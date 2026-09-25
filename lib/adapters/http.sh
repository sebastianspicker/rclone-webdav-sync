#!/bin/bash
# http.sh - shared curl plumbing for Nextcloud WebDAV and OCS endpoints.
#
# Commands that talk to Nextcloud directly (trash, versions, share,
# notifications, lock, ...) use these helpers instead of calling curl with
# their own flag set. The module keeps a plain-text mindset: OCS responses
# are requested as XML, parsed with awk, and never require jq.
#
# Contract:
#   - http_remote_info derives HTTP_BASE/HTTP_USER/HTTP_*_ROOT from the
#     rclone remote and dies when it is not a Nextcloud WebDAV remote.
#   - http_curl streams a response body to stdout and records HTTP_CODE
#     (000 on transport failure), HTTP_ERROR, HTTP_HEADERS_FILE,
#     HTTP_BODY_FILE, and HTTP_RETRY_AFTER. The app password travels in a
#     mode-600 netrc temp file, never in the curl argv. The body/headers/err
#     and netrc files are created once per process and reused.
#   - http_request wraps http_curl, captures the body in HTTP_BODY, and
#     dies on transport failures and 4xx/5xx with an actionable hint unless
#     http_request_allow is used instead.
#   - ocs_request adds the OCS headers and prefixes the OCS root.

# shellcheck disable=SC2034  # HTTP_* globals are this module's output contract

# HTTP_TIMEOUT/HTTP_RETRIES/HTTP_RETRY_DELAY/HTTP_FOLLOW_REDIRECTS/
# HTTP_MAX_REDIRS default in config/settings.env (read by load_settings); the
# ${VAR:-default} fallbacks at each call site below cover a caller that never
# ran load_settings (unit tests, direct sourcing) with the same defaults.

HTTP_BASE=""
HTTP_USER=""
HTTP_DAV_ROOT=""
HTTP_FILES_ROOT=""
HTTP_OCS_ROOT=""
HTTP_CODE=""
HTTP_RC=""
HTTP_ERROR=""
HTTP_BODY=""
HTTP_HEADERS_FILE=""
HTTP_RETRY_AFTER=""
HTTP_BODY_FILE=""

# The plain app password resolved for this process, so every request after the
# first avoids re-running the Keychain/config lookup chain. It is invalidated
# by http_secret_invalidate when the credential changes in-process.
HTTP_SECRET_CACHE=""

# Per-process curl temp files (top-level shell only). _http_temp_init creates
# them once, lazily, and every request reuses them, so the hot path does not
# fork mktemp/rm four times. They stay registered in SCIEBO_TEMP_FILES, so a
# signal still removes them; a command-substitution subshell uses per-call
# files instead (see _http_select_temp_files) because it cannot register in
# the parent.
_HTTP_BODY_FILE=""
_HTTP_ERR_FILE=""
_HTTP_NETRC_FILE=""
_HTTP_TEMP_READY=""

# http_require_curl - die when curl is not available.
http_require_curl() {
  have curl || die "curl is required to talk to Nextcloud but was not found in PATH"
}

# http_origin URL - print scheme://host[:port] of URL, or nothing when URL has
# no authority. Used to keep server-supplied absolute links on the configured
# origin instead of letting them point at another host (SSRF/credential leak).
http_origin() {
  local url="$1" rest="" scheme="" host=""
  case "$url" in
    *://*) ;;
    *) return 0 ;;
  esac
  scheme="${url%%://*}"
  rest="${url#*://}"
  host="${rest%%/*}"
  printf '%s://%s' "$scheme" "$host"
}

# http_remote_info - derive the server endpoints from the configured rclone
# remote. Dies when the remote is not configured or not a Nextcloud WebDAV
# remote. Idempotent: repeated calls keep the first result. The base
# derivation itself is rclone.sh's remote_nextcloud_base (the single
# implementation; both files are sourced eagerly by lib/sciebo.sh, in an
# order where rclone.sh precedes this one).
http_remote_info() {
  [[ -n "$HTTP_BASE" ]] && return 0
  local show="" url="" base=""
  show=${ remote_config_show;} || show=""
  url="$(config_value url "$show")"
  HTTP_USER="$(config_value user "$show")"
  [[ -n "$url" && -n "$HTTP_USER" ]] ||
    die "rclone remote '${RCLONE_REMOTE}:' is not configured (url/user missing); run '${CLI_NAME} setup' first"
  case "$HTTP_USER" in
    *[[:space:]]* | *[[:cntrl:]]*)
      die "rclone remote '${RCLONE_REMOTE}:' has an invalid user name; re-run '${CLI_NAME} setup'"
      ;;
  esac
  case "$url" in
    *[[:space:]]* | *[[:cntrl:]]*)
      die "rclone remote '${RCLONE_REMOTE}:' has an invalid URL; re-run '${CLI_NAME} setup'"
      ;;
  esac
  case "$url" in
    *"/remote.php/dav/files/"*) ;;
    *) die "remote '${RCLONE_REMOTE}:' is not a Nextcloud WebDAV remote (url: $(printable "$url")); run '${CLI_NAME} setup' first" ;;
  esac
  base=${ remote_nextcloud_base "$url";} || base=""
  [[ -n "$base" ]] || die "cannot derive the server base from remote url '$(printable "$url")'"
  HTTP_BASE="$base"
  HTTP_DAV_ROOT="${base}/remote.php/dav"
  HTTP_FILES_ROOT="${HTTP_DAV_ROOT}/files/${HTTP_USER}"
  HTTP_OCS_ROOT="${base}/ocs/v2.php"
}

# http_secret_invalidate - forget the cached plain app password, so the next
# request resolves the credential again. Called after an in-process Keychain
# (keychain_store_plain) or rclone-config (remote_config_invalidate) write.
http_secret_invalidate() {
  HTTP_SECRET_CACHE=""
}

# http_secret - print the plain app password or die. The credential is
# resolved once per process: remote_secret_plain runs through a forkless
# command substitution, so its own per-process caches persist and the chain of
# Keychain/config lookups and their forks does not run again per request.
http_secret() {
  if [[ -n "$HTTP_SECRET_CACHE" ]]; then
    printf '%s' "$HTTP_SECRET_CACHE"
    return 0
  fi
  local secret=""
  secret=${ remote_secret_plain;} || secret=""
  [[ -n "$secret" ]] ||
    die "remote '${RCLONE_REMOTE}:' has no app password (Keychain or rclone config); run '${CLI_NAME} setup' first"
  HTTP_SECRET_CACHE="$secret"
  printf '%s' "$secret"
}

