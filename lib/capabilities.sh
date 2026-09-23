#!/bin/bash
# capabilities.sh - Nextcloud OCS capabilities probe.
#
# `capabilities_probe` asks the server for its OCS capabilities with the
# app password, parses the few facts this tooling cares about without jq,
# and caches both the raw response (CAPABILITIES_JSON) and a sanitized,
# sourceable env file (CAPABILITIES_CACHE). Parsing is best-effort: every
# fact that cannot be read stays empty and callers treat empty as unknown.
#
# The request goes through the shared lib/http.sh plumbing when it is
# loaded (netrc password path, PROXY/PROXY_DIRECT, TLS_INSECURE, timeouts)
# and falls back to a plain curl for standalone library use, so the probe
# also works before/without http_remote_info.
#
# The cache is sourced by capabilities_load, so server-controlled text only
# reaches it after _capabilities_sanitize.

# now_epoch comes from lib/duration.sh.
sciebo_require_module duration now_epoch

CAP_VERSION=""
CAP_BIGFILE_CHUNKING=""
CAP_CHUNK_MAX_SIZE=""
CAP_UNDELETE=""
CAP_CHECKSUMS=""

# safe_source_file lives in lib/core.sh so settings loading can use it too.

# capabilities_sync_chunk_size memoization (at most one resolution per run).
CAPABILITIES_CHUNK_RESOLVED=0
CAPABILITIES_CHUNK_VALUE=""

# _capabilities_sanitize VALUE - keep [A-Za-z0-9._:+-] and drop everything
# else (including newlines), so server-controlled values cannot escape a
# cache assignment.
_capabilities_sanitize() {
  local s="$1"
  local LC_ALL=C
  s="${s//[^A-Za-z0-9._:+-]/}"
  printf '%s' "$s"
}

# capabilities_chunk_for_duration DURATION_S THROUGHPUT_BPS MAX_BYTES -
# print the upload chunk size in bytes for a sync run: THROUGHPUT_BPS times
# DURATION_S seconds, clamped up to MIN_CHUNK_SIZE and down to
# min(MAX_CHUNK_SIZE, MAX_BYTES). MIN_CHUNK_SIZE/MAX_CHUNK_SIZE are optional
# and parsed with size_suffix_bytes when set; an unparseable bound is
# ignored. Prints nothing and returns 1 when any of the three arguments is
# missing, non-numeric, or not positive. Pure apart from the size parser.
capabilities_chunk_for_duration() {
  local duration="${1:-}" throughput="${2:-}" max_bytes="${3:-}"
  local value="" bound="" max_bound=""
  case "$duration" in '' | *[!0-9]*) return 1 ;; esac
  case "$throughput" in '' | *[!0-9]*) return 1 ;; esac
  case "$max_bytes" in '' | *[!0-9]*) return 1 ;; esac
  duration="$((10#$duration))"
  throughput="$((10#$throughput))"
  max_bytes="$((10#$max_bytes))"
  [[ "$duration" -gt 0 && "$throughput" -gt 0 && "$max_bytes" -gt 0 ]] || return 1
  value=$((duration * throughput))
  if [[ -n "${MIN_CHUNK_SIZE:-}" ]] && type size_suffix_bytes >/dev/null 2>&1; then
    bound=${ size_suffix_bytes "$MIN_CHUNK_SIZE" 2>/dev/null;} || bound=""
    if [[ -n "$bound" && "$value" -lt "$bound" ]]; then
      value="$bound"
    fi
  fi
  bound="$max_bytes"
  if [[ -n "${MAX_CHUNK_SIZE:-}" ]] && type size_suffix_bytes >/dev/null 2>&1; then
    max_bound=${ size_suffix_bytes "$MAX_CHUNK_SIZE" 2>/dev/null;} || max_bound=""
    if [[ -n "$max_bound" && "$max_bound" -lt "$bound" ]]; then
      bound="$max_bound"
    fi
  fi
  [[ "$value" -le "$bound" ]] || value="$bound"
  printf '%s\n' "$value"
  return 0
}

