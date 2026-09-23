#!/bin/bash
# policy.sh - desktop-parity policy helpers shared by sync, hydrate, doctor,
# and the folder wizard.
#
# The helpers here turn the policy settings (INVALID_NAME_POLICY,
# CASE_CLASH_POLICY, E2EE_POLICY, EXTERNAL_STORAGE_POLICY, SYMLINK_POLICY,
# CHECKSUM, MOVE_TO_TRASH, DELETE_FILES_THRESHOLD/ASK_DELETE, chunk bounds)
# into rclone arguments, preflight checks, and warnings. The argument
# helpers append one rclone argument at a time to the argv array named by
# their first parameter (the nameref out-param style of
# _rclone_global_flags_into), so callers build their argv without a
# subshell or newline re-parsing; everything else is pure or
# read-only. policy_rename_case_clash is the one exception: it renames a
# local path and is only called for CASE_CLASH_POLICY=rename on an apply.

# blacklist_exclude_pattern escapes the rclone glob for the remote-path
# policy excludes; doctor and the folder wizard reach the engine without
# lib/blacklist.sh being loaded otherwise.
sciebo_require_module blacklist blacklist_exclude_pattern

# _policy_exclude OUT PATTERN - append one rclone --exclude pair (flag,
# pattern) to the argv array named OUT.
_policy_exclude() {
  # shellcheck disable=SC2178  # nameref to an argv array
  local -n _pe_ref="$1"
  _pe_ref+=("--exclude" "$2")
}

# _policy_case_class TEXT - turn lowercase ASCII letters into rclone glob
# character classes ("con" -> "[cC][oO][nN]"), so reserved device names
# match case-insensitively; non-letters stay literal. The uppercase form is
# looked up in a fixed alphabet, so no `tr` process is spawned per letter.
_policy_case_class() {
  local s="$1" out="" ch="" idx=""
  local lower="abcdefghijklmnopqrstuvwxyz" upper="ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  while [[ -n "$s" ]]; do
    ch="${s:0:1}"
    s="${s:1}"
    case "$ch" in
      [a-z])
        idx="${lower%%"$ch"*}"
        out="${out}[${ch}${upper:${#idx}:1}]"
        ;;
      *) out="${out}[${ch}]" ;;
    esac
  done
  printf '%s' "$out"
}

# policy_invalid_name NAME - rc 0 when NAME is not portable across
# platforms: it contains a Windows-invalid character (<>:"|?* or a
# bracket), ends with a dot or space, or is a reserved device name
# (CON/PRN/AUX/NUL, COM1-9, LPT1-9) case-insensitively and with or without
# an extension.
policy_invalid_name() {
  local name="${1:-}" stem=""
  [[ -n "$name" ]] || return 1
  case "$name" in
    *['<>:"|?*']* | *'['* | *']'* | *'.' | *' ') return 0 ;;
  esac
  stem="${name%%.*}"
  # Case-insensitive patterns instead of a `tr` fork per name: doctor calls
  # this once per scanned path (tens of thousands on a large tree).
  case "$stem" in
    [Cc][Oo][Nn] | [Pp][Rr][Nn] | [Aa][Uu][Xx] | [Nn][Uu][Ll] | \
      [Cc][Oo][Mm][1-9] | [Ll][Pp][Tt][1-9]) return 0 ;;
  esac
  return 1
}

# policy_name_exclude_args OUT - append the rclone --exclude pairs covering
# non-portable names to the argv array named OUT, or nothing for
# INVALID_NAME_POLICY=warn/allow. The trailing space uses a character class
# because rclone trims a literal trailing space down
# to "*". The reserved device names are covered by glob character classes so
# any capitalization matches; the literal uppercase forms document the
# intent.
policy_name_exclude_args() {
  # shellcheck disable=SC2178  # nameref to an argv array
  local -n out_ref="$1"
  local pattern="" class="" upper="" base="" LC_ALL=C
  [[ "${INVALID_NAME_POLICY:-}" == "exclude" ]] || return 0
  for pattern in '*[<>:"|?*]*' '*\[*' '*\]*' '*.' '*[ ]'; do
    _policy_exclude out_ref "$pattern"
  done
  for base in con prn aux nul; do
    upper="${base^^}"
    class=${ _policy_case_class "$base";}
    _policy_exclude out_ref "$upper"
    _policy_exclude out_ref "${upper}.*"
    _policy_exclude out_ref "$class"
    _policy_exclude out_ref "${class}.*"
  done
  for base in com lpt; do
    class=${ _policy_case_class "$base";}
    _policy_exclude out_ref "${class}[1-9]"
    _policy_exclude out_ref "${class}[1-9].*"
  done
  return 0
}

# policy_symlink_args OUT - append SYMLINK_POLICY's rclone argument to the
# argv array named OUT: --skip-links (silence rclone's skipped-symlink
# warnings), --copy-links (follow), or --links (translate to .rclonelink
# files); nothing when the policy is unset.
policy_symlink_args() {
  # shellcheck disable=SC2178  # nameref to an argv array
  local -n out_ref="$1"
  case "${SYMLINK_POLICY:-}" in
    skip) out_ref+=(--skip-links) ;;
    follow) out_ref+=(--copy-links) ;;
    translate) out_ref+=(--links) ;;
  esac
  return 0
}

# policy_checksum_args OUT MODE - with CHECKSUM=1 append --checksum for
# sync/pull or bisync's --compare pair to the argv array named OUT;
# nothing otherwise.
policy_checksum_args() {
  # shellcheck disable=SC2178  # nameref to an argv array
  local -n out_ref="$1"
  local mode="${2:-}"
  [[ "${CHECKSUM:-0}" == "1" ]] || return 0
  case "$mode" in
    sync | pull) out_ref+=(--checksum) ;;
    bisync) out_ref+=(--compare "size,modtime,checksum") ;;
  esac
  return 0
}

