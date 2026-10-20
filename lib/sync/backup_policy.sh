#!/bin/bash
# backup_policy.sh - rules shared by the backup commands: the retention
# arguments, the repository/sync-tree overlap rule, the quota gate, and the
# restore target guard. The functions are pure where they can be (settings in,
# verdict out) so they unit-test without restic or a remote.

# backup_keep_args_into ARRAY - append the restic retention flags for every
# non-zero BACKUP_KEEP_* setting (and --keep-within when set) to the argv
# array named ARRAY. Returns 1 with a warning when the policy is empty, since
# restic refuses `forget` without one.
backup_keep_args_into() {
  local -n _bk_out="$1"
  local key="" flag="" value="" any=0
  local -a pairs=(
    BACKUP_KEEP_LAST:--keep-last BACKUP_KEEP_HOURLY:--keep-hourly
    BACKUP_KEEP_DAILY:--keep-daily BACKUP_KEEP_WEEKLY:--keep-weekly
    BACKUP_KEEP_MONTHLY:--keep-monthly BACKUP_KEEP_YEARLY:--keep-yearly
  )
  local pair=""
  for pair in "${pairs[@]}"; do
    key="${pair%%:*}"
    flag="${pair#*:}"
    value="${!key:-0}"
    [[ "$value" =~ ^[0-9]+$ ]] || continue
    [[ "$((10#$value))" -gt 0 ]] || continue
    _bk_out+=("$flag" "$((10#$value))")
    any=1
  done
  if [[ -n "${BACKUP_KEEP_WITHIN:-}" ]]; then
    _bk_out+=(--keep-within "$BACKUP_KEEP_WITHIN")
    any=1
  fi
  if [[ "$any" -eq 0 ]]; then
    warn "empty retention policy: set at least one of BACKUP_KEEP_LAST, BACKUP_KEEP_HOURLY, BACKUP_KEEP_DAILY, BACKUP_KEEP_WEEKLY, BACKUP_KEEP_MONTHLY, BACKUP_KEEP_YEARLY, BACKUP_KEEP_WITHIN"
    return 1
  fi
  return 0
}

# backup_remote_path_normalize P - print P without leading or trailing
# slashes or "./" segments and with "//" collapsed.
backup_remote_path_normalize() {
  local out=""
  _settings_relpath_into out "$1"
  printf '%s' "$out"
}

# backup_repo_overlaps_path SUB - true when REMOTE_BASE/SUB (SUB may be empty
# or "/" for the base itself) equals, lies inside, or contains
# BACKUP_REMOTE_PATH, compared segment-wise.
backup_repo_overlaps_path() {
  local base="" sub="" joined=""
  _settings_relpath_into base "${REMOTE_BASE:-}"
  _settings_relpath_into sub "${1:-}"
  joined="${base}${base:+${sub:+/}}${sub}"
  _settings_paths_overlap "$joined" "$BACKUP_REMOTE_PATH"
}

# _backup_cb_overlap - manifest_each callback: report an entry whose remote
# overlaps the repository.
_backup_cb_overlap() {
  if backup_repo_overlaps_path "$ENTRY_REMOTE"; then
    printf '%s\n' "$ENTRY_NAME"
    _BACKUP_OVERLAP_FOUND=1
  fi
  return 0
}
_BACKUP_OVERLAP_FOUND=0

# backup_repo_overlaps_manifest - print the name of every manifest entry whose
# remote overlaps the backup repository path. Returns 0 when any does, 1 when
# none does.
backup_repo_overlaps_manifest() {
  _BACKUP_OVERLAP_FOUND=0
  manifest_each _backup_cb_overlap
  [[ "$_BACKUP_OVERLAP_FOUND" -eq 1 ]]
}

# backup_quota_gate - 0 to proceed, 2 to skip the run. At or above
# QUOTA_WARN_PERCENT (0 disables) BACKUP_QUOTA_POLICY decides through
# choose_policy_decision: warn proceeds with a warning, skip returns 2. A
# failed quota probe only warns and proceeds.
backup_quota_gate() {
  local threshold="${QUOTA_WARN_PERCENT:-0}" pct="" rc=0
  [[ "$((10#$threshold))" -gt 0 ]] || return 0
  if ! pct=${ quota_used_percent;}; then
    warn "could not read the quota; continuing the backup"
    return 0
  fi
  [[ "$((10#$pct))" -ge "$((10#$threshold))" ]] || return 0
  choose_policy_decision "${BACKUP_QUOTA_POLICY:-warn}" >/dev/null || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    warn "skipping backup: quota at ${pct}% (threshold ${threshold}%)"
    return 2
  fi
  warn "quota at ${pct}% (threshold ${threshold}%)"
  return 0
}

