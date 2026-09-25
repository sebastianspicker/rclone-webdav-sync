#!/usr/bin/env bash
# sync_guards.sh - conflict-copy exclusion, the MAX_DOWNLOAD_SIZE guard, the
# MIN_FREE_SPACE / FREE_SPACE_DOWNLOAD disk guard, and the big-folder
# notification. All run against the real local `testremote`, so rclone
# actually transfers.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

# Tiny limit and no interactive ask make the non-TTY skip deterministic.
export MAX_DOWNLOAD_SIZE=10 ASK_DOWNLOAD_SIZE=0
SYNC_SRC="${TMP}/guards-src"
PULL_DST="${TMP}/guards-dst"
REMOTE_SYNC="${TMP}/backup/guards-sync"
REMOTE_PULL="${TMP}/backup/guards-pull"

cat >"$MANIFEST_FILE" <<EOF
sync|${SYNC_SRC}|guards-sync
pull|${PULL_DST}|guards-pull
EOF

# --- conflict copies stay local ------------------------------------------
mkdir -p "$SYNC_SRC"
printf 'normal\n' >"${SYNC_SRC}/normal.txt"
printf 'conflict\n' >"${SYNC_SRC}/x (conflicted copy).txt"
rm -rf "$REMOTE_SYNC"
expect_cli "guards: sync apply rc 0" 0 run_cli sync --apply --only guards-sync
expect_file "guards: normal file uploaded" "${REMOTE_SYNC}/normal.txt"
expect_no_file "guards: conflict copy not uploaded" "${REMOTE_SYNC}/x (conflicted copy).txt"

# CONFLICT_UPLOAD=1 uploads the copy (fresh remote dir).
rm -rf "$REMOTE_SYNC"
export CONFLICT_UPLOAD=1
expect_cli "guards: sync apply with CONFLICT_UPLOAD=1 rc 0" 0 run_cli sync --apply --only guards-sync
export CONFLICT_UPLOAD=0
expect_file "guards: CONFLICT_UPLOAD=1 uploads the conflict copy" "${REMOTE_SYNC}/x (conflicted copy).txt"

# --- MAX_DOWNLOAD_SIZE gates pull applies --------------------------------
mkdir -p "$REMOTE_PULL"
printf 'remote payload larger than ten bytes\n' >"${REMOTE_PULL}/big.bin"

expect_cli "guards: oversized pull skipped rc 0" 0 run_cli sync --apply --only guards-pull
expect_contains "guards: apply prints the size guard" "$CLI_OUT" "size guard"
expect_contains "guards: apply suggests --yes" "$CLI_OUT" "re-run with --yes"
expect_no_file "guards: skipped pull creates no local dir" "$PULL_DST"

expect_cli "guards: status rc 0" 0 run_cli status --only guards-pull
expect_contains "guards: status shows SKIPPED" "$CLI_OUT" "SKIPPED"
expect_file "guards: runstate record written" "${STATE_DIR}/last/guards-pull"
expect_contains "guards: runstate status skipped" "$(cat "${STATE_DIR}/last/guards-pull")" "status=skipped"
expect_contains "guards: runstate detail mentions the guard" "$(cat "${STATE_DIR}/last/guards-pull")" "size guard"

expect_cli "guards: dry run rc 0" 0 run_cli sync --dry-run --only guards-pull
expect_contains "guards: dry run prints the size guard" "$CLI_OUT" "size guard"
expect_no_file "guards: dry run creates nothing" "$PULL_DST"

expect_cli "guards: --yes apply rc 0" 0 run_cli sync --apply --yes --only guards-pull
expect_contains "guards: --yes logs the override" "$CLI_OUT" "overridden by --yes"
expect_file "guards: --yes downloads the file" "${PULL_DST}/big.bin"

expect_cli "guards: check accepts --yes" 0 run_cli check --yes --only guards-pull

