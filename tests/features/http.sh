#!/usr/bin/env bash
# http.sh - unit checks for the shared HTTP/XML helpers.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

# --- http_urlencode: byte-wise, slashes survive ---------------------------
expect_eq "urlencode: plain path" "notes/plan.txt" "$(http_urlencode 'notes/plan.txt')"
expect_eq "urlencode: spaces" "a%20b.txt" "$(http_urlencode 'a b.txt')"
expect_eq "urlencode: reserved bytes" "%25%3F%23%2B%26%3D" "$(http_urlencode '%?#+&=')"
expect_eq "urlencode: utf-8 bytes" "gr%C3%BC%C3%9Fe.txt" "$(http_urlencode 'grüße.txt')"
expect_eq "urlencode: unreserved survive" "A-z.0_9~/" "$(http_urlencode 'A-z.0_9~/')"
expect_eq "urlencode: empty" "" "$(http_urlencode '')"
expect_eq "urlencode: single quote" "a%27b" "$(http_urlencode "a'b")"
expect_eq "urlencode: double quote and backslash" 'a%22b%5Cc' "$(http_urlencode 'a"b\c')"
expect_eq "urlencode: tab byte" "%09" "$(http_urlencode "$(printf '\t')")"
expect_eq "urlencode: newline dropped (awk parity)" "ab" "$(http_urlencode "$(printf 'a\nb')")"

# --- size_suffix_bytes ----------------------------------------------------
expect_eq "size: plain bytes" "42" "$(size_suffix_bytes 42)"
expect_eq "size: binary mega" "5242880" "$(size_suffix_bytes 5M)"
expect_eq "size: binary giga" "5368709120" "$(size_suffix_bytes 5G)"
expect_eq "size: explicit binary" "1073741824" "$(size_suffix_bytes 1Gi)"
expect_eq "size: decimal kilo" "100000" "$(size_suffix_bytes 100KB)"
expect_eq "size: fraction" "1572864" "$(size_suffix_bytes 1.5M)"
size_suffix_bytes "5Z" >/dev/null 2>&1
expect_rc "size: bad unit rejected" "$?" 1
size_suffix_bytes "" >/dev/null 2>&1
expect_rc "size: empty rejected" "$?" 1

# --- xml helpers ----------------------------------------------------------
sample='<?xml version="1.0"?>
<ocs>
  <meta><status>ok</status><statuscode>200</statuscode><message>OK &amp; then some</message></meta>
  <data>
    <element><id>1</id><path>a &lt;b&gt;.txt</path><note/></element>
    <element><id>2</id><path>two.txt</path></element>
  </data>
</ocs>'
expect_eq "xml_get: namespaced names work" "ok" "$(xml_get "$sample" status)"
expect_eq "xml_get: entities decoded" "OK & then some" "$(xml_get "$sample" message)"
expect_eq "xml_get: escaped value decoded" "a <b>.txt" "$(xml_get "$sample" path)"
expect_eq "xml_get: self-closed is empty" "" "$(xml_get "$sample" note)"
expect_eq "xml_get: absent is empty" "" "$(xml_get "$sample" missing)"
all_ids="$(xml_records_top "$sample" element id | tr '\n' ' ')"
expect_eq "xml_records_top: every value" "1 2 " "$all_ids"
walk_count=0
while IFS= read -r -d $'\x1e' block; do
  [[ -n "$block" ]] || continue
  walk_count=$((walk_count + 1))
done < <(printf '%s' "$sample" | awk -v tag=element "${_AWK_XML_LIB}"'{ doc = doc $0 } END { xml_walk_top(doc, tag, "split") }')
expect_eq "xml_walk_top: two top-level blocks" "2" "$walk_count"

# --- xml_records: one TSV record per wrapper, alternatives decoded -------
rec_xml='<d:multistatus xmlns:d="DAV:">
  <d:response><d:href>/remote.php/dav/files/alice/a%20b.txt</d:href><d:getcontentlength>12</d:getcontentlength></d:response>
  <d:response><d:href>/remote.php/dav/files/alice/c.txt</d:href></d:response>
</d:multistatus>'
expect_eq "xml_records: namespaced fields" \
  $'/remote.php/dav/files/alice/a%20b.txt\t12\n/remote.php/dav/files/alice/c.txt\t' \
  "$(xml_records "$rec_xml" d:response 'd:href|href' 'd:getcontentlength|getcontentlength')"
expect_eq "xml_wrapper_auto: element payload" "element" "$(xml_wrapper_auto '<data><element/></data>')"
expect_eq "xml_wrapper_auto: dav payload" "d:response" "$(xml_wrapper_auto '<d:multistatus/>')"

# xml_records_top must not be truncated by a nested wrapper of the same name.
nested='<data><element><id>1</id><actions><element><id>nested</id></element></actions><link>L1</link></element></data>'
expect_eq "xml_records_top: nested element stays inside parent" \
  $'1\tL1' "$(xml_records_top "$nested" element id link)"

