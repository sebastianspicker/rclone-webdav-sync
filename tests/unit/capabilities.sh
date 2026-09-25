#!/usr/bin/env bash
# capabilities.sh - capability detection and chunk sizing (lib/capabilities.sh).
# Sourced setup lives in tests/unit/common.sh; run standalone with
# `bash tests/unit/capabilities.sh`.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# --- capabilities -------------------------------------------------------
CAPS_SHOW="${TMP}/caps-show.conf"
CAPS_STUB_RCLONE="${TMP}/stub-rclone-caps"
cat >"$CAPS_STUB_RCLONE" <<STUB
#!/bin/bash
cat "${CAPS_SHOW}"
STUB
chmod +x "$CAPS_STUB_RCLONE"
printf '[testremote]\ntype = webdav\nurl = https://cloud.example.org:8443/remote.php/dav/files/alice/\nuser = alice@example.org\nvendor = nextcloud\n' >"$CAPS_SHOW"
remote_config_invalidate
RCLONE_BIN="$CAPS_STUB_RCLONE"
RCLONE_CONFIG="${TMP}/caps-rclone.conf"
RCLONE_REMOTE="testremote"
expect_eq "capabilities_base_url: reads scheme://host:port from the remote" "https://cloud.example.org:8443" "$(capabilities_base_url)"
printf '[testremote]\ntype = webdav\nurl = cloud.example.org\n' >"$CAPS_SHOW"
remote_config_invalidate
expect_err "capabilities_base_url: rc 1 for an unusable url" capabilities_base_url

caps_json_new='{"ocs":{"meta":{"status":"ok","statuscode":200,"message":"OK"},"data":{"version":{"major":31,"minor":0,"micro":2,"string":"31.0.2","edition":"","extendedSupport":false},"capabilities":{"core":{"pollinterval":60,"webdav-root":"remote.php\/webdav"},"files":{"bigfilechunking":true,"undelete":true,"chunked_upload":{"max_size":104857600,"max_parallel":3}},"dav":{"chunking":"1.0"},"checksums":{"supportedTypes":["SHA256"]}}}}}'
capabilities_parse_json "$caps_json_new"
expect_eq "capabilities_parse_json: parses the version string" "31.0.2" "$CAP_VERSION"
expect_eq "capabilities_parse_json: parses bigfilechunking" "true" "$CAP_BIGFILE_CHUNKING"
expect_eq "capabilities_parse_json: parses chunked_upload max_size" "104857600" "$CAP_CHUNK_MAX_SIZE"
expect_eq "capabilities_parse_json: parses undelete" "true" "$CAP_UNDELETE"
expect_eq "capabilities_parse_json: parses checksums" "true" "$CAP_CHECKSUMS"

caps_json_old='{"ocs":{"meta":{"status":"ok","statuscode":200,"message":"OK"},"data":{"capabilities":{"files":{"bigfilechunking":true,"undelete":false,"chunked_upload":{"max_size":10485760}}}}}}'
capabilities_parse_json "$caps_json_old"
expect_eq "capabilities_parse_json: legacy server has no version" "" "$CAP_VERSION"
expect_eq "capabilities_parse_json: legacy bigfilechunking" "true" "$CAP_BIGFILE_CHUNKING"
expect_eq "capabilities_parse_json: legacy chunk max size" "10485760" "$CAP_CHUNK_MAX_SIZE"
expect_eq "capabilities_parse_json: legacy undelete false" "false" "$CAP_UNDELETE"
expect_eq "capabilities_parse_json: legacy checksums empty" "" "$CAP_CHECKSUMS"

