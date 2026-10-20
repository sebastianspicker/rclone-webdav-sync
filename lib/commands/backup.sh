#!/bin/bash
# backup.sh command module - restic backups of local folders into a
# repository on the remote (`sciebo backup init|run|list|add|remove|
# snapshots|ls|restore|forget|check|unlock|info|key`).
#
# restic talks to the server through `rclone serve restic --stdio`, wired up
# by lib/adapters/restic.sh (restic_cmd); this module owns the subcommand
# parsers, the per-source run loop with its signal trap and run records
# (runstate namespace `backup`), and the forget/check maintenance a run
# performs when it is due (lib/state/backupstate.sh markers). Sources live in
# backups.conf (lib/config/backupset.sh); filters are translated by
# lib/sync/backup_filters.sh, retention, overlap, quota, and restore-target
# rules come from lib/sync/backup_policy.sh. The repository password never
# reaches argv or a log: restic gets it in its environment only.

# Per-run bookkeeping for `backup run` (reset by _backup_run_state_init).
_backup_child_pid=""
_backup_timestamp=""
_backup_host=""
_backup_json=0
_backup_quiet=0
_backup_dry_run=0
_backup_extra_tags=""
_backup_total=0
_backup_ok=0
_backup_warn=0
_backup_failed=0
_backup_skipped=0
_backup_reached_restic=0
_backup_failed_names=""
_backup_maint_forget="not run"
_backup_maint_check="not run"
_backup_maint_log=""
declare -ga _backup_res_name=()
declare -ga _backup_res_status=()
declare -ga _backup_res_rc=()
declare -ga _backup_res_snapshot=()
declare -ga _backup_res_detail=()
declare -ga _backup_res_log=()
# Rendering state for `backup list --show-filters`.
_backup_list_rc=0
_backup_list_json=0

usage_backup() {
  usage_emit <<'EOF'
Usage: sciebo backup <subcommand> [options]

Encrypted, deduplicated backups of local folders with restic. The
repository lives on the remote at <RCLONE_REMOTE>:<BACKUP_REMOTE_PATH>,
outside the sync tree REMOTE_BASE; restic reaches it through
`rclone serve restic`, so every rclone setting of this tool applies. Sources
are listed in backups.conf (name|local[|filter]); the BACKUP_* settings in
settings.env control the run flags, retention, and maintenance cadence.

Subcommands:
  init                    create the repository and store its password
  run                     back up every source (or one), then run due
                          forget/check maintenance
  list                    show the configured backup sources
  add LOCAL               add a backup source to backups.conf
  remove NAME             remove a backup source (its snapshots are kept)
  snapshots               list the snapshots in the repository
  ls SNAPSHOT [PATH]      list the files in a snapshot
  restore SNAPSHOT        restore a snapshot into an empty directory
  forget                  show the retention plan (or apply it)
  check                   verify the repository
  unlock                  remove stale repository locks after a crash
  info                    repository, versions, last run/forget/check, cache
  key show                print the repository password (recovery)

Options for init:
  --existing              connect to a repository created elsewhere
                          (verified with `restic cat config`)
  --password-stdin        read the repository password from one line of
                          stdin instead of generating one

Options for run:
  --only NAME             back up only this source
  --dry-run               let restic report what it would store
  --tag TAG               add a restic tag to the snapshots (repeatable)
  --no-maintenance        skip the due forget/check maintenance
  --quiet                 only print failures, warnings, and the summary
  --json                  print one JSON document with the per-source results

Options for list:
  --show-filters          print each source's translated exclude patterns
  --json                  print the sources as JSON

Options for add:
  --name NAME             source name (default: the folder's name)
  --filter FILE           filter file in the filters directory (exclude
                          rules only)

Options for snapshots:
  --only NAME             only snapshots of this source from this host
  --json                  print restic's JSON array

Options for restore:
  --target DIR            directory to restore into (required; must be
                          empty or new and not a sync pair's local folder)
  --include PATH          restore only this path (repeatable)
  --dry-run               report what would be restored
  --force                 restore into a non-empty directory or a sync
                          pair's local folder

Options for forget:
  --apply                 remove the snapshots the policy drops (default is
                          a dry run)
  --prune                 also prune unreferenced data (default with
                          --apply when BACKUP_PRUNE=1)

Options for check:
  --read-data-subset SPEC read this part of the data: N%, N/M, or a size
                          like 2G (default BACKUP_CHECK_READ_DATA_SUBSET)

Options for info:
  --offline               do not contact the repository
  --json                  print the report as JSON

The password printed by `init` is the only way to read the backups: store
it outside this machine. Exit status: 0 ok, 1 failure, 2 usage error (or,
for run, skipped by BACKUP_QUOTA_POLICY=skip).
EOF
}

# ---------------------------------------------------------------------------
# Shared helpers

# backup_preamble - settings, remote, restic version gate, and state dirs for
# every subcommand that runs restic.
backup_preamble() {
  load_settings
  require_remote
  restic_require
  ensure_state_dirs
}

# backup_require_password - die unless a repository password is stored. The
# secret stays in a local and is never printed.
backup_require_password() {
  local pw=""
  pw=${ restic_password;} || pw=""
  [[ -n "$pw" ]] || die "no repository password stored; run 'sciebo backup init'"
}

# backup_overlap_guard - die when a sync pair's remote folder overlaps the
# repository path (re-checked on every run: the manifest can be hand-edited
# and BACKUP_REMOTE_PATH changed after the pairs were added).
backup_overlap_guard() {
  local overlaps=""
  if overlaps=${ backup_repo_overlaps_manifest;}; then
    overlaps="${overlaps//$'\n'/, }"
    die "BACKUP_REMOTE_PATH '${BACKUP_REMOTE_PATH}' overlaps the remote folder of sync pair(s): ${overlaps}; the repository must stay outside every pair"
  fi
  return 0
}

# backup_set_bwlimit - hand the effective bandwidth limit (sciebo limit,
# BW_SCHEDULE, BW_LIMIT_*) to the restic-spawned rclone.
backup_set_bwlimit() {
  # shellcheck disable=SC2034  # read by restic_env_into (lib/adapters/restic.sh)
  RESTIC_BWLIMIT=${ bw_effective_limit;}
}

# backup_capture_discard - drop restic_capture's temp files.
backup_capture_discard() {
  temp_discard "${RESTIC_CAPTURE_OUT:-}"
  temp_discard "${RESTIC_CAPTURE_ERR:-}"
  RESTIC_CAPTURE_OUT=""
  RESTIC_CAPTURE_ERR=""
}

# backup_failure_text RC TEXT - restic_rc_describe RC plus the stderr hint
# found in TEXT (quota exhausted, HTTP 423), one line.
backup_failure_text() {
  local hint=""
  hint=${ restic_stderr_hint "${2:-}";}
  printf '%s%s' "${ restic_rc_describe "$1";}" "${hint:+"; ${hint}"}"
}

# backup_passthrough ARGS... - run restic_cmd ARGS with stdout untouched and
# stderr through sanitize_stream; returns restic's status.
backup_passthrough() {
  local rc=0
  { restic_cmd "$@" 2>&1 1>&3 3>&- | sanitize_stream >&2; } 3>&1 || rc=$?
  return "$rc"
}

# backup_host - the host name restic records: BACKUP_HOST when set, else the
# short hostname (then the full one).
backup_host() {
  local host=""
  if [[ -n "${BACKUP_HOST:-}" ]]; then
    printf '%s' "$BACKUP_HOST"
    return 0
  fi
  host="$(hostname -s 2>/dev/null)" || host=""
  [[ -n "$host" ]] || host="$(hostname 2>/dev/null)" || host=""
  printf '%s' "$host"
}

# backup_abs_path_into VAR PATH - PATH with ~ expanded and made absolute
# against the working directory.
backup_abs_path_into() {
  local p="$2"
  case "$p" in
    \~ | \~/*) expand_local_path_into p "$p" ;;
    /*) ;;
    *) p="${PWD}/${p}" ;;
  esac
  printf -v "$1" '%s' "$p"
}

# backup_json_uint_into VAR LINE KEY - the unsigned number stored under KEY in
# the compact JSON LINE, or empty when absent.
backup_json_uint_into() {
  local re="\"${3}\":[[:space:]]*([0-9]+)"
  if [[ "$2" =~ $re ]]; then
    printf -v "$1" '%s' "${BASH_REMATCH[1]}"
  else
    printf -v "$1" '%s' ""
  fi
}

# backup_check_subset SPEC - true when SPEC is a restic --read-data-subset
# value: N%, N/M, or a size such as 500M or 2G.
backup_check_subset() {
  [[ "$1" =~ ^[0-9]+(\.[0-9]+)?%$ || "$1" =~ ^[1-9][0-9]*/[1-9][0-9]*$ || "$1" =~ ^[0-9]+[KMGTkmgt]?$ ]]
}