# _http_netrc_quote_into VAR VALUE - forkless netrc_quote: escape VALUE into
# VAR (a nameref) instead of printing it, so http_curl does not fork a
# subshell on every request. The `${ ...; }` capture runs netrc_quote in the
# caller's shell (Bash 5.3), so no subshell is spawned and the control-byte
# refusal and exact escaping stay in core's netrc_quote. Returns 1 on a
# control byte, like netrc_quote; VAR is then left empty.
_http_netrc_quote_into() {
  local -n out="$1"
  out=""
  out=${ netrc_quote "${2:-}";}
}

# http_scrub_secrets TEXT - redact credentials curl can echo into its verbose
# or error output: Authorization/Proxy-Authorization/Cookie/Set-Cookie header
# values and userinfo embedded in URLs. Applied to HTTP_ERROR so --debug and
# support bundles never carry the app password. C0/DEL, encoded/stray C1
# bytes, and invalid UTF-8 are stripped too through the shared
# _AWK_CTRL_LIB (ctrl_strip with KEEP=0, so TAB is folded and valid
# multi-byte error text survives), so a curl error line cannot inject
# terminal escapes.
http_scrub_secrets() {
  printf '%s' "$1" | LC_ALL=C awk "${_AWK_CTRL_LIB}"'
    {
      line = $0
      gsub(/[Aa]uthorization:[^\r]*/, "Authorization: REDACTED", line)
      gsub(/[Pp]roxy-[Aa]uthorization:[^\r]*/, "Proxy-Authorization: REDACTED", line)
      gsub(/[Ss]et-[Cc]ookie:[^\r]*/, "Set-Cookie: REDACTED", line)
      gsub(/[Cc]ookie:[^\r]*/, "Cookie: REDACTED", line)
      gsub(/:\/\/[^\/@ ]+:[^\/@ ]+@/, "://REDACTED@", line)
      print ctrl_strip(line, 0)
    }'
}

# _http_discard_all FILE... - temp_discard every argument; used to unwind the
# temp files created part-way through _http_select_temp_files without
# repeating the list.
_http_discard_all() {
  local file
  for file in "$@"; do
    temp_discard "$file"
  done
}

# _http_discard_persistent - discard the per-process temp set and clear the
# _HTTP_* bookkeeping, so a later call rebuilds the files instead of reusing
# paths that no longer exist. Used on the unwind paths that abandon the
# persistent set (_http_prepare_secrets's abort arms and _http_temp_init
# failures); the paths still die today, but the reset keeps a future non-fatal
# return honest.
_http_discard_persistent() {
  _http_discard_all "$_HTTP_BODY_FILE" "$HTTP_HEADERS_FILE" "$_HTTP_ERR_FILE" "$_HTTP_NETRC_FILE" \
    "$_HTTP_KEY_CONFIG_FILE"
  _HTTP_BODY_FILE=""
  _HTTP_ERR_FILE=""
  _HTTP_NETRC_FILE=""
  _HTTP_KEY_CONFIG_FILE=""
  _HTTP_KEY_QUOTED=""
  HTTP_HEADERS_FILE=""
  HTTP_BODY_FILE=""
  _HTTP_TEMP_READY=""
}

# _http_abort_temps PERSISTENT BODY HEADERS ERR NETRC - unwind the temp set
# after a failed request setup. The persistent set is discarded through the
# global reset; per-call files (a command-substitution subshell) are removed
# individually.
_http_abort_temps() {
  local persistent="$1"
  shift
  if [[ "$persistent" == "1" ]]; then
    _http_discard_persistent
  else
    _http_discard_all "$@"
  fi
}

# _http_proxy_args TLS_VAR VER_VAR FLAG_VAR VALUE_VAR ENV_VAR - resolve the
# TLS/HTTP-version and proxy curl flags for the current settings through the
# named out-params. TLS_INSECURE=1 warns once per process and yields -k;
# HTTP2_ENABLED=0 yields --http1.1. The PROXY_TYPE/PROXY/PROXY_DIRECT decision
# comes from the shared _proxy_classify (lib/adapters/proxy.sh): an explicit http:// or
# https:// PROXY is exported to the child curl (HTTP_PROXY/HTTPS_PROXY/
# ALL_PROXY) via ENV_VAR instead of passed as -x, so its credentials never
# reach ps; a socks5:// PROXY keeps -x (the documented residual) because socks
# support through the environment is not guaranteed across proxy stacks.
# --noproxy carries no credentials and stays a flag pair. Runs in the caller's
# shell so the TLS warning and the die on a missing PROXY are not lost to a
# subshell.
_http_proxy_args() {
  local -n out_tls="$1" out_ver="$2" out_flag="$3" out_value="$4" out_env="$5"
  out_tls="" out_ver="" out_flag="" out_value="" out_env=""
  if [[ "${TLS_INSECURE:-0}" == "1" && "${_HTTP_TLS_WARNED:-0}" != "1" ]]; then
    warn "TLS certificate verification is disabled (--trust); this connection is not authenticated"
    _HTTP_TLS_WARNED=1
  fi
  [[ "${TLS_INSECURE:-0}" == "1" ]] && out_tls="-k"
  [[ "${HTTP2_ENABLED:-1}" == "0" ]] && out_ver="--http1.1"
  local proxy_class="" proxy_url="" proxy_error=""
  _proxy_classify proxy_class proxy_url proxy_error \
    "${PROXY_TYPE:-system}" "${PROXY:-}" "${PROXY_DIRECT:-0}"
  [[ -z "$proxy_error" ]] || die "$proxy_error"
  case "$proxy_class" in
    none)
      out_flag="--noproxy"
      out_value="*"
      ;;
    env) out_env="$proxy_url" ;;
    flag)
      out_flag="-x"
      out_value="$proxy_url"
      ;;
  esac
}

# _http_temp_init - create the per-process curl temp files once and reuse
# them for every request in this process: body, response headers, stderr, and
# the mode-600 netrc. Each is registered once with temp_mktemp_into, so a
# signal still removes it. The netrc mode is set here, once. Only the
# top-level process shell persists these files (BASHPID == $$); a
# command-substitution subshell cannot register cleanup in the parent, so
# http_curl uses per-call files there instead.
_http_temp_init() {
  [[ -n "$_HTTP_TEMP_READY" ]] && return 0
  temp_mktemp_into _HTTP_BODY_FILE "${TMPDIR:-/tmp}/sciebo-http-body.XXXXXX" || {
    _http_discard_persistent
    die "cannot create temp file"
  }
  temp_mktemp_into HTTP_HEADERS_FILE "${TMPDIR:-/tmp}/sciebo-http-head.XXXXXX" || {
    _http_discard_persistent
    die "cannot create temp file"
  }
  temp_mktemp_into _HTTP_ERR_FILE "${TMPDIR:-/tmp}/sciebo-http-err.XXXXXX" || {
    _http_discard_persistent
    die "cannot create temp file"
  }
  temp_mktemp_into _HTTP_NETRC_FILE "${TMPDIR:-/tmp}/sciebo-http-netrc.XXXXXX" || {
    _http_discard_persistent
    die "cannot create temp file"
  }
  chmod 600 "$_HTTP_NETRC_FILE" 2>/dev/null || true
  # The client-key passphrase --config file is part of the per-process set
  # too, so it is registered for cleanup once and reused; it is only created
  # when a passphrase is set (otherwise no --config flag is advertised).
  if [[ -n "${CLIENT_KEY_PASSWORD:-}" ]]; then
    temp_mktemp_into _HTTP_KEY_CONFIG_FILE "${TMPDIR:-/tmp}/sciebo-http-key.XXXXXX" || {
      _http_discard_persistent
      die "cannot create temp file"
    }
    chmod 600 "$_HTTP_KEY_CONFIG_FILE" 2>/dev/null || true
  fi
  HTTP_BODY_FILE="$_HTTP_BODY_FILE"
  _HTTP_TEMP_READY=1
}

