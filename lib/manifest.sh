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
  local name=""
  sanitize_name_into name "$1"
  [[ -n "$name" ]] || name="entry"
  printf '%s' "$name"
}

manifest_files() { printf '%s\n' "$MANIFEST_FILE" "$FOLDERS_FILE" "$MANIFEST_GENERATED_FILE"; }

# Memoized manifest content (config_lines already applied). The key covers the
# file list with each file's mtime and size, so an external writer or a test
# that swaps a file invalidates the cache even without an explicit call; the
# index invalidator below also drops it on an in-process write.
MANIFEST_LINES_CACHE=""
MANIFEST_LINES_STAMP=""

# The raw stamp is itself cached for the current SECONDS tick, mirroring
# core.sh `_log_stamp_refresh`: repeated walks in one command reuse it without
# forking stat, and an external writer is still seen on the next tick, so the
# staleness is bounded to about one second. _manifest_lines_stamp hands the
# value to callers through _MANIFEST_LINES_STAMP_VALUE, so manifest_lines does
# not need a command substitution for it.
_MANIFEST_STAMP=""
_MANIFEST_STAMP_SECONDS=""
_MANIFEST_STAMP_FILES=""
_MANIFEST_LINES_STAMP_VALUE=""

# _manifest_lines_stamp - refresh _MANIFEST_LINES_STAMP_VALUE with a
# "path<TAB>mtime size" line for every existing manifest file, in order. One
# stat call covers all of them (BSD/GNU spelling); a missing file contributes
# no line, but its name is part of the stamp, so creating or deleting one
# still changes the key.
_manifest_lines_stamp() {
  local files_key="$MANIFEST_FILE"$'\n'"$FOLDERS_FILE"$'\n'"$MANIFEST_GENERATED_FILE"
  if [[ "$_MANIFEST_STAMP_SECONDS" == "$SECONDS" && "$_MANIFEST_STAMP_FILES" == "$files_key" ]]; then
    _MANIFEST_LINES_STAMP_VALUE="$_MANIFEST_STAMP"
    return 0
  fi
  _MANIFEST_STAMP_SECONDS="$SECONDS"
  _MANIFEST_STAMP_FILES="$files_key"
  local -a files=("$MANIFEST_FILE" "$FOLDERS_FILE" "$MANIFEST_GENERATED_FILE")
  [[ -n "${_SCIEBO_STAT_FLAVOR:-}" ]] || _stat_flavor >/dev/null
  if [[ "$_SCIEBO_STAT_FLAVOR" == "bsd" ]]; then
    _MANIFEST_STAMP="$(stat -f "%N"$'\t'"%m %z" "${files[@]}" 2>/dev/null || true)"
  else
    _MANIFEST_STAMP="$(stat -c "%n"$'\t'"%Y %s" "${files[@]}" 2>/dev/null || true)"
  fi
  _MANIFEST_LINES_STAMP_VALUE="$_MANIFEST_STAMP"
}

# _manifest_lines_fill - refresh MANIFEST_LINES_CACHE when the stamp moved.
# Runs in the caller's shell, so a direct caller (manifest_index_load) primes
# the cache for the whole process; subshell callers just revalidate.
_manifest_lines_fill() {
  _manifest_lines_stamp
  [[ "$MANIFEST_LINES_STAMP" == "$_MANIFEST_LINES_STAMP_VALUE" ]] && return 0
  MANIFEST_LINES_CACHE=""
  local file line
  while IFS= read -r file; do
    [[ -f "$file" ]] || continue
    while IFS= read -r line || [[ -n "$line" ]]; do
      MANIFEST_LINES_CACHE+="${line}"$'\n'
    done < <(config_lines "$file")
  done < <(manifest_files)
  MANIFEST_LINES_STAMP="$_MANIFEST_LINES_STAMP_VALUE"
}

manifest_lines() {
  _manifest_lines_fill
  printf '%s' "$MANIFEST_LINES_CACHE"
}

