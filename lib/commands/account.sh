#!/bin/bash
# account.sh command module - manage profiles (multi-account support).
# A profile lives in config/profiles/<name>/ with its own manifests,
# filters, and state under state/profiles/<name>/. The default profile is
# the project-wide layout and cannot be added or removed.

usage_account() {
  usage_emit <<'EOF'
Usage: sciebo account <list|add|import|remove|use|info|avatar|status> [options]

Manage profiles. Each profile is an independent account: its own
config/profiles/<name>/ manifests and filters, its own rclone remote
settings, and its own state/locks under state/profiles/<name>/.

Subcommands:
  list                                   show every profile
  add NAME [--remote R] [--base B]       create a profile
  import [options]                       import accounts and folder pairs
                                         from the Nextcloud desktop client
  remove NAME [--yes]                    delete a profile's config and state
  use NAME                               show how to activate a profile
  info [--json]                          show the account on the server
  avatar [--output FILE] [--size N]      download the account avatar
  status [--json]                        remote, server, cache, and keychain

Select a profile per run with the global `sciebo --profile NAME ...` flag or
by exporting SCIEBO_PROFILE=NAME for the shell. Keychain storage uses the
service rclone-sciebo/<name> automatically.

add options:
  --remote R  rclone remote name for this profile (letters, digits, dot,
              dash, underscore)
  --base B    remote base folder for this profile (a relative path)

import options:
  --nextcloud-cfg FILE   read FILE instead of the default nextcloud.cfg
                         (also honored: the NEXTCLOUD_CFG environment
                         variable); the default locations are the macOS app
                         container, the macOS legacy path, Linux, and
                         %APPDATA%/Nextcloud/nextcloud.cfg
  --profile NAME         import only the account matching NAME: a 0-based
                         account index, a user id, or the profile name the
                         account would get; without it every configured
                         account is imported (this is the global --profile
                         flag, reused as the selector)
  --dry-run              print the full plan and write nothing
  --yes                  merge into an existing profile or manifest, and
                         accept absolute local paths outside the configured
                         local root, without asking (non-interactive runs
                         need this)
  --json                 print {"imports":[...]} instead of the text plan

Account 0 becomes the default profile; other accounts become a profile
named after their user id when that is a safe name, else account<N>.
Passwords are never imported; run `setup --login` (or `setup --rotate`)
for every imported profile afterwards.

Options:
  --json          print JSON (info and status)
  --output FILE   write the avatar to FILE (default ./avatar-<user>.png)
  --size N        avatar pixel size (default AVATAR_SIZE, else 128)
  -h, --help      show this help
EOF
}

# account_dir NAME - print the config directory of a named profile.
account_dir() { printf '%s/%s' "$PROFILES_DIR" "$1"; }

# account_manifest_paths PROFILE - point the manifest globals at PROFILE's
# files ("default" is the project-wide layout). The caller must declare
# MANIFEST_FILE, FOLDERS_FILE, MANIFEST_GENERATED_FILE, and FILTER_DIR local;
# bash dynamic scoping then lands the assignments in the caller's scope.
# Mirrors the per-profile overrides in load_settings.
account_manifest_paths() {
  local dir=""
  if [[ "$1" == "default" ]]; then
    # Keep an existing override (an exported path or --confdir layout), just
    # like load_settings does.
    dir="${_SCIEBO_CONF_BASE:-${CONFIG_DIR}}"
    : "${MANIFEST_FILE:=${dir}/sources.conf}"
    : "${FOLDERS_FILE:=${dir}/folders.conf}"
    : "${MANIFEST_GENERATED_FILE:=${dir}/sources.generated.conf}"
    : "${FILTER_DIR:=${dir}/filters}"
  else
    dir="$(account_dir "$1")"
    MANIFEST_FILE="${dir}/sources.conf"
    FOLDERS_FILE="${dir}/folders.conf"
    MANIFEST_GENERATED_FILE="${dir}/sources.generated.conf"
    FILTER_DIR="${dir}/filters"
  fi
  return 0
}

# account_exists NAME - true when the profile directory exists.
account_exists() { [[ -d "$(account_dir "$1")" ]]; }

# account_profile_values NAME - subshell-source the profile chain and print
# "remote<TAB>base<TAB>service" for the listing. Returns 1 without output when
# one of the profile's own settings files exists but is unsafe (safe_source_file
# already warned), so the caller can skip the whole profile.
account_profile_values() {
  local name="$1" dir
  dir="$(account_dir "$name")"
  (
    # Each settings file is state/config that may be environment-overridden,
    # so safe_source refuses a file that is not owned by the user or is
    # group/other-writable, and reads through an open descriptor so a swap
    # cannot execute different content.
    # shellcheck disable=SC2153  # settings.sh exports SETTINGS_FILE
    safe_source "$SETTINGS_FILE" 2>/dev/null || exit 0
    safe_source "$SETTINGS_LOCAL_FILE" || true
    if [[ -e "${dir}/settings.env" ]]; then
      safe_source "${dir}/settings.env" || exit 3
    fi
    if [[ -e "${dir}/settings.local.env" ]]; then
      safe_source "${dir}/settings.local.env" || exit 3
    fi
    if [[ "$name" != "default" && "$KEYCHAIN_SERVICE" == "$DEFAULT_KEYCHAIN_SERVICE" ]]; then
      KEYCHAIN_SERVICE="${DEFAULT_KEYCHAIN_SERVICE}/${name}"
    fi
    printf '%s\t%s\t%s\n' "${RCLONE_REMOTE:-}" "${REMOTE_BASE:-}" "${KEYCHAIN_SERVICE:-}"
  )
}

# account_source_count DIR - number of configured manifest lines in a
# profile directory (manual sources plus wizard pairs): non-blank,
# non-comment lines carrying at least three '|'-separated fields across the
# three manifest files. Pure bash so `account list` does not fork awk per
# profile.
account_source_count() {
  local dir="$1" file="" line="" bars="" n=0
  if [[ ! -f "${dir}/sources.conf" && ! -f "${dir}/folders.conf" &&
    ! -f "${dir}/sources.generated.conf" ]]; then
    printf '0'
    return 0
  fi
  # The manifest model also reads sources.generated.conf; count it here too
  # so wizard/discover entries are not invisible in `account list`.
  # awk treats an unopenable input as fatal and then prints nothing at all,
  # so a partial (or unreadable) manifest set must still print nothing here.
  for file in "${dir}/sources.conf" "${dir}/folders.conf" \
    "${dir}/sources.generated.conf"; do
    [[ -f "$file" && -r "$file" ]] || return 0
  done
  for file in "${dir}/sources.conf" "${dir}/folders.conf" \
    "${dir}/sources.generated.conf"; do
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" =~ ^[[:space:]]*$ ]] && continue
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      bars="${line//[^|]/}"
      [[ "${#bars}" -ge 2 ]] || continue
      n=$((n + 1))
    done <"$file" 2>/dev/null
  done
  printf '%s' "$n"
}

account_list() {
  local name="" dir="" values="" remote="" base="" service="" count="" state=""
  local p_name="" p_remote="" p_base="" p_service=""
  printf '%-16s %-14s %-14s %-7s %s\n' "PROFILE" "REMOTE" "BASE" "SOURCES" "KEYCHAIN SERVICE"
  values="$(account_profile_values "default")"
  remote="${values%%$'\t'*}"
  values="${values#*$'\t'}"
  base="${values%%$'\t'*}"
  service="${values#*$'\t'}"
  count="$(account_source_count "${_SCIEBO_CONF_BASE:-$CONFIG_DIR}")"
  p_remote=${ printable "${remote:-?}";}
  p_base=${ printable "${base:-?}";}
  p_service=${ printable "${service:-?}";}
  printf '%-16s %-14s %-14s %-7s %s\n' "default" "$p_remote" \
    "$p_base" "$count" "$p_service"
  [[ -d "$PROFILES_DIR" ]] || return 0
  for dir in "$PROFILES_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    name="${dir%/}"
    name="${name##*/}"
    if ! values="$(account_profile_values "$name")"; then
      p_name=${ printable "$name";}
      warn "skipping profile '${p_name}': unsafe settings file"
      continue
    fi
    remote="${values%%$'\t'*}"
    values="${values#*$'\t'}"
    base="${values%%$'\t'*}"
    service="${values#*$'\t'}"
    count="$(account_source_count "$dir")"
    if [[ -d "${PROFILES_STATE_DIR}/${name}" ]]; then state="ready"; else state="no state yet"; fi
    p_name=${ printable "$name";}
    p_remote=${ printable "${remote:-?}";}
    p_base=${ printable "${base:-?}";}
    p_service=${ printable "${service:-?}";}
    printf '%-16s %-14s %-14s %-7s %s (%s)\n' "$p_name" \
      "$p_remote" "$p_base" "$count" \
      "$p_service" "$state"
  done
}

