#!/usr/bin/env bash
# preview.sh - preview image download through the shared HTTP layer (stub
# curl): file-id resolution below the remote base, --size, file/stdout
# targets, and the 404 / unresolved-path errors.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

PREVIEW_BIN="${TMP}/preview.bin"
# No trailing newline: the byte-for-byte comparison also proves the body was
# not mangled on the way to the output file.
printf 'PNGDATA-123' >"$PREVIEW_BIN"

# preview_routes - the PROPFIND file-id response plus the preview image.
preview_routes() {
  stub_reset_routes
  stub_route PROPFIND '*remote.php/dav/files/alice/backup/notes/plan.txt' 200 <<'XML'
<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
 <d:response>
  <d:href>/remote.php/dav/files/alice/backup/notes/plan.txt</d:href>
  <d:propstat><d:prop><oc:fileid>42</oc:fileid></d:prop></d:propstat>
 </d:response>
</d:multistatus>
XML
  stub_route_file GET '*index.php/core/preview*' "$PREVIEW_BIN" 200
}

OUT="${TMP}/out.bin"
preview_routes
stub_clear_calls
expect_cli "preview: default size rc 0" 0 run_cli_nc preview notes/plan.txt --output "$OUT"
expect_file "preview: file written" "$OUT"
expect_same "preview: exact bytes" "$PREVIEW_BIN" "$OUT"
expect_contains "preview: file id resolved below the remote base" "$(stub_calls)" \
  "remote.php/dav/files/alice/backup/notes/plan.txt"
expect_contains "preview: default size 256" "$(stub_calls)" "fileId=42&x=256&y=256&a=1"
expect_contains "preview: saved confirmation" "$CLI_OUT" "saved preview"

stub_clear_calls
expect_cli "preview: --size rc 0" 0 run_cli_nc preview notes/plan.txt --output "$OUT" --size 64
expect_contains "preview: size in the URL" "$(stub_calls)" "fileId=42&x=64&y=64&a=1"

expect_cli "preview: --output - rc 0" 0 run_cli_nc preview notes/plan.txt --output -
expect_contains "preview: bytes on stdout" "$CLI_OUT" "PNGDATA-123"

rm -f "${TMP}/preview"
expect_cli "preview: DEFAULT_PREVIEW_FILE rc 0" 0 run_cli_nc preview notes/plan.txt
expect_file "preview: default file written" "${TMP}/preview"
expect_same "preview: default exact bytes" "$PREVIEW_BIN" "${TMP}/preview"

# --- binary-safe file output -------------------------------------------------
# A NUL byte must survive byte-for-byte; the old HTTP_BODY string path dropped
# it (and trailing newlines).
PREVIEW_BIN_NUL="${TMP}/preview-nul.bin"
printf 'PNG\0DATA-123' >"$PREVIEW_BIN_NUL"
preview_routes_nul() {
  stub_reset_routes
  stub_route PROPFIND '*remote.php/dav/files/alice/backup/notes/plan.txt' 200 <<'XML'
<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
 <d:response>
  <d:href>/remote.php/dav/files/alice/backup/notes/plan.txt</d:href>
  <d:propstat><d:prop><oc:fileid>42</oc:fileid></d:prop></d:propstat>
 </d:response>
</d:multistatus>
XML
  stub_route_file GET '*index.php/core/preview*' "$PREVIEW_BIN_NUL" 200
}
OUT_NUL="${TMP}/out-nul.bin"
preview_routes_nul
stub_clear_calls
expect_cli "preview: NUL body rc 0" 0 run_cli_nc preview notes/plan.txt --output "$OUT_NUL"
expect_same "preview: NUL body written intact" "$PREVIEW_BIN_NUL" "$OUT_NUL"

