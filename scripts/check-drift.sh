#!/usr/bin/env bash
# check-drift.sh - detect drift between the CLI's sources of truth.
#
# lib/cli/sciebo.spec is the single declarative source scripts/gen-cli.sh
# generates lib/cli/registry.sh (SCIEBO_COMMANDS, the command-to-module and
# tier maps, and _SCIEBO_GLOBAL_SPECS) and completions/{sciebo.bash,_sciebo,
# sciebo.fish} from; `scripts/gen-cli.sh --check` (part of `make lint`) is
# what catches the registry or the completions drifting from the spec, and
# validates the spec itself (every COMMAND's module file exists, every
# lib/commands/*.sh is used, and usage_main's Commands:/Extra commands
# sections match the spec's tiers in order). This script therefore reads the
# command list from the generated lib/cli/registry.sh instead of
# sed-parsing lib/cli/main.sh, and no longer compares SCIEBO_COMMANDS or
# _SCIEBO_GLOBAL_SPECS against the spec directly - only what remains a live
# behavioral question: whether the implementation (usage_<name>() text, the
# man page, docs/commands.md, and the real `--help` output) still matches
# what the spec/registry declare.
#
# Hard failures (exit 1):
#   - a name in the generated SCIEBO_COMMANDS has only one of
#     usage_<name>() / cmd_<name>() under lib/commands/,
#   - a key in lib/config/settings.sh's require_setting call is missing from
#     config/settings.env.
# Warnings (still exit 0):
#   - a SCIEBO_COMMANDS entry with neither definition (a planned command;
#     the implemented set may legitimately lag the dispatch list),
#   - a config/settings.env key not mentioned in docs/settings.md or in
#     config/settings.local.env.example,
#   - a SCIEBO_COMMANDS entry missing from man/sciebo.1,
#   - a docs/commands.md `### <command>` heading that is not in
#     SCIEBO_COMMANDS, or a SCIEBO_COMMANDS entry (other than `help`) with no
#     such heading,
#   - a global option in the generated _SCIEBO_GLOBAL_SPECS not mentioned in
#     docs/commands.md or man/sciebo.1,
#   - a long option in a command's usage_<name>() heredoc not mentioned in
#     that command's `### <name>` section of docs/commands.md (best effort),
#   - a long option in a command's usage_<name>() heredoc not mentioned in the
#     command's section of the man page (best effort; global options are
#     documented once in the man page's global section and are exempt),
#   - a subcommand named under a `Subcommands:`/`Commands:` heading in a
#     command's usage_<name>() heredoc not mentioned in docs/commands.md
#     (best effort),
#   - a subcommand named under a `Subcommands:`/`Commands:` heading in a
#     command's usage_<name>() heredoc missing from man/sciebo.1 (best
#     effort),
#   - a long option that `bin/sciebo <name> --help` prints but
#     lib/cli/sciebo.spec does not declare for that command, or vice versa
#     (best effort; hard failures in DRIFT_STRICT mode - see below),
#   - a function defined in lib/*.sh or lib/commands/*.sh that is referenced
#     nowhere in lib/, bin/, or tests/ (best effort),
#   - a function defined in lib/*.sh or lib/commands/*.sh whose only
#     references are in tests/, i.e. it has no production (lib/, bin/) caller
#     (best effort),
#   - a lib/*.sh or lib/commands/*.sh file that assigns a top-level
#     `_<module>_*` global whose prefix names a *different* module (the
#     naming rule in docs/architecture.md's "Shared globals" section; best
#     effort - a coincidental prefix match is possible, so this never fails
#     hard).
#
# Set DRIFT_STRICT=1 to turn the "planned command" and "spec vs --help"
# warnings into hard failures, which is what a release/CI check wants once
# every SCIEBO_COMMANDS entry is implemented and the spec is complete.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STRICT="${DRIFT_STRICT:-0}"
hard_failures=0
warnings=0

hard() {
  printf 'FAIL: %s\n' "$1"
  hard_failures=$((hard_failures + 1))
}
warn() {
  printf 'WARN: %s\n' "$1"
  warnings=$((warnings + 1))
}

