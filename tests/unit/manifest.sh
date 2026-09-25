#!/usr/bin/env bash
# manifest.sh - sources.conf parsing, iteration, and mutation (lib/manifest.sh).
# Sourced setup lives in tests/unit/common.sh; run standalone with
# `bash tests/unit/manifest.sh`.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# --- manifest_parse_line ------------------------------------------------
# Fields are separated by "@" (the manifest lines themselves use "|"); the
# line goes through printf %b so "\t" can encode a control byte. The
# documented style pads fields with spaces, so each field is trimmed.
printf '# test filter\n' >"${FILTER_DIR}/clutter.txt"
while IFS=@ read -r name line rc_want want_mode want_local want_remote want_filter want_name; do
  rc=0
  manifest_parse_line "$(printf '%b' "$line")" || rc=$?
  expect_rc "${name}: rc" "$rc" "$rc_want"
  if [[ "$rc_want" -eq 0 ]]; then
    expect_eq "${name}: mode" "$want_mode" "$ENTRY_MODE"
    expect_eq "${name}: local" "$want_local" "$ENTRY_LOCAL"
    expect_eq "${name}: remote" "$want_remote" "$ENTRY_REMOTE"
    expect_eq "${name}: filter" "$want_filter" "$ENTRY_FILTER"
    expect_eq "${name}: name" "$want_name" "$ENTRY_NAME"
    expect_eq "${name}: no error" "" "$ENTRY_ERROR"
  elif [[ "$want_mode" != "-" ]]; then
    expect_contains "${name}: error" "$ENTRY_ERROR" "$want_mode"
  fi
done <<EOF
parse: 3-field sync entry@sync|/tmp/src|repos/my-app@0@sync@/tmp/src@repos/my-app@@repos_my-app
parse: tilde local path expands@pull|~/src|notes@0@pull@$HOME/src@notes@@notes
parse: relative local path expands@bisync|rel/dir|notes@0@bisync@$PROJECT_DIR/rel/dir@notes@@notes
parse: 4-field entry with filter@sync|/tmp/src|notes|clutter.txt@0@sync@/tmp/src@notes@clutter.txt@notes
parse: spaced fields trimmed@sync | /tmp/src | notes@0@sync@/tmp/src@notes@@notes
parse: remote field padding trimmed@sync|/tmp/src| notes @0@sync@/tmp/src@notes@@notes
parse: unknown mode@bogus|/tmp/src|notes@1@unknown mode
parse: empty local@sync||notes@1@empty local
parse: empty remote@sync|/tmp/src|@1@unsafe remote
parse: absolute remote@sync|/tmp/src|/abs@1@unsafe remote
parse: .. remote@sync|/tmp/src|a/../b@1@unsafe remote
parse: pipe in remote (4 fields)@sync|/tmp/src|a|b@1@-
parse: pipe in remote (5 fields)@sync|/tmp/src|a|b|c@1@too many fields
parse: five fields@sync|/tmp/src|notes|x|y@1@too many fields
parse: control byte in remote@sync|/tmp/src|a\tb@1@unsafe remote
parse: missing filter file@sync|/tmp/src|notes|nope.txt@1@missing filter file
parse: filter path traversal@sync|/tmp/src|notes|../evil.txt@1@invalid filter file
parse: filter with subdirectory@sync|/tmp/src|notes|sub/x.txt@1@invalid filter file
parse: filter absolute path@sync|/tmp/src|notes|/etc/passwd@1@invalid filter file
EOF

# --- manifest_lines -----------------------------------------------------
printf '# comment line\n\nsync|/tmp/src|repos/my-app\n   \n  # indented comment\npull|/tmp/other|notes\n' >"$MANIFEST_FILE"
: >"$FOLDERS_FILE"
: >"$MANIFEST_GENERATED_FILE"
expect_eq "manifest_lines: blank and comment lines ignored" \
  "$(printf 'sync|/tmp/src|repos/my-app\npull|/tmp/other|notes')" \
  "$(manifest_lines)"

