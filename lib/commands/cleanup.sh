#!/bin/bash
# cleanup.sh command module - old logs, stale Nextcloud chunk uploads,
# orphaned state, mount-cache leftovers, and old support archives.
#
# The selected-target flags and the example caps are read through indirect
# expansion (${!flag}) and namerefs, which shellcheck cannot follow.
# shellcheck disable=SC2034  # CLEANUP_* targets are read via ${!flag}/namerefs

CLEANUP_LOGS=0
CLEANUP_UPLOADS=0
CLEANUP_STATE=0
CLEANUP_JUNK=0
CLEANUP_CACHE=0
CLEANUP_SUPPORT=0
CLEANUP_APPLY=0
CLEANUP_KEEP=5
CLEANUP_HAD_ERROR=0
CLEANUP_LOGS_FOUND=0
CLEANUP_LOGS_DELETED=0
CLEANUP_STATE_FOUND=0
CLEANUP_STATE_DELETED=0
CLEANUP_JUNK_FOUND=0
CLEANUP_JUNK_DELETED=0
CLEANUP_JUNK_EXAMPLES=5
CLEANUP_CACHE_FOUND=0
CLEANUP_CACHE_DELETED=0
CLEANUP_CACHE_EMPTY=0
CLEANUP_CACHE_EXAMPLES=5
CLEANUP_SUPPORT_FOUND=0
CLEANUP_SUPPORT_DELETED=0
# Housekeeping targets in run/summary order. Each name maps to --<name>,
# CLEANUP_<NAME> (1 when selected), cleanup_do_<name>, and a summary line.
CLEANUP_TARGETS=(logs uploads state junk cache support)

usage_cleanup() {
  usage_emit <<'EOF'
Usage: sciebo cleanup (--logs | --uploads | --state | --junk | --cache | --support) [--apply]

Housekeeping for the rclone-sciebo tooling. Dry run by default: nothing
is deleted unless --apply is given. Refuses to run while the local sync
lock is held; runs on other devices cannot be detected, so chunk uploads
are only removed once older than CHUNK_CLEANUP_MIN_AGE. State leftovers
and mount-cache files are only removed once older than
STATE_CLEANUP_MIN_AGE. Junk files are only removed once older than
JUNK_CLEANUP_MIN_AGE.

Options:
  --logs      delete log files older than LOG_RETENTION_DAYS (or
              LOG_EXPIRE_HOURS when set) and rotate '*.log' files larger
              than LOG_MAX_BYTES to <file>.1
  --uploads   delete stale chunk uploads under /remote.php/dav/uploads/
              older than CHUNK_CLEANUP_MIN_AGE, then remove the emptied
              transfer directories
  --state     delete stale bisync workdirs, lock leftovers, atomic-write
              temp files, and orphaned mount records older than
              STATE_CLEANUP_MIN_AGE
  --junk      delete files matching a glob in FILTER_DIR/fleeting.txt,
              under every manifest source directory and older than
              JUNK_CLEANUP_MIN_AGE
  --cache     delete files under MOUNT_CACHE_DIR older than
              STATE_CLEANUP_MIN_AGE
  --support   keep the newest support-*.tar.gz archives under STATE_DIR
              and delete the older ones
  --keep N    archives to keep for --support (default 5)
  --apply     actually delete (default is a dry run)
  -h, --help  show this help and exit
EOF
}

# Backend options go through RCLONE_WEBDAV_* env vars so the obscured
# password is not a command-line argument. It stays readable in the child
# environment (same user only), which is acceptable for this tool.
cleanup_chunk_rclone() {
  local uploads_url="$1" user="$2" pass="$3"
  shift 3
  RCLONE_WEBDAV_URL="$uploads_url" RCLONE_WEBDAV_VENDOR=other \
    RCLONE_WEBDAV_USER="$user" RCLONE_WEBDAV_PASS="$pass" \
    "$RCLONE_BIN" --config "$RCLONE_CONFIG" "$@"
}

