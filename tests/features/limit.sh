#!/usr/bin/env bash
# limit.sh - `limit`/`unlimited` and bw_effective_limit precedence.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"
# shellcheck source=../../lib/bw.sh
source "${PROJ}/lib/bw.sh"

MARKER="${STATE_DIR}/bwlimit"
export BW_LIMIT_FILE="$MARKER" BW_SCHEDULE="" BW_LIMIT_UP="" BW_LIMIT_DOWN=""

expect_cli "limit: set rc 0" 0 run_cli limit --up 2M --down 5M --until 90m
expect_contains "limit: set output" "$CLI_OUT" "limited: up=2M down=5M"
expect_file "limit: marker written" "$MARKER"
expect_eq "limit: effective value" "2M:5M" "$(bw_effective_limit)"

expect_cli "limit: show rc 0" 0 run_cli limit --show
expect_contains "limit: show output" "$CLI_OUT" "up=2M"

expect_cli "limit: json rc 0" 0 run_cli limit --show --json
expect_contains "limit: json active" "$CLI_OUT" '"active": true'
expect_contains "limit: json until" "$CLI_OUT" '"until_stamp"'

expect_cli "limit: no options rc 2" 2 run_cli limit
expect_cli "limit: bad duration rc 2" 2 run_cli limit --up 1M --until 5x
expect_cli "limit: show plus write rc 2" 2 run_cli limit --up 1M --show
expect_cli "limit: unknown option rc 2" 2 run_cli limit --bogus

expect_cli "unlimited rc 0" 0 run_cli unlimited
expect_contains "unlimited output" "$CLI_OUT" "unlimited"
expect_no_file "unlimited: marker removed" "$MARKER"
expect_eq "unlimited: effective empty" "" "$(bw_effective_limit)"

export BW_SCHEDULE="Mon-Fri 08:00,2M Mon-Fri 18:00,off"
expect_eq "schedule: precedence" "$BW_SCHEDULE" "$(bw_effective_limit)"

bw_marker_write "$(($(date '+%s') - 10))" 1M 1M
expect_eq "expired marker: falls through" "$BW_SCHEDULE" "$(bw_effective_limit)"
expect_no_file "expired marker: removed" "$MARKER"

export BW_SCHEDULE=""
export BW_LIMIT_UP="3M"
expect_eq "static cap: up only" "3M:off" "$(bw_effective_limit)"
export BW_LIMIT_UP="" BW_LIMIT_DOWN="7M"
expect_eq "static cap: down only" "off:7M" "$(bw_effective_limit)"

expect_cli "limit: clear rc 0" 0 run_cli limit --clear
expect_contains "limit: clear output" "$CLI_OUT" "unlimited"

# limit_emit formats the expiry with the forkless epoch_to_stamp shim, so a
# stubbed formatter's counter survives in this shell.
# shellcheck source=../../lib/commands/limit.sh
source "${PROJ}/lib/commands/limit.sh"
# shellcheck disable=SC2329  # stub keeps the emit on the text path
output_json_enabled() { return 1; }
fork_stamp_calls=0
# shellcheck disable=SC2329  # counted while limit_emit runs in this shell
epoch_to_stamp() {
  fork_stamp_calls=$((fork_stamp_calls + 1))
  printf 'STAMP'
}
limit_emit 2M 5M 1700000000 1 >"${TMP}/limit-emit.out"
expect_eq "limit: emit formats the stamp in this shell" "1" "$fork_stamp_calls"
expect_contains "limit: emit uses the formatted stamp" "$(cat "${TMP}/limit-emit.out")" "until=STAMP"

# --- marker rates are validated on read (bw_rate_valid) ---------------------
export BW_LIMIT_UP="" BW_LIMIT_DOWN="" BW_SCHEDULE=""

# Valid shapes keep flowing to --bwlimit; an empty side means off.
printf 'until=0\nup=\ndown=5M\n' >"$MARKER"
expect_eq "marker: empty rate means off" "off:5M" "$(bw_effective_limit)"
printf 'until=0\nup=0.5M\ndown=off\n' >"$MARKER"
expect_eq "marker: fraction and off accepted" "0.5M:off" "$(bw_effective_limit)"
printf 'until=0\nup=100k/second\ndown=2MiB\n' >"$MARKER"
expect_eq "marker: suffix and /second accepted" "100k/second:2MiB" "$(bw_effective_limit)"

# Invalid content is treated as absent: warn, drop the marker, emit nothing.
bw_warn="${TMP}/bw-marker.warn"
printf 'until=0\nup=2M; rm -rf ~\ndown=5M\n' >"$MARKER"
expect_eq "marker: invalid rate treated as absent" "" "$(bw_effective_limit 2>"$bw_warn")"
expect_contains "marker: invalid rate warns" "$(cat "$bw_warn")" "invalid rate"
expect_no_file "marker: invalid marker removed" "$MARKER"

printf 'until=0\nup=%s\ndown=5M\n' $'\e]0;owned' >"$MARKER"
expect_eq "marker: control byte treated as absent" "" "$(bw_effective_limit 2>"$bw_warn")"
expect_not_contains "marker: warning strips the control byte" "$(cat "$bw_warn")" $'\e'
expect_no_file "marker: control-byte marker removed" "$MARKER"

finish
