#!/usr/bin/env bash
# integration.sh - end-to-end tests for the sciebo CLI.
# Run from any directory: bash tests/integration.sh
#
# Isolation: the CLI runs as `bash "$PROJ/bin/sciebo" ...` (Bash
# 5.3) against a temporary `local` rclone remote; every path override
# (STATE_DIR, manifests, filters, ...) points into a fresh mktemp directory.
# The real remote, rclone config, config/folders.conf, config/filters/ and
# launchd are never modified; launchd install/uninstall stays opt-in behind
# INTEGRATION_LAUNCHD=1. Without rclone the suite prints SKIP and exits 0.
#
# The suite runs on macOS and Linux. Platform backends are pinned through the
# CLI's SCIEBO_* test hooks (osascript, security, launchd), `stat`/`mount`
# output gets a portable fallback, and checks that cannot run on a platform
# print a SKIP line instead of failing silently.
#
# INTEGRATION_TARGET=real dispatches to tests/contract/real-smoke.sh instead:
# a tagged command subset run against a real Nextcloud (NC_URL/NC_USER/
# NC_APPPASS, from tests/contract/nextcloud-up.sh) rather than the `local`
# rclone remote this file uses below. Default (fake/local) mode is entirely
# unaffected by this branch.
set -uo pipefail
INTEGRATION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$(cd "${INTEGRATION_DIR}/.." && pwd)"
if [[ "${INTEGRATION_TARGET:-}" == "real" ]]; then
  exec bash "${INTEGRATION_DIR}/contract/real-smoke.sh"
fi
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
  # Remove temp paths registered by sourced modules (e.g. policy.sh's scan
  # cache) so the suite leaves nothing behind in TMPDIR.
  if type -t sciebo_temp_cleanup >/dev/null 2>&1; then
    sciebo_temp_cleanup || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

# shellcheck source-path=SCRIPTDIR
# shellcheck source=harness.sh
source "${INTEGRATION_DIR}/harness.sh"
# file_mode/file_mtime/file_stamp come from the portable core helpers, which
# probe stat(1) once for the BSD vs GNU spelling instead of hardcoding one.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/core.sh
source "${PROJ}/lib/core.sh"

# Isolation: state, manifests, filters, and the remote live under $TMP.
# TRANSFERS/RETRIES/CONTIMEOUT are the CLI's own settings (turned into
# rclone flags), so dead-endpoint tests fail fast instead of hanging.
export RCLONE_REMOTE=testremote RCLONE_CONFIG="${TMP}/rclone.conf" REMOTE_BASE=backup \
  STATE_DIR="${TMP}/state" SETTINGS_LOCAL_FILE="${TMP}/no-local.env" ENV_FILE="${TMP}/no-env.env" \
  MANIFEST_FILE="${TMP}/sources.conf" MANIFEST_GENERATED_FILE="${TMP}/sources.generated.conf" \
  ROOTS_FILE="${TMP}/roots.conf" FOLDERS_FILE="${TMP}/folders.conf" FILTER_DIR="${TMP}/filters" \
  LAUNCHD_LABEL="de.rclone-sciebo.sync.integrationtest" \
  KEYCHAIN=0 NOTIFY=0 \
  TRANSFERS=1 RETRIES=1 LOW_LEVEL_RETRIES=1 CONTIMEOUT=1s TIMEOUT=10s
mkdir -p "$FILTER_DIR"
# Empty wizard manifest: assertions must not depend on config/folders.conf.
: >"$FOLDERS_FILE"
cp "${PROJ}/config/filters/clutter.txt" "$FILTER_DIR/clutter.txt"

# Content snapshot of the real project config, compared at the end to prove
# isolation (content, not just file names).
# snapshot_hash FILE - stable content hash; `shasum` on macOS,
# `sha1sum`/`cksum` on Linux. Only before/after equality matters.
snapshot_hash() {
  if command -v shasum >/dev/null 2>&1; then
    shasum "$1"
  elif command -v sha1sum >/dev/null 2>&1; then
    sha1sum "$1"
  else
    cksum "$1"
  fi
}
config_snapshot() {
  local file
  find "${PROJ}/config/filters" -type f | LC_ALL=C sort | while IFS= read -r file; do
    snapshot_hash "$file"
  done
  snapshot_hash "${PROJ}/config/folders.conf"
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
run_cli() { (cd "$TMP" && bash "${PROJ}/bin/sciebo" "$@"); }
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_cli_in() {
  local dir="$1"
  shift
  (cd "$dir" && bash "${PROJ}/bin/sciebo" "$@")
}
# shellcheck disable=SC2329  # invoked indirectly via expect_cli
run_shim() { (cd "$TMP" && bash "${PROJ}/scripts/sync.sh" "$@"); }
# Doctor/cleanup run against the webdav test remote; HOME is redirected so
# the launchd check never reads the real ~/Library.
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_doctor_offline() { (cd "$TMP" && env HOME="${TMP}/home" RCLONE_REMOTE=webtest bash "${PROJ}/bin/sciebo" doctor --offline); }
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_cleanup_uploads() { (cd "$TMP" && env RCLONE_REMOTE=webtest bash "${PROJ}/bin/sciebo" cleanup --uploads); }
# SCIEBO_SCHEDULER_BACKEND pins launchd: the assertions below cover the plist
# lifecycle, and on Linux the probe would otherwise pick systemd/cron/none.
# Real launchd install/uninstall stays opt-in via INTEGRATION_LAUNCHD.
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_schedule() { (cd "$TMP" && env HOME="${TMP}/home" SCIEBO_SCHEDULER_BACKEND=launchd bash "${PROJ}/bin/sciebo" schedule "$@"); }

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
expect_eq "discover: manifest mode 644" "644" "$(file_mode "$MANIFEST_GENERATED_FILE")"
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
# A root that is itself a repository and whose path holds a tab cannot be
# represented in the pipe/tab-sensitive manifest; it is skipped with a
# warning and fails the run.
WS_TAB="${TMP}/ws	tab"
mkdir -p "${WS_TAB}/.git"
printf 'sync|%s|repos|4\n' "$WS_TAB" >"$ROOTS_FILE"
expect_cli "discover: unrepresentable repo path rc 1" 1 run_cli discover
expect_contains "discover: unrepresentable path warned" "$CLI_OUT" "Unrepresentable repository path"
expect_not_contains "discover: unrepresentable path not emitted" "$CLI_OUT" "|${WS_TAB}|"
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

# --- plan output: dry runs summarize copies/deletes ---------------------
# Log names use second granularity and rclone appends to an existing log,
# so clear this entry's dry-run logs before each assertion instead of
# depending on distinct timestamps.
printf 'plan-extra\n' >"${TMP}/src/plan-extra.txt"
printf 'plan-stale\n' >"${TMP}/backup/manual-docs/plan-stale.txt"
rm -f "${STATE_DIR}"/logs/manual-docs-*-dryrun.log
expect_cli "plan: dry run rc 0" 0 run_cli check --only manual-docs
expect_contains "plan: copy and delete counted" "$CLI_OUT" "plan: 1 to copy, 1 to delete"
run_cli sync --only manual-docs >/dev/null 2>&1
expect_file "plan: added file applied" "${TMP}/backup/manual-docs/plan-extra.txt"
expect_no_file "plan: remote deletion applied" "${TMP}/backup/manual-docs/plan-stale.txt"
rm -f "${STATE_DIR}"/logs/manual-docs-*-dryrun.log
expect_cli "plan: dry run after applying rc 0" 0 run_cli check --only manual-docs
expect_contains "plan: no changes after applying" "$CLI_OUT" "plan: no changes"

# --- pause gate: sync/check skip until resumed, --force bypasses ---------
expect_cli "pause: --for 1h rc 0" 0 run_cli pause --for 1h
# epoch_to_stamp formats through the Bash printf strftime builtin first, so
# the resume label is produced on both macOS and Linux.
expect_contains "pause: reports the resume time" "$CLI_OUT" "paused until"
expect_file "pause: marker written" "${STATE_DIR}/paused"
expect_cli "pause: check rc 0 while paused" 0 run_cli check
expect_contains "pause: check prints the paused line" "$CLI_OUT" "is paused"
expect_not_contains "pause: check does not run while paused" "$CLI_OUT" "DRY RUN"
expect_cli "pause: check --force bypasses the gate" 0 run_cli check --force
expect_contains "pause: forced check runs" "$CLI_OUT" "DRY RUN"
expect_cli "resume: rc 0" 0 run_cli resume
expect_contains "resume: reports resumed" "$CLI_OUT" "resumed"
expect_no_file "resume: marker removed" "${STATE_DIR}/paused"
expect_cli "resume: check runs again" 0 run_cli check
expect_contains "resume: check runs" "$CLI_OUT" "DRY RUN"

# --- sync knobs: recorded argv from a stub rclone -----------------------
# The stub satisfies the preflight calls (version, listremotes) and records
# the full argv of the sync call; it never creates the log file the CLI
# passes, which is fine because apply runs do not read it back.
SYNC_STUB_RCLONE="${TMP}/stub-rclone-sync"
SYNC_STUB_LOG="${TMP}/stub-rclone-sync.argv"
cat >"$SYNC_STUB_RCLONE" <<'STUB'
#!/bin/bash
for arg in "$@"; do
  case "$arg" in
    listremotes)
      printf 'testremote:\n'
      exit 0
      ;;
    version)
      printf 'rclone v1.75.1\n'
      exit 0
      ;;
    sync)
      printf '%s\n' "$*" >>"$SYNC_STUB_LOG"
      exit 0
      ;;
  esac