# --- MIN_FREE_SPACE fails, FREE_SPACE_DOWNLOAD skips pull applies ---------
rm -f "${PULL_DST}/big.bin"
export MIN_FREE_SPACE=999999T
expect_cli "guards: MIN_FREE_SPACE fails the pull rc 1" 1 run_cli sync --apply --only guards-pull
expect_contains "guards: MIN_FREE_SPACE reason" "$CLI_OUT" "free space below MIN_FREE_SPACE"
expect_no_file "guards: MIN_FREE_SPACE does not download" "${PULL_DST}/big.bin"
unset MIN_FREE_SPACE

export FREE_SPACE_DOWNLOAD=999999T
expect_cli "guards: FREE_SPACE_DOWNLOAD skips the pull rc 0" 0 run_cli sync --apply --only guards-pull
expect_contains "guards: FREE_SPACE_DOWNLOAD reason" "$CLI_OUT" "free space below FREE_SPACE_DOWNLOAD"
expect_no_file "guards: FREE_SPACE_DOWNLOAD does not download" "${PULL_DST}/big.bin"
unset FREE_SPACE_DOWNLOAD

# --- big folder notification runs before a pull apply ---------------------
mkdir -p "${REMOTE_PULL}/huge"
printf 'x\n' >"${REMOTE_PULL}/huge/x.bin"
export BIG_FOLDER_SIZE=1
expect_cli "guards: big folder pull rc 0" 0 run_cli sync --apply --yes --only guards-pull
expect_contains "guards: big folder warned" "$CLI_OUT" "big folder: guards-pull/huge"
unset BIG_FOLDER_SIZE

# --- E2EE preflight: hostile server paths in rclone excludes --------------
# sync_e2ee_preflight derives rclone --exclude patterns from server-reported
# encrypted subpaths. A subpath with glob metacharacters must be escaped so
# it stays a literal path, and one that is not safely relative must be
# refused instead of turned into a pattern. The nc helpers and the
# Nextcloud probe are stubbed, as in the policy suite.
# shellcheck disable=SC1090,SC1091
source "${PROJ}/lib/commands/sync.sh"

# shellcheck disable=SC2329  # invoked indirectly by the sync preflights
nc_e2ee_paths() { printf '%s\n' "$GUARDS_E2EE_PATHS"; }
# shellcheck disable=SC2329  # invoked indirectly by the sync preflights
remote_is_nextcloud() { return 0; }

# guards_e2ee_preflight PATHS - run sync_e2ee_preflight with PATHS as the
# server's reported encrypted subpaths and print "rc=N" then one
# "exclude=PATTERN" line per collected exclude.
guards_e2ee_preflight() {
  GUARDS_E2EE_PATHS="$1"
  # shellcheck disable=SC2034  # read by sync_e2ee_preflight
  ENTRY_MODE=pull ENTRY_NAME=probe ENTRY_REMOTE=notes E2EE_POLICY=exclude
  SYNC_POLICY_EXCLUDES=()
  local rc=0 i=0
  sync_e2ee_preflight >/dev/null 2>&1 || rc=$?
  printf 'rc=%s\n' "$rc"
  while [[ "$i" -lt "${#SYNC_POLICY_EXCLUDES[@]}" ]]; do
    printf 'exclude=%s\n' "${SYNC_POLICY_EXCLUDES[$i]}"
    i=$((i + 1))
  done
}

out="$(guards_e2ee_preflight $'notes/secret\nnotes/a*b')"
expect_contains "e2ee glob: normal subpath pattern unchanged" "$out" 'exclude=/secret/**'
expect_contains "e2ee glob: star escaped" "$out" 'exclude=/a\*b/**'
expect_not_contains "e2ee glob: star not left as a wildcard" "$out" 'exclude=/a*b/**'

out="$(guards_e2ee_preflight 'notes/weird[1]{x}')"
expect_contains "e2ee glob: brackets and braces escaped" "$out" 'exclude=/weird\[1\]\{x\}/**'
expect_not_contains "e2ee glob: metacharacters not left bare" "$out" 'exclude=/weird[1]{x}/**'

