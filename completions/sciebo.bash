# bash completion for the sciebo CLI.
#
# Install: source this file from a bash-completion drop-in, or copy it into
# a completions directory (for example
# ~/.local/share/bash-completion/completions/sciebo). The command list
# mirrors COMMANDS in bin/sciebo; the option lists mirror the usage_*
# functions in lib/commands/*.sh.

_sciebo_commands='setup doctor discover list check sync verify status pause resume folders mount umount mounts cleanup schedule trash versions share notifications activity presence lock unlock locks quota open conflicts retry account logout config support nextcloudcmd watch limit unlimited network filters file search recent comments favorites tags server hydrate provision logs edit ignored announcements preview download update help'

_sciebo_global_opts='--profile --trust --non-interactive --debug --log-file --confdir --log-dir --log-expire --version -V -h --help'

# Options that consume the next word.
_sciebo_value_opts='--profile --log-file --confdir --log-dir --log-expire --url --only --for --depth --local-root --mode --remote --local --include --exclude --folder --mountpoint --download --restore --delete --output --password --expire --note --permissions --label --limit --since --message --emoji --clear-after --base --resolve --kind --keep --size --proxy --profiles --up --down --until --interval --debounce --remote-interval --backend --dest --path --user -u -p --httpproxy --exclude --exclude-anchored --nextcloud-cfg --max-sync-retries --unsyncedfolders --userid --apppassword --apppassword-fd --serverurl --localdirpath --remotedirpath --isvfsenabled --editor --lines --app --type --action --resume --continue'

# Value options that name a local file or directory.
_sciebo_path_opts='--log-file --confdir --log-dir --local --local-root --mountpoint --output --dest --unsyncedfolders --exclude --exclude-anchored --nextcloud-cfg --localdirpath'

_sciebo_takes_value() {
  case " ${_sciebo_value_opts} " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

_sciebo_compgen() {
  local cur="$1"
  shift
  # shellcheck disable=SC2207  # word-splitting the completion list is intended
  COMPREPLY=($(compgen -W "$*" -- "$cur"))
}

_sciebo_filedir() {
  local cur="$1"
  if declare -F _filedir >/dev/null 2>&1; then
    _filedir
  else
    # shellcheck disable=SC2207  # word-splitting the file list is intended
    COMPREPLY=($(compgen -f -- "$cur"))
  fi
}

_sciebo_project_root() {
  local src="${BASH_SOURCE[0]}" dir
  # Fork removal: parameter expansion replaces both dirname execs (a src
  # without a "/" is prefixed with "./" so ${src%/*} yields "."), leaving
  # only the one cd/pwd subshell that resolves this script's own directory.
  case "$src" in
    */*) ;;
    *) src="./$src" ;;
  esac
  dir="$(cd "${src%/*}" 2>/dev/null && pwd)" || return 0
  dir="${dir%/*}"
  [[ -n "$dir" ]] || dir="/"
  [[ -d "${dir}/config" ]] && printf '%s' "$dir"
}

_sciebo_profile_names() {
  local root name
  root="$(_sciebo_project_root)"
  if [[ -n "$root" && -d "${root}/config/profiles" ]]; then
    for name in "${root}/config/profiles"/*/; do
      [[ -d "$name" ]] || continue
      # Fork removal: the glob's trailing "/" is stripped with parameter
      # expansion instead of a basename fork per profile directory.
      printf '%s\n' "${name%/}"
    done
  fi
  printf 'default\n'
}

_sciebo_profiles() {
  local cur="$1" names
  names="$(_sciebo_profile_names)"
  _sciebo_compgen "$cur" "$names"
}

_sciebo_value() {
  local flag="$1" cur="$2"
  case "$flag" in
    --profile) _sciebo_profiles "$cur" ;;
    --mode) _sciebo_compgen "$cur" 'sync pull bisync' ;;
    --resolve) _sciebo_compgen "$cur" 'keep-local keep-remote keep-newest keep-oldest keep-both' ;;
    --kind) _sciebo_compgen "$cur" 'copy case all' ;;
    --isvfsenabled) _sciebo_compgen "$cur" '0 1' ;;
    --backend) _sciebo_compgen "$cur" 'auto fswatch inotify poll' ;;
    *)
      case " ${_sciebo_path_opts} " in
        *" $flag "*) _sciebo_filedir "$cur" ;;
        *) COMPREPLY=() ;;
      esac
      ;;
  esac
}

