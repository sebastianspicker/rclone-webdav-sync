#!/bin/bash
# preview.sh command module - fetch a Nextcloud preview thumbnail.
#
# Resolves the remote file id through lib/nc_api.sh and downloads the image
# the core preview endpoint generates for it. The bytes are written to a file
# (or standard output) unchanged. Not every file has a preview, so a 404 is
# reported as "previews are not available for this file".

# Settings defaults (config/settings.env is the shipped layer; these keep the
# module usable when it is sourced on its own). Never print secrets here.
: "${PREVIEW_SIZE:=256}"
: "${DEFAULT_PREVIEW_FILE:=./preview}"

usage_preview() {
  usage_emit <<'EOF'
Usage: sciebo preview SUB [options]

Download a preview image of the remote file SUB below the configured remote
base. The file must be one Nextcloud can render (images, PDFs, text, ...);
files without a preview fail with "previews are not available for this file".

Options:
  --output FILE  write the image to FILE (default: DEFAULT_PREVIEW_FILE,
                 ./preview); use "-" to write the image to standard output
  --size N       preview edge size in pixels (default: PREVIEW_SIZE, 256)
  -h, --help     show this help
EOF
}

# preview_resolve_size - print the preview edge size: --size when given,
# otherwise PREVIEW_SIZE. A non-numeric or zero value is rejected.
preview_resolve_size() {
  local size="${PREVIEW_SIZE:-256}"
  if [[ -n "${OPT_size_SET:-}" ]]; then
    opt_require_uint preview --size "${OPT_size:-}" 1
    size="${OPT_size}"
  fi
  is_uint "$size" ||
    die "invalid PREVIEW_SIZE setting: $(printable "$size") (expected a positive integer)"
  # A zero value (from either layer) keeps surfacing as the --size usage
  # error, exactly as before.
  opt_require_uint preview --size "$size" 1
  printf '%s' "$size"
}

# preview_url FILEID SIZE - the absolute core preview URL.
preview_url() {
  printf '%s/index.php/core/preview?fileId=%s&x=%s&y=%s&a=1' \
    "$HTTP_BASE" "$1" "$2" "$2"
}

# preview_fetch URL SUB TARGET STDOUT - GET the preview through the shared
# http_fetch helpers. With STDOUT=1 the bytes stream straight to standard
# output, binary-safe; otherwise they are written to TARGET only after a
# 2xx/3xx response with a non-empty body, so a failed request never leaves a
# partial TARGET. A TARGET that is a symlink is refused before the request
# with preview's dedicated message. A 404 is reported as a missing preview;
# any other HTTP failure goes through the shared error.
preview_fetch() {
  local url="$1" sub="$2" target="$3" to_stdout="$4"
  if [[ "$to_stdout" -eq 1 ]]; then
    http_fetch_stdout "$url" \
      "previews are not available for this file: $(printable "$sub") (GET ${url}: HTTP 404)"
    return 0
  fi
  [[ ! -L "$target" ]] || die "refusing to write preview through symlink: ${target}"
  # shellcheck disable=SC2034  # read by http_fetch_to_file in lib/http.sh
  HTTP_FETCH_EMPTY_MSG="the server returned an empty preview for $(printable "$sub")"
  http_fetch_to_file "$url" "$target" \
    "previews are not available for this file: $(printable "$sub") (GET ${url}: HTTP 404)"
}

cmd_preview() {
  local sub="" size="" fileid="" url="" target="" to_stdout=0
  opt_begin "output:s size:s" preview "" "$@"
  # The file-id lookup and preview download use the http/nc_api helpers;
  # load them after opt_begin's --help exit so `sciebo preview --help`
  # parses none of them.
  sciebo_require_module http xml_get
  sciebo_require_module nc_api nc_dav_request_allow
  opt_require_sub preview SUB "${OPT_EXTRA:-}"
  sub="${POSITIONAL_ARGS[0]}"
  sub=${ strip_trailing_slashes "$sub";}
  require_safe_remote_path "$sub"
  size="$(preview_resolve_size)"
  http_load_context
  fileid="$(nc_fileid "${REMOTE_BASE}/${sub}")"
  url="$(preview_url "$fileid" "$size")"
  target="${OPT_output:-$DEFAULT_PREVIEW_FILE}"
  if [[ "$target" == "-" ]]; then
    to_stdout=1
  fi
  preview_fetch "$url" "$sub" "$target" "$to_stdout"
  [[ "$to_stdout" -eq 1 ]] || printf 'saved preview -> %s\n' "$target"
  return 0
}
