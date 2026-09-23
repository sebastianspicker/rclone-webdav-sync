#!/bin/bash
# status.sh command module - last-run status per source.
# Read-only: status never takes the run lock or writes logs. The only write
# is removing an expired pause marker (through pause_describe).

STATUS_QUIET=false
STATUS_TOTAL=0
STATUS_OK=0
STATUS_FAILED=0
STATUS_IDLE=0
# History records to print under each row (0 when --history is absent).
STATUS_HISTORY_N=0
# True when --history was given; --history --quiet prints nothing.
STATUS_HISTORY_ON=false
# Characters shown from a record's detail field.
STATUS_DETAIL_MAX=60

usage_status() {
  usage_emit <<'EOF'
Usage: sciebo status [options]

Show the pause state and the last recorded run per configured source:
name, mode, state, when it ran, and details (exit code and conflicts, or
the recorded reason). Sources that never ran show `never`. Read-only:
status never takes the run lock or writes logs.

Options:
  --only NAME    show only the source with this sanitized name (see
                 `sciebo list`)
  --history [N]  after each row, print its last N (default 10) recorded
                 runs; combined with --quiet, nothing is printed
  --json         print the pause state and one row per source as a single
                 JSON document (cannot be combined with --watch)
  --watch [N]    refresh the report every N seconds (default 5) until
                 interrupted with INT/TERM
  --quiet        only print rows that need attention, plus the summary
  -h, --help     show this help
EOF
}

# status_read_state NAME - fill RUNSTATE_* from NAME's record. rc 1 with
# the status fields empty when runstate.sh is absent or has no record.
status_read_state() {
  RUNSTATE_STATUS="" RUNSTATE_STAMP="" RUNSTATE_RC=""
  RUNSTATE_CONFLICTS="" RUNSTATE_LOG="" RUNSTATE_DETAIL=""
  type runstate_read >/dev/null 2>&1 || return 1
  runstate_read "$1" || return 1
  return 0
}

# status_detail - the DETAIL column for the record just read: rc and
# conflicts when either is non-zero, otherwise the recorded detail,
# truncated to STATUS_DETAIL_MAX characters.
status_detail() {
  local detail="" rc="${RUNSTATE_RC:-0}" conflicts="${RUNSTATE_CONFLICTS:-0}"
  if [[ "$rc" != "0" || "$conflicts" != "0" ]]; then
    detail="rc=${rc} conflicts=${conflicts}"
  else
    detail="${RUNSTATE_DETAIL:-}"
  fi
  detail=${ printable "$detail";}
  [[ "${#detail}" -le "$STATUS_DETAIL_MAX" ]] || detail="${detail:0:$STATUS_DETAIL_MAX}"
  printf '%s' "$detail"
}

# status_print_row NAME MODE STATE WHEN DETAIL - one status row; OK rows
# are suppressed by --quiet (rc 1 then, so callers can skip row extras).
status_print_row() {
  if [[ "$STATUS_QUIET" == true && "$3" == "OK" ]]; then
    return 1
  fi
  printf '%-28s %-6s %-8s %-19s %s\n' "$1" "$2" "$3" "$4" "$5"
  return 0
}

# status_print_history NAME N - indented recent history records for NAME
# (newest first). Prints nothing when the history module is absent or the
# source has no history; never fails.
status_print_history() {
  local name="$1" limit="$2" line=""
  type runstate_history >/dev/null 2>&1 || return 0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    printf '    history: %s\n' "$line"
  done < <(runstate_history "$name" "$limit")
  return 0
}

# status_name_is NAME - non-zero (stop) when the parsed entry is NAME.
status_name_is() {
  [[ "${ENTRY_NAME:-}" != "$1" ]]
}

# status_has_name NAME - true when a valid manifest entry parses to NAME.
status_has_name() {
  if manifest_each status_name_is "$1"; then
    return 1
  fi
  return 0
}

