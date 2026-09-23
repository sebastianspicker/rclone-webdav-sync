#!/bin/bash
# nc_api.sh - Nextcloud WebDAV/OCS domain helpers shared by the server-facing
# commands (file, search, recent, comments, favorites, tags, share, account)
# and the sync/doctor/wizard policy preflights.
#
# Built on lib/http.sh: every helper either fills HTTP_BODY / prints a value or
# dies through http_request. All calls use the authenticated netrc path, so no
# app password ever appears in a command line. Bodies embedded here are fixed
# templates; user input is XML-escaped with nc_xml_escape before insertion.
# The policy preflights merge their e2ee and external-storage facts into one
# Depth-1 PROPFIND (NC_POLICY_PROPFIND_BODY via _nc_policy_probe) so one
# sync entry costs one round trip, not one per fact.

# The DAV/OCS helpers are built on lib/http.sh, so load it on demand (a no-op
# when bin/sciebo already sourced it).
sciebo_require_module http xml_get

# ---------------------------------------------------------------------------
# Fixed request bodies
# ---------------------------------------------------------------------------

# shellcheck disable=SC2034  # NC_* globals are this module's output contract

NC_FILEID_BODY='<?xml version="1.0"?>
<d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
  <d:prop><oc:fileid/></d:prop>
</d:propfind>'

NC_FILE_INFO_BODY='<?xml version="1.0"?>
<d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
  <d:prop>
    <d:resourcetype/>
    <d:getcontentlength/>
    <d:getlastmodified/>
    <d:getetag/>
    <d:owner-id/>
    <d:locktoken/>
    <oc:fileid/>
    <oc:size/>
    <oc:permissions/>
    <oc:favorite/>
    <oc:checksums/>
  </d:prop>
</d:propfind>'

NC_COMMENTS_LIST_BODY='<?xml version="1.0"?>
<d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
  <d:prop>
    <oc:id/>
    <oc:actorId/>
    <oc:actorDisplayName/>
    <oc:message/>
    <oc:creationDateTime/>
    <oc:verb/>
  </d:prop>
</d:propfind>'

NC_TAGS_LIST_BODY='<?xml version="1.0"?>
<d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
  <d:prop>
    <oc:id/>
    <oc:display-name/>
    <oc:user-visible/>
    <oc:user-assignable/>
  </d:prop>
</d:propfind>'

NC_FAVORITES_REPORT_BODY='<?xml version="1.0"?>
<oc:filter-files xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
  <d:prop>
    <d:resourcetype/>
    <d:getcontentlength/>
    <d:getlastmodified/>
    <oc:fileid/>
    <oc:favorite/>
  </d:prop>
  <oc:filter-rules>
    <oc:favorite>1</oc:favorite>
  </oc:filter-rules>
</oc:filter-files>'

# Sync policy preflights: server-side end-to-end encryption and external
# storages mounted into the user's files tree. Both facts are requested in
# ONE Depth-1 PROPFIND (nc_policy_propfind takes both property names), so
# the e2ee and external callbacks of one sync/doctor/wizard entry share a
# single round trip instead of spending one PROPFIND per fact.
NC_POLICY_PROPFIND_BODY='<?xml version="1.0"?>
<d:propfind xmlns:d="DAV:" xmlns:nc="http://nextcloud.org/ns" xmlns:oc="http://owncloud.org/ns">
  <d:prop>
    <d:resourcetype/>
    <nc:is-encrypted/>
    <oc:permissions/>
  </d:prop>
</d:propfind>'

# nc_xml_escape TEXT - escape text for an XML element body, including the
# attribute quote characters. The escaping itself is shared with schedule's
# body-only variant through core's xml_escape_into.
nc_xml_escape() {
  local s=""
  xml_escape_into s "$1" all
  printf '%s' "$s"
}

# nc_path_url SUB - the DAV URL of SUB below the user's files root.
nc_path_url() {
  local enc=""
  [[ -n "$HTTP_FILES_ROOT" ]] || http_remote_info
  enc=${ http_urlencode "$1";}
  printf '%s/%s' "$HTTP_FILES_ROOT" "$enc"
}

# nc_dav_url PATH - the absolute DAV URL of PATH below the DAV root. Used by
# the endpoints that do not live under the files root (comments, systemtags,
# trashbin, versions). PATH is inserted verbatim, so callers with a variable
# segment must percent-encode it themselves.
nc_dav_url() {
  printf '%s/%s' "$HTTP_DAV_ROOT" "$1"
}

