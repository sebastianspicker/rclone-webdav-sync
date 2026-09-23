#!/bin/bash
# mount.sh - on-demand rclone nfsmount (virtual files, never scheduled).
MNT_TABLE_LOADED=0 MNT_TABLE="" MNT_FOLDER="" MNT_MOUNTPOINT="" MNT_NAME="" MNT_SPEC=""
MNT_PATH="" MNT_MODE=rw MNT_STATE="" MNT_RO=false MNT_FOREGROUND=false MNT_SUDO=false
MNT_ARGV=() MNT_ACTIVE_STATE=""

usage_mount() {
  usage_emit <<'EOF'
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
  usage_emit <<'EOF'
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
  usage_emit <<'EOF'
Usage: sciebo mounts [--folder SUB] [--check] [--prune] [--json]

Show recorded mounts with mount visibility, rclone pid, and pid liveness.

Options:
  --folder SUB   only show the mount recorded for this remote subfolder
  --check        exit 1 when a recorded mount is not visible or its rclone is gone
  --prune        remove state records for mounts whose mountpoint is not mounted and whose pid is not alive
  --json         print the mounts as {"mounts":[{...}]} instead of the table
                 (pid is null when unknown)
  -h, --help     show this help
EOF
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
  local LC_ALL=C
  case "${1,,}" in
    *permission* | *"operation not permitted"* | *"must be root"* | *"root privileges"*) return 0 ;;
  esac
  return 1
}
mount_state_files() {
  [[ -d "$MOUNTS_DIR" ]] || return 0
  find "$MOUNTS_DIR" -maxdepth 1 -type f -name '*.state' 2>/dev/null | sort
}
mount_state_read() {
  T_STATE="$1"
  # basename via parameter expansion: strip the .state suffix first, then
  # everything up to the last slash (state files always come from find in
  # MOUNTS_DIR, so there is no trailing slash to trim like basename would).
  T_NAME="${1%.state}"
  T_NAME="${T_NAME##*/}"
  T_FOLDER="" T_MNT="" T_PID="-" T_SUDO=no
  [[ -f "$1" ]] || return 0
  { IFS= read -r T_FOLDER && IFS= read -r T_MNT && IFS= read -r T_PID && IFS= read -r T_SUDO; } <"$1" || true
  [[ "$T_PID" =~ ^[0-9]+$ ]] || T_PID="-"
  [[ "$T_SUDO" == yes ]] || T_SUDO=no
}
mount_state_write() {
  printf '%s\n' "$2" "$3" "$4" "$5" | atomic_write "$1" 600
}
mount_failed() {
  [[ -z "$1" ]] || printf '%s\n' "$1" | sanitize_stream >&2
  if looks_like_privilege_error "$1"; then err "rclone nfsmount failed with a privilege error; macOS NFS mounts usually need --sudo (re-run with --sudo)"; else err "rclone nfsmount failed (exit ${2})"; fi
  return 1
}
find_mount_pid() {
  local ps_out="" line="" pid=""
  # One `ps -axo pid=,command=` capture per call (portable BSD/GNU, same
  # flags as before) replaces the old `ps | grep -F | grep -F | awk`
  # pipeline of four execs: the two grep -F patterns become whole-line bash
  # substring tests (still literal, never a regex - pgrep -f would treat the
  # mountpoint as one), and the pid is the first field of the first matching
  # line, exactly like `awk '{ print $1; exit }'`.
  ps_out="$(ps -axo pid=,command= 2>/dev/null)" || true
  while IFS= read -r line; do
    [[ "$line" == *nfsmount* && "$line" == *"$1"* ]] || continue
    # Trim the leading column padding, then keep the leading digit run.
    pid="${line#"${line%%[![:space:]]*}"}"
    pid="${pid%%[!0-9]*}"
    break
  done <<<"$ps_out"
  printf '%s' "${pid:--}"
}

# mount_derive_target FOLDER - set MNT_NAME/MNT_SPEC from a remote folder
# (empty = the remote base, name "root"). Dies when the name cannot be
# derived. MNT_PATH is left to the caller because it also honors
# --mountpoint.
mount_derive_target() {
  local folder="$1"
  if [[ -n "$folder" ]]; then
    MNT_NAME="$(sanitize_name "$folder")"
    [[ -n "$MNT_NAME" ]] || die "cannot derive a mount name from folder '${folder}'"
    MNT_SPEC="$(remote_spec "$folder")"
  else
    MNT_NAME=root MNT_SPEC="$REMOTE_PREFIX"
  fi
}

