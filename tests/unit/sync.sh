#!/usr/bin/env bash
# sync.sh - sync argv/report/notify building (lib/commands/sync.sh).
# Sourced setup lives in tests/unit/common.sh; run standalone with
# `bash tests/unit/sync.sh`.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# --- sync_build_args: optional transfer knobs ---------------------------
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/commands/sync.sh
source "${LIB_DIR}/commands/sync.sh"
# sync_args_probe MODE [ENV=...]... - print one argument per line from
# sync_build_args for MODE; the ENV arguments override the probe defaults.
sync_args_probe() {
  local mode="$1"
  shift
  # shellcheck disable=SC2016  # the -c program expands "$1" itself
  env "SYNC_PROBE_MODE=$mode" "$@" bash -c '
    set -uo pipefail
    source "$1/lib/sciebo.sh"
    source "$1/lib/commands/sync.sh"
    : "${TRANSFERS:=1}" "${CHECKERS:=4}" "${TPSLIMIT:=8}" "${RETRIES:=3}" "${LOW_LEVEL_RETRIES:=10}"
    : "${TIMEOUT:=10m}" "${CONTIMEOUT:=30s}" "${STATS:=30s}" "${LOG_LEVEL:=INFO}"
    : "${CREATE_EMPTY_SRC_DIRS:=0}" "${TRACK_RENAMES:=0}" "${MAX_DELETE:=-1}"
    : "${BW_LIMIT_UP:=}" "${BW_LIMIT_DOWN:=}" "${SYNC_CHUNK_SIZE:=}"
    : "${CONFLICT_UPLOAD:=0}" "${CONFLICT_PATTERN:=conflicted copy}"
    ENTRY_MODE="$SYNC_PROBE_MODE" ENTRY_FILTER="" ENTRY_NAME=probe ENTRY_REMOTE=probe
    ENTRY_LOCAL="/tmp/probe-src"
    SYNC_APPLY=false SYNC_ASSUME_YES=false SYNC_RESYNC="${SYNC_PROBE_RESYNC:-false}"
    : "${BISYNC_CONFLICT_RESOLVE:=newer}" "${BISYNC_CONFLICT_LOSER:=num}"
    : "${BISYNC_CONFLICT_SUFFIX:=(conflicted copy)}" "${BISYNC_MAX_LOCK:=2m}"
    : "${BISYNC_RESYNC_MODE:=newer}" "${BISYNC_RESILIENT:=1}" "${BISYNC_RECOVER:=1}"
    : "${BISYNC_DIR:=/tmp/probe-bisync}" "${FILTER_DIR:=/tmp/probe-filters}"
    sync_build_args "remote:base/probe" "/tmp/probe.log"
    printf "%s\n" "${SYNC_ARGS[@]}"
  ' sync-args-probe "$PROJ_DIR" 2>&1
}
out="$(sync_args_probe sync)"
expect_contains "sync_build_args: sync entry recorded" "$out" "sync
/tmp/probe-src/
remote:base/probe/"
expect_contains "sync_build_args: dry run by default" "$out" "--dry-run"
expect_not_contains "sync_build_args: --create-empty-src-dirs off by default" "$out" "--create-empty-src-dirs"
expect_not_contains "sync_build_args: --max-delete off by default" "$out" "--max-delete"
expect_not_contains "sync_build_args: --track-renames off by default" "$out" "--track-renames"
expect_not_contains "sync_build_args: --bwlimit off by default" "$out" "--bwlimit"
out="$(sync_args_probe sync CREATE_EMPTY_SRC_DIRS=1 MAX_DELETE=7 TRACK_RENAMES=1 BW_LIMIT_UP=1M BW_LIMIT_DOWN=off)"
expect_contains "sync_build_args: --create-empty-src-dirs recorded" "$out" "--create-empty-src-dirs"
expect_contains "sync_build_args: --max-delete value recorded" "$out" $'--max-delete\n7'
expect_contains "sync_build_args: --track-renames recorded for sync" "$out" "--track-renames"
expect_contains "sync_build_args: --bwlimit up:down recorded" "$out" $'--bwlimit\n1M:off'
out="$(sync_args_probe sync MAX_DELETE=0)"
expect_contains "sync_build_args: --max-delete 0 is recorded" "$out" $'--max-delete\n0'
out="$(sync_args_probe sync BW_LIMIT_DOWN=5M)"
expect_contains "sync_build_args: --bwlimit with only down recorded" "$out" $'--bwlimit\noff:5M'
out="$(sync_args_probe pull TRACK_RENAMES=1)"
expect_contains "sync_build_args: pull reverses src and dst" "$out" "sync
remote:base/probe/
/tmp/probe-src/"
expect_contains "sync_build_args: --track-renames recorded for pull" "$out" "--track-renames"
out="$(sync_args_probe bisync TRACK_RENAMES=1)"
expect_contains "sync_build_args: bisync entry recorded" "$out" "bisync
/tmp/probe-src/
remote:base/probe/"
expect_not_contains "sync_build_args: no --track-renames for bisync" "$out" "--track-renames"
expect_not_contains "sync_build_args: no --resync-mode for incremental bisync" "$out" "--resync-mode"
out="$(sync_args_probe bisync SYNC_PROBE_RESYNC=true)"
expect_contains "sync_build_args: resync passes --resync-mode" "$out" $'--resync-mode\nnewer'
expect_contains "sync_build_args: resync passes --resync" "$out" $'\n--resync\n'
out="$(sync_args_probe sync)"
expect_contains "sync_build_args: conflict copies excluded by default" "$out" $'--exclude\n*conflicted copy*'
out="$(sync_args_probe sync CONFLICT_UPLOAD=1)"
expect_not_contains "sync_build_args: CONFLICT_UPLOAD=1 uploads conflict copies" "$out" "*conflicted copy*"
out="$(sync_args_probe pull)"
expect_contains "sync_build_args: pull excludes conflict copies" "$out" $'--exclude\n*conflicted copy*'
out="$(sync_args_probe bisync)"
expect_contains "sync_build_args: bisync excludes conflict copies" "$out" $'--exclude\n*conflicted copy*'
out="$(sync_args_probe sync CONFLICT_PATTERN=clash)"
expect_contains "sync_build_args: CONFLICT_PATTERN feeds the exclude" "$out" $'--exclude\n*clash*'

