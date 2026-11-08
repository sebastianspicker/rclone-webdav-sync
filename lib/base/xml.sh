#!/bin/bash
# xml.sh - pure XML/JSON text parsers, split out of lib/adapters/http.sh: no
# curl, no network, no settings; awk (and, for http_urlencode, plain bash)
# over an already-fetched string. Sourced after text.sh, whose _AWK_CTRL_LIB/
# _AWK_HTML_LIB the shared XML awk prelude below composes with.

# json_string_field BODY KEY - print the first `"KEY": "VALUE"` string value
# from a compact JSON document (one awk pass over BODY). All JSON string
# escapes are decoded (\\ \"\/ \b \f \n \r \t and \uXXXX, with surrogate
# pairs, to UTF-8 bytes; \u0000 is dropped); an unknown escape is left
# untouched. Prints nothing and returns 1 when KEY is absent or its value is
# not a properly quoted string.
json_string_field() {
  printf '%s\n' "${1:-}" | LC_ALL=C awk -v key="${2:-}" '
    BEGIN { want = "\"" key "\"" }
    function jhex(h,    k, p, v) {
      if (length(h) != 4) return -1
      v = 0
      for (k = 1; k <= 4; k++) {
        p = index("0123456789abcdef", tolower(substr(h, k, 1)))
        if (p == 0) return -1
        v = v * 16 + p - 1
      }
      return v
    }
    function utf8(cp) {
      if (cp < 128) return sprintf("%c", cp)
      if (cp < 2048) return sprintf("%c%c", 192 + int(cp / 64), 128 + cp % 64)
      if (cp < 65536) return sprintf("%c%c%c", 224 + int(cp / 4096), 128 + int(cp / 64) % 64, 128 + cp % 64)
      return sprintf("%c%c%c%c", 240 + int(cp / 262144), 128 + int(cp / 4096) % 64, 128 + int(cp / 64) % 64, 128 + cp % 64)
    }
    {
      pos = index($0, want)
      if (pos == 0) next
      rest = substr($0, pos + length(want))
      if (rest !~ /^[ \t]*:[ \t]*"/) next
      sub(/^[ \t]*:[ \t]*"/, "", rest)
      out = ""
      closed = 0
      n = length(rest)
      for (i = 1; i <= n; i++) {
        c = substr(rest, i, 1)
        if (c == "\\" && i < n) {
          d = substr(rest, i + 1, 1)
          i++
          if (d == "n") out = out "\n"
          else if (d == "t") out = out "\t"
          else if (d == "r") out = out "\r"
          else if (d == "b") out = out sprintf("%c", 8)
          else if (d == "f") out = out sprintf("%c", 12)
          else if (d == "\"" || d == "/" || d == "\\") out = out d
          else if (d == "u" && (cp = jhex(substr(rest, i + 1, 4))) >= 0) {
            i += 4
            # a high surrogate followed by \uDC00-\uDFFF is one astral codepoint
            if (cp >= 55296 && cp < 56320 && substr(rest, i + 1, 2) == "\\u" && (lo = jhex(substr(rest, i + 3, 4))) >= 56320 && lo < 57344) {
              cp = 65536 + (cp - 55296) * 1024 + (lo - 56320)
              i += 6
            } else if (cp >= 55296 && cp < 57344) cp = 65533
            if (cp > 0) out = out utf8(cp)
          } else out = out c d
          continue
        }
        if (c == "\"") {
          closed = 1
          break
        }
        out = out c
      }
      if (!closed) next
      print out
      found = 1
      exit
    }
    END { exit(found ? 0 : 1) }
  '
}

# http_urlencode TEXT - percent-encode every byte except unreserved
# characters and "/" (path separators survive). Byte-wise on purpose: the
# shell's own substring expansion is locale-aware on macOS and would treat a
# multi-byte character as one unit, so LC_ALL=C is forced and the string is
# indexed one byte at a time. Pure bash, so no fork per call.
http_urlencode() {
  local s="${1:-}" out="" i=0 c="" code=0
  local LC_ALL=C
  # The awk this replaced read the input line by line, so embedded newlines
  # were record separators and never reached the output; keep that behavior.
  s="${s//$'\n'/}"
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [A-Za-z0-9._~/-]) out+="$c" ;;
      # The leading-quote printf idiom is unreliable for a single quote, so
      # it is encoded directly (0x27).
      "'") out+="%27" ;;
      *)
        printf -v code '%d' "'$c"
        printf -v code '%02X' "$code"
        out+="%${code}"
        ;;
    esac
  done
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# XML helpers (awk only, no external dependencies)
# ---------------------------------------------------------------------------

