#!/bin/bash
# folders_choose.sh - `sciebo folders choose`: browse the remote, gather
# pairs into the P_* state, and commit them through folders.sh's
# folders_commit_pending; the optional dry run execs bin/sciebo check.

CHOOSE_PENDING_NAMES=$'\n'
CHOOSE_EXCLUDES=""
CHOOSE_PAIR_MODE=""

# choose_remote_dirs DEPTH - fill CHOOSE_ITEMS with the unconfigured remote
# folders (sorted), printing a skip note for configured ones; rc 1 = none.
choose_remote_dirs() {
  local raw="" listing="" sub=""
  CHOOSE_ITEMS=()
  if ! listing="$(rclone_cmd lsf "${REMOTE_PREFIX}" --dirs-only -R --max-depth "$1" 2>/dev/null)"; then
    die "cannot list ${REMOTE_PREFIX} (depth $1); is the remote reachable?"
  fi
  while IFS= read -r raw; do
    sub="${raw%/}"
    [[ -n "$sub" ]] || continue
    manifest_has_remote "$sub" && printf 'skip %s (already configured)\n' "$(printable "$sub")" && continue
    CHOOSE_ITEMS[${#CHOOSE_ITEMS[@]}]="$sub"
  done <<<"$(printf '%s\n' "$listing" | LC_ALL=C sort)"
  [[ "${#CHOOSE_ITEMS[@]}" -gt 0 ]]
}

# choose_pick_mode SUB MODE_FIXED - set CHOOSE_PAIR_MODE from MODE_FIXED or
# an interactive 1/2/3 prompt (three invalid answers abort).
choose_pick_mode() {
  local sub="$1" fixed="$2" num=1 answer="" tries=0
  local -a modes=(bisync pull sync)
  if [[ -n "$fixed" ]]; then CHOOSE_PAIR_MODE="$fixed" && return 0; fi
  case "$DEFAULT_PAIR_MODE" in pull) num=2 ;; sync) num=3 ;; esac
  printf "Direction for '%s': 1) bisync (two-way) 2) pull (download) 3) sync (upload)\n" "$(printable "$sub")"
  while [[ -z "$CHOOSE_PAIR_MODE" ]]; do
    ui_ask "Choose [1-3, default ${num}]: " || die "input ended; nothing changed"
    answer="$(trim "$UI_ASK_REPLY")"
    case "$answer" in
      "") CHOOSE_PAIR_MODE="$DEFAULT_PAIR_MODE" ;;
      [123]) CHOOSE_PAIR_MODE="${modes[$((answer - 1))]}" ;;
      *)
        tries=$((tries + 1))
        [[ "$tries" -lt 3 ]] || die "invalid direction '${answer}'"
        warn "invalid direction '${answer}'; try again"
        ;;
    esac
  done
}

