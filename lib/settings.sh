#!/bin/bash
# settings.sh - layered settings, path validation, and state layout.
#
# Precedence (low to high): defaults in config/settings.env < environment
# variables < plain assignments in config/settings.local.env. settings.env
# assigns with `: "${VAR:=default}"`, so exported values win; the local file
# is sourced last, so plain assignments win over both.
#
# Sourcing this file only defines functions and derives the configuration
# base paths below; no settings file is read and no other module is touched
# until load_settings runs (its first step, _load_settings_files, takes the
# _sciebo_env_snapshot). ensure_state_dirs pulls in the lazy migrate module
# when it runs.
#
# Every path below (and SETTINGS_FILE/SETTINGS_LOCAL_FILE/ENV_FILE) can be
# overridden from the environment; the integration tests rely on that for
# isolation.

# --confdir redirects the configuration base (nextcloudcmd's -confdir): the
# settings, manifests, filters, and default state live there. Only the
# settings file falls back to the project copy when the confdir has none.
if [[ -n "${SCIEBO_CONFDIR:-}" ]]; then
  _SCIEBO_CONF_BASE="${SCIEBO_CONFDIR%/}"
  _SCIEBO_CONF_STATE="${_SCIEBO_CONF_BASE}/state"
else
  _SCIEBO_CONF_BASE="${CONFIG_DIR}"
  _SCIEBO_CONF_STATE="${PROJECT_DIR}/state"
fi

: "${SETTINGS_FILE:=${_SCIEBO_CONF_BASE}/settings.env}"
: "${SETTINGS_LOCAL_FILE:=${_SCIEBO_CONF_BASE}/settings.local.env}"
: "${ENV_FILE:=${PROJECT_DIR}/.env}"
# Where named profiles keep their config and state; overridable so tests
# never touch the real config/profiles tree.
: "${PROFILES_DIR:=${_SCIEBO_CONF_BASE}/profiles}"
: "${PROFILES_STATE_DIR:=${_SCIEBO_CONF_STATE}/profiles}"

# Active profile ("" or "default" is the project-wide layout). The value
# comes from --profile or SCIEBO_PROFILE and is validated by load_settings.
: "${SCIEBO_PROFILE:=}"
PROFILE_DIR=""
SETTINGS_PROFILE_FILE=""
SETTINGS_PROFILE_LOCAL_FILE=""
DEFAULT_KEYCHAIN_SERVICE="rclone-sciebo"

# validate_profile_name NAME - profiles name a directory under
# config/profiles/ and state/profiles/; keep the character set tight.
validate_profile_name() {
  local name="$1"
  [[ -n "$name" ]] || die "profile name must not be empty"
  case "$name" in
    . | .. | *[!A-Za-z0-9._-]*)
      die "invalid profile name '${ printable "$name";}': use letters, digits, dot, dash, or underscore"
      ;;
  esac
  [[ "$name" != "default" ]] || die "'default' is reserved; omit --profile for the default profile"
}

# require_setting KEY... - fail with a clear message when settings.env is
# missing a key (defaults live only there; see README).
require_setting() {
  local key
  for key in "$@"; do
    [[ -n "${!key+x}" ]] || die "missing setting '${key}' in ${SETTINGS_FILE}"
  done
}

# validate_setting_one_of KEY VALUE... - die unless the setting's value is
# exactly one of the allowed words.
validate_setting_one_of() {
  local key="$1" value="${!1}" allowed list=""
  shift
  for allowed in "$@"; do
    if [[ "$value" == "$allowed" ]]; then
      return 0
    fi
    list="${list:+${list}, }${allowed}"
  done
  die "setting '${key}' in ${SETTINGS_FILE} must be one of ${list} (got '${value}')"
}

# _validate_keys_nonempty KEY... / _validate_keys_uint KEY... /
# _validate_keys_bool KEY... - shared shape checks for validate_settings.
# Each reproduces the exact message the inline loops used.
_validate_keys_nonempty() {
  local key
  for key in "$@"; do
    [[ -n "${!key}" ]] || die "setting '${key}' in ${SETTINGS_FILE} must not be empty"
  done
}

