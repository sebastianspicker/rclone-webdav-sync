#!/bin/bash
# conflicts.sh command module - find local conflict files (read-only).
#
# Two local conflict kinds are found next to their originals: rclone bisync
# and the Nextcloud desktop client keep a conflicting file and append a
# suffix that contains CONFLICT_PATTERN ("conflicted copy" by default), and
# CASE_CLASH_POLICY=rename quarantines a case-clash loser as
# "<name> (case conflict)<ext>" (see policy_rename_case_clash in
# lib/policy.sh). The local scan is purely local: no network, no lock, and
# no state writes (the state directories are never created here).
#
# With --remote the command instead lists remote case clashes: it needs
# load_settings and require_remote and lists each source's remote subtree
# (read-only), reporting names that differ only by ASCII case. It never
# renames remote paths, so --resolve and --apply are usage errors there.

# Conflicts found so far and entries skipped because the local dir is
# missing; CONFLICTS_QUIET suppresses everything except the exit status.
# CONFLICTS_KIND is the --kind filter (copy, case, all); CONFLICTS_OPEN
# additionally records the containing directory of every match.
CONFLICTS_TOTAL=0
CONFLICTS_SKIPPED=0
CONFLICTS_QUIET=false
CONFLICTS_KIND=all
CONFLICTS_OPEN=false
# Remote case-clash scans that could not list a source (unreachable remote).
# The scan continues, but the summary must not claim the remote is clean.
CONFLICTS_REMOTE_FAILED=0
# Case-clash quarantine suffix written by policy_rename_case_clash.
CONFLICTS_CASE_PATTERN=" (case conflict)"
# Directories to open (once each) and the set of dirs already recorded, so a
# folder with many conflicts still opens one window.
CONFLICTS_OPEN_DIRS=()
declare -A CONFLICTS_OPEN_SEEN=()
# Resolve counters and the plan collected before an apply run. CONFLICTS_PLAN
# holds one escaped TAB-separated record per planned action (layout below),
# built by conflicts_plan_add and read through conflicts_record_read.
CONFLICTS_RESOLVED=0
CONFLICTS_FAILED=0
CONFLICTS_PLAN=()
# CONFLICTS_REC_* - the fields of the record conflicts_record_read last
# parsed (out globals like SHARE_RECORD_*; assigned through record_split's
# printf -v, hence the top-level declarations).
CONFLICTS_REC_SOURCE=""
CONFLICTS_REC_KIND=""
CONFLICTS_REC_CONFLICT=""
CONFLICTS_REC_DIR=""
CONFLICTS_REC_REL=""
CONFLICTS_REC_BASE_ABS=""
CONFLICTS_REC_BASE_REL=""
CONFLICTS_REC_ACTION=""
# shellcheck disable=SC2034  # write-only layout field, like the old
# CONFLICTS_PLAN_TARGET_ABS: record_split fills it and _conflicts_record_build
# rejoins it, but only target_rel is ever read (by the printers).
CONFLICTS_REC_TARGET_ABS=""
CONFLICTS_REC_TARGET_REL=""
# CONFLICTS_RECORD_FIELDS - the plan record layout, defined once:
#   source TAB kind TAB conflict TAB dir TAB rel TAB base_abs TAB base_rel
#   TAB action TAB target_abs TAB target_rel
# exactly the ten fields the former parallel CONFLICTS_PLAN_* arrays
# carried. TAB safety: conflicts_plan_add escapes each field ("\" -> "\\",
# TAB -> "\t") and conflicts_record_read undoes it, so record_split's fixed
# delimiters can never shift - raw TAB fields would move the split and
# mv/rm would target the wrong path when a conflict file name found by
# conflicts_find contains a tab. The escape doubles backslashes first and
# _conflicts_record_unescape_field scans left to right, so literal "\" or
# "\t" sequences in a name round-trip exactly. Newlines need no escape:
# records live only in the CONFLICTS_PLAN array (index iteration, never a
# line-based reader) and the join is pure parameter expansion (no command
# substitution to strip trailing newlines). source (entry names) and dir
# (the manifest local path) are control-byte-free for tool-written
# manifests (safe_remote_path / safe_local_path reject [[:cntrl:]]), but
# the conflict file names below dir are raw find output, so every field is
# escaped uniformly. The last field receives record_split's remainder,
# which after escaping is exactly target_rel.
CONFLICTS_RECORD_FIELDS=(
  CONFLICTS_REC_SOURCE CONFLICTS_REC_KIND CONFLICTS_REC_CONFLICT
  CONFLICTS_REC_DIR CONFLICTS_REC_REL CONFLICTS_REC_BASE_ABS
  CONFLICTS_REC_BASE_REL CONFLICTS_REC_ACTION CONFLICTS_REC_TARGET_ABS
  CONFLICTS_REC_TARGET_REL
)

