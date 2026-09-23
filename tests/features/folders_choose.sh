#!/usr/bin/env bash
# folders_choose.sh - `sciebo folders choose` policy gates: the pure
# policy decision, BIG_FOLDER_POLICY through the full wizard on the real
# local remote, the external-storage/E2EE gates with stubbed Nextcloud
# probes, and a live fake-server run proving missing properties proceed.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

# The wizard's policy helpers build on these libraries (env.sh has core.sh
# and http.sh already).
# shellcheck disable=SC1090,SC1091
source "${PROJ}/lib/rclone.sh"
# The direct label/gate assertions below call _bigfolder_label in this
# process and expect capabilities' human label ("2Ki"/"2Mi"). That used to
# arrive through folders_choose.sh's file-top require; the require moved
# into cmd_choose with the lazy-deps pass (so `--help` parses none of it),
# and the direct calls source capabilities.sh here instead. The CLI paths
# still load it through cmd_choose, never through a test-only pre-source.
# shellcheck disable=SC1090,SC1091
source "${PROJ}/lib/capabilities.sh"
# policy.sh backs the direct choose_policy_decision calls below; it loads in
# cmd_choose now (its file-top require moved with the lazy-deps pass), so the
# direct-call tests source it here.
# shellcheck disable=SC1090,SC1091
source "${PROJ}/lib/policy.sh"
# shellcheck disable=SC1090,SC1091
source "${PROJ}/lib/nc_api.sh"
# shellcheck disable=SC1090,SC1091
source "${PROJ}/lib/bigfolder.sh"
# shellcheck disable=SC1090,SC1091
source "${PROJ}/lib/ui.sh"
# shellcheck disable=SC1090,SC1091
source "${PROJ}/lib/commands/folders_choose.sh"

# choose_capture CMD... - combined output in CLI_OUT, rc in CLI_RC, with
# stdin closed so an "ask" gate cannot prompt.
choose_capture() {
  CLI_OUT="$("$@" </dev/null 2>&1)"
  CLI_RC=$?
}

# choose_cli INPUT ARGS... - run bin/sciebo in $TMP with INPUT on stdin
# (piped, so stdin is never a TTY and the ask policies take the
# non-interactive path); sets CLI_OUT/CLI_RC like capture.
choose_cli() {
  local input="$1"
  shift
  CLI_OUT="$(
    cd "$TMP" || exit 1
    printf '%b' "$input" | bash "${PROJ}/bin/sciebo" "$@" 2>&1
  )"
  CLI_RC=$?
}

# expect_choose NAME RC INPUT ARGS... - choose_cli plus an rc assertion.
expect_choose() {
  local name="$1" want="$2" input="$3"
  shift 3
  choose_cli "$input" "$@"
  expect_rc "$name" "$CLI_RC" "$want"
}

# --- pure decision: allow/warn proceed, skip/exclude skip, ask confirms ----
# decide POLICY CONFIRMED - "<output> <rc>" from choose_policy_decision.
decide() {
  local out="" rc=0
  out="$(choose_policy_decision "${1:-}" "${2:-0}")" || rc=$?
  printf '%s %s' "$out" "$rc"
}
expect_eq "decision: allow proceeds" "proceed 0" "$(decide allow 0)"
expect_eq "decision: warn proceeds" "proceed 0" "$(decide warn 0)"
expect_eq "decision: skip skips" "skip 2" "$(decide skip 0)"
expect_eq "decision: exclude skips" "skip 2" "$(decide exclude 0)"
expect_eq "decision: ask without confirmation skips" "skip 2" "$(decide ask 0)"
expect_eq "decision: ask confirmed proceeds" "proceed 0" "$(decide ask 1)"
expect_eq "decision: unset proceeds" "proceed 0" "$(decide "" 0)"
expect_eq "decision: unknown policy proceeds" "proceed 0" "$(decide nonsense 0)"

# --- sciebo_require_module / have_function / label dependency --------------
# have_function detects loaded helpers and rejects missing ones.
have_function _bigfolder_label
expect_rc "have_function: finds a loaded helper" "$?" 0
have_function choose_helper_that_does_not_exist
expect_rc "have_function: rejects a missing helper" "$?" 1

