#!/bin/bash
# recent.sh command module - recently modified remote files.
#
# Read-only and stateless: `rclone lsl` lists the remote recursively with
# sizes and times, and the listing is parsed and sorted locally. `lsl` is
# preferred over `lsjson` because one line maps to one file with no JSON
# parser needed in awk (and unlike `lsjson`, `lsl` recurses by default and
# has no --recursive flag). No lock is taken.

usage_recent() {
  usage_emit <<'EOF'
Usage: sciebo recent [--since DUR] [--limit N] [--json]

List recently modified files below <RCLONE_REMOTE>:<REMOTE_BASE>/ through
rclone, newest first, as MODIFIED<TAB>SIZE<TAB>PATH.

Options:
  --since DURATION  only files modified within DURATION (e.g. 90m, 24h,
                    7d; a bare number means minutes)
  --limit N         print at most N files (default RECENT_LIMIT)
  --json            print the files as JSON
  -h, --help        show this help
EOF
}

# recent_parse LISTING - print "MODIFIED<TAB>SIZE<TAB>PATH" for every valid
# `rclone lsl` line ("SIZE YYYY-MM-DD HH:MM:SS[.NNN] PATH"). Malformed
# lines (headers, warnings) are dropped.
recent_parse() {
  printf '%s\n' "$1" | awk '
    {
      if ($0 !~ /^[[:space:]]*[0-9]+[[:space:]]+[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][[:space:]]+[0-9][0-9]:[0-9][0-9]:[0-9][0-9]([.][0-9]+)?[[:space:]]+[^[:space:]]/) next
      size = $1
      mod = $2 " " $3
      path = $0
      sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", path)
      sub(/^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][[:space:]]+/, "", path)
      sub(/^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]([.][0-9]+)?[[:space:]]+/, "", path)
      printf "%s\t%s\t%s\n", mod, size, path
    }
  '
}

# recent_sorted PARSED LIMIT - newest first, capped at LIMIT rows.
recent_sorted() {
  printf '%s\n' "$1" | sort -r | head -n "$2"
}

# recent_print_text PARSED LIMIT - the MODIFIED/SIZE/PATH table.
recent_print_text() {
  local parsed="$1" limit="$2" line="" mod="" rest="" size="" path="" path_disp=""
  local -a lines=()
  mapfile -t lines < <(recent_sorted "$parsed" "$limit")
  for line in "${lines[@]}"; do
    [[ -n "$line" ]] || continue
    mod="${line%%$'\t'*}"
    rest="${line#*$'\t'}"
    size="${rest%%$'\t'*}"
    path="${rest#*$'\t'}"
    path_disp=${ printable "$path";}
    printf '%s\t%s\t%s\n' "$mod" "$size" "$path_disp"
  done
}

# recent_print_json PARSED LIMIT - the `--json` document.
recent_print_json() {
  local parsed="$1" limit="$2" line="" mod="" rest="" size="" path=""
  local -a lines=()
  output_json_list_begin "files"
  mapfile -t lines < <(recent_sorted "$parsed" "$limit")
  for line in "${lines[@]}"; do
    [[ -n "$line" ]] || continue
    mod="${line%%$'\t'*}"
    rest="${line#*$'\t'}"
    size="${rest%%$'\t'*}"
    path="${rest#*$'\t'}"
    output_json_object_begin
    output_json_kv "modified" "$mod"
    output_json_kv_raw "size" "$size"
    output_json_kv "path" "$path"
    output_json_object_end
  done
  output_json_list_end
}

cmd_recent() {
  local since="" seconds="" limit="" rc=0
  local listing="" parsed=""
  local -a args=()
  opt_begin "since:s limit:s json:b" recent "" "$@"
  opt_guard recent
  if [[ -n "${OPT_since_SET:-}" ]]; then
    since="${OPT_since:-}"
    seconds=${ duration_parse_or_usage recent --since "$since" requires;}
  fi
  load_settings
  # The default limit from settings, 50 when the setting is empty or not
  # numeric.
  limit=${ default_uint "${RECENT_LIMIT:-}" 50;}
  if [[ -n "${OPT_limit_SET:-}" ]]; then
    opt_require_uint recent --limit "${OPT_limit:-}" 1
    limit=$((10#${OPT_limit}))
  fi
  opt_json_mode

  args=(lsl "${REMOTE_PREFIX}/")
  [[ -z "$seconds" ]] || args+=(--max-age "${seconds}s")
  rclone_capture recent "${args[@]}" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    [[ -s "$RCLONE_CAPTURE_ERR" ]] && sanitize_stream <"$RCLONE_CAPTURE_ERR" >&2
    temp_discard "$RCLONE_CAPTURE_OUT"
    temp_discard "$RCLONE_CAPTURE_ERR"
    die "rclone lsl '${REMOTE_PREFIX}/' failed (rc ${rc})"
  fi
  listing="$(<"$RCLONE_CAPTURE_OUT")"
  temp_discard "$RCLONE_CAPTURE_OUT"
  temp_discard "$RCLONE_CAPTURE_ERR"
  parsed="$(recent_parse "$listing")"

  if output_json_enabled; then
    recent_print_json "$parsed" "$limit"
    return 0
  fi
  if [[ -z "$parsed" ]]; then
    printf 'no recent files\n'
    return 0
  fi
  recent_print_text "$parsed" "$limit"
  return 0
}