usage_conflicts() {
  usage_emit <<'EOF'
Usage: sciebo conflicts [options]
       sciebo conflicts --resolve MODE [options]

Find local conflict files below every configured source. The scan is
read-only: nothing is uploaded, deleted, or written. Two kinds are listed:

  copy  conflict copies matching CONFLICT_PATTERN (default: "conflicted copy")
  case  files quarantined by CASE_CLASH_POLICY=rename and renamed to
        "<name> (case conflict)<ext>"

The local scan is purely local and contacts no remote. With --remote the
scan is an opt-in online variant: it lists each source's remote subtree
with `rclone lsf -R` and reports names that differ only by ASCII case as
kind "case". It is read-only, needs a reachable remote, and never renames
anything server-side; `CASE_CLASH_REMOTE_SCAN=1` enables the same scan
during sync.

Options:
  --resolve MODE  resolve conflict files instead of listing them. MODE is
                  one of:
                    keep-local   move the file over the original (overwrite)
                    keep-remote  delete the file, keeping the original
                    keep-newest  keep the newer of the two files
                    keep-oldest  keep the older of the two files
                    keep-both    rename the file to
                                 "<name> (local copy)<ext>"
                  Without --apply this is a dry run that prints one line per
                  planned action and changes nothing. Cannot be combined
                  with --remote.
  --only NAME     scan or resolve only the source with this sanitized name
                  (see `sciebo list`)
  --kind KIND     scan or resolve only one conflict kind: copy, case, or all
                  (default: all). With --remote only case or all are valid.
  --remote        list case clashes on the server (read-only) instead of
                  local files. Cannot be combined with --resolve, --apply,
                  --yes, or --open.
  --open          list and then open the conflict directories with the
                  platform opener (macOS `open`, Linux `xdg-open`); each
                  containing directory is opened once, however many
                  conflicts it holds. Read-only, no confirmation; exits 0
                  (opener failures aside) and prints "no conflicts" when
                  there is nothing to open (nothing with --quiet). Cannot
                  be combined with --resolve.
  --apply         carry out the planned actions. This is destructive:
                  files are overwritten, renamed, or deleted. A terminal
                  run asks once; a non-interactive run needs --yes.
  --yes           skip the --apply confirmation
  --json          print the result as JSON: the resolve result (requires
                  --resolve) or the remote clash list (with --remote)
  --quiet         print nothing; exit 1 when conflicts exist (except with
                  --open, which exits 0)
  -h, --help      show this help
EOF
}

# conflicts_kind_of NAME - conflict kind of a basename: "case" for a
# "(case conflict)" quarantine name, otherwise "copy".
conflicts_kind_of() {
  case "$1" in
    *"${CONFLICTS_CASE_PATTERN}"*) printf 'case' ;;
    *) printf 'copy' ;;
  esac
}

# conflicts_kind_match KIND - true (0) when KIND passes the --kind filter.
conflicts_kind_match() {
  [[ "$CONFLICTS_KIND" == "all" || "$CONFLICTS_KIND" == "$1" ]]
}

# conflicts_find DIR - NUL-delimited paths below DIR matching either
# conflict kind (CONFLICT_PATTERN or the case-clash quarantine suffix).
conflicts_find() {
  find -P "$1" -type f \( -name "*${CONFLICT_PATTERN}*" -o -name "*${CONFLICTS_CASE_PATTERN}*" \) -print0 2>/dev/null
}

# conflicts_derive_base NAME [KIND] - derive the original base name from a
# conflict file's basename: cut at the first kind-specific suffix, strip
# trailing separators (space, dot, dash, underscore, open paren), and append
# the conflict file's extension when the result has none. Prints nothing
# when no usable name remains.
conflicts_derive_base() {
  local name="$1" kind="${2:-copy}" result="" last="" ext=""
  if [[ "$kind" == "case" ]]; then
    result="${name%%"${CONFLICTS_CASE_PATTERN}"*}"
  else
    result="${name%%"${CONFLICT_PATTERN}"*}"
  fi
  while [[ -n "$result" ]]; do
    last="${result:${#result}-1:1}"
    case "$last" in
      ' ' | '.' | '-' | '_' | '(') result="${result%?}" ;;
      *) break ;;
    esac
  done
  if [[ -n "$result" && "$result" != *.* && "$name" == *.* ]]; then
    ext="${name##*.}"
    [[ -n "$ext" ]] && result="${result}.${ext}"
  fi
  printf '%s' "$result"
}

# conflicts_rel_path DIR PATH - PATH relative to DIR (same convention as
# conflicts_process_entry); DIR explains the entry's absolute base path.
conflicts_rel_path() {
  local dir="$1" path="$2"
  case "$dir" in
    /) printf '%s' "${path#/}" ;;
    *) printf '%s' "${path#"$dir"/}" ;;
  esac
}

# conflicts_entry_local_dir VAR - assign VAR ENTRY_LOCAL with the trailing
# slash stripped ("/" for the remote base); warn (unless --quiet) and count a
# skipped entry, returning 1, when the local dir does not exist.
conflicts_entry_local_dir() {
  local -n out="$1"
  out="${ENTRY_LOCAL%/}"
  [[ -n "$out" ]] || out="/"
  if [[ ! -d "$out" ]]; then
    if [[ "$CONFLICTS_QUIET" != true ]]; then
      warn "conflicts: '${ENTRY_NAME}': local dir ${out} does not exist; skipped"
    fi
    CONFLICTS_SKIPPED=$((CONFLICTS_SKIPPED + 1))
    return 1
  fi
  return 0
}

