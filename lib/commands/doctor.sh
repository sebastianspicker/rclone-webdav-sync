#!/bin/bash
# doctor.sh command module - preflight checks with a PASS/WARN/FAIL report.
#
# Sourcing this module only defines functions and the DOCTOR_* state; every
# dependency loads inside cmd_doctor (after opt_guard's --help exit), so
# `sciebo doctor --help` and fixtures that source this file directly parse
# none of them.

DOCTOR_OFFLINE=0
DOCTOR_JSON=0
DOCTOR_PASS_COUNT=0
DOCTOR_WARN_COUNT=0
DOCTOR_FAIL_COUNT=0
# mode|local|remote|name records for the local-path checks.
DOCTOR_ENTRIES=""
# NAME<TAB>LEVEL<TAB>DETAIL records for every report line; converted into
# the --json document at the end of the run.
DOCTOR_LINES=""
# 1 when the capabilities cache/probe produced usable facts, and 1 when this
# run probed the server directly; both gate the E2EE scan.
DOCTOR_CAPABILITIES_AVAILABLE=0
DOCTOR_CAPABILITIES_PROBED=0
# Maximum paths inspected per manifest entry by the name-hygiene half of the
# merged local-tree walk; caps runtime and the temporary list used for
# case-collision detection. The walk itself keeps consuming the stream after
# the limit so the conflict-copy count stays complete (the pre-merge conflict
# scan always walked the whole tree).
DOCTOR_NAME_SCAN_LIMIT="${DOCTOR_NAME_SCAN_LIMIT:-50000}"
# Maximum manifest entries whose remote is queried by the E2EE, external
# storage, and big-folder checks, so doctor stays cheap on large manifests.
DOCTOR_REMOTE_SCAN_LIMIT="${DOCTOR_REMOTE_SCAN_LIMIT:-5}"
# Policy-report state collected for the --json document: name-hygiene counts
# and samples, case-clash pairs, E2EE/external paths found per source, and
# big-folder size records ("name<TAB>remote<TAB>bytes").
DOCTOR_NAME_HYGIENE_SCANNED=0
DOCTOR_NAME_HYGIENE_INVALID=0
DOCTOR_NAME_HYGIENE_COLLISIONS=0
DOCTOR_NAME_HYGIENE_PATHS=""
DOCTOR_CASE_CLASHES=""
# Conflict-copy results of the single merged local-tree walk:
# doctor_check_name_hygiene evaluates the hygiene and conflict predicates in
# one `find -P` pass per manifest local dir, and doctor_check_conflicts
# reports from these instead of walking the trees a second time.
# DOCTOR_CONFLICTS_SCANNED flips to 1 only after that walk has covered every
# entry, so a hygiene pass that aborted before the walk (or a direct call of
# doctor_check_conflicts) still takes the legacy per-entry conflict walk.
DOCTOR_CONFLICTS_SCANNED=0
DOCTOR_CONFLICT_COUNT=0
DOCTOR_CONFLICT_SAMPLES=""
# Memoized doctor_normalize_local results keyed by input path: the
# `cd ... && pwd -P` subshell runs once per distinct path even when several
# manifest entries name the same local dir, and repeat lookups are forkless.
declare -gA DOCTOR_NORMALIZE_CACHE=()
DOCTOR_E2EE_PATHS=""
DOCTOR_E2EE_CHECKED=0
DOCTOR_EXTERNAL_PATHS=""
DOCTOR_EXTERNAL_CHECKED=0
# Scratch array the shared remote-path engine appends excludes to; doctor
# only reports, so it stays empty.
# shellcheck disable=SC2034  # assigned through the engine's nameref out-param
DOCTOR_POLICY_EXCLUDES=()
DOCTOR_BIG_FOLDER_OVER=""
DOCTOR_BIG_FOLDER_CHECKED=0
# One shared `rclone about --json` probe backs both the runtime quota line and
# the QUOTA_WARN_PERCENT check; DOCTOR_ABOUT_OK/OUT carry that probe's verdict
# and combined output.
DOCTOR_ABOUT_OK=0
DOCTOR_ABOUT_OUT=""

usage_doctor() {
  usage_emit <<'EOF'
Usage: sciebo doctor [--offline] [--json]

Run preflight checks and print PASS/WARN/FAIL lines plus a summary.
Exits 1 if any check fails, 0 otherwise.

Checks: rclone availability and version, rclone config and remote,
remote type/url/vendor, the active scheduler/keychain/notification backends,
the app password storage and secret file permissions (.env and the rclone
config), free space on the state filesystem, the proxy mode, server
capabilities (cached or probed), end-to-end encryption (the server
capability and the configured sources), the cached server exclude list,
state directories, filter files (parsed by rclone), the manifest set
(duplicate names/remotes and overlapping local directories), name hygiene
(platform-invalid names and case-only collisions in existing local trees),
case clashes per source, mounted external storages, conflict copies in the
local trees, the watch pid record, the network and metered state, network
reachability, (on macOS) the launchd agent, and the desktop-parity policy
summary (invalid names, case clashes, E2EE, external storage, symlinks,
checksum, trash, the delete guard, and big folders).

Options:
  --offline   skip network checks (rclone lsd/about)
  --json      print only a JSON document
              {"ok":bool,"checks":[{"name":...,"status":...,"detail":...}]}
              instead of the text report
  -h, --help  show this help
EOF
}

# doctor_check_name MESSAGE - derive a stable check name from the first word
# of a report message, for the checks that predate explicit names.
doctor_check_name() {
  local name="${1%% *}" LC_ALL=C
  name="${name,,}"
  name="${name//[^a-z0-9._-]/}"
  printf '%s' "${name:-check}"
}

# doctor_report_named NAME LEVEL MESSAGE... - record one check (name, level,
# detail) for the JSON document and, in text mode, print the existing
# "<LEVEL>  message" line.
doctor_report_named() {
  local name="$1" level="$2" counter="DOCTOR_${2}_COUNT"
  local detail="" record=""
  shift 2
  detail="$*"
  printf -v "$counter" '%s' "$((${!counter} + 1))"
  record="${detail//$'\n'/ }"
  DOCTOR_LINES="${DOCTOR_LINES}${name}"$'\t'"${level}"$'\t'"${record}"$'\n'
  [[ "$DOCTOR_JSON" -eq 0 ]] || return 0
  printf '%-5s %s\n' "$level" "$detail"
}

# doctor_report LEVEL MESSAGE... - report a check without an explicit name.
# doctor_check_name is pure bash, so the name is captured forkless.
doctor_report() {
  local level="$1" check_name=""
  shift
  check_name=${ doctor_check_name "$*";}
  doctor_report_named "$check_name" "$level" "$*"
}

# doctor_delete_guard_short - compact delete-guard state for the policy
# summary and the JSON document: "on (threshold N)" when ASK_DELETE=1 and
# MAX_DELETE is unlimited, otherwise why the guard is inactive.
doctor_delete_guard_short() {
  local threshold="${DELETE_FILES_THRESHOLD:-100}" max="${MAX_DELETE:--1}"
  if [[ "${ASK_DELETE:-0}" != "1" ]]; then
    printf 'off (ASK_DELETE=0)'
  elif [[ "$max" == "-1" ]]; then
    printf 'on (threshold %s)' "$threshold"
  else
    printf 'off (MAX_DELETE=%s)' "$max"
  fi
}

# doctor_print_json - convert the buffered report records into the --json
# document. Prints nothing when JSON mode is off. The check array keeps its
# existing shape; the structured policy objects are added as extra top-level
# keys before it.
doctor_print_json() {
  local name="" level="" detail=""
  output_mode_set true
  output_json_begin
  if [[ "$DOCTOR_FAIL_COUNT" -eq 0 ]]; then
    output_json_kv_raw ok true
  else
    output_json_kv_raw ok false
  fi
  doctor_json_policies
  doctor_json_name_hygiene
  doctor_json_case_clashes
  doctor_json_paths e2ee "${E2EE_POLICY:-exclude}" "$DOCTOR_E2EE_PATHS" "$DOCTOR_E2EE_CHECKED"
  doctor_json_paths external "${EXTERNAL_STORAGE_POLICY:-ask}" "$DOCTOR_EXTERNAL_PATHS" "$DOCTOR_EXTERNAL_CHECKED"
  doctor_json_delete_guard
  doctor_json_big_folders
  output_json_array_begin checks
  while IFS=$'\t' read -r name level detail; do
    [[ -n "$level" ]] || continue
    output_json_object_begin
    output_json_kv name "$name"
    output_json_kv status "$level"
    output_json_kv detail "$detail"
    output_json_object_end
  done <<<"$DOCTOR_LINES"
  output_json_array_end
  output_json_end
}

# doctor_json_policies - emit the top-level "policies" object: one string
# per active desktop-parity policy.
doctor_json_policies() {
  output_json_object_begin policies
  output_json_kv invalid_names "${INVALID_NAME_POLICY:-exclude}"
  output_json_kv case_clashes "${CASE_CLASH_POLICY:-exclude}"
  output_json_kv e2ee "${E2EE_POLICY:-exclude}"
  output_json_kv external_storage "${EXTERNAL_STORAGE_POLICY:-ask}"
  output_json_kv symlinks "${SYMLINK_POLICY:-skip}"
  output_json_kv checksum "$(label_bool "${CHECKSUM:-0}" on off)"
  output_json_kv move_to_trash "$(label_bool "${MOVE_TO_TRASH:-0}" on off)"
  output_json_kv delete_guard "$(doctor_delete_guard_short)"
  output_json_object_end
}

# doctor_json_name_hygiene - emit the top-level "name_hygiene" object with
# the active INVALID_NAME_POLICY and the local scan counters/samples.
doctor_json_name_hygiene() {
  local sample=""
  output_json_object_begin name_hygiene
  output_json_kv policy "${INVALID_NAME_POLICY:-exclude}"
  output_json_kv_raw scanned "$DOCTOR_NAME_HYGIENE_SCANNED"
  output_json_kv_raw invalid "$DOCTOR_NAME_HYGIENE_INVALID"
  output_json_kv_raw collisions "$DOCTOR_NAME_HYGIENE_COLLISIONS"
  output_json_array_begin paths
  while IFS= read -r sample; do
    [[ -n "$sample" ]] || continue
    output_json_array_string "$sample"
  done <<<"$DOCTOR_NAME_HYGIENE_PATHS"
  output_json_array_end
  output_json_object_end
}

# doctor_json_case_clashes - emit the top-level "case_clashes" object with
# the active CASE_CLASH_POLICY and the "first<TAB>second" pairs found.
doctor_json_case_clashes() {
  local pair="" count=0
  while IFS= read -r pair; do
    [[ -n "$pair" ]] || continue
    count=$((count + 1))
  done <<<"$DOCTOR_CASE_CLASHES"
  output_json_object_begin case_clashes
  output_json_kv policy "${CASE_CLASH_POLICY:-exclude}"
  output_json_kv_raw count "$count"
  output_json_array_begin pairs
  while IFS= read -r pair; do
    [[ -n "$pair" ]] || continue
    output_json_array_string "$pair"
  done <<<"$DOCTOR_CASE_CLASHES"
  output_json_array_end
  output_json_object_end
}

