#!/usr/bin/env bash
# fake_server.sh - smoke test for tests/fake_server.py and tests/fake_env.sh.
#
# Sources env.sh (isolation, stub curl, rclone config) and fake_env.sh, then
# starts the live fake Nextcloud and drives it with the real curl: fake_curl
# calls curl with a PATH that never contains the env.sh stub directory, so
# the requests reach the server. Covers the OCS endpoints (capabilities,
# shares incl. pending, sharees, notifications with actions, activity
# pagination), WebDAV (LOCK/UNLOCK, trashbin, versions, chunked uploads),
# Login Flow v2, and the avatar. The EXIT trap installed by fake_server_start
# stops the server and then runs env.sh's temp-dir cleanup.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

command -v python3 >/dev/null 2>&1 || {
  echo "SKIP: python3 not installed"
  exit 0
}

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../fake_env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../fake_env.sh"

fake_server_start || {
  echo "SKIP: fake server did not start"
  exit 0
}

BODY="${TMP}/fake-body.out"
AUTH="${FAKE_USER}:${FAKE_PASSWORD}"

# /status.php is the one unauthenticated endpoint (JSON).
code="$(fake_curl -s -o "$BODY" -w '%{http_code}' "$FAKE_BASE/status.php")"
expect_rc "status: HTTP 200" "$code" 200
expect_contains "status: installed" "$(cat "$BODY")" '"installed":true'
expect_contains "status: version" "$(cat "$BODY")" '"version":"34.0.0"'

# Capabilities (authenticated OCS XML).
code="$(fake_curl -s -o "$BODY" -w '%{http_code}' -u "$AUTH" \
  "$FAKE_BASE/ocs/v2.php/cloud/capabilities")"
expect_rc "capabilities: HTTP 200" "$code" 200
expect_contains "capabilities: bigfilechunking" "$(cat "$BODY")" "bigfilechunking"
expect_contains "capabilities: version" "$(cat "$BODY")" "34.0.0"
# The sharing/versioning/comments/tags/status/activity/dav sections.
expect_contains "capabilities: files_sharing" "$(cat "$BODY")" "<files_sharing>"
expect_contains "capabilities: sharing api_enabled" "$(cat "$BODY")" "<api_enabled>true</api_enabled>"
expect_contains "capabilities: public password enforced" "$(cat "$BODY")" \
  "<password><enforced>true</enforced></password>"
expect_contains "capabilities: user default permissions" "$(cat "$BODY")" \
  "<user><default_permissions>31</default_permissions></user>"
expect_contains "capabilities: federation" "$(cat "$BODY")" \
  "<federation><outgoing>true</outgoing><incoming>true</incoming></federation>"
expect_contains "capabilities: files versioning" "$(cat "$BODY")" "<versioning>true</versioning>"
expect_contains "capabilities: comments" "$(cat "$BODY")" \
  "<comments><maxCharacters>1000</maxCharacters>"
expect_contains "capabilities: systemtags" "$(cat "$BODY")" \
  "<systemtags><enabled>true</enabled></systemtags>"
expect_contains "capabilities: notifications endpoints" "$(cat "$BODY")" "<ocs-endpoints>"
expect_contains "capabilities: user_status" "$(cat "$BODY")" \
  "<user_status><enabled>true</enabled>"
expect_contains "capabilities: activity apiv2" "$(cat "$BODY")" "<activity><apiv2>"
expect_contains "capabilities: dav chunking" "$(cat "$BODY")" "<dav><chunking>1.0</chunking></dav>"

# Capabilities JSON mirrors the XML sections.
code="$(fake_curl -s -o "$BODY" -w '%{http_code}' -u "$AUTH" \
  "$FAKE_BASE/ocs/v2.php/cloud/capabilities?format=json")"
expect_rc "capabilities JSON: HTTP 200" "$code" 200
expect_contains "capabilities JSON: files_sharing" "$(cat "$BODY")" \
  '"files_sharing":{"api_enabled":true'
expect_contains "capabilities JSON: sharebymail" "$(cat "$BODY")" '"sharebymail":{"enabled":true}'
expect_contains "capabilities JSON: comments" "$(cat "$BODY")" '"comments":{"maxCharacters":1000'
expect_contains "capabilities JSON: user_status" "$(cat "$BODY")" \
  '"user_status":{"enabled":true,"supports_emoji":true}'
