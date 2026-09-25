#!/bin/bash
# nextcloudcmd.sh command module - nextcloudcmd-compatible single run.
#
# `sciebo nextcloudcmd SOURCEDIR NEXTCLOUDURL` performs one two-way rclone
# bisync between the local directory and the WebDAV folder derived from the
# URL, using nextcloudcmd's option names. Credentials are only ever passed
# to rclone (obscured in the config) and never printed.
#
# opt_parse does not know short options, so -u/-p/-n/-s/-h/-P are rewritten to
# their long forms before parsing; -v/--version print the version, and
# --verbose is an alias of --logdebug. The rclone remote is dedicated to this
# command (`sciebo-nextcloudcmd`), so a normal `sciebo setup` remote is
# neither read nor changed. Shared helpers cover the rest of what upstream
# nextcloudcmd does locally: netrc_host (lib/core.sh) strips the machine's
# port for the ~/.netrc lookup, and progress_append_args/progress_stdout_tty
# (lib/rclone.sh) own the -P argv guards (terminal only, suppressed by
# --silent and JSON mode).

# Remote name and the resolved URL/credential pieces.
NCC_REMOTE="sciebo-nextcloudcmd"
NCC_SCHEME=""
NCC_HOST=""
NCC_BASE=""
NCC_URL_USER=""
NCC_URL_PASS=""
NCC_USER=""
NCC_PASSWORD=""
NCC_PATH=""
NCC_SOURCEDIR=""
# Rewritten argv (ncc_prescan_args) and the rclone bisync argv (rebuilt for
# the --max-sync-retries dry-run probe).
NCC_RAW_ARGS=()
NCC_ARGS=()
# Run state resolved by ncc_parse_args/ncc_prepare_workdir.
NCC_MAX_RETRIES=0
NCC_DRY_RUN=false
NCC_RESYNC=false
NCC_WORKDIR=""

usage_nextcloudcmd() {
  usage_emit <<'EOF'
Usage: sciebo nextcloudcmd [OPTIONS] SOURCEDIR NEXTCLOUDURL

Run one two-way sync between SOURCEDIR and NEXTCLOUDURL with nextcloudcmd's
option names. The WebDAV folder is
<url>/remote.php/dav/files/<user>/<--path>; the first run initializes the
rclone bisync state automatically (--resync).

Options:
  --path SUB              remote folder below the user root
  --confdir DIR           configuration base for this run (ignored when
                          SCIEBO_CONFDIR is already set)
  --user, -u USER         user name
  --password, -p PASS     password (an app password is recommended). The
                          value is visible in the process list; prefer
                          --password-fd
  --password-fd N         read the password from the already-open file
                          descriptor N instead (avoids exposing it in `ps`)
  -n                      read credentials from ~/.netrc
  --non-interactive       never prompt
  --silent, -s            errors only (--log-level ERROR --stats 0)
  --trust                 accept invalid TLS certificates
  --httpproxy URL         HTTP proxy URL
  --exclude FILE          read exclude patterns from FILE
  --exclude-anchored FILE read patterns from FILE, anchored at the sync root
  --unsyncedfolders FILE  exclude every folder listed in FILE
  --max-sync-retries N    retry the whole sync up to N times while the
                          dry-run check reports remaining changes
  --uplimit RATE          upload bandwidth cap (rclone size suffix)
  --downlimit RATE        download bandwidth cap
  --logdebug              debug-level logging (alias: --verbose)
  --verbose               debug-level logging (alias: --logdebug)
  --progress, -P          show rclone transfer progress (terminal only;
                          suppressed by --silent)
  --version, -v           print the version and exit
  -h                      sync hidden files (no ".*" exclusion)
  --dry-run               report what would change, change nothing
  --help                  show this help
EOF
}

