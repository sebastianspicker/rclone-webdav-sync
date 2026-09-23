#!/bin/bash
# blacklist.sh - per-source failure records for the sync failure-blacklist.
#
# One small TSV record per sanitized entry name under BLACKLIST_DIR:
#
#   <count><TAB><path><TAB><error>[<TAB>next=<epoch>]
#
# A path that fails BLACKLIST_MAX_FAILS times is excluded from later
# sync/pull/bisync runs with an rclone --exclude pattern until `sciebo
# retry` clears it. Records are written atomically (mode 600) and parsed
# without sourcing, so a hostile record cannot execute code. Writing is
# best effort: a state directory problem must never fail a sync.
#
# BLACKLIST_MODE=count (the default) keeps the three-strikes behavior. With
# BLACKLIST_MODE=backoff a path at the threshold is excluded only until its
# `next` epoch: the delay doubles per failure above the threshold, starting
# at BLACKLIST_TIME_MIN and capped at BLACKLIST_TIME_MAX. Older three-field
# records still parse; a record without a future `next` is retried.

# now_epoch/epoch_to_stamp_or_raw come from lib/duration.sh.
sciebo_require_module duration now_epoch

# blacklist_file NAME - print NAME's record path. rc 1 and no output when
# the name sanitizes to nothing or BLACKLIST_DIR is not set.
blacklist_file() {
  local name=""
  name=${ sanitize_name "${1:-}";}
  [[ -n "$name" && -n "${BLACKLIST_DIR:-}" ]] || return 1
  printf '%s/%s\n' "$BLACKLIST_DIR" "$name"
  return 0
}

# _blacklist_write FILE - replace FILE from stdin with mode 600. The write
# runs in a subshell so an atomic_write failure cannot exit the caller.
_blacklist_write() {
  local file="$1"
  (atomic_write "$file" 600) >/dev/null 2>&1
}

# _blacklist_parse_next_into VAR FIELD - store the epoch of a `next=<epoch>`
# field (a bare numeric field is tolerated) in VAR. rc 1 and VAR empty for an
# empty or malformed field. Per-record parsing uses this to stay fork-free.
_blacklist_parse_next_into() {
  local __var="$1" field="${2:-}" epoch=""
  case "$field" in
    next=*) epoch="${field#next=}" ;;
    '')
      printf -v "$__var" '%s' ''
      return 1
      ;;
    *) epoch="$field" ;;
  esac
  case "$epoch" in
    '' | *[!0-9]*)
      printf -v "$__var" '%s' ''
      return 1
      ;;
  esac
  printf -v "$__var" '%s' "$epoch"
  return 0
}

# _blacklist_norm_count_into VAR COUNT - store COUNT when it is all digits,
# else 0.
_blacklist_norm_count_into() {
  local __var="$1" value=""
  value=${ default_uint "${2:-}" 0;}
  printf -v "$__var" '%s' "$value"
  return 0
}

# blacklist_each_record FN FILE - walk FILE's `count<TAB>path<TAB>error
# [<TAB>next=<epoch>]` records in order, calling FN with COUNT, PATH, ERROR,
# and NEXT_FIELD. A final line without a trailing newline is still visited.
# Contract: FN returns 0 to continue; a non-zero return stops the walk and
# blacklist_each_record returns that status (like manifest_each). Runs in the
# caller's shell, so FN reads and writes the caller's locals.
blacklist_each_record() {
  local fn="$1" file="$2"
  local rec_count="" rec_path="" rec_error="" rec_next=""
  while IFS=$'\t' read -r rec_count rec_path rec_error rec_next || [[ -n "${rec_count}${rec_path}${rec_error}${rec_next}" ]]; do
    "$fn" "$rec_count" "$rec_path" "$rec_error" "$rec_next" || return $?
  done <"$file"
}

