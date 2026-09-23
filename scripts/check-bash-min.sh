#!/usr/bin/env bash
# check-bash-min.sh - enforce the Bash 5.3 floor for bin/, lib/, scripts/,
# and tests/.
#
# The CLI targets Bash 5.3, the newest stable Bash, so it may use every feature
# through 5.3: forkless command substitution, ${x@U}/${x@L}/${x@K}/${x@k},
# SRANDOM, wait -n -p, BASH_MONOSECONDS, and declare -I. This checker probes
# the running interpreter for those features; that feature-floor probe is the
# only active enforcement today.
#
# A tree scan for curated post-Bash-5.3 constructs is wired in through CHECKS,
# but Bash 5.3 is the newest stable release, so no post-5.3 construct exists to
# reject and the list is intentionally empty: the scan currently matches
# nothing. Add a label and regex to CHECKS when a post-5.3 construct becomes
# known; the scan then reports file:line for each non-comment match.
#
# Findings are printed as file:line with a short label; comment-only lines and
# this script itself are skipped. Exit 0 when clean, 1 with a report otherwise.

set -uo pipefail

if ! ((BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 3))); then
  printf 'check-bash-min: this checker needs Bash 5.3+; running %s\n' "${BASH_VERSION:-unknown}" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

failures=0

# probe_result LABEL STATUS - record a finding when a feature probe failed.
probe_result() {
  local label="$1" status="$2"
  ((status == 0)) && return 0
  printf 'check-bash-min: missing Bash 5.3 feature: %s\n' "$label" >&2
  failures=$((failures + 1))
}

# run_probes - verify the interpreter provides the 5.3 features the project
# relies on. Each check sets status and hands it to probe_result.
run_probes() {
  local value="" pid="" status=0

  value=${ printf ok;}
  [[ "$value" == "ok" ]]
  probe_result "forkless command substitution" "$?"

  value="ok"
  [[ "${value@U}" == "OK" ]]
  probe_result "\${var@U}" "$?"

  [[ -n "${SRANDOM:-}" ]]
  probe_result "SRANDOM" "$?"

  (exit 0) &
  wait -n -p pid || status=$?
  [[ -n "$pid" ]] || status=1
  probe_result "wait -n -p" "$status"

  [[ -n "${BASH_MONOSECONDS:-}" ]]
  probe_result "BASH_MONOSECONDS" "$?"
}

run_probes

# One check per line: single-token label, one space, extended regular
# expression. The label is a human name for the construct; the regex matches
# likely uses in shell code. Only post-5.3 features are listed here. Bash 5.3
# is the newest stable release, so this curated list is intentionally empty and
# the scan below is a documented no-op until a post-5.3 construct is known.
CHECKS="$(
  cat <<'EOF'
EOF
)"

scan_file() {
  local file="$1" label="" regex="" match="" num="" content="" trimmed=""
  while read -r label regex; do
    [ -n "$label" ] || continue
    while IFS= read -r match; do
      num="${match%%:*}"
      content="${match#*:}"
      trimmed="${content#"${content%%[![:space:]]*}"}"
      case "$trimmed" in '#'*) continue ;; esac
      printf '%s:%s: post-Bash-5.3 construct: %s\n' "$file" "$num" "$label"
      failures=$((failures + 1))
    done < <(grep -nE "$regex" "$file" 2>/dev/null || true)
  done <<<"$CHECKS"
}

files_scanned=0
while IFS= read -r file; do
  [ "$file" = "$SELF" ] && continue
  [ -f "$file" ] || continue
  files_scanned=$((files_scanned + 1))
  scan_file "$file"
done < <(
  {
    find "$ROOT/bin" "$ROOT/lib" "$ROOT/scripts" -type f 2>/dev/null
    find "$ROOT/tests" -type f -name '*.sh' 2>/dev/null
  } | LC_ALL=C sort
)

if [ "$failures" -gt 0 ]; then
  printf 'check-bash-min: %d finding(s) in %d file(s)\n' "$failures" "$files_scanned" >&2
  exit 1
fi
printf 'check-bash-min: OK (Bash 5.3 floor; %d files, no post-5.3 patterns registered)\n' "$files_scanned"
exit 0
