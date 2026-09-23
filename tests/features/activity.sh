#!/usr/bin/env bash
# activity.sh - activity stream listing and filtering through the shared
# HTTP layer (stub curl); --notify uses a stub osascript.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

NOTIFY_BIN="${TMP}/notify-bin"
mkdir -p "$NOTIFY_BIN"
cat >"${NOTIFY_BIN}/osascript" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$(dirname "$0")/calls.log"
exit 0
STUB
chmod +x "${NOTIFY_BIN}/osascript"
rm -f "${NOTIFY_BIN}/calls.log"

ACTIVITY_SEEN_PATH="${STATE_DIR}/activity-seen"
# The recent fixture timestamp is derived at run time so --since never ages.
RECENT_UTC="$(date -u '+%Y-%m-%dT%H:%M:%S+00:00')"

# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_cli_nc_notify() {
  (cd "$TMP" && env PATH="${NOTIFY_BIN}:${STUB_BIN}:$PATH" RCLONE_REMOTE=webtest NOTIFY=1 \
    bash "${PROJ}/bin/sciebo" "$@")
}
notify_calls() { cat "${NOTIFY_BIN}/calls.log" 2>/dev/null || true; }

# --- listing: HTML stripped, both rows and links shown ----------------------
stub_clear_calls
stub_reset_routes
stub_route GET '*apps/activity/api/v2/activity*' 200 <<XML
<?xml version="1.0"?>
<ocs>
 <meta><status>ok</status><statuscode>200</statuscode><message>OK</message></meta>
 <data>
  <element>
   <activity_id>21</activity_id>
   <datetime>${RECENT_UTC}</datetime>
   <app>files</app>
   <type>file_created</type>
   <user>alice</user>
   <subject>Alice created &lt;b&gt;report.txt&lt;/b&gt;</subject>
   <subject_rich><element>Alice created {file}</element><element><file><type>file</type><id>7</id></file></element></subject_rich>
   <message></message>
   <link>https://cloud.example.org/f/21</link>
  </element>
  <element>
   <activity_id>20</activity_id>
   <datetime>2020-01-01T00:00:00+00:00</datetime>
   <app>files</app>
   <type>file_changed</type>
   <user>alice</user>
   <subject>Alice changed &lt;i&gt;old.txt&lt;/i&gt;</subject>
   <message></message>
   <link>https://cloud.example.org/f/20</link>
  </element>
 </data>
</ocs>
XML

expect_cli "activity: list rc 0" 0 run_cli_nc activity
expect_contains "activity: recent datetime shown" "$CLI_OUT" "$RECENT_UTC"
expect_contains "activity: app shown" "$CLI_OUT" "files"
expect_contains "activity: subject shown" "$CLI_OUT" "Alice created report.txt"
expect_not_contains "activity: HTML tag stripped" "$CLI_OUT" "<b>"
expect_contains "activity: link shown" "$CLI_OUT" "https://cloud.example.org/f/21"
expect_contains "activity: older row shown" "$CLI_OUT" "Alice changed old.txt"
expect_contains "activity: default limit in the URL" "$(stub_calls)" "limit=20&sort=desc"

expect_cli "activity: --limit rc 0" 0 run_cli_nc activity --limit 1
expect_contains "activity: limited row shown" "$CLI_OUT" "Alice created report.txt"
expect_not_contains "activity: rows beyond the limit hidden" "$CLI_OUT" "old.txt"

# --- --since: one short page, then pagination with the since= cursor --------
stub_clear_calls
expect_cli "activity: --since rc 0" 0 run_cli_nc activity --since 1h
expect_contains "activity: recent row kept" "$CLI_OUT" "Alice created report.txt"
expect_not_contains "activity: old row filtered" "$CLI_OUT" "old.txt"
expect_contains "activity: since pages with 50 per request" "$(stub_calls)" "limit=50&sort=desc"

expect_cli "activity: --since with a bad duration rc 2" 2 run_cli_nc activity --since nope
expect_contains "activity: duration usage surfaced" "$CLI_OUT" "requires a duration"

capture run_cli_nc activity --quiet
expect_rc "activity: --quiet rc 0" "$CLI_RC" 0
expect_eq "activity: --quiet prints nothing" "" "$CLI_OUT"

# --- --notify: sends unseen ids, records them, then stays quiet -------------
rm -f "$ACTIVITY_SEEN_PATH" "${NOTIFY_BIN}/calls.log"
expect_cli "activity: --notify rc 0" 0 run_cli_nc_notify activity --notify
expect_file "activity: seen cache written" "$ACTIVITY_SEEN_PATH"
expect_eq "activity: seen cache mode 600" "600" "$(file_mode "$ACTIVITY_SEEN_PATH")"
seen="$(cat "$ACTIVITY_SEEN_PATH")"
expect_contains "activity: seen id 21" "$seen" "21"
expect_contains "activity: seen id 20" "$seen" "20"
calls="$(notify_calls)"
expect_contains "activity: notification title" "$calls" "Nextcloud activity"
expect_contains "activity: notification names the app" "$calls" "files: Alice created report.txt"
rm -f "${NOTIFY_BIN}/calls.log"
expect_cli "activity: second --notify rc 0" 0 run_cli_nc_notify activity --notify
expect_no_file "activity: second run sends nothing new" "${NOTIFY_BIN}/calls.log"

