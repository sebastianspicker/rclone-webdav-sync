#!/bin/bash
# notify.sh - desktop notifications for sync results.
#
# Best effort: notifications never change a command's exit status and never
# print to stdout. NOTIFY and NOTIFY_SUCCESS are read defensively so the
# module is safe under `set -u` before settings are loaded. The backend comes
# from platform_notify_backend (osascript on macOS, notify-send on Linux).

# platform_notify_backend comes from lib/adapters/platform.sh, always loaded before
# this file by lib/sciebo.sh.

# notify_enabled - true (0) when NOTIFY=1 and a notification backend exists.
# The notification title is supplied per message, so no title setting can
# disable notifications here.
notify_enabled() {
  [[ "${NOTIFY:-0}" == "1" ]] || return 1
  [[ -n "$(platform_notify_backend)" ]]
}

# notify_send TITLE MESSAGE - show one desktop notification. The strings
# travel as argv and are never interpolated into a script or shell command.
# An empty title, a disabled NOTIFY, or a missing backend is a silent no-op;
# always returns 0.
notify_send() {
  local title="${1:-}" message="${2:-}"
  [[ -n "$title" ]] || return 0
  notify_enabled || return 0
  case "$(platform_notify_backend)" in
    osascript)
      osascript - "$title" "$message" >/dev/null 2>&1 <<'APPLESCRIPT' || true
on run argv
  display notification (item 2 of argv) with title (item 1 of argv)
end run
APPLESCRIPT
      ;;
    notify-send)
      notify-send --app-name=Nextcloud "$title" "$message" >/dev/null 2>&1 || true
      ;;
  esac
  return 0
}
