#!/usr/bin/env bash
# rclone.sh - remote_spec, config introspection, rclone discovery, remote_is_nextcloud, filter excludes (lib/rclone.sh).
# Sourced setup lives in tests/unit/common.sh; run standalone with
# `bash tests/unit/rclone.sh`.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# --- remote_spec --------------------------------------------------------
REMOTE_PREFIX="sciebo:backup"
expect_eq "remote_spec: subpath joined" "sciebo:backup/notes" "$(remote_spec "notes")"
expect_eq "remote_spec: empty subpath" "sciebo:backup/" "$(remote_spec "")"

# --- config_value (config show block) -----------------------------------
config_show='[sciebo]
type = webdav
url = https://cloud.example.org/remote.php/dav/files/alice/
user = alice@example.org
pass = *** ENCRYPTED ***
tight=value
spaced   =   padded
tabbed	=	tab
notype = nope'
while IFS='|' read -r name key want; do
  expect_eq "$name" "$want" "$(config_value "$key" "$config_show")"
done <<'EOF'
config_value: type|type|webdav
config_value: url|url|https://cloud.example.org/remote.php/dav/files/alice/
config_value: user|user|alice@example.org
config_value: missing key is empty|nope|
config_value: no spaces around equals|tight|value
config_value: padded value is trimmed|spaced|padded
config_value: tab around equals|tabbed|tab
config_value: key must start the line|type|webdav
config_value: suffix key is not a match|ype|
EOF

# --- config_dump_value (rclone config dump pretty JSON) -----------------
# Exact `rclone config dump` shape: four-space indent, sorted keys, and no
# trailing comma on the last key of a block.
config_dump='{
    "alpha": {
        "pass": "obscured-alpha",
        "type": "webdav",
        "url": "https://cloud.example.org/remote.php/dav/files/Alice Smith/",
        "user": "alice@example.org"
    },
    "beta": {
        "pass": "obscured-beta"
    }
}'
while IFS='|' read -r name remote key want; do
  expect_eq "$name" "$want" "$(config_dump_value "$remote" "$key" "$config_dump")"
done <<'EOF'
config_dump_value: pass|alpha|pass|obscured-alpha
config_dump_value: url with spaces|alpha|url|https://cloud.example.org/remote.php/dav/files/Alice Smith/
config_dump_value: missing key is empty|alpha|nope|
config_dump_value: second remote does not leak|beta|pass|obscured-beta
config_dump_value: last key without trailing quote|alpha|user|alice@example.org
EOF

# --- rclone discovery ---------------------------------------------------
# RCLONE_BIN that is executable wins; a missing one falls through to the
# candidate list. The test binary is a stub, so no rclone is required.
stub_rclone="${TMP}/stub-rclone"
printf '#!/bin/bash\nexit 0\n' >"$stub_rclone"
chmod +x "$stub_rclone"
RCLONE_BIN="$stub_rclone"
expect_eq "find_rclone: executable RCLONE_BIN wins" "$stub_rclone" "$(find_rclone)"
expect_ok "rclone_available: executable RCLONE_BIN is available" rclone_available
RCLONE_BIN="${TMP}/does-not-exist"
if command -v rclone >/dev/null 2>&1 || [[ -x /opt/homebrew/bin/rclone || -x /usr/local/bin/rclone ]]; then
  expect_ok "rclone_available: falls back to PATH or Homebrew" rclone_available
else
  expect_err "rclone_available: nothing found" rclone_available
fi
RCLONE_BIN=""

