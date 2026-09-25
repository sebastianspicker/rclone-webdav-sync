#!/usr/bin/env bash
# policies.sh - desktop-parity policy engine: invalid names, symlinks,
# checksum/chunk arguments, the delete guard, MOVE_TO_TRASH, case clashes,
# and the E2EE/external-storage preflights.
#
# Platform note: the default macOS/CI filesystem is case-insensitive, so two
# local paths that differ only by case cannot coexist in one tree. The suite
# tries a case-sensitive APFS scratch volume for the real end-to-end
# case-clash runs; when that volume is unavailable it drives
# sync_case_clash_preflight with a stubbed collision list instead (the real
# policy_rename_case_clash is always exercised against files on disk).
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

# shellcheck disable=SC1090,SC1091
source "${PROJ}/lib/commands/sync.sh"

# case_clash.sh allocates its case-scan cache directory lazily on the first
# read/write; prime it in this shell so the cache assertions below and the
# command-substitution scans (which inherit this shell's directory) share one
# directory, exactly as the CLI's main shell does after its first scan.
mkdir -p "${TMP}/policy-cache-prime"
policy_case_clashes "${TMP}/policy-cache-prime" >/dev/null

# The case-sensitive volume (when one was mounted) must be detached before
# the shared feature_cleanup removes the temp tree.
POLY_CS_VOL=""
# shellcheck disable=SC2329  # invoked through the EXIT trap
poly_cleanup() {
  _policy_case_cache_reset 2>/dev/null || true
  # The hardened cache directory is created lazily on the first scan (the
  # prime call above) and kept in place by reset, so remove it here (it is
  # registered for the CLI's own sciebo_temp_cleanup, which the feature
  # harness does not run).
  if [[ -n "${_POLICY_CASE_CACHE_DIR:-}" ]]; then
    rm -rf "$_POLICY_CASE_CACHE_DIR" 2>/dev/null || true
  fi
  if [[ -n "$POLY_CS_VOL" ]]; then
    hdiutil detach "$POLY_CS_VOL" >/dev/null 2>&1 || true
    POLY_CS_VOL=""
  fi
}
trap 'poly_cleanup; feature_cleanup' EXIT

POLY_OUT="${TMP}/policies.out"

# --- policy_invalid_name --------------------------------------------------
while IFS='|' read -r want name; do
  rc=0
  policy_invalid_name "$name" || rc=$?
  expect_rc "invalid_name: ${name:-<empty>}" "$rc" "$want"
done <<'EOF'
0|bad?.txt
0|a<b.txt
0|a>b.txt
0|a:b.txt
0|a"b.txt
0|a|b.txt
0|a*b.txt
0|open[1].txt
0|close].txt
0|trail.
0|trail 
0|CON
0|con.txt
0|CoN.log
0|COM1
0|com9.tar.gz
0|LPT1
0|lpt9
0|NUL
0|aux.txt
1|ok.txt
1|normal
1|console.txt
1|com0
1|com10
1|COM
1|lpt10
1|a.b
1|.hidden
1|
EOF

# --- policy_name_exclude_args ---------------------------------------------
# The argument helpers append to the argv array named by their first
# argument (the nameref out-param form, no subshell); policy_args_join prints
# such an array one element per line for the assertions below.
policy_args_join() {
  # shellcheck disable=SC2178  # nameref to an argv array
  local -n _paj_ref="$1"
  printf '%s\n' "${_paj_ref[@]}"
}

_pa_args=()
INVALID_NAME_POLICY=exclude policy_name_exclude_args _pa_args
invalid_args="$(policy_args_join _pa_args)"
expect_contains "name_exclude_args: invalid characters" "$invalid_args" '*[<>:"|?*]*'
expect_contains "name_exclude_args: open bracket" "$invalid_args" '*\[*'
expect_contains "name_exclude_args: close bracket" "$invalid_args" '*\]*'
expect_contains "name_exclude_args: trailing dot" "$invalid_args" $'*.\n'
expect_contains "name_exclude_args: trailing space" "$invalid_args" $'*[ ]\n'
expect_contains "name_exclude_args: reserved CON literal" "$invalid_args" 'CON'
expect_contains "name_exclude_args: reserved CON with extension" "$invalid_args" 'CON.*'
expect_contains "name_exclude_args: reserved name case classes" "$invalid_args" '[cC][oO][nN].*'
expect_contains "name_exclude_args: reserved COM range" "$invalid_args" '[cC][oO][mM][1-9]'
expect_contains "name_exclude_args: reserved LPT range" "$invalid_args" '[lL][pP][tT][1-9].*'
_pa_args=()
INVALID_NAME_POLICY=warn policy_name_exclude_args _pa_args
expect_eq "name_exclude_args: warn policy has none" "" "$(policy_args_join _pa_args)"
_pa_args=()
INVALID_NAME_POLICY=allow policy_name_exclude_args _pa_args
expect_eq "name_exclude_args: allow policy has none" "" "$(policy_args_join _pa_args)"
_pa_args=()
policy_name_exclude_args _pa_args
expect_eq "name_exclude_args: unset policy has none" "" "$(policy_args_join _pa_args)"

# --- policy_symlink_args / policy_checksum_args ---------------------------
_pa_args=()
SYMLINK_POLICY=skip policy_symlink_args _pa_args
expect_eq "symlink_args: skip" "--skip-links" "$(policy_args_join _pa_args)"
_pa_args=()
SYMLINK_POLICY=follow policy_symlink_args _pa_args
expect_eq "symlink_args: follow" "--copy-links" "$(policy_args_join _pa_args)"
_pa_args=()
SYMLINK_POLICY=translate policy_symlink_args _pa_args
expect_eq "symlink_args: translate" "--links" "$(policy_args_join _pa_args)"
_pa_args=()
policy_symlink_args _pa_args
expect_eq "symlink_args: unset has none" "" "$(policy_args_join _pa_args)"
_pa_args=()
CHECKSUM=0 policy_checksum_args _pa_args sync
expect_eq "checksum_args: off" "" "$(policy_args_join _pa_args)"
_pa_args=()
CHECKSUM=1 policy_checksum_args _pa_args sync
expect_eq "checksum_args: sync" "--checksum" "$(policy_args_join _pa_args)"
_pa_args=()
CHECKSUM=1 policy_checksum_args _pa_args pull
expect_eq "checksum_args: pull" "--checksum" "$(policy_args_join _pa_args)"
_pa_args=()
CHECKSUM=1 policy_checksum_args _pa_args bisync
expect_eq "checksum_args: bisync compare pair" $'--compare\nsize,modtime,checksum' "$(policy_args_join _pa_args)"

# --- policy_trash_args ----------------------------------------------------
_pa_args=()
MOVE_TO_TRASH=0 policy_trash_args _pa_args pull
expect_eq "trash_args: off" "" "$(policy_args_join _pa_args)"
_pa_args=()
MOVE_TO_TRASH=1 policy_trash_args _pa_args sync
expect_eq "trash_args: sync is upload-only" "" "$(policy_args_join _pa_args)"
_pa_args=()
MOVE_TO_TRASH=1 BACKUP_DIR=/backups policy_trash_args _pa_args pull
expect_eq "trash_args: pull with BACKUP_DIR" $'--backup-dir\n/backups' \
  "$(policy_args_join _pa_args)"
_pa_args=()
MOVE_TO_TRASH=1 BACKUP_DIR="" LOCAL_TRASH_DIR=/trash policy_trash_args _pa_args pull
expect_eq "trash_args: pull with LOCAL_TRASH_DIR" $'--backup-dir\n/trash' \
  "$(policy_args_join _pa_args)"
_pa_args=()
MOVE_TO_TRASH=1 BACKUP_DIR=/backups policy_trash_args _pa_args bisync
expect_eq "trash_args: bisync with BACKUP_DIR" $'--backup-dir\n/backups' \
  "$(policy_args_join _pa_args)"

