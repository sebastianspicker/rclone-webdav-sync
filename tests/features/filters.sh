#!/usr/bin/env bash
# filters.sh - `sciebo filters`: fetch the server sync-exclude list, list
# filter files, show one, and validate them with rclone's parser (stub curl).
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

# Paths derived by lib/config/settings.sh from the exported test overrides; kept
# here so the assertions can address them directly.
SERVER_EXCLUDE_FILE="${TMP}/state/sync-exclude.lst"
SERVER_EXCLUDE_FILTER="${TMP}/filters/server-exclude.txt"

# --- sync: fetch, cache, and generate --------------------------------------
stub_clear_calls
stub_reset_routes
stub_route GET '*sync-exclude.lst' 200 <<'LST'
# Nextcloud canonical exclude list

*.tmp
.~lock.*
LST

expect_cli "filters sync: rc 0" 0 run_cli_nc filters sync
expect_contains "filters sync: count and host" "$CLI_OUT" "filters: fetched 2 patterns from 127.0.0.1:9"
expect_file "filters sync: raw cache written" "$SERVER_EXCLUDE_FILE"
expect_contains "filters sync: cache keeps the raw body" "$(cat "$SERVER_EXCLUDE_FILE")" "# Nextcloud canonical exclude list"
expect_file "filters sync: generated filter written" "$SERVER_EXCLUDE_FILTER"
expect_eq "filters sync: one -pattern per rule" "$(cat "$SERVER_EXCLUDE_FILTER")" "- *.tmp
- .~lock.*"
expect_eq "filters sync: comments dropped" "0" "$(grep -c '^#' "$SERVER_EXCLUDE_FILTER" || true)"
expect_contains "filters sync: fetch went through curl" "$(stub_calls)" "sync-exclude.lst"

expect_cli "filters sync --json: rc 0" 0 run_cli_nc filters sync --json
expect_contains "filters sync --json: patterns field" "$CLI_OUT" '"patterns": 2'
expect_contains "filters sync --json: file field" "$CLI_OUT" '"file":'
expect_contains "filters sync --json: source field" "$CLI_OUT" '"source": "http://127.0.0.1:9/sync-exclude.lst"'

# --- list: rows, server flag, cache age ------------------------------------
expect_cli "filters list: rc 0" 0 run_cli_nc filters list
expect_contains "filters list: clutter row" "$CLI_OUT" "clutter.txt"
expect_contains "filters list: generated file row" "$CLI_OUT" "server-exclude.txt"
expect_contains "filters list: server flag" "$CLI_OUT" "yes"
expect_contains "filters list: cache age line" "$CLI_OUT" "server filter cache:"
expect_contains "filters list: cache fresh" "$CLI_OUT" "fresh"

expect_cli "filters list --json: rc 0" 0 run_cli_nc filters list --json
expect_contains "filters list --json: server flag" "$CLI_OUT" '"server": true'
expect_contains "filters list --json: cache not stale" "$CLI_OUT" '"stale": false'
expect_contains "filters list --json: cache max age" "$CLI_OUT" '"max_age": 604800'

# --- show: contents, validated name, missing file ---------------------------
expect_cli "filters show: rc 0" 0 run_cli_nc filters show clutter.txt
expect_contains "filters show: contents" "$CLI_OUT" "- *.part"
expect_cli "filters show: missing file rc 1" 1 run_cli_nc filters show nope.txt
expect_contains "filters show: missing message" "$CLI_OUT" "filter file not found"
expect_cli "filters show: unsafe name rc 1" 1 run_cli_nc filters show ../clutter.txt
expect_contains "filters show: unsafe name message" "$CLI_OUT" "invalid filter name"

# --- check: rclone parses every *.txt ---------------------------------------
expect_cli "filters check: rc 0" 0 run_cli_nc filters check
expect_contains "filters check: clutter passes" "$CLI_OUT" "PASS  clutter.txt"
expect_contains "filters check: generated filter passes" "$CLI_OUT" "PASS  server-exclude.txt"

printf 'garbage\n' >"${FILTER_DIR}/broken.txt"
expect_cli "filters check: bad rule rc 1" 1 run_cli_nc filters check
expect_contains "filters check: bad rule row" "$CLI_OUT" "FAIL  broken.txt"
expect_contains "filters check: good rows still reported" "$CLI_OUT" "PASS  clutter.txt"
rm -f "${FILTER_DIR}/broken.txt"

# --- failure modes ----------------------------------------------------------
stub_reset_routes
stub_route GET '*sync-exclude.lst' 500 <<'LST'
server said no
LST
expect_cli "filters sync: HTTP failure rc 1" 1 run_cli_nc filters sync
expect_contains "filters sync: HTTP failure message" "$CLI_OUT" "failed: HTTP 500"

stub_reset_routes
stub_route GET '*sync-exclude.lst' 200 </dev/null
expect_cli "filters sync: empty body rc 1" 1 run_cli_nc filters sync
expect_contains "filters sync: empty body message" "$CLI_OUT" "empty body"

expect_cli "filters: missing subcommand rc 2" 2 run_cli_nc filters
expect_contains "filters: missing subcommand message" "$CLI_OUT" "missing subcommand"
expect_cli "filters: unknown subcommand rc 2" 2 run_cli_nc filters bogus
expect_contains "filters: unknown subcommand message" "$CLI_OUT" "unknown command"
expect_cli "filters: help rc 0" 0 run_cli_nc filters --help
expect_contains "filters: usage lists sync" "$CLI_OUT" "sync [--json]"

finish
