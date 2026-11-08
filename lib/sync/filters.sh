#!/bin/bash
# filters.sh - domain filter rules shared by the sync/pull and ignored
# rclone-argument builders. Split from lib/adapters/rclone.sh: it calls
# blacklist_excluded (lib/state/blacklist.sh), a rank above adapters.

# filter_server_filter_enabled - rc 0 when the server filter should be
# layered under every source: FILTER_SERVER_SYNC=1 and a non-empty generated
# filter file at SERVER_EXCLUDE_FILTER. The `-s` test covers the file's
# existence, non-emptiness, and the path being set in one shell stat, so the
# sync entry loop never forks a `cat` just to learn whether the file has any
# content (filter_server_filter_file below still prints it for callers that
# need the body).
filter_server_filter_enabled() {
  [[ "${FILTER_SERVER_SYNC:-0}" == 1 && -s "${SERVER_EXCLUDE_FILTER:-}" ]]
}

# filter_server_filter_file - print the generated server filter when
# FILTER_SERVER_SYNC=1 and the file exists; print nothing otherwise. Always
# returns 0 so the sync/hydrate/ignored integrations can call it
# unconditionally.
filter_server_filter_file() {
  [[ "${FILTER_SERVER_SYNC:-0}" == "1" ]] || return 0
  local file="${SERVER_EXCLUDE_FILTER:-}"
  [[ -n "$file" && -f "$file" ]] || return 0
  cat "$file" 2>/dev/null || true
  return 0
}

# rclone_filter_excludes ARGS_NAME NAME RETRY_CLI - append the filter layer
# shared by the sync/pull and ignored builders, in this order: the
# conflict-copy exclusion (unless CONFLICT_UPLOAD=1), the hidden-file
# exclusion (SKIP_HIDDEN=1), then one --exclude per failure-blacklisted path,
# warning once when any applied. ARGS_NAME is an argv array name; RETRY_CLI
# is the command named in the warning.
rclone_filter_excludes() {
  # shellcheck disable=SC2178  # nameref to an argv array
  local -n args_ref="$1"
  local name="$2" retry_cli="$3" pattern="" excluded_n=0 excluded=""
  [[ "${CONFLICT_UPLOAD:-0}" -ne 0 ]] || args_ref+=(--exclude "*${CONFLICT_PATTERN:-conflicted copy}*")
  [[ "${SKIP_HIDDEN:-0}" -ne 1 ]] || args_ref+=(--exclude ".*")
  # Forkless capture instead of `< <(blacklist_excluded ...)`: blacklist_excluded
  # only prints and reads its record file, so running it here drops the
  # per-entry subshell. The `|| true` keeps the old `<(... || true)` contract:
  # whatever was printed before a failure is still iterated, and rc stays 0.
  # The non-empty guard below also skips the blank line a here-string appends.
  excluded=${ blacklist_excluded "$name" 2>/dev/null;} || true
  while IFS= read -r pattern; do
    [[ -n "$pattern" ]] || continue
    args_ref+=(--exclude "$pattern")
    excluded_n=$((excluded_n + 1))
  done <<<"$excluded"
  if [[ "$excluded_n" -gt 0 ]]; then
    warn "${name}: ${excluded_n} blacklisted path(s) excluded after repeated failures; run '${retry_cli} retry ${name}' to try them again"
  fi
}

# filter_entry_args FLAGS - append the per-entry filter stack to the named
# argv array in order: server filter, clutter/entry filters, conflict and
# hidden excludes, blacklist excludes (one warning when any applied), then
# the name policy and per-entry policy excludes. Shared by sync and verify so
# both skip the same files.
filter_entry_args() {
  # shellcheck disable=SC2178  # nameref to an argv array
  local -n args_ref="$1"
  local i=0
  # Only the existence of a non-empty server filter matters here; the file
  # body reaches rclone through the path below, so no `cat` of the whole
  # file runs per entry.
  if filter_server_filter_enabled; then
    args_ref+=(--filter-from "$SERVER_EXCLUDE_FILTER")
  fi
  args_ref+=(--filter-from "${FILTER_DIR}/clutter.txt")
  [[ -z "$ENTRY_FILTER" ]] || args_ref+=(--filter-from "${FILTER_DIR}/${ENTRY_FILTER}")
  rclone_filter_excludes "$1" "$ENTRY_NAME" sciebo
  # A pair imported with the desktop client's ignoreHiddenFiles gets the same
  # dotfile exclusion as the global SKIP_HIDDEN=1 (which rclone_filter_excludes
  # already added), so hidden files are not transferred for that pair alone.
  if [[ "${SKIP_HIDDEN:-0}" -ne 1 ]] && manifest_pair_hidden "$ENTRY_NAME"; then
    args_ref+=(--exclude ".*")
  fi
  policy_name_exclude_args args_ref
  if [[ "${#SYNC_POLICY_EXCLUDES[@]}" -gt 0 ]]; then
    i=0
    while [[ "$i" -lt "${#SYNC_POLICY_EXCLUDES[@]}" ]]; do
      args_ref+=(--exclude "${SYNC_POLICY_EXCLUDES[$i]}")
      i=$((i + 1))
    done
  fi
}