# conflicts_local_copy_path BASE - print the first free absolute path of the
# form "<name> (local copy)<ext>" next to BASE, appending -2, -3, ... when
# needed. Never returns an existing path.
conflicts_local_copy_path() {
  local base="$1" dir="" name="" stem="" ext="" candidate="" n=1
  if [[ "$base" == */* ]]; then
    dir="${base%/*}"
    name="${base##*/}"
  else
    dir="."
    name="$base"
  fi
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
  candidate="${dir}/${stem} (local copy)${ext}"
  while [[ -e "$candidate" ]]; do
    n=$((n + 1))
    candidate="${dir}/${stem} (local copy)-${n}${ext}"
  done
  printf '%s' "$candidate"
}

# conflicts_print_row SOURCE RELPATH MTIME SIZE KIND - one aligned report row.
conflicts_print_row() {
  printf '%-24s %-48s %-16s %-6s %s\n' "$1" "$2" "$3" "$4" "$5"
}

# conflicts_remote_row SOURCE KEPT LOSER - one aligned remote case-clash row
# (the kept and the losing name, kind "case").
conflicts_remote_row() {
  printf '%-24s %-48s %-48s %s\n' "$1" "$2" "$3" "case"
}

# conflicts_open_record DIR - remember DIR once for --open; a directory with
# many conflicts still opens a single window. The associative set keeps the
# membership check O(1) instead of scanning a growing newline list. Always
# returns 0 (a duplicate is the normal case, not an error).
conflicts_open_record() {
  local dir="$1"
  [[ -z "${CONFLICTS_OPEN_SEEN[$dir]:-}" ]] || return 0
  CONFLICTS_OPEN_SEEN[$dir]=1
  CONFLICTS_OPEN_DIRS[${#CONFLICTS_OPEN_DIRS[@]}]="$dir"
  return 0
}

# conflicts_process_entry - scan the entry currently parsed into ENTRY_*.
# A missing local dir is warned about and counted as skipped, never an
# error (--quiet suppresses the warning too). With CONFLICTS_OPEN=true the
# containing directory of every match is recorded for --open; the scan runs
# in this shell (not a process substitution) so those globals survive.
conflicts_process_entry() {
  local dir="" path="" rel="" size="" kind="" cdir="" stamp="" epoch="" when="-"
  local p_rel="" p_size=""
  conflicts_entry_local_dir dir || return 0
  while IFS= read -r -d '' path; do
    kind=${ conflicts_kind_of "${path##*/}";}
    conflicts_kind_match "$kind" || continue
    rel=${ conflicts_rel_path "$dir" "$path";}
    # One stat per file yields both mtime and size (file_stamp); the size is
    # rendered by the pure-bash format_size_bytes.
    stamp=${ file_stamp "$path";}
    epoch="${stamp%% *}"
    size="${stamp##* }"
    [[ -n "$size" ]] || size="-"
    when="-"
    [[ -z "$epoch" ]] || when=${ epoch_to_stamp "$epoch";}
    if [[ "$CONFLICTS_QUIET" != true ]]; then
      p_rel=${ printable "$rel";}
      p_size=${ format_size_bytes "$size";}
      conflicts_print_row "$ENTRY_NAME" "$p_rel" "$when" "$p_size" "$kind"
    fi
    CONFLICTS_TOTAL=$((CONFLICTS_TOTAL + 1))
    if [[ "$CONFLICTS_OPEN" == true ]]; then
      cdir="${path%/*}"
      [[ -n "$cdir" ]] || cdir="/"
      conflicts_open_record "$cdir"
    fi
  done < <(conflicts_find "$dir")
}

# conflicts_each_list_entry ONLY - scan one already-parsed manifest entry for
# conflict copies; entries filtered out by ONLY are ignored.
conflicts_each_list_entry() {
  local only="${1:-}"
  [[ -z "$only" || "$ENTRY_NAME" == "$only" ]] || return 0
  conflicts_process_entry
  return 0
}

# conflicts_plan_reset - clear the collected resolve plan and counters.
conflicts_plan_reset() {
  CONFLICTS_TOTAL=0
  CONFLICTS_SKIPPED=0
  CONFLICTS_RESOLVED=0
  CONFLICTS_FAILED=0
  CONFLICTS_PLAN=()
}

# _conflicts_record_build VAR FIELD... - escape FIELDs (backslash and TAB,
# the record delimiter) and join them into VAR with TABs: one plan record in
# the CONFLICTS_RECORD_FIELDS layout. Pure parameter expansion on purpose:
# a command substitution would strip trailing newlines from a field that
# ends in one (legal in a file name).
_conflicts_record_build() {
  local -n _crb_out="$1"
  shift
  local _crb_line="" _crb_sep="" _crb_field=""
  for _crb_field in "$@"; do
    _crb_field="${_crb_field//\\/\\\\}"
    _crb_field="${_crb_field//$'\t'/\\t}"
    _crb_line+="${_crb_sep}${_crb_field}"
    _crb_sep=$'\t'
  done
  _crb_out="$_crb_line"
  return 0
}

# _conflicts_record_unescape_field VAR - undo _conflicts_record_build's
# field escaping on VAR in place. The scan is left to right, so "\\t" and
# "\\\\" decode to the literal backslash sequences they encode (a naive
# two-pass replace would corrupt them); a lone backslash that our own
# escaping never produces is re-emitted unchanged, so an unescaped
# hand-written record still reads byte for byte.
_conflicts_record_unescape_field() {
  local -n _cru_var="$1"
  local _cru_s="$_cru_var" _cru_out=""
  while [[ "$_cru_s" == *\\* ]]; do
    _cru_out+="${_cru_s%%\\*}"
    _cru_s="${_cru_s#*\\}"
    case "$_cru_s" in
      t*)
        _cru_out+=$'\t'
        _cru_s="${_cru_s:1}"
        ;;
      \\*)
        _cru_out+="\\"
        _cru_s="${_cru_s:1}"
        ;;
      *) _cru_out+="\\" ;;
    esac
  done
  _cru_out+="$_cru_s"
  _cru_var="$_cru_out"
  return 0
}

