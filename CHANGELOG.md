# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- New commands: `announcements` (server news), `preview` (thumbnail by file
  id), `download` (resumable single file or directory), and `update` (git
  `--check`/fast-forward of the local checkout).
- Transfer resilience: `RETRIES_SLEEP` (`--retries-sleep`),
  `TRANSFER_PARTIAL` (`--partial`), and `TRANSFER_INPLACE` (`--inplace`);
  `verify` now passes retry/timeout flags; interrupted downloads can resume.
- Extended sharing: `share deck`, typed `share search`
  (email/federated/circle/Talk, with a user/group fallback), link
  `--download 0|1` (hide-download attribute), and `share update --label`.
- `open --web SUB` opens a remote file's `/index.php/f/<fileid>` link and
  falls back to the Files-app folder URL.
- HTTP/DAV robustness: GET/HEAD follow up to `HTTP_MAX_REDIRS` redirects
  (writes never do, so a redirected POST cannot drop its body); curl retries
  transient errors with `--retry-all-errors` and `HTTP_RETRY_DELAY`; XML
  extraction is namespace-tolerant and decodes numeric entities (`&#39;`);
  capabilities parsing brace-matches nested JSON objects instead of using a
  `[^}]*` regex; new actionable hints for 400/409/412/413/415/502/504.
- Nextcloud desktop parity: `share`, `notifications`, `activity`, `presence`,
  `lock`/`unlock`/`locks`, `quota`, `open`, and `conflicts` commands.
- Non-interactive provisioning: `provision --userid USER --apppassword PASS
  --serverurl URL [--localdirpath PATH] [--remotedirpath PATH]
  [--isvfsenabled 0|1] [--profile NAME]` creates or updates a profile and its
  rclone remote and, when `--localdirpath` is given, one `bisync` pair.
  `--isvfsenabled 1` is accepted and ignored (there are no virtual files); the
  password is never printed and lands in the keychain or obscured in the
  rclone config like `setup`.
- Desktop-client migration: `account import [--nextcloud-cfg FILE]
  [--profile SELECTOR] [--dry-run] [--yes] [--json]` reads `nextcloud.cfg`,
  maps `[Accounts]` to profiles (account 0 becomes `default`), folder entries
  to `bisync` pairs, and the known `[General]` options (chunk sizes, timeout,
  `moveToTrash`, delete threshold, login start, big-folder size, debug
  logging) to `settings.local.env`. Passwords are never imported; finish with
  `setup --login` or `setup --rotate` per profile.
- Per-source logs: `logs list|show NAME|tail NAME|path [NAME]` with
  `--lines N` and `--json`; read-only, preferring the log recorded by the last
  run and falling back to the newest normal or dry-run log.
- "Edit locally": `edit SUB [--editor CMD] [--no-upload] [--lock]` downloads
  one file below a configured source, opens an editor, and uploads it again
  when it changed. Without an editor it uses the platform opener and skips the
  upload; `--lock` takes a WebDAV lock around the edit.
- "Not synced" list: `ignored [SUB] [--source NAME] [--json]` lists the local
  files sync would not transfer, with the same filter layering.
- Pending shares: `share pending [--local|--remote] [--json]`,
  `share accept ID [--remote]`, and `share decline ID [--remote] [--yes]`,
  covering local `/shares/pending` and federated `/remote_shares/pending`
  lists with the older shared-with-me fallback.
- Notification parity: `notifications --action ID LABEL` runs the action the
  server attached, `--app`/`--type` are allowlists with `NOTIFY_APPS`/
  `NOTIFY_TYPES` defaults, plus `--unseen`, `--limit`, `--json`, and a
  foreground `--watch [N]` (default `NOTIFY_WATCH_INTERVAL`).
- Desktop-parity policies with safe defaults: `INVALID_NAME_POLICY=exclude`,
  `CASE_CLASH_POLICY=exclude|warn|rename` (rename quarantines a case-clash
  loser as `<name> (case conflict)<ext>`), `E2EE_POLICY=exclude`,
  `EXTERNAL_STORAGE_POLICY=ask`, `SYMLINK_POLICY=skip`, `CHECKSUM=0`,
  `MOVE_TO_TRASH=0` with `LOCAL_TRASH_DIR`, `BIG_FOLDER_POLICY=ask` and
  `BIG_FOLDER_EXISTING_POLICY=warn` with `BIG_FOLDER_SIZE`, the delete guard
  (`ASK_DELETE=1`, `DELETE_FILES_THRESHOLD=100`, `sync --yes`), upload chunk
  bounds (`MIN_CHUNK_SIZE`/`MAX_CHUNK_SIZE` clamp `CHUNK_SIZE`), and
  `PROXY_TYPE` (`system|none|http|socks5`).
