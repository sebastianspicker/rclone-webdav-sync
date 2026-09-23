#!/bin/bash
# core.sh - shell setup, paths, output, option parsing, pure helpers.
#
# Sourced once by bin/sciebo (and by tests); requires Bash 5.3.
#
# Module conventions:
#   - Command functions return a status; only die/usage_error exit.
#   - Commands never call each other in-process; they exec bin/sciebo.
#   - Module-private globals are prefixed per module (ENTRY_*, MNT_*,
#     P_*, T_*, CHOOSE_*, OPT_*); other temporaries stay local.

# Fork removal: dirname is parameter expansion (a BASH_SOURCE without a "/"
# is prefixed with "./" so ${...%/*} yields "."), and PROJECT_DIR is a "/lib"
# suffix strip instead of a second cd/pwd subshell. LIB_DIR keeps one cd/pwd
# subshell (plain pwd, matching SCRIPT_DIR in bin/sciebo) so a checkout
# reached through symlinks resolves exactly as before; the suffix strip only
# applies when the lib directory is named "lib" (the dev tree and the
# PREFIX/share/rclone-sciebo install layout both are) and falls back to the
# old cd/pwd otherwise, so it can never silently produce a wrong root.
_sciebo_src="${BASH_SOURCE[0]}"
case "$_sciebo_src" in
  */*) ;;
  *) _sciebo_src="./$_sciebo_src" ;;
esac
LIB_DIR="$(cd "${_sciebo_src%/*}" && pwd)"
unset _sciebo_src
case "$LIB_DIR" in
  */lib) PROJECT_DIR="${LIB_DIR%/lib}" ;;
  *) PROJECT_DIR="$(cd "${LIB_DIR}/.." && pwd)" ;;
esac

# patsub_replacement is the default in Bash 5.2+: in ${var//pat/repl} an
# unescaped "&" expands to the matched text, so a literal "&" in a replacement
# must be written "\&" (e.g. schedule_xml_escape builds "&amp;" as "\&amp;").
# shellcheck disable=SC2034  # read by the command modules
CONFIG_DIR="${PROJECT_DIR}/config"
CLI_NAME="sciebo"
# Absolute path of the interpreter running this process (already verified to
# be >= 5.3 by bin/sciebo). Generated launchd/systemd units and shims reuse it.
# shellcheck disable=SC2034  # read by lib/commands/schedule.sh
SCIEBO_BASH="${BASH:-bash}"
# Read once; empty when the tree has no VERSION file (e.g. odd checkouts).
SCIEBO_VERSION=""
if [[ -f "${PROJECT_DIR}/VERSION" ]]; then
  # Fork removal: $(<file) plus a whitespace patsub replace the tr process
  # (byte-identical to tr -d '[:space:]' for a VERSION file); the || keeps
  # the old empty result when the file cannot be read, exactly like the
  # failing redirect did before.
  # shellcheck disable=SC2034  # read by the command modules
  SCIEBO_VERSION="$(<"${PROJECT_DIR}/VERSION")" || SCIEBO_VERSION=""
  SCIEBO_VERSION="${SCIEBO_VERSION//[[:space:]]/}"
fi

# Defensive umask: bin/sciebo sets 077 before sourcing, but a library consumer
# that sources core.sh directly (tests, tooling) must not create
# world-readable state or temp files either.
umask 077

# ---------------------------------------------------------------------------
# Output
#
# The timestamp is cached for the current SECONDS tick: loops that log once
# per candidate (cleanup, sync) would otherwise fork `date` per line.
# _log_stamp_refresh sets _LOG_STAMP in the current shell (a $() wrapper
# would run in a subshell and lose the cache).
# ---------------------------------------------------------------------------

_LOG_STAMP=""
_LOG_STAMP_SECONDS=""

_log_stamp_refresh() {
  [[ "$SECONDS" != "$_LOG_STAMP_SECONDS" || -z "$_LOG_STAMP" ]] || return 0
  _LOG_STAMP_SECONDS="$SECONDS"
  _LOG_STAMP="$(date '+%Y-%m-%d %H:%M:%S')"
}

log() {
  _log_stamp_refresh
  printf '[%s] %s\n' "$_LOG_STAMP" "$*"
}
warn() {
  _log_stamp_refresh
  printf '[%s] WARN: %s\n' "$_LOG_STAMP" "$*" >&2
}
err() {
  _log_stamp_refresh
  printf '[%s] ERROR: %s\n' "$_LOG_STAMP" "$*" >&2
}

# die MESSAGE - operational failure; exits 1.
die() {
  err "$*"
  exit 1
}

# usage_emit - print a usage heredoc on stdin without forking `cat`
# (read -d '' slurps to EOF; || true because read hits EOF rc 1 under set -e).
usage_emit() {
  local _h=""
  IFS= read -r -d '' _h || true
  printf '%s' "$_h"
}

# usage_error COMMAND MESSAGE - usage failure; prints the command usage to
# stderr and exits 2. COMMAND must have a usage_<command> function.
usage_error() {
  local command="$1"
  shift
  printf '%s %s: %s\n\n' "$CLI_NAME" "$command" "$*" >&2
  "usage_${command}" >&2 || true
  exit 2
}

# usage_unknown_sub COMMAND VALUE - the shared "unknown subcommand" usage
# failure: VALUE is passed through printable so control bytes from user input
# cannot reach the terminal inside the error line.
usage_unknown_sub() {
  usage_error "$1" "unknown subcommand: $(printable "${2:-}")"
}

# unknown_source_prefix NAME - print "no source named '<NAME>'" with no trailing
# newline, NAME passed through printable so control bytes from user input cannot
# reach the terminal. The one prefix behind the source-resolution failures;
# callers add their own suffix and choose the channel (die/err/status stderr).
unknown_source_prefix() {
  printf "no source named '%s'" "$(printable "${1:-}")"
}

have() { command -v "$1" >/dev/null 2>&1; }

# have_function NAME - true when NAME is a defined function (or builtin).
have_function() { type -t "$1" >/dev/null 2>&1; }

# sciebo_require_module NAME SENTINEL_FUNCTION - source lib/NAME.sh unless
# SENTINEL_FUNCTION is already defined, so a module that is sourced on its
# own can load a shared dependency without reloading it when bin/sciebo
# already did. LIB_DIR is resolved once from core.sh's own location and
# falls back to the caller's directory. A missing file is not an error
# (callers use this for genuinely optional dependencies), but a readable
# module that fails to source is fatal: swallowing the error would leave
# the caller with missing functions and a confusing failure later.
sciebo_require_module() {
  local name="${1:-}" sentinel="${2:-}" dir="" file=""
  have_function "$sentinel" && return 0
  dir="${LIB_DIR:-}"
  if [[ -z "$dir" ]]; then
    dir="$(cd "$(dirname "${BASH_SOURCE[1]:-}")" && pwd)"
  fi
  file="${dir}/${name}.sh"
  [[ -r "$file" ]] || return 0
  # shellcheck disable=SC1090,SC1091  # runtime path relative to LIB_DIR
  source "$file" || die "failed to load module: ${name}"
  return 0
}

# ---------------------------------------------------------------------------
# Long-option parsing
#
# SPEC entries are space-separated NAME:KIND pairs:
#   s  single value       -> OPT_<name>
#   S  repeatable value   -> OPT_<name>, newline-separated
#   b  boolean flag       -> OPT_<name>=1
#   o  optional value     -> OPT_<name>; written NAME:o:DEFAULT, where
#                           DEFAULT may be empty. --name / --name=VALUE
#                           sets the value, but when the next token is
#                           absent or starts with "-" DEFAULT is used
#                           instead of consuming it. OPT_<name>_SET=1
#                           whenever the flag appears.
# Names use dashes on the command line and underscores in the globals.
#
# opt_parse SPEC COMMAND LABEL "$@"
#   Sets OPT_HELP=1 for -h/--help (callers print their usage), collects
#   positional arguments in OPT_EXTRA (newline-separated), marks provided
#   options with OPT_<name>_SET=1, and routes errors through
#   usage_error COMMAND "LABEL...".
#
# opt_begin SPEC COMMAND LABEL "$@" - the shared prologue: reset the OPT_*
#   globals derived from SPEC, run opt_parse, then opt_help_guard.
# opt_json_mode - enable JSON output from the parsed --json flag.
# ---------------------------------------------------------------------------

opt_reset() {
  local name key
  OPT_HELP=0
  OPT_EXTRA=""
  for name in "$@"; do
    key="${name//-/_}"
    unset "OPT_${key}" "OPT_${key}_SET"
  done
}