# policy_trash_args OUT MODE - with MOVE_TO_TRASH=1 on a pull/bisync append
# the --backup-dir pair for BACKUP_DIR (when set) or LOCAL_TRASH_DIR to the
# argv array named OUT; nothing otherwise. The caller appends the per-entry
# subdirectory.
policy_trash_args() {
  # shellcheck disable=SC2178  # nameref to an argv array
  local -n out_ref="$1"
  local mode="${2:-}" dir=""
  [[ "${MOVE_TO_TRASH:-0}" == "1" ]] || return 0
  case "$mode" in
    pull | bisync) ;;
    *) return 0 ;;
  esac
  dir="${BACKUP_DIR:-}"
  [[ -n "$dir" ]] || dir="${LOCAL_TRASH_DIR:-}"
  [[ -n "$dir" ]] || return 0
  out_ref+=(--backup-dir "$dir")
  return 0
}

# policy_delete_guard_args OUT - when ASK_DELETE=1 and MAX_DELETE is unlimited
# (-1), append the --max-delete guard capped at DELETE_FILES_THRESHOLD to the
# argv array named OUT; nothing when ASK_DELETE is off or an explicit
# MAX_DELETE cap is set.
policy_delete_guard_args() {
  # shellcheck disable=SC2178  # nameref to an argv array
  local -n out_ref="$1"
  local threshold="${DELETE_FILES_THRESHOLD:-100}"
  [[ "${ASK_DELETE:-0}" == "1" ]] || return 0
  [[ "${MAX_DELETE:--1}" == "-1" ]] || return 0
  case "$threshold" in
    '' | *[!0-9]*) threshold=100 ;;
  esac
  out_ref+=(--max-delete "$threshold")
  return 0
}

# policy_delete_guard_hit LOGFILE - rc 0 when LOGFILE contains rclone's
# max-delete abort notice (wording differs across rclone versions, so all
# known spellings match case-insensitively).
policy_delete_guard_hit() {
  local logfile="${1:-}"
  [[ -n "$logfile" && "$logfile" != "-" && "$logfile" != "/dev/stdout" ]] || return 1
  [[ -f "$logfile" ]] || return 1
  LC_ALL=C grep -a -E -i -q \
    -- '(--max-delete threshold reached|deletions stopped due to|maximum delete limit)' \
    "$logfile" 2>/dev/null
}

# policy_chunk_size RAW - print RAW clamped to MIN_CHUNK_SIZE and
# MAX_CHUNK_SIZE using the shared size parser. An empty or unparseable
# value is printed unchanged (empty stays empty).
policy_chunk_size() {
  local raw="${1:-}" value="${1:-}" bytes="" min_raw="" max_raw="" min="" max=""
  [[ -n "$raw" ]] || return 0
  if type -t size_suffix_bytes >/dev/null 2>&1; then
    bytes=${ size_suffix_bytes "$raw" 2>/dev/null;} || bytes=""
  fi
  if [[ -n "$bytes" ]]; then
    min_raw="${MIN_CHUNK_SIZE:-}"
    if [[ -n "$min_raw" ]] && min=${ size_suffix_bytes "$min_raw" 2>/dev/null;} &&
      [[ -n "$min" && "$bytes" -lt "$min" ]]; then
      value="$min_raw"
      bytes="$min"
    fi
    max_raw="${MAX_CHUNK_SIZE:-}"
    if [[ -n "$max_raw" ]] && max=${ size_suffix_bytes "$max_raw" 2>/dev/null;} &&
      [[ -n "$max" && "$bytes" -gt "$max" ]]; then
      value="$max_raw"
    fi
  fi
  printf '%s\n' "$value"
  return 0
}

# _policy_case_pair_runs - read "key<TAB>path" lines already sorted by key and
# print "FIRST<TAB>SECOND" for each adjacent run that shares a key. Shared by
# the local and remote case-clash scanners so their pairing stays identical.
_policy_case_pair_runs() {
  local line="" key="" rel="" prev_key="" prev_rel="" have_prev=0
  while IFS= read -r line; do
    record_split "$line" key rel
    [[ -n "$rel" ]] || continue
    if [[ "$have_prev" -eq 1 && "$key" == "$prev_key" ]]; then
      printf '%s\t%s\n' "$prev_rel" "$rel"
    fi
    prev_key="$key"
    prev_rel="$rel"
    have_prev=1
  done
}

# _policy_case_pairs_from_rels LIMIT - read one relative path per line and
# print the "FIRST<TAB>SECOND" case-clash pairs: lowercase each path with
# LC_ALL=C tolower (so multi-byte bytes are untouched), keep only the first
# LIMIT paths, sort by key, and pair adjacent runs. The one pipeline shared
# by policy_case_clashes and policy_case_clashes_remote.
_policy_case_pairs_from_rels() {
  local limit="${1:-50000}"
  LC_ALL=C awk -v limit="$limit" '
    {
      rel = $0
      if (rel == "") next
      n++
      if (n > limit) exit
      printf "%s\t%s\n", tolower(rel), rel
    }
  ' |
    LC_ALL=C sort |
    _policy_case_pair_runs
}

