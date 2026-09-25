#!/usr/bin/env bash
# security.sh - credential hygiene: the curl netrc temp file that keeps the
# app password out of the argv, and the doctor secret-permission checks.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

# --- http_secret + keychain caches stay in the process ----------------------
# A counting macOS-backend stub shows the forkless chain resolves the Keychain
# credential once and serves later requests from HTTP_SECRET_CACHE, and that
# keychain_store_plain / remote_config_invalidate drop a resolved secret. The
# probes run in a child process (like bin/sciebo) so no cache or PATH change
# leaks into the rest of the suite.
KC_COUNT_BIN="${TMP}/secret-cache-keychain-bin"
KC_COUNT_LOG="${KC_COUNT_BIN}/security.calls"
mkdir -p "$KC_COUNT_BIN"
cat >"${KC_COUNT_BIN}/security" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"${KC_COUNT_LOG:?}"
case "$*" in
  *find-generic-password*) printf 'http-secret-plain' ;;
esac
exit 0
STUB
chmod +x "${KC_COUNT_BIN}/security"
cat >"${KC_COUNT_BIN}/probe" <<STUB
#!/bin/bash
source "${PROJ}/lib/sciebo.sh"
http_secret_invalidate
: >"\$KC_COUNT_LOG"
http_secret >/dev/null
if [[ "\${1:-}" == force ]]; then
  REMOTE_SECRET_PLAIN_CACHE=""
  HTTP_SECRET_CACHE=""
else
  http_secret >/dev/null
fi
http_secret >/dev/null
printf 'calls=%s' "\$(wc -l <"\$KC_COUNT_LOG" | tr -d ' ')"
STUB
chmod +x "${KC_COUNT_BIN}/probe"

# shellcheck disable=SC2329  # invoked indirectly via capture
http_secret_keychain_probe() {
  env PATH="${KC_COUNT_BIN}:$PATH" SCIEBO_KEYCHAIN_BACKEND=security \
    KEYCHAIN=1 KEYCHAIN_SERVICE=rclone-sciebo RCLONE_REMOTE=webtest \
    KC_COUNT_LOG="$KC_COUNT_LOG" RCLONE_BIN="${TMP}/unused-rclone" \
    bash "${KC_COUNT_BIN}/probe" plain
}
expect_contains "security: http_secret resolves the keychain once" \
  "$(http_secret_keychain_probe)" "calls=1"

# A forced remote_secret_plain re-run must still hit the Keychain cache that
# the forkless captures keep in the process instead of shelling out again.
# shellcheck disable=SC2329  # invoked indirectly via capture
http_secret_keychain_cache_probe() {
  env PATH="${KC_COUNT_BIN}:$PATH" SCIEBO_KEYCHAIN_BACKEND=security \
    KEYCHAIN=1 KEYCHAIN_SERVICE=rclone-sciebo RCLONE_REMOTE=webtest \
    KC_COUNT_LOG="$KC_COUNT_LOG" RCLONE_BIN="${TMP}/unused-rclone" \
    bash "${KC_COUNT_BIN}/probe" force
}
expect_contains "security: keychain cache survives a forced re-resolve" \
  "$(http_secret_keychain_cache_probe)" "calls=1"

# shellcheck disable=SC2329  # invoked indirectly via capture
keychain_store_plain_invalidates_http() {
  (
    _keychain_write() { :; }
    HTTP_SECRET_CACHE="stale-secret"
    keychain_store_plain "new-secret"
    printf 'http=[%s] cache=[%s]' "$HTTP_SECRET_CACHE" "$KEYCHAIN_PLAIN_CACHE"
  )
}
expect_eq "security: keychain_store_plain drops the HTTP secret cache" \
  "http=[] cache=[new-secret]" "$(keychain_store_plain_invalidates_http)"

# shellcheck disable=SC2329  # invoked indirectly via capture
remote_config_invalidate_http() {
  (
    HTTP_SECRET_CACHE="stale-secret"
    remote_config_invalidate
    printf 'http=[%s]' "$HTTP_SECRET_CACHE"
  )
}
expect_eq "security: remote_config_invalidate drops the HTTP secret cache" \
  "http=[]" "$(remote_config_invalidate_http)"

# P0.2: a config or Keychain change must drop the remote secret caches too
# (REMOTE_SECRET_CACHE/REMOTE_SECRET_PLAIN_CACHE), not just HTTP_SECRET_CACHE,
# or a stale password can survive into later requests.
# shellcheck disable=SC2030,SC2031,SC2329  # invoked indirectly; subshell-local
remote_secret_invalidate_probe() {
  (
    REMOTE_SECRET_CACHE="stale-obscured"
    REMOTE_SECRET_PLAIN_CACHE="stale-plain"
    HTTP_SECRET_CACHE="stale-http"
    remote_secret_invalidate
    printf 'obscured=[%s] plain=[%s] http=[%s]' \
      "$REMOTE_SECRET_CACHE" "$REMOTE_SECRET_PLAIN_CACHE" "$HTTP_SECRET_CACHE"
  )
}
expect_eq "security: remote_secret_invalidate clears both remote caches and HTTP" \
  "obscured=[] plain=[] http=[]" "$(remote_secret_invalidate_probe)"

# shellcheck disable=SC2030,SC2031,SC2329  # invoked indirectly; subshell-local
remote_config_invalidate_remote() {
  (
    REMOTE_SECRET_CACHE="stale-obscured"
    REMOTE_SECRET_PLAIN_CACHE="stale-plain"
    REMOTE_CONFIGURED_CACHE="1"
    remote_config_invalidate
    printf 'obscured=[%s] plain=[%s] configured=[%s]' \
      "$REMOTE_SECRET_CACHE" "$REMOTE_SECRET_PLAIN_CACHE" "$REMOTE_CONFIGURED_CACHE"
  )
}
expect_eq "security: remote_config_invalidate clears the remote secret caches" \
  "obscured=[] plain=[] configured=[]" "$(remote_config_invalidate_remote)"

# shellcheck disable=SC2030,SC2031,SC2329  # invoked indirectly; subshell-local
keychain_store_plain_invalidates_remote() {
  (
    _keychain_write() { :; }
    REMOTE_SECRET_CACHE="stale-obscured"
    REMOTE_SECRET_PLAIN_CACHE="stale-plain"
    keychain_store_plain "new-secret"
    printf 'obscured=[%s] plain=[%s] cache=[%s]' \
      "$REMOTE_SECRET_CACHE" "$REMOTE_SECRET_PLAIN_CACHE" "$KEYCHAIN_PLAIN_CACHE"
  )
}
expect_eq "security: keychain_store_plain drops the remote secret caches" \
  "obscured=[] plain=[] cache=[new-secret]" "$(keychain_store_plain_invalidates_remote)"

# shellcheck disable=SC2030,SC2031,SC2329  # invoked indirectly; subshell-local
keychain_delete_invalidates_remote() {
  (
    _keychain_remove() { :; }
    REMOTE_SECRET_CACHE="stale-obscured"
    REMOTE_SECRET_PLAIN_CACHE="stale-plain"
    keychain_delete
    printf 'obscured=[%s] plain=[%s]' \
      "$REMOTE_SECRET_CACHE" "$REMOTE_SECRET_PLAIN_CACHE"
  )
}
expect_eq "security: keychain_delete drops the remote secret caches" \
  "obscured=[] plain=[]" "$(keychain_delete_invalidates_remote)"

