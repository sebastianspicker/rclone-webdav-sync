#!/bin/bash
# watch.sh command module - run sync when local source directories change.
#
# Watched directories come from the manifest entries, optionally filtered
# by --only. A single watcher per profile is tracked in WATCH_DIR/watch.pid:
# the file records the pid and its `ps -o lstart=` value, and a record only
# counts as live while the shared pid_alive (lock.sh: kill -0 plus the
# matching start time) succeeds, so a recycled pid cannot keep a stale
# watcher alive.
#
# Backends: fswatch and inotifywait stream change events, poll scans each
# source against a marker under WATCH_DIR. Events are coalesced per source
# for --debounce seconds and a source is never synced more often than
# --interval seconds. Syncs are spawned as
# `bin/sciebo sync --apply --quiet --only NAME`, never run in-process, and
# the sync command owns the run lock itself.

# Elapsed-time bookkeeping uses the monotonic now_mono (BASH_MONOSECONDS) so a
# wall-clock jump cannot stall or spuriously fire the loop. The persisted
# last-run stamp and poll-marker epoch stay on EPOCHSECONDS and outlive the
# process; a poll check compares the marker's mtime against the tree, the
# throttle compares the stamp against the wall clock. Neither forks `date`.

WATCH_RUN_INTERVAL=0
WATCH_RUN_DEBOUNCE=0
WATCH_RUN_REMOTE_INTERVAL=0
WATCH_RUN_BACKEND=""
WATCH_RUN_ONCE=false
WATCH_RUN_NOTIFY=false
WATCH_RUN_NO_NOTIFY=false
WATCH_RUN_QUIET=false
WATCH_SCAN_CHANGED=0
WATCH_PID_PATH=""
WATCH_BACKEND_PID=""
WATCH_CHECK_PID=""
WATCH_FIFO=""
WATCH_RECORDED_PID=""
WATCH_RECORDED_START=""
WATCH_SRC_NAMES=()
WATCH_SRC_LOCALS=()
WATCH_PENDING=()

usage_watch() {
  usage_emit <<'EOF'
Usage: sciebo watch [options]

Watch the local directories of the configured sources and run
`sciebo sync --apply --quiet --only NAME` when one changes. One watcher
per profile is tracked in state/watch/watch.pid.

Options:
  --interval N         poll interval and minimum seconds between two runs
                       of the same source (default WATCH_INTERVAL)
  --debounce N         coalesce change events for N seconds
                       (default WATCH_DEBOUNCE)
  --only NAME          watch only this source; repeatable
  --remote-interval N  check the remote every N seconds and notify when it
                       differs; 0 disables (default WATCH_REMOTE_INTERVAL)
  --backend BACKEND    auto, fswatch, inotify, or poll (default WATCH_BACKEND)
  --once               run one detection cycle, sync affected sources, exit
  --notify             allow desktop notifications
  --no-notify          disable desktop notifications even when NOTIFY=1
                       (mutually exclusive with --notify)
  --quiet              only warnings and errors
  -h, --help           show this help

A source whose local directory is missing is skipped with a warning, and
runs are skipped while `sciebo pause` is active.
EOF
}

# watch_note TEXT - informational output, suppressed by --quiet.
watch_note() {
  [[ "$WATCH_RUN_QUIET" == true ]] || printf '%s\n' "$*"
  return 0
}

# watch_resolve_backend REQUESTED - print fswatch, inotify, or poll.
watch_resolve_backend() {
  local requested="${1:-auto}"
  case "$requested" in
    auto)
      if have fswatch; then
        printf 'fswatch'
      elif have inotifywait; then
        printf 'inotify'
      else
        printf 'poll'
      fi
      ;;
    fswatch)
      have fswatch || die "watch: backend 'fswatch' requested but fswatch is not installed"
      printf 'fswatch'
      ;;
    inotify)
      have inotifywait || die "watch: backend 'inotify' requested but inotifywait is not installed"
      printf 'inotify'
      ;;
    poll) printf 'poll' ;;
    *) die "watch: unknown backend '$(printable "$requested")'" ;;
  esac
  return 0
}