# --- policy_case_clashes: process-lifetime scan cache ----------------------
#
# policy_case_clashes walks a whole tree with find/awk/sort, and the sync and
# doctor callers invoke it once per manifest entry, capturing the pairs in a
# command-substitution subshell. A directory visited more than once in a run
# therefore walked the tree again for every entry. The cache below keys the
# resulting pairs by the scanned directory (and the scan limit) in a
# process-scoped directory on disk, so the result survives those subshells and
# a repeated scan is one file read. A miss is the old walk, so a directory
# that is never re-scanned behaves exactly as before.
#
# The directory is allocated with mktemp -d on the first cache read or write
# (sourcing this module runs no mktemp), so its name is random rather than a
# predictable `${TMPDIR}/sciebo-case-cache.$$` a local attacker could
# pre-seed in a shared TMPDIR. The sync/doctor callers invoke the scan as the
# forkless `${ policy_case_clashes ...;}` form, so the allocation persists in
# the caller's shell and every later subshell shares it. Before every read
# and write the directory is revalidated as a real (non-symlink) directory we
# own with no group/other write bits; a pre-seeded or tampered path disables
# the cache and the caller scans directly. Entries are written to a
# same-directory mktemp file and renamed into place, so no write truncates or
# follows an existing path. The path is registered for exit cleanup
# (sciebo_temp_cleanup removes it).
: "${_POLICY_CASE_CACHE_DIR:=}"
_POLICY_CASE_CACHE_HIT=0
_POLICY_CASE_CACHE_RESULT=""
# Directory string that last passed _policy_case_cache_ok. A shell only ever
# validates the one cache directory it allocated, so a positive result is
# memoized and the per-read/write stat disappears; the string comparison
# means a caller that swaps in a different path is still checked afresh.
_POLICY_CASE_CACHE_OK_DIR=""

# _policy_case_cache_ok DIR - true when DIR is a usable scan cache: an existing
# real directory (not a symlink) owned by this user with no group or other
# write bits. Anything else (a shared-TMPDIR pre-seed, a replaced symlink, a
# world-writable directory) is refused so policy_case_clashes scans directly.
# The BSD/GNU stat spelling comes from core.sh's process-cached
# _stat_flavor, so a cache read or write runs one stat instead of probing
# both spellings every time; a failed or non-octal reading still refuses the
# cache exactly like the old two-probe fallback (on a host whose flavor is
# detected correctly the other spelling cannot succeed anyway).
_policy_case_cache_ok() {
  local dir="${1:-}" mode="" group="" other=""
  [[ -n "$dir" && -d "$dir" && ! -L "$dir" ]] || return 1
  [[ -O "$dir" ]] || return 1
  [[ "$dir" == "$_POLICY_CASE_CACHE_OK_DIR" ]] && return 0
  [[ -n "${_SCIEBO_STAT_FLAVOR:-}" ]] || _stat_flavor >/dev/null
  if [[ "${_SCIEBO_STAT_FLAVOR}" == "gnu" ]]; then
    mode="$(stat -c '%a' "$dir" 2>/dev/null)" || mode=""
  else
    mode="$(stat -f '%Lp' "$dir" 2>/dev/null)" || mode=""
  fi
  case "$mode" in '' | *[!0-7]*) mode="" ;; esac
  [[ -n "$mode" ]] || return 1
  # Group/other write is octal 2 (or 3/6/7); any of them makes the directory
  # unsafe to trust in a shared TMPDIR.
  group="${mode: -2:1}"
  other="${mode: -1:1}"
  case "${group}${other}" in
    *[2367]*) return 1 ;;
  esac
  _POLICY_CASE_CACHE_OK_DIR="$dir"
  return 0
}

# _policy_case_cache_new_dir - allocate a fresh random cache directory with
# mktemp -d, store it in _POLICY_CASE_CACHE_DIR, and register it for exit
# cleanup. Leaves the variable empty (caching disabled) when mktemp fails. A
# usable directory from an earlier allocation is kept, so re-sourcing the
# module (or a second read/write) never strands a second directory behind the
# one cleanup knows about. Nothing calls this at source time:
# _policy_case_cache_read and _policy_case_cache_write allocate on first use.
_policy_case_cache_new_dir() {
  local dir=""
  _policy_case_cache_ok "$_POLICY_CASE_CACHE_DIR" && return 0
  _POLICY_CASE_CACHE_DIR=""
  dir="$(mktemp -d "${TMPDIR:-/tmp}/sciebo-case-cache.XXXXXX" 2>/dev/null)" || dir=""
  [[ -n "$dir" ]] || return 1
  _POLICY_CASE_CACHE_DIR="$dir"
  if type -t sciebo_temp_register >/dev/null 2>&1; then
    sciebo_temp_register "$dir"
  fi
  return 0
}

# _policy_case_cache_ensure - lazily allocate the cache directory on the
# first read/write of this shell. An explicitly set but rejected directory
# (see _policy_case_cache_ok) is left alone so it stays refused; only the
# empty "never allocated" state triggers an attempt. mktemp failure is
# tolerated like the old source-time call: the cache stays disabled and the
# scans fall back to a direct walk.
_policy_case_cache_ensure() {
  [[ -n "$_POLICY_CASE_CACHE_DIR" ]] || _policy_case_cache_new_dir || true
  return 0
}