expect_contains "capabilities JSON: dav chunking" "$(cat "$BODY")" '"dav":{"chunking":"1.0"}'

# Wrong credentials fail with a 401 DAV error body.
code="$(fake_curl -s -o "$BODY" -w '%{http_code}' -u "${FAKE_USER}:wrong" \
  "$FAKE_BASE/ocs/v2.php/cloud/user")"
expect_rc "auth: wrong password 401" "$code" 401
expect_contains "auth: DAV error body" "$(cat "$BODY")" "<d:error"

# Share POST/GET roundtrip.
code="$(fake_curl -s -o "$BODY" -w '%{http_code}' -u "$AUTH" \
  -H 'OCS-APIRequest: true' \
  --data-urlencode path=report.txt --data-urlencode shareType=3 \
  "$FAKE_BASE/ocs/v2.php/apps/files_sharing/api/v1/shares")"
expect_rc "shares: create HTTP 200" "$code" 200
expect_contains "shares: id" "$(cat "$BODY")" "<id>1</id>"
expect_contains "shares: token" "$(cat "$BODY")" "<token>"

code="$(fake_curl -s -o "$BODY" -w '%{http_code}' -u "$AUTH" \
  "$FAKE_BASE/ocs/v2.php/apps/files_sharing/api/v1/shares")"
expect_rc "shares: list HTTP 200" "$code" 200
expect_contains "shares: element" "$(cat "$BODY")" "<element>"
expect_contains "shares: path" "$(cat "$BODY")" "/report.txt"

# Notifications listing.
code="$(fake_curl -s -o "$BODY" -w '%{http_code}' -u "$AUTH" \
  "$FAKE_BASE/ocs/v2.php/apps/notifications/api/v2/notifications")"
expect_rc "notifications: HTTP 200" "$code" 200
expect_contains "notifications: id" "$(cat "$BODY")" "<notification_id>11</notification_id>"
expect_contains "notifications: app" "$(cat "$BODY")" "<app>files_sharing</app>"

# The whole CLI against the faknc remote that fake_server_start created:
# rclone config introspection, lib/http.sh's netrc auth, and XML parsing.
out="$(fake_cli notifications 2>&1)"
expect_rc "fake_cli: notifications rc 0" "$?" 0
expect_contains "fake_cli: subject" "$out" "Alice shared report.txt with you"

# --- pending shares: seeded local and federated listings --------------------
PENDING_URL="${FAKE_BASE}/ocs/v2.php/apps/files_sharing/api/v1/shares/pending"
REMOTE_PENDING_URL="${FAKE_BASE}/ocs/v2.php/apps/files_sharing/api/v1/remote_shares/pending"

code="$(fake_curl -s -o "$BODY" -w '%{http_code}' -u "$AUTH" -H 'OCS-APIRequest: true' "$PENDING_URL")"
expect_rc "pending: local list HTTP 200" "$code" 200
expect_contains "pending: local id" "$(cat "$BODY")" "<id>501</id>"
expect_contains "pending: local type" "$(cat "$BODY")" "<share_type>0</share_type>"
expect_contains "pending: local recipient" "$(cat "$BODY")" "<share_with>alice</share_with>"
expect_contains "pending: local state" "$(cat "$BODY")" "<state>1</state>"

# Older servers have no /shares/pending; the collection accepts a filter.
code="$(fake_curl -s -o "$BODY" -w '%{http_code}' -u "$AUTH" -H 'OCS-APIRequest: true' \
  "${FAKE_BASE}/ocs/v2.php/apps/files_sharing/api/v1/shares?shared_with_me=true&state=pending")"
expect_rc "pending: fallback HTTP 200" "$code" 200
expect_contains "pending: fallback id" "$(cat "$BODY")" "<id>501</id>"

code="$(fake_curl -s -o "$BODY" -w '%{http_code}' -u "$AUTH" "$REMOTE_PENDING_URL")"
expect_rc "pending: federated list HTTP 200" "$code" 200
expect_contains "pending: federated id" "$(cat "$BODY")" "<id>601</id>"
expect_contains "pending: federated type" "$(cat "$BODY")" "<share_type>6</share_type>"
expect_contains "pending: federated remote" "$(cat "$BODY")" "<remote>https://remote.example.org</remote>"

