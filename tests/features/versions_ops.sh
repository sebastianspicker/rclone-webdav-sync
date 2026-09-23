#!/usr/bin/env bash
# versions_ops.sh - versions download/restore/delete actions through the
# shared HTTP layer (stub curl). A small curl wrapper logs the full argv so
# the MOVE Destination header is visible; the shared stub records the rest.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

# --- request-logging curl wrapper around the shared stub --------------------
VERSIONS_BIN="${TMP}/versions-bin"
VERSIONS_LOG="${VERSIONS_BIN}/curl.log"
mkdir -p "$VERSIONS_BIN"
cat >"${VERSIONS_BIN}/curl" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$(dirname "$0")/curl.log"
exec "$(dirname "$0")/../stub-bin/curl" "$@"
STUB
chmod +x "${VERSIONS_BIN}/curl"
vers_log() { cat "$VERSIONS_LOG" 2>/dev/null || true; }
vers_log_reset() { rm -f "$VERSIONS_LOG"; }

# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_cli_versions() {
  (cd "$TMP" && env PATH="${VERSIONS_BIN}:$PATH" RCLONE_REMOTE=webtest \
    bash "${PROJ}/bin/sciebo" "$@")
}
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_cli_versions_no_stdin() {
  (cd "$TMP" && env PATH="${VERSIONS_BIN}:$PATH" RCLONE_REMOTE=webtest \
    bash "${PROJ}/bin/sciebo" "$@" </dev/null)
}

# --- canned fileid/versions XML (shapes from tests/integration.sh) ----------
FILEID_XML="${TMP}/fileid.xml"
cat >"$FILEID_XML" <<'XML'
<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
  <d:response>
    <d:href>/remote.php/dav/files/alice/backup/notes/plan.txt</d:href>
    <d:propstat><d:prop><oc:fileid>42</oc:fileid></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
  </d:response>
</d:multistatus>
XML
VERSIONS_XML="${TMP}/versions.xml"
cat >"$VERSIONS_XML" <<'XML'
<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/remote.php/dav/versions/alice/versions/42/</d:href>
    <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/dav/versions/alice/versions/42/1700000000</d:href>
    <d:propstat><d:prop>
      <d:getlastmodified>Wed, 01 Nov 2023 01:00:00 GMT</d:getlastmodified>
      <d:getcontentlength>1024</d:getcontentlength>
    </d:prop></d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/dav/versions/alice/versions/42/1700000100</d:href>
    <d:propstat><d:prop>
      <d:getlastmodified>Wed, 01 Nov 2023 02:00:00 GMT</d:getlastmodified>
      <d:getcontentlength>2048</d:getcontentlength>
    </d:prop></d:propstat>
  </d:response>
</d:multistatus>
XML

versions_stub_propfinds() {
  stub_reset_routes
  stub_route_file PROPFIND '*/remote.php/dav/files/alice/backup/notes/plan.txt' "$FILEID_XML" 200
  stub_route_file PROPFIND '*/remote.php/dav/versions/alice/versions/42' "$VERSIONS_XML" 200
}
versions_stub_propfinds

# --- listing stays unchanged ------------------------------------------------
stub_clear_calls
vers_log_reset
expect_cli "versions: list rc 0" 0 run_cli_versions versions notes/plan.txt
expect_contains "versions: older version listed" "$CLI_OUT" "1700000000"
expect_contains "versions: newer version listed" "$CLI_OUT" "1700000100"
expect_contains "versions: older version size" "$CLI_OUT" "1.0KiB"
expect_eq "versions: two data rows, collection row skipped" "2" \
  "$(printf '%s\n' "$CLI_OUT" | awk '$1 ~ /^[0-9]+$/ { n++ } END { print n + 0 }')"
expect_contains "versions: depth 0 file id PROPFIND" "$(vers_log)" "Depth: 0"
expect_contains "versions: depth 1 listing PROPFIND" "$(vers_log)" "Depth: 1"
expect_eq "versions: one depth 0 query" "1" \
  "$(printf '%s\n' "$(vers_log)" | grep -c 'Depth: 0')"
expect_eq "versions: one depth 1 query" "1" \
  "$(printf '%s\n' "$(vers_log)" | grep -c 'Depth: 1')"