# status_process_line LINE [ONLY] - validate and print one manifest entry.
# Counts tracked sources; INVALID rows are skipped when ONLY filters them
# out. A printed row is followed by its history records when --history is
# active.
status_process_line() {
  local line="$1" only="${2:-}" name="" mode="" state="" when="-" detail="" log=""
  local log_disp=""
  if ! manifest_parse_line "$line"; then
    if [[ -z "$only" ]]; then
      status_print_row "INVALID" "-" "-" "-" "$ENTRY_ERROR"
    fi
    return 0
  fi
  if [[ -n "$only" && "$ENTRY_NAME" != "$only" ]]; then
    return 0
  fi
  STATUS_TOTAL=$((STATUS_TOTAL + 1))
  name="$ENTRY_NAME"
  mode="$ENTRY_MODE"
  state="never"
  if status_read_state "$name"; then
    if [[ -n "$RUNSTATE_STATUS" ]]; then
      state="${RUNSTATE_STATUS^^}"
      state=${ printable "$state";}
    fi
    [[ -z "$RUNSTATE_STAMP" ]] || when="$RUNSTATE_STAMP"
    when=${ printable "$when";}
  fi
  detail=${ status_detail;}
  case "$RUNSTATE_STATUS" in
    ok) STATUS_OK=$((STATUS_OK + 1)) ;;
    failed) STATUS_FAILED=$((STATUS_FAILED + 1)) ;;
    *) STATUS_IDLE=$((STATUS_IDLE + 1)) ;;
  esac
  if status_print_row "$name" "$mode" "$state" "$when" "$detail"; then
    log="${RUNSTATE_LOG:-}"
    if [[ "$RUNSTATE_STATUS" == "failed" && -n "$log" && "$log" != "-" ]]; then
      log_disp=${ printable "$log";}
      printf '     log: %s\n' "$log_disp"
    fi
    if [[ "$STATUS_HISTORY_ON" == true ]]; then
      status_print_history "$name" "$STATUS_HISTORY_N"
    fi
  fi
  return 0
}

# status_text_report ONLY - the default report: the pause line, one row per
# source (filtered by ONLY), and the summary. Byte-for-byte the historical
# status output.
status_text_report() {
  local only="$1" line="" pause_line="" history_on=false
  [[ "$STATUS_HISTORY_ON" == true ]] && history_on=true
  pause_line=""
  if type pause_describe >/dev/null 2>&1; then
    pause_line="$(pause_describe)"
  fi
  [[ -n "$pause_line" ]] || pause_line="not paused"
  if [[ "$STATUS_QUIET" == false || "$history_on" == false ]]; then
    printf '%s\n' "$pause_line"
  fi
  if [[ -n "$only" ]] && ! status_has_name "$only"; then
    printf '%s\n' "$(unknown_source_prefix "$only")" >&2
    return 1
  fi
  # --quiet keeps only the rows that need attention; --history adds no
  # output to them, so the combination stays silent with rc 0.
  if [[ "$STATUS_QUIET" == true && "$history_on" == true ]]; then
    return 0
  fi
  STATUS_TOTAL=0 STATUS_OK=0 STATUS_FAILED=0 STATUS_IDLE=0
  while IFS= read -r line; do
    status_process_line "$line" "$only"
  done < <(manifest_lines)
  printf 'Summary: %s source(s) tracked (%s ok, %s failed, %s skipped/never)\n' \
    "$STATUS_TOTAL" "$STATUS_OK" "$STATUS_FAILED" "$STATUS_IDLE"
  return 0
}

# status_json_pause - fill STATUS_PAUSED and STATUS_PAUSE_UNTIL from the
# pause marker (removing an expired one, like the text report). The stamp is
# rendered like pause_describe; 0 becomes "indefinite".
status_json_pause() {
  STATUS_PAUSED=false
  STATUS_PAUSE_UNTIL=""
  type pause_active >/dev/null 2>&1 || return 0
  pause_active || return 0
  STATUS_PAUSED=true
  if [[ "$PAUSE_UNTIL" == "0" ]]; then
    STATUS_PAUSE_UNTIL="indefinite"
    return 0
  fi
  STATUS_PAUSE_UNTIL=${ epoch_to_stamp "$PAUSE_UNTIL" '%Y-%m-%d %H:%M:%S';}
  return 0
}

