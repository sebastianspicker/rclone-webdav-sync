#!/bin/bash
# share.sh command module - manage Nextcloud shares through the OCS sharing
# API. SUB is a remote path below <RCLONE_REMOTE>:<REMOTE_BASE>/; request
# fields are sent as --data-urlencode arguments and responses are parsed
# with the shared awk layer (no jq). Also lists and answers pending local and
# federated shares. Only die/usage_error exit.

SHARE_API='/apps/files_sharing/api/v1/shares'
SHARE_SHAREES_API='/apps/files_sharing/api/v1/sharees'
SHARE_PENDING_API="${SHARE_API}/pending"
SHARE_REMOTE_API='/apps/files_sharing/api/v1/remote_shares'
SHARE_REMOTE_PENDING_API="${SHARE_REMOTE_API}/pending"

SHARE_RECORD_ID=""
SHARE_RECORD_TYPE=""
SHARE_RECORD_WITH=""
SHARE_RECORD_PERMISSIONS=""
SHARE_RECORD_EXPIRATION=""
SHARE_RECORD_NOTE=""
SHARE_RECORD_TOKEN=""
SHARE_RECORD_PATH=""
SHARE_RECORD_URL=""
SHARE_RECORD_SHARED_BY=""
SHARE_RECORD_FIELDS=(
  SHARE_RECORD_ID SHARE_RECORD_TYPE SHARE_RECORD_WITH
  SHARE_RECORD_PERMISSIONS SHARE_RECORD_EXPIRATION SHARE_RECORD_NOTE
  SHARE_RECORD_TOKEN SHARE_RECORD_PATH SHARE_RECORD_URL SHARE_RECORD_SHARED_BY
)

SHARE_SUB=""
SHARE_REMOTE=""
SHARE_ARG1=""
SHARE_ARG2=""
SHARE_ARGC=0

SHARE_ARGS=()

SHARE_RESULT_ID=""
SHARE_RESULT_URL=""

SHARE_PENDING_XML=""
SHARE_PENDING_ERROR=""
SHARE_PENDING_KIND=""
SHARE_PENDING_RECORDS=""
SHARE_PENDING_RECORD_KIND=""
SHARE_PENDING_RECORD_ID=""
SHARE_PENDING_RECORD_TYPE=""
SHARE_PENDING_RECORD_OWNER=""
SHARE_PENDING_RECORD_TARGET=""
SHARE_PENDING_RECORD_CREATED=""
SHARE_PENDING_RECORD_FIELDS=(
  SHARE_PENDING_RECORD_KIND SHARE_PENDING_RECORD_ID
  SHARE_PENDING_RECORD_TYPE SHARE_PENDING_RECORD_OWNER
  SHARE_PENDING_RECORD_TARGET SHARE_PENDING_RECORD_CREATED
)

SHARE_TABLE_WANT=""
SHARE_TABLE_SHOW_OWNER=""

usage_share() {
  usage_emit <<'EOF'
Usage: sciebo share <subcommand> [options]

Manage Nextcloud shares through the OCS sharing API. SUB is a remote path
below <RCLONE_REMOTE>:<REMOTE_BASE>/. Permissions are letters (r=read,
w=update, d=delete, c=create, s=reshare) or a numeric mask; link shares
default to read-only (1), the other share types to all (31).

Subcommands:
  link SUB [options]          create a public link share
  user SUB USER [options]     share with a Nextcloud user
  group SUB GROUP [options]   share with a Nextcloud group
  email SUB ADDRESS [options] share with an email address
  guest SUB GUEST [options]   share with a guest (share type 8)
  circle SUB CIRCLE_ID [opts] share with a circle
  talk SUB ROOM_TOKEN [opts]  share with a Talk conversation
  deck SUB DECK_ID [opts]     share with a deck board
  remote SUB [USER@]SERVER    share with a federated cloud id
  list [SUB] [--reshares] [--json]
                              list shares, optionally only for SUB
  info ID                     show one share
  update ID [options]         change password, expiry, note, permissions
  remove ID [--yes]           delete a share (asks on a terminal)
  leave ID [--yes]            leave a share shared with you (asks)
  pending [--local|--remote] [--json]
                              list shares waiting for your acceptance
  accept ID [--remote]        accept a pending share
  decline ID [--remote] [--yes]
                              decline a pending share (asks on a terminal)
  send-email ID               email an existing share to its recipient
  remote-list [--json]        list accepted federated shares
  search QUERY                find users, groups, and other sharees
  copy-link SUB [options]     create or reuse a public link and copy it
  copy-internal SUB           copy a direct internal link for SUB
  incoming [--json]           list shares shared with you

Link and copy-link options:
  --password P            protect the link with password P
  --expire YYYY-MM-DD     expire the link on that date
  --note TEXT             attach a note
  --permissions LETTERS   permission letters or a numeric mask
  --label LABEL           set a link label
  --download 0|1          set the link download attribute
  --file-drop             upload-only link (permissions 4)
  --file-request          mark the link as a file request

User, group, email, guest, circle, talk, deck, and remote options:
  --permissions LETTERS   permission letters or a numeric mask
  --note TEXT             attach a note
  --send-mail             ask the server to email the share recipient

Email options:
  --permissions LETTERS   permission letters or a numeric mask
  --note TEXT             attach a note
  --password P            protect the share with password P
  --expire YYYY-MM-DD     expire the share on that date
  --send-password-by-talk share the password through Talk (needs --password)
  --send-mail             ask the server to email the share recipient

Update options:
  --password P | --remove-password
  --expire DATE | --remove-expire
  --note TEXT | --remove-note
  --permissions LETTERS
  --label LABEL
  --download 0|1
  --send-mail

Pending options:
  --local     only local pending shares
  --remote    only federated pending shares (accept/decline: force it)
  --json      print JSON: create results, pending and incoming lists

Confirmation:
  remove, leave, and decline ask on a terminal unless --yes is given.
  Without a terminal remove and leave proceed as before; decline refuses
  without --yes because declining can lose access to the share.

Options:
  -h, --help  show this help
EOF
}

# share_load_remote - load settings and require curl plus a Nextcloud remote.
share_load_remote() {
  http_load_context
}

# share_split_args ARGS - split the newline-separated positional arguments
# into SHARE_SUB (the subcommand) and SHARE_ARG1/SHARE_ARG2; SHARE_ARGC is
# the total number of positionals. Thin wrapper over the shared
# split_command_args so `share` and `file` parse positionals identically.
share_split_args() {
  split_command_args "$1" SHARE_SUB SHARE_ARG1 SHARE_ARG2 SHARE_ARGC
  SHARE_REMOTE=""
  return 0
}

# share_expect_args MIN MAX WHAT - usage_error when the number of
# positionals is outside [MIN, MAX]; MAX counts the subcommand itself.
share_expect_args() {
  local min="$1" max="$2" what="$3" extra=""
  if [[ "$SHARE_ARGC" -lt "$min" ]]; then
    usage_error share "${SHARE_SUB} requires ${what}"
  fi
  if [[ "$SHARE_ARGC" -gt "$max" ]]; then
    # The first positional past MAX (0-based index MAX) is the unexpected
    # one, even when several extras follow.
    extra="${POSITIONAL_ARGS[$max]:-}"
    [[ -n "$extra" ]] || extra="${SHARE_ARG2:-${SHARE_ARG1:-}}"
    usage_error share "unexpected argument: $(printable "$extra")"
  fi
  return 0
}

