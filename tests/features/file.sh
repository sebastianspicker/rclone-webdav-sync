#!/usr/bin/env bash
# file.sh - `sciebo file info/activity/shares` against stub curl routes:
# WebDAV metadata rows and JSON, per-file activity with HTML stripping, and
# the `share list` passthrough.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

# --- info: metadata rows, empty fields, JSON ---------------------------------
stub_reset_routes
stub_clear_calls
stub_route PROPFIND '*remote.php/dav/files/alice/notes/plan.txt' 207 <<'XML'
<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
 <d:response>
  <d:href>/remote.php/dav/files/alice/notes/plan.txt</d:href>
  <d:propstat>
   <d:prop>
    <d:getcontentlength>2048</d:getcontentlength>
    <d:getlastmodified>Wed, 10 Sep 2025 10:00:00 GMT</d:getlastmodified>
    <d:getetag>"abc123"</d:getetag>
    <d:owner-id><d:href>alice</d:href></d:owner-id>
    <oc:fileid>42</oc:fileid>
    <oc:size>2048</oc:size>
    <oc:permissions>RGDNVW</oc:permissions>
    <oc:favorite>1</oc:favorite>
    <oc:checksums><oc:checksum>SHA1:da39a3ee5e6b4b0d3255bfef95601890afd80709</oc:checksum></oc:checksums>
    <d:locktoken><d:href>opaquelocktoken:abc</d:href></d:locktoken>
   </d:prop>
  </d:propstat>
 </d:response>
</d:multistatus>
XML

expect_cli "file info rc 0" 0 run_cli_nc file info notes/plan.txt
expect_contains "file info path" "$CLI_OUT" "PATH: notes/plan.txt"
expect_contains "file info type" "$CLI_OUT" "TYPE: file"
expect_contains "file info compact size" "$CLI_OUT" "SIZE: 2.0KiB"
expect_contains "file info modified" "$CLI_OUT" "MODIFIED: Wed, 10 Sep 2025 10:00:00 GMT"
expect_contains "file info etag" "$CLI_OUT" 'ETAG: "abc123"'
expect_contains "file info id" "$CLI_OUT" "ID: 42"
expect_contains "file info owner href" "$CLI_OUT" "OWNER: alice"
expect_contains "file info permissions" "$CLI_OUT" "PERMISSIONS: RGDNVW"
expect_contains "file info favorite" "$CLI_OUT" "FAVORITE: yes"
expect_contains "file info checksums" "$CLI_OUT" "CHECKSUMS: SHA1:da39a3ee5e6b4b0d3255bfef95601890afd80709"
expect_contains "file info lock href" "$CLI_OUT" "LOCK: opaquelocktoken:abc"
expect_contains "file info PROPFIND path" "$(stub_calls)" $'PROPFIND\thttp://127.0.0.1:9/remote.php/dav/files/alice/notes/plan.txt'

stub_clear_calls
expect_cli "file info --json rc 0" 0 run_cli_nc file info notes/plan.txt --json
expect_contains "file info json path" "$CLI_OUT" '"path": "notes/plan.txt"'
expect_contains "file info json type" "$CLI_OUT" '"type": "file"'
expect_contains "file info json size" "$CLI_OUT" '"size": 2048'
expect_contains "file info json modified" "$CLI_OUT" '"modified": "Wed, 10 Sep 2025 10:00:00 GMT"'
expect_contains "file info json etag" "$CLI_OUT" '"etag": "\"abc123\""'
expect_contains "file info json id" "$CLI_OUT" '"id": "42"'
expect_contains "file info json owner" "$CLI_OUT" '"owner": "alice"'
expect_contains "file info json permissions" "$CLI_OUT" '"permissions": "RGDNVW"'
expect_contains "file info json favorite" "$CLI_OUT" '"favorite": true'
expect_contains "file info json lock" "$CLI_OUT" '"lock": "opaquelocktoken:abc"'

