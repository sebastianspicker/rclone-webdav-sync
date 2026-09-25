#!/usr/bin/env bash
# blacklist.sh - failure-blacklist records, `sciebo retry`, and BACKUP_DIR.
# The unit section calls lib/state/blacklist.sh (loaded by env.sh) directly; the
# end-to-end runs use a stub rclone that fails with rclone's plain ERROR log
# format, and the BACKUP_DIR check pulls with the real local testremote.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

export BLACKLIST_DIR="${TMP}/blacklist" BLACKLIST_ENABLED=1 BLACKLIST_MAX_FAILS=3

# blacklist_cat NAME - print NAME's raw TSV records (the record file is a
# plain text store).
blacklist_cat() {
  local file=""
  file="$(blacklist_file "${1:-}")" || return 1
  [[ -f "$file" && -r "$file" ]] || return 1
  cat "$file"
}

# blacklist_record_stub NAME PATH ERROR - record one failure through the
# public batch writer (the single-record wrapper was removed).
blacklist_record_stub() {
  [[ -n "${2:-}" ]] || return 1
  printf '%s\t%s\n' "$2" "$3" | blacklist_record_many "$1"
}

# blacklist_fail_count NAME PATH - the stored failure count for one path.
blacklist_fail_count() {
  blacklist_cat "$1" | awk -F'\t' -v path="$2" '$2 == path { print $1 }'
}

# --- record, read, count, clear ------------------------------------------
blacklist_record_stub bl-unit notes/a.txt "permission denied"
blacklist_record_stub bl-unit notes/a.txt "permission denied"
blacklist_record_stub bl-unit notes/b.txt "input/output error"
expect_eq "blacklist: increment records the count" "2" "$(blacklist_cat bl-unit | awk -F'\t' '$2 == "notes/a.txt" { print $1 }')"
expect_eq "blacklist: record mode is 600" "600" "$(file_mode "$(blacklist_file bl-unit)")"
expect_eq "blacklist: error text is recorded" "permission denied" "$(blacklist_cat bl-unit | awk -F'\t' '$2 == "notes/a.txt" { print $3 }')"
expect_eq "blacklist: distinct paths are counted" "2" "$(blacklist_count bl-unit)"
expect_eq "blacklist: missing source reads empty" "" "$(blacklist_cat bl-missing)"
expect_eq "blacklist: missing source counts zero" "0" "$(blacklist_count bl-missing)"

# --- fork-free _into helpers ---------------------------------------------
# The record walkers parse counts, next fields, and backoff deadlines in the
# caller's shell; these *_into forms are the only shape (no printing
# wrappers), so they carry the coverage here.
bl_norm="" bl_next="" bl_epoch=""
_blacklist_norm_count_into bl_norm "42"
expect_eq "blacklist_into: norm_count keeps digits" "42" "$bl_norm"
_blacklist_norm_count_into bl_norm "x"
expect_eq "blacklist_into: norm_count defaults to 0" "0" "$bl_norm"
bl_rc=0
_blacklist_parse_next_into bl_next "next=99"
expect_eq "blacklist_into: parse_next decodes next=" "99" "$bl_next"
_blacklist_parse_next_into bl_next "bogus" || bl_rc=$?
expect_rc "blacklist_into: parse_next malformed rc 1" "$bl_rc" 1
expect_eq "blacklist_into: parse_next malformed clears the var" "" "$bl_next"
_blacklist_next_epoch_into bl_epoch 0
expect_eq "blacklist_into: below threshold is 0" "0" "$bl_epoch"
_blacklist_next_epoch_into bl_epoch 3
bl_epoch_ok=no
[[ "$bl_epoch" =~ ^[0-9]+$ && "$bl_epoch" -gt 0 ]] && bl_epoch_ok=yes
expect_eq "blacklist_into: at threshold is a future epoch" "yes" "$bl_epoch_ok"

# --- thresholds and escaping ---------------------------------------------
for _ in 1 2 3; do
  blacklist_record_stub bl-glob 'notes/a[b]*.txt' "denied"
  blacklist_record_stub bl-glob 'notes/q?.txt' "denied"
  blacklist_record_stub bl-glob 'notes/back\slash.txt' "denied"
  blacklist_record_stub bl-glob 'notes/close]b.txt' "denied"
  blacklist_record_stub bl-glob 'notes/brace{b}.txt' "denied"