# _blacklist_threshold - print the effective failure threshold; an empty or
# non-numeric BLACKLIST_MAX_FAILS falls back to 3.
_blacklist_threshold() {
  default_uint "${BLACKLIST_MAX_FAILS:-3}" 3
}

# _blacklist_backoff - true when the blacklist runs in backoff mode.
_blacklist_backoff() {
  [[ "${BLACKLIST_MODE:-count}" == "backoff" ]]
}

# _blacklist_next_epoch_into VAR COUNT - the epoch a count-COUNT path stays
# excluded until in backoff mode: now + BLACKLIST_TIME_MIN * 2^(COUNT -
# threshold), capped at BLACKLIST_TIME_MAX. 0 below the threshold. Stores the
# result in VAR without a command substitution.
_blacklist_next_epoch_into() {
  local __var="$1" count="${2:-0}" threshold="" delay="" cap="" now="" steps=0
  threshold=${ _blacklist_threshold;}
  case "$count" in
    '' | *[!0-9]*) count=0 ;;
  esac
  [[ "$count" -ge "$threshold" ]] || {
    printf -v "$__var" '%s' 0
    return 0
  }
  delay=${ default_uint "${BLACKLIST_TIME_MIN:-25}" 25;}
  cap=${ default_uint "${BLACKLIST_TIME_MAX:-86400}" 86400;}
  # 40 doublings already reach ~2.7e13 seconds, far beyond any sane cap; the
  # bound keeps the arithmetic away from the 64-bit overflow that would make
  # the cap comparison below succeed by wrapping negative.
  steps=$((count - threshold))
  [[ "$steps" -lt 40 ]] || steps=40
  while [[ "$steps" -gt 0 && "$delay" -lt "$cap" ]]; do
    delay=$((delay * 2))
    steps=$((steps - 1))
  done
  [[ "$delay" -le "$cap" ]] || delay="$cap"
  now=${ now_epoch;}
  case "$now" in
    '' | *[!0-9]*) now=0 ;;
  esac
  printf -v "$__var" '%s' "$((now + delay))"
  return 0
}

# _blacklist_record_many_each COUNT PATH ERROR NEXT - append one existing
# record to blacklist_record_many's caller-local rec_* arrays.
_blacklist_record_many_each() {
  local count="$1" path="$2" error="$3" next_field="$4"
  local n=0
  [[ -n "$path" ]] || return 0
  n="${#rec_paths[@]}"
  _blacklist_norm_count_into count "$count"
  rec_index["$path"]="$n"
  rec_paths[n]="$path"
  rec_counts[n]="$count"
  rec_errors[n]="$error"
  rec_nexts[n]="$next_field"
  return 0
}

# _blacklist_read_input - phase 1 of blacklist_record_many: append stdin's
# `PATH<TAB>ERROR` lines to the caller's in_paths/in_errors arrays (empty
# paths skipped), positionally indexed. Runs in blacklist_record_many's
# shell, so the arrays stay its locals; no file is touched here.
_blacklist_read_input() {
  local in_path="" in_error="" i=0
  while IFS=$'\t' read -r in_path in_error || [[ -n "${in_path}${in_error}" ]]; do
    [[ -n "$in_path" ]] || continue
    i="${#in_paths[@]}"
    in_paths[i]="$in_path"
    in_errors[i]="$in_error"
  done
}

