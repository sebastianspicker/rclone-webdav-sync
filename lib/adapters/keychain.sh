#!/bin/bash
# keychain.sh - app-password storage for the sciebo app password.
#
# Two accounts per remote:
#   - keychain_account_plain: the plaintext app password, used by the HTTP
#     layer so it never has to run `rclone reveal` (whose value would be
#     ps-visible). New installs only ever write this slot.
#   - keychain_account: the legacy obscured (rclone-encrypted) password,
#     kept so an existing install can migrate once (see
#     remote_secret_plain in lib/adapters/rclone.sh).
#
# The rclone config only ever holds an obscured empty value in Keychain mode.
# Every function degrades cleanly when KEYCHAIN is unset (direct sourcing in
# unit tests) or when no backend is available under `set -u`.
#
# The backend comes from platform_keychain_backend: `security` (macOS),
# `secret-tool` (libsecret), or `pass`. The Linux backends read the secret
# from stdin, so it never reaches argv.

# platform_keychain_backend and friends come from lib/adapters/platform.sh, always
# loaded before this file by lib/sciebo.sh.

# Cached values; the _SET flags distinguish "not looked up yet" from an
# empty cached value.
KEYCHAIN_CACHE=""
KEYCHAIN_CACHE_SET=0
KEYCHAIN_PLAIN_CACHE=""
KEYCHAIN_PLAIN_CACHE_SET=0
# Memoized keychain-backend probe. keychain_enabled runs on every
# rclone_cmd, and the platform probe used to fork subshells
# ($(platform_keychain_backend) -> $(platform_os)) on each call. The cache
# is keyed on every input that can change the answer - the
# SCIEBO_KEYCHAIN_BACKEND test hook, PATH (backs the `have` probes), and
# PLATFORM_OS - so a test that re-stubs either between calls re-probes
# without any test-side reset; _keychain_cache_reset (also wired into
# remote_secret_invalidate in lib/adapters/rclone.sh) drops it explicitly.
KEYCHAIN_BACKEND_CACHE=""
KEYCHAIN_BACKEND_CACHE_KEY=""
KEYCHAIN_BACKEND_CACHE_SET=0

# _keychain_backend_refresh - re-probe the platform backend unless the
# memo is still valid for the current inputs. Runs in the caller's shell
# (no command substitution), so KEYCHAIN_BACKEND_CACHE survives the call;
# platform_keychain_backend only prints, so running it here leaves no
# state behind.
_keychain_backend_refresh() {
  local key="${SCIEBO_KEYCHAIN_BACKEND-}|${PATH-}|${PLATFORM_OS-}"
  if [[ "$KEYCHAIN_BACKEND_CACHE_SET" -eq 1 && "$KEYCHAIN_BACKEND_CACHE_KEY" == "$key" ]]; then
    return 0
  fi
  KEYCHAIN_BACKEND_CACHE=${ platform_keychain_backend;}
  KEYCHAIN_BACKEND_CACHE_KEY="$key"
  KEYCHAIN_BACKEND_CACHE_SET=1
  return 0
}

# _keychain_cache_reset - drop the memoized backend so the next call
# re-probes; callable from tests and from remote_secret_invalidate.
_keychain_cache_reset() {
  KEYCHAIN_BACKEND_CACHE=""
  KEYCHAIN_BACKEND_CACHE_KEY=""
  KEYCHAIN_BACKEND_CACHE_SET=0
  return 0
}

# keychain_backend - the active backend (security, secret-tool, pass, or
# empty) for callers that report or dispatch on it. Served from the memo.
keychain_backend() {
  _keychain_backend_refresh
  printf '%s' "$KEYCHAIN_BACKEND_CACHE"
}

# keychain_enabled - true (0) only when KEYCHAIN=1 and a backend exists.
# The backend check reads the memo directly: a `$(...)` capture here would
# fork a subshell per rclone_cmd even on a cache hit.
keychain_enabled() {
  [[ "${KEYCHAIN:-0}" == "1" ]] || return 1
  _keychain_backend_refresh
  [[ -n "$KEYCHAIN_BACKEND_CACHE" ]]
}

