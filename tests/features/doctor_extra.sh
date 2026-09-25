#!/usr/bin/env bash
# doctor_extra.sh - the added doctor checks: --json output, proxy, network,
# the MIN_FREE_SPACE/FREE_SPACE_DOWNLOAD free-space check, and the
# desktop-parity policy reports (policy summary, name hygiene messages, case
# clashes, E2EE/external storage, the delete guard, and big folders).
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../fake_env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../fake_env.sh"

# --- text report keeps the pre-existing checks ------------------------------
capture run_cli doctor --offline
expect_contains "doctor text: rclone config check" "$CLI_OUT" "rclone config file exists"
expect_contains "doctor text: remote listed check" "$CLI_OUT" "is listed in the rclone config"
expect_contains "doctor text: state dir check" "$CLI_OUT" "state dir is writable (${STATE_DIR})"
expect_eq "doctor text: no write-test probe left in state dir" "" \
  "$(find "$STATE_DIR" -maxdepth 1 -name '.doctor-write-test*' -print 2>/dev/null)"
expect_contains "doctor text: filter validation check" "$CLI_OUT" "rclone filter validation passed"
expect_contains "doctor text: conflict check" "$CLI_OUT" "no conflict copies found in local trees"
expect_contains "doctor text: keychain backend check" "$CLI_OUT" "keychain backend:"
expect_contains "doctor text: offline notice" "$CLI_OUT" "offline mode: skipping network checks"
expect_contains "doctor text: summary line" "$CLI_OUT" "passed,"
expect_not_contains "doctor text: not a JSON document" "$CLI_OUT" '"checks"'

# --- global flags driven by the shared table --------------------------------
# --log-dir/--log-expire surface through `cleanup --logs`; --confdir surfaces
# through `config check` naming the settings file it loaded. Both --flag VALUE
# and --flag=VALUE must work, and a global may follow the command.
GLOBAL_LOG_DIR="${TMP}/global-logs"
GLOBAL_CONF_DIR="${TMP}/global-conf"
capture run_cli --log-dir "$GLOBAL_LOG_DIR" cleanup --logs
expect_contains "global --log-dir: log dir redirected" "$CLI_OUT" "scanning ${GLOBAL_LOG_DIR} for '*.log'"
capture run_cli --log-dir="$GLOBAL_LOG_DIR" cleanup --logs
expect_contains "global --log-dir=: log dir redirected" "$CLI_OUT" "scanning ${GLOBAL_LOG_DIR} for '*.log'"
capture run_cli --log-expire 5 cleanup --logs
expect_contains "global --log-expire: expiry named" "$CLI_OUT" "older than 5 hour(s)"
capture run_cli --log-expire=2 cleanup --logs
expect_contains "global --log-expire=: expiry named" "$CLI_OUT" "older than 2 hour(s)"
capture run_cli --confdir="$GLOBAL_CONF_DIR" config check
expect_contains "global --confdir=: settings base changed" "$CLI_OUT" "settings loaded and validated (${GLOBAL_CONF_DIR}/settings.env)"
capture run_cli --confdir "$GLOBAL_CONF_DIR" config check
expect_contains "global --confdir: settings base changed" "$CLI_OUT" "settings loaded and validated (${GLOBAL_CONF_DIR}/settings.env)"
capture run_cli list --log-dir "$GLOBAL_LOG_DIR"
expect_rc "global: flag after the command is still consumed" "$CLI_RC" 0
capture run_cli --log-dir
expect_rc "global --log-dir: missing value rc 2" "$CLI_RC" 2
expect_contains "global --log-dir: missing value message" "$CLI_OUT" "sciebo: --log-dir requires a value"
capture run_cli --confdir
expect_rc "global --confdir: missing value rc 2" "$CLI_RC" 2
expect_contains "global --confdir: missing value message" "$CLI_OUT" "sciebo: --confdir requires a value"

# --- --json emits only the JSON document ------------------------------------
capture run_cli doctor --offline --json
if [[ "$CLI_RC" -eq 0 || "$CLI_RC" -eq 1 ]]; then
  pass "doctor --json: rc 0 or 1"
else
  fail "doctor --json: rc 0 or 1" "rc ${CLI_RC}: ${CLI_OUT}"
fi
expect_contains "doctor --json: checks array" "$CLI_OUT" '"checks"'
expect_contains "doctor --json: proxy check" "$CLI_OUT" '"name": "proxy"'
expect_contains "doctor --json: network check" "$CLI_OUT" '"name": "network"'
expect_contains "doctor --json: free space check" "$CLI_OUT" '"name": "free space"'
expect_contains "doctor --json: status field" "$CLI_OUT" '"status": "PASS"'

