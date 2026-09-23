#!/usr/bin/env bash
# announcements.sh - announcementcenter listing through the shared HTTP layer
# (stub curl): newest-first ordering, HTML stripping, --limit, --json, and the
# graceful absent/empty app paths.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

stub_clear_calls
stub_reset_routes
stub_route GET '*apps/announcementcenter/api/v1/announcements*' 200 <<'XML'
<?xml version="1.0"?>
<ocs>
 <meta><status>ok</status><statuscode>200</statuscode><message>OK</message></meta>
 <data>
  <element>
   <id>3</id>
   <time>1700000300</time>
   <subject>Newest notice</subject>
   <message>Alice &lt;b&gt;bold&lt;/b&gt; text</message>
   <link>https://cloud.example.org/ann/3</link>
  </element>
  <element>
   <announcement_id>2</announcement_id>
   <timestamp>1700000200</timestamp>
   <subject>Middle notice</subject>
   <message>second</message>
   <link>https://cloud.example.org/ann/2</link>
  </element>
  <element>
   <id>1</id>
   <time>1700000100</time>
   <subject>Oldest notice</subject>
   <message>third</message>
   <link>https://cloud.example.org/ann/1</link>
  </element>
 </data>
</ocs>
XML

expect_cli "announcements: list rc 0" 0 run_cli_nc announcements
expect_contains "announcements: endpoint called" "$(stub_calls)" "apps/announcementcenter/api/v1/announcements"
expect_contains "announcements: newest subject" "$CLI_OUT" "Newest notice"
expect_contains "announcements: fallback id record" "$CLI_OUT" "Middle notice"
expect_contains "announcements: HTML stripped" "$CLI_OUT" "Alice bold text"
expect_not_contains "announcements: HTML tag gone" "$CLI_OUT" "<b>"
expect_contains "announcements: link shown" "$CLI_OUT" "https://cloud.example.org/ann/3"
before="${CLI_OUT%%Newest notice*}"
expect_not_contains "announcements: newest first" "$before" "Oldest notice"
middle="${CLI_OUT%%Middle notice*}"
expect_contains "announcements: middle after newest" "$middle" "Newest notice"

expect_cli "announcements: --limit rc 0" 0 run_cli_nc announcements --limit 1
expect_contains "announcements: limited newest kept" "$CLI_OUT" "Newest notice"
expect_not_contains "announcements: limited older hidden" "$CLI_OUT" "Oldest notice"

expect_cli "announcements: --no-dismiss accepted rc 0" 0 run_cli_nc announcements --no-dismiss
expect_contains "announcements: --no-dismiss still lists" "$CLI_OUT" "Newest notice"

expect_cli "announcements: --json rc 0" 0 run_cli_nc announcements --json
expect_contains "announcements: json available" "$CLI_OUT" '"available": true'
expect_contains "announcements: json id" "$CLI_OUT" '"id": "3"'
expect_contains "announcements: json numeric time" "$CLI_OUT" '"time": 1700000300'
expect_contains "announcements: json subject" "$CLI_OUT" '"subject": "Newest notice"'
expect_contains "announcements: json message" "$CLI_OUT" '"message": "Alice bold text"'
expect_contains "announcements: json link" "$CLI_OUT" '"link": "https://cloud.example.org/ann/3"'
expect_contains "announcements: json array" "$CLI_OUT" '"announcements": ['

# --- empty listing ----------------------------------------------------------
stub_reset_routes
stub_route GET '*apps/announcementcenter/api/v1/announcements*' 200 <<'XML'
<?xml version="1.0"?>
<ocs><meta><status>ok</status><statuscode>200</statuscode><message>OK</message></meta><data/></ocs>
XML
expect_cli "announcements: empty rc 0" 0 run_cli_nc announcements
expect_contains "announcements: empty message" "$CLI_OUT" "no announcements"

# --- absent app: HTTP 404 is graceful ---------------------------------------
stub_reset_routes
stub_route GET '*apps/announcementcenter/api/v1/announcements*' 404 <<'XML'
<?xml version="1.0"?>
<ocs><meta><status>failure</status><statuscode>404</statuscode><message>Not found</message></meta><data/></ocs>
XML
expect_cli "announcements: absent app rc 0" 0 run_cli_nc announcements
expect_contains "announcements: absent message" "$CLI_OUT" "announcements app not available"

# --- disabled app: an OCS failure is also graceful --------------------------
stub_reset_routes
stub_route GET '*apps/announcementcenter/api/v1/announcements*' 200 <<'XML'
<?xml version="1.0"?>
<ocs><meta><status>failure</status><statuscode>999</statuscode><message>Announcement app is disabled</message></meta><data/></ocs>
XML
expect_cli "announcements: disabled app rc 0" 0 run_cli_nc announcements
expect_contains "announcements: disabled message" "$CLI_OUT" "announcements app not available"
expect_cli "announcements: unavailable --json rc 0" 0 run_cli_nc announcements --json
expect_contains "announcements: json unavailable" "$CLI_OUT" '"available": false'

# --- usage failures ---------------------------------------------------------
expect_cli "announcements: bad limit rc 2" 2 run_cli_nc announcements --limit x
expect_contains "announcements: limit usage" "$CLI_OUT" "requires a positive integer"
expect_cli "announcements: unknown option rc 2" 2 run_cli_nc announcements --bogus
expect_contains "announcements: usage printed" "$CLI_OUT" "Usage: sciebo announcements"

finish
