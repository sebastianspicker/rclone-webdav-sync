#!/usr/bin/env bash
# fake_env.sh - run tests/fake_server.py and point the CLI at it.
#
# Source this after tests/features/env.sh (it uses TMP, PROJ, RCLONE_CONFIG
# and STUB_BIN):
#
#   source "$(dirname "$0")/env.sh"
#   source "$(dirname "$0")/../fake_env.sh"
#   fake_server_start || exit 0      # sets FAKE_BASE, FAKE_PORT, RCLONE_REMOTE
#   fake_curl -s -u alice:secret "$FAKE_BASE/ocs/v2.php/cloud/user"
#   fake_cli quota                   # bin/sciebo against the fake server
#   fake_server_stop                 # idempotent; also runs from the EXIT trap
#
# fake_server_start runs `python3 tests/fake_server.py --port 0 --user alice
# --password secret --state "$TMP/fake"` in the background, parses the
# `PORT=<n>` line it prints, waits until /status.php answers, creates the
# `faknc` remote in $RCLONE_CONFIG with **rclone config create** (webdav,
# vendor=nextcloud) and exports RCLONE_REMOTE=faknc.
#
# fake_curl calls the real curl with a PATH that never contains the env.sh
# stub directory, so requests reach the fake server instead of the stub.
# fake_cli does the same for `bash bin/sciebo`, so tests can drive the
# whole CLI against the live server. fake_seed and fake_login_seed call the
# server's /__test__ hooks (trashbin/versions fixtures, pending Login Flow
# polls). fake_server_stop is trap-safe and idempotent; fake_server_start
# chains the EXIT trap env.sh installed (feature_cleanup), so temp-dir
# cleanup still runs.

FAKE_REMOTE="${FAKE_REMOTE:-faknc}"
FAKE_USER="${FAKE_USER:-alice}"
FAKE_PASSWORD="${FAKE_PASSWORD:-secret}"
FAKE_STATE="${FAKE_STATE:-${TMP:-/tmp}/fake}"
FAKE_PID=""
FAKE_PORT=""
FAKE_BASE=""
FAKE_OUT="${TMP:-/tmp}/fake-server.out"
FAKE_ERR="${TMP:-/tmp}/fake-server.err"
FAKE_TRAP_INSTALLED=0
FAKE_PREV_TRAP=""

# fake_real_path - print $PATH without the env.sh stub directory, so curl and
# rclone talk to the fake server instead of the canned stub.
fake_real_path() {
  local entry out="" old_ifs="$IFS"
  IFS=:
  for entry in $PATH; do
    [ "$entry" = "${STUB_BIN:-}" ] && continue
    out="${out:+${out}:}${entry}"
  done
  IFS="$old_ifs"
  printf '%s' "$out"
}
FAKE_PATH="$(fake_real_path)"

# fake_curl CURL_ARGS... - the real curl, never the env.sh stub.
fake_curl() {
  PATH="$FAKE_PATH" command curl "$@"
}

# fake_cli ARGS... - run bin/sciebo with the real curl and the faknc remote.
fake_cli() {
  (cd "${TMP:-.}" && env PATH="$FAKE_PATH" RCLONE_REMOTE="$FAKE_REMOTE" \
    bash "${PROJ}/bin/sciebo" "$@")
}

# fake_seed CURL_ARGS... - call the fake server's test seed hook
# (POST /__test__/seed) and print the JSON answer. `--data-urlencode
# what=trash` seeds the deterministic trashbin item, `--data-urlencode
# what=versions --data-urlencode path=REL` seeds one version for REL, and
# `--data-urlencode what=props --data-urlencode path=REL` (plus encrypted,
# external, checksums, owner) overrides REL's DAV properties. `what=fail`
# queues an injected error for path/status/count/method.
fake_seed() {
  fake_curl -fsS -u "${FAKE_USER}:${FAKE_PASSWORD}" -X POST "$@" \
    "${FAKE_BASE}/__test__/seed"
}

