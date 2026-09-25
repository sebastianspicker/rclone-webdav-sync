#!/bin/bash
# pairflags.sh - per-pair state flags (paused/hidden): tool-written state
# under STATE_DIR, split from lib/config/manifest.sh (which owns the
# user-authored manifest model, not this).
#
# One small key=value file per sanitized entry name under
# <PAIR_FLAGS_DIR>/<name> (default ${STATE_DIR}/pairs):
#
#   paused=1
#   hidden=1
#
# The manifest line format never changes; these flags only shape a run
# (a paused pair is skipped, a hidden pair excludes dotfiles). Reads are
# best effort and never fail a run; writes are atomic and mode 600.

# PAIR_FLAGS_DIR is not pinned at source time (lib/sciebo.sh loads this file
# before load_settings derives STATE_DIR): manifest_pair_flags_dir_into below
# derives it from the current STATE_DIR on every call instead, so a profile
# switch is honored too.

# Resolved flag-file paths, keyed by "dir<TAB>name". The resolution only
# depends on the sanitized name and the current flags directory, so a profile
# switch (a new dir) resolves a fresh key and never reuses a stale path.
declare -g -A _MANIFEST_PAIR_FLAGS_FILES=()

# The parsed paused/hidden flags for the last NAME read. The paused and hidden
# predicates are usually asked back to back for the same entry, so this shares
# their file read; manifest_pair_flags_set drops it after a write.
MANIFEST_PAIR_FLAGS_LOADED_NAME=""
MANIFEST_PAIR_PAUSED="0"
MANIFEST_PAIR_HIDDEN="0"

# manifest_pair_flags_dir_into VAR - set VAR to the flags directory without a
# command substitution; return 1 when neither PAIR_FLAGS_DIR nor STATE_DIR is
# known.
manifest_pair_flags_dir_into() {
  if [[ -n "${PAIR_FLAGS_DIR:-}" ]]; then
    printf -v "$1" '%s' "${PAIR_FLAGS_DIR%/}"
    return 0
  fi
  [[ -n "${STATE_DIR:-}" ]] || return 1
  printf -v "$1" '%s' "${STATE_DIR%/}/pairs"
  return 0
}

# manifest_pair_flags_file_into VAR NAME - set VAR to NAME's flag-file path
# without a command substitution; the path is memoized per "dir<TAB>name".
# Return 1 when NAME is unusable or no state directory is known.
manifest_pair_flags_file_into() {
  local out="$1" raw="${2:-}" sname="" sdir="" skey="" resolved=""
  sanitize_name_into sname "$raw"
  [[ -n "$sname" ]] || return 1
  manifest_pair_flags_dir_into sdir || return 1
  skey="${sdir}"$'\t'"${sname}"
  if [[ -v "_MANIFEST_PAIR_FLAGS_FILES[$skey]" ]]; then
    printf -v "$out" '%s' "${_MANIFEST_PAIR_FLAGS_FILES[$skey]}"
    return 0
  fi
  resolved="${sdir}/${sname}"
  _MANIFEST_PAIR_FLAGS_FILES[$skey]="$resolved"
  printf -v "$out" '%s' "$resolved"
  return 0
}

# manifest_pair_flags_file NAME - print NAME's flag-file path; return 1 when
# NAME is unusable or no state directory is known.
manifest_pair_flags_file() {
  local file=""
  manifest_pair_flags_file_into file "${1:-}" || return 1
  printf '%s' "$file"
  return 0
}

# manifest_pair_flags_load NAME - parse NAME's flag file once into the globals
# MANIFEST_PAIR_PAUSED and MANIFEST_PAIR_HIDDEN (0/1; absent is 0). The last
# NAME's parse is kept so the paused and hidden predicates share one read.
# Best effort: a missing or unreadable file leaves both flags 0.
manifest_pair_flags_load() {
  local name="${1:-}" file="" k="" v=""
  [[ "$MANIFEST_PAIR_FLAGS_LOADED_NAME" == "$name" ]] && return 0
  MANIFEST_PAIR_FLAGS_LOADED_NAME="$name"
  MANIFEST_PAIR_PAUSED="0"
  MANIFEST_PAIR_HIDDEN="0"
  manifest_pair_flags_file_into file "$name" || return 0
  [[ -f "$file" && -r "$file" ]] || return 0
  while IFS='=' read -r k v || [[ -n "$k" ]]; do
    case "$k" in
      paused) MANIFEST_PAIR_PAUSED="$v" ;;
      hidden) MANIFEST_PAIR_HIDDEN="$v" ;;
    esac
  done <"$file"
  return 0
}

# manifest_pair_flags_set NAME KEY VALUE - store KEY=VALUE (KEY is paused or
# hidden, VALUE is 0 or 1) in NAME's flag file, preserving the other key and
# ignoring unrelated lines. Rejects an invalid KEY/VALUE or unusable NAME.
# Returns 1 when the file cannot be written; callers may treat that as best
# effort. Writes go through atomic_write (mode 600).
manifest_pair_flags_set() {
  local name="$1" key="$2" value="$3" file="" out="" k="" v="" found=0
  case "$key" in paused | hidden) ;; *) return 1 ;; esac
  case "$value" in 0 | 1) ;; *) return 1 ;; esac
  manifest_pair_flags_file_into file "$name" || return 1
  if [[ -f "$file" && -r "$file" ]]; then
    while IFS='=' read -r k v || [[ -n "$k" ]]; do
      case "$k" in
        paused | hidden) ;;
        *) continue ;;
      esac
      if [[ "$k" == "$key" ]]; then
        out+="${key}=${value}"$'\n'
        found=1
      else
        out+="${k}=${v}"$'\n'
      fi
    done <"$file"
  fi
  [[ "$found" -eq 1 ]] || out+="${key}=${value}"$'\n'
  printf '%s' "$out" | atomic_write "$file" 600 >/dev/null 2>&1 || return 1
  MANIFEST_PAIR_FLAGS_LOADED_NAME=""
  return 0
}

# manifest_pair_paused NAME / manifest_pair_hidden NAME - true when NAME's
# flag is set to 1. Best effort: a missing or unreadable flag file is "off".
# Both share manifest_pair_flags_load's single parse of the flag file.
manifest_pair_paused() {
  manifest_pair_flags_load "${1:-}"
  [[ "$MANIFEST_PAIR_PAUSED" == "1" ]]
}
manifest_pair_hidden() {
  manifest_pair_flags_load "${1:-}"
  [[ "$MANIFEST_PAIR_HIDDEN" == "1" ]]
}
