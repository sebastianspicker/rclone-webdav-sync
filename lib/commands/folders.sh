#!/bin/bash
# folders.sh command module - folder pairs (sciebo <-> local).
#
# `folders add` appends one pair; `folders choose` (folders_choose.sh)
# browses the remote and gathers pairs; `folders import` migrates a
# nextcloudcmd --unsyncedfolders list; all commit through
# folders_commit_pending. Only config/folders.conf and pair filter files
# under config/filters/ are written. The list subcommand is folders_cmd_list
# because cmd_list belongs to the top-level `sciebo list` in sync.sh.

# Pending pairs committed by folders_commit_pending; the wizard fills the
# same arrays.
P_MODES=()
P_LOCALS=()
P_SUBS=()
P_NAMES=()
P_EXCLUDES=()

# CHOOSE_ITEMS/CHOOSE_SELECTED back choose_select_items, the picker shared
# by the folder wizard's folder and exclude selections.
CHOOSE_ITEMS=()
CHOOSE_SELECTED=()

# One `ls -1t` (newest first) log listing per folders_cmd_list run.
FOLDERS_LIST_LOG_SNAPSHOT=""

# Newest log per dash-delimited entry-name prefix, built once from the
# snapshot by _folders_last_log_index_prime so each folders_last_log_for_into
# row is an O(1) lookup instead of rescanning the listing.
declare -A FOLDERS_LIST_LOG_INDEX=()

# Initialized bisync workdir names, primed once per `folders list` by
# _folders_bisync_init_prime. Membership is a plain lookup, so the row loop
# never forks `ls -A` for every bisync entry.
declare -A FOLDERS_BISYNC_INIT=()

# folders_row_columns' derived columns for the row currently parsed into
# ENTRY_*; folders_emit_json_row / folders_emit_text_row read them right
# after every derivation. Recomputed per row, never carried across rows
# (the INVALID branch does not touch them).
FOLDERS_ROW_FILTER=""
FOLDERS_ROW_REMOTE=""
FOLDERS_ROW_BISYNC=""
FOLDERS_ROW_LASTLOG=""
FOLDERS_ROW_PAUSED_COL=""
FOLDERS_ROW_PAUSED_BOOL=""
FOLDERS_ROW_HIDDEN_COL=""
FOLDERS_ROW_HIDDEN_BOOL=""

usage_folders() {
  usage_emit <<'EOF'
Usage: sciebo folders [command] [options]

Choose sciebo folders to pair with local directories, Nextcloud-client
style. With no command, `choose` runs. Only config/folders.conf and pair
filter files under config/filters/ are written; no data is transferred.

Commands:
  choose [options]        browse the remote and pick folders (default)
  add --remote SUB [options]
                          add a single pair without browsing
  import FILE [options]   add a pair from a nextcloudcmd --unsyncedfolders
                          list (one remote-relative folder per line)
  edit NAME [options]     rewrite a wizard pair's subfolder filter or mode
  list [--json]           table of all configured pairs
  pause NAME              skip NAME in sync/check until resumed
  resume NAME             clear NAME's paused flag
  remove NAME [--purge]   remove a wizard-managed pair from folders.conf
  -h, --help              show this help

choose options:
  --depth N               remote scan depth (default: FOLDERS_SCAN_DEPTH)
  --local-root DIR        local root for default destinations
                          (default: FOLDERS_LOCAL_ROOT)
  --mode MODE             fix the direction for all picks (sync|pull|bisync)
  --select                pick which subfolders to sync (include list)
  --no-fzf                always use the numbered menu
  --no-dry-run            do not offer a dry run after adding pairs

add options:
  --remote SUB            remote subfolder below the remote base (required)
  --local PATH            local path (default: <local-root>/<SUB>)
  --mode MODE             direction (sync|pull|bisync; default: DEFAULT_PAIR_MODE)
  --select                interactively pick subfolders to sync
  --include SUB           sync only this subfolder below --remote (repeatable)
  --exclude SUB           exclude SUB below the chosen folder (repeatable)
  --local-root DIR        local root for the default destination

import options:
  FILE                    nextcloudcmd --unsyncedfolders migration list:
                          one folder path per line, relative to --remote,
                          with or without a trailing slash; blank lines and
                          #-comments are ignored
  --remote SUB            remote subfolder below the remote base (required)
  --local PATH            local path (default: <local-root>/<SUB>)
  --mode MODE             direction (sync|pull|bisync; default: DEFAULT_PAIR_MODE)
  --local-root DIR        local root for the default destination
  --select                sync only the listed folders (include list);
                          every other immediate child is excluded

edit options (NAME is the sanitized entry name from `folders list`):
  --local PATH            change the pair's local path
  --remote SUB            change the pair's remote subfolder; "/" or an empty
                          value means the remote base, stored as "."
  --include SUB           sync only these immediate subfolders (repeatable);
                          every other immediate child is excluded
  --exclude SUB           exclude SUB below the pair (repeatable)
  --mode MODE             change the direction (sync|pull|bisync)
  --select                interactively pick subfolders to sync
  --clear                 remove the pair filter (no rules)
  --force                 allow a --remote change even though initialized
                          bisync state no longer matches; re-run
                          `sync --resync` afterwards
At least one option is required; the pair must be wizard-managed.

list options:
  --json                  print the same rows as {"pairs":[...]} instead of
                          the table

pause / resume:
  NAME                    sanitized pair name from `folders list`. pause
                          stores a per-pair paused flag; resume clears it. A
                          paused pair is reported as skipped by sync/check
                          (use `sync --force` to run it anyway).

remove options:
  --purge                 also delete the pair's bisync workdir, run record,
                          history, blacklist record, and pair filter; local
                          data directories are never touched

Modes: sync uploads, pull downloads, bisync is two-way (initialize once
with `make bisync-resync`). Run `make check` for a full dry run before
`make sync`.
EOF
}

# folders_check_filter FILTER [EXIST] - validate a filter file name; when
# EXIST is 1 the file must already exist in FILTER_DIR. Pending filters are
# validated before they are written, so a bad pair cannot leave an orphan.
folders_check_filter() {
  local filter="$1" exist="${2:-0}"
  [[ -n "$filter" ]] || return 0
  safe_filter_name "$filter" || die "invalid filter file '${ printable "$filter";}'"
  [[ "$exist" -ne 1 || -f "${FILTER_DIR}/${filter}" ]] || die "missing filter file '${FILTER_DIR}/${filter}'"
}