# _nc_dav_request MODE METHOD URL [DEPTH] [BODY] [EXTRA_ARGS...] - shared
# implementation of nc_dav_request/nc_dav_request_allow. An empty DEPTH omits
# the header; an empty BODY omits the Content-Type header and the data, so a
# caller that wants an explicit empty body passes `--data-binary ""` as an
# EXTRA_ARG. EXTRA_ARGS are appended verbatim.
_nc_dav_request() {
  local mode="$1" method="$2" url="$3" depth="${4:-}" body="${5:-}"
  local -a args=()
  [[ -z "$depth" ]] || args+=(-H "Depth: ${depth}")
  if [[ -n "$body" ]]; then
    args+=(-H 'Content-Type: application/xml' --data-binary "$body")
  fi
  shift "$(($# < 5 ? $# : 5))"
  if [[ "$mode" == allow ]]; then
    http_request_allow "$method" "$url" ${args[@]+"${args[@]}"} "$@"
  else
    http_request "$method" "$url" ${args[@]+"${args[@]}"} "$@"
  fi
}

# nc_dav_request METHOD URL [DEPTH] [BODY] [EXTRA_ARGS...] - authenticated DAV
# request with HTTP_BODY filled; dies on transport and HTTP errors.
nc_dav_request() {
  _nc_dav_request die "$@"
}

# nc_dav_request_allow METHOD URL [DEPTH] [BODY] [EXTRA_ARGS...] - like
# nc_dav_request but leaves HTTP 4xx/5xx handling to the caller.
nc_dav_request_allow() {
  _nc_dav_request allow "$@"
}

# nc_parse_fileid XML - first numeric <oc:fileid> value, empty when absent.
# Newlines are folded first so a tag split across lines still parses.
nc_parse_fileid() {
  local fileid=""
  fileid="$(xml_get "$1" oc:fileid)"
  is_uint "$fileid" || fileid=""
  printf '%s' "$fileid"
}

# nc_fileid_allow SUB - print the file id of SUB, or nothing when the path
# has no id (missing or not a Nextcloud server). rc 1 when unresolved.
nc_fileid_allow() {
  local sub="$1" fileid=""
  nc_dav_request PROPFIND "$(nc_path_url "$sub")" 0 "$NC_FILEID_BODY"
  fileid="$(nc_parse_fileid "$HTTP_BODY")"
  [[ -n "$fileid" ]] || return 1
  case "$fileid" in *[!0-9]*) return 1 ;; esac
  printf '%s' "$fileid"
}

# nc_fileid SUB - like nc_fileid_allow but dies when SUB cannot be resolved.
nc_fileid() {
  local sub="$1" fileid=""
  fileid="$(nc_fileid_allow "$sub")" || {
    die "cannot resolve a file id for '$(printable "$sub")' (does the path exist?)"
  }
  printf '%s' "$fileid"
}

# nc_file_info SUB - PROPFIND SUB (Depth 0) and fill the NC_FILE_* globals.
nc_file_info() {
  local body="" fields=""
  nc_dav_request PROPFIND "$(nc_path_url "$1")" 0 "$NC_FILE_INFO_BODY"
  body="$HTTP_BODY"
  fields="$(xml_fields "$body" 'oc:fileid' 'oc:size|d:getcontentlength' \
    'd:getlastmodified' 'd:getetag' 'd:owner-id' 'oc:permissions' \
    'oc:favorite' 'oc:checksums' 'd:locktoken')"
  record_split "$fields" NC_FILE_ID NC_FILE_SIZE NC_FILE_MTIME NC_FILE_ETAG \
    NC_FILE_OWNER NC_FILE_PERMISSIONS NC_FILE_FAVORITE NC_FILE_CHECKSUMS \
    NC_FILE_LOCK
  # shellcheck disable=SC2034  # NC_FILE_TYPE is this module's output contract
  case "$body" in
    *'<d:collection'*) NC_FILE_TYPE="dir" ;;
    *) NC_FILE_TYPE="file" ;;
  esac
  [[ -n "$NC_FILE_ID" ]] ||
    die "cannot read file information for '$(printable "$1")' (does the path exist?)"
}

