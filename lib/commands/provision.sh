#!/bin/bash
# provision.sh command module - non-interactive account and folder setup.
# Implements the desktop client's GUI provisioning flags as a shell command.
#
# Choices worth knowing:
#   - The profile is created here instead of by spawning `account add`:
#     provisioning is create-or-update (account add refuses an existing
#     profile) and account add reads ${FILTER_DIR} before load_settings has
#     derived it (unbound under `set -u` without an environment override).
#   - The remote is written directly with the lib/rclone.sh helpers instead
#     of spawning `setup`: setup sources .env after the environment, so a
#     stale .env could silently override --userid/--apppassword. The
#     password is obscured on rclone's stdin and stored exactly like setup
#     (Keychain when the profile's KEYCHAIN setting enables it, otherwise
#     the obscured value in the rclone config); it is never printed.
#   - `--profile` is also a global flag: bin/sciebo consumes it before
#     dispatch, so SCIEBO_PROFILE is honored exactly like OPT_profile.
#   - Folder pairs are `bisync` (the desktop client's two-way default).

usage_provision() {
  usage_emit <<'EOF'
Usage: sciebo provision --userid USER (--apppassword PASS | --apppassword-fd N)
                       --serverurl URL [--localdirpath PATH]
                       [--remotedirpath PATH] [--isvfsenabled 0|1]
                       [--profile NAME]

Create an account profile and configure its rclone remote without prompts,
the way the desktop client's provisioning flags do. The rclone remote is
named after the profile; the default profile is provision-<sanitized
userid> and can also be selected with the global --profile flag.

Options:
  --userid USER          Nextcloud user id (required)
  --apppassword PASS     app password (required; never printed). The value is
                         visible in the process list; prefer --apppassword-fd
  --apppassword-fd N     read the app password from the already-open file
                         descriptor N instead (avoids exposing it in `ps`)
  --serverurl URL        server base URL (required)
  --localdirpath PATH    local folder to pair (optional; without it only
                         the account is created)
  --remotedirpath PATH   remote folder below the remote base (default /)
  --isvfsenabled 0|1     desktop compatibility; 1 is ignored because there
                         are no virtual files: the pair stays a regular
                         two-way (bisync) sync
  --profile NAME         profile to create or update
  -h, --help             show this help
EOF
}

# provision_normalize_url URL USER - print the Nextcloud WebDAV URL for URL
# and USER through the shared nextcloud_dav_url (lib/core.sh) - the same
# helper setup_normalize_url uses, so both commands normalize identically
# without reaching into another command's internals (docs/architecture.md).
# The helper reports only rc 1 for a URL that points into /remote.php/ but
# not at USER's root; provision's --serverurl wording of that failure (with
# printable around the server-controlled URL) stays here.
provision_normalize_url() {
  local url="$1" user="$2" normalized=""
  url="$(strip_trailing_slashes "$url")"
  normalized="$(nextcloud_dav_url "$url" "$user")" ||
    die "server URL '$(printable "$url")' looks like a WebDAV path, but --serverurl needs the Nextcloud base URL (e.g. https://uni-muenster.sciebo.de)"
  printf '%s' "$normalized"
}

