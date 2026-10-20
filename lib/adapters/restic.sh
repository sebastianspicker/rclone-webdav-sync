#!/bin/bash
# restic.sh - restic discovery, repository credentials, and execution.
# Sourced by bin/sciebo after rclone.sh; functions that build the child
# environment require load_settings to have run first (RESTIC_BIN, RCLONE_*,
# BACKUP_*).
#
# Process model: restic never talks to the server itself. It spawns
# `rclone serve restic --stdio` (restic's rclone backend, -o rclone.program /
# -o rclone.args) and speaks its REST protocol over that child's stdio, so the
# repository inherits every rclone setting this tool manages. Those settings
# cannot be passed as rclone flags (restic builds the rclone argv), so
# restic_env_into hands them over as RCLONE_* environment variables, the twins
# of rclone_cmd's flags (_rclone_global_env_into, _rclone_proxy_env_into) plus
# the Keychain app password under RCLONE_CONFIG_<REMOTE>_PASS. The repository
# password travels as RESTIC_PASSWORD. Secrets live only in the child's
# environment, never in argv (restic_args_into carries nothing secret).
#
# Shared global owned by this module: RESTIC_BWLIMIT, an rclone --bwlimit
# value (empty = unlimited). The command layer sets it from bw_effective_limit
# before calling restic_cmd; the adapter cannot call the state layer itself.
# RESTIC_STRIP_PROXY is the module's out-flag from restic_env_into (true when
# the child must not inherit proxy variables).

RESTIC_BIN_CACHE=""
RESTIC_VERSION_CACHE=""
RESTIC_BWLIMIT=""
RESTIC_STRIP_PROXY=false
RESTIC_CAPTURE_OUT=""
RESTIC_CAPTURE_ERR=""

# restic_bin - print the restic binary: RESTIC_BIN when set and executable,
# else restic on PATH, then the usual Homebrew/system locations. rc 1 with
# empty output when none is found. Successes are cached in RESTIC_BIN_CACHE.
restic_bin() {
  local candidate="" from_path=""
  if [[ -n "$RESTIC_BIN_CACHE" ]]; then
    printf '%s' "$RESTIC_BIN_CACHE"
    return 0
  fi
  from_path=${ command -v restic 2>/dev/null || true;}
  for candidate in "${RESTIC_BIN:-}" "$from_path" /opt/homebrew/bin/restic /usr/local/bin/restic; do
    [[ -n "$candidate" && -x "$candidate" ]] || continue
    RESTIC_BIN_CACHE="$candidate"
    printf '%s' "$candidate"
    return 0
  done
  return 1
}

# restic_available - true when restic_bin finds a binary.
restic_available() {
  local bin=""
  bin=${ restic_bin;} || return 1
  [[ -n "$bin" ]]
}

# restic_version - print MAJOR.MINOR.PATCH from the first line of
# `restic version` ("restic 0.19.1 compiled with ..."); empty when restic is
# missing, fails, or prints something unparseable. Successes are cached.
restic_version() {
  if [[ -n "$RESTIC_VERSION_CACHE" ]]; then
    printf '%s' "$RESTIC_VERSION_CACHE"
    return 0
  fi
  local bin="" out="" line="" version=""
  bin=${ restic_bin;} || return 0
  out="$("$bin" version 2>/dev/null || true)"
  line="${out%%$'\n'*}"
  version="${line#restic }"
  version="${version%% *}"
  # Accept a suffix such as 0.18.0-dev; keep only MAJOR.MINOR.PATCH.
  if [[ "$version" =~ ^([0-9]+\.[0-9]+\.[0-9]+) ]]; then
    version="${BASH_REMATCH[1]}"
    RESTIC_VERSION_CACHE="$version"
    printf '%s' "$version"
  fi
  return 0
}

# restic_version_at_least MAJOR MINOR - true (0) when the installed restic is
# at least MAJOR.MINOR; false (1) when older or unreadable.
restic_version_at_least() {
  local want_major="${1:-}" want_minor="${2:-}" version="" major="" minor=""
  case "$want_major" in '' | *[!0-9]*) return 1 ;; esac
  case "$want_minor" in '' | *[!0-9]*) return 1 ;; esac
  version=${ restic_version;}
  [[ -n "$version" ]] || return 1
  major="${version%%.*}"
  minor="${version#*.}"
  minor="${minor%%.*}"
  if [[ "$major" -gt "$want_major" ]]; then return 0; fi
  if [[ "$major" -eq "$want_major" && "$minor" -ge "$want_minor" ]]; then return 0; fi
  return 1
}

# restic_require - die unless restic is installed and at least
# RESTIC_MIN_VERSION (MAJOR.MINOR, default 0.17).
restic_require() {
  local min="${RESTIC_MIN_VERSION:-0.17}" version=""
  local hint="distro packages are often older; use 'restic self-update' or Homebrew (https://restic.readthedocs.io/en/stable/020_installation.html)"
  restic_available || die "restic not found in PATH, /opt/homebrew/bin, or /usr/local/bin; ${hint}"
  version=${ restic_version;}
  [[ -n "$version" ]] || die "cannot read the restic version; ${hint}"
  local want_minor="${min#*.}"
  want_minor="${want_minor%%.*}"
  restic_version_at_least "${min%%.*}" "$want_minor" ||
    die "restic ${version} is older than the required ${min}; ${hint}"
}

