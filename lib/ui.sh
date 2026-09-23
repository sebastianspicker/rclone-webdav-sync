#!/bin/bash
# ui.sh - interactive prompts and selection helpers.
# Functions set UI_* globals or print to stdout so command modules own
# their messages. All return non-zero instead of exiting, except
# ui_select_indices, which gives up after three invalid attempts, and the
# confirmation gates, which stop a run that must be interactive through
# usage_error (exit 2) - the decline path itself only returns non-zero, so
# the caller decides what a declined answer means.

UI_ASK_REPLY=""

# ui_ask PROMPT - read one line into UI_ASK_REPLY; returns 1 on EOF.
ui_ask() {
  printf '%s' "$1"
  IFS= read -r UI_ASK_REPLY
}

# ui_ask_secret PROMPT - like ui_ask but the reply is not echoed (read -s),
# for passwords and other secrets; a newline is written so the next line does
# not continue the prompt. Sets UI_ASK_REPLY and returns 1 on EOF.
ui_ask_secret() {
  printf '%s' "$1"
  IFS= read -r -s UI_ASK_REPLY
  local rc=$?
  printf '\n'
  return "$rc"
}

# ui_stdin_tty - true when stdin is a terminal. The one primitive behind
# every gate in this module; kept as its own function so tests can
# substitute the check without a real pty (same pattern as rclone.sh's
# progress_stdout_tty).
ui_stdin_tty() { [[ -t 0 ]]; }

# _ui_promptable - true when a question may be asked at all: a terminal
# with SCIEBO_NON_INTERACTIVE unset. Shared by the four confirmation gates
# so they cannot drift apart again.
_ui_promptable() { ui_stdin_tty && [[ -z "${SCIEBO_NON_INTERACTIVE:-}" ]]; }

# ui_confirm PROMPT - ask a yes/no question on a TTY; true for y/yes
# (case-insensitive), false for anything else or EOF. Callers decide what a
# false answer means; non-interactive callers should not call this.
ui_confirm() {
  ui_ask "${1:-Continue?} [y/N]: " || return 1
  # Case-insensitive patterns (no `tr` fork); any y/yes spelling accepts.
  case "${UI_ASK_REPLY:-}" in
    [yY] | [yY][eE][sS]) return 0 ;;
  esac
  return 1
}

# ui_confirm_default_yes PROMPT - the [Y/n] counterpart of ui_confirm: an
# empty answer accepts, as do y/yes (case-insensitive); anything else or EOF
# declines. The caller decides what a decline means.
ui_confirm_default_yes() {
  ui_ask "${1:-Continue?} [Y/n]: " || return 1
  local reply=""
  reply=${ trim "$UI_ASK_REPLY";}
  case "$reply" in
    '' | [yY] | [yY][eE][sS]) return 0 ;;
  esac
  return 1
}

# _ui_mutation_gate COMMAND REQUIRES_MESSAGE PROMPT MODE DECLINE_MSG - the one
# implementation behind the hard and soft mutation gates. --yes skips the
# prompt; a non-interactive run without --yes is usage_error COMMAND
# REQUIRES_MESSAGE; a declined ui_confirm returns 1 after MODE picks the
# decline channel: "abort" prints 'aborted' (the hard gate), "log" writes
# DECLINE_MSG through log(), "silent" prints nothing (the soft gate's
# message-less form). Never exits on decline.
_ui_mutation_gate() {
  local command="$1" requires="$2" prompt="$3" mode="$4" decline="$5"
  [[ "${OPT_yes:-0}" == "1" ]] && return 0
  _ui_promptable || usage_error "$command" "$requires"
  ui_confirm "$prompt" && return 0
  case "$mode" in
    log)
      [[ -z "$decline" ]] || log "$decline"
      ;;
    abort)
      printf 'aborted\n'
      ;;
  esac
  return 1
}

# ui_confirm_mutation COMMAND REQUIRES_MESSAGE PROMPT [DECLINE_MSG] -
# confirmation gate for destructive mutations. --yes (OPT_yes=1) skips the
# prompt; REQUIRES_MESSAGE names the option and the reason for a
# non-interactive run without --yes. A declined answer prints 'aborted' and
# returns 1, or logs DECLINE_MSG instead when one is given, so the caller can
# stop without failing the run.
ui_confirm_mutation() {
  local command="$1" requires="$2" prompt="$3" decline="${4:-}"
  if [[ -n "$decline" ]]; then
    _ui_mutation_gate "$command" "$requires" "$prompt" log "$decline"
  else
    _ui_mutation_gate "$command" "$requires" "$prompt" abort ""
  fi
}

