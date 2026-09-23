#!/usr/bin/env bash
# parallel.sh - MAX_PARALLEL_SOURCES (bounded source parallelism), whole
# per-entry output, and INT/TERM handling for `sciebo sync`.
#
# The stub rclone answers version/listremotes, sleeps ~0.3s for sync/bisync,
# and records start/end timestamps, its pid, and its --log-file argument, so
# the tests can tell serial execution from overlapping workers without any
# real transfer.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

STUB_BIN="${TMP}/parallel-bin"
STUB_EVENTS="${TMP}/parallel-events.tsv"
STUB_LOGS="${TMP}/parallel-logfiles.txt"
STUB_PID_FILE="${TMP}/parallel-stub.pid"
STUB_SIZE_LOG="${TMP}/parallel-sizes.txt"
mkdir -p "$STUB_BIN"
cat >"${STUB_BIN}/rclone" <<'STUB'
#!/usr/bin/env bash
mode=""
logfile=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    version)
      printf 'rclone v1.75.1\n'
      exit 0
      ;;
    listremotes)
      printf 'testremote:\n'
      exit 0
      ;;
    size)
      printf '%s\n' "$*" >>"${STUB_SIZE_LOG:-/dev/null}"
      printf '{"count":2,"bytes":5242880,"sizeless":0}\n'
      exit 0
      ;;
    sync | bisync) mode="$1" ;;
    --log-file) logfile="${2:-}"; shift ;;
    --log-file=*) logfile="${1#*=}" ;;
  esac
  shift
done
[[ -n "$mode" ]] || exit 0
printf 'start\t%s\t%s\n' "$$" "$EPOCHREALTIME" >>"${STUB_EVENTS:-/dev/null}"
printf '%s\n' "$logfile" >>"${STUB_LOGS:-/dev/null}"
printf '%s\n' "$$" >"${STUB_PID_FILE:-/dev/null}"
trap 'exit 143' TERM INT
sleep 0.3
printf 'end\t%s\t%s\n' "$$" "$EPOCHREALTIME" >>"${STUB_EVENTS:-/dev/null}"
exit 0
STUB
chmod +x "${STUB_BIN}/rclone"

# run_cli_stub - run the CLI with the sleeping stub as RCLONE_BIN.
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_cli_stub() {
  (cd "$TMP" && env PATH="${STUB_BIN}:$PATH" RCLONE_BIN="${STUB_BIN}/rclone" \
    STUB_EVENTS="$STUB_EVENTS" STUB_LOGS="$STUB_LOGS" STUB_PID_FILE="$STUB_PID_FILE" \
    STUB_SIZE_LOG="$STUB_SIZE_LOG" \
    bash "${PROJ}/bin/sciebo" "$@")
}

# stub_event FIELD N - the Nth event timestamp of FIELD (start|end) in file
# order; empty when there is no such event.
stub_event() {
  awk -F'\t' -v field="$1" -v n="$2" \
    '$1 == field { count++; if (count == n) { print $3; exit } }' "$STUB_EVENTS"
}

# stub_min_end - the earliest recorded end timestamp; empty when none.
stub_min_end() {
  awk -F'\t' '$1 == "end" && (min == "" || $3 < min) { min = $3 } END { print min }' "$STUB_EVENTS"
}

SRC_A="${TMP}/parallel-src-a"
SRC_B="${TMP}/parallel-src-b"
mkdir -p "$SRC_A" "$SRC_B"
cat >"$MANIFEST_FILE" <<EOF
sync|${SRC_A}|par-a
sync|${SRC_B}|par-b
EOF

# --- serial: the default runs the entries strictly one after the other ----
export MAX_PARALLEL_SOURCES=1
: >"$STUB_EVENTS"
: >"$STUB_LOGS"
rm -f "$STUB_PID_FILE"
expect_cli "parallel: serial run rc 0" 0 run_cli_stub sync --apply
expect_contains "parallel: serial output names the first entry" "$CLI_OUT" "par-a"
expect_contains "parallel: serial output names the second entry" "$CLI_OUT" "par-b"
expect_contains "parallel: serial summary counts both" "$CLI_OUT" "Summary: 2 sources (2 ok, 0 failed, 0 skipped)"
expect_file "parallel: serial runstate par-a written" "${STATE_DIR}/last/par-a"
expect_contains "parallel: serial runstate par-a ok" "$(cat "${STATE_DIR}/last/par-a" 2>/dev/null)" "status=ok"
expect_contains "parallel: serial runstate par-b ok" "$(cat "${STATE_DIR}/last/par-b" 2>/dev/null)" "status=ok"
expect_contains "parallel: serial rclone log argument recorded" "$(cat "$STUB_LOGS")" "${STATE_DIR}/logs/par-a-"

