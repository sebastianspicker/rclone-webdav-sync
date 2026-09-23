#!/bin/bash
# schedule.sh command module - manage the per-user sync scheduler (launchd
# on macOS, systemd --user on Linux).

SCHEDULE_TEMPLATE_FILE="${PROJECT_DIR}/launchd/de.rclone-sciebo.sync.plist.in"
SCHEDULE_RCLONE_DIR=""

usage_schedule() {
  usage_emit <<'EOF'
Usage: sciebo schedule install|uninstall|status

Manage the per-user scheduler agent (launchd on macOS, systemd --user on
Linux) that runs `sciebo sync --apply --quiet` daily at
SCHEDULE_HOUR:SCHEDULE_MINUTE, every SCHEDULE_INTERVAL seconds, or when
SCHEDULE_WATCH_PATH changes (see config/settings.env). SCHEDULE_JITTER adds a
random delay before each run.

Commands:
  install     render the unit(s) and start the agent/timer
  uninstall   stop the agent/timer and remove the unit(s)
  status      show whether the agent/timer is installed and loaded

Options for install:
  --at-login       start the agent at login/boot (RunAtLoad on launchd,
                   [Install] WantedBy=default.target on systemd; overrides
                   SCHEDULE_AT_LOGIN=1)
  --profiles LIST  render one extra agent per profile, labelled
                   <LAUNCHD_LABEL>.<profile>, each running with --profile
                   (comma or space separated; overrides SCHEDULE_PROFILES)
EOF
}

# schedule_expand_watch_path PATH - expand a leading ~ to HOME. WatchPaths
# must be absolute, so only the documented home shortcut is applied.
# shellcheck disable=SC2088  # "~/" is a literal case pattern, not a path
schedule_expand_watch_path() {
  case "$1" in
    "~") printf '%s' "$HOME" ;;
    "~/"*) printf '%s' "${HOME}/${1#\~/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# schedule_agent_label PROFILE - the plain LAUNCHD_LABEL names the active
# profile; every configured profile gets its own "<label>.<profile>" agent.
schedule_agent_label() {
  if [[ -n "${1:-}" ]]; then
    printf '%s.%s' "$LAUNCHD_LABEL" "$1"
  else
    printf '%s' "$LAUNCHD_LABEL"
  fi
  return 0
}

# schedule_profile_list - print SCHEDULE_PROFILES entries one per line
# (comma or whitespace separated). `read -a` splits without pathname
# expansion, so a value like "*" is validated as a name, not globbed against
# the working directory.
schedule_profile_list() {
  local raw="${SCHEDULE_PROFILES:-}" entry="" entries=()
  raw="${raw//,/ }"
  read -r -a entries <<<"$raw"
  for entry in "${entries[@]}"; do
    printf '%s\n' "$entry"
  done
  return 0
}

# schedule_each_agent ACTION_FUNC - run ACTION_FUNC once for the active
# profile (empty argument) and once per configured SCHEDULE_PROFILES entry.
# Returns 1 when any call does, 0 otherwise, so callers aggregate status.
schedule_each_agent() {
  local action="$1" profile="" rc=0
  "$action" "" || rc=1
  while IFS= read -r profile; do
    "$action" "$profile" || rc=1
  done < <(schedule_profile_list)
  return "$rc"
}

# schedule_validate_profile_names - validate every SCHEDULE_PROFILES name
# without requiring the profile directory to exist (uninstall and status
# must still reach agents whose profile was removed).
schedule_validate_profile_names() {
  local profile=""
  while IFS= read -r profile; do
    validate_profile_name "$profile"
  done < <(schedule_profile_list)
  return 0
}

