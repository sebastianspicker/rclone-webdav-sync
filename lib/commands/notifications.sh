#!/bin/bash
# notifications.sh command module - list, filter, act on, watch, and delete
# Nextcloud notifications. Talks to the notifications OCS API through
# lib/http.sh. --notify sends best-effort desktop notifications and remembers
# the ids in NOTIFICATIONS_SEEN; it never changes the command's exit status.
# --watch polls in the foreground and records every notification it reports.

NOTIFICATIONS_RECORD_ID=""
NOTIFICATIONS_RECORD_APP=""
NOTIFICATIONS_RECORD_TYPE=""
NOTIFICATIONS_RECORD_DATETIME=""
NOTIFICATIONS_RECORD_SUBJECT=""
NOTIFICATIONS_RECORD_MESSAGE=""
NOTIFICATIONS_RECORD_LINK=""
# Raw XML of the last collection fetch (filled by notifications_fetch).
NOTIFICATIONS_XML=""
# --limit resolved by notifications_resolve_limit: the cap and whether it
# applies (0 when the option was absent).
NOTIFICATIONS_LIMIT=0
NOTIFICATIONS_USE_LIMIT=0
# Row-walk counters and accumulation globals shared by the loop callbacks.
NOTIFICATIONS_PRINTED=0
NOTIFICATIONS_TOTAL=0
NOTIFICATIONS_SENT_COUNT=0
NOTIFICATIONS_NEW_IDS=""
NOTIFICATIONS_SKIP_ID=""

usage_notifications() {
  usage_emit <<'EOF'
Usage: sciebo notifications [options]

List the Nextcloud notifications of the configured remote, newest first.
--app/--type are allowlists matched case-sensitively and exactly; multiple
values are comma/space/colon separated. When the options are absent the
NOTIFY_APPS/NOTIFY_TYPES settings apply as defaults (empty = all).

Options:
  --limit N     print and notify at most N notifications after filtering
  --app LIST    only notifications from these apps
  --type LIST   only notifications with these object types
  --unseen      only notifications not yet recorded in the seen cache;
                listing with --unseen does not write the cache
  --action ID LABEL
                run the action labelled LABEL (case-insensitive) on
                notification ID; POST/DELETE/PUT from the action
  --delete ID   delete one notification
  --delete-all  delete every notification (asks first; needs --yes when not
                running interactively)
  --notify      send a notification for each not-yet-seen notification and
                remember its id in the seen cache
  --json        print the filtered notifications as one JSON document
  --watch [N]   poll every N seconds (default NOTIFY_WATCH_INTERVAL), print
                and record new notifications until interrupted; cannot be
                combined with --delete/--delete-all/--action/--json
  --quiet       print no notification rows
  --yes         skip the --delete-all confirmation
  -h, --help    show this help
EOF
}

# notifications_api_path - OCS path of the notifications collection.
notifications_api_path() { printf '%s' '/apps/notifications/api/v2/notifications'; }

# notifications_parse_xml XML - print one TAB-separated record per <element>
# in the OCS <data> block: id, app, object_type, datetime, subject, message,
# link. API v2 renamed <id> to <notification_id>; both spellings are accepted.
# One depth-aware xml_records_top pass extracts every field (the shared awk
# XML prelude), replacing a fork per field.
notifications_parse_xml() {
  xml_records_top "$1" element \
    'id|notification_id' app object_type datetime subject message link
}

# notifications_subject SUBJECT MESSAGE - print the subject, falling back to
# the message when the subject is empty (scrubbed for display).
notifications_subject() {
  local subject="$1" message="$2"
  [[ -n "$subject" ]] || subject="$message"
  printable "$subject"
}

# notifications_confirm_delete_all - 0 when the deletion may proceed.
# --yes skips the prompt; a non-interactive run without it is a usage error.
# A "no" answer returns 1 so the caller can abort cleanly.
notifications_confirm_delete_all() {
  ui_confirm_mutation notifications \
    "--delete-all requires --yes when not running interactively" \
    "Delete all notifications? [y/N]: "
}

# notifications_allow_contains LIST VALUE - true when VALUE is listed exactly
# (case-sensitive). Lists use comma, space, or colon as separators; runs of
# separators collapse and empty entries never match. An empty VALUE never
# matches a non-empty allowlist.
notifications_allow_contains() {
  local list="$1" value="$2" item=""
  [[ -n "$value" ]] || return 1
  local IFS=', :'
  for item in $list; do
    [[ "$item" == "$value" ]] && return 0
  done
  return 1
}

