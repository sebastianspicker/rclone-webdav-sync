#!/bin/bash
# sync.sh command module - dry run (check) and apply (sync); the `list`
# command lives in list.sh (its row rendering, shared with `sync --list`,
# lives in lib/config/manifest.sh's manifest_list_render).
# `sciebo check` is a dry run; .nosync and filters apply to sync/pull only.
#
# Sourcing this module only defines functions and the SYNC_* state: every
# dependency (blacklist, policy, http, nc_api, capabilities, bigfolder,
# filters, quota, hydrate) is loaded eagerly by lib/sciebo.sh, so `sciebo
# sync --help` and the test fixtures that source this file directly parse
# none of the run-only work, only cmd_sync itself does.

SYNC_FORCE_DRY=false
SYNC_APPLY=false
SYNC_QUIET=false
SYNC_RESYNC=false
# --force: run entries even while the global pause or a per-pair paused flag
# is active.
SYNC_FORCE=false
# --yes: run apply entries even when MAX_DOWNLOAD_SIZE would skip them.
SYNC_ASSUME_YES=false
SYNC_TIMESTAMP=""
# Leading newline so *$'\n'NAME$'\n'* also matches the first warned name.
SYNC_DUP_WARNED=$'\n'
SYNC_TOTAL=0
SYNC_OK=0
SYNC_FAILED=0
SYNC_SKIPPED=0
# Bisync conflict renames seen this run (sync_report_conflicts).
SYNC_CONFLICTS=0
# Bisync conflict renames seen for the entry currently running.
SYNC_ENTRY_CONFLICTS=0
# Failure text of the current entry's last prepare step.
SYNC_ENTRY_REASON=""
# Names of failed entries this run, newline-separated (run notification).
SYNC_FAILED_NAMES=""
# rclone argument vector for the entry being run (sync_build_args).
SYNC_ARGS=()
# Effective rclone log path for the entry being run (sync_build_args) and
# the byte offset the last run started at, so appended logs are not
# re-parsed twice.
SYNC_LOG_FILE=""
SYNC_LOG_OFFSET=0
# Upload chunk size resolved once per run (capabilities_sync_chunk_size),
# then clamped by MIN_CHUNK_SIZE/MAX_CHUNK_SIZE (policy_chunk_size).
SYNC_CHUNK_SIZE=""
# Extra rclone --exclude patterns collected by the per-entry policy
# preflight (case clashes, end-to-end encrypted folders); sync_build_args
# appends them after the blacklist patterns.
SYNC_POLICY_EXCLUDES=()
# Remote size in bytes for the current entry; sync_download_guard and the
# BIG_FOLDER_EXISTING_POLICY guard share one `rclone size` result (filled by
# lib/sync/quota.sh's remote_size). The per-process cache and the server
# quota probe state (QUOTA_WARN_PERCENT) live in lib/sync/quota.sh, shared
# with doctor.
REMOTE_SIZE=""
# True when the current entry's argv carries the ASK_DELETE guard; the run
# failure path then looks for the rclone abort and may re-run without it.
SYNC_DELETE_GUARD=false
# Set while the delete guard re-run rebuilds its argv.
SYNC_DELETE_GUARD_OVERRIDE=false
# Bound for the local name scans (matches the doctor's default).
SYNC_NAME_SCAN_LIMIT="${DOCTOR_NAME_SCAN_LIMIT:-50000}"

# rclone child of the entry currently running; the INT/TERM handler kills it
# so `kill <sciebo-pid>` does not leave rclone behind.
SYNC_CHILD_PID=""
# Parallel workers: pids and their captured-output files. Slots are freed by
# reaping finished workers (blocking in `wait -n`); empty slots are unset and
# the arrays are compacted on reap.
SYNC_WORKER_PIDS=()
SYNC_WORKER_OUTS=()
# Entry name per worker slot, kept parallel to PIDS/OUTS so a worker that
# dies before writing its result can still be reported by name.
SYNC_WORKER_NAMES=()

usage_sync() {
  usage_emit <<'EOF'
Usage: sciebo sync [options]

Apply sync/pull/bisync entries from config/sources.conf,
config/folders.conf, and config/sources.generated.conf. `sciebo check` is
the same run with --dry-run forced.

Options:
  --apply        transfer data (default for sync; check stays a dry run)
  --dry-run      explicit dry run (default for check)
  --only NAME    run only entries whose sanitized name is NAME; `sciebo
                 list` shows the names
  --list         print the parsed sources (same as `sciebo list`) and exit
  --resync       allow rclone bisync --resync, the first-time
                 initialization. WARNING: resync can copy or delete files
                 in BOTH directions; review a dry run with --resync first
  --yes          download pull/bisync sources even when they exceed
                 MAX_DOWNLOAD_SIZE (the size guard is skipped)
  --metered-ok   run even when the connection is metered (overrides
                 METERED_POLICY=skip/ask for this run)
  --quiet        only print failures, warnings, and the final summary
  --no-lock      do not take the run lock
  --force        run even while paused
  -h, --help     show this help

A directory containing a .nosync file is skipped by sync/pull entries
only; bisync ignores .nosync markers. Local files matching
CONFLICT_PATTERN are not uploaded unless CONFLICT_UPLOAD=1. Pull and
bisync applies whose remote source is larger than MAX_DOWNLOAD_SIZE are
skipped unless --yes is given; with ASK_DOWNLOAD_SIZE=1 and a TTY the
run asks first. On a metered connection entries are skipped when
METERED_POLICY=skip ("metered connection (METERED_POLICY=skip)");
--metered-ok overrides that for the run. Pull and bisync entries are
also failed when free disk space is below MIN_FREE_SPACE ("free space
below MIN_FREE_SPACE") and skipped when it is below
FREE_SPACE_DOWNLOAD ("free space below FREE_SPACE_DOWNLOAD"). The remote
must be set up with `sciebo setup`. Duplicate entry names are refused
for bisync entries and warned about otherwise.

Desktop-parity policies: non-portable names are excluded by default
(INVALID_NAME_POLICY), local case-only name clashes are excluded or
renamed (CASE_CLASH_POLICY), end-to-end encrypted remote folders
(E2EE_POLICY) and server-mounted external storages
(EXTERNAL_STORAGE_POLICY) are checked before a run, and an apply that
would delete more than DELETE_FILES_THRESHOLD files is stopped unless
--yes is given (ASK_DELETE).
EOF
}

usage_check() { usage_sync; }

# sync_entry_status STATUS [REASON] [LOG] - one status row plus optional
# reason/log lines; OK and SKIP rows are suppressed by --quiet, FAIL always
# prints.
sync_entry_status() {
  local status="$1" reason="${2:-}" log="${3:-}" spec=""
  if [[ "$status" == FAIL || "$SYNC_QUIET" == false ]]; then
    spec=${ remote_spec "$ENTRY_REMOTE";}
    printf '%-4s %-6s %-28s %s\n' "$status" "$ENTRY_MODE" "$ENTRY_NAME" "$spec"
    [[ -z "$reason" ]] || printf '     reason: %s\n' "$reason"
    [[ -z "$log" ]] || printf '     log: %s\n' "$log"
  fi
}

# sync_prepare_local - make sure ENTRY_LOCAL exists for the current mode.
# Returns 0=proceed, 1=failed, 2=skipped (dry run, created on first apply).
sync_prepare_local() {
  [[ ! -d "$ENTRY_LOCAL" ]] || return 0
  if [[ "$ENTRY_MODE" != pull ]]; then
    SYNC_ENTRY_REASON="local directory does not exist: ${ENTRY_LOCAL}"
    sync_entry_status FAIL "$SYNC_ENTRY_REASON"
    return 1
  fi
  if [[ "$SYNC_APPLY" == false ]]; then
    SYNC_ENTRY_REASON="local dir does not exist yet (first apply will create it)"
    sync_entry_status SKIP "$SYNC_ENTRY_REASON"
    return 2
  fi
  mkdir -p "$ENTRY_LOCAL" || {
    SYNC_ENTRY_REASON="cannot create local directory: ${ENTRY_LOCAL}"
    sync_entry_status FAIL "$SYNC_ENTRY_REASON"
    return 1
  }
}

# sync_prepare_bisync - bisync-only guards and remote dir creation.
# Returns 0=proceed, 1=failed, 2=skipped (dry run, remote dir missing).
# The mkdir only runs when the (memoized per spec) existence probe says the
# remote dir is missing, so an apply that re-runs over an existing remote
# pays one `rclone lsd` instead of a pointless `rclone mkdir`; a missing dir
# still gets created on the first apply, exactly like the old unconditional
# mkdir made it.
sync_prepare_bisync() {
  local spec="$1"
  if [[ "$SYNC_APPLY" == false ]] && ! remote_dir_exists "$spec"; then
    SYNC_ENTRY_REASON="remote dir does not exist yet (first apply will create it)"
    sync_entry_status SKIP "$SYNC_ENTRY_REASON"
    return 2
  fi
  if [[ "$SYNC_RESYNC" == false ]] && ! bisync_initialized "$ENTRY_NAME"; then
    SYNC_ENTRY_REASON="bisync state missing for '${ENTRY_NAME}'; run '${CLI_NAME} sync --resync --apply --only ${ENTRY_NAME}'"
    sync_entry_status FAIL "$SYNC_ENTRY_REASON"
    return 1
  fi
  if [[ "$SYNC_APPLY" == true ]] && ! remote_dir_exists "$spec" && ! rclone_cmd mkdir "${spec}/"; then
    SYNC_ENTRY_REASON="rclone mkdir failed for ${spec}/"
    sync_entry_status FAIL "$SYNC_ENTRY_REASON"
    return 1
  fi
}

# sync_policy_args OUT CMD [ARG...] - load lib/sync/policy.sh on first use and run
# the policy helper CMD with the argv array name OUT as its first argument:
# the helper appends its rclone arguments (if any) through that nameref
# out-param, so no subshell runs and no newline output is re-parsed. Callers
# can append OUT's contents to an argv array without word splitting.
sync_policy_args() {
  local out="${1:-}" cmd="${2:-}"
  [[ -n "$out" && -n "$cmd" ]] || return 0
  shift 2
  # Load lib/sync/policy.sh on first use: cmd_sync requires it too, but unit and
  # feature probes source this module directly and drive sync_build_args
  # without dispatching. Idempotent (one type lookup once loaded).
  "$cmd" "$out" "$@"
  return 0
}

# sync_args_add_filters FLAGS - append the filter stack to the named argv
# array in order: server filter, clutter/entry filters, conflict and hidden
# excludes, blacklist excludes (one warning when any applied), then the
# name/checksum/symlink policy arguments and the per-entry policy excludes.
sync_args_add_filters() {
  # shellcheck disable=SC2178  # nameref to an argv array
  local -n args_ref="$1"
  local i=0
  # Only the existence of a non-empty server filter matters here; the file
  # body reaches rclone through the path below, so no `cat` of the whole
  # file runs per entry.
  if filter_server_filter_enabled; then
    args_ref+=(--filter-from "$SERVER_EXCLUDE_FILTER")
  fi
  args_ref+=(--filter-from "${FILTER_DIR}/clutter.txt")
  [[ -z "$ENTRY_FILTER" ]] || args_ref+=(--filter-from "${FILTER_DIR}/${ENTRY_FILTER}")
  rclone_filter_excludes "$1" "$ENTRY_NAME" sciebo
  # A pair imported with the desktop client's ignoreHiddenFiles gets the same
  # dotfile exclusion as the global SKIP_HIDDEN=1 (which rclone_filter_excludes
  # already added), so hidden files are not transferred for that pair alone.
  if [[ "${SKIP_HIDDEN:-0}" -ne 1 ]] && manifest_pair_hidden "$ENTRY_NAME"; then
    args_ref+=(--exclude ".*")
  fi
  sync_policy_args args_ref policy_name_exclude_args
  if [[ "${#SYNC_POLICY_EXCLUDES[@]}" -gt 0 ]]; then
    i=0
    while [[ "$i" -lt "${#SYNC_POLICY_EXCLUDES[@]}" ]]; do
      args_ref+=(--exclude "${SYNC_POLICY_EXCLUDES[$i]}")
      i=$((i + 1))
    done
  fi
  sync_policy_args args_ref policy_checksum_args "$ENTRY_MODE"
  sync_policy_args args_ref policy_symlink_args
}

# sync_args_collect_trash TRASH - fill the named argv array with the trash
# pair for this entry. A pull that uses BACKUP_DIR keeps that behavior
# instead, so TRASH stays empty and the mode helper adds --backup-dir; the
# policy helper's --backup-dir/root pair is rebased under the entry name.
sync_args_collect_trash() {
  # shellcheck disable=SC2178  # nameref to an argv array
  local -n trash_ref="$1"
  trash_ref=()
  # MOVE_TO_TRASH uses the same --backup-dir slots as BACKUP_DIR, with a
  # per-entry subdirectory like the pull BACKUP_DIR code below; a pull with
  # BACKUP_DIR keeps that behavior instead.
  if [[ "$ENTRY_MODE" == pull && -n "${BACKUP_DIR:-}" ]]; then
    return 0
  fi
  sync_policy_args trash_ref policy_trash_args "$ENTRY_MODE"
  if [[ "${#trash_ref[@]}" -eq 2 ]]; then
    trash_ref=("${trash_ref[0]}" "${trash_ref[1]%/}/${ENTRY_NAME}")
  fi
}

# sync_args_add_delete_guard FLAGS - append the ASK_DELETE guard arguments to
# the named argv array and set SYNC_DELETE_GUARD when they apply, or an
# explicit --max-delete from MAX_DELETE.
sync_args_add_delete_guard() {
  # shellcheck disable=SC2178  # nameref to an argv array
  local -n args_ref="$1"
  # shellcheck disable=SC2034  # filled through the nameref out-param
  local -a guard_args=()
  SYNC_DELETE_GUARD=false
  case "$MAX_DELETE" in
    '' | *[!0-9]*)
      if [[ "$SYNC_ASSUME_YES" != true && "$SYNC_DELETE_GUARD_OVERRIDE" != true ]]; then
        sync_policy_args guard_args policy_delete_guard_args
        if [[ "${#guard_args[@]}" -gt 0 ]]; then
          args_ref+=("${guard_args[@]}")
          SYNC_DELETE_GUARD=true
        fi
      fi
      ;;
    *) args_ref+=(--max-delete "$((10#$MAX_DELETE))") ;;
  esac
}