# nc_user_info - fill NC_USER_ID/NC_USER_DISPLAY/NC_USER_EMAIL from the
# cloud/user OCS endpoint.
nc_user_info() {
  local fields=""
  ocs_request GET '/cloud/user'
  fields="$(xml_fields "$HTTP_BODY" id displayname email)"
  record_split "$fields" NC_USER_ID NC_USER_DISPLAY NC_USER_EMAIL
  [[ -n "$NC_USER_ID" ]] || NC_USER_ID="$HTTP_USER"
}

# nc_avatar_url [SIZE] - the authenticated avatar URL for the active user.
nc_avatar_url() {
  [[ -n "$HTTP_BASE" ]] || http_remote_info
  printf '%s/avatar/%s/%s' "$HTTP_BASE" "$(http_urlencode "$HTTP_USER")" "${1:-128}"
}

# nc_avatar_download FILE [SIZE] - download the avatar; dies on failure.
nc_avatar_download() {
  http_download "$(nc_avatar_url "${2:-128}")" "$1"
}

# nc_activity_for_file FILEID [LIMIT] - activity entries for one file id;
# the OCS response is in HTTP_BODY.
nc_activity_for_file() {
  local fileid="$1" limit="${2:-50}"
  ocs_request GET "/apps/activity/api/v2/activity/filter?fileid=${fileid}&limit=${limit}&sort=desc"
}

# nc_comments_list FILEID - comments collection (Depth 1) in HTTP_BODY.
nc_comments_list() {
  nc_dav_request PROPFIND "${HTTP_DAV_ROOT}/comments/files/${1}" 1 "$NC_COMMENTS_LIST_BODY"
}

# nc_comment_add FILEID MESSAGE - create a comment and leave the response in
# HTTP_BODY.
nc_comment_add() {
  local fileid="$1" message="$2" body=""
  body="<?xml version=\"1.0\"?>
<oc:comment xmlns:oc=\"http://owncloud.org/ns\">
  <oc:message>$(nc_xml_escape "$message")</oc:message>
</oc:comment>"
  nc_dav_request POST "${HTTP_DAV_ROOT}/comments/files/${fileid}" "" "$body"
}

# nc_comment_delete FILEID COMMENT_ID - delete one comment.
nc_comment_delete() {
  nc_dav_request DELETE "${HTTP_DAV_ROOT}/comments/files/${1}/${2}" ""
}

# nc_favorite_set SUB on|off - set or clear the oc:favorite property.
nc_favorite_set() {
  local sub="$1" value="$2" body=""
  case "$value" in
    on | 1 | true) value=1 ;;
    off | 0 | false) value=0 ;;
    *) usage_error "${NC_API_COMMAND:-favorite}" "favorite value must be on or off" ;;
  esac
  body="<?xml version=\"1.0\"?>
<d:propertyupdate xmlns:d=\"DAV:\" xmlns:oc=\"http://owncloud.org/ns\">
  <d:set><d:prop><oc:favorite>${value}</oc:favorite></d:prop></d:set>
</d:propertyupdate>"
  nc_dav_request PROPPATCH "$(nc_path_url "$sub")" 0 "$body"
}

# nc_favorites_list - REPORT the favorites collection; HTTP_BODY holds the
# multistatus response.
nc_favorites_list() {
  http_request REPORT "$(nc_path_url "")" -H 'Depth: 1' \
    -H 'Content-Type: application/xml' --data-binary "$NC_FAVORITES_REPORT_BODY"
}

# nc_tags_list - list system tags (Depth 1) in HTTP_BODY.
nc_tags_list() {
  nc_dav_request PROPFIND "${HTTP_DAV_ROOT}/systemtags" 1 "$NC_TAGS_LIST_BODY"
}

# nc_tag_create NAME - create a user-visible, user-assignable system tag.
nc_tag_create() {
  local name="$1" body=""
  body="<?xml version=\"1.0\"?>
<oc:systemtag xmlns:oc=\"http://owncloud.org/ns\">
  <oc:display-name>$(nc_xml_escape "$name")</oc:display-name>
  <oc:user-visible>true</oc:user-visible>
  <oc:user-assignable>true</oc:user-assignable>
</oc:systemtag>"
  nc_dav_request POST "${HTTP_DAV_ROOT}/systemtags" "" "$body"
}

