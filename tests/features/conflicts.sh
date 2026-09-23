#!/usr/bin/env bash
# conflicts.sh - local conflict detection (conflict copies and case-clash
# quarantine names; read-only, no network), the kind filter, and --open.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

NOTES_DIR="${TMP}/local/notes"
OTHER_DIR="${TMP}/local/other"
MISSING_DIR="${TMP}/local/missing"
mkdir -p "$NOTES_DIR" "$OTHER_DIR"
printf 'hello' >"${NOTES_DIR}/foo.txt.(conflicted copy)1"
printf 'hello' >"${NOTES_DIR}/foo (conflicted copy 2024-01-02 120000).txt"
printf 'keep' >"${NOTES_DIR}/normal.txt"
printf 'hello' >"${OTHER_DIR}/other.txt.(conflicted copy)1"
cat >"$MANIFEST_FILE" <<EOF
sync|${NOTES_DIR}|notes
EOF

# Doctor runs against the configured local remote; HOME is redirected so the
# launchd check never reads the real ~/Library.
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_cli_doctor() {
  (cd "$TMP" && env HOME="${TMP}/home" RCLONE_REMOTE=testremote bash "${PROJ}/bin/sciebo" "$@")
}

# --- listing: both conflict styles, columns filled, count line --------------
expect_cli "conflicts: rc 0 with conflict copies" 0 run_cli conflicts
expect_contains "conflicts: header printed" "$CLI_OUT" "RELATIVE PATH"
expect_contains "conflicts: rclone-style copy listed" "$CLI_OUT" "foo.txt.(conflicted copy)1"
expect_contains "conflicts: desktop-style copy listed" "$CLI_OUT" "foo (conflicted copy 2024-01-02 120000).txt"
expect_contains "conflicts: count line" "$CLI_OUT" "2 conflict copy(ies) found"
expect_not_contains "conflicts: normal file hidden" "$CLI_OUT" "normal.txt"
expect_no_file "conflicts: state directory untouched" "$STATE_DIR"

row="$(printf '%s\n' "$CLI_OUT" | grep -F 'foo (conflicted copy 2024-01-02 120000).txt' | head -n 1)"
expect_contains "conflicts: modified column filled" "$row" "$(date '+%Y-%m-%d')"
expect_contains "conflicts: size column filled" "$row" "5B"

# --- --quiet: rc 1 with copies, rc 0 and silent without ---------------------
capture run_cli conflicts --quiet
expect_rc "conflicts: --quiet rc 1 with copies" "$CLI_RC" 1
expect_eq "conflicts: --quiet prints nothing" "" "$CLI_OUT"

rm -f "${NOTES_DIR}/foo.txt.(conflicted copy)1" "${NOTES_DIR}/foo (conflicted copy 2024-01-02 120000).txt"
capture run_cli conflicts --quiet
expect_rc "conflicts: --quiet rc 0 without copies" "$CLI_RC" 0
expect_eq "conflicts: --quiet silent without copies" "" "$CLI_OUT"
expect_cli "conflicts: normal mode rc 0 without copies" 0 run_cli conflicts
expect_contains "conflicts: no-conflict message" "$CLI_OUT" "no conflict copies"
printf 'hello' >"${NOTES_DIR}/foo.txt.(conflicted copy)1"
printf 'hello' >"${NOTES_DIR}/foo (conflicted copy 2024-01-02 120000).txt"

# --- --only filters to one entry; an unknown name is an error ---------------
printf 'pull|%s|other\n' "$OTHER_DIR" >>"$MANIFEST_FILE"
expect_cli "conflicts: --only rc 0" 0 run_cli conflicts --only notes
expect_contains "conflicts: --only keeps the named entry" "$CLI_OUT" "foo.txt.(conflicted copy)1"
expect_not_contains "conflicts: --only hides other entries" "$CLI_OUT" "other.txt"
expect_contains "conflicts: --only count line" "$CLI_OUT" "2 conflict copy(ies) found"

