#!/bin/bash
# trash.sh command module - list, restore, and delete Nextcloud trashbin
# items. Talks to the WebDAV trashbin endpoint through lib/http.sh; only the
# restore/rm/empty subcommands modify the server.

TRASH_RECORD_NAME=""
TRASH_RECORD_LOCATION=""
TRASH_RECORD_DELETED=""
TRASH_RECORD_SIZE=""
TRASH_RECORD_ID=""

# IDs validated for the current subcommand (newline-separated).
TRASH_IDS=""
# Nextcloud names the trash properties nc:trashbin-filename/-deletion-time
# (nextcloud.org/ns); ownCloud used oc:trashbin-original-filename/
# -delete-timestamp (owncloud.org/ns). Ask for both vocabularies: a server
# answers the ones it knows and 404s the rest in a separate propstat.
# trashbin-original-location has the same local name in both.
TRASH_PROPFIND_BODY='<?xml version="1.0"?>
<d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">
  <d:prop>
    <nc:trashbin-filename/>
    <nc:trashbin-original-location/>
    <nc:trashbin-deletion-time/>
    <oc:trashbin-original-filename/>
    <oc:trashbin-original-location/>
    <oc:trashbin-delete-timestamp/>
    <d:getcontentlength/>
    <d:resourcetype/>
  </d:prop>
</d:propfind>'

usage_trash() {
  usage_emit <<'EOF'
Usage: sciebo trash [list]
       sciebo trash restore ID [ID ...] [--yes]
       sciebo trash restore --all [--yes]
       sciebo trash rm ID [ID ...] [--yes]
       sciebo trash empty [--yes]

List or clean up the Nextcloud trashbin of the configured remote. The
listing (`list`, the default) is read-only: original name, original
location, deletion time, and size. IDs are the last path segment printed
by the listing.

Commands:
  list           list trashed items (default)
  restore ID ... restore items into their original location
  restore --all  restore every listed item (asks first; needs --yes when
                 not running interactively)
  rm ID ...      permanently delete items (asks first on a terminal; a
                 non-interactive run deletes them as before)
  empty          permanently delete the whole trashbin (asks first; needs
                 --yes when not running interactively)

Options:
  --all       restore: restore every listed item instead of naming IDs
  --yes       skip the restore --all / rm / empty confirmation
  -h, --help  show this help
EOF
}

# trash_id_from_href HREF - the percent-decoded last path segment of a
# listing href (the item id): the shell twin of http.sh's awk
# xml_href_segment (strip the trailing slashes, take the segment, then
# decode), so trash_parse_xml can read the raw d:href through the shared
# xml_records walker instead of its own <d:response> loop.
trash_id_from_href() {
  href_last_segment "${1:-}"
}

# trash_parse_xml XML - print one TAB-separated record per <d:response>
# through the shared xml_records walker: name, location, delete timestamp
# (numeric, empty when absent), size, and the last href segment
# (percent-decoded). Tolerates missing properties, self-closed tags, and
# whitespace/newlines inside tags; the per-field numeric checks run on the
# parsed record here.
# NOTE: the split targets avoid `name` - record_split keeps its own local
# `name` as the loop variable, and printf -v would bind to that instead of
# the caller's.
trash_parse_xml() {
  local line="" orig_name="" location="" deleted="" size="" href="" id=""
  local oc_name="" oc_deleted=""
  while IFS= read -r line; do
    record_split "$line" orig_name oc_name location deleted oc_deleted size href
    # Prefer the Nextcloud property, fall back to the ownCloud one.
    [[ -n "$orig_name" ]] || orig_name="$oc_name"
    [[ -n "$deleted" ]] || deleted="$oc_deleted"
    is_uint "$deleted" || deleted=""
    is_uint "$size" || size=""
    orig_name=${ printable "$orig_name";}
    location=${ printable "$location";}
    deleted=${ printable "$deleted";}
    size=${ printable "$size";}
    id=${ trash_id_from_href "$href";}
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$orig_name" "$location" "$deleted" "$size" "$id"
  done < <(xml_records "$1" 'd:response' \
    'nc:trashbin-filename' 'oc:trashbin-original-filename' \
    'oc:trashbin-original-location' \
    'nc:trashbin-deletion-time' 'oc:trashbin-delete-timestamp' \
    'd:getcontentlength' 'd:href')
}

