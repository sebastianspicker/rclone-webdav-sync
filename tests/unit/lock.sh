#!/usr/bin/env bash
# lock.sh - acquire_lock and pid_alive (lib/lock.sh).
# Sourced setup lives in tests/unit/common.sh; run standalone with
# `bash tests/unit/lock.sh`.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# --- lock ---------------------------------------------------------------
export STATE_DIR="${TMP}/lock-state" LOG_DIR="${TMP}/lock-state/logs" \
  LOCK_DIR="${TMP}/lock-state/locks" BISYNC_DIR="${TMP}/lock-state/bisync"
rm -rf "${LOCK_DIR}/sync.lock"
expect_run "lock: fresh acquire rc 0" 0 acquire_lock
expect_file "lock: acquire creates pid file" "${LOCK_DIR}/sync.lock/pid"
expect_eq "lock: pid file records this shell" "$$" "$(cat "${LOCK_DIR}/sync.lock/pid")"
release_lock
expect_no_file "lock: release removes the lock dir" "${LOCK_DIR}/sync.lock"
acquire_lock
held="$LOCK_HELD"
expect_run "lock: reentrant acquire rc 0" 0 acquire_lock
expect_eq "lock: reentrant keeps the same lock" "$held" "$LOCK_HELD"
release_lock
mkdir -p "${LOCK_DIR}/sync.lock"
printf '999999\n' >"${LOCK_DIR}/sync.lock/pid"
stale_err="${TMP}/lock-stale.err"
rc=0
acquire_lock 2>"$stale_err" || rc=$?
expect_rc "lock: stale takeover rc 0" "$rc" 0
expect_contains "lock: stale takeover warns" "$(cat "$stale_err")" "Removing stale lock"
expect_eq "lock: stale takeover records this shell" "$$" "$(cat "${LOCK_DIR}/sync.lock/pid")"
release_lock
holder_start "${TMP}/bin/sciebo"
BG_PID="$HOLDER_PID"
holder_wait "$BG_PID" >/dev/null
expect_ok "lock: background holder looks like the tool" _lock_pid_alive "$BG_PID"
mkdir -p "${LOCK_DIR}/sync.lock"
printf '%s\n' "$BG_PID" >"${LOCK_DIR}/sync.lock/pid"
out="$(lock_probe)"
rc=$?
expect_rc "lock: live holder refuses acquire" "$rc" 1
expect_contains "lock: live refusal message" "$out" "Another sync run is active"
expect_eq "lock: live refusal leaves the foreign pid" "$BG_PID" "$(cat "${LOCK_DIR}/sync.lock/pid")"
kill "$BG_PID" 2>/dev/null || true
wait "$BG_PID" 2>/dev/null || true
BG_PID=""
rm -rf "${LOCK_DIR}/sync.lock"

# Start-time defense: a live pid whose recorded start time does not match
# is a recycled pid, so the lock is stale; a matching start keeps it live.
holder_start "${TMP}/bin/sciebo"
BG_PID="$HOLDER_PID"
expect_rc "lock: start-time holder matches the tool" "$(holder_wait "$BG_PID")" 1
mkdir -p "${LOCK_DIR}/sync.lock"
printf '%s\n' "$BG_PID" >"${LOCK_DIR}/sync.lock/pid"
printf 'wrong start time\n' >"${LOCK_DIR}/sync.lock/start"
out="$(lock_probe)"
rc=$?
expect_rc "lock: recycled pid is stale" "$rc" 0
expect_contains "lock: recycled pid takeover warns" "$out" "Removing stale lock"
rm -rf "${LOCK_DIR}/sync.lock"
mkdir -p "${LOCK_DIR}/sync.lock"
printf '%s\n' "$BG_PID" >"${LOCK_DIR}/sync.lock/pid"
ps -ww -p "$BG_PID" -o lstart= >"${LOCK_DIR}/sync.lock/start"
out="$(lock_probe)"
rc=$?
expect_rc "lock: matching start refuses acquire" "$rc" 1
expect_contains "lock: matching start refusal message" "$out" "Another sync run is active"
expect_eq "lock: matching start leaves the foreign pid" "$BG_PID" "$(cat "${LOCK_DIR}/sync.lock/pid")"
kill "$BG_PID" 2>/dev/null || true
wait "$BG_PID" 2>/dev/null || true
BG_PID=""
rm -rf "${LOCK_DIR}/sync.lock"

mkdir -p "${LOCK_DIR}/sync.lock"
printf '999998\n' >"${LOCK_DIR}/sync.lock/pid"
LOCK_HELD="${LOCK_DIR}/sync.lock"
out="$(release_lock 2>&1)"
rc=$?
expect_rc "lock: foreign release rc 0" "$rc" 0
expect_contains "lock: foreign release warns" "$out" "Not releasing lock"
expect_file "lock: foreign release keeps the lock" "${LOCK_DIR}/sync.lock/pid"
expect_eq "lock: foreign release keeps the pid" "999998" "$(cat "${LOCK_DIR}/sync.lock/pid")"
rm -rf "${LOCK_DIR}/sync.lock"

# --- pid_alive ------------------------------------------------------------
# The lstart comparison squeezes whitespace runs on both sides, so a raw
# `ps -o lstart=` line and a squeezed one describe the same start.
alive_start="$(ps -ww -p "$$" -o lstart= 2>/dev/null)"
expect_ok "pid_alive: this shell is alive without START" pid_alive "$$"
expect_ok "pid_alive: matching raw start accepted" pid_alive "$$" "$alive_start"
expect_ok "pid_alive: matching squeezed start accepted" pid_alive "$$" \
  "$(printf '%s' "$alive_start" | tr -s ' ')"
rc=0
pid_alive "$$" "Mon Jan  1 00:00:00 1990" || rc=$?
expect_rc "pid_alive: wrong start is not alive" "$rc" 1
rc=0
pid_alive "$$" "" || rc=$?
expect_rc "pid_alive: empty recorded start is not alive" "$rc" 1
rc=0
pid_alive 999999999 || rc=$?
expect_rc "pid_alive: missing pid is not alive" "$rc" 1
rc=0
pid_alive not-a-pid || rc=$?
expect_rc "pid_alive: non-numeric pid is not alive" "$rc" 1

finish
