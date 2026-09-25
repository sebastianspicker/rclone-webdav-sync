#!/bin/bash
# policy.sh - desktop-parity rclone-argv gate builders and the shared pure
# policy decision, shared by sync, hydrate, doctor, and the folder wizard.
#
# The helpers here turn the policy settings (INVALID_NAME_POLICY,
# SYMLINK_POLICY, CHECKSUM, MOVE_TO_TRASH, DELETE_FILES_THRESHOLD/ASK_DELETE,
# chunk bounds) into rclone arguments, preflight checks, and warnings. The
# argument helpers append one rclone argument at a time to the argv array
# named by their first parameter (the nameref out-param style of
# _rclone_global_flags_into), so callers build their argv without a subshell
# or newline re-parsing; everything else is pure or read-only.
#
# The case-clash scanner and disk cache live in lib/sync/case_clash.sh; the
# E2EE/external-storage remote-path engine lives in lib/sync/remote_paths.sh
# (it calls choose_policy_decision below; callers of policy_case_clashes
# resolve CASE_CLASH_POLICY through choose_policy_decision themselves).

# blacklist_exclude_pattern (lib/state/blacklist.sh, always loaded before this
# file) escapes the rclone glob for the remote-path policy excludes.

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
  bytes=${ size_suffix_bytes "$raw" 2>/dev/null;} || bytes=""
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

# choose_policy_decision POLICY CONFIRMED - shared pure decision for one
# policy gate: prints "proceed" or "skip" and returns 0 to keep the item /
# 2 to skip it. allow and warn always proceed, skip and exclude always
# skip, and ask proceeds only when CONFIRMED is 1 (the caller resolves the
# TTY/non-interactive answer). An unset or unknown policy proceeds, so a
# missing setting can never block a run or the wizard. Used by the wizard
# gates, callers of policy_case_clashes (CASE_CLASH_POLICY), and
# lib/sync/remote_paths.sh.
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

# net_gate - 0 to proceed, 2 to skip a run on a metered connection. The
# probes (net_is_metered, NET_SSID) live in lib/adapters/platform.sh; the
# verdict is choose_policy_decision's, like every other allow/ask/skip gate.
# SCIEBO_METERED_OK=1 always proceeds. `ask` prompts through ui_confirm_tty
# ([y/yes] dialect); declined, EOF, and not askable (no tty or
# SCIEBO_NON_INTERACTIVE) all count as not confirmed.
net_gate() {
  local label="" policy="${METERED_POLICY:-allow}" confirmed=0
  net_is_metered || return 0
  [[ "${SCIEBO_METERED_OK:-0}" == "1" ]] && return 0
  if [[ -n "${NET_SSID:-}" ]]; then
    label="metered connection $(printable "$NET_SSID")"
  else
    label="metered connection"
  fi
  if [[ "$policy" == "ask" ]] && ui_confirm_tty "${label}; sync anyway?"; then
    confirmed=1
  fi
  choose_policy_decision "$policy" "$confirmed" >/dev/null && return 0
  if [[ "$policy" == "ask" ]]; then
    warn "${label}: skipped (not confirmed)"
  else
    warn "${label}: skipped (METERED_POLICY=${policy})"
  fi
  return 2
}