- `doctor` reports the effective policies plus per-source E2EE and
  external-storage scans, local case clashes, the delete guard, and big
  folders; `doctor --json` adds structured policy objects.
- Run-level upload chunk derivation: with `CHUNK_SIZE` unset and a Nextcloud
  remote, the desktop `TARGET_CHUNK_UPLOAD_DURATION` (milliseconds) times the
  effective upload throughput (`BW_LIMIT_UP`, or the new
  `TARGET_UPLOAD_THROUGHPUT`) selects one chunk size for the whole run,
  capped at the server's maximum and clamped to
  `MIN_CHUNK_SIZE`/`MAX_CHUNK_SIZE`. Without a throughput the capability
  maximum is used; `TARGET_CHUNK_UPLOAD_DURATION` is no longer an
  effect-free compatibility setting.
- `conflicts` gains a case-clash kind (`--kind copy|case|all`) and `--open` to
  open each containing directory; `folders choose` applies the big-folder,
  external-storage, and E2EE policies to proposed pairs.
- Remote-side case-clash detection: `conflicts --kind case --remote` lists
  remote paths that differ only by ASCII case (read-only, `rclone lsf -R`,
  bounded by `POLICY_CASE_SCAN_LIMIT`), and the opt-in
  `CASE_CLASH_REMOTE_SCAN=1` applies the same `CASE_CLASH_POLICY` decision
  during a sync preflight. Remote paths are never renamed, so `rename`
  excludes the losing path there; the scan is off by default because a full
  remote listing is expensive.
- `nextcloudcmd` fidelity: `-v`/`--version` prints the version, `--verbose` is
  the debug alias, `--exclude-anchored FILE` reads patterns anchored at the
  sync root, `--confdir DIR` redirects the configuration base, and
  `--max-sync-retries N` loops the whole sync while a dry-run probe still
  reports changes.
- Hardening: HTTP/OCS failures carry actionable hints (401 -> `setup
  --rotate`, 423 -> `locks`/`unlock`, 429/503 with `Retry-After`, 507 for a
  full storage/quota); the capabilities probe honors `TLS_INSECURE`, the proxy
  settings, and the timeouts; `folders list --json` and `folders remove
  --purge`; `server capabilities --json`; `account status --json`;
  `watch --no-notify`; and `trash rm` asks on a terminal.
- Always-on path: `watch` (foreground change detection with fswatch or
  inotifywait when installed and portable polling otherwise, debounce and
  per-source rate limiting, and a notify-only remote poll) and `schedule
  install --at-login|--profiles` for login agents and one periodic agent per
  profile.
- Bandwidth control: `limit`/`unlimited` runtime markers and the `BW_SCHEDULE`
  timetable, with marker > schedule > static caps precedence.
- Metered networks and disk guards: `network`, `METERED_POLICY`/`METERED_SSIDS`
  gating (including `sync --metered-ok`), `MIN_FREE_SPACE`/
  `FREE_SPACE_DOWNLOAD`, and a `doctor` free-space check.
- Selective-sync editing (`folders edit`) and the server exclude list
  (`filters sync`, `FILTER_SERVER_SYNC=1`, staleness in `filters list`).
- Conflict review and resolution: `conflicts --resolve
  keep-local|keep-remote|keep-newest|keep-oldest|keep-both`, dry run by default
  and `--apply`/`--yes` for the destructive step.
- Shares beyond links/users/groups: email, circle, Talk, and federated shares,
  `share copy-internal`, `share incoming`, and `share leave`.
- Server data commands: `file`, `search`, `recent`, `comments`, `favorites`,
  `tags`, and `server`, plus `account info`/`account avatar`.
- Tooling: `config list|get|check|edit`, the `support` debug archive,
  `hydrate`, `cleanup --cache|--support`, `status --json|--watch`, `mounts
  --json`, `doctor --json`, `open --web`, `setup --proxy|--crypt`, the
  `nextcloudcmd` command, and `OWNCLOUD_*` environment aliases for the
  nextcloudcmd/desktop settings they map to (now including the chunk bounds
  and `TARGET_CHUNK_UPLOAD_DURATION`).
- `trash restore|rm|empty` (with confirmation for the destructive forms) and
  `versions --download|--restore|--delete`.
- Multi-account profiles: `account list|add|remove|use`, global `--profile`,
  `logout`, and `setup --rotate` for app-password rotation.