# --- manifest_lines stamp (one stat + per-SECONDS-tick cache) -------------
# The stamp carries each existing file's "path<TAB>mtime size" from a single
# stat call and is cached for the current SECONDS tick; invalidate drops it.
# Pinning SECONDS keeps the reuse assertion off the tick boundary.
_manifest_lines_stamp
stamp_before="$_MANIFEST_LINES_STAMP_VALUE"
expect_contains "manifest_lines stamp: names the manifest file" "$stamp_before" "$MANIFEST_FILE"
expect_contains "manifest_lines stamp: carries the file stamp" "$stamp_before" "$(file_stamp "$MANIFEST_FILE")"
saved_seconds="$SECONDS"
SECONDS=1000
_manifest_lines_stamp
tick_stamp="$_MANIFEST_LINES_STAMP_VALUE"
expect_eq "manifest_lines stamp: pinned to the tick" "1000" "$_MANIFEST_STAMP_SECONDS"
SECONDS=1000
_manifest_lines_stamp
expect_eq "manifest_lines stamp: same tick reuses the cached value" "$tick_stamp" "$_MANIFEST_LINES_STAMP_VALUE"
printf 'sync|/tmp/src|repos/my-app\npull|/tmp/other|notes|clutter.txt\n' >"$MANIFEST_FILE"
manifest_index_invalidate
expect_eq "manifest_lines stamp: invalidate clears the tick cache" "" "$_MANIFEST_STAMP_SECONDS"
_manifest_lines_stamp
expect_contains "manifest_lines stamp: reflects an external rewrite" \
  "$_MANIFEST_LINES_STAMP_VALUE" "$(file_stamp "$MANIFEST_FILE")"
SECONDS="$saved_seconds"

# --- manifest_each ------------------------------------------------------
# Valid entries are walked in order (invalid lines skipped), extra ARGs reach
# the callback, and a non-zero callback status stops the walk and propagates.
printf 'sync|/tmp/src|repos/my-app\nbogus|/tmp/bad|bad-sub\npull|/tmp/other|notes\n' >"$MANIFEST_FILE"
: >"$FOLDERS_FILE"
: >"$MANIFEST_GENERATED_FILE"
manifest_index_invalidate
me_log=""
# shellcheck disable=SC2329  # invoked indirectly by manifest_each
manifest_each_visit() { me_log+="$ENTRY_MODE:$ENTRY_REMOTE"$'\n'; }
manifest_each manifest_each_visit
expect_rc "manifest_each: completes with rc 0" "$?" 0
expect_eq "manifest_each: valid lines in order, invalid skipped" \
  $'sync:repos/my-app\npull:notes\n' "$me_log"
me_arg=""
# shellcheck disable=SC2329  # invoked indirectly by manifest_each
manifest_each_arg() { me_arg="$1"; }
manifest_each manifest_each_arg "passed-through"
expect_eq "manifest_each: extra ARG reaches the callback" "passed-through" "$me_arg"
me_count=0
# shellcheck disable=SC2329  # invoked indirectly by manifest_each
manifest_each_stop() {
  me_count=$((me_count + 1))
  return 7
}
me_rc=0
manifest_each manifest_each_stop || me_rc=$?
expect_rc "manifest_each: non-zero callback status propagated" "$me_rc" 7
expect_eq "manifest_each: non-zero callback stops the walk" "1" "$me_count"

