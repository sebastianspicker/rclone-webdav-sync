#!/usr/bin/env bash
# config.sh - the config command: list/get/check/edit, sources, and
# credential redaction.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

# --- list and get ----------------------------------------------------------

expect_cli "config list rc 0" 0 run_cli config list
expect_contains "config list: remote key" "$CLI_OUT" "RCLONE_REMOTE="
expect_contains "config list: transfers key" "$CLI_OUT" "TRANSFERS="
expect_contains "config list: exported setting wins" \
  "$CLI_OUT" "RCLONE_REMOTE=testremote"$'\t'"environment"
expect_contains "config list: unexported setting is the default" \
  "$CLI_OUT" "CHECKERS=4"$'\t'"default"

expect_cli "config get known key rc 0" 0 run_cli config get RCLONE_REMOTE
expect_eq "config get prints the effective value" "testremote" "$CLI_OUT"
expect_cli "config get unknown key rc 1" 1 run_cli config get NOPE_NOT_A_SETTING
expect_contains "config get unknown key message" "$CLI_OUT" "unknown setting"

# --- --all and JSON --------------------------------------------------------

expect_cli "config list rc 0 (empty-value check)" 0 run_cli config list
expect_not_contains "config list hides empty values" "$CLI_OUT" "BW_LIMIT_UP="
expect_cli "config list --all rc 0" 0 run_cli config list --all
expect_contains "config list --all shows empty values" "$CLI_OUT" "BW_LIMIT_UP="

expect_cli "config list --json rc 0" 0 run_cli config list --json
expect_contains "config list --json: settings array" "$CLI_OUT" '"settings"'
expect_contains "config list --json: key field" "$CLI_OUT" '"key": "RCLONE_REMOTE"'
expect_contains "config list --json: value field" "$CLI_OUT" '"value": "testremote"'
expect_contains "config list --json: source field" "$CLI_OUT" '"source": "environment"'

expect_cli "config get --json rc 0" 0 run_cli config get RCLONE_REMOTE --json
expect_contains "config get --json: value field" "$CLI_OUT" '"value": "testremote"'
expect_contains "config get --json: source field" "$CLI_OUT" '"source": "environment"'

# --- redaction -------------------------------------------------------------

export SCIEBO_APP_PASSWORD=leak
expect_cli "config list with an unrelated exported secret rc 0" 0 run_cli config list
expect_not_contains "config list never prints non-setting secrets" "$CLI_OUT" "leak"
unset SCIEBO_APP_PASSWORD || true

REDACT_LOCAL="${TMP}/redact-local.env"
cat >"$REDACT_LOCAL" <<'EOF'
PROXY=http://user:pass@proxy
TRANSFERS=7
EOF
capture env SETTINGS_LOCAL_FILE="$REDACT_LOCAL" bash "${PROJ}/bin/sciebo" config list
expect_rc "config list with a local override rc 0" "$CLI_RC" 0
expect_contains "config list redacts credential-looking keys" "$CLI_OUT" "PROXY=REDACTED"
expect_not_contains "config list hides the proxy credentials" "$CLI_OUT" "user:pass"
expect_contains "config list local override source" \
  "$CLI_OUT" "TRANSFERS=7"$'\t'"local"

capture env SETTINGS_LOCAL_FILE="$REDACT_LOCAL" bash "${PROJ}/bin/sciebo" config get PROXY
expect_rc "config get secret key rc 0" "$CLI_RC" 0
expect_eq "config get redacts secret values" "REDACTED" "$CLI_OUT"
capture env SETTINGS_LOCAL_FILE="$REDACT_LOCAL" bash "${PROJ}/bin/sciebo" config get TRANSFERS
expect_eq "config get local override wins" "7" "$CLI_OUT"

# --- check -----------------------------------------------------------------

expect_cli "config check rc 0" 0 run_cli config check
expect_contains "config check: PASS lines" "$CLI_OUT" "PASS"
expect_contains "config check: state dir is writable" "$CLI_OUT" "state dir is writable"
expect_contains "config check: missing manifest is a warning" "$CLI_OUT" "WARN"

