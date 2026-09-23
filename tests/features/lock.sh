#!/usr/bin/env bash
# lock.sh - manual WebDAV file locks through the shared HTTP layer
# (stub curl): LOCK/UNLOCK request shapes, local records, PROPFIND fallback,
# and `locks --prune`.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

# The stub records method/url/body but not request headers; wrap it so the
# lock tests can assert X-User-Lock and Lock-Token too.
STUB_REAL="${STUB_BIN}/curl.real"
cp "${STUB_BIN}/curl" "$STUB_REAL"
{
  printf '#!/bin/bash\n'
  printf 'printf "%%s\\n" "$@" >>"%s"\n' "${TMP}/curl-args.log"
  printf 'exec "%s" "$@"\n' "$STUB_REAL"
} >"${STUB_BIN}/curl"
chmod +x "${STUB_BIN}/curl"
curl_args() { cat "${TMP}/curl-args.log" 2>/dev/null || true; }
curl_args_clear() { : >"${TMP}/curl-args.log"; }

LOCK_HEADERS="${TMP}/lock-token.headers"
printf 'Lock-Token: files_lock/abc-123\r\n' >"$LOCK_HEADERS"
LOCK_RECORD="${TMP}/state/remote-locks/notes_plan.txt.state"

# --- lock: request shape, record, output ------------------------------------
stub_clear_calls
stub_reset_routes
curl_args_clear
stub_route LOCK '*/remote.php/dav/files/alice/backup/notes/plan.txt' 200 "$LOCK_HEADERS" </dev/null

expect_cli "lock: rc 0" 0 run_cli_nc lock notes/plan.txt
expect_contains "lock: prints locked" "$CLI_OUT" "locked notes/plan.txt"
expect_file "lock: record written" "$LOCK_RECORD"
expect_eq "lock: record mode 600" "600" "$(file_mode "$LOCK_RECORD")"
expect_contains "lock: record path" "$(cat "$LOCK_RECORD")" "path=notes/plan.txt"
expect_contains "lock: record token" "$(cat "$LOCK_RECORD")" "token=files_lock/abc-123"
expect_contains "lock: sends LOCK" "$(stub_calls)" $'LOCK\t'
expect_contains "lock: X-User-Lock header" "$(curl_args)" "X-User-Lock: 1"
expect_contains "lock: sends an explicit empty body" "$(curl_args)" "--data-binary"

# --- unlock: reuses the recorded token --------------------------------------
stub_reset_routes
stub_clear_calls
curl_args_clear
stub_route UNLOCK '*/remote.php/dav/files/alice/backup/notes/plan.txt' 200 </dev/null

expect_cli "unlock: rc 0" 0 run_cli_nc unlock notes/plan.txt
expect_contains "unlock: prints unlocked" "$CLI_OUT" "unlocked notes/plan.txt"
expect_contains "unlock: sends UNLOCK" "$(stub_calls)" $'UNLOCK\t'
expect_contains "unlock: sends recorded token" "$(curl_args)" "Lock-Token: files_lock/abc-123"
expect_no_file "unlock: removes record" "$LOCK_RECORD"

# --- unlock: PROPFIND fallback when no record exists ------------------------
stub_reset_routes
stub_clear_calls
curl_args_clear
stub_route PROPFIND '*/remote.php/dav/files/alice/backup/notes/other.txt' 207 <<'XML'
<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:nc="http://nextcloud.org/ns">
  <d:response>
    <d:href>/remote.php/dav/files/alice/backup/notes/other.txt</d:href>
    <d:propstat><d:prop><nc:lock-token>files_lock/from-propfind</nc:lock-token></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
  </d:response>
</d:multistatus>
XML
stub_route UNLOCK '*/remote.php/dav/files/alice/backup/notes/other.txt' 204 </dev/null

expect_cli "unlock: fallback rc 0" 0 run_cli_nc unlock notes/other.txt
expect_contains "unlock: fallback prints" "$CLI_OUT" "unlocked notes/other.txt"
expect_contains "unlock: fallback token" "$(curl_args)" "Lock-Token: files_lock/from-propfind"
expect_contains "unlock: PROPFIND depth 0" "$(curl_args)" "Depth: 0"
expect_contains "unlock: PROPFIND nc:lock-token" "$(stub_calls)" "nc:lock-token"
expect_no_file "unlock: fallback writes no record" "${TMP}/state/remote-locks/notes_other.txt.state"