# --- manifest_resolve_local ---------------------------------------------
printf 'sync|/tmp/src|repos/my-app|clutter.txt\npull|/tmp/other|notes\n' >"$MANIFEST_FILE"
: >"$FOLDERS_FILE"
: >"$MANIFEST_GENERATED_FILE"
manifest_index_invalidate
resolved_local=""
expect_ok "manifest_resolve_local: exact match rc 0" manifest_resolve_local "repos/my-app" resolved_local
expect_eq "manifest_resolve_local: exact local path" "/tmp/src" "$resolved_local"
expect_eq "manifest_resolve_local: exact match name" "repos_my-app" "$MANIFEST_MATCH_NAME"
expect_eq "manifest_resolve_local: exact match filter" "clutter.txt" "$MANIFEST_MATCH_FILTER"
resolved_local=""
expect_ok "manifest_resolve_local: parent match rc 0" manifest_resolve_local "repos/my-app/sub/file.txt" resolved_local
expect_eq "manifest_resolve_local: parent appends remainder" "/tmp/src/sub/file.txt" "$resolved_local"
expect_eq "manifest_resolve_local: parent match name" "repos_my-app" "$MANIFEST_MATCH_NAME"
expect_eq "manifest_resolve_local: parent match filter" "clutter.txt" "$MANIFEST_MATCH_FILTER"
resolved_local=""
expect_err "manifest_resolve_local: no match rc 1" manifest_resolve_local "unrelated/path" resolved_local
expect_eq "manifest_resolve_local: no match leaves OUT_VAR empty" "" "$resolved_local"
expect_eq "manifest_resolve_local: no match clears name" "" "$MANIFEST_MATCH_NAME"
expect_eq "manifest_resolve_local: no match clears filter" "" "$MANIFEST_MATCH_FILTER"
# A fresh manifest (cache invalidated) is picked up, and exact matches prefer
# the newly written entry.
printf 'sync|/tmp/new|fresh-sub\n' >"$MANIFEST_FILE"
: >"$FOLDERS_FILE"
: >"$MANIFEST_GENERATED_FILE"
manifest_index_invalidate
resolved_local=""
expect_ok "manifest_resolve_local: fresh lines after invalidate" manifest_resolve_local "fresh-sub" resolved_local
expect_eq "manifest_resolve_local: fresh local path" "/tmp/new" "$resolved_local"

# --- manifest index and duplicates --------------------------------------
printf 'sync|/tmp/src|repos/my-app\npull|/tmp/pulled|notes\n\npull|/tmp/other|repos_my-app\n' >"$MANIFEST_FILE"
printf 'sync|/tmp/wizard|notes\nbisync|/tmp/bisync|unique-thing\n' >"$FOLDERS_FILE"
: >"$MANIFEST_GENERATED_FILE"
manifest_index_invalidate
expect_ok "manifest_has_name: sanitized duplicate" manifest_has_name "repos_my-app"
expect_ok "manifest_has_name: notes" manifest_has_name "notes"
expect_ok "manifest_has_name: unique" manifest_has_name "unique-thing"
expect_err "manifest_has_name: unknown" manifest_has_name "missing"
expect_ok "manifest_has_remote: repos/my-app" manifest_has_remote "repos/my-app"
expect_ok "manifest_has_remote: notes" manifest_has_remote "notes"
expect_err "manifest_has_remote: unknown" manifest_has_remote "missing"
expect_ok "manifest_has_duplicate_name: repos_my-app" manifest_has_duplicate_name "repos_my-app"
expect_ok "manifest_has_duplicate_name: notes" manifest_has_duplicate_name "notes"
expect_err "manifest_has_duplicate_name: unique" manifest_has_duplicate_name "unique-thing"

# The index is cached; after the duplicates are removed and the cache is
# invalidated the answers must change.
printf 'sync|/tmp/src|repos/my-app\n' >"$MANIFEST_FILE"
manifest_index_invalidate
expect_err "manifest_has_duplicate_name: refreshed after invalidate" manifest_has_duplicate_name "repos/my-app"

# Membership is literal: a glob in the needle must not match a sibling.
cp "$MANIFEST_FILE" "${TMP}/manifest.index.bak"
cp "$FOLDERS_FILE" "${TMP}/folders.index.bak"
printf 'sync|/tmp/src|repos/axb\n' >"$MANIFEST_FILE"
: >"$FOLDERS_FILE"
manifest_index_invalidate
expect_ok "manifest_has_remote: literal needle matches itself" manifest_has_remote "repos/axb"
expect_err "manifest_has_remote: glob needle is literal" manifest_has_remote "repos/a*b"
expect_err "manifest_has_remote: glob question mark is literal" manifest_has_remote "repos/a?b"
cp "${TMP}/manifest.index.bak" "$MANIFEST_FILE"
cp "${TMP}/folders.index.bak" "$FOLDERS_FILE"
manifest_index_invalidate

# --- manifest_remove_pair -----------------------------------------------
expect_run "manifest_remove_pair: present entry rc 0" 0 manifest_remove_pair "unique-thing"
expect_not_contains "manifest_remove_pair: matching line dropped" "$(cat "$FOLDERS_FILE")" "unique-thing"
expect_contains "manifest_remove_pair: other line kept" "$(cat "$FOLDERS_FILE")" "sync|/tmp/wizard|notes"
cp "$FOLDERS_FILE" "${TMP}/folders.saved"
expect_run "manifest_remove_pair: absent entry rc 1" 1 manifest_remove_pair "nope"
expect_same "manifest_remove_pair: absent entry leaves file unchanged" "${TMP}/folders.saved" "$FOLDERS_FILE"