- Global `--trust`, `--non-interactive`, `--debug`, and `--log-file` flags.
- Failure blacklist with `retry` (three-strikes behavior like the desktop
  client), optional `BACKUP_DIR` for pull, and download size guard.
- Per-source run history (`status --history`), `cleanup --junk` for fleeting
  metadata, log rotation via `LOG_MAX_BYTES`, and `state/VERSION` migrations.
- Bounded source parallelism (`MAX_PARALLEL_SOURCES`) and INT/TERM handling
  that releases the lock and stops the active rclone child.
- `folders import` for `nextcloudcmd --unsyncedfolders` lists and
  `SKIP_HIDDEN` for the `nextcloudcmd` hidden-file default.
- Linux adapters for Keychain, notifications, and scheduling where available.
- `make install`, `make dist`, bash/zsh completions, and a man page.
- Test coverage: the fake server serves pending local and federated shares and
  notification actions, with feature suites for provisioning, migration,
  logs, edit, ignored, pending shares, policies, and the hardening changes.
- Sharing parity: `share guest` (type 8), `share send-email ID` (the server's
  sendMail request), `share remote-list [--json]` (accepted federated shares),
  `share list [SUB] [--reshares] [--json]`, a `--send-mail` option on the
  user/group/email/guest/circle/talk/deck/remote creates, and link
  `--file-drop` (upload-only, permission 4) and `--file-request`. Hide-download
  now emits the Nextcloud 30+ `attributes` array
  (`[{"scope":"permissions","key":"download","value":false}]`) and falls back
  to the legacy `{"download":0}` object on older or unknown servers; `share
  search` asks for the guest type too, and `file shares SUB --json` forwards to
  the share JSON.
- Per-pair pause and hidden flags: `folders pause NAME` / `folders resume
  NAME` write a mode-600 `paused`/`hidden` flag file per sanitized pair under
  `PAIR_FLAGS_DIR` (default `<STATE_DIR>/pairs`); `folders list` gains
  `PAUSED`/`HIDDEN` columns and `"paused"`/`"hidden"` JSON fields; `folders
  remove --purge` drops the flag file; and `account import` persists the
  desktop client's per-folder `paused` and `ignoreHiddenFiles`. A paused pair
  is reported as skipped by `sync`/`check` unless `sync --force`, and a hidden
  pair excludes dot-files for that pair alone.
- Mutual TLS, custom trust, and a User-Agent override: `CLIENT_CERT`,
  `CLIENT_KEY`, `CLIENT_KEY_PASSWORD`, `CA_CERT`, and `USER_AGENT`, passed to
  rclone (`--client-cert`, `--client-key`, `--client-pass`, `--ca-cert`,
  `--user-agent`) and to the raw curl calls (including the Login Flow) as
  `--cert`/`--key`/`--pass`/`--cacert`/`-A`. `CLIENT_KEY_PASSWORD` is obscured
  before rclone receives it, and a set PEM path must exist and be readable.
- Server quota warning: `QUOTA_WARN_PERCENT` (integer `0`-`100`, `0` disables)
  makes `sync` warn before the entries and `doctor` report WARN when the quota
  used is at or above the threshold; both share one cached
  `rclone about --json` probe and a probe error only warns.
- `logout --revoke` revokes the active app password server-side (OCS
  `DELETE /core/apppassword`) before the local credentials are removed; a
  failed revoke only warns, so the local logout still runs.
- Bulk lock release: `locks --unlock-all` and `unlock --all` release every
  recorded lock (confirmed, `--yes` non-interactively) and drop the records
  whose `UNLOCK` succeeded, keeping failures for a retry.
- Bulk pending shares: `share accept --all` and `share decline --all`
  (`--remote`, `--yes`) answer every pending share of the selected kind(s);
  `--all` cannot be combined with an explicit id.
- `--progress` on `download`, `hydrate`, and `nextcloudcmd` (`-P`) shows
  rclone's transfer progress, but only on a terminal and never under
  `--quiet`/`--json`/`--silent` or the `--max-sync-retries` probe.
- `folders edit` can now rewrite a pair's paths: `--local PATH` replaces the
  local folder and `--remote SUB` replaces the remote subfolder, renaming the
  pair and its filter. A `--remote` change is refused when initialized bisync
  state no longer matches unless `--force` is given (the stale state is kept;
  re-run `sync --resync`), and duplicate remotes/names are refused.
- The direct-HTTP knobs are registered as settings in `config/settings.env`,
  joining `HTTP_TIMEOUT`/`HTTP_RETRIES`: `HTTP_RETRY_DELAY` spaces curl's
  retries, and `HTTP_FOLLOW_REDIRECTS` (default `1`) lets GET/HEAD follow up to
  `HTTP_MAX_REDIRS` hops while writes never follow, so a redirected POST cannot
  drop its body.

