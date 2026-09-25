#!/usr/bin/env bash
# edit.sh - `sciebo edit`: manifest resolution, the download/edit/upload
# round trip, change detection (mtime+size), editor fallback, and --lock
# (spawned `sciebo lock`/`unlock`; the success path runs against the fake
# Nextcloud).
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

# A local tree behind a real rclone remote (same pattern as hydrate.sh). The
# local backend has no root option, so an alias remote points rclone at it.
REMOTE_ROOT="${TMP}/remote"
mkdir -p "${REMOTE_ROOT}/backup/notes"
printf 'original\n' >"${REMOTE_ROOT}/backup/notes/plan.txt"
rclone config create edittest alias remote="$REMOTE_ROOT" --config "$RCLONE_CONFIG" >/dev/null 2>&1 || {
  echo "SKIP: cannot create temporary alias remote"
  finish
}
export RCLONE_REMOTE=edittest

# The manifest entry owns the local destination.
printf 'pull|%s|notes\n' "${TMP}/local" >"$MANIFEST_FILE"

EDITOR_STUB="${TMP}/stub-editor"
cat >"$EDITOR_STUB" <<'STUB'
#!/bin/bash
printf 'edited line\n' >>"$1"
STUB
chmod +x "$EDITOR_STUB"

# An editor that changes the size but restores the mtime afterwards.
KEEP_MTIME_EDITOR="${TMP}/stub-editor-keep-mtime"
cat >"$KEEP_MTIME_EDITOR" <<'STUB'
#!/bin/bash
file="$1"
cp -p "$file" "${file}.mtime-ref"
printf 'a longer replacement payload than before\n' >"$file"
touch -r "${file}.mtime-ref" "$file"
rm -f "${file}.mtime-ref"
STUB
chmod +x "$KEEP_MTIME_EDITOR"

reset_remote_file() {
  printf 'original\n' >"${REMOTE_ROOT}/backup/notes/plan.txt"
  rm -rf "${TMP}/local"
}

# --- download, edit, upload --------------------------------------------------
expect_cli "edit: rc 0" 0 run_cli edit notes/plan.txt --editor "$EDITOR_STUB"
expect_contains "edit: reports the upload" "$CLI_OUT" "uploaded notes/plan.txt"
expect_contains "edit: local copy edited" "$(cat "${TMP}/local/plan.txt")" "edited line"
expect_contains "edit: remote changed" "$(cat "${REMOTE_ROOT}/backup/notes/plan.txt")" "edited line"
expect_file "edit: local copy kept" "${TMP}/local/plan.txt"

# --- --no-upload: the editor runs, the remote stays untouched ----------------
reset_remote_file
expect_cli "edit: --no-upload rc 0" 0 run_cli edit notes/plan.txt --no-upload --editor "$EDITOR_STUB"
expect_contains "edit: --no-upload local edited" "$(cat "${TMP}/local/plan.txt")" "edited line"
expect_contains "edit: --no-upload reported" "$CLI_OUT" "--no-upload"
expect_eq "edit: --no-upload remote unchanged" "original" "$(cat "${REMOTE_ROOT}/backup/notes/plan.txt")"

# --- a size change is detected even when the editor preserves the mtime ------
reset_remote_file
expect_cli "edit: mtime-preserving editor rc 0" 0 run_cli edit notes/plan.txt --editor "$KEEP_MTIME_EDITOR"
expect_contains "edit: size change still uploads" "$CLI_OUT" "uploaded notes/plan.txt"
expect_contains "edit: replacement uploaded" "$(cat "${REMOTE_ROOT}/backup/notes/plan.txt")" "longer replacement"

# --- an editor that changes nothing leaves the remote alone ------------------
reset_remote_file
NOOP_EDITOR="${TMP}/stub-editor-noop"
printf '#!/bin/bash\nexit 0\n' >"$NOOP_EDITOR"
chmod +x "$NOOP_EDITOR"
expect_cli "edit: unchanged rc 0" 0 run_cli edit notes/plan.txt --editor "$NOOP_EDITOR"
expect_contains "edit: unchanged reported" "$CLI_OUT" "unchanged, not uploaded"
expect_eq "edit: unchanged remote" "original" "$(cat "${REMOTE_ROOT}/backup/notes/plan.txt")"

# --- a failing editor warns but its changes are still uploaded ---------------
reset_remote_file
FAIL_EDITOR="${TMP}/stub-editor-fail"
cat >"$FAIL_EDITOR" <<'STUB'
#!/bin/bash
printf 'edited after warning\n' >>"$1"
exit 3
STUB
chmod +x "$FAIL_EDITOR"
expect_cli "edit: failing editor rc 0" 0 run_cli edit notes/plan.txt --editor "$FAIL_EDITOR"
expect_contains "edit: failing editor warned" "$CLI_OUT" "editor exited with status 3"
expect_contains "edit: failing editor uploaded" "$CLI_OUT" "uploaded notes/plan.txt"
expect_contains "edit: failing editor remote changed" "$(cat "${REMOTE_ROOT}/backup/notes/plan.txt")" "edited after warning"