# share_require_options SUB NAME... - usage_error when an option outside the
# allowed set was given for SUB.
share_require_options() {
  local sub="$1" name allowed keyvar ok
  shift
  for name in password expire note permissions label download file-drop file-request send-mail remove-password remove-expire remove-note yes send-password-by-talk json local remote reshares all; do
    keyvar="OPT_${name//-/_}_SET"
    [[ -n "${!keyvar:-}" ]] || continue
    ok=0
    for allowed in "$@"; do
      if [[ "$name" == "$allowed" ]]; then
        ok=1
        break
      fi
    done
    [[ "$ok" -eq 1 ]] || usage_error share "${sub} does not accept --${name}"
  done
  return 0
}

# share_reject_combo FIRST SECOND - usage_error when both value options were
# given (e.g. --password and --remove-password).
share_reject_combo() {
  local first="$1" second="$2"
  local firstvar="OPT_${first//-/_}_SET" secondvar="OPT_${second//-/_}_SET"
  if [[ -n "${!firstvar:-}" && -n "${!secondvar:-}" ]]; then
    usage_error share "--${first} and --${second} are mutually exclusive"
  fi
  return 0
}

# share_valid_id ID - true when ID is a non-empty numeric share id.
share_valid_id() {
  numeric_id "$1"
}

# share_interactive - true when a confirmation prompt may be shown: stdin
# is a terminal and --non-interactive was not given. The terminal check goes
# through the shared ui_stdin_tty seam so tests can substitute it.
share_interactive() {
  ui_stdin_tty && [[ -z "${SCIEBO_NON_INTERACTIVE:-}" ]]
}

# share_ocs_path SUB - the OCS `path` field for SUB.
share_ocs_path() { printf '/%s/%s' "$REMOTE_BASE" "$1"; }

# share_list_path SUB - OCS list URL filtered to SUB's path.
share_list_path() {
  printf '%s?path=%s&subfiles=false' "$SHARE_API" "$(http_urlencode "$(share_ocs_path "$1")")"
}

# share_type_label TYPE - display name for an OCS share type; unknown types
# keep their numeric value.
share_type_label() {
  case "$1" in
    0) printf 'user' ;;
    1) printf 'group' ;;
    3) printf 'link' ;;
    4) printf 'email' ;;
    6) printf 'remote' ;;
    7) printf 'circle' ;;
    8) printf 'guest' ;;
    10) printf 'talk' ;;
    12) printf 'deck' ;;
    *) printf '%s' "$1" ;;
  esac
}

# share_parse_permissions LETTERS DEFAULT - print the numeric permission mask
# for LETTERS (r=1, w=2, d=8, c=4, s=16); a digits-only value is already a
# mask, and an empty value takes DEFAULT. Unknown letters are a usage error.
share_parse_permissions() {
  local value="$1" default="$2" mask=0 i=0 n=0 c=""
  if [[ -z "$value" ]]; then
    printf '%s' "$default"
    return 0
  fi
  case "$value" in
    *[!0-9]*) ;;
    *)
      printf '%s' "$value"
      return 0
      ;;
  esac
  n="${#value}"
  while [[ "$i" -lt "$n" ]]; do
    c="${value:$i:1}"
    case "$c" in
      r) mask=$((mask + 1)) ;;
      w) mask=$((mask + 2)) ;;
      d) mask=$((mask + 8)) ;;
      c) mask=$((mask + 4)) ;;
      s) mask=$((mask + 16)) ;;
      *) usage_error share "unknown permission letter '${c}' (use r, w, d, c, s or a numeric mask)" ;;
    esac
    i=$((i + 1))
  done
  printf '%s' "$mask"
}

# share_add_field NAME VALUE - append a --data-urlencode pair to SHARE_ARGS.
share_add_field() {
  SHARE_ARGS+=("--data-urlencode" "$1=$2")
}

# share_server_major - print the server major version from the capabilities
# cache (CAP_VERSION), or nothing when the version is unknown. Loads the cache
# through capabilities_load when that helper is available; older servers and
# runs without a cache stay unknown.
share_server_major() {
  local version="" major=""
  if type capabilities_load >/dev/null 2>&1; then
    capabilities_load 2>/dev/null || true
  fi
  version="${CAP_VERSION:-}"
  major="${version%%.*}"
  case "$major" in
    '' | *[!0-9]*) return 0 ;;
  esac
  printf '%d' "$((10#$major))"
}

# share_download_attr_element VALUE - the Nextcloud 30+ attribute object for a
# link download value (JSON booleans).
share_download_attr_element() {
  case "$1" in
    0) printf '{"scope":"permissions","key":"download","value":false}' ;;
    *) printf '{"scope":"permissions","key":"download","value":true}' ;;
  esac
}

# share_download_attr VALUE - print the OCS `attributes` JSON for a link
# download value; callers validate VALUE first with share_require_download.
# Nextcloud 30 moved the attribute to an array of {scope,key,value} objects,
# so the server major version picks the shape; an unknown version keeps the
# legacy object.
share_download_attr() {
  local value="$1" major=""
  major="$(share_server_major)"
  if [[ -n "$major" && "$major" -ge 30 ]]; then
    printf '[%s]' "$(share_download_attr_element "$value")"
    return 0
  fi
  printf '{"download":%s}' "$value"
}

# share_link_attributes - print the combined OCS `attributes` value for link
# creation from --download and --file-request, or nothing when neither was
# given. A file request always uses the array form (it only exists on servers
# that accept it); download alone keeps share_download_attr's version-aware
# shape, and the two combine into one array when both are set.
share_link_attributes() {
  local parts=() joined="" part=""
  if [[ -n "${OPT_file_request_SET:-}" ]]; then
    if [[ -n "${OPT_download_SET:-}" ]]; then
      parts+=("$(share_download_attr_element "${OPT_download:-}")")
    fi
    parts+=('{"scope":"fileRequest","key":"enabled","value":true}')
    for part in "${parts[@]}"; do
      joined="${joined:+${joined},}${part}"
    done
    printf '[%s]' "$joined"
    return 0
  fi
  if [[ -n "${OPT_download_SET:-}" ]]; then
    share_download_attr "${OPT_download:-}"
  fi
  return 0
}

# share_require_download - usage_error unless --download, when given, is 0 or 1.
share_require_download() {
  if [[ -n "${OPT_download_SET:-}" ]]; then
    case "${OPT_download:-}" in
      0 | 1) ;;
      *) usage_error share "--download takes 0 or 1" ;;
    esac
  fi
  return 0
}

# Share passwords never travel in argv (ps/procfs can read it); they are
# written to a mode-600 temp file that curl reads with --data-urlencode
# name@file. The files are registered for EXIT cleanup and discarded as soon
# as the request returned.
SHARE_SECRET_FILES=""

# share_add_secret_field NAME VALUE - append a --data-urlencode pair whose
# value is read from a mode-600 temp file instead of the command line.
share_add_secret_field() {
  local name="$1" value="$2" file=""
  temp_mktemp_into file "${TMPDIR:-/tmp}/sciebo-share.XXXXXX" ||
    die "cannot create a temporary file for --${name}"
  printf '%s' "$value" >"$file" || {
    temp_discard "$file"
    die "cannot write the temporary file for --${name}"
  }
  chmod 600 "$file" 2>/dev/null || true
  SHARE_SECRET_FILES="${SHARE_SECRET_FILES}${file}"$'\n'
  SHARE_ARGS+=("--data-urlencode" "${name}@${file}")
}