# restic_repository - print the restic repository spec (rclone backend).
restic_repository() {
  printf '%s' "${BACKUP_REPOSITORY:-rclone:${RCLONE_REMOTE:-}:${BACKUP_REMOTE_PATH:-}}"
}

# restic_password - print the repository password: from the Keychain item
# "restic" in Keychain mode, else the first line of BACKUP_PASSWORD_FILE.
# rc 1 with empty output when none is stored; dies when the file exists but is
# unsafe (not a regular file, a symlink, not owned by us, or looser than 600).
restic_password() {
  local file="${BACKUP_PASSWORD_FILE:-}" mode="" line=""
  if keychain_enabled; then
    keychain_lookup_item restic
    return
  fi
  [[ -n "$file" ]] || return 1
  if [[ -L "$file" ]]; then
    die "password file ${file} is a symlink; replace it with a regular file (chmod 600)"
  fi
  [[ -e "$file" ]] || return 1
  [[ -f "$file" ]] || die "password file ${file} is not a regular file"
  [[ -O "$file" ]] || die "password file ${file} is not owned by you"
  mode=${ file_mode "$file";}
  case "$mode" in
    600 | 400) ;;
    *) die "password file ${file} has mode ${mode:-unknown}; fix it with: chmod 600 '${file}'" ;;
  esac
  IFS= read -r line <"$file" || true
  [[ -n "$line" ]] || return 1
  printf '%s' "$line"
}

# restic_password_store SECRET - store the repository password: Keychain item
# "restic" in Keychain mode, else BACKUP_PASSWORD_FILE written atomically at
# mode 600.
restic_password_store() {
  if keychain_enabled; then
    keychain_store_item restic "$1"
    return
  fi
  [[ -n "${BACKUP_PASSWORD_FILE:-}" ]] || die "BACKUP_PASSWORD_FILE is not set"
  atomic_write "$BACKUP_PASSWORD_FILE" 600 <<<"$1"
}

# restic_password_delete - remove the stored repository password (the
# Keychain item, or the single password file). rc 0 when already absent.
restic_password_delete() {
  if keychain_enabled; then
    keychain_delete_item restic || true
    return 0
  fi
  [[ -n "${BACKUP_PASSWORD_FILE:-}" ]] || return 0
  rm -f -- "$BACKUP_PASSWORD_FILE"
}

# restic_password_generate - print a fresh random repository password (32
# random bytes, base64, no padding or newline); dies when /dev/urandom is
# unreadable.
restic_password_generate() {
  local pw=""
  [[ -r /dev/urandom ]] || die "cannot read /dev/urandom to generate a password"
  pw="$(head -c 32 /dev/urandom | base64 | tr -d '\n=')"
  [[ -n "$pw" ]] || die "cannot generate a password"
  printf '%s' "$pw"
}

# restic_env_into ASSOC_NAME - fill the associative array named ASSOC_NAME
# with the environment restic and its rclone child need (see the header).
# Sets RESTIC_STRIP_PROXY for the caller. Dies when no repository password is
# stored.
# shellcheck disable=SC2034  # env_ref is filled through a nameref
restic_env_into() {
  local -n env_ref="$1"
  local password="" pass_name="" pass_value=""
  password=${ restic_password;} || password=""
  [[ -n "$password" ]] || die "no repository password stored; run 'sciebo backup init'"
  env_ref[RESTIC_REPOSITORY]=${ restic_repository;}
  env_ref[RESTIC_PASSWORD]="$password"
  env_ref[RESTIC_CACHE_DIR]="${BACKUP_CACHE_DIR:-}"
  env_ref[RESTIC_COMPRESSION]="${BACKUP_COMPRESSION:-}"
  env_ref[RESTIC_PACK_SIZE]="${BACKUP_PACK_SIZE:-}"
  env_ref[RCLONE_CONFIG]="${RCLONE_CONFIG:-}"
  if pass_value=${ rclone_config_pass_value;}; then
    pass_name=${ rclone_config_pass_env_name;}
    # shellcheck disable=SC2004  # a key name, not arithmetic
    env_ref[$pass_name]="$pass_value"
  fi
  [[ -z "${BACKUP_CHUNK_SIZE:-}" ]] || env_ref[RCLONE_WEBDAV_NEXTCLOUD_CHUNK_SIZE]="$BACKUP_CHUNK_SIZE"
  [[ -z "$RESTIC_BWLIMIT" ]] || env_ref[RCLONE_BWLIMIT]="$RESTIC_BWLIMIT"
  if [[ "${TPSLIMIT:-}" =~ ^[0-9.]+$ && "$TPSLIMIT" =~ [1-9] ]]; then
    env_ref[RCLONE_TPSLIMIT]="$TPSLIMIT"
  fi
  _rclone_global_env_into "$1"
  _rclone_proxy_env_into "$1" RESTIC_STRIP_PROXY
}

