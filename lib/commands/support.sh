#!/bin/bash
# support.sh command module - redacted debug archive.
#
# Mirrors the desktop client's "Create Debug Archive": collects version
# information, the offline doctor report, redacted settings and rclone
# configuration, state listings, the newest logs, capabilities, and the
# scheduler/mount status into one tar.gz. Nothing here talks to the network
# (the doctor subprocess always runs --offline) and every credential-like
# setting is replaced before it reaches the staging directory.
#
# Commands are spawned through ${PROJECT_DIR}/bin/sciebo, never called
# in-process; the archive is built in a temp staging directory and only then
# packed, so a failed run never leaves a partial archive behind.

# Staging directory of the run currently being built (removed before return).
SUPPORT_STAGE=""

usage_support() {
  usage_emit <<'EOF'
Usage: sciebo support [--output FILE] [--no-network] [--json]

Build a redacted debug archive for bug reports. The archive contains the
version banner, the doctor report, redacted settings and rclone config,
state/runstate listings, the newest logs (last 200 lines each),
capabilities, and the scheduler/mount status. Passwords, secrets, tokens,
and proxy values are replaced with REDACTED; .env is never included.

The doctor always runs offline, so the archive needs no network access.

Options:
  --output FILE  archive path (default:
                 state/support-<YYYYmmdd-HHMMSS>.tar.gz)
  --no-network   accepted for nextcloudcmd-style callers; doctor is offline
  --json         print {"archive":"...","files":N,"bytes":N}
  -h, --help     show this help
EOF
}

# support_redact_url_userinfo_stream - read text on stdin and mask
# credentials that hide inside URLs: `scheme://user:password@host` becomes
# `scheme://REDACTED@host`. Everything else passes through, so host and path
# detail survives in the archive.
support_redact_url_userinfo_stream() {
  LC_ALL=C sed -E 's#([a-zA-Z][a-zA-Z0-9+.-]*://)[^/@[:space:]]+@#\1REDACTED@#g'
}

# support_redact_value_stream - read text on stdin and mask secret-shaped
# values that the key-name pass cannot see: Authorization/Proxy-Authorization/
# Cookie/Set-Cookie header lines, Basic/Bearer tokens, and runs of 40 or more
# base64-ish characters that contain a digit. Header lines are replaced
# wholesale, so whatever follows the colon never survives. Ordinary prose,
# paths, and short values pass through unchanged.
support_redact_value_stream() {
  LC_ALL=C awk '
    function redact_long(s,   out, rest, tok) {
      out = ""
      rest = s
      while (match(rest, /[A-Za-z0-9+\/=_.-]+/) > 0) {
        tok = substr(rest, RSTART, RLENGTH)
        out = out substr(rest, 1, RSTART - 1)
        if (RLENGTH >= 40 && tok ~ /[0-9]/) {
          out = out "REDACTED"
        } else {
          out = out tok
        }
        rest = substr(rest, RSTART + RLENGTH)
      }
      return out rest
    }
    {
      line = $0
      if (line ~ /^[[:space:]]*[Pp]roxy-[Aa]uthorization:/) { print "Proxy-Authorization: REDACTED"; next }
      if (line ~ /^[[:space:]]*[Aa]uthorization:/) { print "Authorization: REDACTED"; next }
      if (line ~ /^[[:space:]]*[Ss]et-[Cc]ookie:/) { print "Set-Cookie: REDACTED"; next }
      if (line ~ /^[[:space:]]*[Cc]ookie:/) { print "Cookie: REDACTED"; next }
      gsub(/[Bb]asic[[:space:]]+[A-Za-z0-9+\/=_.-]+/, "Basic REDACTED", line)
      gsub(/[Bb]earer[[:space:]]+[A-Za-z0-9+\/=_.-]+/, "Bearer REDACTED", line)
      print redact_long(line)
    }
  '
}

# support_redact_stream - the generic pass applied to every archived file and
# captured command output: value patterns first, then URL userinfo.
support_redact_stream() {
  support_redact_value_stream | support_redact_url_userinfo_stream
}

# support_redact_settings_stream - read a settings file on stdin and replace
# the value of every credential-like key with REDACTED. The key test is
# case-insensitive substring matching on password/secret/token/passwd/
# apikey/api_key; proxy settings are redacted unless they are the non-secret
# proxy policy (PROXY_TYPE, PROXY_DIRECT). The generic value pass then masks
# any secret-shaped value that survives. Lines without an assignment
# (comments) pass through.
support_redact_settings_stream() {
  LC_ALL=C awk -F'=' '
    NF >= 2 {
      key = tolower($1)
      if (key ~ /password[0-9]*|secret|token|passwd|apikey|api_key/ ||
          (key ~ /proxy/ && key !~ /proxy_direct|proxy_type/)) {
        print $1 "=REDACTED"
        next
      }
    }
    { print }
  ' | support_redact_stream
}

