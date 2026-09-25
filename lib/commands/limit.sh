#!/bin/bash
# limit.sh command module - limit/unlimited bandwidth marker commands.

usage_limit() {
  usage_emit <<'EOF'
Usage: sciebo limit [options]

Cap rclone bandwidth for later `sciebo sync` runs. The limit is stored as a
local marker (no server contact) and applies until it expires or
`sciebo unlimited` removes it. An active marker takes precedence over
BW_SCHEDULE and BW_LIMIT_UP/BW_LIMIT_DOWN; an expired marker is removed
automatically on the next read.

Options:
  --up RATE     upload cap (rclone size suffix, e.g. 2M; off = no cap)
  --down RATE   download cap (e.g. 5M)
  --until DUR   expire after this long; a bare number means minutes and 0
                means no expiry (default)
  --show        print the current limit without changing it
  --clear       remove the marker (same as `sciebo unlimited`)
  --json        print the state as JSON
  -h, --help    show this help

At least one of --up, --down, --until, --show, or --clear is required.
EOF
}

usage_unlimited() {
  usage_emit <<'EOF'
Usage: sciebo unlimited

Remove the bandwidth marker written by `sciebo limit` so later sync runs
are uncapped again (unless BW_SCHEDULE or BW_LIMIT_UP/BW_LIMIT_DOWN is
configured). Prints `unlimited`.
EOF
}

# limit_emit UP DOWN UNTIL ACTIVE - print the marker state as text or, with
# output_mode_set true, as a JSON document.
limit_emit() {
  local up="$1" down="$2" until="$3" active="$4" label="" active_json="false"
  if [[ "$active" == "1" ]]; then
    if [[ "$until" == "0" ]]; then
      label="indefinite"
    elif type epoch_to_stamp >/dev/null 2>&1; then
      label=${ epoch_to_stamp "$until";}
    else
      label="$until"
    fi
  fi
  if output_json_enabled; then
    [[ "$active" != "1" ]] || active_json="true"
    output_json_begin
    output_json_kv_raw "active" "$active_json"
    output_json_kv "up" "$up"
    output_json_kv "down" "$down"
    output_json_kv_raw "until" "${until:-0}"
    output_json_kv "until_stamp" "${label:-unlimited}"
    output_json_end
    return 0
  fi
  if [[ "$active" == "1" ]]; then
    printf 'limited: up=%s down=%s until=%s\n' "${up:-off}" "${down:-off}" "$label"
  else
    printf 'unlimited\n'
  fi
  return 0
}

# limit_emit_current - read the marker and print its state.
limit_emit_current() {
  bw_marker_read
  if [[ "${BW_MARKER_ACTIVE:-0}" == "1" ]]; then
    limit_emit "$BW_MARKER_UP" "$BW_MARKER_DOWN" "$BW_MARKER_UNTIL" 1
  else
    limit_emit "" "" 0 0
  fi
}

# limit_validate_options WRITES SHOW CLEAR - the option-combination rules of
# `sciebo limit`: at least one of --up/--down/--until/--show/--clear, --show
# with --clear refused, and neither combined with a write option.
limit_validate_options() {
  local writes="$1" show="$2" clear="$3"
  if [[ "$writes" -eq 0 && "$show" == false && "$clear" == false ]]; then
    usage_error limit "at least one of --up, --down, --until, --show, or --clear is required"
  elif [[ "$show" == true && "$clear" == true ]]; then
    usage_error limit "--show and --clear are mutually exclusive"
  elif [[ "$writes" -eq 1 && ("$show" == true || "$clear" == true) ]]; then
    usage_error limit "--show/--clear cannot be combined with --up/--down/--until"
  fi
  return 0
}

cmd_limit() {
  local up="" down="" duration="" seconds="" until=0 now="" show=false clear=false
  local writes=0
  opt_begin "up:s down:s until:s show:b clear:b json:b" limit "" "$@"
  opt_guard limit
  # Bandwidth-marker helpers load after opt_guard's --help exit so
  # `sciebo limit --help` parses none of them (and the module works whether
  # or not bin/sciebo sourced lib/state/bw.sh directly).
  opt_json_mode
  up="${OPT_up:-}"
  down="${OPT_down:-}"
  duration="${OPT_until:-}"
  opt_into show show
  opt_into clear clear
  [[ -z "${OPT_up_SET:-}" && -z "${OPT_down_SET:-}" && -z "${OPT_until_SET:-}" ]] || writes=1
  limit_validate_options "$writes" "$show" "$clear"
  load_settings --no-rclone
  if [[ "$clear" == true ]]; then
    bw_marker_clear
    limit_emit_current
    return 0
  fi
  if [[ "$show" == true ]]; then
    limit_emit_current
    return 0
  fi
  if [[ -n "${OPT_until_SET:-}" ]]; then
    # The shared duration_parse_or_usage (lib/base/duration.sh) owns the grammar
    # and the error wording; its EXAMPLES argument carries limit's custom
    # "; 0 = no expiry" tail (the flagless "invalid duration: ..." spelling),
    # so the helper raises the exact old message itself.
    seconds=${ duration_parse_or_usage limit "" "$duration" invalid "90m, 1d; 0 = no expiry";}
    if [[ "$seconds" != "0" ]]; then
      now=${ now_epoch;}
      until=$((now + seconds))
    fi
  fi
  bw_marker_write "$until" "$up" "$down" ||
    die "cannot write bandwidth marker: ${BW_LIMIT_FILE:-${STATE_DIR:-?}/bwlimit}"
  limit_emit "$up" "$down" "$until" 1
  return 0
}

cmd_unlimited() {
  opt_begin "" unlimited "" "$@"
  opt_guard unlimited
  load_settings --no-rclone
  bw_marker_clear
  printf 'unlimited\n'
  return 0
}
