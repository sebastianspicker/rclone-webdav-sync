#!/usr/bin/env bash
# nextcloud-up.sh - start a throwaway Nextcloud (SQLite, apache) in Docker for
# the contract test suite, create a test user, and mint an app password.
#
# On success prints three "export NAME=value" lines on stdout:
#   NC_URL      http://127.0.0.1:<port>  (no trailing slash)
#   NC_USER     alice
#   NC_APPPASS  the app password minted through the OCS getapppassword API
#
# Everything else (progress, docker/curl output) goes to stderr, so a caller
# can do `eval "$(bash tests/contract/nextcloud-up.sh)"` to pick up the three
# variables. No credential is ever written into the repo tree; the container,
# its generated admin/user passwords, and the app password only ever live in
# Docker and this process's environment.
#
# Env overrides: CONTRACT_IMAGE (pinned Nextcloud tag), CONTRACT_CONTAINER
# (docker container name, default sciebo-contract-nc), CONTRACT_TIMEOUT
# (seconds to wait for status.php, default 180).
set -uo pipefail

: "${CONTRACT_IMAGE:=nextcloud:34.0.4-apache}"
: "${CONTRACT_CONTAINER:=sciebo-contract-nc}"
: "${CONTRACT_TIMEOUT:=180}"

log() { printf 'nextcloud-up: %s\n' "$1" >&2; }
die() {
  printf 'nextcloud-up: %s\n' "$1" >&2
  exit 1
}

command -v docker >/dev/null 2>&1 || die "docker is not installed"
command -v curl >/dev/null 2>&1 || die "curl is not installed"
docker info >/dev/null 2>&1 || die "docker daemon is not reachable"

if docker ps -a --format '{{.Names}}' | grep -qx "$CONTRACT_CONTAINER"; then
  die "container '${CONTRACT_CONTAINER}' already exists; run nextcloud-down.sh first"
fi

# random_hex N - N bytes of hex from /dev/urandom (portable, no openssl dep).
random_hex() {
  local n="${1:-16}"
  LC_ALL=C od -An -N"$n" -tx1 /dev/urandom | tr -d ' \n'
}

# free_port - ask the kernel for an unused TCP port on 127.0.0.1. Best-effort:
# the port is free at the moment python3 releases the listening socket, and
# Docker binds it immediately after, so the race window is small.
free_port() {
  command -v python3 >/dev/null 2>&1 || die "python3 is not installed (needed to pick a free port)"
  python3 -c '
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
'
}

PORT="$(free_port)"
[[ -n "$PORT" ]] || die "could not obtain a free port"
ADMIN_PASS="$(random_hex 16)"
ALICE_PASS="$(random_hex 16)"
NC_URL="http://127.0.0.1:${PORT}"

log "starting ${CONTRACT_IMAGE} as '${CONTRACT_CONTAINER}' on ${NC_URL}"
docker run -d --name "$CONTRACT_CONTAINER" \
  -p "127.0.0.1:${PORT}:80" \
  -e SQLITE_DATABASE=nextcloud \
  -e NEXTCLOUD_ADMIN_USER=admin \
  -e NEXTCLOUD_ADMIN_PASSWORD="$ADMIN_PASS" \
  -e NEXTCLOUD_TRUSTED_DOMAINS="127.0.0.1" \
  "$CONTRACT_IMAGE" >/dev/null ||
  die "docker run failed"

cleanup_on_failure() {
  docker rm -f "$CONTRACT_CONTAINER" >/dev/null 2>&1 || true
}

log "waiting up to ${CONTRACT_TIMEOUT}s for the installer (status.php)"
deadline=$((SECONDS + CONTRACT_TIMEOUT))
installed=0
while [[ "$SECONDS" -lt "$deadline" ]]; do
  body="$(curl -fsS "${NC_URL}/status.php" 2>/dev/null)" || body=""
  case "$body" in
    *'"installed":true'*)
      installed=1
      break
      ;;
  esac
  sleep 2
done
if [[ "$installed" -ne 1 ]]; then
  log "installer did not finish in time; last status.php body: ${body:-<none>}"
  log "container logs:"
  docker logs "$CONTRACT_CONTAINER" >&2 2>&1 || true
  cleanup_on_failure
  die "Nextcloud did not become ready"
fi
log "installer finished"

log "creating user 'alice'"
if ! docker exec -u 33 -e OC_PASS="$ALICE_PASS" "$CONTRACT_CONTAINER" \
  php occ user:add --password-from-env --display-name="Alice" alice >&2; then
  cleanup_on_failure
  die "user:add failed"
fi

log "minting an app password for alice via OCS getapppassword"
apppass_json="$(curl -fsS -u "alice:${ALICE_PASS}" -H 'OCS-APIRequest: true' \
  -H 'Accept: application/json' \
  "${NC_URL}/ocs/v2.php/core/getapppassword?format=json" 2>/dev/null)" || apppass_json=""
NC_APPPASS="$(printf '%s' "$apppass_json" | LC_ALL=C awk '
  {
    pos = index($0, "\"apppassword\"")
    if (pos == 0) next
    rest = substr($0, pos + 13)
    sub(/^[ \t]*:[ \t]*"/, "", rest)
    sub(/".*$/, "", rest)
    print rest
    found = 1
    exit
  }
  END { exit(found ? 0 : 1) }
')"
if [[ -z "$NC_APPPASS" ]]; then
  log "getapppassword response: ${apppass_json}"
  cleanup_on_failure
  die "could not mint an app password"
fi

log "Nextcloud contract instance ready: ${NC_URL} (user alice)"
printf 'export NC_URL=%q\n' "$NC_URL"
printf 'export NC_USER=%q\n' "alice"
printf 'export NC_APPPASS=%q\n' "$NC_APPPASS"
