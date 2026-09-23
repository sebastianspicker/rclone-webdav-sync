#!/usr/bin/env bash
# mounts.sh - `mounts` table and --json rendering, --folder filtering, and
# the --check/--prune health pass. `mount` is stubbed so "mounted" is
# controlled by a fake mount table.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

MOUNTS_STUB_BIN="${TMP}/mounts-stub-bin"
FAKE_MOUNT_TABLE="${TMP}/fake-mount-table"
mkdir -p "$MOUNTS_STUB_BIN"
: >"$FAKE_MOUNT_TABLE"
cat >"${MOUNTS_STUB_BIN}/mount" <<'STUB'
#!/bin/bash
cat "${FAKE_MOUNT_TABLE:-/dev/null}"
STUB
chmod +x "${MOUNTS_STUB_BIN}/mount"

# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_mounts_stub() {
  (cd "$TMP" && env PATH="${MOUNTS_STUB_BIN}:$PATH" FAKE_MOUNT_TABLE="$FAKE_MOUNT_TABLE" \
    bash "${PROJ}/bin/sciebo" "$@")
}

MOUNTS_DIR="${STATE_DIR}/mounts"
# seed_mount NAME FOLDER MOUNTPOINT PID SUDO - write one recorded mount state.
# shellcheck disable=SC2329  # invoked indirectly by the seed calls below
seed_mount() {
  mkdir -p "$MOUNTS_DIR"
  printf '%s\n%s\n%s\n%s\n' "$2" "$3" "$4" "$5" >"${MOUNTS_DIR}/$1.state"
}

# base is visible with a live pid (healthy); demo is gone with a dead pid.
seed_mount base "" "${TMP}/mnt-base" "$$" no
seed_mount demo demo "${TMP}/mnt-demo" 999999 no
printf 'FakeNFS on %s (fake, local)\n' "${TMP}/mnt-base" >"$FAKE_MOUNT_TABLE"

# --- usage -----------------------------------------------------------------
expect_cli "mounts: --help rc 0" 0 run_mounts_stub mounts --help
expect_contains "mounts: --help usage" "$CLI_OUT" "Usage: sciebo mounts"
expect_cli "mounts: unknown option rc 2" 2 run_mounts_stub mounts --bogus

# --- table -----------------------------------------------------------------
expect_cli "mounts: listing rc 0" 0 run_mounts_stub mounts
expect_contains "mounts: base name" "$CLI_OUT" "base"
expect_contains "mounts: empty folder shows as (base)" "$CLI_OUT" "base  (base)  ${TMP}/mnt-base  mounted=yes"
expect_contains "mounts: live pid is alive" "$CLI_OUT" "pid=$$  alive=yes"
expect_contains "mounts: demo is not visible" "$CLI_OUT" "demo  demo  ${TMP}/mnt-demo  mounted=no"
expect_contains "mounts: dead pid is not alive" "$CLI_OUT" "pid=999999  alive=no"

expect_cli "mounts: --folder rc 0" 0 run_mounts_stub mounts --folder demo
expect_contains "mounts: --folder keeps the match" "$CLI_OUT" "demo  demo"
expect_not_contains "mounts: --folder hides the rest" "$CLI_OUT" "base  (base)"

# --- json ------------------------------------------------------------------
expect_cli "mounts: --json rc 0" 0 run_mounts_stub mounts --json
expect_contains "mounts: json array" "$CLI_OUT" '"mounts"'
expect_contains "mounts: json mounted record" "$CLI_OUT" '"name": "base"'
expect_contains "mounts: json mounted true" "$CLI_OUT" '"mounted": true'
expect_contains "mounts: json mounted pid" "$CLI_OUT" '"pid": '"$$"
expect_contains "mounts: json mounted alive" "$CLI_OUT" '"alive": true'
expect_contains "mounts: json dead record" "$CLI_OUT" '"name": "demo"'
expect_contains "mounts: json mounted false" "$CLI_OUT" '"mounted": false'
expect_contains "mounts: json alive false" "$CLI_OUT" '"alive": false'

# --- --check / --prune -----------------------------------------------------
expect_cli "mounts: --check rc 1" 1 run_mounts_stub mounts --check
expect_contains "mounts: --check summary" "$CLI_OUT" "Summary: 2 mount(s): 1 ok, 1 unhealthy"

expect_cli "mounts: --prune rc 0" 0 run_mounts_stub mounts --prune
expect_contains "mounts: --prune removes the dead record" "$CLI_OUT" "removed state ${MOUNTS_DIR}/demo.state"
expect_no_file "mounts: --prune deleted the state file" "${MOUNTS_DIR}/demo.state"
expect_file "mounts: --prune keeps the healthy state" "${MOUNTS_DIR}/base.state"

# After removing the last record the empty-list message returns.
rm -f "${MOUNTS_DIR}/base.state"
expect_cli "mounts: empty listing rc 0" 0 run_mounts_stub mounts
expect_contains "mounts: empty message" "$CLI_OUT" "no rclone mounts recorded"

finish