# folders_check_pair MODE LOCAL SUB [FILTER] - validate a pair that is
# about to be added (mode, local path, remote path, duplicate name/remote,
# filter name); dies on the first problem.
folders_check_pair() {
  local mode="$1" local_path="$2" sub="$3" filter="${4:-}" name=""
  valid_entry_mode "$mode" || die "invalid mode '${mode}' (expected sync, pull, or bisync)"
  [[ -n "$local_path" ]] || die "local path for '${sub}' must not be empty"
  safe_remote_path "$sub" || die "unsafe remote subdir '${ printable "$sub";}'"
  name="$(entry_name_for "$sub")"
  manifest_has_name "$name" && die "a source named '${name}' already exists"
  manifest_has_remote "$sub" && die "remote folder '${sub}' is already configured"
  folders_check_filter "$filter"
}

# folders_check_remote SUB MODE - refuse a pair whose remote folder is
# missing before anything is written; sync may create it on the first run.
folders_check_remote() {
  local spec
  spec="$(remote_spec "$1")"
  if [[ "$2" == "sync" ]]; then
    remote_dir_exists "$spec" ||
      warn "remote folder '${spec}' does not exist yet; the first sync will create it"
  elif ! remote_dir_exists "$spec"; then
    die "remote folder '${spec}' not found; use sciebo folders choose to pick existing folders"
  fi
}

