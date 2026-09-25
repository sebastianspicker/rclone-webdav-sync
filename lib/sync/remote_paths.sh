#!/bin/bash
# remote_paths.sh - the shared E2EE/external-storage remote-path policy
# engine (policy_remote_paths_apply and its helpers), used by sync, doctor,
# and the folder wizard through the ask-policy callback contract described
# on policy_remote_paths_apply below. Split out of lib/sync/policy.sh.

# _policy_remote_emit SINK MESSAGE - record MESSAGE in POLICY_REMOTE_MESSAGE
# and hand it to SINK (default warn). A caller that only collects state sets
# POLICY_REMOTE_SINK=: to stay silent.
_policy_remote_emit() {
  POLICY_REMOTE_MESSAGE="${2:-}"
  "${1:-warn}" "$POLICY_REMOTE_MESSAGE"
}

# _policy_remote_list_has LIST ITEM - true when the newline-separated LIST
# contains ITEM as one whole entry.
_policy_remote_list_has() {
  local list=$'\n'"$1"$'\n' item="${2:-}"
  [[ -n "$item" ]] || return 1
  [[ "$list" == *$'\n'"${item}"$'\n'* ]]
}

# _policy_remote_scope_find PROBE SUB - print SUB when PROBE reports it, else
# its immediate parent when PROBE reports that; rc 1 when neither is
# reported. The wizard gates use this parent-aware lookup so a chosen folder
# is still gated when only its parent is encrypted/mounted.
_policy_remote_scope_find() {
  local probe="$1" sub="$2" parent="" paths=""
  paths=${ "$probe" "$sub" 2>/dev/null;} || paths=""
  if _policy_remote_list_has "$paths" "$sub"; then
    printf '%s' "$sub"
    return 0
  fi
  parent="${sub%/*}"
  [[ "$parent" != "$sub" && -n "$parent" ]] || return 1
  paths=${ "$probe" "$parent" 2>/dev/null;} || paths=""
  _policy_remote_list_has "$paths" "$parent" || return 1
  printf '%s' "$parent"
  return 0
}

# _policy_remote_confirm KIND - true when the caller's POLICY_REMOTE_CONFIRM
# callback (if any) confirms the interactive ask; an unset callback is a
# "no", which is how a non-interactive caller turns ask into skip.
_policy_remote_confirm() {
  [[ -n "${POLICY_REMOTE_CONFIRM:-}" ]] || return 1
  "$POLICY_REMOTE_CONFIRM" "${1:-}"
}

# _policy_remote_set_checked NAME COUNT - store COUNT in the variable named by
# NAME (the engine's CHECKED_VAR contract); a blank NAME is a no-op so the
# wizard can share the skip helper without touching the caller's bookkeeping.
_policy_remote_set_checked() {
  [[ -n "${1:-}" ]] || return 0
  printf -v "$1" '%s' "${2:-0}"
}

# _policy_remote_skip CHECKED_NAME REASON MESSAGE - emit MESSAGE through the
# active sink when given, mark the engine as skipping with REASON, store
# POLICY_REMOTE_COUNT in CHECKED_NAME, and return 2 (the engine's skip code).
_policy_remote_skip() {
  local checked_name="${1:-}" reason="${2:-}" message="${3:-}"
  [[ -n "$message" ]] && _policy_remote_emit "${POLICY_REMOTE_SINK:-warn}" "$message"
  POLICY_REMOTE_RESULT=skip
  POLICY_REMOTE_SKIP_REASON="$reason"
  _policy_remote_set_checked "$checked_name" "$POLICY_REMOTE_COUNT"
  return 2
}

