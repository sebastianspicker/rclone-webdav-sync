#!/bin/bash
# runstate.sh - per-source last-run records for `sciebo status`.
#
# One small key=value file per sanitized entry name under RUNSTATE_DIR:
#
#   time=<epoch>            stamp=<YYYY-mm-dd HH:MM:SS>
#   mode=<sync|pull|bisync> status=<ok|failed|skipped>
#   rc=<int>                conflicts=<int>
#   log=<path or ->         detail=<single line>
#
# Records are written atomically (mode 600) and parsed without sourcing, so
# a hostile record cannot execute code. Writing is best effort: a state
# directory problem must never fail a sync.
#
# Every successful write also appends one line to
# HISTORY_DIR/<name>.log (`epoch<TAB>status<TAB>detail`) and trims the log
# to the newest HISTORY_MAX_ENTRIES lines (0 disables the history files);
# see runstate_history. History problems are ignored as well.

# now_epoch/epoch_to_stamp_or_raw come from lib/duration.sh; default_uint
# comes from lib/core.sh.
sciebo_require_module duration now_epoch

# runstate_file NAME - print NAME's record path. rc 1 and no output when
# the name sanitizes to nothing or RUNSTATE_DIR is not set.
runstate_file() {
  local name=""
  sanitize_name_into name "${1:-}"
  [[ -n "$name" && -n "${RUNSTATE_DIR:-}" ]] || return 1
  printf '%s/%s\n' "$RUNSTATE_DIR" "$name"
  return 0
}

# runstate_write NAME MODE STATUS RC LOG CONFLICTS DETAIL - atomically
# replace NAME's record (mode 600), creating RUNSTATE_DIR first. LOG is
# stored as "-" when empty and DETAIL is flattened with printable. Always
# returns 0.
runstate_write() {
  local name="${1:-}" mode="${2:-}" status="${3:-}" rc="${4:-}"
  local log="${5:-}" conflicts="${6:-}" detail="${7:-}"
  local file="" now="" stamp="" record=""
  # Forkless path capture (runstate_file only prints); rc 1 (no state dir,
  # name sanitizes to nothing) still bails out exactly as before.
  file=${ runstate_file "$name";} || return 0
  [[ -n "$log" ]] || log="-"
  detail=${ printable "$detail";}
  # Create the state directory only when missing: ensure_state_dirs already
  # made it for CLI callers, and lib-level test callers keep mkdir -p's exact
  # behavior (including its failing rc) for a missing or non-directory path.
  if [[ ! -d "$RUNSTATE_DIR" ]]; then
    mkdir -p "$RUNSTATE_DIR" 2>/dev/null || return 0
  fi
  now=${ now_epoch;}
  printf -v stamp '%(%Y-%m-%d %H:%M:%S)T' -1
  # One printf -v builds the whole record in a variable and a here-string
  # feeds atomic_write, so the record no longer runs through a
  # brace-group-plus-function pipeline (two subshells) per write. The format
  # has no trailing newline: the here-string supplies exactly the one the
  # pipeline's last printf wrote.
  printf -v record 'time=%s\nstamp=%s\nmode=%s\nstatus=%s\nrc=%s\nconflicts=%s\nlog=%s\ndetail=%s' \
    "$now" "$stamp" "$mode" "$status" "$rc" "$conflicts" "$log" "$detail"
  if atomic_write "$file" 600 <<<"$record" >/dev/null 2>&1; then
    runstate_history_append "$name" "$now" "$status" "$detail" || true
  fi
  return 0
}

# runstate_read NAME - parse NAME's record into RUNSTATE_TIME, RUNSTATE_STAMP,
# RUNSTATE_MODE, RUNSTATE_STATUS, RUNSTATE_RC, RUNSTATE_CONFLICTS,
# RUNSTATE_LOG, and RUNSTATE_DETAIL. rc 1 with the variables empty when the
# record is missing or unreadable. The record is parsed, never sourced.
runstate_read() {
  local file="" key="" value=""
  RUNSTATE_TIME="" RUNSTATE_STAMP="" RUNSTATE_MODE="" RUNSTATE_STATUS=""
  RUNSTATE_RC="" RUNSTATE_CONFLICTS="" RUNSTATE_LOG="" RUNSTATE_DETAIL=""
  file=${ runstate_file "${1:-}";} || return 1
  [[ -f "$file" && -r "$file" ]] || return 1
  # shellcheck disable=SC2034  # RUNSTATE_* outputs are read by callers
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    case "$key" in
      time) RUNSTATE_TIME="$value" ;;
      stamp) RUNSTATE_STAMP="$value" ;;
      mode) RUNSTATE_MODE="$value" ;;
      status) RUNSTATE_STATUS="$value" ;;
      rc) RUNSTATE_RC="$value" ;;
      conflicts) RUNSTATE_CONFLICTS="$value" ;;
      log) RUNSTATE_LOG="$value" ;;
      detail) RUNSTATE_DETAIL="$value" ;;
    esac
  done <"$file"
  return 0
}

