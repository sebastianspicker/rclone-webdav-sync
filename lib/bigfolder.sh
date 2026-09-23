#!/bin/bash
# bigfolder.sh - large unconfigured remote folder discovery.
#
# bigfolder_scan NAME REMOTE_SUBDIR prints one TAB-separated row
# (SUB, BYTES, LABEL) for every immediate remote subfolder that has no
# manifest entry and no matching pair filter rule and is larger than
# BIG_FOLDER_SIZE. bigfolder_notify adds a warning, an optional desktop
# notification, and a seen cache so a folder is reported only once. It also
# memoizes the scan under $STATE_DIR/bigfolder/scan-<name> for
# BIGFOLDER_SCAN_TTL, so repeated pull/bisync entries skip the remote scan
# (one recursive listing per scan) while the cache is fresh.
#
# Both helpers are best effort: they never fail the caller and are no-ops
# when BIG_FOLDER_SIZE is empty (or unparseable) or rclone is unavailable.

# now_epoch/duration_seconds come from lib/duration.sh. bin/sciebo sources it
# already; source it here too so the module works standalone (same guard as
# lib/blacklist.sh).
if ! type now_epoch >/dev/null 2>&1 || ! type duration_seconds >/dev/null 2>&1; then
  BIGFOLDER_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -r "${BIGFOLDER_MODULE_DIR}/duration.sh" ]]; then
    # shellcheck source=./duration.sh
    source "${BIGFOLDER_MODULE_DIR}/duration.sh" || true
  fi
  unset BIGFOLDER_MODULE_DIR
fi

BIGFOLDER_MAX_SCAN=50