# Sets ENTRY_MODE, ENTRY_LOCAL, ENTRY_REMOTE, ENTRY_FILTER, ENTRY_NAME.
# Returns 1 and sets ENTRY_ERROR for invalid entries. Every manifest walk
# calls this, so it avoids command substitutions for the field trim and the
# local-path expansion.
manifest_parse_line() {
  local line="$1" raw_mode raw_local raw_remote raw_filter extra
  IFS='|' read -r raw_mode raw_local raw_remote raw_filter extra <<<"$line"
  trim_into ENTRY_MODE "${raw_mode:-}"
  trim_into ENTRY_REMOTE "${raw_remote:-}"
  trim_into ENTRY_FILTER "${raw_filter:-}"
  trim_into raw_local "${raw_local:-}"
  ENTRY_ERROR=""
  # Inline the sanitized name (no command substitution): manifest parsing runs
  # once per line and forks otherwise.
  sanitize_name_into ENTRY_NAME "$ENTRY_REMOTE"
  [[ -n "$ENTRY_NAME" ]] || ENTRY_NAME="entry"
  if [[ -n "$extra" ]]; then
    ENTRY_ERROR="too many fields (expected mode|local|remote[|filter])"
  elif ! valid_entry_mode "$ENTRY_MODE"; then
    ENTRY_ERROR="unknown mode '${ENTRY_MODE}'"
  elif [[ -z "$raw_local" ]]; then
    ENTRY_ERROR="empty local path"
  elif ! safe_remote_path "$ENTRY_REMOTE"; then
    ENTRY_ERROR="unsafe remote subdir '${ printable "$ENTRY_REMOTE";}'"
  elif [[ -n "$ENTRY_FILTER" ]] && ! safe_filter_name "$ENTRY_FILTER"; then
    ENTRY_ERROR="invalid filter file '${ printable "$ENTRY_FILTER";}'"
  elif [[ -n "$ENTRY_FILTER" && ! -f "${FILTER_DIR}/${ENTRY_FILTER}" ]]; then
    ENTRY_ERROR="missing filter file '${ENTRY_FILTER}'"
  fi
  [[ -z "$ENTRY_ERROR" ]] || return 1
  # shellcheck disable=SC2034  # read by the sync command module
  expand_local_path_into ENTRY_LOCAL "$raw_local"
  return 0
}

# manifest_each FN [ARG...] - walk every valid manifest entry in order,
# parsing each line into ENTRY_* and calling FN with ARG.... Contract: FN
# returns 0 to continue the walk; a non-zero return stops the walk and
# manifest_each returns that same status (so a callback signals "stop
# here/failure" instead of "break"). Invalid lines are skipped like the
# `manifest_parse_line "$line" || continue` idiom. Runs in the caller's
# shell, so callback changes to globals are visible to the caller.
manifest_each() {
  local fn="$1" line
  shift
  while IFS= read -r line; do
    manifest_parse_line "$line" || continue
    "$fn" "$@" || return $?
  done < <(manifest_lines)
}

# manifest_resolve_local SUB OUT_VAR - resolve SUB through the manifest: the
# first valid entry whose remote subdir equals SUB or is a parent of it wins.
# Sets OUT_VAR to the entry's local path (with the remaining relative path
# appended for a parent match) and MANIFEST_MATCH_NAME/MANIFEST_MATCH_FILTER to
# the entry's name/filter. Returns 1 without a match, leaving both globals
# empty. The resolution rule matches hydrate_resolve and edit_resolve.
MANIFEST_MATCH_NAME=""
MANIFEST_MATCH_FILTER=""
manifest_resolve_local() {
  local sub="$1" out_name="$2" line="" rest=""
  MANIFEST_MATCH_NAME=""
  MANIFEST_MATCH_FILTER=""
  while IFS= read -r line; do
    manifest_parse_line "$line" || continue
    if [[ "$ENTRY_REMOTE" == "$sub" ]]; then
      printf -v "$out_name" '%s' "$ENTRY_LOCAL"
    elif [[ "$sub" == "$ENTRY_REMOTE/"* ]]; then
      rest="${sub#"$ENTRY_REMOTE"/}"
      printf -v "$out_name" '%s' "${ENTRY_LOCAL%/}/${rest}"
    else
      continue
    fi
    # shellcheck disable=SC2034  # read by command modules via this helper
    MANIFEST_MATCH_NAME="$ENTRY_NAME"
    # shellcheck disable=SC2034  # read by command modules via this helper
    MANIFEST_MATCH_FILTER="$ENTRY_FILTER"
    return 0
  done < <(manifest_lines)
  return 1
}

# Index (for duplicate checks)

MANIFEST_INDEX_LOADED=0
MANIFEST_NAMES=""
MANIFEST_REMOTES=""
MANIFEST_DUP_NAMES=""
# shellcheck disable=SC2034  # read by doctor via the manifest index
MANIFEST_DUP_REMOTES=""

