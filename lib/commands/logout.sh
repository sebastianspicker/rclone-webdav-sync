#!/bin/bash
# logout.sh command module - remove the stored credentials for the active
# profile's remote: the rclone config section and the Keychain item. No
# synced data or manifests are touched.

usage_logout() {
  usage_emit <<'EOF'
Usage: sciebo logout [--revoke] [--yes]

Remove the rclone remote entry and the Keychain item for the active remote
(the default profile, or one selected with --profile NAME). Manifests,
state, and synced files are left alone. Credentials left in .env must be
removed by hand.

Options:
  --revoke    revoke the app password on the server (OCS DELETE
              /core/apppassword) before removing the local credentials; a
              failed revoke only warns, so the local logout still runs
  --yes       do not ask for confirmation
  -h, --help  show this help
EOF
}

# logout_revoke_app_password - revoke the active remote's app password
# server-side through OCS (DELETE /core/apppassword on the v2 root). The
# plaintext secret comes from the shared HTTP layer, so it still travels in
# the mode-600 netrc rather than the curl argv. Best-effort: a missing
# remote, a missing credential, or a failing request only warns, because the
# local logout must not be blocked by a failed revoke. Callers run this in a
# subshell so a die() from the HTTP context (a non-Nextcloud remote) cannot
# abort the logout.
logout_revoke_app_password() {
  local secret=""
  if ! remote_configured; then
    warn "cannot revoke the app password: remote '${RCLONE_REMOTE}:' is not configured"
    return 0
  fi
  secret="$(remote_secret_plain 2>/dev/null)" || secret=""
  if [[ -z "$secret" ]]; then
    warn "cannot revoke the app password: no stored credential for '${RCLONE_REMOTE}:'"
    return 0
  fi
  http_load_context
  ocs_request_allow DELETE '/core/apppassword'
  if http_ok_code_2xx "$HTTP_CODE" && [[ "$OCS_STATUS" == "ok" ]]; then
    log "revoked the app password on the server"
    return 0
  fi
  warn "could not revoke the app password on the server (HTTP ${HTTP_CODE:-?}${OCS_MESSAGE:+: ${OCS_MESSAGE}}); continuing"
  return 0
}

cmd_logout() {
  local removed=0 revoke=0
  opt_begin "revoke:b yes:b" logout "" "$@"
  opt_guard logout
  # Run dependencies load after opt_guard's --help exit, so
  # `sciebo logout --help` parses none of them: the revoke talks to OCS
  # through http.sh, the soft confirmation gate through ui, and the removal
  # path probes keychain.sh (loaded before its `type` guard so a Keychain
  # item is never silently kept).
  sciebo_require_module http xml_get
  sciebo_require_module ui ui_confirm_mutation_soft
  sciebo_require_module keychain keychain_delete
  revoke="${OPT_revoke:-0}"
  load_settings

  # Soft confirmation gate, previously logout_confirm: --yes skips the
  # question, a non-interactive run without --yes is a usage error, and a
  # declined prompt logs "aborted, nothing changed" so the command still
  # exits 0 without removing anything.
  ui_confirm_mutation_soft logout "refusing to remove credentials without --yes" \
    "remove the stored credentials for remote '${RCLONE_REMOTE}:'?" \
    "aborted, nothing changed" || return 0

  # Revoke before the local credentials disappear, so the stored secret is
  # still available. The subshell contains a die() from the HTTP context; a
  # non-zero result only warns and the local logout continues.
  if [[ "$revoke" -eq 1 ]]; then
    (logout_revoke_app_password) ||
      warn "could not revoke the app password on the server; continuing with the local logout"
  fi

  if remote_configured; then
    if "$RCLONE_BIN" --config "$RCLONE_CONFIG" config delete "$RCLONE_REMOTE" >/dev/null 2>&1; then
      log "removed rclone remote '${RCLONE_REMOTE}:' from ${RCLONE_CONFIG}"
      removed=1
    else
      warn "could not remove rclone remote '${RCLONE_REMOTE}:' from ${RCLONE_CONFIG}"
    fi
  else
    log "rclone remote '${RCLONE_REMOTE}:' is not configured"
  fi

  if type keychain_delete >/dev/null 2>&1 && keychain_enabled; then
    if keychain_delete; then
      log "removed the Keychain item (service '${KEYCHAIN_SERVICE}', account '${RCLONE_REMOTE}')"
      removed=1
    else
      warn "could not remove the Keychain item for '${RCLONE_REMOTE}' (it may not exist)"
    fi
  fi

  if [[ -f "$ENV_FILE" ]] && grep -Eq '^[[:space:]]*SCIEBO_APP_PASSWORD=' "$ENV_FILE" 2>/dev/null; then
    warn "credentials are still present in ${ENV_FILE}; remove them by hand"
  fi

  if [[ "$removed" -eq 0 ]]; then
    log "nothing to do"
  fi
  return 0
}
