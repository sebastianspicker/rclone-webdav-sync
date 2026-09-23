#!/usr/bin/env bash
# folders_import.sh - `sciebo folders import`: migrate a nextcloudcmd
# --unsyncedfolders list into a folder pair plus its pair filter.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

# Keep the default mode deterministic: import without --mode must pick this
# up from DEFAULT_PAIR_MODE (settings.env uses :=, so exported values win).
export DEFAULT_PAIR_MODE=pull

# Fixture: local remote trees under $TMP/backup (REMOTE_BASE), browsed
# through the real `testremote` local backend; no network needed.
mkdir -p "${TMP}/backup/import-src/one" "${TMP}/backup/import-src/two"
mkdir -p "${TMP}/backup/import-plain"
mkdir -p "${TMP}/backup/import-select/a" "${TMP}/backup/import-select/b" "${TMP}/backup/import-select/c"
mkdir -p "${TMP}/backup/import-comments"

# --- import: listed folders become excludes --------------------------------
# Blank lines and #-comments are ignored; surrounding whitespace is trimmed
# and trailing slashes are stripped.
IMPORT_LIST="${TMP}/unsynced-main.txt"
printf '\n# nextcloudcmd --unsyncedfolders migration\none\n  two/  \n' >"$IMPORT_LIST"

expect_cli "import: rc 0" 0 run_cli folders import "$IMPORT_LIST" --remote import-src --local "${TMP}/import-local" --mode pull
expect_contains "import: added line" "$CLI_OUT" "Added pull import-src: ${TMP}/import-local -> testremote:backup/import-src"
expect_contains "import: next-step hint" "$CLI_OUT" "Next: make check (dry run), then make sync"
expect_contains "import: pair written with its filter" "$(cat "$FOLDERS_FILE")" "pull|${TMP}/import-local|import-src|pair-import-src.txt"
expect_file "import: pair filter created" "${FILTER_DIR}/pair-import-src.txt"
import_filter="$(cat "${FILTER_DIR}/pair-import-src.txt")"
expect_contains "import: first listed folder excluded" "$import_filter" "- one/"
expect_contains "import: whitespace trimmed, slash stripped" "$import_filter" "- two/"
expect_eq "import: exactly the two listed excludes" "2" "$(grep -c '^- ' "${FILTER_DIR}/pair-import-src.txt")"

expect_cli "import: folders list rc 0" 0 run_cli folders list
expect_contains "import: pair shown in folders list" "$CLI_OUT" "import-src"
expect_contains "import: filter column wired" "$CLI_OUT" "pair-import-src.txt"
expect_cli "import: driver list rc 0" 0 run_cli list
expect_contains "import: pair feeds the driver" "$CLI_OUT" "import-src"

# --- pause / resume: the per-pair paused flag -------------------------------
expect_cli "pause: rc 0" 0 run_cli folders pause import-src
expect_contains "pause: reports" "$CLI_OUT" "Paused 'import-src'"
expect_contains "pause: flag written" "$(cat "${STATE_DIR}/pairs/import-src")" "paused=1"
expect_cli "pause: list json rc 0" 0 run_cli folders list --json
expect_contains "pause: list json surfaces paused" "$CLI_OUT" '"paused": true'
expect_cli "resume: rc 0" 0 run_cli folders resume import-src
expect_contains "resume: reports" "$CLI_OUT" "Resumed 'import-src'"
expect_contains "resume: flag cleared" "$(cat "${STATE_DIR}/pairs/import-src")" "paused=0"
expect_cli "pause: unknown name rc 1" 1 run_cli folders pause nosuch
expect_contains "pause: unknown name message" "$CLI_OUT" "No source named 'nosuch'"
expect_cli "pause: missing NAME rc 2" 2 run_cli folders pause
expect_contains "pause: missing NAME message" "$CLI_OUT" "NAME"

# Defaults: mode from DEFAULT_PAIR_MODE (pull) and destination from
# --local-root/<SUB> when --local is omitted.
expect_cli "import: default destination rc 0" 0 run_cli folders import "$IMPORT_LIST" --remote import-plain --local-root "${TMP}/import-root"
expect_contains "import: default mode and destination" "$(cat "$FOLDERS_FILE")" "pull|${TMP}/import-root/import-plain|import-plain|pair-import-plain.txt"

# A comment-only list adds the pair without a filter file.
COMMENT_LIST="${TMP}/unsynced-comments.txt"
printf '# nothing to exclude\n\n' >"$COMMENT_LIST"
expect_cli "import: comment-only list rc 0" 0 run_cli folders import "$COMMENT_LIST" --remote import-comments --local "${TMP}/comment-local" --mode pull
expect_contains "import: comment-only pair written" "$(cat "$FOLDERS_FILE")" "pull|${TMP}/comment-local|import-comments"
expect_not_contains "import: comment-only pair has no filter" "$(cat "$FOLDERS_FILE")" "pair-import-comments"
expect_no_file "import: comment-only writes no filter file" "${FILTER_DIR}/pair-import-comments.txt"

