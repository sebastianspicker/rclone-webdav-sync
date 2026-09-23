#!/bin/bash
# lock.sh - single-run lock shared by sync and cleanup.
# The lock is a directory that holds a pid file and a start-time file.
# Acquisition is atomic (mkdir). A lock whose pid is gone - or whose pid
# was recycled by an unrelated process - is moved aside before being
# removed, so a concurrent takeover cannot delete a freshly created lock.
# Release only removes the lock when the recorded pid is this process.

LOCK_HELD=""

# _lock_pid LOCK - print LOCK's recorded pid, or nothing when the pid file
# is missing or unreadable. Fork removal: $(<file) replaces the cat fork;
# the [[ -r ]] guard keeps the missing-file probe silent and empty exactly
# like `cat ... 2>/dev/null || true`, and the || covers the race where the
# file disappears between the check and the read.
_lock_pid() {
  local file="$1/pid" content=""
  if [[ -r "$file" ]]; then
    content="$(<"$file")" || content=""
  fi
  printf '%s' "$content"
}
# _lock_start LOCK - LOCK's recorded start time, with the same missing-file
# behavior as _lock_pid (fork-free $(<file) read behind a [[ -r ]] guard).
_lock_start() {
  local file="$1/start" content=""
  if [[ -r "$file" ]]; then
    content="$(<"$file")" || content=""
  fi
  printf '%s' "$content"
}
# -ww keeps the full command line and start time even when the terminal
# width would otherwise truncate them (launchd logs are narrow).
_lock_command() { ps -ww -p "$1" -o command= 2>/dev/null || true; }
_lock_proc_start() { ps -ww -p "$1" -o lstart= 2>/dev/null || true; }
_lock_write_pid() {
  printf '%s\n' "$$" >"$1/pid"
  _lock_proc_start "$$" >"$1/start"
}

# pid_alive PID [START] - true while PID is alive and, when START is passed,
# while its `ps -ww -p PID -o lstart=` start time still matches START - the
# pid-recycling guard shared by watch, doctor, and the lock. PID must be a
# non-empty run of digits. Contract per arity:
#   pid_alive PID          alive iff kill -0 succeeds.
#   pid_alive PID START    also requires a non-empty ps start time equal to
#                          START after squeezing whitespace runs on both
#                          sides (tr -s ' ' semantics): a raw `ps -o lstart=`
#                          recorded by lock.sh and watch's pre-squeezed
#                          record then compare equal for the same pid, and a
#                          recycled pid's differing time does not. An empty
#                          ps result - a pid with no start record, or one
#                          that dies between kill -0 and ps - is NOT alive:
#                          therefore fails too.
pid_alive() {
  local pid="${1:-}" started="${2-}" current=""
  case "$pid" in
    '' | *[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null || return 1
  [[ $# -ge 2 ]] || return 0
  current="$(_lock_proc_start "$pid")"
  while [[ "$current" == *"  "* ]]; do current="${current//  / }"; done
  while [[ "$started" == *"  "* ]]; do started="${started//  / }"; done
  [[ -n "$current" && "$started" == "$current" ]]
}

# _lock_pid_alive PID [LOCK] - true only when the pid is alive, looks like
# this tool, and - when LOCK records a start time - still has that start
# time; a recycled pid must not keep a stale lock alive. Locks without a
# start file (older versions) fall back to the command-line match. The
# start-time half delegates to the shared pid_alive; the command-line match
# (*bin/sciebo* / *scripts/sync.sh*) stays here because pid_alive is the
# generic guard and must not require this tool's argv.
_lock_pid_alive() {
  local pid="$1" lock="${2:-}" command_line="" started=""
  kill -0 "$pid" 2>/dev/null || return 1
  command_line="$(_lock_command "$pid")"
  case "$command_line" in
    *bin/sciebo* | *scripts/sync.sh*) ;;
    *) return 1 ;;
  esac
  [[ -n "$lock" ]] || return 0
  started="$(_lock_start "$lock")"
  [[ -n "$started" ]] || return 0
  pid_alive "$pid" "$started"
}

# acquire_lock - reentrant within one process: the outermost acquisition
# wins and the EXIT trap in bin/sciebo releases it.
acquire_lock() {
  [[ -z "$LOCK_HELD" ]] || return 0
  ensure_state_dirs
  local lock="${LOCK_DIR}/sync.lock" pid stale reason
  if mkdir "$lock" 2>/dev/null; then
    _lock_write_pid "$lock"
    LOCK_HELD="$lock"
    return 0
  fi
  pid="$(_lock_pid "$lock")"
  # The owner writes its pid right after mkdir; wait out that tiny window so
  # a fresh lock is not mistaken for a pid-less stale one.
  local tries=0
  while [[ -z "$pid" && "$tries" -lt 10 ]]; do
    sleep 0.05 2>/dev/null || sleep 1
    pid="$(_lock_pid "$lock")"
    tries=$((tries + 1))
  done
  if [[ -n "$pid" ]] && _lock_pid_alive "$pid" "$lock"; then
    die "Another sync run is active (pid ${pid}). Remove ${lock} if this is wrong."
  fi
  reason="no pid recorded"
  [[ -z "$pid" ]] || reason="pid ${pid} is gone"
  warn "Removing stale lock ${lock} (${reason})"
  stale="${lock}.stale.$$"
  mv "$lock" "$stale" 2>/dev/null || die "Another sync run just started; retry in a moment"
  # Another process may have created a fresh lock between the liveness check
  # and the rename. What landed in $stale must be the same lock we just
  # checked, otherwise a concurrent takeover already started its run: put the
  # directory back untouched and let the caller retry.
  local moved=""
  moved="$(_lock_pid "$stale")"
  if [[ "$moved" != "$pid" ]] || { [[ -n "$moved" ]] && _lock_pid_alive "$moved" "$stale"; }; then
    mv "$stale" "$lock" 2>/dev/null || true
    die "Another sync run just started; retry in a moment"
  fi
  rm -rf "$stale"
  mkdir "$lock" 2>/dev/null || die "Another sync run just started; retry in a moment"
  _lock_write_pid "$lock"
  LOCK_HELD="$lock"
}

release_lock() {
  [[ -n "$LOCK_HELD" ]] || return 0
  local lock="$LOCK_HELD" pid released
  LOCK_HELD=""
  pid="$(_lock_pid "$lock")"
  if [[ "$pid" != "$$" ]]; then
    warn "Not releasing lock ${lock}: it is owned by pid ${pid:-unknown}"
    return 0
  fi
  released="${lock}.release.$$"
  if mv "$lock" "$released" 2>/dev/null; then
    rm -rf "$released"
  else
    warn "Not releasing lock ${lock}: it changed on disk"
  fi
}