# --- sync_report_plan / sync_report_conflicts ---------------------------
plan_log="${TMP}/sync-plan.log"
printf '%s\n' \
  '2026/09/19 18:22:45 NOTICE: a.txt: Skipped copy as --dry-run is set (size 6)' \
  '2026/09/19 18:22:45 NOTICE: b.txt: Skipped delete as --dry-run is set (size 6)' \
  '2026/09/19 18:22:45 NOTICE: c.txt: Skipped update modification time as --dry-run is set (size 4)' \
  '2026/09/19 18:22:45 NOTICE: a.txt: Skipped copy as --dry-run is set (size 6)' >"$plan_log"
expect_eq "sync_report_plan: counts and deduped samples" \
  "plan: 2 to copy, 1 to delete, 1 other (e.g. a.txt, b.txt, c.txt)" \
  "$(sync_report_plan "$plan_log")"
printf '2026/09/19 18:22:45 NOTICE: nothing skipped here\n' >"$plan_log"
expect_eq "sync_report_plan: empty plan says no changes" "plan: no changes" "$(sync_report_plan "$plan_log")"
expect_eq "sync_report_plan: missing log prints nothing" "" "$(sync_report_plan "${TMP}/no-such-plan.log")"

conflict_log="${TMP}/sync-conflict.log"
printf '%s\n' \
  '2026/09/19 18:22:45 NOTICE: - Path1             Renaming Path1 copy                         - /tmp/x/clash.txt.(conflicted copy)1' \
  '2026/09/19 18:22:45 NOTICE: - Path2             Renaming Path2 copy                         - /tmp/x/other.txt.(conflicted copy)2' \
  '2026/09/19 18:22:45 NOTICE: - Path2             Not renaming Path2 copy, as it was determined the winner - /tmp/x/clash.txt' >"$conflict_log"