# --- manifest_append_pair -----------------------------------------------
FOLDERS_FILE="${TMP}/append.conf"
rm -f "$FOLDERS_FILE"
manifest_append_pair "sync" "/tmp/local" "my-sub"
expect_file "manifest_append_pair: creates the file" "$FOLDERS_FILE"
content="$(cat "$FOLDERS_FILE")"
expect_contains "manifest_append_pair: seeds the wizard header" "$content" "# Folder pairs added with"
expect_contains "manifest_append_pair: pair line written" "$content" "sync|/tmp/local|my-sub"
printf 'pull|/tmp/x|old' >"$FOLDERS_FILE"
manifest_append_pair "bisync" "/tmp/y" "new-sub" "clutter.txt"
content="$(cat "$FOLDERS_FILE")"
expect_contains "manifest_append_pair: preserves existing bytes" "$content" "pull|/tmp/x|old"
expect_contains "manifest_append_pair: adds missing newline before append" "$content" "bisync|/tmp/y|new-sub|clutter.txt"
expect_eq "manifest_append_pair: one line per entry" "2" "$(wc -l <"$FOLDERS_FILE" | tr -d ' ')"

# --- manifest_append_pair validation ------------------------------------
# The invalid calls die in a subshell so the suite keeps running.
saved_folders="$FOLDERS_FILE"
FOLDERS_FILE="${TMP}/append-invalid.conf"
rm -f "$FOLDERS_FILE"
expect_dies "manifest_append_pair: rejects a pipe in the local path" manifest_append_pair "sync" "/tmp/a|b" "my-sub"
expect_dies "manifest_append_pair: rejects an unsafe remote subdir" manifest_append_pair "sync" "/tmp/local" "../evil"
expect_dies "manifest_append_pair: rejects an invalid mode" manifest_append_pair "bogus" "/tmp/local" "my-sub"
expect_dies "manifest_append_pair: rejects a filter path" manifest_append_pair "sync" "/tmp/local" "my-sub" "../evil.txt"
expect_no_file "manifest_append_pair: nothing written for invalid pairs" "$FOLDERS_FILE"
FOLDERS_FILE="$saved_folders"

# --- manifest_append_pairs (one atomic batch write) ---------------------
# Every accepted line lands in a single atomic_write, duplicates (existing or
# earlier in the batch) are skipped and counted, and an invalid record dies
# before anything is written.
batch_saved_manifest="$MANIFEST_FILE"
batch_saved_generated="$MANIFEST_GENERATED_FILE"
batch_saved_folders="$FOLDERS_FILE"
MANIFEST_FILE="${TMP}/batch-sources.conf"
MANIFEST_GENERATED_FILE="${TMP}/batch-generated.conf"
: >"$MANIFEST_FILE"
: >"$MANIFEST_GENERATED_FILE"
FOLDERS_FILE="${TMP}/batch.conf"

rm -f "$FOLDERS_FILE"
manifest_index_invalidate
expect_run "manifest_append_pairs: batch rc 0" 0 manifest_append_pairs \
  $'sync\t/tmp/one\tsub-one' $'pull\t/tmp/two\tsub-two' $'bisync\t/tmp/three\tsub-three'
expect_eq "manifest_append_pairs: skipped nothing" "0" "$MANIFEST_APPEND_PAIRS_SKIPPED"
expect_contains "manifest_append_pairs: seeds the wizard header" "$(cat "$FOLDERS_FILE")" "# Folder pairs added with"
expect_eq "manifest_append_pairs: accepted lines keep input order" \
  "$(printf 'sync|/tmp/one|sub-one\npull|/tmp/two|sub-two\nbisync|/tmp/three|sub-three')" \
  "$(tail -n 3 "$FOLDERS_FILE")"

printf '# keep' >"$FOLDERS_FILE"
manifest_index_invalidate
manifest_append_pairs $'sync\t/tmp/one\tsub-one'
expect_eq "manifest_append_pairs: adds missing newline before append" \
  $'# keep\nsync|/tmp/one|sub-one' "$(cat "$FOLDERS_FILE")"

