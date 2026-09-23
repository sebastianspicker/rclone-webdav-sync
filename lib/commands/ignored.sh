#!/bin/bash
# ignored.sh command module - list the local files that sync would not
# transfer (the desktop client's "Not synced" tab analog). Read-only: each
# entry's local directory is listed twice with `rclone lsf`, once unfiltered
# and once with sync's local filter layering, and the difference is
# reported. No lock is taken and no remote is contacted; the remote only
# has to be configured.
#
# Mirrors sync_build_args for the listing context: the generated
# server-exclude filter (FILTER_SERVER_SYNC=1), clutter.txt, the entry's
# pair filter, the conflict-pattern exclusion (unless CONFLICT_UPLOAD=1),
# the hidden-file exclusion (SKIP_HIDDEN=1), the failure-blacklist
# excludes, and --exclude-if-present .nosync for sync/pull entries.
# Transfer-shaping flags (stats, retries, bandwidth, chunk size) do not
# change which paths a transfer touches and are omitted.

# Path prefix requested on the command line (empty = no filter) and whether
# one was given.
IGNORED_SUB=""
IGNORED_SUB_SET=0
# Reported ignored files across all scanned entries.
IGNORED_TOTAL=0
# rclone lsf argv for the entry being scanned, filled by ignored_scan_args:
# the unfiltered listing and the listing with sync's local filter layering.
IGNORED_SCAN_ALL_ARGS=()
IGNORED_SCAN_INC_ARGS=()

usage_ignored() {
  usage_emit <<'EOF'
Usage: sciebo ignored [SUB] [options]

List local files that sync would not transfer: clutter.txt and pair-filter
matches, conflict copies, hidden files (SKIP_HIDDEN=1), server-excluded
paths (FILTER_SERVER_SYNC=1), failure-blacklisted paths, and everything
under a .nosync marker for sync/pull entries. SUB restricts the result to
files under a local, local-relative, or remote-relative path prefix.

Options:
  --source NAME  restrict the scan to one configured source
  --json         print {"ignored":[{"source","local","path"}]}
  -h, --help     show this help
EOF
}

# ignored_match_sub LOCAL REL REMOTE - true when REL (relative to the
# entry's local directory), LOCAL (absolute), or REMOTE (relative to the
# remote base) is under IGNORED_SUB, so the local and remote path forms
# both work.
ignored_match_sub() {
  local local_path="$1" rel="$2" remote_rel="$3"
  [[ "$rel" == "$IGNORED_SUB" || "$rel" == "$IGNORED_SUB/"* ]] && return 0
  [[ "$local_path" == "$IGNORED_SUB" || "$local_path" == "$IGNORED_SUB/"* ]] && return 0
  [[ "$remote_rel" == "$IGNORED_SUB" || "$remote_rel" == "$IGNORED_SUB/"* ]] && return 0
  return 1
}

# ignored_scan_args DIR - build the unfiltered and filtered `rclone lsf` argv
# for the entry currently parsed into ENTRY_* into IGNORED_SCAN_ALL_ARGS and
# IGNORED_SCAN_INC_ARGS. Mirrors sync_build_args for the listing context.
ignored_scan_args() {
  local dir="$1" server_filter=""
  IGNORED_SCAN_ALL_ARGS=(lsf -R --files-only "$dir")
  IGNORED_SCAN_INC_ARGS=(lsf -R --files-only)
  if [[ -f "${FILTER_DIR}/clutter.txt" ]]; then
    IGNORED_SCAN_INC_ARGS+=(--filter-from "${FILTER_DIR}/clutter.txt")
  fi
  [[ -z "$ENTRY_FILTER" ]] || IGNORED_SCAN_INC_ARGS+=(--filter-from "${FILTER_DIR}/${ENTRY_FILTER}")
  if type -t filter_server_filter_file >/dev/null 2>&1; then
    server_filter="$(filter_server_filter_file)"
  fi
  if [[ -n "$server_filter" && -n "${SERVER_EXCLUDE_FILTER:-}" ]]; then
    IGNORED_SCAN_INC_ARGS+=(--filter-from "$SERVER_EXCLUDE_FILTER")
  fi
  rclone_filter_excludes IGNORED_SCAN_INC_ARGS "$ENTRY_NAME" "$CLI_NAME"
  # Mirror sync's per-pair hidden exclusion: a pair imported with the desktop
  # client's ignoreHiddenFiles excludes dotfiles even when SKIP_HIDDEN is off,
  # so those files show up as not synced here too.
  if [[ "${SKIP_HIDDEN:-0}" -ne 1 ]] && manifest_pair_hidden "$ENTRY_NAME"; then
    IGNORED_SCAN_INC_ARGS+=(--exclude ".*")
  fi
  case "$ENTRY_MODE" in
    sync | pull) IGNORED_SCAN_INC_ARGS+=(--exclude-if-present .nosync) ;;
  esac
  IGNORED_SCAN_INC_ARGS+=("$dir")
  return 0
}

