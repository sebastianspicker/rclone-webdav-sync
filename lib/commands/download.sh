#!/bin/bash
# download.sh command module - download a remote path below the remote base.
#
# A single file is fetched over WebDAV through lib/adapters/http.sh (binary-safe, and
# resumable with --resume/--continue via curl's `-C -`); a destination that
# already matches the remote size is skipped unless --force. A directory (or
# a DEST ending in "/") falls back to `rclone copy` with hydrate's filter
# layering and reports the copied byte/file counts from rclone's JSON stats.
# SUB is validated with the shared safe-remote-path helper; no raw curl is
# used and no secret is ever printed.

DOWNLOAD_IS_DIR=false
DOWNLOAD_REMOTE_SIZE=""
DOWNLOAD_QUIET=0
DOWNLOAD_APPLY=true
DOWNLOAD_SKIPPED=0
DOWNLOAD_FILES=0
DOWNLOAD_BYTES=0
DOWNLOAD_SUB=""
DOWNLOAD_DEST_ARG=""
DOWNLOAD_MODE=""
DOWNLOAD_IS_NEXTCLOUD=0

usage_download() {
  usage_emit <<'EOF'
Usage: sciebo download SUB [DEST] [options]

Download a remote path below <RCLONE_REMOTE>:<REMOTE_BASE>/.

A single file is fetched over WebDAV to DEST (default: the basename under
the current directory, or below DOWNLOAD_DIR when that setting is set). A
DEST that already matches the remote size is left alone unless --force is
given; --resume (alias --continue) continues a partial DEST with a range
request. A directory (or a DEST ending in "/") is copied with rclone using
the same filter layering as hydrate.

Options:
  --dry-run    report what would be transferred; change nothing
  --force      download even when DEST already matches the remote
  --resume     continue a partial file
  --continue   continue a partial file (alias of --resume)
  --quiet      do not print the success line
  --json       print a structured summary instead of the text line
  --progress   show rclone's transfer progress (rclone transfers only;
               terminal only, and suppressed by --quiet and --json)
  -h, --help   show this help
EOF
}

# download_default_dest SUB - the default file destination: the basename of
# SUB below DOWNLOAD_DIR when set, else the basename under the current
# directory.
download_default_dest() {
  local name="${1##*/}"
  if [[ -n "${DOWNLOAD_DIR:-}" ]]; then
    printf '%s/%s' "${DOWNLOAD_DIR%/}" "$name"
  else
    printf '%s' "./${name}"
  fi
}

# download_dav_info SUB - non-fatal Depth-0 PROPFIND for SUB. Fills
# DOWNLOAD_IS_DIR and DOWNLOAD_REMOTE_SIZE. rc 1 when the path cannot be
# read (missing or a non-2xx response); transport failures die through the
# shared HTTP layer.
download_dav_info() {
  local sub="$1" url="" body="" size=""
  DOWNLOAD_IS_DIR=false
  DOWNLOAD_REMOTE_SIZE=""
  url="$(nc_path_url "${REMOTE_BASE}/${sub}")"
  nc_dav_request_allow PROPFIND "$url" 0 "$NC_FILE_INFO_BODY"
  http_ok_code_2xx "$HTTP_CODE" || return 1
  body="$HTTP_BODY"
  case "$body" in
    *'<d:collection'*) DOWNLOAD_IS_DIR=true ;;
  esac
  size="$(xml_get "$body" 'oc:size')"
  [[ -n "$size" ]] || size="$(xml_get "$body" 'd:getcontentlength')"
  DOWNLOAD_REMOTE_SIZE="$size"
  return 0
}

# download_remote_stat SPEC - classify a non-Nextcloud remote path with the
# shared `rclone lsjson --stat` probe; sets DOWNLOAD_IS_DIR. rc 1 when the path
# cannot be inspected.
download_remote_stat() {
  local spec="$1" is_dir=0
  DOWNLOAD_IS_DIR=false
  rclone_stat_is_dir "$spec" is_dir || return 1
  [[ "$is_dir" -eq 0 ]] || DOWNLOAD_IS_DIR=true
  return 0
}

