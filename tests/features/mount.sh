#!/usr/bin/env bash
# mount.sh - `mount` state recording, option validation, and the nfsmount
# exit-status path. rclone and `mount` are stubbed, so no real NFS mount is
# ever attempted and no hidden mountpoint is touched.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

export MOUNT_ROOT="${TMP}/mnt-root"
MOUNT_STUB_BIN="${TMP}/mount-stub-bin"
FAKE_MOUNT_TABLE="${TMP}/fake-mount-table"
FAKE_MOUNT_ARGV="${TMP}/fake-mount-argv"
# Unset means "succeed"; a value makes the nfsmount stub fail with exit 7.
FAKE_MOUNT_FAIL=""
mkdir -p "$MOUNT_STUB_BIN"
: >"$FAKE_MOUNT_TABLE"
: >"$FAKE_MOUNT_ARGV"

# The rclone stub satisfies the mount preflight (listremotes, lsd), records
# every argv, and turns nfsmount into "print the mountpoint into the fake
# mount table" so `is_mounted` sees it without a kernel mount.
cat >"${MOUNT_STUB_BIN}/rclone" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"${FAKE_MOUNT_ARGV:-/dev/null}"
command=""
for arg in "$@"; do
  case "$arg" in
    listremotes | lsd | nfsmount | version) command="$arg"; break ;;
  esac
done
case "$command" in
  listremotes) printf 'testremote:\n' ;;
  version) printf 'rclone v1.75.1\n' ;;
  lsd) exit 0 ;;
  nfsmount)
    if [[ -n "${FAKE_MOUNT_FAIL:-}" ]]; then
      printf 'stub nfsmount boom\n' >&2
      exit 7
    fi
    seen=false count=0 mountpoint=""
    for arg in "$@"; do
      if [[ "$seen" == true ]]; then
        count=$((count + 1))
        if [[ "$count" -eq 2 ]]; then mountpoint="$arg" && break; fi
      elif [[ "$arg" == nfsmount ]]; then
        seen=true
      fi
    done
    [[ -z "$mountpoint" ]] || printf 'FakeNFS on %s (fake, local)\n' "$mountpoint" >>"${FAKE_MOUNT_TABLE:?}"
    exit 0
    ;;
esac
exit 0
STUB
cat >"${MOUNT_STUB_BIN}/mount" <<'STUB'
#!/bin/bash
cat "${FAKE_MOUNT_TABLE:-/dev/null}"
STUB
chmod +x "${MOUNT_STUB_BIN}/rclone" "${MOUNT_STUB_BIN}/mount"

# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_mount_stub() {
  (cd "$TMP" && env PATH="${MOUNT_STUB_BIN}:$PATH" RCLONE_BIN="${MOUNT_STUB_BIN}/rclone" \
    MOUNT_ROOT="$MOUNT_ROOT" FAKE_MOUNT_TABLE="$FAKE_MOUNT_TABLE" \
    FAKE_MOUNT_ARGV="$FAKE_MOUNT_ARGV" FAKE_MOUNT_FAIL="${FAKE_MOUNT_FAIL:-}" \
    bash "${PROJ}/bin/sciebo" "$@")
}
MOUNTS_DIR="${STATE_DIR}/mounts"

# --- usage -----------------------------------------------------------------
expect_cli "mount: --help rc 0" 0 run_mount_stub mount --help
expect_contains "mount: --help usage" "$CLI_OUT" "Usage: sciebo mount"
expect_cli "mount: unknown option rc 2" 2 run_mount_stub mount --bogus
expect_cli "mount: positional argument rc 2" 2 run_mount_stub mount bogus
expect_cli "mount: --folder without a value rc 2" 2 run_mount_stub mount --folder
expect_cli "mount: unsafe folder rc 1" 1 run_mount_stub mount --folder ../evil
expect_contains "mount: unsafe folder message" "$CLI_OUT" "invalid remote folder"

# --- state recording -------------------------------------------------------
: >"$FAKE_MOUNT_TABLE"
expect_cli "mount: --folder rc 0" 0 run_mount_stub mount --folder docs
expect_contains "mount: reports the remote spec" "$CLI_OUT" "Mounted testremote:backup/docs"
expect_contains "mount: prints the unmount hint" "$CLI_OUT" "umount --folder docs"
expect_file "mount: state written" "${MOUNTS_DIR}/docs.state"
expect_eq "mount: state folder line" "docs" "$(sed -n '1p' "${MOUNTS_DIR}/docs.state")"
expect_eq "mount: state mountpoint line" "${MOUNT_ROOT}/docs" "$(sed -n '2p' "${MOUNTS_DIR}/docs.state")"
expect_contains "mount: visible in the mount table" "$(cat "$FAKE_MOUNT_TABLE")" "${MOUNT_ROOT}/docs"

# A recorded state whose mountpoint is no longer visible is a duplicate.
: >"$FAKE_MOUNT_TABLE"
expect_cli "mount: duplicate state rc 1" 1 run_mount_stub mount --folder docs
expect_contains "mount: duplicate message" "$CLI_OUT" "mount state already exists"

# --ro is reflected in the state output and passed through to rclone.
expect_cli "mount: --ro rc 0" 0 run_mount_stub mount --folder ro-docs --ro
expect_contains "mount: --ro reports ro mode" "$CLI_OUT" "(ro, name=ro-docs)"
expect_contains "mount: --ro passes --read-only" "$(cat "$FAKE_MOUNT_ARGV")" "--read-only"

# A custom --mountpoint is recorded under the "root" name.
expect_cli "mount: --mountpoint rc 0" 0 run_mount_stub mount --mountpoint "${TMP}/custom-mp"
expect_file "mount: root state written" "${MOUNTS_DIR}/root.state"
expect_eq "mount: root state mountpoint line" "${TMP}/custom-mp" "$(sed -n '2p' "${MOUNTS_DIR}/root.state")"

# rclone's failure must surface and leave no state behind.
FAKE_MOUNT_FAIL=1
expect_cli "mount: nfsmount failure rc 1" 1 run_mount_stub mount --folder fail-docs
expect_contains "mount: failure reports the exit code" "$CLI_OUT" "exit 7"
expect_contains "mount: failure keeps rclone stderr" "$CLI_OUT" "stub nfsmount boom"
expect_no_file "mount: failure records no state" "${MOUNTS_DIR}/fail-docs.state"
FAKE_MOUNT_FAIL=""

# The foreground path runs rclone to completion and drops its state on exit.
expect_cli "mount: --foreground rc 0" 0 run_mount_stub mount --folder fg-docs --foreground
expect_contains "mount: --foreground reports the unmount" "$CLI_OUT" "Unmounted testremote:backup/fg-docs"
expect_no_file "mount: --foreground clears its state" "${MOUNTS_DIR}/fg-docs.state"

finish