out="$(guards_e2ee_preflight 'notes/../escape')"
expect_contains "e2ee glob: unsafe relative path proceeds without excluding" "$out" "rc=0"
expect_not_contains "e2ee glob: unsafe relative path produces no exclude" "$out" 'exclude='

# --- sync_record_errors batches every failing path into the blacklist ------
# The sync failure path streams each `ERROR : <path>: <msg>` line into one
# blacklist_record_many call, so several failing paths land in a single
# record file with their counts accumulated.
export BLACKLIST_DIR="${TMP}/blacklist-errors" BLACKLIST_ENABLED=1
export BLACKLIST_MAX_FAILS=2 BLACKLIST_MODE=count
errlog="${TMP}/sync-record-errors.log"
{
  printf 'ERROR : notes/one.txt: permission denied\n'
  printf 'ERROR : notes/two.txt: input/output error\n'
  printf 'INFO  : notes/ok.txt: transferred\n'
  printf 'ERROR : notes/one.txt: permission denied\n'
} >"$errlog"
# shellcheck disable=SC2034  # read by sync_record_errors
ENTRY_NAME=guards-errors
# shellcheck disable=SC2034  # read by sync_record_errors
SYNC_LOG_OFFSET=0
sync_record_errors "$errlog"
expect_eq "sync errors: repeated path accumulates its count" "2" "$(cat "$(blacklist_file guards-errors)" 2>/dev/null | awk -F'\t' '$2 == "notes/one.txt" { print $1 }')"
expect_eq "sync errors: second path recorded once" "1" "$(cat "$(blacklist_file guards-errors)" 2>/dev/null | awk -F'\t' '$2 == "notes/two.txt" { print $1 }')"
expect_eq "sync errors: only ERROR lines are recorded" "2" "$(blacklist_count guards-errors)"

# --- opt-in remote case-clash preflight (stubbed listing) ------------------
# CASE_CLASH_REMOTE_SCAN is off by default; when enabled the sync preflight
# lists the remote subtree and applies CASE_CLASH_POLICY to remote clashes.
# Remote paths are never renamed, so rename falls back to excluding the loser.
RS_STUB="${TMP}/remote-scan-bin"
RS_LSF="${TMP}/remote-scan-lsf.txt"
RS_LOG="${TMP}/remote-scan.log"
mkdir -p "$RS_STUB"
cat >"${RS_STUB}/rclone" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"${RS_LOG:-/dev/null}"
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
    lsf)
      cat "${RS_LSF:-/dev/null}"
      exit 0
      ;;
    size)
      printf '{"count":2,"bytes":5242880,"sizeless":0}\n'
      exit 0
      ;;
    lsd | config) exit 0 ;;
  esac
done
exit 0
STUB
chmod +x "${RS_STUB}/rclone"
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_cli_remote_scan() {
  (cd "$TMP" && env PATH="${RS_STUB}:$PATH" RCLONE_BIN="${RS_STUB}/rclone" RS_LOG="$RS_LOG" RS_LSF="$RS_LSF" bash "${PROJ}/bin/sciebo" "$@")
}

printf 'Dir/File.txt\nDir/file.txt\nother.txt\n' >"$RS_LSF"
: >"$RS_LOG"
export CASE_CLASH_REMOTE_SCAN=1 CASE_CLASH_POLICY=exclude
expect_cli "remote scan: exclude run rc 0" 0 run_cli_remote_scan sync --dry-run --only guards-sync
expect_contains "remote scan: exclude warns" "$CLI_OUT" "case clash (remote)"
expect_contains "remote scan: exclude pattern passed to rclone" "$(cat "$RS_LOG")" "--exclude /Dir/file.txt"
unset CASE_CLASH_POLICY

printf 'Dir/File.txt\nDir/file.txt\n' >"$RS_LSF"
: >"$RS_LOG"
export CASE_CLASH_POLICY=warn
expect_cli "remote scan: warn run rc 0" 0 run_cli_remote_scan sync --dry-run --only guards-sync
expect_contains "remote scan: warn reports the pair" "$CLI_OUT" "differ only by case"
expect_not_contains "remote scan: warn adds no exclude" "$(cat "$RS_LOG")" "/Dir/file.txt"
unset CASE_CLASH_POLICY