cleanup_run_chunk_op() {
  local label="$1" uploads_url="$2" user="$3" pass="$4" hint="purge"
  shift 4
  local out=""
  if [[ "$label" == "rmdirs" ]]; then hint="remove"; fi
  if [[ "$CLEANUP_APPLY" -eq 0 ]]; then
    set -- "$@" --dry-run
  fi
  if out="$(cleanup_chunk_rclone "$uploads_url" "$user" "$pass" "$@" 2>&1)"; then
    [[ -z "$out" ]] || printf '%s\n' "$out"
    log "chunk ${label} pass complete"
  elif [[ "$out" == *"not found"* || "$out" == *"404"* ]]; then
    warn "chunk uploads directory missing or already empty; nothing to ${hint}"
  else
    err "chunk upload ${label} failed: ${out}"
    CLEANUP_HAD_ERROR=1
  fi
}

# cleanup_candidate PATH FOUND_VAR DELETED_VAR [MODE] [LIMIT_VAR] - count
# PATH as a candidate and either report it (dry run) or delete it with
# --apply, bumping the counters named by FOUND_VAR/DELETED_VAR through
# namerefs. MODE is "delete" (rm -f, the default) or "remove" (rm -rf, for
# state leftovers). LIMIT_VAR names an example cap: dry runs stay silent
# once the found counter passes it. Preserves the per-target wording.
cleanup_candidate() {
  local path="$1" found_var="$2" deleted_var="$3" mode="${4:-delete}" limit_var="${5:-}"
  local -n found="$found_var"
  local -n deleted="$deleted_var"
  local rc=0
  found=$((found + 1))
  if [[ "$CLEANUP_APPLY" -eq 0 ]]; then
    if [[ -n "$limit_var" ]]; then
      local -n limit="$limit_var"
      [[ "$found" -le "$limit" ]] || return 0
    fi
    log "would ${mode} ${path}"
    return 0
  fi
  if [[ "$mode" == "remove" ]]; then
    rm -rf "$path" || rc=1
  else
    rm -f "$path" || rc=1
  fi
  if [[ "$rc" -eq 0 ]]; then
    deleted=$((deleted + 1))
    log "${mode}d ${path}"
  else
    err "could not ${mode} ${path}"
    CLEANUP_HAD_ERROR=1
  fi
  return 0
}

# cleanup_rotate_logs SKIP_LIST - rename '*.log' files larger than
# LOG_MAX_BYTES to <file>.1, replacing an existing .1. SKIP_LIST holds the
# age-based deletion candidates (newline-separated), which are not rotated
# too. Only --apply renames; dry runs print 'rotate: FILE (SIZE)'. An empty
# or unparseable LOG_MAX_BYTES disables rotation.
cleanup_rotate_logs() {
  local skip_list="$1" max_bytes="" file size stamp size_label
  [[ -n "$LOG_MAX_BYTES" ]] || return 0
  max_bytes=${ size_suffix_bytes "$LOG_MAX_BYTES";} || return 0
  [[ -n "$max_bytes" ]] || return 0
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    _manifest_membership "$file" "$skip_list" && continue
    # file_stamp is one stat (mtime + size) instead of a full `wc -c` read of
    # every log file, so a large log is not scanned just to size it.
    stamp=${ file_stamp "$file";}
    size="${stamp#* }"
    case "$size" in
      '' | *[!0-9]*) continue ;;
    esac
    [[ "$size" -gt "$max_bytes" ]] || continue
    if [[ "$CLEANUP_APPLY" -eq 0 ]]; then
      size_label=${ format_size_bytes "$size";}
      log "rotate: ${file} (${size_label})"
    elif mv -f "$file" "${file}.1"; then
      log "rotated ${file} -> ${file}.1"
    else
      err "could not rotate ${file}"
      CLEANUP_HAD_ERROR=1
    fi
  done < <(find "$LOG_DIR" -type f -name '*.log' 2>/dev/null)
}