# conflicts_record_read REC - split one plan record (the escaped TAB layout
# of CONFLICTS_RECORD_FIELDS) into the CONFLICTS_REC_* globals and undo the
# field escaping. Every reader calls it before touching a CONFLICTS_REC_*
# value; the split targets avoid record_split's own local names (core.sh).
conflicts_record_read() {
  record_split "$1" "${CONFLICTS_RECORD_FIELDS[@]}"
  local field=""
  for field in "${CONFLICTS_RECORD_FIELDS[@]}"; do
    _conflicts_record_unescape_field "$field"
  done
  return 0
}

# conflicts_plan_add SOURCE KIND CONFLICT DIR REL BASE_ABS BASE_REL ACTION
# TARGET_ABS TARGET_REL - append one planned resolve action as a single
# record line (CONFLICTS_RECORD_FIELDS layout) to CONFLICTS_PLAN.
conflicts_plan_add() {
  local line=""
  _conflicts_record_build line "$@"
  CONFLICTS_PLAN[${#CONFLICTS_PLAN[@]}]="$line"
  return 0
}

# conflicts_resolve_mode MODE DIR PATH REL BASE_ABS BASE_REL ACTION_VAR
# TARGET_ABS_VAR TARGET_REL_VAR - decide what MODE does with the conflict file
# at PATH (relative REL) and its derived original at BASE_ABS (relative
# BASE_REL): assign the chosen action and the absolute/relative target, both
# defaulting to the original. Pure decision, no file operations.
# shellcheck disable=SC2034  # out_target_rel is assigned through the nameref
conflicts_resolve_mode() {
  local mode="$1" dir="$2" path="$3" rel="$4" base_abs="$5" base_rel="$6"
  local -n out_action="$7" out_target_abs="$8" out_target_rel="$9"
  local base_epoch="" conflict_epoch=""
  out_action=""
  out_target_abs="$base_abs"
  out_target_rel="$base_rel"
  case "$mode" in
    keep-local)
      out_action=keep-local
      ;;
    keep-remote)
      out_action=keep-remote
      out_target_abs="$path"
      out_target_rel="$rel"
      ;;
    keep-both)
      out_action=keep-both
      out_target_abs=${ conflicts_local_copy_path "$base_abs";}
      out_target_rel=${ conflicts_rel_path "$dir" "$out_target_abs";}
      ;;
    keep-newest | keep-oldest)
      if [[ ! -e "$base_abs" ]]; then
        out_action=keep-local
      else
        base_epoch=${ file_mtime_or "$base_abs" 0;}
        conflict_epoch=${ file_mtime_or "$path" 0;}
        out_action=keep-remote
        if [[ "$mode" == keep-newest ]]; then
          [[ "$conflict_epoch" -le "$base_epoch" ]] || out_action=keep-local
        else
          [[ "$conflict_epoch" -ge "$base_epoch" ]] || out_action=keep-local
        fi
      fi
      if [[ "$out_action" == keep-remote ]]; then
        out_target_abs="$path"
        out_target_rel="$rel"
      fi
      ;;
  esac
  return 0
}

# conflicts_resolve_entry MODE - scan the entry currently parsed into ENTRY_*
# and collect the actions MODE plans for its conflict files. Derived base
# names that are empty or identical to the conflict file are warned about
# and skipped; a missing local dir is skipped like the listing scan.
conflicts_resolve_entry() {
  local mode="$1"
  local dir="" path="" rel="" name="" kind="" base="" base_abs="" base_rel=""
  local action="" target_abs="" target_rel="" p_rel=""
  conflicts_entry_local_dir dir || return 0
  while IFS= read -r -d '' path; do
    [[ -n "$path" ]] || continue
    kind=${ conflicts_kind_of "${path##*/}";}
    conflicts_kind_match "$kind" || continue
    CONFLICTS_TOTAL=$((CONFLICTS_TOTAL + 1))
    rel=${ conflicts_rel_path "$dir" "$path";}
    name="${path##*/}"
    base=${ conflicts_derive_base "$name" "$kind";}
    if [[ -z "$base" || "$base" == "$name" ]]; then
      if [[ "$CONFLICTS_QUIET" != true ]]; then
        p_rel=${ printable "$rel";}
        warn "conflicts: '${ENTRY_NAME}': cannot derive the original name from '${p_rel}'; skipped"
      fi
      CONFLICTS_SKIPPED=$((CONFLICTS_SKIPPED + 1))
      continue
    fi
    base_rel="$base"
    case "$dir" in
      /) base_abs="/${base}" ;;
      *) base_abs="${dir}/${base}" ;;
    esac
    conflicts_resolve_mode "$mode" "$dir" "$path" "$rel" "$base_abs" "$base_rel" \
      action target_abs target_rel
    conflicts_plan_add "$ENTRY_NAME" "$kind" "$path" "$dir" "$rel" "$base_abs" \
      "$base_rel" "$action" "$target_abs" "$target_rel"
  done < <(conflicts_find "$dir")
  return 0
}