# --- policy_delete_guard_args / policy_delete_guard_hit -------------------
_pa_args=()
ASK_DELETE=0 policy_delete_guard_args _pa_args
expect_eq "delete_guard_args: ASK_DELETE=0" "" "$(policy_args_join _pa_args)"
_pa_args=()
ASK_DELETE=1 MAX_DELETE=5 policy_delete_guard_args _pa_args
expect_eq "delete_guard_args: explicit MAX_DELETE" "" "$(policy_args_join _pa_args)"
_pa_args=()
ASK_DELETE=1 MAX_DELETE=-1 policy_delete_guard_args _pa_args
expect_eq "delete_guard_args: default threshold" $'--max-delete\n100' \
  "$(policy_args_join _pa_args)"
_pa_args=()
ASK_DELETE=1 MAX_DELETE=-1 DELETE_FILES_THRESHOLD=7 policy_delete_guard_args _pa_args
expect_eq "delete_guard_args: custom threshold" $'--max-delete\n7' \
  "$(policy_args_join _pa_args)"
_pa_args=()
policy_delete_guard_args _pa_args
expect_eq "delete_guard_args: unset ASK_DELETE" "" "$(policy_args_join _pa_args)"
hit_log="${TMP}/policy-guard.log"
printf '%s\n' '2026/09/20 10:00:00 ERROR : b.txt: Got fatal error on delete: --max-delete threshold reached' >"$hit_log"
rc=0
policy_delete_guard_hit "$hit_log" || rc=$?
expect_rc "delete_guard_hit: threshold reached" "$rc" 0
printf '%s\n' '2026/09/20 10:00:00 ERROR : Deletions stopped due to --max-delete' >"$hit_log"
rc=0
policy_delete_guard_hit "$hit_log" || rc=$?
expect_rc "delete_guard_hit: older wording" "$rc" 0
printf '%s\n' '2026/09/20 10:00:00 NOTICE: nothing to see' >"$hit_log"
rc=0
policy_delete_guard_hit "$hit_log" || rc=$?
expect_rc "delete_guard_hit: clean log" "$rc" 1
rc=0
policy_delete_guard_hit "${TMP}/no-such-guard.log" || rc=$?
expect_rc "delete_guard_hit: missing log" "$rc" 1

# --- policy_chunk_size ----------------------------------------------------
expect_eq "chunk_size: empty stays empty" "" "$(policy_chunk_size '')"
expect_eq "chunk_size: no bounds" "100Mi" "$(policy_chunk_size 100Mi)"
expect_eq "chunk_size: min clamp" "200Mi" "$(MIN_CHUNK_SIZE=200Mi policy_chunk_size 100Mi)"
expect_eq "chunk_size: max clamp" "10Mi" "$(MAX_CHUNK_SIZE=10Mi policy_chunk_size 100Mi)"
expect_eq "chunk_size: within bounds" "3Mi" "$(MIN_CHUNK_SIZE=1Mi MAX_CHUNK_SIZE=5Mi policy_chunk_size 3Mi)"
expect_eq "chunk_size: below min" "1Mi" "$(MIN_CHUNK_SIZE=1Mi MAX_CHUNK_SIZE=5Mi policy_chunk_size 100Ki)"
expect_eq "chunk_size: above max" "5Mi" "$(MIN_CHUNK_SIZE=1Mi MAX_CHUNK_SIZE=5Mi policy_chunk_size 100Mi)"
expect_eq "chunk_size: unparseable stays" "nonsense" "$(MIN_CHUNK_SIZE=1Mi MAX_CHUNK_SIZE=5Mi policy_chunk_size nonsense)"

# --- policy_case_clashes: read-only scan and rename -----------------------
clash_plain="${TMP}/policy-plain"
mkdir -p "${clash_plain}/a" "${clash_plain}/b"
printf '1' >"${clash_plain}/a/x.txt"
printf '2' >"${clash_plain}/b/y.txt"
expect_eq "case_clashes: no collisions" "" "$(policy_case_clashes "$clash_plain")"
expect_eq "case_clashes: missing dir" "" "$(policy_case_clashes "${TMP}/no-such-dir")"

# --- policy_case_clashes: hardened cache directory ------------------------
# The scan cache is a random mktemp -d directory (never the predictable
# ${TMPDIR}/sciebo-case-cache.$$ form a shared-TMPDIR attacker could
# pre-seed), and it is private to the user.
case_cache_base="$(basename "${_POLICY_CASE_CACHE_DIR:-}")"
if [[ "$case_cache_base" =~ ^sciebo-case-cache\.[A-Za-z0-9]{6,}$ ]]; then
  pass "case_cache: directory name has a random mktemp suffix"
else
  fail "case_cache: directory name has a random mktemp suffix" "got [$case_cache_base]"
fi
if [[ -d "${_POLICY_CASE_CACHE_DIR:-}" ]]; then
  pass "case_cache: cache directory exists"
else
  fail "case_cache: cache directory exists" "missing ${_POLICY_CASE_CACHE_DIR:-}"
fi
rc=0
_policy_case_cache_ok "$_POLICY_CASE_CACHE_DIR" || rc=$?
expect_rc "case_cache: own private directory is usable" "$rc" 0

# --- policy_case_clashes: per-process memoization -------------------------
# The scan runs in the command-substitution subshells the sync/doctor callers
# use, so the cache is on disk keyed by the scanned directory: a repeated scan
# of one directory in a run is a file read, not another recursive walk. find is
# wrapped so the walks are counted across those subshells.
memo_dir="${TMP}/policy-memo"
mkdir -p "${memo_dir}/sub"
printf 'x' >"${memo_dir}/sub/a.txt"
memo_find_log="${TMP}/policy-memo-find.log"
: >"$memo_find_log"
memo_find_calls() { wc -l <"$memo_find_log" | tr -d ' '; }
# shellcheck disable=SC2329  # inherited by the scan subshells; reset with unset -f
find() {
  printf 'walk\n' >>"$memo_find_log"
  command find "$@"
}
_policy_case_cache_reset
expect_eq "case_cache: first scan is a miss" "" "$(policy_case_clashes "$memo_dir")"
expect_eq "case_cache: first scan walks once" "1" "$(memo_find_calls)"
expect_eq "case_cache: repeat scan reuses the result" "" "$(policy_case_clashes "$memo_dir")"
expect_eq "case_cache: repeat scan does not walk" "1" "$(memo_find_calls)"
# The scan limit is part of the key, so a different bound is a fresh walk.
POLICY_CASE_SCAN_LIMIT=1 policy_case_clashes "$memo_dir" >/dev/null
expect_eq "case_cache: a different limit scans" "2" "$(memo_find_calls)"
# A world-writable directory (a plausible shared-TMPDIR pre-seed) is refused:
# the cache is disabled and each scan falls back to a direct walk without
# writing anything into the untrusted path.
unsafe_cache="${TMP}/policy-unsafe-cache"
mkdir -p "$unsafe_cache"
chmod 0777 "$unsafe_cache"
rc=0
_policy_case_cache_ok "$unsafe_cache" || rc=$?
expect_rc "case_cache: world-writable directory is refused" "$rc" 1
saved_cache_dir="$_POLICY_CASE_CACHE_DIR"
_POLICY_CASE_CACHE_DIR="$unsafe_cache"
policy_case_clashes "$memo_dir" >/dev/null
expect_eq "case_cache: refused directory falls back to a walk" "3" "$(memo_find_calls)"
policy_case_clashes "$memo_dir" >/dev/null
expect_eq "case_cache: refused directory keeps scanning" "4" "$(memo_find_calls)"
expect_eq "case_cache: refused directory stays empty" "" "$(ls -A "$unsafe_cache")"
_POLICY_CASE_CACHE_DIR="$saved_cache_dir"
unset -f find
_policy_case_cache_reset

rename_dir="${TMP}/policy-rename"
mkdir -p "${rename_dir}/sub"
printf 'x' >"${rename_dir}/File.txt"
expect_eq "rename_case_clash: suffix and extension" "File (case conflict).txt" \
  "$(policy_rename_case_clash "$rename_dir" File.txt)"
expect_file "rename_case_clash: file renamed" "${rename_dir}/File (case conflict).txt"
expect_no_file "rename_case_clash: original gone" "${rename_dir}/File.txt"
printf 'y' >"${rename_dir}/File.txt"
expect_eq "rename_case_clash: free-name search" "File (case conflict)-2.txt" \
  "$(policy_rename_case_clash "$rename_dir" File.txt)"
