#!/bin/bash
# setup.sh command module - create or update the sciebo WebDAV remote.

usage_setup() {
  usage_emit <<'EOF'
Usage: sciebo setup [--login] [--url URL] [--no-keychain] [--rotate]
                    [--proxy URL] [--crypt]

Create or update the rclone remote named by RCLONE_REMOTE (see
config/settings.env) as a Nextcloud WebDAV backend and validate it.

Connection values are taken from the environment, from .env in the
project root, or interactively:

  SCIEBO_URL           Nextcloud base URL, e.g. https://your-university.sciebo.de
                       (any Nextcloud server's base URL works too)
  SCIEBO_USER          sciebo ID, e.g. alice@your-university.de (a plain
                       Nextcloud username works too)
  SCIEBO_APP_PASSWORD  app password (Settings > Security > Devices & sessions)

Options:
  --login       authenticate with the Nextcloud Login Flow v2, which
                opens a browser and returns a fresh app password
  --url URL     base URL for --login (optional; otherwise prompted)
  --rotate      fetch a fresh app password for the already-configured
                remote via the Login Flow v2, keeping its url and user
                (no prompts; cannot be combined with --login or --url)
  --proxy URL   use URL as the proxy for this setup run only (a socks URL
                through the explicit flags, an http(s) one through the
                child environment); settings files are never written
  --crypt       create the crypt remote named by CRYPT_REMOTE (default
                <RCLONE_REMOTE>-crypt) wrapping the configured WebDAV
                remote, with fresh randomly generated passwords
                (cannot be combined with --login, --rotate, or --url)
  --no-keychain for this run, store the obscured password in the rclone
                config instead of the platform Keychain
  -h, --help    show this help

If all three are already set, no prompts are shown. The URL is normalized
to https://<host>/remote.php/dav/files/<user>/ so Nextcloud chunked
uploads work. The app password is never printed; with KEYCHAIN=1 it goes
to the Keychain (the rclone config gets an obscured empty value),
otherwise it is obscured before it is written to the rclone config.
EOF
}

# setup_prompt LABEL CURRENT [secret] - print CURRENT or ask for it.
setup_prompt() {
  local label="$1" current="$2" secret="${3:-}"
  if [[ -n "$current" ]]; then
    printf '%s' "$current"
    return 0
  fi
  if [[ -n "$secret" ]]; then
    read -r -s -p "${label}: " current || true
    printf '\n' >&2
  else
    printf '%s: ' "$label"
    read -r current || true
  fi
  printf '%s' "$current"
}

# setup_normalize_url URL USER - print URL normalized to USER's Nextcloud
# WebDAV files root through the shared nextcloud_dav_url (lib/base/core.sh),
# which strips the trailing slashes, keeps a URL already at that root, and
# appends /remote.php/dav/files/USER/ otherwise. The helper reports only
# rc 1 for a URL that points into /remote.php/ but not at USER's root, so
# setup's own wording of that failure stays here (the helper never prints
# command text).
setup_normalize_url() {
  local url="$1" user="$2" normalized=""
  url="$(strip_trailing_slashes "$url")"
  normalized="$(nextcloud_dav_url "$url" "$user")" ||
    die "URL '${url}' looks like a WebDAV path, but setup needs the Nextcloud base URL (e.g. https://your-university.sciebo.de); it appends /remote.php/dav/files/<user>/ itself"
  printf '%s' "$normalized"
}

setup_warn_if_group_or_other_readable() {
  local file="$1" mode=""
  [[ -f "$file" ]] || return 0
  # Shared helper: works with the BSD and GNU stat spellings, so the check
  # also fires on Linux.
  mode="$(file_mode "$file")"
  [[ -n "$mode" ]] || return 0
  case "$mode" in
    *00) ;;
    *) warn "${file} is readable by group/other (mode ${mode}); consider chmod 600 ${file}" ;;
  esac
}

# setup_proxy_hint URL - after a run with --proxy, remind the user how to
# keep it. Settings files are never written. The URL is shown with any
# userinfo redacted (url_redact_userinfo, lib/base/core.sh): a credentialed proxy
# would otherwise land in the terminal scrollback (and any captured log).
setup_proxy_hint() {
  [[ -n "${1:-}" ]] || return 0
  printf '\nadd PROXY="%s" to config/settings.local.env to use it for later runs\n' \
    "$(url_redact_userinfo "$1")"
  return 0
}

# setup_login_flow_url_has_control URL - true when URL carries a C0/DEL or
# stray-C1 control byte. The login-flow response is server-controlled, so such
# a URL must never reach the terminal or the browser opener.
setup_login_flow_url_has_control() {
  case "${1:-}" in
    *[[:cntrl:]]*) return 0 ;;
  esac
  return 1
}

