#!/bin/bash
# output.sh - shared output helpers for --json and table rendering.
#
# Commands that grow a --json flag build the document with these helpers
# instead of printf-ing JSON by hand. Everything is printf/awk only (no jq)
# and every string value is escaped, so server-controlled names cannot
# break the document. An unintended, non-deterministic result is preferred
# over emitting invalid JSON.
#
# Usage:
#   output_mode_set true|false     # from the parsed --json flag
#   output_json_begin              # {
#   output_json_kv NAME VALUE      #   "NAME": "VALUE"
#   output_json_kv_raw NAME JSON   #   "NAME": 123 (caller vouches for JSON)
#   output_json_kv_bool NAME BOOL  #   "NAME": true/false
#   output_json_array_begin NAME   #   "NAME": [
#   output_json_array_string VALUE #     "VALUE"
#   output_json_array_end          #   ]
#   output_json_begin              # (nested object)
#   output_json_end                # }
#
# Text tables share one declarative renderer:
#   output_rows EMPTY ROW_FN MAX HEADER_FMT [VALUE...]  # header + rows + hint
#
# Plain field rendering is shared too:
#   print_field LABEL VALUE          # "LABEL: VALUE", empty VALUE -> "-"
#   label_bool VALUE ON OFF [UNKNOWN]  # one display word per boolean-ish value

OUTPUT_JSON=false
# Stack of container states, topmost first: "1" = no item emitted yet, "0" =
# at least one item emitted. One character per open container.
OUTPUT_JSON_STACK="1"

# output_mode_set VALUE - enable JSON output from a parsed option value.
output_mode_set() {
  case "${1:-false}" in
    true | 1 | yes) OUTPUT_JSON=true ;;
    *) OUTPUT_JSON=false ;;
  esac
  OUTPUT_JSON_STACK="1"
}

output_json_enabled() { [[ "$OUTPUT_JSON" == true ]]; }

# output_json_escape_into VAR TEXT - escape TEXT into VAR without the command
# substitution. Byte-wise (LC_ALL=C) so multi-byte UTF-8 passes through
# unchanged: backslash becomes \\, double quote becomes \", control bytes
# 0x01-0x1F become \u00XX, bytes 0x7F-0x9F become one space, and newlines are
# dropped (the old awk processed the input line by line). Prints nothing; hot
# callers use this to avoid a subshell per value.
output_json_escape_into() {
  local _value="${2-}" _out="" _char="" _code=0 _i=0 _len=0
  local LC_ALL=C
  _value="${_value//$'\n'/}"
  _len=${#_value}
  while ((_i < _len)); do
    _char="${_value:_i:1}"
    case "$_char" in
      "\\") _out+="\\\\" ;;
      '"') _out+="\\\"" ;;
      *)
        printf -v _code '%d' "'$_char"
        if ((_code >= 1 && _code <= 31)); then
          printf -v _char '\\u%04x' "$_code"
          _out+="$_char"
        elif ((_code >= 127 && _code <= 159)); then
          _out+=' '
        else
          _out+="$_char"
        fi
        ;;
    esac
    _i=$((_i + 1))
  done
  printf -v "$1" '%s' "$_out"
}

# _output_json_sep - emit the separator before the next item of the current
# container and mark it as non-empty.
_output_json_sep() {
  case "$OUTPUT_JSON_STACK" in
    1*) OUTPUT_JSON_STACK="0${OUTPUT_JSON_STACK#?}" ;;
    *) printf ',\n' ;;
  esac
}

# output_json_begin - start the document object.
output_json_begin() {
  [[ "$OUTPUT_JSON" == true ]] || return 0
  printf '{\n'
  OUTPUT_JSON_STACK="1"
}

# output_json_end - close the document object.
output_json_end() {
  [[ "$OUTPUT_JSON" == true ]] || return 0
  printf '\n}\n'
}

# output_json_kv NAME VALUE - add a string field to the current object; NAME
# is a trusted key, VALUE is escaped.
output_json_kv() {
  [[ "$OUTPUT_JSON" == true ]] || return 0
  local escaped=""
  output_json_escape_into escaped "${2-}"
  _output_json_sep
  printf '  "%s": "%s"' "$1" "$escaped"
}

# output_json_kv_raw NAME JSON - add a pre-rendered JSON value (number, bool,
# nested object); the caller is responsible for valid JSON.
output_json_kv_raw() {
  [[ "$OUTPUT_JSON" == true ]] || return 0
  _output_json_sep
  printf '  "%s": %s' "$1" "$2"
}