# sciebo_require_module is a clean no-op (rc 0) when the module is absent or
# unreadable: a genuinely optional dependency never aborts the caller, and its
# sentinel stays undefined.
CHOOSE_REQUIRE_DIR="${TMP}/require-modules"
mkdir -p "$CHOOSE_REQUIRE_DIR"
printf ':\n' >"${CHOOSE_REQUIRE_DIR}/unreadable_module.sh"
chmod 000 "${CHOOSE_REQUIRE_DIR}/unreadable_module.sh"
CHOOSE_SAVED_LIB_DIR="$LIB_DIR"
LIB_DIR="$CHOOSE_REQUIRE_DIR"
sciebo_require_module definitely_absent_module no_such_sentinel
expect_rc "require_module: absent module is a clean no-op" "$?" 0
sciebo_require_module unreadable_module no_such_sentinel
expect_rc "require_module: unreadable module is a clean no-op" "$?" 0
have_function no_such_sentinel
expect_rc "require_module: missing module defines no sentinel" "$?" 1
LIB_DIR="$CHOOSE_SAVED_LIB_DIR"

# _bigfolder_label prefers capabilities' human label and falls back to raw
# bytes. The human label appears because capabilities.sh is sourced above
# for the direct calls; the raw-bytes case unsets the helper (in the
# command-substitution subshell) to simulate capabilities being absent.
expect_eq "bigfolder label: raw bytes without capabilities" "2048B" \
  "$(
    unset -f capabilities_size_label
    _bigfolder_label 2048
  )"
expect_eq "bigfolder label: human label once capabilities is required" "2Ki" \
  "$(_bigfolder_label 2048)"

# choose_bigfolder_label's round-5 guard reports a genuinely missing helper
# instead of silently printing an empty size.
unset -f _bigfolder_label
choose_capture choose_bigfolder_label 2097152
expect_rc "choose_bigfolder_label: missing helper dies" "$CLI_RC" 1
expect_contains "choose_bigfolder_label: missing helper names it" "$CLI_OUT" "_bigfolder_label"
expect_not_contains "choose_bigfolder_label: never emits an empty size" "$CLI_OUT" "is  "
# shellcheck source=../../lib/bigfolder.sh
source "${PROJ}/lib/bigfolder.sh"

# --- choose_bigfolder_gate: bounded size, policy verdicts ------------------
# The direct calls need the derived remote prefix (load_settings does this
# for the CLI; it stays unexported so the subprocess wizard derives its own).
# shellcheck disable=SC2034  # read by remote_spec in the direct gate calls
REMOTE_PREFIX="${RCLONE_REMOTE}:${REMOTE_BASE}"
BIGFOLDER_STUB_BYTES=0
BIGFOLDER_CALLS="${TMP}/choose-bigfolder-calls.log"
# shellcheck disable=SC2329  # invoked indirectly by choose_remote_size
rclone_cmd() {
  printf '%s\n' "$*" >>"$BIGFOLDER_CALLS"
  [[ "${BIGFOLDER_STUB_FAIL:-0}" == "1" ]] && return 1
  printf '{"count":1,"bytes":%s,"sizeless":0}\n' "$BIGFOLDER_STUB_BYTES"
}
export BIG_FOLDER_SIZE=1Mi BIG_FOLDER_POLICY=skip
BIGFOLDER_STUB_BYTES=2097152
: >"$BIGFOLDER_CALLS"
choose_capture choose_bigfolder_gate bigpair
expect_rc "bigfolder gate: skip rc 2" "$CLI_RC" 2
expect_contains "bigfolder gate: skip warns" "$CLI_OUT" "big folder: 'bigpair' is 2Mi"
expect_contains "bigfolder gate: skip names the policy" "$CLI_OUT" "BIG_FOLDER_POLICY=skip"
expect_contains "bigfolder gate: skip names the size label" "$CLI_OUT" "big folder: 'bigpair' is 2Mi (limit 1Mi)"
expect_not_contains "bigfolder gate: skip leaks no command-not-found" "$CLI_OUT" "command not found"
expect_not_contains "bigfolder gate: skip leaks no raw helper name" "$CLI_OUT" "_bigfolder_label"
expect_eq "bigfolder gate: one bounded size lookup" "1" "$(wc -l <"$BIGFOLDER_CALLS" | tr -d ' ')"
expect_contains "bigfolder gate: lookup is scoped to the pair" "$(cat "$BIGFOLDER_CALLS")" "testremote:backup/bigpair/"

export BIG_FOLDER_POLICY=warn
choose_capture choose_bigfolder_gate bigpair
expect_rc "bigfolder gate: warn rc 0" "$CLI_RC" 0
expect_contains "bigfolder gate: warn adds anyway" "$CLI_OUT" "big folder: 'bigpair' is 2Mi"
expect_contains "bigfolder gate: warn names the policy" "$CLI_OUT" "adding anyway (BIG_FOLDER_POLICY=warn)"

export BIG_FOLDER_POLICY=ask
choose_capture choose_bigfolder_gate bigpair
expect_rc "bigfolder gate: ask without a TTY skips" "$CLI_RC" 2
expect_contains "bigfolder gate: ask skip names the policy" "$CLI_OUT" "skipping (BIG_FOLDER_POLICY=ask)"

