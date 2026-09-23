#!/usr/bin/env bash
# check-drift.sh - detect drift between the CLI's sources of truth.
#
# Hard failures (exit 1):
#   - a name in the COMMANDS string of bin/sciebo has only one of
#     usage_<name>() / cmd_<name>() under lib/commands/,
#   - a key in lib/settings.sh's require_setting call is missing from
#     config/settings.env.
# Warnings (still exit 0):
#   - a COMMANDS entry with neither definition (a planned command; the
#     implemented set may legitimately lag the dispatch list),
#   - a config/settings.env key not mentioned in docs/settings.md or in
#     config/settings.local.env.example,
#   - a COMMANDS entry missing from completions/sciebo.bash,
#     completions/_sciebo, completions/sciebo.fish, or man/sciebo.1,
#   - a docs/commands.md `### <command>` heading that is not in COMMANDS,
#     or a COMMANDS entry (other than `help`) with no such heading,
#   - a global option in bin/sciebo's _SCIEBO_GLOBAL_SPECS not mentioned in
#     completions/_sciebo, docs/commands.md, or man/sciebo.1,
#   - a long option in a command's usage_<name>() heredoc not mentioned in
#     that command's `### <name>` section of docs/commands.md (best effort),
#   - a long option in a command's usage_<name>() heredoc not mentioned in the
#     command's section of the man page (best effort; global options are
#     documented once in the man page's global section and are exempt),
#   - a subcommand named under a `Subcommands:`/`Commands:` heading in a
#     command's usage_<name>() heredoc not mentioned in docs/commands.md
#     (best effort),
#   - an entry in completions/_sciebo's `name:description` lists with an
#     empty description (best effort),
#   - a _SCIEBO_COMMAND_MODULE_SPECS entry whose target file is missing or
#     does not define the mapped cmd_/usage_, or which restates the default
#     module for a single-command file (best effort),
#   - a subcommand named under a `Subcommands:`/`Commands:` heading in a
#     command's usage_<name>() heredoc missing from completions/_sciebo,
#     completions/sciebo.fish, or man/sciebo.1 (best effort),
#   - a function defined in lib/*.sh or lib/commands/*.sh that is referenced
#     nowhere in lib/, bin/, or tests/ (best effort),
#   - a function defined in lib/*.sh or lib/commands/*.sh whose only
#     references are in tests/, i.e. it has no production (lib/, bin/) caller
#     (best effort).
#
# Set DRIFT_STRICT=1 to turn the "planned command" warning into a hard
# failure, which is what a release/CI check wants once every COMMANDS entry
# is implemented.

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

# --- COMMANDS vs usage_/cmd_ definitions ------------------------------------

commands="$(sed -n 's/^COMMANDS="\(.*\)"$/\1/p' "$ROOT/bin/sciebo" | head -n 1)"
if [ -z "$commands" ]; then
  hard "cannot read the COMMANDS string from bin/sciebo"
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
zsh_text=""
fish_text=""
if [ -f "$man_file" ]; then
  have_man=1
  # The man page escapes option hyphens as `\-\-`; strip the backslashes once.
  man_plain="$(sed 's/\\//g' "$man_file")"
fi
[ -f "$ROOT/docs/commands.md" ] && docs_text="$(cat "$ROOT/docs/commands.md")"
[ -f "$ROOT/completions/_sciebo" ] && zsh_text="$(cat "$ROOT/completions/_sciebo")"
[ -f "$ROOT/completions/sciebo.fish" ] && fish_text="$(cat "$ROOT/completions/sciebo.fish")"

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

# --- _SCIEBO_COMMAND_MODULE_SPECS vs lib/commands/ (warning) ----------------
# bin/sciebo resolves each command through the static table in
# _SCIEBO_COMMAND_MODULE_SPECS (default lib/commands/<command>.sh, overrides
# for a module that defines several commands). A stale entry points at a
# missing file or one that no longer defines the mapped cmd_/usage_ function;
# an idempotent entry restates the default for a single-command file. A
# multi-command module lists its namesake command next to the other commands
# it serves, so those self-mappings are expected and not flagged.
module_specs="$(sed -n '/^_SCIEBO_COMMAND_MODULE_SPECS=(/,/^)/p' "$ROOT/bin/sciebo" |
  sed -n "s/^[[:space:]]*'\([^|]*\)|\([^']*\)'.*$/\1|\2/p")"