done
exit 0
STUB
chmod +x "$SYNC_STUB_RCLONE"
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_sync_stub() {
  (cd "$TMP" && env RCLONE_BIN="${SYNC_STUB_RCLONE}" SYNC_STUB_LOG="${SYNC_STUB_LOG}" \
    bash "${PROJ}/bin/sciebo" "$@")
}
: >"$SYNC_STUB_LOG"
CREATE_EMPTY_SRC_DIRS=1 MAX_DELETE=7 TRACK_RENAMES=1 BW_LIMIT_UP=1M BW_LIMIT_DOWN=off \
  expect_cli "sync knobs: stub run rc 0" 0 run_sync_stub sync --only manual-docs
knob_argv="$(cat "$SYNC_STUB_LOG")"
expect_contains "sync knobs: --create-empty-src-dirs recorded" "$knob_argv" "--create-empty-src-dirs"
expect_contains "sync knobs: --max-delete recorded" "$knob_argv" "--max-delete 7"
expect_contains "sync knobs: --track-renames recorded" "$knob_argv" "--track-renames"
expect_contains "sync knobs: --bwlimit recorded" "$knob_argv" "--bwlimit 1M:off"
: >"$SYNC_STUB_LOG"
expect_cli "sync knobs: default stub run rc 0" 0 run_sync_stub sync --only manual-docs
knob_argv="$(cat "$SYNC_STUB_LOG")"
expect_not_contains "sync knobs: no --create-empty-src-dirs by default" "$knob_argv" "--create-empty-src-dirs"
expect_contains "sync knobs: delete guard by default" "$knob_argv" "--max-delete 100"
expect_not_contains "sync knobs: no --track-renames by default" "$knob_argv" "--track-renames"
expect_not_contains "sync knobs: no --bwlimit by default" "$knob_argv" "--bwlimit"
: >"$SYNC_STUB_LOG"
ASK_DELETE=0 expect_cli "sync knobs: delete guard off rc 0" 0 run_sync_stub sync --only manual-docs
knob_argv="$(cat "$SYNC_STUB_LOG")"
expect_not_contains "sync knobs: no --max-delete with ASK_DELETE=0" "$knob_argv" "--max-delete"

# --- runstate: per-entry last-run records --------------------------------
run_cli sync --only manual-docs >/dev/null 2>&1
ok_record="${STATE_DIR}/last/manual-docs"
expect_file "runstate: successful sync writes a record" "$ok_record"
expect_eq "runstate: record mode 600" "600" "$(file_mode "$ok_record")"
expect_contains "runstate: success recorded as ok" "$(cat "$ok_record")" "status=ok"
expect_contains "runstate: success records mode" "$(cat "$ok_record")" "mode=sync"
expect_contains "runstate: success records rc 0" "$(cat "$ok_record")" "rc=0"

cp "$MANIFEST_FILE" "${TMP}/manifest.runstate.bak"
printf 'sync|%s|missing-local\n' "${TMP}/no-such-local-dir" >>"$MANIFEST_FILE"
expect_cli "runstate: failing sync rc 1" 1 run_cli sync --only missing-local
failed_record="${STATE_DIR}/last/missing-local"
expect_file "runstate: failing sync writes a record" "$failed_record"
expect_contains "runstate: failure recorded as failed" "$(cat "$failed_record")" "status=failed"
expect_contains "runstate: failure records rc 1" "$(cat "$failed_record")" "rc=1"

# --- notifications: a stubbed osascript records the argv of each call ----
# SCIEBO_NOTIFY_BACKEND pins the osascript backend so the same stub drives
# the assertions on Linux, where the CLI would otherwise select notify-send.
NOTIFY_STUB_BIN="${TMP}/notify-bin"
mkdir -p "$NOTIFY_STUB_BIN"
cat >"${NOTIFY_STUB_BIN}/osascript" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$(dirname "$0")/calls.log"
exit 0
STUB
chmod +x "${NOTIFY_STUB_BIN}/osascript"
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_cli_notify() {
  (cd "$TMP" && env PATH="${NOTIFY_STUB_BIN}:$PATH" SCIEBO_NOTIFY_BACKEND=osascript \
    bash "${PROJ}/bin/sciebo" "$@")
}
rm -f "${NOTIFY_STUB_BIN}/calls.log"
NOTIFY=1 expect_cli "notifications: failing apply rc 1" 1 run_cli_notify sync --apply --only missing-local
notify_calls="$(cat "${NOTIFY_STUB_BIN}/calls.log" 2>/dev/null)"
expect_contains "notifications: failure title sent" "$notify_calls" "sciebo sync failed"
expect_contains "notifications: failure names the source" "$notify_calls" "missing-local"

rm -f "${NOTIFY_STUB_BIN}/calls.log"
NOTIFY=1 NOTIFY_SUCCESS=0 expect_cli "notifications: silent success rc 0" 0 run_cli_notify sync --apply --only manual-docs
expect_no_file "notifications: NOTIFY_SUCCESS=0 stays silent" "${NOTIFY_STUB_BIN}/calls.log"

rm -f "${NOTIFY_STUB_BIN}/calls.log"
NOTIFY=1 NOTIFY_SUCCESS=1 expect_cli "notifications: success notify rc 0" 0 run_cli_notify sync --apply --only manual-docs
notify_calls="$(cat "${NOTIFY_STUB_BIN}/calls.log" 2>/dev/null)"
expect_contains "notifications: success title sent" "$notify_calls" "sciebo sync finished"
expect_contains "notifications: success message counts sources" "$notify_calls" "1 source(s) ok"

# --- status: ok/failed/never/invalid rows, --only, and --quiet -----------
printf 'sync|%s|never-ran\n' "${TMP}/src" >>"$MANIFEST_FILE"
printf 'sync|only two fields\n' >>"$MANIFEST_FILE"
expect_cli "status: rc 0" 0 run_cli status
expect_contains "status: pause header" "$CLI_OUT" "not paused"
ok_state="$(printf '%s\n' "$CLI_OUT" | awk '$1 == "manual-docs" { print $3 }')"
expect_eq "status: manual-docs row is OK" "OK" "$ok_state"
failed_state="$(printf '%s\n' "$CLI_OUT" | awk '$1 == "missing-local" { print $3 }')"
expect_eq "status: missing-local row is FAILED" "FAILED" "$failed_state"
never_state="$(printf '%s\n' "$CLI_OUT" | awk '$1 == "never-ran" { print $3 }')"
expect_eq "status: never-ran row is never" "never" "$never_state"
expect_contains "status: invalid row" "$CLI_OUT" "INVALID"
expect_contains "status: summary" "$CLI_OUT" "Summary:"
expect_cli "status --only: rc 0" 0 run_cli status --only manual-docs
expect_contains "status --only: shows the selected source" "$CLI_OUT" "manual-docs"
expect_not_contains "status --only: hides other sources" "$CLI_OUT" "missing-local"
expect_cli "status --only: unknown source rc 1" 1 run_cli status --only nope
expect_contains "status --only: unknown source message" "$CLI_OUT" "no source named"
expect_cli "status --quiet: rc 0" 0 run_cli status --quiet
expect_not_contains "status --quiet: hides OK rows" "$CLI_OUT" "OK"
expect_contains "status --quiet: keeps FAILED rows" "$CLI_OUT" "FAILED"
cp "${TMP}/manifest.runstate.bak" "$MANIFEST_FILE"