# --- a huge MIN_FREE_SPACE fails the free-space check and the run -----------
export MIN_FREE_SPACE=999999T
capture run_cli doctor --offline --json
expect_rc "doctor --json: huge MIN_FREE_SPACE rc 1" "$CLI_RC" 1
free_record="$(printf '%s\n' "$CLI_OUT" | awk '/"name": "free space"/ { getline; print; exit }')"
expect_contains "doctor --json: free space check FAILs below MIN_FREE_SPACE" "$free_record" '"status": "FAIL"'
unset MIN_FREE_SPACE

# --- cached capabilities, watch pid, and server exclude list ----------------
mkdir -p "${STATE_DIR}/watch"
{
  printf 'CAP_VERSION=31.0.2\n'
  printf 'CAP_BIGFILE_CHUNKING=true\n'
  printf 'CAP_CHUNK_MAX_SIZE=104857600\n'
  printf 'CAP_UNDELETE=true\n'
  printf 'CAP_CHECKSUMS=true\n'
  printf 'CAP_PROBED_AT=%s\n' "$(date +%s)"
} >"${STATE_DIR}/capabilities.env"
printf '{"ocs":{"data":{"capabilities":{"files":{"end-to-end-encryption":{"enabled":true}}}}}}\n' \
  >"${STATE_DIR}/capabilities.json"
capture run_cli doctor --offline
expect_contains "doctor: E2EE capability warned" "$CLI_OUT" \
  "server has end-to-end encryption enabled"

printf '999999\nbogus start time\n' >"${STATE_DIR}/watch/watch.pid"
capture run_cli doctor --offline
expect_contains "doctor: stale watcher record warned" "$CLI_OUT" "stale watcher record"
rm -f "${STATE_DIR}/watch/watch.pid"

export FILTER_SERVER_SYNC=1
capture run_cli doctor --offline
expect_contains "doctor: missing server exclude list warned" "$CLI_OUT" "server exclude list missing"
expect_contains "doctor: missing server exclude list hint" "$CLI_OUT" "filters sync"
touch "${STATE_DIR}/sync-exclude.lst"
capture run_cli doctor --offline
expect_contains "doctor: fresh server exclude list passes" "$CLI_OUT" "server exclude list is fresh"
unset FILTER_SERVER_SYNC

# --- the desktop-parity policy summary (text and --json) ---------------------
unset INVALID_NAME_POLICY CASE_CLASH_POLICY E2EE_POLICY EXTERNAL_STORAGE_POLICY \
  SYMLINK_POLICY CHECKSUM MOVE_TO_TRASH ASK_DELETE MAX_DELETE DELETE_FILES_THRESHOLD BIG_FOLDER_SIZE
capture run_cli doctor --offline
expect_contains "doctor policies: summary line" "$CLI_OUT" "policies: invalid names=exclude"
expect_contains "doctor policies: case clashes value" "$CLI_OUT" "case clashes=exclude"
expect_contains "doctor policies: E2EE value" "$CLI_OUT" "E2EE=exclude"
expect_contains "doctor policies: external storage value" "$CLI_OUT" "external storage=ask"
expect_contains "doctor policies: symlinks value" "$CLI_OUT" "symlinks=skip"
expect_contains "doctor policies: checksum value" "$CLI_OUT" "checksum=off"
expect_contains "doctor policies: trash value" "$CLI_OUT" "trash=off"
expect_contains "doctor policies: delete guard value" "$CLI_OUT" "delete guard=on (threshold 100)"
capture run_cli doctor --offline --json
expect_contains "doctor --json: policies object" "$CLI_OUT" '"policies": {'
expect_contains "doctor --json: policies invalid name value" "$CLI_OUT" '"invalid_names": "exclude"'
expect_contains "doctor --json: name hygiene object" "$CLI_OUT" '"name_hygiene": {'
expect_contains "doctor --json: name hygiene policy value" "$CLI_OUT" '"policy": "exclude"'
expect_contains "doctor --json: case clashes object" "$CLI_OUT" '"case_clashes": {'
expect_contains "doctor --json: e2ee object" "$CLI_OUT" '"e2ee": {'
expect_contains "doctor --json: external object" "$CLI_OUT" '"external": {'
expect_contains "doctor --json: delete guard object" "$CLI_OUT" '"delete_guard": {'
expect_contains "doctor --json: delete guard threshold" "$CLI_OUT" '"threshold": 100'
expect_contains "doctor --json: big folders object" "$CLI_OUT" '"big_folders": {'

