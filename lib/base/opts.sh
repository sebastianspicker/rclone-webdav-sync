#!/bin/bash
# opts.sh - the long-option parser: SPEC-driven opt_parse/opt_begin and the
# opt_* helpers command modules call after them (help guard, rejection,
# uint validation, positional-count enforcement).
#
# Sourced by lib/base/core.sh. Depends on core.sh's die/usage_error/printable and
# text.sh's split_positionals (already sourced by the time this file runs).

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