# fake_login_seed [POLLS] - configure the Login Flow v2 poll hook: the next
# flow answers HTTP 404 on its first POLLS polls before it succeeds (default
# 0, i.e. the first poll succeeds).
fake_login_seed() {
  fake_curl -fsS -u "${FAKE_USER}:${FAKE_PASSWORD}" -X POST \
    --data-urlencode "polls=${1:-0}" "${FAKE_BASE}/__test__/login"
}

# fake_server_stop - stop the fake server if it is running; safe in traps and
# safe to call twice.
fake_server_stop() {
  local pid="${FAKE_PID:-}"
  [ -n "$pid" ] || return 0
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  FAKE_PID=""
  return 0
}

# fake_env_cleanup - EXIT handler: stop the server, then run the trap that was
# installed before fake_server_start (env.sh's feature_cleanup).
fake_env_cleanup() {
  fake_server_stop
  local prev="${FAKE_PREV_TRAP:-}"
  prev="${prev#trap -- \'}"
  prev="${prev%\' EXIT}"
  if [ -n "$prev" ]; then
    # shellcheck disable=SC2294  # the previous trap is an eval-ready command
    eval "$prev" || true
  fi
  return 0
}

fake_env_trap_install() {
  [ "$FAKE_TRAP_INSTALLED" = "1" ] && return 0
  FAKE_PREV_TRAP="$(trap -p EXIT)"
  FAKE_TRAP_INSTALLED=1
  trap 'fake_env_cleanup' EXIT
}

# fake_server_start - start the server and prepare the rclone remote. Returns
# non-zero (and prints why) when python3/rclone are missing or startup fails.
fake_server_start() {
  command -v python3 >/dev/null 2>&1 || {
    echo "SKIP: python3 not installed" >&2
    return 1
  }
  command -v rclone >/dev/null 2>&1 || {
    echo "SKIP: rclone not installed" >&2
    return 1
  }
  fake_server_stop
  mkdir -p "$FAKE_STATE"
  : >"$FAKE_OUT"
  : >"$FAKE_ERR"
  python3 "${PROJ}/tests/fake_server.py" --port 0 --user "$FAKE_USER" \
    --password "$FAKE_PASSWORD" --state "$FAKE_STATE" >"$FAKE_OUT" 2>"$FAKE_ERR" &
  # shellcheck disable=SC2034  # read by fake_server_stop and the tests
  FAKE_PID=$!

  local i=0 line=""
  while [ "$i" -lt 100 ]; do
    line="$(sed -n 's/^PORT=\([0-9][0-9]*\)$/\1/p' "$FAKE_OUT" 2>/dev/null | head -n 1)"
    if [ -n "$line" ]; then
      FAKE_PORT="$line"
      break
    fi
    kill -0 "$FAKE_PID" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  if [ -z "$FAKE_PORT" ]; then
    echo "fake_server_start: server did not report a port" >&2
    sed -n '1,20p' "$FAKE_ERR" >&2 || true
    fake_server_stop
    return 1
  fi

  FAKE_BASE="http://127.0.0.1:${FAKE_PORT}"
  export FAKE_PORT FAKE_BASE FAKE_USER FAKE_PASSWORD FAKE_STATE

  i=0
  while [ "$i" -lt 100 ]; do
    fake_curl -fsS --max-time 2 "$FAKE_BASE/status.php" >/dev/null 2>&1 && break
    sleep 0.1
    i=$((i + 1))
  done
  if [ "$i" -ge 100 ]; then
    echo "fake_server_start: ${FAKE_BASE}/status.php never answered" >&2
    fake_server_stop
    return 1
  fi

  rclone config create "$FAKE_REMOTE" webdav \
    url="$FAKE_BASE/remote.php/dav/files/${FAKE_USER}/" vendor=nextcloud \
    user="$FAKE_USER" pass="$(rclone obscure "$FAKE_PASSWORD")" \
    --config "$RCLONE_CONFIG" >/dev/null 2>&1 || {
    echo "fake_server_start: cannot create the rclone remote ${FAKE_REMOTE}" >&2
    fake_server_stop
    return 1
  }
  export RCLONE_REMOTE="$FAKE_REMOTE"
  fake_env_trap_install
  printf 'fake server ready at %s (state %s)\n' "$FAKE_BASE" "$FAKE_STATE"
  return 0
}
