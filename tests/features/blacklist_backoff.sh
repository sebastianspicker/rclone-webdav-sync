#!/usr/bin/env bash
# blacklist_backoff.sh - BLACKLIST_MODE=backoff exponential retry deadlines.
# The blacklist functions are exercised directly with a hermetic BLACKLIST_DIR;
# the CLI is only used for the `retry --list` next column.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

export BLACKLIST_DIR="${TMP}/blacklist-backoff"
export BLACKLIST_ENABLED=1 BLACKLIST_MAX_FAILS=2 BLACKLIST_MODE=backoff
export BLACKLIST_TIME_MIN=10 BLACKLIST_TIME_MAX=60
# shellcheck disable=SC1090,SC1091
source "${PROJ}/lib/duration.sh"
# shellcheck disable=SC1090,SC1091
source "${PROJ}/lib/blacklist.sh"

# Test-local readers for the blacklist record file. The production module no
# longer exposes blacklist_read/blacklist_record, so read the file directly
# and batch writes through the public blacklist_record_many.
blacklist_read() { cat "$(blacklist_file "$1")" 2>/dev/null || true; }
blacklist_record() {
  local name="$1" path="$2" error="${3:-}"
  printf '%s\t%s\n' "$path" "$error" | blacklist_record_many "$name"
}

# blacklist_next_of NAME PATH - the recorded next= epoch for PATH (empty when
# the record has none).
blacklist_next_of() {
  blacklist_read "$1" | awk -F'\t' -v path="$2" '$2 == path { print $4 }' | sed 's/^next=//'
}

# --- below the threshold: counted but not excluded --------------------------
blacklist_record bl-backoff notes/a.txt "denied"
expect_eq "backoff: first failure records no deadline" "0" "$(blacklist_next_of bl-backoff notes/a.txt)"
expect_eq "backoff: below threshold not excluded" "" "$(blacklist_excluded bl-backoff)"

# --- at the threshold: a future deadline, so the path is excluded -----------
before="$(now_epoch)"
blacklist_record bl-backoff notes/a.txt "denied"
after="$(now_epoch)"
next2="$(blacklist_next_of bl-backoff notes/a.txt)"
expect_eq "backoff: second failure reaches the threshold" "2" "$(blacklist_read bl-backoff | awk -F'\t' '$2 == "notes/a.txt" { print $1 }')"
if [[ "$next2" =~ ^[0-9]+$ && "$next2" -gt "$before" ]]; then
  pass "backoff: deadline lies in the future"
else
  fail "backoff: deadline lies in the future" "next=[$next2] before=[$before]"
fi
if [[ "$next2" -ge "$((before + 10))" && "$next2" -le "$((after + 10))" ]]; then
  pass "backoff: threshold delay is BLACKLIST_TIME_MIN"
else
  fail "backoff: threshold delay is BLACKLIST_TIME_MIN" "next=[$next2] before=[$before] after=[$after]"
fi
expect_eq "backoff: future deadline excludes the path" "/notes/a.txt" "$(blacklist_excluded bl-backoff)"

# --- a deadline in the past retries the path --------------------------------
now="$(now_epoch)"
printf '2\tnotes/a.txt\tdenied\tnext=%s\n' "$((now - 30))" | atomic_write "$(blacklist_file bl-backoff)" 600
expect_eq "backoff: past deadline retries the path" "" "$(blacklist_excluded bl-backoff)"

# --- a fresh failure after the deadline grows the delay ---------------------
printf '2\tnotes/a.txt\tdenied\tnext=%s\n' "$((now + 30))" | atomic_write "$(blacklist_file bl-backoff)" 600
before="$(now_epoch)"
blacklist_record bl-backoff notes/a.txt "denied"
after="$(now_epoch)"
next3="$(blacklist_next_of bl-backoff notes/a.txt)"
expect_eq "backoff: third failure counted" "3" "$(blacklist_read bl-backoff | awk -F'\t' '$2 == "notes/a.txt" { print $1 }')"
if [[ "$next3" -ge "$((before + 20))" && "$next3" -le "$((after + 20))" ]]; then
  pass "backoff: next delay doubles"
else
  fail "backoff: next delay doubles" "next=[$next3] before=[$before] after=[$after]"
fi
expect_eq "backoff: grown deadline excludes the path" "/notes/a.txt" "$(blacklist_excluded bl-backoff)"

# --- the delay is capped at BLACKLIST_TIME_MAX ------------------------------
before="$(now_epoch)"
for _ in 1 2 3 4 5 6 7 8; do
  blacklist_record bl-backoff notes/a.txt "denied"