# --- the name-hygiene message follows INVALID_NAME_POLICY --------------------
HYG_SRC="${TMP}/doctor-hygiene"
mkdir -p "$HYG_SRC"
: >"${HYG_SRC}/bad:name.txt"
printf 'sync|%s|doctor-hygiene\n' "$HYG_SRC" >"$MANIFEST_FILE"
export INVALID_NAME_POLICY=warn
capture run_cli doctor --offline
expect_contains "name hygiene: warn policy stated" "$CLI_OUT" "INVALID_NAME_POLICY=warn"
expect_contains "name hygiene: warn action stated" "$CLI_OUT" "warned and synced"
capture run_cli doctor --offline --json
expect_contains "name hygiene --json: policy override recorded" "$CLI_OUT" '"policy": "warn"'
export INVALID_NAME_POLICY=allow
capture run_cli doctor --offline
expect_contains "name hygiene: allow policy stated" "$CLI_OUT" "INVALID_NAME_POLICY=allow"
expect_contains "name hygiene: allow action stated" "$CLI_OUT" "synced as-is"
unset INVALID_NAME_POLICY
capture run_cli doctor --offline
expect_contains "name hygiene: exclude policy stated" "$CLI_OUT" "INVALID_NAME_POLICY=exclude"
expect_contains "name hygiene: exclude action stated" "$CLI_OUT" "excluded from sync/pull"

# --- case clashes ------------------------------------------------------------
# A real same-directory collision needs a case-sensitive filesystem; the
# macOS default is case-insensitive, so the real tree runs only where mkdir
# can create both spellings. The fallback drives doctor_check_case_clashes
# with a pinned collision list (policies.sh already covers the real
# policy_case_clashes scan end to end on a case-sensitive scratch volume).
CC_PROBE="${TMP}/case-probe"
mkdir -p "$CC_PROBE"
if mkdir "${CC_PROBE}/File" 2>/dev/null && mkdir "${CC_PROBE}/file" 2>/dev/null; then
  CC_SRC="${TMP}/doctor-case"
  mkdir -p "${CC_SRC}/Dir"
  printf 'upper' >"${CC_SRC}/Dir/File.txt"
  printf 'lower' >"${CC_SRC}/Dir/file.txt"
  printf 'sync|%s|doctor-case\n' "$CC_SRC" >"$MANIFEST_FILE"
  export CASE_CLASH_POLICY=warn
  capture run_cli doctor --offline
  expect_contains "case clashes: collision reported" "$CLI_OUT" "case clashes: 1 case-only collision(s)"
  expect_contains "case clashes: policy reported" "$CLI_OUT" "CASE_CLASH_POLICY=warn"
  unset CASE_CLASH_POLICY
else
  cat >"${TMP}/case-probe.sh" <<'PROBE'
#!/bin/bash
set -uo pipefail
source "$1/lib/sciebo.sh"
source "$1/lib/commands/doctor.sh"
DOCTOR_JSON=0
DOCTOR_OFFLINE=1
DOCTOR_ENTRIES="sync|/tmp|probe|probe"$'\n'
policy_case_clashes() { printf 'A/clash/X.TXT\ta/Clash/x.txt\n'; }
doctor_check_case_clashes
printf 'PAIRS=%s\n' "$DOCTOR_CASE_CLASHES"
# Nothing allocates the case-cache directory in this probe (allocation is
# lazy and policy_case_clashes is stubbed above), but run the CLI's cleanup
# anyway so the probe keeps mirroring a bin/sciebo process.
sciebo_temp_cleanup || true
PROBE
  cc_out="$(bash "${TMP}/case-probe.sh" "$PROJ" 2>&1)"
  expect_contains "case clashes: stub collision reported" "$cc_out" "case clashes: 1 case-only collision(s)"
  expect_contains "case clashes: stub policy reported" "$cc_out" "CASE_CLASH_POLICY=exclude"
  expect_contains "case clashes: stub pair recorded" "$cc_out" "PAIRS=A/clash/X.TXT"
fi
rm -rf "$CC_PROBE"