# --- a symlinked target is refused and left untouched ------------------------
REAL_PREVIEW="${TMP}/real-preview.bin"
LINK_PREVIEW="${TMP}/link-preview.bin"
PREVIEW_SENTINEL="${TMP}/real-preview.expected"
printf 'ORIGINAL-BYTES' >"$REAL_PREVIEW"
printf 'ORIGINAL-BYTES' >"$PREVIEW_SENTINEL"
ln -sf "$REAL_PREVIEW" "$LINK_PREVIEW"
preview_routes
stub_clear_calls
expect_cli "preview: symlink target rc 1" 1 run_cli_nc preview notes/plan.txt --output "$LINK_PREVIEW"
expect_contains "preview: symlink refused" "$CLI_OUT" "refusing to write preview through symlink"
expect_same "preview: symlink target untouched" "$PREVIEW_SENTINEL" "$REAL_PREVIEW"

# --- a failed request leaves the target and no temp file ---------------------
KEEP_TARGET="${TMP}/keep-preview.bin"
KEEP_SENTINEL="${TMP}/keep-preview.expected"
printf 'KEEP-ME' >"$KEEP_TARGET"
printf 'KEEP-ME' >"$KEEP_SENTINEL"
stub_reset_routes
stub_route PROPFIND '*remote.php/dav/files/alice/backup/notes/plan.txt' 200 <<'XML'
<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
 <d:response><d:propstat><d:prop><oc:fileid>42</oc:fileid></d:prop></d:propstat></d:response>
</d:multistatus>
XML
stub_route GET '*index.php/core/preview*' 500 <<'XML'
<?xml version="1.0"?>
<d:error xmlns:d="DAV:"><d:message>preview exploded</d:message></d:error>
XML
expect_cli "preview: failed request rc 1" 1 run_cli_nc preview notes/plan.txt --output "$KEEP_TARGET"
expect_contains "preview: failed request status" "$CLI_OUT" "HTTP 500"
expect_same "preview: failed request leaves target" "$KEEP_SENTINEL" "$KEEP_TARGET"
expect_eq "preview: failed request leaves no temp file" "" \
  "$(find "$TMP" -maxdepth 1 -name 'keep-preview.bin.tmp.*' -print -quit)"

# --- errors -----------------------------------------------------------------
stub_reset_routes
stub_route PROPFIND '*remote.php/dav/files/alice/backup/notes/plan.txt' 200 <<'XML'
<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
 <d:response><d:propstat><d:prop><oc:fileid>42</oc:fileid></d:prop></d:propstat></d:response>
</d:multistatus>
XML
stub_route GET '*index.php/core/preview*' 404 <<'XML'
<?xml version="1.0"?>
<d:error xmlns:d="DAV:"><d:message>no preview</d:message></d:error>
XML
rm -f "${TMP}/out404.bin"
expect_cli "preview: 404 rc 1" 1 run_cli_nc preview notes/plan.txt --output "${TMP}/out404.bin"
expect_contains "preview: 404 message" "$CLI_OUT" "previews are not available for this file"
expect_no_file "preview: 404 writes no file" "${TMP}/out404.bin"

stub_reset_routes
stub_route PROPFIND '*remote.php/dav/files/alice/backup/missing.bin' 200 <<'XML'
<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:"/>
XML
expect_cli "preview: unresolved path rc 1" 1 run_cli_nc preview missing.bin
expect_contains "preview: unresolved message" "$CLI_OUT" "cannot resolve a file id"

expect_cli "preview: unsafe path rc 1" 1 run_cli_nc preview ../evil
expect_contains "preview: unsafe message" "$CLI_OUT" "unsafe remote path"

expect_cli "preview: bad size rc 2" 2 run_cli_nc preview notes/plan.txt --size abc
expect_contains "preview: size usage" "$CLI_OUT" "requires a positive integer"
expect_cli "preview: unknown option rc 2" 2 run_cli_nc preview notes/plan.txt --bogus
expect_contains "preview: usage printed" "$CLI_OUT" "Usage: sciebo preview"

finish