# setup_login_flow_url_allowed URL BASE_URL - true when URL is non-empty, does
# not start with "-", carries no control byte, uses an http(s) scheme, and
# shares BASE_URL's origin. The login-flow response is server-controlled, so an
# unexpected URL is refused before it can be opened in a browser or POSTed with
# the poll token.
setup_login_flow_url_allowed() {
  local url="${1:-}" base_url="${2:-}"
  [[ -n "$url" ]] || return 1
  setup_login_flow_url_has_control "$url" && return 1
  case "$url" in
    -*) return 1 ;;
  esac
  case "$url" in
    http://* | https://*) ;;
    *) return 1 ;;
  esac
  [[ "$(http_origin "$url")" == "$(http_origin "$base_url")" ]]
}

# setup_require_base_url URL - die unless URL is a non-empty http(s) base URL.
# A leading "-" would be read by curl as an option and a non-http scheme cannot
# address a Nextcloud server, so both are refused before any request is made.
# Plain http:// is accepted (setup_commit warns about it separately).
setup_require_base_url() {
  local url="${1:-}"
  [[ -n "$url" ]] ||
    die "the base URL is empty; pass --url https://<host> or set SCIEBO_URL"
  case "$url" in
    -*) die "the base URL '$(printable "$url")' starts with '-'" ;;
  esac
  case "$url" in
    http://* | https://*) ;;
    *) die "the base URL '$(printable "$url")' must use http:// or https://" ;;
  esac
  return 0
}

# setup_login_flow_curl_pass_file VAR PASSWORD - write a mode-600 curl config
# file carrying the client-key passphrase as `pass = "..."` and store its path
# in VAR. Delegates to the shared curl_key_pass_config_into (lib/base/core.sh),
# which escapes backslash/double quote, refuses a control byte, and registers
# the fresh mode-600 temp for exit cleanup; a control byte (rc 1) or write
# failure (rc 2) is normalized to this path's rc 1. The caller adds
# `--config FILE` and temp_discard()s it, so the passphrase never reaches the
# curl argv.
setup_login_flow_curl_pass_file() {
  curl_key_pass_config_into "$1" "${2-}" || return 1
}

# Login-flow curl state prepared by _login_flow_client_args and reused by
# _login_flow_poll. Module-private (the leading underscore).
_LOGIN_FLOW_TLS_FLAG=""
_LOGIN_FLOW_PASS_FILE=""
_LOGIN_FLOW_CLIENT_ARGS=()

# _login_flow_client_args - fill the login-flow curl TLS flag, the
# mutual-TLS/CA/User-Agent argv, and the mode-600 client-key passphrase config
# file, warning once when TLS verification is disabled. The passphrase reaches
# curl through the config file instead of --pass, which would expose it in the
# argv.
_login_flow_client_args() {
  _LOGIN_FLOW_TLS_FLAG=""
  _LOGIN_FLOW_PASS_FILE=""
  _LOGIN_FLOW_CLIENT_ARGS=()
  if [[ "${TLS_INSECURE:-0}" == "1" ]]; then
    _LOGIN_FLOW_TLS_FLAG="-k"
    if [[ "${_LOGIN_FLOW_TLS_WARNED:-0}" != "1" ]]; then
      warn "TLS certificate verification is disabled (--trust); this connection is not authenticated"
      _LOGIN_FLOW_TLS_WARNED=1
    fi
  fi
  # The login flow uses raw curl, so apply the mutual-TLS/CA/User-Agent
  # settings here too. The client-key passphrase goes through a mode-600
  # --config file (added last) instead of --pass, which would expose it in the
  # argv.
  if [[ -n "${CLIENT_KEY_PASSWORD:-}" ]]; then
    setup_login_flow_curl_pass_file _LOGIN_FLOW_PASS_FILE "$CLIENT_KEY_PASSWORD" ||
      die "the client key passphrase contains a control character and cannot be sent safely"
    curl_client_args_into _LOGIN_FLOW_CLIENT_ARGS --config "$_LOGIN_FLOW_PASS_FILE"
  else
    curl_client_args_into _LOGIN_FLOW_CLIENT_ARGS
  fi
  return 0
}