# _drift_has TEXT NEEDLE - true when NEEDLE occurs in TEXT with a
# non-identifier character (or the string edge) on both sides. NEEDLE is a
# command, subcommand, or `--flag` token, so it holds no regex metacharacter;
# the check runs as an in-process bash regex instead of a grep per token.
_drift_has() {
  [[ "$1" =~ (^|[^A-Za-z0-9_-])${2}([^A-Za-z0-9_-]|$) ]]
}

# usage_subcommands NAME - print, one per line, the subcommands listed under
# the `Subcommands:`/`Commands:` heading of usage_NAME(). The heading sits at
# column 0, the entries are two-space indented, and continuation lines are
# ignored. Reads the precomputed USAGE_BODY map (see below), so it never
# re-scans lib/commands/. Shared by the docs and completion/man checks.
usage_subcommands() {
  local body="${USAGE_BODY[$1]:-}"
  [ -n "$body" ] || return 0
  awk '
    /^(Subcommands|Commands):/ { collecting = 1; next }
    collecting && /^[[:space:]]*$/ { collecting = 0 }
    collecting && /^  [^ ]/ {
      line = $0
      sub(/^  /, "", line)
      sub(/[[:space:]].*/, "", line)
      gsub(/^\[/, "", line)
      gsub(/\]$/, "", line)
      if (line !~ /^-/) print line
    }
  ' <<<"$body" | sort -u
}

# --- SCIEBO_COMMANDS vs usage_/cmd_ definitions -----------------------------
# lib/cli/registry.sh is generated by scripts/gen-cli.sh from
# lib/cli/sciebo.spec; it is data only (see its own header), so sourcing it
# here is safe and replaces the previous sed-parse of lib/cli/main.sh.

# shellcheck source=../lib/cli/registry.sh
source "$ROOT/lib/cli/registry.sh"
commands="$SCIEBO_COMMANDS"
if [ -z "$commands" ]; then
  hard "cannot read SCIEBO_COMMANDS from lib/cli/registry.sh"
  printf 'check-drift: %d hard failure(s), %d warning(s)\n' "$hard_failures" "$warnings"
  exit 1
fi

usage_names=" $(grep -hoE '^usage_[A-Za-z0-9_]+\(\)' "$ROOT"/lib/commands/*.sh 2>/dev/null | sed 's/()$//' | tr '\n' ' ') "
cmd_names=" $(grep -hoE '^cmd_[A-Za-z0-9_]+\(\)' "$ROOT"/lib/commands/*.sh 2>/dev/null | sed 's/()$//' | tr '\n' ' ') "

# --- precomputed sources of truth (one pass each) ---------------------------
# Every usage_<name>() body is extracted in a single awk pass over
# lib/commands/, and the docs, completions, and man page are read into
# variables once. The per-command option/subcommand checks below then match
# against these in-process strings with bash regexes instead of spawning a
# grep (or an awk re-reading every command file) per command or per flag.

declare -A USAGE_BODY=()
while IFS=$'\t' read -r _ub_name _ub_line; do
  [ -n "$_ub_name" ] || continue
  USAGE_BODY["$_ub_name"]+="${_ub_line}"$'\n'
done < <(awk '
  /^usage_[A-Za-z0-9_]+\(\)/ {
    n = $0
    sub(/^usage_/, "", n)
    sub(/\(\).*/, "", n)
    if ($0 ~ /}/) { cur = ""; next }
    cur = n
    print n "\t" $0
    next
  }
  cur != "" {
    print cur "\t" $0
    if ($0 ~ /^}/) cur = ""
  }
' "$ROOT"/lib/commands/*.sh 2>/dev/null)

man_file="$ROOT/man/sciebo.1"
have_man=0
man_plain=""
docs_text=""
if [ -f "$man_file" ]; then
  have_man=1
  # The man page escapes option hyphens as `\-\-`; strip the backslashes once.
  man_plain="$(sed 's/\\//g' "$man_file")"
fi
[ -f "$ROOT/docs/commands.md" ] && docs_text="$(cat "$ROOT/docs/commands.md")"