# account_init_profile NAME [REMOTE] [BASE] - create the profile skeleton:
# config/filters plus empty manifests and roots, and settings.local.env with
# the profile header and the optional remote/base assignments. Existing
# files are never overwritten. Returns 1 when the directories cannot be
# created.
account_init_profile() {
  local name="$1" remote="${2:-}" base="${3:-}" dir="" state_dir="" f=""
  dir="$(account_dir "$name")"
  state_dir="${PROFILES_STATE_DIR}/${name}"
  mkdir -p "${dir}/filters" "$state_dir" || return 1
  for f in sources.conf folders.conf roots.conf; do
    [[ -e "${dir}/${f}" ]] || : >"${dir}/${f}"
  done
  # The source is the project-wide filter directory, not FILTER_DIR, which
  # may already point at the profile being created; it must honor --confdir.
  [[ -e "${dir}/filters/clutter.txt" ]] ||
    cp "${_SCIEBO_CONF_BASE:-${CONFIG_DIR}}/filters/clutter.txt" "${dir}/filters/clutter.txt" 2>/dev/null || true
  if [[ ! -e "${dir}/settings.local.env" ]]; then
    {
      printf '# Profile settings for %s.\n' "$name"
      printf '# Plain assignments here win over the project settings and the environment.\n'
      # %q shell-quotes the values: the file is sourced by every profile run,
      # so a base path containing $, quotes, or backticks must stay data.
      [[ -z "$remote" ]] || printf 'RCLONE_REMOTE=%q\n' "$remote"
      [[ -z "$base" ]] || printf 'REMOTE_BASE=%q\n' "$base"
    } >"${dir}/settings.local.env"
  fi
  return 0
}

account_add() {
  local name="$1" remote="" base="" dir=""
  shift
  opt_begin "remote:s base:s" account "" "$@"
  remote="${OPT_remote:-}"
  base="${OPT_base:-}"
  validate_profile_name "$name"
  # The values are written into settings.local.env, which every profile run
  # sources. account_init_profile shell-quotes them with %q; the remote name
  # is additionally restricted to a portable charset.
  if [[ -n "$remote" ]]; then
    case "$remote" in
      . | .. | *[!A-Za-z0-9._-]*)
        die "invalid --remote name '$(printable "$remote")': use letters, digits, dot, dash, or underscore"
        ;;
    esac
  fi
  if [[ -n "$base" ]] && ! safe_remote_path "$base"; then
    die "invalid --base path '$(printable "$base")': use a relative path without '..', '|', or control bytes"
  fi
  account_exists "$name" &&
    die "profile '$(printable "$name")' already exists at $(account_dir "$name")"
  dir="$(account_dir "$name")"
  account_init_profile "$name" "$remote" "$base" || die "cannot create ${dir}"
  log "created profile '$(printable "$name")' in ${dir}"
  if [[ -z "$remote" ]]; then
    printf 'next: %s --profile %s setup --login     # configure the account\n' "$CLI_NAME" "$name"
  fi
  printf 'next: %s --profile %s folders choose    # add folders to sync\n' "$CLI_NAME" "$name"
}

account_remove() {
  local name="$1" dir="" state_dir=""
  shift
  opt_begin "yes:b" account "" "$@"
  opt_guard account
  [[ "$name" != "default" ]] || die "the default profile cannot be removed"
  validate_profile_name "$name"
  account_exists "$name" || die "no such profile: $(printable "$name")"
  dir="$(account_dir "$name")"
  state_dir="${PROFILES_STATE_DIR}/${name}"
  # Soft confirmation gate, previously account_confirm_soft: --yes skips
  # the question, a non-interactive run without --yes fails the usage with
  # the same message, and a declined prompt logs "aborted, nothing changed"
  # so the command still exits 0 without removing anything.
  ui_confirm_mutation_soft account "refusing to remove '${name}' without --yes" \
    "remove profile '${name}' (config and state)?" \
    "aborted, nothing changed" || return 0
  rm -rf "$dir" "$state_dir" || die "cannot remove profile '${name}'"
  log "removed profile '$(printable "$name")'"
}

account_use() {
  local name="$1"
  shift
  [[ $# -eq 0 ]] || usage_error account "unknown option: $1"
  if [[ "$name" == "default" ]]; then
    log "the default profile is active when SCIEBO_PROFILE is empty"
    return 0
  fi
  validate_profile_name "$name"
  account_exists "$name" || die "no such profile: $(printable "$name")"
  log "profile '$(printable "$name")' is ready"
  printf '  export SCIEBO_PROFILE=%s      # this shell\n' "$name"
  printf '  %s --profile %s doctor        # one run\n' "$CLI_NAME" "$name"
}

# ---------------------------------------------------------------------------
# account import (Nextcloud desktop client migration)
#
# `account import` reads the desktop client's nextcloud.cfg, plans one
# profile per configured account, and writes the profile skeleton, the
# mapped [General] settings, and one bisync pair per configured folder.
# Passwords are never imported: they live in the desktop client's keychain
# and cannot be read portably.
# ---------------------------------------------------------------------------

# nextcloud.cfg data. IMPORT_ACCOUNT_* are keyed by the file's account
# index; IMPORT_F<account>_<folder>_* hold one folder field each. The
# associative "seen" sets make the note_* helpers O(1) instead of rescanning
# a growing newline string per folder.
IMPORT_ENTRIES=""
IMPORT_SECTION=""
IMPORT_FILE=""
IMPORT_NUM_ACCOUNTS=""
IMPORT_ACCOUNT_INDICES=""
IMPORT_ACCOUNT_URL=()
IMPORT_ACCOUNT_USER=()
IMPORT_FOLDERS=()
declare -gA IMPORT_ACCOUNT_INDICES_SEEN=()
declare -gA IMPORT_FOLDER_INDICES_SEEN=()
# The [General] section, keyed by normalized key (last assignment wins),
# filled once by account_import_collect so account_import_general is O(1)
# instead of rescanning IMPORT_ENTRIES per key.
declare -gA IMPORT_GENERAL=()
IMPORT_TARGET_NAMES=()
IMPORT_PLAN_NAMES=""
IMPORT_SELECTED=""
IMPORT_ABORTED=0
# 1 while planning/applying a real import: an absolute localPath outside the
# configured local root then needs --yes (or an interactive confirmation).
# Dry runs keep the full plan, so they leave this at 0.
IMPORT_ENFORCE_ROOT=0
IMPORT_PLAN_ACCOUNTS=()
IMPORT_PLAN_PROFILES=()
IMPORT_PLAN_USERS=()
IMPORT_PLAN_URLS=()
IMPORT_PLAN_SETTINGS=()
IMPORT_PLAN_PAIRS=()
IMPORT_PLAN_BLOCKED=()
IMPORT_PLAN_APPLIED=()
IMPORT_PLAN_STATUS=()
IMPORT_PLAN_SKIPPED=()
# PAIR_FLAGS_DIR as pinned before the import (tests/exported overrides); empty
# means "derive the target profile's state directory per account".
IMPORT_PAIR_FLAGS_DIR_OVERRIDE=""

# account_import_config_candidates - print the default nextcloud.cfg
# locations in discovery order: the macOS app container, the macOS legacy
# path, Linux, and the Windows %APPDATA% location when APPDATA is set.
account_import_config_candidates() {
  printf '%s\n' \
    "${HOME}/Library/Containers/com.nextcloud.desktopclient/Data/Library/Preferences/Nextcloud/nextcloud.cfg" \
    "${HOME}/Library/Preferences/Nextcloud/nextcloud.cfg" \
    "${HOME}/.config/Nextcloud/nextcloud.cfg"
  if [[ -n "${APPDATA:-}" ]]; then
    printf '%s\n' "${APPDATA}/Nextcloud/nextcloud.cfg"
  fi
  return 0
}

# account_import_find_config [EXPLICIT] - set IMPORT_FILE to EXPLICIT, to
# NEXTCLOUD_CFG (both from the caller), or to the first readable default
# location. Dies with the searched paths when nothing is found.
account_import_find_config() {
  local explicit="${1:-}" candidate="" found="" searched=""
  if [[ -n "$explicit" ]]; then
    if [[ ! -f "$explicit" || ! -r "$explicit" ]]; then
      die "cannot read Nextcloud config '$(printable "$explicit")'"
    fi
    IMPORT_FILE="$explicit"
    return 0
  fi
  while IFS= read -r candidate; do
    searched="${searched}  ${candidate}"$'\n'
    if [[ -f "$candidate" && -r "$candidate" ]]; then
      found="$candidate"
      break
    fi
  done < <(account_import_config_candidates)
  if [[ -z "$found" ]]; then
    die "no Nextcloud desktop client config found; searched:
${searched%$'\n'}
use --nextcloud-cfg FILE or NEXTCLOUD_CFG to point at one"
  fi
  IMPORT_FILE="$found"
  return 0
}

# account_import_parse_line LINE LINENO - normalize one raw config line and
# append its SECTION<TAB>KEY<TAB>VALUE record to IMPORT_ENTRIES. A section
# header updates IMPORT_SECTION; keys are normalized to '/' separators
# whatever the file used; values are trimmed and surrounding double quotes
# removed; blank lines, #/; comments, unknown sections, and malformed lines
# are ignored (the last with a warning naming LINENO). The file name comes
# from FILE in the caller's dynamically scoped scope.
account_import_parse_line() {
  local line="$1" lineno="$2" key="" value="" lower=""
  line="${line%$'\r'}"
  line=${ trim "$line";}
  [[ -n "$line" ]] || return 0
  case "$line" in
    \#* | \;*) return 0 ;;
  esac
  case "$line" in
    \[*\])
      lower=${ trim "${line#[}";}
      lower="${lower,,}"
      case "$lower" in
        general\]) IMPORT_SECTION="General" ;;
        accounts\]) IMPORT_SECTION="Accounts" ;;
        *) IMPORT_SECTION="" ;;
      esac
      return 0
      ;;
  esac
  case "$line" in
    *=*) ;;
    *)
      warn "import: ignoring malformed line ${lineno} in ${file}: $(printable "$line")"
      return 0
      ;;
  esac
  [[ -n "$IMPORT_SECTION" ]] || return 0
  key=${ trim "${line%%=*}";}
  value=${ trim "${line#*=}";}
  case "$value" in
    \"*\")
      value="${value#\"}"
      value="${value%\"}"
      ;;
  esac
  key="${key//\\//}"
  if [[ -z "$key" ]]; then
    warn "import: ignoring malformed line ${lineno} in ${file}: $(printable "$line")"
    return 0
  fi
  IMPORT_ENTRIES="${IMPORT_ENTRIES}${IMPORT_SECTION}"$'\t'"${key}"$'\t'"${value}"$'\n'
  return 0
}

