#!/usr/bin/env bash
# ui.sh - selection parsing and confirmation prompts (lib/base/ui.sh).
# Sourced setup lives in tests/unit/common.sh; run standalone with
# `bash tests/unit/ui.sh`.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# --- ui_parse_selection -------------------------------------------------
out="$(ui_parse_selection '3,1,3,1' 5)"
rc=$?
expect_rc "ui_parse_selection: duplicates rc" "$rc" 0
expect_eq "ui_parse_selection: duplicates deduped and ordered" "$(printf '1\n3')" "$out"
while IFS='|' read -r name input max want rc_want; do
  rc=0
  out="$(ui_parse_selection "$input" "$max")" || rc=$?
  if [[ "$rc_want" -eq 0 ]]; then
    expect_rc "${name} rc" "$rc" 0
    expect_eq "$name" "$(printf '%b' "$want")" "$out"
  else
    expect_rc "$name" "$rc" 1
  fi
done <<'EOF'
ui_parse_selection: '1 3'|1 3|5|1\n3|0
ui_parse_selection: '1,3'|1,3|5|1\n3|0
ui_parse_selection: '5-7'|5-7|7|5\n6\n7|0
ui_parse_selection: 'all'|all|3|1\n2\n3|0
ui_parse_selection: '0' invalid rc 1|0|5||1
ui_parse_selection: out of range invalid rc 1|4|3||1
ui_parse_selection: inverted range invalid rc 1|7-5|7||1
ui_parse_selection: non-numeric invalid rc 1|x|5||1
ui_parse_selection: empty invalid rc 1||5||1
EOF

# --- ui_confirm_tty / ui_confirm_mutation_soft ----------------------------
# The gate reads the terminal check through ui_stdin_tty, so the matrix runs
# without a pty: the redefinition plays the terminal (the same substitution
# pattern as hydrate's progress_stdout_tty stub), while ui_confirm still
# answers from stdin.
ui_stdin_tty() { return 0; }
rc=0
out="$(ui_confirm_tty "proceed?" <<<'y')" || rc=$?
expect_rc "ui_confirm_tty: y on a promptable tty rc" "$rc" 0
rc=0
out="$(ui_confirm_tty "proceed?" <<<'Yes')" || rc=$?
expect_rc "ui_confirm_tty: Yes accepted (unified dialect)" "$rc" 0
rc=0
out="$(ui_confirm_tty "proceed?" <<<'yEs')" || rc=$?
expect_rc "ui_confirm_tty: yEs accepted (mixed case)" "$rc" 0
rc=0
out="$(ui_confirm_tty "proceed?" <<<'n')" || rc=$?
expect_rc "ui_confirm_tty: decline rc" "$rc" 1
rc=0
out="$(ui_confirm_tty "proceed?" <<<'')" || rc=$?
expect_rc "ui_confirm_tty: empty answer declines" "$rc" 1
rc=0
out="$(SCIEBO_NON_INTERACTIVE=1 ui_confirm_tty "proceed?" <<<'y')" || rc=$?
expect_rc "ui_confirm_tty: SCIEBO_NON_INTERACTIVE is not promptable" "$rc" 2
expect_eq "ui_confirm_tty: not promptable asks nothing" "" "$out"
ui_stdin_tty() { return 1; }
rc=0
out="$(ui_confirm_tty "proceed?" <<<'y')" || rc=$?
expect_rc "ui_confirm_tty: non-tty is not promptable" "$rc" 2
expect_eq "ui_confirm_tty: non-tty asks nothing" "" "$out"
ui_stdin_tty() { [[ -t 0 ]]; }

OPT_yes=1
rc=0
out="$(ui_confirm_mutation_soft optprobe "needs --yes" "proceed?" <<<'n')" || rc=$?
expect_rc "soft: --yes skips the prompt rc" "$rc" 0
expect_eq "soft: --yes asks nothing" "" "$out"
OPT_yes=0
ui_stdin_tty() { return 1; }
rc=0
out="$(ui_confirm_mutation_soft optprobe "needs --yes" "proceed?" 2>&1 <<<'y')" || rc=$?
expect_rc "soft: non-interactive without --yes exits 2" "$rc" 2
expect_contains "soft: refusal names the requirement" "$out" "needs --yes"
ui_stdin_tty() { return 0; }
rc=0
out="$(ui_confirm_mutation_soft optprobe "needs --yes" "proceed?" <<<'y')" || rc=$?
expect_rc "soft: yes on a promptable tty rc" "$rc" 0
rc=0
out="$(ui_confirm_mutation_soft optprobe "needs --yes" "proceed?" \
  "aborted, nothing changed" <<<'n' 2>&1)" || rc=$?
expect_rc "soft: decline returns 1 without exiting" "$rc" 1
expect_contains "soft: decline logs DECLINE_MSG" "$out" "aborted, nothing changed"
rc=0
out="$(ui_confirm_mutation_soft optprobe "needs --yes" "proceed?" <<<'n' 2>&1)" || rc=$?
expect_rc "soft: decline without DECLINE_MSG returns 1" "$rc" 1
expect_not_contains "soft: silent decline logs nothing" "$out" "aborted"
# Restore the real gate after the substituted stubs above; shellcheck counts
# only those stubs as invocations.
# shellcheck disable=SC2329  # restored implementation for later interactive checks
ui_stdin_tty() { [[ -t 0 ]]; }
unset OPT_yes

finish