# _capabilities_duration_seconds RAW - print RAW as whole seconds for the
# chunk derivation. A bare integer is milliseconds, the Nextcloud desktop
# client's targetChunkUploadDuration unit (the shipped example is 60000, or
# 60s), rounded up so a sub-second target still yields a positive duration;
# an explicit s/m/h/d suffix goes through duration_seconds. Prints nothing
# and returns 1 for a missing, non-positive, or unparseable value.
_capabilities_duration_seconds() {
  local raw="${1:-}" ms=0 seconds=""
  case "$raw" in
    '') return 1 ;;
    *[!0-9]*)
      seconds="$(duration_seconds "$raw" seconds 2>/dev/null)" || return 1
      [[ -n "$seconds" && "$seconds" -gt 0 ]] || return 1
      printf '%s\n' "$seconds"
      return 0
      ;;
  esac
  ms="$((10#$raw))"
  [[ "$ms" -gt 0 ]] || return 1
  printf '%s\n' "$(((ms + 999) / 1000))"
  return 0
}

# _capabilities_derive_chunk_size MAX_BYTES - print the run-level chunk size
# derived from TARGET_CHUNK_UPLOAD_DURATION and the effective upload
# throughput, or nothing when the derivation cannot be made. The throughput
# is BW_LIMIT_UP when set (the effective bandwidth cap), otherwise
# TARGET_UPLOAD_THROUGHPUT; both are rclone SizeSuffix byte-per-second
# values. MAX_BYTES is the server's maximum, passed through as the cap.
_capabilities_derive_chunk_size() {
  local max_bytes="${1:-}" duration_s="" throughput_raw="" throughput_bps=""
  duration_s="$(_capabilities_duration_seconds "${TARGET_CHUNK_UPLOAD_DURATION:-}")" || return 0
  throughput_raw="${BW_LIMIT_UP:-}"
  [[ -n "$throughput_raw" ]] || throughput_raw="${TARGET_UPLOAD_THROUGHPUT:-}"
  [[ -n "$throughput_raw" ]] || return 0
  type size_suffix_bytes >/dev/null 2>&1 || return 0
  throughput_bps=${ size_suffix_bytes "$throughput_raw" 2>/dev/null;} || return 0
  [[ -n "$throughput_bps" && "$throughput_bps" -gt 0 ]] || return 0
  capabilities_chunk_for_duration "$duration_s" "$throughput_bps" "$max_bytes"
}

# capabilities_size_label BYTES - display an exact binary multiple the way
# rclone writes SizeSuffix values (104857600 -> 100Mi); otherwise print the
# plain byte count. Display only. One-line delegation: the rendering lives
# in core's format_size_bytes STYLE rclone, byte-identical to the body this
# used to restate (pinned by the unit format_size table, the capabilities
# chunk labels, and the bigfolder label feature checks).
capabilities_size_label() { format_size_bytes "${1:-}" rclone; }

# capabilities_base_url - print scheme://host[:port] of the configured
# remote; rc 1 when the rclone config or its url is unusable.
capabilities_base_url() {
  remote_nextcloud_base
}

# _capabilities_assign_facts - read "KEY=value" lines on stdin and set the
# matching CAP_* globals (VERSION and CHUNK_MAX_SIZE are sanitized). Unknown
# keys are ignored. Runs in the caller's shell, not a pipeline subshell, so
# the assignments persist.
_capabilities_assign_facts() {
  local key="" value=""
  local LC_ALL=C
  while IFS='=' read -r key value; do
    case "$key" in
      VERSION) CAP_VERSION="$(_capabilities_sanitize "$value")" ;;
      BIGFILE_CHUNKING) CAP_BIGFILE_CHUNKING="$value" ;;
      CHUNK_MAX_SIZE) CAP_CHUNK_MAX_SIZE="${value//[^0-9]/}" ;;
      UNDELETE) CAP_UNDELETE="$value" ;;
      CHECKSUMS) CAP_CHECKSUMS="$value" ;;
    esac
  done
  return 0
}