### Changed

- Shared internals: the proxy environment classification/export, the
  single-pass XML/awk layer, the curl client-key `--config` writer
  (`curl_key_pass_config_into`), and TAB record/list splitting (`record_split`)
  are one implementation each; the remaining dead helpers were deleted, and
  `scripts/check-drift.sh` grew checks for the global option specs,
  `docs/commands.md` headings, the completion files, and `usage_*` long
  options.
- More shared internals: the subcommand "does not accept --X" rejection
  (`opt_reject`), the `--password-fd`/`--apppassword-fd` reader
  (`opt_read_fd_secret`), the positional preamble
  (`split_positionals_into`, with `split_command_args` moved to
  `lib/core.sh`), and the "no source named" prefix (`unknown_source_prefix`)
  are one implementation each; `mount`/`umount`/`mounts`, `cleanup`, and
  `setup` now reject unknown options through `opt_guard`. As a result `logs`,
  `status`, `retry`, and `watch` sanitize a source name before printing it,
  so a hostile name cannot inject terminal escapes into that line.
- **Bash 5.3+ is now required.** The interpreter floor moved from 5.0 to 5.3;
  `bin/sciebo` still runs under `#!/usr/bin/env bash` and refuses an older
  interpreter with a clear message (macOS `/bin/bash` is 3.2, so
  `brew install bash` and put it first on `PATH`). Generated launchd/systemd
  units record the resolved bash path, and `scripts/check-bash-min.sh` was
  rewritten to probe the 5.3 features the code relies on and reject a curated
  list of post-5.3 constructs. The pre-5.2 `patsub_replacement` workaround was
  removed, so `&` in a `${var//pat/repl}` replacement now expands to the
  matched text and a literal `&` is written `\&`; the Bash 3.2-era empty-array
  guards were replaced with plain `"${arr[@]}"` expansion. The code also
  adopted forkless command substitution (`var=${ fn "$x"; }`) and
  `BASH_MONOSECONDS` for elapsed time and deadlines (wall-clock `now_epoch`
  stays for user-visible timestamps).
- **The Bash 5.0 floor was introduced here (later raised to 5.3).**
  `bin/sciebo` runs under `#!/usr/bin/env bash` and refuses an older
  interpreter with a clear message (macOS `/bin/bash` is 3.2, so
  `brew install bash` and put it first on `PATH`). Generated launchd/systemd
  units record the resolved bash path, and `scripts/check-bash32.sh` is
  replaced by `scripts/check-bash-min.sh`. The code adopted associative
  arrays, `mapfile`, `${x,,}`/`${x^^}`, namerefs, `wait -n`, and
  `EPOCHSECONDS`.
- Performance: the metered-network probe is memoized, the `stat` flavor is
  detected once, `format_size_bytes` is pure bash, `now_epoch` uses
  `EPOCHSECONDS`, and the logs/doctor/cleanup/activity/blacklist paths no
  longer re-scan per entry (O(n) instead of O(n^2)) with fewer per-row forks.
- Desktop-parity policies are safe by default, so a run now leaves more out
  than before: non-portable names are excluded
  (`INVALID_NAME_POLICY=exclude`), local case-only collisions are resolved by
  excluding the later path (`CASE_CLASH_POLICY=exclude`), E2EE remote folders
  are not transferred (`E2EE_POLICY=exclude`), external storages and newly
  picked big folders ask for confirmation (`EXTERNAL_STORAGE_POLICY=ask`,
  `BIG_FOLDER_POLICY=ask`), and already-configured big folders warn
  (`BIG_FOLDER_EXISTING_POLICY=warn`). Each policy can be relaxed to
  `warn`/`allow` in the settings.
- The delete guard is on by default: `ASK_DELETE=1` with
  `DELETE_FILES_THRESHOLD=100` stops an apply that would delete more files. A
  terminal `sync` asks once; a non-interactive run fails the source unless
  `sync --yes` is given. `sync --yes` now also bypasses this guard (it already
  bypassed the download size guard). `MOVE_TO_TRASH` (off by default), the
  chunk bounds, and `PROXY_TYPE` are new settings.
- `nextcloudcmd -v` now prints the version and `--verbose` is the debug
  logging alias; `--exclude-anchored FILE` reads patterns from a file, and
  `--max-sync-retries N` now loops the whole sync while a dry-run probe still
  reports changes, on top of rclone's `--retries`.
- HTTP and OCS errors now carry an actionable hint (for example 401 suggests
  `setup --rotate`, 423 points at `locks`, 429/503 include `Retry-After`) in
  addition to the status and server message.
