#!/usr/bin/env bash
# account_import.sh - `account import`: migrate accounts, folder pairs, and
# mapped settings from the Nextcloud desktop client's nextcloud.cfg.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

# The imported fixtures below use absolute paths under /home; declaring that
# as the configured local root keeps them in-root. The guard for absolute
# out-of-root localPath values gets its own fixture further down.
export FOLDERS_LOCAL_ROOT=/home

IMPORT_CFG="${TMP}/nextcloud.cfg"
IMPORT_OUTSIDE_CFG="${TMP}/nextcloud-outside.cfg"
IMPORT_HOME="${TMP}/import-home"
IMPORT_LINUX_HOME="${TMP}/linux-home"
IMPORT_APPDATA="${TMP}/AppData/Roaming"
IMPORT_EMPTY_HOME="${TMP}/empty-home"
mkdir -p "$IMPORT_EMPTY_HOME"

cat >"$IMPORT_CFG" <<'EOF'
[General]
chunkSize=10000000
minChunkSize=5000000
maxChunkSize=100000000
timeout=300
moveToTrash=true
promptDeleteAllFiles=false
deleteFilesThreshold=100
launchOnSystemStartup=true
newBigFolderSizeLimit=500
useNewBigFolderSizeLimit=true
logDebug=1
logDir="/tmp/nextcloud log"
logExpire=5
this line has no equals sign

[Accounts]
0\url=https://cloud.example.org
0\user="alice"
0\Folders\1\localPath=/home/alice/Nextcloud
0\Folders\1\targetPath=/
0\Folders\1\paused=false
0\Folders\1\ignoreHiddenFiles=true
0\Folders\2\localPath=/home/alice/Work
0\Folders\2\targetPath="/Work=2026"
0\Folders\2\paused=true
1/url=https://cloud.example.org
1/user=bob
1/Folders/1/localPath=/home/bob/Stuff
1/Folders/1/targetPath=Stuff
2\url=https://cloud.example.org
2\user=erin@example.org
2\Folders\1\localPath=/home/erin/Data
2\Folders\1\targetPath=Data
numAccounts=3
EOF

# One absolute localPath outside the configured local root and one relative
# path, so a single import exercises both the guard and the preserved
# relative-path behavior.
cat >"$IMPORT_OUTSIDE_CFG" <<'EOF'
[Accounts]
0/url=https://cloud.example.org
0/user=mallory
0/Folders/1/localPath=/opt/outside
0/Folders/1/targetPath=Outside
0/Folders/2/localPath=outside-relative
0/Folders/2/targetPath=Relative
EOF

# run_cli_home HOME ARGS... - run the CLI with a different HOME (for the
# default nextcloud.cfg discovery).
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_cli_home() {
  local home="$1"
  shift
  (cd "$TMP" && env HOME="$home" bash "${PROJ}/bin/sciebo" "$@")
}

# run_cli_appdata APPDATA ARGS... - run with APPDATA set and a HOME that
# holds no Nextcloud config.
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_cli_appdata() {
  local appdata="$1"
  shift
  (cd "$TMP" && env HOME="$IMPORT_EMPTY_HOME" APPDATA="$appdata" bash "${PROJ}/bin/sciebo" "$@")
}

# run_cli_cfg CFG ARGS... - run with NEXTCLOUD_CFG pointing at CFG.
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_cli_cfg() {
  local cfg="$1"
  shift
  (cd "$TMP" && env NEXTCLOUD_CFG="$cfg" bash "${PROJ}/bin/sciebo" "$@")
}

# pair_lines FILE - number of manifest pair lines in FILE.
pair_lines() {
  [[ -f "$1" ]] || {
    printf '0'
    return 0
  }
  grep -c '^bisync' "$1" 2>/dev/null || true
}

# import_reset - clear the imported profiles and the project-wide manifests
# and settings so each import scenario starts clean.
import_reset() {
  rm -rf "${PROFILES_DIR}/bob" "${PROFILES_DIR}/account2" \
    "${PROFILES_STATE_DIR}/bob" "${PROFILES_STATE_DIR}/account2" \
    "${STATE_DIR}/pairs"
  : >"$FOLDERS_FILE"
  rm -f "$SETTINGS_LOCAL_FILE"
}

# --- usage and the dry-run plan --------------------------------------------

expect_cli "import: help rc 0" 0 run_cli account import --help
expect_contains "import: help documents the config option" "$CLI_OUT" "--nextcloud-cfg"
expect_contains "import: help documents dry-run" "$CLI_OUT" "--dry-run"

