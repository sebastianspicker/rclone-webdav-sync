#!/bin/bash
# doctor.sh command module - preflight checks with a PASS/WARN/FAIL report.

DOCTOR_OFFLINE=0
DOCTOR_PASS_COUNT=0
DOCTOR_WARN_COUNT=0
DOCTOR_FAIL_COUNT=0

usage_doctor() {
  cat <<'EOF'
Usage: sciebo doctor [--offline]

Run preflight checks and print PASS/WARN/FAIL lines plus a summary.
Exits 1 if any check fails, 0 otherwise.

Checks: rclone availability and version, rclone config and remote,
remote type/url/vendor, state directories, filter files (parsed by
rclone), the manifest set (duplicate names/remotes and overlapping local
directories), network reachability, and the launchd agent.

Options:
  --offline   skip network checks (rclone lsd/about)
  -h, --help  show this help
EOF
}

# doctor_report LEVEL MESSAGE... - print "<LEVEL>  message" and count it.
doctor_report() {
  local level="$1" counter="DOCTOR_${1}_COUNT"
  shift
  printf -v "$counter" '%s' "$((${!counter} + 1))"
  printf '%-5s %s\n' "$level" "$*"
}

# doctor_report_remote KEY WANT GOOD BAD SHOW - report one config key.
doctor_report_remote() {
  local got
  got="$(config_value "$1" "$5")"
  if [[ "$got" == "$2" ]]; then
    doctor_report "$3" "remote $1 is $2"
  else
    doctor_report "$4" "remote $1 is '${got:-<unset>}' (expected $2)"
  fi
}

# Resolve missing trailing components against the nearest existing parent.
doctor_normalize_local() {
  local p="$1" tail="" resolved
  p="${p%/}"
  [[ -n "$p" ]] || p="/"
  while [[ ! -d "$p" && "$p" != "/" ]]; do
    tail="/$(basename "$p")${tail}"
    p="$(dirname "$p")"
  done
  resolved="$(cd "$p" 2>/dev/null && pwd -P)" || resolved="$p"
  printf '%s%s' "${resolved%/}" "$tail"
}