# doctor_json_paths OBJECT POLICY PATHS CHECKED - nested object for a
# remote-path check (policy, number of sources scanned, paths found).
doctor_json_paths() {
  local object="$1" policy="$2" paths="$3" checked="$4" path=""
  output_json_object_begin "$object"
  output_json_kv policy "$policy"
  output_json_kv_raw checked "$checked"
  output_json_array_begin paths
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    output_json_array_string "$path"
  done <<<"$paths"
  output_json_array_end
  output_json_object_end
}

# doctor_json_delete_guard - emit the top-level "delete_guard" object with
# the threshold, ASK_DELETE, and the explicit MAX_DELETE override.
doctor_json_delete_guard() {
  local ask="${ASK_DELETE:-0}" threshold="${DELETE_FILES_THRESHOLD:-100}" max="${MAX_DELETE:--1}"
  output_json_object_begin delete_guard
  case "$ask" in
    1) output_json_kv_raw ask true ;;
    *) output_json_kv_raw ask false ;;
  esac
  case "$threshold" in '' | *[!0-9]*) threshold=100 ;; esac
  output_json_kv_raw threshold "$threshold"
  case "$max" in
    '' | *[!0-9]*) output_json_kv_raw max_delete -1 ;;
    *) output_json_kv_raw max_delete "$((10#$max))" ;;
  esac
  output_json_kv detail "$(doctor_delete_guard_short)"
  output_json_object_end
}

# doctor_json_big_folders - emit the top-level "big_folders" object with the
# configured limit, the policy, the measured source count, and one record
# per source above the limit.
doctor_json_big_folders() {
  local name="" remote="" bytes=""
  output_json_object_begin big_folders
  output_json_kv limit "${BIG_FOLDER_SIZE:-}"
  output_json_kv policy "${BIG_FOLDER_EXISTING_POLICY:-warn}"
  output_json_kv_raw checked "$DOCTOR_BIG_FOLDER_CHECKED"
  output_json_array_begin over
  while IFS=$'\t' read -r name remote bytes; do
    [[ -n "$name" ]] || continue
    output_json_object_begin
    output_json_kv name "$name"
    output_json_kv remote "$remote"
    output_json_kv_raw bytes "$bytes"
    output_json_object_end
  done <<<"$DOCTOR_BIG_FOLDER_OVER"
  output_json_array_end
  output_json_object_end
}

# doctor_report_remote KEY WANT GOOD BAD SHOW - report one config key.
# config_value is pure bash (locals only), so its capture stays forkless.
doctor_report_remote() {
  local got
  got=${ config_value "$1" "$5";}
  if [[ "$got" == "$2" ]]; then
    doctor_report "$3" "remote $1 is $2"
  else
    doctor_report "$4" "remote $1 is '${got:-<unset>}' (expected $2)"
  fi
}

# Resolve missing trailing components against the nearest existing parent.
# Results are memoized in DOCTOR_NORMALIZE_CACHE keyed by the input path, so
# the `cd`/`pwd -P` subshell runs only for the first sighting of a path and
# repeated manifest entries return the cached value without forking.
doctor_normalize_local() {
  local key="$1" p="$1" tail="" resolved
  # The key guard keeps an empty path out of the array subscript (bash
  # rejects an empty associative key); such inputs just stay unmemoized.
  if [[ -n "$key" && -n "${DOCTOR_NORMALIZE_CACHE[$key]+x}" ]]; then
    printf '%s' "${DOCTOR_NORMALIZE_CACHE[$key]}"
    return 0
  fi
  p="${p%/}"
  [[ -n "$p" ]] || p="/"
  while [[ ! -d "$p" && "$p" != "/" ]]; do
    tail="/${p##*/}${tail}"
    p="${p%/*}"
    [[ -n "$p" ]] || p="/"
  done
  resolved="$(cd "$p" 2>/dev/null && pwd -P)" || resolved="$p"
  resolved="${resolved%/}${tail}"
  [[ -z "$key" ]] || DOCTOR_NORMALIZE_CACHE[$key]="$resolved"
  printf '%s' "$resolved"
}

doctor_check_rclone() {
  local line="" version="" show="" url=""
  local required="${RCLONE_MIN_VERSION:-1.69}" required_major="" required_minor=""
  # One cached `rclone version` call; the first line is only fetched again
  # when the cached parse failed, to quote the raw output.
  version=${ rclone_version;}
  if [[ -n "$version" ]]; then
    line="rclone v${version}"
  elif have "$RCLONE_BIN"; then
    line="$("$RCLONE_BIN" version 2>/dev/null | sed -n '1p' || true)"
  fi
  if [[ -z "$line" ]]; then
    doctor_report FAIL "rclone not found (${RCLONE_BIN})"
  elif [[ -z "$version" ]]; then
    doctor_report FAIL "cannot parse rclone version from '${line}'"
  else
    required_major="${required%%.*}"
    required_minor="${required#*.}"
    required_minor="${required_minor%%.*}"
    if rclone_version_at_least "$required_major" "$required_minor"; then
      doctor_report PASS "rclone ${version} found (>= ${required})"
    else
      doctor_report FAIL "rclone ${version} is too old; need >= ${required}"
    fi
  fi
  if [[ -f "$RCLONE_CONFIG" ]]; then
    doctor_report PASS "rclone config file exists (${RCLONE_CONFIG})"
  else
    doctor_report FAIL "rclone config file missing (${RCLONE_CONFIG}); run '${CLI_NAME} setup'"
  fi
  if remote_configured; then
    doctor_report PASS "remote '${RCLONE_REMOTE}:' is listed in the rclone config"
    if ! show=${ remote_config_show;} || [[ -z "$show" ]]; then
      doctor_report FAIL "cannot read rclone config (${RCLONE_CONFIG}); check permissions and re-run '${CLI_NAME} setup'"
    else
      doctor_report_remote type webdav PASS FAIL "$show"
      doctor_report_remote vendor nextcloud PASS WARN "$show"
      url=${ config_value url "$show";}
      case "$url" in
        *"/remote.php/dav/files/"*)
          doctor_report PASS "remote url contains /remote.php/dav/files/ (chunked uploads enabled)"
          ;;
        *)
          doctor_report WARN "remote url '${url:-<unset>}' lacks /remote.php/dav/files/ (chunked uploads disabled); re-run '${CLI_NAME} setup'"
          ;;
      esac
    fi
  else
    doctor_report FAIL "remote '${RCLONE_REMOTE}:' not found; run '${CLI_NAME} setup'"
  fi
}

# doctor_capabilities_summary - comma-joined one-line summary of the loaded
# CAP_* globals, rendered from the shared capabilities table; empty when
# nothing was parsed. Only "available" trashbin/checksums facts are shown.
doctor_capabilities_summary() {
  local key="" verdict="" detail="" facts=""
  while IFS=$'\t' read -r key verdict detail; do
    [[ -n "$key" ]] || continue
    case "$key" in
      version) facts="${facts:+${facts}, }Nextcloud ${detail}" ;;
      bigfile)
        if [[ "$verdict" == "enabled" && -n "$detail" ]]; then
          facts="${facts:+${facts}, }chunked uploads enabled (max chunk ${detail})"
        elif [[ "$verdict" == "enabled" ]]; then
          facts="${facts:+${facts}, }chunked uploads enabled"
        else
          facts="${facts:+${facts}, }chunked uploads disabled"
        fi
        ;;
      trashbin)
        if [[ "$verdict" == "available" ]]; then
          facts="${facts:+${facts}, }trashbin available"
        fi
        ;;
      checksums)
        if [[ "$verdict" == "available" ]]; then
          facts="${facts:+${facts}, }checksums available"
        fi
        ;;
    esac
  done < <(capabilities_facts)
  printf '%s' "$facts"
}

# doctor_report_capabilities - one PASS line per parsed capability, rendered
# from the shared capabilities table; a successful probe without usable
# facts still reports success.
doctor_report_capabilities() {
  local key="" verdict="" detail="" reported=0
  while IFS=$'\t' read -r key verdict detail; do
    [[ -n "$key" ]] || continue
    case "$key" in
      version)
        doctor_report PASS "server is Nextcloud ${detail}"
        reported=1
        ;;
      bigfile)
        if [[ "$verdict" == "enabled" && -n "$detail" ]]; then
          doctor_report PASS "server supports chunked uploads (max chunk ${detail})"
        elif [[ "$verdict" == "enabled" ]]; then
          doctor_report PASS "server supports chunked uploads"
        else
          doctor_report PASS "server reports chunked uploads disabled"
        fi
        reported=1
        ;;
      trashbin)
        if [[ "$verdict" == "available" ]]; then
          doctor_report PASS "server trashbin is available"
        else
          doctor_report PASS "server reports trashbin unavailable"
        fi
        reported=1
        ;;
      checksums)
        if [[ "$verdict" == "available" ]]; then
          doctor_report PASS "server checksums are available"
          reported=1
        fi
        ;;
    esac
  done < <(capabilities_facts)
  [[ "$reported" -eq 1 ]] || doctor_report PASS "server capabilities probed (no details parsed)"
}

# doctor_check_capabilities - server capabilities from the cache (offline)
# or from a fresh probe. Never FAILs: an unreachable server must not make
# the doctor unusable.
doctor_check_capabilities() {
  local summary=""
  if ! type capabilities_load >/dev/null 2>&1; then
    doctor_report WARN "server capabilities module unavailable"
    return 0
  fi
  if [[ "$DOCTOR_OFFLINE" -eq 1 ]]; then
    if capabilities_load; then
      DOCTOR_CAPABILITIES_AVAILABLE=1
      summary=${ doctor_capabilities_summary;}
      doctor_report PASS "cached server capabilities: ${summary:-response present}"
    else
      doctor_report WARN "no cached server capabilities (run '${CLI_NAME} doctor' online or '${CLI_NAME} setup')"
    fi
    return 0
  fi
  if type capabilities_probe >/dev/null 2>&1 && capabilities_probe; then
    DOCTOR_CAPABILITIES_AVAILABLE=1
    DOCTOR_CAPABILITIES_PROBED=1
    doctor_report_capabilities
    return 0
  fi
  doctor_report WARN "server capabilities probe failed (a cached response may still be usable)"
  if capabilities_load; then
    DOCTOR_CAPABILITIES_AVAILABLE=1
    summary=${ doctor_capabilities_summary;}
    doctor_report PASS "cached server capabilities: ${summary:-response present}"
  fi
}

# doctor_check_backends - one line per active platform backend. Only launchd
# gets the plist/agent checks (in doctor_check_runtime); the other scheduler
# backends are reported as not checked.
doctor_check_backends() {
  local backend=""
  backend="$(platform_scheduler_backend)"
  case "$backend" in
    launchd) doctor_report PASS "scheduler backend: launchd" ;;
    "") doctor_report WARN "scheduler backend none not checked" ;;
    *) doctor_report WARN "scheduler backend ${backend} not checked" ;;
  esac
  backend="$(platform_keychain_backend)"
  doctor_report PASS "keychain backend: ${backend:-none}"
  backend="$(platform_notify_backend)"
  doctor_report PASS "notifications backend: ${backend:-none}"
}

