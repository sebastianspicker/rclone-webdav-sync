#!/usr/bin/env bash
# server.sh - `sciebo server info/capabilities/status`: cached capability
# facts without network, the raw cache passthrough, probe fallback with a
# stale cache, rclone reachability PASS/FAIL, and usage failures.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

mkdir -p "$STATE_DIR"
cat >"${STATE_DIR}/capabilities.env" <<'EOF'
CAP_VERSION=31.0.2
CAP_BIGFILE_CHUNKING=true
CAP_CHUNK_MAX_SIZE=104857600
CAP_UNDELETE=true
CAP_CHECKSUMS=true
CAP_PROBED_AT=1700000000
EOF
printf '%s\n' '{"ocs":{"meta":{"statuscode":200},"data":{"version":{"string":"31.0.2"}}}}' \
  >"${STATE_DIR}/capabilities.json"

# --- capabilities: the fresh cache is used without any network --------------
stub_reset_routes
stub_clear_calls
expect_cli "server capabilities rc 0" 0 run_cli_nc server capabilities
expect_contains "server capabilities version" "$CLI_OUT" "server: Nextcloud 31.0.2"
expect_contains "server capabilities chunking" "$CLI_OUT" "chunked uploads: enabled (max chunk 100Mi)"
expect_contains "server capabilities trashbin" "$CLI_OUT" "trashbin: available"
expect_contains "server capabilities checksums" "$CLI_OUT" "checksums: available"
expect_eq "server capabilities avoids the network" "0" "$(stub_count 'cloud/capabilities')"

expect_cli "server capabilities --raw rc 0" 0 run_cli_nc server capabilities --raw
expect_contains "server capabilities raw JSON" "$CLI_OUT" '"version":{"string":"31.0.2"}'
expect_eq "server capabilities --raw avoids the network" "0" "$(stub_count 'cloud/capabilities')"

expect_cli "server capabilities --json rc 0" 0 run_cli_nc server capabilities --json
expect_contains "server capabilities json version" "$CLI_OUT" '"version": "31.0.2"'
expect_contains "server capabilities json chunking" "$CLI_OUT" '"chunking": true'
expect_contains "server capabilities json chunk size" "$CLI_OUT" '"chunk_max_size": 104857600'
expect_contains "server capabilities json trashbin" "$CLI_OUT" '"trashbin": true'
expect_contains "server capabilities json checksums" "$CLI_OUT" '"checksums": true'
expect_eq "server capabilities --json avoids the network" "0" "$(stub_count 'cloud/capabilities')"

# --- info: base URL, user, and the Cap_* facts ------------------------------
stub_clear_calls
expect_cli "server info rc 0" 0 run_cli_nc server info
expect_contains "server info base" "$CLI_OUT" "SERVER: http://127.0.0.1:9"
expect_contains "server info user" "$CLI_OUT" "USER: alice"
expect_contains "server info version" "$CLI_OUT" "VERSION: 31.0.2"
expect_contains "server info chunking" "$CLI_OUT" "CHUNKING: enabled (max chunk 100Mi)"
expect_contains "server info trashbin" "$CLI_OUT" "TRASHBIN: available"
expect_contains "server info checksums" "$CLI_OUT" "CHECKSUMS: available"
expect_eq "server info avoids the network" "0" "$(stub_count 'cloud/capabilities')"

expect_cli "server info --json rc 0" 0 run_cli_nc server info --json
expect_contains "server info json server" "$CLI_OUT" '"server": "http://127.0.0.1:9"'
expect_contains "server info json user" "$CLI_OUT" '"user": "alice"'
expect_contains "server info json version" "$CLI_OUT" '"version": "31.0.2"'
expect_contains "server info json chunking" "$CLI_OUT" '"chunking": true'
expect_contains "server info json chunk size" "$CLI_OUT" '"chunk_max_size": 104857600'
expect_contains "server info json trashbin" "$CLI_OUT" '"trashbin": true'
expect_contains "server info json checksums" "$CLI_OUT" '"checksums": true'