# MAN_SECTION NAME / DOC_SECTION NAME - the man sections whose heading starts
# with "sciebo NAME" (unioning subcommand sections) and the `### NAME` section
# of docs/commands.md, each extracted in one pass and keyed by the command
# name (the first token after "sciebo " / the heading token).
declare -A MAN_SECTION=()
declare -A DOC_SECTION=()
if [ "$have_man" -eq 1 ]; then
  while IFS=$'\t' read -r _ms_name _ms_line; do
    [ -n "$_ms_name" ] || continue
    MAN_SECTION["$_ms_name"]+="${_ms_line}"$'\n'
  done < <(awk '
    /^\.S[SH] / {
      cur = ""
      if (match($0, /^\.S[SH] "sciebo [^ "]+/)) {
        s = substr($0, RSTART, RLENGTH)
        sub(/^\.S[SH] "sciebo /, "", s)
        cur = s
      }
    }
    cur != "" { print cur "\t" $0 }
  ' "$man_file" | sed 's/\\//g')
fi
if [ -n "$docs_text" ]; then
  while IFS=$'\t' read -r _ds_name _ds_line; do
    [ -n "$_ds_name" ] || continue
    DOC_SECTION["$_ds_name"]+="${_ds_line}"$'\n'
  done < <(awk '
    /^### [A-Za-z0-9_-]+$/ {
      cur = substr($0, 5)
      next
    }
    cur != "" && /^##/ { cur = ""; next }
    cur != "" { print cur "\t" $0 }
  ' "$ROOT/docs/commands.md")
fi

for name in $commands; do
  has_usage=0
  has_cmd=0
  case "$usage_names" in *" usage_${name} "*) has_usage=1 ;; esac
  case "$cmd_names" in *" cmd_${name} "*) has_cmd=1 ;; esac
  if [ "$has_usage" -eq 0 ] && [ "$has_cmd" -eq 0 ]; then
    if [ "$STRICT" = "1" ]; then
      hard "command '${name}' is in COMMANDS but has no usage_${name}()/cmd_${name}() in lib/commands/"
    else
      warn "command '${name}' is in COMMANDS but not implemented (no usage_${name}()/cmd_${name}())"
    fi
  elif [ "$has_usage" -ne "$has_cmd" ]; then
    if [ "$has_usage" -eq 1 ]; then
      hard "command '${name}' defines usage_${name}() but no cmd_${name}()"
    else
      hard "command '${name}' defines cmd_${name}() but no usage_${name}()"
    fi
  fi
done

# (The previous check of the old hand-written command-to-module override
# table against lib/commands/ is gone: scripts/gen-cli.sh --check now
# validates every COMMAND row's module file exists and every
# lib/commands/*.sh is used by at least one COMMAND row, straight from the
# generator that builds SCIEBO_COMMAND_MODULE.)

# --- require_setting keys vs config/settings.env ----------------------------

required_keys="$(awk '
  /^[[:space:]]*require_setting[[:space:]]/ { collecting = 1 }
  collecting {
    line = $0
    sub(/^[[:space:]]*require_setting[[:space:]]*/, "", line)
    gsub(/\\/, " ", line)
    count = split(line, words, /[[:space:]]+/)
    for (i = 1; i <= count; i++) {
      if (words[i] ~ /^[A-Z][A-Z0-9_]*$/) print words[i]
    }
    if ($0 !~ /\\[[:space:]]*$/) collecting = 0
  }
' "$ROOT/lib/config/settings.sh")"

for key in $required_keys; do
  if ! grep -qF "\${${key}:" "$ROOT/config/settings.env" &&
    ! grep -qF "\${${key}}" "$ROOT/config/settings.env"; then
    hard "setting '${key}' is required by lib/config/settings.sh but missing from config/settings.env"
  fi
done

# --- config/settings.env vs docs (warning) ----------------------------------

