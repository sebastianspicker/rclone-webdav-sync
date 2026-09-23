#!/usr/bin/env bash
# conflicts_resolve.sh - `conflicts --resolve`: planning, applying, and the
# confirmation rules for conflict copies and case-clash quarantine rows.
# Purely local; the CLI is run exactly like in the conflicts.sh feature test.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

RES_DIR="${TMP}/local/resolve"
cat >"$MANIFEST_FILE" <<EOF
sync|${RES_DIR}|notes
EOF

# make_case BASE_CONTENT COPY_CONTENT - recreate the source dir with
# notes.txt and its rclone-style conflict copy.
make_case() {
  local base_content="$1" copy_content="$2"
  rm -rf "$RES_DIR"
  mkdir -p "$RES_DIR"
  printf '%s\n' "$base_content" >"${RES_DIR}/notes.txt"
  printf '%s\n' "$copy_content" >"${RES_DIR}/notes.txt.(conflicted copy)1"
}

# --- dry run plans without touching anything --------------------------------
make_case base copy
expect_cli "resolve: dry run rc 0" 0 run_cli conflicts --resolve keep-local
expect_contains "resolve: dry run prints the plan line" "$CLI_OUT" "notes notes.txt.(conflicted copy)1 -> keep-local notes.txt"
expect_contains "resolve: dry run summary" "$CLI_OUT" "1 to resolve (dry run)"
expect_eq "resolve: dry run keeps the base" "base" "$(cat "${RES_DIR}/notes.txt")"
expect_file "resolve: dry run keeps the copy" "${RES_DIR}/notes.txt.(conflicted copy)1"

# --- --quiet mirrors the listing behavior (rc 1 while copies exist) ---------
capture run_cli conflicts --resolve keep-local --quiet
expect_rc "resolve: --quiet dry run rc 1" "$CLI_RC" 1
expect_eq "resolve: --quiet dry run is silent" "" "$CLI_OUT"
expect_file "resolve: --quiet dry run keeps the copy" "${RES_DIR}/notes.txt.(conflicted copy)1"

# --- keep-local overwrites an existing base ---------------------------------
make_case base copy
expect_cli "resolve: keep-local apply rc 0" 0 run_cli conflicts --resolve keep-local --apply --yes
expect_eq "resolve: keep-local moves the copy content" "copy" "$(cat "${RES_DIR}/notes.txt")"
expect_no_file "resolve: keep-local removes the copy" "${RES_DIR}/notes.txt.(conflicted copy)1"
expect_contains "resolve: keep-local summary" "$CLI_OUT" "resolved 1 conflict copy(ies)"

# --- keep-local renames when the base is missing ----------------------------
rm -rf "$RES_DIR"
mkdir -p "$RES_DIR"
printf 'copy\n' >"${RES_DIR}/notes.txt.(conflicted copy)1"
expect_cli "resolve: keep-local without base rc 0" 0 run_cli conflicts --resolve keep-local --apply --yes
expect_eq "resolve: missing base is created" "copy" "$(cat "${RES_DIR}/notes.txt")"
expect_no_file "resolve: renamed copy is gone" "${RES_DIR}/notes.txt.(conflicted copy)1"

# --- keep-remote deletes the copy and keeps the base -------------------------
make_case base copy
expect_cli "resolve: keep-remote apply rc 0" 0 run_cli conflicts --resolve keep-remote --apply --yes
expect_eq "resolve: keep-remote keeps the base" "base" "$(cat "${RES_DIR}/notes.txt")"
expect_no_file "resolve: keep-remote deletes the copy" "${RES_DIR}/notes.txt.(conflicted copy)1"