mount_preflight() {
  remote_configured || die "rclone remote '${RCLONE_REMOTE}' is not configured; run '${CLI_NAME} setup'"
  mount_derive_target "$MNT_FOLDER"
  if [[ -n "$MNT_FOLDER" ]]; then
    MNT_PATH="${MNT_MOUNTPOINT:-${MOUNT_ROOT}/${MNT_NAME}}"
  else
    MNT_PATH="${MNT_MOUNTPOINT:-$MOUNT_ROOT}"
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
# mount_filter_match FOLDER - non-zero (stop) for the entry whose remote
# subdir equals FOLDER, after printing its filter.
mount_filter_match() {
  [[ "${ENTRY_REMOTE:-}" == "$1" ]] || return 0
  printf '%s' "$ENTRY_FILTER"
  return 1
}

# mount_entry_filter - print the ENTRY_FILTER of the manifest entry whose
# remote subdir equals MNT_FOLDER (empty when there is no such entry).
mount_entry_filter() {
  [[ -n "$MNT_FOLDER" ]] || return 0
  # manifest.sh is lazy; load it for the entry walk below.
  sciebo_require_module manifest manifest_each
  manifest_each mount_filter_match "$MNT_FOLDER" || true
  return 0
}
build_mount_argv() {
  local pair_filter=""
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
  if [[ "$MOUNT_FILTERS" -eq 1 ]]; then
    [[ ! -f "${FILTER_DIR}/clutter.txt" ]] || MNT_ARGV+=(--filter-from "${FILTER_DIR}/clutter.txt")
    pair_filter="$(mount_entry_filter)"
    [[ -z "$pair_filter" || ! -f "${FILTER_DIR}/${pair_filter}" ]] || MNT_ARGV+=(--filter-from "${FILTER_DIR}/${pair_filter}")
  fi
  # .nosync support on a mount is best-effort: rclone accepts the flag for
  # nfsmount, but whether the marker hides a directory depends on the mount.
  [[ "$MOUNT_NO_SYNC" -ne 1 ]] || MNT_ARGV+=(--exclude-if-present .nosync)
}
run_mount_command() {
  local out="" rc=0
  if out="$("${MNT_ARGV[@]}" 2>&1)"; then
    MNT_TABLE_LOADED=0 MNT_TABLE=""
    return 0
  else
    rc=$?
    mount_failed "$out" "$rc"
  fi
}
record_state() {
  local i
  # Forkless captures for the three argv helpers (all only print): the pid
  # probe plus label_bool's yes/no word for the sudo flag.
  mount_state_write "$MNT_STATE" "$MNT_FOLDER" "$MNT_PATH" "${ find_mount_pid "$MNT_PATH";}" "${ label_bool "$MNT_SUDO" yes no;}"
  MNT_TABLE_LOADED=0 MNT_TABLE=""
  for i in 1 2 3 4 5; do
    if is_mounted "$MNT_PATH"; then break; fi
    sleep 1
    MNT_TABLE_LOADED=0 MNT_TABLE=""
  done
  is_mounted "$MNT_PATH" || warn "mount not visible in \`mount\` output yet"
}
run_foreground_mount() {
  local out="" rc=0
  # lock.sh is lazy; load it so the EXIT trap's release_lock below exists
  # exactly as when lock.sh was eager (this command never acquires a lock).
  sciebo_require_module lock release_lock
  MNT_ACTIVE_STATE="$MNT_STATE"
  # The command overrides the entrypoint's EXIT trap, so it must clean up
  # the registered temp files (netrc, response bodies) itself.
  trap 'rm -f "$MNT_ACTIVE_STATE"; release_lock; sciebo_temp_cleanup || true' EXIT
  mount_state_write "$MNT_STATE" "$MNT_FOLDER" "$MNT_PATH" - "$(label_bool "$MNT_SUDO" yes no)"
  log "Mounting ${MNT_SPEC} at ${MNT_PATH} (${MNT_MODE}, name=${MNT_NAME}) in the foreground; press Ctrl-C to unmount"
  if out="$("${MNT_ARGV[@]}" 2>&1)"; then
    printf 'Unmounted %s from %s\n' "$MNT_SPEC" "$MNT_PATH"
    return 0
  else
    rc=$?
    mount_failed "$out" "$rc"
  fi
}

cmd_mount() {
  opt_begin "folder:s mountpoint:s ro:b foreground:b sudo:b" mount "" "$@"
  opt_guard mount
  local folder=""
  folder="$(strip_trailing_slashes "${OPT_folder:-}")"
  [[ -z "$folder" ]] || safe_remote_path "$folder" || die "invalid remote folder: ${folder}"
  MNT_FOLDER="$folder"
  MNT_MOUNTPOINT="${OPT_mountpoint:-}"
  MNT_RO=false MNT_FOREGROUND=false MNT_SUDO=false
  opt_into MNT_RO ro
  opt_into MNT_FOREGROUND foreground
  opt_into MNT_SUDO sudo
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
  local folder="$1" mnt="$MOUNT_ROOT"
  folder="$(strip_trailing_slashes "$folder")"
  [[ -z "$folder" ]] || safe_remote_path "$folder" || die "invalid remote folder: ${folder}"
  mount_derive_target "$folder"
  [[ -z "$folder" ]] || mnt="${MOUNT_ROOT}/${MNT_NAME}"
  if [[ -f "${MOUNTS_DIR}/${MNT_NAME}.state" ]]; then
    mount_state_read "${MOUNTS_DIR}/${MNT_NAME}.state"
  else
    T_STATE="" T_NAME="$MNT_NAME" T_FOLDER="$folder" T_MNT="$mnt" T_PID="-" T_SUDO=no
  fi
}
resolve_mountpoint_target() {
  local state name
  name="$(sanitize_name "$(basename "$1")")"
  [[ -n "$name" ]] || name=mount
  while IFS= read -r state; do
    if mount_state_read "$state" && [[ "$T_MNT" == "$1" ]]; then return 0; fi
  done < <(mount_state_files)
  T_STATE="" T_NAME="$name" T_FOLDER="" T_MNT="$1" T_PID="-" T_SUDO=no
}

mount_do_umount() {
  local use_sudo="$1" rc=0
  if ! is_mounted "$T_MNT"; then
    log "${T_MNT}: not visible in mount output"
    return 0
  fi
  if [[ "$use_sudo" == true || "$T_SUDO" == yes ]]; then
    if ! have sudo; then
      err "sudo not found but required to unmount ${T_MNT}"
      rc=1
    elif ! sudo umount "$T_MNT"; then rc=1; fi
  elif ! umount "$T_MNT"; then rc=1; fi
  MNT_TABLE_LOADED=0 MNT_TABLE=""
  if [[ "$rc" -eq 0 ]]; then
    log "unmounted ${T_MNT}"
    return 0
  fi
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
  pid_alive "$pid" || return 0
  command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  if [[ "$command_line" != *nfsmount* || "$command_line" != *"$T_MNT"* ]]; then
    warn "not killing pid ${pid}: it is not the rclone nfsmount for ${T_MNT}"
    return 0
  fi
  kill "$pid" 2>/dev/null || true
  while pid_alive "$pid" && [[ "$i" -lt 3 ]]; do sleep 1 && i=$((i + 1)); done
  if pid_alive "$pid"; then
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
  opt_begin "folder:s mountpoint:s all:b sudo:b" umount "" "$@"
  opt_guard umount
  local picks="${OPT_folder_SET:-}${OPT_mountpoint_SET:-}${OPT_all_SET:-}" use_sudo=false
  [[ -n "$picks" ]] || usage_error umount "umount requires --folder, --mountpoint, or --all"
  [[ "${#picks}" -eq 1 ]] || usage_error umount "use only one of --folder, --mountpoint, --all"
  opt_into use_sudo sudo
  # Run dependency after the help/usage exits: stopping a recorded rclone
  # checks its liveness through lock.sh's pid_alive.
  sciebo_require_module lock pid_alive
  load_settings --no-rclone
  if [[ -n "${OPT_all_SET:-}" ]]; then umount_all "$use_sudo" && return 0 || return $?; fi
  if [[ -n "${OPT_folder_SET:-}" ]]; then resolve_folder_target "${OPT_folder}"; else resolve_mountpoint_target "${OPT_mountpoint}"; fi
  if [[ -z "$T_STATE" ]] && ! is_mounted "$T_MNT"; then printf '%s: not mounted\n' "$T_MNT"; fi
  [[ -n "$T_STATE" ]] || is_mounted "$T_MNT" || return 0
  umount_record "$use_sudo"
}

# mounts_classify MOUNTED ALIVE PID - true (0) when the record is unhealthy:
# the mountpoint is not visible, or a recorded pid is gone.
mounts_classify() {
  [[ "$1" == no || ("$3" != "-" && "$2" == no) ]]
}

# mounts_prunable MOUNTED ALIVE - true (0) when neither the mountpoint nor the
# recorded pid is present, so the state record is stale.
mounts_prunable() {
  [[ "$1" == no && "$2" == no ]]
}

# mounts_render_row NAME FOLDER MOUNTPOINT PID MOUNTED ALIVE - one table row,
# or one JSON object when --json is active.
mounts_render_row() {
  local name="$1" folder="$2" mnt="$3" pid="$4" mounted="$5" alive="$6"
  local mounted_json=false alive_json=false pid_json=null
  if output_json_enabled; then
    [[ "$mounted" != yes ]] || mounted_json=true
    [[ "$alive" != yes ]] || alive_json=true
    [[ ! "$pid" =~ ^[0-9]+$ ]] || pid_json="$pid"
    output_json_object_begin
    output_json_kv name "$name"
    output_json_kv folder "$folder"
    output_json_kv mountpoint "$mnt"
    output_json_kv_raw mounted "$mounted_json"
    output_json_kv_raw pid "$pid_json"
    output_json_kv_raw alive "$alive_json"
    output_json_object_end
  else
    printf '%s  %s  %s  mounted=%s  pid=%s  alive=%s\n' "$name" "${folder:-(base)}" "$mnt" "$mounted" "$pid" "$alive"
  fi
  return 0
}

cmd_mounts() {
  opt_begin "folder:s check:b prune:b json:b" mounts "" "$@"
  opt_guard mounts
  opt_json_mode
  # Run dependency after the help/usage exit: the per-record liveness check
  # is lock.sh's pid_alive (kill -0 plus the empty/non-numeric guard).
  sciebo_require_module lock pid_alive
  load_settings --no-rclone
  local only="" found=0 ok=0 unhealthy=0 state mounted alive
  local check=false prune=false prune_list="" prune_state=""
  [[ -z "${OPT_folder:-}" ]] || only="$(sanitize_name "$OPT_folder")"
  opt_into check check
  opt_into prune prune
  if output_json_enabled; then
    output_json_begin
    output_json_array_begin mounts
  fi
  while IFS= read -r state; do
    mount_state_read "$state"
    [[ -z "$only" || "$T_NAME" == "$only" ]] || continue
    found=$((found + 1))
    mounted=no alive=no
    is_mounted "$T_MNT" && mounted=yes
    pid_alive "$T_PID" && alive=yes
    mounts_render_row "$T_NAME" "$T_FOLDER" "$T_MNT" "$T_PID" "$mounted" "$alive"
    if mounts_classify "$mounted" "$alive" "$T_PID"; then
      unhealthy=$((unhealthy + 1))
    else
      ok=$((ok + 1))
    fi
    if mounts_prunable "$mounted" "$alive"; then
      prune_list="${prune_list}${state}"$'\n'
    fi
  done < <(mount_state_files)
  if output_json_enabled; then
    output_json_array_end
    output_json_end
  else
    [[ "$found" -gt 0 ]] || printf 'no rclone mounts recorded\n'
    if [[ "$check" == true ]]; then
      printf 'Summary: %s mount(s): %s ok, %s unhealthy\n' "$found" "$ok" "$unhealthy"
    fi
  fi
  if [[ "$prune" == true ]]; then
    while IFS= read -r prune_state; do
      [[ -n "$prune_state" ]] || continue
      if rm -f "$prune_state"; then
        output_json_enabled || printf 'removed state %s\n' "$prune_state"
      fi
    done <<<"$prune_list"
  fi
  if [[ "$check" == true && "$unhealthy" -gt 0 ]]; then return 1; fi
  return 0
}