# share_secrets_discard - remove the secret temp files after the request.
share_secrets_discard() {
  local file=""
  [[ -n "$SHARE_SECRET_FILES" ]] || return 0
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    temp_discard "$file"
  done <<<"$SHARE_SECRET_FILES"
  SHARE_SECRET_FILES=""
}

# share_parse_xml XML - print one TAB-separated record per <element>: id,
# share_type, share_with, permissions, expiration, note, token, path, url,
# shared_by (share_owner, else uid_owner; empty when absent). One awk pass
# for the whole document; missing and self-closed fields stay empty.
share_parse_xml() {
  xml_records "$1" element id share_type share_with permissions expiration \
    note token path url 'share_owner|uid_owner'
}

# share_record_url - print the public URL of the current SHARE_RECORD_*
# values: the server <url> when present, else ${HTTP_BASE}/s/<token> for
# link shares. Empty when the share has no public URL.
share_record_url() {
  if [[ -n "$SHARE_RECORD_URL" ]]; then
    printf '%s' "$SHARE_RECORD_URL"
    return 0
  fi
  if [[ "$SHARE_RECORD_TYPE" == "3" && -n "$SHARE_RECORD_TOKEN" ]]; then
    printf '%s/s/%s' "$HTTP_BASE" "$SHARE_RECORD_TOKEN"
  fi
  return 0
}

# share_path_or_url - the Path-or-URL column value for the current record.
share_path_or_url() {
  local url=""
  url=${ share_record_url;}
  if [[ -n "$url" ]]; then
    printf '%s' "$url"
  else
    printf '%s' "$SHARE_RECORD_PATH"
  fi
}

# share_print_row LINE - print one row of the share table. The path filter
# and the owner mode come from SHARE_TABLE_WANT/SHARE_TABLE_SHOW_OWNER (set by
# share_print_rows). Returns non-zero to skip a record.
share_print_row() {
  local owner="" want="$SHARE_TABLE_WANT" show_owner="$SHARE_TABLE_SHOW_OWNER"
  local id="" type="" with="" perms="" expires="" path_or_url=""
  record_split "$1" "${SHARE_RECORD_FIELDS[@]}"
  [[ -n "$SHARE_RECORD_ID" ]] || return 1
  [[ -z "$want" || "$SHARE_RECORD_PATH" == "$want" ]] || return 1
  id=${ printable "$SHARE_RECORD_ID";}
  type=${ share_type_label "$SHARE_RECORD_TYPE";}
  with=${ printable "$SHARE_RECORD_WITH";}
  perms=${ printable "$SHARE_RECORD_PERMISSIONS";}
  expires=${ printable "$SHARE_RECORD_EXPIRATION";}
  path_or_url=${ share_path_or_url;}
  path_or_url=${ printable "$path_or_url";}
  if [[ "$show_owner" == "1" ]]; then
    owner="$SHARE_RECORD_SHARED_BY"
    [[ -n "$owner" ]] || owner="-"
    owner=${ printable "$owner";}
    printf '%-8s %-8s %-20s %-12s %-12s %-16s %s\n' \
      "$id" "$type" "$with" "$perms" "$expires" "$owner" "$path_or_url"
  else
    printf '%-8s %-8s %-20s %-12s %-12s %s\n' \
      "$id" "$type" "$with" "$perms" "$expires" "$path_or_url"
  fi
  return 0
}

# share_print_rows XML [SUB] [EMPTY] [SHOW_OWNER] - print the share table.
# With SUB, rows whose path differs from "/${REMOTE_BASE}/${SUB}" are dropped
# even when the server ignores the path filter. EMPTY defaults to "no shares";
# SHOW_OWNER=1 adds the Shared-by column used by `share incoming`.
share_print_rows() {
  local xml="$1" sub="${2:-}" empty="${3:-no shares}" show_owner="${4:-0}"
  SHARE_TABLE_WANT=""
  SHARE_TABLE_SHOW_OWNER="$show_owner"
  [[ -z "$sub" ]] || SHARE_TABLE_WANT=${ share_ocs_path "$sub";}
  if [[ "$show_owner" == "1" ]]; then
    output_rows "$empty" share_print_row 0 \
      '%-8s %-8s %-20s %-12s %-12s %-16s %s\n' \
      "ID" "Type" "With" "Permissions" "Expires" "Shared-by" "Path-or-URL" \
      < <(share_parse_xml "$xml")
  else
    output_rows "$empty" share_print_row 0 \
      '%-8s %-8s %-20s %-12s %-12s %s\n' \
      "ID" "Type" "With" "Permissions" "Expires" "Path-or-URL" \
      < <(share_parse_xml "$xml")
  fi
}

# share_print_json XML [SUB] - print the shares as a JSON document: an object
# with a "shares" array of {id, type, with, permissions, expiration, note,
# path, url, shared_by}. With SUB, rows whose path differs from
# "/${REMOTE_BASE}/${SUB}" are dropped like share_print_rows does.
# Server-controlled values go through the escaping helpers.
share_print_json() {
  local xml="$1" sub="${2:-}" line="" want="" type_label="" url=""
  [[ -z "$sub" ]] || want=${ share_ocs_path "$sub";}
  output_mode_set true
  output_json_list_begin "shares"
  while IFS= read -r line; do
    record_split "$line" "${SHARE_RECORD_FIELDS[@]}"
    [[ -n "$SHARE_RECORD_ID" ]] || continue
    [[ -z "$want" || "$SHARE_RECORD_PATH" == "$want" ]] || continue
    type_label=${ share_type_label "$SHARE_RECORD_TYPE";}
    url=${ share_record_url;}
    output_json_object_begin
    output_json_kv "id" "$SHARE_RECORD_ID"
    output_json_kv "type" "$type_label"
    output_json_kv "with" "$SHARE_RECORD_WITH"
    output_json_kv "permissions" "$SHARE_RECORD_PERMISSIONS"
    output_json_kv "expiration" "$SHARE_RECORD_EXPIRATION"
    output_json_kv "note" "$SHARE_RECORD_NOTE"
    output_json_kv "path" "$SHARE_RECORD_PATH"
    output_json_kv "url" "$url"
    output_json_kv "shared_by" "$SHARE_RECORD_SHARED_BY"
    output_json_object_end
  done < <(share_parse_xml "$xml")
  output_json_list_end
}

# share_ocs_ok - true when the last ocs_request_allow answered with a
# 2xx/3xx status and an OCS "ok" envelope.
share_ocs_ok() {
  http_ok_code "$HTTP_CODE" || return 1
  [[ "$OCS_STATUS" == "ok" ]]
}

# share_error_text - describe the last failed OCS/HTTP response: the OCS
# message when present, else the HTTP status.
share_error_text() {
  if [[ -n "$OCS_MESSAGE" ]]; then
    printf 'Nextcloud API error %s: %s' "${OCS_STATUSCODE:-?}" "$OCS_MESSAGE"
    return 0
  fi
  case "$HTTP_CODE" in
    '' | 000) printf 'request failed' ;;
    *) printf 'HTTP %s' "$HTTP_CODE" ;;
  esac
}

# --- pending shares ---------------------------------------------------------