export BIG_FOLDER_POLICY=skip
BIGFOLDER_STUB_BYTES=1024
choose_capture choose_bigfolder_gate smallpair
expect_rc "bigfolder gate: folder below the limit proceeds" "$CLI_RC" 0
expect_eq "bigfolder gate: folder below the limit is silent" "" "$CLI_OUT"

BIGFOLDER_STUB_BYTES=2097152
export BIG_FOLDER_SIZE=""
: >"$BIGFOLDER_CALLS"
choose_capture choose_bigfolder_gate bigpair
expect_rc "bigfolder gate: disabled setting proceeds" "$CLI_RC" 0
expect_eq "bigfolder gate: disabled setting does no size lookup" "" "$(cat "$BIGFOLDER_CALLS")"

# An unreadable size (rclone failure) must proceed silently: the gate never
# blocks on a missing measurement. The earlier bigpair measurement is dropped
# so the failing fetch is actually attempted.
BIGFOLDER_STUB_BYTES=2097152 BIGFOLDER_STUB_FAIL=1
export BIG_FOLDER_SIZE=1Mi BIG_FOLDER_POLICY=skip
CHOOSE_REMOTE_SIZE_CACHE=()
: >"$BIGFOLDER_CALLS"
choose_capture choose_bigfolder_gate bigpair
expect_rc "bigfolder gate: unreadable size proceeds" "$CLI_RC" 0
expect_eq "bigfolder gate: unreadable size is silent" "" "$CLI_OUT"
expect_eq "bigfolder gate: unreadable size still looked up" "1" "$(wc -l <"$BIGFOLDER_CALLS" | tr -d ' ')"
unset BIGFOLDER_STUB_FAIL

# A missing label helper (a broken/partial install the lazy require missed)
# must abort loudly instead of printing an empty size: the gate is reached
# through a `|| rc=$?`, so a bare `command not found` would be swallowed.
unset -f _bigfolder_label
BIGFOLDER_STUB_BYTES=2097152
export BIG_FOLDER_SIZE=1Mi BIG_FOLDER_POLICY=skip
choose_capture choose_bigfolder_gate bigpair
expect_rc "bigfolder gate: missing label helper fails" "$CLI_RC" 1
expect_contains "bigfolder gate: missing label helper names it" "$CLI_OUT" "_bigfolder_label"
expect_not_contains "bigfolder gate: missing label helper never empties the size" \
  "$CLI_OUT" "is  (limit"
# shellcheck source=../../lib/bigfolder.sh
source "${PROJ}/lib/bigfolder.sh"

# --- remote_dir_exists: one lsd per distinct spec per process ---------------
# The helper memoizes both positive and negative answers, so repeated checks
# of the same directory reuse the first probe for the life of the process.
CHOOSE_LSD_LOG="${TMP}/choose-lsd.log"
CHOOSE_LSD_RESULT=0
CHOOSE_SHARED_SIZE=0
CHOOSE_SHARED_CALLS="${TMP}/choose-shared-size.log"
# shellcheck disable=SC2329  # invoked indirectly by choose_remote_size
sync_remote_size_lookup() {
  printf '%s\n' "$1" >>"$CHOOSE_SHARED_CALLS"
  # shellcheck disable=SC2034  # read by choose_remote_size
  SYNC_REMOTE_SIZE_BYTES="$CHOOSE_SHARED_SIZE"
  return 0
}
# shellcheck disable=SC2329  # invoked indirectly by remote_dir_exists
rclone_cmd() {
  printf '%s\n' "$*" >>"$BIGFOLDER_CALLS"
  case "$1" in
    lsd) printf '%s\n' "$*" >>"$CHOOSE_LSD_LOG" ;;
    size) printf '{"count":1,"bytes":%s,"sizeless":0}\n' "$BIGFOLDER_STUB_BYTES" ;;
  esac
  return "$CHOOSE_LSD_RESULT"
}
# shellcheck disable=SC2034  # read by remote_dir_exists in lib/rclone.sh
REMOTE_DIR_EXISTS_CACHE=()
: >"$CHOOSE_LSD_LOG"
remote_dir_exists testremote:backup/a
expect_rc "remote_dir_exists: existing dir" "$?" 0
remote_dir_exists testremote:backup/a
expect_rc "remote_dir_exists: cached positive" "$?" 0
CHOOSE_LSD_RESULT=1
remote_dir_exists testremote:backup/b
expect_rc "remote_dir_exists: missing dir" "$?" 1
remote_dir_exists testremote:backup/b
expect_rc "remote_dir_exists: cached negative" "$?" 1
expect_eq "remote_dir_exists: one lsd per distinct spec" "2" \
  "$(wc -l <"$CHOOSE_LSD_LOG" | tr -d ' ')"