# _policy_case_cache_key_into VAR DIR LIMIT - FNV-1a over the key bytes,
# stored in VAR as lowercase hex. The key only names the cache file; the key
# line is written inside it and rechecked, so a hash collision costs a rescan
# instead of returning another directory's pairs.
_policy_case_cache_key_into() {
  local -n _pcc_key_out="$1"
  local s="$2" h=2166136261 i=0 c=0
  local LC_ALL=C
  for ((i = 0; i < ${#s}; i++)); do
    printf -v c '%d' "'${s:i:1}"
    h=$(((h ^ c) * 16777619 & 4294967295))
  done
  printf -v _pcc_key_out '%x' "$h"
}

# _policy_case_cache_read DIR LIMIT - set _POLICY_CASE_CACHE_HIT and
# _POLICY_CASE_CACHE_RESULT from the cached pairs; a miss leaves HIT 0. The
# first line is the key, so a collision is detected and treated as a miss.
# The cache directory is allocated here (lazily) on the first read.
_policy_case_cache_read() {
  local dir="$1" limit="$2" key="" file="" data=""
  _POLICY_CASE_CACHE_HIT=0
  _POLICY_CASE_CACHE_RESULT=""
  _policy_case_cache_ensure
  _policy_case_cache_ok "$_POLICY_CASE_CACHE_DIR" || return 0
  _policy_case_cache_key_into key "${dir}"$'\t'"${limit}"
  file="${_POLICY_CASE_CACHE_DIR}/${key}"
  [[ -f "$file" && ! -L "$file" ]] || return 0
  data="$(<"$file")" 2>/dev/null || return 0
  [[ "${data%%$'\n'*}" == "${dir}"$'\t'"${limit}" ]] || return 0
  if [[ "$data" == *$'\n'* ]]; then
    _POLICY_CASE_CACHE_RESULT="${data#*$'\n'}"
  fi
  _POLICY_CASE_CACHE_HIT=1
  return 0
}

# _policy_case_cache_write DIR LIMIT RESULT - store RESULT (possibly empty)
# under DIR/LIMIT. Best effort: a read-only TMPDIR only loses the caching.
# The cache directory is allocated here too, so a write never needs a prior
# read to have run.
_policy_case_cache_write() {
  local dir="$1" limit="$2" result="$3" key="" file="" tmp=""
  _policy_case_cache_ensure
  _policy_case_cache_ok "$_POLICY_CASE_CACHE_DIR" || return 0
  _policy_case_cache_key_into key "${dir}"$'\t'"${limit}"
  file="${_POLICY_CASE_CACHE_DIR}/${key}"
  # A same-directory mktemp file plus rename: O_EXCL creation cannot follow a
  # pre-seeded symlink, and rename replaces any existing entry atomically.
  tmp="$(mktemp "${_POLICY_CASE_CACHE_DIR}/.tmp.XXXXXX" 2>/dev/null)" || return 0
  if ! {
    printf '%s\t%s\n' "$dir" "$limit"
    [[ -z "$result" ]] || printf '%s\n' "$result"
  } >"$tmp" 2>/dev/null; then
    rm -f -- "$tmp" 2>/dev/null || true
    return 0
  fi
  mv -f -- "$tmp" "$file" 2>/dev/null || rm -f -- "$tmp" 2>/dev/null || true
  return 0
}

# _policy_case_cache_reset - drop every memoized scan by emptying the cache
# directory in place. A rename (sync_case_clash_preflight apply) changes the
# tree, so stale pairs must not be reused; the directory itself is kept so
# command-substitution subshells share one stable path with the parent.
_policy_case_cache_reset() {
  local dir="$_POLICY_CASE_CACHE_DIR" entry=""
  _POLICY_CASE_CACHE_HIT=0
  _POLICY_CASE_CACHE_RESULT=""
  _policy_case_cache_ok "$dir" || return 0
  for entry in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    rm -rf -- "$entry" 2>/dev/null || true
  done
  return 0
}

# policy_case_clashes DIR - print "FIRST<TAB>SECOND" pairs of paths below
# DIR whose relative paths differ only by ASCII case. The pair is in
# LC_ALL=C sort order, so FIRST is the name a case-insensitive transfer
# would keep and SECOND is the one to exclude or rename. Read-only and
# bounded at POLICY_CASE_SCAN_LIMIT paths. Repeated scans of one directory in
# a process reuse the first result.
policy_case_clashes() {
  local dir="${1:-}" limit="${POLICY_CASE_SCAN_LIMIT:-50000}" result=""
  [[ -n "$dir" && -d "$dir" ]] || return 0
  _policy_case_cache_read "$dir" "$limit"
  if [[ "$_POLICY_CASE_CACHE_HIT" -eq 1 ]]; then
    [[ -z "$_POLICY_CASE_CACHE_RESULT" ]] || printf '%s\n' "$_POLICY_CASE_CACHE_RESULT"
    return 0
  fi
  result="$(
    find -P "$dir" -print 2>/dev/null |
      LC_ALL=C awk -v dir="$dir" '
        {
          path = $0
          if (path == dir) next
          rel = path
          if (substr(dir, length(dir), 1) == "/") {
            if (substr(path, 1, length(dir)) == dir) rel = substr(path, length(dir) + 1)
          } else if (substr(path, 1, length(dir) + 1) == dir "/") {
            rel = substr(path, length(dir) + 2)
          }
          if (rel == "") next
          print rel
        }
      ' |
      _policy_case_pairs_from_rels "$limit"
  )"
  _policy_case_cache_write "$dir" "$limit" "$result"
  [[ -z "$result" ]] || printf '%s\n' "$result"
  return 0
}

# policy_case_clashes_remote SPEC - print "FIRST<TAB>SECOND" pairs of paths
# below the remote SPEC whose relative paths differ only by ASCII case. It
# lists the tree with rclone_lsf_paths, lowercases each path with LC_ALL=C
# tolower (so multi-byte bytes are untouched), sorts, and pairs adjacent
# equal keys exactly like policy_case_clashes: FIRST is the name a
# case-insensitive transfer would keep and SECOND is the loser. Read-only,
# bounded at POLICY_CASE_SCAN_LIMIT paths; prints nothing when the listing
# is empty or the remote is unreachable.
policy_case_clashes_remote() {
  local spec="${1:-}" limit="${POLICY_CASE_SCAN_LIMIT:-50000}"
  local listing="" rc=0
  [[ -n "$spec" ]] || return 0
  listing="$(rclone_lsf_paths "$spec")" || rc=$?
  [[ "$rc" -eq 0 ]] || return 1
  [[ -n "$listing" ]] || return 0
  printf '%s\n' "$listing" |
    _policy_case_pairs_from_rels "$limit"
  return 0
}

# policy_remote_case_exclude REL - print the rclone --exclude pattern for a
# remote case-clash loser REL, escaped by blacklist_exclude_pattern. A
# directory (REL carries the listing's trailing "/") gets a "/**" suffix so
# the whole subtree is excluded instead of a bare "/<sub>"; a file keeps the
# exact anchored pattern. Prints nothing for an empty REL.
policy_remote_case_exclude() {
  local rel="${1:-}" escaped="" dir=0
  [[ -n "$rel" ]] || return 0
  case "$rel" in
    */)
      dir=1
      rel="${rel%/}"
      ;;
  esac
  escaped="$(blacklist_exclude_pattern "$rel")"
  [[ -n "$escaped" ]] || return 0
  if [[ "$dir" -eq 1 ]]; then
    printf '%s/**\n' "$escaped"
  else
    printf '%s\n' "$escaped"
  fi
  return 0
}

# policy_rename_case_clash DIR REL - rename DIR/REL to "<name> (case
# conflict)<ext>" next to it, appending -2, -3, ... until the name is
# free (the conflicts.sh keep-both convention), and print the new path
# relative to DIR. rc 1 when REL is unsafe, missing, or cannot be moved.
policy_rename_case_clash() {
  local dir="${1:-}" rel="${2:-}" path="" name="" stem="" ext="" candidate="" newrel="" n=1
  [[ -n "$dir" && -n "$rel" ]] || return 1
  case "$rel" in
    /* | .. | ../* | */.. | */../*) return 1 ;;
  esac
  path="${dir%/}/${rel}"
  [[ -e "$path" ]] || return 1
  name="${rel##*/}"
  case "$name" in
    *.*)
      stem="${name%.*}"
      ext=".${name##*.}"
      ;;
    *)
      stem="$name"
      ext=""
      ;;
  esac
  [[ -n "$stem" ]] || {
    stem="$name"
    ext=""
  }
  candidate="${path%/*}/${stem} (case conflict)${ext}"
  while [[ -e "$candidate" ]]; do
    n=$((n + 1))
    candidate="${path%/*}/${stem} (case conflict)-${n}${ext}"
  done
  mv -- "$path" "$candidate" || return 1
  # The tree changed, so any memoized scan of it is stale.
  _policy_case_cache_reset
  if [[ "$rel" == */* ]]; then
    newrel="${rel%/*}/${candidate##*/}"
  else
    newrel="${candidate##*/}"
  fi
  printf '%s\n' "$newrel"
  return 0
}