# --- cleanup --state: stale bisync dirs, locks, tmp files, mounts --------
mkdir -p "${STATE_DIR}/bisync" "${STATE_DIR}/locks" "${STATE_DIR}/mounts"
stale_bisync="${STATE_DIR}/bisync/stale-workdir"
used_bisync="${STATE_DIR}/bisync/manual-docs"
# Six characters after ".tmp." so the file matches cleanup's narrowed
# atomic_write staging glob (*.tmp.??????).
tmp_file="${STATE_DIR}/leftover.tmp.abc123"
stale_lock="${STATE_DIR}/locks/sync.lock.stale.1"
dead_state="${STATE_DIR}/mounts/dead.state"
mkdir -p "$stale_bisync" "$used_bisync" "$stale_lock"
printf 'junk\n' >"$tmp_file"
printf 'keep\n' >"${stale_bisync}/marker"
printf 'keep\n' >"${used_bisync}/marker"
printf 'dead\n%s\n999999\nno\n' "${TMP}/no-such-mountpoint" >"$dead_state"
touch -t 202001010000 "$stale_bisync" "$used_bisync" "$tmp_file" "$stale_lock" "$dead_state"
expect_cli "cleanup state: dry run rc 0" 0 run_cli cleanup --state
expect_contains "cleanup state: stale bisync workdir reported" "$CLI_OUT" "would remove ${stale_bisync}"
expect_contains "cleanup state: stale lock reported" "$CLI_OUT" "would remove ${stale_lock}"
expect_contains "cleanup state: temp file reported" "$CLI_OUT" "would remove ${tmp_file}"
expect_contains "cleanup state: orphaned mount state reported" "$CLI_OUT" "would remove ${dead_state}"
expect_not_contains "cleanup state: manifest-used bisync dir kept" "$CLI_OUT" "would remove ${used_bisync}"
expect_file "cleanup state: dry run keeps the stale fixture" "${stale_bisync}/marker"
expect_cli "cleanup state: apply rc 0" 0 run_cli cleanup --state --apply
expect_no_file "cleanup state: apply removes stale bisync workdir" "$stale_bisync"
expect_no_file "cleanup state: apply removes stale lock" "$stale_lock"
expect_no_file "cleanup state: apply removes temp file" "$tmp_file"
expect_no_file "cleanup state: apply removes orphaned mount state" "$dead_state"
expect_file "cleanup state: apply keeps manifest-used bisync dir" "${used_bisync}/marker"
rm -rf "$used_bisync"

# --- verify: read-only consistency check --------------------------------
expect_cli "verify: matching source rc 0" 0 run_cli verify --only manual-docs
expect_contains "verify: OK row" "$CLI_OUT" "OK   sync"
# The other manifest entries are counted as skipped by --only, so only the
# selected source's ok/failed counts are pinned here.
expect_contains "verify: clean summary" "$CLI_OUT" "Summary: 1 sources (1 ok, 0 failed"
printf 'unsynced\n' >"${TMP}/src/verify-extra.txt"
expect_cli "verify: differing source rc 1" 1 run_cli verify --only manual-docs
expect_contains "verify: FAIL row" "$CLI_OUT" "FAIL"
expect_contains "verify: names the differing file" "$CLI_OUT" "verify-extra.txt"
rm -f "${TMP}/src/verify-extra.txt"
expect_cli "verify: unknown source rc 1" 1 run_cli verify --only unknown
expect_contains "verify: unknown source message" "$CLI_OUT" "No source named"
cp "$MANIFEST_FILE" "${TMP}/manifest.verify.bak"
rm -rf "${TMP}/verify-pull-missing"
printf 'pull|%s|verify-pull\n' "${TMP}/verify-pull-missing" >>"$MANIFEST_FILE"
expect_cli "verify: missing pull local dir rc 0" 0 run_cli verify --only verify-pull
expect_contains "verify: missing pull local dir skipped" "$CLI_OUT" "SKIP"
expect_contains "verify: skip reason" "$CLI_OUT" "local dir does not exist yet"
expect_contains "verify: skip summary" "$CLI_OUT" "Summary: 1 sources (0 ok, 0 failed"
cp "${TMP}/manifest.verify.bak" "$MANIFEST_FILE"
verify_fresh="${TMP}/state-verify-isolation"
STATE_DIR="$verify_fresh" expect_cli "verify: fresh STATE_DIR rc 0" 0 run_cli verify --only manual-docs
expect_no_file "verify: does not create the state dir" "$verify_fresh"
expect_no_file "verify: does not create the logs dir" "${verify_fresh}/logs"
expect_no_file "verify: does not create the locks dir" "${verify_fresh}/locks"

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

# --- conflicts: a real bisync conflict creates conflict copies ----------
# A temporary pair in FOLDERS_FILE gets resynced, then the same file is
# changed on both sides; the incremental run (no --resync) must report the
# conflict rename. A second unchanged file keeps rclone's "all files were
# changed" abort away.
CONFLICT_LOCAL="${TMP}/conflict-local"
CONFLICT_REMOTE="${TMP}/backup/conflict-pair"
mkdir -p "$CONFLICT_LOCAL" "$CONFLICT_REMOTE"
printf 'same\n' >"${CONFLICT_LOCAL}/same.txt"
printf 'v1\n' >"${CONFLICT_LOCAL}/clash.txt"
printf 'same\n' >"${CONFLICT_REMOTE}/same.txt"
printf 'v1\n' >"${CONFLICT_REMOTE}/clash.txt"
cp "$FOLDERS_FILE" "${TMP}/folders.conflict.bak"
printf 'bisync|%s|conflict-pair\n' "$CONFLICT_LOCAL" >>"$FOLDERS_FILE"
expect_cli "conflicts: --resync --apply rc 0" 0 run_cli sync --resync --apply --only conflict-pair
expect_file "conflicts: resync pushed the pair" "${CONFLICT_REMOTE}/clash.txt"
printf 'local v2\n' >"${CONFLICT_LOCAL}/clash.txt"
# Backdate the local copy so the remote write is unambiguously newer
# (bisync --resync mode=newer needs distinct mtimes); replaces a sleep.
touch -t 202001010000 "${CONFLICT_LOCAL}/clash.txt"
printf 'remote v2 changed\n' >"${CONFLICT_REMOTE}/clash.txt"
BISYNC_RESYNC_MODE=newer expect_cli "conflicts: incremental run rc 0" 0 run_cli sync --apply --only conflict-pair
expect_contains "conflicts: conflict copies reported" "$CLI_OUT" "conflicts: 1 copy(ies) created"
expect_contains "conflicts: summary counts conflicts" "$CLI_OUT" "1 conflict(s)"
expect_file "conflicts: conflict copy kept locally" "${CONFLICT_LOCAL}/clash.txt.(conflicted copy)1"
cp "${TMP}/folders.conflict.bak" "$FOLDERS_FILE"
rm -rf "$CONFLICT_LOCAL" "$CONFLICT_REMOTE"

# A live run lock must stop `folders add` before anything is written.
mkdir -p "${TMP}/backup/locked-test"
holder_start "${TMP}/holder/bin/sciebo"
expect_rc "folders add: lock holder matches the tool" "$(holder_wait "$HOLDER_PID")" 1
mkdir -p "${STATE_DIR}/locks/sync.lock"
printf '%s\n' "$HOLDER_PID" >"${STATE_DIR}/locks/sync.lock/pid"
expect_cli "folders add: live lock refuses rc 1" 1 \
  run_cli folders add --remote locked-test --local "${TMP}/locked-local" --mode pull