# --- $EDITOR and $VISUAL are used when --editor is absent --------------------
reset_remote_file
CLI_OUT="$(cd "$TMP" && env EDITOR="$EDITOR_STUB" VISUAL="$KEEP_MTIME_EDITOR" RCLONE_REMOTE=edittest \
  bash "${PROJ}/bin/sciebo" edit notes/plan.txt 2>&1)"
CLI_RC=$?
expect_rc "edit: \$EDITOR fallback rc 0" "$CLI_RC" 0
expect_contains "edit: \$EDITOR wins over \$VISUAL" "$(cat "${REMOTE_ROOT}/backup/notes/plan.txt")" "edited line"

VISUAL_STUB="${TMP}/stub-editor-visual"
cat >"$VISUAL_STUB" <<'STUB'
#!/bin/bash
printf 'visual line\n' >>"$1"
STUB
chmod +x "$VISUAL_STUB"
reset_remote_file
CLI_OUT="$(cd "$TMP" && env -u EDITOR VISUAL="$VISUAL_STUB" RCLONE_REMOTE=edittest \
  bash "${PROJ}/bin/sciebo" edit notes/plan.txt 2>&1)"
CLI_RC=$?
expect_rc "edit: \$VISUAL fallback rc 0" "$CLI_RC" 0
expect_contains "edit: \$VISUAL used" "$(cat "${REMOTE_ROOT}/backup/notes/plan.txt")" "visual line"

# --- --editor arguments are split on spaces and the file is appended --------
reset_remote_file
EDITOR_ARGS_LOG="${TMP}/editor-args.log"
ARGS_EDITOR="${TMP}/stub-editor-args"
cat >"$ARGS_EDITOR" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >>"${EDITOR_ARGS_LOG}"
printf 'args-edited\n' >>"\${@: -1}"
STUB
chmod +x "$ARGS_EDITOR"
expect_cli "edit: --editor with arguments rc 0" 0 run_cli edit notes/plan.txt --editor "${ARGS_EDITOR} --wait"
expect_contains "edit: argument passed through" "$(cat "$EDITOR_ARGS_LOG")" "--wait"
expect_contains "edit: file appended last" "$(cat "$EDITOR_ARGS_LOG")" "${TMP}/local/plan.txt"
expect_contains "edit: argument editor uploaded" "$(cat "${REMOTE_ROOT}/backup/notes/plan.txt")" "args-edited"

# --- argument and resolution errors ------------------------------------------
expect_cli "edit: unknown SUB rc 1" 1 run_cli edit nosuch/file.txt --editor "$EDITOR_STUB"
expect_contains "edit: unknown SUB message" "$CLI_OUT" "no manifest entry covers"
expect_cli "edit: directory rc 1" 1 run_cli edit notes --editor "$EDITOR_STUB"
expect_contains "edit: directory message" "$CLI_OUT" "is a directory"
expect_cli "edit: missing remote file rc 1" 1 run_cli edit notes/missing.txt --editor "$EDITOR_STUB"
expect_contains "edit: missing remote message" "$CLI_OUT" "remote path not found"
expect_cli "edit: unsafe path rc 1" 1 run_cli edit ../evil --editor "$EDITOR_STUB"
expect_contains "edit: unsafe path message" "$CLI_OUT" "unsafe remote path"
expect_cli "edit: missing SUB rc 2" 2 run_cli edit
expect_contains "edit: missing SUB message" "$CLI_OUT" "SUB is required"

# --- --lock on a non-Nextcloud remote fails before the editor runs -----------
reset_remote_file
expect_cli "edit: --lock needs a Nextcloud remote" 1 run_cli edit notes/plan.txt --editor "$EDITOR_STUB" --lock
expect_contains "edit: --lock failure reported" "$CLI_OUT" "could not lock notes/plan.txt"
expect_no_file "edit: --lock failure records nothing" "${TMP}/state/remote-locks/notes_plan.txt.state"

# --- without an editor the platform opener is used and no upload happens -----
unset EDITOR VISUAL
OPENER_BIN="${TMP}/opener-bin"
OPENER_LOG="${OPENER_BIN}/calls.log"
mkdir -p "$OPENER_BIN"
for opener in open xdg-open; do
  cat >"${OPENER_BIN}/${opener}" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$(dirname "$0")/calls.log"