expect_cli "conflicts: unknown --only rc 1" 1 run_cli conflicts --only nope
expect_contains "conflicts: unknown --only names the entry" "$CLI_OUT" "No source named 'nope'"

# --- a missing local dir is skipped with a warning, not an error ------------
printf 'sync|%s|missing\n' "$MISSING_DIR" >>"$MANIFEST_FILE"
expect_cli "conflicts: missing local dir rc 0" 0 run_cli conflicts
expect_contains "conflicts: missing dir warned" "$CLI_OUT" "WARN"
expect_contains "conflicts: missing dir skipped" "$CLI_OUT" "does not exist; skipped"
expect_not_contains "conflicts: missing dir is not an error" "$CLI_OUT" "ERROR"
expect_contains "conflicts: all entries counted" "$CLI_OUT" "3 conflict copy(ies) found"

# --- doctor --offline sees the same conflict copies (local scan) ------------
capture run_cli_doctor doctor --offline
expect_contains "doctor: WARN names the conflict count" "$CLI_OUT" "conflict copies: 3 found"
expect_contains "doctor: sample relative path shown" "$CLI_OUT" "foo.txt.(conflicted copy)1"

# --- case-clash conflicts: "(case conflict)" quarantine names are listed ----
mkdir -p "${NOTES_DIR}/sub"
printf 'case\n' >"${NOTES_DIR}/report (case conflict).txt"
printf 'case2\n' >"${NOTES_DIR}/report2 (case conflict)-2.txt"
printf 'deep\n' >"${NOTES_DIR}/sub/deep (case conflict).md"

expect_cli "case conflicts: rc 0" 0 run_cli conflicts
expect_contains "case conflicts: quarantine file listed" "$CLI_OUT" "report (case conflict).txt"
expect_contains "case conflicts: numbered quarantine listed" "$CLI_OUT" "report2 (case conflict)-2.txt"
expect_contains "case conflicts: nested quarantine listed" "$CLI_OUT" "sub/deep (case conflict).md"
expect_contains "case conflicts: count includes both kinds" "$CLI_OUT" "6 conflict copy(ies) found"

row="$(printf '%s\n' "$CLI_OUT" | grep -F 'report (case conflict).txt' | head -n 1)"
expect_eq "case conflicts: kind column is case" "case" "$(printf '%s\n' "$row" | awk '{print $NF}')"
row="$(printf '%s\n' "$CLI_OUT" | grep -F 'foo.txt.(conflicted copy)1' | head -n 1)"
expect_eq "case conflicts: kind column is copy" "copy" "$(printf '%s\n' "$row" | awk '{print $NF}')"

# --- --kind filters the listing ---------------------------------------------
expect_cli "kind filter: case rc 0" 0 run_cli conflicts --kind case --only notes
expect_contains "kind filter: case rows listed" "$CLI_OUT" "report (case conflict).txt"
expect_not_contains "kind filter: copies hidden" "$CLI_OUT" "conflicted copy"
expect_contains "kind filter: case count" "$CLI_OUT" "3 conflict copy(ies) found"

expect_cli "kind filter: copy rc 0" 0 run_cli conflicts --kind copy --only notes
expect_contains "kind filter: copies listed" "$CLI_OUT" "foo.txt.(conflicted copy)1"
expect_not_contains "kind filter: case rows hidden" "$CLI_OUT" "(case conflict)"
expect_contains "kind filter: copy count" "$CLI_OUT" "2 conflict copy(ies) found"

expect_cli "kind filter: all rc 0" 0 run_cli conflicts --kind all --only notes
expect_contains "kind filter: all keeps both kinds" "$CLI_OUT" "5 conflict copy(ies) found"

expect_cli "kind filter: unknown rc 2" 2 run_cli conflicts --kind nope
expect_contains "kind filter: unknown names the kinds" "$CLI_OUT" "use copy, case, or all"

