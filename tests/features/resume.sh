#!/usr/bin/env bash
# resume.sh - `resume` clears the pause marker, reports the outcome, and
# stays quiet when nothing was paused.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

PAUSE_MARKER="${STATE_DIR}/paused"

# --- usage -----------------------------------------------------------------
expect_cli "resume: --help rc 0" 0 run_cli resume --help
expect_contains "resume: --help usage" "$CLI_OUT" "Usage: sciebo resume"
expect_cli "resume: positional argument rc 2" 2 run_cli resume extra

# --- idle resume -----------------------------------------------------------
expect_no_file "resume: no marker to start" "$PAUSE_MARKER"
expect_cli "resume: idle rc 0" 0 run_cli resume
expect_contains "resume: idle reports not paused" "$CLI_OUT" "not paused"
expect_no_file "resume: idle leaves no marker" "$PAUSE_MARKER"

# --- clearing an active pause ----------------------------------------------
expect_cli "resume: pause first rc 0" 0 run_cli pause --for 1h
expect_file "resume: pause marker written" "$PAUSE_MARKER"
expect_cli "resume: active rc 0" 0 run_cli resume
expect_contains "resume: active reports resumed" "$CLI_OUT" "resumed"
expect_no_file "resume: active marker removed" "$PAUSE_MARKER"

# A stale (expired) marker counts as not paused but is still cleaned up.
printf 'until=%s\n' "$(($(date '+%s') - 10))" >"$PAUSE_MARKER"
expect_cli "resume: expired marker rc 0" 0 run_cli resume
expect_contains "resume: expired marker reports not paused" "$CLI_OUT" "not paused"
expect_no_file "resume: expired marker removed" "$PAUSE_MARKER"

finish