printf 'z' >"${rename_dir}/sub/note.md"
expect_eq "rename_case_clash: nested relative path" "sub/note (case conflict).md" \
  "$(policy_rename_case_clash "$rename_dir" sub/note.md)"
rc=0
policy_rename_case_clash "$rename_dir" "../escape" >/dev/null 2>&1 || rc=$?
expect_rc "rename_case_clash: unsafe path refused" "$rc" 1

# --- policy_case_clashes_remote / policy_remote_case_exclude --------------
# The remote listing primitive is stubbed so the ASCII pairing, ordering, and
# bounding are deterministic without a live remote.
RCR_PATHS=""
# shellcheck disable=SC2329  # invoked indirectly by policy_case_clashes_remote
rclone_lsf_paths() { printf '%s\n' "$RCR_PATHS"; }

# rcr_pairs LISTING [LIMIT] - run the remote scan against LISTING.
rcr_pairs() {
  RCR_PATHS="$1"
  POLICY_CASE_SCAN_LIMIT="${2:-50000}" policy_case_clashes_remote "testremote:backup/probe"
}
expect_eq "remote_case: pair ordering" $'Dir/File.txt\tDir/file.txt' \
  "$(rcr_pairs $'Dir/File.txt\nDir/file.txt\nother.txt')"
expect_eq "remote_case: equal keys pair adjacently" $'A.TXT\tA.txt\nA.txt\ta.txt' \
  "$(rcr_pairs $'A.txt\na.txt\nA.TXT')"
expect_eq "remote_case: empty listing" "" "$(rcr_pairs '')"
expect_eq "remote_case: no collisions" "" "$(rcr_pairs $'a/x.txt\nb/y.txt')"
expect_eq "remote_case: missing spec" "" "$(policy_case_clashes_remote '')"
# LC_ALL=C tolower leaves non-ASCII bytes alone, so an accented uppercase and
# lowercase letter are not the same cluster.
expect_eq "remote_case: multi-byte bytes untouched" "" \
  "$(rcr_pairs $'CAF\xc3\x89.txt\ncaf\xc3\xa9.txt')"
# The limit is applied before the sort, so only the first two paths count.
expect_eq "remote_case: bounded by the scan limit" $'A.txt\ta.txt' \
  "$(rcr_pairs $'a.txt\nA.txt\nb.txt\nB.txt' 2)"

expect_eq "remote_exclude: file keeps the anchored pattern" "/Dir/file.txt" \
  "$(policy_remote_case_exclude 'Dir/file.txt')"
expect_eq "remote_exclude: directory gets the subtree suffix" "/Dir/Sub/**" \
  "$(policy_remote_case_exclude 'Dir/Sub/')"
expect_eq "remote_exclude: glob metacharacters escaped" '/a\*b.txt' \
  "$(policy_remote_case_exclude 'a*b.txt')"
expect_eq "remote_exclude: directory glob escaped" '/weird\[1\]/**' \
  "$(policy_remote_case_exclude 'weird[1]/')"
expect_eq "remote_exclude: empty path" "" "$(policy_remote_case_exclude '')"

# --- nc_e2ee_paths / nc_external_paths (stubbed HTTP transport) -----------
NC_STUB_DIR="${TMP}/nc-stub"
mkdir -p "$NC_STUB_DIR"
NC_STUB_BODY="${NC_STUB_DIR}/default.xml"
NC_STUB_URLS=""
# The request log is a file so calls in the subshells a command substitution
# would create are still counted.
NC_STUB_REQUESTS_LOG="${NC_STUB_DIR}/requests.log"
: >"$NC_STUB_REQUESTS_LOG"
# shellcheck disable=SC2329  # invoked indirectly by nc_api
http_request_allow() {
  local url="$2" body_file="$NC_STUB_BODY" suffix="" file=""
  printf '%s\n' "$url" >>"$NC_STUB_REQUESTS_LOG"
  HTTP_CODE=207
  while IFS='|' read -r suffix file; do
    [[ -n "$suffix" ]] || continue
    case "$url" in
      *"$suffix") body_file="$file" ;;
    esac
  done <<<"$NC_STUB_URLS"
  HTTP_BODY="$(cat "$body_file" 2>/dev/null || true)"
  return 0
}
HTTP_BASE="http://nc.example"
# shellcheck disable=SC2034  # read by nc_api's URL builders
HTTP_FILES_ROOT="http://nc.example/remote.php/dav/files/alice"
REMOTE_BASE=backup

cat >"$NC_STUB_BODY" <<'XML'
<d:multistatus xmlns:d="DAV:" xmlns:nc="http://nextcloud.org/ns">
  <d:response>
    <d:href>/remote.php/dav/files/alice/backup/notes/</d:href>
    <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype><nc:is-encrypted>0</nc:is-encrypted></d:prop></d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/dav/files/alice/backup/notes/secret/</d:href>
    <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype><nc:is-encrypted>1</nc:is-encrypted></d:prop></d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/dav/files/alice/backup/notes/plain.txt</d:href>
    <d:propstat><d:prop><d:resourcetype/><nc:is-encrypted>0</nc:is-encrypted></d:prop></d:propstat>
  </d:response>
</d:multistatus>
XML
expect_eq "e2ee_paths: encrypted subfolder" "notes/secret" "$(nc_e2ee_paths notes)"

cat >"$NC_STUB_BODY" <<'XML'
<d:multistatus xmlns:d="DAV:" xmlns:nc="http://nextcloud.org/ns">
  <d:response>
    <d:href>/remote.php/dav/files/alice/backup/notes/</d:href>
    <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype><nc:is-encrypted>1</nc:is-encrypted></d:prop></d:propstat>
  </d:response>
</d:multistatus>
XML
expect_eq "e2ee_paths: encrypted root reported" "notes" "$(nc_e2ee_paths notes)"

cat >"$NC_STUB_BODY" <<'XML'
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/remote.php/dav/files/alice/backup/notes/</d:href>
    <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat>
  </d:response>
</d:multistatus>
XML
rc=0
out="$(nc_e2ee_paths notes)" || rc=$?
expect_rc "e2ee_paths: missing property rc 0" "$rc" 0
expect_eq "e2ee_paths: missing property is silent" "" "$out"

# One more level is probed when the property is exposed and nothing at
# depth 1 is encrypted; a percent-encoded href is decoded for the path.
cat >"$NC_STUB_DIR/notes.xml" <<'XML'
<d:multistatus xmlns:d="DAV:" xmlns:nc="http://nextcloud.org/ns">
  <d:response>
    <d:href>/remote.php/dav/files/alice/backup/notes/</d:href>
    <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype><nc:is-encrypted>0</nc:is-encrypted></d:prop></d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/dav/files/alice/backup/notes/child/</d:href>
    <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype><nc:is-encrypted>0</nc:is-encrypted></d:prop></d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/dav/files/alice/backup/notes/my%20file.txt</d:href>
    <d:propstat><d:prop><d:resourcetype/><nc:is-encrypted>0</nc:is-encrypted></d:prop></d:propstat>
  </d:response>
</d:multistatus>
XML
cat >"$NC_STUB_DIR/notes-child.xml" <<'XML'
<d:multistatus xmlns:d="DAV:" xmlns:nc="http://nextcloud.org/ns">
  <d:response>
    <d:href>/remote.php/dav/files/alice/backup/notes/child/</d:href>
    <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype><nc:is-encrypted>0</nc:is-encrypted></d:prop></d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/dav/files/alice/backup/notes/child/deep/</d:href>
    <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype><nc:is-encrypted>1</nc:is-encrypted></d:prop></d:propstat>
  </d:response>
</d:multistatus>
XML
NC_STUB_BODY="$NC_STUB_DIR/notes.xml"
NC_STUB_URLS="notes/child|$NC_STUB_DIR/notes-child.xml"
expect_eq "e2ee_paths: one level deeper when cheap" "notes/child/deep" "$(nc_e2ee_paths notes)"
NC_STUB_URLS=""