expect_contains "folders add: live lock message" "$CLI_OUT" "Another sync run is active"
expect_not_contains "folders add: refused pair not written" "$(cat "$FOLDERS_FILE")" "locked-test"
expect_no_file "folders add: refused pair writes no filter" "${TMP}/filters/pair-locked-test.txt"
kill "$HOLDER_PID" 2>/dev/null || true
wait "$HOLDER_PID" 2>/dev/null || true
HOLDER_PID=""
rm -rf "${STATE_DIR}/locks/sync.lock"

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

# Exclude prompt: answering y and then selecting nothing means "no excludes"
# and must keep the pair (regression: it used to abort the whole selection).
# Prompt order: folder pick, local path, exclude y/N, exclude selection,
# add confirmation.
mkdir -p "${TMP}/cwd4/backup/keepme/child"
expect_cli_pipe "folders choose: empty exclude selection rc 0" 0 '1\n\ny\n\ny\n' run_cli_in "${TMP}/cwd4" \
  folders choose --no-fzf --no-dry-run --mode pull --local-root "${TMP}/picked-d"
expect_contains "folders choose: empty exclude selection keeps the pair" "$(cat "$FOLDERS_FILE")" "|keepme"
expect_no_file "folders choose: empty exclude selection writes no filter" "${TMP}/filters/pair-keepme.txt"

# --- folders add/choose --include/--select: complement excludes ----------
# The remote fixture is browsed through the temp cwd, like cwd2/cwd3/cwd4.
SEL_FOLDERS_BAK="${TMP}/folders.include.bak"
cp "$FOLDERS_FILE" "$SEL_FOLDERS_BAK"
mkdir -p "${TMP}/backup/sel-parent/keep-a" "${TMP}/backup/sel-parent/keep-b" \
  "${TMP}/backup/sel-parent/drop" "${TMP}/backup/sel-plain"
expect_cli "folders add --include: rc 0" 0 run_cli folders add \
  --remote sel-parent --local "${TMP}/sel-local" --mode pull --include keep-a
expect_contains "folders add --include: pair written with its filter" "$(cat "$FOLDERS_FILE")" \
  "pull|${TMP}/sel-local|sel-parent|pair-sel-parent.txt"
expect_file "folders add --include: pair filter created" "${FILTER_DIR}/pair-sel-parent.txt"
sel_filter="$(cat "${FILTER_DIR}/pair-sel-parent.txt")"
expect_contains "folders add --include: another child excluded" "$sel_filter" "- drop/"
expect_contains "folders add --include: second child excluded" "$sel_filter" "- keep-b/"
expect_not_contains "folders add --include: selected child kept" "$sel_filter" "- keep-a/"
expect_cli "folders add --include: unknown include rc 1" 1 run_cli folders add \
  --remote sel-parent --local "${TMP}/sel-x" --mode pull --include nope
expect_contains "folders add --include: unknown include message" "$CLI_OUT" "unknown subfolder 'nope'"
expect_contains "folders add --include: available children listed" "$CLI_OUT" "available: drop, keep-a, keep-b"
expect_cli "folders add --include: --include with --select rc 2" 2 run_cli folders add \
  --remote sel-parent --local "${TMP}/sel-y" --mode pull --include keep-a --select
expect_contains "folders add --include: mutually exclusive message" "$CLI_OUT" "mutually exclusive"
expect_cli "folders add --include: no flags rc 0" 0 run_cli folders add \
  --remote sel-plain --local "${TMP}/sel-plain-local" --mode pull
expect_no_file "folders add --include: no flags writes no filter" "${FILTER_DIR}/pair-sel-plain.txt"

# Piped --select: sorted children are drop, keep-a, keep-b; picking 1 keeps
# drop and excludes the other two.
mkdir -p "${TMP}/cwd5/backup/pick-parent/drop" "${TMP}/cwd5/backup/pick-parent/keep-a" \
  "${TMP}/cwd5/backup/pick-parent/keep-b"
expect_cli_pipe "folders choose --select: rc 0" 0 '1\n\nn\n1\ny\n' run_cli_in "${TMP}/cwd5" \
  folders choose --no-fzf --no-dry-run --depth 1 --select --mode pull --local-root "${TMP}/sel-picked"
expect_contains "folders choose --select: pair written" "$(cat "$FOLDERS_FILE")" "|pick-parent"
pick_filter="$(cat "${FILTER_DIR}/pair-pick-parent.txt")"
expect_contains "folders choose --select: unselected child excluded" "$pick_filter" "- keep-a/"
expect_contains "folders choose --select: second unselected child excluded" "$pick_filter" "- keep-b/"
expect_not_contains "folders choose --select: selected child kept" "$pick_filter" "- drop/"

# The include-all answer skips the filter entirely.
mkdir -p "${TMP}/cwd6/backup/pick-all/one" "${TMP}/cwd6/backup/pick-all/two"
expect_cli_pipe "folders choose --select: include-all rc 0" 0 '1\n\ny\ny\n' run_cli_in "${TMP}/cwd6" \
  folders choose --no-fzf --no-dry-run --depth 1 --select --mode pull --local-root "${TMP}/sel-picked-all"
expect_contains "folders choose --select: include-all pair written" "$(cat "$FOLDERS_FILE")" "|pick-all"
expect_no_file "folders choose --select: include-all writes no filter" "${FILTER_DIR}/pair-pick-all.txt"

cp "$SEL_FOLDERS_BAK" "$FOLDERS_FILE"
rm -f "${FILTER_DIR}/pair-sel-parent.txt" "${FILTER_DIR}/pair-pick-parent.txt" "${FILTER_DIR}/pair-pick-all.txt"

# --- compatibility shim: scripts/sync.sh maps onto the CLI --------------
# Regression: the shim works with no flags (an empty args array expands
# safely under `set -u` and still reaches the dry run).
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

# rclone's real exit status must surface: a stub satisfies the preflight
# calls and then fails nfsmount with a distinctive status and stderr.
MOUNT_STUB_RCLONE="${TMP}/stub-rclone-mount"
cat >"$MOUNT_STUB_RCLONE" <<'STUB'
#!/bin/bash
rclone_command=""
for arg in "$@"; do
  case "$arg" in
    listremotes | lsd | nfsmount) rclone_command="$arg" && break ;;
    show) rclone_command="show" && break ;;
  esac
done
case "$rclone_command" in
  listremotes) printf 'testremote:\n' ;;
  lsd) exit 0 ;;
  show) printf '[testremote]\ntype = webdav\nurl = https://example.invalid/remote.php/dav/files/alice/\nvendor = nextcloud\nuser = alice\n' ;;
  nfsmount)
    printf 'stub nfsmount boom\n' >&2
    exit 7
    ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$MOUNT_STUB_RCLONE"
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_mount_stub() {
  (cd "$TMP" && env RCLONE_BIN="${MOUNT_STUB_RCLONE}" MOUNT_ROOT="${TMP}/mnt-root" bash "${PROJ}/bin/sciebo" mount "$@")
}
expect_cli "mount: rclone exit status is reported" 1 run_mount_stub --folder stub-dir
expect_contains "mount: reports the real exit code" "$CLI_OUT" "exit 7"
expect_contains "mount: keeps rclone stderr" "$CLI_OUT" "stub nfsmount boom"
expect_no_file "mount: failed mount records no state" "${STATE_DIR}/mounts/stub-dir.state"

# Seeded state only: no real mount, a dead recorded pid, no kill target.
mkdir -p "${STATE_DIR}/mounts"
printf 'demo\n%s\n999999\nno\n' "${TMP}/mnt-demo" >"${STATE_DIR}/mounts/demo.state"
expect_cli "mounts: seeded state rc 0" 0 run_cli mounts
expect_contains "mounts: seeded record folder" "$CLI_OUT" "demo"
expect_contains "mounts: seeded record mounted=no" "$CLI_OUT" "mounted=no"
expect_contains "mounts: seeded record alive=no" "$CLI_OUT" "alive=no"
expect_cli "umount: recorded folder rc 0" 0 run_cli umount --folder demo
expect_no_file "umount: state file removed" "${STATE_DIR}/mounts/demo.state"

