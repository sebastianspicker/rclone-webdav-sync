#!/usr/bin/env bash
# download.sh - file downloads over DAV (stub curl) and directory downloads
# through rclone (local alias remote): default destinations, --dry-run,
# --force, --json, --resume, binary safety, and path-traversal refusal.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

# --- directory downloads through rclone (local alias remote) ----------------
REMOTE_ROOT="${TMP}/remote"
mkdir -p "${REMOTE_ROOT}/backup/docs/sub"
printf 'hello\n' >"${REMOTE_ROOT}/backup/docs/a.txt"      # 6 bytes
printf 'nested\n' >"${REMOTE_ROOT}/backup/docs/sub/b.txt" # 7 bytes
rclone config create dlretest alias remote="$REMOTE_ROOT" --config "$RCLONE_CONFIG" >/dev/null 2>&1 || {
  echo "SKIP: cannot create temporary alias remote"
  finish
}
export RCLONE_REMOTE=dlretest FOLDERS_LOCAL_ROOT="${TMP}/folders-root"

# The manifest entry owns the default directory destination.
printf 'pull|%s|docs\n' "${TMP}/local" >"$MANIFEST_FILE"

expect_cli "download: directory rc 0" 0 run_cli download docs "${TMP}/out"
expect_file "download: directory a.txt" "${TMP}/out/a.txt"
expect_file "download: directory sub/b.txt" "${TMP}/out/sub/b.txt"
expect_contains "download: directory prints the transfer" "$CLI_OUT" "downloaded docs -> ${TMP}/out"
expect_contains "download: directory reports the file count" "$CLI_OUT" "2 file(s)"
expect_contains "download: directory reports the byte count" "$CLI_OUT" "13 bytes"

# --dry-run reports the transfer but writes nothing.
expect_cli "download: directory dry run rc 0" 0 run_cli download docs "${TMP}/out-dry" --dry-run
expect_contains "download: dry run message" "$CLI_OUT" "dry run"
expect_contains "download: dry run counts" "$CLI_OUT" "2 file(s)"
expect_no_file "download: dry run copies nothing" "${TMP}/out-dry/a.txt"

# --quiet keeps the success line off stdout.
expect_cli "download: directory quiet rc 0" 0 run_cli download docs "${TMP}/out-quiet" --quiet
expect_file "download: quiet still copies" "${TMP}/out-quiet/a.txt"
expect_not_contains "download: quiet prints no success line" "$CLI_OUT" "downloaded"

# --json gives a structured summary.
expect_cli "download: directory json rc 0" 0 run_cli download docs "${TMP}/out-json" --json
expect_contains "download: json mode" "$CLI_OUT" '"mode": "directory"'
expect_contains "download: json path" "$CLI_OUT" '"path": "docs"'
expect_contains "download: json dest" "$CLI_OUT" '"dest":'
expect_contains "download: json files" "$CLI_OUT" '"files": 2'
expect_contains "download: json bytes" "$CLI_OUT" '"bytes": 13'
expect_contains "download: json dry_run" "$CLI_OUT" '"dry_run": false'

# Without a DEST the manifest entry's local directory wins.
expect_cli "download: directory manifest destination rc 0" 0 run_cli download docs
expect_file "download: manifest destination file" "${TMP}/local/a.txt"
expect_contains "download: manifest destination output" "$CLI_OUT" "downloaded docs -> ${TMP}/local"

# --progress is accepted; because stdout is captured (not a TTY) rclone gets
# no -P. The builder's TTY branch is covered in hydrate.sh, whose helper the
# directory and rclone-file transfers share.
expect_cli "download: directory progress rc 0" 0 run_cli download docs "${TMP}/out-progress" --progress
expect_file "download: directory progress still copies" "${TMP}/out-progress/a.txt"
expect_contains "download: directory progress prints the transfer" "$CLI_OUT" "downloaded docs -> ${TMP}/out-progress"
expect_cli "download: rclone file progress rc 0" 0 run_cli download docs/a.txt "${TMP}/out-progress-a.txt" --progress
expect_file "download: rclone file progress copies" "${TMP}/out-progress-a.txt"

# --- DAV file downloads (stub curl, webtest remote) -------------------------
BIN_BODY="${TMP}/binary-body.bin"
printf '\x01\x02\x7f\x80\xfe\xffhello' >"$BIN_BODY"
BIN_SIZE="$(wc -c <"$BIN_BODY" | tr -d ' ')"
FILE_INFO_XML="${TMP}/download-file-info.xml"
cat >"$FILE_INFO_XML" <<XML
<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
  <d:response>
    <d:href>/remote.php/dav/files/alice/backup/notes/data.bin</d:href>
    <d:propstat><d:prop>
      <oc:fileid>77</oc:fileid>
      <oc:size>${BIN_SIZE}</oc:size>
      <d:getcontentlength>${BIN_SIZE}</d:getcontentlength>
    </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
  </d:response>
</d:multistatus>
XML
stub_reset_routes
stub_route_file PROPFIND '*/remote.php/dav/files/alice/backup/notes/data.bin' "$FILE_INFO_XML" 200
stub_route_file GET '*/remote.php/dav/files/alice/backup/notes/data.bin' "$BIN_BODY" 200

DEST="${TMP}/downloaded-data.bin"
expect_cli "download: file rc 0" 0 run_cli_nc download notes/data.bin "$DEST"
expect_file "download: file written" "$DEST"
expect_same "download: file bytes preserved" "$BIN_BODY" "$DEST"
expect_contains "download: file prints the transfer" "$CLI_OUT" "downloaded notes/data.bin -> ${DEST}"