# account_import_parse FILE - read FILE into IMPORT_ENTRIES as
# SECTION<TAB>KEY<TAB>VALUE lines via account_import_parse_line.
account_import_parse() {
  local file="$1" line="" lineno=0 first=1
  IMPORT_ENTRIES=""
  IMPORT_SECTION=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    if [[ "$first" -eq 1 ]]; then
      line="${line#$'\xEF\xBB\xBF'}"
      first=0
    fi
    account_import_parse_line "$line" "$lineno"
  done <"$file"
  return 0
}

# account_import_note_index IDX - record IDX as a configured account once.
account_import_note_index() {
  local idx="$1"
  [[ -z "${IMPORT_ACCOUNT_INDICES_SEEN[$idx]:-}" ]] || return 0
  IMPORT_ACCOUNT_INDICES_SEEN[$idx]=1
  IMPORT_ACCOUNT_INDICES="${IMPORT_ACCOUNT_INDICES}${idx}"$'\n'
  return 0
}

# account_import_note_folder IDX FIDX - record folder FIDX under account
# IDX once, so folder fields are consumed in the order they first appear.
account_import_note_folder() {
  local idx="$1" fidx="$2" key="${1}/${2}" list="${IMPORT_FOLDERS[$1]:-}"
  [[ -z "${IMPORT_FOLDER_INDICES_SEEN[$key]:-}" ]] || return 0
  IMPORT_FOLDER_INDICES_SEEN[$key]=1
  IMPORT_FOLDERS[idx]="${list}${fidx}"$'\n'
  return 0
}

# account_import_collect_folders IDX KEY VALUE - parse one [Accounts] key of
# account IDX whose sub-key is Folders/<fidx>/<field>: record the folder and
# store its localPath/targetPath/paused/ignoreHiddenFiles value as
# IMPORT_F<IDX>_<FIDX>_*. KEY is the full original key, used in the warning
# for a malformed folder index.
account_import_collect_folders() {
  local idx="$1" key="$2" value="$3"
  local rest="${key#*/}" field="" fidx="" ffield=""
  field="${rest#*/}"
  fidx="${field%%/*}"
  ffield="${field#*/}"
  case "$fidx" in
    '' | *[!0-9]*)
      warn "import: ignoring malformed account key '$(printable "$key")'"
      return 0
      ;;
  esac
  fidx="$((10#$fidx))"
  account_import_note_index "$idx"
  account_import_note_folder "$idx" "$fidx"
  case "$ffield" in
    localPath) printf -v "IMPORT_F${idx}_${fidx}_LOCAL" '%s' "$value" ;;
    targetPath) printf -v "IMPORT_F${idx}_${fidx}_TARGET" '%s' "$value" ;;
    paused) printf -v "IMPORT_F${idx}_${fidx}_PAUSED" '%s' "$value" ;;
    ignoreHiddenFiles) printf -v "IMPORT_F${idx}_${fidx}_HIDDEN" '%s' "$value" ;;
    *) ;;
  esac
  return 0
}

# account_import_collect_general KEY VALUE - record one [General] record;
# the last assignment to a key wins.
account_import_collect_general() {
  IMPORT_GENERAL["$1"]="$2"
  return 0
}