code="$(fake_curl -s -o "$BODY" -w '%{http_code}' -u "$AUTH" -X POST "${PENDING_URL}/9999")"
expect_rc "pending: unknown accept HTTP 404" "$code" 404
expect_contains "pending: unknown accept OCS failure" "$(cat "$BODY")" "<status>failure</status>"

# --- notification actions: XML methods and the action endpoints -------------
code="$(fake_curl -s -o "$BODY" -w '%{http_code}' -u "$AUTH" \
  "${FAKE_BASE}/ocs/v2.php/apps/notifications/api/v2/notifications")"
expect_rc "actions: notifications HTTP 200" "$code" 200
ACTIONS_XML="$(cat "$BODY")"
expect_contains "actions: block rendered" "$ACTIONS_XML" "<actions>"
expect_contains "actions: accept label" "$ACTIONS_XML" "<label>Accept</label>"
expect_contains "actions: accept link" "$ACTIONS_XML" \
  "<link>/ocs/v2.php/apps/files_sharing/api/v1/shares/pending/501</link>"
expect_contains "actions: accept method" "$ACTIONS_XML" "<type>POST</type>"
expect_contains "actions: decline method" "$ACTIONS_XML" "<type>DELETE</type>"
expect_contains "actions: primary flag" "$ACTIONS_XML" "<primary>true</primary>"
expect_contains "actions: neutral dismiss" "$ACTIONS_XML" "<label>Dismiss</label>"
expect_contains "actions: neutral non-OCS link" "$ACTIONS_XML" "<link>#</link>"

# Executing the accept link (POST to the absolute OCS action URL) accepts the
# pending share: it leaves /shares/pending and appears in /shares.
code="$(fake_curl -s -o "$BODY" -w '%{http_code}' -u "$AUTH" -X POST "${PENDING_URL}/501")"
expect_rc "actions: accept HTTP 200" "$code" 200
expect_contains "actions: accepted state" "$(cat "$BODY")" "<state>0</state>"

code="$(fake_curl -s -o "$BODY" -w '%{http_code}' -u "$AUTH" -H 'OCS-APIRequest: true' "$PENDING_URL")"
expect_rc "actions: pending list HTTP 200" "$code" 200
expect_not_contains "actions: pending list emptied" "$(cat "$BODY")" "<id>501</id>"

code="$(fake_curl -s -o "$BODY" -w '%{http_code}' -u "$AUTH" \
  "${FAKE_BASE}/ocs/v2.php/apps/files_sharing/api/v1/shares")"
expect_contains "actions: accepted share listed" "$(cat "$BODY")" "<id>501</id>"

code="$(fake_curl -s -o "$BODY" -w '%{http_code}' -u "$AUTH" -X DELETE "${REMOTE_PENDING_URL}/601")"
expect_rc "actions: federated decline HTTP 200" "$code" 200
code="$(fake_curl -s -o "$BODY" -w '%{http_code}' -u "$AUTH" "$REMOTE_PENDING_URL")"
expect_not_contains "actions: federated list emptied" "$(cat "$BODY")" "<id>601</id>"

# --- sharee autocomplete ----------------------------------------------------
code="$(fake_curl -s -o "$BODY" -w '%{http_code}' -u "$AUTH" \
  "${FAKE_BASE}/ocs/v2.php/apps/files_sharing/api/v1/sharees?search=alice&itemType=file")"
expect_rc "sharees: XML HTTP 200" "$code" 200
expect_contains "sharees: user label" "$(cat "$BODY")" "<label>Alice Anderson</label>"
expect_contains "sharees: user value" "$(cat "$BODY")" "<shareWith>alice</shareWith>"
expect_contains "sharees: user type" "$(cat "$BODY")" "<shareType>0</shareType>"

code="$(fake_curl -s -o "$BODY" -w '%{http_code}' -u "$AUTH" \
  "${FAKE_BASE}/ocs/v2.php/apps/files_sharing/api/v1/sharees?search=team&format=json")"
