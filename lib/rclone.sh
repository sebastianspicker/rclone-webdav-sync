#!/bin/bash
# rclone.sh - rclone discovery, execution, and config introspection.
# Sourced by bin/sciebo; functions that talk to the remote require
# load_settings to have run first (RCLONE_BIN, RCLONE_CONFIG,
# RCLONE_REMOTE, REMOTE_PREFIX).

# _rclone_candidates_into NAME - fill the array named NAME with the rclone
# binary candidates, best first: RCLONE_BIN, then PATH, then the usual
# Homebrew/system locations. Built in-shell: command -v is a builtin and the
# forkless ${ ...; } capture (Bash 5.3) replaces the old printf-in-a-process-
# substitution, which forked twice per discovery. Deliberately not memoized:
# load_settings and the tests change RCLONE_BIN/PATH in-process, so a
# process-lifetime cache could go stale, and the fork-free loop below is
# already cheap.
_rclone_candidates_into() {
  local -n _rc_out="$1"
  local from_path=""
  from_path=${ command -v rclone 2>/dev/null || true;}
  _rc_out=("${RCLONE_BIN:-}" "$from_path" /opt/homebrew/bin/rclone /usr/local/bin/rclone)
}

# find_rclone - print the rclone binary path or die. RCLONE_BIN wins when
# set and executable; otherwise PATH and the usual Homebrew/system
# locations are searched.
find_rclone() {
  local candidate
  local -a candidates=()
  _rclone_candidates_into candidates
  for candidate in "${candidates[@]}"; do
    [[ -n "$candidate" && -x "$candidate" ]] || continue
    printf '%s' "$candidate"
    return 0
  done
  die "rclone not found in PATH, /opt/homebrew/bin, or /usr/local/bin"
}

# rclone_available - true when find_rclone would succeed (without dying).
rclone_available() {
  local candidate
  local -a candidates=()
  _rclone_candidates_into candidates
  for candidate in "${candidates[@]}"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then return 0; fi
  done
  return 1
}

# _rclone_proxy_resolve STRIP_VAR FLAG_VAR VALUE_VAR ENV_VAR - resolve
# PROXY_TYPE/PROXY/PROXY_DIRECT into the rclone child's proxy behavior
# through the named out-params: STRIP_VAR=1 unsets the proxy environment in
# the child, FLAG_VAR/VALUE_VAR form an optional rclone --http-proxy pair,
# and ENV_VAR is an http(s):// proxy URL to export to the child. The
# classification itself is the shared _proxy_classify (lib/core.sh); an
# explicit http:// or https:// PROXY is exported
# (HTTP_PROXY/HTTPS_PROXY/ALL_PROXY) rather than passed in argv, so its
# credentials never reach ps; a socks5:// PROXY keeps --http-proxy (rclone's
# only global proxy flag) because socks support through the environment is
# not guaranteed. PROXY_TYPE=none and PROXY_DIRECT=1 clear the environment;
# http and socks5 require PROXY.
# shellcheck disable=SC2034  # out-params are written through namerefs
_rclone_proxy_resolve() {
  local -n out_strip="$1" out_flag="$2" out_value="$3" out_env="$4"
  local class="" url="" error=""
  out_strip=false out_flag="" out_value="" out_env=""
  _proxy_classify class url error "${PROXY_TYPE:-system}" "${PROXY:-}" "${PROXY_DIRECT:-0}"
  [[ -z "$error" ]] || die "$error"
  case "$class" in
    none) out_strip=true ;;
    env) out_env="$url" ;;
    flag)
      out_flag="--http-proxy"
      out_value="$url"
      ;;
  esac
}

# _rclone_client_pass - print the obscured form of CLIENT_KEY_PASSWORD for
# rclone's --client-pass flag, computed once per process. rclone expects that
# flag's value to be obscured (it calls obscure.Reveal on it), so a plaintext
# passphrase from the settings never reaches argv as such; the obscured value
# does, because rclone has no file-based alternative for it.
RCLONE_CLIENT_PASS_CACHE=""
_rclone_client_pass() {
  if [[ -z "${CLIENT_KEY_PASSWORD:-}" ]]; then
    return 0
  fi
  if [[ -z "$RCLONE_CLIENT_PASS_CACHE" ]]; then
    RCLONE_CLIENT_PASS_CACHE="$(rclone_obscure "$CLIENT_KEY_PASSWORD")"
  fi
  printf '%s' "$RCLONE_CLIENT_PASS_CACHE"
}

