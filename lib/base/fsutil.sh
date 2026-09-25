#!/bin/bash
# fsutil.sh - filesystem utilities: the one-time stat-flavor detection and
# the file_mtime/file_size/file_mode/file_stamp readers built on it, local
# path expansion and safety validation, atomic_write, and safe_source. The
# seen-id cache built on file_stamp/atomic_write lives in
# lib/state/seen.sh (it is state, not a pure helper).
#
# Depends on core.sh's die/warn and text.sh's printable. Invariant:
# safe_source is the only sanctioned way to source a settings/profile/.env
# file - it re-validates ownership and mode through the open descriptor
# (TOCTOU-safe) instead of trusting an earlier check.

# _stat_flavor - detect once whether stat is the BSD (-f) or GNU (-c) spelling.
# Avoids probing both forms on every file_mtime/file_mode/file_stamp call.
_SCIEBO_STAT_FLAVOR=""
_stat_flavor() {
  [[ -n "$_SCIEBO_STAT_FLAVOR" ]] && {
    printf '%s' "$_SCIEBO_STAT_FLAVOR"
    return 0
  }
  # Cache only a positive identification. A probe can fail for reasons that
  # say nothing about the platform (a fork or exec failing under load), and
  # caching "gnu" after such a failure on macOS made every later stat call in
  # the process fail, so safe_source refused safe settings files. When
  # neither form works, leave the flavor unset and let the next call retry.
  if stat -f %m "$LIB_DIR" >/dev/null 2>&1; then
    _SCIEBO_STAT_FLAVOR="bsd"
  elif stat -c %Y "$LIB_DIR" >/dev/null 2>&1; then
    _SCIEBO_STAT_FLAVOR="gnu"
  else
    return 1
  fi
  printf '%s' "$_SCIEBO_STAT_FLAVOR"
}

# file_mtime FILE - print FILE's modification time as an epoch, or nothing
# when it cannot be read. Uses the one-time _stat_flavor detection.
file_mtime() {
  local file="$1" mtime=""
  [[ -n "$_SCIEBO_STAT_FLAVOR" ]] || _stat_flavor >/dev/null
  if [[ "$_SCIEBO_STAT_FLAVOR" == "bsd" ]]; then
    mtime="$(stat -f %m "$file" 2>/dev/null || true)"
  else
    mtime="$(stat -c %Y "$file" 2>/dev/null || true)"
  fi
  case "$mtime" in
    '' | *[!0-9]*) return 0 ;;
  esac
  printf '%s' "$mtime"
}

# file_mtime_or FILE DEFAULT - FILE's modification time as an epoch, or
# DEFAULT when the file is missing or unstatable (the stat fails or prints
# nothing usable). The mtime capture runs forklessly in this shell. Adopters
# pass their own default (0 for age comparisons, "" for stamps). Never
# fails; always prints.
file_mtime_or() {
  local mtime=""
  mtime=${ file_mtime "${1:-}";}
  if [[ -n "$mtime" ]]; then
    printf '%s' "$mtime"
  else
    printf '%s' "${2:-}"
  fi
  return 0
}

# file_size FILE - print FILE's size in bytes, or nothing when it cannot be
# read. Uses the one-time _stat_flavor detection (BSD -f %z / GNU -c %s), the
# stat-dance replacement for the wc-pipe and per-caller flavour probes.
file_size() {
  local file="$1" size=""
  [[ -n "$_SCIEBO_STAT_FLAVOR" ]] || _stat_flavor >/dev/null
  if [[ "$_SCIEBO_STAT_FLAVOR" == "bsd" ]]; then
    size="$(stat -f %z "$file" 2>/dev/null || true)"
  else
    size="$(stat -c %s "$file" 2>/dev/null || true)"
  fi
  case "$size" in
    '' | *[!0-9]*) return 0 ;;
  esac
  printf '%s' "$size"
}