# status_each_entry - emit one source's JSON row. Uses the caller's `only`
# (the manifest walk already parsed the entry into ENTRY_*).
status_each_entry() {
  [[ -z "$only" || "$ENTRY_NAME" == "$only" ]] || return 0
  status_read_state "$ENTRY_NAME" || true
  [[ "$STATUS_QUIET" == true && "$RUNSTATE_STATUS" == "ok" ]] && return 0
  output_json_object_begin
  output_json_kv "name" "$ENTRY_NAME"
  output_json_kv "mode" "$ENTRY_MODE"
  output_json_kv "status" "$RUNSTATE_STATUS"
  output_json_kv "stamp" "$RUNSTATE_STAMP"
  output_json_kv "time" "$RUNSTATE_TIME"
  output_json_kv "rc" "$RUNSTATE_RC"
  output_json_kv "conflicts" "$RUNSTATE_CONFLICTS"
  output_json_kv "log" "$RUNSTATE_LOG"
  output_json_kv "detail" "$RUNSTATE_DETAIL"
  output_json_object_end
  return 0
}

# status_json_report ONLY - one JSON document with the pause state and the
# runstate fields of every source (filtered by ONLY; --quiet hides ok rows).
status_json_report() {
  local only="$1"
  if [[ -n "$only" ]] && ! status_has_name "$only"; then
    printf '%s\n' "$(unknown_source_prefix "$only")" >&2
    return 1
  fi
  status_json_pause
  output_json_begin
  output_json_kv_bool "paused" "$STATUS_PAUSED"
  output_json_kv "pause_until" "$STATUS_PAUSE_UNTIL"
  output_json_array_begin "rows"
  manifest_each status_each_entry
  output_json_array_end
  output_json_end
  return 0
}

# status_watch_loop INTERVAL ONLY - refresh the text report every INTERVAL
# seconds until INT/TERM (exit 130/143). On a TTY the screen is cleared
# before each snapshot; otherwise snapshots are separated by a blank line.
status_watch_loop() {
  local interval="$1" only="$2"
  trap 'exit 130' INT
  trap 'exit 143' TERM
  while true; do
    if [[ -t 1 ]]; then
      printf '\033[2J\033[H'
    fi
    if ! status_text_report "$only"; then
      return 1
    fi
    if [[ ! -t 1 ]]; then
      printf '\n'
    fi
    sleep "$interval"
  done
}

cmd_status() {
  local only="" history="" watch=""
  STATUS_QUIET=false
  STATUS_HISTORY_N=0
  STATUS_HISTORY_ON=false
  opt_begin "only:s quiet:b history:o:10 json:b watch:o:5" status "" "$@"
  opt_guard status
  # Run dependencies load after opt_guard's --help exit, so
  # `sciebo status --help` parses none of them: the last-run records come
  # from runstate.sh (before its `type` probes so they are never silently
  # skipped), the pause line from pause.sh (same), and the source walk goes
  # through the manifest.
  sciebo_require_module runstate runstate_read
  sciebo_require_module pause pause_active
  sciebo_require_module manifest manifest_each
  only="${OPT_only:-}"
  opt_into STATUS_QUIET quiet
  if [[ -n "${OPT_history_SET:-}" ]]; then
    history="${OPT_history:-10}"
    opt_require_uint status --history "$history" 0 "" "invalid --history value: ${history}"
    STATUS_HISTORY_N="$((10#$history))"
    STATUS_HISTORY_ON=true
  fi
  if [[ -n "${OPT_watch_SET:-}" ]]; then
    watch="${OPT_watch:-5}"
    opt_require_uint status --watch "$watch" 1 "" "invalid --watch value: ${watch}"
  fi
  if [[ -n "${OPT_json:-}" && -n "${OPT_watch_SET:-}" ]]; then
    usage_error status "--watch cannot be combined with --json"
  fi
  opt_json_mode
  load_settings --no-rclone
  if [[ -n "${OPT_json:-}" ]]; then
    status_json_report "$only"
    return $?
  fi
  if [[ -n "${OPT_watch_SET:-}" ]]; then
    status_watch_loop "$((10#$watch))" "$only"
    return $?
  fi
  status_text_report "$only"
  return $?
}