# _http_use_persistent - true in the top-level process shell, the only place
# that can register the persistent temp files for exit cleanup (BASHPID equals
# $$ there; a command-substitution or ( ) subshell differs).
_http_use_persistent() {
  [[ "$BASHPID" == "$$" ]]
}

# _http_write_netrc SECRET NETRC_FILE - write the machine/login line for
# HTTP_BASE/HTTP_USER and SECRET into NETRC_FILE, truncating it first, through
# the shared netrc_write_into (which escapes SECRET and derives the bare host).
# The password never reaches the curl argv, and a write problem is fatal.
_http_write_netrc() {
  local secret="$1" netrc_file="$2" out=""
  netrc_write_into out "$HTTP_BASE" "$HTTP_USER" "$secret" "$netrc_file" ||
    die "cannot write temp file"
}

# _HTTP_KEY_CONFIG_FILE - path of the mode-600 curl --config temp file that
# carries CLIENT_KEY_PASSWORD; empty until a passphrase is set. The file is
# created once per process (in _http_temp_init when a passphrase is already
# set, else lazily) and reused, so the hot path does not mktemp/rm per request.
# A persistent _http_exec empties it after every request, so between requests it
# holds no passphrase while the path stays registered for exit cleanup.
_HTTP_KEY_CONFIG_FILE=""

# _HTTP_KEY_QUOTED - the plaintext passphrase currently written to
# _HTTP_KEY_CONFIG_FILE ("" when none is written, including between requests:
# _http_exec empties the file and clears this so the next request rewrites it).
# Used to skip a rewrite while the passphrase is unchanged with one request, and
# to stop advertising --config once it is unset.
_HTTP_KEY_QUOTED=""

# curl_key_pass_config_into VAR PASS [PATH] - write the client-key passphrase
# as a curl `pass = "..."` config line: the single source for the login flow,
# the capabilities probe, and the persistent http --config file. Rejects a
# PASS containing a control byte (rc 1, nothing written). Backslash and double
# quote are escaped, so the value cannot terminate the quoted string or inject
# a second directive. Without PATH a fresh mode-600 temp is created via
# temp_mktemp_into (registered for exit cleanup) and VAR is set to its path;
# with PATH the caller-provided file is truncated and rewritten (the caller
# owns its lifecycle and cleanup), so a persistent per-process config file can
# be reused. A creation or write failure returns 2. Returns 0 on success, and
# the passphrase never reaches an argv.
curl_key_pass_config_into() {
  local -n _ckp_out="$1"
  local pass="${2-}" target="${3-}" escaped="" file=""
  case "$pass" in
    *[[:cntrl:]]*) return 1 ;;
  esac
  escaped="${pass//\\/\\\\}"
  escaped="${escaped//\"/\\\"}"
  if [[ -n "$target" ]]; then
    if ! (umask 077 && printf 'pass = "%s"\n' "$escaped" >"$target"); then
      return 2
    fi
    chmod 600 "$target" 2>/dev/null || true
    _ckp_out="$target"
    return 0
  fi
  temp_mktemp_into file "${TMPDIR:-/tmp}/sciebo-curl-key.XXXXXX" || return 2
  if ! (umask 077 && printf 'pass = "%s"\n' "$escaped" >"$file"); then
    temp_discard "$file"
    return 2
  fi
  chmod 600 "$file" 2>/dev/null || true
  _ckp_out="$file"
  return 0
}

# curl_client_args_into ARRAY_NAME [--config PATH] - append the shared curl
# client flags to the array named by ARRAY_NAME (a nameref), in this order:
# --cert/--key when CLIENT_CERT/CLIENT_KEY are set, --cacert when CA_CERT is
# set, -A when USER_AGENT is set, and --config PATH when one is passed. Each
# flag is its own argv entry, so paths and user-agent strings may contain
# spaces. The client-key passphrase travels through the caller's mode-600
# --config file and never reaches the argv.
curl_client_args_into() {
  local -n _cca_out="$1"
  shift
  local config_path=""
  if [[ "${1:-}" == "--config" ]]; then
    config_path="${2:-}"
  fi
  [[ -z "${CLIENT_CERT:-}" ]] || _cca_out+=(--cert "$CLIENT_CERT")
  [[ -z "${CLIENT_KEY:-}" ]] || _cca_out+=(--key "$CLIENT_KEY")
  [[ -z "${CA_CERT:-}" ]] || _cca_out+=(--cacert "$CA_CERT")
  [[ -z "${USER_AGENT:-}" ]] || _cca_out+=(-A "$USER_AGENT")
  [[ -z "$config_path" ]] || _cca_out+=(--config "$config_path")
}

# _http_key_config_write PASS FILE - rewrite the existing per-process
# client-key --config file in place. FILE was already created mode 600 by
# temp_mktemp_into (or by curl_key_pass_config_into), so the hot path needs no
# umask subshell and no chmod; only a missing file is (re)created through
# curl_key_pass_config_into. The escaping and control-byte refusal mirror that
# shared helper (above), so the value still cannot terminate the quoted
# string or inject a second curl directive. rc 1 for a control byte, 2 when the
# write fails.
_http_key_config_write() {
  local pass="${1:-}" file="$2" escaped=""
  case "$pass" in
    *[[:cntrl:]]*) return 1 ;;
  esac
  escaped="${pass//\\/\\\\}"
  escaped="${escaped//\"/\\\"}"
  printf 'pass = "%s"\n' "$escaped" >"$file" || return 2
  return 0
}