# oc:permissions with M marks a mounted external storage.
cat >"$NC_STUB_BODY" <<'XML'
<d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
  <d:response>
    <d:href>/remote.php/dav/files/alice/backup/notes/</d:href>
    <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype><oc:permissions>RGDNVW</oc:permissions></d:prop></d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/dav/files/alice/backup/notes/mounted/</d:href>
    <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype><oc:permissions>MKG</oc:permissions></d:prop></d:propstat>
  </d:response>
</d:multistatus>
XML
expect_eq "external_paths: mounted subfolder" "notes/mounted" "$(nc_external_paths notes)"
NC_STUB_BODY="$NC_STUB_DIR/default.xml"

# The per-run probe caches (NC_POLICY_CACHE / NC_POLICY_PROP_MISSING) must
# survive the forkless ${ ...;} capture policy.sh uses, so a server that
# exposes neither property is probed once per run, not once per entry. Two
# engine calls share the shell, so only the first reaches the transport.
# shellcheck disable=SC2329  # shadowed for the engine cache calls only
remote_is_nextcloud() { return 0; }
NC_PROBE_CACHE_EXCLUDES=()
# Reference the engine's caches and argv array by name so the resets below
# read as uses to the linter.
: "${NC_POLICY_CACHE[@]}" "${NC_POLICY_PROP_MISSING[@]}" "${NC_PROBE_CACHE_EXCLUDES[@]}"

nc_probe_requests() { wc -l <"$NC_STUB_REQUESTS_LOG" | tr -d ' '; }

: >"$NC_STUB_REQUESTS_LOG"
NC_POLICY_CACHE=()
NC_POLICY_PROP_MISSING=()
POLICY_REMOTE_STYLE=wizard POLICY_REMOTE_SCOPE_SEARCH=1 POLICY_REMOTE_CONFIRM=""
POLICY_REMOTE_SINK=: POLICY_REMOTE_NAME=probe POLICY_REMOTE_ROOT=notes
policy_remote_paths_apply exclude nc_e2ee_paths e2ee NC_PROBE_CACHE_EXCLUDES POLICY_REMOTE_COUNT || true
policy_remote_paths_apply exclude nc_e2ee_paths e2ee NC_PROBE_CACHE_EXCLUDES POLICY_REMOTE_COUNT || true
expect_eq "probe cache: wizard probes a missing property once per run" "1" "$(nc_probe_requests)"

: >"$NC_STUB_REQUESTS_LOG"
NC_POLICY_CACHE=()
NC_POLICY_PROP_MISSING=()
POLICY_REMOTE_STYLE=apply POLICY_REMOTE_SCOPE_SEARCH=0 POLICY_REMOTE_ROOT=notes
policy_remote_paths_apply exclude nc_e2ee_paths e2ee NC_PROBE_CACHE_EXCLUDES POLICY_REMOTE_COUNT || true
policy_remote_paths_apply exclude nc_e2ee_paths e2ee NC_PROBE_CACHE_EXCLUDES POLICY_REMOTE_COUNT || true
expect_eq "probe cache: apply probes a missing property once per run" "1" "$(nc_probe_requests)"

: >"$NC_STUB_REQUESTS_LOG"
NC_POLICY_CACHE=()
NC_POLICY_PROP_MISSING=()
POLICY_REMOTE_STYLE=collect POLICY_REMOTE_ROOT=notes
policy_remote_paths_apply allow nc_external_paths external NC_PROBE_CACHE_EXCLUDES POLICY_REMOTE_COUNT
policy_remote_paths_apply allow nc_external_paths external NC_PROBE_CACHE_EXCLUDES POLICY_REMOTE_COUNT
expect_eq "probe cache: collect probes a missing property once per run" "1" "$(nc_probe_requests)"

# The bounded E2EE child walk is deferred until nc_e2ee_paths actually needs
# it: an external-only read shares the combined probe (one request) but must
# not trigger the child PROPFINDs. Both calls use the forkless ${ ...;} form
# so they run in this shell and share the deferred state.
cat >"$NC_STUB_DIR/lazy-parent.xml" <<'XML'
<d:multistatus xmlns:d="DAV:" xmlns:nc="http://nextcloud.org/ns">
  <d:response>
    <d:href>/remote.php/dav/files/alice/backup/notes/</d:href>
    <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype><nc:is-encrypted>0</nc:is-encrypted></d:prop></d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/dav/files/alice/backup/notes/child/</d:href>
    <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype><nc:is-encrypted>0</nc:is-encrypted></d:prop></d:propstat>
  </d:response>
</d:multistatus>
XML
cat >"$NC_STUB_DIR/lazy-child.xml" <<'XML'
<d:multistatus xmlns:d="DAV:" xmlns:nc="http://nextcloud.org/ns">
  <d:response>
    <d:href>/remote.php/dav/files/alice/backup/notes/child/</d:href>
    <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype><nc:is-encrypted>0</nc:is-encrypted></d:prop></d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/dav/files/alice/backup/notes/child/deep/</d:href>
    <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype><nc:is-encrypted>1</nc:is-encrypted></d:prop></d:propstat>
  </d:response>
</d:multistatus>
XML
: >"$NC_STUB_REQUESTS_LOG"
NC_POLICY_CACHE=()
NC_POLICY_PROP_MISSING=()
# shellcheck disable=SC2034  # reset for the deferred-walk assertions below
NC_POLICY_E2EE_PENDING=()
# shellcheck disable=SC2034  # reset for the deferred-walk assertions below
NC_POLICY_E2EE_CHILDREN=()
NC_STUB_BODY="$NC_STUB_DIR/lazy-parent.xml"
NC_STUB_URLS="notes/child|$NC_STUB_DIR/lazy-child.xml"
external_out=${ nc_external_paths notes;}
expect_eq "lazy e2ee: external slice empty for a permissions-less body" "" "$external_out"
expect_eq "lazy e2ee: external-only read issues no child walk" "1" "$(nc_probe_requests)"
e2ee_out=${ nc_e2ee_paths notes;}
expect_eq "lazy e2ee: e2ee read completes the deferred walk" "notes/child/deep" "$e2ee_out"
expect_eq "lazy e2ee: the deferred walk costs one more request" "2" "$(nc_probe_requests)"
NC_STUB_URLS=""
NC_STUB_BODY="$NC_STUB_DIR/default.xml"
unset POLICY_REMOTE_STYLE POLICY_REMOTE_SCOPE_SEARCH POLICY_REMOTE_CONFIRM \
  POLICY_REMOTE_SINK POLICY_REMOTE_NAME POLICY_REMOTE_ROOT

# --- sync preflights: E2EE, external storage, case clash ------------------
# The nc helpers and the Nextcloud probe are stubbed so the verdicts and the
# argv changes can be asserted without a server; the real HTTP parsing is
# covered above.
# shellcheck disable=SC2329  # invoked indirectly by the sync preflights
nc_e2ee_paths() { printf '%s\n' "$NC_STUB_E2EE_PATHS"; }
# shellcheck disable=SC2329  # invoked indirectly by the sync preflights
nc_external_paths() { printf '%s\n' "$NC_STUB_EXTERNAL_PATHS"; }
# shellcheck disable=SC2329  # invoked indirectly by the sync preflights
remote_is_nextcloud() { return 0; }

# poly_preflight CMD... - run CMD with combined output in POLY_OUT and its
# rc in POLY_RC; globals the command sets stay visible.
POLY_RC=0
poly_preflight() {
  : >"$POLY_OUT"
  POLY_RC=0
  "$@" >"$POLY_OUT" 2>&1 || POLY_RC=$?
}