stub_reset_routes
stub_route PROPFIND '*remote.php/dav/files/alice/photos' 207 <<'XML'
<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
 <d:response>
  <d:href>/remote.php/dav/files/alice/photos/</d:href>
  <d:propstat>
   <d:prop>
    <d:resourcetype><d:collection/></d:resourcetype>
    <d:getcontentlength>0</d:getcontentlength>
    <d:owner-id></d:owner-id>
    <oc:fileid>7</oc:fileid>
    <oc:size>4096</oc:size>
    <oc:permissions>RGDNVCK</oc:permissions>
    <oc:favorite>0</oc:favorite>
    <oc:checksums></oc:checksums>
    <d:locktoken></d:locktoken>
   </d:prop>
  </d:propstat>
 </d:response>
</d:multistatus>
XML
expect_cli "file info dir rc 0" 0 run_cli_nc file info photos
expect_contains "file info dir type" "$CLI_OUT" "TYPE: dir"
expect_contains "file info dir size" "$CLI_OUT" "SIZE: 4.0KiB"
expect_contains "file info empty owner" "$CLI_OUT" "OWNER: -"
expect_contains "file info empty checksums" "$CLI_OUT" "CHECKSUMS: -"
expect_contains "file info empty lock" "$CLI_OUT" "LOCK: -"
expect_contains "file info favorite off" "$CLI_OUT" "FAVORITE: no"

# --- activity: file id resolution, rows, HTML stripping, limits, JSON --------
stub_reset_routes
stub_clear_calls
stub_route PROPFIND '*remote.php/dav/files/alice/notes/plan.txt' 207 <<'XML'
<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
 <d:response>
  <d:href>/remote.php/dav/files/alice/notes/plan.txt</d:href>
  <d:propstat><d:prop><oc:fileid>42</oc:fileid></d:prop></d:propstat>
 </d:response>
</d:multistatus>
XML
stub_route GET '*apps/activity/api/v2/activity/filter*' 200 <<'XML'
<?xml version="1.0"?>
<ocs>
 <meta><status>ok</status><statuscode>200</statuscode><message>OK</message></meta>
 <data>
  <element>
   <activity_id>101</activity_id>
   <app>files</app>
   <type>file_created</type>
   <datetime>2025-09-10T10:00:00+00:00</datetime>
   <subject>You created &lt;strong&gt;plan.txt&lt;/strong&gt;</subject>
   <link>https://cloud.example.org/f/101</link>
  </element>
  <element>
   <activity_id>102</activity_id>
   <app>files_sharing</app>
   <type>shared_user_self</type>
   <datetime>2025-09-10T11:00:00+00:00</datetime>
   <subject>You shared &lt;a href="/f/1"&gt;plan.txt&lt;/a&gt; with bob</subject>
   <link>https://cloud.example.org/f/102</link>
  </element>
 </data>
</ocs>
XML

expect_cli "file activity rc 0" 0 run_cli_nc file activity notes/plan.txt
expect_contains "file activity row" "$CLI_OUT" $'2025-09-10T10:00:00+00:00\tfiles\tYou created plan.txt\thttps://cloud.example.org/f/101'
expect_contains "file activity strips HTML" "$CLI_OUT" $'2025-09-10T11:00:00+00:00\tfiles_sharing\tYou shared plan.txt with bob\thttps://cloud.example.org/f/102'
expect_contains "file activity resolves fileid" "$(stub_calls)" "fileid=42"
expect_contains "file activity default limit" "$(stub_calls)" "limit=50"

stub_clear_calls
expect_cli "file activity --limit rc 0" 0 run_cli_nc file activity notes/plan.txt --limit 1
expect_contains "file activity limit query" "$(stub_calls)" "limit=1"
expect_contains "file activity limit keeps first" "$CLI_OUT" "You created plan.txt"
expect_not_contains "file activity limit drops rest" "$CLI_OUT" "with bob"

