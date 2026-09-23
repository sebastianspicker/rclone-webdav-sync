#!/usr/bin/env bash
# ignored.sh - `sciebo ignored` reports local files sync would not transfer:
# clutter and pair filters, .nosync markers, conflict copies, hidden files,
# server excludes, and blacklisted paths.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

export BLACKLIST_ENABLED=1
ROOT="${TMP}/local"
ROOT2="${TMP}/local-two"
CLEAN="${TMP}/local-clean"
MISSING="${TMP}/local-missing"
mkdir -p "${ROOT}/nosync-dir" "${ROOT}/sub" "${ROOT}/blocked" "${ROOT2}" "${CLEAN}"
printf 'keep\n' >"${ROOT}/keep.txt"
printf 'clutter\n' >"${ROOT}/Thumbs.db"
printf 'conflict\n' >"${ROOT}/keep-conflicted copy.txt"
printf 'hidden\n' >"${ROOT}/.hidden.txt"
: >"${ROOT}/nosync-dir/.nosync"
printf 'inside\n' >"${ROOT}/nosync-dir/inside.txt"
printf 'nested\n' >"${ROOT}/sub/inside.tmp"
printf 'blocked\n' >"${ROOT}/blocked/bad.txt"
printf 'two\n' >"${ROOT2}/other.tmp"
printf 'ok\n' >"${ROOT2}/ok.txt"
printf 'ok\n' >"${CLEAN}/ok.txt"

# The main entry carries a pair filter; the failure blacklist record uses
# the format lib/blacklist.sh parses (count<TAB>path<TAB>error).
printf -- '- pair-skip.txt\n' >"${FILTER_DIR}/pair-ignored.txt"
cat >"$MANIFEST_FILE" <<EOF
sync|${ROOT}|ignored-src|pair-ignored.txt
sync|${ROOT2}|ignored-two
sync|${CLEAN}|ignored-clean
sync|${MISSING}|ignored-missing
EOF
mkdir -p "${STATE_DIR}/blacklist"
printf '3\tblocked/bad.txt\tboom\n' >"${STATE_DIR}/blacklist/ignored-src"

# --- one row per ignored file, normal files stay out -----------------------
expect_cli "ignored: rc 0" 0 run_cli ignored
expect_contains "ignored: clutter file reported" "$CLI_OUT" "$(printf 'ignored-src\t%s\t%s' "${ROOT}/Thumbs.db" "Thumbs.db")"
expect_contains "ignored: conflict copy reported" "$CLI_OUT" "$(printf 'ignored-src\t%s\t%s' "${ROOT}/keep-conflicted copy.txt" "keep-conflicted copy.txt")"
expect_contains "ignored: .nosync tree reported" "$CLI_OUT" "$(printf 'ignored-src\t%s\t%s' "${ROOT}/nosync-dir/inside.txt" "nosync-dir/inside.txt")"
expect_contains "ignored: blacklisted path reported" "$CLI_OUT" "$(printf 'ignored-src\t%s\t%s' "${ROOT}/blocked/bad.txt" "blocked/bad.txt")"
expect_contains "ignored: blacklist warning" "$CLI_OUT" "blacklisted path(s) excluded"
expect_not_contains "ignored: normal file not reported" "$CLI_OUT" "keep.txt"
expect_not_contains "ignored: hidden file synced without SKIP_HIDDEN" "$CLI_OUT" ".hidden.txt"
expect_contains "ignored: count summary" "$CLI_OUT" "ignored files"

# --- the entry's pair filter is applied ------------------------------------
printf 'pair\n' >"${ROOT}/pair-skip.txt"
expect_cli "ignored: pair filter rc 0" 0 run_cli ignored --source ignored-src
expect_contains "ignored: pair-filter match reported" "$CLI_OUT" "$(printf 'ignored-src\t%s\t%s' "${ROOT}/pair-skip.txt" "pair-skip.txt")"

# --- the generated server-exclude filter is applied ------------------------
printf -- '- server-bad.txt\n' >"${FILTER_DIR}/server-exclude.txt"
printf 'server\n' >"${ROOT}/server-bad.txt"
export FILTER_SERVER_SYNC=1
expect_cli "ignored: server exclude rc 0" 0 run_cli ignored --source ignored-src
expect_contains "ignored: server-excluded path reported" "$CLI_OUT" "$(printf 'ignored-src\t%s\t%s' "${ROOT}/server-bad.txt" "server-bad.txt")"
unset FILTER_SERVER_SYNC
expect_cli "ignored: server exclude off rc 0" 0 run_cli ignored --source ignored-src
expect_not_contains "ignored: server-excluded path synced when disabled" "$CLI_OUT" "server-bad.txt"

