#!/bin/bash
# update.sh command module - update the local sciebo checkout from git.
#
# Local-only: runs git in PROJECT_DIR and never reads the remote or writes
# user configuration. --check fetches and compares HEAD with its upstream
# without touching the working tree; without --check the checkout is updated
# with `git pull --ff-only` and the follow-up `make install` / `make lint test`
# command is printed. A source tarball (not a git worktree) and a branch
# without an upstream are reported and are not errors.

usage_update() {
  usage_emit <<'EOF'
Usage: sciebo update [--check] [--json]

Update the local sciebo checkout from its git upstream.

With --check the upstream is fetched and the local revision is compared with
it (current, ahead, behind, or diverged) without changing the working tree;
this also works on a source tarball or a branch without an upstream, which
are reported and exit 0. Without --check the checkout is updated with
`git pull --ff-only` and the command to run afterwards is printed. The
user's configuration is never modified.

Options:
  --check      only report the local vs upstream state
  --json       print the report as a JSON document
  -h, --help   show this help
EOF
}

# update_is_worktree DIR - true when DIR is inside a git work tree.
update_is_worktree() {
  git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

# update_head DIR - print HEAD's full object name.
update_head() {
  git -C "$1" rev-parse HEAD 2>/dev/null
}

# update_branch DIR - print the current branch name (or the short object name
# when HEAD is detached).
update_branch() {
  git -C "$1" rev-parse --abbrev-ref HEAD 2>/dev/null
}

# update_upstream DIR - print the current branch's upstream as
# <remote>/<branch>; rc 1 and no output when it has none.
update_upstream() {
  git -C "$1" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null
}

# update_short SHA - the abbreviated revision for display (7 characters).
update_short() {
  printf '%s' "${1:0:7}"
}

# update_json_head REPO BRANCH HEAD - begin the report object and emit the
# revision fields every report shares; the caller adds its own fields then
# closes the object with update_json_tail.
update_json_head() {
  output_json_begin
  output_json_kv repo "$1"
  output_json_kv branch "$2"
  output_json_kv head "$3"
}

# update_json_tail STATUS AVAILABLE - close the report object with the shared
# status and update_available fields.
update_json_tail() {
  output_json_kv status "$1"
  output_json_kv_raw update_available "$2"
  output_json_end
}

# update_classify_status COUNTS - split the `rev-list --left-right --count
# '@{u}...HEAD'` COUNTS into UPDATE_BEHIND/UPDATE_AHEAD (missing or malformed
# counts are zero) and classify them into UPDATE_STATUS
# (current|ahead|behind|diverged) and UPDATE_AVAILABLE.
update_classify_status() {
  local counts="$1" behind=0 ahead=0
  if [[ -n "$counts" ]]; then
    behind="${counts%%[[:space:]]*}"
    ahead="${counts##*[[:space:]]}"
  fi
  case "$behind" in '' | *[!0-9]*) behind=0 ;; esac
  case "$ahead" in '' | *[!0-9]*) ahead=0 ;; esac
  UPDATE_BEHIND="$behind"
  UPDATE_AHEAD="$ahead"
  UPDATE_AVAILABLE=false
  if [[ "$ahead" -gt 0 && "$behind" -gt 0 ]]; then
    UPDATE_STATUS="diverged"
  elif [[ "$behind" -gt 0 ]]; then
    UPDATE_STATUS="behind"
    UPDATE_AVAILABLE=true
  elif [[ "$ahead" -gt 0 ]]; then
    UPDATE_STATUS="ahead"
  else
    UPDATE_STATUS="current"
  fi
  return 0
}

# update_json_check REPO BRANCH HEAD UPSTREAM - the --check JSON document from
# the classification in UPDATE_AHEAD/UPDATE_BEHIND/UPDATE_STATUS/
# UPDATE_AVAILABLE.
update_json_check() {
  update_json_head "$1" "$2" "$3"
  output_json_kv upstream "$4"
  output_json_kv_raw ahead "$UPDATE_AHEAD"
  output_json_kv_raw behind "$UPDATE_BEHIND"
  update_json_tail "$UPDATE_STATUS" "$UPDATE_AVAILABLE"
}

