#!/bin/bash
# text.sh - pure text helpers: trimming, XML/HTML escaping and stripping,
# control-byte and UTF-8 sanitizing, name/size/URL parsing and formatting,
# and the positional-argument/record splitters.
#
# Sourced by lib/base/core.sh. Every function here is a pure function of its
# arguments (config_lines is the one exception: it reads the file it is
# given); none of them touch the network or write files.

# config_lines FILE - print the non-blank, non-comment lines of a config
# file (the manifest, roots, and doctor readers share this convention).
config_lines() {
  awk 'NF && $0 !~ /^[[:space:]]*#/' "$1"
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# trim_into VAR VALUE - trim VALUE into VAR without a command substitution.
# Hot callers (manifest_parse_line) use this to avoid a subshell per field.
trim_into() {
  local s="$2"
  s="${s#"${s%%[![:space:]]*}"}"
  printf -v "$1" '%s' "${s%"${s##*[![:space:]]}"}"
}

# xml_escape_into VAR TEXT [all] - XML-escape TEXT into VAR without a command
# substitution. The default escapes the element-body metacharacters & < >; the
# literal mode "all" also escapes the attribute quote characters " and '. The
# two callers keep their own wrapper (nc_xml_escape escapes quotes,
# schedule_xml_escape does not), so the entity spellings stay identical.
# patsub_replacement is on by default in Bash 5.2+, so a literal "&" in a
# replacement must be written "\&" or it would expand to the matched text.
xml_escape_into() {
  local _xe_s="${2:-}"
  _xe_s="${_xe_s//&/\&amp;}"
  _xe_s="${_xe_s//</\&lt;}"
  _xe_s="${_xe_s//>/\&gt;}"
  if [[ "${3:-}" == "all" ]]; then
    _xe_s="${_xe_s//\"/\&quot;}"
    _xe_s="${_xe_s//\'/\&apos;}"
  fi
  printf -v "$1" '%s' "$_xe_s"
}

# printable NAME - strip C0 and C1 control bytes before showing
# server-controlled names (remote folders) so they cannot emit terminal
# escape sequences. Display only; never use this for values passed back to
# rclone. Byte semantics (LC_ALL=C) so the explicit 0x80-0x9F range matches;
# TAB and newline are stripped like every other C0 byte.
printable() {
  # UTF-8-aware: drops C0/DEL, encoded/stray C1 bytes, and malformed UTF-8
  # but keeps valid multi-byte characters, so server-controlled names cannot
  # inject terminal escapes without corrupting non-ASCII names.
  strip_control_bytes "$1"
}

# _AWK_CTRL_LIB - the shared awk UTF-8 control stripper. ctrl_strip(s, KEEP)
# drops C0 control bytes and DEL (keeping TAB 0x09 and LF 0x0A only when KEEP
# is 1, which sanitize_stream wants and the XML/secret scrubbers do not),
# encoded C1 (a valid C2 80..C2 9F two-byte sequence for U+0080..U+009F, e.g.
# the 8-bit CSI 0x9B), and invalid UTF-8, while preserving valid 2/3/4-byte
# sequences. The exact byte rules:
#   - C0/C1 0xC0-0xC1 are invalid leads (overlong two-byte forms),
#   - a three-byte E0 requires the second byte A0..BF (no overlong),
#   - ED requires the second byte 80..9F (no UTF-16 surrogates),
#   - a four-byte F0 requires the second byte 90..BF (no overlong),
#   - F4 requires the second byte 80..8F (no codepoints above U+10FFFF),
#   - stray continuation bytes 0x80-0xBF and 0xF5-0xFF are dropped.
# A malformed sequence is removed with its continuation run, so e.g.
# ED A0 80 and F4 90 80 80 disappear whole.
#
# At LC_ALL=C, BWK awk exposes byte semantics, so the C-locale hot path
# removes C0/DEL and encoded C1 with whole-string gsub passes (C speed, so a
# huge ASCII line never enters the per-byte loop) and only scans when a high
# byte remains; that scan reads bytes via split (O(1) each) and emits runs
# with substr, so a 1MB line stays linear instead of the old O(n^2)
# `out = out c`. Under a UTF-8 locale, regex and split reject the invalid
# bytes this function exists to remove (BWK awk: "multibyte conversion
# failure"), so ctrl_strip falls back to a regex-free byte scan. Compose as
# `LC_ALL=C awk "${_AWK_CTRL_LIB}"'<program>'`; sanitize_stream and the HTTP scrubbers
# pass LC_ALL=C for the fast path.
_AWK_CTRL_LIB='
function ctrl_build(    i) {
  if (ctrl_ready) return
  ctrl_ready = 1
  for (i = 1; i <= 31; i++) ctrl_c0 = ctrl_c0 sprintf("%c", i)
  ctrl_c0 = ctrl_c0 sprintf("%c", 127)
  for (i = 128; i <= 191; i++) ctrl_cont = ctrl_cont sprintf("%c", i)
  for (i = 128; i <= 159; i++) ctrl_cont_80_9f = ctrl_cont_80_9f sprintf("%c", i)
  for (i = 128; i <= 143; i++) ctrl_cont_80_8f = ctrl_cont_80_8f sprintf("%c", i)
  for (i = 144; i <= 191; i++) ctrl_cont_90_bf = ctrl_cont_90_bf sprintf("%c", i)
  for (i = 160; i <= 191; i++) ctrl_cont_a0_bf = ctrl_cont_a0_bf sprintf("%c", i)
  for (i = 194; i <= 223; i++) ctrl_lead2 = ctrl_lead2 sprintf("%c", i)
  for (i = 224; i <= 239; i++) ctrl_lead3 = ctrl_lead3 sprintf("%c", i)
  for (i = 240; i <= 244; i++) ctrl_lead4 = ctrl_lead4 sprintf("%c", i)
  ctrl_lead_c2 = sprintf("%c", 194)
  ctrl_lead_e0 = sprintf("%c", 224)
  ctrl_lead_ed = sprintf("%c", 237)
  ctrl_lead_f0 = sprintf("%c", 240)
  ctrl_lead_f4 = sprintf("%c", 244)
  ctrl_bad_high = sprintf("%c%c", 192, 193)
  for (i = 245; i <= 255; i++) ctrl_bad_high = ctrl_bad_high sprintf("%c", i)
  # Byte-range regexes are kept as strings (dynamic regexes) rather than
  # /.../ literals: gawk compiles literals when it parses the program and, in
  # a UTF-8 locale, rejects these byte ranges ("Invalid collation character")
  # before ctrl_in_c_locale can route around them. They are only used in C.
  ctrl_re_c0_keep = "[\001-\010\013-\037\177]"
  ctrl_re_c0_all = "[\001-\037\177]"
  ctrl_re_c1 = "\302[\200-\237]"
  ctrl_re_high = "[\200-\377]"
}
# ctrl_in_c_locale() - true when awk runs with byte semantics, so the
# regex/split fast path is safe. POSIX awk derives its locale from LC_ALL,
# else LC_CTYPE, else LANG; an unset locale is the C locale.
function ctrl_in_c_locale(    l) {
  l = ENVIRON["LC_ALL"]
  if (l == "") l = ENVIRON["LC_CTYPE"]
  if (l == "") l = ENVIRON["LANG"]
  return (l == "" || l == "C" || l == "POSIX")
}
# ctrl_strip_bytes(s, keep_tab_lf) - the locale-agnostic fallback: byte-wise
# substr/index only (no regex or split), for the XML parsers that run under
# the caller locale on small field values.
function ctrl_strip_bytes(s, keep_tab_lf,    i, n, c, start, out, need, j, b2, ok) {
  ctrl_build()
  out = ""
  n = length(s)
  start = 1
  i = 1
  while (i <= n) {
    c = substr(s, i, 1)
    if (index(ctrl_c0, c) > 0) {
      if (keep_tab_lf == 1 && (c == "\t" || c == "\n")) {
        i++
        continue
      }
    } else if (index(ctrl_cont, c) > 0 || index(ctrl_bad_high, c) > 0) {
      # drop below
    } else {
      need = 0
      if (index(ctrl_lead2, c) > 0) need = 1
      else if (index(ctrl_lead3, c) > 0) need = 2
      else if (index(ctrl_lead4, c) > 0) need = 3
      if (need > 0) {
        ok = (i + need <= n)
        for (j = 1; ok && j <= need; j++) {
          if (index(ctrl_cont, substr(s, i + j, 1)) == 0) ok = 0
        }
        if (ok) {
          b2 = substr(s, i + 1, 1)
          if (c == ctrl_lead_c2 && index(ctrl_cont_80_9f, b2) > 0) ok = 0
          else if (c == ctrl_lead_e0 && index(ctrl_cont_a0_bf, b2) == 0) ok = 0
          else if (c == ctrl_lead_ed && index(ctrl_cont_80_9f, b2) == 0) ok = 0
          else if (c == ctrl_lead_f0 && index(ctrl_cont_90_bf, b2) == 0) ok = 0
          else if (c == ctrl_lead_f4 && index(ctrl_cont_80_8f, b2) == 0) ok = 0
        }
        if (ok) {
          i += 1 + need
          continue
        }
        if (i > start) out = out substr(s, start, i - start)
        i++
        while (i <= n && index(ctrl_cont, substr(s, i, 1)) > 0) i++
        start = i
        continue
      }
      i++
      continue
    }
    if (i > start) out = out substr(s, start, i - start)
    i++
    start = i
  }
  if (n >= start) out = out substr(s, start, n - start + 1)
  return out
}
function ctrl_strip(s, keep_tab_lf,    i, n, a, c, start, out, need, j, b2, ok) {
  ctrl_build()
  if (!ctrl_in_c_locale()) return ctrl_strip_bytes(s, keep_tab_lf)
  if (keep_tab_lf == 1) gsub(ctrl_re_c0_keep, "", s)
  else gsub(ctrl_re_c0_all, "", s)
  gsub(ctrl_re_c1, "", s)
  if (s !~ ctrl_re_high) return s
  n = split(s, a, "")
  out = ""
  start = 1
  i = 1
  while (i <= n) {
    c = a[i]
    if (index(ctrl_cont, c) > 0 || index(ctrl_bad_high, c) > 0) {
      if (i > start) out = out substr(s, start, i - start)
      i++
      start = i
      continue
    }
    need = 0
    if (index(ctrl_lead2, c) > 0) need = 1
    else if (index(ctrl_lead3, c) > 0) need = 2
    else if (index(ctrl_lead4, c) > 0) need = 3
    if (need > 0) {
      ok = (i + need <= n)
      for (j = 1; ok && j <= need; j++) {
        if (index(ctrl_cont, a[i + j]) == 0) ok = 0
      }
      if (ok) {
        b2 = a[i + 1]
        if (c == ctrl_lead_c2 && index(ctrl_cont_80_9f, b2) > 0) ok = 0
        else if (c == ctrl_lead_e0 && index(ctrl_cont_a0_bf, b2) == 0) ok = 0
        else if (c == ctrl_lead_ed && index(ctrl_cont_80_9f, b2) == 0) ok = 0
        else if (c == ctrl_lead_f0 && index(ctrl_cont_90_bf, b2) == 0) ok = 0
        else if (c == ctrl_lead_f4 && index(ctrl_cont_80_8f, b2) == 0) ok = 0
      }
      if (ok) {
        i += 1 + need
        continue
      }
      if (i > start) out = out substr(s, start, i - start)
      i++
      while (i <= n && index(ctrl_cont, a[i]) > 0) i++
      start = i
      continue
    }
    i++
  }
  if (n >= start) out = out substr(s, start, n - start + 1)
  return out
}
'

# sanitize_stream - filter stdin, dropping C0 control bytes (including ESC and
# CR), DEL, encoded C1 (C2 80-9F), stray C1 bytes, and invalid UTF-8
# lead/continuation bytes while preserving valid 2/3/4-byte UTF-8 sequences, so
# server- or rclone-derived multi-line output cannot inject terminal escape
# sequences (a bare CR can move the cursor and overwrite an earlier line). awk
# reads line by line, so newlines are preserved, and TAB is kept because
# indented listings rely on it. One LC_ALL=C awk pass (one process) over the
# shared _AWK_CTRL_LIB, so strip_control_bytes and the http scrubbers share
# the exact byte rules.
sanitize_stream() {
  LC_ALL=C awk "${_AWK_CTRL_LIB}"'
    { print ctrl_strip($0, 1) }
  '
}

# format_size_bytes BYTES [STYLE] - compact human size for display; a
# non-numeric value is printed unchanged for every style. Pure bash so hot
# callers (conflicts, cleanup, logs) do not fork awk per row. STYLE selects
# the rendering:
#   (unset), "", iec  the report style: 512B, 1.0KiB, 3.4MiB, 12GiB -
#                     byte-identical to the original single-argument form
#   rclone            the way rclone writes SizeSuffix values: an exact
#                     binary multiple as an integer with Ki/Mi/Gi
#                     (104857600 -> 100Mi, 2048 -> 2Ki), any other count
#                     as the plain byte count (1536 -> 1536) - what
#                     capabilities_size_label delegates to
#   bytes             the unscaled count with a B suffix (2048 -> 2048B),
#                     the raw bigfolder fallback without capabilities.sh
# Any other STYLE behaves like the default (iec).
format_size_bytes() {
  local bytes="${1:-}" style="${2:-}" units=(B KiB MiB GiB TiB)
  case "$bytes" in
    '' | *[!0-9]*) printf '%s' "$bytes" && return 0 ;;
  esac
  # Strip leading zeros so the arithmetic below is base 10: bash reads a
  # leading 0 as octal (01000 -> 512) and rejects 089 outright. A server
  # size with leading zeros is unusual but must not render as a wrong or
  # error value.
  while [[ "$bytes" == 0* && ${#bytes} -gt 1 ]]; do bytes="${bytes#0}"; done
  case "$style" in
    rclone)
      local value="$bytes" unit=""
      if [[ "$bytes" -ge 1073741824 && $((bytes % 1073741824)) -eq 0 ]]; then
        value=$((bytes / 1073741824))
        unit=Gi
      elif [[ "$bytes" -ge 1048576 && $((bytes % 1048576)) -eq 0 ]]; then
        value=$((bytes / 1048576))
        unit=Mi
      elif [[ "$bytes" -ge 1024 && $((bytes % 1024)) -eq 0 ]]; then
        value=$((bytes / 1024))
        unit=Ki
      fi
      printf '%s%s' "$value" "$unit"
      return 0
      ;;
    bytes)
      printf '%sB' "$bytes"
      return 0
      ;;
  esac
  local unit=0 value="$bytes" divisor=1 i whole=0 rem=0 tenths=0
  while ((value >= 1024 && unit < 4)); do
    value=$((value / 1024))
    unit=$((unit + 1))
  done
  if ((unit == 0)); then
    printf '%d%s' "$value" "${units[unit]}"
    return 0
  fi
  for ((i = 0; i < unit; i++)); do divisor=$((divisor * 1024)); done
  whole=$((bytes / divisor))
  rem=$((bytes % divisor))
  tenths=$(((rem * 10 + divisor / 2) / divisor))
  if ((tenths >= 10)); then
    whole=$((whole + 1))
    tenths=0
  fi
  if ((whole >= 10)); then
    printf '%d%s' "$whole" "${units[unit]}"
  else
    printf '%d.%d%s' "$whole" "$tenths" "${units[unit]}"
  fi
  return 0
}

# strip_control_bytes TEXT - the pure-bash twin of the awk ctrl_strip(s, 0):
# remove C0/DEL control bytes, encoded C1 (the two-byte C2 80..C2 9F forms for
# U+0080..U+009F) and stray C1 bytes (0x80-0x9F), while preserving valid UTF-8
# multi-byte sequences. The same corrected UTF-8 rules apply:
#   - C0/C1 0xC0-0xC1 are invalid leads (overlong two-byte forms),
#   - a three-byte E0 requires the second byte A0..BF,
#   - ED requires the second byte 80..9F (no surrogates),
#   - a four-byte F0 requires the second byte 90..BF,
#   - F4 requires the second byte 80..8F,
#   - a malformed sequence is dropped with its continuation run, so ED A0 80
#     and F4 90 80 80 disappear whole.
# A lone 0xA0-0xBF or 0xF5-0xFF byte is not a control and stays, exactly as
# before (only the 0x80-0x9F range is a terminal control under Latin-1).
# Byte-wise and forkless via LC_ALL=C and single-byte substring expansion.
# Used by percent_decode so a decoded %0A/%0D cannot split a record and a
# decoded %9B cannot inject a terminal control, without corrupting multi-byte
# names such as "grüße".
strip_control_bytes() {
  local s="${1:-}" out="" i=0 n=0 b="" b2="" need=0 ok=0 j=0
  local LC_ALL=C
  n=${#s}
  while ((i < n)); do
    b="${s:i:1}"
    need=0
    case "$b" in
      [$'\302'-$'\337']) need=1 ;;
      [$'\340'-$'\357']) need=2 ;;
      [$'\360'-$'\364']) need=3 ;;
    esac
    if ((need > 0)); then
      ok=1
      for ((j = 1; j <= need; j++)); do
        if ((i + j >= n)) || [[ "${s:i+j:1}" != [$'\200'-$'\277'] ]]; then
          ok=0
          break
        fi
      done
      if ((ok)); then
        b2="${s:i+1:1}"
        case "$b" in
          $'\302') if [[ "$b2" == [$'\200'-$'\237'] ]]; then ok=0; fi ;;
          $'\340') if [[ "$b2" == [$'\200'-$'\237'] ]]; then ok=0; fi ;;
          $'\355') if [[ "$b2" == [$'\240'-$'\277'] ]]; then ok=0; fi ;;
          $'\360') if [[ "$b2" != [$'\220'-$'\277'] ]]; then ok=0; fi ;;
          $'\364') if [[ "$b2" != [$'\200'-$'\217'] ]]; then ok=0; fi ;;
        esac
      fi
      if ((ok)); then
        out+="${s:i:1+need}"
        i=$((i + 1 + need))
        continue
      fi
      # A malformed sequence is dropped with the continuation run that
      # follows it, so its bytes cannot survive as a stray C1 byte.
      i=$((i + 1))
      while ((i < n)); do
        [[ "${s:i:1}" == [$'\200'-$'\277'] ]] || break
        i=$((i + 1))
      done
      continue
    fi
    case "$b" in
      [$'\300'-$'\301']) # C0/C1: overlong lead, not a valid UTF-8 start
        i=$((i + 1))
        continue
        ;;
      [[:cntrl:]]) # C0 controls and DEL
        i=$((i + 1))
        continue
        ;;
      [$'\200'-$'\237']) # stray C1 control byte
        i=$((i + 1))
        continue
        ;;
    esac
    out+="$b"
    i=$((i + 1))
  done
  printf '%s' "$out"
  return 0
}