# --- --limit bounds --notify as well as the listing -------------------------
stub_reset_routes
stub_route GET '*apps/activity/api/v2/activity*' 200 <<XML
<?xml version="1.0"?>
<ocs>
 <meta><status>ok</status><statuscode>200</statuscode><message>OK</message></meta>
 <data>
  <element>
   <activity_id>33</activity_id>
   <datetime>${RECENT_UTC}</datetime>
   <app>files</app>
   <type>file_changed</type>
   <user>alice</user>
   <subject>limit item three</subject>
   <message></message>
   <link>https://cloud.example.org/f/33</link>
  </element>
  <element>
   <activity_id>32</activity_id>
   <datetime>${RECENT_UTC}</datetime>
   <app>files</app>
   <type>file_changed</type>
   <user>alice</user>
   <subject>limit item two</subject>
   <message></message>
   <link>https://cloud.example.org/f/32</link>
  </element>
  <element>
   <activity_id>31</activity_id>
   <datetime>${RECENT_UTC}</datetime>
   <app>files</app>
   <type>file_changed</type>
   <user>alice</user>
   <subject>limit item one</subject>
   <message></message>
   <link>https://cloud.example.org/f/31</link>
  </element>
 </data>
</ocs>
XML
rm -f "$ACTIVITY_SEEN_PATH" "${NOTIFY_BIN}/calls.log"
expect_cli "activity: --notify --limit rc 0" 0 run_cli_nc_notify activity --notify --limit 2
expect_eq "activity: --limit bounds --notify" "2" "$(grep -c . "${NOTIFY_BIN}/calls.log")"
expect_eq "activity: --limit caches the notified ids" "2" "$(grep -c . "$ACTIVITY_SEEN_PATH")"
expect_contains "activity: first id notified" "$(cat "$ACTIVITY_SEEN_PATH")" "33"
expect_contains "activity: second id notified" "$(cat "$ACTIVITY_SEEN_PATH")" "32"
expect_not_contains "activity: id beyond the limit not notified" "$(cat "$ACTIVITY_SEEN_PATH")" "31"

# --- --since pagination: a full page, then the cursor page ------------------
# A full page without an entry older than the cutoff continues with the
# smallest activity_id of the page as the next since= cursor; the second
# page then crosses the cutoff and the old row is filtered locally.
PAGE1="${TMP}/activity-page1.xml"
{
  printf '<?xml version="1.0"?>\n<ocs>\n<meta><status>ok</status><statuscode>200</statuscode><message>OK</message></meta>\n<data>\n'
  i=101
  while [[ "$i" -le 150 ]]; do
    printf ' <element><activity_id>%s</activity_id><datetime>%s</datetime><app>files</app><type>file_created</type><user>alice</user><subject>page one item %s</subject><message></message><link>https://cloud.example.org/f/%s</link></element>\n' \
      "$i" "$RECENT_UTC" "$i" "$i"
    i=$((i + 1))
  done
  printf '</data>\n</ocs>\n'
} >"$PAGE1"
PAGE2="${TMP}/activity-page2.xml"
cat >"$PAGE2" <<XML
<?xml version="1.0"?>
<ocs>
 <meta><status>ok</status><statuscode>200</statuscode><message>OK</message></meta>
 <data>
  <element>
   <activity_id>100</activity_id>
   <datetime>${RECENT_UTC}</datetime>
   <app>files</app>
   <type>file_changed</type>
   <user>alice</user>
   <subject>page two newest</subject>
   <message></message>
   <link>https://cloud.example.org/f/100</link>
  </element>
  <element>
   <activity_id>99</activity_id>
   <datetime>2020-01-01T00:00:00+00:00</datetime>
   <app>files</app>
   <type>file_changed</type>
   <user>alice</user>
   <subject>page two ancient</subject>
   <message></message>
   <link>https://cloud.example.org/f/99</link>
  </element>
 </data>
