#!/usr/bin/env bash
# core.sh - pure string/path helpers, safe_source, curl/proxy classifiers, JSON/XML escaping, opt_parse and friends (lib/base/core.sh).
# Sourced setup lives in tests/unit/common.sh; run standalone with
# `bash tests/unit/core.sh`.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

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
# Linearity is checked as a ratio against a 64 KB line timed in the same
# run: 16x the input takes ~16x the time when linear and ~256x when
# quadratic, so the bound is 128x. A busy machine slows both samples alike
# instead of failing a fixed deadline.
sanitize_big_line() {
  {
    head -c "$1" /dev/zero | tr '\0' 'a'
    printf '\t\033\303\274\n'
  } >"$2"
}
sanitize_elapsed_us() {
  local start="$EPOCHREALTIME"
  sanitize_stream <"$1" >"$2"
  printf "%s" "$((${EPOCHREALTIME/./} - ${start/./}))"
}
big_line="${TMP}/sanitize-big-line"
big_out="${TMP}/sanitize-big-out"
small_line="${TMP}/sanitize-small-line"
small_out="${TMP}/sanitize-small-out"
sanitize_big_line 65536 "$small_line"
sanitize_big_line 1048576 "$big_line"
small_us="$(sanitize_elapsed_us "$small_line" "$small_out")"
big_us="$(sanitize_elapsed_us "$big_line" "$big_out")"
expect_eq "sanitize_stream: large line output keeps TAB and valid UTF-8" \
  "1048580" "$(wc -c <"$big_out" | tr -d ' ')"
((small_us > 0)) || small_us=1
big_ratio=$((big_us / small_us))
if ((big_ratio < 128)); then
  pass "sanitize_stream: 1MB line scales linearly (${big_ratio}x the 64KB time)"
else
  fail "sanitize_stream: 1MB line scales linearly" "${big_ratio}x the 64KB time (${big_us}us vs ${small_us}us)"
fi

# The awk preludes must parse in any locale: gawk compiles regex literals at
# parse time and, in a UTF-8 locale, rejects byte ranges such as \302[...].
# Runs wherever gawk exists (GitHub's Linux runners); skipped otherwise.
if command -v gawk >/dev/null 2>&1; then
  gawk_out="$(printf 'a\001<b>x</b>\n' | LC_ALL=C.UTF-8 gawk "${_AWK_XML_LIB}"'{ print ctrl_strip($0, 1) }' 2>&1)"
  expect_eq "awk preludes: parse under gawk in a UTF-8 locale" "0" "$?"
  expect_not_contains "awk preludes: no collation error under gawk" "$gawk_out" "collation"
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

# _stat_flavor must not cache a guess after a failed probe: a transient stat
# failure (e.g. a fork failing under load) used to cache "gnu" on macOS for
# the whole process, after which safe_source refused safe settings files.
stat_saved_flavor="$_SCIEBO_STAT_FLAVOR"
_SCIEBO_STAT_FLAVOR=""
# shellcheck disable=SC2329  # stub called by _stat_flavor
stat() { return 1; }
_stat_flavor >/dev/null
expect_eq "_stat_flavor: failed probes rc 1" "1" "$?"
expect_eq "_stat_flavor: failed probes cache nothing" "" "$_SCIEBO_STAT_FLAVOR"
unset -f stat
stat_expected_flavor="gnu"
[[ "$(uname -s)" != "Darwin" && "$(uname -s)" != *BSD ]] || stat_expected_flavor="bsd"
expect_eq "_stat_flavor: next call detects the real flavor" "$stat_expected_flavor" "$(_stat_flavor)"
_SCIEBO_STAT_FLAVOR=""
stat() { return 1; }
_stat_flavor >/dev/null || true
unset -f stat
stat_safe_file="${TMP}/stat-flavor-safe.env"
printf 'STAT_FLAVOR_PROBE=ok\n' >"$stat_safe_file"
chmod 600 "$stat_safe_file"
STAT_FLAVOR_PROBE=""
safe_source "$stat_safe_file"
expect_eq "safe_source: works after a transient stat failure" "ok" "$STAT_FLAVOR_PROBE"
_SCIEBO_STAT_FLAVOR="$stat_saved_flavor"

# safe_source revalidates on a fresh descriptor when one check fails
# transiently, and still refuses when every check fails.
eval "saved_fd_looks_safe() $(declare -f _fd_looks_safe | tail -n +2)"
fd_check_calls=0
# shellcheck disable=SC2329  # stub called by _safe_source_open_checked
_fd_looks_safe() {
  fd_check_calls=$((fd_check_calls + 1))
  [[ "$fd_check_calls" -gt 1 ]] && saved_fd_looks_safe "$@"
}
STAT_FLAVOR_PROBE=""
safe_source "$stat_safe_file"
expect_eq "safe_source: one transient check failure is retried" "ok" "$STAT_FLAVOR_PROBE"
expect_eq "safe_source: retried exactly once" "2" "$fd_check_calls"
# shellcheck disable=SC2329  # stub called by _safe_source_open_checked
_fd_looks_safe() { return 1; }
STAT_FLAVOR_PROBE=""
safe_source "$stat_safe_file" 2>/dev/null
expect_eq "safe_source: persistent check failure rc 1" "1" "$?"
expect_eq "safe_source: persistent failure sources nothing" "" "$STAT_FLAVOR_PROBE"
eval "_fd_looks_safe() $(declare -f saved_fd_looks_safe | tail -n +2)"
unset -f saved_fd_looks_safe
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

# --- config_lines -------------------------------------------------------
cfg="${TMP}/config-lines.conf"
printf '# comment\n\n   \n  # indented comment\nalpha\nbeta gamma\n' >"$cfg"
expect_eq "config_lines: drops comments and blanks" "alpha
beta gamma" "$(config_lines "$cfg")"

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

finish