# _http_key_password_config - make sure CLIENT_KEY_PASSWORD is written to the
# process's mode-600 curl config file as `pass = "<value>"` and leave its path
# in _HTTP_KEY_CONFIG_FILE, so the client-key passphrase never reaches the curl
# argv. The file is created once per process and rewritten in place when the
# passphrase differs (a request that just ran leaves it empty, so the next
# request rewrites it too); unsetting the passphrase truncates it and drops the
# --config advertisement. A missing path is created through the shared
# curl_key_pass_config_into (which also sets mode 600); an existing one is
# rewritten in place by _http_key_config_write, avoiding the per-request umask
# subshell and chmod. Returns 0 when the file is current (or no passphrase is
# set), 1 for a control byte, and 2 when the temp file cannot be created. The
# persistent file is kept for reuse; a per-call subshell discards it in
# _http_exec.
_http_key_password_config() {
  local pass="${CLIENT_KEY_PASSWORD:-}" rc=0
  if [[ -z "$pass" ]]; then
    # No passphrase: empty the file so a secret does not linger and stop
    # advertising --config (the file stays registered for exit cleanup).
    if [[ -n "$_HTTP_KEY_CONFIG_FILE" && -e "$_HTTP_KEY_CONFIG_FILE" ]]; then
      : >"$_HTTP_KEY_CONFIG_FILE"
    fi
    _HTTP_KEY_QUOTED=""
    return 0
  fi
  if [[ "$pass" == "$_HTTP_KEY_QUOTED" &&
    -n "$_HTTP_KEY_CONFIG_FILE" && -f "$_HTTP_KEY_CONFIG_FILE" ]]; then
    return 0
  fi
  if [[ -z "$_HTTP_KEY_CONFIG_FILE" || ! -e "$_HTTP_KEY_CONFIG_FILE" ]]; then
    # A missing path (first use, or the file was removed out from under us)
    # gets a fresh registered temp instead of writing to a stale, unregistered
    # path that exit cleanup would not remove.
    curl_key_pass_config_into _HTTP_KEY_CONFIG_FILE "$pass" || rc=$?
  else
    # The path already exists and is mode 600 (temp_mktemp_into), so rewrite it
    # in place without the umask subshell and chmod curl_key_pass_config_into
    # would run.
    _http_key_config_write "$pass" "$_HTTP_KEY_CONFIG_FILE" || rc=$?
  fi
  if [[ "$rc" -eq 0 ]]; then
    _HTTP_KEY_QUOTED="$pass"
    return 0
  fi
  if [[ "$rc" -ne 1 ]]; then
    temp_discard "${_HTTP_KEY_CONFIG_FILE:-}"
    _HTTP_KEY_CONFIG_FILE=""
    _HTTP_KEY_QUOTED=""
  fi
  return "$rc"
}

# _http_method_of METHOD_VAR CURL_ARGS... - resolve the effective HTTP method
# from the curl argv into METHOD_VAR (a nameref): -X/--request NAME and
# -I/--head decide it explicitly, and a data flag turns an unset/GET method
# into a POST. The scan is left to right so a later -X overrides an earlier
# data flag (and vice versa), exactly like curl.
_http_method_of() {
  local -n out_method="$1"
  shift
  local arg="" next=0 i=0
  out_method="GET"
  for ((i = 1; i <= $#; i++)); do
    arg="${!i}"
    case "$arg" in
      -X | --request)
        next=$((i + 1))
        [[ "$next" -le $# ]] && out_method="${!next}"
        ;;
      -I | --head) out_method="HEAD" ;;
      --data | --data-binary | --data-raw | --data-urlencode | --json)
        [[ "$out_method" == "GET" ]] && out_method="POST"
        ;;
    esac
  done
}

# _http_client_args ARRAY_VAR - fill ARRAY_VAR (a nameref to an array) with the
# mutual-TLS, custom-CA, --config, and User-Agent flags. Each flag is its own
# argv entry so paths and user-agent strings may contain spaces. The
# client-key passphrase travels through the mode-600 --config file built by
# _http_key_password_config, never in the argv (ps-visible) like --pass.
_http_client_args() {
  local -n out_args="$1"
  out_args=()
  # Only advertise the --config file while a passphrase is actually written to
  # it; unsetting CLIENT_KEY_PASSWORD truncates the file and clears the flag.
  if [[ -n "${_HTTP_KEY_QUOTED:-}" && -n "${_HTTP_KEY_CONFIG_FILE:-}" ]]; then
    curl_client_args_into out_args --config "$_HTTP_KEY_CONFIG_FILE"
  else
    curl_client_args_into out_args
  fi
}

# _http_publish_response RC CODE ERR_FILE - publish the last curl result in the
# HTTP_* globals: HTTP_RC, the status HTTP_CODE ("000" on transport failure),
# the scrubbed HTTP_ERROR read from ERR_FILE, and HTTP_RETRY_AFTER (429/503
# only). The header and error files are only read when they can carry
# something.
_http_publish_response() {
  local rc="$1" code="$2" err_file="$3"
  HTTP_RC="$rc"
  if [[ "$rc" -ne 0 ]]; then
    HTTP_CODE="000"
  else
    HTTP_CODE="${code:-000}"
  fi
  # Retry-After only matters for the throttling/unavailable statuses, so the
  # header file is not scanned on the hot path.
  HTTP_RETRY_AFTER=""
  case "$HTTP_CODE" in
    429 | 503) HTTP_RETRY_AFTER="${ trim "$(http_header 'Retry-After')";}" ;;
  esac
  # An empty stderr carries no transport diagnostics, so the scrub is skipped.
  if [[ -s "$err_file" ]]; then
    HTTP_ERROR="$(http_scrub_secrets "$(<"$err_file")")"
  else
    HTTP_ERROR=""
  fi
}

# _http_follow_args METHOD ARRAY_VAR - fill ARRAY_VAR (a nameref to an array)
# with the redirect-following curl flags. Redirects are only safe to follow
# for read-only methods: curl turns a redirected POST into a GET, which would
# silently drop the body. GET/HEAD follow up to HTTP_MAX_REDIRS hops; writes
# leave a 3xx for the caller.
_http_follow_args() {
  local method="$1"
  local -n out_follow="$2"
  out_follow=()
  if [[ "${HTTP_FOLLOW_REDIRECTS:-1}" == "1" ]]; then
    case "$method" in
      GET | HEAD) out_follow=(-L --max-redirs "${HTTP_MAX_REDIRS:-5}") ;;
    esac
  fi
}