# schedule_require_profiles - additionally require each profile directory
# under PROFILES_DIR, so install cannot render an agent for a missing
# profile.
schedule_require_profiles() {
  local profile=""
  while IFS= read -r profile; do
    validate_profile_name "$profile"
    [[ -d "${PROFILES_DIR}/${profile}" ]] ||
      die "profile '$(printable "$profile")' not found at ${PROFILES_DIR}/${profile}; create it with '${CLI_NAME} account add ${profile}'"
  done < <(schedule_profile_list)
  return 0
}

# schedule_validate_interval - validate SCHEDULE_INTERVAL when it is set and
# store its normalized decimal value. An unset/empty interval leaves the
# setting untouched, which is the "use the daily clock" marker the other
# validators key off.
schedule_validate_interval() {
  local interval="${SCHEDULE_INTERVAL:-}"
  [[ -n "$interval" ]] || return 0
  case "$interval" in
    '' | *[!0-9]*) die "SCHEDULE_INTERVAL must be a positive integer number of seconds (got '${interval}')" ;;
  esac
  interval=$((10#$interval))
  [[ "$interval" -gt 0 ]] ||
    die "SCHEDULE_INTERVAL must be a positive integer number of seconds (got '${SCHEDULE_INTERVAL}')"
  SCHEDULE_INTERVAL="$interval"
}

# schedule_validate_jitter - validate SCHEDULE_JITTER (always consulted) and
# store its decimal value.
schedule_validate_jitter() {
  local jitter="${SCHEDULE_JITTER:-}"
  case "$jitter" in
    '' | *[!0-9]*) die "SCHEDULE_JITTER must be a non-negative integer number of seconds (got '${jitter}')" ;;
  esac
  SCHEDULE_JITTER=$((10#$jitter))
}

# schedule_validate_clock - validate SCHEDULE_HOUR/SCHEDULE_MINUTE. The clock
# is only consulted when no interval is set: schedule_validate_interval runs
# first, so an empty SCHEDULE_INTERVAL here is the "no interval" marker.
schedule_validate_clock() {
  local hour minute
  [[ -z "${SCHEDULE_INTERVAL:-}" ]] || return 0
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

# schedule_validate_watch_path - expand SCHEDULE_WATCH_PATH and require the
# result to exist when the setting is non-empty.
schedule_validate_watch_path() {
  [[ -n "${SCHEDULE_WATCH_PATH:-}" ]] || return 0
  SCHEDULE_WATCH_PATH=${ schedule_expand_watch_path "$SCHEDULE_WATCH_PATH";}
  [[ -e "$SCHEDULE_WATCH_PATH" ]] || die "SCHEDULE_WATCH_PATH does not exist: ${SCHEDULE_WATCH_PATH}"
}

# schedule_validate - validate the SCHEDULE_* settings before rendering.
# These are settings values, not CLI options, so opt_require_uint does not
# fit: it stops through usage_error (exit 2) with "<flag> requires a ...
# integer", while every check here dies (exit 1) quoting the offending
# value, and the hour/minute checks are ranges it cannot express either.
# The interval check runs first because an interval only exists when the
# clock settings are not consulted.
schedule_validate() {
  schedule_validate_interval
  schedule_validate_jitter
  schedule_validate_clock
  schedule_validate_watch_path
  schedule_require_profiles
}

# schedule_xml_escape TEXT - escape the XML metacharacters that can appear
# in label, project, rclone, log, and watch paths, so an "&" or "<" in a
# directory name cannot produce an invalid (or injected) plist. Quotes are
# deliberately left alone; the escaping is shared with nc_api's quote-aware
# variant through core's xml_escape_into.
schedule_xml_escape() {
  local s=""
  xml_escape_into s "$1"
  printf '%s' "$s"
}

# schedule_command [PROFILE] - the command launchd runs via `bash -c`.
# Configured profiles get `--profile <name>`; jitter sleeps a random number
# of seconds (RANDOM is expanded when the agent runs) before exec'ing the
# CLI. The paths are shell-quoted because the whole string goes through
# `bash -c`: an install directory containing spaces or metacharacters must
# not change the command.
schedule_command() {
  local profile="${1:-}" cli="" command=""
  cli="$(printf '%q' "${PROJECT_DIR}/bin/sciebo")"
  command="exec $(printf '%q' "${SCIEBO_BASH:-/bin/bash}") ${cli}"
  [[ -z "$profile" ]] || command="${command} --profile $(printf '%q' "$profile")"
  command="${command} sync --apply --quiet"
  if [[ "${SCHEDULE_JITTER:-0}" -gt 0 ]]; then
    command="sleep \$((RANDOM % ${SCHEDULE_JITTER})); ${command}"
  fi
  printf '%s' "$command"
}

# schedule_run_at_load_block - RunAtLoad key for the launchd agent, true
# when SCHEDULE_AT_LOGIN=1.
schedule_run_at_load_block() {
  if [[ "${SCHEDULE_AT_LOGIN:-0}" == "1" ]]; then
    printf '<key>RunAtLoad</key>\n  <true/>'
  else
    printf '<key>RunAtLoad</key>\n  <false/>'
  fi
  return 0
}

# schedule_block - StartInterval when SCHEDULE_INTERVAL is a positive
# integer, otherwise the daily StartCalendarInterval dict.
schedule_block() {
  local interval="${SCHEDULE_INTERVAL:-}"
  if [[ "$interval" =~ ^[0-9]+$ ]] && [[ "$((10#$interval))" -gt 0 ]]; then
    printf '<key>StartInterval</key>\n  <integer>%s</integer>' "$((10#$interval))"
    return 0
  fi
  printf '<key>StartCalendarInterval</key>\n  <dict>\n    <key>Hour</key>\n    <integer>%s</integer>\n    <key>Minute</key>\n    <integer>%s</integer>\n  </dict>' \
    "${SCHEDULE_HOUR:-0}" "${SCHEDULE_MINUTE:-0}"
}

# schedule_watch_block - WatchPaths array for SCHEDULE_WATCH_PATH, empty
# when the setting is unset.
schedule_watch_block() {
  local path
  [[ -n "${SCHEDULE_WATCH_PATH:-}" ]] || return 0
  path="$(schedule_xml_escape "$(schedule_expand_watch_path "$SCHEDULE_WATCH_PATH")")"
  printf '<key>WatchPaths</key>\n  <array>\n    <string>%s</string>\n  </array>' "$path"
}

# schedule_render_template [LABEL] [PROFILE] - render the plist template for
# LABEL (default LAUNCHD_LABEL) and PROFILE (empty = the active profile).
schedule_render_template() {
  local line label project rclone_dir log_dir command schedule watch_paths run_at_load bash_path
  label="$(schedule_xml_escape "${1:-$LAUNCHD_LABEL}")" project="$(schedule_xml_escape "$PROJECT_DIR")"
  rclone_dir="$(schedule_xml_escape "$SCHEDULE_RCLONE_DIR")"
  # shellcheck disable=SC2153  # LOG_DIR is derived by lib/settings.sh
  log_dir="$(schedule_xml_escape "$LOG_DIR")"
  bash_path="$(schedule_xml_escape "${SCIEBO_BASH:-/bin/bash}")"
  command="$(schedule_xml_escape "$(schedule_command "${2:-}")")"
  schedule="$(schedule_block)"
  watch_paths="$(schedule_watch_block)"
  run_at_load="$(schedule_run_at_load_block)"
  # patsub_replacement (Bash 5.2+ default) treats "&" in a replacement as the
  # matched text, and every value below is XML-escaped (so it can contain
  # "&amp;"). Escape each value's "&" as "\&" before it is used as a
  # replacement so the literal text survives.
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line//@BASH@/${bash_path//&/\\&}}"
    line="${line//@LABEL@/${label//&/\\&}}"
    line="${line//@PROJECT_DIR@/${project//&/\\&}}"
    line="${line//@RCLONE_DIR@/${rclone_dir//&/\\&}}"
    line="${line//@LOG_DIR@/${log_dir//&/\\&}}"
    line="${line//@COMMAND@/${command//&/\\&}}"
    line="${line//@SCHEDULE@/${schedule//&/\\&}}"
    line="${line//@WATCH_PATHS@/${watch_paths//&/\\&}}"
    line="${line//@RUN_AT_LOAD@/${run_at_load//&/\\&}}"
    printf '%s\n' "$line"
  done <"$SCHEDULE_TEMPLATE_FILE"
}

# --- launchd backend ---------------------------------------------------------

# schedule_launchd_render DEST LABEL PROFILE - render one plist, lint it,
# and move it into place.
schedule_launchd_render() {
  local dest="$1" label="$2" profile="$3" tmp=""
  temp_mktemp_into tmp "${dest}.tmp.XXXXXX" || die "cannot create temp file in $(dirname "$dest")"
  schedule_render_template "$label" "$profile" >"$tmp" || {
    temp_discard "$tmp"
    die "cannot render launchd template ${SCHEDULE_TEMPLATE_FILE}"
  }
  plutil -lint "$tmp" >/dev/null || {
    temp_discard "$tmp"
    die "Generated plist did not pass plutil -lint"
  }
  mv -f "$tmp" "$dest"
  temp_discard "$tmp"
}

# schedule_launchd_install_agent PROFILE - render, bootstrap, and report one
# agent (empty PROFILE = the active profile on the plain label).
schedule_launchd_install_agent() {
  local profile="${1:-}" label="" dest="" bootstrap_out=""
  label=${ schedule_agent_label "$profile";}
  dest="${HOME}/Library/LaunchAgents/${label}.plist"
  mkdir -p "$(dirname "$dest")"
  schedule_launchd_render "$dest" "$label" "$profile"
  launchctl bootout "gui/$UID/${label}" >/dev/null 2>&1 || true
  if ! bootstrap_out="$(launchctl bootstrap "gui/$UID" "$dest" 2>&1)"; then
    die "launchctl bootstrap failed for ${label}: ${bootstrap_out}"
  fi
  printf 'Installed %s\n' "$dest"
  launchctl print "gui/$UID/${label}" 2>&1 | sed -n '1,15p' || true
}

# schedule_launchd_install - the macOS path: render the active agent plus
# one agent per configured profile.
schedule_launchd_install() {
  [[ -f "$SCHEDULE_TEMPLATE_FILE" ]] || die "Missing launchd template: ${SCHEDULE_TEMPLATE_FILE}"
  schedule_validate
  SCHEDULE_RCLONE_DIR="$(dirname "$RCLONE_BIN")"
  schedule_each_agent schedule_launchd_install_agent
}

# schedule_launchd_uninstall_agent PROFILE - bootout and remove one plist.
schedule_launchd_uninstall_agent() {
  local profile="${1:-}" label=""
  label=${ schedule_agent_label "$profile";}
  launchctl bootout "gui/$UID/${label}" >/dev/null 2>&1 || true
  rm -f "${HOME}/Library/LaunchAgents/${label}.plist"
  printf 'Uninstalled %s\n' "$label"
}

# schedule_launchd_uninstall - remove every rendered label (the active
# profile plus each configured profile).
schedule_launchd_uninstall() {
  schedule_validate_profile_names
  schedule_each_agent schedule_launchd_uninstall_agent
}

# schedule_status_mode PLIST - print the schedule mode, jitter, and watch
# settings recorded in the plist. Best effort so a foreign plist prints
# nothing extra.
schedule_status_mode() {
  local dest="$1" interval hour minute command_line watch jitter_re
  interval="$(plutil -extract StartInterval raw -o - "$dest" 2>/dev/null || true)"
  if [[ "$interval" =~ ^[0-9]+$ ]]; then
    printf 'schedule: every %ss\n' "$interval"
  else
    hour="$(plutil -extract StartCalendarInterval.Hour raw -o - "$dest" 2>/dev/null || true)"
    minute="$(plutil -extract StartCalendarInterval.Minute raw -o - "$dest" 2>/dev/null || true)"
    if [[ "$hour" =~ ^[0-9]+$ && "$minute" =~ ^[0-9]+$ ]]; then
      printf 'schedule: daily %02d:%02d\n' "$((10#$hour))" "$((10#$minute))"
    fi
  fi
  command_line="$(plutil -extract ProgramArguments.2 raw -o - "$dest" 2>/dev/null || true)"
  jitter_re='RANDOM % ([0-9]+)'
  if [[ "$command_line" =~ $jitter_re ]]; then
    printf 'jitter: %ss\n' "${BASH_REMATCH[1]}"
  fi
  watch="$(plutil -extract WatchPaths.0 raw -o - "$dest" 2>/dev/null || true)"
  [[ -z "$watch" ]] || printf 'watch: %s\n' "$watch"
}

# schedule_launchd_status_agent PROFILE - report one agent: label, schedule
# mode, and loaded state. rc 1 only when the plist exists but is not loaded.
schedule_launchd_status_agent() {
  local profile="${1:-}" label="" dest=""
  label=${ schedule_agent_label "$profile";}
  dest="${HOME}/Library/LaunchAgents/${label}.plist"
  if [[ ! -f "$dest" ]]; then
    printf 'not installed (%s)\n' "$dest"
    return 0
  fi
  grep -q 'bin/sciebo' "$dest" 2>/dev/null ||
    printf "warning: plist runs the old scripts/sync.sh entrypoint; re-run '%s schedule install'\n" "$CLI_NAME" >&2
  if launchctl print "gui/$UID/${label}" >/dev/null 2>&1; then
    printf 'installed and loaded: %s\n' "$dest"
    launchctl print "gui/$UID/${label}" 2>&1 | sed -n '1,15p' || true
    schedule_status_mode "$dest"
    return 0
  fi
  printf 'installed but not loaded: %s\n' "$dest"
  schedule_status_mode "$dest"
  return 1
}

# schedule_launchd_status - list the active agent and every configured
# profile agent; any installed-but-not-loaded agent makes the command fail.
schedule_launchd_status() {
  schedule_validate_profile_names
  schedule_each_agent schedule_launchd_status_agent
}

# --- systemd --user backend -------------------------------------------------

schedule_systemd_unit_dir() { printf '%s' "${HOME}/.config/systemd/user"; }
schedule_systemd_service_file() {
  printf '%s/%s.service' "$(schedule_systemd_unit_dir)" "${1:-$LAUNCHD_LABEL}"
}
schedule_systemd_timer_file() {
  printf '%s/%s.timer' "$(schedule_systemd_unit_dir)" "${1:-$LAUNCHD_LABEL}"
}
schedule_systemd_watch_file() {
  printf '%s/%s.path' "$(schedule_systemd_unit_dir)" "${1:-$LAUNCHD_LABEL}"
}

# schedule_systemd_quote TEXT - quote one systemd value when it contains
# whitespace or quotes, and double "%" so systemd specifiers stay literal.
schedule_systemd_quote() {
  local s="$1"
  s="${s//%/%%}"
  case "$s" in
    *[[:space:]]* | *'"'* | *"\\"*)
      s="${s//\\/\\\\}"
      s="${s//\"/\\\"}"
      printf '"%s"' "$s"
      ;;
    *) printf '%s' "$s" ;;
  esac
}

# schedule_systemd_service_content [LABEL] [PROFILE] - the oneshot service
# that runs the same command as the launchd agent. With SCHEDULE_AT_LOGIN=1
# it also gains the [Install] section that enables it at login.
schedule_systemd_service_content() {
  local label="${1:-$LAUNCHD_LABEL}" profile="${2:-}" command=""
  command="$(schedule_systemd_quote "${SCIEBO_BASH:-/bin/bash}") $(schedule_systemd_quote "${PROJECT_DIR}/bin/sciebo")"
  [[ -z "$profile" ]] || command="${command} --profile $(schedule_systemd_quote "$profile")"
  command="${command} sync --apply --quiet"
  printf '[Unit]\n'
  printf 'Description=sciebo sync (%s)\n\n' "$label"
  printf '[Service]\n'
  printf 'Type=oneshot\n'
  printf 'ExecStart=%s\n' "$command"
  printf 'WorkingDirectory=%s\n' "$(schedule_systemd_quote "$PROJECT_DIR")"
  if [[ "${SCHEDULE_AT_LOGIN:-0}" == "1" ]]; then
    printf '\n[Install]\nWantedBy=default.target\n'
  fi
}

# schedule_systemd_timer_content [LABEL] - OnCalendar for the daily
# schedule, OnUnitActiveSec for SCHEDULE_INTERVAL, and RandomizedDelaySec
# for jitter.
schedule_systemd_timer_content() {
  local label="${1:-$LAUNCHD_LABEL}" interval="${SCHEDULE_INTERVAL:-}" jitter="${SCHEDULE_JITTER:-0}"
  printf '[Unit]\n'
  printf 'Description=sciebo sync schedule (%s)\n\n' "$label"
  printf '[Timer]\n'
  if [[ "$interval" =~ ^[0-9]+$ ]] && [[ "$((10#$interval))" -gt 0 ]]; then
    printf 'OnBootSec=1min\n'
    printf 'OnUnitActiveSec=%ss\n' "$((10#$interval))"
  else
    printf 'OnCalendar=*-*-* %02d:%02d:00\n' "$((10#${SCHEDULE_HOUR:-0}))" "$((10#${SCHEDULE_MINUTE:-0}))"
  fi
  if [[ "$jitter" =~ ^[0-9]+$ ]] && [[ "$((10#$jitter))" -gt 0 ]]; then
    printf 'RandomizedDelaySec=%ss\n' "$((10#$jitter))"
  fi
  printf '\n[Install]\nWantedBy=timers.target\n'
}

# schedule_systemd_watch_content [LABEL] - a .path unit that starts the
# service when SCHEDULE_WATCH_PATH changes.
schedule_systemd_watch_content() {
  local label="${1:-$LAUNCHD_LABEL}" path=""
  printf '[Unit]\n'
  printf 'Description=sciebo sync watch (%s)\n\n' "$label"
  printf '[Path]\n'
  path="$(schedule_expand_watch_path "${SCHEDULE_WATCH_PATH:-}")"
  # Quote only when the path can break out of its directive (a control byte,
  # quote, backslash, or a systemd specifier); a plain space is valid in a
  # single path value.
  case "$path" in
    *[[:cntrl:]]* | *'"'* | *"\\"* | *%*) path="$(schedule_systemd_quote "$path")" ;;
  esac
  printf 'PathChanged=%s\n' "$path"
  printf '\n[Install]\nWantedBy=paths.target\n'
}