# _rclone_global_flags_into ARGS_NAME - append the global rclone flags, in
# argv order, to the argv array named ARGS_NAME: TLS_INSECURE=1 adds
# --no-check-certificate (warning once per process), SCIEBO_DEBUG adds -vv,
# CLIENT_CERT/CLIENT_KEY/CA_CERT add --client-cert/--client-key/--ca-cert,
# CLIENT_KEY_PASSWORD adds --client-pass (obscured to match rclone's
# contract), and USER_AGENT adds --user-agent, when set.
_rclone_global_flags_into() {
  local -n args_ref="$1"
  local client_pass=""
  if [[ "${TLS_INSECURE:-0}" == "1" ]]; then
    args_ref+=(--no-check-certificate)
    if [[ "${_RCLONE_TLS_WARNED:-0}" != "1" ]]; then
      warn "TLS certificate verification is disabled (--trust); this connection is not authenticated"
      _RCLONE_TLS_WARNED=1
    fi
  fi
  if [[ -n "${SCIEBO_DEBUG:-}" ]]; then
    args_ref+=(-vv)
  fi
  # Mutual TLS and custom trust. The paths are not secrets; the key
  # passphrase is obscured above to match rclone's --client-pass contract.
  [[ -z "${CLIENT_CERT:-}" ]] || args_ref+=(--client-cert "$CLIENT_CERT")
  [[ -z "${CLIENT_KEY:-}" ]] || args_ref+=(--client-key "$CLIENT_KEY")
  if [[ -n "${CLIENT_KEY_PASSWORD:-}" ]]; then
    # Forkless capture: _rclone_client_pass caches the obscured value in the
    # caller's shell. The old "$(...)" capture ran it inside a subshell, so
    # RCLONE_CLIENT_PASS_CACHE never survived the statement and rclone_obscure
    # re-ran on every rclone_cmd. Value and ignored rc match the old
    # argument-context substitution.
    client_pass=${ _rclone_client_pass;}
    args_ref+=(--client-pass "$client_pass")
  fi
  [[ -z "${CA_CERT:-}" ]] || args_ref+=(--ca-cert "$CA_CERT")
  [[ -z "${USER_AGENT:-}" ]] || args_ref+=(--user-agent "$USER_AGENT")
}