# _capabilities_extract_json JSON - flatten the response and print the five
# "KEY=value" fact lines the parser consumes (VERSION, BIGFILE_CHUNKING,
# CHUNK_MAX_SIZE, UNDELETE, CHECKSUMS). One awk pass over the payload instead
# of ~40 sed/grep/tr processes re-scanning it for every field.
_capabilities_extract_json() {
  printf '%s' "$1" | LC_ALL=C awk '
    function extract_num(obj, key,    pos, rest, i, c, out) {
      pos = index(obj, "\"" key "\"")
      if (pos == 0) return ""
      rest = substr(obj, pos + length(key) + 2)
      sub(/^[ \t]*:[ \t]*/, "", rest)
      out = ""
      for (i = 1; i <= length(rest); i++) {
        c = substr(rest, i, 1)
        if (c < "0" || c > "9") break
        out = out c
      }
      return out
    }
    # json_object_for(flat, key) - the balanced {...} object that follows the
    # first "key": occurrence, or "". Brace matching (string-aware) makes the
    # extraction independent of object size and key order, unlike a
    # "[^}]*" regex, which breaks as soon as a section nests another object.
    function json_object_for(flat, key,    pos, rest, i, c, depth, in_str, esc) {
      pos = index(flat, "\"" key "\"")
      if (pos == 0) return ""
      rest = substr(flat, pos + length(key) + 2)
      if (rest !~ /^[ \t]*:/) return ""
      sub(/^[ \t]*:[ \t]*/, "", rest)
      if (substr(rest, 1, 1) != "{") return ""
      depth = 0
      in_str = 0
      esc = 0
      for (i = 1; i <= length(rest); i++) {
        c = substr(rest, i, 1)
        if (in_str) {
          if (esc) esc = 0
          else if (c == "\\") esc = 1
          else if (c == "\"") in_str = 0
          continue
        }
        if (c == "\"") { in_str = 1; continue }
        if (c == "{") depth++
        else if (c == "}") { depth--; if (depth == 0) return substr(rest, 1, i) }
      }
      return ""
    }
    # parse_version(flat) - the "version" section as "major.minor[.micro]",
    # preferring the "string" field, or "" when none is present.
    function parse_version(flat,    obj, pos, rest, major, minor, micro, ver) {
      ver = ""
      obj = json_object_for(flat, "version")
      if (obj != "") {
        pos = index(obj, "\"string\"")
        if (pos > 0) {
          rest = substr(obj, pos + 8)
          sub(/^[ \t]*:[ \t]*"/, "", rest)
          pos = index(rest, "\"")
          if (pos > 1) ver = substr(rest, 1, pos - 1)
        }
        if (ver == "") {
          major = extract_num(obj, "major")
          minor = extract_num(obj, "minor")
          micro = extract_num(obj, "micro")
          if (major != "" && minor != "") {
            ver = major "." minor
            if (micro != "") ver = ver "." micro
          }
        }
      }
      return ver
    }
    # parse_bigfile(flat) - the "bigfilechunking" boolean as true/false, or "".
    function parse_bigfile(flat,    big, pos, rest) {
      big = ""
      pos = index(flat, "\"bigfilechunking\"")
      if (pos > 0) {
        rest = substr(flat, pos + 17)
        sub(/^[ \t]*:[ \t]*/, "", rest)
        if (substr(rest, 1, 4) == "true") big = "true"
        else if (substr(rest, 1, 5) == "false") big = "false"
      }
      return big
    }
    # parse_chunk(flat) - chunked_upload.max_size digits, or "".
    function parse_chunk(flat,    obj, chunk) {
      chunk = ""
      obj = json_object_for(flat, "chunked_upload")
      if (obj != "") chunk = extract_num(obj, "max_size")
      return chunk
    }
    # parse_undelete(flat) - true when a "trashbin" section exists, otherwise
    # the "undelete" boolean as true/false, or "".
    function parse_undelete(flat,    und, pos, rest) {
      und = ""
      if (index(flat, "\"trashbin\"") > 0) {
        und = "true"
      } else {
        pos = index(flat, "\"undelete\"")
        if (pos > 0) {
          rest = substr(flat, pos + 10)
          sub(/^[ \t]*:[ \t]*/, "", rest)
          if (substr(rest, 1, 4) == "true") und = "true"
          else if (substr(rest, 1, 5) == "false") und = "false"
        }
      }
      return und
    }
    # parse_checksums(flat) - "true" when a "checksums" section exists.
    function parse_checksums(flat,    checks) {
      checks = ""
      if (index(flat, "\"checksums\"") > 0) checks = "true"
      return checks
    }
    { gsub(/\r/, ""); flat = flat $0 }
    END {
      gsub(/\\\//, "/", flat)
      print "VERSION=" parse_version(flat)
      print "BIGFILE_CHUNKING=" parse_bigfile(flat)
      print "CHUNK_MAX_SIZE=" parse_chunk(flat)
      print "UNDELETE=" parse_undelete(flat)
      print "CHECKSUMS=" parse_checksums(flat)
    }
  '
}

# capabilities_parse_json JSON - set the CAP_* globals from an OCS
# capabilities response. Pure and best-effort: no output, no die, and keys
# may appear in any order. Values are sanitized before they become globals.
capabilities_parse_json() {
  local json="$1"
  CAP_VERSION=""
  CAP_BIGFILE_CHUNKING=""
  CAP_CHUNK_MAX_SIZE=""
  CAP_UNDELETE=""
  CAP_CHECKSUMS=""
  [[ -n "$json" ]] || return 0
  _capabilities_assign_facts < <(_capabilities_extract_json "$json")
  return 0
}

# _capabilities_write_cache - replace CAPABILITIES_CACHE with the sanitized
# CAP_* assignments. Every value goes through _capabilities_sanitize again as
# a last line of defense before sourcing.
_capabilities_write_cache() {
  {
    printf 'CAP_VERSION=%s\n' "$(_capabilities_sanitize "${CAP_VERSION:-}")"
    printf 'CAP_BIGFILE_CHUNKING=%s\n' "$(_capabilities_sanitize "${CAP_BIGFILE_CHUNKING:-}")"
    printf 'CAP_CHUNK_MAX_SIZE=%s\n' "$(_capabilities_sanitize "${CAP_CHUNK_MAX_SIZE:-}")"
    printf 'CAP_UNDELETE=%s\n' "$(_capabilities_sanitize "${CAP_UNDELETE:-}")"
    printf 'CAP_CHECKSUMS=%s\n' "$(_capabilities_sanitize "${CAP_CHECKSUMS:-}")"
  } | atomic_write "$CAPABILITIES_CACHE" 600
}

# capabilities_cache_fresh - true when CAPABILITIES_CACHE exists and is
# younger than CAPABILITIES_MAX_AGE seconds; 0 means always stale.
capabilities_cache_fresh() {
  local max_age="${CAPABILITIES_MAX_AGE:-0}" mtime="" now="" age=""
  case "$max_age" in '' | *[!0-9]*) return 1 ;; esac
  [[ "$max_age" -gt 0 ]] || return 1
  [[ -n "${CAPABILITIES_CACHE:-}" && -f "$CAPABILITIES_CACHE" ]] || return 1
  mtime="$(file_mtime "$CAPABILITIES_CACHE")"
  [[ -n "$mtime" ]] || return 1
  now=${ now_epoch;}
  age=$((now - mtime))
  [[ "$age" -lt "$max_age" ]]
}

# capabilities_load - source CAPABILITIES_CACHE into the CAP_* globals;
# rc 1 when the cache is absent or unreadable.
capabilities_load() {
  [[ -n "${CAPABILITIES_CACHE:-}" ]] || return 1
  CAP_VERSION=""
  CAP_BIGFILE_CHUNKING=""
  CAP_CHUNK_MAX_SIZE=""
  CAP_UNDELETE=""
  CAP_CHECKSUMS=""
  safe_source "$CAPABILITIES_CACHE" || return 1
  return 0
}

# capabilities_fetch_raw BASE - GET the OCS capabilities endpoint below BASE
# and print the response body; rc 1 with no output when credentials are
# missing, the transport fails, or the status is not 2xx. Uses http_curl from
# lib/http.sh when it is loaded, so TLS_INSECURE, PROXY/PROXY_DIRECT,
# HTTP_TIMEOUT and the netrc password path apply; falls back to a plain curl
# otherwise (standalone callers such as the integration tests).
capabilities_fetch_raw() {
  local base="$1" url="" show="" user="" secret="" response="" body_file="" rc=0
  url="${base}/ocs/v2.php/cloud/capabilities?format=json"
  show="$(remote_config_show)" || return 1
  user="$(config_value user "$show")"
  [[ -n "$user" ]] || return 1
  secret="$(remote_secret_plain)" || return 1
  [[ -n "$secret" ]] || return 1
  if type http_curl >/dev/null 2>&1; then
    # http_curl authenticates from HTTP_BASE/HTTP_USER; derive them here
    # because the probe may run before http_remote_info.
    : "${HTTP_BASE:=$base}"
    : "${HTTP_USER:=$user}"
    temp_mktemp_into body_file "${TMPDIR:-/tmp}/sciebo-capabilities.XXXXXX" || return 1
    if http_curl -H 'OCS-APIRequest: true' -H 'Accept: application/json' "$url" >"$body_file"; then
      rc=0
    else
      rc=$?
    fi
    case "${HTTP_CODE:-000}" in
      2*)
        cat "$body_file"
        rc=0
        ;;
      *) rc=1 ;;
    esac
    temp_discard "$body_file"
    return "$rc"
  fi
  # Standalone path (http.sh not loaded): authenticate from a mode-600 netrc
  # too. A control-byte secret cannot be represented and is refused rather
  # than exposed in the curl argv via -u. The client-cert/CA/User-Agent and
  # client-key --config settings apply on this path as well.
  local netrc_file="" key_config=""
  local -a client_args=()
  if [[ -n "${CLIENT_KEY_PASSWORD:-}" ]]; then
    # The client-key passphrase goes through a mode-600 curl config file instead
    # of --pass, which would expose it in the argv. A control byte cannot be
    # carried safely and is refused. The shared writer owns the escaping, mode,
    # and temp registration; its rc 2 (write failure) maps to this path's rc 1.
    curl_key_pass_config_into key_config "$CLIENT_KEY_PASSWORD" || return 1
    curl_client_args_into client_args --config "$key_config"
  else
    curl_client_args_into client_args
  fi
  netrc_write_into netrc_file "$base" "$user" "$secret" || {
    temp_discard "$key_config"
    return 1
  }
  response="$(curl -fsS --max-time "${HTTP_TIMEOUT:-15}" \
    --connect-timeout "${HTTP_CONNECT_TIMEOUT:-15}" --netrc-file "$netrc_file" \
    ${client_args[@]+"${client_args[@]}"} \
    -H 'OCS-APIRequest: true' -H 'Accept: application/json' "$url" 2>/dev/null)" || rc=$?
  temp_discard "$netrc_file"
  temp_discard "$key_config"
  [[ "$rc" -eq 0 ]] || return 1
  [[ -n "$response" ]] || return 1
  printf '%s' "$response"
  return 0
}