# _backup_canon_into VAR PATH - lexically normalise PATH (absolute, no "." or
# ".." segments, no trailing slash) and resolve symlinks in its deepest
# existing ancestor, so two spellings of one directory compare equal.
_backup_canon_into() {
  local p="$2" seg="" rest="" head="" phys="" joined=""
  local -a out=() segs=()
  [[ "$p" == /* ]] || p="${PWD}/${p}"
  IFS=/ read -r -a segs <<<"$p"
  for seg in "${segs[@]}"; do
    case "$seg" in
      '' | .) ;;
      ..) [[ "${#out[@]}" -eq 0 ]] || unset 'out[${#out[@]}-1]' ;;
      *) out+=("$seg") ;;
    esac
  done
  for seg in "${out[@]}"; do joined+="/${seg}"; done
  p="${joined:-/}"
  head="$p"
  while [[ "$head" != "/" && ! -d "$head" ]]; do
    rest="/${head##*/}${rest}"
    head="${head%/*}"
    [[ -n "$head" ]] || head="/"
  done
  if phys="$(cd -P -- "$head" 2>/dev/null && pwd -P)"; then
    [[ "$phys" != "/" ]] || phys=""
    p="${phys}${rest}"
    [[ -n "$p" ]] || p="/"
  fi
  printf -v "$1" '%s' "$p"
}

# _backup_path_within A B - true when A equals B or lies inside it.
_backup_path_within() {
  [[ "$1" == "$2" || "$2" == "/" || "$1" == "${2%/}"/* ]]
}

# _backup_cb_restore_clash TARGET - manifest_each callback: stop (rc 9) and
# record the entry whose local path equals, contains, or lies inside TARGET.
_backup_cb_restore_clash() {
  local local_path=""
  _backup_canon_into local_path "$ENTRY_LOCAL"
  if _backup_path_within "$1" "$local_path" || _backup_path_within "$local_path" "$1"; then
    _BACKUP_RESTORE_CLASH="$ENTRY_NAME"
    return 9
  fi
  return 0
}
_BACKUP_RESTORE_CLASH=""

# backup_restore_target_check TARGET [FORCE] - decide whether restoring into
# TARGET is safe. Returns 0 when ok; otherwise prints one reason and returns
# 1. Never allowed, even with FORCE=1: "/", $HOME, or a parent of $HOME.
# Refused unless FORCE=1: a non-empty directory, and any path that equals,
# contains, or lies inside a sync pair's local folder. A target that exists
# and is not a directory is always refused.
backup_restore_target_check() {
  local target="$1" force="${2:-0}" canon="" home="" rc=0
  _backup_canon_into canon "$target"
  _backup_canon_into home "$HOME"
  # shellcheck disable=SC2034  # read by lib/commands/backup.sh after a 0 return
  BACKUP_RESTORE_CANON="$canon"
  if [[ "$canon" == "/" || "$canon" == "$home" ]] || _backup_path_within "$home" "$canon"; then
    printf "refusing to restore into '%s': it is / or your home directory or a parent of it\n" "$canon"
    return 1
  fi
  if [[ -e "$canon" && ! -d "$canon" ]]; then
    printf "restore target '%s' exists and is not a directory\n" "$canon"
    return 1
  fi
  [[ "$force" == "1" ]] && return 0
  if [[ -d "$canon" && -n "$(ls -A -- "$canon" 2>/dev/null)" ]]; then
    printf "restore target '%s' is not empty (use --force to restore into it)\n" "$canon"
    return 1
  fi
  _BACKUP_RESTORE_CLASH=""
  manifest_each _backup_cb_restore_clash "$canon" || rc=$?
  if [[ "$rc" -eq 9 ]]; then
    printf "restore target '%s' overlaps the local folder of sync pair '%s' (use --force to restore into it)\n" "$canon" "$_BACKUP_RESTORE_CLASH"
    return 1
  fi
  return 0
}
