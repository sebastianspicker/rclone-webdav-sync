#!/usr/bin/env bash
# notifications.sh - notification listing and deletion through the shared
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

NOTIFICATIONS_SEEN_PATH="${STATE_DIR}/notifications-seen"

# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_cli_nc_notify() {
  (cd "$TMP" && env PATH="${NOTIFY_BIN}:${STUB_BIN}:$PATH" RCLONE_REMOTE=webtest NOTIFY=1 \
    bash "${PROJ}/bin/sciebo" "$@")
}
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_cli_nc_no_stdin() {
  (cd "$TMP" && env PATH="${STUB_BIN}:$PATH" RCLONE_REMOTE=webtest \
    bash "${PROJ}/bin/sciebo" "$@" </dev/null)
}
# run_cli_nc_filters NOTIFY_APPS NOTIFY_TYPES ARGS... - run with explicit
# NOTIFY_APPS/NOTIFY_TYPES settings to exercise the filter defaults.
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_cli_nc_filters() {
  local apps="$1" types="$2"
  shift 2
  (cd "$TMP" && env PATH="${STUB_BIN}:$PATH" RCLONE_REMOTE=webtest \
    NOTIFY_APPS="$apps" NOTIFY_TYPES="$types" bash "${PROJ}/bin/sciebo" "$@")
}
notify_calls() { cat "${NOTIFY_BIN}/calls.log" 2>/dev/null || true; }
notify_count() {
  local n=0
  n="$(grep -c . "${NOTIFY_BIN}/calls.log" 2>/dev/null || true)"
  printf '%s' "${n:-0}"
}

# --- listing: rows, message fallback, links ---------------------------------
stub_clear_calls
stub_reset_routes
stub_route GET '*apps/notifications/api/v2/notifications' 200 <<'XML'
<?xml version="1.0"?>
<ocs>
 <meta><status>ok</status><statuscode>200</statuscode><message>OK</message></meta>
 <data>
  <element>
   <id>11</id>
   <app>files_sharing</app>
   <user>alice</user>
   <datetime>2026-01-02T03:04:05+00:00</datetime>
   <object_type>file</object_type>
   <object_id>42</object_id>
   <subject>Alice shared report.txt with you</subject>
   <message></message>
   <link>https://cloud.example.org/s/42</link>
   <actions>
    <element>
     <label>Accept</label>
      <link>http://127.0.0.1:9/ocs/v2.php/apps/files_sharing/api/v1/shares/42/accept</link>
      <method>DELETE</method>
     <primary>true</primary>
    </element>
    <element>
     <label>Ignore</label>
     <link>/apps/files_sharing/api/v1/shares/42/decline</link>
     <primary>false</primary>
    </element>
   </actions>
  </element>
  <element>
   <id>12</id>
   <app>calendar</app>
   <user>alice</user>
   <datetime>2026-01-01T00:00:00+00:00</datetime>
   <object_type></object_type>
   <object_id></object_id>
   <subject></subject>
   <message>Reminder: standup in 5 minutes</message>
   <link></link>
  </element>
  <element>
   <id>13</id>
   <app>spreed</app>
   <user>alice</user>
   <datetime>2025-12-31T23:59:59+00:00</datetime>
   <subject>Bob mentioned you</subject>
   <message></message>
   <link>https://cloud.example.org/call/13</link>
  </element>
 </data>
</ocs>
XML
stub_route DELETE '*apps/notifications/api/v2/notifications*' 200 <<'XML'
<?xml version="1.0"?>
<ocs><meta><status>ok</status><statuscode>200</statuscode><message>OK</message></meta><data/></ocs>
XML

expect_cli "notifications: list rc 0" 0 run_cli_nc notifications
expect_contains "notifications: id shown" "$CLI_OUT" "11"
expect_contains "notifications: app shown" "$CLI_OUT" "files_sharing"
expect_contains "notifications: subject shown" "$CLI_OUT" "Alice shared report.txt with you"
expect_contains "notifications: link shown" "$CLI_OUT" "https://cloud.example.org/s/42"
expect_contains "notifications: message fallback shown" "$CLI_OUT" "Reminder: standup in 5 minutes"
expect_contains "notifications: third row shown" "$CLI_OUT" "Bob mentioned you"
expect_not_contains "notifications: nested action labels are not rows" "$CLI_OUT" "Ignore"
expect_not_contains "notifications: nested action links are not rows" "$CLI_OUT" "shares/42/accept"
expect_eq "notifications: one GET" "1" "$(stub_count 'GET.*notifications')"