# _http_run_curl BODY ERR NETRC TLS VER PROXY_FLAG PROXY_VALUE PROXY_ENV
# CURL_ARGS... - assemble the curl argv (client args, method-derived redirect
# flags) and run curl, printing the status code (%{http_code}) to stdout;
# returns curl's exit status. _http_exec captures this function inside its
# if-condition, so the whole body runs in the command substitution: the
# optional proxy export there isolates the child, and the parent shell keeps
# whatever proxy environment it had.
_http_run_curl() {
  local body_file="$1" err_file="$2" netrc_file="$3"
  local tls_flag="$4" http_ver_flag="$5"
  local proxy_flag="$6" proxy_value="$7" proxy_env="$8"
  shift 8
  local method=""
  local -a follow=() client_args=()
  _http_client_args client_args
  _http_method_of method "$@"
  _http_follow_args "$method" follow
  if [[ -n "$proxy_env" ]]; then
    export HTTP_PROXY="$proxy_env" HTTPS_PROXY="$proxy_env" ALL_PROXY="$proxy_env"
  fi
  curl -sS --max-time "${HTTP_TIMEOUT:-30}" --connect-timeout "${HTTP_CONNECT_TIMEOUT:-15}" \
    --retry "${HTTP_RETRIES:-2}" --retry-delay "${HTTP_RETRY_DELAY:-1}" --retry-all-errors --retry-connrefused \
    ${follow[@]+"${follow[@]}"} \
    ${tls_flag:+"$tls_flag"} ${http_ver_flag:+"$http_ver_flag"} ${SCIEBO_DEBUG:+-v} \
    ${client_args[@]+"${client_args[@]}"} \
    ${proxy_flag:+"$proxy_flag"} ${proxy_value:+"$proxy_value"} \
    --netrc-file "$netrc_file" -D "$HTTP_HEADERS_FILE" -o "$body_file" \
    -w '%{http_code}' "$@" 2>"$err_file"
}

# _http_exec BODY ERR NETRC PERSISTENT TLS VER PROXY_FLAG PROXY_VALUE PROXY_ENV
# CURL_ARGS... - run the request and publish the result: _http_run_curl does
# the curl call (streaming the body to stdout unless the caller set
# _HTTP_STREAM_BODY=0), _http_publish_response records the status code and
# scrubbed transport error in HTTP_CODE ("000" on transport failure),
# HTTP_ERROR, HTTP_RC and HTTP_RETRY_AFTER, and _http_release_temps publishes
# HTTP_BODY_FILE and releases the temp set (PERSISTENT=1 keeps the per-process
# files for reuse; PERSISTENT=0 removes the per-call files). Returns curl's
# exit status. HTTP_HEADERS_FILE is read from the module global set by the
# caller.
_http_exec() {
  local body_file="$1" err_file="$2" netrc_file="$3" persistent="$4"
  local tls_flag="$5" http_ver_flag="$6"
  local proxy_flag="$7" proxy_value="$8" proxy_env="$9"
  shift 9
  local code="" rc=0
  if code="$(_http_run_curl "$body_file" "$err_file" "$netrc_file" \
    "$tls_flag" "$http_ver_flag" "$proxy_flag" "$proxy_value" "$proxy_env" "$@")"; then
    rc=0
  else
    rc=$?
  fi
  _http_publish_response "$rc" "$code" "$err_file"
  _http_release_temps "$persistent" "$body_file" "$err_file" "$netrc_file"
  return "$rc"
}

# _http_release_temps PERSISTENT BODY ERR NETRC - finish the request after
# _http_publish_response has read the err/header files: publish HTTP_BODY_FILE,
# stream the body to stdout unless _HTTP_STREAM_BODY=0, and release the temp
# set. The original order matters and is kept exactly: secret files first
# (while the persistent set still holds its paths), then the body stream, then
# the per-call body/headers removal - so per-call cleanup never runs before
# the body has been read.
_http_release_temps() {
  local persistent="$1" body_file="$2" err_file="$3" netrc_file="$4"
  if [[ "$persistent" == "1" ]]; then
    # Reuse the per-process files; empty the netrc and the client-key --config
    # file so neither secret lingers between requests (the paths stay
    # registered for cleanup). Clearing _HTTP_KEY_QUOTED makes
    # _http_key_password_config rewrite the passphrase for the next request
    # instead of trusting the now-empty file.
    : >"$err_file"
    : >"$netrc_file"
    if [[ -n "${_HTTP_KEY_CONFIG_FILE:-}" && -e "$_HTTP_KEY_CONFIG_FILE" ]]; then
      : >"$_HTTP_KEY_CONFIG_FILE"
    fi
    _HTTP_KEY_QUOTED=""
  else
    temp_discard "$err_file"
    temp_discard "$netrc_file"
    temp_discard "${_HTTP_KEY_CONFIG_FILE:-}"
    _HTTP_KEY_CONFIG_FILE=""
    _HTTP_KEY_QUOTED=""
  fi
  HTTP_BODY_FILE="$body_file"
  if [[ "${_HTTP_STREAM_BODY:-1}" == "1" ]]; then
    cat "$body_file"
  fi
  if [[ "$persistent" != "1" ]]; then
    temp_discard "$body_file"
    temp_discard "$HTTP_HEADERS_FILE"
  fi
}

# _http_select_temp_files PERSISTENT BODY ERR NETRC - out-params (namerefs)
# that select the temp set for one request. PERSISTENT=1 in the top-level
# process shell, where _http_temp_init creates the per-process files once and
# this request truncates them (so a previous call's body/headers/stderr cannot
# bleed into it; the headers stay valid until the next request starts).
# Otherwise PERSISTENT=0 with per-call files, because a command-substitution
# subshell cannot register its temp files with the parent's exit cleanup
# (_http_release_temps removes them instead). The escalating cleanup pattern
# matters: when one temp_mktemp_into fails mid-way, every file created before
# it is discarded first, so a half-built set is never left behind. This runs
# after the secret quote (a refused password dies before any file exists) and
# before any secret is written.
_http_select_temp_files() {
  local -n out_persistent="$1" out_body="$2" out_err="$3" out_netrc="$4"
  if _http_use_persistent; then
    # Reuse the per-process files. Truncate at the start of every request so a
    # previous call's body/headers/stderr cannot bleed into this one; the
    # headers stay valid until the next request starts.
    out_persistent=1
    _http_temp_init
    out_body="$_HTTP_BODY_FILE"
    out_err="$_HTTP_ERR_FILE"
    out_netrc="$_HTTP_NETRC_FILE"
    : >"$out_body"
    : >"$HTTP_HEADERS_FILE"
    : >"$out_err"
  else
    # A command-substitution subshell cannot register its temp files with the
    # parent's exit cleanup, so it uses per-call files that _http_exec removes.
    temp_mktemp_into out_body "${TMPDIR:-/tmp}/sciebo-http-body.XXXXXX" ||
      die "cannot create temp file"
    temp_mktemp_into HTTP_HEADERS_FILE "${TMPDIR:-/tmp}/sciebo-http-head.XXXXXX" || {
      _http_discard_all "$out_body"
      die "cannot create temp file"
    }
    temp_mktemp_into out_err "${TMPDIR:-/tmp}/sciebo-http-err.XXXXXX" || {
      _http_discard_all "$out_body" "$HTTP_HEADERS_FILE"
      die "cannot create temp file"
    }
    temp_mktemp_into out_netrc "${TMPDIR:-/tmp}/sciebo-http-netrc.XXXXXX" || {
      _http_discard_all "$out_body" "$HTTP_HEADERS_FILE" "$out_err"
      die "cannot create temp file"
    }
    chmod 600 "$out_netrc" 2>/dev/null || true
  fi
}

