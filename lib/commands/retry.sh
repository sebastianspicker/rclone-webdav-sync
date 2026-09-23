#!/bin/bash
# retry.sh command module - clear failure-blacklist entries.
# `sciebo retry` only touches local record files: no network, no run lock,
# and no state directory beyond the records it clears.

usage_retry() {
  usage_emit <<'EOF'
Usage: sciebo retry [NAME [PATH]] [--list] [--all]

Clear failure-blacklist entries so the next sync tries those paths again.

Without options, NAME clears every blacklisted path of that source; NAME
PATH clears a single path. --all clears every source's records and --list
prints <name><TAB><count><TAB><path><TAB><error> rows. Records written in
backoff mode (see BLACKLIST_MODE) add a fifth <next> retry-time column.

Options:
  --list      show all blacklist records and exit
  --all       clear every source's records
  -h, --help  show this help
EOF
}

# retry_clear_all - clear every source, print what was cleared.
retry_clear_all() {
  local cleared="" count=0 source=""
  while IFS= read -r source; do
    [[ -n "$source" ]] || continue
    cleared="${cleared:+${cleared}, }${source}"
    count=$((count + 1))
  done < <(blacklist_clear_all)
  if [[ "$count" -eq 0 ]]; then
    printf 'nothing to clear\n'
  else
    printf 'cleared %s source(s): %s\n' "$count" "$cleared"
  fi
  return 0
}

cmd_retry() {
  local list=false all=false name="" path="" count=0
  opt_begin "list:b all:b" retry "" "$@"
  # Run dependencies load after opt_begin's --help exit, so
  # `sciebo retry --help` parses none of them: the record walkers live in
  # blacklist.sh, and the `--name` filter goes through the manifest index
  # (both work whether or not bin/sciebo sourced them directly).
  sciebo_require_module blacklist blacklist_record_many
  sciebo_require_module manifest manifest_index_load
  opt_into list list
  opt_into all all
  split_positionals "${OPT_EXTRA:-}"
  if [[ "$list" == true && "$all" == true ]]; then
    usage_error retry "--list and --all are mutually exclusive"
  fi
  if [[ "${#POSITIONAL_ARGS[@]}" -gt 2 ]]; then
    usage_error retry "too many arguments: $(printable "${POSITIONAL_ARGS[2]}")"
  fi
  name="${POSITIONAL_ARGS[0]:-}"
  path="${POSITIONAL_ARGS[1]:-}"
  if [[ "$list" == true || "$all" == true ]]; then
    [[ -z "$name" && -z "$path" ]] || usage_error retry "a source name cannot be combined with --list or --all"
  fi

  load_settings --no-rclone

  if [[ "$list" == true ]]; then
    blacklist_list
    return 0
  fi
  if [[ "$all" == true ]]; then
    retry_clear_all
    return 0
  fi
  [[ -n "$name" ]] || usage_error retry "NAME is required without --list or --all"

  manifest_index_load
  if ! manifest_has_name "$name"; then
    err "$(unknown_source_prefix "$name") (see 'sciebo list')"
    return 1
  fi
  if [[ -n "$path" ]]; then
    if blacklist_clear "$name" "$path"; then
      printf "cleared '%s' for '%s'\n" "$(printable "$path")" "$name"
      return 0
    fi
    err "no blacklist entry for '$(printable "$path")' under '${name}'"
    return 1
  fi
  count="$(blacklist_count "$name")"
  if [[ "$count" -eq 0 ]]; then
    printf "nothing to clear for '%s'\n" "$name"
    return 0
  fi
  blacklist_clear "$name" || true
  printf "cleared %s path(s) for '%s'\n" "$count" "$name"
  return 0
}
