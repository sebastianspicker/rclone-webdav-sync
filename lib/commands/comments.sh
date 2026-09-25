#!/bin/bash
# comments.sh command module - list, add, and delete Nextcloud file
# comments. Resolves SUB to a file id and talks to the DAV comments endpoint
# through lib/adapters/nc_api.sh; deleting a comment is confirmed interactively (or
# requires --yes). Only die/usage_error exit.

COMMENTS_RECORD_ID=""
COMMENTS_RECORD_ACTOR=""
COMMENTS_RECORD_MESSAGE=""
COMMENTS_RECORD_CREATED=""
COMMENTS_RECORD_VERB=""
COMMENTS_RECORD_FIELDS=(
  COMMENTS_RECORD_ID COMMENTS_RECORD_ACTOR COMMENTS_RECORD_MESSAGE
  COMMENTS_RECORD_CREATED COMMENTS_RECORD_VERB
)
# Filled by comments_parse_action: the validated subcommand, its remote
# path, its argument (comment id for delete, message for add), and the
# resolved list limit.
COMMENTS_ACTION="list"
COMMENTS_SUB=""
COMMENTS_ARG=""
COMMENTS_ROW_LIMIT=50

usage_comments() {
  usage_emit <<'EOF'
Usage: sciebo comments SUB [list] [--json] [--limit N]
       sciebo comments SUB add MESSAGE
       sciebo comments SUB delete ID [--yes]

List, add, or delete comments on the remote path SUB below
<RCLONE_REMOTE>:<REMOTE_BASE>/ (Nextcloud comments app). `list` is the
default and prints the comment id, actor, creation time, verb, and message.

Subcommands:
  SUB [list]          list the comments of SUB (default)
  SUB add MESSAGE     post a new comment
  SUB delete ID       delete one comment (asks first; needs --yes when not
                      running interactively)

Options:
  --limit N   list at most N comments (default: COMMENTS_LIMIT, 50)
  --json      print the listing as JSON
  --yes       skip the delete confirmation
  -h, --help  show this help
EOF
}

# comments_parse_xml XML - print one TAB-separated record per comment:
# id, actorDisplayName, message, creationDateTime, verb. Both the standard
# DAV <d:response> wrapper and an OCS-style <element> wrapper are accepted;
# the oc:-prefixed and plain property spellings are both read.
comments_parse_xml() {
  xml_records "$1" "$(xml_wrapper_auto "$1")" \
    'oc:id|id' 'oc:actorDisplayName|actorDisplayName' 'oc:message|message' \
    'oc:creationDateTime|creationDateTime' 'oc:verb|verb'
}

# comments_print_row LINE - print one comment table row; non-zero when the
# record has no id.
comments_print_row() {
  local id="" actor="" created="" verb="" message=""
  record_split "$1" "${COMMENTS_RECORD_FIELDS[@]}"
  [[ -n "$COMMENTS_RECORD_ID" ]] || return 1
  id=${ printable "$COMMENTS_RECORD_ID";}
  actor=${ printable "$COMMENTS_RECORD_ACTOR";}
  created=${ printable "$COMMENTS_RECORD_CREATED";}
  verb=${ printable "$COMMENTS_RECORD_VERB";}
  message=${ printable "$COMMENTS_RECORD_MESSAGE";}
  printf '%-8s %-20s %-24s %-8s %s\n' "$id" "$actor" "$created" "$verb" "$message"
  return 0
}

# comments_print_rows XML LIMIT - print the comment table or, with --json, an
# object with a "comments" array, stopping after LIMIT rows (0 = no limit).
# Prints a hint when there are no comments.
comments_print_rows() {
  local xml="$1" limit="${2:-0}" line="" count=0
  if output_json_enabled; then
    output_json_list_begin "comments"
    while IFS= read -r line; do
      [[ "$limit" -eq 0 || "$count" -lt "$limit" ]] || break
      record_split "$line" "${COMMENTS_RECORD_FIELDS[@]}"
      [[ -n "$COMMENTS_RECORD_ID" ]] || continue
      output_json_object_begin
      output_json_kv "id" "$COMMENTS_RECORD_ID"
      output_json_kv "actor" "$COMMENTS_RECORD_ACTOR"
      output_json_kv "message" "$COMMENTS_RECORD_MESSAGE"
      output_json_kv "created" "$COMMENTS_RECORD_CREATED"
      output_json_kv "verb" "$COMMENTS_RECORD_VERB"
      output_json_object_end
      count=$((count + 1))
    done < <(comments_parse_xml "$xml")
    output_json_list_end
    return 0
  fi
  output_rows "no comments" comments_print_row "$limit" \
    '%-8s %-20s %-24s %-8s %s\n' "ID" "Actor" "Created" "Verb" "Message" \
    < <(comments_parse_xml "$xml")
}

