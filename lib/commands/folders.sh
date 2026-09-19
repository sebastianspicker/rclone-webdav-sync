#!/bin/bash
# folders.sh command module - folder pairs (sciebo <-> local).
#
# `folders add` appends one pair; `folders choose` (folders_choose.sh)
# browses the remote and gathers pairs; both commit through
# folders_commit_pending. Only config/folders.conf and pair filter files
# under config/filters/ are written. The list subcommand is folders_cmd_list
# because cmd_list belongs to the top-level `sciebo list` in sync.sh.

# Pending pairs committed by folders_commit_pending; the wizard fills the
# same arrays (bash 3.2: no namerefs/assoc arrays).
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

usage_folders() {
  cat <<'EOF'
Usage: sciebo folders [command] [options]

Choose sciebo folders to pair with local directories, Nextcloud-client
style. With no command, `choose` runs. Only config/folders.conf and pair
filter files under config/filters/ are written; no data is transferred.

Commands:
  choose [options]        browse the remote and pick folders (default)
  add --remote SUB [options]
                          add a single pair without browsing
  list                    table of all configured pairs
  remove NAME             remove a wizard-managed pair from folders.conf
  -h, --help              show this help

choose options:
  --depth N               remote scan depth (default: FOLDERS_SCAN_DEPTH)
  --local-root DIR        local root for default destinations
                          (default: FOLDERS_LOCAL_ROOT)
  --mode MODE             fix the direction for all picks (sync|pull|bisync)
  --no-fzf                always use the numbered menu
  --no-dry-run            do not offer a dry run after adding pairs

add options:
  --remote SUB            remote subfolder below the remote base (required)
  --local PATH            local path (default: <local-root>/<SUB>)
  --mode MODE             direction (sync|pull|bisync; default: DEFAULT_PAIR_MODE)
  --exclude SUB           exclude SUB below the chosen folder (repeatable)
  --local-root DIR        local root for the default destination

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
  if [[ "$filter" == /* || "$filter" == */* || "$filter" == *..* ]]; then
    die "invalid filter file '$(printable "$filter")'"
  fi
  [[ "$exist" -ne 1 || -f "${FILTER_DIR}/${filter}" ]] || die "missing filter file '${FILTER_DIR}/${filter}'"
}