doctor_check_rclone() {
  local line="" version="" major="" minor="" show="" url=""
  have "$RCLONE_BIN" && line="$("$RCLONE_BIN" version 2>/dev/null | sed -n '1p' || true)"
  if [[ -z "$line" ]]; then
    doctor_report FAIL "rclone not found (${RCLONE_BIN})"
  else
    version="${line#rclone v}"
    major="${version%%.*}"
    minor="${version#*.}"
    minor="${minor%%.*}"
    if [[ -z "$major" || -z "$minor" || "$major" == *[!0-9]* || "$minor" == *[!0-9]* ]]; then
      doctor_report FAIL "cannot parse rclone version from '${line}'"
    elif [[ "$major" -gt 1 || ("$major" -eq 1 && "$minor" -ge 65) ]]; then
      doctor_report PASS "rclone ${version} found (>= 1.65)"
    else
      doctor_report FAIL "rclone ${version} is too old; need >= 1.65"
    fi
  fi
  if [[ -f "$RCLONE_CONFIG" ]]; then
    doctor_report PASS "rclone config file exists (${RCLONE_CONFIG})"
  else
    doctor_report FAIL "rclone config file missing (${RCLONE_CONFIG}); run '${CLI_NAME} setup'"
  fi
  if remote_configured; then
    doctor_report PASS "remote '${RCLONE_REMOTE}:' is listed in the rclone config"
  else
    doctor_report FAIL "remote '${RCLONE_REMOTE}:' not found; run '${CLI_NAME} setup'"
  fi
  show="$(remote_config_show)"
  doctor_report_remote type webdav PASS FAIL "$show"
  doctor_report_remote vendor nextcloud PASS WARN "$show"
  url="$(config_value url "$show")"
  case "$url" in
    *"/remote.php/dav/files/"*)
      doctor_report PASS "remote url contains /remote.php/dav/files/ (chunked uploads enabled)"
      ;;
    *)
      doctor_report WARN "remote url '${url:-<unset>}' lacks /remote.php/dav/files/ (chunked uploads disabled); re-run '${CLI_NAME} setup'"
      ;;
  esac
}
# Filters (via --filter-from) plus manifest entries, duplicates, overlaps.
doctor_check_manifest() {
  local filter="" checked=0 failures=0
  if [[ ! -f "${FILTER_DIR}/clutter.txt" ]]; then
    doctor_report FAIL "filter file missing (${FILTER_DIR}/clutter.txt)"
  elif have "$RCLONE_BIN"; then
    while IFS= read -r filter; do
      checked=$((checked + 1))
      if ! rclone_cmd --dump filters --filter-from "$filter" lsf "$FILTER_DIR" >/dev/null 2>&1; then
        doctor_report FAIL "rclone rejects filter file ${filter}"
        failures=$((failures + 1))
      fi
    done < <(find "$FILTER_DIR" -maxdepth 1 -type f -name '*.txt' 2>/dev/null | LC_ALL=C sort)
    if [[ "$checked" -eq 0 ]]; then
      doctor_report FAIL "no *.txt filter files found in ${FILTER_DIR}"
    elif [[ "$failures" -eq 0 ]]; then
      doctor_report PASS "rclone filter validation passed (${checked} file(s))"
    fi
  fi
  local file="" line="" mode="" local_path="" remote="" name="" dup="" normalized=""
  local valid=0 invalid=0 entries="" a_local="" a_remote="" b_local="" b_remote=""
  while IFS= read -r file; do
    [[ -f "$file" ]] || continue
    while IFS= read -r line; do
      if manifest_parse_line "$line"; then
        valid=$((valid + 1))
        entries="${entries}${ENTRY_MODE}|${ENTRY_LOCAL}|${ENTRY_REMOTE}|${ENTRY_NAME}"$'\n'
      else
        invalid=$((invalid + 1))
        doctor_report FAIL "${file##*/}: invalid entry '$(printable "$line")': ${ENTRY_ERROR}"
      fi
    done < <(config_lines "$file")
  done < <(manifest_files)
  if [[ "$valid" -eq 0 ]]; then
    doctor_report WARN "no valid manifest entries (nothing will be synced)"
  elif [[ "$invalid" -eq 0 ]]; then
    doctor_report PASS "manifests parsed (${valid} valid entries)"
  fi
  manifest_index_invalidate
  manifest_index_load
  while IFS= read -r dup; do [[ -z "$dup" ]] || doctor_report FAIL "duplicate source name '${dup}'; logs and bisync state would collide (rename one entry)"; done <<<"$MANIFEST_DUP_NAMES"
  while IFS= read -r dup; do [[ -z "$dup" ]] || doctor_report WARN "duplicate remote subdir '$(printable "$dup")' is used by more than one entry"; done <<<"$MANIFEST_DUP_REMOTES"
  # Normalize every local path once while checking local dirs, then compare.
  while IFS='|' read -r mode local_path remote name; do
    [[ -n "$mode" ]] || continue
    if [[ "$mode" != pull && ! -d "$local_path" ]]; then
      doctor_report WARN "${mode} entry '$(printable "$remote")': local dir ${local_path} does not exist (created on first run)"
    fi
    if [[ "$mode" == bisync ]] && ! bisync_initialized "$name"; then
      doctor_report WARN "bisync entry '$(printable "$remote")': not initialized; run 'make bisync-resync' first"
    fi
    normalized="${normalized}${mode}|$(doctor_normalize_local "$local_path")|${remote}|${name}"$'\n'
  done <<<"$entries"
  while IFS='|' read -r _ a_local a_remote _; do
    while IFS='|' read -r _ b_local b_remote _; do
      [[ "${a_local}/" != "${b_local}"/?* ]] || doctor_report WARN "overlapping sources: '$(printable "$a_remote")' (${a_local}) is inside '$(printable "$b_remote")' (${b_local})"
    done <<<"${normalized%$'\n'}"
  done <<<"${normalized%$'\n'}"
}
# Reachability checks (offline/unavailable rclone skip) plus the launchd agent.
doctor_check_runtime() {
  local lsd_err="" about_out="" plist="${HOME}/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"
  if [[ "$DOCTOR_OFFLINE" -eq 1 ]]; then
    log "offline mode: skipping network checks"
  else
    have "$RCLONE_BIN" || return
    if lsd_err="$(rclone_cmd lsd "${RCLONE_REMOTE}:" 2>&1 >/dev/null)"; then
      doctor_report PASS "remote '${RCLONE_REMOTE}:' is reachable (rclone lsd)"
    else
      doctor_report FAIL "cannot reach remote '${RCLONE_REMOTE}:' via rclone lsd: ${lsd_err}"
    fi
    if about_out="$(rclone_cmd about "${RCLONE_REMOTE}:" 2>&1)"; then
      doctor_report PASS "quota info available (rclone about)"
    else
      doctor_report WARN "rclone about failed: ${about_out}"
    fi
  fi
  if [[ ! -f "$plist" ]]; then
    doctor_report WARN "launchd agent not installed ('make schedule-install')"
    return
  fi
  grep -q 'bin/sciebo' "$plist" 2>/dev/null || doctor_report WARN "launchd plist still runs the old scripts/sync.sh entrypoint; re-run '${CLI_NAME} schedule install'"
  if launchctl print "gui/${UID}/${LAUNCHD_LABEL}" >/dev/null 2>&1; then doctor_report PASS "launchd agent '${LAUNCHD_LABEL}' is installed and loaded"; else doctor_report WARN "launchd plist exists but agent '${LAUNCHD_LABEL}' is not loaded; re-run '${CLI_NAME} schedule install'"; fi
}

cmd_doctor() {
  opt_reset offline
  opt_parse "offline:b" doctor "" "$@"
  if [[ "$OPT_HELP" -ne 0 ]]; then usage_doctor && exit 0; fi
  [[ -z "$OPT_EXTRA" ]] || usage_error doctor "unknown option: ${OPT_EXTRA%%$'\n'*}"
  DOCTOR_OFFLINE=0
  [[ -z "${OPT_offline:-}" ]] || DOCTOR_OFFLINE=1
  if have rclone || [[ -x /opt/homebrew/bin/rclone ]] || [[ -x /usr/local/bin/rclone ]]; then load_settings; else load_settings --no-rclone; fi
  doctor_check_rclone
  ensure_state_dirs
  if touch "${STATE_DIR}/.doctor-write-test" 2>/dev/null; then
    rm -f "${STATE_DIR}/.doctor-write-test"
    doctor_report PASS "state dir is writable (${STATE_DIR})"
  else
    doctor_report FAIL "state dir is not writable (${STATE_DIR})"
  fi
  doctor_check_manifest
  doctor_check_runtime
  printf '\n%d passed, %d warning(s), %d failure(s)\n' "$DOCTOR_PASS_COUNT" "$DOCTOR_WARN_COUNT" "$DOCTOR_FAIL_COUNT"
  [[ "$DOCTOR_FAIL_COUNT" -eq 0 ]]
}
