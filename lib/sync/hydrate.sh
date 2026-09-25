#!/bin/bash
# hydrate.sh - remote path resolution and rclone copy argv shared by
# `sciebo hydrate` and `sciebo download`'s directory path. Split out of
# lib/commands/hydrate.sh: neither resolver is hydrate-command-specific.

HYDRATE_ARGS=()
HYDRATE_DEST=""
HYDRATE_FILTER=""
HYDRATE_NAME=""

# hydrate_resolve SUB - set HYDRATE_DEST, HYDRATE_FILTER, and HYDRATE_NAME
# from the first valid manifest entry whose remote subdir equals SUB or is a
# parent of it (the remaining relative path is appended to its local
# directory). Without a match the destination is FOLDERS_LOCAL_ROOT/SUB and
# the name falls back to entry_name_for SUB.
hydrate_resolve() {
  local sub="$1" root=""
  HYDRATE_FILTER=""
  HYDRATE_NAME=""
  if manifest_resolve_local "$sub" HYDRATE_DEST; then
    HYDRATE_FILTER="$MANIFEST_MATCH_FILTER"
    HYDRATE_NAME="$MANIFEST_MATCH_NAME"
    return 0
  fi
  root=${ strip_trailing_slashes "$FOLDERS_LOCAL_ROOT";}
  # shellcheck disable=SC2034  # out-param read by cmd_hydrate/download.sh
  HYDRATE_DEST="${root}/${sub}"
  HYDRATE_NAME="$(entry_name_for "$sub")"
  return 0
}

# hydrate_remote_exists SPEC - true when the remote directory exists.
hydrate_remote_exists() {
  local spec="$1"
  remote_dir_exists "$spec"
}

# hydrate_build_args SUB DEST APPLY - fill HYDRATE_ARGS with the rclone copy
# invocation: sync's filter layering (server-exclude, clutter, pair filter,
# conflict and hidden exclusions, blacklist excludes) plus one-line stats.
# APPLY=false adds --dry-run; nothing is written by this function.
hydrate_build_args() {
  local sub="$1" dest="$2" apply="${3:-true}" pattern="" server_filter="" excluded_n=0
  HYDRATE_ARGS=(copy "${REMOTE_PREFIX}/${sub}/" "${dest}/")
  server_filter="$(filter_server_filter_file)"
  if [[ -n "$server_filter" && -n "${SERVER_EXCLUDE_FILTER:-}" ]]; then
    HYDRATE_ARGS+=(--filter-from "$SERVER_EXCLUDE_FILTER")
  fi
  HYDRATE_ARGS+=(--filter-from "${FILTER_DIR}/clutter.txt")
  [[ -z "$HYDRATE_FILTER" ]] || HYDRATE_ARGS+=(--filter-from "${FILTER_DIR}/${HYDRATE_FILTER}")
  [[ "${CONFLICT_UPLOAD:-0}" -ne 0 ]] || HYDRATE_ARGS+=(--exclude "*${CONFLICT_PATTERN:-conflicted copy}*")
  [[ "${SKIP_HIDDEN:-0}" -ne 1 ]] || HYDRATE_ARGS+=(--exclude ".*")
  while IFS= read -r pattern; do
    [[ -n "$pattern" ]] || continue
    HYDRATE_ARGS+=(--exclude "$pattern")
    excluded_n=$((excluded_n + 1))
  done < <(blacklist_excluded "${HYDRATE_NAME:-$sub}" 2>/dev/null || true)
  if [[ "$excluded_n" -gt 0 ]]; then
    warn "${HYDRATE_NAME:-$sub}: ${excluded_n} blacklisted path(s) excluded after repeated failures; run '${CLI_NAME} retry ${HYDRATE_NAME:-$sub}' to try them again"
  fi
  HYDRATE_ARGS+=(--exclude-if-present .nosync)
  HYDRATE_ARGS+=(--stats-one-line --log-level "$LOG_LEVEL")
  [[ "$apply" == true ]] || HYDRATE_ARGS+=(--dry-run)
}