expect_rc "sharees: JSON HTTP 200" "$code" 200
expect_contains "sharees: JSON group" "$(cat "$BODY")" '"shareWith":"team-blue"'
expect_contains "sharees: JSON group type" "$(cat "$BODY")" '"shareType":1'

# --- WebDAV LOCK/UNLOCK -----------------------------------------------------
LOCK_LOCAL="${TMP}/lock-upload.txt"
printf 'lock me\n' >"$LOCK_LOCAL"
code="$(fake_curl -s -o /dev/null -w '%{http_code}' -u "$AUTH" -X PUT \
  --data-binary "@${LOCK_LOCAL}" "${FAKE_BASE}/remote.php/dav/files/alice/locked.txt")"
expect_rc "lock: upload HTTP 201" "$code" 201

HEADERS="${TMP}/fake-headers.out"
code="$(fake_curl -s -o "$BODY" -D "$HEADERS" -w '%{http_code}' -u "$AUTH" -X LOCK \
  -H 'X-User-Lock: 1' --data-binary '{"owner":"alice"}' \
  "${FAKE_BASE}/remote.php/dav/files/alice/locked.txt")"
expect_rc "lock: HTTP 200" "$code" 200
expect_contains "lock: Lock-Token header" "$(cat "$HEADERS")" "Lock-Token: opaquelocktoken:"
expect_contains "lock: lockdiscovery body" "$(cat "$BODY")" "<d:lockdiscovery>"
LOCK_TOKEN="$(sed -n 's/^[Ll]ock-[Tt]oken: *//p' "$HEADERS" | tr -d '\r' | head -n 1)"
expect_contains "lock: token captured" "$LOCK_TOKEN" "opaquelocktoken:"

code="$(fake_curl -s -o "$BODY" -w '%{http_code}' -u "$AUTH" -X LOCK \
  "${FAKE_BASE}/remote.php/dav/files/alice/locked.txt")"
expect_rc "lock: second LOCK HTTP 423" "$code" 423

code="$(fake_curl -s -o "$BODY" -w '%{http_code}' -u "$AUTH" -X PROPFIND -H 'Depth: 0' \
  -H 'Content-Type: application/xml' \
  --data-binary '<?xml version="1.0"?><d:propfind xmlns:d="DAV:" xmlns:nc="http://nextcloud.org/ns"><d:prop><nc:lock-token/></d:prop></d:propfind>' \
  "${FAKE_BASE}/remote.php/dav/files/alice/locked.txt")"
expect_rc "lock: PROPFIND HTTP 207" "$code" 207
expect_contains "lock: PROPFIND lockdiscovery" "$(cat "$BODY")" "<d:lockdiscovery>"
expect_contains "lock: PROPFIND locktoken" "$(cat "$BODY")" "<d:locktoken>"
expect_contains "lock: PROPFIND token" "$(cat "$BODY")" "$LOCK_TOKEN"

code="$(fake_curl -s -o "$BODY" -w '%{http_code}' -u "$AUTH" -X UNLOCK \
  -H "Lock-Token: ${LOCK_TOKEN}" \
  "${FAKE_BASE}/remote.php/dav/files/alice/locked.txt")"
expect_rc "unlock: HTTP 204" "$code" 204

code="$(fake_curl -s -o "$BODY" -w '%{http_code}' -u "$AUTH" -X LOCK \
  "${FAKE_BASE}/remote.php/dav/files/alice/locked.txt")"
expect_rc "unlock: relock HTTP 200" "$code" 200

# --- DAV properties: seeded E2EE, external mounts, checksums, owner ---------
PROPS_URL="${FAKE_BASE}/remote.php/dav/files/alice/props.txt"
code="$(fake_curl -s -o /dev/null -w '%{http_code}' -u "$AUTH" -X PUT \
  --data-binary 'props' "$PROPS_URL")"
expect_rc "props: upload HTTP 201" "$code" 201

