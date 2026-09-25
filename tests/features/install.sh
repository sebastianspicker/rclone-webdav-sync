#!/usr/bin/env bash
# install.sh - `make install`/`make uninstall`/`make dist` against a
# throwaway PREFIX (and, for dist, the real project tree read-only plus a
# throwaway dist/ output). No network, no real HOME, no rclone required.
set -uo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$(cd "${INSTALL_DIR}/../.." && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../harness.sh
source "${INSTALL_DIR}/../harness.sh"

command -v make >/dev/null 2>&1 || {
  echo "SKIP: make not installed"
  exit 0
}

PREFIX_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sciebo-install.XXXXXX")"
DEST="${PREFIX_DIR}/share/rclone-sciebo"
trap 'rm -rf "$PREFIX_DIR"' EXIT

run_make() { (cd "$PROJ" && make -f Makefile "$@" PREFIX="$PREFIX_DIR" 2>&1); }

# --- fresh install -----------------------------------------------------------
out="$(run_make install)"
rc=$?
expect_rc "install: fresh install rc 0" "$rc" 0
expect_file "install: wrapper installed" "${PREFIX_DIR}/bin/sciebo"
expect_file "install: lib/sciebo.sh installed" "${DEST}/lib/sciebo.sh"
expect_file "install: config/sources.conf installed" "${DEST}/config/sources.conf"
expect_not_contains "install: fresh install preserves nothing" "$out" "preserved existing"

version_out="$("${PREFIX_DIR}/bin/sciebo" --version 2>&1)"
rc=$?
expect_rc "install: --version rc 0" "$rc" 0
expect_contains "install: --version prints sciebo" "$version_out" "sciebo"

help_out="$("${PREFIX_DIR}/bin/sciebo" help 2>&1)"
rc=$?
expect_rc "install: help rc 0" "$rc" 0
expect_contains "install: help prints usage" "$help_out" "Usage: sciebo"

# --- customize the install, then upgrade over it ----------------------------
printf 'sync|/home/marker/custom|custom\n' >>"${DEST}/config/sources.conf"
printf 'bisync|/home/marker/wizard|wizard\n' >>"${DEST}/config/folders.conf"
printf 'CUSTOM_SETTING=kept\n' >"${DEST}/config/settings.local.env"
mkdir -p "${DEST}/state"
: >"${DEST}/state/keep-me"
# A file the upstream tree no longer ships must not linger after an upgrade.
mkdir -p "${DEST}/lib/commands"
: >"${DEST}/lib/commands/folders_choose.sh"

out="$(run_make install)"
rc=$?
expect_rc "install: upgrade rc 0" "$rc" 0
expect_contains "install: upgrade preserves sources.conf" \
  "$(cat "${DEST}/config/sources.conf")" "sync|/home/marker/custom|custom"
expect_contains "install: upgrade preserves folders.conf" \
  "$(cat "${DEST}/config/folders.conf")" "bisync|/home/marker/wizard|wizard"
expect_contains "install: upgrade preserves settings.local.env" \
  "$(cat "${DEST}/config/settings.local.env")" "CUSTOM_SETTING=kept"
expect_file "install: upgrade preserves state/keep-me" "${DEST}/state/keep-me"
expect_no_file "install: upgrade removes a stale shipped file" "${DEST}/lib/commands/folders_choose.sh"
expect_same "install: upgrade refreshes config/settings.env" \
  "${PROJ}/config/settings.env" "${DEST}/config/settings.env"
expect_contains "install: upgrade reports preserved config" "$out" "preserved existing config:"
expect_contains "install: upgrade reports preserved sources.conf" "$out" "sources.conf"
expect_contains "install: upgrade reports preserved folders.conf" "$out" "folders.conf"
expect_contains "install: upgrade reports preserved state" "$out" "preserved existing state/"

# --- uninstall keeps config/ and state/, removes code -----------------------
out="$(run_make uninstall)"
rc=$?
expect_rc "uninstall: rc 0" "$rc" 0
expect_no_file "uninstall: wrapper removed" "${PREFIX_DIR}/bin/sciebo"
expect_no_file "uninstall: lib/ removed" "${DEST}/lib"
expect_no_file "uninstall: bin/ removed" "${DEST}/bin"
expect_file "uninstall: config/sources.conf kept" "${DEST}/config/sources.conf"
expect_contains "uninstall: kept sources.conf still has the custom line" \
  "$(cat "${DEST}/config/sources.conf")" "sync|/home/marker/custom|custom"
expect_file "uninstall: state/keep-me kept" "${DEST}/state/keep-me"
expect_contains "uninstall: points at rm -rf for the remainder" "$out" "rm -rf ${DEST}"

# --- dist: build from the files git would publish ---------------------------
DIST_OUT_DIR="${PREFIX_DIR}/dist-out"
dist_out="$( (cd "$PROJ" && make -f Makefile dist DIST_DIR="$DIST_OUT_DIR" 2>&1) )"
dist_rc=$?
dist_ver="$(tr -d '[:space:]' <"${PROJ}/VERSION")"
tarball="${DIST_OUT_DIR}/rclone-webdav-sync-${dist_ver}.tar.gz"
expect_rc "dist: rc 0" "$dist_rc" 0
expect_contains "dist: prints the wrote-tarball line" "$dist_out" "wrote ${DIST_OUT_DIR}/"
expect_file "dist: tarball written" "$tarball"
listing="$(tar -tzf "$tarball" 2>/dev/null)"
prefix="rclone-webdav-sync-${dist_ver}"
expect_contains "dist: contains bin/sciebo" "$listing" "${prefix}/bin/sciebo"
expect_contains "dist: contains lib/sciebo.sh" "$listing" "${prefix}/lib/sciebo.sh"
case $'\n'"$listing"$'\n' in
  *$'\n'"${prefix}/config/settings.local.env"$'\n'*)
    fail "dist: excludes settings.local.env" "unexpected ${prefix}/config/settings.local.env"
    ;;
  *) pass "dist: excludes settings.local.env" ;;
esac
expect_not_contains "dist: excludes state/" "$listing" "${prefix}/state/"
expect_not_contains "dist: excludes .agents" "$listing" ".agents"
expect_not_contains "dist: excludes .claude" "$listing" ".claude"

# --- dist: fails clearly outside a git work tree ----------------------------
NO_GIT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sciebo-nogit.XXXXXX")"
cp "${PROJ}/Makefile" "${PROJ}/VERSION" "$NO_GIT_DIR/"
nogit_out="$( (cd "$NO_GIT_DIR" && make -f Makefile dist 2>&1) )"
nogit_rc=$?
# make itself reports a recipe failure as exit 2, regardless of the recipe's
# own `exit 1`.
expect_rc "dist: outside a git work tree fails" "$nogit_rc" 2
expect_contains "dist: outside a git work tree names the reason" "$nogit_out" "git work tree"
rm -rf "$NO_GIT_DIR"

finish