# schedule_systemd_write_units PROFILE - write the service, timer, and
# (when configured) watch units for one agent.
schedule_systemd_write_units() {
  local profile="${1:-}" label="" service="" timer="" watch=""
  label=${ schedule_agent_label "$profile";}
  service="$(schedule_systemd_service_file "$label")"
  timer="$(schedule_systemd_timer_file "$label")"
  watch="$(schedule_systemd_watch_file "$label")"
  schedule_systemd_service_content "$label" "$profile" >"$service" ||
    die "cannot write systemd unit ${service}"
  schedule_systemd_timer_content "$label" >"$timer" ||
    die "cannot write systemd unit ${timer}"
  if [[ -n "${SCHEDULE_WATCH_PATH:-}" ]]; then
    schedule_systemd_watch_content "$label" >"$watch" ||
      die "cannot write systemd unit ${watch}"
  else
    rm -f "$watch"
  fi
}

# schedule_systemd_enable_agent PROFILE - enable and report one agent; with
# SCHEDULE_AT_LOGIN=1 the service is enabled at login as well.
schedule_systemd_enable_agent() {
  local profile="${1:-}" label="" timer=""
  label=${ schedule_agent_label "$profile";}
  timer="$(schedule_systemd_timer_file "$label")"
  systemctl --user enable --now "${label}.timer" >/dev/null 2>&1 ||
    die "systemctl --user enable failed for ${label}.timer"
  if [[ -n "${SCHEDULE_WATCH_PATH:-}" ]]; then
    systemctl --user enable --now "${label}.path" >/dev/null 2>&1 ||
      die "systemctl --user enable failed for ${label}.path"
  fi
  if [[ "${SCHEDULE_AT_LOGIN:-0}" == "1" ]]; then
    systemctl --user enable "${label}.service" >/dev/null 2>&1 ||
      die "systemctl --user enable failed for ${label}.service"
  fi
  printf 'Installed %s\n' "$timer"
  systemctl --user status "${label}.timer" --no-pager 2>&1 | sed -n '1,15p' || true
}