# --- unlock: not locked -----------------------------------------------------
stub_reset_routes
stub_clear_calls
stub_route PROPFIND '*/remote.php/dav/files/alice/backup/notes/empty.txt' 207 <<'XML'
<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:nc="http://nextcloud.org/ns">
  <d:response>
    <d:href>/remote.php/dav/files/alice/backup/notes/empty.txt</d:href>
    <d:propstat><d:prop><nc:lock-token/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat>
  </d:response>
</d:multistatus>
XML

expect_cli "unlock: not locked rc 1" 1 run_cli_nc unlock notes/empty.txt
expect_contains "unlock: not locked message" "$CLI_OUT" "notes/empty.txt is not locked"
expect_not_contains "unlock: not locked sends no UNLOCK" "$(stub_calls)" $'UNLOCK\t'

# --- lock: server-side errors ----------------------------------------------
stub_reset_routes
stub_clear_calls
stub_route LOCK '*/remote.php/dav/files/alice/backup/notes/plan.txt' 423 <<'XML'
<?xml version="1.0"?>
<d:error xmlns:d="DAV:" xmlns:s="http://sabredav.org/ns"><s:message>locked by someone</s:message></d:error>
XML

expect_cli "lock: 423 rc 1" 1 run_cli_nc lock notes/plan.txt
expect_contains "lock: already locked message" "$CLI_OUT" "notes/plan.txt is already locked"
expect_no_file "lock: 423 writes no record" "$LOCK_RECORD"

stub_reset_routes
stub_route LOCK '*/remote.php/dav/files/alice/backup/notes/plan.txt' 500 <<'XML'
<?xml version="1.0"?>
<d:error xmlns:d="DAV:" xmlns:s="http://sabredav.org/ns"><d:responsedescription>server exploded</d:responsedescription></d:error>
XML

expect_cli "lock: 500 rc 1" 1 run_cli_nc lock notes/plan.txt
expect_contains "lock: 500 status" "$CLI_OUT" "500"
expect_contains "lock: 500 detail" "$CLI_OUT" "server exploded"

# --- locks: list, prune, empty ---------------------------------------------
rm -rf "${TMP}/state/remote-locks"
mkdir -p "${TMP}/state/remote-locks"
LIVE_RECORD="${TMP}/state/remote-locks/notes_live.txt.state"
OLD_RECORD="${TMP}/state/remote-locks/notes_old.txt.state"
printf 'path=notes/live.txt\ntoken=files_lock/live-1\n' >"$LIVE_RECORD"
printf 'path=notes/old.txt\ntoken=files_lock/old-1\n' >"$OLD_RECORD"

stub_reset_routes
stub_clear_calls
expect_cli "locks: rc 0" 0 run_cli_nc locks
expect_contains "locks: live row" "$CLI_OUT" "notes_live.txt  notes/live.txt  files_lock/live-1"
expect_contains "locks: old row" "$CLI_OUT" "notes_old.txt  notes/old.txt  files_lock/old-1"
expect_eq "locks: listing is local" "0" "$(stub_count 'remote.php')"

stub_reset_routes
stub_clear_calls
curl_args_clear
stub_route PROPFIND '*/remote.php/dav/files/alice/backup/notes' 207 <<'XML'
<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:nc="http://nextcloud.org/ns">
  <d:response>
    <d:href>/remote.php/dav/files/alice/backup/notes/</d:href>
    <d:propstat><d:prop><nc:lock-token/></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/dav/files/alice/backup/notes/live.txt</d:href>
    <d:propstat><d:prop><nc:lock-token>files_lock/live-1</nc:lock-token></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/dav/files/alice/backup/notes/old.txt</d:href>
    <d:propstat><d:prop><nc:lock-token/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat>
  </d:response>
</d:multistatus>
XML

expect_cli "locks: prune rc 0" 0 run_cli_nc locks --prune
expect_contains "locks: pruned old" "$CLI_OUT" "pruned notes_old.txt"
expect_contains "locks: keeps live row" "$CLI_OUT" "notes_live.txt  notes/live.txt  files_lock/live-1"
expect_no_file "locks: old record removed" "$OLD_RECORD"
expect_file "locks: live record kept" "$LIVE_RECORD"
expect_eq "locks: one PROPFIND per parent" "1" "$(stub_count $'PROPFIND\t')"
expect_contains "locks: prune uses Depth 1" "$(curl_args)" "Depth: 1"
expect_not_contains "locks: prune never used Depth 0" "$(curl_args)" "Depth: 0"

