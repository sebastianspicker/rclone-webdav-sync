#!/usr/bin/env bash
# server_live.sh - run the real CLI against the live fake Nextcloud.
#
# Unlike the stub-curl feature tests, this sources fake_env.sh and drives
# bin/sciebo end to end through the real rclone and curl, so each assertion
# exercises the actual HTTP/XML parsing path. Covers the read-only server and
# account facts plus the Nextcloud commands that talk to the fake server's OCS
# and DAV surface: shares, activity, comments, favorites, tags, locks, quota,
# search, recent, and the trashbin listing. The EXIT trap installed by
# fake_server_start stops the server and then runs env.sh's temp-dir cleanup.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

command -v python3 >/dev/null 2>&1 || {
  echo "SKIP: python3 not installed"
  exit 0
}

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../fake_env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../fake_env.sh"

fake_server_start || {
  echo "SKIP: fake server did not start"
  exit 0
}

# A small tree mirrors what a synced account would hold: the remote base
# ("backup", like env.sh) for rclone-backed commands (recent, locks) and a
# files-root copy for the DAV commands addressed below it (comments,
# favorites, tags).
mkdir -p "${FAKE_STATE}/backup/notes" "${FAKE_STATE}/notes"
printf 'root report\n' >"${FAKE_STATE}/report.txt"
printf 'root plan\n' >"${FAKE_STATE}/notes/plan.txt"
printf 'backup report\n' >"${FAKE_STATE}/backup/report.txt"
printf 'backup plan\n' >"${FAKE_STATE}/backup/notes/plan.txt"

# --- server capabilities / info --------------------------------------------
expect_cli "server capabilities rc 0" 0 fake_cli server capabilities
expect_contains "server capabilities version" "$CLI_OUT" "server: Nextcloud 34.0.0"
expect_contains "server capabilities chunking" "$CLI_OUT" "chunked uploads: enabled (max chunk 10Mi)"
expect_contains "server capabilities trashbin" "$CLI_OUT" "trashbin: available"
expect_contains "server capabilities checksums" "$CLI_OUT" "checksums: available"

expect_cli "server info rc 0" 0 fake_cli server info
expect_contains "server info url" "$CLI_OUT" "SERVER: ${FAKE_BASE}"
expect_contains "server info user" "$CLI_OUT" "USER: alice"
expect_contains "server info version" "$CLI_OUT" "VERSION: 34.0.0"
expect_contains "server info chunking" "$CLI_OUT" "CHUNKING: enabled (max chunk 10Mi)"
expect_contains "server info trashbin" "$CLI_OUT" "TRASHBIN: available"
expect_contains "server info checksums" "$CLI_OUT" "CHECKSUMS: available"

# --- account info (user + rclone about quota) -------------------------------
expect_cli "account info rc 0" 0 fake_cli account info
expect_contains "account info id" "$CLI_OUT" "alice"
expect_contains "account info display name" "$CLI_OUT" "DISPLAY NAME    User"
expect_contains "account info email" "$CLI_OUT" "EMAIL           user@example.org"
expect_contains "account info server version" "$CLI_OUT" "SERVER VERSION  34.0.0"
expect_contains "account info quota" "$CLI_OUT" "QUOTA           Total:"

expect_cli "account info --json rc 0" 0 fake_cli account info --json
expect_contains "account info json id" "$CLI_OUT" '"id": "alice"'
expect_contains "account info json email" "$CLI_OUT" '"email": "user@example.org"'
expect_contains "account info json version" "$CLI_OUT" '"server_version": "34.0.0"'

# --- quota (rclone about, fed by the files-root quota properties) -----------
expect_cli "quota rc 0" 0 fake_cli quota
expect_contains "quota total" "$CLI_OUT" "Total:"
expect_contains "quota free" "$CLI_OUT" "Free:"
expect_cli "quota --json rc 0" 0 fake_cli quota --json
expect_contains "quota json free" "$CLI_OUT" '"free":'

# --- share list (create a user share first) ---------------------------------
expect_cli "share user rc 0" 0 fake_cli share user report.txt bob
expect_contains "share user created" "$CLI_OUT" "created share"
expect_cli "share list rc 0" 0 fake_cli share list
expect_contains "share list header" "$CLI_OUT" "Path-or-URL"
expect_contains "share list recipient" "$CLI_OUT" "bob"
expect_contains "share list path" "$CLI_OUT" "/backup/report.txt"

# --- activity ---------------------------------------------------------------
expect_cli "activity rc 0" 0 fake_cli activity --limit 3
expect_contains "activity newest" "$CLI_OUT" "Changed file note-125.txt"
expect_contains "activity older" "$CLI_OUT" "Changed file note-124.txt"

# --- comments (add then list the live response) -----------------------------
expect_cli "comments add rc 0" 0 fake_cli comments notes/plan.txt add "live comment"
expect_contains "comments add" "$CLI_OUT" "added comment"
expect_cli "comments list rc 0" 0 fake_cli comments notes/plan.txt
expect_contains "comments header" "$CLI_OUT" "Message"
expect_contains "comments message" "$CLI_OUT" "live comment"

# --- favorites --------------------------------------------------------------
expect_cli "favorites add rc 0" 0 fake_cli favorites add notes/plan.txt
expect_contains "favorites add" "$CLI_OUT" "favorited notes/plan.txt"
expect_cli "favorites list rc 0" 0 fake_cli favorites
expect_contains "favorites path" "$CLI_OUT" "notes/plan.txt"

# --- tags -------------------------------------------------------------------
expect_cli "tags create rc 0" 0 fake_cli tags create urgent
expect_contains "tags create" "$CLI_OUT" "created tag"
expect_cli "tags list rc 0" 0 fake_cli tags
expect_contains "tags display name" "$CLI_OUT" "urgent"
expect_cli "tags assign rc 0" 0 fake_cli tags assign notes/plan.txt 1
expect_contains "tags assign" "$CLI_OUT" "tagged notes/plan.txt with 1"

# --- lock / locks / unlock --------------------------------------------------
expect_cli "lock rc 0" 0 fake_cli lock notes/plan.txt
expect_contains "lock message" "$CLI_OUT" "locked notes/plan.txt"
expect_cli "locks rc 0" 0 fake_cli locks
expect_contains "locks path" "$CLI_OUT" "notes/plan.txt"
expect_contains "locks token" "$CLI_OUT" "opaquelocktoken:"
expect_cli "unlock rc 0" 0 fake_cli unlock notes/plan.txt
expect_contains "unlock message" "$CLI_OUT" "unlocked notes/plan.txt"

# --- search / recent --------------------------------------------------------
expect_cli "search rc 0" 0 fake_cli search report
expect_contains "search title" "$CLI_OUT" "report.txt"
expect_contains "search subline" "$CLI_OUT" "/backup/report.txt"

expect_cli "recent rc 0" 0 fake_cli recent
expect_contains "recent plan" "$CLI_OUT" "notes/plan.txt"

# --- trash listing (seeded through the fake server hook) --------------------
fake_seed --data-urlencode what=trash >/dev/null
expect_cli "trash rc 0" 0 fake_cli trash
expect_contains "trash original name" "$CLI_OUT" "plan.txt"
expect_contains "trash original location" "$CLI_OUT" "notes/plan.txt"

finish
