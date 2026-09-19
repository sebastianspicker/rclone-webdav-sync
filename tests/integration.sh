#!/bin/bash
# integration.sh - end-to-end tests for the sciebo CLI.
# Run from any directory: /bin/bash tests/integration.sh
#
# Isolation: the CLI runs as `/bin/bash "$PROJ/bin/sciebo" ...` (macOS bash
# 3.2) against a temporary `local` rclone remote; every path override
# (STATE_DIR, manifests, filters, ...) points into a fresh mktemp directory.
# The real remote, rclone config, config/folders.conf, config/filters/ and
# launchd are never modified; launchd install/uninstall stays opt-in behind
# INTEGRATION_LAUNCHD=1. Without rclone the suite prints SKIP and exits 0.
set -uo pipefail
INTEGRATION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$(cd "${INTEGRATION_DIR}/.." && pwd)"
command -v rclone >/dev/null 2>&1 || {
  echo "SKIP: rclone not installed"
  exit 0
}
TMP="$(mktemp -d "${TMPDIR:-/tmp}/rclone-sciebo-test.XXXXXX")"
HOLDER_PID=""
# shellcheck disable=SC2329  # invoked through the EXIT trap
cleanup() {
  if [[ -n "$HOLDER_PID" ]]; then
    kill "$HOLDER_PID" 2>/dev/null || true
    wait "$HOLDER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

# shellcheck source-path=SCRIPTDIR
# shellcheck source=harness.sh
source "${INTEGRATION_DIR}/harness.sh"

# Isolation: state, manifests, filters, and the remote live under $TMP.
# TRANSFERS/RETRIES/CONTIMEOUT are the CLI's own settings (turned into
# rclone flags), so dead-endpoint tests fail fast instead of hanging.
export RCLONE_REMOTE=testremote RCLONE_CONFIG="${TMP}/rclone.conf" REMOTE_BASE=backup \
  STATE_DIR="${TMP}/state" SETTINGS_LOCAL_FILE="${TMP}/no-local.env" ENV_FILE="${TMP}/no-env.env" \
  MANIFEST_FILE="${TMP}/sources.conf" MANIFEST_GENERATED_FILE="${TMP}/sources.generated.conf" \
  ROOTS_FILE="${TMP}/roots.conf" FOLDERS_FILE="${TMP}/folders.conf" FILTER_DIR="${TMP}/filters" \
  LAUNCHD_LABEL="de.rclone-sciebo.sync.integrationtest" \
  TRANSFERS=1 RETRIES=1 LOW_LEVEL_RETRIES=1 CONTIMEOUT=1s TIMEOUT=10s
mkdir -p "$FILTER_DIR"
# Empty wizard manifest: assertions must not depend on config/folders.conf.
: >"$FOLDERS_FILE"
cp "${PROJ}/config/filters/clutter.txt" "$FILTER_DIR/clutter.txt"

# Content snapshot of the real project config, compared at the end to prove
# isolation (content, not just file names).
config_snapshot() {
  local file
  find "${PROJ}/config/filters" -type f | LC_ALL=C sort | while IFS= read -r file; do
    shasum "$file"
  done
  shasum "${PROJ}/config/folders.conf"
}
CONFIG_SNAPSHOT_BEFORE="$(config_snapshot)"
OBSCURED="$(rclone obscure 'integration-test-secret')"
rclone config create testremote local --config "$RCLONE_CONFIG" >/dev/null 2>&1 || {
  echo "SKIP: cannot create temporary local remote"
  exit 0
}
rclone config create webtest webdav url="http://127.0.0.1:9/remote.php/dav/files/alice/" \
  vendor=nextcloud user=alice pass="$OBSCURED" --config "$RCLONE_CONFIG" >/dev/null 2>&1

# capture CMD... - run CMD, store combined output in CLI_OUT and rc in
# CLI_RC. expect_cli folds that into "run + assert rc"; the output stays in
# CLI_OUT for follow-up expect_contains checks. expect_cli_pipe does the
# same with printf '%b' INPUT on stdin (piped folder wizard).
capture() {
  CLI_OUT="$("$@" 2>&1)"
  CLI_RC=$?
}
capture_pipe() {
  local input="$1"
  shift
  CLI_OUT="$(printf '%b' "$input" | "$@" 2>&1)"
  CLI_RC=$?
}
expect_cli() {
  local name="$1" want="$2"
  shift 2
  capture "$@"
  expect_rc "$name" "$CLI_RC" "$want"
}
expect_cli_pipe() {
  local name="$1" want="$2" input="$3"
  shift 3
  capture_pipe "$input" "$@"
  expect_rc "$name" "$CLI_RC" "$want"
}

# The `local` remote has no root, so commands that browse relative remote
# paths (folders choose) must run with the cwd they are meant to see.
run_cli() { (cd "$TMP" && /bin/bash "${PROJ}/bin/sciebo" "$@"); }
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_cli_in() {
  local dir="$1"
  shift
  (cd "$dir" && /bin/bash "${PROJ}/bin/sciebo" "$@")
}
# shellcheck disable=SC2329  # invoked indirectly via expect_cli
run_shim() { (cd "$TMP" && /bin/bash "${PROJ}/scripts/sync.sh" "$@"); }
# Doctor/cleanup run against the webdav test remote; HOME is redirected so
# the launchd check never reads the real ~/Library.
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_doctor_offline() { (cd "$TMP" && env HOME="${TMP}/home" RCLONE_REMOTE=webtest /bin/bash "${PROJ}/bin/sciebo" doctor --offline); }
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_cleanup_uploads() { (cd "$TMP" && env RCLONE_REMOTE=webtest /bin/bash "${PROJ}/bin/sciebo" cleanup --uploads); }
run_schedule() { (cd "$TMP" && env HOME="${TMP}/home" /bin/bash "${PROJ}/bin/sciebo" schedule "$@"); }

# --- fixture: a workspace with nested repos and clutter -----------------
WS="${TMP}/ws"
while IFS='|' read -r path content; do
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$content" >"$path"
done <<EOF
${WS}/a/.git/HEAD|ref: refs/heads/main
${WS}/a/nested/.git/HEAD|ref: refs/heads/main
${WS}/b/.git/HEAD|ref: refs/heads/main
${WS}/a/readme.txt|hello
${WS}/a/.DS_Store|junk
${WS}/a/tmp.swp|swap
${WS}/a/node_modules/x.js|js
${WS}/a/secret/.nosync|
${WS}/a/secret/x.txt|private
${WS}/a/nested/n.txt|nested
${TMP}/src/a.txt|doc
${TMP}/notes/note.txt|note
${TMP}/backup/pulled-src/remote.txt|remote
EOF

# --- discover: nested collapse, duplicate roots, root-as-repo, failures -
printf 'sync|%s|repos|4\nsync|%s|repos|4\n' "$WS" "$WS" >"$ROOTS_FILE"
expect_cli "discover: duplicate roots rc 0" 0 run_cli discover
expect_contains "discover: repo a emitted" "$CLI_OUT" "sync|${WS}/a|repos/a"
expect_contains "discover: repo b emitted" "$CLI_OUT" "sync|${WS}/b|repos/b"
expect_not_contains "discover: nested repo collapsed" "$CLI_OUT" "repos/a/nested"
expect_contains "discover: header count" "$CLI_OUT" "# 2 repositories from 2 root(s)."
run_cli discover --write >/dev/null 2>&1
expect_file "discover: --write creates manifest" "$MANIFEST_GENERATED_FILE"
expect_eq "discover: manifest mode 644" "644" "$(stat -f '%Lp' "$MANIFEST_GENERATED_FILE" 2>/dev/null)"
printf 'sync|%s|repos|2\n' "${TMP}/does-not-exist" >"$ROOTS_FILE"
expect_cli "discover: missing root exits 1" 1 run_cli discover
expect_contains "discover: missing root warning" "$CLI_OUT" "Root does not exist"
expect_cli "discover: --write still fails rc 1" 1 run_cli discover --write
expect_file "discover: --write wrote manifest despite failure" "$MANIFEST_GENERATED_FILE"
expect_contains "discover: failed write header" "$(cat "$MANIFEST_GENERATED_FILE")" "# 0 repositories from 0 root(s)."
printf 'sync|%s|repos|4\n' "$WS" >"$ROOTS_FILE"
run_cli discover --write >/dev/null 2>&1
printf 'sync|%s|repos|4\n' "${WS}/b" >"$ROOTS_FILE"
expect_cli "discover: root-as-repo rc 0" 0 run_cli discover
expect_contains "discover: root-as-repo maps to remote_base" "$CLI_OUT" "sync|${WS}/b|repos"
: >"$ROOTS_FILE"

# --- manifest, list, dry run, apply, filters, .nosync, pull semantics ---
{
  printf 'sync|%s|manual-docs\n' "${TMP}/src"
  printf 'pull|%s|pulled-src\n' "${TMP}/pulled"
  printf 'bisync|%s|notes\n' "${TMP}/notes"
} >"$MANIFEST_FILE"
expect_cli "list: rc 0" 0 run_cli list
expect_contains "list: manual source" "$CLI_OUT" "manual-docs"
expect_contains "list: generated source" "$CLI_OUT" "repos_a"
expect_cli "sync --list: rc 0" 0 run_cli sync --list
expect_contains "sync --list: lists sources" "$CLI_OUT" "manual-docs"
expect_cli "check: rc 0 (bisync skipped, not failed)" 0 run_cli check
expect_contains "check: banner" "$CLI_OUT" "DRY RUN"
expect_contains "check: bisync skipped without remote dir" "$CLI_OUT" "remote dir does not exist yet"
expect_contains "check: pull local dir missing is reported" "$CLI_OUT" "local dir does not exist yet"
expect_no_file "check: does not create the pull local dir" "${TMP}/pulled"
expect_no_file "check: no remote data created" "${TMP}/backup/manual-docs"
expect_no_file "check: no bisync remote dir created" "${TMP}/backup/notes"

# Manifest arity regression: five pipe-separated fields is invalid.
cp "$MANIFEST_FILE" "${TMP}/manifest.arity.bak"
printf 'sync|%s|arity|extra|more\n' "${TMP}/src" >>"$MANIFEST_FILE"
expect_cli "arity: list rc 0" 0 run_cli list
expect_contains "arity: 5 fields invalid in list" "$CLI_OUT" "INVALID"
expect_contains "arity: error names the field count" "$CLI_OUT" "too many fields"
expect_cli "arity: a 5-field entry fails a run" 1 run_cli check
cp "${TMP}/manifest.arity.bak" "$MANIFEST_FILE"

# Pull regression: dry run skips a missing local dir, apply creates it.
expect_cli "pull: sync --only rc 0" 0 run_cli sync --only pulled-src
expect_file "pull: sync creates local dir and pulls" "${TMP}/pulled/remote.txt"
run_cli sync --only manual-docs >/dev/null 2>&1
expect_file "apply: manual docs synced" "${TMP}/backup/manual-docs/a.txt"
run_cli sync --only repos_a >/dev/null 2>&1
expect_file "apply: repo readme synced" "${TMP}/backup/repos/a/readme.txt"
expect_file "apply: .git synced (not git-aware)" "${TMP}/backup/repos/a/.git/HEAD"
expect_file "apply: nested repo synced with parent" "${TMP}/backup/repos/a/nested/n.txt"
expect_file "apply: node_modules kept by default filters" "${TMP}/backup/repos/a/node_modules/x.js"
expect_no_file "apply: .DS_Store filtered" "${TMP}/backup/repos/a/.DS_Store"
expect_no_file "apply: *.swp filtered" "${TMP}/backup/repos/a/tmp.swp"
expect_no_file "apply: .nosync directory excluded" "${TMP}/backup/repos/a/secret"
expect_cli "apply: full run fails on uninitialized bisync" 1 run_cli sync
expect_no_file "apply: bisync guard creates no remote dir" "${TMP}/backup/notes"

# --- bisync: resync, both directions ------------------------------------
expect_cli "bisync: --resync --apply rc 0" 0 run_cli sync --resync --apply
expect_file "bisync: local note pushed" "${TMP}/backup/notes/note.txt"
echo "from remote" >"${TMP}/backup/notes/from-remote.txt"
expect_cli "bisync: pull run rc 0" 0 run_cli sync --apply
expect_file "bisync: remote change pulled" "${TMP}/notes/from-remote.txt"
echo "from local" >"${TMP}/notes/from-local.txt"
run_cli sync --apply >/dev/null 2>&1
expect_file "bisync: local change pushed" "${TMP}/backup/notes/from-local.txt"

# --- folders wizard: add, list, excludes, remove, piped choose ----------
mkdir -p "${TMP}/backup/wizard-test" "${TMP}/backup/wizard-two/child"
echo "one" >"${TMP}/backup/wizard-test/file.txt"
echo "two" >"${TMP}/backup/wizard-two/child/file.txt"
expect_cli "folders add: pair rc 0" 0 run_cli folders add --remote wizard-test --local "${TMP}/wiz-local" --mode pull
expect_contains "folders add: line written" "$(cat "$FOLDERS_FILE")" "pull|${TMP}/wiz-local|wizard-test"
expect_cli "folders list: rc 0" 0 run_cli folders list
expect_contains "folders list: pair shown" "$CLI_OUT" "wizard-test"
expect_contains "folders list: wizard source column" "$CLI_OUT" "wizard"
expect_cli "folders: list rc 0" 0 run_cli list
expect_contains "folders: wizard pair feeds the driver" "$CLI_OUT" "wizard-test"
expect_cli "folders add: duplicate name refused" 1 run_cli folders add --remote wizard-test --local "${TMP}/wiz-local-2" --mode pull
expect_contains "folders add: duplicate mentions already" "$CLI_OUT" "already"
expect_cli "folders add: unsafe remote refused" 1 run_cli folders add --remote ../evil --local "${TMP}/x" --mode pull
expect_cli "folders add: excludes rc 0" 0 run_cli folders add --remote wizard-two --local "${TMP}/wiz-two" --mode pull --exclude child
expect_file "folders add: pair filter created" "${TMP}/filters/pair-wizard-two.txt"
expect_contains "folders add: exclude rule written" "$(cat "${TMP}/filters/pair-wizard-two.txt")" "- child/"
capture run_cli list
expect_contains "folders add: pair filter wired into the driver" "$CLI_OUT" "pair-wizard-two.txt"
expect_cli "folders remove: rc 0" 0 run_cli folders remove wizard-two
expect_not_contains "folders remove: pair line dropped" "$(cat "$FOLDERS_FILE")" "wizard-two"
expect_cli "folders remove: unknown name refused" 1 run_cli folders remove nope

# A failed add must not leave a pair filter behind (the remote check runs
# before any file is written).
expect_cli "folders add: missing remote refused" 1 run_cli folders add --remote missing-remote --local "${TMP}/missing-local" --mode pull --exclude sub
expect_contains "folders add: missing remote message" "$CLI_OUT" "not found"
expect_no_file "folders add: missing remote leaves no orphan filter" "${TMP}/filters/pair-missing-remote.txt"

# Sanitized-name collision: `collide/a` and `collide_a` both map to the
# name `collide_a`; the second add is refused by the name check.
mkdir -p "${TMP}/backup/collide/a"
expect_cli "folders add: first colliding pair rc 0" 0 run_cli folders add --remote collide/a --local "${TMP}/col-1" --mode pull
expect_cli "folders add: sanitized-name collision refused" 1 run_cli folders add --remote collide_a --local "${TMP}/col-2" --mode pull
expect_contains "folders add: collision message" "$CLI_OUT" "already exists"

# Piped choose in a controlled cwd: the local remote resolves relative to
# the cwd, so this mini-remote offers only alpha and beta.
mkdir -p "${TMP}/cwd2/backup/alpha" "${TMP}/cwd2/backup/beta"
cp "$FOLDERS_FILE" "${TMP}/folders.choose.before"
expect_cli_pipe "folders choose: abort rc 0" 0 '1\n\nn\nn\n' run_cli_in "${TMP}/cwd2" folders choose \
  --no-fzf --no-dry-run --mode pull --local-root "${TMP}/picked-a"
expect_contains "folders choose: aborted" "$CLI_OUT" "aborted"
expect_same "folders choose: abort leaves FOLDERS_FILE unchanged" "${TMP}/folders.choose.before" "$FOLDERS_FILE"
expect_cli_pipe "folders choose: add rc 0" 0 '1\n\nn\ny\n' run_cli_in "${TMP}/cwd2" folders choose \
  --no-fzf --no-dry-run --mode pull --local-root "${TMP}/picked-b"
expect_contains "folders choose: chosen pair written" "$(cat "$FOLDERS_FILE")" "pull|${TMP}/picked-b/alpha|alpha"
cp "$FOLDERS_FILE" "${TMP}/folders.choose.after"
expect_cli "folders choose: EOF fails" 1 run_cli_in "${TMP}/cwd2" folders choose --no-fzf </dev/null
expect_same "folders choose: EOF leaves FOLDERS_FILE unchanged" "${TMP}/folders.choose.after" "$FOLDERS_FILE"

# Pending-selection collision: `coll` and `coll/a` are offered, but
# `coll_a` sanitizes to the same name as `coll/a`; the second pick is
# skipped while the selection is applied, so no partial pair is written.
mkdir -p "${TMP}/cwd3/backup/coll/a" "${TMP}/cwd3/backup/coll_a"
expect_cli_pipe "folders choose: pending collision rc 0" 0 'all\n\nn\n\nn\ny\n' run_cli_in "${TMP}/cwd3" \
  folders choose --no-fzf --no-dry-run --depth 2 --mode pull --local-root "${TMP}/picked-c"
expect_contains "folders choose: pending collision skipped" "$CLI_OUT" "already in this selection"
expect_contains "folders choose: first colliding pair written" "$(cat "$FOLDERS_FILE")" "|coll/a"
expect_not_contains "folders choose: colliding duplicate not written" "$(cat "$FOLDERS_FILE")" "|coll_a"

# --- compatibility shim: scripts/sync.sh maps onto the CLI --------------
# Regression: bash 3.2 errors on expanding an empty array under `set -u`,
# so the shim must guard every "${args[@]}" expansion.
capture run_shim
if [[ "$CLI_RC" -eq 0 ]]; then
  pass "shim: no flags is a dry run rc 0"
  expect_contains "shim: no flags banner" "$CLI_OUT" "DRY RUN"
else
  fail "shim: no flags is a dry run rc 0" "rc ${CLI_RC}: ${CLI_OUT}"
fi
echo "shim" >"${TMP}/src/shim-apply.txt"
expect_cli "shim: --apply --only applies rc 0" 0 run_shim --apply --only manual-docs
expect_file "shim: --apply --only transferred the change" "${TMP}/backup/manual-docs/shim-apply.txt"
capture run_shim --list
if [[ "$CLI_RC" -eq 0 ]]; then
  pass "shim: --list lists rc 0"
  expect_contains "shim: --list shows sources" "$CLI_OUT" "manual-docs"
else
  fail "shim: --list lists rc 0" "rc ${CLI_RC}: ${CLI_OUT}"
fi

# --- mounts: recorded-state plumbing and usage errors (no real mounting) -
expect_cli "mounts: rc 0" 0 run_cli mounts
expect_contains "mounts: no mounts recorded" "$CLI_OUT" "no rclone mounts"
expect_cli "umount --all: rc 0 without state" 0 run_cli umount --all
expect_cli "mount --help: rc 0" 0 run_cli mount --help
expect_cli "mount bogus: usage error rc 2" 2 run_cli mount bogus

# Seeded state only: no real mount, a dead recorded pid, no kill target.
mkdir -p "${STATE_DIR}/mounts"
printf 'demo\n%s\n999999\nno\n' "${TMP}/mnt-demo" >"${STATE_DIR}/mounts/demo.state"
expect_cli "mounts: seeded state rc 0" 0 run_cli mounts
expect_contains "mounts: seeded record folder" "$CLI_OUT" "demo"
expect_contains "mounts: seeded record mounted=no" "$CLI_OUT" "mounted=no"
expect_contains "mounts: seeded record alive=no" "$CLI_OUT" "alive=no"
expect_cli "umount: recorded folder rc 0" 0 run_cli umount --folder demo
expect_no_file "umount: state file removed" "${STATE_DIR}/mounts/demo.state"

# A failed unmount keeps the record for a retry. umount is stubbed and the
# mountpoint "/" is guaranteed to be visible in `mount`, so no real unmount
# is attempted.
STUB_BIN="${TMP}/stub-bin"
mkdir -p "$STUB_BIN"
printf '#!/bin/bash\nexit 1\n' >"$STUB_BIN/umount"
chmod +x "$STUB_BIN/umount"
printf 'demo-fail\n/\n-\nno\n' >"${STATE_DIR}/mounts/demo-fail.state"
PATH="$STUB_BIN:$PATH" expect_cli "umount: failed unmount rc 1" 1 run_cli umount --folder demo-fail
expect_contains "umount: failure keeps the state for a retry" "$CLI_OUT" "keeping its state"
expect_file "umount: failed unmount keeps the state file" "${STATE_DIR}/mounts/demo-fail.state"
rm -f "${STATE_DIR}/mounts/demo-fail.state"
expect_cli "usage: cleanup without a selector rc 2" 2 run_cli cleanup
expect_cli "usage: cleanup --bogus rc 2" 2 run_cli cleanup --bogus
expect_cli "usage: unknown command rc 2" 2 run_cli bogus

# --- guards: unsafe entries, REMOTE_BASE, --only, and the run lock ------
cp "$MANIFEST_FILE" "${TMP}/manifest.guards.bak"
printf 'sync|%s|../evil\n' "${TMP}/src" >>"$MANIFEST_FILE"
capture run_cli list
expect_contains "guard: unsafe remote subdir flagged" "$CLI_OUT" "INVALID"
expect_cli "guard: unsafe entry fails a run" 1 run_cli check
cp "${TMP}/manifest.guards.bak" "$MANIFEST_FILE"
REMOTE_BASE='' expect_cli "guard: empty REMOTE_BASE falls back to the default" 0 run_cli list
expect_contains "guard: default remote base used" "$CLI_OUT" "testremote:backup/"
REMOTE_BASE=../x expect_cli "guard: unsafe REMOTE_BASE dies" 1 run_cli list
expect_cli "guard: --only unknown rc 1" 1 run_cli check --only no-such-source
expect_contains "guard: --only unknown names the source" "$CLI_OUT" "No source named"

# Stale lock (dead pid): taken over with a warning, the run succeeds.
mkdir -p "${STATE_DIR}/locks/sync.lock"
printf '999999\n' >"${STATE_DIR}/locks/sync.lock/pid"
expect_cli "lock: stale lock taken over, run succeeds" 0 run_cli check --only manual-docs
expect_contains "lock: stale takeover warns" "$CLI_OUT" "Removing stale lock"
expect_no_file "lock: released after the run" "${STATE_DIR}/locks/sync.lock"

# Live-looking holder (argv contains bin/sciebo): refusal, and --no-lock
# bypasses it.
holder_start "${TMP}/holder/bin/sciebo"
holder_ready="$(holder_wait "$HOLDER_PID")"
expect_rc "lock: holder process matches the tool" "$holder_ready" 1
mkdir -p "${STATE_DIR}/locks/sync.lock"
printf '%s\n' "$HOLDER_PID" >"${STATE_DIR}/locks/sync.lock/pid"
expect_cli "lock: live holder refuses the run" 1 run_cli check --only manual-docs
expect_contains "lock: refusal message" "$CLI_OUT" "Another sync run is active"
expect_cli "lock: --no-lock bypasses a live-looking lock" 0 run_cli check --no-lock --only manual-docs
kill "$HOLDER_PID" 2>/dev/null || true
wait "$HOLDER_PID" 2>/dev/null || true
HOLDER_PID=""
rm -rf "${STATE_DIR}/locks/sync.lock"

# --- list is read-only: it must not create state directories ------------
fresh="${TMP}/state-list-isolation"
STATE_DIR="$fresh" expect_cli "list: rc 0 with a fresh STATE_DIR" 0 run_cli list
expect_contains "list: prints sources" "$CLI_OUT" "manual-docs"
expect_no_file "list: does not create logs dir" "${fresh}/logs"
expect_no_file "list: does not create locks dir" "${fresh}/locks"
expect_no_file "list: does not create bisync dir" "${fresh}/bisync"
expect_no_file "list: does not create the state dir" "$fresh"

# --- --quiet: no OK rows, but failures and the summary still print ------
cp "$MANIFEST_FILE" "${TMP}/manifest.quiet.bak"
printf 'sync|%s|quiet-missing\n' "${TMP}/does-not-exist" >>"$MANIFEST_FILE"
expect_cli "quiet: failing run rc 1" 1 run_cli sync --quiet --dry-run
expect_not_contains "quiet: no OK rows" "$CLI_OUT" "OK "
expect_contains "quiet: failures still print" "$CLI_OUT" "FAIL"
expect_contains "quiet: summary still prints" "$CLI_OUT" "Summary:"
cp "${TMP}/manifest.quiet.bak" "$MANIFEST_FILE"

# --- duplicate entry names: warning on runs, failure in doctor ----------
# NOTE: sanitize_name keeps '-' and '_' distinct, so "dup-x"/"dup_x" would
# NOT collide. Use 'dup/x' (folders.conf) and 'dup_x' (sources.conf).
cp "$MANIFEST_FILE" "${TMP}/manifest.dup.bak"
cp "$FOLDERS_FILE" "${TMP}/folders.dup.bak"
mkdir -p "${TMP}/dup-local-a" "${TMP}/dup-local-b"
printf 'sync|%s|dup_x\n' "${TMP}/dup-local-a" >>"$MANIFEST_FILE"
printf 'sync|%s|dup/x\n' "${TMP}/dup-local-b" >>"$FOLDERS_FILE"
expect_cli "duplicates: check warns but exits 0" 0 run_cli check
expect_contains "duplicates: check warns about the name" "$CLI_OUT" "duplicate source name"
expect_cli "duplicates: doctor --offline fails rc 1" 1 run_doctor_offline
expect_contains "duplicates: doctor reports the duplicate" "$CLI_OUT" "duplicate source name 'dup_x'"
cp "${TMP}/manifest.dup.bak" "$MANIFEST_FILE"
cp "${TMP}/folders.dup.bak" "$FOLDERS_FILE"

# --- config dump parsing (regression: config show redacts passwords) ----
rclone config create dumpremote webdav url="http://127.0.0.1:9/remote.php/dav/files/alice/" \
  vendor=other user=alice pass="$OBSCURED" --config "$RCLONE_CONFIG" >/dev/null 2>&1
# shellcheck disable=SC2016  # single quotes are intentional inside bash -c
got="$(
  env PROJ_PATH="$PROJ" /bin/bash -c '
    source "${PROJ_PATH}/lib/core.sh"
    source "${PROJ_PATH}/lib/rclone.sh"
    source "${PROJ_PATH}/lib/settings.sh"
    load_settings --no-rclone
    dump="$(remote_config_dump)"
    config_dump_value dumpremote pass "$dump"
  '
)"
expect_eq "config dump: obscured pass extracted" "$OBSCURED" "$got"