# _login_flow_poll RESPONSE_FILE POLL_ENDPOINT POLL_TOKEN - poll the login-flow
# endpoint until it returns HTTP 200 or a cap is reached; 404 means "not
# authorized yet". RESPONSE_FILE receives the final body and every failure
# discards it before dying. POLL_TOKEN is written to a mode-600 temp and sent
# as --data-urlencode "token@FILE", so the server-controlled token never
# reaches the curl argv; the temp is discarded after the poll. Uses the state
# from _login_flow_client_args and the LOGIN_FLOW_POLL_INTERVAL/TIMEOUT/
# MAX_POLLS knobs.
_login_flow_poll() {
  local response_file="$1" poll_endpoint="$2" poll_token="$3"
  local http_code="" polls=0 waited=0 token_file=""
  local poll_interval="${LOGIN_FLOW_POLL_INTERVAL:-2}"
  local timeout="${LOGIN_FLOW_TIMEOUT:-1200}"
  local max_polls="${LOGIN_FLOW_MAX_POLLS:-}"
  # temp_mktemp_into registers the file for the EXIT trap, so a die inside the
  # loop cannot leave the poll token behind.
  temp_mktemp_into token_file "${TMPDIR:-/tmp}/sciebo-login-token.XXXXXX" ||
    die "login flow: cannot create a temporary token file"
  if ! printf '%s' "$poll_token" >"$token_file"; then
    temp_discard "$token_file"
    die "login flow: cannot write the temporary token file"
  fi
  chmod 600 "$token_file" 2>/dev/null || true
  while :; do
    http_code="$(curl -sS ${_LOGIN_FLOW_TLS_FLAG:+"$_LOGIN_FLOW_TLS_FLAG"} ${_LOGIN_FLOW_CLIENT_ARGS[@]+"${_LOGIN_FLOW_CLIENT_ARGS[@]}"} -o "$response_file" -w '%{http_code}' -X POST --data-urlencode "token@${token_file}" "$poll_endpoint" 2>/dev/null)" || http_code="000"
    case "$http_code" in
      200) break ;;
      404) ;;
      *)
        temp_discard "$response_file"
        die "login flow: poll failed with HTTP ${http_code}; re-run '${CLI_NAME} setup --login'"
        ;;
    esac
    polls=$((polls + 1))
    if [[ -n "$max_polls" && "$polls" -ge "$max_polls" ]]; then
      temp_discard "$response_file"
      die "login flow: timed out after ${polls} poll(s); re-run '${CLI_NAME} setup --login'"
    fi
    waited=$((waited + poll_interval))
    if [[ "$waited" -ge "$timeout" ]]; then
      temp_discard "$response_file"
      die "login flow: timed out after ${timeout}s; re-run '${CLI_NAME} setup --login'"
    fi
    sleep "$poll_interval"
  done
  temp_discard "$token_file"
  return 0
}

# setup_login_flow_request BASE_URL OUT_LOGIN OUT_TOKEN OUT_ENDPOINT - stage 1
# of the login flow: prepare the curl client args, POST the flow endpoint, and
# parse the login URL, poll token, and poll endpoint out of the response. A
# failed request or a response missing any of the three fields dies here; the
# values reach the later stages through the namerefs.
setup_login_flow_request() {
  local base_url="$1" body=""
  local -n out_login="$2" out_token="$3" out_endpoint="$4"

  _login_flow_client_args
  if ! body="$(curl -fsS ${_LOGIN_FLOW_TLS_FLAG:+"$_LOGIN_FLOW_TLS_FLAG"} ${_LOGIN_FLOW_CLIENT_ARGS[@]+"${_LOGIN_FLOW_CLIENT_ARGS[@]}"} -X POST -H 'OCS-APIRequest: true' "${base_url}/index.php/login/v2")"; then
    die "login flow: cannot reach ${base_url}/index.php/login/v2 (curl failed)"
  fi
  out_login="$(json_string_field "$body" login)" || true
  out_token="$(json_string_field "$body" token)" || true
  out_endpoint="$(json_string_field "$body" endpoint)" || true
  [[ -n "$out_login" && -n "$out_token" && -n "$out_endpoint" ]] ||
    die "login flow: unexpected response from ${base_url}/index.php/login/v2"
}

# setup_login_flow_validate_url LOGIN_URL POLL_ENDPOINT BASE_URL - stage 2 of
# the login flow and its security gate: both server-controlled URLs must be
# free of control bytes and must pass setup_login_flow_url_allowed (same
# http(s) origin as BASE_URL), or the flow dies. This stage runs before the
# browser stage and before the poll, so an unexpected URL never reaches `open`
# or the token POST.
setup_login_flow_validate_url() {
  local login_url="$1" poll_endpoint="$2" base_url="$3"
  if setup_login_flow_url_has_control "$login_url"; then
    die "login flow: the server sent a login URL containing a control character; refusing it"
  fi
  if setup_login_flow_url_has_control "$poll_endpoint"; then
    die "login flow: the server sent a poll endpoint containing a control character; refusing it"
  fi
  setup_login_flow_url_allowed "$login_url" "$base_url" ||
    die "login flow: unexpected server URL in the login-flow response"
  setup_login_flow_url_allowed "$poll_endpoint" "$base_url" ||
    die "login flow: unexpected server URL in the login-flow response"
}