expect_cli "config check --json rc 0" 0 run_cli config check --json
expect_contains "config check --json: ok true" "$CLI_OUT" '"ok": true'
expect_contains "config check --json: checks array" "$CLI_OUT" '"checks"'
expect_contains "config check --json: state dir check" "$CLI_OUT" '"name": "state-dir"'

mv "${FILTER_DIR}/clutter.txt" "${FILTER_DIR}/clutter.txt.bak"
expect_cli "config check without the clutter filter rc 1" 1 run_cli config check
expect_contains "config check reports FAIL" "$CLI_OUT" "FAIL"
expect_cli "config check --json without the clutter filter rc 1" 1 run_cli config check --json
expect_contains "config check --json: ok false" "$CLI_OUT" '"ok": false'
mv "${FILTER_DIR}/clutter.txt.bak" "${FILTER_DIR}/clutter.txt"

# --- edit ------------------------------------------------------------------

LOCAL_FILE="${TMP}/edit-local.env"
CLI_OUT="$(cd "$TMP" && EDITOR=true SETTINGS_LOCAL_FILE="$LOCAL_FILE" \
  bash "${PROJ}/bin/sciebo" config edit </dev/null 2>&1)"
CLI_RC=$?
expect_rc "config edit rc 0" "$CLI_RC" 0
expect_file "config edit creates the local file" "$LOCAL_FILE"
expect_contains "config edit copies the example" \
  "$(cat "$LOCAL_FILE" 2>/dev/null || true)" "Your personal overrides"
expect_contains "config edit prints the path without a TTY" "$CLI_OUT" "$LOCAL_FILE"

# --- key-set cache ---------------------------------------------------------
# The config helpers cache each settings file's key set per (path, stamp).
# Extraction and membership must match the shipped semantics exactly, and a
# stamp change must invalidate the cache. Sourcing the module gives the test
# the pure helpers directly (the CLI paths above exercise them end to end).

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/commands/config.sh
source "${PROJ}/lib/commands/config.sh"

# config_env_exported without the SCIEBO_EXPORTED snapshot reads the live
# export attribute: exported-with-value counts, a plain or valueless export
# does not. (No subshell: harness counters must see these results.)
cfg_saved_exported="${SCIEBO_EXPORTED-__unset__}"
unset SCIEBO_EXPORTED
export CFG_EXPORTED_VALUE=1
# shellcheck disable=SC2034  # read indirectly by config_env_exported
CFG_PLAIN_VALUE=1
declare -x CFG_EXPORTED_NOVALUE
config_env_exported CFG_EXPORTED_VALUE
expect_rc "config_env_exported: exported value" "$?" 0
config_env_exported CFG_PLAIN_VALUE
expect_rc "config_env_exported: unexported value" "$?" 1
config_env_exported CFG_EXPORTED_NOVALUE
expect_rc "config_env_exported: exported without value" "$?" 1
config_env_exported CFG_NEVER_SET
expect_rc "config_env_exported: unset" "$?" 1
unset CFG_EXPORTED_VALUE CFG_PLAIN_VALUE CFG_EXPORTED_NOVALUE
[[ "$cfg_saved_exported" == "__unset__" ]] || SCIEBO_EXPORTED="$cfg_saved_exported"

CACHE_KEYS="${TMP}/config-cache-keys.env"
cat >"$CACHE_KEYS" <<'EOF'
# a comment and a blank line below

: "${CACHE_ALPHA:=1}"
: ${CACHE_BARE:=2}
"${CACHE_QUOTED:=3}"
export CACHE_EXPORT=4
CACHE_PLAIN=5
lowercase_key=6
9BAD=7
exportCACHE_GLUED=8
EOF
config_file_defines "$CACHE_KEYS" CACHE_ALPHA
expect_rc "key cache: alias form" "$?" 0
config_file_defines "$CACHE_KEYS" CACHE_BARE
expect_rc "key cache: bare alias form" "$?" 0
config_file_defines "$CACHE_KEYS" CACHE_QUOTED
expect_rc "key cache: quoted alias form" "$?" 0
config_file_defines "$CACHE_KEYS" CACHE_EXPORT
expect_rc "key cache: export assignment" "$?" 0
config_file_defines "$CACHE_KEYS" CACHE_PLAIN
expect_rc "key cache: plain assignment" "$?" 0
config_file_defines "$CACHE_KEYS" lowercase_key
expect_rc "key cache: lowercase key ignored" "$?" 1
config_file_defines "$CACHE_KEYS" 9BAD
expect_rc "key cache: leading digit ignored" "$?" 1
config_file_defines "$CACHE_KEYS" exportCACHE_GLUED
expect_rc "key cache: glued export ignored" "$?" 1

