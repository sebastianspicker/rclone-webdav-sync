#!/bin/bash
# case_clash.sh - the case-insensitive-filesystem name-clash scanner (local
# and remote) and its process-lifetime disk cache. Split out of
# lib/sync/policy.sh: CASE_CLASH_POLICY is desktop-parity policy, but the
# scanner and its cache are a self-contained subsystem, not an rclone-argv
# gate builder.

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
_POLICY_CASE_CACHE_DIR=""
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
  sciebo_temp_register "$dir"
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
