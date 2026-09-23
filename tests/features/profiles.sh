#!/usr/bin/env bash
# profiles.sh - named profiles, account management, logout, global flags.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

WORK_DIR="${PROFILES_DIR}/feature-work"
WORK_STATE="${PROFILES_STATE_DIR}/feature-work"

# Run the CLI under a named profile without the default-layout path
# overrides, so config layout derives from PROFILES_DIR (still in TMP).
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_cli_profile() {
  local name="$1"
  shift
  (cd "$TMP" && env -u MANIFEST_FILE -u FOLDERS_FILE -u MANIFEST_GENERATED_FILE \
    -u ROOTS_FILE -u FILTER_DIR -u STATE_DIR -u LOG_DIR -u LOCK_DIR \
    -u CAPABILITIES_CACHE -u CAPABILITIES_JSON \
    SCIEBO_PROFILE="$name" bash "${PROJ}/bin/sciebo" "$@")
}

# --- account list/add/use/remove ------------------------------------------
expect_cli "account: list rc 0" 0 run_cli account list
expect_contains "account: default profile listed" "$CLI_OUT" "default"

expect_cli "account: add rc 0" 0 run_cli account add feature-work --remote workremote --base work
expect_file "account: profile settings written" "${WORK_DIR}/settings.local.env"
expect_file "account: profile sources written" "${WORK_DIR}/sources.conf"
expect_file "account: profile filters copied" "${WORK_DIR}/filters/clutter.txt"
expect_contains "account: add names the next step" "$CLI_OUT" "folders choose"
expect_cli "account: duplicate add rc 1" 1 run_cli account add feature-work
expect_cli "account: invalid name rc 1" 1 run_cli account add "../evil"
expect_cli "account: default cannot be removed" 1 run_cli account remove default

expect_cli "account: list shows the profile" 0 run_cli account list
expect_contains "account: row remote" "$CLI_OUT" "workremote"
expect_contains "account: row base" "$CLI_OUT" "work"
expect_contains "account: row keychain service" "$CLI_OUT" "rclone-sciebo/feature-work"

# --- account status (text unchanged, --json added) -------------------------
expect_cli "account: status rc 0" 0 run_cli account status
expect_contains "account: status text remote line" "$CLI_OUT" "remote configured: yes"
expect_contains "account: status text reachable line" "$CLI_OUT" "server reachable: PASS"
expect_contains "account: status text cache line" "$CLI_OUT" "capabilities cache age:"
expect_cli "account: status --json rc 0" 0 run_cli account status --json
expect_contains "account: status --json remote" "$CLI_OUT" '"remote": "testremote"'
expect_contains "account: status --json configured" "$CLI_OUT" '"configured": true'
expect_contains "account: status --json reachable" "$CLI_OUT" '"reachable": true'
expect_contains "account: status --json cache age" "$CLI_OUT" '"capabilities_cache_age": "none"'
expect_contains "account: status --json last check" "$CLI_OUT" '"last_check": ""'
expect_contains "account: status --json keychain" "$CLI_OUT" '"keychain_backend"'
expect_cli "account: status unknown option rc 2" 2 run_cli account status --bogus

expect_cli "account: use rc 0" 0 run_cli account use feature-work
expect_contains "account: use prints activation" "$CLI_OUT" "SCIEBO_PROFILE=feature-work"
expect_cli "account: use unknown rc 1" 1 run_cli account use nope
expect_cli "account: unknown subcommand rc 2" 2 run_cli account bogus

# --- profile layout: manifests and state stay inside the profile ----------
printf 'sync|%s|workstuff\n' "$TMP" >"${WORK_DIR}/sources.conf"
printf 'x\n' >"${TMP}/profile-conflict (conflicted copy).txt"
expect_cli "profile: list uses the profile manifest" 0 run_cli_profile feature-work list
expect_contains "profile: list shows the profile source" "$CLI_OUT" "workstuff"
expect_cli "profile: conflicts scans the profile tree" 1 run_cli_profile feature-work conflicts --quiet
expect_no_file "profile: no default-state writes" "${TMP}/state/last/workstuff"
rm -f "${TMP}/profile-conflict (conflicted copy).txt"
expect_cli "profile: conflicts clean again" 0 run_cli_profile feature-work conflicts --quiet
expect_cli "profile: unknown profile rc 1" 1 run_cli_profile missing list
expect_contains "profile: unknown profile hint" "$CLI_OUT" "account add missing"

# --- global flags ---------------------------------------------------------
stub_clear_calls
stub_reset_routes
stub_route PROPFIND '*/remote.php/dav/trashbin/alice/trash' 200 <<'XML'
<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"/>
XML
expect_cli "global: --trust runs the command" 0 run_cli_nc --trust trash
expect_contains "global: --trust adds curl -k" "$(stub_args)" " -k "
expect_cli "global: --debug runs the command" 0 run_cli_nc --debug trash
expect_contains "global: --debug adds curl -v" "$(stub_args)" " -v "
expect_cli "global: --profile=value form" 0 run_cli_profile feature-work --profile=feature-work list
expect_contains "global: --profile=value selects the profile" "$CLI_OUT" "workstuff"
expect_cli "global: --profile needs a value rc 2" 2 run_cli --profile

# --- logout removes the configured remote ---------------------------------
expect_cli "logout: removes the remote" 0 run_cli logout --yes
expect_contains "logout: says what it removed" "$CLI_OUT" "removed rclone remote 'testremote:'"
remotes="$(rclone listremotes --config "$RCLONE_CONFIG" 2>/dev/null)"
expect_not_contains "logout: remote is gone" "$remotes" "testremote:"
expect_cli "logout: second run is a no-op" 0 run_cli logout --yes
expect_contains "logout: nothing to do" "$CLI_OUT" "nothing to do"
# Restore the remote so the EXIT trap does not matter either way.
rclone config create testremote local --config "$RCLONE_CONFIG" >/dev/null 2>&1

# --- remove needs --yes in a non-interactive run --------------------------
expect_cli "account: remove without --yes rc 2" 2 run_cli account remove feature-work
expect_cli "account: remove --yes rc 0" 0 run_cli account remove feature-work --yes
expect_no_file "account: profile config removed" "${WORK_DIR}/sources.conf"
expect_no_file "account: profile state removed" "$WORK_STATE"
expect_cli "account: remove missing rc 1" 1 run_cli account remove feature-work

finish
