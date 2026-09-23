#!/bin/bash
# logs.sh command module - list, show, and tail per-source sync logs.
#
# Read-only: logs never takes the run lock, writes state, or touches the
# network (load_settings --no-rclone only). Sources come from the manifest
# plus any per-source files in LOG_DIR; a log path recorded by the last run
# (runstate) is reused while the file still exists, otherwise the newest
# matching file in LOG_DIR is used. sync.sh writes `<name>-<stamp>.log` and
# `<name>-<stamp>-dryrun.log`, so a dry-run log is only used as a fallback.

# Trailing lines printed by show/tail (--lines overrides).
LOGS_LINES=50
# Newest-first `ls -1t` snapshot of LOG_DIR plus source names and per-name
# indexes, all built once per command: the raw snapshot feeds
# logs_index_log_files (which also collects LOGS_LOG_NAMES), the manifest walk
# collects LOGS_MANIFEST_NAMES and LOGS_MODE_BY_NAME, LOGS_*_INDEX maps a
# source name to its newest normal/dry-run log path, and LOGS_ALL_NAMES is the
# sorted unique union of the two name sets shared by list/path/known-name
# lookups. Re-deriving any of these per caller re-parsed the manifest and
# re-ran sort -u several times per command.
LOGS_LOG_SNAPSHOT=""
LOGS_MANIFEST_NAMES=""
LOGS_LOG_NAMES=""
LOGS_ALL_NAMES=""
# logs_name_from_file outputs: the derived source name and its log kind.
LOGS_NAME_FROM_FILE=""
LOGS_KIND_FROM_FILE=""
declare -A LOGS_MODE_BY_NAME=()
declare -A LOGS_NORMAL_INDEX=()
declare -A LOGS_DRYRUN_INDEX=()
# Result of logs_select: path to show/tail and whether it is a dry-run log.
LOGS_SELECTED_PATH=""
LOGS_SELECTED_DRYRUN=0
# Sanitized NAME resolved by logs_resolve_name for show/tail.
LOGS_CMD_NAME=""

usage_logs() {
  usage_emit <<'EOF'
Usage: sciebo logs [list]
       sciebo logs show NAME [--lines N]
       sciebo logs tail NAME [--lines N]
       sciebo logs path [NAME]

List, print, or follow the per-source sync logs in LOG_DIR. With no
subcommand, `logs` behaves like `logs list`. Sources come from the
manifest, the run records under state, and the per-source files in
LOG_DIR. Read-only.

Commands:
  list [--json]  table of sources, modes, log paths, sizes, modification
                 times, and last recorded status; with --json the same
                 rows as {"logs":[...]}
  show NAME      print the last --lines lines of NAME's log; when no
                 normal log exists, a dry-run log is used and a note is
                 printed to stderr
  tail NAME      like show, but follow the file with tail -f
  path [NAME]    print NAME's resolved log path as name<TAB>path;
                 without NAME, one line per known source

Options:
  --lines N   number of trailing lines to print (default 50; must be a
              positive integer)
  --json      list as {"logs":[...]}
  -h, --help  show this help
EOF
}

# logs_load_snapshot - cache LOG_DIR's file names newest-first, derive the
# manifest and LOG_DIR name sets, and build the per-name indexes once. A
# missing or unreadable directory leaves the snapshot and LOG_DIR-derived
# names empty; listing never fails.
logs_load_snapshot() {
  LOGS_LOG_SNAPSHOT=""
  LOGS_MANIFEST_NAMES=""
  LOGS_LOG_NAMES=""
  LOGS_ALL_NAMES=""
  LOGS_MODE_BY_NAME=()
  LOGS_NORMAL_INDEX=()
  LOGS_DRYRUN_INDEX=()
  logs_build_manifest_index
  if [[ -n "${LOG_DIR:-}" && -d "$LOG_DIR" ]]; then
    LOGS_LOG_SNAPSHOT="$(ls -1t "$LOG_DIR" 2>/dev/null || true)"
    logs_index_log_files
  fi
  logs_build_all_names
  return 0
}