# conflicts_each_resolve_entry ONLY MODE - plan the resolve actions of one
# already-parsed manifest entry; entries filtered out by ONLY are ignored.
conflicts_each_resolve_entry() {
  local only="${1:-}" mode="$2"
  [[ -z "$only" || "$ENTRY_NAME" == "$only" ]] || return 0
  conflicts_resolve_entry "$mode"
  return 0
}

# conflicts_resolve_confirm - ask once before applying; --yes skips the
# prompt, a non-interactive run without it is a usage error, and anything
# but a yes answer aborts (rc 1, nothing changed).
conflicts_resolve_confirm() {
  ui_confirm_mutation conflicts \
    "--apply requires --yes when not running interactively" \
    "Resolve ${#CONFLICTS_PLAN[@]} conflict copy(ies)? [y/N]: "
}

# _conflicts_count OK|FAIL [MESSAGE] - record one apply outcome: OK bumps
# CONFLICTS_RESOLVED; FAIL warns MESSAGE (already passed through printable
# by the caller) and bumps CONFLICTS_FAILED. Every apply arm paired those
# updates by hand; here they live in one place.
_conflicts_count() {
  case "$1" in
    ok)
      CONFLICTS_RESOLVED=$((CONFLICTS_RESOLVED + 1))
      ;;
    *)
      warn "${2:-}"
      CONFLICTS_FAILED=$((CONFLICTS_FAILED + 1))
      ;;
  esac
  return 0
}

# _conflicts_apply_keep_local - the keep-local arm: move the conflict file
# over the original (the original may be missing), refusing a directory
# target. Counters go through _conflicts_count; the record fields were
# split by conflicts_apply_plan's conflicts_record_read.
_conflicts_apply_keep_local() {
  local p_rel="" p_base=""
  if [[ -d "$CONFLICTS_REC_BASE_ABS" ]]; then
    p_base=${ printable "${CONFLICTS_REC_BASE_REL}";}
    _conflicts_count fail "conflicts: refusing to overwrite directory '${p_base}'"
  elif mv -f -- "$CONFLICTS_REC_CONFLICT" "$CONFLICTS_REC_BASE_ABS"; then
    _conflicts_count ok
  else
    p_rel=${ printable "${CONFLICTS_REC_REL}";}
    p_base=${ printable "${CONFLICTS_REC_BASE_REL}";}
    _conflicts_count fail "conflicts: cannot move '${p_rel}' to '${p_base}'"
  fi
  return 0
}

# _conflicts_apply_keep_remote - the keep-remote arm: delete the conflict
# file, keeping the original; a failed delete warns.
_conflicts_apply_keep_remote() {
  local p_rel=""
  if rm -f -- "$CONFLICTS_REC_CONFLICT"; then
    _conflicts_count ok
  else
    p_rel=${ printable "${CONFLICTS_REC_REL}";}
    _conflicts_count fail "conflicts: cannot delete '${p_rel}'"
  fi
  return 0
}

# _conflicts_apply_keep_both I - the keep-both arm: re-derive the target
# right before the move (so an existing file is never overwritten) and write
# it back into plan record I, so the printed plan/JSON reports the name the
# move actually used - exactly what the old in-place TARGET_* update did.
_conflicts_apply_keep_both() {
  local i="$1" target="" target_rel="" p_rel="" line=""
  target=${ conflicts_local_copy_path "$CONFLICTS_REC_BASE_ABS";}
  target_rel=${ conflicts_rel_path "$CONFLICTS_REC_DIR" "$target";}
  _conflicts_record_build line "$CONFLICTS_REC_SOURCE" "$CONFLICTS_REC_KIND" \
    "$CONFLICTS_REC_CONFLICT" "$CONFLICTS_REC_DIR" "$CONFLICTS_REC_REL" \
    "$CONFLICTS_REC_BASE_ABS" "$CONFLICTS_REC_BASE_REL" \
    "$CONFLICTS_REC_ACTION" "$target" "$target_rel"
  CONFLICTS_PLAN[i]="$line"
  if mv -- "$CONFLICTS_REC_CONFLICT" "$target"; then
    _conflicts_count ok
  else
    p_rel=${ printable "${CONFLICTS_REC_REL}";}
    _conflicts_count fail "conflicts: cannot rename '${p_rel}'"
  fi
  return 0
}