config_file_defines "$CACHE_KEYS" CACHE_EXPORT
expect_rc "key cache: membership hit" "$?" 0
config_file_defines "$CACHE_KEYS" CACHE_MISSING
expect_rc "key cache: membership miss" "$?" 1

# Appending changes the file stamp; the next refresh must observe it.
printf 'CACHE_ADDED=9\n' >>"$CACHE_KEYS"
_config_keys_refresh "$CACHE_KEYS"
config_file_defines "$CACHE_KEYS" CACHE_ADDED
expect_rc "key cache: stamp change is observed" "$?" 0

# The key set is defined by the shipped defaults, so a local override file
# must not change which keys `config list --all` reports.
CACHE_LOCAL="${TMP}/config-cache-local.env"
printf 'TRANSFERS=9\nPROXY=http://user:pass@proxy\n' >"$CACHE_LOCAL"
expect_cli "key cache: list --all without a local file rc 0" 0 run_cli config list --all
CACHE_KEYS_PLAIN="$(printf '%s\n' "$CLI_OUT" | cut -f1 | cut -d= -f1)"
capture env SETTINGS_LOCAL_FILE="$CACHE_LOCAL" bash "${PROJ}/bin/sciebo" config list --all
expect_rc "key cache: list --all with a local file rc 0" "$CLI_RC" 0
CACHE_KEYS_LOCAL="$(printf '%s\n' "$CLI_OUT" | cut -f1 | cut -d= -f1)"
expect_eq "key cache: local file does not change the key set" \
  "$CACHE_KEYS_PLAIN" "$CACHE_KEYS_LOCAL"

# --- pure _into helpers ----------------------------------------------------
# cmd_config_list/get resolve every key's value, source, and display text
# through the *_into forms so the per-key walks fork-free; these are the only
# forms, so they carry the full assertion coverage here.
# shellcheck disable=SC2034  # read by config_effective_value_into
CONFIG_INTO_VALUE="hello"
config_effective_value_into CONFIG_INTO_OUT CONFIG_INTO_VALUE
expect_eq "config_effective_value_into: reads the variable" "hello" "$CONFIG_INTO_OUT"
unset CONFIG_INTO_VALUE
config_effective_value_into CONFIG_INTO_OUT CONFIG_INTO_VALUE
expect_eq "config_effective_value_into: unset key stores empty" "" "$CONFIG_INTO_OUT"

LOCAL_SRC="${TMP}/config-into-local.env"
printf 'CONFIG_INTO_KEY=1\n' >"$LOCAL_SRC"
SETTINGS_PROFILE_LOCAL_FILE="" SETTINGS_PROFILE_FILE="" SETTINGS_LOCAL_FILE="$LOCAL_SRC"
config_key_source_into CONFIG_INTO_OUT CONFIG_INTO_KEY
expect_eq "config_key_source_into: local file wins" "local" "$CONFIG_INTO_OUT"
config_key_source_into CONFIG_INTO_SRC CONFIG_INTO_KEY
expect_eq "config_key_source_into: source stored" "local" "$CONFIG_INTO_SRC"
config_display_value_into CONFIG_INTO_OUT API_TOKEN "leaked-secret"
expect_eq "config_display_value_into: redacts" "REDACTED" "$CONFIG_INTO_OUT"
config_display_value_into CONFIG_INTO_OUT PLAIN_KEY "a"$'\t'"b"
expect_eq "config_display_value_into: strips control bytes" "ab" "$CONFIG_INTO_OUT"

# --- dispatch ---------------------------------------------------------------

expect_cli "config --help rc 0" 0 run_cli config --help
expect_contains "config --help lists subcommands" "$CLI_OUT" "Subcommands:"
expect_cli "config without a subcommand rc 0" 0 run_cli config
expect_cli "config unknown subcommand rc 2" 2 run_cli config bogus

finish
