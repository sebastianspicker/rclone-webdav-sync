#!/bin/bash
# search.sh command module - Nextcloud unified search over the files
# provider. Read-only: one OCS request through lib/nc_api.sh, no lock, no
# local state. Titles and sublines are stripped of HTML and control bytes
# before they reach the terminal; --open hands the first result to the
# platform opener without replacing the shell, and only when the URL stays
# on the configured server's origin.

usage_search() {
  usage_emit <<'EOF'
Usage: sciebo search TERM [--limit N] [--json] [--open]

Search files on the server with Nextcloud's unified search. TERM is a
single argument (quote it to search for spaces). Results are printed as
TITLE<TAB>SUBLINE<TAB>RESOURCEURL, or "no matches".

Options:
  --limit N   ask the server for at most N results (default SEARCH_LIMIT)
  --json      print the results as JSON
  --open      open the first result with the platform opener
  -h, --help  show this help
EOF
}

# search_rows XML - print "TITLE<TAB>SUBLINE<TAB>RESOURCEURL" per <element>
# entry, HTML stripped and control bytes removed. Entries with no displayed
# field at all are dropped. The tag strip and whitespace fold happen inside the
# one awk pass that extracts the fields (the shared xml_html_strip from
# _AWK_XML_LIB acts on the title and subline), so the shell loop only formats
# the record with forkless parameter expansions instead of forking
# strip_html/printable per field and result.
search_rows() {
  local xml="$1" line="" title="" subline="" url=""
  while IFS= read -r line; do
    record_split "$line" title subline url
    title=${ printable "$title";}
    subline=${ printable "$subline";}
    url=${ printable "$url";}
    [[ -n "$title$subline$url" ]] || continue
    printf '%s\t%s\t%s\n' "$title" "$subline" "$url"
  done < <(printf '%s' "$xml" | LC_ALL=C awk -v wrapper=element -v groups="title subline resourceUrl" "${_AWK_XML_LIB}"'
    function search_emit(block, groups,    ng, i, n, j, val, line) {
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
        if (i <= 2) val = xml_html_strip(val)
        line = (i == 1) ? val : line "\t" val
      }
      return line
    }
    { doc = doc $0 }
    END {
      n = xml_walk_top(doc, wrapper, "store")
      for (i = 1; i <= n; i++) print search_emit(xml_top_block[i], groups)
    }
  ')
}

# search_json ROWS - the `--json` document; ROWS is search_rows output.
search_json() {
  local rows="$1" line="" rest="" title="" subline="" url=""
  local -a lines=()
  output_json_list_begin "results"
  mapfile -t lines <<<"$rows"
  for line in "${lines[@]}"; do
    [[ -n "$line" ]] || continue
    title="${line%%$'\t'*}"
    rest="${line#*$'\t'}"
    subline="${rest%%$'\t'*}"
    url="${rest#*$'\t'}"
    output_json_object_begin
    output_json_kv "title" "$title"
    output_json_kv "subline" "$subline"
    output_json_kv "resourceUrl" "$url"
    output_json_object_end
  done
  output_json_list_end
}

# search_first_url ROWS - the RESOURCEURL of the first search row.
search_first_url() {
  local rows="$1" line="" rest=""
  line="${rows%%$'\n'*}"
  rest="${line#*$'\t'}"
  rest="${rest#*$'\t'}"
  printf '%s' "${rest%%$'\t'*}"
}

# search_launch_url URL - hand URL to the platform opener (platform_opener
# picks `open` on macOS, `xdg-open` elsewhere); dies when neither exists or
# the opener fails. The URL is server data: it must be http(s) and share
# scheme and host with the configured server base, so a search result can
# never open the browser on another origin (same rule as the notification
# action links).
search_launch_url() {
  local url="$1" opener="" origin="" expected=""
  # platform.sh is lazy; load it for platform_opener below.
  sciebo_require_module platform platform_opener
  case "$url" in
    http://* | https://*) ;;
    *) die "refusing to open non-http(s) URL: $(printable "$url")" ;;
  esac
  origin="$(http_origin "$url")"
  expected="$(http_origin "${HTTP_BASE:-}")"
  [[ -n "$origin" && "$origin" == "$expected" ]] ||
    die "refusing to open off-origin URL: $(printable "$url") (expected origin $(printable "${expected:-unknown}"))"
  opener="$(platform_opener)"
  [[ -n "$opener" ]] ||
    die "cannot open ${url}: neither 'open' (macOS) nor 'xdg-open' was found"
  # "--" stops a server-controlled URL that starts with "-" from being read
  # as an option by the opener.
  "$opener" -- "$url" || die "cannot open ${url}: ${opener} failed"
  return 0
}

cmd_search() {
  local term="" limit="" rows=""
  opt_begin "limit:s json:b open:b" search "" "$@"
  # Run dependencies load after opt_begin's --help exit, so
  # `sciebo search --help` parses none of them.
  sciebo_require_module http xml_get
  sciebo_require_module nc_api nc_dav_request_allow
  opt_require_sub search "a search term" "${OPT_EXTRA:-}" 1 1 \
    "search accepts exactly one term; quote a term with spaces"
  term="${POSITIONAL_ARGS[0]}"
  http_load_context
  # The default result limit from settings, 20 when the setting is empty or
  # not numeric.
  limit=${ default_uint "${SEARCH_LIMIT:-}" 20;}
  if [[ -n "${OPT_limit_SET:-}" ]]; then
    opt_require_uint search --limit "${OPT_limit:-}" 1
    limit=$((10#${OPT_limit}))
  fi
  nc_search "$term" "$limit"
  rows="$(search_rows "$HTTP_BODY")"
  opt_json_mode
  if output_json_enabled; then
    search_json "$rows"
  elif [[ -n "$rows" ]]; then
    printf '%s\n' "$rows"
  else
    printf 'no matches\n'
  fi
  if [[ -n "${OPT_open:-}" && -n "$rows" ]]; then
    search_launch_url "$(search_first_url "$rows")"
  fi
  return 0
}