# file_mode FILE - print FILE's permission bits as three octal digits (e.g.
# 600; a four-digit mode loses its leading bit), or nothing when it cannot be
# read. Uses the one-time _stat_flavor detection.
file_mode() {
  local file="$1" mode=""
  [[ -n "$_SCIEBO_STAT_FLAVOR" ]] || _stat_flavor >/dev/null
  if [[ "$_SCIEBO_STAT_FLAVOR" == "bsd" ]]; then
    mode="$(stat -f '%Lp' "$file" 2>/dev/null || true)"
  else
    mode="$(stat -c '%a' "$file" 2>/dev/null || true)"
  fi
  case "$mode" in
    [0-7][0-7][0-7]) printf '%s' "$mode" ;;
    [0-7][0-7][0-7][0-7]) printf '%s' "${mode#?}" ;;
    *) return 0 ;;
  esac
}

# _mode_normalize MODE - print MODE as three octal digits (a four-digit stat
# mode loses its leading bit), or nothing when MODE is not octal. The shared
# normalization for safe_source's multi-operand stat read.
_mode_normalize() {
  case "${1:-}" in
    [0-7][0-7][0-7]) printf '%s' "$1" ;;
    [0-7][0-7][0-7][0-7]) printf '%s' "${1#?}" ;;
    *) return 0 ;;
  esac
}