# --- doctor_each_entry: the shared DOCTOR_ENTRIES walk -----------------------
# The per-check loops now share one callback walk; it must visit each valid
# row in order with mode/local/remote/name plus the extra args, skip rows
# without a mode, and run in the caller's shell so a callback can update the
# caller's counters.
cat >"${TMP}/doctor-each-probe.sh" <<'PROBE'
#!/bin/bash
set -uo pipefail
source "$1/lib/sciebo.sh"
source "$1/lib/commands/doctor.sh"
DOCTOR_JSON=0
DOCTOR_OFFLINE=1
seen=0
doctor_probe_entry() {
  local mode="$1" local_path="$2" remote="$3" name="$4" extra="${5:-}"
  seen=$((seen + 1))
  printf 'ROW=%s|%s|%s|%s|%s\n' "$mode" "$local_path" "$remote" "$name" "$extra"
  return 0
}
DOCTOR_ENTRIES=$'sync|/tmp/a|remote-a|name-a\n\n|||\npull|/tmp/b|remote-b|name-b\n'
doctor_each_entry doctor_probe_entry EXTRA
printf 'SEEN=%s\n' "$seen"
sciebo_temp_cleanup || true
PROBE
deach_out="$(bash "${TMP}/doctor-each-probe.sh" "$PROJ" 2>&1)"
expect_contains "doctor_each_entry: visits the first row in order" "$deach_out" "ROW=sync|/tmp/a|remote-a|name-a|EXTRA"
expect_contains "doctor_each_entry: visits the last row in order" "$deach_out" "ROW=pull|/tmp/b|remote-b|name-b|EXTRA"
expect_not_contains "doctor_each_entry: skips rows without a mode" "$deach_out" "ROW=||||EXTRA"
expect_contains "doctor_each_entry: callback updates the caller counter" "$deach_out" "SEEN=2"

# --- E2EE and external storage with stubbed DAV responses --------------------
# The stub serves PROPFIND bodies that expose nc:is-encrypted and
# oc:permissions, so the WARN paths run without a server; the fake-server
# section below covers the PASS path when the properties are absent.
E2EE_LOCAL="${TMP}/e2ee-local"
EXT_LOCAL="${TMP}/ext-local"
mkdir -p "$E2EE_LOCAL" "$EXT_LOCAL"
printf 'sync|%s|e2ee-src\nsync|%s|external-src\n' "$E2EE_LOCAL" "$EXT_LOCAL" >"$MANIFEST_FILE"
stub_reset_routes
stub_route PROPFIND "*e2ee-src*" <<'XML'
<d:multistatus xmlns:d="DAV:" xmlns:nc="http://nextcloud.org/ns" xmlns:oc="http://owncloud.org/ns">
  <d:response>
    <d:href>/remote.php/dav/files/alice/backup/e2ee-src/</d:href>
    <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype><nc:is-encrypted>1</nc:is-encrypted><oc:permissions>RGDNVCK</oc:permissions></d:prop></d:propstat>
  </d:response>
</d:multistatus>
XML
stub_route PROPFIND "*external-src*" <<'XML'
<d:multistatus xmlns:d="DAV:" xmlns:nc="http://nextcloud.org/ns" xmlns:oc="http://owncloud.org/ns">
  <d:response>
    <d:href>/remote.php/dav/files/alice/backup/external-src/</d:href>
    <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype><nc:is-encrypted>0</nc:is-encrypted><oc:permissions>MKG</oc:permissions></d:prop></d:propstat>
  </d:response>
</d:multistatus>
XML
capture run_cli_nc doctor
expect_contains "doctor e2ee: encrypted folder warned" "$CLI_OUT" "end-to-end encrypted folder(s)"
expect_contains "doctor e2ee: names the folder" "$CLI_OUT" "'e2ee-src'"
expect_contains "doctor e2ee: policy reported" "$CLI_OUT" "E2EE_POLICY=exclude"
expect_contains "doctor external: mount warned" "$CLI_OUT" "mounted external storage(s)"
expect_contains "doctor external: names the mount" "$CLI_OUT" "'external-src'"
expect_contains "doctor external: policy reported" "$CLI_OUT" "EXTERNAL_STORAGE_POLICY=ask"
capture run_cli_nc doctor --json
expect_contains "doctor --json: e2ee path recorded" "$CLI_OUT" '"e2ee-src"'
expect_contains "doctor --json: external path recorded" "$CLI_OUT" '"external-src"'

# The shared remote-path engine feeds doctor's collection: two sources with
# one and two encrypted folders give two checked sources and three paths.
cat >"${TMP}/doctor-engine-probe.sh" <<'PROBE'
#!/bin/bash
set -uo pipefail
source "$1/lib/sciebo.sh"
source "$1/lib/commands/doctor.sh"
DOCTOR_JSON=0
DOCTOR_OFFLINE=0
DOCTOR_LINES=""
DOCTOR_PASS_COUNT=0 DOCTOR_WARN_COUNT=0 DOCTOR_FAIL_COUNT=0
DOCTOR_ENTRIES="pull|/tmp|backup/one|one"$'\n'"pull|/tmp|backup/two|two"$'\n'
remote_configured() { return 0; }
doctor_remote_is_nextcloud() { return 0; }
nc_e2ee_paths() {
  case "$1" in
    backup/one) printf 'backup/one/secret\n' ;;
    backup/two) printf 'backup/two/a\nbackup/two/b\n' ;;
  esac
}
doctor_check_e2ee_paths >/dev/null
printf 'CHECKED=%s\nPATHS=%s\n' "$DOCTOR_E2EE_CHECKED" "$DOCTOR_E2EE_PATHS"
sciebo_temp_cleanup || true
PROBE
de_out="$(bash "${TMP}/doctor-engine-probe.sh" "$PROJ" 2>&1)"
expect_contains "doctor engine: counts both checked sources" "$de_out" "CHECKED=2"
expect_contains "doctor engine: collects the first source path" "$de_out" "backup/one/secret"
expect_contains "doctor engine: collects the second source last path" "$de_out" "backup/two/b"