# sync_args_add_bwlimit FLAGS - append --bwlimit when a bandwidth limit is
# effective for this run.
sync_args_add_bwlimit() {
  # shellcheck disable=SC2178  # nameref to an argv array
  local -n args_ref="$1"
  local limit=""
  # Forkless capture: bw_effective_limit is pure bash over the marker file
  # and the settings (it always returns 0).
  limit=${ bw_effective_limit;}
  [[ -z "$limit" ]] || args_ref+=(--bwlimit "$limit")
}

# sync_args_set_sync_mode FLAGS TRASH SPEC - fill SYNC_ARGS for a sync or pull
# entry: local-to-remote for sync, remote-to-local for pull, with the pull
# backup-dir or the trash pair. FLAGS and TRASH are argv array names.
sync_args_set_sync_mode() {
  # shellcheck disable=SC2178  # namerefs to argv arrays
  local -n flags_ref="$1" trash_ref="$2"
  local spec="$3" src="" dst=""
  [[ "$TRACK_RENAMES" -ne 1 ]] || flags_ref+=(--track-renames)
  src="${ENTRY_LOCAL}/" dst="${spec}/"
  if [[ "$ENTRY_MODE" == pull ]]; then
    src="${spec}/" dst="${ENTRY_LOCAL}/"
    if [[ -n "${BACKUP_DIR:-}" ]]; then
      if [[ "$SYNC_APPLY" == true ]]; then
        mkdir -p "$BACKUP_DIR" 2>/dev/null || true
      fi
      flags_ref+=(--backup-dir "${BACKUP_DIR}/${ENTRY_NAME}")
    else
      flags_ref+=(${trash_ref[@]+"${trash_ref[@]}"})
    fi
  fi
  SYNC_ARGS=(sync "$src" "$dst" "${flags_ref[@]}" --exclude-if-present .nosync)
}

# sync_args_set_bisync_mode FLAGS TRASH SPEC - fill SYNC_ARGS for a bisync
# entry, including the resync-only flags. FLAGS and TRASH are argv array
# names.
sync_args_set_bisync_mode() {
  # shellcheck disable=SC2178  # namerefs to argv arrays
  local -n flags_ref="$1" trash_ref="$2"
  local spec="$3"
  flags_ref+=(${trash_ref[@]+"${trash_ref[@]}"})
  # --resync-mode is only valid for a resync run; passing it without
  # --resync makes rclone treat every run as a resync, so it is added
  # together with --resync below.
  SYNC_ARGS=(bisync "${ENTRY_LOCAL}/" "${spec}/" --workdir "${BISYNC_DIR}/${ENTRY_NAME}" --conflict-resolve "$BISYNC_CONFLICT_RESOLVE" --conflict-loser "$BISYNC_CONFLICT_LOSER" --conflict-suffix "$BISYNC_CONFLICT_SUFFIX" --max-lock "$BISYNC_MAX_LOCK" "${flags_ref[@]}")
  [[ "$BISYNC_RESILIENT" -ne 1 ]] || SYNC_ARGS+=(--resilient)
  [[ "$BISYNC_RECOVER" -ne 1 ]] || SYNC_ARGS+=(--recover)
  if [[ "$SYNC_RESYNC" == true ]]; then
    SYNC_ARGS+=(--resync-mode "$BISYNC_RESYNC_MODE" --resync)
  fi
}

# sync_build_args SPEC LOGFILE - fill SYNC_ARGS for the entry currently
# parsed into ENTRY_*. Flag order only matters for the server filter, which
# must precede clutter.txt; the policy arguments are appended after the
# blacklist excludes.
sync_build_args() {
  local spec="$1" logfile="$2"
  # shellcheck disable=SC2034  # filled through the nameref out-param
  local -a trash_args=()
  if [[ -n "${SCIEBO_LOG_FILE:-}" ]]; then
    logfile="$SCIEBO_LOG_FILE"
    [[ "$logfile" != "-" ]] || logfile="/dev/stdout"
  fi
  SYNC_LOG_FILE="$logfile"
  local -a flags=(
    --transfers "$TRANSFERS" --checkers "$CHECKERS" --tpslimit "$TPSLIMIT"
    --retries "$RETRIES" --low-level-retries "$LOW_LEVEL_RETRIES"
    --timeout "$TIMEOUT" --contimeout "$CONTIMEOUT" --stats "$STATS"
    --stats-one-line --log-level "$LOG_LEVEL" --log-file "$logfile"
  )
  # Optional resilience/atomicity knobs. RETRIES_SLEEP spaces rclone's
  # high-level retries; TRANSFER_PARTIAL keeps interrupted downloads for
  # resume, and TRANSFER_INPLACE writes straight to the destination.
  [[ -z "${RETRIES_SLEEP:-}" ]] || flags+=(--retries-sleep "$RETRIES_SLEEP")
  [[ "${TRANSFER_PARTIAL:-0}" -ne 1 ]] || flags+=(--partial)
  [[ "${TRANSFER_INPLACE:-0}" -ne 1 ]] || flags+=(--inplace)
  sync_args_add_filters flags
  sync_args_collect_trash trash_args
  [[ -z "$SYNC_CHUNK_SIZE" ]] || flags+=(--webdav-nextcloud-chunk-size "$SYNC_CHUNK_SIZE")
  [[ "$CREATE_EMPTY_SRC_DIRS" -ne 1 ]] || flags+=(--create-empty-src-dirs)
  sync_args_add_delete_guard flags
  sync_args_add_bwlimit flags
  [[ "${HTTP2_ENABLED:-1}" != "0" ]] || flags+=(--disable-http2)
  case "$ENTRY_MODE" in
    sync | pull) sync_args_set_sync_mode flags trash_args "$spec" ;;
    bisync) sync_args_set_bisync_mode flags trash_args "$spec" ;;
  esac
  [[ "$SYNC_APPLY" == true ]] || SYNC_ARGS+=(--dry-run)
}

# sync_quota_warn - run once per sync before the entries: when
# QUOTA_WARN_PERCENT > 0, probe the server quota once (lib/sync/quota.sh)
# and warn when used/total reaches the threshold. A probe error warns once
# and never fails the run.
sync_quota_warn() {
  local threshold="${QUOTA_WARN_PERCENT:-0}" percent=0 used_label="" total_label=""
  case "$threshold" in '' | *[!0-9]*) return 0 ;; esac
  [[ "$threshold" -gt 0 ]] || return 0
  if ! quota_probe; then
    warn "quota guard: cannot read the server quota (${RCLONE_REMOTE}:); QUOTA_WARN_PERCENT check skipped"
    return 0
  fi
  percent="$(quota_used_percent)" || return 0
  [[ "$percent" -ge "$threshold" ]] || return 0
  used_label=${ format_size_bytes "$QUOTA_USED";}
  total_label=${ format_size_bytes "$QUOTA_TOTAL";}
  warn "quota guard: ${percent}% of ${RCLONE_REMOTE}: used (${used_label} of ${total_label}); QUOTA_WARN_PERCENT=${threshold}"
  return 0
}

