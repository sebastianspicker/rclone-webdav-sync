#!/bin/bash
# platform.sh - runtime backend selection for key storage, notifications, and
# the sync scheduler. macOS keeps its current backends (security, osascript,
# launchd); Linux prefers libsecret's secret-tool, then pass, and systemd
# --user, then cron.
#
# Every function prints one of the documented words (or nothing) and returns
# 0, so callers can use the result under `set -e`. The SCIEBO_KEYCHAIN_BACKEND,
# SCIEBO_NOTIFY_BACKEND, and SCIEBO_SCHEDULER_BACKEND variables are test
# hooks: when non-empty they are returned verbatim instead of probing.

# platform_os - macos, linux, or other. Resolved once when this module loads
# so hot callers do not fork `uname` per call. Fork removal: the Bash builtin
# $OSTYPE answers the two supported platforms without the per-invocation
# uname fork; uname stays only as the fallback for OSTYPE values the mapping
# does not recognize, so every platform resolves exactly as before.
case "$OSTYPE" in
  darwin*) PLATFORM_OS="macos" ;;
  linux*) PLATFORM_OS="linux" ;;
  *)
    case "$(uname -s 2>/dev/null)" in
      Darwin) PLATFORM_OS="macos" ;;
      Linux) PLATFORM_OS="linux" ;;
      *) PLATFORM_OS="other" ;;
    esac
    ;;
esac
platform_os() {
  printf '%s' "$PLATFORM_OS"
  return 0
}

# platform_opener - the platform file/URL opener, or nothing when neither
# `open` (macOS) nor `xdg-open` (Linux) is available.
platform_opener() {
  if [[ "$PLATFORM_OS" == "macos" ]] && have open; then
    printf 'open'
  elif have xdg-open; then
    printf 'xdg-open'
  elif have open; then
    printf 'open'
  fi
  return 0
}

# platform_open PATH [LABEL] - hand PATH to the platform opener, dying with
# LABEL (default PATH) in the message when no opener exists or it fails.
platform_open() {
  local path="$1" label="${2:-$1}" opener=""
  opener="$(platform_opener)"
  [[ -n "$opener" ]] ||
    die "cannot open ${label}: neither 'open' (macOS) nor 'xdg-open' (Linux) was found"
  "$opener" -- "$path" || die "cannot open ${label}: ${opener} failed"
  return 0
}

# platform_keychain_backend - security, secret-tool, pass, or empty.
# macOS uses `security` when it exists; Linux uses secret-tool (libsecret)
# when it exists, else pass.
platform_keychain_backend() {
  local os=""
  if [[ -n "${SCIEBO_KEYCHAIN_BACKEND:-}" ]]; then
    printf '%s' "$SCIEBO_KEYCHAIN_BACKEND"
    return 0
  fi
  # Forkless capture: platform_os only prints.
  os=${ platform_os;}
  case "$os" in
    macos)
      have security && printf 'security'
      ;;
    linux)
      if have secret-tool; then
        printf 'secret-tool'
      elif have pass; then
        printf 'pass'
      fi
      ;;
  esac
  return 0
}

# platform_notify_backend - osascript, notify-send, or empty.
platform_notify_backend() {
  local os=""
  if [[ -n "${SCIEBO_NOTIFY_BACKEND:-}" ]]; then
    printf '%s' "$SCIEBO_NOTIFY_BACKEND"
    return 0
  fi
  # Forkless capture: platform_os only prints.
  os=${ platform_os;}
  case "$os" in
    macos)
      have osascript && printf 'osascript'
      ;;
    linux)
      have notify-send && printf 'notify-send'
      ;;
  esac
  return 0
}

