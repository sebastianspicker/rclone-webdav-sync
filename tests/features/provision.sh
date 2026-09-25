#!/usr/bin/env bash
# provision.sh - `sciebo provision`: non-interactive profile, remote, and
# folder-pair setup from the desktop client's provisioning flags.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

PASSWORD="provision-pass-7f3a"
USERID="alice@example.org"
SERVERURL="https://cloud.example.org"
DAVURL="https://cloud.example.org/remote.php/dav/files/alice@example.org/"
DEFAULT_PROFILE="provision-alice_example.org"

# run_cli_provision ... - the CLI with the default-layout path overrides
# removed, so the command's profile layout resolves under TMP (the same
# trick profiles.sh uses for named profiles).
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_cli_provision() {
  (cd "$TMP" && env -u MANIFEST_FILE -u FOLDERS_FILE -u MANIFEST_GENERATED_FILE \
    -u ROOTS_FILE -u FILTER_DIR -u STATE_DIR -u LOG_DIR -u LOCK_DIR \
    -u CAPABILITIES_CACHE -u CAPABILITIES_JSON \
    bash "${PROJ}/bin/sciebo" "$@")
}

# rclone validation must succeed without a live server: a pass-through stub
# answers every `lsd` with rc 0 and delegates everything else (config,
# obscure, reveal) to the real binary.
REAL_RCLONE="$(command -v rclone)"
STUB_RCLONE_DIR="${TMP}/provision-rclone-bin"
mkdir -p "$STUB_RCLONE_DIR"
cat >"${STUB_RCLONE_DIR}/rclone" <<EOF
#!/bin/bash
for arg in "\$@"; do
  [[ "\$arg" != "lsd" ]] || exit 0
done
exec "${REAL_RCLONE}" "\$@"
EOF
chmod +x "${STUB_RCLONE_DIR}/rclone"
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_cli_provision_stub() {
  (cd "$TMP" && env -u MANIFEST_FILE -u FOLDERS_FILE -u MANIFEST_GENERATED_FILE \
    -u ROOTS_FILE -u FILTER_DIR -u STATE_DIR -u LOG_DIR -u LOCK_DIR \
    -u CAPABILITIES_CACHE -u CAPABILITIES_JSON PATH="${STUB_RCLONE_DIR}:$PATH" \
    bash "${PROJ}/bin/sciebo" "$@")
}

# --- required options and value validation ----------------------------------
expect_cli "missing --userid rc 2" 2 run_cli_provision provision
expect_contains "missing --userid message" "$CLI_OUT" "--userid is required"
expect_cli "missing --apppassword rc 2" 2 run_cli_provision provision --userid "$USERID"
expect_contains "missing --apppassword message" "$CLI_OUT" "--apppassword is required"
expect_cli "missing --serverurl rc 2" 2 run_cli_provision provision \
  --userid "$USERID" --apppassword "$PASSWORD"
expect_contains "missing --serverurl message" "$CLI_OUT" "--serverurl is required"
expect_cli "unknown option rc 2" 2 run_cli_provision provision --bogus
expect_contains "unknown option message" "$CLI_OUT" "unknown option: --bogus"
expect_not_contains "usage errors never echo the password" "$CLI_OUT" "$PASSWORD"

expect_cli "reject --isvfsenabled 2 rc 2" 2 run_cli_provision provision \
  --userid "$USERID" --apppassword "$PASSWORD" --serverurl "$SERVERURL" --isvfsenabled 2
expect_contains "reject --isvfsenabled 2 message" "$CLI_OUT" "--isvfsenabled accepts 0 or 1"
expect_cli "reject missing --isvfsenabled value rc 2" 2 run_cli_provision provision \
  --userid "$USERID" --apppassword "$PASSWORD" --serverurl "$SERVERURL" --isvfsenabled
expect_contains "missing value message" "$CLI_OUT" "--isvfsenabled requires a value"

expect_cli "reject --profile default rc 1" 1 run_cli_provision provision \
  --userid "$USERID" --apppassword "$PASSWORD" --serverurl "$SERVERURL" --profile default
expect_contains "reject --profile default message" "$CLI_OUT" "'default' is reserved"

# --- unreachable server: real rclone, clear failure -------------------------
expect_cli "unreachable server rc 1" 1 run_cli_provision provision \
  --userid "$USERID" --apppassword "$PASSWORD" \
  --serverurl http://127.0.0.1:9 --profile prov-unreachable
expect_contains "unreachable failure message" "$CLI_OUT" "validation failed"
expect_contains "unreachable rclone detail" "$CLI_OUT" "rclone lsd failed"
expect_not_contains "unreachable output has no password" "$CLI_OUT" "$PASSWORD"
expect_file "unreachable run still created the profile" \
  "${PROFILES_DIR}/prov-unreachable/settings.local.env"

# --- account-only provisioning and the derived default profile name ---------
profile_dir="${PROFILES_DIR}/${DEFAULT_PROFILE}"
expect_cli "account-only rc 0" 0 run_cli_provision_stub provision \
  --userid "$USERID" --apppassword "$PASSWORD" --serverurl "$SERVERURL"
