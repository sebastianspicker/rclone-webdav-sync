#!/bin/bash
# hydrate.sh command module - download a remote path below the remote base
# on demand (the VFS "keep downloaded" analog). Resolves the destination
# from the manifest (or FOLDERS_LOCAL_ROOT) and copies once with the same
# filter layering sync uses; runstate records are not written.

HYDRATE_ARGS=()
HYDRATE_DEST=""
HYDRATE_FILTER=""
HYDRATE_NAME=""
HYDRATE_APPLY=true
HYDRATE_QUIET=0

usage_hydrate() {
  usage_emit <<'EOF'
Usage: sciebo hydrate SUB [options]

Download a remote path below the remote base on demand. SUB is copied
with the same filter layering as sync: the server-exclude filter (when
FILTER_SERVER_SYNC=1), clutter.txt, the matching manifest entry's filter
file, the conflict-pattern exclusion (unless CONFLICT_UPLOAD=1), hidden
files (when SKIP_HIDDEN=1), the failure-blacklist excludes, and .nosync
markers.

The destination is the local directory of the first manifest entry whose
remote_subdir equals SUB or is a parent of SUB, with the remaining
relative path appended; without a match it is FOLDERS_LOCAL_ROOT/SUB.
With --dest DIR the contents of SUB are copied into DIR instead (the
matching manifest entry's filter still applies).

Options:
  --dest DIR  copy into DIR instead of the resolved destination
  --dry-run   report what would be copied; changes nothing
  --quiet     do not print the success line (rclone output still shows)
  --json      print {"path","dest","dry_run"} instead of the text line
  --progress  show rclone's transfer progress (terminal only; suppressed by
              --quiet and --json)
  -h, --help  show this help
EOF
}

# hydrate_resolve SUB - set HYDRATE_DEST, HYDRATE_FILTER, and HYDRATE_NAME
# from the first valid manifest entry whose remote subdir equals SUB or is a
# parent of it (the remaining relative path is appended to its local
# directory). Without a match the destination is FOLDERS_LOCAL_ROOT/SUB and
# the name falls back to entry_name_for SUB.
hydrate_resolve() {
  local sub="$1" root=""
  # Cross-module helper (download reuses it): own the manifest require so
  # both entry paths work whether or not cmd_hydrate ran.
  sciebo_require_module manifest manifest_resolve_local
  HYDRATE_FILTER=""
  HYDRATE_NAME=""
  if manifest_resolve_local "$sub" HYDRATE_DEST; then
    HYDRATE_FILTER="$MANIFEST_MATCH_FILTER"
    HYDRATE_NAME="$MANIFEST_MATCH_NAME"
    return 0
  fi
  root=${ strip_trailing_slashes "$FOLDERS_LOCAL_ROOT";}
  HYDRATE_DEST="${root}/${sub}"
  HYDRATE_NAME="$(entry_name_for "$sub")"
  return 0
}

# hydrate_remote_exists SPEC - true when the remote directory exists. Prefer
# the shared helper; fall back to a direct listing so the module also works
# in stripped-down contexts.
hydrate_remote_exists() {
  local spec="$1"
  if type -t remote_dir_exists >/dev/null 2>&1; then
    remote_dir_exists "$spec"
    return $?
  fi
  rclone_cmd lsf "$spec/" >/dev/null 2>&1
}

# hydrate_build_args SUB DEST - fill HYDRATE_ARGS with the rclone copy
# invocation: sync's filter layering (server-exclude, clutter, pair filter,
# conflict and hidden exclusions, blacklist excludes) plus one-line stats. A
# dry run adds --dry-run; nothing is written by this function.
hydrate_build_args() {
  local sub="$1" dest="$2" pattern="" server_filter="" excluded_n=0
  # blacklist.sh and the generated server-exclude filter load here (before
  # the `type -t` probe) so the layering works on cmd_hydrate's path and
  # wherever else this builder is reused.
  sciebo_require_module blacklist blacklist_excluded
  sciebo_require_module commands/filters filter_server_filter_file
  HYDRATE_ARGS=(copy "${REMOTE_PREFIX}/${sub}/" "${dest}/")
  if type -t filter_server_filter_file >/dev/null 2>&1; then
    server_filter="$(filter_server_filter_file)"
  fi
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
  [[ "$HYDRATE_APPLY" == true ]] || HYDRATE_ARGS+=(--dry-run)
}

cmd_hydrate() {
  local sub="" dest="" rc=0 dry_json=false
  opt_begin "dest:s dry-run:b quiet:b json:b progress:b" hydrate "" "$@"
  # Count and emptiness through the shared positional rules; path safety
  # stays with require_safe_remote_path afterwards.
  opt_require_sub hydrate "SUB" "${OPT_EXTRA:-}" 1 1 "at most one SUB argument is allowed"
  sub="${POSITIONAL_ARGS[0]:-}"
  sub=${ strip_trailing_slashes "$sub";}
  require_safe_remote_path "$sub"
  # Run dependencies load after the help/usage exits, so
  # `sciebo hydrate --help` parses none of them: rclone_cmd and the
  # progress argv helpers live in rclone.sh (kept for sourced-alone use),
  # and lock.sh loads before acquire_lock so the EXIT trap can release it.
  sciebo_require_module rclone rclone_cmd
  sciebo_require_module lock acquire_lock
  opt_json_mode
  HYDRATE_APPLY=true
  opt_into HYDRATE_APPLY dry_run false
  HYDRATE_QUIET=0
  opt_into HYDRATE_QUIET quiet 1
  load_settings
  require_remote
  hydrate_resolve "$sub"
  [[ -z "${OPT_dest:-}" ]] || HYDRATE_DEST=${ expand_local_path "$OPT_dest";}
  dest=${ strip_trailing_slashes "$HYDRATE_DEST";}
  [[ -n "$dest" ]] || die "cannot resolve a destination for '${sub}'"
  if ! hydrate_remote_exists "$(remote_spec "$sub")"; then
    die "remote path not found: ${REMOTE_PREFIX}/${sub}"
  fi
  hydrate_build_args "$sub" "$dest"
  progress_append_args HYDRATE_ARGS "$HYDRATE_QUIET"
  if output_json_enabled; then
    # The lock may initialize the state layout, which logs to stdout; keep
    # stdout reserved for the JSON document.
    acquire_lock >&2
  else
    acquire_lock
  fi
  if [[ "$HYDRATE_APPLY" == true ]]; then
    mkdir -p "$dest" || die "cannot create destination: ${dest}"
  fi
  rc=0
  rclone_cmd "${HYDRATE_ARGS[@]}" || rc=$?
  [[ "$rc" -eq 0 ]] || die "rclone copy failed (exit ${rc}) for ${sub}"
  if output_json_enabled; then
    [[ "$HYDRATE_APPLY" == true ]] || dry_json=true
    output_json_begin
    output_json_kv path "$sub"
    output_json_kv dest "$dest"
    output_json_kv_raw dry_run "$dry_json"
    output_json_end
  elif [[ "$HYDRATE_QUIET" -eq 0 ]]; then
    if [[ "$HYDRATE_APPLY" == true ]]; then
      printf 'hydrated %s -> %s\n' "$sub" "$dest"
    else
      printf 'hydrate: dry run, nothing copied\n'
    fi
  fi
  return 0
}
