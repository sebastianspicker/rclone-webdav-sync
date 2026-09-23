#!/bin/bash
# edit.sh command module - download one file below a configured source, open
# it in an editor, and upload it again when the editor exits and the local
# copy changed. SUB resolves through the manifest exactly like hydrate (the
# first entry whose remote subdir equals SUB or is a parent of it); there is
# no FOLDERS_LOCAL_ROOT fallback because edit needs a known source. The run
# lock is held for the whole operation; --lock additionally takes a WebDAV
# lock by spawning `bin/sciebo lock`/`unlock` (commands never call each other
# in-process).

EDIT_LOCAL=""
EDIT_IS_DIR=false
EDIT_REMOTE_LOCKED=0
EDIT_EDITOR_ARGS=()

usage_edit() {
  usage_emit <<'EOF'
Usage: sciebo edit SUB [options]

Download one remote file on demand, open it in an editor, and upload it
again when it changed. SUB is resolved through the manifest: the first
entry whose remote_subdir equals SUB or is a parent of it wins (like
hydrate), and the local copy lives at that entry's local path. Unlike
hydrate there is no FOLDERS_LOCAL_ROOT fallback: edit needs a configured
source, and SUB must name a file, not a directory.

The editor is --editor CMD when given, else $EDITOR, else $VISUAL; CMD may
carry arguments (split on spaces, the file path is appended last). Without
any editor the platform opener (open on macOS, xdg-open on Linux) is used
and the upload is skipped, as if --no-upload had been given.

Options:
  --editor CMD   editor command, possibly with arguments
  --no-upload    do not upload after editing
  --lock         take a WebDAV lock while editing (released afterwards)
  -h, --help     show this help
EOF
}

# edit_resolve SUB - set EDIT_LOCAL from the first valid manifest entry whose
# remote subdir equals SUB or is a parent of it (the remaining relative path
# is appended to the entry's local path). Returns 1 without a match; unlike
# hydrate there is no FOLDERS_LOCAL_ROOT fallback, because edit needs a
# configured source to know where the local copy lives.
edit_resolve() {
  local sub="$1"
  EDIT_LOCAL=""
  # manifest.sh is lazy; load it for the entry lookup below.
  sciebo_require_module manifest manifest_resolve_local
  manifest_resolve_local "$sub" EDIT_LOCAL || return 1
  return 0
}

# edit_remote_stat SPEC - classify the remote path: sets EDIT_IS_DIR. Returns
# 1 when it cannot be inspected (missing path or rclone failure), so callers
# can tell "not found" from "is a directory".
edit_remote_stat() {
  local spec="$1" is_dir=0
  EDIT_IS_DIR=false
  rclone_stat_is_dir "$spec" is_dir || return 1
  [[ "$is_dir" -eq 0 ]] || EDIT_IS_DIR=true
  return 0
}

# edit_signature FILE - print "<mtime>:<size>". Both parts participate in the
# change check, so an editor that preserves the mtime (touch -r) but changes
# the size still counts as a change; an unreadable file produces a value that
# never compares equal to a readable one.
edit_signature() {
  local file="$1" mtime="" size=""
  mtime=${ file_mtime "$file";}
  size=${ file_size "$file";}
  printf '%s:%s' "$mtime" "$size"
}

# edit_open_path FILE - hand FILE to the platform opener (platform_opener
# picks `open` on macOS, `xdg-open` elsewhere). Returns 1 when neither exists
# (the caller dies with the editor hint) and 2 when the opener itself fails.
edit_open_path() {
  local file="$1" opener=""
  # platform.sh is lazy; load it for platform_opener below.
  sciebo_require_module platform platform_opener
  opener="$(platform_opener)"
  [[ -n "$opener" ]] || return 1
  "$opener" -- "$file" || return 2
  return 0
}

# edit_lock_remote SUB - take a WebDAV lock by spawning `bin/sciebo lock`
# (commands never call each other in-process). Dies when the child fails; the
# run lock is released by the entrypoint's EXIT trap either way.
edit_lock_remote() {
  local sub="$1" rc=0
  "${PROJECT_DIR}/bin/sciebo" lock "$sub" || rc=$?
  [[ "$rc" -eq 0 ]] || die "could not lock ${sub} (${CLI_NAME} lock exited ${rc})"
  EDIT_REMOTE_LOCKED=1
  return 0
}

