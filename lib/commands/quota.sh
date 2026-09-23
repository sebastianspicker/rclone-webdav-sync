#!/bin/bash
# quota.sh command module - server quota usage via `rclone about`.
# Read-only and deliberately thin: rclone's output (plain table or --json
# document) is passed through unchanged; only failures are reported.

usage_quota() {
  usage_emit <<'EOF'
Usage: sciebo quota [--json]

Print the quota usage reported by `rclone about <remote>`. With --json
rclone's JSON document is printed instead of the plain table. Backends
without an `about` implementation (or a remote path rclone cannot read)
fail with rclone's own message.

Options:
  --json      print rclone's JSON output
  -h, --help  show this help
EOF
}

cmd_quota() {
  local rc=0
  local args=()
  opt_begin "json:b" quota "" "$@"
  opt_guard quota
  load_settings
  args=(about "$REMOTE_PREFIX")
  [[ -z "${OPT_json:-}" ]] || args+=(--json)

  rclone_capture quota "${args[@]}" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    if [[ -s "$RCLONE_CAPTURE_ERR" ]]; then
      sanitize_stream <"$RCLONE_CAPTURE_ERR" >&2
    fi
    temp_discard "$RCLONE_CAPTURE_OUT"
    temp_discard "$RCLONE_CAPTURE_ERR"
    die "rclone about '${REMOTE_PREFIX}' failed (rc ${rc})"
  fi
  sanitize_stream <"$RCLONE_CAPTURE_OUT"
  temp_discard "$RCLONE_CAPTURE_OUT"
  temp_discard "$RCLONE_CAPTURE_ERR"
  return 0
}