expect_cli "locks: after prune rc 0" 0 run_cli_nc locks
expect_not_contains "locks: old path gone" "$CLI_OUT" "notes/old.txt"

# Distinct parent directories get one Depth-1 PROPFIND each; a missing parent
# (404) prunes its records just like the old per-file 404.
rm -rf "${TMP}/state/remote-locks"
mkdir -p "${TMP}/state/remote-locks"
DOCS_RECORD="${TMP}/state/remote-locks/docs_a.txt.state"
OTHER_RECORD="${TMP}/state/remote-locks/other_b.txt.state"
printf 'path=docs/a.txt\ntoken=files_lock/a-9\n' >"$DOCS_RECORD"
printf 'path=other/b.txt\ntoken=files_lock/b-9\n' >"$OTHER_RECORD"
stub_reset_routes
stub_clear_calls
curl_args_clear
stub_route PROPFIND '*/remote.php/dav/files/alice/backup/docs' 207 <<'XML'
<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:nc="http://nextcloud.org/ns">
  <d:response>
    <d:href>/remote.php/dav/files/alice/backup/docs/a.txt</d:href>
    <d:propstat><d:prop><nc:lock-token>files_lock/a-9</nc:lock-token></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
  </d:response>
</d:multistatus>
XML
stub_route PROPFIND '*/remote.php/dav/files/alice/backup/other' 404 <<'XML'
<?xml version="1.0"?>
<d:error xmlns:d="DAV:"><d:responsedescription>Not Found</d:responsedescription></d:error>
XML

expect_cli "locks: prune distinct parents rc 0" 0 run_cli_nc locks --prune
expect_contains "locks: distinct parents keeps a" "$CLI_OUT" "docs_a.txt  docs/a.txt  files_lock/a-9"
expect_contains "locks: distinct parents prunes b" "$CLI_OUT" "pruned other_b.txt"
expect_eq "locks: one PROPFIND per distinct parent" "2" "$(stub_count $'PROPFIND\t')"
expect_file "locks: distinct parents keeps a record" "$DOCS_RECORD"
expect_no_file "locks: distinct parents drops b record" "$OTHER_RECORD"

# --- fork-free prune: URL and parent built once per record ------------------
# cmd_locks used to evaluate $(lock_parent_url "$(lock_url "$path")") in both
# the parent-batching pass and the report pass, so every record forked twice.
# The URL helpers are stubbed to count calls; running the command in this shell
# (not through run_cli_nc) keeps the counters alive across the forkless
# ${ ...;} captures the prune pass uses.
# shellcheck source=/dev/null
source "${PROJ}/lib/commands/lock.sh"
fork_dir="${TMP}/fork-prune"
rm -rf "$fork_dir"
mkdir -p "${fork_dir}/remote-locks"
printf 'path=notes/a.txt\ntoken=tok-a\n' >"${fork_dir}/remote-locks/notes_a.txt.state"
printf 'path=notes/b.txt\ntoken=tok-b\n' >"${fork_dir}/remote-locks/notes_b.txt.state"
# shellcheck disable=SC2034  # read by cmd_locks
REMOTE_LOCKS_DIR="${fork_dir}/remote-locks"
fork_url_calls=0
fork_parent_calls=0
# shellcheck disable=SC2329  # counted while cmd_locks runs in this shell
lock_url() {
  fork_url_calls=$((fork_url_calls + 1))
  printf 'BASE/%s' "$1"
}
# shellcheck disable=SC2329  # counted while cmd_locks runs in this shell
lock_parent_url() {
  fork_parent_calls=$((fork_parent_calls + 1))
  printf '%s' "${1%/*}"
}
# shellcheck disable=SC2329  # keeps the probe offline
lock_propfind_dir() {
  local -n _fork_tokens="$2"
  _fork_tokens=()
}
# shellcheck disable=SC2329  # keeps the probe offline
http_load_context() { :; }
fork_out=${ cmd_locks --prune;}
expect_eq "locks: prune builds a URL once per record" "2" "$fork_url_calls"
expect_eq "locks: prune builds a parent once per record" "2" "$fork_parent_calls"
expect_contains "locks: fork probe still prunes" "$fork_out" "pruned notes_a.txt"
expect_no_file "locks: fork probe drops the record" "${fork_dir}/remote-locks/notes_a.txt.state"

