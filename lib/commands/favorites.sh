#!/bin/bash
# favorites.sh command module - list and toggle Nextcloud favorites. The
# listing is a DAV REPORT on the files root; add/remove set the oc:favorite
# property through lib/adapters/nc_api.sh. Only die/usage_error exit.

FAVORITES_RECORD_PATH=""
FAVORITES_RECORD_SIZE=""
FAVORITES_RECORD_MODIFIED=""
FAVORITES_RECORD_FIELDS=(
  FAVORITES_RECORD_PATH FAVORITES_RECORD_SIZE FAVORITES_RECORD_MODIFIED
)

usage_favorites() {
  usage_emit <<'EOF'
Usage: sciebo favorites [list] [--json]
       sciebo favorites add SUB
       sciebo favorites remove SUB

List the server-side favorites of the configured remote, or mark SUB (a
remote path below <RCLONE_REMOTE>:<REMOTE_BASE>/) as a favorite. `list` is
the default and prints the path, size, and last-modified time.

Subcommands:
  [list]        list favorites (default)
  add SUB       mark SUB as a favorite
  remove SUB    clear the favorite flag of SUB

Options:
  --json      print the listing as JSON
  -h, --help  show this help
EOF
}

# favorites_href_prefix - the server-relative path of HTTP_FILES_ROOT
# (e.g. /remote.php/dav/files/alice), which is the form Nextcloud uses in
# href values.
favorites_href_prefix() {
  local root="${HTTP_FILES_ROOT#*://}"
  printf '/%s' "${root#*/}"
}

# favorites_display_path HREF - the path shown for a REPORT href: the
# percent-decoded href with the absolute files root or the server-relative
# DAV prefix removed, "/" for the root itself.
favorites_display_path() {
  local decoded="" prefix=""
  decoded=${ href_decode "$1";}
  prefix=${ favorites_href_prefix;}
  case "$decoded" in
    "$HTTP_FILES_ROOT" | "$prefix") printf '/' ;;
    "$HTTP_FILES_ROOT"/*) printf '%s' "${decoded#"$HTTP_FILES_ROOT"/}" ;;
    "$prefix"/*) printf '%s' "${decoded#"$prefix"/}" ;;
    *) printf '%s' "$decoded" ;;
  esac
}

# favorites_parse_xml XML - print one TAB-separated record per <d:response>:
# path, size, last modified. Tolerates the plain (unprefixed) property
# spellings and missing values.
favorites_parse_xml() {
  local line="" href="" size="" modified="" display_path=""
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    record_split "$line" href size modified
    [[ -n "$href" ]] || continue
    display_path=${ favorites_display_path "$href";}
    printf '%s\t%s\t%s\n' "$display_path" "$size" "$modified"
  done < <(xml_records "$1" 'd:response' \
    'd:href|href' 'd:getcontentlength|getcontentlength' 'd:getlastmodified|getlastmodified')
}

# favorites_print_row LINE - print one favorites table row; non-zero when the
# record has no path.
favorites_print_row() {
  local size_label="" path_disp="" size_disp="" modified_disp=""
  record_split "$1" "${FAVORITES_RECORD_FIELDS[@]}"
  [[ -n "$FAVORITES_RECORD_PATH" ]] || return 1
  size_label="$FAVORITES_RECORD_SIZE"
  [[ -n "$size_label" ]] || size_label="-"
  path_disp=${ printable "$FAVORITES_RECORD_PATH";}
  size_disp=${ printable "$size_label";}
  modified_disp=${ printable "$FAVORITES_RECORD_MODIFIED";}
  printf '%-40s %-12s %s\n' "$path_disp" "$size_disp" "$modified_disp"
  return 0
}

# favorites_print_rows XML - print the favorites table or, with --json, an
# object with a "favorites" array. Prints a hint when the list is empty.
favorites_print_rows() {
  local xml="$1" line=""
  if output_json_enabled; then
    output_json_list_begin "favorites"
    while IFS= read -r line; do
      record_split "$line" "${FAVORITES_RECORD_FIELDS[@]}"
      [[ -n "$FAVORITES_RECORD_PATH" ]] || continue
      output_json_object_begin
      output_json_kv "path" "$FAVORITES_RECORD_PATH"
      output_json_kv "size" "$FAVORITES_RECORD_SIZE"
      output_json_kv "modified" "$FAVORITES_RECORD_MODIFIED"
      output_json_object_end
    done < <(favorites_parse_xml "$xml")
    output_json_list_end
    return 0
  fi
  output_rows "no favorites" favorites_print_row 0 \
    '%-40s %-12s %s\n' "Path" "Size" "Modified" \
    < <(favorites_parse_xml "$xml")
}

cmd_favorites() {
  local p1="" p2="" p3="" action="list" sub=""
  opt_begin "json:b" favorites "" "$@"
  # The DAV listing and property updates use the http/nc_api helpers; load
  # them after opt_begin's --help exit so `sciebo favorites --help` parses
  # none of them.
  split_positionals_into p1 p2 p3
  [[ "${#POSITIONAL_ARGS[@]}" -le 3 ]] ||
    usage_error favorites "unexpected argument: $(printable "${POSITIONAL_ARGS[3]}")"
  case "$p1" in
    '' | list)
      action=list
      [[ -z "$p2" ]] || usage_error favorites "unexpected argument: $(printable "$p2")"
      ;;
    add | remove)
      action="$p1"
      [[ -n "$p2" ]] || usage_error favorites "${p1} requires a remote path (SUB)"
      [[ -z "$p3" ]] || usage_error favorites "unexpected argument: $(printable "$p3")"
      opt_reject favorites "$action" json
      sub="$p2"
      require_safe_remote_path "$sub"
      ;;
    *)
      usage_unknown_sub favorites "$p1"
      ;;
  esac
  opt_json_mode
  http_load_context
  case "$action" in
    list)
      nc_favorites_list
      favorites_print_rows "$HTTP_BODY"
      ;;
    add)
      nc_favorite_set "$sub" on
      printf 'favorited %s\n' "$(printable "$sub")"
      ;;
    remove)
      nc_favorite_set "$sub" off
      printf 'unfavorited %s\n' "$(printable "$sub")"
      ;;
  esac
  return 0
}