# shellcheck disable=SC2034  # read by the sync preflights
ENTRY_NAME=probe ENTRY_REMOTE=notes
ENTRY_LOCAL="${TMP}/probe-local"
mkdir -p "$ENTRY_LOCAL"
export ENTRY_MODE=pull E2EE_POLICY=exclude
NC_STUB_E2EE_PATHS=$'notes/secret\nnotes/other'
SYNC_POLICY_EXCLUDES=()
poly_preflight sync_e2ee_preflight
expect_rc "e2ee_preflight: subfolder proceeds" "$POLY_RC" 0
expect_eq "e2ee_preflight: subfolder excluded" "/secret/**" "${SYNC_POLICY_EXCLUDES[0]:-}"
expect_eq "e2ee_preflight: second subfolder excluded" "/other/**" "${SYNC_POLICY_EXCLUDES[1]:-}"
expect_contains "e2ee_preflight: subfolder warned" "$(cat "$POLY_OUT")" "end-to-end encrypted"
NC_STUB_E2EE_PATHS="notes"
SYNC_POLICY_EXCLUDES=()
poly_preflight sync_e2ee_preflight
expect_rc "e2ee_preflight: root skipped" "$POLY_RC" 2
expect_contains "e2ee_preflight: root reason" "${SYNC_ENTRY_REASON:-}" "end-to-end encrypted"
export E2EE_POLICY=warn
NC_STUB_E2EE_PATHS="notes/secret"
SYNC_POLICY_EXCLUDES=()
poly_preflight sync_e2ee_preflight
expect_rc "e2ee_preflight: warn proceeds" "$POLY_RC" 0
expect_eq "e2ee_preflight: warn excludes nothing" "" "${SYNC_POLICY_EXCLUDES[0]:-}"
export E2EE_POLICY=allow
poly_preflight sync_e2ee_preflight
expect_rc "e2ee_preflight: allow no-op" "$POLY_RC" 0
export ENTRY_MODE=sync E2EE_POLICY=exclude
poly_preflight sync_e2ee_preflight
expect_rc "e2ee_preflight: upload entries skip the check" "$POLY_RC" 0
unset E2EE_POLICY

export ENTRY_MODE=pull EXTERNAL_STORAGE_POLICY=skip
NC_STUB_EXTERNAL_PATHS="notes"
poly_preflight sync_external_preflight </dev/null
expect_rc "external_preflight: skip root" "$POLY_RC" 2
expect_contains "external_preflight: skip reason" "${SYNC_ENTRY_REASON:-}" "external storage"
export EXTERNAL_STORAGE_POLICY=warn
poly_preflight sync_external_preflight </dev/null
expect_rc "external_preflight: warn proceeds" "$POLY_RC" 0
expect_contains "external_preflight: warn output" "$(cat "$POLY_OUT")" "external storage"
export EXTERNAL_STORAGE_POLICY=ask
poly_preflight sync_external_preflight </dev/null
expect_rc "external_preflight: ask without TTY skips" "$POLY_RC" 2
NC_STUB_EXTERNAL_PATHS="notes/mounted"
export EXTERNAL_STORAGE_POLICY=skip
poly_preflight sync_external_preflight </dev/null
expect_rc "external_preflight: subfolder only warns" "$POLY_RC" 0
expect_contains "external_preflight: subfolder warning" "$(cat "$POLY_OUT")" "subfolder"
export EXTERNAL_STORAGE_POLICY=allow
NC_STUB_EXTERNAL_PATHS="notes"
poly_preflight sync_external_preflight </dev/null
expect_rc "external_preflight: allow no-op" "$POLY_RC" 0
unset EXTERNAL_STORAGE_POLICY

# --- shared remote-path engine -------------------------------------------
# policy_remote_paths_apply is the one gate behind the sync/doctor/wizard
# copies. These focused tests pin its contract directly: allow and probe
# short-circuits, the root-vs-subfolder distinction, glob-escaped recursive
# excludes, unsafe subpaths, and the wizard scope lookup.
ENGINE_PATHS=""
# shellcheck disable=SC2329  # invoked indirectly by the engine
engine_paths() { printf '%s\n' "$ENGINE_PATHS"; }

# engine_apply KIND POLICY ROOT PATHS - run the engine in apply style with a
# stub probe; print "rc=N count=N reason=N" then one "exclude=PATTERN" line.
# (A subshell, so the reason is echoed rather than read back.)
engine_apply() {
  local kind="$1" policy="$2" root="$3" paths="$4" rc=0 i=0
  ENGINE_PATHS="$paths"
  POLICY_REMOTE_ROOT="$root"
  POLICY_REMOTE_NAME=probe
  POLICY_REMOTE_STYLE=apply
  POLICY_REMOTE_SCOPE_SEARCH=0
  POLICY_REMOTE_CONFIRM=""
  POLICY_REMOTE_SINK=:
  # The engine reads these by name; reference them so shellcheck sees the use.
  : "$POLICY_REMOTE_ROOT" "$POLICY_REMOTE_NAME" "$POLICY_REMOTE_STYLE" \
    "$POLICY_REMOTE_SCOPE_SEARCH" "$POLICY_REMOTE_CONFIRM" "$POLICY_REMOTE_SINK"
  local -a ENGINE_EXCLUDES=()
  policy_remote_paths_apply "$policy" engine_paths "$kind" ENGINE_EXCLUDES POLICY_REMOTE_COUNT || rc=$?
  printf 'rc=%s count=%s reason=%s\n' "$rc" "$POLICY_REMOTE_COUNT" "$POLICY_REMOTE_SKIP_REASON"
  while [[ "$i" -lt "${#ENGINE_EXCLUDES[@]}" ]]; do
    printf 'exclude=%s\n' "${ENGINE_EXCLUDES[$i]}"
    i=$((i + 1))
  done
}

out="$(engine_apply e2ee exclude notes $'notes/a*b\nnotes/weird[1]{x}')"
expect_contains "engine e2ee: proceeds on subfolders" "$out" "rc=0 count=2"
expect_contains "engine e2ee: star glob escaped" "$out" 'exclude=/a\*b/**'
expect_contains "engine e2ee: brackets and braces escaped" "$out" 'exclude=/weird\[1\]\{x\}/**'
expect_not_contains "engine e2ee: no bare wildcard pattern" "$out" 'exclude=/a*b/**'

out="$(engine_apply e2ee exclude notes notes)"
expect_contains "engine e2ee: encrypted root skips" "$out" "rc=2 count=1"
expect_contains "engine e2ee: root reason recorded" "$out" "reason=end-to-end encrypted remote root"

out="$(engine_apply e2ee warn notes notes/secret)"
expect_contains "engine e2ee: warn proceeds" "$out" "rc=0 count=1"
expect_not_contains "engine e2ee: warn excludes nothing" "$out" "exclude="

out="$(engine_apply e2ee exclude notes 'notes/../escape')"
expect_contains "engine e2ee: unsafe subpath proceeds" "$out" "rc=0"
expect_not_contains "engine e2ee: unsafe subpath yields no exclude" "$out" "exclude="

out="$(engine_apply e2ee allow notes notes)"
expect_contains "engine allow: short-circuits without a probe" "$out" "rc=0 count=0"
expect_not_contains "engine allow: silent" "$out" "exclude="

out="$(engine_apply external skip notes notes)"
expect_contains "engine external: skip root" "$out" "rc=2 count=1"

out="$(engine_apply external ask notes notes)"
expect_contains "engine external: ask without confirmation skips" "$out" "rc=2"
expect_contains "engine external: ask reason recorded" "$out" "reason=external storage (EXTERNAL_STORAGE_POLICY=ask); not confirmed"

out="$(engine_apply external warn notes notes)"
expect_contains "engine external: warn root proceeds" "$out" "rc=0 count=1"

out="$(engine_apply external skip notes notes/mounted)"
expect_contains "engine external: subfolder only warns and proceeds" "$out" "rc=0 count=1"

# collect style keeps recording reported paths even under allow (doctor's
# report), while apply/wizard short-circuit.
POLICY_REMOTE_ROOT=notes POLICY_REMOTE_STYLE=collect POLICY_REMOTE_SINK=:
ENGINE_PATHS=$'notes/a\nnotes/b'
ENGINE_EXCLUDES=()
policy_remote_paths_apply allow engine_paths e2ee ENGINE_EXCLUDES POLICY_REMOTE_COUNT
expect_eq "engine collect: allow still records paths" "2" "$POLICY_REMOTE_COUNT"
expect_eq "engine collect: paths joined" $'notes/a\nnotes/b' "$POLICY_REMOTE_PATHS"

