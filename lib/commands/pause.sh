#!/bin/bash
# pause.sh command module - pause/resume scheduled and manual syncs.

usage_pause() {
  usage_emit <<'EOF'
Usage: sciebo pause [--for DURATION]

Skip sync and check runs until `sciebo resume`. Without --for the pause
is indefinite; DURATION is a number with an optional s, m, h, or d
suffix (90m, 24h, 1d), and a bare number means minutes. An expired
marker is removed automatically on the next check.

Options:
  --for DURATION  pause for this long instead of indefinitely
  -h, --help      show this help
EOF
}

usage_resume() {
  usage_emit <<'EOF'
Usage: sciebo resume

Clear the pause marker so scheduled and manual sync/check runs continue.
Prints `resumed` when a pause was active and `not paused` otherwise.
EOF
}

cmd_pause() {
  local duration="" seconds="" until="" desc=""
  opt_begin "for:s" pause "" "$@"
  opt_guard pause
  # lib/pause.sh is lazy; load it after opt_guard's --help exit so
  # `sciebo pause --help` parses none of it.
  sciebo_require_module pause pause_set
  duration="${OPT_for:-}"
  load_settings --no-rclone
  until=0
  if [[ -n "$duration" ]]; then
    # duration_parse_or_usage (lib/duration.sh) owns the grammar and the
    # wording; its EXAMPLES argument carries pause's "90m, 24h, 1d" list.
    seconds=${ duration_parse_or_usage pause "" "$duration" invalid "90m, 24h, 1d";}
    until=$(($(now_epoch) + seconds))
  fi
  pause_set "$until" || die "cannot write pause marker: ${PAUSE_FILE}"
  desc="$(pause_describe)" || desc=""
  [[ -n "$desc" ]] || desc="paused"
  printf '%s\n' "$desc"
  return 0
}

cmd_resume() {
  local was_paused=false
  opt_begin "" resume "" "$@"
  opt_guard resume
  # lib/pause.sh is lazy; load it before the `type pause_active` probe (and
  # pause_clear) so an active pause is never reported as "not paused".
  sciebo_require_module pause pause_active
  load_settings --no-rclone
  if type pause_active >/dev/null 2>&1 && pause_active; then
    was_paused=true
  fi
  pause_clear
  if [[ "$was_paused" == true ]]; then
    printf 'resumed\n'
  else
    printf 'not paused\n'
  fi
  return 0
}