# _rclone_exec_with_env STRIP PROXY_ENV SECRET ENV_NAME ARGS_NAME CMD... - run
# rclone in a child that isolates the proxy environment and the dynamically
# named config password: STRIP=true unsets HTTP_PROXY/HTTPS_PROXY/ALL_PROXY
# (and their lowercase forms) in the child, a non-empty PROXY_ENV is exported
# to all three, and a non-empty SECRET is exported as ENV_NAME. The rclone
# argv is the array named ARGS_NAME followed by CMD...; the child execs
# rclone, so neither the secret nor the proxy URL ever reaches a process list.
# rclone keeps the remote section verbatim in the variable name, so a remote
# with a dash or dot yields an ENV_NAME bash cannot export
# (RCLONE_CONFIG_MY-REMOTE_PASS); such a name is handed to env(1) for the exec
# instead, which briefly puts the obscured secret in env's argv (the price of
# a name bash cannot hold, and the only way rclone reads it at all).
_rclone_exec_with_env() {
  local strip="$1" proxy_env="$2" secret="$3" env_name="$4"
  # shellcheck disable=SC2178  # nameref to an argv array
  local -n args_ref="$5"
  shift 5
  (
    if [[ "$strip" == true ]]; then
      unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy
    fi
    if [[ -n "$proxy_env" ]]; then
      export HTTP_PROXY="$proxy_env" HTTPS_PROXY="$proxy_env" ALL_PROXY="$proxy_env"
    fi
    if [[ -n "$secret" ]]; then
      if [[ "$env_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        export "$env_name=$secret"
      else
        exec env "$env_name=$secret" "$RCLONE_BIN" "${args_ref[@]}" "$@"
      fi
    fi
    exec "$RCLONE_BIN" "${args_ref[@]}" "$@"
  )
}

# _rclone_env_pass_name REMOTE - print the RCLONE_CONFIG_<REMOTE>_PASS
# variable name rclone reads for REMOTE. rclone's fs/config.go ConfigToEnv
# uppercases the section name verbatim and underscore-folds only the option
# part, so a dashed or dotted remote keeps those characters:
# my-remote -> RCLONE_CONFIG_MY-REMOTE_PASS. Bash cannot export such a name,
# so _rclone_exec_with_env hands it to env(1); this helper is the single
# source of the spelling.
_rclone_env_pass_name() {
  printf 'RCLONE_CONFIG_%s_PASS' "${1^^}"
}

# rclone_cmd ARGS... - run rclone against the configured rclone config.
# In Keychain mode the obscured app password is injected through
# RCLONE_CONFIG_<REMOTE>_PASS, which affects only this remote and only the
# child process; the parent environment is never modified. The global flags
# come from _rclone_global_flags_into and the proxy behavior from
# _rclone_proxy_resolve; the export+exec child is _rclone_exec_with_env.
rclone_cmd() {
  local secret="" env_name="" strip_env=false proxy_flag="" proxy_value="" proxy_env="" LC_ALL=C
  local -a args=(--config "$RCLONE_CONFIG")
  # keychain.sh loads lazily; require it before the probe below so
  # KEYCHAIN=1 keeps injecting the secret exactly as when keychain.sh was
  # eager (the `type` probe alone would silently take the non-keychain
  # branch whenever the module had not been loaded yet).
  sciebo_require_module keychain keychain_enabled
  # A config write invalidates the cached config introspection.
  case "${1:-} ${2:-}" in
    "config create" | "config update" | "config delete") remote_config_invalidate ;;
  esac
  _rclone_global_flags_into args
  # The proxy URL is exported to the child instead of passed as --http-proxy
  # whenever it carries credentials (http/https), so it stays out of argv.
  _rclone_proxy_resolve strip_env proxy_flag proxy_value proxy_env
  [[ -z "$proxy_flag" ]] || args+=("$proxy_flag" "$proxy_value")
  if type keychain_enabled >/dev/null 2>&1 && keychain_enabled; then
    secret=${ remote_secret_obscured;} || secret=""
  fi
  if [[ -n "$secret" ]]; then
    # rclone's own rule (fs/config.go ConfigToEnv) uppercases the section
    # name but leaves its characters untouched: only the *option* part has
    # its hyphens turned into underscores. So "my-remote" becomes
    # RCLONE_CONFIG_MY-REMOTE_PASS, verified against real rclone.
    # _rclone_exec_with_env exports a valid name directly and hands a
    # dashed/dotted one to env(1).
    env_name=${ _rclone_env_pass_name "$RCLONE_REMOTE";}
  fi
  if [[ "$strip_env" == true || -n "$proxy_env" || -n "$secret" ]]; then
    _rclone_exec_with_env "$strip_env" "$proxy_env" "$secret" "$env_name" args "$@"
    return $?
  fi
  "$RCLONE_BIN" "${args[@]}" "$@"
}

# progress_stdout_tty - true when stdout is a terminal. Kept as its own
# function so tests can substitute a TTY-like check without a real pty.
progress_stdout_tty() { [[ -t 1 ]]; }

# progress_append_args ARGS_NAME QUIET - append rclone's -P to the array named
# by ARGS_NAME when --progress was requested, stdout is a terminal, and the run
# is neither quiet nor in JSON mode. A stdout that is captured or piped (a
# logged run) keeps the progress bar out of the output.
progress_append_args() {
  # shellcheck disable=SC2178  # nameref to an argv array
  local -n args_ref="$1"
  local quiet="$2"
  [[ -n "${OPT_progress:-}" ]] || return 0
  [[ "$quiet" -eq 0 ]] || return 0
  [[ "${OUTPUT_JSON:-false}" != true ]] || return 0
  progress_stdout_tty || return 0
  args_ref+=(-P)
}

require_remote() {
  remote_configured ||
    die "rclone remote '${RCLONE_REMOTE}:' is not configured; run '${CLI_NAME} setup'"
}

# Process-lifetime caches for the two config-introspection calls that run
# several times per command (doctor alone made ~7 rclone invocations for
# these). Successes only: a failed lookup must stay retryable, and
# remote_config_invalidate drops both after a config write.
REMOTE_CONFIGURED_CACHE=""
REMOTE_CONFIG_SHOW_CACHE=""
# Negative results are cached too (as "0"): remote_is_nextcloud is called
# from several per-entry guards, and a non-Nextcloud remote never changes
# unless the config is rewritten, which invalidates this.
REMOTE_IS_NEXTCLOUD_CACHE=""

# remote_secret_invalidate - forget the resolved obscured and plain app
# passwords, so a config or Keychain change cannot leave a stale credential
# in either process-lifetime cache. When lib/http.sh is loaded its own
# HTTP_SECRET_CACHE (derived from the plaintext) is dropped too; when
# lib/keychain.sh is loaded the memoized keychain-backend probe is dropped
# with the secrets so the next rclone_cmd re-probes after a credential
# change. Both guards keep lib/rclone.sh usable on its own.
remote_secret_invalidate() {
  REMOTE_SECRET_CACHE=""
  REMOTE_SECRET_PLAIN_CACHE=""
  if type -t http_secret_invalidate >/dev/null 2>&1; then
    http_secret_invalidate
  fi
  if type -t _keychain_cache_reset >/dev/null 2>&1; then
    _keychain_cache_reset
  fi
}

# remote_config_invalidate - forget the cached config answers; call after
# `rclone config create/update/delete`. The resolved app passwords (and the
# HTTP plaintext derived from them) are dropped with them, because a rewritten
# config can change the credential fallback chain.
remote_config_invalidate() {
  REMOTE_CONFIGURED_CACHE=""
  REMOTE_CONFIG_SHOW_CACHE=""
  REMOTE_IS_NEXTCLOUD_CACHE=""
  remote_secret_invalidate
}

remote_configured() {
  if [[ -n "$REMOTE_CONFIGURED_CACHE" ]]; then
    [[ "$REMOTE_CONFIGURED_CACHE" == "1" ]]
    return
  fi
  if rclone_cmd listremotes 2>/dev/null | grep -Fqx "${RCLONE_REMOTE}:"; then
    REMOTE_CONFIGURED_CACHE="1"
    return 0
  fi
  return 1
}

# `config show` is enough for type/url/vendor/user; it redacts the password
# ("*** ENCRYPTED ***"). Commands that must authenticate with a second,
# ad-hoc remote read the obscured value from `config dump` instead. Both
# return non-zero with empty stdout when rclone cannot read the config.
# They call the binary directly: a config read must never go through the
# Keychain lookup, which itself reads the dump as a fallback.
remote_config_show() {
  if [[ -n "$REMOTE_CONFIG_SHOW_CACHE" ]]; then
    printf '%s' "$REMOTE_CONFIG_SHOW_CACHE"
    return 0
  fi
  local out=""
  out="$("$RCLONE_BIN" --config "$RCLONE_CONFIG" config show "$RCLONE_REMOTE" 2>/dev/null)" || return 1
  [[ -n "$out" ]] || return 1
  REMOTE_CONFIG_SHOW_CACHE="$out"
  printf '%s' "$out"
}

remote_config_dump() { "$RCLONE_BIN" --config "$RCLONE_CONFIG" config dump 2>/dev/null; }

# rclone_config_encrypted - true (0) when the rclone config file carries
# rclone's encryption header. An encrypted file defeats the placeholder+patch
# design (rclone stores the encrypted form, not the literal placeholder), and
# the reversible secret must not fall back to an argv config write, so the
# write helpers refuse instead of patching.
rclone_config_encrypted() {
  local file="${RCLONE_CONFIG:-}"
  [[ -n "$file" && -f "$file" ]] || return 1
  LC_ALL=C grep -q '^RCLONE_ENCRYPT_' "$file" 2>/dev/null
}

# rclone_version - print the version from `rclone version` (e.g. "1.75.1"),
# empty when rclone is missing, fails, or reports an unparseable version.
# Successful lookups are cached in RCLONE_VERSION_CACHE.
rclone_version() {
  if [[ -n "${RCLONE_VERSION_CACHE:-}" ]]; then
    printf '%s' "$RCLONE_VERSION_CACHE"
    return 0
  fi
  local out="" line="" version="" major="" minor=""
  if have "${RCLONE_BIN:-}"; then
    # Fork removal: capture the output once and take the first line with
    # parameter expansion instead of piping through sed (still behind
    # RCLONE_VERSION_CACHE below, so this runs at most once per process).
    out="$("$RCLONE_BIN" version 2>/dev/null || true)"
    line="${out%%$'\n'*}"
  fi
  version="${line#rclone v}"
  major="${version%%.*}"
  minor="${version#*.}"
  minor="${minor%%.*}"
  if [[ -n "$major" && -n "$minor" && "$major" != *[!0-9]* && "$minor" != *[!0-9]* ]]; then
    RCLONE_VERSION_CACHE="$version"
  fi
  printf '%s' "${RCLONE_VERSION_CACHE:-}"
}

# rclone_version_at_least MAJOR MINOR - true (0) when the installed rclone is
# at least MAJOR.MINOR; false (1) when it is older or the version cannot be
# read or parsed.
rclone_version_at_least() {
  local want_major="${1:-}" want_minor="${2:-}" version="" major="" minor=""
  case "$want_major" in '' | *[!0-9]*) return 1 ;; esac
  case "$want_minor" in '' | *[!0-9]*) return 1 ;; esac
  version=${ rclone_version;}
  [[ -n "$version" ]] || return 1
  major="${version%%.*}"
  minor="${version#*.}"
  minor="${minor%%.*}"
  case "$major" in '' | *[!0-9]*) return 1 ;; esac
  case "$minor" in '' | *[!0-9]*) return 1 ;; esac
  if [[ "$major" -gt "$want_major" ]]; then return 0; fi
  if [[ "$major" -eq "$want_major" && "$minor" -ge "$want_minor" ]]; then return 0; fi
  return 1
}

