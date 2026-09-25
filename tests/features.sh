#!/usr/bin/env bash
# features.sh - run tests/features/*.sh, in a fresh bash process each.
# Usage: tests/features.sh [-j N] [NAME...]
#   -j N   run N scripts concurrently (default $SCIEBO_TEST_JOBS, else the
#          CPU count, else 4; -j 1 runs one at a time).
#   NAME   run only tests/features/NAME.sh (with or without the .sh), may be
#          repeated; no NAME runs every script. Sourced helpers (env.sh, and
#          anything named _*.sh) are never suites and are always skipped;
#          see tests/run-suite.sh.
# Each script is self-isolated (temp dir, stub curl) and reports through
# tests/harness.sh; tests/run-suite.sh aggregates the exit status.
set -uo pipefail
FEATURES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=run-suite.sh
source "${FEATURES_DIR}/run-suite.sh"
run_suite features "${FEATURES_DIR}/features" env "$@"
exit "$?"
