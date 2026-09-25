#!/bin/bash
# quota.sh - remote size and server quota, probed once per process and
# shared by sync (the download/big-folder size guards) and doctor (the
# quota check and the big-folder scan). Split out of lib/commands/sync.sh:
# neither remote size nor quota is sync-specific state.

# Per-process cache of successful `rclone size` lookups keyed by the remote
# spec (B9). The download and big-folder guards for the same spec, and
# repeated or overlapping entries, reuse one result within a run; entries are
# only created when a guard is opted in and a size is actually fetched.
declare -gA REMOTE_SIZE_CACHE=()
# Out-param of remote_size_lookup: the bytes for the requested spec.
REMOTE_SIZE_BYTES=""

# remote_size_lookup SPEC - set REMOTE_SIZE_BYTES to the remote's total size
# in bytes, reusing the per-process REMOTE_SIZE_CACHE when SPEC was already
# measured. rc 1 when the size cannot be read or parsed; a failed lookup is
# not cached, so a later guard can still retry it.
remote_size_lookup() {
  local spec="$1" bytes=""
  REMOTE_SIZE_BYTES=""
  if [[ -n "${REMOTE_SIZE_CACHE[$spec]+cached}" ]]; then
    REMOTE_SIZE_BYTES="${REMOTE_SIZE_CACHE[$spec]}"
    return 0
  fi
  bytes="$(rclone_remote_size "$spec")" || return 1
  [[ -n "$bytes" ]] || return 1
  REMOTE_SIZE_CACHE[$spec]="$bytes"
  REMOTE_SIZE_BYTES="$bytes"
  return 0
}

# remote_size SPEC - fill REMOTE_SIZE with the remote's total size in bytes
# from one cached `rclone size --json`; rc 1 when the size cannot be read or
# parsed. The result is cached per spec, so the download and big-folder
# guards (and repeated/overlapping entries) share one lookup. REMOTE_SIZE
# itself is read by sync.sh's download/big-folder guards, not here.
remote_size() {
  local spec="$1"
  # shellcheck disable=SC2034  # out-param read by sync.sh's size guards
  REMOTE_SIZE=""
  remote_size_lookup "$spec" || return 1
  # shellcheck disable=SC2034  # out-param read by sync.sh's size guards
  REMOTE_SIZE="$REMOTE_SIZE_BYTES"
  return 0
}

# quota_about_number JSON FIELD - print the top-level numeric FIELD from an
# `rclone about --json` document (total, used); nothing when it is absent.
# One awk pass, no jq, like rclone_size_bytes.
quota_about_number() {
  printf '%s\n' "${1:-}" | LC_ALL=C awk -v field="${2:-}" '
    match($0, "\"" field "\"[ \t]*:[ \t]*[0-9]+") {
      value = substr($0, RSTART, RLENGTH)
      sub(/.*:[ \t]*/, "", value)
      print value
      exit
    }
  '
}

# Server quota probe state for QUOTA_WARN_PERCENT: ""=not probed yet,
# "ok"/"error" after one attempt, plus the parsed byte counts. Cached for
# the run, so several entries (or doctor's checks) never re-probe the quota.
QUOTA_STATUS=""
QUOTA_TOTAL=""
QUOTA_USED=""

# quota_probe - read the server quota once with `rclone about --json` and
# set QUOTA_TOTAL/QUOTA_USED to the parsed byte counts. Returns 0 on
# success, 1 when the probe or parse fails; the first attempt is cached
# (QUOTA_STATUS), so a run never probes twice and never fails on a quota
# error.
quota_probe() {
  local json=""
  case "$QUOTA_STATUS" in
    ok) return 0 ;;
    error) return 1 ;;
  esac
  QUOTA_STATUS="error"
  json="$(rclone_cmd about --json "${RCLONE_REMOTE}:" 2>/dev/null)" || json=""
  QUOTA_TOTAL="$(quota_about_number "$json" total)"
  QUOTA_USED="$(quota_about_number "$json" used)"
  case "$QUOTA_TOTAL" in
    '' | *[!0-9]*) return 1 ;;
  esac
  case "$QUOTA_USED" in
    '' | *[!0-9]*) return 1 ;;
  esac
  [[ "$QUOTA_TOTAL" -gt 0 ]] || return 1
  QUOTA_STATUS="ok"
  return 0
}

# quota_used_percent - print the floor percentage of quota used from one
# cached probe; rc 1 when the quota cannot be read. Shared by sync and
# doctor.
quota_used_percent() {
  quota_probe || return 1
  printf '%s' "$((10#$QUOTA_USED * 100 / 10#$QUOTA_TOTAL))"
}

# quota_prime STATUS [TOTAL USED] - seed the memoized probe from a result a
# caller already fetched itself (doctor's shared runtime/quota probe
# combines the `rclone about` call with its own PASS/WARN report), so a
# later quota_probe/quota_used_percent call reuses it instead of probing
# again. STATUS is "ok" or "error"; TOTAL/USED are only meaningful when
# STATUS is "ok".
quota_prime() {
  QUOTA_STATUS="$1"
  QUOTA_TOTAL="${2:-}"
  QUOTA_USED="${3:-}"
}