export CASE_CLASH_POLICY=rename
: >"$RS_LOG"
expect_cli "remote scan: rename run rc 0" 0 run_cli_remote_scan sync --dry-run --only guards-sync
expect_contains "remote scan: rename excludes the loser" "$(cat "$RS_LOG")" "--exclude /Dir/file.txt"
expect_contains "remote scan: rename warns it is not attempted" "$CLI_OUT" "cannot rename"
unset CASE_CLASH_POLICY

printf 'Dir/Sub/\nDir/sub/\n' >"$RS_LSF"
: >"$RS_LOG"
export CASE_CLASH_POLICY=exclude
expect_cli "remote scan: directory run rc 0" 0 run_cli_remote_scan sync --dry-run --only guards-sync
expect_contains "remote scan: directory subtree excluded" "$(cat "$RS_LOG")" "--exclude /Dir/sub/**"
unset CASE_CLASH_POLICY

: >"$RS_LOG"
export CASE_CLASH_REMOTE_SCAN=0
expect_cli "remote scan: disabled run rc 0" 0 run_cli_remote_scan sync --dry-run --only guards-sync
expect_not_contains "remote scan: disabled does no listing" "$(cat "$RS_LOG")" " lsf "
unset CASE_CLASH_REMOTE_SCAN

# --- opt-in remote-size cache: one `rclone size` per distinct spec ---------
# Two pull entries resolve to the same remote spec. The first guard lookup is
# cached per process, so the second entry reuses it instead of running
# `rclone size` again (B9); both are still skipped and reported.
SIZE_DST_A="${TMP}/size-cache-a"
SIZE_DST_B="${TMP}/size-cache-b"
cat >"$MANIFEST_FILE" <<EOF
pull|${SIZE_DST_A}|guards-cache
pull|${SIZE_DST_B}|guards-cache
EOF
: >"$RS_LOG"
export MAX_DOWNLOAD_SIZE=1
expect_cli "size cache: duplicate-spec pulls rc 0" 0 run_cli_remote_scan sync --apply
expect_contains "size cache: first entry hits the size guard" "$CLI_OUT" "size guard"
expect_eq "size cache: one rclone size call for both entries" "1" \
  "$(grep -c ' size --json' "$RS_LOG" 2>/dev/null || true)"
expect_no_file "size cache: skipped pulls create no local dir" "$SIZE_DST_A"
expect_no_file "size cache: second skipped pull creates no local dir" "$SIZE_DST_B"
export MAX_DOWNLOAD_SIZE=10

# --- disk guard: free space is memoized per resolved directory -------------
# sync_disk_guard caches the df result per directory for the run, so repeated
# pull entries on the same destination share one df call while a different
# directory still probes.
mkdir -p "${TMP}/disk-guard-a" "${TMP}/disk-guard-b"
DF_LOG="${TMP}/disk-guard-df.log"
: >"$DF_LOG"
# shellcheck disable=SC2329  # invoked indirectly by sync_disk_guard
df() {
  printf 'call\n' >>"$DF_LOG"
  printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
  printf '/dev/fake 100000 0 100 0%% /\n'
}
# shellcheck disable=SC2034  # read by sync_disk_guard
SYNC_DISK_FREE_CACHE=()
# shellcheck disable=SC2034  # read by sync_disk_guard
ENTRY_MODE=pull
MIN_FREE_SPACE=1
FREE_SPACE_DOWNLOAD=""
sync_disk_guard "${TMP}/disk-guard-a" || true
sync_disk_guard "${TMP}/disk-guard-a" || true
sync_disk_guard "${TMP}/disk-guard-b" || true
unset -f df
unset MIN_FREE_SPACE
expect_eq "disk guard: one df per resolved directory" "2" \
  "$(grep -c '' "$DF_LOG" 2>/dev/null || true)"

