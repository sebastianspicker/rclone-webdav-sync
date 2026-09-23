#!/usr/bin/env bash
# unit.sh - unit tests for the sciebo libraries (rclone is not required).
# Run from any directory: bash tests/unit.sh
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
# shellcheck source=../lib/output.sh
source "${LIB_DIR}/output.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/rclone.sh
source "${LIB_DIR}/rclone.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/http.sh
source "${LIB_DIR}/http.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/keychain.sh
source "${LIB_DIR}/keychain.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/capabilities.sh
source "${LIB_DIR}/capabilities.sh"
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
# shellcheck source=../lib/blacklist.sh
source "${LIB_DIR}/blacklist.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/ui.sh
source "${LIB_DIR}/ui.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/pause.sh
source "${LIB_DIR}/pause.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/runstate.sh
source "${LIB_DIR}/runstate.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/notify.sh
source "${LIB_DIR}/notify.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/sciebo-unit.XXXXXX")"
# Route every child/probe temp (e.g. the case-clash scan cache) under TMP so
# the EXIT cleanup removes them, and drop registered temps explicitly.
export TMPDIR="$TMP"
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
  sciebo_temp_cleanup || true
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

# expect_dies NAME CMD... - like expect_err, but in a subshell, so a die
# inside CMD cannot end the test suite.
expect_dies() {
  local name="$1" rc=0
  shift
  ("$@" >/dev/null 2>&1) || rc=$?
  expect_rc "$name" "$rc" 1
}

# settings_probe VAR [ENV=...]... - print VAR after load_settings --no-rclone
# in a clean subprocess; die output and rc are preserved.
settings_probe() {
  local var="$1"
  shift
  # shellcheck disable=SC2016  # the -c program expands "$1"/"$2" itself
  env "$@" bash -c '
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
  env FILTER_DIR="$FILTER_DIR" bash -c '
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
    bash -c '
      set -uo pipefail
      source "$1/lib/core.sh"
      source "$1/lib/settings.sh"
      source "$1/lib/lock.sh"
      acquire_lock
    ' lock-probe "$PROJ_DIR" 2>&1
}

# --- Bash 5.3 shell semantics the rewrite relies on ----------------------
# The rewrite drops the old "call without the array" guards, so an empty
# array must expand safely even though this suite runs under `set -u`.
empty_args=()
expanded=""
expanded="${empty_args[*]}"
expect_eq "bash 5.3: empty array [*] expands under set -u" "" "$expanded"
expect_eq "bash 5.3: empty array count expands under set -u" "0" "${#empty_args[@]}"
empty_argc() { printf '%s' "$#"; }
expect_eq "bash 5.3: empty array [@] expands under set -u" "0" "$(empty_argc "${empty_args[@]}")"

# patsub_replacement is on by default in Bash 5.2+, so `&` in a replacement
# is the matched text; a literal one must be escaped as `\&`.
patsub_v='a&b<c'
patsub_v="${patsub_v//&/\&amp;}"
patsub_v="${patsub_v//</\&lt;}"
expect_eq "bash 5.3: patsub replacement escapes & then <" "a&amp;b&lt;c" "$patsub_v"
patsub_bad='a<b'
patsub_bad="${patsub_bad//</&lt;}"
expect_eq "bash 5.3: unescaped & inserts the matched text" "a<lt;b" "$patsub_bad"

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

# --- safe_local_path / safe_filter_name / strip_trailing_slashes --------
while IFS=@ read -r name input want; do
  input="$(printf '%b' "$input")"
  if [[ "$want" == ok ]]; then expect_ok "$name" safe_local_path "$input"; else expect_err "$name" safe_local_path "$input"; fi
done <<'EOF'
safe_local_path: accepts an absolute path@/tmp/src@ok
safe_local_path: accepts a relative path@rel/dir@ok
safe_local_path: rejects empty@@err
safe_local_path: rejects a pipe@/tmp/a|b@err
safe_local_path: rejects surrounding spaces@ /tmp/src @err
safe_local_path: rejects a control byte@/tmp/a\tb@err
EOF
while IFS=@ read -r name input want; do
  input="$(printf '%b' "$input")"
  if [[ "$want" == ok ]]; then expect_ok "$name" safe_filter_name "$input"; else expect_err "$name" safe_filter_name "$input"; fi
done <<'EOF'
safe_filter_name: accepts a bare name@pair-x.txt@ok
safe_filter_name: rejects empty@@err
safe_filter_name: rejects an absolute path@/etc/passwd@err
safe_filter_name: rejects a subdirectory@sub/x.txt@err
safe_filter_name: rejects traversal@../x.txt@err
EOF
# --- temp_mktemp_into / output_json_escape_into ---------------------------
# Registration must run in the caller's shell; a command-substitution caller
# would lose it and leave a temp file behind on a signal (the bug this covers).
SCIEBO_TEMP_FILES=()
unit_tmp=""
temp_mktemp_into unit_tmp "${TMP}/unit-temp.XXXXXX"
expect_rc "temp_mktemp_into: succeeds" "$?" 0
expect_eq "temp_mktemp_into: registers in the caller" "1" "${#SCIEBO_TEMP_FILES[@]}"
expect_file "temp_mktemp_into: creates the file" "$unit_tmp"
sciebo_temp_cleanup
expect_no_file "temp_mktemp_into: cleanup removes the file" "$unit_tmp"
expect_eq "temp_mktemp_into: cleanup empties the registry" "0" "${#SCIEBO_TEMP_FILES[@]}"

# --- safe_source (descriptor-based, self-contained) ----------------------
# Each call runs in a subshell so a die/set-e inside a sourced file cannot end
# the suite; the subshell prints its rc and the persisted assignment together.
assert_source_probe() {
  local file="$1" rc=0
  (safe_source "$file") >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}

# assert_source_probe_timed FILE - like assert_source_probe, but the probe runs
# in the background and is killed after ~2s, so an open that blocks (a FIFO)
# cannot hang the suite; prints the rc, or 124 when it had to be killed.
assert_source_probe_timed() {
  local file="$1" pid="" rc=0 i=""
  (safe_source "$file") >/dev/null 2>&1 &
  pid=$!
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" || rc=$?
      printf '%s' "$rc"
      return 0
    fi
    sleep 0.1
  done
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  printf '124'
}
ss_env="${TMP}/safe-source.env"
printf 'SS_PERSIST="persisted"\n' >"$ss_env"
chmod 600 "$ss_env"
ss_out="$(
  safe_source "$ss_env"
  printf '%s|%s' "$?" "${SS_PERSIST:-unset}"
)"
expect_eq "safe_source: sources a safe mode-600 file" "0|persisted" "$ss_out"

# A refusal must leave the file's commands unsourced: the marker never appears.
ss_marker="${TMP}/safe-source.marker"
rm -f "$ss_marker"
ss_writable="${TMP}/safe-source-writable.env"
printf 'touch %q\n' "$ss_marker" >"$ss_writable"
chmod 666 "$ss_writable"
expect_rc "safe_source: group/other-writable refused" "$(assert_source_probe "$ss_writable")" 1
expect_no_file "safe_source: writable file not sourced" "$ss_marker"

# The combined descriptor/path stat must parse both modes: either write bit
# alone is refused, while a group-readable (not writable) file is accepted.
ss_group_w="${TMP}/safe-source-group-writable.env"
printf 'SS_GROUP_W="touched"\n' >"$ss_group_w"
chmod 620 "$ss_group_w"
expect_rc "safe_source: group-writable (620) refused" "$(assert_source_probe "$ss_group_w")" 1
ss_other_w="${TMP}/safe-source-other-writable.env"
printf 'SS_OTHER_W="touched"\n' >"$ss_other_w"
chmod 602 "$ss_other_w"
expect_rc "safe_source: other-writable (602) refused" "$(assert_source_probe "$ss_other_w")" 1
ss_group_r="${TMP}/safe-source-group-readable.env"
printf 'SS_GROUP_R="ok"\n' >"$ss_group_r"
chmod 640 "$ss_group_r"
ss_group_out="$(
  safe_source "$ss_group_r"
  printf '%s|%s' "$?" "${SS_GROUP_R:-unset}"
)"
expect_eq "safe_source: group-readable (640) accepted" "0|ok" "$ss_group_out"

ss_safe_marker="${TMP}/safe-source-link.env"
printf 'touch %q\n' "$ss_marker" >"$ss_safe_marker"
chmod 600 "$ss_safe_marker"
ln -sf "$ss_safe_marker" "${TMP}/safe-source-symlink.env"
expect_rc "safe_source: symlink refused" "$(assert_source_probe "${TMP}/safe-source-symlink.env")" 1
expect_no_file "safe_source: symlink target not sourced" "$ss_marker"

# A FIFO is not a regular file: the pre-open check must refuse it immediately
# instead of blocking until a writer appears. The timed probe bounds that.
ss_fifo="${TMP}/safe-source-fifo.env"
rm -f "$ss_fifo"
if mkfifo "$ss_fifo" 2>/dev/null; then
  expect_rc "safe_source: FIFO refused without blocking" "$(assert_source_probe_timed "$ss_fifo")" 1
else
  fail "safe_source: FIFO refused without blocking" "mkfifo unavailable"
fi

ss_broken="${TMP}/safe-source-broken.env"
printf 'if true; then\n' >"$ss_broken"
chmod 600 "$ss_broken"
ss_broken_rc="$(assert_source_probe "$ss_broken")"
ss_broken_nonzero=0
[[ "$ss_broken_rc" -ne 0 ]] && ss_broken_nonzero=1
expect_rc "safe_source: syntax error propagated non-zero" "$ss_broken_nonzero" 1

safe_esc=""
output_json_escape_into safe_esc 'a"b\c'
expect_eq "output_json_escape_into: quotes and backslashes" 'a\"b\\c' "$safe_esc"
output_json_escape_into safe_esc "$(printf 'a\tb')"
expect_eq "output_json_escape_into: tab becomes \\u0009" 'a\u0009b' "$safe_esc"
output_json_escape_into safe_esc "plain"
expect_eq "output_json_escape_into: plain unchanged" "plain" "$safe_esc"

# --- xml_escape_into -----------------------------------------------------
# The shared XML escaper: the default mode escapes the element-body
# metacharacters & < >; the "all" mode also escapes the attribute quote
# characters " and '. Entity spellings must match nc_xml_escape (quotes
# escaped) and schedule_xml_escape (quotes kept).
xml_out=""
xml_escape_into xml_out 'a&b<c>d'
expect_eq "xml_escape_into: default body metacharacters" 'a&amp;b&lt;c&gt;d' "$xml_out"
xml_escape_into xml_out "q\"u'o"
expect_eq "xml_escape_into: default keeps quotes" "q\"u'o" "$xml_out"
xml_escape_into xml_out "a&b<c>d\"e'f" all
expect_eq "xml_escape_into: all escapes quotes too" 'a&amp;b&lt;c&gt;d&quot;e&apos;f' "$xml_out"
xml_escape_into xml_out ''
expect_eq "xml_escape_into: empty stays empty" "" "$xml_out"
xml_escape_into xml_out "'<&>'"
expect_eq "xml_escape_into: default leaves apos and quot alone" "'&lt;&amp;&gt;'" "$xml_out"

# --- curl_key_pass_config_into / _proxy_classify (shared core helpers) -----
# The shared passphrase config writer: escaping, control-byte refusal, and a
# mode-600 temp registered for exit cleanup.
ckp_file=""
curl_key_pass_config_into ckp_file 'a"b\c'
expect_rc "curl_key_pass_config_into: escapes and succeeds" "$?" 0
expect_eq "curl_key_pass_config_into: escaped config line" 'pass = "a\"b\\c"' \
  "$(cat "$ckp_file" 2>/dev/null || true)"
expect_eq "curl_key_pass_config_into: temp mode 600" "600" "$(file_mode "$ckp_file")"
temp_discard "$ckp_file"
curl_key_pass_config_into ckp_file "$(printf 'a\tb')" >/dev/null 2>&1
expect_rc "curl_key_pass_config_into: control byte refused" "$?" 1

# The caller-provided path variant truncates and rewrites in place, so http's
# persistent per-process --config file can be reused.
ckp_path="${TMP}/curl-key-config"
printf 'stale\n' >"$ckp_path"
chmod 600 "$ckp_path"
curl_key_pass_config_into ckp_file "plain" "$ckp_path"
expect_rc "curl_key_pass_config_into: writes into a caller path" "$?" 0
expect_eq "curl_key_pass_config_into: caller path kept" "$ckp_path" "$ckp_file"
expect_eq "curl_key_pass_config_into: caller path rewritten" 'pass = "plain"' \
  "$(cat "$ckp_path" 2>/dev/null || true)"

# netrc_write_into enforces mode 600 on a caller-supplied target too, so a
# loose-mode path cannot be handed the app password.
netrc_target="${TMP}/caller-netrc"
printf 'stale\n' >"$netrc_target"
chmod 644 "$netrc_target"
nw_out=""
netrc_write_into nw_out "https://cloud.example.org/remote.php/dav/files/alice/" alice "secret" "$netrc_target"
expect_rc "netrc_write_into: caller target rc 0" "$?" 0
expect_eq "netrc_write_into: caller target returned" "$netrc_target" "$nw_out"
expect_eq "netrc_write_into: caller target mode enforced 600" "600" "$(file_mode "$netrc_target")"

# _proxy_classify is the single source of the proxy decision the curl and
# rclone resolvers share; assert the class/url/error triple directly.
pc_class="" pc_url="" pc_err=""
_proxy_classify pc_class pc_url pc_err none "" 0
expect_eq "proxy_classify: none" "none||" "${pc_class}|${pc_url}|${pc_err}"
_proxy_classify pc_class pc_url pc_err system "http://p.example:8080" 0
expect_eq "proxy_classify: http(s) is env" "env|http://p.example:8080|" \
  "${pc_class}|${pc_url}|${pc_err}"
_proxy_classify pc_class pc_url pc_err system "socks5://p.example:1080" 0
expect_eq "proxy_classify: socks is flag" "flag|socks5://p.example:1080|" \
  "${pc_class}|${pc_url}|${pc_err}"
_proxy_classify pc_class pc_url pc_err system "" 1
expect_eq "proxy_classify: direct is none" "none||" "${pc_class}|${pc_url}|${pc_err}"
_proxy_classify pc_class pc_url pc_err system "" 0
expect_eq "proxy_classify: unset is none-needed" "none-needed||" \
  "${pc_class}|${pc_url}|${pc_err}"
_proxy_classify pc_class pc_url pc_err http "" 0
expect_eq "proxy_classify: missing PROXY error" \
  "none-needed||PROXY_TYPE=http requires PROXY to be set" \
  "${pc_class}|${pc_url}|${pc_err}"