# download_stats_counts JSON - print "BYTES<TAB>FILES" from the last rclone
# --use-json-log "stats" object, or "0<TAB>0" when there is none.
download_stats_counts() {
  printf '%s\n' "${1:-}" | LC_ALL=C awk '
    /"stats":/ { line = $0 }
    END {
      bytes = 0
      files = 0
      if (match(line, /"bytes":[ \t]*[0-9]+/)) {
        bytes = substr(line, RSTART, RLENGTH)
        sub(/.*:[ \t]*/, "", bytes)
      }
      if (match(line, /"transfers":[ \t]*[0-9]+/)) {
        files = substr(line, RSTART, RLENGTH)
        sub(/.*:[ \t]*/, "", files)
      }
      printf "%s\t%s", bytes, files
    }
  '
}

# download_emit_json SUB DEST MODE [SKIPPED] - print the JSON result shared by
# the file and directory emitters. The `skipped` field is emitted only when the
# optional SKIPPED argument is given (download_emit_file always passes it,
# download_emit_dir never does).
download_emit_json() {
  local sub="$1" dest="$2" mode="$3" skipped="${4:-}" dry=false
  [[ "$DOWNLOAD_APPLY" == true ]] || dry=true
  output_json_begin
  output_json_kv path "$sub"
  output_json_kv dest "$dest"
  output_json_kv mode "$mode"
  output_json_kv_raw dry_run "$dry"
  [[ -z "$skipped" ]] || output_json_kv_raw skipped "$skipped"
  output_json_kv_raw files "$DOWNLOAD_FILES"
  output_json_kv_raw bytes "$DOWNLOAD_BYTES"
  output_json_end
}

# download_emit_file SUB DEST - print the file result as the text line or the
# JSON document.
download_emit_file() {
  local sub="$1" dest="$2" skip=false
  if output_json_enabled; then
    [[ "$DOWNLOAD_SKIPPED" -eq 0 ]] || skip=true
    download_emit_json "$sub" "$dest" file "$skip"
    return 0
  fi
  [[ "$DOWNLOAD_QUIET" -eq 0 ]] || return 0
  if [[ "$DOWNLOAD_APPLY" != true ]]; then
    printf 'download: dry run, would download %s -> %s\n' "$sub" "$dest"
  elif [[ "$DOWNLOAD_SKIPPED" -eq 1 ]]; then
    printf 'download: %s already complete (use --force to download again)\n' "$dest"
  else
    printf 'downloaded %s -> %s\n' "$sub" "$dest"
  fi
}

# download_emit_dir SUB DEST - print the directory result with the copied
# file/byte counts.
download_emit_dir() {
  local sub="$1" dest="$2"
  if output_json_enabled; then
    download_emit_json "$sub" "$dest" directory
    return 0
  fi
  [[ "$DOWNLOAD_QUIET" -eq 0 ]] || return 0
  if [[ "$DOWNLOAD_APPLY" != true ]]; then
    printf 'download: dry run, would copy %s file(s) (%s bytes)\n' \
      "$DOWNLOAD_FILES" "$DOWNLOAD_BYTES"
  else
    printf 'downloaded %s -> %s (%s file(s), %s bytes)\n' \
      "$sub" "$dest" "$DOWNLOAD_FILES" "$DOWNLOAD_BYTES"
  fi
}