expect_cli "import: dry run rc 0" 0 run_cli account import --nextcloud-cfg "$IMPORT_CFG" --dry-run
expect_contains "import: dry run header" "$CLI_OUT" "dry run"
expect_contains "import: plans account 0 as the default profile" "$CLI_OUT" "[default] account 0 (alice)"
expect_contains "import: plans account 1 as its user name" "$CLI_OUT" "[bob] account 1 (bob)"
expect_contains "import: derives accountN for an unsafe user id" "$CLI_OUT" "[account2] account 2 (erin@example.org)"
expect_contains "import: maps chunkSize" "$CLI_OUT" 'CHUNK_SIZE="10000000"'
expect_contains "import: maps minChunkSize" "$CLI_OUT" 'MIN_CHUNK_SIZE="5000000"'
expect_contains "import: maps maxChunkSize" "$CLI_OUT" 'MAX_CHUNK_SIZE="100000000"'
expect_contains "import: maps timeout" "$CLI_OUT" 'TIMEOUT="300s"'
expect_contains "import: maps moveToTrash" "$CLI_OUT" 'MOVE_TO_TRASH="1"'
expect_contains "import: maps promptDeleteAllFiles" "$CLI_OUT" 'ASK_DELETE="0"'
expect_contains "import: maps deleteFilesThreshold" "$CLI_OUT" 'DELETE_FILES_THRESHOLD="100"'
expect_contains "import: maps launchOnSystemStartup" "$CLI_OUT" 'SCHEDULE_AT_LOGIN="1"'
expect_contains "import: maps newBigFolderSizeLimit" "$CLI_OUT" 'BIG_FOLDER_SIZE="500Mi"'
expect_contains "import: maps logDebug" "$CLI_OUT" 'LOG_LEVEL="DEBUG"'
expect_contains "import: root target becomes the remote base" "$CLI_OUT" "pair: /home/alice/Nextcloud -> . (bisync)"
expect_contains "import: quoted target keeps '=' in the name" "$CLI_OUT" "pair: /home/alice/Work -> Work=2026 (bisync)"
expect_contains "import: reports paused folders" "$CLI_OUT" "paused in the desktop client"
expect_contains "import: reports hidden-file folders" "$CLI_OUT" "ignores hidden files in the desktop client"
expect_contains "import: dry run says the flags are not stored yet" "$CLI_OUT" "will be stored on apply"
expect_contains "import: warns about a malformed line" "$CLI_OUT" "malformed line 15"
expect_contains "import: prints the password follow-up" "$CLI_OUT" "setup --login"
expect_contains "import: names the profile in the follow-up" "$CLI_OUT" "--profile bob setup --login"
expect_eq "import: dry run leaves folders.conf empty" "0" "$(pair_lines "$FOLDERS_FILE")"
expect_no_file "import: dry run creates no profile" "${PROFILES_DIR}/bob"
expect_no_file "import: dry run writes no settings" "$SETTINGS_LOCAL_FILE"

# --- default config discovery ----------------------------------------------

mkdir -p "${IMPORT_HOME}/Library/Containers/com.nextcloud.desktopclient/Data/Library/Preferences/Nextcloud"
cat >"${IMPORT_HOME}/Library/Containers/com.nextcloud.desktopclient/Data/Library/Preferences/Nextcloud/nextcloud.cfg" <<'EOF'
[Accounts]
0/url=https://container.example.org
0/user=bailey
EOF
expect_cli "import: finds the macOS app container config" 0 run_cli_home "$IMPORT_HOME" account import --dry-run
expect_contains "import: container config user is planned" "$CLI_OUT" "bailey"
rm -rf "${IMPORT_HOME}/Library/Containers"

mkdir -p "${IMPORT_HOME}/Library/Preferences/Nextcloud"
cat >"${IMPORT_HOME}/Library/Preferences/Nextcloud/nextcloud.cfg" <<'EOF'
[General]
timeout=120
[Accounts]
0/url=https://legacy.example.org
0/user=carol
0/Folders/1/localPath=/home/carol/Docs
0/Folders/1/targetPath=Docs
EOF
expect_cli "import: finds the macOS legacy config" 0 run_cli_home "$IMPORT_HOME" account import --dry-run
expect_contains "import: reports the discovered path" "$CLI_OUT" "${IMPORT_HOME}/Library/Preferences/Nextcloud/nextcloud.cfg"
expect_contains "import: plans the discovered user" "$CLI_OUT" "carol"