# --- setup: URL normalization (validation fails fast against a dead port)
# shellcheck disable=SC2030,SC2031  # per-run overrides live in a subshell
SCIEBO_URL="http://127.0.0.1:9" SCIEBO_USER="alice@example.org" \
  SCIEBO_APP_PASSWORD="integration-secret" RCLONE_REMOTE=setuptest \
  expect_cli "setup: dead endpoint fails validation" 1 run_cli setup
expect_contains "setup: warns about http" "$CLI_OUT" "plain http"
dump="$(rclone --config "$RCLONE_CONFIG" config dump 2>/dev/null)"
expect_contains "setup: url normalized" "$dump" "http://127.0.0.1:9/remote.php/dav/files/alice@example.org/"
expect_not_contains "setup: plaintext password not stored" "$dump" "integration-secret"

# --- cleanup: logs and uploads plumbing ---------------------------------
mkdir -p "${STATE_DIR}/logs"
old_log="${STATE_DIR}/logs/old-test.log"
touch -t 202001010000 "$old_log"
expect_cli "cleanup logs: dry run rc 0" 0 run_cli cleanup --logs
expect_contains "cleanup logs: would delete" "$CLI_OUT" "would delete"
expect_file "cleanup logs: dry run keeps file" "$old_log"
run_cli cleanup --logs --apply >/dev/null 2>&1
expect_no_file "cleanup logs: apply deletes file" "$old_log"
expect_cli "cleanup uploads: unreachable endpoint fails" 1 run_cleanup_uploads
expect_not_contains "cleanup uploads: credentials parsed from dump" "$CLI_OUT" "not fully configured"
expect_contains "cleanup uploads: uploads url derived" "$CLI_OUT" "/uploads/alice/"