# --- status: PASS/FAIL from `rclone lsd` ------------------------------------
STUB_RCLONE_DIR="${TMP}/server-stub-rclone"
mkdir -p "$STUB_RCLONE_DIR"
cat >"${STUB_RCLONE_DIR}/rclone" <<'STUB'
#!/bin/bash
if [[ "${SERVER_STATUS_FAIL:-0}" == "1" ]]; then
  printf 'ERROR : server said no\n' >&2
  exit 3
fi
printf '          -1 2025-01-01 00:00:00        -1 backup\n'
exit 0
STUB
chmod +x "${STUB_RCLONE_DIR}/rclone"
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_cli_stub() {
  (cd "$TMP" && env PATH="${STUB_RCLONE_DIR}:$PATH" bash "${PROJ}/bin/sciebo" "$@")
}
expect_cli "server status PASS rc 0" 0 run_cli_stub server status
expect_contains "server status PASS line" "$CLI_OUT" "PASS server reachable: testremote:backup"
expect_not_contains "server status PASS drops stderr" "$CLI_OUT" "ERROR"

export SERVER_STATUS_FAIL=1
expect_cli "server status FAIL rc 1" 1 run_cli_stub server status
expect_contains "server status FAIL line" "$CLI_OUT" "FAIL server unreachable: testremote:backup"
expect_contains "server status FAIL surfaces stderr" "$CLI_OUT" "server said no"
unset SERVER_STATUS_FAIL

# --- stale cache: probe the OCS endpoint and show the parsed result ---------
rm -f "${STATE_DIR}/capabilities.env" "${STATE_DIR}/capabilities.json"
stub_reset_routes
stub_clear_calls
stub_route GET '*cloud/capabilities*' 200 <<'XML'
{"ocs":{"meta":{"status":"ok","statuscode":200,"message":"OK"},"data":{"version":{"major":31,"minor":0,"micro":2,"string":"31.0.2"},"capabilities":{"files":{"bigfilechunking":true},"files_sharing":{"chunked_upload":{"max_size":104857600}}}}}}
XML
expect_cli "server capabilities probe rc 0" 0 run_cli_nc server capabilities
expect_contains "server capabilities probe result" "$CLI_OUT" "server: Nextcloud 31.0.2"
expect_contains "server capabilities probe chunking" "$CLI_OUT" "chunked uploads: enabled (max chunk 100Mi)"
expect_eq "server capabilities probes once" "1" "$(stub_count 'cloud/capabilities')"
expect_file "server capabilities writes the cache" "${STATE_DIR}/capabilities.env"

# --- no cache and a failing probe: unknown, still rc 0 ----------------------
rm -f "${STATE_DIR}/capabilities.env" "${STATE_DIR}/capabilities.json"
stub_reset_routes
expect_cli "server capabilities unknown rc 0" 0 run_cli_nc server capabilities
expect_contains "server capabilities unknown message" "$CLI_OUT" "unknown"

# --- usage failures ----------------------------------------------------------
expect_cli "server unknown subcommand rc 2" 2 run_cli_nc server bogus
expect_contains "server unknown subcommand named" "$CLI_OUT" "unknown subcommand"
expect_cli "server missing subcommand rc 2" 2 run_cli_nc server
expect_contains "server needs a subcommand" "$CLI_OUT" "a subcommand is required"
expect_cli "server extra argument rc 2" 2 run_cli_nc server info extra
expect_contains "server extra argument named" "$CLI_OUT" "unexpected argument"
expect_cli "server capabilities rejects --json with --raw rc 2" 2 run_cli_nc server capabilities --json --raw
expect_contains "server capabilities --json --raw message" "$CLI_OUT" "mutually exclusive"
expect_cli "server info rejects --raw rc 2" 2 run_cli_nc server info --raw
expect_contains "server info --raw message" "$CLI_OUT" "does not support --raw"
expect_cli "server --help rc 0" 0 run_cli_nc server --help
expect_contains "server help lists subcommands" "$CLI_OUT" "capabilities [--raw]"

finish