# The CLI reads mount visibility from `mount` output in the BSD/macOS
# "<src> on <path> (opts)" shape. Linux mount(8) prints
# "<src> on <path> type <fs> (opts)", which that parser cannot see. On
# non-macOS runs, prepend a stub `mount` that reports a BSD-style table with
# only "/" mounted, so the visibility-dependent assertions below keep their
# meaning on Linux.
if [[ "$(uname -s)" == "Darwin" ]]; then
  # shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
  run_cli_with_mounts() { run_cli "$@"; }
else
  MOUNT_TABLE_STUB_DIR="${TMP}/mount-table-stub-bin"
  mkdir -p "$MOUNT_TABLE_STUB_DIR"
  printf '#!/bin/bash\nprintf "/dev/sciebo-stub on / (stubfs, local)\\n"\n' >"${MOUNT_TABLE_STUB_DIR}/mount"
  chmod +x "${MOUNT_TABLE_STUB_DIR}/mount"
  # shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
  run_cli_with_mounts() {
    (cd "$TMP" && env PATH="${MOUNT_TABLE_STUB_DIR}:$PATH" bash "${PROJ}/bin/sciebo" "$@")
  }
fi

# A failed unmount keeps the record for a retry. umount is stubbed and the
# mountpoint "/" is visible in the mount table, so no real unmount is
# attempted.
STUB_BIN="${TMP}/stub-bin"
mkdir -p "$STUB_BIN"
printf '#!/bin/bash\nexit 1\n' >"$STUB_BIN/umount"
chmod +x "$STUB_BIN/umount"
printf 'demo-fail\n/\n-\nno\n' >"${STATE_DIR}/mounts/demo-fail.state"
PATH="$STUB_BIN:$PATH" expect_cli "umount: failed unmount rc 1" 1 run_cli_with_mounts umount --folder demo-fail
expect_contains "umount: failure keeps the state for a retry" "$CLI_OUT" "keeping its state"
expect_file "umount: failed unmount keeps the state file" "${STATE_DIR}/mounts/demo-fail.state"
rm -f "${STATE_DIR}/mounts/demo-fail.state"

# --- mounts --check / --prune: health summary and dead-record pruning ----
# "/" is visible in the mount table, so the record with pid `-` is healthy;
# the other points at a nonexistent mountpoint with a dead pid.
printf 'ok\n/\n-\nno\n' >"${STATE_DIR}/mounts/ok.state"
printf 'dead\n%s\n999999\nno\n' "${TMP}/no-such-mountpoint" >"${STATE_DIR}/mounts/dead.state"
expect_cli "mounts health: plain mounts rc 0" 0 run_cli_with_mounts mounts
expect_contains "mounts health: dead record mounted=no" "$CLI_OUT" "mounted=no"
expect_contains "mounts health: dead record alive=no" "$CLI_OUT" "alive=no"
expect_cli "mounts health: --check rc 1" 1 run_cli_with_mounts mounts --check
expect_contains "mounts health: summary counts ok and unhealthy" "$CLI_OUT" \
  "Summary: 2 mount(s): 1 ok, 1 unhealthy"
expect_cli "mounts health: --prune rc 0" 0 run_cli_with_mounts mounts --prune
expect_contains "mounts health: dead record pruned" "$CLI_OUT" "removed state ${STATE_DIR}/mounts/dead.state"
expect_no_file "mounts health: dead state removed" "${STATE_DIR}/mounts/dead.state"
expect_file "mounts health: healthy state kept" "${STATE_DIR}/mounts/ok.state"
rm -f "${STATE_DIR}/mounts/ok.state"
expect_cli "mounts health: empty list after pruning rc 0" 0 run_cli_with_mounts mounts
expect_contains "mounts health: empty message" "$CLI_OUT" "no rclone mounts"

expect_cli "usage: cleanup without a selector rc 2" 2 run_cli cleanup
expect_cli "usage: cleanup --bogus rc 2" 2 run_cli cleanup --bogus
expect_cli "usage: unknown command rc 2" 2 run_cli bogus
expect_cli "usage: help for a known command rc 0" 0 run_cli help sync
expect_contains "usage: help sync prints its usage" "$CLI_OUT" "Usage: sciebo sync"
expect_cli "usage: help for an unknown command rc 2" 2 run_cli help bogus
expect_cli "usage: bare help rc 0" 0 run_cli help
expect_contains "usage: bare help lists commands" "$CLI_OUT" "Commands:"

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

# Version gate: a version below RCLONE_MIN_VERSION refuses to run; the
# default minimum lets the same dry run through.
export RCLONE_MIN_VERSION=1.80
expect_cli "version gate: rclone below the minimum refused" 1 run_cli check --only manual-docs
expect_contains "version gate: too-old message" "$CLI_OUT" "is too old"
unset RCLONE_MIN_VERSION
expect_cli "version gate: default minimum allows the run" 0 run_cli check --only manual-docs

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
  env PROJ_PATH="$PROJ" bash -c '
    source "${PROJ_PATH}/lib/core.sh"
    source "${PROJ_PATH}/lib/rclone.sh"
    source "${PROJ_PATH}/lib/settings.sh"
    load_settings --no-rclone
    dump="$(remote_config_dump)"
    config_dump_value dumpremote pass "$dump"
  '
)"
expect_eq "config dump: obscured pass extracted" "$OBSCURED" "$got"

# --- capabilities: OCS probe plumbing against a stub curl ---------------
CAPS_STUB_BIN="${TMP}/capabilities-bin"
mkdir -p "$CAPS_STUB_BIN"
cat >"$CAPS_STUB_BIN/curl" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$(dirname "$0")/curl.log"
for arg in "$@"; do
  case "$arg" in
    *cloud/capabilities*)
      cat <<'JSON'
{"ocs":{"meta":{"status":"ok","statuscode":200,"message":"OK"},"data":{"version":{"major":31,"minor":0,"micro":2,"string":"31.0.2","edition":"","extendedSupport":false},"capabilities":{"core":{"pollinterval":60,"webdav-root":"remote.php\/webdav"},"files":{"bigfilechunking":true,"undelete":true,"chunked_upload":{"max_size":104857600,"max_parallel":3}},"dav":{"chunking":"1.0"},"checksums":{"supportedTypes":["SHA256"]}}}}}
JSON
      exit 0
      ;;
  esac
done
exit 1
STUB
chmod +x "$CAPS_STUB_BIN/curl"
CAPS_CACHE="${TMP}/caps-probe/capabilities.env"
CAPS_JSON="${TMP}/caps-probe/capabilities.json"
# shellcheck disable=SC2016  # single quotes are intentional inside bash -c
caps_probe_out="$(
  env PROJ_PATH="$PROJ" PATH="$CAPS_STUB_BIN:$PATH" \
    RCLONE_REMOTE=webtest RCLONE_CONFIG="$RCLONE_CONFIG" \
    CAPABILITIES_CACHE="$CAPS_CACHE" CAPABILITIES_JSON="$CAPS_JSON" \
    bash -c '
      set -uo pipefail
      source "$1/lib/core.sh"
      source "$1/lib/rclone.sh"
      source "$1/lib/settings.sh"
      source "$1/lib/capabilities.sh"
      load_settings
      capabilities_probe --force || exit 1
      capabilities_show
      printf "CAPS_CHUNK=%s\n" "$(capabilities_sync_chunk_size)"
    ' caps-probe "$PROJ"
)"
caps_probe_rc=$?
expect_rc "capabilities probe: sourced probe rc 0" "$caps_probe_rc" 0
expect_contains "capabilities probe: reports the server version" "$caps_probe_out" "server: Nextcloud 31.0.2"
expect_contains "capabilities probe: reports chunked uploads" "$caps_probe_out" "chunked uploads: enabled (max chunk 100Mi)"
expect_contains "capabilities probe: cached chunk size reaches sync" "$caps_probe_out" "CAPS_CHUNK=104857600"
expect_contains "capabilities probe: curl hit the capabilities URL" "$(cat "${CAPS_STUB_BIN}/curl.log")" "cloud/capabilities"
expect_eq "capabilities cache: mode 600" "600" "$(file_mode "$CAPS_CACHE")"
expect_contains "capabilities cache: sanitized version assignment" "$(cat "$CAPS_CACHE")" "CAP_VERSION=31.0.2"
expect_eq "capabilities json: mode 600" "600" "$(file_mode "$CAPS_JSON")"

