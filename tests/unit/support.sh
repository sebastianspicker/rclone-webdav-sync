#!/usr/bin/env bash
# support.sh - the newest-files sort/cap helper (lib/commands/support.sh).
# Sourced setup lives in tests/unit/common.sh; run standalone with
# `bash tests/unit/support.sh`.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/commands/support.sh
source "${LIB_DIR}/commands/support.sh"

# --- support_sort_capped: small, easily-checked ordering ------------------
small_list=$'30 c.txt\n10 a.txt\n20 b.txt'
expect_eq "support_sort_capped: newest first, all rows" "$(printf '%s\n' c.txt b.txt a.txt)" \
  "$(support_sort_capped "$small_list" 3)"
expect_eq "support_sort_capped: limit caps the rows" "c.txt" "$(support_sort_capped "$small_list" 1)"

# --- support_sort_capped: input larger than one pipe buffer must not trip
# SIGPIPE. The old implementation (`sort -rn | head -n N`) fails under
# `pipefail` once `head` exits early and closes the pipe on `sort`
# mid-write; `mapfile -n` reading from a process substitution does not.
big_list=""
for ((i = 0; i < 20000; i++)); do
  big_list="${big_list}${i} file$(printf '%05d' "$i").txt"$'\n'
done
rc=0
out="$(support_sort_capped "$big_list" 5)" || rc=$?
expect_eq "support_sort_capped: large input succeeds (rc 0)" "0" "$rc"
expect_eq "support_sort_capped: large input returns exactly 5 rows" "5" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
expect_contains "support_sort_capped: large input keeps the newest" "$out" "file19999.txt"
expect_not_contains "support_sort_capped: large input caps the list" "$out" "file00000.txt"

finish
