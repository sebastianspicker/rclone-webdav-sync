#!/usr/bin/env bash
# history.sh - per-source run history: runstate_history and status --history.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

# --- unit: runstate_history against the library directly ------------------
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/runstate.sh
source "${PROJ}/lib/runstate.sh"
# Plain assignments (not exports) keep the CLI runs below on the derived
# state/history path instead of this unit directory.
RUNSTATE_DIR="${TMP}/runstate-unit"
HISTORY_DIR="${TMP}/history-unit"
HISTORY_MAX_ENTRIES=50

runstate_write "unit-src" sync ok 0 "" 0 "one"
runstate_write "unit-src" sync failed 1 "" 0 "two"
runstate_write "unit-src" sync skipped 0 "" 0 "three"

out="$(runstate_history unit-src)"
expect_eq "history: no N prints every record" \
  "3" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
expect_contains "history: newest record first" \
  "$(printf '%s\n' "$out" | sed -n '1p')" "SKIPPED  three"
expect_contains "history: oldest record last" \
  "$(printf '%s\n' "$out" | sed -n '3p')" "OK  one"
expect_eq "history: date formatted YYYY-" \
  "$(date '+%Y-')" "$(printf '%s\n' "$out" | sed -n '1p' | cut -c1-5)"

out="$(runstate_history unit-src 2)"
expect_eq "history: N limits the record count" \
  "2" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
expect_contains "history: N keeps the newest" \
  "$(printf '%s\n' "$out" | sed -n '1p')" "three"
expect_not_contains "history: N drops the oldest" "$out" "one"

out="$(runstate_history unit-src not-a-number)"
expect_eq "history: non-numeric N falls back to 10" \
  "3" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"

out="$(runstate_history unit-never)"
missing_rc=$?
expect_eq "history: missing history prints nothing" "" "$out"
expect_rc "history: missing history rc 0" "$missing_rc" 0
: >"${HISTORY_DIR}/unit-empty.log"
expect_eq "history: empty history prints nothing" "" "$(runstate_history unit-empty)"

runstate_history_append "fold-src" 1700000000 ok $'a\tb\nc'
expect_contains "history: TABs and newlines fold to spaces" \
  "$(cat "${HISTORY_DIR}/fold-src.log")" "a b c"

HISTORY_MAX_ENTRIES=2
runstate_write "trim-src" sync ok 0 "" 0 "first"
runstate_write "trim-src" sync ok 0 "" 0 "second"
runstate_write "trim-src" sync ok 0 "" 0 "third"
trim_file="${HISTORY_DIR}/trim-src.log"
expect_file "history: trim log exists" "$trim_file"
expect_eq "history: trims to HISTORY_MAX_ENTRIES" \
  "2" "$(wc -l <"$trim_file" | tr -d ' ')"
expect_not_contains "history: oldest record trimmed" "$(cat "$trim_file")" "first"
expect_contains "history: newest record kept" "$(cat "$trim_file")" "third"
expect_not_contains "history: trimmed record not printed" \
  "$(runstate_history trim-src)" "first"

HISTORY_MAX_ENTRIES=0
runstate_write "off-src" sync ok 0 "" 0 "ignored"
expect_no_file "history: HISTORY_MAX_ENTRIES=0 writes nothing" \
  "${HISTORY_DIR}/off-src.log"
HISTORY_MAX_ENTRIES=50

# runstate_history formats each row through runstate_format_epoch_into; it must
# match the printing form (epoch_to_stamp_or_raw) and pass a non-numeric
# epoch through unchanged.
fmt_out=""
runstate_format_epoch_into fmt_out 1700000000
expect_eq "history: format_epoch_into matches the printing form" \
  "$(epoch_to_stamp_or_raw 1700000000)" "$fmt_out"
runstate_format_epoch_into fmt_out not-a-number
expect_eq "history: format_epoch_into passes non-numeric through" \
  "not-a-number" "$fmt_out"

# --- end to end: a real apply records history for status ------------------
HIST_SRC="${TMP}/history-src"
REMOTE_HIST="${TMP}/backup/history-src"
cat >"$MANIFEST_FILE" <<EOF
sync|${HIST_SRC}|hist-src
sync|${TMP}/history-never|hist-never
EOF
mkdir -p "$HIST_SRC"
printf 'payload\n' >"${HIST_SRC}/file.txt"
rm -rf "$REMOTE_HIST"

expect_cli "history e2e: first apply rc 0" 0 run_cli sync --apply --only hist-src
expect_cli "history e2e: second apply rc 0" 0 run_cli sync --apply --only hist-src
E2E_LOG="${STATE_DIR}/history/hist-src.log"
expect_file "history e2e: history log written" "$E2E_LOG"
expect_eq "history e2e: one record per run" "2" "$(wc -l <"$E2E_LOG" | tr -d ' ')"
expect_contains "history e2e: record says ok" "$(cat "$E2E_LOG")" "ok"

expect_cli "history e2e: status --history rc 0" 0 run_cli status --history
expect_contains "history e2e: source row shown" "$CLI_OUT" "hist-src"
expect_contains "history e2e: history lines shown" "$CLI_OUT" "    history: "
expect_eq "history e2e: status --history prints both records" \
  "2" "$(printf '%s\n' "$CLI_OUT" | grep -c '^    history: ' || true)"

expect_cli "history e2e: status --history 1 rc 0" 0 run_cli status --history 1
expect_eq "history e2e: --history 1 prints one record" \
  "1" "$(printf '%s\n' "$CLI_OUT" | grep -c '^    history: ' || true)"

expect_cli "history e2e: --history --only rc 0" 0 run_cli status --history --only hist-src
expect_contains "history e2e: --only keeps the row" "$CLI_OUT" "hist-src"
expect_contains "history e2e: --only keeps the history" "$CLI_OUT" "    history: "
expect_not_contains "history e2e: --only hides other sources" "$CLI_OUT" "hist-never"

expect_cli "history e2e: never-ran source rc 0" 0 run_cli status --history --only hist-never
expect_contains "history e2e: never-ran row shown" "$CLI_OUT" "hist-never"
expect_contains "history e2e: never-ran row state" "$CLI_OUT" "never"
expect_not_contains "history e2e: never-ran has no history" "$CLI_OUT" "history:"

expect_cli "history e2e: --quiet --history rc 0" 0 run_cli status --quiet --history
expect_eq "history e2e: --quiet --history prints nothing" "" "$CLI_OUT"

expect_cli "history e2e: malformed --history value rc 2" 2 run_cli status --history abc
expect_cli "history e2e: malformed --history= value rc 2" 2 run_cli status --history=abc
expect_cli "history e2e: --quiet without --history rc 0" 0 run_cli status --quiet --only hist-src
expect_contains "history e2e: quiet keeps the pause header" "$CLI_OUT" "not paused"
expect_contains "history e2e: quiet keeps the summary" "$CLI_OUT" "Summary:"
expect_not_contains "history e2e: quiet hides the OK row" "$CLI_OUT" "OK"

finish
