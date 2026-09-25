#!/bin/bash
# secrets.sh - keeps credentials out of argv, ps, and stray files: the netrc
# writer and the temp-file registry every secret-holding temp goes through
# so bin/sciebo's EXIT trap can remove it. The proxy-classification decision
# (shared by curl and rclone) lives in lib/adapters/proxy.sh; the curl-config
# writers that read CLIENT_CERT/CLIENT_KEY/CA_CERT settings live in
# lib/adapters/http.sh - base must not know about settings.
#
# Depends on core.sh's die and text.sh's printable. Invariant: every temp
# file holding a secret is created through temp_mktemp_into (registered for
# exit cleanup) or through a caller-supplied path the caller already owns;
# never via a bare mktemp or a $(...) that would lose the registration in a
# subshell.

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
