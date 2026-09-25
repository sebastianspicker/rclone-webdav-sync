#!/usr/bin/env bash
# logs.sh - the logs list/show/tail/path subcommands: log resolution from
# the manifest, run records, and LOG_DIR; JSON rows; dry-run fallback.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

# Fixtures: manifest sources with run records, scanned normal logs, plain
# and timestamped dry-run logs, a log whose recorded path vanished, a
# manifest source with no log, and a source that only exists in LOG_DIR.
LOG_DIR="${STATE_DIR}/logs"
RUNSTATE_DIR="${STATE_DIR}/last"
HISTORY_DIR="${STATE_DIR}/history"
HISTORY_MAX_ENTRIES=50
mkdir -p "$LOG_DIR" "$RUNSTATE_DIR"

cat >"$MANIFEST_FILE" <<EOF
sync|${TMP}/src-a|repo-a
pull|${TMP}/src-b|repo-b
bisync|${TMP}/src-c|repo-c
sync|${TMP}/src-big|repo-big
sync|${TMP}/src-r|repo
sync|${TMP}/src-rp|repo-plain
bisync|${TMP}/src-d|repo-d
EOF

# Exactly 12 lines / 96 bytes so the size label is deterministic.
LOG_A="${LOG_DIR}/repo-a-20260101-010101.log"
i=1
: >"$LOG_A"
while [[ "$i" -le 12 ]]; do
  printf 'line-%02d\n' "$i" >>"$LOG_A"
  i=$((i + 1))
done

LOG_B="${LOG_DIR}/repo-b-20260101-030303.log"
printf 'b-line\n' >"$LOG_B"
LOG_C="${LOG_DIR}/repo-c-dryrun.log"
printf 'dry-run-content\n' >"$LOG_C"
LOG_BIG="${LOG_DIR}/repo-big-20260101-050505.log"
head -c 2048 /dev/zero | tr '\0' 'x' >"$LOG_BIG"
LOG_ORPHAN="${LOG_DIR}/orphan-20260101-040404.log"
printf 'orphan-line\n' >"$LOG_ORPHAN"
# Plain `<name>.log` fallback and a timestamped dry-run log.
LOG_PLAIN="${LOG_DIR}/repo-plain.log"
printf 'plain-line\n' >"$LOG_PLAIN"
LOG_D="${LOG_DIR}/repo-d-20260101-060606-dryrun.log"
printf 'timestamped-dry\n' >"$LOG_D"
# Prefix pair plus a suffix that is not a timestamp: only the exact
# `-<stamp>` decoration is stripped, so `repo-b-extra` (and `repo-x-notes`)
# must survive as their own source names rather than collapsing onto `repo-b`
# or `repo-x`.
LOG_EXTRA="${LOG_DIR}/repo-b-extra-20260101-070707.log"
printf 'extra-line\n' >"$LOG_EXTRA"
LOG_EXTRA_DRY="${LOG_DIR}/repo-b-extra-dryrun.log"
printf 'extra-dry\n' >"$LOG_EXTRA_DRY"
LOG_NOTES="${LOG_DIR}/repo-x-notes.log"
printf 'notes-line\n' >"$LOG_NOTES"
# A non-.log file is not a log and must be ignored by every logs path.
printf 'ignored\n' >"${LOG_DIR}/notes.txt"

# repo-a's recorded path is the real file; repo-b's record points at a log
# that no longer exists, so the newest LOG_DIR file must be used instead.
runstate_write "repo-a" sync ok 0 "$LOG_A" 0 "all good"
runstate_write "repo-b" pull failed 3 "/nonexistent/repo-b.log" 2 "boom"

# --- list -------------------------------------------------------------------

expect_cli "logs list rc 0" 0 run_cli logs list
expect_contains "logs list: header" "$CLI_OUT" "NAME"
expect_contains "logs list: source column" "$CLI_OUT" "repo-a"
expect_contains "logs list: mode column" "$CLI_OUT" "sync"
expect_contains "logs list: ok status" "$CLI_OUT" "OK"
expect_contains "logs list: failed status" "$CLI_OUT" "FAILED"
expect_contains "logs list: never status" "$CLI_OUT" "never"
expect_contains "logs list: byte size" "$CLI_OUT" "96B"
expect_contains "logs list: kib size" "$CLI_OUT" "2.0KiB"
expect_contains "logs list: recorded path reused" "$CLI_OUT" "$LOG_A"
expect_contains "logs list: missing record falls back" "$CLI_OUT" "$LOG_B"
expect_contains "logs list: dry-run path" "$CLI_OUT" "$LOG_C"
expect_contains "logs list: plain fallback path" "$CLI_OUT" "$LOG_PLAIN"
expect_contains "logs list: timestamped dry-run path" "$CLI_OUT" "$LOG_D"
expect_contains "logs list: log-only source" "$CLI_OUT" "orphan"
expect_contains "logs list: prefix-pair source" "$CLI_OUT" "repo-b-extra"
expect_contains "logs list: non-timestamp source" "$CLI_OUT" "repo-x-notes"
expect_not_contains "logs list: non-.log file ignored" "$CLI_OUT" "notes.txt"
expect_contains "logs list: mtime year" "$CLI_OUT" "$(date '+%Y')"

