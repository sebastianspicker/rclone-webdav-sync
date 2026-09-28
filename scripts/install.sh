#!/usr/bin/env bash
# install.sh - transactional implementation behind `make install` and the
# matching data-preserving `make uninstall`.
set -euo pipefail

ROOT="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
MODE="${1:-}"
PREFIX="${2:-}"
VERSION="${3:-}"
shift "$(($# >= 3 ? 3 : $#))"
CODE_ITEMS=("$@")

usage() {
  printf 'usage: %s install|uninstall PREFIX VERSION CODE_ITEM...\n' "${BASH_SOURCE[0]}" >&2
  exit 2
}

[[ "$MODE" == install || "$MODE" == uninstall ]] || usage
[[ -n "$PREFIX" ]] || {
  printf 'install: PREFIX must not be empty\n' >&2
  exit 1
}
((${#CODE_ITEMS[@]} > 0)) || usage

DEST="${PREFIX%/}/share/rclone-sciebo"
BIN_TARGET="${PREFIX%/}/bin/sciebo"
MAN_TARGET="${PREFIX%/}/share/man/man1/sciebo.1"

path_exists() { [[ -e "$1" || -L "$1" ]]; }

die_install() {
  printf 'install: %s\n' "$*" >&2
  exit 1
}

uninstall_tree() {
  local item="" had_dest=0
  if [[ -d "$DEST" ]]; then
    had_dest=1
    for item in "${CODE_ITEMS[@]}"; do
      rm -rf -- "${DEST:?}/${item}" || die_install "cannot remove ${DEST}/${item}"
    done
    printf 'removed code and assets under %s\n' "$DEST"
  fi
  if path_exists "$BIN_TARGET"; then
    rm -f -- "$BIN_TARGET" || die_install "cannot remove ${BIN_TARGET}"
    printf 'removed %s\n' "$BIN_TARGET"
  fi
  if path_exists "$MAN_TARGET"; then
    rm -f -- "$MAN_TARGET" || die_install "cannot remove ${MAN_TARGET}"
    printf 'removed %s\n' "$MAN_TARGET"
  fi
  if ((had_dest)) &&
    [[ -z "$(find "$DEST" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    rmdir "$DEST" || die_install "cannot remove empty install directory ${DEST}"
  fi
  if [[ -d "$DEST" ]]; then
    printf 'config and state remain in %s (remove with: rm -rf %s)\n' "$DEST" "$DEST"
  fi
}

if [[ "$MODE" == uninstall ]]; then
  uninstall_tree
  exit 0
fi

[[ -n "$VERSION" ]] || die_install "VERSION file missing"

mkdir -p "$DEST" "${PREFIX%/}/bin" "${PREFIX%/}/share/man/man1" ||
  die_install "cannot create install directories under ${PREFIX}"

STAGE="$(mktemp -d "${DEST}/.install-stage.XXXXXX")" ||
  die_install "cannot create staging directory under ${DEST}"
BACKUP="$(mktemp -d "${DEST}/.install-backup.XXXXXX")" || {
  rm -rf -- "$STAGE"
  die_install "cannot create rollback directory under ${DEST}"
}
COMMITTING=0
TX_TARGETS=()
TX_BACKUPS=()
TX_HAD_OLD=()
PRESERVED=()

# rollback_transaction - reverse every committed target. Entries are recorded
# immediately after an old target is moved aside, before the staged target is
# moved into place, so a failed second move is recoverable too.
rollback_transaction() {
  local i=0 target="" backup_path="" failed=0
  for ((i = ${#TX_TARGETS[@]} - 1; i >= 0; i--)); do
    target="${TX_TARGETS[$i]}"
    backup_path="${TX_BACKUPS[$i]}"
    if path_exists "$target"; then
      rm -rf -- "$target" || failed=1
    fi
    if [[ "${TX_HAD_OLD[$i]}" == 1 ]]; then
      mkdir -p "${target%/*}" || failed=1
      mv -- "$backup_path" "$target" || failed=1
    fi
  done
  return "$failed"
}

cleanup_install() {
  local rc=$? rollback_failed=0
  trap - EXIT HUP INT TERM
  set +e
  if ((rc != 0 && COMMITTING)); then
    printf 'install: replacement failed; restoring the previous installation\n' >&2
    rollback_transaction || rollback_failed=1
  fi
  rm -rf -- "$STAGE"
  if ((rollback_failed)); then
    printf 'install: rollback was incomplete; recovery files remain at %s\n' "$BACKUP" >&2
  else
    rm -rf -- "$BACKUP"
  fi
  exit "$rc"
}
trap cleanup_install EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# transaction_replace SOURCE TARGET BACKUP_KEY - atomically move TARGET aside
# and put the already-staged SOURCE in its place. A missing SOURCE deliberately
# removes an obsolete shipped item while retaining it in the rollback tree.
transaction_replace() {
  local source="$1" target="$2" key="$3" backup_path="" had_old=0
  backup_path="${BACKUP}/${key}"
  mkdir -p "${target%/*}" "${backup_path%/*}"
  if path_exists "$target"; then
    mv -- "$target" "$backup_path"
    had_old=1
  fi
  TX_TARGETS+=("$target")
  TX_BACKUPS+=("$backup_path")
  TX_HAD_OLD+=("$had_old")
  if path_exists "$source"; then
    mv -- "$source" "$target"
  fi
}

# Stage every byte before touching the working installation. Copy failures,
# full disks, and unreadable sources therefore leave the old tree intact.
for item in "${CODE_ITEMS[@]}"; do
  source_path="${ROOT}/${item}"
  stage_path="${STAGE}/code/${item}"
  path_exists "$source_path" || continue
  mkdir -p "${stage_path%/*}"
  cp -R "$source_path" "$stage_path" || die_install "cannot stage ${item}"
done

mkdir -p "${STAGE}/managed-config" "${STAGE}/seed-config"
cp "${ROOT}/config/settings.env" "${STAGE}/managed-config/settings.env" ||
  die_install "cannot stage config/settings.env"
cp "${ROOT}/config/settings.local.env.example" \
  "${STAGE}/managed-config/settings.local.env.example" ||
  die_install "cannot stage config/settings.local.env.example"

while IFS= read -r -d '' source_path; do
  relative="${source_path#"${ROOT}/config/"}"
  basename="${relative##*/}"
  case "$basename" in
    .* | settings.env | settings.local.env.example | settings.local.env | sources.generated.conf) continue ;;
  esac
  stage_path="${STAGE}/seed-config/${relative}"
  mkdir -p "${stage_path%/*}"
  cp "$source_path" "$stage_path" || die_install "cannot stage config/${relative}"
done < <(find "${ROOT}/config" -type f -print0)

mkdir -p "${STAGE}/external"
printf '#!/usr/bin/env bash\nexec bash "%s/bin/sciebo" "$@"\n' "$DEST" >"${STAGE}/external/sciebo"
chmod +x "${STAGE}/external/sciebo"
if [[ -f "${ROOT}/man/sciebo.1" ]]; then
  cp "${ROOT}/man/sciebo.1" "${STAGE}/external/sciebo.1" ||
    die_install "cannot stage man/sciebo.1"
fi

COMMITTING=1
for item in "${CODE_ITEMS[@]}"; do
  transaction_replace "${STAGE}/code/${item}" "${DEST}/${item}" "code/${item}"
done

mkdir -p "${DEST}/config"
transaction_replace "${STAGE}/managed-config/settings.env" \
  "${DEST}/config/settings.env" "config/settings.env"
transaction_replace "${STAGE}/managed-config/settings.local.env.example" \
  "${DEST}/config/settings.local.env.example" "config/settings.local.env.example"

while IFS= read -r -d '' stage_path; do
  relative="${stage_path#"${STAGE}/seed-config/"}"
  target="${DEST}/config/${relative}"
  if path_exists "$target"; then
    PRESERVED+=("$relative")
    continue
  fi
  transaction_replace "$stage_path" "$target" "config/${relative}"
done < <(find "${STAGE}/seed-config" -type f -print0)

transaction_replace "${STAGE}/external/sciebo" "$BIN_TARGET" external/sciebo
if [[ -f "${STAGE}/external/sciebo.1" ]]; then
  transaction_replace "${STAGE}/external/sciebo.1" "$MAN_TARGET" external/sciebo.1
fi
COMMITTING=0

if ((${#PRESERVED[@]} > 0)); then
  printf 'preserved existing config:'
  printf ' %s' "${PRESERVED[@]}"
  printf '\n'
fi
if [[ -d "${DEST}/state" ]]; then
  printf 'preserved existing state/\n'
fi
printf 'installed sciebo %s to %s\n' "$VERSION" "$BIN_TARGET"
