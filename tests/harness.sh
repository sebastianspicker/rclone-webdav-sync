#!/bin/bash
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
  case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" "missing [$3]" ;; esac
}
expect_not_contains() {
  case "$2" in *"$3"*) fail "$1" "unexpected [$3]" ;; *) pass "$1" ;; esac
}
expect_rc() {
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
    if ps -p "$1" -o command= 2>/dev/null | grep -q 'bin/sciebo'; then
      printf '1'
      return 0
    fi
    sleep 0.1
  done
  printf '0'
}

finish() {
  printf '%d passed, %d failed\n' "$HARNESS_PASS" "$HARNESS_FAIL"
  if [[ "$HARNESS_FAIL" -gt 0 ]]; then exit 1; fi
  exit 0
}
