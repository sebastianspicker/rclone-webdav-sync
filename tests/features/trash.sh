#!/usr/bin/env bash
# trash.sh - trashbin listing through the shared HTTP layer (stub curl).
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

stub_clear_calls
stub_reset_routes
stub_route PROPFIND '*/remote.php/dav/trashbin/alice/trash' 200 <<'XML'
<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
  <d:response>
    <d:href>/remote.php/dav/trashbin/alice/trash/</d:href>
    <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/dav/trashbin/alice/trash/plan.txt.d1700000000</d:href>
    <d:propstat><d:prop>
      <oc:trashbin-original-filename>plan.txt</oc:trashbin-original-filename>
      <oc:trashbin-original-location>notes/plan.txt</oc:trashbin-original-location>
      <oc:trashbin-delete-timestamp>1700000000</oc:trashbin-delete-timestamp>
      <d:getcontentlength>2048</d:getcontentlength>
    </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
  </d:response>
</d:multistatus>
XML

expect_cli "trash: lists an entry" 0 run_cli_nc trash
expect_contains "trash: name shown" "$CLI_OUT" "plan.txt"
expect_contains "trash: location shown" "$CLI_OUT" "notes/plan.txt"
expect_contains "trash: compact size" "$CLI_OUT" "2.0KiB"
expect_eq "trash: one PROPFIND" "1" "$(stub_count 'trashbin')"

# A failing route surfaces the HTTP status and a non-zero exit.
stub_reset_routes
stub_route PROPFIND '*/remote.php/dav/trashbin/alice/trash' 503 <<'XML'
<?xml version="1.0"?><d:error/>
XML
expect_cli "trash: HTTP 503 is an error" 1 run_cli_nc trash
expect_contains "trash: 503 is named" "$CLI_OUT" "503"

# An empty multistatus is not an error.
stub_reset_routes
stub_route PROPFIND '*/remote.php/dav/trashbin/alice/trash' 200 <<'XML'
<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:"/>
XML
expect_cli "trash: empty bin rc 0" 0 run_cli_nc trash
expect_contains "trash: empty message" "$CLI_OUT" "no trashed files"

finish