# cleanup_logs_min_age - the -mmin age for --logs: LOG_EXPIRE_HOURS when
# set (hours win over LOG_RETENTION_DAYS), else LOG_RETENTION_DAYS days.
cleanup_logs_min_age() {
  local hours="${LOG_EXPIRE_HOURS:-}"
  if [[ -n "$hours" ]]; then
    case "$hours" in
      '' | *[!0-9]*) die "LOG_EXPIRE_HOURS must be a non-negative integer (got '${hours}')" ;;
    esac
    printf '%s' "$((10#$hours * 60))"
    return 0
  fi
  case "$LOG_RETENTION_DAYS" in
    '' | *[!0-9]*) die "LOG_RETENTION_DAYS must be a non-negative integer (got '${LOG_RETENTION_DAYS}')" ;;
  esac
  printf '%s' "$((10#$LOG_RETENTION_DAYS * 1440))"
}

cleanup_do_logs() {
  local log_file candidates="" min_age="" age_label=""
  min_age="$(cleanup_logs_min_age)"
  if [[ -n "${LOG_EXPIRE_HOURS:-}" ]]; then
    age_label="${LOG_EXPIRE_HOURS} hour(s)"
  else
    age_label="${LOG_RETENTION_DAYS} day(s)"
  fi
  log "scanning ${LOG_DIR} for '*.log' older than ${age_label}"
  while IFS= read -r log_file; do
    [[ -n "$log_file" ]] || continue
    candidates="${candidates}${log_file}"$'\n'
    cleanup_candidate "$log_file" CLEANUP_LOGS_FOUND CLEANUP_LOGS_DELETED
  done < <(find "$LOG_DIR" -type f -name '*.log' -mmin "+${min_age}" 2>/dev/null)
  [[ "$CLEANUP_LOGS_FOUND" -gt 0 ]] || log "no log files older than ${age_label}"
  cleanup_rotate_logs "$candidates"
}

cleanup_do_uploads() {
  local config_dump url user pass uploads_url
  if ! config_dump="$(remote_config_dump)" || [[ -z "$config_dump" ]]; then
    die "cannot read rclone config from ${RCLONE_CONFIG}; run '${CLI_NAME} setup'"
  fi
  url="$(config_dump_value "$RCLONE_REMOTE" url "$config_dump")"
  user="$(config_dump_value "$RCLONE_REMOTE" user "$config_dump")"
  [[ -n "$url" && -n "$user" ]] ||
    die "remote '${RCLONE_REMOTE}:' is not fully configured (url/user/pass missing); run '${CLI_NAME} setup' first"
  pass=${ remote_secret_obscured;} || pass=""
  [[ -n "$pass" ]] ||
    die "remote '${RCLONE_REMOTE}:' has no app password (Keychain or rclone config); run '${CLI_NAME} setup' first"
  case "$url" in
    *"/dav/files/"*) ;;
    *) die "remote url '${url}' lacks /dav/files/; re-run '${CLI_NAME} setup'" ;;
  esac
  uploads_url="${url/files\//uploads/}"
  [[ "$uploads_url" != "$url" ]] || die "could not derive chunk uploads URL from '${url}'"

  log "purging chunk uploads older than ${CHUNK_CLEANUP_MIN_AGE} at ${uploads_url}"
  cleanup_run_chunk_op delete "$uploads_url" "$user" "$pass" delete ":webdav:" --min-age "$CHUNK_CLEANUP_MIN_AGE"
  cleanup_run_chunk_op rmdirs "$uploads_url" "$user" "$pass" rmdirs ":webdav:" --leave-root
}

# cleanup_age_minutes DURATION [KEY] - convert <N>[smhd] (bare N = minutes)
# into whole minutes, the unit find -mmin uses. KEY names the setting in
# error messages. Dies on anything else.
cleanup_age_minutes() {
  local duration="$1" key="${2:-STATE_CLEANUP_MIN_AGE}" seconds=""
  seconds="$(duration_seconds "$duration" minutes 2>/dev/null)" || seconds=""
  [[ -n "$seconds" ]] ||
    die "${key} must look like <N>[smhd] (got '${duration}')"
  printf '%s' "$((seconds / 60))"
}

# cleanup_state_each_entry - print one valid entry's sanitized name.
cleanup_state_each_entry() {
  printf '%s\n' "$ENTRY_NAME"
}

# cleanup_state_used_names - bisync workdir names of every valid manifest
# entry, one per line (any mode).
cleanup_state_used_names() {
  manifest_each cleanup_state_each_entry
}