# --- trash / versions: Nextcloud WebDAV flows behind a stub curl ---------
# The stub logs every invocation and serves canned XML by URL shape
# (trashbin, files/ file id, versions list); `fail` flips it into an HTTP
# 503. Its HTTP error goes to stderr like real curl's.
NC_STUB_BIN="${TMP}/nextcloud-stub-bin"
mkdir -p "$NC_STUB_BIN"
cat >"${NC_STUB_BIN}/curl" <<'STUB'
#!/bin/bash
dir="$(cd "$(dirname "$0")" && pwd)"
printf '%s\n' "$*" >>"${dir}/calls.log"
url=""
headers_file=""
body_file=""
write_format=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -D) headers_file="$2"; shift 2 ;;
    -o) body_file="$2"; shift 2 ;;
    -w) write_format="$2"; shift 2 ;;
    -u | --netrc-file | -X | --max-time | --retry | --data-binary) shift 2 ;;
    -*) shift ;;
    *)
      url="$1"
      shift
      ;;
  esac
done
code=200
body=""
if [[ -f "${dir}/fail" ]]; then
  code=503
else
  case "$url" in
    */remote.php/dav/trashbin/*) body="${dir}/trash.xml" ;;
    */remote.php/dav/versions/*) body="${dir}/versions.xml" ;;
    */remote.php/dav/files/*) body="${dir}/fileid.xml" ;;
    *) code=404 ;;
  esac
fi
if [[ -n "$body_file" && "$body_file" != "-" ]]; then
  [[ -n "$body" ]] && cat "$body" >"$body_file"
else
  [[ -n "$body" ]] && cat "$body"
fi
if [[ -n "$headers_file" ]]; then
  printf 'HTTP/1.1 %s Stub\r\n' "$code" >"$headers_file"
fi
if [[ -n "$write_format" ]]; then
  printf '%s' "$write_format" | sed "s/%{http_code}/${code}/g"
fi
if [[ "$code" -ge 400 && "$*" == *" -f"* ]]; then
  printf 'curl: (22) The requested URL returned error: %s\n' "$code" >&2
  exit 22
fi
exit 0
STUB
chmod +x "${NC_STUB_BIN}/curl"
cat >"${NC_STUB_BIN}/trash.xml" <<'XML'
<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
  <d:response>
    <d:href>/remote.php/dav/trashbin/alice/trash/</d:href>
    <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/dav/trashbin/alice/trash/plan.txt.d1700000000</d:href>
    <d:propstat><d:prop>
      <oc:trashbin-original-filename>plan.txt</oc:trashbin-original-filename>
      <oc:trashbin-original-location>notes/plan.txt</oc:trashbin-original-location>
      <oc:trashbin-delete-timestamp>1700000000</oc:trashbin-delete-timestamp>
      <d:getcontentlength>2048</d:getcontentlength>
    </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
  </d:response>
</d:multistatus>
XML
cat >"${NC_STUB_BIN}/fileid.xml" <<'XML'
<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
  <d:response>
    <d:href>/remote.php/dav/files/alice/backup/notes/plan.txt</d:href>
    <d:propstat><d:prop><oc:fileid>42</oc:fileid></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
  </d:response>
</d:multistatus>
XML
cat >"${NC_STUB_BIN}/versions.xml" <<'XML'
<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/remote.php/dav/versions/alice/versions/42/</d:href>
    <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/dav/versions/alice/versions/42/1700000000</d:href>
    <d:propstat><d:prop>
      <d:getlastmodified>Wed, 01 Nov 2023 01:00:00 GMT</d:getlastmodified>
      <d:getcontentlength>1024</d:getcontentlength>
    </d:prop></d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/dav/versions/alice/versions/42/1700000100</d:href>
    <d:propstat><d:prop>
      <d:getlastmodified>Wed, 01 Nov 2023 02:00:00 GMT</d:getlastmodified>
      <d:getcontentlength>2048</d:getcontentlength>
    </d:prop></d:propstat>
  </d:response>
</d:multistatus>
XML
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_cli_nextcloud() {
  (cd "$TMP" && env PATH="${NC_STUB_BIN}:$PATH" RCLONE_REMOTE=webtest bash "${PROJ}/bin/sciebo" "$@")
}
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_cli_plain_webdav() {
  (cd "$TMP" && env PATH="${NC_STUB_BIN}:$PATH" RCLONE_REMOTE=plainwebdav bash "${PROJ}/bin/sciebo" "$@")
}
rclone config create plainwebdav webdav url="http://127.0.0.1:9/dav/" \
  user=alice pass="$OBSCURED" --config "$RCLONE_CONFIG" >/dev/null 2>&1

rm -f "${NC_STUB_BIN}/calls.log"
expect_cli "trash: sample entry rc 0" 0 run_cli_nextcloud trash
expect_contains "trash: shows the original name" "$CLI_OUT" "plan.txt"
expect_contains "trash: shows the original location" "$CLI_OUT" "notes/plan.txt"
expect_contains "trash: shows the compact size" "$CLI_OUT" "2.0KiB"
trash_log="$(cat "${NC_STUB_BIN}/calls.log")"
expect_contains "trash: PROPFIND hit the trashbin endpoint" "$trash_log" "remote.php/dav/trashbin/alice/trash"
expect_contains "trash: PROPFIND used depth 1" "$trash_log" "Depth: 1"
expect_eq "trash: exactly one PROPFIND" "1" "$(grep -c -- '-X PROPFIND' "${NC_STUB_BIN}/calls.log")"

rm -f "${NC_STUB_BIN}/calls.log"
expect_cli "versions: rc 0" 0 run_cli_nextcloud versions notes/plan.txt
expect_contains "versions: lists the older version" "$CLI_OUT" "1700000000"
expect_contains "versions: lists the newer version" "$CLI_OUT" "1700000100"
expect_contains "versions: older version size" "$CLI_OUT" "1.0KiB"
expect_contains "versions: newer version size" "$CLI_OUT" "2.0KiB"
expect_eq "versions: two data rows, collection row skipped" "2" \
  "$(printf '%s\n' "$CLI_OUT" | awk '$1 ~ /^[0-9]+$/ { n++ } END { print n + 0 }')"
versions_log="$(cat "${NC_STUB_BIN}/calls.log")"
expect_contains "versions: depth 0 fileid PROPFIND" "$versions_log" "remote.php/dav/files/alice/backup/notes/plan.txt"
expect_contains "versions: depth 1 versions PROPFIND" "$versions_log" "remote.php/dav/versions/alice/versions/42"
expect_eq "versions: one depth 0 query" "1" "$(grep -c 'Depth: 0' "${NC_STUB_BIN}/calls.log")"
expect_eq "versions: one depth 1 query" "1" "$(grep -c 'Depth: 1' "${NC_STUB_BIN}/calls.log")"

expect_cli "versions: unsafe path rc 1" 1 run_cli_nextcloud versions ../evil
expect_contains "versions: unsafe path message" "$CLI_OUT" "unsafe remote path"
expect_cli "versions: missing argument rc 2" 2 run_cli_nextcloud versions
expect_contains "versions: missing argument prints the usage" "$CLI_OUT" "Usage: sciebo versions"
expect_cli "versions: extra arguments rc 2" 2 run_cli_nextcloud versions a b
expect_cli "trash: unknown option rc 2" 2 run_cli_nextcloud trash --bogus
expect_cli "trash: non-Nextcloud remote rc 1" 1 run_cli_plain_webdav trash
expect_contains "trash: non-Nextcloud message" "$CLI_OUT" "not a Nextcloud WebDAV remote"
expect_cli "versions: non-Nextcloud remote rc 1" 1 run_cli_plain_webdav versions notes/plan.txt
expect_contains "versions: non-Nextcloud message" "$CLI_OUT" "not a Nextcloud WebDAV remote"

# An empty multistatus lists nothing; a 503 surfaces as an rc 1 die.
printf '<?xml version="1.0"?>\n<d:multistatus xmlns:d="DAV:"/>\n' >"${NC_STUB_BIN}/trash.xml"
expect_cli "trash: empty trashbin rc 0" 0 run_cli_nextcloud trash
expect_contains "trash: empty message" "$CLI_OUT" "no trashed files"
touch "${NC_STUB_BIN}/fail"
expect_cli "trash: HTTP 503 rc 1" 1 run_cli_nextcloud trash
expect_contains "trash: HTTP 503 error surfaced" "$CLI_OUT" "503"
rm -f "${NC_STUB_BIN}/fail"

# --- setup: URL normalization (validation fails fast against a dead port)
# shellcheck disable=SC2030,SC2031  # per-run overrides live in a subshell
SCIEBO_URL="http://127.0.0.1:9" SCIEBO_USER="alice@example.org" \
  SCIEBO_APP_PASSWORD="integration-secret" RCLONE_REMOTE=setuptest \
  expect_cli "setup: dead endpoint fails validation" 1 run_cli setup
expect_contains "setup: warns about http" "$CLI_OUT" "plain http"
dump="$(rclone --config "$RCLONE_CONFIG" config dump 2>/dev/null)"
expect_contains "setup: url normalized" "$dump" "http://127.0.0.1:9/remote.php/dav/files/alice@example.org/"
expect_not_contains "setup: plaintext password not stored" "$dump" "integration-secret"

# --- setup --login: Login Flow v2 against stub curl/open -----------------
# The stub answers the init POST with escaped-slash JSON, then 404 on the
# first poll and 200 with the credentials on the second; the state counter
# lives in the stub directory. The validation afterwards runs the real
# rclone against example.invalid, so the run must fail there - but only
# after the remote was written.
LOGIN_STUB_BIN="${TMP}/login-flow-bin"
LOGIN_RCLONE_CONFIG="${TMP}/login-flow/rclone.conf"
LOGIN_STATE_DIR="${TMP}/login-flow/state"
mkdir -p "$LOGIN_STUB_BIN"
cat >"$LOGIN_STUB_BIN/curl" <<'STUB'
#!/bin/bash
dir="$(cd "$(dirname "$0")" && pwd)"
printf '%s\n' "$*" >>"${dir}/curl.log"
out_file=""
url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out_file="${2:-}"; shift 2 ;;
    -w | -H | -X | -d | -u | --max-time) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  */index.php/login/v2)
    printf '%s' '{"poll":{"token":"stub-poll-token","endpoint":"https:\/\/example.invalid\/login\/v2\/poll"},"login":"https:\/\/example.invalid\/login\/v2\/flow"}'
    ;;
  */login/v2/poll)
    polls=0
    [[ ! -f "${dir}/polls" ]] || polls="$(cat "${dir}/polls")"
    polls=$((polls + 1))
    printf '%s\n' "$polls" >"${dir}/polls"
    if [[ "$polls" -lt 2 ]]; then
      [[ -z "$out_file" ]] || : >"$out_file"
      printf '404'
    else
      [[ -z "$out_file" ]] || printf '%s' '{"server":"https:\/\/example.invalid","loginName":"alice","appPassword":"s3cret-app-password"}' >"$out_file"
      printf '200'
    fi
    ;;
  *)
    printf '000'
    exit 1
    ;;