# --- keep-both renames to "(local copy)" and then "-2" ----------------------
make_case base copy
expect_cli "resolve: keep-both apply rc 0" 0 run_cli conflicts --resolve keep-both --apply --yes
expect_no_file "resolve: keep-both moves the copy away" "${RES_DIR}/notes.txt.(conflicted copy)1"
expect_eq "resolve: keep-both keeps the local copy" "copy" "$(cat "${RES_DIR}/notes (local copy).txt")"
expect_eq "resolve: keep-both keeps the base" "base" "$(cat "${RES_DIR}/notes.txt")"
printf 'copy2\n' >"${RES_DIR}/notes.txt.(conflicted copy)1"
expect_cli "resolve: second keep-both apply rc 0" 0 run_cli conflicts --resolve keep-both --apply --yes
expect_eq "resolve: keep-both appends -2" "copy2" "$(cat "${RES_DIR}/notes (local copy)-2.txt")"

# --- keep-newest/keep-oldest compare mtimes ---------------------------------
make_case base copy
touch -t 202001010000 "${RES_DIR}/notes.txt"
touch -t 203001010000 "${RES_DIR}/notes.txt.(conflicted copy)1"
expect_cli "resolve: keep-newest apply rc 0" 0 run_cli conflicts --resolve keep-newest --apply --yes
expect_eq "resolve: keep-newest picks the newer copy" "copy" "$(cat "${RES_DIR}/notes.txt")"
expect_no_file "resolve: keep-newest removes the copy" "${RES_DIR}/notes.txt.(conflicted copy)1"

make_case base copy
touch -t 203001010000 "${RES_DIR}/notes.txt"
touch -t 202001010000 "${RES_DIR}/notes.txt.(conflicted copy)1"
expect_cli "resolve: keep-oldest apply rc 0" 0 run_cli conflicts --resolve keep-oldest --apply --yes
expect_eq "resolve: keep-oldest picks the older copy" "copy" "$(cat "${RES_DIR}/notes.txt")"
expect_no_file "resolve: keep-oldest removes the copy" "${RES_DIR}/notes.txt.(conflicted copy)1"

# --- desktop-client style name derives back to the original ------------------
rm -rf "$RES_DIR"
mkdir -p "$RES_DIR"
printf 'dest\n' >"${RES_DIR}/mydata.txt"
printf 'conflict\n' >"${RES_DIR}/mydata (conflicted copy 2018-04-10 093612).txt"
expect_cli "resolve: desktop-style dry run rc 0" 0 run_cli conflicts --resolve keep-local
expect_contains "resolve: desktop-style base is derived" "$CLI_OUT" "mydata (conflicted copy 2018-04-10 093612).txt -> keep-local mydata.txt"
expect_cli "resolve: desktop-style apply rc 0" 0 run_cli conflicts --resolve keep-local --apply --yes
expect_eq "resolve: desktop-style content moved" "conflict" "$(cat "${RES_DIR}/mydata.txt")"

# --- --json reports the plan ------------------------------------------------
make_case base copy
expect_cli "resolve: --json dry run rc 0" 0 run_cli conflicts --resolve keep-local --json
expect_contains "resolve: --json has items" "$CLI_OUT" '"items"'
expect_contains "resolve: --json has action" "$CLI_OUT" '"action": "keep-local"'
expect_contains "resolve: --json counts a total" "$CLI_OUT" '"total": 1'
expect_contains "resolve: --json counts a skip" "$CLI_OUT" '"skipped": 0'
expect_file "resolve: --json dry run keeps the copy" "${RES_DIR}/notes.txt.(conflicted copy)1"

# --- usage and confirmation errors ------------------------------------------
expect_cli "resolve: unknown mode rc 2" 2 run_cli conflicts --resolve keep-nothing
expect_contains "resolve: unknown mode lists the modes" "$CLI_OUT" "unknown --resolve mode"
expect_cli "resolve: --apply without --resolve rc 2" 2 run_cli conflicts --apply
expect_cli "resolve: --json without --resolve rc 2" 2 run_cli conflicts --json

make_case base copy
expect_cli "resolve: --apply without --yes rc 2" 2 run_cli conflicts --resolve keep-local --apply </dev/null
expect_contains "resolve: --apply names --yes" "$CLI_OUT" "requires --yes"
expect_eq "resolve: aborted apply keeps the base" "base" "$(cat "${RES_DIR}/notes.txt")"
expect_file "resolve: aborted apply keeps the copy" "${RES_DIR}/notes.txt.(conflicted copy)1"