mkdir -p "${IMPORT_HOME}/.config/Nextcloud"
cat >"${IMPORT_HOME}/.config/Nextcloud/nextcloud.cfg" <<'EOF'
[Accounts]
0/url=https://linux.example.org
0/user=dave
EOF
expect_cli "import: prefers the earlier discovery path" 0 run_cli_home "$IMPORT_HOME" account import --dry-run
expect_contains "import: earlier path still wins" "$CLI_OUT" "carol"
expect_not_contains "import: later path is ignored" "$CLI_OUT" "dave"

mkdir -p "${IMPORT_LINUX_HOME}/.config/Nextcloud"
cp "${IMPORT_HOME}/.config/Nextcloud/nextcloud.cfg" "${IMPORT_LINUX_HOME}/.config/Nextcloud/nextcloud.cfg"
expect_cli "import: finds the Linux config" 0 run_cli_home "$IMPORT_LINUX_HOME" account import --dry-run
expect_contains "import: Linux config user is planned" "$CLI_OUT" "dave"

mkdir -p "${IMPORT_APPDATA}/Nextcloud"
cat >"${IMPORT_APPDATA}/Nextcloud/nextcloud.cfg" <<'EOF'
[Accounts]
0/url=https://windows.example.org
0/user=erin
EOF
expect_cli "import: finds the APPDATA config" 0 run_cli_appdata "$IMPORT_APPDATA" account import --dry-run
expect_contains "import: APPDATA config user is planned" "$CLI_OUT" "erin"

expect_cli "import: NEXTCLOUD_CFG overrides discovery" 0 run_cli_cfg "$IMPORT_CFG" account import --dry-run
expect_contains "import: NEXTCLOUD_CFG config is used" "$CLI_OUT" "alice"

# --- failures ---------------------------------------------------------------

expect_cli "import: missing explicit config rc 1" 1 run_cli account import --nextcloud-cfg "${TMP}/missing.cfg"
expect_contains "import: missing config message" "$CLI_OUT" "cannot read Nextcloud config"

expect_cli "import: no config found rc 1" 1 run_cli_home "$IMPORT_EMPTY_HOME" account import
expect_contains "import: missing config is reported" "$CLI_OUT" "no Nextcloud desktop client config found"
expect_contains "import: missing config lists the searched paths" "$CLI_OUT" "${IMPORT_EMPTY_HOME}/.config/Nextcloud/nextcloud.cfg"

expect_cli "import: unknown selector rc 1" 1 run_cli account import --nextcloud-cfg "$IMPORT_CFG" --profile nope
expect_contains "import: unknown selector message" "$CLI_OUT" "no configured Nextcloud account matches"

# --- importing one named profile -------------------------------------------

import_reset
expect_cli "import: profile user rc 0" 0 run_cli account import --nextcloud-cfg "$IMPORT_CFG" --profile bob
expect_file "import: profile settings created" "${PROFILES_DIR}/bob/settings.local.env"
expect_file "import: profile folders created" "${PROFILES_DIR}/bob/folders.conf"
expect_file "import: profile filter copied" "${PROFILES_DIR}/bob/filters/clutter.txt"
if [[ -d "${PROFILES_STATE_DIR}/bob" ]]; then
  pass "import: profile state directory created"
else
  fail "import: profile state directory created" "missing ${PROFILES_STATE_DIR}/bob"
fi
expect_contains "import: profile pair written" "$(cat "${PROFILES_DIR}/bob/folders.conf")" "bisync|/home/bob/Stuff|Stuff"
expect_eq "import: one pair in the profile" "1" "$(pair_lines "${PROFILES_DIR}/bob/folders.conf")"
expect_contains "import: profile chunk size" "$(cat "${PROFILES_DIR}/bob/settings.local.env")" 'CHUNK_SIZE="10000000"'
expect_contains "import: profile timeout" "$(cat "${PROFILES_DIR}/bob/settings.local.env")" 'TIMEOUT="300s"'
expect_contains "import: profile debug level" "$(cat "${PROFILES_DIR}/bob/settings.local.env")" 'LOG_LEVEL="DEBUG"'
expect_contains "import: profile setup hint" "$CLI_OUT" "--profile bob setup --login"
expect_no_file "import: no default settings written" "$SETTINGS_LOCAL_FILE"

