#!/usr/bin/env bash
# setup_rotate.sh - `setup --rotate`: refresh the app password through the
# Login Flow v2 against the already-configured remote, without prompts.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

OLD_PASSWORD="old-password"
NEW_PASSWORD="rotated-app-password"
OLD_OBSCURED="$(rclone obscure "$OLD_PASSWORD")"
rclone config create rotweb webdav url="http://127.0.0.1:9/remote.php/dav/files/alice/" \
  vendor=nextcloud user=alice pass="$OLD_OBSCURED" --config "$RCLONE_CONFIG" >/dev/null 2>&1

ROTATE_REMOTE=rotweb
ROTATE_STUB_BIN="${TMP}/rotate-stub-bin"
mkdir -p "$ROTATE_STUB_BIN"
cat >"${ROTATE_STUB_BIN}/curl" <<'STUB'
#!/bin/bash
dir="$(cd "$(dirname "$0")" && pwd)"
printf '%s\n' "$*" >>"${dir}/curl.log"
out_file=""
url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out_file="${2:-}"; shift 2 ;;
    -w | -H | -X | -d | -u | --max-time) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  */index.php/login/v2)
    printf '%s' '{"poll":{"token":"rotate-poll-token","endpoint":"http:\/\/127.0.0.1:9\/login\/v2\/poll"},"login":"http:\/\/127.0.0.1:9\/login\/v2\/flow"}'
    ;;
  */login/v2/poll)
    polls=0
    [[ ! -f "${dir}/polls" ]] || polls="$(cat "${dir}/polls")"
    polls=$((polls + 1))
    printf '%s\n' "$polls" >"${dir}/polls"
    if [[ "$polls" -lt 2 ]]; then
      printf 'poll %s 404\n' "$polls" >>"${dir}/polls.log"
      [[ -z "$out_file" ]] || : >"$out_file"
      printf '404'
    else
      printf 'poll %s 200\n' "$polls" >>"${dir}/polls.log"
      [[ -z "$out_file" ]] || printf '%s' '{"server":"http:\/\/127.0.0.1:9","loginName":"alice","appPassword":"rotated-app-password"}' >"$out_file"
      printf '200'
    fi
    ;;
  *)
    printf '000'
    exit 1
    ;;
esac
exit 0
STUB
cat >"${ROTATE_STUB_BIN}/open" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$(dirname "$0")/open.log"
exit 0
STUB
chmod +x "${ROTATE_STUB_BIN}/curl" "${ROTATE_STUB_BIN}/open"

# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_cli_rotate() {
  (cd "$TMP" && env PATH="${ROTATE_STUB_BIN}:$PATH" LOGIN_FLOW_NO_BROWSER=1 \
    LOGIN_FLOW_POLL_INTERVAL=0 LOGIN_FLOW_TIMEOUT=10 LOGIN_FLOW_MAX_POLLS=5 \
    RCLONE_REMOTE="${ROTATE_REMOTE}" bash "${PROJ}/bin/sciebo" "$@")
}

# --- rotation replaces only the app password ------------------------------
old_dump="$(rclone --config "$RCLONE_CONFIG" config dump 2>/dev/null)"
expect_eq "rotate: fixture stores the old obscured pass" "$OLD_OBSCURED" \
  "$(config_dump_value rotweb pass "$old_dump")"

rm -f "${ROTATE_STUB_BIN}/polls" "${ROTATE_STUB_BIN}/polls.log" \
  "${ROTATE_STUB_BIN}/curl.log" "${ROTATE_STUB_BIN}/open.log"
expect_cli "rotate: setup --rotate rc 0" 0 run_cli_rotate setup --rotate
expect_contains "rotate: prints the rotation line" "$CLI_OUT" \
  "rotated the app password for alice@127.0.0.1:9"
expect_not_contains "rotate: never prompts for the base URL" "$CLI_OUT" "sciebo base URL"
expect_eq "rotate: polled 404 then 200" "$(printf 'poll 1 404\npoll 2 200')" \
  "$(cat "${ROTATE_STUB_BIN}/polls.log" 2>/dev/null || true)"