REAL_RCLONE="$(command -v rclone)"
REAL_AWK="$(command -v awk)"

# --- curl wrapper that snapshots the netrc file before it disappears --------
# bin/sciebo deletes the netrc temp file right after curl returns, so the
# snapshot (content, mode, path) has to be taken by a wrapper that runs as
# the curl for this test. It delegates to the shared stub untouched.
SNAP_BIN="${TMP}/netrc-snap-bin"
SNAP_NETRC="${SNAP_BIN}/netrc.snap"
SNAP_MODE="${SNAP_BIN}/netrc.mode"
SNAP_PATH="${SNAP_BIN}/netrc.path"
mkdir -p "$SNAP_BIN"
cat >"${SNAP_BIN}/curl" <<'STUB'
#!/bin/bash
source "${PROJ}/lib/sciebo.sh"
prev=""
for arg in "$@"; do
  if [[ "$prev" == "--netrc-file" ]]; then
    snap="$(dirname "$0")"
    cp "$arg" "${snap}/netrc.snap" 2>/dev/null || true
    file_mode "$arg" >"${snap}/netrc.mode" 2>/dev/null || true
    printf '%s\n' "$arg" >"${snap}/netrc.path"
    prev=""
    continue
  fi
  [[ "$arg" == "--netrc-file" ]] && prev="--netrc-file"
done
exec "$(dirname "$0")/../stub-bin/curl" "$@"
STUB
chmod +x "${SNAP_BIN}/curl"

# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
snap_clear() { rm -f "$SNAP_NETRC" "$SNAP_MODE" "$SNAP_PATH"; }
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_cli_nc_snap() {
  (cd "$TMP" && env PATH="${SNAP_BIN}:${STUB_BIN}:$PATH" RCLONE_REMOTE=webtest \
    bash "${PROJ}/bin/sciebo" "$@")
}

# --- app password travels in a mode-600 netrc, not in the curl argv ---------
stub_clear_calls
stub_reset_routes
snap_clear
stub_route PROPFIND '*/remote.php/dav/trashbin/alice/trash' 200 <<'XML'
<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:"/>
XML
expect_cli "security: trash over netrc rc 0" 0 run_cli_nc_snap trash
expect_not_contains "security: password absent from curl argv" "$(stub_args)" "feature-test-secret"
expect_contains "security: curl got --netrc-file" "$(stub_args)" "--netrc-file"
netrc_snap="$(cat "$SNAP_NETRC" 2>/dev/null || true)"
expect_contains "security: machine line is the bare host" "$netrc_snap" "machine 127.0.0.1"
expect_not_contains "security: machine line has no port" "$netrc_snap" "machine 127.0.0.1:9"
expect_contains "security: login recorded" "$netrc_snap" "login alice"
expect_contains "security: password quoted" "$netrc_snap" 'password "feature-test-secret"'
expect_eq "security: netrc was mode 600" "600" "$(cat "$SNAP_MODE" 2>/dev/null || true)"
netrc_path="$(cat "$SNAP_PATH" 2>/dev/null || true)"
expect_contains "security: netrc path recorded" "$netrc_path" "sciebo-http-netrc."
expect_no_file "security: netrc removed after the call" "$netrc_path"

# --- host derivation is independent of scheme, path, and port ---------------
expect_eq "security: host strips scheme/port/path" "cloud.example.com" "$(netrc_host 'https://cloud.example.com:8443/nextcloud')"
expect_eq "security: host strips the port" "127.0.0.1" "$(netrc_host 'http://127.0.0.1:18765')"

# P0.5: a whitespace/control byte in the remote url must be refused like an
# invalid user name, so it cannot reach the netrc machine line.
# shellcheck disable=SC2030,SC2031,SC2329  # invoked indirectly; subshell-local
http_remote_info_bad_url() {
  (
    HTTP_BASE=""
    remote_config_show() {
      printf 'url = https://cloud .example.org/remote.php/dav/files/alice/\nuser = alice\n'
    }
    http_remote_info
  ) 2>&1
}
capture http_remote_info_bad_url
expect_rc "security: whitespace in the remote url is refused" "$CLI_RC" 1
expect_contains "security: invalid url message names the remote" "$CLI_OUT" \
  "has an invalid URL"

# shellcheck disable=SC2030,SC2031,SC2329  # invoked indirectly; subshell-local
http_remote_info_ctrl_url() {
  (
    HTTP_BASE=""
    remote_config_show() {
      printf 'url = https://cloud.example.org/remote.php/dav/files/alice%s/\nuser = alice\n' "$(printf '\t')"
    }
    http_remote_info
  ) 2>&1
}
capture http_remote_info_ctrl_url
expect_rc "security: control byte in the remote url is refused" "$CLI_RC" 1
expect_contains "security: control-byte url message names the remote" "$CLI_OUT" \
  "has an invalid URL"

# --- quotes and backslashes are escaped, still never in the argv ------------
# Direct harness: source-level http_curl with the wrapper curl in PATH and a
# temporary remote whose obscured password contains a quote and a backslash.
QUOTED_PASS='p a"ss\b'
QUOTED_OBSCURED="$(rclone obscure "$QUOTED_PASS")"
rclone config create quotedweb webdav url="http://127.0.0.1:9/remote.php/dav/files/alice/" \
  vendor=nextcloud user=alice pass="$QUOTED_OBSCURED" --config "$RCLONE_CONFIG" >/dev/null 2>&1
stub_clear_calls
stub_reset_routes
snap_clear
stub_route GET '*/remote.php/dav/files/alice/quoted' 200 <<'BODY'
quoted-ok
BODY
# shellcheck disable=SC2030,SC2031  # exports are intentionally subshell-local
(
  export PATH="${SNAP_BIN}:${STUB_BIN}:$PATH"
  export RCLONE_REMOTE=quotedweb RCLONE_BIN="$REAL_RCLONE"
  export HTTP_BASE="http://127.0.0.1:9" HTTP_USER=alice
  unset REMOTE_SECRET_CACHE REMOTE_SECRET_PLAIN_CACHE
  http_curl "http://127.0.0.1:9/remote.php/dav/files/alice/quoted" >/dev/null
)
expect_rc "security: quoted password call rc 0" "$?" 0
quoted_snap="$(cat "$SNAP_NETRC" 2>/dev/null || true)"
expect_contains "security: quote and backslash escaped" "$quoted_snap" 'password "p a\"ss\\b"'
expect_not_contains "security: quoted password absent from argv" "$(stub_args)" 'p a"ss\b'

# --- a control-byte password is refused, never sent via -u argv ------------
netrc_quote "$(printf 'a\tb')" >/dev/null 2>&1
expect_rc "security: netrc quote rejects control bytes" "$?" 1
netrc_quote_into_out=""
_http_netrc_quote_into netrc_quote_into_out "$(printf 'a\tb')"
expect_rc "security: netrc quote_into rejects control bytes" "$?" 1
expect_eq "security: rejected password prints nothing" "" "$netrc_quote_into_out"
stub_clear_calls
snap_clear
# shellcheck disable=SC2030,SC2031  # exports are intentionally subshell-local
(
  export PATH="${SNAP_BIN}:${STUB_BIN}:$PATH"
  export HTTP_BASE="http://127.0.0.1:9" HTTP_USER=alice
  ctrl_pass="$(printf 'a\tb')"
  export REMOTE_SECRET_PLAIN_CACHE="$ctrl_pass"
  http_curl "http://127.0.0.1:9/remote.php/dav/files/alice/quoted" >/dev/null
)
expect_rc "security: control-byte password is refused" "$?" 1
expect_not_contains "security: control-byte call uses no -u" "$(stub_args)" "-u "
expect_not_contains "security: control-byte call uses no netrc" "$(stub_args)" "--netrc-file"
expect_no_file "security: control-byte call writes no netrc" "$SNAP_NETRC"

