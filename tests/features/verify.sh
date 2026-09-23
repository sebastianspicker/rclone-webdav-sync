#!/usr/bin/env bash
# verify.sh - `sciebo verify`: read-only consistency check via `rclone check`.
# The real `testremote` local backend is used, so checks are fast and
# network-free; the manifest and both trees live under the suite temp dir.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

# Fixture: a sync source mirrored under REMOTE_BASE (testremote:backup/...).
# run_cli runs from $TMP, which is where the bare local remote is rooted.
VS="${TMP}/verify-src"
RS="${TMP}/backup/verify-src"
mkdir -p "$VS" "$RS"
printf 'hello\n' >"$VS/hello.txt"
printf 'hello\n' >"$RS/hello.txt"
printf 'sync|%s|verify-src\n' "$VS" >"$MANIFEST_FILE"

# --- a matching source succeeds with an OK row and a clean summary --------
expect_cli "verify: matching source rc 0" 0 run_cli verify --only verify-src
expect_contains "verify: OK row" "$CLI_OUT" "OK   sync"
expect_contains "verify: OK row names the source" "$CLI_OUT" "verify-src"
expect_contains "verify: clean summary" "$CLI_OUT" "Summary: 1 sources (1 ok, 0 failed, 0 skipped)"

# --- an extra local file fails with a FAIL row naming the file -------------
printf 'unsynced\n' >"$VS/extra.txt"
expect_cli "verify: extra local file rc 1" 1 run_cli verify --only verify-src
expect_contains "verify: extra file FAIL row" "$CLI_OUT" "FAIL sync"
expect_contains "verify: extra file named" "$CLI_OUT" "extra.txt"
expect_contains "verify: extra file difference count" "$CLI_OUT" "differences"
expect_contains "verify: failed summary" "$CLI_OUT" "Summary: 1 sources (0 ok, 1 failed, 0 skipped)"
rm -f "$VS/extra.txt"

# --- a changed local file fails by default but passes --size-only ----------
# 'world' has the same length as 'hello', so --size-only deliberately skips
# the hash comparison that catches the content change.
printf 'world\n' >"$VS/hello.txt"
expect_cli "verify: changed local file rc 1" 1 run_cli verify --only verify-src
expect_contains "verify: changed file FAIL row" "$CLI_OUT" "FAIL sync"
expect_contains "verify: changed file named" "$CLI_OUT" "hello.txt"
expect_cli "verify: --size-only ignores a same-size change rc 0" 0 \
  run_cli verify --only verify-src --size-only
expect_contains "verify: --size-only OK row" "$CLI_OUT" "OK   sync"
printf 'hello\n' >"$VS/hello.txt"

# --- --quiet hides OK rows but still prints the summary -------------------
expect_cli "verify: --quiet rc 0" 0 run_cli verify --only verify-src --quiet
expect_not_contains "verify: --quiet hides the OK row" "$CLI_OUT" "OK   sync"
expect_contains "verify: --quiet keeps the summary" "$CLI_OUT" \
  "Summary: 1 sources (1 ok, 0 failed, 0 skipped)"

# --- a missing local sync directory fails with a reason -------------------
printf 'sync|%s|verify-missing\n' "${TMP}/no-such-verify-dir" >>"$MANIFEST_FILE"
expect_cli "verify: missing local dir rc 1" 1 run_cli verify --only verify-missing
expect_contains "verify: missing local dir reason" "$CLI_OUT" "local directory does not exist"

# --- guards: unknown source, --json unsupported, help ---------------------
expect_cli "verify: unknown source rc 1" 1 run_cli verify --only unknown
expect_contains "verify: unknown source message" "$CLI_OUT" "No source named"
# verify prints a human table only; --json is not a supported option.
expect_cli "verify: --json rejected rc 2" 2 run_cli verify --json
expect_contains "verify: --json unknown option" "$CLI_OUT" "unknown option"
expect_cli "verify: --help rc 0" 0 run_cli verify --help
expect_contains "verify: usage documents --only" "$CLI_OUT" "--only"

# --- pure output helpers replace the per-line sed and grep|tail pipelines ----
# shellcheck source=../../lib/commands/verify.sh
source "${PROJ}/lib/commands/verify.sh"
expect_eq "verify: strips ANSI escapes" "red" "$(verify_strip_ansi $'\033[31mred\033[0m')"
expect_eq "verify: keeps a plain line" "plain" "$(verify_strip_ansi 'plain')"
expect_eq "verify: leaves an unterminated escape" $'\033[' "$(verify_strip_ansi $'\033[')"
expect_eq "verify: counts differences" " (3 differences)" "$(verify_counts '3 differences found')"
expect_eq "verify: counts differences and errors" " (2 differences, 1 errors)" \
  "$(verify_counts $'2 differences found\n1 errors')"
expect_eq "verify: zero differences are omitted" " (1 errors)" \
  "$(verify_counts $'0 differences found\n1 errors')"

finish
