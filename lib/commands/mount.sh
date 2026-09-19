#!/bin/bash
# mount.sh - on-demand rclone nfsmount (virtual files, never scheduled).
MNT_TABLE_LOADED=0 MNT_TABLE="" MNT_FOLDER="" MNT_MOUNTPOINT="" MNT_NAME="" MNT_SPEC=""
MNT_PATH="" MNT_MODE=rw MNT_STATE="" MNT_RO=false MNT_FOREGROUND=false MNT_SUDO=false
MNT_ARGV=() MNT_ACTIVE_STATE=""

usage_mount() {
  cat <<'EOF'
Usage: sciebo mount [options]

On-demand access to the configured rclone remote as a local filesystem
(rclone nfsmount; no macFUSE needed on macOS). Mounts are created and
removed only when this command is run; nothing is scheduled or started
automatically.

Options:
  --folder SUB       remote subfolder below the remote base
  --mountpoint PATH  local mountpoint (default: MOUNT_ROOT or MOUNT_ROOT/<name>)
  --ro               read-only mount, no VFS cache
  --foreground       run rclone in the foreground (Ctrl-C to unmount)
  --sudo             run rclone as root; macOS NFS mounts usually need this
  -h, --help         show this help

State lives in STATE_DIR/mounts; credentials stay in the rclone config.
EOF
}

usage_umount() {
  cat <<'EOF'
Usage: sciebo umount (--folder SUB | --mountpoint PATH | --all) [--sudo]

Unmount a recorded mount and remove its state. macOS NFS unmounts usually
need --sudo.

Options:
  --folder SUB       unmount the mount recorded for this remote subfolder
  --mountpoint PATH  unmount the mount recorded for this local mountpoint
  --all              unmount every recorded mount
  --sudo             run umount as root
  -h, --help         show this help
EOF
}

usage_mounts() {
  cat <<'EOF'
Usage: sciebo mounts [--folder SUB]

Show recorded mounts with mount visibility, rclone pid, and pid liveness.

Options:
  --folder SUB   only show the mount recorded for this remote subfolder
  -h, --help     show this help
EOF
}
usage_show() {
  "usage_$1"
  exit 0
}

load_mount_table() {
  [[ "$MNT_TABLE_LOADED" -ne 1 ]] || return 0
  MNT_TABLE="$(mount 2>/dev/null || true)" MNT_TABLE_LOADED=1
}
is_mounted() {
  load_mount_table
  [[ "$MNT_TABLE" == *" on $1 ("* ]]
}
looks_like_privilege_error() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    *permission* | *"operation not permitted"* | *"must be root"* | *"root privileges"*) return 0 ;;
  esac
  return 1
}
bool_yes_no() {
  if [[ "$1" == true ]]; then printf 'yes'; else printf 'no'; fi
}
mount_state_files() {
  [[ -d "$MOUNTS_DIR" ]] || return 0
  find "$MOUNTS_DIR" -maxdepth 1 -type f -name '*.state' 2>/dev/null | sort
}
mount_state_read() {
  T_STATE="$1"
  T_NAME="$(basename "${1%.state}")"
  T_FOLDER="" T_MNT="" T_PID="-" T_SUDO=no
  [[ -f "$1" ]] || return 0
  { IFS= read -r T_FOLDER && IFS= read -r T_MNT && IFS= read -r T_PID && IFS= read -r T_SUDO; } <"$1" || true
  [[ -n "$T_PID" ]] || T_PID="-"
  [[ -n "$T_SUDO" ]] || T_SUDO=no
}
mount_state_write() {
  printf '%s\n' "$2" "$3" "$4" "$5" | atomic_write "$1" 600
}
mount_failed() {
  [[ -z "$1" ]] || printf '%s\n' "$1" >&2
  if looks_like_privilege_error "$1"; then err "rclone nfsmount failed with a privilege error; macOS NFS mounts usually need --sudo (re-run with --sudo)"; else err "rclone nfsmount failed (exit ${2})"; fi
  return 1
}
find_mount_pid() {
  local pid
  # shellcheck disable=SC2009  # pgrep -f treats the mountpoint as a regex
  pid="$(ps -axo pid=,command= 2>/dev/null | grep -F 'nfsmount' | grep -F -e "$1" | awk '{ print $1; exit }')" || true
  printf '%s' "${pid:--}"
}