# doctor_keychain_backend OUT_BACKEND - resolve the backend behind the
# KEYCHAIN=1 tier into OUT_BACKEND: keychain_backend when this build provides
# it, the platform probe as fallback, empty when neither exists. The command
# substitutions stay inside this helper, so the caller pays the same forks the
# single function used to.
doctor_keychain_backend() {
  local -n out_backend="$1"
  out_backend=""
  if type keychain_backend >/dev/null 2>&1; then
    out_backend="$(keychain_backend 2>/dev/null || true)"
  fi
  if [[ -z "$out_backend" ]] && type platform_keychain_backend >/dev/null 2>&1; then
    out_backend="$(platform_keychain_backend 2>/dev/null || true)"
  fi
}

# doctor_keychain_have_secret - true when the stored app password can be read:
# the plain-text lookup first, the legacy keychain_lookup fallback after. The
# caller has already ruled out a build without keychain_lookup, and the probe
# runs inside an `if` condition so a missing secret is never an error.
doctor_keychain_have_secret() {
  if type keychain_lookup_plain >/dev/null 2>&1 && keychain_lookup_plain >/dev/null 2>&1; then
    return 0
  fi
  keychain_lookup >/dev/null 2>&1
}

# doctor_check_keychain_enabled - the KEYCHAIN=1 tier of doctor_check_keychain:
# resolve the backend and refuse without one (FAIL) or without a usable lookup
# (WARN), then report where the app password lives: PASS in the keychain, WARN
# when only an obscured config copy remains (sync still works through that
# fallback, so it only nudges back to the keychain), FAIL when it is missing
# everywhere. Never prints the password; every path reports one line and
# returns 0.
doctor_check_keychain_enabled() {
  local show="" account="" backend="" have=0
  doctor_keychain_backend backend
  if [[ -z "$backend" ]]; then
    doctor_report FAIL "KEYCHAIN=1 but no keychain backend is available (need security, secret-tool, or pass)"
    return 0
  fi
  if ! type keychain_lookup >/dev/null 2>&1; then
    doctor_report WARN "keychain lookup unavailable in this build; cannot verify the stored app password"
    return 0
  fi
  if doctor_keychain_have_secret; then have=1; fi
  if [[ "$have" -eq 0 ]]; then
    # Existing configs may still carry the obscured password; sync keeps
    # working through the fallback, so only nudge toward the keychain.
    show=${ remote_config_show 2>/dev/null || true;}
    if [[ -n "$show" ]] && [[ -n "${ config_value pass "$show";}" ]]; then
      doctor_report WARN "app password is stored in the rclone config (obscured); re-run '${CLI_NAME} setup' to move it to the keychain"
    else
      doctor_report FAIL "app password missing from the ${backend} keychain; re-run '${CLI_NAME} setup'"
    fi
    return 0
  fi
  if type keychain_account >/dev/null 2>&1; then
    account="$(keychain_account 2>/dev/null || true)"
  fi
  doctor_report PASS "app password stored in the ${backend} keychain (${KEYCHAIN_SERVICE}, ${account:-unknown})"
  return 0
}

# doctor_check_config_password - the KEYCHAIN=0 tier of doctor_check_keychain:
# report whether the (obscured) app password sits in the rclone config: PASS
# when it does, FAIL with a re-run setup hint when the remote has none.
# config_value is pure bash, so the pass probe stays forkless.
doctor_check_config_password() {
  local show=""
  show=${ remote_config_show 2>/dev/null || true;}
  if [[ -n "$show" ]] && [[ -n "${ config_value pass "$show";}" ]]; then
    doctor_report PASS "app password stored in the rclone config (obscured)"
  else
    doctor_report FAIL "remote has no app password; re-run '${CLI_NAME} setup'"
  fi
}

# doctor_check_keychain - verify where the app password is stored, without
# ever printing it. The keychain helpers are optional so a stub build still
# runs the check. Two tiers, picked on KEYCHAIN: the enabled tier walks the
# backend/lookup/config ladder, the disabled tier reports the config-stored
# password.
doctor_check_keychain() {
  if [[ "${KEYCHAIN:-0}" -eq 1 ]]; then
    doctor_check_keychain_enabled
  else
    doctor_check_config_password
  fi
}

# doctor_check_secret_permissions - WARN-only checks on the local credential
# files: .env must not be group/other readable or writable and the rclone
# config must not be group/other readable. Missing files and a mode that
# cannot be read are never FAILs. Purely local, so it works offline.
doctor_check_secret_permissions() {
  local mode=""
  if [[ -f "$ENV_FILE" ]]; then
    mode=${ file_mode "$ENV_FILE";}
    if [[ -z "$mode" ]]; then
      doctor_report WARN "could not read the mode of ${ENV_FILE}; cannot verify it is private"
    elif [[ "$mode" == ?[2-7][2-7] ]]; then
      doctor_report WARN "${ENV_FILE} is group/other readable or writable (mode ${mode}); run 'chmod 600 ${ENV_FILE}'"
    else
      doctor_report PASS "${ENV_FILE} permissions are private (mode ${mode})"
    fi
  else
    doctor_report PASS "no ${ENV_FILE} file found (nothing to protect)"
  fi
  if [[ -f "$RCLONE_CONFIG" ]]; then
    mode=${ file_mode "$RCLONE_CONFIG";}
    if [[ -z "$mode" ]]; then
      doctor_report WARN "could not read the mode of ${RCLONE_CONFIG}; cannot verify it is private"
    elif [[ "$mode" == ?[4-7][4-7] ]]; then
      doctor_report WARN "${RCLONE_CONFIG} is group/other readable (mode ${mode}); run 'chmod 600 ${RCLONE_CONFIG}'"
    else
      doctor_report PASS "${RCLONE_CONFIG} permissions are private (mode ${mode})"
    fi
  else
    doctor_report PASS "no rclone config file at ${RCLONE_CONFIG} (nothing to protect)"
  fi
}

# doctor_check_free_space - report the free space on the filesystem holding
# STATE_DIR against MIN_FREE_SPACE/FREE_SPACE_DOWNLOAD (rclone size suffixes,
# empty disables a threshold). FAILs below MIN_FREE_SPACE, WARNs below
# FREE_SPACE_DOWNLOAD, PASSes otherwise. `df -Pk` is portable on macOS and
# Linux; column 4 is the available-KB count. Purely local, so it works
# offline.
doctor_check_free_space() {
  local free_kb="" free_bytes="" min="" download=""
  local min_raw="${MIN_FREE_SPACE:-}" download_raw="${FREE_SPACE_DOWNLOAD:-}"
  free_kb="$(df -Pk "$STATE_DIR" 2>/dev/null | awk 'NR == 2 { print $4; exit }')"
  case "$free_kb" in
    '' | *[!0-9]*)
      doctor_report_named "free space" WARN "cannot read the free space of ${STATE_DIR} (df failed)"
      return 0
      ;;
  esac
  free_bytes=$((10#$free_kb * 1024))
  min=${ size_suffix_bytes "$min_raw" 2>/dev/null;} || min=""
  download=${ size_suffix_bytes "$download_raw" 2>/dev/null;} || download=""
  if [[ -n "$min" && "$free_bytes" -lt "$min" ]]; then
    doctor_report_named "free space" FAIL "${free_bytes} bytes free on ${STATE_DIR} is below MIN_FREE_SPACE (${min_raw})"
  elif [[ -n "$download" && "$free_bytes" -lt "$download" ]]; then
    doctor_report_named "free space" WARN "${free_bytes} bytes free on ${STATE_DIR} is below FREE_SPACE_DOWNLOAD (${download_raw})"
  else
    doctor_report_named "free space" PASS "${free_bytes} bytes free on ${STATE_DIR} (MIN_FREE_SPACE=${min_raw:-unset}, FREE_SPACE_DOWNLOAD=${download_raw:-unset})"
  fi
  return 0
}

# doctor_check_proxy - report the effective proxy mode. PROXY_DIRECT beats
# an explicit PROXY (it wins inside rclone_cmd), an explicit PROXY beats the
# environment, and HTTPS_PROXY/HTTP_PROXY are the environment fallback.
doctor_check_proxy() {
  local value=""
  if [[ "${PROXY_DIRECT:-0}" == "1" ]]; then
    doctor_report_named proxy PASS "direct connection (PROXY_DIRECT=1)"
    return 0
  fi
  if [[ -n "${PROXY:-}" ]]; then
    doctor_report_named proxy PASS "explicit proxy $(url_redact_userinfo "$PROXY")"
    return 0
  fi
  value="${HTTPS_PROXY:-${https_proxy:-}}"
  [[ -n "$value" ]] || value="${HTTP_PROXY:-${http_proxy:-}}"
  if [[ -n "$value" ]]; then
    doctor_report_named proxy PASS "proxy from the environment: $(url_redact_userinfo "$value")"
  else
    doctor_report_named proxy WARN "no proxy configured and none in the environment"
  fi
  return 0
}

# doctor_report_tls_file KEY LABEL - report the PEM file named by the KEY
# setting: PASS when readable, FAIL when it is missing or not a readable file.
# An unset key reports nothing.
doctor_report_tls_file() {
  local label="$2" path="${!1}"
  [[ -n "$path" ]] || return 0
  if [[ -f "$path" && -r "$path" ]]; then
    doctor_report_named "$label" PASS "${label} is readable (${path})"
  elif [[ -e "$path" ]]; then
    doctor_report_named "$label" FAIL "${label} is not a readable file (${path})"
  else
    doctor_report_named "$label" FAIL "${label} is missing (${path})"
  fi
}

# doctor_check_tls_client - report the optional mutual-TLS, custom-CA, and
# User-Agent settings. A configured PEM file that is missing or unreadable is
# a FAIL (cmd_doctor sets SCIEBO_SKIP_FILE_CHECKS=1 before load_settings, so
# this reports instead of dying in validate_settings). Purely local.
doctor_check_tls_client() {
  local user_agent_label=""
  if [[ -z "${CLIENT_CERT:-}" && -z "${CLIENT_KEY:-}" && -z "${CA_CERT:-}" &&
    -z "${CLIENT_KEY_PASSWORD:-}" && -z "${USER_AGENT:-}" ]]; then
    doctor_report_named "tls client" PASS "no client certificate, custom CA, or User-Agent configured"
    return 0
  fi
  doctor_report_tls_file CLIENT_CERT "client certificate"
  doctor_report_tls_file CLIENT_KEY "client key"
  doctor_report_tls_file CA_CERT "CA certificate"
  if [[ -n "${CLIENT_CERT:-}" && -z "${CLIENT_KEY:-}" ]] ||
    [[ -z "${CLIENT_CERT:-}" && -n "${CLIENT_KEY:-}" ]]; then
    doctor_report_named "client key pair" WARN "CLIENT_CERT and CLIENT_KEY should be set together"
  fi
  if [[ -n "${CLIENT_KEY_PASSWORD:-}" ]]; then
    doctor_report_named "client key passphrase" PASS "client key passphrase is configured"
  elif [[ -n "${CLIENT_KEY:-}" ]]; then
    doctor_report_named "client key passphrase" WARN "CLIENT_KEY is set without CLIENT_KEY_PASSWORD; an encrypted key needs the passphrase"
  fi
  if [[ -n "${USER_AGENT:-}" ]]; then
    user_agent_label=${ printable "$USER_AGENT";}
    doctor_report_named "user agent" PASS "User-Agent override: ${user_agent_label}"
  elif [[ -n "${CLIENT_CERT:-}${CLIENT_KEY:-}${CA_CERT:-}" ]]; then
    doctor_report_named "user agent" WARN "no User-Agent override configured; using the rclone/curl default"
  fi
  return 0
}

# doctor_check_server_exclude - when FILTER_SERVER_SYNC=1, report whether the
# cached server exclude list exists and is younger than
# SERVER_EXCLUDE_MAX_AGE. Missing or stale only WARNs; sync degrades to not
# layering the list.
doctor_check_server_exclude() {
  local max_age="${SERVER_EXCLUDE_MAX_AGE:-0}" mtime="" now="" age=""
  local age_label="" max_age_label=""
  local file="${SERVER_EXCLUDE_FILE:-}"
  [[ "${FILTER_SERVER_SYNC:-0}" == "1" ]] || return 0
  if [[ -z "$file" || ! -f "$file" ]]; then
    doctor_report_named "server exclude list" WARN "server exclude list missing (${file:-SERVER_EXCLUDE_FILE}); run '${CLI_NAME} filters sync'"
    return 0
  fi
  case "$max_age" in '' | *[!0-9]*) max_age=0 ;; esac
  mtime=${ file_mtime "$file";}
  [[ -n "$mtime" ]] || mtime=0
  now=${ now_epoch;}
  age=$((now - mtime))
  [[ "$age" -ge 0 ]] || age=0
  # file_mtime/now_epoch/duration_human are pure bash (locals only), so
  # both duration labels are captured forkless before the report.
  age_label=${ duration_human "$age";}
  max_age_label=${ duration_human "$max_age";}
  if [[ "$max_age" -gt 0 && "$age" -lt "$max_age" ]]; then
    doctor_report_named "server exclude list" PASS "server exclude list is fresh (age ${age_label}, max ${max_age_label})"
  else
    doctor_report_named "server exclude list" WARN "server exclude list is stale (age ${age_label}, max ${max_age_label}); run '${CLI_NAME} filters sync'"
  fi
  return 0
}

