#!/usr/bin/env bash
# completions.sh - completions/sciebo.spec and scripts/gen-completions.sh:
# the generator is clean (--check), the generated zsh/fish files parse (when
# those shells are installed), and the generated bash completion produces
# the right candidates for a representative set of commands/options.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../harness.sh
COMPLETIONS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$(cd "${COMPLETIONS_DIR}/../.." && pwd)"
source "${COMPLETIONS_DIR}/../harness.sh"

# --- the committed completions match the spec -------------------------------

check_out="$(cd "$PROJ" && bash scripts/gen-completions.sh --check 2>&1)"
check_rc=$?
expect_rc "gen-completions --check: exit 0" "$check_rc" 0
if [[ "$check_rc" -ne 0 ]]; then
  printf '%s\n' "$check_out" >&2
fi

# --- zsh/fish parse the generated files (best effort) -----------------------

if command -v zsh >/dev/null 2>&1; then
  zsh_out="$(zsh -n "${PROJ}/completions/_sciebo" 2>&1)"
  zsh_rc=$?
  expect_rc "zsh -n completions/_sciebo: exit 0" "$zsh_rc" 0
  expect_eq "zsh -n completions/_sciebo: no output" "" "$zsh_out"
else
  pass "zsh -n completions/_sciebo (skipped: zsh not installed)"
fi

if command -v fish >/dev/null 2>&1; then
  fish_out="$(fish -n "${PROJ}/completions/sciebo.fish" 2>&1)"
  fish_rc=$?
  expect_rc "fish -n completions/sciebo.fish: exit 0" "$fish_rc" 0
  expect_eq "fish -n completions/sciebo.fish: no output" "" "$fish_out"
else
  pass "fish -n completions/sciebo.fish (skipped: fish not installed)"
fi

# --- bash completion candidates ---------------------------------------------
# Source the generated file from a throwaway copy of the tree so its
# BASH_SOURCE-relative project-root/profile walk (_sciebo_project_root/
# _sciebo_profile_names) resolves against a disposable config/profiles tree
# instead of this checkout's real one.

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sciebo-completions.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/completions" "$TMP/config/profiles/alpha" "$TMP/config/profiles/beta"
mkdir -p "$TMP/scratch/subone" "$TMP/scratch/subtwo"
cp "${PROJ}/completions/sciebo.bash" "$TMP/completions/sciebo.bash"

# shellcheck source=/dev/null
source "$TMP/completions/sciebo.bash"

# reply_has NEEDLE - true when NEEDLE is one of COMPREPLY's entries.
reply_has() {
  local c
  for c in "${COMPREPLY[@]:-}"; do
    [[ "$c" == "$1" ]] && return 0
  done
  return 1
}

# 1. Top-level: no command typed yet.
COMP_WORDS=(sciebo "")
COMP_CWORD=1
_sciebo
if reply_has sync && reply_has share && reply_has help; then
  pass "bash: top-level candidates include sync, share, help"
else
  fail "bash: top-level candidates include sync, share, help" "${COMPREPLY[*]:-}"
fi

# 2. `sync --mo<TAB>`: sync has no --mo* option (folders' --mode must not
# leak into sync's list; the old flat _sciebo_value_opts had no per-command
# scoping at all).
COMP_WORDS=(sciebo sync "--mo")
COMP_CWORD=2
_sciebo
expect_eq "bash: sync --mo<TAB> has no candidates" "0" "${#COMPREPLY[@]}"

# 3. `folders add --mode <TAB>`: the --mode enum action.
COMP_WORDS=(sciebo folders add --mode "")
COMP_CWORD=4
_sciebo
expect_eq "bash: folders add --mode<TAB> is the mode enum" "sync pull bisync" "${COMPREPLY[*]:-}"

# 4. `share <TAB>`: subcommand names.
COMP_WORDS=(sciebo share "")
COMP_CWORD=2
_sciebo
if reply_has link && reply_has accept && reply_has copy-link; then
  pass "bash: share<TAB> lists its subcommands"
else
  fail "bash: share<TAB> lists its subcommands" "${COMPREPLY[*]:-}"
fi

# 5. `share link --download <TAB>`: the 0/1 enum, scoped to share link (not
# every command's --download - verify's is a boolean flag, case 6 below).
COMP_WORDS=(sciebo share link --download "")
COMP_CWORD=4
_sciebo
expect_eq "bash: share link --download<TAB> is 0 1" "0 1" "${COMPREPLY[*]:-}"

# 6. `verify --down<TAB>`: --download is listed as an option name (a flag,
# not a value-taking option, for this command).
COMP_WORDS=(sciebo verify "--down")
COMP_CWORD=2
_sciebo
if reply_has --download; then
  pass "bash: verify --down<TAB> offers --download"
else
  fail "bash: verify --down<TAB> offers --download" "${COMPREPLY[*]:-}"
fi

# 7. `--profile <TAB>`: profile basenames plus "default", from a throwaway
# config/profiles tree (never this checkout's real one).
COMP_WORDS=(sciebo --profile "")
COMP_CWORD=2
_sciebo
if reply_has alpha && reply_has beta && reply_has default; then
  pass "bash: --profile<TAB> lists basenames plus default"
else
  fail "bash: --profile<TAB> lists basenames plus default" "${COMPREPLY[*]:-}"
fi

# 8. `folders add --local-root <TAB>`: directory completion.
(
  cd "$TMP/scratch" || exit 1
  COMP_WORDS=(sciebo folders add --local-root "sub")
  COMP_CWORD=4
  _sciebo
  if reply_has subone && reply_has subtwo; then
    pass "bash: folders add --local-root<TAB> completes directories"
  else
    fail "bash: folders add --local-root<TAB> completes directories" "${COMPREPLY[*]:-}"
  fi
)

# 9. `help <TAB>`: the COMMANDS action.
COMP_WORDS=(sciebo help "")
COMP_CWORD=2
_sciebo
if reply_has sync && reply_has share; then
  pass "bash: help<TAB> lists every command"
else
  fail "bash: help<TAB> lists every command" "${COMPREPLY[*]:-}"
fi

# 10. `presence set <TAB>`: an enum positional inside a dispatch subcommand.
COMP_WORDS=(sciebo presence set "")
COMP_CWORD=3
_sciebo
expect_eq "bash: presence set<TAB> is the status enum" "online away dnd offline" "${COMPREPLY[*]:-}"

finish