expect_cli "notifications: --limit rc 0" 0 run_cli_nc notifications --limit 1
expect_contains "notifications: limited row shown" "$CLI_OUT" "Alice shared report.txt with you"
expect_not_contains "notifications: rows beyond the limit hidden" "$CLI_OUT" "Bob mentioned you"

capture run_cli_nc notifications --quiet
expect_rc "notifications: --quiet rc 0" "$CLI_RC" 0
expect_eq "notifications: --quiet prints nothing" "" "$CLI_OUT"

# --- --notify: sends unseen ids, records them, then stays quiet -------------
rm -f "$NOTIFICATIONS_SEEN_PATH" "${NOTIFY_BIN}/calls.log"
expect_cli "notifications: --notify rc 0" 0 run_cli_nc_notify notifications --notify
expect_file "notifications: seen cache written" "$NOTIFICATIONS_SEEN_PATH"
expect_eq "notifications: seen cache mode 600" "600" "$(file_mode "$NOTIFICATIONS_SEEN_PATH")"
seen="$(cat "$NOTIFICATIONS_SEEN_PATH")"
expect_contains "notifications: seen id 11" "$seen" "11"
expect_contains "notifications: seen id 12" "$seen" "12"
expect_contains "notifications: seen id 13" "$seen" "13"
calls="$(notify_calls)"
expect_contains "notifications: notification title" "$calls" "Nextcloud"
expect_contains "notifications: notification names the app" "$calls" "files_sharing: Alice shared report.txt with you"
expect_contains "notifications: notification uses the fallback" "$calls" "calendar: Reminder: standup in 5 minutes"
rm -f "${NOTIFY_BIN}/calls.log"
expect_cli "notifications: second --notify rc 0" 0 run_cli_nc_notify notifications --notify
expect_no_file "notifications: second run sends nothing new" "${NOTIFY_BIN}/calls.log"

# A deleted notification is neither notified nor cached in the same run.
rm -f "$NOTIFICATIONS_SEEN_PATH" "${NOTIFY_BIN}/calls.log"
expect_cli "notifications: --delete --notify rc 0" 0 run_cli_nc_notify notifications --delete 12 --notify
expect_contains "notifications: delete --notify still confirms" "$CLI_OUT" "deleted notification 12"
expect_contains "notifications: remaining id notified" "$(notify_calls)" "files_sharing:"
expect_not_contains "notifications: deleted id not notified" "$(notify_calls)" "calendar:"
expect_not_contains "notifications: deleted id not cached" "$(cat "$NOTIFICATIONS_SEEN_PATH")" "12"

# --- --delete / --delete-all: URLs and confirmation -------------------------
stub_clear_calls
expect_cli "notifications: --delete rc 0" 0 run_cli_nc notifications --delete 12
expect_contains "notifications: delete confirmation" "$CLI_OUT" "deleted notification 12"
expect_eq "notifications: one DELETE" "1" "$(stub_count '^DELETE')"
expect_contains "notifications: delete URL" "$(stub_calls)" \
  "DELETE	http://127.0.0.1:9/ocs/v2.php/apps/notifications/api/v2/notifications/12"

stub_clear_calls
expect_cli "notifications: --delete-all without --yes rc 2" 2 run_cli_nc_no_stdin notifications --delete-all
expect_contains "notifications: --delete-all names --yes" "$CLI_OUT" "requires --yes"
expect_eq "notifications: no DELETE without --yes" "0" "$(stub_count '^DELETE')"

stub_clear_calls
expect_cli "notifications: --delete-all --yes rc 0" 0 run_cli_nc_no_stdin notifications --delete-all --yes
expect_contains "notifications: delete-all confirmation" "$CLI_OUT" "deleted all notifications"
expect_eq "notifications: one delete-all DELETE" "1" "$(stub_count '^DELETE')"
expect_contains "notifications: delete-all URL" "$(stub_calls)" \
  "DELETE	http://127.0.0.1:9/ocs/v2.php/apps/notifications/api/v2/notifications"