manifest_index_invalidate() {
  MANIFEST_INDEX_LOADED=0
  # shellcheck disable=SC2034  # read by doctor via the manifest index
  MANIFEST_NAMES="" MANIFEST_REMOTES="" MANIFEST_DUP_NAMES="" MANIFEST_DUP_REMOTES=""
  MANIFEST_LINES_CACHE="" MANIFEST_LINES_STAMP=""
  _MANIFEST_STAMP="" _MANIFEST_STAMP_SECONDS="" _MANIFEST_STAMP_FILES="" _MANIFEST_LINES_STAMP_VALUE=""
}

# _manifest_unique_split SORTED OUT DUP - split a LC_ALL=C-sorted
# newline-separated list into its unique values (OUT) and the values that
# occur more than once (DUP), both sorted with no trailing newline exactly as
# the old `uniq`/`uniq -d` command substitutions produced them. Pure bash, so
# the index build forks only the sorts and not four uniq pipelines.
_manifest_unique_split() {
  local sorted="$1" out_name="$2" dup_name="$3"
  local line="" prev="" have=0 duped=0 out="" dup=""
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if [[ "$have" -eq 1 && "$line" == "$prev" ]]; then
      if [[ "$duped" -eq 0 ]]; then
        dup+="${line}"$'\n'
        duped=1
      fi
      continue
    fi
    have=1
    duped=0
    prev="$line"
    out+="${line}"$'\n'
  done <<<"$sorted"
  printf -v "$out_name" '%s' "${out%$'\n'}"
  printf -v "$dup_name" '%s' "${dup%$'\n'}"
}

manifest_index_load() {
  [[ "$MANIFEST_INDEX_LOADED" != "1" ]] || return 0
  _manifest_lines_fill
  local line names="" remotes="" sorted_names="" sorted_remotes=""
  while IFS= read -r line; do
    manifest_parse_line "$line" || continue
    names="${names}${ENTRY_NAME}"$'\n'
    remotes="${remotes}${ENTRY_REMOTE}"$'\n'
  done <<<"$MANIFEST_LINES_CACHE"
  sorted_names="$(LC_ALL=C sort <<<"$names")"
  sorted_remotes="$(LC_ALL=C sort <<<"$remotes")"
  _manifest_unique_split "$sorted_names" MANIFEST_NAMES MANIFEST_DUP_NAMES
  _manifest_unique_split "$sorted_remotes" MANIFEST_REMOTES MANIFEST_DUP_REMOTES
  MANIFEST_INDEX_LOADED=1
}

# _manifest_membership NEEDLE HAYSTACK - true when NEEDLE is one line of the
# newline-separated HAYSTACK. Quoting the needle keeps glob characters
# literal, so a remote path like "repos/a*b" cannot match "repos/axb".
_manifest_membership() {
  local needle="$1" haystack="$2"
  [[ -n "$needle" && -n "$haystack" ]] || return 1
  [[ $'\n'"$haystack"$'\n' == *$'\n'"$needle"$'\n'* ]]
}

manifest_has_name() { manifest_index_load && _manifest_membership "$1" "$MANIFEST_NAMES"; }
manifest_has_remote() { manifest_index_load && _manifest_membership "$1" "$MANIFEST_REMOTES"; }
manifest_has_duplicate_name() { manifest_index_load && _manifest_membership "$1" "$MANIFEST_DUP_NAMES"; }

# manifest_names_csv - the configured entry names as one space-separated line
# (MANIFEST_NAMES is already unique and sorted).
manifest_names_csv() {
  manifest_index_load || return 0
  printf '%s' "$MANIFEST_NAMES" | tr '\n' ' '
}

# manifest_require_name NAME [PREFIX] - die with the shared
# "No source named '...'. Available: ..." message unless NAME is configured.
# PREFIX is inserted verbatim (e.g. "watch: ") for callers that label it.
manifest_require_name() {
  manifest_has_name "${1:-}" && return 0
  die "${2:-}No source named '${ printable "${1:-}";}'. Available: ${ trim "$(manifest_names_csv)";}"
}

# Writers (config/folders.conf and pair filters only; atomic replace)