# _policy_remote_collect_paths PROBE ROOT - list ROOT with PROBE, drop blanks
# and trailing slashes, and accumulate the reported paths into
# POLICY_REMOTE_COUNT, the newline-joined POLICY_REMOTE_PATHS, and
# POLICY_REMOTE_LAST_PATH.
_policy_remote_collect_paths() {
  local probe="$1" root="$2" paths="" path=""
  paths=${ "$probe" "$root" 2>/dev/null;} || paths=""
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    path="${path%/}"
    POLICY_REMOTE_COUNT=$((POLICY_REMOTE_COUNT + 1))
    POLICY_REMOTE_PATHS="${POLICY_REMOTE_PATHS}${POLICY_REMOTE_PATHS:+$'\n'}${path}"
    POLICY_REMOTE_LAST_PATH="$path"
  done <<<"$paths"
}

# _policy_remote_wizard KIND POLICY SUB SCOPE SINK - wizard verdict for a
# chosen folder reported by the shared probe; returns 0 to keep the pair, 2 to
# skip it. KIND is e2ee or external and selects the wording and policy
# variable.
_policy_remote_wizard() {
  local kind="$1" policy="$2" sub="$3" scope="$4" sink="$5" confirmed=0
  local prefix="" var="" detail="" reason_detail=""
  case "$kind" in
    e2ee)
      prefix="e2ee"
      var="E2EE_POLICY"
      detail="is end-to-end encrypted (${scope}); sciebo cannot decrypt E2EE folders"
      reason_detail="is end-to-end encrypted (${scope})"
      ;;
    *)
      prefix="external storage"
      var="EXTERNAL_STORAGE_POLICY"
      detail="is on mounted external storage"
      reason_detail="on mounted external storage"
      ;;
  esac
  if [[ "$policy" == "ask" ]] && _policy_remote_confirm "$kind"; then
    confirmed=1
  fi
  if ! choose_policy_decision "$policy" "$confirmed" >/dev/null; then
    _policy_remote_skip "" "${prefix}: '$(printable "$sub")' ${reason_detail} (${var}=${policy})" \
      "${prefix}: '$(printable "$sub")' ${detail}; skipping (${var}=${policy})"
    return 2
  fi
  if [[ "$policy" == "ask" ]]; then
    _policy_remote_emit "$sink" "${prefix}: '$(printable "$sub")' accepted (${var}=ask)"
  elif [[ "$policy" == "warn" ]]; then
    _policy_remote_emit "$sink" "${prefix}: '$(printable "$sub")' ${detail}; adding anyway (${var}=warn)"
  fi
  return 0
}

# _policy_remote_wizard_e2ee POLICY SUB SCOPE SINK - E2EE wording wrapper.
_policy_remote_wizard_e2ee() {
  _policy_remote_wizard e2ee "$1" "$2" "$3" "$4"
}

# _policy_remote_wizard_external POLICY SUB SCOPE SINK - external wording
# wrapper.
_policy_remote_wizard_external() {
  _policy_remote_wizard external "$1" "$2" "$3" "$4"
}