# _size_guard_verdict BYTES LIMIT - the non-interactive verdicts of the
# MAX_DOWNLOAD_SIZE guard for the entry currently parsed into ENTRY_*:
# rc 0 when BYTES does not exceed LIMIT (silent proceed), and also when
# the over-limit case is already settled without asking - a dry run warns
# and proceeds, SYNC_ASSUME_YES logs the --yes override and proceeds.
# rc 3 tells sync_download_guard its interactive tail still runs (an
# apply over the limit: prompt on a TTY, skip otherwise). The messages
# name MAX_DOWNLOAD_SIZE as LIMIT's source setting; nothing here sets
# SYNC_ENTRY_REASON (the tail owns the skip reasons).
_size_guard_verdict() {
  local bytes="$1" limit="$2" label=""
  [[ "$bytes" -gt "$limit" ]] || return 0
  label=${ format_size_bytes "$bytes";}
  if [[ "$SYNC_APPLY" == false ]]; then
    warn "size guard: ${ENTRY_REMOTE} is ${label} (limit ${MAX_DOWNLOAD_SIZE}); dry run, nothing downloaded"
    return 0
  fi
  if [[ "$SYNC_ASSUME_YES" == true ]]; then
    log "size guard: ${ENTRY_REMOTE} is ${label} (limit ${MAX_DOWNLOAD_SIZE}); overridden by --yes"
    return 0
  fi
  return 3
}

# sync_download_guard SPEC - skip a pull/bisync apply whose remote source
# exceeds MAX_DOWNLOAD_SIZE. Returns 0 to proceed and 2 to skip (the caller
# records the skip, so it is never a failure). A dry run and a size lookup
# that fails only warn. On an apply: SYNC_ASSUME_YES proceeds; otherwise
# ASK_DOWNLOAD_SIZE=1 asks through the shared ui_confirm_tty gate (unified
# [y/yes] dialect; a non-interactive run - no tty or SCIEBO_NON_INTERACTIVE -
# refuses instead of prompting), and anything else skips.
sync_download_guard() {
  local spec="$1" limit="" bytes="" label=""
  [[ "$ENTRY_MODE" == pull || "$ENTRY_MODE" == bisync ]] || return 0
  [[ -n "${MAX_DOWNLOAD_SIZE:-}" ]] || return 0
  limit=${ size_suffix_bytes "$MAX_DOWNLOAD_SIZE";} || return 0
  if ! remote_size "$spec"; then
    warn "size guard: cannot read or parse the remote size for '${ENTRY_REMOTE}'; continuing"
    return 0
  fi
  bytes="$REMOTE_SIZE"
  _size_guard_verdict "$bytes" "$limit" && return 0
  # Over the limit on an apply without --yes. When ASK_DOWNLOAD_SIZE enables
  # it, the shared ui_confirm_tty gate asks (rc 0 proceeds, rc 1 is a
  # decline, rc 2 is not promptable: no tty or SCIEBO_NON_INTERACTIVE - it
  # takes the skip branch here, so a non-interactive run never prompts).
  label=${ format_size_bytes "$bytes";}
  if [[ "${ASK_DOWNLOAD_SIZE:-0}" == "1" ]]; then
    local gate_rc=0
    ui_confirm_tty "remote ${ENTRY_REMOTE} is ${label}; download anyway?" || gate_rc=$?
    [[ "$gate_rc" -eq 0 ]] && return 0
    if [[ "$gate_rc" -eq 1 ]]; then
      SYNC_ENTRY_REASON="size guard: ${ENTRY_REMOTE} is ${label} (limit ${MAX_DOWNLOAD_SIZE}); download declined"
    else
      SYNC_ENTRY_REASON="size guard: ${ENTRY_REMOTE} is ${label} (limit ${MAX_DOWNLOAD_SIZE}); re-run with --yes to download"
    fi
    warn "${SYNC_ENTRY_REASON}"
    return 2
  fi
  SYNC_ENTRY_REASON="size guard: ${ENTRY_REMOTE} is ${label} (limit ${MAX_DOWNLOAD_SIZE}); re-run with --yes to download"
  warn "${SYNC_ENTRY_REASON}"
  return 2
}

# Available-space cache for sync_disk_guard, keyed by the resolved
# destination directory. The guard runs once per pull/bisync entry and several
# entries commonly share a directory or filesystem, so the df call is
# memoized for the run. An empty value is cached too (`+x` presence test), so
# a failed df is not retried per entry.
declare -gA SYNC_DISK_FREE_CACHE=()

# _disk_guard_check_setting SETTING RAW FREE - evaluate one free-space
# setting against FREE bytes available at the destination: rc 0 when RAW
# is blank, unparseable by size_suffix_bytes, or covered by FREE (the
# caller keeps looping); rc 1 when SETTING is MIN_FREE_SPACE and FREE is
# below it, which fails the entry with a status row; rc 2 when it is
# FREE_SPACE_DOWNLOAD, which only skips it. SYNC_ENTRY_REASON is set on
# rc 1 and rc 2 (the caller's guard records that reason).
_disk_guard_check_setting() {
  local setting="$1" raw="$2" free="$3" limit="" free_label="" limit_label=""
  [[ -n "$raw" ]] || return 0
  limit=${ size_suffix_bytes "$raw" 2>/dev/null;} || limit=""
  [[ -n "$limit" && "$free" -lt "$limit" ]] || return 0
  free_label=${ format_size_bytes "$free";}
  limit_label=${ format_size_bytes "$limit";}
  SYNC_ENTRY_REASON="free space below ${setting} (${free_label} < ${limit_label})"
  if [[ "$setting" == "MIN_FREE_SPACE" ]]; then
    sync_entry_status FAIL "$SYNC_ENTRY_REASON"
    return 1
  fi
  sync_entry_status SKIP "$SYNC_ENTRY_REASON"
  return 2
}

# sync_disk_guard DIR - pull/bisync disk-space guard. Available space comes
# from `df -Pk DIR`; the check is skipped when DIR does not exist yet and
# when neither MIN_FREE_SPACE nor FREE_SPACE_DOWNLOAD is set (no df call
# then). A destination below MIN_FREE_SPACE fails the entry (1), below
# FREE_SPACE_DOWNLOAD it is skipped (2). Values parse with
# size_suffix_bytes; an unparseable setting or a df failure only proceeds.
sync_disk_guard() {
  local dir="$1" free="" setting="" rc=0
  [[ "$ENTRY_MODE" == pull || "$ENTRY_MODE" == bisync ]] || return 0
  [[ -n "${MIN_FREE_SPACE:-}" || -n "${FREE_SPACE_DOWNLOAD:-}" ]] || return 0
  [[ -d "$dir" ]] || return 0
  if [[ -n "${SYNC_DISK_FREE_CACHE["$dir"]+x}" ]]; then
    free="${SYNC_DISK_FREE_CACHE["$dir"]}"
  else
    free="$(df -Pk "$dir" 2>/dev/null | LC_ALL=C awk 'NR == 2 && $4 ~ /^[0-9]+$/ { print $4 * 1024; exit }')"
    SYNC_DISK_FREE_CACHE["$dir"]="$free"
  fi
  case "$free" in
    '' | *[!0-9]*) return 0 ;;
  esac
  # MIN_FREE_SPACE fails the entry, FREE_SPACE_DOWNLOAD only skips it; the
  # two checks differ in nothing else, so one helper serves the loop.
  for setting in MIN_FREE_SPACE FREE_SPACE_DOWNLOAD; do
    rc=0
    _disk_guard_check_setting "$setting" "${!setting:-}" "$free" || rc=$?
    [[ "$rc" -eq 0 ]] || return "$rc"
  done
  return 0
}

# sync_warn_invalid_names DIR - INVALID_NAME_POLICY=warn scan: one warning
# with the count and up to three non-portable names below DIR. Read-only and
# bounded at SYNC_NAME_SCAN_LIMIT paths; never fails the entry.
sync_warn_invalid_names() {
  local dir="${1:-}" limit="${SYNC_NAME_SCAN_LIMIT:-50000}" count=0 invalid=0
  local path="" base="" rel="" rel_label="" samples=""
  [[ -d "$dir" ]] || return 0
  while IFS= read -r -d '' path; do
    count=$((count + 1))
    if [[ "$count" -gt "$limit" ]]; then
      warn "invalid names: ${dir} scan truncated at ${limit} paths; names beyond that were not checked"
      break
    fi
    base="${path##*/}"
    policy_invalid_name "$base" || continue
    invalid=$((invalid + 1))
    [[ "$invalid" -gt 3 ]] || {
      case "$dir" in
        /) rel="${path#/}" ;;
        *) rel="${path#"$dir"/}" ;;
      esac
      rel_label=${ printable "$rel";}
      samples="${samples}${samples:+, }'${rel_label}'"
    }
  done < <(find -P "$dir" -print0 2>/dev/null)
  [[ "$invalid" -gt 0 ]] || return 0
  warn "invalid names: ${invalid} non-portable name(s) under ${dir} (INVALID_NAME_POLICY=warn): ${samples}"
  return 0
}

# sync_case_clash_warn PREFIX COUNT MESSAGE - one capped per-pair collision
# warning: only the first three collisions of a family are printed; the
# scan's trailing summary counts the rest.
sync_case_clash_warn() {
  local prefix="$1" count="$2"
  shift 2
  [[ "$count" -gt 3 ]] || warn "${prefix}: $*"
  return 0
}

# sync_case_clash_scan PREFIX TARGET PAIRS HANDLER - walk the
# FIRST<TAB>SECOND case-clash pairs in LC_ALL=C order, calling
# HANDLER PREFIX TARGET POLICY FIRST SECOND COUNT once per pair. The handler
# appends any exclude pattern itself and reports its per-pair line through
# sync_case_clash_warn. After the walk one summary warns when more than
# three collisions were seen. PREFIX is "case clash" or "case clash
# (remote)"; TARGET names the scanned local dir or remote spec.
sync_case_clash_scan() {
  local prefix="$1" target="$2" pairs="$3" handler="$4"
  local policy="${CASE_CLASH_POLICY:-exclude}" line="" first="" second="" count=0
  while IFS= read -r line; do
    record_split "$line" first second
    [[ -n "$first" && -n "$second" ]] || continue
    count=$((count + 1))
    "$handler" "$prefix" "$target" "$policy" "$first" "$second" "$count"
  done <<<"$pairs"
  if [[ "$count" -gt 3 ]]; then
    warn "${prefix}: ${count} case-only collision(s) under ${target} (CASE_CLASH_POLICY=${policy})"
  fi
  return 0
}

