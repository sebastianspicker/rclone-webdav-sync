#!/bin/bash
# bw.sh - bandwidth-limit marker helpers shared by sync and the
# limit/unlimited commands.
#
# The marker is three lines under BW_LIMIT_FILE (mode 600):
#   until=<epoch|0>   (0 = no expiry)
#   up=<rate|empty>   (rclone SizeSuffix, e.g. 2M; empty = off)
#   down=<rate|empty>
#
# An active marker takes precedence over BW_SCHEDULE, which takes precedence
# over BW_LIMIT_UP/BW_LIMIT_DOWN. Expired markers and malformed content (a
# bad expiry line, or a rate that is not a valid rclone bandwidth limit) are
# removed best-effort on read, like the pause marker; an invalid rate also
# warns.

# now_epoch comes from lib/base/duration.sh, always loaded before this file.

# _bw_file - print the marker path. BW_LIMIT_FILE wins; STATE_DIR/bwlimit is
# the fallback when the settings module was not loaded. rc 1 without output
# when neither is set.
_bw_file() {
  if [[ -n "${BW_LIMIT_FILE:-}" ]]; then
    printf '%s\n' "$BW_LIMIT_FILE"
    return 0
  fi
  [[ -n "${STATE_DIR:-}" ]] || return 1
  printf '%s\n' "${STATE_DIR}/bwlimit"
}

# bw_rate_valid RATE - true when RATE is safe to hand to rclone's --bwlimit:
# empty (the marker's "off"), the literal off, or a number with an optional
# decimal fraction, an optional [kKMGT][i]B suffix, and an optional /second
# (or /s) tail. Whitespace, control bytes, and any other marker content
# fail the anchored pattern, so a tampered marker is ignored on read
# instead of reaching rclone's argv (sync.sh consumes bw_effective_limit
# verbatim).
bw_rate_valid() {
  local rate="$1"
  case "$rate" in
    '' | off) return 0 ;;
  esac
  [[ "$rate" =~ ^([0-9]+([.][0-9]+)?|[.][0-9]+)([kKMGT][iI]?[Bb]?)?([/][sS](econd)?)?$ ]]
}

# bw_marker_read - parse the marker into BW_MARKER_UP, BW_MARKER_DOWN, and
# BW_MARKER_UNTIL; BW_MARKER_ACTIVE is 1 when the marker exists and is
# indefinite or still in the future. An expired marker or a malformed one
# (bad expiry line, rate failing bw_rate_valid, which also warns) is removed
# best-effort. Always returns 0, so callers under `set -e` can call
# it unconditionally and inspect BW_MARKER_ACTIVE. The path and now_epoch
# reads are forkless captures (both helpers are pure printf).
bw_marker_read() {
  local file="" line="" until="" up="" down=""
  BW_MARKER_UP=""
  BW_MARKER_DOWN=""
  BW_MARKER_UNTIL=""
  BW_MARKER_ACTIVE=0
  file=${ _bw_file;} || return 0
  [[ -f "$file" && -r "$file" ]] || return 0
  while IFS= read -r line; do
    case "$line" in
      until=*) until="${line#until=}" ;;
      up=*) up="${line#up=}" ;;
      down=*) down="${line#down=}" ;;
    esac
  done <"$file"
  case "$until" in
    '' | *[!0-9]*)
      rm -f "$file" 2>/dev/null || true
      return 0
      ;;
  esac
  # Marker content is state-file data, not user input: a rate that is not a
  # valid rclone bandwidth limit is treated as an absent marker instead of
  # flowing into --bwlimit. printable keeps a planted control byte out of
  # the warning line.
  if ! bw_rate_valid "$up" || ! bw_rate_valid "$down"; then
    warn "removing bandwidth marker with an invalid rate (not a valid rclone limit): up='$(printable "$up")' down='$(printable "$down")' (${file})"
    rm -f "$file" 2>/dev/null || true
    return 0
  fi
  until="$((10#$until))"
  BW_MARKER_UP="$up"
  BW_MARKER_DOWN="$down"
  # shellcheck disable=SC2034  # read by the sync command module
  BW_MARKER_UNTIL="$until"
  if [[ "$until" == "0" ]] || [[ "$until" -gt ${ now_epoch;} ]]; then
    BW_MARKER_ACTIVE=1
    return 0
  fi
  rm -f "$file" 2>/dev/null || true
  return 0
}

# bw_marker_write UNTIL_EPOCH UP DOWN - atomically write the three-line
# marker (mode 600), creating its directory. rc 1 without writing on a bad
# epoch or when the state path is unavailable; never exits.
bw_marker_write() {
  local until="${1:-}" up="${2:-}" down="${3:-}" file=""
  case "$until" in
    '' | *[!0-9]*) return 1 ;;
  esac
  file=${ _bw_file;} || return 1
  type atomic_write >/dev/null 2>&1 || return 1
  mkdir -p "$(dirname "$file")" 2>/dev/null || return 1
  printf 'until=%s\nup=%s\ndown=%s\n' "$until" "$up" "$down" |
    atomic_write "$file" 600 >/dev/null 2>&1 || return 1
  return 0
}

# bw_marker_clear - remove the marker. rc 0 when it was already absent.
bw_marker_clear() {
  local file=""
  file=${ _bw_file;} || return 0
  rm -f "$file" 2>/dev/null || true
  return 0
}

# bw_effective_limit - print the rclone --bwlimit value for the current
# state: the active marker as "<up|off>:<down|off>", else BW_SCHEDULE
# verbatim, else BW_LIMIT_UP/BW_LIMIT_DOWN as "<up|off>:<down|off>" when
# either is set, else nothing. Always returns 0.
bw_effective_limit() {
  bw_marker_read
  if [[ "${BW_MARKER_ACTIVE:-0}" == "1" ]]; then
    printf '%s:%s\n' "${BW_MARKER_UP:-off}" "${BW_MARKER_DOWN:-off}"
    return 0
  fi
  if [[ -n "${BW_SCHEDULE:-}" ]]; then
    printf '%s\n' "$BW_SCHEDULE"
    return 0
  fi
  if [[ -n "${BW_LIMIT_UP:-}" || -n "${BW_LIMIT_DOWN:-}" ]]; then
    printf '%s:%s\n' "${BW_LIMIT_UP:-off}" "${BW_LIMIT_DOWN:-off}"
    return 0
  fi
  return 0
}