code="$(fake_curl -s -o "$BODY" -w '%{http_code}' -u "$AUTH" -X PROPFIND -H 'Depth: 0' "$PROPS_URL")"
expect_rc "props: plain PROPFIND HTTP 207" "$code" 207
expect_contains "props: plain permissions" "$(cat "$BODY")" "<oc:permissions>RGDNVW</oc:permissions>"
expect_contains "props: plain owner defaults to the user" "$(cat "$BODY")" "<d:owner-id>alice</d:owner-id>"
expect_not_contains "props: plain is not encrypted" "$(cat "$BODY")" "<nc:is-encrypted>"

fake_seed --data-urlencode what=props --data-urlencode path=props.txt \
  --data-urlencode encrypted=1 --data-urlencode checksums=SHA256:abc \
  --data-urlencode owner=bob >/dev/null
code="$(fake_curl -s -o "$BODY" -w '%{http_code}' -u "$AUTH" -X PROPFIND -H 'Depth: 0' "$PROPS_URL")"
expect_rc "props: seeded PROPFIND HTTP 207" "$code" 207
expect_contains "props: is-encrypted" "$(cat "$BODY")" "<nc:is-encrypted>1</nc:is-encrypted>"
expect_contains "props: checksums" "$(cat "$BODY")" "<oc:checksums>SHA256:abc</oc:checksums>"
expect_contains "props: seeded owner" "$(cat "$BODY")" "<d:owner-id>bob</d:owner-id>"

fake_seed --data-urlencode what=external --data-urlencode path=props.txt >/dev/null
code="$(fake_curl -s -o "$BODY" -w '%{http_code}' -u "$AUTH" -X PROPFIND -H 'Depth: 0' "$PROPS_URL")"
expect_contains "props: external mount permission" "$(cat "$BODY")" \
  "<oc:permissions>RGDNVWM</oc:permissions>"

# --- opt-in error injection: query faults, seeded faults, If-Match ----------
code="$(fake_curl -s -o "$BODY" -D "$HEADERS" -w '%{http_code}' -u "$AUTH" "${PROPS_URL}?__fail=429")"
expect_rc "faults: query 429" "$code" 429
expect_contains "faults: 429 Retry-After" "$(cat "$HEADERS")" "Retry-After: 1"
for status in 503 507; do
  code="$(fake_curl -s -o "$BODY" -w '%{http_code}' -u "$AUTH" "${PROPS_URL}?__fail=${status}")"
  expect_rc "faults: query ${status}" "$code" "$status"
  expect_contains "faults: query ${status} DAV error" "$(cat "$BODY")" "<d:error"
done

fake_seed --data-urlencode what=fail --data-urlencode path=props.txt \
  --data-urlencode status=503 --data-urlencode count=1 >/dev/null
code="$(fake_curl -s -o /dev/null -w '%{http_code}' -u "$AUTH" "$PROPS_URL")"
expect_rc "faults: seeded request injected" "$code" 503
code="$(fake_curl -s -o "$BODY" -w '%{http_code}' -u "$AUTH" "$PROPS_URL")"
expect_rc "faults: seeded request recovers" "$code" 200
expect_contains "faults: recovered body" "$(cat "$BODY")" "props"

# The GET advertises an ETag; a stale If-Match answers 412, a fresh one 200.
code="$(fake_curl -s -o /dev/null -D "$HEADERS" -w '%{http_code}' -u "$AUTH" "$PROPS_URL")"
ETAG_VALUE="$(sed -n 's/^[Ee][Tt][Aa][Gg]: *//p' "$HEADERS" | tr -d '\r' | head -n 1)"
expect_contains "faults: GET ETag header" "$ETAG_VALUE" '"'
code="$(fake_curl -s -o "$BODY" -w '%{http_code}' -u "$AUTH" -H 'If-Match: "stale"' "$PROPS_URL")"
expect_rc "faults: stale If-Match 412" "$code" 412
code="$(fake_curl -s -o /dev/null -w '%{http_code}' -u "$AUTH" -H "If-Match: ${ETAG_VALUE}" "$PROPS_URL")"
expect_rc "faults: matching If-Match 200" "$code" 200

# --- Range partial GET and the redirect routes ------------------------------
code="$(fake_curl -s -o "$BODY" -D "$HEADERS" -w '%{http_code}' -u "$AUTH" -r 0-3 "$PROPS_URL")"
expect_rc "range: HTTP 206" "$code" 206
expect_eq "range: partial body" "prop" "$(cat "$BODY")"
expect_contains "range: Content-Range" "$(cat "$HEADERS")" "Content-Range: bytes 0-3/5"