# _ncc_take_value FLAG VALUE - append the long form of the value-taking short
# flag FLAG (-u or -p) and its VALUE to NCC_RAW_ARGS. A missing VALUE is a
# usage error, so a caller can consume both arguments with one `shift 2`.
_ncc_take_value() {
  local flag="$1" value="${2:-}"
  [[ -n "$value" ]] || usage_error nextcloudcmd "${flag} requires a value"
  case "$flag" in
    -u) NCC_RAW_ARGS+=("--user" "$value") ;;
    -p) NCC_RAW_ARGS+=("--password" "$value") ;;
  esac
}

# ncc_prescan_args ARGS... - rewrite nextcloudcmd's short flags into the long
# forms opt_parse understands: -u/-p take a value, -n/-s/-h/-P are booleans (-h
# is "sync hidden files"; --help stays the help flag; -P is --progress).
# -v/--version select the version banner and --verbose is the long alias of
# --logdebug.
# Everything after "--" is left untouched.
ncc_prescan_args() {
  NCC_RAW_ARGS=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -u)
        _ncc_take_value "$1" "${2:-}"
        shift 2
        ;;
      -u*) NCC_RAW_ARGS+=("--user=${1#-u}") && shift ;;
      -p)
        _ncc_take_value "$1" "${2:-}"
        shift 2
        ;;
      -p*) NCC_RAW_ARGS+=("--password=${1#-p}") && shift ;;
      -P) NCC_RAW_ARGS+=("--progress") && shift ;;
      -n) NCC_RAW_ARGS+=("--netrc") && shift ;;
      -s) NCC_RAW_ARGS+=("--silent") && shift ;;
      -v | --version) NCC_RAW_ARGS+=("--version") && shift ;;
      --verbose) NCC_RAW_ARGS+=("--logdebug") && shift ;;
      -h) NCC_RAW_ARGS+=("--hidden") && shift ;;
      --)
        NCC_RAW_ARGS+=("--")
        shift
        while [[ $# -gt 0 ]]; do
          NCC_RAW_ARGS+=("$1")
          shift
        done
        ;;
      *)
        NCC_RAW_ARGS+=("$1")
        shift
        ;;
    esac
  done
}

# ncc_parse_url URL - fill NCC_SCHEME/NCC_HOST/NCC_BASE and the URL
# userinfo; rc 1 when the scheme is not http(s) or the host is empty.
ncc_parse_url() {
  local url="$1" rest="" authority="" path="" userinfo=""
  NCC_SCHEME=""
  NCC_HOST=""
  NCC_BASE=""
  NCC_URL_USER=""
  NCC_URL_PASS=""
  case "$url" in
    http://*) NCC_SCHEME="http" ;;
    https://*) NCC_SCHEME="https" ;;
    *) return 1 ;;
  esac
  rest="${url#*://}"
  authority="${rest%%/*}"
  case "$rest" in
    */*) path="${rest#*/}" ;;
    *) path="" ;;
  esac
  case "$authority" in
    *@*)
      userinfo="${authority%@*}"
      authority="${authority##*@}"
      NCC_URL_USER="${userinfo%%:*}"
      case "$userinfo" in
        *:*) NCC_URL_PASS="${userinfo#*:}" ;;
      esac
      ;;
  esac
  NCC_HOST="$authority"
  [[ -n "$NCC_HOST" ]] || return 1
  NCC_BASE="/${path}"
  NCC_BASE="${NCC_BASE%/}"
  return 0
}