# _opt_spec_lookup SPEC NAME - set OPT_LOOKUP_KIND and OPT_LOOKUP_DEFAULT from
# the first SPEC entry matching NAME (entries are space-separated NAME:KIND or
# NAME:KIND:DEFAULT), or return 1 when NAME is absent or has an empty kind.
# A single-part entry has an empty DEFAULT. Writes globals instead of printing
# so opt_parse can read the result without a command-substitution fork per
# option.
_opt_spec_lookup() {
  local spec="$1" name="$2" entry="" rest="" kind="" default=""
  for entry in $spec; do
    case "$entry" in
      "${name}:"*)
        rest="${entry#*:}"
        case "$rest" in
          *:*) kind="${rest%%:*}" default="${rest#*:}" ;;
          *) kind="$rest" ;;
        esac
        [[ -n "$kind" ]] || return 1
        OPT_LOOKUP_KIND="$kind"
        OPT_LOOKUP_DEFAULT="$default"
        return 0
        ;;
    esac
  done
  return 1
}

# _opt_store KIND KEYVAR VALUE - store VALUE in the OPT_<name> global named by
# KEYVAR: "b" stores the flag 1, "S" appends a newline-separated value, and
# every other kind replaces the value.
_opt_store() {
  local kind="$1" keyvar="$2" value="$3"
  case "$kind" in
    b) printf -v "$keyvar" '1' ;;
    S) printf -v "$keyvar" '%s%s\n' "${!keyvar:-}" "$value" ;;
    *) printf -v "$keyvar" '%s' "$value" ;;
  esac
}

