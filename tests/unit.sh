#!/bin/bash
# unit.sh - unit tests for the sciebo libraries (rclone is not required).
# Run from any directory: /bin/bash tests/unit.sh
#
# Isolation: every path is redirected into a fresh mktemp directory; the
# real config, state, HOME, rclone config, sciebo and launchd are never
# touched. Settings precedence runs in clean subprocesses.
set -uo pipefail
UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${UNIT_DIR}/.." && pwd)"
LIB_DIR="${PROJ_DIR}/lib"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=harness.sh
source "${UNIT_DIR}/harness.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/core.sh
source "${LIB_DIR}/core.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/rclone.sh
source "${LIB_DIR}/rclone.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/settings.sh
source "${LIB_DIR}/settings.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/lock.sh
source "${LIB_DIR}/lock.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/manifest.sh
source "${LIB_DIR}/manifest.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/ui.sh
source "${LIB_DIR}/ui.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/sciebo-unit.XXXXXX")"
export SETTINGS_FILE="${PROJ_DIR}/config/settings.env" \
  SETTINGS_LOCAL_FILE="${TMP}/settings.local.absent.env" ENV_FILE="${TMP}/env.absent.env" \
  STATE_DIR="${TMP}/state" MANIFEST_FILE="${TMP}/sources.conf" \
  MANIFEST_GENERATED_FILE="${TMP}/sources.generated.conf" FOLDERS_FILE="${TMP}/folders.conf" \
  FILTER_DIR="${TMP}/filters"
mkdir -p "$FILTER_DIR"