# capabilities_probe [--force] - fill the CAP_* globals from the server.
# Uses a fresh cache unless --force is given; rc 1 without output when curl
# or the app password is unavailable, or when the probe fails. Writes the
# sanitized cache on success.
capabilities_probe() {
  local force=0 arg="" base="" response=""
  for arg in "$@"; do
    [[ "$arg" != "--force" ]] || force=1
  done
  have curl || return 1
  if [[ "$force" -eq 0 ]] && capabilities_cache_fresh; then
    capabilities_load && return 0
    return 1
  fi
  [[ -n "${CAPABILITIES_CACHE:-}" && -n "${CAPABILITIES_JSON:-}" ]] || return 1
  type remote_secret_plain >/dev/null 2>&1 || return 1
  base="$(capabilities_base_url)" || return 1
  response="$(capabilities_fetch_raw "$base")" || return 1
  [[ -n "$response" ]] || return 1
  capabilities_parse_json "$response"
  printf '%s\n' "$response" | atomic_write "$CAPABILITIES_JSON" 600
  _capabilities_write_cache
  return 0
}

# Capability descriptors: the single mapping from a CAP_* global to its
# label/verdict. Each record is
#   <key>|<globals-var>|<mode>|<yes-word>|<no-word>|<detail>
# where mode is:
#   text   the value itself is the fact (only a non-empty value counts)
#   bool   true/false map to the yes/no words; detail "chunk" appends the
#          maximum chunk size label when CAP_CHUNK_MAX_SIZE is set
# Missing or unknown values produce no fact. capabilities_facts renders the
# table into "<key>\t<verdict>\t<detail>" records that capabilities_show and
# doctor format.
_CAPABILITY_SPECS=(
  'version|CAP_VERSION|text|present||'
  'bigfile|CAP_BIGFILE_CHUNKING|bool|enabled|disabled|chunk'
  'trashbin|CAP_UNDELETE|bool|available|unavailable|'
  'checksums|CAP_CHECKSUMS|bool|available|unavailable|'
)