# folders_check_pair MODE LOCAL SUB [FILTER] - validate a pair that is
# about to be added (mode, local path, remote path, duplicate name/remote,
# filter name); dies on the first problem.
folders_check_pair() {
  local mode="$1" local_path="$2" sub="$3" filter="${4:-}" name=""
  valid_entry_mode "$mode" || die "invalid mode '${mode}' (expected sync, pull, or bisync)"
  [[ -n "$local_path" ]] || die "local path for '${sub}' must not be empty"
  safe_remote_path "$sub" || die "unsafe remote subdir '$(printable "$sub")'"
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

# folders_commit_pending - commit the pending P_* pairs. Every pair (and
# its remote) is validated before the first pair filter or manifest entry
# is written, so a bad pair can never leave a partial selection behind.
# Prints one Added line per pair plus the shared Next/First-run footer.
folders_commit_pending() {
  local i=0 filter="" ex="" added_bisync=0
  local -a pair_excludes

  for ((i = 0; i < ${#P_SUBS[@]}; i++)); do
    filter=""
    [[ -z "${P_EXCLUDES[$i]}" ]] || filter="pair-${P_NAMES[$i]}.txt"
    folders_check_pair "${P_MODES[$i]}" "${P_LOCALS[$i]}" "${P_SUBS[$i]}" "$filter"
  done
  for ((i = 0; i < ${#P_SUBS[@]}; i++)); do
    folders_check_remote "${P_SUBS[$i]}" "${P_MODES[$i]}"
  done

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
    printf "Added %s pair '%s': %s <-> %s\n" \
      "${P_MODES[$i]}" "${P_NAMES[$i]}" "${P_LOCALS[$i]}" "$(printable "$(remote_spec "${P_SUBS[$i]}")")"
    [[ "${P_MODES[$i]}" != "bisync" ]] || added_bisync=1
  done

  printf 'Next: make check (dry run), then make sync\n'
  [[ "$added_bisync" -eq 0 ]] || printf 'First run: sciebo sync --resync --apply (or make bisync-resync)\n'
}

# choose_select_items PROMPT [FZF_PROMPT [NO_FZF]] - pick from
# CHOOSE_ITEMS: fzf when FZF_PROMPT is set, NO_FZF is 0, and fzf is
# available on a terminal, otherwise a numbered menu; stores the picks in
# CHOOSE_SELECTED. Returns 1 on an empty pick and 2 when reading the
# selection failed (ui_select_indices gives up on EOF; the caller's
# $(...) turns that into a nonzero status).
choose_select_items() {
  local prompt="$1" fzf_prompt="${2:-}" no_fzf="${3:-1}" sel="" item="" picked="" i=0
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
      printf '  %2d) %s\n' "$i" "$(printable "${CHOOSE_ITEMS[i - 1]}")"
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
  local i=0 filter=""
  printf 'Pairs to add:\n'
  for ((i = 0; i < ${#P_SUBS[@]}; i++)); do
    filter=""
    [[ -z "${P_EXCLUDES[$i]}" ]] || filter=" [filter: pair-${P_NAMES[$i]}.txt]"
    printf '  %-6s %-24s %s <-> %s%s\n' \
      "${P_MODES[$i]}" "${P_NAMES[$i]}" "${P_LOCALS[$i]}" \
      "$(printable "$(remote_spec "${P_SUBS[$i]}")")" "$filter"
  done
}

cmd_add() {
  local remote="" mode="" local_root="" local_path="" name=""
  opt_reset remote local mode exclude local_root
  opt_parse "remote:s local:s mode:s exclude:S local-root:s" folders "add: " "$@"
  if [[ "$OPT_HELP" -ne 0 ]]; then
    usage_folders
    return 0
  fi
  [[ -z "$OPT_EXTRA" ]] || usage_error folders "add: unknown option: ${OPT_EXTRA%%$'\n'*}"
  [[ -n "${OPT_remote:-}" ]] || usage_error folders "add: --remote is required"

  load_settings
  mode="${OPT_mode:-$DEFAULT_PAIR_MODE}"
  valid_entry_mode "$mode" || die "invalid mode '${mode}' (expected sync, pull, or bisync)"
  remote="$OPT_remote"
  while [[ "$remote" == */ ]]; do remote="${remote%/}"; done
  local_root="$(expand_local_path "${OPT_local_root:-$FOLDERS_LOCAL_ROOT}")"
  local_root="${local_root%/}"
  local_path="${OPT_local:-${local_root}/${remote}}"
  local_path="$(expand_local_path "$local_path")"
  name="$(entry_name_for "$remote")"

  require_remote
  P_MODES=("$mode")
  P_LOCALS=("$local_path")
  P_SUBS=("$remote")
  P_NAMES=("$name")
  P_EXCLUDES=("${OPT_exclude:-}")
  folders_commit_pending
}

# folders_cmd_list - table of all configured pairs. Read-only: it must not
# create state directories (load_settings --no-rclone only).
folders_cmd_list() {
  if [[ $# -gt 0 ]]; then
    case "$1" in
      -h | --help) usage_folders && return 0 ;;
      *) usage_error folders "list: unknown option: $1" ;;
    esac
  fi
  load_settings --no-rclone
  FOLDERS_LIST_LOG_SNAPSHOT="$(ls -1t "$LOG_DIR" 2>/dev/null || true)"
  printf '%-24s %-7s %-32s %-36s %-10s %-20s %-18s %s\n' \
    "NAME" "MODE" "LOCAL" "REMOTE" "SOURCE" "FILTER" "BISYNC" "LASTLOG"
  folders_list_print_file "$MANIFEST_FILE" "manual"
  folders_list_print_file "$FOLDERS_FILE" "wizard"
  folders_list_print_file "$MANIFEST_GENERATED_FILE" "discovered"
  return 0
}

# folders_last_log_for NAME - newest <name>-*.log, or "-". The snapshot is
# `ls -1t` (newest first), so the first match is the newest one.
folders_last_log_for() {
  local name="$1" file=""
  while IFS= read -r file; do
    case "$file" in
      "$name-"*.log) printf '%s' "$file" && return 0 ;;
    esac
  done <<<"$FOLDERS_LIST_LOG_SNAPSHOT"
  printf -- '-'
}

# folders_list_print_file FILE SOURCE - one table row per entry, mirroring
# the sources.conf -> folders.conf -> generated order of manifest_lines.
folders_list_print_file() {
  local file="$1" source="$2" line="" filter_col="" bisync_col="" lastlog=""
  [[ -f "$file" ]] || return 0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if manifest_parse_line "$line"; then
      filter_col="${ENTRY_FILTER:--}"
      if [[ "$ENTRY_MODE" == "bisync" ]]; then
        bisync_col="$(bisync_initialized "$ENTRY_NAME" && printf 'bisync=initialized' || printf 'bisync=missing')"
      else
        bisync_col="-"
      fi
      lastlog="$(folders_last_log_for "$ENTRY_NAME")"
      printf '%-24s %-7s %-32s %-36s %-10s %-20s %-18s %s\n' \
        "$ENTRY_NAME" "$ENTRY_MODE" "$ENTRY_LOCAL" "$(printable "$(remote_spec "$ENTRY_REMOTE")")" \
        "$source" "$filter_col" "$bisync_col" "$lastlog"
    else
      printf '%-24s %-7s %-32s %-36s %-10s %s\n' \
        "INVALID" "-" "-" "-" "-" "$ENTRY_ERROR"
    fi
  done < <(config_lines "$file")
}

cmd_remove() {
  local name=""
  case "${1:-}" in
    -h | --help) usage_folders && return 0 ;;
  esac
  if [[ $# -ne 1 || -z "${1:-}" ]]; then
    usage_error folders "remove requires a NAME"
  fi
  name="$1"
  load_settings --no-rclone
  if ! manifest_remove_pair "$name"; then
    die "not found in ${FOLDERS_FILE}; manual entries must be edited in their own file"
  fi
  printf "Removed '%s' from %s\n" "$name" "$FOLDERS_FILE"
  if [[ -d "${BISYNC_DIR}/${name}" ]]; then
    printf 'Note: bisync state remains in %s; remove it if the pair is gone for good\n' "${BISYNC_DIR}/${name}"
  fi
  return 0
}

cmd_folders() {
  local sub="${1:-}"
  case "$sub" in
    "") cmd_choose ;;
    choose) shift && cmd_choose "$@" ;;
    add) shift && cmd_add "$@" ;;
    list) shift && folders_cmd_list "$@" ;;
    remove) shift && cmd_remove "$@" ;;
    -h | --help) usage_folders ;;
    *) usage_error folders "unknown command: ${sub}" ;;
  esac
}