# --- setup/provision keep the reversible obscured password out of argv ------
# The wrapper captures the obscured value from the `obscure` call itself
# (rclone's encoding is randomized per call) and flags any later rclone argv
# that carries it; config/obscure/reveal delegate to the real binary (only
# lsd/about are answered locally) so the placeholder+patch path actually runs.
# An awk wrapper does the same for the patch helper, whose VALUE must travel
# through ENVIRON rather than in the awk argv.
SEC_PASSWORD="security-argv-fixture-4d9c"
SEC_USER="argvuser@example.org"
SEC_SERVERURL="https://cloud.example.org"
SEC_SETUP_REMOTE="secsetup"
SEC_BIN="${TMP}/sec-rclone-bin"
SEC_LOG="${SEC_BIN}/rclone.log"
SEC_SENTINEL="${SEC_BIN}/obscured-in-argv.log"
SEC_AWK_LOG="${SEC_BIN}/awk.log"
SEC_AWK_SENTINEL="${SEC_BIN}/obscured-in-awk-argv.log"
mkdir -p "$SEC_BIN"
printf '%s\n' "$REAL_RCLONE" >"${SEC_BIN}/real-rclone"
cat >"${SEC_BIN}/rclone" <<'STUB'
#!/bin/bash
dir="$(cd "$(dirname "$0")" && pwd)"
real="$(cat "${dir}/real-rclone")"
printf '%s\n' "$*" >>"${dir}/rclone.log"
for arg in "$@"; do
  if [[ "$arg" == "obscure" ]]; then
    input="$(cat)"
    out="$(printf '%s' "$input" | "$real" "$@")" || exit $?
    if [[ -n "$input" ]]; then
      printf '%s\n' "$out" >>"${dir}/secret-obscured"
    fi
    printf '%s' "$out"
    exit 0
  fi
done
if [[ -f "${dir}/secret-obscured" ]]; then
  while IFS= read -r val; do
    [[ -n "$val" ]] || continue
    case "$*" in
      *"$val"*) printf '%s\n' "$*" >>"${dir}/obscured-in-argv.log" ;;
    esac
  done <"${dir}/secret-obscured"
fi
for arg in "$@"; do
  case "$arg" in
    lsd | about) exit 0 ;;
  esac
done
exec "$real" "$@"
STUB
chmod +x "${SEC_BIN}/rclone"

# awk wrapper: log the argv and flag any occurrence of a known obscured value,
# then delegate. The ENVIRON-based patch must never put VALUE in this argv.
printf '%s\n' "$REAL_AWK" >"${SEC_BIN}/real-awk"
cat >"${SEC_BIN}/awk" <<'STUB'
#!/bin/bash
dir="$(cd "$(dirname "$0")" && pwd)"
printf '%s\n' "$*" >>"${dir}/awk.log"
if [[ -f "${dir}/secret-obscured" ]]; then
  while IFS= read -r val; do
    [[ -n "$val" ]] || continue
    case "$*" in
      *"$val"*) printf '%s\n' "$*" >>"${dir}/obscured-in-awk-argv.log" ;;
    esac
  done <"${dir}/secret-obscured"
fi
exec "$(cat "${dir}/real-awk")" "$@"
STUB
chmod +x "${SEC_BIN}/awk"

# A fresh capabilities cache keeps setup from probing the server: the probe
# reveals the obscured value for `rclone reveal`, which is not the config
# write path under test.
mkdir -p "$STATE_DIR"
: >"${STATE_DIR}/capabilities.env"

# shellcheck disable=SC2329,SC2030,SC2031  # called indirectly; PATH is subshell-local
run_cli_setup_obscured() {
  (cd "$TMP" && env PATH="${SEC_BIN}:${STUB_BIN}:$PATH" RCLONE_REMOTE="$SEC_SETUP_REMOTE" \
    ENV_FILE="${TMP}/sec-no-env.env" SCIEBO_URL="$SEC_SERVERURL" SCIEBO_USER="$SEC_USER" \
    SCIEBO_APP_PASSWORD="$SEC_PASSWORD" bash "${PROJ}/bin/sciebo" "$@")
}
# shellcheck disable=SC2329,SC2030,SC2031  # called indirectly; PATH is subshell-local
run_cli_provision_obscured() {
  (cd "$TMP" && env -u MANIFEST_FILE -u FOLDERS_FILE -u MANIFEST_GENERATED_FILE \
    -u ROOTS_FILE -u FILTER_DIR -u STATE_DIR -u LOG_DIR -u LOCK_DIR \
    -u CAPABILITIES_CACHE -u CAPABILITIES_JSON \
    PATH="${SEC_BIN}:${STUB_BIN}:$PATH" ENV_FILE="${TMP}/sec-no-env.env" \
    bash "${PROJ}/bin/sciebo" "$@")
}

sec_clear() {
  rm -f "$SEC_LOG" "$SEC_AWK_LOG" "${SEC_BIN}/secret-obscured" \
    "$SEC_SENTINEL" "$SEC_AWK_SENTINEL"
}

sec_clear
expect_cli "security: setup writes the remote rc 0" 0 run_cli_setup_obscured setup --no-keychain
setup_pass="$(config_dump_value "$SEC_SETUP_REMOTE" pass \
  "$(rclone --config "$RCLONE_CONFIG" config dump 2>/dev/null)")"
expect_eq "security: setup stored pass reveals to the plaintext" "$SEC_PASSWORD" \
  "$(rclone reveal -- "$setup_pass" 2>/dev/null)"
expect_no_file "security: setup obscured password never in rclone argv" "$SEC_SENTINEL"
expect_not_contains "security: setup plaintext never in rclone argv" \
  "$(cat "$SEC_LOG" 2>/dev/null || true)" "$SEC_PASSWORD"
expect_no_file "security: setup obscured password never in awk argv" "$SEC_AWK_SENTINEL"
expect_not_contains "security: setup obscured password absent from the awk log" \
  "$(cat "$SEC_AWK_LOG" 2>/dev/null || true)" "$setup_pass"

sec_clear
expect_cli "security: provision writes the remote rc 0" 0 run_cli_provision_obscured provision \
  --userid "$SEC_USER" --apppassword "$SEC_PASSWORD" --serverurl "$SEC_SERVERURL" \
  --profile secprov
provision_pass="$(config_dump_value secprov pass \
  "$(rclone --config "$RCLONE_CONFIG" config dump 2>/dev/null)")"
expect_eq "security: provision stored pass reveals to the plaintext" "$SEC_PASSWORD" \
  "$(rclone reveal -- "$provision_pass" 2>/dev/null)"
expect_no_file "security: provision obscured password never in rclone argv" "$SEC_SENTINEL"
expect_not_contains "security: provision plaintext never in rclone argv" \
  "$(cat "$SEC_LOG" 2>/dev/null || true)" "$SEC_PASSWORD"
