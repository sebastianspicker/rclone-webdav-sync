#!/usr/bin/env bash
# harness.sh - shared assertion harness for the sciebo test suites.
# Source this file; it never enables `set -e`, so callers keep their own
# error policy. Counters use `:=` so `set -u` callers are safe. Output is
# `PASS  name` / `FAIL  name (detail)`; `finish` prints
# `<N> passed, <M> failed` and exits 1 when any test failed.

: "${HARNESS_PASS:=0}"
: "${HARNESS_FAIL:=0}"

pass() {
  HARNESS_PASS=$((HARNESS_PASS + 1))
  printf 'PASS  %s\n' "$1"
}
fail() {
  HARNESS_FAIL=$((HARNESS_FAIL + 1))
  if [[ $# -gt 1 && -n "${2:-}" ]]; then
    printf 'FAIL  %s (%s)\n' "$1" "$2"
  else
    printf 'FAIL  %s\n' "$1"
  fi
}

# expect_eq NAME EXPECTED ACTUAL / expect_contains NAME HAYSTACK NEEDLE /
# expect_not_contains NAME HAYSTACK NEEDLE / expect_rc NAME ACTUAL EXPECTED.
expect_eq() {
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "expected [$2], got [$3]"; fi
}
expect_contains() {
  case "$2" in
    *"$3"*) pass "$1" ;;
    *)
      fail "$1" "missing [$3]"
      printf '%s\n' "$2" | head -n 12 | sed 's/^/      | /'
      ;;
  esac
}
expect_not_contains() {
  case "$2" in *"$3"*) fail "$1" "unexpected [$3]" ;; *) pass "$1" ;; esac
}
expect_rc() {
  # Validate both operands: `[[ "" -eq 0 ]]` is true in bash, so an empty or
  # non-numeric actual rc used to pass silently for an expected 0.
  case "${2:-}" in
    '' | *[!0-9]*)
      fail "$1" "expected rc ${3}, got non-numeric [${2:-}]"
      return 0
      ;;
  esac
  case "${3:-}" in
    '' | *[!0-9]*)
      fail "$1" "invalid expected rc [${3:-}]"
      return 0
      ;;
  esac
  if [[ "$2" -eq "$3" ]]; then pass "$1"; else fail "$1" "expected rc ${3}, got ${2}"; fi
}

# expect_file NAME PATH / expect_no_file NAME PATH.
expect_file() {
  if [[ -f "$2" ]]; then pass "$1"; else fail "$1" "missing file ${2}"; fi
}
expect_no_file() {
  if [[ -e "$2" ]]; then fail "$1" "unexpected path ${2}"; else pass "$1"; fi
}

# expect_same NAME FILE_A FILE_B - pass when both files have identical bytes.
expect_same() {
  if cmp -s "$2" "$3"; then pass "$1"; else fail "$1" "files differ: $2 vs $3"; fi
}

# wait_until TIMEOUT_S CMD... - run CMD every 0.1s until it succeeds (rc 0)
# or TIMEOUT_S whole seconds elapse. CMD's output is discarded. Returns 0 on
# success and 1 on timeout; a timeout never fails a test by itself, the
# caller asserts on the return value. Polling on a deadline beats a fixed
# sleep because the wait ends as soon as the condition holds.
wait_until() {
  local timeout="${1:-0}" deadline=0
  shift
  deadline=$((SECONDS + timeout))
  while :; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    [[ "$SECONDS" -lt "$deadline" ]] || return 1
    sleep 0.1
  done
}

# wait_for_file TIMEOUT_S PATH - wait until PATH is a non-empty regular file.
wait_for_file() {
  wait_until "$1" test -s "$2"
}

# wait_for_pattern TIMEOUT_S FILE PATTERN - wait until grep finds PATTERN in
# FILE. A missing FILE simply never matches until the deadline.
wait_for_pattern() {
  wait_until "$1" grep -q -e "$3" "$2"
}

# _pid_gone PID - true once PID no longer exists. Passed to wait_until by name.
# shellcheck disable=SC2329  # invoked through wait_until
_pid_gone() {
  ! kill -0 "${1:-}" 2>/dev/null
}

# wait_for_pid_gone TIMEOUT_S PID - wait until PID no longer exists.
wait_for_pid_gone() {
  wait_until "$1" _pid_gone "$2"
}

# holder_start ARGV0 - spawn `sleep 30` with argv[0] replaced by ARGV0 (so
# ps reports bin/sciebo) and set HOLDER_PID. holder_wait PID prints 1 once
# ps shows the holder, else 0 after ~1s.
holder_start() {
  (exec -a "$1" sleep 30) &
  # shellcheck disable=SC2034  # read by the sourcing test suites
  HOLDER_PID=$!
}
holder_wait() {
  local _=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if ps -ww -p "$1" -o command= 2>/dev/null | grep -q 'bin/sciebo'; then
      printf '1'
      return 0
    fi
    sleep 0.1
  done
  printf '0'
}

finish() {
  # Remove temp paths registered by sourced modules (e.g. policy.sh's scan
  # cache) so a suite using the harness leaves nothing behind in TMPDIR.
  if type -t sciebo_temp_cleanup >/dev/null 2>&1; then
    sciebo_temp_cleanup || true
  fi
  printf '%d passed, %d failed\n' "$HARNESS_PASS" "$HARNESS_FAIL"
  if [[ "$HARNESS_FAIL" -gt 0 ]]; then exit 1; fi
  exit 0
}

# show_cli_out_on_mismatch RC WANT - after a failed rc assertion, print the
# first lines of the captured command output (CLI_OUT) so a failure in the
# suite log says why the command failed, not only that it did.
show_cli_out_on_mismatch() {
  [[ "$1" == "$2" ]] && return 0
  printf '%s\n' "${CLI_OUT:-}" | head -n 20 | sed 's/^/      | /'
}
