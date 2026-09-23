#!/usr/bin/env bash
# setup_crypt.sh - `setup --crypt`: create the crypt remote wrapping the
# configured WebDAV remote through a recording rclone stub.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

# A stub rclone that logs every argv, answers `lsd` with exit 0 (no live
# server), and delegates everything else (config, obscure, reveal) to the
# real binary so the placeholders are actually patched into the config.
REAL_RCLONE="$(command -v rclone)"
CRYPT_STUB_BIN="${TMP}/crypt-stub-bin"
CRYPT_STUB_LOG="${CRYPT_STUB_BIN}/calls.log"
mkdir -p "$CRYPT_STUB_BIN"
printf '%s\n' "$REAL_RCLONE" >"${CRYPT_STUB_BIN}/real-rclone"
cat >"${CRYPT_STUB_BIN}/rclone" <<'STUB'
#!/bin/bash
dir="$(cd "$(dirname "$0")" && pwd)"
printf '%s\n' "$*" >>"${dir}/calls.log"
for arg in "$@"; do
  [[ "$arg" != "lsd" ]] || exit 0
done
exec "$(cat "${dir}/real-rclone")" "$@"
STUB
chmod +x "${CRYPT_STUB_BIN}/rclone"

# shellcheck source=../../lib/rclone.sh
# shellcheck disable=SC1090,SC1091
source "${PROJ}/lib/rclone.sh"

export RCLONE_REMOTE=webtest KEYCHAIN=0
export PATH="${CRYPT_STUB_BIN}:$PATH"

# --- setup --crypt creates the crypt remote ---------------------------------
rm -f "$CRYPT_STUB_LOG"
expect_cli "setup --crypt: rc 0" 0 run_cli setup --crypt
crypt_log="$(cat "$CRYPT_STUB_LOG" 2>/dev/null || true)"
expect_contains "setup --crypt: config create recorded" "$crypt_log" "config create"
expect_contains "setup --crypt: crypt type recorded" "$crypt_log" "crypt"
expect_contains "setup --crypt: wraps the webdav remote" "$crypt_log" "remote=webtest:"
expect_contains "setup --crypt: validation call recorded" "$crypt_log" "lsd webtest-crypt:"
expect_not_contains "setup --crypt: no password value in the output" "$CLI_OUT" "password="
expect_contains "setup --crypt: reports the created remote" "$CLI_OUT" \
  "created crypt remote webtest-crypt wrapping webtest:"
expect_contains "setup --crypt: points at settings.local.env" "$CLI_OUT" \
  'RCLONE_REMOTE="webtest-crypt"'

# The real obscured values only ever reach the config file (through the patch
# helper), never the rclone argv: config create carries the placeholders.
crypt_dump="$(rclone --config "$RCLONE_CONFIG" config dump 2>/dev/null)"
crypt_pass1="$(config_dump_value webtest-crypt password "$crypt_dump")"
crypt_pass2="$(config_dump_value webtest-crypt password2 "$crypt_dump")"
crypt_plain1="$(rclone reveal -- "$crypt_pass1" 2>/dev/null)"
crypt_plain2="$(rclone reveal -- "$crypt_pass2" 2>/dev/null)"
expect_eq "setup --crypt: password stored obscured, reveals to a plaintext" "yes" \
  "$([[ -n "$crypt_plain1" ]] && printf yes || printf no)"
expect_eq "setup --crypt: password2 stored obscured, reveals to a plaintext" "yes" \
  "$([[ -n "$crypt_plain2" ]] && printf yes || printf no)"
expect_not_contains "setup --crypt: obscured password absent from argv" "$crypt_log" "$crypt_pass1"
expect_not_contains "setup --crypt: obscured password2 absent from argv" "$crypt_log" "$crypt_pass2"
expect_not_contains "setup --crypt: plaintext password absent from argv" "$crypt_log" "$crypt_plain1"
expect_not_contains "setup --crypt: plaintext password2 absent from argv" "$crypt_log" "$crypt_plain2"
expect_not_contains "setup --crypt: no argv config update fallback" "$crypt_log" "config update"

# --- usage guards -----------------------------------------------------------
expect_cli "setup --crypt --login: usage error rc 2" 2 run_cli setup --crypt --login
expect_contains "setup --crypt --login: conflict message" "$CLI_OUT" \
  "--crypt cannot be combined with --login"
expect_cli "setup --crypt --rotate: usage error rc 2" 2 run_cli setup --crypt --rotate
expect_contains "setup --crypt --rotate: conflict message" "$CLI_OUT" \
  "--crypt cannot be combined with --rotate"
expect_cli "setup --crypt --url: usage error rc 2" 2 run_cli setup --crypt --url https://example.invalid
expect_contains "setup --crypt --url: conflict message" "$CLI_OUT" \
  "--crypt cannot be combined with --url"

expect_cli "setup --help: rc 0" 0 run_cli setup --help
expect_contains "setup --help: documents --crypt" "$CLI_OUT" "--crypt"
expect_contains "setup --help: documents --proxy" "$CLI_OUT" "--proxy"

finish