# --- offline E2EE/external checks print the policy only ----------------------
capture run_cli doctor --offline
expect_contains "doctor e2ee: offline prints the policy" "$CLI_OUT" "e2ee: E2EE_POLICY=exclude (offline"
expect_contains "doctor external: offline prints the policy" "$CLI_OUT" "external storage: EXTERNAL_STORAGE_POLICY=ask (offline"

# --- delete guard: threshold, ASK_DELETE, and the MAX_DELETE override --------
export ASK_DELETE=1 MAX_DELETE=-1 DELETE_FILES_THRESHOLD=7
capture run_cli doctor --offline
expect_contains "delete guard: custom threshold named" "$CLI_OUT" "DELETE_FILES_THRESHOLD=7"
expect_contains "delete guard: guard active" "$CLI_OUT" "runs stop after 7 deletion(s)"
export MAX_DELETE=5
capture run_cli doctor --offline
expect_contains "delete guard: MAX_DELETE named" "$CLI_OUT" "MAX_DELETE=5"
expect_contains "delete guard: override stated" "$CLI_OUT" "explicit cap overrides"
export ASK_DELETE=0
unset MAX_DELETE
capture run_cli doctor --offline
expect_contains "delete guard: ASK_DELETE=0 reported" "$CLI_OUT" "ASK_DELETE=0"
unset ASK_DELETE DELETE_FILES_THRESHOLD
capture run_cli doctor --offline --json
expect_contains "delete guard --json: ask default" "$CLI_OUT" '"ask": true'
expect_contains "delete guard --json: unlimited max_delete" "$CLI_OUT" '"max_delete": -1'

# --- quota warning: doctor report against a stub rclone ----------------------
# The shared lib/sync/quota.sh helpers parse `rclone about --json`; doctor
# reports WARN at or above QUOTA_WARN_PERCENT, PASS below, and stays silent
# when the setting is off. A stub rclone binary answers the probe.
QUOTA_STUB="${TMP}/doctor-quota-bin"
mkdir -p "$QUOTA_STUB"
cat >"${QUOTA_STUB}/rclone" <<'STUB'
#!/bin/bash
printf '{"total":1000,"used":950}\n'
exit 0
STUB
chmod +x "${QUOTA_STUB}/rclone"
cat >"${TMP}/doctor-quota-probe.sh" <<'PROBE'
#!/bin/bash
set -uo pipefail
source "$1/lib/sciebo.sh"
source "$1/lib/commands/doctor.sh"
DOCTOR_JSON=0
DOCTOR_OFFLINE=0
DOCTOR_LINES=""
DOCTOR_PASS_COUNT=0 DOCTOR_WARN_COUNT=0 DOCTOR_FAIL_COUNT=0
RCLONE_BIN="$2"
RCLONE_REMOTE="stub"
RCLONE_CONFIG="$3"
QUOTA_WARN_PERCENT="${4:-90}"
QUOTA_STATUS=""
QUOTA_TOTAL=""
QUOTA_USED=""
doctor_check_quota
sciebo_temp_cleanup || true
PROBE

quota_out="$(bash "${TMP}/doctor-quota-probe.sh" "$PROJ" "${QUOTA_STUB}/rclone" "${RCLONE_CONFIG}" 90 2>&1)"
expect_contains "doctor quota: at/over threshold warns" "$quota_out" "quota: 95% of stub: used"
expect_contains "doctor quota: threshold named" "$quota_out" "QUOTA_WARN_PERCENT=90"
quota_out="$(bash "${TMP}/doctor-quota-probe.sh" "$PROJ" "${QUOTA_STUB}/rclone" "${RCLONE_CONFIG}" 96 2>&1)"
expect_contains "doctor quota: below threshold passes" "$quota_out" "below QUOTA_WARN_PERCENT=96"
quota_out="$(bash "${TMP}/doctor-quota-probe.sh" "$PROJ" "${QUOTA_STUB}/rclone" "${RCLONE_CONFIG}" 0 2>&1)"
expect_not_contains "doctor quota: off is silent" "$quota_out" "quota:"

