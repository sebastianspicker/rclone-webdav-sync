#!/bin/bash
# lock.sh command module - manual WebDAV file locks (Nextcloud files_lock).
# `lock` records the server's Lock-Token locally, `unlock` releases it, and
# `locks` lists (and optionally prunes) the recorded locks. Server traffic
# goes through lib/adapters/http.sh; records are parsed, never sourced.

LOCK_PROPFIND_BODY='<?xml version="1.0"?>
<d:propfind xmlns:d="DAV:" xmlns:nc="http://nextcloud.org/ns">
  <d:prop>
    <nc:lock-token/>
  </d:prop>
</d:propfind>'

LOCK_SUB=""
LOCK_RECORD_PATH=""
LOCK_RECORD_TOKEN=""
LOCK_RESOLVED_TOKEN=""

usage_lock() {
  usage_emit <<'EOF'
Usage: sciebo lock SUB

Manually lock a remote file below <RCLONE_REMOTE>:<REMOTE_BASE>/ with a
WebDAV LOCK carrying the Nextcloud `X-User-Lock: 1` header. The lock token
is recorded locally (mode 600) so `sciebo unlock` can release the lock.

Options:
  -h, --help  show this help
EOF
}

usage_unlock() {
  usage_emit <<'EOF'
Usage: sciebo unlock SUB
       sciebo unlock --all [--yes]

Release a manual WebDAV lock on SUB with UNLOCK. The token is taken from
the record written by `sciebo lock`; without one it is looked up on the
server through PROPFIND (nc:lock-token).

Options:
  --all       release every recorded lock (see `sciebo locks`) and drop
              the records whose UNLOCK succeeded; asks first and needs
              --yes when not running interactively
  --yes       skip the --all confirmation
  -h, --help  show this help
EOF
}

usage_locks() {
  usage_emit <<'EOF'
Usage: sciebo locks [--prune | --unlock-all] [--yes]

List the locks recorded by `sciebo lock` as NAME, PATH, and TOKEN
(NAME is the sanitized path).

Options:
  --prune         check every recorded path and forget records whose
                  lock-token is gone (prints `pruned NAME`)
  --unlock-all    release every recorded lock with UNLOCK and drop the
                  records that succeeded; asks first and needs --yes
                  when not running interactively
  --yes           skip the --unlock-all confirmation
  -h, --help      show this help
EOF
}

# lock_state_file SUB - print SUB's record path. rc 1 and no output when
# the name sanitizes to nothing or REMOTE_LOCKS_DIR is not set.
lock_state_file() {
  local name=""
  name=${ sanitize_name "${1:-}";}
  [[ -n "$name" && -n "${REMOTE_LOCKS_DIR:-}" ]] || return 1
  printf '%s/%s.state\n' "$REMOTE_LOCKS_DIR" "$name"
  return 0
}

# lock_url SUB - print the WebDAV URL of SUB below the remote base.
lock_url() {
  nc_path_url "${REMOTE_BASE}/${1}"
}

# lock_token_control_free TOKEN - rc 0 when TOKEN has no control byte, rc 1
# when it holds a C0/DEL/stray-C1 byte. A token comes from a response header
# or a locally stored record and is replayed verbatim as an HTTP header, so a
# control byte must never be persisted or put on the wire.
lock_token_control_free() {
  case "$1" in
    *[[:cntrl:]]*) return 1 ;;
  esac
  return 0
}

# lock_record_parse FILE - parse a lock record into LOCK_RECORD_PATH and
# LOCK_RECORD_TOKEN without sourcing it. rc 0 on success, rc 1 when the
# file is missing or unreadable, rc 2 when it has no path or token.
lock_record_parse() {
  local file="$1" key="" value=""
  LOCK_RECORD_PATH=""
  LOCK_RECORD_TOKEN=""
  [[ -f "$file" && -r "$file" ]] || return 1
  # shellcheck disable=SC2034  # LOCK_RECORD_* outputs are read by callers
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    case "$key" in
      path) LOCK_RECORD_PATH=${ trim "$value";} ;;
      token) LOCK_RECORD_TOKEN=${ trim "$value";} ;;
    esac
  done <"$file"
  [[ -n "$LOCK_RECORD_PATH" && -n "$LOCK_RECORD_TOKEN" ]] || return 2
  return 0
}