# _case_clash_rename PREFIX COUNT DIR SECOND FIRST_LABEL SECOND_LABEL - the
# CASE_CLASH_POLICY=rename arm: rename the loser (SECOND) below DIR on an
# apply, fall back to excluding it when the rename fails, or only warn
# about the planned rename on a dry run. FIRST_LABEL/SECOND_LABEL are the
# display-sanitized names the caller already computed. Returns 0.
_case_clash_rename() {
  local prefix="$1" count="$2" dir="$3" second="$4"
  local first_label="$5" second_label="$6" newrel="" newrel_label=""
  if [[ "$SYNC_APPLY" == true ]]; then
    if newrel="$(policy_rename_case_clash "$dir" "$second")"; then
      newrel_label=${ printable "$newrel";}
      sync_case_clash_warn "$prefix" "$count" "renamed '${second_label}' to '${newrel_label}' (keeping '${first_label}')"
    else
      SYNC_POLICY_EXCLUDES[${#SYNC_POLICY_EXCLUDES[@]}]=${ blacklist_exclude_pattern "$second";}
      warn "${prefix}: cannot rename '${second_label}'; excluding it instead"
    fi
  else
    sync_case_clash_warn "$prefix" "$count" "would rename '${second_label}' to a '(case conflict)' name (dry run; keeping '${first_label}')"
  fi
  return 0
}

# sync_case_clash_local_pair PREFIX DIR POLICY FIRST SECOND COUNT - handle one
# local collision: exclude the loser, rename it on an apply, or warn, as
# CASE_CLASH_POLICY requests.
sync_case_clash_local_pair() {
  local prefix="$1" dir="$2" policy="$3" first="$4" second="$5" count="$6"
  local first_label="" second_label=""
  first_label=${ printable "$first";}
  second_label=${ printable "$second";}
  case "$policy" in
    exclude)
      SYNC_POLICY_EXCLUDES[${#SYNC_POLICY_EXCLUDES[@]}]=${ blacklist_exclude_pattern "$second";}
      sync_case_clash_warn "$prefix" "$count" "excluding '${second_label}' (keeping '${first_label}')"
      ;;
    rename) _case_clash_rename "$prefix" "$count" "$dir" "$second" "$first_label" "$second_label" ;;
    *)
      sync_case_clash_warn "$prefix" "$count" "'${first_label}' and '${second_label}' differ only by case (CASE_CLASH_POLICY=warn)"
      ;;
  esac
  return 0
}

# sync_case_clash_preflight DIR - apply CASE_CLASH_POLICY to the local
# case-only path collisions below DIR. policy_case_clashes prints each pair
# in LC_ALL=C order: the first name is kept, the second is excluded or
# renamed. Warn, exclude, and rename all report the collision; a dry run
# only prints the planned rename and never touches the tree.
sync_case_clash_preflight() {
  local dir="${1:-}" pairs=""
  [[ -d "$dir" ]] || return 0
  pairs=${ policy_case_clashes "$dir";} || pairs=""
  [[ -n "$pairs" ]] || return 0
  sync_case_clash_scan "case clash" "$dir" "$pairs" sync_case_clash_local_pair
  return 0
}

# sync_local_policy_preflight - local-tree policies for the entry currently
# parsed into ENTRY_*: INVALID_NAME_POLICY=warn scans for non-portable
# names, then CASE_CLASH_POLICY handles case-only collisions. Read-only
# except for CASE_CLASH_POLICY=rename on an apply.
sync_local_policy_preflight() {
  [[ -d "$ENTRY_LOCAL" ]] || return 0
  [[ "${INVALID_NAME_POLICY:-exclude}" != "warn" ]] || sync_warn_invalid_names "$ENTRY_LOCAL"
  sync_case_clash_preflight "$ENTRY_LOCAL"
  return 0
}

# sync_case_clash_remote_pair PREFIX SPEC POLICY FIRST SECOND COUNT - handle
# one remote collision: the remote tree is never modified, so exclude (and
# rename, which falls back to exclude) adds the escaped recursive exclude
# and warns; warn only warns.
sync_case_clash_remote_pair() {
  local prefix="$1" _spec="$2" policy="$3" first="$4" second="$5" count="$6" pattern=""
  local first_label="" second_label=""
  first_label=${ printable "$first";}
  second_label=${ printable "$second";}
  pattern="$(policy_remote_case_exclude "$second")"
  case "$policy" in
    exclude)
      [[ -n "$pattern" ]] && SYNC_POLICY_EXCLUDES[${#SYNC_POLICY_EXCLUDES[@]}]="$pattern"
      sync_case_clash_warn "$prefix" "$count" "excluding '${second_label}' (keeping '${first_label}')"
      ;;
    rename)
      [[ -n "$pattern" ]] && SYNC_POLICY_EXCLUDES[${#SYNC_POLICY_EXCLUDES[@]}]="$pattern"
      sync_case_clash_warn "$prefix" "$count" "cannot rename '${second_label}' server-side; excluding it instead (keeping '${first_label}')"
      ;;
    *)
      sync_case_clash_warn "$prefix" "$count" "'${first_label}' and '${second_label}' differ only by case (CASE_CLASH_POLICY=warn)"
      ;;
  esac
  return 0
}

# sync_case_clash_remote_preflight SPEC - opt-in online case-clash scan of the
# entry's remote subtree, triggered only by CASE_CLASH_REMOTE_SCAN=1 (default
# 0) when the remote exists. A full remote listing is expensive, so this is
# off by default. policy_case_clashes_remote reports each FIRST<TAB>SECOND
# pair in LC_ALL=C order; the loser (SECOND) is handled exactly like the local
# counterpart, but the remote tree is never modified: `exclude` adds the
# escaped recursive exclude and warns, `rename` warns that a server-side
# rename is not attempted and excludes the loser instead, and `warn` only
# warns. Read-only, never fails the entry, and silent when nothing is found
# or the listing fails.
sync_case_clash_remote_preflight() {
  local spec="${1:-}" pairs=""
  [[ "${CASE_CLASH_REMOTE_SCAN:-0}" == "1" ]] || return 0
  [[ -n "$spec" ]] || return 0
  remote_dir_exists "$spec" || return 0
  if ! pairs="$(policy_case_clashes_remote "$spec")"; then
    warn "case clash (remote): could not list ${spec}; skipping the remote case scan"
    return 0
  fi
  [[ -n "$pairs" ]] || return 0
  sync_case_clash_scan "case clash (remote)" "$spec" "$pairs" sync_case_clash_remote_pair
  return 0
}

# sync_policy_confirm_external - the external-storage ask confirmation.
# ui_confirm_tty's rc 0 confirms; rc 1 (declined) and rc 2 (no tty, or
# SCIEBO_NON_INTERACTIVE) both decline - rc 2 takes exactly the branch this
# gate took when stdin was not a tty, so sync now honors
# SCIEBO_NON_INTERACTIVE on a terminal too (approved change).
sync_policy_confirm_external() {
  local rc=0
  ui_confirm_tty "external storage: ${ENTRY_REMOTE} is mounted external storage; sync anyway?" || rc=$?
  [[ "$rc" -eq 0 ]]
}

# sync_e2ee_preflight - E2EE_POLICY=warn/exclude preflight for pull and
# bisync entries. Reported encrypted subfolders are excluded (exclude) or
# warned about (warn); an entry whose own remote root is E2EE is skipped
# because the encrypted blobs cannot be synced meaningfully. Returns
# 0=proceed, 2=skip. Servers without nc:is-encrypted and non-Nextcloud
# remotes stay silent.
sync_e2ee_preflight() {
  local policy="${E2EE_POLICY:-exclude}" rc=0
  [[ "$ENTRY_MODE" == pull || "$ENTRY_MODE" == bisync ]] || return 0
  POLICY_REMOTE_ROOT="$ENTRY_REMOTE"
  POLICY_REMOTE_NAME="$ENTRY_NAME"
  POLICY_REMOTE_STYLE=apply
  POLICY_REMOTE_CONFIRM=""
  POLICY_REMOTE_SINK=warn
  policy_remote_paths_apply "$policy" nc_e2ee_paths e2ee SYNC_POLICY_EXCLUDES POLICY_REMOTE_COUNT || rc=$?
  if [[ "$rc" -eq 2 ]]; then
    SYNC_ENTRY_REASON="$POLICY_REMOTE_SKIP_REASON"
  fi
  return "$rc"
}

# sync_external_preflight - EXTERNAL_STORAGE_POLICY preflight for the entry
# currently parsed into ENTRY_*. A remote root on mounted external storage
# is skipped (skip), warned about (warn), or confirmed on a TTY (ask);
# external subfolders only warn. Returns 0=proceed, 2=skip; servers without
# oc:permissions and non-Nextcloud remotes stay silent.
sync_external_preflight() {
  local policy="${EXTERNAL_STORAGE_POLICY:-ask}" rc=0
  # POLICY_REMOTE_* are read by policy_remote_paths_apply in lib/sync/remote_paths.sh,
  # which shellcheck cannot follow (no direct `source` line here; lib/sciebo.sh
  # loads it eagerly at runtime).
  # shellcheck disable=SC2034  # read by policy_remote_paths_apply
  POLICY_REMOTE_ROOT="$ENTRY_REMOTE"
  # shellcheck disable=SC2034  # read by policy_remote_paths_apply
  POLICY_REMOTE_NAME="$ENTRY_NAME"
  # shellcheck disable=SC2034  # read by policy_remote_paths_apply
  POLICY_REMOTE_STYLE=apply
  # shellcheck disable=SC2034  # read by policy_remote_paths_apply
  POLICY_REMOTE_CONFIRM=sync_policy_confirm_external
  # shellcheck disable=SC2034  # read by policy_remote_paths_apply
  POLICY_REMOTE_SINK=warn
  policy_remote_paths_apply "$policy" nc_external_paths external SYNC_POLICY_EXCLUDES POLICY_REMOTE_COUNT || rc=$?
  if [[ "$rc" -eq 2 ]]; then
    SYNC_ENTRY_REASON="$POLICY_REMOTE_SKIP_REASON"
  fi
  return "$rc"
}

# sync_big_folder_existing_guard SPEC - apply BIG_FOLDER_EXISTING_POLICY to
# an already-configured entry whose remote grew past BIG_FOLDER_SIZE.
# Returns 0=proceed, 2=skip. The remote size is shared with the download
# guard; a missing size only proceeds. allow stays silent, warn warns, and
# skip skips the entry.
sync_big_folder_existing_guard() {
  local spec="$1" policy="${BIG_FOLDER_EXISTING_POLICY:-warn}" limit="" bytes="" label=""
  [[ -n "${BIG_FOLDER_SIZE:-}" ]] || return 0
  [[ "$policy" != "allow" ]] || return 0
  limit=${ size_suffix_bytes "$BIG_FOLDER_SIZE" 2>/dev/null;} || return 0
  if [[ -z "$REMOTE_SIZE" ]] && ! remote_size "$spec"; then
    return 0
  fi
  bytes="$REMOTE_SIZE"
  [[ "$bytes" -gt "$limit" ]] || return 0
  label=${ format_size_bytes "$bytes";}
  if [[ "$policy" == "skip" ]]; then
    SYNC_ENTRY_REASON="big folder: ${ENTRY_REMOTE} is ${label} (limit ${BIG_FOLDER_SIZE}); skipped by BIG_FOLDER_EXISTING_POLICY=skip"
    warn "${SYNC_ENTRY_REASON}"
    return 2
  fi
  warn "big folder: ${ENTRY_REMOTE} is ${label} (limit ${BIG_FOLDER_SIZE}); BIG_FOLDER_EXISTING_POLICY=${policy}"
  return 0
}

# sync_policy_preflight SPEC - remote and local policy checks for the entry
# currently parsed into ENTRY_*. Returns 0=proceed or 2=skip with
# SYNC_ENTRY_REASON set; the remote checks run first so a skipped entry
# never renames local files.
sync_policy_preflight() {
  local spec="$1" rc=0
  sync_e2ee_preflight || rc=$?
  [[ "$rc" -eq 0 ]] || return "$rc"
  sync_external_preflight || rc=$?
  [[ "$rc" -eq 0 ]] || return "$rc"
  sync_big_folder_existing_guard "$spec" || rc=$?
  [[ "$rc" -eq 0 ]] || return "$rc"
  sync_local_policy_preflight
  sync_case_clash_remote_preflight "$spec"
  return $?
}

# sync_step_result RC - record a failed guard result in runstate and return
# RC: 0 passes through, 2 records skipped, anything else records failed. The
# guard must have set SYNC_ENTRY_REASON.
sync_step_result() {
  local rc="$1"
  [[ "$rc" -ne 0 ]] || return 0
  if [[ "$rc" -eq 2 ]]; then
    sync_runstate_record skipped 0 "" "$SYNC_ENTRY_REASON"
  else
    sync_runstate_record failed "$rc" "" "$SYNC_ENTRY_REASON"
  fi
  return "$rc"
}

# sync_guard_run CMD... - run a preflight guard; on failure record the
# runstate result and return the guard's status.
sync_guard_run() {
  local rc=0
  "$@" || rc=$?
  sync_step_result "$rc"
  return "$rc"
}

# _sync_file_size FILE - print FILE's size in bytes, or nothing when it
# cannot be read. A thin wrapper over core.sh's flavour-cached file_size
# (the old inline BSD/GNU stat dance and the standalone fallback both live
# there now); the name is kept for sync_log_offset and any external stubbing.
_sync_file_size() {
  file_size "${1:-}"
}

# sync_log_offset - set SYNC_LOG_OFFSET to the current size of SYNC_LOG_FILE
# (0 when it does not exist yet), so a later sync_record_errors only reads
# what this run appended.
sync_log_offset() {
  local size=""
  SYNC_LOG_OFFSET=0
  [[ -f "$SYNC_LOG_FILE" ]] || return 0
  size=${ _sync_file_size "$SYNC_LOG_FILE";}
  case "$size" in '' | *[!0-9]*) size=0 ;; esac
  SYNC_LOG_OFFSET="$size"
}

# sync_run_rclone - run SYNC_ARGS in the background so its pid can be
# recorded and the wait is interruptible: a trap on INT/TERM runs
# immediately and can kill rclone, while a foreground command defers the
# trap until it exits. Returns rclone's exit status; SYNC_CHILD_PID is set
# while it runs.
sync_run_rclone() {
  local rc=0
  SYNC_CHILD_PID=""
  rclone_cmd "${SYNC_ARGS[@]}" &
  SYNC_CHILD_PID=$!
  wait "$SYNC_CHILD_PID" || rc=$?
  SYNC_CHILD_PID=""
  return "$rc"
}

# sync_delete_guard_retry SPEC LOGFILE - the ASK_DELETE guard aborted the
# run (policy_delete_guard_hit). The shared ui_confirm_tty gate asks once
# (unified [y/yes] dialect; rc 2 - no tty or SCIEBO_NON_INTERACTIVE - refuses
# without prompting) and, on acceptance, the entry re-runs without
# --max-delete; a declined prompt or a non-interactive run fails the entry
# with a message naming DELETE_FILES_THRESHOLD and --yes. Returns 0 when the
# re-run succeeded, 1 when the entry failed without a re-run.
sync_delete_guard_retry() {
  local spec="$1" logfile="$2" rc=0 gate_rc=0
  ui_confirm_tty "delete guard: this run would delete more than ${DELETE_FILES_THRESHOLD} file(s); continue anyway?" || gate_rc=$?
  if [[ "$gate_rc" -eq 0 ]]; then
    warn "delete guard: overridden for '${ENTRY_NAME}' (continuing without --max-delete ${DELETE_FILES_THRESHOLD})"
  elif [[ "$gate_rc" -eq 1 ]]; then
    SYNC_ENTRY_REASON="delete guard: more than ${DELETE_FILES_THRESHOLD} file(s) to delete; declined"
    warn "${SYNC_ENTRY_REASON}"
    return 1
  else
    SYNC_ENTRY_REASON="delete guard: more than ${DELETE_FILES_THRESHOLD} file(s) to delete; re-run with --yes to allow"
    warn "${SYNC_ENTRY_REASON}"
    return 1
  fi
  SYNC_DELETE_GUARD_OVERRIDE=true
  sync_build_args "$spec" "$logfile"
  SYNC_DELETE_GUARD_OVERRIDE=false
  sync_log_offset
  rc=0
  sync_run_rclone || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    return 0
  fi
  sync_record_errors "$SYNC_LOG_FILE"
  SYNC_ENTRY_REASON="rclone ${ENTRY_MODE} failed after the delete guard override (exit ${rc})"
  warn "${SYNC_ENTRY_REASON}"
  return 1
}

# sync_sample_collect SEEN_VAR SAMPLES_VAR PATH - when PATH is non-empty and
# not already in the associative array named by SEEN_VAR, record it there and
# append its display-sanitized form to the comma-separated list named by
# SAMPLES_VAR. Shared by sync_report_plan and sync_report_conflicts, which cap
# the list at three by checking ${#SEEN_VAR[@]}. rc 1 when nothing was added.
sync_sample_collect() {
  # shellcheck disable=SC2178  # namerefs to a set and a caller-local string
  local -n seen_ref="$1"
  # shellcheck disable=SC2178  # nameref to a caller-local string
  local -n samples_ref="$2"
  local path="$3" label=""
  [[ -n "$path" ]] || return 1
  [[ -z "${seen_ref[$path]:-}" ]] || return 1
  seen_ref["$path"]=1
  label=${ printable "$path";}
  samples_ref="${samples_ref:+${samples_ref}, }${label}"
  return 0
}

# sync_report_plan LOGFILE - print one "plan:" line after a successful dry
# run: how many copies, deletes, and other skipped actions rclone logged,
# with up to three example paths. Best effort: a missing log or parsing
# trouble prints nothing and never fails the run.
sync_report_plan() {
  local logfile="$1" kind="" path="" line="" copy=0 delete=0 other=0
  local -A seen=()
  local samples=""
  [[ -f "$logfile" ]] || return 0
  while IFS= read -r line; do
    record_split "$line" kind path
    case "$kind" in
      copy) copy=$((copy + 1)) ;;
      delete) delete=$((delete + 1)) ;;
      *) other=$((other + 1)) ;;
    esac
    [[ -n "$path" ]] || continue
    # Stop tracking and sanitizing once three samples are collected; on a
    # large tree the old unconditional seen-set was quadratic.
    [[ "${#seen[@]}" -lt 3 ]] || continue
    sync_sample_collect seen samples "$path" || continue
  done < <(
    LC_ALL=C awk '
      {
        gsub(/\033\[[0-9;]*[A-Za-z]/, "")
        if ($0 !~ /Skipped .* as --dry-run is set/) next
        path = $0
        sub(/: Skipped .*$/, "", path)
        sub(/^[^ ]+ +[^ ]+ +[A-Z]+: +/, "", path)
        kind = "other"
        if ($0 ~ /Skipped copy/) kind = "copy"
        else if ($0 ~ /Skipped delete/) kind = "delete"
        print kind "\t" path
      }
    ' "$logfile" 2>/dev/null
  )
  if [[ "$copy" -eq 0 && "$delete" -eq 0 && "$other" -eq 0 ]]; then
    printf 'plan: no changes\n'
    return 0
  fi
  [[ "$copy" -eq 0 ]] || line="${copy} to copy"
  [[ "$delete" -eq 0 ]] || line="${line:+${line}, }${delete} to delete"
  [[ "$other" -eq 0 ]] || line="${line:+${line}, }${other} other"
  printf 'plan: %s%s\n' "$line" "${samples:+ (e.g. ${samples})}"
  return 0
}

