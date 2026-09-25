#!/usr/bin/env bash
# capture-fixtures.sh - capture golden Nextcloud response fixtures from a
# live server (started with nextcloud-up.sh) and write them, redacted, into
# tests/fixtures/nextcloud/captured-*.
#
# Redaction: NC_URL and every absolute URL derived from it is stripped down
# to relative paths (or, where a fixture must keep a full URL, rewritten to
# https://cloud.example.test); NC_USER is expected to be "alice" (nextcloud-up.sh's
# fixed test user) so no user substitution is normally needed. Nothing here
# writes NC_APPPASS to disk.
#
# Usage: eval "$(bash tests/contract/nextcloud-up.sh)" && bash tests/contract/capture-fixtures.sh
# Requires curl and the NC_URL/NC_USER/NC_APPPASS env vars nextcloud-up.sh prints.
set -uo pipefail

CONTRACT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES_DIR="$(cd "${CONTRACT_DIR}/../fixtures/nextcloud" && pwd)"

log() { printf 'capture-fixtures: %s\n' "$1" >&2; }
die() {
  printf 'capture-fixtures: %s\n' "$1" >&2
  exit 1
}

[[ -n "${NC_URL:-}" && -n "${NC_USER:-}" && -n "${NC_APPPASS:-}" ]] ||
  die "NC_URL/NC_USER/NC_APPPASS must be set (eval nextcloud-up.sh's output first)"
command -v curl >/dev/null 2>&1 || die "curl is not installed"

# redact TEXT - strip every form the live NC_URL can appear in (plain,
# JSON-escaped "\/", and the bare "127.0.0.1:<port>" host:port with no
# scheme) out of TEXT, replacing each with a fixed, obviously-fake
# placeholder. NC_HOSTPORT is NC_URL with its "http://" prefix removed.
redact() {
  local text="$1" hostport="${NC_URL#http://}"
  hostport="${hostport#https://}"
  text="${text//${NC_URL}/https:\/\/cloud.example.test}"
  text="${text//${NC_URL//\//\\/}/https:\/\/cloud.example.test}"
  text="${text//${hostport}/cloud.example.test}"
  printf '%s' "$text"
}

auth_curl() {
  curl -fsS -u "${NC_USER}:${NC_APPPASS}" "$@"
}

# --- capabilities (OCS JSON) -------------------------------------------------
log "capturing capabilities"
caps="$(auth_curl -H 'OCS-APIRequest: true' -H 'Accept: application/json' \
  "${NC_URL}/ocs/v2.php/cloud/capabilities?format=json")" || die "capabilities request failed"
redact "$caps" >"${FIXTURES_DIR}/captured-capabilities.json"
printf '\n' >>"${FIXTURES_DIR}/captured-capabilities.json"

# --- user info (OCS XML) -----------------------------------------------------
log "capturing user info"
userinfo="$(auth_curl -H 'OCS-APIRequest: true' "${NC_URL}/ocs/v2.php/cloud/user")" ||
  die "user info request failed"
redact "$userinfo" >"${FIXTURES_DIR}/captured-userinfo.xml"

# --- a small tree with special characters, then a files PROPFIND ------------
log "seeding a folder/file with special characters"
auth_curl -X MKCOL "${NC_URL}/remote.php/dav/files/${NC_USER}/Vertr%c3%a4ge" >/dev/null || true
auth_curl -X PUT --data-binary 'hello world' \
  "${NC_URL}/remote.php/dav/files/${NC_USER}/Q%26A%27s%20notes.txt" >/dev/null ||
  die "seed PUT failed"

propfind_files_body='<?xml version="1.0"?>
<d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
  <d:prop>
    <d:resourcetype/>
    <d:getcontentlength/>
    <d:getlastmodified/>
    <d:getetag/>
    <d:owner-id/>
    <d:locktoken/>
    <oc:fileid/>
    <oc:size/>
    <oc:permissions/>
    <oc:favorite/>
    <oc:checksums/>
  </d:prop>
</d:propfind>'
log "capturing a files PROPFIND (Depth 1)"
files_xml="$(auth_curl -X PROPFIND -H 'Depth: 1' -H 'Content-Type: text/xml' \
  --data-binary "$propfind_files_body" \
  "${NC_URL}/remote.php/dav/files/${NC_USER}/")" || die "files PROPFIND failed"
redact "$files_xml" >"${FIXTURES_DIR}/captured-propfind-files.xml"

# --- trashbin PROPFIND (nc: namespace - see the contract report) ------------
log "deleting the seeded file/folder to populate the trashbin"
auth_curl -X DELETE "${NC_URL}/remote.php/dav/files/${NC_USER}/Q%26A%27s%20notes.txt" >/dev/null
auth_curl -X DELETE "${NC_URL}/remote.php/dav/files/${NC_USER}/Vertr%c3%a4ge" >/dev/null

trash_body='<?xml version="1.0"?>
<d:propfind xmlns:d="DAV:" xmlns:nc="http://nextcloud.org/ns">
  <d:prop>
    <nc:trashbin-filename/>
    <nc:trashbin-original-location/>
    <nc:trashbin-deletion-time/>
    <d:getcontentlength/>
  </d:prop>
</d:propfind>'
log "capturing a trashbin PROPFIND (Depth 1)"
trash_xml="$(auth_curl -X PROPFIND -H 'Depth: 1' -H 'Content-Type: text/xml' \
  --data-binary "$trash_body" \
  "${NC_URL}/remote.php/dav/trashbin/${NC_USER}/trash/")" || die "trashbin PROPFIND failed"
redact "$trash_xml" >"${FIXTURES_DIR}/captured-propfind-trashbin.xml"

log "done; wrote captured-capabilities.json, captured-userinfo.xml, captured-propfind-files.xml, captured-propfind-trashbin.xml"
