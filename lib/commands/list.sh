#!/bin/bash
# list.sh command module - list the parsed sources (mode, name, paths, filter).
# Split out of sync.sh so `sciebo list` and `sciebo list --help` parse only
# this module. The row rendering (mode/name/paths/filter, JSON or table) is
# shared with `sciebo sync --list` as lib/config/manifest.sh's
# manifest_list_render.

usage_list() {
  usage_emit <<'EOF'
Usage: sciebo list [--json]

List the parsed sources with mode, name, local path, remote path, and
filter, including invalid entries with their error. Invalid lines keep
going to stderr.

Options:
  --json      print the valid entries as {"sources":[...]} with their
              origin (manual, folders, or generated)
  -h, --help  show this help
EOF
}

cmd_list() {
  local json_mode=0
  opt_begin "json:b" list "" "$@"
  opt_guard list
  output_mode_set "${OPT_json:-false}"
  output_json_enabled && json_mode=1
  load_settings --no-rclone
  manifest_list_render "$json_mode"
}