# sync_report_conflicts LOGFILE - count bisync conflict renames in LOGFILE
# (Path1/Path2 copy), add them to SYNC_CONFLICTS, and print one "conflicts:"
# line with up to three example paths. Conflicts are printed even under
# --quiet because they need attention. Best effort, never fails the run.
sync_report_conflicts() {
  local logfile="$1" line="" path="" found=0
  local -A seen=()
  local samples=""
  [[ -f "$logfile" ]] || return 0
  while IFS= read -r line; do
    case "$line" in
      *"Renaming Path"*) ;;
      *) continue ;;
    esac
    found=$((found + 1))
    path="${line##* - }"
    [[ -n "$path" && "$path" != "$line" ]] || continue
    [[ "${#seen[@]}" -lt 3 ]] || continue
    sync_sample_collect seen samples "$path" || continue
  done < <(LC_ALL=C awk '{ gsub(/\033\[[0-9;]*[A-Za-z]/, ""); print }' "$logfile" 2>/dev/null)
  SYNC_CONFLICTS=$((SYNC_CONFLICTS + found))
  SYNC_ENTRY_CONFLICTS=$((SYNC_ENTRY_CONFLICTS + found))
  [[ "$found" -gt 0 ]] || return 0
  printf 'conflicts: %s copy(ies) created%s\n' "$found" "${samples:+ (e.g. ${samples})}"
  return 0
}