# The default destination is the basename below the current directory.
rm -f "${TMP}/data.bin"
expect_cli "download: file default dest rc 0" 0 run_cli_nc download notes/data.bin
expect_contains "download: default dest named" "$CLI_OUT" "downloaded notes/data.bin -> ./data.bin"
expect_file "download: default dest written" "${TMP}/data.bin"

# DOWNLOAD_DIR replaces the current directory as the default.
export DOWNLOAD_DIR="${TMP}/dl-dir"
mkdir -p "$DOWNLOAD_DIR"
expect_cli "download: DOWNLOAD_DIR default rc 0" 0 run_cli_nc download notes/data.bin
expect_contains "download: DOWNLOAD_DIR dest named" "$CLI_OUT" "downloaded notes/data.bin -> ${DOWNLOAD_DIR}/data.bin"
expect_file "download: DOWNLOAD_DIR dest written" "${DOWNLOAD_DIR}/data.bin"
unset DOWNLOAD_DIR

# A destination that already matches the remote size is skipped; --force
# downloads it again.
cp "$BIN_BODY" "${TMP}/complete.bin"
stub_clear_calls
expect_cli "download: complete dest rc 0" 0 run_cli_nc download notes/data.bin "${TMP}/complete.bin"
expect_contains "download: complete dest skipped" "$CLI_OUT" "already complete"
expect_eq "download: complete dest sends no GET" "0" "$(stub_count '^GET')"
expect_cli "download: force rc 0" 0 run_cli_nc download notes/data.bin "${TMP}/complete.bin" --force
expect_eq "download: force sends the GET" "1" "$(stub_count '^GET')"
expect_same "download: force rewrites the file" "$BIN_BODY" "${TMP}/complete.bin"

# --resume continues a partial destination with curl's -C -.
printf 'partial' >"${TMP}/partial.bin"
stub_clear_calls
expect_cli "download: resume rc 0" 0 run_cli_nc download notes/data.bin "${TMP}/partial.bin" --resume
expect_contains "download: resume passes -C -" "$(stub_args)" "-C -"
expect_same "download: resume writes the body" "$BIN_BODY" "${TMP}/partial.bin"

# --resume on an already complete destination still skips.
stub_clear_calls
expect_cli "download: resume complete rc 0" 0 run_cli_nc download notes/data.bin "${TMP}/complete.bin" --resume
expect_contains "download: resume complete skips" "$CLI_OUT" "already complete"
expect_eq "download: resume complete sends no GET" "0" "$(stub_count '^GET')"

# --json reports the file transfer.
expect_cli "download: file json rc 0" 0 run_cli_nc download notes/data.bin "${TMP}/json.bin" --json
expect_contains "download: file json mode" "$CLI_OUT" '"mode": "file"'
expect_contains "download: file json path" "$CLI_OUT" '"path": "notes/data.bin"'
expect_contains "download: file json skipped" "$CLI_OUT" '"skipped": false'
expect_contains "download: file json bytes" "$CLI_OUT" "\"bytes\": ${BIN_SIZE}"

# A hard failure removes the partial destination.
stub_route_file GET '*/remote.php/dav/files/alice/backup/notes/broken.bin' "$BIN_BODY" 500
stub_route_file PROPFIND '*/remote.php/dav/files/alice/backup/notes/broken.bin' "$FILE_INFO_XML" 200
expect_cli "download: failing GET rc 1" 1 run_cli_nc download notes/broken.bin "${TMP}/broken.bin"
expect_no_file "download: failed GET removes the partial file" "${TMP}/broken.bin"

# A hard failure must not truncate a destination that already exists.
printf 'keep-me' >"${TMP}/keep.bin"
stub_route_file GET '*/remote.php/dav/files/alice/backup/notes/keep.bin' "$BIN_BODY" 500
stub_route_file PROPFIND '*/remote.php/dav/files/alice/backup/notes/keep.bin' "$FILE_INFO_XML" 200
expect_cli "download: failing GET over existing dest rc 1" 1 run_cli_nc download notes/keep.bin "${TMP}/keep.bin"
expect_eq "download: failed GET keeps the existing file" "keep-me" "$(cat "${TMP}/keep.bin")"

# A 3xx PROPFIND is not a successful info lookup (curl does not follow
# redirects for PROPFIND), so the path is reported as not found and no GET runs.
stub_clear_calls
stub_route_file PROPFIND '*/remote.php/dav/files/alice/backup/notes/redirect.bin' "$FILE_INFO_XML" 302
expect_cli "download: 3xx PROPFIND rc 1" 1 run_cli_nc download notes/redirect.bin "${TMP}/redirect.bin"
expect_contains "download: 3xx PROPFIND not found" "$CLI_OUT" "remote path not found"
expect_eq "download: 3xx PROPFIND sends no GET" "0" "$(stub_count '^GET')"
expect_no_file "download: 3xx PROPFIND writes nothing" "${TMP}/redirect.bin"

# A symlinked destination is refused before the GET; its target is untouched.
VICTIM="${TMP}/symlink-victim.bin"
printf 'original' >"$VICTIM"
LINK_DEST="${TMP}/symlink-dest.bin"
ln -sf "$VICTIM" "$LINK_DEST"
stub_clear_calls
expect_cli "download: symlink dest rc 1" 1 run_cli_nc download notes/data.bin "$LINK_DEST"
expect_contains "download: symlink dest refused" "$CLI_OUT" "refusing to write through symlink: ${LINK_DEST}"
expect_eq "download: symlink dest leaves target" "original" "$(cat "$VICTIM")"
expect_eq "download: symlink dest sends no GET" "0" "$(stub_count '^GET')"

# Path traversal is refused before any request.
expect_cli "download: traversal refused rc 1" 1 run_cli_nc download ../etc "${TMP}/escape"
expect_contains "download: traversal message" "$CLI_OUT" "unsafe remote path"

finish