# percent_decode TEXT - decode %XX escapes byte-wise (LC_ALL=C plus one-byte
# substring expansion, so multi-byte UTF-8 survives as its raw bytes). Literal
# backslashes in TEXT are never re-interpreted (unlike printf '%b'). A "%" not
# followed by two hex digits stays literal, exactly like the awk this
# replaced, and newlines are dropped to match awk's line-based reader. C0/C1
# control bytes are dropped after decoding, so a %0A in a server href cannot
# split a policy record.
percent_decode() {
  local s="${1:-}" out="" i=0 c="" h1="" h2="" ch=""
  local LC_ALL=C
  s="${s//$'\n'/}"
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    if [[ "$c" == "%" && $((i + 2)) -lt ${#s} ]]; then
      h1="${s:i+1:1}"
      h2="${s:i+2:1}"
      case "$h1$h2" in
        [0-9a-fA-F][0-9a-fA-F])
          printf -v ch '%b' "\\x${h1}${h2}"
          out+="$ch"
          i=$((i + 2))
          continue
          ;;
      esac
    fi
    out+="$c"
  done
  strip_control_bytes "$out"
  return 0
}

# href_decode HREF - percent-decode HREF and strip control bytes, so a
# server-controlled URL segment is safe to display (DAV hrefs arrive
# URL-encoded).
href_decode() {
  printable "$(percent_decode "$1")"
}

# href_last_segment HREF - the percent-decoded, control-stripped last path
# segment of a listing href: the item id shared by trash and versions. Strip
# the trailing slashes, take the final segment, then decode, matching
# http.sh's awk xml_href_segment.
href_last_segment() {
  local segment="${1:-}"
  while [[ "$segment" == */ ]]; do segment="${segment%/}"; done
  segment="${segment##*/}"
  href_decode "$segment"
}

# _AWK_HTML_LIB - the shared awk HTML stripper, composed as
# `LC_ALL=C awk "${_AWK_HTML_LIB}"'<program>'` the same way core's _AWK_CTRL_LIB and
# http.sh's _AWK_XML_LIB compose (http.sh prepends this lib to
# _AWK_XML_LIB, so the XML parsers call xml_html_strip from one source).
# xml_html_strip(s) removes <...> markup, folds whitespace runs to single
# spaces, and trims the ends - the exact gsub/sub sequence the three inline
# copies (core's strip_html, activity's html_strip, search's
# search_strip_html) used to restate per parser.
_AWK_HTML_LIB='
function xml_html_strip(s,    text) {
  text = s
  gsub(/<[^>]*>/, "", text)
  gsub(/[[:space:]]+/, " ", text)
  sub(/^ /, "", text)
  sub(/ $/, "", text)
  return text
}
'

# strip_html TEXT - remove HTML markup and fold whitespace so a
# server-controlled string stays a single readable line. Multi-line TEXT is
# joined with single spaces first, then stripped by the shared
# xml_html_strip (_AWK_HTML_LIB); the gsub/sub rules are byte-identical to
# the inline END block this replaced. Callers that print the result to a
# terminal must still run it through printable.
strip_html() {
  printf '%s' "$1" | LC_ALL=C awk "${_AWK_HTML_LIB}"'
    { text = text $0 " " }
    END { print xml_html_strip(text) }
  '
}

# sanitize_name TEXT - map to [A-Za-z0-9._-] for use in log file names and
# bisync workdirs; collisions are reported by doctor and sync.
sanitize_name() {
  local result=""
  sanitize_name_into result "${1:-}"
  printf '%s' "$result"
}

# sanitize_name_into VAR VALUE - sanitize_name without the command
# substitution, for hot callers (manifest parsing). Byte-wise via LC_ALL=C
# so multi-byte characters map to one underscore, exactly like the tr form
# this replaced.
sanitize_name_into() {
  local s="${2:-}"
  local LC_ALL=C
  s="${s//[^A-Za-z0-9._-]/_}"
  s="${s#"${s%%[!._]*}"}"
  while [[ "$s" == *__* ]]; do
    s="${s//__/_}"
  done
  printf -v "$1" '%s' "${s%_}"
}

# is_uint VALUE - true when VALUE is a non-empty run of ASCII digits.
is_uint() {
  case "${1:-}" in
    '' | *[!0-9]*) return 1 ;;
  esac
  return 0
}

# default_uint VALUE FALLBACK - print VALUE when it is a non-empty run of
# ASCII digits, else FALLBACK. The shared normalizer for settings-derived
# limits and thresholds (recent/search/file-activity limits, the
# blacklist/runstate counters), replacing the repeated
# `case '' | *[!0-9]*) v=fallback ;;` idiom. Pure printf, so callers capture
# it forklessly with ${ ...; }.
default_uint() {
  if is_uint "${1:-}"; then
    printf '%s' "$1"
  else
    printf '%s' "${2:-}"
  fi
  return 0
}

# comma_ids_valid IDS - true when IDS is one or more non-empty ASCII-digit
# ids separated by commas; false for an empty string, an empty field, or any
# non-digit byte. The shared validator for comma-separated numeric id lists.
comma_ids_valid() {
  local ids="${1:-}" id="" rest=""
  [[ -n "$ids" ]] || return 1
  rest="$ids"
  while :; do
    id="${rest%%,*}"
    is_uint "$id" || return 1
    [[ "$rest" == *,* ]] || break
    rest="${rest#*,}"
  done
  return 0
}

# url_redact_userinfo URL - print URL with any credentials embedded in the
# authority masked as `***@`: `scheme://user:pass@host/path` becomes
# `scheme://***@host/path`. Host and path survive, so a proxy URL can be
# reported or archived safely.
url_redact_userinfo() {
  local url="${1:-}" scheme="" rest="" authority="" tail=""
  case "$url" in
    *://*)
      scheme="${url%%://*}://"
      rest="${url#*://}"
      ;;
    *) rest="$url" ;;
  esac
  authority="${rest%%/*}"
  tail="${rest#"$authority"}"
  case "$authority" in
    *@*) authority="***@${authority##*@}" ;;
  esac
  printf '%s' "${scheme}${authority}${tail}"
}

