#!/bin/bash
# secrets.sh - keeps credentials out of argv, ps, and stray files: the netrc
# and curl-config writers, the proxy-classification decision shared by curl
# and rclone, and the temp-file registry every secret-holding temp goes
# through so bin/sciebo's EXIT trap can remove it.
#
# Sourced by lib/core.sh. Depends on core.sh's die and text.sh's printable.
# Invariant: every temp file holding a secret is created through
# temp_mktemp_into (registered for exit cleanup) or through a caller-supplied
# path the caller already owns; never via a bare mktemp or a $(...) that
# would lose the registration in a subshell.

# opt_read_fd_secret CMD FLAG OUT FD - validate FD (a positive decimal file
# descriptor) and read one line from it into OUT. Stops the run through
# usage_error CMD for a non-number, "0", an unreadable descriptor, or an empty
# value, with FLAG's established descriptor wording. Shared by nextcloudcmd
# --password-fd and provision --apppassword-fd so the secret never reaches the
# argv and the two remain worded alike. OUT may be a local or a global.
opt_read_fd_secret() {
  local command="$1" flag="$2" outvar="$3" fd="$4" secret=""
  case "$fd" in
    '' | *[!0-9]*) usage_error "$command" "${flag} requires a file descriptor number" ;;
  esac
  [[ "$fd" != "0" ]] || usage_error "$command" "${flag} requires a positive file descriptor number"
  # read returns 1 at EOF without a trailing newline, so only an empty result
  # counts as failure (a bad descriptor also leaves it empty).
  if ! IFS= read -r -u "$fd" secret 2>/dev/null && [[ -z "$secret" ]]; then
    usage_error "$command" "${flag} ${fd} is not readable"
  fi
  [[ -n "$secret" ]] || usage_error "$command" "${flag} ${fd} provided an empty password"
  printf -v "$outvar" '%s' "$secret"
  return 0
}

# netrc_quote VALUE - quote VALUE as a netrc password field: escape
# backslashes and double quotes, then wrap the result in double quotes.
# Prints nothing and returns 1 when VALUE contains a control byte (newline,
# CR, TAB, ...), which netrc cannot carry safely. Shared by http.sh (always)
# and capabilities.sh (which may run without http.sh loaded).
netrc_quote() {
  local value="$1"
  case "$value" in
    *[[:cntrl:]]*) return 1 ;;
  esac
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

# netrc_host BASE - the `machine` value for a curl netrc file: BASE without
# scheme, path, and port. curl matches machine entries against the bare
# hostname, so "127.0.0.1:18765" would never match.
netrc_host() {
  local host="$1"
  host="${host#*://}"
  host="${host%%/*}"
  case "$host" in
    *\]:*) host="${host%:*}" ;;
    *\]) ;;
    *:*) host="${host%%:*}" ;;
  esac
  printf '%s' "$host"
}

# netrc_write_into VAR BASE USER SECRET [NETRC_FILE] - write a curl netrc
# `machine HOST login USER password QUOTED` line and set VAR (a nameref) to
# the file used. HOST comes from netrc_host BASE and SECRET is escaped by
# netrc_quote, so the password never reaches a curl argv. A control byte in
# SECRET is refused (rc 1, VAR untouched) because netrc cannot carry it.
# Without NETRC_FILE a fresh mode-600 temp is created via temp_mktemp_into
# (registered for exit cleanup); with NETRC_FILE the caller-provided path is
# truncated and rewritten (the caller owns its lifecycle and cleanup), which
# is what keeps http.sh's persistent-temp netrc reusable. A write failure
# returns 1 and removes a temp the call just created. Both values are captured
# forklessly, so the hot http path does not spawn a subshell per request.
netrc_write_into() {
  local -n _nw_out="$1"
  local base="${2-}" user="${3-}" secret="${4-}" target="${5-}"
  local quoted="" host="" file=""
  quoted=${ netrc_quote "$secret";} || return 1
  host=${ netrc_host "$base";}
  if [[ -n "$target" ]]; then
    if ! printf 'machine %s login %s password %s\n' "$host" "$user" "$quoted" >"$target"; then
      return 1
    fi
    # Enforce 600 even on a caller-supplied path, so a loose-mode target
    # cannot be handed the app password.
    chmod 600 "$target" 2>/dev/null || true
    _nw_out="$target"
    return 0
  fi
  temp_mktemp_into file "${TMPDIR:-/tmp}/sciebo-netrc.XXXXXX" || return 1
  chmod 600 "$file" 2>/dev/null || true
  if ! printf 'machine %s login %s password %s\n' "$host" "$user" "$quoted" >"$file"; then
    temp_discard "$file"
    return 1
  fi
  _nw_out="$file"
  return 0
}