# nc_tag_assign SUB TAG_IDS - replace the system tags of SUB with the
# comma-separated TAG_IDS list. The ids go into an XML body, so the helper
# validates them itself instead of trusting every caller.
nc_tag_assign() {
  local sub="$1" tagids="$2" body=""
  # An empty list is valid (clears the tags); a non-empty list must be
  # numeric ids only.
  [[ -z "$tagids" ]] || comma_ids_valid "$tagids" ||
    die "nc_tag_assign: invalid tag ids '$(printable "$tagids")'"
  body="<?xml version=\"1.0\"?>
<d:propertyupdate xmlns:d=\"DAV:\" xmlns:oc=\"http://owncloud.org/ns\">
  <d:set><d:prop><oc:tags>${tagids}</oc:tags></d:prop></d:set>
</d:propertyupdate>"
  nc_dav_request PROPPATCH "$(nc_path_url "$sub")" 0 "$body"
}

# nc_search TERM [LIMIT] - unified search over the files provider; the OCS
# response is in HTTP_BODY.
nc_search() {
  local term="$1" limit="${2:-20}"
  ocs_request GET "/search/providers/files/search?term=$(http_urlencode "$term")&limit=${limit}" -g
}

# ---------------------------------------------------------------------------
# Remote policy preflights (sync, doctor, folder wizard)
# ---------------------------------------------------------------------------

# shellcheck disable=SC2034  # NC_POLICY_* globals are this module's output contract
NC_POLICY_RECORDS=""
# Per-run memoization. A property the server does not expose is probed once
# (NC_POLICY_PROP_MISSING is keyed by property name), and each probe result is
# reused per remote subpath (NC_POLICY_CACHE is keyed by "PROBE<TAB>SUB", PROBE
# being e2ee or external) so a multi-entry sync with several pull/bisync
# sources does not repeat the same PROPFIND. The combined probe
# (_nc_policy_probe) fills BOTH keys for a subpath from one response, so the
# second public reader of an entry hits memory with zero extra round trips;
# anything else reading NC_POLICY_CACHE keeps the historical "PROBE<TAB>SUB"
# keys. Both caches are safe to keep for the process lifetime because the
# policy probes are read-only.
declare -gA NC_POLICY_PROP_MISSING=()
declare -gA NC_POLICY_CACHE=()
# Per-property flags of the last successful nc_policy_propfind (PROP -> 1
# when the response mentions it at all).
declare -gA NC_POLICY_HAS_PROP=()
# Deferred E2EE child recursion. The combined probe records, per
# "e2ee<TAB>SUB" key, the child folders a bounded one-level walk would visit
# (NC_POLICY_E2EE_CHILDREN) and whether that walk is still owed
# (NC_POLICY_E2EE_PENDING). nc_e2ee_paths runs it on demand; a caller that
# only wanted the external-storage fact (sync's external preflight, the
# collect/wizard engines) never pays for the extra PROPFINDs.
declare -gA NC_POLICY_E2EE_CHILDREN=()
declare -gA NC_POLICY_E2EE_PENDING=()