mount_preflight() {
  remote_configured || die "rclone remote '${RCLONE_REMOTE}' is not configured; run '${CLI_NAME} setup'"
  if [[ -n "$MNT_FOLDER" ]]; then
    MNT_NAME="$(sanitize_name "$MNT_FOLDER")"
    [[ -n "$MNT_NAME" ]] || die "cannot derive a mount name from folder '${MNT_FOLDER}'"
    MNT_SPEC="$(remote_spec "$MNT_FOLDER")"
    MNT_PATH="${MNT_MOUNTPOINT:-${MOUNT_ROOT}/${MNT_NAME}}"
  else
    MNT_NAME=root MNT_SPEC="$REMOTE_PREFIX" MNT_PATH="${MNT_MOUNTPOINT:-$MOUNT_ROOT}"
  fi
  if ! remote_dir_exists "$MNT_SPEC"; then
    [[ -z "$MNT_FOLDER" ]] || die "remote folder '${MNT_SPEC}' not found"
    die "remote base '${MNT_SPEC}' not found; run '${CLI_NAME} setup'"
  fi
  MNT_STATE="${MOUNTS_DIR}/${MNT_NAME}.state"
  if [[ -f "$MNT_STATE" ]]; then
    mount_state_read "$MNT_STATE"
    [[ -z "$T_MNT" ]] || ! is_mounted "$T_MNT" || die "already mounted at ${T_MNT} (name=${MNT_NAME}); run '${CLI_NAME} umount --mountpoint ${T_MNT}' first"
    die "mount state already exists for '${MNT_NAME}' (${MNT_STATE}); run '${CLI_NAME} umount --mountpoint ${T_MNT:-$MNT_PATH}' first"
  fi
  is_mounted "$MNT_PATH" && die "already mounted at ${MNT_PATH}"
  if [[ -d "$MNT_PATH" ]]; then
    [[ -z "$(ls -A "$MNT_PATH" 2>/dev/null || true)" ]] || die "mountpoint is not empty: ${MNT_PATH}"
  elif ! mkdir -p "$MNT_PATH"; then
    die "cannot create mountpoint: ${MNT_PATH}"
  fi
}
build_mount_argv() {
  local -a extra_flags
  MNT_ARGV=("$RCLONE_BIN" --config "$RCLONE_CONFIG" nfsmount "${MNT_SPEC}/" "$MNT_PATH"
    --volname "sciebo${MNT_FOLDER:+/$MNT_FOLDER}" --dir-cache-time 1m
    --cache-dir "$MOUNT_CACHE_DIR" --log-file "${LOG_DIR}/mount-${MNT_NAME}.log"
    --log-level INFO)
  [[ "$MNT_FOREGROUND" == true ]] || MNT_ARGV+=(--daemon)
  if [[ "$MNT_RO" == true ]]; then MNT_MODE=ro MNT_ARGV+=(--read-only); else MNT_ARGV+=(--vfs-cache-mode writes --vfs-cache-max-size "$MOUNT_CACHE_MAX_SIZE"); fi
  [[ "$MNT_SUDO" != true ]] || MNT_ARGV+=(--sudo)
  if [[ -n "$MOUNT_EXTRA_FLAGS" ]]; then
    read -r -a extra_flags <<<"$MOUNT_EXTRA_FLAGS"
    [[ "${#extra_flags[@]}" -eq 0 ]] || MNT_ARGV+=("${extra_flags[@]}")
  fi
}
run_mount_command() {
  local out=""
  if out="$("${MNT_ARGV[@]}" 2>&1)"; then
    MNT_TABLE_LOADED=0 MNT_TABLE=""
    return 0
  fi
  mount_failed "$out" "$?"
}
record_state() {
  local i
  mount_state_write "$MNT_STATE" "$MNT_FOLDER" "$MNT_PATH" "$(find_mount_pid "$MNT_PATH")" "$(bool_yes_no "$MNT_SUDO")"
  MNT_TABLE_LOADED=0 MNT_TABLE=""
  for i in 1 2 3 4 5; do
    is_mounted "$MNT_PATH" && break
    sleep 1
    MNT_TABLE_LOADED=0 MNT_TABLE=""
  done
  is_mounted "$MNT_PATH" || warn "mount not visible in \`mount\` output yet"
}
run_foreground_mount() {
  local out=""
  MNT_ACTIVE_STATE="$MNT_STATE"
  trap 'rm -f "$MNT_ACTIVE_STATE"; release_lock' EXIT
  mount_state_write "$MNT_STATE" "$MNT_FOLDER" "$MNT_PATH" - "$(bool_yes_no "$MNT_SUDO")"
  log "Mounting ${MNT_SPEC} at ${MNT_PATH} (${MNT_MODE}, name=${MNT_NAME}) in the foreground; press Ctrl-C to unmount"
  if out="$("${MNT_ARGV[@]}" 2>&1)"; then
    printf 'Unmounted %s from %s\n' "$MNT_SPEC" "$MNT_PATH"
    return 0
  fi
  mount_failed "$out" "$?"
}