# --- xml_fields: one pass, first non-empty alternative per group ----------
fields_xml='<r><a>1</a><b>2</b><c>3</c></r>'
expect_eq "xml_fields: multiple groups" $'1\t2\t3' "$(xml_fields "$fields_xml" a b c)"
expect_eq "xml_fields: first non-empty alternative wins" $'10' \
  "$(xml_fields '<r><oc:size>10</oc:size><d:getcontentlength>20</d:getcontentlength></r>' 'oc:size|d:getcontentlength')"
expect_eq "xml_fields: alternative falls back when empty" $'20' \
  "$(xml_fields '<r><d:getcontentlength>20</d:getcontentlength></r>' 'oc:size|d:getcontentlength')"
expect_eq "xml_fields: missing field stays empty" $'1\t\t3' \
  "$(xml_fields '<r><a>1</a><c>3</c></r>' a b c)"
expect_eq "xml_fields: entities decoded" "a <b>" \
  "$(xml_fields '<r><v>a &lt;b&gt;</v></r>' v)"
expect_eq "xml_fields: control bytes stripped" "ab" \
  "$(xml_fields "$(printf '<r><v>a\033b</v></r>')" v)"
expect_eq "xml_fields: C1 control bytes stripped" "ab" \
  "$(xml_fields "$(printf '<r><v>a\200\233b</v></r>')" v)"

# Control bytes never reach the record (terminal-escape defense).
ctrl_xml=$'<d:response><d:href>/x/a\x1b[31mb.txt</d:href></d:response>'
expect_eq "xml_records: control bytes stripped" "/x/a[31mb.txt" \
  "$(xml_records "$ctrl_xml" d:response 'd:href|href')"
expect_eq "xml_extract: control bytes stripped" "plain" "$(xml_get '<x><v>pl'"$(printf '\033')"'ain</v></x>' v)"
# C1 bytes (0x80-0x9F) are terminal-escape vectors too and must be dropped.
expect_eq "xml_extract: C1 control bytes stripped" "ab" \
  "$(xml_get "$(printf '<x><v>a\200\233b</v></x>')" v)"
expect_eq "xml_pct: C1 percent escapes dropped" "ab" \
  "$(printf '%s' 'a%80%9Bb' | awk "${_AWK_XML_LIB}"'{print xml_pct($0)}')"
# The shared ctrl_strip drops encoded C1 and invalid UTF-8 but preserves
# valid multi-byte values (the fallback byte scan runs under this UTF-8
# locale, which BWK awk's regex/split cannot).
expect_eq "xml_fields: encoded C1 C2 9B dropped" "ab" \
  "$(xml_fields "$(printf '<r><v>a\302\233b</v></r>')" v)"
expect_eq "xml_fields: overlong lead C1 9B dropped" "ab" \
  "$(xml_fields "$(printf '<r><v>a\301\233b</v></r>')" v)"
expect_eq "xml_fields: overlong E0 80 80 dropped" "ab" \
  "$(xml_fields "$(printf '<r><v>a\340\200\200b</v></r>')" v)"
expect_eq "xml_fields: surrogate ED A0 80 dropped" "ab" \
  "$(xml_fields "$(printf '<r><v>a\355\240\200b</v></r>')" v)"
expect_eq "xml_fields: out-of-range F4 90 80 80 dropped" "ab" \
  "$(xml_fields "$(printf '<r><v>a\364\220\200\200b</v></r>')" v)"
expect_eq "xml_fields: stray continuation 80 dropped" "ab" \
  "$(xml_fields "$(printf '<r><v>a\200b</v></r>')" v)"
expect_eq "xml_fields: valid UTF-8 survives" "grüße€😀" \
  "$(xml_fields '<r><v>grüße€😀</v></r>' v)"

# xml_href_segment: byte-wise percent decode (utf-8 survives), control dropped.
pct_xml='<d:response><d:href>/remote.php/dav/files/alice/F%C3%B6o%20b.txt</d:href></d:response>'
expect_eq "xml_href_segment: decoded last segment" "Föo b.txt" \
  "$(printf '%s' "$pct_xml" | awk -v tag=d:response "${_AWK_XML_LIB}"'{doc=doc $0} END{rest=doc; while((pos=index(rest,"<"tag))>0){after=substr(rest,pos+1+length(tag));gt=index(after,">");body=substr(after,gt+1);cend=index(body,"</"tag);print xml_href_segment(substr(body,1,cend-1));rest=substr(body,cend+length(tag)+2)}}')"

