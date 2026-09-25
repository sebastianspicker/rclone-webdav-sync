#!/usr/bin/env bash
# update.sh - local-checkout update logic. Every repository is a throwaway
# created under $TMP and PROJECT_DIR is overridden in a subshell, so the real
# checkout is never fetched, pulled, or modified.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"
# cmd_update is called in-process with PROJECT_DIR overridden, so the JSON
# shellcheck source=../../lib/commands/update.sh
source "${PROJ}/lib/commands/update.sh"

GIT_ID=(-c user.email=test@example.com -c user.name=FeatureTest)

# run_update_dir REPO ARGS... - cmd_update with PROJECT_DIR pointed at REPO.
# shellcheck disable=SC2329  # invoked indirectly via capture
run_update_dir() {
  local repo="$1"
  shift
  (
    PROJECT_DIR="$repo"
    cmd_update "$@"
  )
}

# --- a temp origin plus a clone that tracks it ------------------------------
ORIGIN="${TMP}/origin.git"
git init --bare -q --initial-branch=main "$ORIGIN"
SEED="${TMP}/seed"
git init -q "$SEED"
(
  cd "$SEED" || exit 1
  printf 'one\n' >file.txt
  git add file.txt
  git "${GIT_ID[@]}" commit -q -m one
  git branch -M main
  git remote add origin "$ORIGIN"
  git push -q -u origin main
)
REPO="${TMP}/repo"
git clone -q "$ORIGIN" "$REPO"

capture run_update_dir "$REPO" --check
expect_rc "update: current rc 0" "$CLI_RC" 0
expect_contains "update: current report" "$CLI_OUT" "up to date"

capture run_update_dir "$REPO" --check --json
expect_rc "update: current --json rc 0" "$CLI_RC" 0
expect_contains "update: json status current" "$CLI_OUT" '"status": "current"'
expect_contains "update: json behind 0" "$CLI_OUT" '"behind": 0'
expect_contains "update: json no update" "$CLI_OUT" '"update_available": false'

# advance the origin, so the clone falls behind
(
  cd "$SEED" || exit 1
  printf 'two\n' >>file.txt
  git "${GIT_ID[@]}" commit -q -am two
  git push -q origin main
)
capture run_update_dir "$REPO" --check
expect_rc "update: behind rc 0" "$CLI_RC" 0
expect_contains "update: behind report" "$CLI_OUT" "update available"
capture run_update_dir "$REPO" --check --json
expect_rc "update: behind --json rc 0" "$CLI_RC" 0
expect_contains "update: json behind 1" "$CLI_OUT" '"behind": 1'
expect_contains "update: json status behind" "$CLI_OUT" '"status": "behind"'
expect_contains "update: json update available" "$CLI_OUT" '"update_available": true'

# without --check: fast-forward pull plus the follow-up commands
capture run_update_dir "$REPO"
expect_rc "update: pull rc 0" "$CLI_RC" 0
expect_contains "update: pull reports the update" "$CLI_OUT" "updated"
expect_contains "update: pull install hint" "$CLI_OUT" "make install"
expect_contains "update: pull lint hint" "$CLI_OUT" "make lint test"
capture run_update_dir "$REPO" --check
expect_rc "update: current after pull rc 0" "$CLI_RC" 0
expect_contains "update: up to date after pull" "$CLI_OUT" "up to date"

# --- no upstream: a branch without a remote ---------------------------------
NOUP="${TMP}/no-upstream"
git init -q "$NOUP"
(
  cd "$NOUP" || exit 1
  printf 'x\n' >f.txt
  git add f.txt
  git "${GIT_ID[@]}" commit -q -m x
)
capture run_update_dir "$NOUP" --check
expect_rc "update: no upstream rc 0" "$CLI_RC" 0
expect_contains "update: no upstream report" "$CLI_OUT" "no upstream branch"
capture run_update_dir "$NOUP" --check --json
expect_rc "update: no upstream --json rc 0" "$CLI_RC" 0
expect_contains "update: json no-upstream status" "$CLI_OUT" '"status": "no-upstream"'

# --- not a git worktree: a plain directory ----------------------------------
NOTGIT="${TMP}/not-git"
mkdir -p "$NOTGIT"
capture run_update_dir "$NOTGIT" --check
expect_rc "update: non-git rc 0" "$CLI_RC" 0
expect_contains "update: non-git report" "$CLI_OUT" "not inside a git worktree"
capture run_update_dir "$NOTGIT" --check --json
expect_rc "update: non-git --json rc 0" "$CLI_RC" 0
expect_contains "update: json not-git status" "$CLI_OUT" '"status": "not-git"'

finish