code="$(fake_curl -s -o /dev/null -D "$HEADERS" -w '%{http_code}' -u "$AUTH" \
  "$FAKE_BASE/redirect/status.php")"
expect_rc "redirect: static HTTP 302" "$code" 302
expect_contains "redirect: static Location" "$(cat "$HEADERS")" "Location: /status.php"
code="$(fake_curl -s -o /dev/null -D "$HEADERS" -w '%{http_code}' -u "$AUTH" \
  "$FAKE_BASE/__test__/redirect?to=/status.php")"
expect_rc "redirect: hook HTTP 302" "$code" 302
expect_contains "redirect: hook Location" "$(cat "$HEADERS")" "Location: /status.php"

# --- quota properties on the files root -------------------------------------
code="$(fake_curl -s -o "$BODY" -w '%{http_code}' -u "$AUTH" -X PROPFIND -H 'Depth: 0' \
  "${FAKE_BASE}/remote.php/dav/files/alice/")"
expect_rc "quota: root PROPFIND HTTP 207" "$code" 207
expect_contains "quota: available bytes" "$(cat "$BODY")" "<d:quota-available-bytes>"
expect_contains "quota: used bytes" "$(cat "$BODY")" "<d:quota-used-bytes>"

# --- functional trashbin (empty by default, seeded through the hook) --------
TRASH_URL="${FAKE_BASE}/remote.php/dav/trashbin/alice/trash"
code="$(fake_curl -s -o "$BODY" -w '%{http_code}' -u "$AUTH" -X PROPFIND -H 'Depth: 1' "$TRASH_URL")"
expect_rc "trash: default PROPFIND HTTP 207" "$code" 207
expect_not_contains "trash: empty by default" "$(cat "$BODY")" "<d:response>"

fake_seed --data-urlencode what=trash >/dev/null
code="$(fake_curl -s -o "$BODY" -w '%{http_code}' -u "$AUTH" -X PROPFIND -H 'Depth: 1' "$TRASH_URL")"
expect_rc "trash: seeded PROPFIND HTTP 207" "$code" 207
expect_contains "trash: item href" "$(cat "$BODY")" "plan.txt.d1700000000"
expect_contains "trash: original name" "$(cat "$BODY")" \
  "<oc:trashbin-original-filename>plan.txt</oc:trashbin-original-filename>"
expect_contains "trash: original location" "$(cat "$BODY")" \
  "<oc:trashbin-original-location>notes/plan.txt</oc:trashbin-original-location>"

code="$(fake_curl -s -o /dev/null -w '%{http_code}' -u "$AUTH" -X MOVE \
  -H "Destination: ${FAKE_BASE}/remote.php/dav/trashbin/alice/restore/plan.txt.d1700000000" \
  "${TRASH_URL}/plan.txt.d1700000000")"
expect_rc "trash: restore HTTP 201" "$code" 201
code="$(fake_curl -s -o "$BODY" -w '%{http_code}' -u "$AUTH" \
  "${FAKE_BASE}/remote.php/dav/files/alice/notes/plan.txt")"
expect_rc "trash: restored file HTTP 200" "$code" 200
expect_contains "trash: restored content" "$(cat "$BODY")" "restored from trash"

fake_seed --data-urlencode what=trash >/dev/null
code="$(fake_curl -s -o /dev/null -w '%{http_code}' -u "$AUTH" -X DELETE \
  "${TRASH_URL}/plan.txt.d1700000000")"
expect_rc "trash: delete HTTP 204" "$code" 204
code="$(fake_curl -s -o "$BODY" -w '%{http_code}' -u "$AUTH" -X PROPFIND -H 'Depth: 1' "$TRASH_URL")"
expect_not_contains "trash: empty after delete" "$(cat "$BODY")" "<d:response>"