# --- remote_is_nextcloud memoization ------------------------------------
# A stub rclone counts `config show` invocations; the memo (positive and
# negative) must keep it to one call until remote_config_invalidate clears
# it. REMOTE_CONFIG_SHOW_CACHE is cleared between calls so only the
# remote_is_nextcloud memo can prevent the second rclone invocation.
NEXTCLOUD_STUB="${TMP}/stub-rclone-nextcloud"
NEXTCLOUD_CALLS="${TMP}/rclone-nextcloud.calls"
NEXTCLOUD_SHOW="${TMP}/nextcloud-show.conf"
cat >"$NEXTCLOUD_STUB" <<STUB
#!/bin/bash
printf 'call\n' >>"${NEXTCLOUD_CALLS}"
cat "${NEXTCLOUD_SHOW}"
STUB
chmod +x "$NEXTCLOUD_STUB"
saved_rclone_bin="${RCLONE_BIN:-}"
saved_rclone_config="${RCLONE_CONFIG:-}"
saved_rclone_remote="${RCLONE_REMOTE:-}"
RCLONE_BIN="$NEXTCLOUD_STUB"
RCLONE_CONFIG="${TMP}/nextcloud-rclone.conf"
RCLONE_REMOTE="testremote"
printf '[testremote]\ntype = webdav\nurl = https://cloud.example.org/remote.php/dav/files/alice/\n' >"$NEXTCLOUD_SHOW"
rm -f "$NEXTCLOUD_CALLS"
REMOTE_CONFIG_SHOW_CACHE=""
REMOTE_IS_NEXTCLOUD_CACHE=""
expect_ok "remote_is_nextcloud: nextcloud url is detected" remote_is_nextcloud
REMOTE_CONFIG_SHOW_CACHE=""
expect_ok "remote_is_nextcloud: cached second call still true" remote_is_nextcloud
expect_eq "remote_is_nextcloud: positive result memoized to one call" "1" "$(wc -l <"$NEXTCLOUD_CALLS" | tr -d ' ')"
remote_config_invalidate
expect_ok "remote_is_nextcloud: invalidate re-resolves" remote_is_nextcloud
expect_eq "remote_is_nextcloud: one call after invalidation" "2" "$(wc -l <"$NEXTCLOUD_CALLS" | tr -d ' ')"
printf '[testremote]\ntype = webdav\nurl = https://cloud.example.org/index.php\n' >"$NEXTCLOUD_SHOW"
rm -f "$NEXTCLOUD_CALLS"
REMOTE_CONFIG_SHOW_CACHE=""
REMOTE_IS_NEXTCLOUD_CACHE=""
expect_err "remote_is_nextcloud: non-nextcloud url is rejected" remote_is_nextcloud
REMOTE_CONFIG_SHOW_CACHE=""
expect_err "remote_is_nextcloud: cached negative result still false" remote_is_nextcloud
expect_eq "remote_is_nextcloud: negative result memoized to one call" "1" "$(wc -l <"$NEXTCLOUD_CALLS" | tr -d ' ')"
RCLONE_BIN="$saved_rclone_bin"
RCLONE_CONFIG="$saved_rclone_config"
RCLONE_REMOTE="$saved_rclone_remote"
REMOTE_CONFIG_SHOW_CACHE=""
REMOTE_IS_NEXTCLOUD_CACHE=""

# --- rclone_filter_excludes (forkless blacklist capture) --------------------
# Production callers are sync and ignored; drive the rclone.sh helper
# directly so the forkless blacklist_excluded capture stays covered.
bl_unit_dir="${TMP}/bl-unit"
mkdir -p "$bl_unit_dir"
BLACKLIST_DIR="$bl_unit_dir"
printf '3\tx.txt\tdenied\n' >"${bl_unit_dir}/exsrc"
saved_conflict_upload="${CONFLICT_UPLOAD:-}" saved_skip_hidden="${SKIP_HIDDEN:-}"
CONFLICT_UPLOAD=1 SKIP_HIDDEN=1
ex_args=()
rclone_filter_excludes ex_args exsrc sciebo 2>"${TMP}/bl-unit-warn.txt"
# CONFLICT_UPLOAD=1 suppresses the conflict-copy exclusion; SKIP_HIDDEN=1 is
# the feature toggle that ADDS the dotfile exclusion; one blacklisted path
# follows: two --exclude pairs.
expect_eq "rclone_filter_excludes: conflict suppressed, dotfile+blacklist kept" "4" "${#ex_args[@]}"
expect_eq "rclone_filter_excludes: --exclude flag appended" "--exclude" "${ex_args[0]:-}"
expect_eq "rclone_filter_excludes: dotfile exclusion follows SKIP_HIDDEN=1" ".*" "${ex_args[1]:-}"
expect_eq "rclone_filter_excludes: blacklisted pattern appended last" "/x.txt" "${ex_args[3]:-}"
expect_contains "rclone_filter_excludes: warns once with the retry hint" \
  "$(cat "${TMP}/bl-unit-warn.txt")" "run 'sciebo retry exsrc' to try them again"
ex_args=()
rclone_filter_excludes ex_args nosuchsrc sciebo 2>/dev/null
expect_eq "rclone_filter_excludes: no record keeps only the flag layers" "2" "${#ex_args[@]}"
if [[ -z "$saved_conflict_upload" ]]; then unset CONFLICT_UPLOAD; else CONFLICT_UPLOAD="$saved_conflict_upload"; fi
if [[ -z "$saved_skip_hidden" ]]; then unset SKIP_HIDDEN; else SKIP_HIDDEN="$saved_skip_hidden"; fi
unset BLACKLIST_DIR
rm -rf "$bl_unit_dir"

finish
