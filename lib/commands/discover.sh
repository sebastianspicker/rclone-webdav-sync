#!/bin/bash
# discover.sh command module - find git repositories under configured roots.

usage_discover() {
  cat <<'EOF'
Usage: sciebo discover [--write]

Scan the roots in config/roots.conf for git repositories and emit manifest
lines (mode|repo|remote_subdir) for config/sources.generated.conf.

Options:
  --write     atomically write config/sources.generated.conf
  -h, --help  show this help
EOF
}

# discover_parse_root MODE ROOT REMOTE_BASE MAXDEPTH - validate one
# roots.conf entry and normalize it into DISCOVER_ROOT/MODE/REMOTE_BASE/
# MAXDEPTH, warning on invalid entries. Returns 1 when the entry is
# skipped.
discover_parse_root() {
  local mode root_raw remote_base maxdepth err=""
  mode="$(trim "${1:-}")"
  root_raw="$(trim "${2:-}")"
  remote_base="$(trim "${3:-}")"
  maxdepth="$(trim "${4:-}")"
  [[ -n "$maxdepth" ]] || maxdepth=3
  if ! valid_entry_mode "$mode"; then
    err="roots.conf: invalid mode '${mode}' - skipping entry"
  elif [[ -z "$root_raw" || -z "$remote_base" ]]; then
    err="roots.conf: empty root or remote_base - skipping entry"
  elif [[ "$maxdepth" == *[!0-9]* ]]; then
    err="roots.conf: invalid maxdepth '${maxdepth}' for root '${root_raw}'"
  elif [[ "$maxdepth" -lt 1 ]]; then
    err="roots.conf: maxdepth must be a positive integer for root '${root_raw}'"
  fi
  if [[ -n "$err" ]]; then
    warn "$err"
    return 1
  fi
  DISCOVER_ROOT="$(expand_local_path "$root_raw")"
  DISCOVER_ROOT="${DISCOVER_ROOT%/}"
  DISCOVER_REMOTE_BASE="${remote_base%/}"
  if [[ -z "$DISCOVER_REMOTE_BASE" ]]; then
    warn "roots.conf: remote_base normalizes to empty for root '${root_raw}'"
    return 1
  fi
  if [[ ! -d "$DISCOVER_ROOT" ]]; then
    warn "Root does not exist, skipping: ${DISCOVER_ROOT}"
    return 1
  fi
  DISCOVER_MODE="$mode"
  DISCOVER_MAXDEPTH="$maxdepth"
}

# discover_scan_root - append one tab-separated record per repository under
# the normalized root to DISCOVER_RECORDS. Counts unreadable repositories
# in DISCOVER_FAILURES and warns when a root holds none.
discover_scan_root() {
  local gitdir repo found=0
  while IFS= read -r gitdir; do
    [[ -n "$gitdir" ]] || continue
    repo="${gitdir%/.git}"
    if [[ ! -d "$repo" || ! -r "$repo" ]]; then
      warn "Repository not readable, skipping: ${repo}"
      DISCOVER_FAILURES=$((DISCOVER_FAILURES + 1))
      continue
    fi
    DISCOVER_RECORDS="${DISCOVER_RECORDS}${repo}"$'\t'"${DISCOVER_MODE}"$'\t'"${DISCOVER_ROOT}"$'\t'"${DISCOVER_REMOTE_BASE}"$'\n'
    found=$((found + 1))
  done <<<"$(find "$DISCOVER_ROOT" -maxdepth "$DISCOVER_MAXDEPTH" -type d -name .git -prune -print 2>/dev/null || true)"
  [[ "$found" -ne 0 ]] || warn "No git repositories found under ${DISCOVER_ROOT}"
}

# discover_collapse - drop repositories nested in a kept ancestor and fill
# DISCOVER_MANIFEST with manifest lines. Counts emitted repositories in
# DISCOVER_REPO_COUNT and unsafe remote paths in DISCOVER_FAILURES.
discover_collapse() {
  local sorted_records repo mode root remote_base top rel remote_subdir
  local -a stack=()
  sorted_records="$(printf '%s' "$DISCOVER_RECORDS" | LC_ALL=C sort)"

  # Sorted repo paths let a stack drop every repo nested in a kept
  # ancestor. Entries are popped only once no future sorted path can start
  # with them; "-" sorting before "/" means a string prefix need not be a
  # path ancestor.
  while IFS=$'\t' read -r repo mode root remote_base; do
    [[ -n "$repo" ]] || continue
    while [[ "${#stack[@]}" -gt 0 && "$repo" != "${stack[${#stack[@]} - 1]}"* ]]; do
      unset "stack[${#stack[@]} - 1]"
    done
    if [[ "${#stack[@]}" -gt 0 ]]; then
      top="${stack[${#stack[@]} - 1]}"
      case "$repo" in
        "$top" | "$top"/*) continue ;;
      esac
    fi
    stack[${#stack[@]}]="$repo"

    rel="${repo#"${root%/}"/}"
    [[ "$rel" != "$repo" ]] || rel=""
    remote_subdir="${remote_base}"
    [[ -z "$rel" ]] || remote_subdir="${remote_base}/${rel}"
    if ! safe_remote_path "$remote_subdir"; then
      warn "roots.conf: unsafe remote subdir '$(printable "$remote_subdir")' for repository '$(printable "$repo")' - skipping"
      DISCOVER_FAILURES=$((DISCOVER_FAILURES + 1))
      continue
    fi
    DISCOVER_MANIFEST="${DISCOVER_MANIFEST}${mode}|${repo}|${remote_subdir}"$'\n'
    DISCOVER_REPO_COUNT=$((DISCOVER_REPO_COUNT + 1))
  done <<<"$sorted_records"
}

cmd_discover() {
  local write=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --write) write=1 ;;
      -h | --help)
        usage_discover
        exit 0
        ;;
      *) usage_error discover "unknown option: $1" ;;
    esac
    shift
  done

  load_settings --no-rclone
  [[ -f "$ROOTS_FILE" ]] || die "Missing roots file: ${ROOTS_FILE}"

  DISCOVER_ROOTS=0 DISCOVER_FAILURES=0 DISCOVER_REPO_COUNT=0 DISCOVER_RECORDS="" DISCOVER_MANIFEST=""

  local raw_mode raw_root raw_base raw_depth
  while IFS='|' read -r raw_mode raw_root raw_base raw_depth; do
    if ! discover_parse_root "$raw_mode" "$raw_root" "$raw_base" "$raw_depth"; then
      DISCOVER_FAILURES=$((DISCOVER_FAILURES + 1))
      continue
    fi
    DISCOVER_ROOTS=$((DISCOVER_ROOTS + 1))
    discover_scan_root
  done < <(config_lines "$ROOTS_FILE")

  discover_collapse

  local header count output
  header="# Generated by 'sciebo discover --write' on $(date '+%Y-%m-%d'). Do not edit by hand."
  count="# ${DISCOVER_REPO_COUNT} repositories from ${DISCOVER_ROOTS} root(s)."
  output="$(printf '%s\n%s\n%s' "$header" "$count" "$DISCOVER_MANIFEST")"

  if [[ "$write" -eq 1 ]]; then
    acquire_lock
    printf '%s\n' "$output" | atomic_write "$MANIFEST_GENERATED_FILE" 644
    printf 'discover: %s root(s) scanned, %s repositories found, wrote %s\n' \
      "$DISCOVER_ROOTS" "$DISCOVER_REPO_COUNT" "$MANIFEST_GENERATED_FILE"
  else
    printf '%s\n' "$output"
  fi
  [[ "$DISCOVER_FAILURES" -eq 0 ]]
}