for spec in $module_specs; do
  spec_name="${spec%%|*}"
  spec_file="${spec#*|}"
  [ -n "$spec_name" ] || continue
  spec_target="$ROOT/lib/commands/${spec_file}"
  if [ ! -f "$spec_target" ]; then
    warn "module spec '${spec_name}|${spec_file}' points to a missing file"
    continue
  fi
  spec_cmds=" $(grep -hoE '^cmd_[A-Za-z0-9_]+\(\)' "$spec_target" 2>/dev/null | sed 's/()$//' | tr '\n' ' ')"
  spec_usages=" $(grep -hoE '^usage_[A-Za-z0-9_]+\(\)' "$spec_target" 2>/dev/null | sed 's/()$//' | tr '\n' ' ')"
  case "$spec_cmds" in
    *" cmd_${spec_name} "*) ;;
    *) warn "module spec '${spec_name}|${spec_file}' does not define cmd_${spec_name}()" ;;
  esac
  case "$spec_usages" in
    *" usage_${spec_name} "*) ;;
    *) warn "module spec '${spec_name}|${spec_file}' does not define usage_${spec_name}()" ;;
  esac
  if [ "$spec_file" = "${spec_name}.sh" ]; then
    spec_other=""
    for spec_defined in $spec_cmds; do
      [ "$spec_defined" = "cmd_${spec_name}" ] || spec_other="$spec_defined"
    done
    [ -n "$spec_other" ] ||
      warn "module spec '${spec_name}|${spec_file}' is idempotent with the default module"
  fi
done

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
' "$ROOT/lib/settings.sh")"

for key in $required_keys; do
  if ! grep -qF "\${${key}:" "$ROOT/config/settings.env" &&
    ! grep -qF "\${${key}}" "$ROOT/config/settings.env"; then
    hard "setting '${key}' is required by lib/settings.sh but missing from config/settings.env"
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

# --- _SCIEBO_GLOBAL_SPECS vs completions and docs (warning) -----------------

if [ -f "$ROOT/completions/_sciebo" ] && [ -f "$ROOT/docs/commands.md" ]; then
  global_specs="$(sed -n '/^_SCIEBO_GLOBAL_SPECS=(/,/^)/p' "$ROOT/bin/sciebo" |
    sed -n "s/^[[:space:]]*'\([^']*\)'.*/\1/p" | sed 's/|.*//')"
  for spec in $global_specs; do
    # A spec is a comma-separated alias list; every alias must be documented.
    IFS=',' read -r -a flags <<<"$spec"
    for flag in "${flags[@]}"; do
      [ -n "$flag" ] || continue
      _drift_has "$zsh_text" "$flag" ||
        warn "global option '${flag}' is in _SCIEBO_GLOBAL_SPECS but not mentioned in completions/_sciebo"
      _drift_has "$docs_text" "$flag" ||
        warn "global option '${flag}' is in _SCIEBO_GLOBAL_SPECS but not mentioned in docs/commands.md"
      if [ "$have_man" -eq 1 ]; then
        _drift_has "$man_plain" "$flag" ||
          warn "global option '${flag}' is in _SCIEBO_GLOBAL_SPECS but not mentioned in man/sciebo.1"
      fi
    done
  done
else
  warn "completions/_sciebo or docs/commands.md not found; skipping the global-option check"
fi

# --- COMMANDS vs completions and man page (warning) -------------------------

bash_commands="$(sed -n "s/^_sciebo_commands='\(.*\)'$/\1/p" "$ROOT/completions/sciebo.bash" | head -n 1)"
# The zsh command list is an array of 'name:description' entries.
zsh_commands="$(sed -n '/^_sciebo_commands=(/,/^)/p' "$ROOT/completions/_sciebo" |
  sed -n "s/^[[:space:]]*'\([A-Za-z0-9_-]*\):.*/\1/p" | tr '\n' ' ')"