_validate_keys_uint() {
  local key
  for key in "$@"; do
    case "${!key}" in
      '' | *[!0-9]*)
        die "setting '${key}' in ${SETTINGS_FILE} must be a non-negative integer (got '${!key}')"
        ;;
    esac
  done
}

# _validate_keys_percent KEY... - each key must be an integer percentage from
# 0 to 100 (0 disables the check).
_validate_keys_percent() {
  local key value
  for key in "$@"; do
    value="${!key}"
    case "$value" in
      '' | *[!0-9]*)
        die "setting '${key}' in ${SETTINGS_FILE} must be an integer 0-100 (got '${value}')"
        ;;
    esac
    [[ "$((10#$value))" -le 100 ]] ||
      die "setting '${key}' in ${SETTINGS_FILE} must be an integer 0-100 (got '${value}')"
  done
}

_validate_keys_bool() {
  local key
  for key in "$@"; do
    case "${!key}" in
      0 | 1) ;;
      *) die "setting '${key}' in ${SETTINGS_FILE} must be 0 or 1 (got '${!key}')" ;;
    esac
  done
}

# _validate_keys_readable KEY... - when set, each key must name an existing,
# readable regular file (CLIENT_CERT, CLIENT_KEY, CA_CERT). Unset/empty keys
# are fine; doctor sets SCIEBO_SKIP_FILE_CHECKS=1 so it can report a missing
# file as a FAIL instead of dying here.
_validate_keys_readable() {
  local key path
  for key in "$@"; do
    path="${!key}"
    [[ -n "$path" ]] || continue
    [[ -f "$path" && -r "$path" ]] && continue
    [[ "${SCIEBO_SKIP_FILE_CHECKS:-0}" == "1" ]] && continue
    if [[ -e "$path" ]]; then
      die "setting '${key}' in ${SETTINGS_FILE} must point to a readable file (got '${path}')"
    fi
    die "setting '${key}' in ${SETTINGS_FILE} points to a file that does not exist (got '${path}')"
  done
}