# policy_remote_paths_apply POLICY PROBE KIND OUT_EXCLUDES_NAME CHECKED_VAR
#
# The one shared E2EE / server-mounted external-storage gate behind the sync
# preflights, `doctor`, and the folder wizard. POLICY is the effective
# setting (E2EE_POLICY/EXTERNAL_STORAGE_POLICY), PROBE is the path-listing
# callback (nc_e2ee_paths/nc_external_paths), KIND is e2ee or external,
# OUT_EXCLUDES_NAME names an argv array that receives one rclone --exclude
# pattern per encrypted subfolder, and CHECKED_VAR names the variable that
# receives the number of reported paths evaluated.
#
# The external signature is deliberately byte-stable: all three call
# sites - sync.sh, doctor.sh, and folders.sh's wizard - plus the policy
# suite pass these same five positionals. On entry they are folded into
# the POLICY_REMOTE_* globals, so POLICY_REMOTE_* is the single read
# channel for both input paths (see the input note in the function).
#
# The caller supplies the context through globals:
#   POLICY_REMOTE_ROOT         remote path the probe is queried with
#                              (apply/collect); the candidate folder
#                              (wizard)
#   POLICY_REMOTE_NAME         entry label used by apply messages
#   POLICY_REMOTE_STYLE        apply (default), wizard, or collect
#   POLICY_REMOTE_SCOPE_SEARCH 1 to match the candidate or its parent
#                              instead of enumerating the tree (wizard)
#   POLICY_REMOTE_CONFIRM      optional callback run for an ask policy; it
#                              must return 0 for a confirmed answer
#   POLICY_REMOTE_SINK         message sink (default warn; : silences)
#
# It sets POLICY_REMOTE_COUNT, POLICY_REMOTE_PATHS (newline-joined reported
# paths), POLICY_REMOTE_LAST_PATH/LAST_SUB/LAST_SCOPE, POLICY_REMOTE_RESULT
# (proceed/skip), POLICY_REMOTE_SKIP_REASON, and POLICY_REMOTE_MESSAGE, so
# every caller can phrase its own report from the shared state. Returns 0 to
# proceed and 2 to skip (an E2EE remote root, or external ask without a
# confirmation). allow, a missing probe, and a non-Nextcloud remote are
# silent no-ops; collect style only records what the probe reports (doctor
# still lists encrypted folders under allow).
policy_remote_paths_apply() {
  # Input contract, one section, fed by both channels: the five
  # positionals keep their external byte-stable signature but are copied
  # into POLICY_REMOTE_POLICY/PROBE/KIND/OUT_EXCLUDES/CHECKED_VAR on
  # entry, and the caller-preset context below already arrives through
  # POLICY_REMOTE_* globals. Every read afterwards (here and in the
  # style-specific engine calls) uses the locals initialized from that
  # one section, instead of mixing $1..$5 with the globals.
  POLICY_REMOTE_POLICY="${1:-}"
  POLICY_REMOTE_PROBE="${2:-}"
  POLICY_REMOTE_KIND="${3:-}"
  POLICY_REMOTE_OUT_EXCLUDES="${4:-}"
  POLICY_REMOTE_CHECKED_VAR="${5:-}"
  local policy="$POLICY_REMOTE_POLICY" probe="$POLICY_REMOTE_PROBE"
  local kind="$POLICY_REMOTE_KIND" out_name="$POLICY_REMOTE_OUT_EXCLUDES"
  local checked_name="$POLICY_REMOTE_CHECKED_VAR"
  local style="${POLICY_REMOTE_STYLE:-apply}" root="${POLICY_REMOTE_ROOT:-}"
  local sink="${POLICY_REMOTE_SINK:-warn}" name="${POLICY_REMOTE_NAME:-}"
  local scope_search="${POLICY_REMOTE_SCOPE_SEARCH:-0}"

  # Output contract: every call resets these before the gate runs, so a
  # caller can phrase its own report from the shared state.
  POLICY_REMOTE_COUNT=0
  POLICY_REMOTE_PATHS=""
  POLICY_REMOTE_LAST_PATH=""
  POLICY_REMOTE_LAST_SUB=""
  POLICY_REMOTE_LAST_SCOPE=""
  POLICY_REMOTE_RESULT=proceed
  POLICY_REMOTE_SKIP_REASON=""
  POLICY_REMOTE_MESSAGE=""
  # POLICY_REMOTE_* globals are the engine's output contract; this keeps the
  # assignments below visible to shellcheck (callers read them by name).
  : "${POLICY_REMOTE_LAST_PATH}" "${POLICY_REMOTE_LAST_SUB}" \
    "${POLICY_REMOTE_LAST_SCOPE}" "${POLICY_REMOTE_RESULT}" "${POLICY_REMOTE_SKIP_REASON}"

  if [[ "$style" != "collect" && "$policy" == "allow" ]]; then
    _policy_remote_set_checked "$checked_name" 0
    return 0
  fi
  type -t "$probe" >/dev/null 2>&1 || {
    _policy_remote_set_checked "$checked_name" 0
    return 0
  }
  if [[ "$style" != "collect" ]] && ! remote_is_nextcloud; then
    _policy_remote_set_checked "$checked_name" 0
    return 0
  fi

  if [[ "$style" == "collect" ]]; then
    _policy_remote_run_collect "$probe" "$root" "$checked_name"
    return 0
  fi

  if [[ "$scope_search" == "1" ]]; then
    _policy_remote_run_wizard "$policy" "$probe" "$kind" "$root" "$sink" "$checked_name"
    return $?
  fi

  _policy_remote_run_apply "$policy" "$probe" "$kind" "$out_name" "$checked_name" \
    "$root" "$name" "$sink"
  return $?
}