env_keys="$(sed -n 's/^: "\${\([A-Za-z_][A-Za-z0-9_]*\):=.*/\1/p' "$ROOT/config/settings.env")"
if [ -f "$ROOT/docs/settings.md" ]; then
  for key in $env_keys; do
    # Match the whole key, not a substring: PROXY must not be satisfied by a
    # mention of PROXY_TYPE, so require a non-identifier character (or the
    # start/end of the file) on both sides.
    grep -qE "(^|[^A-Za-z0-9_])${key}([^A-Za-z0-9_]|$)" "$ROOT/docs/settings.md" ||
      warn "setting '${key}' is in config/settings.env but not mentioned in docs/settings.md"
  done
else
  warn "docs/settings.md not found; skipping the settings documentation check"
fi

# --- config/settings.env vs config/settings.local.env.example (warning) ------

if [ -f "$ROOT/config/settings.local.env.example" ]; then
  for key in $env_keys; do
    # Same whole-key match as the docs check, so PROXY is not satisfied by a
    # mention of PROXY_TYPE.
    grep -qE "(^|[^A-Za-z0-9_])${key}([^A-Za-z0-9_]|$)" "$ROOT/config/settings.local.env.example" ||
      warn "setting '${key}' is in config/settings.env but not in config/settings.local.env.example"
  done
else
  warn "config/settings.local.env.example not found; skipping the example check"
fi

# --- COMMANDS vs docs/commands.md headings (warning) ------------------------

if [ -f "$ROOT/docs/commands.md" ]; then
  # A command heading is a single token on its own line; require at least one
  # character so a bare `###` heading cannot pass silently.
  doc_commands="$(sed -n 's/^### \([A-Za-z0-9_-][A-Za-z0-9_-]*\)$/\1/p' "$ROOT/docs/commands.md" | tr '\n' ' ')"
  for name in $doc_commands; do
    case " $commands " in
      *" $name "*) ;;
      *) warn "docs/commands.md documents '${name}' but it is not in COMMANDS" ;;
    esac
  done
  for name in $commands; do
    # `help` is documented under `## Help`, not a `### help` heading.
    [ "$name" = "help" ] && continue
    case " $doc_commands " in
      *" $name "*) ;;
      *) warn "command '${name}' is in COMMANDS but not documented in docs/commands.md" ;;
    esac
  done
fi

# --- _SCIEBO_GLOBAL_SPECS vs docs and man (warning) -------------------------
# The completions' own global-option coverage is checked against
# lib/cli/sciebo.spec by scripts/gen-cli.sh --check instead (part of `make
# lint`): the generated files mirror the spec exactly, so a spec row missing
# an alias would already fail that check. _SCIEBO_GLOBAL_SPECS itself is
# generated into lib/cli/registry.sh (sourced above), so this reads that
# real bash array instead of sed-parsing lib/cli/main.sh.

if [ -f "$ROOT/docs/commands.md" ]; then
  global_specs=""
  for spec in "${_SCIEBO_GLOBAL_SPECS[@]}"; do
    global_specs+="${global_specs:+ }${spec%%|*}"
  done
  for spec in $global_specs; do
    # A spec is a comma-separated alias list; every alias must be documented.
    IFS=',' read -r -a flags <<<"$spec"
    for flag in "${flags[@]}"; do
      [ -n "$flag" ] || continue
      _drift_has "$docs_text" "$flag" ||
        warn "global option '${flag}' is in _SCIEBO_GLOBAL_SPECS but not mentioned in docs/commands.md"
      if [ "$have_man" -eq 1 ]; then
        _drift_has "$man_plain" "$flag" ||
          warn "global option '${flag}' is in _SCIEBO_GLOBAL_SPECS but not mentioned in man/sciebo.1"
      fi
    done
  done
else
  warn "docs/commands.md not found; skipping the global-option check"
fi

# --- COMMANDS vs man page (warning) ------------------------------------------
# The completions' own command coverage is checked against
# lib/cli/sciebo.spec by scripts/gen-cli.sh --check instead (see the note
# above); the spec-vs---help check further below covers the spec itself.

for name in $commands; do
  if [ "$have_man" -eq 1 ]; then
    [[ "$man_plain" =~ sciebo[[:space:]]+${name}([^A-Za-z0-9_]|$) ]] ||
      warn "command '${name}' is missing from man/sciebo.1"
  fi
done

# (The old "empty completions/_sciebo description" check is gone: the spec
# requires a non-empty description for every GLOBAL/COMMAND/SUB/OPT row - see
# lib/cli/sciebo.spec's format doc - so scripts/gen-cli.sh can never produce
# an empty one.)

# --- usage_<command> options vs that command's docs section (warning) --------

if [ -f "$ROOT/docs/commands.md" ]; then
  for name in $commands; do
    # `help` prints usage_main and is documented under `## Help`.
    [ "$name" = "help" ] && continue
    usage_body="${USAGE_BODY[$name]:-}"
    [ -n "$usage_body" ] || continue
    # Restrict the check to this command's own `### <name>` section so a flag
    # documented under a different command is flagged.
    section="${DOC_SECTION[$name]:-}"
    [ -n "$section" ] || continue
    while IFS= read -r flag; do
      [ -n "$flag" ] || continue
      # --help is documented once in the global option table, not per command.
      [ "$flag" = "--help" ] && continue
      _drift_has "$section" "$flag" ||
        warn "long option '${flag}' in usage_${name}() is not mentioned in its docs/commands.md section"
    done < <(grep -oE '\-\-[A-Za-z][A-Za-z0-9-]*' <<<"$usage_body" | sort -u)
  done