# _manifest_append_emit LINES - print the current FOLDERS_FILE (seeding the
# standard wizard header when it is absent or empty) followed by LINES, a
# newline-terminated body that may be empty. Keeps existing bytes exactly as
# the single-pair writer always did. Writes to stdout; the caller pipes it
# through atomic_write.
_manifest_append_emit() {
  local lines="$1"
  if [[ -s "$FOLDERS_FILE" ]]; then
    cat "$FOLDERS_FILE"
    [[ -z "$(tail -c 1 "$FOLDERS_FILE" || true)" ]] || printf '\n'
  else
    cat <<'EOF'
# Folder pairs added with `sciebo folders` (the wizard).
#
# Same format as config/sources.conf:
#   mode | local_path | remote_subdir [ | filter_file ]
#
# The wizard owns this file: `sciebo folders add`/`choose` append entries and
# `sciebo folders remove NAME` deletes them, preserving manual edits and
# comments. Remote paths are relative to sciebo:<REMOTE_BASE>/ (see
# config/settings.env).
EOF
  fi
  printf '%s' "$lines"
}

# manifest_append_pair MODE LOCAL SUB [FILTER] - append one line, preserving
# existing bytes (and seeding the standard header when the file is empty).
# Validates every field once more so a malformed line cannot be written even
# when a caller forgets a check.
manifest_append_pair() {
  local mode="$1" local_path="$2" sub="$3" filter="${4:-}"
  valid_entry_mode "$mode" || die "invalid mode '${mode}' (expected sync, pull, or bisync)"
  safe_local_path "$local_path" || die "invalid local path '${ printable "$local_path";}'"
  safe_remote_path "$sub" || die "unsafe remote subdir '${ printable "$sub";}'"
  [[ -z "$filter" ]] || safe_filter_name "$filter" || die "invalid filter file '${ printable "$filter";}'"
  _manifest_append_emit "${mode}|${local_path}|${sub}${filter:+"|${filter}"}"$'\n' |
    atomic_write "$FOLDERS_FILE" 644
  manifest_index_invalidate
}

