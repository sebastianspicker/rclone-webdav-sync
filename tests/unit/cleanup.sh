#!/usr/bin/env bash
# cleanup.sh - cleanup_age_minutes (lib/commands/cleanup.sh).
# Sourced setup lives in tests/unit/common.sh; run standalone with
# `bash tests/unit/cleanup.sh`.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# --- cleanup_age_minutes -------------------------------------------------
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/commands/cleanup.sh
source "${LIB_DIR}/commands/cleanup.sh"
while IFS='|' read -r name input want rc_want; do
  rc=0
  out="$(cleanup_age_minutes "$input" 2>/dev/null)" || rc=$?
  expect_rc "${name}: rc" "$rc" "$rc_want"
  [[ "$rc_want" -ne 0 ]] || expect_eq "$name" "$want" "$out"
done <<'EOF'
cleanup_age_minutes: seconds truncate to minutes|45s|0|0
cleanup_age_minutes: bare number is minutes|5|5|0
cleanup_age_minutes: minutes suffix|90m|90|0
cleanup_age_minutes: hours suffix|2h|120|0
cleanup_age_minutes: days suffix|1d|1440|0
cleanup_age_minutes: empty dies|||1
cleanup_age_minutes: unknown unit dies|5x||1
EOF

finish
