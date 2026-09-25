#!/bin/bash
# filters.sh command module - rclone filter file management.
#
# `filters sync` fetches the server's canonical Nextcloud exclude list
# (sync-exclude.lst), caches the raw body, and regenerates the rclone filter
# file that sync layers under every source when FILTER_SERVER_SYNC=1.
# `list`, `show`, and `check` are read-only. Only the sync subcommand writes,
# and it replaces the cache and the generated filter atomically; no run lock
# is needed (nothing else reads them as shared state).
#
# The sync/hydrate/ignored integration (filter_server_filter_enabled,
# filter_server_filter_file) lives in lib/sync/filters.sh: it is domain
# filter state, not part of this command's own subcommands.

usage_filters() {
  usage_emit <<'EOF'
Usage: sciebo filters <subcommand>

Manage the rclone filter files in FILTER_DIR.

Subcommands:
  sync [--json]           fetch the server's sync-exclude.lst, cache the raw
                          body, and regenerate the server filter file
  list [--json]           table of *.txt filter files plus the age and
                          staleness of the server cache
  show NAME               print one filter file (bare file name)
  check                   validate every *.txt filter with rclone's parser

`filters sync` replaces the cache (sync-exclude.lst) and the generated
server filter (server-exclude.txt) atomically and takes no run lock.

Options:
  --json      sync/list: print the result as JSON instead of the table
  -h, --help  show this help
EOF
}

# filters_pattern_count FILE - number of non-blank, non-comment rules.
filters_pattern_count() {
  awk '
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*#/ { next }
    { n++ }
    END { print n + 0 }
  ' "$1"
}