# manifest_append_pairs [RECORD...] - append a batch of pairs with ONE atomic
# write and a single index invalidation. Each RECORD is a TAB-separated
# MODE<TAB>LOCAL<TAB>REMOTE[<TAB>FILTER] line; with no arguments the records
# are read from stdin (blank lines are ignored). Every field is validated
# exactly like manifest_append_pair - an invalid record dies with the same
# message - and a pair whose name or remote already exists (in the current
# index or accepted earlier in this batch) is skipped, preserving the
# "already configured" behavior callers relied on when appending one pair at
# a time. Accepted lines keep their input order; MANIFEST_APPEND_PAIRS_SKIPPED
# is left set to the number of skipped pairs.
MANIFEST_APPEND_PAIRS_SKIPPED=0
manifest_append_pairs() {
  local line="" mode="" local_path="" sub="" filter="" name=""
  local body="" accepted=0
  local -A seen_names=() seen_remotes=()
  local -a records=()
  MANIFEST_APPEND_PAIRS_SKIPPED=0
  manifest_index_load
  if [[ $# -gt 0 ]]; then
    records=("$@")
  else
    while IFS= read -r line || [[ -n "$line" ]]; do
      records+=("$line")
    done
  fi
  for line in "${records[@]}"; do
    [[ -n "$line" ]] || continue
    IFS=$'\t' read -r mode local_path sub filter <<<"$line"
    valid_entry_mode "$mode" || die "invalid mode '${mode}' (expected sync, pull, or bisync)"
    safe_local_path "$local_path" || die "invalid local path '${ printable "$local_path";}'"
    safe_remote_path "$sub" || die "unsafe remote subdir '${ printable "$sub";}'"
    [[ -z "$filter" ]] || safe_filter_name "$filter" || die "invalid filter file '${ printable "$filter";}'"
    sanitize_name_into name "$sub"
    [[ -n "$name" ]] || name="entry"
    if _manifest_membership "$name" "$MANIFEST_NAMES" ||
      _manifest_membership "$sub" "$MANIFEST_REMOTES" ||
      [[ -n "${seen_names[$name]:-}" || -n "${seen_remotes[$sub]:-}" ]]; then
      MANIFEST_APPEND_PAIRS_SKIPPED=$((MANIFEST_APPEND_PAIRS_SKIPPED + 1))
      continue
    fi
    seen_names[$name]=1
    seen_remotes[$sub]=1
    body+="${mode}|${local_path}|${sub}${filter:+"|${filter}"}"$'\n'
    accepted=$((accepted + 1))
  done
  [[ "$accepted" -gt 0 ]] || return 0
  _manifest_append_emit "$body" | atomic_write "$FOLDERS_FILE" 644
  manifest_index_invalidate
  return 0
}

# manifest_remove_pair NAME - drop the first line whose parsed entry name
# matches NAME. Returns 1 when no such entry exists (file left untouched).
manifest_remove_pair() {
  local want="$1" line="" found=0 out=""
  [[ -f "$FOLDERS_FILE" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$found" -eq 0 ]] && manifest_parse_line "$line" && [[ "$ENTRY_NAME" == "$want" ]]; then
      found=1
      continue
    fi
    out="${out}${line}"$'\n'
  done <"$FOLDERS_FILE"
  [[ "$found" -eq 1 ]] || return 1
  printf '%s' "$out" | atomic_write "$FOLDERS_FILE" 644
  manifest_index_invalidate
  return 0
}

# ---------------------------------------------------------------------------
# Per-pair flags (paused/hidden)
#
# One small key=value file per sanitized entry name under
# <PAIR_FLAGS_DIR>/<name> (default ${STATE_DIR}/pairs):
#
#   paused=1
#   hidden=1
#
# The manifest line format never changes; these flags only shape a run
# (a paused pair is skipped, a hidden pair excludes dotfiles). Reads are
# best effort and never fail a run; writes are atomic and mode 600.
# ---------------------------------------------------------------------------

# Pin the directory at source time only when state is already derived (tests
# and exported overrides); otherwise manifest_pair_flags_dir_into derives it
# from the current STATE_DIR on every call, so a profile switch is honored.
if [[ -n "${STATE_DIR:-}" ]]; then
  : "${PAIR_FLAGS_DIR:=${STATE_DIR}/pairs}"
fi

# Resolved flag-file paths, keyed by "dir<TAB>name". The resolution only
# depends on the sanitized name and the current flags directory, so a profile
# switch (a new dir) resolves a fresh key and never reuses a stale path.
declare -g -A _MANIFEST_PAIR_FLAGS_FILES=()

# The parsed paused/hidden flags for the last NAME read. The paused and hidden
# predicates are usually asked back to back for the same entry, so this shares
# their file read; manifest_pair_flags_set drops it after a write.
MANIFEST_PAIR_FLAGS_LOADED_NAME=""
MANIFEST_PAIR_PAUSED="0"
MANIFEST_PAIR_HIDDEN="0"

# manifest_pair_flags_dir_into VAR - set VAR to the flags directory without a
# command substitution; return 1 when neither PAIR_FLAGS_DIR nor STATE_DIR is
# known.
manifest_pair_flags_dir_into() {
  if [[ -n "${PAIR_FLAGS_DIR:-}" ]]; then
    printf -v "$1" '%s' "${PAIR_FLAGS_DIR%/}"
    return 0
  fi
  [[ -n "${STATE_DIR:-}" ]] || return 1
  printf -v "$1" '%s' "${STATE_DIR%/}/pairs"
  return 0
}

# manifest_pair_flags_file_into VAR NAME - set VAR to NAME's flag-file path
# without a command substitution; the path is memoized per "dir<TAB>name".
# Return 1 when NAME is unusable or no state directory is known.
manifest_pair_flags_file_into() {
  local out="$1" raw="${2:-}" sname="" sdir="" skey="" resolved=""
  sanitize_name_into sname "$raw"
  [[ -n "$sname" ]] || return 1
  manifest_pair_flags_dir_into sdir || return 1
  skey="${sdir}"$'\t'"${sname}"
  if [[ -v "_MANIFEST_PAIR_FLAGS_FILES[$skey]" ]]; then
    printf -v "$out" '%s' "${_MANIFEST_PAIR_FLAGS_FILES[$skey]}"
    return 0
  fi
  resolved="${sdir}/${sname}"
  _MANIFEST_PAIR_FLAGS_FILES[$skey]="$resolved"
  printf -v "$out" '%s' "$resolved"
  return 0
}

# manifest_pair_flags_file NAME - print NAME's flag-file path; return 1 when
# NAME is unusable or no state directory is known.
manifest_pair_flags_file() {
  local file=""
  manifest_pair_flags_file_into file "${1:-}" || return 1
  printf '%s' "$file"
  return 0
}

# manifest_pair_flags_load NAME - parse NAME's flag file once into the globals
# MANIFEST_PAIR_PAUSED and MANIFEST_PAIR_HIDDEN (0/1; absent is 0). The last
# NAME's parse is kept so the paused and hidden predicates share one read.
# Best effort: a missing or unreadable file leaves both flags 0.
manifest_pair_flags_load() {
  local name="${1:-}" file="" k="" v=""
  [[ "$MANIFEST_PAIR_FLAGS_LOADED_NAME" == "$name" ]] && return 0
  MANIFEST_PAIR_FLAGS_LOADED_NAME="$name"
  MANIFEST_PAIR_PAUSED="0"
  MANIFEST_PAIR_HIDDEN="0"
  manifest_pair_flags_file_into file "$name" || return 0
  [[ -f "$file" && -r "$file" ]] || return 0
  while IFS='=' read -r k v || [[ -n "$k" ]]; do
    case "$k" in
      paused) MANIFEST_PAIR_PAUSED="$v" ;;
      hidden) MANIFEST_PAIR_HIDDEN="$v" ;;
    esac
  done <"$file"
  return 0
}

# manifest_pair_flags_set NAME KEY VALUE - store KEY=VALUE (KEY is paused or
# hidden, VALUE is 0 or 1) in NAME's flag file, preserving the other key and
# ignoring unrelated lines. Rejects an invalid KEY/VALUE or unusable NAME.
# Returns 1 when the file cannot be written; callers may treat that as best
# effort. Writes go through atomic_write (mode 600).
manifest_pair_flags_set() {
  local name="$1" key="$2" value="$3" file="" out="" k="" v="" found=0
  case "$key" in paused | hidden) ;; *) return 1 ;; esac
  case "$value" in 0 | 1) ;; *) return 1 ;; esac
  manifest_pair_flags_file_into file "$name" || return 1
  if [[ -f "$file" && -r "$file" ]]; then
    while IFS='=' read -r k v || [[ -n "$k" ]]; do
      case "$k" in
        paused | hidden) ;;
        *) continue ;;
      esac
      if [[ "$k" == "$key" ]]; then
        out+="${key}=${value}"$'\n'
        found=1
      else
        out+="${k}=${v}"$'\n'
      fi
    done <"$file"
  fi
  [[ "$found" -eq 1 ]] || out+="${key}=${value}"$'\n'
  printf '%s' "$out" | atomic_write "$file" 600 >/dev/null 2>&1 || return 1
  MANIFEST_PAIR_FLAGS_LOADED_NAME=""
  return 0
}

