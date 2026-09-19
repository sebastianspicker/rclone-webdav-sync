#!/bin/bash
# sync.sh command module - list, dry run (check), and apply (sync).
# `sciebo check` is a dry run; .nosync and filters apply to sync/pull only.

SYNC_FORCE_DRY=false
SYNC_APPLY=false
SYNC_QUIET=false
SYNC_RESYNC=false
SYNC_TIMESTAMP=""
# Leading newline so *$'\n'NAME$'\n'* also matches the first warned name.
SYNC_DUP_WARNED=$'\n'

usage_sync() {
  cat <<'EOF'
Usage: sciebo sync [options]

Apply sync/pull/bisync entries from config/sources.conf,
config/folders.conf, and config/sources.generated.conf. `sciebo check` is
the same run with --dry-run forced.

Options:
  --apply        transfer data (default for sync; check stays a dry run)
  --dry-run      explicit dry run (default for check)
  --only NAME    run only entries whose sanitized name is NAME; `sciebo
                 list` shows the names
  --resync       allow rclone bisync --resync, the first-time
                 initialization. WARNING: resync can copy or delete files
                 in BOTH directions; review a dry run with --resync first
  --quiet        only print failures, warnings, and the final summary
  --no-lock      do not take the run lock
  -h, --help     show this help

A directory containing a .nosync file is skipped by sync/pull entries
only; bisync ignores .nosync markers. The remote must be set up with
`sciebo setup`. Duplicate entry names are refused for bisync entries and
warned about otherwise.
EOF
}

usage_check() { usage_sync; }

usage_list() {
  cat <<'EOF'
Usage: sciebo list

List the parsed sources with mode, name, local path, remote path, and
filter, including invalid entries with their error.
EOF
}

# sync_entry_status STATUS [REASON] [LOG] - one status row plus optional
# reason/log lines; OK and SKIP rows are suppressed by --quiet, FAIL always
# prints.
sync_entry_status() {
  local status="$1" reason="${2:-}" log="${3:-}"
  if [[ "$status" == FAIL || "$SYNC_QUIET" == false ]]; then
    printf '%-4s %-6s %-28s %s\n' "$status" "$ENTRY_MODE" "$ENTRY_NAME" "$(remote_spec "$ENTRY_REMOTE")"
    [[ -z "$reason" ]] || printf '     reason: %s\n' "$reason"
    [[ -z "$log" ]] || printf '     log: %s\n' "$log"
  fi
}

cmd_list() {
  if [[ $# -gt 0 ]]; then
    case "$1" in
      -h | --help) usage_list && exit 0 ;;
      *) usage_error list "unknown option: $1" ;;
    esac
  fi
  load_settings --no-rclone
  local line="" spec="" filter_suffix="" count=0
  while IFS= read -r line; do
    if manifest_parse_line "$line"; then
      count=$((count + 1))
      spec="$(printable "$(remote_spec "$ENTRY_REMOTE")")"
      filter_suffix=""
      [[ -z "$ENTRY_FILTER" ]] || filter_suffix=" [filter: ${ENTRY_FILTER}]"
      printf '%-7s %-28s %s -> %s%s\n' "$ENTRY_MODE" "$ENTRY_NAME" "$ENTRY_LOCAL" "$spec" "$filter_suffix"
    else
      printf '%-7s %-28s %s\n' "INVALID" "-" "$ENTRY_ERROR"
    fi
  done < <(manifest_lines)
  if [[ "$count" -eq 0 ]]; then printf 'No sources configured (edit config/sources.conf).\n'; fi
  return 0
}

# sync_run_entry - run the entry currently parsed into ENTRY_*; returns
# 0=ok, 1=failed, 2=skipped. Prints its own status lines.
sync_run_entry() {
  local spec="" logfile="" log_suffix="" rc=0
  spec="$(remote_spec "$ENTRY_REMOTE")"
  if [[ ! -d "$ENTRY_LOCAL" ]]; then
    if [[ "$ENTRY_MODE" != pull ]]; then
      sync_entry_status FAIL "local directory does not exist: ${ENTRY_LOCAL}"
      return 1
    fi
    if [[ "$SYNC_APPLY" == false ]]; then
      sync_entry_status SKIP "local dir does not exist yet (first apply will create it)"
      return 2
    fi
    if ! mkdir -p "$ENTRY_LOCAL"; then
      sync_entry_status FAIL "cannot create local directory: ${ENTRY_LOCAL}"
      return 1
    fi
  fi
  if [[ "$SYNC_APPLY" == false ]]; then log_suffix="-dryrun"; fi
  logfile="${LOG_DIR}/${ENTRY_NAME}-${SYNC_TIMESTAMP}${log_suffix}.log"
  local common_flags=(--transfers "$TRANSFERS" --checkers "$CHECKERS" --tpslimit "$TPSLIMIT" --retries "$RETRIES" --low-level-retries "$LOW_LEVEL_RETRIES" --timeout "$TIMEOUT" --contimeout "$CONTIMEOUT" --stats "$STATS" --stats-one-line --log-level "$LOG_LEVEL" --log-file "$logfile")
  local filter_flags=(--filter-from "${FILTER_DIR}/clutter.txt")
  [[ -z "$ENTRY_FILTER" ]] || filter_flags+=(--filter-from "${FILTER_DIR}/${ENTRY_FILTER}")
  local args=() src="" dst=""
  case "$ENTRY_MODE" in
    sync | pull)
      src="${ENTRY_LOCAL}/"
      dst="${spec}/"
      [[ "$ENTRY_MODE" == pull ]] && src="${spec}/" dst="${ENTRY_LOCAL}/"
      args=(sync "$src" "$dst" "${common_flags[@]}" "${filter_flags[@]}" --exclude-if-present .nosync)
      ;;
    bisync)
      if [[ "$SYNC_APPLY" == false ]] && ! remote_dir_exists "$spec"; then
        sync_entry_status SKIP "remote dir does not exist yet (first apply will create it)"
        return 2
      fi
      if [[ "$SYNC_RESYNC" == false ]] && ! bisync_initialized "$ENTRY_NAME"; then
        sync_entry_status FAIL "bisync state missing for '${ENTRY_NAME}'; run 'make bisync-resync'"
        return 1
      fi
      if [[ "$SYNC_APPLY" == true ]] && ! rclone_cmd mkdir "${spec}/"; then
        sync_entry_status FAIL "rclone mkdir failed for ${spec}/"
        return 1
      fi
      args=(bisync "${ENTRY_LOCAL}/" "${spec}/" --workdir "${BISYNC_DIR}/${ENTRY_NAME}" --conflict-resolve "$BISYNC_CONFLICT_RESOLVE" "${common_flags[@]}" "${filter_flags[@]}")
      if [[ "$SYNC_RESYNC" == true ]]; then args+=(--resync); fi
      ;;
  esac
  if [[ "$SYNC_APPLY" == false ]]; then args+=(--dry-run); fi
  rclone_cmd "${args[@]}" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    sync_entry_status OK
    return 0
  fi
  sync_entry_status FAIL "rclone ${ENTRY_MODE} failed (exit ${rc})" "$logfile"
  return 1
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

