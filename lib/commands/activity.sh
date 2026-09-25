#!/bin/bash
# activity.sh command module - show the Nextcloud activity stream.
# Talks to the activity OCS API through lib/adapters/http.sh. --notify sends
# best-effort desktop notifications and remembers the ids in ACTIVITY_SEEN;
# it never changes the command's exit status. --since walks the API's
# activity-id cursor (since=) backwards until entries older than the cutoff
# are reached, so a duration window is not silently truncated at one page.

ACTIVITY_RECORD_ID=""
ACTIVITY_RECORD_APP=""
ACTIVITY_RECORD_DATETIME=""
ACTIVITY_RECORD_SUBJECT=""
ACTIVITY_RECORD_LINK=""
ACTIVITY_RECORD_FIELDS=(
  ACTIVITY_RECORD_ID ACTIVITY_RECORD_APP - ACTIVITY_RECORD_DATETIME
  ACTIVITY_RECORD_SUBJECT - ACTIVITY_RECORD_LINK
)
# Records collected by the fetchers: one TAB-separated activity per line.
ACTIVITY_RECORDS=""
# Raw XML of the last page (filled by activity_fetch_page).
ACTIVITY_PAGE_XML=""
# Ids already collected, keyed for O(1) cross-page membership checks; a page
# boundary may repeat the cursor id.
declare -gA ACTIVITY_FETCHED_IDS=()
# Datetime -> epoch cache so each distinct timestamp is parsed once; an unset
# key means "not parsed yet", a set-but-empty value means "unparsable".
declare -gA ACTIVITY_EPOCH_CACHE=()
# Records appended by the last activity_records_append call.
ACTIVITY_PAGE_NEW=0
# Records counted by the last activity_record_count call.
ACTIVITY_PAGE_COUNT=0
# Optional --since cutoff (epoch) applied by activity_print_row/rows.
ACTIVITY_PRINT_CUTOFF=""
# Pagination bounds for --since: 50 per page, at most 10 pages.
ACTIVITY_PAGE_SIZE=50
ACTIVITY_MAX_PAGES=10

usage_activity() {
  usage_emit <<'EOF'
Usage: sciebo activity [options]

Show the Nextcloud activity stream of the configured remote, newest first.

Options:
  --limit N         print and notify at most N activities (default 20,
                    max 100)
  --since DURATION  only activities newer than DURATION (e.g. 90m, 24h, 7d);
                    pages through the API's since= cursor until the window is
                    covered (at most 10 pages of 50, with a warning when the
                    cap is hit)
  --notify          send a desktop notification for each not-yet-seen
                    activity (bounded by --limit)
  --quiet           print no activity rows
  -h, --help        show this help
EOF
}

# activity_api_path LIMIT [SINCE] - OCS path of the activity stream, newest
# first, optionally continuing below the given activity id for pagination.
activity_api_path() {
  local path="/apps/activity/api/v2/activity?limit=$1&sort=desc"
  [[ -z "${2:-}" ]] || path="${path}&since=$2"
  printf '%s' "$path"
}

# activity_parse_xml XML - print one TAB-separated record per activity:
# activity_id, app, type, datetime, subject (HTML stripped), message, link,
# actor. Records are sliced at <activity_id> instead of split at <element>
# so nested rich-subject elements cannot truncate a record. One awk pass over
# the shared XML prelude extracts every field and strips the markup with the
# shared xml_html_strip (_AWK_HTML_LIB composed into _AWK_XML_LIB),
# replacing a fork per field.
activity_parse_xml() {
  printf '%s' "$1" | LC_ALL=C awk "${_AWK_XML_LIB}"'
    { doc = doc $0 }
    END {
      gsub(/\r/, "", doc)
      marker = "<activity_id"
      mlen = length(marker)
      pos = index(doc, marker)
      while (pos > 0) {
        rest = substr(doc, pos + mlen)
        rel = index(rest, marker)
        if (rel == 0) {
          block = substr(doc, pos)
          pos = 0
        } else {
          block = substr(doc, pos, mlen + rel - 1)
          pos = pos + mlen + rel - 1
        }
        id = xml_extract(block, "activity_id")
        if (id == "") continue
        actor = xml_extract(block, "actor")
        if (actor == "") actor = xml_extract(block, "user")
        subject = xml_strip_ctrl(xml_html_strip(xml_extract(block, "subject")))
        message = xml_strip_ctrl(xml_html_strip(xml_extract(block, "message")))
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", id,
          xml_extract(block, "app"), xml_extract(block, "type"),
          xml_extract(block, "datetime"), subject, message,
          xml_extract(block, "link"), actor
      }
    }
  '
}

