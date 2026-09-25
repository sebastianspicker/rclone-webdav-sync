#!/usr/bin/env bash
# keychain.sh - keychain backends (stub `security` in a private bin dir) (lib/keychain.sh).
# Sourced setup lives in tests/unit/common.sh; run standalone with
# `bash tests/unit/keychain.sh`.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# --- keychain (stub `security` in a private bin dir) --------------------
# `security` is resolved through PATH, so a stub only exists for the calls
# made while PATH points at it. The stub records each argv line and keeps
# the stored secret in a file, so store/lookup can cross processes. The
# assertions never print the secret value.
KC_BIN="${TMP}/keychain-bin"
mkdir -p "$KC_BIN"
cat >"${KC_BIN}/security" <<'STUB'
#!/bin/bash
dir="$(cd "$(dirname "$0")" && pwd)"
printf '%s\n' "$*" >>"${dir}/calls.log"
cmd="$1"
shift
secret=""
account=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -w)
      if [[ "$cmd" == "add-generic-password" && $# -ge 2 ]]; then
        secret="$2"
        shift 2
      else
        shift
      fi
      ;;
    -a) account="$2"; shift 2 ;;
    -s) shift 2 ;;
    -U) shift ;;
    *) shift ;;
  esac
done
file="${dir}/stored.${account}"
case "$cmd" in
  add-generic-password)
    [[ ! -f "${dir}/add.fail" ]] || exit 1
    printf '%s' "$secret" >"$file"
    ;;
  find-generic-password)
    [[ ! -f "${dir}/find.fail" ]] || exit 1
    [[ -f "$file" ]] || exit 44
    cat "$file"
    ;;
  delete-generic-password)
    [[ ! -f "${dir}/delete.fail" ]] || exit 1
    [[ -f "$file" ]] || exit 44
    rm -f "$file"
    ;;
esac
exit 0
STUB
chmod +x "${KC_BIN}/security"
KEYCHAIN_TEST_SECRET="obscured-unit-value"
saved_path="$PATH"
saved_keychain="${KEYCHAIN:-0}"
saved_service="${KEYCHAIN_SERVICE:-}"
saved_remote="${RCLONE_REMOTE:-}"
PATH="${KC_BIN}:$PATH"
KEYCHAIN=1 KEYCHAIN_SERVICE="rclone-sciebo" RCLONE_REMOTE="testremote"

expect_ok "keychain_enabled: rc 0 with KEYCHAIN=1 and stub security" keychain_enabled
KEYCHAIN=0 expect_err "keychain_enabled: rc 1 with KEYCHAIN=0" keychain_enabled
KEYCHAIN=1
# F-P1 backend memo: the probe result is cached per input set. Re-stubbing
# an input (the SCIEBO_KEYCHAIN_BACKEND hook or PATH) must re-probe without
# any test-side reset, and remote_secret_invalidate must drop the memo next
# to the secret caches. Call keychain_backend uncaptured so the refresh
# lands in this shell.
keychain_backend >/dev/null
expect_eq "keychain memo: primed with the stub security" "security" "$KEYCHAIN_BACKEND_CACHE"
SCIEBO_KEYCHAIN_BACKEND="secret-tool"
keychain_backend >/dev/null
expect_eq "keychain memo: hook change bypasses the cache" "secret-tool" "$KEYCHAIN_BACKEND_CACHE"
unset SCIEBO_KEYCHAIN_BACKEND
keychain_backend >/dev/null
expect_eq "keychain memo: hook removal re-probes PATH" "security" "$KEYCHAIN_BACKEND_CACHE"
remote_secret_invalidate
expect_eq "keychain memo: remote_secret_invalidate resets the memo" "" "$KEYCHAIN_BACKEND_CACHE"
keychain_backend >/dev/null
expect_eq "keychain memo: re-primed after reset" "security" "$KEYCHAIN_BACKEND_CACHE"
expect_eq "keychain_account: names the configured remote" "testremote" "$(keychain_account)"