# --- --json carries the kind field ------------------------------------------
expect_cli "case json: rc 0" 0 run_cli conflicts --resolve keep-local --json --kind case --only notes
expect_contains "case json: kind field" "$CLI_OUT" '"kind": "case"'
expect_contains "case json: path field" "$CLI_OUT" '"path": "report (case conflict).txt"'
expect_contains "case json: count" "$CLI_OUT" '"total": 3'
expect_file "case json: dry run keeps the quarantine file" "${NOTES_DIR}/report (case conflict).txt"

# --- --open opens each containing directory once ----------------------------
OPEN_BIN="${TMP}/conflicts-open-bin"
OPEN_LOG="${TMP}/conflicts-open.log"
mkdir -p "$OPEN_BIN"
for opener in open xdg-open; do
  cat >"${OPEN_BIN}/${opener}" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"${CONFLICTS_OPEN_LOG:-/dev/null}"
exit 0
STUB
  chmod +x "${OPEN_BIN}/${opener}"
done
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_cli_open() {
  (cd "$TMP" && env PATH="${OPEN_BIN}:$PATH" CONFLICTS_OPEN_LOG="$OPEN_LOG" bash "${PROJ}/bin/sciebo" "$@")
}

rm -f "$OPEN_LOG"
expect_cli "open: rc 0" 0 run_cli_open conflicts --open --kind case --only notes
expect_contains "open: lists the case rows" "$CLI_OUT" "report (case conflict).txt"
expect_eq "open: one call per containing directory" "2" "$(wc -l <"$OPEN_LOG" | tr -d ' ')"
expect_contains "open: root directory opened" "$(cat "$OPEN_LOG")" "$NOTES_DIR"
expect_contains "open: nested directory opened" "$(cat "$OPEN_LOG")" "${NOTES_DIR}/sub"
expect_contains "open: summary printed" "$CLI_OUT" "3 conflict copy(ies) found"

rm -f "$OPEN_LOG"
capture run_cli_open conflicts --open --kind case --only notes --quiet
expect_rc "open --quiet: rc 0" "$CLI_RC" 0
expect_eq "open --quiet: silent" "" "$CLI_OUT"
expect_eq "open --quiet: still opens the directories" "2" "$(wc -l <"$OPEN_LOG" | tr -d ' ')"

expect_cli "open: conflicts with --resolve rc 2" 2 run_cli_open conflicts --open --resolve keep-local
expect_contains "open: resolve rejection explained" "$CLI_OUT" "--open cannot be combined with --resolve"

# --- --open with nothing to open --------------------------------------------
rm -f "${NOTES_DIR}/report (case conflict).txt" "${NOTES_DIR}/report2 (case conflict)-2.txt" \
  "${NOTES_DIR}/sub/deep (case conflict).md" "${NOTES_DIR}/foo.txt.(conflicted copy)1" \
  "${NOTES_DIR}/foo (conflicted copy 2024-01-02 120000).txt"
expect_cli "open: no conflicts rc 0" 0 run_cli_open conflicts --open --only notes
expect_contains "open: no conflicts message" "$CLI_OUT" "no conflicts"
capture run_cli_open conflicts --open --only notes --quiet
expect_rc "open: no conflicts --quiet rc 0" "$CLI_RC" 0
expect_eq "open: no conflicts --quiet silent" "" "$CLI_OUT"

# --- --remote: read-only online case-clash listing (stubbed rclone) ---------
RC_STUB="${TMP}/remote-conflicts-bin"
RC_LSF="${TMP}/remote-conflicts-lsf.txt"
RC_LOG="${TMP}/remote-conflicts.log"
mkdir -p "$RC_STUB"
cat >"${RC_STUB}/rclone" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"${RC_LOG:-/dev/null}"
for arg in "$@"; do
  case "$arg" in
    version)
      printf 'rclone v1.75.1\n'
      exit 0
      ;;
    listremotes)
      printf 'testremote:\n'
      exit 0
      ;;
    lsf)
      if [[ -n "${RC_LSF_FAIL:-}" ]]; then
        printf 'rclone: failed to list\n' >&2
        exit 1
      fi
      cat "${RC_LSF:-/dev/null}"
      exit 0
      ;;
  esac