# _http_prepare_secrets PASS PERSISTENT BODY ERR NETRC - write this request's
# secrets into the set selected by _http_select_temp_files: the mode-600 netrc
# through _http_write_netrc, then the client-key passphrase (when set) into
# its mode-600 --config file through _http_key_password_config. A failure
# aborts the selected set first - per-call files individually, the persistent
# set through the global reset - so a partially prepared set is unwound the
# same way it was built, and only then dies with the original message.
_http_prepare_secrets() {
  local pass="$1" persistent="$2" body_file="$3" err_file="$4" netrc_file="$5"
  local key_rc=0
  _http_write_netrc "$pass" "$netrc_file"
  # The client-key passphrase (when set) goes into its own mode-600 --config
  # file; the helper rejects a control byte because curl's config parser cannot
  # carry one, rather than falling back to --pass in the argv.
  _http_key_password_config || key_rc=$?
  case "$key_rc" in
    0) ;;
    1)
      _http_abort_temps "$persistent" "$body_file" "$HTTP_HEADERS_FILE" "$err_file" "$netrc_file" \
        "${_HTTP_KEY_CONFIG_FILE:-}"
      die "the client key passphrase contains a control character and cannot be sent safely; check CLIENT_KEY_PASSWORD"
      ;;
    *)
      _http_abort_temps "$persistent" "$body_file" "$HTTP_HEADERS_FILE" "$err_file" "$netrc_file" \
        "${_HTTP_KEY_CONFIG_FILE:-}"
      die "cannot create temp file"
      ;;
  esac
}

# http_curl CURL_ARGS... - run an authenticated curl request with the
# configured timeout and retries. The app password travels through a mode-600
# netrc temp file (--netrc-file); only a password with control bytes is
# refused instead of falling back to -u. The body goes to stdout (or is left
# in HTTP_BODY_FILE for callers that read it directly); response headers are
# stored in HTTP_HEADERS_FILE, the status code in HTTP_CODE ("000" on
# transport failure), the transport error text in HTTP_ERROR, the Retry-After
# header value (429/503 only) in HTTP_RETRY_AFTER, and the curl exit status in
# HTTP_RC (also the return value). HTTP 4xx/5xx responses are not errors here;
# callers decide what they mean. HTTP_CONNECT_TIMEOUT (default 15) bounds the
# connect phase, HTTP2_ENABLED=0 forces HTTP/1.1, and the PROXY/PROXY_DIRECT
# settings select the proxy behavior. CLIENT_CERT/CLIENT_KEY add --cert/--key,
# CA_CERT adds --cacert, and USER_AGENT adds -A when set. CLIENT_KEY_PASSWORD
# is written to a mode-600 --config file, so the passphrase stays out of the
# argv. In the top-level shell the body/headers/err/netrc and client-key
# --config files are created once and reused across requests, and the two
# secret-carrying files (netrc, client-key --config) are emptied after every
# request; a subshell uses per-call files because it cannot hand the cleanup
# registration to the parent process. Setup is split into
# _http_select_temp_files (temp-set selection) and _http_prepare_secrets
# (netrc/key-config write with their abort paths); this function keeps the
# secret resolution and the dispatch.
http_curl() {
  local pass="" body_file="" err_file="" netrc_file="" quoted="" persistent=0
  local tls_flag="" http_ver_flag="" proxy_flag="" proxy_value="" proxy_env=""
  [[ -n "$HTTP_USER" ]] || http_remote_info
  # Forkless: http_secret keeps its per-process cache in this shell, so only
  # the first request in the process resolves the credential chain.
  pass=${ http_secret;}
  _http_proxy_args tls_flag http_ver_flag proxy_flag proxy_value proxy_env
  # The password always travels in a mode-600 netrc file, never in the curl
  # argv (ps-visible). A control character cannot be represented in netrc, so
  # such a password is refused instead of falling back to -u. The quote runs
  # forklessly in this shell (no per-request command-substitution subshell).
  # It deliberately stays before _http_select_temp_files: a refused password
  # must die before any temp file is created, truncated, or registered.
  _http_netrc_quote_into quoted "$pass" ||
    die "the app password contains a control character and cannot be sent safely; rotate it with '${CLI_NAME} setup --rotate'"
  _http_select_temp_files persistent body_file err_file netrc_file
  _http_prepare_secrets "$pass" "$persistent" "$body_file" "$err_file" "$netrc_file"
  _http_exec "$body_file" "$err_file" "$netrc_file" "$persistent" "$tls_flag" "$http_ver_flag" \
    "$proxy_flag" "$proxy_value" "$proxy_env" "$@"
}

# _http_status_hint CODE RETRY_AFTER - one-line next-step hint for the HTTP
# statuses this tooling can explain; prints nothing for everything else.
# RETRY_AFTER is the Retry-After header value when the response carried one.
_http_status_hint() {
  local code="$1" retry_after="${2:-}" hint=""
  # Retry-After is server-controlled; strip control bytes before it can reach
  # the terminal through the hint.
  retry_after="$(printable "$retry_after")"
  case "$code" in
    400) hint="the server rejected the request; check the remote path and the request body" ;;
    401) hint="the app password may have expired or been revoked; run '${CLI_NAME} setup --rotate' to replace it" ;;
    403) hint="the account may not have permission for this action; check sharing and file permissions in Nextcloud" ;;
    409) hint="the server reported a conflict; the file or folder may have changed on the server" ;;
    412) hint="the file changed on the server (ETag mismatch); re-fetch it and retry" ;;
    413) hint="the upload is too large; lower CHUNK_SIZE or raise the server's upload limit" ;;
    415) hint="the server refused the content type; check the file and the server configuration" ;;
    423) hint="the file is locked; run '${CLI_NAME} locks' to list locks or '${CLI_NAME} unlock <path>' to release one" ;;
    429) hint="the server is rate limiting requests" ;;
    502) hint="the server gateway returned an invalid response" ;;
    503) hint="the server is temporarily unavailable" ;;
    504) hint="the server gateway timed out" ;;
    507) hint="the server storage or quota is full" ;;
    *) return 0 ;;
  esac
  case "$code" in
    429 | 503)
      if [[ -n "$retry_after" ]]; then
        hint="${hint}; Retry-After: ${retry_after}"
      else
        hint="${hint}; retry later"
      fi
      ;;
  esac
  printf '%s' "$hint"
}