# setup_login_flow_open_browser LOGIN_URL - stage 3 of the login flow: open
# the validated login URL in the browser (under LOGIN_FLOW_NO_BROWSER print it
# instead, and when `open` fails warn with the same URL), then announce the
# wait with the configured timeout.
setup_login_flow_open_browser() {
  local login_url="$1" shown="" timeout="${LOGIN_FLOW_TIMEOUT:-1200}"
  if [[ -n "${LOGIN_FLOW_NO_BROWSER:-}" ]]; then
    shown="${ printable "$login_url";}"
    printf 'Open this URL in a browser to authorize access:\n%s\n' "$shown"
  elif ! open -- "$login_url" >/dev/null 2>&1; then
    shown="${ printable "$login_url";}"
    warn "could not open a browser; open this URL manually: ${shown}"
  fi
  log "waiting for authorization (timeout ${timeout}s)"
}

# setup_login_flow_finish BASE_URL POLL_TOKEN POLL_ENDPOINT - stage 4 of the
# login flow: poll until the user grants access, read the credentials
# response, and set LOGIN_FLOW_URL/LOGIN_FLOW_USER/LOGIN_FLOW_PASSWORD. The
# server-reported URL goes through the same control-byte and origin checks
# before it is kept, and an authorization with an incomplete response dies.
setup_login_flow_finish() {
  local base_url="$1" poll_token="$2" poll_endpoint="$3"
  local response_file="" resolved="" server_url=""

  # temp_mktemp_into registers the file for the EXIT trap, so a signal during
  # the poll loop cannot leave the app-password response behind.
  temp_mktemp_into response_file "${TMPDIR:-/tmp}/sciebo-login.XXXXXX" ||
    die "login flow: cannot create a temporary response file"
  _login_flow_poll "$response_file" "$poll_endpoint" "$poll_token"
  resolved="$(<"$response_file")"
  temp_discard "$response_file"
  temp_discard "$_LOGIN_FLOW_PASS_FILE"

  server_url="$(json_string_field "$resolved" server)" || true
  if setup_login_flow_url_has_control "$server_url"; then
    die "login flow: the server reported a URL containing a control character; refusing it"
  fi
  setup_login_flow_url_allowed "$server_url" "$base_url" ||
    die "login flow: server reported an unexpected URL"
  LOGIN_FLOW_URL="$server_url"
  LOGIN_FLOW_USER="$(json_string_field "$resolved" loginName)" || true
  LOGIN_FLOW_PASSWORD="$(json_string_field "$resolved" appPassword)" || true
  [[ -n "$LOGIN_FLOW_URL" && -n "$LOGIN_FLOW_USER" && -n "$LOGIN_FLOW_PASSWORD" ]] ||
    die "login flow: authorization succeeded but the credentials response was incomplete"
}

# setup_login_flow BASE_URL - Nextcloud Login Flow v2: POST the flow,
# open the login URL in the browser, poll until the user grants access,
# and set LOGIN_FLOW_URL/LOGIN_FLOW_USER/LOGIN_FLOW_PASSWORD. Uses `curl`
# from PATH. Test knobs: LOGIN_FLOW_POLL_INTERVAL (default 2),
# LOGIN_FLOW_TIMEOUT (default 1200), LOGIN_FLOW_NO_BROWSER (print instead
# of opening), and LOGIN_FLOW_MAX_POLLS (optional poll cap).
# The four stages run in order — request, URL validation, browser, finish —
# so the security validation always completes before the URL is opened or
# polled.
setup_login_flow() {
  local base_url="" login_url="" poll_token="" poll_endpoint=""
  base_url="$(strip_trailing_slashes "$1")"
  setup_require_base_url "$base_url"
  setup_login_flow_request "$base_url" login_url poll_token poll_endpoint
  setup_login_flow_validate_url "$login_url" "$poll_endpoint" "$base_url"
  setup_login_flow_open_browser "$login_url"
  setup_login_flow_finish "$base_url" "$poll_token" "$poll_endpoint"
}