expect_contains "summary profile" "$CLI_OUT" "provisioned profile '${DEFAULT_PROFILE}'"
expect_contains "summary remote" "$CLI_OUT" "remote: ${DEFAULT_PROFILE}:"
expect_contains "summary server" "$CLI_OUT" "server: ${DAVURL}"
expect_contains "summary password location" "$CLI_OUT" "password: rclone config (obscured)"
expect_contains "summary no pair" "$CLI_OUT" "no folder pair was added"
expect_not_contains "account-only output has no password" "$CLI_OUT" "$PASSWORD"
expect_file "profile sources.conf" "${profile_dir}/sources.conf"
expect_file "profile folders.conf" "${profile_dir}/folders.conf"
expect_file "profile roots.conf" "${profile_dir}/roots.conf"
expect_file "profile settings.local.env" "${profile_dir}/settings.local.env"
expect_file "profile clutter filter" "${profile_dir}/filters/clutter.txt"
expect_file "profile state layout" "${PROFILES_STATE_DIR}/${DEFAULT_PROFILE}/VERSION"
expect_contains "settings name the profile remote" \
  "$(cat "${profile_dir}/settings.local.env")" "RCLONE_REMOTE=\"${DEFAULT_PROFILE}\""
expect_eq "account-only leaves folders.conf empty" "" "$(cat "${profile_dir}/folders.conf")"

dump="$(rclone --config "$RCLONE_CONFIG" config dump 2>/dev/null)"
expect_contains "remote type" "$dump" '"type": "webdav"'
expect_contains "remote url is normalized" "$dump" "$DAVURL"
expect_contains "remote vendor" "$dump" '"vendor": "nextcloud"'
expect_contains "remote user" "$dump" '"user": "alice@example.org"'
stored_pass="$(config_dump_value "$DEFAULT_PROFILE" pass "$dump")"
expect_eq "stored pass reveals to the app password" "$PASSWORD" \
  "$(rclone reveal -- "$stored_pass" 2>/dev/null)"
expect_not_contains "plain password never in the rclone config" "$dump" "$PASSWORD"

# --- pair with --localdirpath/--remotedirpath -------------------------------
pair_local="${TMP}/pair-data"
mkdir -p "$pair_local"
expect_cli "pair rc 0" 0 run_cli_provision_stub provision \
  --userid "$USERID" --apppassword "$PASSWORD" --serverurl "$SERVERURL" \
  --profile work --localdirpath "$pair_local" --remotedirpath /Photos/Vacation/
expect_contains "pair summary" "$CLI_OUT" \
  "pair:   ${pair_local} <-> work:backup/Photos/Vacation (bisync)"
expect_not_contains "pair output has no password" "$CLI_OUT" "$PASSWORD"
expect_contains "pair line in folders.conf" \
  "$(cat "${PROFILES_DIR}/work/folders.conf")" "bisync|${pair_local}|Photos/Vacation"
expect_file "pair profile settings" "${PROFILES_DIR}/work/settings.local.env"

# --- a /-rooted --remotedirpath means the whole remote base -----------------
root_local="${TMP}/root-data"
mkdir -p "$root_local"
expect_cli "root pair rc 0" 0 run_cli_provision_stub provision \
  --userid "$USERID" --apppassword "$PASSWORD" --serverurl "$SERVERURL" \
  --profile rootpair --localdirpath "$root_local"
expect_contains "root pair line in folders.conf" \
  "$(cat "${PROFILES_DIR}/rootpair/folders.conf")" "bisync|${root_local}|."
expect_contains "root pair summary spec" "$CLI_OUT" "rootpair:backup/."

# --- --isvfsenabled: 1 warns, 0 is silent -----------------------------------
vfs_local="${TMP}/vfs-data"
mkdir -p "$vfs_local"
expect_cli "vfs=1 rc 0" 0 run_cli_provision_stub provision \
  --userid "$USERID" --apppassword "$PASSWORD" --serverurl "$SERVERURL" \
  --profile vfspair --localdirpath "$vfs_local" --remotedirpath docs --isvfsenabled 1
expect_contains "vfs=1 warns that the flag is ignored" "$CLI_OUT" "--isvfsenabled 1 is ignored"
expect_contains "vfs=1 stays a two-way pair" "$CLI_OUT" "two-way (bisync)"
expect_contains "vfs=1 pair is still bisync" \
  "$(cat "${PROFILES_DIR}/vfspair/folders.conf")" "bisync|${vfs_local}|docs"

expect_cli "vfs=0 rc 0" 0 run_cli_provision_stub provision \
  --userid "$USERID" --apppassword "$PASSWORD" --serverurl "$SERVERURL" \
  --profile vfszero --localdirpath "$vfs_local" --remotedirpath docs2 --isvfsenabled 0
expect_not_contains "vfs=0 is silent" "$CLI_OUT" "--isvfsenabled 1 is ignored"

# --- the plain app password never lands in any file under TMP ---------------
leak="$(grep -rlF "$PASSWORD" "$TMP" 2>/dev/null || true)"
expect_eq "password absent from every created file" "" "$leak"

finish