# --- functional versions (seeded through the hook) --------------------------
SEED_JSON="$(fake_seed --data-urlencode what=versions --data-urlencode path=report.txt)"
expect_contains "versions: seed reports a fileid" "$SEED_JSON" '"seeded":"versions"'
FILEID="$(printf '%s' "$SEED_JSON" | sed -n 's/.*"fileid":\([0-9][0-9]*\).*/\1/p')"
VERSIONS_URL="${FAKE_BASE}/remote.php/dav/versions/alice/versions/${FILEID}"
code="$(fake_curl -s -o "$BODY" -w '%{http_code}' -u "$AUTH" -X PROPFIND -H 'Depth: 1' "$VERSIONS_URL")"
expect_rc "versions: PROPFIND HTTP 207" "$code" 207
expect_contains "versions: version href" "$(cat "$BODY")" "1700000000"
expect_contains "versions: version size" "$(cat "$BODY")" "<d:getcontentlength>"

code="$(fake_curl -s -o "$BODY" -w '%{http_code}' -u "$AUTH" "${VERSIONS_URL}/1700000000")"
expect_rc "versions: download HTTP 200" "$code" 200
expect_contains "versions: download content" "$(cat "$BODY")" "version-one-payload"

code="$(fake_curl -s -o /dev/null -w '%{http_code}' -u "$AUTH" -X MOVE \
  -H "Destination: ${FAKE_BASE}/remote.php/dav/versions/alice/restore/target" \
  "${VERSIONS_URL}/1700000000")"
expect_rc "versions: restore HTTP 201" "$code" 201
code="$(fake_curl -s -o "$BODY" -w '%{http_code}' -u "$AUTH" \
  "${FAKE_BASE}/remote.php/dav/files/alice/report.txt")"
expect_contains "versions: restore replaced the file" "$(cat "$BODY")" "version-one-payload"

fake_seed --data-urlencode what=versions --data-urlencode path=report.txt >/dev/null
code="$(fake_curl -s -o /dev/null -w '%{http_code}' -u "$AUTH" -X DELETE "${VERSIONS_URL}/1700000000")"
expect_rc "versions: delete HTTP 204" "$code" 204
code="$(fake_curl -s -o "$BODY" -w '%{http_code}' -u "$AUTH" -X PROPFIND -H 'Depth: 1' "$VERSIONS_URL")"
expect_rc "versions: empty PROPFIND HTTP 207" "$code" 207
expect_not_contains "versions: empty after delete" "$(cat "$BODY")" "<d:response>"