expect_contains "rotate: poll endpoint was called" \
  "$(cat "${ROTATE_STUB_BIN}/curl.log" 2>/dev/null || true)" "/login/v2/poll"
expect_no_file "rotate: no browser was opened" "${ROTATE_STUB_BIN}/open.log"

new_dump="$(rclone --config "$RCLONE_CONFIG" config dump 2>/dev/null)"
new_pass="$(config_dump_value rotweb pass "$new_dump")"
expect_not_contains "rotate: obscured pass is no longer the old one" "$new_pass" "$OLD_OBSCURED"
expect_eq "rotate: stored pass reveals to the flow password" "$NEW_PASSWORD" \
  "$(rclone reveal -- "$new_pass" 2>/dev/null)"
expect_not_contains "rotate: plain app password never stored" "$new_dump" "$NEW_PASSWORD"
expect_contains "rotate: type unchanged" "$new_dump" '"type": "webdav"'
expect_contains "rotate: url unchanged" "$new_dump" \
  "http://127.0.0.1:9/remote.php/dav/files/alice/"
expect_contains "rotate: user unchanged" "$new_dump" '"user": "alice"'
expect_contains "rotate: vendor unchanged" "$new_dump" '"vendor": "nextcloud"'

# --- --no-keychain rotates into the config as well ------------------------
rm -f "${ROTATE_STUB_BIN}/polls" "${ROTATE_STUB_BIN}/polls.log" \
  "${ROTATE_STUB_BIN}/curl.log" "${ROTATE_STUB_BIN}/open.log"
expect_cli "rotate: --no-keychain rc 0" 0 run_cli_rotate setup --rotate --no-keychain
expect_contains "rotate: --no-keychain prints the rotation line" "$CLI_OUT" \
  "rotated the app password for alice@127.0.0.1:9"
expect_eq "rotate: --no-keychain stored pass reveals to the flow password" "$NEW_PASSWORD" \
  "$(rclone reveal -- "$(config_dump_value rotweb pass "$(rclone --config "$RCLONE_CONFIG" config dump 2>/dev/null)")" 2>/dev/null)"

# --- failure and usage guards ---------------------------------------------
ROTATE_REMOTE=missingweb expect_cli "rotate: unconfigured remote rc 1" 1 \
  run_cli_rotate setup --rotate
expect_contains "rotate: unconfigured remote points at setup --login" "$CLI_OUT" \
  "setup --login"

expect_cli "rotate: --url conflict rc 2" 2 \
  run_cli_rotate setup --rotate --url https://example.invalid
expect_contains "rotate: --url conflict message" "$CLI_OUT" \
  "--rotate cannot be combined with --url"
expect_cli "rotate: --login conflict rc 2" 2 run_cli_rotate setup --rotate --login
expect_contains "rotate: --login conflict message" "$CLI_OUT" \
  "--rotate cannot be combined with --login"

# --- login-flow base URL is validated before any curl call -----------------
rm -f "${ROTATE_STUB_BIN}/curl.log"
expect_cli "rotate: login-flow leading-dash URL rc 1" 1 \
  run_cli_rotate setup --login --url=--config=/tmp/x
expect_contains "rotate: leading-dash URL message" "$CLI_OUT" "starts with '-'"
expect_no_file "rotate: leading-dash URL makes no curl call" "${ROTATE_STUB_BIN}/curl.log"

expect_cli "rotate: login-flow non-http URL rc 1" 1 \
  run_cli_rotate setup --login --url=ftp://example.invalid
expect_contains "rotate: non-http URL message" "$CLI_OUT" "must use http:// or https://"
expect_no_file "rotate: non-http URL makes no curl call" "${ROTATE_STUB_BIN}/curl.log"

expect_cli "rotate: usage documents the option" 0 run_cli_rotate setup --help
expect_contains "rotate: usage lists --rotate" "$CLI_OUT" "--rotate"

finish