# ---------------------------------------------------------------------------
# run: child process, signals, per-source loop, maintenance

# backup_kill_child PID - TERM PID and its direct children. restic_cmd is a
# shell function, so the backgrounded pid is the wrapper subshell and restic
# is its child; restic removes its own repository lock on TERM.
backup_kill_child() {
  local pid="${1:-}" child=""
  [[ -n "$pid" ]] || return 0
  while IFS= read -r child; do
    [[ -n "$child" ]] || continue
    kill -TERM "$child" 2>/dev/null || true
  done < <(ps -ww -o pid=,ppid= -ax 2>/dev/null | awk -v parent="$pid" '$2 == parent { print $1 }')
  kill -TERM "$pid" 2>/dev/null || true
  return 0
}

# backup_on_signal SIGNAL - INT/TERM handler for `backup run`: TERM the
# running restic child and exit 128+SIGNAL. The EXIT trap in lib/cli/main.sh
# releases the backup lock and removes registered temp files.
backup_on_signal() {
  local status=130
  [[ "$1" != "TERM" ]] || status=143
  backup_kill_child "${_backup_child_pid:-}"
  exit "$status"
}

# backup_child LOGFILE ARGS... - run restic_cmd ARGS in the background with
# stdout and stderr appended to LOGFILE, recording the pid so the signal
# trap can stop it, and wait (an interruptible wait, unlike a foreground
# child). Returns restic's status.
backup_child() {
  local logfile="$1" rc=0
  shift
  _backup_child_pid=""
  restic_cmd "$@" </dev/null >>"$logfile" 2>&1 &
  _backup_child_pid=$!
  wait "$_backup_child_pid" || rc=$?
  _backup_child_pid=""
  return "$rc"
}

# backup_say MESSAGE - a progress line for `backup run`: stderr in JSON mode
# (stdout carries only the document), nothing with --quiet, else log.
backup_say() {
  if [[ "$_backup_json" -eq 1 ]]; then
    printf '%s\n' "$*" >&2
  elif [[ "$_backup_quiet" -eq 0 ]]; then
    log "$*"
  fi
}

# _backup_run_state_init - reset the per-run counters and result arrays.
_backup_run_state_init() {
  _backup_total=0
  _backup_ok=0
  _backup_warn=0
  _backup_failed=0
  _backup_skipped=0
  _backup_reached_restic=0
  _backup_failed_names=""
  _backup_maint_forget="not run"
  _backup_maint_check="not run"
  _backup_maint_log=""
  _backup_res_name=()
  _backup_res_status=()
  _backup_res_rc=()
  _backup_res_snapshot=()
  _backup_res_detail=()
  _backup_res_log=()
}

# backup_entry_result NAME LOCAL STATUS RC SNAPSHOT DETAIL LOG [EXTRA] -
# count, record (runstate namespace backup), and print one source's outcome.
# EXTRA holds additional indented lines (filter errors) for text mode.
backup_entry_result() {
  local name="$1" local_path="$2" status="$3" rc="$4" snapshot="$5" detail="$6" logfile="$7" extra="${8:-}"
  local label="OK" line=""
  _backup_total=$((_backup_total + 1))
  case "$status" in
    ok) _backup_ok=$((_backup_ok + 1)) ;;
    warn)
      _backup_warn=$((_backup_warn + 1))
      label="WARN"
      ;;
    *)
      _backup_failed=$((_backup_failed + 1))
      _backup_failed_names+="${name}"$'\n'
      label="FAIL"
      ;;
  esac
  _backup_res_name+=("$name")
  _backup_res_status+=("$status")
  _backup_res_rc+=("$rc")
  _backup_res_snapshot+=("$snapshot")
  _backup_res_detail+=("$detail")
  _backup_res_log+=("$logfile")
  runstate_write_ns backup "$name" backup "$status" "$rc" "$logfile" 0 "$detail"
  [[ "$_backup_json" -eq 0 ]] || return 0
  [[ "$label" != "OK" || "$_backup_quiet" -eq 0 ]] || return 0
  printf '%-4s %-6s %-28s %s\n' "$label" backup "$name" "${ printable "$local_path";}"
  if [[ -n "$detail" ]]; then
    if [[ "$label" == "OK" ]]; then
      printf '     %s\n' "${ printable "$detail";}"
    else
      printf '     reason: %s\n' "${ printable "$detail";}"
    fi
  fi
  while IFS= read -r line; do
    [[ -z "$line" ]] || printf '     %s\n' "${ printable "$line";}"
  done <<<"$extra"
  [[ "$label" == "OK" || -z "$logfile" ]] || printf '     log: %s\n' "$logfile"
  return 0
}