# --- --app/--type filters and the NOTIFY_APPS/NOTIFY_TYPES defaults ---------
stub_clear_calls
expect_cli "notifications: --app filter rc 0" 0 run_cli_nc notifications --app files_sharing
expect_contains "notifications: --app keeps the matching app" "$CLI_OUT" "Alice shared report.txt with you"
expect_not_contains "notifications: --app hides other apps" "$CLI_OUT" "Bob mentioned you"
expect_not_contains "notifications: --app hides the fallback row" "$CLI_OUT" "Reminder: standup in 5 minutes"

expect_cli "notifications: --app comma list rc 0" 0 run_cli_nc notifications --app "calendar,spreed"
expect_contains "notifications: comma list keeps calendar" "$CLI_OUT" "Reminder: standup in 5 minutes"
expect_contains "notifications: comma list keeps spreed" "$CLI_OUT" "Bob mentioned you"
expect_not_contains "notifications: comma list hides files_sharing" "$CLI_OUT" "Alice shared report.txt with you"

expect_cli "notifications: --app colon list rc 0" 0 run_cli_nc notifications --app "calendar:spreed"
expect_contains "notifications: colon list works" "$CLI_OUT" "Bob mentioned you"

expect_cli "notifications: --type filter rc 0" 0 run_cli_nc notifications --type file
expect_contains "notifications: --type keeps the matching type" "$CLI_OUT" "Alice shared report.txt with you"
expect_not_contains "notifications: --type hides empty types" "$CLI_OUT" "Bob mentioned you"

expect_cli "notifications: --app is case-sensitive rc 0" 0 run_cli_nc notifications --app FILES_SHARING
expect_contains "notifications: case-sensitive filter matches nothing" "$CLI_OUT" "no notifications"

expect_cli "notifications: NOTIFY_APPS default rc 0" 0 run_cli_nc_filters "calendar" "" notifications
expect_contains "notifications: NOTIFY_APPS keeps the app" "$CLI_OUT" "Reminder: standup in 5 minutes"
expect_not_contains "notifications: NOTIFY_APPS hides others" "$CLI_OUT" "Alice shared report.txt with you"

expect_cli "notifications: --app overrides NOTIFY_APPS rc 0" 0 run_cli_nc_filters "calendar" "" notifications --app files_sharing
expect_contains "notifications: option wins over the setting" "$CLI_OUT" "Alice shared report.txt with you"
expect_not_contains "notifications: setting does not filter when --app is given" "$CLI_OUT" "Reminder: standup in 5 minutes"

expect_cli "notifications: NOTIFY_TYPES default rc 0" 0 run_cli_nc_filters "" "file" notifications
expect_contains "notifications: NOTIFY_TYPES keeps the type" "$CLI_OUT" "Alice shared report.txt with you"
expect_not_contains "notifications: NOTIFY_TYPES hides others" "$CLI_OUT" "Bob mentioned you"

# --- --unseen: filter by the seen cache without writing it ------------------
rm -f "$NOTIFICATIONS_SEEN_PATH"
expect_cli "notifications: --unseen listing rc 0" 0 run_cli_nc notifications --unseen
expect_contains "notifications: --unseen shows all when nothing is seen" "$CLI_OUT" "Alice shared report.txt with you"
expect_contains "notifications: --unseen shows the third row" "$CLI_OUT" "Bob mentioned you"
expect_no_file "notifications: --unseen listing does not write the cache" "$NOTIFICATIONS_SEEN_PATH"