# comments_confirm_delete ID - 0 when the deletion may proceed. --yes skips
# the prompt; a non-interactive run without it is a usage error. A "no"
# answer returns 1 so the caller can abort cleanly.
comments_confirm_delete() {
  ui_confirm_mutation comments \
    "delete requires --yes when not running interactively" \
    "Delete comment ${1}? [y/N]: "
}

# comments_parse_action ARGS... - parse the options and positionals and
# validate the subcommand, the per-action option rules, the --limit value,
# and the remote path. Sets COMMENTS_ACTION (list|add|delete),
# COMMENTS_SUB, COMMENTS_ARG, and COMMENTS_ROW_LIMIT; usage_error on the
# same inputs as before.
comments_parse_action() {
  local p1="" p2="" p3="" limit=""
  COMMENTS_ACTION=list
  COMMENTS_SUB=""
  COMMENTS_ARG=""
  opt_begin "json:b yes:b limit:s" comments "" "$@"
  split_positionals_into p1 p2 p3
  [[ -n "$p1" ]] || usage_error comments "a remote path argument is required"
  [[ "${#POSITIONAL_ARGS[@]}" -le 3 ]] ||
    usage_error comments "unexpected argument: ${ printable "${POSITIONAL_ARGS[3]}";}"
  case "$p2" in
    '' | list)
      COMMENTS_ACTION=list
      [[ -z "$p3" ]] || usage_error comments "unexpected argument: ${ printable "$p3";}"
      opt_reject comments list yes
      ;;
    add)
      COMMENTS_ACTION=add
      [[ -n "$p3" ]] || usage_error comments "add requires a message"
      opt_reject comments add json yes limit
      COMMENTS_ARG="$p3"
      ;;
    delete)
      COMMENTS_ACTION=delete
      [[ -n "$p3" ]] || usage_error comments "delete requires a comment id"
      opt_reject comments delete json limit
      numeric_id "$p3" ||
        usage_error comments "invalid comment id: ${ printable "$p3";}"
      COMMENTS_ARG="$p3"
      ;;
    *)
      usage_unknown_sub comments "$p2"
      ;;
  esac
  # The --limit value goes through opt_require_uint's MSG override: the message
  # interpolates the offending value (from --limit or the COMMENTS_LIMIT
  # setting) and ends with the "(use a non-negative integer)" hint. MIN=0, so
  # only non-digit values fail.
  limit="${OPT_limit:-${COMMENTS_LIMIT:-50}}"
  opt_require_uint comments --limit "$limit" 0 "" \
    "invalid --limit: ${ printable "${OPT_limit:-$limit}";} (use a non-negative integer)"
  COMMENTS_ROW_LIMIT=$((10#$limit))
  COMMENTS_SUB="$p1"
  require_safe_remote_path "$p1"
}

# cmd_comments - run the subcommand chosen by comments_parse_action: gate a
# delete on confirmation, resolve the file id, and perform the
# list/add/delete call, printing its result.
cmd_comments() {
  local fileid="" id=""
  comments_parse_action "$@"
  # Run dependencies load after the parse (its opt_begin consumed --help),
  # so `sciebo comments --help` parses none of them: the DAV calls use
  # http/nc_api, and the delete confirmation prompts through ui.
  opt_json_mode
  if [[ "$COMMENTS_ACTION" == "delete" ]]; then
    comments_confirm_delete "$COMMENTS_ARG" || return 0
  fi
  http_load_context
  fileid="$(nc_fileid "$COMMENTS_SUB")"
  case "$COMMENTS_ACTION" in
    list)
      nc_comments_list "$fileid"
      comments_print_rows "$HTTP_BODY" "$COMMENTS_ROW_LIMIT"
      ;;
    add)
      nc_comment_add "$fileid" "$COMMENTS_ARG"
      id="$(xml_get_any "$HTTP_BODY" 'oc:id' id)"
      if [[ -n "$id" ]]; then
        printf 'added comment %s\n' "${ printable "$id";}"
      else
        printf 'added comment\n'
      fi
      ;;
    delete)
      nc_comment_delete "$fileid" "$COMMENTS_ARG"
      printf 'deleted comment %s\n' "${ printable "$COMMENTS_ARG";}"
      ;;
  esac
  return 0
}