# backup_summary_detail LOGFILE SNAP_VAR - parse the last restic summary line
# in LOGFILE into a one-line human detail (printed) and store the snapshot id
# in SNAP_VAR. Prints nothing when the log holds no summary.
backup_summary_detail() {
  local logfile="$1" line="" snap="" new="" changed="" added="" total="" size=""
  printf -v "$2" '%s' ""
  line=${ grep -F '"message_type":"summary"' "$logfile" 2>/dev/null | tail -n 1;} || line=""
  [[ -n "$line" ]] || return 0
  snap=${ json_string_field "$line" snapshot_id;} || snap=""
  backup_json_uint_into new "$line" files_new
  backup_json_uint_into changed "$line" files_changed
  backup_json_uint_into added "$line" data_added
  backup_json_uint_into total "$line" total_files_processed
  size=${ format_size_bytes "${added:-0}";}
  # A dry run reports a snapshot id that is never written; drop it.
  [[ "$_backup_dry_run" -eq 0 ]] || snap=""
  printf -v "$2" '%s' "$snap"
  if [[ "$_backup_dry_run" -eq 1 ]]; then
    printf 'dry run: %s new, %s changed, %s would be added' "${new:-0}" "${changed:-0}" "$size"
  elif [[ -n "$snap" ]]; then
    printf 'snapshot %s, %s new, %s changed, %s added' "${snap:0:8}" "${new:-0}" "${changed:-0}" "$size"
  else
    printf 'unchanged, no new snapshot (%s files checked)' "${total:-0}"
  fi
}

# backup_build_args_into ARRAY NAME LOCAL EXCLUDE_FILE - the restic backup argv
# for one source from the BACKUP_* settings and the run options.
backup_build_args_into() {
  local -n _bb_args="$1"
  local name="$2" local_path="$3" exclude_file="$4" tag="" raw=""
  local -a tags=()
  _bb_args=(backup --host "$_backup_host")
  IFS=, read -r -a tags <<<"${BACKUP_TAGS:-}"
  for raw in "${tags[@]}"; do
    trim_into tag "$raw"
    [[ -z "$tag" ]] || _bb_args+=(--tag "$tag")
  done
  _bb_args+=(--tag "source=${name}")
  while IFS= read -r tag; do
    [[ -z "$tag" ]] || _bb_args+=(--tag "$tag")
  done <<<"$_backup_extra_tags"
  [[ -z "$exclude_file" ]] || _bb_args+=(--exclude-file "$exclude_file")
  [[ -z "${BACKUP_EXCLUDE_IF_PRESENT:-}" ]] || _bb_args+=(--exclude-if-present "$BACKUP_EXCLUDE_IF_PRESENT")
  [[ "${BACKUP_EXCLUDE_CACHES:-0}" != "1" ]] || _bb_args+=(--exclude-caches)
  [[ "${BACKUP_ONE_FILE_SYSTEM:-0}" != "1" ]] || _bb_args+=(--one-file-system)
  [[ -z "${BACKUP_EXCLUDE_LARGER_THAN:-}" ]] || _bb_args+=(--exclude-larger-than "$BACKUP_EXCLUDE_LARGER_THAN")
  [[ "${BACKUP_SKIP_IF_UNCHANGED:-0}" != "1" ]] || _bb_args+=(--skip-if-unchanged)
  [[ "$_backup_dry_run" -eq 0 ]] || _bb_args+=(--dry-run)
  _bb_args+=(--json "$local_path")
}

# _backup_run_entry ONLY - backupset_each callback: back up the source parsed
# into BACKUP_ENTRY_* (unless ONLY names another one). Always returns 0;
# outcomes are counted by backup_entry_result.
_backup_run_entry() {
  local only="$1" name="$BACKUP_ENTRY_NAME" local_path="" filter_src="" exclude_file="" errors=""
  local logfile="" rc=0 status="" detail="" snapshot="" tail_text="" last=""
  local -a args=()
  [[ -z "$only" || "$name" == "$only" ]] || return 0
  local_path=${ backupset_resolve_local "$BACKUP_ENTRY_LOCAL";} || local_path=""
  if [[ -z "$local_path" || ! -d "$local_path" ]]; then
    backup_entry_result "$name" "${local_path:-$BACKUP_ENTRY_LOCAL}" failed 1 "" \
      "local directory does not exist: ${local_path:-$BACKUP_ENTRY_LOCAL}" ""
    return 0
  fi
  if [[ -n "$BACKUP_ENTRY_FILTER" ]]; then
    filter_src=${ backup_filter_resolve "$BACKUP_ENTRY_FILTER";} || filter_src=""
    if [[ -z "$filter_src" ]]; then
      backup_entry_result "$name" "$local_path" failed 1 "" \
        "filter file not found: ${FILTER_DIR}/${BACKUP_ENTRY_FILTER}" ""
      return 0
    fi
    temp_mktemp_into exclude_file "${TMPDIR:-/tmp}/sciebo-bexclude.XXXXXX" || die "cannot create temp file"
    if ! errors=${ backup_filter_translate "$filter_src" "$local_path" "$exclude_file" 2>&1;}; then
      temp_discard "$exclude_file"
      backup_entry_result "$name" "$local_path" failed 1 "" \
        "filter ${BACKUP_ENTRY_FILTER} has unsupported rules: ${errors%%$'\n'*}" "" "$errors"
      return 0
    fi
  fi
  backup_build_args_into args "$name" "$local_path" "$exclude_file"
  logfile="${LOG_DIR}/backup-${name}-${_backup_timestamp}.log"
  _backup_reached_restic=1
  backup_child "$logfile" "${args[@]}" || rc=$?
  [[ -z "$exclude_file" ]] || temp_discard "$exclude_file"
  status=${ restic_rc_status "$rc";}
  detail=${ backup_summary_detail "$logfile" snapshot;}
  # backup_summary_detail ran in a forkless substitution, so SNAP_VAR was set
  # in this shell already.
  case "$status" in
    ok) ;;
    warn) detail="${detail:+"${detail}; "}some files unreadable (see the log)" ;;
    *)
      tail_text=${ tail -n 20 "$logfile" 2>/dev/null;} || tail_text=""
      last=${ grep -v '^{' "$logfile" 2>/dev/null | tail -n 1;} || last=""
      detail=${ backup_failure_text "$rc" "$tail_text";}
      [[ -z "$last" ]] || detail="${detail}: ${last:0:200}"
      ;;
  esac
  backup_entry_result "$name" "$local_path" "$status" "$rc" "$snapshot" "$detail" "$logfile"
  return 0
}