# share_pending_get URL - GET URL and, when the response is an OK OCS
# envelope, store its body in SHARE_PENDING_XML and return 0; otherwise
# return 1 so the caller can try the fallback list or report the failure.
share_pending_get() {
  ocs_request_allow GET "$1"
  share_ocs_ok || return 1
  SHARE_PENDING_XML="$HTTP_BODY"
  return 0
}

# share_pending_fallback_needed - true when the last /shares/pending
# response is the older-server shape (OCS 404/999, HTTP 404, or a "wrong
# path"/"not found" message) that predates the pending route.
share_pending_fallback_needed() {
  case "$OCS_STATUSCODE" in
    404 | 999) return 0 ;;
  esac
  case "$HTTP_CODE" in
    404) return 0 ;;
  esac
  case "${OCS_MESSAGE,,}" in
    *"wrong path"*) return 0 ;;
    *"not found"*) return 0 ;;
  esac
  return 1
}

# share_pending_fetch KIND - GET KIND's ("local" or "remote") pending list
# into SHARE_PENDING_XML; on failure set SHARE_PENDING_ERROR and return 1.
# The local /shares/pending route exists on current servers only: older
# servers answer OCS 404/999 or a "wrong path" error, and that case falls
# back to the shared-with-me list filtered with state=pending (the variant
# the web UI used before the route existed). Responses stay XML.
share_pending_fetch() {
  local kind="$1" LC_ALL=C
  SHARE_PENDING_XML=""
  SHARE_PENDING_ERROR=""
  case "$kind" in
    remote)
      if share_pending_get "$SHARE_REMOTE_PENDING_API"; then
        return 0
      fi
      ;;
    local)
      if share_pending_get "$SHARE_PENDING_API"; then
        return 0
      fi
      if share_pending_fallback_needed; then
        if share_pending_get "${SHARE_API}?shared_with_me=true&state=pending"; then
          return 0
        fi
      fi
      ;;
  esac
  SHARE_PENDING_ERROR="cannot list ${kind} pending shares: $(share_error_text)"
  return 1
}

# share_pending_records XML KIND - print one TAB-separated record per
# pending <element>: kind, id, share_type, owner, target, created. Local
# records use the share fields (share_owner/uid_owner, path, stime), remote
# records the federated fields (owner, name/mountpoint, type 6); servers
# often omit a created timestamp for federated shares, so the field can be
# empty. One awk pass for the whole document; elements without an id are
# dropped in the loop.
share_pending_records() {
  local xml="$1" kind="$2" line="" id="" type="" owner="" target="" created=""
  local -a groups=()
  if [[ "$kind" == "remote" ]]; then
    groups=(id share_type owner 'name|mountpoint|remote' 'stime|created')
  else
    groups=(id share_type 'share_owner|uid_owner' 'path|share_with|name' 'stime|created')
  fi
  while IFS= read -r line; do
    record_split "$line" id type owner target created
    [[ -n "$id" ]] || continue
    if [[ "$kind" == "remote" && -z "$type" ]]; then
      type="6"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$kind" "$id" "$type" "$owner" "$target" "$created"
  done < <(xml_records "$xml" element "${groups[@]}")
}

# share_pending_has XML KIND ID - true when ID appears in the pending
# records parsed from XML for KIND.
share_pending_has() {
  local xml="$1" kind="$2" id="$3" line=""
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    record_split "$line" "${SHARE_PENDING_RECORD_FIELDS[@]}"
    if [[ "$SHARE_PENDING_RECORD_ID" == "$id" ]]; then
      return 0
    fi
  done < <(share_pending_records "$xml" "$kind")
  return 1
}

# share_pending_kind ID - resolve which pending list owns ID and set
# SHARE_PENDING_KIND ("local" or "remote"). --remote forces federated;
# otherwise ID is looked up in the local list first and in the federated
# list next, so accept and decline agree with `pending`. On failure
# SHARE_PENDING_ERROR explains why.
share_pending_kind() {
  local id="$1" fetched=0
  SHARE_PENDING_KIND=""
  SHARE_PENDING_ERROR=""
  if [[ -n "${OPT_remote_SET:-}" ]]; then
    SHARE_PENDING_KIND="remote"
    return 0
  fi
  if share_pending_fetch local; then
    fetched=$((fetched + 1))
    if share_pending_has "$SHARE_PENDING_XML" local "$id"; then
      SHARE_PENDING_KIND="local"
      return 0
    fi
  fi
  if share_pending_fetch remote; then
    fetched=$((fetched + 1))
    if share_pending_has "$SHARE_PENDING_XML" remote "$id"; then
      SHARE_PENDING_KIND="remote"
      return 0
    fi
  fi
  if [[ "$fetched" -eq 0 ]]; then
    SHARE_PENDING_ERROR="cannot tell whether pending share ${id} is local or federated: no pending list could be read"
  else
    SHARE_PENDING_ERROR="no pending share with id ${id} (pass --remote to force a federated share)"
  fi
  return 1
}

# share_pending_cell VALUE - VALUE for a table cell, or "-" when empty.
share_pending_cell() {
  if [[ -n "$1" ]]; then
    printf '%s' "$1"
  else
    printf '-'
  fi
}

# share_pending_print_row LINE - print one pending-share table row; non-zero
# when the record has no kind.
share_pending_print_row() {
  local kind="" id="" type="" owner="" target="" created=""
  record_split "$1" "${SHARE_PENDING_RECORD_FIELDS[@]}"
  [[ -n "$SHARE_PENDING_RECORD_KIND" ]] || return 1
  kind=${ printable "$SHARE_PENDING_RECORD_KIND";}
  id=${ printable "$SHARE_PENDING_RECORD_ID";}
  type=${ share_type_label "$SHARE_PENDING_RECORD_TYPE";}
  type=${ printable "$type";}
  owner=${ share_pending_cell "$SHARE_PENDING_RECORD_OWNER";}
  owner=${ printable "$owner";}
  target=${ share_pending_cell "$SHARE_PENDING_RECORD_TARGET";}
  target=${ printable "$target";}
  created=${ share_pending_cell "$SHARE_PENDING_RECORD_CREATED";}
  created=${ printable "$created";}
  printf '%-8s %-8s %-8s %-20s %-12s %s\n' \
    "$kind" "$id" "$type" "$owner" "$created" "$target"
  return 0
}

# share_pending_print_rows - print SHARE_PENDING_RECORDS as the pending
# table: Kind, ID, Type, Owner, Created, Target.
share_pending_print_rows() {
  output_rows "no pending shares" share_pending_print_row 0 \
    '%-8s %-8s %-8s %-20s %-12s %s\n' "Kind" "ID" "Type" "Owner" "Created" "Target" \
    <<<"$SHARE_PENDING_RECORDS"
}

# share_pending_print_json - print SHARE_PENDING_RECORDS as a
# {"pending": [...]} document with kind, id, type, owner, target, created.
share_pending_print_json() {
  local line="" type_label=""
  output_mode_set true
  output_json_list_begin "pending"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    record_split "$line" "${SHARE_PENDING_RECORD_FIELDS[@]}"
    [[ -n "$SHARE_PENDING_RECORD_KIND" ]] || continue
    type_label=${ share_type_label "$SHARE_PENDING_RECORD_TYPE";}
    output_json_object_begin
    output_json_kv "kind" "$SHARE_PENDING_RECORD_KIND"
    output_json_kv "id" "$SHARE_PENDING_RECORD_ID"
    output_json_kv "type" "$type_label"
    output_json_kv "owner" "$SHARE_PENDING_RECORD_OWNER"
    output_json_kv "target" "$SHARE_PENDING_RECORD_TARGET"
    output_json_kv "created" "$SHARE_PENDING_RECORD_CREATED"
    output_json_object_end
  done <<<"$SHARE_PENDING_RECORDS"
  output_json_list_end
}

