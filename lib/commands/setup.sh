#!/bin/bash
# setup.sh command module - create or update the sciebo WebDAV remote.

usage_setup() {
  cat <<'EOF'
Usage: sciebo setup

Create or update the rclone remote named by RCLONE_REMOTE (see
config/settings.env) as a Nextcloud WebDAV backend and validate it.

Connection values are taken from the environment, from .env in the
project root, or interactively:

  SCIEBO_URL           Nextcloud base URL, e.g. https://uni-muenster.sciebo.de
  SCIEBO_USER          sciebo ID, e.g. alice@uni-muenster.de
  SCIEBO_APP_PASSWORD  app password (Settings > Security > Devices & sessions)

If all three are already set, no prompts are shown. The URL is normalized
to https://<host>/remote.php/dav/files/<user>/ so Nextcloud chunked
uploads work. The app password is obscured before it is written to the
rclone config and is never printed or stored in this repository.
EOF
}

# setup_prompt LABEL CURRENT [secret] - print CURRENT or ask for it.
setup_prompt() {
  local label="$1" current="$2" secret="${3:-}"
  if [[ -n "$current" ]]; then
    printf '%s' "$current"
    return 0
  fi
  if [[ -n "$secret" ]]; then
    read -r -s -p "${label}: " current || true
    printf '\n' >&2
  else
    printf '%s: ' "$label"
    read -r current || true
  fi
  printf '%s' "$current"
}

setup_normalize_url() {
  local url="$1" user="$2"
  while [[ "$url" == */ ]]; do
    url="${url%/}"
  done
  case "$url" in
    */remote.php/dav/files/"$user")
      printf '%s/' "$url"
      ;;
    *"/remote.php/"*)
      die "URL '${url}' looks like a WebDAV path, but setup needs the Nextcloud base URL (e.g. https://uni-muenster.sciebo.de); it appends /remote.php/dav/files/<user>/ itself"
      ;;
    *)
      printf '%s/remote.php/dav/files/%s/' "$url" "$user"
      ;;
  esac
}

setup_warn_if_group_or_other_readable() {
  local file="$1" mode
  [[ -f "$file" ]] || return 0
  mode="$(stat -f '%Lp' "$file" 2>/dev/null || true)"
  [[ -n "$mode" ]] || return 0
  case "$mode" in
    *00) ;;
    *) warn "${file} is readable by group/other (mode ${mode}); consider chmod 600 ${file}" ;;
  esac
}

cmd_setup() {
  opt_reset
  opt_parse "" setup "" "$@"
  if [[ "$OPT_HELP" -eq 1 ]]; then
    usage_setup
    exit 0
  fi
  [[ -z "$(trim "$OPT_EXTRA")" ]] || usage_error setup "unknown option: $(trim "$OPT_EXTRA")"

  load_settings
  ensure_state_dirs
  mkdir -p "$(dirname "$RCLONE_CONFIG")"

  if [[ -f "$ENV_FILE" ]]; then
    setup_warn_if_group_or_other_readable "$ENV_FILE"
    # shellcheck disable=SC1090  # .env path is documented and overridable
    source "$ENV_FILE"
  fi

  local url user pass pass_obscured lsd_err about_out
  url="$(setup_prompt 'sciebo base URL (e.g. https://uni-muenster.sciebo.de)' "${SCIEBO_URL:-}")"
  [[ -n "$url" ]] || die "sciebo base URL is required; set SCIEBO_URL in .env (cp .env.example .env)"

  user="$(setup_prompt 'sciebo ID (e.g. alice@uni-muenster.de)' "${SCIEBO_USER:-}")"
  [[ -n "$user" ]] || die "sciebo ID is required; set SCIEBO_USER in .env (cp .env.example .env)"
  case "$user" in
    *@*) ;;
    *) die "sciebo ID '${user}' does not look like an ID; expected <localid>@<scope>, e.g. alice@uni-muenster.de" ;;
  esac

  pass="$(setup_prompt 'sciebo app password' "${SCIEBO_APP_PASSWORD:-}" secret)"
  [[ -n "$pass" ]] || die "sciebo app password is required; set SCIEBO_APP_PASSWORD in .env (cp .env.example .env)"

  url="$(setup_normalize_url "$url" "$user")"
  case "$url" in
    http://*) warn "URL uses plain http://; sciebo connections should use https://" ;;
  esac

  pass_obscured="$(printf '%s' "$pass" | "$RCLONE_BIN" obscure -)"
  pass=""
  unset SCIEBO_APP_PASSWORD

  if remote_configured; then
    log "updating existing rclone remote '${RCLONE_REMOTE}:'"
    rclone_cmd config update "$RCLONE_REMOTE" type webdav url "$url" vendor nextcloud user "$user" pass "$pass_obscured" --non-interactive
  else
    log "creating rclone remote '${RCLONE_REMOTE}:'"
    rclone_cmd config create "$RCLONE_REMOTE" webdav url "$url" vendor nextcloud user "$user" pass "$pass_obscured" --non-interactive
  fi

  log "validating remote '${RCLONE_REMOTE}:' (rclone lsd)"
  if lsd_err="$(rclone_cmd lsd "${RCLONE_REMOTE}:" 2>&1 >/dev/null)"; then
    log "remote is reachable"
  else
    err "rclone lsd failed: ${lsd_err}"
    die "validation failed; check the URL, the sciebo ID, and the app password (accounts with 2FA need an app password from Settings > Security)"
  fi

  if about_out="$(rclone_cmd about "${RCLONE_REMOTE}:" 2>&1)"; then
    [[ -z "$about_out" ]] || printf '%s\n' "$about_out"
  else
    warn "could not read quota (rclone about failed): ${about_out}"
  fi

  printf '\n'
  log "remote '${RCLONE_REMOTE}:' ready"
  printf '  url:    %s\n  user:   %s\n  config: %s\n' "$url" "$user" "$RCLONE_CONFIG"
  printf '\nNext steps:\n'
  printf '  1. add sources to config/sources.conf\n'
  printf '  2. sciebo check   (dry run)\n'
  printf '  3. sciebo sync    (apply)\n'
  return 0
}