# logs_each_entry - record one valid entry's name and (first) mode.
logs_each_entry() {
  LOGS_MANIFEST_NAMES="${LOGS_MANIFEST_NAMES}${ENTRY_NAME}"$'\n'
  [[ -n "${LOGS_MODE_BY_NAME[$ENTRY_NAME]+x}" ]] ||
    LOGS_MODE_BY_NAME["$ENTRY_NAME"]="$ENTRY_MODE"
  return 0
}

# logs_build_manifest_index - one manifest walk filling LOGS_MODE_BY_NAME and
# LOGS_MANIFEST_NAMES, so no caller re-parses the manifest for names or modes.
logs_build_manifest_index() {
  # manifest.sh is lazy; load it for the entry walk below.
  sciebo_require_module manifest manifest_each
  manifest_each logs_each_entry
  return 0
}

# logs_build_all_names - the sorted unique union of the manifest and LOG_DIR
# name sets, computed once per command. The LC_ALL=C sort -u of the
# concatenated newline sets is byte-for-byte the pipeline this replaced.
logs_build_all_names() {
  LOGS_ALL_NAMES="$(
    printf '%s%s' "$LOGS_MANIFEST_NAMES" "$LOGS_LOG_NAMES" | LC_ALL=C sort -u
  )"
  return 0
}

# logs_name_from_file FILE - derive the source name from a LOG_DIR file name
# (`<name>.log`, `<name>-<stamp>.log`, and their -dryrun variants all collapse
# to <name>) and set LOGS_NAME_FROM_FILE to it plus LOGS_KIND_FROM_FILE to
# normal/dryrun. Shared by logs_index_log_files so the stripping logic lives in
# exactly one place. The suffix after `<name>-` must be exactly a timestamp, so
# a source that is a prefix of another (`repo` vs `repo-b`) never collapses to
# the wrong name.
logs_name_from_file() {
  local base="${1%.log}"
  LOGS_KIND_FROM_FILE="normal"
  case "$base" in
    *-dryrun)
      base="${base%-dryrun}"
      LOGS_KIND_FROM_FILE="dryrun"
      ;;
  esac
  if [[ "$base" =~ ^(.*)-[0-9]{8}-[0-9]{6}$ ]]; then
    base="${BASH_REMATCH[1]}"
  fi
  LOGS_NAME_FROM_FILE="$base"
  return 0
}

# logs_index_log_files - one pass over LOGS_LOG_SNAPSHOT (newest-first)
# recording the first (newest) normal and dry-run path per source name and
# collecting every derived name for LOGS_ALL_NAMES. The name and kind come
# from logs_name_from_file; the `<name>.log` and `<name>-<stamp>.log` forms are
# normal, the `-dryrun` suffix (with or without a stamp) marks a dry-run log.
logs_index_log_files() {
  local file=""
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    case "$file" in
      *.log) ;;
      *) continue ;;
    esac
    logs_name_from_file "$file"
    [[ -n "$LOGS_NAME_FROM_FILE" ]] || continue
    LOGS_LOG_NAMES="${LOGS_LOG_NAMES}${LOGS_NAME_FROM_FILE}"$'\n'
    case "$LOGS_KIND_FROM_FILE" in
      normal)
        [[ -n "${LOGS_NORMAL_INDEX[$LOGS_NAME_FROM_FILE]+x}" ]] ||
          LOGS_NORMAL_INDEX["$LOGS_NAME_FROM_FILE"]="$LOG_DIR/$file"
        ;;
      dryrun)
        [[ -n "${LOGS_DRYRUN_INDEX[$LOGS_NAME_FROM_FILE]+x}" ]] ||
          LOGS_DRYRUN_INDEX["$LOGS_NAME_FROM_FILE"]="$LOG_DIR/$file"
        ;;
    esac
  done <<<"$LOGS_LOG_SNAPSHOT"
  return 0
}