CHOOSE_LSD_RESULT=0

# choose_remote_size reuses sync's per-process size cache whenever that module
# is loaded, and falls back to the bounded rclone_remote_size otherwise.
: >"$CHOOSE_SHARED_CALLS"
CHOOSE_SHARED_SIZE=4242
expect_eq "choose_remote_size: routes through the shared lookup" "4242" \
  "$(choose_remote_size routedpair)"
expect_eq "choose_remote_size: scopes the shared lookup to the pair" \
  "testremote:backup/routedpair" "$(cat "$CHOOSE_SHARED_CALLS")"
unset -f sync_remote_size_lookup
BIGFOLDER_STUB_BYTES=4242
: >"$BIGFOLDER_CALLS"
expect_eq "choose_remote_size: falls back to the bounded lookup" "4242" \
  "$(choose_remote_size fallbackpair)"
expect_contains "choose_remote_size: fallback is the scoped rclone size" \
  "$(cat "$BIGFOLDER_CALLS")" "size --json testremote:backup/fallbackpair/"

# The fallback wraps the bounded lookup in a local per-run cache keyed by
# spec, so repeated gates for the same subtree re-fetch nothing. The calls
# deliberately avoid a command substitution so the cache survives in this
# shell (a subshell would drop it).
# shellcheck disable=SC2034  # read by choose_remote_size
CHOOSE_REMOTE_SIZE_CACHE=()
BIGFOLDER_STUB_BYTES=4242
: >"$BIGFOLDER_CALLS"
choose_remote_size cachedpair >/dev/null
expect_eq "choose_remote_size: fallback fills the per-run cache" "4242" \
  "$CHOOSE_REMOTE_SIZE_BYTES"
choose_remote_size cachedpair >/dev/null
expect_eq "choose_remote_size: fallback cache hit keeps the bytes" "4242" \
  "$CHOOSE_REMOTE_SIZE_BYTES"
expect_eq "choose_remote_size: fallback re-fetches only once per spec" "1" \
  "$(wc -l <"$BIGFOLDER_CALLS" | tr -d ' ')"

# --- choose_external_gate: allow/warn/ask/skip over stubbed probes ----------
NC_STUB_EXTERNAL_PATHS=""
# shellcheck disable=SC2329  # invoked indirectly by choose_external_gate
nc_external_paths() { printf '%s\n' "$NC_STUB_EXTERNAL_PATHS"; }
# shellcheck disable=SC2329  # invoked indirectly by choose_external_gate
remote_is_nextcloud() { return 0; }

export EXTERNAL_STORAGE_POLICY=skip
NC_STUB_EXTERNAL_PATHS=notes
choose_capture choose_external_gate notes
expect_rc "external gate: skip rc 2" "$CLI_RC" 2
expect_contains "external gate: skip warns" "$CLI_OUT" "external storage: 'notes'"
expect_contains "external gate: skip names the policy" "$CLI_OUT" "EXTERNAL_STORAGE_POLICY=skip"

export EXTERNAL_STORAGE_POLICY=warn
choose_capture choose_external_gate notes
expect_rc "external gate: warn rc 0" "$CLI_RC" 0
expect_contains "external gate: warn adds anyway" "$CLI_OUT" "adding anyway (EXTERNAL_STORAGE_POLICY=warn)"

export EXTERNAL_STORAGE_POLICY=ask
choose_capture choose_external_gate notes
expect_rc "external gate: ask without a TTY skips" "$CLI_RC" 2
expect_contains "external gate: ask skip names the policy" "$CLI_OUT" "skipping (EXTERNAL_STORAGE_POLICY=ask)"

export EXTERNAL_STORAGE_POLICY=allow
choose_capture choose_external_gate notes
expect_rc "external gate: allow rc 0" "$CLI_RC" 0
expect_eq "external gate: allow is silent" "" "$CLI_OUT"

# The chosen folder's parent is the mount: the child pair is gated too.
# shellcheck disable=SC2329  # invoked indirectly by choose_external_gate
nc_external_paths() {
  case "$1" in
    parent) printf 'parent\n' ;;
  esac
}
export EXTERNAL_STORAGE_POLICY=skip
choose_capture choose_external_gate parent/child
expect_rc "external gate: parent mount skips the child" "$CLI_RC" 2
expect_contains "external gate: parent mount warning names the pair" "$CLI_OUT" "'parent/child'"