# activity_epoch DATETIME - print an ISO 8601 timestamp as an epoch, or
# nothing when it cannot be parsed. macOS date first (its %z wants +0000, so
# the offset is normalized), then GNU date. Callers keep unparsable rows.
activity_epoch() {
  local value="$1" normalized="" out="" cached=""
  [[ -n "$value" ]] || return 1
  if [[ -v "ACTIVITY_EPOCH_CACHE[$value]" ]]; then
    cached="${ACTIVITY_EPOCH_CACHE[$value]}"
    [[ -n "$cached" ]] || return 1
    printf '%s' "$cached"
    return 0
  fi
  normalized="$(printf '%s' "$value" |
    sed 's/\.[0-9][0-9]*//; s/\([+-][0-9][0-9]\):\([0-9][0-9]\)$/\1\2/; s/Z$/+0000/')"
  out="$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$normalized" '+%s' 2>/dev/null)" || out=""
  if [[ -z "$out" ]]; then
    out="$(date -d "$value" '+%s' 2>/dev/null)" || out=""
  fi
  ACTIVITY_EPOCH_CACHE[$value]="$out"
  [[ -n "$out" ]] || return 1
  printf '%s' "$out"
  return 0
}

# activity_recent DATETIME CUTOFF - true when DATETIME is at or after
# CUTOFF, or when it cannot be parsed (unparsable rows are kept).
activity_recent() {
  local value="$1" cutoff="$2" epoch=""
  epoch=${ activity_epoch "$value";} || epoch=""
  [[ -n "$epoch" ]] || return 0
  [[ "$epoch" -ge "$cutoff" ]]
}

# activity_fetch_page LIMIT SINCE - GET one page into ACTIVITY_PAGE_XML
# (empty on 204/304).
activity_fetch_page() {
  local limit="$1" since="${2:-}" path=""
  path=${ activity_api_path "$limit" "$since";}
  ocs_request_allow GET "$path"
  ocs_check_response GET "${HTTP_OCS_ROOT}${path}"
  case "$HTTP_CODE" in
    204 | 304) ACTIVITY_PAGE_XML="" ;;
    *) ACTIVITY_PAGE_XML="$HTTP_BODY" ;;
  esac
  return 0
}

# activity_record_count RECORDS - set ACTIVITY_PAGE_COUNT to the number of
# non-empty records in RECORDS. The pagination loop counts the page on every
# iteration, so this stays pure bash instead of forking awk.
activity_record_count() {
  local line="" n=0
  while IFS= read -r line; do
    [[ "$line" == *[![:space:]]* ]] || continue
    n=$((n + 1))
  done <<<"$1"
  ACTIVITY_PAGE_COUNT=$n
  return 0
}

# activity_page_min_id RECORDS - print the smallest numeric activity_id in
# the page (the next since= cursor), or nothing when there is none.
activity_page_min_id() {
  local line="" id="" min=""
  while IFS= read -r line; do
    id="${line%%$'\t'*}"
    case "$id" in
      '' | *[!0-9]*) continue ;;
    esac
    if [[ -z "$min" || "$id" -lt "$min" ]]; then
      min="$id"
    fi
  done <<<"$1"
  [[ -z "$min" ]] || printf '%s' "$min"
  return 0
}

# activity_page_crossed RECORDS CUTOFF - true when the page contains an
# entry older than CUTOFF, i.e. a descending walk is done.
activity_page_crossed() {
  local line="" epoch=""
  while IFS= read -r line; do
    record_split "$line" "${ACTIVITY_RECORD_FIELDS[@]}"
    [[ -n "$ACTIVITY_RECORD_ID" ]] || continue
    epoch=${ activity_epoch "$ACTIVITY_RECORD_DATETIME";} || epoch=""
    [[ -n "$epoch" ]] || continue
    [[ "$epoch" -ge "$2" ]] || return 0
  done <<<"$1"
  return 1
}