# backup_maintenance - the due forget/prune and check passes after a run,
# logged to LOG_DIR/backup-maintenance-<timestamp>.log. Sets
# _backup_maint_forget/_backup_maint_check. Returns 1 when a pass failed.
backup_maintenance() {
  local rc=0 status=0
  local -a args=()
  _backup_maint_log="${LOG_DIR}/backup-maintenance-${_backup_timestamp}.log"
  _backup_maint_forget="not due"
  _backup_maint_check="not due"
  if backupstate_due forget "${BACKUP_FORGET_EVERY:-}"; then
    # Only this host's snapshots: in a repository shared by several machines
    # each one applies its own retention policy to its own groups.
    args=(forget --host "$_backup_host" --group-by "host,paths")
    if backup_keep_args_into args; then
      if [[ "${BACKUP_PRUNE:-0}" == "1" ]]; then
        args+=(--prune)
        backup_say "Maintenance: forget and prune"
      else
        backup_say "Maintenance: forget"
      fi
      rc=0
      backup_child "$_backup_maint_log" "${args[@]}" || rc=$?
      if [[ "$rc" -eq 0 ]]; then
        backupstate_mark forget || true
        _backup_maint_forget="ok"
      else
        _backup_maint_forget="failed: ${ restic_rc_describe "$rc";}"
        warn "maintenance: forget failed (${ restic_rc_describe "$rc";}); see ${_backup_maint_log}"
        status=1
      fi
    else
      _backup_maint_forget="skipped: empty retention policy"
    fi
  fi
  if backupstate_due check "${BACKUP_CHECK_EVERY:-}"; then
    backup_say "Maintenance: check --read-data-subset ${BACKUP_CHECK_READ_DATA_SUBSET}"
    rc=0
    backup_child "$_backup_maint_log" check --read-data-subset "$BACKUP_CHECK_READ_DATA_SUBSET" || rc=$?
    if [[ "$rc" -eq 0 ]]; then
      backupstate_mark check || true
      _backup_maint_check="ok"
    else
      _backup_maint_check="failed: ${ restic_rc_describe "$rc";}"
      warn "maintenance: check failed (${ restic_rc_describe "$rc";}); see ${_backup_maint_log}"
      status=1
    fi
  fi
  return "$status"
}