stub_clear_calls
expect_cli "file activity --json rc 0" 0 run_cli_nc file activity notes/plan.txt --json
expect_contains "file activity json array" "$CLI_OUT" '"activity": ['
expect_contains "file activity json datetime" "$CLI_OUT" '"datetime": "2025-09-10T10:00:00+00:00"'
expect_contains "file activity json app" "$CLI_OUT" '"app": "files"'
expect_contains "file activity json subject" "$CLI_OUT" '"subject": "You created plan.txt"'
expect_contains "file activity json link" "$CLI_OUT" '"link": "https://cloud.example.org/f/101"'

# --- shares: thin passthrough to `share list SUB` ----------------------------
stub_reset_routes
stub_clear_calls
stub_route GET '*apps/files_sharing/api/v1/shares*' 200 <<'XML'
<?xml version="1.0"?>
<ocs>
 <meta><status>ok</status><statuscode>200</statuscode><message>OK</message></meta>
 <data>
  <element>
   <id>7</id><share_type>3</share_type><permissions>1</permissions>
   <token>Tok7</token><path>/backup/notes/plan.txt</path>
  </element>
 </data>
</ocs>
XML
expect_cli "file shares rc 0" 0 run_cli_nc file shares notes/plan.txt
expect_contains "file shares header" "$CLI_OUT" "Path-or-URL"
expect_contains "file shares link row" "$CLI_OUT" "http://127.0.0.1:9/s/Tok7"
expect_contains "file shares filters the path" "$(stub_calls)" "path=/backup/notes/plan.txt"

# --- shares --json: the passthrough forwards the flag ------------------------
stub_clear_calls
expect_cli "file shares --json rc 0" 0 run_cli_nc file shares notes/plan.txt --json
expect_contains "file shares json array" "$CLI_OUT" '"shares": ['
expect_contains "file shares json id" "$CLI_OUT" '"id": "7"'
expect_contains "file shares json type" "$CLI_OUT" '"type": "link"'
expect_contains "file shares json url" "$CLI_OUT" '"url": "http://127.0.0.1:9/s/Tok7"'
expect_not_contains "file shares json hides table" "$CLI_OUT" "Path-or-URL"

# --- shares: `--` keeps a dash-leading path positional -----------------------
stub_clear_calls
expect_cli "file shares -- forwards a dash path rc 0" 0 run_cli_nc file shares -- --json
expect_contains "file shares -- dash path stays a path" "$CLI_OUT" "Path-or-URL"
expect_not_contains "file shares -- dash path not a flag" "$CLI_OUT" '"shares": ['
expect_contains "file shares -- uses the shares endpoint" "$(stub_calls)" "apps/files_sharing/api/v1/shares"

# --- usage failures ----------------------------------------------------------
expect_cli "file info rejects --limit rc 2" 2 run_cli_nc file info notes/plan.txt --limit 2
expect_contains "file info --limit message" "$CLI_OUT" "info does not accept --limit"
expect_cli "file activity bad limit rc 2" 2 run_cli_nc file activity notes/plan.txt --limit x
expect_contains "file activity limit message" "$CLI_OUT" "positive integer"
expect_cli "file unknown subcommand rc 2" 2 run_cli_nc file bogus
expect_contains "file unknown subcommand named" "$CLI_OUT" "unknown subcommand"
expect_cli "file without subcommand rc 2" 2 run_cli_nc file
expect_contains "file needs a subcommand" "$CLI_OUT" "a subcommand is required"
expect_cli "file info without SUB rc 2" 2 run_cli_nc file info
expect_contains "file info needs SUB" "$CLI_OUT" "requires a remote path"
expect_cli "file info extra argument rc 2" 2 run_cli_nc file info one two
expect_contains "file info extra argument named" "$CLI_OUT" "unexpected argument"
expect_cli "file shares unsafe path rc 1" 1 run_cli_nc file shares ../escape
expect_contains "file shares unsafe path message" "$CLI_OUT" "unsafe remote path"
expect_cli "file --help rc 0" 0 run_cli_nc file --help
expect_contains "file help lists subcommands" "$CLI_OUT" "shares SUB"

finish
