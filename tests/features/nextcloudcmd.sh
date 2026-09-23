#!/usr/bin/env bash
# nextcloudcmd.sh - nextcloudcmd-compatible run: WebDAV URL construction,
# credential precedence, filters, short flags, version banners, whole-sync
# retries, and failure modes.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

# Stub rclone: one log line per invocation (argv joined with spaces), the
# environment of the last invocation, and always success, so the test can
# inspect the config create and bisync argv as well as the proxy variables
# exported to the child. A dry run prints rclone's "as --dry-run is set"
# plan marker while the dryrun-changes sentinel exists, which drives the
# --max-sync-retries probe.
NC_BIN="${TMP}/nc-bin"
mkdir -p "$NC_BIN"
cat >"${NC_BIN}/rclone" <<'STUB'
#!/bin/bash
dir="$(cd "$(dirname "$0")" && pwd)"
printf '%s\n' "$*" >>"${dir}/rclone.log"
env | sort >"${dir}/rclone.env"
dry=false
for arg in "$@"; do
  [[ "$arg" == "--dry-run" ]] && dry=true
done
if [[ "$dry" == true && -e "${dir}/dryrun-changes" ]]; then
  printf 'Skipping f1.txt as --dry-run is set\n'
fi
exit 0
STUB
chmod +x "${NC_BIN}/rclone"
NC_LOG="${NC_BIN}/rclone.log"
nc_log_clear() { : >"$NC_LOG"; }
nc_log() { cat "$NC_LOG" 2>/dev/null || true; }
# nc_env - the environment the last stub rclone invocation ran with.
nc_env() { cat "${NC_BIN}/rclone.env" 2>/dev/null || true; }
# nc_bisync_count true|false - number of logged bisync invocations with
# (true) or without (false) the --dry-run flag.
nc_bisync_count() {
  if [[ "$1" == true ]]; then
    awk '/ bisync / && /--dry-run/ { n++ } END { print n + 0 }' "$NC_LOG"
  else
    awk '/ bisync / && !/--dry-run/ { n++ } END { print n + 0 }' "$NC_LOG"
  fi
}
# nc_progress_count - number of logged rclone invocations carrying -P.
nc_progress_count() {
  awk '{ for (i = 1; i <= NF; i++) if ($i == "-P") n++ } END { print n + 0 }' "$NC_LOG"
}

# run_nc - run the CLI with the stub rclone first in PATH and prompting
# disabled; credentials must come from the flags or the URL.
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_nc() {
  (cd "$TMP" && env PATH="${NC_BIN}:$PATH" SCIEBO_NON_INTERACTIVE=1 \
    bash "${PROJ}/bin/sciebo" "$@")
}

LOCAL="${TMP}/local"

# --- dry run: dedicated remote config and bisync argv ------------------------
nc_log_clear
expect_cli "nextcloudcmd: dry run rc 0" 0 run_nc nextcloudcmd --dry-run \
  --user alice --password x --path docs "$LOCAL" https://cloud.example.org
log="$(nc_log)"
expect_contains "nextcloudcmd: bisync invoked" "$log" "bisync"
expect_contains "nextcloudcmd: dedicated remote target" "$log" "sciebo-nextcloudcmd:"
expect_contains "nextcloudcmd: webdav url path" "$log" "remote.php/dav/files/alice/docs"
expect_contains "nextcloudcmd: dry run flag" "$log" "--dry-run"
expect_contains "nextcloudcmd: first run resync" "$log" "--resync"
expect_contains "nextcloudcmd: conflict exclusion" "$log" "conflicted copy"
expect_contains "nextcloudcmd: success message" "$CLI_OUT" "nextcloudcmd: synced"

# --- short flags -------------------------------------------------------------
nc_log_clear
expect_cli "nextcloudcmd: short flags rc 0" 0 run_nc nextcloudcmd --dry-run \
  -u alice -p x "$LOCAL" https://cloud.example.org
expect_contains "nextcloudcmd: -u maps to --user" "$(nc_log)" "user=alice"