# --- CONFLICT_UPLOAD=1 allows conflict copies ------------------------------
export CONFLICT_UPLOAD=1
expect_cli "ignored: CONFLICT_UPLOAD rc 0" 0 run_cli ignored --source ignored-src
expect_not_contains "ignored: conflict copy synced with CONFLICT_UPLOAD=1" "$CLI_OUT" "keep-conflicted copy.txt"
unset CONFLICT_UPLOAD

# --- SKIP_HIDDEN=1 adds the dotfile exclusion ------------------------------
export SKIP_HIDDEN=1
expect_cli "ignored: SKIP_HIDDEN rc 0" 0 run_cli ignored --source ignored-src
expect_contains "ignored: hidden file reported with SKIP_HIDDEN=1" "$CLI_OUT" "$(printf 'ignored-src\t%s\t%s' "${ROOT}/.hidden.txt" ".hidden.txt")"
unset SKIP_HIDDEN

# --- --json -----------------------------------------------------------------
expect_cli "ignored: json rc 0" 0 run_cli ignored --source ignored-src --json
expect_contains "ignored: json array" "$CLI_OUT" '"ignored": ['
expect_contains "ignored: json source" "$CLI_OUT" '"source": "ignored-src"'
expect_contains "ignored: json local" "$CLI_OUT" "\"local\": \"${ROOT}/Thumbs.db\""
expect_contains "ignored: json path" "$CLI_OUT" '"path": "Thumbs.db"'
expect_not_contains "ignored: json has no text summary" "$CLI_OUT" "ignored files"
expect_cli "ignored: json empty rc 0" 0 run_cli ignored --source ignored-clean --json
expect_contains "ignored: json empty array" "$CLI_OUT" '"ignored": []'
if command -v python3 >/dev/null 2>&1; then
  expect_cli "ignored: json parse rc 0" 0 run_cli ignored --source ignored-two --json
  json_rc=0
  printf '%s' "$CLI_OUT" | python3 -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1 || json_rc=$?
  expect_rc "ignored: json parses" "$json_rc" 0
fi

# --- --source restricts the scan -------------------------------------------
expect_cli "ignored: --source rc 0" 0 run_cli ignored --source ignored-two
expect_contains "ignored: --source reports its entry" "$CLI_OUT" "$(printf 'ignored-two\t%s\t%s' "${ROOT2}/other.tmp" "other.tmp")"
expect_not_contains "ignored: --source keeps normal files out" "$CLI_OUT" "ok.txt"
expect_not_contains "ignored: --source hides other entries" "$CLI_OUT" "ignored-src"
expect_cli "ignored: unknown source rc 1" 1 run_cli ignored --source no-such-source
expect_contains "ignored: unknown source message" "$CLI_OUT" "No source named 'no-such-source'"

# --- SUB matches local-relative, remote-relative, and absolute paths -------
expect_cli "ignored: SUB local-relative rc 0" 0 run_cli ignored sub
expect_contains "ignored: SUB local-relative keeps match" "$CLI_OUT" "sub/inside.tmp"
expect_not_contains "ignored: SUB local-relative drops others" "$CLI_OUT" "Thumbs.db"
expect_cli "ignored: SUB remote-relative rc 0" 0 run_cli ignored ignored-src/sub
expect_contains "ignored: SUB remote-relative keeps match" "$CLI_OUT" "sub/inside.tmp"
expect_not_contains "ignored: SUB remote-relative drops others" "$CLI_OUT" "Thumbs.db"
expect_cli "ignored: SUB absolute rc 0" 0 run_cli ignored "${ROOT}/sub"
expect_contains "ignored: SUB absolute keeps match" "$CLI_OUT" "sub/inside.tmp"
expect_not_contains "ignored: SUB absolute drops others" "$CLI_OUT" "Thumbs.db"
expect_cli "ignored: two SUBs rc 2" 2 run_cli ignored a b
expect_contains "ignored: two SUBs message" "$CLI_OUT" "at most one SUB"

# --- empty results and missing directories ---------------------------------
expect_cli "ignored: clean source rc 0" 0 run_cli ignored --source ignored-clean
expect_contains "ignored: clean source message" "$CLI_OUT" "no ignored files"
expect_cli "ignored: no SUB match rc 0" 0 run_cli ignored no/such/path
expect_contains "ignored: no SUB match message" "$CLI_OUT" "no ignored files"
expect_cli "ignored: missing local dir rc 0" 0 run_cli ignored --source ignored-missing
expect_contains "ignored: missing local dir warning" "$CLI_OUT" "local directory missing"
expect_contains "ignored: missing local dir empty" "$CLI_OUT" "no ignored files"

# --help prints the usage and exits 0.
expect_cli "ignored: --help rc 0" 0 run_cli ignored --help
expect_contains "ignored: --help usage" "$CLI_OUT" "Usage: sciebo ignored"

finish
