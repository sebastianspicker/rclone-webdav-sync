#!/bin/bash
# config.sh command module - inspect the effective settings, where each value
# comes from, and whether the required local files are in place. Read-only
# except `config edit`, which creates and opens the local settings file.

CONFIG_CHECK_PASS=0
CONFIG_CHECK_WARN=0
CONFIG_CHECK_FAIL=0
# Newline-terminated "<status><TAB><name><TAB><detail>" records from
# config_check_add; printed as text or JSON by cmd_config_check.
CONFIG_CHECKS=""

usage_config() {
  usage_emit <<'EOF'
Usage: sciebo config <subcommand> [options]

Inspect the effective settings and where each value comes from. The layered
files (config/settings.env, the environment, config/settings.local.env, and
the active profile) are read without contacting a remote.

Subcommands:
  list [--json] [--all]  print every setting as KEY=VALUE<TAB>source.
                         Without --all, settings with an empty value are
                         hidden. Values whose key looks like a credential
                         (password, secret, token, apikey, proxy) print as
                         REDACTED.
  get KEY [--json]       print the effective value of one setting
  check [--json]         check the settings and required files as
                         PASS/WARN/FAIL lines; exits 1 on any FAIL
  edit                   create config/settings.local.env from the shipped
                         example when missing and open it in $EDITOR

Options:
  --json      print the result as JSON (list, get, check)
  --all       list: also show settings whose value is empty
  -h, --help  show this help
EOF
}

# Per-file cache of the extracted key sets. The value is the newline-separated
# LC_ALL=C-sorted list (no trailing newline) and the stamp is the file_stamp it
# was read at, so an external edit is picked up by the next
# _config_keys_refresh. config_file_defines reads the cache without forking,
# which matters because `config list` resolves the source of ~120 keys.
declare -A CONFIG_KEYS_CACHE=()
declare -A CONFIG_KEYS_STAMP=()
declare -A CONFIG_KEYS_LOADED=()

# _config_keys_extract FILE - the unique setting keys defined in FILE,
# preserving the original semantics exactly: the config/settings.env forms
# `: "${KEY:=default}"`, a bare `${KEY:=...}`, and plain (optionally
# `export`) `KEY=value` assignments. Comments and blank lines are ignored and
# keys stay uppercase-only, sorted -u under LC_ALL=C.
_config_keys_extract() {
  {
    sed -nE 's/^[[:space:]]*:?[[:space:]]*"?\$\{([A-Z][A-Z0-9_]*):=.*/\1/p' "$1"
    sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Z][A-Z0-9_]*)=.*/\2/p' "$1"
  } | LC_ALL=C sort -u
}

# _config_keys_refresh FILE - refill FILE's cached key set when its file_stamp
# moved and mark it loaded. Runs in the caller's shell; the one stat/extract
# per changed file replaces the per-key reparse. A missing or unreadable file
# caches as empty.
_config_keys_refresh() {
  local file="$1" stamp=""
  if [[ -z "$file" || ! -f "$file" || ! -r "$file" ]]; then
    CONFIG_KEYS_CACHE["$file"]=""
    CONFIG_KEYS_STAMP["$file"]=""
    CONFIG_KEYS_LOADED["$file"]=1
    return 0
  fi
  stamp="$(file_stamp "$file")"
  if [[ "${CONFIG_KEYS_LOADED["$file"]:-}" == "1" && "${CONFIG_KEYS_STAMP["$file"]:-}" == "$stamp" ]]; then
    return 0
  fi
  CONFIG_KEYS_CACHE["$file"]="$(_config_keys_extract "$file")"
  CONFIG_KEYS_STAMP["$file"]="$stamp"
  CONFIG_KEYS_LOADED["$file"]=1
  return 0
}

# _config_keys_ensure FILE - load FILE's cache for this process only when it
# has never been loaded. Unlike _config_keys_refresh it does not stat an
# already-loaded file, so per-key membership checks stay fork-free.
_config_keys_ensure() {
  local file="$1"
  [[ "${CONFIG_KEYS_LOADED["$file"]:-}" == "1" ]] && return 0
  _config_keys_refresh "$file"
}