expect_no_file "security: provision obscured password never in awk argv" "$SEC_AWK_SENTINEL"
expect_not_contains "security: provision obscured password absent from the awk log" \
  "$(cat "$SEC_AWK_LOG" 2>/dev/null || true)" "$provision_pass"

# --- setup --rotate's write path (remote_write_pass) patches, never argv ----
# `setup --rotate` reaches the same placeholder+patch helper; exercise that
# write path directly against a dedicated remote with the same capture.
SEC_ROTATE_REMOTE="secrotate"
rclone config create "$SEC_ROTATE_REMOTE" webdav \
  url="${SEC_SERVERURL}/remote.php/dav/files/${SEC_USER}/" vendor=nextcloud \
  user="$SEC_USER" pass="$(rclone obscure 'old-rotate-secret')" \
  --config "$RCLONE_CONFIG" >/dev/null 2>&1
# shellcheck disable=SC2329,SC2030,SC2031  # called indirectly; PATH is subshell-local
run_rotate_write() {
  (
    export PATH="${SEC_BIN}:${STUB_BIN}:$PATH" RCLONE_BIN="${SEC_BIN}/rclone" \
      RCLONE_REMOTE="$SEC_ROTATE_REMOTE" KEYCHAIN=0
    local val=""
    val="$(rclone_obscure 'rotated-secret')"
    remote_write_pass "$val"
  )
}
sec_clear
expect_cli "security: rotate write path rc 0" 0 run_rotate_write
rotate_pass="$(config_dump_value "$SEC_ROTATE_REMOTE" pass \
  "$(rclone --config "$RCLONE_CONFIG" config dump 2>/dev/null)")"
expect_eq "security: rotate stored pass reveals to the rotated secret" "rotated-secret" \
  "$(rclone reveal -- "$rotate_pass" 2>/dev/null)"
expect_no_file "security: rotate obscured password never in rclone argv" "$SEC_SENTINEL"
expect_no_file "security: rotate obscured password never in awk argv" "$SEC_AWK_SENTINEL"

# --- encrypted rclone config: refuse, never fall back to an argv write ------
# An encrypted config cannot be patched with the reversible secret; setup must
# die before the obscured value can reach any argv (rclone or awk).
SEC_ENC_CONFIG="${TMP}/sec-enc-rclone.conf"
SEC_ENC_PASS="sec-enc-config-pass"
rclone config create "$SEC_SETUP_REMOTE" webdav \
  url="${SEC_SERVERURL}/remote.php/dav/files/${SEC_USER}/" vendor=nextcloud \
  user="$SEC_USER" pass="$(rclone obscure 'placeholder')" \
  --config "$SEC_ENC_CONFIG" >/dev/null 2>&1
printf '%s\n%s\n' "$SEC_ENC_PASS" "$SEC_ENC_PASS" |
  rclone --config "$SEC_ENC_CONFIG" config encryption set >/dev/null 2>&1

if grep -q '^RCLONE_ENCRYPT_' "$SEC_ENC_CONFIG" 2>/dev/null; then
  # shellcheck disable=SC2329,SC2030,SC2031  # invoked indirectly; PATH is subshell-local
  run_cli_setup_encrypted() {
    (cd "$TMP" && env PATH="${SEC_BIN}:${STUB_BIN}:$PATH" RCLONE_REMOTE="$SEC_SETUP_REMOTE" \
      RCLONE_CONFIG="$SEC_ENC_CONFIG" RCLONE_CONFIG_PASS="$SEC_ENC_PASS" \
      ENV_FILE="${TMP}/sec-no-env.env" SCIEBO_URL="$SEC_SERVERURL" SCIEBO_USER="$SEC_USER" \
      SCIEBO_APP_PASSWORD="$SEC_PASSWORD" bash "${PROJ}/bin/sciebo" "$@")
  }
  sec_clear
  expect_cli "security: encrypted config refuses the write rc 1" 1 \
    run_cli_setup_encrypted setup --no-keychain
  expect_contains "security: encrypted config says to disable encryption" "$CLI_OUT" \
    "disable rclone config encryption"
  expect_no_file "security: encrypted config obscured password never in rclone argv" "$SEC_SENTINEL"
  expect_no_file "security: encrypted config obscured password never in awk argv" "$SEC_AWK_SENTINEL"
  expect_not_contains "security: encrypted config plaintext never in rclone argv" \
    "$(cat "$SEC_LOG" 2>/dev/null || true)" "$SEC_PASSWORD"
else
  printf 'SKIP  security: rclone cannot create an encrypted config here\n'
fi

# --- a plaintext config whose placeholder is absent: generic patch failure --
# A patch failure on a non-encrypted config must not be blamed on encryption;
# it is an unreadable or changed config. A stub rclone no-ops the config write
# so the placeholder never lands in the plaintext config and the patch fails.
SEC_PLAIN_BIN="${TMP}/plain-patch-bin"
mkdir -p "$SEC_PLAIN_BIN"
printf '%s\n' "$REAL_RCLONE" >"${SEC_PLAIN_BIN}/real-rclone"
cat >"${SEC_PLAIN_BIN}/rclone" <<'STUB'
#!/bin/bash
dir="$(cd "$(dirname "$0")" && pwd)"
prev=""
for arg in "$@"; do
  if [[ "$prev" == "config" && "$arg" == "update" ]]; then exit 0; fi
  prev="$arg"
done
exec "$(cat "${dir}/real-rclone")" "$@"
STUB
chmod +x "${SEC_PLAIN_BIN}/rclone"

SEC_PLAIN_REMOTE="secplainpatch"
rclone config create "$SEC_PLAIN_REMOTE" webdav \
  url="${SEC_SERVERURL}/remote.php/dav/files/${SEC_USER}/" vendor=nextcloud \
  user="$SEC_USER" pass="$(rclone obscure 'old-plain-secret')" \
  --config "$RCLONE_CONFIG" >/dev/null 2>&1

# shellcheck disable=SC2329,SC2030,SC2031  # invoked indirectly; env is subshell-local
run_write_pass_missing_placeholder() {
  (
    export RCLONE_BIN="${SEC_PLAIN_BIN}/rclone" \
      RCLONE_REMOTE="$SEC_PLAIN_REMOTE" KEYCHAIN=0
    remote_write_pass "$(rclone_obscure 'new-plain-secret')"
  )
}
capture run_write_pass_missing_placeholder
expect_rc "security: plaintext patch failure rc 1" "$CLI_RC" 1
expect_contains "security: plaintext patch failure is the generic message" "$CLI_OUT" \
  "could not patch the password into the rclone config (unreadable or changed)"
expect_not_contains "security: plaintext patch failure not blamed on encryption" "$CLI_OUT" \
  "config is encrypted"

# shellcheck disable=SC2329,SC2030,SC2031  # invoked indirectly; env is subshell-local
run_write_nextcloud_missing_placeholder() {
  (
    export RCLONE_BIN="${SEC_PLAIN_BIN}/rclone" \
      RCLONE_REMOTE="$SEC_PLAIN_REMOTE" KEYCHAIN=0
    remote_write_nextcloud "${SEC_SERVERURL}/remote.php/dav/files/${SEC_USER}/" \
      "$SEC_USER" "$(rclone_obscure 'new-plain-secret')"
  )
}
capture run_write_nextcloud_missing_placeholder
expect_rc "security: nextcloud plaintext patch failure rc 1" "$CLI_RC" 1
expect_contains "security: nextcloud plaintext patch failure is the generic message" "$CLI_OUT" \
  "could not patch the password into the rclone config (unreadable or changed)"
