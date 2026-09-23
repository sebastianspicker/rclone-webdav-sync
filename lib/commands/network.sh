#!/bin/bash
# network.sh command module - report the active network and metered state.
# Read-only: only local probes (route/networksetup/nmcli) run; nothing is
# written and no server is contacted.

usage_network() {
  usage_emit <<'EOF'
Usage: sciebo network [--json]

Show the active network interface and Wi-Fi name, whether the connection
is metered (OS report, METERED_SSIDS, or a hotspot-looking SSID), the
METERED_POLICY in effect, and the proxy mode for rclone and curl: the
configured PROXY value, `direct` when PROXY_DIRECT=1 ignores the
environment, or `environment`.

Options:
  --json      print the state as JSON
  -h, --help  show this help
EOF
}

cmd_network() {
  local interface="" ssid="" metered="no" policy="" proxy_label=""
  opt_begin "json:b" network "" "$@"
  opt_guard network
  # platform.sh is lazy; load it for the metered/connection probes below
  # (after opt_guard's --help exit, so `sciebo network --help` parses
  # none of it).
  sciebo_require_module platform platform_os
  opt_json_mode
  load_settings --no-rclone
  if net_is_metered; then metered="yes"; fi
  interface="${NET_IFACE:-}"
  ssid="${NET_SSID:-}"
  policy="${METERED_POLICY:-allow}"
  if [[ "${PROXY_DIRECT:-0}" == "1" ]]; then
    proxy_label="direct"
  elif [[ -n "${PROXY:-}" ]]; then
    proxy_label="$(url_redact_userinfo "$PROXY")"
  else
    proxy_label="environment"
  fi
  if output_json_enabled; then
    output_json_begin
    output_json_kv "interface" "$interface"
    output_json_kv "ssid" "$ssid"
    output_json_kv_raw "metered" "$([[ "$metered" == "yes" ]] && printf 'true' || printf 'false')"
    output_json_kv "policy" "$policy"
    output_json_kv "proxy" "$proxy_label"
    output_json_end
    return 0
  fi
  printf 'interface: %s\n' "${interface:--}"
  printf 'ssid: %s\n' "${ssid:--}"
  printf 'metered: %s\n' "$metered"
  printf 'policy: %s\n' "$policy"
  printf 'proxy: %s\n' "$proxy_label"
  return 0
}