# --- doctor: filter validation failure, then a healthy offline report ---
printf -- '- [\n' >"${FILTER_DIR}/pair-broken.txt"
expect_cli "doctor filters: broken filter fails rc 1" 1 run_doctor_offline
expect_contains "doctor filters: rclone rejects the file" "$CLI_OUT" "rclone rejects filter file"
rm -f "${FILTER_DIR}/pair-broken.txt"
expect_cli "doctor offline: healthy config rc 0" 0 run_doctor_offline
expect_contains "doctor offline: filter validation passed" "$CLI_OUT" "rclone filter validation passed"
expect_not_contains "doctor offline: no failures" "$CLI_OUT" "FAIL"

# --- schedule: status is read-only; install stays opt-in ----------------
mkdir -p "${TMP}/home"
plist="${TMP}/home/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"
expect_cli "schedule: status not installed rc 0" 0 run_schedule status
expect_contains "schedule: not installed" "$CLI_OUT" "not installed"
expect_no_file "schedule: no plist written" "$plist"
mkdir -p "$(dirname "$plist")"
printf '<?xml version="1.0"?><plist><string>%s/scripts/sync.sh</string></plist>\n' "$PROJ" >"$plist"
expect_cli "schedule: old-format plist rc 1" 1 run_schedule status
expect_contains "schedule: old entrypoint warning" "$CLI_OUT" "old scripts/sync.sh entrypoint"
expect_contains "schedule: reported as installed but not loaded" "$CLI_OUT" "installed but not loaded"
rm -f "$plist"
if [[ "${INTEGRATION_LAUNCHD:-0}" == "1" ]]; then
  run_schedule install >/dev/null 2>&1
  expect_file "schedule: opt-in install" "$plist"
  run_schedule uninstall >/dev/null 2>&1
  expect_no_file "schedule: opt-in uninstall" "$plist"
else
  printf 'SKIP  schedule: launchd install/uninstall (set INTEGRATION_LAUNCHD=1 to enable)\n'
fi

# --- isolation proof: the real project config was never written to ------
CONFIG_SNAPSHOT_AFTER="$(config_snapshot)"
if [[ "$CONFIG_SNAPSHOT_BEFORE" == "$CONFIG_SNAPSHOT_AFTER" ]]; then
  pass "isolation: real config/folders.conf and config/filters/ untouched"
else
  fail "isolation: real project config changed" "content shasums differ"
fi
finish