# --- case-clash rows: dry run, keep-both, and the kind filter ---------------
# make_case_clash BASE_CONTENT COPY_CONTENT - recreate the source dir with
# notes.txt and its "(case conflict)" quarantine file.
make_case_clash() {
  local base_content="$1" copy_content="$2"
  rm -rf "$RES_DIR"
  mkdir -p "$RES_DIR"
  printf '%s\n' "$base_content" >"${RES_DIR}/notes.txt"
  printf '%s\n' "$copy_content" >"${RES_DIR}/notes (case conflict).txt"
}

make_case_clash base casecopy
expect_cli "resolve case: dry run rc 0" 0 run_cli conflicts --resolve keep-both --kind case
expect_contains "resolve case: dry run plan line" "$CLI_OUT" "notes notes (case conflict).txt -> keep-both notes (local copy).txt"
expect_contains "resolve case: dry run summary" "$CLI_OUT" "1 to resolve (dry run)"
expect_file "resolve case: dry run keeps the quarantine file" "${RES_DIR}/notes (case conflict).txt"
expect_eq "resolve case: dry run keeps the base" "base" "$(cat "${RES_DIR}/notes.txt")"

expect_cli "resolve case: keep-both apply rc 0" 0 run_cli conflicts --resolve keep-both --apply --yes --kind case
expect_no_file "resolve case: quarantine name gone" "${RES_DIR}/notes (case conflict).txt"
expect_eq "resolve case: renamed to the local copy name" "casecopy" "$(cat "${RES_DIR}/notes (local copy).txt")"
expect_eq "resolve case: keep-both keeps the base" "base" "$(cat "${RES_DIR}/notes.txt")"
expect_cli "resolve case: renamed file matches neither pattern" 0 run_cli conflicts --quiet

make_case_clash base casecopy
expect_cli "resolve case: keep-local apply rc 0" 0 run_cli conflicts --resolve keep-local --apply --yes --kind case
expect_eq "resolve case: keep-local moves the file over the base" "casecopy" "$(cat "${RES_DIR}/notes.txt")"
expect_no_file "resolve case: keep-local removes the quarantine file" "${RES_DIR}/notes (case conflict).txt"

make_case_clash base casecopy
expect_cli "resolve case: keep-remote apply rc 0" 0 run_cli conflicts --resolve keep-remote --apply --yes --kind case
expect_eq "resolve case: keep-remote keeps the base" "base" "$(cat "${RES_DIR}/notes.txt")"
expect_no_file "resolve case: keep-remote deletes the quarantine file" "${RES_DIR}/notes (case conflict).txt"

make_case_clash base casecopy
expect_cli "resolve case: --kind copy skips case rows" 0 run_cli conflicts --resolve keep-remote --kind copy
expect_contains "resolve case: filtered dry run is empty" "$CLI_OUT" "no conflict copies"
expect_file "resolve case: --kind copy leaves the case row" "${RES_DIR}/notes (case conflict).txt"

make_case base copy
expect_cli "resolve case: --kind case skips copy rows" 0 run_cli conflicts --resolve keep-remote --kind case
expect_contains "resolve case: filtered copies are empty" "$CLI_OUT" "no conflict copies"
expect_file "resolve case: --kind case leaves the copy row" "${RES_DIR}/notes.txt.(conflicted copy)1"

make_case_clash base casecopy
expect_cli "resolve case: --json rc 0" 0 run_cli conflicts --resolve keep-both --json --kind case
expect_contains "resolve case: json kind" "$CLI_OUT" '"kind": "case"'
expect_contains "resolve case: json path" "$CLI_OUT" '"path": "notes (case conflict).txt"'
expect_contains "resolve case: json target" "$CLI_OUT" '"target": "notes (local copy).txt"'
expect_file "resolve case: json dry run keeps the quarantine file" "${RES_DIR}/notes (case conflict).txt"

finish
