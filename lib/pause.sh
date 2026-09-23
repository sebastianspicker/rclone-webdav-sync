#!/bin/bash
# pause.sh - pause marker helpers shared by sync and the pause/resume commands.
#
# The marker is a single line `until=<epoch>`; 0 means paused indefinitely.
# An expired marker is removed by pause_active, so the next run proceeds.

# now_epoch/epoch_to_stamp/duration_seconds come from lib/duration.sh.
sciebo_require_module duration now_epoch

# _pause_file - print the marker path. PAUSE_FILE wins; STATE_DIR/paused is
# the fallback when the settings module was not loaded. rc 1 without output
# when neither is set.
_pause_file() {
  if [[ -n "${PAUSE_FILE:-}" ]]; then
    printf '%s\n' "$PAUSE_FILE"
    return 0
  fi
  [[ -n "${STATE_DIR:-}" ]] || return 1
  printf '%s\n' "${STATE_DIR}/paused"
}

# pause_read - parse the marker into PAUSE_UNTIL. rc 1 with PAUSE_UNTIL
# empty when there is no marker or it is unreadable/invalid. The path read
# is a forkless capture (_pause_file is pure printf).
pause_read() {
  local file="" line="" value=""
  PAUSE_UNTIL=""
  file=${ _pause_file;} || return 1
  [[ -f "$file" && -r "$file" ]] || return 1
  IFS= read -r line <"$file" || true
  case "$line" in
    until=*) value="${line#until=}" ;;
    *) return 1 ;;
  esac
  case "$value" in
    '' | *[!0-9]*) return 1 ;;
  esac
  PAUSE_UNTIL="$((10#$value))"
  return 0
}

# pause_active - true while the marker exists and is indefinite or in the
# future; an expired marker is removed first. Never prints anything.
pause_active() {
  local file="" now=""
  pause_read || return 1
  [[ "$PAUSE_UNTIL" != "0" ]] || return 0
  now=${ now_epoch;}
  [[ "$PAUSE_UNTIL" -gt "$now" ]] || {
    file=${ _pause_file;} || return 1
    rm -f "$file" 2>/dev/null || true
    return 1
  }
  return 0
}

# pause_set UNTIL_EPOCH - atomically write the marker (mode 600), creating
# its directory. rc 1 without writing on a bad epoch; never exits.
pause_set() {
  local until="${1:-}" file=""
  case "$until" in
    '' | *[!0-9]*) return 1 ;;
  esac
  file=${ _pause_file;} || return 1
  type atomic_write >/dev/null 2>&1 || return 1
  mkdir -p "$(dirname "$file")" 2>/dev/null || return 1
  printf 'until=%s\n' "$until" | atomic_write "$file" 600 >/dev/null 2>&1 || return 1
  return 0
}

# pause_clear - remove the marker. rc 0 when it was already absent.
pause_clear() {
  local file=""
  file=${ _pause_file;} || return 0
  rm -f "$file" 2>/dev/null || true
  return 0
}

# pause_describe - print "paused until <stamp>" or "paused (indefinite)";
# print nothing when not paused. Never fails.
pause_describe() {
  local when=""
  pause_active || return 0
  if [[ "$PAUSE_UNTIL" == "0" ]]; then
    printf 'paused (indefinite)\n'
    return 0
  fi
  when=${ epoch_to_stamp "$PAUSE_UNTIL" '%Y-%m-%d %H:%M:%S';} || when=""
  [[ -n "$when" ]] || return 0
  printf 'paused until %s\n' "$when"
  return 0
}