# backup_run_json - print the `backup run --json` document.
backup_run_json() {
  local i=0
  output_json_begin
  output_json_array_begin sources
  for ((i = 0; i < ${#_backup_res_name[@]}; i++)); do
    output_json_object_begin
    output_json_kv name "${_backup_res_name[i]}"
    output_json_kv status "${_backup_res_status[i]}"
    output_json_kv_raw rc "${_backup_res_rc[i]}"
    output_json_kv snapshot_id "${_backup_res_snapshot[i]}"
    output_json_kv detail "${_backup_res_detail[i]}"
    output_json_kv log "${_backup_res_log[i]}"
    output_json_object_end
  done
  output_json_array_end
  output_json_kv_raw ok "$_backup_ok"
  output_json_kv_raw warn "$_backup_warn"
  output_json_kv_raw failed "$_backup_failed"
  output_json_kv_raw skipped "$_backup_skipped"
  output_json_object_begin maintenance
  output_json_kv forget "$_backup_maint_forget"
  output_json_kv check "$_backup_maint_check"
  output_json_kv log "$_backup_maint_log"
  output_json_object_end
  output_json_end
}

# backup_run_notify - one desktop notification: failures always, success
# only with NOTIFY_SUCCESS=1; dry runs stay silent.
backup_run_notify() {
  local names=""
  [[ "$_backup_dry_run" -eq 0 && "$_backup_total" -gt 0 ]] || return 0
  if [[ "$_backup_failed" -gt 0 ]]; then
    names="${_backup_failed_names%$'\n'}"
    names="${names//$'\n'/, }"
    notify_send "sciebo backup failed" "${_backup_failed} of ${_backup_total} source(s) failed: ${names}"
  elif [[ "${NOTIFY_SUCCESS:-0}" == "1" ]]; then
    notify_send "sciebo backup finished" "$((_backup_ok + _backup_warn)) source(s) backed up"
  fi
  return 0
}

# backup_run - `backup run`: quota gate, one restic backup per source, due
# maintenance, summary. Returns 0 (all ok/warn), 1 (a source or maintenance
# failed), or 2 (skipped by the quota gate).
backup_run() {
  local only="" gate=0 status=0 count=0 suffix=""
  opt_begin "only:s dry-run:b tag:S no-maintenance:b quiet:b json:b" backup "run: " "$@"
  opt_guard backup "run: "
  _backup_json=0 _backup_quiet=0 _backup_dry_run=0
  opt_into _backup_json json 1
  opt_into _backup_quiet quiet 1
  opt_into _backup_dry_run dry_run 1
  _backup_extra_tags="${OPT_tag:-}"
  only="${OPT_only:-}"
  [[ "$_backup_json" -eq 0 ]] || output_mode_set true
  backup_preamble
  backup_require_password
  backup_overlap_guard
  if [[ -n "$only" ]] && ! backupset_has_name "$only"; then
    die "${ unknown_source_prefix "$only";} in ${BACKUPS_FILE} (see 'sciebo backup list')"
  fi
  acquire_lock backup
  _backup_run_state_init
  backup_set_bwlimit
  _backup_host=${ backup_host;}
  printf -v _backup_timestamp '%(%Y%m%d-%H%M%S)T' -1
  count=${ backupset_count;}
  backup_quota_gate || gate=$?
  if [[ "$gate" -eq 2 ]]; then
    backup_say "skipped: quota"
    _backup_skipped="$count"
    [[ -z "$only" ]] || _backup_skipped=1
    [[ "$_backup_json" -eq 0 ]] || backup_run_json
    return 2
  fi
  if [[ "$count" -eq 0 ]]; then
    backup_say "No backup sources configured (add one with 'sciebo backup add LOCAL')"
    [[ "$_backup_json" -eq 0 ]] || backup_run_json
    return 0
  fi
  if [[ "$_backup_dry_run" -eq 1 ]]; then
    backup_say "DRY RUN: restic reports what it would store; no snapshot is written"
  else
    backup_say "Backing up to ${ restic_repository;}"
  fi
  trap 'backup_on_signal INT' INT
  trap 'backup_on_signal TERM' TERM
  backupset_each _backup_run_entry "$only"
  if [[ "$_backup_reached_restic" -eq 1 && "$_backup_dry_run" -eq 0 ]]; then
    backupstate_mark run || true
  fi
  if [[ "${BACKUP_MAINTENANCE:-0}" != "1" ]]; then
    _backup_maint_forget="disabled" _backup_maint_check="disabled"
  elif [[ "$_backup_dry_run" -eq 1 || -n "${OPT_no_maintenance:-}" ]]; then
    _backup_maint_forget="skipped" _backup_maint_check="skipped"
  elif [[ "$_backup_failed" -gt 0 ]]; then
    _backup_maint_forget="skipped: a source failed" _backup_maint_check="skipped: a source failed"
    backup_say "Maintenance skipped: a source failed"
  else
    backup_maintenance || status=1
  fi
  trap - INT TERM
  [[ "$_backup_failed" -eq 0 ]] || status=1
  if [[ "$_backup_json" -eq 1 ]]; then
    backup_run_json
  else
    suffix=""
    [[ "$_backup_dry_run" -eq 0 ]] || suffix=" - dry run, no snapshot written"
    printf 'Summary: %s sources (%s ok, %s warn, %s failed, %s skipped)%s\n' \
      "$_backup_total" "$_backup_ok" "$_backup_warn" "$_backup_failed" "$_backup_skipped" "$suffix"
  fi
  backup_run_notify
  return "$status"
}

# ---------------------------------------------------------------------------
# init

# backup_password_restore PREVIOUS - undo a password store: put PREVIOUS back,
# or delete the stored password when there was none.
backup_password_restore() {
  if [[ -n "${1:-}" ]]; then
    restic_password_store "$1"
  else
    restic_password_delete || true
  fi
}

# backup_password_where - describe where the repository password is stored.
backup_password_where() {
  if keychain_enabled; then
    printf 'key storage %s, account %s' "${ platform_keychain_backend;}" "${ keychain_account_item restic;}"
  else
    printf 'file %s' "${BACKUP_PASSWORD_FILE:-}"
  fi
}

# backup_init - `backup init [--existing] [--password-stdin]`.
backup_init() {
  local existing=0 from_stdin=0 password="" previous="" generated=0 reuse_stored=0 overlaps="" rc=0 repo="" err_text=""
  opt_begin "existing:b password-stdin:b" backup "init: " "$@"
  opt_guard backup "init: "
  opt_into existing existing 1
  opt_into from_stdin password_stdin 1
  backup_preamble
  acquire_lock backup
  repo=${ restic_repository;}
  if overlaps=${ backup_repo_overlaps_manifest;}; then
    overlaps="${overlaps//$'\n'/, }"
    die "BACKUP_REMOTE_PATH '${BACKUP_REMOTE_PATH}' overlaps the remote folder of sync pair(s): ${overlaps}; the repository must stay outside every pair"
  fi
  previous=${ restic_password;} || previous=""
  if [[ -n "$previous" && ! ("$existing" -eq 1 && "$from_stdin" -eq 1) ]]; then
    rc=0
    restic_capture backup-probe cat config || rc=$?
    err_text=${ tail -n 20 "$RESTIC_CAPTURE_ERR" 2>/dev/null;} || err_text=""
    backup_capture_discard
    case "$rc" in
      0)
        if [[ "$existing" -eq 1 ]]; then
          printf 'Repository %s is reachable with the stored password.\n' "$repo"
          return 0
        fi
        die "repository ${repo} is already initialized and its password is stored; use 'sciebo backup init --existing' to verify it"
        ;;
      10)
        [[ "$existing" -eq 0 ]] || die "no repository at ${repo}: ${ restic_rc_describe "$rc";}"
        # No repository here, but a password is stored (BACKUP_REMOTE_PATH
        # changed, or a first init failed after storing): reuse it, so the
        # key that may still open another repository is never overwritten.
        reuse_stored=1
        ;;
      12)
        die "a repository exists at ${repo} but the stored password does not open it; use 'sciebo backup init --existing --password-stdin' with the right password"
        ;;
      *)
        die "cannot reach ${repo}: ${ backup_failure_text "$rc" "$err_text";}"
        ;;
    esac
  fi
  if [[ "$from_stdin" -eq 1 ]]; then
    IFS= read -r password || [[ -n "$password" ]] || password=""
    password="${password%$'\r'}"
    [[ -n "$password" ]] || die "no password on stdin (--password-stdin reads one line)"
  elif [[ "$existing" -eq 1 ]]; then
    die "--existing needs the repository password: pipe it in with --password-stdin"
  elif [[ "$reuse_stored" -eq 1 ]]; then
    password="$previous"
    printf 'Using the already stored repository password for the new repository.\n'
  else
    password=${ restic_password_generate;}
    generated=1
  fi
  [[ "$reuse_stored" -eq 1 ]] || restic_password_store "$password"
  if [[ "$existing" -eq 1 ]]; then
    rc=0
    restic_capture backup-verify cat config || rc=$?
    err_text=${ tail -n 20 "$RESTIC_CAPTURE_ERR" 2>/dev/null;} || err_text=""
    backup_capture_discard
    if [[ "$rc" -ne 0 ]]; then
      backup_password_restore "$previous"
      die "cannot open ${repo}: ${ backup_failure_text "$rc" "$err_text";}"
    fi
    printf 'Connected to the existing repository %s.\n' "$repo"
    printf 'Password stored in %s.\n' "${ backup_password_where;}"
    return 0
  fi
  rc=0
  restic_capture backup-init init || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    err_text=${ tail -n 20 "$RESTIC_CAPTURE_ERR" 2>/dev/null;} || err_text=""
    sanitize_stream <"$RESTIC_CAPTURE_ERR" | tail -n 5 >&2 || true
    backup_capture_discard
    backup_password_restore "$previous"
    die "restic init failed: ${ backup_failure_text "$rc" "$err_text";}"
  fi
  backup_capture_discard
  printf 'Initialized restic repository %s.\n' "$repo"
  printf 'Password stored in %s.\n' "${ backup_password_where;}"
  if [[ "$generated" -eq 1 ]]; then
    printf '\nRepository password (shown only this once):\n\n  %s\n\n' "$password"
    printf '%s\n' "WARNING: this password is the only way to read your backups. Store it" \
      "outside this machine (a password manager or on paper); if this machine is" \
      "lost without it, the backups are unrecoverable. Print it again later with" \
      "'sciebo backup key show'."
  fi
  return 0
}