expect_not_contains "security: nextcloud patch failure not blamed on encryption" "$CLI_OUT" \
  "config is encrypted"

# --- mutual TLS / custom CA / User-Agent in the rclone argv -----------------
# Temp PEM files: only path/flag handling is asserted here, so the contents
# need not form a valid certificate. The passphrase is a real obscured value
# because rclone's --client-pass runs obscure.Reveal on it.
TLS_DIR="${TMP}/tls-fixtures"
mkdir -p "$TLS_DIR"
printf '%s\n' '-----BEGIN CERTIFICATE-----' 'client' '-----END CERTIFICATE-----' >"${TLS_DIR}/client.pem"
printf '%s\n' '-----BEGIN PRIVATE KEY-----' 'key' '-----END PRIVATE KEY-----' >"${TLS_DIR}/client.key"
printf '%s\n' '-----BEGIN CERTIFICATE-----' 'ca' '-----END CERTIFICATE-----' >"${TLS_DIR}/ca.pem"
TLS_KEY_PASSWORD="tls-key-secret-passphrase"

# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_rclone_cmd_tls() {
  # shellcheck disable=SC2030,SC2031  # exports are intentionally subshell-local
  (
    export RCLONE_BIN="${SEC_BIN}/rclone" RCLONE_REMOTE=webtest \
      CLIENT_CERT="${TLS_DIR}/client.pem" CLIENT_KEY="${TLS_DIR}/client.key" \
      CLIENT_KEY_PASSWORD="$TLS_KEY_PASSWORD" CA_CERT="${TLS_DIR}/ca.pem" \
      USER_AGENT="sciebo-test/1.0"
    rclone_cmd version
  ) >/dev/null 2>&1
}

sec_clear
run_rclone_cmd_tls
tls_log="$(cat "$SEC_LOG" 2>/dev/null || true)"
expect_contains "security: rclone gets --client-cert" "$tls_log" "--client-cert ${TLS_DIR}/client.pem"
expect_contains "security: rclone gets --client-key" "$tls_log" "--client-key ${TLS_DIR}/client.key"
expect_contains "security: rclone gets --ca-cert" "$tls_log" "--ca-cert ${TLS_DIR}/ca.pem"
expect_contains "security: rclone gets --user-agent" "$tls_log" "--user-agent sciebo-test/1.0"
expect_contains "security: rclone gets --client-pass" "$tls_log" "--client-pass"
expect_not_contains "security: plaintext key passphrase absent from rclone argv" "$tls_log" "$TLS_KEY_PASSWORD"
obscured_pass="$(cat "${SEC_BIN}/secret-obscured" 2>/dev/null || true)"
expect_eq "security: --client-pass is the obscured passphrase" "$TLS_KEY_PASSWORD" \
  "$(rclone reveal -- "$obscured_pass" 2>/dev/null)"

# Unset settings add no TLS flags.
# shellcheck disable=SC2329  # invoked indirectly
run_rclone_cmd_plain() {
  # shellcheck disable=SC2030,SC2031  # exports are intentionally subshell-local
  (
    export RCLONE_BIN="${SEC_BIN}/rclone" RCLONE_REMOTE=webtest
    unset CLIENT_CERT CLIENT_KEY CLIENT_KEY_PASSWORD CA_CERT USER_AGENT
    rclone_cmd version
  ) >/dev/null 2>&1
}
sec_clear
run_rclone_cmd_plain
plain_log="$(cat "$SEC_LOG" 2>/dev/null || true)"
expect_not_contains "security: no --client-cert by default" "$plain_log" "--client-cert"
expect_not_contains "security: no --ca-cert by default" "$plain_log" "--ca-cert"
expect_not_contains "security: no --user-agent by default" "$plain_log" "--user-agent"

# --- a configured TLS file must exist before the command runs ---------------
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_cli_missing_cert() {
  (cd "$TMP" && env RCLONE_REMOTE=webtest CLIENT_CERT="${TMP}/no-such-client.pem" \
    bash "${PROJ}/bin/sciebo" config list)
}
expect_cli "security: missing CLIENT_CERT dies" 1 run_cli_missing_cert
expect_contains "security: missing CLIENT_CERT names the setting" "$CLI_OUT" "CLIENT_CERT"
expect_contains "security: missing CLIENT_CERT message is clear" "$CLI_OUT" "does not exist"

# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_cli_tls_defaults() {
  (cd "$TMP" && env -u CLIENT_CERT -u CLIENT_KEY -u CLIENT_KEY_PASSWORD -u CA_CERT -u USER_AGENT \
    RCLONE_REMOTE=webtest bash "${PROJ}/bin/sciebo" config list)
}
expect_cli "security: unset TLS defaults are fine" 0 run_cli_tls_defaults

# --- doctor secret-permission checks (WARN only, works offline) -------------
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_doctor_offline() {
  (cd "$TMP" && env HOME="${TMP}/home" RCLONE_REMOTE=webtest \
    bash "${PROJ}/bin/sciebo" doctor --offline)
}
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_doctor_offline_missing() {
  (cd "$TMP" && env HOME="${TMP}/home" RCLONE_REMOTE=webtest \
    ENV_FILE="${TMP}/missing-env.env" RCLONE_CONFIG="${TMP}/missing-rclone.conf" \
    bash "${PROJ}/bin/sciebo" doctor --offline)
}

printf 'SCIEBO_APP_PASSWORD=legacy-secret\n' >"$ENV_FILE"
chmod 644 "$ENV_FILE"
chmod 644 "$RCLONE_CONFIG"
expect_cli "doctor: group/other modes still rc 0" 0 run_doctor_offline
expect_contains "doctor: warns about the .env file" "$CLI_OUT" "${ENV_FILE} is group/other readable or writable"
expect_contains "doctor: warns about the rclone config" "$CLI_OUT" "${RCLONE_CONFIG} is group/other readable"
expect_not_contains "doctor: secret checks never FAIL on .env" "$CLI_OUT" "FAIL  ${ENV_FILE}"

chmod 600 "$ENV_FILE"
chmod 600 "$RCLONE_CONFIG"
expect_cli "doctor: private modes rc 0" 0 run_doctor_offline
expect_contains "doctor: .env passes" "$CLI_OUT" "${ENV_FILE} permissions are private (mode 600)"
expect_contains "doctor: rclone config passes" "$CLI_OUT" "${RCLONE_CONFIG} permissions are private (mode 600)"
expect_not_contains "doctor: no .env warning anymore" "$CLI_OUT" "${ENV_FILE} is group/other"
expect_not_contains "doctor: no config warning anymore" "$CLI_OUT" "${RCLONE_CONFIG} is group/other"

capture run_doctor_offline_missing
expect_contains "doctor: missing .env is a PASS" "$CLI_OUT" "no ${TMP}/missing-env.env file found"
expect_contains "doctor: missing rclone config is a PASS" "$CLI_OUT" "no rclone config file at ${TMP}/missing-rclone.conf"

expect_cli "doctor: --help rc 0" 0 run_cli doctor --help
expect_contains "doctor: usage names secret file permissions" "$CLI_OUT" "secret file permissions"