# --- output_json_kv_bool -------------------------------------------------
# json_bool_probe NAME VALUE [NAME VALUE...] - emit one object with the given
# boolean fields, so the expected bytes stay readable.
json_bool_probe() {
  output_json_begin
  while [[ $# -ge 2 ]]; do
    output_json_kv_bool "$1" "$2"
    shift 2
  done
  output_json_end
}
output_mode_set true
expect_eq "output_json_kv_bool: 1 is true" \
  "$(printf '{\n  "flag": true\n}')" \
  "$(json_bool_probe flag 1)"
expect_eq "output_json_kv_bool: true is true" \
  "$(printf '{\n  "flag": true\n}')" \
  "$(json_bool_probe flag true)"
expect_eq "output_json_kv_bool: 0 is false" \
  "$(printf '{\n  "flag": false\n}')" \
  "$(json_bool_probe flag 0)"
expect_eq "output_json_kv_bool: anything else is false" \
  "$(printf '{\n  "flag": false\n}')" \
  "$(json_bool_probe flag yes)"
expect_eq "output_json_kv_bool: empty is false" \
  "$(printf '{\n  "flag": false\n}')" \
  "$(json_bool_probe flag "")"
expect_eq "output_json_kv_bool: separator between fields" \
  "$(printf '{\n  "a": true,\n  "b": false\n}')" \
  "$(json_bool_probe a 1 b 0)"
output_mode_set false
expect_eq "output_json_kv_bool: respects OUTPUT_JSON=false" "" \
  "$(json_bool_probe flag 1)"

# --- label_bool / print_field --------------------------------------------
expect_eq "label_bool: true is ON" "yes" "$(label_bool true yes no)"
expect_eq "label_bool: 1 is ON" "yes" "$(label_bool 1 yes no)"
expect_eq "label_bool: false is OFF" "no" "$(label_bool false yes no)"
expect_eq "label_bool: 0 is OFF" "no" "$(label_bool 0 yes no)"
expect_eq "label_bool: empty defaults to the OFF word" "no" "$(label_bool "" yes no)"
expect_eq "label_bool: unknown defaults to the OFF word" "no" "$(label_bool maybe yes no)"
expect_eq "label_bool: explicit UNKNOWN can be empty" "" \
  "$(label_bool "" available unavailable "")"
expect_eq "label_bool: explicit UNKNOWN word" "null" \
  "$(label_bool maybe true false null)"
expect_eq "label_bool: paired words for false" "unavailable" \
  "$(label_bool false available unavailable unavailable)"
expect_eq "print_field: value" "NAME: alice" "$(print_field NAME alice)"
expect_eq "print_field: empty shows a dash" "NAME: -" "$(print_field NAME "")"
expect_eq "print_field: missing value shows a dash" "NAME: -" "$(print_field NAME)"

expect_eq "duration_seconds: surrounding spaces" "300" "$(duration_seconds ' 5 ')"

# --- numeric_id / percent_decode / split_positionals / format_size_bytes -
while IFS=@ read -r name input want; do
  if [[ "$want" == ok ]]; then expect_ok "$name" numeric_id "$input"; else expect_err "$name" numeric_id "$input"; fi
done <<'EOF'
numeric_id: accepts digits@123@ok
numeric_id: accepts zero@0@ok
numeric_id: rejects empty@@err
numeric_id: rejects letters@12a@err
numeric_id: rejects a path@1/../2@err
numeric_id: rejects spaces@1 2@err
EOF
# --- comma_ids_valid -----------------------------------------------------
while IFS=@ read -r name input want; do
  if [[ "$want" == ok ]]; then expect_ok "$name" comma_ids_valid "$input"; else expect_err "$name" comma_ids_valid "$input"; fi
done <<'EOF'
comma_ids_valid: accepts one id@42@ok
comma_ids_valid: accepts zero@0@ok
comma_ids_valid: accepts a list@1,2,3@ok
comma_ids_valid: rejects empty@@err
comma_ids_valid: rejects a lone comma@,@err
comma_ids_valid: rejects a trailing comma@1,@err
comma_ids_valid: rejects a leading comma@,1@err
comma_ids_valid: rejects an empty field@1,,2@err
comma_ids_valid: rejects spaces@1, 2@err
comma_ids_valid: rejects a letter field@1,2a@err
comma_ids_valid: rejects a non-numeric list@a,b@err
EOF

# --- epoch_to_stamp_or_raw -----------------------------------------------
expect_eq "epoch_to_stamp_or_raw: empty passes through" "" "$(epoch_to_stamp_or_raw '')"
expect_eq "epoch_to_stamp_or_raw: non-numeric passes through" "abc" "$(epoch_to_stamp_or_raw abc)"
expect_eq "epoch_to_stamp_or_raw: negative passes through" "-5" "$(epoch_to_stamp_or_raw -5)"
expect_eq "epoch_to_stamp_or_raw: numeric delegates to epoch_to_stamp" \
  "$(epoch_to_stamp 1700000001)" "$(epoch_to_stamp_or_raw 1700000001)"
expect_eq "epoch_to_stamp_or_raw: FORMAT is passed through" \
  "$(epoch_to_stamp 1700000001 '%Y/%m/%d')" "$(epoch_to_stamp_or_raw 1700000001 '%Y/%m/%d')"

# epoch_to_stamp formats numeric epochs with the Bash builtin strftime (no
# fork) and must agree with `date`; the result is cached per epoch+format. A
# non-numeric or out-of-range value still passes through unchanged.
# epoch_ref uses whichever `date` spelling this platform supports.
epoch_ref() {
  date -d "@$1" "+$2" 2>/dev/null || date -r "$1" "+$2"
}
EPOCH_STAMP_CACHE=()
expect_eq "epoch_to_stamp: builtin matches date" \
  "$(epoch_ref 1700000001 '%Y-%m-%d %H:%M:%S')" "$(epoch_to_stamp 1700000001 '%Y-%m-%d %H:%M:%S')"
expect_eq "epoch_to_stamp: builtin honors the format" \
  "$(epoch_ref 1700000001 '%Y/%m/%d')" "$(epoch_to_stamp 1700000001 '%Y/%m/%d')"
# A direct call (not a command substitution) primes the parent-shell cache.
epoch_to_stamp 1700000001 '%Y/%m/%d' >/dev/null
expect_eq "epoch_to_stamp: caches the formatted value" \
  "$(epoch_ref 1700000001 '%Y/%m/%d')" "${EPOCH_STAMP_CACHE['1700000001|%Y/%m/%d']}"
expect_eq "epoch_to_stamp: non-numeric passes through" "abc" "$(epoch_to_stamp abc)"
expect_eq "epoch_to_stamp: out-of-range passes through" "99999999999999999999" \
  "$(epoch_to_stamp 99999999999999999999)"

expect_eq "percent_decode: decodes escapes" "a b/c" "$(percent_decode 'a%20b%2Fc')"
expect_eq "percent_decode: literal backslash kept" 'a\b' "$(percent_decode 'a\b')"
expect_eq "percent_decode: backslash escape not interpreted" 'a\c' "$(percent_decode 'a\c')"
expect_eq "percent_decode: malformed escape kept" 'a%2' "$(percent_decode 'a%2')"
expect_eq "percent_decode: plus stays literal" 'a+b' "$(percent_decode 'a+b')"
expect_eq "percent_decode: multi-byte utf-8" "grüße.txt" "$(percent_decode 'gr%C3%BC%C3%9Fe.txt')"
expect_eq "percent_decode: uppercase hex slash" "/" "$(percent_decode '%2F')"
expect_eq "percent_decode: lowercase hex slash" "/" "$(percent_decode '%2f')"
expect_eq "percent_decode: mixed-case hex" "+" "$(percent_decode '%2B')"
expect_eq "percent_decode: malformed trailing percent" "a%" "$(percent_decode 'a%')"
expect_eq "percent_decode: malformed non-hex kept" "%zz" "$(percent_decode '%zz')"
expect_eq "percent_decode: malformed then valid" "%2/a b" "$(percent_decode '%2/a%20b')"
expect_eq "percent_decode: literal backslash-n kept" 'a\nb' "$(percent_decode 'a\nb')"
split_positionals $'one\ntwo\n'
expect_eq "split_positionals: count" "2" "${#POSITIONAL_ARGS[@]}"
expect_eq "split_positionals: first" "one" "${POSITIONAL_ARGS[0]:-}"
expect_eq "split_positionals: second" "two" "${POSITIONAL_ARGS[1]:-}"
split_positionals ""
expect_eq "split_positionals: empty input" "0" "${#POSITIONAL_ARGS[@]}"
split_positionals $'a\n\nb\n'
expect_eq "split_positionals: empty field kept" "|b" "${POSITIONAL_ARGS[1]:-}|${POSITIONAL_ARGS[2]:-}"
while IFS='|' read -r name input want; do
  expect_eq "$name" "$want" "$(format_size_bytes "$input")"
done <<'EOF'
format_size_bytes: bytes|512|512B
format_size_bytes: kibibytes|1024|1.0KiB
format_size_bytes: mebibytes|3670016|3.5MiB
format_size_bytes: gibibytes|12884901888|12GiB
format_size_bytes: non-numeric passes through|n/a|n/a
format_size_bytes: empty passes through||
format_size_bytes: leading zero is decimal, not octal|01000|1000B
format_size_bytes: leading zero with 8/9 is decimal too|089|89B
EOF
while IFS='|' read -r name input want; do
  expect_eq "$name" "$want" "$(format_size_bytes "$input" rclone)"
done <<'EOF'
format_size_bytes rclone: exact mebibytes|104857600|100Mi
format_size_bytes rclone: exact kibibytes|2048|2Ki
format_size_bytes rclone: non-exact stays plain|1536|1536
format_size_bytes rclone: below one kibibyte is plain|512|512
format_size_bytes rclone: non-numeric passes through|n/a|n/a
EOF
while IFS='|' read -r name input want; do
  expect_eq "$name" "$want" "$(format_size_bytes "$input" bytes)"
done <<'EOF'
format_size_bytes bytes: unscaled with suffix|2048|2048B
format_size_bytes bytes: small stays B|512|512B
format_size_bytes bytes: non-numeric passes through|n/a|n/a
EOF
# capabilities_size_label is a delegation to the rclone style and must stay
# byte-identical to the original body for every sample the label checks use.
for size_label_sample in 0 1 512 1023 1024 1536 2048 5242880 104857600 \
  1073741824 1073741825 999999999999 n/a ""; do
  expect_eq "capabilities_size_label: rclone style for '${size_label_sample}'" \
    "$(format_size_bytes "$size_label_sample" rclone)" \
    "$(capabilities_size_label "$size_label_sample")"
done

# --- default_uint ---------------------------------------------------------
while IFS='|' read -r name input fallback want; do
  expect_eq "$name" "$want" "$(default_uint "$input" "$fallback")"
done <<'EOF'
default_uint: valid passes through|50|20|50
default_uint: zero passes through|0|20|0
default_uint: empty falls back||20|20
default_uint: non-numeric falls back|abc|20|20
default_uint: mixed falls back|12a|20|20
EOF

# --- strip_control_bytes -------------------------------------------------
# C0/DEL and stray C1 bytes are dropped, valid 2/3/4-byte UTF-8 survives, and
# a non-control high byte is kept. Byte counts go through printf | wc -c.
bytes_of() { printf '%s' "$1" | wc -c | tr -d ' '; }
expect_eq "strip_control_bytes: drops C0 and DEL" "3" \
  "$(bytes_of "$(strip_control_bytes "$(printf 'a\001b\177c')")")"
expect_eq "strip_control_bytes: drops stray C1 bytes" "3" \
  "$(bytes_of "$(strip_control_bytes "$(printf 'a\200b\233c')")")"
expect_eq "strip_control_bytes: keeps 2-byte UTF-8" "2" \
  "$(bytes_of "$(strip_control_bytes "$(printf 'ü')")")"
expect_eq "strip_control_bytes: keeps 3-byte UTF-8" "3" \
  "$(bytes_of "$(strip_control_bytes "$(printf '€')")")"
expect_eq "strip_control_bytes: keeps 4-byte UTF-8" "4" \
  "$(bytes_of "$(strip_control_bytes "$(printf '😀')")")"
expect_eq "strip_control_bytes: control bytes around valid UTF-8" "11" \
  "$(bytes_of "$(strip_control_bytes "$(printf 'a\001ü\200€\177😀b')")")"
expect_eq "strip_control_bytes: non-control high byte 0xa0 kept" "1" \
  "$(bytes_of "$(strip_control_bytes "$(printf '\240')")")"
expect_eq "strip_control_bytes: non-control high byte 0xff kept" "1" \
  "$(bytes_of "$(strip_control_bytes "$(printf '\377')")")"
expect_eq "strip_control_bytes: valid multi-byte text unchanged" "grüße€" \
  "$(strip_control_bytes "$(printf 'grüße€')")"
# Encoded C1 and invalid UTF-8 are dropped, but a lone non-control high byte
# stays (only 0x80-0x9F is a terminal control under Latin-1).
expect_eq "strip_control_bytes: drops encoded C1 C2 9B" "2" \
  "$(bytes_of "$(strip_control_bytes "$(printf 'a\302\233b')")")"
expect_eq "strip_control_bytes: drops overlong lead C1 9B" "2" \
  "$(bytes_of "$(strip_control_bytes "$(printf 'a\301\233b')")")"
expect_eq "strip_control_bytes: drops overlong E0 80 80" "2" \
  "$(bytes_of "$(strip_control_bytes "$(printf 'a\340\200\200b')")")"
expect_eq "strip_control_bytes: drops surrogate ED A0 80" "2" \
  "$(bytes_of "$(strip_control_bytes "$(printf 'a\355\240\200b')")")"
expect_eq "strip_control_bytes: drops out-of-range F4 90 80 80" "2" \
  "$(bytes_of "$(strip_control_bytes "$(printf 'a\364\220\200\200b')")")"
expect_eq "strip_control_bytes: drops a stray continuation 80" "2" \
  "$(bytes_of "$(strip_control_bytes "$(printf 'a\200b')")")"

# --- sanitize_stream -----------------------------------------------------
# The terminal stream filter drops C0 (except TAB/LF), DEL, stray C1 bytes,
# and invalid UTF-8 bytes while preserving valid 2/3/4-byte sequences and the
# line structure. The awk pass is run through a pipe so stdin is exercised.
expect_eq "sanitize_stream: drops ESC and DEL" "a[31mb" \
  "$(printf 'a\033[31m\177b\n' | sanitize_stream)"
expect_eq "sanitize_stream: drops stray C1 bytes" "abc" \
  "$(printf 'a\200b\233c\n' | sanitize_stream)"
expect_eq "sanitize_stream: keeps TAB and LF" "$(printf 'a\tb\nc')" \
  "$(printf 'a\tb\nc\n' | sanitize_stream)"
expect_eq "sanitize_stream: drops CR" "$(printf 'ab')" \
  "$(printf 'a\rb\n' | sanitize_stream)"
expect_eq "sanitize_stream: keeps 2-byte UTF-8" "ü" \
  "$(printf 'ü\n' | sanitize_stream)"
expect_eq "sanitize_stream: keeps 3-byte UTF-8" "€" \
  "$(printf '€\n' | sanitize_stream)"
expect_eq "sanitize_stream: keeps 4-byte UTF-8" "😀" \
  "$(printf '😀\n' | sanitize_stream)"
expect_eq "sanitize_stream: controls around UTF-8 and TAB" "$(printf 'a\t[31mü€😀b')" \
  "$(printf 'a\t\033[31mü\200€\177😀b\n' | sanitize_stream)"
# Encoded C1 and invalid UTF-8 are dropped by the shared byte rules, while
# valid multi-byte text and TAB/LF survive.
expect_eq "sanitize_stream: drops encoded C1 C2 9B" "ab" \
  "$(printf 'a\302\233b\n' | sanitize_stream)"
expect_eq "sanitize_stream: drops overlong lead C1 9B" "ab" \
  "$(printf 'a\301\233b\n' | sanitize_stream)"
expect_eq "sanitize_stream: drops overlong E0 80 80" "ab" \
  "$(printf 'a\340\200\200b\n' | sanitize_stream)"
expect_eq "sanitize_stream: drops surrogate ED A0 80" "ab" \
  "$(printf 'a\355\240\200b\n' | sanitize_stream)"
expect_eq "sanitize_stream: drops out-of-range F4 90 80 80" "ab" \
  "$(printf 'a\364\220\200\200b\n' | sanitize_stream)"
expect_eq "sanitize_stream: drops a stray continuation 80" "ab" \
  "$(printf 'a\200b\n' | sanitize_stream)"
# A multi-hundred-KB single line must stay linear: the old byte-by-byte
# concatenation hung here. The line carries a TAB, an ESC, and a valid
# two-byte character, so the fast path and the UTF-8 rules are both used.
big_line="${TMP}/sanitize-big-line"
big_out="${TMP}/sanitize-big-out"
{
  head -c 1048576 /dev/zero | tr '\0' 'a'
  printf '\t\033ü'
} >"$big_line"
printf '\n' >>"$big_line"
big_start="$EPOCHREALTIME"
sanitize_stream <"$big_line" >"$big_out"
big_end="$EPOCHREALTIME"
big_elapsed_ms=$(((${big_end/./} - ${big_start/./}) / 1000))
expect_eq "sanitize_stream: large line output keeps TAB and valid UTF-8" \
  "1048580" "$(wc -c <"$big_out" | tr -d ' ')"
if [[ "$big_elapsed_ms" -lt 2000 ]]; then
  pass "sanitize_stream: 1MB single line completes quickly (${big_elapsed_ms}ms)"
else
  fail "sanitize_stream: 1MB single line completes quickly" "${big_elapsed_ms}ms"
fi

# --- url_redact_userinfo -------------------------------------------------
expect_eq "url_redact_userinfo: masks embedded credentials" \
  "https://***@example.com/path" "$(url_redact_userinfo 'https://user:pass@example.com/path')"
expect_eq "url_redact_userinfo: no userinfo is unchanged" \
  "https://example.com/path" "$(url_redact_userinfo 'https://example.com/path')"
expect_eq "url_redact_userinfo: no scheme is unchanged" \
  "example.com:8080" "$(url_redact_userinfo 'example.com:8080')"
expect_eq "url_redact_userinfo: IPv6 host and port survive redaction" \
  "http://***@[2001:db8::1]:8443/path" "$(url_redact_userinfo 'http://user:pass@[2001:db8::1]:8443/path')"

# --- file_mtime / file_mode / seen_contains ------------------------------
FM_TIME="${TMP}/mtime-probe"
printf 'x' >"$FM_TIME"
case "$(file_mtime "$FM_TIME")" in
  '' | *[!0-9]*) fail "file_mtime: numeric epoch" "got [$(file_mtime "$FM_TIME")]" ;;
  *) pass "file_mtime: numeric epoch" ;;
esac
expect_eq "file_mtime: missing file is empty" "" "$(file_mtime "${TMP}/no-such-file")"
chmod 600 "$FM_TIME"
expect_eq "file_mode: octal mode" "600" "$(file_mode "$FM_TIME")"
expect_eq "file_mode: missing file is empty" "" "$(file_mode "${TMP}/no-such-file")"
SEEN_FILE="${TMP}/seen-probe"
printf '41\n42\n' >"$SEEN_FILE"
expect_ok "seen_contains: finds a recorded id" seen_contains "$SEEN_FILE" 41
expect_err "seen_contains: misses an unknown id" seen_contains "$SEEN_FILE" 43
expect_err "seen_contains: missing file is not an error" seen_contains "${TMP}/no-seen" 1
# The raw stamp is memoized for the current SECONDS tick, so a write from
# another process (here: the seen_record pipeline subshell) is only picked up
# on the next tick. Cross it explicitly to keep the assertion off the
# boundary.
printf '43\n' | seen_record "$SEEN_FILE"
seen_saved_seconds="$SECONDS"
SECONDS=$((SECONDS + 1))
expect_ok "seen_record: appended id is visible" seen_contains "$SEEN_FILE" 43
expect_ok "seen_record: old id survives" seen_contains "$SEEN_FILE" 41
SECONDS="$seen_saved_seconds"
expect_eq "seen_record: mode 600" "600" "$(file_mode "$SEEN_FILE")"