# A whole batch goes through exactly one atomic_write regardless of size.
rm -f "${TMP}/batch-writes"
MANIFEST_FILE="${TMP}/batch-count-sources.conf"
: >"$MANIFEST_FILE"
FOLDERS_FILE="${TMP}/batch-count.conf"
manifest_index_invalidate
(
  atomic_write() { printf 'write\n' >>"${TMP}/batch-writes"; }
  manifest_append_pairs $'sync\t/tmp/a\tsub-a' $'pull\t/tmp/b\tsub-b' $'bisync\t/tmp/c\tsub-c'
)
expect_eq "manifest_append_pairs: one atomic_write for the whole batch" "1" \
  "$(wc -l <"${TMP}/batch-writes" | tr -d ' ')"
MANIFEST_FILE="${TMP}/batch-sources.conf"
: >"$MANIFEST_FILE"
FOLDERS_FILE="${TMP}/batch.conf"
manifest_index_invalidate

printf 'sync|/tmp/seed|sub-one\n' >"$MANIFEST_FILE"
manifest_index_invalidate
printf '# keep\n' >"$FOLDERS_FILE"
manifest_append_pairs \
  $'sync\t/tmp/a\tsub-one' \
  $'pull\t/tmp/b\tsub-new' \
  $'bisync\t/tmp/c\tsub-new' \
  $'sync\t/tmp/d\tsub-other'
expect_eq "manifest_append_pairs: existing and intra-batch duplicates skipped" "2" \
  "$MANIFEST_APPEND_PAIRS_SKIPPED"
expect_eq "manifest_append_pairs: only accepted lines written in order" \
  $'# keep\npull|/tmp/b|sub-new\nsync|/tmp/d|sub-other' "$(cat "$FOLDERS_FILE")"

: >"$MANIFEST_FILE"
manifest_index_invalidate
printf '# keep\n' >"$FOLDERS_FILE"
printf 'pull\t/tmp/stdin\tsub-stdin\n' | manifest_append_pairs
expect_eq "manifest_append_pairs: reads records from stdin" \
  $'# keep\npull|/tmp/stdin|sub-stdin' "$(cat "$FOLDERS_FILE")"

printf '# keep\n' >"$FOLDERS_FILE"
cp "$FOLDERS_FILE" "${TMP}/batch.saved"
manifest_index_invalidate
expect_dies "manifest_append_pairs: rejects an invalid mode" \
  manifest_append_pairs $'bogus\t/tmp/x\tsub-x'
expect_dies "manifest_append_pairs: rejects an unsafe remote subdir" \
  manifest_append_pairs $'sync\t/tmp/x\t../evil'
expect_dies "manifest_append_pairs: rejects a pipe in the local path" \
  manifest_append_pairs $'sync\t/tmp/a|b\tsub-x'
expect_same "manifest_append_pairs: invalid batch leaves the file untouched" \
  "${TMP}/batch.saved" "$FOLDERS_FILE"

rm -f "$FOLDERS_FILE"
manifest_index_invalidate
printf '\n' | manifest_append_pairs
expect_no_file "manifest_append_pairs: blank-only batch writes nothing" "$FOLDERS_FILE"

MANIFEST_FILE="$batch_saved_manifest"
MANIFEST_GENERATED_FILE="$batch_saved_generated"
FOLDERS_FILE="$batch_saved_folders"
manifest_index_invalidate

