#!/usr/bin/env bash
# status_json.sh - the status --json document and --watch guard.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/runstate.sh
source "${PROJ}/lib/runstate.sh"

# Two manifest sources; the run records live where the CLI derives them
# (STATE_DIR/last) so `status` reads the seeded state.
cat >"$MANIFEST_FILE" <<EOF
sync|${TMP}/src-a|repo-a
sync|${TMP}/src-b|repo-b
EOF
RUNSTATE_DIR="${STATE_DIR}/last"
HISTORY_DIR="${STATE_DIR}/history"
HISTORY_MAX_ENTRIES=50
runstate_write "repo-a" sync ok 0 "" 0 "all good"
runstate_write "repo-b" sync failed 3 "" 2 "boom"

# --- JSON rows --------------------------------------------------------------

expect_cli "status --json rc 0" 0 run_cli status --json
expect_contains "status --json: rows array" "$CLI_OUT" '"rows"'
expect_contains "status --json: first source" "$CLI_OUT" '"name": "repo-a"'
expect_contains "status --json: second source" "$CLI_OUT" '"name": "repo-b"'
expect_contains "status --json: not paused" "$CLI_OUT" '"paused": false'
expect_contains "status --json: empty pause_until" "$CLI_OUT" '"pause_until": ""'
expect_contains "status --json: failed status" "$CLI_OUT" '"status": "failed"'
expect_contains "status --json: exit code field" "$CLI_OUT" '"rc": "3"'
expect_contains "status --json: conflicts field" "$CLI_OUT" '"conflicts": "2"'
expect_contains "status --json: detail field" "$CLI_OUT" '"detail": "boom"'

expect_cli "status --json --only rc 0" 0 run_cli status --json --only repo-b
expect_contains "status --json --only keeps the row" "$CLI_OUT" '"name": "repo-b"'
expect_not_contains "status --json --only hides others" "$CLI_OUT" '"name": "repo-a"'

expect_cli "status --json --quiet rc 0" 0 run_cli status --json --quiet
expect_contains "status --json --quiet still prints the document" "$CLI_OUT" '"rows"'
expect_contains "status --json --quiet keeps failed rows" "$CLI_OUT" '"name": "repo-b"'
expect_not_contains "status --json --quiet hides ok rows" "$CLI_OUT" '"name": "repo-a"'

expect_cli "status --json unknown source rc 1" 1 run_cli status --json --only missing-src
expect_contains "status --json unknown source message" "$CLI_OUT" "no source named"

# --- watch ------------------------------------------------------------------

expect_cli "status --json --watch rc 2" 2 run_cli status --json --watch
expect_contains "status --json --watch message" "$CLI_OUT" "cannot be combined"
expect_cli "status --watch --json rc 2" 2 run_cli status --watch --json
expect_cli "status --watch abc rc 2" 2 run_cli status --watch abc

WATCH_OUT="${TMP}/status-watch.out"
WATCH_PID=""
WATCH_RC=0

# The watcher must never outlive the test: the EXIT trap kills a leaked pid
# (and chains env.sh's feature_cleanup, whose EXIT trap this replaces), so an
# abort or a missed signal cannot leave the background CLI running.
# shellcheck disable=SC2329  # invoked through the EXIT trap
watch_cleanup() {
  if [[ -n "$WATCH_PID" ]]; then
    kill -KILL "$WATCH_PID" 2>/dev/null || true
    wait "$WATCH_PID" 2>/dev/null || true
    WATCH_PID=""
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

# stop_watch SIGNAL - signal the watcher and leave its exit status in
# WATCH_RC. The reap is bounded: poll until the pid is gone, then SIGKILL and
# reap, so a watcher that ignores the signal cannot hang the suite.
# shellcheck disable=SC2329  # invoked indirectly
stop_watch() {
  local signal="$1" pid="$WATCH_PID"
  [[ -n "$pid" ]] || return 0
  kill -"$signal" "$pid" 2>/dev/null || true
  if ! wait_for_pid_gone 10 "$pid"; then
    kill -KILL "$pid" 2>/dev/null || true
    wait_for_pid_gone 5 "$pid" || true
  fi
  wait "$pid" 2>/dev/null
  WATCH_RC=$?
  WATCH_PID=""
}

start_watch status --watch 1
wait_for_pattern 10 "$WATCH_OUT" 'Summary:'
stop_watch INT
expect_rc "status --watch exits 130 on INT" "$WATCH_RC" 130
expect_contains "status --watch printed a snapshot" \
  "$(cat "$WATCH_OUT" 2>/dev/null || true)" "Summary:"

WATCH_OUT="${TMP}/status-watch.out.term"
start_watch status --watch 1
wait_for_pattern 10 "$WATCH_OUT" 'Summary:'
stop_watch TERM
expect_rc "status --watch exits 143 on TERM" "$WATCH_RC" 143

finish
