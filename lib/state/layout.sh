#!/bin/bash
# layout.sh - state layout: directory creation and versioning (renamed from
# migrate.sh; also owns ensure_state_dirs and the bisync-workdir predicates,
# formerly in lib/config/settings.sh - they inspect/create STATE_DIR
# contents, which is state, not configuration).
#
# state/VERSION holds the layout version of STATE_DIR. Migrations run when
# the directory is first created (writing the current version) or upgraded;
# a state directory written by a newer version is refused so an old binary
# cannot silently corrupt it.
#
# Adding a migration: bump STATE_VERSION and add a case in
# _state_migrate_step.

STATE_VERSION=1

# state_version_read - print the numeric version in STATE_VERSION_FILE, or
# empty when the file is missing or unreadable.
state_version_read() {
  [[ -f "$STATE_VERSION_FILE" ]] || return 0
  local raw=""
  raw="$(<"$STATE_VERSION_FILE")"
  case "$raw" in
    '' | *[!0-9]*) return 0 ;;
  esac
  printf '%s' "$raw"
}

# _state_migrate_step FROM - apply the migration that upgrades FROM to
# FROM+1. Unknown steps are an internal error, not a user error.
_state_migrate_step() {
  local from="$1"
  case "$from" in
    0)
      # Baseline: the version file itself marks the layout as initialized.
      ;;
    *)
      die "internal error: no state migration from version ${from}"
      ;;
  esac
}

# state_migrations_run - create or upgrade STATE_VERSION_FILE. Called by
# ensure_state_dirs, so every command that writes state goes through it.
state_migrations_run() {
  local current="" previous="" had_content=0
  if [[ -d "$STATE_DIR" ]]; then
    while IFS= read -r previous; do
      [[ "$previous" == "$STATE_VERSION_FILE" ]] && continue
      had_content=1
      break
    done < <(find "$STATE_DIR" -mindepth 1 -maxdepth 1 2>/dev/null)
  fi
  current="$(state_version_read)"
  if [[ -z "$current" ]]; then
    if [[ "$had_content" -eq 1 ]]; then
      log "initializing state layout version ${STATE_VERSION} in ${STATE_DIR}"
    fi
    printf '%s\n' "$STATE_VERSION" | atomic_write "$STATE_VERSION_FILE" 600
    return 0
  fi
  if [[ "$current" -gt "$STATE_VERSION" ]]; then
    die "state directory ${STATE_DIR} uses layout version ${current}, but this ${CLI_NAME} only understands ${STATE_VERSION}; update the tool or use a different STATE_DIR"
  fi
  while [[ "$current" -lt "$STATE_VERSION" ]]; do
    _state_migrate_step "$current"
    current=$((current + 1))
    printf '%s\n' "$current" | atomic_write "$STATE_VERSION_FILE" 600
    log "migrated the state layout to version ${current}"
  done
}

# ensure_state_dirs - create the state directories every command that writes
# state needs, then run state_migrations_run.
ensure_state_dirs() {
  RUNSTATE_DIR="${RUNSTATE_DIR:-${STATE_DIR}/last}"
  mkdir -p "$LOG_DIR" "$LOCK_DIR" "$BISYNC_DIR" "$RUNSTATE_DIR"
  # This file is always loaded (lib/sciebo.sh), so state versioning always
  # runs on every state-writing command. The STATE_VERSION_FILE guard keeps
  # library-level callers that never ran load_settings (unit tests, direct
  # sourcing) skipping it: without a derived state layout
  # state_migrations_run would die under `set -u`.
  if [[ -n "${STATE_VERSION_FILE:-}" ]]; then
    state_migrations_run
  fi
}

# bisync_initialized_dir DIR - true when DIR holds real bisync state. Dry
# runs leave only *-dry files, which must not count as initialization.
bisync_initialized_dir() {
  local dir="$1" file
  [[ -d "$dir" ]] || return 1
  while IFS= read -r file; do
    [[ "$file" == *-dry ]] || return 0
  done < <(ls -A "$dir" 2>/dev/null || true)
  return 1
}

# bisync_initialized NAME - true when the named bisync workdir holds real
# state (BISYNC_DIR/NAME).
bisync_initialized() {
  bisync_initialized_dir "${BISYNC_DIR}/$1"
}
