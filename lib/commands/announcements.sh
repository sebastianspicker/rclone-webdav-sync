#!/bin/bash
# announcements.sh command module - list the Nextcloud announcements.
#
# Read-only: reads the announcementcenter OCS app through lib/http.sh and
# never dismisses anything yet. --no-dismiss is accepted for interface
# compatibility and currently ignored. An absent or disabled app is reported
# as unavailable with rc 0, not as a failure.

# OCS path of the announcementcenter listing (relative to HTTP_OCS_ROOT).
ANN_PATH='/apps/announcementcenter/api/v1/announcements'
# Announcements parsed from the response, one TAB-separated record per line:
# id, time (epoch), subject, message (HTML stripped), link. Sorted newest
# first before printing.
ANN_RECORDS=""
# 1 when the app answered with a usable listing.
ANN_AVAILABLE=0
# Raw XML of the last listing.
ANN_XML=""
ANN_RECORD_FIELDS=(id time subject message link)
ANN_DEFAULT_LIMIT=20
ANN_MAX_LIMIT=100

usage_announcements() {
  usage_emit <<'EOF'
Usage: sciebo announcements [options]

List the Nextcloud announcements of the configured server, newest first.
The announcements (announcementcenter) app must be installed and enabled;
when it is absent or disabled the command prints "announcements app not
available" and exits 0.

Options:
  --limit N     print at most N announcements (default 20, max 100)
  --no-dismiss  accepted for compatibility; announcements are not dismissed
                yet
  --json        print {"available":...,"announcements":[...]}
  -h, --help    show this help
EOF
}

# announcements_parse XML - one TAB-separated record per <element>:
# id, time, subject (HTML stripped), message (HTML stripped), link. Field
# alternatives accept both the plain and the namespaced tag spellings; a
# record without an id is skipped.
announcements_parse() {
  local xml="$1" line="" id="" time="" subject="" message="" link=""
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    record_split "$line" "${ANN_RECORD_FIELDS[@]}"
    [[ -n "$id" ]] || continue
    subject="$(strip_html "$subject")"
    message="$(strip_html "$message")"
    printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$time" "$subject" "$message" "$link"
  done < <(xml_records_top "$xml" element \
    'id|announcement_id|oc:id|nc:id' \
    'time|timestamp|oc:time|nc:time' \
    'subject|oc:subject|nc:subject' \
    'message|oc:message|nc:message' \
    'link|oc:link|nc:link')
}

# announcements_fetch - GET the listing. Sets ANN_AVAILABLE/ANN_XML; a
# missing (404/405), empty (204/304), or OCS-rejected app leaves
# ANN_AVAILABLE=0 without failing. Other HTTP errors die through the shared
# helper.
announcements_fetch() {
  ANN_AVAILABLE=0
  ANN_XML=""
  ocs_request_allow GET "$ANN_PATH"
  case "$HTTP_CODE" in
    404 | 405) return 0 ;;
    204 | 304)
      ANN_AVAILABLE=1
      return 0
      ;;
  esac
  if ! http_ok_code "$HTTP_CODE"; then
    http_die_http_error GET "${HTTP_OCS_ROOT}${ANN_PATH}"
  fi
  [[ "$OCS_STATUS" == "ok" ]] || return 0
  ANN_AVAILABLE=1
  ANN_XML="$HTTP_BODY"
  return 0
}

# announcements_load - parse the fetched XML and sort the records newest
# first by their epoch time field. A missing time sorts as 0 (last).
announcements_load() {
  local parsed=""
  ANN_RECORDS=""
  [[ "$ANN_AVAILABLE" -eq 1 ]] || return 0
  parsed="$(announcements_parse "$ANN_XML")"
  [[ -n "$parsed" ]] || return 0
  ANN_RECORDS="$(printf '%s\n' "$parsed" | LC_ALL=C sort -t$'\t' -k2,2nr)"
  return 0
}

# announcements_print_row LINE - print one announcement block (time + subject,
# then an indented message and link when present); non-zero when the record has
# no id.
announcements_print_row() {
  local id="" time="" subject="" message="" link=""
  local time_label="" subject_disp="" message_disp="" link_disp=""
  record_split "$1" "${ANN_RECORD_FIELDS[@]}"
  [[ -n "$id" ]] || return 1
  time_label=${ epoch_to_stamp_or_raw "$time";}
  subject_disp=${ printable "$subject";}
  printf '%s  %s\n' "$time_label" "$subject_disp"
  if [[ -n "$message" ]]; then
    message_disp=${ printable "$message";}
    printf '    %s\n' "$message_disp"
  fi
  if [[ -n "$link" ]]; then
    link_disp=${ printable "$link";}
    printf '    %s\n' "$link_disp"
  fi
  return 0
}

# announcements_print_text LIMIT - the plain report.
announcements_print_text() {
  local limit="$1"
  if [[ "$ANN_AVAILABLE" -eq 0 ]]; then
    printf 'announcements app not available\n'
    return 0
  fi
  output_rows "no announcements" announcements_print_row "$limit" "" <<<"$ANN_RECORDS"
}

# announcements_print_json LIMIT - the same listing as a JSON document.
announcements_print_json() {
  local limit="$1" line="" id="" time="" subject="" message="" link="" count=0
  output_json_begin
  if [[ "$ANN_AVAILABLE" -eq 1 ]]; then
    output_json_kv_raw available true
  else
    output_json_kv_raw available false
  fi
  output_json_array_begin announcements
  if [[ "$ANN_AVAILABLE" -eq 1 ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      [[ "$count" -lt "$limit" ]] || break
      record_split "$line" "${ANN_RECORD_FIELDS[@]}"
      [[ -n "$id" ]] || continue
      output_json_object_begin
      output_json_kv id "$id"
      if is_uint "$time"; then
        output_json_kv_raw time "$time"
      else
        output_json_kv time "$time"
      fi
      output_json_kv subject "$subject"
      output_json_kv message "$message"
      output_json_kv link "$link"
      output_json_object_end
      count=$((count + 1))
    done <<<"$ANN_RECORDS"
  fi
  output_json_array_end
  output_json_end
  return 0
}

cmd_announcements() {
  local limit="$ANN_DEFAULT_LIMIT"
  opt_begin "limit:s json:b no-dismiss:b" announcements "" "$@"
  opt_guard announcements
  # The OCS call goes through http.sh; load it after opt_guard's --help
  # exit so `sciebo announcements --help` parses none of it.
  sciebo_require_module http xml_get
  opt_json_mode
  if [[ -n "${OPT_limit_SET:-}" ]]; then
    opt_require_uint announcements --limit "${OPT_limit:-}" 1
    limit=$((10#${OPT_limit}))
    [[ "$limit" -le "$ANN_MAX_LIMIT" ]] || limit="$ANN_MAX_LIMIT"
  fi
  http_load_context
  announcements_fetch
  announcements_load
  if output_json_enabled; then
    announcements_print_json "$limit"
  else
    announcements_print_text "$limit"
  fi
  return 0
}