# keychain_account - the legacy obscured-value account for the remote.
keychain_account() { printf '%s' "${RCLONE_REMOTE:-}"; }

# keychain_account_plain - the plaintext app-password account for the remote.
# The separate slot keeps the migration unambiguous: an existing install
# holds the obscured value under keychain_account.
keychain_account_plain() { printf '%s#plain' "${RCLONE_REMOTE:-}"; }

# _keychain_pass_path ACCOUNT - the pass entry for service and account;
# service and account may contain slashes, which map to pass directory levels.
_keychain_pass_path() {
  printf 'rclone-sciebo/%s/%s' "${KEYCHAIN_SERVICE:-}" "${1:-}"
}

# keychain_security_store ACCOUNT SECRET - macOS `security` backend. The
# secret is passed in argv, so any local user who can run `ps` during the
# short window before `security` replaces its argument vector can read it; in
# exchange the rclone config holds no persistent, reversible secret. Dies with
# a clear message when `security` fails.
keychain_security_store() {
  local account="$1" secret="$2"
  if ! security add-generic-password -U -a "$account" \
    -s "${KEYCHAIN_SERVICE:-}" -w "$secret" >/dev/null 2>&1; then
    die "could not store the app password in the macOS Keychain (service '${KEYCHAIN_SERVICE:-}', account '${account}'); check Keychain access"
  fi
}

# keychain_secret_tool_store ACCOUNT SECRET - libsecret item, labeled with
# service and account; the secret travels on stdin only. Dies with a clear
# message when secret-tool fails.
keychain_secret_tool_store() {
  local account="$1" secret="$2"
  if ! secret-tool store --label "${KEYCHAIN_SERVICE:-} (${account})" \
    service "${KEYCHAIN_SERVICE:-}" account "$account" \
    <<<"$secret" >/dev/null 2>&1; then
    die "could not store the app password with secret-tool (service '${KEYCHAIN_SERVICE:-}', account '${account}'); check the login keyring"
  fi
}

# keychain_pass_store ACCOUNT SECRET - pass entry under
# rclone-sciebo/<service>/<account>; the secret travels on stdin only. Dies
# with a clear message when pass fails.
keychain_pass_store() {
  local account="$1" secret="$2"
  if ! pass insert -m -f "$(_keychain_pass_path "$account")" >/dev/null 2>&1 <<<"$secret"; then
    die "could not store the app password with pass ($(_keychain_pass_path "$account")); check the pass store"
  fi
}

# _keychain_write ACCOUNT SECRET - dispatch to the active backend. Dies with
# a clear message when no backend exists or the backend fails.
_keychain_write() {
  local account="$1" secret="$2"
  case "$(keychain_backend)" in
    security) keychain_security_store "$account" "$secret" ;;
    secret-tool) keychain_secret_tool_store "$account" "$secret" ;;
    pass) keychain_pass_store "$account" "$secret" ;;
    *) die "no keychain backend available (need 'security', 'secret-tool', or 'pass')" ;;
  esac
}

# _keychain_read ACCOUNT - print the stored secret, rc 1 with empty output
# when the item is absent. All backend output is silenced.
_keychain_read() {
  local account="$1" secret="" backend=""
  # Forkless capture: keychain_backend only prints.
  backend=${ keychain_backend;}
  case "$backend" in
    security)
      secret="$(security find-generic-password -a "$account" \
        -s "${KEYCHAIN_SERVICE:-}" -w 2>/dev/null)" || return 1
      ;;
    secret-tool)
      secret="$(secret-tool lookup service "${KEYCHAIN_SERVICE:-}" \
        account "$account" 2>/dev/null)" || return 1
      ;;
    pass)
      secret="$(pass show "$(_keychain_pass_path "$account")" 2>/dev/null)" || return 1
      secret="${secret%%$'\n'*}"
      ;;
    *) return 1 ;;
  esac
  [[ -n "$secret" ]] || return 1
  printf '%s' "$secret"
}