# --- doctor: mutual-TLS / custom-CA / User-Agent reporting ------------------
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_doctor_tls() {
  (cd "$TMP" && env HOME="${TMP}/home" RCLONE_REMOTE=webtest \
    CLIENT_CERT="${TLS_DIR}/client.pem" CLIENT_KEY="${TLS_DIR}/client.key" \
    CLIENT_KEY_PASSWORD="$TLS_KEY_PASSWORD" CA_CERT="${TLS_DIR}/ca.pem" \
    USER_AGENT="sciebo-test/1.0" \
    bash "${PROJ}/bin/sciebo" doctor --offline)
}
expect_cli "doctor: TLS settings rc 0" 0 run_doctor_tls
expect_contains "doctor: client certificate is readable" "$CLI_OUT" "client certificate is readable"
expect_contains "doctor: CA certificate is readable" "$CLI_OUT" "CA certificate is readable"
expect_contains "doctor: client key passphrase configured" "$CLI_OUT" "client key passphrase is configured"
expect_contains "doctor: User-Agent override reported" "$CLI_OUT" "User-Agent override"

# A configured file that vanished is reported as a FAIL, not a crash.
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_doctor_tls_missing() {
  (cd "$TMP" && env HOME="${TMP}/home" RCLONE_REMOTE=webtest \
    CLIENT_CERT="${TMP}/missing-client.pem" \
    bash "${PROJ}/bin/sciebo" doctor --offline)
}
expect_cli "doctor: missing client certificate rc 1" 1 run_doctor_tls_missing
expect_contains "doctor: missing client certificate is a FAIL" "$CLI_OUT" "FAIL"
expect_contains "doctor: missing client certificate names the path" "$CLI_OUT" "missing-client.pem"
expect_not_contains "doctor: missing file does not abort settings" \
  "$CLI_OUT" "points to a file that does not exist"

# --- support archive: proxy credentials never survive redaction -------------
# A credential proxy is set in the local settings layer (redacted by the
# settings dump) and in the environment (inherited by the offline doctor
# report, where only the userinfo is masked). PROXY_TYPE/PROXY_DIRECT are
# non-secret policy and must stay readable in the archive.
PROXY_SECRET="proxy-test-secret"
cat >"${TMP}/support-proxy.env" <<EOF
PROXY="http://user:${PROXY_SECRET}@proxy.example:8080"
PROXY_DIRECT=0
PROXY_TYPE=socks5
EOF
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_cli_support_proxy() {
  (cd "$TMP" && env RCLONE_REMOTE=webtest SETTINGS_LOCAL_FILE="${TMP}/support-proxy.env" \
    PROXY="http://user:${PROXY_SECRET}@proxy.example:8080" \
    bash "${PROJ}/bin/sciebo" "$@")
}
ARCHIVE_PROXY="${TMP}/support-proxy.tar.gz"
expect_cli "security: support with a credential proxy rc 0" 0 run_cli_support_proxy support --output "$ARCHIVE_PROXY"
proxy_archive="$(tar -xzOf "$ARCHIVE_PROXY" 2>/dev/null)"
expect_not_contains "security: proxy password absent from the archive" "$proxy_archive" "$PROXY_SECRET"
expect_contains "security: proxy userinfo masked in the doctor report" "$proxy_archive" "REDACTED@proxy.example"
expect_contains "security: PROXY setting redacted" "$proxy_archive" "PROXY=REDACTED"
expect_contains "security: PROXY_TYPE policy setting kept" "$proxy_archive" "PROXY_TYPE=socks5"
expect_contains "security: PROXY_DIRECT policy setting kept" "$proxy_archive" "PROXY_DIRECT=0"

# --- unsafe settings files are refused before they are sourced -------------
# A group/other-writable or symlinked settings layer must not execute code.
UNSAFE_LOCAL="${TMP}/unsafe-local.env"
printf 'RCLONE_REMOTE=webtest\n' >"$UNSAFE_LOCAL"
chmod 666 "$UNSAFE_LOCAL"
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_cli_unsafe_settings() {
  (cd "$TMP" && env RCLONE_REMOTE=webtest SETTINGS_LOCAL_FILE="$UNSAFE_LOCAL" \
    bash "${PROJ}/bin/sciebo" config list)
}
expect_cli "security: group-writable settings refused" 1 run_cli_unsafe_settings
expect_contains "security: refusal names the unsafe file" "$CLI_OUT" "refusing unsafe settings file"

printf 'RCLONE_REMOTE=webtest\n' >"${TMP}/link-target.env"
chmod 600 "${TMP}/link-target.env"
ln -sf "${TMP}/link-target.env" "${TMP}/link-local.env"
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_cli_symlink_settings() {
  (cd "$TMP" && env RCLONE_REMOTE=webtest SETTINGS_LOCAL_FILE="${TMP}/link-local.env" \
    bash "${PROJ}/bin/sciebo" config list)
}
expect_cli "security: symlinked settings refused" 1 run_cli_symlink_settings
expect_contains "security: symlink refusal names the file" "$CLI_OUT" "refusing unsafe settings file"

# --- login flow: an off-origin endpoint/login URL is refused ---------------
# A hostile/MITM'd server must not steer the credential poll at another host
# (or inject a leading-dash curl option).
stub_reset_routes
stub_route POST '*login/v2*' 200 <<'JSON'
{"poll":{"token":"t0k","endpoint":"http://evil.example/index.php/login/v2/poll"},"login":"https://evil.example/login"}
JSON
expect_cli "security: login-flow off-origin response refused" 1 run_cli_nc setup --login --url http://127.0.0.1:9 --no-keychain
expect_contains "security: off-origin login-flow message" "$CLI_OUT" "unexpected server URL"

# --- login flow: a control byte in the server URL is refused ---------------
# The login-flow response is server-controlled; a control byte in the login
# URL must be refused before it can reach the terminal or the browser opener.
LOGIN_CTRL_BIN="${TMP}/login-ctrl-bin"
LOGIN_CTRL_OPEN="${LOGIN_CTRL_BIN}/open.log"
mkdir -p "$LOGIN_CTRL_BIN"
cat >"${LOGIN_CTRL_BIN}/open" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$(dirname "$0")/open.log"
exit 0
STUB
chmod +x "${LOGIN_CTRL_BIN}/open"
# shellcheck disable=SC2329,SC2030,SC2031  # called indirectly; PATH is subshell-local
run_cli_login_ctrl() {
  (cd "$TMP" && env PATH="${LOGIN_CTRL_BIN}:${STUB_BIN}:$PATH" RCLONE_REMOTE=webtest \
    bash "${PROJ}/bin/sciebo" "$@")
}

login_ctrl_tab="$(printf '\t')"
stub_reset_routes
stub_clear_calls
rm -f "$LOGIN_CTRL_OPEN"
stub_route POST '*login/v2' 200 <<JSON
{"poll":{"token":"t0k","endpoint":"http://127.0.0.1:9/index.php/login/v2/poll"},"login":"http://127.0.0.1:9/login${login_ctrl_tab}flow"}
JSON
expect_cli "security: login-flow control-byte URL refused" 1 \
  run_cli_login_ctrl setup --login --url http://127.0.0.1:9 --no-keychain
expect_contains "security: control-byte login-flow message" "$CLI_OUT" "control character"
expect_eq "security: control-byte login-flow made the flow request" "1" \
  "$(stub_count 'POST.*login/v2')"
expect_eq "security: control-byte login-flow never polled" "0" \
  "$(stub_count 'login/v2/poll')"