# Only a child is mounted: the pair itself is fine and stays silent.
# shellcheck disable=SC2329  # invoked indirectly by choose_external_gate
nc_external_paths() { printf 'notes/child\n'; }
choose_capture choose_external_gate notes
expect_rc "external gate: external child only proceeds" "$CLI_RC" 0
expect_eq "external gate: external child only is silent" "" "$CLI_OUT"

# Missing property (older/other server): proceed silently.
NC_STUB_EXTERNAL_PATHS=""
# shellcheck disable=SC2329  # invoked indirectly by choose_external_gate
nc_external_paths() { printf '%s\n' "$NC_STUB_EXTERNAL_PATHS"; }
choose_capture choose_external_gate notes
expect_rc "external gate: missing property proceeds" "$CLI_RC" 0
expect_eq "external gate: missing property is silent" "" "$CLI_OUT"

# Other remotes never run the check.
# shellcheck disable=SC2329  # invoked indirectly by choose_external_gate
remote_is_nextcloud() { return 1; }
NC_STUB_EXTERNAL_PATHS=notes
choose_capture choose_external_gate notes
expect_rc "external gate: non-Nextcloud is a no-op" "$CLI_RC" 0
expect_eq "external gate: non-Nextcloud is silent" "" "$CLI_OUT"

# --- choose_e2ee_gate: allow/warn/exclude over stubbed probes --------------
NC_STUB_E2EE_PATHS=""
# shellcheck disable=SC2329  # invoked indirectly by choose_e2ee_gate
nc_e2ee_paths() { printf '%s\n' "$NC_STUB_E2EE_PATHS"; }
# shellcheck disable=SC2329  # invoked indirectly by choose_e2ee_gate
remote_is_nextcloud() { return 0; }

export E2EE_POLICY=exclude
NC_STUB_E2EE_PATHS=notes/secret
choose_capture choose_e2ee_gate notes/secret
expect_rc "e2ee gate: exclude rc 2" "$CLI_RC" 2
expect_contains "e2ee gate: exclude warns" "$CLI_OUT" "end-to-end encrypted"
expect_contains "e2ee gate: exclude explains the limitation" "$CLI_OUT" "cannot decrypt E2EE folders"
expect_contains "e2ee gate: exclude names the policy" "$CLI_OUT" "E2EE_POLICY=exclude"

export E2EE_POLICY=warn
choose_capture choose_e2ee_gate notes/secret
expect_rc "e2ee gate: warn rc 0" "$CLI_RC" 0
expect_contains "e2ee gate: warn adds anyway" "$CLI_OUT" "adding anyway (E2EE_POLICY=warn)"

export E2EE_POLICY=allow
choose_capture choose_e2ee_gate notes/secret
expect_rc "e2ee gate: allow rc 0" "$CLI_RC" 0
expect_eq "e2ee gate: allow is silent" "" "$CLI_OUT"

# The parent is encrypted: the child pair is gated.
# shellcheck disable=SC2329  # invoked indirectly by choose_e2ee_gate
nc_e2ee_paths() {
  case "$1" in
    parent) printf 'parent\n' ;;
  esac
}
export E2EE_POLICY=exclude
choose_capture choose_e2ee_gate parent/child
expect_rc "e2ee gate: parent root skips the child" "$CLI_RC" 2
expect_contains "e2ee gate: parent root warning names the pair" "$CLI_OUT" "'parent/child'"

# Only a child is encrypted: the pair proceeds; sync's own preflight
# excludes the encrypted child.
# shellcheck disable=SC2329  # invoked indirectly by choose_e2ee_gate
nc_e2ee_paths() { printf 'notes/secret\n'; }
choose_capture choose_e2ee_gate notes
expect_rc "e2ee gate: encrypted child only proceeds" "$CLI_RC" 0
expect_eq "e2ee gate: encrypted child only is silent" "" "$CLI_OUT"

# Missing property (older/other server): proceed silently.
NC_STUB_E2EE_PATHS=""
# shellcheck disable=SC2329  # invoked indirectly by choose_e2ee_gate
nc_e2ee_paths() { printf '%s\n' "$NC_STUB_E2EE_PATHS"; }
choose_capture choose_e2ee_gate notes
expect_rc "e2ee gate: missing property proceeds" "$CLI_RC" 0
expect_eq "e2ee gate: missing property is silent" "" "$CLI_OUT"

# shellcheck disable=SC2329  # invoked indirectly by choose_e2ee_gate
remote_is_nextcloud() { return 1; }
NC_STUB_E2EE_PATHS=notes
choose_capture choose_e2ee_gate notes
expect_rc "e2ee gate: non-Nextcloud is a no-op" "$CLI_RC" 0
expect_eq "e2ee gate: non-Nextcloud is silent" "" "$CLI_OUT"