# _keychain_remove ACCOUNT - remove one item. rc 0 when it was deleted or was
# already absent, rc 1 on an unexpected failure. Never dies.
_keychain_remove() {
  local account="$1" rc=0
  case "$(keychain_backend)" in
    security)
      have security || return 1
      security delete-generic-password -a "$account" \
        -s "${KEYCHAIN_SERVICE:-}" >/dev/null 2>&1 || rc=$?
      if [[ "$rc" -ne 0 && "$rc" -ne 44 ]]; then
        return 1
      fi
      ;;
    secret-tool)
      if [[ -n "$(secret-tool lookup service "${KEYCHAIN_SERVICE:-}" \
        account "$account" 2>/dev/null)" ]]; then
        secret-tool clear service "${KEYCHAIN_SERVICE:-}" \
          account "$account" >/dev/null 2>&1 || return 1
      fi
      ;;
    pass)
      if ! pass rm -f "$(_keychain_pass_path "$account")" >/dev/null 2>&1; then
        if [[ -n "$(pass show "$(_keychain_pass_path "$account")" 2>/dev/null)" ]]; then
          return 1
        fi
      fi
      ;;
    *) return 1 ;;
  esac
  return 0
}

# keychain_store_plain SECRET - overwrite the plaintext app-password slot, so
# HTTP-backed commands never need `rclone reveal`. Dies with a clear message
# when no backend exists or the backend fails. Any resolved secret derived
# from the previous credential is dropped, including the remote/HTTP caches
# owned by lib/adapters/rclone.sh and lib/adapters/http.sh.
keychain_store_plain() {
  local secret="$1"
  _keychain_write "$(keychain_account_plain)" "$secret"
  KEYCHAIN_PLAIN_CACHE="$secret"
  KEYCHAIN_PLAIN_CACHE_SET=1
  remote_secret_invalidate
}

# keychain_lookup - print the legacy obscured password, rc 0. rc 1 with empty
# output when key storage is unavailable or the item is absent. Successful
# lookups are cached per process.
keychain_lookup() {
  keychain_enabled || return 1
  if [[ "$KEYCHAIN_CACHE_SET" -eq 1 ]]; then
    printf '%s' "$KEYCHAIN_CACHE"
    return 0
  fi
  local secret="" account=""
  account=${ keychain_account;}
  secret=${ _keychain_read "$account";} || return 1
  KEYCHAIN_CACHE="$secret"
  KEYCHAIN_CACHE_SET=1
  printf '%s' "$secret"
}

# keychain_lookup_plain - print the plaintext app password, rc 0. rc 1 with
# empty output when key storage is unavailable or the item is absent.
# Successful lookups are cached per process.
keychain_lookup_plain() {
  keychain_enabled || return 1
  if [[ "$KEYCHAIN_PLAIN_CACHE_SET" -eq 1 ]]; then
    printf '%s' "$KEYCHAIN_PLAIN_CACHE"
    return 0
  fi
  local secret="" account=""
  account=${ keychain_account_plain;}
  secret=${ _keychain_read "$account";} || return 1
  KEYCHAIN_PLAIN_CACHE="$secret"
  KEYCHAIN_PLAIN_CACHE_SET=1
  printf '%s' "$secret"
}

# keychain_delete - remove both the plaintext and the legacy obscured item.
# rc 0 when they were deleted or already absent, rc 1 on an unexpected
# failure. Never dies. Any resolved secret is dropped with the items,
# including the remote/HTTP caches owned by lib/adapters/rclone.sh and lib/adapters/http.sh when
# they are loaded.
keychain_delete() {
  local rc=0
  _keychain_remove "$(keychain_account)" || rc=1
  _keychain_remove "$(keychain_account_plain)" || rc=1
  KEYCHAIN_CACHE=""
  KEYCHAIN_CACHE_SET=0
  KEYCHAIN_PLAIN_CACHE=""
  KEYCHAIN_PLAIN_CACHE_SET=0
  remote_secret_invalidate
  return "$rc"
}
