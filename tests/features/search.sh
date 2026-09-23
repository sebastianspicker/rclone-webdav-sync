#!/usr/bin/env bash
# search.sh - `sciebo search` against stub OCS routes: rows, HTML stripping,
# limits, JSON, the platform opener (including the off-origin refusal), and
# usage failures.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

stub_reset_routes
stub_clear_calls
stub_route GET '*search/providers/files/search*' 200 <<'XML'
<?xml version="1.0"?>
<ocs>
 <meta><status>ok</status><statuscode>200</statuscode><message>OK</message></meta>
 <data>
  <name>files</name>
  <entries>
   <element>
    <title>report.txt</title>
    <subline>/backup/report.txt</subline>
    <resourceUrl>http://127.0.0.1:9/remote.php/dav/files/alice/report.txt</resourceUrl>
   </element>
   <element>
    <title>&lt;em&gt;Notes&lt;/em&gt; &amp; plans</title>
    <subline>/backup/&lt;b&gt;notes&lt;/b&gt;</subline>
    <resourceUrl>http://127.0.0.1:9/remote.php/dav/files/alice/notes</resourceUrl>
   </element>
   <element>
    <title>Deep   &lt;span&gt;work&lt;/span&gt;   now</title>
    <subline>/backup/   spaced   name</subline>
    <resourceUrl>http://127.0.0.1:9/remote.php/dav/files/alice/deep</resourceUrl>
   </element>
  </entries>
 </data>
</ocs>
XML

expect_cli "search rc 0" 0 run_cli_nc search report
expect_contains "search row" "$CLI_OUT" $'report.txt\t/backup/report.txt\thttp://127.0.0.1:9/remote.php/dav/files/alice/report.txt'
expect_contains "search strips HTML and decodes entities" "$CLI_OUT" $'Notes & plans\t/backup/notes\thttp://127.0.0.1:9/remote.php/dav/files/alice/notes'
expect_contains "search folds whitespace around stripped tags" "$CLI_OUT" $'Deep work now\t/backup/ spaced name\thttp://127.0.0.1:9/remote.php/dav/files/alice/deep'
expect_contains "search sends the term" "$(stub_calls)" "term=report"
expect_contains "search default limit" "$(stub_calls)" "limit=20"

stub_clear_calls
expect_cli "search --limit rc 0" 0 run_cli_nc search report --limit 5
expect_contains "search custom limit" "$(stub_calls)" "limit=5"

stub_clear_calls
expect_cli "search --json rc 0" 0 run_cli_nc search report --json
expect_contains "search json array" "$CLI_OUT" '"results": ['
expect_contains "search json title" "$CLI_OUT" '"title": "report.txt"'
expect_contains "search json subline" "$CLI_OUT" '"subline": "/backup/report.txt"'
expect_contains "search json resourceUrl" "$CLI_OUT" '"resourceUrl": "http://127.0.0.1:9/remote.php/dav/files/alice/report.txt"'
expect_contains "search json strips HTML" "$CLI_OUT" '"title": "Notes & plans"'

# --- --open hands the first result to the platform opener --------------------
OPEN_LOG="${TMP}/search-open.log"
for opener in open xdg-open; do
  # The URL is the last argument ("--" separates it from any option-looking
  # value), so the stub records that one.
  cat >"${STUB_BIN}/${opener}" <<'STUB'
#!/bin/bash
last=""
for arg in "$@"; do last="$arg"; done
printf '%s\n' "$last" >>"${SEARCH_OPEN_LOG:-/dev/null}"
exit 0
STUB
  chmod +x "${STUB_BIN}/${opener}"
done
export SEARCH_OPEN_LOG="$OPEN_LOG"
rm -f "$OPEN_LOG"
expect_cli "search --open rc 0" 0 run_cli_nc search report --open
expect_file "search --open log exists" "$OPEN_LOG"
expect_eq "search --open opens the first result" \
  "http://127.0.0.1:9/remote.php/dav/files/alice/report.txt" "$(cat "$OPEN_LOG")"
unset SEARCH_OPEN_LOG

# --- --open refuses an off-origin URL ---------------------------------------
# The opener stubs stay in place; a result on another host must never reach
# them. The configured base is http://127.0.0.1:9 (the webtest remote).
stub_reset_routes
stub_route GET '*search/providers/files/search*' 200 <<'XML'
<?xml version="1.0"?>
<ocs>
 <meta><status>ok</status><statuscode>200</statuscode><message>OK</message></meta>
 <data>
  <name>files</name>
  <entries>
   <element>
    <title>report.txt</title>
    <subline>/backup/report.txt</subline>
    <resourceUrl>https://evil.example/phish</resourceUrl>
   </element>
  </entries>
 </data>
</ocs>
XML
export SEARCH_OPEN_LOG="$OPEN_LOG"
rm -f "$OPEN_LOG"
expect_cli "search --open off-origin rc 1" 1 run_cli_nc search report --open
expect_contains "search --open off-origin refuses" "$CLI_OUT" "refusing to open off-origin URL"
expect_contains "search --open off-origin names the expected origin" "$CLI_OUT" "http://127.0.0.1:9"
expect_no_file "search --open off-origin never invokes the opener" "$OPEN_LOG"
unset SEARCH_OPEN_LOG

# --- no matches --------------------------------------------------------------
stub_reset_routes
stub_clear_calls
stub_route GET '*search/providers/files/search*' 200 <<'XML'
<?xml version="1.0"?>
<ocs>
 <meta><status>ok</status><statuscode>200</statuscode><message>OK</message></meta>
 <data><name>files</name><entries/></data>
</ocs>
XML
expect_cli "search no matches rc 0" 0 run_cli_nc search nothing
expect_contains "search no matches message" "$CLI_OUT" "no matches"

# --- usage failures ----------------------------------------------------------
expect_cli "search missing TERM rc 2" 2 run_cli_nc search
expect_contains "search usage printed" "$CLI_OUT" "Usage: sciebo search"
expect_cli "search extra TERM rc 2" 2 run_cli_nc search one two
expect_contains "search single term message" "$CLI_OUT" "exactly one term"
expect_cli "search bad limit rc 2" 2 run_cli_nc search report --limit 0
expect_contains "search limit message" "$CLI_OUT" "positive integer"
expect_cli "search unknown option rc 2" 2 run_cli_nc search report --bogus
expect_contains "search unknown option usage" "$CLI_OUT" "Usage: sciebo search"
expect_cli "search --help rc 0" 0 run_cli_nc search --help
expect_contains "search help lists --open" "$CLI_OUT" "--open"

finish