# config_value KEY CONFIG_SHOW_OUTPUT -> value (empty if unset). Pure bash:
# the key must start a line, whitespace around "=" is tolerated, and the
# value is trimmed. Walks the blob line by line with a here-string so no awk
# process is forked on the config-introspection hot path.
config_value() {
  local key="$1" blob="$2" line="" value=""
  while IFS= read -r line; do
    case "$line" in
      "$key"=* | "$key"[[:space:]]*=*) ;;
      *) continue ;;
    esac
    value="${line#*=}"
    trim_into value "$value"
    printf '%s' "$value"
    return 0
  done <<<"$blob"
  return 0
}

# remote_is_nextcloud - true (0) when the configured remote's url is a
# Nextcloud WebDAV URL (/remote.php/dav/files/); rc 1 otherwise, no output.
# Other backends stay silent in the E2EE/external-storage gates.
remote_is_nextcloud() {
  local show="" url=""
  if [[ -n "$REMOTE_IS_NEXTCLOUD_CACHE" ]]; then
    [[ "$REMOTE_IS_NEXTCLOUD_CACHE" == "1" ]]
    return
  fi
  show=${ remote_config_show 2>/dev/null;} || return 1
  [[ -n "$show" ]] || return 1
  url="$(config_value url "$show")"
  case "$url" in
    *"/remote.php/dav/files/"*)
      REMOTE_IS_NEXTCLOUD_CACHE="1"
      return 0
      ;;
  esac
  REMOTE_IS_NEXTCLOUD_CACHE="0"
  return 1
}