# restic_args_into ARRAY_NAME - append the restic global options that wire in
# the rclone backend and the cache directory. Nothing secret.
restic_args_into() {
  local -n args_ref="$1"
  args_ref+=(-o "rclone.program=${RCLONE_BIN:-rclone}")
  args_ref+=(-o "rclone.args=serve restic --stdio --b2-hard-delete")
  args_ref+=(-o "rclone.connections=${BACKUP_CONNECTIONS:-5}")
  args_ref+=(--cache-dir "${BACKUP_CACHE_DIR:-}")
}

# restic_cmd ARGS... - run restic with the global options and the child
# environment from restic_env_into, in a subshell that execs restic so the
# secrets never reach a process list. A variable name bash cannot export
# (RCLONE_CONFIG_MY-REMOTE_PASS) is handed to env(1) for the exec instead, as
# rclone_cmd does. Returns restic's status.
restic_cmd() {
  local bin="" key="" LC_ALL=C
  local -a args=() env_args=()
  local -A child_env=()
  bin=${ restic_bin;} || die "restic not found; run 'sciebo doctor'"
  restic_env_into child_env
  restic_args_into args
  for key in "${!child_env[@]}"; do
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || env_args+=("$key=${child_env[$key]}")
  done
  (
    if [[ "$RESTIC_STRIP_PROXY" == true ]]; then
      unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy
    fi
    # restic prefers a password file/command and a repository file over the
    # plain variables; an inherited one would silently select another key.
    unset RESTIC_PASSWORD_FILE RESTIC_PASSWORD_COMMAND RESTIC_REPOSITORY_FILE \
      RESTIC_FROM_PASSWORD RESTIC_FROM_PASSWORD_FILE RESTIC_FROM_PASSWORD_COMMAND \
      RESTIC_FROM_REPOSITORY RESTIC_FROM_REPOSITORY_FILE
    for key in "${!child_env[@]}"; do
      [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
      export "$key=${child_env[$key]}"
    done
    if [[ ${#env_args[@]} -gt 0 ]]; then
      exec env "${env_args[@]}" "$bin" "${args[@]}" "$@"
    fi
    exec "$bin" "${args[@]}" "$@"
  )
}

# restic_capture LABEL ARGS... - run restic_cmd ARGS with stdout captured in
# RESTIC_CAPTURE_OUT and stderr in RESTIC_CAPTURE_ERR (both registered for
# exit cleanup). Returns restic's status; discard both files with
# temp_discard when done.
restic_capture() {
  local label="${1:-restic}"
  shift
  temp_mktemp_into RESTIC_CAPTURE_OUT "${TMPDIR:-/tmp}/sciebo-${label}-out.XXXXXX" ||
    die "cannot create temp file"
  temp_mktemp_into RESTIC_CAPTURE_ERR "${TMPDIR:-/tmp}/sciebo-${label}-err.XXXXXX" || {
    temp_discard "$RESTIC_CAPTURE_OUT"
    RESTIC_CAPTURE_OUT=""
    die "cannot create temp file"
  }
  local rc=0
  if restic_cmd "$@" >"$RESTIC_CAPTURE_OUT" 2>"$RESTIC_CAPTURE_ERR"; then
    rc=0
  else
    rc=$?
  fi
  return "$rc"
}

# restic_rc_status RC - classify a restic exit status: ok (0), warn (3, the
# snapshot exists but some source files were unreadable), failed (else).
restic_rc_status() {
  case "$1" in
    0) printf 'ok' ;;
    3) printf 'warn' ;;
    *) printf 'failed' ;;
  esac
}

# restic_rc_describe RC - one line describing a restic exit status.
restic_rc_describe() {
  case "$1" in
    0) printf 'completed' ;;
    1) printf 'restic reported a fatal error' ;;
    2) printf 'restic runtime error' ;;
    3) printf 'some source files could not be read (snapshot created)' ;;
    10) printf "repository does not exist; run 'sciebo backup init'" ;;
    11) printf "repository is locked by another process; see 'sciebo backup unlock'" ;;
    12) printf 'wrong repository password' ;;
    130) printf 'interrupted' ;;
    *) printf 'restic exited with status %s' "$1" ;;
  esac
}

# restic_stderr_hint TEXT - scan captured restic stderr for server conditions
# worth naming (HTTP 507 quota exhaustion, HTTP 423 locked resource); prints
# one line, or nothing.
restic_stderr_hint() {
  case "$1" in
    *" 507 "* | *"507 Insufficient"* | *"status 507"* | *"Insufficient Storage"* | *"insufficient storage"*)
      printf 'the server reports insufficient storage (quota exhausted)'
      ;;
    *"423 Locked"* | *" 423 "* | *"status 423"*)
      printf 'the server reports a locked resource (HTTP 423); retry later'
      ;;
  esac
}
