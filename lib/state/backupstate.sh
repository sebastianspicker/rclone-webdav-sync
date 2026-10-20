#!/bin/bash
# backupstate.sh - maintenance markers for `sciebo backup`.
#
# One file per kind (forget, check, run) under backupstate_dir holds the epoch
# of the last successful pass, written atomically (mode 600) and parsed, never
# sourced. backupstate_due compares a marker with a duration like 7d so the
# backup command knows when forget/check maintenance is owed. State problems
# never die: a failed write returns 1, a missing or malformed marker is
# simply "never done".

# now_epoch/duration_seconds/duration_human come from lib/base/duration.sh and
# atomic_write from lib/base/fsutil.sh, both loaded before this file.

# backupstate_dir - print the directory that holds the markers.
backupstate_dir() { printf '%s' "${BACKUP_STATE_DIR:-${STATE_DIR:-}/backup}"; }

# _backupstate_kind KIND - die unless KIND is forget, check, or run.
_backupstate_kind() {
  case "${1:-}" in
    forget | check | run) ;;
    *) die "invalid backup marker kind: ${1:-} (use forget, check, or run)" ;;
  esac
}

# backupstate_mark KIND [EPOCH] - record that KIND just happened (EPOCH
# defaults to now). rc 0 on success, rc 1 when the marker cannot be written.
backupstate_mark() {
  local kind="${1:-}" epoch="" dir="" file=""
  _backupstate_kind "$kind"
  epoch="${2:-}"
  [[ -n "$epoch" ]] || epoch=${ now_epoch;}
  dir=${ backupstate_dir;}
  file="${dir}/last-${kind}"
  mkdir -p "$dir" 2>/dev/null || return 1
  atomic_write "$file" 600 <<<"$epoch" >/dev/null 2>&1 || return 1
  return 0
}

# backupstate_last KIND - print the stored epoch (digits only). Prints nothing
# and returns 1 when the marker is missing or malformed.
backupstate_last() {
  local kind="${1:-}" dir="" file="" value=""
  _backupstate_kind "$kind"
  dir=${ backupstate_dir;}
  file="${dir}/last-${kind}"
  [[ -f "$file" && -r "$file" ]] || return 1
  IFS= read -r value <"$file" || [[ -n "$value" ]] || return 1
  case "$value" in
    '' | *[!0-9]*) return 1 ;;
  esac
  printf '%s' "$value"
}

# backupstate_due KIND EVERY [NOW] - rc 0 when KIND is owed: the marker is
# missing or malformed, or at least EVERY (a duration like 7d) has passed
# since it. rc 1 when it is not due, when EVERY is empty or 0 (maintenance
# disabled), and, with a warning, when EVERY is not a duration.
backupstate_due() {
  local kind="${1:-}" every="${2:-}" now="${3:-}" seconds="" last=""
  _backupstate_kind "$kind"
  [[ -n "$every" ]] || return 1
  seconds=${ duration_seconds "$every";} || {
    warn "Ignoring invalid ${kind} interval: ${every} (use <N>[smhd], e.g. 7d)"
    return 1
  }
  [[ "$seconds" -gt 0 ]] || return 1
  [[ -n "$now" ]] || now=${ now_epoch;}
  last=${ backupstate_last "$kind";} || return 0
  [[ $((now - last)) -ge "$seconds" ]]
}

# backupstate_age_human KIND - "never" or the age of the marker as a compact
# duration (e.g. "2d 3h").
backupstate_age_human() {
  local kind="${1:-}" last="" now="" age=0
  last=${ backupstate_last "$kind";} || {
    printf 'never'
    return 0
  }
  now=${ now_epoch;}
  age=$((now - last))
  [[ "$age" -ge 0 ]] || age=0
  duration_human "$age"
}