</ocs>
XML
stub_reset_routes
stub_route_file GET '*since=101*' "$PAGE2"
stub_route_file GET '*apps/activity/api/v2/activity*' "$PAGE1"
stub_clear_calls
expect_cli "activity: --since paginates rc 0" 0 run_cli_nc activity --since 1h --limit 100
expect_contains "activity: page one row shown" "$CLI_OUT" "page one item 101"
expect_contains "activity: page two row shown" "$CLI_OUT" "page two newest"
expect_not_contains "activity: page two old row filtered" "$CLI_OUT" "page two ancient"
expect_contains "activity: first page URL" "$(stub_calls)" "limit=50&sort=desc"
expect_contains "activity: second page uses the cursor" "$(stub_calls)" "since=101"
expect_eq "activity: two pages fetched" "2" "$(stub_count 'apps/activity/api/v2/activity')"

# --- epoch cache: a repeated datetime is parsed only once -------------------
# activity_epoch memoizes datetimes in ACTIVITY_EPOCH_CACHE, but only when the
# callers read it through the forkless ${ fn; } form; a $( ) caller would run
# in a subshell and discard the cache. A counting `date` wrapper measures the
# parses: three rows sharing one datetime must cost the same as one row.
DATE_BIN="${TMP}/date-bin"
DATE_LOG="${TMP}/date-calls.log"
REAL_DATE="$(command -v date)"
mkdir -p "$DATE_BIN"
cat >"${DATE_BIN}/date" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >>"${DATE_LOG}"
exec "${REAL_DATE}" "\$@"
STUB
chmod +x "${DATE_BIN}/date"
activity_date_calls() {
  rm -f "$DATE_LOG"
  (cd "$TMP" && env PATH="${DATE_BIN}:${STUB_BIN}:$PATH" RCLONE_REMOTE=webtest \
    bash "${PROJ}/bin/sciebo" "$@" >/dev/null 2>&1)
  local n=0
  n="$(grep -c . "$DATE_LOG" 2>/dev/null || true)"
  printf '%s' "${n:-0}"
}

stub_reset_routes
stub_route GET '*apps/activity/api/v2/activity*' 200 <<XML
<?xml version="1.0"?>
<ocs>
 <meta><status>ok</status><statuscode>200</statuscode><message>OK</message></meta>
 <data>
  <element><activity_id>43</activity_id><datetime>${RECENT_UTC}</datetime><app>files</app><type>file_created</type><user>alice</user><subject>same stamp one</subject><message></message><link>https://cloud.example.org/f/43</link></element>
  <element><activity_id>42</activity_id><datetime>${RECENT_UTC}</datetime><app>files</app><type>file_created</type><user>alice</user><subject>same stamp two</subject><message></message><link>https://cloud.example.org/f/42</link></element>
  <element><activity_id>41</activity_id><datetime>${RECENT_UTC}</datetime><app>files</app><type>file_created</type><user>alice</user><subject>same stamp three</subject><message></message><link>https://cloud.example.org/f/41</link></element>
 </data>
</ocs>
XML
same_stamp_calls="$(activity_date_calls activity --since 1h)"

stub_reset_routes
stub_route GET '*apps/activity/api/v2/activity*' 200 <<XML
<?xml version="1.0"?>
<ocs>
 <meta><status>ok</status><statuscode>200</statuscode><message>OK</message></meta>
 <data>
  <element><activity_id>43</activity_id><datetime>${RECENT_UTC}</datetime><app>files</app><type>file_created</type><user>alice</user><subject>same stamp one</subject><message></message><link>https://cloud.example.org/f/43</link></element>
 </data>
</ocs>
XML
one_stamp_calls="$(activity_date_calls activity --since 1h)"
expect_eq "activity: repeated datetime parsed once" "$one_stamp_calls" "$same_stamp_calls"

# --- empty stream and a disabled activity app -------------------------------
stub_reset_routes
stub_route GET '*apps/activity/api/v2/activity*' 304 </dev/null
expect_cli "activity: 304 rc 0" 0 run_cli_nc activity
expect_contains "activity: empty message" "$CLI_OUT" "no activities"

stub_reset_routes
stub_route GET '*apps/activity/api/v2/activity*' 200 <<'XML'
<?xml version="1.0"?>
<ocs><meta><status>failure</status><statuscode>999</statuscode><message>Activity app is disabled</message></meta><data/></ocs>
XML
expect_cli "activity: disabled app rc 1" 1 run_cli_nc activity
expect_contains "activity: OCS message surfaced" "$CLI_OUT" "Activity app is disabled"

stub_reset_routes
stub_route GET '*apps/activity/api/v2/activity*' 503 <<'XML'
<?xml version="1.0"?>
<ocs><meta><status>failure</status><statuscode>999</statuscode><message>service down</message></meta><data/></ocs>
XML
expect_cli "activity: HTTP 503 rc 1" 1 run_cli_nc activity
expect_contains "activity: HTTP status surfaced" "$CLI_OUT" "503"

expect_cli "activity: unknown option rc 2" 2 run_cli_nc activity --bogus
expect_contains "activity: usage printed" "$CLI_OUT" "Usage: sciebo activity"

finish