# sync_record_errors LOGFILE - best-effort blacklist recording for the entry
# currently parsed into ENTRY_*: parse rclone's plain `ERROR : <path>:
# <message>` log lines and record every path. Any parse or write problem is
# ignored; a failure here never changes the entry's status.
sync_record_errors() {
  local logfile="$1" path="" path_label="" message="" record_line="" from=$((SYNC_LOG_OFFSET + 1))
  [[ "${BLACKLIST_ENABLED:-1}" == "1" ]] || return 0
  [[ -n "$logfile" && "$logfile" != "-" && "$logfile" != "/dev/stdout" ]] || return 0
  [[ -f "$logfile" ]] || return 0
  # One blacklist_record_many call for the whole run: parse and sanitize
  # every ERROR path in order, then let the batch apply all increments with a
  # single atomic rewrite instead of one read/write per line.
  tail -c "+${from}" "$logfile" 2>/dev/null |
    LC_ALL=C awk '
      {
        gsub(/\033\[[0-9;]*[A-Za-z]/, "")
        offset = index($0, "ERROR : ")
        if (offset == 0) next
        rest = substr($0, offset + 8)
        split_at = index(rest, ": ")
        if (split_at == 0) next
        printf "%s\t%s\n", substr(rest, 1, split_at - 1), substr(rest, split_at + 2)
      }
    ' 2>/dev/null |
    while IFS= read -r record_line; do
      record_split "$record_line" path message
      [[ -n "$path" ]] || continue
      # Strip control bytes (OSC/CR/...) before the path reaches state files
      # and report output; rclone never needs them back.
      path_label=${ printable "$path";}
      printf '%s\t%s\n' "$path_label" "$message"
    done |
    blacklist_record_many "$ENTRY_NAME" >/dev/null 2>&1 || true
  return 0
}

# sync_runstate_record STATUS RC LOG DETAIL - best-effort last-run record for
# the entry currently parsed into ENTRY_*; a state-directory problem is
# harmless.
sync_runstate_record() {
  runstate_write "$ENTRY_NAME" "$ENTRY_MODE" "$1" "$2" "$3" "$SYNC_ENTRY_CONFLICTS" "$4" || true
  return 0
}

# sync_pair_paused_guard - skip an entry whose persisted per-pair paused flag
# is set (folders pause, account import). Returns 0 to proceed, 2 to skip with
# SYNC_ENTRY_REASON set; --force overrides. Best effort: a missing flag file
# means "not paused".
sync_pair_paused_guard() {
  [[ "$SYNC_FORCE" == true ]] && return 0
  manifest_pair_paused "$ENTRY_NAME" || return 0
  SYNC_ENTRY_REASON="pair is paused; run '${CLI_NAME} folders resume ${ENTRY_NAME}' to sync it"
  sync_entry_status SKIP "$SYNC_ENTRY_REASON"
  return 2
}

# sync_run_preflight SPEC - reset the per-entry state and run the metered gate
# plus the ordered preflight guards (disk, download, local, bisync, policy).
# Returns 0 to proceed or the first guard's skip/fail status; each failing
# guard has already recorded its runstate row.
sync_run_preflight() {
  local spec="$1" rc=0
  SYNC_ENTRY_CONFLICTS=0
  SYNC_ENTRY_REASON=""
  SYNC_POLICY_EXCLUDES=()
  REMOTE_SIZE=""
  SYNC_DELETE_GUARD=false
  SYNC_DELETE_GUARD_OVERRIDE=false
  rc=0
  sync_guard_run sync_pair_paused_guard || return $?
  net_gate || rc=$?
  if [[ "$rc" -eq 2 ]]; then
    SYNC_ENTRY_REASON="metered connection (METERED_POLICY=${METERED_POLICY:-allow})"
    sync_entry_status SKIP "$SYNC_ENTRY_REASON"
    sync_step_result 2 || return $?
  fi
  sync_guard_run sync_disk_guard "$ENTRY_LOCAL" || return $?
  sync_guard_run sync_download_guard "$spec" || return $?
  sync_guard_run sync_prepare_local || return $?
  if [[ "$ENTRY_MODE" == bisync ]]; then
    sync_guard_run sync_prepare_bisync "$spec" || return $?
  fi
  sync_guard_run sync_policy_preflight "$spec" || return $?
  return 0
}

# sync_finish_entry SPEC LOGFILE RC - post-run handling: on failure record the
# blacklist errors or retry around the ASK_DELETE guard, then print the status
# row, report bisync conflicts, record runstate, and print the plan for a dry
# run. Returns 0=ok, 1=failed.
sync_finish_entry() {
  local spec="$1" logfile="$2" rc="$3"
  if [[ "$rc" -ne 0 ]]; then
    if [[ "$SYNC_DELETE_GUARD" == true ]] && policy_delete_guard_hit "$SYNC_LOG_FILE"; then
      # The guard aborted the run; its log carries no per-file errors, so the
      # blacklist is only fed from a retry attempt (inside the helper).
      rc=0
      sync_delete_guard_retry "$spec" "$logfile" || rc=$?
    else
      sync_record_errors "$SYNC_LOG_FILE"
    fi
  fi
  if [[ "$rc" -eq 0 ]]; then
    sync_entry_status OK
  else
    sync_entry_status FAIL "${SYNC_ENTRY_REASON:-rclone ${ENTRY_MODE} failed (exit ${rc})}" "$logfile"
  fi
  if [[ "$ENTRY_MODE" == bisync ]]; then
    sync_report_conflicts "$logfile"
  fi
  if [[ "$rc" -ne 0 ]]; then
    sync_runstate_record failed "$rc" "$logfile" "${SYNC_ENTRY_REASON:-rclone ${ENTRY_MODE} failed (exit ${rc})}"
    return 1
  fi
  sync_runstate_record ok 0 "$logfile" ""
  if [[ "$SYNC_APPLY" == false && "$SYNC_QUIET" == false ]]; then
    sync_report_plan "$logfile"
  fi
  return 0
}

# sync_run_entry - run the entry currently parsed into ENTRY_*; returns
# 0=ok, 1=failed, 2=skipped. Prints its own status lines and records the
# outcome for `sciebo status`.
sync_run_entry() {
  local spec="" logfile="" log_suffix="" rc=0
  spec=${ remote_spec "$ENTRY_REMOTE";}
  sync_run_preflight "$spec" || return $?
  [[ "$SYNC_APPLY" == true ]] || log_suffix="-dryrun"
  logfile="${LOG_DIR}/${ENTRY_NAME}-${SYNC_TIMESTAMP}${log_suffix}.log"
  sync_build_args "$spec" "$logfile"
  if [[ "$ENTRY_MODE" == pull || "$ENTRY_MODE" == bisync ]] && [[ -n "${BIG_FOLDER_SIZE:-}" ]]; then
    bigfolder_notify "$ENTRY_NAME" "$ENTRY_REMOTE" || true
  fi
  sync_log_offset
  rc=0
  sync_run_rclone || rc=$?
  sync_finish_entry "$spec" "$logfile" "$rc"
}

# sync_warn_duplicate NAME MODE - warn once per duplicated name; bisync
# entries are refused by the caller because they would share state.
sync_warn_duplicate() {
  local name="$1" mode="$2"
  case "$SYNC_DUP_WARNED" in
    *$'\n'"${name}"$'\n'*) return 0 ;;
  esac
  SYNC_DUP_WARNED="${SYNC_DUP_WARNED}${name}"$'\n'
  warn "duplicate source name '${name}' (${mode}): logs may collide; rename one entry"
}

# sync_run_one_line LINE [ONLY] - validate and run one manifest line in the
# current shell (the shared per-entry work). Increments
# SYNC_TOTAL/SYNC_OK/SYNC_FAILED/SYNC_SKIPPED; a parse error and a
# duplicated bisync name fail the entry, an entry filtered out by ONLY is
# counted as skipped. The serial path calls it inline; the parallel path
# runs it in a worker subshell (see sync_parallel_worker).
sync_run_one_line() {
  local line="$1" only="${2:-}" rc=0
  if ! manifest_parse_line "$line"; then
    SYNC_TOTAL=$((SYNC_TOTAL + 1))
    SYNC_FAILED=$((SYNC_FAILED + 1))
    sync_note_failure "${ENTRY_NAME:-<invalid>}"
    sync_entry_status FAIL "$ENTRY_ERROR"
    return 0
  fi
  if [[ -n "$only" && "$ENTRY_NAME" != "$only" ]]; then
    SYNC_SKIPPED=$((SYNC_SKIPPED + 1))
    sync_entry_status SKIP
    return 0
  fi
  SYNC_TOTAL=$((SYNC_TOTAL + 1))
  if manifest_has_duplicate_name "$ENTRY_NAME"; then
    if [[ "$ENTRY_MODE" == bisync ]]; then
      SYNC_FAILED=$((SYNC_FAILED + 1))
      sync_note_failure "$ENTRY_NAME"
      sync_entry_status FAIL "duplicate source name '${ENTRY_NAME}'; bisync state would be shared"
      return 0
    fi
    sync_warn_duplicate "$ENTRY_NAME" "$ENTRY_MODE"
  fi
  rc=0
  sync_run_entry || rc=$?
  case "$rc" in
    0) SYNC_OK=$((SYNC_OK + 1)) ;;
    2) SYNC_SKIPPED=$((SYNC_SKIPPED + 1)) ;;
    *)
      SYNC_FAILED=$((SYNC_FAILED + 1))
      sync_note_failure "$ENTRY_NAME"
      ;;
  esac
}

# sync_note_failure NAME - remember one failed entry for the run
# notification.
sync_note_failure() {
  SYNC_FAILED_NAMES="${SYNC_FAILED_NAMES}${1}"$'\n'
}

# sync_failed_names_summary - up to three remembered failure names, joined
# with commas (for the notification body).
sync_failed_names_summary() {
  local name="" list="" count=0
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    [[ "$count" -lt 3 ]] || break
    list="${list:+${list}, }${name}"
    count=$((count + 1))
  done <<<"$SYNC_FAILED_NAMES"
  printf '%s' "$list"
}

# sync_notify - send one macOS notification for an apply run: failures win
# over conflicts, conflicts over NOTIFY_SUCCESS. A failure body also names
# any conflict copies the run created, because conflicts need attention even
# when only failure notifications are enabled. Dry runs and empty runs stay
# silent; never fails the run.
sync_notify() {
  local names="" body=""
  [[ "$SYNC_APPLY" == true && "$SYNC_TOTAL" -gt 0 ]] || return 0
  notify_enabled || return 0
  if [[ "$SYNC_FAILED" -gt 0 ]]; then
    names=${ sync_failed_names_summary;}
    body="${SYNC_FAILED} of ${SYNC_TOTAL} source(s) failed: ${names}"
    [[ "$SYNC_CONFLICTS" -eq 0 ]] || body="${body}, ${SYNC_CONFLICTS} conflict copy(ies)"
    notify_send "sciebo sync failed" "$body"
  elif [[ "$SYNC_CONFLICTS" -gt 0 ]]; then
    notify_send "sciebo conflicts" "${SYNC_CONFLICTS} conflict copy(ies) created; run 'sciebo status'"
  elif [[ "${NOTIFY_SUCCESS:-0}" == "1" ]]; then
    notify_send "sciebo sync finished" "${SYNC_OK} source(s) ok"
  fi
  return 0
}

