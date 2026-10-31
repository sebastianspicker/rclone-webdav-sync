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

# sciebo needs bash 5.3+, but cron and other minimal environments often find
# only macOS's /bin/bash 3.2 on PATH. This part stays bash-3.2 compatible and
# picks the first new enough bash; with none, bin/sciebo's own guard explains.
find_bash() {
  local c=""
  for c in "${SCIEBO_BASH:-}" "$(command -v bash 2>/dev/null || true)" \
    /opt/homebrew/bin/bash /usr/local/bin/bash /home/linuxbrew/.linuxbrew/bin/bash \
    /usr/bin/bash /bin/bash; do
    [ -n "$c" ] && [ -x "$c" ] || continue
    if "$c" -c '((BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 3)))' 2>/dev/null; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  printf 'bash\n'
}
SCIEBO_BASH_BIN="$(find_bash)"

run() {
  # ${args[@]+...}: an empty array under set -u is an error in bash 3.2.
  exec "$SCIEBO_BASH_BIN" "$PROJECT_DIR/bin/sciebo" "$1" ${args[@]+"${args[@]}"}
}

if [[ "$list" == true ]]; then
  run list
elif [[ "$apply" == true ]]; then
  run sync
else
  run check
fi