# choose_policy_decision POLICY CONFIRMED - shared pure decision for one
# policy gate: prints "proceed" or "skip" and returns 0 to keep the item /
# 2 to skip it. allow and warn always proceed, skip and exclude always
# skip, and ask proceeds only when CONFIRMED is 1 (the caller resolves the
# TTY/non-interactive answer). An unset or unknown policy proceeds, so a
# missing setting can never block a run or the wizard. Used by the wizard
# gates and the remote-path engine below.
choose_policy_decision() {
  local policy="${1:-}" confirmed="${2:-0}"
  case "$policy" in
    allow | warn) printf 'proceed\n' ;;
    skip | exclude)
      printf 'skip\n'
      return 2
      ;;
    ask)
      if [[ "$confirmed" == "1" ]]; then
        printf 'proceed\n'
      else
        printf 'skip\n'
        return 2
      fi
      ;;
    *) printf 'proceed\n' ;;
  esac
  return 0
}

# _policy_remote_emit SINK MESSAGE - record MESSAGE in POLICY_REMOTE_MESSAGE
# and hand it to SINK (default warn). A caller that only collects state sets
# POLICY_REMOTE_SINK=: to stay silent.
_policy_remote_emit() {
  POLICY_REMOTE_MESSAGE="${2:-}"
  "${1:-warn}" "$POLICY_REMOTE_MESSAGE"
}

# _policy_remote_list_has LIST ITEM - true when the newline-separated LIST
# contains ITEM as one whole entry.
_policy_remote_list_has() {
  local list=$'\n'"$1"$'\n' item="${2:-}"
  [[ -n "$item" ]] || return 1
  [[ "$list" == *$'\n'"${item}"$'\n'* ]]
}

# _policy_remote_scope_find PROBE SUB - print SUB when PROBE reports it, else
# its immediate parent when PROBE reports that; rc 1 when neither is
# reported. The wizard gates use this parent-aware lookup so a chosen folder
# is still gated when only its parent is encrypted/mounted.
_policy_remote_scope_find() {
  local probe="$1" sub="$2" parent="" paths=""
  paths=${ "$probe" "$sub" 2>/dev/null;} || paths=""
  if _policy_remote_list_has "$paths" "$sub"; then
    printf '%s' "$sub"
    return 0
  fi
  parent="${sub%/*}"
  [[ "$parent" != "$sub" && -n "$parent" ]] || return 1
  paths=${ "$probe" "$parent" 2>/dev/null;} || paths=""
  _policy_remote_list_has "$paths" "$parent" || return 1
  printf '%s' "$parent"
  return 0
}

# _policy_remote_confirm KIND - true when the caller's POLICY_REMOTE_CONFIRM
# callback (if any) confirms the interactive ask; an unset callback is a
# "no", which is how a non-interactive caller turns ask into skip.
_policy_remote_confirm() {
  [[ -n "${POLICY_REMOTE_CONFIRM:-}" ]] || return 1
  "$POLICY_REMOTE_CONFIRM" "${1:-}"
}

# _policy_remote_set_checked NAME COUNT - store COUNT in the variable named by
# NAME (the engine's CHECKED_VAR contract); a blank NAME is a no-op so the
# wizard can share the skip helper without touching the caller's bookkeeping.
_policy_remote_set_checked() {
  [[ -n "${1:-}" ]] || return 0
  printf -v "$1" '%s' "${2:-0}"
}