s1="$(stub_event start 1)"
e1="$(stub_event end 1)"
s2="$(stub_event start 2)"
if [[ -n "$s1" && -n "$e1" && -n "$s2" ]] && awk -v a="$s2" -v b="$e1" 'BEGIN { exit !(a >= b) }'; then
  pass "parallel: serial entries do not overlap"
else
  fail "parallel: serial entries do not overlap" "start1=${s1} end1=${e1} start2=${s2}"
fi

# --- parallel: MAX_PARALLEL_SOURCES=2 overlaps the same two entries -------
export MAX_PARALLEL_SOURCES=2
: >"$STUB_EVENTS"
: >"$STUB_LOGS"
rm -f "${STATE_DIR}/last/par-a" "${STATE_DIR}/last/par-b"
expect_cli "parallel: two workers rc 0" 0 run_cli_stub sync --apply
expect_contains "parallel: parallel output names the first entry" "$CLI_OUT" "par-a"
expect_contains "parallel: parallel output names the second entry" "$CLI_OUT" "par-b"
expect_contains "parallel: parallel summary counts both" "$CLI_OUT" "Summary: 2 sources (2 ok, 0 failed, 0 skipped)"
expect_file "parallel: runstate par-a written" "${STATE_DIR}/last/par-a"
expect_file "parallel: runstate par-b written" "${STATE_DIR}/last/par-b"
expect_contains "parallel: runstate par-a ok" "$(cat "${STATE_DIR}/last/par-a" 2>/dev/null)" "status=ok"
expect_contains "parallel: runstate par-b ok" "$(cat "${STATE_DIR}/last/par-b" 2>/dev/null)" "status=ok"
expect_eq "parallel: both rclone log arguments recorded" "2" "$(wc -l <"$STUB_LOGS" | tr -d ' ')"
expect_eq "parallel: one OK row per entry" "2" "$(printf '%s\n' "$CLI_OUT" | grep -c '^OK' || true)"
expect_eq "parallel: no worker temp files left" "" \
  "$(find "${STATE_DIR}" -maxdepth 1 -name '.sync-parallel.*' -print 2>/dev/null)"

# The overlap is read from sub-second timestamps and compared as
# floating-point values, so no scheduler jitter retry is needed.
s2="$(stub_event start 2)"
min_end="$(stub_min_end)"
if [[ -n "$s2" && -n "$min_end" ]] && awk -v a="$s2" -v b="$min_end" 'BEGIN { exit !(a < b) }'; then
  pass "parallel: second entry starts before the first ends"
else
  fail "parallel: second entry starts before the first ends" "start2=${s2} min_end=${min_end}"
fi

# --- MAX_PARALLEL_SOURCES=0 falls back to the serial path ------------------
export MAX_PARALLEL_SOURCES=0
: >"$STUB_EVENTS"
expect_cli "parallel: zero limit runs serially rc 0" 0 run_cli_stub sync --apply
s2="$(stub_event start 2)"
e1="$(stub_event end 1)"
if [[ -n "$s2" && -n "$e1" ]] && awk -v a="$s2" -v b="$e1" 'BEGIN { exit !(a >= b) }'; then
  pass "parallel: zero limit does not overlap"
else
  fail "parallel: zero limit does not overlap" "start2=${s2} end1=${e1}"
fi

# --- TERM: sciebo exits 143, kills the child, and releases the lock --------
export MAX_PARALLEL_SOURCES=1
: >"$STUB_EVENTS"
rm -f "$STUB_PID_FILE"
(
  cd "$TMP" || exit 1
  exec env PATH="${STUB_BIN}:$PATH" RCLONE_BIN="${STUB_BIN}/rclone" \
    STUB_EVENTS="$STUB_EVENTS" STUB_LOGS="$STUB_LOGS" STUB_PID_FILE="$STUB_PID_FILE" \
    bash "${PROJ}/bin/sciebo" sync --apply --only par-a
) >"${TMP}/parallel-signal.out" 2>&1 &
cli_pid=$!

