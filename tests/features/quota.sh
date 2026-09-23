#!/usr/bin/env bash
# quota.sh - `rclone about` wrapper against the local testremote.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

# rclone's local backend implements `about` for an existing directory below
# the remote root; run_cli executes from TMP, so testremote:backup resolves
# to TMP/backup.
mkdir -p "${TMP}/backup"

expect_cli "quota: plain rc 0" 0 run_cli quota
expect_contains "quota: total reported" "$CLI_OUT" "Total:"
expect_contains "quota: free reported" "$CLI_OUT" "Free:"

expect_cli "quota: --json rc 0" 0 run_cli quota --json
expect_contains "quota: JSON total" "$CLI_OUT" '"total"'
expect_contains "quota: JSON free" "$CLI_OUT" '"free"'

rm -rf "${TMP}/backup"
expect_cli "quota: missing path fails cleanly" 1 run_cli quota
expect_contains "quota: rclone error surfaced" "$CLI_OUT" "directory not found"
expect_contains "quota: failure names rclone" "$CLI_OUT" "rclone about"

finish