# shellcheck disable=SC2016  # the payload's $() and backticks are intentional literals
caps_json_evil='{"ocs":{"data":{"version":{"string":"31.0.2; touch /tmp/pwned; $(id) `id`"},"capabilities":{"bigfilechunking":true,"chunked_upload":{"max_size":104857600}}}}}'
capabilities_parse_json "$caps_json_evil"
expect_eq "capabilities_parse_json: injection sanitized to allowed characters" "31.0.2touchtmppwnedidid" "$CAP_VERSION"
for cap_var in CAP_VERSION CAP_BIGFILE_CHUNKING CAP_CHUNK_MAX_SIZE CAP_UNDELETE CAP_CHECKSUMS; do
  cap_value="${!cap_var}"
  cap_safe=1
  # shellcheck disable=SC2016  # the needles are literal metacharacters
  case "$cap_value" in
    *';'* | *'`'* | *'$('*) cap_safe=0 ;;
  esac
  if [[ "$cap_safe" -eq 1 ]]; then
    pass "capabilities_parse_json: ${cap_var} free of shell metacharacters"
  else
    fail "capabilities_parse_json: ${cap_var} free of shell metacharacters" "unsanitized metacharacters"
  fi
done

CAPS_DIR="${TMP}/caps-unit"
mkdir -p "$CAPS_DIR"
CAPABILITIES_CACHE="${CAPS_DIR}/capabilities.env"
CAPABILITIES_MAX_AGE=3600
printf 'CAP_VERSION=31.0.2\nCAP_BIGFILE_CHUNKING=true\nCAP_CHUNK_MAX_SIZE=104857600\nCAP_UNDELETE=true\nCAP_CHECKSUMS=true\nCAP_PROBED_AT=1700000000\n' >"$CAPABILITIES_CACHE"
expect_ok "capabilities_cache_fresh: fresh cache rc 0" capabilities_cache_fresh
touch -t 202001010000 "$CAPABILITIES_CACHE"
expect_err "capabilities_cache_fresh: old cache rc 1" capabilities_cache_fresh
touch "$CAPABILITIES_CACHE"
CAPABILITIES_MAX_AGE=0
expect_err "capabilities_cache_fresh: CAPABILITIES_MAX_AGE=0 is always stale" capabilities_cache_fresh
CAPABILITIES_MAX_AGE=3600

CHUNK_SIZE="50Mi"
CAPABILITIES_CHUNK_RESOLVED=0 CAPABILITIES_CHUNK_VALUE=""
expect_eq "capabilities_sync_chunk_size: CHUNK_SIZE wins" "50Mi" "$(capabilities_sync_chunk_size)"
CHUNK_SIZE=""
printf '[testremote]\ntype = webdav\nurl = https://cloud.example.org/remote.php/dav/files/alice/\nvendor = nextcloud\n' >"$CAPS_SHOW"
remote_config_invalidate
CAPABILITIES_CHUNK_RESOLVED=0 CAPABILITIES_CHUNK_VALUE=""
expect_eq "capabilities_sync_chunk_size: fresh cache supplies nextcloud chunk" "104857600" "$(capabilities_sync_chunk_size)"
printf '[testremote]\ntype = webdav\nurl = https://cloud.example.org/remote.php/dav/files/alice/\nvendor = other\n' >"$CAPS_SHOW"
remote_config_invalidate
CAPABILITIES_CHUNK_RESOLVED=0 CAPABILITIES_CHUNK_VALUE=""
expect_eq "capabilities_sync_chunk_size: non-nextcloud vendor prints nothing" "" "$(capabilities_sync_chunk_size)"

# --- capabilities_chunk_for_duration (pure) -----------------------------
expect_eq "chunk_for_duration: throughput times duration" "10485760" \
  "$(MIN_CHUNK_SIZE='' MAX_CHUNK_SIZE='' capabilities_chunk_for_duration 10 1048576 1073741824)"
expect_eq "chunk_for_duration: clamps up to MIN_CHUNK_SIZE" "52428800" \
  "$(MIN_CHUNK_SIZE=50Mi MAX_CHUNK_SIZE='' capabilities_chunk_for_duration 1 1 1073741824)"
expect_eq "chunk_for_duration: clamps down to MAX_CHUNK_SIZE" "1048576" \
  "$(MIN_CHUNK_SIZE='' MAX_CHUNK_SIZE=1Mi capabilities_chunk_for_duration 2000 1000 1073741824)"
expect_eq "chunk_for_duration: caps at the server maximum" "104857600" \
  "$(MIN_CHUNK_SIZE='' MAX_CHUNK_SIZE='' capabilities_chunk_for_duration 1000 1048576 104857600)"
