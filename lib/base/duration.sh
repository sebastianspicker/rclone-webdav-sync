#!/bin/bash
# duration.sh - duration parsing and epoch helpers shared by pause, presence,
# cleanup, schedule, watch, support, and the confidence guards.
#
# The project-wide convention: a duration is a non-negative number with an
# optional s/m/h/d suffix; a bare number means minutes unless the caller
# asks for seconds with `duration_seconds VALUE seconds`.

# duration_seconds VALUE [DEFAULT_UNIT] - print the duration in whole
# seconds. DEFAULT_UNIT is "minutes" (the default) or "seconds". Prints
# nothing and returns 1 for a value that is not a duration.
duration_seconds() {
  local value="$1" unit="${2:-minutes}" number="" suffix="" multiplier=60
  case "$unit" in
    seconds | s) multiplier=1 ;;
    minutes | m) multiplier=60 ;;
  esac
  value="${value//[[:space:]]/}"
  [[ -n "$value" ]] || return 1
  number="${value%%[!0-9]*}"
  suffix="${value#"$number"}"
  [[ -n "$number" ]] || return 1
  [[ "$number" != *[!0-9]* ]] || return 1
  case "$suffix" in
    '') ;;
    s | S) multiplier=1 ;;
    m | M) multiplier=60 ;;
    h | H) multiplier=3600 ;;
    d | D) multiplier=86400 ;;
    *) return 1 ;;
  esac
  printf '%s' "$((10#$number * multiplier))"
}

# duration_parse_or_usage CMD FLAG VALUE [STYLE] [EXAMPLES] - print VALUE as
# seconds through duration_seconds' minutes grammar (<N>[smhd], a bare number
# means minutes), or stop the run through usage_error CMD (exit 2). STYLE
# picks the message shape the asserted wordings need:
#   invalid (default)
#       "invalid[ <FLAG>] duration: <VALUE> (use <N>[smhd], e.g. EXAMPLES)"
#       Pass FLAG="" for pause's flagless "invalid duration: ..." spelling,
#       or the flag name for presence's "invalid --clear-after duration: ...".
#   requires
#       "<FLAG> requires a duration like 90m, 24h, or 7d" - activity's and
#       recent's --since wording.
# EXAMPLES overrides the example list in the invalid wording (its default is
# "90m, 24h, 7d"): pause passes "90m, 24h, 1d", presence "30m, 4h, 1d",
# limit "90m, 1d; 0 = no expiry". It has no effect on the requires wording.
# Returns 0 and prints the seconds on success; never returns on failure.
# _capabilities_duration_seconds' milliseconds variant in capabilities.sh is
# a different grammar and does not use this.
duration_parse_or_usage() {
  local command="$1" flag="${2:-}" value="${3:-}" style="${4:-invalid}"
  local examples="${5:-90m, 24h, 7d}" seconds=""
  seconds=${ duration_seconds "$value" minutes;} || seconds=""
  if [[ -n "$seconds" ]]; then
    printf '%s' "$seconds"
    return 0
  fi
  case "$style" in
    requires)
      usage_error "$command" "${flag} requires a duration like 90m, 24h, or 7d"
      ;;
  esac
  usage_error "$command" "invalid${flag:+ ${flag}} duration: ${value} (use <N>[smhd], e.g. ${examples})"
}

# now_epoch - wall-clock seconds since the epoch (integer), for user-visible
# timestamps. Uses the Bash special variable (updated on access) to avoid
# forking `date` in hot callers; falls back to `date` if EPOCHSECONDS was unset.
now_epoch() { printf '%s' "${EPOCHSECONDS:-$(date '+%s')}"; }

# now_mono - monotonic seconds (Bash 5.3 BASH_MONOSECONDS). Use for elapsed
# time, intervals, and deadlines; it is unaffected by wall-clock changes and
# is not a timestamp, so do not store it.
now_mono() { printf '%s' "${BASH_MONOSECONDS}"; }

# Successfully formatted timestamps, keyed by "epoch|format"; an unset key
# means "not converted yet". Failures fall back to the raw epoch and are not
# cached. -g keeps the array global regardless of what scope sources this
# file from.
declare -g -A EPOCH_STAMP_CACHE=()

# epoch_to_stamp EPOCH [FORMAT] - formatted local time for EPOCH; the default
# is the report style used by status and conflicts. A non-empty all-digit
# epoch is formatted by the Bash builtin strftime (no fork); a value the
# builtin rejects (out of its supported range) or a non-numeric value falls
# back to `date`, whose two spellings cover macOS and GNU.
epoch_to_stamp() {
  local epoch="$1" format="${2:-%Y-%m-%d %H:%M}" key="" out=""
  key="${epoch}|${format}"
  if [[ -v "EPOCH_STAMP_CACHE[$key]" ]]; then
    printf '%s' "${EPOCH_STAMP_CACHE[$key]}"
    return 0
  fi
  # printf -v sets out even when the conversion fails, so only trust it on
  # rc 0; the digits-only guard keeps negative and non-numeric values on the
  # `date` path that historically handled them.
  if [[ -n "$epoch" && "$epoch" != *[!0-9]* ]]; then
    if printf -v out '%('"$format"')T' "$epoch" 2>/dev/null; then
      EPOCH_STAMP_CACHE[$key]="$out"
      printf '%s' "$out"
      return 0
    fi
  fi
  if out="$(date -r "$epoch" "+${format}" 2>/dev/null)"; then
    EPOCH_STAMP_CACHE[$key]="$out"
    printf '%s' "$out"
    return 0
  fi
  if out="$(date -d "@${epoch}" "+${format}" 2>/dev/null)"; then
    EPOCH_STAMP_CACHE[$key]="$out"
    printf '%s' "$out"
    return 0
  fi
  printf '%s' "$epoch"
}

# epoch_to_stamp_or_raw EPOCH [FORMAT] - EPOCH through epoch_to_stamp when it
# is a non-empty run of ASCII digits; a missing, empty, or non-numeric value
# prints through unchanged, so callers can format possibly-absent timestamps.
epoch_to_stamp_or_raw() {
  local epoch="${1:-}" format="${2:-}"
  case "$epoch" in
    '' | *[!0-9]*)
      printf '%s' "$epoch"
      return 0
      ;;
  esac
  if [[ -n "$format" ]]; then
    epoch_to_stamp "$epoch" "$format"
  else
    epoch_to_stamp "$epoch"
  fi
}

# duration_human SECONDS - compact "2h 15m" style label for reports.
duration_human() {
  local seconds="$1" out=""
  case "$seconds" in
    '' | *[!0-9]*) printf '%s' "$seconds" && return 0 ;;
  esac
  if [[ "$seconds" -ge 86400 ]]; then
    out="$((seconds / 86400))d"
    seconds=$((seconds % 86400))
  fi
  if [[ "$seconds" -ge 3600 ]]; then
    out="${out:+${out} }$((seconds / 3600))h"
    seconds=$((seconds % 3600))
  fi
  if [[ "$seconds" -ge 60 ]]; then
    out="${out:+${out} }$((seconds / 60))m"
    seconds=$((seconds % 60))
  fi
  [[ "$seconds" -eq 0 && -n "$out" ]] || out="${out:+${out} }${seconds}s"
  printf '%s' "$out"
}