opt_parse() {
  local spec="$1" command="$2" label="$3"
  shift 3
  local token name value kind="" default="" key keyvar=""
  OPT_HELP=0
  OPT_EXTRA=""
  while [[ $# -gt 0 ]]; do
    token="$1"
    shift
    case "$token" in
      -h | --help)
        # shellcheck disable=SC2034  # read by callers after opt_parse
        OPT_HELP=1
        return 0
        ;;
      --)
        while [[ $# -gt 0 ]]; do
          OPT_EXTRA="${OPT_EXTRA}${1}"$'\n'
          shift
        done
        return 0
        ;;
      --*=*)
        name="${token#--}"
        value="${name#*=}"
        name="${name%%=*}"
        ;;
      --*)
        name="${token#--}"
        value=""
        ;;
      *)
        OPT_EXTRA="${OPT_EXTRA}${token}"$'\n'
        continue
        ;;
    esac
    _opt_spec_lookup "$spec" "$name" ||
      usage_error "$command" "${label}unknown option: --$(printable "$name")"
    kind="$OPT_LOOKUP_KIND"
    default="$OPT_LOOKUP_DEFAULT"
    key="${name//-/_}"
    keyvar="OPT_${key}"
    case "$kind" in
      b)
        [[ -z "$value" ]] || usage_error "$command" "${label}--${name} does not take a value"
        ;;
      o)
        if [[ -z "$value" ]]; then
          if [[ $# -gt 0 && -n "${1:-}" && "$1" != -* ]]; then
            value="$1"
            shift
          else
            value="$default"
          fi
        fi
        ;;
      *)
        if [[ -z "$value" ]]; then
          [[ $# -gt 0 && -n "${1:-}" ]] || usage_error "$command" "${label}--${name} requires a value"
          value="$1"
          shift
        fi
        ;;
    esac
    _opt_store "$kind" "$keyvar" "$value"
    printf -v "OPT_${key}_SET" '1'
  done
  return 0
}

# opt_begin SPEC COMMAND LABEL "$@" - reset the OPT_* globals named by SPEC,
# parse "$@", then honor -h/--help. Deriving the names from SPEC keeps the
# reset in sync with the parse; commands call this instead of the
# opt_reset/opt_parse/opt_help_guard prologue.
opt_begin() {
  local spec="$1" command="$2" label="$3"
  shift 3
  local entry name
  local -a names=()
  for entry in $spec; do
    name="${entry%%:*}"
    names+=("$name")
  done
  opt_reset "${names[@]}"
  opt_parse "$spec" "$command" "$label" "$@"
  opt_help_guard "$command"
}

# opt_json_mode - enable JSON output from the parsed --json flag.
opt_json_mode() {
  output_mode_set "${OPT_json:-false}"
}

# opt_help_guard COMMAND - print COMMAND's usage and exit 0 when -h/--help
# was given; a no-op otherwise. Call right after opt_parse.
opt_help_guard() {
  [[ "${OPT_HELP:-0}" -ne 0 ]] || return 0
  "usage_${1}"
  exit 0
}

# opt_guard COMMAND [LABEL] - opt_help_guard plus the generic rejection of
# unexpected positionals/options. For commands that take no positional
# arguments; commands that do call opt_help_guard and validate OPT_EXTRA
# themselves. LABEL prefixes the error for subcommands (e.g. "list: ").
opt_guard() {
  opt_help_guard "$1"
  [[ -z "${OPT_EXTRA:-}" ]] ||
    usage_error "$1" "${2:-}unknown option: $(printable "${OPT_EXTRA%%$'\n'*}")"
}

# opt_reject CMD SUB FLAG... - usage_error when any named option was given for
# a subcommand that does not accept it: "<SUB> does not accept --<FLAG>". Each
# FLAG is the option spelling without "--" (hyphens normalize to underscores)
# and its OPT_<flag>_SET marker is tested, so this is the shared form of the
# per-subcommand "does not accept" rejections. Returns 0 when none was given.
opt_reject() {
  local command="$1" sub="$2" flag="" setvar=""
  shift 2
  for flag in "$@"; do
    setvar="OPT_${flag//-/_}_SET"
    [[ -z "${!setvar:-}" ]] || usage_error "$command" "${sub} does not accept --${flag}"
  done
  return 0
}

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

# opt_require_uint CMD FLAG VALUE MIN [MAX] [MSG] - validate one numeric option
# value: VALUE must be a non-empty run of ASCII digits (is_uint), at least
# MIN, and - when MAX is given - at most MAX. On violation the run stops
# through usage_error CMD (exit 2) with one of these wordings:
#   non-digits / below MIN with MIN >= 1: "<FLAG> requires a positive integer"
#   non-digits with MIN = 0:              "<FLAG> requires a non-negative integer"
#   above MAX:                            "<FLAG> must be at most <MAX>"
# MSG, when non-empty, replaces the first wording (non-digits / below MIN)
# with the caller's exact text - the commands whose message carries the
# offending value ("--interval must be a positive integer (got 'x')") pass it
# here instead of hand-rolling the whole check. The above-MAX wording is
# unchanged. FLAG is spelled the way it appears on the command line
# ("--limit", "--size"); the two base wordings are byte-identical to the
# hand-rolled validators this replaces. Callers that clamp instead of failing
# (activity's --limit cap) keep their own check; this helper is for flags that
# must reject the value. Returns 0 when VALUE passes; it never returns on a
# violation (usage_error exits 2).
opt_require_uint() {
  local command="$1" flag="$2" value="${3:-}" min="${4:-1}" max="${5:-}" msg="${6:-}"
  local kind="positive integer" number=0
  if [[ "$min" -lt 1 ]]; then kind="non-negative integer"; fi
  if ! is_uint "$value" || [[ "$((10#$value))" -lt "$min" ]]; then
    if [[ -n "$msg" ]]; then usage_error "$command" "$msg"; fi
    usage_error "$command" "${flag} requires a ${kind}"
  fi
  number=$((10#$value))
  if [[ -n "$max" && "$number" -gt "$max" ]]; then
    usage_error "$command" "${flag} must be at most ${max}"
  fi
  return 0
}

# opt_into VAR FLAG [TRUEWORD] - set VAR to TRUEWORD (default "true") when the
# boolean option FLAG was given, leaving VAR untouched otherwise. FLAG is the
# OPT_ key suffix without the prefix ("yes", "quiet", "dry_run"); the pair
# collapses the ubiquitous `[[ -z "${OPT_x:-}" ]] || var=...` fold. VAR may be
# a local or a global: printf -v writes through the dynamic scope.
opt_into() {
  local var="$1" flag="$2" word="${3:-true}" name="OPT_${2:-}"
  [[ -z "${!name:-}" ]] || printf -v "$var" '%s' "$word"
}

# opt_require_sub CMD LABEL SUB [MIN] [MAX] [TOO_MANY] - enforce the
# positional-count rules of a (mostly) single-positional command. SUB is the
# newline-separated positional list (raw OPT_EXTRA or an already-trimmed
# copy; split_positionals parses either) and the parsed words are left in
# POSITIONAL_ARGS for the caller. MIN/MAX default to 1/1 and only count and
# emptiness are checked - path safety stays with require_safe_remote_path,
# which the caller runs on the surviving positional.
# Contract: returns 0 when MIN <= count <= MAX; otherwise usage_error CMD
# (exit 2) with one of these message forms (LABEL phrases the positional):
#   count < MIN:  "<LABEL> is required"                    (MIN >= 1)
#       "SUB is required", "a remote path argument is required",
#       "a search term is required" are LABEL=SUB / LABEL="a remote path
#       argument" / LABEL="a search term".
#   count > MAX, TOO_MANY unset - derived from MIN/MAX:
#       MIN = 0, MAX = 1: "at most one <LABEL> argument is allowed"
#       MAX = 1:          "exactly one <LABEL> argument is allowed"
#       MAX > 1:          "at most <word(MAX)> <LABEL> arguments are allowed"
#   count > MAX, TOO_MANY set: used verbatim, for command-specific wording
#       (search's "search accepts exactly one term; quote a term with
#       spaces", download's "at most SUB and DEST are allowed", ...).
# Value-bearing extras ("unexpected argument: <arg>") keep their hand-rolled
# check: the message needs the offending word, which this helper does not
# interpolate.
opt_require_sub() {
  local command="$1" label="$2" sub="${3:-}"
  local min="${4:-1}" max="${5:-1}" too_many="${6:-}"
  local count=0 rule="" num_word=""
  split_positionals "$sub"
  count="${#POSITIONAL_ARGS[@]}"
  if [[ "$count" -lt "$min" ]]; then
    usage_error "$command" "${label} is required"
  fi
  if [[ "$count" -gt "$max" ]]; then
    if [[ -n "$too_many" ]]; then
      usage_error "$command" "$too_many"
    fi
    if [[ "$max" -gt 1 ]]; then
      case "$max" in
        2) num_word="two" ;;
        3) num_word="three" ;;
        *) num_word="$max" ;;
      esac
      usage_error "$command" "at most ${num_word} ${label} arguments are allowed"
    fi
    if [[ "$min" -eq 0 ]]; then rule="at most one"; else rule="exactly one"; fi
    usage_error "$command" "${rule} ${label} argument is allowed"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Pure helpers
# ---------------------------------------------------------------------------

# config_lines FILE - print the non-blank, non-comment lines of a config
# file (the manifest, roots, and doctor readers share this convention).
config_lines() {
  awk 'NF && $0 !~ /^[[:space:]]*#/' "$1"
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# trim_into VAR VALUE - trim VALUE into VAR without a command substitution.
# Hot callers (manifest_parse_line) use this to avoid a subshell per field.
trim_into() {
  local s="$2"
  s="${s#"${s%%[![:space:]]*}"}"
  printf -v "$1" '%s' "${s%"${s##*[![:space:]]}"}"
}

# xml_escape_into VAR TEXT [all] - XML-escape TEXT into VAR without a command
# substitution. The default escapes the element-body metacharacters & < >; the
# literal mode "all" also escapes the attribute quote characters " and '. The
# two callers keep their own wrapper (nc_xml_escape escapes quotes,
# schedule_xml_escape does not), so the entity spellings stay identical.
# patsub_replacement is on by default in Bash 5.2+, so a literal "&" in a
# replacement must be written "\&" or it would expand to the matched text.
xml_escape_into() {
  local _xe_s="${2:-}"
  _xe_s="${_xe_s//&/\&amp;}"
  _xe_s="${_xe_s//</\&lt;}"
  _xe_s="${_xe_s//>/\&gt;}"
  if [[ "${3:-}" == "all" ]]; then
    _xe_s="${_xe_s//\"/\&quot;}"
    _xe_s="${_xe_s//\'/\&apos;}"
  fi
  printf -v "$1" '%s' "$_xe_s"
}

# printable NAME - strip C0 and C1 control bytes before showing
# server-controlled names (remote folders) so they cannot emit terminal
# escape sequences. Display only; never use this for values passed back to
# rclone. Byte semantics (LC_ALL=C) so the explicit 0x80-0x9F range matches;
# TAB and newline are stripped like every other C0 byte.
printable() {
  # UTF-8-aware: drops C0/DEL, encoded/stray C1 bytes, and malformed UTF-8
  # but keeps valid multi-byte characters, so server-controlled names cannot
  # inject terminal escapes without corrupting non-ASCII names.
  strip_control_bytes "$1"
}

# _AWK_CTRL_LIB - the shared awk UTF-8 control stripper. ctrl_strip(s, KEEP)
# drops C0 control bytes and DEL (keeping TAB 0x09 and LF 0x0A only when KEEP
# is 1, which sanitize_stream wants and the XML/secret scrubbers do not),
# encoded C1 (a valid C2 80..C2 9F two-byte sequence for U+0080..U+009F, e.g.
# the 8-bit CSI 0x9B), and invalid UTF-8, while preserving valid 2/3/4-byte
# sequences. The exact byte rules:
#   - C0/C1 0xC0-0xC1 are invalid leads (overlong two-byte forms),
#   - a three-byte E0 requires the second byte A0..BF (no overlong),
#   - ED requires the second byte 80..9F (no UTF-16 surrogates),
#   - a four-byte F0 requires the second byte 90..BF (no overlong),
#   - F4 requires the second byte 80..8F (no codepoints above U+10FFFF),
#   - stray continuation bytes 0x80-0xBF and 0xF5-0xFF are dropped.
# A malformed sequence is removed with its continuation run, so e.g.
# ED A0 80 and F4 90 80 80 disappear whole.
#
# At LC_ALL=C, BWK awk exposes byte semantics, so the C-locale hot path
# removes C0/DEL and encoded C1 with whole-string gsub passes (C speed, so a
# huge ASCII line never enters the per-byte loop) and only scans when a high
# byte remains; that scan reads bytes via split (O(1) each) and emits runs
# with substr, so a 1MB line stays linear instead of the old O(n^2)
# `out = out c`. Under a UTF-8 locale, regex and split reject the invalid
# bytes this function exists to remove (BWK awk: "multibyte conversion
# failure"), so ctrl_strip falls back to a regex-free byte scan. Compose as
# `awk "${_AWK_CTRL_LIB}"'<program>'`; sanitize_stream and the HTTP scrubbers
# pass LC_ALL=C for the fast path.
_AWK_CTRL_LIB='
function ctrl_build(    i) {
  if (ctrl_ready) return
  ctrl_ready = 1
  for (i = 1; i <= 31; i++) ctrl_c0 = ctrl_c0 sprintf("%c", i)
  ctrl_c0 = ctrl_c0 sprintf("%c", 127)
  for (i = 128; i <= 191; i++) ctrl_cont = ctrl_cont sprintf("%c", i)
  for (i = 128; i <= 159; i++) ctrl_cont_80_9f = ctrl_cont_80_9f sprintf("%c", i)
  for (i = 128; i <= 143; i++) ctrl_cont_80_8f = ctrl_cont_80_8f sprintf("%c", i)
  for (i = 144; i <= 191; i++) ctrl_cont_90_bf = ctrl_cont_90_bf sprintf("%c", i)
  for (i = 160; i <= 191; i++) ctrl_cont_a0_bf = ctrl_cont_a0_bf sprintf("%c", i)
  for (i = 194; i <= 223; i++) ctrl_lead2 = ctrl_lead2 sprintf("%c", i)
  for (i = 224; i <= 239; i++) ctrl_lead3 = ctrl_lead3 sprintf("%c", i)
  for (i = 240; i <= 244; i++) ctrl_lead4 = ctrl_lead4 sprintf("%c", i)
  ctrl_lead_c2 = sprintf("%c", 194)
  ctrl_lead_e0 = sprintf("%c", 224)
  ctrl_lead_ed = sprintf("%c", 237)
  ctrl_lead_f0 = sprintf("%c", 240)
  ctrl_lead_f4 = sprintf("%c", 244)
  ctrl_bad_high = sprintf("%c%c", 192, 193)
  for (i = 245; i <= 255; i++) ctrl_bad_high = ctrl_bad_high sprintf("%c", i)
}
# ctrl_in_c_locale() - true when awk runs with byte semantics, so the
# regex/split fast path is safe. POSIX awk derives its locale from LC_ALL,
# else LC_CTYPE, else LANG; an unset locale is the C locale.
function ctrl_in_c_locale(    l) {
  l = ENVIRON["LC_ALL"]
  if (l == "") l = ENVIRON["LC_CTYPE"]
  if (l == "") l = ENVIRON["LANG"]
  return (l == "" || l == "C" || l == "POSIX")
}
# ctrl_strip_bytes(s, keep_tab_lf) - the locale-agnostic fallback: byte-wise
# substr/index only (no regex or split), for the XML parsers that run under
# the caller locale on small field values.
function ctrl_strip_bytes(s, keep_tab_lf,    i, n, c, start, out, need, j, b2, ok) {
  ctrl_build()
  out = ""
  n = length(s)
  start = 1
  i = 1
  while (i <= n) {
    c = substr(s, i, 1)
    if (index(ctrl_c0, c) > 0) {
      if (keep_tab_lf == 1 && (c == "\t" || c == "\n")) {
        i++
        continue
      }
    } else if (index(ctrl_cont, c) > 0 || index(ctrl_bad_high, c) > 0) {
      # drop below
    } else {
      need = 0
      if (index(ctrl_lead2, c) > 0) need = 1
      else if (index(ctrl_lead3, c) > 0) need = 2
      else if (index(ctrl_lead4, c) > 0) need = 3
      if (need > 0) {
        ok = (i + need <= n)
        for (j = 1; ok && j <= need; j++) {
          if (index(ctrl_cont, substr(s, i + j, 1)) == 0) ok = 0
        }
        if (ok) {
          b2 = substr(s, i + 1, 1)
          if (c == ctrl_lead_c2 && index(ctrl_cont_80_9f, b2) > 0) ok = 0
          else if (c == ctrl_lead_e0 && index(ctrl_cont_a0_bf, b2) == 0) ok = 0
          else if (c == ctrl_lead_ed && index(ctrl_cont_80_9f, b2) == 0) ok = 0
          else if (c == ctrl_lead_f0 && index(ctrl_cont_90_bf, b2) == 0) ok = 0
          else if (c == ctrl_lead_f4 && index(ctrl_cont_80_8f, b2) == 0) ok = 0
        }
        if (ok) {
          i += 1 + need
          continue
        }
        if (i > start) out = out substr(s, start, i - start)
        i++
        while (i <= n && index(ctrl_cont, substr(s, i, 1)) > 0) i++
        start = i
        continue
      }
      i++
      continue
    }
    if (i > start) out = out substr(s, start, i - start)
    i++
    start = i
  }
  if (n >= start) out = out substr(s, start, n - start + 1)
  return out
}
function ctrl_strip(s, keep_tab_lf,    i, n, a, c, start, out, need, j, b2, ok) {
  ctrl_build()
  if (!ctrl_in_c_locale()) return ctrl_strip_bytes(s, keep_tab_lf)
  if (keep_tab_lf == 1) gsub(/[\001-\010\013-\037\177]/, "", s)
  else gsub(/[\001-\037\177]/, "", s)
  gsub(/\302[\200-\237]/, "", s)
  if (s !~ /[\200-\377]/) return s
  n = split(s, a, "")
  out = ""
  start = 1
  i = 1
  while (i <= n) {
    c = a[i]
    if (index(ctrl_cont, c) > 0 || index(ctrl_bad_high, c) > 0) {
      if (i > start) out = out substr(s, start, i - start)
      i++
      start = i
      continue
    }
    need = 0
    if (index(ctrl_lead2, c) > 0) need = 1
    else if (index(ctrl_lead3, c) > 0) need = 2
    else if (index(ctrl_lead4, c) > 0) need = 3
    if (need > 0) {
      ok = (i + need <= n)
      for (j = 1; ok && j <= need; j++) {
        if (index(ctrl_cont, a[i + j]) == 0) ok = 0
      }
      if (ok) {
        b2 = a[i + 1]
        if (c == ctrl_lead_c2 && index(ctrl_cont_80_9f, b2) > 0) ok = 0
        else if (c == ctrl_lead_e0 && index(ctrl_cont_a0_bf, b2) == 0) ok = 0
        else if (c == ctrl_lead_ed && index(ctrl_cont_80_9f, b2) == 0) ok = 0
        else if (c == ctrl_lead_f0 && index(ctrl_cont_90_bf, b2) == 0) ok = 0
        else if (c == ctrl_lead_f4 && index(ctrl_cont_80_8f, b2) == 0) ok = 0
      }
      if (ok) {
        i += 1 + need
        continue
      }
      if (i > start) out = out substr(s, start, i - start)
      i++
      while (i <= n && index(ctrl_cont, a[i]) > 0) i++
      start = i
      continue
    }
    i++
  }
  if (n >= start) out = out substr(s, start, n - start + 1)
  return out
}
'

# sanitize_stream - filter stdin, dropping C0 control bytes (including ESC and
# CR), DEL, encoded C1 (C2 80-9F), stray C1 bytes, and invalid UTF-8
# lead/continuation bytes while preserving valid 2/3/4-byte UTF-8 sequences, so
# server- or rclone-derived multi-line output cannot inject terminal escape
# sequences (a bare CR can move the cursor and overwrite an earlier line). awk
# reads line by line, so newlines are preserved, and TAB is kept because
# indented listings rely on it. One LC_ALL=C awk pass (one process) over the
# shared _AWK_CTRL_LIB, so strip_control_bytes and the http scrubbers share
# the exact byte rules.
sanitize_stream() {
  LC_ALL=C awk "${_AWK_CTRL_LIB}"'
    { print ctrl_strip($0, 1) }
  '
}

# format_size_bytes BYTES [STYLE] - compact human size for display; a
# non-numeric value is printed unchanged for every style. Pure bash so hot
# callers (conflicts, cleanup, logs) do not fork awk per row. STYLE selects
# the rendering:
#   (unset), "", iec  the report style: 512B, 1.0KiB, 3.4MiB, 12GiB -
#                     byte-identical to the original single-argument form
#   rclone            the way rclone writes SizeSuffix values: an exact
#                     binary multiple as an integer with Ki/Mi/Gi
#                     (104857600 -> 100Mi, 2048 -> 2Ki), any other count
#                     as the plain byte count (1536 -> 1536) - what
#                     capabilities_size_label delegates to
#   bytes             the unscaled count with a B suffix (2048 -> 2048B),
#                     the raw bigfolder fallback without capabilities.sh
# Any other STYLE behaves like the default (iec).
format_size_bytes() {
  local bytes="${1:-}" style="${2:-}" units=(B KiB MiB GiB TiB)
  case "$bytes" in
    '' | *[!0-9]*) printf '%s' "$bytes" && return 0 ;;
  esac
  # Strip leading zeros so the arithmetic below is base 10: bash reads a
  # leading 0 as octal (01000 -> 512) and rejects 089 outright. A server
  # size with leading zeros is unusual but must not render as a wrong or
  # error value.
  while [[ "$bytes" == 0* && ${#bytes} -gt 1 ]]; do bytes="${bytes#0}"; done
  case "$style" in
    rclone)
      local value="$bytes" unit=""
      if [[ "$bytes" -ge 1073741824 && $((bytes % 1073741824)) -eq 0 ]]; then
        value=$((bytes / 1073741824))
        unit=Gi
      elif [[ "$bytes" -ge 1048576 && $((bytes % 1048576)) -eq 0 ]]; then
        value=$((bytes / 1048576))
        unit=Mi
      elif [[ "$bytes" -ge 1024 && $((bytes % 1024)) -eq 0 ]]; then
        value=$((bytes / 1024))
        unit=Ki
      fi
      printf '%s%s' "$value" "$unit"
      return 0
      ;;
    bytes)
      printf '%sB' "$bytes"
      return 0
      ;;
  esac
  local unit=0 value="$bytes" divisor=1 i whole=0 rem=0 tenths=0
  while ((value >= 1024 && unit < 4)); do
    value=$((value / 1024))
    unit=$((unit + 1))
  done
  if ((unit == 0)); then
    printf '%d%s' "$value" "${units[unit]}"
    return 0
  fi
  for ((i = 0; i < unit; i++)); do divisor=$((divisor * 1024)); done
  whole=$((bytes / divisor))
  rem=$((bytes % divisor))
  tenths=$(((rem * 10 + divisor / 2) / divisor))
  if ((tenths >= 10)); then
    whole=$((whole + 1))
    tenths=0
  fi
  if ((whole >= 10)); then
    printf '%d%s' "$whole" "${units[unit]}"
  else
    printf '%d.%d%s' "$whole" "$tenths" "${units[unit]}"
  fi
  return 0
}

# _stat_flavor - detect once whether stat is the BSD (-f) or GNU (-c) spelling.
# Avoids probing both forms on every file_mtime/file_mode/file_stamp call.
_SCIEBO_STAT_FLAVOR=""
_stat_flavor() {
  [[ -n "$_SCIEBO_STAT_FLAVOR" ]] && {
    printf '%s' "$_SCIEBO_STAT_FLAVOR"
    return 0
  }
  if stat -f %m "$LIB_DIR" >/dev/null 2>&1; then
    _SCIEBO_STAT_FLAVOR="bsd"
  else
    _SCIEBO_STAT_FLAVOR="gnu"
  fi
  printf '%s' "$_SCIEBO_STAT_FLAVOR"
}

# file_mtime FILE - print FILE's modification time as an epoch, or nothing
# when it cannot be read. Uses the one-time _stat_flavor detection.
file_mtime() {
  local file="$1" mtime=""
  [[ -n "$_SCIEBO_STAT_FLAVOR" ]] || _stat_flavor >/dev/null
  if [[ "$_SCIEBO_STAT_FLAVOR" == "bsd" ]]; then
    mtime="$(stat -f %m "$file" 2>/dev/null || true)"
  else
    mtime="$(stat -c %Y "$file" 2>/dev/null || true)"
  fi
  case "$mtime" in
    '' | *[!0-9]*) return 0 ;;
  esac
  printf '%s' "$mtime"
}

# file_mtime_or FILE DEFAULT - FILE's modification time as an epoch, or
# DEFAULT when the file is missing or unstatable (the stat fails or prints
# nothing usable). The mtime capture runs forklessly in this shell. Adopters
# pass their own default (0 for age comparisons, "" for stamps). Never
# fails; always prints.
file_mtime_or() {
  local mtime=""
  mtime=${ file_mtime "${1:-}";}
  if [[ -n "$mtime" ]]; then
    printf '%s' "$mtime"
  else
    printf '%s' "${2:-}"
  fi
  return 0
}

# file_size FILE - print FILE's size in bytes, or nothing when it cannot be
# read. Uses the one-time _stat_flavor detection (BSD -f %z / GNU -c %s), the
# stat-dance replacement for the wc-pipe and per-caller flavour probes.
file_size() {
  local file="$1" size=""
  [[ -n "$_SCIEBO_STAT_FLAVOR" ]] || _stat_flavor >/dev/null
  if [[ "$_SCIEBO_STAT_FLAVOR" == "bsd" ]]; then
    size="$(stat -f %z "$file" 2>/dev/null || true)"
  else
    size="$(stat -c %s "$file" 2>/dev/null || true)"
  fi
  case "$size" in
    '' | *[!0-9]*) return 0 ;;
  esac
  printf '%s' "$size"
}

# file_mode FILE - print FILE's permission bits as three octal digits (e.g.
# 600; a four-digit mode loses its leading bit), or nothing when it cannot be
# read. Uses the one-time _stat_flavor detection.
file_mode() {
  local file="$1" mode=""
  [[ -n "$_SCIEBO_STAT_FLAVOR" ]] || _stat_flavor >/dev/null
  if [[ "$_SCIEBO_STAT_FLAVOR" == "bsd" ]]; then
    mode="$(stat -f '%Lp' "$file" 2>/dev/null || true)"
  else
    mode="$(stat -c '%a' "$file" 2>/dev/null || true)"
  fi
  case "$mode" in
    [0-7][0-7][0-7]) printf '%s' "$mode" ;;
    [0-7][0-7][0-7][0-7]) printf '%s' "${mode#?}" ;;
    *) return 0 ;;
  esac
}