# --- inline short flags and a missing value ---------------------------------
# -uVALUE/-pVALUE are rewritten like the split forms; a value-taking flag
# without its value is a usage error before any rclone call.
nc_log_clear
expect_cli "nextcloudcmd: inline short flags rc 0" 0 run_nc nextcloudcmd --dry-run \
  -ualice -psecret "$LOCAL" https://cloud.example.org
expect_contains "nextcloudcmd: inline -u maps to --user" "$(nc_log)" "user=alice"
nc_log_clear
expect_cli "nextcloudcmd: missing -u value rc 2" 2 run_nc nextcloudcmd -u
expect_contains "nextcloudcmd: missing -u value named" "$CLI_OUT" "-u requires a value"
expect_not_contains "nextcloudcmd: missing -u value runs no sync" "$(nc_log)" "bisync"
nc_log_clear
expect_cli "nextcloudcmd: missing -p value rc 2" 2 run_nc nextcloudcmd -p
expect_contains "nextcloudcmd: missing -p value named" "$CLI_OUT" "-p requires a value"
expect_not_contains "nextcloudcmd: missing -p value runs no sync" "$(nc_log)" "bisync"

# --- --password warns, --password-fd reads the secret from a descriptor ------
nc_log_clear
expect_cli "nextcloudcmd: --password warns about ps rc 0" 0 run_nc nextcloudcmd --dry-run \
  --user alice --password x "$LOCAL" https://cloud.example.org
expect_contains "nextcloudcmd: --password warns about ps" "$CLI_OUT" "visible in the process list"
nc_log_clear
expect_cli "nextcloudcmd: --password-fd rc 0" 0 run_nc nextcloudcmd --dry-run \
  --user alice --password-fd 3 "$LOCAL" https://cloud.example.org 3<<<"fd-secret"
log="$(nc_log)"
expect_contains "nextcloudcmd: --password-fd run syncs" "$log" "bisync"
expect_not_contains "nextcloudcmd: fd password stays out of rclone argv" "$log" "fd-secret"
nc_log_clear
expect_cli "nextcloudcmd: password and fd combined rc 2" 2 run_nc nextcloudcmd \
  --password x --password-fd 3
expect_contains "nextcloudcmd: password and fd combined named" "$CLI_OUT" \
  "--password and --password-fd cannot be combined"
expect_not_contains "nextcloudcmd: combined password flags run no sync" "$(nc_log)" "bisync"
expect_cli "nextcloudcmd: non-numeric fd rc 2" 2 run_nc nextcloudcmd --password-fd nope
expect_contains "nextcloudcmd: non-numeric fd named" "$CLI_OUT" \
  "--password-fd requires a file descriptor number"
expect_cli "nextcloudcmd: fd 0 rc 2" 2 run_nc nextcloudcmd --password-fd 0
expect_contains "nextcloudcmd: fd 0 named" "$CLI_OUT" \
  "--password-fd requires a positive file descriptor number"
expect_cli "nextcloudcmd: closed fd rc 2" 2 run_nc nextcloudcmd --password-fd 63
expect_contains "nextcloudcmd: closed fd named" "$CLI_OUT" "--password-fd 63 is not readable"
expect_cli "nextcloudcmd: empty fd password rc 2" 2 run_nc nextcloudcmd --password-fd 3 3<<<""
expect_contains "nextcloudcmd: empty fd password named" "$CLI_OUT" \
  "--password-fd 3 provided an empty password"

# --- hidden files: excluded by default, kept with -h -------------------------
nc_log_clear
expect_cli "nextcloudcmd: default hidden exclusion rc 0" 0 run_nc nextcloudcmd --dry-run \
  --user alice --password x "$LOCAL" https://cloud.example.org
expect_contains "nextcloudcmd: hidden exclusion present" "$(nc_log)" "--exclude .*"
nc_log_clear
expect_cli "nextcloudcmd: -h hidden files rc 0" 0 run_nc nextcloudcmd --dry-run -h \
  --user alice --password x "$LOCAL" https://cloud.example.org
expect_not_contains "nextcloudcmd: -h drops hidden exclusion" "$(nc_log)" "--exclude .*"