cmd_mount() {
  opt_reset folder mountpoint ro foreground sudo
  opt_parse "folder:s mountpoint:s ro:b foreground:b sudo:b" mount "" "$@"
  [[ "$OPT_HELP" -eq 0 ]] || usage_show mount
  [[ -z "$OPT_EXTRA" ]] || usage_error mount "unknown option: ${OPT_EXTRA%%$'\n'*}"
  local folder="${OPT_folder:-}"
  while [[ "$folder" == */ ]]; do folder="${folder%/}"; done
  [[ -z "$folder" ]] || safe_remote_path "$folder" || die "invalid remote folder: ${folder}"
  MNT_FOLDER="$folder"
  MNT_MOUNTPOINT="${OPT_mountpoint:-}"
  MNT_RO=false MNT_FOREGROUND=false MNT_SUDO=false
  [[ -z "${OPT_ro:-}" ]] || MNT_RO=true
  [[ -z "${OPT_foreground:-}" ]] || MNT_FOREGROUND=true
  [[ -z "${OPT_sudo:-}" ]] || MNT_SUDO=true
  load_settings
  ensure_state_dirs
  mkdir -p "$MOUNTS_DIR" "$MOUNT_CACHE_DIR"
  mount_preflight
  build_mount_argv
  if [[ "$MNT_FOREGROUND" == true ]]; then
    run_foreground_mount
    return $?
  fi
  run_mount_command || return $?
  record_state
  printf 'Mounted %s at %s (%s, name=%s)\n' "$MNT_SPEC" "$MNT_PATH" "$MNT_MODE" "$MNT_NAME"
  if [[ -n "$MNT_FOLDER" ]]; then printf 'Unmount with: %s umount --folder %s\n' "$CLI_NAME" "$MNT_FOLDER"; else printf 'Unmount with: %s umount --mountpoint %s\n' "$CLI_NAME" "$MNT_PATH"; fi
}

resolve_folder_target() {
  local folder="$1" name=root mnt="$MOUNT_ROOT"
  if [[ -n "$folder" ]]; then
    while [[ "$folder" == */ ]]; do folder="${folder%/}"; done
    safe_remote_path "$folder" || die "invalid remote folder: ${folder}"
    name="$(sanitize_name "$folder")"
    [[ -n "$name" ]] || die "cannot derive a mount name from folder '${folder}'"
    mnt="${MOUNT_ROOT}/${name}"
  fi
  if [[ -f "${MOUNTS_DIR}/${name}.state" ]]; then
    mount_state_read "${MOUNTS_DIR}/${name}.state"
  else
    T_STATE="" T_NAME="$name" T_FOLDER="$folder" T_MNT="$mnt" T_PID="-" T_SUDO=no
  fi
}
resolve_mountpoint_target() {
  local state name
  name="$(sanitize_name "$(basename "$1")")"
  [[ -n "$name" ]] || name=mount
  while IFS= read -r state; do mount_state_read "$state" && [[ "$T_MNT" == "$1" ]] && return 0; done < <(mount_state_files)
  T_STATE="" T_NAME="$name" T_FOLDER="" T_MNT="$1" T_PID="-" T_SUDO=no
}

mount_do_umount() {
  local use_sudo="$1" rc=0
  if ! is_mounted "$T_MNT"; then log "${T_MNT}: not visible in mount output" && return 0; fi
  if [[ "$use_sudo" == true || "$T_SUDO" == yes ]]; then
    if ! have sudo; then
      err "sudo not found but required to unmount ${T_MNT}"
      rc=1
    elif ! sudo umount "$T_MNT"; then rc=1; fi
  elif ! umount "$T_MNT"; then rc=1; fi
  MNT_TABLE_LOADED=0 MNT_TABLE=""
  if [[ "$rc" -eq 0 ]]; then log "unmounted ${T_MNT}" && return 0; fi
  is_mounted "$T_MNT" || log "${T_MNT} disappeared from mount output despite the umount error"
  is_mounted "$T_MNT" || return 0
  err "failed to unmount ${T_MNT}; keeping its state for a retry"
  if [[ "$use_sudo" == false && "$T_SUDO" != yes ]]; then
    err "macOS NFS unmounts may require root; re-run with --sudo"
  fi
  return 1
}

