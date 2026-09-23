#!/usr/bin/env bash
# features.sh - run every tests/features/*.sh in a fresh bash process.
# Each script is self-isolated (temp dir, stub curl) and reports through
# tests/harness.sh; this runner aggregates the exit status.
set -uo pipefail
FEATURES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/features"
status=0
for script in "${FEATURES_DIR}"/*.sh; do
  [[ -f "$script" ]] || continue
  [[ "$(basename "$script")" == "env.sh" ]] && continue
  printf '\n=== %s ===\n' "$(basename "$script")"
  bash "$script" || status=1
done
exit "$status"