# The wizard scope lookup: a pair whose parent is reported is gated.
ENGINE_SUB_PATHS="" ENGINE_PARENT_PATHS=""
# shellcheck disable=SC2329  # invoked indirectly by the engine
engine_scope_probe() {
  case "$1" in
    parent) printf '%s\n' "$ENGINE_PARENT_PATHS" ;;
    *) printf '%s\n' "$ENGINE_SUB_PATHS" ;;
  esac
}
engine_wizard() {
  local kind="$1" policy="$2" sub="$3" rc=0
  POLICY_REMOTE_ROOT="$sub"
  POLICY_REMOTE_STYLE=wizard
  POLICY_REMOTE_SCOPE_SEARCH=1
  POLICY_REMOTE_CONFIRM=""
  POLICY_REMOTE_SINK=:
  # The engine reads these by name; reference them so shellcheck sees the use.
  : "$POLICY_REMOTE_ROOT" "$POLICY_REMOTE_STYLE" "$POLICY_REMOTE_SCOPE_SEARCH" \
    "$POLICY_REMOTE_CONFIRM" "$POLICY_REMOTE_SINK"
  local -a ENGINE_EXCLUDES=()
  policy_remote_paths_apply "$policy" engine_scope_probe "$kind" ENGINE_EXCLUDES POLICY_REMOTE_COUNT || rc=$?
  printf 'rc=%s scope=%s\n' "$rc" "$POLICY_REMOTE_LAST_SCOPE"
}

ENGINE_PARENT_PATHS="parent"
out="$(engine_wizard external skip parent/child)"
expect_contains "engine wizard: parent mount skips the child" "$out" "rc=2"
expect_contains "engine wizard: scope is the parent" "$out" "scope=parent"

ENGINE_PARENT_PATHS=""
out="$(engine_wizard e2ee warn notes)"
expect_contains "engine wizard: unreported pair proceeds" "$out" "rc=0"

ENGINE_SUB_PATHS="notes"
out="$(engine_wizard e2ee exclude notes)"
expect_contains "engine wizard: reported pair skips" "$out" "rc=2"
expect_contains "engine wizard: scope is the pair" "$out" "scope=notes"

# The platform blocks same-tree case collisions, so the sync branch tests
# feed sync_case_clash_preflight a pinned pair; the real detection runs below
# on a case-sensitive volume when one could be mounted.
policy_case_clashes() { printf 'A/clash/X.TXT\ta/Clash/x.txt\n'; }
cc_tree="${TMP}/cc-branch"
mkdir -p "${cc_tree}/a/Clash"
printf 'one' >"${cc_tree}/a/Clash/x.txt"
export CASE_CLASH_POLICY=exclude
SYNC_POLICY_EXCLUDES=()
poly_preflight sync_case_clash_preflight "$cc_tree"
expect_eq "case_clash exclude: pattern" "/a/Clash/x.txt" "${SYNC_POLICY_EXCLUDES[0]:-}"
expect_contains "case_clash exclude: warning" "$(cat "$POLY_OUT")" "case clash"
export CASE_CLASH_POLICY=warn
SYNC_POLICY_EXCLUDES=()
poly_preflight sync_case_clash_preflight "$cc_tree"
expect_eq "case_clash warn: no exclude" "" "${SYNC_POLICY_EXCLUDES[0]:-}"
expect_contains "case_clash warn: warning" "$(cat "$POLY_OUT")" "differ only by case"
export CASE_CLASH_POLICY=rename SYNC_APPLY=true
SYNC_POLICY_EXCLUDES=()
poly_preflight sync_case_clash_preflight "$cc_tree"
expect_file "case_clash rename: local file renamed" "${cc_tree}/a/Clash/x (case conflict).txt"
expect_contains "case_clash rename: output names the rename" "$(cat "$POLY_OUT")" "renamed"
printf 'two' >"${cc_tree}/a/Clash/x.txt"
export CASE_CLASH_POLICY=rename SYNC_APPLY=false
SYNC_POLICY_EXCLUDES=()
poly_preflight sync_case_clash_preflight "$cc_tree"
expect_file "case_clash dry run: nothing renamed" "${cc_tree}/a/Clash/x.txt"
expect_contains "case_clash dry run: would rename" "$(cat "$POLY_OUT")" "would rename"
unset CASE_CLASH_POLICY
# Restore the real helper shadowed by the branch stub above (policy_case_clashes
# lives in lib/sync/case_clash.sh, split out of lib/sync/policy.sh).
# shellcheck source=/dev/null
source "${PROJ}/lib/sync/case_clash.sh"

# --- sync_build_args carries the policy arguments -------------------------
# poly_build_args MODE [ENV=...]... - one SYNC_ARGS entry per line from a
# clean subprocess, like the unit suite's probe.
poly_build_args() {
  local mode="$1"
  shift
  # shellcheck disable=SC2016  # the -c program expands "$1" itself
  env "POLY_MODE=$mode" "$@" bash -c '
    set -uo pipefail
    source "$1/lib/sciebo.sh"
    source "$1/lib/commands/sync.sh"
    : "${TRANSFERS:=1}" "${CHECKERS:=4}" "${TPSLIMIT:=8}" "${RETRIES:=3}" "${LOW_LEVEL_RETRIES:=10}"
    : "${TIMEOUT:=10m}" "${CONTIMEOUT:=30s}" "${STATS:=30s}" "${LOG_LEVEL:=INFO}"
    : "${CREATE_EMPTY_SRC_DIRS:=0}" "${TRACK_RENAMES:=0}" "${MAX_DELETE:=-1}"
    : "${BW_LIMIT_UP:=}" "${BW_LIMIT_DOWN:=}" "${SYNC_CHUNK_SIZE:=}"
    : "${CONFLICT_UPLOAD:=0}" "${CONFLICT_PATTERN:=conflicted copy}"
    ENTRY_MODE="$POLY_MODE" ENTRY_FILTER="" ENTRY_NAME=probe ENTRY_REMOTE=probe
    ENTRY_LOCAL="/tmp/probe-src"
    SYNC_APPLY=false SYNC_ASSUME_YES=false SYNC_DELETE_GUARD_OVERRIDE=false SYNC_POLICY_EXCLUDES=()
    : "${BISYNC_CONFLICT_RESOLVE:=newer}" "${BISYNC_CONFLICT_LOSER:=num}"
    : "${BISYNC_CONFLICT_SUFFIX:=(conflicted copy)}" "${BISYNC_MAX_LOCK:=2m}"
    : "${BISYNC_RESYNC_MODE:=newer}" "${BISYNC_RESILIENT:=1}" "${BISYNC_RECOVER:=1}"
    : "${BISYNC_DIR:=/tmp/probe-bisync}" "${FILTER_DIR:=/tmp/probe-filters}"
    : "${SYMLINK_POLICY:=skip}"
    sync_build_args "remote:base/probe" "/tmp/probe.log"
    printf "%s\n" "${SYNC_ARGS[@]}"
    # policy.sh loads on demand through sync_policy_args and allocates no
    # case-cache directory here (allocation is lazy and no scan runs); keep
    # the cleanup call so any temp file a future probe registers is dropped
    # like bin/sciebo would drop it.
    sciebo_temp_cleanup || true
  ' poly-build "$PROJ" 2>&1
}
out="$(poly_build_args sync)"
expect_contains "build_args: symlink skip by default" "$out" "--skip-links"
expect_not_contains "build_args: no delete guard without ASK_DELETE" "$out" "--max-delete"
out="$(poly_build_args sync CHECKSUM=1)"
expect_contains "build_args: --checksum recorded" "$out" "--checksum"
out="$(poly_build_args bisync CHECKSUM=1 MOVE_TO_TRASH=1 LOCAL_TRASH_DIR=/trash)"
expect_contains "build_args: bisync --compare recorded" "$out" $'--compare\nsize,modtime,checksum'
expect_contains "build_args: bisync backup-dir per entry" "$out" $'--backup-dir\n/trash/probe'
out="$(poly_build_args sync SYMLINK_POLICY=follow INVALID_NAME_POLICY=exclude)"
expect_contains "build_args: followed symlinks" "$out" "--copy-links"
expect_contains "build_args: invalid name excludes" "$out" '*[<>:"|?*]*'
expect_contains "build_args: reserved name class excludes" "$out" '[cC][oO][nN]'
out="$(poly_build_args sync ASK_DELETE=1 MAX_DELETE=-1 DELETE_FILES_THRESHOLD=3)"
expect_contains "build_args: delete guard threshold" "$out" $'--max-delete\n3'
out="$(poly_build_args sync MAX_DELETE=7)"
expect_contains "build_args: explicit max-delete wins" "$out" $'--max-delete\n7'
expect_not_contains "build_args: explicit cap has no extra guard" "$out" $'--max-delete\n3'
out="$(poly_build_args sync RETRIES_SLEEP=5s TRANSFER_PARTIAL=1 TRANSFER_INPLACE=1)"
expect_contains "build_args: retries-sleep recorded" "$out" $'--retries-sleep\n5s'
expect_contains "build_args: partial recorded" "$out" "--partial"
expect_contains "build_args: inplace recorded" "$out" "--inplace"
out="$(poly_build_args sync)"
expect_not_contains "build_args: no partial by default" "$out" "--partial"
expect_not_contains "build_args: no inplace by default" "$out" "--inplace"