# _mode_normalize MODE - print MODE as three octal digits (a four-digit stat
# mode loses its leading bit), or nothing when MODE is not octal. The shared
# normalization for safe_source's multi-operand stat read.
_mode_normalize() {
  case "${1:-}" in
    [0-7][0-7][0-7]) printf '%s' "$1" ;;
    [0-7][0-7][0-7][0-7]) printf '%s' "${1#?}" ;;
    *) return 0 ;;
  esac
}

# strip_control_bytes TEXT - the pure-bash twin of the awk ctrl_strip(s, 0):
# remove C0/DEL control bytes, encoded C1 (the two-byte C2 80..C2 9F forms for
# U+0080..U+009F) and stray C1 bytes (0x80-0x9F), while preserving valid UTF-8
# multi-byte sequences. The same corrected UTF-8 rules apply:
#   - C0/C1 0xC0-0xC1 are invalid leads (overlong two-byte forms),
#   - a three-byte E0 requires the second byte A0..BF,
#   - ED requires the second byte 80..9F (no surrogates),
#   - a four-byte F0 requires the second byte 90..BF,
#   - F4 requires the second byte 80..8F,
#   - a malformed sequence is dropped with its continuation run, so ED A0 80
#     and F4 90 80 80 disappear whole.
# A lone 0xA0-0xBF or 0xF5-0xFF byte is not a control and stays, exactly as
# before (only the 0x80-0x9F range is a terminal control under Latin-1).
# Byte-wise and forkless via LC_ALL=C and single-byte substring expansion.
# Used by percent_decode so a decoded %0A/%0D cannot split a record and a
# decoded %9B cannot inject a terminal control, without corrupting multi-byte
# names such as "grüße".
strip_control_bytes() {
  local s="${1:-}" out="" i=0 n=0 b="" b2="" need=0 ok=0 j=0
  local LC_ALL=C
  n=${#s}
  while ((i < n)); do
    b="${s:i:1}"
    need=0
    case "$b" in
      [$'\302'-$'\337']) need=1 ;;
      [$'\340'-$'\357']) need=2 ;;
      [$'\360'-$'\364']) need=3 ;;
    esac
    if ((need > 0)); then
      ok=1
      for ((j = 1; j <= need; j++)); do
        if ((i + j >= n)) || [[ "${s:i+j:1}" != [$'\200'-$'\277'] ]]; then
          ok=0
          break
        fi
      done
      if ((ok)); then
        b2="${s:i+1:1}"
        case "$b" in
          $'\302') if [[ "$b2" == [$'\200'-$'\237'] ]]; then ok=0; fi ;;
          $'\340') if [[ "$b2" == [$'\200'-$'\237'] ]]; then ok=0; fi ;;
          $'\355') if [[ "$b2" == [$'\240'-$'\277'] ]]; then ok=0; fi ;;
          $'\360') if [[ "$b2" != [$'\220'-$'\277'] ]]; then ok=0; fi ;;
          $'\364') if [[ "$b2" != [$'\200'-$'\217'] ]]; then ok=0; fi ;;
        esac
      fi
      if ((ok)); then
        out+="${s:i:1+need}"
        i=$((i + 1 + need))
        continue
      fi
      # A malformed sequence is dropped with the continuation run that
      # follows it, so its bytes cannot survive as a stray C1 byte.
      i=$((i + 1))
      while ((i < n)); do
        [[ "${s:i:1}" == [$'\200'-$'\277'] ]] || break
        i=$((i + 1))
      done
      continue
    fi
    case "$b" in
      [$'\300'-$'\301']) # C0/C1: overlong lead, not a valid UTF-8 start
        i=$((i + 1))
        continue
        ;;
      [[:cntrl:]]) # C0 controls and DEL
        i=$((i + 1))
        continue
        ;;
      [$'\200'-$'\237']) # stray C1 control byte
        i=$((i + 1))
        continue
        ;;
    esac
    out+="$b"
    i=$((i + 1))
  done
  printf '%s' "$out"
  return 0
}