# Shared awk XML prelude. Every parser composes its program as
# `LC_ALL=C awk [-v ...] "${_AWK_XML_LIB}"'<program>'`, so trim/decode/extract
# live in one place instead of being copy-pasted per command module. The
# preludes work on bytes: in a UTF-8 locale gawk treats sprintf("%c", 195) as
# the character U+00C3, which corrupts percent-decoded names, so callers run
# them under LC_ALL=C (scripts/check-layers.sh rule 6 enforces this). It starts with
# text.sh's _AWK_CTRL_LIB (text.sh is always sourced before this file), so
# the XML parsers share the exact UTF-8 control rules through xml_strip_ctrl,
# and includes text.sh's _AWK_HTML_LIB, so a parser strips server-provided
# markup with the same xml_html_strip that text.sh's strip_html uses.
# shellcheck disable=SC2153  # _AWK_HTML_LIB is assigned in lib/base/text.sh
_AWK_XML_LIB="${_AWK_CTRL_LIB}${_AWK_HTML_LIB}"'
function xml_trim(s) {
  sub(/^[[:space:]]+/, "", s)
  sub(/[[:space:]]+$/, "", s)
  return s
}
function xml_hexval(h,    i, c, v, p) {
  v = 0
  for (i = 1; i <= length(h); i++) {
    c = tolower(substr(h, i, 1))
    p = index("0123456789abcdef", c)
    if (p == 0) return -1
    v = v * 16 + (p - 1)
  }
  return v
}
# xml_decode_numeric(s) - decode &#NN; / &#xHH; references. Only codepoints in
# the ASCII range are rewritten: emitting bytes >= 0x80 portably is not
# possible with awk %c across implementations (BSD awk vs gawk under a UTF-8
# locale), and Nextcloud escapes non-ASCII as named entities or UTF-8 anyway.
function xml_decode_numeric(s,    out, i, n, j, c, hexf, d, code) {
  out = ""
  n = length(s)
  i = 1
  while (i <= n) {
    if (substr(s, i, 2) == "&#") {
      j = i + 2
      hexf = (tolower(substr(s, j, 1)) == "x")
      if (hexf) j++
      d = ""
      while (j <= n) {
        c = substr(s, j, 1)
        if ((hexf && c ~ /[0-9A-Fa-f]/) || (!hexf && c ~ /[0-9]/)) {
          d = d c
          j++
          continue
        }
        break
      }
      if (d != "" && substr(s, j, 1) == ";") {
        code = (hexf ? xml_hexval(d) : d + 0)
        if (code >= 0 && code <= 127) {
          out = out sprintf("%c", code)
          i = j + 1
          continue
        }
        out = out substr(s, i, j - i + 1)
        i = j + 1
        continue
      }
    }
    out = out substr(s, i, 1)
    i++
  }
  return out
}
# xml_decode(s) - one left-to-right pass, so a decoded "&" is never decoded
# again: &amp;lt; -> &lt; and &amp;#65; -> &#65;.
function xml_decode(s,    out, i, j, ent, dec) {
  out = ""
  while ((i = index(s, "&")) > 0) {
    out = out substr(s, 1, i - 1)
    s = substr(s, i)
    if (substr(s, 1, 4) == "&lt;") { out = out "<"; s = substr(s, 5) }
    else if (substr(s, 1, 4) == "&gt;") { out = out ">"; s = substr(s, 5) }
    else if (substr(s, 1, 5) == "&amp;") { out = out "&"; s = substr(s, 6) }
    else if (substr(s, 1, 6) == "&quot;") { out = out "\""; s = substr(s, 7) }
    else if (substr(s, 1, 6) == "&apos;") { out = out sprintf("%c", 39); s = substr(s, 7) }
    else if (substr(s, 1, 2) == "&#" && (j = index(s, ";")) > 0 && (dec = xml_decode_numeric(ent = substr(s, 1, j))) != ent) {
      out = out dec
      s = substr(s, j + 1)
    } else { out = out "&"; s = substr(s, 2) }
  }
  return out s
}
# xml_strip_ctrl(s) - drop C0/DEL, encoded/stray C1 bytes (0x80-0x9F), and
# invalid UTF-8 while keeping valid multi-byte sequences, so a server value
# cannot inject a control byte or break TSV framing without corrupting
# non-ASCII names. KEEP=0 folds TAB like the other TSV-field strippers. The
# byte rules live in ctrl_strip (composed through _AWK_CTRL_LIB in core).
function xml_strip_ctrl(s) {
  return ctrl_strip(s, 0)
}
function xml_extract_exact(block, tag,    pos, after, gt, head, body, cend, val) {
  while ((pos = index(block, "<" tag)) > 0) {
    after = substr(block, pos + 1 + length(tag))
    if (after ~ /^[[:space:]\/>]/) {
      gt = index(after, ">")
      if (gt > 0) {
        head = substr(after, 1, gt - 1)
        if (head !~ /\/[[:space:]]*$/) {
          body = substr(after, gt + 1)
          cend = index(body, "</" tag)
          if (cend > 0) {
            val = xml_decode(xml_trim(substr(body, 1, cend - 1)))
            gsub(/\t/, " ", val)
            val = xml_strip_ctrl(val)
            if (val != "") return val
          }
        }
      }
    }
    block = substr(block, pos + 1)
  }
  return ""
}
# xml_extract_ns(block, tag) - namespace-tolerant fallback: match an element
# whose local name equals the local name of TAG under any (or no) prefix.
# It only runs when the exact spelling is absent, so documents using the usual
# d:/oc:/nc: prefixes keep their current behavior and cost.
function xml_extract_ns(block, tag,    local, rest, pos, m, full, after, gt, head, body, cend, val) {
  if (tag == "") return ""
  local = tag
  sub(/^.*:/, "", local)
  rest = block
  while ((pos = match(rest, "<([A-Za-z0-9_.-]+:)?" local "([[:space:]/]|>)")) > 0) {
    m = substr(rest, pos, RLENGTH)
    full = m
    sub(/^</, "", full)
    sub(/[[:space:]\/>].*$/, "", full)
    if (full != "") {
      after = substr(rest, pos + 1 + length(full))
      if (after ~ /^[[:space:]\/>]/) {
        gt = index(after, ">")
        if (gt > 0) {
          head = substr(after, 1, gt - 1)
          if (head !~ /\/[[:space:]]*$/) {
            body = substr(after, gt + 1)
            cend = index(body, "</" full)
            if (cend > 0) {
              val = xml_decode(xml_trim(substr(body, 1, cend - 1)))
              gsub(/\t/, " ", val)
              val = xml_strip_ctrl(val)
              if (val != "") return val
            }
          }
        }
      }
    }
    rest = substr(rest, pos + 1)
  }
  return ""
}
function xml_extract(block, tag,    val) {
  val = xml_extract_exact(block, tag)
  if (val != "") return val
  return xml_extract_ns(block, tag)
}
# xml_pct(s) - percent-decode S byte-wise and drop C0/DEL and stray C1 bytes
# (a server-controlled href segment is display-safe and TSV-safe afterwards)
# while keeping valid UTF-8 sequences.
function xml_pct(s,    out, i, c, h1, h2, ch) {
  if (xml_hex == "") {
    xml_hex = "0123456789abcdef"
    for (i = 1; i <= 31; i++) xml_ctl = xml_ctl sprintf("%c", i)
    xml_ctl = xml_ctl sprintf("%c", 127)
  }
  out = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c == "%" && i + 2 <= length(s)) {
      h1 = tolower(substr(s, i + 1, 1))
      h2 = tolower(substr(s, i + 2, 1))
      if (index(xml_hex, h1) > 0 && index(xml_hex, h2) > 0) {
        ch = sprintf("%c", (index(xml_hex, h1) - 1) * 16 + (index(xml_hex, h2) - 1))
        i += 2
        if (index(xml_ctl, ch) == 0) out = out ch
        continue
      }
    }
    if (index(xml_ctl, c) == 0) out = out c
  }
  return xml_strip_ctrl(out)
}
function xml_last_segment(href,    s, parts, n) {
  s = href
  sub(/\/+$/, "", s)
  n = split(s, parts, "/")
  return parts[n]
}
# xml_href_segment(block) - the percent-decoded last path segment of the
# first <d:href> in the block, ready to print in a TSV record.
function xml_href_segment(block) {
  return xml_pct(xml_last_segment(xml_extract(block, "d:href")))
}
# xml_emit_fields(block, groups) - one TAB-separated record built from the
# "|"-separated tag spellings in the space-separated groups list.
function xml_emit_fields(block, groups,    ng, i, n, j, val, line) {
  ng = split(groups, xml_groups, " ")
  line = ""
  for (i = 1; i <= ng; i++) {
    n = split(xml_groups[i], xml_alts, "|")
    val = ""
    for (j = 1; j <= n; j++) {
      val = xml_extract(block, xml_alts[j])
      if (val != "") break
    }
    val = xml_strip_ctrl(val)
    line = (i == 1) ? val : line "\t" val
  }
  return line
}
# xml_walk_top(doc, tag, mode) - depth-aware walk of the top-level <tag>
# blocks in doc, shared by every XML splitter. A nested <tag> stays inside its
# parent block instead of truncating it (the notifications API nests <element>
# inside <actions>). mode "split" prints each block followed by an ASCII record
# separator (0x1e); mode "store" fills xml_top_block[1..n] and returns n for
# the caller to process. CR bytes are dropped first so a CRLF document walks
# like an LF one.
function xml_walk_top(doc, tag, mode,    len, close_len, rest, pos, after, gt, head, scan, content, depth, o, c, oa, ogt, ohead, emitted, n) {
  gsub(/\r/, "", doc)
  len = length(tag)
  close_len = len + 2
  rest = doc
  n = 0
  while ((pos = index(rest, "<" tag)) > 0) {
    after = substr(rest, pos + 1 + len)
    if (after !~ /^[[:space:]\/>]/) {
      rest = substr(rest, pos + 1)
      continue
    }
    gt = index(after, ">")
    if (gt == 0) break
    head = substr(after, 1, gt - 1)
    if (head ~ /\/[[:space:]]*$/) {
      rest = substr(after, gt + 1)
      continue
    }
    scan = substr(after, gt + 1)
    content = ""
    depth = 1
    emitted = 0
    while (depth > 0) {
      o = index(scan, "<" tag)
      c = index(scan, "</" tag)
      if (c == 0) break
      if (o > 0 && o < c) {
        oa = substr(scan, o + 1 + len)
        if (oa ~ /^[[:space:]\/>]/) {
          ogt = index(oa, ">")
          if (ogt > 0) {
            ohead = substr(oa, 1, ogt - 1)
            if (ohead !~ /\/[[:space:]]*$/) depth++
            content = content substr(scan, 1, o + len + ogt)
            scan = substr(scan, o + len + ogt + 1)
            continue
          }
        }
        content = content substr(scan, 1, 1)
        scan = substr(scan, 2)
        continue
      }
      depth--
      if (depth == 0) {
        content = content substr(scan, 1, c - 1)
        if (mode == "split") {
          printf "%s\036", content
        } else {
          n++
          xml_top_block[n] = content
        }
        scan = substr(scan, c + close_len)
        emitted = 1
        break
      }
      content = content substr(scan, 1, c + close_len - 1)
      scan = substr(scan, c + close_len)
    }
    if (!emitted) break
    rest = scan
  }
  return n
}
'