# --- download/delete guards route through the shared ui_confirm_tty gate ----
# Both guards used to test `-t 0` themselves, so SCIEBO_NON_INTERACTIVE was
# ignored on a terminal. They now call ui_confirm_tty: rc 0 proceeds, rc 1 is
# a typed decline, rc 2 (no tty, or SCIEBO_NON_INTERACTIVE) refuses without
# prompting and keeps the exact pre-existing messages. The direct calls below
# simulate the terminal via ui_stdin_tty and feed the reply on stdin.
# shellcheck disable=SC2329  # the guard's remote-size lookup, stubbed here
remote_size() {
  # shellcheck disable=SC2034  # read by sync_download_guard
  REMOTE_SIZE=1048576
  return 0
}
# download_probe - run sync_download_guard and print "rc=N reason=..." so the
# subshell's SYNC_ENTRY_REASON is observable.
download_probe() {
  local rc=0
  sync_download_guard remote:probe >/dev/null 2>&1 && rc=0 || rc=$?
  printf 'rc=%s reason=%s\n' "$rc" "$SYNC_ENTRY_REASON"
}
# delete_probe - the same for sync_delete_guard_retry.
delete_probe() {
  local rc=0
  sync_delete_guard_retry remote:probe /dev/null >/dev/null 2>&1 && rc=0 || rc=$?
  printf 'rc=%s reason=%s\n' "$rc" "$SYNC_ENTRY_REASON"
}

# shellcheck disable=SC2034  # read by the guards under test
ENTRY_MODE=pull ENTRY_REMOTE=probe SYNC_APPLY=true SYNC_ASSUME_YES=false
# shellcheck disable=SC2034  # read by the guards under test
ENTRY_NAME=probe DELETE_FILES_THRESHOLD=7
MAX_DOWNLOAD_SIZE=1 ASK_DOWNLOAD_SIZE=1

# no tty: refuse and skip with the --yes message.
# shellcheck disable=SC2329  # simulated non-terminal for the gate
ui_stdin_tty() { return 1; }
out="$(download_probe)"
expect_contains "download guard: no tty skips" "$out" "rc=2"
expect_contains "download guard: no tty refusal" "$out" "re-run with --yes to download"
out="$(delete_probe)"
expect_contains "delete guard: no tty fails the entry" "$out" "rc=1"
expect_contains "delete guard: no tty refusal" "$out" "re-run with --yes to allow"

# a terminal plus SCIEBO_NON_INTERACTIVE still refuses without prompting.
# shellcheck disable=SC2329  # simulated terminal for the gate
ui_stdin_tty() { return 0; }
export SCIEBO_NON_INTERACTIVE=1
out="$(download_probe)"
expect_contains "download guard: SCIEBO_NON_INTERACTIVE skips" "$out" "rc=2"
expect_contains "download guard: non-interactive refusal" "$out" "re-run with --yes to download"
out="$(delete_probe)"
expect_contains "delete guard: SCIEBO_NON_INTERACTIVE fails" "$out" "rc=1"
expect_contains "delete guard: non-interactive refusal" "$out" "re-run with --yes to allow"
unset SCIEBO_NON_INTERACTIVE

# on a terminal a typed decline keeps the original "declined" wording; a
# typed yes proceeds (the unified y/yes dialect).
out="$(printf 'n\n' | download_probe)"
expect_contains "download guard: typed decline skips" "$out" "rc=2"
expect_contains "download guard: decline wording" "$out" "download declined"
out="$(printf 'y\n' | download_probe)"
expect_contains "download guard: typed yes proceeds" "$out" "rc=0"
out="$(printf 'n\n' | delete_probe)"
expect_contains "delete guard: typed decline fails" "$out" "rc=1"
expect_contains "delete guard: decline wording" "$out" "delete guard: more than 7 file(s) to delete; declined"

unset MAX_DOWNLOAD_SIZE ASK_DOWNLOAD_SIZE

finish