# conflicts_apply_plan - carry out every planned action, updating the
# resolved/failed/skipped counters. Each record is split once through
# conflicts_record_read and dispatched to its arm; keep-both re-derives its
# target right before the move so an existing file is never overwritten.
conflicts_apply_plan() {
  local i=0 total="${#CONFLICTS_PLAN[@]}"
  while [[ "$i" -lt "$total" ]]; do
    conflicts_record_read "${CONFLICTS_PLAN[$i]}"
    case "$CONFLICTS_REC_ACTION" in
      keep-local)
        _conflicts_apply_keep_local
        ;;
      keep-remote)
        _conflicts_apply_keep_remote
        ;;
      keep-both)
        _conflicts_apply_keep_both "$i"
        ;;
    esac
    i=$((i + 1))
  done
  CONFLICTS_SKIPPED=$((CONFLICTS_SKIPPED + CONFLICTS_FAILED))
  return 0
}

# conflicts_print_plan - one "<source> <relpath> -> <action> <target>" line
# per planned action.
conflicts_print_plan() {
  local i=0 total="${#CONFLICTS_PLAN[@]}"
  local source="" rel="" action="" target=""
  while [[ "$i" -lt "$total" ]]; do
    conflicts_record_read "${CONFLICTS_PLAN[$i]}"
    source=${ printable "${CONFLICTS_REC_SOURCE}";}
    rel=${ printable "${CONFLICTS_REC_REL}";}
    action="$CONFLICTS_REC_ACTION"
    target=${ printable "${CONFLICTS_REC_TARGET_REL}";}
    printf '%s %s -> %s %s\n' "$source" "$rel" "$action" "$target"
    i=$((i + 1))
  done
}

# conflicts_print_json - the --json document for a resolve run.
conflicts_print_json() {
  local i=0 total="${#CONFLICTS_PLAN[@]}"
  output_json_begin
  output_json_kv_raw total "$CONFLICTS_TOTAL"
  output_json_kv_raw resolved "$CONFLICTS_RESOLVED"
  output_json_kv_raw skipped "$CONFLICTS_SKIPPED"
  output_json_array_begin items
  while [[ "$i" -lt "$total" ]]; do
    conflicts_record_read "${CONFLICTS_PLAN[$i]}"
    output_json_object_begin
    output_json_kv source "${CONFLICTS_REC_SOURCE}"
    output_json_kv path "${CONFLICTS_REC_REL}"
    output_json_kv kind "${CONFLICTS_REC_KIND}"
    output_json_kv action "${CONFLICTS_REC_ACTION}"
    output_json_kv target "${CONFLICTS_REC_TARGET_REL}"
    output_json_object_end
    i=$((i + 1))
  done
  output_json_array_end
  output_json_end
}

# conflicts_launch_dirs - open every recorded conflict directory once with
# the platform opener: `open` on macOS, `xdg-open` elsewhere (the same
# selection lib/commands/open.sh makes). Dies when neither exists; warns
# and returns 1 when the opener fails for a directory.
conflicts_launch_dirs() {
  local total="${#CONFLICTS_OPEN_DIRS[@]}" i=0 dir="" opener="" failed=0 p_dir=""
  [[ "$total" -gt 0 ]] || return 0
  # platform.sh is lazy; load it for platform_opener below.
  sciebo_require_module platform platform_opener
  opener="$(platform_opener)"
  [[ -n "$opener" ]] ||
    die "cannot open conflicts: neither 'open' (macOS) nor 'xdg-open' (Linux) was found"
  while [[ "$i" -lt "$total" ]]; do
    dir="${CONFLICTS_OPEN_DIRS[$i]}"
    if ! "$opener" -- "$dir"; then
      p_dir=${ printable "$dir";}
      warn "conflicts: cannot open '${p_dir}': ${opener} failed"
      failed=1
    fi
    i=$((i + 1))
  done
  return "$failed"
}

# conflicts_validate_remote MODE APPLY OPEN KIND - the --remote combination
# rules: --remote is read-only, so it rejects --resolve, --apply, --yes, and
# --open, and lists case clashes only (--kind case or all). Called by
# conflicts_parse_validate once --remote is set.
conflicts_validate_remote() {
  local mode="$1" apply="$2" open="$3" kind="$4"
  [[ -z "$mode" ]] || usage_error conflicts "--remote cannot be combined with --resolve"
  [[ "$apply" == false ]] || usage_error conflicts "--remote cannot be combined with --apply"
  [[ -z "${OPT_yes:-}" ]] || usage_error conflicts "--remote cannot be combined with --yes"
  [[ "$open" == false ]] || usage_error conflicts "--remote cannot be combined with --open"
  case "$kind" in
    all | case) ;;
    *) usage_error conflicts "--remote lists case clashes only (use --kind case or all)" ;;
  esac
  return 0
}

