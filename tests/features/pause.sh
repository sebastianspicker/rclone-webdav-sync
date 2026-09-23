#!/usr/bin/env bash
# pause.sh - `pause --for`, indefinite pause, and the pause gate that makes
# check/sync skip until --force.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

PAUSE_MARKER="${STATE_DIR}/paused"

# --- usage -----------------------------------------------------------------
expect_cli "pause: --help rc 0" 0 run_cli pause --help
expect_contains "pause: --help usage" "$CLI_OUT" "Usage: sciebo pause"
expect_cli "pause: invalid duration rc 2" 2 run_cli pause --for 5x
expect_contains "pause: invalid duration message" "$CLI_OUT" "invalid duration"
expect_cli "pause: unknown option rc 2" 2 run_cli pause --bogus

# --- timed pause -----------------------------------------------------------
expect_no_file "pause: no marker before pausing" "$PAUSE_MARKER"
expect_cli "pause: --for 1h rc 0" 0 run_cli pause --for 1h
expect_contains "pause: reports the resume time" "$CLI_OUT" "paused until"
expect_file "pause: marker written" "$PAUSE_MARKER"
expect_contains "pause: marker records until=" "$(cat "$PAUSE_MARKER")" "until="
expect_not_contains "pause: timed marker is not indefinite" "$(cat "$PAUSE_MARKER")" "until=0"

# --- the pause gate --------------------------------------------------------
expect_cli "pause gate: check rc 0 while paused" 0 run_cli check
expect_contains "pause gate: check reports paused" "$CLI_OUT" "is paused"
expect_not_contains "pause gate: check does not run" "$CLI_OUT" "DRY RUN"

expect_cli "pause gate: sync rc 0 while paused" 0 run_cli sync
expect_contains "pause gate: sync reports paused" "$CLI_OUT" "is paused"
expect_not_contains "pause gate: sync does not run" "$CLI_OUT" "DRY RUN"

expect_cli "pause gate: check --force rc 0" 0 run_cli check --force
expect_contains "pause gate: --force bypasses the gate" "$CLI_OUT" "DRY RUN"

# --- indefinite pause ------------------------------------------------------
expect_cli "pause: indefinite rc 0" 0 run_cli pause
expect_contains "pause: indefinite message" "$CLI_OUT" "paused (indefinite)"
expect_eq "pause: indefinite marker" "until=0" "$(cat "$PAUSE_MARKER")"

# An expired marker is removed by the next run instead of blocking it.
printf 'until=%s\n' "$(($(date '+%s') - 10))" >"$PAUSE_MARKER"
expect_cli "pause: expired marker check rc 0" 0 run_cli check
expect_contains "pause: expired marker lets check run" "$CLI_OUT" "DRY RUN"
expect_no_file "pause: expired marker removed" "$PAUSE_MARKER"

finish
