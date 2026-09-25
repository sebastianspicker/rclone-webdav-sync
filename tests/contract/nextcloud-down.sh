#!/usr/bin/env bash
# nextcloud-down.sh - remove the throwaway Nextcloud container started by
# nextcloud-up.sh. Idempotent: a missing container is not an error.
set -uo pipefail

: "${CONTRACT_CONTAINER:=sciebo-contract-nc}"

command -v docker >/dev/null 2>&1 || {
  printf 'nextcloud-down: docker is not installed\n' >&2
  exit 0
}

if docker ps -a --format '{{.Names}}' | grep -qx "$CONTRACT_CONTAINER"; then
  docker rm -f "$CONTRACT_CONTAINER" >/dev/null
  printf 'nextcloud-down: removed %s\n' "$CONTRACT_CONTAINER" >&2
else
  printf 'nextcloud-down: %s not running\n' "$CONTRACT_CONTAINER" >&2
fi