# xml_unescape TEXT - decode the five predefined XML entities.
xml_unescape() {
  printf '%s' "$1" | LC_ALL=C awk "${_AWK_XML_LIB}"'
    { print xml_decode($0) }
  '
}

# xml_get XML TAG - print the decoded text of the first <TAG> element
# (TAG may be namespaced, e.g. "oc:fileid"). Empty when the element is
# absent or self-closed. Whitespace around the value is trimmed and TABs
# are folded so records stay line-based.
xml_get() {
  printf '%s' "$1" | LC_ALL=C awk -v tag="$2" "${_AWK_XML_LIB}"'
    { doc = doc $0 }
    END { print xml_extract(doc, tag) }
  '
}

# xml_wrapper_auto XML - print the record wrapper tag the document uses:
# "element" for OCS-style payloads, else "d:response".
xml_wrapper_auto() {
  case "$1" in
    *'<element'*) printf 'element' ;;
    *) printf 'd:response' ;;
  esac
}

# xml_records XML WRAPPER GROUP... - print one TAB-separated record per
# <WRAPPER> element, in document order. Each GROUP is a "|"-separated list
# of tag spellings; the first non-empty decoded value is used (empty stays
# empty). Values are trimmed, TAB-folded, and stripped of control bytes so a
# server cannot break record framing or inject terminal escapes. This is the
# single-pass replacement for the per-field `xml_get` loops: one awk process
# for the whole document instead of one per field per record.
xml_records() {
  local xml="$1" wrapper="$2"
  shift 2
  local groups="$*"
  printf '%s' "$xml" | LC_ALL=C awk -v wrapper="$wrapper" -v groups="$groups" "${_AWK_XML_LIB}"'
    { doc = doc $0 }
    END {
      rest = doc
      while ((pos = index(rest, "<" wrapper)) > 0) {
        after = substr(rest, pos + 1 + length(wrapper))
        if (after !~ /^[[:space:]\/>]/) {
          rest = substr(rest, pos + 1)
          continue
        }
        gt = index(after, ">")
        if (gt == 0) break
        head = substr(after, 1, gt - 1)
        if (head ~ /\/[[:space:]]*$/) {
          rest = substr(after, gt + 1)
          continue
        }
        body = substr(after, gt + 1)
        cend = index(body, "</" wrapper)
        if (cend == 0) break
        block = substr(body, 1, cend - 1)
        rest = substr(body, cend + length("</" wrapper))
        print xml_emit_fields(block, groups)
      }
    }
  '
}