# platform_scheduler_backend - launchd, systemd, cron, or empty. macOS uses
# launchd; elsewhere a usable `systemctl --user` (live session or
# XDG_RUNTIME_DIR) selects systemd, and `crontab` selects cron.
platform_scheduler_backend() {
  local os=""
  if [[ -n "${SCIEBO_SCHEDULER_BACKEND:-}" ]]; then
    printf '%s' "$SCIEBO_SCHEDULER_BACKEND"
    return 0
  fi
  # Forkless capture: platform_os only prints.
  os=${ platform_os;}
  if [[ "$os" == "macos" ]]; then
    printf 'launchd'
    return 0
  fi
  if systemctl --user show-environment >/dev/null 2>&1 ||
    { [[ -n "${XDG_RUNTIME_DIR:-}" ]] && have systemctl; }; then
    printf 'systemd'
  elif have crontab; then
    printf 'cron'
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Network probes (metered connections)
#
# net_info fills NET_IFACE/NET_SSID/NET_METERED from the OS; net_is_metered
# adds the METERED_SSIDS list and hotspot-looking names; net_gate turns that
# into a sync decision. SCIEBO_NETWORK_BACKEND is the test hook and is
# returned verbatim instead of probing. Every function is best-effort: a
# missing tool or parse problem leaves the globals empty and METERED=0.
# ---------------------------------------------------------------------------

# platform_network_backend - macos, linux, or none.
platform_network_backend() {
  local os=""
  if [[ -n "${SCIEBO_NETWORK_BACKEND:-}" ]]; then
    printf '%s' "$SCIEBO_NETWORK_BACKEND"
    return 0
  fi
  # Forkless capture: platform_os only prints.
  os=${ platform_os;}
  case "$os" in
    macos)
      if have route && have networksetup; then printf 'macos'; else printf 'none'; fi
      ;;
    linux)
      if have nmcli; then printf 'linux'; else printf 'none'; fi
      ;;
    *) printf 'none' ;;
  esac
  return 0
}

# _net_macos_probe - fill NET_IFACE from the default route and NET_SSID from
# networksetup. Never fails.
_net_macos_probe() {
  local out="" line=""
  if have route; then
    out="$(route -n get default 2>/dev/null || true)"
  fi
  while IFS= read -r line; do
    case "$line" in
      *interface:*)
        NET_IFACE=${ trim "${line#*interface:}";}
        break
        ;;
    esac
  done <<<"$out"
  if [[ -n "$NET_IFACE" ]] && have networksetup; then
    out="$(networksetup -getairportnetwork "$NET_IFACE" 2>/dev/null || true)"
    case "$out" in
      "Current Wi-Fi Network: "*) NET_SSID=${ trim "${out#Current Wi-Fi Network: }";} ;;
    esac
  fi
  return 0
}

# _net_nmcli_fields ROW - split one nmcli -t row on unescaped ":" and print
# the fields one per line; "\:" and "\\" are decoded. Passed through ENVIRON
# so awk never reinterprets the backslashes.
_net_nmcli_fields() {
  local row="$1"
  NMCLI_ROW="$row" awk '
    BEGIN {
      s = ENVIRON["NMCLI_ROW"]
      field = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\\" && i < length(s)) {
          i++
          field = field substr(s, i, 1)
          continue
        }
        if (c == ":") {
          print field
          field = ""
          continue
        }
        field = field c
      }
      print field
    }
  '
}

# _net_linux_probe - fill NET_IFACE/NET_SSID from the first active nmcli
# connection (NAME becomes the SSID, DEVICE the interface) and NET_METERED
# from `connection.metered`. Never fails.
_net_linux_probe() {
  local rows="" row="" fields="" name="" device="" metered=""
  if have nmcli; then
    rows="$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null || true)"
  fi
  row="${rows%%$'\n'*}"
  [[ -n "$row" ]] || return 0
  fields="$(_net_nmcli_fields "$row")"
  name="${fields%%$'\n'*}"
  case "$fields" in
    *$'\n'*) device="${fields#*$'\n'}" ;;
    *) device="" ;;
  esac
  NET_SSID="$name"
  NET_IFACE="$device"
  if [[ -n "$name" ]]; then
    metered="$(nmcli -t -f connection.metered connection show "$name" 2>/dev/null || true)"
    metered="${metered%%$'\n'*}"
    case "$metered" in
      yes) NET_METERED=1 ;;
      *) NET_METERED=0 ;;
    esac
  fi
  return 0
}