# ncc_normalize_path PATH - strip leading and trailing slashes. The leading
# strip is nextcloudcmd's own (--path arrives user-written); the trailing
# strip is the shared strip_trailing_slashes (lib/core.sh), which keeps a
# lone "/" intact.
ncc_normalize_path() {
  local path="$1"
  while [[ "$path" == /* ]]; do path="${path#/}"; done
  path=${ strip_trailing_slashes "$path";}
  printf '%s' "$path"
}

# ncc_webdav_url - the rclone WebDAV url for the resolved user and path.
ncc_webdav_url() {
  local url="${NCC_SCHEME}://${NCC_HOST}${NCC_BASE}/remote.php/dav/files/${NCC_USER}"
  [[ -z "$NCC_PATH" ]] || url="${url}/${NCC_PATH}"
  printf '%s' "$url"
}

# ncc_netrc_lookup HOST - print "<login>\t<password>" from ~/.netrc; rc 1
# when the file or a matching machine entry is missing.
ncc_netrc_lookup() {
  local host="$1" file="${HOME}/.netrc"
  [[ -f "$file" ]] || return 1
  LC_ALL=C awk -v host="$host" '
    {
      for (i = 1; i <= NF; i++) {
        if ($i == "machine") cur = $(i + 1)
        else if (cur == host && $i == "login") login = $(i + 1)
        else if (cur == host && $i == "password") pass = $(i + 1)
      }
    }
    END {
      if (login != "") printf "%s\t%s\n", login, pass
    }
  ' "$file"
}

# ncc_prompt user|password - ask on the terminal through lib/ui.sh: the user
# name through ui_ask, the password through ui_ask_secret (read -s, so the
# typed secret is never echoed). The UI module is lazy, so it is required
# before the probes rather than silently skipped.
ncc_prompt() {
  local what="$1" prompt=""
  sciebo_require_module ui ui_ask
  if [[ "$what" == "user" ]]; then
    prompt="Username: "
    ui_ask "$prompt" || return 1
    NCC_USER="$UI_ASK_REPLY"
  else
    prompt="Password for ${NCC_USER}@${NCC_HOST}: "
    ui_ask_secret "$prompt" || return 1
    NCC_PASSWORD="$UI_ASK_REPLY"
  fi
  return 0
}

# ncc_pick_credential VAR OPT URL ENV NETRC NON_INTERACTIVE - assign VAR the
# first non-empty credential in the documented precedence: --user/--password,
# URL userinfo, the NC_USER/NC_PASSWORD environment variables (only for a
# non-interactive run), then the ~/.netrc entry. VAR is empty when none fits.
ncc_pick_credential() {
  local -n out="$1"
  local opt="$2" url="$3" env="${4:-}" netrc="${5:-}" non_interactive="$6"
  out=""
  # shellcheck disable=SC2034  # assigned through the nameref out-param
  if [[ -n "$opt" ]]; then
    out="$opt"
  elif [[ -n "$url" ]]; then
    out="$url"
  elif [[ "$non_interactive" == true && -n "$env" ]]; then
    out="$env"
  elif [[ -n "$netrc" ]]; then
    out="$netrc"
  fi
  return 0
}

# ncc_read_password - resolve the password input before the credential
# precedence runs: --password-fd N reads it from the already-open descriptor
# N (never the argv), while a plain --password keeps its value but warns
# because it is visible in the process list. Mirrors provision_read_password
# (lib/commands/provision.sh).
ncc_read_password() {
  local fd="${OPT_password_fd:-}"
  if [[ -z "$fd" ]]; then
    [[ -z "${OPT_password:-}" ]] ||
      warn "--password is visible in the process list; prefer --password-fd N"
    return 0
  fi
  if [[ -n "${OPT_password:-}" ]]; then
    usage_error nextcloudcmd "--password and --password-fd cannot be combined"
  fi
  # opt_read_fd_secret (lib/core.sh) owns the shared fd vocabulary
  # ("requires a file descriptor number"/"requires a positive file descriptor
  # number"/"is not readable"/"provided an empty password") that
  # tests/features/nextcloudcmd.sh asserts.
  opt_read_fd_secret nextcloudcmd --password-fd OPT_password "$fd"
  return 0
}

# ncc_resolve_credentials - apply the documented precedence:
# --user/--password > URL userinfo > NC_USER/NC_PASSWORD with
# --non-interactive > ~/.netrc with -n > interactive prompt. Dies (rc 1)
# when a non-interactive run has no credentials.
ncc_resolve_credentials() {
  local non_interactive=false netrc=false record="" netrc_user="" netrc_pass=""
  [[ -z "${OPT_non_interactive:-}" && -z "${SCIEBO_NON_INTERACTIVE:-}" ]] || non_interactive=true
  opt_into netrc netrc
  if [[ "$netrc" == true ]]; then
    # netrc_host (lib/core.sh) strips scheme/path/port; NCC_HOST is already
    # the bare authority ncc_parse_url produced, so only its port-stripping
    # half applies here (host, host:port, and bracketed IPv6 behave exactly
    # like the ncc-local copy this replaced).
    record="$(ncc_netrc_lookup "$(netrc_host "$NCC_HOST")")" || record=""
    if [[ -n "$record" ]]; then
      netrc_user="${record%%$'\t'*}"
      netrc_pass="${record#*$'\t'}"
      [[ "$netrc_pass" != "$record" ]] || netrc_pass=""
    fi
  fi
  ncc_pick_credential NCC_USER "${OPT_user:-}" "$NCC_URL_USER" "${NC_USER:-}" "$netrc_user" "$non_interactive"
  ncc_pick_credential NCC_PASSWORD "${OPT_password:-}" "$NCC_URL_PASS" "${NC_PASSWORD:-}" "$netrc_pass" "$non_interactive"
  if [[ -z "$NCC_USER" ]]; then
    [[ "$non_interactive" != true ]] ||
      die "no user for ${NCC_HOST}; use --user or set NC_USER with --non-interactive"
    ncc_prompt user || die "no user for ${NCC_HOST}"
  fi
  [[ -n "$NCC_USER" ]] || die "no user for ${NCC_HOST}"
  if [[ -z "$NCC_PASSWORD" ]]; then
    [[ "$non_interactive" != true ]] ||
      die "no password for ${NCC_USER}@${NCC_HOST}; use --password or set NC_PASSWORD with --non-interactive"
    ncc_prompt password || die "no password for ${NCC_USER}@${NCC_HOST}"
  fi
  [[ -n "$NCC_PASSWORD" ]] || die "no password for ${NCC_USER}@${NCC_HOST}"
}

# ncc_configure_remote URL - create or update the dedicated rclone remote.
# The plaintext password is obscured on rclone's stdin; because the obscured
# value is reversible, it must not reach an argv either, so the remote is
# written with a harmless obscured-empty placeholder and the real obscured
# value is patched into the plaintext config file afterwards. An encrypted
# config cannot be patched without exposing the reversible secret in the
# process list, so that case is refused (rclone's config write has no
# stdin/env path).
ncc_configure_remote() {
  local url="$1" obscured="" rc=0 placeholder=""
  if ! obscured="$(printf '%s' "$NCC_PASSWORD" | "$RCLONE_BIN" obscure -)"; then
    die "cannot obscure the password for '${NCC_REMOTE}' (rclone obscure failed)"
  fi
  placeholder="$(rclone_obscure_empty)"
  if rclone_cmd config create "$NCC_REMOTE" webdav "url=${url}" vendor=nextcloud \
    "user=${NCC_USER}" "pass=${placeholder}" >/dev/null; then
    rc=0
  else
    rc=$?
  fi
  [[ "$rc" -eq 0 ]] || die "cannot configure rclone remote '${NCC_REMOTE}'"
  if rclone_config_patch_value "$NCC_REMOTE" pass "$placeholder" "$obscured"; then
    remote_config_invalidate
  elif rclone_config_encrypted; then
    die "rclone config is encrypted, so the password cannot be patched in without exposing it in the process list; disable rclone config encryption (rclone config encryption remove) and re-run '${CLI_NAME} nextcloudcmd'"
  else
    # No encryption header: the placeholder is missing for some other reason.
    # The reversible secret still must not reach an argv, so warn and carry on
    # without falling back to an argv config update.
    warn "could not store the password for '${NCC_REMOTE}' in the rclone config"
  fi
}

# ncc_bisync_initialized WORKDIR - true when the workdir holds non-dry state.
# Delegates to bisync_initialized_dir (lib/settings.sh) so both bisync
# call sites share the same definition of "initialized".
ncc_bisync_initialized() {
  bisync_initialized_dir "$1"
}

# ncc_build_args_base SOURCEDIR WORKDIR - set NCC_ARGS to the core bisync
# invocation plus the conflict/resilience/lock settings.
ncc_build_args_base() {
  NCC_ARGS=(bisync "${1}/" "${NCC_REMOTE}:" --workdir "$2"
    --conflict-resolve "${BISYNC_CONFLICT_RESOLVE:-newer}"
    --conflict-loser "${BISYNC_CONFLICT_LOSER:-num}"
    --conflict-suffix "${BISYNC_CONFLICT_SUFFIX:-(conflicted copy)}")
  [[ "${BISYNC_RESILIENT:-1}" -ne 1 ]] || NCC_ARGS+=(--resilient)
  [[ "${BISYNC_RECOVER:-1}" -ne 1 ]] || NCC_ARGS+=(--recover)
  NCC_ARGS+=(--max-lock "${BISYNC_MAX_LOCK:-2m}")
}

# ncc_build_args_excludes - append the --exclude/--exclude-anchored/
# --unsyncedfolders filters, validating each file first.
ncc_build_args_excludes() {
  local line=""
  if [[ -n "${OPT_exclude:-}" ]]; then
    [[ -f "${OPT_exclude}" && -r "${OPT_exclude}" ]] ||
      die "--exclude file not found or unreadable: ${OPT_exclude}"
    NCC_ARGS+=(--exclude-from "${OPT_exclude}")
  fi
  if [[ -n "${OPT_exclude_anchored:-}" ]]; then
    [[ -f "${OPT_exclude_anchored}" && -r "${OPT_exclude_anchored}" ]] ||
      die "--exclude-anchored file not found or unreadable: ${OPT_exclude_anchored}"
    # Upstream reads the file and anchors every pattern at the sync root;
    # rclone spells that with a leading "/", and an already-anchored pattern
    # is kept as is. Passing one --exclude per line avoids a rewritten
    # --exclude-from temp file and reuses config_lines for blank/comment
    # lines, exactly like --unsyncedfolders.
    while IFS= read -r line; do
      case "$line" in
        /*) NCC_ARGS+=(--exclude "$line") ;;
        *) NCC_ARGS+=(--exclude "/${line}") ;;
      esac
    done < <(config_lines "${OPT_exclude_anchored}")
  fi
  if [[ -n "${OPT_unsyncedfolders:-}" ]]; then
    [[ -f "${OPT_unsyncedfolders}" ]] || die "--unsyncedfolders file not found: ${OPT_unsyncedfolders}"
    while IFS= read -r line; do
      line=${ strip_trailing_slashes "$line";}
      [[ -n "$line" ]] || continue
      NCC_ARGS+=(--exclude "$line")
    done < <(config_lines "${OPT_unsyncedfolders}")
  fi
}

# ncc_build_args_default_excludes - append the hidden-file and conflict-copy
# exclusions.
ncc_build_args_default_excludes() {
  if [[ -z "${OPT_hidden:-}" ]]; then
    NCC_ARGS+=(--exclude ".*")
  fi
  [[ "${CONFLICT_UPLOAD:-0}" -ne 0 ]] || NCC_ARGS+=(--exclude "*${CONFLICT_PATTERN:-conflicted copy}*")
}

# ncc_build_args_logging LOG_MODE - append the stats/log-level flags; "probe"
# selects rclone's default log level with --stats 0.
ncc_build_args_logging() {
  local log_mode="$1"
  if [[ "$log_mode" == "probe" ]]; then
    NCC_ARGS+=(--stats 0)
  elif [[ -n "${OPT_logdebug:-}" ]]; then
    NCC_ARGS+=(--stats 30s --stats-one-line --log-level DEBUG)
  elif [[ -n "${OPT_silent:-}" ]]; then
    NCC_ARGS+=(--log-level ERROR --stats 0)
  else
    NCC_ARGS+=(--stats 30s --stats-one-line --log-level INFO)
  fi
}

# ncc_append_progress LOG_MODE - append rclone's -P through the shared
# progress_append_args (lib/rclone.sh), which checks --progress, quiet, JSON
# mode, and progress_stdout_tty (the terminal probe this module used to
# duplicate as ncc_progress_tty). LOG_MODE "probe" is the captured
# --max-sync-retries dry-run check, which never shows a bar; --silent maps
# to the shared quiet argument.
ncc_append_progress() {
  local log_mode="$1" quiet=0
  [[ "$log_mode" != "probe" ]] || return 0
  opt_into quiet silent 1
  progress_append_args NCC_ARGS "$quiet"
}

# ncc_build_args_limits DRY_RUN RESYNC - append the bandwidth/retry/TLS
# flags and the --dry-run/--resync switches. The proxy is never hand-built
# into the argv here: ncc_prepare_workdir folds --httpproxy into PROXY and
# rclone_cmd routes it through _rclone_proxy_resolve (lib/rclone.sh), so
# proxy credentials stay out of ps.
ncc_build_args_limits() {
  local dry_run="$1" resync="$2"
  if [[ -n "${OPT_uplimit:-}" || -n "${OPT_downlimit:-}" ]]; then
    NCC_ARGS+=(--bwlimit "${OPT_uplimit:-off}:${OPT_downlimit:-off}")
  fi
  [[ -z "${OPT_max_sync_retries:-}" ]] || NCC_ARGS+=(--retries "${OPT_max_sync_retries}")
  # Verification is disabled only when it was turned off on purpose:
  # --trust (folded into TLS_INSECURE by ncc_parse_args) or TLS_INSECURE=1
  # from the environment/settings. load_settings always leaves a non-empty
  # "0"/"1", so the value must be compared, not the length.
  [[ "${TLS_INSECURE:-0}" == "1" || -n "${OPT_trust:-}" ]] && NCC_ARGS+=(--no-check-certificate)
  [[ "$dry_run" != true ]] || NCC_ARGS+=(--dry-run)
  [[ "$resync" != true ]] || NCC_ARGS+=(--resync)
}

# ncc_build_args SOURCEDIR WORKDIR DRY_RUN RESYNC [LOG_MODE] - fill NCC_ARGS
# with the bisync invocation and every filter/limit flag. LOG_MODE "probe"
# selects rclone's default log level with --stats 0 for the
# --max-sync-retries dry-run check, so its plan lines stay visible even with
# --silent, whose --log-level ERROR would suppress them.
ncc_build_args() {
  local sourcedir="$1" workdir="$2" dry_run="$3" resync="$4" log_mode="${5:-normal}"
  ncc_build_args_base "$sourcedir" "$workdir"
  ncc_build_args_excludes
  ncc_build_args_default_excludes
  ncc_build_args_logging "$log_mode"
  ncc_append_progress "$log_mode"
  ncc_build_args_limits "$dry_run" "$resync"
}

# ncc_parse_positionals - consume OPT_EXTRA as SOURCEDIR NEXTCLOUDURL: exactly
# two positionals, then parse the URL. Sets NCC_SOURCEDIR. Two positionals
# need a compound missing message and a too-many message that quotes the
# offending word, so opt_require_sub does not fit (its missing form is
# "<LABEL> is required", and value-bearing extras keep a hand-rolled check
# per that helper's doc).
ncc_parse_positionals() {
  local line="" sourcedir="" url="" nargs=0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    nargs=$((nargs + 1))
    case "$nargs" in
      1) sourcedir="$line" ;;
      2) url="$line" ;;
    esac
  done <<<"$OPT_EXTRA"
  [[ "$nargs" -ge 2 ]] || usage_error nextcloudcmd "SOURCEDIR and NEXTCLOUDURL are required"
  [[ "$nargs" -le 2 ]] || usage_error nextcloudcmd "unexpected argument: $(printable "${line}")"
  # The URL may carry user:pass@ userinfo, so only the redacted form may be
  # printed in the error line (url_redact_userinfo, lib/core.sh).
  ncc_parse_url "$url" || usage_error nextcloudcmd "invalid NEXTCLOUDURL: $(url_redact_userinfo "$url")"
  NCC_SOURCEDIR="$sourcedir"
}

# ncc_parse_retries - validate --max-sync-retries and set NCC_MAX_RETRIES.
ncc_parse_retries() {
  NCC_MAX_RETRIES=0
  if [[ -n "${OPT_max_sync_retries:-}" ]]; then
    # Not opt_require_uint: its non-negative wording is "--max-sync-retries
    # requires a non-negative integer"; this command's established "must
    # be ..." wording stays (byte-identical output).
    case "${OPT_max_sync_retries}" in
      '' | *[!0-9]*) usage_error nextcloudcmd "--max-sync-retries must be a non-negative integer" ;;
    esac
    NCC_MAX_RETRIES=$((10#${OPT_max_sync_retries}))
  fi
}

# ncc_resolve_derived - set the run state derived from the parsed options:
# NCC_PATH, NCC_DRY_RUN, TLS_INSECURE, and the --confdir export.
ncc_resolve_derived() {
  NCC_PATH=${ ncc_normalize_path "${OPT_path:-}";}
  NCC_DRY_RUN=false
  opt_into NCC_DRY_RUN dry_run
  opt_into TLS_INSECURE trust 1
  # --confdir must be exported before the first load_settings, which derives
  # every path from SCIEBO_CONFDIR; an existing value wins. The entrypoint's
  # early scan normally consumes the flag before this command is dispatched.
  if [[ -n "${OPT_confdir:-}" && -z "${SCIEBO_CONFDIR:-}" ]]; then
    export SCIEBO_CONFDIR="${OPT_confdir}"
  fi
}

# ncc_parse_args ARGS... - rewrite the short flags, parse the options, handle
# --version, validate the two positionals and NEXTCLOUDURL, and set
# NCC_SOURCEDIR/NCC_PATH plus NCC_DRY_RUN and NCC_MAX_RETRIES.
ncc_parse_args() {
  local spec=""
  ncc_prescan_args "$@"
  spec="path:s confdir:s user:s password:s password-fd:s netrc:b non-interactive:b silent:b trust:b httpproxy:s exclude:s exclude-anchored:s unsyncedfolders:s max-sync-retries:s uplimit:s downlimit:s logdebug:b hidden:b progress:b dry-run:b version:b"
  opt_begin "$spec" nextcloudcmd "" "${NCC_RAW_ARGS[@]}"
  if [[ -n "${OPT_version:-}" ]]; then
    printf '%s %s\n' "$CLI_NAME" "${SCIEBO_VERSION:-unknown}"
    exit 0
  fi
  ncc_read_password
  ncc_parse_positionals
  ncc_parse_retries
  ncc_resolve_derived
}

# ncc_prepare_workdir - load settings, resolve credentials, configure the
# dedicated remote, and create the per-target workdir. Sets NCC_WORKDIR and
# NCC_RESYNC (true when the workdir has no bisync state yet).
ncc_prepare_workdir() {
  local webdav="" path_key="" digest=""
  load_settings
  # --httpproxy overrides the PROXY setting for this run. From here the
  # proxy is entirely rclone_cmd's business: _rclone_proxy_resolve classifies
  # it with the shared _proxy_classify and routes an http(s) URL through the
  # rclone child's environment instead of its argv (credentials never reach
  # ps), keeps a socks URL as --http-proxy, honors PROXY_TYPE/PROXY_DIRECT,
  # and strips the ambient proxy environment for a direct run.
  # shellcheck disable=SC2034  # read by _rclone_proxy_resolve inside rclone_cmd (lib/rclone.sh)
  opt_into PROXY httpproxy "${OPT_httpproxy:-}"
  ensure_state_dirs
  ncc_resolve_credentials
  webdav=${ ncc_webdav_url;}
  ncc_configure_remote "$webdav"
  path_key="${NCC_HOST}-${NCC_PATH}"
  # sanitize_name collapses distinct byte sequences (e.g. "a/b" and "a_b") to
  # the same name; the checksum keeps the workdir injective so two different
  # targets never share bisync state.
  digest="$(printf '%s' "$path_key" | cksum | awk '{print $1}')"
  NCC_WORKDIR="${STATE_DIR}/nextcloudcmd/$(sanitize_name "$path_key")-${digest}"
  mkdir -p "$NCC_WORKDIR" 2>/dev/null || die "cannot create bisync workdir: ${NCC_WORKDIR}"
  NCC_RESYNC=false
  if ! ncc_bisync_initialized "$NCC_WORKDIR"; then
    NCC_RESYNC=true
    warn "nextcloudcmd: no bisync state in ${NCC_WORKDIR}; first run uses --resync"
  fi
}

# ncc_retry_loop - while the dry-run probe reports remaining changes, rerun
# the real sync up to NCC_MAX_RETRIES times. Returns 1 when a sync fails. The
# retries never pass --resync: the first run initialized the state.
ncc_retry_loop() {
  local attempts=0 probe_out="" probe_rc=0 rc=0
  [[ "$NCC_DRY_RUN" != true && "$NCC_MAX_RETRIES" -gt 0 ]] || return 0
  # Upstream loops the whole sync while the engine reports that another sync
  # is needed. rclone exits 0 for a dry run whether or not it would change
  # anything (verified with rclone 1.75.1), so the "as --dry-run is set" plan
  # marker is the reliable signal, exactly as watch_remote_poll uses it.
  attempts=0
  while [[ "$attempts" -lt "$NCC_MAX_RETRIES" ]]; do
    attempts=$((attempts + 1))
    ncc_build_args "$NCC_SOURCEDIR" "$NCC_WORKDIR" true false probe
    probe_rc=0
    probe_out="$(rclone_cmd "${NCC_ARGS[@]}" 2>&1)" || probe_rc=$?
    if [[ "$probe_rc" -ne 0 ]]; then
      # A failed probe cannot prove convergence, so the run is reported as
      # failed instead of letting the max-sync-retries loop mask it.
      warn "nextcloudcmd: dry-run check failed (exit ${probe_rc}); cannot confirm the sync is complete"
      return 1
    fi
    case "$probe_out" in
      *'as --dry-run is set'*) ;;
      *) break ;;
    esac
    ncc_build_args "$NCC_SOURCEDIR" "$NCC_WORKDIR" false false
    if rclone_cmd "${NCC_ARGS[@]}"; then
      rc=0
    else
      rc=$?
    fi
    [[ "$rc" -eq 0 ]] || return 1
  done
  return 0
}

cmd_nextcloudcmd() {
  ncc_parse_args "$@"
  ncc_prepare_workdir
  ncc_build_args "$NCC_SOURCEDIR" "$NCC_WORKDIR" "$NCC_DRY_RUN" "$NCC_RESYNC"
  if rclone_cmd "${NCC_ARGS[@]}"; then
    :
  else
    return 1
  fi
  ncc_retry_loop || return 1
  printf 'nextcloudcmd: synced %s <-> %s\n' "$NCC_SOURCEDIR" "${NCC_PATH:-/}"
  return 0
}