SYNC_CONFLICTS=0
conflict_out="$(sync_report_conflicts "$conflict_log")"
expect_eq "sync_report_conflicts: counts and samples" \
  "conflicts: 2 copy(ies) created (e.g. /tmp/x/clash.txt.(conflicted copy)1, /tmp/x/other.txt.(conflicted copy)2)" \
  "$conflict_out"
printf '2026/09/19 18:22:45 NOTICE: nothing to see\n' >"$conflict_log"
conflict_out="$(sync_report_conflicts "$conflict_log")"
expect_eq "sync_report_conflicts: clean log prints nothing" "" "$conflict_out"
# SYNC_CONFLICTS accumulates across calls in the same shell.
printf '%s\n' \
  '2026/09/19 18:22:45 NOTICE: - Path1             Renaming Path1 copy                         - /tmp/x/clash.txt.(conflicted copy)1' >"$conflict_log"
SYNC_CONFLICTS=1
sync_report_conflicts "$conflict_log" >/dev/null
expect_eq "sync_report_conflicts: total accumulates" "2" "$SYNC_CONFLICTS"

# --- sync_notify: failures beat conflicts, conflicts beat success --------
# A private bin dir stubs osascript, exactly like tests/unit/notify.sh; the
# two suites run in separate processes, so each needs its own stub.
NOTIFY_BIN="${TMP}/notify-bin"
mkdir -p "$NOTIFY_BIN"
cat >"${NOTIFY_BIN}/osascript" <<'STUB'
#!/bin/bash
dir="$(cd "$(dirname "$0")" && pwd)"
{
  printf 'argc=%s\n' "$#"
  i=0
  for arg in "$@"; do
    i=$((i + 1))
    printf 'arg%s=%s\n' "$i" "$arg"
  done
} >>"${dir}/calls.log"
exit 0
STUB
chmod +x "${NOTIFY_BIN}/osascript"
# Exercise the macOS notification backend through the stub on any host.
sync_saved_platform_os="$PLATFORM_OS"
PLATFORM_OS=macos
saved_path="$PATH"
PATH="${NOTIFY_BIN}:$PATH"
SYNC_APPLY=true SYNC_TOTAL=2 SYNC_FAILED=0 SYNC_OK=2 SYNC_CONFLICTS=1
SYNC_FAILED_NAMES="" NOTIFY=1 NOTIFY_SUCCESS=0
rm -f "${NOTIFY_BIN}/calls.log"
sync_notify
expect_contains "sync_notify: conflict notification sent" "$(cat "${NOTIFY_BIN}/calls.log")" "sciebo conflicts"
rm -f "${NOTIFY_BIN}/calls.log"
SYNC_CONFLICTS=0
sync_notify
expect_no_file "sync_notify: success stays silent with NOTIFY_SUCCESS=0" "${NOTIFY_BIN}/calls.log"
rm -f "${NOTIFY_BIN}/calls.log"
NOTIFY_SUCCESS=1
sync_notify
expect_contains "sync_notify: success notification sent" "$(cat "${NOTIFY_BIN}/calls.log")" "sciebo sync finished"
rm -f "${NOTIFY_BIN}/calls.log"
SYNC_APPLY=false
sync_notify
expect_no_file "sync_notify: dry runs never notify" "${NOTIFY_BIN}/calls.log"
rm -f "${NOTIFY_BIN}/calls.log"
SYNC_APPLY=true SYNC_TOTAL=1 SYNC_FAILED=1 SYNC_CONFLICTS=1 NOTIFY_SUCCESS=1
SYNC_FAILED_NAMES=$'broken\n'
sync_notify
expect_contains "sync_notify: failure notification beats conflicts" "$(cat "${NOTIFY_BIN}/calls.log")" "sciebo sync failed"
expect_contains "sync_notify: failure notification names the source" "$(cat "${NOTIFY_BIN}/calls.log")" "broken"
PLATFORM_OS="$sync_saved_platform_os"
PATH="$saved_path"
SYNC_APPLY=false SYNC_TOTAL=0 SYNC_FAILED=0 SYNC_OK=0 SYNC_CONFLICTS=0 SYNC_FAILED_NAMES=""
NOTIFY=0 NOTIFY_SUCCESS=0

finish
