#!/usr/bin/env bash
# common.sh - shared setup for tests/unit/*.sh (rclone is not required).
# Sourced by each tests/unit/<module>.sh, never run directly.
#
# Isolation: every path is redirected into a fresh mktemp directory; the
# real config, state, HOME, rclone config, sciebo and launchd are never
# touched. Settings precedence runs in clean subprocesses.
set -uo pipefail
UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${UNIT_DIR}/../.." && pwd)"
LIB_DIR="${PROJ_DIR}/lib"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../harness.sh
source "${UNIT_DIR}/../harness.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/sciebo.sh
source "${LIB_DIR}/sciebo.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/commands/sync.sh
source "${LIB_DIR}/commands/sync.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/commands/schedule.sh
source "${LIB_DIR}/commands/schedule.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/commands/cleanup.sh
source "${LIB_DIR}/commands/cleanup.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/commands/trash.sh
source "${LIB_DIR}/commands/trash.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/commands/versions.sh
source "${LIB_DIR}/commands/versions.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/commands/mount.sh
source "${LIB_DIR}/commands/mount.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/sciebo-unit.XXXXXX")"
# Route every child/probe temp (e.g. the case-clash scan cache) under TMP so
# the EXIT cleanup removes them, and drop registered temps explicitly.
export TMPDIR="$TMP"
export SETTINGS_FILE="${PROJ_DIR}/config/settings.env" \
  SETTINGS_LOCAL_FILE="${TMP}/settings.local.absent.env" ENV_FILE="${TMP}/env.absent.env" \
  STATE_DIR="${TMP}/state" MANIFEST_FILE="${TMP}/sources.conf" \
  MANIFEST_GENERATED_FILE="${TMP}/sources.generated.conf" FOLDERS_FILE="${TMP}/folders.conf" \
  FILTER_DIR="${TMP}/filters"
mkdir -p "$FILTER_DIR"

# Derived state paths (LOG_DIR/LOCK_DIR/BISYNC_DIR) stay unset here so the
# settings probes observe the libraries' defaults.
BG_PID=""
# shellcheck disable=SC2329  # invoked through the EXIT trap
cleanup() {
  if [[ -n "$BG_PID" ]]; then
    kill "$BG_PID" 2>/dev/null || true
    wait "$BG_PID" 2>/dev/null || true
  fi
  sciebo_temp_cleanup || true
  rm -rf "$TMP"
}
trap cleanup EXIT
printf 'sciebo unit tests (%s)\n' "$PROJ_DIR"

# expect_run NAME WANT_RC CMD... - pass when CMD exits WANT_RC (globals it
# sets stay visible to the caller).
expect_run() {
  local name="$1" want="$2" rc=0
  shift 2
  "$@" >/dev/null 2>&1 || rc=$?
  expect_rc "$name" "$rc" "$want"
}

# expect_ok/expect_err NAME CMD... - pass when CMD exits 0/non-zero.
expect_ok() { expect_run "$1" 0 "${@:2}"; }
expect_err() { expect_run "$1" 1 "${@:2}"; }

# expect_dies NAME CMD... - like expect_err, but in a subshell, so a die
# inside CMD cannot end the test suite.
expect_dies() {
  local name="$1" rc=0
  shift
  ("$@" >/dev/null 2>&1) || rc=$?
  expect_rc "$name" "$rc" 1
}

# settings_probe VAR [ENV=...]... - print VAR after load_settings --no-rclone
# in a clean subprocess; die output and rc are preserved.
settings_probe() {
  local var="$1"
  shift
  # shellcheck disable=SC2016  # the -c program expands "$1"/"$2" itself
  env "$@" bash -c '
    set -uo pipefail
    source "$1/lib/sciebo.sh"
    load_settings --no-rclone
    printf "%s" "${!2}"
  ' sciebo-unit-probe "$PROJ_DIR" "$var" 2>&1
}

# probe_case RC_NAME VALUE_NAME VAR RC_WANT MODE WANT [ENV=...]...
probe_case() {
  local rc_name="$1" value_name="$2" var="$3" rc_want="$4" mode="$5" want="$6"
  shift 6
  local out="" rc=0
  out="$(settings_probe "$var" "$@")" || rc=$?
  expect_rc "$rc_name" "$rc" "$rc_want"
  if [[ "$mode" == eq ]]; then
    expect_eq "$value_name" "$want" "$out"
  else
    expect_contains "$value_name" "$out" "$want"
  fi
}

# write_filter_probe NAME SUB EXCLUDES... - combined output of
# manifest_write_pair_filter run in a clean subprocess.
write_filter_probe() {
  local name="$1" sub="$2"
  shift 2
  # shellcheck disable=SC2016  # the -c program expands "$1" itself
  env FILTER_DIR="$FILTER_DIR" bash -c '
    set -uo pipefail
    source "$1/lib/sciebo.sh"
    manifest_write_pair_filter "$2" "$3" "${@:4}"
  ' probe "$PROJ_DIR" "$name" "$sub" "$@" 2>&1
}

# lock_probe - acquire_lock in a clean subprocess against this shell's lock
# dirs (combined output; same rc).
lock_probe() {
  # shellcheck disable=SC2016  # the -c program expands "$1" itself
  env STATE_DIR="$STATE_DIR" LOG_DIR="$LOG_DIR" LOCK_DIR="$LOCK_DIR" BISYNC_DIR="$BISYNC_DIR" \
    bash -c '
      set -uo pipefail
      source "$1/lib/sciebo.sh"
      acquire_lock
    ' lock-probe "$PROJ_DIR" 2>&1
}
