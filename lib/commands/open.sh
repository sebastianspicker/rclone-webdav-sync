#!/bin/bash
# open.sh command module - open the local folder of a configured source, or
# the matching Nextcloud web UI target with --web. Local resolution happens
# against the manifest and FOLDERS_LOCAL_ROOT without network access. --web
# builds a URL from the configured remote: a remote file resolves to its
# direct /index.php/f/<fileid> link, a directory (or an unresolvable path)
# to the Files app folder URL, and the result is handed to the opener.

usage_open() {
  usage_emit <<'EOF'
Usage: sciebo open [SUB] [--print] [--web]

Open the local folder for SUB. The first valid manifest entry whose
remote_subdir, local path, or entry name equals SUB wins; without a match
SUB is resolved below FOLDERS_LOCAL_ROOT (the root itself when SUB is
omitted). The folder must exist: run `sciebo sync` first.

With --web, open SUB in the Nextcloud web UI instead of the local folder:
a remote file opens at its direct /index.php/f/<fileid> link, a directory
at the Files app folder /<REMOTE_BASE>[/SUB] (also the fallback when SUB
cannot be resolved).

Options:
  --web       open the target in the Nextcloud web UI
  --print     print the resolved path or URL instead of opening it
  -h, --help  show this help
EOF
}

# open_resolve_match SUB - non-zero (stop) for the first entry whose remote
# subdir, local path, or entry name equals SUB, after printing its local path.
open_resolve_match() {
  [[ "${ENTRY_REMOTE:-}" == "$1" || "${ENTRY_LOCAL:-}" == "$1" || "${ENTRY_NAME:-}" == "$1" ]] || return 0
  printf '%s\n' "$ENTRY_LOCAL"
  return 1
}

# open_resolve SUB - print the local folder for SUB: the matching manifest
# entry, else FOLDERS_LOCAL_ROOT[/SUB]. A manifest match is exact, so it is
# trusted; the root-join fallback validates SUB first and dies on a path that
# could escape the root.
open_resolve() {
  local sub="$1" root=""
  if ! manifest_each open_resolve_match "$sub"; then
    return 0
  fi
  root=${ strip_trailing_slashes "$FOLDERS_LOCAL_ROOT";}
  if [[ -n "$sub" ]]; then
    open_require_sub "$sub"
    printf '%s/%s\n' "$root" "$sub"
  else
    printf '%s\n' "$root"
  fi
  return 0
}

# open_require_sub SUB - validate a local SUB before it is joined below the
# configured root: safe_local_path rejects "."/".." segments, "|", control
# bytes, and surrounding whitespace, and a leading "/" is refused so an
# absolute path can never escape FOLDERS_LOCAL_ROOT.
open_require_sub() {
  local sub="$1"
  [[ -n "$sub" ]] || return 0
  safe_local_path "$sub" && [[ "$sub" != /* ]] && return 0
  die "unsafe local path '$(printable "$sub")': use a relative path below the local root without '.' or '..'"
}

# open_web_url SUB - print the Nextcloud Files app URL for SUB below
# REMOTE_BASE. Requires load_settings and http_remote_info to have run.
open_web_url() {
  local sub="$1" dir=""
  dir="/${REMOTE_BASE}"
  [[ -z "$sub" ]] || dir="${dir}/${sub}"
  printf '%s/index.php/apps/files/?dir=%s' "$HTTP_BASE" "$(http_urlencode "$dir")"
}

# open_web_fileid SUB - print SUB's file id when it resolves to a remote
# file; rc 1 for a directory or when the path cannot be resolved. This is
# the non-fatal form of nc_fileid: a missing or non-2xx path must fall back
# to the Files-app folder URL instead of failing. The INFO propfind body is
# used so a directory can be told apart by its <d:collection>/resourcetype.
open_web_fileid() {
  local sub="$1" url="" body="" fileid=""
  [[ -n "$sub" ]] || return 1
  url="$(nc_path_url "${REMOTE_BASE}/${sub}")"
  nc_dav_request_allow PROPFIND "$url" 0 "$NC_FILE_INFO_BODY"
  http_ok_code_2xx "$HTTP_CODE" || return 1
  body="$HTTP_BODY"
  case "$body" in
    *'<d:collection'*) return 1 ;;
  esac
  fileid="$(nc_parse_fileid "$body")"
  is_uint "$fileid" || return 1
  printf '%s' "$fileid"
}

cmd_open() {
  local sub="" path="" url="" fileid="" print=0 web=0
  opt_begin "print:b web:b" open "" "$@"
  # Run dependencies load after opt_begin's --help exit, so
  # `sciebo open --help` parses none of them: nc_api/http provide the
  # non-fatal DAV probe and its XML helpers, the resolution walks the
  # manifest, and the launch uses the platform opener.
  # SUB is optional (MIN 0); a second positional is rejected with the same
  # wording the inline check used. No strip/path-safety pass follows here:
  # open resolves SUB against the manifest or below FOLDERS_LOCAL_ROOT and
  # validates it in open_require_sub.
  opt_require_sub open "SUB" "${OPT_EXTRA:-}" 0
  sub="${POSITIONAL_ARGS[0]:-}"
  opt_into print print 1
  opt_into web web 1
  if [[ "$web" -eq 1 ]]; then
    load_settings
    http_remote_info
    url="$(open_web_url "$sub")"
    if [[ -n "$sub" ]]; then
      # A probe failure (offline, missing, directory) keeps the folder URL.
      fileid="$(open_web_fileid "$sub" 2>/dev/null)" || fileid=""
      [[ -z "$fileid" ]] || url="${HTTP_BASE}/index.php/f/${fileid}"
    fi
    if [[ "$print" -eq 1 ]]; then
      printf '%s\n' "$url"
      return 0
    fi
    platform_open "$url"
    return 0
  fi
  load_settings --no-rclone
  path="$(open_resolve "$sub")"
  [[ -d "$path" ]] ||
    die "no local folder at '${path}'; run '${CLI_NAME} sync' to create it"
  if [[ "$print" -eq 1 ]]; then
    printf '%s\n' "$path"
    return 0
  fi
  platform_open "$path"
  return 0
}