# xml_fields XML GROUP... - print one TAB-separated record built from the
# "|"-separated tag spellings in each GROUP, using the first non-empty decoded
# value (empty stays empty). Same trim, tab-fold, entity-decode and
# control-strip rules as xml_records, but for a single document with no
# wrapper: one awk pass for the whole field set instead of one xml_get per
# field.
xml_fields() {
  local xml="$1"
  shift
  local groups="$*"
  printf '%s' "$xml" | LC_ALL=C awk -v groups="$groups" "${_AWK_XML_LIB}"'
    { doc = doc $0 }
    END { print xml_emit_fields(doc, groups) }
  '
}

# xml_records_top XML WRAPPER GROUP... - like xml_records but only top-level
# <WRAPPER> blocks: nested wrappers of the same name (the notifications API
# nests <element> inside <actions>) stay inside their parent block instead of
# truncating it. Same field rules as xml_records.
xml_records_top() {
  local xml="$1" wrapper="$2"
  shift 2
  local groups="$*"
  printf '%s' "$xml" | LC_ALL=C awk -v tag="$wrapper" -v groups="$groups" "${_AWK_XML_LIB}"'
    { doc = doc $0 }
    END {
      n = xml_walk_top(doc, tag, "store")
      for (i = 1; i <= n; i++) print xml_emit_fields(xml_top_block[i], groups)
    }
  '
}
