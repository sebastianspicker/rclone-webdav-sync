#!/usr/bin/env bash
# schedule_login.sh - `schedule install --at-login --profiles` on the
# launchd backend: RunAtLoad, per-profile agents, and status listing.
# launchctl and plutil are stubbed; the real ones are never invoked.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

SCHEDULE_BIN="${TMP}/schedule-bin"
mkdir -p "$SCHEDULE_BIN"
cat >"${SCHEDULE_BIN}/launchctl" <<'STUB'
#!/bin/bash
dir="$(cd "$(dirname "$0")" && pwd)"
printf '%s\n' "$*" >>"${dir}/calls.log"
exit 0
STUB
cat >"${SCHEDULE_BIN}/plutil" <<'STUB'
#!/bin/bash
# Accept -lint; the status extracts report no value.
case "$1" in
  -lint) exit 0 ;;
  *) exit 1 ;;
esac
STUB
chmod +x "${SCHEDULE_BIN}/launchctl" "${SCHEDULE_BIN}/plutil"

HOME_DIR="${TMP}/home"
mkdir -p "$HOME_DIR"

# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_cli_launchd() {
  (cd "$TMP" && env HOME="$HOME_DIR" SCIEBO_SCHEDULER_BACKEND=launchd \
    PATH="${SCHEDULE_BIN}:$PATH" bash "${PROJ}/bin/sciebo" "$@")
}

label="${LAUNCHD_LABEL}"
plist_dir="${HOME_DIR}/Library/LaunchAgents"

expect_cli "schedule login: install --at-login rc 0" 0 run_cli_launchd schedule install --at-login
expect_file "schedule login: active plist written" "${plist_dir}/${label}.plist"
active_plist="$(cat "${plist_dir}/${label}.plist")"
expect_contains "schedule login: RunAtLoad key" "$active_plist" "<key>RunAtLoad</key>"
expect_contains "schedule login: RunAtLoad true" "$active_plist" "<true/>"
expect_not_contains "schedule login: no RunAtLoad false" "$active_plist" "<false/>"

mkdir -p "${PROFILES_DIR}/work"
expect_cli "schedule login: install --profiles rc 0" 0 run_cli_launchd schedule install --at-login --profiles work
expect_file "schedule login: profile plist written" "${plist_dir}/${label}.work.plist"
profile_plist="$(cat "${plist_dir}/${label}.work.plist")"
expect_contains "schedule login: profile command uses --profile" "$profile_plist" "--profile work"

# A glob in SCHEDULE_PROFILES is validated as a literal name, never expanded
# against the working directory.
touch "${TMP}/globvictim"
export SCHEDULE_PROFILES='*'
expect_cli "schedule login: glob profile rc 1" 1 run_cli_launchd schedule install --at-login
expect_contains "schedule login: glob rejected as a name" "$CLI_OUT" "invalid profile name '*'"
expect_not_contains "schedule login: glob not expanded" "$CLI_OUT" "globvictim"
unset SCHEDULE_PROFILES
rm -f "${TMP}/globvictim"

export SCHEDULE_PROFILES=work
expect_cli "schedule login: status rc 0" 0 run_cli_launchd schedule status
expect_contains "schedule login: status lists the active label" "$CLI_OUT" "${label}.plist"
expect_contains "schedule login: status lists the profile label" "$CLI_OUT" "${label}.work.plist"

expect_cli "schedule login: uninstall rc 0" 0 run_cli_launchd schedule uninstall
expect_no_file "schedule login: active plist removed" "${plist_dir}/${label}.plist"
expect_no_file "schedule login: profile plist removed" "${plist_dir}/${label}.work.plist"
unset SCHEDULE_PROFILES

finish
