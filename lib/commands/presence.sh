#!/bin/bash
# presence.sh command module - show, set, or clear the Nextcloud user status.
# Talks to the OCS user_status app through lib/adapters/http.sh; no local state.

# Filled by presence_parse_data from the <data> block of a status response.
PRESENCE_STATUS=""
PRESENCE_MESSAGE=""
PRESENCE_EMOJI=""
PRESENCE_CLEAR_AT=""

# Filled by presence_parse_action / presence_validate_options: the resolved
# action (show|set|clear), the set status type, and the set options.
PRESENCE_ACTION=""
PRESENCE_SET_STATUS=""
PRESENCE_OPT_MESSAGE=""
PRESENCE_OPT_EMOJI=""
PRESENCE_OPT_CLEAR_AFTER=""
PRESENCE_SECONDS=""

PRESENCE_STATUS_PATH='/apps/user_status/api/v1/user_status/status'
PRESENCE_MESSAGE_PATH='/apps/user_status/api/v1/user_status/message'
PRESENCE_CUSTOM_PATH='/apps/user_status/api/v1/user_status/message/custom'

usage_presence() {
  usage_emit <<'EOF'
Usage: sciebo presence [show]
       sciebo presence set online|away|dnd|offline [options]
       sciebo presence clear

Show (the default), set, or clear your Nextcloud user status. `show`
prints the status type, custom message, emoji, and when the message
expires.

Options (set):
  --message TEXT      publish a custom message
  --emoji EMOJI       publish a status emoji (statusIcon)
  --clear-after DUR   expire the message after <N>[smhd] (bare N means
                      minutes); `--clear-after 0` clears the message
  -h, --help          show this help
EOF
}

# presence_valid_status STATUS - true for the status types the API accepts.
presence_valid_status() {
  case "$1" in
    online | away | dnd | offline) return 0 ;;
  esac
  return 1
}

# presence_clear_label EPOCH - local 'YYYY-mm-dd HH:MM' for a clearAt epoch;
# empty for 0, non-numeric values pass through unchanged. Thin delegate to
# the shared shim.
presence_clear_label() {
  local epoch="$1"
  [[ "$epoch" != "0" ]] || return 0
  epoch_to_stamp_or_raw "$epoch"
}

# presence_parse_data XML - fill the PRESENCE_* globals from a <data> block;
# missing fields stay empty. The OCS <meta> status is parsed separately by
# ocs_parse, so this only ever sees the data element.
presence_parse_data() {
  local data="$1" fields=""
  fields="$(xml_fields "$data" status message statusIcon clearAt)"
  record_split "$fields" PRESENCE_STATUS PRESENCE_MESSAGE PRESENCE_EMOJI \
    PRESENCE_CLEAR_AT
  PRESENCE_STATUS=${ printable "$PRESENCE_STATUS";}
  PRESENCE_MESSAGE=${ printable "$PRESENCE_MESSAGE";}
  PRESENCE_EMOJI=${ printable "$PRESENCE_EMOJI";}
}

# presence_clear_message - DELETE the custom status message and print the
# confirmation. Dies on transport and OCS errors like every ocs_request.
presence_clear_message() {
  ocs_request DELETE "$PRESENCE_MESSAGE_PATH"
  printf 'message cleared\n'
}

# presence_parse_action ARGS... - parse the options and positionals and
# validate the subcommand. Sets PRESENCE_ACTION (show|set|clear) and, for set,
# PRESENCE_SET_STATUS. usage_error on the same inputs as before.
presence_parse_action() {
  local line1="" line2="" line3=""
  opt_begin "message:s emoji:s clear-after:s" presence "" "$@"

  split_positionals_into line1 line2 line3
  [[ "${#POSITIONAL_ARGS[@]}" -le 3 ]] ||
    usage_error presence "unexpected argument: $(printable "${POSITIONAL_ARGS[3]}")"

  case "$line1" in
    '') PRESENCE_ACTION=show ;;
    show)
      [[ -z "$line2" ]] || usage_error presence "unexpected argument: $(printable "$line2")"
      PRESENCE_ACTION=show
      ;;
    clear)
      [[ -z "$line2" ]] || usage_error presence "unexpected argument: $(printable "$line2")"
      PRESENCE_ACTION=clear
      ;;
    set)
      [[ -n "$line2" ]] || usage_error presence "set requires a status: online, away, dnd, or offline"
      [[ -z "$line3" ]] || usage_error presence "unexpected argument: $(printable "$line3")"
      presence_valid_status "$line2" ||
        usage_error presence "unknown status: $(printable "$line2") (use online, away, dnd, or offline)"
      PRESENCE_SET_STATUS="$line2"
      PRESENCE_ACTION='set'
      ;;
    *)
      usage_unknown_sub presence "$line1"
      ;;
  esac
}