# --- unsyncedfolders: one exclude per non-comment line -----------------------
cat >"${TMP}/unsynced.txt" <<'EOF'
# comment

photos/
drafts
EOF
nc_log_clear
expect_cli "nextcloudcmd: unsyncedfolders rc 0" 0 run_nc nextcloudcmd --dry-run \
  --user alice --password x --unsyncedfolders "${TMP}/unsynced.txt" "$LOCAL" https://cloud.example.org
log="$(nc_log)"
expect_contains "nextcloudcmd: unsynced photos excluded" "$log" "--exclude photos"
expect_contains "nextcloudcmd: unsynced drafts excluded" "$log" "--exclude drafts"
expect_not_contains "nextcloudcmd: comment not excluded" "$log" "--exclude # comment"

# --- exclude file, silent mode, retries, and proxy ---------------------------
printf '*.tmp\n' >"${TMP}/exclude.txt"
nc_log_clear
expect_cli "nextcloudcmd: exclude/silent/retries/proxy rc 0" 0 run_nc nextcloudcmd --dry-run \
  --user alice --password x --exclude "${TMP}/exclude.txt" --silent \
  --max-sync-retries 5 --httpproxy http://proxy.example.org:8080 "$LOCAL" https://cloud.example.org
log="$(nc_log)"
expect_contains "nextcloudcmd: exclude file forwarded" "$log" "--exclude-from ${TMP}/exclude.txt"
expect_contains "nextcloudcmd: silent maps to log level" "$log" "--log-level ERROR --stats 0"
expect_contains "nextcloudcmd: max sync retries maps to retries" "$log" "--retries 5"
expect_not_contains "nextcloudcmd: http proxy stays out of argv" "$log" "--http-proxy"
expect_contains "nextcloudcmd: http proxy exported to rclone env" "$(nc_env)" \
  "HTTP_PROXY=http://proxy.example.org:8080"

# --- TLS: --no-check-certificate only when verification is off ---------------
# load_settings always leaves TLS_INSECURE as "0" or "1", so an inverted
# condition here used to append the flag on every run and silently disabled
# certificate verification.
nc_log_clear
expect_cli "nextcloudcmd: default keeps TLS verification rc 0" 0 run_nc nextcloudcmd --dry-run \
  --user alice --password x "$LOCAL" https://cloud.example.org
expect_not_contains "nextcloudcmd: default has no --no-check-certificate" "$(nc_log)" \
  "--no-check-certificate"
export TLS_INSECURE=1
nc_log_clear
expect_cli "nextcloudcmd: TLS_INSECURE=1 run rc 0" 0 run_nc nextcloudcmd --dry-run \
  --user alice --password x "$LOCAL" https://cloud.example.org
expect_contains "nextcloudcmd: TLS_INSECURE=1 adds --no-check-certificate" "$(nc_log)" \
  "--no-check-certificate"
unset TLS_INSECURE
nc_log_clear
expect_cli "nextcloudcmd: --trust run rc 0" 0 run_nc nextcloudcmd --dry-run --trust \
  --user alice --password x "$LOCAL" https://cloud.example.org
expect_contains "nextcloudcmd: --trust adds --no-check-certificate" "$(nc_log)" \
  "--no-check-certificate"

# --- proxy: http(s) credentials leave via the environment, never argv --------
nc_log_clear
expect_cli "nextcloudcmd: credentialed proxy rc 0" 0 run_nc nextcloudcmd --dry-run \
  --user alice --password x \
  --httpproxy "http://alice:proxy-secret@proxy.example.org:8080" \
  "$LOCAL" https://cloud.example.org
log="$(nc_log)"
env_out="$(nc_env)"
expect_not_contains "nextcloudcmd: proxy credentials stay out of argv" "$log" "proxy-secret"
expect_not_contains "nextcloudcmd: credentialed proxy adds no --http-proxy" "$log" "--http-proxy"
expect_contains "nextcloudcmd: proxy exported as HTTP_PROXY" "$env_out" \
  "HTTP_PROXY=http://alice:proxy-secret@proxy.example.org:8080"