# manifest_pair_paused NAME / manifest_pair_hidden NAME - true when NAME's
# flag is set to 1. Best effort: a missing or unreadable flag file is "off".
# Both share manifest_pair_flags_load's single parse of the flag file.
manifest_pair_paused() {
  manifest_pair_flags_load "${1:-}"
  [[ "$MANIFEST_PAIR_PAUSED" == "1" ]]
}
manifest_pair_hidden() {
  manifest_pair_flags_load "${1:-}"
  [[ "$MANIFEST_PAIR_HIDDEN" == "1" ]]
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
    rule=${ strip_trailing_slashes "$rule";}
    if [[ -z "$rule" ]] || ! safe_remote_path "$rule"; then
      die "invalid exclude '${ printable "$rule";}': must be relative and without '..'"
    fi
    rules[${#rules[@]}]="$rule"
  done
  mkdir -p "$FILTER_DIR"
  file="${FILTER_DIR}/pair-${name}.txt"
  content="# Pair filter for '${sub}' created by the folder wizard."
  content="${content}"$'\n'"# rclone --filter-from rules; see config/filters/README.md."
  for rule in "${rules[@]}"; do
    content="${content}"$'\n'"- ${rule}/"
  done
  # shellcheck disable=SC2034  # read by the folder command modules
  MANIFEST_PAIR_FILTER="pair-${name}.txt"
  if [[ -f "$file" ]]; then
    [[ "$(<"$file")" == "$content" ]] ||
      die "filter file ${file} exists with different content; edit or remove it manually"
    return 0
  fi
  printf '%s\n' "$content" | atomic_write "$file" 644
  # A new filter can turn a previously skipped manifest entry into a valid
  # one, so drop the parsed/index state along with the content cache.
  manifest_index_invalidate
  return 0
}