# logs_find_log NAME KIND - print the newest LOG_DIR log for NAME from the
# index built by logs_load_snapshot: the sync pattern `<name>-<stamp>.log` or
# the plain `<name>.log` fallback (KIND normal), or *-dryrun.log (KIND
# dryrun). rc 1 when nothing matches.
logs_find_log() {
  local name="$1" kind="${2:-normal}" path=""
  case "$kind" in
    normal) path="${LOGS_NORMAL_INDEX[$name]:-}" ;;
    dryrun) path="${LOGS_DRYRUN_INDEX[$name]:-}" ;;
    *) return 1 ;;
  esac
  [[ -n "$path" ]] || return 1
  printf '%s\n' "$path"
}

# logs_has_name NAME - true when NAME (sanitized) is in the cached
# LOGS_ALL_NAMES set (a manifest entry or a name derived from LOG_DIR).
logs_has_name() {
  local name=""
  name="$(sanitize_name "${1:-}")"
  [[ -n "$name" ]] || return 1
  _manifest_membership "$name" "$LOGS_ALL_NAMES"
}

# logs_known_names - space-separated known source names for error messages.
# LOGS_ALL_NAMES has no trailing newline, so the pure-bash newline-to-space
# substitution matches the sort -u | tr pipeline byte for byte.
logs_known_names() {
  printf '%s' "${LOGS_ALL_NAMES//$'\n'/ }"
}

# logs_die_unknown NAME - die (rc 1) naming the known sources.
logs_die_unknown() {
  local name="$1" known=""
  known="$(logs_known_names)"
  if [[ -z "$known" ]]; then
    die "$(unknown_source_prefix "$name"); no sources configured"
  fi
  die "$(unknown_source_prefix "$name"); known: ${known}"
}

# logs_read_state NAME - fill RUNSTATE_STATUS, RUNSTATE_MODE, and
# RUNSTATE_LOG from NAME's record. rc 1 when runstate.sh is absent or NAME
# never ran; the runstate module is never required by logs.
logs_read_state() {
  RUNSTATE_STATUS="" RUNSTATE_MODE="" RUNSTATE_LOG=""
  # runstate.sh is lazy; load it before the probe so a recorded last run
  # is never silently dropped from the report.
  sciebo_require_module runstate runstate_read
  type runstate_read >/dev/null 2>&1 || return 1
  runstate_read "${1:-}" || return 1
  return 0
}