# The fish command list is the body of __fish_sciebo_commands; extra tokens
# (function, printf, ...) are harmless because only COMMANDS names are looked
# up in it.
fish_commands="$(sed -n '/^function __fish_sciebo_commands/,/^end/p' "$ROOT/completions/sciebo.fish" |
  grep -oE '[A-Za-z][A-Za-z0-9_-]+' | tr '\n' ' ')"

for name in $commands; do
  case " $bash_commands " in
    *" $name "*) ;;
    *) warn "command '${name}' is missing from completions/sciebo.bash" ;;
  esac
  case " $zsh_commands " in
    *" $name "*) ;;
    *) warn "command '${name}' is missing from completions/_sciebo" ;;
  esac
  case " $fish_commands " in
    *" $name "*) ;;
    *) warn "command '${name}' is missing from completions/sciebo.fish" ;;
  esac
  if [ "$have_man" -eq 1 ]; then
    [[ "$man_plain" =~ sciebo[[:space:]]+${name}([^A-Za-z0-9_]|$) ]] ||
      warn "command '${name}' is missing from man/sciebo.1"
  fi
done

# --- completion name:description entries (warning, best effort) --------------

# The zsh completion lists commands and subcommands as 'name:description'
# entries. An empty description is almost always a mistake.
if [ -f "$ROOT/completions/_sciebo" ]; then
  empty_completion_desc="$(sed -nE "s/^[[:space:]]*'([A-Za-z][A-Za-z0-9_-]*):'[[:space:]]*$/\1/p" \
    "$ROOT/completions/_sciebo")"
  for name in $empty_completion_desc; do
    warn "completion entry '${name}:' in completions/_sciebo has an empty description"
  done
fi

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
  while IFS= read -r spec; do
    spec_first="${spec%%|*}"
    for alias in ${spec_first//,/ }; do
      case "$alias" in -*) global_alias_flags+=" $alias" ;; esac
    done
  done < <(sed -n '/^_SCIEBO_GLOBAL_SPECS=(/,/^)/p' "$ROOT/bin/sciebo" |
    sed -n "s/^[[:space:]]*'\([^']*\)'.*/\1/p")
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

# --- usage_<command> subcommands vs completions and man (warning) -----------
# The commands that dispatch to subcommands name them under a
# Subcommands:/Commands: heading in their usage heredoc; a subcommand the user
# cannot complete or look up is a documentation gap. Best effort, and the man
# page escapes option hyphens (copy\-link), so strip backslashes before
# matching it.
for name in share account folders filters trash config logs; do
  subcommands="$(usage_subcommands "$name")"
  [ -n "$subcommands" ] || continue
  for sub in $subcommands; do
    [ -n "$sub" ] || continue
    if [ -n "$zsh_text" ]; then
      _drift_has "$zsh_text" "$sub" ||
        warn "subcommand '${sub}' in usage_${name}() is not mentioned in completions/_sciebo"
    fi
    if [ -n "$fish_text" ]; then
      _drift_has "$fish_text" "$sub" ||
        warn "subcommand '${sub}' in usage_${name}() is not mentioned in completions/sciebo.fish"
    fi
    if [ "$have_man" -eq 1 ]; then
      _drift_has "$man_plain" "$sub" ||
        warn "subcommand '${sub}' in usage_${name}() is not mentioned in man/sciebo.1"
    fi
  done
done

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
# ("cmd_${command}"/"usage_$1", probed by have_function, and located by
# _sciebo_module_path's ^cmd_NAME() content grep) and cleanup_do_* is invoked
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
        if (file ~ /^lib\/[^\/]+\.sh$/ || file ~ /^lib\/commands\/[^\/]+\.sh$/) {
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

printf 'check-drift: %d hard failure(s), %d warning(s)\n' "$hard_failures" "$warnings"
if [ "$hard_failures" -gt 0 ]; then
  exit 1
fi
exit 0
