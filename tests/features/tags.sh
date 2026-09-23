#!/usr/bin/env bash
# tags.sh - system tag listing, creation, assignment, and clearing through
# the DAV systemtags endpoint (stub curl).
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

TAGS_XML="${TMP}/tags.xml"
cat >"$TAGS_XML" <<'XML'
<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
 <element>
  <oc:id>3</oc:id>
  <oc:display-name>Work</oc:display-name>
  <oc:user-visible>true</oc:user-visible>
  <oc:user-assignable>true</oc:user-assignable>
 </element>
 <element>
  <oc:id>4</oc:id>
  <oc:display-name>Private</oc:display-name>
  <oc:user-visible>false</oc:user-visible>
  <oc:user-assignable>false</oc:user-assignable>
 </element>
</d:multistatus>
XML

# --- listing: rows and --json ------------------------------------------------
stub_clear_calls
stub_reset_routes
stub_route_file PROPFIND '*/remote.php/dav/systemtags' "$TAGS_XML" 200
expect_cli "tags: list rc 0" 0 run_cli_nc tags list
expect_contains "tags: work id" "$CLI_OUT" "3"
expect_contains "tags: work name" "$CLI_OUT" "Work"
expect_contains "tags: private name" "$CLI_OUT" "Private"
expect_contains "tags: visible flag" "$CLI_OUT" "true"
expect_contains "tags: assignable flag" "$CLI_OUT" "false"
expect_contains "tags: systemtags PROPFIND" "$(stub_calls)" "/remote.php/dav/systemtags"

expect_cli "tags: default list rc 0" 0 run_cli_nc tags
expect_contains "tags: default list row" "$CLI_OUT" "Work"

expect_cli "tags: --json rc 0" 0 run_cli_nc tags list --json
expect_contains "tags: json array" "$CLI_OUT" '"tags": ['
expect_contains "tags: json name" "$CLI_OUT" '"display_name": "Work"'
expect_contains "tags: json visible" "$CLI_OUT" '"user_visible": "true"'

# A standard DAV <d:response> listing is parsed as well.
stub_reset_routes
stub_route PROPFIND '*/remote.php/dav/systemtags' 200 <<'XML'
<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
 <d:response>
  <d:href>/remote.php/dav/systemtags/9</d:href>
  <d:propstat><d:prop>
   <oc:id>9</oc:id>
   <oc:display-name>Archive</oc:display-name>
   <oc:user-visible>true</oc:user-visible>
   <oc:user-assignable>false</oc:user-assignable>
  </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
 </d:response>
</d:multistatus>
XML
expect_cli "tags: DAV response rc 0" 0 run_cli_nc tags list
expect_contains "tags: DAV response row" "$CLI_OUT" "Archive"

stub_reset_routes
stub_route PROPFIND '*/remote.php/dav/systemtags' 200 <<'XML'
<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:"/>
XML
expect_cli "tags: empty list rc 0" 0 run_cli_nc tags list
expect_contains "tags: empty message" "$CLI_OUT" "no tags"

# --- create: POST body and the response id -----------------------------------
stub_clear_calls
stub_reset_routes
stub_route POST '*/remote.php/dav/systemtags' 201 <<'XML'
<?xml version="1.0"?>
<oc:systemtag xmlns:oc="http://owncloud.org/ns">
 <oc:id>7</oc:id>
 <oc:display-name>Urgent</oc:display-name>
</oc:systemtag>
XML
expect_cli "tags: create rc 0" 0 run_cli_nc tags create Urgent
expect_contains "tags: create confirms" "$CLI_OUT" "created tag 7"
expect_contains "tags: create body name" "$(stub_data)" "<oc:display-name>Urgent</oc:display-name>"
expect_contains "tags: create body user-visible" "$(stub_data)" "<oc:user-visible>true</oc:user-visible>"

# --- assign / clear: the oc:tags property ------------------------------------
stub_clear_calls
stub_reset_routes
stub_route PROPPATCH '*/remote.php/dav/files/alice/notes/plan.txt' 207 <<'XML'
<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:"/>
XML
expect_cli "tags: assign rc 0" 0 run_cli_nc tags assign notes/plan.txt 3,4
expect_contains "tags: assign confirms" "$CLI_OUT" "tagged notes/plan.txt with 3,4"
expect_contains "tags: assign body" "$(stub_data)" "<oc:tags>3,4</oc:tags>"
expect_eq "tags: one PROPPATCH for assign" "1" "$(stub_count '^PROPPATCH')"

stub_clear_calls
expect_cli "tags: clear rc 0" 0 run_cli_nc tags clear notes/plan.txt
expect_contains "tags: clear confirms" "$CLI_OUT" "cleared tags for notes/plan.txt"
expect_contains "tags: clear body" "$(stub_data)" "<oc:tags></oc:tags>"
expect_eq "tags: one PROPPATCH for clear" "1" "$(stub_count '^PROPPATCH')"

# --- usage failures ----------------------------------------------------------
stub_clear_calls
expect_cli "tags: invalid ids rc 2" 2 run_cli_nc tags assign notes/plan.txt 3,x
expect_contains "tags: invalid ids named" "$CLI_OUT" "invalid tag ids"
expect_eq "tags: no PROPPATCH for invalid ids" "0" "$(stub_count '^PROPPATCH')"
expect_cli "tags: unknown subcommand rc 2" 2 run_cli_nc tags bogus
expect_contains "tags: unknown subcommand named" "$CLI_OUT" "unknown subcommand"
expect_cli "tags: create without name rc 2" 2 run_cli_nc tags create
expect_contains "tags: create needs a name" "$CLI_OUT" "create requires a tag name"
expect_cli "tags: assign without ids rc 2" 2 run_cli_nc tags assign notes/plan.txt
expect_contains "tags: assign needs ids" "$CLI_OUT" "requires one or more tag ids"
expect_cli "tags: unsafe path rc 1" 1 run_cli_nc tags clear ../evil
expect_contains "tags: unsafe path named" "$CLI_OUT" "unsafe remote path"

finish
