#!/bin/bash
# rclone.sh - rclone discovery, execution, and config introspection.
# Sourced by bin/sciebo; functions that talk to the remote require
# load_settings to have run first (RCLONE_BIN, RCLONE_CONFIG,
# RCLONE_REMOTE, REMOTE_PREFIX).

# find_rclone - print the rclone binary path or die. RCLONE_BIN wins when
# set and executable; otherwise PATH and the usual Homebrew/system
# locations are searched.
find_rclone() {
  if [[ -n "${RCLONE_BIN:-}" && -x "${RCLONE_BIN}" ]]; then
    printf '%s' "$RCLONE_BIN"
    return 0
  fi
  local candidate
  for candidate in "$(command -v rclone 2>/dev/null || true)" \
    /opt/homebrew/bin/rclone /usr/local/bin/rclone; do
    [[ -n "$candidate" && -x "$candidate" ]] || continue
    printf '%s' "$candidate"
    return 0
  done
  die "rclone not found in PATH, /opt/homebrew/bin, or /usr/local/bin"
}

# rclone_cmd ARGS... - run rclone against the configured rclone config.
rclone_cmd() { "$RCLONE_BIN" --config "$RCLONE_CONFIG" "$@"; }

require_remote() {
  remote_configured ||
    die "rclone remote '${RCLONE_REMOTE}:' is not configured; run '${CLI_NAME} setup'"
}

remote_configured() {
  rclone_cmd listremotes 2>/dev/null | grep -Fqx "${RCLONE_REMOTE}:"
}

# `config show` is enough for type/url/vendor/user; it redacts the password
# ("*** ENCRYPTED ***"). Commands that must authenticate with a second,
# ad-hoc remote read the obscured value from `config dump` instead.
remote_config_show() { rclone_cmd config show "$RCLONE_REMOTE" 2>/dev/null || true; }
remote_config_dump() { rclone_cmd config dump 2>/dev/null || true; }

# config_value KEY CONFIG_SHOW_OUTPUT -> value (empty if unset)
config_value() {
  printf '%s\n' "$2" | awk -F' = ' -v k="$1" '$1 == k { print $2; exit }'
}

# config_dump_value REMOTE KEY JSON_FROM_CONFIG_DUMP -> value
# Minimal parser for the pretty-printed dump; handles simple string values
# (url/user/pass contain no embedded quotes). Kept deliberately small and
# covered by tests.
config_dump_value() {
  local remote="$1" key="$2" json="$3" line
  line="$(
    printf '%s\n' "$json" |
      awk -v marker="\"${remote}\"" '
        index($0, marker) && /[{][[:space:]]*$/ { in_block = 1; next }
        in_block && /^[[:space:]]*}/ { exit }
        in_block { print }
      ' |
      grep -F "\"${key}\":" |
      head -n 1
  )"
  line="${line#*: }"
  line="${line%,}"
  case "$line" in
    \"*\")
      line="${line#\"}"
      line="${line%\"}"
      ;;
  esac
  printf '%s' "$line"
}

# remote_spec SUBPATH - print <remote>:<base>/<subpath>
remote_spec() { printf '%s/%s' "$REMOTE_PREFIX" "$1"; }

remote_dir_exists() { rclone_cmd lsd "$1/" >/dev/null 2>&1; }