done
# rclone aborts on a bare "]" or "}" in a glob, so the escaped form is the
# only one that keeps later sync/pull/bisync runs working.
expect_eq "blacklist: bracket and star escaped in exclude" '/notes/a\[b\]\*.txt' "$(blacklist_excluded bl-glob | sed -n '1p')"
expect_eq "blacklist: question mark escaped in exclude" '/notes/q\?.txt' "$(blacklist_excluded bl-glob | sed -n '2p')"
expect_eq "blacklist: backslash escaped in exclude" '/notes/back\\slash.txt' "$(blacklist_excluded bl-glob | sed -n '3p')"
expect_eq "blacklist: closing bracket escaped in exclude" '/notes/close\]b.txt' "$(blacklist_excluded bl-glob | sed -n '4p')"
expect_eq "blacklist: braces escaped in exclude" '/notes/brace\{b\}.txt' "$(blacklist_excluded bl-glob | sed -n '5p')"
blacklist_record_stub bl-threshold x.txt "denied"
blacklist_record_stub bl-threshold x.txt "denied"
expect_eq "blacklist: under threshold not excluded" "" "$(blacklist_excluded bl-threshold)"
blacklist_record_stub bl-threshold x.txt "denied"
expect_eq "blacklist: at threshold excluded" "/x.txt" "$(blacklist_excluded bl-threshold)"

# --- clear and list -------------------------------------------------------
blacklist_clear bl-unit notes/a.txt
expect_eq "blacklist: clearing one path keeps the rest" "1" "$(blacklist_count bl-unit)"
blacklist_clear bl-unit
expect_eq "blacklist: clearing the source removes the file" "0" "$(blacklist_count bl-unit)"
expect_no_file "blacklist: cleared source file is gone" "$(blacklist_file bl-unit)"
rc=0
blacklist_clear bl-unit notes/a.txt || rc=$?
expect_rc "blacklist: clearing a missing path is rc 1" "$rc" 1
blacklist_record_stub bl-list b.txt "oops"
expect_contains "blacklist: list row has name, count, path, error" "$(blacklist_list)" "$(printf 'bl-list\t1\tb.txt\toops')"
cleared="$(blacklist_clear_all)"
expect_contains "blacklist: clear_all reports each source" "$cleared" "bl-list"
expect_eq "blacklist: clear_all removes the records" "" "$(blacklist_list)"

# --- batch records: every increment applied in one write ------------------
printf 'notes/b1.txt\tdenied\nnotes/b1.txt\tstill denied\nnotes/b2.txt\toops\n' |
  blacklist_record_many bl-many
expect_eq "blacklist_many: duplicate path increments per line" "2" "$(blacklist_fail_count bl-many notes/b1.txt)"
expect_eq "blacklist_many: last error wins" "still denied" "$(blacklist_cat bl-many | awk -F'\t' '$2 == "notes/b1.txt" { print $3 }')"
expect_eq "blacklist_many: distinct path added once" "1" "$(blacklist_fail_count bl-many notes/b2.txt)"
expect_eq "blacklist_many: tracks each distinct path" "2" "$(blacklist_count bl-many)"
order="$(blacklist_cat bl-many | awk -F'\t' '{ printf "%s%s", (NR > 1 ? " " : ""), $2 }')"
expect_eq "blacklist_many: existing order is preserved" "notes/b1.txt notes/b2.txt" "$order"
blacklist_record_stub bl-many notes/b1.txt "third"
expect_eq "blacklist_many: a later single record still increments" "3" "$(blacklist_fail_count bl-many notes/b1.txt)"
printf '' | blacklist_record_many bl-empty
expect_no_file "blacklist_many: empty input writes no record" "$(blacklist_file bl-empty)"
blacklist_clear bl-many

# --- end-to-end: sync records failures from the rclone log ---------------
# Two strikes: the second recorded failure excludes the path on the next run.
export BLACKLIST_MAX_FAILS=2
BL_SRC="${TMP}/bl-src"
STUB_RCLONE_BIN="${TMP}/stub-rclone-bin"
ARGV_LOG="${TMP}/stub-rclone.argv"
rm -rf "$BL_SRC"
mkdir -p "$BL_SRC" "$STUB_RCLONE_BIN"
cat >"$MANIFEST_FILE" <<EOF
sync|${BL_SRC}|bl-notes
EOF
cat >"${STUB_RCLONE_BIN}/rclone" <<'STUB'
#!/bin/bash
for arg in "$@"; do
  case "$arg" in
    version)
      printf 'rclone v1.69.0\n'
      exit 0
      ;;
    listremotes)
      printf 'testremote:\n'
      exit 0
      ;;
  esac
done
printf '%s\n' "$*" >>"${STUB_RCLONE_ARGV:-/dev/null}"
logfile=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --log-file)
      logfile="${2:-}"
      shift 2
      ;;
    --log-file=*)
      logfile="${1#*=}"
      shift
      ;;
    *) shift ;;
  esac
