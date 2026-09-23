#!/bin/bash
# folders_choose.sh - `sciebo folders choose`: browse the remote, gather
# pairs into the P_* state, and commit them through folders.sh's
# folders_commit_pending; the optional dry run execs bin/sciebo check.

CHOOSE_PENDING_NAMES=$'\n'
CHOOSE_EXCLUDES=""
CHOOSE_PAIR_MODE=""
CHOOSE_SELECT_MODE=0
# Out-param of choose_remote_size: the last measured size in bytes, so the
# big-folder gate can read the cached lookup without a command substitution
# (which would run it in a subshell and drop the shared cache).
CHOOSE_REMOTE_SIZE_BYTES=""
# Per-run cache of fallback `rclone_remote_size` lookups keyed by remote spec,
# used only when sync's shared cache is unavailable (folders_choose does not
# load sync). Repeated gates for the same subtree reuse one result within a
# run; a failed lookup is not cached, so a later gate can retry it.
declare -gA CHOOSE_REMOTE_SIZE_CACHE=()
# Scratch array the shared remote-path engine appends excludes to; the
# wizard only gates pairs, so it stays empty.
# shellcheck disable=SC2034  # assigned through the engine's nameref out-param
CHOOSE_POLICY_EXCLUDES=()

# choose_remote_dirs DEPTH - fill CHOOSE_ITEMS with the unconfigured remote
# folders (sorted), printing a skip note for configured ones; rc 1 = none.
choose_remote_dirs() {
  local raw="" listing="" sub=""
  CHOOSE_ITEMS=()
  if ! listing="$(rclone_cmd lsf "${REMOTE_PREFIX}" --dirs-only -R --max-depth "$1" 2>/dev/null)"; then
    die "cannot list ${REMOTE_PREFIX} (depth $1); is the remote reachable?"
  fi
  while IFS= read -r raw; do
    sub=${ strip_trailing_slashes "$raw";}
    [[ -n "$sub" ]] || continue
    if manifest_has_remote "$sub"; then
      printf 'skip %s (already configured)\n' "${ printable "$sub";}"
      continue
    fi
    CHOOSE_ITEMS[${#CHOOSE_ITEMS[@]}]="$sub"
  done <<<"$(printf '%s\n' "$listing" | LC_ALL=C sort)"
  [[ "${#CHOOSE_ITEMS[@]}" -gt 0 ]]
}

# choose_pick_mode SUB MODE_FIXED - set CHOOSE_PAIR_MODE from MODE_FIXED or
# an interactive 1/2/3 prompt (three invalid answers abort).
choose_pick_mode() {
  local sub="$1" fixed="$2" num=1 answer="" tries=0
  local -a modes=(bisync pull sync)
  if [[ -n "$fixed" ]]; then
    CHOOSE_PAIR_MODE="$fixed"
    return 0
  fi
  case "$DEFAULT_PAIR_MODE" in pull) num=2 ;; sync) num=3 ;; esac
  printf "Direction for '%s': 1) bisync (two-way) 2) pull (download) 3) sync (upload)\n" "${ printable "$sub";}"
  while [[ -z "$CHOOSE_PAIR_MODE" ]]; do
    ui_ask "Choose [1-3, default ${num}]: " || die "input ended; nothing changed"
    answer=${ trim "$UI_ASK_REPLY";}
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

# choose_load_children SUB [SORT] - fill CHOOSE_ITEMS with the immediate child
# folders of SUB (trailing slashes stripped); SORT=1 orders them with
# LC_ALL=C sort like the include flow. rc 1 when the remote has no subfolders.
choose_load_children() {
  local sub="$1" sort="${2:-0}" spec="" raw="" listing=""
  CHOOSE_ITEMS=()
  spec="$(remote_spec "$sub")"
  listing="$(rclone_cmd lsf "$spec" --dirs-only --max-depth 1 2>/dev/null || true)"
  [[ "$sort" -eq 0 ]] || listing="$(printf '%s\n' "$listing" | LC_ALL=C sort)"
  while IFS= read -r raw; do
    raw=${ strip_trailing_slashes "$raw";}
    [[ -n "$raw" ]] || continue
    CHOOSE_ITEMS[${#CHOOSE_ITEMS[@]}]="$raw"
  done <<<"$listing"
  [[ "${#CHOOSE_ITEMS[@]}" -gt 0 ]]
}

# choose_pick_excludes SUB - ask whether to exclude subfolders and gather
# the picks into CHOOSE_EXCLUDES (empty when none); rc 2 on read failure.
# An empty selection means "no excludes" and keeps the pair; only a read
# failure (rc 2) aborts.
choose_pick_excludes() {
  local child="" rc=0
  CHOOSE_EXCLUDES=""
  ui_ask "Exclude subfolders of '${ printable "$1";}'? [y/N]: " || die "input ended; nothing changed"
  case "${ trim "$UI_ASK_REPLY";}" in y | Y) ;; *) return 0 ;; esac
  if ! choose_load_children "$1" 0; then
    printf '  no subfolders found\n'
    return 0
  fi
  choose_select_items 'Select subfolders to exclude (empty for none): ' || rc=$?
  [[ "$rc" -ne 2 ]] || return 2
  if [[ "${#CHOOSE_SELECTED[@]}" -gt 0 ]]; then
    for child in "${CHOOSE_SELECTED[@]}"; do
      CHOOSE_EXCLUDES="${CHOOSE_EXCLUDES}${child}"$'\n'
    done
  fi
}

# choose_include_excludes SUB - Nextcloud-client-style include flow: ask
# whether to sync every immediate subfolder, then gather the picks into
# CHOOSE_EXCLUDES as the complement (empty when all are included); rc 2 on
# read failure. An empty selection excludes every child and warns.
choose_include_excludes() {
  local sub="$1" raw="" item="" child="" selected=$'\n' rc=0
  CHOOSE_EXCLUDES=""
  if ! choose_load_children "$sub" 1; then
    printf '  no subfolders found\n'
    return 0
  fi
  # The shared [Y/n] gate: an empty reply or y/yes includes all; a typed
  # decline falls through to the picker. EOF also returns 1, so an empty
  # reply after a decline is EOF and keeps the old fatal path.
  if ui_confirm_default_yes "Include all ${#CHOOSE_ITEMS[@]} subfolders of '${ printable "$sub";}'?"; then
    return 0
  fi
  [[ -n "${UI_ASK_REPLY:-}" ]] || die "input ended; nothing changed"
  choose_select_items 'Select subfolders to sync (empty selects none): ' || rc=$?
  [[ "$rc" -ne 2 ]] || return 2
  if [[ "${#CHOOSE_SELECTED[@]}" -gt 0 ]]; then
    for item in "${CHOOSE_SELECTED[@]}"; do
      selected="${selected}${item}"$'\n'
    done
  else
    warn "no subfolders selected; only files directly under '${ printable "$sub";}' will be synced"
  fi
  for child in "${CHOOSE_ITEMS[@]}"; do
    [[ "$selected" == *$'\n'"${child}"$'\n'* ]] && continue
    CHOOSE_EXCLUDES="${CHOOSE_EXCLUDES}${child}"$'\n'
  done
}

# choose_policy_confirm KIND SUB DESC - rc 0 when the user confirmed adding
# the pair; rc 1 when declined, and rc 1 also without prompting when stdin
# is not a TTY or the run is non-interactive (SCIEBO_NON_INTERACTIVE) -
# ui_confirm_tty's "cannot ask" rc 2 maps onto the return 1 that the ask
# policies turn into a skip, exactly like the old `[[ -t 0 && -z
# SCIEBO_NON_INTERACTIVE ]] || return 1` gate.
choose_policy_confirm() {
  local kind="$1" sub="$2" desc="$3" rc=0
  ui_confirm_tty "${kind}: '${ printable "$sub";}' is ${desc}; add it anyway?" || rc=$?
  [[ "$rc" -eq 0 ]]
}

# choose_policy_confirm_external / _e2ee - the ask-policy callbacks the
# shared engine runs once it has found the reported scope from the globals it
# set (POLICY_REMOTE_LAST_SUB/LAST_SCOPE); the wording matches the gates.
choose_policy_confirm_external() {
  choose_policy_confirm "external storage" "$POLICY_REMOTE_LAST_SUB" "on mounted external storage (${POLICY_REMOTE_LAST_SCOPE})"
}

choose_policy_confirm_e2ee() {
  choose_policy_confirm "e2ee" "$POLICY_REMOTE_LAST_SUB" "end-to-end encrypted (${POLICY_REMOTE_LAST_SCOPE})"
}

# choose_remote_size SUB - print the size in bytes of one remote folder,
# setting CHOOSE_REMOTE_SIZE_BYTES to the same value. When sync is loaded the
# shared sync_remote_size_lookup cache is used, so a repeated or overlapping
# probe reuses one `rclone size`; otherwise a local per-run cache keyed by the
# remote spec wraps the bounded rclone_remote_size lookup, so repeated gates
# for the same subtree do not re-fetch either. rc 1 when it cannot be read.
choose_remote_size() {
  local spec="" bytes=""
  spec=${ remote_spec "$1";}
  CHOOSE_REMOTE_SIZE_BYTES=""
  if have_function sync_remote_size_lookup; then
    sync_remote_size_lookup "$spec" || return 1
    CHOOSE_REMOTE_SIZE_BYTES="$SYNC_REMOTE_SIZE_BYTES"
    printf '%s' "$CHOOSE_REMOTE_SIZE_BYTES"
    return 0
  fi
  if [[ -n "${CHOOSE_REMOTE_SIZE_CACHE[$spec]+cached}" ]]; then
    CHOOSE_REMOTE_SIZE_BYTES="${CHOOSE_REMOTE_SIZE_CACHE[$spec]}"
    printf '%s' "$CHOOSE_REMOTE_SIZE_BYTES"
    return 0
  fi
  bytes="$(rclone_remote_size "$spec")" || return 1
  [[ -n "$bytes" ]] || return 1
  CHOOSE_REMOTE_SIZE_CACHE[$spec]="$bytes"
  CHOOSE_REMOTE_SIZE_BYTES="$bytes"
  printf '%s' "$bytes"
  return 0
}

# Out-param of choose_bigfolder_label: the human label for the last gated
# folder, resolved in the caller's shell so a missing dependency aborts loudly.
CHOOSE_BIGFOLDER_LABEL=""

# choose_bigfolder_label BYTES - set CHOOSE_BIGFOLDER_LABEL to the human label
# of BYTES. bigfolder's _bigfolder_label is required at load time; resolving it
# through this wrapper (not a command substitution) turns a missing dependency
# into a clear failure instead of the `command not found` the gate's `|| rc=$?`
# would otherwise swallow, leaving an empty size in the ask/warn message.
choose_bigfolder_label() {
  have_function _bigfolder_label ||
    die "big-folder gate: _bigfolder_label is unavailable (bigfolder module failed to load)"
  CHOOSE_BIGFOLDER_LABEL=${ _bigfolder_label "$1";}
}

# choose_bigfolder_gate SUB - apply BIG_FOLDER_POLICY to a pair whose remote
# folder is above BIG_FOLDER_SIZE: warn proceeds with a warning, ask
# confirms on a TTY (and skips non-interactively), and skip never prompts.
# One bounded size lookup; an unknown size or a disabled setting proceeds.
# Returns 0 to keep the pair, 2 to skip it.
choose_bigfolder_gate() {
  local sub="$1" policy="${BIG_FOLDER_POLICY:-ask}" limit="" bytes="" label="" confirmed=0
  [[ -n "${BIG_FOLDER_SIZE:-}" ]] || return 0
  limit=${ size_suffix_bytes "$BIG_FOLDER_SIZE" 2>/dev/null;} || return 0
  [[ -n "$limit" ]] || return 0
  choose_remote_size "$sub" >/dev/null 2>&1 || return 0
  bytes="$CHOOSE_REMOTE_SIZE_BYTES"
  [[ -n "$bytes" && "$bytes" -gt "$limit" ]] || return 0
  choose_bigfolder_label "$bytes"
  label="$CHOOSE_BIGFOLDER_LABEL"
  if [[ "$policy" == "ask" ]]; then
    if choose_policy_confirm "big folder" "$sub" "${label} (limit ${BIG_FOLDER_SIZE})"; then
      confirmed=1
    fi
  fi
  choose_policy_decision "$policy" "$confirmed" >/dev/null || {
    warn "big folder: '${ printable "$sub";}' is ${label} (limit ${BIG_FOLDER_SIZE}); skipping (BIG_FOLDER_POLICY=${policy})"
    return 2
  }
  if [[ "$policy" == "warn" ]]; then
    warn "big folder: '${ printable "$sub";}' is ${label} (limit ${BIG_FOLDER_SIZE}); adding anyway (BIG_FOLDER_POLICY=warn)"
  fi
  return 0
}

# choose_external_gate SUB - apply EXTERNAL_STORAGE_POLICY when SUB or its
# immediate parent is on server-mounted external storage (oc:permissions
# "M"): allow is silent, warn warns and proceeds, ask confirms on a TTY
# (and skips otherwise), skip skips with a warning. Silent on non-Nextcloud
# remotes and when the server does not expose the property. Returns 0 to
# keep the pair, 2 to skip it.
choose_external_gate() {
  local sub="$1" policy="${EXTERNAL_STORAGE_POLICY:-ask}" rc=0
  POLICY_REMOTE_ROOT="$sub"
  POLICY_REMOTE_STYLE=wizard
  POLICY_REMOTE_SCOPE_SEARCH=1
  POLICY_REMOTE_CONFIRM=choose_policy_confirm_external
  POLICY_REMOTE_SINK=warn
  policy_remote_paths_apply "$policy" nc_external_paths external CHOOSE_POLICY_EXCLUDES POLICY_REMOTE_COUNT || rc=$?
  return "$rc"
}

# choose_e2ee_gate SUB - apply E2EE_POLICY when SUB or its immediate parent
# is end-to-end encrypted (nc:is-encrypted): allow is silent, warn warns
# and proceeds, exclude skips with a message that the encrypted blobs
# cannot be decrypted. Silent on non-Nextcloud remotes and when the server
# does not expose the property. Returns 0 to keep the pair, 2 to skip it.
choose_e2ee_gate() {
  local sub="$1" policy="${E2EE_POLICY:-exclude}" rc=0
  # POLICY_REMOTE_* are read by policy_remote_paths_apply in lib/policy.sh,
  # which shellcheck cannot follow through sciebo_require_module.
  # shellcheck disable=SC2034  # read by policy_remote_paths_apply
  POLICY_REMOTE_ROOT="$sub"
  # shellcheck disable=SC2034  # read by policy_remote_paths_apply
  POLICY_REMOTE_STYLE=wizard
  # shellcheck disable=SC2034  # read by policy_remote_paths_apply
  POLICY_REMOTE_SCOPE_SEARCH=1
  # shellcheck disable=SC2034  # read by policy_remote_paths_apply
  POLICY_REMOTE_CONFIRM=choose_policy_confirm_e2ee
  # shellcheck disable=SC2034  # read by policy_remote_paths_apply
  POLICY_REMOTE_SINK=warn
  policy_remote_paths_apply "$policy" nc_e2ee_paths e2ee CHOOSE_POLICY_EXCLUDES POLICY_REMOTE_COUNT || rc=$?
  return "$rc"
}

# choose_pair_policy_preflight SUB - apply the big-folder, external-storage,
# and E2EE policies to a proposed pair in that order. Returns 0 to keep the
# pair, 2 to skip it; the first skip wins.
choose_pair_policy_preflight() {
  local sub="$1" gate="" rc=0
  for gate in choose_bigfolder_gate choose_external_gate choose_e2ee_gate; do
    rc=0
    "$gate" "$sub" || rc=$?
    [[ "$rc" -ne 2 ]] || return 2
  done
  return 0
}

# choose_gather_pair SUB MODE_FIXED LOCAL_ROOT - prompt for the local
# destination, direction, and excludes, then append the pair to P_*. rc 1
# (after a warning) = name already configured or already picked; rc 2 =
# reading input failed (nothing has been written).
choose_gather_pair() {
  local sub="$1" mode_fixed="$2" local_root="$3"
  local name="" answer="" default_local="" rc=0
  name="$(entry_name_for "$sub")"
  if manifest_has_name "$name"; then
    warn "skipping '${ printable "$sub";}': a source named '${name}' already exists"
    return 1
  fi
  if [[ "$CHOOSE_PENDING_NAMES" == *$'\n'"${name}"$'\n'* ]]; then
    warn "skipping '${ printable "$sub";}': a source named '${name}' is already in this selection"
    return 1
  fi
  choose_pair_policy_preflight "$sub" || rc=$?
  [[ "$rc" -ne 2 ]] || return 1
  default_local="${local_root}/${sub}"
  ui_ask "Local path [${ printable "$default_local";}]: " || die "input ended; nothing changed"
  answer=${ trim "$UI_ASK_REPLY";}
  [[ -n "$answer" ]] || answer="$default_local"
  answer="$(expand_local_path "$answer")"
  [[ -n "$answer" ]] || die "local path for '${ printable "$sub";}' must not be empty"
  safe_local_path "$answer" || die "invalid local path '${ printable "$answer";}'"
  choose_pick_mode "$sub" "$mode_fixed"
  if [[ "$CHOOSE_SELECT_MODE" -eq 1 ]]; then
    choose_include_excludes "$sub" || return 2
  else
    choose_pick_excludes "$sub" || return 2
  fi
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
  local name="" rc=0 failed=0
  # Shared [Y/n] gate. EOF now declines like a typed "no" (the old bare
  # ui_ask treated a closed stdin as the default yes), so a run whose stdin
  # ended does not launch the dry-run children.
  ui_confirm_default_yes 'Run a dry run for the new pairs now?' || return 0
  for name in "${P_NAMES[@]}"; do
    rc=0
    "${PROJECT_DIR}/bin/sciebo" check --only "$name" || rc=$?
    if [[ "$rc" -eq 0 ]]; then
      printf 'dry run ok: %s\n' "$name"
    else
      printf 'dry run FAILED: %s (exit %s)\n' "$name" "$rc"
      failed=1
    fi
  done
  [[ "$failed" -eq 0 ]]
}

cmd_choose() {
  local depth="" local_root="" mode_fixed="" sub="" rc=0
  opt_begin "depth:s local-root:s mode:s no-fzf:b no-dry-run:b select:b" folders "choose: " "$@"
  opt_guard folders "choose: "
  # Run dependencies load after opt_guard's --help exit, so the module can
  # be sourced (by folders.sh) without parsing any of them: the shared
  # remote-path gate and the wizard's pure policy decision use policy, the
  # remote browse/gate probes use nc_api/http, the big-folder gate labels
  # sizes through bigfolder's _bigfolder_label (which prefers capabilities'
  # human-readable label, so the wizard prints "2Mi" like sync/doctor), the
  # picker/prompt helpers come from ui, and the pair lookups go through the
  # manifest.
  sciebo_require_module policy policy_case_clashes
  sciebo_require_module http xml_get
  sciebo_require_module nc_api nc_dav_request_allow
  sciebo_require_module capabilities capabilities_size_label
  sciebo_require_module bigfolder _bigfolder_label
  sciebo_require_module ui ui_ask
  sciebo_require_module manifest manifest_each
  P_MODES=() P_LOCALS=() P_SUBS=() P_NAMES=() P_EXCLUDES=()
  CHOOSE_PENDING_NAMES=$'\n'
  CHOOSE_REMOTE_SIZE_CACHE=()
  CHOOSE_SELECT_MODE="${OPT_select:-0}"
  load_settings
  depth="${OPT_depth:-$FOLDERS_SCAN_DEPTH}" local_root="${OPT_local_root:-$FOLDERS_LOCAL_ROOT}"
  if [[ ! "$depth" =~ ^[0-9]+$ ]] || [[ "$((10#$depth))" -lt 1 ]]; then
    die "invalid --depth '${depth}': expected a positive integer"
  fi
  depth=$((10#$depth))
  [[ "${OPT_mode_SET:-0}" -eq 0 ]] || valid_entry_mode "${OPT_mode:-}" || die "invalid mode '${OPT_mode:-}' (expected sync, pull, or bisync)"
  mode_fixed="${OPT_mode:-}"
  require_remote
  local_root=${ strip_trailing_slashes "$(expand_local_path "$local_root")";}
  if ! choose_remote_dirs "$depth"; then
    printf 'nothing to choose: no unconfigured folders under %s (depth %s)\n' "$REMOTE_PREFIX" "$depth"
    return 0
  fi
  rc=0
  choose_select_items 'Select folders (e.g. "1 3 5-7", "all", empty to abort): ' 'Select folders> ' "${OPT_no_fzf:-0}" || rc=$?
  [[ "$rc" -ne 2 ]] || return 1
  if [[ "$rc" -ne 0 ]]; then
    printf 'aborted, nothing changed\n'
    return 0
  fi
  for sub in "${CHOOSE_SELECTED[@]}"; do
    rc=0
    choose_gather_pair "$sub" "$mode_fixed" "$local_root" || rc=$?
    [[ "$rc" -ne 2 ]] || return 1
  done
  if [[ "${#P_SUBS[@]}" -eq 0 ]]; then
    printf 'nothing to add, nothing changed\n'
    return 0
  fi
  choose_preview_pairs
  ui_ask "Add these ${#P_SUBS[@]} pair(s) to ${FOLDERS_FILE}? [y/N]: " || die "input ended; nothing changed"
  case "${ trim "$UI_ASK_REPLY";}" in
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