rm -rf "${TMP}/state/remote-locks"
expect_cli "locks: missing dir rc 0" 0 run_cli_nc locks
expect_contains "locks: missing dir message" "$CLI_OUT" "no recorded locks"

# --- locks/unlock: malformed records ----------------------------------------
mkdir -p "${TMP}/state/remote-locks"
printf 'path=notes/broken.txt\n' >"${TMP}/state/remote-locks/notes_broken.txt.state"
expect_cli "locks: malformed skipped rc 0" 0 run_cli_nc locks
expect_contains "locks: malformed warned" "$CLI_OUT" "malformed"
expect_not_contains "locks: malformed not listed" "$CLI_OUT" "notes/broken.txt"

expect_cli "unlock: malformed record rc 1" 1 run_cli_nc unlock notes/broken.txt
expect_contains "unlock: malformed message" "$CLI_OUT" "malformed"
rm -rf "${TMP}/state/remote-locks"

# --- security: control bytes in a Lock-Token are never replayed -------------
stub_reset_routes
stub_clear_calls
curl_args_clear
BAD_HEADERS="${TMP}/lock-token-bad.headers"
printf 'Lock-Token: files_lock/bad\001inject\r\n' >"$BAD_HEADERS"
stub_route LOCK '*/remote.php/dav/files/alice/backup/notes/bad.txt' 200 "$BAD_HEADERS" </dev/null

expect_cli "lock: control-byte token rc 1" 1 run_cli_nc lock notes/bad.txt
expect_contains "lock: control-byte token refused" "$CLI_OUT" "control bytes"
expect_no_file "lock: control-byte token writes no record" "${TMP}/state/remote-locks/notes_bad.txt.state"
expect_not_contains "lock: control-byte token never sent" "$(curl_args)" "inject"

# A tampered record is refused before its token is built into a header.
mkdir -p "${TMP}/state/remote-locks"
printf 'path=notes/corrupt.txt\ntoken=files_lock/bad\001inject\n' >"${TMP}/state/remote-locks/notes_corrupt.txt.state"
stub_reset_routes
stub_clear_calls
curl_args_clear
expect_cli "unlock: control-byte record rc 1" 1 run_cli_nc unlock notes/corrupt.txt
expect_contains "unlock: control-byte record refused" "$CLI_OUT" "control bytes"
expect_not_contains "unlock: control-byte record sends no UNLOCK" "$(stub_calls)" $'UNLOCK\t'
rm -f "${TMP}/state/remote-locks/notes_corrupt.txt.state"

# --- unlock --all / locks --unlock-all --------------------------------------
rm -rf "${TMP}/state/remote-locks"
mkdir -p "${TMP}/state/remote-locks"
ALL_A="${TMP}/state/remote-locks/notes_a.txt.state"
ALL_B="${TMP}/state/remote-locks/notes_b.txt.state"
printf 'path=notes/a.txt\ntoken=files_lock/a-1\n' >"$ALL_A"
printf 'path=notes/b.txt\ntoken=files_lock/b-1\n' >"$ALL_B"

stub_reset_routes
stub_clear_calls
curl_args_clear
stub_route UNLOCK '*/remote.php/dav/files/alice/backup/notes/a.txt' 200 </dev/null
stub_route UNLOCK '*/remote.php/dav/files/alice/backup/notes/b.txt' 204 </dev/null

expect_cli "unlock --all: rc 0" 0 run_cli_nc unlock --all --yes
expect_contains "unlock --all: unlocks a" "$CLI_OUT" "unlocked notes/a.txt"
expect_contains "unlock --all: unlocks b" "$CLI_OUT" "unlocked notes/b.txt"
expect_contains "unlock --all: sends a token" "$(curl_args)" "Lock-Token: files_lock/a-1"
expect_contains "unlock --all: sends b token" "$(curl_args)" "Lock-Token: files_lock/b-1"
expect_eq "unlock --all: one UNLOCK per record" "2" "$(stub_count $'UNLOCK\t')"
expect_no_file "unlock --all: removes a record" "$ALL_A"
expect_no_file "unlock --all: removes b record" "$ALL_B"