# download_dav_file SUB DEST FORCE RESUME - GET SUB over WebDAV into DEST.
# Skips the transfer when DEST matches the remote size (unless FORCE or
# RESUME) and continues a partial DEST with `-C -` when RESUME. The body goes
# through the shared http_fetch_to_file, so a DEST that is a symlink is
# refused and a failed request never truncates an existing DEST.
download_dav_file() {
  local sub="$1" dest="$2" force="$3" resume="$4" url="" size=0
  local -a resume_arg=()
  url="$(nc_path_url "${REMOTE_BASE}/${sub}")"
  DOWNLOAD_SKIPPED=0
  DOWNLOAD_FILES=0
  DOWNLOAD_BYTES=0
  if [[ "$DOWNLOAD_APPLY" != true ]]; then
    DOWNLOAD_FILES=1
    DOWNLOAD_BYTES="${DOWNLOAD_REMOTE_SIZE:-0}"
    download_emit_file "$sub" "$dest"
    return 0
  fi
  if [[ "$force" -eq 0 && -f "$dest" && -n "$DOWNLOAD_REMOTE_SIZE" ]]; then
    size="$(wc -c <"$dest" | tr -d ' ')"
    if [[ "$size" == "$DOWNLOAD_REMOTE_SIZE" ]]; then
      DOWNLOAD_SKIPPED=1
      download_emit_file "$sub" "$dest"
      return 0
    fi
  fi
  mkdir -p "$(dirname "$dest")" || die "cannot create destination for ${dest}"
  [[ "$resume" -eq 0 || ! -f "$dest" ]] || resume_arg=(-C -)
  http_fetch_to_file "$url" "$dest" "" ${resume_arg[@]+"${resume_arg[@]}"}
  DOWNLOAD_FILES=1
  if [[ -n "$DOWNLOAD_REMOTE_SIZE" ]]; then
    DOWNLOAD_BYTES="$DOWNLOAD_REMOTE_SIZE"
  else
    DOWNLOAD_BYTES="$(wc -c <"$dest" | tr -d ' ')"
  fi
  download_emit_file "$sub" "$dest"
}

# download_rclone_file SUB DEST FORCE - copy a single file with rclone for a
# non-Nextcloud remote (no DAV endpoint). FORCE re-transfers an unchanged
# destination, --dry-run is passed through.
download_rclone_file() {
  local sub="$1" dest="$2" force="$3" rc=0
  local -a args=(copyto "$(remote_spec "$sub")" "$dest")
  DOWNLOAD_SKIPPED=0
  DOWNLOAD_FILES=0
  DOWNLOAD_BYTES=0
  [[ "$DOWNLOAD_APPLY" == true ]] || args+=(--dry-run)
  [[ "$force" -eq 0 ]] || args+=(--ignore-times)
  progress_append_args args "$DOWNLOAD_QUIET"
  if rclone_cmd "${args[@]}"; then rc=0; else rc=$?; fi
  [[ "$rc" -eq 0 ]] || die "rclone copy failed (exit ${rc}) for ${sub}"
  DOWNLOAD_FILES=1
  if [[ -f "$dest" ]]; then
    DOWNLOAD_BYTES="$(wc -c <"$dest" | tr -d ' ')"
  fi
  download_emit_file "$sub" "$dest"
}

# download_dir SUB DEST - copy SUB into DEST with hydrate's filter layering
# and report the copied file/byte counts from rclone's JSON stats.
download_dir() {
  local sub="$1" dest="$2" rc=0 stats="" counts=""
  hydrate_resolve "$sub"
  hydrate_build_args "$sub" "$dest" "$DOWNLOAD_APPLY"
  progress_append_args HYDRATE_ARGS "$DOWNLOAD_QUIET"
  HYDRATE_ARGS+=(--use-json-log)
  if ! hydrate_remote_exists "$(remote_spec "$sub")"; then
    die "remote path not found: ${REMOTE_PREFIX}/${sub}"
  fi
  if [[ "$DOWNLOAD_APPLY" == true ]]; then
    mkdir -p "$dest" || die "cannot create destination: ${dest}"
  fi
  if output_json_enabled; then
    acquire_lock >&2
  else
    acquire_lock
  fi
  if rclone_capture download "${HYDRATE_ARGS[@]}"; then rc=0; else rc=$?; fi
  stats="$(<"$RCLONE_CAPTURE_ERR")"
  temp_discard "${RCLONE_CAPTURE_OUT:-}"
  temp_discard "${RCLONE_CAPTURE_ERR:-}"
  [[ "$rc" -eq 0 ]] || die "rclone copy failed (exit ${rc}) for ${sub}"
  counts="$(download_stats_counts "$stats")"
  record_split "$counts" DOWNLOAD_BYTES DOWNLOAD_FILES
  download_emit_dir "$sub" "$dest"
}