# A here-string keeps seen_record in the current shell, so its in-process
# invalidation makes the append visible inside the same tick.
seen_record "$SEEN_FILE" <<<'44'
expect_ok "seen_record: same-tick in-process append is visible" seen_contains "$SEEN_FILE" 44
expect_eq "seen_contains: index tracks the queried file" "$SEEN_FILE" "$SEEN_CACHE_FILE"

# _seen_stamp_refresh reuses FILE's stamp for the current SECONDS tick and
# re-stats on the next one (mirroring _log_stamp_refresh).
_seen_stamp_refresh "$SEEN_FILE"
seen_stamp_first="$SEEN_STAMP_VALUE"
seen_stamp_tick="$SEEN_STAMP_SECONDS"
printf '99\n' >>"$SEEN_FILE"
_seen_stamp_refresh "$SEEN_FILE"
expect_eq "seen stamp: same tick reuses the cached value" "$seen_stamp_first" "$SEEN_STAMP_VALUE"
SECONDS=$((seen_stamp_tick + 1))
_seen_stamp_refresh "$SEEN_FILE"
expect_eq "seen stamp: next tick re-stats the file" "$(file_stamp "$SEEN_FILE")" "$SEEN_STAMP_VALUE"
SECONDS="$seen_saved_seconds"

# A state write problem must not abort the caller: run under errexit (as the
# notify/watch callers effectively do) against a read-only target directory
# and require seen_record to return 0 and let execution continue. A plain
# subshell is used because a command substitution would mask the abort.
SEEN_RO_DIR="${TMP}/seen-readonly"
mkdir -p "$SEEN_RO_DIR"
chmod 500 "$SEEN_RO_DIR"
SEEN_RO_MARKER="${TMP}/seen-continued"
rm -f "$SEEN_RO_MARKER"
(
  set -e -o pipefail
  printf '99\n' | seen_record "${SEEN_RO_DIR}/seen"
  : >"$SEEN_RO_MARKER"
) >/dev/null 2>&1
seen_ro_rc=$?
chmod 700 "$SEEN_RO_DIR"
expect_rc "seen_record: unwritable state dir does not abort" "$seen_ro_rc" 0
expect_file "seen_record: execution continues after a failed write" "$SEEN_RO_MARKER"
expect_no_file "seen_record: read-only target is not written" "${SEEN_RO_DIR}/seen"

while IFS='|' read -r name input want; do
  expect_eq "$name" "$want" "$(strip_trailing_slashes "$input")"
done <<'EOF'
strip_trailing_slashes: strips one|a/|a
strip_trailing_slashes: strips many|a///|a
strip_trailing_slashes: keeps bare|a|a
strip_trailing_slashes: keeps root|/|/
strip_trailing_slashes: keeps empty||
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
parse: filter path traversal@sync|/tmp/src|notes|../evil.txt@1@invalid filter file
parse: filter with subdirectory@sync|/tmp/src|notes|sub/x.txt@1@invalid filter file
parse: filter absolute path@sync|/tmp/src|notes|/etc/passwd@1@invalid filter file
EOF

# --- manifest_lines -----------------------------------------------------
printf '# comment line\n\nsync|/tmp/src|repos/my-app\n   \n  # indented comment\npull|/tmp/other|notes\n' >"$MANIFEST_FILE"
: >"$FOLDERS_FILE"
: >"$MANIFEST_GENERATED_FILE"
expect_eq "manifest_lines: blank and comment lines ignored" \
  "$(printf 'sync|/tmp/src|repos/my-app\npull|/tmp/other|notes')" \
  "$(manifest_lines)"

# --- manifest_lines stamp (one stat + per-SECONDS-tick cache) -------------
# The stamp carries each existing file's "path<TAB>mtime size" from a single
# stat call and is cached for the current SECONDS tick; invalidate drops it.
# Pinning SECONDS keeps the reuse assertion off the tick boundary.
_manifest_lines_stamp
stamp_before="$_MANIFEST_LINES_STAMP_VALUE"
expect_contains "manifest_lines stamp: names the manifest file" "$stamp_before" "$MANIFEST_FILE"
expect_contains "manifest_lines stamp: carries the file stamp" "$stamp_before" "$(file_stamp "$MANIFEST_FILE")"
saved_seconds="$SECONDS"
SECONDS=1000
_manifest_lines_stamp
tick_stamp="$_MANIFEST_LINES_STAMP_VALUE"
expect_eq "manifest_lines stamp: pinned to the tick" "1000" "$_MANIFEST_STAMP_SECONDS"
SECONDS=1000
_manifest_lines_stamp
expect_eq "manifest_lines stamp: same tick reuses the cached value" "$tick_stamp" "$_MANIFEST_LINES_STAMP_VALUE"
printf 'sync|/tmp/src|repos/my-app\npull|/tmp/other|notes|clutter.txt\n' >"$MANIFEST_FILE"
manifest_index_invalidate
expect_eq "manifest_lines stamp: invalidate clears the tick cache" "" "$_MANIFEST_STAMP_SECONDS"
_manifest_lines_stamp
expect_contains "manifest_lines stamp: reflects an external rewrite" \
  "$_MANIFEST_LINES_STAMP_VALUE" "$(file_stamp "$MANIFEST_FILE")"
SECONDS="$saved_seconds"

# --- manifest_each ------------------------------------------------------
# Valid entries are walked in order (invalid lines skipped), extra ARGs reach
# the callback, and a non-zero callback status stops the walk and propagates.
printf 'sync|/tmp/src|repos/my-app\nbogus|/tmp/bad|bad-sub\npull|/tmp/other|notes\n' >"$MANIFEST_FILE"
: >"$FOLDERS_FILE"
: >"$MANIFEST_GENERATED_FILE"
manifest_index_invalidate
me_log=""
# shellcheck disable=SC2329  # invoked indirectly by manifest_each
manifest_each_visit() { me_log+="$ENTRY_MODE:$ENTRY_REMOTE"$'\n'; }
manifest_each manifest_each_visit
expect_rc "manifest_each: completes with rc 0" "$?" 0
expect_eq "manifest_each: valid lines in order, invalid skipped" \
  $'sync:repos/my-app\npull:notes\n' "$me_log"
me_arg=""
# shellcheck disable=SC2329  # invoked indirectly by manifest_each
manifest_each_arg() { me_arg="$1"; }
manifest_each manifest_each_arg "passed-through"
expect_eq "manifest_each: extra ARG reaches the callback" "passed-through" "$me_arg"
me_count=0
# shellcheck disable=SC2329  # invoked indirectly by manifest_each
manifest_each_stop() {
  me_count=$((me_count + 1))
  return 7
}
me_rc=0
manifest_each manifest_each_stop || me_rc=$?
expect_rc "manifest_each: non-zero callback status propagated" "$me_rc" 7
expect_eq "manifest_each: non-zero callback stops the walk" "1" "$me_count"

# --- blacklist_each_record ----------------------------------------------
# Fields are COUNT, PATH, ERROR, NEXT; a final line without a trailing newline
# is still visited, and a non-zero callback status stops and propagates.
bl_file="${TMP}/blacklist-each.rec"
printf '1\tpath/a\terror one\n2\tpath/b\terror two\tnext=1700000000\n3\tpath/c\tno newline' >"$bl_file"
bl_log=""
# shellcheck disable=SC2329  # invoked indirectly by blacklist_each_record
blacklist_each_visit() { bl_log+="$1,$2,$3,$4;"; }
blacklist_each_record blacklist_each_visit "$bl_file"
expect_rc "blacklist_each_record: completes with rc 0" "$?" 0
expect_eq "blacklist_each_record: fields and unterminated final line" \
  '1,path/a,error one,;2,path/b,error two,next=1700000000;3,path/c,no newline,;' "$bl_log"
bl_count=0
# shellcheck disable=SC2329  # invoked indirectly by blacklist_each_record
blacklist_each_stop() {
  bl_count=$((bl_count + 1))
  return 9
}
bl_rc=0
blacklist_each_record blacklist_each_stop "$bl_file" || bl_rc=$?
expect_rc "blacklist_each_record: non-zero callback status propagated" "$bl_rc" 9
expect_eq "blacklist_each_record: non-zero callback stops the walk" "1" "$bl_count"

# --- manifest_resolve_local ---------------------------------------------
printf 'sync|/tmp/src|repos/my-app|clutter.txt\npull|/tmp/other|notes\n' >"$MANIFEST_FILE"
: >"$FOLDERS_FILE"
: >"$MANIFEST_GENERATED_FILE"
manifest_index_invalidate
resolved_local=""
expect_ok "manifest_resolve_local: exact match rc 0" manifest_resolve_local "repos/my-app" resolved_local
expect_eq "manifest_resolve_local: exact local path" "/tmp/src" "$resolved_local"
expect_eq "manifest_resolve_local: exact match name" "repos_my-app" "$MANIFEST_MATCH_NAME"
expect_eq "manifest_resolve_local: exact match filter" "clutter.txt" "$MANIFEST_MATCH_FILTER"
resolved_local=""
expect_ok "manifest_resolve_local: parent match rc 0" manifest_resolve_local "repos/my-app/sub/file.txt" resolved_local
expect_eq "manifest_resolve_local: parent appends remainder" "/tmp/src/sub/file.txt" "$resolved_local"
expect_eq "manifest_resolve_local: parent match name" "repos_my-app" "$MANIFEST_MATCH_NAME"
expect_eq "manifest_resolve_local: parent match filter" "clutter.txt" "$MANIFEST_MATCH_FILTER"
resolved_local=""
expect_err "manifest_resolve_local: no match rc 1" manifest_resolve_local "unrelated/path" resolved_local
expect_eq "manifest_resolve_local: no match leaves OUT_VAR empty" "" "$resolved_local"
expect_eq "manifest_resolve_local: no match clears name" "" "$MANIFEST_MATCH_NAME"
expect_eq "manifest_resolve_local: no match clears filter" "" "$MANIFEST_MATCH_FILTER"
# A fresh manifest (cache invalidated) is picked up, and exact matches prefer
# the newly written entry.
printf 'sync|/tmp/new|fresh-sub\n' >"$MANIFEST_FILE"
: >"$FOLDERS_FILE"
: >"$MANIFEST_GENERATED_FILE"
manifest_index_invalidate
resolved_local=""
expect_ok "manifest_resolve_local: fresh lines after invalidate" manifest_resolve_local "fresh-sub" resolved_local
expect_eq "manifest_resolve_local: fresh local path" "/tmp/new" "$resolved_local"

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

# The index is cached; after the duplicates are removed and the cache is
# invalidated the answers must change.
printf 'sync|/tmp/src|repos/my-app\n' >"$MANIFEST_FILE"
manifest_index_invalidate
expect_err "manifest_has_duplicate_name: refreshed after invalidate" manifest_has_duplicate_name "repos/my-app"

# Membership is literal: a glob in the needle must not match a sibling.
cp "$MANIFEST_FILE" "${TMP}/manifest.index.bak"
cp "$FOLDERS_FILE" "${TMP}/folders.index.bak"
printf 'sync|/tmp/src|repos/axb\n' >"$MANIFEST_FILE"
: >"$FOLDERS_FILE"
manifest_index_invalidate
expect_ok "manifest_has_remote: literal needle matches itself" manifest_has_remote "repos/axb"
expect_err "manifest_has_remote: glob needle is literal" manifest_has_remote "repos/a*b"
expect_err "manifest_has_remote: glob question mark is literal" manifest_has_remote "repos/a?b"
cp "${TMP}/manifest.index.bak" "$MANIFEST_FILE"
cp "${TMP}/folders.index.bak" "$FOLDERS_FILE"
manifest_index_invalidate

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
expect_contains "manifest_append_pair: seeds the wizard header" "$content" "# Folder pairs added with"
expect_contains "manifest_append_pair: pair line written" "$content" "sync|/tmp/local|my-sub"
printf 'pull|/tmp/x|old' >"$FOLDERS_FILE"
manifest_append_pair "bisync" "/tmp/y" "new-sub" "clutter.txt"
content="$(cat "$FOLDERS_FILE")"
expect_contains "manifest_append_pair: preserves existing bytes" "$content" "pull|/tmp/x|old"
expect_contains "manifest_append_pair: adds missing newline before append" "$content" "bisync|/tmp/y|new-sub|clutter.txt"
expect_eq "manifest_append_pair: one line per entry" "2" "$(wc -l <"$FOLDERS_FILE" | tr -d ' ')"

# --- manifest_append_pair validation ------------------------------------
# The invalid calls die in a subshell so the suite keeps running.
saved_folders="$FOLDERS_FILE"
FOLDERS_FILE="${TMP}/append-invalid.conf"
rm -f "$FOLDERS_FILE"
expect_dies "manifest_append_pair: rejects a pipe in the local path" manifest_append_pair "sync" "/tmp/a|b" "my-sub"
expect_dies "manifest_append_pair: rejects an unsafe remote subdir" manifest_append_pair "sync" "/tmp/local" "../evil"
expect_dies "manifest_append_pair: rejects an invalid mode" manifest_append_pair "bogus" "/tmp/local" "my-sub"
expect_dies "manifest_append_pair: rejects a filter path" manifest_append_pair "sync" "/tmp/local" "my-sub" "../evil.txt"
expect_no_file "manifest_append_pair: nothing written for invalid pairs" "$FOLDERS_FILE"
FOLDERS_FILE="$saved_folders"

# --- manifest_append_pairs (one atomic batch write) ---------------------
# Every accepted line lands in a single atomic_write, duplicates (existing or
# earlier in the batch) are skipped and counted, and an invalid record dies
# before anything is written.
batch_saved_manifest="$MANIFEST_FILE"
batch_saved_generated="$MANIFEST_GENERATED_FILE"
batch_saved_folders="$FOLDERS_FILE"
MANIFEST_FILE="${TMP}/batch-sources.conf"
MANIFEST_GENERATED_FILE="${TMP}/batch-generated.conf"
: >"$MANIFEST_FILE"
: >"$MANIFEST_GENERATED_FILE"
FOLDERS_FILE="${TMP}/batch.conf"

rm -f "$FOLDERS_FILE"
manifest_index_invalidate
expect_run "manifest_append_pairs: batch rc 0" 0 manifest_append_pairs \
  $'sync\t/tmp/one\tsub-one' $'pull\t/tmp/two\tsub-two' $'bisync\t/tmp/three\tsub-three'
expect_eq "manifest_append_pairs: skipped nothing" "0" "$MANIFEST_APPEND_PAIRS_SKIPPED"
expect_contains "manifest_append_pairs: seeds the wizard header" "$(cat "$FOLDERS_FILE")" "# Folder pairs added with"
expect_eq "manifest_append_pairs: accepted lines keep input order" \
  "$(printf 'sync|/tmp/one|sub-one\npull|/tmp/two|sub-two\nbisync|/tmp/three|sub-three')" \
  "$(tail -n 3 "$FOLDERS_FILE")"

printf '# keep' >"$FOLDERS_FILE"
manifest_index_invalidate
manifest_append_pairs $'sync\t/tmp/one\tsub-one'
expect_eq "manifest_append_pairs: adds missing newline before append" \
  $'# keep\nsync|/tmp/one|sub-one' "$(cat "$FOLDERS_FILE")"

# A whole batch goes through exactly one atomic_write regardless of size.
rm -f "${TMP}/batch-writes"
MANIFEST_FILE="${TMP}/batch-count-sources.conf"
: >"$MANIFEST_FILE"
FOLDERS_FILE="${TMP}/batch-count.conf"
manifest_index_invalidate
(
  atomic_write() { printf 'write\n' >>"${TMP}/batch-writes"; }
  manifest_append_pairs $'sync\t/tmp/a\tsub-a' $'pull\t/tmp/b\tsub-b' $'bisync\t/tmp/c\tsub-c'
)
expect_eq "manifest_append_pairs: one atomic_write for the whole batch" "1" \
  "$(wc -l <"${TMP}/batch-writes" | tr -d ' ')"
MANIFEST_FILE="${TMP}/batch-sources.conf"
: >"$MANIFEST_FILE"
FOLDERS_FILE="${TMP}/batch.conf"
manifest_index_invalidate

printf 'sync|/tmp/seed|sub-one\n' >"$MANIFEST_FILE"
manifest_index_invalidate
printf '# keep\n' >"$FOLDERS_FILE"
manifest_append_pairs \
  $'sync\t/tmp/a\tsub-one' \
  $'pull\t/tmp/b\tsub-new' \
  $'bisync\t/tmp/c\tsub-new' \
  $'sync\t/tmp/d\tsub-other'
expect_eq "manifest_append_pairs: existing and intra-batch duplicates skipped" "2" \
  "$MANIFEST_APPEND_PAIRS_SKIPPED"
expect_eq "manifest_append_pairs: only accepted lines written in order" \
  $'# keep\npull|/tmp/b|sub-new\nsync|/tmp/d|sub-other' "$(cat "$FOLDERS_FILE")"

: >"$MANIFEST_FILE"
manifest_index_invalidate
printf '# keep\n' >"$FOLDERS_FILE"
printf 'pull\t/tmp/stdin\tsub-stdin\n' | manifest_append_pairs
expect_eq "manifest_append_pairs: reads records from stdin" \
  $'# keep\npull|/tmp/stdin|sub-stdin' "$(cat "$FOLDERS_FILE")"

printf '# keep\n' >"$FOLDERS_FILE"
cp "$FOLDERS_FILE" "${TMP}/batch.saved"
manifest_index_invalidate
expect_dies "manifest_append_pairs: rejects an invalid mode" \
  manifest_append_pairs $'bogus\t/tmp/x\tsub-x'
expect_dies "manifest_append_pairs: rejects an unsafe remote subdir" \
  manifest_append_pairs $'sync\t/tmp/x\t../evil'