# ui_confirm_mutation_soft COMMAND REQUIRES_MESSAGE PROMPT [DECLINE_MSG] -
# the soft variant: same rules as ui_confirm_mutation, but a declined answer
# never prints 'aborted' - DECLINE_MSG, when given, is logged and an unset
# one stays silent. The caller decides what declining means. Return
# contract: 0 = proceed, 1 = declined, only usage_error exits (2).
ui_confirm_mutation_soft() {
  local command="$1" requires="$2" prompt="$3" decline="${4:-}"
  _ui_mutation_gate "$command" "$requires" "$prompt" log "$decline"
}

# ui_confirm_proceed PROMPT - confirmation gate for mutations whose
# non-interactive callers should keep working: --yes answers yes, and a
# non-interactive stdin (or SCIEBO_NON_INTERACTIVE) proceeds without a prompt.
# On a terminal the question goes through ui_confirm; a declined prompt prints
# 'aborted' and returns 1 so the caller can stop without failing the run.
ui_confirm_proceed() {
  [[ "${OPT_yes:-0}" == "1" ]] && return 0
  _ui_promptable || return 0
  ui_confirm "$1" || {
    printf 'aborted\n'
    return 1
  }
  return 0
}

# ui_confirm_tty PROMPT - the single TTY/interactive gate for policy
# confirmations (the external-storage/e2ee asks, the metered-network ask).
# Returns 0 when the user accepted the ui_confirm prompt (unified [y/yes]
# dialect), 1 when promptable but declined (or EOF), and 2 when the
# question cannot be asked at all: stdin is not a terminal or
# SCIEBO_NON_INTERACTIVE is set. It never exits and never prompts on 2.
# Caller mappings at adoption:
#   sync_policy_confirm_external  map 0 -> proceed, 1/2 -> decline; this
#     makes sync honor SCIEBO_NON_INTERACTIVE and take exactly the branch
#     it already takes when stdin is not a tty (approved change).
#   folders_choose choose_policy_confirm  map 0 -> confirm, 1/2 -> return 1;
#     byte-identical to its current `[[ -t 0 && -z SCIEBO_NON_INTERACTIVE ]]
#     || return 1; ui_confirm ...` gate.
#   platform net_gate (ask)  map 0 -> proceed; 1/2 -> warn + return 2;
#     accepting yes/YES in place of the y|Y-only reply is the approved
#     dialect unification.
#   account account_import_local_confirmed  map 0 -> confirm, 1 -> skip the
#     pair, 2 -> the pre-prompt skip it took when not interactive (a skip
#     keeps the import rc 0, so this caller must not usage_error).
ui_confirm_tty() {
  _ui_promptable || return 2
  ui_confirm "$1" && return 0
  return 1
}

# ui_parse_selection INPUT MAX - expand "1 3", "1,3", "5-7", or "all" into
# sorted, unique 1-based indices, one per line. Returns 1 on bad input.
ui_parse_selection() {
  local input="$1" max="$2" out="" token lo hi i tokens
  read -r -a tokens <<<"$(printf '%s' "$input" | tr ',' ' ')"
  [[ "${#tokens[@]}" -gt 0 ]] || return 1
  for token in "${tokens[@]}"; do
    case "$token" in
      all | ALL)
        for ((i = 1; i <= max; i++)); do out="${out}${i}"$'\n'; done
        ;;
      *)
        if [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
          lo=$((10#${BASH_REMATCH[1]}))
          hi=$((10#${BASH_REMATCH[2]}))
          [[ "$lo" -ge 1 && "$hi" -le "$max" && "$lo" -le "$hi" ]] || return 1
          for ((i = lo; i <= hi; i++)); do out="${out}${i}"$'\n'; done
        elif [[ "$token" =~ ^[0-9]+$ ]]; then
          i=$((10#$token))
          [[ "$i" -ge 1 && "$i" -le "$max" ]] || return 1
          out="${out}${i}"$'\n'
        else
          return 1
        fi
        ;;
    esac
  done
  printf '%s' "$out" | LC_ALL=C sort -n -u
}

# ui_select_indices MAX PROMPT - read a selection from stdin, re-prompting
# up to three times on invalid input; prints the chosen indices. Empty
# input prints nothing and returns 0; EOF or persistent bad input exits.
ui_select_indices() {
  local max="$1" prompt="$2" attempt=0 input="" chosen=""
  while :; do
    printf '%s' "$prompt" >&2
    IFS= read -r input || die "input ended; nothing changed"
    input=${ trim "$input";}
    [[ -n "$input" ]] || return 0
    if chosen="$(ui_parse_selection "$input" "$max")"; then
      printf '%s\n' "$chosen"
      return 0
    fi
    attempt=$((attempt + 1))
    [[ "$attempt" -lt 3 ]] || die "invalid selection: ${input}"
    warn "invalid selection '${input}'; try again"
  done
}