# conflicts_validate_resolve MODE APPLY OPEN REMOTE - the --open combination
# rules and, for --resolve, the mode check and the options it requires;
# without --resolve, --apply/--yes and --json (except with --remote) need it.
# Called by conflicts_parse_validate after the remote rules.
conflicts_validate_resolve() {
  local mode="$1" apply="$2" open="$3" remote="$4"
  if [[ "$open" == true ]]; then
    [[ -z "$mode" ]] || usage_error conflicts "--open cannot be combined with --resolve"
    [[ "$apply" == false ]] || usage_error conflicts "--open cannot be combined with --apply"
    [[ -z "${OPT_yes:-}" ]] || usage_error conflicts "--open cannot be combined with --yes"
    [[ -z "${OPT_json:-}" ]] || usage_error conflicts "--open cannot be combined with --json"
  fi
  if [[ -n "$mode" ]]; then
    case "$mode" in
      keep-local | keep-remote | keep-newest | keep-oldest | keep-both) ;;
      *) usage_error conflicts "unknown --resolve mode '$(printable "$mode")' (use keep-local, keep-remote, keep-newest, keep-oldest, or keep-both)" ;;
    esac
  else
    [[ "$apply" == false ]] || usage_error conflicts "--apply requires --resolve MODE"
    [[ -z "${OPT_yes:-}" ]] || usage_error conflicts "--yes requires --resolve MODE"
    if [[ "$remote" != true ]]; then
      [[ -z "${OPT_json:-}" ]] || usage_error conflicts "--json requires --resolve MODE"
    fi
  fi
  return 0
}

# conflicts_parse_validate ONLY_VAR MODE_VAR APPLY_VAR OPEN_VAR REMOTE_VAR "$@"
# - parse the command line and apply the --open/--remote/--resolve/--apply/
# --yes/--json combination rules; also set CONFLICTS_QUIET/CONFLICTS_KIND and
# the output mode. Assigns the five named locals and returns 0; a usage error
# never returns.
conflicts_parse_validate() {
  local -n out_only="$1" out_mode="$2" out_apply="$3" out_open="$4" out_remote="$5"
  shift 5
  local kind=""
  opt_begin "resolve:s only:s quiet:b apply:b yes:b json:b kind:s open:b remote:b" conflicts "" "$@"
  opt_guard conflicts
  # shellcheck disable=SC2034  # assigned through the nameref out-params
  out_only="${OPT_only:-}"
  out_mode="${OPT_resolve:-}"
  out_remote=false
  opt_into out_remote remote
  kind="${OPT_kind:-all}"
  case "$kind" in
    all | copy | case) ;;
    *) usage_error conflicts "unknown --kind '$(printable "$kind")' (use copy, case, or all)" ;;
  esac
  CONFLICTS_QUIET=false
  opt_into CONFLICTS_QUIET quiet
  CONFLICTS_KIND="$kind"
  CONFLICTS_OPEN=false
  out_apply=false
  out_open=false
  opt_into out_open open
  opt_into out_apply apply
  if [[ "$out_remote" == true ]]; then
    conflicts_validate_remote "$out_mode" "$out_apply" "$out_open" "$kind"
  fi
  conflicts_validate_resolve "$out_mode" "$out_apply" "$out_open" "$out_remote"
  opt_json_mode
  return 0
}

# conflicts_remote_entry ONLY JSON - list the remote case clashes of one
# already-parsed manifest entry (filtered by ONLY), counting them in
# CONFLICTS_TOTAL and printing a row or JSON object per clash. A listing
# failure warns, counts in CONFLICTS_REMOTE_FAILED, and continues without
# failing the command; it must not look like "no remote clashes".
conflicts_remote_entry() {
  local only="${1:-}" json="$2" spec="" pairs="" first="" second=""
  local p_first="" p_second=""
  [[ -z "$only" || "$ENTRY_NAME" == "$only" ]] || return 0
  spec=${ remote_spec "$ENTRY_REMOTE";}
  if ! pairs="$(policy_case_clashes_remote "$spec")"; then
    warn "conflicts: '${ENTRY_NAME}': could not list ${spec}; skipping the remote case scan"
    CONFLICTS_REMOTE_FAILED=$((CONFLICTS_REMOTE_FAILED + 1))
    return 0
  fi
  [[ -n "$pairs" ]] || return 0
  while IFS=$'\t' read -r first second; do
    [[ -n "$first" && -n "$second" ]] || continue
    CONFLICTS_TOTAL=$((CONFLICTS_TOTAL + 1))
    if [[ "$json" == true ]]; then
      output_json_object_begin
      output_json_kv source "$ENTRY_NAME"
      output_json_kv kind case
      output_json_kv first "$first"
      output_json_kv second "$second"
      output_json_object_end
    elif [[ "$CONFLICTS_QUIET" != true ]]; then
      p_first=${ printable "$first";}
      p_second=${ printable "$second";}
      conflicts_remote_row "$ENTRY_NAME" "$p_first" "$p_second"
    fi
  done <<<"$pairs"
  return 0
}

# conflicts_run_remote_list ONLY - online read-only listing of remote case
# clashes below every source's remote subtree (filtered by ONLY). policy_
# case_clashes_remote reports each pair; the kept (first) and losing (second)
# names are printed, or a JSON document with --json. Nothing is renamed or
# written on either side; --quiet exits 1 when a clash exists. A source whose
# remote listing failed is warned about and counted as incomplete, but the
# command still succeeds. Returns the command status.
conflicts_run_remote_list() {
  local only="$1" count=0
  local json=false
  output_json_enabled && json=true
  if [[ "$json" == true ]]; then
    output_json_begin
    output_json_kv_raw remote true
    output_json_array_begin items
  elif [[ "$CONFLICTS_QUIET" != true ]]; then
    conflicts_remote_row "SOURCE" "KEPT (FIRST)" "LOSER (SECOND)"
  fi
  CONFLICTS_TOTAL=0
  CONFLICTS_REMOTE_FAILED=0
  manifest_each conflicts_remote_entry "$only" "$json"
  count="$CONFLICTS_TOTAL"
  if [[ "$json" == true ]]; then
    output_json_array_end
    output_json_kv_raw total "$count"
    output_json_end
    return 0
  fi
  if [[ "$CONFLICTS_QUIET" == true ]]; then
    [[ "$count" -eq 0 ]] || return 1
    return 0
  fi
  if [[ "$CONFLICTS_REMOTE_FAILED" -gt 0 ]]; then
    printf 'remote case scan incomplete: %d source(s) could not be listed\n' "$CONFLICTS_REMOTE_FAILED"
  fi
  if [[ "$count" -gt 0 ]]; then
    printf '%d remote case clash(es) found\n' "$count"
  elif [[ "$CONFLICTS_REMOTE_FAILED" -eq 0 ]]; then
    printf 'no remote case clashes\n'
  fi
  return 0
}

