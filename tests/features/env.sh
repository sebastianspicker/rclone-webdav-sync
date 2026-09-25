#!/usr/bin/env bash
# env.sh - shared isolation and stub infrastructure for tests/features/*.sh.
# Sourced by feature scripts, never executed directly.
#
# Each feature script gets:
#   - a fresh temp directory with every project path redirected into it,
#   - a real rclone config with `testremote` (local) and `webtest` (webdav),
#   - a stub `curl` in PATH that serves canned responses from a route table,
#   - run_cli / expect_cli helpers in the style of tests/integration.sh.
#
# The real project config, filters, state, and remote are never touched.

set -uo pipefail

FEATURE_ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$(cd "${FEATURE_ENV_DIR}/../.." && pwd)"
TESTS_DIR="$(cd "${FEATURE_ENV_DIR}/.." && pwd)"

# The feature tree is created before any library is sourced and TMPDIR is
# redirected into it, so every child `mktemp` (probe subprocesses, and
# lib/policy.sh's scan cache) lands under $TMP and is removed in one shot.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/sciebo-feature.XXXXXX")"
export TMPDIR="$TMP"
# shellcheck disable=SC2329  # invoked through the EXIT trap
feature_cleanup() {
  # Drop the paths modules registered at source time (e.g. policy.sh's scan
  # cache) before the tree that holds them is deleted.
  if type -t sciebo_temp_cleanup >/dev/null 2>&1; then
    sciebo_temp_cleanup || true
  fi
  rm -rf "$TMP"
}
trap feature_cleanup EXIT

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../harness.sh
source "${TESTS_DIR}/harness.sh"
# Feature scripts may call the pure helpers and the HTTP/XML API directly;
# bin/sciebo is what shellcheck follows for these libraries.
# shellcheck disable=SC1090,SC1091
source "${PROJ}/lib/core.sh"
# shellcheck disable=SC1090,SC1091
source "${PROJ}/lib/http.sh"

command -v rclone >/dev/null 2>&1 || {
  echo "SKIP: rclone not installed"
  exit 0
}

# HTTP_TIMEOUT is 15s (well above the stub curl's near-instant reply) so a
# forked stub isn't mistaken for a hung request when many feature scripts
# run concurrently and briefly starve the scheduler.
export RCLONE_REMOTE=testremote RCLONE_CONFIG="${TMP}/rclone.conf" REMOTE_BASE=backup \
  PROJ="$PROJ" \
  STATE_DIR="${TMP}/state" SETTINGS_LOCAL_FILE="${TMP}/no-local.env" ENV_FILE="${TMP}/no-env.env" \
  MANIFEST_FILE="${TMP}/sources.conf" MANIFEST_GENERATED_FILE="${TMP}/sources.generated.conf" \
  ROOTS_FILE="${TMP}/roots.conf" FOLDERS_FILE="${TMP}/folders.conf" FILTER_DIR="${TMP}/filters" \
  PROFILES_DIR="${TMP}/profiles" PROFILES_STATE_DIR="${TMP}/profiles-state" \
  LAUNCHD_LABEL="de.rclone-sciebo.sync.featuretest" \
  KEYCHAIN=0 NOTIFY=0 HTTP_TIMEOUT=15 HTTP_RETRIES=1 \
  TRANSFERS=1 RETRIES=1 LOW_LEVEL_RETRIES=1 CONTIMEOUT=1s TIMEOUT=10s
mkdir -p "$FILTER_DIR"
: >"$FOLDERS_FILE"
cp "${PROJ}/config/filters/clutter.txt" "$FILTER_DIR/clutter.txt"

OBSCURED="$(rclone obscure 'feature-test-secret')"
rclone config create testremote local --config "$RCLONE_CONFIG" >/dev/null 2>&1 || {
  echo "SKIP: cannot create temporary local remote"
  exit 0
}
rclone config create webtest webdav url="http://127.0.0.1:9/remote.php/dav/files/alice/" \
  vendor=nextcloud user=alice pass="$OBSCURED" --config "$RCLONE_CONFIG" >/dev/null 2>&1

# capture CMD... - combined output in CLI_OUT, rc in CLI_RC. Both are read
# by the calling feature script after expect_cli/capture returns.
CLI_OUT=""
CLI_RC=0
# shellcheck disable=SC2034  # read by the calling feature script
capture() {
  CLI_OUT="$("$@" 2>&1)"
  CLI_RC=$?
}
expect_cli() {
  local name="$1" want="$2"
  shift 2
  capture "$@"
  expect_rc "$name" "$CLI_RC" "$want"
}
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_cli() { (cd "$TMP" && bash "${PROJ}/bin/sciebo" "$@"); }

# --- stub curl --------------------------------------------------------------
# Routes: METHOD<TAB>URL_GLOB<TAB>BODY_FILE<TAB>CODE<TAB>HEADERS_FILE (the
# last two optional). First match wins; METHOD may be `*`. The stub emulates
# the curl flags lib/http.sh uses (-D/-o/-w/-X/-H/--data*) and appends every
# call to calls.log with method, url, and request-body bytes in data.log.
STUB_BIN="${TMP}/stub-bin"
STUB_ROUTES="${TMP}/stub-routes.tsv"
STUB_SEQ=0