expect_contains "nextcloudcmd: proxy exported as HTTPS_PROXY" "$env_out" \
  "HTTPS_PROXY=http://alice:proxy-secret@proxy.example.org:8080"

# A socks proxy keeps --http-proxy (rclone's only global proxy flag), like
# _rclone_proxy_resolve routes it for every rclone_cmd run.
nc_log_clear
expect_cli "nextcloudcmd: socks5 proxy rc 0" 0 run_nc nextcloudcmd --dry-run \
  --user alice --password x --httpproxy "socks5://proxy.example.org:1080" \
  "$LOCAL" https://cloud.example.org
expect_contains "nextcloudcmd: socks5 proxy keeps --http-proxy" "$(nc_log)" \
  "--http-proxy socks5://proxy.example.org:1080"

# PROXY_DIRECT=1 strips even an ambient proxy environment from the child.
# shellcheck disable=SC2031  # only rewritten in rclone_cmd's child subshell
export PROXY_DIRECT=1 HTTP_PROXY="http://ambient.example:3128"
nc_log_clear
expect_cli "nextcloudcmd: proxy direct rc 0" 0 run_nc nextcloudcmd --dry-run \
  --user alice --password x "$LOCAL" https://cloud.example.org
env_out="$(nc_env)"
expect_not_contains "nextcloudcmd: direct strips HTTP_PROXY" "$env_out" "HTTP_PROXY="
expect_not_contains "nextcloudcmd: direct strips HTTPS_PROXY" "$env_out" "HTTPS_PROXY="
unset PROXY_DIRECT HTTP_PROXY

# --- bandwidth, debug logging ------------------------------------------------
nc_log_clear
expect_cli "nextcloudcmd: uplimit/downlimit rc 0" 0 run_nc nextcloudcmd --dry-run \
  --user alice --password x --uplimit 2M --downlimit 5M "$LOCAL" https://cloud.example.org
expect_contains "nextcloudcmd: uplimit/downlimit map to bwlimit" "$(nc_log)" "--bwlimit 2M:5M"
nc_log_clear
expect_cli "nextcloudcmd: verbose maps to debug rc 0" 0 run_nc nextcloudcmd --dry-run --verbose \
  --user alice --password x "$LOCAL" https://cloud.example.org
expect_contains "nextcloudcmd: --verbose maps to debug" "$(nc_log)" "--log-level DEBUG"
nc_log_clear
expect_cli "nextcloudcmd: logdebug rc 0" 0 run_nc nextcloudcmd --dry-run --logdebug \
  --user alice --password x "$LOCAL" https://cloud.example.org
expect_contains "nextcloudcmd: --logdebug maps to debug" "$(nc_log)" "--log-level DEBUG"

# --- --progress: rclone's -P only on a TTY -----------------------------------
# In tests stdout is captured, so --progress is accepted but must not reach
# the rclone argv; the builder is exercised directly with a TTY-like stub.
nc_log_clear
expect_cli "nextcloudcmd: --progress accepted rc 0" 0 run_nc nextcloudcmd --dry-run \
  --user alice --password x --progress "$LOCAL" https://cloud.example.org
expect_eq "nextcloudcmd: non-tty --progress adds no -P" "0" "$(nc_progress_count)"
nc_log_clear
expect_cli "nextcloudcmd: -P accepted rc 0" 0 run_nc nextcloudcmd --dry-run \
  --user alice --password x -P "$LOCAL" https://cloud.example.org
expect_eq "nextcloudcmd: non-tty -P adds no -P" "0" "$(nc_progress_count)"
nc_log_clear
expect_cli "nextcloudcmd: --silent suppresses progress rc 0" 0 run_nc nextcloudcmd --dry-run \
  --user alice --password x --progress --silent "$LOCAL" https://cloud.example.org
expect_eq "nextcloudcmd: silent adds no -P" "0" "$(nc_progress_count)"

