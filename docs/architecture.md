# Architecture

How the codebase is put together and where to change it. `sciebo` is plain
Bash: there is no build step, and the entrypoint sources the libraries and
command modules directly. Everything must stay compatible with Bash 5.3+,
which is the floor for associative arrays, `mapfile`, `${var,,}`/`${var^^}`,
namerefs, `wait -n`, `EPOCHSECONDS`, forkless command substitution, and
`BASH_MONOSECONDS`. `scripts/check-bash-min.sh` probes the running
interpreter for the 5.3 features the code relies on and scans `bin/`, `lib/`,
`scripts/`, and `tests/` against a curated list of post-5.3 constructs. That
list is intentionally empty, because Bash 5.3 is the newest stable release, so
the scan is a documented no-op until a post-5.3 construct becomes known.

- [Module map](#module-map)
- [Dispatch and global flags](#dispatch-and-global-flags)
- [Command conventions](#command-conventions)
- [Settings and paths](#settings-and-paths)
- [Manifest model](#manifest-model)
- [Lock design](#lock-design)
- [Run records, history, blacklist, pause](#run-records-history-blacklist-pause)
- [Bandwidth, metered networks, and disk guards](#bandwidth-metered-networks-and-disk-guards)
- [Policy gates](#policy-gates)
- [Automatic sync and scheduling](#automatic-sync-and-scheduling)
- [HTTP / DAV / OCS layer](#http--dav--ocs-layer)
- [Capabilities probe](#capabilities-probe)
- [Profiles](#profiles)
- [Platform backends](#platform-backends)
- [Signals](#signals)
- [Parallelism](#parallelism)
- [State migrations](#state-migrations)
- [Tests](#tests)
- [Adding a command](#adding-a-command)

## Module map

```
bin/sciebo                  entrypoint: shell options, sourcing, dispatch, global
                            flags, signal/EXIT traps
lib/
  core.sh                   paths, logging (log/warn/err with a per-second
                            timestamp cache), die/usage_error (with
                            unknown_source_prefix for the shared
                            source-resolution wording), long-option
                            parser (opt_parse with s/S/b/o kinds, opt_begin,
                            opt_json_mode, opt_help_guard, opt_guard, opt_reject,
                            opt_into, opt_require_uint with an optional
                            custom-message arg,
                            opt_read_fd_secret for the shared
                            --password-fd/--apppassword-fd reader),
                            module loading (sciebo_require_module), pure
                            helpers (sanitize_name/sanitize_name_into,
                            safe_*_path, trim/trim_into, comma_ids_valid,
                            record_split, split_positionals,
                            split_positionals_into, split_command_args,
                            href_decode, href_last_segment,
                            url_redact_userinfo, file_size, size_suffix_bytes,
                            atomic_write, ...), the shared
                            UTF-8 control stripper (_AWK_CTRL_LIB with
                            ctrl_strip, behind sanitize_stream and the HTTP
                            scrubbers), the netrc/curl client helpers
                            (netrc_write_into for a mode-600 password file,
                            curl_client_args_into for the client-cert/CA/
                            user-agent/--config flags), the
                            secret temp-file registry (temp_mktemp_into VAR
                            TEMPLATE; registration happens in the caller's
                            shell, so it must be called as a command and never
                            inside a command substitution), and safe_source
                            (refuse a symlinked or group/other-writable file,
                            then source the verified file through its open
                            descriptor, so a swap between check and read
                            cannot execute different content)
  output.sh                 --json document builders and table-row helpers
                            (output_mode_set, output_json_*, output_rows,
                            escaping)
  duration.sh               duration parsing and epoch helpers
                            (duration_seconds, duration_parse_or_usage with an
                            optional EXAMPLES arg, now_epoch, epoch_to_stamp,
                            epoch_to_stamp_or_raw, duration_human)
  version.sh                the version banner used by support
  settings.sh               layered settings, validation, profile resolution,
                            OWNCLOUD_* aliases, derivation of every
                            config/state path
  rclone.sh                 rclone discovery, rclone_cmd, config
                            introspection, secret reveal (keychain or obscured
                            config), remote metadata (the memoized
                            remote_is_nextcloud, remote_nextcloud_base),
                            size and listing capture (rclone_size_bytes,
                            rclone_remote_size, rclone_capture,
                            rclone_lsf_paths), and argv-free config patching
                            (rclone_config_patch_value)
  platform.sh               backend selection: security/secret-tool/pass,
                            osascript/notify-send, launchd/systemd/cron, and
                            metered-network probes (net_info, net_is_metered,
                            net_gate)
  keychain.sh               app-password storage via the selected backend:
                            the plaintext password under account
                            `<remote>#plain` (HTTP reads it directly, no
                            `rclone reveal`) plus the legacy obscured slot,
                            migrated once on first use
  http.sh                   curl plumbing, netrc handling, the unified
                            single-pass XML walker (the shared _AWK_XML_LIB
                            prelude behind xml_records/xml_records_top/
                            xml_fields and xml_wrapper_auto),
                            json_string_field for compact JSON fields, proxy
                            and HTTP/2 selection
  nc_api.sh                 Nextcloud DAV/OCS domain helpers on top of
                            http.sh: nc_dav_url and
                            nc_dav_request/nc_dav_request_allow for the
                            endpoints outside the files root (trashbin,
                            versions, comments, systemtags, locks), file
                            ids/info, user info, avatars, comments,
                            favorites, tags, search, and the memoized
                            E2EE/external-storage policy probes (one
                            PROPFIND per property and remote subpath per run)
  bw.sh                     bandwidth-limit marker read/write and effective
                            limit precedence
  bigfolder.sh              large unconfigured remote folder scan/notify
                            with a BIGFOLDER_SCAN_TTL scan cache
  capabilities.sh           Nextcloud OCS capabilities probe and cache,
                            capabilities_facts rendering, and the run-level
                            chunk derivation (capabilities_chunk_for_duration)
  policy.sh                 desktop-parity policy gates for name hygiene and
                            local/remote case clashes, plus the shared
                            E2EE/external-storage remote-path engine
                            (policy_remote_paths_apply, choose_policy_decision)
  notify.sh                 desktop notifications via the selected backend
  runstate.sh               per-source last-run records and run history
  blacklist.sh              failure-count records for the sync blacklist
  pause.sh                  pause marker shared by sync and pause/resume
  lock.sh                   single-run lock (mkdir + pid + process start time)
  manifest.sh               manifest format, parsing, index (memoized content
                            keyed by each file's mtime/size stamp, plus a
                            pure-bash unique/duplicate split), writers
                            (manifest_append_pair and the single-atomic-write
                            manifest_append_pairs batch), and the per-pair
                            flag store under PAIR_FLAGS_DIR
                            (paused/hidden, mode 600)
  migrate.sh                state layout version and migrations
  ui.sh                     interactive prompts (ui_ask/ui_confirm,
                            ui_confirm_default_yes for the [Y/n] dialect,
                            ui_confirm_tty for the shared TTY/interactive
                            gate, ui_confirm_mutation for destructive
                            commands, ui_confirm_proceed for mutations a
                            non-interactive caller may continue), and
                            selection parsing
lib/commands/
  setup.sh                  setup
  account.sh                account
  provision.sh              provision (non-interactive account/folder setup)
  logout.sh                 logout
  doctor.sh                 doctor
  discover.sh               discover
  ignored.sh                ignored (locally filtered paths)
  sync.sh                   list, check, sync
  verify.sh                 verify
  status.sh                 status
  pause.sh                  pause, resume
  folders.sh                folders (add/import/list/remove)
  folders_choose.sh         folders choose (browser/picker)
  mount.sh                  mount, umount, mounts
  cleanup.sh                cleanup
  logs.sh                   logs (list/show/tail run logs)
  schedule.sh               schedule (launchd or systemd --user)
  trash.sh                  trash
  versions.sh               versions
  share.sh                  share
  notifications.sh          notifications
  announcements.sh          announcements
  activity.sh               activity
  presence.sh               presence
  lock.sh                   lock, unlock, locks
  quota.sh                  quota
  open.sh                   open
  download.sh               download
  edit.sh                   edit
  preview.sh                preview
  conflicts.sh              conflicts
  retry.sh                  retry
  config.sh                 config (list/get/check/edit)
  support.sh                support (redacted debug archive)
  update.sh                 update (git checkout update)
  nextcloudcmd.sh           nextcloudcmd (nextcloudcmd-compatible bisync)
  watch.sh                  watch
  limit.sh                  limit, unlimited
  network.sh                network
  filters.sh                filters
  file.sh                   file
  search.sh                 search
  recent.sh                 recent
  comments.sh               comments
  favorites.sh              favorites
  tags.sh                   tags
  server.sh                 server
  hydrate.sh                hydrate
config/                     settings, manifests, filters, profile template
launchd/                    launchd plist template for schedule
scripts/sync.sh             compatibility shim for the old entrypoint
scripts/nextcloudcmd        compatibility shim forwarding to
                            `sciebo nextcloudcmd`
scripts/check-bash-min.sh  enforces the Bash 5.3 floor; its post-5.3 construct
                            list is intentionally empty (5.3 is the newest
                            stable release), so the scan is a no-op
scripts/check-drift.sh      checks COMMANDS, require_setting, settings docs and
                            example, global options, command headings, and
                            completions drift (warnings for documentation gaps)
tools/screenshots.py        renders the README/demo SVG screenshots
tests/fake_server.py        local fake Nextcloud (DAV/OCS) for tests
tests/fake_env.sh           starts the fake server and points the CLI at it
tests/                      unit, feature, and integration suites (see below)
```

## Dispatch and global flags

`bin/sciebo`:

1. Sets `set -euo pipefail`, `umask 077`, and rejects a Bash older than 5.3.
2. Describes every global option once in `_SCIEBO_GLOBAL_SPECS`, a table of
   `<flag>[,<alias>...]|<env-var>|<kind>|<early>` records. `value` consumes
   the next argument (or the `--flag=VALUE` form), `flag` sets the variable to
   `1`, `version` prints the version and exits, and `early=1` marks an option
   that must be consumed before `lib/settings.sh` loads.
3. Runs `_sciebo_consume_globals` in `early` mode for the path-affecting
   globals `--confdir`, `--log-dir`, and `--log-expire`, exporting them as
   `SCIEBO_CONFDIR`, `SCIEBO_LOG_DIR`, and `SCIEBO_LOG_EXPIRE_HOURS` *before*
   any library loads, because `lib/settings.sh` derives every path when it is
   sourced. The remaining arguments are preserved for dispatch.
4. Sources the five eager libraries — `lib/core.sh` (the loader and
   foundational helpers), `lib/output.sh` and `lib/duration.sh` (time and
   JSON/row helpers with call sites in nearly every command), `lib/rclone.sh`
   (binary discovery for `load_settings`), and `lib/settings.sh` — then
   lazily sources only the dispatched command module: `_sciebo_module_path`
   looks the command up in
   the static `_SCIEBO_COMMAND_MODULE_SPECS` table (the default
   `lib/commands/<command>.sh`, with overrides for the multi-command modules)
   and falls back to a content scan only when a mapped file is missing; the
   entrypoint sources the resolved file at global scope, so adding a command
   never needs an entrypoint edit and an invocation only parses the code it
   needs. Every other library — `bw`, `keychain` (which pulls `platform`),
   `notify`, `runstate`, `pause`, `migrate`, `lock`, `manifest`, `ui`,
   `version`, plus the heavy `http`, `nc_api`, `bigfolder`, `capabilities`,
   and `policy` — loads on demand through `sciebo_require_module` in the
   function that uses it.
5. `extract_global_flags "$@"` runs the same table in `all` mode for the rest:
   `--profile`, `--trust`, `--non-interactive`, `--debug`, and `--log-file`
   are exported as `SCIEBO_PROFILE`, `TLS_INSECURE`,
   `SCIEBO_NON_INTERACTIVE`, `SCIEBO_DEBUG`, and `SCIEBO_LOG_FILE`, with
   `--version` short-circuiting. `--confdir`/`--log-dir`/`--log-expire` are
   accepted here as well so direct callers keep working.
6. Looks the command up in the `COMMANDS` string and calls `cmd_<command>`
   with the remaining arguments; `help`/`-h`/`--help` call `usage_<command>`
   or `usage_main`. Unknown commands exit 2.
7. Installs INT/TERM handlers and an EXIT trap that release the run lock
   (when a command loaded `lib/lock.sh` by acquiring one; the trap probes
   `type release_lock` first because lock.sh is lazy) and exit 130/143 on
   signals.

The `COMMANDS` list is the single source of truth: dispatch and help lookup
share it, so they cannot drift apart; `scripts/check-drift.sh` verifies that
every entry has a matching `usage_<name>`/`cmd_<name>` pair and that the
completion files list the same commands. Command modules are loaded lazily:
the entrypoint resolves the dispatched command to one file through the static
`_SCIEBO_COMMAND_MODULE_SPECS` table (content scan only as a stale-table
fallback) and sources it, and a module declares its own dependencies with
`sciebo_require_module` — placed in the `cmd_<command>` entry function after
`opt_guard`/`opt_begin`'s `--help` exit (for example `versions.sh` and
`open.sh` require `http.sh`'s `xml_get` in their entries, and `sync.sh`/
`retry.sh` require `blacklist.sh`), or inside a helper that can run without
its entry (cross-module helpers own their own requires). Because the requires
sit after the help guard, `<command> --help` parses neither the command's
dependencies nor any of the lazy libraries, and source-time side effects stay
out of the way.

## Command conventions

- A command module defines `usage_<command>` (a heredoc printed by
  `--help`, and by `usage_error` on bad input) and `cmd_<command>`.
- Commands parse options with `opt_parse "name:kind ..." <command> <label>
  "$@"` (or `opt_begin`, the shared reset/parse/help prologue). Kinds: `s`
  single value, `S` repeatable value, `b` boolean, and `o` optional value
  (`--name` / `--name=VALUE` sets it; otherwise the `NAME:o:DEFAULT` default
  is used without consuming the next token). Parsed values live in
  `OPT_<name>` (dashes become underscores), `OPT_<name>_SET` marks a provided
  option, positional arguments collect in `OPT_EXTRA` (newline-separated),
  and `-h`/`--help` sets `OPT_HELP`; `opt_json_mode` turns the parsed `--json`
  flag into the output mode.
- After parsing, commands call `opt_help_guard <command>` (print the usage and
  exit 0 on `-h`/`--help`). Commands that take no positionals use
  `opt_guard <command> [label]` instead, which also rejects the first
  unexpected argument with `usage_error`; the optional label prefixes the
  message for subcommands (`opt_guard folders "list: "`).
- Command functions return a status; only `die` (message to stderr, exit 1)
  and `usage_error` (usage to stderr, exit 2) exit directly. This is what
  lets the top-level `sync` orchestrate entries and still return a summary.
- Commands never call each other in-process. When one needs another command,
  it spawns `${PROJECT_DIR}/bin/sciebo` (the folder wizard does this for its
  optional dry run).
- Commands source only `lib/` helpers, never another command's internals.
  A module declares its dependencies with `sciebo_require_module` in the
  entry function (after the `--help` exit) or inside a shared helper, so
  sourcing a module for its `usage_<command>` alone loads nothing heavy.
- Module-private globals are prefixed per module (`ENTRY_*`, `MNT_*`, `P_*`,
  `SYNC_*`, `VERIFY_*`, `OPT_*`) and must not collide across modules.
- Every command that talks to the remote calls `load_settings` (or
  `load_settings --no-rclone` for config-only commands) and `require_remote`;
  commands that only inspect configuration must not create state directories.

## Settings and paths

`lib/settings.sh` sources the layers described in
[docs/settings.md](settings.md#precedence) through `safe_source` (owner, mode,
and symlink checked, then read through the verified file's own descriptor),
validates the values, then derives
every path (`MANIFEST_FILE`, `STATE_DIR`, `LOG_DIR`, `FILTER_DIR`, ...) with
`: "${VAR:=default}"`, so environment overrides win. Between the shipped
defaults and the local files, a compatibility layer maps the `OWNCLOUD_*`
names of nextcloudcmd/the desktop client onto settings:
`_sciebo_env_snapshot` records which settings were exported before
`settings.env` was sourced, and `_apply_nextcloud_env_aliases` converts and
copies the aliases (seconds, booleans, or verbatim). An exported sciebo
setting wins over its alias; local and profile assignments win over both.
All path overrides are documented in
[docs/settings.md](settings.md#path-overrides-isolated-runs); the test suites
rely on them for isolation. `PROJECT_DIR`, `CONFIG_DIR`, and `LIB_DIR` come
from `lib/core.sh` and are not overridable.

`--confdir` rebases the configuration: `SCIEBO_CONFDIR` becomes the base for
the settings, manifest, filter, and profile paths and the parent of the
default state (`<confdir>/state`); only the settings file falls back to the
project copy when the confdir has none. `--log-dir` overrides `LOG_DIR`, and
`--log-expire` sets the runtime `LOG_EXPIRE_HOURS` read by `cleanup --logs`
(see [docs/settings.md](settings.md#housekeeping)).

`ensure_state_dirs` creates the state directories and runs
`state_migrations_run` (requiring the lazy `lib/migrate.sh` first); any
command that writes state calls it first.

## Manifest model

`lib/manifest.sh` owns the `mode|local|remote[|filter]` line format:

- `manifest_files` / `manifest_lines` read `MANIFEST_FILE`, `FOLDERS_FILE`,
  `MANIFEST_GENERATED_FILE` in that order.
- `manifest_parse_line` validates a line and fills `ENTRY_MODE`,
  `ENTRY_LOCAL`, `ENTRY_REMOTE`, `ENTRY_FILTER`, `ENTRY_NAME`, or returns 1
  with `ENTRY_ERROR`.
- `manifest_index_load` builds sorted name/remote lists plus duplicate lists
  used by `doctor`, `sync`, and `retry`.
- Writers (`manifest_append_pair`, `manifest_remove_pair`,
  `manifest_write_pair_filter`) only touch `FOLDERS_FILE` and pair filters,
  validate every field again, and replace files atomically.

Entry names are sanitized with `sanitize_name`, which is also used for log
files, bisync workdirs, run records, lock records, and blacklist files; that
is why duplicate names are rejected.

## Lock design

`lib/lock.sh` implements a single-run lock under `LOCK_DIR/sync.lock`:

- Acquisition is atomic (`mkdir`); inside are `pid` and `start` (the
  process's `lstart`).
- A lock is stale only when the pid is gone, the command line no longer looks
  like this tool, or the recorded start time differs (pid recycling). The
  stale directory is renamed aside before removal, so two processes taking
  over concurrently cannot delete a fresh lock.
- `acquire_lock` is reentrant within a process (the outermost holder wins),
  which is why the folder wizard can commit under a lock and callers can
  acquire again safely. `release_lock` only removes a lock owned by the
  current pid and is idempotent, so the EXIT trap can run after a signal
  handler already released it.

`sync` (unless `--no-lock`), `cleanup`, `discover --write`,
`folders add|import|remove|choose`, and the wizard's commit take the lock.
`verify` and `status` never do.

## Run records, history, blacklist, pause

- `lib/runstate.sh` writes one key=value record per source under
  `RUNSTATE_DIR` (`state/last/<name>`) after every entry run: time, stamp,
  mode, status (`ok`/`failed`/`skipped`), rc, conflicts, log path, detail.
  Records are parsed, never sourced. Each write also appends a TAB-separated
  line to `HISTORY_DIR/<name>.log` and trims it to the newest
  `HISTORY_MAX_ENTRIES`.
- `lib/blacklist.sh` tracks failed paths in `BLACKLIST_DIR/<name>` as
  `count<TAB>path<TAB>error`. `sync` adds rclone `--exclude` patterns for
  paths at the threshold; `retry` clears entries. All writes are best effort:
  a state problem must never fail a sync.
- `lib/pause.sh` owns the one-line pause marker (`PAUSE_FILE`,
  `until=<epoch>`; `0` = indefinite). `pause_active` removes an expired
  marker, which is the only write `status` ever performs.

All of these use `atomic_write` with mode 600 and never source user- or
server-controlled text.

## Bandwidth, metered networks, and disk guards

Three guard layers can shape or stop a transfer before rclone runs:

- Bandwidth: `lib/bw.sh` owns the three-line marker (`BW_LIMIT_FILE`, mode
  600: `until`, `up`, `down`). `bw_effective_limit` resolves the value sync
  passes as `--bwlimit` with the precedence active marker > `BW_SCHEDULE` >
  `BW_LIMIT_UP`/`BW_LIMIT_DOWN`; an expired or malformed marker is removed
  best-effort on read. `sciebo limit` writes the marker and `unlimited`
  clears it; no server contact is involved.
- Metered networks: `lib/platform.sh` probes the active connection
  (`route`/`networksetup` on macOS, `nmcli` on Linux), adds `METERED_SSIDS`
  and hotspot-looking names, and `net_gate` turns that into allow/ask/skip
  according to `METERED_POLICY` (0 = proceed, 2 = skip; `--metered-ok` /
  `SCIEBO_METERED_OK=1` override). A skipped entry is recorded as `skipped`,
  never failed.
- Disk space: `sync_disk_guard` reads the local destination with `df -Pk`;
  below `MIN_FREE_SPACE` the entry fails, below `FREE_SPACE_DOWNLOAD` it is
  skipped. `doctor` reports the state filesystem against both thresholds.
  `bigfolder_notify` (`lib/bigfolder.sh`) is the remote counterpart: after a
  pull/bisync entry it scans unconfigured remote subfolders above
  `BIG_FOLDER_SIZE` and warns/notifies once per folder, remembering the
  reported names under `state/bigfolder/`; the scan itself is reused for
  `BIGFOLDER_SCAN_TTL` from a per-name `scan-<name>` cache.

## Policy gates

`lib/policy.sh` centralizes the desktop-parity guards that run before an entry
touches the remote (the settings are in
[docs/settings.md](settings.md#desktop-parity-policies)). Two pieces are
shared:

- `choose_policy_decision POLICY CONFIRMED` is the pure verdict behind every
  allow/warn/ask/skip choice: `allow`/`warn` proceed, `skip`/`exclude` skip,
  and `ask` proceeds only with a confirmation, so the caller decides how a TTY
  or non-interactive run answers.
- `policy_remote_paths_apply` is the one E2EE / server-mounted-external-storage
  engine behind the sync preflight, `doctor`, and the folder wizard. Callers
  choose a style (`apply`, `collect`, or `wizard`), a message sink, and an
  optional confirm callback through `POLICY_REMOTE_*` globals, and read the
  shared result state (`POLICY_REMOTE_RESULT`, `POLICY_REMOTE_PATHS`,
  `POLICY_REMOTE_SKIP_REASON`, ...) to phrase their own report.

Case-only collisions are scanned locally by `policy_case_clashes` and, with
`CASE_CLASH_REMOTE_SCAN=1` or `conflicts --kind case --remote`, on the remote
by `policy_case_clashes_remote` (a bounded `rclone lsf -R` listing). A local
scan walks the tree with find/awk/sort once, then memoizes the pairs for the
life of the process in a random `mktemp -d` cache directory on disk, so the
repeated per-entry scans the `sync` and `doctor` callers make from
command-substitution subshells become a file read instead of another walk; the
directory is revalidated (a real, owned, non-group/other-writable path) before
every read and write, and an apply rename empties it because the tree changed.
`policy_remote_case_exclude` turns a remote loser into the anchored rclone
exclude pattern, with a `/**` suffix when it is a directory. Local `rename`
quarantines the loser; remote paths are never renamed, so `rename` excludes
there instead.

## Automatic sync and scheduling

- `watch` collects the manifest's local directories (optionally `--only`) and
  keeps a single watcher per profile: `WATCH_DIR/watch.pid` records the pid
  and its `lstart`, so a recycled pid cannot keep a stale watcher alive.
  Streaming backends (`fswatch`, `inotifywait`) push events; the `poll`
  backend compares each source against a per-source marker under
  `WATCH_DIR`. Events are debounced (`WATCH_DEBOUNCE`) and a source is synced
  at most once per `WATCH_INTERVAL`; `WATCH_REMOTE_INTERVAL` additionally
  runs `check --quiet` and notifies when the remote differs. Syncs are
  spawned as `bin/sciebo sync --apply --quiet --only NAME` (the sync command
  owns the run lock), and runs are skipped while a pause is active.
- `schedule` renders the launchd plist or the systemd `--user` units from the
  `SCHEDULE_*` settings: daily at `SCHEDULE_HOUR:SCHEDULE_MINUTE`, every
  `SCHEDULE_INTERVAL` seconds, or on `SCHEDULE_WATCH_PATH` changes, with
  `SCHEDULE_JITTER`. `SCHEDULE_AT_LOGIN`/`--at-login` adds `RunAtLoad` /
  `WantedBy=default.target`, and `SCHEDULE_PROFILES`/`--profiles` renders one
  `<LAUNCHD_LABEL>.<profile>` agent per extra profile, each running with
  `--profile`.

## HTTP / DAV / OCS layer

`lib/http.sh` centralizes direct Nextcloud access for `trash`, `versions`,
`share`, `notifications`, `activity`, `presence`, `lock`, and the newer
server commands; `lib/nc_api.sh` builds the DAV/OCS domain helpers on top.
`lock`, `trash`, and `versions` build their endpoint URLs with `nc_dav_url`
and issue their PROPFIND/LOCK/UNLOCK/MOVE/DELETE calls through
`nc_dav_request_allow`, which keeps the non-fatal status handling in the
command while reusing the shared authenticated request path:

- `http_remote_info` derives `HTTP_BASE`, `HTTP_USER`, `HTTP_DAV_ROOT`,
  `HTTP_FILES_ROOT`, and `HTTP_OCS_ROOT` from the rclone remote's URL and
  dies when it is not a Nextcloud WebDAV remote.
- `http_curl` gets the plain app password from the keychain plaintext slot
  (no `rclone reveal`) and writes it to a mode-600 netrc temp file
  (`--netrc-file`) so it never appears in the curl argv. A password containing
  a control byte is refused rather than falling back to `-u user:password`
  (which would expose it in `ps`). `HTTP_CONNECT_TIMEOUT` (default 15) bounds
  the connect phase; `HTTP2_ENABLED=0` forces `--http1.1`; an explicit
  `http(s)://` `PROXY` is exported to the curl child as
  `HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY` rather than passed as `-x URL`, so its
  credentials never appear in the curl argv, while a `socks5://` `PROXY` keeps
  `-x URL` (the documented residual) and `PROXY_DIRECT=1` passes
  `--noproxy '*'` (see [docs/settings.md](settings.md#proxy)). A set
  `CLIENT_KEY_PASSWORD` reaches curl through a mode-600 `--config` file, not
  `--pass`.
- On the hot path the top-level shell creates the body/headers/stderr/netrc
  temp files once per process and truncates and reuses them across requests (a
  command-substitution subshell, which cannot register cleanup in the parent,
  uses per-call files); `Retry-After` is parsed only for 429/503, an empty
  stderr skips the scrub, and an explicit 2xx/3xx test (`http_ok_code`) is a
  pure-bash helper. `xml_fields` builds one TAB record for a whole field set in
  a single awk pass.
- `http_request` captures the body in `HTTP_BODY` and dies on transport
  failures and 4xx/5xx; `http_request_allow` leaves the status to the caller.
  Header values are read with `http_header` (used for `Lock-Token`).
- `ocs_request`/`ocs_request_allow` add the OCS headers, prefix the OCS root,
  and parse the envelope with `ocs_parse`.
- `lib/nc_api.sh` holds the fixed PROPFIND/REPORT/PROPPATCH bodies and the
  operations built from them: file ids and metadata (`nc_fileid`,
  `nc_file_info`), user info and avatars, comments, favorites, system tags,
  and unified search. User input is XML-escaped with `nc_xml_escape` before
  it reaches a body, and everything goes through the authenticated netrc
  path.
- Responses are requested as XML and parsed with awk-based helpers so no `jq`
  is needed. The shared prelude `_AWK_XML_LIB` holds the trim, entity-decode,
  percent-decode, and extract primitives, so every parser composes one awk
  program instead of copy-pasting them. The `xml_get` getter (with
  `xml_get_any` for the alias spellings of one tag) remains for single values,
  while list responses use the single-pass
  `xml_records`/`xml_records_top` extractors (one awk process per document,
  one TAB-separated record per wrapper); `xml_wrapper_auto` picks the wrapper
  tag the document actually uses. The OCS JSON replies are read with
  `json_string_field`, which pulls one `"KEY": "VALUE"` string in a single awk
  pass, so the capabilities and OCS paths need no JSON parser.
  `http_urlencode` is byte-wise so multi-byte names encode correctly on macOS.

Commands that use this layer never call curl directly; they set expectations
about status codes and let the shared helpers format errors. `rclone` gets
the proxy and HTTP/2 treatment in `rclone_cmd`: an explicit `http(s)://`
`PROXY` is exported to the child as `HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY`
(credentials stay out of argv), a `socks5://` `PROXY` keeps `--http-proxy`,
`PROXY_DIRECT=1`/`none` strips the proxy variables, and `--disable-http2`
is applied. When the remote's password lives in the
rclone config rather than the keychain, `remote_write_nextcloud` (and
`remote_write_pass` for `setup --rotate`) writes a non-secret placeholder and
then patches the real obscured value into the plaintext config with
`rclone_config_patch_value`, so the reversible secret never lands in an argv;
an encrypted rclone config is refused with a clear message instead of falling
back to the argv form. `remote_secret_plain` reads the keychain plaintext slot
directly during normal operation; only a legacy obscured keychain item (once,
during migration) or the `KEYCHAIN=0` config-obscured fallback runs
`rclone reveal` (see [SECURITY.md](../SECURITY.md)).

## Capabilities probe

`lib/capabilities.sh` probes the OCS capabilities endpoint
(`/ocs/v2.php/cloud/capabilities?format=json`, `Accept: application/json`).
When `lib/http.sh` is loaded it goes through `http_curl`, so the
`--trust`/`TLS_INSECURE` policy, `PROXY`/`PROXY_DIRECT`, `HTTP_TIMEOUT`, and
the netrc app-password path all apply. A standalone caller (the integration
tests) that has not loaded `http.sh` falls back to a plain curl GET that still
uses `curl_client_args_into` and a mode-600 netrc file, but that path does not
itself apply TLS_INSECURE or the proxy. Either way it parses the facts the
tooling cares about (Nextcloud version, big-file chunking, chunk max size,
trashbin, checksums) without `jq`, and caches the raw response
(`CAPABILITIES_JSON`) plus a sanitized sourceable file (`CAPABILITIES_CACHE`).
`CAPABILITIES_MAX_AGE` bounds freshness.
`capabilities_facts` renders the parsed facts once for `capabilities_show`
and `doctor`.

`sync` resolves the upload chunk size once per run. `CHUNK_SIZE` wins;
otherwise, for a Nextcloud remote with a fresh cache,
`capabilities_chunk_for_duration` derives a run-level value from
`TARGET_CHUNK_UPLOAD_DURATION` (milliseconds, or a duration with a suffix)
times the effective upload throughput (`BW_LIMIT_UP`, else
`TARGET_UPLOAD_THROUGHPUT`), capped at the server's maximum and clamped to
`MIN_CHUNK_SIZE`/`MAX_CHUNK_SIZE`; without a throughput the capability
maximum is used. The derivation runs once per run, not per chunk, because
rclone uploads with one fixed chunk size. The value reaches rclone as
`--webdav-nextcloud-chunk-size`.

## Profiles

A profile is resolved in `load_settings`: when `SCIEBO_PROFILE` is set and not
`default`, the profile directory must exist under `PROFILES_DIR`, and the
manifest/state paths are rebound to `config/profiles/<name>/` and
`state/profiles/<name>/`. The keychain service becomes
`rclone-sciebo/<name>` unless `KEYCHAIN_SERVICE` was customized. Because the
defaults are derived only after all layers are sourced, a profile can change
`RCLONE_REMOTE`, `REMOTE_BASE`, and tuning without touching the project-wide
files.

## Platform backends

`lib/platform.sh` selects one backend per concern at runtime; `doctor`
reports the active ones, and tests override probing with the
`SCIEBO_KEYCHAIN_BACKEND`, `SCIEBO_NOTIFY_BACKEND`,
`SCIEBO_SCHEDULER_BACKEND`, and `SCIEBO_NETWORK_BACKEND` environment
variables.

| Concern | macOS | Linux | Fallback |
| --- | --- | --- | --- |
| key storage | `security` | `secret-tool` (libsecret), else `pass` | obscured password in the rclone config (`KEYCHAIN=0`) |
| notifications | `osascript` | `notify-send` | silent no-op |
| scheduler | `launchd` | `systemd --user` | a bare `crontab` is detected but not managed |
| metered networks | `route` + `networksetup` | `nmcli` | no metering detected |

`lib/keychain.sh` sources `platform.sh`; `lib/notify.sh` and
`lib/commands/schedule.sh` call the `platform_*` functions and rely on the
entrypoint having sourced `keychain.sh` first. The Linux key-storage backends
pass the secret on stdin, so it never appears in process arguments.

## Signals

- `bin/sciebo` traps INT/TERM: release the lock and exit 130/143.
- `sync` installs its own trap around a run. It backgrounds the rclone child
  so the trap can run immediately (a foreground child defers traps until it
  exits), records the child pid, and on a signal TERMs the child (and its
  direct children) or every live parallel worker, then exits 128+signal.
- The EXIT trap is the single release point for the lock, which keeps lock
  handling correct on both clean and signal exits.

## Parallelism

`MAX_PARALLEL_SOURCES` > 1 switches `sync` from the serial loop to
`sync_run_parallel`. The parent uses `wait -n` to reap workers as they finish,
keeping at most N alive. Each worker is a subshell that
runs the same `sync_run_one_line` function with stdout/stderr captured to a
per-entry file and writes counter deltas plus failed names to a `.result`
file. The parent prints each worker's captured output whole when it reaps it
and folds the deltas into the run totals, so the summary, conflicts,
notifications, blacklist, and runstate behave exactly like the serial path.
Worker state files live under `STATE_DIR` and are removed on reap or signal.

## Performance and fork reduction

The hot paths replace subprocesses with shell builtins or one-pass helpers:

- `size_suffix_bytes` parses `N[KMGTP]` sizes in pure bash, so the per-entry
  disk/limit guard and the chunk paths no longer spawn `awk`; `epoch_to_stamp`
  formats numeric epochs with the `strftime` builtin and caches per epoch and
  format, replacing the per-call `date` fork in status/history/log rendering.
- Settings key sets are memoized per file and stamp (`_config_keys_refresh`),
  so `config list`/`get` stop re-parsing `settings.env` once per key, and
  `config_file_defines` is a pure-bash membership test.
- `manifest_lines`, the pair-flag file, and the runstate/history paths resolve
  and parse once per changed file or name instead of forking per field.
- Row-heavy output uses single-pass helpers: `xml_fields` builds a whole field
  set in one awk pass, `blacklist_each_record` and `doctor_each_entry` walk
  records through a callback instead of a subshell loop, and the share, lock,
  and folder row renderers plus wider `opt_begin` adoption remove the
  remaining per-row resubstitutions where possible. The HTTP layer keeps its
  temp files across requests and parses `Retry-After` lazily (see above).
- Command modules are loaded lazily (`_sciebo_module_path`, which resolves
  through `_SCIEBO_COMMAND_MODULE_SPECS` with a content scan only as a
  stale-table fallback, plus `sciebo_require_module`), so a one-command
  invocation parses only the file that defines it instead of every
  `lib/commands/*.sh`.
- The plain app password is cached for the process lifetime
  (`HTTP_SECRET_CACHE`, cleared by `http_secret_invalidate`), so repeated HTTP
  calls do not re-read the keychain, and `lib/bigfolder.sh` derives every child
  folder size from one recursive `rclone lsf` listing per scan.

## State migrations

`lib/migrate.sh` versions the state layout with `STATE_VERSION` (currently
1) stored in `STATE_VERSION_FILE` (`state/VERSION`). `ensure_state_dirs`
requires the module on demand and calls `state_migrations_run`, which:

- writes the current version when the state directory is first initialized,
- walks `_state_migrate_step` from the recorded version to the current one,
  rewriting the version after each step,
- refuses to continue when the recorded version is newer than the binary
  understands, so an old checkout cannot silently corrupt newer state.

To add a migration: write the step in `_state_migrate_step`, bump
`STATE_VERSION`, and cover it in the unit tests.

## Tests

| Suite | Command | Scope |
| --- | --- | --- |
| unit | `tests/unit.sh` | library functions with rclone stubbed or absent; paths redirected to a temp directory |
| feature | `tests/features.sh` | one script per feature in `tests/features/`, each self-isolated with a temp dir and stub `curl` binaries |
| integration | `tests/integration.sh` | the whole CLI as `bash bin/sciebo` against a throwaway `local` rclone remote; every path override points into a temp dir |

`tests/harness.sh` provides the shared assertions (`expect_eq`,
`expect_contains`, `expect_file`, ...) and prints `PASS`/`FAIL` lines plus a
summary. `tests/fake_server.py` is a local Nextcloud emulator (status, Login
Flow v2, avatar, capabilities including `files_sharing`/`files.versioning`/
`dav`/`comments`/`systemtags`/`notifications`/`user_status`/`activity`, DAV
files/comments/systemtags plus functional trashbin, versions, locks, and
chunked uploads, OCS user/activity/search/shares/notifications/user status,
and `/__test__/` seed hooks). The DAV layer emits `nc:is-encrypted`,
`oc:checksums`, `d:owner-id`, `d:locktoken`, and external-mount
`oc:permissions` for seeded paths, honors a single `Range`, and can inject
429/503/507, ETag/`If-Match` 412, and redirects via `/__test__/seed` and
`?__fail=STATUS`. `tests/fake_env.sh` starts it, creates a `faknc` rclone
remote pointing at it, and can run the real CLI with a PATH that bypasses the
feature-suite curl stubs, so server-facing commands and the chunk-upload path
can be exercised end to end without a network; `tests/features/server_live.sh`
does exactly that for the DAV/OCS read commands. The integration suite
snapshots the real
`config/` content before and after to prove it never touched the real tree;
launchd install/uninstall runs only when `INTEGRATION_LAUNCHD=1`. The unit
suite also exercises the pure helpers directly (the chunk derivation,
`comma_ids_valid`, `epoch_to_stamp_or_raw`, `remote_is_nextcloud` memoization,
and the policy/XML parsers). `make lint` (shellcheck + shfmt +
`scripts/check-bash-min.sh` + `scripts/check-drift.sh`) and `make test` are
the pre-PR gates; `make test-fast` runs unit + feature without integration.
CI runs lint, unit, feature, and integration on both macOS and Linux (the
Linux jobs run `make lint` + `make test-fast` plus a portable integration
job).

## Adding a command

1. Create `lib/commands/<name>.sh` with a module comment, `usage_<name>`,
   and `cmd_<name>` (return a status; use `die`/`usage_error` only for
   terminal errors).
2. Add `<name>` to the `COMMANDS` string in `bin/sciebo`; the
   `lib/commands/*.sh` glob sources the new module automatically.
3. Parse options with `opt_parse`; call `load_settings` and, when the remote
   is needed, `require_remote`; acquire the lock only if the command writes
   shared state.
4. Add a unit test for any pure helper, a feature test (stub curl when
   talking to Nextcloud) and, when it changes CLI behavior, an integration
   test.
5. Document the command in [docs/commands.md](commands.md), any new setting
   in [docs/settings.md](settings.md) and
   `config/settings.local.env.example`, and add a `CHANGELOG.md` entry.