# support_redact_rclone_stream - read `rclone config show` output on stdin
# and replace pass/password (and other credential-like keys such as
# client_secret/token) values with REDACTED, preserving the `key = value`
# shape. The generic value pass then handles anything that slips through.
support_redact_rclone_stream() {
  LC_ALL=C awk '
    {
      key = $0
      sub(/=.*/, "", key)
      if (tolower(key) ~ /^[[:space:]]*(pass|passwd|password[0-9]*|secret|token|apikey|api_key|client_secret)[[:space:]]*$/) {
        sub(/=.*/, "= REDACTED", $0)
      }
      print
    }
  '
}

# support_stat_mtime_name FILE - print "<mtime> <path>" through the shared
# file_mtime probe (cached BSD/GNU flavor); rc 1 when the mtime cannot be
# read. The old copy re-probed `stat -f '%m %N'`/`stat -c '%Y %n'` per file;
# %N/%n was always the path passed in, which is what prints here.
support_stat_mtime_name() {
  local file="$1" mtime=""
  mtime=${ file_mtime "$file";}
  [[ -n "$mtime" ]] || return 1
  printf '%s %s' "$mtime" "$file"
}

# support_sort_capped LIST LIMIT - LIST's "<mtime> <path>" records (one per
# line), newest first, capped at LIMIT rows, with the mtime column
# stripped. `sort` runs inside a process substitution, so `mapfile -n`
# stopping before EOF never turns into a SIGPIPE on the pipeline itself
# (pipefail would otherwise fail this on a large LIST once `head` closed
# the pipe on `sort` mid-write).
support_sort_capped() {
  local list="$1" limit="$2"
  local -a lines=()
  # Read everything, then slice (see recent_sorted): no early pipe close.
  mapfile -t lines < <(printf '%s' "$list" | LC_ALL=C sort -rn)
  printf '%s\n' "${lines[@]:0:$limit}" | sed 's/^[0-9][0-9]* //'
}

