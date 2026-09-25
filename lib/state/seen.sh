#!/bin/bash
# seen.sh - seen-id caches (notifications, activity): one server-side id per
# line, under STATE_DIR. The in-process index turns per-record membership
# into one `case` match instead of a full file scan per record. Writers run
# in subshells (the `... | seen_record` pipeline), so the index is
# revalidated against the file stamp instead of relying on in-process
# invalidation. The raw stamp is itself cached for the current SECONDS tick
# (mirroring core.sh's _log_stamp_refresh), so a burst of membership checks
# stats the file at most once per second; a write from another process is
# picked up on the next tick, while seen_record clears the cache so a
# same-shell append is seen immediately.

SEEN_CACHE_FILE=""
SEEN_CACHE_STAMP=""
SEEN_CACHE_INDEX=""
SEEN_STAMP_FILE=""
SEEN_STAMP_SECONDS=""
SEEN_STAMP_VALUE=""

# _seen_stamp_refresh FILE - set SEEN_STAMP_VALUE to FILE's "mtime size"
# stamp, reusing the value cached for the current SECONDS tick and file. The
# file is part of the cache key, so switching files re-stats even inside one
# tick. Runs in the caller's shell (a $() wrapper would lose the cache).
_seen_stamp_refresh() {
  local file="$1"
  if [[ "$SEEN_STAMP_SECONDS" == "$SECONDS" && "$SEEN_STAMP_FILE" == "$file" ]]; then
    return 0
  fi
  SEEN_STAMP_SECONDS="$SECONDS"
  SEEN_STAMP_FILE="$file"
  SEEN_STAMP_VALUE="$(file_stamp "$file")"
  return 0
}

# seen_contains FILE ID - true when ID is one line of FILE. A missing file
# is not an error.
seen_contains() {
  local file="$1" id="${2:-}" stamp=""
  [[ -n "$id" && -f "$file" ]] || return 1
  _seen_stamp_refresh "$file"
  stamp="$SEEN_STAMP_VALUE"
  if [[ "$SEEN_CACHE_FILE" != "$file" || "$SEEN_CACHE_STAMP" != "$stamp" ]]; then
    SEEN_CACHE_FILE="$file"
    SEEN_CACHE_STAMP="$stamp"
    SEEN_CACHE_INDEX=$'\n'"$(<"$file")"$'\n'
  fi
  case "$SEEN_CACHE_INDEX" in
    *$'\n'"$id"$'\n'*) return 0 ;;
  esac
  return 1
}

# seen_record FILE - append the ids on stdin (one per line) to FILE,
# atomically and mode 600. Best effort: a state write problem must never
# fail the caller, so atomic_write's die is contained in the subshell.
seen_record() {
  local file="$1"
  (
    {
      [[ ! -f "$file" ]] || cat "$file"
      cat
    } | atomic_write "$file" 600
  ) 2>/dev/null || true
  SEEN_CACHE_FILE=""
  SEEN_CACHE_STAMP=""
  SEEN_CACHE_INDEX=""
  # Drop the per-tick stamp memo so the just-appended id is visible to the
  # next seen_contains even when the write lands in the same SECONDS tick.
  SEEN_STAMP_FILE=""
  SEEN_STAMP_SECONDS=""
  SEEN_STAMP_VALUE=""
}