# remote_nextcloud_base [URL] - print scheme://host[:port] derived from URL
# (the configured remote's url when omitted); rc 1 without an http(s)
# scheme or the /remote.php/dav/files/ path. The single base derivation:
# http_remote_info (lib/http.sh) and capabilities_base_url both delegate
# here, and http.sh already depends on rclone.sh's config helpers, so this
# file is the load-order-safe owner of the logic.
remote_nextcloud_base() {
  local url="${1:-}" show="" base=""
  if [[ -z "$url" ]]; then
    show=${ remote_config_show 2>/dev/null;} || return 1
    [[ -n "$show" ]] || return 1
    url="$(config_value url "$show")"
  fi
  case "$url" in
    http://* | https://*) ;;
    *) return 1 ;;
  esac
  case "$url" in
    *"/remote.php/dav/files/"*)
      base="${url%%/remote.php/dav/files/*}"
      ;;
    *) return 1 ;;
  esac
  base="${base%/}"
  [[ -n "$base" ]] || return 1
  printf '%s\n' "$base"
}

# rclone_config_patch_value REMOTE KEY EXPECTED VALUE - replace REMOTE's KEY
# line in the rclone config with VALUE without VALUE ever reaching an argv:
# VALUE is exported to the awk child and read from ENVIRON, never passed with
# -v (which would put the reversible secret in the awk argv). EXPECTED is the
# literal placeholder rclone just wrote; it proves the config is plaintext
# (an encrypted config carries the encrypted form instead) and the function
# returns 1 when it is absent, so the caller must refuse rather than fall back
# to an argv config write. Only the matching KEY line in REMOTE's [section] is
# rewritten; the file is replaced atomically with mode 600.
rclone_config_patch_value() {
  local remote="$1" key="$2" expected="$3" value="$4" file="${RCLONE_CONFIG:-}" tmp=""
  [[ -n "$file" && -f "$file" && -n "$remote" && -n "$key" ]] || return 1
  case "$key$value" in *[[:cntrl:]]* | *\\*) return 1 ;; esac
  temp_mktemp_into tmp "${file}.tmp.XXXXXX" || return 1
  if ! VALUE="$value" awk -v section="[${remote}]" -v key="$key" -v expected="$expected" '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    BEGIN { value = ENVIRON["VALUE"] }
    /^\[/ {
      insec = (trim($0) == section)
      print
      next
    }
    {
      if (insec && !found && $0 ~ ("^[[:space:]]*" key "[[:space:]]*=")) {
        cur = trim($0)
        sub(/^[^=]*=[[:space:]]*/, "", cur)
        if (cur == expected) {
          print key " = " value
          found = 1
          next
        }
      }
      print
    }
    END { exit(found ? 0 : 1) }
  ' "$file" >"$tmp"; then
    temp_discard "$tmp"
    return 1
  fi
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$file" || {
    temp_discard "$tmp"
    return 1
  }
  temp_discard "$tmp"
  return 0
}

# remote_write_nextcloud URL USER PASS_CONFIG - create or update the
# configured remote as a Nextcloud WebDAV backend with PASS_CONFIG as its
# `pass` value (already obscured, or the obscured empty value in Keychain
# mode). rclone first writes a non-secret placeholder, then the real obscured
# value is patched into the plaintext config file, so the reversible secret
# never appears in an argv (rclone's config write has no stdin/env path).
# Refuses (die) for an encrypted config instead of falling back to an argv
# update. The logs and failure messages match setup/provision exactly.
remote_write_nextcloud() {
  local url="$1" user="$2" pass_config="$3" placeholder=""
  placeholder="$(rclone_obscure_empty)"
  if remote_configured; then
    log "updating existing rclone remote '${RCLONE_REMOTE}:'"
    if ! rclone_cmd config update "$RCLONE_REMOTE" type webdav url "$url" vendor nextcloud user "$user" pass --non-interactive -- "$placeholder" >/dev/null; then
      die "could not update the rclone remote '${RCLONE_REMOTE}:'"
    fi
  else
    log "creating rclone remote '${RCLONE_REMOTE}:'"
    if ! rclone_cmd config create "$RCLONE_REMOTE" webdav url "$url" vendor nextcloud user "$user" pass --non-interactive -- "$placeholder" >/dev/null; then
      die "could not create the rclone remote '${RCLONE_REMOTE}:'"
    fi
  fi
  [[ "$pass_config" == "$placeholder" ]] && return 0
  if rclone_config_patch_value "$RCLONE_REMOTE" pass "$placeholder" "$pass_config"; then
    remote_config_invalidate
    return 0
  fi
  if rclone_config_encrypted; then
    die "rclone config is encrypted, so the password cannot be patched in without exposing it in the process list; disable rclone config encryption (rclone config encryption remove) and re-run '${CLI_NAME} setup'"
  fi
  die "could not patch the password into the rclone config (unreadable or changed); re-run '${CLI_NAME} setup'"
}

