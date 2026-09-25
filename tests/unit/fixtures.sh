#!/usr/bin/env bash
# fixtures.sh - golden-fixture tests for the awk-based Nextcloud response
# parsers (lib/http.sh, lib/capabilities.sh, lib/nc_api.sh and the command
# modules built on them). Unlike unit.sh's inline XML/JSON snippets, these
# read realistic captured-shape documents from tests/fixtures/nextcloud/ so
# a change to real Nextcloud's response shape (property order, namespace
# prefix, HTML-escaping, nested JSON) has a test that would notice.
# Run from any directory: bash tests/unit/fixtures.sh
set -uo pipefail
UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${UNIT_DIR}/../.." && pwd)"
LIB_DIR="${PROJ_DIR}/lib"
FIXTURES_DIR="${PROJ_DIR}/tests/fixtures/nextcloud"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../harness.sh
source "${UNIT_DIR}/../harness.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/core.sh
source "${LIB_DIR}/core.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/output.sh
source "${LIB_DIR}/output.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/rclone.sh
source "${LIB_DIR}/rclone.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/http.sh
source "${LIB_DIR}/http.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/keychain.sh
source "${LIB_DIR}/keychain.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/capabilities.sh
source "${LIB_DIR}/capabilities.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/settings.sh
source "${LIB_DIR}/settings.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/lock.sh
source "${LIB_DIR}/lock.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/manifest.sh
source "${LIB_DIR}/manifest.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/blacklist.sh
source "${LIB_DIR}/blacklist.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/ui.sh
source "${LIB_DIR}/ui.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/pause.sh
source "${LIB_DIR}/pause.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/runstate.sh
source "${LIB_DIR}/runstate.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/notify.sh
source "${LIB_DIR}/notify.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/nc_api.sh
source "${LIB_DIR}/nc_api.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/commands/trash.sh
source "${LIB_DIR}/commands/trash.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/commands/versions.sh
source "${LIB_DIR}/commands/versions.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/commands/share.sh
source "${LIB_DIR}/commands/share.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/commands/notifications.sh
source "${LIB_DIR}/commands/notifications.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/commands/file.sh
source "${LIB_DIR}/commands/file.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/commands/favorites.sh
source "${LIB_DIR}/commands/favorites.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/commands/comments.sh
source "${LIB_DIR}/commands/comments.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/commands/tags.sh
source "${LIB_DIR}/commands/tags.sh"

printf 'sciebo fixture tests (%s)\n' "$PROJ_DIR"

# fx NAME - print the contents of tests/fixtures/nextcloud/NAME.
fx() { cat "${FIXTURES_DIR}/$1"; }

# ---------------------------------------------------------------------------
# xml_records: trash_parse_xml over a real trashbin PROPFIND, captured from a
# live Nextcloud 29.0.11 container (redacted: host dropped, user "alice").
#
# Nextcloud names the trashbin properties nc:trashbin-filename /
# nc:trashbin-deletion-time (http://nextcloud.org/ns); ownCloud used
# oc:trashbin-original-filename / oc:trashbin-delete-timestamp.
# trash_parse_xml reads both (tests/unit/trash_versions_mount.sh covers the
# ownCloud vocabulary); this fixture pins the Nextcloud one.
trash_xml="$(fx propfind-trashbin.xml)"
want=$'\t\t\t\ttrash'
want="${want}"$'\nVerträge\tVerträge\t1700000600\t\tVerträge.d1700000600'
want="${want}"$'\n'"Q&A's notes.txt"$'\t'"Q&A's notes.txt"$'\t1700000500\t11\t'"Q&A's notes.txt.d1700000500"
expect_eq "trash_parse_xml: golden trashbin PROPFIND (Nextcloud nc: properties)" \
  "$want" "$(trash_parse_xml "$trash_xml")"