# sync_check_rclone_version - refuse to run when rclone is older than
# RCLONE_MIN_VERSION. The setting is MAJOR.MINOR[.PATCH]; a missing minor
# counts as 0. Runs after load_settings, so RCLONE_BIN is known.
sync_check_rclone_version() {
  local required="$RCLONE_MIN_VERSION" required_major="" required_minor="" version=""
  case "$required" in
    *.*)
      required_major="${required%%.*}"
      required_minor="${required#*.}"
      required_minor="${required_minor%%.*}"
      ;;
    *)
      required_major="$required"
      required_minor=0
      ;;
  esac
  version=${ rclone_version;}
  if [[ -z "$version" ]]; then
    die "cannot determine the rclone version (need >= ${RCLONE_MIN_VERSION}); run 'sciebo doctor'"
  fi
  rclone_version_at_least "$required_major" "$required_minor" ||
    die "rclone ${version} is too old; need >= ${RCLONE_MIN_VERSION} (run 'sciebo doctor' for details)"
}

# sync_resolve_chunk_size - resolve SYNC_CHUNK_SIZE once per run: the
# capabilities helper (CHUNK_SIZE, a run-level duration/throughput
# derivation, or the server maximum), then clamped by MIN_CHUNK_SIZE/
# MAX_CHUNK_SIZE. A changed value is warned about once, naming the original.
sync_resolve_chunk_size() {
  local raw=""
  SYNC_CHUNK_SIZE=${ capabilities_sync_chunk_size;} || SYNC_CHUNK_SIZE=""
  raw="$SYNC_CHUNK_SIZE"
  SYNC_CHUNK_SIZE="$(policy_chunk_size "$raw")"
  if [[ -n "$raw" && "$SYNC_CHUNK_SIZE" != "$raw" ]]; then
    warn "chunk size ${raw} clamped to ${SYNC_CHUNK_SIZE} (MIN_CHUNK_SIZE/MAX_CHUNK_SIZE)"
  fi
}

# sync_state_init - reset the per-run bookkeeping before the manifest walk.
# The option-derived flags (SYNC_APPLY, SYNC_QUIET, SYNC_RESYNC, ...) are set
# by cmd_sync itself; this covers only state the run starts from zero.
sync_state_init() {
  SYNC_TOTAL=0
  SYNC_OK=0
  SYNC_FAILED=0
  SYNC_SKIPPED=0
  SYNC_CONFLICTS=0
  SYNC_FAILED_NAMES=""
  SYNC_POLICY_EXCLUDES=()
  # shellcheck disable=SC2034  # lib/sync/quota.sh state, reset for this run
  REMOTE_SIZE_CACHE=()
  # shellcheck disable=SC2034  # lib/sync/quota.sh state, reset for this run
  QUOTA_STATUS=""
  # shellcheck disable=SC2034  # lib/sync/quota.sh state, reset for this run
  QUOTA_TOTAL=""
  # shellcheck disable=SC2034  # lib/sync/quota.sh state, reset for this run
  QUOTA_USED=""
}

# sync_kill_child PID - TERM PID and its direct children. rclone_cmd is a
# shell function, so the pid recorded around the backgrounded call is the
# wrapper subshell; rclone itself is that subshell's child.
sync_kill_child() {
  local pid="${1:-}" child=""
  [[ -n "$pid" ]] || return 0
  while IFS= read -r child; do
    [[ -n "$child" ]] || continue
    kill -TERM "$child" 2>/dev/null || true
  done < <(ps -ww -o pid=,ppid= -ax 2>/dev/null | awk -v parent="$pid" '$2 == parent { print $1 }')
  kill -TERM "$pid" 2>/dev/null || true
  return 0
}

# sync_on_signal SIGNAL - INT/TERM handler for a sync run: TERM the active
# rclone child (serial path) and every live parallel worker, then exit with
# 128+SIGNAL (130 for INT, 143 for TERM). Workers install the same handler,
# so a TERM to a worker also reaches its own child. The EXIT trap in
# bin/sciebo releases the run lock.
sync_on_signal() {
  local status=130 pid="" i=0
  [[ "$1" != "TERM" ]] || status=143
  if [[ -n "${SYNC_CHILD_PID:-}" ]]; then
    sync_kill_child "$SYNC_CHILD_PID"
  fi
  i=0
  while [[ "$i" -lt "${#SYNC_WORKER_PIDS[@]}" ]]; do
    pid="${SYNC_WORKER_PIDS[$i]:-}"
    if [[ -n "$pid" ]]; then
      kill -TERM "$pid" 2>/dev/null || true
    fi
    i=$((i + 1))
  done
  i=0
  while [[ "$i" -lt "${#SYNC_WORKER_OUTS[@]}" ]]; do
    if [[ -n "${SYNC_WORKER_OUTS[$i]:-}" ]]; then
      rm -f "${SYNC_WORKER_OUTS[$i]}" "${SYNC_WORKER_OUTS[$i]}.result" 2>/dev/null || true
    fi
    i=$((i + 1))
  done
  exit "$status"
}

