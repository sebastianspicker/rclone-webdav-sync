#!/usr/bin/env bash
# trash_versions_mount.sh - trash/versions XML parsing and build_mount_argv (lib/commands/trash.sh, versions.sh, mount.sh).
# Sourced setup lives in tests/unit/common.sh; run standalone with
# `bash tests/unit/trash_versions_mount.sh`.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# --- trash / versions / mount command libraries -------------------------
# The modules are sourced without RCLONE_BIN; their parsers and
# build_mount_argv are pure, and the argv probe runs in a clean subprocess.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/commands/trash.sh
source "${LIB_DIR}/commands/trash.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/commands/versions.sh
source "${LIB_DIR}/commands/versions.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/commands/mount.sh
source "${LIB_DIR}/commands/mount.sh"

# trash_parse_xml: TAB records, entity decoding, missing properties,
# percent-escaped hrefs, and the root collection row (the CLI skips it
# because the parsed name is empty).
trash_xml='<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
  <d:response>
    <d:href>/remote.php/dav/trashbin/alice/trash/</d:href>
    <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/dav/trashbin/alice/trash/Q&amp;A report.txt.d1700000000</d:href>
    <d:propstat><d:prop>
      <oc:trashbin-original-filename>Q&amp;A report.txt</oc:trashbin-original-filename>
      <oc:trashbin-original-location>docs/Q&amp;A report.txt</oc:trashbin-original-location>
      <oc:trashbin-delete-timestamp>1700000000</oc:trashbin-delete-timestamp>
      <d:getcontentlength>2048</d:getcontentlength>
    </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/dav/trashbin/alice/trash/notes.txt.d1700000100</d:href>
    <d:propstat><d:prop>
      <oc:trashbin-original-filename>notes.txt</oc:trashbin-original-filename>
      <oc:trashbin-original-location>notes.txt</oc:trashbin-original-location>
    </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/dav/trashbin/alice/trash/Vertr%C3%A4ge.d1700000200</d:href>
    <d:propstat><d:prop>
      <oc:trashbin-original-filename>Verträge</oc:trashbin-original-filename>
      <oc:trashbin-original-location>Verträge</oc:trashbin-original-location>
      <oc:trashbin-delete-timestamp>1700000200</oc:trashbin-delete-timestamp>
      <d:getcontentlength>99</d:getcontentlength>
    </d:prop></d:propstat>
  </d:response>
</d:multistatus>'
want=$'\t\t\t\ttrash'
want="${want}"$'\n'"Q&A report.txt"$'\t'"docs/Q&A report.txt"$'\t1700000000\t2048\t'"Q&A report.txt.d1700000000"
want="${want}"$'\n'"notes.txt"$'\tnotes.txt\t\t\tnotes.txt.d1700000100'
want="${want}"$'\n'"Verträge"$'\t'"Verträge"$'\t1700000200\t99\tVerträge.d1700000200'
expect_eq "trash_parse_xml: TAB records with escapes and gaps" "$want" "$(trash_parse_xml "$trash_xml")"
expect_contains "trash_parse_xml: root collection row kept by the parser" \
  "$(trash_parse_xml "$trash_xml")" $'\t\t\t\ttrash'
expect_contains "trash_parse_xml: percent-escaped href decoded" \
  "$(trash_parse_xml "$trash_xml")" "Verträge.d1700000200"

# Hostile XML values must stay literal: the parser only reads and prints.
hostile_trash="<d:multistatus><d:response><d:href>/remote.php/dav/trashbin/alice/trash/x.d1</d:href><d:propstat><d:prop><oc:trashbin-original-filename>\$(touch ${TMP}/trash-pwned) \`touch ${TMP}/trash-pwned\`</oc:trashbin-original-filename></d:prop></d:propstat></d:response></d:multistatus>"
hostile_out="$(trash_parse_xml "$hostile_trash")"
expect_contains "trash_parse_xml: hostile payload stays literal" "$hostile_out" "\$(touch ${TMP}/trash-pwned)"
expect_no_file "trash_parse_xml: hostile payload never executes" "${TMP}/trash-pwned"

# versions_parse_fileid: numeric ids, multiline tags, self-closed tags.
expect_eq "versions_parse_fileid: numeric id" "12345" \
  "$(versions_parse_fileid '<d:multistatus><d:response><d:propstat><d:prop><oc:fileid>12345</oc:fileid></d:prop></d:propstat></d:response></d:multistatus>')"
expect_eq "versions_parse_fileid: multiline id" "12345" \
  "$(versions_parse_fileid "$(printf '<oc:fileid>\n  12345  \n</oc:fileid>')")"
expect_eq "versions_parse_fileid: self-closed tag is empty" "" "$(versions_parse_fileid '<oc:fileid/>')"
expect_eq "versions_parse_fileid: missing property is empty" "" "$(versions_parse_fileid '<d:multistatus/>')"
expect_eq "versions_parse_fileid: non-numeric value is empty" "" "$(versions_parse_fileid '<oc:fileid>abc</oc:fileid>')"