# net_info - fill NET_IFACE/NET_SSID/NET_METERED for the active connection.
# Never fails. The probe is memoized for the process: `sync` asks once per
# manifest entry, and route/networksetup/nmcli are expensive. A change of
# backend (test hook) invalidates the cache.
NET_INFO_KEY=""
net_info() {
  local key="${SCIEBO_NETWORK_BACKEND:-}:${METERED_SSIDS:-}" backend=""
  if [[ -n "$NET_INFO_KEY" && "$NET_INFO_KEY" == "$key" ]]; then
    return 0
  fi
  NET_INFO_KEY="$key"
  NET_IFACE=""
  NET_SSID=""
  NET_METERED=0
  # Forkless capture: platform_network_backend only prints.
  backend=${ platform_network_backend;}
  case "$backend" in
    macos) _net_macos_probe ;;
    linux) _net_linux_probe ;;
  esac
  return 0
}

# net_is_metered - true (0) when the OS reports a metered connection, the
# SSID exactly matches a METERED_SSIDS entry (case-insensitive; entries are
# comma or whitespace separated), or the SSID looks like a phone hotspot
# (iPhone, AndroidAP, Hotspot, tether; case-insensitive substring).
#
# NET_METERED_LIST_CACHE holds the comma/whitespace-normalized METERED_SSIDS
# keyed by the raw value, mirroring the NET_INFO_KEY cache, so the two tr
# passes run once per distinct list instead of on every call.
NET_METERED_LIST_KEY=""
NET_METERED_LIST=""
net_is_metered() {
  local ssid_lower="" list="" raw=""
  net_info
  local LC_ALL=C
  [[ "${NET_METERED:-0}" == "1" ]] && return 0
  [[ -n "${NET_SSID:-}" ]] || return 1
  ssid_lower="${NET_SSID,,}"
  raw="${METERED_SSIDS:-}"
  if [[ "$NET_METERED_LIST_KEY" != "$raw" ]]; then
    NET_METERED_LIST="$(printf '%s' "$raw" |
      LC_ALL=C tr ',' ' ' |
      LC_ALL=C tr -s '[:space:]' ' ')"
    NET_METERED_LIST_KEY="$raw"
  fi
  list=" ${NET_METERED_LIST} "
  case "$list" in
    *" ${ssid_lower} "*) return 0 ;;
  esac
  case "$ssid_lower" in
    *iphone* | *androidap* | *hotspot* | *tether*) return 0 ;;
  esac
  return 1
}

# net_gate - 0 to proceed, 2 to skip on a metered connection. SCIEBO_METERED_OK=1
# and METERED_POLICY=allow always proceed; skip warns and returns 2; ask
# prompts through ui_confirm_tty (unified [y/yes] dialect) and any other
# outcome - declined, EOF, or not askable (no tty / SCIEBO_NON_INTERACTIVE) -
# warns and returns 2.
net_gate() {
  local label=""
  net_is_metered || return 0
  [[ "${SCIEBO_METERED_OK:-0}" == "1" ]] && return 0
  if [[ -n "${NET_SSID:-}" ]]; then
    label="metered connection $(printable "$NET_SSID")"
  else
    label="metered connection"
  fi
  case "${METERED_POLICY:-allow}" in
    allow) return 0 ;;
    skip)
      warn "${label}: skipped (METERED_POLICY=skip)"
      return 2
      ;;
    ask)
      # ui.sh loads lazily; require it before the probe so METERED_POLICY=ask
      # still prompts instead of silently skipping the confirmation when the
      # module has not been loaded yet. ui_confirm_tty's rc 0 is the approved
      # answer; rc 1 (declined/EOF) and rc 2 (not askable) fall through to the
      # same "not confirmed" skip this branch always took when the question
      # could not be asked.
      sciebo_require_module ui ui_ask
      if type ui_ask >/dev/null 2>&1 && ui_confirm_tty "${label}; sync anyway?"; then
        return 0
      fi
      warn "${label}: skipped (not confirmed)"
      return 2
      ;;
  esac
  return 0
}
