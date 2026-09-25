#!/usr/bin/env bash
# folders_edit.sh - `sciebo folders edit`: include/exclude filter rewrites,
# direction changes, filter clearing, ownership guards, plus the
# big-folder discovery hook (stub rclone).
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

# Fixture: a wizard pair on the real `testremote` local backend, with four
# immediate children so an include selection leaves a distinguishable
# complement.
mkdir -p "${TMP}/backup/papers/code" "${TMP}/backup/papers/docs" \
  "${TMP}/backup/papers/drafts" "${TMP}/backup/papers/extra"
mkdir -p "${TMP}/src"
printf 'bisync|%s/src|papers\n' "$TMP" >"$FOLDERS_FILE"

# --- include: the complement of the pick becomes the filter ----------------
expect_cli "edit --include: rc 0" 0 run_cli folders edit papers --include code --include docs
expect_contains "edit --include: update line" "$CLI_OUT" "updated pair papers (filter pair-papers.txt)"
expect_file "edit --include: filter written" "${FILTER_DIR}/pair-papers.txt"
edit_filter="$(cat "${FILTER_DIR}/pair-papers.txt")"
expect_contains "edit --include: unlisted child excluded" "$edit_filter" "- drafts/"
expect_contains "edit --include: other unlisted child excluded" "$edit_filter" "- extra/"
expect_not_contains "edit --include: included child kept" "$edit_filter" "- code/"
expect_contains "edit --include: manifest keeps the filter column" "$(cat "$FOLDERS_FILE")" "bisync|${TMP}/src|papers|pair-papers.txt"

# --- exclude: the filter is rewritten with the explicit rules ---------------
expect_cli "edit --exclude: rc 0" 0 run_cli folders edit papers --exclude drafts
expect_contains "edit --exclude: update line" "$CLI_OUT" "updated pair papers (filter pair-papers.txt)"
edit_filter="$(cat "${FILTER_DIR}/pair-papers.txt")"
expect_contains "edit --exclude: rule written" "$edit_filter" "- drafts/"
expect_not_contains "edit --exclude: include complement replaced" "$edit_filter" "- extra/"

# --- mode: the line is rewritten, the filter column survives ----------------
expect_cli "edit --mode: rc 0" 0 run_cli folders edit papers --mode sync
expect_contains "edit --mode: update line" "$CLI_OUT" "updated pair papers (mode sync)"
expect_contains "edit --mode: manifest line rewritten" "$(cat "$FOLDERS_FILE")" "sync|${TMP}/src|papers|pair-papers.txt"
expect_not_contains "edit --mode: old direction gone" "$(cat "$FOLDERS_FILE")" "bisync|${TMP}/src|papers"
expect_file "edit --mode: filter file kept" "${FILTER_DIR}/pair-papers.txt"

# --- clear: the filter file and its column are removed ----------------------
expect_cli "edit --clear: rc 0" 0 run_cli folders edit papers --clear
expect_contains "edit --clear: update line" "$CLI_OUT" "updated pair papers (filter -)"
expect_no_file "edit --clear: filter file removed" "${FILTER_DIR}/pair-papers.txt"
expect_contains "edit --clear: manifest line without filter" "$(cat "$FOLDERS_FILE")" "sync|${TMP}/src|papers"
expect_not_contains "edit --clear: no filter reference left" "$(cat "$FOLDERS_FILE")" "pair-papers"
expect_cli "edit --clear: folders list rc 0" 0 run_cli folders list
expect_contains "edit --clear: pair still listed" "$CLI_OUT" "papers"

# --- guards ------------------------------------------------------------------
expect_cli "edit: unknown name rc 1" 1 run_cli folders edit nosuch --exclude x
expect_contains "edit: unknown name message" "$CLI_OUT" "no pair named 'nosuch'"
expect_contains "edit: unknown name points at the wizard file" "$CLI_OUT" "folders.conf"
expect_cli "edit: no options rc 2" 2 run_cli folders edit papers
expect_contains "edit: no options message" "$CLI_OUT" "at least one of"
expect_cli "edit: missing NAME rc 2" 2 run_cli folders edit --exclude x
expect_contains "edit: missing NAME message" "$CLI_OUT" "NAME is required"
expect_cli "edit: clear plus filter rc 2" 2 run_cli folders edit papers --clear --exclude drafts
expect_contains "edit: clear conflict message" "$CLI_OUT" "cannot be combined"
expect_cli "edit: include plus select rc 2" 2 run_cli folders edit papers --include code --select
expect_contains "edit: include/select conflict" "$CLI_OUT" "mutually exclusive"
expect_cli "edit: unknown child rc 1" 1 run_cli folders edit papers --include nope
expect_contains "edit: unknown child lists available" "$CLI_OUT" "unknown subfolder 'nope'"