# doctor_check_e2ee - when a fresh capabilities response is available (cached
# fresh or just probed), look for the end-to-end-encryption capability.
# Purely local (the JSON is already cached or was just probed); E2EE folders
# are opaque to this tooling, so this is a WARN, never a FAIL. The per-source
# folder scan is doctor_check_e2ee_paths.
doctor_check_e2ee() {
  local json="${CAPABILITIES_JSON:-}"
  [[ "$DOCTOR_CAPABILITIES_AVAILABLE" -eq 1 ]] || return 0
  if [[ "$DOCTOR_CAPABILITIES_PROBED" -ne 1 ]]; then
    type capabilities_cache_fresh >/dev/null 2>&1 || return 0
    capabilities_cache_fresh || return 0
  fi
  [[ -n "$json" && -r "$json" ]] || return 0
  if LC_ALL=C grep -qiE 'end-to-end-encryption|e2ee' "$json" 2>/dev/null; then
    doctor_report_named e2ee WARN "server has end-to-end encryption enabled; sciebo cannot decrypt E2EE folders (E2EE_POLICY=${E2EE_POLICY:-exclude})"
  else
    doctor_report_named e2ee PASS "server has no end-to-end encryption enabled"
  fi
  return 0
}

# doctor_check_watch - when a watch.pid record exists, report whether the
# recorded watcher is still live or stale (lock.sh's shared pid_alive does
# the kill -0 plus start-time recycling check). Purely local.
doctor_check_watch() {
  local file="" pid="" started=""
  [[ -n "${WATCH_DIR:-}" ]] || return 0
  file="${WATCH_DIR}/watch.pid"
  [[ -f "$file" ]] || return 0
  {
    IFS= read -r pid || true
    IFS= read -r started || true
  } <"$file" 2>/dev/null || true
  if pid_alive "$pid" "$started"; then
    doctor_report_named watch PASS "watcher running (pid ${pid})"
  else
    doctor_report_named watch WARN "stale watcher record (${file})"
  fi
  return 0
}

# doctor_check_network - report the active interface/SSID and the metered
# decision through the platform helpers. Metered connections WARN with the
# configured METERED_POLICY; nothing here reaches the network.
doctor_check_network() {
  local label="" metered=0 ssid=""
  if net_is_metered; then
    metered=1
  fi
  ssid=${ printable "${NET_SSID:-}";}
  if [[ -n "${NET_IFACE:-}" && -n "$ssid" ]]; then
    label="${NET_IFACE} (${ssid})"
  elif [[ -n "${NET_IFACE:-}" ]]; then
    label="${NET_IFACE}"
  elif [[ -n "$ssid" ]]; then
    label="${ssid}"
  else
    label="unknown"
  fi
  if [[ "$metered" -eq 1 ]]; then
    doctor_report_named network WARN "metered: ${label} (METERED_POLICY=${METERED_POLICY:-allow})"
  else
    doctor_report_named network PASS "not metered: ${label}"
  fi
  return 0
}

# doctor_check_filters - validate clutter.txt plus every *.txt filter file
# through rclone's own --filter-from parser.
doctor_check_filters() {
  local filter="" checked=0 failures=0
  local -a filters=() validate_args=()
  if [[ ! -f "${FILTER_DIR}/clutter.txt" ]]; then
    doctor_report FAIL "filter file missing (${FILTER_DIR}/clutter.txt)"
    return 0
  fi
  have "$RCLONE_BIN" || return 0
  while IFS= read -r filter; do
    filters+=("$filter")
    validate_args+=(--filter-from "$filter")
  done < <(find "$FILTER_DIR" -maxdepth 1 -type f -name '*.txt' 2>/dev/null | LC_ALL=C sort)
  checked="${#filters[@]}"
  if [[ "$checked" -eq 0 ]]; then
    doctor_report FAIL "no *.txt filter files found in ${FILTER_DIR}"
    return 0
  fi
  # One invocation validates every file together; only when it rejects the set
  # do we re-run per file to name the offenders (preserving the old report).
  if rclone_cmd --dump filters "${validate_args[@]}" lsf "$FILTER_DIR" >/dev/null 2>&1; then
    doctor_report PASS "rclone filter validation passed (${checked} file(s))"
    return 0
  fi
  for filter in "${filters[@]}"; do
    if ! rclone_cmd --dump filters --filter-from "$filter" lsf "$FILTER_DIR" >/dev/null 2>&1; then
      doctor_report FAIL "rclone rejects filter file ${filter}"
      failures=$((failures + 1))
    fi
  done
  [[ "$failures" -eq 0 ]] || return 0
  doctor_report PASS "rclone filter validation passed (${checked} file(s))"
}

# doctor_check_manifest_entries - parse every manifest file and report the
# valid/invalid counts. Sets DOCTOR_ENTRIES for the local-path checks.
doctor_check_manifest_entries() {
  local file="" line="" line_label="" valid=0 invalid=0
  DOCTOR_ENTRIES=""
  while IFS= read -r file; do
    [[ -f "$file" ]] || continue
    while IFS= read -r line; do
      if manifest_parse_line "$line"; then
        valid=$((valid + 1))
        DOCTOR_ENTRIES="${DOCTOR_ENTRIES}${ENTRY_MODE}|${ENTRY_LOCAL}|${ENTRY_REMOTE}|${ENTRY_NAME}"$'\n'
      else
        invalid=$((invalid + 1))
        line_label=${ printable "$line";}
        doctor_report FAIL "${file##*/}: invalid entry '${line_label}': ${ENTRY_ERROR}"
      fi
    done < <(config_lines "$file")
  done < <(manifest_files)
  if [[ "$valid" -eq 0 ]]; then
    doctor_report WARN "no valid manifest entries (nothing will be synced)"
  elif [[ "$invalid" -eq 0 ]]; then
    doctor_report PASS "manifests parsed (${valid} valid entries)"
  fi
}

# doctor_each_entry FN [ARG...] - walk every DOCTOR_ENTRIES record in order,
# calling FN as FN MODE LOCAL_PATH REMOTE NAME ARG.... Rows without a mode
# are skipped, exactly like the per-check loops did. Runs in the caller's
# shell, so FN reads and writes the caller's locals (like
# manifest_each/blacklist_each_record) and a bounded scan can no-op itself
# once it reaches its limit. FN must return 0 so a genuine failure inside it
# still aborts under `set -e`, exactly as the old inline loop body did.
doctor_each_entry() {
  local fn="$1" mode="" local_path="" remote="" name=""
  shift
  while IFS='|' read -r mode local_path remote name; do
    [[ -n "$mode" ]] || continue
    "$fn" "$mode" "$local_path" "$remote" "$name" "$@"
  done <<<"$DOCTOR_ENTRIES"
  return 0
}

doctor_check_manifest_duplicates() {
  local dup="" dup_label=""
  while IFS= read -r dup; do
    [[ -z "$dup" ]] || doctor_report FAIL "duplicate source name '${dup}'; logs and bisync state would collide (rename one entry)"
  done <<<"$MANIFEST_DUP_NAMES"
  while IFS= read -r dup; do
    dup_label=${ printable "$dup";}
    [[ -z "$dup" ]] || doctor_report WARN "duplicate remote subdir '${dup_label}' is used by more than one entry"
  done <<<"$MANIFEST_DUP_REMOTES"
}

# doctor_manifest_locals_entry MODE LOCAL_PATH REMOTE NAME - warn about one
# entry's missing local dir/uninitialized bisync state and append its
# normalized local path to the caller's `normalized` list.
doctor_manifest_locals_entry() {
  local mode="$1" local_path="$2" remote="$3" name="$4" remote_label=""
  remote_label=${ printable "$remote";}
  if [[ "$mode" != pull && ! -d "$local_path" ]]; then
    doctor_report WARN "${mode} entry '${remote_label}': local dir ${local_path} does not exist (created on first run)"
  fi
  if [[ "$mode" == bisync ]] && ! bisync_initialized "$name"; then
    doctor_report WARN "bisync entry '${remote_label}': not initialized; run 'make bisync-resync' first"
  fi
  # doctor_normalize_local is memoized, so the forkless capture makes repeat
  # paths free (first sighting still pays its `cd`/`pwd -P` subshell inside).
  normalized="${normalized}${mode}|${ doctor_normalize_local "$local_path";}|${remote}|${name}"$'\n'
  return 0
}

