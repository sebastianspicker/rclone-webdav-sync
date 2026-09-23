#!/usr/bin/env bash
# trash_ops.sh - trash restore/rm/empty through the shared HTTP layer (stub
# curl): MOVE/DELETE request shapes, the Destination header, the item count,
# and the confirmation guards.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

# The stub records method/url/body but not request headers; wrap it so the
# restore tests can assert the Destination header too (same pattern as
# tests/features/lock.sh).
STUB_REAL="${STUB_BIN}/curl.real"
cp "${STUB_BIN}/curl" "$STUB_REAL"
{
  printf '#!/bin/bash\n'
  printf 'printf "%%s\\n" "$@" >>"%s"\n' "${TMP}/curl-args.log"
  printf 'exec "%s" "$@"\n' "$STUB_REAL"
} >"${STUB_BIN}/curl"
chmod +x "${STUB_BIN}/curl"
curl_args() { cat "${TMP}/curl-args.log" 2>/dev/null || true; }
curl_args_clear() { : >"${TMP}/curl-args.log"; }

# Canned PROPFIND multistatus: the collection itself plus two trashed items.
# A fixture file keeps stub_route out of a pipeline (its STUB_SEQ counter is
# per-shell, so a piped call would reuse and overwrite body files).
TRASH_LISTING_XML="${TMP}/trash-listing.xml"
cat >"$TRASH_LISTING_XML" <<'XML'
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
  <d:response>
    <d:href>/remote.php/dav/trashbin/alice/trash/report.pdf.d1700000001</d:href>
    <d:propstat><d:prop>
      <oc:trashbin-original-filename>report.pdf</oc:trashbin-original-filename>
      <oc:trashbin-original-location>docs/report.pdf</oc:trashbin-original-location>
      <oc:trashbin-delete-timestamp>1700000001</oc:trashbin-delete-timestamp>
      <d:getcontentlength>4096</d:getcontentlength>
    </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
  </d:response>
</d:multistatus>
XML

# --- list: the subcommand form of the read-only listing ----------------------
stub_reset_routes
stub_clear_calls
stub_route_file PROPFIND '*/remote.php/dav/trashbin/alice/trash' "$TRASH_LISTING_XML" 207

expect_cli "list: rc 0" 0 run_cli_nc trash list </dev/null
expect_contains "list: name shown" "$CLI_OUT" "plan.txt"
expect_contains "list: second name shown" "$CLI_OUT" "report.pdf"
expect_eq "list: one PROPFIND" "1" "$(stub_count $'PROPFIND\t')"

# --- restore one ID: MOVE with an absolute Destination -----------------------
stub_reset_routes
stub_clear_calls
curl_args_clear
stub_route MOVE '*/remote.php/dav/trashbin/alice/trash/plan.txt.d1700000000' 201 </dev/null

expect_cli "restore: rc 0" 0 run_cli_nc trash restore plan.txt.d1700000000 </dev/null
expect_contains "restore: prints restored" "$CLI_OUT" "restored plan.txt.d1700000000"
expect_contains "restore: MOVE logged" "$(stub_calls)" \
  $'MOVE\thttp://127.0.0.1:9/remote.php/dav/trashbin/alice/trash/plan.txt.d1700000000'
expect_contains "restore: Destination header" "$(curl_args)" \
  "Destination: http://127.0.0.1:9/remote.php/dav/trashbin/alice/restore/plan.txt.d1700000000"
expect_eq "restore: exactly one MOVE" "1" "$(stub_count $'MOVE\t')"

# --- restore two IDs: one MOVE each ------------------------------------------
stub_reset_routes
stub_clear_calls
curl_args_clear
stub_route MOVE '*/remote.php/dav/trashbin/alice/trash/*' 204 </dev/null

expect_cli "restore: two IDs rc 0" 0 run_cli_nc trash restore plan.txt.d1700000000 report.pdf.d1700000001 </dev/null
expect_contains "restore: first restored" "$CLI_OUT" "restored plan.txt.d1700000000"
expect_contains "restore: second restored" "$CLI_OUT" "restored report.pdf.d1700000001"
expect_eq "restore: two MOVEs" "2" "$(stub_count $'MOVE\t')"
expect_contains "restore: first destination" "$(curl_args)" \
  "Destination: http://127.0.0.1:9/remote.php/dav/trashbin/alice/restore/plan.txt.d1700000000"
expect_contains "restore: second destination" "$(curl_args)" \
  "Destination: http://127.0.0.1:9/remote.php/dav/trashbin/alice/restore/report.pdf.d1700000001"

# --- restore --all: fresh listing first, then one MOVE per item ---------------
stub_reset_routes
stub_clear_calls
curl_args_clear
stub_route_file PROPFIND '*/remote.php/dav/trashbin/alice/trash' "$TRASH_LISTING_XML" 207
stub_route MOVE '*/remote.php/dav/trashbin/alice/trash/*' 207 </dev/null

