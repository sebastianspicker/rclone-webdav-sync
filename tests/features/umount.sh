#!/usr/bin/env bash
# umount.sh - `umount` selector resolution, --all, and the failed-unmount
# retry path. `mount` (visibility) and `umount` are stubbed, so no real
# filesystem is unmounted.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

UMOUNT_STUB_BIN="${TMP}/umount-stub-bin"
FAKE_MOUNT_TABLE="${TMP}/fake-mount-table"
mkdir -p "$UMOUNT_STUB_BIN"
: >"$FAKE_MOUNT_TABLE"
cat >"${UMOUNT_STUB_BIN}/mount" <<'STUB'
#!/bin/bash
cat "${FAKE_MOUNT_TABLE:-/dev/null}"
STUB
chmod +x "${UMOUNT_STUB_BIN}/mount"

# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_umount_stub() {
  (cd "$TMP" && env PATH="${UMOUNT_STUB_BIN}:$PATH" FAKE_MOUNT_TABLE="$FAKE_MOUNT_TABLE" \
    bash "${PROJ}/bin/sciebo" "$@")
}

# seed_mount NAME FOLDER MOUNTPOINT PID SUDO - write one recorded mount state.
MOUNTS_DIR="${STATE_DIR}/mounts"
# shellcheck disable=SC2329  # invoked indirectly by the seed calls below
seed_mount() {
  mkdir -p "$MOUNTS_DIR"
  printf '%s\n%s\n%s\n%s\n' "$2" "$3" "$4" "$5" >"${MOUNTS_DIR}/$1.state"
}

# --- usage -----------------------------------------------------------------
expect_cli "umount: --help rc 0" 0 run_umount_stub umount --help
expect_contains "umount: --help usage" "$CLI_OUT" "Usage: sciebo umount"
expect_cli "umount: no selector rc 2" 2 run_umount_stub umount
expect_contains "umount: no selector message" "$CLI_OUT" "requires --folder, --mountpoint, or --all"
expect_cli "umount: two selectors rc 2" 2 run_umount_stub umount --folder a --mountpoint /b
expect_contains "umount: two selectors message" "$CLI_OUT" "use only one of"
expect_cli "umount: unknown option rc 2" 2 run_umount_stub umount --bogus

# --- unknown selector ------------------------------------------------------
: >"$FAKE_MOUNT_TABLE"
expect_cli "umount: unknown folder rc 0" 0 run_umount_stub umount --folder nosuch
expect_contains "umount: unknown folder reports not mounted" "$CLI_OUT" "not mounted"

# --- unmount by selector ---------------------------------------------------
seed_mount demo demo "${TMP}/mnt-demo" - no
expect_cli "umount: --folder rc 0" 0 run_umount_stub umount --folder demo
expect_contains "umount: --folder logs the removal" "$CLI_OUT" "removed state"
expect_no_file "umount: --folder state gone" "${MOUNTS_DIR}/demo.state"

seed_mount alpha alpha "${TMP}/mnt-x" - no
expect_cli "umount: --mountpoint rc 0" 0 run_umount_stub umount --mountpoint "${TMP}/mnt-x"
expect_no_file "umount: --mountpoint state gone" "${MOUNTS_DIR}/alpha.state"

# --- --all -----------------------------------------------------------------
expect_cli "umount: --all without state rc 0" 0 run_umount_stub umount --all
expect_contains "umount: --all empty message" "$CLI_OUT" "no rclone mounts recorded"

seed_mount one one "${TMP}/mnt-one" - no
seed_mount two two "${TMP}/mnt-two" - no
expect_cli "umount: --all rc 0" 0 run_umount_stub umount --all
expect_no_file "umount: --all removed first state" "${MOUNTS_DIR}/one.state"
expect_no_file "umount: --all removed second state" "${MOUNTS_DIR}/two.state"

# --- a failed unmount keeps the record for a retry -------------------------
printf '#!/bin/bash\necho "umount stub" >&2\nexit 1\n' >"${UMOUNT_STUB_BIN}/umount"
chmod +x "${UMOUNT_STUB_BIN}/umount"
printf 'FakeNFS on %s (fake, local)\n' "${TMP}/mnt-fail" >"$FAKE_MOUNT_TABLE"
seed_mount failf failf "${TMP}/mnt-fail" - no
expect_cli "umount: failure rc 1" 1 run_umount_stub umount --folder failf
expect_contains "umount: failure keeps the state" "$CLI_OUT" "keeping its state"
expect_file "umount: failure keeps the state file" "${MOUNTS_DIR}/failf.state"
rm -f "${UMOUNT_STUB_BIN}/umount"

finish