# share_result_parse XML - fill SHARE_RESULT_ID/SHARE_RESULT_URL from an OCS
# create response, falling back to ${HTTP_BASE}/s/<token>. The three fields
# come from one awk pass and split on TAB like ocs_parse.
share_result_parse() {
  local body="$1" parsed="" tab=$'\t' token=""
  parsed="$(printf '%s' "$body" | awk "${_AWK_XML_LIB}"'
    { doc = doc $0 }
    END { printf "%s\t%s\t%s", xml_extract(doc, "id"), xml_extract(doc, "url"), xml_extract(doc, "token") }
  ')"
  SHARE_RESULT_ID="${parsed%%"$tab"*}"
  parsed="${parsed#*"$tab"}"
  SHARE_RESULT_URL="${parsed%%"$tab"*}"
  token="${parsed#*"$tab"}"
  if [[ -z "$SHARE_RESULT_URL" ]]; then
    [[ -z "$token" ]] || SHARE_RESULT_URL="${HTTP_BASE}/s/${token}"
  fi
}

# share_print_result_json TYPE PERMISSIONS - print a created share as
# {"id", "type", "url", "permissions"}; the url key is omitted when the
# server returned none.
share_print_result_json() {
  local type="$1" permissions="$2"
  output_mode_set true
  output_json_begin
  output_json_kv "id" "$SHARE_RESULT_ID"
  output_json_kv "type" "$type"
  [[ -z "$SHARE_RESULT_URL" ]] || output_json_kv "url" "$SHARE_RESULT_URL"
  output_json_kv "permissions" "$permissions"
  output_json_end
}

# share_create TYPE WITH PERMISSIONS - POST a new share for SHARE_REMOTE
# with the value options that were given and fill SHARE_RESULT_*. Dies on
# OCS errors like every ocs_request.
share_create() {
  local type="$1" with="$2" permissions="$3"
  SHARE_ARGS=()
  share_add_field path "$(share_ocs_path "$SHARE_REMOTE")"
  [[ -z "$with" ]] || share_add_field shareWith "$with"
  share_add_field permissions "$permissions"
  [[ -z "${OPT_password_SET:-}" ]] || share_add_secret_field password "${OPT_password:-}"
  [[ -z "${OPT_expire_SET:-}" ]] || share_add_field expireDate "${OPT_expire:-}"
  [[ -z "${OPT_note_SET:-}" ]] || share_add_field note "${OPT_note:-}"
  [[ -z "${OPT_label_SET:-}" ]] || share_add_field label "${OPT_label:-}"
  [[ -z "${OPT_send_password_by_talk_SET:-}" ]] || share_add_field sendPasswordByTalk "true"
  [[ -z "${OPT_send_mail_SET:-}" ]] || share_add_field sendMail "true"
  share_add_field shareType "$type"
  [[ -z "${OPT_download_SET:-}" && -z "${OPT_file_request_SET:-}" ]] ||
    share_add_field attributes "$(share_link_attributes)"
  ocs_request POST "$SHARE_API" ${SHARE_ARGS[@]+"${SHARE_ARGS[@]}"}
  share_secrets_discard
  share_result_parse "$HTTP_BODY"
}

# share_reuse_link - look for an existing public link share of SHARE_REMOTE.
# On success SHARE_RESULT_ID/SHARE_RESULT_URL describe it and rc is 0;
# rc 1 when SUB has no link share yet.
share_reuse_link() {
  local line="" want=""
  want=${ share_ocs_path "$SHARE_REMOTE";}
  ocs_request GET "$(share_list_path "$SHARE_REMOTE")"
  while IFS= read -r line; do
    record_split "$line" "${SHARE_RECORD_FIELDS[@]}"
    [[ "$SHARE_RECORD_TYPE" == "3" ]] || continue
    [[ "$SHARE_RECORD_PATH" == "$want" ]] || continue
    SHARE_RESULT_ID="$SHARE_RECORD_ID"
    SHARE_RESULT_URL=${ share_record_url;}
    return 0
  done < <(share_parse_xml "$HTTP_BODY")
  return 1
}

# share_copy_text TEXT - copy TEXT with pbcopy when it works (printing a
# confirmation); otherwise print TEXT so it can be copied manually.
share_copy_text() {
  local text="$1"
  if have pbcopy && printf '%s' "$text" | pbcopy 2>/dev/null; then
    printf 'copied to clipboard\n'
    return 0
  fi
  printf '%s\n' "$text"
  return 0
}

# share_print_sharee_row LINE - one "type<TAB>shareWith<TAB>label" row; returns
# non-zero for a record with neither a shareWith nor a label.
share_print_sharee_row() {
  local type="" with="" label="" type_label=""
  record_split "$1" type with label
  [[ -n "$with" || -n "$label" ]] || return 1
  type_label=${ share_type_label "$type";}
  with=${ printable "$with";}
  label=${ printable "$label";}
  printf '%s\t%s\t%s\n' "$type_label" "$with" "$label"
  return 0
}

# share_print_sharees XML - print one "type<TAB>shareWith<TAB>label" row per
# sharee <element>, with the numeric shareType shown through share_type_label;
# prints "no matches" when there are none. One awk pass for the whole document;
# rows without a shareWith and label are dropped.
share_print_sharees() {
  output_rows "no matches" share_print_sharee_row 0 "" \
    < <(xml_records "$1" element shareType shareWith label)
}

# share_run_link SUB - create (or reuse, for copy-link) a public link share.
share_run_link() {
  local sub="$1" mask="" default_mask=1
  share_expect_args 2 2 "a remote path argument (SUB)"
  share_require_options "$sub" password expire note permissions label download file-drop file-request json
  share_require_download
  # A file-drop link is upload-only: default to the create permission unless
  # --permissions says otherwise.
  opt_into default_mask file_drop_SET 4
  require_safe_remote_path "$SHARE_ARG1"
  SHARE_REMOTE="$SHARE_ARG1"
  share_load_remote
  if [[ "$sub" == "copy-link" ]] && share_reuse_link; then
    mask="$SHARE_RECORD_PERMISSIONS"
  else
    mask="$(share_parse_permissions "${OPT_permissions:-}" "$default_mask")"
    share_create 3 "" "$mask"
  fi
  if [[ -n "${OPT_json_SET:-}" ]]; then
    if [[ "$sub" == "copy-link" && -z "$SHARE_RESULT_URL" ]]; then
      die "the server returned no public link for '$(printable "$SHARE_REMOTE")'"
    fi
    share_print_result_json "link" "$mask"
  elif [[ "$sub" == "link" ]]; then
    printf 'created share %s\n' "$(printable "$SHARE_RESULT_ID")"
    [[ -z "$SHARE_RESULT_URL" ]] || printf 'url: %s\n' "$(printable "$SHARE_RESULT_URL")"
  else
    [[ -n "$SHARE_RESULT_URL" ]] ||
      die "the server returned no public link for '$(printable "$SHARE_REMOTE")'"
    share_copy_text "$(printable "$SHARE_RESULT_URL")"
  fi
  return 0
}