stub_pid=""
if wait_for_file 10 "$STUB_PID_FILE"; then
  stub_pid="$(cat "$STUB_PID_FILE")"
fi
if [[ -n "$stub_pid" ]]; then
  pass "signal: stub started"
else
  fail "signal: stub started" "no pid marker after 10s"
fi

kill -TERM "$cli_pid" 2>/dev/null || true
rc=0
wait "$cli_pid" || rc=$?
expect_rc "signal: sciebo exits 143 after TERM" "$rc" 143
expect_no_file "signal: run lock released" "${STATE_DIR}/locks/sync.lock"

gone=0
wait_for_pid_gone 10 "${stub_pid:-}" && gone=1
expect_rc "signal: rclone stub is gone" "$gone" 1

# --- a worker that dies before reporting is counted as a failure -----------
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/commands/sync.sh
source "${PROJ}/lib/commands/sync.sh"
SYNC_TOTAL=0 SYNC_OK=0 SYNC_FAILED=0 SYNC_SKIPPED=0 SYNC_CONFLICTS=0 SYNC_FAILED_NAMES=""
missing_out="${TMP}/missing-worker.out"
missing_res="${TMP}/missing-worker.result"
rm -f "$missing_out" "$missing_res"
sync_parallel_collect "$missing_out" "$missing_res" par-x 2>"${TMP}/collect.err" || true
expect_contains "parallel collect: warns about the dead worker" \
  "$(cat "${TMP}/collect.err")" "exited before reporting"
expect_eq "parallel collect: counts the entry" "1" "$SYNC_TOTAL"
expect_eq "parallel collect: counts a failure" "1" "$SYNC_FAILED"
expect_eq "parallel collect: records no ok" "0" "$SYNC_OK"
expect_contains "parallel collect: failure name recorded" "$SYNC_FAILED_NAMES" "par-x"

# --- per-process remote-size cache and the parallel path -------------------
# Two pull entries resolve to the same remote spec. The serial path reuses the
# first `rclone size` result (B9); parallel workers each own their per-process
# cache, so they measure their own entry but both still skip correctly.
CACHE_DST_A="${TMP}/parallel-cache-a"
CACHE_DST_B="${TMP}/parallel-cache-b"
cat >"$MANIFEST_FILE" <<EOF
pull|${CACHE_DST_A}|cache-spec
pull|${CACHE_DST_B}|cache-spec
EOF
export MAX_DOWNLOAD_SIZE=1 ASK_DOWNLOAD_SIZE=0
: >"$STUB_SIZE_LOG"
export MAX_PARALLEL_SOURCES=1
expect_cli "size cache: serial run rc 0" 0 run_cli_stub sync --apply
expect_contains "size cache: serial skips both entries" "$CLI_OUT" "Summary: 2 sources (0 ok, 0 failed, 2 skipped)"
expect_eq "size cache: serial shares one rclone size call" "1" \
  "$(grep -c '^size --json' "$STUB_SIZE_LOG" 2>/dev/null || true)"
: >"$STUB_SIZE_LOG"
export MAX_PARALLEL_SOURCES=2
expect_cli "size cache: parallel run rc 0" 0 run_cli_stub sync --apply
expect_contains "size cache: parallel skips both entries" "$CLI_OUT" "Summary: 2 sources (0 ok, 0 failed, 2 skipped)"
expect_eq "size cache: parallel workers keep independent per-process caches" "2" \
  "$(grep -c '^size --json' "$STUB_SIZE_LOG" 2>/dev/null || true)"
expect_eq "size cache: no worker temp files left" "" \
  "$(find "${STATE_DIR}" -maxdepth 1 -name '.sync-parallel.*' -print 2>/dev/null)"
unset MAX_DOWNLOAD_SIZE ASK_DOWNLOAD_SIZE
export MAX_PARALLEL_SOURCES=1