esac
exit 0
STUB
cat >"$LOGIN_STUB_BIN/open" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$(dirname "$0")/open.log"
exit 0
STUB
chmod +x "$LOGIN_STUB_BIN/curl" "$LOGIN_STUB_BIN/open"
# shellcheck disable=SC2030,SC2031  # per-run overrides live in a subshell
PATH="$LOGIN_STUB_BIN:$PATH" LOGIN_FLOW_NO_BROWSER=1 LOGIN_FLOW_POLL_INTERVAL=0 \
  LOGIN_FLOW_TIMEOUT=10 LOGIN_FLOW_MAX_POLLS=5 \
  RCLONE_REMOTE=logintest RCLONE_CONFIG="$LOGIN_RCLONE_CONFIG" STATE_DIR="$LOGIN_STATE_DIR" \
  expect_cli "setup login flow: dead endpoint rc 1" 1 run_cli setup --login --url https://example.invalid --no-keychain
expect_contains "setup login flow: prints the authorization URL" "$CLI_OUT" "https://example.invalid/login/v2/flow"
expect_eq "setup login flow: stub polled until success" "2" "$(cat "${LOGIN_STUB_BIN}/polls")"
login_dump="$(rclone --config "$LOGIN_RCLONE_CONFIG" config dump 2>/dev/null)"
expect_contains "setup login flow: remote stored with normalized url" "$login_dump" "https://example.invalid/remote.php/dav/files/alice/"
expect_not_contains "setup login flow: plain app password never stored" "$login_dump" "s3cret-app-password"
expect_contains "setup login flow: obscured pass stored (keychain off)" "$login_dump" '"pass"'
expect_no_file "setup login flow: no browser was opened" "${LOGIN_STUB_BIN}/open.log"

# --- keychain: store/lookup round-trip through a stub `security` ---------
# SCIEBO_KEYCHAIN_BACKEND pins the macOS `security` backend so the stub drives
# the round-trip on Linux too (the probe would otherwise look for secret-tool).
KEYCHAIN_STUB_BIN="${TMP}/keychain-stub-bin"
mkdir -p "$KEYCHAIN_STUB_BIN"
cat >"$KEYCHAIN_STUB_BIN/security" <<'STUB'
#!/bin/bash
dir="$(cd "$(dirname "$0")" && pwd)"
printf '%s\n' "$*" >>"${dir}/calls.log"
cmd="$1"
shift
secret=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -w)
      if [[ "$cmd" == "add-generic-password" && $# -ge 2 ]]; then
        secret="$2"
        shift 2
      else
        shift
      fi
      ;;
    -a | -s) shift 2 ;;
    -U) shift ;;
    *) shift ;;
  esac
done
case "$cmd" in
  add-generic-password) printf '%s' "$secret" >"${dir}/stored" ;;
  find-generic-password)
    [[ -f "${dir}/stored" ]] || exit 44
    cat "${dir}/stored"
    ;;
  delete-generic-password)
    [[ -f "${dir}/stored" ]] || exit 44
    rm -f "${dir}/stored"
    ;;
esac
exit 0
STUB
chmod +x "$KEYCHAIN_STUB_BIN/security"
keychain_store_rc=0
# shellcheck disable=SC2016  # single quotes are intentional inside bash -c
env PROJ_PATH="$PROJ" PATH="$KEYCHAIN_STUB_BIN:$PATH" KEYCHAIN=1 \
  SCIEBO_KEYCHAIN_BACKEND=security \
  RCLONE_REMOTE=webtest KEYCHAIN_SERVICE=rclone-sciebo bash -c '
    set -uo pipefail
    source "$1/lib/core.sh"
    source "$1/lib/keychain.sh"
    keychain_store_plain "obscured-round-trip-value"
  ' keychain-store "$PROJ" || keychain_store_rc=$?
expect_rc "keychain round-trip: store rc 0" "$keychain_store_rc" 0
keychain_lookup_rc=0
# shellcheck disable=SC2016  # single quotes are intentional inside bash -c
keychain_lookup_out="$(
  env PROJ_PATH="$PROJ" PATH="$KEYCHAIN_STUB_BIN:$PATH" KEYCHAIN=1 \
    SCIEBO_KEYCHAIN_BACKEND=security \
    RCLONE_REMOTE=webtest KEYCHAIN_SERVICE=rclone-sciebo bash -c '
      set -uo pipefail
      source "$1/lib/core.sh"
      source "$1/lib/keychain.sh"
      keychain_lookup_plain
    ' keychain-lookup "$PROJ"
)" || keychain_lookup_rc=$?
expect_rc "keychain round-trip: lookup rc 0" "$keychain_lookup_rc" 0
if [[ "$keychain_lookup_out" == "obscured-round-trip-value" ]]; then
  pass "keychain round-trip: lookup returns the stored plaintext value"