# _policy_remote_run_collect PROBE ROOT CHECKED_NAME - collect style: list
# ROOT with PROBE and record the reported paths for the caller (doctor).
_policy_remote_run_collect() {
  local probe="$1" root="$2" checked_name="$3"
  _policy_remote_collect_paths "$probe" "$root"
  _policy_remote_set_checked "$checked_name" "$POLICY_REMOTE_COUNT"
  return 0
}

# _policy_remote_run_wizard POLICY PROBE KIND ROOT SINK CHECKED_NAME - wizard
# style: match the candidate ROOT or its parent (POLICY_REMOTE_SCOPE_SEARCH is
# set by the caller) and apply the kind's gate; rc 0 to keep the pair and 2 to
# skip it.
_policy_remote_run_wizard() {
  local policy="$1" probe="$2" kind="$3" root="$4" sink="$5" checked_name="$6"
  local scope=""
  scope=${ _policy_remote_scope_find "$probe" "$root";} || scope=""
  [[ -n "$scope" ]] || {
    _policy_remote_set_checked "$checked_name" 0
    return 0
  }
  POLICY_REMOTE_COUNT=1
  POLICY_REMOTE_PATHS="$scope"
  POLICY_REMOTE_LAST_PATH="$scope"
  POLICY_REMOTE_LAST_SUB="$root"
  POLICY_REMOTE_LAST_SCOPE="$scope"
  _policy_remote_set_checked "$checked_name" "$POLICY_REMOTE_COUNT"
  case "$kind" in
    e2ee) _policy_remote_wizard_e2ee "$policy" "$root" "$scope" "$sink" ;;
    *) _policy_remote_wizard_external "$policy" "$root" "$scope" "$sink" ;;
  esac
  return $?
}

# _policy_remote_run_apply POLICY PROBE KIND OUT_EXCLUDES_NAME CHECKED_VAR ROOT
# NAME SINK - apply style: enumerate ROOT and walk the reported paths in order
# through _policy_remote_apply_path. rc 0 to proceed and 2 to skip.
_policy_remote_run_apply() {
  local policy="$1" probe="$2" kind="$3" out_name="$4" checked_name="$5"
  local root="$6" name="$7" sink="$8"
  local path="" seen=0 rc=0
  _policy_remote_collect_paths "$probe" "$root"
  root="${root%/}"
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    seen=$((seen + 1))
    POLICY_REMOTE_LAST_PATH="$path"
    rc=0
    _policy_remote_apply_path "$path" "$root" "$kind" "$policy" "$out_name" \
      "$checked_name" "$name" "$sink" "$seen" || rc=$?
    case "$rc" in
      0) ;;
      3) return 0 ;;
      *) return "$rc" ;;
    esac
  done <<<"$POLICY_REMOTE_PATHS"
  _policy_remote_set_checked "$checked_name" "$POLICY_REMOTE_COUNT"
  return 0
}