# logs_best_path NAME [RECORDED] - print the log path to report for NAME: the
# path recorded by the last run when that file still exists, else the newest
# normal log, else the newest dry-run log. RECORDED, when supplied, is an
# already parsed RUNSTATE_LOG value so callers that read the record for other
# columns do not read it again. rc 1 when NAME has no log.
logs_best_path() {
  local name="$1" recorded="${2:-}" path=""
  if [[ $# -lt 2 ]] && logs_read_state "$name"; then
    recorded="${RUNSTATE_LOG:-}"
  fi
  if [[ -n "$recorded" && "$recorded" != "-" && -f "$recorded" ]]; then
    printf '%s' "$recorded"
    return 0
  fi
  path=${ logs_find_log "$name" normal;} || path=""
  if [[ -z "$path" ]]; then
    path=${ logs_find_log "$name" dryrun;} || path=""
  fi
  [[ -n "$path" ]] || return 1
  printf '%s' "$path"
}

# logs_select NAME - resolve the file show/tail uses: the recorded normal
# log, the newest normal log, then the recorded or newest dry-run log. Sets
# LOGS_SELECTED_PATH and LOGS_SELECTED_DRYRUN (1 for a dry-run fallback);
# rc 1 when NAME has no log at all.
logs_select() {
  local name="$1" recorded="" normal="" dryrun=""
  LOGS_SELECTED_PATH=""
  LOGS_SELECTED_DRYRUN=0
  if logs_read_state "$name"; then
    recorded="${RUNSTATE_LOG:-}"
    [[ "$recorded" != "-" ]] || recorded=""
  fi
  if [[ -n "$recorded" && -f "$recorded" && "$recorded" != *-dryrun.log ]]; then
    normal="$recorded"
  else
    normal="$(logs_find_log "$name" normal || true)"
  fi
  if [[ -n "$recorded" && -f "$recorded" && "$recorded" == *-dryrun.log ]]; then
    dryrun="$recorded"
  else
    dryrun="$(logs_find_log "$name" dryrun || true)"
  fi
  if [[ -n "$normal" ]]; then
    LOGS_SELECTED_PATH="$normal"
    return 0
  fi
  if [[ -n "$dryrun" ]]; then
    LOGS_SELECTED_PATH="$dryrun"
    LOGS_SELECTED_DRYRUN=1
    return 0
  fi
  return 1
}

# logs_note_dryrun NAME - stderr note when the selection fell back to a
# dry-run log (show/tail never hide the fallback).
logs_note_dryrun() {
  [[ "$LOGS_SELECTED_DRYRUN" -eq 1 ]] || return 0
  printf "note: no normal log for '%s'; using dry-run log %s\n" \
    "$1" "$(printable "$LOGS_SELECTED_PATH")" >&2
  return 0
}

# logs_lines_from_opt SUB - apply --lines (default 50). A missing value keeps
# the default; an empty, zero, or non-numeric value is a usage error. The
# message carries the subcommand prefix and the offending value, so it goes
# through opt_require_uint's MSG override.
logs_lines_from_opt() {
  local sub="$1"
  LOGS_LINES=50
  [[ -n "${OPT_lines_SET:-}" ]] || return 0
  opt_require_uint logs --lines "${OPT_lines:-}" 1 "" \
    "${sub}: --lines must be a positive integer (got '${OPT_lines:-}')"
  LOGS_LINES=$((10#$OPT_lines))
  return 0
}

# logs_require_name NAME RAW - die with the known names when the sanitized
# NAME is not tracked; RAW is the user's spelling for the message.
logs_require_name() {
  local name="$1" raw="$2"
  [[ -n "$name" ]] && logs_has_name "$name" && return 0
  logs_die_unknown "$raw"
}

# logs_render_row NAME MODE PATH SIZE MTIME STATUS_RAW - one table row, or one
# JSON object when --json is active; mirrors mounts_render_row. An empty
# STATUS_RAW renders as "never".
logs_render_row() {
  local name="$1" mode="$2" path="$3" size="$4" mtime="$5" status_raw="$6"
  local text_status="" p_path="" p_status=""
  if output_json_enabled; then
    output_json_object_begin
    output_json_kv "source" "$name"
    output_json_kv "mode" "$mode"
    output_json_kv "path" "$path"
    output_json_kv "size" "$size"
    output_json_kv "mtime" "$mtime"
    output_json_kv "status" "$status_raw"
    output_json_object_end
    return 0
  fi
  text_status="never"
  if [[ -n "$status_raw" ]]; then
    text_status="${status_raw^^}"
  fi
  p_path=${ printable "$path";}
  p_status=${ printable "$text_status";}
  printf '%-24s %-7s %-44s %-10s %-17s %s\n' \
    "$name" "$mode" "$p_path" "$size" "$mtime" "$p_status"
  return 0
}

# logs_row_fields NAME MODE_VAR PATH_VAR SIZE_VAR MTIME_VAR STATUS_VAR -
# compute one `logs list` row's six columns for NAME (mode from the
# manifest/run record, the best log path, its size and mtime, and the
# recorded status) into the out-params. Pure compute: emitting is
# logs_render_row's job, so the walk and the row rendering stay separate;
# callers pass out-var names this function does not declare as locals (a
# same-named local would win the nameref lookup).
# shellcheck disable=SC2034  # the out-params are assigned through the namerefs
logs_row_fields() {
  local name="$1" mode="" path="" size="" mtime="" stamp="" epoch=""
  local status_raw="" recorded_log="" recorded_mode=""
  local -n out_mode="$2" out_path="$3" out_size="$4" out_mtime="$5" out_status="$6"
  if logs_read_state "$name"; then
    status_raw="${RUNSTATE_STATUS:-}"
    recorded_log="${RUNSTATE_LOG:-}"
    recorded_mode="${RUNSTATE_MODE:-}"
  fi
  if [[ -n "${LOGS_MODE_BY_NAME[$name]+x}" ]]; then
    mode="${LOGS_MODE_BY_NAME[$name]}"
  elif [[ -n "$recorded_mode" ]]; then
    mode="$recorded_mode"
  else
    mode="-"
  fi
  path=""
  path=${ logs_best_path "$name" "$recorded_log";} || path=""
  if [[ -n "$path" ]]; then
    stamp=${ file_stamp "$path";}
    epoch="${stamp%% *}"
    size="${stamp##* }"
    if [[ -z "$epoch" || "$epoch" == *[!0-9]* ]]; then
      mtime="-"
    else
      mtime=${ epoch_to_stamp "$epoch";}
    fi
    if [[ -z "$size" || "$size" == *[!0-9]* ]]; then
      size="-"
    else
      size=${ format_size_bytes "$size";}
    fi
  else
    path="-"
    size="-"
    mtime="-"
  fi
  out_mode="$mode"
  out_path="$path"
  out_size="$size"
  out_mtime="$mtime"
  out_status="$status_raw"
  return 0
}

# logs_row NAME - compute NAME's columns through logs_row_fields and render
# them through logs_render_row (text or JSON, like mounts_render_row).
# Non-zero for an empty NAME so output_rows skips the record. The r_*
# out-var names never collide with logs_row_fields' own locals, so the
# namerefs bind here (a callee local with the same name would win).
logs_row() {
  local name="$1" r_mode="" r_path="" r_size="" r_mtime="" r_status=""
  [[ -n "$name" ]] || return 1
  logs_row_fields "$name" r_mode r_path r_size r_mtime r_status
  logs_render_row "$name" "$r_mode" "$r_path" "$r_size" "$r_mtime" "$r_status"
}

# logs_cmd_list - table of sources, or the same rows as {"logs":[...]} with
# --json. Sources without a log show "-" columns; an empty state prints
# 'no logs' (or an empty document) and no header. The text rows go through
# the shared output_rows renderer; the JSON document keeps its own walk,
# which has neither header nor empty hint. Read-only: it must not create
# state directories (load_settings --no-rclone only).
logs_cmd_list() {
  local name="" names=""
  LOGS_LINES=50
  opt_begin "json:b" logs "list: " "$@"
  opt_guard logs "list: "
  opt_json_mode
  load_settings --no-rclone
  logs_load_snapshot
  names="$LOGS_ALL_NAMES"
  if output_json_enabled; then
    output_json_begin
    output_json_array_begin "logs"
    while IFS= read -r name; do
      logs_row "$name" || continue
    done <<<"$names"
    output_json_array_end
    output_json_end
    return 0
  fi
  # The header appears only when there is at least one source; the empty
  # hint alone is the whole output of an empty state.
  if [[ -n "$names" ]]; then
    printf '%-24s %-7s %-44s %-10s %-17s %s\n' \
      "NAME" "MODE" "PATH" "SIZE" "MTIME" "STATUS"
  fi
  output_rows "no logs" logs_row 0 "" <<<"$names"
  return 0
}

# logs_show_file NAME - select, announce a dry-run fallback on stderr, and
# print the last LOGS_LINES lines.
logs_show_file() {
  local name="$1"
  logs_select "$name" || die "no log for '${name}' yet in ${LOG_DIR}"
  logs_note_dryrun "$name"
  local out=""
  if ! out="$(tail -n "$LOGS_LINES" "$LOGS_SELECTED_PATH")"; then
    die "cannot read log '$(printable "$LOGS_SELECTED_PATH")'"
  fi
  printf '%s\n' "$out" | sanitize_stream
  return 0
}

# logs_resolve_name SUB - parse SUB's single NAME positional, apply --lines,
# load the snapshot, and resolve NAME against it. Sets LOGS_CMD_NAME to the
# sanitized name. Must not run in a command substitution: usage_error and die
# have to exit the process.
logs_resolve_name() {
  local sub="$1" name="" raw=""
  split_positionals "${OPT_EXTRA:-}"
  name="${POSITIONAL_ARGS[0]:-}"
  [[ "${#POSITIONAL_ARGS[@]}" -le 1 ]] ||
    usage_error logs "${sub}: unexpected extra argument: ${POSITIONAL_ARGS[1]}"
  [[ -n "$name" ]] || usage_error logs "${sub} requires a NAME"
  logs_lines_from_opt "$sub"
  load_settings --no-rclone
  logs_load_snapshot
  raw="$name"
  name="$(sanitize_name "$name")"
  logs_require_name "$name" "$raw"
  LOGS_CMD_NAME="$name"
  return 0
}

# logs_cmd_show - `logs show NAME [--lines N]`.
logs_cmd_show() {
  opt_begin "lines:s" logs "show: " "$@"
  logs_resolve_name show
  logs_show_file "$LOGS_CMD_NAME"
}

# logs_cmd_tail - `logs tail NAME [--lines N]`: show the last lines and
# then follow the file in the foreground (INT/TERM handled by bin/sciebo).
logs_cmd_tail() {
  local name=""
  opt_begin "lines:s" logs "tail: " "$@"
  logs_resolve_name tail
  name="$LOGS_CMD_NAME"
  logs_select "$name" || die "no log for '${name}' yet in ${LOG_DIR}"
  logs_note_dryrun "$name"
  if ! tail -n "$LOGS_LINES" -f "$LOGS_SELECTED_PATH"; then
    die "cannot follow log '$(printable "$LOGS_SELECTED_PATH")'"
  fi
  return 0
}

# logs_cmd_path - `logs path [NAME]`: one `name<TAB>path` line per source
# ("-" when no log exists), or for the one NAME given. Text-only by design.
logs_cmd_path() {
  local name="" raw="" path="" names=""
  opt_begin "" logs "path: " "$@"
  split_positionals "${OPT_EXTRA:-}"
  name="${POSITIONAL_ARGS[0]:-}"
  [[ "${#POSITIONAL_ARGS[@]}" -le 1 ]] ||
    usage_error logs "path: unexpected extra argument: ${POSITIONAL_ARGS[1]}"
  load_settings --no-rclone
  logs_load_snapshot
  if [[ -n "$name" ]]; then
    raw="$name"
    name="$(sanitize_name "$name")"
    logs_require_name "$name" "$raw"
    path=${ logs_best_path "$name";} || path=""
    printf '%s\t%s\n' "$name" "${path:--}"
    return 0
  fi
  names="$LOGS_ALL_NAMES"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    path=${ logs_best_path "$name";} || path=""
    printf '%s\t%s\n' "$name" "${path:--}"
  done <<<"$names"
  return 0
}

cmd_logs() {
  local sub="${1:-}"
  case "$sub" in
    "") logs_cmd_list ;;
    list) shift && logs_cmd_list "$@" ;;
    show) shift && logs_cmd_show "$@" ;;
    tail) shift && logs_cmd_tail "$@" ;;
    path) shift && logs_cmd_path "$@" ;;
    -h | --help) usage_logs && exit 0 ;;
    -*) logs_cmd_list "$@" ;;
    *) usage_error logs "unknown command: ${sub}" ;;
  esac
}
