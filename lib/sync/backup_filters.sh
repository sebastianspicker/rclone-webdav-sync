#!/bin/bash
# backup_filters.sh - translate rclone filter files into restic exclude files.
#
# Only the exclude subset of rclone's filter syntax is supported, so a filter
# can never silently include more than the user expects (see
# RESTIC_INTEGRATION_PLAN.md section 4.4). Every other construct is an error
# reported as FILE:LINE: message.

# _backup_filter_escape_literal_into VAR TEXT - escape the characters restic's
# exclude matcher treats as special (\ * ? [) so a source path stays literal.
_backup_filter_escape_literal_into() {
  local s="$2"
  s="${s//\\/\\\\}"
  s="${s//\*/\\*}"
  s="${s//\?/\\?}"
  s="${s//\[/\\[}"
  printf -v "$1" '%s' "$s"
}

# backup_filter_translate SRC LOCAL DEST - read the rclone filter file SRC and
# write restic exclude patterns to DEST (the caller created it). A pattern
# anchored with a leading / becomes LOCAL/rest, because rclone anchors to the
# source root and restic to /. Every `$` is doubled, since restic expands
# environment variables in exclude files. Unsupported lines (include rules,
# `!`, alternation, a missing space after the minus, empty patterns) print
# SRC:LINE: message to stderr; the whole file is still processed so every
# error is listed, and the function then returns 1.
backup_filter_translate() {
  local src="$1" local_root="${2%/}" dest="$3"
  local raw="" line="" pat="" out="" lineno=0 errors=0 lit=""
  _backup_filter_escape_literal_into lit "$local_root"
  lit="${lit//\$/\$\$}"
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    lineno=$((lineno + 1))
    trim_into line "$raw"
    case "$line" in
      '' | '#'* | ';'*) continue ;;
      '!')
        printf '%s:%d: "!" (clear rules) has no restic equivalent\n' "$src" "$lineno" >&2
        errors=$((errors + 1))
        continue
        ;;
      '+' | '+ '*)
        printf '%s:%d: include rules ("+") are not supported for backups; use exclude rules only\n' "$src" "$lineno" >&2
        errors=$((errors + 1))
        continue
        ;;
      '-')
        printf '%s:%d: empty pattern\n' "$src" "$lineno" >&2
        errors=$((errors + 1))
        continue
        ;;
      '- '*) ;;
      '-'* | '+'*)
        printf '%s:%d: write "- pattern" with a space after the minus (got "%s")\n' "$src" "$lineno" "${ printable "$line";}" >&2
        errors=$((errors + 1))
        continue
        ;;
      *)
        printf '%s:%d: unsupported rule "%s" (only "- pattern" exclude rules)\n' "$src" "$lineno" "${ printable "$line";}" >&2
        errors=$((errors + 1))
        continue
        ;;
    esac
    trim_into pat "${line#- }"
    if [[ "$pat" == *"{"* || "$pat" == *"}"* ]]; then
      printf '%s:%d: alternation {a,b} has no restic equivalent; split the rule by hand\n' "$src" "$lineno" >&2
      errors=$((errors + 1))
      continue
    fi
    while [[ "$pat" == */ ]]; do pat="${pat%/}"; done
    case "$pat" in
      '!'* | '#'*)
        # restic reads a leading "!" as a re-include and "#" as a comment, so
        # the rule would silently exclude nothing.
        printf '%s:%d: pattern "%s" would start with %s, which restic treats specially\n' "$src" "$lineno" "${ printable "$pat";}" "${pat:0:1}" >&2
        errors=$((errors + 1))
        continue
        ;;
    esac
    if [[ -z "$pat" || "$pat" == "/" ]]; then
      printf '%s:%d: empty pattern\n' "$src" "$lineno" >&2
      errors=$((errors + 1))
      continue
    fi
    pat="${pat//\$/\$\$}"
    if [[ "$pat" == /* ]]; then
      pat="${lit}${pat}"
    fi
    out+="${pat}"$'\n'
  done <"$src"
  printf '%s' "$out" >"$dest" || return 1
  [[ "$errors" -eq 0 ]]
}

# backup_filter_check SRC - translate SRC into a throwaway temp file to
# validate it (doctor, list). Prints the same SRC:LINE: errors; rc 1 on any.
backup_filter_check() {
  local tmp="" rc=0
  temp_mktemp_into tmp "${TMPDIR:-/tmp}/sciebo-bfilter.XXXXXX" || return 1
  backup_filter_translate "$1" "/" "$tmp" || rc=$?
  temp_discard "$tmp"
  return "$rc"
}

# backup_filter_resolve NAME - print the path of filter file NAME in
# FILTER_DIR. Returns 1 for an unsafe name or a missing file.
backup_filter_resolve() {
  safe_filter_name "$1" || return 1
  [[ -f "${FILTER_DIR}/${1}" ]] || return 1
  printf '%s' "${FILTER_DIR}/${1}"
}
