#!/usr/bin/env bash
# proxy.sh - PROXY/PROXY_DIRECT handling in rclone and curl helpers.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

# rclone_proxy_resolved - print the _rclone_proxy_resolve out-params as
# "strip|flag|value|env" so the mapping can be asserted directly.
rclone_proxy_resolved() {
  local strip="" flag="" value="" env=""
  _rclone_proxy_resolve strip flag value env
  printf '%s|%s|%s|%s\n' "$strip" "$flag" "$value" "$env"
}

# http_proxy_resolved - print the _http_proxy_args proxy out-params as
# "flag|value|env" so the shared classification can be asserted directly.
http_proxy_resolved() {
  # shellcheck disable=SC2034  # out-params written through _http_proxy_args namerefs
  local tls="" ver="" flag="" value="" env=""
  _http_proxy_args tls ver flag value env
  printf '%s|%s|%s\n' "$flag" "$value" "$env"
}

export PROXY="http://p.example:8080" PROXY_DIRECT=0
expect_eq "proxy: rclone exports http(s)" "false|||http://p.example:8080" "$(rclone_proxy_resolved)"
expect_eq "proxy: curl exports http(s)" "||http://p.example:8080" "$(http_proxy_resolved)"

export PROXY_DIRECT=1
expect_eq "proxy: direct curl args" "--noproxy|*|" "$(http_proxy_resolved)"
expect_eq "proxy: direct strips proxy env" "true|||" "$(rclone_proxy_resolved)"

# PROXY_TYPE selects the proxy mode explicitly.
export PROXY_DIRECT=0 PROXY_TYPE=none
expect_eq "proxy: type none curl args" "--noproxy|*|" "$(http_proxy_resolved)"
expect_eq "proxy: type none strips proxy env" "true|||" "$(rclone_proxy_resolved)"
export PROXY_TYPE=http
expect_eq "proxy: type http curl exports http(s)" "||http://p.example:8080" "$(http_proxy_resolved)"
expect_eq "proxy: type http exports http(s)" "false|||http://p.example:8080" "$(rclone_proxy_resolved)"
export PROXY_TYPE=socks5 PROXY="socks5://p.example:1080"
expect_eq "proxy: type socks5 curl args" "-x|socks5://p.example:1080|" "$(http_proxy_resolved)"
expect_eq "proxy: type socks5 rclone flag" "false|--http-proxy|socks5://p.example:1080|" "$(rclone_proxy_resolved)"
export PROXY_TYPE=system PROXY="http://p.example:8080"
export PROXY_DIRECT=1

STUB="${TMP}/rclone-stub"
LOG="${TMP}/rclone-log"
mkdir -p "$STUB" "$LOG"
cat >"${STUB}/rclone" <<'STUB_RCLONE'
#!/bin/bash
printf '%s\n' "$@" >"${RCLONE_STUB_LOG}/args"
env | sort >"${RCLONE_STUB_LOG}/env"
exit 0
STUB_RCLONE
chmod +x "${STUB}/rclone"

# shellcheck disable=SC2031  # re-exported only inside rclone_cmd/http_curl subshells
export RCLONE_BIN="${STUB}/rclone" RCLONE_CONFIG="${TMP}/rclone.conf" \
  RCLONE_REMOTE=testremote RCLONE_STUB_LOG="$LOG" \
  HTTPS_PROXY="http://env-proxy.example:3128" HTTP_PROXY="http://env-proxy.example:3128" \
  ALL_PROXY="http://env-proxy.example:3128"

# PROXY_TYPE=none / PROXY_DIRECT=1 strip the proxy environment, including
# ALL_PROXY, and never pass a flag.
export PROXY_DIRECT=1
rclone_cmd version >/dev/null 2>&1
expect_not_contains "proxy: direct strips HTTPS_PROXY" "$(cat "${LOG}/env" 2>/dev/null)" "HTTPS_PROXY"
expect_not_contains "proxy: direct strips HTTP_PROXY" "$(cat "${LOG}/env" 2>/dev/null)" "HTTP_PROXY"
expect_not_contains "proxy: direct strips ALL_PROXY" "$(cat "${LOG}/env" 2>/dev/null)" "ALL_PROXY"
expect_not_contains "proxy: direct no flag" "$(cat "${LOG}/args" 2>/dev/null)" "--http-proxy"

# An explicit http(s) PROXY is exported, not passed as --http-proxy: the
# credential URL stays out of argv.
export PROXY_DIRECT=0
rclone_cmd version >/dev/null 2>&1
expect_not_contains "proxy: http(s) no --http-proxy flag" "$(cat "${LOG}/args" 2>/dev/null)" "--http-proxy"
expect_not_contains "proxy: http(s) url absent from argv" "$(cat "${LOG}/args" 2>/dev/null)" "http://p.example:8080"
expect_contains "proxy: http(s) exports HTTP_PROXY" "$(cat "${LOG}/env" 2>/dev/null)" "HTTP_PROXY=http://p.example:8080"
expect_contains "proxy: http(s) exports HTTPS_PROXY" "$(cat "${LOG}/env" 2>/dev/null)" "HTTPS_PROXY=http://p.example:8080"
expect_contains "proxy: http(s) exports ALL_PROXY" "$(cat "${LOG}/env" 2>/dev/null)" "ALL_PROXY=http://p.example:8080"