expect_dies "manifest_append_pairs: rejects a pipe in the local path" \
  manifest_append_pairs $'sync\t/tmp/a|b\tsub-x'
expect_same "manifest_append_pairs: invalid batch leaves the file untouched" \
  "${TMP}/batch.saved" "$FOLDERS_FILE"

rm -f "$FOLDERS_FILE"
manifest_index_invalidate
printf '\n' | manifest_append_pairs
expect_no_file "manifest_append_pairs: blank-only batch writes nothing" "$FOLDERS_FILE"

MANIFEST_FILE="$batch_saved_manifest"
MANIFEST_GENERATED_FILE="$batch_saved_generated"
FOLDERS_FILE="$batch_saved_folders"
manifest_index_invalidate

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

# --- manifest_pair_flags (paused/hidden) ---------------------------------
# The into variants resolve the directory and file without a command
# substitution, and the predicates share one parse of the flag file.
expect_eq "pair_flags_file: joins dir and name" "${STATE_DIR}/pairs/probe-pair" \
  "$(manifest_pair_flags_file 'probe-pair')"
pf_dir=""
expect_ok "pair_flags_dir_into: rc 0" manifest_pair_flags_dir_into pf_dir
expect_eq "pair_flags_dir_into: value" "${STATE_DIR}/pairs" "$pf_dir"
pf_file=""
expect_ok "pair_flags_file_into: rc 0" manifest_pair_flags_file_into pf_file 'probe-pair'
expect_eq "pair_flags_file_into: value" "${STATE_DIR}/pairs/probe-pair" "$pf_file"

expect_ok "pair_flags_set: paused on" manifest_pair_flags_set 'probe-pair' paused 1
expect_ok "pair_paused: true" manifest_pair_paused 'probe-pair'
expect_err "pair_hidden: false" manifest_pair_hidden 'probe-pair'
expect_ok "pair_flags_set: hidden on" manifest_pair_flags_set 'probe-pair' hidden 1
# A write drops the shared parse, so both predicates see the new pair.
expect_ok "pair_paused: still true" manifest_pair_paused 'probe-pair'
expect_ok "pair_hidden: now true" manifest_pair_hidden 'probe-pair'
expect_ok "pair_flags_set: paused off" manifest_pair_flags_set 'probe-pair' paused 0
expect_err "pair_paused: false after set" manifest_pair_paused 'probe-pair'
expect_ok "pair_hidden: unchanged after the paused set" manifest_pair_hidden 'probe-pair'
expect_err "pair_paused: unknown pair is off" manifest_pair_paused 'no-such-pair'
expect_err "pair_hidden: unknown pair is off" manifest_pair_hidden 'no-such-pair'
expect_err "pair_flags_set: rejects an unknown key" manifest_pair_flags_set 'probe-pair' bogus 1
expect_err "pair_flags_set: rejects a bad value" manifest_pair_flags_set 'probe-pair' paused 2
# Unrelated lines are ignored on write and the preserved key is kept.
printf 'paused=1\njunk=9\n' >"${STATE_DIR}/pairs/probe-pair"
MANIFEST_PAIR_FLAGS_LOADED_NAME=""
expect_ok "pair_flags_set: rewrites the raw file" manifest_pair_flags_set 'probe-pair' hidden 1
expect_contains "pair_flags_set: preserves paused" "$(cat "${STATE_DIR}/pairs/probe-pair")" "paused=1"
expect_contains "pair_flags_set: writes hidden" "$(cat "${STATE_DIR}/pairs/probe-pair")" "hidden=1"
expect_not_contains "pair_flags_set: drops unrelated lines" "$(cat "${STATE_DIR}/pairs/probe-pair")" "junk"

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

# --- ui_confirm_tty / ui_confirm_mutation_soft ----------------------------
# The gate reads the terminal check through ui_stdin_tty, so the matrix runs
# without a pty: the redefinition plays the terminal (the same substitution
# pattern as hydrate's progress_stdout_tty stub), while ui_confirm still
# answers from stdin.
ui_stdin_tty() { return 0; }
rc=0
out="$(ui_confirm_tty "proceed?" <<<'y')" || rc=$?
expect_rc "ui_confirm_tty: y on a promptable tty rc" "$rc" 0
rc=0
out="$(ui_confirm_tty "proceed?" <<<'Yes')" || rc=$?
expect_rc "ui_confirm_tty: Yes accepted (unified dialect)" "$rc" 0
rc=0
out="$(ui_confirm_tty "proceed?" <<<'yEs')" || rc=$?
expect_rc "ui_confirm_tty: yEs accepted (mixed case)" "$rc" 0
rc=0
out="$(ui_confirm_tty "proceed?" <<<'n')" || rc=$?
expect_rc "ui_confirm_tty: decline rc" "$rc" 1
rc=0
out="$(ui_confirm_tty "proceed?" <<<'')" || rc=$?
expect_rc "ui_confirm_tty: empty answer declines" "$rc" 1
rc=0
out="$(SCIEBO_NON_INTERACTIVE=1 ui_confirm_tty "proceed?" <<<'y')" || rc=$?
expect_rc "ui_confirm_tty: SCIEBO_NON_INTERACTIVE is not promptable" "$rc" 2
expect_eq "ui_confirm_tty: not promptable asks nothing" "" "$out"
ui_stdin_tty() { return 1; }
rc=0
out="$(ui_confirm_tty "proceed?" <<<'y')" || rc=$?
expect_rc "ui_confirm_tty: non-tty is not promptable" "$rc" 2
expect_eq "ui_confirm_tty: non-tty asks nothing" "" "$out"
ui_stdin_tty() { [[ -t 0 ]]; }

OPT_yes=1
rc=0
out="$(ui_confirm_mutation_soft optprobe "needs --yes" "proceed?" <<<'n')" || rc=$?
expect_rc "soft: --yes skips the prompt rc" "$rc" 0
expect_eq "soft: --yes asks nothing" "" "$out"
OPT_yes=0
ui_stdin_tty() { return 1; }
rc=0
out="$(ui_confirm_mutation_soft optprobe "needs --yes" "proceed?" 2>&1 <<<'y')" || rc=$?
expect_rc "soft: non-interactive without --yes exits 2" "$rc" 2
expect_contains "soft: refusal names the requirement" "$out" "needs --yes"
ui_stdin_tty() { return 0; }
rc=0
out="$(ui_confirm_mutation_soft optprobe "needs --yes" "proceed?" <<<'y')" || rc=$?
expect_rc "soft: yes on a promptable tty rc" "$rc" 0
rc=0
out="$(ui_confirm_mutation_soft optprobe "needs --yes" "proceed?" \
  "aborted, nothing changed" <<<'n' 2>&1)" || rc=$?
expect_rc "soft: decline returns 1 without exiting" "$rc" 1
expect_contains "soft: decline logs DECLINE_MSG" "$out" "aborted, nothing changed"
rc=0
out="$(ui_confirm_mutation_soft optprobe "needs --yes" "proceed?" <<<'n' 2>&1)" || rc=$?
expect_rc "soft: decline without DECLINE_MSG returns 1" "$rc" 1
expect_not_contains "soft: silent decline logs nothing" "$out" "aborted"
# Restore the real gate after the substituted stubs above; shellcheck counts
# only those stubs as invocations.
# shellcheck disable=SC2329  # restored implementation for later interactive checks
ui_stdin_tty() { [[ -t 0 ]]; }
unset OPT_yes

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

# --- json_string_field (compact JSON) -----------------------------------
json_body='{"id": "42", "path": "a\/b", "quote": "a\"b", "empty": "", "url": "http://x/y"}'
expect_eq "json_string_field: plain value" "42" "$(json_string_field "$json_body" id)"
expect_eq "json_string_field: escaped slash" "a/b" "$(json_string_field "$json_body" path)"
expect_eq "json_string_field: escaped quote" 'a"b' "$(json_string_field "$json_body" quote)"
expect_eq "json_string_field: empty value is found" "" "$(json_string_field "$json_body" empty)"
expect_eq "json_string_field: value with colon" "http://x/y" "$(json_string_field "$json_body" url)"
expect_eq "json_string_field: key suffix not matched" "" "$(json_string_field '{"fileid": "x"}' id)"
expect_eq "json_string_field: other escapes kept" 'a\tb' "$(json_string_field '{"k": "a\tb"}' k)"
json_multi='{
  "a": "1",
  "b": "two"
}'
expect_eq "json_string_field: key on a later line" "two" "$(json_string_field "$json_multi" b)"
json_string_field "$json_body" missing >/dev/null 2>&1
expect_rc "json_string_field: absent rc 1" "$?" 1
expect_eq "json_string_field: absent prints nothing" "" "$(json_string_field "$json_body" missing)"
expect_eq "json_string_field: empty body prints nothing" "" "$(json_string_field '' id)"

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
probe_case "settings: TRANSFERS=abc dies rc 1" "settings: TRANSFERS=abc message" \
  TRANSFERS 1 contains "must be a non-negative integer" TRANSFERS=abc
probe_case "settings: KEYCHAIN=2 dies rc 1" "settings: KEYCHAIN=2 message" \
  KEYCHAIN 1 contains "must be 0 or 1" KEYCHAIN=2
probe_case "settings: MAX_DELETE=-2 dies rc 1" "settings: MAX_DELETE=-2 message" \
  MAX_DELETE 1 contains "integer >= -1" MAX_DELETE=-2
probe_case "settings: DEFAULT_PAIR_MODE=zzz dies rc 1" "settings: DEFAULT_PAIR_MODE=zzz message" \
  DEFAULT_PAIR_MODE 1 contains "must be one of sync, pull, bisync" DEFAULT_PAIR_MODE=zzz
probe_case "settings: REMOTE_BASE pipe dies rc 1" "settings: REMOTE_BASE pipe message" \
  REMOTE_BASE 1 contains "must not contain '|' or control bytes" 'REMOTE_BASE=a|b'
probe_case "settings: empty BW_LIMIT_UP rc 0" "settings: empty BW_LIMIT_UP accepted" \
  BW_LIMIT_UP 0 eq "" BW_LIMIT_UP=
probe_case "settings: derived RUNSTATE_DIR rc 0" "settings: RUNSTATE_DIR defaults under STATE_DIR" \
  RUNSTATE_DIR 0 eq "${SETTINGS_STATE}/last"

# ensure_state_dirs must create the per-source last-run directory too.
runstate_root="${TMP}/runstate-dirs"
(
  STATE_DIR="$runstate_root" LOG_DIR="${runstate_root}/logs" LOCK_DIR="${runstate_root}/locks" \
    BISYNC_DIR="${runstate_root}/bisync" RUNSTATE_DIR="" ensure_state_dirs
)
expect_ok "ensure_state_dirs: creates RUNSTATE_DIR" test -d "${runstate_root}/last"

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

# Start-time defense: a live pid whose recorded start time does not match
# is a recycled pid, so the lock is stale; a matching start keeps it live.
holder_start "${TMP}/bin/sciebo"
BG_PID="$HOLDER_PID"
expect_rc "lock: start-time holder matches the tool" "$(holder_wait "$BG_PID")" 1
mkdir -p "${LOCK_DIR}/sync.lock"
printf '%s\n' "$BG_PID" >"${LOCK_DIR}/sync.lock/pid"
printf 'wrong start time\n' >"${LOCK_DIR}/sync.lock/start"
out="$(lock_probe)"
rc=$?
expect_rc "lock: recycled pid is stale" "$rc" 0
expect_contains "lock: recycled pid takeover warns" "$out" "Removing stale lock"
rm -rf "${LOCK_DIR}/sync.lock"
mkdir -p "${LOCK_DIR}/sync.lock"
printf '%s\n' "$BG_PID" >"${LOCK_DIR}/sync.lock/pid"
ps -ww -p "$BG_PID" -o lstart= >"${LOCK_DIR}/sync.lock/start"
out="$(lock_probe)"
rc=$?
expect_rc "lock: matching start refuses acquire" "$rc" 1
expect_contains "lock: matching start refusal message" "$out" "Another sync run is active"
expect_eq "lock: matching start leaves the foreign pid" "$BG_PID" "$(cat "${LOCK_DIR}/sync.lock/pid")"
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

# --- pid_alive ------------------------------------------------------------
# The lstart comparison squeezes whitespace runs on both sides, so a raw
# `ps -o lstart=` line and a squeezed one describe the same start.
alive_start="$(ps -ww -p "$$" -o lstart= 2>/dev/null)"
expect_ok "pid_alive: this shell is alive without START" pid_alive "$$"
expect_ok "pid_alive: matching raw start accepted" pid_alive "$$" "$alive_start"
expect_ok "pid_alive: matching squeezed start accepted" pid_alive "$$" \
  "$(printf '%s' "$alive_start" | tr -s ' ')"
rc=0
pid_alive "$$" "Mon Jan  1 00:00:00 1990" || rc=$?
expect_rc "pid_alive: wrong start is not alive" "$rc" 1
rc=0
pid_alive "$$" "" || rc=$?
expect_rc "pid_alive: empty recorded start is not alive" "$rc" 1
rc=0
pid_alive 999999999 || rc=$?
expect_rc "pid_alive: missing pid is not alive" "$rc" 1
rc=0
pid_alive not-a-pid || rc=$?
expect_rc "pid_alive: non-numeric pid is not alive" "$rc" 1

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
# The staging template must stay <file>.tmp.XXXXXX (exactly six characters):
# cleanup --state's narrowed *.tmp.?????? glob depends on it. Spy on the temp
# registry to observe the staged path instead of racing the rename, and feed
# stdin via here-string (a pipeline would run the spy in a subshell).
_aw_saved_register="$(declare -f sciebo_temp_register)"
atomic_tmp_seen=""
aw_prefix="probe.txt.tmp."
# shellcheck disable=SC2329  # invoked indirectly by atomic_write -> temp_mktemp_into
sciebo_temp_register() { atomic_tmp_seen="$1"; }
atomic_write "${TMP}/tmpname/probe.txt" 600 <<<"temp-name"
aw_base="${atomic_tmp_seen##*/}"
if [[ "$aw_base" == probe.txt.tmp.?????? ]]; then
  pass "atomic_write: temp staged as file.tmp.?????? (six chars)"
else
  fail "atomic_write: temp staged as file.tmp.?????? (six chars)" "got ${aw_base}"
fi
expect_eq "atomic_write: temp suffix is exactly six characters" "6" "$((${#aw_base} - ${#aw_prefix}))"
expect_eq "atomic_write: here-string content written" "temp-name" "$(cat "${TMP}/tmpname/probe.txt")"
# A path without a slash derives dir="." and lands in the current directory.
# The cd needs a subshell, so the spy prints its view from inside it.
rel_seen="$(cd "$TMP" && atomic_write "relative-probe.txt" <<<"rel" && printf '%s' "$atomic_tmp_seen")"
expect_eq "atomic_write: no-slash path writes into the current directory" "rel" \
  "$(cat "${TMP}/relative-probe.txt")"
if [[ "${rel_seen##*/}" == relative-probe.txt.tmp.?????? ]]; then
  pass "atomic_write: no-slash temp also staged with six chars"
else
  fail "atomic_write: no-slash temp also staged with six chars" "got ${rel_seen##*/}"
fi
eval "$_aw_saved_register"

# --- duration_parse_or_usage (pause's flagless grammar) ------------------
# pause_parse_duration was folded into duration_parse_or_usage: the parsed
# values are unchanged, but a bad value now exits 2 through usage_error.
# shellcheck disable=SC2329  # invoked indirectly through usage_error
usage_pause() { :; }
while IFS='|' read -r name input want rc_want; do
  rc=0
  out="$(duration_parse_or_usage pause "" "$input" invalid "90m, 24h, 1d" 2>/dev/null)" || rc=$?
  expect_rc "${name}: rc" "$rc" "$rc_want"
  [[ "$rc_want" -ne 0 ]] || expect_eq "$name" "$want" "$out"
done <<'EOF'
duration_parse_or_usage: bare number is minutes|5|300|0
duration_parse_or_usage: seconds suffix|30s|30|0
duration_parse_or_usage: minutes suffix|90m|5400|0
duration_parse_or_usage: hours suffix|2h|7200|0
duration_parse_or_usage: days suffix|1d|86400|0
duration_parse_or_usage: fractional hours rejected|1.5h||2
duration_parse_or_usage: unknown unit rejected|5x||2
duration_parse_or_usage: empty rejected|||2
EOF
rc=0
err="$(duration_parse_or_usage pause "" 5x invalid "90m, 24h, 1d" 2>&1)" || rc=$?
expect_rc "duration_parse_or_usage: pause bad value exits 2" "$rc" 2
expect_contains "duration_parse_or_usage: pause example list" "$err" \
  "invalid duration: 5x (use <N>[smhd], e.g. 90m, 24h, 1d)"

