#!/bin/bash
# verify.sh command module - read-only consistency check with rclone check.
# verify never transfers, deletes, takes the run lock, or writes logs; sync
# entries are checked local -> remote, pull entries remote -> local, and
# bisync entries two-way.

VERIFY_DOWNLOAD=false
VERIFY_SIZE_ONLY=false
VERIFY_QUIET=false
VERIFY_TOTAL=0
VERIFY_OK=0
VERIFY_FAILED=0
VERIFY_SKIPPED=0
# Output lines shown per failed entry.
VERIFY_MAX_OUTPUT=5
# rclone argument vector for the entry being checked (verify_build_args).
VERIFY_ARGS=()

usage_verify() {
  usage_emit <<'EOF'
Usage: sciebo verify [options]

Check that every configured source matches its destination with
`rclone check`. verify changes nothing: it never transfers, deletes, or
writes logs. Sync sources are checked local -> remote, pull sources
remote -> local, and bisync sources two-way.

Options:
  --only NAME   check only the source with this sanitized name (see
                `sciebo list`)
  --download    download remote files and hash them (slow, catches
                server-side corruption)
  --size-only   compare sizes only, skip hashes
  --quiet       only print failures and the summary
  -h, --help    show this help
EOF
}

# verify_strip_ansi LINE - drop ANSI escape sequences (ESC '[' parameters
# letter) so captured rclone output stays readable. Pure bash and byte-wise
# (LC_ALL=C), so callers can capture it with ${ ...;} without forking sed per
# line; a sequence the old sed did not match is likewise left intact.
verify_strip_ansi() {
  local s="${1:-}" out="" i=0 n=0 c="" j=0
  local LC_ALL=C
  n=${#s}
  while ((i < n)); do
    c="${s:i:1}"
    if [[ "$c" == $'\033' && "${s:i+1:1}" == "[" ]]; then
      j=$((i + 2))
      while ((j < n)) && [[ "${s:j:1}" == [+0-9\;?] ]]; do
        j=$((j + 1))
      done
      if ((j < n)) && [[ "${s:j:1}" == [A-Za-z] ]]; then
        i=$((j + 1))
        continue
      fi
    fi
    out+="$c"
    i=$((i + 1))
  done
  printf '%s' "$out"
}

# verify_print_output OUTPUT - print up to VERIFY_MAX_OUTPUT output lines,
# ANSI-stripped and indented, so the user sees which files differ.
verify_print_output() {
  local output="$1" line="" shown=0 p_line=""
  [[ -n "$output" ]] || return 0
  while IFS= read -r line && [[ "$shown" -lt "$VERIFY_MAX_OUTPUT" ]]; do
    p_line=${ verify_strip_ansi "$line";}
    printf '     %s\n' "$p_line"
    shown=$((shown + 1))
  done <<<"$output"
}

# verify_counts OUTPUT - print " (N differences, M errors)" when the rclone
# check output reports them; empty when neither is present. One pure-bash pass
# over the output keeps the last occurrence of each counter (the old
# grep|tail pair forked twice per failed entry).
verify_counts() {
  local output="$1" line="" work="" differences="" errors=""
  while IFS= read -r line; do
    work="$line"
    while [[ "$work" =~ ([0-9]+)\ differences\ found|([0-9]+)\ errors ]]; do
      if [[ -n "${BASH_REMATCH[1]}" ]]; then
        differences="${BASH_REMATCH[1]}"
      else
        errors="${BASH_REMATCH[2]}"
      fi
      work="${work#*"${BASH_REMATCH[0]}"}"
    done
  done <<<"$output"
  [[ -n "$differences" && "$differences" != "0" ]] || differences=""
  if [[ -n "$differences" && -n "$errors" ]]; then
    printf ' (%s differences, %s errors)' "$differences" "$errors"
  elif [[ -n "$differences" ]]; then
    printf ' (%s differences)' "$differences"
  elif [[ -n "$errors" ]]; then
    printf ' (%s errors)' "$errors"
  fi
}

# verify_entry_status STATUS [DETAIL] [OUTPUT] - one status row plus up to
# VERIFY_MAX_OUTPUT output lines on failure; OK and SKIP rows are suppressed
# by --quiet, FAIL always prints. DETAIL is appended to the row.
verify_entry_status() {
  local status="$1" detail="${2:-}" output="${3:-}" spec=""
  if [[ "$status" != FAIL && "$VERIFY_QUIET" == true ]]; then return 0; fi
  spec=${ remote_spec "$ENTRY_REMOTE";}
  printf '%-4s %-6s %-28s %s%s\n' "$status" "$ENTRY_MODE" "$ENTRY_NAME" "$spec" "$detail"
  [[ "$status" != FAIL ]] || verify_print_output "$output"
}

# verify_prepare SPEC - local-directory and bisync remote-dir guards.
# Returns 0=check, 1=failed, 2=skipped. Prints its own status lines.
verify_prepare() {
  local spec="$1"
  if [[ "$ENTRY_MODE" == bisync ]] && ! remote_dir_exists "$spec"; then
    verify_entry_status SKIP " (remote dir does not exist)"
    return 2
  fi
  [[ ! -d "$ENTRY_LOCAL" ]] || return 0
  if [[ "$ENTRY_MODE" == pull ]]; then
    verify_entry_status SKIP " (local dir does not exist yet)"
    return 2
  fi
  verify_entry_status FAIL " (local directory does not exist: ${ENTRY_LOCAL})"
  return 1
}

# verify_build_args SRC DST - fill VERIFY_ARGS for the entry currently
# parsed into ENTRY_*.
verify_build_args() {
  local src="$1" dst="$2"
  local -a flags=(
    --checkers "$CHECKERS"
    --retries "$RETRIES" --low-level-retries "$LOW_LEVEL_RETRIES"
    --timeout "$TIMEOUT" --contimeout "$CONTIMEOUT"
    --filter-from "${FILTER_DIR}/clutter.txt"
  )
  [[ -z "${RETRIES_SLEEP:-}" ]] || flags+=(--retries-sleep "$RETRIES_SLEEP")
  [[ -z "$ENTRY_FILTER" ]] || flags+=(--filter-from "${FILTER_DIR}/${ENTRY_FILTER}")
  if [[ "$ENTRY_MODE" != bisync ]]; then
    flags+=(--one-way --exclude-if-present .nosync)
  fi
  [[ "$VERIFY_SIZE_ONLY" == false ]] || flags+=(--size-only)
  [[ "$VERIFY_DOWNLOAD" == false ]] || flags+=(--download)
  VERIFY_ARGS=(check "$src" "$dst" "${flags[@]}")
}

# verify_run_entry - check the entry currently parsed into ENTRY_*; returns
# 0=ok, 1=failed, 2=skipped. Prints its own status lines.
verify_run_entry() {
  local spec="" src="" dst="" output="" detail="" rc=0
  spec=${ remote_spec "$ENTRY_REMOTE";}
  rc=0
  verify_prepare "$spec" || rc=$?
  [[ "$rc" -eq 0 ]] || return "$rc"
  case "$ENTRY_MODE" in
    pull) src="${spec}/" dst="${ENTRY_LOCAL}/" ;;
    *) src="${ENTRY_LOCAL}/" dst="${spec}/" ;;
  esac
  verify_build_args "$src" "$dst"
  output="$(rclone_cmd "${VERIFY_ARGS[@]}" 2>&1)" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    verify_entry_status OK
    return 0
  fi
  detail=${ verify_counts "$output";}
  [[ -n "$detail" ]] || detail=" (rclone check failed, exit ${rc})"
  verify_entry_status FAIL "$detail" "$output"
  return 1
}