# percent_decode TEXT - decode %XX escapes byte-wise (LC_ALL=C plus one-byte
# substring expansion, so multi-byte UTF-8 survives as its raw bytes). Literal
# backslashes in TEXT are never re-interpreted (unlike printf '%b'). A "%" not
# followed by two hex digits stays literal, exactly like the awk this
# replaced, and newlines are dropped to match awk's line-based reader. C0/C1
# control bytes are dropped after decoding, so a %0A in a server href cannot
# split a policy record.
percent_decode() {
  local s="${1:-}" out="" i=0 c="" h1="" h2="" ch=""
  local LC_ALL=C
  s="${s//$'\n'/}"
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    if [[ "$c" == "%" && $((i + 2)) -lt ${#s} ]]; then
      h1="${s:i+1:1}"
      h2="${s:i+2:1}"
      case "$h1$h2" in
        [0-9a-fA-F][0-9a-fA-F])
          printf -v ch '%b' "\\x${h1}${h2}"
          out+="$ch"
          i=$((i + 2))
          continue
          ;;
      esac
    fi
    out+="$c"
  done
  strip_control_bytes "$out"
  return 0
}

# href_decode HREF - percent-decode HREF and strip control bytes, so a
# server-controlled URL segment is safe to display (DAV hrefs arrive
# URL-encoded).
href_decode() {
  printable "$(percent_decode "$1")"
}

# href_last_segment HREF - the percent-decoded, control-stripped last path
# segment of a listing href: the item id shared by trash and versions. Strip
# the trailing slashes, take the final segment, then decode, matching
# http.sh's awk xml_href_segment.
href_last_segment() {
  local segment="${1:-}"
  while [[ "$segment" == */ ]]; do segment="${segment%/}"; done
  segment="${segment##*/}"
  href_decode "$segment"
}

# _AWK_HTML_LIB - the shared awk HTML stripper, composed as
# `awk "${_AWK_HTML_LIB}"'<program>'` the same way core's _AWK_CTRL_LIB and
# http.sh's _AWK_XML_LIB compose (http.sh prepends this lib to
# _AWK_XML_LIB, so the XML parsers call xml_html_strip from one source).
# xml_html_strip(s) removes <...> markup, folds whitespace runs to single
# spaces, and trims the ends - the exact gsub/sub sequence the three inline
# copies (core's strip_html, activity's html_strip, search's
# search_strip_html) used to restate per parser.
_AWK_HTML_LIB='
function xml_html_strip(s,    text) {
  text = s
  gsub(/<[^>]*>/, "", text)
  gsub(/[[:space:]]+/, " ", text)
  sub(/^ /, "", text)
  sub(/ $/, "", text)
  return text
}
'

# strip_html TEXT - remove HTML markup and fold whitespace so a
# server-controlled string stays a single readable line. Multi-line TEXT is
# joined with single spaces first, then stripped by the shared
# xml_html_strip (_AWK_HTML_LIB); the gsub/sub rules are byte-identical to
# the inline END block this replaced. Callers that print the result to a
# terminal must still run it through printable.
strip_html() {
  printf '%s' "$1" | awk "${_AWK_HTML_LIB}"'
    { text = text $0 " " }
    END { print xml_html_strip(text) }
  '
}

# sanitize_name TEXT - map to [A-Za-z0-9._-] for use in log file names and
# bisync workdirs; collisions are reported by doctor and sync.
sanitize_name() {
  local result=""
  sanitize_name_into result "${1:-}"
  printf '%s' "$result"
}

# sanitize_name_into VAR VALUE - sanitize_name without the command
# substitution, for hot callers (manifest parsing). Byte-wise via LC_ALL=C
# so multi-byte characters map to one underscore, exactly like the tr form
# this replaced.
sanitize_name_into() {
  local s="${2:-}"
  local LC_ALL=C
  s="${s//[^A-Za-z0-9._-]/_}"
  s="${s#"${s%%[!._]*}"}"
  while [[ "$s" == *__* ]]; do
    s="${s//__/_}"
  done
  printf -v "$1" '%s' "${s%_}"
}

# expand_local_path PATH - absolute stays, ~ and ~/ expand, anything else
# is relative to the project root.
# shellcheck disable=SC2088  # ${p#\~/} is an intentional literal-prefix strip
expand_local_path() {
  case "$1" in
    "~") printf '%s' "$HOME" ;;
    "~/"*) printf '%s' "${HOME}/${1#\~/}" ;;
    /*) printf '%s' "$1" ;;
    *) printf '%s' "${PROJECT_DIR}/${1}" ;;
  esac
}

# expand_local_path_into VAR PATH - expand_local_path without the command
# substitution, for hot callers.
# shellcheck disable=SC2088  # ${2#\~/} is an intentional literal-prefix strip
expand_local_path_into() {
  case "$2" in
    "~") printf -v "$1" '%s' "$HOME" ;;
    "~/"*) printf -v "$1" '%s' "${HOME}/${2#\~/}" ;;
    /*) printf -v "$1" '%s' "$2" ;;
    *) printf -v "$1" '%s' "${PROJECT_DIR}/${2}" ;;
  esac
}

# safe_remote_path PATH - validate a path below the remote base. Rejects
# empty, absolute, ".." segments, whitespace padding, "|", and control
# bytes so manifest lines and remote args round-trip unambiguously.
safe_remote_path() {
  local s="$1"
  [[ -n "$s" ]] || return 1
  case "$s" in
    [[:space:]]* | *[[:space:]] | /* | *..* | *"|"*) return 1 ;;
  esac
  [[ "$s" != *[[:cntrl:]]* ]]
}

# safe_local_path PATH - validate a local path for the pipe-separated
# manifest: non-empty, no surrounding whitespace, no "|" (the field
# separator), no control bytes, and no "." or ".." path segments (so a
# manifest or `open` argument cannot escape its root).
safe_local_path() {
  local s="$1"
  [[ -n "$s" ]] || return 1
  case "$s" in
    [[:space:]]* | *[[:space:]] | *"|"*) return 1 ;;
    "." | ".." | "./"* | "../"* | *"/./"* | *"/../"* | *"/." | *"/..") return 1 ;;
  esac
  [[ "$s" != *[[:cntrl:]]* ]]
}

# require_safe_remote_path PATH [LABEL] - die with the shared message unless
# PATH passes safe_remote_path. Centralizes the wording used by every
# command that accepts a path below the remote base.
require_safe_remote_path() {
  safe_remote_path "${1:-}" && return 0
  local shown=""
  shown=${ printable "${1:-}";}
  die "${2:-}unsafe remote path '${shown}': use a relative path below the remote base without '..'"
}

# is_uint VALUE - true when VALUE is a non-empty run of ASCII digits.
is_uint() {
  case "${1:-}" in
    '' | *[!0-9]*) return 1 ;;
  esac
  return 0
}

# default_uint VALUE FALLBACK - print VALUE when it is a non-empty run of
# ASCII digits, else FALLBACK. The shared normalizer for settings-derived
# limits and thresholds (recent/search/file-activity limits, the
# blacklist/runstate counters), replacing the repeated
# `case '' | *[!0-9]*) v=fallback ;;` idiom. Pure printf, so callers capture
# it forklessly with ${ ...; }.
default_uint() {
  if is_uint "${1:-}"; then
    printf '%s' "$1"
  else
    printf '%s' "${2:-}"
  fi
  return 0
}

# comma_ids_valid IDS - true when IDS is one or more non-empty ASCII-digit
# ids separated by commas; false for an empty string, an empty field, or any
# non-digit byte. The shared validator for comma-separated numeric id lists.
comma_ids_valid() {
  local ids="${1:-}" id="" rest=""
  [[ -n "$ids" ]] || return 1
  rest="$ids"
  while :; do
    id="${rest%%,*}"
    is_uint "$id" || return 1
    [[ "$rest" == *,* ]] || break
    rest="${rest#*,}"
  done
  return 0
}

# file_stamp FILE - print "mtime size" for cache invalidation, or nothing
# when it cannot be read. Uses the one-time _stat_flavor detection.
file_stamp() {
  local file="$1" stamp=""
  [[ -n "$_SCIEBO_STAT_FLAVOR" ]] || _stat_flavor >/dev/null
  if [[ "$_SCIEBO_STAT_FLAVOR" == "bsd" ]]; then
    stamp="$(stat -f '%m %z' "$file" 2>/dev/null || true)"
  else
    stamp="$(stat -c '%Y %s' "$file" 2>/dev/null || true)"
  fi
  printf '%s' "$stamp"
}

# Paths already reported as unsafe by the safe_source helpers (warn once per
# path, whichever layer reaches the refusal first).
declare -A _SAFE_SOURCE_WARNED=()

# _safe_source_warn FILE MESSAGE - print MESSAGE once per FILE; a refusal that
# is reached from several layers warns a single time.
_safe_source_warn() {
  local file="$1" message="$2"
  [[ -z "${_SAFE_SOURCE_WARNED[$file]:-}" ]] || return 0
  _SAFE_SOURCE_WARNED[$file]=1
  warn "$message"
}

# _fd_looks_safe FD FD_UID FD_MODE FD_INO PATH_MODE PATH_INO - 0 when the
# descriptor FD still names a regular file owned by the current user with
# neither group- nor other-write bits, and FD and the path agree on the
# inode (the path-based mode must describe the file that was actually
# opened; on platforms where stat-ing /dev/fd/N reports the access mode
# instead of the file's mode, the inode match is what makes the path read
# meaningful). Modes must already be normalized by _mode_normalize; an
# empty uid, mode, or inode is refused. Extracted from safe_source so the
# compound refusal lives in one place with the same short-circuit order.
_fd_looks_safe() {
  local fd="$1" fd_uid="$2" fd_mode="$3" fd_ino="$4" path_mode="$5" path_ino="$6"
  if [[ ! -f "/dev/fd/${fd}" || -z "$fd_uid" || "$fd_uid" != "$UID" ||
    -z "$fd_ino" || "$fd_ino" != "$path_ino" || -z "$path_mode" ||
    $((8#$path_mode & 8#022)) -ne 0 || -z "$fd_mode" || $((8#$fd_mode & 8#022)) -ne 0 ]]; then
    return 1
  fi
  return 0
}

# safe_source FILE - source the already-verified file through its open
# descriptor so a swap between the check and the read cannot execute different
# content. It is self-contained: it rejects a symlinked path, opens FILE, and
# validates the descriptor itself - regular file, owned by the current user,
# and without a group or other write bit - before sourcing. On platforms where
# stat-ing /dev/fd/N reports the descriptor's access mode instead of the file's
# (macOS), the descriptor and the path must also name the same inode, so the
# path-based mode read describes the file that was actually opened
# (TOCTOU-safe). Warns once per path and returns 1 when FILE is unsafe;
# otherwise returns the exit status of the sourced file, so a syntax or
# runtime error in a settings, profile, or .env file is propagated instead of
# swallowed. Runs in the caller's shell, so assignments made by FILE persist.
safe_source() {
  local file="${1:-}" fd="" rc=0
  local out="" fd_uid="" fd_mode="" fd_ino="" path_mode="" path_ino=""
  [[ -n "$file" ]] || return 1
  [[ ! -L "$file" ]] || {
    _safe_source_warn "$file" "refusing to source symlinked file '$(printable "$file")'"
    return 1
  }
  # Refuse anything that is not a regular file before opening it: opening a
  # FIFO or a device would block (or have side effects) instead of failing.
  [[ -f "$file" ]] || return 1
  exec {fd}<"$file" || return 1
  # One stat invocation supplies uid, mode, and inode for both names (the open
  # descriptor and the path name), BSD '%u %Lp %i' or GNU '%u %a %i'.
  # stat prints one line per operand in argument order; an operand that cannot
  # be read contributes no line, so its fields stay empty and the check below
  # refuses exactly as before.
  [[ -n "$_SCIEBO_STAT_FLAVOR" ]] || _stat_flavor >/dev/null
  if [[ "$_SCIEBO_STAT_FLAVOR" == "bsd" ]]; then
    out="$(stat -f '%u %Lp %i' "/dev/fd/${fd}" "$file" 2>/dev/null || true)"
  else
    out="$(stat -c '%u %a %i' "/dev/fd/${fd}" "$file" 2>/dev/null || true)"
  fi
  read -r fd_uid fd_mode fd_ino <<<"${out%%$'\n'*}"
  if [[ "$out" == *$'\n'* ]]; then
    read -r _ path_mode path_ino <<<"${out#*$'\n'}"
  fi
  # Normalize a four-digit mode to three octal digits, and treat a non-octal
  # mode as unreadable.
  fd_mode="$(_mode_normalize "$fd_mode")"
  path_mode="$(_mode_normalize "$path_mode")"
  if ! _fd_looks_safe "$fd" "$fd_uid" "$fd_mode" "$fd_ino" "$path_mode" "$path_ino"; then
    exec {fd}<&-
    _safe_source_warn "$file" "refusing to source unsafe file '$(printable "$file")': it must be owned by you and not group- or other-writable"
    return 1
  fi
  # shellcheck disable=SC1090  # /dev/fd path; the descriptor was validated above
  source "/dev/fd/${fd}" || rc=$?
  exec {fd}<&-
  return "$rc"
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

# url_redact_userinfo URL - print URL with any credentials embedded in the
# authority masked as `***@`: `scheme://user:pass@host/path` becomes
# `scheme://***@host/path`. Host and path survive, so a proxy URL can be
# reported or archived safely.
url_redact_userinfo() {
  local url="${1:-}" scheme="" rest="" authority="" tail=""
  case "$url" in
    *://*)
      scheme="${url%%://*}://"
      rest="${url#*://}"
      ;;
    *) rest="$url" ;;
  esac
  authority="${rest%%/*}"
  tail="${rest#"$authority"}"
  case "$authority" in
    *@*) authority="***@${authority##*@}" ;;
  esac
  printf '%s' "${scheme}${authority}${tail}"
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

# nextcloud_dav_url URL USER - print URL normalized to USER's Nextcloud
# WebDAV files root: trailing slashes are stripped, a URL that already ends
# in /remote.php/dav/files/USER gains a trailing slash, and anything else
# gains the whole /remote.php/dav/files/USER/ path. rc 1 without output
# when URL points into /remote.php/ but not at USER's files root - the
# caller then dies with its command-specific hint, because setup ("... but
# setup needs the Nextcloud base URL ...") and provision ("... but
# --serverurl needs ...") word that failure differently and only they may
# print it. This is the shared half of setup_normalize_url/
# provision_normalize_url; ncc_parse_url (nextcloudcmd) parses a different
# shape and stays separate.
nextcloud_dav_url() {
  local url="$1" user="$2"
  url="$(strip_trailing_slashes "$url")"
  case "$url" in
    */remote.php/dav/files/"$user")
      printf '%s/' "$url"
      ;;
    *"/remote.php/"*)
      return 1
      ;;
    *)
      printf '%s/remote.php/dav/files/%s/' "$url" "$user"
      ;;
  esac
  return 0
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