# doctor_check_manifest_locals - warn about missing local dirs and
# uninitialized bisync state, then report overlapping local directories.
# Normalizes every local path once and sorts by it; a stack of the current
# ancestor chain then reports each strictly-nested pair without the old
# O(n^2) cross-product.
doctor_check_manifest_locals() {
  local mode="" a_local="" a_remote="" b_local="" b_remote="" i=0 top=0
  local a_remote_label="" b_remote_label=""
  local normalized=""
  local -a stack_local=() stack_remote=()
  doctor_each_entry doctor_manifest_locals_entry
  normalized="${normalized%$'\n'}"
  [[ -n "$normalized" ]] || return 0
  while IFS='|' read -r mode a_local a_remote _; do
    [[ -n "$mode" ]] || continue
    # Drop stack entries that are not ancestors of a_local; the remainder is
    # the ancestor chain (an entry below a prefix is also a prefix). Equal
    # paths stay so a duplicate entry still records every ancestor, matching
    # the old pairwise scan.
    while ((top > 0)); do
      b_local="${stack_local[top - 1]}"
      [[ "${a_local}/" == "${b_local}/"?* || "$a_local" == "$b_local" ]] && break
      top=$((top - 1))
    done
    a_remote_label=${ printable "$a_remote";}
    for ((i = top - 1; i >= 0; i--)); do
      b_local="${stack_local[i]}"
      [[ "$b_local" != "$a_local" ]] || continue
      b_remote="${stack_remote[i]}"
      b_remote_label=${ printable "$b_remote";}
      doctor_report WARN "overlapping sources: '${a_remote_label}' (${a_local}) is inside '${b_remote_label}' (${b_local})"
    done
    stack_local[top]="$a_local"
    stack_remote[top]="$a_remote"
    top=$((top + 1))
  done < <(printf '%s\n' "$normalized" | LC_ALL=C sort -t '|' -k2,2)
}

# doctor_check_manifest - filters, entries, duplicates, and local paths.
doctor_check_manifest() {
  doctor_check_filters
  doctor_check_manifest_entries
  manifest_index_invalidate
  manifest_index_load
  doctor_check_manifest_duplicates
  doctor_check_manifest_locals
}

# doctor_name_hygiene_samples SAMPLES - join newline-separated sample paths
# (already passed through printable) as 'a', 'b'.
doctor_name_hygiene_samples() {
  local s="" out=""
  while IFS= read -r s; do
    [[ -n "$s" ]] || continue
    out="${out}${out:+, }'${s}'"
  done <<<"$1"
  printf '%s' "$out"
}

# doctor_name_hygiene_group COUNT PATHS COUNT_VAR SHOWN_VAR SAMPLES_VAR -
# account for one lowercased-key group of COUNT distinct paths: a group of
# two or more is a case-only collision, and its paths are appended (in
# order, until five samples are collected) to the newline list named by
# SAMPLES_VAR. Counter variables are updated through namerefs.
doctor_name_hygiene_group() {
  local count="$1" paths="$2" path="" path_label=""
  local -n _collisions="$3" _shown="$4" _samples="$5"
  [[ "$count" -ge 2 ]] || return 0
  _collisions=$((_collisions + 1))
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    [[ "$_shown" -lt 5 ]] || break
    _shown=$((_shown + 1))
    path_label=${ printable "$path";}
    _samples="${_samples}${_samples:+$'\n'}${path_label}"
  done <<<"$paths"
  return 0
}

# doctor_name_hygiene_fold_groups LIST COLLISIONS_VAR SHOWN_VAR SAMPLES_VAR -
# fold the sorted unique "<lowercased path>\t<path>" records in LIST into
# per-lowercased-key groups, flushing each finished group through
# doctor_name_hygiene_group. The counter/sample variables are updated in the
# caller's scope through the names given (the nameref chain stays intact).
doctor_name_hygiene_fold_groups() {
  local source="$1" collisions_var="$2" shown_var="$3" samples_var="$4"
  local key="" path="" prev_key="" group_paths=""
  local first=1 group_count=0
  while IFS=$'\t' read -r key path; do
    [[ -n "$path" ]] || continue
    if [[ "$first" -eq 0 && "$key" != "$prev_key" ]]; then
      doctor_name_hygiene_group "$group_count" "$group_paths" "$collisions_var" "$shown_var" "$samples_var"
      group_count=0
      group_paths=""
    fi
    first=0
    prev_key="$key"
    group_count=$((group_count + 1))
    group_paths="${group_paths}${group_paths:+$'\n'}$path"
  done < <(LC_ALL=C sort -u "$source")
  doctor_name_hygiene_group "$group_count" "$group_paths" "$collisions_var" "$shown_var" "$samples_var"
  return 0
}

# doctor_name_hygiene_invalid_path PATH BASE - account one path in the hygiene
# half of the merged walk when policy_invalid_name rejects its base name: bump
# the caller's `invalid` and, while fewer than five samples are collected,
# append the printable path to the caller's `bad_samples`. Both live in
# doctor_check_name_hygiene's scope and are reached through the existing
# dynamic-scope chain, exactly as the inline body did. No-op for portable
# names.
doctor_name_hygiene_invalid_path() {
  local path="$1" base="$2" path_label=""
  policy_invalid_name "$base" || return 0
  invalid=$((invalid + 1))
  [[ "$invalid" -le 5 ]] || return 0
  path_label=${ printable "$path";}
  bad_samples="${bad_samples}${bad_samples:+$'\n'}${path_label}"
  return 0
}

# doctor_name_hygiene_limit_warn LOCAL_PATH_LABEL - the single truncation WARN
# emitted once per local tree when DOCTOR_NAME_SCAN_LIMIT is reached.
doctor_name_hygiene_limit_warn() {
  doctor_report WARN "name hygiene: '$1' scan truncated at ${DOCTOR_NAME_SCAN_LIMIT} paths; names beyond that were not checked"
}

# doctor_name_hygiene_conflict_path DIR BASE PATH PATTERN - the conflict-copy
# half of the merged walk: for a regular file whose base name matches the
# caller's find-style PATTERN, bump DOCTOR_CONFLICT_COUNT and, for the first
# three, append the printable path relative to DIR to
# DOCTOR_CONFLICT_SAMPLES. `find -name "*<pattern>*" -type f` under -P keeps a
# symlink as type "link", so `-f && ! -L` matches -type f exactly; the pattern
# stays unquoted so glob metachars in CONFLICT_PATTERN behave like find's
# fnmatch (same as before). No-op otherwise.
doctor_name_hygiene_conflict_path() {
  local dir="$1" base="$2" path="$3" pattern="$4" rel="" rel_label=""
  # shellcheck disable=SC2053  # intentional pattern match, mirrors find -name
  [[ "$base" == $pattern && -f "$path" && ! -L "$path" ]] || return 0
  DOCTOR_CONFLICT_COUNT=$((DOCTOR_CONFLICT_COUNT + 1))
  [[ "$DOCTOR_CONFLICT_COUNT" -le 3 ]] || return 0
  case "$dir" in
    /)
      rel="${path#/}"
      rel="${rel#/}"
      ;;
    *) rel="${path#"$dir"/}" ;;
  esac
  rel_label=${ printable "$rel";}
  DOCTOR_CONFLICT_SAMPLES="${DOCTOR_CONFLICT_SAMPLES}${DOCTOR_CONFLICT_SAMPLES:+$'\n'}${rel_label}"
  return 0
}

# doctor_name_hygiene_scan LOCAL_PATH - scan one existing local tree in ONE
# `find -P` pass that evaluates both doctor-local tree predicates:
#   1. name hygiene: warn when DOCTOR_NAME_SCAN_LIMIT is hit, count
#      platform-invalid names (collecting up to five samples into the
#      caller's `bad_samples`), and write every counted path as
#      "<lowercased path>\t<path>" to the caller's open `fd` for the
#      collision fold;
#   2. conflict copies: count regular files whose name matches
#      *CONFLICT_PATTERN* (the old second walk's `find -name ... -type f`,
#      evaluated here per path) into DOCTOR_CONFLICT_COUNT, collecting up to
#      three relative-path samples into DOCTOR_CONFLICT_SAMPLES.
# The hygiene half stops counting at the scan limit with one truncation WARN
# exactly like the pre-merge walk, but the stream keeps being consumed
# because the pre-merge conflict walk always ran over the whole tree.
doctor_name_hygiene_scan() {
  local local_path="$1" path="" base="" count=0 stopped=0
  local local_path_label="" dir="" conflict_pat=""
  local_path_label=${ printable "$local_path";}
  dir="${local_path%/}"
  [[ -n "$dir" ]] || dir="/"
  conflict_pat="*${CONFLICT_PATTERN:-conflicted copy}*"
  while IFS= read -r -d '' path; do
    base="${path##*/}"
    if [[ "$stopped" -eq 0 ]]; then
      if [[ "$count" -ge "$DOCTOR_NAME_SCAN_LIMIT" ]]; then
        doctor_name_hygiene_limit_warn "$local_path_label"
        stopped=1
      else
        count=$((count + 1))
        scanned=$((scanned + 1))
        doctor_name_hygiene_invalid_path "$path" "$base"
        printf '%s\t%s\n' "${path,,}" "$path" >&"$fd"
      fi
    fi
    # Conflict predicate, evaluated per path over the same stream.
    doctor_name_hygiene_conflict_path "$dir" "$base" "$path" "$conflict_pat"
  done < <(find -P "$local_path" -print0 2>/dev/null)
  return 0
}

# doctor_name_hygiene_entry MODE LOCAL_PATH - scan one existing manifest local
# tree; missing directories are skipped like the old inline guard.
doctor_name_hygiene_entry() {
  local local_path="$2"
  [[ -d "$local_path" ]] || return 0
  doctor_name_hygiene_scan "$local_path"
  return 0
}

# doctor_check_name_hygiene - scan the existing local trees for names that
# policy_invalid_name rejects (the same rule sync applies: Windows-invalid
# characters, trailing dot/space, reserved device names) and for case-only
# collisions within one directory. WARNs only: a hostile name must never
# make the doctor itself unusable; the message states what
# INVALID_NAME_POLICY does with the names. One pass writes each path as
# "<lowercased path>\t<path>"; a single sort then yields equal-key groups.
# That same pass also counts the conflict copies (see
# doctor_name_hygiene_scan), so this check owns the one merged walk over the
# manifest local trees and flips DOCTOR_CONFLICTS_SCANNED once every entry
# has been visited; doctor_check_conflicts then reports without a second
# walk. A temporary-file failure leaves the flag at 0 so the conflict check
# falls back to its legacy per-entry walk.
doctor_check_name_hygiene() {
  local LC_ALL=C
  local list="" fd=""
  local scanned=0 invalid=0 collisions=0 shown=0
  local policy="${INVALID_NAME_POLICY:-exclude}" action=""
  local bad_samples="" collision_samples=""
  local bad_label="" collision_label=""
  case "$policy" in
    exclude) action="excluded from sync/pull" ;;
    warn) action="warned and synced" ;;
    *) action="synced as-is" ;;
  esac
  temp_mktemp_into list "${TMPDIR:-/tmp}/sciebo-doctor-names.XXXXXX" || {
    doctor_report WARN "name hygiene: cannot create a temporary file under ${TMPDIR:-/tmp}"
    return 0
  }
  # Fresh conflict-copy state for the merged walk; the flag stays 0 on the
  # temp-file failure above so doctor_check_conflicts takes its legacy
  # per-entry fallback walk.
  DOCTOR_CONFLICTS_SCANNED=0
  DOCTOR_CONFLICT_COUNT=0
  DOCTOR_CONFLICT_SAMPLES=""
  exec {fd}>>"$list"
  doctor_each_entry doctor_name_hygiene_entry
  exec {fd}>&-
  DOCTOR_CONFLICTS_SCANNED=1
  if [[ -s "$list" ]]; then
    doctor_name_hygiene_fold_groups "$list" collisions shown collision_samples
  fi
  if [[ "$invalid" -gt 0 ]]; then
    bad_samples="$(printf '%s\n' "$bad_samples" | LC_ALL=C sort)"
    # doctor_name_hygiene_samples is pure bash; capture it forkless.
    bad_label=${ doctor_name_hygiene_samples "$bad_samples";}
    doctor_report WARN "name hygiene: ${invalid} platform-invalid name(s) (<>\":|?* brackets, trailing dot/space, or reserved names); INVALID_NAME_POLICY=${policy}: ${action}: ${bad_label}"
  fi
  if [[ "$collisions" -gt 0 ]]; then
    collision_label=${ doctor_name_hygiene_samples "$collision_samples";}
    doctor_report WARN "name hygiene: ${collisions} case-only collision(s): ${collision_label}"
  fi
  if [[ "$invalid" -eq 0 && "$collisions" -eq 0 && "$scanned" -gt 0 ]]; then
    doctor_report PASS "name hygiene: ${scanned} path(s) scanned, no platform-invalid or case-colliding names"
  fi
  DOCTOR_NAME_HYGIENE_SCANNED=$scanned
  DOCTOR_NAME_HYGIENE_INVALID=$invalid
  DOCTOR_NAME_HYGIENE_COLLISIONS=$collisions
  DOCTOR_NAME_HYGIENE_PATHS="$bad_samples"
  temp_discard "$list"
  return 0
}