# verify_process_line LINE [ONLY] - validate and check one manifest line.
# Increments VERIFY_TOTAL/VERIFY_OK/VERIFY_FAILED/VERIFY_SKIPPED; a parse
# error fails the entry, an entry filtered out by ONLY is counted as skipped
# without a row.
verify_process_line() {
  local line="$1" only="${2:-}" rc=0
  if ! manifest_parse_line "$line"; then
    VERIFY_TOTAL=$((VERIFY_TOTAL + 1))
    VERIFY_FAILED=$((VERIFY_FAILED + 1))
    verify_entry_status FAIL " (${ENTRY_ERROR})"
    return 0
  fi
  if [[ -n "$only" && "$ENTRY_NAME" != "$only" ]]; then
    VERIFY_SKIPPED=$((VERIFY_SKIPPED + 1))
    return 0
  fi
  VERIFY_TOTAL=$((VERIFY_TOTAL + 1))
  rc=0
  verify_run_entry || rc=$?
  case "$rc" in
    0) VERIFY_OK=$((VERIFY_OK + 1)) ;;
    2) VERIFY_SKIPPED=$((VERIFY_SKIPPED + 1)) ;;
    *) VERIFY_FAILED=$((VERIFY_FAILED + 1)) ;;
  esac
}

cmd_verify() {
  local only="" line="" summary=""
  opt_begin "only:s download:b size-only:b quiet:b" verify "" "$@"
  opt_guard verify
  # Run dependencies load after opt_guard's --help exit, so
  # `sciebo verify --help` parses none of them.
  only="${OPT_only:-}"
  VERIFY_DOWNLOAD=false
  opt_into VERIFY_DOWNLOAD download
  VERIFY_SIZE_ONLY=false
  opt_into VERIFY_SIZE_ONLY size_only
  VERIFY_QUIET=false
  opt_into VERIFY_QUIET quiet
  load_settings
  require_remote
  manifest_index_load
  if [[ -n "$only" ]]; then
    manifest_require_name "$only"
  fi
  VERIFY_TOTAL=0 VERIFY_OK=0 VERIFY_FAILED=0 VERIFY_SKIPPED=0
  while IFS= read -r line; do
    verify_process_line "$line" "$only"
  done < <(manifest_lines)
  summary="Summary: ${VERIFY_TOTAL} sources (${VERIFY_OK} ok, ${VERIFY_FAILED} failed, ${VERIFY_SKIPPED} skipped)"
  printf '%s\n' "$summary"
  [[ "$VERIFY_FAILED" -eq 0 ]]
}