# _nc_remote_rel_href HREF - decode HREF and make it relative to the remote
# base (REMOTE_BASE): the files root and the base itself are stripped, and a
# trailing slash is removed. Prints nothing and returns 1 for hrefs outside
# the user's files tree or for the base itself.
_nc_remote_rel_href() {
  local href="${1:-}" decoded="" prefix="" rel=""
  [[ -n "$href" ]] || return 1
  # percent_decode keeps multi-byte names intact and never re-interprets
  # literal backslash escapes (unlike printf %b).
  decoded=${ percent_decode "$href";}
  prefix="${HTTP_FILES_ROOT%/}"
  # PROPFIND hrefs are server-absolute paths, while HTTP_FILES_ROOT is a
  # full URL; compare against its path component only.
  case "$prefix" in
    *://*) prefix="/${prefix#*://*/}" ;;
  esac
  case "$decoded" in
    "$prefix"/*) rel="${decoded#"$prefix"/}" ;;
    *) return 1 ;;
  esac
  rel="${rel%/}"
  if [[ -n "${REMOTE_BASE:-}" ]]; then
    case "$rel" in
      "$REMOTE_BASE") rel="" ;;
      "$REMOTE_BASE"/*) rel="${rel#"$REMOTE_BASE"/}" ;;
    esac
  fi
  # Defense in depth: percent_decode already dropped C0/C1 bytes, but a
  # server-controlled href must never inject a TAB or control byte into the
  # TAB-framed policy records.
  rel=${ strip_control_bytes "$rel";}
  [[ -n "$rel" ]] || return 1
  printf '%s' "$rel"
  return 0
}

# nc_policy_propfind URL BODY PROP... - Depth-1 PROPFIND URL with BODY asking
# for every PROP in one request; fills NC_POLICY_RECORDS with one
# "REL<TAB>V1<TAB>...<TAB>VN<TAB>dir|file" line per response (the values in
# PROP order, "-" when a response omits the property, href and values
# control-byte stripped so a server cannot break the TAB framing) and
# NC_POLICY_HAS_PROP (PROP -> 1 when the response mentions it at all). rc 1
# when the request or the HTTP status fails; a missing property is not an
# error. A property the server does not expose is remembered per name
# (NC_POLICY_PROP_MISSING) and never probed again in this process, but the
# request is only skipped when EVERY requested property is already known
# missing: one combined round trip keeps serving whichever fact a server
# does expose. A 2xx response without <d:response> leaves the flags unset
# and unremembered (retryable), like the old single-prop probe.
nc_policy_propfind() {
  local url="$1" body="$2" href="" rel="" tail="" records="" prop=""
  local props_csv="" all_missing=1
  shift 2
  NC_POLICY_RECORDS=""
  NC_POLICY_HAS_PROP=()
  for prop in "$@"; do
    if [[ -z "${NC_POLICY_PROP_MISSING[$prop]:-}" ]]; then
      all_missing=0
      break
    fi
  done
  [[ "$all_missing" -eq 0 ]] || return 0
  http_request_allow PROPFIND "$url" -H 'Depth: 1' \
    -H 'Content-Type: application/xml' --data-binary "$body" || return 1
  http_ok_code_2xx "$HTTP_CODE" || return 1
  for prop in "$@"; do
    case "$HTTP_BODY" in
      *"$prop"*) NC_POLICY_HAS_PROP[$prop]=1 ;;
      *'<d:response'*) NC_POLICY_PROP_MISSING[$prop]=1 ;;
    esac
  done
  # One awk pass extracts the href, one value column per requested property,
  # and the collection flag for every <d:response> block, instead of two
  # xml_get pipelines per record.
  props_csv="$(
    IFS=,
    printf '%s' "$*"
  )"
  records="$(printf '%s' "$HTTP_BODY" | awk -v props="$props_csv" "${_AWK_XML_LIB}"'
    { doc = doc $0 }
    END {
      n = split(props, parr, ",")
      tag = "d:response"
      len = length(tag)
      rest = doc
      while ((pos = index(rest, "<" tag)) > 0) {
        after = substr(rest, pos + 1 + len)
        if (after !~ /^[[:space:]\/>]/) {
          rest = substr(rest, pos + 1)
          continue
        }
        gt = index(after, ">")
        if (gt == 0) break
        head = substr(after, 1, gt - 1)
        if (head ~ /\/[[:space:]]*$/) {
          rest = substr(after, gt + 1)
          continue
        }
        block_body = substr(after, gt + 1)
        cend = index(block_body, "</" tag)
        if (cend == 0) break
        block = substr(block_body, 1, cend - 1)
        rest = substr(block_body, cend + length("</" tag))
        href = xml_extract(block, "d:href")
        gsub(/[[:cntrl:]]/, "", href)
        gsub(/\t/, " ", href)
        printf "%s", href
        for (i = 1; i <= n; i++) {
          v = xml_extract(block, parr[i])
          # An absent value is emitted as "-" so no column is ever empty:
          # bash `read` collapses adjacent IFS delimiters and a mixed
          # response (server answers one requested prop but not the other)
          # would shift the following columns. Neither policy fact can read
          # "-" for data (nc:is-encrypted is 0/1, oc:permissions is
          # letters); xml_extract already folds TABs and strips control
          # bytes, so each value stays one record field.
          if (v == "") v = "-"
          printf "\t%s", v
        }
        kind = (index(block, "<d:collection") > 0) ? "dir" : "file"
        printf "\t%s\n", kind
      }
    }
  ')"
  # The last read variable keeps the remaining TAB-separated fields (the
  # value columns and the dir/file flag) exactly as the awk pass framed
  # them, so NC_POLICY_RECORDS stays "REL<TAB>...<TAB>kind" per response.
  while IFS=$'\t' read -r href tail; do
    [[ -n "$href" ]] || continue
    rel=${ _nc_remote_rel_href "$href" 2>/dev/null;} || continue
    NC_POLICY_RECORDS="${NC_POLICY_RECORDS}${rel}"$'\t'"${tail}"$'\n'
  done <<<"$records"
  NC_POLICY_RECORDS="${NC_POLICY_RECORDS%$'\n'}"
  return 0
}

# _nc_policy_external_slice - print the external-storage paths (the SUB itself
# plus every child whose oc:permissions contains "M") from NC_POLICY_RECORDS,
# the output of the combined probe's nc_policy_propfind. Empty when the server
# does not expose oc:permissions. Forkless-capture friendly.
_nc_policy_external_slice() {
  local out="" rel="" enc="" perm="" kind=""
  local perm_prop='oc:permissions'
  [[ "${NC_POLICY_HAS_PROP[$perm_prop]:-0}" -eq 1 ]] || {
    printf '%s' ""
    return 0
  }
  while IFS=$'\t' read -r rel enc perm kind; do
    [[ -n "$rel" ]] || continue
    case "$perm" in
      *M*) out="${out}${out:+$'\n'}${rel}" ;;
    esac
  done <<<"$NC_POLICY_RECORDS"
  printf '%s' "$out"
  return 0
}

# _nc_policy_e2ee_top KEY SUB_REL - print the Depth-1 E2EE slice (SUB itself
# plus every entry reporting nc:is-encrypted=1) from NC_POLICY_RECORDS, the
# combined probe's output, and record the deferred child walk under KEY:
# NC_POLICY_E2EE_CHILDREN[KEY] gets the child folders (one per line) and
# NC_POLICY_E2EE_PENDING[KEY]=1 marks the walk as owed. The walk is only
# recorded, never run, when nothing at Depth 1 is encrypted and there are at
# most NC_E2EE_RECURSE_LIMIT child folders; nc_e2ee_paths runs it on demand,
# so a caller that reads only the external-storage fact pays nothing extra.
_nc_policy_e2ee_top() {
  local key="$1" sub_rel="$2" out="" found=0 children="" rel="" enc="" perm="" kind=""
  local child="" child_count=0
  local enc_prop='nc:is-encrypted'
  if [[ "${NC_POLICY_HAS_PROP[$enc_prop]:-0}" -eq 1 ]]; then
    while IFS=$'\t' read -r rel enc perm kind; do
      [[ -n "$rel" ]] || continue
      if [[ "$enc" == "1" ]]; then
        out="${out}${out:+$'\n'}${rel}"
        found=$((found + 1))
      elif [[ "$kind" == "dir" && "$rel" != "$sub_rel" ]]; then
        children="${children}${rel}"$'\n'
      fi
    done <<<"$NC_POLICY_RECORDS"
    if [[ "$found" -eq 0 && -n "$children" ]]; then
      while IFS= read -r child; do
        [[ -z "$child" ]] || child_count=$((child_count + 1))
      done <<<"$children"
      if [[ "$child_count" -le "${NC_E2EE_RECURSE_LIMIT:-10}" ]]; then
        NC_POLICY_E2EE_CHILDREN[$key]="$children"
        NC_POLICY_E2EE_PENDING[$key]=1
      fi
    fi
  fi
  printf '%s' "$out"
  return 0
}

# _nc_policy_e2ee_recurse KEY - run the deferred, bounded one-level child walk
# recorded by _nc_policy_e2ee_top and print the encrypted paths it finds (one
# per line, in child order). Each child needs its own Depth-1 PROPFIND: a
# Depth-1 on the parent lists the children but not THEIR properties, and
# Depth: infinity is deliberately not used (unbounded responses, server
# limits). The per-child URL is captured with the forkless ${ ...;} form so the
# loop does not fork a subshell per child.
_nc_policy_e2ee_recurse() {
  local key="$1"
  local children="${NC_POLICY_E2EE_CHILDREN[$key]:-}"
  local out="" child="" child_url="" rel="" enc="" kind=""
  local enc_prop='nc:is-encrypted'
  while IFS= read -r child; do
    [[ -n "$child" ]] || continue
    child_url=${ nc_path_url "${REMOTE_BASE}/${child}";}
    nc_policy_propfind "$child_url" "$NC_POLICY_PROPFIND_BODY" \
      "$enc_prop" || continue
    [[ "${NC_POLICY_HAS_PROP[$enc_prop]:-0}" -eq 1 ]] || continue
    while IFS=$'\t' read -r rel enc kind; do
      [[ -n "$rel" && "$enc" == "1" ]] || continue
      out="${out}${out:+$'\n'}${rel}"
    done <<<"$NC_POLICY_RECORDS"
  done <<<"$children"
  printf '%s' "$out"
  return 0
}

# _nc_policy_probe SUB - the one combined Depth-1 PROPFIND below
# REMOTE_BASE/SUB (NC_POLICY_PROPFIND_BODY asks <nc:is-encrypted> and
# <oc:permissions> together) that parses BOTH facts from the response and
# memoizes each fact's slice in NC_POLICY_CACHE under its own key
# ("e2ee<TAB>SUB" and "external<TAB>SUB"), so whichever public reader runs
# second in the same entry hits memory with zero extra round trips. rc 1
# when the request fails (nothing memoized, like the old per-fact probes);
# otherwise rc 0 with both keys set, including "" slices for properties the
# server does not expose. The E2EE slice's bounded one-level child walk is
# deferred to nc_e2ee_paths (see _nc_policy_e2ee_top), so an external-only
# caller never pays for it.
_nc_policy_probe() {
  local sub="${1:-}" sub_rel="" url=""
  local e2ee_key="e2ee"$'\t'"${1:-}" ext_key="external"$'\t'"${1:-}"
  # Literal property names in locals: shfmt rejects a colon inside a
  # subscript literal, and the names stay readable at the use sites.
  local enc_prop='nc:is-encrypted' perm_prop='oc:permissions'
  url="$(nc_path_url "${REMOTE_BASE}/${sub}")"
  nc_policy_propfind "$url" "$NC_POLICY_PROPFIND_BODY" \
    "$enc_prop" "$perm_prop" || return 1
  sub_rel="${sub%/}"
  # Re-probing a key supersedes any walk an earlier probe recorded for it.
  unset 'NC_POLICY_E2EE_PENDING[$e2ee_key]'
  NC_POLICY_E2EE_CHILDREN[$e2ee_key]=""
  NC_POLICY_CACHE[$ext_key]=${ _nc_policy_external_slice;}
  NC_POLICY_CACHE[$e2ee_key]=${ _nc_policy_e2ee_top "$e2ee_key" "$sub_rel";}
  return 0
}

# nc_e2ee_paths SUB - print the remote paths (relative to REMOTE_BASE) of
# folders that Nextcloud reports as end-to-end encrypted. SUB itself is
# included, so callers can tell whether the entry root is E2EE; see
# _nc_policy_probe for the combined Depth-1 walk. The slice's bounded
# one-level child walk is deferred until here (NC_POLICY_E2EE_PENDING), so a
# caller that only needs nc_external_paths never pays for those PROPFINDs.
# Prints nothing and returns 0 when the server does not expose
# nc:is-encrypted or the probe request fails. Reads the combined probe's
# memoized slice, so when nc_external_paths already probed the same SUB there
# is no second round trip.
nc_e2ee_paths() {
  local key="e2ee"$'\t'"${1:-}" base="" deeper=""
  [[ -n "${REMOTE_BASE:-}" ]] || return 0
  if [[ -z "${NC_POLICY_CACHE[$key]+set}" ]]; then
    _nc_policy_probe "${1:-}" || return 0
  fi
  if [[ -n "${NC_POLICY_E2EE_PENDING[$key]:-}" ]]; then
    unset 'NC_POLICY_E2EE_PENDING[$key]'
    deeper=${ _nc_policy_e2ee_recurse "$key";}
    if [[ -n "$deeper" ]]; then
      base="${NC_POLICY_CACHE[$key]:-}"
      NC_POLICY_CACHE[$key]="${base}${base:+$'\n'}${deeper}"
    fi
  fi
  printf '%s' "${NC_POLICY_CACHE[$key]:-}"
  return 0
}

# nc_external_paths SUB - print the remote paths (relative to REMOTE_BASE)
# whose oc:permissions value contains "M" (mounted external storage),
# including SUB itself. Prints nothing and returns 0 when the server does
# not expose oc:permissions or the probe request fails; the slice comes
# from the same combined probe as nc_e2ee_paths.
nc_external_paths() {
  local key="external"$'\t'"${1:-}"
  [[ -n "${REMOTE_BASE:-}" ]] || return 0
  if [[ -z "${NC_POLICY_CACHE[$key]+set}" ]]; then
    _nc_policy_probe "${1:-}" || return 0
  fi
  printf '%s' "${NC_POLICY_CACHE[$key]:-}"
  return 0
}