# seen-id caches (notifications, activity): one server-side id per line.
# The in-process index turns per-record membership into one `case` match
# instead of a full file scan per record. Writers run in subshells (the
# `... | seen_record` pipeline), so the index is revalidated against the
# file stamp instead of relying on in-process invalidation. The raw stamp is
# itself cached for the current SECONDS tick (mirroring _log_stamp_refresh),
# so a burst of membership checks stats the file at most once per second; a
# write from another process is picked up on the next tick, while seen_record
# clears the cache so a same-shell append is seen immediately.
SEEN_CACHE_FILE=""
SEEN_CACHE_STAMP=""
SEEN_CACHE_INDEX=""
SEEN_STAMP_FILE=""
SEEN_STAMP_SECONDS=""
SEEN_STAMP_VALUE=""

# _seen_stamp_refresh FILE - set SEEN_STAMP_VALUE to FILE's "mtime size"
# stamp, reusing the value cached for the current SECONDS tick and file. The
# file is part of the cache key, so switching files re-stats even inside one
# tick. Runs in the caller's shell (a $() wrapper would lose the cache).
_seen_stamp_refresh() {
  local file="$1"
  if [[ "$SEEN_STAMP_SECONDS" == "$SECONDS" && "$SEEN_STAMP_FILE" == "$file" ]]; then
    return 0
  fi
  SEEN_STAMP_SECONDS="$SECONDS"
  SEEN_STAMP_FILE="$file"
  SEEN_STAMP_VALUE="$(file_stamp "$file")"
  return 0
}