- Conflict copies now stay local by default (`CONFLICT_UPLOAD=0`), matching
  the Nextcloud desktop client. Set `CONFLICT_UPLOAD=1` for the old behavior.
- Conflict copies can be reviewed and resolved locally with `conflicts
  --resolve`; `keep-both` renames the copy so it no longer matches
  `CONFLICT_PATTERN` and uploads on the next run.
- Bandwidth resolution is layered: an active `sciebo limit` marker overrides
  `BW_SCHEDULE`, which overrides `BW_LIMIT_UP`/`BW_LIMIT_DOWN`.
- The always-on behavior is explicit: `watch` is a foreground, opt-in command
  and `schedule` stays periodic, so nothing runs in the background unless it
  is started or installed. Nextcloud E2EE remains unimplemented; `setup
  --crypt` is the rclone crypt alternative.
- Direct HTTP calls keep the app password out of the curl argv (netrc temp
  file, mode 600) and the CLI refuses state directories written by a newer
  layout version.
- The clutter filter list follows Nextcloud's `sync-exclude.lst` more
  closely (lock files, partial downloads, editor debris).
- `share remove`/`share leave` and `trash rm` ask on a terminal before they
  run; `--yes` skips the prompt. `share decline` additionally requires
  `--yes` in a non-interactive run because a declined share can be lost.
- Internals were deduplicated behind shared helpers: `opt_help_guard`/
  `opt_guard` for the help and unexpected-argument checks, `record_split` for
  TAB records, `xml_get_any` for prefixed/plain XML spellings,
  `ui_confirm_mutation` for destructive confirmations, `href_decode`, and
  `epoch_to_stamp` for epoch formatting. `cmd_share` was split into one
  helper per subcommand.
- `opt_begin` now collapses the repeated reset/parse/help-guard triple in each
  command parser; `temp_mktemp_into VAR TEMPLATE` replaces the
  command-substitution temp-file creation; `safe_source_file` centralizes the
  owned/non-writable `source` check; `output_json_kv_bool` and the shared
  E2EE/external-storage remote-path engine replace their per-command copies;
  `_policy_case_pair_runs` is shared by the local and remote case-clash
  scanners so their pairing stays identical.
- Performance: log timestamps are cached per second instead of forking `date`
  per line, `manifest_parse_line` no longer forks per field, and
  `blacklist_excluded` returns before any parsing when a source has no
  blacklist record.

- Internal refactor with no behavior change: the Nextcloud-remote detection,
  creation, and validation logic and the DAV filter-exclude stack are shared
  helpers; XML record splitting is reused across comments/tags; and the
  largest command functions (`sync` argv assembly and run pipeline,
  `notifications`, `conflicts`, `mount`, `nextcloudcmd` credentials) were
  decomposed into named helpers. JSON string escaping, epoch formatting, and
  per-record DAV href decoding are now fork-free/memoized, cutting process
  spawns on list-heavy commands.
- The keychain now stores the app password in plaintext under account
  `<remote>#plain` (service `KEYCHAIN_SERVICE`), so HTTP-backed commands read
  it directly and no longer run `rclone reveal` (whose reversible obscured
  value was argv-visible). The rclone config still holds only an obscured
  empty value; a legacy obscured keychain item is migrated once on first use,
  and `logout` deletes both items. With `KEYCHAIN=0` the password stays
  obscured in the rclone config and is still revealed — the residual
  documented in `SECURITY.md` and reported by `doctor`.
- `setup --rotate` and the encrypted-config write paths no longer pass the
  obscured secret in argv: `setup --rotate` uses the placeholder-plus-patch
  path, and an encrypted rclone config is refused with a clear message instead
  of falling back to the argv form. `CLIENT_KEY_PASSWORD` reaches curl through
  a mode-600 `--config` file instead of `--pass`, so the passphrase stays out
  of the process list.
- `ui_confirm_mutation` treats the global `--non-interactive` flag as
  non-interactive even when stdin is a terminal, so a destructive command run
  with `--non-interactive` now fails with the same required-`--yes` usage error
  as a piped run instead of prompting.
- The `sync` download-size guard and delete-guard retry (`ui_confirm_tty`) and
  `share`'s confirmation (`ui_stdin_tty`) honor `SCIEBO_NON_INTERACTIVE` even
  when stdin is a terminal, so a flag-set run takes the same branch as a piped
  one; the `[Y/n]` choose prompts use the shared unified yes dialect.

### Removed