# _policy_remote_skip CHECKED_NAME REASON MESSAGE - emit MESSAGE through the
# active sink when given, mark the engine as skipping with REASON, store
# POLICY_REMOTE_COUNT in CHECKED_NAME, and return 2 (the engine's skip code).
_policy_remote_skip() {
  local checked_name="${1:-}" reason="${2:-}" message="${3:-}"
  [[ -n "$message" ]] && _policy_remote_emit "${POLICY_REMOTE_SINK:-warn}" "$message"
  POLICY_REMOTE_RESULT=skip
  POLICY_REMOTE_SKIP_REASON="$reason"
  _policy_remote_set_checked "$checked_name" "$POLICY_REMOTE_COUNT"
  return 2
}

# _policy_remote_collect_paths PROBE ROOT - list ROOT with PROBE, drop blanks
# and trailing slashes, and accumulate the reported paths into
# POLICY_REMOTE_COUNT, the newline-joined POLICY_REMOTE_PATHS, and
# POLICY_REMOTE_LAST_PATH.
_policy_remote_collect_paths() {
  local probe="$1" root="$2" paths="" path=""
  paths=${ "$probe" "$root" 2>/dev/null;} || paths=""
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    path="${path%/}"
    POLICY_REMOTE_COUNT=$((POLICY_REMOTE_COUNT + 1))
    POLICY_REMOTE_PATHS="${POLICY_REMOTE_PATHS}${POLICY_REMOTE_PATHS:+$'\n'}${path}"
    POLICY_REMOTE_LAST_PATH="$path"
  done <<<"$paths"
}

# _policy_remote_wizard KIND POLICY SUB SCOPE SINK - wizard verdict for a
# chosen folder reported by the shared probe; returns 0 to keep the pair, 2 to
# skip it. KIND is e2ee or external and selects the wording and policy
# variable.
_policy_remote_wizard() {
  local kind="$1" policy="$2" sub="$3" scope="$4" sink="$5" confirmed=0
  local prefix="" var="" detail="" reason_detail=""
  case "$kind" in
    e2ee)
      prefix="e2ee"
      var="E2EE_POLICY"
      detail="is end-to-end encrypted (${scope}); sciebo cannot decrypt E2EE folders"
      reason_detail="is end-to-end encrypted (${scope})"
      ;;
    *)
      prefix="external storage"
      var="EXTERNAL_STORAGE_POLICY"
      detail="is on mounted external storage"
      reason_detail="on mounted external storage"
      ;;
  esac
  if [[ "$policy" == "ask" ]] && _policy_remote_confirm "$kind"; then
    confirmed=1
  fi
  if ! choose_policy_decision "$policy" "$confirmed" >/dev/null; then
    _policy_remote_skip "" "${prefix}: '$(printable "$sub")' ${reason_detail} (${var}=${policy})" \
      "${prefix}: '$(printable "$sub")' ${detail}; skipping (${var}=${policy})"
    return 2
  fi
  if [[ "$policy" == "ask" ]]; then
    _policy_remote_emit "$sink" "${prefix}: '$(printable "$sub")' accepted (${var}=ask)"
  elif [[ "$policy" == "warn" ]]; then
    _policy_remote_emit "$sink" "${prefix}: '$(printable "$sub")' ${detail}; adding anyway (${var}=warn)"
  fi
  return 0
}

# _policy_remote_wizard_e2ee POLICY SUB SCOPE SINK - E2EE wording wrapper.
_policy_remote_wizard_e2ee() {
  _policy_remote_wizard e2ee "$1" "$2" "$3" "$4"
}

# _policy_remote_wizard_external POLICY SUB SCOPE SINK - external wording
# wrapper.
_policy_remote_wizard_external() {
  _policy_remote_wizard external "$1" "$2" "$3" "$4"
}