# lock_propfind_token SUB - resolve SUB's current lock token over PROPFIND
# (Depth 0, nc:lock-token). Sets LOCK_RESOLVED_TOKEN (empty when the file
# has no lock) and returns 0. A missing file (HTTP 404) counts as no lock;
# other HTTP errors die with the server message.
lock_propfind_token() {
  local sub="$1" url=""
  url="$(lock_url "$sub")"
  nc_dav_request_allow PROPFIND "$url" 0 "$LOCK_PROPFIND_BODY"
  case "$HTTP_CODE" in
    200 | 207) ;;
    404)
      LOCK_RESOLVED_TOKEN=""
      return 0
      ;;
    *) http_die_http_error PROPFIND "$url" ;;
  esac
  LOCK_RESOLVED_TOKEN="$(xml_get "$HTTP_BODY" "nc:lock-token")"
  return 0
}

# lock_parent_url URL - the parent collection URL of a DAV file URL: the URL
# with its final path segment removed. Recorded lock URLs are built by
# nc_path_url (which preserves "/"), so splitting at the last "/" is exact.
lock_parent_url() {
  printf '%s' "${1%/*}"
}

# lock_depth1_tokens XML - print "SEGMENT<TAB>LOCK_TOKEN" for every
# <d:response> in a Depth-1 PROPFIND body. SEGMENT is the percent-decoded last
# path segment of <d:href>, which maps a response back to a recorded lock
# path. One awk pass over the document, so no fork per record.
lock_depth1_tokens() {
  printf '%s' "$1" | LC_ALL=C awk -v wrapper=d:response "${_AWK_XML_LIB}"'
    { doc = doc $0 }
    END {
      n = xml_walk_top(doc, wrapper, "store")
      for (i = 1; i <= n; i++) {
        printf "%s\t%s\n", xml_href_segment(xml_top_block[i]), xml_extract(xml_top_block[i], "nc:lock-token")
      }
    }
  '
}

# lock_propfind_dir PARENT OUT_MAP - send one Depth-1 PROPFIND for the PARENT
# collection and fill OUT_MAP (a nameref to an associative array) with its
# children's lock tokens, keyed by decoded file name. A missing collection
# (404) leaves the map empty, matching the per-file path's "no lock" reading;
# any other HTTP error dies like the per-file path. The first response for a
# name wins, so a repeated entry cannot change the token.
lock_propfind_dir() {
  local parent="$1" segment="" token=""
  local -n out_map="$2"
  out_map=()
  nc_dav_request_allow PROPFIND "$parent" 1 "$LOCK_PROPFIND_BODY"
  case "$HTTP_CODE" in
    200 | 207) ;;
    404) return 0 ;;
    *) http_die_http_error PROPFIND "$parent" ;;
  esac
  while IFS=$'\t' read -r segment token; do
    [[ -n "$segment" ]] || continue
    [[ -z "${out_map[$segment]+set}" ]] || continue
    out_map["$segment"]="$token"
  done < <(lock_depth1_tokens "$HTTP_BODY")
}

# lock_parse_sub COMMAND ARGS - validate the single SUB positional shared
# by lock and unlock and set LOCK_SUB. Usage and safety failures exit here
# (usage_error/die), so callers never continue with an empty path. The
# count rules come from the shared opt_require_sub (missing = "a remote
# path argument is required", extra = the verbatim "exactly one ..." form);
# path safety stays with require_safe_remote_path on the surviving word.
lock_parse_sub() {
  local command="$1" args="${2:-}"
  opt_require_sub "$command" "a remote path argument" "$args" 1 1 \
    "exactly one remote path argument is required"
  require_safe_remote_path "${POSITIONAL_ARGS[0]}"
  LOCK_SUB="${POSITIONAL_ARGS[0]}"
}

# lock_unlock_all COMMAND FLAG - UNLOCK every lock recorded below
# REMOTE_LOCKS_DIR and drop the records whose release succeeded. --yes
# (OPT_yes) skips the prompt; a non-interactive run without it is a usage
# error for COMMAND. A record whose server call fails is warned about and
# kept, so a later run can retry it.
lock_unlock_all() {
  local command="$1" flag="$2" file="" path="" token="" url="" rc=0 detail="" count=0 failed=0
  ui_confirm_mutation "$command" \
    "${flag} requires --yes when not running interactively" \
    "release every recorded lock? [y/N]: " ||
    return 0
  http_load_context
  if [[ ! -d "${REMOTE_LOCKS_DIR:-}" ]]; then
    printf 'no recorded locks\n'
    return 0
  fi
  while IFS= read -r file; do
    if lock_record_parse "$file"; then
      path="$LOCK_RECORD_PATH"
      if ! safe_remote_path "$path"; then
        warn "skipping malformed lock record ${file}: unsafe path '${ printable "$path";}'"
        continue
      fi
      token="$LOCK_RECORD_TOKEN"
      if ! lock_token_control_free "$token"; then
        warn "skipping malformed lock record ${file}: control bytes in token"
        continue
      fi
      url="$(lock_url "$path")"
      nc_dav_request_allow UNLOCK "$url" "" "" -H 'X-User-Lock: 1' -H "Lock-Token: ${token}"
      case "$HTTP_CODE" in
        200 | 204 | 207)
          rm -f "$file"
          printf 'unlocked %s\n' "$path"
          count=$((count + 1))
          ;;
        *)
          detail="$(http_error_message "$HTTP_BODY")"
          warn "could not unlock ${path}: HTTP ${HTTP_CODE:-?}${detail:+: ${detail}}"
          failed=$((failed + 1))
          ;;
      esac
    else
      rc=$?
      if [[ "$rc" -eq 1 ]]; then
        warn "skipping unreadable lock record ${file}"
      else
        warn "skipping malformed lock record ${file}"
      fi
    fi
  done < <(find "$REMOTE_LOCKS_DIR" -maxdepth 1 -type f -name '*.state' -print 2>/dev/null |
    LC_ALL=C sort)
  if [[ "$count" -eq 0 && "$failed" -eq 0 ]]; then
    printf 'no recorded locks\n'
  fi
  return 0
}