# account_import_collect_account KEY VALUE - record one [Accounts] record:
# numAccounts, an account url/user, or a Folders/<fidx>/<field> folder.
# Malformed account indices and unknown account keys are skipped.
account_import_collect_account() {
  local key="$1" value="$2" idx="" rest=""
  case "$key" in
    numAccounts)
      IMPORT_NUM_ACCOUNTS="$value"
      return 0
      ;;
    */*)
      idx="${key%%/*}"
      rest="${key#*/}"
      ;;
    *)
      return 0
      ;;
  esac
  case "$idx" in
    '' | *[!0-9]*)
      warn "import: ignoring malformed account key '$(printable "$key")'"
      return 0
      ;;
  esac
  idx="$((10#$idx))"
  case "$rest" in
    url)
      IMPORT_ACCOUNT_URL[idx]="$value"
      account_import_note_index "$idx"
      ;;
    user)
      IMPORT_ACCOUNT_USER[idx]="$value"
      account_import_note_index "$idx"
      ;;
    Folders/* | folders/*)
      account_import_collect_folders "$idx" "$key" "$value"
      ;;
    *) ;;
  esac
  return 0
}

# account_import_collect_record SECTION KEY VALUE - dispatch one parsed
# IMPORT_ENTRIES record to its section handler; other sections are ignored.
account_import_collect_record() {
  local section="$1"
  if [[ "$section" == "General" ]]; then
    account_import_collect_general "$2" "$3"
    return 0
  fi
  if [[ "$section" == "Accounts" ]]; then
    account_import_collect_account "$2" "$3"
  fi
  return 0
}

# account_import_collect - turn IMPORT_ENTRIES into the per-account
# IMPORT_ACCOUNT_* values and IMPORT_F<account>_<folder>_* fields.
# Structurally broken [Accounts] keys are warned about and skipped.
account_import_collect() {
  local section="" key="" value=""
  IMPORT_NUM_ACCOUNTS=""
  IMPORT_ACCOUNT_INDICES=""
  IMPORT_ACCOUNT_URL=()
  IMPORT_ACCOUNT_USER=()
  IMPORT_FOLDERS=()
  IMPORT_ACCOUNT_INDICES_SEEN=()
  IMPORT_FOLDER_INDICES_SEEN=()
  IMPORT_GENERAL=()
  while IFS=$'\t' read -r section key value; do
    account_import_collect_record "$section" "$key" "$value"
  done <<<"$IMPORT_ENTRIES"
  account_import_check_num_accounts
  return 0
}

# account_import_check_num_accounts - numAccounts is optional and the
# account keys are authoritative, so it only drives a warning for declared
# accounts that carry neither a url nor a user.
account_import_check_num_accounts() {
  local n="" i=0
  [[ -n "$IMPORT_NUM_ACCOUNTS" ]] || return 0
  if ! account_import_nonneg_into n "$IMPORT_NUM_ACCOUNTS"; then
    warn "import: ignoring invalid numAccounts '$(printable "$IMPORT_NUM_ACCOUNTS")'"
    return 0
  fi
  while [[ "$i" -lt "$n" ]]; do
    if [[ -z "${IMPORT_ACCOUNT_URL[$i]:-}" && -z "${IMPORT_ACCOUNT_USER[$i]:-}" ]]; then
      warn "import: account ${i} is declared by numAccounts but has no url/user; skipped"
    fi
    i=$((i + 1))
  done
  return 0
}

# account_import_general KEY - print the [General] value for KEY (the last
# assignment wins), or nothing. IMPORT_GENERAL is filled once by
# account_import_collect, so this is a plain lookup.
account_import_general() {
  printf '%s' "${IMPORT_GENERAL[${1:-}]:-}"
  return 0
}

# account_import_bool_into VAR VALUE - normalize a desktop client boolean to
# 1/0 in VAR (empty when the value is neither), without a command
# substitution: this runs once per folder pair, so hot callers avoid forking
# a subshell. Case-insensitive patterns instead of a `tr` fork.
account_import_bool_into() {
  local -n _aib_out="$1"
  _aib_out=""
  case "${2:-}" in
    1 | [Tt][Rr][Uu][Ee] | [Yy][Ee][Ss] | [Oo][Nn]) _aib_out="1" ;;
    0 | [Ff][Aa][Ll][Ss][Ee] | [Nn][Oo] | [Oo][Ff][Ff]) _aib_out="0" ;;
  esac
  return 0
}

# account_import_nonneg_into VAR VALUE - normalize VALUE to a non-negative
# integer in VAR without a command substitution: returns 0 with VAR set, or 1
# when the value is not a number (VAR cleared first), so callers can use it
# directly in an `if`.
account_import_nonneg_into() {
  local -n _ain_out="$1"
  local _ain_value="${2:-}"
  _ain_out=""
  case "$_ain_value" in
    '' | *[!0-9]*) return 1 ;;
  esac
  _ain_out="$((10#$_ain_value))"
  return 0
}

# account_import_num_line KEY VALUE [MIN] - print KEY="VALUE" when VALUE is
# a non-negative integer >= MIN (default 1); warn and print nothing
# otherwise.
account_import_num_line() {
  local key="$1" value="$2" min="${3:-1}" num=""
  [[ -n "$value" ]] || return 0
  if ! account_import_nonneg_into num "$value"; then
    warn "import: ignoring non-numeric ${key} value '$(printable "$value")'"
    return 0
  fi
  [[ "$num" -ge "$min" ]] || return 0
  printf '%s="%s"\n' "$key" "$num"
  return 0
}

# account_import_bool_line KEY VALUE - print KEY="0|1" for a boolean VALUE;
# warn and print nothing otherwise.
account_import_bool_line() {
  local key="$1" value="$2" norm=""
  [[ -n "$value" ]] || return 0
  account_import_bool_into norm "$value"
  if [[ -z "$norm" ]]; then
    warn "import: ignoring non-boolean ${key} value '$(printable "$value")'"
    return 0
  fi
  printf '%s="%s"\n' "$key" "$norm"
  return 0
}

# account_import_settings_block IDX - print the settings.local.env lines
# derived from the [General] section for account IDX. Only values with a
# sciebo equivalent are mapped (see docs/settings.md): chunk sizes, timeout,
# trash behavior, delete threshold, launch-at-login, big-folder size, and
# debug logging.
account_import_settings_block() {
  local value="" num="" log_debug=""
  account_import_num_line CHUNK_SIZE "${ account_import_general chunkSize;}" 1
  account_import_num_line MIN_CHUNK_SIZE "${ account_import_general minChunkSize;}" 1
  account_import_num_line MAX_CHUNK_SIZE "${ account_import_general maxChunkSize;}" 1
  value=${ account_import_general timeout;}
  if account_import_nonneg_into num "$value"; then
    [[ "$num" -le 0 ]] || printf 'TIMEOUT="%ss"\n' "$num"
  elif [[ -n "$value" ]]; then
    warn "import: ignoring non-numeric TIMEOUT value '$(printable "$value")'"
  fi
  account_import_bool_line MOVE_TO_TRASH "${ account_import_general moveToTrash;}"
  account_import_bool_line ASK_DELETE "${ account_import_general promptDeleteAllFiles;}"
  account_import_num_line DELETE_FILES_THRESHOLD "${ account_import_general deleteFilesThreshold;}" 0
  account_import_bool_line SCHEDULE_AT_LOGIN "${ account_import_general launchOnSystemStartup;}"
  value=${ account_import_general newBigFolderSizeLimit;}
  if account_import_nonneg_into num "$value"; then
    [[ "$num" -le 0 ]] || printf 'BIG_FOLDER_SIZE="%sMi"\n' "$num"
  elif [[ -n "$value" ]]; then
    warn "import: ignoring non-numeric BIG_FOLDER_SIZE value '$(printable "$value")'"
  fi
  account_import_bool_into log_debug "${ account_import_general logDebug;}"
  if [[ "$log_debug" == "1" ]]; then
    printf 'LOG_LEVEL="DEBUG"\n'
  fi
  return 0
}

# account_import_safe_name NAME - true when NAME is usable as a profile
# directory name (mirrors validate_profile_name without dying).
account_import_safe_name() {
  local name="$1"
  [[ -n "$name" && "$name" != "." && "$name" != ".." && "$name" != "default" ]] || return 1
  case "$name" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# account_import_name_taken NAME - true when NAME is already assigned.
account_import_name_taken() {
  local name="$1" taken=""
  while IFS= read -r taken; do
    if [[ "$taken" == "$name" ]]; then return 0; fi
  done <<<"$IMPORT_PLAN_NAMES"
  return 1
}

# account_import_ordered_indices - print the configured account indices in
# numeric order.
account_import_ordered_indices() {
  printf '%s' "$IMPORT_ACCOUNT_INDICES" | LC_ALL=C sort -n
  return 0
}

# account_import_target_name IDX - the profile name for account IDX:
# "default" for index 0, otherwise the user id when it is a safe profile
# name, else account<IDX>, with a numeric suffix on collisions.
account_import_target_name() {
  local idx="$1" user="${IMPORT_ACCOUNT_USER[$1]:-}" name="" n=2
  if [[ "$idx" == "0" ]]; then
    printf 'default'
    return 0
  fi
  if account_import_safe_name "$user"; then
    name="$user"
  else
    name="account${idx}"
  fi
  while account_import_name_taken "$name"; do
    name="account${idx}-${n}"
    n=$((n + 1))
  done
  printf '%s' "$name"
  return 0
}

# account_import_assign_names - assign every configured account a unique
# target profile name; IMPORT_TARGET_NAMES is keyed by account index.
account_import_assign_names() {
  local idx="" name=""
  IMPORT_TARGET_NAMES=()
  IMPORT_PLAN_NAMES=""
  while IFS= read -r idx; do
    [[ -n "$idx" ]] || continue
    name="$(account_import_target_name "$idx")"
    IMPORT_TARGET_NAMES[idx]="$name"
    IMPORT_PLAN_NAMES="${IMPORT_PLAN_NAMES}${name}"$'\n'
  done <<<"$(account_import_ordered_indices)"
  return 0
}

# account_import_selected SELECTOR - set IMPORT_SELECTED to the account
# indices to import: every configured account without SELECTOR, or the one
# matching SELECTOR (a 0-based index, a user id, or the target profile
# name). Dies when SELECTOR matches nothing.
account_import_selected() {
  local selector="${1:-}" idx="" user="" target="" want_num="" members=""
  IMPORT_SELECTED=""
  members="$(account_import_ordered_indices)"
  if [[ -z "$selector" ]]; then
    IMPORT_SELECTED="$members"
    return 0
  fi
  case "$selector" in
    '' | *[!0-9]*) want_num="" ;;
    *) want_num="$((10#$selector))" ;;
  esac
  while IFS= read -r idx; do
    [[ -n "$idx" ]] || continue
    user="${IMPORT_ACCOUNT_USER[$idx]:-}"
    target="${IMPORT_TARGET_NAMES[$idx]:-}"
    if [[ -n "$want_num" && "$want_num" == "$idx" ]]; then
      IMPORT_SELECTED="${IMPORT_SELECTED}${idx}"$'\n'
    elif [[ -n "$user" && "$selector" == "$user" ]]; then
      IMPORT_SELECTED="${IMPORT_SELECTED}${idx}"$'\n'
    elif [[ -n "$target" && "$selector" == "$target" ]]; then
      IMPORT_SELECTED="${IMPORT_SELECTED}${idx}"$'\n'
    fi
  done <<<"$members"
  if [[ -z "$IMPORT_SELECTED" ]]; then
    die "no configured Nextcloud account matches '$(printable "$selector")' (use an account index or user id)"
  fi
  return 0
}

# account_import_count_entries PROFILE - number of valid manifest entries
# of the target profile (the project-wide files for "default"). Reads the
# profile's manifests without touching or creating anything.
account_import_count_entries() {
  local profile="$1" line="" n=0
  # The inherited values (exported test/CLI overrides) survive the shadowing;
  # for the default profile account_manifest_paths keeps them.
  # shellcheck disable=SC2034  # read by the manifest helpers below
  local MANIFEST_FILE="${MANIFEST_FILE:-}" FOLDERS_FILE="${FOLDERS_FILE:-}"
  # shellcheck disable=SC2034  # read by account_manifest_paths below
  local MANIFEST_GENERATED_FILE="${MANIFEST_GENERATED_FILE:-}" FILTER_DIR="${FILTER_DIR:-}"
  account_manifest_paths "$profile"
  manifest_index_invalidate
  while IFS= read -r line; do
    manifest_parse_line "$line" || continue
    n=$((n + 1))
  done < <(manifest_lines)
  printf '%s' "$n"
  return 0
}

# account_import_target_blocked PROFILE - true when PROFILE already exists
# or already has manifest entries.
account_import_target_blocked() {
  local profile="$1" n=0
  if [[ "$profile" != "default" ]] && account_exists "$profile"; then
    return 0
  fi
  n="$(account_import_count_entries "$profile")"
  [[ -n "$n" ]] || n=0
  if [[ "$n" -gt 0 ]]; then
    return 0
  fi
  return 1
}

# account_import_remote_sub TARGET - normalize a desktop client targetPath
# into a manifest remote subdir: surrounding slashes are stripped and the
# account root ("/" or empty) becomes ".", because a manifest remote field
# must not be empty and rclone resolves "." to the remote base.
account_import_remote_sub() {
  local target=""
  target=${ trim "${1:-}";}
  target=${ strip_trailing_slashes "$target";}
  while [[ "$target" == /* ]]; do
    target="${target#/}"
  done
  [[ -n "$target" ]] || target="."
  printf '%s' "$target"
  return 0
}

# account_import_local_root - print the root an imported absolute localPath
# must stay under: FOLDERS_LOCAL_ROOT (expanded) when set, else the project
# directory. Trailing slashes are stripped and "/" is kept intact.
account_import_local_root() {
  local root="${FOLDERS_LOCAL_ROOT:-$PROJECT_DIR}"
  root=${ expand_local_path "$root";}
  root=${ strip_trailing_slashes "$root";}
  [[ -n "$root" ]] || root="/"
  printf '%s' "$root"
  return 0
}

# account_import_local_outside_root LOCAL_PATH - true when LOCAL_PATH is
# absolute and does not resolve below the configured local root. Relative
# paths are always allowed: the manifest resolves them against the project.
account_import_local_outside_root() {
  local path="$1" root=""
  [[ "$path" == /* ]] || return 1
  root=${ account_import_local_root;}
  [[ "$root" != "/" ]] || return 1
  [[ "$path" != "$root" && "$path" != "$root/"* ]]
}

# account_import_local_confirmed LOCAL_PATH - gate an out-of-root absolute
# localPath. --yes accepts it; ui_confirm_tty asks once when a prompt is
# possible and otherwise refuses (rc 2 maps to the old pre-prompt return-1
# skip), so a non-interactive run skips just that pair instead of failing
# the import - which is why this uses the TTY gate, not the soft mutation
# gate whose non-interactive branch is a usage error.
account_import_local_confirmed() {
  local path="$1" root="" rc=0
  account_import_local_outside_root "$path" || return 0
  [[ "${OPT_yes:-0}" == "1" ]] && return 0
  root=${ account_import_local_root;}
  ui_confirm_tty "imported local path '$(printable "$path")' is outside '$(printable "$root")'; import this pair?" || rc=$?
  [[ "$rc" -eq 0 ]]
}

# account_import_pairs_block IDX - print the account's folder pairs as
# LOCAL<TAB>REMOTE<TAB>PAUSED<TAB>HIDDEN lines. Entries that cannot be
# represented in a manifest (missing localPath, unsafe local or target path)
# are warned about and skipped. A real (non-dry) import additionally skips an
# absolute localPath outside the configured local root unless --yes or an
# interactive confirmation allows it.
account_import_pairs_block() {
  local idx="$1" fidx="" ref="" local_path="" target="" remote="" paused="" hidden="" root=""
  local folders="${IMPORT_FOLDERS[$1]:-}"
  while IFS= read -r fidx; do
    [[ -n "$fidx" ]] || continue
    ref="IMPORT_F${idx}_${fidx}_LOCAL"
    local_path=${ trim "${!ref:-}";}
    ref="IMPORT_F${idx}_${fidx}_TARGET"
    target="${!ref:-}"
    ref="IMPORT_F${idx}_${fidx}_PAUSED"
    paused="${!ref:-}"
    ref="IMPORT_F${idx}_${fidx}_HIDDEN"
    hidden="${!ref:-}"
    if [[ -z "$local_path" ]]; then
      warn "import: account ${idx} folder ${fidx} has no localPath; skipped"
      continue
    fi
    if ! safe_local_path "$local_path"; then
      warn "import: account ${idx} has an invalid local path '$(printable "$local_path")'; skipped"
      continue
    fi
    if [[ "${IMPORT_ENFORCE_ROOT:-0}" -eq 1 ]] && ! account_import_local_confirmed "$local_path"; then
      root=${ account_import_local_root;}
      warn "import: account ${idx} local path '$(printable "$local_path")' is outside the configured local root '$(printable "$root")'; skipped (use --yes to import)"
      continue
    fi
    remote=${ account_import_remote_sub "$target";}
    if ! safe_remote_path "$remote"; then
      warn "import: account ${idx} has an invalid target path '$(printable "$target")'; skipped"
      continue
    fi
    printf '%s\t%s\t%s\t%s\n' "$local_path" "$remote" "$paused" "$hidden"
  done <<<"$folders"
  return 0
}

# account_import_build_plan - fill the plan arrays for IMPORT_SELECTED.
account_import_build_plan() {
  local idx="" profile="" settings="" pairs="" line="" k=0
  IMPORT_PLAN_ACCOUNTS=()
  IMPORT_PLAN_PROFILES=()
  IMPORT_PLAN_USERS=()
  IMPORT_PLAN_URLS=()
  IMPORT_PLAN_SETTINGS=()
  IMPORT_PLAN_PAIRS=()
  IMPORT_PLAN_BLOCKED=()
  IMPORT_PLAN_APPLIED=()
  IMPORT_PLAN_STATUS=()
  IMPORT_PLAN_SKIPPED=()
  while IFS= read -r idx; do
    [[ -n "$idx" ]] || continue
    profile="${IMPORT_TARGET_NAMES[$idx]:-account${idx}}"
    settings=${ account_import_settings_block "$idx";}
    pairs=${ account_import_pairs_block "$idx";}
    IMPORT_PLAN_ACCOUNTS[k]="$idx"
    IMPORT_PLAN_PROFILES[k]="$profile"
    IMPORT_PLAN_USERS[k]="${IMPORT_ACCOUNT_USER[$idx]:-}"
    IMPORT_PLAN_URLS[k]="${IMPORT_ACCOUNT_URL[$idx]:-}"
    IMPORT_PLAN_SETTINGS[k]="$settings"
    IMPORT_PLAN_PAIRS[k]="$pairs"
    IMPORT_PLAN_SKIPPED[k]="0"
    if account_import_target_blocked "$profile"; then
      IMPORT_PLAN_BLOCKED[k]="yes"
    else
      IMPORT_PLAN_BLOCKED[k]="no"
    fi
    IMPORT_PLAN_APPLIED[k]="0"
    IMPORT_PLAN_STATUS[k]="planned"
    k=$((k + 1))
  done <<<"$IMPORT_SELECTED"
  return 0
}

# account_import_settings_write FILE BLOCK - merge BLOCK (newline-separated
# KEY="VALUE" lines) into FILE: lines assigning the same keys are replaced,
# every other line is preserved.
account_import_settings_write() {
  local file="$1" block="$2" out="" line="" key="" keys=""
  [[ -n "$block" ]] || return 0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    key="${line%%=*}"
    keys="${keys} ${key}"
  done <<<"$block"
  if [[ -f "$file" ]]; then
    out="$(awk -v keys="$keys" '
      BEGIN {
        n = split(keys, a, " ")
        for (i = 1; i <= n; i++) if (a[i] != "") drop[a[i]] = 1
      }
      {
        k = $0
        sub(/[ \t]*=.*/, "", k)
        gsub(/^[ \t]+|[ \t]+$/, "", k)
        if (k != "" && k in drop) next
        print
      }
    ' "$file")" || die "cannot read ${file}"
  fi
  {
    if [[ -n "$out" ]]; then
      printf '%s\n\n' "$out"
    fi
    printf '# Imported from the Nextcloud desktop client by %s account import.\n' "$CLI_NAME"
    printf '%s\n' "$block"
  } | atomic_write "$file" 600
  return 0
}