expect_cli "import: existing profile refused rc 2" 2 run_cli account import --nextcloud-cfg "$IMPORT_CFG" --profile bob
expect_contains "import: refusal names --yes" "$CLI_OUT" "without --yes"
expect_eq "import: refusal changes nothing" "1" "$(pair_lines "${PROFILES_DIR}/bob/folders.conf")"

expect_cli "import: dry run of an existing profile rc 0" 0 run_cli account import --nextcloud-cfg "$IMPORT_CFG" --profile bob --dry-run
expect_contains "import: dry run flags the --yes requirement" "$CLI_OUT" "re-run with --yes"

printf 'CUSTOM_SETTING="keep-me"\n' >>"${PROFILES_DIR}/bob/settings.local.env"
expect_cli "import: --yes merges the existing profile" 0 run_cli account import --nextcloud-cfg "$IMPORT_CFG" --profile bob --yes
expect_eq "import: --yes adds no duplicate pair" "1" "$(pair_lines "${PROFILES_DIR}/bob/folders.conf")"
expect_contains "import: merge reports the already-configured pair" "$CLI_OUT" "1 pair(s) already configured"
expect_contains "import: merge preserves other settings" "$(cat "${PROFILES_DIR}/bob/settings.local.env")" 'CUSTOM_SETTING="keep-me"'
expect_eq "import: merge keeps one chunk size line" "1" "$(grep -c '^CHUNK_SIZE=' "${PROFILES_DIR}/bob/settings.local.env")"

# --- importing account 0 into the default profile --------------------------

import_reset
expect_cli "import: account index 0 rc 0" 0 run_cli account import --nextcloud-cfg "$IMPORT_CFG" --profile 0
expect_file "import: default settings written" "$SETTINGS_LOCAL_FILE"
expect_contains "import: default settings chunk size" "$(cat "$SETTINGS_LOCAL_FILE")" 'CHUNK_SIZE="10000000"'
expect_contains "import: default root pair" "$(cat "$FOLDERS_FILE")" "bisync|/home/alice/Nextcloud|."
expect_contains "import: default nested pair" "$(cat "$FOLDERS_FILE")" "bisync|/home/alice/Work|Work=2026"
expect_eq "import: two default pairs" "2" "$(pair_lines "$FOLDERS_FILE")"
expect_contains "import: default setup hint omits the profile" "$CLI_OUT" "run 'sciebo setup --login'"
expect_no_file "import: default import creates no profile dir" "${PROFILES_DIR}/default"

# The per-folder paused/ignoreHiddenFiles booleans are persisted as per-pair
# flags: "entry" (target ".") is hidden, "Work_2026" is paused.
expect_file "import: hidden flag file written" "${STATE_DIR}/pairs/entry"
expect_contains "import: hidden flag value" "$(cat "${STATE_DIR}/pairs/entry")" "hidden=1"
expect_file "import: paused flag file written" "${STATE_DIR}/pairs/Work_2026"
expect_contains "import: paused flag value" "$(cat "${STATE_DIR}/pairs/Work_2026")" "paused=1"
expect_eq "import: flag file is mode 600" "600" "$(file_mode "${STATE_DIR}/pairs/entry")"
expect_eq "import: applied summary names the flag" "1" "$(grep -c 'paused flag stored' <<<"$CLI_OUT")"

expect_cli "import: folders list --json rc 0" 0 run_cli folders list --json
expect_contains "import: list --json surfaces hidden" "$CLI_OUT" '"hidden": true'
expect_contains "import: list --json surfaces paused" "$CLI_OUT" '"paused": true'
expect_contains "import: list --json keeps the name" "$CLI_OUT" '"name": "Work_2026"'
expect_cli "import: folders list text rc 0" 0 run_cli folders list
expect_contains "import: list text has the PAUSED column" "$CLI_OUT" "PAUSED"

# --- JSON -------------------------------------------------------------------

import_reset
expect_cli "import: json dry run rc 0" 0 run_cli account import --nextcloud-cfg "$IMPORT_CFG" --dry-run --json
expect_contains "import: json has the imports array" "$CLI_OUT" '"imports"'
expect_contains "import: json dry_run flag" "$CLI_OUT" '"dry_run": true'
expect_contains "import: json default profile" "$CLI_OUT" '"profile": "default"'
expect_contains "import: json planned status" "$CLI_OUT" '"status": "planned"'
expect_contains "import: json not applied" "$CLI_OUT" '"applied": false'
expect_contains "import: json pair object" "$CLI_OUT" '"remote": "."'
expect_contains "import: json paused pair" "$CLI_OUT" '"paused": true'
expect_contains "import: json settings array" "$CLI_OUT" '"CHUNK_SIZE=\"10000000\""'
expect_eq "import: json dry run writes nothing" "0" "$(pair_lines "$FOLDERS_FILE")"

