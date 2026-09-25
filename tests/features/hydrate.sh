#!/usr/bin/env bash
# hydrate.sh - on-demand download of a remote path (`sciebo hydrate`).
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

# A local tree behind a real rclone remote. The local backend has no root
# option, so an alias remote points rclone at the temp tree.
REMOTE_ROOT="${TMP}/remote"
mkdir -p "${REMOTE_ROOT}/backup/docs/sub"
printf 'hello\n' >"${REMOTE_ROOT}/backup/docs/a.txt"
printf 'nested\n' >"${REMOTE_ROOT}/backup/docs/sub/b.txt"
rclone config create hydretest alias remote="$REMOTE_ROOT" --config "$RCLONE_CONFIG" >/dev/null 2>&1 || {
  echo "SKIP: cannot create temporary alias remote"
  finish
}
export RCLONE_REMOTE=hydretest FOLDERS_LOCAL_ROOT="${TMP}/folders-root"

# The manifest entry owns the default destination.
printf 'pull|%s|docs\n' "${TMP}/local" >"$MANIFEST_FILE"

# --dest copies the contents of SUB into the given directory.
expect_cli "hydrate: --dest rc 0" 0 run_cli hydrate docs --dest "${TMP}/out"
expect_file "hydrate: --dest copies a.txt" "${TMP}/out/a.txt"
expect_file "hydrate: --dest copies nested b.txt" "${TMP}/out/sub/b.txt"
expect_contains "hydrate: --dest prints the transfer" "$CLI_OUT" "hydrated docs -> ${TMP}/out"

# A dry run reports the transfer but writes nothing.
expect_cli "hydrate: dry run rc 0" 0 run_cli hydrate docs --dest "${TMP}/out-dry" --dry-run
expect_contains "hydrate: dry run message" "$CLI_OUT" "dry run, nothing copied"
expect_no_file "hydrate: dry run copies nothing" "${TMP}/out-dry/a.txt"

# --quiet keeps the success line off stdout.
expect_cli "hydrate: quiet rc 0" 0 run_cli hydrate docs --dest "${TMP}/out-quiet" --quiet
expect_file "hydrate: quiet still copies" "${TMP}/out-quiet/a.txt"
expect_not_contains "hydrate: quiet prints no success line" "$CLI_OUT" "hydrated docs"

# --progress is accepted; the CLI's stdout is captured by the harness (not a
# TTY), so no -P reaches rclone. The TTY branch is exercised below.
expect_cli "hydrate: --progress rc 0" 0 run_cli hydrate docs --dest "${TMP}/out-progress" --progress
expect_file "hydrate: --progress still copies" "${TMP}/out-progress/a.txt"
expect_contains "hydrate: --progress prints the transfer" "$CLI_OUT" "hydrated docs -> ${TMP}/out-progress"

# Without --dest the manifest entry's local directory wins.
expect_cli "hydrate: manifest destination rc 0" 0 run_cli hydrate docs
expect_file "hydrate: manifest destination file" "${TMP}/local/a.txt"
expect_contains "hydrate: manifest destination output" "$CLI_OUT" "hydrated docs -> ${TMP}/local"

# A parent manifest entry gets the remaining relative path appended.
expect_cli "hydrate: sub path rc 0" 0 run_cli hydrate docs/sub
expect_file "hydrate: sub path file" "${TMP}/local/sub/b.txt"

# The manifest entry's filter file applies to the transfer.
printf -- '- sub/**\n' >"${FILTER_DIR}/skip-sub.txt"
printf 'pull|%s|docs|skip-sub.txt\n' "${TMP}/local" >"$MANIFEST_FILE"
rm -rf "${TMP}/local"
expect_cli "hydrate: entry filter rc 0" 0 run_cli hydrate docs
expect_file "hydrate: filtered copy keeps a.txt" "${TMP}/local/a.txt"
expect_no_file "hydrate: filtered copy skips sub/b.txt" "${TMP}/local/sub/b.txt"
rm -f "${FILTER_DIR}/skip-sub.txt"
printf 'pull|%s|docs\n' "${TMP}/local" >"$MANIFEST_FILE"

# Without a manifest match the destination is FOLDERS_LOCAL_ROOT/SUB.
: >"$MANIFEST_FILE"
expect_cli "hydrate: folders root fallback rc 0" 0 run_cli hydrate docs
expect_file "hydrate: folders root fallback file" "${TMP}/folders-root/docs/a.txt"