# --- end-to-end: invalid names --------------------------------------------
INV_SRC="${TMP}/inv-src"
INV_REMOTE="${TMP}/backup/inv-names"
mkdir -p "$INV_SRC"
printf 'ok\n' >"${INV_SRC}/ok.txt"
printf 'bad\n' >"${INV_SRC}/bad?.txt"
printf 'dot\n' >"${INV_SRC}/trail."
printf 'res\n' >"${INV_SRC}/CON.txt"
printf 'mixed\n' >"${INV_SRC}/CoN.log"
printf 'br\n' >"${INV_SRC}/open[1].txt"
printf 'space\n' >"${INV_SRC}/trail "
printf 'com\n' >"${INV_SRC}/com3.dat"
printf 'lpt\n' >"${INV_SRC}/LPT9.log"
printf 'com10\n' >"${INV_SRC}/com10.dat"
cat >"$MANIFEST_FILE" <<EOF
sync|${INV_SRC}|inv-names
EOF
rm -rf "$INV_REMOTE"
expect_cli "invalid names: default exclude rc 0" 0 run_cli sync --apply --only inv-names
expect_file "invalid names: portable file uploaded" "${INV_REMOTE}/ok.txt"
expect_no_file "invalid names: question mark excluded" "${INV_REMOTE}/bad?.txt"
expect_no_file "invalid names: trailing dot excluded" "${INV_REMOTE}/trail."
expect_no_file "invalid names: reserved name excluded" "${INV_REMOTE}/CON.txt"
expect_no_file "invalid names: mixed-case reserved excluded" "${INV_REMOTE}/CoN.log"
expect_no_file "invalid names: bracket name excluded" "${INV_REMOTE}/open[1].txt"
expect_no_file "invalid names: trailing space excluded" "${INV_REMOTE}/trail "
expect_no_file "invalid names: COM range excluded" "${INV_REMOTE}/com3.dat"
expect_no_file "invalid names: LPT range excluded" "${INV_REMOTE}/LPT9.log"
expect_file "invalid names: COM10 is not reserved" "${INV_REMOTE}/com10.dat"

rm -rf "$INV_REMOTE"
export INVALID_NAME_POLICY=allow
expect_cli "invalid names: allow rc 0" 0 run_cli sync --apply --only inv-names
expect_file "invalid names: allow uploads the question mark" "${INV_REMOTE}/bad?.txt"
expect_file "invalid names: allow uploads the reserved name" "${INV_REMOTE}/CON.txt"
expect_file "invalid names: allow uploads the bracket name" "${INV_REMOTE}/open[1].txt"
expect_file "invalid names: allow uploads the trailing space" "${INV_REMOTE}/trail "
unset INVALID_NAME_POLICY

rm -rf "$INV_REMOTE"
export INVALID_NAME_POLICY=warn
expect_cli "invalid names: warn rc 0" 0 run_cli sync --apply --only inv-names
expect_contains "invalid names: warn reports the count" "$CLI_OUT" "non-portable name(s)"
expect_file "invalid names: warn still uploads" "${INV_REMOTE}/bad?.txt"
unset INVALID_NAME_POLICY

# --- end-to-end: symlink policies -----------------------------------------
SL_SRC="${TMP}/sl-src"
SL_REMOTE="${TMP}/backup/sl-policy"
mkdir -p "$SL_SRC"
printf 'real\n' >"${SL_SRC}/target.txt"
ln -s target.txt "${SL_SRC}/link.txt"
cat >"$MANIFEST_FILE" <<EOF
sync|${SL_SRC}|sl-policy
EOF
export SYMLINK_POLICY=skip
rm -rf "$SL_REMOTE"
expect_cli "symlinks: skip rc 0" 0 run_cli sync --apply --only sl-policy
expect_file "symlinks: skip copies the target" "${SL_REMOTE}/target.txt"
expect_no_file "symlinks: skip drops the link" "${SL_REMOTE}/link.txt"
export SYMLINK_POLICY=follow
rm -rf "$SL_REMOTE"
expect_cli "symlinks: follow rc 0" 0 run_cli sync --apply --only sl-policy
expect_file "symlinks: follow copies the link target" "${SL_REMOTE}/link.txt"
expect_contains "symlinks: follow content" "$(cat "${SL_REMOTE}/link.txt" 2>/dev/null)" "real"
export SYMLINK_POLICY=translate
rm -rf "$SL_REMOTE"
expect_cli "symlinks: translate rc 0" 0 run_cli sync --apply --only sl-policy
if [[ -L "${SL_REMOTE}/link.txt" || -f "${SL_REMOTE}/link.txt.rclonelink" ]]; then
  pass "symlinks: translate keeps a link representation"
else
  fail "symlinks: translate keeps a link representation" "missing ${SL_REMOTE}/link.txt"
fi
unset SYMLINK_POLICY

# --- end-to-end: delete guard ---------------------------------------------
DG_LOCAL="${TMP}/dg-local"
DG_REMOTE="${TMP}/backup/dg-guard"
mkdir -p "$DG_LOCAL" "$DG_REMOTE"
printf 'a\n' >"${DG_REMOTE}/a.txt"
printf 'b\n' >"${DG_REMOTE}/b.txt"
cat >"$MANIFEST_FILE" <<EOF
sync|${DG_LOCAL}|dg-guard
EOF
export DELETE_FILES_THRESHOLD=1 ASK_DELETE=1
expect_cli "delete guard: non-interactive fails rc 1" 1 run_cli sync --apply --only dg-guard </dev/null
expect_contains "delete guard: names the threshold" "$CLI_OUT" "more than 1 file(s) to delete"
expect_contains "delete guard: suggests --yes" "$CLI_OUT" "--yes"
expect_cli "delete guard: --yes disables the guard rc 0" 0 run_cli sync --apply --yes --only dg-guard </dev/null
expect_no_file "delete guard: --yes deletes the first file" "${DG_REMOTE}/a.txt"
expect_no_file "delete guard: --yes deletes the second file" "${DG_REMOTE}/b.txt"
unset DELETE_FILES_THRESHOLD ASK_DELETE

# --- end-to-end: MOVE_TO_TRASH on a pull ----------------------------------
MT_LOCAL="${TMP}/mt-local"
MT_REMOTE="${TMP}/backup/mt-pull"
MT_TRASH="${TMP}/mt-trash"
mkdir -p "$MT_REMOTE"
printf 'first\n' >"${MT_REMOTE}/data.txt"
cat >"$MANIFEST_FILE" <<EOF
pull|${MT_LOCAL}|mt-pull
EOF
expect_cli "trash: first pull rc 0" 0 run_cli sync --apply --only mt-pull
expect_contains "trash: first content is local" "$(cat "${MT_LOCAL}/data.txt" 2>/dev/null)" "first"
printf 'second\n' >"${MT_REMOTE}/data.txt"
export MOVE_TO_TRASH=1 LOCAL_TRASH_DIR="$MT_TRASH"
expect_cli "trash: overwriting pull rc 0" 0 run_cli sync --apply --only mt-pull
expect_contains "trash: new content is local" "$(cat "${MT_LOCAL}/data.txt" 2>/dev/null)" "second"
old_content="$(find "$MT_TRASH" -type f -name 'data.txt' -exec cat {} \; 2>/dev/null)"
expect_contains "trash: old file moved under LOCAL_TRASH_DIR" "$old_content" "first"
unset MOVE_TO_TRASH