# runstate_history_file NAME - print NAME's history log path. rc 1 and no
# output when the name sanitizes to nothing or HISTORY_DIR is not set.
runstate_history_file() {
  local name=""
  sanitize_name_into name "${1:-}"
  [[ -n "$name" && -n "${HISTORY_DIR:-}" ]] || return 1
  printf '%s/%s.log\n' "$HISTORY_DIR" "$name"
  return 0
}

# runstate_history_append NAME EPOCH STATUS DETAIL - append one TAB-separated
# history record for NAME, creating HISTORY_DIR lazily, and trim the log to
# the newest HISTORY_MAX_ENTRIES lines. STATUS and DETAIL are flattened to a
# single line (TABs and newlines become spaces); a non-numeric
# HISTORY_MAX_ENTRIES falls back to 50, and 0 disables writing. Best effort:
# a broken history log never changes the caller's status, so this always
# returns 0.
runstate_history_append() {
  local name="${1:-}" epoch="${2:-}" status="${3:-}" detail="${4:-}"
  local file="" max="${HISTORY_MAX_ENTRIES:-50}" count="" tmp=""
  # Forkless path capture (runstate_history_file only prints); rc 1 bails
  # out exactly as before.
  file=${ runstate_history_file "$name";} || return 0
  max=${ default_uint "$max" 50;}
  max=$((10#$max))
  [[ "$max" -gt 0 ]] || return 0
  status="${status//$'\t'/ }"
  status="${status//$'\n'/ }"
  status=${ printable "$status";}
  detail="${detail//$'\t'/ }"
  detail="${detail//$'\n'/ }"
  detail=${ printable "$detail";}
  case "$epoch" in
    '' | *[!0-9]*) epoch=${ now_epoch;} ;;
  esac
  # Same missing-directory guard as runstate_write: create HISTORY_DIR only
  # when absent so the common append path skips the mkdir fork, while a
  # missing directory keeps mkdir -p's exact rc behavior.
  if [[ ! -d "$HISTORY_DIR" ]]; then
    mkdir -p "$HISTORY_DIR" 2>/dev/null || return 0
  fi
  printf '%s\t%s\t%s\n' "$epoch" "$status" "$detail" >>"$file" 2>/dev/null || return 0
  # Count in pure bash: the log is bounded by HISTORY_MAX_ENTRIES, so this
  # reads at most max+1 lines and never forks wc. Stop as soon as the count
  # exceeds max; only the >max decision matters for the rotation below.
  count=0
  while IFS= read -r _ || [[ -n "$_" ]]; do
    count=$((count + 1))
    [[ "$count" -gt "$max" ]] && break
  done <"$file"
  [[ "$count" -gt "$max" ]] || return 0
  tmp="$(mktemp "${file}.tmp.XXXXXX" 2>/dev/null)" || return 0
  if tail -n "$max" "$file" >"$tmp" 2>/dev/null; then
    mv -f "$tmp" "$file" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
  return 0
}

# runstate_format_epoch_into VAR EPOCH - store epoch_to_stamp_or_raw's
# output in VAR without a command substitution; the history walk formats one
# epoch per row, so the per-row subshell is avoided.
runstate_format_epoch_into() {
  local __var="$1" out=""
  out="${ epoch_to_stamp_or_raw "${2:-}";}"
  printf -v "$__var" '%s' "$out"
  return 0
}

# runstate_history NAME [N] - print the most recent N (default 10) history
# records for NAME, newest first, as 'YYYY-mm-dd HH:MM  STATUS  detail'.
# Missing, empty, or unreadable history prints nothing and returns 0; a
# non-numeric N falls back to 10. The read is forkless: the log is bounded
# by HISTORY_MAX_ENTRIES (trimmed on every append), so the rows are loaded
# with mapfile and the newest N are emitted in reverse in bash - byte
# identical to the former `tail -n N | LC_ALL=C awk {reverse}` pipeline
# (every emitted row ends in a newline, empty rows are skipped below).
runstate_history() {
  local name="${1:-}" limit="${2:-10}" file="" epoch="" status="" detail="" stamp=""
  local -a rows=()
  local i=0 start=0
  file=${ runstate_history_file "$name";} || return 0
  [[ -f "$file" && -r "$file" ]] || return 0
  limit=${ default_uint "$limit" 10;}
  limit=$((10#$limit))
  [[ "$limit" -gt 0 ]] || return 0
  # Redirections run left to right, so stderr is silenced before the input
  # open: a race-deleted file degrades to "prints nothing", like tail's
  # 2>/dev/null did.
  mapfile -t rows 2>/dev/null <"$file"
  start=$((${#rows[@]} - limit))
  [[ "$start" -ge 0 ]] || start=0
  i="${#rows[@]}"
  while [[ "$i" -gt "$start" ]]; do
    i=$((i - 1))
    IFS=$'\t' read -r epoch status detail <<<"${rows[i]}"
    [[ -n "$epoch$status$detail" ]] || continue
    runstate_format_epoch_into stamp "$epoch"
    printf '%s  %s  %s\n' "$stamp" "${status^^}" "$detail"
  done
  return 0
}
