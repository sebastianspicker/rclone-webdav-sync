#!/usr/bin/env bash
# duration.sh - epoch formatting and duration parsing (lib/duration.sh).
# Sourced setup lives in tests/unit/common.sh; run standalone with
# `bash tests/unit/duration.sh`.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# --- epoch_to_stamp_or_raw -----------------------------------------------
expect_eq "epoch_to_stamp_or_raw: empty passes through" "" "$(epoch_to_stamp_or_raw '')"
expect_eq "epoch_to_stamp_or_raw: non-numeric passes through" "abc" "$(epoch_to_stamp_or_raw abc)"
expect_eq "epoch_to_stamp_or_raw: negative passes through" "-5" "$(epoch_to_stamp_or_raw -5)"
expect_eq "epoch_to_stamp_or_raw: numeric delegates to epoch_to_stamp" \
  "$(epoch_to_stamp 1700000001)" "$(epoch_to_stamp_or_raw 1700000001)"
expect_eq "epoch_to_stamp_or_raw: FORMAT is passed through" \
  "$(epoch_to_stamp 1700000001 '%Y/%m/%d')" "$(epoch_to_stamp_or_raw 1700000001 '%Y/%m/%d')"

# epoch_to_stamp formats numeric epochs with the Bash builtin strftime (no
# fork) and must agree with `date`; the result is cached per epoch+format. A
# non-numeric or out-of-range value still passes through unchanged.
# epoch_ref uses whichever `date` spelling this platform supports.
epoch_ref() {
  date -d "@$1" "+$2" 2>/dev/null || date -r "$1" "+$2"
}
EPOCH_STAMP_CACHE=()
expect_eq "epoch_to_stamp: builtin matches date" \
  "$(epoch_ref 1700000001 '%Y-%m-%d %H:%M:%S')" "$(epoch_to_stamp 1700000001 '%Y-%m-%d %H:%M:%S')"
expect_eq "epoch_to_stamp: builtin honors the format" \
  "$(epoch_ref 1700000001 '%Y/%m/%d')" "$(epoch_to_stamp 1700000001 '%Y/%m/%d')"
# A direct call (not a command substitution) primes the parent-shell cache.
epoch_to_stamp 1700000001 '%Y/%m/%d' >/dev/null
expect_eq "epoch_to_stamp: caches the formatted value" \
  "$(epoch_ref 1700000001 '%Y/%m/%d')" "${EPOCH_STAMP_CACHE['1700000001|%Y/%m/%d']}"
expect_eq "epoch_to_stamp: non-numeric passes through" "abc" "$(epoch_to_stamp abc)"
expect_eq "epoch_to_stamp: out-of-range passes through" "99999999999999999999" \
  "$(epoch_to_stamp 99999999999999999999)"

expect_eq "percent_decode: decodes escapes" "a b/c" "$(percent_decode 'a%20b%2Fc')"
expect_eq "percent_decode: literal backslash kept" 'a\b' "$(percent_decode 'a\b')"
expect_eq "percent_decode: backslash escape not interpreted" 'a\c' "$(percent_decode 'a\c')"
expect_eq "percent_decode: malformed escape kept" 'a%2' "$(percent_decode 'a%2')"
expect_eq "percent_decode: plus stays literal" 'a+b' "$(percent_decode 'a+b')"
expect_eq "percent_decode: multi-byte utf-8" "grüße.txt" "$(percent_decode 'gr%C3%BC%C3%9Fe.txt')"
expect_eq "percent_decode: uppercase hex slash" "/" "$(percent_decode '%2F')"
expect_eq "percent_decode: lowercase hex slash" "/" "$(percent_decode '%2f')"
expect_eq "percent_decode: mixed-case hex" "+" "$(percent_decode '%2B')"
expect_eq "percent_decode: malformed trailing percent" "a%" "$(percent_decode 'a%')"
expect_eq "percent_decode: malformed non-hex kept" "%zz" "$(percent_decode '%zz')"
expect_eq "percent_decode: malformed then valid" "%2/a b" "$(percent_decode '%2/a%20b')"
expect_eq "percent_decode: literal backslash-n kept" 'a\nb' "$(percent_decode 'a\nb')"
split_positionals $'one\ntwo\n'
expect_eq "split_positionals: count" "2" "${#POSITIONAL_ARGS[@]}"
expect_eq "split_positionals: first" "one" "${POSITIONAL_ARGS[0]:-}"
expect_eq "split_positionals: second" "two" "${POSITIONAL_ARGS[1]:-}"
split_positionals ""
expect_eq "split_positionals: empty input" "0" "${#POSITIONAL_ARGS[@]}"
split_positionals $'a\n\nb\n'
expect_eq "split_positionals: empty field kept" "|b" "${POSITIONAL_ARGS[1]:-}|${POSITIONAL_ARGS[2]:-}"
while IFS='|' read -r name input want; do
  expect_eq "$name" "$want" "$(format_size_bytes "$input")"