# nextcloud_dav_url URL USER - print URL normalized to USER's Nextcloud
# WebDAV files root: trailing slashes are stripped, a URL that already ends
# in /remote.php/dav/files/USER gains a trailing slash, and anything else
# gains the whole /remote.php/dav/files/USER/ path. rc 1 without output
# when URL points into /remote.php/ but not at USER's files root - the
# caller then dies with its command-specific hint, because setup ("... but
# setup needs the Nextcloud base URL ...") and provision ("... but
# --serverurl needs ...") word that failure differently and only they may
# print it. This is the shared half of setup_normalize_url/
# provision_normalize_url; ncc_parse_url (nextcloudcmd) parses a different
# shape and stays separate.
nextcloud_dav_url() {
  local url="$1" user="$2"
  url="$(strip_trailing_slashes "$url")"
  case "$url" in
    */remote.php/dav/files/"$user")
      printf '%s/' "$url"
      ;;
    *"/remote.php/"*)
      return 1
      ;;
    *)
      printf '%s/remote.php/dav/files/%s/' "$url" "$user"
      ;;
  esac
  return 0
}

# split_positionals ARGS - fill the POSITIONAL_ARGS array from a
# newline-separated OPT_EXTRA value (one element per positional). Callers
# check ${#POSITIONAL_ARGS[@]} -gt 0 before indexing.
split_positionals() {
  POSITIONAL_ARGS=()
  local rest="${1:-}"
  rest="${rest%$'\n'}"
  [[ -n "$rest" ]] || return 0
  while :; do
    POSITIONAL_ARGS[${#POSITIONAL_ARGS[@]}]="${rest%%$'\n'*}"
    [[ "$rest" == *$'\n'* ]] || break
    rest="${rest#*$'\n'}"
  done
  return 0
}

# split_positionals_into NAME... - split OPT_EXTRA (like split_positionals,
# leaving the words in POSITIONAL_ARGS for the caller's own count check) and
# assign the leading words to the named variables, empty when absent. Collapses
# the `split_positionals; p1=${POSITIONAL_ARGS[0]:-}; ...` preamble the
# subcommand parsers repeat. NAME may be a local or a global.
split_positionals_into() {
  split_positionals "${OPT_EXTRA:-}"
  local i=0 name=""
  for name in "$@"; do
    printf -v "$name" '%s' "${POSITIONAL_ARGS[$i]:-}"
    i=$((i + 1))
  done
  return 0
}

# split_command_args ARGS SUB_VAR ARG1_VAR ARG2_VAR ARGC_VAR - fill the named
# globals from the newline-separated positional arguments: SUB_VAR gets the
# first positional, ARG1_VAR the second, ARG2_VAR the third, and ARGC_VAR their
# total. Missing trailing names stay empty. Shared by the `share` and `file`
# subcommand parsers; callers own their differently named globals.
split_command_args() {
  local args="$1" sub_var="$2" arg1_var="$3" arg2_var="$4" argc_var="$5"
  local n=0
  split_positionals "$args"
  n="${#POSITIONAL_ARGS[@]}"
  printf -v "$sub_var" '%s' ""
  printf -v "$arg1_var" '%s' ""
  printf -v "$arg2_var" '%s' ""
  printf -v "$argc_var" '%s' "$n"
  [[ "$n" -gt 0 ]] || return 0
  printf -v "$sub_var" '%s' "${POSITIONAL_ARGS[0]}"
  [[ "$n" -gt 1 ]] || return 0
  printf -v "$arg1_var" '%s' "${POSITIONAL_ARGS[1]}"
  [[ "$n" -gt 2 ]] || return 0
  printf -v "$arg2_var" '%s' "${POSITIONAL_ARGS[2]}"
  return 0
}

# record_split LINE NAME... - assign the TAB-separated fields of LINE to the
# named variables. Every NAME consumes one field; "-" skips a field and the
# last NAME receives the remainder. Splitting is explicit because TAB is IFS
# whitespace, so `read` would collapse empty fields. Prints nothing and
# returns 0 even for an empty record, so parsers can call it per record.
record_split() {
  local rest="$1"
  shift
  local names=("$@") i=0 last=$(($# - 1)) name=""
  [[ "$last" -ge 0 ]] || return 0
  while [[ "$i" -lt "$last" ]]; do
    name="${names[$i]}"
    if [[ "$name" == "-" ]]; then
      rest="${rest#*$'\t'}"
    else
      printf -v "$name" '%s' "${rest%%$'\t'*}"
      rest="${rest#*$'\t'}"
    fi
    i=$((i + 1))
  done
  name="${names[$last]}"
  [[ "$name" == "-" ]] || printf -v "$name" '%s' "$rest"
  return 0
}

# numeric_id VALUE - true when VALUE is one non-empty run of ASCII digits.
# Server-side ids (share/comment/notification ids) are interpolated into
# request paths and XML bodies, so anything else must be rejected first.
numeric_id() { is_uint "${1:-}"; }

# strip_trailing_slashes PATH - remove trailing slashes, keeping "/" intact.
strip_trailing_slashes() {
  local s="$1"
  while [[ "$s" == */ && "$s" != "/" ]]; do s="${s%/}"; done
  printf '%s' "$s"
}

# size_suffix_bytes SIZE - parse an rclone-style size suffix (1, 500M, 5G,
# 1Gi, 100KB) into bytes. Binary units for K/M/G/T/P/E (1024-based), decimal
# for the explicit KB/MB/GB/TB forms. Prints nothing and returns 1 when the
# value is not parseable.
size_suffix_bytes() {
  local value="$1" number="" unit="" multiplier=""
  value="${value//[[:space:]]/}"
  number="${value%%[!0-9.]*}"
  unit="${value#"$number"}"
  [[ -n "$number" && "$number" != *.*.* ]] || return 1
  case "$unit" in
    '') multiplier=1 ;;
    B | b) multiplier=1 ;;
    K | k | Ki | ki | KI) multiplier=1024 ;;
    M | m | Mi | mi | MI) multiplier=1048576 ;;
    G | g | Gi | gi | GI) multiplier=1073741824 ;;
    T | t | Ti | ti | TI) multiplier=1099511627776 ;;
    P | p | Pi | pi | PI) multiplier=1125899906842624 ;;
    E | e | Ei | ei | EI) multiplier=1152921504606846976 ;;
    KB | kb | kB | Kb) multiplier=1000 ;;
    MB | mb | mB | Mb) multiplier=1000000 ;;
    GB | gb | gB | Gb) multiplier=1000000000 ;;
    TB | tb | tB | Tb) multiplier=1000000000000 ;;
    *) return 1 ;;
  esac
  # Parse the supported shape ^[0-9]+([.][0-9]+)?$ in pure bash (no awk fork
  # on the per-entry guard and chunk paths): integer part times multiplier
  # plus the fractional part scaled to whole bytes. The fraction is rounded
  # half-to-even to match awk's "%.0f" for values a double represents
  # exactly; beyond 2^53 the double-precision awk result can differ by one
  # byte. Bash arithmetic is 64-bit signed, so a result at or above 2^63
  # wraps instead of printing awk's (already inexact) double. Invalid shapes
  # (leading/trailing dot, two dots) return 1 exactly like awk.
  case "$number" in
    .* | *.) return 1 ;;
  esac
  local int_part="$number" frac="" scale=1 i=0 whole=0 frac_num=0
  local mult_q=0 mult_r=0 remainder=0 half=0
  if [[ "$number" == *.* ]]; then
    int_part="${number%%.*}"
    frac="${number#*.}"
  fi
  [[ -n "$int_part" && "$int_part" != *[!0-9]* ]] || return 1
  [[ -z "$frac" || "$frac" != *[!0-9]* ]] || return 1
  whole=$((10#$int_part * multiplier))
  if [[ -n "$frac" ]]; then
    for ((i = 0; i < ${#frac}; i++)); do scale=$((scale * 10)); done
    # Split the multiplier by scale so frac*multiplier cannot overflow before
    # the division: frac*(q*scale + r) = frac*q*scale + frac*r.
    mult_q=$((multiplier / scale))
    mult_r=$((multiplier % scale))
    frac_num=$((10#$frac))
    whole=$((whole + frac_num * mult_q + frac_num * mult_r / scale))
    remainder=$((frac_num * mult_r % scale))
    half=$((scale / 2))
    if ((remainder > half)) ||
      ((scale % 2 == 0 && remainder == half && whole % 2 == 1)); then
      whole=$((whole + 1))
    fi
  fi
  printf '%d' "$whole"
}