fi

# --- usage_<command> options vs the man page section (warning) ---------------
# The man page is the exhaustive per-command reference, so a long option that
# a command's usage_<name>() advertises but the man page omits is real drift.
# (The completions are deliberately partial, so they are not checked per
# option.) Only options that begin an indented usage line count, which skips
# the inline `(--log-level ERROR --stats 0)`-style prose. Global options are
# documented once in the man page's global section, so they are exempt here.
if [ -f "$ROOT/man/sciebo.1" ]; then
  global_alias_flags=""
  for spec in "${_SCIEBO_GLOBAL_SPECS[@]}"; do
    spec_first="${spec%%|*}"
    for alias in ${spec_first//,/ }; do
      case "$alias" in -*) global_alias_flags+=" $alias" ;; esac
    done
  done
  for name in $commands; do
    [ "$name" = "help" ] && continue
    usage_body="${USAGE_BODY[$name]:-}"
    [ -n "$usage_body" ] || continue
    # Union every man section whose heading starts with "sciebo <name>", so
    # multi-subcommand commands (folders add/list/..., account ...) are fully
    # covered rather than only their first section.
    man_section="${MAN_SECTION[$name]:-}"
    while IFS= read -r flag; do
      [ -n "$flag" ] || continue
      [ "$flag" = "--help" ] && continue
      case "$global_alias_flags " in *" $flag "*) continue ;; esac
      _drift_has "$man_section" "$flag" ||
        warn "long option '${flag}' in usage_${name}() is not mentioned in man/sciebo.1"
    done < <(grep -oE '^[[:space:]]+--[A-Za-z][A-Za-z0-9-]*' <<<"$usage_body" |
      sed 's/^[[:space:]]*//' | sort -u)
  done
fi

# --- usage_<command> subcommands vs docs/commands.md (warning, best effort) --

if [ -f "$ROOT/docs/commands.md" ]; then
  for name in $commands; do
    # `help` prints usage_main and is documented under `## Help`.
    [ "$name" = "help" ] && continue
    subcommands="$(usage_subcommands "$name")"
    [ -n "$subcommands" ] || continue
    for sub in $subcommands; do
      [ -n "$sub" ] || continue
      _drift_has "$docs_text" "$sub" ||
        warn "subcommand '${sub}' in usage_${name}() is not mentioned in docs/commands.md"
    done
  done
fi

# --- usage_<command> subcommands vs man (warning) ---------------------------
# The commands that dispatch to subcommands name them under a
# Subcommands:/Commands: heading in their usage heredoc; a subcommand missing
# from the man page is a documentation gap. Best effort, and the man page
# escapes option hyphens (copy\-link), so strip backslashes before matching
# it. The completions' own subcommand coverage is checked against
# lib/cli/sciebo.spec by scripts/gen-cli.sh --check instead.
for name in share account folders filters trash config logs; do
  subcommands="$(usage_subcommands "$name")"
  [ -n "$subcommands" ] || continue
  for sub in $subcommands; do
    [ -n "$sub" ] || continue
    if [ "$have_man" -eq 1 ]; then
      _drift_has "$man_plain" "$sub" ||
        warn "subcommand '${sub}' in usage_${name}() is not mentioned in man/sciebo.1"
    fi
  done
done

