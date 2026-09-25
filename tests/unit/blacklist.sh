#!/usr/bin/env bash
# blacklist.sh - blacklist record iteration (lib/state/blacklist.sh).
# Sourced setup lives in tests/unit/common.sh; run standalone with
# `bash tests/unit/blacklist.sh`.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# --- blacklist_each_record ----------------------------------------------
# Fields are COUNT, PATH, ERROR, NEXT; a final line without a trailing newline
# is still visited, and a non-zero callback status stops and propagates.
bl_file="${TMP}/blacklist-each.rec"
printf '1\tpath/a\terror one\n2\tpath/b\terror two\tnext=1700000000\n3\tpath/c\tno newline' >"$bl_file"
bl_log=""
# shellcheck disable=SC2329  # invoked indirectly by blacklist_each_record
blacklist_each_visit() { bl_log+="$1,$2,$3,$4;"; }
blacklist_each_record blacklist_each_visit "$bl_file"
expect_rc "blacklist_each_record: completes with rc 0" "$?" 0
expect_eq "blacklist_each_record: fields and unterminated final line" \
  '1,path/a,error one,;2,path/b,error two,next=1700000000;3,path/c,no newline,;' "$bl_log"
bl_count=0
# shellcheck disable=SC2329  # invoked indirectly by blacklist_each_record
blacklist_each_stop() {
  bl_count=$((bl_count + 1))
  return 9
}
bl_rc=0
blacklist_each_record blacklist_each_stop "$bl_file" || bl_rc=$?
expect_rc "blacklist_each_record: non-zero callback status propagated" "$bl_rc" 9
expect_eq "blacklist_each_record: non-zero callback stops the walk" "1" "$bl_count"

finish