# policy_remote_paths_apply POLICY PROBE KIND OUT_EXCLUDES_NAME CHECKED_VAR
#
# The one shared E2EE / server-mounted external-storage gate behind the sync
# preflights, `doctor`, and the folder wizard. POLICY is the effective
# setting (E2EE_POLICY/EXTERNAL_STORAGE_POLICY), PROBE is the path-listing
# callback (nc_e2ee_paths/nc_external_paths), KIND is e2ee or external,
# OUT_EXCLUDES_NAME names an argv array that receives one rclone --exclude
# pattern per encrypted subfolder, and CHECKED_VAR names the variable that
# receives the number of reported paths evaluated.
#
# The external signature is deliberately byte-stable: all three call
# sites - sync.sh, doctor.sh, and folders_choose.sh - plus the policy
# suite pass these same five positionals. On entry they are folded into
# the POLICY_REMOTE_* globals, so POLICY_REMOTE_* is the single read
# channel for both input paths (see the input note in the function).
#
# The caller supplies the context through globals:
#   POLICY_REMOTE_ROOT         remote path the probe is queried with
#                              (apply/collect); the candidate folder
#                              (wizard)
#   POLICY_REMOTE_NAME         entry label used by apply messages
#   POLICY_REMOTE_STYLE        apply (default), wizard, or collect
#   POLICY_REMOTE_SCOPE_SEARCH 1 to match the candidate or its parent
#                              instead of enumerating the tree (wizard)
#   POLICY_REMOTE_CONFIRM      optional callback run for an ask policy; it
#                              must return 0 for a confirmed answer
#   POLICY_REMOTE_SINK         message sink (default warn; : silences)
#
# It sets POLICY_REMOTE_COUNT, POLICY_REMOTE_PATHS (newline-joined reported
# paths), POLICY_REMOTE_LAST_PATH/LAST_SUB/LAST_SCOPE, POLICY_REMOTE_RESULT
# (proceed/skip), POLICY_REMOTE_SKIP_REASON, and POLICY_REMOTE_MESSAGE, so
# every caller can phrase its own report from the shared state. Returns 0 to
# proceed and 2 to skip (an E2EE remote root, or external ask without a
# confirmation). allow, a missing probe, and a non-Nextcloud remote are
# silent no-ops; collect style only records what the probe reports (doctor
# still lists encrypted folders under allow).
policy_remote_paths_apply() {
  # Input contract, one section, fed by both channels: the five
  # positionals keep their external byte-stable signature but are copied
  # into POLICY_REMOTE_POLICY/PROBE/KIND/OUT_EXCLUDES/CHECKED_VAR on
  # entry, and the caller-preset context below already arrives through
  # POLICY_REMOTE_* globals. Every read afterwards (here and in the
  # style-specific engine calls) uses the locals initialized from that
  # one section, instead of mixing $1..$5 with the globals.
  POLICY_REMOTE_POLICY="${1:-}"
  POLICY_REMOTE_PROBE="${2:-}"
  POLICY_REMOTE_KIND="${3:-}"
  POLICY_REMOTE_OUT_EXCLUDES="${4:-}"
  POLICY_REMOTE_CHECKED_VAR="${5:-}"
  local policy="$POLICY_REMOTE_POLICY" probe="$POLICY_REMOTE_PROBE"
  local kind="$POLICY_REMOTE_KIND" out_name="$POLICY_REMOTE_OUT_EXCLUDES"
  local checked_name="$POLICY_REMOTE_CHECKED_VAR"
  local style="${POLICY_REMOTE_STYLE:-apply}" root="${POLICY_REMOTE_ROOT:-}"
  local sink="${POLICY_REMOTE_SINK:-warn}" name="${POLICY_REMOTE_NAME:-}"
  local scope_search="${POLICY_REMOTE_SCOPE_SEARCH:-0}"

  # Output contract: every call resets these before the gate runs, so a
  # caller can phrase its own report from the shared state.
  POLICY_REMOTE_COUNT=0
  POLICY_REMOTE_PATHS=""
  POLICY_REMOTE_LAST_PATH=""
  POLICY_REMOTE_LAST_SUB=""
  POLICY_REMOTE_LAST_SCOPE=""
  POLICY_REMOTE_RESULT=proceed
  POLICY_REMOTE_SKIP_REASON=""
  POLICY_REMOTE_MESSAGE=""
  # POLICY_REMOTE_* globals are the engine's output contract; this keeps the
  # assignments below visible to shellcheck (callers read them by name).
  : "${POLICY_REMOTE_LAST_PATH}" "${POLICY_REMOTE_LAST_SUB}" \
    "${POLICY_REMOTE_LAST_SCOPE}" "${POLICY_REMOTE_RESULT}" "${POLICY_REMOTE_SKIP_REASON}"

  if [[ "$style" != "collect" && "$policy" == "allow" ]]; then
    _policy_remote_set_checked "$checked_name" 0
    return 0
  fi
  type -t "$probe" >/dev/null 2>&1 || {
    _policy_remote_set_checked "$checked_name" 0
    return 0
  }
  if [[ "$style" != "collect" ]] && ! remote_is_nextcloud; then
    _policy_remote_set_checked "$checked_name" 0
    return 0
  fi

  if [[ "$style" == "collect" ]]; then
    _policy_remote_run_collect "$probe" "$root" "$checked_name"
    return 0
  fi

  if [[ "$scope_search" == "1" ]]; then
    _policy_remote_run_wizard "$policy" "$probe" "$kind" "$root" "$sink" "$checked_name"
    return $?
  fi

  _policy_remote_run_apply "$policy" "$probe" "$kind" "$out_name" "$checked_name" \
    "$root" "$name" "$sink"
  return $?
}

# _policy_remote_run_collect PROBE ROOT CHECKED_NAME - collect style: list
# ROOT with PROBE and record the reported paths for the caller (doctor).
_policy_remote_run_collect() {
  local probe="$1" root="$2" checked_name="$3"
  _policy_remote_collect_paths "$probe" "$root"
  _policy_remote_set_checked "$checked_name" "$POLICY_REMOTE_COUNT"
  return 0
}

# _policy_remote_run_wizard POLICY PROBE KIND ROOT SINK CHECKED_NAME - wizard
# style: match the candidate ROOT or its parent (POLICY_REMOTE_SCOPE_SEARCH is
# set by the caller) and apply the kind's gate; rc 0 to keep the pair and 2 to
# skip it.
_policy_remote_run_wizard() {
  local policy="$1" probe="$2" kind="$3" root="$4" sink="$5" checked_name="$6"
  local scope=""
  scope=${ _policy_remote_scope_find "$probe" "$root";} || scope=""
  [[ -n "$scope" ]] || {
    _policy_remote_set_checked "$checked_name" 0
    return 0
  }
  POLICY_REMOTE_COUNT=1
  POLICY_REMOTE_PATHS="$scope"
  POLICY_REMOTE_LAST_PATH="$scope"
  POLICY_REMOTE_LAST_SUB="$root"
  POLICY_REMOTE_LAST_SCOPE="$scope"
  _policy_remote_set_checked "$checked_name" "$POLICY_REMOTE_COUNT"
  case "$kind" in
    e2ee) _policy_remote_wizard_e2ee "$policy" "$root" "$scope" "$sink" ;;
    *) _policy_remote_wizard_external "$policy" "$root" "$scope" "$sink" ;;
  esac
  return $?
}

