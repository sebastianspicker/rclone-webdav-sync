#!/bin/bash
# manifest.sh - the source manifest model (format, parsing, index, writers).
#
# Format (single source of truth; see also config/sources.conf):
#   mode|local_path|remote_subdir[|filter_file]
#     mode          sync (local -> remote), pull (remote -> local), bisync
#     local_path    absolute, ~-prefixed, or relative to the project root
#     remote_subdir path below <RCLONE_REMOTE>:<REMOTE_BASE>/ ; never empty
#     filter_file   optional extra filter file in FILTER_DIR
# Lines starting with # and blank lines are ignored. Entries are read from
# MANIFEST_FILE, FOLDERS_FILE, and MANIFEST_GENERATED_FILE, in that order;
# command modules must load settings before calling these functions.

valid_entry_mode() {
  case "$1" in
    sync | pull | bisync) ;;
    *) return 1 ;;
  esac
}

# entry_name_for SUBDIR - sanitized name used for logs and bisync workdirs.
entry_name_for() {
  local name="$(sanitize_name "$1")"
  [[ -n "$name" ]] || name="entry"
  printf '%s' "$name"
}

manifest_files() { printf '%s\n' "$MANIFEST_FILE" "$FOLDERS_FILE" "$MANIFEST_GENERATED_FILE"; }

manifest_lines() {
  local file
  while IFS= read -r file; do
    [[ -f "$file" ]] || continue
    config_lines "$file"
  done < <(manifest_files)
}

# Sets ENTRY_MODE, ENTRY_LOCAL, ENTRY_REMOTE, ENTRY_FILTER, ENTRY_NAME.
# Returns 1 and sets ENTRY_ERROR for invalid entries.
manifest_parse_line() {
  local line="$1" raw_mode raw_local raw_remote raw_filter extra
  IFS='|' read -r raw_mode raw_local raw_remote raw_filter extra <<<"$line"
  ENTRY_MODE="$(trim "${raw_mode:-}")"
  ENTRY_REMOTE="$(trim "${raw_remote:-}")"
  ENTRY_FILTER="$(trim "${raw_filter:-}")"
  raw_local="$(trim "${raw_local:-}")"
  ENTRY_ERROR=""
  ENTRY_NAME="$(entry_name_for "$ENTRY_REMOTE")"
  if [[ -n "$extra" ]]; then
    ENTRY_ERROR="too many fields (expected mode|local|remote[|filter])"
  elif ! valid_entry_mode "$ENTRY_MODE"; then
    ENTRY_ERROR="unknown mode '${ENTRY_MODE}'"
  elif [[ -z "$raw_local" ]]; then
    ENTRY_ERROR="empty local path"
  elif ! safe_remote_path "$ENTRY_REMOTE"; then
    ENTRY_ERROR="unsafe remote subdir '$(printable "$ENTRY_REMOTE")'"
  elif [[ -n "$ENTRY_FILTER" && ! -f "${FILTER_DIR}/${ENTRY_FILTER}" ]]; then
    ENTRY_ERROR="missing filter file '${ENTRY_FILTER}'"
  fi
  [[ -z "$ENTRY_ERROR" ]] || return 1
  ENTRY_LOCAL="$(expand_local_path "$raw_local")"
  return 0
}

# Index (for duplicate checks)

MANIFEST_INDEX_LOADED=0
MANIFEST_NAMES=""
MANIFEST_REMOTES=""
MANIFEST_DUP_NAMES=""
MANIFEST_DUP_REMOTES=""

manifest_index_invalidate() {
  MANIFEST_INDEX_LOADED=0
  MANIFEST_NAMES="" MANIFEST_REMOTES="" MANIFEST_DUP_NAMES="" MANIFEST_DUP_REMOTES=""
}

manifest_index_load() {
  [[ "$MANIFEST_INDEX_LOADED" != "1" ]] || return 0
  local line names="" remotes=""
  while IFS= read -r line; do
    manifest_parse_line "$line" || continue
    names="${names}${ENTRY_NAME}"$'\n'
    remotes="${remotes}${ENTRY_REMOTE}"$'\n'
  done < <(manifest_lines)
  MANIFEST_NAMES="$(printf '%s' "$names" | LC_ALL=C sort -u)"
  MANIFEST_REMOTES="$(printf '%s' "$remotes" | LC_ALL=C sort -u)"
  MANIFEST_DUP_NAMES="$(printf '%s' "$names" | LC_ALL=C sort | uniq -d)"
  MANIFEST_DUP_REMOTES="$(printf '%s' "$remotes" | LC_ALL=C sort | uniq -d)"
  MANIFEST_INDEX_LOADED=1
}