printf '11\n' >"$NOTIFICATIONS_SEEN_PATH"
expect_cli "notifications: --unseen hides seen ids rc 0" 0 run_cli_nc notifications --unseen
expect_not_contains "notifications: --unseen hides the seen id" "$CLI_OUT" "Alice shared report.txt with you"
expect_contains "notifications: --unseen keeps the unseen rows" "$CLI_OUT" "Reminder: standup in 5 minutes"
expect_eq "notifications: --unseen listing keeps the cache" "11" "$(cat "$NOTIFICATIONS_SEEN_PATH")"
rm -f "${NOTIFY_BIN}/calls.log"
expect_cli "notifications: --unseen --notify rc 0" 0 run_cli_nc_notify notifications --unseen --notify
expect_not_contains "notifications: --unseen --notify skips seen ids" "$(notify_calls)" "files_sharing:"
expect_contains "notifications: --unseen --notify sends unseen ids" "$(notify_calls)" "spreed: Bob mentioned you"
expect_contains "notifications: --unseen --notify caches the unseen ids" "$(cat "$NOTIFICATIONS_SEEN_PATH")" "13"

# --- --limit bounds --notify as well as the listing -------------------------
rm -f "$NOTIFICATIONS_SEEN_PATH" "${NOTIFY_BIN}/calls.log"
expect_cli "notifications: --notify --limit rc 0" 0 run_cli_nc_notify notifications --notify --limit 1
expect_eq "notifications: --limit bounds --notify" "1" "$(notify_count)"
expect_contains "notifications: --limit caches the notified id" "$(cat "$NOTIFICATIONS_SEEN_PATH")" "11"
expect_not_contains "notifications: --limit leaves later ids uncached" "$(cat "$NOTIFICATIONS_SEEN_PATH")" "13"

expect_cli "notifications: --app --limit rc 0" 0 run_cli_nc notifications --app spreed --limit 1
expect_contains "notifications: --limit applies after the filter" "$CLI_OUT" "Bob mentioned you"
expect_not_contains "notifications: --limit hides the fallback row" "$CLI_OUT" "Reminder: standup in 5 minutes"

# --- --json ----------------------------------------------------------------
rm -f "$NOTIFICATIONS_SEEN_PATH"
expect_cli "notifications: --json rc 0" 0 run_cli_nc notifications --json
expect_contains "notifications: json array" "$CLI_OUT" '"notifications": ['
expect_contains "notifications: json id" "$CLI_OUT" '"id": "11"'
expect_contains "notifications: json app" "$CLI_OUT" '"app": "files_sharing"'
expect_contains "notifications: json object_type" "$CLI_OUT" '"object_type": "file"'
expect_contains "notifications: json subject" "$CLI_OUT" '"subject": "Alice shared report.txt with you"'
expect_contains "notifications: json message" "$CLI_OUT" '"message": "Reminder: standup in 5 minutes"'
expect_contains "notifications: json link" "$CLI_OUT" '"link": "https://cloud.example.org/s/42"'
expect_contains "notifications: json datetime" "$CLI_OUT" '"datetime": "2026-01-02T03:04:05+00:00"'
expect_contains "notifications: json unseen flag" "$CLI_OUT" '"seen": false'

printf '11\n' >"$NOTIFICATIONS_SEEN_PATH"
expect_cli "notifications: --json marks seen ids rc 0" 0 run_cli_nc notifications --json
expect_contains "notifications: json seen flag" "$CLI_OUT" '"seen": true'
expect_cli "notifications: --json --unseen rc 0" 0 run_cli_nc notifications --json --unseen
expect_not_contains "notifications: --json --unseen hides seen ids" "$CLI_OUT" '"id": "11"'
expect_contains "notifications: --json --unseen keeps unseen ids" "$CLI_OUT" '"id": "13"'
expect_cli "notifications: --json --limit rc 0" 0 run_cli_nc notifications --json --limit 1
expect_not_contains "notifications: --json --limit hides later ids" "$CLI_OUT" '"id": "13"'
rm -f "$NOTIFICATIONS_SEEN_PATH"

# --- --action: label lookup and link execution ------------------------------
stub_route DELETE '*shares/42/accept*' 200 <<'XML'
<?xml version="1.0"?>
<ocs><meta><status>ok</status><statuscode>200</statuscode><message>OK</message></meta><data/></ocs>
XML
stub_route POST '*shares/42/decline*' 200 <<'XML'
<?xml version="1.0"?>
<ocs><meta><status>ok</status><statuscode>200</statuscode><message>OK</message></meta><data/></ocs>
XML

