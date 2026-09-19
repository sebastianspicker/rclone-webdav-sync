#!/bin/bash
# lock.sh - single-run lock shared by sync and cleanup.
# The lock is a directory that holds a pid file. Acquisition is atomic
# (mkdir). A lock whose pid is gone - or whose pid was recycled by an
# unrelated process - is moved aside before being removed, so a concurrent
# takeover cannot delete a freshly created lock. Release only removes the
# lock when the recorded pid is this process.

LOCK_HELD=""

_lock_pid() { cat "$1/pid" 2>/dev/null || true; }
_lock_write_pid() { printf '%s\n' "$$" >"$1/pid"; }

# _lock_pid_alive PID - true only when the pid is alive AND looks like this
# tool; a recycled pid must not keep a stale lock alive.
_lock_pid_alive() {
  local pid="$1" command_line=""
  kill -0 "$pid" 2>/dev/null || return 1
  command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  case "$command_line" in
    *bin/sciebo* | *scripts/sync.sh*) return 0 ;;
    *) return 1 ;;
  esac
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
  if [[ -n "$pid" ]] && _lock_pid_alive "$pid"; then
    die "Another sync run is active (pid ${pid}). Remove ${lock} if this is wrong."
  fi
  reason="no pid recorded"
  [[ -z "$pid" ]] || reason="pid ${pid} is gone"
  warn "Removing stale lock ${lock} (${reason})"
  stale="${lock}.stale.$$"
  mv "$lock" "$stale" 2>/dev/null || die "Another sync run just started; retry in a moment"
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
