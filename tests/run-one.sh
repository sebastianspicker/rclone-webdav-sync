#!/usr/bin/env bash
# run-one.sh - run a single unit or feature test by name.
# Usage: tests/run-one.sh NAME   (NAME with or without .sh)
# Looks for tests/unit/NAME.sh, then tests/features/NAME.sh, and runs
# whichever exists in a fresh bash process, forwarding its exit status.
# Backs `make test-one T=NAME`.
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -ne 1 || -z "$1" ]]; then
  printf 'usage: %s NAME\n' "${BASH_SOURCE[0]}" >&2
  exit 2
fi
name="${1%.sh}"

# common.sh/env.sh (and anything named _*.sh) are sourced
# helpers, not runnable suites (tests/run-suite.sh skips them too); reject
# them here instead of silently "running" a no-op.
if [[ "$name" == common || "$name" == env || "$name" == _* ]]; then
  printf 'run-one: %s is a sourced helper, not a test\n' "$name" >&2
  exit 2
fi

for dir in unit features; do
  candidate="${TESTS_DIR}/${dir}/${name}.sh"
  if [[ -f "$candidate" ]]; then
    exec bash "$candidate"
  fi
done

printf 'run-one: no such test: %s (looked in %s/unit and %s/features)\n' \
  "$name" "$TESTS_DIR" "$TESTS_DIR" >&2
exit 2