# --- Login Flow v2 ----------------------------------------------------------
code="$(fake_curl -s -o "$BODY" -w '%{http_code}' -X POST "${FAKE_BASE}/index.php/login/v2")"
expect_rc "login flow: start HTTP 200" "$code" 200
expect_contains "login flow: poll endpoint" "$(cat "$BODY")" "/login/v2/poll"
expect_contains "login flow: login url" "$(cat "$BODY")" "/login/v2/flow/"
FLOW_TOKEN="$(sed -n 's/.*"token":"\([^"]*\)".*/\1/p' "$BODY" | head -n 1)"
expect_contains "login flow: token captured" "$FLOW_TOKEN" "flow-"

code="$(fake_curl -s -o "$BODY" -w '%{http_code}' -X POST \
  --data-urlencode "token=${FLOW_TOKEN}" "${FAKE_BASE}/login/v2/poll")"
expect_rc "login flow: first poll HTTP 200" "$code" 200
expect_contains "login flow: login name" "$(cat "$BODY")" '"loginName":"alice"'
expect_contains "login flow: app password" "$(cat "$BODY")" '"appPassword":"app-pass"'

# With polls=1 the next flow 404s once before it succeeds.
fake_login_seed 1 >/dev/null
fake_curl -s -o "$BODY" -X POST "${FAKE_BASE}/index.php/login/v2"
FLOW_TOKEN="$(sed -n 's/.*"token":"\([^"]*\)".*/\1/p' "$BODY" | head -n 1)"
code="$(fake_curl -s -o /dev/null -w '%{http_code}' -X POST \
  --data-urlencode "token=${FLOW_TOKEN}" "${FAKE_BASE}/login/v2/poll")"
expect_rc "login flow: pending poll HTTP 404" "$code" 404
code="$(fake_curl -s -o "$BODY" -w '%{http_code}' -X POST \
  --data-urlencode "token=${FLOW_TOKEN}" "${FAKE_BASE}/login/v2/poll")"
expect_rc "login flow: later poll HTTP 200" "$code" 200

code="$(fake_curl -s -o "$BODY" -w '%{http_code}' -u "alice:app-pass" \
  "${FAKE_BASE}/ocs/v2.php/cloud/user")"
expect_rc "login flow: app password authenticates" "$code" 200

# --- avatar -----------------------------------------------------------------
code="$(fake_curl -s -o "$BODY" -w '%{http_code}' -u "$AUTH" "${FAKE_BASE}/avatar/alice/32")"
expect_rc "avatar: HTTP 200" "$code" 200
expect_eq "avatar: 1x1 PNG size" "70" "$(wc -c <"$BODY" | tr -d ' ')"
AVATAR_TYPE="$(fake_curl -s -o /dev/null -w '%{content_type}' -u "$AUTH" "${FAKE_BASE}/avatar/alice/32")"
expect_eq "avatar: content type" "image/png" "$AVATAR_TYPE"

# --- activity pagination ----------------------------------------------------
ACTIVITY_URL="${FAKE_BASE}/ocs/v2.php/apps/activity/api/v2/activity"
code="$(fake_curl -s -o "$BODY" -w '%{http_code}' -u "$AUTH" "${ACTIVITY_URL}?limit=3&sort=desc")"
expect_rc "activity: limit HTTP 200" "$code" 200
ACTIVITY_XML="$(cat "$BODY")"
expect_contains "activity: newest first" "$ACTIVITY_XML" "<activity_id>125</activity_id>"
expect_contains "activity: limit keeps three" "$ACTIVITY_XML" "<activity_id>123</activity_id>"
expect_not_contains "activity: limit cuts the rest" "$ACTIVITY_XML" "<activity_id>122</activity_id>"

code="$(fake_curl -s -o "$BODY" -w '%{http_code}' -u "$AUTH" "${ACTIVITY_URL}?since=124&sort=desc")"
expect_rc "activity: since HTTP 200" "$code" 200
expect_contains "activity: since returns newer" "$(cat "$BODY")" "<activity_id>125</activity_id>"
expect_not_contains "activity: since drops older" "$(cat "$BODY")" "<activity_id>124</activity_id>"

# --- chunked uploads --------------------------------------------------------
UPLOAD_URL="${FAKE_BASE}/remote.php/dav/uploads/alice/up-1"
code="$(fake_curl -s -o "$BODY" -w '%{http_code}' -u "$AUTH" -X MKCOL "$UPLOAD_URL")"
expect_rc "uploads: MKCOL HTTP 201" "$code" 201
code="$(fake_curl -s -o "$BODY" -w '%{http_code}' -u "$AUTH" -X PUT \
  --data-binary 'hello ' "${UPLOAD_URL}/1")"
expect_rc "uploads: chunk 1 HTTP 201" "$code" 201
code="$(fake_curl -s -o "$BODY" -w '%{http_code}' -u "$AUTH" -X PUT \
  --data-binary 'world' "${UPLOAD_URL}/2")"
expect_rc "uploads: chunk 2 HTTP 201" "$code" 201
code="$(fake_curl -s -o /dev/null -w '%{http_code}' -u "$AUTH" -X MOVE \
  -H "Destination: ${FAKE_BASE}/remote.php/dav/files/alice/chunked.txt" "${UPLOAD_URL}/.file")"
expect_rc "uploads: assemble HTTP 201" "$code" 201
code="$(fake_curl -s -o "$BODY" -w '%{http_code}' -u "$AUTH" \
  "${FAKE_BASE}/remote.php/dav/files/alice/chunked.txt")"
expect_rc "uploads: assembled GET HTTP 200" "$code" 200
expect_eq "uploads: assembled content" "hello world" "$(cat "$BODY")"

code="$(fake_curl -s -o "$BODY" -w '%{http_code}' -u "$AUTH" -X MKCOL "${UPLOAD_URL}-2")"
expect_rc "uploads: second MKCOL HTTP 201" "$code" 201
code="$(fake_curl -s -o /dev/null -w '%{http_code}' -u "$AUTH" -X DELETE "${UPLOAD_URL}-2")"
expect_rc "uploads: DELETE HTTP 204" "$code" 204

finish