# socks5:// keeps --http-proxy because env socks support is not guaranteed.
export PROXY_TYPE=socks5 PROXY="socks5://p.example:1080"
rclone_cmd version >/dev/null 2>&1
expect_contains "proxy: socks5 keeps --http-proxy" "$(cat "${LOG}/args" 2>/dev/null)" "--http-proxy"
expect_contains "proxy: socks5 keeps url in argv" "$(cat "${LOG}/args" 2>/dev/null)" "socks5://p.example:1080"
expect_not_contains "proxy: socks5 no env export" "$(cat "${LOG}/env" 2>/dev/null)" "HTTPS_PROXY=socks5://"

# PROXY_TYPE=none strips the environment even with PROXY set, and an
# explicit http/socks5 type without PROXY refuses to run.
export PROXY_TYPE=none PROXY="http://p.example:8080"
rclone_cmd version >/dev/null 2>&1
expect_not_contains "proxy: type none strips HTTPS_PROXY" "$(cat "${LOG}/env" 2>/dev/null)" "HTTPS_PROXY"
expect_not_contains "proxy: type none strips ALL_PROXY" "$(cat "${LOG}/env" 2>/dev/null)" "ALL_PROXY"
expect_not_contains "proxy: type none no flag" "$(cat "${LOG}/args" 2>/dev/null)" "--http-proxy"

export PROXY_TYPE=http
unset PROXY
out="$(rclone_cmd version 2>&1)"
rc=$?
expect_eq "proxy: type http without PROXY dies" "$rc" 1
expect_contains "proxy: type http error message" "$out" "requires PROXY"
# The curl resolver shares _proxy_classify, so it dies with the same message.
out="$(http_proxy_resolved 2>&1)"
rc=$?
expect_eq "proxy: curl type http without PROXY dies" "$rc" 1
expect_contains "proxy: curl type http error message" "$out" "requires PROXY"
export PROXY="http://p.example:8080"
export PROXY_TYPE=system

# --- http_curl keeps http(s) proxy credentials out of argv ------------------
CURL_STUB="${TMP}/curl-stub"
CURL_LOG="${TMP}/curl-log"
mkdir -p "$CURL_STUB" "$CURL_LOG"
cat >"${CURL_STUB}/curl" <<'STUB_CURL'
#!/bin/bash
printf '%s\n' "$*" >"${CURL_STUB_LOG}/args"
env | sort >"${CURL_STUB_LOG}/env"
exit 0
STUB_CURL
chmod +x "${CURL_STUB}/curl"
export CURL_STUB_LOG="$CURL_LOG"

# curl_proxy_probe - run http_curl through the logging curl in a subshell.
# shellcheck disable=SC2329  # invoked indirectly
curl_proxy_probe() {
  (
    export PATH="${CURL_STUB}:$PATH"
    export HTTP_BASE="http://127.0.0.1:9" HTTP_USER=alice \
      REMOTE_SECRET_PLAIN_CACHE="feature-test-secret"
    http_curl "http://127.0.0.1:9/x" >/dev/null 2>&1
  )
}

export PROXY_TYPE=system PROXY_DIRECT=0 PROXY="http://p.example:8080"
curl_proxy_probe
expect_not_contains "proxy: curl http(s) uses no -x" "$(cat "${CURL_LOG}/args" 2>/dev/null)" "-x"
expect_contains "proxy: curl http(s) exports HTTP_PROXY" "$(cat "${CURL_LOG}/env" 2>/dev/null)" "HTTP_PROXY=http://p.example:8080"
expect_contains "proxy: curl http(s) exports HTTPS_PROXY" "$(cat "${CURL_LOG}/env" 2>/dev/null)" "HTTPS_PROXY=http://p.example:8080"
expect_contains "proxy: curl http(s) exports ALL_PROXY" "$(cat "${CURL_LOG}/env" 2>/dev/null)" "ALL_PROXY=http://p.example:8080"

export PROXY_TYPE=socks5 PROXY="socks5://p.example:1080"
curl_proxy_probe
expect_contains "proxy: curl socks5 keeps -x" "$(cat "${CURL_LOG}/args" 2>/dev/null)" "-x socks5://p.example:1080"
expect_not_contains "proxy: curl socks5 no env export" "$(cat "${CURL_LOG}/env" 2>/dev/null)" "HTTPS_PROXY=socks5://"

export PROXY_TYPE=none
curl_proxy_probe
expect_contains "proxy: curl none uses --noproxy" "$(cat "${CURL_LOG}/args" 2>/dev/null)" "--noproxy"
expect_not_contains "proxy: curl none uses no -x" "$(cat "${CURL_LOG}/args" 2>/dev/null)" "-x"

# --- setup --proxy overrides PROXY_TYPE=none and redacts the hint -----------
# shellcheck source=../../lib/commands/setup.sh
source "${PROJ}/lib/commands/setup.sh"
export PROXY_TYPE=none PROXY="" PROXY_DIRECT=1
setup_apply_proxy "http://user:secret@proxy.example:8080"
expect_eq "proxy: setup --proxy forces system mode over none" "system" "$PROXY_TYPE"
expect_eq "proxy: setup --proxy clears PROXY_DIRECT" "0" "$PROXY_DIRECT"
expect_eq "proxy: setup --proxy sets PROXY" "http://user:secret@proxy.example:8080" "$PROXY"
expect_contains "proxy: setup hint redacts credentials" \
  "$(setup_proxy_hint "http://user:secret@proxy.example:8080")" 'PROXY="http://***@proxy.example:8080"'

finish
