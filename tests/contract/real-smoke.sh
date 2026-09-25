#!/usr/bin/env bash
# real-smoke.sh - a tagged subset of sciebo commands run against a real
# Nextcloud (started with nextcloud-up.sh), not tests/fake_server.py.
#
# This is the "INTEGRATION_TARGET=real" entry point tests/integration.sh
# dispatches to (see the top of that file): default (fake) mode is entirely
# unchanged, and this script never runs unless INTEGRATION_TARGET=real and
# NC_URL/NC_USER/NC_APPPASS are set.
#
# Isolation follows tests/integration.sh: every path (STATE_DIR, manifests,
# filters, rclone config) lives under a fresh mktemp dir; nothing under the
# real project config or HOME is touched. Requires rclone; SKIPs (rc 0)
# otherwise, matching tests/integration.sh's own SKIP convention.
set -uo pipefail
CONTRACT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$(cd "${CONTRACT_DIR}/.." && pwd)/.."
PROJ="$(cd "$PROJ" && pwd)"

command -v rclone >/dev/null 2>&1 || {
  echo "SKIP: rclone not installed"
  exit 0
}
[[ -n "${NC_URL:-}" && -n "${NC_USER:-}" && -n "${NC_APPPASS:-}" ]] || {
  echo "SKIP: NC_URL/NC_USER/NC_APPPASS not set (run nextcloud-up.sh first)"
  exit 0
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sciebo-contract.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../harness.sh
source "${CONTRACT_DIR}/../harness.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/core.sh
source "${PROJ}/lib/core.sh"

export RCLONE_REMOTE=contractnc RCLONE_CONFIG="${TMP}/rclone.conf" REMOTE_BASE=contract \
  STATE_DIR="${TMP}/state" SETTINGS_LOCAL_FILE="${TMP}/no-local.env" ENV_FILE="${TMP}/no-env.env" \
  MANIFEST_FILE="${TMP}/sources.conf" MANIFEST_GENERATED_FILE="${TMP}/sources.generated.conf" \
  ROOTS_FILE="${TMP}/roots.conf" FOLDERS_FILE="${TMP}/folders.conf" FILTER_DIR="${TMP}/filters" \
  KEYCHAIN=0 NOTIFY=0 TRANSFERS=1 RETRIES=1 LOW_LEVEL_RETRIES=1 CONTIMEOUT=5s TIMEOUT=30s
mkdir -p "$FILTER_DIR"
: >"$FOLDERS_FILE"
cp "${PROJ}/config/filters/clutter.txt" "$FILTER_DIR/clutter.txt"

run_cli() { (cd "$TMP" && bash "${PROJ}/bin/sciebo" "$@"); }
capture() {
  CLI_OUT="$("$@" 2>&1)"
  CLI_RC=$?
}
expect_cli() {
  local name="$1" want="$2"
  shift 2
  capture "$@"
  expect_rc "$name" "$CLI_RC" "$want"
  # A real server's answer is the evidence; show it when the rc is wrong.
  [[ "$CLI_RC" == "$want" ]] || printf '      | %s\n' "${CLI_OUT//$'\n'/$'\n      | '}"
}

OBSCURED="$(rclone obscure "$NC_APPPASS")"
rclone config create "$RCLONE_REMOTE" webdav \
  "url=${NC_URL}/remote.php/dav/files/${NC_USER}/" \
  vendor=nextcloud "user=${NC_USER}" "pass=${OBSCURED}" \
  --config "$RCLONE_CONFIG" >/dev/null || {
  echo "SKIP: cannot create the contract rclone remote"
  exit 0
}

printf 'sciebo contract smoke test against %s\n' "$NC_URL"

# --- doctor / capabilities (real network) -----------------------------------
expect_cli "doctor: runs against the real server" 0 run_cli doctor
expect_contains "doctor: reports the server version" "$CLI_OUT" "server is Nextcloud"

# --- sync (push) -------------------------------------------------------------
mkdir -p "${TMP}/src"
printf 'contract sync payload\n' >"${TMP}/src/report.txt"
printf 'sync|%s/src|contract-sync\n' "$TMP" >"$MANIFEST_FILE"
expect_cli "sync: push (--apply)" 0 run_cli sync --apply
expect_cli "verify: push matches" 0 run_cli verify --only contract-sync

# --- pull ---------------------------------------------------------------
# A pull entry's name comes from its own remote_subdir, and manifest entry
# names must be unique, so this seeds a *different* remote folder directly
# with rclone (not through a second sync entry pointed at contract-sync).
mkdir -p "${TMP}/dst" "${TMP}/pull-seed"
printf 'contract pull payload\n' >"${TMP}/pull-seed/pulled.txt"
rclone copyto "${TMP}/pull-seed/pulled.txt" "${RCLONE_REMOTE}:${REMOTE_BASE}/contract-pull/pulled.txt" \
  --config "$RCLONE_CONFIG" >/dev/null 2>&1
printf 'sync|%s/src|contract-sync\npull|%s/dst|contract-pull\n' "$TMP" "$TMP" >"$MANIFEST_FILE"
expect_cli "sync: pull (--apply)" 0 run_cli sync --apply --only contract-pull
expect_file "pull: downloaded the seeded file" "${TMP}/dst/pulled.txt"

# --- bisync -------------------------------------------------------------
# Two files, not one: rclone bisync's "all files changed" safety abort
# triggers whenever 100% of a (non-empty) listing changed between runs, so a
# single-file folder can never pass a normal (non-resync) run after an edit.
mkdir -p "${TMP}/bi"
printf 'bisync content v1\n' >"${TMP}/bi/notes.txt"
printf 'unchanged\n' >"${TMP}/bi/stable.txt"
printf 'bisync|%s/bi|contract-bisync\n' "$TMP" >>"$MANIFEST_FILE"
expect_cli "sync: bisync resync (--resync --apply)" 0 \
  run_cli sync --resync --apply --only contract-bisync
printf 'bisync content v2\n' >"${TMP}/bi/notes.txt"
expect_cli "sync: bisync normal run" 0 run_cli sync --apply --only contract-bisync

# --- share create/list/delete -----------------------------------------------
expect_cli "share: create a link share" 0 run_cli share link contract-sync/report.txt
share_id="$(printf '%s' "$CLI_OUT" | LC_ALL=C awk '/^created share / {print $3; exit}')"
expect_cli "share: list includes the new share" 0 run_cli share list
# The listing's last column is the share URL for link shares, not the
# shared path, so this checks the share type column instead.
expect_contains "share: listing shows a link share" "$CLI_OUT" "link"
if [[ -n "$share_id" ]]; then
  expect_cli "share: remove the share" 0 run_cli share remove "$share_id" --yes
else
  echo "SKIP: share: remove (could not parse the share id from 'share link' output)"
fi

# --- versions -----------------------------------------------------------
printf 'contract sync payload v2\n' >"${TMP}/src/report.txt"
expect_cli "sync: second push creates a version" 0 run_cli sync --apply --only contract-sync
expect_cli "versions: list rc 0" 0 run_cli versions contract-sync/report.txt

# --- trash ----------------------------------------------------------------
# Nextcloud names the trashbin properties nc:trashbin-filename/
# nc:trashbin-deletion-time; `sciebo trash` must list the deleted file by
# its original name (it once asked only for the ownCloud oc: names and
# reported a non-empty trashbin as empty).
rm -f "${TMP}/src/report.txt"
expect_cli "sync: delete pushes a remote deletion (populates the trashbin)" 0 run_cli sync --apply --only contract-sync
expect_cli "trash: list rc 0" 0 run_cli trash
expect_contains "trash: lists the deleted file by name" "$CLI_OUT" "report.txt"
expect_not_contains "trash: non-empty trashbin is not reported empty" "$CLI_OUT" "no trashed files"

# --- quota ----------------------------------------------------------------
expect_cli "quota: rc 0" 0 run_cli quota

# --- lock/unlock (skipped if the files_lock app is not installed) ----------
if command -v docker >/dev/null 2>&1 &&
  docker exec -u 33 "${CONTRACT_CONTAINER:-sciebo-contract-nc}" \
    php occ app:list --output=json 2>/dev/null | grep -q '"files_lock"'; then
  mkdir -p "${TMP}/src"
  printf 'lock me\n' >"${TMP}/src/locked.txt"
  run_cli sync --apply --only contract-sync >/dev/null 2>&1
  expect_cli "lock: rc 0" 0 run_cli lock contract-sync/locked.txt
  expect_cli "unlock: rc 0" 0 run_cli unlock contract-sync/locked.txt
else
  echo "SKIP: lock/unlock (files_lock app not installed on the contract server)"
fi

finish