# _policy_remote_run_apply POLICY PROBE KIND OUT_EXCLUDES_NAME CHECKED_VAR ROOT
# NAME SINK - apply style: enumerate ROOT and walk the reported paths in order
# through _policy_remote_apply_path. rc 0 to proceed and 2 to skip.
_policy_remote_run_apply() {
  local policy="$1" probe="$2" kind="$3" out_name="$4" checked_name="$5"
  local root="$6" name="$7" sink="$8"
  local path="" seen=0 rc=0
  _policy_remote_collect_paths "$probe" "$root"
  root="${root%/}"
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    seen=$((seen + 1))
    POLICY_REMOTE_LAST_PATH="$path"
    rc=0
    _policy_remote_apply_path "$path" "$root" "$kind" "$policy" "$out_name" \
      "$checked_name" "$name" "$sink" "$seen" || rc=$?
    case "$rc" in
      0) ;;
      3) return 0 ;;
      *) return "$rc" ;;
    esac
  done <<<"$POLICY_REMOTE_PATHS"
  _policy_remote_set_checked "$checked_name" "$POLICY_REMOTE_COUNT"
  return 0
}

# _policy_remote_apply_external_root POLICY ROOT NAME SINK CHECKED_NAME SEEN -
# evaluate an external-storage root for apply style. Sets POLICY_REMOTE_COUNT
# to SEEN before reporting; rc 0 to keep walking, 2 to stop and skip, and 3 to
# stop and proceed (an accepted ask).
_policy_remote_apply_external_root() {
  local policy="$1" root="$2" name="$3" sink="$4" checked_name="$5" seen="$6"
  case "$policy" in
    skip)
      POLICY_REMOTE_COUNT="$seen"
      _policy_remote_skip "$checked_name" \
        "external storage (EXTERNAL_STORAGE_POLICY=skip)" \
        "external storage: '${name}': remote root ${root} is mounted external storage; skipping (EXTERNAL_STORAGE_POLICY=skip)"
      return 2
      ;;
    ask)
      if _policy_remote_confirm external; then
        POLICY_REMOTE_COUNT="$seen"
        _policy_remote_emit "$sink" "external storage: ${root} accepted for '${name}' (EXTERNAL_STORAGE_POLICY=ask)"
        _policy_remote_set_checked "$checked_name" "$POLICY_REMOTE_COUNT"
        return 3
      fi
      POLICY_REMOTE_COUNT="$seen"
      _policy_remote_skip "$checked_name" \
        "external storage (EXTERNAL_STORAGE_POLICY=ask); not confirmed" \
        "external storage: '${name}': remote root ${root} is mounted external storage; skipping (EXTERNAL_STORAGE_POLICY=ask)"
      return 2
      ;;
    *)
      _policy_remote_emit "$sink" "external storage: remote root ${root} is mounted external storage (EXTERNAL_STORAGE_POLICY=${policy})"
      ;;
  esac
  return 0
}

# _policy_remote_apply_path PATH ROOT KIND POLICY OUT_EXCLUDES_NAME CHECKED_VAR
# NAME SINK SEEN - evaluate one reported path for apply style and update the
# POLICY_REMOTE_* state. rc 0 to keep walking, 2 to stop and skip, and 3 to
# stop and proceed (an accepted external-storage ask).
_policy_remote_apply_path() {
  local path="$1" root="$2" kind="$3" policy="$4" out_name="$5"
  local checked_name="$6" name="$7" sink="$8" seen="$9"
  local sub="" p_path="" silent=false
  [[ "$sink" == ":" ]] && silent=true
  if [[ "$path" == "$root" ]]; then
    if [[ "$kind" == "e2ee" ]]; then
      POLICY_REMOTE_COUNT="$seen"
      _policy_remote_skip "$checked_name" \
        "end-to-end encrypted remote root (E2EE_POLICY=${policy})" \
        "e2ee: '${name}': remote root ${root} is end-to-end encrypted; skipping (E2EE_POLICY=${policy})"
      return 2
    fi
    _policy_remote_apply_external_root "$policy" "$root" "$name" "$sink" "$checked_name" "$seen"
    return $?
  fi
  if [[ "$kind" == "e2ee" ]]; then
    sub="${path#"$root"/}"
    if [[ "$sub" == "$path" || -z "$sub" ]]; then
      return 0
    fi
    if ! safe_remote_path "$sub"; then
      if [[ "$silent" == false ]]; then
        p_path=${ printable "$path";}
        _policy_remote_emit "$sink" "e2ee: ignoring unsafe remote path ${p_path}"
      fi
      return 0
    fi
    POLICY_REMOTE_LAST_SUB="$sub"
    if [[ "$policy" == "exclude" ]]; then
      if [[ -n "$out_name" ]]; then
        local -n _pro_excludes="$out_name"
        _pro_excludes+=("$(blacklist_exclude_pattern "$sub")/**")
      fi
      if [[ "$silent" == false ]]; then
        p_path=${ printable "$path";}
        _policy_remote_emit "$sink" "e2ee: ${p_path} is end-to-end encrypted; excluded"
      fi
    elif [[ "$silent" == false ]]; then
      p_path=${ printable "$path";}
      _policy_remote_emit "$sink" "e2ee: ${p_path} is end-to-end encrypted (E2EE_POLICY=${policy})"
    fi
  else
    sub="${path#"$root"/}"
    if [[ "$sub" != "$path" && -n "$sub" ]] && ! safe_remote_path "$sub"; then
      if [[ "$silent" == false ]]; then
        p_path=${ printable "$path";}
        _policy_remote_emit "$sink" "external storage: ignoring unsafe remote path ${p_path}"
      fi
      return 0
    fi
    if [[ "$silent" == false ]]; then
      p_path=${ printable "$path";}
      _policy_remote_emit "$sink" "external storage: ${p_path} is mounted external storage (subfolder; continuing)"
    fi
  fi
  return 0
}