# --- http helpers without curl -------------------------------------------
HTTP_CODE=404
HTTP_BODY='<?xml version="1.0"?><ocs><meta><status>failure</status><statuscode>404</statuscode><message>Wrong path</message></meta></ocs>'
expect_eq "http_error_message: OCS message" "Wrong path" "$(http_error_message "$HTTP_BODY")"
ocs_parse "$HTTP_BODY"
expect_eq "ocs_parse: status" "failure" "$OCS_STATUS"
expect_eq "ocs_parse: statuscode" "404" "$OCS_STATUSCODE"
expect_eq "ocs_parse: message" "Wrong path" "$OCS_MESSAGE"

# A DAV error description is the fallback.
dav_error='<?xml version="1.0"?><d:error xmlns:d="DAV:"><d:responsedescription>Item is locked</d:responsedescription></d:error>'
expect_eq "http_error_message: DAV description" "Item is locked" "$(http_error_message "$dav_error")"

# curl's stderr is scrubbed of secrets and of every control byte (C0, DEL, C1)
# before it lands in HTTP_ERROR, so --debug output cannot inject escapes.
expect_eq "http_scrub_secrets: strips C0 and C1 control bytes" "abc" \
  "$(http_scrub_secrets "$(printf 'a\033b\200c')")"
# Encoded C1 and invalid UTF-8 go through the same shared rules, and valid
# multi-byte text survives.
expect_eq "http_scrub_secrets: drops encoded C1 C2 9B" "ab" \
  "$(http_scrub_secrets "$(printf 'a\302\233b')")"
expect_eq "http_scrub_secrets: drops overlong/surrogate/out-of-range bytes" "ab" \
  "$(http_scrub_secrets "$(printf 'a\301\233\340\200\200\355\240\200\364\220\200\200b')")"
expect_eq "http_scrub_secrets: keeps valid UTF-8" "grüße€😀" \
  "$(http_scrub_secrets 'grüße€😀')"

# --- actionable HTTP status hints in the shared request path ----------------
# The direct harness needs remote_secret_plain, exactly like bin/sciebo
# sources it. Probes run in a subshell so http_request's die() cannot end the
# suite; the stub curl serves the canned status routes.
# shellcheck disable=SC1090,SC1091
source "${PROJ}/lib/rclone.sh"

# --- http_secret: resolved once per process, dropped on invalidate ----------
# A counting resolver proves the forkless capture runs remote_secret_plain in
# the caller's shell: a subshell capture would lose the cache and never see the
# increment. Each probe runs in a command substitution, so its override and
# cache cannot leak into the request tests below.
HTTP_SECRET_PROBE_LOG="${TMP}/http-secret-probe.log"
: >"$HTTP_SECRET_PROBE_LOG"

# shellcheck disable=SC2329  # invoked indirectly via capture
http_secret_probe() {
  local out=""
  http_secret_invalidate
  remote_secret_plain() {
    printf 'x' >>"$HTTP_SECRET_PROBE_LOG"
    printf 'probe-secret'
  }
  out="$(
    http_secret
    printf '|'
    http_secret
  )"
  printf '%s' "$out"
}
expect_eq "http_secret: caches the resolved secret" \
  "probe-secret|probe-secret" "$(http_secret_probe)"
expect_eq "http_secret: resolver ran once" "1" "$(wc -c <"$HTTP_SECRET_PROBE_LOG" | tr -d ' ')"

# shellcheck disable=SC2329  # invoked indirectly via capture
http_secret_invalidate_probe() {
  (
    http_secret_invalidate
    remote_secret_plain() {
      printf 'x' >>"$HTTP_SECRET_PROBE_LOG"
      printf 'probe-secret'
    }
    http_secret >/dev/null
    http_secret_invalidate
    http_secret >/dev/null
  )
}
: >"$HTTP_SECRET_PROBE_LOG"
http_secret_invalidate_probe
expect_eq "http_secret: invalidate forces re-resolution" "2" "$(wc -c <"$HTTP_SECRET_PROBE_LOG" | tr -d ' ')"

# http_error_probe METHOD URL - run http_request against the stub and print
# the combined output; the caller reads CLI_RC.
# shellcheck disable=SC2329  # invoked indirectly via capture
http_error_probe() {
  local method="$1" url="$2"
  # shellcheck disable=SC2030,SC2031  # exports are intentionally subshell-local
  (
    export PATH="${STUB_BIN}:$PATH"
    export HTTP_BASE="http://127.0.0.1:9" HTTP_USER=alice \
      REMOTE_SECRET_PLAIN_CACHE="feature-test-secret"
    http_request "$method" "$url" 2>&1
  )
}

# http_allow_probe METHOD URL - http_request_allow leaves the status to the
# caller; print it together with the captured Retry-After header.
# shellcheck disable=SC2329  # invoked indirectly via capture
http_allow_probe() {
  local method="$1" url="$2"
  # shellcheck disable=SC2030,SC2031  # exports are intentionally subshell-local
  (
    export PATH="${STUB_BIN}:$PATH"
    export HTTP_BASE="http://127.0.0.1:9" HTTP_USER=alice \
      REMOTE_SECRET_PLAIN_CACHE="feature-test-secret"
    http_request_allow "$method" "$url" || exit 1
    printf 'code=%s retry=%s\n' "$HTTP_CODE" "${HTTP_RETRY_AFTER:-}"
  )
}

