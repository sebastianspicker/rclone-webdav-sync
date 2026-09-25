#!/bin/bash
# hydrate.sh command module - download a remote path below the remote base
# on demand (the VFS "keep downloaded" analog). Resolves the destination
# from the manifest (or FOLDERS_LOCAL_ROOT) and copies once with the same
# filter layering sync uses; runstate records are not written. The path
# resolver and argv builder (hydrate_resolve, hydrate_remote_exists,
# hydrate_build_args) live in lib/sync/hydrate.sh: download.sh's directory
# path calls them directly too.

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

cmd_hydrate() {
  local sub="" dest="" rc=0 dry_json=false apply=true
  opt_begin "dest:s dry-run:b quiet:b json:b progress:b" hydrate "" "$@"
  # Count and emptiness through the shared positional rules; path safety
  # stays with require_safe_remote_path afterwards.
  opt_require_sub hydrate "SUB" "${OPT_EXTRA:-}" 1 1 "at most one SUB argument is allowed"
  sub="${POSITIONAL_ARGS[0]:-}"
  sub=${ strip_trailing_slashes "$sub";}
  require_safe_remote_path "$sub"
  opt_json_mode
  opt_into apply dry_run false
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
  hydrate_build_args "$sub" "$dest" "$apply"
  progress_append_args HYDRATE_ARGS "$HYDRATE_QUIET"
  if output_json_enabled; then
    # The lock may initialize the state layout, which logs to stdout; keep
    # stdout reserved for the JSON document.
    acquire_lock >&2
  else
    acquire_lock
  fi
  if [[ "$apply" == true ]]; then
    mkdir -p "$dest" || die "cannot create destination: ${dest}"
  fi
  rc=0
  rclone_cmd "${HYDRATE_ARGS[@]}" || rc=$?
  [[ "$rc" -eq 0 ]] || die "rclone copy failed (exit ${rc}) for ${sub}"
  if output_json_enabled; then
    [[ "$apply" == true ]] || dry_json=true
    output_json_begin
    output_json_kv path "$sub"
    output_json_kv dest "$dest"
    output_json_kv_raw dry_run "$dry_json"
    output_json_end
  elif [[ "$HYDRATE_QUIET" -eq 0 ]]; then
    if [[ "$apply" == true ]]; then
      printf 'hydrated %s -> %s\n' "$sub" "$dest"
    else
      printf 'hydrate: dry run, nothing copied\n'
    fi
  fi
  return 0
}
