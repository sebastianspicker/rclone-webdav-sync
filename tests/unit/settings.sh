#!/usr/bin/env bash
# settings.sh - settings precedence and bisync_initialized (lib/config/settings.sh).
# Sourced setup lives in tests/unit/common.sh; run standalone with
# `bash tests/unit/settings.sh`.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# --- settings precedence (subprocesses) ---------------------------------
SETTINGS_ENV="${TMP}/settings.env"
cp "${PROJ_DIR}/config/settings.env" "$SETTINGS_ENV"
NO_LOCAL="${TMP}/settings.local.absent.env"
SETTINGS_STATE="${TMP}/state-settings"
LOCAL_ENV="${TMP}/settings.local.env"
printf 'REMOTE_BASE="localbase"\n' >"$LOCAL_ENV"
export SETTINGS_FILE="$SETTINGS_ENV" SETTINGS_LOCAL_FILE="$NO_LOCAL" STATE_DIR="$SETTINGS_STATE"
probe_case "settings: env override rc 0" "settings: environment beats settings.env" \
  REMOTE_BASE 0 eq envbase REMOTE_BASE=envbase
probe_case "settings: local override rc 0" "settings: settings.local.env plain assignment beats env" \
  REMOTE_BASE 0 eq localbase REMOTE_BASE=envbase SETTINGS_LOCAL_FILE="$LOCAL_ENV"
probe_case "settings: derived LOG_DIR rc 0" "settings: LOG_DIR defaults under STATE_DIR" \
  LOG_DIR 0 eq "${SETTINGS_STATE}/logs"
probe_case "settings: derived LOCK_DIR rc 0" "settings: LOCK_DIR defaults under STATE_DIR" \
  LOCK_DIR 0 eq "${SETTINGS_STATE}/locks"
probe_case "settings: explicit LOG_DIR rc 0" "settings: explicit LOG_DIR wins over derivation" \
  LOG_DIR 0 eq "${TMP}/custom-logs" LOG_DIR="${TMP}/custom-logs"
probe_case "settings: empty REMOTE_BASE rc 0" "settings: empty REMOTE_BASE falls back to backup" \
  REMOTE_BASE 0 eq backup REMOTE_BASE=
probe_case "settings: ../ REMOTE_BASE dies rc 1" "settings: ../ REMOTE_BASE message" \
  REMOTE_BASE 1 contains "must be a relative path without '..'" REMOTE_BASE=../x
probe_case "settings: missing SETTINGS_FILE dies rc 1" "settings: missing SETTINGS_FILE message" \
  REMOTE_BASE 1 contains "Missing settings file" SETTINGS_FILE="${TMP}/missing-settings.env"
probe_case "settings: TRANSFERS=abc dies rc 1" "settings: TRANSFERS=abc message" \
  TRANSFERS 1 contains "must be a non-negative integer" TRANSFERS=abc
probe_case "settings: KEYCHAIN=2 dies rc 1" "settings: KEYCHAIN=2 message" \
  KEYCHAIN 1 contains "must be 0 or 1" KEYCHAIN=2
probe_case "settings: MAX_DELETE=-2 dies rc 1" "settings: MAX_DELETE=-2 message" \
  MAX_DELETE 1 contains "integer >= -1" MAX_DELETE=-2
probe_case "settings: DEFAULT_PAIR_MODE=zzz dies rc 1" "settings: DEFAULT_PAIR_MODE=zzz message" \
  DEFAULT_PAIR_MODE 1 contains "must be one of sync, pull, bisync" DEFAULT_PAIR_MODE=zzz
probe_case "settings: REMOTE_BASE pipe dies rc 1" "settings: REMOTE_BASE pipe message" \
  REMOTE_BASE 1 contains "must not contain '|' or control bytes" 'REMOTE_BASE=a|b'
probe_case "settings: empty BW_LIMIT_UP rc 0" "settings: empty BW_LIMIT_UP accepted" \
  BW_LIMIT_UP 0 eq "" BW_LIMIT_UP=
probe_case "settings: derived RUNSTATE_DIR rc 0" "settings: RUNSTATE_DIR defaults under STATE_DIR" \
  RUNSTATE_DIR 0 eq "${SETTINGS_STATE}/last"

# ensure_state_dirs must create the per-source last-run directory too.
runstate_root="${TMP}/runstate-dirs"
(
  STATE_DIR="$runstate_root" LOG_DIR="${runstate_root}/logs" LOCK_DIR="${runstate_root}/locks" \
    BISYNC_DIR="${runstate_root}/bisync" RUNSTATE_DIR="" ensure_state_dirs
)
expect_ok "ensure_state_dirs: creates RUNSTATE_DIR" test -d "${runstate_root}/last"

# --- bisync_initialized ignores dry-run residue -------------------------
# BISYNC_DIR is normally derived by load_settings/ensure_state_dirs (covered
# above); this section only needs some writable directory to hold the
# per-source bisync state files bisync_initialized inspects.
BISYNC_DIR="${TMP}/bisync-initialized"
mkdir -p "${BISYNC_DIR}/dry-only"
: >"${BISYNC_DIR}/dry-only/notes.path1.lst-dry"
expect_err "bisync_initialized: only *-dry residue is uninitialized" bisync_initialized "dry-only"
mkdir -p "${BISYNC_DIR}/real"
: >"${BISYNC_DIR}/real/notes.path1.lst"
expect_ok "bisync_initialized: real state is initialized" bisync_initialized "real"
expect_err "bisync_initialized: missing directory" bisync_initialized "missing"

finish
