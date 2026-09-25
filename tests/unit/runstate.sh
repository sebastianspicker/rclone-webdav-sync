#!/usr/bin/env bash
# runstate.sh - runstate records and history (lib/runstate.sh).
# Sourced setup lives in tests/unit/common.sh; run standalone with
# `bash tests/unit/runstate.sh`.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# --- runstate records ----------------------------------------------------
RUNSTATE_DIR="${TMP}/runstate"
expect_ok "runstate_write: rc 0" runstate_write "manual-docs" sync ok 0 "${TMP}/x.log" 2 "detail text"
expect_file "runstate_write: creates the record" "${RUNSTATE_DIR}/manual-docs"
expect_eq "runstate_write: record mode 600" "600" "$(file_mode "${RUNSTATE_DIR}/manual-docs")"
expect_ok "runstate_read: rc 0" runstate_read "manual-docs"
expect_eq "runstate_read: status" "ok" "$RUNSTATE_STATUS"
expect_eq "runstate_read: mode" "sync" "$RUNSTATE_MODE"
expect_eq "runstate_read: rc" "0" "$RUNSTATE_RC"
expect_eq "runstate_read: conflicts" "2" "$RUNSTATE_CONFLICTS"
expect_eq "runstate_read: log" "${TMP}/x.log" "$RUNSTATE_LOG"
expect_eq "runstate_read: detail" "detail text" "$RUNSTATE_DETAIL"
expect_err "runstate_read: missing record rc 1" runstate_read "missing"

# shellcheck disable=SC2016  # the command substitution is literal test data
hostile_detail='$(touch '"${TMP}/runstate-pwned"')'
hostile_detail="${hostile_detail}"$'\n'"second line"
expect_ok "runstate_write: hostile detail rc 0" runstate_write "hostile" sync failed 1 "" 0 "$hostile_detail"
expect_no_file "runstate_write: hostile detail is never executed" "${TMP}/runstate-pwned"
expect_ok "runstate_read: hostile record rc 0" runstate_read "hostile"
# shellcheck disable=SC2016  # the expected value is literal test data
expect_eq "runstate_read: hostile detail is flattened" \
  '$(touch '"${TMP}/runstate-pwned"')second line' "$RUNSTATE_DETAIL"
expect_eq "runstate_read: hostile status" "failed" "$RUNSTATE_STATUS"

# --- runstate history display and trim -----------------------------------
HISTORY_DIR="${TMP}/history"
HISTORY_MAX_ENTRIES=50
runstate_history_append "hist-unit" 1700000001 ok "first"
runstate_history_append "hist-unit" 1700000002 failed "second"
out="$(runstate_history hist-unit)"
expect_contains "runstate_history: status uppercased" "$out" "OK  first"
expect_contains "runstate_history: failed uppercased" "$out" "FAILED  second"
expect_eq "runstate_history: newest record first" \
  "$(epoch_to_stamp_or_raw 1700000002)  FAILED  second" "$(printf '%s\n' "$out" | sed -n '1p')"
HISTORY_MAX_ENTRIES=2
runstate_history_append "trim-unit" 1700000001 ok "first"
runstate_history_append "trim-unit" 1700000002 ok "second"
runstate_history_append "trim-unit" 1700000003 ok "third"
trim_file="${HISTORY_DIR}/trim-unit.log"
expect_eq "runstate_history_append: trims to HISTORY_MAX_ENTRIES" "2" "$(grep -c '' "$trim_file")"
expect_not_contains "runstate_history_append: oldest record trimmed" "$(cat "$trim_file")" "first"
expect_contains "runstate_history_append: newest record kept" "$(cat "$trim_file")" "third"
HISTORY_MAX_ENTRIES=0
runstate_history_append "off-unit" 1700000001 ok "ignored"
expect_no_file "runstate_history_append: 0 disables the log" "${HISTORY_DIR}/off-unit.log"
unset HISTORY_DIR HISTORY_MAX_ENTRIES

finish