# --- manifest_write_pair_filter -----------------------------------------
MANIFEST_PAIR_FILTER=""
expect_run "manifest_write_pair_filter: rc 0" 0 manifest_write_pair_filter "my-pair" "my-sub" "build" "dist/"
expect_eq "manifest_write_pair_filter: sets file name" "pair-my-pair.txt" "$MANIFEST_PAIR_FILTER"
expect_file "manifest_write_pair_filter: creates file" "${FILTER_DIR}/pair-my-pair.txt"
pair_content="$(cat "${FILTER_DIR}/pair-my-pair.txt")"
expect_contains "manifest_write_pair_filter: header written" "$pair_content" "# Pair filter for 'my-sub'"
expect_contains "manifest_write_pair_filter: exclude rule written" "$pair_content" "- build/"
expect_contains "manifest_write_pair_filter: trailing slash normalized" "$pair_content" "- dist/"
cp "${FILTER_DIR}/pair-my-pair.txt" "${TMP}/pair.saved"
expect_run "manifest_write_pair_filter: same content is idempotent" 0 manifest_write_pair_filter "my-pair" "my-sub" "build" "dist/"
expect_same "manifest_write_pair_filter: idempotent run keeps bytes" "${TMP}/pair.saved" "${FILTER_DIR}/pair-my-pair.txt"
printf 'manual\n' >"${FILTER_DIR}/pair-conflict.txt"
out="$(write_filter_probe conflict sub build)"
rc=$?
expect_rc "manifest_write_pair_filter: conflict dies rc 1" "$rc" 1
expect_contains "manifest_write_pair_filter: conflict message" "$out" "different content"
expect_eq "manifest_write_pair_filter: conflict leaves file untouched" "manual" "$(cat "${FILTER_DIR}/pair-conflict.txt")"
out="$(write_filter_probe invalid-pair sub ../evil)"
rc=$?
expect_rc "manifest_write_pair_filter: unsafe exclude dies rc 1" "$rc" 1
expect_contains "manifest_write_pair_filter: unsafe exclude message" "$out" "invalid exclude"

# --- manifest_pair_flags (paused/hidden) ---------------------------------
# The into variants resolve the directory and file without a command
# substitution, and the predicates share one parse of the flag file.
expect_eq "pair_flags_file: joins dir and name" "${STATE_DIR}/pairs/probe-pair" \
  "$(manifest_pair_flags_file 'probe-pair')"
pf_dir=""
expect_ok "pair_flags_dir_into: rc 0" manifest_pair_flags_dir_into pf_dir
expect_eq "pair_flags_dir_into: value" "${STATE_DIR}/pairs" "$pf_dir"
pf_file=""
expect_ok "pair_flags_file_into: rc 0" manifest_pair_flags_file_into pf_file 'probe-pair'
expect_eq "pair_flags_file_into: value" "${STATE_DIR}/pairs/probe-pair" "$pf_file"

expect_ok "pair_flags_set: paused on" manifest_pair_flags_set 'probe-pair' paused 1
expect_ok "pair_paused: true" manifest_pair_paused 'probe-pair'
expect_err "pair_hidden: false" manifest_pair_hidden 'probe-pair'
expect_ok "pair_flags_set: hidden on" manifest_pair_flags_set 'probe-pair' hidden 1
# A write drops the shared parse, so both predicates see the new pair.
expect_ok "pair_paused: still true" manifest_pair_paused 'probe-pair'
expect_ok "pair_hidden: now true" manifest_pair_hidden 'probe-pair'
expect_ok "pair_flags_set: paused off" manifest_pair_flags_set 'probe-pair' paused 0
expect_err "pair_paused: false after set" manifest_pair_paused 'probe-pair'
expect_ok "pair_hidden: unchanged after the paused set" manifest_pair_hidden 'probe-pair'
expect_err "pair_paused: unknown pair is off" manifest_pair_paused 'no-such-pair'
expect_err "pair_hidden: unknown pair is off" manifest_pair_hidden 'no-such-pair'
expect_err "pair_flags_set: rejects an unknown key" manifest_pair_flags_set 'probe-pair' bogus 1
expect_err "pair_flags_set: rejects a bad value" manifest_pair_flags_set 'probe-pair' paused 2
# Unrelated lines are ignored on write and the preserved key is kept.
printf 'paused=1\njunk=9\n' >"${STATE_DIR}/pairs/probe-pair"
MANIFEST_PAIR_FLAGS_LOADED_NAME=""
expect_ok "pair_flags_set: rewrites the raw file" manifest_pair_flags_set 'probe-pair' hidden 1
expect_contains "pair_flags_set: preserves paused" "$(cat "${STATE_DIR}/pairs/probe-pair")" "paused=1"
expect_contains "pair_flags_set: writes hidden" "$(cat "${STATE_DIR}/pairs/probe-pair")" "hidden=1"
expect_not_contains "pair_flags_set: drops unrelated lines" "$(cat "${STATE_DIR}/pairs/probe-pair")" "junk"

finish