# schedule_systemd_install - write and enable the active agent plus one
# agent per configured profile.
schedule_systemd_install() {
  local dir=""
  schedule_validate
  dir="$(schedule_systemd_unit_dir)"
  mkdir -p "$dir"
  schedule_each_agent schedule_systemd_write_units
  systemctl --user daemon-reload >/dev/null 2>&1 ||
    die "systemctl --user daemon-reload failed; is a user systemd session running?"
  schedule_each_agent schedule_systemd_enable_agent
}

# schedule_systemd_remove_agent PROFILE - disable and remove one agent.
schedule_systemd_remove_agent() {
  local profile="${1:-}" label="" watch=""
  label=${ schedule_agent_label "$profile";}
  watch="$(schedule_systemd_watch_file "$label")"
  systemctl --user disable --now "${label}.timer" >/dev/null 2>&1 || true
  if [[ -f "$watch" ]]; then
    systemctl --user disable --now "${label}.path" >/dev/null 2>&1 || true
  fi
  if [[ "${SCHEDULE_AT_LOGIN:-0}" == "1" ]]; then
    systemctl --user disable "${label}.service" >/dev/null 2>&1 || true
  fi
  rm -f "$(schedule_systemd_service_file "$label")" \
    "$(schedule_systemd_timer_file "$label")" "$watch"
  printf 'Uninstalled %s\n' "${label}.timer"
}