# --- pause marker round trip ---------------------------------------------
PAUSE_FILE="${TMP}/pause-state/paused"
expect_ok "pause_set: future marker rc 0" pause_set "$(($(date +%s) + 3600))"
expect_file "pause_set: creates the marker" "$PAUSE_FILE"
expect_eq "pause_set: marker mode 600" "600" "$(file_mode "$PAUSE_FILE")"
expect_ok "pause_active: future marker is active" pause_active
expect_contains "pause_describe: future marker names the time" "$(pause_describe)" "paused until "
printf 'garbage\n' >"$PAUSE_FILE"
expect_err "pause_read: malformed marker rc 1" pause_read
printf 'until=abc\n' >"$PAUSE_FILE"
expect_err "pause_read: non-numeric epoch rc 1" pause_read
printf 'until=123\n' >"$PAUSE_FILE"
expect_ok "pause_read: valid marker rc 0" pause_read
expect_eq "pause_read: parses the epoch" "123" "$PAUSE_UNTIL"
printf 'until=1\n' >"$PAUSE_FILE"
expect_err "pause_active: expired marker is inactive" pause_active
expect_no_file "pause_active: expired marker is removed" "$PAUSE_FILE"
expect_eq "pause_describe: silent when not paused" "" "$(pause_describe)"
expect_ok "pause_clear: rc 0 when the marker is absent" pause_clear
expect_ok "pause_clear: idempotent second call rc 0" pause_clear
expect_ok "pause_set: indefinite marker rc 0" pause_set 0
expect_ok "pause_active: indefinite marker is active" pause_active
expect_eq "pause_describe: indefinite wording" "paused (indefinite)" "$(pause_describe)"
expect_ok "pause_clear: rc 0 when the marker exists" pause_clear
expect_no_file "pause_clear: removes the marker" "$PAUSE_FILE"
expect_err "pause_set: non-numeric epoch rejected" pause_set not-a-number

# --- runstate records ----------------------------------------------------
RUNSTATE_DIR="${TMP}/runstate"
expect_ok "runstate_write: rc 0" runstate_write "manual-docs" sync ok 0 "${TMP}/x.log" 2 "detail text"
expect_file "runstate_write: creates the record" "${RUNSTATE_DIR}/manual-docs"
expect_eq "runstate_write: record mode 600" "600" "$(file_mode "${RUNSTATE_DIR}/manual-docs")"
expect_ok "runstate_read: rc 0" runstate_read "manual-docs"
expect_eq "runstate_read: status" "ok" "$RUNSTATE_STATUS"
expect_eq "runstate_read: mode" "sync" "$RUNSTATE_MODE"
expect_eq "runstate_read: rc" "0" "$RUNSTATE_RC"
expect_eq "runstate_read: conflicts" "2" "$RUNSTATE_CONFLICTS"
expect_eq "runstate_read: log" "${TMP}/x.log" "$RUNSTATE_LOG"
expect_eq "runstate_read: detail" "detail text" "$RUNSTATE_DETAIL"
expect_err "runstate_read: missing record rc 1" runstate_read "missing"

# shellcheck disable=SC2016  # the command substitution is literal test data
hostile_detail='$(touch '"${TMP}/runstate-pwned"')'
hostile_detail="${hostile_detail}"$'\n'"second line"
expect_ok "runstate_write: hostile detail rc 0" runstate_write "hostile" sync failed 1 "" 0 "$hostile_detail"
expect_no_file "runstate_write: hostile detail is never executed" "${TMP}/runstate-pwned"
expect_ok "runstate_read: hostile record rc 0" runstate_read "hostile"
# shellcheck disable=SC2016  # the expected value is literal test data
expect_eq "runstate_read: hostile detail is flattened" \
  '$(touch '"${TMP}/runstate-pwned"')second line' "$RUNSTATE_DETAIL"
expect_eq "runstate_read: hostile status" "failed" "$RUNSTATE_STATUS"

# --- runstate history display and trim -----------------------------------
HISTORY_DIR="${TMP}/history"
HISTORY_MAX_ENTRIES=50
runstate_history_append "hist-unit" 1700000001 ok "first"
runstate_history_append "hist-unit" 1700000002 failed "second"
out="$(runstate_history hist-unit)"
expect_contains "runstate_history: status uppercased" "$out" "OK  first"
expect_contains "runstate_history: failed uppercased" "$out" "FAILED  second"
expect_eq "runstate_history: newest record first" \
  "$(epoch_to_stamp_or_raw 1700000002)  FAILED  second" "$(printf '%s\n' "$out" | sed -n '1p')"
HISTORY_MAX_ENTRIES=2
runstate_history_append "trim-unit" 1700000001 ok "first"
runstate_history_append "trim-unit" 1700000002 ok "second"
runstate_history_append "trim-unit" 1700000003 ok "third"
trim_file="${HISTORY_DIR}/trim-unit.log"
expect_eq "runstate_history_append: trims to HISTORY_MAX_ENTRIES" "2" "$(grep -c '' "$trim_file")"
expect_not_contains "runstate_history_append: oldest record trimmed" "$(cat "$trim_file")" "first"
expect_contains "runstate_history_append: newest record kept" "$(cat "$trim_file")" "third"
HISTORY_MAX_ENTRIES=0
runstate_history_append "off-unit" 1700000001 ok "ignored"
expect_no_file "runstate_history_append: 0 disables the log" "${HISTORY_DIR}/off-unit.log"
unset HISTORY_DIR HISTORY_MAX_ENTRIES

# --- notifications (stub osascript in a private bin dir) ----------------
NOTIFY_BIN="${TMP}/notify-bin"
mkdir -p "$NOTIFY_BIN"
cat >"${NOTIFY_BIN}/osascript" <<'STUB'
#!/bin/bash
dir="$(cd "$(dirname "$0")" && pwd)"
{
  printf 'argc=%s\n' "$#"
  i=0
  for arg in "$@"; do
    i=$((i + 1))
    printf 'arg%s=%s\n' "$i" "$arg"
  done
} >>"${dir}/calls.log"
exit 0
STUB
chmod +x "${NOTIFY_BIN}/osascript"
saved_path="$PATH"
saved_notify="${NOTIFY:-0}"
PATH="${NOTIFY_BIN}:$PATH"
NOTIFY=0 expect_err "notify_enabled: rc 1 with NOTIFY=0" notify_enabled
NOTIFY=1 expect_ok "notify_enabled: rc 0 with NOTIFY=1 and osascript" notify_enabled
: >"${NOTIFY_BIN}/calls.log"
NOTIFY=1
out="$(notify_send "title here" "message here")"
rc=$?
expect_rc "notify_send: rc 0" "$rc" 0
expect_eq "notify_send: prints nothing" "" "$out"
calls="$(cat "${NOTIFY_BIN}/calls.log")"
expect_contains "notify_send: argc includes the script placeholder" "$calls" "argc=3"
expect_contains "notify_send: placeholder is argv[1]" "$calls" "arg1=-"
expect_contains "notify_send: title is argv[2]" "$calls" "arg2=title here"
expect_contains "notify_send: message is argv[3]" "$calls" "arg3=message here"
PATH="$saved_path"
NOTIFY="$saved_notify"

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

# --- keychain (stub `security` in a private bin dir) --------------------
# `security` is resolved through PATH, so a stub only exists for the calls
# made while PATH points at it. The stub records each argv line and keeps
# the stored secret in a file, so store/lookup can cross processes. The
# assertions never print the secret value.
KC_BIN="${TMP}/keychain-bin"
mkdir -p "$KC_BIN"
cat >"${KC_BIN}/security" <<'STUB'
#!/bin/bash
dir="$(cd "$(dirname "$0")" && pwd)"
printf '%s\n' "$*" >>"${dir}/calls.log"
cmd="$1"
shift
secret=""
account=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -w)
      if [[ "$cmd" == "add-generic-password" && $# -ge 2 ]]; then
        secret="$2"
        shift 2
      else
        shift
      fi
      ;;
    -a) account="$2"; shift 2 ;;
    -s) shift 2 ;;
    -U) shift ;;
    *) shift ;;
  esac
done
file="${dir}/stored.${account}"
case "$cmd" in
  add-generic-password)
    [[ ! -f "${dir}/add.fail" ]] || exit 1
    printf '%s' "$secret" >"$file"
    ;;
  find-generic-password)
    [[ ! -f "${dir}/find.fail" ]] || exit 1
    [[ -f "$file" ]] || exit 44
    cat "$file"
    ;;
  delete-generic-password)
    [[ ! -f "${dir}/delete.fail" ]] || exit 1
    [[ -f "$file" ]] || exit 44
    rm -f "$file"
    ;;
esac
exit 0
STUB
chmod +x "${KC_BIN}/security"
KEYCHAIN_TEST_SECRET="obscured-unit-value"
saved_path="$PATH"
saved_keychain="${KEYCHAIN:-0}"
saved_service="${KEYCHAIN_SERVICE:-}"
saved_remote="${RCLONE_REMOTE:-}"
PATH="${KC_BIN}:$PATH"
KEYCHAIN=1 KEYCHAIN_SERVICE="rclone-sciebo" RCLONE_REMOTE="testremote"

expect_ok "keychain_enabled: rc 0 with KEYCHAIN=1 and stub security" keychain_enabled
KEYCHAIN=0 expect_err "keychain_enabled: rc 1 with KEYCHAIN=0" keychain_enabled
KEYCHAIN=1
# F-P1 backend memo: the probe result is cached per input set. Re-stubbing
# an input (the SCIEBO_KEYCHAIN_BACKEND hook or PATH) must re-probe without
# any test-side reset, and remote_secret_invalidate must drop the memo next
# to the secret caches. Call keychain_backend uncaptured so the refresh
# lands in this shell.
keychain_backend >/dev/null
expect_eq "keychain memo: primed with the stub security" "security" "$KEYCHAIN_BACKEND_CACHE"
SCIEBO_KEYCHAIN_BACKEND="secret-tool"
keychain_backend >/dev/null
expect_eq "keychain memo: hook change bypasses the cache" "secret-tool" "$KEYCHAIN_BACKEND_CACHE"
unset SCIEBO_KEYCHAIN_BACKEND
keychain_backend >/dev/null
expect_eq "keychain memo: hook removal re-probes PATH" "security" "$KEYCHAIN_BACKEND_CACHE"
remote_secret_invalidate
expect_eq "keychain memo: remote_secret_invalidate resets the memo" "" "$KEYCHAIN_BACKEND_CACHE"
keychain_backend >/dev/null
expect_eq "keychain memo: re-primed after reset" "security" "$KEYCHAIN_BACKEND_CACHE"
expect_eq "keychain_account: names the configured remote" "testremote" "$(keychain_account)"

printf '%s' "$KEYCHAIN_TEST_SECRET" >"${KC_BIN}/stored.testremote"
: >"${KC_BIN}/calls.log"
KEYCHAIN_CACHE="" KEYCHAIN_CACHE_SET=0
kc_out_file="${TMP}/keychain-lookup.out"
rc=0
keychain_lookup >"$kc_out_file" || rc=$?
expect_rc "keychain_lookup: rc 0 with a stored item" "$rc" 0
if [[ "$(cat "$kc_out_file")" == "$KEYCHAIN_TEST_SECRET" ]]; then
  pass "keychain_lookup: prints the stored obscured value"
else
  fail "keychain_lookup: prints the stored obscured value" "value mismatch"
fi
rc=0
keychain_lookup >"$kc_out_file" || rc=$?
expect_rc "keychain_lookup: cached second call rc 0" "$rc" 0
expect_eq "keychain_lookup: second call served from cache" "1" "$(wc -l <"${KC_BIN}/calls.log" | tr -d ' ')"

touch "${KC_BIN}/find.fail"
KEYCHAIN_CACHE="" KEYCHAIN_CACHE_SET=0
expect_err "keychain_lookup: rc 1 when the stub fails" keychain_lookup
rm -f "${KC_BIN}/find.fail"

rm -f "${KC_BIN}/stored.testremote"
KEYCHAIN_CACHE="" KEYCHAIN_CACHE_SET=0
expect_err "keychain_lookup: rc 1 when the item is absent" keychain_lookup

expect_ok "keychain_delete: rc 0 when the item exists" keychain_delete
expect_no_file "keychain_delete: stub removed the item" "${KC_BIN}/stored.testremote"
expect_ok "keychain_delete: rc 0 when the item is already absent" keychain_delete
touch "${KC_BIN}/delete.fail"
expect_err "keychain_delete: rc 1 on an unexpected failure" keychain_delete
rm -f "${KC_BIN}/delete.fail"

expect_eq "keychain_account_plain: names the plaintext slot" "testremote#plain" "$(keychain_account_plain)"
: >"${KC_BIN}/calls.log"
expect_ok "keychain_store_plain: rc 0" keychain_store_plain "plain-unit-value"
recorded="$(cat "${KC_BIN}/calls.log")"
if [[ "$recorded" == "add-generic-password -U -a testremote#plain -s rclone-sciebo -w plain-unit-value" ]]; then
  pass "keychain_store_plain: passes add-generic-password -U -a -s -w argv"
else
  fail "keychain_store_plain: passes add-generic-password -U -a -s -w argv" "recorded argv mismatch"
fi
expect_eq "keychain_store_plain: updates the plaintext cache" "plain-unit-value" "$KEYCHAIN_PLAIN_CACHE"
KEYCHAIN_PLAIN_CACHE="" KEYCHAIN_PLAIN_CACHE_SET=0
expect_eq "keychain_lookup_plain: prints the plaintext" "plain-unit-value" "$(keychain_lookup_plain)"

# remote_secret_plain reads the plaintext slot without any rclone call; a
# legacy obscured keychain item is revealed once and migrated to the slot.
LEGACY_BIN="${TMP}/stub-rclone-legacy"
cat >"$LEGACY_BIN" <<'STUB'
#!/bin/bash
dir="$(cd "$(dirname "$0")" && pwd)"
printf '%s\n' "$*" >>"${dir}/reveal.log"
case "$1" in
  reveal) printf 'plain-from-legacy' ;;
  obscure) cat >/dev/null; printf 'obscured-form' ;;
esac
STUB
chmod +x "$LEGACY_BIN"
RCLONE_BIN="$LEGACY_BIN"
printf '%s' "legacy-obscured" >"${KC_BIN}/stored.testremote"
rm -f "${KC_BIN}/stored.testremote#plain" "${KC_BIN}/reveal.log"
KEYCHAIN_CACHE="" KEYCHAIN_CACHE_SET=0 KEYCHAIN_PLAIN_CACHE="" KEYCHAIN_PLAIN_CACHE_SET=0
REMOTE_SECRET_PLAIN_CACHE="" REMOTE_SECRET_CACHE=""
expect_eq "remote_secret_plain: reveals a legacy keychain item" "plain-from-legacy" "$(remote_secret_plain)"
expect_eq "remote_secret_plain: migrates it to the plaintext slot" "plain-from-legacy" "$(cat "${KC_BIN}/stored.testremote#plain")"
rm -f "${KC_BIN}/reveal.log"
KEYCHAIN_CACHE="" KEYCHAIN_CACHE_SET=0 KEYCHAIN_PLAIN_CACHE="" KEYCHAIN_PLAIN_CACHE_SET=0
REMOTE_SECRET_PLAIN_CACHE="" REMOTE_SECRET_CACHE=""
expect_eq "remote_secret_plain: plaintext slot hit" "plain-from-legacy" "$(remote_secret_plain)"
expect_no_file "remote_secret_plain: no rclone call once migrated" "${KC_BIN}/reveal.log"

# rclone_cmd must inject the obscured password into the child only, under
# the RCLONE_CONFIG_<REMOTE>_PASS name rclone itself builds (which keeps the
# section's dashes and dots; only the option part is underscore-folded).
# Pin the spelling the plumbing emits before exercising the exec path.
expect_eq "rclone env name: plain remote" "RCLONE_CONFIG_TESTREMOTE_PASS" "$(_rclone_env_pass_name testremote)"
expect_eq "rclone env name: dashed remote keeps the dash" "RCLONE_CONFIG_MY-REMOTE_PASS" "$(_rclone_env_pass_name my-remote)"
expect_eq "rclone env name: dotted remote keeps the dot" "RCLONE_CONFIG_MY.REMOTE_PASS" "$(_rclone_env_pass_name my.remote)"
RCLONE_BIN="${TMP}/stub-rclone-pass"
cat >"$RCLONE_BIN" <<'STUB'
#!/bin/bash
env | grep '^RCLONE_CONFIG_' || true
STUB
chmod +x "$RCLONE_BIN"
rm -f "${KC_BIN}/stored.testremote#plain"
printf '%s' "$KEYCHAIN_TEST_SECRET" >"${KC_BIN}/stored.testremote"
KEYCHAIN_CACHE="" KEYCHAIN_PLAIN_CACHE="" KEYCHAIN_PLAIN_CACHE_SET=0 KEYCHAIN_CACHE_SET=0 REMOTE_SECRET_CACHE=""
RCLONE_REMOTE="testremote"
RCLONE_CONFIG="${TMP}/rclone-cmd.conf"
out="$(rclone_cmd lsd)"
expect_contains "rclone_cmd: child sees RCLONE_CONFIG_TESTREMOTE_PASS" "$out" "RCLONE_CONFIG_TESTREMOTE_PASS=${KEYCHAIN_TEST_SECRET}"
expect_err "rclone_cmd: parent environment stays clean" printenv RCLONE_CONFIG_TESTREMOTE_PASS
RCLONE_REMOTE="my-remote"
printf '%s' "$KEYCHAIN_TEST_SECRET" >"${KC_BIN}/stored.my-remote"
KEYCHAIN_CACHE="" KEYCHAIN_CACHE_SET=0 KEYCHAIN_PLAIN_CACHE="" KEYCHAIN_PLAIN_CACHE_SET=0 REMOTE_SECRET_CACHE=""
out="$(rclone_cmd lsd)"
expect_contains "rclone_cmd: keeps a dashed remote name as rclone does" "$out" "RCLONE_CONFIG_MY-REMOTE_PASS=${KEYCHAIN_TEST_SECRET}"
expect_err "rclone_cmd: parent environment clean for dashed names" printenv "RCLONE_CONFIG_MY-REMOTE_PASS"