stub_reset_routes
stub_clear_calls

# 401: expired or revoked app password, pointed at setup --rotate.
stub_route GET '*/remote.php/dav/files/alice/expired' 401 <<'XML'
<?xml version="1.0"?>
<d:error xmlns:d="DAV:"><d:responsedescription>Unauthorized</d:responsedescription></d:error>
XML
capture http_error_probe GET "http://127.0.0.1:9/remote.php/dav/files/alice/expired"
expect_rc "http: 401 rc 1" "$CLI_RC" 1
expect_contains "http: 401 keeps the HTTP prefix" "$CLI_OUT" "failed: HTTP 401"
expect_contains "http: 401 explains the app password" "$CLI_OUT" "app password may have expired or been revoked"
expect_contains "http: 401 suggests setup --rotate" "$CLI_OUT" "setup --rotate"

# 403: permission check hint.
stub_route GET '*/remote.php/dav/files/alice/forbidden' 403 <<'XML'
<?xml version="1.0"?>
<d:error xmlns:d="DAV:"><d:responsedescription>Forbidden</d:responsedescription></d:error>
XML
capture http_error_probe GET "http://127.0.0.1:9/remote.php/dav/files/alice/forbidden"
expect_rc "http: 403 rc 1" "$CLI_RC" 1
expect_contains "http: 403 mentions permissions" "$CLI_OUT" "permission"

# 423: locked file, pointed at locks/unlock.
stub_route GET '*/remote.php/dav/files/alice/locked.txt' 423 <<'XML'
<?xml version="1.0"?>
<d:error xmlns:d="DAV:"><d:responsedescription>File is locked</d:responsedescription></d:error>
XML
capture http_error_probe GET "http://127.0.0.1:9/remote.php/dav/files/alice/locked.txt"
expect_rc "http: 423 rc 1" "$CLI_RC" 1
expect_contains "http: 423 says the file is locked" "$CLI_OUT" "file is locked"
expect_contains "http: 423 points at locks" "$CLI_OUT" "locks"
expect_contains "http: 423 points at unlock" "$CLI_OUT" "unlock <path>"

# 429: rate limiting, Retry-After carried into the message and the global.
printf 'Retry-After: 120\n' >"${TMP}/retry-after-429.headers"
stub_route GET '*/remote.php/dav/files/alice/limited' 429 "${TMP}/retry-after-429.headers" <<'XML'
<?xml version="1.0"?>
<d:error xmlns:d="DAV:"><d:responsedescription>Too many requests</d:responsedescription></d:error>
XML
capture http_error_probe GET "http://127.0.0.1:9/remote.php/dav/files/alice/limited"
expect_rc "http: 429 rc 1" "$CLI_RC" 1
expect_contains "http: 429 says rate limiting" "$CLI_OUT" "rate limiting"
expect_contains "http: 429 includes Retry-After" "$CLI_OUT" "Retry-After: 120"

# http_request_allow still returns 0 and leaves HTTP_CODE/HTTP_RETRY_AFTER.
capture http_allow_probe GET "http://127.0.0.1:9/remote.php/dav/files/alice/limited"
expect_rc "http: allow leaves 429 to the caller" "$CLI_RC" 0
expect_contains "http: allow keeps the status" "$CLI_OUT" "code=429"
expect_contains "http: allow captures Retry-After" "$CLI_OUT" "retry=120"

# 503: include Retry-After when present, still hint to retry otherwise.
printf 'Retry-After: 30\n' >"${TMP}/retry-after-503.headers"
stub_route GET '*/remote.php/dav/files/alice/unavailable' 503 "${TMP}/retry-after-503.headers" <<'XML'
<?xml version="1.0"?>
<d:error xmlns:d="DAV:"><d:responsedescription>Service unavailable</d:responsedescription></d:error>
XML
capture http_error_probe GET "http://127.0.0.1:9/remote.php/dav/files/alice/unavailable"
expect_rc "http: 503 rc 1" "$CLI_RC" 1
expect_contains "http: 503 says temporarily unavailable" "$CLI_OUT" "temporarily unavailable"
expect_contains "http: 503 includes Retry-After" "$CLI_OUT" "Retry-After: 30"
stub_route GET '*/remote.php/dav/files/alice/down' 503 <<'XML'
<?xml version="1.0"?>
<d:error xmlns:d="DAV:"><d:responsedescription>Service unavailable</d:responsedescription></d:error>
XML
capture http_error_probe GET "http://127.0.0.1:9/remote.php/dav/files/alice/down"
expect_contains "http: 503 without header says retry later" "$CLI_OUT" "retry later"

