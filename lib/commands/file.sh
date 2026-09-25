#!/bin/bash
# file.sh command module - details, activity, and shares for one remote path.
#
# `info` and `activity` resolve SUB below <RCLONE_REMOTE>:<REMOTE_BASE>/ and
# talk to the Nextcloud DAV/OCS endpoints through lib/adapters/nc_api.sh (no jq, no
# direct curl). `shares` is a thin spawn of `share list SUB` because commands
# never call each other in-process. Read-only: no lock and no local state.
# Module-private globals use the FILE_ prefix.

FILE_SUB=""
FILE_ARG=""
FILE_EXTRA=""
FILE_ARGC=0

usage_file() {
  usage_emit <<'EOF'
Usage: sciebo file <subcommand> [options]

Show details for a remote path below <RCLONE_REMOTE>:<REMOTE_BASE>/.

Subcommands:
  info SUB [--json]              show WebDAV metadata for SUB
  activity SUB [--limit N] [--json]
                                 show the activity stream of SUB
  shares SUB [--json]            list the shares of SUB (`share list SUB`)

Options:
  --json      print info/activity/shares as JSON
  --limit N   activity: print at most N entries (default FILE_ACTIVITY_LIMIT)
  -h, --help  show this help
EOF
}

# file_split_args ARGS - fill FILE_SUB/FILE_ARG/FILE_EXTRA from the
# newline-separated positional arguments; FILE_ARGC counts them all. Thin
# wrapper over the shared split_command_args so `file` and `share` parse
# positionals identically.
file_split_args() { split_command_args "$1" FILE_SUB FILE_ARG FILE_EXTRA FILE_ARGC; }

# file_owner_value - the owner display value: the d:href inside d:owner-id
# when the server wraps it, else the plain value.
file_owner_value() {
  local raw="${NC_FILE_OWNER:-}" href=""
  [[ -n "$raw" ]] || return 0
  href="$(xml_get "$raw" 'd:href')"
  if [[ -n "$href" ]]; then
    printf '%s' "$href"
  else
    printf '%s' "$raw"
  fi
}

# file_checksums_value - the first oc:checksum inside oc:checksums, else the
# raw property value.
file_checksums_value() {
  local raw="${NC_FILE_CHECKSUMS:-}" value=""
  [[ -n "$raw" ]] || return 0
  value="$(xml_get "$raw" 'oc:checksum')"
  if [[ -n "$value" ]]; then
    printf '%s' "$value"
  else
    printf '%s' "$raw"
  fi
}

# file_lock_value - the d:href inside d:locktoken, else the raw property.
file_lock_value() {
  local raw="${NC_FILE_LOCK:-}" href=""
  [[ -n "$raw" ]] || return 0
  href="$(xml_get "$raw" 'd:href')"
  if [[ -n "$href" ]]; then
    printf '%s' "$href"
  else
    printf '%s' "$raw"
  fi
}

# file_favorite_value - "yes"/"no" for the numeric oc:favorite flag; other
# values pass through unchanged.
file_favorite_value() {
  case "${NC_FILE_FAVORITE:-}" in
    1) printf 'yes' ;;
    0) printf 'no' ;;
    *) printf '%s' "${NC_FILE_FAVORITE:-}" ;;
  esac
}

# file_print_info_text SUB - the labeled `file info` report.
file_print_info_text() {
  local sub="$1" value=""
  value=${ printable "$sub";}
  print_field "PATH" "$value"
  value=${ printable "${NC_FILE_TYPE:-}";}
  print_field "TYPE" "$value"
  value=${ format_size_bytes "${NC_FILE_SIZE:-}";}
  value=${ printable "$value";}
  print_field "SIZE" "$value"
  value=${ printable "${NC_FILE_MTIME:-}";}
  print_field "MODIFIED" "$value"
  value=${ printable "${NC_FILE_ETAG:-}";}
  print_field "ETAG" "$value"
  value=${ printable "${NC_FILE_ID:-}";}
  print_field "ID" "$value"
  value="$(file_owner_value)"
  value=${ printable "$value";}
  print_field "OWNER" "$value"
  value=${ printable "${NC_FILE_PERMISSIONS:-}";}
  print_field "PERMISSIONS" "$value"
  value="$(file_favorite_value)"
  value=${ printable "$value";}
  print_field "FAVORITE" "$value"
  value="$(file_checksums_value)"
  value=${ printable "$value";}
  print_field "CHECKSUMS" "$value"
  value="$(file_lock_value)"
  value=${ printable "$value";}
  print_field "LOCK" "$value"
}