# _config_keys_prime - refresh the cached key sets of every settings layer.
# Call after load_settings and before the per-key config list/get walks.
_config_keys_prime() {
  local file
  for file in "${SETTINGS_PROFILE_LOCAL_FILE:-}" "${SETTINGS_PROFILE_FILE:-}" \
    "${SETTINGS_LOCAL_FILE:-}" "${SETTINGS_FILE:-}"; do
    [[ -n "$file" ]] || continue
    _config_keys_refresh "$file"
  done
}

# config_file_defines FILE KEY - true when FILE assigns KEY. Pure-bash
# membership against the cached key set; it forks only to prime a file that
# was not primed by _config_keys_prime.
config_file_defines() {
  local file="$1" key="$2"
  [[ -n "$file" && -n "$key" ]] || return 1
  [[ -f "$file" && -r "$file" ]] || return 1
  _config_keys_ensure "$file"
  case $'\n'"${CONFIG_KEYS_CACHE["$file"]:-}"$'\n' in
    *$'\n'"$key"$'\n'*) return 0 ;;
  esac
  return 1
}

# config_env_exported NAME - true when NAME was exported before the settings
# layers were sourced (SCIEBO_EXPORTED); falls back to a live `export -p`
# when load_settings has not run.
config_env_exported() {
  local name="$1"
  if [[ "${SCIEBO_EXPORTED+set}" == "set" ]]; then
    case "$SCIEBO_EXPORTED" in
      *" ${name} "*) return 0 ;;
    esac
    return 1
  fi
  export -p 2>/dev/null | grep -qE "^declare -x ${name}="
}

# config_key_source_into VAR KEY - store profile, local, environment, or
# default in VAR, following the settings precedence, without a command
# substitution. config list/get resolve the source of every key, so this
# fork-free form is the only one (one printf -v per key, no subshell).
config_key_source_into() {
  local __var="$1" key="${2:-}"
  if [[ -n "${SETTINGS_PROFILE_LOCAL_FILE:-}" ]] && config_file_defines "$SETTINGS_PROFILE_LOCAL_FILE" "$key"; then
    printf -v "$__var" '%s' 'profile'
    return 0
  fi
  if [[ -n "${SETTINGS_PROFILE_FILE:-}" ]] && config_file_defines "$SETTINGS_PROFILE_FILE" "$key"; then
    printf -v "$__var" '%s' 'profile'
    return 0
  fi
  if [[ -n "${SETTINGS_LOCAL_FILE:-}" ]] && config_file_defines "$SETTINGS_LOCAL_FILE" "$key"; then
    printf -v "$__var" '%s' 'local'
    return 0
  fi
  if config_env_exported "$key"; then
    printf -v "$__var" '%s' 'environment'
    return 0
  fi
  printf -v "$__var" '%s' 'default'
  return 0
}

# config_is_secret KEY - true for credential-looking key names.
config_is_secret() {
  local lower="${1,,}"
  case "$lower" in
    *password* | *secret* | *token* | *passwd* | *apikey* | *api_key* | *proxy*) return 0 ;;
  esac
  return 1
}

# config_effective_value_into VAR KEY - store KEY's effective value in VAR;
# empty when unset. Pure bash, for the per-key config list/get walks.
config_effective_value_into() {
  local __var="$1" key="${2:-}"
  if [[ -n "$key" && -n "${!key+x}" ]]; then
    printf -v "$__var" '%s' "${!key}"
  else
    printf -v "$__var" '%s' ''
  fi
  return 0
}

# config_display_value_into VAR KEY VALUE - store VALUE's redacted, printable
# text representation in VAR. config list/get call this per key, so it avoids
# the per-row command substitution.
config_display_value_into() {
  local __var="$1" key="${2:-}" value="${3:-}"
  if config_is_secret "$key"; then
    printf -v "$__var" '%s' 'REDACTED'
    return 0
  fi
  printf -v "$__var" '%s' "${ printable "$value";}"
  return 0
}

