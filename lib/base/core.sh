#!/bin/bash
# core.sh - shell setup, paths, and logging/die/usage_error helpers.
#
# Sourced once by lib/sciebo.sh, first among lib/*.sh, so LIB_DIR and
# PROJECT_DIR (resolved by lib/sciebo.sh from its own location before this
# file loads) are already set.
#
# Sourced once by bin/sciebo (via lib/sciebo.sh) and by tests; requires
# Bash 5.3.
#
# Module conventions:
#   - Command functions return a status; only die/usage_error exit.
#   - Commands never call each other in-process; they exec bin/sciebo.
#   - Module-private globals are prefixed per module (ENTRY_*, MNT_*,
#     P_*, T_*, CHOOSE_*, OPT_*); other temporaries stay local. In lib/*.sh,
#     state private to one module is prefixed "_<module>_" (module = the
#     file's basename without .sh, e.g. "_http_", "_manifest_"); state shared
#     across modules is documented in docs/architecture.md's "Shared
#     globals" table instead of hidden behind a misleading module prefix.

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
# that sources lib/sciebo.sh directly (tests, tooling) must not create
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
