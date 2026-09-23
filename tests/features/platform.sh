#!/usr/bin/env bash
# platform.sh - platform backend selection, the Linux keychain dispatch
# (secret-tool/pass, secret on stdin only), and the systemd schedule units.
# macOS behavior is asserted as well, so the suite stays meaningful on both.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"
# shellcheck disable=SC1090,SC1091  # paths are documented and overridable
source "${PROJ}/lib/platform.sh"
# shellcheck disable=SC1090,SC1091
source "${PROJ}/lib/keychain.sh"
# shellcheck disable=SC1090,SC1091
source "${PROJ}/lib/notify.sh"
# shellcheck disable=SC1090,SC1091
source "${PROJ}/lib/commands/schedule.sh"

# --- platform helpers and test hooks -----------------------------------------
case "$(platform_os)" in
  macos)
    expect_eq "platform_os: macOS" "macos" "$(platform_os)"
    expect_eq "platform_keychain_backend: security on macOS" "security" "$(platform_keychain_backend)"
    expect_eq "platform_notify_backend: osascript on macOS" "osascript" "$(platform_notify_backend)"
    expect_eq "platform_scheduler_backend: launchd on macOS" "launchd" "$(platform_scheduler_backend)"
    ;;
  linux)
    expect_eq "platform_os: Linux" "linux" "$(platform_os)"
    ;;
esac
expect_eq "platform hook: keychain override" "secret-tool" \
  "$(SCIEBO_KEYCHAIN_BACKEND=secret-tool platform_keychain_backend)"
expect_eq "platform hook: notify override" "notify-send" \
  "$(SCIEBO_NOTIFY_BACKEND=notify-send platform_notify_backend)"
expect_eq "platform hook: scheduler override" "systemd" \
  "$(SCIEBO_SCHEDULER_BACKEND=systemd platform_scheduler_backend)"

# --- notify-send dispatch (argv, best-effort) --------------------------------
NOTIFY_BIN="${TMP}/platform-notify-bin"
mkdir -p "$NOTIFY_BIN"
cat >"${NOTIFY_BIN}/notify-send" <<'STUB'
#!/bin/bash
dir="$(cd "$(dirname "$0")" && pwd)"
for arg in "$@"; do printf '%s\n' "$arg"; done >>"${dir}/calls.log"
exit 0
STUB
chmod +x "${NOTIFY_BIN}/notify-send"
rm -f "${NOTIFY_BIN}/calls.log"
# shellcheck disable=SC2016  # the -c program expands "$1" itself
env PATH="${NOTIFY_BIN}:$PATH" SCIEBO_NOTIFY_BACKEND=notify-send NOTIFY=1 \
  bash -c '
    source "$1/lib/core.sh"
    source "$1/lib/platform.sh"
    source "$1/lib/notify.sh"
    notify_send "title here" "message here"
  ' notify-probe "$PROJ" >/dev/null
expect_contains "notify-send: app name and argv" "$(cat "${NOTIFY_BIN}/calls.log" 2>/dev/null)" \
  $'--app-name=Nextcloud\ntitle here\nmessage here'

# --- keychain dispatch through stubbed secret-tool/pass ----------------------
KC_BIN="${TMP}/platform-kc-bin"
mkdir -p "$KC_BIN"
cat >"${KC_BIN}/secret-tool" <<'STUB'
#!/bin/bash
dir="$(cd "$(dirname "$0")" && pwd)"
for arg in "$@"; do printf '%s\n' "$arg"; done >>"${dir}/args.log"
case "$1" in
  store)
    cat >"${dir}/stdin.log"
    cp "${dir}/stdin.log" "${dir}/secret"
    ;;
  lookup)
    [[ -f "${dir}/secret" ]] || exit 1
    cat "${dir}/secret"
    ;;
  clear) rm -f "${dir}/secret" ;;
esac
exit 0
STUB
cat >"${KC_BIN}/pass" <<'STUB'
#!/bin/bash
dir="$(cd "$(dirname "$0")" && pwd)"
for arg in "$@"; do printf '%s\n' "$arg"; done >>"${dir}/args.log"
case "$1" in
  insert)
    shift
    cat >"${dir}/stdin.log"
    cp "${dir}/stdin.log" "${dir}/secret"
    ;;
  show)
    [[ -f "${dir}/secret" ]] || exit 1
    cat "${dir}/secret"
    ;;
  rm)
    [[ -f "${dir}/secret" ]] || exit 1
    rm -f "${dir}/secret"
    ;;
esac
exit 0
STUB
chmod +x "${KC_BIN}/secret-tool" "${KC_BIN}/pass"