# file_print_info_json SUB - the `file info --json` document. size is a JSON
# number and favorite a JSON boolean when known; unknown values are null.
file_print_info_json() {
  local sub="$1" size="${NC_FILE_SIZE:-}" favorite="${NC_FILE_FAVORITE:-}"
  output_json_begin
  output_json_kv "path" "$sub"
  output_json_kv "type" "${NC_FILE_TYPE:-}"
  case "$size" in
    '' | *[!0-9]*) output_json_kv_raw "size" "null" ;;
    *) output_json_kv_raw "size" "$size" ;;
  esac
  output_json_kv "modified" "${NC_FILE_MTIME:-}"
  output_json_kv "etag" "${NC_FILE_ETAG:-}"
  output_json_kv "id" "${NC_FILE_ID:-}"
  output_json_kv "owner" "$(file_owner_value)"
  output_json_kv "permissions" "${NC_FILE_PERMISSIONS:-}"
  case "$favorite" in
    1) output_json_kv_raw "favorite" "true" ;;
    0) output_json_kv_raw "favorite" "false" ;;
    *) output_json_kv_raw "favorite" "null" ;;
  esac
  output_json_kv "checksums" "$(file_checksums_value)"
  output_json_kv "lock" "$(file_lock_value)"
  output_json_end
}

# file_parse_activity XML - print one TAB-separated record per <element>:
# datetime, app, subject, link. A single awk pass extracts every field; the
# caller strips HTML from the subject.
file_parse_activity() {
  xml_records "$1" element datetime app subject link
}

# file_print_activity_text XML LIMIT - print "DATETIME<TAB>APP<TAB>SUBJECT<TAB>LINK"
# rows for the first LIMIT <element> records; HTML in the subject is stripped.
# LIMIT caps locally because the server may ignore the requested limit.
file_print_activity_text() {
  local xml="$1" limit="$2" line="" count=0
  local datetime="" app="" subject="" link=""
  while IFS= read -r line; do
    [[ "$count" -lt "$limit" ]] || break
    record_split "$line" FILE_ACTIVITY_DATETIME FILE_ACTIVITY_APP \
      FILE_ACTIVITY_SUBJECT FILE_ACTIVITY_LINK
    FILE_ACTIVITY_SUBJECT="$(strip_html "$FILE_ACTIVITY_SUBJECT")"
    [[ -n "$FILE_ACTIVITY_DATETIME$FILE_ACTIVITY_APP$FILE_ACTIVITY_SUBJECT$FILE_ACTIVITY_LINK" ]] || continue
    datetime=${ printable "$FILE_ACTIVITY_DATETIME";}
    app=${ printable "$FILE_ACTIVITY_APP";}
    subject=${ printable "$FILE_ACTIVITY_SUBJECT";}
    link=${ printable "$FILE_ACTIVITY_LINK";}
    printf '%s\t%s\t%s\t%s\n' "$datetime" "$app" "$subject" "$link"
    count=$((count + 1))
  done < <(file_parse_activity "$xml")
  [[ "$count" -gt 0 ]] || printf 'no activity\n'
}