printf 'sync|%s/manual|manualpair\n' "$TMP" >>"$MANIFEST_FILE"
expect_cli "edit: manual entry rc 1" 1 run_cli folders edit manualpair --exclude x
expect_contains "edit: manual entry points at its file" "$CLI_OUT" "sources.conf"

# --- list --json: the same rows as the table, as {"pairs":[...]} -------------
expect_cli "list --json: rc 0" 0 run_cli folders list --json
expect_contains "list --json: pairs array" "$CLI_OUT" '"pairs": ['
expect_contains "list --json: wizard pair" "$CLI_OUT" '"name": "papers"'
expect_contains "list --json: manual pair" "$CLI_OUT" '"name": "manualpair"'
expect_contains "list --json: source column" "$CLI_OUT" '"source": "wizard"'
expect_contains "list --json: mode column" "$CLI_OUT" '"mode": "sync"'
expect_not_contains "list --json: no table header" "$CLI_OUT" "NAME"
expect_cli "list --json: unknown option rc 2" 2 run_cli folders list --bogus
expect_contains "list --json: unknown option message" "$CLI_OUT" "unknown option"

# --- remove --purge: the pair's state and filter are cleaned up --------------
mkdir -p "${TMP}/state/bisync/purgepair" "${TMP}/state/blacklist" \
  "${TMP}/state/last" "${TMP}/state/history"
printf 'pull|%s/purged-local|purgepair|pair-purgepair.txt\n' "$TMP" >>"$FOLDERS_FILE"
printf -- '- x/\n' >"${FILTER_DIR}/pair-purgepair.txt"
printf '1\tx\tboom\n' >"${TMP}/state/blacklist/purgepair"
printf 'time=1\n' >"${TMP}/state/last/purgepair"
printf '1\tok\t\n' >"${TMP}/state/history/purgepair.log"
expect_cli "remove --purge: rc 0" 0 run_cli folders remove purgepair --purge
expect_contains "remove --purge: removed line" "$CLI_OUT" "Removed 'purgepair'"
expect_contains "remove --purge: purge reported" "$CLI_OUT" "Purged state for 'purgepair'"
expect_not_contains "remove --purge: pair line gone" "$(cat "$FOLDERS_FILE")" "purgepair"
expect_no_file "remove --purge: bisync workdir removed" "${TMP}/state/bisync/purgepair"
expect_no_file "remove --purge: run record removed" "${TMP}/state/last/purgepair"
expect_no_file "remove --purge: history removed" "${TMP}/state/history/purgepair.log"
expect_no_file "remove --purge: blacklist removed" "${TMP}/state/blacklist/purgepair"
expect_no_file "remove --purge: pair filter removed" "${FILTER_DIR}/pair-purgepair.txt"

# --- remove without --purge: today's behavior, only a note -------------------
mkdir -p "${TMP}/state/bisync/notepair"
printf 'sync|%s/notepair-local|notepair\n' "$TMP" >>"$FOLDERS_FILE"
expect_cli "remove: rc 0" 0 run_cli folders remove notepair
expect_contains "remove: leftover note" "$CLI_OUT" "bisync state remains"
expect_eq "remove: state kept without --purge" "yes" \
  "$([[ -d "${TMP}/state/bisync/notepair" ]] && printf 'yes' || printf 'no')"
rm -rf "${TMP}/state/bisync/notepair"