# kc_probe BACKEND OP [SECRET] - run one keychain operation in a clean
# subprocess with SCIEBO_KEYCHAIN_BACKEND forced and the stub PATH; prints
# the operation output followed by "rc=<n>".
# shellcheck disable=SC2016  # the -c program expands "$1".."$4" itself
kc_probe() {
  local backend="$1" op="$2" secret="${3:-}"
  env PATH="${KC_BIN}:$PATH" SCIEBO_KEYCHAIN_BACKEND="$backend" KEYCHAIN=1 \
    KEYCHAIN_SERVICE="sciebo-platform-test" RCLONE_REMOTE="platform-acct" \
    KEYCHAIN_CACHE="" KEYCHAIN_CACHE_SET=0 \
    bash -c '
      set -uo pipefail
      source "$1/lib/core.sh"
      source "$1/lib/keychain.sh"
      case "$2" in
        store) keychain_store_plain "$3" ;;
        lookup) keychain_lookup_plain ;;
        delete) keychain_delete ;;
      esac
      printf "rc=%s\n" "$?"
    ' kc-probe "$PROJ" "$op" "$secret" 2>&1
}

secret="obscured-secret-tool-value"
rm -f "${KC_BIN}/secret" "${KC_BIN}/stdin.log"
: >"${KC_BIN}/args.log"
out="$(kc_probe secret-tool store "$secret")"
expect_contains "keychain secret-tool: store rc 0" "$out" "rc=0"
args="$(cat "${KC_BIN}/args.log")"
expect_contains "keychain secret-tool: label and attributes" "$args" \
  $'store\n--label\nsciebo-platform-test (platform-acct#plain)\nservice\nsciebo-platform-test\naccount\nplatform-acct#plain'
expect_not_contains "keychain secret-tool: secret never in argv" "$args" "$secret"
expect_eq "keychain secret-tool: secret on stdin" "$secret" "$(cat "${KC_BIN}/stdin.log")"

: >"${KC_BIN}/args.log"
out="$(kc_probe secret-tool lookup)"
expect_eq "keychain secret-tool: lookup returns the secret" "$(printf '%src=0' "$secret")" "$out"
expect_contains "keychain secret-tool: lookup attributes" "$(cat "${KC_BIN}/args.log")" \
  $'lookup\nservice\nsciebo-platform-test\naccount\nplatform-acct#plain'

: >"${KC_BIN}/args.log"
out="$(kc_probe secret-tool delete)"
expect_eq "keychain secret-tool: delete rc 0" "rc=0" "$out"
expect_contains "keychain secret-tool: delete clears the item" "$(cat "${KC_BIN}/args.log")" "clear"
expect_no_file "keychain secret-tool: item removed" "${KC_BIN}/secret"
expect_eq "keychain secret-tool: delete absent rc 0" "rc=0" "$(kc_probe secret-tool delete)"

secret="obscured-pass-value"
rm -f "${KC_BIN}/secret" "${KC_BIN}/stdin.log"
: >"${KC_BIN}/args.log"
out="$(kc_probe pass store "$secret")"
expect_contains "keychain pass: store rc 0" "$out" "rc=0"
args="$(cat "${KC_BIN}/args.log")"
expect_contains "keychain pass: store under rclone-sciebo/<service>/<account>" "$args" \
  $'insert\n-m\n-f\nrclone-sciebo/sciebo-platform-test/platform-acct#plain'
expect_not_contains "keychain pass: secret never in argv" "$args" "$secret"
expect_eq "keychain pass: secret on stdin" "$secret" "$(cat "${KC_BIN}/stdin.log")"

: >"${KC_BIN}/args.log"
out="$(kc_probe pass lookup)"
expect_eq "keychain pass: lookup returns the first line" "$(printf '%src=0' "$secret")" "$out"
expect_contains "keychain pass: lookup path" "$(cat "${KC_BIN}/args.log")" \
  $'show\nrclone-sciebo/sciebo-platform-test/platform-acct#plain'

: >"${KC_BIN}/args.log"
out="$(kc_probe pass delete)"
expect_eq "keychain pass: delete rc 0" "rc=0" "$out"
expect_contains "keychain pass: delete removes the entry" "$(cat "${KC_BIN}/args.log")" \
  $'rm\n-f\nrclone-sciebo/sciebo-platform-test/platform-acct#plain'
expect_no_file "keychain pass: entry removed" "${KC_BIN}/secret"
expect_eq "keychain pass: delete absent rc 0" "rc=0" "$(kc_probe pass delete)"

# --- systemd schedule rendering (direct) -------------------------------------
service_content="$(SCHEDULE_JITTER=0 schedule_systemd_service_content)"
timer_content="$(SCHEDULE_INTERVAL="" SCHEDULE_JITTER=0 SCHEDULE_HOUR=12 SCHEDULE_MINUTE=30 schedule_systemd_timer_content)"
expect_contains "systemd render: ExecStart" "$service_content" \
  "ExecStart=${SCIEBO_BASH} ${PROJ}/bin/sciebo sync --apply --quiet"
expect_contains "systemd render: label recorded" "$service_content" "$LAUNCHD_LABEL"
expect_contains "systemd render: OnCalendar from SCHEDULE_HOUR/MINUTE" "$timer_content" \
  "OnCalendar=*-*-* 12:30:00"
expect_contains "systemd render: timer install target" "$timer_content" "WantedBy=timers.target"