# notifications_wanted VALUE OPT NAME - true when VALUE passes the allowlist of
# option OPT (when the option was set) or the setting NAME (empty means all).
notifications_wanted() {
  local value="$1" opt="$2" setting="$3" opt_set="" opt_val="" list=""
  opt_set="OPT_${opt}_SET"
  if [[ -n "${!opt_set:-}" ]]; then
    opt_val="OPT_${opt}"
    list="${!opt_val:-}"
  else
    list="${!setting:-}"
  fi
  [[ -n "$list" ]] || return 0
  notifications_allow_contains "$list" "$value"
}

# notifications_passes_filters - true when the record just split passes the
# app and object-type allowlists.
notifications_passes_filters() {
  notifications_wanted "$NOTIFICATIONS_RECORD_APP" app NOTIFY_APPS || return 1
  notifications_wanted "$NOTIFICATIONS_RECORD_TYPE" type NOTIFY_TYPES || return 1
  return 0
}

# notifications_passes_unseen - true when --unseen is absent or the record
# just split is not in the seen cache. Listing never writes the cache.
notifications_passes_unseen() {
  [[ "${OPT_unseen:-0}" == "1" ]] || return 0
  ! seen_contains "$NOTIFICATIONS_SEEN" "$NOTIFICATIONS_RECORD_ID"
}

# notifications_resolve_limit - read the --limit option into the
# NOTIFICATIONS_LIMIT/NOTIFICATIONS_USE_LIMIT globals (0/0 when it is absent).
notifications_resolve_limit() {
  NOTIFICATIONS_LIMIT=0
  NOTIFICATIONS_USE_LIMIT=0
  if [[ -n "${OPT_limit_SET:-}" ]]; then
    NOTIFICATIONS_LIMIT="${OPT_limit:-0}"
    NOTIFICATIONS_USE_LIMIT=1
  fi
}

# notifications_for_each_record XML FN - split every parsed record, skip the
# records without an id or failing the app/type filters, then call FN once per
# remaining record. FN runs in the current shell, so it reads the
# NOTIFICATIONS_RECORD_* globals of the current record; a non-zero status
# stops the walk. The split goes through record_split because TAB is IFS
# whitespace, so `read` would collapse empty fields.
notifications_for_each_record() {
  local xml="$1" fn="$2" line=""
  local -a lines=()
  mapfile -t lines < <(notifications_parse_xml "$xml")
  for line in "${lines[@]}"; do
    record_split "$line" NOTIFICATIONS_RECORD_ID NOTIFICATIONS_RECORD_APP \
      NOTIFICATIONS_RECORD_TYPE NOTIFICATIONS_RECORD_DATETIME \
      NOTIFICATIONS_RECORD_SUBJECT NOTIFICATIONS_RECORD_MESSAGE \
      NOTIFICATIONS_RECORD_LINK
    [[ -n "$NOTIFICATIONS_RECORD_ID" ]] || continue
    notifications_passes_filters || continue
    "$fn" "$line" || break
  done
  return 0
}

# notifications_print_record - print one table row from the record globals.
notifications_print_record() {
  local id="" app="" datetime="" subject="" link="" link_value=""
  id=${ printable "$NOTIFICATIONS_RECORD_ID";}
  app=${ printable "$NOTIFICATIONS_RECORD_APP";}
  datetime=${ printable "$NOTIFICATIONS_RECORD_DATETIME";}
  subject=${ notifications_subject "$NOTIFICATIONS_RECORD_SUBJECT" "$NOTIFICATIONS_RECORD_MESSAGE";}
  if [[ -n "$NOTIFICATIONS_RECORD_LINK" ]]; then
    link_value=${ printable "$NOTIFICATIONS_RECORD_LINK";}
    link=" ${link_value}"
  fi
  printf '%-8s %-12s %-20s %s%s\n' "$id" "$app" "$datetime" "$subject" "$link"
}

# notifications_list_row - print one table row after the --unseen check;
# stop the walk once --limit printed rows are reached.
notifications_list_row() {
  notifications_passes_unseen || return 0
  NOTIFICATIONS_TOTAL=$((NOTIFICATIONS_TOTAL + 1))
  [[ "$NOTIFICATIONS_USE_LIMIT" -eq 0 || "$NOTIFICATIONS_PRINTED" -lt "$NOTIFICATIONS_LIMIT" ]] || return 1
  notifications_print_record
  NOTIFICATIONS_PRINTED=$((NOTIFICATIONS_PRINTED + 1))
  return 0
}