# The argv builder appends -P when the TTY check says so. ncc_append_progress
# goes through the shared progress_append_args now, so source lib/rclone.sh
# here (env.sh loads only core/http, like hydrate's direct-drive block) and
# stub the shared terminal probe instead of the removed ncc_progress_tty.
source "${PROJ}/lib/commands/nextcloudcmd.sh"
# shellcheck disable=SC1090,SC1091
source "${PROJ}/lib/rclone.sh"
# shellcheck disable=SC2329  # invoked by progress_append_args
progress_stdout_tty() { return 0; }
# shellcheck disable=SC2034  # read by the sourced argv builder
OPT_progress=1
# shellcheck disable=SC2034  # read by the sourced argv builder
OPT_silent=""
NCC_ARGS=()
ncc_build_args /src /wd false false
expect_contains "nextcloudcmd: tty progress appended" "${NCC_ARGS[*]}" "-P"
NCC_ARGS=()
ncc_build_args /src /wd true false
expect_contains "nextcloudcmd: dry run keeps progress" "${NCC_ARGS[*]}" "-P"
NCC_ARGS=()
ncc_build_args /src /wd false false probe
expect_not_contains "nextcloudcmd: probe has no progress" "${NCC_ARGS[*]}" "-P"
# shellcheck disable=SC2034  # read by the sourced argv builder
OPT_silent=1
NCC_ARGS=()
ncc_build_args /src /wd false false
expect_not_contains "nextcloudcmd: silent suppresses tty progress" "${NCC_ARGS[*]}" "-P"
# shellcheck disable=SC2034  # read by the sourced argv builder
OPT_silent=""
# The shared progress_append_args carries the JSON-mode guard this command's
# local copy lacked: -P must never reach the argv when output is JSON.
# shellcheck disable=SC2034  # read by the sourced progress helper
OUTPUT_JSON=true
NCC_ARGS=()
ncc_build_args /src /wd false false
expect_not_contains "nextcloudcmd: json suppresses tty progress" "${NCC_ARGS[*]}" "-P"
# shellcheck disable=SC2034  # test fixture reset
OUTPUT_JSON=false
# shellcheck disable=SC2034  # test fixture reset
OPT_progress=""

# --- exclude-anchored: FILE patterns anchored at the sync root ---------------
cat >"${TMP}/anchored.txt" <<'EOF'
# comment

cache
/logs
EOF
nc_log_clear
expect_cli "nextcloudcmd: exclude-anchored file rc 0" 0 run_nc nextcloudcmd --dry-run \
  --user alice --password x --exclude-anchored "${TMP}/anchored.txt" "$LOCAL" https://cloud.example.org
log="$(nc_log)"
expect_contains "nextcloudcmd: anchored pattern prefixed" "$log" "--exclude /cache"
expect_contains "nextcloudcmd: already-anchored pattern kept" "$log" "--exclude /logs"
expect_not_contains "nextcloudcmd: anchored pattern not double-prefixed" "$log" "--exclude //logs"
expect_not_contains "nextcloudcmd: anchored comment skipped" "$log" "--exclude /# comment"
nc_log_clear
expect_cli "nextcloudcmd: missing exclude-anchored file rc 1" 1 run_nc nextcloudcmd --dry-run \
  --user alice --password x --exclude-anchored "${TMP}/no-anchored.txt" "$LOCAL" https://cloud.example.org
expect_contains "nextcloudcmd: missing anchored file named" "$CLI_OUT" "exclude-anchored file not found"
expect_not_contains "nextcloudcmd: missing anchored file does not sync" "$(nc_log)" "bisync"

# --- version: -v/--version print the banner without a sync -------------------
VERSION_LINE="sciebo unknown"
if [[ -f "${PROJ}/VERSION" ]]; then
  VERSION_LINE="sciebo $(tr -d '[:space:]' <"${PROJ}/VERSION")"
fi
nc_log_clear
expect_cli "nextcloudcmd: -v rc 0" 0 run_nc nextcloudcmd -v
expect_eq "nextcloudcmd: -v version line" "$VERSION_LINE" "$CLI_OUT"
expect_not_contains "nextcloudcmd: -v runs no sync" "$(nc_log)" "bisync"
nc_log_clear
expect_cli "nextcloudcmd: --version rc 0" 0 run_nc nextcloudcmd --version
expect_eq "nextcloudcmd: --version version line" "$VERSION_LINE" "$CLI_OUT"
expect_not_contains "nextcloudcmd: --version runs no sync" "$(nc_log)" "bisync"