cmd_sync() {
  local only="" line="" rc=0 total=0 ok=0 failed=0 skipped=0 names="" summary=""
  local list=false resync=false no_lock=false
  opt_reset apply dry-run only list resync quiet no-lock
  opt_parse "apply:b dry-run:b only:s list:b resync:b quiet:b no-lock:b" sync "" "$@"
  if [[ "$OPT_HELP" -ne 0 ]]; then usage_sync && exit 0; fi
  [[ -z "$OPT_EXTRA" ]] || usage_error sync "unknown option: ${OPT_EXTRA%%$'\n'*}"
  only="${OPT_only:-}"
  [[ -z "${OPT_list:-}" ]] || list=true
  [[ -z "${OPT_resync:-}" ]] || resync=true
  [[ -z "${OPT_no_lock:-}" ]] || no_lock=true
  SYNC_APPLY=true
  if [[ "$SYNC_FORCE_DRY" == true || -n "${OPT_dry_run:-}" ]]; then
    SYNC_APPLY=false
  fi
  SYNC_QUIET=false
  [[ -z "${OPT_quiet:-}" ]] || SYNC_QUIET=true
  SYNC_RESYNC="$resync"
  SYNC_DUP_WARNED=$'\n'
  if [[ "$list" == true ]]; then cmd_list && return 0; fi
  load_settings
  ensure_state_dirs
  require_remote
  if [[ "$no_lock" == false ]]; then acquire_lock; fi
  SYNC_TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
  if [[ "$resync" == true ]]; then warn "--resync: bisync can copy or delete files in BOTH directions"; fi
  if [[ "$SYNC_QUIET" == false ]]; then
    if [[ "$SYNC_APPLY" == true ]]; then
      log "Applying changes to ${REMOTE_PREFIX} (${RCLONE_CONFIG})"
    else
      log "DRY RUN: no changes will be made (use 'sciebo sync' to transfer)"
    fi
  fi
  manifest_index_load
  if [[ -n "$only" ]] && ! manifest_has_name "$only"; then
    names="$(trim "$(printf '%s' "$MANIFEST_NAMES" | sort -u | tr '\n' ' ')")"
    die "No source named '${only}'. Available: ${names:-<none>}"
  fi
  while IFS= read -r line; do
    if ! manifest_parse_line "$line"; then
      total=$((total + 1))
      failed=$((failed + 1))
      sync_entry_status FAIL "$ENTRY_ERROR"
      continue
    fi
    if [[ -n "$only" && "$ENTRY_NAME" != "$only" ]]; then
      skipped=$((skipped + 1))
      sync_entry_status SKIP
      continue
    fi
    total=$((total + 1))
    if manifest_has_duplicate_name "$ENTRY_NAME"; then
      if [[ "$ENTRY_MODE" == bisync ]]; then
        failed=$((failed + 1))
        sync_entry_status FAIL "duplicate source name '${ENTRY_NAME}'; bisync state would be shared"
        continue
      fi
      sync_warn_duplicate "$ENTRY_NAME" "$ENTRY_MODE"
    fi
    rc=0
    sync_run_entry || rc=$?
    case "$rc" in
      0) ok=$((ok + 1)) ;;
      2) skipped=$((skipped + 1)) ;;
      *) failed=$((failed + 1)) ;;
    esac
  done < <(manifest_lines)
  summary="Summary: ${total} sources (${ok} ok, ${failed} failed, ${skipped} skipped)"
  [[ "$SYNC_APPLY" == true ]] || summary="${summary} - dry run, no changes made"
  printf '%s\n' "$summary"
  [[ "$failed" -eq 0 ]]
}

cmd_check() {
  SYNC_FORCE_DRY=true
  cmd_sync "$@"
}