# account_pair_flags_dir PROFILE - print the per-pair flag directory an
# imported profile's paused/hidden flags are stored under. An explicit
# PAIR_FLAGS_DIR captured at import start wins, then an exported STATE_DIR
# (tests and overrides); otherwise the profile's state directory is derived
# the way load_settings would, because account import never calls it (the
# profile may not exist yet).
account_pair_flags_dir() {
  local profile="$1" base=""
  if [[ -n "${IMPORT_PAIR_FLAGS_DIR_OVERRIDE:-}" ]]; then
    printf '%s' "${IMPORT_PAIR_FLAGS_DIR_OVERRIDE%/}"
    return 0
  fi
  if [[ -n "${STATE_DIR:-}" ]]; then
    printf '%s/pairs' "${STATE_DIR%/}"
    return 0
  fi
  if [[ "$profile" == "default" ]]; then
    base="${_SCIEBO_CONF_STATE:-${PROJECT_DIR}/state}"
  else
    base="${PROFILES_STATE_DIR%/}/${profile}"
  fi
  printf '%s/pairs' "${base%/}"
}

# account_import_pair_flags FLAGS_DIR NAME PAUSED HIDDEN - persist the
# desktop client's per-folder paused/ignoreHiddenFiles booleans as the pair's
# paused/hidden flags. Best effort: a write problem warns but never fails
# the import, and an unset/false boolean writes nothing.
account_import_pair_flags() {
  local flags_dir="$1" name="$2" paused="$3" hidden="$4"
  local paused_flag="" hidden_flag=""
  account_import_bool_into paused_flag "$paused"
  account_import_bool_into hidden_flag "$hidden"
  [[ "$paused_flag" == "1" || "$hidden_flag" == "1" ]] || return 0
  PAIR_FLAGS_DIR="$flags_dir"
  if [[ "$paused_flag" == "1" ]]; then
    manifest_pair_flags_set "$name" paused 1 ||
      warn "import: could not store the paused flag for '${name}'"
  fi
  if [[ "$hidden_flag" == "1" ]]; then
    manifest_pair_flags_set "$name" hidden 1 ||
      warn "import: could not store the hidden flag for '${name}'"
  fi
  return 0
}