_sciebo_options_for() {
  local cmd="$1" sub="$2"
  case "$cmd" in
    setup) printf '%s\n' '--login --url --rotate --no-keychain --proxy --crypt' ;;
    provision) printf '%s\n' '--userid --apppassword --apppassword-fd --serverurl --localdirpath --remotedirpath --isvfsenabled --profile' ;;
    logs)
      case "$sub" in
        show | tail) printf '%s\n' '--lines' ;;
        list | '') printf '%s\n' '--json' ;;
        *) printf '\n' ;;
      esac
      ;;
    edit) printf '%s\n' '--editor --no-upload --lock' ;;
    ignored) printf '%s\n' '--source --json' ;;
    doctor) printf '%s\n' '--offline --json' ;;
    discover) printf '%s\n' '--write' ;;
    list) printf '%s\n' '--json' ;;
    check | sync) printf '%s\n' '--apply --dry-run --only --resync --yes --metered-ok --quiet --no-lock --force' ;;
    verify) printf '%s\n' '--only --download --size-only --quiet' ;;
    status) printf '%s\n' '--only --history --json --watch --quiet' ;;
    pause) printf '%s\n' '--for' ;;
    folders)
      case "$sub" in
        add) printf '%s\n' '--remote --local --mode --select --include --exclude --local-root' ;;
        import) printf '%s\n' '--remote --local --mode --local-root --select' ;;
        edit) printf '%s\n' '--local --remote --include --exclude --mode --select --clear --force' ;;
        list) printf '%s\n' '--json' ;;
        remove) printf '%s\n' '--purge' ;;
        '' | choose) printf '%s\n' '--depth --local-root --mode --select --no-fzf --no-dry-run' ;;
        *) printf '\n' ;;
      esac
      ;;
    mount) printf '%s\n' '--folder --mountpoint --ro --foreground --sudo' ;;
    umount) printf '%s\n' '--folder --mountpoint --all --sudo' ;;
    mounts) printf '%s\n' '--folder --check --prune --json' ;;
    cleanup) printf '%s\n' '--logs --uploads --state --junk --cache --support --keep --apply' ;;
    schedule)
      if [[ "$sub" == "install" ]]; then
        printf '%s\n' '--at-login --profiles'
      else
        printf '\n'
      fi
      ;;
    trash)
      case "$sub" in
        restore) printf '%s\n' '--all --yes' ;;
        rm | empty) printf '%s\n' '--yes' ;;
        *) printf '\n' ;;
      esac
      ;;
    versions) printf '%s\n' '--download --output --stdout --restore --delete --yes' ;;
    share)
      case "$sub" in
        link | copy-link) printf '%s\n' '--password --expire --note --permissions --label --download --file-drop --file-request --json' ;;
        user | group | guest | circle | talk | deck | remote) printf '%s\n' '--permissions --note --send-mail --json' ;;
        email) printf '%s\n' '--permissions --note --password --expire --send-password-by-talk --send-mail --json' ;;
        update) printf '%s\n' '--password --remove-password --expire --remove-expire --note --remove-note --permissions --label --download --send-mail' ;;
        list) printf '%s\n' '--reshares --json' ;;
        remote-list) printf '%s\n' '--json' ;;
        remove | leave) printf '%s\n' '--yes' ;;
        pending) printf '%s\n' '--local --remote --json' ;;
        accept) printf '%s\n' '--remote --all' ;;
        decline) printf '%s\n' '--remote --yes --all' ;;
        incoming) printf '%s\n' '--json' ;;
        *) printf '\n' ;;
      esac
      ;;
    notifications) printf '%s\n' '--limit --app --type --unseen --action --delete --delete-all --notify --json --watch --quiet --yes' ;;
    activity) printf '%s\n' '--limit --since --notify --quiet' ;;
    presence)
      if [[ "$sub" == "set" ]]; then
        printf '%s\n' '--message --emoji --clear-after'
      else
        printf '\n'
      fi
      ;;
    unlock) printf '%s\n' '--all --yes' ;;
    locks) printf '%s\n' '--prune --unlock-all --yes' ;;
    quota) printf '%s\n' '--json' ;;
    open) printf '%s\n' '--print --web' ;;
    conflicts) printf '%s\n' '--resolve --only --kind --open --apply --yes --json --quiet' ;;
    retry) printf '%s\n' '--list --all' ;;
    account)
      case "$sub" in
        add) printf '%s\n' '--remote --base' ;;
        import) printf '%s\n' '--nextcloud-cfg --profile --dry-run --yes --json' ;;
        remove) printf '%s\n' '--yes' ;;
        info | status) printf '%s\n' '--json' ;;
        avatar) printf '%s\n' '--output --size' ;;
        *) printf '\n' ;;
      esac
      ;;
    logout) printf '%s\n' '--revoke --yes' ;;
    config)
      case "$sub" in
        list) printf '%s\n' '--json --all' ;;
        get | check) printf '%s\n' '--json' ;;
        *) printf '\n' ;;
      esac
      ;;
    support) printf '%s\n' '--output --no-network --json' ;;
    nextcloudcmd) printf '%s\n' '--path --confdir --user -u --password -p -n --non-interactive --silent -s --trust --httpproxy --exclude --exclude-anchored --unsyncedfolders --max-sync-retries --uplimit --downlimit --logdebug --verbose --progress -P -v --version -h --dry-run' ;;
    watch) printf '%s\n' '--interval --debounce --only --remote-interval --backend --once --notify --no-notify --quiet' ;;
    limit) printf '%s\n' '--up --down --until --show --clear --json' ;;
    network) printf '%s\n' '--json' ;;
    filters)
      case "$sub" in
        sync | list) printf '%s\n' '--json' ;;
        *) printf '\n' ;;
      esac
      ;;
    file)
      case "$sub" in
        info) printf '%s\n' '--json' ;;
        activity) printf '%s\n' '--limit --json' ;;
        shares) printf '%s\n' '--json' ;;
        *) printf '\n' ;;
      esac
      ;;
    search) printf '%s\n' '--limit --json --open' ;;
    recent) printf '%s\n' '--since --limit --json' ;;
    comments) printf '%s\n' '--json --yes' ;;
    favorites) printf '%s\n' '--json' ;;
    tags) printf '%s\n' '--json' ;;
    server)
      case "$sub" in
        info) printf '%s\n' '--json' ;;
        capabilities) printf '%s\n' '--raw --json' ;;
        *) printf '\n' ;;
      esac
      ;;
    hydrate) printf '%s\n' '--dest --dry-run --quiet --json --progress' ;;
    announcements) printf '%s\n' '--limit --no-dismiss --json' ;;
    preview) printf '%s\n' '--output --size' ;;
    download) printf '%s\n' '--dry-run --force --resume --continue --quiet --json --progress' ;;
    update) printf '%s\n' '--check --json' ;;
    *) printf '\n' ;;
  esac
}

