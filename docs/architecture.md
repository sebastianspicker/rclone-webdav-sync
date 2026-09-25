# Architecture

This document is for a contributor about to read, change, or review code in
this repository. It explains what the codebase is, how it is organized into
layers, how a single invocation starts up and ends, and which parts of its
behavior are contracts that must not break. Start with [Layers](#layers) for
the mental model, then [Adding a command](#adding-a-command) when you are
ready to write code, and [External contracts](#external-contracts) before you
refactor anything that looks load-bearing.

rclone-webdav-sync, an unofficial command-line client for sciebo
(Hochschulcloud.NRW) and other Nextcloud servers, is a Bash CLI, invoked as
`sciebo`, that mirrors local directories and git repositories to a Nextcloud
WebDAV remote through rclone, with Nextcloud-desktop-client parity
(sync/pull/bisync, shares, notifications, on-demand mounts) and no daemon
unless the user opts into `watch` or `schedule install`. The command is named
after the service it connects to; the name belongs to the sciebo service, not
to this project. This tool talks to any Nextcloud server, not only sciebo.
<!-- src: architecture.md -->

There is no build step; `bin/sciebo` runs straight from the checkout. Each
invocation is one process: it loads its libraries, dispatches one command,
spawns rclone/curl children as needed, and exits. `watch` and an installed
`schedule` unit are the only long-running or recurring cases, and both work
by re-invoking `bin/sciebo sync` as a child rather than syncing in-process.
The floor is Bash 5.3 (associative arrays, `mapfile`, `${var,,}`/`${var^^}`,
namerefs, `wait -n`, `EPOCHSECONDS`, forkless command substitution,
`BASH_MONOSECONDS`); macOS ships 3.2 as `/bin/bash`, so `bin/sciebo` checks
the version and fails fast with a clear message when it is too old.
<!-- src: architecture.md -->

- [Layers](#layers)
- [Startup and dispatch](#startup-and-dispatch)
- [The CLI definition](#the-cli-definition)
- [State and configuration](#state-and-configuration)
- [Locking](#locking)
- [Run records, history, blacklist, pause](#run-records-history-blacklist-pause)
- [Guards before a transfer](#guards-before-a-transfer)
- [Policy gates](#policy-gates)
- [Watch and schedule](#watch-and-schedule)
- [HTTP / DAV / OCS layer](#http--dav--ocs-layer)
- [Capabilities probing](#capabilities-probing)
- [Profiles](#profiles)
- [Platform backends](#platform-backends)
- [Signal handling](#signal-handling)
- [Parallel sync](#parallel-sync)
- [Command conventions](#command-conventions)
- [Global naming conventions](#global-naming-conventions)
- [Tests and tooling](#tests-and-tooling)
- [Adding a command](#adding-a-command)
- [External contracts](#external-contracts)
- [Limitations](#limitations)
- [Glossary](#glossary)

## Layers

`lib/` is a stack of seven code layers, one directory each. A file may call a
function defined in its own layer or any layer below it; never a higher one.
Within `lib/commands/`, one command module never calls another's functions;
shared logic belongs in a lower layer, and a command that needs another
command spawns `bin/sciebo` instead of calling it as a function.
<!-- src: architecture.md#layers -->

| Layer | Directory | Owns | May depend on |
| --- | --- | --- | --- |
| base | `lib/base/` | paths, logging, `die`/`usage_error` (`core.sh`); string/UTF-8 helpers (`text.sh`); XML/JSON parsing (`xml.sh`); the option parser (`opts.sh`); keeping secrets out of argv/ps (`secrets.sh`); stat/atomic-write/`safe_source` (`fsutil.sh`); `--json`/table output (`output.sh`); duration/epoch helpers (`duration.sh`); prompts (`ui.sh`) | nothing else in `lib/` |
| adapters | `lib/adapters/` | external programs and services: proxy classification (`proxy.sh`); rclone (`rclone.sh`); curl/DAV/OCS transport (`http.sh`); Nextcloud domain calls (`nc_api.sh`); the capabilities probe (`capabilities.sh`); app-password storage (`keychain.sh`); OS backend selection (`platform.sh`); notifications (`notify.sh`) | base |
| config | `lib/config/` | user-authored configuration: layered settings, profiles, path derivation (`settings.sh`); the manifest/pair model (`manifest.sh`) | base, adapters |
| state | `lib/state/` | tool-written state under `STATE_DIR`: layout/versioning (`layout.sh`); run records (`runstate.sh`); the failure blacklist (`blacklist.sh`); pause marker (`pause.sh`); bandwidth marker (`bw.sh`); the run lock (`lock.sh`); per-pair flags (`pairflags.sh`); seen-id caches (`seen.sh`) | base, adapters, config |
| sync | `lib/sync/` | domain rules shared by several commands: rclone-argv policy gates (`policy.sh`); case-clash scanner (`case_clash.sh`); E2EE/external-storage engine (`remote_paths.sh`); large-folder discovery (`bigfolder.sh`); filter accessors (`filters.sh`); remote size/quota (`quota.sh`); hydrate/download resolution (`hydrate.sh`) | base, adapters, config, state |
| cli | `lib/cli/` | process entry: the generated registry (`registry.sh`); global options, dispatch, help, traps (`main.sh`); version banner (`version.sh`) | base, adapters, config, state, sync |
| commands | `lib/commands/` | one file per command group, e.g. `setup.sh`, `sync.sh`, `folders.sh` | every layer below; never another command module |

<!-- src: architecture.md#layers -->

`scripts/check-layers.sh` enforces this statically in `make lint` by parsing
function definitions and by-name calls across `lib/`. Its header states six
rules, and each violation prints `file:line` and fails the check:

1. A file may call functions defined in its own layer or a lower one. Rank:
   base < adapters < config < state < sync < cli < commands.
2. A command module never calls a function defined in another command
   module; shared logic belongs in `lib/`.
3. Only `lib/sciebo.sh` sources library code. A line may opt out with a
   trailing `# layers: allow-source` comment (used by `safe_source` reading
   a user settings file, and by the command-module dispatch in
   `lib/cli/main.sh`).
4. Library files do no settings work at source time: no top-level
   `: "${VAR:=...}"` defaults.
5. Top-level array declarations are global (`declare -gA`/`-ga`), so a
   module behaves the same whichever scope sources it.
6. awk programs built on the shared byte-oriented preludes (`_AWK_CTRL_LIB`,
   `_AWK_HTML_LIB`, `_AWK_XML_LIB`) must run under `LC_ALL=C`; in a UTF-8
   locale gawk turns decoded bytes into characters, which breaks the
   byte-oriented logic those preludes assume.
<!-- src: architecture.md#layers -->

Names built at runtime (`cmd_$name`) are invisible to the checker by design;
that is documented dispatch, not a violation.
<!-- src: architecture.md#layers -->

Where new code goes: a pure helper with no knowledge of settings or the
network goes in `base`; something that shells out or talks to a service goes
in `adapters`; a new settings key or manifest field goes in `config`; a new
on-disk record under `STATE_DIR` goes in `state`; a rule shared by two or
more commands goes in `sync`; a single command's own logic goes in
`lib/commands/<name>.sh`.
<!-- src: architecture.md#layers -->

## Startup and dispatch

Every invocation follows the same seven steps, from process start to exit:

1. `bin/sciebo` sets `set -euo pipefail` and `umask 077`, rejects a Bash
   older than 5.3, resolves its own directory, and sources `lib/sciebo.sh`,
   which resolves `LIB_DIR`/`PROJECT_DIR` and sources every
   `lib/<layer>/*.sh` file eagerly in the layer order from the table above
   (no globs across layers, so a stale file in an installed tree can never
   be picked up). A library file only defines functions and its own
   module-private state at source time; it never reads settings or derives
   a path there.
2. `bin/sciebo` calls `sciebo_main "$@"` (`lib/cli/main.sh`), which installs
   the INT/TERM/EXIT traps first.
3. `sciebo_main` consumes the path-affecting globals (`--confdir`,
   `--log-dir`, `--log-expire`) in an early pass, exporting them before
   anything path-derived runs, then consumes the rest (`--profile`,
   `--trust`, `--non-interactive`, `--debug`, `--log-file`), with
   `--version`/`-V` short-circuiting.
4. It calls `settings_init_paths` (idempotent; also `load_settings`'s first
   step), deriving the config/state layout before any command module loads,
   including for a bare `help <command>`.
5. It sources exactly the dispatched command's module through
   `sciebo_command_module` (`lib/sciebo.sh`). This happens inside
   `sciebo_main`, which is safe because every top-level array in a module is
   declared with `-g` (check-layers rule 5 above); a plain `declare -A`
   would become local to `sciebo_main` and vanish when it returns.
6. `main` (`lib/cli/main.sh`) looks the command up in `SCIEBO_COMMANDS` and
   calls `cmd_<command>` with the remaining arguments, or `usage_<command>`/
   `usage_main` for `help`/`-h`/`--help`; an unknown command exits 2.
7. On INT/TERM, `_sciebo_on_signal` releases the run lock and exits
   130/143; the EXIT trap releases the lock and cleans up registered temp
   files on every exit path.
<!-- src: architecture.md#startup-and-dispatch -->

Loading all of `lib/` eagerly costs roughly 15-20 ms per process (an
informal estimate, not a benchmarked figure), well under the time any real
command spends waiting on rclone or curl. This replaced an older
per-function lazy-loading scheme (`sciebo_require_module` and roughly 185
call sites deciding whether a module was already loaded). Command modules
are still lazy: only one is ever needed per invocation.
<!-- src: architecture.md#startup-and-dispatch -->

## The CLI definition

`lib/cli/sciebo.spec` is the single declarative source of truth for the
command surface: `GLOBAL` rows describe global options, `COMMAND` rows
describe top-level commands (name, tier, module, description), `SUB` rows
describe dispatch subcommands, `OPT`/`POS` rows describe a command's options
and positionals. `scripts/gen-cli.sh` reads it and writes `lib/cli/registry.sh`
(the generated command list, command-to-module map, tier map, and
global-option table `lib/cli/main.sh` consumes) plus the three completion
scripts, `completions/sciebo.bash`, `completions/_sciebo` (zsh), and
`completions/sciebo.fish`. All four generated files are committed.
<!-- src: architecture.md#the-cli-definition -->

`make gen` regenerates them from the spec. `scripts/gen-cli.sh --check`
(part of `make lint`) regenerates to a temp directory and diffs against the
committed files, and first validates the spec against the rest of the tree:
every `COMMAND` row's module file exists, every `lib/commands/*.sh` file is
referenced by some row, and `usage_main`'s "Commands:"/"Extra commands:"
sections list exactly the spec's core/extra commands in spec order. Never
edit `lib/cli/registry.sh` or the three completion files directly; edit the
spec and run `make gen`.
<!-- src: architecture.md#the-cli-definition -->

## State and configuration

`lib/config/settings.sh` sources the layered settings files through
`safe_source` (owner, mode, and symlink checked, then read through the
verified descriptor to stay TOCTOU-safe): shipped defaults in
`config/settings.env`, then environment variables, then
`config/settings.local.env` last, so plain assignments there win. See
[docs/settings.md](settings.md#precedence) for the full precedence table and
[docs/settings.md](settings.md#path-overrides-isolated-runs) for the path
overrides the test suites rely on. `settings_init_paths` derives every path
(`MANIFEST_FILE`, `STATE_DIR`, `LOG_DIR`, `FILTER_DIR`, and others) and is
idempotent.
<!-- src: architecture.md#state-and-configuration -->

`lib/config/manifest.sh` owns the `mode|local|remote[|filter]` manifest
format, the list of configured folder pairs (the sync list): `manifest_parse_line`
validates one line, `manifest_index_load` builds the sorted name/remote
indexes (with duplicate lists) `doctor`, `sync`, and `retry` read, the
writers (`manifest_append_pair`, `manifest_remove_pair`,
`manifest_write_pair_filter`) validate and replace files atomically, and
`manifest_list_render` renders the rows `list` and `sync`'s dry-run summary
share. Entry names are sanitized with `sanitize_name` (`lib/base/text.sh`),
also used for log files, bisync workdirs, run records, lock records, and
blacklist files; that reuse is why duplicate names are rejected.
<!-- src: architecture.md#state-and-configuration -->

`lib/state/layout.sh` owns the state directory: `ensure_state_dirs` creates
`LOG_DIR`, `LOCK_DIR`, `BISYNC_DIR`, `RUNSTATE_DIR`, then runs
`state_migrations_run`; every command that writes state calls it first.
<!-- src: architecture.md#state-and-configuration -->

| State module | File(s) under `STATE_DIR` | Holds |
| --- | --- | --- |
| `lib/state/layout.sh` | `VERSION` | the state layout version |
| `lib/state/runstate.sh` | `last/<name>`, `history/<name>.log` | last-run record and trimmed history per source |
| `lib/state/blacklist.sh` | `blacklist/<name>` | failure counts and errors per excluded path |
| `lib/state/pause.sh` | `paused` | pause marker (`until=<epoch>`, `0` = indefinite) |
| `lib/state/bw.sh` | `bwlimit` | bandwidth-limit marker (`until`/`up`/`down`) |
| `lib/state/lock.sh` | `lock/sync.lock/` | the single-run lock directory (`pid`, `start`) |
| `lib/state/pairflags.sh` | `pairs/<name>` | per-pair `paused`/`hidden` flags |
| `lib/state/seen.sh` | one file per cache | seen server-side ids (notifications, activity) |
| `lib/sync/bigfolder.sh` | `bigfolder/scan-<name>` | per-name scan cache and reported-once folder names |

<!-- src: architecture.md#state-and-configuration -->

`state/VERSION` holds `STATE_VERSION`: `state_migrations_run` writes the
current version on first creation, walks `_state_migrate_step` from the
recorded version to the current one on an upgrade, and refuses to continue
when the recorded version is newer than the binary understands. To add a
migration: write the step, bump `STATE_VERSION`, and cover it in the unit
tests.
<!-- src: architecture.md#state-and-configuration -->

## Locking

`lib/state/lock.sh` implements a single-run lock, the safeguard that stops
two sync/cleanup runs from overlapping on the same machine, under
`LOCK_DIR/sync.lock`. Acquisition is atomic (`mkdir`), with `pid` and
`start` (the process's `lstart`) recorded inside. A lock is stale only when
the pid is gone, the command line no longer looks like this tool (matched
against `*bin/sciebo*`, which is why that path must stay stable), or the
start time differs (pid recycling); the stale directory is renamed aside
before removal, so a concurrent takeover cannot delete a fresh lock.
`acquire_lock` is reentrant within a process (the outermost holder wins, so
the folder wizard can commit under a lock); `release_lock` only removes a
lock owned by the current pid and is idempotent, so the EXIT trap can run
after a signal handler already released it. `sync` (unless `--no-lock`),
`cleanup`, `discover --write`, `folders add|import|remove|choose`, and the
wizard's commit take the lock; `verify` and `status` never do.
<!-- src: architecture.md#lock-design -->

## Run records, history, blacklist, pause

- `lib/state/runstate.sh` writes one key=value record per source after every
  entry run (time, stamp, mode, status, rc, conflicts, log path, detail),
  parsed, never sourced, and appends a TAB-separated line to
  `history/<name>.log`, trimmed to `HISTORY_MAX_ENTRIES`.
- `lib/state/blacklist.sh` tracks failed paths as
  `count<TAB>path<TAB>error`, the retry blacklist. `sync` adds rclone
  `--exclude` patterns for paths at the threshold; `retry` clears entries.
  Writes are best effort: a state problem must never fail a sync.
- `lib/state/pause.sh` owns the one-line pause marker (`until=<epoch>`; `0`
  = indefinite). `pause_active` removes an expired marker, the only write
  `status` ever performs.
<!-- src: architecture.md#run-records-history-blacklist-pause -->

All of these use `atomic_write` with mode 600 and never source user- or
server-controlled text.
<!-- src: architecture.md#run-records-history-blacklist-pause -->

## Guards before a transfer

Three guard layers can shape or stop a transfer before rclone runs:
bandwidth, metered networks, and disk space.

- Bandwidth: `lib/state/bw.sh` owns the three-line marker (mode 600:
  `until`, `up`, `down`). `bw_effective_limit` resolves sync's `--bwlimit`
  with precedence active marker > `BW_SCHEDULE` >
  `BW_LIMIT_UP`/`BW_LIMIT_DOWN`. `sciebo limit` writes the marker and
  `unlimited` clears it; no server contact is involved.
- Metered networks: `lib/adapters/platform.sh` probes the active connection
  (`route`/`networksetup` on macOS, `nmcli` on Linux), and `net_gate`
  (`lib/sync/policy.sh`, built on `choose_policy_decision`) turns that into
  allow/ask/skip per `METERED_POLICY` (0 = proceed, 2 = skip;
  `--metered-ok`/`SCIEBO_METERED_OK=1` override). A skipped entry is
  recorded as `skipped`, never failed.
- Disk space: `sync_disk_guard` reads the local destination with `df -Pk`;
  below `MIN_FREE_SPACE` the entry fails, below `FREE_SPACE_DOWNLOAD` it is
  skipped. `bigfolder_notify` (`lib/sync/bigfolder.sh`) is the remote
  counterpart: after a pull/bisync entry it scans unconfigured remote
  subfolders above `BIG_FOLDER_SIZE` and warns/notifies once per folder,
  memoizing the scan under `state/bigfolder/` for `BIGFOLDER_SCAN_TTL`.
<!-- src: architecture.md#bandwidth-metered-networks-and-disk-guards -->

Remote size and server quota are probed once per process by
`lib/sync/quota.sh`: `remote_size_lookup` memoizes `rclone size` lookups per
remote spec in `REMOTE_SIZE_CACHE`, and `quota_probe` memoizes the server
quota in `QUOTA_STATUS`/`QUOTA_TOTAL`/`QUOTA_USED`. `sync` calls
`quota_probe` and the size guards; `doctor`'s quota check and big-folder
scan and the folder picker call `remote_size_lookup` directly, so a run
never fetches the same size twice.
<!-- src: architecture.md#bandwidth-metered-networks-and-disk-guards -->

## Policy gates

`lib/sync/policy.sh`, `lib/sync/case_clash.sh`, and `lib/sync/remote_paths.sh`
implement the desktop-parity safety policies that run before an entry
touches the remote (settings in
[docs/settings.md](settings.md#desktop-parity-policies)):

- `choose_policy_decision POLICY CONFIRMED` (`policy.sh`) is the pure
  verdict behind every allow/warn/ask/skip choice: `allow`/`warn` proceed,
  `skip`/`exclude` skip, `ask` proceeds only with confirmation.
- `policy_remote_paths_apply` (`remote_paths.sh`) is the one E2EE /
  server-mounted-external-storage engine behind the sync preflight,
  `doctor`, and the folder wizard, with a style per caller (`apply`,
  `collect`, `wizard`) and shared result state (`POLICY_REMOTE_RESULT`,
  `POLICY_REMOTE_PATHS`, `POLICY_REMOTE_SKIP_REASON`, and related
  variables).
- Case-only collisions are scanned locally by `policy_case_clashes` and,
  with `CASE_CLASH_REMOTE_SCAN=1` or `conflicts --kind case --remote`, on
  the remote by `policy_case_clashes_remote` (`case_clash.sh`, a bounded
  `rclone lsf -R` listing). A local scan memoizes its pairs for the process
  lifetime in a `mktemp -d` cache, so the repeated per-entry scans
  `sync`/`doctor` make become a file read instead of another tree walk.
  `policy_remote_case_exclude` turns a remote loser into an anchored rclone
  exclude pattern; local `rename` quarantines the loser, but remote paths
  are never renamed, so `rename` excludes there instead.
<!-- src: architecture.md#policy-gates -->

## Watch and schedule

- `watch` (live sync) collects the manifest's local directories (optionally
  `--only`) and keeps a single watcher per profile in `WATCH_DIR/watch.pid`
  (pid plus `lstart`, so a recycled pid cannot keep a stale watcher alive).
  Streaming backends (`fswatch`, `inotifywait`) push events; `poll` compares
  each source against a marker under `WATCH_DIR`. Events are debounced
  (`WATCH_DEBOUNCE`), a source syncs at most once per `WATCH_INTERVAL`, and
  `WATCH_REMOTE_INTERVAL` additionally runs `check --quiet` and notifies on
  drift. Syncs are spawned as `bin/sciebo sync --apply --quiet --only NAME`
  (sync owns the run lock) and are skipped while a pause is active.
- `schedule` (scheduled runs) renders the launchd plist or systemd `--user`
  units from the `SCHEDULE_*` settings: daily at
  `SCHEDULE_HOUR:SCHEDULE_MINUTE`, every `SCHEDULE_INTERVAL` seconds, or on
  `SCHEDULE_WATCH_PATH` changes, with `SCHEDULE_JITTER`.
  `SCHEDULE_AT_LOGIN`/`--at-login` adds `RunAtLoad`/`WantedBy=default.target`;
  `SCHEDULE_PROFILES`/`--profiles` renders one `<LAUNCHD_LABEL>.<profile>`
  agent per extra profile.
<!-- src: architecture.md#watch-and-schedule -->

## HTTP / DAV / OCS layer

`lib/adapters/http.sh` centralizes direct Nextcloud access for `trash`,
`versions`, `share`, `notifications`, `activity`, `presence`, `lock`, and the
newer server commands; `lib/adapters/nc_api.sh` builds the DAV/OCS domain
helpers on top, and `lib/base/xml.sh` holds the pure parsing primitives both
use. `lock`, `trash`, and `versions` build endpoint URLs with `nc_dav_url`
and issue PROPFIND/LOCK/UNLOCK/MOVE/DELETE through `nc_dav_request_allow`,
which keeps non-fatal status handling in the command while reusing the
shared authenticated request path.
<!-- src: architecture.md#http--dav--ocs-layer -->

`http_remote_info` derives `HTTP_BASE`/`HTTP_USER`/`HTTP_DAV_ROOT`/
`HTTP_FILES_ROOT`/`HTTP_OCS_ROOT` from the rclone remote's URL and dies when
it is not a Nextcloud WebDAV remote. Secrets never reach argv (the
command's visible arguments, readable by anyone who can list processes):
`http_curl` gets the plain app password from the keychain plaintext slot
(no `rclone reveal`) and writes it to a mode-600 netrc temp file
(`--netrc-file`); a password containing a control byte is refused rather
than falling back to `-u user:password` (ps-visible), and an explicit
`http(s)://` `PROXY` reaches the child as
`HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY` rather than `-x URL` (a `socks5://`
`PROXY` keeps `-x URL`; `PROXY_DIRECT=1` passes `--noproxy '*'`; see
[docs/settings.md](settings.md#proxy)). `rclone_cmd`
(`lib/adapters/rclone.sh`) applies the same proxy/HTTP2 rules to rclone.
`http_request` dies on transport failures and 4xx/5xx (`HTTP_BODY` holds the
body); `http_request_allow` leaves the status to the caller;
`ocs_request`/`ocs_request_allow` add the OCS headers and parse the envelope
with `ocs_parse`.
<!-- src: architecture.md#http--dav--ocs-layer -->

`lib/adapters/nc_api.sh` holds the fixed PROPFIND/REPORT/PROPPATCH bodies
and the operations built from them (file ids/metadata, user info, avatars,
comments, favorites, system tags, unified search), XML-escaping user input
with `nc_xml_escape` before it reaches a body. Responses are parsed with the
awk-based helpers in `lib/base/xml.sh`, so no `jq` is needed: `xml_get`/
`xml_get_any` for single values, `xml_records`/`xml_records_top` for list
responses (one awk pass, `xml_wrapper_auto` picking the wrapper tag), and
`json_string_field` for OCS JSON replies.
<!-- src: architecture.md#http--dav--ocs-layer -->

Commands never call curl directly. When the remote's password lives in the
rclone config rather than the keychain, `remote_write_nextcloud` (and
`remote_write_pass` for `setup --rotate`) writes a placeholder and patches
the real obscured value into the plaintext config with
`rclone_config_patch_value`, so the reversible secret never lands in an
argv; an encrypted rclone config is refused instead. `remote_secret_plain`
reads the keychain plaintext slot directly; only a legacy obscured keychain
item (once, during migration) or the `KEYCHAIN=0` fallback runs
`rclone reveal` (see [SECURITY.md](../SECURITY.md)).
<!-- src: architecture.md#http--dav--ocs-layer -->

## Capabilities probing

`lib/adapters/capabilities.sh` probes the OCS capabilities endpoint (the
server feature check, `/ocs/v2.php/cloud/capabilities?format=json`) through
`http_curl`, so `--trust`/`TLS_INSECURE`, `PROXY`/`PROXY_DIRECT`,
`HTTP_TIMEOUT`, and the netrc app-password path all apply. It parses the
facts the tooling needs (Nextcloud version, big-file chunking, chunk max
size, trashbin, checksums) without `jq`, caching the raw response
(`CAPABILITIES_JSON`) and a sanitized sourceable file
(`CAPABILITIES_CACHE`) for `CAPABILITIES_MAX_AGE`. `capabilities_facts`
renders the parsed facts for `capabilities_show` and `doctor`.
<!-- src: architecture.md#capabilities -->

`sync` resolves the upload chunk size once per run. `CHUNK_SIZE` wins;
otherwise, for a Nextcloud remote with a fresh cache,
`capabilities_chunk_for_duration` derives a run-level value from
`TARGET_CHUNK_UPLOAD_DURATION` times the effective upload throughput
(`BW_LIMIT_UP`, else `TARGET_UPLOAD_THROUGHPUT`), capped at the server's
maximum and clamped to `MIN_CHUNK_SIZE`/`MAX_CHUNK_SIZE`. The value reaches
rclone as `--webdav-nextcloud-chunk-size`.
<!-- src: architecture.md#capabilities -->

## Profiles

A profile (an independent, named account setup) is resolved in
`load_settings`: when `SCIEBO_PROFILE` is set and not `default`, the
profile directory must exist under `PROFILES_DIR`, and manifest/state paths
rebind to `config/profiles/<name>/` and `state/profiles/<name>/`. The
keychain service becomes `rclone-sciebo/<name>` unless `KEYCHAIN_SERVICE`
was customized, so a profile can change `RCLONE_REMOTE`, `REMOTE_BASE`, and
tuning without touching the project-wide files.
<!-- src: architecture.md#profiles -->

## Platform backends

`lib/adapters/platform.sh` selects one backend per concern at runtime;
`doctor` reports the active ones, and tests override probing with
`SCIEBO_KEYCHAIN_BACKEND`/`SCIEBO_NOTIFY_BACKEND`/`SCIEBO_SCHEDULER_BACKEND`/
`SCIEBO_NETWORK_BACKEND`.
<!-- src: architecture.md#platform-backends -->

| Concern | macOS | Linux | Fallback |
| --- | --- | --- | --- |
| key storage | `security` | `secret-tool` (libsecret), else `pass` | obscured password in the rclone config (`KEYCHAIN=0`) |
| notifications | `osascript` | `notify-send` | silent no-op |
| scheduler | `launchd` | `systemd --user` | a bare `crontab` is detected but not managed |
| metered networks | `route` + `networksetup` | `nmcli` | no metering detected |

<!-- src: architecture.md#platform-backends -->

The Linux key-storage backends pass the secret on stdin, so it never appears
in process arguments.
<!-- src: architecture.md#platform-backends -->

## Signal handling

`bin/sciebo` traps INT/TERM through `sciebo_main`: release the lock and exit
130/143. `sync` installs its own trap around a run, backgrounding the rclone
child so the trap runs immediately (a foreground child defers traps until it
exits); on a signal it TERMs the child (and its direct children) or every
live parallel worker, then exits 128+signal. The EXIT trap is the single
release point for the lock, keeping lock handling correct on both clean and
signal exits.
<!-- src: architecture.md#signals -->

## Parallel sync

`MAX_PARALLEL_SOURCES` > 1 switches `sync` from the serial loop to
`sync_run_parallel`. The parent uses `wait -n` to reap workers as they
finish, keeping at most N alive. Each worker is a subshell running the same
`sync_run_one_line` function with stdout/stderr captured to a per-entry file
and counter deltas plus failed names written to a `.result` file. The parent
prints each worker's output whole when it reaps it and folds the deltas
into the run totals, so the summary, conflicts, notifications, blacklist,
and runstate behave exactly like the serial path. Worker state files live
under `STATE_DIR` and are removed on reap or signal.
<!-- src: architecture.md#parallel-sync -->

## Command conventions

- A command module defines `usage_<command>` (a heredoc printed by
  `--help` and by `usage_error` on bad input) and `cmd_<command>`.
- Commands parse options with `opt_parse "name:kind ..." <command> <label>
  "$@"` (or `opt_begin`). Kinds: `s` single value, `S` repeatable value, `b`
  boolean, `o` optional value. Parsed values live in `OPT_<name>`,
  `OPT_<name>_SET` marks a provided option, positionals collect in
  `OPT_EXTRA`, and `-h`/`--help` sets `OPT_HELP`. Then `opt_help_guard
  <command>` prints usage and exits 0 on `-h`/`--help`; commands with no
  positionals use `opt_guard <command> [label]` instead, which also rejects
  the first unexpected argument with `usage_error`.
- Command functions return a status; only `die` (exit 1) and `usage_error`
  (exit 2) exit directly, which is what lets the top-level `sync`
  orchestrate entries and still return a summary.
- Commands never call each other in-process; one that needs another spawns
  `${PROJECT_DIR}/bin/sciebo` (the folder wizard does this for its optional
  dry run), and source only `lib/` helpers, never another command's
  internals.
- Every command that talks to the remote calls `load_settings` (or
  `load_settings --no-rclone` for config-only commands) and
  `require_remote`; commands that only inspect configuration must not
  create state directories.
<!-- src: architecture.md#command-conventions -->

## Global naming conventions

A top-level variable in a `lib/*/*.sh` or `lib/commands/*.sh` file is either
module-private, prefixed `_<module>_` for the file's basename (e.g.
`_http_secret_cache` is private to `lib/adapters/http.sh`) and unreadable
outside it, or shared, named for what it holds (`HTTP_BASE`, `OPT_EXTRA`)
and owned by one module as below. Most existing globals still follow older
per-command conventions (`ENTRY_*`, `MNT_*`) that predate this rule;
`scripts/check-drift.sh` only warns, never fails, on a top-level
`_<other>_*` global naming a different module.
<!-- src: architecture.md#global-naming -->

| Family | Owner | Purpose |
| --- | --- | --- |
| `OPT_*`, `OPT_HELP`, `OPT_EXTRA`, `POSITIONAL_ARGS` | `lib/base/opts.sh` | written by `opt_parse`/`opt_begin`/`split_positionals`; every command reads them after parsing its own options |
| `SCIEBO_TEMP_FILES` | `lib/base/secrets.sh` | the exit-cleanup temp-file registry; any `atomic_write`/`temp_mktemp_into` caller appends to it |
| `CLIENT_CERT`, `CLIENT_KEY`, `CA_CERT`, `USER_AGENT` | `lib/config/settings.sh` | read by `secrets.sh`'s `curl_client_args_into` and `lib/adapters/http.sh`'s curl calls |
| `CLI_NAME`, `CONFIG_DIR`, `LIB_DIR`, `PROJECT_DIR`, `SCIEBO_BASH`, `SCIEBO_VERSION` | `lib/base/core.sh` | resolved once at source time; read across nearly every file |
| `HTTP_*` | `lib/adapters/http.sh` | request/response state every `http_*`/`ocs_*` call leaves for its caller |
| `OCS_STATUS`, `OCS_STATUSCODE`, `OCS_MESSAGE` | `lib/adapters/http.sh` | `ocs_request`'s parsed envelope, read by every OCS-backed command |
| `CAP_*`, `CAPABILITIES_*` | `lib/adapters/capabilities.sh` | parsed capabilities facts and the chunk-size memo; read by `server`/`account`/`share`/`filters` |
| `POLICY_REMOTE_*` | `lib/sync/remote_paths.sh` | `policy_remote_paths_apply`'s result state, read by `sync`/`doctor`/the folder wizard |
| `QUOTA_*`, `REMOTE_SIZE_CACHE`, `REMOTE_SIZE_BYTES` | `lib/sync/quota.sh` | per-process quota/size figures read by `sync`, `doctor`, and the folder picker |
| `MANIFEST_DUP_NAMES`, `MANIFEST_DUP_REMOTES`, `MANIFEST_NAMES`, `MANIFEST_MATCH_*` | `lib/config/manifest.sh` | `manifest_index_load`'s output, read by `doctor`/`watch`/`hydrate` |
| `CHOOSE_*`, `P_*` | `lib/commands/folders.sh` | private to the folder picker/wizard |

<!-- src: architecture.md#global-naming -->

## Tests and tooling

| Suite | Command | Scope |
| --- | --- | --- |
| unit | `tests/unit.sh` (`tests/unit/*.sh`) | library functions with rclone stubbed or absent; paths redirected to a temp directory |
| feature | `tests/features.sh` (`tests/features/*.sh`) | one script per feature, each self-isolated with a temp dir and stub `curl` binaries |
| integration | `tests/integration.sh` | the whole CLI as `bash bin/sciebo` against a throwaway `local` rclone remote |
| contract | `tests/contract/` | the whole CLI against a real Nextcloud in Docker; nightly CI only |

<!-- src: architecture.md#tests-and-tooling -->

`tests/unit.sh` and `tests/features.sh` wrap the shared `tests/run-suite.sh`
runner, which discovers every script in its directory, runs up to `-j N`
concurrently (reaped with `wait -n -p`), and prints each report under an
`=== name ===` header in alphabetical order regardless of finish order.
`tests/harness.sh` provides the shared assertions (`expect_eq`,
`expect_contains`, `expect_file`, and others), printing the captured output
on a failing `expect_rc`/`expect_contains`. Every test script loads
production code through `lib/sciebo.sh`, the same loader `bin/sciebo` uses.
`tests/fake_server.py` is a local Nextcloud emulator (status, Login Flow v2,
avatar, capabilities, DAV files/comments/systemtags plus
trashbin/versions/locks/chunked uploads, OCS
user/activity/search/shares/notifications, `/__test__/` seed hooks);
`tests/fake_env.sh` starts it and points a real CLI invocation at it.
`tests/run-one.sh` (`make test-one T=NAME`) runs one named script.
<!-- src: architecture.md#tests-and-tooling -->

`make lint` runs shellcheck, shfmt, `scripts/check-layers.sh`,
`scripts/gen-cli.sh --check`, `DRIFT_STRICT=1 scripts/check-drift.sh`, and a
`py_compile` check of `tools/screenshots.py`/`tests/fake_server.py` (a
missing linter fails unless `LINT_ALLOW_MISSING=1`).
<!-- src: architecture.md#tests-and-tooling -->

shellcheck runs in two passes, because the two audiences need different
settings: production code runs with `-x`, following sources into `lib/`, so
each library file is checked in the context it actually loads in; tests run
without following sources, because each test sources the whole library and
`-x` would re-analyze all of `lib/` once per test file, which does not scale.
The test pass excludes only the codes that need the library's view (SC1091,
SC2154, SC2034, SC2329), since those would otherwise misfire on names and
sources the test file only ever sees indirectly.
<!-- src: architecture.md#tests-and-tooling -->

`check-drift.sh` checks the implementation against the spec/registry: every
command has a matching `usage_<name>`/`cmd_<name>` pair and man page
section, every settings key `settings.sh` requires exists in
`settings.env`, and, under `DRIFT_STRICT`, a live `<command> --help`'s long
options match the spec. `make test` is unit + feature + integration;
`make test-fast` skips integration (the pre-PR gate). CI runs
lint/unit/feature/integration on macOS and Linux; the contract suite runs
nightly against a real server.
<!-- src: architecture.md#tests-and-tooling -->

## Adding a command

1. Add a `COMMAND` row to `lib/cli/sciebo.spec` (name, tier, module,
   description) plus any `SUB`/`OPT`/`POS` rows it needs, then run
   `make gen`.
2. Create `lib/commands/<name>.sh` with a module comment, `usage_<name>`,
   and `cmd_<name>` (return a status; `die`/`usage_error` only for terminal
   errors). Parse with `opt_parse`; call `load_settings` and, when the
   remote is needed, `require_remote`; acquire the lock only if the command
   writes shared state.
3. Add the command's line to `usage_main`'s "Commands:"/"Extra commands:"
   section, in spec order; `scripts/gen-cli.sh --check` verifies the two
   match.
4. Put shared logic in the right layer (`lib/sync/` for a rule two commands
   need, `lib/adapters/` for a new external call), never inline in a second
   command module.
5. Add a unit test for any pure helper, a feature test (stub curl for
   Nextcloud calls), and an integration test if CLI behavior changes.
6. Document it in [docs/commands.md](commands.md), any new setting in
   [docs/settings.md](settings.md) and `config/settings.local.env.example`,
   and add a `CHANGELOG.md` entry.
<!-- src: architecture.md#adding-a-command -->

A new server-API command starts in the `extra` tier and is promoted to
`core` only once `tests/contract/` covers it against a real Nextcloud.
<!-- src: architecture.md#adding-a-command -->

## External contracts

These stay stable across refactors because something outside the repo
depends on them:

- `bin/sciebo`'s path: installed launchd/systemd units embed it, and the
  lock's staleness check matches the running process's command line against
  `*bin/sciebo*`.
- The launchd plist template path (`launchd/de.rclone-sciebo.sync.plist.in`)
  and the rendered unit's structure.
- `config/` and `state/` live under the project root or under `--confdir`.
- The completions at `completions/{sciebo.bash,_sciebo,sciebo.fish}`.
- `scripts/sync.sh` and `scripts/nextcloudcmd` keep forwarding to
  `bin/sciebo sync`/`bin/sciebo nextcloudcmd` for old automation.
- Settings keys in `config/settings.env` and the `OWNCLOUD_*` alias names
  nextcloudcmd/the desktop client use.
- The state file formats in the ownership table in
  [State and configuration](#state-and-configuration).
- Exit codes: 0 success, 1 `die`, 2 `usage_error`/unknown command, 130
  SIGINT, 143 SIGTERM.
<!-- src: architecture.md#external-contracts -->

## Limitations

This document has no product limitations to disclose; what it enforces
instead are process rules, checked by lint rather than left as convention:

- Layering (base → adapters → config → state → sync → cli → commands) must
  not be violated; `scripts/check-layers.sh` fails the build on a call to a
  higher layer.
- Command modules must not call each other in-process; a command that needs
  another spawns `bin/sciebo`.
- The old per-function lazy-loading scheme is gone; every library file loads
  eagerly on every invocation, which trades roughly 15-20 ms of startup for
  the simplicity of not tracking load state at ~185 call sites.
<!-- src: architecture.md -->

## Glossary

Plain-language definitions for terms used above, shared with the rest of
this project's documentation:

| Term | Meaning |
| --- | --- |
| sciebo | The Hochschulcloud.NRW cloud storage service for NRW universities; this project is an unofficial client for it. |
| `sciebo` (command) | The command this tool installs; named after the service. |
| Nextcloud | The open-source server software the sciebo service and other institutions run. |
| rclone | The third-party file-transfer engine this tool is built on; this tool configures and runs it rather than talking to the server directly for transfers. |
| remote / rclone remote | A named rclone configuration entry (default name `sciebo`, held in `RCLONE_REMOTE`) that holds the server URL and how to authenticate. |
| WebDAV | The file-access protocol rclone and this tool's direct HTTP calls use against the server. |
| app password | A Nextcloud-issued password scoped to one application/device, used instead of the account's main password. |
| keychain | The OS-level secret store (macOS Keychain, Linux secret-tool/pass) this tool prefers for the app password over the rclone config file. |
| manifest | The set of configured folder pairs (the sync list) that `sync`/`check`/etc. act on. |
| layer | One of seven ordered internal code groupings (from basic helpers up to individual commands); lower layers never depend on higher ones. |
| state directory | Where this tool stores run history, locks, caches, and other bookkeeping, separate from synced files. |
| run lock | A safeguard that stops two sync/cleanup runs from overlapping on the same machine. |
| policy (e.g. `E2EE_POLICY`) | A named setting that chooses how this tool reacts to a risky situation: allow it, warn, ask first, or skip/exclude it. |
| tier (core / extra) | `core` commands are covered by tests against a real Nextcloud server; `extra` commands are newer and tested only against a local stand-in. |
| profile | An independent, named account setup (its own remote, sync list, filters, and state), used to manage more than one Nextcloud account. |
| filter file | A plain-text rule file (rclone syntax) that excludes or includes paths from a sync. |
| capabilities probe | A one-time-per-cache-window API call that discovers what the connected server supports (chunk size, trashbin, checksums, version). |
| metered network | A connection this tool can detect and treat more cautiously, e.g. a mobile hotspot. |
| blacklist (failure) | The list of paths this tool has temporarily stopped retrying after repeated failures, until `sciebo retry` clears them. |
| watch | An optional, foreground command that syncs a folder as soon as it changes; not a background service. |
| schedule | An optional, installable background job (via the OS's own scheduler) that runs sync periodically; opt-in, not automatic. |