cmd_lock() {
  local sub="" url="" file="" token=""
  opt_begin "" lock "" "$@"
  lock_parse_sub lock "${OPT_EXTRA:-}"
  sub="$LOCK_SUB"
  http_load_context
  file="$(lock_state_file "$sub")" ||
    die "cannot derive a lock record name for '${ printable "$sub";}'"
  url="$(lock_url "$sub")"
  nc_dav_request_allow LOCK "$url" "" "" -H 'X-User-Lock: 1' --data-binary ""
  case "$HTTP_CODE" in
    200 | 207) ;;
    423) die "${sub} is already locked" ;;
    *) http_die_http_error LOCK "$url" ;;
  esac
  token=${ trim "$(http_header 'Lock-Token')";}
  # Nextcloud's files_lock answers LOCK with the lock state as nc:
  # properties and no Lock-Token header; its token is the nc:lock-token
  # property, so read it back over PROPFIND.
  if [[ -z "$token" ]]; then
    lock_propfind_token "$sub"
    token="$LOCK_RESOLVED_TOKEN"
  fi
  [[ -n "$token" ]] || die "LOCK ${url} returned no lock token (no Lock-Token header or nc:lock-token)"
  lock_token_control_free "$token" ||
    die "LOCK ${url} returned a Lock-Token header with control bytes; refusing to record it"
  printf 'path=%s\ntoken=%s\n' "$sub" "$token" | atomic_write "$file" 600
  printf 'locked %s\n' "$sub"
  return 0
}

cmd_unlock() {
  local sub="" url="" file="" token="" rc=0
  opt_begin "all:b yes:b" unlock "" "$@"
  # See cmd_lock: the WebDAV unlock calls use http/nc_api.
  if [[ -n "${OPT_all:-}" ]]; then
    [[ -z "${OPT_EXTRA:-}" ]] || usage_error unlock "unexpected argument: ${OPT_EXTRA%%$'\n'*}"
    lock_unlock_all unlock --all
    return 0
  fi
  lock_parse_sub unlock "${OPT_EXTRA:-}"
  sub="$LOCK_SUB"
  http_load_context
  file="$(lock_state_file "$sub")" ||
    die "cannot derive a lock record name for '${ printable "$sub";}'"
  if [[ -f "$file" ]]; then
    if lock_record_parse "$file"; then
      [[ "$LOCK_RECORD_PATH" == "$sub" ]] ||
        die "lock record '${file}' belongs to '${LOCK_RECORD_PATH}', not '${sub}'"
      token="$LOCK_RECORD_TOKEN"
    else
      rc=$?
      [[ "$rc" -ne 1 ]] || die "lock record for '${sub}' is unreadable: ${file}"
      die "lock record for '${sub}' is malformed: ${file}"
    fi
  else
    lock_propfind_token "$sub"
    token="$LOCK_RESOLVED_TOKEN"
    [[ -n "$token" ]] || die "${sub} is not locked"
  fi
  url="$(lock_url "$sub")"
  lock_token_control_free "$token" ||
    die "refusing to send a Lock-Token with control bytes for '${sub}'"
  nc_dav_request_allow UNLOCK "$url" "" "" -H 'X-User-Lock: 1' -H "Lock-Token: ${token}"
  case "$HTTP_CODE" in
    200 | 204 | 207) ;;
    *) http_die_http_error UNLOCK "$url" ;;
  esac
  rm -f "$file"
  printf 'unlocked %s\n' "$sub"
  return 0
}