# _blacklist_bump_or_add PATH ERROR MODE - upsert one input line into the
# caller's rec_index/rec_* arrays: an existing path bumps its count (normed
# through _blacklist_norm_count_into), replaces the error, and in backoff
# mode stores the fresh next epoch; a new path is appended with count 1
# (next=0 in backoff mode, no next field in count mode). Runs in
# blacklist_record_many's shell over its caller-local arrays.
_blacklist_bump_or_add() {
  local path="$1" error="$2" mode="${3:-count}"
  local count="" next_epoch="" n=0
  if [[ -n "${rec_index[$path]+x}" ]]; then
    n="${rec_index[$path]}"
    _blacklist_norm_count_into count "${rec_counts[n]}"
    count=$((count + 1))
    rec_counts[n]="$count"
    rec_errors[n]="$error"
    if [[ "$mode" == "backoff" ]]; then
      _blacklist_next_epoch_into next_epoch "$count"
      rec_nexts[n]="next=${next_epoch}"
    else
      rec_nexts[n]=""
    fi
  else
    n="${#rec_paths[@]}"
    rec_index["$path"]="$n"
    rec_paths[n]="$path"
    rec_counts[n]="1"
    rec_errors[n]="$error"
    if [[ "$mode" == "backoff" ]]; then
      rec_nexts[n]="next=0"
    else
      rec_nexts[n]=""
    fi
  fi
}

# _blacklist_merge_records FILE MODE - phase 2 of blacklist_record_many:
# load FILE's existing records into the caller's rec_* arrays (through
# _blacklist_record_many_each, which keeps position and index), then upsert
# every input line through _blacklist_bump_or_add: input order is preserved,
# existing records keep their position, new paths append as first seen, and
# duplicate lines increment the same path with the last error winning. Still
# no write - the one atomic rewrite per batch happens after serialize.
# Runs in blacklist_record_many's shell over its caller-local arrays.
_blacklist_merge_records() {
  local file="$1" mode="${2:-count}"
  local path="" error="" i=0
  if [[ -f "$file" ]]; then
    blacklist_each_record _blacklist_record_many_each "$file"
  fi
  while [[ "$i" -lt "${#in_paths[@]}" ]]; do
    path="${in_paths[i]}"
    error=${ printable "${in_errors[i]}";}
    _blacklist_bump_or_add "$path" "$error" "$mode"
    i=$((i + 1))
  done
}

# _blacklist_serialize MODE - phase 3 of blacklist_record_many: build the
# caller's `out` string from the caller's rec_* arrays in stored order -
# count, path, error, plus a normalized `next=<epoch>` field in backoff mode
# (a malformed or absent epoch serializes as next=0); count mode keeps the
# three-field shape and drops any stored next field. Runs in
# blacklist_record_many's shell; performs no write itself.
_blacklist_serialize() {
  local mode="${1:-count}" next_field="" n=0
  while [[ "$n" -lt "${#rec_paths[@]}" ]]; do
    if [[ "$mode" == "backoff" ]]; then
      _blacklist_parse_next_into next_field "${rec_nexts[n]}" || true
      case "$next_field" in '' | *[!0-9]*) next_field=0 ;; esac
      out="${out}${rec_counts[n]}"$'\t'"${rec_paths[n]}"$'\t'"${rec_errors[n]}"$'\t'"next=${next_field}"$'\n'
    else
      out="${out}${rec_counts[n]}"$'\t'"${rec_paths[n]}"$'\t'"${rec_errors[n]}"$'\n'
    fi
    n=$((n + 1))
  done
}

# blacklist_record_many NAME - batch writer. Reads `PATH<TAB>ERROR` records
# from stdin (one per line, as sync_record_errors produces), applies every
# increment in memory, and writes the record file once through the same
# atomic path. Duplicate lines increment the same path and the last error
# wins, exactly as one single-path record per line would. Input order is
# preserved: existing records keep their position and
# new paths are appended as first seen. rc 1 on an invalid name or a write
# failure, rc 0 when there is nothing to record; callers treat a failure as
# best effort. The work is phased across _blacklist_read_input (stdin),
# _blacklist_merge_records (existing records + upsert) and
# _blacklist_serialize (output string), which share this function's
# caller-local arrays - and the single atomic _blacklist_write stays here, at
# the end of the batch.
blacklist_record_many() {
  local name="${1:-}" file="" mode="${BLACKLIST_MODE:-count}"
  local out=""
  local -a in_paths=() in_errors=()
  local -a rec_paths=() rec_counts=() rec_errors=() rec_nexts=()
  local -A rec_index=()
  file=${ blacklist_file "$name";} || return 1
  _blacklist_read_input
  # Nothing to record: do not create or rewrite an empty record file.
  [[ "${#in_paths[@]}" -gt 0 ]] || return 0
  _blacklist_merge_records "$file" "$mode"
  _blacklist_serialize "$mode"
  printf '%s' "$out" | _blacklist_write "$file" || return 1
  return 0
}