done
after="$(now_epoch)"
capped="$(blacklist_next_of bl-backoff notes/a.txt)"
if [[ "$capped" -ge "$((before + 60))" && "$capped" -le "$((after + 60))" ]]; then
  pass "backoff: delay is capped at BLACKLIST_TIME_MAX"
else
  fail "backoff: delay is capped at BLACKLIST_TIME_MAX" "next=[$capped] before=[$before] after=[$after]"
fi

# --- an older three-field record still parses and is retried ----------------
printf '2\tnotes/legacy.txt\tdenied\n' | atomic_write "$(blacklist_file bl-backoff)" 600
expect_eq "backoff: three-field record parses" "1" "$(blacklist_count bl-backoff)"
expect_eq "backoff: three-field record is retried" "" "$(blacklist_excluded bl-backoff)"
legacy_row="$(blacklist_list | awk -F'\t' '$1 == "bl-backoff"')"
expect_eq "backoff: three-field list keeps four columns" "4" "$(printf '%s\n' "$legacy_row" | awk -F'\t' '{ print NF }')"

# --- retry --list formats the deadline in a fifth column --------------------
blacklist_record bl-list notes/b.txt "denied"
blacklist_record bl-list notes/b.txt "denied"
list_next="$(blacklist_next_of bl-list notes/b.txt)"
row="$(blacklist_list | awk -F'\t' '$1 == "bl-list"')"
expect_eq "backoff: list prints five columns" "5" "$(printf '%s\n' "$row" | awk -F'\t' '{ print NF }')"
expect_eq "backoff: list formats the deadline" "$(epoch_to_stamp "$list_next")" "$(printf '%s\n' "$row" | cut -f5)"
legacy_row="$(blacklist_list | awk -F'\t' '$1 == "bl-backoff"')"
expect_eq "backoff: list leaves an unset deadline blank" "-" "$(printf '%s\n' "$legacy_row" | cut -f5)"
expect_cli "backoff: retry --list rc 0" 0 run_cli retry --list
expect_contains "backoff: retry --list shows the next column" "$CLI_OUT" "$(epoch_to_stamp "$list_next")"

# --- batch form applies multiple increments and deadlines at once ----------
printf 'notes/batch1.txt\tdenied\nnotes/batch1.txt\tdenied\nnotes/batch2.txt\tdenied\nnotes/batch2.txt\tdenied\n' |
  blacklist_record_many bl-batch
expect_eq "backoff batch: first path reaches the threshold" "2" "$(blacklist_read bl-batch | awk -F'\t' '$2 == "notes/batch1.txt" { print $1 }')"
expect_eq "backoff batch: second path reaches the threshold" "2" "$(blacklist_read bl-batch | awk -F'\t' '$2 == "notes/batch2.txt" { print $1 }')"
expect_contains "backoff batch: first path excluded" "$(blacklist_excluded bl-batch)" "/notes/batch1.txt"
expect_contains "backoff batch: second path excluded" "$(blacklist_excluded bl-batch)" "/notes/batch2.txt"
batch_next="$(blacklist_next_of bl-batch notes/batch1.txt)"
if [[ "$batch_next" =~ ^[0-9]+$ && "$batch_next" -gt "$(now_epoch)" ]]; then
  pass "backoff batch: deadline lies in the future"
else
  fail "backoff batch: deadline lies in the future" "next=[$batch_next]"
fi
blacklist_record bl-cross notes/c.txt "denied"
printf 'notes/c.txt\tdenied\n' | blacklist_record_many bl-cross
expect_contains "backoff batch: an existing record crosses the threshold" "$(blacklist_excluded bl-cross)" "/notes/c.txt"

# --- count mode keeps the three-field shape ---------------------------------
saved_mode="$BLACKLIST_MODE"
BLACKLIST_MODE=count
blacklist_record bl-count notes/c.txt "denied"
expect_eq "backoff: count mode writes three fields" "3" "$(blacklist_read bl-count | awk -F'\t' '{ print NF }')"
BLACKLIST_MODE="$saved_mode"

# --- clearing removes the record entirely -----------------------------------
blacklist_record bl-clear notes/d.txt "denied"
blacklist_record bl-clear notes/d.txt "denied"
expect_file "backoff: clear target exists" "$(blacklist_file bl-clear)"
blacklist_clear bl-clear
expect_eq "backoff: clear removes the path" "0" "$(blacklist_count bl-clear)"
expect_no_file "backoff: clear removes the record file" "$(blacklist_file bl-clear)"

finish