# doctor_conflicts_entry MODE LOCAL_PATH - the LEGACY fallback walk: scan one
# existing local tree for conflict copies, counting them in the caller's
# `count` and collecting up to three relative-path samples in the caller's
# `samples`. Only runs when doctor_check_name_hygiene's merged walk did not
# cover the entries (temp-file failure, or a direct call of the conflict
# check without the hygiene pass); the normal cmd_doctor path reports from
# the merged walk instead.
doctor_conflicts_entry() {
  local local_path="$2" dir="" path="" rel="" rel_label=""
  dir="${local_path%/}"
  [[ -n "$dir" ]] || dir="/"
  [[ -d "$dir" ]] || return 0
  while IFS= read -r -d '' path; do
    count=$((count + 1))
    [[ "$shown" -lt 3 ]] || continue
    case "$dir" in
      /) rel="${path#/}" ;;
      *) rel="${path#"$dir"/}" ;;
    esac
    shown=$((shown + 1))
    rel_label=${ printable "$rel";}
    samples="${samples}${samples:+$'\n'}${rel_label}"
  done < <(find -P "$dir" -name "*${CONFLICT_PATTERN}*" -type f -print0 2>/dev/null)
  return 0
}

# doctor_check_conflicts - scan the existing local trees for conflict copies
# (rclone bisync or desktop client) and report one WARN with the count and up
# to three sample relative paths, or one PASS. Purely local, so it works
# offline, and it never FAILs. Normally no walk happens here: the merged
# name-hygiene pass already counted the copies into DOCTOR_CONFLICT_COUNT
# (DOCTOR_CONFLICTS_SCANNED=1); only a hygiene pass that never ran walks the
# trees itself through the legacy doctor_conflicts_entry fallback.
doctor_check_conflicts() {
  local count=0 shown=0 samples="" samples_label=""
  if [[ "$DOCTOR_CONFLICTS_SCANNED" -eq 1 ]]; then
    count="$DOCTOR_CONFLICT_COUNT"
    samples="$DOCTOR_CONFLICT_SAMPLES"
  else
    doctor_each_entry doctor_conflicts_entry
  fi
  if [[ "$count" -gt 0 ]]; then
    samples_label=${ doctor_name_hygiene_samples "$samples";}
    doctor_report WARN "conflict copies: ${count} found (up to 3 samples): ${samples_label}"
  else
    doctor_report PASS "no conflict copies found in local trees"
  fi
}

# ---------------------------------------------------------------------------
# Desktop-parity policy checks
# ---------------------------------------------------------------------------

# doctor_remote_is_nextcloud - true when the configured remote carries a
# Nextcloud WebDAV URL (the same rule as sync's preflights), delegated to
# remote_is_nextcloud so doctor and sync share one detection path.
doctor_remote_is_nextcloud() {
  remote_is_nextcloud
}

# doctor_remote_size_bytes SPEC - print the remote total in bytes from one
# `rclone size --json`, delegating to rclone_remote_size. rc 1 when the size
# cannot be read or parsed.
doctor_remote_size_bytes() {
  rclone_remote_size "$1"
}

# doctor_check_policies - one compact PASS line naming the active
# desktop-parity policies, so the report shows what behavior to expect.
doctor_check_policies() {
  doctor_report_named policies PASS "policies: invalid names=${INVALID_NAME_POLICY:-exclude}, case clashes=${CASE_CLASH_POLICY:-exclude}, E2EE=${E2EE_POLICY:-exclude}, external storage=${EXTERNAL_STORAGE_POLICY:-ask}, symlinks=${SYMLINK_POLICY:-skip}, checksum=$(label_bool "${CHECKSUM:-0}" on off), trash=$(label_bool "${MOVE_TO_TRASH:-0}" on off), delete guard=$(doctor_delete_guard_short)"
  return 0
}

# doctor_case_clashes_entry MODE LOCAL_PATH - scan one existing local tree
# through policy_case_clashes, appending its pairs to DOCTOR_CASE_CLASHES and
# counting them in the caller's `count` (collecting up to five samples).
doctor_case_clashes_entry() {
  local local_path="$2" pairs="" first="" second="" first_label="" second_label=""
  [[ -d "$local_path" ]] || return 0
  dirs=$((dirs + 1))
  pairs=${ policy_case_clashes "$local_path";} || pairs=""
  [[ -n "$pairs" ]] || return 0
  while IFS=$'\t' read -r first second; do
    [[ -n "$first" && -n "$second" ]] || continue
    count=$((count + 1))
    DOCTOR_CASE_CLASHES="${DOCTOR_CASE_CLASHES}${first}"$'\t'"${second}"$'\n'
    [[ "$count" -gt 5 ]] || {
      first_label=${ printable "$first";}
      second_label=${ printable "$second";}
      samples="${samples}${samples:+$'\n'}'${first_label}' / '${second_label}'"
    }
  done <<<"$pairs"
  return 0
}

# doctor_check_case_clashes - report local case-only collisions through
# policy_case_clashes (read-only and bounded per directory by
# POLICY_CASE_SCAN_LIMIT) together with the active CASE_CLASH_POLICY. Only
# runs when the manifest parsed into DOCTOR_ENTRIES has an existing local
# directory.
doctor_check_case_clashes() {
  local policy="${CASE_CLASH_POLICY:-exclude}" dirs=0 count=0 samples="" action=""
  local samples_label=""
  DOCTOR_CASE_CLASHES=""
  doctor_each_entry doctor_case_clashes_entry
  DOCTOR_CASE_CLASHES="${DOCTOR_CASE_CLASHES%$'\n'}"
  [[ "$dirs" -gt 0 ]] || return 0
  case "$policy" in
    exclude) action="excluded from sync" ;;
    rename) action="renamed to a (case conflict) name" ;;
    *) action="warned only" ;;
  esac
  if [[ "$count" -gt 0 ]]; then
    samples_label=${ doctor_name_hygiene_samples "$samples";}
    doctor_report_named "case clashes" WARN "case clashes: ${count} case-only collision(s) in ${dirs} local dir(s); CASE_CLASH_POLICY=${policy} (${action}): ${samples_label}"
  else
    doctor_report_named "case clashes" PASS "case clashes: no case-only collisions in ${dirs} local dir(s) (CASE_CLASH_POLICY=${policy})"
  fi
  return 0
}

# doctor_e2ee_paths_entry MODE LOCAL_PATH REMOTE NAME - run nc_e2ee_paths for
# one source (up to the caller's `limit`) and collect its folders into
# DOCTOR_E2EE_PATHS/count/samples. No-op once the limit is reached, matching
# the old `break`.
doctor_e2ee_paths_entry() {
  local remote="$3" path="" path_label=""
  [[ "$checked" -lt "$limit" ]] || return 0
  checked=$((checked + 1))
  POLICY_REMOTE_ROOT="$remote"
  POLICY_REMOTE_STYLE=collect
  POLICY_REMOTE_SINK=:
  policy_remote_paths_apply "$policy" nc_e2ee_paths e2ee DOCTOR_POLICY_EXCLUDES POLICY_REMOTE_COUNT
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    count=$((count + 1))
    DOCTOR_E2EE_PATHS="${DOCTOR_E2EE_PATHS}${path}"$'\n'
    [[ "$count" -gt 5 ]] || {
      path_label=${ printable "$path";}
      samples="${samples}${samples:+$'\n'}${path_label}"
    }
  done <<<"$POLICY_REMOTE_PATHS"
  return 0
}

# doctor_check_e2ee_paths - per-source end-to-end encryption report. Online,
# calls nc_e2ee_paths for the first DOCTOR_REMOTE_SCAN_LIMIT sources and
# reports the folders together with E2EE_POLICY; a non-Nextcloud remote only
# WARNs, and offline runs print the policy only. Never FAILs on a missing
# capability.
doctor_check_e2ee_paths() {
  local policy="${E2EE_POLICY:-exclude}" limit="${DOCTOR_REMOTE_SCAN_LIMIT:-5}"
  local checked=0 count=0 samples="" samples_label=""
  DOCTOR_E2EE_PATHS=""
  DOCTOR_E2EE_CHECKED=0
  if [[ "$DOCTOR_OFFLINE" -eq 1 ]]; then
    doctor_report_named "e2ee folders" PASS "e2ee: E2EE_POLICY=${policy} (offline; encrypted folders not scanned)"
    return 0
  fi
  remote_configured || return 0
  if ! doctor_remote_is_nextcloud; then
    doctor_report_named "e2ee folders" WARN "e2ee: remote '${RCLONE_REMOTE}:' is not a Nextcloud WebDAV remote; cannot scan for end-to-end encrypted folders (E2EE_POLICY=${policy})"
    return 0
  fi
  type nc_e2ee_paths >/dev/null 2>&1 || return 0
  doctor_each_entry doctor_e2ee_paths_entry
  DOCTOR_E2EE_PATHS="${DOCTOR_E2EE_PATHS%$'\n'}"
  DOCTOR_E2EE_CHECKED=$checked
  if [[ "$count" -gt 0 ]]; then
    samples_label=${ doctor_name_hygiene_samples "$samples";}
    doctor_report_named "e2ee folders" WARN "e2ee: ${count} end-to-end encrypted folder(s) in ${checked} source(s); E2EE_POLICY=${policy} (sciebo cannot decrypt E2EE folders): ${samples_label}"
  elif [[ "$checked" -gt 0 ]]; then
    doctor_report_named "e2ee folders" PASS "e2ee: no end-to-end encrypted folders in ${checked} source(s) (E2EE_POLICY=${policy})"
  else
    doctor_report_named "e2ee folders" PASS "e2ee: no sources to scan (E2EE_POLICY=${policy})"
  fi
  return 0
}

