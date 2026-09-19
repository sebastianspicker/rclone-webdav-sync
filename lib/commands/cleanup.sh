#!/bin/bash
# cleanup.sh command module - old logs and stale Nextcloud chunk uploads.

CLEANUP_LOGS=0
CLEANUP_UPLOADS=0
CLEANUP_APPLY=0
CLEANUP_HAD_ERROR=0
CLEANUP_LOGS_FOUND=0
CLEANUP_LOGS_DELETED=0

usage_cleanup() {
  cat <<'EOF'
Usage: sciebo cleanup (--logs | --uploads) [--apply]

Housekeeping for the rclone-sciebo tooling. Dry run by default: nothing
is deleted unless --apply is given. Refuses to run while the local sync
lock is held; runs on other devices cannot be detected, so chunk uploads
are only removed once older than CHUNK_CLEANUP_MIN_AGE.

Options:
  --logs      delete log files older than LOG_RETENTION_DAYS
  --uploads   delete stale chunk uploads under /remote.php/dav/uploads/
              older than CHUNK_CLEANUP_MIN_AGE, then remove the emptied
              transfer directories
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
  local label="$1" uploads_url="$2" user="$3" pass="$4" hint="remove"
  shift 4
  local out=""
  if [[ "$label" == "delete" ]]; then
    hint="purge"
  fi
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

cleanup_do_logs() {
  local log_file
  log "scanning ${LOG_DIR} for '*.log' older than ${LOG_RETENTION_DAYS} day(s)"
  while IFS= read -r log_file; do
    [[ -n "$log_file" ]] || continue
    CLEANUP_LOGS_FOUND=$((CLEANUP_LOGS_FOUND + 1))
    if [[ "$CLEANUP_APPLY" -eq 0 ]]; then
      log "would delete ${log_file}"
    elif rm -f "$log_file"; then
      CLEANUP_LOGS_DELETED=$((CLEANUP_LOGS_DELETED + 1))
      log "deleted ${log_file}"
    else
      err "could not delete ${log_file}"
      CLEANUP_HAD_ERROR=1
    fi
  done < <(find "$LOG_DIR" -type f -name '*.log' -mtime "+${LOG_RETENTION_DAYS}" 2>/dev/null)
  [[ "$CLEANUP_LOGS_FOUND" -gt 0 ]] || log "no log files older than ${LOG_RETENTION_DAYS} day(s)"
}

cleanup_do_uploads() {
  local config_dump url user pass uploads_url
  config_dump="$(remote_config_dump)"
  url="$(config_dump_value "$RCLONE_REMOTE" url "$config_dump")"
  user="$(config_dump_value "$RCLONE_REMOTE" user "$config_dump")"
  pass="$(config_dump_value "$RCLONE_REMOTE" pass "$config_dump")"
  [[ -n "$url" && -n "$user" && -n "$pass" ]] ||
    die "remote '${RCLONE_REMOTE}:' is not fully configured (url/user/pass missing); run '${CLI_NAME} setup' first"
  case "$url" in
    *"/dav/files/"*) ;;
    *) die "remote url '${url}' lacks /dav/files/; re-run '${CLI_NAME} setup'" ;;
  esac
  uploads_url="$(printf '%s' "$url" | sed 's|/files/|/uploads/|')"
  [[ "$uploads_url" != "$url" ]] || die "could not derive chunk uploads URL from '${url}'"

  log "purging chunk uploads older than ${CHUNK_CLEANUP_MIN_AGE} at ${uploads_url}"
  cleanup_run_chunk_op delete "$uploads_url" "$user" "$pass" delete ":webdav:" --min-age "$CHUNK_CLEANUP_MIN_AGE"
  cleanup_run_chunk_op rmdirs "$uploads_url" "$user" "$pass" rmdirs ":webdav:" --leave-root
}

cmd_cleanup() {
  CLEANUP_HAD_ERROR=0
  CLEANUP_LOGS_FOUND=0
  CLEANUP_LOGS_DELETED=0

  opt_reset logs uploads apply
  opt_parse "logs:b uploads:b apply:b" cleanup "" "$@"
  if [[ "$OPT_HELP" -eq 1 ]]; then
    usage_cleanup
    exit 0
  fi
  [[ -z "$(trim "$OPT_EXTRA")" ]] || usage_error cleanup "unknown option: $(trim "$OPT_EXTRA")"
  CLEANUP_LOGS="${OPT_logs:-0}"
  CLEANUP_UPLOADS="${OPT_uploads:-0}"
  CLEANUP_APPLY="${OPT_apply:-0}"
  [[ "$CLEANUP_LOGS" -eq 1 || "$CLEANUP_UPLOADS" -eq 1 ]] ||
    usage_error cleanup "at least one of --logs or --uploads is required"

  load_settings
  ensure_state_dirs
  acquire_lock

  if [[ "$CLEANUP_APPLY" -eq 1 ]]; then
    log "cleanup starting (apply)"
  else
    log "cleanup starting (dry run; pass --apply to delete)"
  fi
  [[ "$CLEANUP_LOGS" -eq 0 ]] || cleanup_do_logs
  [[ "$CLEANUP_UPLOADS" -eq 0 ]] || cleanup_do_uploads

  printf '\n'
  if [[ "$CLEANUP_APPLY" -eq 1 ]]; then
    log "cleanup finished (apply)"
  else
    log "cleanup finished (dry run; re-run with --apply to delete)"
  fi
  [[ "$CLEANUP_LOGS" -eq 0 ]] || log "logs: ${CLEANUP_LOGS_FOUND} candidate(s), ${CLEANUP_LOGS_DELETED} deleted"
  [[ "$CLEANUP_UPLOADS" -eq 0 ]] || log "chunk uploads: purge pass(es) finished"
  return "$CLEANUP_HAD_ERROR"
}