expect_cli "import: json apply rc 0" 0 run_cli account import --nextcloud-cfg "$IMPORT_CFG" --json
expect_contains "import: json applied profile" "$CLI_OUT" '"profile": "bob"'
expect_contains "import: json applied unsafe user" "$CLI_OUT" '"profile": "account2"'
expect_contains "import: json applied status" "$CLI_OUT" '"status": "applied"'
expect_contains "import: json applied flag" "$CLI_OUT" '"applied": true'
expect_contains "import: json skipped counter" "$CLI_OUT" '"skipped":'
expect_file "import: json apply wrote the profile" "${PROFILES_DIR}/bob/settings.local.env"
expect_contains "import: json apply wrote the pair" "$(cat "${PROFILES_DIR}/bob/folders.conf")" "bisync|/home/bob/Stuff|Stuff"

# --- no atomic-write temp debris --------------------------------------------

# An applied import writes settings, folder pairs, and per-pair flags through
# atomic_write, which stages into a sibling FILE.tmp.XXXXXX and renames it into
# place. A leftover tmp file means a write unwound without discarding its
# staging file; a repo-root 600.tmp.* would additionally mean a relative mktemp
# ran from the project root. Both must be empty after the applied imports
# above.
state_debris="$(find "${STATE_DIR}" -name '*.tmp.*' -print 2>/dev/null || true)"
expect_eq "import: no state-dir temp debris" "" "$state_debris"
root_debris="$(compgen -G "${PROJ}/600.tmp.*" || true)"
expect_eq "import: no repo-root temp debris" "" "$root_debris"

# --- unsafe profile settings file (account list) ----------------------------

import_reset
mkdir -p "${PROFILES_DIR}/evil"
printf 'RCLONE_REMOTE=evilremote\n' >"${PROFILES_DIR}/evil/settings.local.env"
chmod 664 "${PROFILES_DIR}/evil/settings.local.env"
expect_cli "account: list refuses a group-writable profile settings file" 0 run_cli account list
expect_contains "account: list warns about the unsafe file" "$CLI_OUT" "refusing to source unsafe file"
expect_contains "account: list names the unsafe file" "$CLI_OUT" "${PROFILES_DIR}/evil/settings.local.env"
expect_contains "account: list skips the profile" "$CLI_OUT" "skipping profile 'evil'"
expect_not_contains "account: list never runs the unsafe settings" "$CLI_OUT" "evilremote"
rm -rf "${PROFILES_DIR}/evil"

# --- absolute localPath outside the configured local root -------------------

import_reset
expect_cli "import: out-of-root dry run rc 0" 0 \
  run_cli account import --nextcloud-cfg "$IMPORT_OUTSIDE_CFG" --profile 0 --dry-run
expect_contains "import: dry run still plans the out-of-root pair" "$CLI_OUT" \
  "pair: /opt/outside -> Outside (bisync)"
expect_contains "import: dry run still plans the relative pair" "$CLI_OUT" \
  "pair: outside-relative -> Relative (bisync)"
expect_eq "import: out-of-root dry run writes nothing" "0" "$(pair_lines "$FOLDERS_FILE")"

import_reset
expect_cli "import: out-of-root skipped without --yes rc 0" 0 \
  run_cli account import --nextcloud-cfg "$IMPORT_OUTSIDE_CFG" --profile 0
expect_contains "import: out-of-root skip warning" "$CLI_OUT" "outside the configured local root"
expect_contains "import: relative path still imported without --yes" "$(cat "$FOLDERS_FILE")" \
  "bisync|outside-relative|Relative"
expect_not_contains "import: out-of-root path not imported without --yes" "$(cat "$FOLDERS_FILE")" \
  "/opt/outside"
expect_eq "import: only the relative pair written" "1" "$(pair_lines "$FOLDERS_FILE")"

expect_cli "import: out-of-root imported with --yes rc 0" 0 \
  run_cli account import --nextcloud-cfg "$IMPORT_OUTSIDE_CFG" --profile 0 --yes
expect_contains "import: out-of-root pair written with --yes" "$(cat "$FOLDERS_FILE")" \
  "bisync|/opt/outside|Outside"
expect_eq "import: both pairs present with --yes" "2" "$(pair_lines "$FOLDERS_FILE")"

# --- per-pair paused/hidden flags shape a real sync run ---------------------