# --- the spec vs `--help` (warning, hard failures in DRIFT_STRICT) ----------
# lib/cli/sciebo.spec is the single declarative source scripts/gen-cli.sh
# generates the registry and the completions from; this is the check that
# keeps the spec's OPT rows honest against the live implementation (every
# COMMANDS entry is guaranteed to have a COMMAND row - SCIEBO_COMMANDS is
# generated from the spec, so that can no longer drift; gen-cli.sh --check
# is what validates the spec itself). Since a subcommand's own --help just
# reprints its command's whole usage_<name>() text - there is no narrower
# text to compare against - every long option `bin/sciebo <name> --help`
# prints must be one of that command's OPT rows (summed over every
# subcommand, plus the always-available GLOBAL rows) or vice versa. Only
# options that begin an indented usage line count (matching the man-page
# check above), which skips inline prose mentions of another command's flag
# (nextcloudcmd's "--silent, -s errors only (--log-level ERROR --stats 0)",
# schedule's "runs `sciebo sync --apply --quiet`", ...).
spec_file="$ROOT/lib/cli/sciebo.spec"
if [ -f "$spec_file" ]; then
  global_opts=" $(awk -F'|' '$1=="GLOBAL"{print $2}' "$spec_file" |
    tr ',' '\n' | grep -E '^--' | sort -u | tr '\n' ' ') "
  for name in $commands; do
    spec_opts_own=" $(awk -F'|' -v cmd="$name" '$1=="OPT" && $2==cmd{print $4}' "$spec_file" |
      tr ',' '\n' | grep -E '^--' | sort -u | tr '\n' ' ') "
    spec_opts_with_global="${spec_opts_own% }${global_opts}"
    help_text="$("$ROOT/bin/sciebo" "$name" --help 2>/dev/null)"
    help_opts=" $(grep -oE '^[[:space:]]+--[A-Za-z][A-Za-z0-9-]*' <<<"$help_text" |
      sed 's/^[[:space:]]*//' | sort -u | tr '\n' ' ') "
    # help -> spec: every flag the text prints must be a spec option for this
    # command or a global one (nextcloudcmd relists --trust/--non-interactive
    # as its own bullets even though they are already global).
    for flag in $help_opts; do
      case "$spec_opts_with_global" in
        *" $flag "*) ;;
        *)
          if [ "$STRICT" = "1" ]; then
            hard "long option '${flag}' in 'sciebo ${name} --help' is not in lib/cli/sciebo.spec"
          else
            warn "long option '${flag}' in 'sciebo ${name} --help' is not in lib/cli/sciebo.spec"
          fi
          ;;
      esac
    done
    # spec -> help: every one of the command's OWN options (not the globals,
    # which most commands' usage_ text never repeats) must be printed.
    for flag in $spec_opts_own; do
      case "$help_opts" in
        *" $flag "*) ;;
        *)
          if [ "$STRICT" = "1" ]; then
            hard "option '${flag}' in lib/cli/sciebo.spec for '${name}' is not printed by 'sciebo ${name} --help'"
          else
            warn "option '${flag}' in lib/cli/sciebo.spec for '${name}' is not printed by 'sciebo ${name} --help'"
          fi
          ;;
      esac
    done
  done
else
  warn "lib/cli/sciebo.spec not found; skipping the spec/--help drift check"
fi