# doctor_external_storage_entry MODE LOCAL_PATH REMOTE NAME - run
# nc_external_paths for one source (up to the caller's `limit`) and collect
# its mounts into DOCTOR_EXTERNAL_PATHS/count/samples. No-op once the limit
# is reached, matching the old `break`.
doctor_external_storage_entry() {
  local remote="$3" path="" path_label=""
  [[ "$checked" -lt "$limit" ]] || return 0
  checked=$((checked + 1))
  # POLICY_REMOTE_* are read by policy_remote_paths_apply in lib/policy.sh,
  # which shellcheck cannot follow through sciebo_require_module.
  # shellcheck disable=SC2034  # read by policy_remote_paths_apply
  POLICY_REMOTE_ROOT="$remote"
  # shellcheck disable=SC2034  # read by policy_remote_paths_apply
  POLICY_REMOTE_STYLE=collect
  # shellcheck disable=SC2034  # read by policy_remote_paths_apply
  POLICY_REMOTE_SINK=:
  policy_remote_paths_apply "$policy" nc_external_paths external DOCTOR_POLICY_EXCLUDES POLICY_REMOTE_COUNT
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    count=$((count + 1))
    DOCTOR_EXTERNAL_PATHS="${DOCTOR_EXTERNAL_PATHS}${path}"$'\n'
    [[ "$count" -gt 5 ]] || {
      path_label=${ printable "$path";}
      samples="${samples}${samples:+$'\n'}${path_label}"
    }
  done <<<"$POLICY_REMOTE_PATHS"
  return 0
}

# doctor_check_external_storage - per-source external-storage report. Online,
# calls nc_external_paths for the first DOCTOR_REMOTE_SCAN_LIMIT sources and
# reports the mounts together with EXTERNAL_STORAGE_POLICY; a non-Nextcloud
# remote only WARNs, and offline runs print the policy only. No mounts and
# servers without oc:permissions are PASS, never FAIL.
doctor_check_external_storage() {
  local policy="${EXTERNAL_STORAGE_POLICY:-ask}" limit="${DOCTOR_REMOTE_SCAN_LIMIT:-5}"
  local checked=0 count=0 samples="" samples_label=""
  DOCTOR_EXTERNAL_PATHS=""
  DOCTOR_EXTERNAL_CHECKED=0
  if [[ "$DOCTOR_OFFLINE" -eq 1 ]]; then
    doctor_report_named "external storage" PASS "external storage: EXTERNAL_STORAGE_POLICY=${policy} (offline; mounts not scanned)"
    return 0
  fi
  remote_configured || return 0
  if ! doctor_remote_is_nextcloud; then
    doctor_report_named "external storage" WARN "external storage: remote '${RCLONE_REMOTE}:' is not a Nextcloud WebDAV remote; cannot scan for mounted external storages (EXTERNAL_STORAGE_POLICY=${policy})"
    return 0
  fi
  type nc_external_paths >/dev/null 2>&1 || return 0
  doctor_each_entry doctor_external_storage_entry
  DOCTOR_EXTERNAL_PATHS="${DOCTOR_EXTERNAL_PATHS%$'\n'}"
  DOCTOR_EXTERNAL_CHECKED=$checked
  if [[ "$count" -gt 0 ]]; then
    samples_label=${ doctor_name_hygiene_samples "$samples";}
    doctor_report_named "external storage" WARN "external storage: ${count} mounted external storage(s) in ${checked} source(s); EXTERNAL_STORAGE_POLICY=${policy}: ${samples_label}"
  elif [[ "$checked" -gt 0 ]]; then
    doctor_report_named "external storage" PASS "external storage: no mounted external storages in ${checked} source(s) (EXTERNAL_STORAGE_POLICY=${policy})"
  else
    doctor_report_named "external storage" PASS "external storage: no sources to scan (EXTERNAL_STORAGE_POLICY=${policy})"
  fi
  return 0
}

# doctor_check_delete_guard - report DELETE_FILES_THRESHOLD and ASK_DELETE,
# and whether an explicit MAX_DELETE cap (>= 0) overrides the guard. Pure
# settings inspection, no scan.
doctor_check_delete_guard() {
  local threshold="${DELETE_FILES_THRESHOLD:-100}" ask="${ASK_DELETE:-0}" max="${MAX_DELETE:--1}"
  case "$ask" in
    1)
      case "$max" in
        -1) doctor_report_named "delete guard" PASS "delete guard: ASK_DELETE=1, DELETE_FILES_THRESHOLD=${threshold} (runs stop after ${threshold} deletion(s) unless --yes)" ;;
        *) doctor_report_named "delete guard" PASS "delete guard: ASK_DELETE=1, DELETE_FILES_THRESHOLD=${threshold}, MAX_DELETE=${max} (explicit cap overrides the guard)" ;;
      esac
      ;;
    *) doctor_report_named "delete guard" PASS "delete guard: ASK_DELETE=0 (DELETE_FILES_THRESHOLD=${threshold} is not enforced)" ;;
  esac
  return 0
}

# doctor_check_quota - when QUOTA_WARN_PERCENT > 0, read the server quota
# once and report used/total against the threshold: WARN at or above it,
# PASS below, WARN when the quota cannot be read. The setting is off by
# default, so the check is silent then; offline runs report the threshold
# only. Never FAILs.
doctor_check_quota() {
  local threshold="${QUOTA_WARN_PERCENT:-0}" percent=""
  case "$threshold" in '' | *[!0-9]*) threshold=0 ;; esac
  [[ "$threshold" -gt 0 ]] || return 0
  if [[ "$DOCTOR_OFFLINE" -eq 1 ]]; then
    doctor_report_named quota PASS "quota: QUOTA_WARN_PERCENT=${threshold} (offline; server quota not read)"
    return 0
  fi
  have "$RCLONE_BIN" || return 0
  if ! type -t sync_quota_used_percent >/dev/null 2>&1; then
    doctor_report_named quota WARN "quota: quota probe unavailable in this build"
    return 0
  fi
  if ! percent="$(sync_quota_used_percent)"; then
    doctor_report_named quota WARN "quota: cannot read the server quota (${RCLONE_REMOTE}:; QUOTA_WARN_PERCENT=${threshold})"
    return 0
  fi
  if [[ "$percent" -ge "$threshold" ]]; then
    doctor_report_named quota WARN "quota: ${percent}% of ${RCLONE_REMOTE}: used (QUOTA_WARN_PERCENT=${threshold})"
  else
    doctor_report_named quota PASS "quota: ${percent}% of ${RCLONE_REMOTE}: used (below QUOTA_WARN_PERCENT=${threshold})"
  fi
  return 0
}

# doctor_big_folders_entry MODE LOCAL_PATH REMOTE NAME - measure one source
# (up to the caller's `scan_limit`) and record it in DOCTOR_BIG_FOLDER_OVER
# when it is over the caller's `limit_bytes`. No-op once the scan limit is
# reached, matching the old `break`.
doctor_big_folders_entry() {
  local remote="$3" name="$4" bytes="" spec=""
  [[ "$attempted" -lt "$scan_limit" ]] || return 0
  attempted=$((attempted + 1))
  spec=${ remote_spec "$remote";}
  if type -t sync_remote_size_lookup >/dev/null 2>&1; then
    # Looked up in this shell so the shared cache persists across sources.
    sync_remote_size_lookup "$spec" || return 0
    # shellcheck disable=SC2154  # out-param filled by sync_remote_size_lookup
    bytes="$SYNC_REMOTE_SIZE_BYTES"
  else
    bytes="$(doctor_remote_size_bytes "$spec")" || return 0
  fi
  measured=$((measured + 1))
  [[ "$bytes" -gt "$limit_bytes" ]] || return 0
  count=$((count + 1))
  DOCTOR_BIG_FOLDER_OVER="${DOCTOR_BIG_FOLDER_OVER}${name}"$'\t'"${remote}"$'\t'"${bytes}"$'\n'
  [[ "$count" -gt 5 ]] || samples="${samples}${samples:+$'\n'}${name} (${remote}): ${bytes} bytes"
  return 0
}

# doctor_check_big_folders - compare the first DOCTOR_REMOTE_SCAN_LIMIT
# sources against BIG_FOLDER_SIZE with one `rclone size --json` per distinct
# remote spec (online only) and report the sources over the limit with
# BIG_FOLDER_EXISTING_POLICY. The shared per-process size cache is reused
# when this process also loaded sync.sh, so duplicate/spec-equal sources are
# measured once; the per-entry rows and counters are unchanged. Silent when
# BIG_FOLDER_SIZE is empty.
doctor_check_big_folders() {
  local limit_raw="${BIG_FOLDER_SIZE:-}" limit_bytes="" limit_label="" policy="${BIG_FOLDER_EXISTING_POLICY:-warn}"
  local attempted=0 measured=0 count=0 samples="" samples_label=""
  local scan_limit="${DOCTOR_REMOTE_SCAN_LIMIT:-5}"
  DOCTOR_BIG_FOLDER_OVER=""
  DOCTOR_BIG_FOLDER_CHECKED=0
  [[ -n "$limit_raw" ]] || return 0
  limit_bytes=${ size_suffix_bytes "$limit_raw" 2>/dev/null;} || limit_bytes=""
  if [[ -z "$limit_bytes" ]]; then
    limit_label=${ printable "$limit_raw";}
    doctor_report_named "big folders" WARN "big folders: BIG_FOLDER_SIZE='${limit_label}' is not a valid size"
    return 0
  fi
  if [[ "$DOCTOR_OFFLINE" -eq 1 ]]; then
    doctor_report_named "big folders" PASS "big folders: BIG_FOLDER_SIZE=${limit_raw} (offline; remote sizes not checked; BIG_FOLDER_EXISTING_POLICY=${policy})"
    return 0
  fi
  have "$RCLONE_BIN" || return 0
  doctor_each_entry doctor_big_folders_entry
  DOCTOR_BIG_FOLDER_OVER="${DOCTOR_BIG_FOLDER_OVER%$'\n'}"
  DOCTOR_BIG_FOLDER_CHECKED=$measured
  if [[ "$count" -gt 0 ]]; then
    samples_label=${ doctor_name_hygiene_samples "$samples";}
    doctor_report_named "big folders" WARN "big folders: ${count} source(s) over BIG_FOLDER_SIZE=${limit_raw} (BIG_FOLDER_EXISTING_POLICY=${policy}): ${samples_label}"
  elif [[ "$measured" -gt 0 ]]; then
    doctor_report_named "big folders" PASS "big folders: ${measured} source(s) below BIG_FOLDER_SIZE=${limit_raw} (BIG_FOLDER_EXISTING_POLICY=${policy})"
  else
    doctor_report_named "big folders" PASS "big folders: no sources measured (BIG_FOLDER_SIZE=${limit_raw})"
  fi
  return 0
}

# doctor_quota_enabled - true when QUOTA_WARN_PERCENT asks for a quota check.
doctor_quota_enabled() {
  local threshold="${QUOTA_WARN_PERCENT:-0}"
  case "$threshold" in '' | *[!0-9]*) return 1 ;; esac
  [[ "$threshold" -gt 0 ]]
}