# notifications_print_rows XML - print the notification table (subject
# falling back to the message, link when present). The app/type and --unseen
# filters run first, --limit caps the printed rows after them. Prints a hint
# when nothing passes the filters; --quiet suppresses all of it.
notifications_print_rows() {
  [[ "${OPT_quiet:-0}" != "1" ]] || return 0
  notifications_resolve_limit
  NOTIFICATIONS_TOTAL=0
  NOTIFICATIONS_PRINTED=0
  notifications_for_each_record "$1" notifications_list_row
  [[ "$NOTIFICATIONS_TOTAL" -gt 0 ]] || printf 'no notifications\n'
  return 0
}

# notifications_json_row - emit one notification object after the --unseen
# check; stop the walk once --limit objects are reached.
notifications_json_row() {
  local seen=false
  notifications_passes_unseen || return 0
  [[ "$NOTIFICATIONS_USE_LIMIT" -eq 0 || "$NOTIFICATIONS_PRINTED" -lt "$NOTIFICATIONS_LIMIT" ]] || return 1
  if seen_contains "$NOTIFICATIONS_SEEN" "$NOTIFICATIONS_RECORD_ID"; then
    seen=true
  fi
  output_json_object_begin
  output_json_kv "id" "$NOTIFICATIONS_RECORD_ID"
  output_json_kv "app" "$NOTIFICATIONS_RECORD_APP"
  output_json_kv "object_type" "$NOTIFICATIONS_RECORD_TYPE"
  output_json_kv "subject" "$NOTIFICATIONS_RECORD_SUBJECT"
  output_json_kv "message" "$NOTIFICATIONS_RECORD_MESSAGE"
  output_json_kv "link" "$NOTIFICATIONS_RECORD_LINK"
  output_json_kv "datetime" "$NOTIFICATIONS_RECORD_DATETIME"
  output_json_kv_raw "seen" "$seen"
  output_json_object_end
  NOTIFICATIONS_PRINTED=$((NOTIFICATIONS_PRINTED + 1))
  return 0
}

# notifications_print_json XML - print the filtered notifications as
# `{"notifications": [...]}` with id, app, object_type, subject, message,
# link, datetime, and a seen flag from the cache. --limit applies after the
# filters; --quiet does not suppress the document.
notifications_print_json() {
  notifications_resolve_limit
  NOTIFICATIONS_PRINTED=0
  output_json_list_begin "notifications"
  notifications_for_each_record "$1" notifications_json_row
  output_json_list_end
  return 0
}

# notifications_notify_row - send one desktop notification for the current
# record unless it is the record deleted in this run or already seen; stop the
# walk once --limit notifications are sent.
notifications_notify_row() {
  local id="$NOTIFICATIONS_RECORD_ID" subject="" app=""
  notifications_passes_unseen || return 0
  [[ -z "$NOTIFICATIONS_SKIP_ID" || "$id" != "$NOTIFICATIONS_SKIP_ID" ]] || return 0
  seen_contains "$NOTIFICATIONS_SEEN" "$id" && return 0
  [[ "$NOTIFICATIONS_USE_LIMIT" -eq 0 || "$NOTIFICATIONS_SENT_COUNT" -lt "$NOTIFICATIONS_LIMIT" ]] || return 1
  if type notify_send >/dev/null 2>&1; then
    subject=${ notifications_subject "$NOTIFICATIONS_RECORD_SUBJECT" "$NOTIFICATIONS_RECORD_MESSAGE";}
    app=${ printable "$NOTIFICATIONS_RECORD_APP";}
    notify_send "Nextcloud" "${app}: ${subject}"
  fi
  NOTIFICATIONS_NEW_IDS="${NOTIFICATIONS_NEW_IDS}${id}"$'\n'
  NOTIFICATIONS_SENT_COUNT=$((NOTIFICATIONS_SENT_COUNT + 1))
  return 0
}