# share_run_create TYPE SUB WHAT [ALLOWED...] - create a share of TYPE for
# SHARE_ARG2 (the sharee value). WHAT is the arity hint, ALLOWED... is the
# subcommand's option allowlist, and the result is printed as JSON or text.
# The email password option is the only per-sub extra rule.
share_run_create() {
  local type="$1" sub="$2" what="$3" mask=""
  shift 3
  share_expect_args 3 3 "$what"
  share_require_options "$sub" "$@"
  if [[ "$sub" == "email" && -n "${OPT_send_password_by_talk_SET:-}" && -z "${OPT_password_SET:-}" ]]; then
    usage_error share "--send-password-by-talk requires --password"
  fi
  require_safe_remote_path "$SHARE_ARG1"
  SHARE_REMOTE="$SHARE_ARG1"
  mask="$(share_parse_permissions "${OPT_permissions:-}" 31)"
  share_load_remote
  share_create "$type" "$SHARE_ARG2" "$mask"
  if [[ -n "${OPT_json_SET:-}" ]]; then
    share_print_result_json "$sub" "$mask"
  else
    printf 'created share %s\n' "$(printable "$SHARE_RESULT_ID")"
  fi
  return 0
}

# share_run_list [SUB] - list the shares of SUB, or every share. --reshares
# asks the server for reshares only; --json prints the shared JSON document.
share_run_list() {
  local url="" sub="${2:-}"
  share_expect_args 1 2 "no arguments"
  share_require_options list reshares json
  share_load_remote
  if [[ "$SHARE_ARGC" -eq 2 ]]; then
    require_safe_remote_path "$SHARE_ARG1"
    sub="$SHARE_ARG1"
    url="$(share_list_path "$sub")"
    [[ -z "${OPT_reshares_SET:-}" ]] || url="${url}&reshares=true"
  else
    url="$SHARE_API"
    [[ -z "${OPT_reshares_SET:-}" ]] || url="${url}?reshares=true"
  fi
  ocs_request GET "$url"
  if [[ -n "${OPT_json_SET:-}" ]]; then
    share_print_json "$HTTP_BODY" "$sub"
  else
    share_print_rows "$HTTP_BODY" "$sub"
  fi
  return 0
}

# share_run_info ID - show one share.
share_run_info() {
  share_expect_args 2 2 "a share id"
  share_require_options info
  share_valid_id "$SHARE_ARG1" ||
    usage_error share "invalid share id: $(printable "$SHARE_ARG1")"
  share_load_remote
  ocs_request GET "${SHARE_API}/${SHARE_ARG1}"
  share_print_rows "$HTTP_BODY" "" "no share with id ${SHARE_ARG1}"
  return 0
}

# share_update_fields - append the --data-urlencode pairs for the update
# options that were given. Each entry is "<option>:<api field>:<kind>":
# value sends the option's value, empty an explicit removal, secret routes
# the password through share_add_secret_field, true sends "true", and the
# permissions/download kinds derive their value. Field order matches the
# previous flat chain.
share_update_fields() {
  local entry="" opt="" rest="" field="" kind="" key="" setvar="" valvar="" value=""
  for entry in \
    password:password:secret \
    remove-password:password:empty \
    expire:expireDate:value \
    remove-expire:expireDate:empty \
    note:note:value \
    remove-note:note:empty \
    permissions:permissions:permissions \
    label:label:value \
    send-mail:sendMail:true \
    download:attributes:download; do
    opt="${entry%%:*}"
    rest="${entry#*:}"
    field="${rest%%:*}"
    kind="${rest#*:}"
    key="${opt//-/_}"
    setvar="OPT_${key}_SET"
    valvar="OPT_${key}"
    [[ -n "${!setvar:-}" ]] || continue
    value="${!valvar:-}"
    case "$kind" in
      secret) share_add_secret_field "$field" "$value" ;;
      empty) share_add_field "$field" "" ;;
      true) share_add_field "$field" "true" ;;
      permissions) share_add_field "$field" "$(share_parse_permissions "$value" 0)" ;;
      download) share_add_field "$field" "$(share_download_attr "$value")" ;;
      *) share_add_field "$field" "$value" ;;
    esac
  done
  return 0
}

# share_run_update ID - change the given fields of one share.
share_run_update() {
  share_expect_args 2 2 "a share id"
  share_require_options update password remove-password expire remove-expire note remove-note permissions label download send-mail
  share_require_download
  share_valid_id "$SHARE_ARG1" ||
    usage_error share "invalid share id: $(printable "$SHARE_ARG1")"
  share_reject_combo password remove-password
  share_reject_combo expire remove-expire
  share_reject_combo note remove-note
  # Load settings before building the body: the download/file-request
  # attributes are shaped from the capabilities cache, which load_settings
  # locates.
  share_load_remote
  SHARE_ARGS=()
  share_update_fields
  [[ "${#SHARE_ARGS[@]}" -gt 0 ]] ||
    usage_error share "update requires at least one change option"
  ocs_request PUT "${SHARE_API}/${SHARE_ARG1}" ${SHARE_ARGS[@]+"${SHARE_ARGS[@]}"}
  share_secrets_discard
  printf 'updated share %s\n' "$SHARE_ARG1"
  return 0
}

# share_run_remove ID - delete one share after confirmation.
share_run_remove() {
  local path="" line=""
  share_expect_args 2 2 "a share id"
  share_require_options remove yes
  share_valid_id "$SHARE_ARG1" ||
    usage_error share "invalid share id: $(printable "$SHARE_ARG1")"
  share_load_remote
  # Shared proceed gate (the share_confirm_mutation alias was inlined):
  # --yes answers yes, a non-interactive run proceeds without prompting.
  if ! ui_confirm_proceed "remove share ${SHARE_ARG1}? [y/N] "; then
    return 0
  fi
  ocs_request GET "${SHARE_API}/${SHARE_ARG1}"
  while IFS= read -r line; do
    record_split "$line" "${SHARE_RECORD_FIELDS[@]}"
    [[ -n "$SHARE_RECORD_ID" ]] || continue
    path="$SHARE_RECORD_PATH"
    break
  done < <(share_parse_xml "$HTTP_BODY")
  ocs_request DELETE "${SHARE_API}/${SHARE_ARG1}"
  if [[ -n "$path" ]]; then
    printf 'removed share %s (%s)\n' "$SHARE_ARG1" "$(printable "$path")"
  else
    printf 'removed share %s\n' "$SHARE_ARG1"
  fi
  return 0
}

# share_pending_load - fetch the pending lists selected by --local/--remote
# into SHARE_PENDING_RECORDS (one TAB-separated record per line). Warns and
# keeps the kinds that answered; dies when every requested list failed.
share_pending_load() {
  local requested=0 failed=0
  SHARE_PENDING_RECORDS=""
  if [[ -z "${OPT_remote_SET:-}" ]]; then
    requested=$((requested + 1))
    if share_pending_fetch local; then
      SHARE_PENDING_RECORDS="${SHARE_PENDING_RECORDS}$(share_pending_records "$SHARE_PENDING_XML" local)"$'\n'
    else
      warn "$SHARE_PENDING_ERROR"
      failed=$((failed + 1))
    fi
  fi
  if [[ -z "${OPT_local_SET:-}" ]]; then
    requested=$((requested + 1))
    if share_pending_fetch remote; then
      SHARE_PENDING_RECORDS="${SHARE_PENDING_RECORDS}$(share_pending_records "$SHARE_PENDING_XML" remote)"$'\n'
    else
      warn "$SHARE_PENDING_ERROR"
      failed=$((failed + 1))
    fi
  fi
  if [[ "$requested" -eq "$failed" ]]; then
    die "could not list pending shares"
  fi
  return 0
}

