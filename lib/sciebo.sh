#!/bin/bash
# sciebo.sh - the single library loader: resolves LIB_DIR/PROJECT_DIR, sources
# every ranked lib/*/*.sh file eagerly (in an order where no file calls
# another's function at *source* time), and exposes the command-module lookup
# bin/sciebo's sciebo_main (lib/cli/main.sh) and the command modules
# themselves use to source lib/commands/*.sh.
#
# Sourced once by bin/sciebo and by every test suite; requires Bash 5.3.
# lib/commands/*.sh stay lazy: sciebo_main sources only the dispatched
# module, at global scope. Every command module's own dependencies live in
# lib/ (ranks 1-6 above), so no command module ever calls into another.

# Load-once guard: a test that sources this file directly, plus bin/sciebo,
# plus a command module that is sourced standalone, must not re-run the
# resolution and re-source every library.
[[ -z "${_SCIEBO_SH_LOADED:-}" ]] || return 0
_SCIEBO_SH_LOADED=1

# Resolve this file's own directory (LIB_DIR) and the project root
# (PROJECT_DIR), the same logic lib/base/core.sh used to run on itself: a
# BASH_SOURCE without a "/" is prefixed with "./" so ${...%/*} yields ".".
# LIB_DIR keeps one cd/pwd subshell (plain pwd, matching SCRIPT_DIR in
# bin/sciebo) so a checkout reached through symlinks resolves exactly as
# before; PROJECT_DIR is a "/lib" suffix strip instead of a second cd/pwd
# subshell, falling back to cd/pwd when the lib directory is not named "lib".
_sciebo_lib_src="${BASH_SOURCE[0]}"
case "$_sciebo_lib_src" in
  */*) ;;
  *) _sciebo_lib_src="./$_sciebo_lib_src" ;;
esac
LIB_DIR="$(cd "${_sciebo_lib_src%/*}" && pwd)"
unset _sciebo_lib_src
# shellcheck disable=SC2034  # PROJECT_DIR is read by core.sh and every command module
case "$LIB_DIR" in
  */lib) PROJECT_DIR="${LIB_DIR%/lib}" ;;
  *) PROJECT_DIR="$(cd "${LIB_DIR}/.." && pwd)" ;;
esac

# ---------------------------------------------------------------------------
# Library loading
#
# Every lib/<layer>/*.sh, sourced once, in an explicit order (no globs, so a
# new file must be added here deliberately), grouped by layer (rank order; a
# file may call functions from its own layer or a lower one - see
# docs/architecture.md#layers and scripts/check-layers.sh). Order matters
# only in that a file must not call another's function at *source* time
# (defining a function or a plain variable never does; text.sh's
# _AWK_CTRL_LIB/_AWK_HTML_LIB, read by xml.sh's own top-level _AWK_XML_LIB
# assignment, is the one real same-process dependency, which is why text.sh
# precedes xml.sh below):

# base: process plumbing and pure helpers - no knowledge of settings, rclone,
# or the network.
# shellcheck source=lib/base/core.sh
source "${LIB_DIR}/base/core.sh"
# shellcheck source=lib/base/text.sh
source "${LIB_DIR}/base/text.sh"
# shellcheck source=lib/base/xml.sh
source "${LIB_DIR}/base/xml.sh"
# shellcheck source=lib/base/opts.sh
source "${LIB_DIR}/base/opts.sh"
# shellcheck source=lib/base/secrets.sh
source "${LIB_DIR}/base/secrets.sh"
# shellcheck source=lib/base/fsutil.sh
source "${LIB_DIR}/base/fsutil.sh"
# shellcheck source=lib/base/output.sh
source "${LIB_DIR}/base/output.sh"
# shellcheck source=lib/base/duration.sh
source "${LIB_DIR}/base/duration.sh"
# shellcheck source=lib/base/ui.sh
source "${LIB_DIR}/base/ui.sh"