# 507: server storage/quota is full.
stub_route GET '*/remote.php/dav/files/alice/full' 507 <<'XML'
<?xml version="1.0"?>
<d:error xmlns:d="DAV:"><d:responsedescription>Insufficient Storage</d:responsedescription></d:error>
XML
capture http_error_probe GET "http://127.0.0.1:9/remote.php/dav/files/alice/full"
expect_rc "http: 507 rc 1" "$CLI_RC" 1
expect_contains "http: 507 names the full storage" "$CLI_OUT" "storage or quota is full"

# Additional DAV/OCS statuses get an actionable hint too.
for status_hint in \
  '409:conflict' '412:ETag mismatch' '413:too large' '415:content type' \
  '502:gateway returned' '504:gateway timed out'; do
  status="${status_hint%%:*}"
  want="${status_hint#*:}"
  stub_route GET "*/remote.php/dav/files/alice/hint-${status}" "$status" <<'XML'
<?xml version="1.0"?>
<d:error xmlns:d="DAV:"><d:responsedescription>nope</d:responsedescription></d:error>
XML
  capture http_error_probe GET "http://127.0.0.1:9/remote.php/dav/files/alice/hint-${status}"
  expect_rc "http: ${status} rc 1" "$CLI_RC" 1
  expect_contains "http: ${status} hint" "$CLI_OUT" "$want"
done

# --- namespace-tolerant and numeric-entity XML decoding --------------------
ns_xml='<x:root xmlns:x="DAV:"><x:message>hello &amp; bye</x:message></x:root>'
expect_eq "xml_get: namespace prefix tolerated" "hello & bye" "$(xml_get "$ns_xml" message)"
expect_eq "xml_get: exact prefixed tag still works" "hello & bye" "$(xml_get "$ns_xml" x:message)"
expect_eq "xml_get: fallback matches the local name exactly" "" \
  "$(xml_get '<x:root><x:myhref>v</x:myhref></x:root>' href)"
expect_eq "xml_get: decimal numeric entity decoded" "'" "$(xml_get '<x><v>&#39;</v></x>' v)"
expect_eq "xml_get: hex numeric entity decoded" "A" "$(xml_get '<x><v>&#x41;</v></x>' v)"
expect_eq "xml_get: high codepoint left literal" "&#233;" "$(xml_get '<x><v>&#233;</v></x>' v)"

# --- redirect and retry flags on the shared curl invocation ----------------
stub_reset_routes
stub_clear_calls
stub_route GET '*/remote.php/dav/files/alice/redir' 200 <<'XML'
<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"/>
XML
capture http_allow_probe GET "http://127.0.0.1:9/remote.php/dav/files/alice/redir"
expect_rc "http: GET redirect probe rc 0" "$CLI_RC" 0
expect_contains "http: GET follows redirects" "$(stub_args)" "-L"
expect_contains "http: GET bounds redirects" "$(stub_args)" "--max-redirs"
expect_contains "http: curl retries all errors" "$(stub_args)" "--retry-all-errors"
expect_contains "http: curl retry delay set" "$(stub_args)" "--retry-delay"

stub_clear_calls
stub_route PROPPATCH '*/remote.php/dav/files/alice/redir' 207 <<'XML'
<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"/>
XML
capture http_allow_probe PROPPATCH "http://127.0.0.1:9/remote.php/dav/files/alice/redir"
expect_rc "http: write probe rc 0" "$CLI_RC" 0
expect_not_contains "http: writes do not follow redirects" "$(stub_args)" " -L"

# --- http_ok_code_2xx: PROPFIND/writes reject a redirect as success --------
# curl only follows redirects for GET/HEAD, so a 3xx answer to PROPFIND or a
# write leaves an empty body and must not be treated as success.
for code in 200 201 204 207; do
  http_ok_code_2xx "$code"
  expect_rc "http_ok_code_2xx: accepts ${code}" "$?" 0
done
for code in 301 302 304 404 500 ''; do
  http_ok_code_2xx "$code"
  expect_rc "http_ok_code_2xx: rejects ${code:-empty}" "$?" 1
done

# http_method_probe METHOD URL - run http_request against the stub and print
# the combined output; the caller reads CLI_RC.
# shellcheck disable=SC2329  # invoked indirectly via capture
http_method_probe() {
  local method="$1" url="$2"
  # shellcheck disable=SC2030,SC2031  # exports are intentionally subshell-local
  (
    export PATH="${STUB_BIN}:$PATH"
    export HTTP_BASE="http://127.0.0.1:9" HTTP_USER=alice \
      REMOTE_SECRET_PLAIN_CACHE="feature-test-secret"
    http_request "$method" "$url" 2>&1
  )
}

stub_reset_routes
stub_clear_calls
stub_route PROPFIND '*/remote.php/dav/files/alice/redirect-propfind' 302 <<'XML'
<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"/>
XML
capture http_method_probe PROPFIND "http://127.0.0.1:9/remote.php/dav/files/alice/redirect-propfind"
expect_rc "http: PROPFIND redirect is a failure" "$CLI_RC" 1
expect_contains "http: PROPFIND redirect reports the status" "$CLI_OUT" "failed: HTTP 302"