# ---------------------------------------------------------------------------
# list / add / remove

# _backup_list_cb - backupset_each callback for `list --show-filters`: print
# the source row and its translated exclude patterns (or errors) beneath it.
_backup_list_cb() {
  local resolved="" src="" tmp="" errors="" line="" ok=1
  local -a patterns=()
  resolved=${ backupset_resolve_local "$BACKUP_ENTRY_LOCAL";} || resolved="$BACKUP_ENTRY_LOCAL"
  if [[ -n "$BACKUP_ENTRY_FILTER" ]]; then
    src=${ backup_filter_resolve "$BACKUP_ENTRY_FILTER";} || src=""
    if [[ -z "$src" ]]; then
      errors="filter file not found: ${FILTER_DIR}/${BACKUP_ENTRY_FILTER}"
      ok=0
    else
      temp_mktemp_into tmp "${TMPDIR:-/tmp}/sciebo-blist.XXXXXX" || die "cannot create temp file"
      errors=${ backup_filter_translate "$src" "$resolved" "$tmp" 2>&1;} || ok=0
      mapfile -t patterns <"$tmp"
      temp_discard "$tmp"
    fi
  fi
  [[ "$ok" -eq 1 ]] || _backup_list_rc=1
  if [[ "$_backup_list_json" -eq 1 ]]; then
    output_json_object_begin
    output_json_kv name "$BACKUP_ENTRY_NAME"
    output_json_kv local "$resolved"
    output_json_kv filter "$BACKUP_ENTRY_FILTER"
    output_json_array_begin excludes
    for line in "${patterns[@]}"; do output_json_array_string "$line"; done
    output_json_array_end
    output_json_kv filter_error "$errors"
    output_json_object_end
    return 0
  fi
  printf '%-28s %s%s\n' "$BACKUP_ENTRY_NAME" "${ printable "$resolved";}" "${BACKUP_ENTRY_FILTER:+" [filter: ${BACKUP_ENTRY_FILTER}]"}"
  for line in "${patterns[@]}"; do
    printf '    exclude: %s\n' "${ printable "$line";}"
  done
  while IFS= read -r line; do
    [[ -z "$line" ]] || printf '    error: %s\n' "${ printable "$line";}"
  done <<<"$errors"
  return 0
}

# backup_list - `backup list [--show-filters] [--json]`.
backup_list() {
  local json_mode=0
  opt_begin "show-filters:b json:b" backup "list: " "$@"
  opt_guard backup "list: "
  opt_json_mode
  output_json_enabled && json_mode=1
  load_settings --no-rclone
  if [[ -z "${OPT_show_filters:-}" ]]; then
    backupset_render "$json_mode"
    return 0
  fi
  _backup_list_rc=0
  _backup_list_json="$json_mode"
  if [[ "$json_mode" -eq 1 ]]; then
    output_json_begin
    output_json_array_begin backups
  fi
  backupset_each _backup_list_cb
  if [[ "$json_mode" -eq 1 ]]; then
    output_json_array_end
    output_json_end
  elif [[ "${ backupset_count;}" -eq 0 ]]; then
    printf 'No backup sources configured (edit %s).\n' "$BACKUPS_FILE"
  fi
  return "$_backup_list_rc"
}

# backup_add - `backup add LOCAL [--name NAME] [--filter FILE]`.
backup_add() {
  local local_arg="" local_path="" name="" filter="" src="" base=""
  opt_begin "name:s filter:s" backup "add: " "$@"
  opt_require_sub backup "add: LOCAL" "${OPT_EXTRA:-}" 1 1
  local_arg="${POSITIONAL_ARGS[0]}"
  filter="${OPT_filter:-}"
  load_settings --no-rclone
  backup_abs_path_into local_path "$local_arg"
  local_path="${local_path%/}"
  [[ -n "$local_path" ]] || local_path="/"
  [[ -d "$local_path" ]] || die "local directory does not exist: ${ printable "$local_path";}"
  if [[ -n "${OPT_name:-}" ]]; then
    name="$OPT_name"
  else
    base="${local_path##*/}"
    sanitize_name_into name "$base"
    [[ -n "$name" ]] || die "cannot derive a source name from '${ printable "$local_path";}'; pass --name NAME"
  fi
  if [[ -n "$filter" ]]; then
    src=${ backup_filter_resolve "$filter";} || die "filter file not found: ${FILTER_DIR}/${ printable "$filter";}"
    backup_filter_check "$src" || die "filter ${filter} has unsupported rules (see above); backups accept exclude rules only"
  fi
  acquire_lock backup
  backupset_append "$name" "$local_path" "$filter"
  printf "Added backup source '%s' (%s)%s.\n" "$name" "${ printable "$local_path";}" "${filter:+", filter ${filter}"}"
  return 0
}

# backup_remove - `backup remove NAME`.
backup_remove() {
  local name=""
  opt_begin "" backup "remove: " "$@"
  opt_require_sub backup "remove: NAME" "${OPT_EXTRA:-}" 1 1
  name="${POSITIONAL_ARGS[0]}"
  load_settings --no-rclone
  acquire_lock backup
  backupset_remove "$name" || die "${ unknown_source_prefix "$name";} in ${BACKUPS_FILE}"
  printf "Removed backup source '%s' (its snapshots stay in the repository).\n" "$name"
  return 0
}

# ---------------------------------------------------------------------------
# snapshots / ls / restore