# locks_prune_resolve PARENTS_NAME RESOLVED_NAME - resolve the live lock tokens
# for the records gathered in rec_paths under --prune. PARENTS_NAME receives
# one parent collection URL per record (lock_url/lock_parent_url evaluated once
# here so neither the batching nor the report pass rebuilds them) and
# RESOLVED_NAME receives a map keyed by "PARENT<TAB>SEGMENT" with each child's
# nc:lock-token. Sends one Depth-1 PROPFIND per distinct parent directory: a
# name missing from a listing (or carrying an empty lock-token) resolves to the
# empty string, meaning the lock is gone.
locks_prune_resolve() {
  local parents_name="$1" resolved_name="$2" path="" url="" parent="" segment=""
  local -n _lpr_parents="$parents_name"
  local -n _lpr_resolved="$resolved_name"
  local -A parent_seen=() dir_tokens=()
  local -a parents=()
  _lpr_parents=()
  _lpr_resolved=()
  for path in "${rec_paths[@]}"; do
    url=${ lock_url "$path";}
    parent=${ lock_parent_url "$url";}
    _lpr_parents+=("$parent")
    if [[ -z "${parent_seen[$parent]:-}" ]]; then
      parent_seen["$parent"]=1
      parents+=("$parent")
    fi
  done
  for parent in "${parents[@]}"; do
    lock_propfind_dir "$parent" dir_tokens
    for segment in "${!dir_tokens[@]}"; do
      _lpr_resolved["$parent"$'\t'"$segment"]="${dir_tokens[$segment]}"
    done
  done
  return 0
}

cmd_locks() {
  local prune=false file="" name="" path="" token="" rc=0 shown=0 pruned=0 token_disp=""
  local parent="" segment="" i=0
  local -a rec_files=() rec_paths=() rec_names=() rec_tokens=() rec_parents=()
  local -A resolved=()
  opt_begin "prune:b unlock-all:b yes:b" locks "" "$@"
  opt_guard locks
  # The unlock-all release (and prune follow-ups) go over WebDAV; see
  # cmd_lock for the --help placement.
  if [[ -n "${OPT_prune:-}" && -n "${OPT_unlock_all:-}" ]]; then
    usage_error locks "--prune and --unlock-all cannot be combined"
  fi
  if [[ -n "${OPT_unlock_all:-}" ]]; then
    lock_unlock_all locks --unlock-all
    return 0
  fi
  if [[ -n "${OPT_prune:-}" ]]; then
    prune=true
    http_load_context
  else
    load_settings --no-rclone
  fi
  if [[ ! -d "${REMOTE_LOCKS_DIR:-}" ]]; then
    printf 'no recorded locks\n'
    return 0
  fi
  # Read the valid records once, in sorted file order. --prune then batches its
  # PROPFINDs per parent directory but still reports in this same order.
  while IFS= read -r file; do
    if lock_record_parse "$file"; then
      path="$LOCK_RECORD_PATH"
      if ! safe_remote_path "$path"; then
        warn "skipping malformed lock record ${file}: unsafe path '${ printable "$path";}'"
        continue
      fi
      name=${ sanitize_name "$path";}
      if [[ -z "$name" ]]; then
        warn "skipping malformed lock record ${file}: unusable path '${ printable "$path";}'"
        continue
      fi
      rec_files+=("$file")
      rec_paths+=("$path")
      rec_names+=("$name")
      rec_tokens+=("$LOCK_RECORD_TOKEN")
    else
      rc=$?
      if [[ "$rc" -eq 1 ]]; then
        warn "skipping unreadable lock record ${file}"
      else
        warn "skipping malformed lock record ${file}"
      fi
    fi
  done < <(find "$REMOTE_LOCKS_DIR" -maxdepth 1 -type f -name '*.state' -print 2>/dev/null |
    LC_ALL=C sort)
  if [[ "$prune" == true ]]; then
    locks_prune_resolve rec_parents resolved
  fi
  for ((i = 0; i < ${#rec_paths[@]}; i++)); do
    file="${rec_files[i]}"
    path="${rec_paths[i]}"
    name="${rec_names[i]}"
    if [[ "$prune" == true ]]; then
      parent="${rec_parents[i]}"
      segment="${path%/}"
      segment="${segment##*/}"
      token="${resolved["$parent"$'\t'"$segment"]:-}"
      if [[ -z "$token" ]]; then
        rm -f "$file"
        printf 'pruned %s\n' "$name"
        pruned=$((pruned + 1))
        continue
      fi
    else
      token="${rec_tokens[i]}"
    fi
    token_disp=${ printable "$token";}
    printf '%s  %s  %s\n' "$name" "$path" "$token_disp"
    shown=$((shown + 1))
  done
  if [[ "$shown" -eq 0 && "$pruned" -eq 0 ]]; then
    printf 'no recorded locks\n'
  fi
  return 0
}