# share_run_pending - list pending local and/or remote shares.
share_run_pending() {
  share_expect_args 1 1 "no arguments"
  share_require_options pending local remote json
  share_reject_combo local remote
  share_load_remote
  share_pending_load
  if [[ -n "${OPT_json_SET:-}" ]]; then
    share_pending_print_json
  else
    share_pending_print_rows
  fi
  return 0
}

# share_respond_one SUB KIND ID - answer one pending share of KIND ("local" or
# "remote"): POST to accept, DELETE to decline. Prints the confirmation line;
# dies on OCS errors like every ocs_request.
share_respond_one() {
  local sub="$1" kind="$2" id="$3" endpoint=""
  if [[ "$kind" == "remote" ]]; then
    endpoint="$SHARE_REMOTE_PENDING_API"
  else
    endpoint="$SHARE_PENDING_API"
  fi
  if [[ "$sub" == "accept" ]]; then
    ocs_request POST "${endpoint}/${id}"
    printf 'accepted %s share %s\n' "$kind" "$id"
  else
    ocs_request DELETE "${endpoint}/${id}"
    printf 'declined %s share %s\n' "$kind" "$id"
  fi
  return 0
}

# share_respond_all SUB - accept or decline every pending share selected by
# --local/--remote. Reuses the pending fetch/parse and share_respond_one;
# prints "no pending shares" when neither list has a record.
share_respond_all() {
  local sub="$1" line="" kind="" id="" count=0
  share_pending_load
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    record_split "$line" "${SHARE_PENDING_RECORD_FIELDS[@]}"
    [[ -n "$SHARE_PENDING_RECORD_ID" ]] || continue
    kind="$SHARE_PENDING_RECORD_KIND"
    id="$SHARE_PENDING_RECORD_ID"
    # Ids come from the server; validate them before they reach the request
    # path so a malformed or hostile record cannot smuggle in a traversal.
    if ! share_valid_id "$id"; then
      warn "skipping pending share with invalid id: $(printable "$id")"
      continue
    fi
    share_respond_one "$sub" "$kind" "$id"
    count=$((count + 1))
  done <<<"$SHARE_PENDING_RECORDS"
  [[ "$count" -gt 0 ]] || printf 'no pending shares\n'
  return 0
}

# share_require_respond_options SUB - the option set `share accept` and
# `share decline` accept.
share_require_respond_options() {
  if [[ "$1" == "accept" ]]; then
    share_require_options accept remote all
  else
    share_require_options decline remote yes all
  fi
  return 0
}

# share_decline_gate SUB REQUIRES - usage_error when a decline without --yes
# runs non-interactively, before any request is made.
#
# Declining can lose access, so a scripted run must ask for it explicitly;
# remove/leave keep their old non-interactive behavior. This half of the
# gate stays hand-rolled on purpose: ui_confirm_mutation_soft would also
# prompt here, but the single-id prompt needs the kind share_pending_kind
# only learns after its HTTP fetches, and a refused run must exit before
# share_load_remote touches curl (the tests pin "refusal no GET"). The
# prompt itself is the shared ui_confirm_mutation below.
share_decline_gate() {
  local sub="$1" requires="$2"
  if [[ "$sub" == "decline" && "${OPT_yes:-0}" != "1" ]] && ! share_interactive; then
    usage_error share "$requires"
  fi
  return 0
}

# share_run_respond_all SUB REQUIRES - accept or decline every pending share
# selected by --local/--remote. The mutation prompt runs before the pending
# list is fetched, so a declined --all stops without a GET.
share_run_respond_all() {
  local sub="$1" requires="$2"
  [[ "$SHARE_ARGC" -eq 1 ]] ||
    usage_error share "--all cannot be combined with a share id"
  share_load_remote
  if [[ "$sub" == "decline" ]]; then
    ui_confirm_mutation share "$requires" \
      "decline all pending shares? [y/N] " || return 0
  fi
  share_respond_all "$sub"
  return 0
}

# share_run_respond_id SUB REQUIRES - accept or decline the single pending
# share named by SHARE_ARG1, resolving its kind through the pending lists.
share_run_respond_id() {
  local sub="$1" requires="$2" kind=""
  share_expect_args 2 2 "a pending share id"
  share_valid_id "$SHARE_ARG1" ||
    usage_error share "invalid share id: $(printable "$SHARE_ARG1")"
  share_load_remote
  share_pending_kind "$SHARE_ARG1" || die "$SHARE_PENDING_ERROR"
  kind="$SHARE_PENDING_KIND"
  if [[ "$sub" == "decline" ]]; then
    ui_confirm_mutation share "$requires" \
      "decline ${kind} share ${SHARE_ARG1}? [y/N] " || return 0
  fi
  share_respond_one "$sub" "$kind" "$SHARE_ARG1"
  return 0
}

# share_run_respond SUB [ID] - accept or decline one pending share, or with
# --all every pending share of the selected kind(s).
share_run_respond() {
  local sub="$1" decline_requires=""
  share_require_respond_options "$sub"
  decline_requires="decline requires --yes when not running interactively (a declined share can be lost)"
  share_decline_gate "$sub" "$decline_requires"
  if [[ -n "${OPT_all_SET:-}" ]]; then
    share_run_respond_all "$sub" "$decline_requires"
    return 0
  fi
  share_run_respond_id "$sub" "$decline_requires"
  return 0
}

# share_run_incoming - list shares shared with the current user.
share_run_incoming() {
  share_expect_args 1 1 "no arguments"
  share_require_options incoming json
  share_load_remote
  ocs_request GET "${SHARE_API}?shared_with_me=true"
  if [[ -n "${OPT_json_SET:-}" ]]; then
    share_print_json "$HTTP_BODY"
  else
    share_print_rows "$HTTP_BODY" "" "no shares" 1
  fi
  return 0
}

# share_run_send_email ID - ask the server to email an existing share to its
# recipient through POST /shares/{id}/send-email.
share_run_send_email() {
  share_expect_args 2 2 "a share id"
  share_require_options send-email
  share_valid_id "$SHARE_ARG1" ||
    usage_error share "invalid share id: $(printable "$SHARE_ARG1")"
  share_load_remote
  ocs_request POST "${SHARE_API}/${SHARE_ARG1}/send-email"
  printf 'sent share %s by email\n' "$SHARE_ARG1"
  return 0
}

# share_remote_print_row LINE - one accepted federated share row; returns
# non-zero when the record has no id.
share_remote_print_row() {
  local id="" type="" owner="" target=""
  record_split "$1" "${SHARE_PENDING_RECORD_FIELDS[@]}"
  [[ -n "$SHARE_PENDING_RECORD_ID" ]] || return 1
  [[ -n "$SHARE_PENDING_RECORD_TYPE" ]] || SHARE_PENDING_RECORD_TYPE="6"
  id=${ printable "$SHARE_PENDING_RECORD_ID";}
  type=${ share_type_label "$SHARE_PENDING_RECORD_TYPE";}
  type=${ printable "$type";}
  owner=${ share_pending_cell "$SHARE_PENDING_RECORD_OWNER";}
  owner=${ printable "$owner";}
  target=${ share_pending_cell "$SHARE_PENDING_RECORD_TARGET";}
  target=${ printable "$target";}
  printf '%-8s %-8s %-20s %s\n' "$id" "$type" "$owner" "$target"
  return 0
}