# _blacklist_clear_each COUNT PATH ERROR NEXT - keep one record that
# blacklist_clear does not drop; sets its caller-local `found` when PATH
# matches.
_blacklist_clear_each() {
  local count="$1" record_path="$2" record_error="$3" record_next="$4"
  [[ -n "$record_path" ]] || return 0
  if [[ "$record_path" == "$path" ]]; then
    found=1
    return 0
  fi
  if [[ -n "$record_next" ]]; then
    out="${out}${count}"$'\t'"${record_path}"$'\t'"${record_error}"$'\t'"${record_next}"$'\n'
  else
    out="${out}${count}"$'\t'"${record_path}"$'\t'"${record_error}"$'\n'
  fi
  return 0
}

# blacklist_clear NAME [PATH] - clear one PATH or NAME's whole record.
# rc 0 when something was cleared, rc 1 when there was nothing to clear.
blacklist_clear() {
  local name="${1:-}" path="${2:-}" file=""
  file=${ blacklist_file "$name";} || return 1
  [[ -f "$file" ]] || return 1
  if [[ -z "$path" ]]; then
    rm -f "$file" || return 1
    return 0
  fi
  local out="" found=0
  blacklist_each_record _blacklist_clear_each "$file"
  [[ "$found" -eq 1 ]] || return 1
  if [[ -z "$out" ]]; then
    rm -f "$file" || return 1
  else
    printf '%s' "$out" | _blacklist_write "$file" || return 1
  fi
  return 0
}

# blacklist_count NAME - number of tracked paths for NAME (0 when none).
blacklist_count() {
  local file="" count=0
  file=${ blacklist_file "${1:-}";} || {
    printf '0\n'
    return 0
  }
  if [[ -f "$file" ]]; then
    count="$(LC_ALL=C awk 'END { print NR + 0 }' "$file" 2>/dev/null)"
    case "$count" in '' | *[!0-9]*) count=0 ;; esac
  fi
  printf '%s\n' "$count"
  return 0
}

# blacklist_exclude_pattern PATH - print the rclone --exclude pattern for the
# exact PATH. A leading slash anchors the pattern at the transfer root; every
# rclone glob metacharacter (\, *, ?, [, ], {, }) is backslash-escaped so the
# path stays literal. An unescaped "]" or "}" makes rclone abort before it
# starts, so the escape set must stay complete.
blacklist_exclude_pattern() {
  local path="${1:-}" out="" ch="" i=0
  while [[ "$i" -lt "${#path}" ]]; do
    ch="${path:$i:1}"
    case "$ch" in
      "\\" | '*' | '?' | '[' | ']' | '{' | '}') out="${out}\\${ch}" ;;
      *) out="${out}${ch}" ;;
    esac
    i=$((i + 1))
  done
  printf '/%s\n' "$out"
}

# _blacklist_excluded_each COUNT PATH ERROR NEXT - print PATH's exclude
# pattern when it is at or above the threshold and, in backoff mode, its
# deadline is in the future (caller locals `threshold`, `now`).
_blacklist_excluded_each() {
  local count="$1" path="$2" error="$3" next_field="$4"
  local next_epoch=""
  [[ -n "$path" ]] || return 0
  case "$count" in '' | *[!0-9]*) return 0 ;; esac
  [[ "$count" -ge "$threshold" ]] || return 0
  if _blacklist_backoff; then
    _blacklist_parse_next_into next_epoch "$next_field" || true
    case "$next_epoch" in
      '' | *[!0-9]*) next_epoch=0 ;;
    esac
    [[ "$now" -lt "$next_epoch" ]] || return 0
  fi
  blacklist_exclude_pattern "$path"
  return 0
}