# ---------------------------------------------------------------------------
# xml_records: versions_parse_xml over a realistic versions PROPFIND
# ---------------------------------------------------------------------------
versions_xml="$(fx propfind-versions.xml)"
want=$'77\t\t'
want="${want}"$'\n1700000700\tWed, 01 Nov 2023 01:00:00 GMT\t4096'
want="${want}"$'\n1700000800\tWed, 01 Nov 2023 02:00:00 GMT\t8192'
expect_eq "versions_parse_xml: golden versions PROPFIND" "$want" "$(versions_parse_xml "$versions_xml")"

# ---------------------------------------------------------------------------
# xml_records: share_parse_xml over a realistic OCS shares listing (element
# wrapper, a link share and a user share, entity-escaped note/path)
# ---------------------------------------------------------------------------
shares_xml="$(fx shares.xml)"
want=$'17\t3\t\t1\t\t'"Q&A for the 'launch' review"$'\taBcDeFgHiJkLmNo\t/Verträge\thttps://cloud.example.test/s/aBcDeFgHiJkLmNo\talice'
want="${want}"$'\n18\t0\tbob\t19\t2024-01-01 00:00:00\t\t\t'"/Q&A's notes.txt"$'\t\talice'
expect_eq "share_parse_xml: golden OCS shares listing" "$want" "$(share_parse_xml "$shares_xml")"

# ---------------------------------------------------------------------------
# xml_records: file_parse_activity over a realistic OCS activity feed
# (HTML-tag entities and umlaut/ampersand in the subject/link)
# ---------------------------------------------------------------------------
activity_xml="$(fx activity.xml)"
want=$'2023-11-01T02:00:00+00:00\tfiles\t'"You edited <strong>Q&A's notes.txt</strong>"$'\thttps://cloud.example.test/apps/files/?dir=/&scrollto=notes.txt'
want="${want}"$'\n2023-11-01T02:05:00+00:00\tfiles_sharing\t'"You shared <strong>Verträge</strong> by link"$'\thttps://cloud.example.test/apps/files/?dir=/Verträge'
expect_eq "file_parse_activity: golden OCS activity feed" "$want" "$(file_parse_activity "$activity_xml")"

# ---------------------------------------------------------------------------
# xml_records_top: notifications_parse_xml over a realistic OCS notification
# list where the first <element> nests an <actions> block containing its own
# <element> children (Accept/Decline actions) - a naive non-depth-aware
# splitter would truncate the first record at the first nested </element>.
# ---------------------------------------------------------------------------
notifications_xml="$(fx notifications.xml)"
notifications_out="$(notifications_parse_xml "$notifications_xml")"
want=$'501\tfiles_sharing\tshare\t2023-11-01T02:00:00+00:00\t'"Alice shared \"Verträge\" with you"$'\t\thttps://cloud.example.test/apps/files/?dir=/Verträge'
want="${want}"$'\n502\tcomments\tcomment\t2023-11-01T03:00:00+00:00\tBob commented on notes.txt\tLooks good, thanks!\t'
expect_eq "notifications_parse_xml: golden OCS notifications (nested actions)" "$want" "$notifications_out"
expect_eq "notifications_parse_xml: exactly 2 top-level records, not more" \
  "2" "$(printf '%s\n' "$notifications_out" | grep -c .)"

# ---------------------------------------------------------------------------
# xml_wrapper_auto + xml_records: comments_parse_xml/tags_parse_xml over the
# DAV <d:response> wrapper shape (real Nextcloud comments/systemtags REPORT),
# and xml_wrapper_auto's "element" branch over the OCS shares document.
# ---------------------------------------------------------------------------
expect_eq "xml_wrapper_auto: OCS <element> document" "element" "$(xml_wrapper_auto "$shares_xml")"
comments_xml="$(fx comments.xml)"
expect_eq "xml_wrapper_auto: DAV <d:response> document" "d:response" "$(xml_wrapper_auto "$comments_xml")"