timer_content="$(SCHEDULE_INTERVAL=3600 SCHEDULE_JITTER=120 schedule_systemd_timer_content)"
expect_contains "systemd render: interval uses OnUnitActiveSec" "$timer_content" "OnUnitActiveSec=3600s"
expect_not_contains "systemd render: interval disables OnCalendar" "$timer_content" "OnCalendar"
expect_contains "systemd render: jitter uses RandomizedDelaySec" "$timer_content" "RandomizedDelaySec=120s"

watch_dir="${TMP}/watched path"
mkdir -p "$watch_dir"
watch_content="$(SCHEDULE_WATCH_PATH="$watch_dir" schedule_systemd_watch_content)"
expect_contains "systemd render: watch uses PathChanged" "$watch_content" "PathChanged=${watch_dir}"

# --- systemd schedule install/status/uninstall (stubbed systemctl) ----------
SYSTEMD_BIN="${TMP}/systemd-bin"
mkdir -p "$SYSTEMD_BIN"
cat >"${SYSTEMD_BIN}/systemctl" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$(dirname "$0")/calls.log"
exit "${SYSTEMCTL_RC:-0}"
STUB
chmod +x "${SYSTEMD_BIN}/systemctl"
mkdir -p "${TMP}/home"
unit_dir="${TMP}/home/.config/systemd/user"
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_cli_systemd() {
  (cd "$TMP" && env HOME="${TMP}/home" SCIEBO_SCHEDULER_BACKEND=systemd \
    PATH="${SYSTEMD_BIN}:$PATH" bash "${PROJ}/bin/sciebo" "$@")
}
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_cli_systemd_down() {
  (cd "$TMP" && env HOME="${TMP}/home" SCIEBO_SCHEDULER_BACKEND=systemd SYSTEMCTL_RC=1 \
    PATH="${SYSTEMD_BIN}:$PATH" bash "${PROJ}/bin/sciebo" "$@")
}

: >"${SYSTEMD_BIN}/calls.log"
expect_cli "schedule systemd: install rc 0" 0 run_cli_systemd schedule install
expect_file "schedule systemd: service unit written" "${unit_dir}/${LAUNCHD_LABEL}.service"
expect_file "schedule systemd: timer unit written" "${unit_dir}/${LAUNCHD_LABEL}.timer"
expect_contains "schedule systemd: install names the timer unit" "$CLI_OUT" \
  "Installed ${unit_dir}/${LAUNCHD_LABEL}.timer"
expect_contains "schedule systemd: unit ExecStart" "$(cat "${unit_dir}/${LAUNCHD_LABEL}.service")" \
  "ExecStart=${SCIEBO_BASH} ${PROJ}/bin/sciebo sync --apply --quiet"
expect_contains "schedule systemd: unit OnCalendar" "$(cat "${unit_dir}/${LAUNCHD_LABEL}.timer")" \
  "OnCalendar=*-*-* 12:30:00"
calls="$(cat "${SYSTEMD_BIN}/calls.log")"
expect_contains "schedule systemd: daemon-reload called" "$calls" "--user daemon-reload"
expect_contains "schedule systemd: timer enabled" "$calls" \
  "--user enable --now ${LAUNCHD_LABEL}.timer"

expect_cli "schedule systemd: status loaded rc 0" 0 run_cli_systemd schedule status
expect_contains "schedule systemd: status loaded wording" "$CLI_OUT" "installed and loaded"
expect_contains "schedule systemd: status reports the schedule" "$CLI_OUT" "schedule:"

expect_cli "schedule systemd: status unloaded rc 1" 1 run_cli_systemd_down schedule status
expect_contains "schedule systemd: status unloaded wording" "$CLI_OUT" "installed but not loaded"

: >"${SYSTEMD_BIN}/calls.log"
expect_cli "schedule systemd: uninstall rc 0" 0 run_cli_systemd schedule uninstall
expect_no_file "schedule systemd: service unit removed" "${unit_dir}/${LAUNCHD_LABEL}.service"
expect_no_file "schedule systemd: timer unit removed" "${unit_dir}/${LAUNCHD_LABEL}.timer"
expect_contains "schedule systemd: disable recorded" "$(cat "${SYSTEMD_BIN}/calls.log")" \
  "--user disable --now ${LAUNCHD_LABEL}.timer"
expect_cli "schedule systemd: status after uninstall rc 0" 0 run_cli_systemd schedule status
expect_contains "schedule systemd: reports not installed" "$CLI_OUT" "not installed"

# --- doctor reports the macOS backends and stays green offline ---------------
if [[ "$(platform_os)" == "macos" ]]; then
  # shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
  run_cli_doctor_platform() {
    (cd "$TMP" && env HOME="${TMP}/home" RCLONE_REMOTE=webtest bash "${PROJ}/bin/sciebo" doctor --offline)
  }
  expect_cli "doctor: offline rc 0 on macOS" 0 run_cli_doctor_platform
  expect_contains "doctor: scheduler backend line" "$CLI_OUT" "scheduler backend: launchd"
  expect_contains "doctor: keychain backend line" "$CLI_OUT" "keychain backend: security"
  expect_contains "doctor: notifications backend line" "$CLI_OUT" "notifications backend: osascript"
fi

finish