# file_print_activity_json XML LIMIT - the `file activity --json` document.
file_print_activity_json() {
  local xml="$1" limit="$2" line="" count=0
  output_json_begin
  output_json_array_begin "activity"
  while IFS= read -r line; do
    [[ "$count" -lt "$limit" ]] || break
    record_split "$line" FILE_ACTIVITY_DATETIME FILE_ACTIVITY_APP \
      FILE_ACTIVITY_SUBJECT FILE_ACTIVITY_LINK
    FILE_ACTIVITY_SUBJECT="$(strip_html "$FILE_ACTIVITY_SUBJECT")"
    [[ -n "$FILE_ACTIVITY_DATETIME$FILE_ACTIVITY_APP$FILE_ACTIVITY_SUBJECT$FILE_ACTIVITY_LINK" ]] || continue
    output_json_object_begin
    output_json_kv "datetime" "$FILE_ACTIVITY_DATETIME"
    output_json_kv "app" "$FILE_ACTIVITY_APP"
    output_json_kv "subject" "$FILE_ACTIVITY_SUBJECT"
    output_json_kv "link" "$FILE_ACTIVITY_LINK"
    output_json_object_end
    count=$((count + 1))
  done < <(file_parse_activity "$xml")
  output_json_array_end
  output_json_end
}

# file_require_sub SUB - usage_error unless exactly one SUB positional follows
# the subcommand (rejecting extras first), with the per-sub message. Kept
# hand-rolled: the too-few message is per-subcommand and not the shared
# "<LABEL> is required" shape, and the too-many message interpolates the
# offending word ("unexpected argument: <arg>"), which opt_require_sub does
# not support.
file_require_sub() {
  local sub="$1"
  [[ "$FILE_ARGC" -le 2 ]] ||
    usage_error file "unexpected argument: ${ printable "$FILE_EXTRA";}"
  [[ "$FILE_ARGC" -eq 2 ]] ||
    usage_error file "${sub} requires a remote path argument (SUB)"
}

# file_reject_option SUB NAME - usage_error when --NAME was given for SUB; the
# wrapper keeps file's call sites named while opt_reject owns the check.
file_reject_option() {
  opt_reject file "$1" "$2"
}

# file_print_mode TEXT_FN JSON_FN ARGS... - print through the text or JSON
# printer matching the current --json flag.
file_print_mode() {
  local text_fn="$1" json_fn="$2"
  shift 2
  if output_json_enabled; then
    "$json_fn" "$@"
  else
    "$text_fn" "$@"
  fi
}

cmd_file() {
  local sub="" limit="" fileid="" rc=0
  opt_begin "json:b limit:s" file "" "$@"
  # Run dependencies load after opt_begin's --help exit, so
  # `sciebo file --help` parses none of them: the DAV/OCS lookups use
  # http/nc_api; the argument split is core's split_command_args.
  file_split_args "${OPT_EXTRA:-}"
  sub="$FILE_SUB"
  case "$sub" in
    info | activity | shares) ;;
    '')
      usage_error file "a subcommand is required (info, activity, shares)"
      ;;
    *)
      usage_unknown_sub file "$sub"
      ;;
  esac

  case "$sub" in
    info)
      file_require_sub info
      file_reject_option info limit
      require_safe_remote_path "$FILE_ARG"
      http_load_context
      nc_file_info "$FILE_ARG"
      opt_json_mode
      file_print_mode file_print_info_text file_print_info_json "$FILE_ARG"
      ;;
    activity)
      file_require_sub activity
      require_safe_remote_path "$FILE_ARG"
      http_load_context
      # The default activity limit from settings, 50 when the setting is
      # empty or not numeric.
      limit=${ default_uint "${FILE_ACTIVITY_LIMIT:-}" 50;}
      if [[ -n "${OPT_limit_SET:-}" ]]; then
        opt_require_uint file --limit "${OPT_limit:-}" 1
        limit=$((10#${OPT_limit}))
      fi
      fileid="$(nc_fileid "$FILE_ARG")"
      nc_activity_for_file "$fileid" "$limit"
      opt_json_mode
      file_print_mode file_print_activity_text file_print_activity_json "$HTTP_BODY" "$limit"
      ;;
    shares)
      file_require_sub shares
      file_reject_option shares limit
      require_safe_remote_path "$FILE_ARG"
      if [[ -n "${OPT_json_SET:-}" ]]; then
        "${PROJECT_DIR}/bin/sciebo" share list --json -- "$FILE_ARG" || rc=$?
      else
        "${PROJECT_DIR}/bin/sciebo" share list -- "$FILE_ARG" || rc=$?
      fi
      return "$rc"
      ;;
  esac
  return 0
}