stub_clear_calls
expect_cli "notifications: --action absolute link rc 0" 0 run_cli_nc notifications --action 11 accept
expect_contains "notifications: action reports what ran" "$CLI_OUT" "ran action accept on notification 11"
expect_contains "notifications: absolute action DELETE url" "$(stub_calls)" \
  "DELETE	http://127.0.0.1:9/ocs/v2.php/apps/files_sharing/api/v1/shares/42/accept"

stub_clear_calls
expect_cli "notifications: --action relative link rc 0" 0 run_cli_nc notifications --action 11 Ignore
expect_contains "notifications: relative action defaults to POST" "$(stub_calls)" \
  "POST	http://127.0.0.1:9/ocs/v2.php/apps/files_sharing/api/v1/shares/42/decline"

expect_cli "notifications: unknown action rc 1" 1 run_cli_nc notifications --action 11 Nope
expect_contains "notifications: unknown action message" "$CLI_OUT" "no action 'Nope' found"
expect_cli "notifications: --action without label rc 2" 2 run_cli_nc notifications --action 11
expect_contains "notifications: --action usage surfaced" "$CLI_OUT" "requires an id and a label"

# --- --action: single-pass parser edge cases --------------------------------
stub_reset_routes
stub_route GET '*apps/notifications/api/v2/notifications' 200 <<'XML'
<?xml version="1.0"?>
<ocs>
 <meta><status>ok</status><statuscode>200</statuscode><message>OK</message></meta>
 <data>
  <element>
   <notification_id>21</notification_id>
   <app>files_sharing</app>
   <object_type>file</object_type>
   <datetime>2026-01-02T03:04:05+00:00</datetime>
   <subject>typed action</subject>
   <message></message>
   <link></link>
   <actions>
    <element>
     <label>Accept</label>
     <link>/apps/files_sharing/api/v1/shares/42/accept</link>
     <method>delete</method>
    </element>
    <element>
     <label>Put It</label>
     <link>/apps/files_sharing/api/v1/shares/42/put</link>
     <type>put</type>
    </element>
    <element>
     <label>Redirect</label>
     <link>/apps/files_sharing/api/v1/shares/42/redir</link>
     <method>delete</method>
    </element>
    <element>
     <label>Redirect Abs</label>
     <link>http://127.0.0.1:9/ocs/v2.php/apps/files_sharing/api/v1/shares/42/redirabs</link>
     <method>delete</method>
    </element>
   </actions>
  </element>
  <element>
   <id>22</id>
   <app>calendar</app>
   <object_type></object_type>
   <datetime>2026-01-01T00:00:00+00:00</datetime>
   <subject>bare action wrapper</subject>
   <message></message>
   <link></link>
   <actions>
    <action>
     <label>Mixed Case</label>
     <link>/apps/files_sharing/api/v1/shares/42/mixed</link>
    </action>
   </actions>
  </element>
  <element>
   <id>23</id>
   <app>spreed</app>
   <object_type></object_type>
   <datetime>2025-12-31T23:59:59+00:00</datetime>
   <subject>no actions</subject>
   <message></message>
   <link></link>
  </element>
 </data>
</ocs>
XML
stub_route DELETE '*shares/42/accept*' 200 <<'XML'
<?xml version="1.0"?>
<ocs><meta><status>ok</status><statuscode>200</statuscode><message>OK</message></meta><data/></ocs>
XML
stub_route PUT '*shares/42/put*' 200 <<'XML'
<?xml version="1.0"?>
<ocs><meta><status>ok</status><statuscode>200</statuscode><message>OK</message></meta><data/></ocs>
XML
stub_route POST '*shares/42/mixed*' 200 <<'XML'
<?xml version="1.0"?>
<ocs><meta><status>ok</status><statuscode>200</statuscode><message>OK</message></meta><data/></ocs>
XML
stub_route DELETE '*shares/42/redir*' 302 </dev/null
stub_route DELETE '*shares/42/redirabs*' 302 </dev/null

stub_clear_calls
expect_cli "notifications: --action notification_id spelling rc 0" 0 run_cli_nc notifications --action 21 accept
expect_contains "notifications: method is upper-cased" "$(stub_calls)" \
  "DELETE	http://127.0.0.1:9/ocs/v2.php/apps/files_sharing/api/v1/shares/42/accept"