# --- ask with a confirming answer proceeds (engine wizard path) -------------
# The engine resolves the scope first, then runs the caller's confirmation
# callback, so a confirming answer turns external ask into warn-and-proceed.
# shellcheck disable=SC2329  # invoked indirectly by choose_external_gate
remote_is_nextcloud() { return 0; }
# shellcheck disable=SC2329  # invoked indirectly by choose_external_gate
choose_policy_confirm_external() { return 0; }
export EXTERNAL_STORAGE_POLICY=ask
NC_STUB_EXTERNAL_PATHS=notes
choose_capture choose_external_gate notes
expect_rc "external gate: ask with confirmation proceeds" "$CLI_RC" 0
expect_contains "external gate: ask acceptance stated" "$CLI_OUT" "accepted (EXTERNAL_STORAGE_POLICY=ask)"
unset EXTERNAL_STORAGE_POLICY

# --- full wizard: BIG_FOLDER_POLICY gates what is written ------------------
# The real testremote local backend resolves below $TMP (the CLI runs with
# its cwd there), so a real `rclone size` drives the gate.
mkdir -p "${TMP}/backup/bigone" "${TMP}/backup/smallone" "${TMP}/backup/smalltwo"
dd if=/dev/zero of="${TMP}/backup/bigone/blob.bin" bs=1024 count=8 2>/dev/null
printf 'x' >"${TMP}/backup/smallone/file.txt"
printf 'y' >"${TMP}/backup/smalltwo/file.txt"

export BIG_FOLDER_SIZE=1Ki
export BIG_FOLDER_POLICY=skip
expect_choose "choose big skip: rc 0" 0 '1\n' \
  folders choose --no-fzf --no-dry-run --depth 1 --mode pull --local-root "${TMP}/big-skip"
expect_contains "choose big skip: warning names the folder" "$CLI_OUT" "big folder: 'bigone'"
expect_contains "choose big skip: warning names the size label" "$CLI_OUT" "big folder: 'bigone' is 8Ki"
expect_contains "choose big skip: warning names the limit" "$CLI_OUT" "(limit 1Ki)"
expect_contains "choose big skip: warning names the policy" "$CLI_OUT" "BIG_FOLDER_POLICY=skip"
expect_not_contains "choose big skip: no command-not-found leak" "$CLI_OUT" "command not found"
expect_not_contains "choose big skip: no raw helper name leak" "$CLI_OUT" "_bigfolder_label"
expect_contains "choose big skip: nothing added" "$CLI_OUT" "nothing to add"
expect_not_contains "choose big skip: folders.conf stays empty" "$(cat "$FOLDERS_FILE")" "bigone"

export BIG_FOLDER_POLICY=ask
expect_choose "choose big ask: rc 0" 0 '1\n' \
  folders choose --no-fzf --no-dry-run --depth 1 --mode pull --local-root "${TMP}/big-ask"
expect_contains "choose big ask: non-interactive skip" "$CLI_OUT" "skipping (BIG_FOLDER_POLICY=ask)"
expect_contains "choose big ask: skip names the size label" "$CLI_OUT" "big folder: 'bigone' is 8Ki"
expect_not_contains "choose big ask: nothing written" "$(cat "$FOLDERS_FILE")" "bigone"

export BIG_FOLDER_POLICY=warn
expect_choose "choose big warn: rc 0" 0 '1\n\nn\ny\n' \
  folders choose --no-fzf --no-dry-run --depth 1 --mode pull --local-root "${TMP}/big-warn"
expect_contains "choose big warn: warning kept" "$CLI_OUT" "adding anyway (BIG_FOLDER_POLICY=warn)"
expect_contains "choose big warn: warning names the size label" "$CLI_OUT" "big folder: 'bigone' is 8Ki"
expect_contains "choose big warn: pair written" "$(cat "$FOLDERS_FILE")" "pull|${TMP}/big-warn/bigone|bigone"

# Skipped pairs are not counted in the summary or the written file.
: >"$FOLDERS_FILE"
export BIG_FOLDER_POLICY=skip
expect_choose "choose big mixed: rc 0" 0 '1 2\n\nn\ny\n' \
  folders choose --no-fzf --no-dry-run --depth 1 --mode pull --local-root "${TMP}/big-mixed"
expect_contains "choose big mixed: only the small pair is counted" "$CLI_OUT" "Add these 1 pair(s)"
expect_contains "choose big mixed: small pair written" "$(cat "$FOLDERS_FILE")" "pull|${TMP}/big-mixed/smallone|smallone"
expect_not_contains "choose big mixed: skipped pair not written" "$(cat "$FOLDERS_FILE")" "bigone"