# presence_validate_options - apply the set-only rules to --message, --emoji
# and --clear-after (parse the duration; require a message/emoji for a positive
# one) and reject the same options with show/clear. Sets
# PRESENCE_OPT_MESSAGE/PRESENCE_OPT_EMOJI/PRESENCE_OPT_CLEAR_AFTER and
# PRESENCE_SECONDS.
presence_validate_options() {
  PRESENCE_OPT_MESSAGE="${OPT_message:-}"
  PRESENCE_OPT_EMOJI="${OPT_emoji:-}"
  PRESENCE_OPT_CLEAR_AFTER="${OPT_clear_after:-}"
  PRESENCE_SECONDS=""
  if [[ "$PRESENCE_ACTION" == "set" ]]; then
    if [[ -n "$PRESENCE_OPT_CLEAR_AFTER" ]]; then
      # The shared duration_parse_or_usage (lib/base/duration.sh, eager) owns the
      # grammar and now the wording: its EXAMPLES argument carries presence's
      # "30m, 4h, 1d" list and its FLAG gives the "invalid --clear-after
      # duration: ..." spelling. The require also keeps sourced-alone use
      # working; it replaces the old lazy lib/state/pause.sh load that existed only
      # for pause_parse_duration's wrapper over the same grammar.
      PRESENCE_SECONDS=${ duration_parse_or_usage presence --clear-after "$PRESENCE_OPT_CLEAR_AFTER" invalid "30m, 4h, 1d";}
      if [[ "$PRESENCE_SECONDS" -gt 0 && -z "$PRESENCE_OPT_MESSAGE" && -z "$PRESENCE_OPT_EMOJI" ]]; then
        usage_error presence "--clear-after requires --message or --emoji"
      fi
    fi
  elif [[ -n "$PRESENCE_OPT_MESSAGE" || -n "$PRESENCE_OPT_EMOJI" || -n "$PRESENCE_OPT_CLEAR_AFTER" ]]; then
    usage_error presence "options are only valid with 'set'"
  fi
}

# presence_show - GET the status and print the four fields.
presence_show() {
  ocs_request GET /apps/user_status/api/v1/user_status
  presence_parse_data "$(xml_get "$HTTP_BODY" data)"
  printf 'Status: %s\n' "$PRESENCE_STATUS"
  printf 'Message: %s\n' "$PRESENCE_MESSAGE"
  printf 'Emoji: %s\n' "$PRESENCE_EMOJI"
  printf 'Clears: %s\n' "$(presence_clear_label "$PRESENCE_CLEAR_AT")"
}

# presence_set - PUT the status type and, when a message/emoji or a positive
# --clear-after was given, the custom message (clear-after 0 clears it).
presence_set() {
  local clear_at=""
  ocs_request PUT "$PRESENCE_STATUS_PATH" --data-urlencode "statusType=${PRESENCE_SET_STATUS}"
  printf 'status: %s\n' "$PRESENCE_SET_STATUS"
  if [[ -n "$PRESENCE_OPT_CLEAR_AFTER" && "$PRESENCE_SECONDS" -eq 0 ]]; then
    presence_clear_message
  elif [[ -n "$PRESENCE_OPT_MESSAGE" || -n "$PRESENCE_OPT_EMOJI" ]]; then
    clear_at=""
    if [[ -n "$PRESENCE_OPT_CLEAR_AFTER" ]]; then
      clear_at="$(($(now_epoch) + PRESENCE_SECONDS))"
      ocs_request PUT "$PRESENCE_CUSTOM_PATH" \
        --data-urlencode "statusIcon=${PRESENCE_OPT_EMOJI}" \
        --data-urlencode "message=${PRESENCE_OPT_MESSAGE}" \
        --data-urlencode "clearAt=${clear_at}"
    else
      ocs_request PUT "$PRESENCE_CUSTOM_PATH" \
        --data-urlencode "statusIcon=${PRESENCE_OPT_EMOJI}" \
        --data-urlencode "message=${PRESENCE_OPT_MESSAGE}"
    fi
    [[ -z "$PRESENCE_OPT_MESSAGE" ]] || printf 'message: %s\n' "$PRESENCE_OPT_MESSAGE"
  fi
}

cmd_presence() {
  presence_parse_action "$@"
  # http loads after the parse (whose opt_begin consumed --help), so
  # `sciebo presence --help` parses none of it.
  presence_validate_options

  http_load_context

  case "$PRESENCE_ACTION" in
    show) presence_show ;;
    clear) presence_clear_message ;;
    set) presence_set ;;
  esac
  return 0
}