# update_report_not_git REPO - the source-tarball report.
update_report_not_git() {
  local repo="$1"
  if output_json_enabled; then
    output_json_begin
    output_json_kv repo "$repo"
    output_json_kv status "not-git"
    output_json_kv_raw update_available false
    output_json_end
    return 0
  fi
  printf 'not inside a git worktree: %s (a source tarball cannot be updated this way)\n' \
    "$(printable "$repo")"
}

# update_report_no_upstream REPO BRANCH HEAD - the no-upstream report; the
# suggested fix names the branch so the user can wire it up.
update_report_no_upstream() {
  local repo="$1" branch="$2" head="$3"
  if output_json_enabled; then
    update_json_head "$repo" "$branch" "$head"
    update_json_tail "no-upstream" false
    return 0
  fi
  printf 'no upstream branch for %s in %s\n' \
    "${branch:-(detached HEAD)}" "$(printable "$repo")"
  printf 'set one with: git -C %s branch --set-upstream-to=<remote>/<branch>\n' \
    "$(printable "$repo")"
}

# update_run_check REPO - fetch, compare HEAD with its upstream, and report.
update_run_check() {
  local repo="$1" head="" branch="" upstream="" counts=""
  head="$(update_head "$repo")" || head=""
  branch="$(update_branch "$repo")" || branch=""
  upstream="$(update_upstream "$repo")" || upstream=""
  if [[ -z "$upstream" ]]; then
    update_report_no_upstream "$repo" "$branch" "$head"
    return 0
  fi
  if ! git -C "$repo" fetch --quiet 2>/dev/null; then
    warn "could not fetch the upstream; comparing against the last known upstream revision"
  fi
  counts="$(git -C "$repo" rev-list --left-right --count '@{u}...HEAD' 2>/dev/null)" || counts=""
  update_classify_status "$counts"
  if output_json_enabled; then
    update_json_check "$repo" "$branch" "$head" "$upstream"
    return 0
  fi
  case "$UPDATE_STATUS" in
    current)
      printf 'up to date with %s (%s)\n' "$upstream" "$(update_short "$head")"
      ;;
    behind)
      printf 'update available: %s commit(s) behind %s; run '\''%s update'\''\n' \
        "$UPDATE_BEHIND" "$upstream" "$CLI_NAME"
      ;;
    ahead)
      printf 'local checkout is %s commit(s) ahead of %s\n' "$UPDATE_AHEAD" "$upstream"
      ;;
    diverged)
      printf 'diverged: %s commit(s) ahead and %s commit(s) behind %s\n' \
        "$UPDATE_AHEAD" "$UPDATE_BEHIND" "$upstream"
      ;;
  esac
  return 0
}

# update_run_pull REPO - fast-forward pull and print the follow-up commands.
update_run_pull() {
  local repo="$1" before="" after=""
  before="$(update_head "$repo")" || before=""
  if ! git -C "$repo" pull --ff-only; then
    die "git pull --ff-only failed in ${repo}; commit or discard local changes and retry"
  fi
  after="$(update_head "$repo")" || after=""
  if output_json_enabled; then
    output_json_begin
    output_json_kv repo "$repo"
    output_json_kv before "$before"
    output_json_kv after "$after"
    output_json_kv_raw changed "$([[ "$before" != "$after" ]] && printf true || printf false)"
    output_json_end
    return 0
  fi
  if [[ "$before" == "$after" ]]; then
    printf 'already up to date (%s)\n' "$(update_short "$after")"
  else
    printf 'updated %s -> %s\n' "$(update_short "$before")" "$(update_short "$after")"
  fi
  printf "run 'make install' to install, then 'make lint test' to verify\n"
  return 0
}

cmd_update() {
  local repo=""
  opt_begin "check:b json:b" update "" "$@"
  opt_guard update
  opt_json_mode
  load_settings --no-rclone
  have git || die "git is required to update ${CLI_NAME} but was not found in PATH"
  repo="${PROJECT_DIR:-}"
  [[ -n "$repo" ]] || die "cannot determine the project directory"
  if ! update_is_worktree "$repo"; then
    update_report_not_git "$repo"
    return 0
  fi
  if [[ -n "${OPT_check:-}" ]]; then
    update_run_check "$repo"
    return 0
  fi
  update_run_pull "$repo"
  return 0
}
