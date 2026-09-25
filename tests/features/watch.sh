#!/usr/bin/env bash
# watch.sh - `sciebo watch --once`: marker-based detection, the spawned
# sync (stubbed rclone), and the single-watcher pid file guard.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

WATCH_STUB_BIN="${TMP}/watch-bin"
mkdir -p "$WATCH_STUB_BIN"
cat >"${WATCH_STUB_BIN}/rclone" <<'STUB'
#!/bin/bash
dir="$(cd "$(dirname "$0")" && pwd)"
printf '%s\n' "$*" >>"${dir}/calls.log"
log_file="" dry=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    version)
      printf 'rclone v1.99.0\n'
      exit 0
      ;;
    listremotes)
      printf 'testremote:\n'
      exit 0
      ;;
    --log-file)
      log_file="${2:-}"
      shift 2
      continue
      ;;
    --dry-run) dry=1 ;;
  esac
  shift
done
if [[ -n "$log_file" && "$dry" -eq 1 && "${WATCH_STUB_PLAN:-0}" == "1" ]]; then
  printf 'NOTICE: new-file.txt: Skipped copy as --dry-run is set\n' >>"$log_file"
fi
[[ "${WATCH_STUB_FAIL:-0}" != "1" ]] || exit 1
exit 0
STUB
chmod +x "${WATCH_STUB_BIN}/rclone"

export WATCH_BACKEND=poll WATCH_INTERVAL=1

# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_cli_watch() {
  (cd "$TMP" && env PATH="${WATCH_STUB_BIN}:$PATH" bash "${PROJ}/bin/sciebo" "$@")
}

src="${TMP}/watch-src"
mkdir -p "$src"
printf 'sync|%s|watchsrc\n' "$src" >"$MANIFEST_FILE"
pid_file="${TMP}/state/watch/watch.pid"

# First --once baselines the markers and syncs the source.
: >"${WATCH_STUB_BIN}/calls.log"
expect_cli "watch: once rc 0" 0 run_cli_watch watch --once --quiet
expect_no_file "watch: --once leaves no pid file" "$pid_file"

# A touched file is detected by the next cycle and spawns the sync. The poll
# check compares the marker's mtime against the tree, so backdate the marker
# instead of waiting for the wall clock: the touched file is then newer than
# the marker without any delay.
marker_file="${TMP}/state/watch/poll-$(sanitize_name watchsrc)"
touch -t 202001010000 "$marker_file"
touch "${src}/new-file.txt"
: >"${WATCH_STUB_BIN}/calls.log"
expect_cli "watch: once after a change rc 0" 0 run_cli_watch watch --once --quiet
expect_contains "watch: changed source syncs" "$(cat "${WATCH_STUB_BIN}/calls.log")" " sync "

# A stale pid record (dead pid) does not block and is replaced.
mkdir -p "$(dirname "$pid_file")"
printf '999999\nbogus start time\n' >"$pid_file"
expect_cli "watch: stale pid does not block" 0 run_cli_watch watch --once --quiet
expect_no_file "watch: stale pid removed" "$pid_file"

# --no-notify is accepted; --notify and --no-notify are mutually exclusive.
expect_cli "watch: --no-notify rc 0" 0 run_cli_watch watch --once --quiet --no-notify
expect_cli "watch: --notify with --no-notify rc 2" 2 run_cli_watch watch --once --notify --no-notify
expect_contains "watch: notify conflict message" "$CLI_OUT" "mutually exclusive"

# A live pid with a matching start time blocks a second watcher. Wait for ps
# to report the holder's start time before recording it: under load the
# process may not be visible immediately, and an empty start time would make
# the guard treat the record as stale.
sleep 30 &
live_pid=$!
# shellcheck disable=SC2329  # invoked through wait_until
live_start_ready() {
  [[ -n "$(ps -ww -p "$1" -o lstart= 2>/dev/null | tr -s ' ')" ]]
}
wait_until 5 live_start_ready "$live_pid"
live_start="$(ps -ww -p "$live_pid" -o lstart= | tr -s ' ')"
mkdir -p "$(dirname "$pid_file")"
printf '%s\n%s\n' "$live_pid" "$live_start" >"$pid_file"
expect_cli "watch: live watcher blocks" 1 run_cli_watch watch --once --quiet
expect_contains "watch: live watcher error" "$CLI_OUT" "already running"
kill "$live_pid" 2>/dev/null || true
wait "$live_pid" 2>/dev/null || true
rm -f "$pid_file"

# --- remote poll: marker means "changed", a failed check means failure -------
# watch_remote_poll is called directly (like the library probes in other
# feature suites) with a stub notify-send, so no desktop notification is
# shown. The stub rclone writes the dry-run plan marker when WATCH_STUB_PLAN=1
# and fails when WATCH_STUB_FAIL=1.
NOTIFY_BIN="${TMP}/watch-notify-bin"
mkdir -p "$NOTIFY_BIN"
cat >"${NOTIFY_BIN}/notify-send" <<'STUB'
#!/bin/bash
dir="$(cd "$(dirname "$0")" && pwd)"
for arg in "$@"; do printf '%s\n' "$arg"; done >>"${dir}/calls.log"
exit 0
STUB
chmod +x "${NOTIFY_BIN}/notify-send"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/commands/watch.sh
source "${PROJ}/lib/commands/watch.sh"

export WATCH_DIR="${TMP}/state/watch" LOG_DIR="${TMP}/state/logs"
mkdir -p "$WATCH_DIR" "$LOG_DIR"
export PATH="${WATCH_STUB_BIN}:${NOTIFY_BIN}:$PATH"
export NOTIFY=1 SCIEBO_NOTIFY_BACKEND=notify-send

rm -f "${NOTIFY_BIN}/calls.log"
WATCH_STUB_PLAN=1 capture watch_remote_poll
expect_rc "watch remote poll: marker dry run rc 0" "$CLI_RC" 0
expect_contains "watch remote poll: log marker means changed" \
  "$(cat "${NOTIFY_BIN}/calls.log" 2>/dev/null)" "remote differences detected"

rm -f "${NOTIFY_BIN}/calls.log"
WATCH_STUB_PLAN=0 WATCH_STUB_FAIL=1 capture watch_remote_poll
expect_rc "watch remote poll: failing dry run rc 0" "$CLI_RC" 0
expect_contains "watch remote poll: non-zero dry run means failure" \
  "$(cat "${NOTIFY_BIN}/calls.log" 2>/dev/null)" "remote check failed"

rm -f "${NOTIFY_BIN}/calls.log"
WATCH_RUN_NO_NOTIFY=true
WATCH_STUB_PLAN=0 WATCH_STUB_FAIL=1 capture watch_remote_poll
expect_rc "watch remote poll: --no-notify rc 0" "$CLI_RC" 0
expect_no_file "watch remote poll: --no-notify suppresses notifications" "${NOTIFY_BIN}/calls.log"
WATCH_RUN_NO_NOTIFY=false
unset WATCH_STUB_PLAN WATCH_STUB_FAIL NOTIFY SCIEBO_NOTIFY_BACKEND

finish