# filters_validate_body FILE - reject a server-provided sync-exclude body that
# cannot be trusted as a plain pattern list: control bytes, a leading rclone
# rule sign (+/-), an over-long line, or an implausible number of rules. This
# keeps a hostile server from injecting include rules or malformed globs into
# the filters `sync`/`bisync`/`hydrate` later consume. Dies on the first
# offender with the line number.
filters_validate_body() {
  local file="$1" line="" n=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    case "$line" in
      '' | [[:space:]]*'#'* | '#'*) continue ;;
    esac
    case "$line" in
      *[[:cntrl:]]*) die "filters sync: refusing server filter with control bytes (line ${n})" ;;
      [+-]*) die "filters sync: refusing server filter line starting with a rule sign (line ${n}): ${ printable "$line";}" ;;
    esac
    ((${#line} <= 4096)) || die "filters sync: refusing over-long server filter line (line ${n})"
    ((n <= 100000)) || die "filters sync: refusing server filter with too many lines"
  done <"$file"
  return 0
}

# filters_generate_filter - rewrite SERVER_EXCLUDE_FILTER from the cached
# raw body: one "- <pattern>" rule per non-blank, non-comment line, pattern
# text kept verbatim.
filters_generate_filter() {
  awk '
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*#/ { next }
    { print "- " $0 }
  ' "$SERVER_EXCLUDE_FILE" | atomic_write "$SERVER_EXCLUDE_FILTER" 644
}

# filters_server_url - print the sync-exclude.lst URL. HTTP_BASE comes from
# http_remote_info; a usable capabilities_base_url wins.
filters_server_url() {
  local base="${HTTP_BASE:-}" cap=""
  if type capabilities_base_url >/dev/null 2>&1 && cap="$(capabilities_base_url 2>/dev/null)"; then
    base="$cap"
  fi
  [[ -n "$base" ]] || base="$HTTP_BASE"
  [[ -n "$base" ]] || die "cannot derive the server base URL; run '${CLI_NAME} setup' first"
  printf '%s/sync-exclude.lst' "${base%/}"
}

# filters_cmd_sync [--json] - fetch, cache, and regenerate.
filters_cmd_sync() {
  local json=false url="" base="" host="" tmp="" patterns="" json_mode=0
  opt_begin "json:b" filters "sync: " "$@"
  opt_guard filters "sync: "
  opt_json_mode
  output_json_enabled && json_mode=1

  load_settings
  require_remote
  http_remote_info
  url="$(filters_server_url)"
  temp_mktemp_into tmp "${TMPDIR:-/tmp}/sciebo-filters.XXXXXX" || die "cannot create temp file"
  http_download "$url" "$tmp"
  if [[ ! -s "$tmp" ]]; then
    temp_discard "$tmp"
    die "filters sync: ${url} returned an empty body"
  fi
  filters_validate_body "$tmp"
  atomic_write "$SERVER_EXCLUDE_FILE" 644 <"$tmp"
  temp_discard "$tmp"
  filters_generate_filter
  patterns="$(filters_pattern_count "$SERVER_EXCLUDE_FILE")"
  base="${url%/sync-exclude.lst}"
  host="${base#*://}"
  host="${host%%/*}"
  if [[ "$json_mode" -eq 1 ]]; then
    output_json_begin
    output_json_kv_raw patterns "$patterns"
    output_json_kv file "$SERVER_EXCLUDE_FILE"
    output_json_kv source "$url"
    output_json_end
  else
    printf 'filters: fetched %s patterns from %s\n' "$patterns" "$host"
  fi
  return 0
}

# filters_list_row FILE JSON_MODE - emit one filters list row: the file's name,
# rule count, mtime, and whether it is the generated server filter, as a JSON
# object (JSON_MODE 1) or a table line.
filters_list_row() {
  local file="$1" json_mode="$2" name="" rules=0 mtime=0 server=0 mtime_label="" server_label=""
  name="${file##*/}"
  rules="$(filters_pattern_count "$file")"
  mtime=${ file_mtime_or "$file" 0;}
  server=0
  [[ "$file" == "$SERVER_EXCLUDE_FILTER" ]] && server=1
  if [[ "$json_mode" -eq 1 ]]; then
    output_json_object_begin
    output_json_kv name "$name"
    output_json_kv_raw rules "$rules"
    output_json_kv_raw mtime "$mtime"
    if [[ "$server" -eq 1 ]]; then
      output_json_kv_raw server true
    else
      output_json_kv_raw server false
    fi
    output_json_object_end
  else
    mtime_label=${ epoch_to_stamp "$mtime";}
    if [[ "$server" -eq 1 ]]; then
      server_label="yes"
    else
      server_label="-"
    fi
    printf '%-32s %5s  %-16s %s\n' "$name" "$rules" "$mtime_label" "$server_label"
  fi
  return 0
}

# filters_list_cache CACHE MAX_AGE JSON_MODE - emit the server cache age and
# staleness: the trailing JSON cache object (and end) or the human line.
filters_list_cache() {
  local cache="$1" max_age="$2" json_mode="$3" now="" age="" state="missing"
  if [[ -n "$cache" && -f "$cache" ]]; then
    now=${ now_epoch;}
    age=$((now - $(file_mtime_or "$cache" 0)))
    [[ "$age" -ge 0 ]] || age=0
    if [[ "$max_age" -gt 0 && "$age" -lt "$max_age" ]]; then
      state="fresh"
    else
      state="stale"
    fi
  fi
  if [[ "$json_mode" -eq 1 ]]; then
    output_json_object_begin cache
    output_json_kv file "$cache"
    if [[ -n "$age" ]]; then
      output_json_kv_raw age "$age"
    else
      output_json_kv_raw age null
    fi
    if [[ "$state" == "fresh" ]]; then
      output_json_kv_raw stale false
    else
      output_json_kv_raw stale true
    fi
    output_json_kv_raw max_age "$max_age"
    output_json_object_end
    output_json_end
  else
    if [[ "$state" == "missing" ]]; then
      printf 'server filter cache: %s (missing; run '\''%s filters sync'\'')\n' "$cache" "$CLI_NAME"
    else
      printf 'server filter cache: %s (age %ss, %s; max %ss)\n' "$cache" "$age" "$state" "$max_age"
    fi
  fi
  return 0
}

# filters_cmd_list [--json] - one row per *.txt filter file plus the server
# cache age and staleness.
filters_cmd_list() {
  # shellcheck disable=SC2034  # option locals mirror the parsed flags
  local json=false file="" json_mode=0 max_age="" cache=""
  opt_begin "json:b" filters "list: " "$@"
  opt_guard filters "list: "
  load_settings --no-rclone
  max_age="${SERVER_EXCLUDE_MAX_AGE:-0}"
  opt_json_mode
  output_json_enabled && json_mode=1
  # Settings-derived age threshold: keep a digits-only value, else 0.
  max_age="${ default_uint "$max_age" 0;}"
  cache="${SERVER_EXCLUDE_FILE:-}"

  if [[ "$json_mode" -eq 1 ]]; then
    output_json_begin
    output_json_array_begin files
  else
    printf '%-32s %5s  %-16s %s\n' "NAME" "RULES" "MTIME" "SERVER"
  fi
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    filters_list_row "$file" "$json_mode"
  done < <(find "$FILTER_DIR" -maxdepth 1 -type f -name '*.txt' 2>/dev/null | LC_ALL=C sort)
  if [[ "$json_mode" -eq 1 ]]; then
    output_json_array_end
  fi
  filters_list_cache "$cache" "$max_age" "$json_mode"
  return 0
}

# filters_cmd_show NAME - print a filter file after validating the name.
filters_cmd_show() {
  local name=""
  case "${1:-}" in
    -h | --help)
      usage_filters
      return 0
      ;;
  esac
  name="${1:-}"
  [[ -n "$name" ]] || usage_error filters "show: NAME is required"
  [[ $# -le 1 ]] || usage_error filters "show: unexpected extra argument: ${2:-}"
  safe_filter_name "$name" || die "invalid filter name '${ printable "$name";}'"
  load_settings --no-rclone
  [[ -f "${FILTER_DIR}/${name}" ]] || die "filter file not found: ${FILTER_DIR}/${name}"
  cat "${FILTER_DIR}/${name}"
}

# filters_cmd_check - parse every *.txt filter with rclone and report
# PASS/FAIL per file; exit 1 when any file is rejected.
filters_cmd_check() {
  local file="" name="" message="" failures=0 checked=0
  local -a files=() check_args=()
  case "${1:-}" in
    -h | --help)
      usage_filters
      return 0
      ;;
  esac
  [[ $# -eq 0 ]] || usage_error filters "check: unexpected argument: ${1:-}"
  load_settings
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    files+=("$file")
    check_args+=(--filter-from "$file")
  done < <(find "$FILTER_DIR" -maxdepth 1 -type f -name '*.txt' 2>/dev/null | LC_ALL=C sort)
  checked="${#files[@]}"
  if [[ "$checked" -eq 0 ]]; then
    warn "no *.txt filter files found in ${FILTER_DIR}"
    return 0
  fi
  # One invocation parses every file together; a clean run prints one PASS per
  # file, and a rejection falls back to per-file runs to name the offenders.
  if rclone_cmd "${check_args[@]}" lsf :memory: --max-depth 0 >/dev/null 2>&1; then
    for file in "${files[@]}"; do
      printf 'PASS  %s\n' "${file##*/}"
    done
    return 0
  fi
  for file in "${files[@]}"; do
    name="${file##*/}"
    message=""
    if message="$(rclone_cmd --filter-from "$file" lsf :memory: --max-depth 0 2>&1 >/dev/null)"; then
      printf 'PASS  %s\n' "$name"
    else
      failures=$((failures + 1))
      printf 'FAIL  %s\n' "$name"
      [[ -z "$message" ]] || printf '      %s\n' "${message%%$'\n'*}"
    fi
  done
  [[ "$failures" -eq 0 ]]
}

cmd_filters() {
  local sub="${1:-}"
  case "$sub" in
    sync) shift && filters_cmd_sync "$@" ;;
    list) shift && filters_cmd_list "$@" ;;
    show) shift && filters_cmd_show "$@" ;;
    check) shift && filters_cmd_check "$@" ;;
    -h | --help) usage_filters ;;
    '') usage_error filters "missing subcommand" ;;
    *) usage_error filters "unknown command: ${sub}" ;;
  esac
}
