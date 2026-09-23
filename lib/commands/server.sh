#!/bin/bash
# server.sh command module - server endpoint and capability facts.
#
# Read-only. `info` and `capabilities` read the capabilities cache when it
# is fresh and never touch the network then; a stale or missing cache falls
# back to the OCS probe in lib/capabilities.sh. `status` checks
# reachability through `rclone lsd`. No lock and no local state writes
# beyond the capabilities cache the probe maintains.

usage_server() {
  usage_emit <<'EOF'
Usage: sciebo server <subcommand> [options]

Inspect the configured Nextcloud server (URL, user, capabilities) or check
that the remote answers.

Subcommands:
  info [--json]          server URL, user, and capability facts
  capabilities [--raw] [--json]
                         parsed capabilities summary (--raw: cached JSON;
                         --json: the same facts as a JSON document)
  status                 reachability check with `rclone lsd` (PASS/FAIL)

Options:
  --json      info/capabilities: print a JSON document
  --raw       capabilities: print the cached raw OCS response
  -h, --help  show this help
EOF
}

# server_chunking_text - the CHUNKING display value.
server_chunking_text() {
  case "${CAP_BIGFILE_CHUNKING:-}" in
    true)
      if [[ -n "${CAP_CHUNK_MAX_SIZE:-}" ]]; then
        printf 'enabled (max chunk %s)' "$(capabilities_size_label "$CAP_CHUNK_MAX_SIZE")"
      else
        printf 'enabled'
      fi
      ;;
    false) printf 'disabled' ;;
    *) printf '' ;;
  esac
}

# server_capabilities_refresh - fill the CAP_* globals: a fresh cache wins
# and never touches the network; otherwise the OCS probe runs, and a stale
# cache is the last resort. rc 1 when no cache and no probe result is
# available.
server_capabilities_refresh() {
  if capabilities_cache_fresh && capabilities_load; then
    return 0
  fi
  if type capabilities_probe >/dev/null 2>&1 && capabilities_probe; then
    return 0
  fi
  capabilities_load
}

# server_print_info_text - the `server info` report. The capability flags
# render through the shared helpers: print_field (empty values show "-")
# and label_bool with an explicit "" unknown word, which is what
# server_cap_word used to print for a flag that is neither true nor false.
server_print_info_text() {
  printf 'SERVER: %s\n' "$(printable "$HTTP_BASE")"
  printf 'USER: %s\n' "$(printable "$HTTP_USER")"
  print_field "VERSION" "$(printable "${CAP_VERSION:-}")"
  print_field "CHUNKING" "$(printable "$(server_chunking_text)")"
  print_field "TRASHBIN" "$(label_bool "${CAP_UNDELETE:-}" available unavailable "")"
  print_field "CHECKSUMS" "$(label_bool "${CAP_CHECKSUMS:-}" available unavailable "")"
}

# server_print_capability_fields - the capability facts as JSON object fields,
# shared by `server info --json` and `server capabilities --json`. The three
# flag literals come from label_bool with a "null" unknown word (what
# server_cap_boolean printed), so the JSON bytes stay identical.
server_print_capability_fields() {
  output_json_kv "version" "${CAP_VERSION:-}"
  output_json_kv_raw "chunking" "$(label_bool "${CAP_BIGFILE_CHUNKING:-}" true false null)"
  if is_uint "${CAP_CHUNK_MAX_SIZE:-}"; then
    output_json_kv_raw "chunk_max_size" "$CAP_CHUNK_MAX_SIZE"
  else
    output_json_kv_raw "chunk_max_size" "null"
  fi
  output_json_kv_raw "trashbin" "$(label_bool "${CAP_UNDELETE:-}" true false null)"
  output_json_kv_raw "checksums" "$(label_bool "${CAP_CHECKSUMS:-}" true false null)"
}

# server_print_info_json - the `server info --json` document.
server_print_info_json() {
  output_json_begin
  output_json_kv "server" "$HTTP_BASE"
  output_json_kv "user" "$HTTP_USER"
  server_print_capability_fields
  output_json_end
}