# The runtime quota line and doctor_check_quota share one `rclone about --json`
# probe: with QUOTA_WARN_PERCENT on, doctor_check_runtime runs it once and
# doctor_check_quota reports the cached bytes without a second network call.
cat >"${TMP}/doctor-quota-shared-probe.sh" <<'PROBE'
#!/bin/bash
set -uo pipefail
source "$1/lib/sciebo.sh"
source "$1/lib/commands/doctor.sh"
DOCTOR_JSON=0
DOCTOR_OFFLINE=0
DOCTOR_LINES=""
DOCTOR_PASS_COUNT=0 DOCTOR_WARN_COUNT=0 DOCTOR_FAIL_COUNT=0
RCLONE_BIN="$(command -v true)"
RCLONE_REMOTE="stub"
RCLONE_CONFIG="$2"
ABOUT_LOG="$3"
QUOTA_WARN_PERCENT="${4:-90}"
QUOTA_STATUS=""
QUOTA_TOTAL=""
QUOTA_USED=""
platform_scheduler_backend() { printf ''; }
rclone_cmd() {
  case "$1" in
    about)
      printf 'about\n' >>"$ABOUT_LOG"
      printf '{"total":1000,"used":950}\n'
      ;;
  esac
  return 0
}
doctor_check_runtime
doctor_check_quota
printf 'ABOUT_CALLS=%s\n' "$(wc -l <"$ABOUT_LOG" | tr -d ' ')"
sciebo_temp_cleanup || true
PROBE
: >"${TMP}/doctor-quota-shared.log"
shared_out="$(bash "${TMP}/doctor-quota-shared-probe.sh" "$PROJ" "${RCLONE_CONFIG}" "${TMP}/doctor-quota-shared.log" 90 2>&1)"
expect_contains "doctor shared quota: runtime quota line" "$shared_out" "quota info available (rclone about)"
expect_contains "doctor shared quota: quota line" "$shared_out" "quota: 95% of stub: used"
expect_contains "doctor shared quota: one probe backs both lines" "$shared_out" "ABOUT_CALLS=1"

# A missing rclone online stops doctor_check_runtime at the reachability stage
# (quota/launchd skipped, as before) but must NOT abort the command: cmd_doctor
# runs under errexit, so a non-zero return here would cut the checklist before
# its later stages and the pass/warn/fail summary. Run the stage under `set -e`
# with an unmistakably absent rclone and require the caller to survive.
cat >"${TMP}/doctor-runtime-nonfatal-probe.sh" <<'PROBE'
#!/bin/bash
set -euo pipefail
source "$1/lib/sciebo.sh"
source "$1/lib/commands/doctor.sh"
DOCTOR_JSON=0
DOCTOR_OFFLINE=0
DOCTOR_LINES=""
DOCTOR_PASS_COUNT=0 DOCTOR_WARN_COUNT=0 DOCTOR_FAIL_COUNT=0
RCLONE_BIN="$1/no-such-rclone-binary"
RCLONE_REMOTE="stub"
RCLONE_CONFIG="$2"
platform_scheduler_backend() { printf ''; }
doctor_check_runtime
printf 'RUNTIME_CONTINUED\n'
PROBE
runtime_out="$(bash "${TMP}/doctor-runtime-nonfatal-probe.sh" "$PROJ" "${RCLONE_CONFIG}" 2>&1)"
runtime_rc=$?
expect_eq "doctor runtime: missing rclone does not abort under errexit" "0" "$runtime_rc"
expect_contains "doctor runtime: continues past a missing rclone" "$runtime_out" "RUNTIME_CONTINUED"

# --- big folders: BIG_FOLDER_SIZE against a small local remote ---------------
BIG_LOCAL="${TMP}/big-local"
BIG_REMOTE="${TMP}/backup/big-src"
mkdir -p "$BIG_LOCAL" "$BIG_REMOTE"
printf 'x' >"$BIG_LOCAL/file.txt"
printf 'small' >"${BIG_REMOTE}/data.txt"
printf 'sync|%s|big-src\n' "$BIG_LOCAL" >"$MANIFEST_FILE"
unset BIG_FOLDER_SIZE
capture run_cli doctor --offline
expect_not_contains "big folders: silent when BIG_FOLDER_SIZE is empty" "$CLI_OUT" "big folders:"
export BIG_FOLDER_SIZE=1G
capture run_cli doctor
expect_contains "big folders: below the limit passes" "$CLI_OUT" "below BIG_FOLDER_SIZE=1G"
export BIG_FOLDER_SIZE=1
capture run_cli doctor
expect_contains "big folders: over the limit warned" "$CLI_OUT" "over BIG_FOLDER_SIZE=1"
expect_contains "big folders: policy reported" "$CLI_OUT" "BIG_FOLDER_EXISTING_POLICY=warn"

