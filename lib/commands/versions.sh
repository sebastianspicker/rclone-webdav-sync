#!/bin/bash
# versions.sh command module - list, download, restore, and delete Nextcloud
# file versions. Resolves a remote path's file id and lists its versions via
# the WebDAV versions endpoint through lib/http.sh; restoring and deleting
# are confirmed interactively (or require --yes).

VERSIONS_RECORD_VERSION=""
VERSIONS_RECORD_MODIFIED=""
VERSIONS_RECORD_SIZE=""
VERSIONS_FILEID=""
VERSIONS_LIST_XML=""
# Parsed by versions_parse_action: the remote path and the selected action
# (empty means list) with its version.
VERSIONS_SUB=""
VERSIONS_ACTION=""
VERSIONS_VERSION=""
VERSIONS_FILEID_BODY='<?xml version="1.0"?>
<d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
  <d:prop>
    <oc:fileid/>
  </d:prop>
</d:propfind>'
VERSIONS_LIST_BODY='<?xml version="1.0"?>
<d:propfind xmlns:d="DAV:">
  <d:prop>
    <d:getlastmodified/>
    <d:getcontentlength/>
  </d:prop>
</d:propfind>'

usage_versions() {
  usage_emit <<'EOF'
Usage: sciebo versions SUB [options]

List the Nextcloud versions of a remote path below
<RCLONE_REMOTE>:<REMOTE_BASE>/ (read-only by default). The path is resolved
to a file id first; a path that does not exist or is not a file has none.

Options:
  --download VERSION  save VERSION; default target ./<name>.<VERSION>
  --output FILE       write the --download body to FILE
  --stdout            stream the --download body to standard output
  --restore VERSION   restore VERSION (asks first; needs --yes when not
                      running interactively)
  --delete VERSION    delete VERSION (asks first; needs --yes when not
                      running interactively)
  --yes               skip the --restore/--delete confirmation
  -h, --help          show this help
EOF
}

# versions_parse_action "$@" - parse the options and the single positional
# remote path into the VERSIONS_SUB/VERSIONS_ACTION/VERSIONS_VERSION globals.
# Validates the option combinations and the numeric version in the original
# order, then checks the path is safe.
versions_parse_action() {
  local actions=0
  opt_begin "download:s restore:s delete:s output:s stdout:b yes:b" versions "" "$@"
  # Exactly one positional (the remote path); path safety stays with
  # require_safe_remote_path below.
  opt_require_sub versions "a remote path argument" "${OPT_EXTRA:-}" 1 1 \
    "exactly one remote path argument is required"
  VERSIONS_SUB="${POSITIONAL_ARGS[0]}"
  VERSIONS_ACTION=""
  VERSIONS_VERSION=""
  [[ -z "${OPT_download_SET:-}" ]] || actions=$((actions + 1))
  [[ -z "${OPT_restore_SET:-}" ]] || actions=$((actions + 1))
  [[ -z "${OPT_delete_SET:-}" ]] || actions=$((actions + 1))
  [[ "$actions" -le 1 ]] ||
    usage_error versions "--download, --restore, and --delete are mutually exclusive"
  if [[ -z "${OPT_download_SET:-}" ]]; then
    [[ -z "${OPT_output_SET:-}" ]] || usage_error versions "--output requires --download"
    [[ -z "${OPT_stdout_SET:-}" ]] || usage_error versions "--stdout requires --download"
  fi
  [[ -z "${OPT_output_SET:-}" || -z "${OPT_stdout_SET:-}" ]] ||
    usage_error versions "--output and --stdout are mutually exclusive"
  if [[ -n "${OPT_download_SET:-}" ]]; then
    VERSIONS_ACTION=download
    VERSIONS_VERSION="${OPT_download:-}"
  elif [[ -n "${OPT_restore_SET:-}" ]]; then
    VERSIONS_ACTION=restore
    VERSIONS_VERSION="${OPT_restore:-}"
  elif [[ -n "${OPT_delete_SET:-}" ]]; then
    VERSIONS_ACTION=delete
    VERSIONS_VERSION="${OPT_delete:-}"
  fi
  if [[ -n "$VERSIONS_ACTION" ]]; then
    is_uint "$VERSIONS_VERSION" || usage_error versions "--${VERSIONS_ACTION} requires a numeric version"
  fi
  require_safe_remote_path "$VERSIONS_SUB"
}