# activity_records_append RECORDS - append the records that are not already
# collected to ACTIVITY_RECORDS; the number of new records lands in
# ACTIVITY_PAGE_NEW.
activity_records_append() {
  local line="" id=""
  local -a lines=()
  ACTIVITY_PAGE_NEW=0
  mapfile -t lines <<<"$1"
  for line in "${lines[@]}"; do
    [[ -n "$line" ]] || continue
    id="${line%%$'\t'*}"
    [[ -n "$id" ]] || continue
    if [[ -v "ACTIVITY_FETCHED_IDS[$id]" ]]; then continue; fi
    ACTIVITY_RECORDS="${ACTIVITY_RECORDS}${line}"$'\n'
    ACTIVITY_FETCHED_IDS[$id]=1
    ACTIVITY_PAGE_NEW=$((ACTIVITY_PAGE_NEW + 1))
  done
  return 0
}

# activity_fetch_default LIMIT - fetch one newest-first page into
# ACTIVITY_RECORDS (the no---since listing path).
activity_fetch_default() {
  ACTIVITY_RECORDS=""
  ACTIVITY_FETCHED_IDS=()
  activity_fetch_page "$1" ""
  [[ -z "$ACTIVITY_PAGE_XML" ]] ||
    activity_records_append "$(activity_parse_xml "$ACTIVITY_PAGE_XML")"
  return 0
}

# activity_fetch_since CUTOFF - page backwards with the API's since= cursor
# until a page crosses CUTOFF, the stream ends, or the page cap is hit (then
# warn, since older entries were not fetched). Local activity_recent
# filtering remains the fallback.
activity_fetch_since() {
  local cutoff="$1" since="" next="" page=0 completed=0 records="" count=0 min_id=""
  ACTIVITY_RECORDS=""
  ACTIVITY_FETCHED_IDS=()
  while [[ "$page" -lt "$ACTIVITY_MAX_PAGES" ]]; do
    activity_fetch_page "$ACTIVITY_PAGE_SIZE" "$since"
    page=$((page + 1))
    if [[ -z "$ACTIVITY_PAGE_XML" ]]; then
      completed=1
      break
    fi
    records="$(activity_parse_xml "$ACTIVITY_PAGE_XML")"
    activity_record_count "$records"
    count="$ACTIVITY_PAGE_COUNT"
    if [[ "$count" -eq 0 ]]; then
      completed=1
      break
    fi
    activity_records_append "$records"
    if [[ "$ACTIVITY_PAGE_NEW" -eq 0 ]]; then
      completed=1
      break
    fi
    if [[ "$count" -lt "$ACTIVITY_PAGE_SIZE" ]]; then
      completed=1
      break
    fi
    if activity_page_crossed "$records" "$cutoff"; then
      completed=1
      break
    fi
    min_id=${ activity_page_min_id "$records";}
    if [[ -z "$min_id" ]]; then
      completed=1
      break
    fi
    next="$min_id"
    if [[ "$next" == "$since" ]]; then
      completed=1
      break
    fi
    since="$next"
  done
  if [[ "$completed" -eq 0 ]]; then
    warn "activity: --since stopped after ${ACTIVITY_MAX_PAGES} pages of ${ACTIVITY_PAGE_SIZE}; entries older than the window were not fetched"
  fi
  return 0
}