cleanup_do_state_bisync() {
  local min_age="$1" used="" dir name
  used="$(cleanup_state_used_names)"
  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    name="${dir##*/}"
    _manifest_membership "$name" "$used" && continue
    cleanup_candidate "$dir" CLEANUP_STATE_FOUND CLEANUP_STATE_DELETED remove
  done < <(find "$BISYNC_DIR" -mindepth 1 -maxdepth 1 -type d -mmin "+${min_age}" 2>/dev/null)
}

cleanup_do_state_locks() {
  local min_age="$1" dir
  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    cleanup_candidate "$dir" CLEANUP_STATE_FOUND CLEANUP_STATE_DELETED remove
  done < <(find "$LOCK_DIR" -mindepth 1 -maxdepth 1 -type d \
    \( -name 'sync.lock.stale.*' -o -name 'sync.lock.release.*' \) \
    -mmin "+${min_age}" 2>/dev/null)
}

# cleanup_do_state_tmp MIN_AGE - find leftover atomic_write staging files
# (<file>.tmp.XXXXXX, six random characters from mktemp). The six-character
# requirement keeps an ordinary user file that merely contains ".tmp." out
# of the rm -rf path.
cleanup_do_state_tmp() {
  local min_age="$1" file
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    cleanup_candidate "$file" CLEANUP_STATE_FOUND CLEANUP_STATE_DELETED remove
  done < <(find "$CONFIG_DIR" "$STATE_DIR" -type f -name '*.tmp.??????' -mmin "+${min_age}" 2>/dev/null)
}

# cleanup_do_state_mounts - drop mount records whose mountpoint is not in
# `mount` output and whose recorded pid (when numeric) is no longer alive.
# The visibility check is local on purpose: commands never call mount.sh.
cleanup_do_state_mounts() {
  local min_age="$1" table state mountpoint pid line needle=""
  table="$(mount 2>/dev/null || true)"
  while IFS= read -r state; do
    [[ -n "$state" ]] || continue
    mountpoint="" pid=""
    { IFS= read -r line && IFS= read -r mountpoint && IFS= read -r pid && IFS= read -r line; } <"$state" || true
    [[ -n "$mountpoint" ]] || continue
    # Build a literal needle: a mountpoint containing glob characters must
    # not match a different row.
    printf -v needle ' on %s (' "$mountpoint"
    [[ "$table" == *"$needle"* ]] && continue
    if pid_alive "$pid"; then continue; fi
    cleanup_candidate "$state" CLEANUP_STATE_FOUND CLEANUP_STATE_DELETED remove
  done < <(find "$MOUNTS_DIR" -maxdepth 1 -type f -name '*.state' -mmin "+${min_age}" 2>/dev/null)
}

cleanup_do_state() {
  local min_age
  min_age="$(cleanup_age_minutes "$STATE_CLEANUP_MIN_AGE")"
  log "scanning state for leftovers older than ${STATE_CLEANUP_MIN_AGE}"
  cleanup_do_state_bisync "$min_age"
  cleanup_do_state_locks "$min_age"
  cleanup_do_state_tmp "$min_age"
  cleanup_do_state_mounts "$min_age"
}

# cleanup_junk_scan_dir DIR MIN_AGE NAME_PREDICATE... - find regular files
# under DIR that match one of the -name predicates and are older than
# MIN_AGE minutes. `find` never follows symlinks, so nothing outside DIR
# can be reached.
cleanup_junk_scan_dir() {
  local dir="$1" min_age="$2" path
  shift 2
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    cleanup_candidate "$path" CLEANUP_JUNK_FOUND CLEANUP_JUNK_DELETED delete CLEANUP_JUNK_EXAMPLES
  done < <(find "$dir" -type f \( "$@" \) -mmin "+${min_age}" 2>/dev/null)
}

# cleanup_junk_each_entry MIN_AGE NAME_ARGS... - scan one valid entry's local
# directory for junk files. The status is always 0 so the walk continues.
cleanup_junk_each_entry() {
  local min_age="$1"
  shift
  [[ -d "$ENTRY_LOCAL" ]] || return 0
  cleanup_junk_scan_dir "$ENTRY_LOCAL" "$min_age" "$@"
  return 0
}