# support_newest_files DIR LIMIT - print up to LIMIT regular files from DIR,
# newest first. Log names are sanitized by the tooling, so line-based
# sorting is safe here.
support_newest_files() {
  local dir="$1" limit="$2" file="" record="" list=""
  for file in "$dir"/*; do
    [[ -f "$file" ]] || continue
    record="$(support_stat_mtime_name "$file")" || continue
    list="${list}${record}"$'\n'
  done
  [[ -n "$list" ]] || return 0
  support_sort_capped "$list" "$limit"
}

support_add_version() {
  local out="$1"
  {
    version_print || true
    uname -a 2>/dev/null || true
    printf 'shell %s\n' "${SHELL:-/bin/bash}"
  } | support_redact_stream >"$out"
}

support_add_doctor() {
  local out="$1"
  "${PROJECT_DIR}/bin/sciebo" doctor --offline 2>&1 |
    support_redact_stream >"$out" || true
}

# support_add_settings FILE OUT - append the redacted contents of FILE to
# OUT with a source header; a missing or empty path is ignored.
support_add_settings() {
  local file="$1" out="$2"
  [[ -n "$file" && -f "$file" ]] || return 0
  {
    printf '### %s\n' "$file"
    if ! support_redact_settings_stream <"$file"; then
      printf '(unreadable)\n'
    fi
  } >>"$out"
  return 0
}

support_add_rclone_config() {
  local out="$1" show=""
  show=${ remote_config_show;} || show=""
  if [[ -z "$show" && -n "${RCLONE_BIN:-}" ]]; then
    show="$("$RCLONE_BIN" --config "$RCLONE_CONFIG" config show "$RCLONE_REMOTE" 2>/dev/null)" || show=""
  fi
  printf '%s\n' "$show" | support_redact_rclone_stream |
    support_redact_stream >"$out"
}

support_add_state() {
  local out="$1"
  {
    printf '== ls -la %s ==\n' "$STATE_DIR"
    ls -la "$STATE_DIR" 2>&1 || true
    printf '\n== find %s -maxdepth 2 ==\n' "$STATE_DIR"
    find "$STATE_DIR" -maxdepth 2 2>&1 || true
  } | support_redact_stream >"$out"
}

support_add_runstate() {
  local out="$1" file=""
  : >"$out"
  [[ -d "$RUNSTATE_DIR" ]] || return 0
  for file in "$RUNSTATE_DIR"/*; do
    [[ -f "$file" ]] || continue
    printf '== %s ==\n' "$file" >>"$out"
    support_redact_stream <"$file" >>"$out" || true
  done
  return 0
}

support_add_logs() {
  local outdir="$1" file="" count=0
  mkdir -p "$outdir" 2>/dev/null || true
  [[ -d "$LOG_DIR" ]] || return 0
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    count=$((count + 1))
    tail -n 200 "$file" 2>/dev/null |
      support_redact_stream >"$outdir/$(basename "$file")" || true
    [[ "$count" -lt 5 ]] || break
  done < <(support_newest_files "$LOG_DIR" 5)
  return 0
}

support_add_capabilities() {
  local out="$1"
  {
    capabilities_load || true
    capabilities_show || true
  } | support_redact_stream >"$out"
}

# support_add_subcommand OUT ARGS... - capture another sciebo command's
# combined output, redacted; its exit status never fails the archive.
support_add_subcommand() {
  local out="$1"
  shift
  "${PROJECT_DIR}/bin/sciebo" "$@" 2>&1 |
    support_redact_stream >"$out" || true
}

# support_collect STAGE - fill the staging directory.
support_collect() {
  local stage="$1"
  support_add_version "$stage/version.txt"
  support_add_doctor "$stage/doctor.txt"
  : >"$stage/settings.txt"
  support_add_settings "${SETTINGS_FILE:-}" "$stage/settings.txt"
  support_add_settings "${SETTINGS_LOCAL_FILE:-}" "$stage/settings.txt"
  support_add_settings "${SETTINGS_PROFILE_FILE:-}" "$stage/settings.txt"
  support_add_settings "${SETTINGS_PROFILE_LOCAL_FILE:-}" "$stage/settings.txt"
  support_add_rclone_config "$stage/rclone-config.txt"
  support_add_state "$stage/state.txt"
  support_add_runstate "$stage/runstate.txt"
  support_add_logs "$stage/logs"
  support_add_capabilities "$stage/capabilities.txt"
  support_add_subcommand "$stage/scheduler.txt" schedule status
  support_add_subcommand "$stage/mounts.txt" mounts
}

cmd_support() {
  local output="" output_dir="" rc=0 files=0 bytes=""
  opt_begin "output:s no-network:b json:b" support "" "$@"
  [[ -z "$OPT_EXTRA" ]] || usage_error support "unexpected argument: ${OPT_EXTRA%%$'\n'*}"
  # The capabilities section is read from the cache; load the module after
  # the help/usage exits so `sciebo support --help` parses none of it.
  output="${OPT_output:-}"
  if rclone_available; then load_settings; else load_settings --no-rclone; fi
  mkdir -p "$STATE_DIR" 2>/dev/null || die "cannot create state dir: ${STATE_DIR}"
  [[ -n "$output" ]] || output="${STATE_DIR}/support-$(date '+%Y%m%d-%H%M%S').tar.gz"
  output_dir="$(dirname "$output")"
  mkdir -p "$output_dir" 2>/dev/null || die "cannot create output directory: ${output_dir}"
  SUPPORT_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/sciebo-support.XXXXXX")" || die "cannot create staging directory"
  # Register the staging tree so an exit or signal before the normal
  # end-of-command removal below cannot leave it behind.
  sciebo_temp_register "$SUPPORT_STAGE"
  support_collect "$SUPPORT_STAGE"
  files="$(find "$SUPPORT_STAGE" -type f 2>/dev/null | wc -l | tr -d '[:space:]')"
  [[ -n "$files" ]] || files=0
  if tar -czf "$output" -C "$SUPPORT_STAGE" -- \
    version.txt doctor.txt settings.txt rclone-config.txt state.txt \
    runstate.txt capabilities.txt scheduler.txt mounts.txt logs 2>/dev/null; then
    rc=0
  else
    rc=1
  fi
  rm -rf "$SUPPORT_STAGE" 2>/dev/null || true
  SUPPORT_STAGE=""
  [[ "$rc" -eq 0 ]] || die "cannot write archive: ${output}"
  bytes="$(wc -c <"$output" 2>/dev/null | tr -d '[:space:]')"
  [[ -n "$bytes" ]] || bytes=0
  opt_json_mode
  if output_json_enabled; then
    output_json_begin
    output_json_kv archive "$output"
    output_json_kv_raw files "$files"
    output_json_kv_raw bytes "$bytes"
    output_json_end
  else
    printf 'support: wrote %s\n' "$output"
  fi
  return 0
}