# notifications_notify XML DELETE_ID DELETE_ALL - notify the not-yet-seen
# records passing the filters and record them in NOTIFICATIONS_SEEN. --limit
# caps how many notifications are sent; the id deleted in this run is
# skipped. Sending is best-effort: a missing notify_send or a failed send is
# ignored.
notifications_notify() {
  local xml="$1" delete_id="$2" delete_all="$3"
  [[ "$delete_all" -eq 1 ]] && return 0
  notifications_resolve_limit
  NOTIFICATIONS_SKIP_ID="$delete_id"
  NOTIFICATIONS_NEW_IDS=""
  NOTIFICATIONS_SENT_COUNT=0
  notifications_for_each_record "$xml" notifications_notify_row
  [[ -z "$NOTIFICATIONS_NEW_IDS" ]] || printf '%s' "$NOTIFICATIONS_NEW_IDS" | seen_record "$NOTIFICATIONS_SEEN"
  return 0
}

# notifications_action_records XML - one TAB-separated record per nested
# action of every notification: id, notification_id, label, method, type,
# link. A single depth-aware xml_walk_top pass over the document (shared
# _AWK_XML_LIB) walks the top-level <element> blocks, the first <actions>
# body, and its nested <element>/<action> wrappers, replacing the per-block
# and per-field xml_get forks. The top-level blocks are copied out before the
# nested walk reuses the same awk buffers, so nested <element> wrappers stay
# inside their parent block.
notifications_action_records() {
  printf '%s' "$1" | awk "${_AWK_XML_LIB}"'
    function notif_action(id, nid, block) {
      printf "%s\t%s\t%s\t%s\t%s\t%s\n", id, nid, xml_extract(block, "label"), xml_extract(block, "method"), xml_extract(block, "type"), xml_extract(block, "link")
    }
    function notif_notification(block,    id, nid, apos, body, cend, wrapper, an, ai) {
      id = xml_extract(block, "id")
      nid = xml_extract(block, "notification_id")
      apos = index(block, "<actions>")
      if (apos == 0) return
      body = substr(block, apos + length("<actions>"))
      cend = index(body, "</actions>")
      if (cend > 0) body = substr(body, 1, cend - 1)
      if (body == "") return
      wrapper = "action"
      if (index(body, "<element") > 0) wrapper = "element"
      an = xml_walk_top(body, wrapper, "store")
      for (ai = 1; ai <= an; ai++) notif_action(id, nid, xml_top_block[ai])
    }
    function notif_document(doc,    n, i, top) {
      n = xml_walk_top(doc, "element", "store")
      for (i = 1; i <= n; i++) top[i] = xml_top_block[i]
      for (i = 1; i <= n; i++) notif_notification(top[i])
    }
    { doc = doc $0 }
    END { notif_document(doc) }
  '
}

# notifications_find_action XML ID LABEL - on success print "METHOD<TAB>LINK"
# for the first action of notification ID whose <label> matches LABEL
# case-insensitively; return 1 when there is no such action. The HTTP method
# comes from <method>, falls back to an HTTP-method <type> (the API's other
# spelling), and defaults to POST. Matching runs in the shell over the
# single-pass records.
notifications_find_action() {
  local xml="$1" want_id="$2" want_label="$3"
  local want_lc="" line="" id="" nid="" label="" label_lc="" method="" type="" link="" upper=""
  want_lc="${want_label,,}"
  while IFS= read -r line; do
    record_split "$line" id nid label method type link
    [[ "$id" == "$want_id" || "$nid" == "$want_id" ]] || continue
    label_lc="${label,,}"
    [[ -n "$label_lc" && "$label_lc" == "$want_lc" ]] || continue
    upper="${method^^}"
    case "$upper" in
      POST | PUT | DELETE) ;;
      *) method="$type" ;;
    esac
    upper="${method^^}"
    case "$upper" in
      POST | PUT | DELETE) method="$upper" ;;
      *) method="POST" ;;
    esac
    printf '%s\t%s\n' "$method" "$link"
    return 0
  done < <(notifications_action_records "$xml")
  return 1
}

# notifications_action_absolute LABEL ID METHOD LINK - run an absolute action
# link through http_curl with the OCS-APIRequest header. Refuses an off-origin
# link before the request.
notifications_action_absolute() {
  local label="$1" id="$2" method="$3" link="$4"
  [[ "$(http_origin "$link")" == "$(http_origin "$HTTP_BASE")" ]] ||
    die "notification ${id}: refusing action '${label}' with an off-origin link: $(printable "$link")"
  http_request_allow "$method" "$link" -H 'OCS-APIRequest: true'
  if ! http_ok_code_2xx "$HTTP_CODE"; then
    http_die_http_error "$method" "$link"
  fi
}