# edit_unlock_remote SUB - release the WebDAV lock via `bin/sciebo unlock`
# (spawned like lock). Best effort: a failure is warned about but never masks
# the edit result.
edit_unlock_remote() {
  local sub="$1" rc=0
  [[ "$EDIT_REMOTE_LOCKED" -eq 1 ]] || return 0
  EDIT_REMOTE_LOCKED=0
  "${PROJECT_DIR}/bin/sciebo" unlock "$sub" || rc=$?
  [[ "$rc" -eq 0 ]] ||
    warn "could not release the WebDAV lock on ${sub} (${CLI_NAME} unlock exited ${rc}); run '${CLI_NAME} unlock ${sub}' to retry"
  return 0
}

# edit_parse_args ARGS... - parse the edit options and validate SUB (single,
# non-empty, relative). Sets EDIT_SUB, EDIT_NO_UPLOAD and EDIT_LOCK_REMOTE;
# usage_error/die exactly like the old inline prologue.
edit_parse_args() {
  local sub=""
  opt_begin "editor:s no-upload:b lock:b" edit "" "$@"
  # Count and emptiness through the shared positional rules; path safety
  # stays with require_safe_remote_path afterwards.
  opt_require_sub edit "SUB" "${OPT_EXTRA:-}"
  sub="${POSITIONAL_ARGS[0]:-}"
  sub=${ strip_trailing_slashes "$sub";}
  [[ -n "$sub" ]] || usage_error edit "SUB is required"
  require_safe_remote_path "$sub"
  EDIT_SUB="$sub"
  EDIT_NO_UPLOAD=false
  opt_into EDIT_NO_UPLOAD no_upload
  EDIT_LOCK_REMOTE=false
  opt_into EDIT_LOCK_REMOTE lock
}

# edit_prepare_target - resolve EDIT_SUB through the manifest, classify the
# remote, take the run lock, and download the file (plus the WebDAV lock when
# requested). Sets EDIT_LOCAL_FILE and EDIT_REMOTE. Dies on the same errors
# as the old inline prologue, before any editor is opened.
edit_prepare_target() {
  # lock.sh is lazy; load it before acquire_lock below so the EXIT trap's
  # release_lock exists too.
  sciebo_require_module lock acquire_lock
  load_settings
  require_remote
  edit_resolve "$EDIT_SUB" ||
    die "no manifest entry covers '${EDIT_SUB}'; edit needs a configured source (run '${CLI_NAME} list' or '${CLI_NAME} folders add')"
  EDIT_LOCAL_FILE="$EDIT_LOCAL"
  [[ -n "$EDIT_LOCAL_FILE" ]] || die "cannot resolve a local path for '${EDIT_SUB}'"
  EDIT_REMOTE=${ remote_spec "$EDIT_SUB";}
  edit_remote_stat "$EDIT_REMOTE" || die "remote path not found: ${EDIT_REMOTE}"
  if [[ "$EDIT_IS_DIR" == true ]]; then
    die "remote path is a directory (edit works on single files): ${EDIT_REMOTE}"
  fi
  acquire_lock
  rclone_cmd copyto "$EDIT_REMOTE" "$EDIT_LOCAL_FILE" ||
    die "rclone copy failed (exit $?) for ${EDIT_SUB}"
  if [[ "$EDIT_LOCK_REMOTE" == true ]]; then
    edit_lock_remote "$EDIT_SUB"
  fi
}

# edit_editor_command - print the editor command from --editor, $EDITOR, or
# $VISUAL (first non-empty); nothing when none is configured.
edit_editor_command() {
  local editor_cmd="${OPT_editor:-}"
  [[ -n "$editor_cmd" ]] || editor_cmd="${EDITOR:-}"
  [[ -n "$editor_cmd" ]] || editor_cmd="${VISUAL:-}"
  printf '%s' "$editor_cmd"
}

