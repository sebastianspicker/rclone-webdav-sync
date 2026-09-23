#!/usr/bin/env bash
# cleanup_extra.sh - log rotation and fleeting-junk cleanup for `cleanup`.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

export LOG_MAX_BYTES=1K JUNK_CLEANUP_MIN_AGE=24h
LOG_DIR="${STATE_DIR}/logs"

# --- cleanup --logs: rotate '*.log' larger than LOG_MAX_BYTES ------------
mkdir -p "$LOG_DIR"
big_log="${LOG_DIR}/big.log"
head -c 2048 /dev/zero | tr '\0' 'x' >"$big_log"

expect_cli "cleanup logs: rotation dry run rc 0" 0 run_cli cleanup --logs
expect_contains "cleanup logs: rotation reported" "$CLI_OUT" "rotate: ${big_log}"
expect_file "cleanup logs: dry run keeps the oversized log" "$big_log"
expect_no_file "cleanup logs: dry run creates no .1" "${big_log}.1"

expect_cli "cleanup logs: rotation apply rc 0" 0 run_cli cleanup --logs --apply
expect_no_file "cleanup logs: apply renames the oversized log" "$big_log"
expect_file "cleanup logs: rotated file exists" "${big_log}.1"

printf 'replacement\n' >"$big_log"
head -c 2048 /dev/zero | tr '\0' 'y' >>"$big_log"
expect_cli "cleanup logs: second rotation rc 0" 0 run_cli cleanup --logs --apply
expect_file "cleanup logs: second rotation keeps .1" "${big_log}.1"
expect_contains "cleanup logs: second rotation replaces .1" "$(cat "${big_log}.1")" "replacement"
expect_no_file "cleanup logs: no double rotation" "${big_log}.1.1"

# An old oversized log is an age-based deletion candidate, not a rotation.
old_big="${LOG_DIR}/old-big.log"
head -c 2048 /dev/zero | tr '\0' 'z' >"$old_big"
touch -t 202001010000 "$old_big"
expect_cli "cleanup logs: old oversized dry run rc 0" 0 run_cli cleanup --logs
expect_contains "cleanup logs: old oversized is deleted, not rotated" "$CLI_OUT" "would delete ${old_big}"
expect_not_contains "cleanup logs: old oversized has no rotate line" "$CLI_OUT" "rotate: ${old_big}"
expect_cli "cleanup logs: old oversized apply rc 0" 0 run_cli cleanup --logs --apply
expect_no_file "cleanup logs: old oversized deleted" "$old_big"
expect_no_file "cleanup logs: old oversized not rotated" "${old_big}.1"

# An unparseable LOG_MAX_BYTES disables rotation.
export LOG_MAX_BYTES=not-a-size
printf 'fresh\n' >"$big_log"
head -c 2048 /dev/zero | tr '\0' 'w' >>"$big_log"
expect_cli "cleanup logs: unparseable setting rc 0" 0 run_cli cleanup --logs
expect_not_contains "cleanup logs: unparseable setting skips rotation" "$CLI_OUT" "rotate: ${big_log}"
expect_file "cleanup logs: unparseable setting keeps the log" "$big_log"
rm -f "$big_log"
export LOG_MAX_BYTES=1K

# --- cleanup --junk: only manifest local trees, only past the age gate ----
cp "${PROJ}/config/filters/fleeting.txt" "$FILTER_DIR/fleeting.txt"
JUNK_SRC="${TMP}/junk-src"
JUNK_OUTSIDE="${TMP}/junk-outside"
mkdir -p "$JUNK_SRC" "$JUNK_OUTSIDE"
printf 'sync|%s|junk-src\n' "$JUNK_SRC" >"$MANIFEST_FILE"
: >"${JUNK_SRC}/.DS_Store"
: >"${JUNK_SRC}/x.part"
: >"${JUNK_SRC}/y.part"
: >"${JUNK_OUTSIDE}/.DS_Store"
touch -t 202001010000 "${JUNK_SRC}/.DS_Store" "${JUNK_SRC}/x.part" "${JUNK_OUTSIDE}/.DS_Store"

expect_cli "cleanup junk: dry run rc 0" 0 run_cli cleanup --junk
expect_contains "cleanup junk: dry run lists .DS_Store" "$CLI_OUT" "${JUNK_SRC}/.DS_Store"
expect_contains "cleanup junk: dry run lists x.part" "$CLI_OUT" "${JUNK_SRC}/x.part"
expect_contains "cleanup junk: dry run summary" "$CLI_OUT" "junk: 2 candidate(s), 0 deleted"
expect_not_contains "cleanup junk: fresh y.part is age-gated" "$CLI_OUT" "y.part"
expect_file "cleanup junk: dry run deletes nothing" "${JUNK_SRC}/.DS_Store"
expect_file "cleanup junk: dry run keeps x.part" "${JUNK_SRC}/x.part"

expect_cli "cleanup junk: apply rc 0" 0 run_cli cleanup --junk --apply
expect_no_file "cleanup junk: apply removes .DS_Store" "${JUNK_SRC}/.DS_Store"
expect_no_file "cleanup junk: apply removes x.part" "${JUNK_SRC}/x.part"
expect_file "cleanup junk: apply keeps the fresh file" "${JUNK_SRC}/y.part"
expect_file "cleanup junk: outside the manifest tree untouched" "${JUNK_OUTSIDE}/.DS_Store"
expect_contains "cleanup junk: apply summary" "$CLI_OUT" "junk: 2 candidate(s), 2 deleted"

# Dry runs show the summary for all candidates but at most five examples.
for i in 1 2 3 4 5 6 7; do : >"${JUNK_SRC}/many-${i}.part"; done
touch -t 202001010000 "${JUNK_SRC}"/many-*.part
expect_cli "cleanup junk: example cap rc 0" 0 run_cli cleanup --junk
expect_eq "cleanup junk: exactly five examples" "5" "$(printf '%s\n' "$CLI_OUT" | grep -c "would delete ")"
expect_contains "cleanup junk: summary counts every candidate" "$CLI_OUT" "junk: 7 candidate(s), 0 deleted"

rm -f "$FILTER_DIR/fleeting.txt"
expect_cli "cleanup junk: missing fleeting file rc 0" 0 run_cli cleanup --junk
expect_contains "cleanup junk: missing fleeting file message" "$CLI_OUT" "no fleeting file (${FILTER_DIR}/fleeting.txt)"

# --- selectors and usage errors ------------------------------------------
expect_cli "cleanup: combined modes rc 0" 0 run_cli cleanup --logs --junk
expect_cli "cleanup: unknown option rc 2" 2 run_cli cleanup --bogus
expect_cli "cleanup: no mode rc 2" 2 run_cli cleanup

finish
