#!/usr/bin/env bash
# bigfolder.sh - big-folder scan cache: a fresh scan emits the large row and
# warns once, a second notify within BIGFOLDER_SCAN_TTL reuses the cached
# rows without touching rclone, and BIGFOLDER_SCAN_TTL=0 forces a rescan.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

# bigfolder_notify builds on these libraries; bin/sciebo loads the rest, so
# this suite runs the functions directly.
# shellcheck disable=SC1090,SC1091
source "${PROJ}/lib/manifest.sh"
# shellcheck disable=SC1090,SC1091
source "${PROJ}/lib/rclone.sh"
# shellcheck disable=SC1090,SC1091
source "${PROJ}/lib/capabilities.sh"
# shellcheck disable=SC1090,SC1091
source "${PROJ}/lib/notify.sh"
# shellcheck disable=SC1090,SC1091
source "${PROJ}/lib/bigfolder.sh"

BF_STATE="${TMP}/bigfolder-state"
BF_CALLS="${TMP}/bigfolder-calls.log"
export STATE_DIR="$BF_STATE" REMOTE_PREFIX="testremote:backup" \
  BIG_FOLDER_SIZE=1M BIGFOLDER_SCAN_TTL=1h
# rclone_available only needs an executable path; rclone_cmd is stubbed below.
RCLONE_BIN="$(command -v rclone)"
export RCLONE_BIN

# rclone_cmd stub: append every invocation to BF_CALLS so the test can count
# listings, and answer lsf/size from a fixed tree (videos is large, tiny is
# not). The single recursive listing carries SIZE;PATH rows: directories
# appear as "-1;name/" and files with their byte count, which
# _bigfolder_child_sizes sums per top-level child.
# shellcheck disable=SC2329  # invoked indirectly by bigfolder_scan/notify
rclone_cmd() {
  printf '%s\n' "$*" >>"$BF_CALLS"
  case "$*" in
    *-R*)
      printf '%s\n' '-1;videos/' '-1;tiny/' \
        '7;root.txt' '5242880;videos/clip.bin' '1024;tiny/note.bin'
      ;;
    lsf*) printf 'videos/\ntiny/\n' ;;
    size*videos*) printf '{"count":2,"bytes":5242880,"sizeless":0}\n' ;;
    size*) printf '{"count":1,"bytes":1024,"sizeless":0}\n' ;;
  esac
}

bf_size_count() { grep -c '^size ' "$BF_CALLS" 2>/dev/null || true; }
bf_recursive_count() { grep -c '^lsf .* -R' "$BF_CALLS" 2>/dev/null || true; }

# --- rclone_size_bytes parses the size payload -------------------------------
expect_eq "bigfolder: rclone_size_bytes parses the payload" "5242880" \
  "$(rclone_size_bytes '{"count":2,"bytes":5242880,"sizeless":0}')"
expect_eq "bigfolder: rclone_size_bytes on an unreadable payload is empty" "" \
  "$(rclone_size_bytes 'not json')"

# --- (a) a scan above BIG_FOLDER_SIZE emits the row and warns once ---------
: >"$BF_CALLS"
scan_rows="$(bigfolder_scan bigroot bigroot)"
expect_contains "scan: emits the large folder row" "$scan_rows" $'videos\t5242880\t5Mi'
expect_not_contains "scan: omits the folder below the limit" "$scan_rows" "tiny"
expect_eq "scan: uses one recursive listing" "1" "$(bf_recursive_count)"
expect_eq "scan: makes no per-child size call" "0" "$(bf_size_count)"