# expand_local_path PATH - absolute stays, ~ and ~/ expand, anything else
# is relative to the project root.
# shellcheck disable=SC2088  # ${p#\~/} is an intentional literal-prefix strip
expand_local_path() {
  case "$1" in
    "~") printf '%s' "$HOME" ;;
    "~/"*) printf '%s' "${HOME}/${1#\~/}" ;;
    /*) printf '%s' "$1" ;;
    *) printf '%s' "${PROJECT_DIR}/${1}" ;;
  esac
}

# expand_local_path_into VAR PATH - expand_local_path without the command
# substitution, for hot callers.
# shellcheck disable=SC2088  # ${2#\~/} is an intentional literal-prefix strip
expand_local_path_into() {
  case "$2" in
    "~") printf -v "$1" '%s' "$HOME" ;;
    "~/"*) printf -v "$1" '%s' "${HOME}/${2#\~/}" ;;
    /*) printf -v "$1" '%s' "$2" ;;
    *) printf -v "$1" '%s' "${PROJECT_DIR}/${2}" ;;
  esac
}

# safe_remote_path PATH - validate a path below the remote base. Rejects
# empty, absolute, ".." segments, whitespace padding, "|", and control
# bytes so manifest lines and remote args round-trip unambiguously.
safe_remote_path() {
  local s="$1"
  [[ -n "$s" ]] || return 1
  case "$s" in
    [[:space:]]* | *[[:space:]] | /* | *..* | *"|"*) return 1 ;;
  esac
  [[ "$s" != *[[:cntrl:]]* ]]
}

# safe_local_path PATH - validate a local path for the pipe-separated
# manifest: non-empty, no surrounding whitespace, no "|" (the field
# separator), no control bytes, and no "." or ".." path segments (so a
# manifest or `open` argument cannot escape its root).
safe_local_path() {
  local s="$1"
  [[ -n "$s" ]] || return 1
  case "$s" in
    [[:space:]]* | *[[:space:]] | *"|"*) return 1 ;;
    "." | ".." | "./"* | "../"* | *"/./"* | *"/../"* | *"/." | *"/..") return 1 ;;
  esac
  [[ "$s" != *[[:cntrl:]]* ]]
}

# require_safe_remote_path PATH [LABEL] - die with the shared message unless
# PATH passes safe_remote_path. Centralizes the wording used by every
# command that accepts a path below the remote base.
require_safe_remote_path() {
  safe_remote_path "${1:-}" && return 0
  local shown=""
  shown=${ printable "${1:-}";}
  die "${2:-}unsafe remote path '${shown}': use a relative path below the remote base without '..'"
}

# file_stamp FILE - print "mtime size" for cache invalidation, or nothing
# when it cannot be read. Uses the one-time _stat_flavor detection.
file_stamp() {
  local file="$1" stamp=""
  [[ -n "$_SCIEBO_STAT_FLAVOR" ]] || _stat_flavor >/dev/null
  if [[ "$_SCIEBO_STAT_FLAVOR" == "bsd" ]]; then
    stamp="$(stat -f '%m %z' "$file" 2>/dev/null || true)"
  else
    stamp="$(stat -c '%Y %s' "$file" 2>/dev/null || true)"
  fi
  printf '%s' "$stamp"
}

# Paths already reported as unsafe by the safe_source helpers (warn once per
# path, whichever layer reaches the refusal first).
declare -gA _SAFE_SOURCE_WARNED=()

# _safe_source_warn FILE MESSAGE - print MESSAGE once per FILE; a refusal that
# is reached from several layers warns a single time.
_safe_source_warn() {
  local file="$1" message="$2"
  [[ -z "${_SAFE_SOURCE_WARNED[$file]:-}" ]] || return 0
  _SAFE_SOURCE_WARNED[$file]=1
  warn "$message"
}

# _fd_looks_safe FD FD_UID FD_MODE FD_INO PATH_MODE PATH_INO - 0 when the
# descriptor FD still names a regular file owned by the current user with
# neither group- nor other-write bits, and FD and the path agree on the
# inode (the path-based mode must describe the file that was actually
# opened; on platforms where stat-ing /dev/fd/N reports the access mode
# instead of the file's mode, the inode match is what makes the path read
# meaningful). Modes must already be normalized by _mode_normalize; an
# empty uid, mode, or inode is refused. Extracted from safe_source so the
# compound refusal lives in one place with the same short-circuit order.
_fd_looks_safe() {
  local fd="$1" fd_uid="$2" fd_mode="$3" fd_ino="$4" path_mode="$5" path_ino="$6"
  if [[ ! -f "/dev/fd/${fd}" || -z "$fd_uid" || "$fd_uid" != "$UID" ||
    -z "$fd_ino" || "$fd_ino" != "$path_ino" || -z "$path_mode" ||
    $((8#$path_mode & 8#022)) -ne 0 || -z "$fd_mode" || $((8#$fd_mode & 8#022)) -ne 0 ]]; then
    return 1
  fi
  return 0
}

# safe_source FILE - source the already-verified file through its open
# descriptor so a swap between the check and the read cannot execute different
# content. It is self-contained: it rejects a symlinked path, opens FILE, and
# validates the descriptor itself - regular file, owned by the current user,
# and without a group or other write bit - before sourcing. On platforms where
# stat-ing /dev/fd/N reports the descriptor's access mode instead of the file's
# (macOS), the descriptor and the path must also name the same inode, so the
# path-based mode read describes the file that was actually opened
# (TOCTOU-safe). Warns once per path and returns 1 when FILE is unsafe;
# otherwise returns the exit status of the sourced file, so a syntax or
# runtime error in a settings, profile, or .env file is propagated instead of
# swallowed. Runs in the caller's shell, so assignments made by FILE persist.
safe_source() {
  local file="${1:-}" fd="" rc=0
  [[ -n "$file" ]] || return 1
  [[ ! -L "$file" ]] || {
    _safe_source_warn "$file" "refusing to source symlinked file '$(printable "$file")'"
    return 1
  }
  # Refuse anything that is not a regular file before opening it: opening a
  # FIFO or a device would block (or have side effects) instead of failing.
  [[ -f "$file" ]] || return 1
  # Validate up to three times, each on a fresh descriptor. On a heavily
  # loaded macOS host the /dev/fd view of an open file has been seen to
  # report inconsistent fields for a moment; a genuinely unsafe file fails
  # every attempt, and each attempt sources only the descriptor it validated.
  for _ in 1 2 3; do
    _safe_source_open_checked "$file" && break
    fd=""
  done
  if [[ -z "$fd" ]]; then
    _safe_source_warn "$file" "refusing to source unsafe file '$(printable "$file")': it must be owned by you and not group- or other-writable"
    return 1
  fi
  # shellcheck disable=SC1090  # /dev/fd path; the descriptor was validated above
  source "/dev/fd/${fd}" || rc=$? # layers: allow-source (user settings/profile file, not library code)
  exec {fd}<&-
  return "$rc"
}

# _safe_source_open_checked FILE - open FILE on the caller's `fd` and check,
# through that descriptor, that it is a regular file owned by the current
# user and not group- or other-writable, and still the same inode as the
# path. Leaves the descriptor open on success; closes it and returns 1
# otherwise.
_safe_source_open_checked() {
  local file="$1" out="" fd_uid="" fd_mode="" fd_ino="" path_mode="" path_ino=""
  exec {fd}<"$file" || return 1
  # One stat invocation supplies uid, mode, and inode for both names (the open
  # descriptor and the path name), BSD '%u %Lp %i' or GNU '%u %a %i'.
  # stat prints one line per operand in argument order; an operand that cannot
  # be read contributes no line, so its fields stay empty and the check below
  # refuses.
  [[ -n "$_SCIEBO_STAT_FLAVOR" ]] || _stat_flavor >/dev/null
  if [[ "$_SCIEBO_STAT_FLAVOR" == "bsd" ]]; then
    out="$(stat -f '%u %Lp %i' "/dev/fd/${fd}" "$file" 2>/dev/null || true)"
  else
    # On Linux /dev/fd/N is a symlink into /proc, and GNU stat does not
    # follow symlinks by default: without -L it reports the link itself (a
    # different inode), so the inode check below could never pass. Follow
    # only the descriptor; the path is still examined without following.
    out="$(stat -L -c '%u %a %i' "/dev/fd/${fd}" 2>/dev/null || true)"
    out+=$'\n'"$(stat -c '%u %a %i' "$file" 2>/dev/null || true)"
  fi
  read -r fd_uid fd_mode fd_ino <<<"${out%%$'\n'*}"
  if [[ "$out" == *$'\n'* ]]; then
    read -r _ path_mode path_ino <<<"${out#*$'\n'}"
  fi
  # Normalize a four-digit mode to three octal digits, and treat a non-octal
  # mode as unreadable.
  fd_mode="$(_mode_normalize "$fd_mode")"
  path_mode="$(_mode_normalize "$path_mode")"
  if ! _fd_looks_safe "$fd" "$fd_uid" "$fd_mode" "$fd_ino" "$path_mode" "$path_ino"; then
    exec {fd}<&-
    return 1
  fi
  return 0
}

# safe_filter_name NAME - validate a bare filter file name (no directory
# components, no ".."), so manifests cannot point outside FILTER_DIR.
safe_filter_name() {
  local s="$1"
  [[ -n "$s" ]] || return 1
  case "$s" in
    /* | */* | *..*) return 1 ;;
  esac
  [[ "$s" != *[[:cntrl:]]* ]]
}

