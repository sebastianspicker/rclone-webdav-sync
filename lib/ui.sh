#!/bin/bash
# ui.sh - interactive prompts and selection helpers.
# Functions set UI_* globals or print to stdout so command modules own
# their messages. All return non-zero instead of exiting, except
# ui_select_indices, which gives up after three invalid attempts.

UI_ASK_REPLY=""

# ui_ask PROMPT - read one line into UI_ASK_REPLY; returns 1 on EOF.
ui_ask() {
  printf '%s' "$1"
  IFS= read -r UI_ASK_REPLY
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
    input="$(trim "$input")"
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