# _bigfolder_child_sizes SPEC - print CHILD<TAB>BYTES for every immediate
# child of SPEC, from ONE recursive `rclone lsf` listing. The listing carries
# both kinds of row: a directory entry ends with "/" and its size field is
# -1, a file entry starts with its byte count. Directory rows register the
# child in listing order (so empty children are still counted and the
# BIGFOLDER_MAX_SCAN cap sees the same set as the old --dirs-only call), file
# rows add to its total; a file directly at SPEC's root belongs to no child
# and is ignored, exactly as before. The size field precedes the path and
# never contains ";" (rclone's default separator), so a path may.
_bigfolder_child_sizes() {
  local spec="$1"
  rclone_cmd lsf "$spec" -R --format sp 2>/dev/null |
    LC_ALL=C awk '
      {
        sep = index($0, ";")
        if (sep < 2) next
        size = substr($0, 1, sep - 1)
        path = substr($0, sep + 1)
        if (path ~ /\/$/) {
          name = path
          sub(/\/$/, "", name)
          if (name == "" || name ~ /\//) next
          if (!(name in seen)) { seen[name] = 1; order[++n] = name }
          next
        }
        if (size !~ /^[0-9]+$/) next
        if (path !~ /\//) next
        child = path
        sub(/\/.*/, "", child)
        if (child == "") next
        if (!(child in seen)) { seen[child] = 1; order[++n] = child }
        total[child] += size
      }
      END {
        for (i = 1; i <= n; i++) printf "%s\t%d\n", order[i], total[order[i]]
      }
    '
}

# _bigfolder_label BYTES - human label for a byte count. The type guard is
# the feature-pinned pick of whether capabilities.sh (the SizeSuffix
# labeler) has been loaded: loaded renders the rclone style, unloaded the
# raw "<N>B" count - a load-order difference changes only the style, since
# both styles come from core's format_size_bytes, not from a formatter that
# may be absent.
_bigfolder_label() {
  local bytes="$1"
  if type capabilities_size_label >/dev/null 2>&1; then
    format_size_bytes "$bytes" rclone
  else
    format_size_bytes "$bytes" bytes
  fi
}

# _bigfolder_filter_covers FILE CHILD - true when a non-comment rule in FILE
# names CHILD as its first path segment ("- child/", "- /child/**", ...).
_bigfolder_filter_covers() {
  local file="$1" child="$2" line="" rule="" first=""
  [[ -f "$file" ]] || return 1
  while IFS= read -r line; do
    line=${ trim "$line";}
    case "$line" in '' | \#*) continue ;; esac
    rule="${line#[+-]}"
    rule=${ trim "${rule# }";}
    rule="${rule#/}"
    first="${rule%%/*}"
    [[ "$first" == "$child" ]] && return 0
  done <"$file"
  return 1
}

# _bigfolder_pair_match NAME - non-zero (stop) for the entry named NAME,
# after printing its filter file.
_bigfolder_pair_match() {
  [[ "${ENTRY_NAME:-}" == "$1" ]] || return 0
  printf '%s' "$ENTRY_FILTER"
  return 1
}

# _bigfolder_pair_filter NAME - print the filter file of the manifest entry
# named NAME (empty when the entry has none).
_bigfolder_pair_filter() {
  # manifest.sh is lazy; load it when the core loader is available. Without
  # core.sh (fully standalone sourcing) the harness must source manifest.sh
  # itself, exactly as before.
  if type sciebo_require_module >/dev/null 2>&1; then
    sciebo_require_module manifest manifest_each
  fi
  manifest_each _bigfolder_pair_match "$1" || true
  return 0
}

# _bigfolder_covered SUB CHILD FILTER - true when CHILD below SUB already has
# a manifest entry or a rule in FILTER (the entry's pair filter name, which
# the caller resolves once per scan; resolving it per child re-parsed the
# whole manifest for every remote subfolder).
_bigfolder_covered() {
  local sub="$1" child="$2" filter="$3" spec=""
  # manifest.sh is lazy; see _bigfolder_pair_filter for the standalone case.
  if type sciebo_require_module >/dev/null 2>&1; then
    sciebo_require_module manifest manifest_has_remote
  fi
  spec="${sub:+${sub}/}${child}"
  manifest_has_remote "$spec" && return 0
  [[ -n "$filter" ]] || return 1
  _bigfolder_filter_covers "${FILTER_DIR}/${filter}" "$child"
}

# bigfolder_scan NAME REMOTE_SUBDIR - scan the immediate remote subfolders of
# <RCLONE_REMOTE>:<REMOTE_BASE>/<REMOTE_SUBDIR> and print SUB<TAB>BYTES<TAB>LABEL
# for the unconfigured ones above BIG_FOLDER_SIZE. Scans at most
# BIGFOLDER_MAX_SCAN subfolders and always returns 0.
bigfolder_scan() {
  local name="$1" sub="${2:-}" threshold="" spec="" child=""
  local bytes="" label="" scanned=0 filter=""
  sub=${ strip_trailing_slashes "$sub";}
  [[ -n "${BIG_FOLDER_SIZE:-}" ]] || return 0
  threshold=${ size_suffix_bytes "$BIG_FOLDER_SIZE";} || return 0
  [[ -n "$threshold" ]] || return 0
  type rclone_available >/dev/null 2>&1 || return 0
  rclone_available || return 0
  spec=${ remote_spec "$sub";}
  filter=${ _bigfolder_pair_filter "$name";}
  # One recursive listing feeds both the child order (directory rows, in
  # rclone's listing order) and the per-child byte totals (file rows), so the
  # old second `rclone lsf --dirs-only --max-depth 1` call is gone.
  while IFS=$'\t' read -r child bytes; do
    [[ -n "$child" ]] || continue
    _bigfolder_covered "$sub" "$child" "$filter" && continue
    scanned=$((scanned + 1))
    [[ "$scanned" -le "$BIGFOLDER_MAX_SCAN" ]] || break
    case "$bytes" in
      '' | *[!0-9]*) continue ;;
    esac
    [[ "$bytes" -gt "$threshold" ]] || continue
    label=${ _bigfolder_label "$bytes";}
    printf '%s\t%s\t%s\n' "$child" "$bytes" "$label"
  done < <(_bigfolder_child_sizes "$spec")
  return 0
}

# _bigfolder_scan_cache NAME TTL - print the cached scan rows when the
# per-name cache is fresh (age below TTL seconds); rc 1 when caching is
# disabled (TTL 0), or the cache is missing, stale, or unreadable. Best
# effort: any oddity makes the caller scan the remote again.
_bigfolder_scan_cache() {
  local name="$1" ttl="$2" file="" stamp="" age="" line="" now=""
  case "$ttl" in '' | *[!0-9]*) return 1 ;; esac
  [[ "$ttl" -gt 0 ]] || return 1
  file="${STATE_DIR}/bigfolder/scan-${ sanitize_name "$name";}"
  [[ -r "$file" ]] || return 1
  {
    IFS= read -r stamp || return 1
    case "$stamp" in '' | *[!0-9]*) return 1 ;; esac
    now=${ now_epoch;}
    age=$((now - stamp))
    [[ "$age" -ge 0 && "$age" -lt "$ttl" ]] || return 1
    while IFS= read -r line; do
      printf '%s\n' "$line"
    done
  } <"$file"
}