# adapters: talk to external programs/services; read settings *globals*,
# never call config functions.
# shellcheck source=lib/adapters/proxy.sh
source "${LIB_DIR}/adapters/proxy.sh"
# shellcheck source=lib/adapters/rclone.sh
source "${LIB_DIR}/adapters/rclone.sh"
# shellcheck source=lib/adapters/http.sh
source "${LIB_DIR}/adapters/http.sh"
# shellcheck source=lib/adapters/nc_api.sh
source "${LIB_DIR}/adapters/nc_api.sh"
# shellcheck source=lib/adapters/capabilities.sh
source "${LIB_DIR}/adapters/capabilities.sh"
# shellcheck source=lib/adapters/keychain.sh
source "${LIB_DIR}/adapters/keychain.sh"
# shellcheck source=lib/adapters/platform.sh
source "${LIB_DIR}/adapters/platform.sh"
# shellcheck source=lib/adapters/notify.sh
source "${LIB_DIR}/adapters/notify.sh"

# config: user-authored configuration - settings layers, profiles, path
# derivation, the manifest/pair model.
# shellcheck source=lib/config/settings.sh
source "${LIB_DIR}/config/settings.sh"
# shellcheck source=lib/config/manifest.sh
source "${LIB_DIR}/config/manifest.sh"

# state: tool-written persistent state under STATE_DIR.
# shellcheck source=lib/state/layout.sh
source "${LIB_DIR}/state/layout.sh"
# shellcheck source=lib/state/runstate.sh
source "${LIB_DIR}/state/runstate.sh"
# shellcheck source=lib/state/blacklist.sh
source "${LIB_DIR}/state/blacklist.sh"
# shellcheck source=lib/state/pause.sh
source "${LIB_DIR}/state/pause.sh"
# shellcheck source=lib/state/bw.sh
source "${LIB_DIR}/state/bw.sh"
# shellcheck source=lib/state/lock.sh
source "${LIB_DIR}/state/lock.sh"
# shellcheck source=lib/state/pairflags.sh
source "${LIB_DIR}/state/pairflags.sh"
# shellcheck source=lib/state/seen.sh
source "${LIB_DIR}/state/seen.sh"

# sync: domain rules shared by several commands.
# shellcheck source=lib/sync/policy.sh
source "${LIB_DIR}/sync/policy.sh"
# shellcheck source=lib/sync/case_clash.sh
source "${LIB_DIR}/sync/case_clash.sh"
# shellcheck source=lib/sync/remote_paths.sh
source "${LIB_DIR}/sync/remote_paths.sh"
# shellcheck source=lib/sync/bigfolder.sh
source "${LIB_DIR}/sync/bigfolder.sh"
# shellcheck source=lib/sync/filters.sh
source "${LIB_DIR}/sync/filters.sh"
# shellcheck source=lib/sync/quota.sh
source "${LIB_DIR}/sync/quota.sh"
# shellcheck source=lib/sync/hydrate.sh
source "${LIB_DIR}/sync/hydrate.sh"

# cli: process entry - the generated command registry, global options,
# dispatch, help, traps.
# shellcheck source=lib/cli/registry.sh
source "${LIB_DIR}/cli/registry.sh"
# shellcheck source=lib/cli/main.sh
source "${LIB_DIR}/cli/main.sh"
# shellcheck source=lib/cli/version.sh
source "${LIB_DIR}/cli/version.sh"

# ---------------------------------------------------------------------------
# Command-module lookup
#
# lib/commands/*.sh stay lazy: dispatch resolves the wanted command to one
# file and sources it at global scope. SCIEBO_COMMAND_MODULE (from the
# generated lib/cli/registry.sh, sourced above) maps every SCIEBO_COMMANDS
# entry to its lib/commands/ file, without the .sh suffix.
# ---------------------------------------------------------------------------

# sciebo_command_module NAME - print the absolute lib/commands/ file that
# defines cmd_NAME/usage_NAME, from the generated SCIEBO_COMMAND_MODULE map
# (default lib/commands/<name>.sh for a name the map does not mention). A
# mapped file that is missing is an internal error (die) - SCIEBO_COMMANDS
# already gates real dispatch, so a stale table here is a bug, not a runtime
# condition to degrade from.
sciebo_command_module() {
  local command="$1" mod=""
  mod="${LIB_DIR}/commands/${SCIEBO_COMMAND_MODULE[$command]:-$command}.sh"
  [[ -r "$mod" ]] || die "internal error: no module defines command '${command}'"
  printf '%s' "$mod"
}