# A source whose size cannot be read is skipped, not counted as measured.
printf 'sync|%s|missing-src\n' "${TMP}/missing-local" >"$MANIFEST_FILE"
capture run_cli doctor
expect_contains "big folders: unreadable source skipped" "$CLI_OUT" "no sources measured"
unset BIG_FOLDER_SIZE
capture run_cli doctor --json
expect_contains "big folders --json: limit empty" "$CLI_OUT" '"limit": ""'

# --- E2EE/external against the fake server (properties absent: PASS) ---------
if fake_server_start; then
  mkdir -p "${FAKE_STATE}/backup/doctor-fake" "${TMP}/fake-local"
  printf 'sync|%s|doctor-fake\n' "${TMP}/fake-local" >"$MANIFEST_FILE"
  capture fake_cli doctor
  expect_contains "doctor fake server: e2ee absent is a PASS" "$CLI_OUT" "no end-to-end encrypted folders"
  expect_contains "doctor fake server: external absent is a PASS" "$CLI_OUT" "no mounted external storages"
  fake_server_stop
  export RCLONE_REMOTE=testremote
else
  printf 'SKIP  doctor fake server: fake server unavailable\n'
fi

# --- capabilities rendering: exact rows for every CAP_* state ---------------
# capabilities_show (`server capabilities`) and doctor's cached summary share
# the capabilities table, so both must stay byte-identical across
# true/false/missing values. The cache is fresh (CAPABILITIES_MAX_AGE=86400),
# so neither command touches the network.
caps_rows() {
  local name="$1" version="$2" big="$3" chunk="$4" undelete="$5" checksums="$6"
  local want_show="$7" want_summary="$8" got_summary=""
  mkdir -p "$STATE_DIR"
  {
    printf 'CAP_VERSION=%s\n' "$version"
    printf 'CAP_BIGFILE_CHUNKING=%s\n' "$big"
    printf 'CAP_CHUNK_MAX_SIZE=%s\n' "$chunk"
    printf 'CAP_UNDELETE=%s\n' "$undelete"
    printf 'CAP_CHECKSUMS=%s\n' "$checksums"
    printf 'CAP_PROBED_AT=%s\n' "$(date +%s)"
  } >"${STATE_DIR}/capabilities.env"
  capture run_cli server capabilities
  expect_eq "capabilities show: ${name}" "$want_show" "$CLI_OUT"
  capture run_cli doctor --offline
  got_summary="$(printf '%s\n' "$CLI_OUT" | sed -n 's/^PASS  cached server capabilities: //p' | head -n 1)"
  expect_eq "doctor capabilities summary: ${name}" "$want_summary" "$got_summary"
}

caps_rows "all true" 31.0.2 true 104857600 true true \
  $'server: Nextcloud 31.0.2\nchunked uploads: enabled (max chunk 100Mi)\ntrashbin: available\nchecksums: available' \
  'Nextcloud 31.0.2, chunked uploads enabled (max chunk 100Mi), trashbin available, checksums available'
caps_rows "all false" 31.0.2 false "" false false \
  $'server: Nextcloud 31.0.2\nchunked uploads: disabled\ntrashbin: unavailable\nchecksums: unavailable' \
  'Nextcloud 31.0.2, chunked uploads disabled'
caps_rows "chunked without a max size" "" true "" true true \
  $'chunked uploads: enabled\ntrashbin: available\nchecksums: available' \
  'chunked uploads enabled, trashbin available, checksums available'
caps_rows "only trashbin unavailable" "" "" "" false "" \
  'trashbin: unavailable' \
  'response present'
caps_rows "nothing known" "" "" "" "" "" \
  'server capabilities: unknown (probe failed or not cached)' \
  'response present'