# schedule_systemd_uninstall - remove every rendered label (the active
# profile plus each configured profile).
schedule_systemd_uninstall() {
  schedule_validate_profile_names
  schedule_each_agent schedule_systemd_remove_agent
  systemctl --user daemon-reload >/dev/null 2>&1 || true
}

# schedule_systemd_status_mode LABEL - print the schedule, jitter, and
# watch settings recorded in the timer and path units.
schedule_systemd_status_mode() {
  local label="${1:-$LAUNCHD_LABEL}" timer="" line=""
  timer="$(schedule_systemd_timer_file "$label")"
  while IFS= read -r line; do
    case "$line" in
      OnCalendar=*) printf 'schedule: %s\n' "${line#OnCalendar=}" ;;
      OnUnitActiveSec=*) printf 'schedule: every %s\n' "${line#OnUnitActiveSec=}" ;;
      RandomizedDelaySec=*) printf 'jitter: %s\n' "${line#RandomizedDelaySec=}" ;;
    esac
  done <"$timer" 2>/dev/null
  if [[ -f "$(schedule_systemd_watch_file "$label")" ]]; then
    printf 'watch: %s\n' "$SCHEDULE_WATCH_PATH"
  fi
  return 0
}

# schedule_systemd_status_agent PROFILE - report one agent: label, schedule
# mode, and loaded state. rc 1 only when the timer exists but is not loaded.
schedule_systemd_status_agent() {
  local profile="${1:-}" label="" timer="" service=""
  label=${ schedule_agent_label "$profile";}
  timer="$(schedule_systemd_timer_file "$label")"
  service="$(schedule_systemd_service_file "$label")"
  if [[ ! -f "$timer" ]]; then
    printf 'not installed (%s)\n' "$timer"
    return 0
  fi
  grep -q 'bin/sciebo' "$service" 2>/dev/null ||
    printf "warning: systemd unit runs the old entrypoint; re-run '%s schedule install'\n" "$CLI_NAME" >&2
  if systemctl --user is-enabled "${label}.timer" >/dev/null 2>&1 &&
    systemctl --user is-active "${label}.timer" >/dev/null 2>&1; then
    printf 'installed and loaded: %s\n' "$timer"
    schedule_systemd_status_mode "$label"
    return 0
  fi
  printf 'installed but not loaded: %s\n' "$timer"
  schedule_systemd_status_mode "$label"
  return 1
}

