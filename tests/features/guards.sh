#!/usr/bin/env bash
# guards.sh - run the repository guards from the repo root and require clean
# exits. check-drift reports command and settings drift and must exit 0 and
# print a summary; it may print WARN lines (planned commands,
# docs/completions/man lag) without failing, which this test accepts as long as
# the hard checks pass.
set -uo pipefail

GUARDS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$(cd "${GUARDS_DIR}/../.." && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../harness.sh
source "${GUARDS_DIR}/../harness.sh"

# expect_guard NAME SCRIPT - run SCRIPT from the repo root, expect rc 0 and
# non-empty combined output.
expect_guard() {
  local name="$1" script="$2" out="" rc=0
  out="$( (cd "$PROJ" && bash "$script") 2>&1)" || rc=$?
  expect_rc "$name: exit 0" "$rc" 0
  if [[ -n "$out" ]]; then
    pass "$name: output"
  else
    fail "$name: output" "empty output"
  fi
}

expect_guard "check-drift" "scripts/check-drift.sh"

# DRIFT_STRICT turns a planned-command warning into a hard failure; with the
# dispatch list fully implemented it must still exit 0. The module-spec,
# completion-subcommand, and dead-symbol checks added alongside it are
# warning-only, so the strict summary still reports zero hard failures.
out="$( (cd "$PROJ" && DRIFT_STRICT=1 bash scripts/check-drift.sh) 2>&1)"
rc=$?
expect_rc "check-drift (strict): exit 0" "$rc" 0
expect_contains "check-drift (strict): no hard failures" "$out" "0 hard failure(s)"

# --- check-drift catches a missing option -----------------------------------
# Build a throwaway copy of the tree and add a usage_ function whose option
# docs/commands.md does not document. The copy keeps check-drift's
# ROOT-relative reads working unchanged; the injected module sorts first so the
# option scan picks it up. The run must still exit 0 (warnings never fail) and
# name the option.
drift_copy="$(mktemp -d "${TMPDIR:-/tmp}/sciebo-drift.XXXXXX")"
trap 'rm -rf "$drift_copy"' EXIT
cp -R "${PROJ}/bin" "${PROJ}/lib" "${PROJ}/docs" "${PROJ}/completions" \
  "${PROJ}/man" "${PROJ}/config" "${PROJ}/scripts" "$drift_copy/"
cat >"${drift_copy}/lib/commands/000-inject.sh" <<'EOF'
usage_download() {
  cat <<'USAGE'
Usage: sciebo download SUB [--injected-bogus-flag]
USAGE
}
EOF
out="$(DRIFT_STRICT=1 bash "${drift_copy}/scripts/check-drift.sh" 2>&1)"
rc=$?
expect_rc "check-drift injection: exits 0" "$rc" 0
expect_contains "check-drift injection: warns about the missing option" "$out" "--injected-bogus-flag"

# --- command-module mapping -------------------------------------------------
# bin/sciebo resolves each command through lib/sciebo.sh's
# sciebo_command_module, driven by the generated SCIEBO_COMMAND_MODULE map
# (lib/cli/registry.sh, built by scripts/gen-cli.sh from lib/cli/sciebo.spec;
# `scripts/gen-cli.sh --check`, part of `make lint`, already validates that
# every COMMAND row's module file exists). This restates that behaviorally:
# a representative set of multi-command modules must actually answer `help`.
for cmd in list check sync pause resume mount umount mounts lock unlock locks limit unlimited; do
  out="$(bash "${PROJ}/bin/sciebo" help "$cmd" 2>&1)"
  rc=$?
  expect_rc "module mapping: help ${cmd} exits 0" "$rc" 0
  expect_contains "module mapping: help ${cmd} prints usage" "$out" "Usage: sciebo "
done

# --- --version / -V --------------------------------------------------------
# --version/-V prints "sciebo VERSION" and exits 0, including when combined
# with other globals.
version_file="$(tr -d '[:space:]' <"${PROJ}/VERSION" 2>/dev/null || true)"
expect_eq "version: --version prints the version" "sciebo ${version_file}" \
  "$(bash "${PROJ}/bin/sciebo" --version 2>&1)"
expect_eq "version: -V prints the version" "sciebo ${version_file}" \
  "$(bash "${PROJ}/bin/sciebo" -V 2>&1)"
expect_eq "version: --profile=x --version prints the version" "sciebo ${version_file}" \
  "$(bash "${PROJ}/bin/sciebo" --profile=x --version 2>&1)"
# A version flag joined to a value is not a version request (the option
# parser treats it as an unmatched argument), so it must not short-circuit.
bash "${PROJ}/bin/sciebo" --version=foo >/dev/null 2>&1
expect_rc "version: --version=foo stays an unknown command" "$?" 2

# --- bare help ---------------------------------------------------------------
# `help`/`-h`/`--help` with no command argument print the main usage and exit
# 0, including when global options precede them. `help <command>` prints that
# command's own usage.
for helpflag in help -h --help; do
  out="$(bash "${PROJ}/bin/sciebo" "$helpflag" 2>&1)"
  rc=$?
  expect_rc "help: bare ${helpflag} exits 0" "$rc" 0
  expect_contains "help: bare ${helpflag} prints usage" "$out" "Usage: sciebo "
  expect_contains "help: bare ${helpflag} lists commands" "$out" "Commands:"
done
out="$(bash "${PROJ}/bin/sciebo" --profile=x help 2>&1)"
rc=$?
expect_rc "help: --profile=x help exits 0" "$rc" 0
expect_contains "help: --profile=x help prints usage" "$out" "Usage: sciebo "
out="$(bash "${PROJ}/bin/sciebo" help sync 2>&1)"
rc=$?
expect_rc "help: help sync exits 0" "$rc" 0
expect_contains "help: help sync prints the command usage" "$out" "Usage: sciebo sync"

finish