# --- QUOTA_WARN_PERCENT: one quota probe per run ---------------------------
# A dedicated stub answers `about --json` with a configurable total/used and
# records every probe, so the warn threshold and the once-per-run caching can
# be checked without a real server.
QUOTA_STUB="${TMP}/quota-bin"
QUOTA_ABOUT_LOG="${TMP}/quota-about.log"
QUOTA_SRC_A="${TMP}/quota-src-a"
QUOTA_SRC_B="${TMP}/quota-src-b"
mkdir -p "$QUOTA_STUB" "$QUOTA_SRC_A" "$QUOTA_SRC_B"
cat >"${QUOTA_STUB}/rclone" <<'STUB'
#!/bin/bash
for arg in "$@"; do
  case "$arg" in
    version)
      printf 'rclone v1.75.1\n'
      exit 0
      ;;
    listremotes)
      printf 'testremote:\n'
      exit 0
      ;;
    about)
      printf 'about\n' >>"${QUOTA_ABOUT_LOG:-/dev/null}"
      printf '%s\n' "${QUOTA_ABOUT_JSON:-{\"total\":1000,\"used\":500}}"
      exit 0
      ;;
  esac
done
exit 0
STUB
chmod +x "${QUOTA_STUB}/rclone"

# run_cli_quota - run the CLI with the quota stub as RCLONE_BIN.
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_cli_quota() {
  (cd "$TMP" && env PATH="${QUOTA_STUB}:$PATH" RCLONE_BIN="${QUOTA_STUB}/rclone" \
    QUOTA_ABOUT_LOG="$QUOTA_ABOUT_LOG" QUOTA_ABOUT_JSON="${QUOTA_ABOUT_JSON:-}" \
    bash "${PROJ}/bin/sciebo" "$@")
}

cat >"$MANIFEST_FILE" <<EOF
sync|${QUOTA_SRC_A}|quota-a
sync|${QUOTA_SRC_B}|quota-b
EOF

# At the threshold the run warns once and still succeeds.
: >"$QUOTA_ABOUT_LOG"
export QUOTA_WARN_PERCENT=90 QUOTA_ABOUT_JSON='{"total":1000,"used":900}'
expect_cli "quota: at threshold rc 0" 0 run_cli_quota sync --dry-run
expect_contains "quota: at threshold warning printed" "$CLI_OUT" "quota guard: 90% of testremote: used"
expect_contains "quota: warning names the setting" "$CLI_OUT" "QUOTA_WARN_PERCENT=90"
expect_eq "quota: one probe for the whole run" "1" "$(wc -l <"$QUOTA_ABOUT_LOG" | tr -d ' ')"

# Below the threshold stays silent.
: >"$QUOTA_ABOUT_LOG"
export QUOTA_ABOUT_JSON='{"total":1000,"used":500}'
expect_cli "quota: below threshold rc 0" 0 run_cli_quota sync --dry-run
expect_not_contains "quota: below threshold is silent" "$CLI_OUT" "quota guard"

# A parallel run still probes once; the workers inherit the cached result.
: >"$QUOTA_ABOUT_LOG"
export QUOTA_ABOUT_JSON='{"total":1000,"used":950}' MAX_PARALLEL_SOURCES=2
expect_cli "quota: parallel run rc 0" 0 run_cli_quota sync --dry-run
expect_contains "quota: parallel run warns" "$CLI_OUT" "quota guard: 95% of testremote: used"
expect_eq "quota: parallel run probes once" "1" "$(wc -l <"$QUOTA_ABOUT_LOG" | tr -d ' ')"

# A probe error only warns and never fails the run.
: >"$QUOTA_ABOUT_LOG"
export QUOTA_ABOUT_JSON='not json' MAX_PARALLEL_SOURCES=1
expect_cli "quota: probe error rc 0" 0 run_cli_quota sync --dry-run
expect_contains "quota: probe error warned" "$CLI_OUT" "quota guard: cannot read the server quota"
expect_contains "quota: probe error still runs the entries" "$CLI_OUT" \
  "Summary: 2 sources (2 ok, 0 failed, 0 skipped)"
unset QUOTA_WARN_PERCENT QUOTA_ABOUT_JSON
export MAX_PARALLEL_SOURCES=1

finish