# --- built argv: chunk clamp and checksum (stub rclone) -------------------
POLY_STUB="${TMP}/poly-rclone-bin"
POLY_ARGV="${TMP}/poly-rclone.argv"
mkdir -p "$POLY_STUB"
cat >"${POLY_STUB}/rclone" <<'STUB'
#!/bin/bash
for arg in "$@"; do
  case "$arg" in
    version)
      printf 'rclone v1.75.1\n'
      exit 0
      ;;
    listremotes)
      printf 'testremote:\n'
      exit 0
      ;;
  esac
done
printf '%s\n' "$*" >>"${POLY_ARGV:-/dev/null}"
exit 0
STUB
chmod +x "${POLY_STUB}/rclone"
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_cli_stub() {
  (cd "$TMP" && env PATH="${POLY_STUB}:$PATH" RCLONE_BIN="${POLY_STUB}/rclone" POLY_ARGV="$POLY_ARGV" bash "${PROJ}/bin/sciebo" "$@")
}
cat >"$MANIFEST_FILE" <<EOF
sync|${INV_SRC}|poly-argv
EOF
: >"$POLY_ARGV"
export CHUNK_SIZE=100Mi MAX_CHUNK_SIZE=10Mi
expect_cli "argv: clamped chunk size rc 0" 0 run_cli_stub sync --dry-run --only poly-argv
expect_contains "argv: chunk size clamped to MAX" "$(cat "$POLY_ARGV")" "--webdav-nextcloud-chunk-size 10Mi"
expect_contains "argv: clamp warning" "$CLI_OUT" "clamped"
unset MAX_CHUNK_SIZE
export CHECKSUM=1
: >"$POLY_ARGV"
expect_cli "argv: checksum run rc 0" 0 run_cli_stub sync --dry-run --only poly-argv
expect_contains "argv: --checksum recorded" "$(cat "$POLY_ARGV")" "--checksum"
unset CHECKSUM CHUNK_SIZE

# --- case clashes end-to-end (case-sensitive scratch volume) --------------
# poly_make_cs_volume - mount a small case-sensitive APFS image under TMP and
# set POLY_CS_VOL (cleaned up by the EXIT trap); rc 1 when unavailable.
poly_make_cs_volume() {
  command -v hdiutil >/dev/null 2>&1 || return 1
  local img="${TMP}/policies-cs.dmg" mp="${TMP}/policies-cs-mnt"
  mkdir -p "$mp" || return 1
  hdiutil create -size 8m -fs "Case-sensitive APFS" -volname "sciebo-policies-$$" -ov "$img" >/dev/null 2>&1 || return 1
  hdiutil attach -nobrowse -readwrite -mountpoint "$mp" "$img" >/dev/null 2>&1 || return 1
  mkdir -p "${mp}/probe/Dir" 2>/dev/null || {
    hdiutil detach "$mp" >/dev/null 2>&1 || true
    return 1
  }
  if ! mkdir "${mp}/probe/dir" 2>/dev/null; then
    hdiutil detach "$mp" >/dev/null 2>&1 || true
    return 1
  fi
  rm -rf "${mp}/probe"
  POLY_CS_VOL="$mp"
  return 0
}
if poly_make_cs_volume; then
  cs_vol="$POLY_CS_VOL"
  cs_src="${cs_vol}/src"
  mkdir -p "${cs_src}/Dir"
  printf 'upper' >"${cs_src}/Dir/File.txt"
  printf 'lower' >"${cs_src}/Dir/file.txt"
  expect_eq "case_clashes: real same-dir pair" $'Dir/File.txt\tDir/file.txt' \
    "$(policy_case_clashes "$cs_src")"

  cat >"$MANIFEST_FILE" <<EOF
sync|${cs_src}|cc-real
EOF
  rm -rf "${TMP}/backup/cc-real"
  expect_cli "case clash exclude: apply rc 0" 0 run_cli sync --apply --only cc-real
  expect_file "case clash exclude: first name kept" "${TMP}/backup/cc-real/Dir/File.txt"
  # The test remote lives on a case-insensitive filesystem, so the excluded
  # name would resolve to the kept file; list the stored names instead.
  expect_eq "case clash exclude: only the kept name uploaded" "./Dir/File.txt" \
    "$(cd "${TMP}/backup/cc-real" && find . -type f | LC_ALL=C sort)"
  expect_contains "case clash exclude: kept content intact" \
    "$(cat "${TMP}/backup/cc-real/Dir/File.txt" 2>/dev/null)" "upper"

  cs_src2="${cs_vol}/src2"
  mkdir -p "${cs_src2}/Dir"
  printf 'upper' >"${cs_src2}/Dir/File.txt"
  printf 'lower' >"${cs_src2}/Dir/file.txt"
  cat >"$MANIFEST_FILE" <<EOF
sync|${cs_src2}|cc-rename
EOF
  rm -rf "${TMP}/backup/cc-rename"
  export CASE_CLASH_POLICY=rename
  expect_cli "case clash rename: apply rc 0" 0 run_cli sync --apply --only cc-rename
  expect_file "case clash rename: local later name renamed" "${cs_src2}/Dir/file (case conflict).txt"
  expect_file "case clash rename: first name uploaded" "${TMP}/backup/cc-rename/Dir/File.txt"
  expect_file "case clash rename: renamed file uploaded" "${TMP}/backup/cc-rename/Dir/file (case conflict).txt"

  cs_src3="${cs_vol}/src3"
  mkdir -p "${cs_src3}/Dir"
  printf 'upper' >"${cs_src3}/Dir/File.txt"
  printf 'lower' >"${cs_src3}/Dir/file.txt"
  cat >"$MANIFEST_FILE" <<EOF
sync|${cs_src3}|cc-dry
EOF
  rm -rf "${TMP}/backup/cc-dry"
  expect_cli "case clash dry run: rc 0" 0 run_cli check --only cc-dry
  expect_file "case clash dry run: local tree untouched" "${cs_src3}/Dir/file.txt"
  expect_contains "case clash dry run: prints the planned rename" "$CLI_OUT" "would rename"
  expect_no_file "case clash dry run: nothing uploaded" "${TMP}/backup/cc-dry"
  unset CASE_CLASH_POLICY
else
  pass "case clash: case-sensitive volume unavailable; branch behavior covered by the stubbed preflight checks"
fi

# --- engine apply: printable is formatted once, and never when silent -------
# _policy_remote_apply_path used to call $(printable "$path") in every message
# even with POLICY_REMOTE_SINK=:. The stub counts calls so the silent sink is
# proven to skip the format entirely and the active sink to format one path.
poly_printable_orig="$(declare -f printable)"
poly_printable_calls=0
# shellcheck disable=SC2329  # counted while the engine runs in this shell
printable() {
  poly_printable_calls=$((poly_printable_calls + 1))
  printf '%s' "$1"
}
# shellcheck disable=SC2329  # silent non-warn sink for the active-sink case
poly_sink() { :; }
# shellcheck disable=SC2034  # assigned by the engine under test
POLICY_REMOTE_LAST_SUB=""
_policy_remote_apply_path "notes/secret" notes e2ee exclude "" "" probe ":" 1
expect_eq "engine apply: silent sink never formats printable" "0" "$poly_printable_calls"
_policy_remote_apply_path "notes/secret" notes e2ee exclude "" "" probe poly_sink 1
expect_eq "engine apply: active sink formats printable once" "1" "$poly_printable_calls"
eval "$poly_printable_orig"

finish