# folders_commit_pending [STYLE] - commit the pending P_* pairs. Every pair
# (and its remote) is validated before the first pair filter or manifest
# entry is written, so a bad pair can never leave a partial selection
# behind. The run lock is held across the writes (reentrant for callers
# that already hold it). STYLE "pair" (default) prints the wizard's
# `Added <mode> pair '<name>': <local> <-> <remote>` line; "import" prints
# `Added <mode> <name>: <local> -> <remote>`. Both end with the shared
# Next/First-run footer.
folders_commit_pending() {
  local style="${1:-pair}" i=0 filter="" ex="" added_bisync=0 remote_display=""
  local -a pair_excludes

  for ((i = 0; i < ${#P_SUBS[@]}; i++)); do
    filter=""
    [[ -z "${P_EXCLUDES[$i]}" ]] || filter="pair-${P_NAMES[$i]}.txt"
    folders_check_pair "${P_MODES[$i]}" "${P_LOCALS[$i]}" "${P_SUBS[$i]}" "$filter"
  done
  for ((i = 0; i < ${#P_SUBS[@]}; i++)); do
    folders_check_remote "${P_SUBS[$i]}" "${P_MODES[$i]}"
  done

  acquire_lock
  for ((i = 0; i < ${#P_SUBS[@]}; i++)); do
    filter=""
    pair_excludes=()
    while IFS= read -r ex; do
      [[ -n "$ex" ]] || continue
      pair_excludes[${#pair_excludes[@]}]="$ex"
    done <<<"${P_EXCLUDES[$i]}"
    if [[ "${#pair_excludes[@]}" -gt 0 ]]; then
      manifest_write_pair_filter "${P_NAMES[$i]}" "${P_SUBS[$i]}" "${pair_excludes[@]}"
      filter="$MANIFEST_PAIR_FILTER"
    fi
    manifest_append_pair "${P_MODES[$i]}" "${P_LOCALS[$i]}" "${P_SUBS[$i]}" "$filter"
    remote_display=${ remote_spec "${P_SUBS[$i]}";}
    remote_display=${ printable "$remote_display";}
    if [[ "$style" == "import" ]]; then
      printf 'Added %s %s: %s -> %s\n' \
        "${P_MODES[$i]}" "${P_NAMES[$i]}" "${P_LOCALS[$i]}" "$remote_display"
    else
      printf "Added %s pair '%s': %s <-> %s\n" \
        "${P_MODES[$i]}" "${P_NAMES[$i]}" "${P_LOCALS[$i]}" "$remote_display"
    fi
    [[ "${P_MODES[$i]}" != "bisync" ]] || added_bisync=1
  done

  printf 'Next: make check (dry run), then make sync\n'
  [[ "$added_bisync" -eq 0 ]] || printf 'First run: sciebo sync --resync --apply (or make bisync-resync)\n'
  release_lock
}

# choose_select_items PROMPT [FZF_PROMPT [NO_FZF]] - pick from
# CHOOSE_ITEMS: fzf when FZF_PROMPT is set, NO_FZF is 0, and fzf is
# available on a terminal, otherwise a numbered menu; stores the picks in
# CHOOSE_SELECTED. Returns 1 on an empty pick and 2 when reading the
# selection failed (ui_select_indices gives up on EOF; the caller's
# $(...) turns that into a nonzero status).
choose_select_items() {
  local prompt="$1" fzf_prompt="${2:-}" no_fzf="${3:-1}" sel="" item="" picked="" i=0
  # ui.sh is lazy; load it for ui_select_indices below (this helper is
  # defined in folders.sh but called from the folders_choose wizard too).
  sciebo_require_module ui ui_select_indices
  CHOOSE_SELECTED=()
  if [[ -n "$fzf_prompt" && "$no_fzf" -eq 0 ]] && have fzf && [[ -t 0 && -t 1 ]]; then
    if ! sel="$(printf '%s\n' "${CHOOSE_ITEMS[@]}" | fzf --multi --prompt "$fzf_prompt" 2>/dev/null)"; then
      return 1
    fi
    while IFS= read -r item; do
      [[ -n "$item" ]] || continue
      CHOOSE_SELECTED[${#CHOOSE_SELECTED[@]}]="$item"
    done <<<"$sel"
  else
    for ((i = 1; i <= ${#CHOOSE_ITEMS[@]}; i++)); do
      printf '  %2d) %s\n' "$i" "${ printable "${CHOOSE_ITEMS[i - 1]}";}"
    done
    picked="$(ui_select_indices "${#CHOOSE_ITEMS[@]}" "$prompt")" || return 2
    while IFS= read -r item; do
      [[ -n "$item" ]] || continue
      CHOOSE_SELECTED[${#CHOOSE_SELECTED[@]}]="${CHOOSE_ITEMS[$((item - 1))]}"
    done <<<"$picked"
  fi
  [[ "${#CHOOSE_SELECTED[@]}" -gt 0 ]]
}

# choose_preview_pairs - print the "Pairs to add:" table.
choose_preview_pairs() {
  local i=0 filter="" remote_display=""
  printf 'Pairs to add:\n'
  for ((i = 0; i < ${#P_SUBS[@]}; i++)); do
    filter=""
    [[ -z "${P_EXCLUDES[$i]}" ]] || filter=" [filter: pair-${P_NAMES[$i]}.txt]"
    remote_display=${ remote_spec "${P_SUBS[$i]}";}
    remote_display=${ printable "$remote_display";}
    printf '  %-6s %-24s %s <-> %s%s\n' \
      "${P_MODES[$i]}" "${P_NAMES[$i]}" "${P_LOCALS[$i]}" "$remote_display" "$filter"
  done
}

# folders_excludes_for CHILDREN INCLUDED - print every newline-separated line
# of CHILDREN that is not in the newline-separated INCLUDED list. Used to turn
# an include selection into the complement the pair filter stores.
folders_excludes_for() {
  local children="$1" included="$2" child="" wanted=$'\n' excludes=""
  while IFS= read -r child; do
    [[ -n "$child" ]] || continue
    wanted="${wanted}${child}"$'\n'
  done <<<"$included"
  while IFS= read -r child; do
    [[ -n "$child" ]] || continue
    [[ "$wanted" == *$'\n'"$child"$'\n'* ]] && continue
    excludes="${excludes}${child}"$'\n'
  done <<<"$children"
  printf '%s' "$excludes"
}

# folders_include_excludes REMOTE INCLUDES - set FOLDERS_INCLUDE_EXCLUDES
# to every immediate child of REMOTE that is not named in the
# newline-separated INCLUDES (empty when everything is included). Dies when
# the remote folder is missing or an include is not an immediate child.
folders_include_excludes() {
  local remote="$1" includes="$2" spec="" raw="" inc="" children=$'\n' available="" sep="" wanted=$'\n'
  while IFS= read -r inc; do
    inc=${ strip_trailing_slashes "$inc";}
    [[ -n "$inc" ]] || continue
    safe_remote_path "$inc" || die "invalid include '${ printable "$inc";}': must be relative and without '..'"
    wanted="${wanted}${inc}"$'\n'
  done <<<"$includes"
  spec="$(remote_spec "$remote")"
  remote_dir_exists "$spec" ||
    die "cannot choose subfolders: remote folder '${spec}' does not exist yet"
  while IFS= read -r raw; do
    raw=${ strip_trailing_slashes "$raw";}
    [[ -n "$raw" ]] || continue
    children="${children}${raw}"$'\n'
    available="${available}${sep}${raw}"
    sep=", "
  done <<<"$(rclone_cmd lsf "$spec" --dirs-only --max-depth 1 2>/dev/null | LC_ALL=C sort || true)"
  [[ -n "$available" ]] || available="(none)"
  while IFS= read -r inc; do
    inc=${ strip_trailing_slashes "$inc";}
    [[ -n "$inc" ]] || continue
    [[ "$children" == *$'\n'"$inc"$'\n'* ]] ||
      die "unknown subfolder '${ printable "$inc";}' under '${ printable "$remote";}'; available: ${available}"
  done <<<"$includes"
  FOLDERS_INCLUDE_EXCLUDES="$(folders_excludes_for "$children" "$wanted")"
}

folders_cmd_add() {
  local remote="" mode="" local_root="" local_path="" name="" excludes="" rc=0
  opt_begin "remote:s local:s mode:s exclude:S local-root:s select:b include:S" folders "add: " "$@"
  opt_guard folders "add: "
  [[ -n "${OPT_remote:-}" ]] || usage_error folders "add: --remote is required"
  if [[ -n "${OPT_include:-}" && "${OPT_select:-0}" -ne 0 ]]; then
    usage_error folders "add: --include and --select are mutually exclusive"
  fi

  load_settings
  mode="${OPT_mode:-$DEFAULT_PAIR_MODE}"
  valid_entry_mode "$mode" || die "invalid mode '${mode}' (expected sync, pull, or bisync)"
  remote=${ strip_trailing_slashes "$OPT_remote";}
  local_root=${ strip_trailing_slashes "$(expand_local_path "${OPT_local_root:-$FOLDERS_LOCAL_ROOT}")";}
  local_path="$(expand_local_path "${OPT_local:-${local_root}/${remote}}")"
  name="$(entry_name_for "$remote")"

  ensure_state_dirs
  require_remote
  excludes="${OPT_exclude:-}"
  if [[ -n "${OPT_include:-}" ]]; then
    folders_include_excludes "$remote" "${OPT_include}"
    excludes="$FOLDERS_INCLUDE_EXCLUDES"
  elif [[ "${OPT_select:-0}" -ne 0 ]]; then
    # shellcheck disable=SC2034  # read by folders_choose.sh's gather_pair
    CHOOSE_SELECT_MODE=1
    choose_include_excludes "$remote" || rc=$?
    [[ "$rc" -ne 2 ]] || die "input ended; nothing changed"
    excludes="$CHOOSE_EXCLUDES"
  fi
  P_MODES=("$mode")
  P_LOCALS=("$local_path")
  P_SUBS=("$remote")
  P_NAMES=("$name")
  P_EXCLUDES=("$excludes")
  acquire_lock
  folders_commit_pending
  release_lock
}

# folders_import_read FILE - set FOLDERS_IMPORT_PATHS to the normalized
# paths of FILE (the nextcloudcmd --unsyncedfolders format): surrounding
# whitespace trimmed, blank lines and #-comments ignored, trailing slashes
# stripped. A path that is empty, absolute, or contains "..", "|", or
# control bytes is a usage error.
folders_import_read() {
  local file="$1" line="" path=""
  FOLDERS_IMPORT_PATHS=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${ trim "$line";}
    [[ -n "$line" ]] || continue
    case "$line" in \#*) continue ;; esac
    path=${ strip_trailing_slashes "$line";}
    if [[ -z "$path" ]] || ! safe_remote_path "$path"; then
      usage_error folders "import: invalid folder path '${ printable "$line";}'"
    fi
    FOLDERS_IMPORT_PATHS="${FOLDERS_IMPORT_PATHS}${path}"$'\n'
  done <"$file"
}

# folders_import_select SUB INCLUDES - set FOLDERS_IMPORT_SELECT to every
# immediate child of SUB that is not named in the newline-separated
# INCLUDES (empty when everything is listed). Dies with rclone's message
# when the listing fails.
folders_import_select() {
  local sub="$1" includes="$2" spec="" listing="" raw="" children=""
  spec="$(remote_spec "$sub")"
  if ! listing="$(rclone_cmd lsf "$spec" --dirs-only --max-depth 1 2>&1)"; then
    die "cannot list remote folder '${spec}': ${listing}"
  fi
  while IFS= read -r raw; do
    raw=${ strip_trailing_slashes "$raw";}
    [[ -n "$raw" ]] || continue
    children="${children}${raw}"$'\n'
  done <<<"$(printf '%s\n' "$listing" | LC_ALL=C sort)"
  FOLDERS_IMPORT_SELECT="$(folders_excludes_for "$children" "$includes")"
}

folders_cmd_import() {
  local file="" remote="" mode="" local_root="" local_path="" name="" excludes=""
  opt_begin "remote:s local:s mode:s local-root:s select:b" folders "import: " "$@"
  split_positionals "${OPT_EXTRA:-}"
  file="${POSITIONAL_ARGS[0]:-}"
  [[ -n "$file" ]] || usage_error folders "import: FILE is required"
  [[ "${#POSITIONAL_ARGS[@]}" -le 1 ]] ||
    usage_error folders "import: unexpected extra argument: ${POSITIONAL_ARGS[1]}"
  [[ -n "${OPT_remote:-}" ]] || usage_error folders "import: --remote is required"
  [[ -f "$file" ]] || die "cannot read list file '${ printable "$file";}'"

  load_settings
  mode="${OPT_mode:-$DEFAULT_PAIR_MODE}"
  valid_entry_mode "$mode" || die "invalid mode '${mode}' (expected sync, pull, or bisync)"
  remote=${ strip_trailing_slashes "$OPT_remote";}
  local_root=${ strip_trailing_slashes "$(expand_local_path "${OPT_local_root:-$FOLDERS_LOCAL_ROOT}")";}
  local_path="$(expand_local_path "${OPT_local:-${local_root}/${remote}}")"
  name="$(entry_name_for "$remote")"

  ensure_state_dirs
  require_remote
  folders_import_read "$file"
  excludes="$FOLDERS_IMPORT_PATHS"
  if [[ "${OPT_select:-0}" -ne 0 ]]; then
    folders_import_select "$remote" "$FOLDERS_IMPORT_PATHS"
    excludes="$FOLDERS_IMPORT_SELECT"
  fi
  P_MODES=("$mode")
  P_LOCALS=("$local_path")
  P_SUBS=("$remote")
  P_NAMES=("$name")
  P_EXCLUDES=("$excludes")
  acquire_lock
  folders_commit_pending import
  release_lock
}

# folders_edit_find NAME - set FOLDERS_EDIT_LINE and the ENTRY_* globals to
# the wizard-managed pair named NAME. Dies when NAME is unknown or belongs
# to another manifest file.
folders_edit_find() {
  local want="$1" line="" file=""
  if [[ -f "$FOLDERS_FILE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      manifest_parse_line "$line" || continue
      if [[ "$ENTRY_NAME" == "$want" ]]; then
        FOLDERS_EDIT_LINE="$line"
        return 0
      fi
    done <"$FOLDERS_FILE"
  fi
  for file in "$MANIFEST_FILE" "$MANIFEST_GENERATED_FILE"; do
    [[ -f "$file" ]] || continue
    while IFS= read -r line || [[ -n "$line" ]]; do
      manifest_parse_line "$line" || continue
      [[ "$ENTRY_NAME" == "$want" ]] || continue
      die "'${want}' is not a wizard-managed pair; edit ${file} instead"
    done <"$file"
  done
  die "no pair named '${want}' in ${FOLDERS_FILE}"
}

# folders_edit_merge_rules BASE EXTRAS - print the newline-separated BASE
# list plus the EXTRAS entries that are not already in it (order preserved).
folders_edit_merge_rules() {
  local base="$1" extras="$2" entry="" merged="$1" seen=$'\n'
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    seen="${seen}${entry}"$'\n'
  done <<<"$base"
  while IFS= read -r entry; do
    entry=${ strip_trailing_slashes "$entry";}
    [[ -n "$entry" ]] || continue
    [[ "$seen" == *$'\n'"${entry}"$'\n'* ]] && continue
    merged="${merged}${entry}"$'\n'
    seen="${seen}${entry}"$'\n'
  done <<<"$extras"
  printf '%s' "$merged"
}

# folders_edit_parse_args ARGS... - parse the edit options, validate NAME, and
# enforce the option-combination rules. Sets FOLDERS_EDIT_NAME.
folders_edit_parse_args() {
  local name="" includes="" excludes="" entry="" key="" kind="" var="" given=0
  opt_begin "local:s remote:s include:S exclude:S mode:s select:b clear:b force:b" folders "edit: " "$@"
  split_positionals "${OPT_EXTRA:-}"
  name="${POSITIONAL_ARGS[0]:-}"
  [[ -n "$name" ]] || usage_error folders "edit: NAME is required"
  [[ "${#POSITIONAL_ARGS[@]}" -le 1 ]] ||
    usage_error folders "edit: unexpected extra argument: ${POSITIONAL_ARGS[1]}"
  includes="${OPT_include:-}" excludes="${OPT_exclude:-}"
  # At-least-one rule: value options (include/exclude/mode) need a non-empty
  # value; the rest count through their _SET marker, as before.
  for entry in local:set remote:set include:val exclude:val mode:val select:set clear:set; do
    key="${entry%%:*}" kind="${entry#*:}"
    if [[ "$kind" == "set" ]]; then
      var="OPT_${key}_SET"
    else
      var="OPT_${key}"
    fi
    [[ -z "${!var:-}" ]] || given=1
  done
  [[ "$given" -eq 1 ]] ||
    usage_error folders "edit: at least one of --local, --remote, --include, --exclude, --mode, --select, or --clear is required"
  [[ -z "$includes" || "${OPT_select:-0}" -eq 0 ]] ||
    usage_error folders "edit: --include and --select are mutually exclusive"
  if [[ "${OPT_clear:-0}" -ne 0 ]]; then
    [[ -z "$includes" && -z "$excludes" && "${OPT_select:-0}" -eq 0 ]] ||
      usage_error folders "edit: --clear cannot be combined with filter options"
  fi
  [[ -z "${OPT_mode:-}" ]] || valid_entry_mode "${OPT_mode}" ||
    die "invalid mode '${OPT_mode}' (expected sync, pull, or bisync)"
  FOLDERS_EDIT_NAME="$name"
}

# folders_edit_normalize_remote SUB - normalize a --remote value the way
# provision does: leading and trailing slashes are stripped, and "/" or an
# empty value means the remote base, stored as "." (the manifest format
# cannot express an empty remote field, and rclone resolves "." to the base).
folders_edit_normalize_remote() {
  local sub="$1"
  while [[ "$sub" == */ && "$sub" != "/" ]]; do sub="${sub%/}"; done
  while [[ "$sub" == /* ]]; do sub="${sub#/}"; done
  [[ -n "$sub" ]] || sub="."
  printf '%s' "$sub"
}

# folders_edit_bisync_guard - the pair named FOLDERS_EDIT_NAME is changing
# its remote path. When initialized bisync state exists it no longer matches
# the new path: refuse unless --force, and even then only warn. The state is
# never deleted here; the next run must be a resync.
folders_edit_bisync_guard() {
  bisync_initialized "$FOLDERS_EDIT_NAME" || return 0
  if [[ -n "${OPT_force:-}" ]]; then
    warn "pair '${FOLDERS_EDIT_NAME}' has initialized bisync state that no longer matches the new remote path; re-initialize it with 'sciebo sync --resync' (or make bisync-resync) before syncing"
    return 0
  fi
  die "pair '${FOLDERS_EDIT_NAME}' has initialized bisync state that no longer matches the new remote path; re-run with --force to change it anyway (the state is kept; re-initialize with 'sciebo sync --resync')"
}

# folders_edit_resolve_local - set FOLDERS_EDIT_LOCAL/LOCAL_CHANGE from the
# resolved entry line and an optional --local override.
folders_edit_resolve_local() {
  local raw_local="" new_local=""
  raw_local=${ trim "${FOLDERS_EDIT_LINE#*|}";}
  raw_local=${ trim "${raw_local%%|*}";}
  FOLDERS_EDIT_LOCAL="$raw_local"
  FOLDERS_EDIT_LOCAL_CHANGE=0
  if [[ -n "${OPT_local_SET:-}" ]]; then
    [[ -n "${OPT_local:-}" ]] || die "local path must not be empty"
    new_local="$(expand_local_path "$OPT_local")"
    safe_local_path "$new_local" || die "invalid local path '${ printable "$OPT_local";}'"
    FOLDERS_EDIT_LOCAL="$new_local"
    FOLDERS_EDIT_LOCAL_CHANGE=1
  fi
  return 0
}

# folders_edit_resolve_remote - set FOLDERS_EDIT_REMOTE/REMOTE_CHANGE and
# FOLDERS_EDIT_NEW_NAME from the resolved entry and an optional --remote
# override. A change runs the duplicate name/remote checks and the
# initialized-bisync guard before anything is written.
folders_edit_resolve_remote() {
  local new_remote=""
  FOLDERS_EDIT_REMOTE="$ENTRY_REMOTE"
  FOLDERS_EDIT_REMOTE_CHANGE=0
  FOLDERS_EDIT_NEW_NAME="$FOLDERS_EDIT_NAME"
  if [[ -n "${OPT_remote_SET:-}" ]]; then
    new_remote="$(folders_edit_normalize_remote "$OPT_remote")"
    safe_remote_path "$new_remote" || die "unsafe remote subdir '${ printable "$OPT_remote";}'"
    FOLDERS_EDIT_REMOTE="$new_remote"
    FOLDERS_EDIT_NEW_NAME="$(entry_name_for "$new_remote")"
    [[ "$new_remote" == "$ENTRY_REMOTE" ]] || FOLDERS_EDIT_REMOTE_CHANGE=1
  fi
  if [[ "$FOLDERS_EDIT_REMOTE_CHANGE" -eq 1 ]]; then
    manifest_has_remote "$FOLDERS_EDIT_REMOTE" &&
      die "remote folder '${FOLDERS_EDIT_REMOTE}' is already configured"
    if [[ "$FOLDERS_EDIT_NEW_NAME" != "$FOLDERS_EDIT_NAME" ]]; then
      manifest_has_name "$FOLDERS_EDIT_NEW_NAME" &&
        die "a source named '${FOLDERS_EDIT_NEW_NAME}' already exists"
    fi
    folders_edit_bisync_guard
  fi
  return 0
}

# folders_edit_resolve_mode - set FOLDERS_EDIT_MODE/MODE_CHANGE from the
# resolved entry and an optional --mode override.
folders_edit_resolve_mode() {
  local mode="${ENTRY_MODE}"
  FOLDERS_EDIT_MODE_CHANGE=0
  if [[ -n "${OPT_mode:-}" ]]; then
    mode="${OPT_mode}"
    FOLDERS_EDIT_MODE_CHANGE=1
  fi
  FOLDERS_EDIT_MODE="$mode"
  return 0
}

# folders_edit_resolve - load the manifest, find the pair named
# FOLDERS_EDIT_NAME, and set FOLDERS_EDIT_LOCAL/LOCAL_CHANGE,
# FOLDERS_EDIT_REMOTE/REMOTE_CHANGE, FOLDERS_EDIT_NEW_NAME,
# FOLDERS_EDIT_MODE/MODE_CHANGE and FOLDERS_EDIT_FILTER from the current
# entry. A --remote change also runs the duplicate name/remote checks and the
# initialized-bisync guard before anything is written.
folders_edit_resolve() {
  load_settings
  manifest_index_load
  folders_edit_find "$FOLDERS_EDIT_NAME"
  folders_edit_resolve_local
  folders_edit_resolve_remote
  folders_edit_resolve_mode
  FOLDERS_EDIT_FILTER="${ENTRY_FILTER}"
}

# folders_edit_filter_clear - --clear drops the pair filter.
folders_edit_filter_clear() {
  FOLDERS_EDIT_FILTER_CHANGE=1
  return 0
}

# folders_edit_filter_include OUT INCLUDES EXCLUDES - build the new rules
# from --include (plus any --exclude) into OUT.
folders_edit_filter_include() {
  local -n _fefi_out="$1"
  local includes="$2" excludes="$3"
  ensure_state_dirs
  require_remote
  folders_include_excludes "$FOLDERS_EDIT_REMOTE" "$includes"
  _fefi_out="$FOLDERS_INCLUDE_EXCLUDES"
  [[ -z "$excludes" ]] || _fefi_out="$(folders_edit_merge_rules "$_fefi_out" "$excludes")"
  FOLDERS_EDIT_FILTER_CHANGE=1
  return 0
}

# folders_edit_filter_exclude OUT EXCLUDES - build the new rules from
# --exclude into OUT.
folders_edit_filter_exclude() {
  local -n _fefe_out="$1"
  _fefe_out="$2"
  FOLDERS_EDIT_FILTER_CHANGE=1
  return 0
}

# folders_edit_filter_select OUT - interactively pick the new rules into OUT;
# dies when the input ended before anything was picked.
folders_edit_filter_select() {
  local -n _fefs_out="$1"
  local rc=0
  ensure_state_dirs
  require_remote
  # shellcheck disable=SC2034  # read by folders_choose.sh's include flow
  CHOOSE_SELECT_MODE=1
  choose_include_excludes "$FOLDERS_EDIT_REMOTE" || rc=$?
  [[ "$rc" -ne 2 ]] || die "input ended; nothing changed"
  _fefs_out="$CHOOSE_EXCLUDES"
  FOLDERS_EDIT_FILTER_CHANGE=1
  return 0
}

# folders_edit_rules_array RULES - fill FOLDERS_EDIT_RULES_ARR from the
# newline-separated RULES, trimming trailing slashes and dropping blanks.
folders_edit_rules_array() {
  local rules="$1" rule=""
  FOLDERS_EDIT_RULES_ARR=()
  while IFS= read -r rule; do
    rule=${ strip_trailing_slashes "$rule";}
    [[ -n "$rule" ]] || continue
    FOLDERS_EDIT_RULES_ARR[${#FOLDERS_EDIT_RULES_ARR[@]}]="$rule"
  done <<<"$rules"
  return 0
}

# folders_edit_compute_filter - turn --clear/--include/--exclude/--select into
# the new pair filter. Sets FOLDERS_EDIT_FILTER_CHANGE, FOLDERS_EDIT_RULES_ARR
# (the rules as an array) and FOLDERS_EDIT_NEW_FILTER.
folders_edit_compute_filter() {
  local includes="${OPT_include:-}" excludes="${OPT_exclude:-}" rules="" new_filter=""
  FOLDERS_EDIT_RULES_ARR=()
  FOLDERS_EDIT_FILTER_CHANGE=0
  if [[ "${OPT_clear:-0}" -ne 0 ]]; then
    folders_edit_filter_clear
  elif [[ -n "$includes" ]]; then
    folders_edit_filter_include rules "$includes" "$excludes"
  elif [[ -n "$excludes" ]]; then
    folders_edit_filter_exclude rules "$excludes"
  elif [[ "${OPT_select:-0}" -ne 0 ]]; then
    folders_edit_filter_select rules
  fi
  if [[ "$FOLDERS_EDIT_FILTER_CHANGE" -eq 1 ]]; then
    folders_edit_rules_array "$rules"
    new_filter=""
    [[ "${#FOLDERS_EDIT_RULES_ARR[@]}" -eq 0 ]] || new_filter="pair-${FOLDERS_EDIT_NEW_NAME}.txt"
  else
    new_filter="$FOLDERS_EDIT_FILTER"
  fi
  FOLDERS_EDIT_NEW_FILTER="$new_filter"
}

# folders_edit_commit_apply - rewrite the manifest and pair filter for the
# edit; the caller holds the run lock. Returns 1 when the pair is already
# gone (nothing was written).
folders_edit_commit_apply() {
  manifest_remove_pair "$FOLDERS_EDIT_NAME" || return 1
  if [[ "$FOLDERS_EDIT_FILTER_CHANGE" -eq 1 ]]; then
    if [[ -n "$FOLDERS_EDIT_NEW_FILTER" ]]; then
      rm -f "${FILTER_DIR}/${FOLDERS_EDIT_NEW_FILTER}"
      manifest_write_pair_filter "$FOLDERS_EDIT_NEW_NAME" "$FOLDERS_EDIT_REMOTE" "${FOLDERS_EDIT_RULES_ARR[@]}"
    fi
    # Drop the old filter when it is removed or was renamed (the pair name
    # follows the remote subdir, so a --remote change renames the filter).
    if [[ -n "$FOLDERS_EDIT_FILTER" && "$FOLDERS_EDIT_FILTER" != "$FOLDERS_EDIT_NEW_FILTER" ]]; then
      rm -f "${FILTER_DIR}/${FOLDERS_EDIT_FILTER}"
    fi
  fi
  manifest_append_pair "$FOLDERS_EDIT_MODE" "$FOLDERS_EDIT_LOCAL" "$FOLDERS_EDIT_REMOTE" "$FOLDERS_EDIT_NEW_FILTER"
  return 0
}

# folders_edit_commit - hold the run lock across the rewrite: drop the old
# line, write or delete the pair filter, and append the new line.
folders_edit_commit() {
  acquire_lock
  if ! folders_edit_commit_apply; then
    release_lock
    die "no pair named '${FOLDERS_EDIT_NAME}' in ${FOLDERS_FILE}"
  fi
  release_lock
  return 0
}

folders_cmd_edit() {
  folders_edit_parse_args "$@"
  folders_edit_resolve
  folders_edit_compute_filter
  folders_edit_commit

  if [[ "$FOLDERS_EDIT_LOCAL_CHANGE" -eq 1 ]]; then
    printf 'updated pair %s (local %s)\n' "$FOLDERS_EDIT_NEW_NAME" "$FOLDERS_EDIT_LOCAL"
  fi
  if [[ "$FOLDERS_EDIT_REMOTE_CHANGE" -eq 1 ]]; then
    printf 'updated pair %s (remote %s)\n' "$FOLDERS_EDIT_NEW_NAME" "$(remote_spec "$FOLDERS_EDIT_REMOTE")"
  fi
  if [[ "$FOLDERS_EDIT_FILTER_CHANGE" -eq 1 ]]; then
    printf 'updated pair %s (filter %s)\n' "$FOLDERS_EDIT_NEW_NAME" "${FOLDERS_EDIT_NEW_FILTER:--}"
  fi
  if [[ "$FOLDERS_EDIT_MODE_CHANGE" -eq 1 ]]; then
    printf 'updated pair %s (mode %s)\n' "$FOLDERS_EDIT_NEW_NAME" "$FOLDERS_EDIT_MODE"
  fi
  return 0
}

# _folders_bisync_init_prime - fill FOLDERS_BISYNC_INIT with the sanitized
# entry name of every BISYNC_DIR workdir that holds at least one entry not
# ending in `-dry`, exactly like bisync_initialized_dir, but in a single find
# pass for the whole listing instead of one `ls -A` per bisync row.
_folders_bisync_init_prime() {
  FOLDERS_BISYNC_INIT=()
  local dir="${BISYNC_DIR:-}" path="" name=""
  [[ -n "$dir" && -d "$dir" ]] || return 0
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    name="${path%/*}"
    name="${name##*/}"
    [[ -n "$name" ]] || continue
    FOLDERS_BISYNC_INIT["$name"]=1
  done < <(find "$dir" -mindepth 2 -maxdepth 2 ! -name '*-dry' -print 2>/dev/null)
  return 0
}

# folders_cmd_list - table of all configured pairs, or the same rows as
# {"pairs":[...]} with --json. Read-only: it must not create state
# directories (load_settings --no-rclone only).
folders_cmd_list() {
  local json_mode=0
  opt_begin "json:b" folders "list: " "$@"
  opt_guard folders "list: "
  opt_json_mode
  output_json_enabled && json_mode=1
  load_settings --no-rclone
  FOLDERS_LIST_LOG_SNAPSHOT="$(ls -1t "$LOG_DIR" 2>/dev/null || true)"
  _folders_last_log_index_prime
  _folders_bisync_init_prime
  if [[ "$json_mode" -eq 1 ]]; then
    output_json_begin
    output_json_array_begin pairs
  else
    printf '%-24s %-7s %-32s %-36s %-10s %-20s %-18s %s %-7s %-6s\n' \
      "NAME" "MODE" "LOCAL" "REMOTE" "SOURCE" "FILTER" "BISYNC" "LASTLOG" "PAUSED" "HIDDEN"
  fi
  folders_list_print_file "$MANIFEST_FILE" "manual"
  folders_list_print_file "$FOLDERS_FILE" "wizard"
  folders_list_print_file "$MANIFEST_GENERATED_FILE" "discovered"
  if [[ "$json_mode" -eq 1 ]]; then
    output_json_array_end
    output_json_end
  fi
  return 0
}

# _folders_last_log_index_prime - index FOLDERS_LIST_LOG_SNAPSHOT (newest
# first) by every dash-delimited prefix of each `*.log` name: a query is
# "$name-"*.log, so NAME is always such a prefix. The first hit per prefix is
# the newest, so a later (older) file never overwrites it.
_folders_last_log_index_prime() {
  FOLDERS_LIST_LOG_INDEX=()
  local file="" stem="" prefix=""
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    case "$file" in
      *.log) ;;
      *) continue ;;
    esac
    stem="$file"
    prefix=""
    while [[ "$stem" == *-* ]]; do
      prefix="${prefix}${stem%%-*}"
      if [[ -n "$prefix" && -z "${FOLDERS_LIST_LOG_INDEX[$prefix]:-}" ]]; then
        FOLDERS_LIST_LOG_INDEX["$prefix"]="$file"
      fi
      stem="${stem#*-}"
      prefix="${prefix}-"
    done
  done <<<"$FOLDERS_LIST_LOG_SNAPSHOT"
  return 0
}

# folders_last_log_for_into VAR NAME - store the newest <name>-*.log in VAR,
# or "-", as an O(1) lookup into the index built once by
# _folders_last_log_index_prime. The snapshot is `ls -1t` (newest first), so
# the first hit stored per name is the newest one.
folders_last_log_for_into() {
  local __var="$1" name="$2"
  if [[ -n "$name" && -n "${FOLDERS_LIST_LOG_INDEX[$name]:-}" ]]; then
    printf -v "$__var" '%s' "${FOLDERS_LIST_LOG_INDEX[$name]}"
  else
    printf -v "$__var" '%s' '-'
  fi
  return 0
}

# folders_row_columns - derive the current ENTRY_* row's shared columns
# into the FOLDERS_ROW_* globals: the filter column (default "-"), the
# display remote path, the bisync initialization column
# (initialized/missing/-), the newest log name, and the paused/hidden text
# and JSON forms. Pure derivation from the primed indexes: no forks, no
# output, no emit decision (that is the emit functions' job).
folders_row_columns() {
  FOLDERS_ROW_FILTER="${ENTRY_FILTER:--}"
  FOLDERS_ROW_REMOTE=${ remote_spec "$ENTRY_REMOTE";}
  if [[ "$ENTRY_MODE" == "bisync" ]]; then
    if [[ -n "${FOLDERS_BISYNC_INIT["$ENTRY_NAME"]+x}" ]]; then
      FOLDERS_ROW_BISYNC="initialized"
    else
      FOLDERS_ROW_BISYNC="missing"
    fi
  else
    FOLDERS_ROW_BISYNC="-"
  fi
  folders_last_log_for_into FOLDERS_ROW_LASTLOG "$ENTRY_NAME"
  if manifest_pair_paused "$ENTRY_NAME"; then
    FOLDERS_ROW_PAUSED_COL="yes"
    FOLDERS_ROW_PAUSED_BOOL="true"
  else
    FOLDERS_ROW_PAUSED_COL="no"
    FOLDERS_ROW_PAUSED_BOOL="false"
  fi
  if manifest_pair_hidden "$ENTRY_NAME"; then
    FOLDERS_ROW_HIDDEN_COL="yes"
    FOLDERS_ROW_HIDDEN_BOOL="true"
  else
    FOLDERS_ROW_HIDDEN_COL="no"
    FOLDERS_ROW_HIDDEN_BOOL="false"
  fi
  return 0
}

# folders_emit_json_row SOURCE - the {"name":...} object for the parsed
# ENTRY_* row (columns from folders_row_columns) inside the pairs array.
folders_emit_json_row() {
  local source="$1"
  output_json_object_begin
  output_json_kv name "$ENTRY_NAME"
  output_json_kv mode "$ENTRY_MODE"
  output_json_kv local "$ENTRY_LOCAL"
  output_json_kv remote "$FOLDERS_ROW_REMOTE"
  output_json_kv source "$source"
  output_json_kv filter "$FOLDERS_ROW_FILTER"
  output_json_kv bisync "$FOLDERS_ROW_BISYNC"
  output_json_kv lastlog "$FOLDERS_ROW_LASTLOG"
  output_json_kv_bool paused "$FOLDERS_ROW_PAUSED_BOOL"
  output_json_kv_bool hidden "$FOLDERS_ROW_HIDDEN_BOOL"
  output_json_object_end
  return 0
}

# folders_emit_text_row SOURCE - the aligned table row for the parsed
# ENTRY_* row: the bisync column gains its "bisync=" prefix and the remote
# path is passed through printable, both on emit-local copies so the
# FOLDERS_ROW_* globals stay pristine for the JSON walk.
folders_emit_text_row() {
  local source="$1" bisync_col="$FOLDERS_ROW_BISYNC" remote_display=""
  [[ "$bisync_col" == "-" ]] || bisync_col="bisync=${bisync_col}"
  remote_display=${ printable "$FOLDERS_ROW_REMOTE";}
  printf '%-24s %-7s %-32s %-36s %-10s %-20s %-18s %s %-7s %-6s\n' \
    "$ENTRY_NAME" "$ENTRY_MODE" "$ENTRY_LOCAL" "$remote_display" \
    "$source" "$FOLDERS_ROW_FILTER" "$bisync_col" "$FOLDERS_ROW_LASTLOG" \
    "$FOLDERS_ROW_PAUSED_COL" "$FOLDERS_ROW_HIDDEN_COL"
  return 0
}

# folders_list_print_file FILE SOURCE - one row per entry, mirroring the
# sources.conf -> folders.conf -> generated order of manifest_lines: parse,
# derive the columns, emit (text or JSON). With --json the row is an object
# in the pairs array; invalid lines go to stderr like `list --json` in
# sync.sh.
folders_list_print_file() {
  local file="$1" source="$2" line=""
  [[ -f "$file" ]] || return 0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if manifest_parse_line "$line"; then
      folders_row_columns
      if output_json_enabled; then
        folders_emit_json_row "$source"
      else
        folders_emit_text_row "$source"
      fi
    elif output_json_enabled; then
      printf '%-24s %-7s %-32s %-36s %-10s %s\n' \
        "INVALID" "-" "-" "-" "-" "$ENTRY_ERROR" >&2
    else
      printf '%-24s %-7s %-32s %-36s %-10s %s\n' \
        "INVALID" "-" "-" "-" "-" "$ENTRY_ERROR"
    fi
  done < <(config_lines "$file")
}

# folders_cmd_pause NAME - set the pair's per-pair paused flag so sync/check
# skip it (recorded as skipped, not failed). NAME must be a configured source.
folders_cmd_pause() {
  local name="${1:-}" rest="${2:-}"
  [[ -n "$name" ]] || usage_error folders "pause requires a NAME"
  [[ -z "$rest" ]] || usage_error folders "pause: unexpected extra argument: ${rest}"
  load_settings --no-rclone
  manifest_require_name "$name"
  manifest_pair_flags_set "$name" paused 1 ||
    die "cannot write the pair flags for '${name}'"
  printf "Paused '%s'\n" "$name"
  return 0
}

# folders_cmd_resume NAME - clear the pair's per-pair paused flag.
folders_cmd_resume() {
  local name="${1:-}" rest="${2:-}"
  [[ -n "$name" ]] || usage_error folders "resume requires a NAME"
  [[ -z "$rest" ]] || usage_error folders "resume: unexpected extra argument: ${rest}"
  load_settings --no-rclone
  manifest_require_name "$name"
  manifest_pair_flags_set "$name" paused 0 ||
    die "cannot write the pair flags for '${name}'"
  printf "Resumed '%s'\n" "$name"
  return 0
}

# folders_purge_state NAME FILTER - remove NAME's per-source state after the
# manifest entry is gone: the bisync workdir, run record, history log,
# blacklist record, the pair filter named by FILTER (when the entry had one),
# the default pair filter, and the pair flags. Local data directories are
# never touched, and every removal is best effort.
folders_purge_state() {
  local name="$1" filter="${2:-}" flags_file=""
  rm -rf "${BISYNC_DIR}/${name:?}" 2>/dev/null || true
  rm -f "${RUNSTATE_DIR}/${name}" "${HISTORY_DIR}/${name}.log" \
    "${BLACKLIST_DIR}/${name}" 2>/dev/null || true
  [[ -z "$filter" ]] || rm -f "${FILTER_DIR}/${filter}" 2>/dev/null || true
  rm -f "${FILTER_DIR}/pair-${name}.txt" 2>/dev/null || true
  flags_file="$(manifest_pair_flags_file "$name" 2>/dev/null || true)"
  [[ -z "$flags_file" ]] || rm -f "$flags_file" 2>/dev/null || true
  return 0
}

# folders_cmd_remove NAME [--purge] - drop a wizard pair from folders.conf. With
# --purge the per-source state follows: the bisync workdir, run record,
# history log, blacklist record, pair filter, and pair flags. Local data
# directories are never touched.
folders_cmd_remove() {
  local name="" purge=0 filter="" line=""
  opt_begin "purge:b" folders "remove: " "$@"
  split_positionals "${OPT_EXTRA:-}"
  name="${POSITIONAL_ARGS[0]:-}"
  [[ -n "$name" ]] || usage_error folders "remove requires a NAME"
  [[ "${#POSITIONAL_ARGS[@]}" -le 1 ]] ||
    usage_error folders "remove: unexpected extra argument: ${POSITIONAL_ARGS[1]}"
  [[ -z "${OPT_purge:-}" ]] || purge=1
  load_settings --no-rclone
  if [[ "$purge" -eq 1 && -f "$FOLDERS_FILE" ]]; then
    while IFS= read -r line; do
      manifest_parse_line "$line" || continue
      if [[ "$ENTRY_NAME" == "$name" ]]; then
        filter="$ENTRY_FILTER"
        break
      fi
    done <"$FOLDERS_FILE"
  fi
  acquire_lock
  if ! manifest_remove_pair "$name"; then
    release_lock
    die "not found in ${FOLDERS_FILE}; manual entries must be edited in their own file"
  fi
  release_lock
  printf "Removed '%s' from %s\n" "$name" "$FOLDERS_FILE"
  if [[ "$purge" -eq 1 ]]; then
    folders_purge_state "$name" "$filter"
    printf "Purged state for '%s'\n" "$name"
    return 0
  fi
  if [[ -d "${BISYNC_DIR}/${name}" ]]; then
    printf 'Note: bisync state remains in %s; remove it if the pair is gone for good\n' "${BISYNC_DIR}/${name}"
  fi
  return 0
}

cmd_folders() {
  local sub="${1:-}"
  # Dispatcher-level help exits here, before any dependency loads, so
  # `sciebo folders --help` parses none of them.
  case "$sub" in
    -h | --help)
      usage_folders
      return 0
      ;;
  esac
  # Run dependencies for every subcommand (each handler's opt_* consumed
  # sub-level --help): choose (the default subcommand) lives in
  # folders_choose.sh and loads on demand here, the pair model walks the
  # manifest, and the commit helpers take the run lock (so the EXIT trap
  # can release it).
  sciebo_require_module commands/folders_choose cmd_choose
  sciebo_require_module manifest manifest_each
  sciebo_require_module lock acquire_lock
  case "$sub" in
    "") cmd_choose ;;
    choose) shift && cmd_choose "$@" ;;
    add) shift && folders_cmd_add "$@" ;;
    import) shift && folders_cmd_import "$@" ;;
    edit) shift && folders_cmd_edit "$@" ;;
    list) shift && folders_cmd_list "$@" ;;
    pause) shift && folders_cmd_pause "$@" ;;
    resume) shift && folders_cmd_resume "$@" ;;
    remove) shift && folders_cmd_remove "$@" ;;
    *) usage_error folders "unknown command: ${sub}" ;;
  esac
}