# watch_collect_sources ONLY_LIST - fill the source tables from the
# manifest, filtered by the newline-separated ONLY_LIST (empty = all).
# Invalid entries and missing local directories are skipped with a warning;
# an --only name that does not exist in the manifest is fatal.
watch_collect_sources() {
  local only_list="${1:-}" line=""
  WATCH_SRC_NAMES=()
  WATCH_SRC_LOCALS=()
  WATCH_PENDING=()
  if [[ -n "$only_list" ]]; then
    while IFS= read -r only; do
      [[ -n "$only" ]] || continue
      manifest_has_name "$only" ||
        die "watch: $(unknown_source_prefix "$only"). Available: $(trim "$(printf '%s' "$MANIFEST_NAMES" | tr '\n' ' ')")"
    done <<<"$only_list"
  fi
  while IFS= read -r line; do
    if ! manifest_parse_line "$line"; then
      warn "watch: ignoring invalid source line: ${ENTRY_ERROR}"
      continue
    fi
    if [[ -n "$only_list" ]]; then
      _manifest_membership "$ENTRY_NAME" "$only_list" || continue
    fi
    if [[ ! -d "$ENTRY_LOCAL" ]]; then
      warn "watch: skipping '${ENTRY_NAME}' (local directory missing: ${ENTRY_LOCAL})"
      continue
    fi
    WATCH_SRC_NAMES[${#WATCH_SRC_NAMES[@]}]="$ENTRY_NAME"
    WATCH_SRC_LOCALS[${#WATCH_SRC_LOCALS[@]}]=${ strip_trailing_slashes "$ENTRY_LOCAL";}
    WATCH_PENDING[${#WATCH_PENDING[@]}]=""
  done < <(manifest_lines)
  [[ "${#WATCH_SRC_NAMES[@]}" -gt 0 ]] ||
    die "watch: no sources to watch (add pairs with '${CLI_NAME} folders add' or fix the local paths)"
  return 0
}

# watch_source_index_for_path PATH - print the index of the source whose
# local directory contains PATH; rc 1 when no source matches.
watch_source_index_for_path() {
  local path="${1:-}" i=0 dir=""
  while [[ "$i" -lt "${#WATCH_SRC_LOCALS[@]}" ]]; do
    dir="${WATCH_SRC_LOCALS[$i]}"
    if [[ "$path" == "$dir" || "$path" == "$dir"/* ]]; then
      printf '%s' "$i"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

# watch_stamp_file NAME / watch_marker_file NAME - per-source runtime files
# under WATCH_DIR: the last-run stamp (min-interval throttle) and the poll
# scan marker (newest-mtime comparison). Both only print; sanitize_name_into
# keeps the per-tick call fork-free (the old `$(sanitize_name ...)` forked a
# subshell per call).
watch_stamp_file() {
  local name=""
  sanitize_name_into name "${1:-}"
  printf '%s/last-%s' "$WATCH_DIR" "$name"
}

watch_marker_file() {
  local name=""
  sanitize_name_into name "${1:-}"
  printf '%s/poll-%s' "$WATCH_DIR" "$name"
}

# watch_last_run NAME - print the epoch of NAME's last sync, 0 when unknown.
watch_last_run() {
  local stamp="" path=""
  path=${ watch_stamp_file "$1";}
  if [[ -r "$path" ]]; then
    stamp="$(<"$path")"
  fi
  case "$stamp" in
    '' | *[!0-9]*) stamp=0 ;;
  esac
  printf '%s' "$stamp"
}

# watch_last_run_set NAME - record "now" as NAME's last sync. Best effort:
# a state-directory problem only delays the interval throttle.
watch_last_run_set() {
  local path=""
  mkdir -p "$WATCH_DIR" 2>/dev/null || return 0
  path=${ watch_stamp_file "$1";}
  printf '%s\n' "$EPOCHSECONDS" >"$path" 2>/dev/null || true
  return 0
}

# watch_dir_changed DIR MARKER - true (0) when DIR holds a path newer than
# MARKER's mtime (missing marker = everything is new). watch_scan_source
# rewrites the marker after every scan, so its mtime is the last scan and
# one portable `find -newer` walk answers the check on BSD and GNU find.
watch_dir_changed() {
  local dir="$1" marker="$2" out=""
  [[ -f "$marker" ]] || return 0
  out="$(find "$dir" -newer "$marker" -print -quit 2>/dev/null)" || true
  if [[ -n "$out" ]]; then
    return 0
  fi
  return 1
}

# watch_scan_source INDEX - compare the source's newest mtimes against its
# marker, refresh the marker (the rewrite also stamps the mtime the next
# check compares against), and return 0 when something changed.
watch_scan_source() {
  local name="${WATCH_SRC_NAMES[$1]:-}" dir="${WATCH_SRC_LOCALS[$1]:-}"
  local marker="" changed=1
  # Forkless capture: watch_marker_file only prints.
  marker=${ watch_marker_file "$name";}
  if watch_dir_changed "$dir" "$marker"; then
    changed=0
  fi
  printf '%s\n' "$EPOCHSECONDS" >"$marker" 2>/dev/null || true
  return "$changed"
}

# watch_scan_all - poll every source; changed sources get a pending
# timestamp (the debounce clock starts at the first event). The state
# directory is created once per tick here rather than inside every
# watch_scan_source call.
watch_scan_all() {
  local i=0 now=""
  WATCH_SCAN_CHANGED=0
  now=${ now_mono;}
  mkdir -p "$WATCH_DIR" 2>/dev/null || true
  i=0
  while [[ "$i" -lt "${#WATCH_SRC_NAMES[@]}" ]]; do
    if watch_scan_source "$i"; then
      WATCH_SCAN_CHANGED=$((WATCH_SCAN_CHANGED + 1))
      WATCH_PENDING[i]="$now"
    fi
    i=$((i + 1))
  done
  return 0
}

# watch_run_sync NAME - spawn one sync for NAME. Never in-process, never
# with the run lock held here; a paused watcher skips with a warning.
watch_run_sync() {
  local name="${1:-}" rc=0
  if type pause_active >/dev/null 2>&1 && pause_active; then
    warn "watch: sync is paused; not syncing '${name}' (run '${CLI_NAME} resume')"
    return 0
  fi
  watch_note "watch: ${name} changed, syncing"
  if [[ "$WATCH_RUN_QUIET" == true ]]; then
    "${PROJECT_DIR}/bin/sciebo" sync --apply --quiet --only "$name" >/dev/null 2>&1 || rc=$?
  else
    "${PROJECT_DIR}/bin/sciebo" sync --apply --quiet --only "$name" || rc=$?
  fi
  [[ "$rc" -eq 0 ]] || warn "watch: sync for '${name}' failed (exit ${rc})"
  watch_last_run_set "$name"
  return 0
}

# watch_notify TITLE MESSAGE - desktop notification through notify_send;
# --notify forces it on and --no-notify forces it off, otherwise NOTIFY must
# already be enabled.
watch_notify() {
  local saved="${NOTIFY:-0}"
  if [[ "$WATCH_RUN_NO_NOTIFY" == true ]]; then
    NOTIFY=0
  elif [[ "$WATCH_RUN_NOTIFY" == true ]]; then
    NOTIFY=1
  fi
  if type notify_send >/dev/null 2>&1; then
    notify_send "${1:-}" "${2:-}" || true
  fi
  NOTIFY="$saved"
  return 0
}

# watch_remote_poll - dry-run the configured sources and notify when the
# remote differs. Differences are read from the fresh dry-run logs: the
# "Skipped ... as --dry-run is set" plan lines mean there is work to do. A
# non-zero exit status is a real check failure (a missing source, a failed
# transfer guard), not a difference, and is reported as such. No transfers
# happen here.
watch_remote_poll() {
  local probe="${WATCH_DIR}/remote-poll.marker" rc=0 changed=0 hit=""
  mkdir -p "$WATCH_DIR" 2>/dev/null || true
  : >"$probe" 2>/dev/null || true
  WATCH_CHECK_PID=""
  "${PROJECT_DIR}/bin/sciebo" check --quiet >/dev/null 2>&1 &
  WATCH_CHECK_PID=$!
  wait "$WATCH_CHECK_PID" || rc=$?
  WATCH_CHECK_PID=""
  # One walk over the fresh dry-run logs: grep -q per candidate stops at the
  # first match and -print -quit ends the search there, so a path in the
  # output means changed and an empty result means unchanged (or no logs).
  hit="$(find "${LOG_DIR:-}" -maxdepth 1 -type f -name '*-dryrun.log' -newer "$probe" \
    -exec grep -q 'as --dry-run is set' {} \; -print -quit 2>/dev/null)" || true
  if [[ -n "$hit" ]]; then
    changed=1
  fi
  if [[ "$rc" -ne 0 ]]; then
    watch_notify "sciebo watch" "remote check failed; run '${CLI_NAME} status' for details"
  elif [[ "$changed" -eq 1 ]]; then
    watch_notify "sciebo watch" "remote differences detected; run '${CLI_NAME} sync'"
  fi
  return 0
}

# --- single-watcher pid file -------------------------------------------------

# watch_pid_read - parse WATCH_PID_PATH into WATCH_RECORDED_PID and
# WATCH_RECORDED_START; rc 1 when the file is missing or unreadable.
watch_pid_read() {
  WATCH_RECORDED_PID=""
  WATCH_RECORDED_START=""
  [[ -f "$WATCH_PID_PATH" && -r "$WATCH_PID_PATH" ]] || return 1
  {
    IFS= read -r WATCH_RECORDED_PID
    IFS= read -r WATCH_RECORDED_START
  } <"$WATCH_PID_PATH" || true
  return 0
}

# watch_pid_guard - die when the recorded watcher is live; remove a stale
# record so the caller can take over. Liveness (kill -0 plus the recorded
# start time, the pid-recycling guard) is lock.sh's shared pid_alive; the
# record format written by watch_pid_claim is unchanged.
watch_pid_guard() {
  local pid="" started=""
  watch_pid_read || return 0
  pid="$WATCH_RECORDED_PID"
  started="$WATCH_RECORDED_START"
  if pid_alive "$pid" "$started"; then
    die "watch: a watcher is already running (pid ${pid})"
  fi
  warn "watch: removing stale watcher record (pid ${pid:-unknown})"
  rm -f "$WATCH_PID_PATH" 2>/dev/null || true
  return 0
}

# watch_pid_claim - guard, then record this process (pid + lstart).
watch_pid_claim() {
  local started=""
  watch_pid_guard
  mkdir -p "$WATCH_DIR" 2>/dev/null || die "watch: cannot create ${WATCH_DIR}"
  started="$(ps -ww -p "$$" -o lstart= 2>/dev/null | tr -s ' ')"
  # Atomic write: a concurrent watcher must never read a truncated record
  # and take over a live watcher's claim.
  printf '%s\n%s\n' "$$" "$started" | atomic_write "$WATCH_PID_PATH" 600 ||
    die "watch: cannot write ${WATCH_PID_PATH}"
  return 0
}

# watch_pid_release - remove the record only when it belongs to this process.
watch_pid_release() {
  local pid=""
  [[ -n "$WATCH_PID_PATH" ]] || return 0
  IFS= read -r pid <"$WATCH_PID_PATH" 2>/dev/null || true
  if [[ "$pid" == "$$" ]]; then
    rm -f "$WATCH_PID_PATH" 2>/dev/null || true
  fi
  return 0
}

# --- streaming and poll loops ------------------------------------------------

# watch_start_backend BACKEND - exec the streaming backend; the caller's
# background subshell becomes the backend process.
watch_start_backend() {
  local backend="$1" i=0 dirs=()
  while [[ "$i" -lt "${#WATCH_SRC_LOCALS[@]}" ]]; do
    dirs[${#dirs[@]}]="${WATCH_SRC_LOCALS[$i]}"
    i=$((i + 1))
  done
  case "$backend" in
    fswatch)
      exec fswatch -r -l "$WATCH_RUN_DEBOUNCE" \
        --event Created --event Updated --event Removed --event Renamed \
        --event MovedFrom --event MovedTo "${dirs[@]}"
      ;;
    inotify)
      exec inotifywait -m -r -q -e modify,create,delete,move \
        --format '%w%f' "${dirs[@]}"
      ;;
  esac
}

# watch_handle_event PATH - start the debounce clock for PATH's source when
# no event for that source is pending yet.
watch_handle_event() {
  local path="${1:-}" index=""
  [[ -n "$path" ]] || return 0
  # Forkless capture keeps rc 1 (no source matches) exactly like the old
  # `index="$(...)"` assignment: partial output is kept, the rc bails out.
  index=${ watch_source_index_for_path "$path";} || return 0
  [[ -n "${WATCH_PENDING[$index]:-}" ]] || WATCH_PENDING[index]=${ now_mono;}
  return 0
}

# watch_flush_due NOW_MONO NOW_EPOCH - run sources whose debounce window
# closed and whose min-interval window is open. Debounce is measured on the
# monotonic clock; the min-interval compares the persisted wall-clock
# last-run stamp against NOW_EPOCH.
watch_flush_due() {
  local now_mono="$1" now_epoch="$2" i=0 stamp="" last="" name=""
  i=0
  while [[ "$i" -lt "${#WATCH_SRC_NAMES[@]}" ]]; do
    stamp="${WATCH_PENDING[$i]:-}"
    if [[ -n "$stamp" ]] && [[ $((now_mono - stamp)) -ge "$WATCH_RUN_DEBOUNCE" ]]; then
      name="${WATCH_SRC_NAMES[$i]}"
      # Forkless capture: watch_last_run only prints (its stamp read is
      # $(<file), which does not fork either).
      last=${ watch_last_run "$name";}
      if [[ $((now_epoch - last)) -ge "$WATCH_RUN_INTERVAL" ]]; then
        WATCH_PENDING[i]=""
        watch_run_sync "$name"
      fi
    fi
    i=$((i + 1))
  done
  return 0
}

# watch_loop - stream events (or poll on a timer), flush due sources, and
# poll the remote when a remote interval is configured.
watch_loop() {
  local backend="$WATCH_RUN_BACKEND" fifo="" line="" tick_fifo=""
  local now=0 now_epoch_val=0 next_scan=0 next_remote=0
  WATCH_BACKEND_PID=""
  if [[ "$backend" != "poll" ]]; then
    fifo="${WATCH_DIR}/events.$$"
    rm -f "$fifo" 2>/dev/null || true
    mkfifo "$fifo" || die "watch: cannot create event pipe ${fifo}"
    WATCH_FIFO="$fifo"
    watch_start_backend "$backend" >"$fifo" 2>/dev/null &
    WATCH_BACKEND_PID=$!
    exec 3<"$fifo" || die "watch: cannot open event pipe ${fifo}"
    rm -f "$fifo" 2>/dev/null || true
  else
    # A read-write self-pipe gives the poll loop a forkless one-second tick:
    # `read -t 1` times out with no writer, so no `sleep` process is spawned
    # once per second. The path is unlinked immediately; the open fd keeps it
    # alive.
    tick_fifo="${WATCH_DIR}/tick.$$"
    rm -f "$tick_fifo" 2>/dev/null || true
    mkfifo "$tick_fifo" || die "watch: cannot create tick pipe ${tick_fifo}"
    exec 4<>"$tick_fifo" || die "watch: cannot open tick pipe ${tick_fifo}"
    rm -f "$tick_fifo" 2>/dev/null || true
  fi
  now=${ now_mono;}
  next_scan="$now"
  next_remote=0
  [[ "$WATCH_RUN_REMOTE_INTERVAL" -le 0 ]] || next_remote=$((now + WATCH_RUN_REMOTE_INTERVAL))
  while :; do
    if [[ -n "$WATCH_BACKEND_PID" ]] && ! pid_alive "$WATCH_BACKEND_PID"; then
      warn "watch: ${backend} backend stopped; exiting"
      break
    fi
    line=""
    if [[ -n "$WATCH_BACKEND_PID" ]]; then
      IFS= read -r -t 1 line <&3 || true
      if [[ -n "$line" ]]; then
        watch_handle_event "$line"
      fi
    else
      IFS= read -r -t 1 _ <&4 || true
    fi
    now=${ now_mono;}
    now_epoch_val=${ now_epoch;}
    if [[ "$backend" == "poll" && "$now" -ge "$next_scan" ]]; then
      watch_scan_all
      next_scan=$((now + WATCH_RUN_INTERVAL))
    fi
    watch_flush_due "$now" "$now_epoch_val"
    if [[ "$WATCH_RUN_REMOTE_INTERVAL" -gt 0 && "$now" -ge "$next_remote" ]]; then
      watch_remote_poll
      next_remote=$((now + WATCH_RUN_REMOTE_INTERVAL))
    fi
  done
  return 0
}

# watch_once - one detection cycle: scan every source and sync the changed
# ones immediately, then report the summary.
watch_once() {
  local i=0 changed=0 count="${#WATCH_SRC_NAMES[@]}"
  watch_scan_all
  changed="$WATCH_SCAN_CHANGED"
  i=0
  while [[ "$i" -lt "$count" ]]; do
    if [[ -n "${WATCH_PENDING[$i]:-}" ]]; then
      WATCH_PENDING[i]=""
      watch_run_sync "${WATCH_SRC_NAMES[$i]}"
    fi
    i=$((i + 1))
  done
  watch_note "watch: once: ${count} source(s) checked, ${changed} changed"
  return 0
}

# --- signals -----------------------------------------------------------------

watch_kill_children() {
  if [[ -n "$WATCH_CHECK_PID" ]]; then
    kill -TERM "$WATCH_CHECK_PID" 2>/dev/null || true
  fi
  if [[ -n "$WATCH_BACKEND_PID" ]]; then
    kill -TERM "$WATCH_BACKEND_PID" 2>/dev/null || true
  fi
  return 0
}

watch_on_signal() {
  local status=130
  [[ "$1" != "TERM" ]] || status=143
  watch_kill_children
  watch_pid_release
  rm -f "$WATCH_FIFO" 2>/dev/null || true
  if type release_lock >/dev/null 2>&1; then release_lock || true; fi
  exit "$status"
}

watch_on_exit() {
  watch_kill_children
  watch_pid_release
  rm -f "$WATCH_FIFO" 2>/dev/null || true
  if type release_lock >/dev/null 2>&1; then release_lock || true; fi
  # The command overrides the entrypoint's EXIT trap, so it must clean up
  # the registered temp files itself.
  if type sciebo_temp_cleanup >/dev/null 2>&1; then sciebo_temp_cleanup || true; fi
  return 0
}

cmd_watch() {
  local interval="" debounce="" remote_interval="" backend="" only_list=""
  opt_begin "interval:s debounce:s only:S remote-interval:s backend:s once:b notify:b no-notify:b quiet:b" watch "" "$@"
  [[ -z "$OPT_EXTRA" ]] || usage_error watch "unknown argument: ${OPT_EXTRA%%$'\n'*}"
  # Run dependencies load after the help/usage exits, so
  # `sciebo watch --help` parses none of them: now_mono times the loop
  # (duration.sh), the run gate checks the pause marker, --notify delivers
  # through notify.sh (both before their `type` probes so neither silently
  # skips), the source walk goes through the manifest, and the pid guard
  # (plus the backend liveness check) uses lock.sh's shared pid_alive.
  sciebo_require_module duration now_mono
  sciebo_require_module pause pause_active
  sciebo_require_module notify notify_send
  sciebo_require_module manifest manifest_each
  sciebo_require_module lock pid_alive

  # The option values are validated once below, after load_settings fills
  # the defaults. The three integer checks go through opt_require_uint with
  # their exact value-bearing wording as MSG - "--interval must be a positive
  # integer (got 'x')" - which the 6th argument carries verbatim.
  interval="${OPT_interval:-}"
  debounce="${OPT_debounce:-}"
  remote_interval="${OPT_remote_interval:-}"
  backend="${OPT_backend:-}"

  WATCH_RUN_ONCE=false
  opt_into WATCH_RUN_ONCE once
  if [[ -n "${OPT_notify_SET:-}" && -n "${OPT_no_notify_SET:-}" ]]; then
    usage_error watch "--notify and --no-notify are mutually exclusive"
  fi
  WATCH_RUN_NOTIFY=false
  opt_into WATCH_RUN_NOTIFY notify
  WATCH_RUN_NO_NOTIFY=false
  opt_into WATCH_RUN_NO_NOTIFY no_notify
  WATCH_RUN_QUIET=false
  opt_into WATCH_RUN_QUIET quiet
  only_list="${OPT_only:-}"

  load_settings
  [[ -n "$interval" ]] || interval="$WATCH_INTERVAL"
  opt_require_uint watch --interval "$interval" 1 "" "--interval must be a positive integer (got '${interval}')"
  WATCH_RUN_INTERVAL=$((10#$interval))
  [[ -n "$debounce" ]] || debounce="$WATCH_DEBOUNCE"
  opt_require_uint watch --debounce "$debounce" 0 "" "--debounce must be a non-negative integer (got '${debounce}')"
  WATCH_RUN_DEBOUNCE=$((10#$debounce))
  [[ -n "$remote_interval" ]] || remote_interval="$WATCH_REMOTE_INTERVAL"
  opt_require_uint watch --remote-interval "$remote_interval" 0 "" "--remote-interval must be a non-negative integer (got '${remote_interval}')"
  WATCH_RUN_REMOTE_INTERVAL=$((10#$remote_interval))
  [[ -n "$backend" ]] || backend="$WATCH_BACKEND"
  case "$backend" in
    auto | fswatch | inotify | poll) ;;
    *) usage_error watch "--backend must be one of auto, fswatch, inotify, poll (got '${backend}')" ;;
  esac

  require_remote
  manifest_index_load
  WATCH_PID_PATH="${WATCH_DIR}/watch.pid"
  WATCH_RUN_BACKEND="$(watch_resolve_backend "$backend")"
  watch_collect_sources "$only_list"

  trap 'watch_on_exit' EXIT
  trap 'watch_on_signal INT' INT
  trap 'watch_on_signal TERM' TERM

  if [[ "$WATCH_RUN_ONCE" == true ]]; then
    watch_pid_guard
    watch_once
    return 0
  fi
  watch_pid_claim
  watch_note "watch: watching ${#WATCH_SRC_NAMES[@]} source(s) every ${WATCH_RUN_INTERVAL}s (${WATCH_RUN_BACKEND})"
  watch_loop
  return 0
}
