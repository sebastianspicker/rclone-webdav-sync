#!/bin/bash
# core.sh - shell setup, paths, logging, die/usage_error, and module loading.
# Sources lib/text.sh, lib/opts.sh, lib/secrets.sh, and lib/fsutil.sh (the
# option parser and pure helpers this file used to define inline), so
# `source lib/core.sh` still provides every function it has always provided;
# see the "Module loading" section below for the split and the load order.
#
# Sourced once by bin/sciebo (and by tests); requires Bash 5.3.
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
# Module loading
#
# core.sh used to define every pure helper and parser inline; they now live in
# their own files (split by responsibility, not by call graph), sourced here
# so `source lib/core.sh` keeps providing every function it always has - no
# caller (bin/sciebo, a command module, or a test) needs to change. Order
# matters only in that a file must not call another's function at *source*
# time (defining a function or a plain variable never does); library authors
# adding a fifth file should keep that invariant instead of relying on this
# order:
#   text.sh     pure string/text helpers (no dependencies among these four)
#   opts.sh     the long-option parser (uses text.sh's split_positionals)
#   secrets.sh  netrc/curl-config/proxy helpers, the temp-file registry
#               (uses text.sh's printable)
#   fsutil.sh   stat/path/atomic-write helpers, safe_source, the seen-id
#               cache (uses text.sh's printable and secrets.sh's
#               temp_mktemp_into)
# shellcheck source=lib/text.sh
source "${LIB_DIR}/text.sh"
# shellcheck source=lib/opts.sh
source "${LIB_DIR}/opts.sh"
# shellcheck source=lib/secrets.sh
source "${LIB_DIR}/secrets.sh"
# shellcheck source=lib/fsutil.sh
source "${LIB_DIR}/fsutil.sh"