stub_route PUT '*/remote.php/dav/files/alice/redirect-put' 302 <<'XML'
<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"/>
XML
capture http_method_probe PUT "http://127.0.0.1:9/remote.php/dav/files/alice/redirect-put"
expect_rc "http: write redirect is a failure" "$CLI_RC" 1
expect_contains "http: write redirect reports the status" "$CLI_OUT" "failed: HTTP 302"

stub_route GET '*/remote.php/dav/files/alice/redirect-get' 302 <<'XML'
<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"/>
XML
capture http_method_probe GET "http://127.0.0.1:9/remote.php/dav/files/alice/redirect-get"
expect_rc "http: GET redirect is still accepted" "$CLI_RC" 0

# --- client certificate / custom CA / User-Agent curl flags ----------------
TLS_DIR="${TMP}/tls-fixtures"
mkdir -p "$TLS_DIR"
printf '%s\n' '-----BEGIN CERTIFICATE-----' 'client' '-----END CERTIFICATE-----' >"${TLS_DIR}/client.pem"
printf '%s\n' '-----BEGIN PRIVATE KEY-----' 'key' '-----END PRIVATE KEY-----' >"${TLS_DIR}/client.key"
printf '%s\n' '-----BEGIN CERTIFICATE-----' 'ca' '-----END CERTIFICATE-----' >"${TLS_DIR}/ca.pem"

# http_tls_probe - http_request_allow with the TLS client settings exported.
# shellcheck disable=SC2329  # invoked indirectly via capture
http_tls_probe() {
  # shellcheck disable=SC2030,SC2031  # exports are intentionally subshell-local
  (
    export PATH="${STUB_BIN}:$PATH"
    export HTTP_BASE="http://127.0.0.1:9" HTTP_USER=alice \
      REMOTE_SECRET_PLAIN_CACHE="feature-test-secret" \
      CLIENT_CERT="${TLS_DIR}/client.pem" CLIENT_KEY="${TLS_DIR}/client.key" \
      CLIENT_KEY_PASSWORD="tls-key-secret" CA_CERT="${TLS_DIR}/ca.pem" \
      USER_AGENT="sciebo-http-test/1.0"
    http_request_allow GET "http://127.0.0.1:9/remote.php/dav/files/alice/tls" || exit 1
  )
}

stub_reset_routes
stub_clear_calls
stub_route GET '*/remote.php/dav/files/alice/tls' 200 <<'XML'
<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"/>
XML
capture http_tls_probe
expect_rc "http: client-cert probe rc 0" "$CLI_RC" 0
tls_args="$(stub_args)"
expect_contains "http: curl gets --cert" "$tls_args" "--cert ${TLS_DIR}/client.pem"
expect_contains "http: curl gets --key" "$tls_args" "--key ${TLS_DIR}/client.key"
expect_contains "http: curl gets --cacert" "$tls_args" "--cacert ${TLS_DIR}/ca.pem"
expect_contains "http: curl gets the User-Agent" "$tls_args" "-A sciebo-http-test/1.0"
expect_not_contains "http: key passphrase never in the curl argv" "$tls_args" "tls-key-secret"

# Unset settings add none of those flags.
unset CLIENT_CERT CLIENT_KEY CLIENT_KEY_PASSWORD CA_CERT USER_AGENT
stub_clear_calls
capture http_allow_probe GET "http://127.0.0.1:9/remote.php/dav/files/alice/tls"
expect_rc "http: default TLS probe rc 0" "$CLI_RC" 0
plain_args="$(stub_args)"
expect_not_contains "http: no --cert by default" "$plain_args" "--cert"
expect_not_contains "http: no --cacert by default" "$plain_args" "--cacert"
expect_not_contains "http: no User-Agent by default" "$plain_args" "-A "