# atomic_write FILE [MODE] - replace FILE with stdin, same directory,
# atomic rename. Default mode 644.
atomic_write() {
  local file="$1" mode="${2:-644}" dir tmp=""
  # The directory comes from parameter expansion (no `dirname` fork): a path
  # without a slash writes into the current directory, an empty expansion
  # means the root directory. mkdir only runs when the directory is missing;
  # the temp template below stays `${file}.tmp.XXXXXX` because cleanup
  # --state's narrowed `*.tmp.??????` glob matches exactly six characters.
  dir="${file%/*}"
  if [[ "$dir" == "$file" ]]; then
    dir="."
  elif [[ -z "$dir" ]]; then
    dir="/"
  fi
  [[ -d "$dir" ]] || mkdir -p -- "$dir"
  temp_mktemp_into tmp "${file}.tmp.XXXXXX" || die "cannot create temp file in ${dir}"
  if ! cat >"$tmp"; then
    temp_discard "$tmp"
    die "cannot write temp file for ${file}"
  fi
  chmod "$mode" "$tmp" || {
    temp_discard "$tmp"
    die "cannot chmod ${tmp} to ${mode}"
  }
  mv -f "$tmp" "$file" || {
    temp_discard "$tmp"
    die "cannot replace ${file}"
  }
  temp_discard "$tmp"
}