# versions_parse_xml: full and missing sizes; the parser keeps the
# collection row (cmd_versions skips it when version == fileid).
versions_xml='<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/remote.php/dav/versions/alice/versions/42/</d:href>
    <d:propstat><d:prop>
      <d:getlastmodified>Wed, 01 Nov 2023 00:00:00 GMT</d:getlastmodified>
    </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
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
    </d:prop></d:propstat>
  </d:response>
</d:multistatus>'
want=$'42\tWed, 01 Nov 2023 00:00:00 GMT\t'
want="${want}"$'\n1700000000\tWed, 01 Nov 2023 01:00:00 GMT\t1024'
want="${want}"$'\n1700000100\tWed, 01 Nov 2023 02:00:00 GMT\t'
expect_eq "versions_parse_xml: TAB records with a missing size" "$want" "$(versions_parse_xml "$versions_xml")"
expect_contains "versions_parse_xml: collection row carries the fileid" "$(versions_parse_xml "$versions_xml")" "42"

# build_mount_argv filter additions (probe in a clean subprocess, with an
# isolated filter dir and manifest so the pair filter lookup is exercised).
MOUNT_PROBE_DIR="${TMP}/mount-probe"
mkdir -p "${MOUNT_PROBE_DIR}/filters"
printf '# clutter\n' >"${MOUNT_PROBE_DIR}/filters/clutter.txt"
printf '# pair\n' >"${MOUNT_PROBE_DIR}/filters/pair-probe.txt"
printf 'sync|/tmp/probe-src|pair-probe|pair-probe.txt\n' >"${MOUNT_PROBE_DIR}/sources.conf"
: >"${MOUNT_PROBE_DIR}/folders.conf"
: >"${MOUNT_PROBE_DIR}/sources.generated.conf"
# mount_args_probe FOLDER [ENV=...]... - print one argument per line from
# build_mount_argv with MNT_FOLDER=FOLDER; ENV overrides the probe defaults
# (FILTER_DIR, the manifest files, MOUNT_FILTERS, MOUNT_NO_SYNC).
mount_args_probe() {
  local folder="$1"
  shift
  # shellcheck disable=SC2016  # the -c program expands "$1" itself
  env "MNT_PROBE_FOLDER=$folder" "$@" bash -c '
    set -uo pipefail
    source "$1/lib/sciebo.sh"
    source "$1/lib/commands/mount.sh"
    MNT_FOLDER="$MNT_PROBE_FOLDER"
    MNT_NAME=probe MNT_SPEC="remote:base/${MNT_PROBE_FOLDER}"
    MNT_PATH=/tmp/probe-mnt MNT_FOREGROUND=false MNT_RO=false MNT_SUDO=false MNT_MODE=rw
    MOUNT_CACHE_DIR=/tmp/probe-cache MOUNT_CACHE_MAX_SIZE=5G
    LOG_DIR=/tmp/probe-logs MOUNT_EXTRA_FLAGS=""
    build_mount_argv
    printf "%s\n" "${MNT_ARGV[@]}"
  ' mount-args-probe "$PROJ_DIR" 2>&1
}
mount_probe_env=(
  RCLONE_BIN=/bin/true RCLONE_CONFIG=/tmp/probe-rclone.conf
  "FILTER_DIR=${MOUNT_PROBE_DIR}/filters" "MANIFEST_FILE=${MOUNT_PROBE_DIR}/sources.conf"
  "FOLDERS_FILE=${MOUNT_PROBE_DIR}/folders.conf"
  "MANIFEST_GENERATED_FILE=${MOUNT_PROBE_DIR}/sources.generated.conf"
)
out="$(mount_args_probe pair-probe "${mount_probe_env[@]}" MOUNT_FILTERS=1 MOUNT_NO_SYNC=1)"
expect_contains "build_mount_argv: clutter filter recorded" "$out" $'--filter-from\n'"${MOUNT_PROBE_DIR}/filters/clutter.txt"
expect_contains "build_mount_argv: pair filter recorded" "$out" $'--filter-from\n'"${MOUNT_PROBE_DIR}/filters/pair-probe.txt"
expect_contains "build_mount_argv: .nosync marker recorded" "$out" $'--exclude-if-present\n.nosync'
out="$(mount_args_probe pair-probe "${mount_probe_env[@]}" MOUNT_FILTERS=0 MOUNT_NO_SYNC=0)"
expect_not_contains "build_mount_argv: no filters when disabled" "$out" "--filter-from"
expect_not_contains "build_mount_argv: no .nosync marker when disabled" "$out" "--exclude-if-present"
out="$(mount_args_probe other-probe "${mount_probe_env[@]}" MOUNT_FILTERS=1 MOUNT_NO_SYNC=0)"
expect_contains "build_mount_argv: clutter filter for another folder" "$out" "${MOUNT_PROBE_DIR}/filters/clutter.txt"
expect_not_contains "build_mount_argv: no pair filter for a different folder" "$out" "pair-probe.txt"

finish