exit 0
STUB
  chmod +x "${OPENER_BIN}/${opener}"
done
reset_remote_file
CLI_OUT="$(cd "$TMP" && env -u EDITOR -u VISUAL PATH="${OPENER_BIN}:${PATH}" RCLONE_REMOTE=edittest \
  bash "${PROJ}/bin/sciebo" edit notes/plan.txt 2>&1)"
CLI_RC=$?
expect_rc "edit: opener fallback rc 0" "$CLI_RC" 0
expect_contains "edit: opener fallback note" "$CLI_OUT" "platform opener"
expect_contains "edit: opener fallback skips upload" "$CLI_OUT" "skipped"
expect_contains "edit: opener received the local file" "$(cat "$OPENER_LOG" 2>/dev/null)" "${TMP}/local/plan.txt"
expect_eq "edit: opener fallback remote unchanged" "original" "$(cat "${REMOTE_ROOT}/backup/notes/plan.txt")"

# --- without an editor and without an opener the command dies ----------------
NO_OPENER_BIN="${TMP}/no-opener-bin"
RCLONE_REAL="$(command -v rclone)"
mkdir -p "$NO_OPENER_BIN"
old_ifs="$IFS"
IFS=:
for dir in $PATH; do
  [ -d "$dir" ] || continue
  find "$dir" -maxdepth 1 \( -type f -o -type l \) -perm -u+x ! -name open ! -name xdg-open \
    -exec sh -c 'dest="$1"; shift; for f in "$@"; do ln -sf "$f" "$dest/"; done' sh "$NO_OPENER_BIN" {} + 2>/dev/null
done
IFS="$old_ifs"
reset_remote_file
CLI_OUT="$(cd "$TMP" && env -u EDITOR -u VISUAL PATH="${NO_OPENER_BIN}" RCLONE_BIN="$RCLONE_REAL" \
  RCLONE_REMOTE=edittest "$BASH" "${PROJ}/bin/sciebo" edit notes/plan.txt 2>&1)"
CLI_RC=$?
expect_rc "edit: no editor and no opener rc 1" "$CLI_RC" 1
expect_contains "edit: no editor hint" "$CLI_OUT" "no editor configured"
expect_contains "edit: no editor hint names --editor" "$CLI_OUT" "--editor"

# --- --lock success against the fake Nextcloud --------------------------------
if command -v python3 >/dev/null 2>&1; then
  # shellcheck source-path=SCRIPTDIR
  # shellcheck source=../fake_env.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../fake_env.sh"
  if fake_server_start; then
    printf 'lock me\n' >"${TMP}/lock-src.txt"
    fake_curl -fsS -u "${FAKE_USER}:${FAKE_PASSWORD}" -X PUT \
      --data-binary "@${TMP}/lock-src.txt" \
      "${FAKE_BASE}/remote.php/dav/files/${FAKE_USER}/backup/notes/plan.txt" >/dev/null
    printf 'pull|%s|notes\n' "${TMP}/lock-local" >"$MANIFEST_FILE"
    rm -rf "${TMP}/lock-local"
    expect_cli "edit --lock: rc 0" 0 fake_cli edit notes/plan.txt --editor "$EDITOR_STUB" --lock
    expect_contains "edit --lock: locked" "$CLI_OUT" "locked notes/plan.txt"
    expect_contains "edit --lock: uploaded" "$CLI_OUT" "uploaded notes/plan.txt"
    expect_contains "edit --lock: unlocked" "$CLI_OUT" "unlocked notes/plan.txt"
    expect_no_file "edit --lock: record removed" "${TMP}/state/remote-locks/notes_plan.txt.state"
    expect_contains "edit --lock: remote edited" \
      "$(fake_curl -fsS -u "${FAKE_USER}:${FAKE_PASSWORD}" \
        "${FAKE_BASE}/remote.php/dav/files/${FAKE_USER}/backup/notes/plan.txt")" "edited line"

    expect_cli "edit --lock --no-upload: rc 0" 0 fake_cli edit notes/plan.txt --editor "$EDITOR_STUB" --lock --no-upload
    expect_contains "edit --lock --no-upload: locked" "$CLI_OUT" "locked notes/plan.txt"
    expect_contains "edit --lock --no-upload: unlocked" "$CLI_OUT" "unlocked notes/plan.txt"
    expect_contains "edit --lock --no-upload: upload skipped" "$CLI_OUT" "--no-upload"
    expect_no_file "edit --lock --no-upload: record removed" "${TMP}/state/remote-locks/notes_plan.txt.state"
  else
    echo "SKIP: fake server unavailable; edit --lock success path not exercised"
  fi
else
  echo "SKIP: python3 not installed; edit --lock success path not exercised"
fi

finish