# validate_settings - enforce value shapes after require_setting. Checks run
# before path derivation and rclone discovery, so a bad settings file fails
# fast. BW_LIMIT_UP/DOWN, CHUNK_SIZE, SCHEDULE_INTERVAL, SCHEDULE_WATCH_PATH,
# and MOUNT_EXTRA_FLAGS are presence-checked only: empty is meaningful there.
validate_settings() {
  _validate_keys_nonempty \
    RCLONE_REMOTE RCLONE_CONFIG TRANSFERS CHECKERS TPSLIMIT \
    RETRIES LOW_LEVEL_RETRIES TIMEOUT CONTIMEOUT STATS LOG_LEVEL \
    BISYNC_CONFLICT_RESOLVE BISYNC_CONFLICT_LOSER BISYNC_RESYNC_MODE \
    RCLONE_MIN_VERSION DEFAULT_PAIR_MODE FOLDERS_LOCAL_ROOT MOUNT_ROOT \
    MOUNT_CACHE_MAX_SIZE KEYCHAIN_SERVICE HTTP_TIMEOUT CONFLICT_PATTERN

  _validate_keys_uint \
    TRANSFERS CHECKERS RETRIES LOW_LEVEL_RETRIES \
    LOG_RETENTION_DAYS CAPABILITIES_MAX_AGE SCHEDULE_JITTER \
    HTTP_RETRIES HTTP_RETRY_DELAY HTTP_MAX_REDIRS BLACKLIST_MAX_FAILS HISTORY_MAX_ENTRIES \
    MAX_PARALLEL_SOURCES WATCH_INTERVAL WATCH_DEBOUNCE WATCH_REMOTE_INTERVAL \
    SERVER_EXCLUDE_MAX_AGE BLACKLIST_TIME_MIN BLACKLIST_TIME_MAX \
    SEARCH_LIMIT RECENT_LIMIT AVATAR_SIZE COMMENTS_LIMIT FILE_ACTIVITY_LIMIT \
    NOTIFY_WATCH_INTERVAL DELETE_FILES_THRESHOLD

  _validate_keys_percent QUOTA_WARN_PERCENT

  case "$MAX_DELETE" in
    -1) ;;
    '' | *[!0-9]*)
      die "setting 'MAX_DELETE' in ${SETTINGS_FILE} must be an integer >= -1 (got '${MAX_DELETE}')"
      ;;
  esac

  _validate_keys_bool \
    BISYNC_RESILIENT BISYNC_RECOVER CREATE_EMPTY_SRC_DIRS \
    TRACK_RENAMES KEYCHAIN NOTIFY NOTIFY_SUCCESS MOUNT_FILTERS MOUNT_NO_SYNC \
    CONFLICT_UPLOAD ASK_DOWNLOAD_SIZE TLS_INSECURE SKIP_HIDDEN \
    BLACKLIST_ENABLED SCHEDULE_AT_LOGIN PROXY_DIRECT FILTER_SERVER_SYNC \
    HTTP2_ENABLED ASK_DELETE MOVE_TO_TRASH CHECKSUM HTTP_FOLLOW_REDIRECTS

  # Optional PEM files must exist and be readable when set; empty disables
  # them. CLIENT_KEY_PASSWORD and USER_AGENT are not paths.
  _validate_keys_readable CLIENT_CERT CLIENT_KEY CA_CERT

  validate_setting_one_of BISYNC_CONFLICT_RESOLVE none newer older larger smaller path1 path2
  validate_setting_one_of BISYNC_RESYNC_MODE none newer older larger smaller path1 path2
  validate_setting_one_of BISYNC_CONFLICT_LOSER num pathname delete
  validate_setting_one_of DEFAULT_PAIR_MODE sync pull bisync
  validate_setting_one_of WATCH_BACKEND auto fswatch inotify poll
  validate_setting_one_of METERED_POLICY allow ask skip
  validate_setting_one_of BLACKLIST_MODE count backoff
  validate_setting_one_of BIG_FOLDER_POLICY warn ask skip
  validate_setting_one_of BIG_FOLDER_EXISTING_POLICY warn skip allow
  validate_setting_one_of EXTERNAL_STORAGE_POLICY allow warn ask skip
  validate_setting_one_of SYMLINK_POLICY skip follow translate
  validate_setting_one_of INVALID_NAME_POLICY warn exclude allow
  validate_setting_one_of CASE_CLASH_POLICY warn exclude rename
  validate_setting_one_of E2EE_POLICY warn exclude allow
  validate_setting_one_of PROXY_TYPE system none http socks5

  REMOTE_BASE="${REMOTE_BASE%/}"
  [[ -n "$REMOTE_BASE" ]] || die "REMOTE_BASE must not be empty (see ${SETTINGS_FILE})"
  case "$REMOTE_BASE" in
    /* | *..*)
      die "REMOTE_BASE '${REMOTE_BASE}' must be a relative path without '..'"
      ;;
    *"|"* | *[[:cntrl:]]*)
      die "REMOTE_BASE '${ printable "$REMOTE_BASE";}' must not contain '|' or control bytes"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# nextcloudcmd / desktop-client environment compatibility
# ---------------------------------------------------------------------------

# _sciebo_env_snapshot - record which names were exported before settings.env
# assigns defaults, so an OWNCLOUD_* alias never overwrites a value the user
# set directly (in the environment or a local settings file).
_sciebo_env_snapshot() {
  local names=""
  # compgen -e is a builtin and the forkless capture-slurp keeps its output
  # in this shell, so this avoids both the three-process export|sed|tr
  # pipeline and the process-substitution subshell it ran under before.
  names=${ compgen -e;}
  SCIEBO_EXPORTED=" ${names//$'\n'/ } "
}
_env_exported() {
  case "${SCIEBO_EXPORTED:- }" in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# _alias_env OURS THEIRS MODE - when THEIRS is set and OURS was not exported
# by the user, copy/convert THEIRS into OURS. MODE: plain, seconds, bool.
_alias_env() {
  local ours="$1" theirs="$2" mode="$3" value=""
  _env_exported "$ours" && return 0
  value="${!theirs:-}"
  [[ -n "$value" ]] || return 0
  case "$mode" in
    seconds)
      case "$value" in *[!0-9]*) return 0 ;; esac
      printf -v "$ours" '%ss' "$value"
      ;;
    bool)
      case "$value" in
        1 | true | yes | on) printf -v "$ours" '1' ;;
        0 | false | no | off) printf -v "$ours" '0' ;;
      esac
      ;;
    *) printf -v "$ours" '%s' "$value" ;;
  esac
}

# _apply_nextcloud_env_aliases - map the OWNCLOUD_* variables of nextcloudcmd
# and the desktop client onto sciebo settings. Runs after settings.env and
# before settings.local.env/profile files, so precedence stays: exported
# setting > OWNCLOUD_* alias > shipped default, with local files on top.
_apply_nextcloud_env_aliases() {
  _alias_env CHUNK_SIZE OWNCLOUD_CHUNK_SIZE plain
  _alias_env TIMEOUT OWNCLOUD_TIMEOUT seconds
  _alias_env MAX_PARALLEL_SOURCES OWNCLOUD_MAX_PARALLEL plain
  _alias_env MIN_FREE_SPACE OWNCLOUD_CRITICAL_FREE_SPACE_BYTES plain
  _alias_env FREE_SPACE_DOWNLOAD OWNCLOUD_FREE_SPACE_BYTES plain
  _alias_env BLACKLIST_TIME_MIN OWNCLOUD_BLACKLIST_TIME_MIN plain
  _alias_env BLACKLIST_TIME_MAX OWNCLOUD_BLACKLIST_TIME_MAX plain
  _alias_env CONFLICT_UPLOAD OWNCLOUD_UPLOAD_CONFLICT_FILES bool
  _alias_env HTTP2_ENABLED OWNCLOUD_HTTP2_ENABLED bool
  _alias_env MIN_CHUNK_SIZE OWNCLOUD_MIN_CHUNK_SIZE plain
  _alias_env MAX_CHUNK_SIZE OWNCLOUD_MAX_CHUNK_SIZE plain
  _alias_env TARGET_CHUNK_UPLOAD_DURATION OWNCLOUD_TARGET_CHUNK_UPLOAD_DURATION plain
}

# _load_settings_files - snapshot the exported environment, then source the
# layered settings in precedence order: shipped defaults (with the --confdir
# fallback), the OWNCLOUD_* aliases, and the per-machine local file.
_load_settings_files() {
  _sciebo_env_snapshot
  local settings_file="$SETTINGS_FILE"
  if [[ ! -f "$settings_file" && -n "${SCIEBO_CONFDIR:-}" ]]; then
    # --confdir may hold only the per-machine files; the shipped defaults
    # stay the fallback.
    settings_file="${CONFIG_DIR}/settings.env"
  fi
  [[ -f "$settings_file" ]] || die "Missing settings file: ${SETTINGS_FILE}"
  # Settings files are executable shell: refuse one that is a symlink or not
  # owned by the user / group- or other-writable (safe_source_file warns).
  safe_source "$settings_file" ||
    die "refusing unsafe settings file '$(printable "$settings_file")': it must be a regular file owned by you and not group- or other-writable"
  _apply_nextcloud_env_aliases
  if [[ -f "$SETTINGS_LOCAL_FILE" ]]; then
    safe_source "$SETTINGS_LOCAL_FILE" ||
      die "refusing unsafe settings file '$(printable "$SETTINGS_LOCAL_FILE")': it must be a regular file owned by you and not group- or other-writable"
  fi
}

# _apply_profile_layer - a named profile layers its own defaults and
# overrides on top of the project-wide files. Profile assignments are plain
# (like settings.local.env), so they win over environment variables.
_apply_profile_layer() {
  local profile="${SCIEBO_PROFILE:-}"
  if [[ -n "$profile" && "$profile" != "default" ]]; then
    validate_profile_name "$profile"
    PROFILE_DIR="${PROFILE_DIR:-${PROFILES_DIR}/${profile}}"
    [[ -d "$PROFILE_DIR" ]] ||
      die "profile '${ printable "$profile";}' not found at ${PROFILE_DIR}; create it with '${CLI_NAME} account add ${profile}'"
    SETTINGS_PROFILE_FILE="${SETTINGS_PROFILE_FILE:-${PROFILE_DIR}/settings.env}"
    SETTINGS_PROFILE_LOCAL_FILE="${SETTINGS_PROFILE_LOCAL_FILE:-${PROFILE_DIR}/settings.local.env}"
    if [[ -f "$SETTINGS_PROFILE_FILE" ]]; then
      safe_source "$SETTINGS_PROFILE_FILE" ||
        die "refusing unsafe profile settings file '$(printable "$SETTINGS_PROFILE_FILE")': it must be a regular file owned by you and not group- or other-writable"
    fi
    if [[ -f "$SETTINGS_PROFILE_LOCAL_FILE" ]]; then
      safe_source "$SETTINGS_PROFILE_LOCAL_FILE" ||
        die "refusing unsafe profile settings file '$(printable "$SETTINGS_PROFILE_LOCAL_FILE")': it must be a regular file owned by you and not group- or other-writable"
    fi
  else
    SCIEBO_PROFILE=""
  fi
}

# _require_settings - fail fast on missing keys, then enforce value shapes.
_require_settings() {
  require_setting RCLONE_REMOTE REMOTE_BASE RCLONE_CONFIG \
    TRANSFERS CHECKERS TPSLIMIT RETRIES LOW_LEVEL_RETRIES \
    TIMEOUT CONTIMEOUT STATS LOG_LEVEL \
    BISYNC_CONFLICT_RESOLVE BISYNC_CONFLICT_LOSER BISYNC_CONFLICT_SUFFIX \
    BISYNC_RESILIENT BISYNC_RECOVER BISYNC_MAX_LOCK BISYNC_RESYNC_MODE \
    RCLONE_MIN_VERSION CREATE_EMPTY_SRC_DIRS TRACK_RENAMES MAX_DELETE \
    BW_LIMIT_UP BW_LIMIT_DOWN BW_SCHEDULE CHUNK_SIZE \
    KEYCHAIN KEYCHAIN_SERVICE CAPABILITIES_MAX_AGE \
    NOTIFY NOTIFY_SUCCESS \
    LOG_RETENTION_DAYS CHUNK_CLEANUP_MIN_AGE STATE_CLEANUP_MIN_AGE \
    LAUNCHD_LABEL SCHEDULE_HOUR SCHEDULE_MINUTE SCHEDULE_INTERVAL \
    SCHEDULE_JITTER SCHEDULE_WATCH_PATH SCHEDULE_AT_LOGIN SCHEDULE_PROFILES \
    FOLDERS_SCAN_DEPTH DEFAULT_PAIR_MODE FOLDERS_LOCAL_ROOT \
    MOUNT_ROOT MOUNT_CACHE_MAX_SIZE MOUNT_FILTERS MOUNT_NO_SYNC \
    MOUNT_EXTRA_FLAGS HTTP_TIMEOUT HTTP_RETRIES \
    HTTP_RETRY_DELAY HTTP_FOLLOW_REDIRECTS HTTP_MAX_REDIRS CONFLICT_UPLOAD \
    CONFLICT_PATTERN MAX_DOWNLOAD_SIZE ASK_DOWNLOAD_SIZE TLS_INSECURE \
    CLIENT_CERT CLIENT_KEY CLIENT_KEY_PASSWORD CA_CERT USER_AGENT \
    SKIP_HIDDEN BLACKLIST_ENABLED BLACKLIST_MAX_FAILS BLACKLIST_MODE \
    BLACKLIST_TIME_MIN BLACKLIST_TIME_MAX BACKUP_DIR \
    HISTORY_MAX_ENTRIES LOG_MAX_BYTES JUNK_CLEANUP_MIN_AGE \
    MAX_PARALLEL_SOURCES \
    WATCH_INTERVAL WATCH_DEBOUNCE WATCH_REMOTE_INTERVAL WATCH_BACKEND \
    METERED_POLICY METERED_SSIDS MIN_FREE_SPACE FREE_SPACE_DOWNLOAD \
    QUOTA_WARN_PERCENT \
    PROXY PROXY_DIRECT \
    FILTER_SERVER_SYNC SERVER_EXCLUDE_MAX_AGE BIG_FOLDER_SIZE \
    HTTP2_ENABLED CRYPT_REMOTE \
    SEARCH_LIMIT RECENT_LIMIT AVATAR_SIZE COMMENTS_LIMIT FILE_ACTIVITY_LIMIT \
    NOTIFY_APPS NOTIFY_TYPES NOTIFY_WATCH_INTERVAL \
    BIG_FOLDER_POLICY BIG_FOLDER_EXISTING_POLICY EXTERNAL_STORAGE_POLICY \
    DELETE_FILES_THRESHOLD ASK_DELETE MOVE_TO_TRASH LOCAL_TRASH_DIR \
    SYMLINK_POLICY INVALID_NAME_POLICY CASE_CLASH_POLICY E2EE_POLICY \
    CHECKSUM PROXY_TYPE MIN_CHUNK_SIZE MAX_CHUNK_SIZE \
    TARGET_CHUNK_UPLOAD_DURATION TARGET_UPLOAD_THROUGHPUT

  validate_settings
}

# _derive_settings_paths - configuration and state layout; every path stays
# environment-overridable for isolated test runs. A named profile keeps its
# configuration under config/profiles/<name>/ and its state under
# state/profiles/<name>/, so two accounts never share locks or workdirs.
_derive_settings_paths() {
  if [[ -n "${PROFILE_DIR:-}" ]]; then
    : "${MANIFEST_FILE:=${PROFILE_DIR}/sources.conf}"
    : "${FOLDERS_FILE:=${PROFILE_DIR}/folders.conf}"
    : "${MANIFEST_GENERATED_FILE:=${PROFILE_DIR}/sources.generated.conf}"
    : "${ROOTS_FILE:=${PROFILE_DIR}/roots.conf}"
    : "${FILTER_DIR:=${PROFILE_DIR}/filters}"
    : "${STATE_DIR:=${PROFILES_STATE_DIR}/${SCIEBO_PROFILE}}"
  else
    : "${MANIFEST_FILE:=${_SCIEBO_CONF_BASE}/sources.conf}"
    : "${FOLDERS_FILE:=${_SCIEBO_CONF_BASE}/folders.conf}"
    : "${MANIFEST_GENERATED_FILE:=${_SCIEBO_CONF_BASE}/sources.generated.conf}"
    : "${ROOTS_FILE:=${_SCIEBO_CONF_BASE}/roots.conf}"
    : "${FILTER_DIR:=${_SCIEBO_CONF_BASE}/filters}"
    : "${STATE_DIR:=${_SCIEBO_CONF_STATE}}"
  fi
  # A named profile gets its own Keychain service unless the user picked
  # an explicit one; two accounts then never overwrite each other.
  if [[ -n "${PROFILE_DIR:-}" && "$KEYCHAIN_SERVICE" == "$DEFAULT_KEYCHAIN_SERVICE" ]]; then
    KEYCHAIN_SERVICE="${DEFAULT_KEYCHAIN_SERVICE}/${SCIEBO_PROFILE}"
  fi
  # --log-dir overrides the per-run log location; --log-expire is read by
  # `cleanup --logs` when set.
  LOG_DIR="${LOG_DIR:-${STATE_DIR}/logs}"
  [[ -z "${SCIEBO_LOG_DIR:-}" ]] || LOG_DIR="$SCIEBO_LOG_DIR"
  LOG_EXPIRE_HOURS="${SCIEBO_LOG_EXPIRE_HOURS:-${LOG_EXPIRE_HOURS:-}}"
  LOCK_DIR="${LOCK_DIR:-${STATE_DIR}/locks}"
  BISYNC_DIR="${BISYNC_DIR:-${STATE_DIR}/bisync}"
  MOUNTS_DIR="${MOUNTS_DIR:-${STATE_DIR}/mounts}"
  MOUNT_CACHE_DIR="${MOUNT_CACHE_DIR:-${STATE_DIR}/mount-cache}"
  # Local trash for MOVE_TO_TRASH when no BACKUP_DIR is configured.
  [[ -n "${LOCAL_TRASH_DIR:-}" ]] || LOCAL_TRASH_DIR="${STATE_DIR}/trash"
  # Per-source last-run records, the pause marker, and the OCS capabilities
  # cache (parsed values plus the raw probe response).
  RUNSTATE_DIR="${RUNSTATE_DIR:-${STATE_DIR}/last}"
  PAUSE_FILE="${PAUSE_FILE:-${STATE_DIR}/paused}"
  CAPABILITIES_CACHE="${CAPABILITIES_CACHE:-${STATE_DIR}/capabilities.env}"
  CAPABILITIES_JSON="${CAPABILITIES_JSON:-${STATE_DIR}/capabilities.json}"
  # Remote file locks recorded by `sciebo lock`, and the seen-id caches for
  # `sciebo notifications` / `sciebo activity`.
  REMOTE_LOCKS_DIR="${REMOTE_LOCKS_DIR:-${STATE_DIR}/remote-locks}"
  NOTIFICATIONS_SEEN="${NOTIFICATIONS_SEEN:-${STATE_DIR}/notifications-seen}"
  ACTIVITY_SEEN="${ACTIVITY_SEEN:-${STATE_DIR}/activity-seen}"
  # Failure-blacklist records, per-source run history, and the state layout
  # version file used by migrations.
  BLACKLIST_DIR="${BLACKLIST_DIR:-${STATE_DIR}/blacklist}"
  HISTORY_DIR="${HISTORY_DIR:-${STATE_DIR}/history}"
  STATE_VERSION_FILE="${STATE_VERSION_FILE:-${STATE_DIR}/VERSION}"
  # watch runtime markers, the `limit` bandwidth marker, and the cached
  # server-side sync-exclude list plus the filter file generated from it.
  WATCH_DIR="${WATCH_DIR:-${STATE_DIR}/watch}"
  BW_LIMIT_FILE="${BW_LIMIT_FILE:-${STATE_DIR}/bwlimit}"
  SERVER_EXCLUDE_FILE="${SERVER_EXCLUDE_FILE:-${STATE_DIR}/sync-exclude.lst}"
  SERVER_EXCLUDE_FILTER="${SERVER_EXCLUDE_FILTER:-${FILTER_DIR}/server-exclude.txt}"
  # The crypt-wrapped remote used by `setup --crypt` defaults to a sibling
  # of the plain remote.
  [[ -n "${CRYPT_REMOTE:-}" ]] || CRYPT_REMOTE="${RCLONE_REMOTE}-crypt"
}

# _finalize_settings_rclone [--no-rclone] - discover the rclone binary (or
# trust PATH when --no-rclone skips discovery) and build the remote prefix.
_finalize_settings_rclone() {
  if [[ "${1:-}" == "--no-rclone" ]]; then RCLONE_BIN="${RCLONE_BIN:-rclone}"; else RCLONE_BIN="$(find_rclone)"; fi
  # shellcheck disable=SC2034  # read by the sync command module
  REMOTE_PREFIX="${RCLONE_REMOTE}:${REMOTE_BASE}"
}

# load_settings [--no-rclone] - source settings and derive every path.
# --no-rclone skips binary discovery for commands that only inspect
# configuration (list, folders list, mount status, schedule status).
load_settings() {
  _load_settings_files
  _apply_profile_layer
  _require_settings
  _derive_settings_paths
  _finalize_settings_rclone "$@"
}

ensure_state_dirs() {
  RUNSTATE_DIR="${RUNSTATE_DIR:-${STATE_DIR}/last}"
  mkdir -p "$LOG_DIR" "$LOCK_DIR" "$BISYNC_DIR" "$RUNSTATE_DIR"
  # migrate.sh loads lazily; require it here so state versioning still runs
  # on every state-writing command (it ran unconditionally when migrate.sh
  # was eager — the old `type` probe would have become a silent skip). The
  # STATE_VERSION_FILE guard keeps library-level callers that never ran
  # load_settings (unit tests, direct sourcing) on the old skip: without a
  # derived state layout state_migrations_run would die under `set -u`,
  # which is exactly what the old `type` probe avoided there.
  if [[ -n "${STATE_VERSION_FILE:-}" ]]; then
    sciebo_require_module migrate state_migrations_run
    state_migrations_run
  fi
}

# bisync_initialized_dir DIR - true when DIR holds real bisync state. Dry
# runs leave only *-dry files, which must not count as initialization.
bisync_initialized_dir() {
  local dir="$1" file
  [[ -d "$dir" ]] || return 1
  while IFS= read -r file; do
    [[ "$file" == *-dry ]] || return 0
  done < <(ls -A "$dir" 2>/dev/null || true)
  return 1
}

# bisync_initialized NAME - true when the named bisync workdir holds real
# state (BISYNC_DIR/NAME).
bisync_initialized() {
  bisync_initialized_dir "${BISYNC_DIR}/$1"
}
