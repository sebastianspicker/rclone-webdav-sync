#!/usr/bin/env bash
# favorites.sh - favorites listing (DAV REPORT) and toggling via PROPPATCH
# (stub curl).
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

FAVORITES_XML="${TMP}/favorites.xml"
cat >"$FAVORITES_XML" <<'XML'
<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
 <d:response>
  <d:href>/remote.php/dav/files/alice/backup/notes/plan.txt</d:href>
  <d:propstat><d:prop>
   <d:resourcetype/>
   <d:getcontentlength>1024</d:getcontentlength>
   <d:getlastmodified>Wed, 01 Nov 2023 01:00:00 GMT</d:getlastmodified>
   <oc:favorite>1</oc:favorite>
  </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
 </d:response>
 <d:response>
  <d:href>/remote.php/dav/files/alice/backup/photos/</d:href>
  <d:propstat><d:prop>
   <d:resourcetype><d:collection/></d:resourcetype>
   <d:getcontentlength>0</d:getcontentlength>
   <d:getlastmodified>Thu, 02 Nov 2023 02:00:00 GMT</d:getlastmodified>
  </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
 </d:response>
</d:multistatus>
XML

# --- listing: rows, path prefix stripped, size and modified shown ------------
stub_clear_calls
stub_reset_routes
stub_route_file REPORT '*/remote.php/dav/files/alice/' "$FAVORITES_XML" 200
expect_cli "favorites: list rc 0" 0 run_cli_nc favorites
expect_contains "favorites: file path" "$CLI_OUT" "backup/notes/plan.txt"
expect_contains "favorites: file size" "$CLI_OUT" "1024"
expect_contains "favorites: file modified" "$CLI_OUT" "Wed, 01 Nov 2023 01:00:00 GMT"
expect_contains "favorites: directory path" "$CLI_OUT" "backup/photos/"
expect_not_contains "favorites: DAV prefix stripped" "$CLI_OUT" "remote.php/dav/files"
expect_contains "favorites: REPORT url" "$(stub_calls)" "REPORT	http://127.0.0.1:9/remote.php/dav/files/alice/"
expect_contains "favorites: REPORT filter" "$(stub_data)" "<oc:favorite>1</oc:favorite>"

stub_clear_calls
expect_cli "favorites: explicit list rc 0" 0 run_cli_nc favorites list
expect_contains "favorites: explicit list row" "$CLI_OUT" "backup/notes/plan.txt"

expect_cli "favorites: --json rc 0" 0 run_cli_nc favorites list --json
expect_contains "favorites: json array" "$CLI_OUT" '"favorites": ['
expect_contains "favorites: json path" "$CLI_OUT" '"path": "backup/notes/plan.txt"'
expect_contains "favorites: json size" "$CLI_OUT" '"size": "1024"'

stub_reset_routes
stub_route REPORT '*/remote.php/dav/files/alice/' 200 <<'XML'
<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:"/>
XML
expect_cli "favorites: empty list rc 0" 0 run_cli_nc favorites
expect_contains "favorites: empty message" "$CLI_OUT" "no favorites"

# --- add / remove: PROPPATCH with the exact property value -------------------
stub_clear_calls
stub_reset_routes
stub_route PROPPATCH '*/remote.php/dav/files/alice/notes/plan.txt' 207 <<'XML'
<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:"/>
XML
expect_cli "favorites: add rc 0" 0 run_cli_nc favorites add notes/plan.txt
expect_contains "favorites: add confirms" "$CLI_OUT" "favorited notes/plan.txt"
expect_contains "favorites: add body" "$(stub_data)" "<oc:favorite>1</oc:favorite>"
expect_eq "favorites: one PROPPATCH for add" "1" "$(stub_count '^PROPPATCH')"

stub_clear_calls
expect_cli "favorites: remove rc 0" 0 run_cli_nc favorites remove notes/plan.txt
expect_contains "favorites: remove confirms" "$CLI_OUT" "unfavorited notes/plan.txt"
expect_contains "favorites: remove body" "$(stub_data)" "<oc:favorite>0</oc:favorite>"
expect_eq "favorites: one PROPPATCH for remove" "1" "$(stub_count '^PROPPATCH')"

# --- usage failures ----------------------------------------------------------
expect_cli "favorites: unknown subcommand rc 2" 2 run_cli_nc favorites bogus
expect_contains "favorites: unknown subcommand named" "$CLI_OUT" "unknown subcommand"
expect_cli "favorites: add without SUB rc 2" 2 run_cli_nc favorites add
expect_contains "favorites: add needs SUB" "$CLI_OUT" "requires a remote path"
expect_cli "favorites: add rejects --json rc 2" 2 run_cli_nc favorites add notes/plan.txt --json
expect_contains "favorites: add --json named" "$CLI_OUT" "does not accept --json"
expect_cli "favorites: unsafe path rc 1" 1 run_cli_nc favorites add ../evil
expect_contains "favorites: unsafe path named" "$CLI_OUT" "unsafe remote path"

finish