# _bigfolder_scan_cache_write NAME ROWS - replace the per-name scan cache
# with an epoch stamp followed by ROWS. Atomic and mode 600; best effort, so
# any failure is ignored. The subshell contains atomic_write's die, which
# must not fail the caller.
_bigfolder_scan_cache_write() {
  local name="$1" rows="$2" file="" now=""
  file="${STATE_DIR}/bigfolder/scan-${ sanitize_name "$name";}"
  now=${ now_epoch;}
  (
    printf '%s\n%s' "$now" "$rows" | atomic_write "$file" 600
  ) 2>/dev/null || true
  return 0
}

# bigfolder_notify NAME REMOTE_SUBDIR - warn (and notify) about unconfigured
# remote subfolders above BIG_FOLDER_SIZE and remember them under
# $STATE_DIR/bigfolder/<name> so later runs stay quiet. The scan itself is
# reused from $STATE_DIR/bigfolder/scan-<name> while younger than
# BIGFOLDER_SCAN_TTL. Always returns 0 and never prompts.
bigfolder_notify() {
  local name="$1" sub="${2:-}" seen_file="" line="" child="" bytes="" label=""
  local new_seen="" seen=$'\n' ttl="" rows="" child_disp=""
  sub=${ strip_trailing_slashes "$sub";}
  # notify.sh is lazy; load it before the `type notify_send` probe below so
  # an eligible warning still notifies (the probe alone would silently skip
  # when the module had not been loaded). Guarded for fully standalone
  # sourcing without core.sh, like the manifest requires above.
  if type sciebo_require_module >/dev/null 2>&1; then
    sciebo_require_module notify notify_send
  fi
  [[ -n "${BIG_FOLDER_SIZE:-}" ]] || return 0
  [[ -n "${STATE_DIR:-}" && -n "$name" ]] || return 0
  type rclone_available >/dev/null 2>&1 || return 0
  rclone_available || return 0
  seen_file="${STATE_DIR}/bigfolder/${ sanitize_name "$name";}"
  if [[ -f "$seen_file" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      seen="${seen}${line}"$'\n'
    done <"$seen_file"
  fi
  ttl=${ duration_seconds "${BIGFOLDER_SCAN_TTL:-1h}" seconds 2>/dev/null;} || ttl=0
  if ! rows="$(_bigfolder_scan_cache "$name" "$ttl")"; then
    rows="$(bigfolder_scan "$name" "$sub")"
    _bigfolder_scan_cache_write "$name" "$rows"
  fi
  while IFS=$'\t' read -r child bytes label; do
    [[ -n "$child" ]] || continue
    [[ "$seen" == *$'\n'"${child}"$'\n'* ]] && continue
    child_disp=${ printable "$child";}
    warn "big folder: ${name}/${child_disp} is ${label} (not configured; add it with '${CLI_NAME} folders add')"
    if type notify_send >/dev/null 2>&1; then
      notify_send "${CLI_NAME}" "big folder: ${name}/${child_disp} is ${label}" || true
    fi
    new_seen="${new_seen}${child}"$'\n'
  done <<<"$rows"
  if [[ -n "$new_seen" ]]; then
    (
      {
        [[ -f "$seen_file" ]] && cat "$seen_file"
        printf '%s' "$new_seen"
      } | atomic_write "$seen_file" 600
    ) 2>/dev/null || true
  fi
  return 0
}
