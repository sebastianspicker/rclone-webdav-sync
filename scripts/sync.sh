#!/usr/bin/env bash
# Compatibility shim for automation that still calls scripts/sync.sh:
# installed launchd agents that point at the old path, plus local scripts
# or habits referencing it.
#
# Removal condition: delete this file once `sciebo schedule install` has
# been re-run on every machine. Old semantics: no --apply means dry run.

set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
args=()
apply=false
list=false
for arg in "$@"; do
  case "$arg" in
    --apply) apply=true ;;
    --list) list=true ;;
    *) args[${#args[@]}]="$arg" ;;
  esac
done

run() {
  exec "$PROJECT_DIR/bin/sciebo" "$1" "${args[@]}"
}

if [[ "$list" == true ]]; then
  run list
elif [[ "$apply" == true ]]; then
  run sync
else
  run check
fi