# output_json_kv_bool NAME BOOL - add a boolean field: true when BOOL is `1`
# or `true`, false for anything else. Delegates the separator and the
# OUTPUT_JSON gate to output_json_kv_raw.
output_json_kv_bool() {
  local value=false
  case "${2:-}" in
    1 | true) value=true ;;
  esac
  output_json_kv_raw "$1" "$value"
}

# output_json_array_begin NAME - start an array field in the current object.
output_json_array_begin() {
  [[ "$OUTPUT_JSON" == true ]] || return 0
  _output_json_sep
  printf '  "%s": [' "$1"
  OUTPUT_JSON_STACK="1${OUTPUT_JSON_STACK}"
}

# output_json_array_string VALUE - append a string to the open array.
output_json_array_string() {
  [[ "$OUTPUT_JSON" == true ]] || return 0
  local escaped=""
  output_json_escape_into escaped "${1-}"
  _output_json_sep
  printf '"%s"' "$escaped"
}

# output_json_array_end - close the open array.
output_json_array_end() {
  [[ "$OUTPUT_JSON" == true ]] || return 0
  printf ']'
  OUTPUT_JSON_STACK="${OUTPUT_JSON_STACK#?}"
}

# output_json_object_begin [NAME] - start a nested object: a field named NAME
# in the current object, or a bare array item when NAME is omitted.
output_json_object_begin() {
  [[ "$OUTPUT_JSON" == true ]] || return 0
  _output_json_sep
  [[ -z "${1:-}" ]] || printf '"%s": ' "$1"
  printf '{'
  OUTPUT_JSON_STACK="1${OUTPUT_JSON_STACK}"
}

# output_json_object_end - close a nested object (or an array item object).
output_json_object_end() {
  [[ "$OUTPUT_JSON" == true ]] || return 0
  printf '}'
  OUTPUT_JSON_STACK="${OUTPUT_JSON_STACK#?}"
}

# output_json_list_begin NAME / output_json_list_end - the common
# "one object with a single NAME array" document (list commands, reports).
output_json_list_begin() {
  output_json_begin
  output_json_array_begin "$1"
}

output_json_list_end() {
  output_json_array_end
  output_json_end
}

# output_rows EMPTY ROW_FN MAX HEADER_FMT [HEADER_VALUE...] - declarative text
# table renderer. Reads records from stdin, prints the header (HEADER_FMT with
# the remaining arguments, nothing when HEADER_FMT is empty), then calls
# ROW_FN once per record line: ROW_FN prints the row and returns non-zero to
# skip the record. MAX > 0 stops after that many printed rows (0 = no limit).
# Prints EMPTY (and no hint when rows were printed) when nothing was printed.
# The text is byte-identical to the hand-written header/loop/count/hint blocks.
output_rows() {
  local empty="$1" row_fn="$2" max="${3:-0}" fmt="$4" line="" count=0
  shift 4
  # The column layout is a literal at every call site, so SC2059 does not
  # apply; no caller data reaches the format string.
  # shellcheck disable=SC2059  # fmt is a literal at every call site
  [[ -z "$fmt" ]] || printf "$fmt" "$@"
  while IFS= read -r line; do
    "$row_fn" "$line" || continue
    count=$((count + 1))
    [[ "$max" -eq 0 || "$count" -lt "$max" ]] || break
  done
  [[ "$count" -gt 0 ]] || printf '%s\n' "$empty"
}

# print_field LABEL VALUE - print "LABEL: VALUE"; an empty VALUE prints "-"
# instead. VALUE is printed as given, so the caller decides whether it needs
# printable first.
print_field() {
  local value="${2:-}"
  [[ -n "$value" ]] || value="-"
  printf '%s: %s\n' "$1" "$value"
}

# label_bool VALUE ON OFF [UNKNOWN] - one display word for a boolean-ish
# VALUE: 1 and true print ON, 0 and false print OFF, anything else
# (including empty) prints UNKNOWN. UNKNOWN defaults to OFF's word, so the
# two-word renderers (mount's yes/no, doctor's on/off) pass three arguments;
# pass the 4th when the unknown state differs from OFF - e.g. "" for
# availability words or "null" for JSON literals. Never fails; always
# prints.
label_bool() {
  case "${1:-}" in
    1 | true) printf '%s' "${2:-}" ;;
    0 | false) printf '%s' "${3:-}" ;;
    *) printf '%s' "${4-${3:-}}" ;;
  esac
  return 0
}