want=$'1\tBob\tLooks good, thanks!\tWed, 01 Nov 2023 03:00:00 GMT\tcomment'
want="${want}"$'\n2\t'"Alice & Bob"$'\t'"Re: Q&A's notes"$'\tWed, 01 Nov 2023 03:05:00 GMT\tcomment'
expect_eq "comments_parse_xml: golden DAV comments REPORT" "$want" "$(comments_parse_xml "$comments_xml")"

tags_xml="$(fx tags.xml)"
want=$'5\tImportant\ttrue\ttrue'
want="${want}"$'\n6\t'"Q&A"$'\ttrue\tfalse'
expect_eq "tags_parse_xml: golden systemtags REPORT" "$want" "$(tags_parse_xml "$tags_xml")"

# ---------------------------------------------------------------------------
# xml_records + href_last_segment/href_decode: a files listing with a
# percent-encoded umlaut folder and a percent-encoded "&"/"'"/space file name,
# oc:fileid/oc:permissions/nc:has-preview/d:getetag and the two size
# spellings (oc:size preferred over d:getcontentlength).
# ---------------------------------------------------------------------------
files_xml="$(fx propfind-files.xml)"
files_out="$(xml_records "$files_xml" 'd:response' \
  oc:fileid 'oc:size|d:getcontentlength' d:getlastmodified d:getetag \
  oc:permissions nc:has-preview d:href)"
want=$'42\t10485760\tWed, 01 Nov 2023 00:00:00 GMT\t"65123abc456def"\tRGDNVCK\tfalse\t/remote.php/dav/files/alice/'
want="${want}"$'\n43\t2048\tWed, 01 Nov 2023 01:00:00 GMT\t"65123abc456df1"\tRGDNVCK\tfalse\t/remote.php/dav/files/alice/Vertr%c3%a4ge/'
want="${want}"$'\n44\t512\tWed, 01 Nov 2023 02:00:00 GMT\t"65123abc456df2"\tRGDNVW\ttrue\t/remote.php/dav/files/alice/Q%26A%27s%20notes.txt'
expect_eq "xml_records: golden files PROPFIND (fileid/size/etag/permissions/has-preview/href)" "$want" "$files_out"

expect_eq "href_last_segment: percent-encoded umlaut folder" "Verträge" \
  "$(href_last_segment "/remote.php/dav/files/alice/Vertr%c3%a4ge/")"
expect_eq "href_last_segment: percent-encoded &, ' and space" "Q&A's notes.txt" \
  "$(href_last_segment "/remote.php/dav/files/alice/Q%26A%27s%20notes.txt")"
expect_eq "href_decode: whole path, not just the last segment" \
  "/remote.php/dav/files/alice/Verträge/" \
  "$(href_decode "/remote.php/dav/files/alice/Vertr%c3%a4ge/")"

# ---------------------------------------------------------------------------
# xml_fields: nc_file_info's single-document field set over a Depth:0
# PROPFIND response for one file (no wrapper, first match per tag).
# ---------------------------------------------------------------------------
file_info_xml="$(fx propfind-file-info.xml)"
fields="$(xml_fields "$file_info_xml" 'oc:fileid' 'oc:size|d:getcontentlength' \
  'd:getlastmodified' 'd:getetag' 'd:owner-id' 'oc:permissions' \
  'oc:favorite' 'oc:checksums' 'd:locktoken')"
# oc:checksums wraps an <oc:checksum> child; xml_fields/xml_get extract the
# text between the requested tag's own open/close tags verbatim (no nested
# element stripping), so the nested tag stays in the value - this is the
# real, current parser behavior, not a bug (nc_file_info only reports the
# wrapped text; nothing in the codebase asks for the inner oc:checksum).
want=$'44\t512\tWed, 01 Nov 2023 02:00:00 GMT\t"65123abc456df2"\talice\tRGDNVW\t1\t<oc:checksum>SHA1:abc123def456</oc:checksum>\t'
expect_eq "xml_fields: golden nc_file_info PROPFIND (Depth 0)" "$want" "$fields"

