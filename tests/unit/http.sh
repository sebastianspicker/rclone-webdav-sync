#!/usr/bin/env bash
# http.sh - json_string_field (lib/base/xml.sh).
# Sourced setup lives in tests/unit/common.sh; run standalone with
# `bash tests/unit/http.sh`.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# --- json_string_field (compact JSON) -----------------------------------
json_body='{"id": "42", "path": "a\/b", "quote": "a\"b", "empty": "", "url": "http://x/y"}'
expect_eq "json_string_field: plain value" "42" "$(json_string_field "$json_body" id)"
expect_eq "json_string_field: escaped slash" "a/b" "$(json_string_field "$json_body" path)"
expect_eq "json_string_field: escaped quote" 'a"b' "$(json_string_field "$json_body" quote)"
expect_eq "json_string_field: empty value is found" "" "$(json_string_field "$json_body" empty)"
expect_eq "json_string_field: value with colon" "http://x/y" "$(json_string_field "$json_body" url)"
expect_eq "json_string_field: key suffix not matched" "" "$(json_string_field '{"fileid": "x"}' id)"
expect_eq "json_string_field: other escapes kept" 'a\tb' "$(json_string_field '{"k": "a\tb"}' k)"
json_multi='{
  "a": "1",
  "b": "two"
}'
expect_eq "json_string_field: key on a later line" "two" "$(json_string_field "$json_multi" b)"
json_string_field "$json_body" missing >/dev/null 2>&1
expect_rc "json_string_field: absent rc 1" "$?" 1
expect_eq "json_string_field: absent prints nothing" "" "$(json_string_field "$json_body" missing)"
expect_eq "json_string_field: empty body prints nothing" "" "$(json_string_field '' id)"

finish
