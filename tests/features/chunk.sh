#!/usr/bin/env bash
# chunk.sh - run-level upload chunk resolution: CHUNK_SIZE wins, a
# duration+throughput derivation reaches the rclone argv, and the capability
# maximum is the fallback. A stub rclone logs the built argv and reports a
# nextcloud config, so no transfer happens.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

CHUNK_SRC="${TMP}/chunk-src"
mkdir -p "$CHUNK_SRC"
printf 'data\n' >"${CHUNK_SRC}/file.txt"
cat >"$MANIFEST_FILE" <<EOF
sync|${CHUNK_SRC}|chunk-sync
EOF

# A fresh capabilities cache with a 100Mi server maximum; the stub rclone
# reports a nextcloud vendor so capabilities_sync_chunk_size accepts it.
mkdir -p "$STATE_DIR"
{
  printf 'CAP_VERSION=31.0.2\n'
  printf 'CAP_BIGFILE_CHUNKING=true\n'
  printf 'CAP_CHUNK_MAX_SIZE=104857600\n'
  printf 'CAP_UNDELETE=true\n'
  printf 'CAP_CHECKSUMS=true\n'
  printf 'CAP_PROBED_AT=%s\n' "$(date +%s)"
} >"${STATE_DIR}/capabilities.env"

CHUNK_STUB="${TMP}/chunk-rclone-bin"
CHUNK_ARGV="${TMP}/chunk-rclone.argv"
mkdir -p "$CHUNK_STUB"
cat >"${CHUNK_STUB}/rclone" <<'STUB'
#!/bin/bash
seen_config=0
seen_show=0
for arg in "$@"; do
  case "$arg" in
    version)
      printf 'rclone v1.75.1\n'
      exit 0
      ;;
    listremotes)
      printf 'testremote:\n'
      exit 0
      ;;
    config) seen_config=1 ;;
    show) seen_show=1 ;;
  esac
done
if [[ "$seen_config" -eq 1 && "$seen_show" -eq 1 ]]; then
  printf '[testremote]\ntype = webdav\nurl = https://cloud.example.org/\nvendor = nextcloud\n'
  exit 0
fi
printf '%s\n' "$*" >>"${CHUNK_ARGV:-/dev/null}"
exit 0
STUB
chmod +x "${CHUNK_STUB}/rclone"

# shellcheck disable=SC2329  # invoked indirectly via expect_cli
run_cli_chunk() {
  (cd "$TMP" && env PATH="${CHUNK_STUB}:$PATH" RCLONE_BIN="${CHUNK_STUB}/rclone" CHUNK_ARGV="$CHUNK_ARGV" bash "${PROJ}/bin/sciebo" "$@")
}

TARGET_CHUNK_UPLOAD_DURATION=60000
TARGET_UPLOAD_THROUGHPUT=""
BW_LIMIT_UP=""
CHUNK_SIZE=""

# CHUNK_SIZE wins over any derivation.
export CHUNK_SIZE=7Mi
: >"$CHUNK_ARGV"
expect_cli "chunk: CHUNK_SIZE run rc 0" 0 run_cli_chunk sync --dry-run --only chunk-sync
expect_contains "chunk: CHUNK_SIZE reaches the argv" "$(cat "$CHUNK_ARGV")" "--webdav-nextcloud-chunk-size 7Mi"
unset CHUNK_SIZE

# 60000ms (60s) at 1M/s derives 60Mi, below the 100Mi server maximum.
export TARGET_CHUNK_UPLOAD_DURATION=60000 TARGET_UPLOAD_THROUGHPUT=1M
: >"$CHUNK_ARGV"
expect_cli "chunk: derived run rc 0" 0 run_cli_chunk sync --dry-run --only chunk-sync
expect_contains "chunk: derived value reaches the argv" "$(cat "$CHUNK_ARGV")" "--webdav-nextcloud-chunk-size 62914560"

# BW_LIMIT_UP is the effective throughput and wins over the setting: with
# 500K/s the target alone would derive 30Mi, with 1M/s it derives 60Mi.
export TARGET_UPLOAD_THROUGHPUT=500K BW_LIMIT_UP=1M
: >"$CHUNK_ARGV"
expect_cli "chunk: BW_LIMIT_UP run rc 0" 0 run_cli_chunk sync --dry-run --only chunk-sync
expect_contains "chunk: BW_LIMIT_UP wins" "$(cat "$CHUNK_ARGV")" "--webdav-nextcloud-chunk-size 62914560"
expect_not_contains "chunk: target throughput is ignored when BW_LIMIT_UP is set" "$(cat "$CHUNK_ARGV")" "--webdav-nextcloud-chunk-size 30720000"
unset BW_LIMIT_UP

# Without a throughput the capability maximum is used.
unset TARGET_UPLOAD_THROUGHPUT
: >"$CHUNK_ARGV"
expect_cli "chunk: fallback run rc 0" 0 run_cli_chunk sync --dry-run --only chunk-sync
expect_contains "chunk: capability max is the fallback" "$(cat "$CHUNK_ARGV")" "--webdav-nextcloud-chunk-size 104857600"
unset TARGET_CHUNK_UPLOAD_DURATION

finish