else
  fail "keychain round-trip: lookup returns the stored plaintext value" "value mismatch"
fi

# sciebo's RCLONE_CONFIG_<REMOTE>_PASS spelling must match rclone's: rclone
# uppercases the section verbatim and keeps its dashes/dots (only the option
# part is underscore-folded). Pin that upstream rule against the installed
# rclone, so a future change surfaces here instead of as silent 401s for a
# dashed remote in keychain mode.
probe_conf="${TMP}/dashed-env.conf"
rclone config create probe-remote local --config "$probe_conf" >/dev/null 2>&1
probe_type="$(env 'RCLONE_CONFIG_PROBE-REMOTE_TYPE=sftp' rclone --config "$probe_conf" config show probe-remote 2>/dev/null | sed -n 's/^type = //p')"
probe_eq_underscore="$(env 'RCLONE_CONFIG_PROBE_REMOTE_TYPE=sftp' rclone --config "$probe_conf" config show probe-remote 2>/dev/null | sed -n 's/^type = //p')"
expect_contains "rclone env rule: dashed section name is read verbatim" "$probe_type" "sftp"
expect_not_contains "rclone env rule: underscore-folded section name is ignored" "$probe_eq_underscore" "sftp"

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

# An unreadable config dies with the cleanup-specific message instead of a
# misleading "not fully configured". Root ignores mode 000, so the check is
# skipped when the suite itself runs as root (e.g. inside a container).
: >"${TMP}/unreadable.conf"
chmod 000 "${TMP}/unreadable.conf"
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_cleanup_uploads_unreadable_config() {
  (cd "$TMP" && env RCLONE_REMOTE=webtest RCLONE_CONFIG="${TMP}/unreadable.conf" bash "${PROJ}/bin/sciebo" cleanup --uploads)
}
if [[ "$(id -u)" -eq 0 ]]; then
  printf 'SKIP  cleanup uploads: unreadable config dies rc 1 (running as root; mode 000 is readable)\n'
else
  expect_cli "cleanup uploads: unreadable config dies rc 1" 1 run_cleanup_uploads_unreadable_config
  expect_contains "cleanup uploads: cannot read config message" "$CLI_OUT" "cannot read rclone config from"
fi
chmod 644 "${TMP}/unreadable.conf"

# --- doctor: filter validation failure, then a healthy offline report ---
printf -- '- [\n' >"${FILTER_DIR}/pair-broken.txt"
expect_cli "doctor filters: broken filter fails rc 1" 1 run_doctor_offline
expect_contains "doctor filters: rclone rejects the file" "$CLI_OUT" "rclone rejects filter file"
rm -f "${FILTER_DIR}/pair-broken.txt"
expect_cli "doctor offline: healthy config rc 0" 0 run_doctor_offline
expect_contains "doctor offline: filter validation passed" "$CLI_OUT" "rclone filter validation passed"
expect_not_contains "doctor offline: no failures" "$CLI_OUT" "FAIL"

# An unreadable config must report "cannot read rclone config" instead of
# the remote's type as '<unset>'. `rclone config show` prints a section
# header even when the config cannot be read, so the stub isolates the two
# outcomes: listremotes succeeds, config show fails.
DOCTOR_STUB_RCLONE="${TMP}/stub-rclone-doctor"
cat >"$DOCTOR_STUB_RCLONE" <<'STUB'
#!/bin/bash
for arg in "$@"; do
  case "$arg" in
    version)
      printf 'rclone v1.75.1\n'
      exit 0
      ;;
    listremotes)
      printf 'webtest:\n'
      exit 0
      ;;
    show) exit 1 ;;
  esac
done
exit 0
STUB
chmod +x "$DOCTOR_STUB_RCLONE"
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_doctor_stub_config() {
  (cd "$TMP" && env HOME="${TMP}/home" RCLONE_REMOTE=webtest RCLONE_CONFIG="${TMP}/missing.conf" \
    RCLONE_BIN="${DOCTOR_STUB_RCLONE}" bash "${PROJ}/bin/sciebo" doctor --offline)
}
expect_cli "doctor unreadable config: rc 1" 1 run_doctor_stub_config
expect_contains "doctor unreadable config: cannot read report" "$CLI_OUT" "cannot read rclone config"
expect_not_contains "doctor unreadable config: no unset type" "$CLI_OUT" "type is '<unset>'"

# --- doctor: name hygiene warns about hostile names, never fails ---------
# The fixture holds Windows-invalid names and a case-only collision. Two
# manifest entries spell the same directory with different case, which is
# what makes the collision visible on a case-insensitive filesystem (macOS
# default: both entries scan the same files); on a case-sensitive
# filesystem the lower-case directory additionally holds a report.txt
# next to Report.txt.
DOCTOR_NAMES_DIR="${TMP}/doctor-names"
DOCTOR_NAMES_UPPER="${TMP}/Doctor-Names"
mkdir -p "$DOCTOR_NAMES_DIR" "$DOCTOR_NAMES_UPPER"
: >"${DOCTOR_NAMES_DIR}/bad:name.txt"
: >"${DOCTOR_NAMES_DIR}/trailing."
printf 'A\n' >"${DOCTOR_NAMES_DIR}/Report.txt"
printf 'B\n' >"${DOCTOR_NAMES_UPPER}/report.txt"
printf 'C\n' >"${DOCTOR_NAMES_DIR}/report.txt"
cp "$MANIFEST_FILE" "${TMP}/manifest.hygiene.bak"
printf 'sync|%s|doctor-names\n' "$DOCTOR_NAMES_DIR" >>"$MANIFEST_FILE"
printf 'sync|%s|doctor-names-upper\n' "$DOCTOR_NAMES_UPPER" >>"$MANIFEST_FILE"
expect_cli "doctor name hygiene: hostile names warn but rc 0" 0 run_doctor_offline
expect_contains "doctor name hygiene: platform-invalid names warned" "$CLI_OUT" "platform-invalid name(s)"
expect_contains "doctor name hygiene: names the invalid file" "$CLI_OUT" "bad:name.txt"
expect_contains "doctor name hygiene: trailing dot warned" "$CLI_OUT" "trailing."
expect_contains "doctor name hygiene: case-only collision warned" "$CLI_OUT" "case-only collision(s)"
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_doctor_name_limit() {
  (cd "$TMP" && env HOME="${TMP}/home" RCLONE_REMOTE=webtest DOCTOR_NAME_SCAN_LIMIT=1 \
    bash "${PROJ}/bin/sciebo" doctor --offline)
}
expect_cli "doctor name hygiene: scan limit warns but rc 0" 0 run_doctor_name_limit
expect_contains "doctor name hygiene: scan limit truncation reported" "$CLI_OUT" "scan truncated at 1 paths"
cp "${TMP}/manifest.hygiene.bak" "$MANIFEST_FILE"
rm -rf "$DOCTOR_NAMES_DIR" "$DOCTOR_NAMES_UPPER"

# --- doctor: pre-seeded capabilities cache, KEYCHAIN=0 fallback ---------
printf 'CAP_VERSION=31.0.2\nCAP_BIGFILE_CHUNKING=true\nCAP_CHUNK_MAX_SIZE=104857600\nCAP_UNDELETE=true\nCAP_CHECKSUMS=true\nCAP_PROBED_AT=1700000000\n' >"${STATE_DIR}/capabilities.env"
expect_cli "doctor offline: seeded capabilities rc 0" 0 run_doctor_offline
expect_contains "doctor offline: reports the cached server" "$CLI_OUT" "cached server capabilities: Nextcloud 31.0.2"
expect_contains "doctor offline: reports cached chunking" "$CLI_OUT" "chunked uploads enabled (max chunk 100Mi)"
expect_contains "doctor offline: KEYCHAIN=0 pass found in config" "$CLI_OUT" "app password stored in the rclone config (obscured)"
expect_not_contains "doctor offline: capabilities never FAIL" "$CLI_OUT" "FAIL"

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