expect_no_file "security: control-byte login-flow opened no browser" "$LOGIN_CTRL_OPEN"

# --- login flow: the client-key passphrase stays out of the curl argv ------
# A stub curl snapshots the --config file before setup discards it, so the
# content, mode, and post-call removal can all be asserted.
LOGIN_PASS_BIN="${TMP}/login-pass-bin"
LOGIN_PASS_ARGV="${LOGIN_PASS_BIN}/argv.log"
LOGIN_PASS_SNAP="${LOGIN_PASS_BIN}/curl-config.snap"
LOGIN_PASS_MODE="${LOGIN_PASS_BIN}/curl-config.mode"
LOGIN_PASS_PATH="${LOGIN_PASS_BIN}/curl-config.path"
mkdir -p "$LOGIN_PASS_BIN"
cat >"${LOGIN_PASS_BIN}/curl" <<'STUB'
#!/bin/bash
source "${PROJ}/lib/sciebo.sh"
dir="$(cd "$(dirname "$0")" && pwd)"
printf '%s\n' "$*" >>"${dir}/argv.log"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      cfg="${2:-}"
      [[ -n "$cfg" ]] || break
      cp "$cfg" "${dir}/curl-config.snap" 2>/dev/null || true
      file_mode "$cfg" >"${dir}/curl-config.mode" 2>/dev/null || true
      printf '%s\n' "$cfg" >"${dir}/curl-config.path"
      shift 2
      ;;
    *) shift ;;
  esac
done
exit 1
STUB
chmod +x "${LOGIN_PASS_BIN}/curl"

login_pass_clear() {
  rm -f "$LOGIN_PASS_ARGV" "$LOGIN_PASS_SNAP" "$LOGIN_PASS_MODE" "$LOGIN_PASS_PATH"
}
# shellcheck disable=SC2329,SC2030,SC2031  # called indirectly; PATH is subshell-local
run_cli_login_pass() {
  local key_pass="$1"
  shift
  (cd "$TMP" && env PATH="${LOGIN_PASS_BIN}:${STUB_BIN}:$PATH" RCLONE_REMOTE=webtest \
    TMPDIR="$TMP" CLIENT_KEY_PASSWORD="$key_pass" \
    bash "${PROJ}/bin/sciebo" "$@")
}

LOGIN_KEY_PASS='login-key "pw"\back'
login_pass_clear
expect_cli "security: login-flow key-passphrase run rc 1" 1 \
  run_cli_login_pass "$LOGIN_KEY_PASS" setup --login --url http://127.0.0.1:9 --no-keychain
expect_not_contains "security: key passphrase absent from curl argv" \
  "$(cat "$LOGIN_PASS_ARGV" 2>/dev/null || true)" "$LOGIN_KEY_PASS"
expect_contains "security: login-flow curl got --config" \
  "$(cat "$LOGIN_PASS_ARGV" 2>/dev/null || true)" "--config"
expect_contains "security: curl config quotes the passphrase" \
  "$(cat "$LOGIN_PASS_SNAP" 2>/dev/null || true)" 'pass = "login-key \"pw\"\\back"'
expect_eq "security: curl config was mode 600" "600" \
  "$(cat "$LOGIN_PASS_MODE" 2>/dev/null || true)"
expect_no_file "security: curl config removed after the call" \
  "$(cat "$LOGIN_PASS_PATH" 2>/dev/null || true)"

# A control byte cannot be represented in the curl config and is refused.
ctrl_login_pass="$(printf 'a\tb')"
login_pass_clear
expect_cli "security: login-flow control-byte key passphrase refused" 1 \
  run_cli_login_pass "$ctrl_login_pass" setup --login --url http://127.0.0.1:9 --no-keychain
expect_contains "security: control-byte key passphrase message" "$CLI_OUT" "control character"
expect_no_file "security: control-byte key passphrase makes no curl call" "$LOGIN_PASS_ARGV"

# --- login flow: the poll token stays out of the curl argv -----------------
# The server-controlled token is written to a mode-600 temp and sent as
# --data-urlencode "token@FILE"; a stub curl snapshots that file before setup
# discards it, so the argv, content, mode, and post-poll removal are asserted.
LOGIN_TOKEN_BIN="${TMP}/login-token-bin"
LOGIN_TOKEN_ARGV="${LOGIN_TOKEN_BIN}/argv.log"
LOGIN_TOKEN_SNAP="${LOGIN_TOKEN_BIN}/token.snap"
LOGIN_TOKEN_MODE="${LOGIN_TOKEN_BIN}/token.mode"
LOGIN_TOKEN_PATH="${LOGIN_TOKEN_BIN}/token.path"
LOGIN_TOKEN_VALUE='poll-token-fixture-9f3a'
mkdir -p "$LOGIN_TOKEN_BIN"
cat >"${LOGIN_TOKEN_BIN}/curl" <<'STUB'
#!/bin/bash
source "${PROJ}/lib/sciebo.sh"
dir="$(cd "$(dirname "$0")" && pwd)"
printf '%s\n' "$*" >>"${dir}/argv.log"
out_file=""
url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out_file="${2:-}"; shift 2 ;;
    --data-urlencode)
      field="${2:-}"
      case "$field" in
        token@*)
          token_file="${field#token@}"
          if [[ -f "$token_file" ]]; then
            cp "$token_file" "${dir}/token.snap" 2>/dev/null || true
            file_mode "$token_file" >"${dir}/token.mode" 2>/dev/null || true
            printf '%s\n' "$token_file" >"${dir}/token.path"
          fi
          ;;
      esac
      shift 2
      ;;
    -w | -H | -X | -d | -u | --max-time) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  */index.php/login/v2)
    printf '%s' '{"poll":{"token":"poll-token-fixture-9f3a","endpoint":"http:\/\/127.0.0.1:9\/login\/v2\/poll"},"login":"http:\/\/127.0.0.1:9\/login\/v2\/flow"}'
    ;;
  */login/v2/poll)
    [[ -z "$out_file" ]] || : >"$out_file"
    printf '404'
    ;;
  *)
    printf '000'
    exit 1
    ;;
esac
exit 0
STUB
chmod +x "${LOGIN_TOKEN_BIN}/curl"

login_token_clear() {
  rm -f "$LOGIN_TOKEN_ARGV" "$LOGIN_TOKEN_SNAP" "$LOGIN_TOKEN_MODE" "$LOGIN_TOKEN_PATH"
}
# shellcheck disable=SC2329,SC2030,SC2031  # called indirectly; env is subshell-local
run_cli_login_token() {
  (cd "$TMP" && env PATH="${LOGIN_TOKEN_BIN}:${STUB_BIN}:$PATH" RCLONE_REMOTE=webtest \
    TMPDIR="$TMP" LOGIN_FLOW_NO_BROWSER=1 LOGIN_FLOW_POLL_INTERVAL=0 \
    LOGIN_FLOW_TIMEOUT=10 LOGIN_FLOW_MAX_POLLS=1 \
    bash "${PROJ}/bin/sciebo" "$@")
}

login_token_clear
expect_cli "security: login-flow poll rc 1 on timeout" 1 \
  run_cli_login_token setup --login --url http://127.0.0.1:9 --no-keychain
expect_not_contains "security: poll token absent from curl argv" \
  "$(cat "$LOGIN_TOKEN_ARGV" 2>/dev/null || true)" "$LOGIN_TOKEN_VALUE"