# Derived state paths (LOG_DIR/LOCK_DIR/BISYNC_DIR) stay unset here so the
# settings probes observe the libraries' defaults.
BG_PID=""
# shellcheck disable=SC2329  # invoked through the EXIT trap
cleanup() {
  if [[ -n "$BG_PID" ]]; then
    kill "$BG_PID" 2>/dev/null || true
    wait "$BG_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT
printf 'sciebo unit tests (%s)\n' "$PROJ_DIR"

# expect_run NAME WANT_RC CMD... - pass when CMD exits WANT_RC (globals it
# sets stay visible to the caller).
expect_run() {
  local name="$1" want="$2" rc=0
  shift 2
  "$@" >/dev/null 2>&1 || rc=$?
  expect_rc "$name" "$rc" "$want"
}

# expect_ok/expect_err NAME CMD... - pass when CMD exits 0/non-zero.
expect_ok() { expect_run "$1" 0 "${@:2}"; }
expect_err() { expect_run "$1" 1 "${@:2}"; }
file_mode() { stat -f '%Lp' "$1" 2>/dev/null || true; }

# settings_probe VAR [ENV=...]... - print VAR after load_settings --no-rclone
# in a clean subprocess; die output and rc are preserved.
settings_probe() {
  local var="$1"
  shift
  # shellcheck disable=SC2016  # the -c program expands "$1"/"$2" itself
  env "$@" /bin/bash -c '
    set -uo pipefail
    source "$1/lib/core.sh"
    source "$1/lib/settings.sh"
    load_settings --no-rclone
    printf "%s" "${!2}"
  ' sciebo-unit-probe "$PROJ_DIR" "$var" 2>&1
}

# probe_case RC_NAME VALUE_NAME VAR RC_WANT MODE WANT [ENV=...]...
probe_case() {
  local rc_name="$1" value_name="$2" var="$3" rc_want="$4" mode="$5" want="$6"
  shift 6
  local out="" rc=0
  out="$(settings_probe "$var" "$@")" || rc=$?
  expect_rc "$rc_name" "$rc" "$rc_want"
  if [[ "$mode" == eq ]]; then
    expect_eq "$value_name" "$want" "$out"
  else
    expect_contains "$value_name" "$out" "$want"
  fi
}

# write_filter_probe NAME SUB EXCLUDES... - combined output of
# manifest_write_pair_filter run in a clean subprocess.
write_filter_probe() {
  local name="$1" sub="$2"
  shift 2
  # shellcheck disable=SC2016  # the -c program expands "$1" itself
  env FILTER_DIR="$FILTER_DIR" /bin/bash -c '
    set -uo pipefail
    source "$1/lib/core.sh"
    source "$1/lib/manifest.sh"
    manifest_write_pair_filter "$2" "$3" "${@:4}"
  ' probe "$PROJ_DIR" "$name" "$sub" "$@" 2>&1
}

# lock_probe - acquire_lock in a clean subprocess against this shell's lock
# dirs (combined output; same rc).
lock_probe() {
  # shellcheck disable=SC2016  # the -c program expands "$1" itself
  env STATE_DIR="$STATE_DIR" LOG_DIR="$LOG_DIR" LOCK_DIR="$LOCK_DIR" BISYNC_DIR="$BISYNC_DIR" \
    /bin/bash -c '
      set -uo pipefail
      source "$1/lib/core.sh"
      source "$1/lib/settings.sh"
      source "$1/lib/lock.sh"
      acquire_lock
    ' lock-probe "$PROJ_DIR" 2>&1
}

# --- pure string helpers: trim / printable / sanitize_name / expand -----
while IFS='|' read -r name fn input want; do
  expect_eq "$name" "$want" "$("$fn" "$(printf '%b' "$input")")"
done <<EOF
trim: surrounding spaces|trim|  a  |a
trim: surrounding tabs|trim|\t a b \t|a b
trim: internal spacing kept|trim|a  b|a  b
trim: all whitespace becomes empty|trim|   |
trim: empty stays empty|trim||
printable: strips tab and carriage return|printable|a\tb\rc|abc
printable: strips ESC from escapes|printable|\033[31mred|[31mred
printable: plain text unchanged|printable|hello world|hello world
sanitize_name: slash becomes underscore|sanitize_name|repos/my-app|repos_my-app
sanitize_name: leading dots stripped|sanitize_name|.hidden|hidden
sanitize_name: leading underscores stripped|sanitize_name|__a|a
sanitize_name: double underscores collapsed|sanitize_name|a__b|a_b
sanitize_name: runs collapsed and edges trimmed|sanitize_name|__a__b__|a_b
sanitize_name: all-invalid input becomes empty|sanitize_name|!!!|
sanitize_name: trailing underscore stripped|sanitize_name|foo/|foo
expand_local_path: bare tilde|expand_local_path|~|$HOME
expand_local_path: tilde path|expand_local_path|~/x|$HOME/x
expand_local_path: absolute unchanged|expand_local_path|/abs/path|/abs/path
expand_local_path: relative under PROJECT_DIR|expand_local_path|rel/dir|$PROJECT_DIR/rel/dir
EOF
expect_eq "entry_name_for: empty fallback" "entry" "$(entry_name_for '///')"
expect_eq "entry_name_for: sanitized remote" "repos_my-app" "$(entry_name_for 'repos/my-app')"

# --- safe_remote_path ---------------------------------------------------
while IFS=@ read -r name input want; do
  input="$(printf '%b' "$input")"
  if [[ "$want" == ok ]]; then expect_ok "$name" safe_remote_path "$input"; else expect_err "$name" safe_remote_path "$input"; fi
done <<'EOF'
safe_remote_path: accepts a@a@ok
safe_remote_path: accepts a/b@a/b@ok
safe_remote_path: accepts repos/my-app@repos/my-app@ok
safe_remote_path: rejects empty@@err
safe_remote_path: rejects absolute@/abs@err
safe_remote_path: rejects ..@a/../b@err
safe_remote_path: rejects |@a|b@err
safe_remote_path: rejects leading space@ a@err
safe_remote_path: rejects trailing space@a @err
safe_remote_path: rejects embedded tab@a\tb@err
EOF

# --- manifest_parse_line ------------------------------------------------
# Fields are separated by "@" (the manifest lines themselves use "|"); the
# line goes through printf %b so "\t" can encode a control byte. The
# documented style pads fields with spaces, so each field is trimmed.
printf '# test filter\n' >"${FILTER_DIR}/clutter.txt"
while IFS=@ read -r name line rc_want want_mode want_local want_remote want_filter want_name; do
  rc=0
  manifest_parse_line "$(printf '%b' "$line")" || rc=$?
  expect_rc "${name}: rc" "$rc" "$rc_want"
  if [[ "$rc_want" -eq 0 ]]; then
    expect_eq "${name}: mode" "$want_mode" "$ENTRY_MODE"
    expect_eq "${name}: local" "$want_local" "$ENTRY_LOCAL"
    expect_eq "${name}: remote" "$want_remote" "$ENTRY_REMOTE"
    expect_eq "${name}: filter" "$want_filter" "$ENTRY_FILTER"
    expect_eq "${name}: name" "$want_name" "$ENTRY_NAME"
    expect_eq "${name}: no error" "" "$ENTRY_ERROR"
  elif [[ "$want_mode" != "-" ]]; then
    expect_contains "${name}: error" "$ENTRY_ERROR" "$want_mode"
  fi
done <<EOF
parse: 3-field sync entry@sync|/tmp/src|repos/my-app@0@sync@/tmp/src@repos/my-app@@repos_my-app
parse: tilde local path expands@pull|~/src|notes@0@pull@$HOME/src@notes@@notes
parse: relative local path expands@bisync|rel/dir|notes@0@bisync@$PROJECT_DIR/rel/dir@notes@@notes
parse: 4-field entry with filter@sync|/tmp/src|notes|clutter.txt@0@sync@/tmp/src@notes@clutter.txt@notes
parse: spaced fields trimmed@sync | /tmp/src | notes@0@sync@/tmp/src@notes@@notes
parse: remote field padding trimmed@sync|/tmp/src| notes @0@sync@/tmp/src@notes@@notes
parse: unknown mode@bogus|/tmp/src|notes@1@unknown mode
parse: empty local@sync||notes@1@empty local
parse: empty remote@sync|/tmp/src|@1@unsafe remote
parse: absolute remote@sync|/tmp/src|/abs@1@unsafe remote
parse: .. remote@sync|/tmp/src|a/../b@1@unsafe remote
parse: pipe in remote (4 fields)@sync|/tmp/src|a|b@1@-
parse: pipe in remote (5 fields)@sync|/tmp/src|a|b|c@1@too many fields
parse: five fields@sync|/tmp/src|notes|x|y@1@too many fields
parse: control byte in remote@sync|/tmp/src|a\tb@1@unsafe remote
parse: missing filter file@sync|/tmp/src|notes|nope.txt@1@missing filter file
EOF

# --- manifest_lines -----------------------------------------------------
printf '# comment line\n\nsync|/tmp/src|repos/my-app\n   \n  # indented comment\npull|/tmp/other|notes\n' >"$MANIFEST_FILE"
: >"$FOLDERS_FILE"
: >"$MANIFEST_GENERATED_FILE"
expect_eq "manifest_lines: blank and comment lines ignored" \
  "$(printf 'sync|/tmp/src|repos/my-app\npull|/tmp/other|notes')" \
  "$(manifest_lines)"

# --- manifest index and duplicates --------------------------------------
printf 'sync|/tmp/src|repos/my-app\npull|/tmp/pulled|notes\n\npull|/tmp/other|repos_my-app\n' >"$MANIFEST_FILE"
printf 'sync|/tmp/wizard|notes\nbisync|/tmp/bisync|unique-thing\n' >"$FOLDERS_FILE"
: >"$MANIFEST_GENERATED_FILE"
manifest_index_invalidate
expect_ok "manifest_has_name: sanitized duplicate" manifest_has_name "repos_my-app"
expect_ok "manifest_has_name: notes" manifest_has_name "notes"
expect_ok "manifest_has_name: unique" manifest_has_name "unique-thing"
expect_err "manifest_has_name: unknown" manifest_has_name "missing"
expect_ok "manifest_has_remote: repos/my-app" manifest_has_remote "repos/my-app"
expect_ok "manifest_has_remote: notes" manifest_has_remote "notes"
expect_err "manifest_has_remote: unknown" manifest_has_remote "missing"
expect_ok "manifest_has_duplicate_name: repos_my-app" manifest_has_duplicate_name "repos_my-app"
expect_ok "manifest_has_duplicate_name: notes" manifest_has_duplicate_name "notes"
expect_err "manifest_has_duplicate_name: unique" manifest_has_duplicate_name "unique-thing"
expect_ok "manifest_has_duplicate_remote: notes" manifest_has_duplicate_remote "notes"
expect_err "manifest_has_duplicate_remote: repos/my-app" manifest_has_duplicate_remote "repos/my-app"

# The index is cached; after the duplicates are removed and the cache is
# invalidated the answers must change.
printf 'sync|/tmp/src|repos/my-app\n' >"$MANIFEST_FILE"
manifest_index_invalidate
expect_err "manifest_has_duplicate_name: refreshed after invalidate" manifest_has_duplicate_name "repos/my-app"
expect_err "manifest_has_duplicate_remote: refreshed after invalidate" manifest_has_duplicate_remote "notes"

# --- manifest_remove_pair -----------------------------------------------
expect_run "manifest_remove_pair: present entry rc 0" 0 manifest_remove_pair "unique-thing"
expect_not_contains "manifest_remove_pair: matching line dropped" "$(cat "$FOLDERS_FILE")" "unique-thing"
expect_contains "manifest_remove_pair: other line kept" "$(cat "$FOLDERS_FILE")" "sync|/tmp/wizard|notes"
cp "$FOLDERS_FILE" "${TMP}/folders.saved"
expect_run "manifest_remove_pair: absent entry rc 1" 1 manifest_remove_pair "nope"
expect_same "manifest_remove_pair: absent entry leaves file unchanged" "${TMP}/folders.saved" "$FOLDERS_FILE"

# --- manifest_append_pair -----------------------------------------------
FOLDERS_FILE="${TMP}/append.conf"
rm -f "$FOLDERS_FILE"
manifest_append_pair "sync" "/tmp/local" "my-sub"
expect_file "manifest_append_pair: creates the file" "$FOLDERS_FILE"
content="$(cat "$FOLDERS_FILE")"
expect_contains "manifest_append_pair: seeds the wizard header" "$content" "# Folders chosen with the folder wizard"
expect_contains "manifest_append_pair: pair line written" "$content" "sync|/tmp/local|my-sub"
printf 'pull|/tmp/x|old' >"$FOLDERS_FILE"
manifest_append_pair "bisync" "/tmp/y" "new-sub" "clutter.txt"
content="$(cat "$FOLDERS_FILE")"
expect_contains "manifest_append_pair: preserves existing bytes" "$content" "pull|/tmp/x|old"
expect_contains "manifest_append_pair: adds missing newline before append" "$content" "bisync|/tmp/y|new-sub|clutter.txt"
expect_eq "manifest_append_pair: one line per entry" "2" "$(wc -l <"$FOLDERS_FILE" | tr -d ' ')"

# --- manifest_write_pair_filter -----------------------------------------
MANIFEST_PAIR_FILTER=""
expect_run "manifest_write_pair_filter: rc 0" 0 manifest_write_pair_filter "my-pair" "my-sub" "build" "dist/"
expect_eq "manifest_write_pair_filter: sets file name" "pair-my-pair.txt" "$MANIFEST_PAIR_FILTER"
expect_file "manifest_write_pair_filter: creates file" "${FILTER_DIR}/pair-my-pair.txt"
pair_content="$(cat "${FILTER_DIR}/pair-my-pair.txt")"
expect_contains "manifest_write_pair_filter: header written" "$pair_content" "# Pair filter for 'my-sub'"
expect_contains "manifest_write_pair_filter: exclude rule written" "$pair_content" "- build/"
expect_contains "manifest_write_pair_filter: trailing slash normalized" "$pair_content" "- dist/"
cp "${FILTER_DIR}/pair-my-pair.txt" "${TMP}/pair.saved"
expect_run "manifest_write_pair_filter: same content is idempotent" 0 manifest_write_pair_filter "my-pair" "my-sub" "build" "dist/"
expect_same "manifest_write_pair_filter: idempotent run keeps bytes" "${TMP}/pair.saved" "${FILTER_DIR}/pair-my-pair.txt"
printf 'manual\n' >"${FILTER_DIR}/pair-conflict.txt"
out="$(write_filter_probe conflict sub build)"
rc=$?
expect_rc "manifest_write_pair_filter: conflict dies rc 1" "$rc" 1
expect_contains "manifest_write_pair_filter: conflict message" "$out" "different content"
expect_eq "manifest_write_pair_filter: conflict leaves file untouched" "manual" "$(cat "${FILTER_DIR}/pair-conflict.txt")"
out="$(write_filter_probe invalid-pair sub ../evil)"
rc=$?
expect_rc "manifest_write_pair_filter: unsafe exclude dies rc 1" "$rc" 1
expect_contains "manifest_write_pair_filter: unsafe exclude message" "$out" "invalid exclude"

# --- remote_spec --------------------------------------------------------
REMOTE_PREFIX="sciebo:backup"
expect_eq "remote_spec: subpath joined" "sciebo:backup/notes" "$(remote_spec "notes")"
expect_eq "remote_spec: empty subpath" "sciebo:backup/" "$(remote_spec "")"

# --- ui_parse_selection -------------------------------------------------
out="$(ui_parse_selection '3,1,3,1' 5)"
rc=$?
expect_rc "ui_parse_selection: duplicates rc" "$rc" 0
expect_eq "ui_parse_selection: duplicates deduped and ordered" "$(printf '1\n3')" "$out"
while IFS='|' read -r name input max want rc_want; do
  rc=0
  out="$(ui_parse_selection "$input" "$max")" || rc=$?
  if [[ "$rc_want" -eq 0 ]]; then
    expect_rc "${name} rc" "$rc" 0
    expect_eq "$name" "$(printf '%b' "$want")" "$out"
  else
    expect_rc "$name" "$rc" 1
  fi
done <<'EOF'
ui_parse_selection: '1 3'|1 3|5|1\n3|0
ui_parse_selection: '1,3'|1,3|5|1\n3|0
ui_parse_selection: '5-7'|5-7|7|5\n6\n7|0
ui_parse_selection: 'all'|all|3|1\n2\n3|0
ui_parse_selection: '0' invalid rc 1|0|5||1
ui_parse_selection: out of range invalid rc 1|4|3||1
ui_parse_selection: inverted range invalid rc 1|7-5|7||1
ui_parse_selection: non-numeric invalid rc 1|x|5||1
ui_parse_selection: empty invalid rc 1||5||1
EOF

# --- config_value (config show block) -----------------------------------
config_show='[sciebo]
type = webdav
url = https://cloud.example.org/remote.php/dav/files/alice/
user = alice@example.org
pass = *** ENCRYPTED ***'
while IFS='|' read -r name key want; do
  expect_eq "$name" "$want" "$(config_value "$key" "$config_show")"
done <<'EOF'
config_value: type|type|webdav
config_value: url|url|https://cloud.example.org/remote.php/dav/files/alice/
config_value: user|user|alice@example.org
config_value: missing key is empty|nope|
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

# --- settings precedence (subprocesses) ---------------------------------
SETTINGS_ENV="${TMP}/settings.env"
cp "${PROJ_DIR}/config/settings.env" "$SETTINGS_ENV"
NO_LOCAL="${TMP}/settings.local.absent.env"
SETTINGS_STATE="${TMP}/state-settings"
LOCAL_ENV="${TMP}/settings.local.env"
printf 'REMOTE_BASE="localbase"\n' >"$LOCAL_ENV"
export SETTINGS_FILE="$SETTINGS_ENV" SETTINGS_LOCAL_FILE="$NO_LOCAL" STATE_DIR="$SETTINGS_STATE"
probe_case "settings: env override rc 0" "settings: environment beats settings.env" \
  REMOTE_BASE 0 eq envbase REMOTE_BASE=envbase
probe_case "settings: local override rc 0" "settings: settings.local.env plain assignment beats env" \
  REMOTE_BASE 0 eq localbase REMOTE_BASE=envbase SETTINGS_LOCAL_FILE="$LOCAL_ENV"
probe_case "settings: derived LOG_DIR rc 0" "settings: LOG_DIR defaults under STATE_DIR" \
  LOG_DIR 0 eq "${SETTINGS_STATE}/logs"
probe_case "settings: derived LOCK_DIR rc 0" "settings: LOCK_DIR defaults under STATE_DIR" \
  LOCK_DIR 0 eq "${SETTINGS_STATE}/locks"
probe_case "settings: explicit LOG_DIR rc 0" "settings: explicit LOG_DIR wins over derivation" \
  LOG_DIR 0 eq "${TMP}/custom-logs" LOG_DIR="${TMP}/custom-logs"
probe_case "settings: empty REMOTE_BASE rc 0" "settings: empty REMOTE_BASE falls back to backup" \
  REMOTE_BASE 0 eq backup REMOTE_BASE=
probe_case "settings: ../ REMOTE_BASE dies rc 1" "settings: ../ REMOTE_BASE message" \
  REMOTE_BASE 1 contains "must be a relative path without '..'" REMOTE_BASE=../x
probe_case "settings: missing SETTINGS_FILE dies rc 1" "settings: missing SETTINGS_FILE message" \
  REMOTE_BASE 1 contains "Missing settings file" SETTINGS_FILE="${TMP}/missing-settings.env"

# --- lock ---------------------------------------------------------------
export STATE_DIR="${TMP}/lock-state" LOG_DIR="${TMP}/lock-state/logs" \
  LOCK_DIR="${TMP}/lock-state/locks" BISYNC_DIR="${TMP}/lock-state/bisync"
rm -rf "${LOCK_DIR}/sync.lock"
expect_run "lock: fresh acquire rc 0" 0 acquire_lock
expect_file "lock: acquire creates pid file" "${LOCK_DIR}/sync.lock/pid"
expect_eq "lock: pid file records this shell" "$$" "$(cat "${LOCK_DIR}/sync.lock/pid")"
release_lock
expect_no_file "lock: release removes the lock dir" "${LOCK_DIR}/sync.lock"
acquire_lock
held="$LOCK_HELD"
expect_run "lock: reentrant acquire rc 0" 0 acquire_lock
expect_eq "lock: reentrant keeps the same lock" "$held" "$LOCK_HELD"
release_lock
mkdir -p "${LOCK_DIR}/sync.lock"
printf '999999\n' >"${LOCK_DIR}/sync.lock/pid"
stale_err="${TMP}/lock-stale.err"
rc=0
acquire_lock 2>"$stale_err" || rc=$?
expect_rc "lock: stale takeover rc 0" "$rc" 0
expect_contains "lock: stale takeover warns" "$(cat "$stale_err")" "Removing stale lock"
expect_eq "lock: stale takeover records this shell" "$$" "$(cat "${LOCK_DIR}/sync.lock/pid")"
release_lock
holder_start "${TMP}/bin/sciebo"
BG_PID="$HOLDER_PID"
holder_wait "$BG_PID" >/dev/null
expect_ok "lock: background holder looks like the tool" _lock_pid_alive "$BG_PID"
mkdir -p "${LOCK_DIR}/sync.lock"
printf '%s\n' "$BG_PID" >"${LOCK_DIR}/sync.lock/pid"
out="$(lock_probe)"
rc=$?
expect_rc "lock: live holder refuses acquire" "$rc" 1
expect_contains "lock: live refusal message" "$out" "Another sync run is active"
expect_eq "lock: live refusal leaves the foreign pid" "$BG_PID" "$(cat "${LOCK_DIR}/sync.lock/pid")"
kill "$BG_PID" 2>/dev/null || true
wait "$BG_PID" 2>/dev/null || true
BG_PID=""
rm -rf "${LOCK_DIR}/sync.lock"
mkdir -p "${LOCK_DIR}/sync.lock"
printf '999998\n' >"${LOCK_DIR}/sync.lock/pid"
LOCK_HELD="${LOCK_DIR}/sync.lock"
out="$(release_lock 2>&1)"
rc=$?
expect_rc "lock: foreign release rc 0" "$rc" 0
expect_contains "lock: foreign release warns" "$out" "Not releasing lock"
expect_file "lock: foreign release keeps the lock" "${LOCK_DIR}/sync.lock/pid"
expect_eq "lock: foreign release keeps the pid" "999998" "$(cat "${LOCK_DIR}/sync.lock/pid")"
rm -rf "${LOCK_DIR}/sync.lock"

# --- atomic_write -------------------------------------------------------
aw="${TMP}/atomic.txt"
printf 'old\n' >"$aw"
printf 'new\n' | atomic_write "$aw" 600
expect_eq "atomic_write: replaces content" "new" "$(cat "$aw")"
expect_eq "atomic_write: mode argument applied" "600" "$(file_mode "$aw")"
expect_eq "atomic_write: no temp file left behind" "" \
  "$(find "$TMP" -maxdepth 1 -name 'atomic.txt.tmp.*' -print -quit)"
printf 'plain\n' | atomic_write "${TMP}/atomic-default.txt"
expect_eq "atomic_write: default mode 644" "644" "$(file_mode "${TMP}/atomic-default.txt")"
printf 'nested\n' | atomic_write "${TMP}/newdir/nested.txt"
expect_eq "atomic_write: creates parent directory" "nested" "$(cat "${TMP}/newdir/nested.txt")"

# --- bisync_initialized ignores dry-run residue -------------------------
mkdir -p "${BISYNC_DIR}/dry-only"
: >"${BISYNC_DIR}/dry-only/notes.path1.lst-dry"
expect_err "bisync_initialized: only *-dry residue is uninitialized" bisync_initialized "dry-only"
mkdir -p "${BISYNC_DIR}/real"
: >"${BISYNC_DIR}/real/notes.path1.lst"
expect_ok "bisync_initialized: real state is initialized" bisync_initialized "real"
expect_err "bisync_initialized: missing directory" bisync_initialized "missing"

# --- config_lines -------------------------------------------------------
cfg="${TMP}/config-lines.conf"
printf '# comment\n\n   \n  # indented comment\nalpha\nbeta gamma\n' >"$cfg"
expect_eq "config_lines: drops comments and blanks" "alpha
beta gamma" "$(config_lines "$cfg")"

# --- opt_parse ----------------------------------------------------------
OPT_only=""
OPT_quiet=""
OPT_exclude=""
OPT_only_SET=""
opt_parse "only:s quiet:b exclude:S" sync "" --only notes --quiet --exclude a --exclude=b
expect_eq "opt_parse: value" "notes" "$OPT_only"
expect_eq "opt_parse: boolean" "1" "$OPT_quiet"
expect_eq "opt_parse: repeatable" "a
b" "$(printf '%s' "$OPT_exclude")"
expect_eq "opt_parse: set marker" "1" "$OPT_only_SET"
opt_parse "only:s" sync "" --help
expect_eq "opt_parse: help flag" "1" "$OPT_HELP"
opt_parse "only:s" sync "" pos1 pos2
expect_eq "opt_parse: positionals" "pos1
pos2" "$(printf '%s' "$OPT_EXTRA")"
opt_err="${TMP}/opt-parse.err"
rc=0
(opt_parse "only:s" sync "" --only) >/dev/null 2>"$opt_err" || rc=$?
expect_rc "opt_parse: missing value exits 2" "$rc" 2
expect_contains "opt_parse: missing value message" "$(cat "$opt_err")" "--only requires a value"
rc=0
(opt_parse "only:s" sync "" --bogus) >/dev/null 2>"$opt_err" || rc=$?
expect_rc "opt_parse: unknown option exits 2" "$rc" 2
expect_contains "opt_parse: unknown option message" "$(cat "$opt_err")" "unknown option: --bogus"

# --- schedule template XML escaping -------------------------------------
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/commands/schedule.sh
source "${LIB_DIR}/commands/schedule.sh"
SCHEDULE_TEMPLATE_FILE="${TMP}/template.plist"
printf '<string>@PROJECT_DIR@</string>\n<string>@LABEL@</string>\n<string>@RCLONE_DIR@</string>\n<string>@LOG_DIR@</string>\n' >"$SCHEDULE_TEMPLATE_FILE"
PROJECT_DIR='/tmp/R&D <x>'
LAUNCHD_LABEL='de.test&x'
SCHEDULE_RCLONE_DIR='/opt/bin'
LOG_DIR='/tmp/logs & more'
rendered="$(schedule_render_template)"
expect_contains "schedule render: project dir escaped" "$rendered" "/tmp/R&amp;D &lt;x&gt;"
expect_contains "schedule render: label escaped" "$rendered" "de.test&amp;x"
expect_contains "schedule render: log dir escaped" "$rendered" "/tmp/logs &amp; more"
expect_not_contains "schedule render: no raw project ampersand" "$rendered" "R&D"
expect_contains "schedule render: placeholders replaced" "$rendered" "/opt/bin"
finish