done <<'EOF'
format_size_bytes: bytes|512|512B
format_size_bytes: kibibytes|1024|1.0KiB
format_size_bytes: mebibytes|3670016|3.5MiB
format_size_bytes: gibibytes|12884901888|12GiB
format_size_bytes: non-numeric passes through|n/a|n/a
format_size_bytes: empty passes through||
format_size_bytes: leading zero is decimal, not octal|01000|1000B
format_size_bytes: leading zero with 8/9 is decimal too|089|89B
EOF
while IFS='|' read -r name input want; do
  expect_eq "$name" "$want" "$(format_size_bytes "$input" rclone)"
done <<'EOF'
format_size_bytes rclone: exact mebibytes|104857600|100Mi
format_size_bytes rclone: exact kibibytes|2048|2Ki
format_size_bytes rclone: non-exact stays plain|1536|1536
format_size_bytes rclone: below one kibibyte is plain|512|512
format_size_bytes rclone: non-numeric passes through|n/a|n/a
EOF
while IFS='|' read -r name input want; do
  expect_eq "$name" "$want" "$(format_size_bytes "$input" bytes)"
done <<'EOF'
format_size_bytes bytes: unscaled with suffix|2048|2048B
format_size_bytes bytes: small stays B|512|512B
format_size_bytes bytes: non-numeric passes through|n/a|n/a
EOF
# capabilities_size_label is a delegation to the rclone style and must stay
# byte-identical to the original body for every sample the label checks use.
for size_label_sample in 0 1 512 1023 1024 1536 2048 5242880 104857600 \
  1073741824 1073741825 999999999999 n/a ""; do
  expect_eq "capabilities_size_label: rclone style for '${size_label_sample}'" \
    "$(format_size_bytes "$size_label_sample" rclone)" \
    "$(capabilities_size_label "$size_label_sample")"
done

# --- duration_parse_or_usage (pause's flagless grammar) ------------------
# pause_parse_duration was folded into duration_parse_or_usage: the parsed
# values are unchanged, but a bad value now exits 2 through usage_error.
# shellcheck disable=SC2329  # invoked indirectly through usage_error
usage_pause() { :; }
while IFS='|' read -r name input want rc_want; do
  rc=0
  out="$(duration_parse_or_usage pause "" "$input" invalid "90m, 24h, 1d" 2>/dev/null)" || rc=$?
  expect_rc "${name}: rc" "$rc" "$rc_want"
  [[ "$rc_want" -ne 0 ]] || expect_eq "$name" "$want" "$out"
done <<'EOF'
duration_parse_or_usage: bare number is minutes|5|300|0
duration_parse_or_usage: seconds suffix|30s|30|0
duration_parse_or_usage: minutes suffix|90m|5400|0
duration_parse_or_usage: hours suffix|2h|7200|0
duration_parse_or_usage: days suffix|1d|86400|0
duration_parse_or_usage: fractional hours rejected|1.5h||2
duration_parse_or_usage: unknown unit rejected|5x||2
duration_parse_or_usage: empty rejected|||2
EOF
rc=0
err="$(duration_parse_or_usage pause "" 5x invalid "90m, 24h, 1d" 2>&1)" || rc=$?
expect_rc "duration_parse_or_usage: pause bad value exits 2" "$rc" 2
expect_contains "duration_parse_or_usage: pause example list" "$err" \
  "invalid duration: 5x (use <N>[smhd], e.g. 90m, 24h, 1d)"

finish