stub_setup() {
  mkdir -p "$STUB_BIN"
  : >"$STUB_ROUTES"
  cat >"${STUB_BIN}/curl" <<'STUB'
#!/bin/bash
dir="$(cd "$(dirname "$0")" && pwd)"
raw_args="$*"
method="GET"
url=""
headers_file=""
body_file=""
write_format=""
fail_on_error=0
data=""
header_args=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -D) headers_file="$2"; shift 2 ;;
    -o) body_file="$2"; shift 2 ;;
    -w) write_format="$2"; shift 2 ;;
    -u | --netrc-file | --max-time | --retry | --retry-delay | --retry-max-time | --connect-timeout) shift 2 ;;
    -X | --request) method="$2"; shift 2 ;;
    -H) header_args="${header_args}${2}"$'\n'; shift 2 ;;
    --data-binary | --data | --data-raw | --data-urlencode)
      data="$2"
      [[ "$data" == "@-" ]] && data="$(cat)"
      shift 2
      ;;
    -f | --fail) fail_on_error=1; shift ;;
    -I | --head) method="HEAD"; shift ;;
    -sS | -fsS | -s | -S | --silent | --show-error | --retry-connrefused | --get | -L | --location) shift ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s\n' "$raw_args" >>"${dir}/args.log"
[[ -n "$data" ]] && printf '%s' "$data" >"${dir}/data.log" || : >"${dir}/data.log"
printf '%s\t%s\t%s\n' "$method" "$url" "$(printf '%s' "$data" | tr '\n' ' ')" >>"${dir}/calls.log"

route_code=""
route_body=""
route_headers=""
if [[ -f "${dir}/routes.tsv" ]]; then
  while IFS=$'\t' read -r rmethod rglob rbody rcode rheaders; do
    [[ -n "$rmethod" ]] || continue
    [[ "$rmethod" == "$method" || "$rmethod" == "*" ]] || continue
    # shellcheck disable=SC2254  # globs are intentional
    case "$url" in
      $rglob)
        route_body="$rbody"
        route_code="${rcode:-200}"
        route_headers="$rheaders"
        break
        ;;
    esac
  done <"${dir}/routes.tsv"
fi

if [[ -z "$route_code" ]]; then
  route_code=404
  route_body="${dir}/stub-404.xml"
  printf '<?xml version="1.0"?>\n<d:error xmlns:d="DAV:" xmlns:s="http://sabredav.org/ns"><s:message>stub: no route for %s %s</s:message></d:error>\n' \
    "$method" "$url" >"$route_body"
fi

if [[ "$fail_on_error" -eq 1 && "$route_code" -ge 400 ]]; then
  printf 'curl: (22) The requested URL returned error: %s\n' "$route_code" >&2
  exit 22
fi

if [[ -n "$body_file" && "$body_file" != "-" ]]; then
  cat "$route_body" >"$body_file"
else
  cat "$route_body"
fi
if [[ -n "$headers_file" ]]; then
  if [[ -n "$route_headers" && -f "$route_headers" ]]; then
    cat "$route_headers" >"$headers_file"
  else
    : >"$headers_file"
  fi
  printf 'HTTP/1.1 %s Stub\r\n' "$route_code" >>"$headers_file"
fi
if [[ -n "$write_format" ]]; then
  printf '%s' "$write_format" | sed "s/%{http_code}/${route_code}/g"
fi
exit 0
STUB
  chmod +x "${STUB_BIN}/curl"
}

# stub_route METHOD URL_GLOB [CODE] [HEADERS_FILE] - body from stdin.
stub_route() {
  local method="$1" glob="$2" code="${3:-200}" headers="${4:-}"
  STUB_SEQ=$((STUB_SEQ + 1))
  local body="${TMP}/stub-body-${STUB_SEQ}"
  cat >"$body"
  printf '%s\t%s\t%s\t%s\t%s\n' "$method" "$glob" "$body" "$code" "$headers" >>"$STUB_ROUTES"
  cp "$STUB_ROUTES" "${STUB_BIN}/routes.tsv"
}

# stub_route_file METHOD URL_GLOB FILE [CODE] [HEADERS_FILE]
stub_route_file() {
  local method="$1" glob="$2" file="$3" code="${4:-200}" headers="${5:-}"
  printf '%s\t%s\t%s\t%s\t%s\n' "$method" "$glob" "$file" "$code" "$headers" >>"$STUB_ROUTES"
  cp "$STUB_ROUTES" "${STUB_BIN}/routes.tsv"
}

stub_reset_routes() {
  : >"$STUB_ROUTES"
  cp "$STUB_ROUTES" "${STUB_BIN}/routes.tsv"
}

# stub_clear_calls - truncate the call, args, and data logs.
stub_clear_calls() {
  : >"${STUB_BIN}/calls.log"
  : >"${STUB_BIN}/data.log"
  : >"${STUB_BIN}/args.log"
}

stub_calls() { cat "${STUB_BIN}/calls.log" 2>/dev/null || true; }
stub_data() { cat "${STUB_BIN}/data.log" 2>/dev/null || true; }
stub_args() { cat "${STUB_BIN}/args.log" 2>/dev/null || true; }
# stub_count GLOB - number of logged call lines matching GLOB.
stub_count() {
  local n=0
  n="$(grep -c -- "$1" "${STUB_BIN}/calls.log" 2>/dev/null || true)"
  printf '%s' "${n:-0}"
}

# run_cli_nc - run the CLI with the stub curl in PATH and the webtest
# remote (Nextcloud-style URL) selected.
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_cli_nc() {
  (cd "$TMP" && env PATH="${STUB_BIN}:$PATH" RCLONE_REMOTE=webtest bash "${PROJ}/bin/sciebo" "$@")
}
# run_cli_plain - run with the stub curl but a non-Nextcloud remote.
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_cli_plain() {
  (cd "$TMP" && env PATH="${STUB_BIN}:$PATH" RCLONE_REMOTE=plainwebdav bash "${PROJ}/bin/sciebo" "$@")
}
rclone config create plainwebdav webdav url="http://127.0.0.1:9/dav/" \
  user=alice pass="$OBSCURED" --config "$RCLONE_CONFIG" >/dev/null 2>&1

stub_setup