import_reset
PAIR_LOCAL="${TMP}/flags-local"
mkdir -p "$PAIR_LOCAL"
printf 'visible\n' >"${PAIR_LOCAL}/visible.txt"
printf 'hidden\n' >"${PAIR_LOCAL}/.secret.txt"
cat >"$MANIFEST_FILE" <<EOF
sync|${PAIR_LOCAL}|flags-src
EOF
rm -rf "${TMP}/backup/flags-src"

# Paused: sync skips the pair without transferring and records it as skipped.
mkdir -p "${STATE_DIR}/pairs"
printf 'paused=1\n' >"${STATE_DIR}/pairs/flags-src"
expect_cli "flags: paused sync rc 0" 0 run_cli sync --apply
expect_contains "flags: paused skip reason" "$CLI_OUT" "pair is paused"
expect_contains "flags: paused counted as skipped" "$CLI_OUT" "1 skipped"
expect_no_file "flags: paused pair transfers nothing" "${TMP}/backup/flags-src/visible.txt"
expect_contains "flags: paused runstate status" "$(cat "${STATE_DIR}/last/flags-src")" "status=skipped"

# --force runs a paused pair anyway.
expect_cli "flags: --force runs the paused pair rc 0" 0 run_cli sync --apply --force
expect_file "flags: --force uploads despite the pause" "${TMP}/backup/flags-src/visible.txt"

# Hidden: only the dotfile is excluded for this pair.
printf 'hidden=1\n' >"${STATE_DIR}/pairs/flags-src"
rm -rf "${TMP}/backup/flags-src"
expect_cli "flags: hidden sync rc 0" 0 run_cli sync --apply
expect_file "flags: hidden pair uploads the visible file" "${TMP}/backup/flags-src/visible.txt"
expect_no_file "flags: hidden pair excludes the dotfile" "${TMP}/backup/flags-src/.secret.txt"
expect_cli "flags: ignored rc 0" 0 run_cli ignored --source flags-src
expect_contains "flags: ignored lists the hidden file" "$CLI_OUT" ".secret.txt"

# --- fork-free import planning ----------------------------------------------
# account_import_general is read with ${ ...;} inside the settings block, and
# account_import_build_plan calls the block builders from this shell, so a
# stubbed counter survives (the old $(...) forms lost it in a subshell).
# shellcheck source=../../lib/commands/account.sh
# shellcheck disable=SC1090,SC1091
source "${PROJ}/lib/commands/account.sh"
fork_general_calls=0
# shellcheck disable=SC2329  # counted while account_import_settings_block runs
account_import_general() {
  fork_general_calls=$((fork_general_calls + 1))
  printf '%s' "${IMPORT_GENERAL[${1:-}]:-}"
}
IMPORT_GENERAL=(
  [chunkSize]=10000000 [minChunkSize]=5000000 [maxChunkSize]=100000000
  [timeout]=300 [moveToTrash]=true [promptDeleteAllFiles]=false
  [deleteFilesThreshold]=100 [launchOnSystemStartup]=true
  [newBigFolderSizeLimit]=500 [logDebug]=1
)
account_import_settings_block 0 >"${TMP}/settings-block.out"
expect_eq "import: settings block reads every general key in this shell" "10" "$fork_general_calls"
expect_contains "import: settings block still maps chunkSize" \
  "$(cat "${TMP}/settings-block.out")" 'CHUNK_SIZE="10000000"'

fork_settings_calls=0
fork_pairs_calls=0
# shellcheck disable=SC2329  # counted while account_import_build_plan runs
account_import_settings_block() {
  fork_settings_calls=$((fork_settings_calls + 1))
  printf 'K="1"\n'
}
# shellcheck disable=SC2329  # counted while account_import_build_plan runs
account_import_pairs_block() {
  fork_pairs_calls=$((fork_pairs_calls + 1))
  printf 'l\t.\t\t\n'
}
# shellcheck disable=SC2329  # stub keeps the plan off the manifests
account_import_target_blocked() { return 1; }
IMPORT_SELECTED=$'0\n'
IMPORT_TARGET_NAMES=([0]=default)
IMPORT_ACCOUNT_USER=()
IMPORT_ACCOUNT_URL=()
account_import_build_plan >"${TMP}/build-plan.out"
expect_eq "import: build plan calls the settings block in this shell" "1" "$fork_settings_calls"
expect_eq "import: build plan calls the pairs block in this shell" "1" "$fork_pairs_calls"

finish