PATH="$saved_path"
KEYCHAIN="$saved_keychain"
KEYCHAIN_SERVICE="$saved_service"
RCLONE_REMOTE="$saved_remote"
RCLONE_BIN=""
KEYCHAIN_CACHE="" KEYCHAIN_CACHE_SET=0 KEYCHAIN_PLAIN_CACHE="" KEYCHAIN_PLAIN_CACHE_SET=0
REMOTE_SECRET_CACHE="" REMOTE_SECRET_PLAIN_CACHE=""

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

# --- capabilities -------------------------------------------------------
CAPS_SHOW="${TMP}/caps-show.conf"
CAPS_STUB_RCLONE="${TMP}/stub-rclone-caps"
cat >"$CAPS_STUB_RCLONE" <<STUB
#!/bin/bash
cat "${CAPS_SHOW}"
STUB
chmod +x "$CAPS_STUB_RCLONE"
printf '[testremote]\ntype = webdav\nurl = https://cloud.example.org:8443/remote.php/dav/files/alice/\nuser = alice@example.org\nvendor = nextcloud\n' >"$CAPS_SHOW"
remote_config_invalidate
RCLONE_BIN="$CAPS_STUB_RCLONE"
RCLONE_CONFIG="${TMP}/caps-rclone.conf"
RCLONE_REMOTE="testremote"
expect_eq "capabilities_base_url: reads scheme://host:port from the remote" "https://cloud.example.org:8443" "$(capabilities_base_url)"
printf '[testremote]\ntype = webdav\nurl = cloud.example.org\n' >"$CAPS_SHOW"
remote_config_invalidate
expect_err "capabilities_base_url: rc 1 for an unusable url" capabilities_base_url

caps_json_new='{"ocs":{"meta":{"status":"ok","statuscode":200,"message":"OK"},"data":{"version":{"major":31,"minor":0,"micro":2,"string":"31.0.2","edition":"","extendedSupport":false},"capabilities":{"core":{"pollinterval":60,"webdav-root":"remote.php\/webdav"},"files":{"bigfilechunking":true,"undelete":true,"chunked_upload":{"max_size":104857600,"max_parallel":3}},"dav":{"chunking":"1.0"},"checksums":{"supportedTypes":["SHA256"]}}}}}'
capabilities_parse_json "$caps_json_new"
expect_eq "capabilities_parse_json: parses the version string" "31.0.2" "$CAP_VERSION"
expect_eq "capabilities_parse_json: parses bigfilechunking" "true" "$CAP_BIGFILE_CHUNKING"
expect_eq "capabilities_parse_json: parses chunked_upload max_size" "104857600" "$CAP_CHUNK_MAX_SIZE"
expect_eq "capabilities_parse_json: parses undelete" "true" "$CAP_UNDELETE"
expect_eq "capabilities_parse_json: parses checksums" "true" "$CAP_CHECKSUMS"

caps_json_old='{"ocs":{"meta":{"status":"ok","statuscode":200,"message":"OK"},"data":{"capabilities":{"files":{"bigfilechunking":true,"undelete":false,"chunked_upload":{"max_size":10485760}}}}}}'
capabilities_parse_json "$caps_json_old"
expect_eq "capabilities_parse_json: legacy server has no version" "" "$CAP_VERSION"
expect_eq "capabilities_parse_json: legacy bigfilechunking" "true" "$CAP_BIGFILE_CHUNKING"
expect_eq "capabilities_parse_json: legacy chunk max size" "10485760" "$CAP_CHUNK_MAX_SIZE"
expect_eq "capabilities_parse_json: legacy undelete false" "false" "$CAP_UNDELETE"
expect_eq "capabilities_parse_json: legacy checksums empty" "" "$CAP_CHECKSUMS"

# shellcheck disable=SC2016  # the payload's $() and backticks are intentional literals
caps_json_evil='{"ocs":{"data":{"version":{"string":"31.0.2; touch /tmp/pwned; $(id) `id`"},"capabilities":{"bigfilechunking":true,"chunked_upload":{"max_size":104857600}}}}}'
capabilities_parse_json "$caps_json_evil"
expect_eq "capabilities_parse_json: injection sanitized to allowed characters" "31.0.2touchtmppwnedidid" "$CAP_VERSION"
for cap_var in CAP_VERSION CAP_BIGFILE_CHUNKING CAP_CHUNK_MAX_SIZE CAP_UNDELETE CAP_CHECKSUMS; do
  cap_value="${!cap_var}"
  cap_safe=1
  # shellcheck disable=SC2016  # the needles are literal metacharacters
  case "$cap_value" in
    *';'* | *'`'* | *'$('*) cap_safe=0 ;;
  esac
  if [[ "$cap_safe" -eq 1 ]]; then
    pass "capabilities_parse_json: ${cap_var} free of shell metacharacters"
  else
    fail "capabilities_parse_json: ${cap_var} free of shell metacharacters" "unsanitized metacharacters"
  fi
done

CAPS_DIR="${TMP}/caps-unit"
mkdir -p "$CAPS_DIR"
CAPABILITIES_CACHE="${CAPS_DIR}/capabilities.env"
CAPABILITIES_MAX_AGE=3600
printf 'CAP_VERSION=31.0.2\nCAP_BIGFILE_CHUNKING=true\nCAP_CHUNK_MAX_SIZE=104857600\nCAP_UNDELETE=true\nCAP_CHECKSUMS=true\nCAP_PROBED_AT=1700000000\n' >"$CAPABILITIES_CACHE"
expect_ok "capabilities_cache_fresh: fresh cache rc 0" capabilities_cache_fresh
touch -t 202001010000 "$CAPABILITIES_CACHE"
expect_err "capabilities_cache_fresh: old cache rc 1" capabilities_cache_fresh
touch "$CAPABILITIES_CACHE"
CAPABILITIES_MAX_AGE=0
expect_err "capabilities_cache_fresh: CAPABILITIES_MAX_AGE=0 is always stale" capabilities_cache_fresh
CAPABILITIES_MAX_AGE=3600

CHUNK_SIZE="50Mi"
CAPABILITIES_CHUNK_RESOLVED=0 CAPABILITIES_CHUNK_VALUE=""
expect_eq "capabilities_sync_chunk_size: CHUNK_SIZE wins" "50Mi" "$(capabilities_sync_chunk_size)"
CHUNK_SIZE=""
printf '[testremote]\ntype = webdav\nurl = https://cloud.example.org/remote.php/dav/files/alice/\nvendor = nextcloud\n' >"$CAPS_SHOW"
remote_config_invalidate
CAPABILITIES_CHUNK_RESOLVED=0 CAPABILITIES_CHUNK_VALUE=""
expect_eq "capabilities_sync_chunk_size: fresh cache supplies nextcloud chunk" "104857600" "$(capabilities_sync_chunk_size)"
printf '[testremote]\ntype = webdav\nurl = https://cloud.example.org/remote.php/dav/files/alice/\nvendor = other\n' >"$CAPS_SHOW"
remote_config_invalidate
CAPABILITIES_CHUNK_RESOLVED=0 CAPABILITIES_CHUNK_VALUE=""
expect_eq "capabilities_sync_chunk_size: non-nextcloud vendor prints nothing" "" "$(capabilities_sync_chunk_size)"

# --- capabilities_chunk_for_duration (pure) -----------------------------
expect_eq "chunk_for_duration: throughput times duration" "10485760" \
  "$(MIN_CHUNK_SIZE='' MAX_CHUNK_SIZE='' capabilities_chunk_for_duration 10 1048576 1073741824)"
expect_eq "chunk_for_duration: clamps up to MIN_CHUNK_SIZE" "52428800" \
  "$(MIN_CHUNK_SIZE=50Mi MAX_CHUNK_SIZE='' capabilities_chunk_for_duration 1 1 1073741824)"
expect_eq "chunk_for_duration: clamps down to MAX_CHUNK_SIZE" "1048576" \
  "$(MIN_CHUNK_SIZE='' MAX_CHUNK_SIZE=1Mi capabilities_chunk_for_duration 2000 1000 1073741824)"
expect_eq "chunk_for_duration: caps at the server maximum" "104857600" \
  "$(MIN_CHUNK_SIZE='' MAX_CHUNK_SIZE='' capabilities_chunk_for_duration 1000 1048576 104857600)"
expect_eq "chunk_for_duration: server maximum wins over a larger MAX_CHUNK_SIZE" "104857600" \
  "$(MIN_CHUNK_SIZE='' MAX_CHUNK_SIZE=200Mi capabilities_chunk_for_duration 1000 1048576 104857600)"
expect_eq "chunk_for_duration: MIN and MAX bounds together" "2097152" \
  "$(MIN_CHUNK_SIZE=2Mi MAX_CHUNK_SIZE=5Mi capabilities_chunk_for_duration 1 1000 104857600)"
expect_ok "chunk_for_duration: within bounds rc 0" capabilities_chunk_for_duration 10 100 100000
expect_err "chunk_for_duration: missing duration rc 1" capabilities_chunk_for_duration "" 100 1000
expect_err "chunk_for_duration: non-numeric throughput rc 1" capabilities_chunk_for_duration 10 x 1000
expect_err "chunk_for_duration: zero throughput rc 1" capabilities_chunk_for_duration 10 0 1000
expect_err "chunk_for_duration: empty max rc 1" capabilities_chunk_for_duration 10 100 ""
expect_err "chunk_for_duration: zero max rc 1" capabilities_chunk_for_duration 10 100 0

# --- capabilities_sync_chunk_size: run-level derivation -----------------
printf '[testremote]\ntype = webdav\nurl = https://cloud.example.org/remote.php/dav/files/alice/\nvendor = nextcloud\n' >"$CAPS_SHOW"
remote_config_invalidate
CHUNK_SIZE=""
MIN_CHUNK_SIZE=""
MAX_CHUNK_SIZE=""
TARGET_CHUNK_UPLOAD_DURATION=10000
TARGET_UPLOAD_THROUGHPUT=1M
BW_LIMIT_UP=""
CAPABILITIES_CHUNK_RESOLVED=0 CAPABILITIES_CHUNK_VALUE=""
expect_eq "capabilities_sync_chunk_size: derives from duration and throughput" "10485760" "$(capabilities_sync_chunk_size)"
TARGET_CHUNK_UPLOAD_DURATION=10000
TARGET_UPLOAD_THROUGHPUT=1M
BW_LIMIT_UP=2M
CAPABILITIES_CHUNK_RESOLVED=0 CAPABILITIES_CHUNK_VALUE=""
expect_eq "capabilities_sync_chunk_size: BW_LIMIT_UP wins over TARGET_UPLOAD_THROUGHPUT" "20971520" "$(capabilities_sync_chunk_size)"
TARGET_UPLOAD_THROUGHPUT=""
BW_LIMIT_UP=""
CAPABILITIES_CHUNK_RESOLVED=0 CAPABILITIES_CHUNK_VALUE=""
expect_eq "capabilities_sync_chunk_size: no throughput falls back to the capability max" "104857600" "$(capabilities_sync_chunk_size)"
TARGET_CHUNK_UPLOAD_DURATION=30s
TARGET_UPLOAD_THROUGHPUT=1M
CAPABILITIES_CHUNK_RESOLVED=0 CAPABILITIES_CHUNK_VALUE=""
expect_eq "capabilities_sync_chunk_size: suffixed duration is accepted" "31457280" "$(capabilities_sync_chunk_size)"
TARGET_CHUNK_UPLOAD_DURATION=60000
TARGET_UPLOAD_THROUGHPUT=1M
MAX_CHUNK_SIZE=10Mi
CAPABILITIES_CHUNK_RESOLVED=0 CAPABILITIES_CHUNK_VALUE=""
expect_eq "capabilities_sync_chunk_size: derived value honors MAX_CHUNK_SIZE" "10485760" "$(capabilities_sync_chunk_size)"
TARGET_CHUNK_UPLOAD_DURATION=""
TARGET_UPLOAD_THROUGHPUT=""
MIN_CHUNK_SIZE=""
MAX_CHUNK_SIZE=""

CAPABILITIES_CHUNK_RESOLVED=0 CAPABILITIES_CHUNK_VALUE=""
CAPABILITIES_CACHE=""
RCLONE_BIN=""
RCLONE_REMOTE=""
RCLONE_CONFIG=""

# --- size_suffix_bytes: pure-bash decimal parse -------------------------
expect_eq "size_suffix_bytes: plain bytes" "42" "$(size_suffix_bytes 42)"
expect_eq "size_suffix_bytes: binary mega" "5242880" "$(size_suffix_bytes 5M)"
expect_eq "size_suffix_bytes: decimal kilo" "100000" "$(size_suffix_bytes 100KB)"
expect_eq "size_suffix_bytes: decimal fraction" "1572864" "$(size_suffix_bytes 1.5M)"
expect_eq "size_suffix_bytes: half rounds to even" "2" "$(size_suffix_bytes 2.5)"
expect_eq "size_suffix_bytes: half rounds up to even" "4" "$(size_suffix_bytes 3.5)"
expect_eq "size_suffix_bytes: above half rounds up" "2" "$(size_suffix_bytes 1.75)"
expect_eq "size_suffix_bytes: below half rounds down" "1" "$(size_suffix_bytes 1.25)"
expect_eq "size_suffix_bytes: leading zeros" "7" "$(size_suffix_bytes 007)"
expect_eq "size_suffix_bytes: zero fraction" "0" "$(size_suffix_bytes 00.5)"
size_suffix_bytes "1." >/dev/null 2>&1
expect_rc "size_suffix_bytes: trailing dot rejected" "$?" 1
size_suffix_bytes ".5" >/dev/null 2>&1
expect_rc "size_suffix_bytes: leading dot rejected" "$?" 1
size_suffix_bytes "1.2.3" >/dev/null 2>&1
expect_rc "size_suffix_bytes: two dots rejected" "$?" 1
size_suffix_bytes "5Z" >/dev/null 2>&1
expect_rc "size_suffix_bytes: bad unit rejected" "$?" 1
size_suffix_bytes "" >/dev/null 2>&1
expect_rc "size_suffix_bytes: empty rejected" "$?" 1

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

# --- _opt_spec_lookup ---------------------------------------------------
# The lookup writes OPT_LOOKUP_KIND/OPT_LOOKUP_DEFAULT instead of printing,
# so opt_parse avoids a command-substitution fork per option.
rc=0
_opt_spec_lookup "history:o:10 quiet:b" history || rc=$?
expect_rc "_opt_spec_lookup: kind and default rc" "$rc" 0
expect_eq "_opt_spec_lookup: kind" "o" "$OPT_LOOKUP_KIND"
expect_eq "_opt_spec_lookup: default" "10" "$OPT_LOOKUP_DEFAULT"
rc=0
_opt_spec_lookup "only:s" only || rc=$?
expect_rc "_opt_spec_lookup: single value rc" "$rc" 0
expect_eq "_opt_spec_lookup: single value kind" "s" "$OPT_LOOKUP_KIND"
expect_eq "_opt_spec_lookup: single value empty default" "" "$OPT_LOOKUP_DEFAULT"
rc=0
_opt_spec_lookup "quiet:b" quiet || rc=$?
expect_rc "_opt_spec_lookup: boolean rc" "$rc" 0
expect_eq "_opt_spec_lookup: boolean kind" "b" "$OPT_LOOKUP_KIND"
expect_eq "_opt_spec_lookup: boolean empty default" "" "$OPT_LOOKUP_DEFAULT"
rc=0
_opt_spec_lookup "only:s" bogus >/dev/null 2>&1 || rc=$?
expect_rc "_opt_spec_lookup: missing name returns 1" "$rc" 1
rc=0
_opt_spec_lookup "broken:" broken >/dev/null 2>&1 || rc=$?
expect_rc "_opt_spec_lookup: empty kind returns 1" "$rc" 1

# --- opt_parse kind o: optional values ----------------------------------
# A bare flag takes the SPEC default; an attached (--name=VALUE) or a
# following non-dash token wins; an option-like token is left for opt_parse
# and the default is used instead.
OPT_history=""
OPT_history_SET=""
opt_reset history quiet
opt_parse "history:o:10 quiet:b" sync "" --history 5
expect_eq "opt_parse: optional value form" "5" "$OPT_history"
expect_eq "opt_parse: optional value set marker" "1" "$OPT_history_SET"
opt_reset history quiet
opt_parse "history:o:10 quiet:b" sync "" --history=7
expect_eq "opt_parse: optional = form" "7" "$OPT_history"
expect_eq "opt_parse: optional = form set marker" "1" "$OPT_history_SET"
opt_reset history quiet
opt_parse "history:o:10 quiet:b" sync "" --history
expect_eq "opt_parse: optional missing value uses the default" "10" "$OPT_history"
expect_eq "opt_parse: optional missing value set marker" "1" "$OPT_history_SET"
opt_reset history quiet
opt_parse "history:o:10 quiet:b" sync "" --history --quiet
expect_eq "opt_parse: optional flag before another option keeps the default" "10" "$OPT_history"
expect_eq "opt_parse: optional flag before another option parses it" "1" "$OPT_quiet"
opt_reset history quiet
opt_parse "history:o:" sync "" --history
expect_eq "opt_parse: optional empty default" "" "$OPT_history"
expect_eq "opt_parse: optional empty default set marker" "1" "$OPT_history_SET"
opt_reset history quiet
rc=0
(opt_parse "history:o:10" sync "" --bogus) >/dev/null 2>"$opt_err" || rc=$?
expect_rc "opt_parse: optional unknown option exits 2" "$rc" 2
expect_contains "opt_parse: optional unknown option message" "$(cat "$opt_err")" "unknown option: --bogus"
opt_reset history quiet

