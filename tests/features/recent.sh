#!/usr/bin/env bash
# recent.sh - `sciebo recent` with a stub rclone that answers `lsl` with a
# canned listing (including a malformed line): sorting, limits, --since,
# JSON, empty output, and failure handling.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

STUB_RCLONE_DIR="${TMP}/stub-rclone-bin"
LISTING="${TMP}/rclone-lsl.txt"
ARGV_LOG="${TMP}/recent-rclone.args"
mkdir -p "$STUB_RCLONE_DIR"
cat >"${STUB_RCLONE_DIR}/rclone" <<'STUB'
#!/bin/bash
if [[ "${RECENT_FAIL:-0}" == "1" ]]; then
  printf 'ERROR : listing failed\n' >&2
  exit 3
fi
printf '%s\n' "$*" >>"${RECENT_ARGV_LOG:-/dev/null}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    version)
      printf 'rclone v1.75.1\n'
      exit 0
      ;;
    listremotes)
      printf 'testremote:\n'
      exit 0
      ;;
    lsl)
      cat "${RECENT_LISTING:-/dev/null}"
      exit 0
      ;;
    --config) shift 2 ;;
    *) shift ;;
  esac
done
exit 0
STUB
chmod +x "${STUB_RCLONE_DIR}/rclone"

# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_cli_recent() {
  (cd "$TMP" && env PATH="${STUB_RCLONE_DIR}:$PATH" RECENT_LISTING="$LISTING" \
    RECENT_ARGV_LOG="$ARGV_LOG" bash "${PROJ}/bin/sciebo" "$@")
}

cat >"$LISTING" <<'LIST'
     1024 2025-09-10 10:00:00.000000000 notes/new.txt
      512 2025-09-09 09:00:00.123456789 notes/older.txt
this is not a listing line and must be ignored
    20480 2025-09-11 12:30:00.500000000 photos/img space.jpg
LIST

expected="$(printf '%s\n' \
  $'2025-09-11 12:30:00.500000000\t20480\tphotos/img space.jpg' \
  $'2025-09-10 10:00:00.000000000\t1024\tnotes/new.txt' \
  $'2025-09-09 09:00:00.123456789\t512\tnotes/older.txt')"

: >"$ARGV_LOG"
expect_cli "recent rc 0" 0 run_cli_recent recent
expect_eq "recent sorted newest first" "$expected" "$CLI_OUT"
expect_not_contains "recent drops malformed lines" "$CLI_OUT" "must be ignored"
expect_contains "recent uses lsl recursively by default" "$(cat "$ARGV_LOG")" "lsl testremote:backup/"
expect_not_contains "recent does not pass --recursive to lsl" "$(cat "$ARGV_LOG")" "--recursive"

expect_cli "recent --limit rc 0" 0 run_cli_recent recent --limit 2
expect_contains "recent limit keeps newest" "$CLI_OUT" "photos/img space.jpg"
expect_contains "recent limit keeps second" "$CLI_OUT" "notes/new.txt"
expect_not_contains "recent limit caps the list" "$CLI_OUT" "notes/older.txt"

: >"$ARGV_LOG"
expect_cli "recent --since rc 0" 0 run_cli_recent recent --since 2d
expect_contains "recent --since converts to seconds" "$(cat "$ARGV_LOG")" "--max-age 172800s"

expect_cli "recent bad --since rc 2" 2 run_cli_recent recent --since soon
expect_contains "recent bad --since message" "$CLI_OUT" "--since requires a duration"
expect_cli "recent bad --limit rc 2" 2 run_cli_recent recent --limit 0
expect_contains "recent bad --limit message" "$CLI_OUT" "positive integer"
expect_cli "recent unknown option rc 2" 2 run_cli_recent recent --bogus
expect_contains "recent usage printed" "$CLI_OUT" "Usage: sciebo recent"

expect_cli "recent --json rc 0" 0 run_cli_recent recent --json
expect_contains "recent json array" "$CLI_OUT" '"files": ['
expect_contains "recent json modified" "$CLI_OUT" '"modified": "2025-09-11 12:30:00.500000000"'
expect_contains "recent json size" "$CLI_OUT" '"size": 20480'
expect_contains "recent json path" "$CLI_OUT" '"path": "photos/img space.jpg"'

: >"$LISTING"
expect_cli "recent empty rc 0" 0 run_cli_recent recent
expect_contains "recent empty message" "$CLI_OUT" "no recent files"
expect_cli "recent empty --json rc 0" 0 run_cli_recent recent --json
expect_contains "recent empty json" "$CLI_OUT" '"files": []'

export RECENT_FAIL=1
expect_cli "recent failure rc 1" 1 run_cli_recent recent
expect_contains "recent failure message" "$CLI_OUT" "failed"
expect_contains "recent failure surfaces rclone stderr" "$CLI_OUT" "listing failed"
unset RECENT_FAIL

# --- a listing bigger than one pipe buffer must not trip SIGPIPE -----------
# `sort -r | head -n N` (the old implementation) fails the pipeline under
# `pipefail` once `head` exits early and closes the pipe on `sort` mid-write.
{
  for ((i = 0; i < 20000; i++)); do
    ss=$((i % 60))
    mm=$(((i / 60) % 60))
    hh=$((i / 3600))
    printf '%8d 2020-01-01 %02d:%02d:%02d.000000000 file%05d.txt\n' "$i" "$hh" "$mm" "$ss" "$i"
  done
} >"$LISTING"
expect_cli "recent large listing rc 0" 0 run_cli_recent recent --limit 5
expect_eq "recent large listing returns exactly 5 lines" "5" "$(printf '%s\n' "$CLI_OUT" | wc -l | tr -d ' ')"
expect_contains "recent large listing keeps the newest" "$CLI_OUT" "file19999.txt"
expect_not_contains "recent large listing caps the list" "$CLI_OUT" "file00000.txt"

finish