# remote_write_pass PASS_CONFIG - update only the `pass` of the configured
# remote without putting the secret in an argv: write the obscured-empty
# placeholder with rclone, then patch the real value into the plaintext
# config. Dies for an encrypted/unreadable config.
remote_write_pass() {
  local pass_config="$1" placeholder=""
  placeholder="$(rclone_obscure_empty)"
  if ! rclone_cmd config update "$RCLONE_REMOTE" pass --non-interactive -- "$placeholder" >/dev/null; then
    die "could not update the app password for '${RCLONE_REMOTE}:'"
  fi
  [[ "$pass_config" == "$placeholder" ]] && return 0
  if rclone_config_patch_value "$RCLONE_REMOTE" pass "$placeholder" "$pass_config"; then
    remote_config_invalidate
    return 0
  fi
  if rclone_config_encrypted; then
    die "rclone config is encrypted, so the new password cannot be patched in without exposing it in the process list; disable rclone config encryption and re-run '${CLI_NAME} setup --rotate'"
  fi
  die "could not patch the password into the rclone config (unreadable or changed); re-run '${CLI_NAME} setup --rotate'"
}

# remote_validate [HINT] - `rclone lsd` against the configured remote; log
# success or die naming the Nextcloud credentials. HINT is the exact list
# of options/values to check (defaults to setup's wording).
remote_validate() {
  local hint="${1:-the URL, the sciebo ID, and the app password}"
  local lsd_err=""
  log "validating remote '${RCLONE_REMOTE}:' (rclone lsd)"
  if lsd_err="$(rclone_cmd lsd "${RCLONE_REMOTE}:" 2>&1 >/dev/null)"; then
    log "remote is reachable"
    return 0
  fi
  err "rclone lsd failed: $(printf '%s' "$lsd_err" | sanitize_stream)"
  die "validation failed; check ${hint} (accounts with 2FA need an app password from Settings > Security)"
}

# config_dump_value REMOTE KEY JSON_FROM_CONFIG_DUMP -> value
# Minimal parser for the pretty-printed dump; handles simple string values
# (url/user/pass contain no embedded quotes). One awk pass over a
# here-string: it finds the first `"KEY": "VALUE"` line inside REMOTE's
# block, extracts the value, and exits, so no grep/head/printf is forked.
# A missing key or remote prints nothing and returns 0, as before.
config_dump_value() {
  local remote="$1" key="$2" json="$3"
  awk -v marker="\"${remote}\"" -v want="\"${key}\":" '
    index($0, marker) && /[{][[:space:]]*$/ { in_block = 1; next }
    in_block && /^[[:space:]]*}/ { exit }
    in_block && index($0, want) {
      value = $0
      sub(/^[^:]*: /, "", value)
      sub(/,$/, "", value)
      if (value ~ /^".*"$/) value = substr(value, 2, length(value) - 2)
      print value
      exit
    }
  ' <<<"$json"
}

# rclone_obscure SECRET - print SECRET obscured with `rclone obscure`. The
# plaintext travels on stdin, never in an argv visible to ps; die when
# rclone fails.
rclone_obscure() {
  local obscured=""
  obscured="$(printf '%s' "$1" | "$RCLONE_BIN" obscure -)" ||
    die "could not obscure the password (rclone obscure failed)"
  printf '%s' "$obscured"
}

# rclone_obscure_empty - print the obscured empty password, computed once
# per process. rclone accepts it as the config value when the real secret
# lives in the Keychain.
RCLONE_OBSCURE_EMPTY_CACHE=""
rclone_obscure_empty() {
  if [[ -z "$RCLONE_OBSCURE_EMPTY_CACHE" ]]; then
    RCLONE_OBSCURE_EMPTY_CACHE="$(printf '' | "$RCLONE_BIN" obscure -)" ||
      die "could not obscure an empty password (rclone obscure failed)"
  fi
  printf '%s' "$RCLONE_OBSCURE_EMPTY_CACHE"
}

# remote_password_config_value PLAINTEXT [USE_KEYCHAIN] - print the value to
# store as the remote's `pass`. In Keychain mode the plaintext goes to the
# keychain (so HTTP commands never `rclone reveal` it) and the config gets the
# obscured empty value; otherwise the obscured plaintext is returned.
remote_password_config_value() {
  local plaintext="$1" use_keychain="${2:-0}"
  # keychain.sh is lazy; require it on the path that stores the secret.
  sciebo_require_module keychain keychain_store_plain
  if [[ "$use_keychain" -eq 1 ]]; then
    keychain_store_plain "$plaintext"
    rclone_obscure_empty
    return 0
  fi
  rclone_obscure "$plaintext"
}

# _rclone_reveal OBSCURED - print the plaintext of an obscured value. This
# passes the reversible obscured value in the rclone argv, so it is used only
# for a one-time migration of a legacy keychain item or when the secret lives
# obscured in the rclone config.
_rclone_reveal() {
  "$RCLONE_BIN" reveal -- "$1" 2>/dev/null
}