# _policy_remote_apply_external_root POLICY ROOT NAME SINK CHECKED_NAME SEEN -
# evaluate an external-storage root for apply style. Sets POLICY_REMOTE_COUNT
# to SEEN before reporting; rc 0 to keep walking, 2 to stop and skip, and 3 to
# stop and proceed (an accepted ask).
_policy_remote_apply_external_root() {
  local policy="$1" root="$2" name="$3" sink="$4" checked_name="$5" seen="$6"
  case "$policy" in
    skip)
      POLICY_REMOTE_COUNT="$seen"
      _policy_remote_skip "$checked_name" \
        "external storage (EXTERNAL_STORAGE_POLICY=skip)" \
        "external storage: '${name}': remote root ${root} is mounted external storage; skipping (EXTERNAL_STORAGE_POLICY=skip)"
      return 2
      ;;
    ask)
      if _policy_remote_confirm external; then
        POLICY_REMOTE_COUNT="$seen"
        _policy_remote_emit "$sink" "external storage: ${root} accepted for '${name}' (EXTERNAL_STORAGE_POLICY=ask)"
        _policy_remote_set_checked "$checked_name" "$POLICY_REMOTE_COUNT"
        return 3
      fi
      POLICY_REMOTE_COUNT="$seen"
      _policy_remote_skip "$checked_name" \
        "external storage (EXTERNAL_STORAGE_POLICY=ask); not confirmed" \
        "external storage: '${name}': remote root ${root} is mounted external storage; skipping (EXTERNAL_STORAGE_POLICY=ask)"
      return 2
      ;;
    *)
      _policy_remote_emit "$sink" "external storage: remote root ${root} is mounted external storage (EXTERNAL_STORAGE_POLICY=${policy})"
      ;;
  esac
  return 0
}

# _policy_remote_apply_path PATH ROOT KIND POLICY OUT_EXCLUDES_NAME CHECKED_VAR
# NAME SINK SEEN - evaluate one reported path for apply style and update the
# POLICY_REMOTE_* state. rc 0 to keep walking, 2 to stop and skip, and 3 to
# stop and proceed (an accepted external-storage ask).
_policy_remote_apply_path() {
  local path="$1" root="$2" kind="$3" policy="$4" out_name="$5"
  local checked_name="$6" name="$7" sink="$8" seen="$9"
  local sub="" p_path="" silent=false
  [[ "$sink" == ":" ]] && silent=true
  if [[ "$path" == "$root" ]]; then
    if [[ "$kind" == "e2ee" ]]; then
      POLICY_REMOTE_COUNT="$seen"
      _policy_remote_skip "$checked_name" \
        "end-to-end encrypted remote root (E2EE_POLICY=${policy})" \
        "e2ee: '${name}': remote root ${root} is end-to-end encrypted; skipping (E2EE_POLICY=${policy})"
      return 2
    fi
    _policy_remote_apply_external_root "$policy" "$root" "$name" "$sink" "$checked_name" "$seen"
    return $?
  fi
  if [[ "$kind" == "e2ee" ]]; then
    sub="${path#"$root"/}"
    if [[ "$sub" == "$path" || -z "$sub" ]]; then
      return 0
    fi
    if ! safe_remote_path "$sub"; then
      if [[ "$silent" == false ]]; then
        p_path=${ printable "$path";}
        _policy_remote_emit "$sink" "e2ee: ignoring unsafe remote path ${p_path}"
      fi
      return 0
    fi
    POLICY_REMOTE_LAST_SUB="$sub"
    if [[ "$policy" == "exclude" ]]; then
      if [[ -n "$out_name" ]]; then
        local -n _pro_excludes="$out_name"
        _pro_excludes+=("$(blacklist_exclude_pattern "$sub")/**")
      fi
      if [[ "$silent" == false ]]; then
        p_path=${ printable "$path";}
        _policy_remote_emit "$sink" "e2ee: ${p_path} is end-to-end encrypted; excluded"
      fi
    elif [[ "$silent" == false ]]; then
      p_path=${ printable "$path";}
      _policy_remote_emit "$sink" "e2ee: ${p_path} is end-to-end encrypted (E2EE_POLICY=${policy})"
    fi
  else
    sub="${path#"$root"/}"
    if [[ "$sub" != "$path" && -n "$sub" ]] && ! safe_remote_path "$sub"; then
      if [[ "$silent" == false ]]; then
        p_path=${ printable "$path";}
        _policy_remote_emit "$sink" "external storage: ignoring unsafe remote path ${p_path}"
      fi
      return 0
    fi
    if [[ "$silent" == false ]]; then
      p_path=${ printable "$path";}
      _policy_remote_emit "$sink" "external storage: ${p_path} is mounted external storage (subfolder; continuing)"
    fi
  fi
  return 0
}
