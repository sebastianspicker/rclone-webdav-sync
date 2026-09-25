#!/usr/bin/env bash
# unit.sh - run tests/unit/*.sh (rclone is not required), in a fresh bash
# process each. Usage: tests/unit.sh [-j N] [NAME...]
#   -j N   run N scripts concurrently (default $SCIEBO_TEST_JOBS, else the
#          CPU count, else 4; -j 1 runs one at a time).
#   NAME   run only tests/unit/NAME.sh (with or without the .sh), may be
#          repeated; no NAME runs every script. Sourced helpers (common.sh
#          and anything named _*.sh) are never suites and are
#          always skipped; see tests/run-suite.sh.
# Each script sources tests/unit/common.sh for isolation (every path
# redirected into a fresh mktemp directory) and reports through
# tests/harness.sh; tests/run-suite.sh aggregates the exit status.
set -uo pipefail
UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=run-suite.sh
source "${UNIT_DIR}/run-suite.sh"
run_suite unit "${UNIT_DIR}/unit" "common" "$@"
exit "$?"
