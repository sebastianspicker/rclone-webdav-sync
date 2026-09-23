#!/usr/bin/env bash
# sync_integration.sh - the sync hooks around bandwidth, server filters,
# HTTP/2, the metered network gate, the disk guard, and `list --json`.
#
# A stub rclone logs the full argv of every non-preflight call and exits 0,
# so the assertions can inspect exactly what sync would have executed
# without any network or real transfer.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

STUB_BIN="${TMP}/sync-integration-bin"
NET_STUB="${TMP}/sync-integration-net"
STUB_ARGV="${TMP}/sync-integration.argv"
SSID_FILE="${TMP}/sync-integration.ssid"
mkdir -p "$STUB_BIN" "$NET_STUB"
cat >"${STUB_BIN}/rclone" <<'STUB'
#!/bin/bash
for arg in "$@"; do
  case "$arg" in
    version)
      printf 'rclone v1.75.1\n'
      exit 0
      ;;
    listremotes)
      printf 'testremote:\n'
      exit 0
      ;;
  esac
done
printf '%s\n' "$*" >>"${STUB_ARGV:-/dev/null}"
exit 0
STUB
chmod +x "${STUB_BIN}/rclone"

# route/networksetup stubs keep the metered probe hermetic; the SSID comes
# from SSID_FILE so each scenario can change it.
printf 'HomeNet\n' >"$SSID_FILE"
cat >"${NET_STUB}/route" <<'STUB'
#!/bin/bash
printf '   route to: default\n'
printf 'destination: default\n'
printf '    interface: en0\n'
exit 0
STUB
cat >"${NET_STUB}/networksetup" <<'STUB'
#!/bin/bash
printf 'Current Wi-Fi Network: %s\n' "$(cat "$SSID_FILE" 2>/dev/null || printf 'HomeNet')"
exit 0
STUB
chmod +x "${NET_STUB}/route" "${NET_STUB}/networksetup"

# run_cli_stub - run the CLI with the stub rclone and network probe on PATH.
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_cli_stub() {
  (cd "$TMP" && env PATH="${STUB_BIN}:${NET_STUB}:$PATH" RCLONE_BIN="${STUB_BIN}/rclone" \
    STUB_ARGV="$STUB_ARGV" SSID_FILE="$SSID_FILE" bash "${PROJ}/bin/sciebo" "$@")
}

stub_argv() { cat "$STUB_ARGV" 2>/dev/null || true; }
stub_argv_clear() { : >"$STUB_ARGV"; }

PULL_NAME="integration-pull"
PULL_LOCAL="${TMP}/sync-integration-pull"
SERVER_EXCLUDE_FILTER="${TMP}/filters/server-exclude.txt"
export SERVER_EXCLUDE_FILTER
mkdir -p "$PULL_LOCAL"
cat >"$MANIFEST_FILE" <<EOF
pull|${PULL_LOCAL}|${PULL_NAME}
EOF

# Deterministic starting point: not metered, no disk or size guard.
unset SCIEBO_NETWORK_BACKEND METERED_SSIDS SCIEBO_METERED_OK || true
export METERED_POLICY=allow

# --- (a) the generated server filter is layered before clutter.txt --------
export FILTER_SERVER_SYNC=1
printf -- '- *.tmp\n' >"$SERVER_EXCLUDE_FILTER"
stub_argv_clear
expect_cli "integration: run with the server filter rc 0" 0 run_cli_stub sync --only "$PULL_NAME"
expect_contains "integration: server filter passed with --filter-from" "$(stub_argv)" "--filter-from ${SERVER_EXCLUDE_FILTER}"
expect_contains "integration: server filter precedes clutter.txt" "$(stub_argv)" \
  "--filter-from ${SERVER_EXCLUDE_FILTER} --filter-from ${FILTER_DIR}/clutter.txt"
export FILTER_SERVER_SYNC=0

# --- (b) the bw marker becomes --bwlimit (marker wins over BW_LIMIT_*) ----
expect_cli "integration: limit --up 2M rc 0" 0 run_cli_stub limit --up 2M
stub_argv_clear
expect_cli "integration: run with the bandwidth marker rc 0" 0 run_cli_stub sync --only "$PULL_NAME"
expect_contains "integration: bwlimit from the marker" "$(stub_argv)" "--bwlimit 2M:off"
expect_cli "integration: unlimited rc 0" 0 run_cli_stub unlimited

# --- (c) HTTP2_ENABLED=0 forces HTTP/1.1 --------------------------------
export HTTP2_ENABLED=0
stub_argv_clear
expect_cli "integration: run with HTTP/2 disabled rc 0" 0 run_cli_stub sync --only "$PULL_NAME"
expect_contains "integration: disable-http2 passed" "$(stub_argv)" "--disable-http2"
unset HTTP2_ENABLED || true

# --- (d) metered gate: none backend proceeds, hotspot skips, --metered-ok -
export SCIEBO_NETWORK_BACKEND=none METERED_POLICY=skip METERED_SSIDS=""
stub_argv_clear
expect_cli "integration: none backend is not metered rc 0" 0 run_cli_stub sync --only "$PULL_NAME"
expect_contains "integration: none backend runs rclone" "$(stub_argv)" "sync"

printf 'FakeHotspot\n' >"$SSID_FILE"
export SCIEBO_NETWORK_BACKEND=macos METERED_SSIDS="FakeHotspot" METERED_POLICY=skip
stub_argv_clear
expect_cli "integration: metered hotspot skips rc 0" 0 run_cli_stub sync --only "$PULL_NAME"
expect_contains "integration: skip reason mentions metered" "$CLI_OUT" "metered"
expect_contains "integration: skip reason names the policy" "$CLI_OUT" "METERED_POLICY=skip"
expect_eq "integration: metered skip runs no rclone" "" "$(stub_argv)"

stub_argv_clear
expect_cli "integration: --metered-ok overrides the gate rc 0" 0 run_cli_stub sync --only "$PULL_NAME" --metered-ok
expect_contains "integration: --metered-ok runs rclone" "$(stub_argv)" "sync"
expect_contains "integration: --metered-ok run reports OK" "$CLI_OUT" "OK"

# --- (e) MIN_FREE_SPACE fails the entry before rclone runs ---------------
export SCIEBO_NETWORK_BACKEND=none METERED_POLICY=allow
unset METERED_SSIDS SCIEBO_METERED_OK || true
export MIN_FREE_SPACE=999999T
stub_argv_clear
expect_cli "integration: low free space fails rc 1" 1 run_cli_stub sync --only "$PULL_NAME"
expect_contains "integration: free space reason" "$CLI_OUT" "free space below MIN_FREE_SPACE"
expect_eq "integration: failed disk guard runs no rclone" "" "$(stub_argv)"
unset MIN_FREE_SPACE || true

# --- (f) list --json -----------------------------------------------------
expect_cli "integration: list --json rc 0" 0 run_cli_stub list --json
expect_contains "integration: list --json has a sources array" "$CLI_OUT" '"sources"'
expect_contains "integration: list --json names the entry" "$CLI_OUT" "$PULL_NAME"
expect_contains "integration: list --json records the source" "$CLI_OUT" '"source": "manual"'

finish