# setup_rotate_base_url URL - derive the Nextcloud base URL from the stored
# (normalized) WebDAV URL. rc 1 when it does not look like a WebDAV URL.
# Deliberately not remote_nextcloud_base (lib/adapters/rclone.sh): that helper
# requires an http(s) scheme and the /remote.php/dav/files/ path, while
# rotate reads whatever url a hand-edited config holds and derives the base
# from any /remote.php/ path, so the stricter helper would refuse URLs this
# command has always rotated.
setup_rotate_base_url() {
  local url="$1"
  url="$(strip_trailing_slashes "$url")"
  case "$url" in
    */remote.php/*) printf '%s' "${url%%/remote.php/*}" ;;
    *) return 1 ;;
  esac
}

# setup_rotate_host URL - the host[:port] part of a URL, for the summary line.
setup_rotate_host() {
  local rest="${1#*://}"
  printf '%s' "${rest%%/*}"
}

# setup_rotate NO_KEYCHAIN - run the Login Flow v2 against the base URL of
# the already-configured remote and replace only its app password. The url
# and user stored in the rclone config are kept; no prompts are shown.
setup_rotate() {
  local no_keychain="$1"
  local show="" url="" user="" base_url="" host=""
  local pass_config="" use_keychain=0

  remote_configured ||
    die "rclone remote '${RCLONE_REMOTE}:' is not configured; run '${CLI_NAME} setup --login' first"

  show=${ remote_config_show;}
  url="$(config_value url "$show")"
  user="$(config_value user "$show")"
  [[ -n "$url" ]] ||
    die "remote '${RCLONE_REMOTE}:' has no url; run '${CLI_NAME} setup --login' first"
  [[ -n "$user" ]] ||
    die "remote '${RCLONE_REMOTE}:' has no user; run '${CLI_NAME} setup --login' first"
  base_url="$(setup_rotate_base_url "$url")" ||
    die "remote '${RCLONE_REMOTE}:' has an unexpected url '${url}'; run '${CLI_NAME} setup --login' first"

  setup_login_flow "$base_url"
  if [[ -n "${LOGIN_FLOW_USER:-}" && "${LOGIN_FLOW_USER}" != "$user" ]]; then
    warn "login flow authorized '${LOGIN_FLOW_USER}', but remote '${RCLONE_REMOTE}:' is configured for '${user}'; keeping the configured user"
  fi

  if [[ "$no_keychain" -eq 0 ]] && keychain_enabled; then
    use_keychain=1
  fi
  pass_config="$(remote_password_config_value "${LOGIN_FLOW_PASSWORD:-}" "$use_keychain")"
  LOGIN_FLOW_PASSWORD=""
  unset LOGIN_FLOW_PASSWORD

  remote_write_pass "$pass_config"

  host="$(setup_rotate_host "$base_url")"
  printf 'rotated the app password for %s@%s\n' "$user" "$host"
}

# setup_crypt_password - print a fresh random password: 32 bytes of
# openssl base64 when available, otherwise 40 alphanumerics from
# /dev/urandom. Never fails; the caller checks for an empty result.
setup_crypt_password() {
  local out=""
  if have openssl && out="$(openssl rand -base64 32 2>/dev/null)" && [[ -n "$out" ]]; then
    printf '%s' "$out"
    return 0
  fi
  # head closes the pipe once it has enough bytes; the SIGPIPE on tr must
  # not fail the function under `set -o pipefail`.
  LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 40 || true
  return 0
}

# setup_crypt_resolve_remote OUT - set OUT to the crypt remote name
# (CRYPT_REMOTE, else RCLONE_REMOTE-crypt) after validating it.
setup_crypt_resolve_remote() {
  local -n _scr_out="$1"
  local remote="${CRYPT_REMOTE:-${RCLONE_REMOTE}-crypt}"
  [[ -n "$remote" ]] || die "CRYPT_REMOTE is empty; set CRYPT_REMOTE or RCLONE_REMOTE"
  case "$remote" in
    *:*) die "CRYPT_REMOTE '$(printable "$remote")' must not contain ':'" ;;
  esac
  _scr_out="$remote"
  return 0
}

# setup_crypt_install_remote CRYPT_REMOTE NO_KEYCHAIN - generate two fresh
# crypt passwords, obscure them, and write them into the rclone config; they
# are never printed. The keychain helpers store exactly one secret per remote
# (the app password), so the obscured config values are a fallback that is
# called out in a warning when a keychain backend is active. The plaintext
# and obscured copies are cleared here, in the function that reads them.
setup_crypt_install_remote() {
  local crypt_remote="$1" no_keychain="$2"
  local pass1="" pass2="" obscured1="" obscured2="" backend="" empty=""

  pass1="$(setup_crypt_password)"
  pass2="$(setup_crypt_password)"
  [[ -n "$pass1" && -n "$pass2" ]] || die "could not generate crypt passwords"
  obscured1="$(rclone_obscure "$pass1")"
  obscured2="$(rclone_obscure "$pass2")"
  pass1=""
  pass2=""
  unset pass1 pass2

  if [[ "$no_keychain" -eq 0 ]] && keychain_enabled; then
    backend="$(keychain_backend 2>/dev/null || true)"
    warn "the ${backend:-keychain} keychain backend stores one item per remote; the crypt passwords stay obscured in the rclone config"
  fi

  # rclone's config write only takes values in argv; the remote is created
  # with the harmless obscured-empty placeholder and the real obscured
  # values are patched into the plaintext config file afterwards, so they
  # never reach an argv. An encrypted config cannot be patched without
  # exposing the reversible secrets in the process list, so that case is
  # refused rather than falling back to the argv form.
  empty="$(rclone_obscure_empty)"
  if ! rclone_cmd config create "$crypt_remote" crypt "remote=${RCLONE_REMOTE}:" \
    filename_encryption=standard directory_name_encryption=true \
    "password=${empty}" "password2=${empty}" --non-interactive >/dev/null; then
    die "could not create the crypt remote '${crypt_remote}'"
  fi
  if rclone_config_patch_value "$crypt_remote" password "$empty" "$obscured1" &&
    rclone_config_patch_value "$crypt_remote" password2 "$empty" "$obscured2"; then
    remote_config_invalidate
  elif rclone_config_encrypted; then
    die "rclone config is encrypted, so the crypt passwords cannot be patched in without exposing them in the process list; disable rclone config encryption (rclone config encryption remove) and re-run '${CLI_NAME} setup --crypt'"
  else
    die "could not patch the crypt passwords into the rclone config for '${crypt_remote}'"
  fi
  obscured1=""
  obscured2=""
  unset obscured1 obscured2
  return 0
}

# setup_crypt_validate CRYPT_REMOTE - validate the new remote with a
# `rclone lsd`; die with rclone's (sanitized) output on failure.
setup_crypt_validate() {
  local crypt_remote="$1" lsd_err=""
  log "validating crypt remote '${crypt_remote}:' (rclone lsd)"
  if ! lsd_err="$(rclone_cmd lsd "${crypt_remote}:" 2>&1 >/dev/null)"; then
    die "crypt remote validation failed (${crypt_remote}:): $(printf '%s' "$lsd_err" | sanitize_stream)"
  fi
  return 0
}

# setup_crypt_print_hint CRYPT_REMOTE - print the next-step hints after the
# crypt remote was created.
setup_crypt_print_hint() {
  local crypt_remote="$1"
  printf '\ncreated crypt remote %s wrapping %s:\n' "$crypt_remote" "${RCLONE_REMOTE}"
  printf '  set RCLONE_REMOTE="%s" in config/settings.local.env to sync through it\n' "$crypt_remote"
  printf '  (keep RCLONE_REMOTE="%s" for plain access)\n' "$RCLONE_REMOTE"
  return 0
}

# setup_crypt NO_KEYCHAIN - create the crypt remote CRYPT_REMOTE wrapping
# RCLONE_REMOTE. Two fresh passwords are generated, obscured with rclone,
# and written to the rclone config; they are never printed. The keychain
# helpers store exactly one secret per remote (the app password), so a crypt
# remote has to keep its obscured passwords in the config; with KEYCHAIN=1
# that fallback is called out in a warning. The new remote is validated with
# `rclone lsd`.
setup_crypt() {
  local no_keychain="${1:-0}"
  local crypt_remote=""
  setup_crypt_resolve_remote crypt_remote
  setup_crypt_install_remote "$crypt_remote" "$no_keychain"
  setup_crypt_validate "$crypt_remote"
  setup_crypt_print_hint "$crypt_remote"
  return 0
}

# setup_validate_option_combo USE_LOGIN ROTATE CRYPT - reject the option
# combinations the usage documents. Each conflict is a usage error.
setup_validate_option_combo() {
  local use_login="$1" rotate="$2" crypt="$3"
  if [[ "$rotate" -eq 1 ]]; then
    [[ -z "${OPT_url_SET:-}" ]] || usage_error setup "--rotate cannot be combined with --url"
    [[ "$use_login" -eq 0 ]] || usage_error setup "--rotate cannot be combined with --login"
  fi
  if [[ "$crypt" -eq 1 ]]; then
    [[ "$use_login" -eq 0 ]] || usage_error setup "--crypt cannot be combined with --login"
    [[ "$rotate" -eq 0 ]] || usage_error setup "--crypt cannot be combined with --rotate"
    [[ -z "${OPT_url_SET:-}" ]] || usage_error setup "--crypt cannot be combined with --url"
  fi
  return 0
}

# setup_apply_proxy PROXY - --proxy applies to this run only: the shared
# proxy resolvers read PROXY/PROXY_TYPE (an http(s) URL through the child's
# environment, a socks URL through rclone's --http-proxy / curl's -x), while
# the exported HTTP_PROXY/HTTPS_PROXY cover the login flow's direct curl
# calls. PROXY_TYPE is forced to "system" so an ambient PROXY_TYPE=none
# cannot silently swallow the proxy the user just asked for; PROXY_DIRECT is
# cleared for the same reason. Settings files are never written.
setup_apply_proxy() {
  local proxy="${1:-}"
  [[ -n "$proxy" ]] || return 0
  PROXY_TYPE=system
  PROXY="$proxy"
  PROXY_DIRECT=0
  HTTP_PROXY="$proxy"
  HTTPS_PROXY="$proxy"
  export PROXY PROXY_TYPE PROXY_DIRECT HTTP_PROXY HTTPS_PROXY
  return 0
}

# setup_load_env - warn about a group/other-readable .env, refuse an unsafe
# one (symlink, wrong owner, or group/other-writable), and source it. It may
# carry the app password, so it is executable shell input.
setup_load_env() {
  [[ -f "$ENV_FILE" ]] || return 0
  setup_warn_if_group_or_other_readable "$ENV_FILE"
  safe_source "$ENV_FILE" ||
    die "refusing unsafe .env file '$(printable "$ENV_FILE")': it must be a regular file owned by you and not group- or other-writable"
  return 0
}

# setup_run_login NO_KEYCHAIN PROXY - resolve credentials with the Login Flow
# v2 and hand them to setup_commit. The base URL comes from --url, SCIEBO_URL,
# or a prompt.
setup_run_login() {
  local no_keychain="$1" proxy="$2"
  local base_url="" url="" user="" pass=""
  setup_load_env
  base_url="${OPT_url:-${SCIEBO_URL:-}}"
  [[ -n "$base_url" ]] ||
    base_url="$(setup_prompt 'sciebo base URL (e.g. https://your-university.sciebo.de)' "")"
  [[ -n "$base_url" ]] || die "sciebo base URL is required for --login; pass --url URL or set SCIEBO_URL in .env (cp .env.example .env)"
  setup_login_flow "$base_url"
  url="${LOGIN_FLOW_URL:-}"
  user="${LOGIN_FLOW_USER:-}"
  pass="${LOGIN_FLOW_PASSWORD:-}"
  [[ -n "$url" && -n "$user" && -n "$pass" ]] ||
    die "login flow did not return credentials; re-run '${CLI_NAME} setup --login'"
  setup_commit "$url" "$user" "$pass" "$no_keychain" "$proxy"
}

# setup_run_normal NO_KEYCHAIN PROXY - prompt for (or read from .env) the URL,
# user, and app password, then hand them to setup_commit.
setup_run_normal() {
  local no_keychain="$1" proxy="$2"
  local base_url="" url="" user="" pass=""
  setup_load_env
  base_url="${OPT_url:-${SCIEBO_URL:-}}"
  url="$(setup_prompt 'sciebo base URL (e.g. https://your-university.sciebo.de)' "$base_url")"
  [[ -n "$url" ]] || die "sciebo base URL is required; set SCIEBO_URL in .env (cp .env.example .env)"

  user="$(setup_prompt 'sciebo ID (e.g. alice@your-university.de; a plain Nextcloud username works too)' "${SCIEBO_USER:-}")"
  [[ -n "$user" ]] || die "sciebo ID is required; set SCIEBO_USER in .env (cp .env.example .env)"
  case "$user" in
    *[[:space:]]* | *[[:cntrl:]]*)
      die "sciebo ID '${user}' must not contain whitespace or control characters"
      ;;
  esac

  pass="$(setup_prompt 'sciebo app password' "${SCIEBO_APP_PASSWORD:-}" secret)"
  [[ -n "$pass" ]] || die "sciebo app password is required; set SCIEBO_APP_PASSWORD in .env (cp .env.example .env)"
  setup_commit "$url" "$user" "$pass" "$no_keychain" "$proxy"
}

# setup_prepare_credentials URL USER PASS NO_KEYCHAIN OUT_URL OUT_CONFIG
# OUT_KEYCHAIN - stage 1 of setup_commit: normalize the URL to USER's WebDAV
# files root (warning about plain http://), decide the keychain tier, compute
# the obscured rclone config value for PASS, and zero the plaintext secrets.
# keychain.sh loads before the decision (see setup_rotate); the login-flow and
# .env copies are dropped only once the config value exists. This stage must
# complete before the remote is written — nothing after it holds a plaintext
# password. Results reach the later stages through the namerefs.
setup_prepare_credentials() {
  local pass="$3" no_keychain="$4"
  local -n out_url="$5" out_config="$6" out_keychain="$7"
  local use_keychain=0

  out_url="$(setup_normalize_url "$1" "$2")"
  case "$out_url" in
    http://*) warn "URL uses plain http://; sciebo connections should use https://" ;;
  esac

  if [[ "$no_keychain" -eq 0 ]] && keychain_enabled; then
    use_keychain=1
  fi
  # shellcheck disable=SC2034  # written through the nameref; read by setup_commit
  out_config="$(remote_password_config_value "$pass" "$use_keychain")"
  pass=""
  # The login flow keeps the plaintext in LOGIN_FLOW_PASSWORD for the same
  # reason setup_rotate does; drop it once the config value is computed.
  LOGIN_FLOW_PASSWORD=""
  unset LOGIN_FLOW_PASSWORD SCIEBO_APP_PASSWORD
  # shellcheck disable=SC2034  # written through the nameref; read by setup_commit
  out_keychain="$use_keychain"
}

# setup_write_and_validate_remote URL USER PASS_CONFIG - stage 2 of
# setup_commit: write the Nextcloud WebDAV remote into the rclone config and
# validate it (validation failure dies). Runs only after the credentials stage
# has zeroed the plaintext secrets.
setup_write_and_validate_remote() {
  remote_write_nextcloud "$1" "$2" "$3"
  remote_validate
}

# setup_report_quota - stage 3 of setup_commit: print the quota readout from
# `rclone about`, or warn when the readout cannot be obtained.
setup_report_quota() {
  local about_out=""
  if about_out="$(rclone_cmd about "${RCLONE_REMOTE}:" 2>&1)"; then
    [[ -z "$about_out" ]] || printf '%s\n' "$about_out"
  else
    warn "could not read quota (rclone about failed): ${about_out}"
  fi
}

# setup_report_capabilities - stage 4 of setup_commit: probe the server
# capabilities and report them (the capability rows plus the chunk-size
# hint), warning when the probe fails.
setup_report_capabilities() {
  local chunk=""
  if capabilities_probe; then
    printf '\n'
    capabilities_show
    chunk=${ capabilities_sync_chunk_size;} || chunk=""
    if [[ -n "$chunk" && "$chunk" != "${CHUNK_SIZE:-}" ]]; then
      log "server reports chunk size ${chunk}; consider setting CHUNK_SIZE=${chunk} in config/settings.local.env"
    fi
  else
    warn "could not probe server capabilities (chunk size not checked)"
  fi
}

# setup_print_summary URL USER USE_KEYCHAIN PROXY - stage 5 of setup_commit:
# the summary block (ready line, url/user/config, where the password is
# stored), the next steps, and the reminder about a run-scoped --proxy.
setup_print_summary() {
  local url="$1" user="$2" use_keychain="$3" proxy="$4"
  local shown_url=""
  printf '\n'
  log "remote '${RCLONE_REMOTE}:' ready"
  shown_url="${ printable "$url";}"
  printf '  url:    %s\n  user:   %s\n  config: %s\n' "$shown_url" "$user" "$RCLONE_CONFIG"
  if [[ "$use_keychain" -eq 1 ]]; then
    printf '  password: Keychain (%s, %s)\n' "$KEYCHAIN_SERVICE" "$(keychain_account_plain)"
  else
    printf '  password: rclone config (obscured)\n'
  fi
  printf '\nNext steps:\n'
  printf '  1. add sources to config/sources.conf\n'
  printf '  2. sciebo check   (dry run)\n'
  printf '  3. sciebo sync    (apply)\n'
  setup_proxy_hint "$proxy"
  return 0
}

# setup_commit URL USER PASS NO_KEYCHAIN PROXY - run setup's five stages in
# order: prepare (and zero) the credentials, write and validate the rclone
# remote, print the quota readout, probe and report the capabilities, then
# print the summary, next steps, and the proxy hint. Shared by the normal and
# --login flows; PASS is read only by the first stage.
setup_commit() {
  local user="$2" proxy="$5"
  local url="" pass_config="" use_keychain=0

  setup_prepare_credentials "$1" "$user" "$3" "$4" url pass_config use_keychain
  setup_write_and_validate_remote "$url" "$user" "$pass_config"
  setup_report_quota
  setup_report_capabilities
  setup_print_summary "$url" "$user" "$use_keychain" "$proxy"
  return 0
}

cmd_setup() {
  opt_begin "login:b url:s no-keychain:b rotate:b proxy:s crypt:b" setup "" "$@"
  opt_guard setup

  # Run dependencies load after opt_begin's --help exit (and after the
  # unknown-option usage error), so `sciebo setup --help` parses none of
  # them: the login flow and remote validation use http/capabilities.

  local use_login=0 no_keychain=0 rotate=0 crypt=0
  local proxy="${OPT_proxy:-}"
  opt_into use_login login 1
  opt_into no_keychain no_keychain 1
  opt_into rotate rotate 1
  opt_into crypt crypt 1
  setup_validate_option_combo "$use_login" "$rotate" "$crypt"

  load_settings
  ensure_state_dirs
  mkdir -p "$(dirname "$RCLONE_CONFIG")"
  setup_apply_proxy "$proxy"

  if [[ "$crypt" -eq 1 ]]; then
    setup_crypt "$no_keychain"
    setup_proxy_hint "$proxy"
    return 0
  fi

  if [[ "$rotate" -eq 1 ]]; then
    setup_rotate "$no_keychain"
    setup_proxy_hint "$proxy"
    return 0
  fi

  if [[ "$use_login" -eq 1 ]]; then
    setup_run_login "$no_keychain" "$proxy"
  else
    setup_run_normal "$no_keychain" "$proxy"
  fi
  return 0
}