# conflicts_run_list ONLY OPEN - scan the manifest (filtered by ONLY) and print
# the report; with OPEN also launch the recorded conflict directories. Returns
# the command status.
conflicts_run_list() {
  local only="$1" open="$2"
  if [[ "$CONFLICTS_QUIET" != true ]]; then
    conflicts_print_row "SOURCE" "RELATIVE PATH" "MODIFIED" "SIZE" "KIND"
  fi
  manifest_each conflicts_each_list_entry "$only"
  if [[ "$open" == true ]]; then
    if [[ "$CONFLICTS_TOTAL" -eq 0 ]]; then
      [[ "$CONFLICTS_QUIET" == true ]] || printf 'no conflicts\n'
      return 0
    fi
    [[ "$CONFLICTS_QUIET" == true ]] || printf '%d conflict copy(ies) found\n' "$CONFLICTS_TOTAL"
    conflicts_launch_dirs || return 1
    return 0
  fi
  if [[ "$CONFLICTS_QUIET" == true ]]; then
    if [[ "$CONFLICTS_TOTAL" -gt 0 ]]; then
      return 1
    fi
    return 0
  fi
  if [[ "$CONFLICTS_TOTAL" -gt 0 ]]; then
    printf '%d conflict copy(ies) found\n' "$CONFLICTS_TOTAL"
  else
    printf 'no conflict copies\n'
  fi
  return 0
}

# conflicts_run_resolve ONLY MODE APPLY - plan the resolve actions for the
# manifest (filtered by ONLY) and, with APPLY, confirm and carry them out;
# print the plan or result. Returns the command status.
conflicts_run_resolve() {
  local only="$1" mode="$2" apply="$3" total=0
  manifest_each conflicts_each_resolve_entry "$only" "$mode"
  total="${#CONFLICTS_PLAN[@]}"
  if [[ "$apply" == true ]]; then
    if [[ "$total" -gt 0 ]]; then
      conflicts_resolve_confirm || return 1
      conflicts_apply_plan
    fi
  else
    CONFLICTS_RESOLVED="$total"
  fi
  if output_json_enabled; then
    conflicts_print_json
  elif [[ "$CONFLICTS_QUIET" != true ]]; then
    conflicts_print_plan
    if [[ "$CONFLICTS_TOTAL" -gt 0 ]]; then
      if [[ "$apply" == true ]]; then
        printf 'resolved %d conflict copy(ies)\n' "$CONFLICTS_RESOLVED"
      else
        printf '%d to resolve (dry run)\n' "$total"
      fi
    else
      printf 'no conflict copies\n'
    fi
  fi
  if [[ "$apply" == true ]]; then
    [[ "$CONFLICTS_FAILED" -eq 0 ]] || return 1
    return 0
  fi
  if [[ "$CONFLICTS_QUIET" == true && "$CONFLICTS_TOTAL" -gt 0 ]]; then
    return 1
  fi
  return 0
}

cmd_conflicts() {
  local only="" mode="" apply=false open=false remote=false
  conflicts_parse_validate only mode apply open remote "$@"
  # Run dependencies load after the parse (its opt_begin consumed --help),
  # so `sciebo conflicts --help` parses none of them: the remote case-clash
  # scan uses the policy helpers, the walkers go through the manifest, and
  # the resolve/delete gates prompt through the ui helpers.
  sciebo_require_module policy policy_case_clashes
  sciebo_require_module manifest manifest_each
  sciebo_require_module ui ui_confirm
  if [[ "$remote" == true ]]; then
    # The online scan needs the rclone binary and a configured remote; it is
    # read-only and never resolves anything server-side.
    load_settings
    manifest_index_load
    if [[ -n "$only" ]]; then
      manifest_require_name "$only"
    fi
    require_remote
    conflicts_run_remote_list "$only"
    return
  fi
  load_settings --no-rclone
  manifest_index_load
  if [[ -n "$only" ]]; then
    manifest_require_name "$only"
  fi
  conflicts_plan_reset
  CONFLICTS_OPEN_DIRS=()
  CONFLICTS_OPEN_SEEN=()
  [[ "$open" == false ]] || CONFLICTS_OPEN=true
  if [[ -z "$mode" ]]; then
    conflicts_run_list "$only" "$open"
    return
  fi
  conflicts_run_resolve "$only" "$mode" "$apply"
}