# choose_pick_excludes SUB - ask whether to exclude subfolders and gather
# the picks into CHOOSE_EXCLUDES (empty when none); rc 2 on read failure.
choose_pick_excludes() {
  local child=""
  CHOOSE_EXCLUDES=""
  ui_ask "Exclude subfolders of '$1'? [y/N]: " || die "input ended; nothing changed"
  case "$(trim "$UI_ASK_REPLY")" in y | Y) ;; *) return 0 ;; esac
  CHOOSE_ITEMS=()
  while IFS= read -r child; do
    child="${child%/}"
    [[ -n "$child" ]] || continue
    CHOOSE_ITEMS[${#CHOOSE_ITEMS[@]}]="$child"
  done <<<"$(rclone_cmd lsf "$(remote_spec "$1")" --dirs-only --max-depth 1 2>/dev/null || true)"
  if [[ "${#CHOOSE_ITEMS[@]}" -eq 0 ]]; then
    printf '  no subfolders found\n'
    return 0
  fi
  choose_select_items 'Select subfolders to exclude (empty for none): ' || return $?
  for child in "${CHOOSE_SELECTED[@]}"; do
    CHOOSE_EXCLUDES="${CHOOSE_EXCLUDES}${child}"$'\n'
  done
}

# choose_gather_pair SUB MODE_FIXED LOCAL_ROOT - prompt for the local
# destination, direction, and excludes, then append the pair to P_*. rc 1
# (after a warning) = name already configured or already picked; rc 2 =
# reading input failed (nothing has been written).
choose_gather_pair() {
  local sub="$1" mode_fixed="$2" local_root="$3"
  local name="" answer="" default_local=""
  name="$(entry_name_for "$sub")"
  if manifest_has_name "$name"; then
    warn "skipping '${sub}': a source named '${name}' already exists"
    return 1
  fi
  if [[ "$CHOOSE_PENDING_NAMES" == *$'\n'"${name}"$'\n'* ]]; then
    warn "skipping '${sub}': a source named '${name}' is already in this selection"
    return 1
  fi
  default_local="${local_root}/${sub}"
  ui_ask "Local path [${default_local}]: " || die "input ended; nothing changed"
  answer="$(trim "$UI_ASK_REPLY")"
  [[ -n "$answer" ]] || answer="$default_local"
  answer="$(expand_local_path "$answer")"
  [[ -n "$answer" ]] || die "local path for '${sub}' must not be empty"
  choose_pick_mode "$sub" "$mode_fixed"
  choose_pick_excludes "$sub" || return 2
  P_MODES[${#P_MODES[@]}]="$CHOOSE_PAIR_MODE"
  P_LOCALS[${#P_LOCALS[@]}]="$answer"
  P_SUBS[${#P_SUBS[@]}]="$sub"
  P_NAMES[${#P_NAMES[@]}]="$name"
  P_EXCLUDES[${#P_EXCLUDES[@]}]="$CHOOSE_EXCLUDES"
  CHOOSE_PENDING_NAMES="${CHOOSE_PENDING_NAMES}${name}"$'\n'
}

# choose_offer_dry_run - offer to dry-run the pairs just added, one
# `sciebo check --only` per pair; rc 1 if any run failed.
choose_offer_dry_run() {
  local name="" i=0 failed=0
  ui_ask 'Run a dry run for the new pairs now? [Y/n]: ' || UI_ASK_REPLY=""
  case "$(trim "$UI_ASK_REPLY")" in n | N) return 0 ;; esac
  for name in "${P_NAMES[@]}"; do
    i=0
    "${PROJECT_DIR}/bin/sciebo" check --only "$name" || i=$?
    if [[ "$i" -eq 0 ]]; then printf 'dry run ok: %s\n' "$name"; else printf 'dry run FAILED: %s (exit %s)\n' "$name" "$i" && failed=1; fi
  done
  [[ "$failed" -eq 0 ]]
}

cmd_choose() {
  local depth="" local_root="" mode_fixed="" sub="" rc=0
  opt_reset depth local_root mode no_fzf no_dry_run
  opt_parse "depth:s local-root:s mode:s no-fzf:b no-dry-run:b" folders "choose: " "$@"
  if [[ "$OPT_HELP" -ne 0 ]]; then usage_folders && return 0; fi
  [[ -z "$OPT_EXTRA" ]] || usage_error folders "choose: unknown option: ${OPT_EXTRA%%$'\n'*}"
  P_MODES=() P_LOCALS=() P_SUBS=() P_NAMES=() P_EXCLUDES=()
  CHOOSE_PENDING_NAMES=$'\n'
  load_settings
  depth="${OPT_depth:-$FOLDERS_SCAN_DEPTH}" local_root="${OPT_local_root:-$FOLDERS_LOCAL_ROOT}"
  if [[ ! "$depth" =~ ^[0-9]+$ ]] || [[ "$((10#$depth))" -lt 1 ]]; then
    die "invalid --depth '${depth}': expected a positive integer"
  fi
  depth=$((10#$depth))
  [[ "${OPT_mode_SET:-0}" -eq 0 ]] || valid_entry_mode "${OPT_mode:-}" || die "invalid mode '${OPT_mode:-}' (expected sync, pull, or bisync)"
  mode_fixed="${OPT_mode:-}"
  require_remote
  local_root="$(expand_local_path "$local_root")"
  local_root="${local_root%/}"
  if ! choose_remote_dirs "$depth"; then
    printf 'nothing to choose: no unconfigured folders under %s (depth %s)\n' "$REMOTE_PREFIX" "$depth"
    return 0
  fi
  choose_select_items 'Select folders (e.g. "1 3 5-7", "all", empty to abort): ' 'Select folders> ' "${OPT_no_fzf:-0}" || rc=$?
  [[ "$rc" -ne 2 ]] || return 1
  if [[ "$rc" -ne 0 ]]; then
    printf 'aborted, nothing changed\n'
    return 0
  fi
  for sub in "${CHOOSE_SELECTED[@]}"; do
    choose_gather_pair "$sub" "$mode_fixed" "$local_root" || rc=$?
    [[ "$rc" -ne 2 ]] || return 1
  done
  if [[ "${#P_SUBS[@]}" -eq 0 ]]; then
    printf 'nothing to add, nothing changed\n'
    return 0
  fi
  choose_preview_pairs
  ui_ask "Add these ${#P_SUBS[@]} pair(s) to ${FOLDERS_FILE}? [y/N]: " || die "input ended; nothing changed"
  case "$(trim "$UI_ASK_REPLY")" in
    y | Y) ;;
    *)
      printf 'aborted, nothing changed\n'
      return 0
      ;;
  esac
  folders_commit_pending
  [[ "${OPT_no_dry_run:-0}" -ne 0 ]] || choose_offer_dry_run || return 1
  return 0
}