# --- opt_require_uint / opt_require_sub / duration_parse_or_usage --------
# usage_error exits 2 and prints through usage_<command>; the probe stub
# keeps stderr to the message under test.
# shellcheck disable=SC2329  # invoked indirectly through usage_error
usage_optprobe() { :; }
opt_err="${TMP}/opt-require.err"
rc=0
opt_require_uint optprobe --limit 5 1 10 >/dev/null 2>"$opt_err" || rc=$?
expect_rc "opt_require_uint: in-range value rc" "$rc" 0
rc=0
opt_require_uint optprobe --limit 10 1 10 >/dev/null 2>"$opt_err" || rc=$?
expect_rc "opt_require_uint: max boundary rc" "$rc" 0
rc=0
(opt_require_uint optprobe --limit abc 1 10) >/dev/null 2>"$opt_err" || rc=$?
expect_rc "opt_require_uint: non-numeric exits 2" "$rc" 2
expect_contains "opt_require_uint: positive-integer message" "$(cat "$opt_err")" \
  "--limit requires a positive integer"
rc=0
(opt_require_uint optprobe --limit 0 1 10) >/dev/null 2>"$opt_err" || rc=$?
expect_rc "opt_require_uint: below min exits 2" "$rc" 2
expect_contains "opt_require_uint: below min names the positive form" \
  "$(cat "$opt_err")" "--limit requires a positive integer"
rc=0
(opt_require_uint optprobe --limit abc 0) >/dev/null 2>"$opt_err" || rc=$?
expect_rc "opt_require_uint: min 0 non-numeric exits 2" "$rc" 2
expect_contains "opt_require_uint: min 0 names the non-negative form" \
  "$(cat "$opt_err")" "--limit requires a non-negative integer"
rc=0
opt_require_uint optprobe --limit 0 0 >/dev/null 2>"$opt_err" || rc=$?
expect_rc "opt_require_uint: min 0 accepts zero" "$rc" 0
rc=0
(opt_require_uint optprobe --limit 11 1 10) >/dev/null 2>"$opt_err" || rc=$?
expect_rc "opt_require_uint: above max exits 2" "$rc" 2
expect_contains "opt_require_uint: max message" "$(cat "$opt_err")" \
  "--limit must be at most 10"

rc=0
opt_require_sub optprobe SUB $'one\n' >/dev/null 2>"$opt_err" || rc=$?
expect_rc "opt_require_sub: one positional rc" "$rc" 0
expect_eq "opt_require_sub: leaves POSITIONAL_ARGS" "1|one" \
  "${#POSITIONAL_ARGS[@]}|${POSITIONAL_ARGS[0]:-}"
rc=0
(opt_require_sub optprobe SUB "") >/dev/null 2>"$opt_err" || rc=$?
expect_rc "opt_require_sub: missing exits 2" "$rc" 2
expect_contains "opt_require_sub: missing message" "$(cat "$opt_err")" \
  "SUB is required"
rc=0
(opt_require_sub optprobe "a remote path argument" "") >/dev/null 2>"$opt_err" || rc=$?
expect_contains "opt_require_sub: label phrases the missing message" \
  "$(cat "$opt_err")" "a remote path argument is required"
rc=0
opt_require_sub optprobe SUB "" 0 >/dev/null 2>"$opt_err" || rc=$?
expect_rc "opt_require_sub: optional positional accepts none" "$rc" 0
rc=0
(opt_require_sub optprobe SUB $'one\ntwo\n') >/dev/null 2>"$opt_err" || rc=$?
expect_rc "opt_require_sub: extra positional exits 2" "$rc" 2
expect_contains "opt_require_sub: default too-many is exactly one" \
  "$(cat "$opt_err")" "exactly one SUB argument is allowed"
rc=0
(opt_require_sub optprobe SUB $'one\ntwo\n' 0) >/dev/null 2>"$opt_err" || rc=$?
expect_contains "opt_require_sub: MIN=0 too-many is at most one" \
  "$(cat "$opt_err")" "at most one SUB argument is allowed"
rc=0
(opt_require_sub optprobe SUB $'a\nb\nc\n' 1 2) >/dev/null 2>"$opt_err" || rc=$?
expect_contains "opt_require_sub: MAX=2 too-many is at most two" \
  "$(cat "$opt_err")" "at most two SUB arguments are allowed"
rc=0
(opt_require_sub optprobe term $'one\ntwo\n' 1 1 \
  "search accepts exactly one term; quote a term with spaces") \
  >/dev/null 2>"$opt_err" || rc=$?
expect_rc "opt_require_sub: verbatim too-many exits 2" "$rc" 2
expect_contains "opt_require_sub: verbatim too-many message" "$(cat "$opt_err")" \
  "search accepts exactly one term; quote a term with spaces"

rc=0
out="$(duration_parse_or_usage optprobe --since 90m)" || rc=$?
expect_rc "duration_parse_or_usage: valid duration rc" "$rc" 0
expect_eq "duration_parse_or_usage: prints seconds" "5400" "$out"
rc=0
out="$(duration_parse_or_usage optprobe --since 5x requires 2>&1)" || rc=$?
expect_rc "duration_parse_or_usage: bad duration exits 2" "$rc" 2
expect_contains "duration_parse_or_usage: requires style" "$out" \
  "--since requires a duration like 90m, 24h, or 7d"
rc=0
out="$(duration_parse_or_usage optprobe "" 5x 2>&1)" || rc=$?
expect_rc "duration_parse_or_usage: flagless invalid exits 2" "$rc" 2
expect_contains "duration_parse_or_usage: flagless invalid message" "$out" \
  "invalid duration: 5x (use <N>[smhd], e.g. 90m, 24h, 7d)"
rc=0
out="$(duration_parse_or_usage optprobe --clear-after 5x 2>&1)" || rc=$?
expect_contains "duration_parse_or_usage: flagged invalid message" "$out" \
  "invalid --clear-after duration: 5x"

# --- split_positionals_into / split_command_args / opt_reject -------------
# The shared helpers the subcommand parsers, the fd-password readers, and the
# source-resolution failures adopt. usage_error exits 2 through the optprobe
# stub above.
OPT_EXTRA=$'one\ntwo\n'
x1="" x2="" x3=""
split_positionals_into x1 x2 x3
expect_eq "split_positionals_into: first" "one" "$x1"
expect_eq "split_positionals_into: second" "two" "$x2"
expect_eq "split_positionals_into: missing stays empty" "" "$x3"
expect_eq "split_positionals_into: leaves POSITIONAL_ARGS" "2" "${#POSITIONAL_ARGS[@]}"
OPT_EXTRA=""
x1="keep"
split_positionals_into x1 x2
expect_eq "split_positionals_into: empty input clears the first" "" "$x1"
expect_eq "split_positionals_into: empty input count" "0" "${#POSITIONAL_ARGS[@]}"

csub="" carg1="" carg2="" cargc=""
split_command_args $'sub\narg1\narg2\n' csub carg1 carg2 cargc
expect_eq "split_command_args: sub" "sub" "$csub"
expect_eq "split_command_args: arg1" "arg1" "$carg1"
expect_eq "split_command_args: arg2" "arg2" "$carg2"
expect_eq "split_command_args: argc" "3" "$cargc"
split_command_args $'sub\n' csub carg1 carg2 cargc
expect_eq "split_command_args: short sub kept" "sub" "$csub"
expect_eq "split_command_args: short arg1 empty" "" "$carg1"
expect_eq "split_command_args: short argc" "1" "$cargc"

# shellcheck disable=SC2034  # OPT_*_SET markers are read dynamically in opt_reject
OPT_json_SET="" OPT_yes_SET=""
rc=0
opt_reject optprobe add json yes limit >/dev/null 2>"$opt_err" || rc=$?
expect_rc "opt_reject: no flag set rc" "$rc" 0
OPT_yes_SET=1
rc=0
(opt_reject optprobe add json yes limit) >/dev/null 2>"$opt_err" || rc=$?
expect_rc "opt_reject: set flag exits 2" "$rc" 2
expect_contains "opt_reject: names the subcommand and flag" "$(cat "$opt_err")" \
  "add does not accept --yes"
# shellcheck disable=SC2034  # read dynamically in opt_reject
OPT_yes_SET=""

# --- opt_read_fd_secret / unknown_source_prefix --------------------------
printf 'sekret\n' >"$TMP/fd-secret"
exec 3<"$TMP/fd-secret"
got=""
rc=0
opt_read_fd_secret optprobe --password-fd got 3 >/dev/null 2>"$opt_err" || rc=$?
expect_rc "opt_read_fd_secret: reads a real fd rc" "$rc" 0
expect_eq "opt_read_fd_secret: reads the value" "sekret" "$got"
exec 3<&-
rc=0
(opt_read_fd_secret optprobe --password-fd got abc) >/dev/null 2>"$opt_err" || rc=$?
expect_rc "opt_read_fd_secret: non-number exits 2" "$rc" 2
expect_contains "opt_read_fd_secret: non-number message" "$(cat "$opt_err")" \
  "--password-fd requires a file descriptor number"
rc=0
(opt_read_fd_secret optprobe --password-fd got 0) >/dev/null 2>"$opt_err" || rc=$?
expect_rc "opt_read_fd_secret: zero exits 2" "$rc" 2
expect_contains "opt_read_fd_secret: positive message" "$(cat "$opt_err")" \
  "--password-fd requires a positive file descriptor number"
rc=0
(opt_read_fd_secret optprobe --password-fd got 9 9<&-) >/dev/null 2>"$opt_err" || rc=$?
expect_rc "opt_read_fd_secret: unreadable fd exits 2" "$rc" 2
expect_contains "opt_read_fd_secret: unreadable message" "$(cat "$opt_err")" \
  "--password-fd 9 is not readable"
printf '\n' >"$TMP/fd-empty"
exec 3<"$TMP/fd-empty"
rc=0
(opt_read_fd_secret optprobe --password-fd got 3) >/dev/null 2>"$opt_err" || rc=$?
expect_rc "opt_read_fd_secret: empty value exits 2" "$rc" 2
expect_contains "opt_read_fd_secret: empty message" "$(cat "$opt_err")" \
  "--password-fd 3 provided an empty password"
exec 3<&-

expect_eq "unknown_source_prefix: plain name" "no source named 'plain'" \
  "$(unknown_source_prefix plain)"
expect_eq "unknown_source_prefix: strips control bytes" "no source named 'evilname'" \
  "$(unknown_source_prefix $'evil\tname')"

# --- sync_build_args: optional transfer knobs ---------------------------
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/commands/sync.sh
source "${LIB_DIR}/commands/sync.sh"
# sync_args_probe MODE [ENV=...]... - print one argument per line from
# sync_build_args for MODE; the ENV arguments override the probe defaults.
sync_args_probe() {
  local mode="$1"
  shift
  # shellcheck disable=SC2016  # the -c program expands "$1" itself
  env "SYNC_PROBE_MODE=$mode" "$@" bash -c '
    set -uo pipefail
    source "$1/lib/core.sh"
    source "$1/lib/rclone.sh"
    source "$1/lib/settings.sh"
    source "$1/lib/manifest.sh"
    source "$1/lib/ui.sh"
    source "$1/lib/commands/sync.sh"
    : "${TRANSFERS:=1}" "${CHECKERS:=4}" "${TPSLIMIT:=8}" "${RETRIES:=3}" "${LOW_LEVEL_RETRIES:=10}"
    : "${TIMEOUT:=10m}" "${CONTIMEOUT:=30s}" "${STATS:=30s}" "${LOG_LEVEL:=INFO}"
    : "${CREATE_EMPTY_SRC_DIRS:=0}" "${TRACK_RENAMES:=0}" "${MAX_DELETE:=-1}"
    : "${BW_LIMIT_UP:=}" "${BW_LIMIT_DOWN:=}" "${SYNC_CHUNK_SIZE:=}"
    : "${CONFLICT_UPLOAD:=0}" "${CONFLICT_PATTERN:=conflicted copy}"
    ENTRY_MODE="$SYNC_PROBE_MODE" ENTRY_FILTER="" ENTRY_NAME=probe ENTRY_REMOTE=probe
    ENTRY_LOCAL="/tmp/probe-src"
    SYNC_APPLY=false SYNC_ASSUME_YES=false SYNC_RESYNC="${SYNC_PROBE_RESYNC:-false}"
    : "${BISYNC_CONFLICT_RESOLVE:=newer}" "${BISYNC_CONFLICT_LOSER:=num}"
    : "${BISYNC_CONFLICT_SUFFIX:=(conflicted copy)}" "${BISYNC_MAX_LOCK:=2m}"
    : "${BISYNC_RESYNC_MODE:=newer}" "${BISYNC_RESILIENT:=1}" "${BISYNC_RECOVER:=1}"
    : "${BISYNC_DIR:=/tmp/probe-bisync}" "${FILTER_DIR:=/tmp/probe-filters}"
    sync_build_args "remote:base/probe" "/tmp/probe.log"
    printf "%s\n" "${SYNC_ARGS[@]}"
  ' sync-args-probe "$PROJ_DIR" 2>&1
}
out="$(sync_args_probe sync)"
expect_contains "sync_build_args: sync entry recorded" "$out" "sync
/tmp/probe-src/
remote:base/probe/"
expect_contains "sync_build_args: dry run by default" "$out" "--dry-run"
expect_not_contains "sync_build_args: --create-empty-src-dirs off by default" "$out" "--create-empty-src-dirs"
expect_not_contains "sync_build_args: --max-delete off by default" "$out" "--max-delete"
expect_not_contains "sync_build_args: --track-renames off by default" "$out" "--track-renames"
expect_not_contains "sync_build_args: --bwlimit off by default" "$out" "--bwlimit"
out="$(sync_args_probe sync CREATE_EMPTY_SRC_DIRS=1 MAX_DELETE=7 TRACK_RENAMES=1 BW_LIMIT_UP=1M BW_LIMIT_DOWN=off)"
expect_contains "sync_build_args: --create-empty-src-dirs recorded" "$out" "--create-empty-src-dirs"
expect_contains "sync_build_args: --max-delete value recorded" "$out" $'--max-delete\n7'
expect_contains "sync_build_args: --track-renames recorded for sync" "$out" "--track-renames"
expect_contains "sync_build_args: --bwlimit up:down recorded" "$out" $'--bwlimit\n1M:off'
out="$(sync_args_probe sync MAX_DELETE=0)"
expect_contains "sync_build_args: --max-delete 0 is recorded" "$out" $'--max-delete\n0'
out="$(sync_args_probe sync BW_LIMIT_DOWN=5M)"
expect_contains "sync_build_args: --bwlimit with only down recorded" "$out" $'--bwlimit\noff:5M'
out="$(sync_args_probe pull TRACK_RENAMES=1)"
expect_contains "sync_build_args: pull reverses src and dst" "$out" "sync
remote:base/probe/
/tmp/probe-src/"
expect_contains "sync_build_args: --track-renames recorded for pull" "$out" "--track-renames"
out="$(sync_args_probe bisync TRACK_RENAMES=1)"
expect_contains "sync_build_args: bisync entry recorded" "$out" "bisync
/tmp/probe-src/
remote:base/probe/"
expect_not_contains "sync_build_args: no --track-renames for bisync" "$out" "--track-renames"
expect_not_contains "sync_build_args: no --resync-mode for incremental bisync" "$out" "--resync-mode"
out="$(sync_args_probe bisync SYNC_PROBE_RESYNC=true)"
expect_contains "sync_build_args: resync passes --resync-mode" "$out" $'--resync-mode\nnewer'
expect_contains "sync_build_args: resync passes --resync" "$out" $'\n--resync\n'
out="$(sync_args_probe sync)"
expect_contains "sync_build_args: conflict copies excluded by default" "$out" $'--exclude\n*conflicted copy*'
out="$(sync_args_probe sync CONFLICT_UPLOAD=1)"
expect_not_contains "sync_build_args: CONFLICT_UPLOAD=1 uploads conflict copies" "$out" "*conflicted copy*"
out="$(sync_args_probe pull)"
expect_contains "sync_build_args: pull excludes conflict copies" "$out" $'--exclude\n*conflicted copy*'
out="$(sync_args_probe bisync)"
expect_contains "sync_build_args: bisync excludes conflict copies" "$out" $'--exclude\n*conflicted copy*'
out="$(sync_args_probe sync CONFLICT_PATTERN=clash)"
expect_contains "sync_build_args: CONFLICT_PATTERN feeds the exclude" "$out" $'--exclude\n*clash*'

# --- sync_report_plan / sync_report_conflicts ---------------------------
plan_log="${TMP}/sync-plan.log"
printf '%s\n' \
  '2026/09/19 18:22:45 NOTICE: a.txt: Skipped copy as --dry-run is set (size 6)' \
  '2026/09/19 18:22:45 NOTICE: b.txt: Skipped delete as --dry-run is set (size 6)' \
  '2026/09/19 18:22:45 NOTICE: c.txt: Skipped update modification time as --dry-run is set (size 4)' \
  '2026/09/19 18:22:45 NOTICE: a.txt: Skipped copy as --dry-run is set (size 6)' >"$plan_log"
expect_eq "sync_report_plan: counts and deduped samples" \
  "plan: 2 to copy, 1 to delete, 1 other (e.g. a.txt, b.txt, c.txt)" \
  "$(sync_report_plan "$plan_log")"
printf '2026/09/19 18:22:45 NOTICE: nothing skipped here\n' >"$plan_log"
expect_eq "sync_report_plan: empty plan says no changes" "plan: no changes" "$(sync_report_plan "$plan_log")"
expect_eq "sync_report_plan: missing log prints nothing" "" "$(sync_report_plan "${TMP}/no-such-plan.log")"