# edit_run_editor SUB LOCAL_FILE EDITOR_CMD - run EDITOR_CMD (split on spaces,
# LOCAL_FILE appended last). Warns without dying when the editor exits
# nonzero and dies when it removed LOCAL_FILE. Sets EDIT_EDITOR_RC.
edit_run_editor() {
  local sub="$1" local_file="$2" editor_cmd="$3"
  EDIT_EDITOR_RC=0
  EDIT_EDITOR_ARGS=()
  read -r -a EDIT_EDITOR_ARGS <<<"$editor_cmd"
  [[ "${#EDIT_EDITOR_ARGS[@]}" -gt 0 ]] || EDIT_EDITOR_ARGS=("$editor_cmd")
  "${EDIT_EDITOR_ARGS[@]}" "$local_file" || EDIT_EDITOR_RC=$?
  if [[ "$EDIT_EDITOR_RC" -ne 0 ]]; then
    warn "editor exited with status ${EDIT_EDITOR_RC}; still checking for changes"
  fi
  if [[ ! -f "$local_file" ]]; then
    edit_unlock_remote "$sub"
    die "editor removed ${local_file}; nothing to upload"
  fi
}

# edit_upload SUB LOCAL_FILE REMOTE BEFORE NO_UPLOAD - compare BEFORE against
# the file's current signature and upload when it changed, unless NO_UPLOAD.
# Sets EDIT_UPLOAD_RC to the rclone status (0 when no upload was attempted).
edit_upload() {
  local sub="$1" local_file="$2" remote="$3" before="$4" no_upload="$5" after=""
  EDIT_UPLOAD_RC=0
  after="$(edit_signature "$local_file")"
  if [[ "$before" == "$after" ]]; then
    printf 'edit: %s unchanged, not uploaded\n' "$sub"
  elif [[ "$no_upload" == true ]]; then
    printf 'edit: %s changed, not uploaded (--no-upload)\n' "$sub"
  else
    rclone_cmd copyto "$local_file" "$remote" || EDIT_UPLOAD_RC=$?
    [[ "$EDIT_UPLOAD_RC" -ne 0 ]] || printf 'edit: uploaded %s\n' "$sub"
  fi
}

# edit_run ARGS - the actual top-level `edit` implementation. cmd_edit is a
# thin dispatcher so it can be reinstalled after the glob-sourced modules
# loaded (see edit_claim_dispatch below).
edit_run() {
  local editor_cmd="" signature_before="" open_rc=0
  edit_parse_args "$@"
  edit_prepare_target
  editor_cmd="$(edit_editor_command)"
  if [[ -z "$editor_cmd" ]]; then
    # No editor to wait for: the opener returns as soon as the file is
    # handed over, so the changes cannot be uploaded reliably.
    open_rc=0
    edit_open_path "$EDIT_LOCAL_FILE" || open_rc=$?
    if [[ "$open_rc" -ne 0 ]]; then
      edit_unlock_remote "$EDIT_SUB"
      if [[ "$open_rc" -eq 1 ]]; then
        die "no editor configured: pass --editor CMD or set \$EDITOR (e.g. '${CLI_NAME} edit ${EDIT_SUB} --editor vim')"
      fi
      die "cannot open ${EDIT_LOCAL_FILE} with the platform opener"
    fi
    printf "edit: opened %s with the platform opener; no editor configured, so the upload is skipped (pass --editor CMD or set \$EDITOR)\n" \
      "$EDIT_LOCAL_FILE"
    edit_unlock_remote "$EDIT_SUB"
    return 0
  fi
  signature_before="$(edit_signature "$EDIT_LOCAL_FILE")"
  edit_run_editor "$EDIT_SUB" "$EDIT_LOCAL_FILE" "$editor_cmd"
  edit_upload "$EDIT_SUB" "$EDIT_LOCAL_FILE" "$EDIT_REMOTE" "$signature_before" "$EDIT_NO_UPLOAD"
  edit_unlock_remote "$EDIT_SUB"
  [[ "$EDIT_UPLOAD_RC" -eq 0 ]] || die "rclone upload failed (exit ${EDIT_UPLOAD_RC}) for ${EDIT_SUB}"
  return 0
}

cmd_edit() { edit_run "$@"; }
