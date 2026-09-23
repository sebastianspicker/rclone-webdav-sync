#!/usr/bin/env bash
# cleanup_cache.sh - `cleanup --cache`, `cleanup --support`, the
# LOG_EXPIRE_HOURS override for `cleanup --logs`, and the narrowed
# `cleanup --state` temp-file gate.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

export STATE_CLEANUP_MIN_AGE=24h
CACHE_DIR="${TMP}/mount-cache"
export MOUNT_CACHE_DIR="$CACHE_DIR"
mkdir -p "$CACHE_DIR"
old_cache="${CACHE_DIR}/old.bin"
new_cache="${CACHE_DIR}/new.bin"
: >"$old_cache"
: >"$new_cache"
touch -t 202001010000 "$old_cache"

# Dry run reports the old file and deletes nothing.
expect_cli "cleanup cache: dry run rc 0" 0 run_cli cleanup --cache
expect_contains "cleanup cache: lists the old file" "$CLI_OUT" "would delete ${old_cache}"
expect_contains "cleanup cache: summary" "$CLI_OUT" "cache: 1 candidate(s), 0 deleted"
expect_not_contains "cleanup cache: fresh file is age-gated" "$CLI_OUT" "$new_cache"
expect_file "cleanup cache: dry run keeps the old file" "$old_cache"
expect_file "cleanup cache: dry run keeps the fresh file" "$new_cache"

# Apply deletes only the old file.
expect_cli "cleanup cache: apply rc 0" 0 run_cli cleanup --cache --apply
expect_no_file "cleanup cache: apply removes the old file" "$old_cache"
expect_file "cleanup cache: apply keeps the fresh file" "$new_cache"
expect_contains "cleanup cache: apply summary" "$CLI_OUT" "cache: 1 candidate(s), 1 deleted"

# A missing cache directory is a no-op.
rm -rf "$CACHE_DIR"
expect_cli "cleanup cache: missing dir rc 0" 0 run_cli cleanup --cache
expect_contains "cleanup cache: missing dir message" "$CLI_OUT" "cache: nothing to do"

# At most five examples are listed in a dry run.
mkdir -p "$CACHE_DIR"
for i in 1 2 3 4 5 6 7; do : >"${CACHE_DIR}/many-${i}.bin"; done
touch -t 202001010000 "${CACHE_DIR}"/many-*.bin
expect_cli "cleanup cache: example cap rc 0" 0 run_cli cleanup --cache
expect_eq "cleanup cache: exactly five examples" "5" "$(printf '%s\n' "$CLI_OUT" | grep -c "would delete ")"
expect_contains "cleanup cache: example cap summary" "$CLI_OUT" "cache: 7 candidate(s), 0 deleted"
rm -rf "$CACHE_DIR"

# --- cleanup --support: keep the newest N archives ------------------------
old_support="${STATE_DIR}/support-20200101-000000.tar.gz"
mid_support="${STATE_DIR}/support-20210101-000000.tar.gz"
new_support="${STATE_DIR}/support-20220101-000000.tar.gz"
: >"$old_support"
: >"$mid_support"
: >"$new_support"
touch -t 202001010000 "$old_support"
touch -t 202101010000 "$mid_support"
touch -t 202201010000 "$new_support"

# The default keeps the newest five: nothing is a candidate here.
expect_cli "cleanup support: default dry run rc 0" 0 run_cli cleanup --support
expect_contains "cleanup support: default keeps all" "$CLI_OUT" "support: 0 candidate(s), 0 deleted"
expect_file "cleanup support: default keeps the oldest" "$old_support"

# A dry run reports the older archives and deletes nothing.
expect_cli "cleanup support: keep 1 dry run rc 0" 0 run_cli cleanup --support --keep 1
expect_contains "cleanup support: reports the oldest" "$CLI_OUT" "would delete ${old_support}"
expect_contains "cleanup support: keep 1 summary" "$CLI_OUT" "support: 2 candidate(s), 0 deleted"
expect_file "cleanup support: dry run keeps everything" "$old_support"

# --keep 1 --apply keeps only the newest archive.
expect_cli "cleanup support: keep 1 apply rc 0" 0 run_cli cleanup --support --keep 1 --apply
expect_no_file "cleanup support: apply removes the oldest" "$old_support"
expect_no_file "cleanup support: apply removes the middle" "$mid_support"
expect_file "cleanup support: apply keeps the newest" "$new_support"

# --keep without --support and a bad value are usage errors.
expect_cli "cleanup support: --keep without --support rc 2" 2 run_cli cleanup --keep 1
expect_cli "cleanup support: --keep non-numeric rc 2" 2 run_cli cleanup --support --keep x
rm -f "$new_support"

# --- cleanup --logs: LOG_EXPIRE_HOURS overrides LOG_RETENTION_DAYS --------
export LOG_RETENTION_DAYS=36500
LOG_DIR="${STATE_DIR}/logs"
mkdir -p "$LOG_DIR"
expire_log="${LOG_DIR}/expire.log"
: >"$expire_log"
touch -t 202001010000 "$expire_log"

unset LOG_EXPIRE_HOURS
expect_cli "cleanup logs: days retention rc 0" 0 run_cli cleanup --logs
expect_not_contains "cleanup logs: days retention keeps the log" "$CLI_OUT" "would delete ${expire_log}"
expect_file "cleanup logs: days retention does not delete" "$expire_log"

export LOG_EXPIRE_HOURS=1
expect_cli "cleanup logs: hours override rc 0" 0 run_cli cleanup --logs
expect_contains "cleanup logs: hours override lists the log" "$CLI_OUT" "would delete ${expire_log}"
expect_contains "cleanup logs: hours override label" "$CLI_OUT" "older than 1 hour(s)"
expect_file "cleanup logs: hours override dry run keeps" "$expire_log"

expect_cli "cleanup logs: hours override apply rc 0" 0 run_cli cleanup --logs --apply
expect_no_file "cleanup logs: hours override deletes the log" "$expire_log"
unset LOG_EXPIRE_HOURS

# --- cleanup --state: only atomic-write staging files are removed -----------
# atomic_write stages into <file>.tmp.XXXXXX (exactly six characters), so
# the scan is narrowed to that shape: an ordinary user file that merely
# contains ".tmp." survives even when it is older than the age threshold.
user_tmp="${STATE_DIR}/notes.tmp.draft"
staged_tmp="${STATE_DIR}/settings.env.tmp.ab12cd"
printf 'user draft\n' >"$user_tmp"
printf 'stale staging\n' >"$staged_tmp"
touch -t 202001010000 "$user_tmp" "$staged_tmp"

expect_cli "cleanup state: tmp dry run rc 0" 0 run_cli cleanup --state
expect_contains "cleanup state: staging file reported" "$CLI_OUT" "would remove ${staged_tmp}"
expect_not_contains "cleanup state: user .tmp. file not reported" "$CLI_OUT" "would remove ${user_tmp}"
expect_file "cleanup state: dry run keeps staging file" "$staged_tmp"
expect_file "cleanup state: dry run keeps user file" "$user_tmp"

expect_cli "cleanup state: tmp apply rc 0" 0 run_cli cleanup --state --apply
expect_no_file "cleanup state: apply removes staging file" "$staged_tmp"
expect_file "cleanup state: apply keeps user .tmp. file" "$user_tmp"

finish