- The dead helpers `version_ge` and `http_date_to_epoch` (and their remaining
  callers) were removed; version checks and HTTP-date handling use the
  surviving shared helpers instead.

### Fixed

- Login-flow control-byte refusal: a control byte in the Login Flow app
  password (or in `CLIENT_KEY_PASSWORD`) is refused before it can travel,
  instead of being passed on.
- Secret-cache invalidation: the in-process plain-app-password cache
  (`HTTP_SECRET_CACHE`, `REMOTE_SECRET_CACHE`) is dropped when the credential
  changes (`http_secret_invalidate`, `remote_secret_invalidate`), so a rotation
  mid-run cannot reuse the old secret.
- State writes are best-effort: a run that cannot write its state or runstate
  record no longer fails on the write alone.
- Lock tokens are validated (no control byte) before they are echoed, matched,
  or sent.
- `safe_source` refuses a FIFO or device before opening it, so sourcing a
  non-regular file cannot block.
- `schedule_profile_list` splits `SCHEDULE_PROFILES` with `read -a`, so a value
  like `*` is validated as a profile name instead of being globbed against the
  working directory.
- Parallel sync workers that die before writing their result are counted as
  failed instead of vanishing from the run summary.
- `rclone_lsf_paths` returns a failure instead of reporting an unreachable
  remote as an empty listing; the remote case-clash preflight now warns when
  the listing fails.
- `watch --remote-interval` reports a failed check as a failure instead of
  "remote differences detected".
- `nextcloudcmd --max-sync-retries` no longer reports success when the
  convergence probe fails.
- `hydrate` now uses the same filter layering as sync (server excludes,
  clutter, pair filter, conflict copies, hidden files, blacklist, `.nosync`).
- `setup`, `setup --rotate`, and `provision` pass the obscured password to
  `rclone config` behind a `--` terminator, so an obscured value starting
  with `-` is no longer parsed as an option (rare, but it failed the run).
- `account add` no longer requires `load_settings` to have run before it
  copies the clutter filter; it falls back to the project filter directory.
- `activity --since` no longer truncates at a single page; it pages through
  the API's `since=` cursor (up to 10 pages of 50) and warns when the cap is
  hit.
- `http_urlencode` is byte-wise again on macOS (multi-byte paths and
  non-ASCII file names encode correctly).
- Empty argument arrays no longer fail under bash 3.2 `set -u`.
- The settings documentation now states that the capabilities probe honors
  `TLS_INSECURE`/`--trust` (only the Login Flow always verifies); the code
  already behaved that way.
- Keychain mode builds the rclone config env name the way rclone does (only
  the option part is underscore-folded), so a remote whose config section
  contains `-` or `.` works; previously the unexportable name was silently
  dropped and the remote failed to authenticate.
- `nextcloudcmd`'s interactive password prompt no longer echoes the typed
  password (it reads through the shared no-echo prompt).
- `doctor` no longer aborts before its tail checks and summary when rclone is
  missing while online; the reachability stage stops the network checks
  without propagating its status.
- The proxy hint printed after `setup --proxy` redacts proxy userinfo, so a
  credentialed proxy does not land in the terminal scrollback or a captured
  log.

### Security

- `--debug` output is scrubbed of `Authorization`/`Cookie`/URL-userinfo before
  it can reach a terminal or the `support` archive.
- Notification action links must stay on the configured origin and known app
  paths; server `sync-exclude.lst` bodies are validated before they become
  rclone filter rules; server/rclone console output is stripped of terminal
  escape bytes.
- A control-byte app password is refused instead of falling back to `curl -u`
  (which exposed it in `ps`); the password always travels in a mode-600 netrc,
  and `provision` gained `--apppassword-fd` to keep it out of the process list.
- Temp files created on non-standard error paths now use the exit-cleanup
  registry, `.env` is chmod 600 before it is sourced, and `--trust` prints an
  explicit warning.
- The `support` debug archive masks proxy credentials (both in settings and in
  the rclone config), plus any URL userinfo in the files it includes; `.env`
  is never included.
- An explicit `http://`/`https://` `PROXY` is handed to the curl and rclone
  children through `HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY` instead of `-x`/
  `--http-proxy`, so proxy credentials no longer appear in the child argv. A
  `socks5://` `PROXY` keeps the explicit flags (environment socks support is
  not guaranteed) and therefore remains argv-visible, as documented.
- `account import` never reads the desktop client's keychain and never writes
  passwords; authentication stays with `setup --login`/`setup --rotate`.
- Capabilities probes now use the same hardened HTTP path as the other
  commands (`TLS_INSECURE`, proxy handling, timeouts, netrc temp file), so
  credentials cannot leak through a different code path.