# ignored_report_diff DIR ALL_FILE INC_FILE - print one row per line of
# ALL_FILE that INC_FILE does not contain, honoring IGNORED_SUB and the
# active output mode, and advance IGNORED_TOTAL.
ignored_report_diff() {
  local dir="$1" all_file="$2" inc_file="$3"
  local rel="" local_path="" remote_rel=""
  local -a all_lines=() inc_lines=()
  local -A inc_seen=()
  # `comm -23 <(sort all) <(sort inc)` is exactly "sorted all-file lines
  # whose text is not in inc"; a membership set replaces the second sort and
  # the external comm, and the all-file sort keeps the output order.
  mapfile -t inc_lines <"$inc_file"
  for rel in "${inc_lines[@]}"; do
    [[ -n "$rel" ]] || continue
    inc_seen["$rel"]=1
  done
  mapfile -t all_lines < <(LC_ALL=C sort "$all_file")
  for rel in "${all_lines[@]}"; do
    [[ -n "$rel" ]] || continue
    [[ -z "${inc_seen[$rel]:-}" ]] || continue
    local_path="${dir%/}/${rel}"
    remote_rel="${ENTRY_REMOTE%/}/${rel}"
    if [[ "$IGNORED_SUB_SET" -eq 1 ]] && ! ignored_match_sub "$local_path" "$rel" "$remote_rel"; then
      continue
    fi
    if output_json_enabled; then
      output_json_object_begin
      output_json_kv source "$ENTRY_NAME"
      output_json_kv local "$local_path"
      output_json_kv path "$rel"
      output_json_object_end
    else
      printf '%s\t%s\t%s\n' "$ENTRY_NAME" "$local_path" "$rel"
    fi
    IGNORED_TOTAL=$((IGNORED_TOTAL + 1))
  done
  return 0
}

# ignored_scan_entry - list the ignored files of the entry currently parsed
# into ENTRY_* and print one row per file; IGNORED_TOTAL is advanced. The
# unfiltered and filtered listings go to temp files so an rclone failure is
# a warning for that entry instead of a partial result. Returns 1 when a
# listing failed.
ignored_scan_entry() {
  local dir="" all_file="" inc_file="" rc=0
  dir=${ strip_trailing_slashes "$ENTRY_LOCAL";}
  ignored_scan_args "$dir"
  temp_mktemp_into all_file "${TMPDIR:-/tmp}/sciebo-ignored.XXXXXX" || {
    warn "ignored: cannot create a temporary file for '${ENTRY_NAME}'"
    return 1
  }
  temp_mktemp_into inc_file "${TMPDIR:-/tmp}/sciebo-ignored.XXXXXX" || {
    temp_discard "$all_file"
    warn "ignored: cannot create a temporary file for '${ENTRY_NAME}'"
    return 1
  }
  rclone_cmd "${IGNORED_SCAN_ALL_ARGS[@]}" >"$all_file" 2>/dev/null || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    rclone_cmd "${IGNORED_SCAN_INC_ARGS[@]}" >"$inc_file" 2>/dev/null || rc=$?
  fi
  if [[ "$rc" -ne 0 ]]; then
    temp_discard "$all_file"
    temp_discard "$inc_file"
    warn "ignored: cannot list '${ENTRY_NAME}' (${dir}): rclone exit ${rc}"
    return 1
  fi
  ignored_report_diff "$dir" "$all_file" "$inc_file"
  temp_discard "$all_file"
  temp_discard "$inc_file"
  return 0
}

cmd_ignored() {
  local sub="" source_filter="" line="" failures=0
  opt_begin "source:s json:b" ignored "" "$@"
  # Run dependencies load after opt_begin's --help exit, so
  # `sciebo ignored --help` parses none of them: the record/blacklist
  # excludes, the generated server-exclude filter mirrored by the listing
  # (guarded by `type -t` below, but it must be loaded), and the manifest
  # walkers.
  sciebo_require_module blacklist blacklist_record_many
  sciebo_require_module commands/filters filter_server_filter_file
  sciebo_require_module manifest manifest_each
  # SUB is optional (MIN 0); a second positional is rejected with the same
  # wording the inline check used.
  opt_require_sub ignored "SUB" "${OPT_EXTRA:-}" 0
  sub="${POSITIONAL_ARGS[0]:-}"
  IGNORED_SUB=${ strip_trailing_slashes "$sub";}
  IGNORED_SUB_SET=0
  [[ -z "$sub" ]] || IGNORED_SUB_SET=1
  source_filter="${OPT_source:-}"
  opt_json_mode
  load_settings
  require_remote
  if [[ -n "$source_filter" ]]; then
    manifest_require_name "$source_filter"
  fi
  IGNORED_TOTAL=0
  if output_json_enabled; then
    output_json_list_begin ignored
  fi
  while IFS= read -r line; do
    if ! manifest_parse_line "$line"; then
      warn "ignored: ignoring invalid source line: ${ENTRY_ERROR}"
      continue
    fi
    if [[ -n "$source_filter" && "$ENTRY_NAME" != "$source_filter" ]]; then
      continue
    fi
    if [[ ! -d "$ENTRY_LOCAL" ]]; then
      warn "ignored: skipping '${ENTRY_NAME}' (local directory missing: ${ENTRY_LOCAL})"
      continue
    fi
    ignored_scan_entry || failures=$((failures + 1))
  done < <(manifest_lines)
  if output_json_enabled; then
    output_json_list_end
  elif [[ "$IGNORED_TOTAL" -eq 0 ]]; then
    printf 'no ignored files\n'
  else
    printf '%s ignored files\n' "$IGNORED_TOTAL"
  fi
  [[ "$failures" -eq 0 ]]
}