# notifications_action_ocs LABEL ID METHOD LINK - run an OCS-relative action
# link through ocs_request (a leading /ocs/v2.php or /ocs/v1.php is dropped
# because the helper adds the root).
notifications_action_ocs() {
  local label="$1" id="$2" method="$3" link="$4" path=""
  case "$link" in
    /ocs/* | /apps/* | /index.php/*) ;;
    *)
      die "notification ${id}: refusing action '${label}' with an unsupported link: $(printable "$link")"
      ;;
  esac
  path="$link"
  case "$path" in
    /ocs/v2.php/*) path="${path#/ocs/v2.php}" ;;
    /ocs/v1.php/*) path="${path#/ocs/v1.php}" ;;
    /*) ;;
    *) path="/${path}" ;;
  esac
  ocs_request_allow "$method" "$path"
  if ! http_ok_code_2xx "$HTTP_CODE"; then
    http_die_http_error "$method" "${HTTP_OCS_ROOT}${path}"
  fi
  [[ "$OCS_STATUS" == "ok" ]] ||
    die "Nextcloud API error $(printable "${OCS_STATUSCODE:-?}"): $(printable "${OCS_MESSAGE:-request failed}")"
}

# notifications_run_action LABEL ID METHOD LINK - execute one notification
# action and print what ran. Absolute links go through http_curl with the
# OCS-APIRequest header; OCS-relative links through ocs_request (a leading
# /ocs/v2.php or /ocs/v1.php is dropped because the helper adds the root).
notifications_run_action() {
  local label="$1" id="$2" method="$3" link="$4"
  [[ -n "$link" ]] || die "notification ${id}: action '${label}' has no link"
  case "$link" in
    http://* | https://*) notifications_action_absolute "$label" "$id" "$method" "$link" ;;
    *) notifications_action_ocs "$label" "$id" "$method" "$link" ;;
  esac
  printf 'ran action %s on notification %s (%s %s)\n' "$(printable "$label")" \
    "$(printable "$id")" "$(printable "$method")" "$(printable "$link")"
  return 0
}

# notifications_fetch - GET the collection into NOTIFICATIONS_XML. 204/304
# mean an empty collection.
notifications_fetch() {
  local path=""
  path=${ notifications_api_path;}
  ocs_request_allow GET "$path"
  ocs_check_response GET "${HTTP_OCS_ROOT}${path}"
  case "$HTTP_CODE" in
    204 | 304) NOTIFICATIONS_XML="" ;;
    *) NOTIFICATIONS_XML="$HTTP_BODY" ;;
  esac
  return 0
}

# notifications_watch_row - print (unless --quiet) and optionally notify the
# current not-yet-seen record; stop the walk once --limit records are handled.
notifications_watch_row() {
  local id="$NOTIFICATIONS_RECORD_ID" subject="" app=""
  seen_contains "$NOTIFICATIONS_SEEN" "$id" && return 0
  [[ "$NOTIFICATIONS_USE_LIMIT" -eq 0 || "$NOTIFICATIONS_SENT_COUNT" -lt "$NOTIFICATIONS_LIMIT" ]] || return 1
  [[ "${OPT_quiet:-0}" == "1" ]] || notifications_print_record
  if [[ "${OPT_notify:-0}" == "1" ]] && type notify_send >/dev/null 2>&1; then
    subject=${ notifications_subject "$NOTIFICATIONS_RECORD_SUBJECT" "$NOTIFICATIONS_RECORD_MESSAGE";}
    app=${ printable "$NOTIFICATIONS_RECORD_APP";}
    notify_send "Nextcloud" "${app}: ${subject}"
  fi
  NOTIFICATIONS_NEW_IDS="${NOTIFICATIONS_NEW_IDS}${id}"$'\n'
  NOTIFICATIONS_SENT_COUNT=$((NOTIFICATIONS_SENT_COUNT + 1))
  return 0
}

# notifications_watch_cycle XML - one poll iteration: print (unless --quiet)
# and optionally notify the new records passing the filters, at most --limit,
# then record their ids in NOTIFICATIONS_SEEN. Watch always treats the seen
# cache as the "new" boundary, so --unseen adds nothing here.
notifications_watch_cycle() {
  notifications_resolve_limit
  NOTIFICATIONS_NEW_IDS=""
  NOTIFICATIONS_SENT_COUNT=0
  notifications_for_each_record "$1" notifications_watch_row
  [[ -z "$NOTIFICATIONS_NEW_IDS" ]] || printf '%s' "$NOTIFICATIONS_NEW_IDS" | seen_record "$NOTIFICATIONS_SEEN"
  return 0
}

# notifications_watch_loop INTERVAL - refresh every INTERVAL seconds until
# INT/TERM (exit 130/143), like status --watch.
notifications_watch_loop() {
  local interval="$1"
  trap 'exit 130' INT
  trap 'exit 143' TERM
  while true; do
    notifications_fetch || return 1
    notifications_watch_cycle "$NOTIFICATIONS_XML"
    sleep "$interval"
  done
}

# notifications_parse_argv ARRAY "$@" - fold the CLI arguments into the token
# list opt_parse expects, writing it to the array named by ARRAY. "--action
# ID LABEL" is folded into one --action=ID LABEL value; --watch's optional
# interval is handled by opt_parse's "o" kind.
notifications_parse_argv() {
  local -n dest="$1"
  shift
  dest=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --action)
        [[ $# -ge 3 && -n "${2:-}" && -n "${3:-}" ]] ||
          usage_error notifications "--action requires an id and a label"
        dest+=("--action=$2 $3")
        shift 3
        ;;
      --action=*)
        [[ -n "${1#--action=}" && -n "${2:-}" ]] ||
          usage_error notifications "--action requires an id and a label"
        dest+=("--action=${1#--action=} $2")
        shift 2
        ;;
      *)
        dest+=("$1")
        shift
        ;;
    esac
  done
}

# notifications_validate_watch - validate --watch and its exclusions. The
# interval itself is resolved later by notifications_dispatch_watch.
notifications_validate_watch() {
  if [[ "${OPT_watch:-}" != "default" ]]; then
    is_uint "${OPT_watch:-}" || usage_error notifications "invalid --watch value: ${OPT_watch}"
    [[ "$((10#${OPT_watch}))" -gt 0 ]] || usage_error notifications "invalid --watch value: ${OPT_watch}"
  fi
  if [[ -n "${OPT_json:-}" ]]; then
    usage_error notifications "--watch cannot be combined with --json"
  fi
  if [[ -n "${OPT_delete_SET:-}" || -n "${OPT_delete_all_SET:-}" ]]; then
    usage_error notifications "--watch cannot be combined with --delete/--delete-all"
  fi
  if [[ -n "${OPT_action_SET:-}" ]]; then
    usage_error notifications "--watch cannot be combined with --action"
  fi
}

# notifications_validate_action - validate --action's exclusions and split its
# folded "ID LABEL" value into NOTIFICATIONS_ACTION_ID/LABEL.
notifications_validate_action() {
  if [[ -n "${OPT_delete_SET:-}" || -n "${OPT_delete_all_SET:-}" ]]; then
    usage_error notifications "--action cannot be combined with --delete/--delete-all"
  fi
  NOTIFICATIONS_ACTION_ID="${OPT_action:-}"
  NOTIFICATIONS_ACTION_LABEL="$NOTIFICATIONS_ACTION_ID"
  NOTIFICATIONS_ACTION_ID="${NOTIFICATIONS_ACTION_ID%% *}"
  NOTIFICATIONS_ACTION_LABEL="${NOTIFICATIONS_ACTION_LABEL#* }"
  numeric_id "$NOTIFICATIONS_ACTION_ID" ||
    usage_error notifications "invalid notification id: $(printable "$NOTIFICATIONS_ACTION_ID")"
}

# notifications_validate_options - perform all option validation in the
# original order and derive the action, delete, and json state on the
# NOTIFICATIONS_* module globals.
notifications_validate_options() {
  NOTIFICATIONS_ACTION_ID=""
  NOTIFICATIONS_ACTION_LABEL=""
  NOTIFICATIONS_DELETE_ID=""
  NOTIFICATIONS_DELETE_ALL=0
  if [[ -n "${OPT_delete_SET:-}" && -n "${OPT_delete_all_SET:-}" ]]; then
    usage_error notifications "--delete and --delete-all are mutually exclusive"
  fi
  if [[ -n "${OPT_limit_SET:-}" ]]; then
    opt_require_uint notifications --limit "${OPT_limit:-}" 0
  fi
  if [[ -n "${OPT_watch_SET:-}" ]]; then
    notifications_validate_watch
  fi
  if [[ -n "${OPT_action_SET:-}" ]]; then
    notifications_validate_action
  fi
  if [[ -n "${OPT_delete_SET:-}" ]]; then
    NOTIFICATIONS_DELETE_ID="${OPT_delete:-}"
    numeric_id "$NOTIFICATIONS_DELETE_ID" ||
      usage_error notifications "invalid --delete id: $(printable "$NOTIFICATIONS_DELETE_ID")"
  fi
  opt_into NOTIFICATIONS_DELETE_ALL delete_all_SET 1
}

# notifications_dispatch_watch - resolve the poll interval (a bare --watch
# uses NOTIFY_WATCH_INTERVAL, falling back to 60) and run the foreground loop.
notifications_dispatch_watch() {
  local watch_interval=""
  if [[ "${OPT_watch:-}" == "default" ]]; then
    watch_interval="${NOTIFY_WATCH_INTERVAL:-60}"
    is_uint "$watch_interval" || watch_interval=60
  else
    watch_interval="$((10#${OPT_watch}))"
  fi
  notifications_watch_loop "$watch_interval"
}

# notifications_render_output - fetch the collection and print it as table
# rows or as one JSON document.
notifications_render_output() {
  notifications_fetch
  if output_json_enabled; then
    notifications_print_json "$NOTIFICATIONS_XML"
  else
    notifications_print_rows "$NOTIFICATIONS_XML"
  fi
}

# notifications_perform_action - look up the requested action in the fetched
# collection and run it; die when the label is absent.
notifications_perform_action() {
  local action_result=""
  if ! action_result="$(notifications_find_action "$NOTIFICATIONS_XML" \
    "$NOTIFICATIONS_ACTION_ID" "$NOTIFICATIONS_ACTION_LABEL")"; then
    die "no action '$(printable "$NOTIFICATIONS_ACTION_LABEL")' found for notification $(printable "$NOTIFICATIONS_ACTION_ID")"
  fi
  notifications_run_action "$NOTIFICATIONS_ACTION_LABEL" "$NOTIFICATIONS_ACTION_ID" \
    "${action_result%%$'\t'*}" "${action_result#*$'\t'}"
}

# notifications_run_delete - run --delete or --delete-all. Returns 1 when
# --delete-all's confirmation is declined so the caller can abort cleanly.
notifications_run_delete() {
  if [[ -n "$NOTIFICATIONS_DELETE_ID" ]]; then
    ocs_request DELETE "$(notifications_api_path)/${NOTIFICATIONS_DELETE_ID}"
    printf 'deleted notification %s\n' "$(printable "$NOTIFICATIONS_DELETE_ID")"
    return 0
  fi
  if [[ "$NOTIFICATIONS_DELETE_ALL" -eq 1 ]]; then
    notifications_confirm_delete_all || return 1
    ocs_request DELETE "$(notifications_api_path)"
    printf 'deleted all notifications\n'
  fi
  return 0
}

cmd_notifications() {
  local -a args=()
  notifications_parse_argv args "$@"
  opt_begin "limit:s app:s type:s unseen:b action:s delete:s delete-all:b notify:b quiet:b yes:b json:b watch:o:default" notifications "" "${args[@]}"
  opt_guard notifications
  # The OCS calls go through http.sh; load them after opt_guard's --help
  # exit so `sciebo notifications --help` parses none of them.
  sciebo_require_module http xml_get
  # ui loads for the delete confirmation; notify for --notify rows (both
  # before their `type` probes so neither silently skips).
  sciebo_require_module ui ui_confirm_mutation
  sciebo_require_module notify notify_send
  notifications_validate_options
  opt_json_mode
  http_load_context

  if [[ -n "${OPT_watch_SET:-}" ]]; then
    notifications_dispatch_watch
    return $?
  fi

  notifications_render_output

  if [[ -n "${OPT_action_SET:-}" ]]; then
    notifications_perform_action
  fi

  notifications_run_delete || return 0

  if [[ "${OPT_notify:-0}" == "1" ]]; then
    notifications_notify "$NOTIFICATIONS_XML" "$NOTIFICATIONS_DELETE_ID" "$NOTIFICATIONS_DELETE_ALL"
  fi
  return 0
}
