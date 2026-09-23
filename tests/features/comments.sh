#!/usr/bin/env bash
# comments.sh - file comment listing, adding, and deleting through the DAV
# comments endpoint (stub curl).
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

# The delete confirmation must see a non-interactive stdin without killing
# the whole test run.
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_cli_nc_no_stdin() { run_cli_nc "$@" </dev/null; }

FILEID_XML="${TMP}/comments-fileid.xml"
cat >"$FILEID_XML" <<'XML'
<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
 <d:response>
  <d:href>/remote.php/dav/files/alice/notes/plan.txt</d:href>
  <d:propstat><d:prop><oc:fileid>42</oc:fileid></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
 </d:response>
</d:multistatus>
XML

COMMENTS_XML="${TMP}/comments-list.xml"
cat >"$COMMENTS_XML" <<'XML'
<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
 <element>
  <oc:id>5</oc:id>
  <oc:actorId>alice</oc:actorId>
  <oc:actorDisplayName>Alice</oc:actorDisplayName>
  <oc:message>first comment</oc:message>
  <oc:creationDateTime>2024-01-01T10:00:00+00:00</oc:creationDateTime>
  <oc:verb>comment</oc:verb>
 </element>
 <element>
  <oc:id>6</oc:id>
  <oc:actorId>bob</oc:actorId>
  <oc:actorDisplayName>Bob</oc:actorDisplayName>
  <oc:message>second comment</oc:message>
  <oc:creationDateTime>2024-01-02T11:00:00+00:00</oc:creationDateTime>
  <oc:verb>comment</oc:verb>
 </element>
</d:multistatus>
XML

comments_stub_routes() {
  stub_reset_routes
  stub_route_file PROPFIND '*/remote.php/dav/files/alice/notes/plan.txt' "$FILEID_XML" 200
  stub_route_file PROPFIND '*/remote.php/dav/comments/files/42' "$COMMENTS_XML" 200
}
comments_stub_routes

# --- listing: id, actor, message, and the Depth 1 comments PROPFIND ----------
stub_clear_calls
expect_cli "comments: list rc 0" 0 run_cli_nc comments notes/plan.txt
expect_contains "comments: first id" "$CLI_OUT" "5"
expect_contains "comments: first actor" "$CLI_OUT" "Alice"
expect_contains "comments: first message" "$CLI_OUT" "first comment"
expect_contains "comments: second message" "$CLI_OUT" "second comment"
expect_contains "comments: comments PROPFIND" "$(stub_calls)" "/remote.php/dav/comments/files/42"
expect_contains "comments: depth 1" "$(stub_args)" "Depth: 1"

stub_clear_calls
expect_cli "comments: explicit list rc 0" 0 run_cli_nc comments notes/plan.txt list
expect_contains "comments: explicit list row" "$CLI_OUT" "first comment"

expect_cli "comments: --json rc 0" 0 run_cli_nc comments notes/plan.txt --json
expect_contains "comments: json array" "$CLI_OUT" '"comments": ['
expect_contains "comments: json message" "$CLI_OUT" '"message": "first comment"'
expect_contains "comments: json verb" "$CLI_OUT" '"verb": "comment"'

stub_reset_routes
stub_route_file PROPFIND '*/remote.php/dav/files/alice/notes/plan.txt' "$FILEID_XML" 200
stub_route PROPFIND '*/remote.php/dav/comments/files/42' 200 <<'XML'
<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:"/>
XML
expect_cli "comments: empty list rc 0" 0 run_cli_nc comments notes/plan.txt
expect_contains "comments: empty message" "$CLI_OUT" "no comments"

# --- add: POST body carries the message, id comes from the response ----------
comments_stub_routes
stub_clear_calls
stub_route POST '*/remote.php/dav/comments/files/42' 201 <<'XML'
<?xml version="1.0"?>
<d:prop xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
 <oc:id>9</oc:id>
 <oc:message>hello world</oc:message>
</d:prop>
XML
expect_cli "comments: add rc 0" 0 run_cli_nc comments notes/plan.txt add "hello world"
expect_contains "comments: add confirms id" "$CLI_OUT" "added comment 9"
expect_contains "comments: add POST body" "$(stub_data)" "<oc:message>hello world</oc:message>"
expect_eq "comments: one POST" "1" "$(stub_count '^POST')"

# --- delete: --yes is required when stdin is not a terminal ------------------
comments_stub_routes
stub_clear_calls
expect_cli "comments: delete without --yes rc 2" 2 \
  run_cli_nc_no_stdin comments notes/plan.txt delete 5
expect_contains "comments: delete names --yes" "$CLI_OUT" "requires --yes"
expect_eq "comments: no DELETE without --yes" "0" "$(stub_count '^DELETE')"

stub_route DELETE '*/remote.php/dav/comments/files/42/5' 204 </dev/null
expect_cli "comments: delete --yes rc 0" 0 run_cli_nc comments notes/plan.txt delete 5 --yes
expect_contains "comments: delete confirms" "$CLI_OUT" "deleted comment 5"
expect_eq "comments: one DELETE" "1" "$(stub_count '^DELETE')"

# --- usage failures ----------------------------------------------------------
expect_cli "comments: missing SUB rc 2" 2 run_cli_nc comments
expect_contains "comments: SUB named" "$CLI_OUT" "a remote path argument is required"
expect_cli "comments: unknown subcommand rc 2" 2 run_cli_nc comments notes/plan.txt bogus
expect_contains "comments: unknown subcommand named" "$CLI_OUT" "unknown subcommand"
expect_cli "comments: delete invalid id rc 2" 2 \
  run_cli_nc comments notes/plan.txt delete abc --yes
expect_contains "comments: invalid id named" "$CLI_OUT" "invalid comment id"
expect_cli "comments: add without message rc 2" 2 run_cli_nc comments notes/plan.txt add
expect_contains "comments: add needs a message" "$CLI_OUT" "add requires a message"
expect_cli "comments: list rejects --yes rc 2" 2 run_cli_nc comments notes/plan.txt list --yes
expect_contains "comments: list --yes named" "$CLI_OUT" "does not accept --yes"
expect_cli "comments: unsafe path rc 1" 1 run_cli_nc comments ../evil
expect_contains "comments: unsafe path named" "$CLI_OUT" "unsafe remote path"

finish