- HTTP 401 failures point at `setup --rotate` so a revoked or expired app
  password is replaced rather than retried unchanged.
- Profile `settings.local.env` values are shell-quoted with `%q`, so a
  `--base` path containing `$`, quotes, or backticks stays data when the
  profile is sourced.
- The Login Flow response file (it carries the app password) is registered
  with the temp-file cleanup registry, so a signal during the poll cannot
  leave it behind.
- `share --password` values are written to a mode-600 temp file and passed to
  curl as `password@file`; they no longer appear in the curl argv. The
  parallel sync worker output files are created with `mktemp` instead of a
  predictable name, and the launchd command shell-quotes the install path.
- `config edit` runs `$EDITOR` as a program with arguments instead of
  evaluating it as shell code, and `setup` opens the server-supplied login URL
  with `open --` so it cannot be read as an option.
- Every remaining server/rclone-controlled string shown to the terminal is
  stripped of escape bytes: HTTP/OCS error messages and `Retry-After`, lock
  tokens, share ids/URLs, blacklist paths, big-folder and folder-wizard names,
  and the raw capabilities JSON. `file info`/`file activity` now validate the
  remote path like their siblings, and the generated systemd `.path` unit
  quotes a watch path that could inject directives.

- `setup`, `provision`, `nextcloudcmd`, and `setup --crypt` no longer pass the
  reversible obscured app password in `rclone config` argv: a non-secret
  placeholder is written first and the real value is patched into the mode-600
  plaintext config. The argv form remains only as the fallback for an
  encrypted rclone config.
- `rclone_cmd` injects the obscured password through a subshell `export`
  instead of `/usr/bin/env`, and warns once when `--trust` disables TLS
  verification; the Login Flow and capabilities probes warn the same way.
- `doctor` and `network` mask URL userinfo in proxy reports; `support` also
  masks `password2`-style keys.
- Server-reported E2EE subpaths are validated with `safe_remote_path` and
  escaped as rclone globs before they become exclude patterns.
- Platform openers receive `--` before the path, so a path beginning with `-`
  cannot be read as an option. Files that are `source`d (capabilities cache,
  per-profile settings) are refused when not owned by the current user or when
  group/other-writable. `account import` confirms absolute local paths outside
  the configured local root.
- Secret temp files are created through `temp_mktemp_into`, which registers
  them in the caller's shell instead of a command-substitution subshell, so a
  signal can no longer leave an app-password or share-password file behind.
- Every `source`d file (`settings.env`, `settings.local.env`, profile
  settings, and `.env`) goes through `safe_source_file` and is refused when it
  is a symlink or not owned by the user / group- or other-writable; the avatar
  download refuses to write through a symlink, and the rclone-config patch
  rejects control bytes and backslashes.
- The Login Flow validates the server-supplied login URL, poll endpoint, and
  final server URL against the configured origin (http/https only, no leading
  `-`) before opening or POSTing to them, and rclone/crypt stderr shown to the
  terminal is passed through `sanitize_stream` so escape bytes cannot be
  injected.
- Settings, profile, and `.env` files are sourced TOCTOU-safely: after the
  owner/mode/symlink check the verified content is read through the file's own
  open descriptor, so a file swapped between the check and the read is refused
  rather than executed.
- `CLIENT_KEY_PASSWORD` (mutual-TLS client-key passphrase) is written to a
  mode-600 curl `--config` file instead of being passed as `--pass` in the
  argv, for both the HTTP layer and the Login Flow; a control byte is refused
  because curl's config parser cannot carry one safely.
- Display of `rclone`/server stderr is stripped of C0/DEL and stray C1 bytes
  with a UTF-8-aware filter (valid multi-byte characters are preserved), so a
  server-controlled byte sequence cannot inject terminal escapes without
  corrupting non-ASCII names.
- The Login Flow base URL is validated before any curl call: it must be
  non-empty, start with `http://`/`https://`, and not begin with `-`, so a
  crafted `--url` cannot be read as a curl option or address a non-HTTP scheme.
- WebDAV `download` writes to a same-directory mode-600 temp file and refuses
  a symlinked destination, so a failed GET cannot truncate an existing file
  and a symlink cannot redirect the write; `versions --download` and `preview`
  refuse a symlinked destination the same way.
- The TOCTOU-safe `safe_source` (read the verified file through its own open
  descriptor) is propagated to every standalone reader of a `source`d file
  (`account`, `setup`, `capabilities`), so a settings/profile/`.env`/cache file
  swapped between the ownership check and the read is refused everywhere, not
  only in `lib/settings.sh`.