# --- edit --local: only the local path is rewritten -------------------------
printf 'sync|%s/pathlocal-old|pathlocal\n' "$TMP" >>"$FOLDERS_FILE"
expect_cli "edit --local: rc 0" 0 run_cli folders edit pathlocal --local "${TMP}/pathlocal-new"
expect_contains "edit --local: update line" "$CLI_OUT" "updated pair pathlocal (local ${TMP}/pathlocal-new)"
expect_contains "edit --local: manifest rewritten" "$(cat "$FOLDERS_FILE")" "sync|${TMP}/pathlocal-new|pathlocal"
expect_not_contains "edit --local: old local gone" "$(cat "$FOLDERS_FILE")" "pathlocal-old"
# shellcheck disable=SC2088  # a literal ~ is handed to expand_local_path
tilde_local='~/pathlocal-tilde'
expect_cli "edit --local: tilde expands rc 0" 0 run_cli folders edit pathlocal --local "$tilde_local"
expect_contains "edit --local: tilde expanded" "$(cat "$FOLDERS_FILE")" "sync|${HOME}/pathlocal-tilde|pathlocal"
expect_cli "edit --local: unsafe path rc 1" 1 run_cli folders edit pathlocal --local '../escape'
expect_contains "edit --local: unsafe path message" "$CLI_OUT" "invalid local path"

# --- edit --remote: the remote subdir and the derived pair name change -------
printf 'sync|%s/mover-local|mover-src\n' "$TMP" >>"$FOLDERS_FILE"
expect_cli "edit --remote: rc 0" 0 run_cli folders edit mover-src --remote mover-dst
expect_contains "edit --remote: update line" "$CLI_OUT" "updated pair mover-dst (remote testremote:backup/mover-dst)"
expect_contains "edit --remote: manifest rewritten" "$(cat "$FOLDERS_FILE")" "sync|${TMP}/mover-local|mover-dst"
expect_not_contains "edit --remote: old remote gone" "$(cat "$FOLDERS_FILE")" "mover-src"

# --remote / means the remote base, stored as "." like provision does.
printf 'sync|%s/baselocal|baseremote\n' "$TMP" >>"$FOLDERS_FILE"
expect_cli "edit --remote /: rc 0" 0 run_cli folders edit baseremote --remote /
expect_contains "edit --remote /: update line" "$CLI_OUT" "updated pair entry (remote testremote:backup/.)"
expect_contains "edit --remote /: base stored as dot" "$(cat "$FOLDERS_FILE")" "sync|${TMP}/baselocal|."

# --- edit --remote: duplicate remote and name are refused --------------------
expect_cli "edit --remote: duplicate remote rc 1" 1 run_cli folders edit pathlocal --remote papers
expect_contains "edit --remote: duplicate remote message" "$CLI_OUT" "already configured"
expect_contains "edit --remote: duplicate remote leaves the pair in place" "$(cat "$FOLDERS_FILE")" "|pathlocal"
expect_cli "edit --remote: duplicate name rc 1" 1 run_cli folders edit pathlocal --remote 'papers!'
expect_contains "edit --remote: duplicate name message" "$CLI_OUT" "already exists"

# --- edit --remote: initialized bisync state needs --force ------------------
mkdir -p "${STATE_DIR}/bisync/bisyncpair"
printf 'state\n' >"${STATE_DIR}/bisync/bisyncpair/bisync.pt"
printf 'bisync|%s/bisync-local|bisyncpair\n' "$TMP" >>"$FOLDERS_FILE"
expect_cli "edit --remote: bisync guard rc 1" 1 run_cli folders edit bisyncpair --remote bisync-new
expect_contains "edit --remote: bisync guard explains the mismatch" "$CLI_OUT" "no longer matches"
expect_contains "edit --remote: bisync guard points at --resync" "$CLI_OUT" "sync --resync"
expect_contains "edit --remote: bisync guard keeps the pair" "$(cat "$FOLDERS_FILE")" "bisync|${TMP}/bisync-local|bisyncpair"
expect_cli "edit --remote: --force rc 0" 0 run_cli folders edit bisyncpair --remote bisync-new --force
expect_contains "edit --remote: --force warns about the mismatch" "$CLI_OUT" "no longer matches"
expect_contains "edit --remote: --force rewrites the remote" "$(cat "$FOLDERS_FILE")" "bisync|${TMP}/bisync-local|bisync-new"
expect_eq "edit --remote: --force keeps the bisync state" "yes" \
  "$([[ -d "${STATE_DIR}/bisync/bisyncpair" ]] && printf 'yes' || printf 'no')"