stub_clear_calls
expect_cli "notifications: --action type fallback rc 0" 0 run_cli_nc notifications --action 21 "put it"
expect_contains "notifications: type supplies the method" "$(stub_calls)" \
  "PUT	http://127.0.0.1:9/ocs/v2.php/apps/files_sharing/api/v1/shares/42/put"

stub_clear_calls
expect_cli "notifications: --action action wrapper rc 0" 0 run_cli_nc notifications --action 22 "mixed case"
expect_contains "notifications: missing method defaults to POST" "$(stub_calls)" \
  "POST	http://127.0.0.1:9/ocs/v2.php/apps/files_sharing/api/v1/shares/42/mixed"

expect_cli "notifications: --action without actions rc 1" 1 run_cli_nc notifications --action 23 accept
expect_contains "notifications: no actions message" "$CLI_OUT" "no action 'accept' found"

# A 3xx answer to an action is not a successful action: curl does not follow
# redirects for POST/PUT/DELETE, so nothing ran and no action is reported.
stub_clear_calls
expect_cli "notifications: relative action redirect rc 1" 1 run_cli_nc notifications --action 21 redirect
expect_not_contains "notifications: relative redirect is not reported as run" "$CLI_OUT" "ran action"
expect_contains "notifications: relative redirect reports the status" "$CLI_OUT" "HTTP 302"

stub_clear_calls
expect_cli "notifications: absolute action redirect rc 1" 1 run_cli_nc notifications --action 21 "redirect abs"
expect_not_contains "notifications: absolute redirect is not reported as run" "$CLI_OUT" "ran action"
expect_contains "notifications: absolute redirect reports the status" "$CLI_OUT" "HTTP 302"

# --- --watch guards ---------------------------------------------------------
expect_cli "notifications: --watch --delete rc 2" 2 run_cli_nc_no_stdin notifications --watch 1 --delete 11
expect_contains "notifications: --watch delete exclusion" "$CLI_OUT" "cannot be combined"
expect_cli "notifications: --watch --delete-all rc 2" 2 run_cli_nc_no_stdin notifications --watch 1 --delete-all
expect_contains "notifications: --watch delete-all exclusion" "$CLI_OUT" "cannot be combined"
expect_cli "notifications: --watch --json rc 2" 2 run_cli_nc_no_stdin notifications --watch 1 --json
expect_contains "notifications: --watch json exclusion" "$CLI_OUT" "cannot be combined"
expect_cli "notifications: --watch 0 rc 2" 2 run_cli_nc_no_stdin notifications --watch 0
expect_contains "notifications: --watch value validated" "$CLI_OUT" "invalid --watch value"

# --- empty collection and error handling -------------------------------------
stub_reset_routes
stub_route GET '*apps/notifications/api/v2/notifications' 204 </dev/null
expect_cli "notifications: 204 rc 0" 0 run_cli_nc notifications
expect_contains "notifications: empty message" "$CLI_OUT" "no notifications"

stub_reset_routes
stub_route GET '*apps/notifications/api/v2/notifications' 200 <<'XML'
<?xml version="1.0"?>
<ocs><meta><status>failure</status><statuscode>997</statuscode><message>Notifications app is disabled</message></meta><data/></ocs>
XML
expect_cli "notifications: OCS failure rc 1" 1 run_cli_nc notifications
expect_contains "notifications: OCS message surfaced" "$CLI_OUT" "Notifications app is disabled"

stub_reset_routes
stub_route GET '*apps/notifications/api/v2/notifications' 503 <<'XML'
<?xml version="1.0"?>
<ocs><meta><status>failure</status><statuscode>997</statuscode><message>service down</message></meta><data/></ocs>
XML
expect_cli "notifications: HTTP 503 rc 1" 1 run_cli_nc notifications
expect_contains "notifications: HTTP status surfaced" "$CLI_OUT" "503"

expect_cli "notifications: unknown option rc 2" 2 run_cli_nc notifications --bogus
expect_contains "notifications: usage printed" "$CLI_OUT" "Usage: sciebo notifications"

finish