# _account_import_write_settings K - stage 1 of account_import_apply_one:
# create the plan's profile K's directory when it is not the default profile
# (dying when creation fails), set the profile's manifest paths, and write the
# account's settings block into the right settings file. The account_manifest_paths
# assignment into the MANIFEST_*/FILTER_DIR names stays contained by
# account_import_apply_one's shadow locals (dynamic scope), which this stage
# inherits.
_account_import_write_settings() {
  local k="$1" profile="${IMPORT_PLAN_PROFILES[$1]}"
  local dir="" settings_file="" settings_block="${IMPORT_PLAN_SETTINGS[$1]}"
  if [[ "$profile" != "default" ]]; then
    dir="$(account_dir "$profile")"
    account_init_profile "$profile" || die "cannot create profile '$(printable "$profile")' in ${dir}"
  fi
  account_manifest_paths "$profile"
  if [[ -n "$settings_block" ]]; then
    if [[ "$profile" == "default" ]]; then
      settings_file="$SETTINGS_LOCAL_FILE"
    else
      settings_file="${dir}/settings.local.env"
    fi
    account_import_settings_write "$settings_file" "$settings_block"
  fi
}

# _account_import_batch_pairs K FLAGS_DIR - stage 2 of
# account_import_apply_one: dedupe the plan's pairs against the manifest and
# against each other, append the accepted ones in one atomic write, and store
# their per-pair paused/hidden flags. The skipped count accumulates in the
# caller's `skipped` local (declared by account_import_apply_one, which also
# does the status marking). Needs the caller's MANIFEST_* shadow locals in
# dynamic scope, like _account_import_write_settings.
_account_import_batch_pairs() {
  local k="$1" flags_dir="$2"
  local local_path="" remote="" paused="" hidden="" name=""
  # Collect every new pair (skipping names/remotes already present, including
  # earlier pairs in this batch) and append them in one atomic write. The
  # per-pair paused/hidden flags stay one small file each and are written for
  # the accepted pairs only, exactly as the old per-pair append did.
  local -A batch_names=() batch_remotes=()
  local -a batch_records=() pending_flags=()
  local flag_line="" flag_name="" flag_paused="" flag_hidden=""
  while IFS=$'\t' read -r local_path remote paused hidden; do
    [[ -n "$local_path" ]] || continue
    sanitize_name_into name "$remote"
    [[ -n "$name" ]] || name="entry"
    if manifest_has_name "$name" || manifest_has_remote "$remote" ||
      [[ -n "${batch_names[$name]:-}" || -n "${batch_remotes[$remote]:-}" ]]; then
      skipped=$((skipped + 1))
      continue
    fi
    batch_names[$name]=1
    batch_remotes[$remote]=1
    batch_records+=("bisync"$'\t'"$local_path"$'\t'"$remote")
    pending_flags+=("$name"$'\t'"$paused"$'\t'"$hidden")
  done <<<"${IMPORT_PLAN_PAIRS[$k]}"
  if [[ "${#batch_records[@]}" -gt 0 ]]; then
    manifest_append_pairs "${batch_records[@]}"
    for flag_line in "${pending_flags[@]}"; do
      IFS=$'\t' read -r flag_name flag_paused flag_hidden <<<"$flag_line"
      account_import_pair_flags "$flags_dir" "$flag_name" "$flag_paused" "$flag_hidden"
    done
  fi
}

# account_import_apply_one K - create/merge the plan's profile K and write
# its settings and pairs. The manifests are only appended: pairs that
# already exist are counted as skipped and left alone. The stage order is
# fixed: profile creation + settings write (_account_import_write_settings),
# flags dir + index invalidation, pair batch + per-pair flags
# (_account_import_batch_pairs), then the status marking here.
account_import_apply_one() {
  local k="$1" idx="${IMPORT_PLAN_ACCOUNTS[$1]}" profile="${IMPORT_PLAN_PROFILES[$1]}"
  local skipped=0 flags_dir=""
  # The inherited values (exported test/CLI overrides) survive the shadowing;
  # for the default profile account_manifest_paths keeps them.
  # shellcheck disable=SC2034  # read by the manifest helpers via dynamic scope
  local MANIFEST_FILE="${MANIFEST_FILE:-}" FOLDERS_FILE="${FOLDERS_FILE:-}"
  # shellcheck disable=SC2034  # read via dynamic scope by the manifest helpers
  local MANIFEST_GENERATED_FILE="${MANIFEST_GENERATED_FILE:-}" FILTER_DIR="${FILTER_DIR:-}"
  _account_import_write_settings "$k"
  flags_dir="$(account_pair_flags_dir "$profile")"
  manifest_index_invalidate
  _account_import_batch_pairs "$k" "$flags_dir"
  IMPORT_PLAN_SKIPPED[k]="$skipped"
  IMPORT_PLAN_APPLIED[k]="1"
  IMPORT_PLAN_STATUS[k]="applied"
  return 0
}