# versions_parse_fileid XML - print the numeric file id of the first
# <oc:fileid> value; empty when the property is absent or not numeric.
# xml_get comes from lib/http.sh, which the guard above loads when this
# module is sourced on its own (nc_parse_fileid is the nc_api copy).
versions_parse_fileid() {
  local fileid=""
  fileid="$(xml_get "$1" oc:fileid)"
  is_uint "$fileid" || fileid=""
  printf '%s' "$fileid"
}

# versions_id_from_href HREF - the percent-decoded last path segment of a
# listing href (the version label): the shell twin of http.sh's awk
# xml_href_segment (strip the trailing slashes, take the segment, then
# decode), so versions_parse_xml can read the raw d:href through the shared
# xml_records walker instead of its own <d:response> loop.
versions_id_from_href() {
  href_last_segment "${1:-}"
}

# versions_parse_xml XML - print one TAB-separated record per <d:response>
# through the shared xml_records walker: version (last href segment,
# percent-decoded), last modified, and size. Tolerates missing properties,
# self-closed tags, and whitespace/newlines inside tags; the size check runs
# on the parsed record here.
versions_parse_xml() {
  local line="" version="" modified="" size="" href=""
  while IFS= read -r line; do
    record_split "$line" href modified size
    is_uint "$size" || size=""
    version=${ versions_id_from_href "$href";}
    modified=${ printable "$modified";}
    size=${ printable "$size";}
    printf '%s\t%s\t%s\n' "$version" "$modified" "$size"
  done < <(xml_records "$1" 'd:response' \
    'd:href' 'd:getlastmodified' 'd:getcontentlength')
}

# versions_version_url FILEID VERSION - print the absolute WebDAV URL of one
# version of FILEID.
versions_version_url() {
  nc_dav_url "versions/${HTTP_USER}/versions/$1/$2"
}

# versions_resolve SUB - fill VERSIONS_FILEID and VERSIONS_LIST_XML with the
# shared PROPFIND pair: the file id of SUB (Depth 0) and its version listing
# (Depth 1). Dies when SUB has no numeric file id.
versions_resolve() {
  local sub="$1" url="" fileid=""
  url="$(nc_path_url "${REMOTE_BASE}/${sub}")"
  nc_dav_request PROPFIND "$url" 0 "$VERSIONS_FILEID_BODY"
  fileid="$(versions_parse_fileid "$HTTP_BODY")"
  [[ -n "$fileid" ]] ||
    die "no file id for '${sub}' below ${RCLONE_REMOTE}:${REMOTE_BASE}/ (not found, or not a file)"
  VERSIONS_FILEID="$fileid"
  nc_dav_request PROPFIND "$(nc_dav_url "versions/${HTTP_USER}/versions/${fileid}")" 1 "$VERSIONS_LIST_BODY"
  VERSIONS_LIST_XML="$HTTP_BODY"
}

# versions_confirm ACTION VERSION - 0 when the action may proceed. --yes
# skips the prompt; a non-interactive run without it is a usage error. A
# "no" answer returns 1 so the caller can abort cleanly.
versions_confirm() {
  local action="$1" version="$2" verb=""
  case "$action" in
    restore) verb="Restore" ;;
    delete) verb="Delete" ;;
  esac
  ui_confirm_mutation versions \
    "--${action} requires --yes when not running interactively" \
    "${verb} version ${version}? [y/N]: "
}

# versions_fetch URL VERSION TARGET STDOUT - GET a version URL through the
# shared http_fetch helpers. With STDOUT=1 the body goes straight to standard
# output; otherwise it is written to TARGET only on success, so a failed
# request never truncates an existing TARGET. A TARGET that is a symlink is
# refused. HTTP 404 dies with a dedicated message, any other HTTP error with
# the status.
versions_fetch() {
  local url="$1" version="$2" target="$3" to_stdout="$4"
  if [[ "$to_stdout" -eq 1 ]]; then
    http_fetch_stdout "$url" "no such version ${version} (GET ${url}: HTTP 404)"
    return 0
  fi
  http_fetch_to_file "$url" "$target" "no such version ${version} (GET ${url}: HTTP 404)"
}