done
exit 0
STUB
chmod +x "${RC_STUB}/rclone"
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_cli_remote() {
  (cd "$TMP" && env PATH="${RC_STUB}:$PATH" RCLONE_BIN="${RC_STUB}/rclone" RC_LOG="$RC_LOG" RC_LSF="$RC_LSF" bash "${PROJ}/bin/sciebo" "$@")
}
# run_cli_remote_unreachable - same as run_cli_remote but the stubbed rclone
# lsf fails, simulating an unreachable remote.
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_cli_remote_unreachable() {
  (cd "$TMP" && env PATH="${RC_STUB}:$PATH" RCLONE_BIN="${RC_STUB}/rclone" RC_LOG="$RC_LOG" RC_LSF="$RC_LSF" RC_LSF_FAIL=1 bash "${PROJ}/bin/sciebo" "$@")
}

printf 'Dir/File.txt\nDir/file.txt\nother.txt\n' >"$RC_LSF"
expect_cli "remote conflicts: rc 0" 0 run_cli_remote conflicts --kind case --remote --only notes
expect_contains "remote conflicts: kept name listed" "$CLI_OUT" "Dir/File.txt"
expect_contains "remote conflicts: losing name listed" "$CLI_OUT" "Dir/file.txt"
expect_contains "remote conflicts: count line" "$CLI_OUT" "1 remote case clash(es) found"
expect_not_contains "remote conflicts: lone name hidden" "$CLI_OUT" "other.txt"

expect_cli "remote conflicts: json rc 0" 0 run_cli_remote conflicts --kind case --remote --json --only notes
expect_contains "remote conflicts: json remote flag" "$CLI_OUT" '"remote": true'
expect_contains "remote conflicts: json kind" "$CLI_OUT" '"kind": "case"'
expect_contains "remote conflicts: json first" "$CLI_OUT" '"first": "Dir/File.txt"'
expect_contains "remote conflicts: json second" "$CLI_OUT" '"second": "Dir/file.txt"'
expect_contains "remote conflicts: json total" "$CLI_OUT" '"total": 1'

# --- --remote: a failed listing warns instead of claiming "no clashes" ------
expect_cli "remote conflicts: failed listing rc 0" 0 run_cli_remote_unreachable conflicts --kind case --remote --only notes
expect_contains "remote conflicts: failed listing warned" "$CLI_OUT" "could not list"
expect_contains "remote conflicts: failed listing warns the scan is skipped" "$CLI_OUT" "skipping the remote case scan"
expect_contains "remote conflicts: failed listing marks the scan incomplete" "$CLI_OUT" "remote case scan incomplete"
expect_not_contains "remote conflicts: failed listing does not claim clean" "$CLI_OUT" "no remote case clashes"

expect_cli "remote conflicts: --kind copy rc 2" 2 run_cli_remote conflicts --remote --kind copy
expect_contains "remote conflicts: --kind copy explained" "$CLI_OUT" "--remote lists case clashes only"
expect_cli "remote conflicts: --resolve rc 2" 2 run_cli_remote conflicts --remote --resolve keep-local
expect_contains "remote conflicts: --resolve explained" "$CLI_OUT" "--remote cannot be combined with --resolve"

: >"$RC_LOG"
expect_cli "remote conflicts: local run rc 0" 0 run_cli_remote conflicts --only notes
expect_not_contains "remote conflicts: local run never lists" "$(cat "$RC_LOG")" " lsf "