cmd_config_list() {
  local all=false key="" value="" source="" display=""
  opt_begin "json:b all:b" config "" "$@"
  opt_guard config
  opt_into all all
  opt_json_mode
  load_settings --no-rclone
  _config_keys_prime
  output_json_list_begin "settings"
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    config_effective_value_into value "$key"
    if [[ -z "$value" && "$all" != true ]]; then
      continue
    fi
    config_key_source_into source "$key"
    config_display_value_into display "$key" "$value"
    if output_json_enabled; then
      output_json_object_begin
      output_json_kv "key" "$key"
      output_json_kv "value" "$display"
      output_json_kv "source" "$source"
      output_json_object_end
    else
      printf '%s=%s\t%s\n' "$key" "$display" "$source"
    fi
  done <<<"${CONFIG_KEYS_CACHE["$SETTINGS_FILE"]:-}"
  output_json_list_end
  return 0
}

cmd_config_get() {
  local key="" value="" source="" display=""
  opt_begin "json:b" config "" "$@"
  split_positionals "${OPT_EXTRA:-}"
  key="${POSITIONAL_ARGS[0]:-}"
  [[ -n "$key" ]] || usage_error config "get requires a KEY"
  [[ "${#POSITIONAL_ARGS[@]}" -eq 1 ]] || usage_error config "get takes exactly one KEY"
  opt_json_mode
  load_settings --no-rclone
  _config_keys_prime
  config_file_defines "$SETTINGS_FILE" "$key" ||
    die "unknown setting: ${key}"
  config_effective_value_into value "$key"
  config_key_source_into source "$key"
  config_display_value_into display "$key" "$value"
  if output_json_enabled; then
    output_json_begin
    output_json_kv "key" "$key"
    output_json_kv "value" "$display"
    output_json_kv "source" "$source"
    output_json_end
    return 0
  fi
  printf '%s\n' "$display"
  return 0
}

# config_check_add STATUS NAME DETAIL - record one check and count it.
config_check_add() {
  case "$1" in
    PASS) CONFIG_CHECK_PASS=$((CONFIG_CHECK_PASS + 1)) ;;
    WARN) CONFIG_CHECK_WARN=$((CONFIG_CHECK_WARN + 1)) ;;
    FAIL) CONFIG_CHECK_FAIL=$((CONFIG_CHECK_FAIL + 1)) ;;
  esac
  CONFIG_CHECKS="${CONFIG_CHECKS}${1}"$'\t'"${2}"$'\t'"${3}"$'\n'
}