# remote_secret_obscured - print the obscured app password for
# RCLONE_REMOTE. Prefers the keychain plaintext slot (obscured here with
# `rclone obscure` on stdin, so no secret reaches an argv), then the legacy
# obscured keychain item, then the `pass` value from `rclone config dump`.
# rc 1 with empty output when none exists. Cached in REMOTE_SECRET_CACHE.
remote_secret_obscured() {
  local secret="" dump="" plain=""
  if [[ -n "${REMOTE_SECRET_CACHE:-}" ]]; then
    printf '%s' "$REMOTE_SECRET_CACHE"
    return 0
  fi
  # keychain.sh is lazy; require it before the probe so the keychain branch
  # is taken whenever KEYCHAIN=1, module loaded or not.
  sciebo_require_module keychain keychain_enabled
  if type keychain_enabled >/dev/null 2>&1 && keychain_enabled; then
    plain=${ keychain_lookup_plain 2>/dev/null;} || plain=""
    if [[ -n "$plain" ]]; then
      secret="$(rclone_obscure "$plain")"
      REMOTE_SECRET_CACHE="$secret"
      printf '%s' "$secret"
      return 0
    fi
    secret=${ keychain_lookup 2>/dev/null;} || secret=""
    if [[ -n "$secret" ]]; then
      REMOTE_SECRET_CACHE="$secret"
      printf '%s' "$secret"
      return 0
    fi
  fi
  if dump=${ remote_config_dump;} && [[ -n "$dump" ]]; then
    secret=${ config_dump_value "$RCLONE_REMOTE" pass "$dump";}
    if [[ -n "$secret" ]]; then
      REMOTE_SECRET_CACHE="$secret"
      printf '%s' "$secret"
      return 0
    fi
  fi
  return 1
}

# remote_secret_plain - print the plain app password. Prefers the keychain
# plaintext slot (no reveal). A legacy obscured keychain item is revealed
# once and migrated to the plaintext slot. When the secret lives obscured in
# the rclone config (KEYCHAIN=0) it is revealed with a one-time warning.
# Cached in REMOTE_SECRET_PLAIN_CACHE.
remote_secret_plain() {
  local obscured="" plain=""
  if [[ -n "${REMOTE_SECRET_PLAIN_CACHE:-}" ]]; then
    printf '%s' "$REMOTE_SECRET_PLAIN_CACHE"
    return 0
  fi
  # keychain.sh is lazy; require it before the probe (see
  # remote_secret_obscured).
  sciebo_require_module keychain keychain_enabled
  if type keychain_enabled >/dev/null 2>&1 && keychain_enabled; then
    plain=${ keychain_lookup_plain 2>/dev/null;} || plain=""
    if [[ -z "$plain" ]]; then
      obscured=${ keychain_lookup 2>/dev/null;} || obscured=""
      if [[ -n "$obscured" ]]; then
        plain=${ _rclone_reveal "$obscured";} || plain=""
      fi
      if [[ -n "$plain" ]]; then
        # One-time migration of the legacy obscured keychain item.
        keychain_store_plain "$plain"
      fi
    fi
  fi
  if [[ -z "$plain" ]]; then
    obscured=${ remote_secret_obscured;} || return 1
    plain=${ _rclone_reveal "$obscured";} || return 1
    # The residual exposure (KEYCHAIN=0 config-obscured) is reported by
    # `doctor` and documented in SECURITY.md; no per-command warning is
    # emitted because it would break --quiet output.
  fi
  [[ -n "$plain" ]] || return 1
  REMOTE_SECRET_PLAIN_CACHE="$plain"
  printf '%s' "$plain"
}

# rclone_size_bytes JSON - print the top-level "bytes" number from an
# `rclone size --json` document; nothing when the field is absent. One awk
# pass, shared by every size caller.
rclone_size_bytes() {
  printf '%s\n' "${1:-}" | LC_ALL=C awk '
    match($0, /"bytes"[ \t]*:[ \t]*[0-9]+/) {
      value = substr($0, RSTART, RLENGTH)
      sub(/.*:[ \t]*/, "", value)
      print value
      exit
    }
  '
}

# rclone_remote_size SPEC - print the remote source's total size in bytes
# from one `rclone size --json`; rc 1 when the call fails or the size cannot
# be parsed. Callers memoize the result per entry.
rclone_remote_size() {
  local spec="$1" size_json="" bytes=""
  size_json="$(rclone_cmd size --json "${spec}/" 2>/dev/null)" || return 1
  bytes="$(rclone_size_bytes "$size_json")"
  [[ -n "$bytes" ]] || return 1
  printf '%s' "$bytes"
}

# rclone_capture LABEL ARGS... - run rclone_cmd ARGS with stdout captured in
# RCLONE_CAPTURE_OUT and stderr in RCLONE_CAPTURE_ERR (both registered for
# exit cleanup). Returns the child's status so the caller can decide what to
# print; discard both files with temp_discard when done.
rclone_capture() {
  local label="${1:-rclone}"
  shift
  temp_mktemp_into RCLONE_CAPTURE_OUT "${TMPDIR:-/tmp}/sciebo-${label}-out.XXXXXX" ||
    die "cannot create temp file"
  temp_mktemp_into RCLONE_CAPTURE_ERR "${TMPDIR:-/tmp}/sciebo-${label}-err.XXXXXX" || {
    temp_discard "$RCLONE_CAPTURE_OUT"
    RCLONE_CAPTURE_OUT=""
    die "cannot create temp file"
  }
  local rc=0
  if rclone_cmd "$@" >"$RCLONE_CAPTURE_OUT" 2>"$RCLONE_CAPTURE_ERR"; then
    rc=0
  else
    rc=$?
  fi
  return "$rc"
}