# --- the client-key passphrase travels in a curl --config file -------------
# A wrapper curl records the file named by --config before delegating to the
# route stub, so the test proves the passphrase left the argv and reached curl
# through the config file.
KEY_STUB_BIN="${TMP}/key-stub-bin"
mkdir -p "$KEY_STUB_BIN"
cat >"${KEY_STUB_BIN}/curl" <<'STUB'
#!/bin/bash
args=("$@")
i=0
while ((i < ${#args[@]})); do
  case "${args[i]}" in
    -K | --config)
      j=$((i + 1))
      if [[ -n "${args[j]:-}" && -f "${args[j]}" ]]; then
        cp "${args[j]}" "${KEY_STUB_CAPTURE:?}"
      fi
      ;;
  esac
  i=$((i + 1))
done
exec "${KEY_STUB_REAL:?}" "${args[@]}"
STUB
chmod +x "${KEY_STUB_BIN}/curl"

KEY_CAPTURE="${TMP}/captured-curl-config"

# http_key_probe - http_request_allow with a client-key passphrase exported.
# shellcheck disable=SC2329  # invoked indirectly via capture
http_key_probe() {
  # shellcheck disable=SC2030,SC2031  # exports are intentionally subshell-local
  (
    export PATH="${KEY_STUB_BIN}:${STUB_BIN}:$PATH"
    export HTTP_BASE="http://127.0.0.1:9" HTTP_USER=alice \
      REMOTE_SECRET_PLAIN_CACHE="feature-test-secret" \
      CLIENT_CERT="${TLS_DIR}/client.pem" CLIENT_KEY="${TLS_DIR}/client.key" \
      CLIENT_KEY_PASSWORD="tls-key-secret" CA_CERT="${TLS_DIR}/ca.pem" \
      KEY_STUB_CAPTURE="${KEY_CAPTURE}" KEY_STUB_REAL="${STUB_BIN}/curl"
    http_request_allow GET "http://127.0.0.1:9/remote.php/dav/files/alice/tls" || exit 1
  )
}

rm -f "$KEY_CAPTURE"
stub_reset_routes
stub_clear_calls
stub_route GET '*/remote.php/dav/files/alice/tls' 200 <<'XML'
<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"/>
XML
capture http_key_probe
expect_rc "http: client-key config probe rc 0" "$CLI_RC" 0
key_args="$(stub_args)"
expect_contains "http: curl gets --config for the key passphrase" "$key_args" "--config"
expect_not_contains "http: curl argv has no --pass" "$key_args" "--pass"
expect_not_contains "http: curl argv has no key passphrase" "$key_args" "tls-key-secret"
expect_eq "http: config file carries the escaped passphrase" \
  'pass = "tls-key-secret"' "$(cat "$KEY_CAPTURE" 2>/dev/null || true)"

# --- persistent curl temps reused across calls in one top-level process ---
# http_curl creates the body/headers/err/netrc files once per process and
# reuses them. Every other probe here runs inside a command substitution
# (BASHPID != $$), which correctly falls back to per-call files, so the two
# requests below run directly in this top-level shell to exercise the reuse.
persist_url="http://127.0.0.1:9/remote.php/dav/files/alice/persist"
stub_reset_routes
stub_clear_calls
stub_route GET '*/persist' 200 <<'XML'
<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"/>
XML
sciebo_temp_cleanup
# shellcheck disable=SC2031  # top-level on purpose: exercises persistent temps
export PATH="${STUB_BIN}:$PATH"
# shellcheck disable=SC2031  # top-level on purpose: exercises persistent temps
export HTTP_BASE="http://127.0.0.1:9" HTTP_USER=alice REMOTE_SECRET_PLAIN_CACHE="persist-secret"
http_request_allow GET "$persist_url" >/dev/null 2>&1
persist_rc1=$?
http_request_allow GET "$persist_url" >/dev/null 2>&1
persist_rc2=$?
expect_rc "persistent temps: first request rc 0" "$persist_rc1" 0
expect_rc "persistent temps: second request rc 0" "$persist_rc2" 0

# arg_after FLAG LINE - print the token following FLAG in a stub args.log line.
arg_after() {
  local flag="$1" line="$2" prev="" tok=""
  for tok in $line; do
    if [[ "$prev" == "$flag" ]]; then
      printf '%s' "$tok"
      return 0
    fi
    prev="$tok"
  done
  return 1
}
{
  IFS= read -r persist_args_1
  IFS= read -r persist_args_2
} <"${STUB_BIN}/args.log"
expect_eq "persistent temps: two stub calls recorded" "2" "$(wc -l <"${STUB_BIN}/args.log" | tr -d ' ')"
expect_eq "persistent temps: body path reused" \
  "$(arg_after -o "$persist_args_1")" "$(arg_after -o "$persist_args_2")"
expect_eq "persistent temps: header path reused" \
  "$(arg_after -D "$persist_args_1")" "$(arg_after -D "$persist_args_2")"
expect_eq "persistent temps: netrc path reused" \
  "$(arg_after --netrc-file "$persist_args_1")" "$(arg_after --netrc-file "$persist_args_2")"
persist_body="$(arg_after -o "$persist_args_1")"
persist_headers="$(arg_after -D "$persist_args_1")"
persist_netrc="$(arg_after --netrc-file "$persist_args_1")"
expect_file "persistent temps: body file exists before cleanup" "$persist_body"
expect_file "persistent temps: header file exists before cleanup" "$persist_headers"
expect_file "persistent temps: netrc file exists before cleanup" "$persist_netrc"
expect_eq "persistent temps: four temp files registered" "4" "${#SCIEBO_TEMP_FILES[@]}"
sciebo_temp_cleanup
expect_no_file "persistent temps: cleanup removes the body file" "$persist_body"
expect_no_file "persistent temps: cleanup removes the header file" "$persist_headers"
expect_no_file "persistent temps: cleanup removes the netrc file" "$persist_netrc"
expect_eq "persistent temps: cleanup empties the registry" "0" "${#SCIEBO_TEMP_FILES[@]}"

# --- persistent client-key --config reused across calls in one process -----
# A top-level process creates the client-key --config file once, writes the
# passphrase into it for each request, and empties it after curl returns so the
# plaintext never sits on disk between requests; the path stays registered so a
# signal still removes the secret. A wrapper curl captures the file as curl saw
# it (before the post-request truncation), so the test can tell a rewrite from
# an empty file. Run directly in this shell like the persistent-temps block.
sciebo_temp_cleanup
_http_discard_persistent
persist_key_url="http://127.0.0.1:9/remote.php/dav/files/alice/persist-key"
persist_key_capture="${TMP}/persist-key-capture"
# shellcheck disable=SC2031  # top-level on purpose: exercises persistent temps
export PATH="${KEY_STUB_BIN}:${STUB_BIN}:$PATH" KEY_STUB_CAPTURE="$persist_key_capture" \
  KEY_STUB_REAL="${STUB_BIN}/curl"
stub_reset_routes
stub_clear_calls
stub_route GET '*/persist-key' 200 <<'XML'
<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"/>
XML
# shellcheck disable=SC2031  # top-level on purpose: exercises persistent temps
export CLIENT_KEY_PASSWORD="first-pass"
rm -f "$persist_key_capture"
http_request_allow GET "$persist_key_url" >/dev/null 2>&1
key_rc1=$?
key_args_1="$(tail -n 1 "${STUB_BIN}/args.log")"
key_cfg_1="$(arg_after --config "$key_args_1")"
expect_rc "persistent key: first request rc 0" "$key_rc1" 0
expect_eq "persistent key: config mode 600" "600" "$(file_mode "$key_cfg_1")"
expect_eq "persistent key: passphrase written for request 1" 'pass = "first-pass"' \
  "$(cat "$persist_key_capture" 2>/dev/null || true)"
expect_eq "persistent key: file emptied after request 1" "" "$(cat "$key_cfg_1" 2>/dev/null || true)"
expect_not_contains "persistent key: passphrase not in argv" "$key_args_1" "first-pass"

# The same passphrase is rewritten for the next request, because the previous
# request left the file empty; the registered config path is reused.
rm -f "$persist_key_capture"
http_request_allow GET "$persist_key_url" >/dev/null 2>&1
key_rc2=$?
key_args_2="$(tail -n 1 "${STUB_BIN}/args.log")"
key_cfg_2="$(arg_after --config "$key_args_2")"
expect_rc "persistent key: second request rc 0" "$key_rc2" 0
expect_eq "persistent key: config path reused" "$key_cfg_1" "$key_cfg_2"
expect_eq "persistent key: passphrase rewritten for request 2" 'pass = "first-pass"' \
  "$(cat "$persist_key_capture" 2>/dev/null || true)"
expect_eq "persistent key: file emptied after request 2" "" "$(cat "$key_cfg_1" 2>/dev/null || true)"
expect_eq "persistent key: five temp files registered" "5" "${#SCIEBO_TEMP_FILES[@]}"

# A changed passphrase rewrites the same file instead of adding a temp.
# shellcheck disable=SC2031  # top-level on purpose: exercises persistent temps
export CLIENT_KEY_PASSWORD="second-pass"
rm -f "$persist_key_capture"
http_request_allow GET "$persist_key_url" >/dev/null 2>&1
expect_rc "persistent key: changed-passphrase rc 0" "$?" 0
key_args_3="$(tail -n 1 "${STUB_BIN}/args.log")"
key_cfg_3="$(arg_after --config "$key_args_3")"
expect_eq "persistent key: rewrite reuses config path" "$key_cfg_1" "$key_cfg_3"
expect_eq "persistent key: rewritten passphrase" 'pass = "second-pass"' \
  "$(cat "$persist_key_capture" 2>/dev/null || true)"
expect_eq "persistent key: no extra temp after rewrite" "5" "${#SCIEBO_TEMP_FILES[@]}"

# Unsetting the passphrase drops --config and empties the file.
# shellcheck disable=SC2031  # top-level on purpose: exercises persistent temps
unset CLIENT_KEY_PASSWORD
rm -f "$persist_key_capture"
http_request_allow GET "$persist_key_url" >/dev/null 2>&1
expect_rc "persistent key: unset rc 0" "$?" 0
key_args_4="$(tail -n 1 "${STUB_BIN}/args.log")"
expect_not_contains "persistent key: no --config after unset" "$key_args_4" "--config"
expect_eq "persistent key: file emptied after unset" "" "$(cat "$key_cfg_1" 2>/dev/null || true)"

sciebo_temp_cleanup
expect_no_file "persistent key: cleanup removes the config file" "$key_cfg_1"

finish