# backup_snapshots - `backup snapshots [--only NAME] [--json]`.
backup_snapshots() {
  local rc=0
  local -a args=(snapshots)
  opt_begin "only:s json:b" backup "snapshots: " "$@"
  opt_guard backup "snapshots: "
  backup_preamble
  backup_require_password
  if [[ -n "${OPT_only:-}" ]]; then
    args+=(--host "${ backup_host;}" --tag "source=${OPT_only}")
  fi
  [[ -z "${OPT_json:-}" ]] || args+=(--json)
  backup_passthrough "${args[@]}" || rc=$?
  [[ "$rc" -eq 0 ]] || die "restic snapshots failed: ${ restic_rc_describe "$rc";}"
  return 0
}

# backup_ls - `backup ls SNAPSHOT [PATH]`.
backup_ls() {
  local rc=0
  local -a args=(ls)
  opt_begin "" backup "ls: " "$@"
  opt_require_sub backup "ls: SNAPSHOT" "${OPT_EXTRA:-}" 1 2
  args+=(-- "${POSITIONAL_ARGS[@]}")
  backup_preamble
  backup_require_password
  backup_passthrough "${args[@]}" || rc=$?
  [[ "$rc" -eq 0 ]] || die "restic ls failed: ${ restic_rc_describe "$rc";}"
  return 0
}

# backup_restore - `backup restore SNAPSHOT --target DIR [--include PATH]...
# [--dry-run] [--force]`.
backup_restore() {
  local snapshot="" target="" reason="" force=0 rc=0 path=""
  local -a args=(restore)
  opt_begin "target:s include:S dry-run:b force:b" backup "restore: " "$@"
  opt_require_sub backup "restore: SNAPSHOT" "${OPT_EXTRA:-}" 1 1
  snapshot="${POSITIONAL_ARGS[0]}"
  [[ -n "${OPT_target:-}" ]] || usage_error backup "restore: --target DIR is required"
  opt_into force force 1
  backup_preamble
  backup_require_password
  backup_abs_path_into target "$OPT_target"
  if ! reason=${ backup_restore_target_check "$target" "$force";}; then
    die "$reason"
  fi
  # The guard judged the canonical path; create and restore into exactly that.
  target="$BACKUP_RESTORE_CANON"
  if [[ -z "${OPT_dry_run:-}" ]]; then
    mkdir -p -- "$target" || die "cannot create restore target ${ printable "$target";}"
  fi
  args+=(--target "$target")
  while IFS= read -r path; do
    [[ -z "$path" ]] || args+=(--include "$path")
  done <<<"${OPT_include:-}"
  [[ -z "${OPT_dry_run:-}" ]] || args+=(--dry-run)
  args+=(-- "$snapshot")
  backup_set_bwlimit
  backup_passthrough "${args[@]}" || rc=$?
  [[ "$rc" -eq 0 ]] || die "restic restore failed: ${ restic_rc_describe "$rc";}"
  return 0
}

# ---------------------------------------------------------------------------
# forget / check / unlock

# backup_forget - `backup forget [--apply] [--prune]`: dry run by default.
backup_forget() {
  local rc=0 prune=0
  local -a args=(forget --group-by "host,paths")
  opt_begin "apply:b prune:b" backup "forget: " "$@"
  opt_guard backup "forget: "
  backup_preamble
  backup_require_password
  # Only this host's snapshots (see backup_maintenance).
  args+=(--host "${ backup_host;}")
  backup_keep_args_into args || die "refusing to forget without a retention policy (set BACKUP_KEEP_*)"
  opt_into prune prune 1
  if [[ -n "${OPT_apply:-}" ]]; then
    [[ "${BACKUP_PRUNE:-0}" != "1" ]] || prune=1
    acquire_lock backup
  else
    args+=(--dry-run)
  fi
  [[ "$prune" -eq 0 ]] || args+=(--prune)
  backup_set_bwlimit
  backup_passthrough "${args[@]}" || rc=$?
  [[ "$rc" -eq 0 ]] || die "restic forget failed: ${ restic_rc_describe "$rc";}"
  if [[ -z "${OPT_apply:-}" ]]; then
    printf 'Dry run: nothing was removed (use --apply to apply the policy).\n'
    return 0
  fi
  backupstate_mark forget || true
  if [[ "$prune" -eq 1 ]]; then
    printf '%s\n' "Pruned packs land in the server's trash bin; they stop counting against" \
      "the quota only once the trash bin is emptied (web UI or automatic expiry)."
  fi
  return 0
}

# backup_check - `backup check [--read-data-subset SPEC]`.
backup_check() {
  local subset="" rc=0
  opt_begin "read-data-subset:s" backup "check: " "$@"
  opt_guard backup "check: "
  subset="${OPT_read_data_subset:-}"
  if [[ -n "$subset" ]] && ! backup_check_subset "$subset"; then
    usage_error backup "check: --read-data-subset must be N%, N/M, or a size like 2G (got '${ printable "$subset";}')"
  fi
  backup_preamble
  backup_require_password
  [[ -n "$subset" ]] || subset="${BACKUP_CHECK_READ_DATA_SUBSET:-}"
  acquire_lock backup
  backup_set_bwlimit
  if [[ -n "$subset" ]]; then
    backup_passthrough check --read-data-subset "$subset" || rc=$?
  else
    backup_passthrough check || rc=$?
  fi
  [[ "$rc" -eq 0 ]] || die "restic check failed: ${ restic_rc_describe "$rc";}"
  backupstate_mark check || true
  return 0
}

# backup_unlock - `backup unlock`: remove stale restic repository locks.
backup_unlock() {
  local rc=0
  opt_begin "" backup "unlock: " "$@"
  opt_guard backup "unlock: "
  backup_preamble
  backup_require_password
  acquire_lock backup
  backup_passthrough unlock || rc=$?
  [[ "$rc" -eq 0 ]] || die "restic unlock failed: ${ restic_rc_describe "$rc";}"
  printf 'restic unlock: %s\n' "${ restic_rc_describe "$rc";}"
  return 0
}

# ---------------------------------------------------------------------------
# info / key

# backup_age_label AGE - "never" unchanged, any other age as "<AGE> ago".
backup_age_label() {
  if [[ "$1" == "never" ]]; then printf 'never'; else printf '%s ago' "$1"; fi
}