# provision_normalize_sub PATH - print PATH as a remote subdir below the
# remote base: leading and trailing slashes are stripped (the trailing half
# through the shared strip_trailing_slashes; only the leading strip is
# provision's own), so / means the base itself (empty). The manifest format
# cannot express an empty remote field; cmd_provision maps that case to
# ".", which rclone resolves to the base directory.
provision_normalize_sub() {
  local sub="$1"
  sub=${ strip_trailing_slashes "$sub";}
  while [[ "$sub" == /* ]]; do sub="${sub#/}"; done
  printf '%s' "$sub"
}

# provision_profile_create NAME REMOTE - create config/profiles/NAME with
# the minimal account layout account add writes: empty sources/folders/
# roots manifests, the copied clutter filter, and settings.local.env naming
# the remote. An existing profile is left untouched.
provision_profile_create() {
  local name="$1" remote="$2"
  local dir="${PROFILES_DIR}/${name}" state_dir="${PROFILES_STATE_DIR}/${name}"
  local f="" src=""
  if [[ -d "$dir" ]]; then
    return 0
  fi
  mkdir -p "${dir}/filters" "$state_dir" || die "cannot create profile directory ${dir}"
  for f in sources.conf folders.conf roots.conf; do
    : >"${dir}/${f}"
  done
  # load_settings has not run yet (the profile must exist first), so
  # FILTER_DIR is not derived; the confdir-aware default stands in.
  src="${FILTER_DIR:-${_SCIEBO_CONF_BASE:-${CONFIG_DIR}}/filters}/clutter.txt"
  cp "$src" "${dir}/filters/clutter.txt" 2>/dev/null || true
  {
    printf '# Profile settings for %s.\n' "$name"
    printf '# Plain assignments here win over the project settings and the environment.\n'
    [[ -z "$remote" ]] || printf 'RCLONE_REMOTE="%s"\n' "$remote"
  } >"${dir}/settings.local.env"
}

# provision_write_remote URL USER PASS USE_KEYCHAIN - write the Nextcloud
# WebDAV remote named by RCLONE_REMOTE exactly like setup: obscure PASS on
# stdin, store the obscured value in the Keychain when USE_KEYCHAIN is 1
# (the config then gets an obscured empty value), otherwise keep it in the
# rclone config.
provision_write_remote() {
  local url="$1" user="$2" pass="$3" use_keychain="$4"
  local pass_config=""
  pass_config="$(remote_password_config_value "$pass" "$use_keychain")"
  remote_write_nextcloud "$url" "$user" "$pass_config"
}

# provision_validate_remote - `rclone lsd` against the freshly written
# remote, like setup; die with a clear message when the server does not
# answer.
provision_validate_remote() {
  remote_validate "--serverurl, --userid, and --apppassword"
}

# provision_read_password OUT - set OUT from --apppassword-fd N (read from
# the already-open descriptor, never the argv) or --apppassword PASS. Either
# option satisfies the requirement; using --apppassword prints a warning
# because the value is visible in the process list.
provision_read_password() {
  local out="$1" fd="${OPT_apppassword_fd:-}" secret=""
  if [[ -n "$fd" ]]; then
    if [[ -n "${OPT_apppassword:-}" ]]; then
      usage_error provision "--apppassword and --apppassword-fd cannot be combined"
    fi
    # opt_read_fd_secret (lib/core.sh) owns the shared fd vocabulary, keeping
    # provision worded like nextcloudcmd's --password-fd.
    opt_read_fd_secret provision --apppassword-fd out "$fd"
    return 0
  fi
  [[ -n "${OPT_apppassword:-}" ]] || usage_error provision "--apppassword is required"
  secret="${OPT_apppassword}"
  warn "--apppassword is visible in the process list; prefer --apppassword-fd N"
  printf -v "$out" '%s' "$secret"
  return 0
}

# provision_resolve_profile OUT - set OUT to the profile to create: an
# explicit --profile/SCIEBO_PROFILE, else provision-<sanitized userid>.
# --profile is also a global flag consumed by bin/sciebo, so the value may
# arrive as SCIEBO_PROFILE instead of OPT_profile.
provision_resolve_profile() {
  local out="$1" wanted="${OPT_profile:-${SCIEBO_PROFILE:-}}"
  if [[ -n "$wanted" ]]; then
    validate_profile_name "$wanted"
  else
    wanted="$(sanitize_name "${OPT_userid}")"
    [[ -n "$wanted" ]] ||
      die "cannot derive a profile name from user id '$(printable "${OPT_userid}")'; pass --profile NAME"
    wanted="provision-${wanted}"
  fi
  printf -v "$out" '%s' "$wanted"
  return 0
}

# provision_validate_pair LOCAL_REF SUB_REF NAME_REF PAIR_REF - validate
# --localdirpath/--remotedirpath before anything is written, so a bad path
# cannot leave a half-provisioned account behind. Sets PAIR_REF to 1 when a
# pair is requested and fills the other references from that request.
provision_validate_pair() {
  local local_ref="$1" sub_ref="$2" name_ref="$3" pair_ref="$4"
  local lp="" rsub="" sname=""
  if [[ -z "${OPT_localdirpath:-}" ]]; then
    printf -v "$pair_ref" '%s' 0
    return 0
  fi
  lp="$(expand_local_path "${OPT_localdirpath}")"
  safe_local_path "$lp" ||
    die "invalid --localdirpath '$(printable "${OPT_localdirpath}")'"
  rsub="$(provision_normalize_sub "${OPT_remotedirpath:-/}")"
  if [[ -z "$rsub" ]]; then
    rsub="."
  fi
  safe_remote_path "$rsub" ||
    die "invalid --remotedirpath '$(printable "${OPT_remotedirpath:-/}")'"
  sname="$(entry_name_for "$rsub")"
  printf -v "$local_ref" '%s' "$lp"
  printf -v "$sub_ref" '%s' "$rsub"
  printf -v "$name_ref" '%s' "$sname"
  printf -v "$pair_ref" '%s' 1
  return 0
}

# provision_print_summary PROFILE URL USE_KEYCHAIN PAIR_ADDED LOCAL_PATH SUB -
# the closing report: remote, server, password location, and the pair (or the
# hint to add one).
provision_print_summary() {
  local profile="$1" url="$2" use_keychain="$3" pair_added="$4" local_path="$5" sub="$6"
  printf '\n'
  log "provisioned profile '$(printable "$profile")'"
  printf '  remote: %s:\n  server: %s\n' "$RCLONE_REMOTE" "$url"
  if [[ "$use_keychain" -eq 1 ]]; then
    printf '  password: Keychain (%s, %s)\n' "$KEYCHAIN_SERVICE" "$(keychain_account)"
  else
    printf '  password: rclone config (obscured)\n'
  fi
  if [[ "$pair_added" -eq 1 ]]; then
    printf '  pair:   %s <-> %s (bisync)\n' "$local_path" "$(remote_spec "$sub")"
  else
    printf '  pair:   none (no folder pair was added; pass --localdirpath PATH to add one)\n'
  fi
  return 0
}

# provision_validate_vfs - accept only --isvfsenabled 0|1. 1 is accepted but
# warned about: there are no virtual files, so the pair stays a regular
# two-way (bisync) sync.
provision_validate_vfs() {
  local vfs="${OPT_isvfsenabled:-0}"
  case "$vfs" in
    0) ;;
    1)
      warn "--isvfsenabled 1 is ignored: there are no virtual files; the folder pair is a regular two-way (bisync) sync"
      ;;
    *)
      usage_error provision "--isvfsenabled accepts 0 or 1 (got '$(printable "$vfs")')"
      ;;
  esac
}

# provision_check_duplicates PAIR_ADDED NAME SUB - when a folder pair was
# requested, refuse a source name or remote folder that is already configured
# in the active PROFILE. Loads the manifest index only in that case, so an
# account-only run never touches it.
provision_check_duplicates() {
  local pair_added="$1" name="$2" sub="$3"
  [[ "$pair_added" -eq 1 ]] || return 0
  manifest_index_load
  if manifest_has_name "$name"; then
    die "a source named '${name}' already exists in profile '$(printable "$profile")'"
  fi
  if manifest_has_remote "$sub"; then
    die "remote folder '${sub}' is already configured in profile '$(printable "$profile")'"
  fi
  return 0
}

# provision_resolve_keychain OUT - set OUT to 1 when the keychain backend is
# enabled, else 0. Called in the caller's shell (not through a subshell) so
# keychain_enabled's memo survives for the rclone calls that follow, and the
# `type` guard keeps a missing module from aborting.
provision_resolve_keychain() {
  local out="$1"
  if type keychain_enabled >/dev/null 2>&1 && keychain_enabled; then
    printf -v "$out" '%s' 1
  else
    printf -v "$out" '%s' 0
  fi
  return 0
}

cmd_provision() {
  local user="" pass="" url="" profile="" remote="" sub="" local_path=""
  local name="" use_keychain=0 pair_added=0
  opt_begin "userid:s apppassword:s apppassword-fd:s serverurl:s localdirpath:s remotedirpath:s isvfsenabled:s profile:s" provision "" "$@"
  opt_guard provision
  # Run dependencies load after opt_guard's --help exit, so
  # `sciebo provision --help` parses none of them: the pair validation and
  # append go through the manifest, the keychain probe below runs before
  # its `type` guard (KEYCHAIN=1 is never silently ignored), and lock.sh
  # loads before acquire_lock (so the EXIT trap can release it).
  sciebo_require_module manifest manifest_each
  sciebo_require_module keychain keychain_enabled
  sciebo_require_module lock acquire_lock

  [[ -n "${OPT_userid:-}" ]] || usage_error provision "--userid is required"
  provision_read_password pass
  [[ -n "${OPT_serverurl:-}" ]] || usage_error provision "--serverurl is required"
  provision_validate_vfs

  provision_resolve_profile profile
  remote="$profile"

  user="${OPT_userid}"
  url="$(provision_normalize_url "${OPT_serverurl}" "$user")"
  case "$url" in
    http://*) warn "URL uses plain http://; sciebo connections should use https://" ;;
  esac
  OPT_apppassword=""
  unset OPT_apppassword

  provision_validate_pair local_path sub name pair_added

  provision_profile_create "$profile" "$remote"
  SCIEBO_PROFILE="$profile"
  load_settings
  ensure_state_dirs
  mkdir -p "$(dirname "$RCLONE_CONFIG")"

  provision_check_duplicates "$pair_added" "$name" "$sub"

  provision_resolve_keychain use_keychain
  provision_write_remote "$url" "$user" "$pass" "$use_keychain"
  pass=""
  unset pass
  provision_validate_remote

  if [[ "$pair_added" -eq 1 ]]; then
    acquire_lock
    manifest_append_pair bisync "$local_path" "$sub"
    release_lock
  fi

  provision_print_summary "$profile" "$url" "$use_keychain" "$pair_added" "$local_path" "$sub"
  return 0
}