# download_parse_positionals POSITIONALS - validate the raw newline-separated
# positional list (SUB [DEST]) through the shared positional-count rules and
# split it into DOWNLOAD_SUB/DOWNLOAD_DEST_ARG; SUB is then normalized and
# checked for path safety like every other remote-path argument.
# usage_error exactly like the old inline prologue.
download_parse_positionals() {
  DOWNLOAD_SUB=""
  DOWNLOAD_DEST_ARG=""
  opt_require_sub download "SUB" "${1:-}" 1 2 "at most SUB and DEST are allowed"
  DOWNLOAD_SUB="${POSITIONAL_ARGS[0]:-}"
  DOWNLOAD_DEST_ARG="${POSITIONAL_ARGS[1]:-}"
  DOWNLOAD_SUB=${ strip_trailing_slashes "$DOWNLOAD_SUB";}
  [[ -n "$DOWNLOAD_SUB" ]] || usage_error download "SUB is required"
  require_safe_remote_path "$DOWNLOAD_SUB"
}

# download_classify_mode SUB DEST_ARG - set DOWNLOAD_MODE ("file" or "dir")
# and DOWNLOAD_IS_NEXTCLOUD for the resolved SUB/DEST_ARG. Dies when the
# remote path cannot be found, exactly like the old inline classification.
download_classify_mode() {
  local sub="$1" dest_arg="$2"
  DOWNLOAD_MODE=""
  DOWNLOAD_IS_NEXTCLOUD=0
  if [[ "$dest_arg" == */ ]]; then
    DOWNLOAD_MODE="dir"
  elif remote_is_nextcloud; then
    DOWNLOAD_IS_NEXTCLOUD=1
    http_require_curl
    http_remote_info
    download_dav_info "$sub" || die "remote path not found: ${REMOTE_PREFIX}/${sub}"
    if [[ "$DOWNLOAD_IS_DIR" == true ]]; then DOWNLOAD_MODE="dir"; else DOWNLOAD_MODE="file"; fi
  elif download_remote_stat "$(remote_spec "$sub")"; then
    if [[ "$DOWNLOAD_IS_DIR" == true ]]; then DOWNLOAD_MODE="dir"; else DOWNLOAD_MODE="file"; fi
  else
    die "remote path not found: ${REMOTE_PREFIX}/${sub}"
  fi
}

cmd_download() {
  local dest="" force=0 resume=0
  opt_begin "dry-run:b force:b quiet:b json:b resume:b continue:b progress:b" download "" "$@"
  download_parse_positionals "${OPT_EXTRA:-}"
  # Run dependencies load after the parse (opt_begin consumed --help), so
  # `sciebo download --help` parses none of them: the directory path reuses
  # hydrate's resolver and argv builder, progress_append_args/rclone_cmd
  # live in rclone.sh, and the DAV file path uses http/nc_api.
  opt_json_mode
  DOWNLOAD_APPLY=true
  opt_into DOWNLOAD_APPLY dry_run false
  DOWNLOAD_QUIET=0
  opt_into DOWNLOAD_QUIET quiet 1
  force=0
  opt_into force force 1
  resume=0
  [[ -n "${OPT_resume:-}${OPT_continue:-}" ]] && resume=1
  load_settings
  require_remote
  download_classify_mode "$DOWNLOAD_SUB" "$DOWNLOAD_DEST_ARG"
  case "$DOWNLOAD_MODE" in
    file)
      if [[ -z "$DOWNLOAD_DEST_ARG" ]]; then
        dest="$(download_default_dest "$DOWNLOAD_SUB")"
      else
        dest="$DOWNLOAD_DEST_ARG"
      fi
      if [[ "$DOWNLOAD_IS_NEXTCLOUD" -eq 1 ]]; then
        download_dav_file "$DOWNLOAD_SUB" "$dest" "$force" "$resume"
      else
        download_rclone_file "$DOWNLOAD_SUB" "$dest" "$force"
      fi
      ;;
    dir)
      hydrate_resolve "$DOWNLOAD_SUB"
      if [[ -n "$DOWNLOAD_DEST_ARG" ]]; then
        dest=${ strip_trailing_slashes "$DOWNLOAD_DEST_ARG";}
      else
        dest=${ strip_trailing_slashes "$HYDRATE_DEST";}
      fi
      [[ -n "$dest" ]] || die "cannot resolve a destination for '${DOWNLOAD_SUB}'"
      download_dir "$DOWNLOAD_SUB" "$dest"
      ;;
  esac
  return 0
}