# cleanup_do_junk - scan every valid manifest entry's local directory for
# files matching a glob in FILTER_DIR/fleeting.txt, older than
# JUNK_CLEANUP_MIN_AGE. Missing local directories are skipped quietly.
cleanup_do_junk() {
  local fleeting="${FILTER_DIR}/fleeting.txt" min_age="" line
  if [[ ! -f "$fleeting" ]]; then
    log "no fleeting file (${fleeting})"
    return 0
  fi
  min_age="$(cleanup_age_minutes "$JUNK_CLEANUP_MIN_AGE" JUNK_CLEANUP_MIN_AGE)"
  local -a name_args=()
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if [[ "${#name_args[@]}" -gt 0 ]]; then
      name_args[${#name_args[@]}]='-o'
    fi
    name_args[${#name_args[@]}]='-name'
    name_args[${#name_args[@]}]="$line"
  done < <(config_lines "$fleeting")
  if [[ "${#name_args[@]}" -eq 0 ]]; then
    log "no junk patterns in ${fleeting}"
    return 0
  fi
  log "scanning manifest folders for junk older than ${JUNK_CLEANUP_MIN_AGE}"
  manifest_each cleanup_junk_each_entry "$min_age" "${name_args[@]}"
  [[ "$CLEANUP_JUNK_FOUND" -gt 0 ]] || log "no junk files older than ${JUNK_CLEANUP_MIN_AGE}"
}

# cleanup_do_cache - scan MOUNT_CACHE_DIR for files older than
# STATE_CLEANUP_MIN_AGE. A missing or empty cache directory sets
# CLEANUP_CACHE_EMPTY, which the summary reports as 'cache: nothing to do'.
cleanup_do_cache() {
  local min_age="" file
  CLEANUP_CACHE_EMPTY=0
  if [[ ! -d "$MOUNT_CACHE_DIR" ]] ||
    [[ -z "$(find "$MOUNT_CACHE_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    CLEANUP_CACHE_EMPTY=1
    return 0
  fi
  min_age="$(cleanup_age_minutes "$STATE_CLEANUP_MIN_AGE")"
  log "scanning ${MOUNT_CACHE_DIR} for files older than ${STATE_CLEANUP_MIN_AGE}"
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    cleanup_candidate "$file" CLEANUP_CACHE_FOUND CLEANUP_CACHE_DELETED delete CLEANUP_CACHE_EXAMPLES
  done < <(find "$MOUNT_CACHE_DIR" -type f -mmin "+${min_age}" 2>/dev/null)
  [[ "$CLEANUP_CACHE_FOUND" -gt 0 ]] || log "no mount cache files older than ${STATE_CLEANUP_MIN_AGE}"
}

# cleanup_do_support [KEEP] - keep the newest KEEP (default CLEANUP_KEEP)
# support-*.tar.gz archives under STATE_DIR and report/delete the older
# ones. Files are sorted by mtime (oldest first); an unreadable mtime sorts
# as 0 and is removed first.
cleanup_do_support() {
  local keep="${1:-$CLEANUP_KEEP}" list="" file="" mtime="" total=0 index=0 line=""
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    mtime="$(file_mtime "$file")"
    list="${list}${mtime:-0}"$'\t'"${file}"$'\n'
    total=$((total + 1))
  done < <(find "$STATE_DIR" -maxdepth 1 -type f -name 'support-*.tar.gz' 2>/dev/null)
  if [[ "$total" -eq 0 ]]; then
    return 0
  fi
  log "keeping the newest ${keep} of ${total} support archive(s) in ${STATE_DIR}"
  while IFS= read -r line; do
    record_split "$line" mtime file
    [[ -n "$file" ]] || continue
    index=$((index + 1))
    [[ "$index" -le "$((total - keep))" ]] || break
    cleanup_candidate "$file" CLEANUP_SUPPORT_FOUND CLEANUP_SUPPORT_DELETED
  done < <(printf '%s' "$list" | LC_ALL=C sort -n)
  [[ "$CLEANUP_SUPPORT_FOUND" -gt 0 ]] || log "no support archives older than the newest ${keep}"
}

# cleanup_summary_target TARGET - the per-target summary line, reading the
# counters the matching cleanup_do_* filled (chunk uploads has none).
cleanup_summary_target() {
  case "$1" in
    logs) log "logs: ${CLEANUP_LOGS_FOUND} candidate(s), ${CLEANUP_LOGS_DELETED} deleted" ;;
    uploads) log "chunk uploads: purge pass(es) finished" ;;
    state) log "state: ${CLEANUP_STATE_FOUND} candidate(s), ${CLEANUP_STATE_DELETED} removed" ;;
    junk) log "junk: ${CLEANUP_JUNK_FOUND} candidate(s), ${CLEANUP_JUNK_DELETED} deleted" ;;
    cache)
      if [[ "$CLEANUP_CACHE_EMPTY" -eq 1 ]]; then
        log "cache: nothing to do"
      else
        log "cache: ${CLEANUP_CACHE_FOUND} candidate(s), ${CLEANUP_CACHE_DELETED} deleted"
      fi
      ;;
    support) log "support: ${CLEANUP_SUPPORT_FOUND} candidate(s), ${CLEANUP_SUPPORT_DELETED} deleted" ;;
  esac
  return 0
}

cmd_cleanup() {
  local target="" flag="" opt="" any=0
  CLEANUP_HAD_ERROR=0
  CLEANUP_CACHE_EMPTY=0
  CLEANUP_KEEP=5
  for target in "${CLEANUP_TARGETS[@]}"; do
    printf -v "CLEANUP_${target^^}_FOUND" '%s' 0
    printf -v "CLEANUP_${target^^}_DELETED" '%s' 0
  done

  opt_begin "logs:b uploads:b state:b junk:b cache:b support:b keep:s apply:b" cleanup "" "$@"
  opt_guard cleanup
  for target in "${CLEANUP_TARGETS[@]}"; do
    opt="OPT_${target}"
    printf -v "CLEANUP_${target^^}" '%s' "${!opt:-0}"
    [[ "${!opt:-0}" -eq 0 ]] || any=1
  done
  CLEANUP_APPLY="${OPT_apply:-0}"
  if [[ -n "${OPT_keep_SET:-}" ]]; then
    opt_require_uint cleanup --keep "${OPT_keep:-}" 0 "" "--keep must be a non-negative integer"
    CLEANUP_KEEP=$((10#$OPT_keep))
  fi
  [[ -z "${OPT_keep_SET:-}" || "$CLEANUP_SUPPORT" -eq 1 ]] ||
    usage_error cleanup "--keep requires --support"
  [[ "$any" -eq 1 ]] ||
    usage_error cleanup "at least one of --logs, --uploads, --state, --junk, --cache or --support is required"

  # Run dependencies load after the help/usage exits, so
  # `sciebo cleanup --help` parses none of them: the state/junk walks go
  # through the manifest, and lock.sh loads before acquire_lock (so the
  # EXIT trap can release it).
  sciebo_require_module manifest manifest_each
  sciebo_require_module lock acquire_lock
  load_settings
  ensure_state_dirs
  acquire_lock

  if [[ "$CLEANUP_APPLY" -eq 1 ]]; then
    log "cleanup starting (apply)"
  else
    log "cleanup starting (dry run; pass --apply to delete)"
  fi
  for target in "${CLEANUP_TARGETS[@]}"; do
    flag="CLEANUP_${target^^}"
    [[ "${!flag}" -eq 0 ]] || "cleanup_do_${target}"
  done

  printf '\n'
  if [[ "$CLEANUP_APPLY" -eq 1 ]]; then
    log "cleanup finished (apply)"
  else
    log "cleanup finished (dry run; re-run with --apply to delete)"
  fi
  for target in "${CLEANUP_TARGETS[@]}"; do
    flag="CLEANUP_${target^^}"
    [[ "${!flag}" -eq 0 ]] || cleanup_summary_target "$target"
  done
  return "$CLEANUP_HAD_ERROR"
}
