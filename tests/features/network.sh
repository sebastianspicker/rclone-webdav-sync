#!/usr/bin/env bash
# network.sh - metered-connection detection, net_gate policy, and the
# `network` report. Stubbed route/networksetup keep it hermetic.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

STUB="${TMP}/net-stub"
mkdir -p "$STUB"
cat >"${STUB}/route" <<'STUB_ROUTE'
#!/bin/bash
printf '   route to: default\n'
printf 'destination: default\n'
printf '    interface: en0\n'
exit 0
STUB_ROUTE
cat >"${STUB}/networksetup" <<'STUB_NETWORKSETUP'
#!/bin/bash
printf 'Current Wi-Fi Network: FakeHotspot\n'
exit 0
STUB_NETWORKSETUP
chmod +x "${STUB}/route" "${STUB}/networksetup"

export SCIEBO_NETWORK_BACKEND=macos PATH="${STUB}:${PATH}"
export METERED_SSIDS="FakeHotspot"
unset SCIEBO_METERED_OK || true

net_info
expect_eq "network: interface parsed" "en0" "$NET_IFACE"
expect_eq "network: ssid parsed" "FakeHotspot" "$NET_SSID"
expect_rc "network: metered" "$(
  net_is_metered
  echo $?
)" 0

export METERED_POLICY=skip
net_gate
rc=$?
expect_rc "network: gate skips metered" "$rc" 2
export SCIEBO_METERED_OK=1
net_gate
rc=$?
expect_rc "network: gate override" "$rc" 0
export METERED_POLICY=allow
unset SCIEBO_METERED_OK || true

expect_cli "network: json rc 0" 0 run_cli network --json
expect_contains "network: json metered" "$CLI_OUT" '"metered": true'
expect_contains "network: json ssid" "$CLI_OUT" '"ssid": "FakeHotspot"'

expect_cli "network: plain rc 0" 0 run_cli network
expect_contains "network: plain row" "$CLI_OUT" "metered: yes"
expect_contains "network: proxy environment" "$CLI_OUT" "proxy: environment"

export PROXY="http://p.example:8080"
expect_cli "network: proxy value" 0 run_cli network
expect_contains "network: proxy url" "$CLI_OUT" "proxy: http://p.example:8080"
unset PROXY || true

# --- credential proxy: the password never survives the report ----------------
# The proxy userinfo is masked (`user:secret@` -> `***@`) in both the JSON and
# the text report, while the non-secret policy stays readable: the http scheme
# and host that PROXY_TYPE=http selects, and `direct` for PROXY_DIRECT=1.
CRED_PROXY="http://user:secret@proxy.example:8080"
export PROXY="$CRED_PROXY" PROXY_TYPE=http
expect_cli "network: credential proxy json rc 0" 0 run_cli network --json
expect_not_contains "network: json proxy password absent" "$CLI_OUT" "secret"
expect_not_contains "network: json proxy userinfo absent" "$CLI_OUT" "user:secret"
expect_contains "network: json proxy userinfo masked" "$CLI_OUT" '"proxy": "http://***@proxy.example:8080"'

expect_cli "network: credential proxy text rc 0" 0 run_cli network
expect_not_contains "network: text proxy password absent" "$CLI_OUT" "secret"
expect_contains "network: text proxy policy kept" "$CLI_OUT" "proxy: http://***@proxy.example:8080"

# PROXY_DIRECT is non-secret policy and still wins when a credential PROXY is
# configured, so the report says `direct` and leaks nothing.
export PROXY_DIRECT=1
expect_cli "network: credential proxy direct json rc 0" 0 run_cli network --json
expect_not_contains "network: json direct proxy password absent" "$CLI_OUT" "secret"
expect_contains "network: json direct policy shown" "$CLI_OUT" '"proxy": "direct"'
unset PROXY PROXY_TYPE PROXY_DIRECT || true

CLI_OUT="$(env SCIEBO_NETWORK_BACKEND=none PATH="${STUB}:${PATH}" bash "${PROJ}/bin/sciebo" network 2>&1)"
CLI_RC=$?
expect_rc "network: none backend rc 0" "$CLI_RC" 0
expect_contains "network: none backend not metered" "$CLI_OUT" "metered: no"

# --- metered SSID list normalization and memoization -------------------------
# The normalized METERED_SSIDS list is cached by raw value. Pinning
# NET_INFO_KEY/NET_SSID keeps the probe from overwriting the fixture; the SSID
# deliberately lacks a hotspot keyword so only the list decides the result.
export METERED_SSIDS="home, officewifi"
NET_INFO_KEY="macos:home, officewifi"
NET_SSID="OfficeWifi"
NET_METERED=0
NET_METERED_LIST_KEY=""
rc=0
net_is_metered || rc=$?
expect_rc "network: comma and space separated list matches" "$rc" 0
export METERED_SSIDS="otherwifi"
NET_INFO_KEY="macos:otherwifi"
NET_SSID="OfficeWifi"
rc=0
net_is_metered || rc=$?
expect_rc "network: a changed list invalidates the cache" "$rc" 1
export METERED_SSIDS="FakeHotspot"
NET_INFO_KEY=""
NET_METERED_LIST_KEY=""

finish