expect_cli "logs bare rc 0" 0 run_cli logs
expect_contains "logs bare behaves like list" "$CLI_OUT" "repo-a"

# --- list --json ------------------------------------------------------------

expect_cli "logs list --json rc 0" 0 run_cli logs list --json
expect_contains "logs json: array" "$CLI_OUT" '"logs"'
expect_contains "logs json: source" "$CLI_OUT" '"source": "repo-a"'
expect_contains "logs json: mode" "$CLI_OUT" '"mode": "sync"'
expect_contains "logs json: recorded path" "$CLI_OUT" "$LOG_A"
expect_contains "logs json: size label" "$CLI_OUT" '"size": "96B"'
expect_contains "logs json: ok status" "$CLI_OUT" '"status": "ok"'
expect_contains "logs json: failed status" "$CLI_OUT" '"status": "failed"'
expect_contains "logs json: never status empty" "$CLI_OUT" '"status": ""'
expect_contains "logs json: mtime filled" "$CLI_OUT" "\"mtime\": \"$(date '+%Y')"

# --- show -------------------------------------------------------------------

expect_cli "logs show rc 0" 0 run_cli logs show repo-a
expect_eq "logs show: default prints every line" "12" \
  "$(printf '%s\n' "$CLI_OUT" | wc -l | tr -d ' ')"
expect_contains "logs show: first line" "$CLI_OUT" "line-01"
expect_contains "logs show: last line" "$CLI_OUT" "line-12"

expect_cli "logs show --lines rc 0" 0 run_cli logs show repo-a --lines 3
expect_eq "logs show: --lines count" "3" \
  "$(printf '%s\n' "$CLI_OUT" | wc -l | tr -d ' ')"
expect_contains "logs show: --lines keeps the newest" "$CLI_OUT" "line-12"
expect_not_contains "logs show: --lines drops the oldest" "$CLI_OUT" "line-09"

# A recorded log path that vanished falls back to the newest LOG_DIR file.
expect_cli "logs show missing record rc 0" 0 run_cli logs show repo-b
expect_contains "logs show: fallback content" "$CLI_OUT" "b-line"

# The dry-run fallback goes to stdout, the note to stderr.
SHOW_OUT="${TMP}/logs-show-c.out"
SHOW_ERR="${TMP}/logs-show-c.err"
run_cli logs show repo-c >"$SHOW_OUT" 2>"$SHOW_ERR"
SHOW_RC=$?
expect_rc "logs show dry-run fallback rc 0" "$SHOW_RC" 0
expect_contains "logs show: dry-run content" "$(cat "$SHOW_OUT")" "dry-run-content"
expect_contains "logs show: dry-run note on stderr" "$(cat "$SHOW_ERR")" "dry-run log"
expect_not_contains "logs show: note not on stdout" "$(cat "$SHOW_OUT")" "note:"

# Same fallback for the timestamped `<name>-<stamp>-dryrun.log` form.
expect_cli "logs show timestamped dry-run rc 0" 0 run_cli logs show repo-d
expect_contains "logs show: timestamped dry-run content" "$CLI_OUT" "timestamped-dry"
expect_contains "logs show: timestamped dry-run note" "$CLI_OUT" "dry-run log"

# A plain <name>.log is the last-resort normal fallback.
expect_cli "logs show plain fallback rc 0" 0 run_cli logs show repo-plain
expect_contains "logs show: plain fallback content" "$CLI_OUT" "plain-line"

expect_cli "logs show unknown rc 1" 1 run_cli logs show missing-src
expect_contains "logs show unknown lists known names" "$CLI_OUT" "known:"
expect_contains "logs show unknown includes repo-a" "$CLI_OUT" "repo-a"
expect_cli "logs show without NAME rc 2" 2 run_cli logs show
expect_cli "logs show extra argument rc 2" 2 run_cli logs show repo-a extra
expect_cli "logs show --lines abc rc 2" 2 run_cli logs show repo-a --lines abc
expect_cli "logs show --lines 0 rc 2" 2 run_cli logs show repo-a --lines 0
expect_cli "logs show --lines -1 rc 2" 2 run_cli logs show repo-a --lines -1
expect_cli "logs tail --lines abc rc 2" 2 run_cli logs tail repo-a --lines abc
expect_cli "logs tail unknown rc 1" 1 run_cli logs tail missing-src
expect_cli "logs show --help rc 0" 0 run_cli logs show --help
expect_contains "logs show --help usage" "$CLI_OUT" "Usage: sciebo logs"

# --- path -------------------------------------------------------------------

expect_cli "logs path NAME rc 0" 0 run_cli logs path repo-a
expect_eq "logs path NAME: name<TAB>recorded path" \
  "$(printf 'repo-a\t%s' "$LOG_A")" "$CLI_OUT"
