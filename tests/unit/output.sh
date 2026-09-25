#!/usr/bin/env bash
# output.sh - JSON/bool/field printers (lib/output.sh).
# Sourced setup lives in tests/unit/common.sh; run standalone with
# `bash tests/unit/output.sh`.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# --- output_json_kv_bool -------------------------------------------------
# json_bool_probe NAME VALUE [NAME VALUE...] - emit one object with the given
# boolean fields, so the expected bytes stay readable.
json_bool_probe() {
  output_json_begin
  while [[ $# -ge 2 ]]; do
    output_json_kv_bool "$1" "$2"
    shift 2
  done
  output_json_end
}
output_mode_set true
expect_eq "output_json_kv_bool: 1 is true" \
  "$(printf '{\n  "flag": true\n}')" \
  "$(json_bool_probe flag 1)"
expect_eq "output_json_kv_bool: true is true" \
  "$(printf '{\n  "flag": true\n}')" \
  "$(json_bool_probe flag true)"
expect_eq "output_json_kv_bool: 0 is false" \
  "$(printf '{\n  "flag": false\n}')" \
  "$(json_bool_probe flag 0)"
expect_eq "output_json_kv_bool: anything else is false" \
  "$(printf '{\n  "flag": false\n}')" \
  "$(json_bool_probe flag yes)"
expect_eq "output_json_kv_bool: empty is false" \
  "$(printf '{\n  "flag": false\n}')" \
  "$(json_bool_probe flag "")"
expect_eq "output_json_kv_bool: separator between fields" \
  "$(printf '{\n  "a": true,\n  "b": false\n}')" \
  "$(json_bool_probe a 1 b 0)"
output_mode_set false
expect_eq "output_json_kv_bool: respects OUTPUT_JSON=false" "" \
  "$(json_bool_probe flag 1)"

# --- label_bool / print_field --------------------------------------------
expect_eq "label_bool: true is ON" "yes" "$(label_bool true yes no)"
expect_eq "label_bool: 1 is ON" "yes" "$(label_bool 1 yes no)"
expect_eq "label_bool: false is OFF" "no" "$(label_bool false yes no)"
expect_eq "label_bool: 0 is OFF" "no" "$(label_bool 0 yes no)"
expect_eq "label_bool: empty defaults to the OFF word" "no" "$(label_bool "" yes no)"
expect_eq "label_bool: unknown defaults to the OFF word" "no" "$(label_bool maybe yes no)"
expect_eq "label_bool: explicit UNKNOWN can be empty" "" \
  "$(label_bool "" available unavailable "")"
expect_eq "label_bool: explicit UNKNOWN word" "null" \
  "$(label_bool maybe true false null)"
expect_eq "label_bool: paired words for false" "unavailable" \
  "$(label_bool false available unavailable unavailable)"
expect_eq "print_field: value" "NAME: alice" "$(print_field NAME alice)"
expect_eq "print_field: empty shows a dash" "NAME: -" "$(print_field NAME "")"
expect_eq "print_field: missing value shows a dash" "NAME: -" "$(print_field NAME)"

expect_eq "duration_seconds: surrounding spaces" "300" "$(duration_seconds ' 5 ')"

finish