_sciebo() {
  local cur prev cmd='' sub='' arg1='' w i expect=0 npos=0
  COMPREPLY=()

  cur="${COMP_WORDS[COMP_CWORD]}"
  prev=''
  [[ "$COMP_CWORD" -gt 0 ]] && prev="${COMP_WORDS[COMP_CWORD - 1]}"

  # --help/-h before the cursor ends completion.
  for ((i = 1; i < COMP_CWORD; i++)); do
    case "${COMP_WORDS[i]}" in
      -h | --help) return 0 ;;
    esac
  done

  # A value option directly before the cursor takes the next word.
  if [[ -n "$prev" ]] && _sciebo_takes_value "$prev"; then
    _sciebo_value "$prev" "$cur"
    return 0
  fi

  case "$cur" in
    --profile=*)
      _sciebo_profiles "${cur#*=}"
      for i in "${!COMPREPLY[@]}"; do
        COMPREPLY[i]="--profile=${COMPREPLY[i]}"
      done
      return 0
      ;;
    --mode=*)
      _sciebo_compgen "${cur#*=}" 'sync pull bisync'
      for i in "${!COMPREPLY[@]}"; do
        COMPREPLY[i]="--mode=${COMPREPLY[i]}"
      done
      return 0
      ;;
  esac

  # Collect the command and its positionals, skipping option values.
  for ((i = 1; i < COMP_CWORD; i++)); do
    w="${COMP_WORDS[i]}"
    if [[ "$expect" -eq 1 ]]; then
      expect=0
      continue
    fi
    case "$w" in
      --*=*) continue ;;
      -*)
        if _sciebo_takes_value "$w"; then
          expect=1
        fi
        continue
        ;;
    esac
    if [[ -z "$cmd" ]]; then
      cmd="$w"
    else
      case "$npos" in
        0) sub="$w" ;;
        1) arg1="$w" ;;
      esac
      npos=$((npos + 1))
    fi
  done

  if [[ -z "$cmd" ]]; then
    _sciebo_compgen "$cur" "$_sciebo_commands $_sciebo_global_opts"
    return 0
  fi

  if [[ "$cur" == -* ]]; then
    _sciebo_compgen "$cur" "$(_sciebo_options_for "$cmd" "$sub") $_sciebo_global_opts"
    return 0
  fi

  case "$cmd" in
    help)
      _sciebo_compgen "$cur" "$_sciebo_commands"
      ;;
    folders)
      case "$sub" in
        '') _sciebo_compgen "$cur" 'choose add import edit list pause resume remove' ;;
        import) _sciebo_filedir "$cur" ;;
        *) COMPREPLY=() ;;
      esac
      ;;
    schedule)
      [[ -n "$sub" ]] || _sciebo_compgen "$cur" 'install uninstall status'
      ;;
    trash)
      [[ -n "$sub" ]] || _sciebo_compgen "$cur" 'list restore rm empty'
      ;;
    share)
      [[ -n "$sub" ]] || _sciebo_compgen "$cur" 'link user group email guest circle talk deck remote list info update remove leave pending accept decline send-email remote-list search copy-link copy-internal incoming'
      ;;
    logs)
      [[ -n "$sub" ]] || _sciebo_compgen "$cur" 'list show tail path'
      ;;
    presence)
      if [[ -z "$sub" ]]; then
        _sciebo_compgen "$cur" 'show set clear'
      elif [[ "$sub" == "set" && -z "$arg1" ]]; then
        _sciebo_compgen "$cur" 'online away dnd offline'
      fi
      ;;
    account)
      if [[ -z "$sub" ]]; then
        _sciebo_compgen "$cur" 'list add import remove use info status avatar'
      elif [[ "$sub" == "remove" || "$sub" == "use" ]]; then
        _sciebo_profiles "$cur"
      fi
      ;;
    config)
      [[ -n "$sub" ]] || _sciebo_compgen "$cur" 'list get check edit'
      ;;
    filters)
      [[ -n "$sub" ]] || _sciebo_compgen "$cur" 'sync list show check'
      ;;
    file)
      [[ -n "$sub" ]] || _sciebo_compgen "$cur" 'info activity shares'
      ;;
    favorites)
      [[ -n "$sub" ]] || _sciebo_compgen "$cur" 'list add remove'
      ;;
    tags)
      [[ -n "$sub" ]] || _sciebo_compgen "$cur" 'list create assign clear'
      ;;
    server)
      [[ -n "$sub" ]] || _sciebo_compgen "$cur" 'info capabilities status'
      ;;
    comments)
      if [[ "$npos" -eq 1 && -z "$arg1" ]]; then
        _sciebo_compgen "$cur" 'list add delete'
      fi
      ;;
    open)
      _sciebo_filedir "$cur"
      ;;
    *)
      COMPREPLY=()
      ;;
  esac
}

_sciebo_complete() {
  _sciebo "$@"
}

complete -F _sciebo sciebo