# capabilities_facts - print one "<key>\t<verdict>\t<detail>" record for
# every known CAP_* fact, in table order. Unknown facts are omitted.
capabilities_facts() {
  local spec="" key="" var="" mode="" yes="" no="" detail="" value=""
  for spec in "${_CAPABILITY_SPECS[@]}"; do
    IFS='|' read -r key var mode yes no detail <<<"$spec"
    value="${!var:-}"
    if [[ "$mode" == "text" ]]; then
      [[ -n "$value" ]] || continue
      printf '%s\t%s\t%s\n' "$key" "$yes" "$value"
      continue
    fi
    case "$value" in
      true)
        if [[ "$detail" == "chunk" && -n "${CAP_CHUNK_MAX_SIZE:-}" ]]; then
          printf '%s\t%s\t%s\n' "$key" "$yes" "$(capabilities_size_label "$CAP_CHUNK_MAX_SIZE")"
        else
          printf '%s\t%s\t%s\n' "$key" "$yes" ""
        fi
        ;;
      false) printf '%s\t%s\t%s\n' "$key" "$no" "" ;;
    esac
  done
  return 0
}

# capabilities_show - print the known capabilities, one fact per line;
# unknown facts are omitted and an empty result explains itself.
capabilities_show() {
  local key="" verdict="" detail="" shown=0
  while IFS=$'\t' read -r key verdict detail; do
    [[ -n "$key" ]] || continue
    shown=1
    case "$key" in
      version) printf 'server: Nextcloud %s\n' "$detail" ;;
      bigfile)
        if [[ "$verdict" == "enabled" && -n "$detail" ]]; then
          printf 'chunked uploads: enabled (max chunk %s)\n' "$detail"
        elif [[ "$verdict" == "enabled" ]]; then
          printf 'chunked uploads: enabled\n'
        else
          printf 'chunked uploads: disabled\n'
        fi
        ;;
      trashbin)
        if [[ "$verdict" == "available" ]]; then
          printf 'trashbin: available\n'
        else
          printf 'trashbin: unavailable\n'
        fi
        ;;
      checksums)
        if [[ "$verdict" == "available" ]]; then
          printf 'checksums: available\n'
        else
          printf 'checksums: unavailable\n'
        fi
        ;;
    esac
  done < <(capabilities_facts)
  [[ "$shown" -eq 1 ]] || printf 'server capabilities: unknown (probe failed or not cached)\n'
  return 0
}