# sync_parallel_limit - effective MAX_PARALLEL_SOURCES. validate_settings
# already rejects non-numeric values; 0 falls back to the serial path.
sync_parallel_limit() {
  local limit="${MAX_PARALLEL_SOURCES:-1}"
  case "$limit" in
    '' | *[!0-9]*) limit=1 ;;
  esac
  limit=$((10#$limit))
  [[ "$limit" -ge 1 ]] || limit=1
  printf '%s' "$limit"
}

# sync_each_entry - warn once per duplicated non-bisync name. Uses the
# caller's `only`.
sync_each_entry() {
  [[ -z "$only" || "$ENTRY_NAME" == "$only" ]] || return 0
  [[ "$ENTRY_MODE" != "bisync" ]] || return 0
  if manifest_has_duplicate_name "$ENTRY_NAME"; then
    sync_warn_duplicate "$ENTRY_NAME" "$ENTRY_MODE"
  fi
  return 0
}

# sync_prewarn_duplicates ONLY - parallel path only: warn once per
# duplicated non-bisync name before any worker starts and record it in
# SYNC_DUP_WARNED, which the workers inherit, so they cannot warn
# concurrently. Bisync duplicates keep failing their own entry.
sync_prewarn_duplicates() {
  local only="$1"
  manifest_each sync_each_entry
  return 0
}

# sync_parallel_collect OUTFILE RESULTFILE - fold one worker's counters into
# the run totals, print its captured output whole, and remove both files.
# RESULTFILE is "total<TAB>ok<TAB>failed<TAB>skipped<TAB>conflicts<TAB>name".
sync_parallel_collect() {
  local out="$1" result="$2" name="${3:-}"
  local d_total=0 d_ok=0 d_failed=0 d_skipped=0 d_conflicts=0 d_name=""
  local result_line=""
  if [[ -f "$result" ]]; then
    IFS= read -r result_line <"$result" || true
    record_split "$result_line" d_total d_ok d_failed d_skipped d_conflicts d_name
  else
    # A worker that was killed (or crashed) before writing its result would
    # otherwise vanish from the totals. Count it as one failed entry so the
    # run summary and notification stay honest.
    warn "parallel worker for '${name:-?}' exited before reporting; counting it as failed"
    d_total=1
    d_failed=1
    d_name="$name"
  fi
  is_uint "$d_total" || d_total=0
  is_uint "$d_ok" || d_ok=0
  is_uint "$d_failed" || d_failed=0
  is_uint "$d_skipped" || d_skipped=0
  is_uint "$d_conflicts" || d_conflicts=0
  SYNC_TOTAL=$((SYNC_TOTAL + d_total))
  SYNC_OK=$((SYNC_OK + d_ok))
  SYNC_FAILED=$((SYNC_FAILED + d_failed))
  SYNC_SKIPPED=$((SYNC_SKIPPED + d_skipped))
  SYNC_CONFLICTS=$((SYNC_CONFLICTS + d_conflicts))
  [[ -z "$d_name" ]] || sync_note_failure "$d_name"
  if [[ -f "$out" ]]; then
    cat "$out"
  fi
  rm -f "$out" "$result" 2>/dev/null || true
  return 0
}

# sync_parallel_reap INDEX - wait for one worker, fold in its result, print
# its output, and drop it from the worker tables.
sync_parallel_reap() {
  local index="$1" pid="${SYNC_WORKER_PIDS[$1]:-}" out="${SYNC_WORKER_OUTS[$1]:-}" name="${SYNC_WORKER_NAMES[$1]:-}"
  [[ -n "$pid" ]] || return 0
  wait "$pid" 2>/dev/null || true
  sync_parallel_collect "$out" "${out}.result" "$name"
  unset "SYNC_WORKER_PIDS[$index]" "SYNC_WORKER_OUTS[$index]" "SYNC_WORKER_NAMES[$index]" 2>/dev/null || true
  if [[ "${#SYNC_WORKER_PIDS[@]}" -gt 0 ]]; then
    SYNC_WORKER_PIDS=("${SYNC_WORKER_PIDS[@]}")
    SYNC_WORKER_OUTS=("${SYNC_WORKER_OUTS[@]}")
    SYNC_WORKER_NAMES=("${SYNC_WORKER_NAMES[@]}")
  fi
  return 0
}

# sync_parallel_reap_finished - reap the first finished worker in table
# order, folding in its result and printing its output. Returns 0 when a
# worker was reaped, 1 when all live workers are still running. Reaping
# compacts the tables, so the caller restarts the scan.
sync_parallel_reap_finished() {
  local i=0 count="${#SYNC_WORKER_PIDS[@]}" pid=""
  while [[ "$i" -lt "$count" ]]; do
    pid="${SYNC_WORKER_PIDS[$i]:-}"
    if [[ -n "$pid" ]] && ! pid_alive "$pid"; then
      sync_parallel_reap "$i"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

# sync_parallel_wait_slot LIMIT - block until fewer than LIMIT workers are
# alive. Finished workers are reaped first (lowest launch index first, so the
# output order matches the serial path); once the table is full the loop
# blocks in `wait -n` for the next worker to finish instead of polling.
sync_parallel_wait_slot() {
  local limit="$1"
  while :; do
    while sync_parallel_reap_finished; do :; done
    [[ "${#SYNC_WORKER_PIDS[@]}" -lt "$limit" ]] && return 0
    wait -n 2>/dev/null || true
  done
}

# sync_parallel_drain_one - block on one live worker and reap it; rc 1 when
# no worker is left.
sync_parallel_drain_one() {
  local i=0 pid="" count="${#SYNC_WORKER_PIDS[@]}"
  while [[ "$i" -lt "$count" ]]; do
    pid="${SYNC_WORKER_PIDS[$i]:-}"
    if [[ -n "$pid" ]]; then
      sync_parallel_reap "$i"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

# sync_parallel_worker LINE ONLY OUTFILE - one parallel entry: run the
# shared per-entry function with its stdout/stderr captured in OUTFILE and
# write the counter deltas plus any failed name to OUTFILE.result.
sync_parallel_worker() {
  local line="$1" only="$2" out="$3"
  local total0="$SYNC_TOTAL" ok0="$SYNC_OK" failed0="$SYNC_FAILED" skipped0="$SYNC_SKIPPED"
  local conflicts0="$SYNC_CONFLICTS" names0="$SYNC_FAILED_NAMES"
  trap 'sync_on_signal INT' INT
  trap 'sync_on_signal TERM' TERM
  sync_run_one_line "$line" "$only" >"$out" 2>&1 || true
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$((SYNC_TOTAL - total0))" "$((SYNC_OK - ok0))" \
    "$((SYNC_FAILED - failed0))" "$((SYNC_SKIPPED - skipped0))" \
    "$((SYNC_CONFLICTS - conflicts0))" "${SYNC_FAILED_NAMES#"$names0"}" >"${out}.result"
  return 0
}

# sync_run_parallel ONLY LIMIT - bounded-parallel dispatch for
# MAX_PARALLEL_SOURCES > 1. Each entry runs in a background subshell with
# its output captured in a per-entry file, which is printed whole when the
# entry is reaped; the parent folds the worker's counters in, so summary,
# conflicts, notifications, blacklist, and runstate match the serial path.
sync_run_parallel() {
  local only="$1" limit="$2" line="" out="" wname=""
  SYNC_WORKER_PIDS=()
  SYNC_WORKER_OUTS=()
  SYNC_WORKER_NAMES=()
  # Allocate the policy case-scan cache in the parent before the first fork:
  # policy.sh now creates it lazily on first read/write, and workers do not
  # inherit the EXIT trap, so a directory first allocated inside a worker
  # would never be cleaned up. Already allocated runs hit the keep-existing
  # path and pay nothing but a revalidation stat.
  _policy_case_cache_new_dir || true
  sync_prewarn_duplicates "$only"
  while IFS= read -r line; do
    sync_parallel_wait_slot "$limit"
    wname=""
    manifest_parse_line "$line" && wname="$ENTRY_NAME"
    # temp_mktemp_into uses a random, O_EXCL-created name so a planted symlink
    # in a shared STATE_DIR cannot redirect the truncation, and registers it
    # for EXIT cleanup alongside the signal handler.
    temp_mktemp_into out "${STATE_DIR}/.sync-parallel.XXXXXX" || out=""
    if [[ -z "$out" ]]; then
      warn "cannot create a parallel worker output file in ${STATE_DIR}; running the entry serially"
      sync_run_one_line "$line" "$only"
      continue
    fi
    sync_parallel_worker "$line" "$only" "$out" &
    SYNC_WORKER_PIDS[${#SYNC_WORKER_PIDS[@]}]="$!"
    SYNC_WORKER_OUTS[${#SYNC_WORKER_OUTS[@]}]="$out"
    SYNC_WORKER_NAMES[${#SYNC_WORKER_NAMES[@]}]="$wname"
  done < <(manifest_lines)
  while sync_parallel_drain_one; do :; done
  SYNC_WORKER_PIDS=()
  SYNC_WORKER_OUTS=()
  SYNC_WORKER_NAMES=()
  return 0
}

# sync_pause_guard FORCE - when --force was not given and a pause is active,
# log the paused notice and return 0 so the caller stops; return 1 to
# continue.
sync_pause_guard() {
  local force="$1" pause_desc=""
  [[ "$force" == false ]] || return 1
  pause_active || return 1
  pause_desc="$(pause_describe)" || pause_desc="paused"
  [[ -n "$pause_desc" ]] || pause_desc="paused"
  log "sync is paused (${pause_desc}); run 'sciebo resume' or use 'sciebo sync --force'"
  return 0
}

# sync_parse_options "$@" - step 1 of cmd_sync: parse the run's options
# and map them into state. opt_begin resets and fills the OPT_* globals
# (its help guard exits 0 for -h/--help right there), opt_guard rejects
# unexpected positionals through usage_error (exit 2), so neither --help
# nor a bad option ever reaches the requires in sync_bootstrap. The
# mapping sets SYNC_APPLY/SYNC_QUIET/SYNC_RESYNC/SYNC_FORCE/
# SYNC_ASSUME_YES, exports SCIEBO_METERED_OK for --metered-ok, resets
# SYNC_DUP_WARNED, and fills this command's flow locals - only, list,
# resync, no_lock, force - which cmd_sync declares and sync_bootstrap
# reads through bash dynamic scope (the way sync_each_entry reads its
# caller's `only`); assume_yes/metered_ok are locals of this function.
# Returns 0; --help and unknown options exit before that.
sync_parse_options() {
  local assume_yes=false metered_ok=false
  opt_begin "apply:b dry-run:b only:s list:b resync:b quiet:b no-lock:b force:b yes:b metered-ok:b" sync "" "$@"
  opt_guard sync
  only="${OPT_only:-}"
  opt_into list list
  opt_into resync resync
  opt_into no_lock no_lock
  opt_into force force
  opt_into assume_yes yes
  opt_into metered_ok metered_ok
  SYNC_APPLY=true
  SYNC_FORCE="$force"
  SYNC_ASSUME_YES="$assume_yes"
  if [[ "$metered_ok" == true ]]; then
    export SCIEBO_METERED_OK=1
  fi
  if [[ "$SYNC_FORCE_DRY" == true || -n "${OPT_dry_run:-}" ]]; then
    SYNC_APPLY=false
  fi
  SYNC_QUIET=false
  opt_into SYNC_QUIET quiet
  SYNC_RESYNC="$resync"
  SYNC_DUP_WARNED=$'\n'
  return 0
}

# sync_bootstrap - step 2 of cmd_sync: everything between option parsing
# and the entry walk, in the run's original order: `--list` renders the
# same rows as `sciebo list` (lib/config/manifest.sh's manifest_list_render;
# sync --list has no --json option, so it always renders the text table),
# then settings, the rclone version gate, the pause gate, the chunk size,
# the run counters, the state directories, the remote check, the run lock
# (acquired before the banner and released by bin/sciebo's EXIT trap), the
# timestamp, the --resync warning, the banner, the quota warning, the
# manifest index and the --only name check, and finally the INT/TERM traps
# (installed after the lock, so a signal can arrive only once the handler
# exists and the lock is held).
# Reads cmd_sync's flow locals (list/resync/no_lock/force/only) through
# dynamic scope. Returns 0; the two normal stops - `--list` rendered,
# and an active pause - set cmd_sync's `stopped` local to true instead,
# because both end the run successfully. Failures never return: they die
# or usage_error, exactly like the old inline body did under errexit.
sync_bootstrap() {
  if [[ "$list" == true ]]; then
    load_settings --no-rclone
    manifest_list_render 0
    stopped=true
    return 0
  fi
  load_settings
  sync_check_rclone_version
  if sync_pause_guard "$force"; then
    stopped=true
    return 0
  fi
  sync_resolve_chunk_size
  sync_state_init
  ensure_state_dirs
  require_remote
  if [[ "$no_lock" == false ]]; then acquire_lock; fi
  printf -v SYNC_TIMESTAMP '%(%Y%m%d-%H%M%S)T' -1
  if [[ "$resync" == true ]]; then warn "--resync: bisync can copy or delete files in BOTH directions"; fi
  if [[ "$SYNC_QUIET" == false ]]; then
    if [[ "$SYNC_APPLY" == true ]]; then
      log "Applying changes to ${REMOTE_PREFIX} (${RCLONE_CONFIG})"
    else
      log "DRY RUN: no changes will be made (use 'sciebo sync' to transfer)"
    fi
  fi
  sync_quota_warn
  manifest_index_load
  if [[ -n "$only" ]]; then
    manifest_require_name "$only"
  fi
  trap 'sync_on_signal INT' INT
  trap 'sync_on_signal TERM' TERM
  return 0
}

# sync_dispatch_entries ONLY - step 3 of cmd_sync: walk the manifest and
# run every entry through sync_run_one_line - serially when
# sync_parallel_limit is <= 1, with sync_run_parallel above that. ONLY
# restricts the run to the entry with that sanitized name (an empty ONLY
# runs everything; an invalid line or a duplicate name is judged per
# entry inside sync_run_one_line). Returns 0: failed entries are counted
# for sync_print_summary, never returned from here.
sync_dispatch_entries() {
  local only="$1" line="" parallel=""
  parallel=${ sync_parallel_limit;}
  if [[ "$parallel" -le 1 ]]; then
    while IFS= read -r line; do
      sync_run_one_line "$line" "$only"
    done < <(manifest_lines)
  else
    sync_run_parallel "$only" "$parallel"
  fi
  return 0
}

# sync_print_summary - step 4 of cmd_sync: print the run's summary line
# (with the conflict and dry-run suffixes), send the completion
# notification, and return the run status: 0 when no entry failed, 1
# otherwise (cmd_sync's - and therefore the process's - final status).
sync_print_summary() {
  local summary=""
  summary="Summary: ${SYNC_TOTAL} sources (${SYNC_OK} ok, ${SYNC_FAILED} failed, ${SYNC_SKIPPED} skipped)"
  [[ "$SYNC_CONFLICTS" -eq 0 ]] || summary="${summary}, ${SYNC_CONFLICTS} conflict(s)"
  [[ "$SYNC_APPLY" == true ]] || summary="${summary} - dry run, no changes made"
  printf '%s\n' "$summary"
  sync_notify
  [[ "$SYNC_FAILED" -eq 0 ]]
}

# cmd_sync - the `sync` run (and `check`, which routes here with
# SYNC_FORCE_DRY=true), as four ordered steps:
#   1. sync_parse_options "$@" - option parsing and flag mapping; --help
#      and unknown options exit here, before any run dependency loads.
#   2. sync_bootstrap - dependencies, the `--list` dispatch, settings,
#      gates, state, lock, banner, traps; it stops the run for `--list`
#      and for an active pause by setting `stopped` (both end rc 0).
#   3. sync_dispatch_entries ONLY - the serial or parallel entry walk.
#   4. sync_print_summary - summary line, notification, final status.
# Returns 0 when nothing failed (or the run stopped early), 1 when an
# entry failed; only die/usage_error exit.
cmd_sync() {
  local only="" list=false resync=false no_lock=false force=false stopped=false
  sync_parse_options "$@"
  sync_bootstrap
  if [[ "$stopped" == true ]]; then return 0; fi
  sync_dispatch_entries "$only"
  sync_print_summary
}

# cmd_check - `sciebo check`, the same run as sync with --dry-run forced.
# It only flips the flag and routes through cmd_sync.
cmd_check() {
  SYNC_FORCE_DRY=true
  cmd_sync "$@"
}