printf '%s' "$KEYCHAIN_TEST_SECRET" >"${KC_BIN}/stored.testremote"
: >"${KC_BIN}/calls.log"
KEYCHAIN_CACHE="" KEYCHAIN_CACHE_SET=0
kc_out_file="${TMP}/keychain-lookup.out"
rc=0
keychain_lookup >"$kc_out_file" || rc=$?
expect_rc "keychain_lookup: rc 0 with a stored item" "$rc" 0
if [[ "$(cat "$kc_out_file")" == "$KEYCHAIN_TEST_SECRET" ]]; then
  pass "keychain_lookup: prints the stored obscured value"
else
  fail "keychain_lookup: prints the stored obscured value" "value mismatch"
fi
rc=0
keychain_lookup >"$kc_out_file" || rc=$?
expect_rc "keychain_lookup: cached second call rc 0" "$rc" 0
expect_eq "keychain_lookup: second call served from cache" "1" "$(wc -l <"${KC_BIN}/calls.log" | tr -d ' ')"

touch "${KC_BIN}/find.fail"
KEYCHAIN_CACHE="" KEYCHAIN_CACHE_SET=0
expect_err "keychain_lookup: rc 1 when the stub fails" keychain_lookup
rm -f "${KC_BIN}/find.fail"

rm -f "${KC_BIN}/stored.testremote"
KEYCHAIN_CACHE="" KEYCHAIN_CACHE_SET=0
expect_err "keychain_lookup: rc 1 when the item is absent" keychain_lookup

expect_ok "keychain_delete: rc 0 when the item exists" keychain_delete
expect_no_file "keychain_delete: stub removed the item" "${KC_BIN}/stored.testremote"
expect_ok "keychain_delete: rc 0 when the item is already absent" keychain_delete
touch "${KC_BIN}/delete.fail"
expect_err "keychain_delete: rc 1 on an unexpected failure" keychain_delete
rm -f "${KC_BIN}/delete.fail"

expect_eq "keychain_account_plain: names the plaintext slot" "testremote#plain" "$(keychain_account_plain)"
: >"${KC_BIN}/calls.log"
expect_ok "keychain_store_plain: rc 0" keychain_store_plain "plain-unit-value"
recorded="$(cat "${KC_BIN}/calls.log")"
if [[ "$recorded" == "add-generic-password -U -a testremote#plain -s rclone-sciebo -w plain-unit-value" ]]; then
  pass "keychain_store_plain: passes add-generic-password -U -a -s -w argv"
else
  fail "keychain_store_plain: passes add-generic-password -U -a -s -w argv" "recorded argv mismatch"
fi
expect_eq "keychain_store_plain: updates the plaintext cache" "plain-unit-value" "$KEYCHAIN_PLAIN_CACHE"
KEYCHAIN_PLAIN_CACHE="" KEYCHAIN_PLAIN_CACHE_SET=0
expect_eq "keychain_lookup_plain: prints the plaintext" "plain-unit-value" "$(keychain_lookup_plain)"

# remote_secret_plain reads the plaintext slot without any rclone call; a
# legacy obscured keychain item is revealed once and migrated to the slot.
LEGACY_BIN="${TMP}/stub-rclone-legacy"
cat >"$LEGACY_BIN" <<'STUB'
#!/bin/bash
dir="$(cd "$(dirname "$0")" && pwd)"
printf '%s\n' "$*" >>"${dir}/reveal.log"
case "$1" in
  reveal) printf 'plain-from-legacy' ;;
  obscure) cat >/dev/null; printf 'obscured-form' ;;
