#!/usr/bin/env bash
# pause.sh - pause marker round trip (lib/state/pause.sh).
# Sourced setup lives in tests/unit/common.sh; run standalone with
# `bash tests/unit/pause.sh`.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# --- pause marker round trip ---------------------------------------------
PAUSE_FILE="${TMP}/pause-state/paused"
expect_ok "pause_set: future marker rc 0" pause_set "$(($(date +%s) + 3600))"
expect_file "pause_set: creates the marker" "$PAUSE_FILE"
expect_eq "pause_set: marker mode 600" "600" "$(file_mode "$PAUSE_FILE")"
expect_ok "pause_active: future marker is active" pause_active
expect_contains "pause_describe: future marker names the time" "$(pause_describe)" "paused until "
printf 'garbage\n' >"$PAUSE_FILE"
expect_err "pause_read: malformed marker rc 1" pause_read
printf 'until=abc\n' >"$PAUSE_FILE"
expect_err "pause_read: non-numeric epoch rc 1" pause_read
printf 'until=123\n' >"$PAUSE_FILE"
expect_ok "pause_read: valid marker rc 0" pause_read
expect_eq "pause_read: parses the epoch" "123" "$PAUSE_UNTIL"
printf 'until=1\n' >"$PAUSE_FILE"
expect_err "pause_active: expired marker is inactive" pause_active
expect_no_file "pause_active: expired marker is removed" "$PAUSE_FILE"
expect_eq "pause_describe: silent when not paused" "" "$(pause_describe)"
expect_ok "pause_clear: rc 0 when the marker is absent" pause_clear
expect_ok "pause_clear: idempotent second call rc 0" pause_clear
expect_ok "pause_set: indefinite marker rc 0" pause_set 0
expect_ok "pause_active: indefinite marker is active" pause_active
expect_eq "pause_describe: indefinite wording" "paused (indefinite)" "$(pause_describe)"
expect_ok "pause_clear: rc 0 when the marker exists" pause_clear
expect_no_file "pause_clear: removes the marker" "$PAUSE_FILE"
expect_err "pause_set: non-numeric epoch rejected" pause_set not-a-number

finish