# backup_info - `backup info [--json] [--offline]`.
backup_info() {
  local restic_path="" restic_ver="" rclone_ver="" store="" stored=false sources=0
  local last_run="" last_forget="" last_check="" retention="" cache_kib="" snapshots="" snap_error=""
  local rc=0 out="" item="" flag=""
  local -a keep=()
  opt_begin "json:b offline:b" backup "info: " "$@"
  opt_guard backup "info: "
  opt_json_mode
  if rclone_available; then load_settings; else load_settings --no-rclone; fi
  if restic_available; then
    restic_path=${ restic_bin;}
    restic_ver=${ restic_version;}
  fi
  rclone_ver=${ rclone_version;} || rclone_ver=""
  store=${ backup_password_where;}
  if (restic_password >/dev/null 2>&1); then stored=true; fi
  sources=${ backupset_count;}
  last_run=${ backupstate_age_human run;}
  last_forget=${ backupstate_age_human forget;}
  last_check=${ backupstate_age_human check;}
  if backup_keep_args_into keep 2>/dev/null; then
    for item in "${keep[@]}"; do
      if [[ "$item" == --* ]]; then
        flag="${item#--}"
      else
        retention+="${retention:+, }${flag} ${item}"
      fi
    done
  else
    retention="empty (forget refused)"
  fi
  if [[ -d "${BACKUP_CACHE_DIR:-}" ]]; then
    cache_kib="$(du -sk "$BACKUP_CACHE_DIR" 2>/dev/null)" || cache_kib=""
    cache_kib="${cache_kib%%[[:space:]]*}"
  fi
  if [[ -n "${OPT_offline:-}" ]]; then
    snap_error="skipped (--offline)"
  elif [[ -z "$restic_path" ]]; then
    snap_error="restic not installed"
  elif [[ "$stored" != true ]]; then
    snap_error="no repository password stored"
  elif ! remote_configured; then
    snap_error="unreachable: rclone remote '${RCLONE_REMOTE}:' is not configured"
  else
    rc=0
    restic_capture backup-info snapshots --json || rc=$?
    if [[ "$rc" -eq 0 ]]; then
      out=${ grep -o '"short_id"' "$RESTIC_CAPTURE_OUT" | wc -l;} || out=0
      snapshots="${out//[[:space:]]/}"
    else
      snap_error="unreachable: ${ backup_failure_text "$rc" "${ tail -n 20 "$RESTIC_CAPTURE_ERR" 2>/dev/null;}";}"
    fi
    backup_capture_discard
  fi
  if output_json_enabled; then
    output_json_begin
    output_json_kv repository "${ restic_repository;}"
    output_json_kv restic_bin "$restic_path"
    output_json_kv restic_version "$restic_ver"
    output_json_kv rclone_version "$rclone_ver"
    output_json_kv password_store "$store"
    output_json_kv_bool password_stored "$stored"
    output_json_kv_raw sources "$sources"
    output_json_kv last_run "$last_run"
    output_json_kv last_forget "$last_forget"
    output_json_kv last_check "$last_check"
    output_json_kv retention "$retention"
    output_json_kv cache_dir "${BACKUP_CACHE_DIR:-}"
    output_json_kv_raw cache_kib "${cache_kib:-null}"
    output_json_kv_raw snapshots "${snapshots:-null}"
    output_json_kv snapshots_error "$snap_error"
    output_json_end
    return 0
  fi
  printf '%-16s %s\n' "repository" "${ restic_repository;}"
  if [[ -n "$restic_path" ]]; then
    printf '%-16s %s (%s)\n' "restic" "${restic_ver:-unknown version}" "$restic_path"
  else
    printf '%-16s %s\n' "restic" "not installed"
  fi
  printf '%-16s %s\n' "rclone" "${rclone_ver:-not found}"
  item="not stored"
  [[ "$stored" != true ]] || item="stored"
  printf '%-16s %s (%s)\n' "password" "$store" "$item"
  printf '%-16s %s (%s)\n' "sources" "$sources" "$BACKUPS_FILE"
  printf '%-16s %s\n' "last run" "${ backup_age_label "$last_run";}"
  printf '%-16s %s\n' "last forget" "${ backup_age_label "$last_forget";}"
  printf '%-16s %s\n' "last check" "${ backup_age_label "$last_check";}"
  printf '%-16s %s\n' "retention" "$retention"
  if [[ -n "$cache_kib" ]]; then
    printf '%-16s %s (%s)\n' "cache" "$BACKUP_CACHE_DIR" "${ format_size_bytes "$((cache_kib * 1024))";}"
  else
    printf '%-16s %s (empty)\n' "cache" "${BACKUP_CACHE_DIR:-}"
  fi
  if [[ -n "$snapshots" ]]; then
    printf '%-16s %s\n' "snapshots" "$snapshots"
  else
    printf '%-16s %s\n' "snapshots" "$snap_error"
  fi
  return 0
}

# backup_key - `backup key show`: print the repository password after a
# confirmation; a non-interactive run refuses.
backup_key() {
  local action="" pw="" gate=0
  opt_begin "" backup "key: " "$@"
  opt_require_sub backup "key: an action (show)" "${OPT_EXTRA:-}" 1 1
  action="${POSITIONAL_ARGS[0]}"
  [[ "$action" == "show" ]] || usage_error backup "key: unknown action: ${ printable "$action";} (use show)"
  load_settings --no-rclone
  pw=${ restic_password;} || pw=""
  [[ -n "$pw" ]] || die "no repository password stored; run 'sciebo backup init'"
  ui_confirm_tty "Print the repository password to this terminal?" || gate=$?
  case "$gate" in
    0) ;;
    1)
      printf 'aborted\n'
      return 1
      ;;
    *) die "refusing to print the repository password without an interactive confirmation" ;;
  esac
  printf '%s\n' "$pw"
  return 0
}

# ---------------------------------------------------------------------------
# dispatch

cmd_backup() {
  local sub="${1:-}"
  case "$sub" in
    init | run | list | add | remove | snapshots | ls | restore | forget | check | unlock | info | key) ;;
    -h | --help)
      usage_backup
      exit 0
      ;;
    "")
      usage_error backup "a subcommand is required (init|run|list|add|remove|snapshots|ls|restore|forget|check|unlock|info|key)"
      ;;
    *)
      usage_unknown_sub backup "$sub"
      ;;
  esac
  shift
  case "$sub" in
    init) backup_init "$@" ;;
    run) backup_run "$@" ;;
    list) backup_list "$@" ;;
    add) backup_add "$@" ;;
    remove) backup_remove "$@" ;;
    snapshots) backup_snapshots "$@" ;;
    ls) backup_ls "$@" ;;
    restore) backup_restore "$@" ;;
    forget) backup_forget "$@" ;;
    check) backup_check "$@" ;;
    unlock) backup_unlock "$@" ;;
    info) backup_info "$@" ;;
    key) backup_key "$@" ;;
  esac
}