# --- dead helpers across lib/ (warning) --------------------------------------
# Every helper lib/*.sh and lib/commands/*.sh define should be consumed by the
# code that runs in production. One grep pass over bin/, lib/, and tests/
# feeds an awk map (definition names + identifier occurrences), so the tree is
# scanned once instead of once per helper, and each helper is classified:
#   - referenced in bin/ or lib/    -> production-live, not reported,
#   - referenced only in tests/     -> warning: no production caller,
#   - not referenced anywhere       -> warning: dead helper.
# The reference scope (lib/, bin/, tests/) matches the original core/http
# check; scripts/, completions/, config/, launchd/, and docs/ were never
# counted. check-drift.sh itself sits in scripts/, outside both scopes, so it
# can neither define symbols under lib/ nor count its own patterns as refs.
#
# Exemptions: cmd_*/usage_* are dispatched dynamically by bin/sciebo
# ("cmd_${command}"/"usage_$1") and cleanup_do_* is invoked
# as "cleanup_do_${target}" from lib/commands/cleanup.sh, so an absence of
# literal callers proves nothing for those prefixes. Comment-only lines never
# count as references — including the helper's own doc comment above its
# definition — and neither does a helper's own name() definition occurrence.
# (The old check grepped without -n, so its file:line: comment filter never
# matched and doc-comment first lines silently counted as live references.)
dead_helpers="$(
  (cd "$ROOT" && grep -rInE '[A-Za-z_][A-Za-z0-9_]*' bin lib tests 2>/dev/null || true) |
    awk '
      {
        file = $0
        sub(/:[0-9]+:.*/, "", file)
        line = $0
        sub(/^[^:]*:[0-9]+:/, "", line)
        if (line ~ /^[[:space:]]*#/) next
        if (file ~ /^lib\/[^\/]+\.sh$/ || file ~ /^lib\/[^\/]+\/[^\/]+\.sh$/) {
          if (match(line, /^[A-Za-z_][A-Za-z0-9_]*\(\)/)) {
            name = substr(line, 1, RLENGTH - 2)
            if (name !~ /^(cmd|usage)_/ && name !~ /^cleanup_do_/) def[name] = file
          }
        }
        rest = line
        while (match(rest, /[A-Za-z_][A-Za-z0-9_]*/)) {
          id = substr(rest, RSTART, RLENGTH)
          rest = substr(rest, RSTART + RLENGTH)
          if (index(line, id "()") > 0) continue
          if (file ~ /^tests\//) { thit[id] = 1 } else { phit[id] = 1 }
        }
      }
      END {
        for (name in def) {
          if (name in phit) continue
          if (name in thit) { print def[name] "\t" name "\ttest"; continue }
          print def[name] "\t" name "\tnone"
        }
      }
    ' |
    LC_ALL=C sort
)"
while IFS=$'\t' read -r helper_file helper_name helper_tier; do
  [ -n "${helper_name:-}" ] || continue
  if [ "$helper_tier" = "test" ]; then
    warn "helper '${helper_name}' in ${helper_file} is referenced only from tests/ (no production caller)"
  else
    warn "function '${helper_name}' in ${helper_file} is referenced nowhere"
  fi
done <<<"$dead_helpers"

# --- module-private global prefix vs the naming rule (warning) -------------
# The naming rule in docs/architecture.md's "Shared globals" section: state
# private to one module is prefixed "_<module>_" (module = the file's
# basename without .sh); cross-module state is listed there by name instead
# of hidden behind a misleading module prefix. A file that assigns a
# top-level "_<other>_*" global whose prefix names a *different* module is
# likely misplaced or copied from the wrong file. Best effort: only a
# column-0 assignment counts (shfmt indents every line inside a function, so
# a column-0 line is a real top-level global, never a `local`), heredoc
# bodies (the usage_<name>() text, always `<<'EOF'`/`<<'APPLESCRIPT'` in this
# tree) are skipped so example lines cannot be mistaken for assignments, and
# a coincidental prefix match is possible, so this never fails hard.
module_names="$( (cd "$ROOT" && ls lib/*.sh lib/*/*.sh 2>/dev/null) |
  xargs -n1 basename | sed 's/\.sh$//' | sort -u)"
for lib_file in "$ROOT"/lib/*.sh "$ROOT"/lib/*/*.sh; do
  [ -f "$lib_file" ] || continue
  rel="${lib_file#"$ROOT"/}"
  mod="$(basename "$lib_file" .sh)"
  assigned_vars="$(awk '
    /<<.*EOF/ { skip = "EOF"; next }
    /<<.*APPLESCRIPT/ { skip = "APPLESCRIPT"; next }
    skip != "" { if ($0 == skip) skip = ""; next }
    /^(declare[ \t]+-[A-Za-z]+[ \t]+)?_[A-Za-z][A-Za-z0-9_]*(\+?=|\[)/ { print }
  ' "$lib_file" | sed -E 's/^declare[[:space:]]+-[A-Za-z]+[[:space:]]+//; s/(\+?=|\[).*$//')"
  for var in $assigned_vars; do
    for other in $module_names; do
      [ "$other" != "$mod" ] || continue
      case "$var" in
        "_${other}_"*)
          warn "${rel} assigns \${${var}}, whose _${other}_ prefix names the ${other} module, not ${mod} (see docs/architecture.md's Shared globals table)"
          break
          ;;
      esac
    done
  done
done

# (The previous "command tiers: spec vs `sciebo help`" check is gone:
# scripts/gen-cli.sh --check now validates that usage_main's Commands:/Extra
# commands sections list exactly the spec's core/extra commands, in spec
# order - a stronger check than the tier-only, unordered comparison here.)

printf 'check-drift: %d hard failure(s), %d warning(s)\n' "$hard_failures" "$warnings"
if [ "$hard_failures" -gt 0 ]; then
  exit 1
fi
exit 0
