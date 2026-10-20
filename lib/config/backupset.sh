#!/bin/bash
# backupset.sh - the backup source model for `sciebo backup` (format, parsing,
# writers, rendering).
#
# Format (single source of truth; see also config/backups.conf):
#   name|local_path[|filter_file]
#     name          sanitize_name-safe; names snapshots, logs, run records
#     local_path    absolute or ~-prefixed directory to back up
#     filter_file   optional file in FILTER_DIR, rclone filter syntax (only
#                   "- pattern" exclude rules are supported; see
#                   lib/sync/backup_filters.sh)
# Lines starting with # and blank lines are ignored. Entries are read from
# BACKUPS_FILE; a missing file is normal and means "no backup sources".
# Command modules must load settings before calling these functions.

# backupset_file - print the path of the backup sources file.
backupset_file() { printf '%s' "$BACKUPS_FILE"; }

# backupset_lines - print every non-blank, non-comment line of the backup
# sources file; succeeds silently when the file does not exist.
backupset_lines() {
  [[ -f "$BACKUPS_FILE" ]] || return 0
  config_lines "$BACKUPS_FILE"
}

# backupset_resolve_local RAW - print RAW with a leading ~ expanded. Returns
# 1 (printing nothing) unless the result is an absolute path.
backupset_resolve_local() {
  local resolved=""
  case "$1" in
    \~ | \~/* | /*) ;;
    *) return 1 ;;
  esac
  expand_local_path_into resolved "$1"
  [[ "$resolved" == /* ]] || return 1
  printf '%s' "$resolved"
}

# backupset_parse_line LINE - parse one name|local[|filter] line into
# BACKUP_ENTRY_NAME, BACKUP_ENTRY_LOCAL (raw, unexpanded), BACKUP_ENTRY_FILTER.
# Returns 1 and sets BACKUP_ENTRY_ERROR for an invalid line.
backupset_parse_line() {
  local line="$1" raw_name raw_local raw_filter extra sane=""
  IFS='|' read -r raw_name raw_local raw_filter extra <<<"$line"
  trim_into BACKUP_ENTRY_NAME "${raw_name:-}"
  trim_into BACKUP_ENTRY_LOCAL "${raw_local:-}"
  trim_into BACKUP_ENTRY_FILTER "${raw_filter:-}"
  BACKUP_ENTRY_ERROR=""
  sanitize_name_into sane "$BACKUP_ENTRY_NAME"
  if [[ -n "$extra" ]]; then
    BACKUP_ENTRY_ERROR="too many fields (expected name|local[|filter])"
  elif [[ -z "$BACKUP_ENTRY_NAME" ]]; then
    BACKUP_ENTRY_ERROR="empty name"
  elif [[ "$sane" != "$BACKUP_ENTRY_NAME" ]]; then
    BACKUP_ENTRY_ERROR="invalid name '${ printable "$BACKUP_ENTRY_NAME";}': use letters, digits, dot, dash, or underscore, not starting with dot or underscore"
  elif [[ -z "$BACKUP_ENTRY_LOCAL" ]]; then
    BACKUP_ENTRY_ERROR="empty local path"
  elif ! safe_local_path "$BACKUP_ENTRY_LOCAL"; then
    BACKUP_ENTRY_ERROR="unsafe local path '${ printable "$BACKUP_ENTRY_LOCAL";}'"
  elif ! backupset_resolve_local "$BACKUP_ENTRY_LOCAL" >/dev/null; then
    BACKUP_ENTRY_ERROR="local path '${ printable "$BACKUP_ENTRY_LOCAL";}' must be absolute or start with ~"
  elif [[ -n "$BACKUP_ENTRY_FILTER" ]] && ! safe_filter_name "$BACKUP_ENTRY_FILTER"; then
    BACKUP_ENTRY_ERROR="invalid filter file '${ printable "$BACKUP_ENTRY_FILTER";}'"
  fi
  [[ -z "$BACKUP_ENTRY_ERROR" ]]
}

# backupset_each FUNC [ARG...] - walk every valid entry in order, parsing it
# into BACKUP_ENTRY_* and calling FUNC with ARG.... A non-zero return from
# FUNC stops the walk and is returned. Invalid lines are reported to stderr as
# file:line: message and skipped. Runs in the caller's shell.
backupset_each() {
  local fn="$1" raw="" line="" lineno=0
  shift
  [[ -f "$BACKUPS_FILE" ]] || return 0
  while IFS= read -r raw <&3 || [[ -n "$raw" ]]; do
    lineno=$((lineno + 1))
    trim_into line "$raw"
    [[ -n "$line" && "$line" != "#"* ]] || continue
    if ! backupset_parse_line "$line"; then
      printf '%s:%d: %s\n' "$BACKUPS_FILE" "$lineno" "$BACKUP_ENTRY_ERROR" >&2
      continue
    fi
    "$fn" "$@" || return $?
  done 3<"$BACKUPS_FILE"
  return 0
}

# _backupset_cb_name - backupset_each callback: append the entry name.
_backupset_cb_name() {
  _BACKUPSET_NAMES+="${BACKUP_ENTRY_NAME}"$'\n'
}

# backupset_names - print the valid entry names, one per line, in file order.
backupset_names() {
  _BACKUPSET_NAMES=""
  backupset_each _backupset_cb_name 2>/dev/null
  printf '%s' "$_BACKUPSET_NAMES"
}
_BACKUPSET_NAMES=""

# _backupset_cb_find NAME - backupset_each callback: stop (rc 7) at NAME.
_backupset_cb_find() {
  [[ "$BACKUP_ENTRY_NAME" != "$1" ]] || return 7
  return 0
}

# backupset_has_name NAME - true when a valid entry has that name.
backupset_has_name() {
  local rc=0
  backupset_each _backupset_cb_find "$1" 2>/dev/null || rc=$?
  [[ "$rc" -eq 7 ]]
}

# backupset_count - print the number of valid entries.
backupset_count() {
  local names=""
  names=${ backupset_names;}
  if [[ -z "$names" ]]; then
    printf '0'
  else
    # The capture dropped the trailing newline: separators + 1 entries.
    names="${names//[^$'\n']/}"
    printf '%s' "$((${#names} + 1))"
  fi
}

# _backupset_emit_current - print the current file (exact bytes, newline
# terminated), or a short header when the file is missing or empty.
_backupset_emit_current() {
  if [[ -s "$BACKUPS_FILE" ]]; then
    cat "$BACKUPS_FILE"
    [[ -z "$(tail -c 1 "$BACKUPS_FILE" || true)" ]] || printf '\n'
  else
    printf '%s\n' "# Backup sources for \`sciebo backup\`: name|local_path[|filter_file]"
  fi
}

# backupset_append NAME LOCAL [FILTER] - validate and append one line,
# preserving existing bytes. Dies on an invalid entry or a duplicate name.
backupset_append() {
  local name="$1" local_path="$2" filter="${3:-}" line=""
  line="${name}|${local_path}${filter:+"|${filter}"}"
  backupset_parse_line "$line" || die "invalid backup source: ${BACKUP_ENTRY_ERROR}"
  ! backupset_has_name "$name" || die "backup source '${name}' already exists"
  { _backupset_emit_current && printf '%s\n' "$line"; } | atomic_write "$BACKUPS_FILE" 600
}

# backupset_remove NAME - drop the first line whose entry name is NAME,
# keeping every other line (comments included). Returns 1 when absent.
backupset_remove() {
  local want="$1" raw="" line="" found=0 out=""
  [[ -f "$BACKUPS_FILE" ]] || return 1
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    trim_into line "$raw"
    if [[ "$found" -eq 0 && -n "$line" && "$line" != "#"* ]] &&
      backupset_parse_line "$line" && [[ "$BACKUP_ENTRY_NAME" == "$want" ]]; then
      found=1
      continue
    fi
    out+="${raw}"$'\n'
  done <"$BACKUPS_FILE"
  [[ "$found" -eq 1 ]] || return 1
  printf '%s' "$out" | atomic_write "$BACKUPS_FILE" 600
}

# _backupset_cb_render JSON_FLAG - backupset_each callback: print one row.
_backupset_cb_render() {
  local json_mode="$1" resolved="" shown=""
  backupset_resolve_local "$BACKUP_ENTRY_LOCAL" >/dev/null && resolved=${ backupset_resolve_local "$BACKUP_ENTRY_LOCAL";}
  _BACKUPSET_RENDERED=$((_BACKUPSET_RENDERED + 1))
  if [[ "$json_mode" -eq 1 ]]; then
    output_json_object_begin
    output_json_kv name "$BACKUP_ENTRY_NAME"
    output_json_kv local "$resolved"
    output_json_kv filter "$BACKUP_ENTRY_FILTER"
    output_json_object_end
  else
    shown=${ printable "$resolved";}
    printf '%-28s %s%s\n' "$BACKUP_ENTRY_NAME" "$shown" "${BACKUP_ENTRY_FILTER:+" [filter: ${BACKUP_ENTRY_FILTER}]"}"
  fi
  return 0
}
_BACKUPSET_RENDERED=0

# backupset_render JSON_FLAG - print the configured backup sources: the
# aligned table (name, local path, filter) or {"backups":[...]} when
# JSON_FLAG is 1. Invalid lines go to stderr so JSON stays valid.
backupset_render() {
  local json_mode="${1:-0}"
  _BACKUPSET_RENDERED=0
  if [[ "$json_mode" -eq 1 ]]; then
    output_json_begin
    output_json_array_begin backups
  fi
  backupset_each _backupset_cb_render "$json_mode"
  if [[ "$json_mode" -eq 1 ]]; then
    output_json_array_end
    output_json_end
  elif [[ "$_BACKUPSET_RENDERED" -eq 0 ]]; then
    printf 'No backup sources configured (edit %s).\n' "$BACKUPS_FILE"
  fi
  return 0
}