# blacklist_excluded NAME - print one rclone --exclude pattern per path that
# has failed at least BLACKLIST_MAX_FAILS times. In backoff mode a path is
# only excluded until its next-retry epoch, so `now >= next` retries it.
# Prints nothing when the blacklist is disabled or no path is eligible.
blacklist_excluded() {
  local name="${1:-}" file="" threshold="${BLACKLIST_MAX_FAILS:-3}" now=0
  [[ "${BLACKLIST_ENABLED:-1}" == "1" ]] || return 0
  case "$threshold" in '' | *[!0-9]*) threshold=3 ;; esac
  # Resolve the record once and bail before any parsing when there is none:
  # sync calls this per entry, and most entries never failed. The path read
  # is a forkless capture (blacklist_file is pure printf over sanitize_name).
  file=${ blacklist_file "$name" 2>/dev/null;} || return 0
  [[ -f "$file" && -r "$file" ]] || return 0
  if _blacklist_backoff; then
    now=${ now_epoch;}
    case "$now" in '' | *[!0-9]*) now=0 ;; esac
  fi
  blacklist_each_record _blacklist_excluded_each "$file"
  return 0
}

# _blacklist_list_each COUNT PATH ERROR NEXT - print one blacklist_list row
# (caller locals `name`, `has_next`).
_blacklist_list_each() {
  local count="$1" path="$2" error="$3" next_field="$4"
  local next_epoch="" next_label="" path_disp="" error_disp=""
  [[ -n "$path" ]] || return 0
  path_disp=${ printable "$path";}
  error_disp=${ printable "$error";}
  if [[ "$has_next" -eq 1 ]]; then
    _blacklist_parse_next_into next_epoch "$next_field" || true
    # Normalize leading zeros ("00") so the zero test cannot miss it.
    [[ -z "$next_epoch" ]] || next_epoch="$((10#$next_epoch))"
    case "$next_epoch" in
      '' | 0) next_label="-" ;;
      *) next_label=${ epoch_to_stamp_or_raw "$next_epoch";} ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$count" "$path_disp" "$error_disp" "$next_label"
  else
    printf '%s\t%s\t%s\t%s\n' "$name" "$count" "$path_disp" "$error_disp"
  fi
  return 0
}

# blacklist_list - print "NAME<TAB>COUNT<TAB>PATH<TAB>ERROR" rows, plus a
# fifth NEXT column (ISO local time, `-` when no future retry is set) when
# any record carries a next field.
blacklist_list() {
  local dir="${BLACKLIST_DIR:-}" file="" name="" has_next=0
  [[ -n "$dir" && -d "$dir" ]] || return 0
  # One grep decides the column layout; the record loop below then reads each
  # file exactly once instead of making a preparatory full pass in the shell.
  if grep -rl -m1 $'\tnext=' "$dir" >/dev/null 2>&1; then
    has_next=1
  fi
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    name="${file##*/}"
    blacklist_each_record _blacklist_list_each "$file"
  done < <(find "$dir" -maxdepth 1 -type f -print 2>/dev/null | LC_ALL=C sort)
  return 0
}

# blacklist_clear_all - remove every record file and print the sanitized
# source name of each record that was removed.
blacklist_clear_all() {
  local dir="${BLACKLIST_DIR:-}" file=""
  [[ -n "$dir" && -d "$dir" ]] || return 0
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    if rm -f "$file" 2>/dev/null; then
      printf '%s\n' "${file##*/}"
    fi
  done < <(find "$dir" -maxdepth 1 -type f -print 2>/dev/null | LC_ALL=C sort)
  return 0
}