- The obscured app password reaches a child only through the environment:
  `rclone_cmd` exports it in a subshell instead of passing it with
  `/usr/bin/env`, and the rclone-config patch hands the secret to its awk child
  through `ENVIRON` (`VALUE`), so it can never appear in a process argv.
- `preview` writes the binary image body through a same-directory mode-600
  temp file and refuses a symlinked destination, so a crafted target cannot
  redirect the write or truncate an existing file (matching
  `versions --download`).
- `share accept --all` / `share decline --all` reject an explicit share id
  (`--all cannot be combined with a share id`), so a bulk confirmation cannot
  be smuggled into the single-id path.
- Server- and rclone-controlled text shown on the terminal is stripped of
  C0/DEL and stray C1 bytes with a UTF-8-aware filter (valid multi-byte
  characters survive), covering HTTP/OCS messages, lock tokens, share
  ids/URLs, blacklist paths, big-folder names, and the raw capabilities JSON.

### Performance

- Startup and dispatch are cheaper: `bin/sciebo` maps a command to its module
  with a static table (one associative-array lookup instead of a scan of the
  command tree), prints a bare `--version` before loading any module, and loads
  the heavy command libraries lazily.
- Repeated probes are cached and hot loops are forkless: `search`, `doctor`,
  `network`, and the case-clash scanner reuse earlier results, and several
  per-record `grep`/`awk`/`sed` sweeps run in pure bash.
- A shared single-pass XML/awk layer (`_AWK_XML_LIB`, `xml_records`,
  `xml_records_top`) replaced the per-field `xml_get` loops in comments, tags,
  favorites, trash, versions, share, activity, notifications, search, and
  file, and removed the duplicated awk bodies in trash/versions.
- Manifest content is memoized and keyed by each file's mtime/size, the
  manifest index splits uniqueness in pure bash instead of `uniq` pipelines,
  and the E2EE/external-storage policy probes are memoized per property and
  remote subpath (`NC_POLICY_PROP_MISSING`/`NC_POLICY_CACHE`), so a
  multi-entry sync no longer repeats the same PROPFIND. `http_urlencode`,
  `output_json_escape`, `size_suffix_bytes`, and `config_dump_value` are now
  pure bash or one-pass (`awk` only), cutting `awk`/`tr`/`grep`/`head` forks
  on list-heavy and JSON-heavy commands.
- The HTTP layer creates its body/headers/stderr/netrc temp files once per
  top-level process and reuses them across requests, and `Retry-After` is
  parsed only for 429/503, and an empty stderr skips the scrub, so long loops
  (`watch`) stop re-creating and re-scanning temp files per call.
- `size_suffix_bytes` and `epoch_to_stamp` are pure bash (the latter with a
  per-epoch-and-format cache backed by the `strftime` builtin), removing the
  `awk`/`date` forks from the per-entry guards and list-heavy commands; the
  settings key-set lookup is memoized per file and stamp, and the manifest,
  pair-flag, and runstate paths each fork once instead of per record.
- Row-heavy output and recent additions share single-pass helpers:
  `xml_fields`, `blacklist_each_record`, and `doctor_each_entry` replace
  per-record `xml_get`/subshell loops, the share/lock/folder row renderers and
  `opt_begin` adoption trim remaining per-row forks, and manifest parse/flag
  paths no longer fork per field.
- `lib/http.sh` caches the plain app password for the life of the process
  (`HTTP_SECRET_CACHE`, cleared by `http_secret_invalidate` when the credential
  changes), so a long run no longer re-reads the keychain once per request.
- Command modules are loaded lazily: the entrypoint resolves the dispatched
  command to a single `lib/commands/*.sh` file (`_sciebo_module_path`) and a
  module pulls its own dependencies with `sciebo_require_module`, so a
  one-command invocation no longer parses the whole command tree.
- `lib/bigfolder.sh` derives every child folder size from one recursive
  `rclone lsf` listing per scan instead of one listing per child.
- The E2EE/external-storage policy probes stay memoized per property and remote
  subpath, and the forkless row helpers (`xml_fields`,
  `blacklist_each_record`, `doctor_each_entry`) cover the remaining hot rows.

## [0.1.0] - 2026-09-19

Initial versioned snapshot: manifest-driven sync/pull/bisync, folder wizard,
git discovery, Login Flow v2 with Keychain storage, capabilities probe,
filters and `.nosync`, verify/status/pause, launchd scheduling, on-demand
mounts, cleanup, and the read-only trashbin/version listings.

[Unreleased]: https://github.com/example/rclone-sciebo-webdav/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/example/rclone-sciebo-webdav/releases/tag/v0.1.0
