#!/bin/bash
# core.sh - shell setup, paths, output, option parsing, pure helpers.
#
# Sourced once by bin/sciebo (and by tests); must stay compatible with
# bash 3.2 (macOS /bin/bash), which is the interpreter launchd uses.
#
# Module conventions:
#   - Command functions return a status; only die/usage_error exit.
#   - Commands never call each other in-process; they exec bin/sciebo.
#   - Module-private globals are prefixed per module (ENTRY_*, MNT_*,
#     P_*, T_*, CHOOSE_*, OPT_*); other temporaries stay local.

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${LIB_DIR}/.." && pwd)"
CONFIG_DIR="${PROJECT_DIR}/config"
CLI_NAME="sciebo"

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
err() {
  printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

# die MESSAGE - operational failure; exits 1.
die() {
  err "$*"
  exit 1
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

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Long-option parsing
#
# SPEC entries are space-separated NAME:KIND pairs:
#   s  single value       -> OPT_<name>
#   S  repeatable value   -> OPT_<name>, newline-separated
#   b  boolean flag       -> OPT_<name>=1
# Names use dashes on the command line and underscores in the globals.
#
# opt_parse SPEC COMMAND LABEL "$@"
#   Sets OPT_HELP=1 for -h/--help (callers print their usage), collects
#   positional arguments in OPT_EXTRA (newline-separated), marks provided
#   options with OPT_<name>_SET=1, and routes errors through
#   usage_error COMMAND "LABEL...".
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

opt_parse() {
  local spec="$1" command="$2" label="$3"
  shift 3
  local token name value kind entry key keyvar current
  OPT_HELP=0
  OPT_EXTRA=""
  while [[ $# -gt 0 ]]; do
    token="$1"
    shift
    case "$token" in
      -h | --help)
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
    kind=""
    for entry in $spec; do
      case "$entry" in
        "${name}:"*)
          kind="${entry#*:}"
          break
          ;;
      esac
    done
    [[ -n "$kind" ]] || usage_error "$command" "${label}unknown option: --${name}"
    key="${name//-/_}"
    keyvar="OPT_${key}"
    if [[ "$kind" == "b" ]]; then
      [[ -z "$value" ]] || usage_error "$command" "${label}--${name} does not take a value"
      printf -v "$keyvar" '1'
    else
      if [[ -z "$value" ]]; then
        [[ $# -gt 0 && -n "${1:-}" ]] || usage_error "$command" "${label}--${name} requires a value"
        value="$1"
        shift
      fi
      if [[ "$kind" == "S" ]]; then
        current="${!keyvar:-}"
        printf -v "$keyvar" '%s%s\n' "$current" "$value"
      else
        printf -v "$keyvar" '%s' "$value"
      fi
    fi
    printf -v "OPT_${key}_SET" '1'
  done
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

# printable NAME - strip control bytes before showing server-controlled
# names (remote folders) so they cannot emit terminal escape sequences.
# Display only; never use this for values passed back to rclone.
printable() {
  local s="$1"
  s="${s//[[:cntrl:]]/}"
  printf '%s' "$s"
}

# sanitize_name TEXT - map to [A-Za-z0-9._-] for use in log file names and
# bisync workdirs; collisions are reported by doctor and sync.
sanitize_name() {
  local s
  s="$(printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')"
  s="${s#"${s%%[!._]*}"}"
  while [[ "$s" == *__* ]]; do
    s="${s//__/_}"
  done
  printf '%s' "${s%_}"
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

# safe_remote_path PATH - validate a path below the remote base. Rejects
# empty, absolute, ".." segments, whitespace padding, "|", and control
# bytes so manifest lines and remote args round-trip unambiguously.
safe_remote_path() {
  local s="$1"
  [[ -n "$s" && "$s" == "$(trim "$s")" ]] || return 1
  case "$s" in
    /* | *..* | *"|"*) return 1 ;;
  esac
  [[ "$s" != *[[:cntrl:]]* ]]
}

# atomic_write FILE [MODE] - replace FILE with stdin, same directory,
# atomic rename. Default mode 644.
atomic_write() {
  local file="$1" mode="${2:-644}" dir tmp
  dir="$(dirname "$file")"
  mkdir -p "$dir"
  tmp="$(mktemp "${file}.tmp.XXXXXX")" || die "cannot create temp file in ${dir}"
  cat >"$tmp"
  chmod "$mode" "$tmp"
  mv -f "$tmp" "$file"
}