esac
STUB
chmod +x "$LEGACY_BIN"
RCLONE_BIN="$LEGACY_BIN"
printf '%s' "legacy-obscured" >"${KC_BIN}/stored.testremote"
rm -f "${KC_BIN}/stored.testremote#plain" "${KC_BIN}/reveal.log"
KEYCHAIN_CACHE="" KEYCHAIN_CACHE_SET=0 KEYCHAIN_PLAIN_CACHE="" KEYCHAIN_PLAIN_CACHE_SET=0
REMOTE_SECRET_PLAIN_CACHE="" REMOTE_SECRET_CACHE=""
expect_eq "remote_secret_plain: reveals a legacy keychain item" "plain-from-legacy" "$(remote_secret_plain)"
expect_eq "remote_secret_plain: migrates it to the plaintext slot" "plain-from-legacy" "$(cat "${KC_BIN}/stored.testremote#plain")"
rm -f "${KC_BIN}/reveal.log"
KEYCHAIN_CACHE="" KEYCHAIN_CACHE_SET=0 KEYCHAIN_PLAIN_CACHE="" KEYCHAIN_PLAIN_CACHE_SET=0
REMOTE_SECRET_PLAIN_CACHE="" REMOTE_SECRET_CACHE=""
expect_eq "remote_secret_plain: plaintext slot hit" "plain-from-legacy" "$(remote_secret_plain)"
expect_no_file "remote_secret_plain: no rclone call once migrated" "${KC_BIN}/reveal.log"

# rclone_cmd must inject the obscured password into the child only, under
# the RCLONE_CONFIG_<REMOTE>_PASS name rclone itself builds (which keeps the
# section's dashes and dots; only the option part is underscore-folded).
# Pin the spelling the plumbing emits before exercising the exec path.
expect_eq "rclone env name: plain remote" "RCLONE_CONFIG_TESTREMOTE_PASS" "$(_rclone_env_pass_name testremote)"
expect_eq "rclone env name: dashed remote keeps the dash" "RCLONE_CONFIG_MY-REMOTE_PASS" "$(_rclone_env_pass_name my-remote)"
expect_eq "rclone env name: dotted remote keeps the dot" "RCLONE_CONFIG_MY.REMOTE_PASS" "$(_rclone_env_pass_name my.remote)"
RCLONE_BIN="${TMP}/stub-rclone-pass"
cat >"$RCLONE_BIN" <<'STUB'
#!/bin/bash
env | grep '^RCLONE_CONFIG_' || true
STUB
chmod +x "$RCLONE_BIN"
rm -f "${KC_BIN}/stored.testremote#plain"
printf '%s' "$KEYCHAIN_TEST_SECRET" >"${KC_BIN}/stored.testremote"
KEYCHAIN_CACHE="" KEYCHAIN_PLAIN_CACHE="" KEYCHAIN_PLAIN_CACHE_SET=0 KEYCHAIN_CACHE_SET=0 REMOTE_SECRET_CACHE=""
RCLONE_REMOTE="testremote"
RCLONE_CONFIG="${TMP}/rclone-cmd.conf"
out="$(rclone_cmd lsd)"
expect_contains "rclone_cmd: child sees RCLONE_CONFIG_TESTREMOTE_PASS" "$out" "RCLONE_CONFIG_TESTREMOTE_PASS=${KEYCHAIN_TEST_SECRET}"
expect_err "rclone_cmd: parent environment stays clean" printenv RCLONE_CONFIG_TESTREMOTE_PASS
RCLONE_REMOTE="my-remote"
printf '%s' "$KEYCHAIN_TEST_SECRET" >"${KC_BIN}/stored.my-remote"
KEYCHAIN_CACHE="" KEYCHAIN_CACHE_SET=0 KEYCHAIN_PLAIN_CACHE="" KEYCHAIN_PLAIN_CACHE_SET=0 REMOTE_SECRET_CACHE=""
out="$(rclone_cmd lsd)"
expect_contains "rclone_cmd: keeps a dashed remote name as rclone does" "$out" "RCLONE_CONFIG_MY-REMOTE_PASS=${KEYCHAIN_TEST_SECRET}"
expect_err "rclone_cmd: parent environment clean for dashed names" printenv "RCLONE_CONFIG_MY-REMOTE_PASS"

PATH="$saved_path"
KEYCHAIN="$saved_keychain"
KEYCHAIN_SERVICE="$saved_service"
RCLONE_REMOTE="$saved_remote"
RCLONE_BIN=""
KEYCHAIN_CACHE="" KEYCHAIN_CACHE_SET=0 KEYCHAIN_PLAIN_CACHE="" KEYCHAIN_PLAIN_CACHE_SET=0
REMOTE_SECRET_CACHE="" REMOTE_SECRET_PLAIN_CACHE=""

finish