# http_error_message BODY - best-effort human message from an OCS/DAV error
# body: the OCS <message>, else the DAV <d:responsedescription>, else empty.
http_error_message() {
  local body="$1" message=""
  message="$(printf '%s' "$body" | LC_ALL=C awk "${_AWK_XML_LIB}"'
    { doc = doc $0 }
    END {
      val = xml_extract(doc, "message")
      if (val == "") val = xml_extract(doc, "d:responsedescription")
      print val
    }
  ')"
  # The message comes from the server; decode entities, then drop stray C1
  # bytes with the UTF-8-aware strip_control_bytes (a hostile entity such as
  # &#155; must not inject an 8-bit CSI) and finally C0/DEL/CR with
  # sanitize_stream, so a hostile response cannot inject terminal escapes.
  # Output for normal text is unchanged.
  message="$(strip_control_bytes "$(xml_unescape "$message")")"
  printf '%s' "$message" | sanitize_stream
}

# http_die_http_error METHOD URL - die with the HTTP status, the best
# available detail from HTTP_BODY, and the actionable hint for well-known
# statuses (expired app password, permissions, locked files, rate limiting
# with Retry-After, and a full server quota).
http_die_http_error() {
  local method="$1" url="$2" detail="" hint=""
  # The URL is caller/server-influenced; strip control bytes before it reaches
  # the terminal through the die message.
  url="$(printable "$url")"
  detail="$(http_error_message "$HTTP_BODY")"
  hint="$(_http_status_hint "$HTTP_CODE" "${HTTP_RETRY_AFTER:-}")"
  if [[ -n "$detail" && -n "$hint" ]]; then
    die "${method} ${url} failed: HTTP ${HTTP_CODE}: ${detail}; ${hint}"
  fi
  if [[ -n "$detail" ]]; then
    die "${method} ${url} failed: HTTP ${HTTP_CODE}: ${detail}"
  fi
  if [[ -n "$hint" ]]; then
    die "${method} ${url} failed: HTTP ${HTTP_CODE}: ${hint}"
  fi
  die "${method} ${url} failed: HTTP ${HTTP_CODE}"
}

# http_request_allow METHOD URL CURL_ARGS... - like http_request but leaves
# HTTP 4xx/5xx handling to the caller. Still dies on transport failures.
# In the top-level shell the body is read straight from HTTP_BODY_FILE (which
# _http_exec already filled) instead of buffering it through a second temp; a
# subshell, which has no persistent body file, still captures the streamed
# body into a per-call temp. Either way the HTTP_* globals survive.
http_request_allow() {
  local method="$1" url="$2" body_file="" rc=0 display_url=""
  shift 2
  # Keep the request URL intact; only the message copy is stripped of control
  # bytes so it cannot inject terminal escapes.
  display_url="$(printable "$url")"
  if _http_use_persistent; then
    _HTTP_STREAM_BODY=0
    if http_curl -X "$method" "$@" "$url" >/dev/null; then
      rc=0
    else
      rc=$?
    fi
    _HTTP_STREAM_BODY=1
    HTTP_BODY="$(<"$HTTP_BODY_FILE")"
  else
    temp_mktemp_into body_file "${TMPDIR:-/tmp}/sciebo-http-request.XXXXXX" || die "cannot create temp file"
    if http_curl -X "$method" "$@" "$url" >"$body_file"; then
      rc=0
    else
      rc=$?
    fi
    HTTP_BODY="$(<"$body_file")"
    temp_discard "$body_file"
  fi
  if [[ "$rc" -ne 0 ]]; then
    die "${method} ${display_url} failed: ${HTTP_ERROR:-curl exit ${HTTP_RC}}"
  fi
  return 0
}

# http_ok_code CODE - true when CODE is a 2xx or 3xx HTTP status. Used for the
# GET/HEAD requests whose redirects curl follows, so a 3xx there ends up as the
# final response curl hands back.
http_ok_code() {
  case "$1" in
    2* | 3*) return 0 ;;
  esac
  return 1
}

# http_ok_code_2xx CODE - true when CODE is a 2xx HTTP status. Used for the
# methods curl does not follow redirects for (PROPFIND and writes): a 3xx there
# is a redirect with an empty body, not a successful operation.
http_ok_code_2xx() {
  case "$1" in
    2*) return 0 ;;
  esac
  return 1
}

# _http_ok_method METHOD CODE - true when CODE is a success for METHOD: 2xx
# always, plus 3xx for GET/HEAD because curl follows those redirects up to
# HTTP_MAX_REDIRS. Every other method must answer 2xx.
_http_ok_method() {
  case "$1" in
    GET | HEAD) http_ok_code "$2" ;;
    *) http_ok_code_2xx "$2" ;;
  esac
}

# http_request METHOD URL CURL_ARGS... - request and die unless the status is a
# success for METHOD (2xx, or 3xx for a followed GET/HEAD redirect). The
# response body is available in HTTP_BODY.
http_request() {
  http_request_allow "$@"
  if ! _http_ok_method "$1" "$HTTP_CODE"; then
    local method="$1" url="$2"
    http_die_http_error "$method" "$url"
  fi
}

# http_download URL FILE - GET URL and write the body to FILE. Removes a
# partial FILE and dies on any failure.
http_download() {
  local url="$1" file="$2" rc=0 display_url=""
  # Keep the request URL intact; only the message copy is stripped of control
  # bytes so it cannot inject terminal escapes.
  display_url="$(printable "$url")"
  if http_curl "$url" >"$file"; then rc=0; else rc=$?; fi
  if [[ "$rc" -ne 0 || "$HTTP_CODE" == 000 ]]; then
    rm -f "$file"
    die "GET ${display_url} failed: ${HTTP_ERROR:-curl exit ${rc}}"
  fi
  if ! http_ok_code "$HTTP_CODE"; then
    rm -f "$file"
    HTTP_BODY=""
    http_die_http_error GET "$url"
  fi
  return 0
}

# http_fetch_stdout URL NOTFOUND_MESSAGE [CURL_ARGS...] - GET URL and stream
# the body to stdout (binary-safe). Dies on a transport failure with
# "GET ... failed", on HTTP 404 with NOTFOUND_MESSAGE when non-empty (else a
# generic 404 line), and on any other non-2xx/3xx through http_die_http_error.
# Shared by the preview and versions stdout paths.
http_fetch_stdout() {
  local url="$1" notfound="$2" rc=0
  shift 2
  if http_curl "$url" "$@"; then rc=0; else rc=$?; fi
  if [[ "$rc" -ne 0 || "$HTTP_CODE" == "000" ]]; then
    die "GET ${url} failed: ${HTTP_ERROR:-curl exit ${rc}}"
  fi
  case "$HTTP_CODE" in
    2* | 3*) return 0 ;;
    404)
      [[ -z "$notfound" ]] || die "$notfound"
      die "GET ${url} failed: HTTP 404"
      ;;
  esac
  http_die_http_error GET "$url"
}