mount_stop_recorded_pid() {
  local pid="$T_PID" command_line="" i=0
  [[ -n "$pid" && "$pid" != "-" ]] || return 0
  kill -0 "$pid" 2>/dev/null || return 0
  command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  if [[ "$command_line" != *nfsmount* || "$command_line" != *"$T_MNT"* ]]; then
    warn "not killing pid ${pid}: it is not the rclone nfsmount for ${T_MNT}"
    return 0
  fi
  kill "$pid" 2>/dev/null || true
  while kill -0 "$pid" 2>/dev/null && [[ "$i" -lt 3 ]]; do sleep 1 && i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
    warn "rclone (pid ${pid}) ignored SIGTERM; sent SIGKILL"
  fi
  log "stopped rclone (pid ${pid})"
}
umount_record() {
  mount_do_umount "$1" || return 1
  mount_stop_recorded_pid
  [[ -f "$T_STATE" ]] || return 0
  rm -f "$T_STATE"
  log "removed state ${T_STATE}"
}
umount_all() {
  local found=0 failures=0 state
  while IFS= read -r state; do
    found=1
    mount_state_read "$state"
    umount_record "$1" || failures=1
  done < <(mount_state_files)
  [[ "$found" -gt 0 ]] || printf 'no rclone mounts recorded\n'
  [[ "$failures" -eq 0 ]]
}

cmd_umount() {
  opt_reset folder mountpoint all sudo
  opt_parse "folder:s mountpoint:s all:b sudo:b" umount "" "$@"
  [[ "$OPT_HELP" -eq 0 ]] || usage_show umount
  [[ -z "$OPT_EXTRA" ]] || usage_error umount "unknown option: ${OPT_EXTRA%%$'\n'*}"
  local picks="${OPT_folder_SET:-}${OPT_mountpoint_SET:-}${OPT_all_SET:-}" use_sudo=false
  [[ -n "$picks" ]] || usage_error umount "umount requires --folder, --mountpoint, or --all"
  [[ "${#picks}" -eq 1 ]] || usage_error umount "use only one of --folder, --mountpoint, --all"
  [[ -z "${OPT_sudo:-}" ]] || use_sudo=true
  load_settings --no-rclone
  if [[ -n "${OPT_all_SET:-}" ]]; then umount_all "$use_sudo" && return 0 || return $?; fi
  if [[ -n "${OPT_folder_SET:-}" ]]; then resolve_folder_target "${OPT_folder}"; else resolve_mountpoint_target "${OPT_mountpoint}"; fi
  if [[ -z "$T_STATE" ]] && ! is_mounted "$T_MNT"; then printf '%s: not mounted\n' "$T_MNT"; fi
  [[ -n "$T_STATE" ]] || is_mounted "$T_MNT" || return 0
  umount_record "$use_sudo"
}

cmd_mounts() {
  opt_reset folder
  opt_parse "folder:s" mounts "" "$@"
  [[ "$OPT_HELP" -eq 0 ]] || usage_show mounts
  [[ -z "$OPT_EXTRA" ]] || usage_error mounts "unknown option: ${OPT_EXTRA%%$'\n'*}"
  load_settings --no-rclone
  local only="" found=0 state mounted alive
  [[ -z "${OPT_folder:-}" ]] || only="$(sanitize_name "$OPT_folder")"
  while IFS= read -r state; do
    mount_state_read "$state"
    [[ -z "$only" || "$T_NAME" == "$only" ]] || continue
    found=$((found + 1))
    mounted=no alive=no
    is_mounted "$T_MNT" && mounted=yes
    [[ "$T_PID" != "-" ]] && kill -0 "$T_PID" 2>/dev/null && alive=yes
    printf '%s  %s  %s  mounted=%s  pid=%s  alive=%s\n' "$T_NAME" "${T_FOLDER:-(base)}" "$T_MNT" "$mounted" "$T_PID" "$alive"
  done < <(mount_state_files)
  [[ "$found" -gt 0 ]] || printf 'no rclone mounts recorded\n'
}