# _proxy_classify CLASS_VAR URL_VAR ERROR_VAR PROXY_TYPE PROXY PROXY_DIRECT -
# the single source of the PROXY_TYPE/PROXY/PROXY_DIRECT decision, shared by
# the curl and rclone proxy resolvers. Writes three out-params (namerefs):
#   CLASS_VAR  one of:
#                none        no proxy, and the ambient proxy environment must
#                            be ignored (PROXY_TYPE=none, or PROXY_DIRECT=1)
#                none-needed no proxy setting at all: leave the environment
#                            (and any ambient proxy) untouched
#                env         use URL_VAR as an http(s) proxy through the
#                            child's environment, keeping credentials out of
#                            the argv
#                flag        pass URL_VAR as an explicit proxy flag (curl -x /
#                            rclone --http-proxy), for socks and other schemes
#   URL_VAR    the proxy URL for env/flag, empty otherwise
#   ERROR_VAR  "PROXY_TYPE=<type> requires PROXY to be set" when http/socks5
#              was selected without PROXY, empty otherwise
# An explicit http:// or https:// PROXY classifies as env; every other scheme
# as flag, because socks support through the environment is not portable.
# This helper never dies, so the caller decides how to report ERROR_VAR; its
# two current consumers die with it (lib/http.sh _http_proxy_args and
# lib/rclone.sh _rclone_proxy_resolve).
_proxy_classify() {
  local -n _pc_class="$1" _pc_url="$2" _pc_err="$3"
  local type="${4:-system}" proxy="${5:-}" direct="${6:-0}"
  _pc_class="none-needed"
  _pc_url=""
  _pc_err=""
  case "$type" in
    none)
      _pc_class="none"
      ;;
    http | socks5)
      if [[ -z "$proxy" ]]; then
        _pc_err="PROXY_TYPE=${type} requires PROXY to be set"
        return 0
      fi
      _proxy_classify_url "$1" "$2" "$proxy"
      ;;
    *)
      if [[ "$direct" == "1" ]]; then
        _pc_class="none"
      elif [[ -n "$proxy" ]]; then
        _proxy_classify_url "$1" "$2" "$proxy"
      fi
      ;;
  esac
  return 0
}

# _proxy_classify_url CLASS_VAR URL_VAR PROXY - write the class/url pair for a
# non-empty PROXY: an explicit http:// or https:// proxy goes through the
# child's environment ("env"), every other scheme is passed as an explicit
# proxy flag ("flag"), because socks support through the environment is not
# portable. Both out-params are namerefs; the two branches of _proxy_classify
# call this so the per-scheme rule lives once.
_proxy_classify_url() {
  local -n _pcu_class="$1" _pcu_url="$2"
  local proxy="$3"
  case "$proxy" in
    http://* | https://*)
      _pcu_class="env"
      _pcu_url="$proxy"
      ;;
    *)
      _pcu_class="flag"
      _pcu_url="$proxy"
      ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# Temp-file registry
#
# Modules that write secrets (the curl netrc file) or per-call response
# bodies register them here. bin/sciebo removes every leftover on exit, so a
# signal or a crash cannot leave an authenticated netrc on disk. The registry
# is a Bash array of paths (empty expansions are safe under `set -u` in 5.3).
# ---------------------------------------------------------------------------

SCIEBO_TEMP_FILES=()

# sciebo_temp_register FILE - remember FILE for exit cleanup.
sciebo_temp_register() {
  SCIEBO_TEMP_FILES+=("$1")
}

# sciebo_temp_unregister FILE - forget FILE after the caller removed it.
sciebo_temp_unregister() {
  local file="$1" kept=() entry=""
  for entry in "${SCIEBO_TEMP_FILES[@]}"; do
    [[ "$entry" != "$file" ]] || continue
    kept+=("$entry")
  done
  SCIEBO_TEMP_FILES=("${kept[@]}")
}

# sciebo_temp_cleanup - remove every registered temp path; safe to run twice.
# Entries may be files or staging directories (support.sh registers its
# mktemp -d staging tree), so this uses rm -rf. It only runs on exit/signal.
sciebo_temp_cleanup() {
  local entry=""
  for entry in "${SCIEBO_TEMP_FILES[@]}"; do
    rm -rf "$entry" 2>/dev/null || true
  done
  SCIEBO_TEMP_FILES=()
}

# temp_mktemp_into VAR TEMPLATE - mktemp TEMPLATE, store the path in VAR, and
# register it for exit cleanup. Must be called as a command (never inside
# `$(...)`): registration has to happen in the caller's shell, because a
# command-substitution subshell would discard the SCIEBO_TEMP_FILES entry and
# leave a secret temp file behind on a signal. Returns 1 when mktemp fails.
temp_mktemp_into() {
  local -n _temp_out="$1"
  local _temp_path=""
  _temp_path="$(mktemp "$2")" || return 1
  _temp_out="$_temp_path"
  sciebo_temp_register "$_temp_path"
  return 0
}

# temp_discard FILE - remove FILE and drop it from the temp registry.
temp_discard() {
  [[ -n "${1:-}" ]] || return 0
  rm -f "$1" 2>/dev/null || true
  sciebo_temp_unregister "$1"
}

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