# doctor_quota_shared_probe - run the one `rclone about --json` call shared by
# doctor_check_runtime's quota line and doctor_check_quota, caching the parsed
# used/total in sync's quota globals so the QUOTA_WARN_PERCENT check reuses
# them instead of probing again. Sets DOCTOR_ABOUT_OK (1/0) and
# DOCTOR_ABOUT_OUT (the combined output, used as the failure detail). A
# result already cached by sync_quota_probe (ok or error) is reused as-is.
doctor_quota_shared_probe() {
  local json="" total="" used=""
  DOCTOR_ABOUT_OUT=""
  case "$SYNC_QUOTA_STATUS" in
    ok)
      DOCTOR_ABOUT_OK=1
      return 0
      ;;
    error)
      DOCTOR_ABOUT_OK=0
      return 0
      ;;
  esac
  if json="$(rclone_cmd about --json "${RCLONE_REMOTE}:" 2>&1)"; then
    DOCTOR_ABOUT_OK=1
    DOCTOR_ABOUT_OUT="$json"
    total="$(sync_about_number "$json" total)"
    used="$(sync_about_number "$json" used)"
    case "$total" in '' | *[!0-9]*) total="" ;; esac
    case "$used" in '' | *[!0-9]*) used="" ;; esac
    if [[ -n "$total" && "$total" -gt 0 && -n "$used" ]]; then
      SYNC_QUOTA_STATUS="ok"
      # shellcheck disable=SC2034  # read by sync_quota_used_percent in sync.sh
      SYNC_QUOTA_TOTAL="$total"
      # shellcheck disable=SC2034  # read by sync_quota_used_percent in sync.sh
      SYNC_QUOTA_USED="$used"
    else
      SYNC_QUOTA_STATUS="error"
    fi
  else
    DOCTOR_ABOUT_OK=0
    DOCTOR_ABOUT_OUT="$json"
    SYNC_QUOTA_STATUS="error"
  fi
  return 0
}

# doctor_check_reachability - the reachability stage of doctor_check_runtime:
# offline prints the skip notice (unless JSON output must stay clean), online
# verifies the remote with `rclone lsd` (PASS with the error detail sanitized
# on failure). Returns 1 when rclone is missing online, which
# doctor_check_runtime turns into a clean stop of the quota/launchd stages
# (see its comment); it must never abort the whole doctor run.
doctor_check_reachability() {
  local lsd_err=""
  if [[ "$DOCTOR_OFFLINE" -eq 1 ]]; then
    [[ "$DOCTOR_JSON" -eq 1 ]] || log "offline mode: skipping network checks"
    return 0
  fi
  have "$RCLONE_BIN" || return
  if lsd_err="$(rclone_cmd lsd "${RCLONE_REMOTE}:" 2>&1 >/dev/null)"; then
    doctor_report PASS "remote '${RCLONE_REMOTE}:' is reachable (rclone lsd)"
  else
    doctor_report FAIL "cannot reach remote '${RCLONE_REMOTE}:' via rclone lsd: $(printf '%s' "$lsd_err" | sanitize_stream)"
  fi
  return 0
}

# doctor_check_quota_probe - the quota stage of doctor_check_runtime: with
# QUOTA_WARN_PERCENT asking for the check, run the one shared `rclone about`
# probe so doctor_check_quota reports the cached bytes with no second call,
# otherwise probe plainly; PASS when the about succeeds, WARN with the
# sanitized error otherwise. Online only — the offline path printed the skip
# notice in doctor_check_reachability and never touches the server.
doctor_check_quota_probe() {
  local about_out=""
  if [[ "$DOCTOR_OFFLINE" -eq 1 ]]; then
    return 0
  fi
  if doctor_quota_enabled && type -t sync_quota_used_percent >/dev/null 2>&1; then
    # The quota check needs the same server probe; run it once here and let
    # doctor_check_quota report the cached result with no second call.
    doctor_quota_shared_probe
    about_out="$DOCTOR_ABOUT_OUT"
    if [[ "$DOCTOR_ABOUT_OK" -eq 1 ]]; then
      doctor_report PASS "quota info available (rclone about)"
    else
      doctor_report WARN "rclone about failed: $(printf '%s' "$about_out" | sanitize_stream)"
    fi
  elif about_out="$(rclone_cmd about "${RCLONE_REMOTE}:" 2>&1)"; then
    doctor_report PASS "quota info available (rclone about)"
  else
    doctor_report WARN "rclone about failed: $(printf '%s' "$about_out" | sanitize_stream)"
  fi
}

# doctor_check_launchd_agent - the launchd stage of doctor_check_runtime:
# report the agent plist/loaded state (missing plist WARN, old entrypoint
# WARN, loaded PASS), but only when launchd is the active scheduler backend —
# the other backends get no line here.
doctor_check_launchd_agent() {
  local plist=""
  [[ "$(platform_scheduler_backend)" == "launchd" ]] || return 0
  plist="${HOME}/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"
  if [[ ! -f "$plist" ]]; then
    doctor_report WARN "launchd agent not installed ('make schedule-install')"
    return
  fi
  grep -q 'bin/sciebo' "$plist" 2>/dev/null || doctor_report WARN "launchd plist still runs the old scripts/sync.sh entrypoint; re-run '${CLI_NAME} schedule install'"
  if launchctl print "gui/${UID}/${LAUNCHD_LABEL}" >/dev/null 2>&1; then doctor_report PASS "launchd agent '${LAUNCHD_LABEL}' is installed and loaded"; else doctor_report WARN "launchd plist exists but agent '${LAUNCHD_LABEL}' is not loaded; re-run '${CLI_NAME} schedule install'"; fi
}

# doctor_check_runtime - the network/runtime checklist stage, in its original
# line order: reachability (or the offline skip notice), the quota line, then
# the launchd agent report. The stages are plain calls, and a missing rclone
# online still skips the quota and launchd lines the way the single function's
# `return` did - but the status must not escape: cmd_doctor runs under errexit,
# so returning non-zero here aborted the checklist before the policies, quota,
# and big-folder stages and before the pass/warn/fail summary (or the JSON
# document) could print.
doctor_check_runtime() {
  doctor_check_reachability || return 0
  doctor_check_quota_probe
  doctor_check_launchd_agent
}

cmd_doctor() {
  opt_begin "offline:b json:b" doctor "" "$@"
  opt_guard doctor
  # Desktop-parity policy helpers (the shared remote-path gate).
  sciebo_require_module policy policy_case_clashes
  # The capabilities summary and the DAV/OCS probes use the nc_api/http and
  # capabilities helpers; load them on demand.
  sciebo_require_module http xml_get
  sciebo_require_module nc_api nc_dav_request_allow
  sciebo_require_module capabilities capabilities_load
  # The quota and big-folder checks reuse sync's probes (sync_quota_used_percent,
  # sync_remote_size_lookup); both are guarded by `type -t` below, so load the
  # module on demand instead of silently skipping the checks. Sourcing
  # commands/sync now only defines its functions (its own dependencies load
  # inside cmd_sync), so nothing else arrives transitively — these helpers
  # need only the eagerly loaded rclone.sh and sync.sh internals.
  sciebo_require_module commands/sync sync_quota_used_percent
  # The keychain/backend/network/runtime checks and the manifest checks use
  # the keychain/platform/manifest helpers; they load here (after the
  # --help exit) so none of the checks silently degrades to a skipped
  # `type` probe when the module has not been loaded yet. lock.sh loads for
  # pid_alive, which doctor_check_watch shares with watch's own guard.
  sciebo_require_module keychain keychain_backend
  sciebo_require_module platform platform_os
  sciebo_require_module manifest manifest_each
  sciebo_require_module lock pid_alive
  DOCTOR_OFFLINE=0
  opt_into DOCTOR_OFFLINE offline 1
  DOCTOR_JSON=0
  opt_into DOCTOR_JSON json 1
  DOCTOR_LINES=""
  DOCTOR_CAPABILITIES_AVAILABLE=0
  DOCTOR_CAPABILITIES_PROBED=0
  DOCTOR_NAME_HYGIENE_SCANNED=0
  DOCTOR_NAME_HYGIENE_INVALID=0
  DOCTOR_NAME_HYGIENE_COLLISIONS=0
  DOCTOR_NAME_HYGIENE_PATHS=""
  DOCTOR_CASE_CLASHES=""
  DOCTOR_CONFLICTS_SCANNED=0
  DOCTOR_CONFLICT_COUNT=0
  DOCTOR_CONFLICT_SAMPLES=""
  DOCTOR_E2EE_PATHS=""
  DOCTOR_E2EE_CHECKED=0
  DOCTOR_EXTERNAL_PATHS=""
  DOCTOR_EXTERNAL_CHECKED=0
  DOCTOR_BIG_FOLDER_OVER=""
  DOCTOR_BIG_FOLDER_CHECKED=0
  # A configured TLS file that is missing or unreadable must be reported as a
  # FAIL, not abort load_settings: tolerate it here and let
  # doctor_check_tls_client explain it.
  export SCIEBO_SKIP_FILE_CHECKS=1
  if rclone_available; then load_settings; else load_settings --no-rclone; fi
  doctor_check_rclone
  # ensure_state_dirs can log (first-time state initialization); JSON mode
  # must emit nothing but the document.
  if [[ "$DOCTOR_JSON" -eq 1 ]]; then
    ensure_state_dirs >/dev/null
  else
    ensure_state_dirs
  fi
  # Probe with mktemp, not a fixed name: a planted symlink called
  # .doctor-write-test in STATE_DIR would be followed by a bare touch. The
  # unique probe file is removed right away; the PASS/FAIL wording is
  # unchanged.
  local write_probe=""
  write_probe="$(mktemp "${STATE_DIR}/.doctor-write-test.XXXXXX" 2>/dev/null || true)"
  if [[ -n "$write_probe" ]]; then
    rm -f "$write_probe"
    doctor_report PASS "state dir is writable (${STATE_DIR})"
  else
    doctor_report FAIL "state dir is not writable (${STATE_DIR})"
  fi
  doctor_check_free_space
  doctor_check_capabilities
  doctor_check_e2ee
  doctor_check_backends
  doctor_check_keychain
  doctor_check_secret_permissions
  doctor_check_proxy
  doctor_check_tls_client
  doctor_check_server_exclude
  doctor_check_manifest
  doctor_check_name_hygiene
  doctor_check_conflicts
  doctor_check_watch
  doctor_check_network
  doctor_check_runtime
  doctor_check_policies
  doctor_check_case_clashes
  doctor_check_e2ee_paths
  doctor_check_external_storage
  doctor_check_delete_guard
  doctor_check_quota
  doctor_check_big_folders
  if [[ "$DOCTOR_JSON" -eq 1 ]]; then
    doctor_print_json
  else
    printf '\n%d passed, %d warning(s), %d failure(s)\n' "$DOCTOR_PASS_COUNT" "$DOCTOR_WARN_COUNT" "$DOCTOR_FAIL_COUNT"
  fi
  [[ "$DOCTOR_FAIL_COUNT" -eq 0 ]]
}