# --- confdir: accepted as the configuration base -----------------------------
mkdir -p "${TMP}/confdir"
nc_log_clear
expect_cli "nextcloudcmd: confdir rc 0" 0 run_nc nextcloudcmd --confdir "${TMP}/confdir" --dry-run \
  --user alice --password x "$LOCAL" https://cloud.example.org
expect_contains "nextcloudcmd: confdir run syncs" "$(nc_log)" "bisync"

# --- max-sync-retries: rerun the real sync while changes remain --------------
touch "${NC_BIN}/dryrun-changes"
nc_log_clear
expect_cli "nextcloudcmd: max-sync-retries loop rc 0" 0 run_nc nextcloudcmd \
  --user alice --password x --max-sync-retries 1 "$LOCAL" https://cloud.example.org
expect_eq "nextcloudcmd: retries run the real sync twice" "2" "$(nc_bisync_count false)"
expect_eq "nextcloudcmd: retries probe once" "1" "$(nc_bisync_count true)"
nc_log_clear
expect_cli "nextcloudcmd: zero retries rc 0" 0 run_nc nextcloudcmd \
  --user alice --password x --max-sync-retries 0 "$LOCAL" https://cloud.example.org
expect_eq "nextcloudcmd: zero retries run the real sync once" "1" "$(nc_bisync_count false)"
expect_eq "nextcloudcmd: zero retries do not probe" "0" "$(nc_bisync_count true)"
nc_log_clear
expect_cli "nextcloudcmd: default retries rc 0" 0 run_nc nextcloudcmd \
  --user alice --password x "$LOCAL" https://cloud.example.org
expect_eq "nextcloudcmd: default runs the real sync once" "1" "$(nc_bisync_count false)"
expect_eq "nextcloudcmd: default does not probe" "0" "$(nc_bisync_count true)"
rm -f "${NC_BIN}/dryrun-changes"

# --- URL userinfo becomes the credential -------------------------------------
nc_log_clear
expect_cli "nextcloudcmd: URL userinfo rc 0" 0 run_nc nextcloudcmd --dry-run \
  "$LOCAL" "https://bob:s3cret@cloud.example.org/base"
log="$(nc_log)"
expect_contains "nextcloudcmd: URL user used" "$log" "user=bob"
expect_contains "nextcloudcmd: URL base path kept" "$log" "base/remote.php/dav/files/bob"

# --- failures ----------------------------------------------------------------
expect_cli "nextcloudcmd: missing credentials rc 1" 1 run_nc nextcloudcmd --dry-run \
  "$LOCAL" https://cloud.example.org
expect_contains "nextcloudcmd: missing credentials named" "$CLI_OUT" "no user"
expect_cli "nextcloudcmd: bad URL rc 2" 2 run_nc nextcloudcmd --dry-run \
  --user alice --password x "$LOCAL" ftp://cloud.example.org
expect_contains "nextcloudcmd: bad URL named" "$CLI_OUT" "invalid NEXTCLOUDURL"
# The invalid-URL error prints the redacted URL: user:pass@ userinfo must
# not reach the terminal or a log.
expect_cli "nextcloudcmd: bad URL with userinfo rc 2" 2 run_nc nextcloudcmd --dry-run \
  --user alice --password x "$LOCAL" "ftp://bob:s3cret@cloud.example.org"
expect_contains "nextcloudcmd: bad URL with userinfo named" "$CLI_OUT" "invalid NEXTCLOUDURL"
expect_contains "nextcloudcmd: bad URL with userinfo redacted" "$CLI_OUT" "***@cloud.example.org"
expect_not_contains "nextcloudcmd: bad URL never prints the userinfo" "$CLI_OUT" "s3cret"
expect_cli "nextcloudcmd: missing URL rc 2" 2 run_nc nextcloudcmd "$LOCAL"
expect_contains "nextcloudcmd: missing URL named" "$CLI_OUT" "SOURCEDIR and NEXTCLOUDURL are required"

finish
