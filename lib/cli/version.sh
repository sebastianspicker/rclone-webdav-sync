#!/bin/bash
# version.sh - dotted version comparison used by doctor, sync, and support.
#
# Versions are MAJOR[.MINOR[.PATCH]] with optional suffix; comparison is
# numeric per component, so "1.69" < "1.70" and "1.69.1" > "1.69".

# version_print - sciebo + rclone versions, one line each. Used by support.
# The rclone line uses the cached rclone_version (lib/adapters/rclone.sh)
# when it is loaded and is omitted when no version can be read.
version_print() {
  local rclone=""
  printf '%s %s\n' "$CLI_NAME" "${SCIEBO_VERSION:-unknown}"
  if type rclone_version >/dev/null 2>&1; then
    rclone=${ rclone_version;}
  elif [[ -n "${RCLONE_BIN:-}" ]]; then
    rclone="$("$RCLONE_BIN" version 2>/dev/null | awk 'NR == 1 { print $2 }')" || rclone=""
  fi
  [[ -z "$rclone" ]] || printf 'rclone %s\n' "$rclone"
  printf 'bash %s\n' "${BASH_VERSION:-unknown}"
}
