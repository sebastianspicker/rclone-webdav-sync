#!/usr/bin/env bash
# notify.sh - notification stubs (lib/adapters/notify.sh).
# Sourced setup lives in tests/unit/common.sh; run standalone with
# `bash tests/unit/notify.sh`.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# --- notifications (stub osascript in a private bin dir) ----------------
NOTIFY_BIN="${TMP}/notify-bin"
mkdir -p "$NOTIFY_BIN"
cat >"${NOTIFY_BIN}/osascript" <<'STUB'
#!/bin/bash
dir="$(cd "$(dirname "$0")" && pwd)"
{
  printf 'argc=%s\n' "$#"
  i=0
  for arg in "$@"; do
    i=$((i + 1))
    printf 'arg%s=%s\n' "$i" "$arg"
  done
} >>"${dir}/calls.log"
exit 0
STUB
chmod +x "${NOTIFY_BIN}/osascript"
# These cases exercise the macOS backend through the stub on any host.
PLATFORM_OS=macos
saved_path="$PATH"
saved_notify="${NOTIFY:-0}"
PATH="${NOTIFY_BIN}:$PATH"
NOTIFY=0 expect_err "notify_enabled: rc 1 with NOTIFY=0" notify_enabled
NOTIFY=1 expect_ok "notify_enabled: rc 0 with NOTIFY=1 and osascript" notify_enabled
: >"${NOTIFY_BIN}/calls.log"
NOTIFY=1
out="$(notify_send "title here" "message here")"
rc=$?
expect_rc "notify_send: rc 0" "$rc" 0
expect_eq "notify_send: prints nothing" "" "$out"
calls="$(cat "${NOTIFY_BIN}/calls.log")"
expect_contains "notify_send: argc includes the script placeholder" "$calls" "argc=3"
expect_contains "notify_send: placeholder is argv[1]" "$calls" "arg1=-"
expect_contains "notify_send: title is argv[2]" "$calls" "arg2=title here"
expect_contains "notify_send: message is argv[3]" "$calls" "arg3=message here"
PATH="$saved_path"
NOTIFY="$saved_notify"

finish
