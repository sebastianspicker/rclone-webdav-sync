#!/usr/bin/env bash
# notifications_watch.sh - `notifications --watch`: the foreground poll loop
# prints and records new notifications and stops on INT. The stub curl serves
# one response, then a changed one, while the watcher is running.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

WATCH_OUT="${TMP}/notifications-watch.out"
WATCH_PID=""
SEEN_PATH="${STATE_DIR}/notifications-seen"
NOTIFY_BIN="${TMP}/notify-bin"
mkdir -p "$NOTIFY_BIN"
cat >"${NOTIFY_BIN}/osascript" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$(dirname "$0")/calls.log"
exit 0
STUB
chmod +x "${NOTIFY_BIN}/osascript"
# Pin the backend the stub stands in for, so Linux runs use it too.
export SCIEBO_NOTIFY_BACKEND=osascript
rm -f "${NOTIFY_BIN}/calls.log"
# The background CLI inherits the stub PATH and the webtest remote from this
# shell, so the exports stay valid for the whole test.
export RCLONE_REMOTE=webtest
export PATH="${STUB_BIN}:$PATH"
BASE_PATH="$PATH"

# shellcheck disable=SC2329  # invoked through the EXIT trap
watch_cleanup() {
  if [[ -n "$WATCH_PID" ]]; then
    kill "$WATCH_PID" 2>/dev/null || true
    wait "$WATCH_PID" 2>/dev/null || true
  fi
  feature_cleanup
}
trap watch_cleanup EXIT

# start_watch ARGS... - background one watch run and record its pid. Job
# control keeps the background CLI interruptible (without it a non-interactive
# background job inherits SIGINT ignored).
# shellcheck disable=SC2329  # invoked indirectly
start_watch() {
  set -m
  bash "${PROJ}/bin/sciebo" "$@" >"$WATCH_OUT" 2>&1 &
  WATCH_PID=$!
  set +m
}

# stop_watch - interrupt the watcher and leave its exit status in WATCH_RC.
# shellcheck disable=SC2329  # invoked indirectly
stop_watch() {
  kill -INT "$WATCH_PID" 2>/dev/null || true
  wait "$WATCH_PID"
  WATCH_RC=$?
  WATCH_PID=""
}

# --- --watch 1: first response, then a changed response ----------------------
stub_clear_calls
stub_reset_routes
stub_route GET '*apps/notifications/api/v2/notifications' 200 <<'XML'
<?xml version="1.0"?>
<ocs>
 <meta><status>ok</status><statuscode>200</statuscode><message>OK</message></meta>
 <data>
  <element>
   <id>41</id>
   <app>files_sharing</app>
   <datetime>2026-01-02T03:04:05+00:00</datetime>
   <object_type>file</object_type>
   <subject>watch one</subject>
   <message></message>
   <link></link>
  </element>
 </data>
</ocs>
XML
rm -f "$SEEN_PATH" "$WATCH_OUT"
start_watch notifications --watch 1
# Wait for the first-cycle id to be recorded before swapping the response, so
# the change lands after a completed poll rather than racing the first one.
wait_for_pattern 10 "$SEEN_PATH" '^41$'

stub_reset_routes
stub_route GET '*apps/notifications/api/v2/notifications' 200 <<'XML'
<?xml version="1.0"?>
<ocs>
 <meta><status>ok</status><statuscode>200</statuscode><message>OK</message></meta>
 <data>
  <element>
   <id>42</id>
   <app>files_sharing</app>
   <datetime>2026-01-02T03:05:05+00:00</datetime>
   <object_type>file</object_type>
   <subject>watch two</subject>
   <message></message>
   <link></link>
  </element>
  <element>
   <id>41</id>
   <app>files_sharing</app>
   <datetime>2026-01-02T03:04:05+00:00</datetime>
   <object_type>file</object_type>
   <subject>watch one</subject>
   <message></message>
   <link></link>
  </element>
 </data>
</ocs>
XML
wait_for_pattern 10 "$SEEN_PATH" '^42$'

stop_watch
WATCH_TEXT="$(cat "$WATCH_OUT" 2>/dev/null || true)"
expect_rc "watch: exits 130 on INT" "$WATCH_RC" 130
expect_contains "watch: first notification printed" "$WATCH_TEXT" "watch one"
expect_contains "watch: new notification printed" "$WATCH_TEXT" "watch two"
expect_eq "watch: earlier notification not repeated" "1" \
  "$(printf '%s\n' "$WATCH_TEXT" | grep -c 'watch one')"
expect_contains "watch: first id recorded" "$(cat "$SEEN_PATH")" "41"
expect_contains "watch: new id recorded" "$(cat "$SEEN_PATH")" "42"
expect_eq "watch: exactly two ids recorded" "2" "$(grep -c . "$SEEN_PATH")"

# --- bare --watch takes the interval from NOTIFY_WATCH_INTERVAL --------------
export NOTIFY_WATCH_INTERVAL=1
stub_reset_routes
stub_route GET '*apps/notifications/api/v2/notifications' 200 <<'XML'
<?xml version="1.0"?>
<ocs>
 <meta><status>ok</status><statuscode>200</statuscode><message>OK</message></meta>
 <data>
  <element>
   <id>43</id>
   <app>spreed</app>
   <datetime>2026-01-02T03:06:05+00:00</datetime>
   <subject>bare watch</subject>
   <message></message>
   <link></link>
  </element>
 </data>
</ocs>
XML
rm -f "$SEEN_PATH" "$WATCH_OUT"
start_watch notifications --watch
wait_for_pattern 10 "$SEEN_PATH" '^43$'
stop_watch
expect_rc "watch: bare --watch exits 130 on INT" "$WATCH_RC" 130
expect_contains "watch: bare --watch uses the setting interval" \
  "$(cat "$WATCH_OUT" 2>/dev/null || true)" "bare watch"
unset NOTIFY_WATCH_INTERVAL

# --- --quiet records without printing; --notify still fires ----------------
rm -f "$SEEN_PATH" "$WATCH_OUT" "${NOTIFY_BIN}/calls.log"
export PATH="${NOTIFY_BIN}:${BASE_PATH}"
export NOTIFY=1
start_watch notifications --watch 1 --quiet --notify
wait_for_pattern 10 "$SEEN_PATH" '^43$'
wait_for_pattern 10 "${NOTIFY_BIN}/calls.log" 'spreed: bare watch'
stop_watch
export PATH="$BASE_PATH"
unset NOTIFY
expect_rc "watch: --quiet exits 130 on INT" "$WATCH_RC" 130
expect_eq "watch: --quiet prints nothing" "" "$(cat "$WATCH_OUT" 2>/dev/null || true)"
expect_contains "watch: --quiet still records the id" "$(cat "$SEEN_PATH")" "43"
expect_contains "watch: --notify sends the desktop notification" \
  "$(cat "${NOTIFY_BIN}/calls.log" 2>/dev/null || true)" "spreed: bare watch"

finish