# locks --unlock-all releases the same records through the same path.
printf 'path=notes/a.txt\ntoken=files_lock/a-2\n' >"$ALL_A"
printf 'path=notes/b.txt\ntoken=files_lock/b-2\n' >"$ALL_B"
stub_reset_routes
stub_clear_calls
curl_args_clear
stub_route UNLOCK '*/remote.php/dav/files/alice/backup/notes/a.txt' 200 </dev/null
stub_route UNLOCK '*/remote.php/dav/files/alice/backup/notes/b.txt' 200 </dev/null

expect_cli "locks --unlock-all: rc 0" 0 run_cli_nc locks --unlock-all --yes
expect_contains "locks --unlock-all: unlocks a" "$CLI_OUT" "unlocked notes/a.txt"
expect_contains "locks --unlock-all: unlocks b" "$CLI_OUT" "unlocked notes/b.txt"
expect_no_file "locks --unlock-all: removes a record" "$ALL_A"
expect_no_file "locks --unlock-all: removes b record" "$ALL_B"

# Without --yes a non-interactive run refuses before touching the server.
printf 'path=notes/a.txt\ntoken=files_lock/a-3\n' >"$ALL_A"
stub_reset_routes
stub_clear_calls
expect_cli "unlock --all: needs --yes rc 2" 2 run_cli_nc unlock --all
expect_contains "unlock --all: needs --yes message" "$CLI_OUT" "--all requires --yes"
expect_eq "unlock --all: no server call without --yes" "0" "$(stub_count 'remote.php')"
expect_file "unlock --all: record kept without --yes" "$ALL_A"

expect_cli "locks --unlock-all: needs --yes rc 2" 2 run_cli_nc locks --unlock-all
expect_contains "locks --unlock-all: needs --yes message" "$CLI_OUT" "--unlock-all requires --yes"
expect_file "locks --unlock-all: record kept without --yes" "$ALL_A"

# A failing UNLOCK warns and keeps that record; the others are still released.
printf 'path=notes/b.txt\ntoken=files_lock/b-3\n' >"$ALL_B"
stub_reset_routes
stub_clear_calls
stub_route UNLOCK '*/remote.php/dav/files/alice/backup/notes/a.txt' 200 </dev/null
stub_route UNLOCK '*/remote.php/dav/files/alice/backup/notes/b.txt' 500 <<'XML'
<?xml version="1.0"?>
<d:error xmlns:d="DAV:" xmlns:s="http://sabredav.org/ns"><d:responsedescription>server exploded</d:responsedescription></d:error>
XML

expect_cli "unlock --all: partial failure rc 0" 0 run_cli_nc unlock --all --yes
expect_contains "unlock --all: failure warned" "$CLI_OUT" "could not unlock notes/b.txt"
expect_contains "unlock --all: failure detail" "$CLI_OUT" "server exploded"
expect_no_file "unlock --all: success record removed" "$ALL_A"
expect_file "unlock --all: failure record kept" "$ALL_B"

# --all takes no SUB and --prune cannot be combined with --unlock-all.
expect_cli "unlock --all: rejects SUB rc 2" 2 run_cli_nc unlock --all notes/a.txt
expect_contains "unlock --all: SUB message" "$CLI_OUT" "unexpected argument"
expect_cli "locks: prune and unlock-all rc 2" 2 run_cli_nc locks --prune --unlock-all
expect_contains "locks: combined message" "$CLI_OUT" "cannot be combined"

rm -rf "${TMP}/state/remote-locks"
expect_cli "unlock --all: missing dir rc 0" 0 run_cli_nc unlock --all --yes
expect_contains "unlock --all: missing dir message" "$CLI_OUT" "no recorded locks"
mkdir -p "${TMP}/state/remote-locks"
expect_cli "unlock --all: empty dir rc 0" 0 run_cli_nc unlock --all --yes
expect_contains "unlock --all: empty dir message" "$CLI_OUT" "no recorded locks"
rm -rf "${TMP}/state/remote-locks"

# --- guards: unsafe and missing arguments -----------------------------------
expect_cli "lock: unsafe path rc 1" 1 run_cli_nc lock ../evil
expect_contains "lock: unsafe path message" "$CLI_OUT" "unsafe remote path"
expect_cli "lock: missing SUB rc 2" 2 run_cli_nc lock
expect_contains "lock: missing SUB message" "$CLI_OUT" "a remote path argument is required"
expect_cli "unlock: missing SUB rc 2" 2 run_cli_nc unlock
expect_contains "unlock: missing SUB message" "$CLI_OUT" "a remote path argument is required"
expect_cli "locks: unknown option rc 2" 2 run_cli_nc locks --bogus

finish
