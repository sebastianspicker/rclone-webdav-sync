#!/usr/bin/env bash
# quota.sh - the shared quota probe and remote-size lookup
# (lib/sync/quota.sh): each is memoized for the run, so sync, doctor, and the
# folder picker share one `rclone about` call and one size lookup per path.
# Sourced setup lives in tests/unit/common.sh; run standalone with
# `bash tests/unit/quota.sh`.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# --- remote_size_lookup: one lookup per path per run ---------------------
QUOTA_UNIT_CALLS="${TMP}/quota-size-calls"
: >"$QUOTA_UNIT_CALLS"
# shellcheck disable=SC2329  # stub called by remote_size_lookup
rclone_remote_size() {
  printf '%s\n' "$1" >>"$QUOTA_UNIT_CALLS"
  case "$1" in
    remote:a) printf '1234' ;;
    remote:empty) printf '' ;;
    *) return 1 ;;
  esac
}
quota_unit_calls() { grep -c . "$QUOTA_UNIT_CALLS" || true; }

# shellcheck disable=SC2034  # reset of the cache remote_size_lookup reads
REMOTE_SIZE_CACHE=()
expect_ok "remote_size_lookup: first lookup rc 0" remote_size_lookup remote:a
expect_eq "remote_size_lookup: first lookup bytes" "1234" "$REMOTE_SIZE_BYTES"
expect_ok "remote_size_lookup: repeat lookup rc 0" remote_size_lookup remote:a
expect_eq "remote_size_lookup: repeat lookup bytes" "1234" "$REMOTE_SIZE_BYTES"
expect_eq "remote_size_lookup: repeat is served from the cache" "1" "$(quota_unit_calls)"
expect_err "remote_size_lookup: failed lookup rc 1" remote_size_lookup remote:missing
expect_eq "remote_size_lookup: failed lookup leaves no bytes" "" "$REMOTE_SIZE_BYTES"
expect_err "remote_size_lookup: failure is not cached" remote_size_lookup remote:missing
expect_err "remote_size_lookup: empty answer rc 1" remote_size_lookup remote:empty
expect_eq "remote_size_lookup: only uncached paths reach rclone" "4" "$(quota_unit_calls)"

# --- quota_probe: one `rclone about` per run, primed or probed ------------
QUOTA_UNIT_ABOUT="${TMP}/quota-about-calls"
: >"$QUOTA_UNIT_ABOUT"
QUOTA_UNIT_JSON='{"total": 1000, "used": 950, "free": 50}'
# shellcheck disable=SC2329  # stub called by quota_probe
rclone_cmd() {
  printf 'about\n' >>"$QUOTA_UNIT_ABOUT"
  printf '%s\n' "$QUOTA_UNIT_JSON"
}
RCLONE_REMOTE="${RCLONE_REMOTE:-remote}"
quota_prime "" "" ""
expect_eq "quota_used_percent: floor percentage" "95" "$(quota_used_percent)"
# $(...) above ran in a subshell, so its memo stayed there; probe in this
# shell to check that a second call reuses the first result.
: >"$QUOTA_UNIT_ABOUT"
quota_prime "" "" ""
quota_probe
quota_probe
expect_eq "quota_probe: memoized after the first call" "1" "$(grep -c . "$QUOTA_UNIT_ABOUT")"

quota_prime ok 200 50
: >"$QUOTA_UNIT_ABOUT"
expect_eq "quota_prime: seeded result is used" "25" "$(quota_used_percent)"
expect_eq "quota_prime: no probe after priming" "0" "$(grep -c . "$QUOTA_UNIT_ABOUT" || true)"

quota_prime error
expect_err "quota_prime: a primed error stays an error" quota_used_percent

QUOTA_UNIT_JSON='{"total": 0, "used": 0}'
quota_prime "" "" ""
expect_err "quota_probe: zero total is unreadable" quota_probe

finish