# config_check_state_dir DIR - mkdir -p DIR and report whether it is
# writable. When the nearest existing parent is not writable, nothing is
# created.
config_check_state_dir() {
  local dir="$1" parent=""
  [[ -n "$dir" ]] || {
    config_check_add FAIL "state-dir" "state dir is not configured"
    return 0
  }
  if [[ -d "$dir" ]]; then
    if [[ -w "$dir" ]]; then
      config_check_add PASS "state-dir" "state dir is writable (${dir})"
    else
      config_check_add FAIL "state-dir" "state dir is not writable (${dir})"
    fi
    return 0
  fi
  parent="$dir"
  while [[ ! -d "$parent" && "$parent" != "/" ]]; do
    if [[ "$parent" == */* ]]; then
      parent="${parent%/*}"
      [[ -n "$parent" ]] || parent="/"
    else
      parent="."
      break
    fi
  done
  [[ -d "$parent" ]] || parent="/"
  if [[ ! -w "$parent" ]]; then
    config_check_add FAIL "state-dir" "state dir cannot be created (${dir}; ${parent} is not writable)"
    return 0
  fi
  if mkdir -p "$dir" 2>/dev/null && [[ -w "$dir" ]]; then
    config_check_add PASS "state-dir" "state dir is writable (${dir})"
  else
    config_check_add FAIL "state-dir" "state dir is not writable (${dir})"
  fi
  return 0
}

cmd_config_check() {
  local status="" name="" detail="" ok="false"
  opt_begin "json:b" config "" "$@"
  opt_guard config
  opt_json_mode
  load_settings
  CONFIG_CHECK_PASS=0
  CONFIG_CHECK_WARN=0
  CONFIG_CHECK_FAIL=0
  CONFIG_CHECKS=""
  config_check_add PASS "settings" "settings loaded and validated (${SETTINGS_FILE})"
  if [[ -f "$MANIFEST_FILE" ]]; then
    config_check_add PASS "manifest" "manifest file exists (${MANIFEST_FILE})"
  else
    config_check_add WARN "manifest" "manifest file missing (${MANIFEST_FILE}); nothing will be synced"
  fi
  if [[ -f "$FOLDERS_FILE" ]]; then
    config_check_add PASS "folders" "folders file exists (${FOLDERS_FILE})"
  else
    config_check_add WARN "folders" "folders file missing (${FOLDERS_FILE})"
  fi
  if [[ -f "${FILTER_DIR}/clutter.txt" ]]; then
    config_check_add PASS "filter" "clutter filter exists (${FILTER_DIR}/clutter.txt)"
  else
    config_check_add FAIL "filter" "clutter filter missing (${FILTER_DIR}/clutter.txt)"
  fi
  if [[ -r "$RCLONE_CONFIG" ]]; then
    config_check_add PASS "rclone-config" "rclone config is readable (${RCLONE_CONFIG})"
  else
    config_check_add FAIL "rclone-config" "rclone config is not readable (${RCLONE_CONFIG}); run '${CLI_NAME} setup'"
  fi
  config_check_state_dir "$STATE_DIR"
  if output_json_enabled; then
    [[ "$CONFIG_CHECK_FAIL" -eq 0 ]] && ok="true"
    output_json_begin
    output_json_kv_raw "ok" "$ok"
    output_json_array_begin "checks"
    while IFS=$'\t' read -r status name detail; do
      [[ -n "$status" ]] || continue
      output_json_object_begin
      output_json_kv "name" "$name"
      output_json_kv "status" "$status"
      output_json_kv "detail" "$detail"
      output_json_object_end
    done <<<"$CONFIG_CHECKS"
    output_json_array_end
    output_json_end
  else
    while IFS=$'\t' read -r status name detail; do
      [[ -n "$status" ]] || continue
      printf '%-5s %s\n' "$status" "$detail"
    done <<<"$CONFIG_CHECKS"
    printf '\n%d passed, %d warning(s), %d failure(s)\n' \
      "$CONFIG_CHECK_PASS" "$CONFIG_CHECK_WARN" "$CONFIG_CHECK_FAIL"
  fi
  [[ "$CONFIG_CHECK_FAIL" -eq 0 ]]
}

cmd_config_edit() {
  local file="${SETTINGS_LOCAL_FILE:-}" example="${CONFIG_DIR}/settings.local.env.example" editor=""
  opt_begin "" config "" "$@"
  [[ -z "$OPT_EXTRA" ]] || usage_error config "edit takes no arguments"
  [[ -n "$file" ]] || die "SETTINGS_LOCAL_FILE is not set"
  if [[ "$file" == "${SETTINGS_FILE:-}" ]]; then
    die "refusing to edit ${SETTINGS_FILE} directly; local overrides belong in ${file}"
  fi
  if [[ ! -f "$file" ]]; then
    [[ -f "$example" ]] || die "missing settings example: ${example}"
    mkdir -p "$(dirname "$file")" 2>/dev/null || die "cannot create $(dirname "$file")"
    cp "$example" "$file" || die "cannot create ${file}"
    chmod 600 "$file" 2>/dev/null || true
  fi
  if [[ ! -t 0 ]]; then
    printf '%s\n' "$file"
    return 0
  fi
  editor="${EDITOR:-}"
  if [[ -z "$editor" ]]; then
    if have vi; then
      editor="vi"
    else
      printf '%s\n' "$file"
      return 0
    fi
  fi
  # Split on whitespace and exec directly: EDITOR may carry arguments
  # ("code -w"), but it must never be evaluated as shell code.
  local -a editor_args=()
  read -r -a editor_args <<<"$editor"
  [[ "${#editor_args[@]}" -gt 0 ]] || editor_args=("$editor")
  "${editor_args[@]}" "$file"
}

cmd_config() {
  local sub="${1:-}"
  case "$sub" in
    list) shift && cmd_config_list "$@" ;;
    get) shift && cmd_config_get "$@" ;;
    check) shift && cmd_config_check "$@" ;;
    edit) shift && cmd_config_edit "$@" ;;
    '' | -h | --help | help)
      usage_config
      return 0
      ;;
    *) usage_unknown_sub config "$sub" ;;
  esac
}
