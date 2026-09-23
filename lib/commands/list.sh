#!/bin/bash
# list.sh command module - list the parsed sources (mode, name, paths, filter).
# Split out of sync.sh so `sciebo list` and `sciebo list --help` parse only
# this module: cmd_list needs the settings/output/rclone helpers that stay
# eager plus the manifest model, whose require lives in the entry function
# below (after opt_guard's --help exit), so it needs no file-top
# sciebo_require_module of its own.

usage_list() {
  usage_emit <<'EOF'
Usage: sciebo list [--json]

List the parsed sources with mode, name, local path, remote path, and
filter, including invalid entries with their error. --json prints the
valid entries as {"sources":[...]} with their origin (manual, folders,
or generated); invalid lines keep going to stderr.
EOF
}

# _cmd_list_emit_entry JSON_MODE SRC - print one row for the entry the
# parser just accepted into ENTRY_*: a JSON object appended to the open
# `sources` array when JSON_MODE is 1 (with SRC as its origin label:
# manual, folders, or generated), otherwise the aligned text row with the
# printable remote display and the optional filter suffix. Returns 0; a
# failed printf surfaces exactly as it did when this fork was inline.
_cmd_list_emit_entry() {
  local json_mode="$1" src="${2:-}"
  local remote_display="" spec="" filter_suffix=""
  remote_display=${ remote_spec "$ENTRY_REMOTE";}
  if [[ "$json_mode" -eq 1 ]]; then
    output_json_object_begin
    output_json_kv mode "$ENTRY_MODE"
    output_json_kv name "$ENTRY_NAME"
    output_json_kv local "$ENTRY_LOCAL"
    output_json_kv remote "$remote_display"
    output_json_kv filter "$ENTRY_FILTER"
    output_json_kv source "$src"
    output_json_object_end
  else
    spec=${ printable "$remote_display";}
    filter_suffix=""
    [[ -z "$ENTRY_FILTER" ]] || filter_suffix=" [filter: ${ENTRY_FILTER}]"
    printf '%-7s %-28s %s -> %s%s\n' "$ENTRY_MODE" "$ENTRY_NAME" "$ENTRY_LOCAL" "$spec" "$filter_suffix"
  fi
  return 0
}

# _cmd_list_emit_invalid JSON_MODE - print the INVALID row for the line
# manifest_parse_line rejected (its message sits in ENTRY_ERROR): to
# stderr in JSON mode, so the JSON document on stdout stays valid, and to
# stdout otherwise. Returns 0.
_cmd_list_emit_invalid() {
  local json_mode="$1"
  if [[ "$json_mode" -eq 1 ]]; then
    printf '%-7s %-28s %s\n' "INVALID" "-" "$ENTRY_ERROR" >&2
  else
    printf '%-7s %-28s %s\n' "INVALID" "-" "$ENTRY_ERROR"
  fi
  return 0
}

# shellcheck disable=SC2120  # `sync --list` calls cmd_list with no arguments after cmd_sync parsed its own options
cmd_list() {
  local json_mode=0 file="" src="" line="" count=0 content=""
  opt_begin "json:b" list "" "$@"
  opt_guard list
  # manifest.sh is lazy; load it after opt_guard's --help exit so
  # `sciebo list --help` parses none of it (cmd_sync's `--list` dispatch
  # reaches this require too, since it runs after its own opt_guard).
  sciebo_require_module manifest manifest_each
  output_mode_set "${OPT_json:-false}"
  output_json_enabled && json_mode=1
  load_settings --no-rclone
  if [[ "$json_mode" -eq 1 ]]; then
    output_json_begin
    output_json_array_begin sources
  fi
  while IFS= read -r file; do
    [[ -f "$file" ]] || continue
    case "$file" in
      "$MANIFEST_FILE") src="manual" ;;
      "$FOLDERS_FILE") src="folders" ;;
      "$MANIFEST_GENERATED_FILE") src="generated" ;;
      *) src="manual" ;;
    esac
    # config_lines only prints, so the forkless capture keeps its filtered
    # output in this shell (no process-substitution subshell per file) and
    # the here-string feeds the loop. An empty result is skipped so it never
    # turns into one spurious blank INVALID row.
    content=${ config_lines "$file";}
    [[ -n "$content" ]] || continue
    while IFS= read -r line; do
      if manifest_parse_line "$line"; then
        count=$((count + 1))
        _cmd_list_emit_entry "$json_mode" "$src"
      else
        _cmd_list_emit_invalid "$json_mode"
      fi
    done <<<"$content"
  done < <(manifest_files)
  if [[ "$json_mode" -eq 1 ]]; then
    output_json_array_end
    output_json_end
  elif [[ "$count" -eq 0 ]]; then
    printf 'No sources configured (edit config/sources.conf).\n'
  fi
  return 0
}