# seen_contains FILE ID - true when ID is one line of FILE. A missing file
# is not an error.
seen_contains() {
  local file="$1" id="${2:-}" stamp=""
  [[ -n "$id" && -f "$file" ]] || return 1
  _seen_stamp_refresh "$file"
  stamp="$SEEN_STAMP_VALUE"
  if [[ "$SEEN_CACHE_FILE" != "$file" || "$SEEN_CACHE_STAMP" != "$stamp" ]]; then
    SEEN_CACHE_FILE="$file"
    SEEN_CACHE_STAMP="$stamp"
    SEEN_CACHE_INDEX=$'\n'"$(<"$file")"$'\n'
  fi
  case "$SEEN_CACHE_INDEX" in
    *$'\n'"$id"$'\n'*) return 0 ;;
  esac
  return 1
}

# seen_record FILE - append the ids on stdin (one per line) to FILE,
# atomically and mode 600. Best effort: a state write problem must never
# fail the caller, so atomic_write's die is contained in the subshell.
seen_record() {
  local file="$1"
  (
    {
      [[ ! -f "$file" ]] || cat "$file"
      cat
    } | atomic_write "$file" 600
  ) 2>/dev/null || true
  SEEN_CACHE_FILE=""
  SEEN_CACHE_STAMP=""
  SEEN_CACHE_INDEX=""
  # Drop the per-tick stamp memo so the just-appended id is visible to the
  # next seen_contains even when the write lands in the same SECONDS tick.
  SEEN_STAMP_FILE=""
  SEEN_STAMP_SECONDS=""
  SEEN_STAMP_VALUE=""
}