expect_contains "security: poll sends the token from a file" \
  "$(cat "$LOGIN_TOKEN_ARGV" 2>/dev/null || true)" "token@"
expect_eq "security: poll token file held the token" "$LOGIN_TOKEN_VALUE" \
  "$(cat "$LOGIN_TOKEN_SNAP" 2>/dev/null || true)"
expect_eq "security: poll token file was mode 600" "600" \
  "$(cat "$LOGIN_TOKEN_MODE" 2>/dev/null || true)"
expect_no_file "security: poll token file removed after the poll" \
  "$(cat "$LOGIN_TOKEN_PATH" 2>/dev/null || true)"

# --- logout --revoke: revoke the app password server-side first -------------
# One dedicated remote per case keeps the shared webtest remote untouched. The
# plaintext secret still comes from the rclone config (KEYCHAIN=0), so rclone
# reveal feeds the OCS netrc. The revoke must run before the local delete and
# a 2xx OCS "ok" clears it; a failure warns but the local logout still runs.
rclone config create logoutweb webdav url="http://127.0.0.1:9/remote.php/dav/files/alice/" \
  vendor=nextcloud user=alice pass="$OBSCURED" --config "$RCLONE_CONFIG" >/dev/null 2>&1
rclone config create logoutfail webdav url="http://127.0.0.1:9/remote.php/dav/files/alice/" \
  vendor=nextcloud user=alice pass="$OBSCURED" --config "$RCLONE_CONFIG" >/dev/null 2>&1
# shellcheck disable=SC2329,SC2030,SC2031  # called indirectly; PATH is subshell-local
run_cli_logout() {
  local remote="$1"
  shift
  (cd "$TMP" && env PATH="${STUB_BIN}:$PATH" RCLONE_REMOTE="$remote" bash "${PROJ}/bin/sciebo" "$@")
}

stub_reset_routes
stub_clear_calls
stub_route DELETE '*/ocs/v2.php/core/apppassword' 200 <<'XML'
<?xml version="1.0"?>
<ocs>
 <meta><status>ok</status><statuscode>200</statuscode><message>OK</message></meta>
 <data/>
</ocs>
XML

# Without --yes a non-interactive run refuses before any server call.
expect_cli "security: logout --revoke needs --yes rc 2" 2 run_cli_logout logoutweb logout --revoke
expect_contains "security: logout --revoke needs --yes message" "$CLI_OUT" "without --yes"
expect_eq "security: refusal makes no revoke call" "0" "$(stub_count 'apppassword')"

expect_cli "security: logout --revoke rc 0" 0 run_cli_logout logoutweb logout --revoke --yes
expect_contains "security: revoke sends DELETE" "$(stub_calls)" $'DELETE\t'
expect_contains "security: revoke hits the v2 endpoint" "$(stub_calls)" "ocs/v2.php/core/apppassword"
expect_contains "security: revoke confirmed" "$CLI_OUT" "revoked the app password on the server"
expect_not_contains "security: revoke removed the local remote" \
  "$(rclone --config "$RCLONE_CONFIG" listremotes 2>/dev/null || true)" "logoutweb:"

# A failing revoke warns but the local credentials are still removed.
stub_reset_routes
stub_clear_calls
stub_route DELETE '*/ocs/v2.php/core/apppassword' 500 <<'XML'
<?xml version="1.0"?>
<ocs>
 <meta><status>failure</status><statuscode>500</statuscode><message>revoke failed</message></meta>
 <data/>
</ocs>
XML

expect_cli "security: logout --revoke failure rc 0" 0 run_cli_logout logoutfail logout --revoke --yes
expect_contains "security: failing revoke warns" "$CLI_OUT" "could not revoke the app password"
expect_not_contains "security: failing revoke still logs out" \
  "$(rclone --config "$RCLONE_CONFIG" listremotes 2>/dev/null || true)" "logoutfail:"

# A 3xx answer to the revoke DELETE is not a successful revoke: curl does not
# follow redirects for the write, so the command warns and the local logout
# still runs.
rclone config create logoutredir webdav url="http://127.0.0.1:9/remote.php/dav/files/alice/" \
  vendor=nextcloud user=alice pass="$OBSCURED" --config "$RCLONE_CONFIG" >/dev/null 2>&1
stub_reset_routes
stub_clear_calls
stub_route DELETE '*/ocs/v2.php/core/apppassword' 302 </dev/null

expect_cli "security: logout --revoke redirect rc 0" 0 run_cli_logout logoutredir logout --revoke --yes
expect_not_contains "security: redirect revoke is not confirmed" "$CLI_OUT" "revoked the app password"
expect_contains "security: redirect revoke warns" "$CLI_OUT" "could not revoke the app password"
expect_contains "security: redirect revoke reports the status" "$CLI_OUT" "HTTP 302"
expect_not_contains "security: redirect revoke still logs out" \
  "$(rclone --config "$RCLONE_CONFIG" listremotes 2>/dev/null || true)" "logoutredir:"

# --- ui_confirm_mutation refuses on a TTY when SCIEBO_NON_INTERACTIVE is set -
# The gate must treat SCIEBO_NON_INTERACTIVE as non-interactive even though
# stdin is a terminal: it must refuse with the usage error instead of asking.
# A python3 pty gives the probe a real terminal, so the check is deterministic
# whether or not the suite itself runs attached to one.
UI_GATE_BIN="${TMP}/ui-gate-probe"
mkdir -p "$UI_GATE_BIN"
cat >"${UI_GATE_BIN}/probe.sh" <<'PROBE'
#!/bin/bash
source "${PROJ}/lib/sciebo.sh"
CLI_NAME=sciebo
usage_probe() { :; }
ui_confirm_mutation probe "probe requires --yes" "proceed? [y/N]: "
printf 'gate-returned-%s\n' "$?"
PROBE
# run_ui_gate_probe - run the probe with stdin/stdout on a pty and
# SCIEBO_NON_INTERACTIVE=1, feeding 'n' so a prompt would answer no. Prints the
# combined output; exits with the probe's status, or 127 without python3.
run_ui_gate_probe() {
  command -v python3 >/dev/null 2>&1 || return 127
  python3 - "${UI_GATE_BIN}/probe.sh" <<'PY'
import os
import pty
import sys

try:
    pid, fd = pty.fork()
except OSError:
    sys.exit(127)
if pid == 0:
    os.environ["SCIEBO_NON_INTERACTIVE"] = "1"
    os.execvp("bash", ["bash", sys.argv[1]])
try:
    os.write(fd, b"n\n")
except OSError:
    pass
out = b""
while True:
    try:
        data = os.read(fd, 4096)
    except OSError:
        break
    if not data:
        break
    out += data
_, status = os.waitpid(pid, 0)
sys.stdout.buffer.write(out)
if os.WIFEXITED(status):
    sys.exit(os.WEXITSTATUS(status))
sys.exit(128 + os.WTERMSIG(status))
PY
}

gate_rc=0
gate_out="$(run_ui_gate_probe 2>&1)" || gate_rc=$?
if [[ "$gate_rc" -eq 127 ]]; then
  printf 'SKIP  security: non-interactive mutation gate needs python3\n'
else
  expect_rc "security: non-interactive gate refuses on a TTY" "$gate_rc" 2
  expect_contains "security: TTY refusal names --yes" "$gate_out" "requires --yes"
  expect_not_contains "security: TTY refusal does not prompt" "$gate_out" "[y/N]"
fi

finish