# trash_valid_id ID - true when ID is one non-empty path segment without
# "/", "..", or control bytes; safe to append to a trashbin URL.
trash_valid_id() {
  local s="$1"
  [[ -n "$s" ]] || return 1
  case "$s" in
    */* | *..*) return 1 ;;
  esac
  [[ "$s" != *[[:cntrl:]]* ]]
}

# trash_collection_url / trash_item_url ID / trash_restore_url ID - WebDAV
# URLs of the trash collection, one trashed item, and an item's absolute
# restore target (Destination header).
trash_collection_url() { nc_dav_url "trashbin/${HTTP_USER}/trash"; }
trash_item_url() { nc_dav_url "trashbin/${HTTP_USER}/trash/$(http_urlencode "$1")"; }
trash_restore_url() { nc_dav_url "trashbin/${HTTP_USER}/restore/$(http_urlencode "$1")"; }

# trash_propfind - PROPFIND the trash collection (Depth 1) and print the
# raw XML. HTTP failures die through nc_dav_request.
trash_propfind() {
  nc_dav_request PROPFIND "$(trash_collection_url)" 1 "$TRASH_PROPFIND_BODY"
  printf '%s' "$HTTP_BODY"
}

# trash_list_ids - print the ID (last href segment) of every trashed item
# from a fresh listing, one per line. The collection record carries no
# original filename and is skipped, like in the listing.
trash_list_ids() {
  local line="" xml=""
  xml="$(trash_propfind)"
  while IFS= read -r line; do
    record_split "$line" TRASH_RECORD_NAME TRASH_RECORD_LOCATION \
      TRASH_RECORD_DELETED TRASH_RECORD_SIZE TRASH_RECORD_ID
    [[ -n "$TRASH_RECORD_NAME" ]] || continue
    [[ -n "$TRASH_RECORD_ID" ]] || continue
    printf '%s\n' "$TRASH_RECORD_ID"
  done < <(trash_parse_xml "$xml")
}

# trash_parse_ids - validate the positional IDs in OPT_EXTRA and set
# TRASH_IDS (newline-separated). usage_error on the first invalid ID.
trash_parse_ids() {
  local id="" ids=""
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    trash_valid_id "$id" ||
      usage_error trash "invalid trash item id: $(printable "$id")"
    ids="${ids}${id}"$'\n'
  done <<<"${OPT_EXTRA:-}"
  TRASH_IDS="$ids"
}

# trash_check_mutation METHOD URL [ID] - return 0 for a successful
# MOVE/DELETE (200/201/204/207); 404 dies with "no such trash item" when
# ID is given, and every other failure surfaces the status and body.
trash_check_mutation() {
  local method="$1" url="$2" id="${3:-}"
  case "$HTTP_CODE" in
    200 | 201 | 204 | 207) return 0 ;;
    404)
      [[ -z "$id" ]] || die "no such trash item: $(printable "$id") (HTTP 404)"
      ;;
  esac
  http_die_http_error "$method" "$url"
}

# trash_restore_one ID - MOVE ID from the trashbin back into its original
# location and print the confirmation. Dies on HTTP errors.
trash_restore_one() {
  local id="$1" url="" destination=""
  url="$(trash_item_url "$id")"
  destination="$(trash_restore_url "$id")"
  nc_dav_request_allow MOVE "$url" "" "" -H "Destination: ${destination}"
  trash_check_mutation MOVE "$url" "$id"
  printf 'restored %s\n' "$(printable "$id")"
}

# trash_remove_one ID - DELETE the trashed item and print the confirmation.
# Dies on HTTP errors.
trash_remove_one() {
  local id="$1" url=""
  url="$(trash_item_url "$id")"
  nc_dav_request_allow DELETE "$url"
  trash_check_mutation DELETE "$url" "$id"
  printf 'removed %s\n' "$(printable "$id")"
}

# trash_print_row LINE - print one listing row; non-zero for the collection
# record, which carries no original filename.
trash_print_row() {
  local name="" location="" deleted="" size="" when=""
  record_split "$1" TRASH_RECORD_NAME TRASH_RECORD_LOCATION \
    TRASH_RECORD_DELETED TRASH_RECORD_SIZE TRASH_RECORD_ID
  [[ -n "$TRASH_RECORD_NAME" ]] || return 1
  name=${ printable "$TRASH_RECORD_NAME";}
  location=${ printable "$TRASH_RECORD_LOCATION";}
  deleted=${ printable "$TRASH_RECORD_DELETED";}
  size=${ printable "$TRASH_RECORD_SIZE";}
  when=${ epoch_to_stamp_or_raw "$deleted";}
  size=${ format_size_bytes "$size";}
  printf '%-32s %-32s %-16s %s\n' "$name" "$location" "$when" "$size"
  return 0
}

# trash_cmd_list - the read-only listing; `trash` and `trash list`.
trash_cmd_list() {
  local xml=""
  opt_begin "" trash "" "$@"
  opt_guard trash
  http_load_context
  xml="$(trash_propfind)"
  output_rows "no trashed files" trash_print_row 0 \
    '%-32s %-32s %-16s %s\n' "Original name" "Location" "Deleted" "Size" \
    < <(trash_parse_xml "$xml")
  return 0
}

# trash_cmd_restore - MOVE the named items (or, with --all, every item of a
# fresh listing after one confirmation) back into their original location.
trash_cmd_restore() {
  local all=0 id=""
  opt_begin "all:b yes:b" trash "" "$@"
  opt_into all all_SET 1
  if [[ "$all" -eq 1 && -n "$OPT_EXTRA" ]]; then
    usage_error trash "--all does not take item IDs"
  fi
  TRASH_IDS=""
  if [[ "$all" -eq 0 ]]; then
    # Presence check only, not opt_require_sub: restore takes an unbounded
    # ID list ("one or more"), which the helper's bounded MAX cannot express.
    [[ -n "$OPT_EXTRA" ]] || usage_error trash "restore requires at least one ID or --all"
    trash_parse_ids
  else
    # The soft gate both refuses a non-interactive run without --yes and asks
    # the question (unified [y/yes] dialect); it runs before the listing so a
    # refusal still happens before any request goes out. A declined answer
    # logs `aborted` and aborts the run with rc 0.
    ui_confirm_mutation_soft trash \
      "--all requires --yes when not running interactively" \
      "Restore all trashed items? [y/N]: " "aborted" || return 0
  fi
  http_load_context
  if [[ "$all" -eq 1 ]]; then
    TRASH_IDS="$(trash_list_ids)"
    [[ -n "$TRASH_IDS" ]] || {
      printf 'no trashed files\n'
      return 0
    }
  fi
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    if [[ "$all" -eq 1 ]] && ! trash_valid_id "$id"; then
      warn "skipping trash item with unsafe id: $(printable "$id")"
      continue
    fi
    trash_restore_one "$id"
  done <<<"$TRASH_IDS"
  return 0
}

# trash_cmd_rm - DELETE the named items after one confirmation on a terminal
# (--yes skips it; a non-interactive run proceeds as before).
trash_cmd_rm() {
  local id="" count=0
  opt_begin "yes:b" trash "" "$@"
  # Same bounded-MAX note as `trash restore`: one or more IDs, no upper bound.
  [[ -n "$OPT_EXTRA" ]] || usage_error trash "rm requires at least one ID"
  trash_parse_ids
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    count=$((count + 1))
  done <<<"$TRASH_IDS"
  # Soft-asked on a terminal only; a non-interactive run (or SCIEBO_NON_
  # INTERACTIVE) proceeds without a prompt, as before.
  ui_confirm_proceed "Permanently delete ${count} trash item(s)? [y/N]: " || return 0
  http_load_context
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    trash_remove_one "$id"
  done <<<"$TRASH_IDS"
  return 0
}

# trash_cmd_empty - DELETE the trash collection itself after one
# confirmation; the item count comes from a fresh listing before the delete.
trash_cmd_empty() {
  local id="" count=0
  opt_begin "yes:b" trash "" "$@"
  [[ -z "$OPT_EXTRA" ]] || usage_error trash "empty takes no arguments"
  # Gate and prompt in one, before the listing so a non-interactive run still
  # refuses before any request goes out; a declined answer logs `aborted` and
  # aborts the run with rc 0.
  ui_confirm_mutation_soft trash \
    "empty requires --yes when not running interactively" \
    "Empty the trashbin? [y/N]: " "aborted" || return 0
  http_load_context
  TRASH_IDS="$(trash_list_ids)"
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    count=$((count + 1))
  done <<<"$TRASH_IDS"
  nc_dav_request_allow DELETE "$(trash_collection_url)"
  trash_check_mutation DELETE "$(trash_collection_url)"
  printf 'emptied the trashbin (%d item(s))\n' "$count"
  return 0
}

cmd_trash() {
  local sub="${1:-}"
  # Dispatcher-level help exits here, before any dependency loads, so
  # `sciebo trash --help` parses none of them.
  case "$sub" in
    -h | --help)
      usage_trash
      exit 0
      ;;
  esac
  # Run dependencies: the trashbin DAV calls use http/nc_api, and the
  # restore/rm/empty confirmations prompt through the ui gates.
  sciebo_require_module http xml_records
  sciebo_require_module nc_api nc_dav_request_allow
  sciebo_require_module ui ui_confirm_mutation_soft
  case "$sub" in
    list) shift && trash_cmd_list "$@" ;;
    restore) shift && trash_cmd_restore "$@" ;;
    rm) shift && trash_cmd_rm "$@" ;;
    empty) shift && trash_cmd_empty "$@" ;;
    '' | -*) trash_cmd_list "$@" ;;
    *) usage_unknown_sub trash "$sub" ;;
  esac
}