# remote_spec SUBPATH - print <remote>:<base>/<subpath>
remote_spec() { printf '%s/%s' "$REMOTE_PREFIX" "$1"; }

# Process-lifetime cache of directory-existence probes, keyed by the exact
# remote spec. Both positive and negative answers are cached, so the repeated
# checks of one directory within a run (sync, verify, folders, mount, hydrate,
# and the remote case-clash preflight) reuse a single `rclone lsd` instead of
# re-querying. Parallel workers are separate processes and keep independent
# caches, like the config and size caches. Declared with -g so the cache
# survives being loaded through sciebo_require_module.
declare -gA REMOTE_DIR_EXISTS_CACHE=()

# remote_dir_exists SPEC - true when SPEC (a remote directory) exists. The
# positive/negative answer is memoized per spec for the life of the process;
# callers are read-only probes and never rely on observing a directory they
# create later in the same run.
remote_dir_exists() {
  local spec="${1:-}"
  if [[ -n "${REMOTE_DIR_EXISTS_CACHE[$spec]+cached}" ]]; then
    [[ "${REMOTE_DIR_EXISTS_CACHE[$spec]}" == "1" ]]
    return
  fi
  if rclone_cmd lsd "$spec/" >/dev/null 2>&1; then
    REMOTE_DIR_EXISTS_CACHE[$spec]="1"
    return 0
  fi
  REMOTE_DIR_EXISTS_CACHE[$spec]="0"
  return 1
}

# rclone_stat_is_dir SPEC OUT_VAR - classify SPEC with `rclone lsjson --stat`;
# sets OUT_VAR to 1 for a directory, 0 otherwise. rc 1 when the path cannot be
# inspected (rclone failure or empty output), matching the inline stat probes
# in the download and edit command modules.
rclone_stat_is_dir() {
  local spec="$1" out_name="$2" out="" rc=0
  printf -v "$out_name" '%s' 0
  if out="$(rclone_cmd lsjson "$spec" --stat 2>/dev/null)"; then
    rc=0
  else
    rc=$?
  fi
  [[ "$rc" -eq 0 && -n "$out" ]] || return 1
  if printf '%s' "$out" | grep -qE '"IsDir"[[:space:]]*:[[:space:]]*true'; then
    printf -v "$out_name" '%s' 1
  fi
  return 0
}

# rclone_lsf_paths SPEC - print one relative path per line from
# `rclone lsf -R --format p SPEC`; directories keep their trailing "/".
# Read-only. rc 0 for an empty listing (nothing printed) and rc 1 when the
# listing command itself fails, so callers can tell "nothing there" from
# "could not look" instead of silently scanning an unreachable remote as
# empty.
rclone_lsf_paths() {
  local spec="${1:-}" out="" rc=0
  [[ -n "$spec" ]] || return 0
  out="$(rclone_cmd lsf -R --format p "$spec" 2>/dev/null)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    return 1
  fi
  [[ -n "$out" ]] || return 0
  printf '%s\n' "$out"
  return 0
}

# rclone_filter_excludes ARGS_NAME NAME RETRY_CLI - append the filter layer
# shared by the sync/pull and ignored builders, in this order: the
# conflict-copy exclusion (unless CONFLICT_UPLOAD=1), the hidden-file
# exclusion (SKIP_HIDDEN=1), then one --exclude per failure-blacklisted path,
# warning once when any applied. ARGS_NAME is an argv array name; RETRY_CLI
# is the command named in the warning.
rclone_filter_excludes() {
  # shellcheck disable=SC2178  # nameref to an argv array
  local -n args_ref="$1"
  local name="$2" retry_cli="$3" pattern="" excluded_n=0 excluded=""
  [[ "${CONFLICT_UPLOAD:-0}" -ne 0 ]] || args_ref+=(--exclude "*${CONFLICT_PATTERN:-conflicted copy}*")
  [[ "${SKIP_HIDDEN:-0}" -ne 1 ]] || args_ref+=(--exclude ".*")
  # Forkless capture instead of `< <(blacklist_excluded ...)`: blacklist_excluded
  # only prints and reads its record file, so running it here drops the
  # per-entry subshell. The `|| true` keeps the old `<(... || true)` contract:
  # whatever was printed before a failure is still iterated, and rc stays 0.
  # The non-empty guard below also skips the blank line a here-string appends.
  excluded=${ blacklist_excluded "$name" 2>/dev/null;} || true
  while IFS= read -r pattern; do
    [[ -n "$pattern" ]] || continue
    args_ref+=(--exclude "$pattern")
    excluded_n=$((excluded_n + 1))
  done <<<"$excluded"
  if [[ "$excluded_n" -gt 0 ]]; then
    warn "${name}: ${excluded_n} blacklisted path(s) excluded after repeated failures; run '${retry_cli} retry ${name}' to try them again"
  fi
}