# activity_print_row LINE - print one activity row; non-zero when the record
# is empty or older than ACTIVITY_PRINT_CUTOFF.
activity_print_row() {
  local dt_disp="" app_disp="" link_disp=""
  record_split "$1" "${ACTIVITY_RECORD_FIELDS[@]}"
  [[ -n "$ACTIVITY_RECORD_ID" ]] || return 1
  [[ -z "${ACTIVITY_PRINT_CUTOFF:-}" ]] ||
    activity_recent "$ACTIVITY_RECORD_DATETIME" "$ACTIVITY_PRINT_CUTOFF" || return 1
  dt_disp=${ printable "$ACTIVITY_RECORD_DATETIME";}
  app_disp=${ printable "$ACTIVITY_RECORD_APP";}
  [[ -z "$ACTIVITY_RECORD_LINK" ]] || link_disp=${ printable "$ACTIVITY_RECORD_LINK";}
  printf '%-24s %-12s %s%s\n' "$dt_disp" "$app_disp" "$ACTIVITY_RECORD_SUBJECT" \
    "${link_disp:+ ${link_disp}}"
  return 0
}

# activity_print_rows [CUTOFF] - print the collected stream (datetime, app,
# subject, link), honoring --limit and the optional --since cutoff. Prints a
# hint when the stream is empty; --quiet suppresses all of it.
activity_print_rows() {
  local cutoff="${1:-}" limit=20
  [[ -n "${OPT_limit_SET:-}" ]] && limit="${OPT_limit:-0}"
  [[ "${OPT_quiet:-0}" != "1" ]] || return 0
  ACTIVITY_PRINT_CUTOFF="$cutoff"
  output_rows "no activities" activity_print_row "$limit" "" <<<"$ACTIVITY_RECORDS"
  return 0
}

# activity_notify [CUTOFF] - notify the unseen activities in the collected
# (optionally --since filtered) stream and record the ids in ACTIVITY_SEEN.
# --limit (default 20) caps how many notifications are sent. Sending is
# best-effort: a failed send is ignored.
activity_notify() {
  local cutoff="${1:-}" limit=20 line="" new_ids="" sent=0 app_disp=""
  local -a lines=()
  [[ -n "${OPT_limit_SET:-}" ]] && limit="${OPT_limit:-0}"
  mapfile -t lines <<<"$ACTIVITY_RECORDS"
  for line in "${lines[@]}"; do
    record_split "$line" "${ACTIVITY_RECORD_FIELDS[@]}"
    [[ -n "$ACTIVITY_RECORD_ID" ]] || continue
    [[ -z "$cutoff" ]] || activity_recent "$ACTIVITY_RECORD_DATETIME" "$cutoff" || continue
    seen_contains "$ACTIVITY_SEEN" "$ACTIVITY_RECORD_ID" && continue
    [[ "$sent" -lt "$limit" ]] || break
    app_disp=${ printable "$ACTIVITY_RECORD_APP";}
    notify_send "Nextcloud activity" "${app_disp}: ${ACTIVITY_RECORD_SUBJECT}"
    new_ids="${new_ids}${ACTIVITY_RECORD_ID}"$'\n'
    sent=$((sent + 1))
  done
  [[ -z "$new_ids" ]] || printf '%s' "$new_ids" | seen_record "$ACTIVITY_SEEN"
  return 0
}

cmd_activity() {
  local limit=20 fetch_limit=20 since_seconds="" cutoff=""
  opt_begin "limit:s since:s notify:b quiet:b" activity "" "$@"
  opt_guard activity
  # Run dependencies load after opt_guard's --help exit, so
  # `sciebo activity --help` parses none of them: the OCS calls go through
  # http.sh; --limit and --since validate through the eagerly loaded core/
  # duration helpers.
  if [[ -n "${OPT_limit_SET:-}" ]]; then
    opt_require_uint activity --limit "${OPT_limit:-}" 1
    limit=$((10#${OPT_limit}))
    [[ "$limit" -le 100 ]] || limit=100
  fi
  fetch_limit="$limit"
  if [[ -n "${OPT_since_SET:-}" ]]; then
    since_seconds=${ duration_parse_or_usage activity --since "${OPT_since:-}" requires;}
    cutoff="$(($(now_epoch) - since_seconds))"
  fi
  http_load_context

  if [[ -n "$cutoff" ]]; then
    activity_fetch_since "$cutoff"
  else
    activity_fetch_default "$fetch_limit"
  fi

  activity_print_rows "$cutoff"
  if [[ "${OPT_notify:-0}" == "1" ]]; then
    activity_notify "$cutoff"
  fi
  return 0
}