expect_cli "logs path fallback rc 0" 0 run_cli logs path repo-b
expect_eq "logs path: scanned fallback" "$(printf 'repo-b\t%s' "$LOG_B")" "$CLI_OUT"
expect_cli "logs path dry-run rc 0" 0 run_cli logs path repo-c
expect_eq "logs path: dry-run fallback" "$(printf 'repo-c\t%s' "$LOG_C")" "$CLI_OUT"
expect_cli "logs path timestamped dry-run rc 0" 0 run_cli logs path repo-d
expect_eq "logs path: timestamped dry-run" "$(printf 'repo-d\t%s' "$LOG_D")" "$CLI_OUT"
expect_cli "logs path plain rc 0" 0 run_cli logs path repo-plain
expect_eq "logs path: plain fallback" "$(printf 'repo-plain\t%s' "$LOG_PLAIN")" "$CLI_OUT"
# A prefix-pair source with both a normal and a dry-run log resolves to the
# normal one; the trailing -dryrun must not leak into the name.
expect_cli "logs path prefix-pair rc 0" 0 run_cli logs path repo-b-extra
expect_eq "logs path: prefix-pair normal preferred" \
  "$(printf 'repo-b-extra\t%s' "$LOG_EXTRA")" "$CLI_OUT"
# `-notes` is not `-<stamp>`, so it stays part of the source name.
expect_cli "logs path non-timestamp rc 0" 0 run_cli logs path repo-x-notes
expect_eq "logs path: non-timestamp suffix kept" \
  "$(printf 'repo-x-notes\t%s' "$LOG_NOTES")" "$CLI_OUT"
expect_cli "logs path prefix of non-timestamp rc 1" 1 run_cli logs path repo-x
expect_cli "logs path all rc 0" 0 run_cli logs path
expect_contains "logs path all: manifest source" "$CLI_OUT" \
  "$(printf 'repo-a\t%s' "$LOG_A")"
expect_contains "logs path all: log-only source" "$CLI_OUT" \
  "$(printf 'orphan\t%s' "$LOG_ORPHAN")"
expect_contains "logs path all: no log prints -" "$CLI_OUT" "$(printf 'repo\t-')"
expect_eq "logs path all: one line per source" "10" \
  "$(printf '%s\n' "$CLI_OUT" | wc -l | tr -d ' ')"
expect_cli "logs path prefix source rc 0" 0 run_cli logs path repo
expect_eq "logs path: prefix source stays -" "$(printf 'repo\t-')" "$CLI_OUT"
expect_cli "logs path unknown rc 1" 1 run_cli logs path missing-src
expect_cli "logs path --json rc 2" 2 run_cli logs path --json

# `repo` must not resolve to `repo-b`'s log just because it is a prefix.
expect_cli "logs show known without log rc 1" 1 run_cli logs show repo
expect_contains "logs show known without log message" "$CLI_OUT" "no log for"

# The known-name hint is the sorted unique manifest + LOG_DIR union (the
# exact ordering the cached LC_ALL=C sort -u produces), so a regression in
# the name set or its ordering is caught here.
expect_cli "logs show unknown list rc 1" 1 run_cli logs show missing-src
expect_eq "logs show unknown known list exact" \
  "orphan repo repo-a repo-b repo-b-extra repo-big repo-c repo-d repo-plain repo-x-notes" \
  "$(printf '%s' "$CLI_OUT" | sed -n 's/.*known: //p')"

# --- dispatch and empty state ----------------------------------------------

expect_cli "logs unknown subcommand rc 2" 2 run_cli logs frobnicate
expect_contains "logs unknown subcommand message" "$CLI_OUT" "unknown command"
expect_cli "logs list --lines rc 2" 2 run_cli logs list --lines 3
expect_cli "logs --help rc 0" 0 run_cli logs --help
expect_contains "logs --help usage" "$CLI_OUT" "Usage: sciebo logs"

# run_cli_empty - the CLI with no manifest and no LOG_DIR at all.
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_cli_empty() {
  (cd "$TMP" && env MANIFEST_FILE="${TMP}/none-sources.conf" \
    FOLDERS_FILE="${TMP}/none-folders.conf" \
    MANIFEST_GENERATED_FILE="${TMP}/none-generated.conf" \
    LOG_DIR="${TMP}/none-logs" bash "${PROJ}/bin/sciebo" "$@")
}
expect_cli "logs list empty rc 0" 0 run_cli_empty logs list
expect_eq "logs list empty prints no logs" "no logs" "$CLI_OUT"
expect_cli "logs bare empty rc 0" 0 run_cli_empty logs
expect_eq "logs bare empty prints no logs" "no logs" "$CLI_OUT"
expect_cli "logs empty --json rc 0" 0 run_cli_empty logs list --json
expect_contains "logs empty json array" "$CLI_OUT" '"logs": []'
expect_not_contains "logs empty json has no rows" "$CLI_OUT" '"source"'
expect_cli "logs path empty rc 0" 0 run_cli_empty logs path
expect_eq "logs path empty prints nothing" "" "$CLI_OUT"

finish