conflict_log="${TMP}/sync-conflict.log"
printf '%s\n' \
  '2026/09/19 18:22:45 NOTICE: - Path1             Renaming Path1 copy                         - /tmp/x/clash.txt.(conflicted copy)1' \
  '2026/09/19 18:22:45 NOTICE: - Path2             Renaming Path2 copy                         - /tmp/x/other.txt.(conflicted copy)2' \
  '2026/09/19 18:22:45 NOTICE: - Path2             Not renaming Path2 copy, as it was determined the winner - /tmp/x/clash.txt' >"$conflict_log"
SYNC_CONFLICTS=0
conflict_out="$(sync_report_conflicts "$conflict_log")"
expect_eq "sync_report_conflicts: counts and samples" \
  "conflicts: 2 copy(ies) created (e.g. /tmp/x/clash.txt.(conflicted copy)1, /tmp/x/other.txt.(conflicted copy)2)" \
  "$conflict_out"
printf '2026/09/19 18:22:45 NOTICE: nothing to see\n' >"$conflict_log"
conflict_out="$(sync_report_conflicts "$conflict_log")"
expect_eq "sync_report_conflicts: clean log prints nothing" "" "$conflict_out"
# SYNC_CONFLICTS accumulates across calls in the same shell.
printf '%s\n' \
  '2026/09/19 18:22:45 NOTICE: - Path1             Renaming Path1 copy                         - /tmp/x/clash.txt.(conflicted copy)1' >"$conflict_log"
SYNC_CONFLICTS=1
sync_report_conflicts "$conflict_log" >/dev/null
expect_eq "sync_report_conflicts: total accumulates" "2" "$SYNC_CONFLICTS"

# --- sync_notify: failures beat conflicts, conflicts beat success --------
saved_path="$PATH"
PATH="${NOTIFY_BIN}:$PATH"
SYNC_APPLY=true SYNC_TOTAL=2 SYNC_FAILED=0 SYNC_OK=2 SYNC_CONFLICTS=1
SYNC_FAILED_NAMES="" NOTIFY=1 NOTIFY_SUCCESS=0
rm -f "${NOTIFY_BIN}/calls.log"
sync_notify
expect_contains "sync_notify: conflict notification sent" "$(cat "${NOTIFY_BIN}/calls.log")" "sciebo conflicts"
rm -f "${NOTIFY_BIN}/calls.log"
SYNC_CONFLICTS=0
sync_notify
expect_no_file "sync_notify: success stays silent with NOTIFY_SUCCESS=0" "${NOTIFY_BIN}/calls.log"
rm -f "${NOTIFY_BIN}/calls.log"
NOTIFY_SUCCESS=1
sync_notify
expect_contains "sync_notify: success notification sent" "$(cat "${NOTIFY_BIN}/calls.log")" "sciebo sync finished"
rm -f "${NOTIFY_BIN}/calls.log"
SYNC_APPLY=false
sync_notify
expect_no_file "sync_notify: dry runs never notify" "${NOTIFY_BIN}/calls.log"
rm -f "${NOTIFY_BIN}/calls.log"
SYNC_APPLY=true SYNC_TOTAL=1 SYNC_FAILED=1 SYNC_CONFLICTS=1 NOTIFY_SUCCESS=1
SYNC_FAILED_NAMES=$'broken\n'
sync_notify
expect_contains "sync_notify: failure notification beats conflicts" "$(cat "${NOTIFY_BIN}/calls.log")" "sciebo sync failed"
expect_contains "sync_notify: failure notification names the source" "$(cat "${NOTIFY_BIN}/calls.log")" "broken"
PATH="$saved_path"
SYNC_APPLY=false SYNC_TOTAL=0 SYNC_FAILED=0 SYNC_OK=0 SYNC_CONFLICTS=0 SYNC_FAILED_NAMES=""
NOTIFY=0 NOTIFY_SUCCESS=0

# --- schedule template XML escaping -------------------------------------
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/commands/schedule.sh
source "${LIB_DIR}/commands/schedule.sh"
SCHEDULE_TEMPLATE_FILE="${TMP}/template.plist"
printf '<string>@PROJECT_DIR@</string>\n<string>@LABEL@</string>\n<string>@RCLONE_DIR@</string>\n<string>@LOG_DIR@</string>\n<string>@COMMAND@</string>\n<string>@SCHEDULE@</string>\n<string>@WATCH_PATHS@</string>\n' >"$SCHEDULE_TEMPLATE_FILE"
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

# --- schedule command, schedule block, and watch paths -------------------
PROJECT_DIR="${PROJ_DIR}"
LOG_DIR="${TMP}/schedule-logs"
SCHEDULE_RCLONE_DIR=""
SCHEDULE_INTERVAL=""
SCHEDULE_JITTER=0
SCHEDULE_WATCH_PATH=""
rendered="$(schedule_render_template)"
expect_contains "schedule render: default uses StartCalendarInterval" "$rendered" "<key>StartCalendarInterval</key>"
expect_not_contains "schedule render: default has no StartInterval" "$rendered" "StartInterval"
expect_not_contains "schedule render: default has no WatchPaths" "$rendered" "WatchPaths"
expect_contains "schedule render: command runs sync --apply --quiet" "$rendered" "bin/sciebo sync --apply --quiet"

SCHEDULE_INTERVAL=3600
rendered="$(schedule_render_template)"
expect_contains "schedule render: interval uses StartInterval" "$rendered" $'<key>StartInterval</key>\n  <integer>3600</integer>'
expect_not_contains "schedule render: interval has no calendar block" "$rendered" "StartCalendarInterval"

SCHEDULE_INTERVAL=""
SCHEDULE_JITTER=300
rendered="$(schedule_render_template)"
# shellcheck disable=SC2016  # the jitter expression must stay literal
expect_contains "schedule render: jitter prefixes the command" "$rendered" "sleep \$((RANDOM % 300)); exec ${SCIEBO_BASH}"
expect_not_contains "schedule render: jitter keeps the calendar schedule" "$rendered" "StartInterval"

SCHEDULE_JITTER=0
SCHEDULE_WATCH_PATH="${TMP}/watch & <dir>"
mkdir -p "$SCHEDULE_WATCH_PATH"
rendered="$(schedule_render_template)"
expect_contains "schedule render: watch path uses WatchPaths" "$rendered" "<key>WatchPaths</key>"
expect_contains "schedule render: watch path XML-escaped" "$rendered" "&amp; &lt;dir&gt;"

SCHEDULE_INTERVAL=""
SCHEDULE_JITTER=0
SCHEDULE_WATCH_PATH=""
PROJECT_DIR="${PROJ_DIR}"
LOG_DIR="${TMP}/lock-state/logs"

# --- cleanup_age_minutes -------------------------------------------------
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/commands/cleanup.sh
source "${LIB_DIR}/commands/cleanup.sh"
while IFS='|' read -r name input want rc_want; do
  rc=0
  out="$(cleanup_age_minutes "$input" 2>/dev/null)" || rc=$?
  expect_rc "${name}: rc" "$rc" "$rc_want"
  [[ "$rc_want" -ne 0 ]] || expect_eq "$name" "$want" "$out"
done <<'EOF'
cleanup_age_minutes: seconds truncate to minutes|45s|0|0
cleanup_age_minutes: bare number is minutes|5|5|0
cleanup_age_minutes: minutes suffix|90m|90|0
cleanup_age_minutes: hours suffix|2h|120|0
cleanup_age_minutes: days suffix|1d|1440|0
cleanup_age_minutes: empty dies|||1
cleanup_age_minutes: unknown unit dies|5x||1
EOF

# --- trash / versions / mount command libraries -------------------------
# The modules are sourced without RCLONE_BIN; their parsers and
# build_mount_argv are pure, and the argv probe runs in a clean subprocess.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/commands/trash.sh
source "${LIB_DIR}/commands/trash.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/commands/versions.sh
source "${LIB_DIR}/commands/versions.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/commands/mount.sh
source "${LIB_DIR}/commands/mount.sh"

# trash_parse_xml: TAB records, entity decoding, missing properties,
# percent-escaped hrefs, and the root collection row (the CLI skips it
# because the parsed name is empty).
trash_xml='<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
  <d:response>
    <d:href>/remote.php/dav/trashbin/alice/trash/</d:href>
    <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/dav/trashbin/alice/trash/Q&amp;A report.txt.d1700000000</d:href>
    <d:propstat><d:prop>
      <oc:trashbin-original-filename>Q&amp;A report.txt</oc:trashbin-original-filename>
      <oc:trashbin-original-location>docs/Q&amp;A report.txt</oc:trashbin-original-location>
      <oc:trashbin-delete-timestamp>1700000000</oc:trashbin-delete-timestamp>
      <d:getcontentlength>2048</d:getcontentlength>
    </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/dav/trashbin/alice/trash/notes.txt.d1700000100</d:href>
    <d:propstat><d:prop>
      <oc:trashbin-original-filename>notes.txt</oc:trashbin-original-filename>
      <oc:trashbin-original-location>notes.txt</oc:trashbin-original-location>
    </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/dav/trashbin/alice/trash/Vertr%C3%A4ge.d1700000200</d:href>
    <d:propstat><d:prop>
      <oc:trashbin-original-filename>Verträge</oc:trashbin-original-filename>
      <oc:trashbin-original-location>Verträge</oc:trashbin-original-location>
      <oc:trashbin-delete-timestamp>1700000200</oc:trashbin-delete-timestamp>
      <d:getcontentlength>99</d:getcontentlength>
    </d:prop></d:propstat>
  </d:response>
</d:multistatus>'
want=$'\t\t\t\ttrash'
want="${want}"$'\n'"Q&A report.txt"$'\t'"docs/Q&A report.txt"$'\t1700000000\t2048\t'"Q&A report.txt.d1700000000"
want="${want}"$'\n'"notes.txt"$'\tnotes.txt\t\t\tnotes.txt.d1700000100'
want="${want}"$'\n'"Verträge"$'\t'"Verträge"$'\t1700000200\t99\tVerträge.d1700000200'
expect_eq "trash_parse_xml: TAB records with escapes and gaps" "$want" "$(trash_parse_xml "$trash_xml")"
expect_contains "trash_parse_xml: root collection row kept by the parser" \
  "$(trash_parse_xml "$trash_xml")" $'\t\t\t\ttrash'
expect_contains "trash_parse_xml: percent-escaped href decoded" \
  "$(trash_parse_xml "$trash_xml")" "Verträge.d1700000200"

# Hostile XML values must stay literal: the parser only reads and prints.
hostile_trash="<d:multistatus><d:response><d:href>/remote.php/dav/trashbin/alice/trash/x.d1</d:href><d:propstat><d:prop><oc:trashbin-original-filename>\$(touch ${TMP}/trash-pwned) \`touch ${TMP}/trash-pwned\`</oc:trashbin-original-filename></d:prop></d:propstat></d:response></d:multistatus>"
hostile_out="$(trash_parse_xml "$hostile_trash")"
expect_contains "trash_parse_xml: hostile payload stays literal" "$hostile_out" "\$(touch ${TMP}/trash-pwned)"
expect_no_file "trash_parse_xml: hostile payload never executes" "${TMP}/trash-pwned"

# versions_parse_fileid: numeric ids, multiline tags, self-closed tags.
expect_eq "versions_parse_fileid: numeric id" "12345" \
  "$(versions_parse_fileid '<d:multistatus><d:response><d:propstat><d:prop><oc:fileid>12345</oc:fileid></d:prop></d:propstat></d:response></d:multistatus>')"
expect_eq "versions_parse_fileid: multiline id" "12345" \
  "$(versions_parse_fileid "$(printf '<oc:fileid>\n  12345  \n</oc:fileid>')")"
expect_eq "versions_parse_fileid: self-closed tag is empty" "" "$(versions_parse_fileid '<oc:fileid/>')"
expect_eq "versions_parse_fileid: missing property is empty" "" "$(versions_parse_fileid '<d:multistatus/>')"
expect_eq "versions_parse_fileid: non-numeric value is empty" "" "$(versions_parse_fileid '<oc:fileid>abc</oc:fileid>')"

# versions_parse_xml: full and missing sizes; the parser keeps the
# collection row (cmd_versions skips it when version == fileid).
versions_xml='<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/remote.php/dav/versions/alice/versions/42/</d:href>
    <d:propstat><d:prop>
      <d:getlastmodified>Wed, 01 Nov 2023 00:00:00 GMT</d:getlastmodified>
    </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/dav/versions/alice/versions/42/1700000000</d:href>
    <d:propstat><d:prop>
      <d:getlastmodified>Wed, 01 Nov 2023 01:00:00 GMT</d:getlastmodified>
      <d:getcontentlength>1024</d:getcontentlength>
    </d:prop></d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/dav/versions/alice/versions/42/1700000100</d:href>
    <d:propstat><d:prop>
      <d:getlastmodified>Wed, 01 Nov 2023 02:00:00 GMT</d:getlastmodified>
    </d:prop></d:propstat>
  </d:response>
</d:multistatus>'
want=$'42\tWed, 01 Nov 2023 00:00:00 GMT\t'
want="${want}"$'\n1700000000\tWed, 01 Nov 2023 01:00:00 GMT\t1024'
want="${want}"$'\n1700000100\tWed, 01 Nov 2023 02:00:00 GMT\t'
expect_eq "versions_parse_xml: TAB records with a missing size" "$want" "$(versions_parse_xml "$versions_xml")"
expect_contains "versions_parse_xml: collection row carries the fileid" "$(versions_parse_xml "$versions_xml")" "42"

# build_mount_argv filter additions (probe in a clean subprocess, with an
# isolated filter dir and manifest so the pair filter lookup is exercised).
MOUNT_PROBE_DIR="${TMP}/mount-probe"
mkdir -p "${MOUNT_PROBE_DIR}/filters"
printf '# clutter\n' >"${MOUNT_PROBE_DIR}/filters/clutter.txt"
printf '# pair\n' >"${MOUNT_PROBE_DIR}/filters/pair-probe.txt"
printf 'sync|/tmp/probe-src|pair-probe|pair-probe.txt\n' >"${MOUNT_PROBE_DIR}/sources.conf"
: >"${MOUNT_PROBE_DIR}/folders.conf"
: >"${MOUNT_PROBE_DIR}/sources.generated.conf"
# mount_args_probe FOLDER [ENV=...]... - print one argument per line from
# build_mount_argv with MNT_FOLDER=FOLDER; ENV overrides the probe defaults
# (FILTER_DIR, the manifest files, MOUNT_FILTERS, MOUNT_NO_SYNC).
mount_args_probe() {
  local folder="$1"
  shift
  # shellcheck disable=SC2016  # the -c program expands "$1" itself
  env "MNT_PROBE_FOLDER=$folder" "$@" bash -c '
    set -uo pipefail
    source "$1/lib/core.sh"
    source "$1/lib/manifest.sh"
    source "$1/lib/commands/mount.sh"
    MNT_FOLDER="$MNT_PROBE_FOLDER"
    MNT_NAME=probe MNT_SPEC="remote:base/${MNT_PROBE_FOLDER}"
    MNT_PATH=/tmp/probe-mnt MNT_FOREGROUND=false MNT_RO=false MNT_SUDO=false MNT_MODE=rw
    MOUNT_CACHE_DIR=/tmp/probe-cache MOUNT_CACHE_MAX_SIZE=5G
    LOG_DIR=/tmp/probe-logs MOUNT_EXTRA_FLAGS=""
    build_mount_argv
    printf "%s\n" "${MNT_ARGV[@]}"
  ' mount-args-probe "$PROJ_DIR" 2>&1
}
mount_probe_env=(
  RCLONE_BIN=/bin/true RCLONE_CONFIG=/tmp/probe-rclone.conf
  "FILTER_DIR=${MOUNT_PROBE_DIR}/filters" "MANIFEST_FILE=${MOUNT_PROBE_DIR}/sources.conf"
  "FOLDERS_FILE=${MOUNT_PROBE_DIR}/folders.conf"
  "MANIFEST_GENERATED_FILE=${MOUNT_PROBE_DIR}/sources.generated.conf"
)
out="$(mount_args_probe pair-probe "${mount_probe_env[@]}" MOUNT_FILTERS=1 MOUNT_NO_SYNC=1)"
expect_contains "build_mount_argv: clutter filter recorded" "$out" $'--filter-from\n'"${MOUNT_PROBE_DIR}/filters/clutter.txt"
expect_contains "build_mount_argv: pair filter recorded" "$out" $'--filter-from\n'"${MOUNT_PROBE_DIR}/filters/pair-probe.txt"
expect_contains "build_mount_argv: .nosync marker recorded" "$out" $'--exclude-if-present\n.nosync'
out="$(mount_args_probe pair-probe "${mount_probe_env[@]}" MOUNT_FILTERS=0 MOUNT_NO_SYNC=0)"
expect_not_contains "build_mount_argv: no filters when disabled" "$out" "--filter-from"
expect_not_contains "build_mount_argv: no .nosync marker when disabled" "$out" "--exclude-if-present"
out="$(mount_args_probe other-probe "${mount_probe_env[@]}" MOUNT_FILTERS=1 MOUNT_NO_SYNC=0)"
expect_contains "build_mount_argv: clutter filter for another folder" "$out" "${MOUNT_PROBE_DIR}/filters/clutter.txt"
expect_not_contains "build_mount_argv: no pair filter for a different folder" "$out" "pair-probe.txt"

finish
