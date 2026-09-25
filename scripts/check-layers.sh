#!/usr/bin/env bash
# scripts/check-layers.sh - enforce the lib/ layering described in
# docs/architecture.md. Static and best effort: it sees functions called by
# name in code, not calls built at runtime ("cmd_$name", callbacks passed by
# name), which are the documented dispatch conventions.
#
# Rules (each violation prints file:line and fails):
#   1. A file may call functions defined in its own layer or a lower one.
#      Rank: base < adapters < config < state < sync < cli < commands.
#   2. A command module never calls a function defined in another command
#      module (shared logic belongs in lib/).
#   3. Only lib/sciebo.sh sources library code. A line may opt out with a
#      trailing "# layers: allow-source" (settings files read through
#      safe_source).
#   4. Library files do no settings work at source time: no top-level
#      `: "${VAR:=...}"` defaults.
#   5. Top-level array declarations are global (`declare -gA`/`-ga`), so a
#      module behaves the same whichever scope sources it.
#   6. awk programs built on the shared byte-oriented preludes
#      (_AWK_CTRL_LIB, _AWK_HTML_LIB, _AWK_XML_LIB) run under LC_ALL=C; in a
#      UTF-8 locale gawk turns decoded bytes into characters.
set -euo pipefail

ROOT="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
cd "$ROOT"

LAYERS=(base adapters config state sync cli commands)
files=()
for layer in "${LAYERS[@]}"; do
  for f in lib/"$layer"/*.sh; do
    [[ -e "$f" ]] && files+=("$f")
  done
done
((${#files[@]} > 0)) || {
  echo "check-layers: no layered files under lib/" >&2
  exit 1
}

# One awk pass over every file: strip comments, heredoc bodies and
# single-quoted multi-line strings (embedded awk programs), collect function
# definitions, then report cross-file references against the layer ranks.
awk -v layers="${LAYERS[*]}" '
function layer_of(path,   parts) {
  split(path, parts, "/")
  return parts[2]
}
function strip(line,   out, i, c, inq) {
  # Drop a trailing comment that is not inside quotes, and the contents of
  # single-quoted strings (their text is data, not calls).
  out = ""; inq = 0
  for (i = 1; i <= length(line); i++) {
    c = substr(line, i, 1)
    if (insq) {
      if (c == "\047") insq = 0
      continue
    }
    if (c == "\047" && !indq) { insq = 1; continue }
    if (c == "\"" && substr(line, i - 1, 1) != "\\") indq = !indq
    if (c == "#" && !indq && (i == 1 || substr(line, i - 1, 1) ~ /[ \t;(]/)) break
    out = out c
  }
  return out
}
BEGIN {
  n = split(layers, L, " ")
  for (i = 1; i <= n; i++) rank[L[i]] = i
}
FNR == 1 { heredoc = ""; insq = 0; indq = 0; depth = 0 }
{
  raw = $0
  if (heredoc != "") {
    t = raw; sub(/^[\t]+/, "", t)
    if (t == heredoc) heredoc = ""
    next
  }
  wasq = insq
  hd = ""
  if (!insq && match(raw, /<<-?[ ]*["\047]?[A-Za-z_]+["\047]?/)) {
    hd = substr(raw, RSTART, RLENGTH)
    gsub(/<<-?[ ]*|["\047]/, "", hd)
  }
  code = strip(raw)
  indq = 0
  if (hd != "") heredoc = hd
  if (match(code, /^[ \t]*(function[ \t]+)?[A-Za-z_][A-Za-z0-9_]*[ \t]*\(\)/)) {
    name = code
    sub(/^[ \t]*(function[ \t]+)?/, "", name)
    sub(/[ \t]*\(\).*/, "", name)
    def[name] = FILENAME
    deflayer[name] = layer_of(FILENAME)
    if (code ~ /\{[ \t]*$/ || code ~ /\{/) depth = 1
  }
  if (layer_of(FILENAME) != "commands" && FILENAME != "lib/sciebo.sh") {
    top = (raw !~ /^[ \t]/ && !wasq)
    if (top && code ~ /^:[ \t]+"\$\{[A-Za-z_][A-Za-z0-9_]*:=/)
      printf "%s:%d: rule 4: source-time settings default: %s\n", FILENAME, FNR, raw
  }
  if (!wasq && raw !~ /^[ \t]/ && code ~ /^declare[ \t]+-[a-zA-Z]*[aA]/ && code !~ /^declare[ \t]+-[a-zA-Z]*g/)
    printf "%s:%d: rule 5: top-level array must be declared with -g: %s\n", FILENAME, FNR, raw
  bare = code
  gsub(/"([^"\\]|\\.)*"/, "\"\"", bare)
  if (bare ~ /(^|[;&|{]|then|do|else)[ \t]*(source|\.)[ \t]+[^ \t|)]/ && raw !~ /# layers: allow-source/)
    printf "%s:%d: rule 3: only lib/sciebo.sh sources library code: %s\n", FILENAME, FNR, raw
  lines[FILENAME, FNR] = code
  count[FILENAME] = FNR
  order[++nf] = FILENAME
}
END {
  for (k = 1; k <= nf; k++) {
    f = order[k]
    if (seen[f]++) continue
    fl = layer_of(f)
    for (ln = 1; ln <= count[f]; ln++) {
      code = lines[f, ln]
      while (match(code, /[A-Za-z_][A-Za-z0-9_]*/)) {
        tok = substr(code, RSTART, RLENGTH)
        code = substr(code, RSTART + RLENGTH)
        if (!(tok in def) || def[tok] == f) continue
        dl = deflayer[tok]
        if (fl == "commands" && dl == "commands")
          printf "%s:%d: rule 2: command module calls %s from %s\n", f, ln, tok, def[tok]
        else if (rank[dl] > rank[fl])
          printf "%s:%d: rule 1: %s layer calls %s from higher layer %s (%s)\n", f, ln, fl, tok, dl, def[tok]
      }
    }
  }
}
' "${files[@]}" | sort -u | tee /dev/stderr | { ! grep -q .; } || {
  echo "check-layers: violations found (see docs/architecture.md#layers)" >&2
  exit 1
}
# Rule 6: a line that runs awk with one of the shared preludes must set
# LC_ALL=C on that command (comment lines excluded).
prelude_violations="$(grep -nE 'awk[^|]*"\$\{_AWK_(CTRL|HTML|XML)_LIB\}' "${files[@]}" lib/sciebo.sh |
  grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | grep -v 'LC_ALL=C awk' || true)"
if [[ -n "$prelude_violations" ]]; then
  printf '%s\n' "$prelude_violations" | sed 's/$/  <- rule 6: run shared awk preludes under LC_ALL=C/' >&2
  echo "check-layers: violations found (see docs/architecture.md#layers)" >&2
  exit 1
fi
echo "check-layers: ${#files[@]} files, no violations"
