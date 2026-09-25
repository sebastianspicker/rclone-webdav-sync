#!/usr/bin/env bash
# schedule.sh - schedule template rendering and launchd/systemd commands (lib/commands/schedule.sh).
# Sourced setup lives in tests/unit/common.sh; run standalone with
# `bash tests/unit/schedule.sh`.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# --- schedule template XML escaping -------------------------------------
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/commands/schedule.sh
source "${LIB_DIR}/commands/schedule.sh"
SCHEDULE_TEMPLATE_FILE="${TMP}/template.plist"
printf '<string>@PROJECT_DIR@</string>\n<string>@LABEL@</string>\n<string>@RCLONE_DIR@</string>\n<string>@LOG_DIR@</string>\n<string>@COMMAND@</string>\n<string>@SCHEDULE@</string>\n<string>@WATCH_PATHS@</string>\n' >"$SCHEDULE_TEMPLATE_FILE"
PROJECT_DIR='/tmp/R&D <x>'
LAUNCHD_LABEL='de.test&x'
SCHEDULE_RCLONE_DIR='/opt/bin'
LOG_DIR='/tmp/logs & more'
rendered="$(schedule_render_template)"
expect_contains "schedule render: project dir escaped" "$rendered" "/tmp/R&amp;D &lt;x&gt;"
expect_contains "schedule render: label escaped" "$rendered" "de.test&amp;x"
expect_contains "schedule render: log dir escaped" "$rendered" "/tmp/logs &amp; more"
expect_not_contains "schedule render: no raw project ampersand" "$rendered" "R&D"
expect_contains "schedule render: placeholders replaced" "$rendered" "/opt/bin"

# --- schedule command, schedule block, and watch paths -------------------
PROJECT_DIR="${PROJ_DIR}"
LOG_DIR="${TMP}/schedule-logs"
SCHEDULE_RCLONE_DIR=""
SCHEDULE_INTERVAL=""
SCHEDULE_JITTER=0
SCHEDULE_WATCH_PATH=""
rendered="$(schedule_render_template)"
expect_contains "schedule render: default uses StartCalendarInterval" "$rendered" "<key>StartCalendarInterval</key>"
expect_not_contains "schedule render: default has no StartInterval" "$rendered" "StartInterval"
expect_not_contains "schedule render: default has no WatchPaths" "$rendered" "WatchPaths"
expect_contains "schedule render: command runs sync --apply --quiet" "$rendered" "bin/sciebo sync --apply --quiet"

SCHEDULE_INTERVAL=3600
rendered="$(schedule_render_template)"
expect_contains "schedule render: interval uses StartInterval" "$rendered" $'<key>StartInterval</key>\n  <integer>3600</integer>'
expect_not_contains "schedule render: interval has no calendar block" "$rendered" "StartCalendarInterval"

SCHEDULE_INTERVAL=""
SCHEDULE_JITTER=300
rendered="$(schedule_render_template)"
# shellcheck disable=SC2016  # the jitter expression must stay literal
expect_contains "schedule render: jitter prefixes the command" "$rendered" "sleep \$((RANDOM % 300)); exec ${SCIEBO_BASH}"
expect_not_contains "schedule render: jitter keeps the calendar schedule" "$rendered" "StartInterval"

SCHEDULE_JITTER=0
SCHEDULE_WATCH_PATH="${TMP}/watch & <dir>"
mkdir -p "$SCHEDULE_WATCH_PATH"
rendered="$(schedule_render_template)"
expect_contains "schedule render: watch path uses WatchPaths" "$rendered" "<key>WatchPaths</key>"
expect_contains "schedule render: watch path XML-escaped" "$rendered" "&amp; &lt;dir&gt;"

SCHEDULE_INTERVAL=""
SCHEDULE_JITTER=0
SCHEDULE_WATCH_PATH=""
PROJECT_DIR="${PROJ_DIR}"
LOG_DIR="${TMP}/lock-state/logs"

finish
