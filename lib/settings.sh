#!/bin/bash
# settings.sh - layered settings, path validation, and state layout.
#
# Precedence (low to high): defaults in config/settings.env < environment
# variables < plain assignments in config/settings.local.env. settings.env
# assigns with `: "${VAR:=default}"`, so exported values win; the local file
# is sourced last, so plain assignments win over both.
#
# Every path below (and SETTINGS_FILE/SETTINGS_LOCAL_FILE/ENV_FILE) can be
# overridden from the environment; the integration tests rely on that for
# isolation.

: "${SETTINGS_FILE:=${CONFIG_DIR}/settings.env}"
: "${SETTINGS_LOCAL_FILE:=${CONFIG_DIR}/settings.local.env}"
: "${ENV_FILE:=${PROJECT_DIR}/.env}"

# require_setting KEY... - fail with a clear message when settings.env is
# missing a key (defaults live only there; see README).
require_setting() {
  local key
  for key in "$@"; do
    [[ -n "${!key+x}" ]] || die "missing setting '${key}' in ${SETTINGS_FILE}"
  done
}

# load_settings [--no-rclone] - source settings and derive every path.
# --no-rclone skips binary discovery for commands that only inspect
# configuration (list, folders list, mount status, schedule status).
load_settings() {
  [[ -f "$SETTINGS_FILE" ]] || die "Missing settings file: ${SETTINGS_FILE}"
  # shellcheck disable=SC1090  # path is documented and overridable
  source "$SETTINGS_FILE"
  if [[ -f "$SETTINGS_LOCAL_FILE" ]]; then
    # shellcheck disable=SC1090  # path is documented and overridable
    source "$SETTINGS_LOCAL_FILE"
  fi

  require_setting RCLONE_REMOTE REMOTE_BASE RCLONE_CONFIG \
    TRANSFERS CHECKERS TPSLIMIT RETRIES LOW_LEVEL_RETRIES \
    TIMEOUT CONTIMEOUT STATS LOG_LEVEL \
    BISYNC_CONFLICT_RESOLVE LOG_RETENTION_DAYS CHUNK_CLEANUP_MIN_AGE \
    LAUNCHD_LABEL SCHEDULE_HOUR SCHEDULE_MINUTE \
    FOLDERS_SCAN_DEPTH DEFAULT_PAIR_MODE FOLDERS_LOCAL_ROOT \
    MOUNT_ROOT MOUNT_CACHE_MAX_SIZE MOUNT_EXTRA_FLAGS

  REMOTE_BASE="${REMOTE_BASE%/}"
  [[ -n "$REMOTE_BASE" ]] || die "REMOTE_BASE must not be empty (see ${SETTINGS_FILE})"
  case "$REMOTE_BASE" in
    /* | *..*)
      die "REMOTE_BASE '${REMOTE_BASE}' must be a relative path without '..'"
      ;;
  esac

  # Configuration and state layout; every path stays environment-
  # overridable for isolated test runs.
  : "${MANIFEST_FILE:=${CONFIG_DIR}/sources.conf}"
  : "${FOLDERS_FILE:=${CONFIG_DIR}/folders.conf}"
  : "${MANIFEST_GENERATED_FILE:=${CONFIG_DIR}/sources.generated.conf}"
  : "${ROOTS_FILE:=${CONFIG_DIR}/roots.conf}"
  : "${FILTER_DIR:=${CONFIG_DIR}/filters}"
  : "${STATE_DIR:=${PROJECT_DIR}/state}"
  LOG_DIR="${LOG_DIR:-${STATE_DIR}/logs}"
  LOCK_DIR="${LOCK_DIR:-${STATE_DIR}/locks}"
  BISYNC_DIR="${BISYNC_DIR:-${STATE_DIR}/bisync}"
  MOUNTS_DIR="${MOUNTS_DIR:-${STATE_DIR}/mounts}"
  MOUNT_CACHE_DIR="${MOUNT_CACHE_DIR:-${STATE_DIR}/mount-cache}"

  if [[ "${1:-}" == "--no-rclone" ]]; then RCLONE_BIN="${RCLONE_BIN:-rclone}"; else RCLONE_BIN="$(find_rclone)"; fi
  REMOTE_PREFIX="${RCLONE_REMOTE}:${REMOTE_BASE}"
}

ensure_state_dirs() { mkdir -p "$LOG_DIR" "$LOCK_DIR" "$BISYNC_DIR"; }

# bisync_initialized NAME - true when the bisync workdir holds real state.
# Dry runs leave only *-dry files, which must not count as initialization.
bisync_initialized() {
  local dir="${BISYNC_DIR}/$1" file
  [[ -d "$dir" ]] || return 1
  while IFS= read -r file; do
    [[ "$file" == *-dry ]] || return 0
  done < <(ls -A "$dir" 2>/dev/null || true)
  return 1
}