# schedule_systemd_status - list the active agent and every configured
# profile agent; any installed-but-not-loaded agent makes the command fail.
schedule_systemd_status() {
  schedule_validate_profile_names
  schedule_each_agent schedule_systemd_status_agent
}

# schedule_install/schedule_uninstall/schedule_status - dispatch to the
# backend selected by platform_scheduler_backend. cron is detected but not
# managed; the user keeps ownership of that crontab entry.
schedule_install() {
  # platform.sh is lazy; load it for the scheduler-backend dispatch below.
  sciebo_require_module platform platform_scheduler_backend
  case "$(platform_scheduler_backend)" in
    launchd) schedule_launchd_install ;;
    systemd) schedule_systemd_install ;;
    cron) die "scheduler backend 'cron' is not managed by '${CLI_NAME} schedule'; add the crontab entry manually" ;;
    *) die "no supported scheduler backend found (need launchd or a systemd --user session)" ;;
  esac
}

schedule_uninstall() {
  # platform.sh is lazy; see schedule_install.
  sciebo_require_module platform platform_scheduler_backend
  case "$(platform_scheduler_backend)" in
    launchd) schedule_launchd_uninstall ;;
    systemd) schedule_systemd_uninstall ;;
    cron) die "scheduler backend 'cron' is not managed by '${CLI_NAME} schedule'; remove the crontab entry manually" ;;
    *) die "no supported scheduler backend found (need launchd or a systemd --user session)" ;;
  esac
}

schedule_status() {
  # platform.sh is lazy; see schedule_install.
  sciebo_require_module platform platform_scheduler_backend
  case "$(platform_scheduler_backend)" in
    launchd) schedule_launchd_status ;;
    systemd) schedule_systemd_status ;;
    cron) die "scheduler backend 'cron' is not managed by '${CLI_NAME} schedule'; check the crontab manually" ;;
    *) die "no supported scheduler backend found (need launchd or a systemd --user session)" ;;
  esac
}

cmd_schedule() {
  local command="${1:-}"
  case "$command" in
    install | uninstall | status) ;;
    -h | --help)
      usage_schedule
      exit 0
      ;;
    "")
      usage_error schedule "a subcommand is required (install|uninstall|status)"
      ;;
    *)
      usage_unknown_sub schedule "$command"
      ;;
  esac

  if [[ "$command" == "install" ]]; then
    shift
    opt_begin "at-login:b profiles:s" schedule "install " "$@"
    opt_guard schedule "install: "
    opt_into SCHEDULE_AT_LOGIN at_login 1
    opt_into SCHEDULE_PROFILES profiles "${OPT_profiles:-}"
  fi

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
