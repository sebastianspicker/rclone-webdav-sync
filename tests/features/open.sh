#!/usr/bin/env bash
# open.sh - manifest/root resolution and the platform opener (all stubbed).
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"
# platform_open is exercised directly for the leading-dash argv check.
# shellcheck disable=SC1090,SC1091
source "${PROJ}/lib/platform.sh"

export FOLDERS_LOCAL_ROOT="${TMP}/folders"
BROWSER_BIN="${TMP}/browser-bin"
BROWSER_LOG="${BROWSER_BIN}/calls.log"
mkdir -p "$BROWSER_BIN" "$FOLDERS_LOCAL_ROOT"
cat >"${BROWSER_BIN}/open" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$(dirname "$0")/calls.log"
exit 0
STUB
cat >"${BROWSER_BIN}/xdg-open" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$(dirname "$0")/calls.log"
exit 0
STUB
chmod +x "${BROWSER_BIN}/open" "${BROWSER_BIN}/xdg-open"
export PATH="${BROWSER_BIN}:$PATH"

OPEN_EXISTING="${TMP}/existing-folder"
OPEN_MISSING="${TMP}/missing-folder"
mkdir -p "$OPEN_EXISTING"
cat >"$MANIFEST_FILE" <<EOF
sync|${OPEN_EXISTING}|backup/notes
pull|${OPEN_MISSING}|archive/old
EOF

expect_cli "open: --print resolves a remote subdir" 0 run_cli open --print backup/notes
expect_eq "open: manifest entry path printed" "$OPEN_EXISTING" "$CLI_OUT"
expect_eq "open: --print never opens a browser" "" "$(cat "$BROWSER_LOG" 2>/dev/null || true)"

expect_cli "open: --print resolves a local path" 0 run_cli open --print "$OPEN_EXISTING"
expect_eq "open: local path printed" "$OPEN_EXISTING" "$CLI_OUT"

expect_cli "open: missing entry dies" 1 run_cli open --print archive/old
expect_contains "open: sync hint for missing entry" "$CLI_OUT" "sciebo sync"

mkdir -p "${FOLDERS_LOCAL_ROOT}/pairs/one"
expect_cli "open: unknown SUB falls back to FOLDERS_LOCAL_ROOT" 0 run_cli open --print pairs/one
expect_eq "open: fallback path printed" "${FOLDERS_LOCAL_ROOT}/pairs/one" "$CLI_OUT"

expect_cli "open: missing fallback dies" 1 run_cli open --print nope
expect_contains "open: sync hint for fallback" "$CLI_OUT" "sciebo sync"

expect_cli "open: root when SUB is omitted" 0 run_cli open --print
expect_eq "open: root path printed" "$FOLDERS_LOCAL_ROOT" "$CLI_OUT"

: >"$BROWSER_LOG"
expect_cli "open: launches the opener" 0 run_cli open backup/notes
expect_contains "open: opener received the path" "$(cat "$BROWSER_LOG")" "$OPEN_EXISTING"

# platform_open must insert "--" so a path beginning with "-" cannot be read
# as an option by the opener. The stub logs "$*", so the separator's position
# is visible.
: >"$BROWSER_LOG"
platform_open "-dash-folder" >/dev/null 2>&1 || true
expect_contains "open: leading-dash path passed after --" "$(cat "$BROWSER_LOG")" "-- -dash-folder"

# --web: a remote file opens the direct /index.php/f/<fileid> link, while a
# directory (or an unresolved path) keeps the Files-app folder URL.
OPEN_FILEID_XML="${TMP}/open-fileid.xml"
cat >"$OPEN_FILEID_XML" <<'XML'
<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
  <d:response>
    <d:href>/remote.php/dav/files/alice/backup/notes/plan.txt</d:href>
    <d:propstat><d:prop><oc:fileid>42</oc:fileid></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
  </d:response>
</d:multistatus>
XML
stub_reset_routes
stub_route_file PROPFIND '*/remote.php/dav/files/alice/backup/notes/plan.txt' "$OPEN_FILEID_XML" 200

: >"$BROWSER_LOG"
expect_cli "open: --web file --print rc 0" 0 run_cli_nc open --web --print notes/plan.txt
expect_eq "open: --web file prints the /f/ link" \
  "http://127.0.0.1:9/index.php/f/42" "$CLI_OUT"
expect_eq "open: --web file --print launches nothing" "" "$(cat "$BROWSER_LOG" 2>/dev/null || true)"

: >"$BROWSER_LOG"
expect_cli "open: --web file launches the opener" 0 run_cli_nc open --web notes/plan.txt
expect_contains "open: --web file opener got the /f/ link" \
  "$(cat "$BROWSER_LOG")" "http://127.0.0.1:9/index.php/f/42"

# Without a matching response the folder URL is kept.
expect_cli "open: --web unresolved rc 0" 0 run_cli_nc open --web --print notes
expect_eq "open: --web unresolved folder url" \
  "http://127.0.0.1:9/index.php/apps/files/?dir=/backup/notes" "$CLI_OUT"

# A 3xx PROPFIND is not a successful file lookup (curl does not follow
# redirects for PROPFIND), so the folder URL is kept.
stub_reset_routes
stub_route_file PROPFIND '*/remote.php/dav/files/alice/backup/notes/redirect.txt' "$OPEN_FILEID_XML" 302
expect_cli "open: --web 3xx PROPFIND rc 0" 0 run_cli_nc open --web --print notes/redirect.txt
expect_eq "open: --web 3xx PROPFIND keeps the folder url" \
  "http://127.0.0.1:9/index.php/apps/files/?dir=/backup/notes/redirect.txt" "$CLI_OUT"

finish