# --- the dry-run offer survives the new gate -------------------------------
: >"$FOLDERS_FILE"
unset BIG_FOLDER_SIZE
expect_choose "choose dry run: rc 0" 0 '1\n\nn\ny\nn\n' \
  folders choose --no-fzf --depth 1 --mode pull --local-root "${TMP}/dry-run"
expect_contains "choose dry run: offer shown" "$CLI_OUT" "Run a dry run for the new pairs now?"
: >"$FOLDERS_FILE"
expect_choose "choose no-dry-run: rc 0" 0 '1\n\nn\ny\n' \
  folders choose --no-fzf --no-dry-run --depth 1 --mode pull --local-root "${TMP}/no-dry-run"
expect_not_contains "choose no-dry-run: no offer" "$CLI_OUT" "Run a dry run for the new pairs now?"

# --- live fake Nextcloud: missing properties proceed silently --------------
if command -v python3 >/dev/null 2>&1; then
  # shellcheck source-path=SCRIPTDIR
  # shellcheck source=../fake_env.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../fake_env.sh"
  if fake_server_start; then
    mkdir -p "${FAKE_STATE}/backup/remote-plain/child"
    printf 'x' >"${FAKE_STATE}/backup/remote-plain/file.txt"

    # A forwarding curl shim logs every CLI HTTP request, so the test can
    # prove the external-storage and E2EE probes really queried the server
    # (rclone does its own HTTP and never uses curl). Both facts come from
    # one combined PROPFIND now, so one logged PROPFIND covers both gates.
    CHOOSE_REAL_CURL="$(PATH="$FAKE_PATH" command -v curl)"
    CHOOSE_CURL_BIN="${TMP}/choose-curl-bin"
    CHOOSE_CURL_LOG="${TMP}/choose-curl.log"
    mkdir -p "$CHOOSE_CURL_BIN"
    cat >"${CHOOSE_CURL_BIN}/curl" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"${CHOOSE_CURL_LOG}"
exec "${CHOOSE_REAL_CURL}" "$@"
STUB
    chmod +x "${CHOOSE_CURL_BIN}/curl"
    export CHOOSE_CURL_LOG CHOOSE_REAL_CURL

    # choose_fake INPUT ARGS... - wizard against the live fake server with
    # the logging curl first in PATH.
    choose_fake() {
      local input="$1"
      shift
      CLI_OUT="$(
        cd "$TMP" || exit 1
        printf '%b' "$input" | env PATH="${CHOOSE_CURL_BIN}:${FAKE_PATH}" \
          RCLONE_REMOTE="$FAKE_REMOTE" bash "${PROJ}/bin/sciebo" "$@" 2>&1
      )"
      CLI_RC=$?
    }

    : >"$CHOOSE_CURL_LOG"
    export BIG_FOLDER_SIZE="" EXTERNAL_STORAGE_POLICY=skip E2EE_POLICY=exclude
    choose_fake '1\n\nn\ny\n' folders choose --no-fzf --no-dry-run --depth 1 \
      --mode pull --local-root "${TMP}/fake-skip"
    expect_rc "choose nc skip: rc 0" "$CLI_RC" 0
    expect_contains "choose nc skip: pair written" "$(cat "$FOLDERS_FILE")" "|remote-plain"
    expect_not_contains "choose nc skip: no false external warning" "$CLI_OUT" "external storage"
    expect_not_contains "choose nc skip: no false e2ee warning" "$CLI_OUT" "e2ee"
    expect_eq "choose nc skip: the combined external + e2ee probe queried the server" "1" \
      "$(grep -c 'PROPFIND' "$CHOOSE_CURL_LOG" 2>/dev/null || true)"
    expect_contains "choose nc skip: probes hit the chosen folder" "$(cat "$CHOOSE_CURL_LOG")" "backup/remote-plain"

    # ask/warn also proceed when the property is unavailable (never block
    # on a missing capability).
    : >"$FOLDERS_FILE"
    export EXTERNAL_STORAGE_POLICY=ask E2EE_POLICY=warn
    choose_fake '1\n\nn\ny\n' folders choose --no-fzf --no-dry-run --depth 1 \
      --mode pull --local-root "${TMP}/fake-ask"
    expect_rc "choose nc ask: rc 0" "$CLI_RC" 0
    expect_contains "choose nc ask: pair written" "$(cat "$FOLDERS_FILE")" "|remote-plain"
    expect_not_contains "choose nc ask: no false skip" "$CLI_OUT" "skipping (EXTERNAL_STORAGE_POLICY=ask)"
  else
    pass "choose nc gates: fake server unavailable; stubbed gate tests cover the policies"
  fi