# http_fetch_to_file URL TARGET NOTFOUND_MESSAGE [CURL_ARGS...] - GET URL into
# a same-directory mode-600 temp file and move it onto TARGET only after a
# 2xx/3xx response, so a failed request never leaves a partial TARGET and a
# previous TARGET survives every failure path. A TARGET that is a symlink is
# refused before the request. Transport failures die with "GET ... failed";
# HTTP 404 dies with NOTFOUND_MESSAGE when non-empty; other non-success
# statuses load the body into HTTP_BODY and die through http_die_http_error.
# When HTTP_FETCH_EMPTY_MSG is set and the successful body is empty, dies with
# that message instead of moving the temp (TARGET keeps its previous content);
# the variable is cleared by every call. Returns 0 on a moved body.
http_fetch_to_file() {
  local url="$1" target="$2" notfound="$3" rc=0 tmp="" empty_msg=""
  shift 3
  empty_msg="${HTTP_FETCH_EMPTY_MSG:-}"
  HTTP_FETCH_EMPTY_MSG=""
  [[ ! -L "$target" ]] || die "refusing to write through symlink: ${target}"
  temp_mktemp_into tmp "${target}.tmp.XXXXXX" ||
    die "cannot create temp file for ${target}"
  if http_curl "$url" "$@" >"$tmp"; then rc=0; else rc=$?; fi
  if [[ "$rc" -ne 0 || "$HTTP_CODE" == "000" ]]; then
    temp_discard "$tmp"
    die "GET ${url} failed: ${HTTP_ERROR:-curl exit ${rc}}"
  fi
  case "$HTTP_CODE" in
    2* | 3*) ;;
    404)
      temp_discard "$tmp"
      [[ -z "$notfound" ]] || die "$notfound"
      die "GET ${url} failed: HTTP 404"
      ;;
    *)
      # shellcheck disable=SC2034  # read by http_die_http_error via HTTP_BODY
      HTTP_BODY="$(<"$tmp")"
      temp_discard "$tmp"
      http_die_http_error GET "$url"
      ;;
  esac
  if [[ -n "$empty_msg" && ! -s "$tmp" ]]; then
    temp_discard "$tmp"
    die "$empty_msg"
  fi
  mv -f "$tmp" "$target" || {
    temp_discard "$tmp"
    die "cannot write ${target}"
  }
  temp_discard "$tmp"
  return 0
}

# ocs_request_allow METHOD PATH CURL_ARGS... - OCS request (path starts with
# "/"); the body is in HTTP_BODY. After a successful call the OCS envelope
# values are in OCS_STATUS/OCS_STATUSCODE/OCS_MESSAGE.
ocs_request_allow() {
  local method="$1" path="$2"
  shift 2
  [[ -n "$HTTP_OCS_ROOT" ]] || http_remote_info
  http_request_allow "$method" "${HTTP_OCS_ROOT}${path}" \
    -H 'OCS-APIRequest: true' -H 'Accept: application/xml' "$@"
  ocs_parse "$HTTP_BODY"
  return 0
}

# ocs_request METHOD PATH CURL_ARGS... - like ocs_request_allow but dies on
# HTTP errors and on an OCS status other than "ok".
ocs_request() {
  ocs_request_allow "$@"
  if ! _http_ok_method "$1" "$HTTP_CODE"; then
    local method="$1" path="$2"
    http_die_http_error "$method" "${HTTP_OCS_ROOT}${path}"
  fi
  [[ "$OCS_STATUS" == "ok" ]] ||
    die "Nextcloud API error ${OCS_STATUSCODE:-?}: ${OCS_MESSAGE:-request failed}"
  return 0
}

# ocs_check_response METHOD URL - die unless the last ocs_request_allow
# result is a success. A 204/304 means an empty collection; HTTP failures
# use the error body, OCS failures the OCS message.
ocs_check_response() {
  local method="$1" url="$2"
  case "$HTTP_CODE" in
    204 | 304) return 0 ;;
  esac
  if ! _http_ok_method "$method" "$HTTP_CODE"; then
    http_die_http_error "$method" "$url"
  fi
  [[ "$OCS_STATUS" == "ok" ]] ||
    die "Nextcloud API error ${OCS_STATUSCODE:-?}: ${OCS_MESSAGE:-request failed}"
  return 0
}

# OCS envelope values, filled by ocs_parse.
OCS_STATUS=""
OCS_STATUSCODE=""
OCS_MESSAGE=""

# ocs_parse XML - extract the OCS envelope. All three tags are pulled in a
# single awk pass (each xml_get call would fork its own printf | awk), with
# the same tag-boundary, self-close, trim, entity-decode and tab-folding rules
# as xml_get. Server-controlled fields that reach the terminal are stripped of
# control bytes here, so every caller is covered. A response without an <ocs>
# envelope leaves the values empty; callers treat that as an error.
ocs_parse() {
  local parsed="" tab=$'\t'
  parsed="$(printf '%s' "$1" | LC_ALL=C awk "${_AWK_XML_LIB}"'
    { doc = doc $0 }
    END { printf "%s\t%s\t%s", xml_extract(doc, "status"), xml_extract(doc, "statuscode"), xml_extract(doc, "message") }
  ')"
  # Split on TAB with parameter expansion, not read: an empty leading field
  # (no <status>) must stay empty instead of shifting the other two columns.
  OCS_STATUS="${parsed%%"$tab"*}"
  parsed="${parsed#*"$tab"}"
  OCS_STATUSCODE=${ printable "${parsed%%"$tab"*}";}
  OCS_MESSAGE=${ printable "${parsed#*"$tab"}";}
}

# http_header NAME - print the value of the response header NAME from the
# last http_curl call (case-insensitive), empty when absent. Pure bash: the
# header file is read line by line, the CR is stripped, and the first
# case-insensitive "name:" match wins, so no tr/awk fork is needed.
http_header() {
  local name="${1:-}" prefix="" line="" lower=""
  [[ -n "$HTTP_HEADERS_FILE" && -f "$HTTP_HEADERS_FILE" ]] || return 0
  prefix="${name,,}:"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    lower="${line,,}"
    if [[ "$lower" == "$prefix"* ]]; then
      printf '%s' "${line:${#prefix}}"
      return 0
    fi
  done <"$HTTP_HEADERS_FILE"
  return 0
}
