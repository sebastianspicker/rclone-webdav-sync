#!/bin/bash
# tags.sh command module - list system tags and assign them to files. Talks
# to the DAV systemtags endpoint through lib/adapters/nc_api.sh; only `create` and
# `assign`/`clear` modify the server. Only die/usage_error exit.

TAGS_RECORD_ID=""
TAGS_RECORD_NAME=""
TAGS_RECORD_VISIBLE=""
TAGS_RECORD_ASSIGNABLE=""
TAGS_RECORD_FIELDS=(
  TAGS_RECORD_ID TAGS_RECORD_NAME TAGS_RECORD_VISIBLE TAGS_RECORD_ASSIGNABLE
)
# Filled by tags_parse_action: the validated subcommand and its arguments.
TAGS_ACTION="list"
TAGS_NAME=""
TAGS_SUB=""
TAGS_IDS=""

usage_tags() {
  usage_emit <<'EOF'
Usage: sciebo tags list [--json]
       sciebo tags create NAME
       sciebo tags assign SUB ID[,ID...]
       sciebo tags clear SUB

Manage Nextcloud system tags. `list` prints the id, display name, and the
user-visible/user-assignable flags. `assign` replaces the tags of SUB (a
remote path below <RCLONE_REMOTE>:<REMOTE_BASE>/) with a comma-separated id
list; `clear` removes all of them.

Subcommands:
  list                 list the system tags (default)
  create NAME          create a user-visible, user-assignable tag
  assign SUB IDS       replace the tags of SUB with IDS (e.g. 3,4)
  clear SUB            remove every tag from SUB

Options:
  --json      print the listing as JSON
  -h, --help  show this help
EOF
}

# tags_valid_ids IDS - true when IDS is a comma-separated list of one or
# more numeric tag ids; the value is inserted into an XML body, so anything
# else must be rejected. Thin delegate to the shared comma id validator.
tags_valid_ids() { comma_ids_valid "${1:-}"; }

# tags_parse_xml XML - print one TAB-separated record per tag: id,
# display-name, user-visible, user-assignable. Both the standard DAV
# <d:response> wrapper and an OCS-style <element> wrapper are accepted; the
# oc:-prefixed and plain property spellings are both read.
tags_parse_xml() {
  xml_records "$1" "$(xml_wrapper_auto "$1")" \
    'oc:id|id' 'oc:display-name|display-name' \
    'oc:user-visible|user-visible' 'oc:user-assignable|user-assignable'
}

# tags_print_row LINE - print one tag table row; non-zero when the record has
# no id.
tags_print_row() {
  local id="" name="" visible="" assignable=""
  record_split "$1" "${TAGS_RECORD_FIELDS[@]}"
  [[ -n "$TAGS_RECORD_ID" ]] || return 1
  id=${ printable "$TAGS_RECORD_ID";}
  name=${ printable "$TAGS_RECORD_NAME";}
  visible=${ printable "$TAGS_RECORD_VISIBLE";}
  assignable=${ printable "$TAGS_RECORD_ASSIGNABLE";}
  printf '%-8s %-28s %-8s %s\n' "$id" "$name" "$visible" "$assignable"
  return 0
}

# tags_print_rows XML - print the tag table or, with --json, an object with
# a "tags" array. Prints a hint when there are no tags.
tags_print_rows() {
  local xml="$1" line=""
  if output_json_enabled; then
    output_json_list_begin "tags"
    while IFS= read -r line; do
      record_split "$line" "${TAGS_RECORD_FIELDS[@]}"
      [[ -n "$TAGS_RECORD_ID" ]] || continue
      output_json_object_begin
      output_json_kv "id" "$TAGS_RECORD_ID"
      output_json_kv "display_name" "$TAGS_RECORD_NAME"
      output_json_kv "user_visible" "$TAGS_RECORD_VISIBLE"
      output_json_kv "user_assignable" "$TAGS_RECORD_ASSIGNABLE"
      output_json_object_end
    done < <(tags_parse_xml "$xml")
    output_json_list_end
    return 0
  fi
  output_rows "no tags" tags_print_row 0 \
    '%-8s %-28s %-8s %s\n' "ID" "Display name" "Visible" "Assignable" \
    < <(tags_parse_xml "$xml")
}

# tags_parse_action ARGS... - parse the options and positionals and validate
# the subcommand. Sets TAGS_ACTION (list|create|assign|clear) and, per action,
# TAGS_NAME/TAGS_SUB/TAGS_IDS; usage_error on the same inputs as before.
tags_parse_action() {
  local p1="" p2="" p3=""
  TAGS_ACTION=list
  TAGS_NAME=""
  TAGS_SUB=""
  TAGS_IDS=""
  opt_begin "json:b" tags "" "$@"
  split_positionals_into p1 p2 p3
  [[ "${#POSITIONAL_ARGS[@]}" -le 3 ]] ||
    usage_error tags "unexpected argument: $(printable "${POSITIONAL_ARGS[3]}")"
  case "$p1" in
    '' | list)
      TAGS_ACTION=list
      [[ -z "$p2" ]] || usage_error tags "unexpected argument: $(printable "$p2")"
      ;;
    create)
      TAGS_ACTION=create
      [[ -n "$p2" ]] || usage_error tags "create requires a tag name"
      [[ -z "$p3" ]] || usage_error tags "unexpected argument: $(printable "$p3")"
      opt_reject tags create json
      TAGS_NAME="$p2"
      ;;
    assign)
      TAGS_ACTION=assign
      [[ -n "$p2" ]] || usage_error tags "assign requires a remote path (SUB)"
      [[ -n "$p3" ]] || usage_error tags "assign requires one or more tag ids (e.g. 3,4)"
      opt_reject tags assign json
      TAGS_SUB="$p2"
      TAGS_IDS="$p3"
      require_safe_remote_path "$TAGS_SUB"
      tags_valid_ids "$TAGS_IDS" ||
        usage_error tags "invalid tag ids: $(printable "$TAGS_IDS") (use a comma-separated list of numbers)"
      ;;
    clear)
      TAGS_ACTION=clear
      [[ -n "$p2" ]] || usage_error tags "clear requires a remote path (SUB)"
      [[ -z "$p3" ]] || usage_error tags "unexpected argument: $(printable "$p3")"
      opt_reject tags clear json
      TAGS_SUB="$p2"
      require_safe_remote_path "$TAGS_SUB"
      ;;
    *)
      usage_unknown_sub tags "$p1"
      ;;
  esac
}

# tags_run_action - run the subcommand chosen by tags_parse_action: load the
# HTTP context and perform the list/create/assign/clear call, printing its
# result.
tags_run_action() {
  local id=""
  opt_json_mode
  http_load_context
  case "$TAGS_ACTION" in
    list)
      nc_tags_list
      tags_print_rows "$HTTP_BODY"
      ;;
    create)
      nc_tag_create "$TAGS_NAME"
      id="$(xml_get_any "$HTTP_BODY" 'oc:id' id)"
      if [[ -n "$id" ]]; then
        printf 'created tag %s\n' "$(printable "$id")"
      else
        printf 'created tag\n'
      fi
      ;;
    assign)
      nc_tag_assign "$TAGS_SUB" "$TAGS_IDS"
      printf 'tagged %s with %s\n' "$(printable "$TAGS_SUB")" "$(printable "$TAGS_IDS")"
      ;;
    clear)
      nc_tag_assign "$TAGS_SUB" ""
      printf 'cleared tags for %s\n' "$(printable "$TAGS_SUB")"
      ;;
  esac
  return 0
}

cmd_tags() {
  tags_parse_action "$@"
  tags_run_action
  return 0
}