# --- fork-free stat/mtime: the helpers run in the caller's shell ------------
# file_mtime_or (via the ${ ...;} capture, replacing the module-local
# conflicts_mtime_epoch wrapper) and the per-file stamp run in this shell, so
# a stubbed helper's counter survives. With the old $(...) form the counter
# stayed at zero (it was set in the forked subshell).
# shellcheck source=/dev/null
source "${PROJ}/lib/commands/conflicts.sh"
fork_dir="${TMP}/fork-conflicts"
rm -rf "$fork_dir"
mkdir -p "$fork_dir"
printf 'x' >"${fork_dir}/a.txt.(conflicted copy)1"
fork_mtime_calls=0
# shellcheck disable=SC2329  # counted while file_mtime_or runs in this shell
file_mtime() {
  fork_mtime_calls=$((fork_mtime_calls + 1))
  printf '1700000000'
}
fork_mtime=${ file_mtime_or "${fork_dir}/a.txt.(conflicted copy)1" 0;}
expect_eq "conflicts: mtime helper is forkless" "1700000000" "$fork_mtime"
expect_eq "conflicts: mtime helper runs once in this shell" "1" "$fork_mtime_calls"
fork_stamp_calls=0
# shellcheck disable=SC2329  # counted while conflicts_process_entry runs in this shell
file_stamp() {
  fork_stamp_calls=$((fork_stamp_calls + 1))
  printf '1700000000 5'
}
# shellcheck disable=SC2034  # read by conflicts_process_entry
CONFLICT_PATTERN="conflicted copy"
# shellcheck disable=SC2034  # read by conflicts_process_entry
ENTRY_NAME=notes ENTRY_LOCAL="$fork_dir" CONFLICTS_KIND=all CONFLICTS_QUIET=true
# shellcheck disable=SC2034  # read by conflicts_process_entry
CONFLICTS_OPEN=false CONFLICTS_TOTAL=0
conflicts_process_entry
expect_eq "conflicts: stamp runs once in this shell" "1" "$fork_stamp_calls"
expect_eq "conflicts: fork probe still counts the copy" "1" "$CONFLICTS_TOTAL"

# conflicts_resolve_mode reads both mtimes through the forkless helper, and
# conflicts_print_plan captures printable the same way, so each stub's counter
# survives in this shell (the old $(...) forms left it at zero).
printf 'base' >"${fork_dir}/a.txt"
fork_mode_calls=0
# shellcheck disable=SC2329  # counted while conflicts_resolve_mode runs in this shell
file_mtime() {
  fork_mode_calls=$((fork_mode_calls + 1))
  printf '%s' "$((fork_mode_calls * 100))"
}
# shellcheck disable=SC2034  # assigned through the namerefs
mode_action="" mode_target_abs="" mode_target_rel=""
conflicts_resolve_mode keep-newest "$fork_dir" \
  "${fork_dir}/a.txt.(conflicted copy)1" "a.txt.(conflicted copy)1" \
  "${fork_dir}/a.txt" "a.txt" mode_action mode_target_abs mode_target_rel
expect_eq "conflicts: resolve mode reads mtimes in this shell" "2" "$fork_mode_calls"
expect_eq "conflicts: resolve mode keeps the newer copy" "keep-local" "$mode_action"
expect_eq "conflicts: resolve mode targets the original" "${fork_dir}/a.txt" "$mode_target_abs"

fork_print_calls=0
# shellcheck disable=SC2329  # counted while conflicts_print_plan runs in this shell
printable() {
  fork_print_calls=$((fork_print_calls + 1))
  printf '%s' "$1"
}
# The plan is one escaped TAB record per action (CONFLICTS_RECORD_FIELDS):
# source kind conflict dir rel base_abs base_rel action target_abs
# target_rel - only source/rel/action/target_rel carry values here.
rec=$'notes\t\t\t\ta.txt\t\t\tkeep-local\t\ta.txt'
# shellcheck disable=SC2034  # read by conflicts_print_plan
CONFLICTS_PLAN=("$rec")
conflicts_print_plan >/dev/null
expect_eq "conflicts: plan printing runs in this shell" "3" "$fork_print_calls"

finish