# The probed path (doctor_report_capabilities) renders the same facts.
mkdir -p "$STATE_DIR"
{
  printf 'CAP_VERSION=31.0.2\nCAP_BIGFILE_CHUNKING=true\nCAP_CHUNK_MAX_SIZE=104857600\nCAP_UNDELETE=true\nCAP_CHECKSUMS=true\nCAP_PROBED_AT=%s\n' "$(date +%s)"
} >"${STATE_DIR}/capabilities.env"
capture run_cli doctor
expect_contains "doctor probed capabilities: version row" "$CLI_OUT" "PASS  server is Nextcloud 31.0.2"
expect_contains "doctor probed capabilities: chunk row" "$CLI_OUT" "PASS  server supports chunked uploads (max chunk 100Mi)"
expect_contains "doctor probed capabilities: trashbin row" "$CLI_OUT" "PASS  server trashbin is available"
expect_contains "doctor probed capabilities: checksums row" "$CLI_OUT" "PASS  server checksums are available"
{
  printf 'CAP_VERSION=\nCAP_BIGFILE_CHUNKING=false\nCAP_CHUNK_MAX_SIZE=\nCAP_UNDELETE=false\nCAP_CHECKSUMS=false\nCAP_PROBED_AT=%s\n' "$(date +%s)"
} >"${STATE_DIR}/capabilities.env"
capture run_cli doctor
expect_contains "doctor probed capabilities: disabled chunk row" "$CLI_OUT" "PASS  server reports chunked uploads disabled"
expect_contains "doctor probed capabilities: unavailable trashbin row" "$CLI_OUT" "PASS  server reports trashbin unavailable"
expect_not_contains "doctor probed capabilities: no false checksum row" "$CLI_OUT" "server checksums"

# --- the merged local-tree walk: hygiene + conflict copies in one pass --------
# One find per manifest local dir now feeds both checks, so a single run must
# report the hostile name and the conflict copy together.
MERGED_SRC="${TMP}/doctor-merged"
mkdir -p "$MERGED_SRC"
: >"${MERGED_SRC}/bad:name.txt"
printf 'conflicted copy\n' >"${MERGED_SRC}/notes conflicted copy.txt"
printf 'sync|%s|doctor-merged\n' "$MERGED_SRC" >"$MANIFEST_FILE"
# Note: doctor rc is 1 throughout this suite (the harness's `testremote` is
# a local-type remote with no app password, both remote checks FAIL), so the
# assertions below target the merged-walk diagnostics, not the rc.
capture run_cli doctor --offline
expect_contains "doctor merged walk: hygiene still reports the hostile name" \
  "$CLI_OUT" "platform-invalid name(s)"
expect_contains "doctor merged walk: conflict copy counted in the same run" \
  "$CLI_OUT" "conflict copies: 1 found"
expect_contains "doctor merged walk: conflict sample is the relative path" \
  "$CLI_OUT" "'notes conflicted copy.txt'"

# The hygiene half stops at DOCTOR_NAME_SCAN_LIMIT, but the conflict count
# must keep covering the whole tree exactly like the pre-merge second walk.
export DOCTOR_NAME_SCAN_LIMIT=1
capture run_cli doctor --offline
expect_contains "doctor merged walk: scan limit still truncates hygiene" \
  "$CLI_OUT" "scan truncated at 1 paths"
expect_contains "doctor merged walk: conflict counted past the hygiene limit" \
  "$CLI_OUT" "conflict copies: 1 found"
unset DOCTOR_NAME_SCAN_LIMIT

# --- doctor_normalize_local memoization --------------------------------------
# A symlink swap between two calls proves the second call is served from
# DOCTOR_NORMALIZE_CACHE: resolving again would return .../norm-link instead
# of the first call's physical .../norm-real.
cat >"${TMP}/doctor-norm-probe.sh" <<'PROBE'
#!/bin/bash
set -uo pipefail
source "$1/lib/sciebo.sh"
source "$1/lib/commands/doctor.sh"
base="$2"
mkdir -p "${base}/norm-real"
ln -s "${base}/norm-real" "${base}/norm-link"
path="${base}/norm-link"
# Capture forkless, exactly like doctor_check_manifest_locals does, so the
# memo is written in THIS shell (a $( ... ) capture would prime a subshell).
first=${ doctor_normalize_local "$path";}
if [[ -n "${DOCTOR_NORMALIZE_CACHE[$path]+x}" ]]; then echo "PRIMED=1"; else echo "PRIMED=0"; fi
rm "${base}/norm-link"
mkdir "${base}/norm-link"
second=${ doctor_normalize_local "$path";}
printf 'FIRST=%s\nSECOND=%s\n' "$first" "$second"
sciebo_temp_cleanup || true
PROBE
rm -rf "${TMP}/doctor-norm"
norm_out="$(bash "${TMP}/doctor-norm-probe.sh" "$PROJ" "${TMP}/doctor-norm" 2>&1)"
expect_contains "doctor_normalize_local: first sighting primes the cache" "$norm_out" "PRIMED=1"
expect_eq "doctor_normalize_local: repeat call returns the cached value" \
  "$(printf '%s\n' "$norm_out" | sed -n 's/^FIRST=//p')" \
  "$(printf '%s\n' "$norm_out" | sed -n 's/^SECOND=//p')"

finish