# --json reports path, dest, and the dry-run state.
expect_cli "hydrate: json rc 0" 0 run_cli hydrate docs --dest "${TMP}/out-json" --json
expect_contains "hydrate: json path" "$CLI_OUT" '"path": "docs"'
expect_contains "hydrate: json dest" "$CLI_OUT" '"dest"'
expect_contains "hydrate: json dry_run" "$CLI_OUT" '"dry_run": false'
expect_cli "hydrate: json dry run rc 0" 0 run_cli hydrate docs --dest "${TMP}/out-json" --dry-run --json
expect_contains "hydrate: json dry run true" "$CLI_OUT" '"dry_run": true'

# The failure blacklist excludes paths that failed repeatedly, like sync.
printf 'pull|%s|docs\n' "${TMP}/local-bl" >"$MANIFEST_FILE"
mkdir -p "${TMP}/state/blacklist"
printf '3\ta.txt\tboom\n' >"${TMP}/state/blacklist/docs"
printf 'hidden\n' >"${REMOTE_ROOT}/backup/docs/.hidden.txt"
printf 'server\n' >"${REMOTE_ROOT}/backup/docs/skipped.txt"
expect_cli "hydrate: blacklist rc 0" 0 run_cli hydrate docs
expect_no_file "hydrate: blacklisted path not copied" "${TMP}/local-bl/a.txt"
expect_file "hydrate: non-blacklisted nested file copied" "${TMP}/local-bl/sub/b.txt"
expect_contains "hydrate: blacklist warning" "$CLI_OUT" "blacklisted path(s) excluded"

# SKIP_HIDDEN=1 layers the hidden-file exclusion like sync.
export SKIP_HIDDEN=1
expect_cli "hydrate: skip hidden rc 0" 0 run_cli hydrate docs --dest "${TMP}/out-hidden"
expect_file "hydrate: visible file copied with SKIP_HIDDEN" "${TMP}/out-hidden/skipped.txt"
expect_no_file "hydrate: hidden file not copied with SKIP_HIDDEN" "${TMP}/out-hidden/.hidden.txt"
unset SKIP_HIDDEN

# FILTER_SERVER_SYNC=1 layers the generated server-exclude filter.
printf -- '- skipped.txt\n' >"${FILTER_DIR}/server-exclude.txt"
export FILTER_SERVER_SYNC=1
expect_cli "hydrate: server exclude rc 0" 0 run_cli hydrate docs --dest "${TMP}/out-server"
expect_file "hydrate: server filter keeps other files" "${TMP}/out-server/sub/b.txt"
expect_no_file "hydrate: server-excluded path not copied" "${TMP}/out-server/skipped.txt"
unset FILTER_SERVER_SYNC
rm -f "${FILTER_DIR}/server-exclude.txt"

# --- --progress: rclone's -P only on a TTY ----------------------------------
# Drive the shared argv builder directly. Command substitution gives it a
# non-TTY stdout, so the result does not depend on how the suite is run.
# rclone.sh is already loaded by env.sh (via lib/sciebo.sh).
# shellcheck disable=SC1090,SC1091
source "${PROJ}/lib/commands/hydrate.sh"
hydrate_progress_args() {
  local quiet="$1"
  HYDRATE_ARGS=(copy remote: /tmp/dest)
  progress_append_args HYDRATE_ARGS "$quiet"
  printf '%s' "${HYDRATE_ARGS[*]}"
}
# shellcheck disable=SC2034  # read by the sourced progress helper
OPT_progress=""
expect_not_contains "hydrate: no progress without the flag" "$(hydrate_progress_args 0)" "-P"
# shellcheck disable=SC2034  # read by the sourced progress helper
OPT_progress=1
expect_not_contains "hydrate: non-tty progress adds no -P" "$(hydrate_progress_args 0)" "-P"
# shellcheck disable=SC2329  # invoked by progress_append_args
progress_stdout_tty() { return 0; }
expect_contains "hydrate: tty progress appended" "$(hydrate_progress_args 0)" "-P"
expect_not_contains "hydrate: quiet suppresses progress" "$(hydrate_progress_args 1)" "-P"
# shellcheck disable=SC2034  # read by the sourced progress helper
OUTPUT_JSON=true
expect_not_contains "hydrate: json suppresses progress" "$(hydrate_progress_args 0)" "-P"
# shellcheck disable=SC2034  # read by the sourced progress helper
OUTPUT_JSON=false
# shellcheck disable=SC2034  # test fixture reset
OPT_progress=""

# A remote path that does not exist fails; unsafe paths fail validation.
expect_cli "hydrate: missing remote path rc 1" 1 run_cli hydrate missing
expect_cli "hydrate: unsafe path rc 1" 1 run_cli hydrate ../etc

finish