else
  pass "choose nc gates: python3 unavailable; stubbed gate tests cover the policies"
fi

# --- fork-free captures: the pure helpers run in the caller's shell ---------
# choose_remote_size captures remote_spec, choose_bigfolder_gate captures
# size_suffix_bytes, and choose_bigfolder_label captures _bigfolder_label with
# ${ ...;} rather than $(...), so stubbed counters survive in this shell. With
# the old $(...) form each counter stayed at zero (set in a forked subshell).
remote_spec_calls=0
size_suffix_calls=0
bigfolder_label_calls=0
# shellcheck disable=SC2329  # counted while choose_remote_size runs in this shell
remote_spec() {
  remote_spec_calls=$((remote_spec_calls + 1))
  printf '%s/%s' "$REMOTE_PREFIX" "$1"
}
# shellcheck disable=SC2329  # counted while choose_bigfolder_gate runs in this shell
size_suffix_bytes() {
  size_suffix_calls=$((size_suffix_calls + 1))
  printf '1048576'
}
# shellcheck disable=SC2329  # counted while choose_bigfolder_label runs in this shell
_bigfolder_label() {
  bigfolder_label_calls=$((bigfolder_label_calls + 1))
  printf '2Mi'
}

BIGFOLDER_STUB_BYTES=2097152
export BIG_FOLDER_SIZE=1Mi BIG_FOLDER_POLICY=skip
CHOOSE_REMOTE_SIZE_CACHE=()
choose_remote_size forkpair >/dev/null
expect_eq "choose_remote_size: remote_spec is forkless" "1" "$remote_spec_calls"
choose_bigfolder_label 2097152
expect_eq "choose_bigfolder_label: label helper is forkless" "1" "$bigfolder_label_calls"
size_suffix_calls=0
# shellcheck disable=SC2034  # read by choose_remote_size through the gate
CHOOSE_REMOTE_SIZE_CACHE=()
choose_bigfolder_gate forkpair >/dev/null 2>&1 || true
expect_eq "choose_bigfolder_gate: size parser is forkless" "1" "$size_suffix_calls"

# --- [Y/n] prompts go through ui_confirm_default_yes -----------------------
# choose_include_excludes' include-all prompt is the shared [Y/n] gate: an
# empty reply or y/yes includes everything (returns 0 before the picker); a
# typed decline falls through to the picker; EOF keeps the old fatal path
# (`[[ -n "$UI_ASK_REPLY" ]] || die "input ended; nothing changed"`).
# choose_offer_dry_run's [Y/n] prompt now treats EOF like a typed "no"
# instead of the old default-yes.
# shellcheck disable=SC2329,SC2034  # stub / read by choose_include_excludes
choose_load_children() {
  CHOOSE_ITEMS=(alpha beta)
  return 0
}
# shellcheck disable=SC2329  # stub for the decline branch's picker
choose_select_items() {
  # shellcheck disable=SC2034  # read by choose_include_excludes
  CHOOSE_SELECTED=()
  return 1
}

CHOOSE_EXCLUDES=""
rc=0
choose_include_excludes sub <<<"" || rc=$?
expect_rc "include-all: empty reply confirms" "$rc" 0
expect_eq "include-all: confirm sets no excludes" "" "$CHOOSE_EXCLUDES"
rc=0
choose_include_excludes sub <<<"yes" || rc=$?
expect_rc "include-all: 'yes' confirms" "$rc" 0

CHOOSE_EXCLUDES=""
rc=0
choose_include_excludes sub <<<"n" || rc=$?
expect_rc "include-all: typed decline falls through" "$rc" 0
expect_contains "include-all: declined pick excludes every child" "$CHOOSE_EXCLUDES" "alpha"
expect_contains "include-all: declined pick excludes the second child" "$CHOOSE_EXCLUDES" "beta"

# EOF is still fatal (the old code died on the read failure).
rc=0
err="$(choose_include_excludes sub </dev/null 2>&1)" || rc=$?
expect_rc "include-all: EOF is fatal" "$rc" 1
expect_contains "include-all: EOF message" "$err" "input ended; nothing changed"

# choose_offer_dry_run: a typed decline and an EOF both skip the dry run
# without launching the check child (P_NAMES is set so an accept would run).
# shellcheck disable=SC2034  # read by choose_offer_dry_run
P_NAMES=(probe)
rc=0
choose_offer_dry_run <<<"n" || rc=$?
expect_rc "dry-run offer: typed decline skips" "$rc" 0
rc=0
choose_offer_dry_run </dev/null || rc=$?
expect_rc "dry-run offer: EOF declines" "$rc" 0

finish
