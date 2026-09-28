#!/usr/bin/env bash
# runner.sh - argument validation for the shared unit/feature suite runner.
set -uo pipefail

RUNNER_UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "${RUNNER_UNIT_DIR}/.." && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../harness.sh
source "${TESTS_DIR}/harness.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../run-suite.sh
source "${TESTS_DIR}/run-suite.sh"

RUNNER_TMP="$(mktemp -d "${TMPDIR:-/tmp}/sciebo-runner-unit.XXXXXX")"
trap 'rm -rf "$RUNNER_TMP"' EXIT

out=""
rc=0
out="$(run_suite probe "$RUNNER_TMP" "" -j 2>&1)" || rc=$?
expect_rc "runner: trailing -j is a usage error" "$rc" 2
expect_contains "runner: trailing -j explains the missing value" "$out" \
  "-j requires a positive integer"

finish