# account_import_any_blocked - true when any planned target already exists.
account_import_any_blocked() {
  local k=0
  for ((k = 0; k < ${#IMPORT_PLAN_PROFILES[@]}; k++)); do
    if [[ "${IMPORT_PLAN_BLOCKED[$k]}" == "yes" ]]; then return 0; fi
  done
  return 1
}

# account_import_blocked_names - print the profiles that would be merged,
# comma-separated (for the confirmation prompt).
account_import_blocked_names() {
  local k=0 names="" profile=""
  for ((k = 0; k < ${#IMPORT_PLAN_PROFILES[@]}; k++)); do
    [[ "${IMPORT_PLAN_BLOCKED[$k]}" == "yes" ]] || continue
    profile="${IMPORT_PLAN_PROFILES[$k]}"
    names="${names:+${names}, }${profile}"
  done
  printf '%s' "$names"
  return 0
}

# account_import_render_text DRY - print the plan/result report: header line,
# one block per planned account through account_import_render_account, and
# the dry-run footer.
account_import_render_text() {
  local dry="$1" k=0 p_file=""
  p_file=${ printable "$IMPORT_FILE";}
  if [[ "$dry" -eq 1 ]]; then
    printf 'Import plan from %s (dry run; nothing will be written):\n' "$p_file"
  else
    printf 'Import from %s:\n' "$p_file"
  fi
  for ((k = 0; k < ${#IMPORT_PLAN_PROFILES[@]}; k++)); do
    account_import_render_account "$k" "$dry"
  done
  if [[ "$dry" -eq 1 ]]; then
    printf 'Dry run: nothing was written; re-run without --dry-run to apply.\n'
  fi
  return 0
}

# account_import_render_account K DRY - one account's block of the text
# plan/result report: the profile/user/status line, the settings line, the
# pair lines with paused/hidden notes, the skipped/blocked notes, and the
# authenticate hint. All plan data comes from the IMPORT_PLAN_* globals; DRY
# only selects the blocked-account note.
account_import_render_account() {
  local k="$1" dry="$2" line="" joined="" local_path="" remote="" paused="" hidden=""
  local flag_word="will be" p_profile="" p_user="" p_local="" p_remote=""
  local paused_flag="" hidden_flag=""
  p_profile=${ printable "${IMPORT_PLAN_PROFILES[$k]}";}
  p_user=${ printable "${IMPORT_PLAN_USERS[$k]:--}";}
  printf '  [%s] account %s (%s): %s\n' \
    "$p_profile" "${IMPORT_PLAN_ACCOUNTS[$k]}" \
    "$p_user" "${IMPORT_PLAN_STATUS[$k]}"
  joined=""
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    joined="${joined}${line} "
  done <<<"${IMPORT_PLAN_SETTINGS[$k]}"
  [[ -z "$joined" ]] || printf '    settings: %s\n' "${joined% }"
  if [[ "${IMPORT_PLAN_APPLIED[$k]}" == "1" ]]; then flag_word="stored"; else flag_word="will be stored on apply"; fi
  while IFS=$'\t' read -r local_path remote paused hidden; do
    [[ -n "$local_path" ]] || continue
    p_local=${ printable "$local_path";}
    p_remote=${ printable "$remote";}
    printf '    pair: %s -> %s (bisync)\n' "$p_local" "$p_remote"
    account_import_bool_into paused_flag "$paused"
    account_import_bool_into hidden_flag "$hidden"
    if [[ "$paused_flag" == "1" ]]; then
      printf "    note: pair '%s' is paused in the desktop client; paused flag %s\n" \
        "$p_local" "$flag_word"
    fi
    if [[ "$hidden_flag" == "1" ]]; then
      printf "    note: pair '%s' ignores hidden files in the desktop client; hidden flag %s\n" \
        "$p_local" "$flag_word"
    fi
  done <<<"${IMPORT_PLAN_PAIRS[$k]}"
  if [[ "${IMPORT_PLAN_SKIPPED[$k]:-0}" -gt 0 ]]; then
    printf '    note: %s pair(s) already configured; not added again\n' "${IMPORT_PLAN_SKIPPED[$k]}"
  fi
  if [[ "${IMPORT_PLAN_BLOCKED[$k]}" == "yes" ]]; then
    if [[ "${IMPORT_PLAN_APPLIED[$k]}" == "1" ]]; then
      printf '    note: existing profile or manifest merged (--yes)\n'
    elif [[ "$dry" -eq 1 ]]; then
      printf '    note: existing profile or manifest; re-run with --yes to merge\n'
    fi
  fi
  printf '    next: %s\n' "$(account_import_authenticate_hint "${IMPORT_PLAN_PROFILES[$k]}")"
}

# account_import_authenticate_hint PROFILE - print the one-line follow-up
# needed to add the app password the import cannot read (empty profile
# string means the default profile and omits --profile).
account_import_authenticate_hint() {
  local profile="$1" scope=""
  [[ "$profile" == "default" || -z "$profile" ]] || scope=" --profile ${profile}"
  printf "run '%s%s setup --login' or '%s%s setup --rotate' to add the app password" \
    "$CLI_NAME" "$scope" "$CLI_NAME" "$scope"
  return 0
}

# account_import_render_json DRY - print {"imports":[...]} with one object
# per planned account through account_import_render_json_account.
account_import_render_json() {
  local dry="$1" k=0 dry_word="false"
  [[ "$dry" -eq 1 ]] && dry_word=true
  output_json_begin
  output_json_kv_raw "dry_run" "$dry_word"
  output_json_array_begin "imports"
  for ((k = 0; k < ${#IMPORT_PLAN_PROFILES[@]}; k++)); do
    account_import_render_json_account "$k"
  done
  output_json_array_end
  output_json_end
  return 0
}

# account_import_render_json_account K - one account's object of the JSON
# plan/result report: identity/status fields, the settings array, the pairs
# array (with booleans), and the authenticate hint. All plan data comes from
# the IMPORT_PLAN_* globals; the dry flag is published once in the header by
# account_import_render_json.
account_import_render_json_account() {
  local k="$1" line="" local_path="" remote="" paused="" hidden=""
  local paused_flag="" hidden_flag=""
  output_json_object_begin
  output_json_kv "account" "${IMPORT_PLAN_ACCOUNTS[$k]}"
  output_json_kv "user" "${IMPORT_PLAN_USERS[$k]}"
  output_json_kv "url" "${IMPORT_PLAN_URLS[$k]}"
  output_json_kv "profile" "${IMPORT_PLAN_PROFILES[$k]}"
  output_json_kv "status" "${IMPORT_PLAN_STATUS[$k]}"
  output_json_kv_bool "applied" "${IMPORT_PLAN_APPLIED[$k]}"
  output_json_kv_bool "blocked" "$([[ "${IMPORT_PLAN_BLOCKED[$k]}" == "yes" ]] && printf '1')"
  output_json_kv_raw "skipped" "${IMPORT_PLAN_SKIPPED[$k]:-0}"
  output_json_array_begin "settings"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    output_json_array_string "$line"
  done <<<"${IMPORT_PLAN_SETTINGS[$k]}"
  output_json_array_end
  output_json_array_begin "pairs"
  while IFS=$'\t' read -r local_path remote paused hidden; do
    [[ -n "$local_path" ]] || continue
    output_json_object_begin
    output_json_kv "local" "$local_path"
    output_json_kv "remote" "$remote"
    output_json_kv "mode" "bisync"
    account_import_bool_into paused_flag "$paused"
    account_import_bool_into hidden_flag "$hidden"
    output_json_kv_bool "paused" "$paused_flag"
    output_json_kv_bool "hidden" "$hidden_flag"
    output_json_object_end
  done <<<"${IMPORT_PLAN_PAIRS[$k]}"
  output_json_array_end
  output_json_kv "next" "$(account_import_authenticate_hint "${IMPORT_PLAN_PROFILES[$k]}")"
  output_json_object_end
}

# account_import_confirm_gate DRY YES - confirm overwriting existing
# profiles/manifests before a real (non-dry) import run without --yes: an
# interactive text run asks once and sets IMPORT_ABORTED on a decline;
# anything else (non-interactive, or --json) is a usage error. A dry run or
# --yes passes without prompting. JSON mode is checked before the shared
# soft gate because that helper has no JSON model: it would prompt where
# --json must fail instead.
account_import_confirm_gate() {
  local dry="$1" yes="$2"
  IMPORT_ABORTED=0
  if [[ "$dry" -eq 0 && "$yes" -eq 0 ]] && account_import_any_blocked; then
    if output_json_enabled; then
      usage_error account "import: refusing to overwrite existing profile(s)/manifest(s) without --yes"
    fi
    ui_confirm_mutation_soft account \
      "import: refusing to overwrite existing profile(s)/manifest(s) without --yes" \
      "overwrite existing profile(s)/manifest(s) ($(account_import_blocked_names))?" \
      "aborted, nothing changed" ||
      IMPORT_ABORTED=1
  fi
  return 0
}

# account_import_apply_plan DRY - the apply phase between the confirm gate
# and the report: walk every planned account and mark it aborted when the
# gate declined, planned when this is a dry run, or applied through
# account_import_apply_one. Only the per-account status writes live here; the
# gate itself stays in account_import_confirm_gate.
account_import_apply_plan() {
  local dry="$1" k=0
  for ((k = 0; k < ${#IMPORT_PLAN_PROFILES[@]}; k++)); do
    if [[ "$IMPORT_ABORTED" -eq 1 ]]; then
      IMPORT_PLAN_APPLIED[k]="0"
      IMPORT_PLAN_STATUS[k]="aborted"
      continue
    fi
    if [[ "$dry" -eq 1 ]]; then
      IMPORT_PLAN_APPLIED[k]="0"
      IMPORT_PLAN_STATUS[k]="planned"
      continue
    fi
    account_import_apply_one "$k"
  done
  return 0
}

# account_import - `account import` entry point: parse the config, plan one
# profile per configured account, confirm overwrites, and apply.
account_import() {
  local cfg="" selector="" dry=0 yes=0
  opt_begin "nextcloud-cfg:s profile:s dry-run:b yes:b json:b" account "import: " "$@"
  [[ -z "$OPT_EXTRA" ]] || usage_error account "import: unexpected argument: ${OPT_EXTRA%%$'\n'*}"
  opt_into dry dry_run 1
  opt_into yes yes 1
  opt_json_mode
  selector="${OPT_profile:-${SCIEBO_PROFILE:-}}"
  cfg="${OPT_nextcloud_cfg:-${NEXTCLOUD_CFG:-}}"
  account_import_find_config "$cfg"
  account_import_parse "$IMPORT_FILE"
  account_import_collect
  if [[ -z "$IMPORT_ACCOUNT_INDICES" ]]; then
    die "no accounts found in $(printable "$IMPORT_FILE") (expected [Accounts] entries)"
  fi
  account_import_assign_names
  account_import_selected "$selector"
  # Capture an explicit flag directory before any per-profile derivation; the
  # default (empty) then follows the target profile's state directory.
  IMPORT_PAIR_FLAGS_DIR_OVERRIDE="${PAIR_FLAGS_DIR:-}"
  IMPORT_ENFORCE_ROOT=0
  [[ "$dry" -eq 1 ]] || IMPORT_ENFORCE_ROOT=1
  account_import_build_plan
  account_import_confirm_gate "$dry" "$yes"
  account_import_apply_plan "$dry"
  if output_json_enabled; then
    account_import_render_json "$dry"
  else
    account_import_render_text "$dry"
  fi
  return 0
}

# account_cache_stamp - print the capabilities cache's mtime as a local
# timestamp, or nothing when there is no cache. Never fails; thin delegate
# to the shared epoch shim over file_mtime_or.
account_cache_stamp() {
  local mtime=""
  mtime=${ file_mtime_or "${CAPABILITIES_CACHE:-}" "";}
  [[ -n "$mtime" ]] || return 0
  epoch_to_stamp_or_raw "$mtime" '%Y-%m-%d %H:%M:%S'
  return 0
}

# account_cache_age - print the age of the capabilities cache in seconds
# (`123s`), `none` when no cache exists, or `unknown` when its timestamp
# cannot be read. Never fails.
account_cache_age() {
  local cache="${CAPABILITIES_CACHE:-}" mtime="" now=""
  if [[ -z "$cache" || ! -f "$cache" ]]; then
    printf 'none'
    return 0
  fi
  mtime=${ file_mtime_or "$cache" "";}
  if [[ -z "$mtime" ]]; then
    printf 'unknown'
    return 0
  fi
  now="$(now_epoch)"
  printf '%ss' "$((now - mtime))"
  return 0
}

# account_info - print the server-side account facts for the active remote:
# id, display name, email, server base, quota (best effort), and the cached
# capabilities version. --json prints a JSON document instead.
account_info() {
  local json=0 quota="" server_version=""
  opt_begin "json:b" account "" "$@"
  [[ -z "$OPT_EXTRA" ]] || usage_error account "unexpected argument: ${OPT_EXTRA%%$'\n'*}"
  opt_into json json 1
  http_load_context
  nc_user_info
  quota="$(rclone_cmd about "${RCLONE_REMOTE}:" 2>/dev/null)" || quota=""
  quota="$(trim "${quota//$'\n'/ }")"
  if capabilities_load 2>/dev/null; then
    server_version="${CAP_VERSION:-}"
  fi
  if [[ "$json" -eq 1 ]]; then
    output_mode_set true
    output_json_begin
    output_json_kv "id" "$NC_USER_ID"
    output_json_kv "display_name" "$NC_USER_DISPLAY"
    output_json_kv "email" "$NC_USER_EMAIL"
    output_json_kv "server" "$HTTP_BASE"
    output_json_kv "quota" "$quota"
    output_json_kv "server_version" "$server_version"
    output_json_end
    return 0
  fi
  printf '%-15s %s\n' "ID" "${NC_USER_ID:--}"
  printf '%-15s %s\n' "DISPLAY NAME" "${NC_USER_DISPLAY:--}"
  printf '%-15s %s\n' "EMAIL" "${NC_USER_EMAIL:--}"
  printf '%-15s %s\n' "SERVER" "$HTTP_BASE"
  printf '%-15s %s\n' "QUOTA" "${ printable "${quota:--}";}"
  [[ -z "$server_version" ]] || printf '%-15s %s\n' "SERVER VERSION" "$server_version"
  return 0
}

# account_avatar - download the active user's avatar to a local file and
# print the path. The image never reaches stdout; the default target is
# ./avatar-<user>.png and the default size is AVATAR_SIZE (fallback 128).
account_avatar() {
  local file="" size=""
  opt_begin "output:s size:s" account "" "$@"
  [[ -z "$OPT_EXTRA" ]] || usage_error account "unexpected argument: ${OPT_EXTRA%%$'\n'*}"
  size="${OPT_size:-}"
  if [[ -z "$size" ]]; then
    size="${AVATAR_SIZE:-}"
    case "$size" in '' | 0 | *[!0-9]*) size=128 ;; esac
  fi
  case "$size" in
    '' | *[!0-9]*) usage_error account "--size requires a positive integer" ;;
  esac
  [[ "$size" -gt 0 ]] || usage_error account "--size requires a positive integer"
  http_load_context
  file="${OPT_output:-}"
  [[ -n "$file" ]] || file="./avatar-${HTTP_USER}.png"
  [[ ! -L "$file" ]] || die "refusing to write avatar through symlink: ${file}"
  nc_avatar_download "$file" "$size"
  printf '%s\n' "$file"
  return 0
}

# account_status - report the local account wiring: whether the rclone
# remote is configured, whether the server answers (`rclone lsd`), the
# capabilities cache age, and the active keychain backend. Exit 1 when the
# server is not reachable. --json prints the same facts as a JSON document.
account_status() {
  local json=0 configured="no" reach="FAIL" backend="" age="" stamp=""
  opt_begin "json:b" account "status: " "$@"
  opt_guard account "status: "
  opt_into json json 1
  load_settings
  if remote_configured; then configured="yes"; fi
  if [[ "$configured" == "yes" ]] && rclone_cmd lsd "${RCLONE_REMOTE}:" >/dev/null 2>&1; then
    reach="PASS"
  fi
  age="$(account_cache_age)"
  stamp="$(account_cache_stamp)"
  backend="$(keychain_backend)"
  if [[ "$json" -eq 1 ]]; then
    output_mode_set true
    output_json_begin
    output_json_kv "remote" "${RCLONE_REMOTE:-}"
    output_json_kv_bool "configured" "$([[ "$configured" == "yes" ]] && printf '1')"
    output_json_kv_bool "reachable" "$([[ "$reach" == "PASS" ]] && printf '1')"
    output_json_kv "capabilities_cache_age" "$age"
    output_json_kv "last_check" "$stamp"
    output_json_kv "keychain_backend" "${backend:--}"
    output_json_end
    [[ "$reach" == "PASS" ]] || return 1
    return 0
  fi
  printf 'remote configured: %s\n' "$configured"
  printf 'server reachable: %s\n' "$reach"
  printf 'capabilities cache age: %s\n' "$age"
  printf 'keychain backend: %s\n' "${backend:--}"
  [[ "$reach" == "PASS" ]] || return 1
  return 0
}

cmd_account() {
  local sub="${1:-list}" name=""
  [[ $# -gt 0 ]] && shift
  # Dispatcher-level help exits here, before any dependency loads, so
  # `sciebo account --help` parses none of them.
  case "$sub" in
    -h | --help)
      usage_account
      exit 0
      ;;
  esac
  # Run dependencies for the subcommand handlers (each handler's opt_begin
  # consumed sub-level --help): the server-facing helpers use
  # http/nc_api/capabilities, the confirmations prompt through ui's soft
  # and tty gates, and the import path walks the manifest.
  case "$sub" in
    list)
      [[ $# -eq 0 ]] || usage_error account "unknown option: $1"
      account_list
      ;;
    add)
      [[ $# -gt 0 ]] || usage_error account "a profile name is required"
      name="$1"
      shift
      account_add "$name" "$@"
      ;;
    import)
      account_import "$@"
      ;;
    remove)
      [[ $# -gt 0 ]] || usage_error account "a profile name is required"
      name="$1"
      shift
      account_remove "$name" "$@"
      ;;
    use)
      [[ $# -gt 0 ]] || usage_error account "a profile name is required"
      name="$1"
      shift
      account_use "$name" "$@"
      ;;
    info)
      account_info "$@"
      ;;
    avatar)
      account_avatar "$@"
      ;;
    status)
      account_status "$@"
      ;;
    *)
      usage_unknown_sub account "$sub"
      ;;
  esac
  return 0
}