# versions_check_action METHOD URL VERSION - die unless the last request
# succeeded; a 404 is reported as a missing version. The action is a MOVE or
# DELETE, so a 3xx redirect (curl does not follow those for writes) is a
# failure, not a success.
versions_check_action() {
  local method="$1" url="$2" version="$3"
  http_ok_code_2xx "$HTTP_CODE" && return 0
  if [[ "$HTTP_CODE" == "404" ]]; then
    die "no such version ${version} (${method} ${url}: HTTP 404)"
  fi
  http_die_http_error "$method" "$url"
}

# versions_print_row LINE - print one version table row; non-zero when the
# record has no version or is the collection row itself.
versions_print_row() {
  local version="" modified="" size=""
  record_split "$1" VERSIONS_RECORD_VERSION VERSIONS_RECORD_MODIFIED \
    VERSIONS_RECORD_SIZE
  [[ -n "$VERSIONS_RECORD_VERSION" ]] || return 1
  [[ "$VERSIONS_RECORD_VERSION" != "$VERSIONS_FILEID" ]] || return 1
  version=${ printable "$VERSIONS_RECORD_VERSION";}
  modified=${ printable "$VERSIONS_RECORD_MODIFIED";}
  size=${ printable "$VERSIONS_RECORD_SIZE";}
  size=${ format_size_bytes "$size";}
  printf '%-20s %-32s %s\n' "$version" "$modified" "$size"
  return 0
}

# versions_run_list - print the version table of VERSIONS_LIST_XML.
versions_run_list() {
  output_rows "no versions" versions_print_row 0 \
    '%-20s %-32s %s\n' "Version" "Modified" "Size" \
    < <(versions_parse_xml "$VERSIONS_LIST_XML")
}

# versions_run_download VERSION URL - GET the version to --output, the default
# ./<name>.<VERSION> target, or standard output with --stdout.
versions_run_download() {
  local version="$1" url="$2" target=""
  if [[ "${OPT_stdout:-0}" == "1" ]]; then
    versions_fetch "$url" "$version" "" 1
    return 0
  fi
  target="${OPT_output:-./${VERSIONS_SUB##*/}.${version}}"
  versions_fetch "$url" "$version" "$target" 0
  printf 'downloaded %s -> %s\n' "$version" "$target"
}

# versions_run_restore VERSION URL - MOVE the version back to its file.
versions_run_restore() {
  local version="$1" url="$2" dest=""
  dest="$(nc_dav_url "versions/${HTTP_USER}/restore/target")"
  nc_dav_request_allow MOVE "$url" "" "" -H "Destination: ${dest}"
  versions_check_action MOVE "$url" "$version"
  printf 'restored %s\n' "$version"
}

# versions_run_delete VERSION URL - DELETE one version.
versions_run_delete() {
  local version="$1" url="$2"
  nc_dav_request_allow DELETE "$url"
  versions_check_action DELETE "$url" "$version"
  printf 'deleted %s\n' "$version"
}

cmd_versions() {
  local url=""
  versions_parse_action "$@"
  # Run dependencies load after the parse (its opt_begin consumed --help),
  # so `sciebo versions --help` parses none of them: versions_parse_fileid
  # and the file-id lookup use the http/nc_api helpers (unit tests that
  # source this module alone still get them loaded on demand here), and the
  # restore/delete confirmation prompts through ui.
  sciebo_require_module http xml_get
  sciebo_require_module nc_api nc_dav_request_allow
  sciebo_require_module ui ui_confirm_mutation
  case "$VERSIONS_ACTION" in
    restore | delete) versions_confirm "$VERSIONS_ACTION" "$VERSIONS_VERSION" || return 0 ;;
  esac
  http_load_context
  versions_resolve "$VERSIONS_SUB"
  if [[ -z "$VERSIONS_ACTION" ]]; then
    versions_run_list
    return 0
  fi
  url=${ versions_version_url "$VERSIONS_FILEID" "$VERSIONS_VERSION";}
  case "$VERSIONS_ACTION" in
    download) versions_run_download "$VERSIONS_VERSION" "$url" ;;
    restore) versions_run_restore "$VERSIONS_VERSION" "$url" ;;
    delete) versions_run_delete "$VERSIONS_VERSION" "$url" ;;
  esac
  return 0
}