userinfo_xml="$(fx userinfo.xml)"
fields="$(xml_fields "$userinfo_xml" id displayname email)"
expect_eq "xml_fields: golden nc_user_info OCS response" $'alice\tAlice Anderson\talice@cloud.example.test' "$fields"

# ---------------------------------------------------------------------------
# xml_extract_ns fallback: a document that spells a property with a
# different-case prefix (<D:getetag>) or the default/no-prefix spelling
# (<fileid>) instead of the caller's exact "d:getetag"/"oc:fileid".
# ---------------------------------------------------------------------------
altns_xml="$(fx propfind-files-altns.xml)"
expect_eq "xml_get: namespace-tolerant fallback for <D:getetag>" '"legacy-etag-0001"' \
  "$(xml_get "$altns_xml" d:getetag)"
expect_eq "xml_get: namespace-tolerant fallback for unprefixed <fileid>" "77" \
  "$(xml_get "$altns_xml" oc:fileid)"
expect_eq "xml_get: exact spelling still wins when present" "256" \
  "$(xml_get "$altns_xml" oc:size)"

# ---------------------------------------------------------------------------
# Malformed/edge-case XML: truncated document, empty multistatus, entity and
# CDATA edge cases. The parsers only read and print; they must not hang,
# crash, or fabricate records.
# ---------------------------------------------------------------------------
truncated_xml="$(fx malformed-truncated.xml)"
truncated_out="$(xml_records "$truncated_xml" 'd:response' oc:fileid d:getetag)"
expect_eq "xml_records: truncated document yields only the complete record" \
  "1" "$(printf '%s\n' "$truncated_out" | grep -c .)"
expect_contains "xml_records: truncated document keeps the complete record's fields" \
  "$truncated_out" "complete-0001"

empty_xml="$(fx malformed-empty-multistatus.xml)"
expect_eq "xml_records: self-closed empty <d:multistatus/> yields no records" \
  "" "$(trash_parse_xml "$empty_xml")"

entities_xml="$(fx malformed-entities.xml)"
expect_eq "xml_get: decimal and hex numeric entities" "Decimal 'apostrophe' and hex & amp" \
  "$(xml_get "$entities_xml" oc:trashbin-original-filename)"
expect_eq "xml_get: double-escaped &amp;amp; decodes only one level" \
  'Double-escaped &amp; stays literal' "$(xml_get "$entities_xml" d:getetag)"
expect_eq "xml_get: CDATA markers are not stripped (plain-text parser, documented)" \
  '<![CDATA[literal CDATA block]]>' \
  "$(xml_get "$entities_xml" oc:trashbin-original-location)"

# ---------------------------------------------------------------------------
# json_string_field: the Nextcloud Login Flow v2 init/poll response shapes
# (nested "poll":{"token":...,"endpoint":...} and escaped "\/" separators).
# ---------------------------------------------------------------------------
login_init_json="$(fx login-v2-init.json)"
expect_eq "json_string_field: top-level login URL" \
  "https://cloud.example.test/login/v2/flow/tok_9f8e7d6c5b4a" \
  "$(json_string_field "$login_init_json" login)"
expect_eq "json_string_field: nested poll.token" "tok_9f8e7d6c5b4a" \
  "$(json_string_field "$login_init_json" token)"
expect_eq "json_string_field: nested poll.endpoint (escaped slashes decoded)" \
  "https://cloud.example.test/login/v2/poll" \
  "$(json_string_field "$login_init_json" endpoint)"

login_poll_json="$(fx login-v2-poll.json)"
expect_eq "json_string_field: resolved server URL" "https://cloud.example.test" \
  "$(json_string_field "$login_poll_json" server)"
expect_eq "json_string_field: resolved loginName" "alice" \
  "$(json_string_field "$login_poll_json" loginName)"
expect_eq "json_string_field: resolved appPassword" "aBc1-dEf2-gHi3-jKl4-mNo5" \
  "$(json_string_field "$login_poll_json" appPassword)"