# --- folders list: bisync workdir initialization column ----------------------
# The listing resolves every bisync row's initialization from one precomputed
# set. A workdir with a real file is "initialized"; one holding only `-dry`
# artifacts is "missing".
mkdir -p "${STATE_DIR}/bisync/initpair" "${STATE_DIR}/bisync/drypair"
printf 'state\n' >"${STATE_DIR}/bisync/initpair/bisync.pt"
printf 'state\n' >"${STATE_DIR}/bisync/drypair/listing.lst-dry"
printf 'bisync|%s/init-local|initpair\n' "$TMP" >>"$FOLDERS_FILE"
printf 'bisync|%s/dry-local|drypair\n' "$TMP" >>"$FOLDERS_FILE"
expect_cli "list: bisync column rc 0" 0 run_cli folders list
expect_contains "list: initialized workdir" "$CLI_OUT" "bisync=initialized"
expect_contains "list: dry-only workdir is missing" "$CLI_OUT" "bisync=missing"

# --- bigfolder_notify: warn once per large unconfigured folder --------------
BF_BIN="${TMP}/bigfolder-bin"
mkdir -p "$BF_BIN"
cat >"${BF_BIN}/rclone" <<'STUB'
#!/bin/bash
dir="$(cd "$(dirname "$0")" && pwd)"
printf '%s\n' "$*" >>"${dir}/calls.log"
case "$*" in
  *"-R"*)
    printf '%s\n' '-1;videos/' '-1;tiny/'
    printf '%s\n' '5242880;videos/clip.bin' '1024;tiny/note.bin'
    ;;
  *" lsf "*)
    printf 'videos/\n'
    printf 'tiny/\n'
    ;;
  *" size "*"videos"*)
    printf '{"count":2,"bytes":5242880,"sizeless":0}\n'
    ;;
  *" size "*)
    printf '{"count":1,"bytes":1024,"sizeless":0}\n'
    ;;
esac
exit 0
STUB
chmod +x "${BF_BIN}/rclone"

export BIG_FOLDER_SIZE=1M
export STATE_DIR="${TMP}/bigfolder-state"
export RCLONE_BIN="${BF_BIN}/rclone"
export REMOTE_PREFIX=testremote:backup
capture bigfolder_notify bigroot bigroot
expect_rc "bigfolder: first scan rc 0" "$CLI_RC" 0
expect_contains "bigfolder: large folder warned" "$CLI_OUT" "big folder: bigroot/videos is 5Mi"
expect_contains "bigfolder: add hint" "$CLI_OUT" "add it with 'sciebo folders add'"
expect_not_contains "bigfolder: small folder not warned" "$CLI_OUT" "bigroot/tiny"
expect_file "bigfolder: seen cache written" "${STATE_DIR}/bigfolder/bigroot"
expect_contains "bigfolder: seen cache content" "$(cat "${STATE_DIR}/bigfolder/bigroot")" "videos"

capture bigfolder_notify bigroot bigroot
expect_rc "bigfolder: second scan rc 0" "$CLI_RC" 0
expect_not_contains "bigfolder: second scan does not re-warn" "$CLI_OUT" "big folder:"

# A pair filter rule covers the folder: no warning, even without a cache.
rm -rf "${STATE_DIR}/bigfolder"
printf 'pull|%s/biglocal|bigroot|pair-bigroot.txt\n' "$TMP" >>"$FOLDERS_FILE"
printf -- '- videos/\n' >"${FILTER_DIR}/pair-bigroot.txt"
manifest_index_invalidate
capture bigfolder_notify bigroot bigroot
expect_rc "bigfolder: filtered folder rc 0" "$CLI_RC" 0
expect_not_contains "bigfolder: pair filter rule suppresses the warning" "$CLI_OUT" "big folder:"
expect_no_file "bigfolder: covered folder not cached" "${STATE_DIR}/bigfolder/bigroot"

# --- folders list: last-log lookup is an O(1) prefix index -------------------
# The listing snapshots `ls -1t` once and indexes it by dash-delimited name
# prefix, so each row is a lookup rather than a rescan. The newest match per
# name wins and a miss is "-".
# shellcheck source=../../lib/commands/folders.sh
source "${PROJ}/lib/commands/folders.sh"
FOLDERS_LIST_LOG_SNAPSHOT=$'notes-20240101-120000.log\nnotes-20230101-120000.log\ndir-pair-20240101-120000.log'
_folders_last_log_index_prime
got=""
folders_last_log_for_into got notes
expect_eq "list: newest log for a name" "notes-20240101-120000.log" "$got"
folders_last_log_for_into got dir-pair
expect_eq "list: newest log for a dashed name" "dir-pair-20240101-120000.log" "$got"
folders_last_log_for_into got missing
expect_eq "list: missing log is a dash" "-" "$got"

finish