# --- --download: file target, stdout, and the GET URL -----------------------
stub_clear_calls
vers_log_reset
stub_route GET '*/remote.php/dav/versions/alice/versions/42/1700000000' 200 <<'BODY'
version-one-payload
BODY
OUT_FILE="${TMP}/out.txt"
expect_cli "versions: --download rc 0" 0 \
  run_cli_versions versions notes/plan.txt --download 1700000000 --output "$OUT_FILE"
expect_contains "versions: download confirmation" "$CLI_OUT" "downloaded 1700000000 -> ${OUT_FILE}"
expect_file "versions: download target exists" "$OUT_FILE"
expect_contains "versions: download wrote the body" "$(cat "$OUT_FILE")" "version-one-payload"
expect_contains "versions: download GET URL" "$(stub_calls)" \
  "http://127.0.0.1:9/remote.php/dav/versions/alice/versions/42/1700000000"
expect_eq "versions: one GET for the version" "1" "$(stub_count '^GET.*/versions/42/1700000000')"

# The default target is ./<basename-of-SUB>.<VERSION> below the CWD.
rm -f "${TMP}/plan.txt.1700000000"
expect_cli "versions: --download default target rc 0" 0 \
  run_cli_versions versions notes/plan.txt --download 1700000000
expect_contains "versions: default target named" "$CLI_OUT" "downloaded 1700000000 -> ./plan.txt.1700000000"
expect_file "versions: default target written" "${TMP}/plan.txt.1700000000"

rm -f "${TMP}/plan.txt.1700000000"
vers_log_reset
expect_cli "versions: --download --stdout rc 0" 0 \
  run_cli_versions versions notes/plan.txt --download 1700000000 --stdout
expect_contains "versions: stdout carries the body" "$CLI_OUT" "version-one-payload"
expect_not_contains "versions: stdout prints no confirmation" "$CLI_OUT" "downloaded"
expect_no_file "versions: stdout writes no file" "${TMP}/plan.txt.1700000000"

# A symlinked --output target is refused before the GET; its target is intact.
VICTIM="${TMP}/versions-victim.txt"
printf 'original' >"$VICTIM"
LINK_TARGET="${TMP}/versions-link.txt"
ln -sf "$VICTIM" "$LINK_TARGET"
stub_clear_calls
expect_cli "versions: symlink output rc 1" 1 \
  run_cli_versions versions notes/plan.txt --download 1700000000 --output "$LINK_TARGET"
expect_contains "versions: symlink output refused" "$CLI_OUT" "refusing to write through symlink: ${LINK_TARGET}"
expect_eq "versions: symlink target untouched" "original" "$(cat "$VICTIM")"
expect_eq "versions: symlink output sends no GET" "0" "$(stub_count '^GET.*/versions/42/1700000000')"

# A missing version dies with a dedicated message and leaves no partial file.
stub_route GET '*/remote.php/dav/versions/alice/versions/42/1799999999' 404 <<'XML'
<?xml version="1.0"?>
<d:error xmlns:d="DAV:"/>
XML
expect_cli "versions: missing version rc 1" 1 \
  run_cli_versions versions notes/plan.txt --download 1799999999 --output "${TMP}/missing.txt"
expect_contains "versions: 404 names no such version" "$CLI_OUT" "no such version"
expect_no_file "versions: failed download leaves no file" "${TMP}/missing.txt"

# --- --restore: confirmation, MOVE URL, and Destination ---------------------
stub_clear_calls
vers_log_reset
expect_cli "versions: --restore without --yes rc 2" 2 \
  run_cli_versions_no_stdin versions notes/plan.txt --restore 1700000000
expect_contains "versions: restore names --yes" "$CLI_OUT" "requires --yes"
expect_eq "versions: no MOVE without --yes" "0" "$(stub_count '^MOVE')"

stub_route MOVE '*/remote.php/dav/versions/alice/versions/42/1700000000' 201 </dev/null
stub_clear_calls
vers_log_reset
expect_cli "versions: --restore --yes rc 0" 0 \
  run_cli_versions versions notes/plan.txt --restore 1700000000 --yes