rc=0
json_string_field "$login_poll_json" token >/dev/null || rc=$?
expect_rc "json_string_field: missing key returns rc 1 with no output" "$rc" 1

# ---------------------------------------------------------------------------
# capabilities: the JSON brace-matcher and capabilities_facts renderer over
# three golden OCS capabilities documents (modern Nextcloud, legacy
# ownCloud-style trashbin app, and adversarial braces/quotes inside strings).
# ---------------------------------------------------------------------------
capabilities_parse_json "$(fx capabilities.json)"
expect_eq "capabilities_parse_json: modern Nextcloud CAP_VERSION" "28.0.4" "$CAP_VERSION"
expect_eq "capabilities_parse_json: modern Nextcloud CAP_BIGFILE_CHUNKING" "true" "$CAP_BIGFILE_CHUNKING"
expect_eq "capabilities_parse_json: modern Nextcloud CAP_CHUNK_MAX_SIZE" "524288000" "$CAP_CHUNK_MAX_SIZE"
expect_eq "capabilities_parse_json: modern Nextcloud CAP_UNDELETE (files.undelete, no trashbin key)" "true" "$CAP_UNDELETE"
expect_eq "capabilities_parse_json: modern Nextcloud CAP_CHECKSUMS" "true" "$CAP_CHECKSUMS"
want=$'version\tpresent\t28.0.4'
want="${want}"$'\nbigfile\tenabled\t500Mi'
want="${want}"$'\ntrashbin\tavailable\t'
want="${want}"$'\nchecksums\tavailable\t'
expect_eq "capabilities_facts: modern Nextcloud table" "$want" "$(capabilities_facts)"

capabilities_parse_json "$(fx capabilities-legacy-trashbin.json)"
expect_eq "capabilities_parse_json: legacy CAP_VERSION (major.minor.micro, no string field)" "10.13.2" "$CAP_VERSION"
expect_eq "capabilities_parse_json: legacy CAP_BIGFILE_CHUNKING false" "false" "$CAP_BIGFILE_CHUNKING"
expect_eq "capabilities_parse_json: legacy CAP_CHUNK_MAX_SIZE absent" "" "$CAP_CHUNK_MAX_SIZE"
expect_eq "capabilities_parse_json: legacy CAP_UNDELETE via top-level \"trashbin\" app" "true" "$CAP_UNDELETE"
expect_eq "capabilities_parse_json: legacy CAP_CHECKSUMS" "true" "$CAP_CHECKSUMS"
want=$'version\tpresent\t10.13.2'
want="${want}"$'\nbigfile\tdisabled\t'
want="${want}"$'\ntrashbin\tavailable\t'
want="${want}"$'\nchecksums\tavailable\t'
expect_eq "capabilities_facts: legacy trashbin-app table" "$want" "$(capabilities_facts)"

capabilities_parse_json "$(fx capabilities-edgecases.json)"
expect_eq "capabilities_parse_json: braces/quotes inside the version object's own string do not break brace matching" \
  "29.1.0" "$CAP_VERSION"
expect_eq "capabilities_parse_json: braces/quotes inside chunked_upload's sibling string do not break brace matching" \
  "104857600" "$CAP_CHUNK_MAX_SIZE"
expect_eq "capabilities_parse_json: edgecases CAP_UNDELETE false" "false" "$CAP_UNDELETE"
expect_eq "capabilities_parse_json: edgecases CAP_CHECKSUMS true even for an empty {} section" "true" "$CAP_CHECKSUMS"
want=$'version\tpresent\t29.1.0'
want="${want}"$'\nbigfile\tenabled\t100Mi'
want="${want}"$'\ntrashbin\tunavailable\t'
want="${want}"$'\nchecksums\tavailable\t'
expect_eq "capabilities_facts: edgecases table" "$want" "$(capabilities_facts)"

finish