# split_positionals ARGS - fill the POSITIONAL_ARGS array from a
# newline-separated OPT_EXTRA value (one element per positional). Callers
# check ${#POSITIONAL_ARGS[@]} -gt 0 before indexing.
split_positionals() {
  POSITIONAL_ARGS=()
  local rest="${1:-}"
  rest="${rest%$'\n'}"
  [[ -n "$rest" ]] || return 0
  while :; do
    POSITIONAL_ARGS[${#POSITIONAL_ARGS[@]}]="${rest%%$'\n'*}"
    [[ "$rest" == *$'\n'* ]] || break
    rest="${rest#*$'\n'}"
  done
  return 0
}

# split_positionals_into NAME... - split OPT_EXTRA (like split_positionals,
# leaving the words in POSITIONAL_ARGS for the caller's own count check) and
# assign the leading words to the named variables, empty when absent. Collapses
# the `split_positionals; p1=${POSITIONAL_ARGS[0]:-}; ...` preamble the
# subcommand parsers repeat. NAME may be a local or a global.
split_positionals_into() {
  split_positionals "${OPT_EXTRA:-}"
  local i=0 name=""
  for name in "$@"; do
    printf -v "$name" '%s' "${POSITIONAL_ARGS[$i]:-}"
    i=$((i + 1))
  done
  return 0
}

# split_command_args ARGS SUB_VAR ARG1_VAR ARG2_VAR ARGC_VAR - fill the named
# globals from the newline-separated positional arguments: SUB_VAR gets the
# first positional, ARG1_VAR the second, ARG2_VAR the third, and ARGC_VAR their
# total. Missing trailing names stay empty. Shared by the `share` and `file`
# subcommand parsers; callers own their differently named globals.
split_command_args() {
  local args="$1" sub_var="$2" arg1_var="$3" arg2_var="$4" argc_var="$5"
  local n=0
  split_positionals "$args"
  n="${#POSITIONAL_ARGS[@]}"
  printf -v "$sub_var" '%s' ""
  printf -v "$arg1_var" '%s' ""
  printf -v "$arg2_var" '%s' ""
  printf -v "$argc_var" '%s' "$n"
  [[ "$n" -gt 0 ]] || return 0
  printf -v "$sub_var" '%s' "${POSITIONAL_ARGS[0]}"
  [[ "$n" -gt 1 ]] || return 0
  printf -v "$arg1_var" '%s' "${POSITIONAL_ARGS[1]}"
  [[ "$n" -gt 2 ]] || return 0
  printf -v "$arg2_var" '%s' "${POSITIONAL_ARGS[2]}"
  return 0
}

# record_split LINE NAME... - assign the TAB-separated fields of LINE to the
# named variables. Every NAME consumes one field; "-" skips a field and the
# last NAME receives the remainder. Splitting is explicit because TAB is IFS
# whitespace, so `read` would collapse empty fields. Prints nothing and
# returns 0 even for an empty record, so parsers can call it per record.
record_split() {
  local rest="$1"
  shift
  local names=("$@") i=0 last=$(($# - 1)) name=""
  [[ "$last" -ge 0 ]] || return 0
  while [[ "$i" -lt "$last" ]]; do
    name="${names[$i]}"
    if [[ "$name" == "-" ]]; then
      rest="${rest#*$'\t'}"
    else
      printf -v "$name" '%s' "${rest%%$'\t'*}"
      rest="${rest#*$'\t'}"
    fi
    i=$((i + 1))
  done
  name="${names[$last]}"
  [[ "$name" == "-" ]] || printf -v "$name" '%s' "$rest"
  return 0
}

# numeric_id VALUE - true when VALUE is one non-empty run of ASCII digits.
# Server-side ids (share/comment/notification ids) are interpolated into
# request paths and XML bodies, so anything else must be rejected first.
numeric_id() { is_uint "${1:-}"; }

# safe_filter_name NAME - validate a bare filter file name (no directory
# components, no ".."), so manifests cannot point outside FILTER_DIR.
safe_filter_name() {
  local s="$1"
  [[ -n "$s" ]] || return 1
  case "$s" in
    /* | */* | *..*) return 1 ;;
  esac
  [[ "$s" != *[[:cntrl:]]* ]]
}

# strip_trailing_slashes PATH - remove trailing slashes, keeping "/" intact.
strip_trailing_slashes() {
  local s="$1"
  while [[ "$s" == */ && "$s" != "/" ]]; do s="${s%/}"; done
  printf '%s' "$s"
}

# size_suffix_bytes SIZE - parse an rclone-style size suffix (1, 500M, 5G,
# 1Gi, 100KB) into bytes. Binary units for K/M/G/T/P/E (1024-based), decimal
# for the explicit KB/MB/GB/TB forms. Prints nothing and returns 1 when the
# value is not parseable.
size_suffix_bytes() {
  local value="$1" number="" unit="" multiplier=""
  value="${value//[[:space:]]/}"
  number="${value%%[!0-9.]*}"
  unit="${value#"$number"}"
  [[ -n "$number" && "$number" != *.*.* ]] || return 1
  case "$unit" in
    '') multiplier=1 ;;
    B | b) multiplier=1 ;;
    K | k | Ki | ki | KI) multiplier=1024 ;;
    M | m | Mi | mi | MI) multiplier=1048576 ;;
    G | g | Gi | gi | GI) multiplier=1073741824 ;;
    T | t | Ti | ti | TI) multiplier=1099511627776 ;;
    P | p | Pi | pi | PI) multiplier=1125899906842624 ;;
    E | e | Ei | ei | EI) multiplier=1152921504606846976 ;;
    KB | kb | kB | Kb) multiplier=1000 ;;
    MB | mb | mB | Mb) multiplier=1000000 ;;
    GB | gb | gB | Gb) multiplier=1000000000 ;;
    TB | tb | tB | Tb) multiplier=1000000000000 ;;
    *) return 1 ;;
  esac
  # Parse the supported shape ^[0-9]+([.][0-9]+)?$ in pure bash (no awk fork
  # on the per-entry guard and chunk paths): integer part times multiplier
  # plus the fractional part scaled to whole bytes. The fraction is rounded
  # half-to-even to match awk's "%.0f" for values a double represents
  # exactly; beyond 2^53 the double-precision awk result can differ by one
  # byte. Bash arithmetic is 64-bit signed, so a result at or above 2^63
  # wraps instead of printing awk's (already inexact) double. Invalid shapes
  # (leading/trailing dot, two dots) return 1 exactly like awk.
  case "$number" in
    .* | *.) return 1 ;;
  esac
  local int_part="$number" frac="" scale=1 i=0 whole=0 frac_num=0
  local mult_q=0 mult_r=0 remainder=0 half=0
  if [[ "$number" == *.* ]]; then
    int_part="${number%%.*}"
    frac="${number#*.}"
  fi
  [[ -n "$int_part" && "$int_part" != *[!0-9]* ]] || return 1
  [[ -z "$frac" || "$frac" != *[!0-9]* ]] || return 1
  whole=$((10#$int_part * multiplier))
  if [[ -n "$frac" ]]; then
    for ((i = 0; i < ${#frac}; i++)); do scale=$((scale * 10)); done
    # Split the multiplier by scale so frac*multiplier cannot overflow before
    # the division: frac*(q*scale + r) = frac*q*scale + frac*r.
    mult_q=$((multiplier / scale))
    mult_r=$((multiplier % scale))
    frac_num=$((10#$frac))
    whole=$((whole + frac_num * mult_q + frac_num * mult_r / scale))
    remainder=$((frac_num * mult_r % scale))
    half=$((scale / 2))
    if ((remainder > half)) ||
      ((scale % 2 == 0 && remainder == half && whole % 2 == 1)); then
      whole=$((whole + 1))
    fi
  fi
  printf '%d' "$whole"
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

# atomic_write FILE [MODE] - replace FILE with stdin, same directory,
# atomic rename. Default mode 644.
atomic_write() {
  local file="$1" mode="${2:-644}" dir tmp=""
  # The directory comes from parameter expansion (no `dirname` fork): a path
  # without a slash writes into the current directory, an empty expansion
  # means the root directory. mkdir only runs when the directory is missing;
  # the temp template below stays `${file}.tmp.XXXXXX` because cleanup
  # --state's narrowed `*.tmp.??????` glob matches exactly six characters.
  dir="${file%/*}"
  if [[ "$dir" == "$file" ]]; then
    dir="."
  elif [[ -z "$dir" ]]; then
    dir="/"
  fi
  [[ -d "$dir" ]] || mkdir -p -- "$dir"
  temp_mktemp_into tmp "${file}.tmp.XXXXXX" || die "cannot create temp file in ${dir}"
  if ! cat >"$tmp"; then
    temp_discard "$tmp"
    die "cannot write temp file for ${file}"
  fi
  chmod "$mode" "$tmp" || {
    temp_discard "$tmp"
    die "cannot chmod ${tmp} to ${mode}"
  }
  mv -f "$tmp" "$file" || {
    temp_discard "$tmp"
    die "cannot replace ${file}"
  }
  temp_discard "$tmp"
}