expect_contains "versions: restore confirmation" "$CLI_OUT" "restored 1700000000"
expect_eq "versions: one MOVE" "1" "$(stub_count '^MOVE')"
expect_contains "versions: MOVE URL" "$(stub_calls)" \
  "MOVE	http://127.0.0.1:9/remote.php/dav/versions/alice/versions/42/1700000000"
expect_contains "versions: MOVE Destination" "$(vers_log)" \
  "Destination: http://127.0.0.1:9/remote.php/dav/versions/alice/restore/target"

# --- --delete: confirmation and DELETE URL ----------------------------------
stub_clear_calls
expect_cli "versions: --delete without --yes rc 2" 2 \
  run_cli_versions_no_stdin versions notes/plan.txt --delete 1700000100
expect_contains "versions: delete names --yes" "$CLI_OUT" "requires --yes"
expect_eq "versions: no DELETE without --yes" "0" "$(stub_count '^DELETE')"

stub_route DELETE '*/remote.php/dav/versions/alice/versions/42/1700000100' 204 </dev/null
stub_clear_calls
expect_cli "versions: --delete --yes rc 0" 0 \
  run_cli_versions versions notes/plan.txt --delete 1700000100 --yes
expect_contains "versions: delete confirmation" "$CLI_OUT" "deleted 1700000100"
expect_eq "versions: one DELETE" "1" "$(stub_count '^DELETE')"
expect_contains "versions: DELETE URL" "$(stub_calls)" \
  "DELETE	http://127.0.0.1:9/remote.php/dav/versions/alice/versions/42/1700000100"

# A 404 on an action names the missing version too.
stub_route MOVE '*/remote.php/dav/versions/alice/versions/42/1799999999' 404 <<'XML'
<?xml version="1.0"?>
<d:error xmlns:d="DAV:"/>
XML
expect_cli "versions: missing restore target rc 1" 1 \
  run_cli_versions versions notes/plan.txt --restore 1799999999 --yes
expect_contains "versions: restore 404 names no such version" "$CLI_OUT" "no such version"

# A 3xx on a write is a failure: curl does not follow redirects for MOVE or
# DELETE, so the redirected request has no body and the action did not happen.
stub_route MOVE '*/remote.php/dav/versions/alice/versions/42/1700000001' 302 </dev/null
stub_clear_calls
expect_cli "versions: restore redirect rc 1" 1 \
  run_cli_versions versions notes/plan.txt --restore 1700000001 --yes
expect_not_contains "versions: restore redirect is not restored" "$CLI_OUT" "restored"
expect_contains "versions: restore redirect reports the status" "$CLI_OUT" "HTTP 302"

stub_route DELETE '*/remote.php/dav/versions/alice/versions/42/1700000002' 302 </dev/null
stub_clear_calls
expect_cli "versions: delete redirect rc 1" 1 \
  run_cli_versions versions notes/plan.txt --delete 1700000002 --yes
expect_not_contains "versions: delete redirect is not deleted" "$CLI_OUT" "deleted"
expect_contains "versions: delete redirect reports the status" "$CLI_OUT" "HTTP 302"

# --- option validation ------------------------------------------------------
expect_cli "versions: --restore with --delete rc 2" 2 \
  run_cli_versions versions notes/plan.txt --restore 1 --delete 1 --yes
expect_contains "versions: exclusivity message" "$CLI_OUT" "mutually exclusive"
expect_cli "versions: --output without --download rc 2" 2 \
  run_cli_versions versions notes/plan.txt --output "${TMP}/out.txt"
expect_contains "versions: --output needs --download" "$CLI_OUT" "requires --download"
expect_cli "versions: --stdout without --download rc 2" 2 \
  run_cli_versions versions notes/plan.txt --stdout
expect_contains "versions: --stdout needs --download" "$CLI_OUT" "requires --download"
expect_cli "versions: non-numeric version rc 2" 2 \
  run_cli_versions versions notes/plan.txt --restore abc --yes
expect_contains "versions: numeric version message" "$CLI_OUT" "numeric version"
expect_cli "versions: timestamp version rc 2" 2 \
  run_cli_versions versions notes/plan.txt --delete 1700000000.5 --yes
expect_contains "versions: dotted version rejected" "$CLI_OUT" "numeric version"

finish