expect_cli "restore --all: rc 0" 0 run_cli_nc trash restore --all --yes </dev/null
expect_contains "restore --all: first restored" "$CLI_OUT" "restored plan.txt.d1700000000"
expect_contains "restore --all: second restored" "$CLI_OUT" "restored report.pdf.d1700000001"
expect_eq "restore --all: one PROPFIND" "1" "$(stub_count $'PROPFIND\t')"
expect_eq "restore --all: two MOVEs" "2" "$(stub_count $'MOVE\t')"
# The listing must come before the transfers (the shared HTTP layer may probe
# curl itself first, so compare the first PROPFIND against the first MOVE).
first_propfind="$(stub_calls | awk '$1 == "PROPFIND" { print NR; exit }')"
first_move="$(stub_calls | awk '$1 == "MOVE" { print NR; exit }')"
expect_eq "restore --all: listing first" "yes" \
  "$([[ -n "$first_propfind" && -n "$first_move" && "$first_propfind" -lt "$first_move" ]] && printf 'yes' || printf 'no')"

# --- rm: DELETE the item; --yes skips the TTY confirmation --------------------
stub_reset_routes
stub_clear_calls
stub_route DELETE '*/remote.php/dav/trashbin/alice/trash/plan.txt.d1700000000' 204 </dev/null

expect_cli "rm: rc 0" 0 run_cli_nc trash rm --yes plan.txt.d1700000000 </dev/null
expect_contains "rm: prints removed" "$CLI_OUT" "removed plan.txt.d1700000000"
expect_contains "rm: DELETE logged" "$(stub_calls)" \
  $'DELETE\thttp://127.0.0.1:9/remote.php/dav/trashbin/alice/trash/plan.txt.d1700000000'
expect_eq "rm: exactly one DELETE" "1" "$(stub_count $'DELETE\t')"
expect_not_contains "rm: --yes does not prompt" "$CLI_OUT" "Permanently delete"

# Without --yes and without a TTY the delete proceeds as before.
stub_reset_routes
stub_clear_calls
stub_route DELETE '*/remote.php/dav/trashbin/alice/trash/report.pdf.d1700000001' 204 </dev/null

expect_cli "rm: non-interactive rc 0" 0 run_cli_nc trash rm report.pdf.d1700000001 </dev/null
expect_contains "rm: non-interactive prints removed" "$CLI_OUT" "removed report.pdf.d1700000001"
expect_eq "rm: non-interactive one DELETE" "1" "$(stub_count $'DELETE\t')"
expect_not_contains "rm: non-interactive does not prompt" "$CLI_OUT" "Permanently delete"

# --- empty: DELETE the collection, count from the listing ---------------------
stub_reset_routes
stub_clear_calls
stub_route_file PROPFIND '*/remote.php/dav/trashbin/alice/trash' "$TRASH_LISTING_XML" 207
stub_route DELETE '*/remote.php/dav/trashbin/alice/trash' 204 </dev/null

expect_cli "empty: rc 0" 0 run_cli_nc trash empty --yes </dev/null
expect_contains "empty: prints count" "$CLI_OUT" "emptied the trashbin (2 item(s))"
expect_contains "empty: DELETE logged" "$(stub_calls)" \
  $'DELETE\thttp://127.0.0.1:9/remote.php/dav/trashbin/alice/trash'
expect_eq "empty: one PROPFIND before delete" "1" "$(stub_count $'PROPFIND\t')"
expect_eq "empty: one DELETE" "1" "$(stub_count $'DELETE\t')"

# --- guards: confirmations, unknown items, invalid IDs ------------------------
stub_reset_routes
stub_clear_calls
stub_route_file PROPFIND '*/remote.php/dav/trashbin/alice/trash' "$TRASH_LISTING_XML" 207
stub_route DELETE '*/remote.php/dav/trashbin/alice/trash' 204 </dev/null

expect_cli "empty: non-TTY needs --yes" 2 run_cli_nc trash empty </dev/null
expect_contains "empty: --yes hint" "$CLI_OUT" "--yes"
expect_eq "empty: no request without --yes" "0" "$(stub_count $'PROPFIND\t')"

expect_cli "restore --all: non-TTY needs --yes" 2 run_cli_nc trash restore --all </dev/null
expect_contains "restore --all: --yes hint" "$CLI_OUT" "--yes"

stub_reset_routes
stub_clear_calls
expect_cli "restore: unknown item rc 1" 1 run_cli_nc trash restore ghost.txt.d1 </dev/null
expect_contains "restore: missing item message" "$CLI_OUT" "no such trash item"
expect_contains "restore: 404 visible" "$CLI_OUT" "404"
expect_not_contains "restore: nothing restored" "$CLI_OUT" "restored"

expect_cli "rm: unknown item rc 1" 1 run_cli_nc trash rm ghost.txt.d1 </dev/null
expect_contains "rm: missing item message" "$CLI_OUT" "no such trash item"
expect_contains "rm: 404 visible" "$CLI_OUT" "404"

stub_clear_calls
expect_cli "restore: no ID rc 2" 2 run_cli_nc trash restore </dev/null
expect_cli "rm: no ID rc 2" 2 run_cli_nc trash rm </dev/null
expect_cli "restore: ../x rc 2" 2 run_cli_nc trash restore ../x </dev/null
expect_contains "restore: ../x message" "$CLI_OUT" "invalid trash item id"
expect_cli "restore: a/b rc 2" 2 run_cli_nc trash restore a/b </dev/null
expect_contains "restore: a/b message" "$CLI_OUT" "invalid trash item id"
expect_cli "rm: ../x rc 2" 2 run_cli_nc trash rm ../x </dev/null
expect_eq "invalid IDs send no request" "0" "$(stub_count $'\t')"

finish