expect_eq "chunk_for_duration: server maximum wins over a larger MAX_CHUNK_SIZE" "104857600" \
  "$(MIN_CHUNK_SIZE='' MAX_CHUNK_SIZE=200Mi capabilities_chunk_for_duration 1000 1048576 104857600)"
expect_eq "chunk_for_duration: MIN and MAX bounds together" "2097152" \
  "$(MIN_CHUNK_SIZE=2Mi MAX_CHUNK_SIZE=5Mi capabilities_chunk_for_duration 1 1000 104857600)"
expect_ok "chunk_for_duration: within bounds rc 0" capabilities_chunk_for_duration 10 100 100000
expect_err "chunk_for_duration: missing duration rc 1" capabilities_chunk_for_duration "" 100 1000
expect_err "chunk_for_duration: non-numeric throughput rc 1" capabilities_chunk_for_duration 10 x 1000
expect_err "chunk_for_duration: zero throughput rc 1" capabilities_chunk_for_duration 10 0 1000
expect_err "chunk_for_duration: empty max rc 1" capabilities_chunk_for_duration 10 100 ""
expect_err "chunk_for_duration: zero max rc 1" capabilities_chunk_for_duration 10 100 0

# --- capabilities_sync_chunk_size: run-level derivation -----------------
printf '[testremote]\ntype = webdav\nurl = https://cloud.example.org/remote.php/dav/files/alice/\nvendor = nextcloud\n' >"$CAPS_SHOW"
remote_config_invalidate
CHUNK_SIZE=""
MIN_CHUNK_SIZE=""
MAX_CHUNK_SIZE=""
TARGET_CHUNK_UPLOAD_DURATION=10000
TARGET_UPLOAD_THROUGHPUT=1M
BW_LIMIT_UP=""
CAPABILITIES_CHUNK_RESOLVED=0 CAPABILITIES_CHUNK_VALUE=""
expect_eq "capabilities_sync_chunk_size: derives from duration and throughput" "10485760" "$(capabilities_sync_chunk_size)"
TARGET_CHUNK_UPLOAD_DURATION=10000
TARGET_UPLOAD_THROUGHPUT=1M
BW_LIMIT_UP=2M
CAPABILITIES_CHUNK_RESOLVED=0 CAPABILITIES_CHUNK_VALUE=""
expect_eq "capabilities_sync_chunk_size: BW_LIMIT_UP wins over TARGET_UPLOAD_THROUGHPUT" "20971520" "$(capabilities_sync_chunk_size)"
TARGET_UPLOAD_THROUGHPUT=""
BW_LIMIT_UP=""
CAPABILITIES_CHUNK_RESOLVED=0 CAPABILITIES_CHUNK_VALUE=""
expect_eq "capabilities_sync_chunk_size: no throughput falls back to the capability max" "104857600" "$(capabilities_sync_chunk_size)"
TARGET_CHUNK_UPLOAD_DURATION=30s
TARGET_UPLOAD_THROUGHPUT=1M
CAPABILITIES_CHUNK_RESOLVED=0 CAPABILITIES_CHUNK_VALUE=""
expect_eq "capabilities_sync_chunk_size: suffixed duration is accepted" "31457280" "$(capabilities_sync_chunk_size)"
TARGET_CHUNK_UPLOAD_DURATION=60000
TARGET_UPLOAD_THROUGHPUT=1M
MAX_CHUNK_SIZE=10Mi
CAPABILITIES_CHUNK_RESOLVED=0 CAPABILITIES_CHUNK_VALUE=""
expect_eq "capabilities_sync_chunk_size: derived value honors MAX_CHUNK_SIZE" "10485760" "$(capabilities_sync_chunk_size)"
TARGET_CHUNK_UPLOAD_DURATION=""
TARGET_UPLOAD_THROUGHPUT=""
MIN_CHUNK_SIZE=""
MAX_CHUNK_SIZE=""

CAPABILITIES_CHUNK_RESOLVED=0 CAPABILITIES_CHUNK_VALUE=""
CAPABILITIES_CACHE=""
RCLONE_BIN=""
RCLONE_REMOTE=""
RCLONE_CONFIG=""

finish