_manifest_membership() {
  local needle="$1" haystack="$2"
  [[ -n "$haystack" ]] || return 1
  printf '%s\n' "$haystack" | grep -Fxq -e "$needle"
}

manifest_has_name() { manifest_index_load && _manifest_membership "$1" "$MANIFEST_NAMES"; }
manifest_has_remote() { manifest_index_load && _manifest_membership "$1" "$MANIFEST_REMOTES"; }
manifest_has_duplicate_name() { manifest_index_load && _manifest_membership "$1" "$MANIFEST_DUP_NAMES"; }
manifest_has_duplicate_remote() { manifest_index_load && _manifest_membership "$1" "$MANIFEST_DUP_REMOTES"; }

# Writers (config/folders.conf and pair filters only; atomic replace)

# manifest_append_pair MODE LOCAL SUB [FILTER] - append one line, preserving
# existing bytes (and seeding the standard header when the file is empty).
manifest_append_pair() {
  local mode="$1" local_path="$2" sub="$3" filter="${4:-}"
  local tmp last
  mkdir -p "$(dirname "$FOLDERS_FILE")"
  tmp="$(mktemp "${FOLDERS_FILE}.tmp.XXXXXX")" || die "cannot create temp file in $(dirname "$FOLDERS_FILE")"
  if [[ -s "$FOLDERS_FILE" ]]; then
    cat "$FOLDERS_FILE" >"$tmp"
    last="$(tail -c 1 "$FOLDERS_FILE" || true)"
    [[ -z "$last" ]] || printf '\n' >>"$tmp"
  else
    cat >"$tmp" <<'EOF'
# Folders chosen with the folder wizard (sciebo folders).
#
# Same format as config/sources.conf:
#   mode | local_path | remote_subdir [ | filter_file ]
#
# This file is managed by the wizard: entries are added by `sciebo folders
# add`/`choose` and removed by `sciebo folders remove NAME`. Manual edits
# and comments are preserved by those commands. Folders are relative to
# sciebo:<REMOTE_BASE>/ (see config/settings.env).
EOF
  fi
  printf '%s|%s|%s%s\n' "$mode" "$local_path" "$sub" "${filter:+"|${filter}"}" >>"$tmp"
  chmod 644 "$tmp"
  mv -f "$tmp" "$FOLDERS_FILE"
  manifest_index_invalidate
}

# manifest_remove_pair NAME - drop the first line whose parsed entry name
# matches NAME. Returns 1 when no such entry exists.
manifest_remove_pair() {
  local want="$1" line="" found=0 tmp=""
  [[ -f "$FOLDERS_FILE" ]] || return 1
  tmp="$(mktemp "${FOLDERS_FILE}.tmp.XXXXXX")" || die "cannot create temp file in $(dirname "$FOLDERS_FILE")"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$found" -eq 0 ]] && manifest_parse_line "$line" && [[ "$ENTRY_NAME" == "$want" ]]; then
      found=1
      continue
    fi
    printf '%s\n' "$line" >>"$tmp"
  done <"$FOLDERS_FILE"
  if [[ "$found" -eq 0 ]]; then
    rm -f "$tmp"
    return 1
  fi
  chmod 644 "$tmp"
  mv -f "$tmp" "$FOLDERS_FILE"
  manifest_index_invalidate
  return 0
}

# manifest_write_pair_filter NAME SUB EXCLUDES... - write
# FILTER_DIR/pair-NAME.txt with one "- SUB/" rule per exclusion. Fails when
# an existing file has different content (manual intervention required).
# Sets MANIFEST_PAIR_FILTER to the file name.
manifest_write_pair_filter() {
  local name="$1" sub="$2"
  shift 2
  local file content rule
  local -a rules=()
  for rule in "$@"; do
    while [[ "$rule" == */ ]]; do
      rule="${rule%/}"
    done
    if [[ -z "$rule" ]] || ! safe_remote_path "$rule"; then
      die "invalid exclude '$(printable "$rule")': must be relative and without '..'"
    fi
    rules[${#rules[@]}]="$rule"
  done
  mkdir -p "$FILTER_DIR"
  file="${FILTER_DIR}/pair-${name}.txt"
  content="# Pair filter for '${sub}' created by the folder wizard."
  content="${content}"$'\n'"# rclone --filter-from rules; see config/filters/README.md."
  if [[ "${#rules[@]}" -gt 0 ]]; then
    for rule in "${rules[@]}"; do
      content="${content}"$'\n'"- ${rule}/"
    done
  fi
  MANIFEST_PAIR_FILTER="pair-${name}.txt"
  if [[ -f "$file" ]]; then
    [[ "$(cat "$file")" == "$content" ]] ||
      die "filter file ${file} exists with different content; edit or remove it manually"
    return 0
  fi
  printf '%s\n' "$content" | atomic_write "$file" 644
  return 0
}
