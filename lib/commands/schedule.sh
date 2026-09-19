#!/bin/bash
# schedule.sh command module - manage the launchd sync agent.

SCHEDULE_TEMPLATE_FILE="${PROJECT_DIR}/launchd/de.rclone-sciebo.sync.plist.in"
SCHEDULE_RCLONE_DIR=""

usage_schedule() {
  cat <<'EOF'
Usage: sciebo schedule install|uninstall|status

Manage the per-user launchd agent that runs `sciebo sync --apply --quiet`
daily at SCHEDULE_HOUR:SCHEDULE_MINUTE (see config/settings.env).

Commands:
  install     render the plist and bootstrap the agent
  uninstall   bootout the agent and remove the plist
  status      show whether the agent is installed and loaded
EOF
}

schedule_validate() {
  local hour minute
  case "$SCHEDULE_HOUR" in
    '' | *[!0-9]*) die "SCHEDULE_HOUR must be an integer between 0 and 23 (got '${SCHEDULE_HOUR}')" ;;
  esac
  case "$SCHEDULE_MINUTE" in
    '' | *[!0-9]*) die "SCHEDULE_MINUTE must be an integer between 0 and 59 (got '${SCHEDULE_MINUTE}')" ;;
  esac
  hour=$((10#${SCHEDULE_HOUR}))
  minute=$((10#${SCHEDULE_MINUTE}))
  [[ "$hour" -le 23 ]] || die "SCHEDULE_HOUR must be between 0 and 23 (got '${SCHEDULE_HOUR}')"
  [[ "$minute" -le 59 ]] || die "SCHEDULE_MINUTE must be between 0 and 59 (got '${SCHEDULE_MINUTE}')"
  SCHEDULE_HOUR="$hour"
  SCHEDULE_MINUTE="$minute"
}

# schedule_xml_escape TEXT - escape the XML metacharacters that can appear
# in label, project, rclone, and log paths, so an "&" or "<" in a directory
# name cannot produce an invalid (or injected) plist.
schedule_xml_escape() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  printf '%s' "$s"
}

schedule_render_template() {
  local line label project rclone_dir log_dir
  label="$(schedule_xml_escape "$LAUNCHD_LABEL")" project="$(schedule_xml_escape "$PROJECT_DIR")"
  rclone_dir="$(schedule_xml_escape "$SCHEDULE_RCLONE_DIR")" log_dir="$(schedule_xml_escape "$LOG_DIR")"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line//@LABEL@/$label}"
    line="${line//@PROJECT_DIR@/$project}"
    line="${line//@RCLONE_DIR@/$rclone_dir}"
    line="${line//@LOG_DIR@/$log_dir}"
    printf '%s\n' "$line"
  done <"$SCHEDULE_TEMPLATE_FILE"
}

schedule_install() {
  [[ -f "$SCHEDULE_TEMPLATE_FILE" ]] || die "Missing launchd template: ${SCHEDULE_TEMPLATE_FILE}"
  schedule_validate
  SCHEDULE_RCLONE_DIR="$(dirname "$RCLONE_BIN")"
  local dest="${HOME}/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"
  mkdir -p "$(dirname "$dest")"
  local tmp="${dest}.tmp.$$"
  schedule_render_template >"$tmp"
  plutil -replace StartCalendarInterval.Hour -integer "$SCHEDULE_HOUR" "$tmp"
  plutil -replace StartCalendarInterval.Minute -integer "$SCHEDULE_MINUTE" "$tmp"
  plutil -lint "$tmp" >/dev/null || {
    rm -f "$tmp"
    die "Generated plist did not pass plutil -lint"
  }
  mv -f "$tmp" "$dest"
  launchctl bootout "gui/$UID/${LAUNCHD_LABEL}" >/dev/null 2>&1 || true
  local bootstrap_out
  if ! bootstrap_out="$(launchctl bootstrap "gui/$UID" "$dest" 2>&1)"; then
    die "launchctl bootstrap failed for ${LAUNCHD_LABEL}: ${bootstrap_out}"
  fi
  printf 'Installed %s\n' "$dest"
  launchctl print "gui/$UID/${LAUNCHD_LABEL}" 2>&1 | sed -n '1,15p' || true
}

schedule_uninstall() {
  launchctl bootout "gui/$UID/${LAUNCHD_LABEL}" >/dev/null 2>&1 || true
  rm -f "${HOME}/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"
  printf 'Uninstalled %s\n' "$LAUNCHD_LABEL"
}

schedule_status() {
  local dest="${HOME}/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"
  if [[ ! -f "$dest" ]]; then
    printf 'not installed (%s)\n' "$dest"
    return 0
  fi
  grep -q 'bin/sciebo' "$dest" 2>/dev/null ||
    printf "warning: plist runs the old scripts/sync.sh entrypoint; re-run '%s schedule install'\n" "$CLI_NAME" >&2
  if launchctl print "gui/$UID/${LAUNCHD_LABEL}" >/dev/null 2>&1; then
    printf 'installed and loaded: %s\n' "$dest"
    launchctl print "gui/$UID/${LAUNCHD_LABEL}" 2>&1 | sed -n '1,15p' || true
    return 0
  fi
  printf 'installed but not loaded: %s\n' "$dest"
  return 1
}

cmd_schedule() {
  case "${1:-}" in
    install | uninstall | status) ;;
    -h | --help)
      usage_schedule
      exit 0
      ;;
    "")
      usage_error schedule "a subcommand is required (install|uninstall|status)"
      ;;
    *)
      usage_error schedule "unknown subcommand: $1"
      ;;
  esac

  local command="$1"
  if [[ "$command" == "status" ]]; then
    load_settings --no-rclone
    schedule_status
    return $?
  fi
  load_settings
  ensure_state_dirs
  case "$command" in
    install) schedule_install ;;
    uninstall) schedule_uninstall ;;
  esac
}