# server_print_capabilities_json - the `server capabilities --json`
# document: the same facts capabilities_show prints.
server_print_capabilities_json() {
  output_json_begin
  server_print_capability_fields
  output_json_end
}

# server_print_raw_capabilities - the cached raw OCS response; probes only
# when the raw cache file does not exist yet.
server_print_raw_capabilities() {
  if [[ -n "${CAPABILITIES_JSON:-}" && -s "$CAPABILITIES_JSON" ]]; then
    sanitize_stream <"$CAPABILITIES_JSON"
    return 0
  fi
  if type capabilities_probe >/dev/null 2>&1 && capabilities_probe &&
    [[ -s "$CAPABILITIES_JSON" ]]; then
    sanitize_stream <"$CAPABILITIES_JSON"
    return 0
  fi
  die "no cached capabilities JSON; run '${CLI_NAME} server capabilities' first"
}

server_cmd_info() {
  opt_json_mode
  http_load_context
  server_capabilities_refresh || true
  if output_json_enabled; then
    server_print_info_json
  else
    server_print_info_text
  fi
  return 0
}

server_cmd_capabilities() {
  load_settings
  if [[ -n "${OPT_raw:-}" ]]; then
    server_print_raw_capabilities
    return 0
  fi
  opt_json_mode
  server_capabilities_refresh || true
  if output_json_enabled; then
    server_print_capabilities_json
  else
    capabilities_show
  fi
  return 0
}

server_cmd_status() {
  local rc=0
  load_settings
  rclone_capture server lsd "${REMOTE_PREFIX}" || rc=$?
  temp_discard "$RCLONE_CAPTURE_OUT"
  if [[ "$rc" -eq 0 ]]; then
    temp_discard "$RCLONE_CAPTURE_ERR"
    printf 'PASS server reachable: %s\n' "$(printable "$REMOTE_PREFIX")"
    return 0
  fi
  printf 'FAIL server unreachable: %s (rc %s)\n' "$(printable "$REMOTE_PREFIX")" "$rc"
  [[ -s "$RCLONE_CAPTURE_ERR" ]] && sanitize_stream <"$RCLONE_CAPTURE_ERR" >&2
  temp_discard "$RCLONE_CAPTURE_ERR"
  return 1
}

cmd_server() {
  local sub="" rc=0 argc=0
  opt_begin "json:b raw:b" server "" "$@"
  # The OCS probe and endpoint facts use the http/capabilities helpers;
  # load them after opt_begin's --help exit so `sciebo server --help`
  # parses none of them.
  sciebo_require_module http xml_get
  sciebo_require_module capabilities capabilities_load
  split_positionals "${OPT_EXTRA:-}"
  argc=${#POSITIONAL_ARGS[@]}
  [[ "$argc" -eq 0 ]] || sub="${POSITIONAL_ARGS[0]}"
  case "$sub" in
    info | capabilities | status) ;;
    '')
      usage_error server "a subcommand is required (info, capabilities, status)"
      ;;
    *)
      usage_unknown_sub server "$sub"
      ;;
  esac
  [[ "$argc" -le 1 ]] ||
    usage_error server "unexpected argument: $(printable "${POSITIONAL_ARGS[1]}")"

  case "$sub" in
    info)
      [[ -z "${OPT_raw_SET:-}" ]] || usage_error server "info does not support --raw"
      server_cmd_info || rc=$?
      ;;
    capabilities)
      if [[ -n "${OPT_json_SET:-}" && -n "${OPT_raw_SET:-}" ]]; then
        usage_error server "capabilities: --json and --raw are mutually exclusive"
      fi
      server_cmd_capabilities || rc=$?
      ;;
    status)
      [[ -z "${OPT_json_SET:-}" ]] || usage_error server "status does not support --json"
      [[ -z "${OPT_raw_SET:-}" ]] || usage_error server "status does not support --raw"
      server_cmd_status || rc=$?
      ;;
  esac
  return "$rc"
}