: >"$BF_CALLS"
capture bigfolder_notify bigroot bigroot
expect_rc "notify: first scan rc 0" "$CLI_RC" 0
expect_contains "notify: large folder warned" "$CLI_OUT" "big folder: bigroot/videos is 5Mi"
expect_contains "notify: add hint" "$CLI_OUT" "add it with 'sciebo folders add'"
expect_not_contains "notify: small folder not warned" "$CLI_OUT" "bigroot/tiny"
expect_eq "notify: fresh scan uses one recursive listing" "1" "$(bf_recursive_count)"
expect_eq "notify: fresh scan makes no size call" "0" "$(bf_size_count)"
expect_file "notify: seen cache written" "${BF_STATE}/bigfolder/bigroot"
expect_file "notify: scan cache written" "${BF_STATE}/bigfolder/scan-bigroot"
expect_eq "notify: scan cache mode 600" "600" "$(file_mode "${BF_STATE}/bigfolder/scan-bigroot")"
scan_stamp="$(sed -n '1p' "${BF_STATE}/bigfolder/scan-bigroot")"
case "$scan_stamp" in
  '' | *[!0-9]*) fail "notify: scan cache first line is an epoch" "got [$scan_stamp]" ;;
  *) pass "notify: scan cache first line is an epoch" ;;
esac
expect_contains "notify: scan cache holds the row" \
  "$(sed -n '2p' "${BF_STATE}/bigfolder/scan-bigroot")" $'videos\t'

# --- (b) a second notify within the TTL reuses the cache -------------------
# No remote scan at all (neither lsf nor size), and the seen cache keeps the
# warning quiet.
: >"$BF_CALLS"
capture bigfolder_notify bigroot bigroot
expect_rc "notify: cached run rc 0" "$CLI_RC" 0
expect_not_contains "notify: cached run stays quiet" "$CLI_OUT" "big folder:"
expect_eq "notify: cached run makes no size call" "0" "$(bf_size_count)"
expect_eq "notify: cached run makes no recursive listing" "0" "$(bf_recursive_count)"
expect_eq "notify: cached run makes no lsf call" "0" \
  "$(grep -c '^lsf ' "$BF_CALLS" 2>/dev/null || true)"

# --- (c) BIGFOLDER_SCAN_TTL=0 disables the cache and forces a rescan -------
# The seen cache still suppresses the repeat warning.
export BIGFOLDER_SCAN_TTL=0
: >"$BF_CALLS"
capture bigfolder_notify bigroot bigroot
expect_rc "notify: ttl=0 run rc 0" "$CLI_RC" 0
expect_eq "notify: ttl=0 relists recursively" "1" "$(bf_recursive_count)"
expect_eq "notify: ttl=0 makes no size call" "0" "$(bf_size_count)"
expect_not_contains "notify: ttl=0 still hides the seen folder" "$CLI_OUT" "big folder:"
expect_file "notify: ttl=0 rewrites the scan cache" "${BF_STATE}/bigfolder/scan-bigroot"

# --- fork-free captures: the pure helpers run in the caller's shell ---------
# bigfolder_scan captures _bigfolder_pair_filter and _bigfolder_label with
# ${ ...;} rather than $(...), so stubbed counters survive in this shell. With
# the old $(...) form each counter stayed at zero (set in a forked subshell).
bf_filter_calls=0
bf_label_calls=0
# shellcheck disable=SC2329  # counted while bigfolder_scan runs in this shell
_bigfolder_pair_filter() {
  bf_filter_calls=$((bf_filter_calls + 1))
  printf ''
}
# shellcheck disable=SC2329  # counted while bigfolder_scan runs in this shell
_bigfolder_label() {
  bf_label_calls=$((bf_label_calls + 1))
  printf 'XLABEL'
}
bigfolder_scan bigroot bigroot >"${TMP}/bf-forkless.out"
expect_eq "scan: _bigfolder_pair_filter is forkless" "1" "$bf_filter_calls"
expect_eq "scan: _bigfolder_label is forkless" "1" "$bf_label_calls"
expect_contains "scan: forkless label lands in the row" \
  "$(cat "${TMP}/bf-forkless.out")" $'videos\t5242880\tXLABEL'

finish