# --- import --select: the listed folders are the only ones to sync ---------
SELECT_LIST="${TMP}/unsynced-select.txt"
printf '# keep only a\na\n' >"$SELECT_LIST"
expect_cli "import --select: rc 0" 0 run_cli folders import "$SELECT_LIST" --remote import-select --local "${TMP}/select-local" --mode pull --select
expect_contains "import --select: pair written" "$(cat "$FOLDERS_FILE")" "pull|${TMP}/select-local|import-select|pair-import-select.txt"
select_filter="$(cat "${FILTER_DIR}/pair-import-select.txt")"
expect_contains "import --select: unlisted child b excluded" "$select_filter" "- b/"
expect_contains "import --select: unlisted child c excluded" "$select_filter" "- c/"
expect_not_contains "import --select: listed child a kept" "$select_filter" "- a/"

# A failing remote listing dies with rclone's message, before anything is
# written (mode sync would otherwise only warn about the missing folder).
expect_cli "import --select: missing remote rc 1" 1 run_cli folders import "$SELECT_LIST" --remote import-missing --local "${TMP}/missing-local" --mode sync --select
expect_contains "import --select: rclone message kept" "$CLI_OUT" "directory not found"
expect_not_contains "import --select: failed import adds no pair" "$(cat "$FOLDERS_FILE")" "import-missing"
expect_no_file "import --select: failed import writes no filter" "${FILTER_DIR}/pair-import-missing.txt"

# --- guards ----------------------------------------------------------------
BAD_LIST="${TMP}/unsynced-bad.txt"
printf '../x\n' >"$BAD_LIST"
expect_cli "import: unsafe path rc 2" 2 run_cli folders import "$BAD_LIST" --remote import-src2 --local "${TMP}/bad-local" --mode pull
expect_contains "import: unsafe path message" "$CLI_OUT" "invalid folder path '../x'"
ABS_LIST="${TMP}/unsynced-abs.txt"
printf '/etc/passwd\n' >"$ABS_LIST"
expect_cli "import: absolute path rc 2" 2 run_cli folders import "$ABS_LIST" --remote import-src2 --local "${TMP}/abs-local" --mode pull
expect_contains "import: absolute path message" "$CLI_OUT" "invalid folder path"
expect_cli "import: missing FILE rc 2" 2 run_cli folders import --remote import-src
expect_contains "import: missing FILE message" "$CLI_OUT" "FILE is required"
expect_cli "import: missing --remote rc 2" 2 run_cli folders import "$IMPORT_LIST"
expect_contains "import: missing --remote message" "$CLI_OUT" "--remote is required"
expect_cli "import: unreadable list rc 1" 1 run_cli folders import "${TMP}/no-such-list.txt" --remote import-src
expect_contains "import: unreadable list message" "$CLI_OUT" "cannot read list file"
expect_cli "import: unknown option rc 2" 2 run_cli folders import "$IMPORT_LIST" --remote import-src --bogus
expect_cli "import: help rc 0" 0 run_cli folders import --help
expect_contains "import: usage documents the subcommand" "$CLI_OUT" "import FILE"

# --- duplicate import is refused and leaves the filter alone ---------------
cp "${FILTER_DIR}/pair-import-src.txt" "${TMP}/import-filter.before"
expect_cli "import: duplicate pair rc 1" 1 run_cli folders import "$IMPORT_LIST" --remote import-src --local "${TMP}/import-local-2" --mode pull
expect_contains "import: duplicate message" "$CLI_OUT" "already"
expect_same "import: duplicate leaves the pair filter unchanged" "${TMP}/import-filter.before" "${FILTER_DIR}/pair-import-src.txt"
expect_not_contains "import: duplicate adds no second line" "$(cat "$FOLDERS_FILE")" "import-local-2"

# --- remove --purge cleans up an imported pair's filter and state ------------
mkdir -p "${TMP}/state/bisync/import-plain" "${TMP}/state/blacklist"
printf '1\tx\tboom\n' >"${TMP}/state/blacklist/import-plain"
printf 'paused=1\n' >"${STATE_DIR}/pairs/import-plain"
expect_cli "import: remove --purge rc 0" 0 run_cli folders remove import-plain --purge
expect_contains "import: remove --purge reports" "$CLI_OUT" "Purged state for 'import-plain'"
expect_not_contains "import: remove --purge drops the pair" "$(cat "$FOLDERS_FILE")" "import-plain"
expect_no_file "import: remove --purge drops the pair filter" "${FILTER_DIR}/pair-import-plain.txt"
expect_no_file "import: remove --purge drops the blacklist record" "${TMP}/state/blacklist/import-plain"
expect_no_file "import: remove --purge drops the bisync workdir" "${TMP}/state/bisync/import-plain"
expect_no_file "import: remove --purge drops the pair flags" "${STATE_DIR}/pairs/import-plain"

finish