# share_remote_print_rows XML - accepted federated shares as a table: ID,
# Type, Owner, Target (the mount name or remote host from the record).
share_remote_print_rows() {
  output_rows "no remote shares" share_remote_print_row 0 \
    '%-8s %-8s %-20s %s\n' "ID" "Type" "Owner" "Target" \
    < <(share_pending_records "$1" remote)
}

# share_remote_print_json XML - the accepted federated shares as
# {"remote_shares": [...]} with id, type, owner, target, created.
share_remote_print_json() {
  local xml="$1" line="" type_label=""
  output_mode_set true
  output_json_list_begin "remote_shares"
  while IFS= read -r line; do
    record_split "$line" "${SHARE_PENDING_RECORD_FIELDS[@]}"
    [[ -n "$SHARE_PENDING_RECORD_ID" ]] || continue
    type_label=${ share_type_label "${SHARE_PENDING_RECORD_TYPE:-6}";}
    output_json_object_begin
    output_json_kv "id" "$SHARE_PENDING_RECORD_ID"
    output_json_kv "type" "$type_label"
    output_json_kv "owner" "$SHARE_PENDING_RECORD_OWNER"
    output_json_kv "target" "$SHARE_PENDING_RECORD_TARGET"
    output_json_kv "created" "$SHARE_PENDING_RECORD_CREATED"
    output_json_object_end
  done < <(share_pending_records "$xml" remote)
  output_json_list_end
}

# share_run_remote_list - list the accepted federated shares through
# GET /remote_shares.
share_run_remote_list() {
  share_expect_args 1 1 "no arguments"
  share_require_options remote-list json
  share_load_remote
  ocs_request GET "$SHARE_REMOTE_API"
  if [[ -n "${OPT_json_SET:-}" ]]; then
    share_remote_print_json "$HTTP_BODY"
  else
    share_remote_print_rows "$HTTP_BODY"
  fi
  return 0
}

# share_run_leave ID - remove the current user from a share.
share_run_leave() {
  share_expect_args 2 2 "a share id"
  share_require_options leave yes
  share_valid_id "$SHARE_ARG1" ||
    usage_error share "invalid share id: $(printable "$SHARE_ARG1")"
  share_load_remote
  # Same shared proceed gate as share_run_remove.
  if ! ui_confirm_proceed "leave share ${SHARE_ARG1}? [y/N] "; then
    return 0
  fi
  ocs_request DELETE "${SHARE_API}/${SHARE_ARG1}"
  printf 'left share %s\n' "$SHARE_ARG1"
  return 0
}

# share_run_copy_internal SUB - print the internal share URL of SUB.
share_run_copy_internal() {
  local fileid=""
  share_expect_args 2 2 "a remote path argument (SUB)"
  share_require_options copy-internal
  require_safe_remote_path "$SHARE_ARG1"
  share_load_remote
  fileid="$(nc_fileid "$SHARE_ARG1")"
  share_copy_text "${HTTP_BASE}/index.php/f/${fileid}"
  return 0
}

# SHARE_SEARCH_TYPES - the numeric share types `share search` asks the server
# for, in request order: user, group, email, federated, circle, guest, talk.
SHARE_SEARCH_TYPES=(0 1 4 6 7 8 10)

# share_search_url QUERY TYPES... - the sharees search URL for QUERY limited
# to the given numeric share types.
share_search_url() {
  local query="$1" url="" type=""
  shift
  url="${SHARE_SHAREES_API}?search=$(http_urlencode "$query")&itemType=file&perItem=20"
  for type in "$@"; do
    url="${url}&shareType[]=${type}"
  done
  printf '%s' "$url"
}

# share_search_rejected - true when the last OCS/HTTP response looks like a
# server that refused the requested shareType values (4xx at the HTTP or OCS
# level), so the caller can retry with the baseline user/group types.
share_search_rejected() {
  case "$HTTP_CODE" in 4*) return 0 ;; esac
  case "$OCS_STATUSCODE" in 4*) return 0 ;; esac
  return 1
}

# share_run_search QUERY - search sharees by name. The request asks for every
# share type the sharing dialog knows; a server that rejects the extended
# shareType[] set (4xx) is retried with the baseline user/group types so the
# default search keeps working.
share_run_search() {
  local url=""
  share_expect_args 2 2 "a search query"
  share_require_options search
  share_load_remote
  url="$(share_search_url "$SHARE_ARG1" "${SHARE_SEARCH_TYPES[@]}")"
  ocs_request_allow GET "$url" -g
  if ! share_ocs_ok && share_search_rejected; then
    url="$(share_search_url "$SHARE_ARG1" 0 1)"
    ocs_request_allow GET "$url" -g
  fi
  share_ocs_ok || die "search failed: $(share_error_text)"
  share_print_sharees "$HTTP_BODY"
  return 0
}

cmd_share() {
  local sub=""
  opt_begin "password:s expire:s note:s permissions:s label:s download:s file-drop:b file-request:b send-mail:b remove-password:b remove-expire:b remove-note:b yes:b send-password-by-talk:b json:b local:b remote:b reshares:b all:b" share "" "$@"
  # Run dependencies load after opt_begin's --help exit, so
  # `sciebo share --help` parses none of them: the OCS sharing calls and
  # chunked-upload labels use http/nc_api/capabilities, and the argument
  # split plus the confirm gates use the ui helpers.
  sciebo_require_module http xml_get
  sciebo_require_module nc_api nc_dav_request_allow
  sciebo_require_module capabilities capabilities_load
  sciebo_require_module ui ui_confirm_mutation
  share_split_args "${OPT_EXTRA:-}"
  sub="$SHARE_SUB"
  case "$sub" in
    link | copy-link) share_run_link "$sub" ;;
    user) share_run_create 0 user "a remote path and a user or group name" permissions note json send-mail ;;
    group) share_run_create 1 group "a remote path and a user or group name" permissions note json send-mail ;;
    email) share_run_create 4 email "a remote path and an email address" email permissions note password expire send-password-by-talk json send-mail ;;
    guest) share_run_create 8 guest "a remote path and a guest" permissions note json send-mail ;;
    circle) share_run_create 7 circle "a remote path and a sharee" permissions note json send-mail ;;
    talk) share_run_create 10 talk "a remote path and a sharee" permissions note json send-mail ;;
    deck) share_run_create 12 deck "a remote path and a sharee" permissions note json send-mail ;;
    remote) share_run_create 6 remote "a remote path and a sharee" permissions note json send-mail ;;
    list) share_run_list ;;
    info) share_run_info ;;
    update) share_run_update ;;
    remove) share_run_remove ;;
    pending) share_run_pending ;;
    accept | decline) share_run_respond "$sub" ;;
    incoming) share_run_incoming ;;
    send-email) share_run_send_email ;;
    remote-list) share_run_remote_list ;;
    leave) share_run_leave ;;
    copy-internal) share_run_copy_internal ;;
    search) share_run_search ;;
    '')
      usage_error share "a subcommand is required (link, user, group, email, guest, circle, talk, deck, remote, list, info, update, remove, leave, pending, accept, decline, send-email, remote-list, search, copy-link, copy-internal, incoming)"
      ;;
    *)
      usage_unknown_sub share "$sub"
      ;;
  esac
  return 0
}