done
if [[ -n "$logfile" && "$logfile" != "-" ]]; then
  printf 'ERROR : notes/bad.txt: permission denied\n' >>"$logfile"
fi
exit 9
STUB
chmod +x "${STUB_RCLONE_BIN}/rclone"
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_cli_stub() {
  (cd "$TMP" && env PATH="${STUB_RCLONE_BIN}:$PATH" STUB_RCLONE_ARGV="$ARGV_LOG" bash "${PROJ}/bin/sciebo" "$@")
}

: >"$ARGV_LOG"
expect_cli "stub: first failing run rc 1" 1 run_cli_stub sync --apply --only bl-notes
expect_eq "stub: first failure recorded" "1" "$(blacklist_fail_count bl-notes notes/bad.txt)"
expect_eq "stub: first failure tracks one path" "1" "$(blacklist_count bl-notes)"
expect_cli "stub: second failing run rc 1" 1 run_cli_stub sync --apply --only bl-notes
expect_eq "stub: second failure counted" "2" "$(blacklist_fail_count bl-notes notes/bad.txt)"
: >"$ARGV_LOG"
expect_cli "stub: third failing run rc 1" 1 run_cli_stub sync --apply --only bl-notes
expect_contains "stub: threshold path is excluded" "$(cat "$ARGV_LOG")" "--exclude /notes/bad.txt"
expect_contains "stub: warn names retry" "$CLI_OUT" "retry bl-notes"
expect_eq "stub: third failure counted" "3" "$(blacklist_fail_count bl-notes notes/bad.txt)"

# --- retry: list, clear, and error handling ------------------------------
expect_cli "retry: --list rc 0" 0 run_cli retry --list
expect_contains "retry: --list row" "$CLI_OUT" "$(printf 'bl-notes\t3\tnotes/bad.txt\tpermission denied')"
expect_cli "retry: unknown source rc 1" 1 run_cli retry no-such-source
expect_contains "retry: unknown source message" "$CLI_OUT" "no source named 'no-such-source'"
expect_cli "retry: unknown path rc 1" 1 run_cli retry bl-notes notes/missing.txt
expect_contains "retry: unknown path message" "$CLI_OUT" "no blacklist entry"
expect_cli "retry: unknown option rc 2" 2 run_cli retry --bogus
expect_cli "retry: NAME required rc 2" 2 run_cli retry
expect_cli "retry: clear the source rc 0" 0 run_cli retry bl-notes
expect_contains "retry: clear reports the source" "$CLI_OUT" "cleared 1 path(s) for 'bl-notes'"
expect_eq "retry: blacklist emptied" "0" "$(blacklist_count bl-notes)"
: >"$ARGV_LOG"
expect_cli "stub: run after retry rc 1" 1 run_cli_stub sync --apply --only bl-notes
expect_not_contains "stub: no exclusion after retry" "$(cat "$ARGV_LOG")" "--exclude /notes/bad.txt"
expect_eq "stub: retried path recorded again" "1" "$(blacklist_fail_count bl-notes notes/bad.txt)"
blacklist_record_stub bl-notes notes/two.txt "again"
expect_cli "retry: --all rc 0" 0 run_cli retry --all
expect_contains "retry: --all reports the cleared source" "$CLI_OUT" "cleared 1 source(s): bl-notes"
expect_eq "retry: --all empties the records" "" "$(blacklist_list)"

# --- BACKUP_DIR is pull-only and keeps overwritten local files -----------
export BACKUP_DIR="${TMP}/bk-backups"
rm -rf "$BACKUP_DIR"
: >"$ARGV_LOG"
expect_cli "backup: stub sync run rc 1" 1 run_cli_stub sync --apply --only bl-notes
expect_not_contains "backup: --backup-dir is pull-only" "$(cat "$ARGV_LOG")" "--backup-dir"

BK_DST="${TMP}/bk-dst"
REMOTE_BK="${TMP}/backup/bk-notes"
rm -rf "$BK_DST" "$REMOTE_BK" "$BACKUP_DIR"
mkdir -p "$REMOTE_BK" "$BK_DST"
printf 'remote-new\n' >"${REMOTE_BK}/keep.txt"
printf 'local-old\n' >"${BK_DST}/keep.txt"
cat >"$MANIFEST_FILE" <<EOF
pull|${BK_DST}|bk-notes
EOF
expect_cli "backup: pull apply rc 0" 0 run_cli sync --apply --only bk-notes
expect_eq "backup: remote content is local" "remote-new" "$(cat "${BK_DST}/keep.txt")"
expect_eq "backup: overwritten local content kept" "local-old" "$(cat "${BACKUP_DIR}/bk-notes/keep.txt")"
expect_no_file "backup: successful entry records no blacklist data" "$(blacklist_file bk-notes)"

finish