# capabilities_sync_chunk_size - print the Nextcloud upload chunk size for
# rclone, or nothing. CHUNK_SIZE wins; otherwise a fresh capabilities cache
# supplies the server maximum for nextcloud remotes. When
# TARGET_CHUNK_UPLOAD_DURATION and an upload throughput are set, a run-level
# value is derived from them first (see _capabilities_derive_chunk_size) and
# falls back to the server maximum when the derivation cannot be made.
# Always rc 0, and the decision is memoized so it runs at most once per
# process.
capabilities_sync_chunk_size() {
  local show="" vendor="" derived=""
  if [[ "$CAPABILITIES_CHUNK_RESOLVED" -eq 1 ]]; then
    [[ -z "$CAPABILITIES_CHUNK_VALUE" ]] || printf '%s\n' "$CAPABILITIES_CHUNK_VALUE"
    return 0
  fi
  CAPABILITIES_CHUNK_RESOLVED=1
  CAPABILITIES_CHUNK_VALUE=""
  if [[ -n "${CHUNK_SIZE:-}" ]]; then
    CAPABILITIES_CHUNK_VALUE="$CHUNK_SIZE"
  elif capabilities_cache_fresh && capabilities_load; then
    if show="$(remote_config_show)"; then
      vendor="$(config_value vendor "$show")"
      if [[ "$vendor" == "nextcloud" && -n "${CAP_CHUNK_MAX_SIZE:-}" ]]; then
        derived="$(_capabilities_derive_chunk_size "$CAP_CHUNK_MAX_SIZE")"
        CAPABILITIES_CHUNK_VALUE="${derived:-$CAP_CHUNK_MAX_SIZE}"
      fi
    fi
  fi
  [[ -z "$CAPABILITIES_CHUNK_VALUE" ]] || printf '%s\n' "$CAPABILITIES_CHUNK_VALUE"
  return 0
}
