# Settings

This tool (rclone-webdav-sync) is configured entirely through shell-style
files and environment variables. There is no separate config parser: files
are sourced by `lib/config/settings.sh`, so quoting rules are Bash's.
<!-- src: settings.md -->

This page is a lookup reference, not a tutorial: use it to find one setting,
check its default, or work out which file wins when an override doesn't seem
to take effect. If you are setting up this tool for the first time, start
with the [README](../README.md) instead.

## In short

- Settings live in `config/settings.env` (shipped defaults), and you override
  them in `config/settings.local.env` (your personal file, not tracked by
  git) or in the environment for a single run. See
  [Precedence](#precedence) for the exact order.
- The file that wins is whichever loaded last: `config/settings.local.env`
  beats an exported environment variable, which beats
  `config/settings.env`. If your override "isn't taking effect," check that
  it's not being beaten by a later layer, in particular a profile file (see
  [Profiles](#profiles)).
- The settings most people change first are transfer speed
  (`TRANSFERS`, `BW_LIMIT_UP`/`BW_LIMIT_DOWN`), what happens to deleted files
  (`MAX_DELETE`, `MOVE_TO_TRASH`), and whether this tool uses the system's
  password manager (`KEYCHAIN`). See [Common overrides](#common-overrides)
  for ready-to-paste examples of each.
- Everything below "Settings reference" is the full lookup table, grouped by
  theme (connection, transfer tuning, safety policies, notifications,
  scheduling, and so on).
<!-- src: settings.md#common-overrides -->

- [Precedence](#precedence)
- [Common overrides](#common-overrides)
- [Profiles](#profiles)
- [Configuration files](#configuration-files)
- [Settings reference](#settings-reference)
- [Key storage backends](#key-storage-backends)
- [TLS](#tls)
- [Proxy](#proxy)
- [State layout](#state-layout)
- [Path overrides (isolated runs)](#path-overrides-isolated-runs)
- [Development knobs](#development-knobs)
- [Limitations](#limitations)
- [Glossary](#glossary)

## Precedence

Later layers win. Every layer is sourced in this order:
<!-- src: settings.md#precedence -->

1. `config/settings.env` — the defaults that ship with the project. It uses
   `: "${VAR:=default}"`, so a variable already present in the environment
   keeps its environment value.
2. Environment variables — handy for one-off runs and scripts.
3. `config/settings.local.env` — your personal overrides (gitignored). Plain
   assignments here beat the environment.
4. Profile files: `config/profiles/<name>/settings.env`, then
   `config/profiles/<name>/settings.local.env`. Plain assignments there beat
   everything else.
<!-- src: settings.md#precedence -->

So: export a variable for a single run, copy
`config/settings.local.env.example` to `config/settings.local.env` for
something permanent, or put it in an account profile to affect one account.
<!-- src: settings.md#precedence -->

Every settings, profile, and `.env` file is read only after an ownership,
permission, and symlink check, and the verified content is sourced through
its own open descriptor, so a file swapped between the check and the read is
refused (this is the same TOCTOU-safe mechanism SECURITY.md describes for
credential files). An unsafe file aborts the command with a clear message;
these files are trusted input and must be owned by you and not group- or
other-writable.
<!-- src: settings.md#precedence -->

One compatibility layer sits between the shipped defaults and your local
files: the `OWNCLOUD_*` aliases of `nextcloudcmd` (the Nextcloud desktop
client's own `nextcloudcmd` tool, not this tool's `sciebo nextcloudcmd`
subcommand) and the desktop client are applied after `config/settings.env`
and before `config/settings.local.env` (see
[nextcloudcmd and desktop client aliases](#nextcloudcmd-and-desktop-client-aliases)).
An exported setting for this tool always wins over its alias.
<!-- src: settings.md#precedence -->

Values are validated when settings load: enumerated settings
(`BISYNC_CONFLICT_RESOLVE`, `BISYNC_RESYNC_MODE`, `BISYNC_CONFLICT_LOSER`,
`DEFAULT_PAIR_MODE`, `WATCH_BACKEND`, `METERED_POLICY`, `BLACKLIST_MODE`,
`BIG_FOLDER_POLICY`, `BIG_FOLDER_EXISTING_POLICY`,
`EXTERNAL_STORAGE_POLICY`, `SYMLINK_POLICY`, `INVALID_NAME_POLICY`,
`CASE_CLASH_POLICY`, `E2EE_POLICY`, and `PROXY_TYPE`), 0/1 switches,
non-negative integers, and the settings that must be non-empty all fail
fast with a clear message instead of a surprise mid-sync. `REMOTE_BASE` is
normalized (trailing slash removed) and must be a relative path without
`..` or `|`. `LOG_LEVEL` is passed to rclone unchanged, which rejects
unknown levels.
<!-- src: settings.md#precedence -->

Do not edit `config/settings.env` in a working tree: overrides belong in
`settings.local.env` or a profile, so updates keep working.
<!-- src: settings.md#precedence -->

## Common overrides

The shipped [`config/settings.local.env.example`](../config/settings.local.env.example)
lists the same set ready to uncomment. These are the changes most people
make first:
<!-- src: settings.md#common-overrides -->

```sh
# Gentle or faster transfers
TRANSFERS=1
LOG_LEVEL=INFO
BW_LIMIT_UP="2M"
MAX_DELETE=100

# Linux without secret-tool/pass or notify-send
KEYCHAIN=0
NOTIFY=0

# Keep overwritten/deleted local files on pull/bisync runs
BACKUP_DIR="$HOME/.cache/sciebo-backup"

# ...or move them to the per-source local trash instead (BACKUP_DIR wins)
MOVE_TO_TRASH=1
LOCAL_TRASH_DIR="$HOME/.local/share/sciebo/trash"

# Self-signed server (prefer fixing the certificate)
TLS_INSECURE=1

# Exclude hidden files like nextcloudcmd
SKIP_HIDDEN=1

# More download safety
MAX_DOWNLOAD_SIZE="10G"
BLACKLIST_MAX_FAILS=5

# Watch locally, stay gentle on metered links, keep disk headroom
WATCH_INTERVAL=30
METERED_POLICY="skip"
MIN_FREE_SPACE="512M"
FREE_SPACE_DOWNLOAD="1G"

# Explicit proxy (or PROXY_DIRECT=1 to ignore the environment)
PROXY="http://proxy.example.org:8080"

# Layer the server's sync-exclude list
FILTER_SERVER_SYNC=1

# Nightly scheduled run instead of 12:30
SCHEDULE_HOUR=22
SCHEDULE_MINUTE=0
```
<!-- src: settings.md#common-overrides -->

Put changes you want to keep in `config/settings.local.env`; export a
variable instead for a single run. See [Precedence](#precedence) for which
file wins when more than one sets the same setting.

## Profiles

An account profile is an independent account. Selecting one with
`--profile NAME` (or `SCIEBO_PROFILE=NAME`) moves the derived defaults into
the profile:
<!-- src: settings.md#profiles -->

| Path | Default profile | Named profile |
| --- | --- | --- |
| manifests | `config/sources.conf`, `config/folders.conf`, `config/sources.generated.conf`, `config/roots.conf` | `config/profiles/<name>/...` (same file names) |
| filters | `config/filters/` | `config/profiles/<name>/filters/` |
| state | `state/` | `state/profiles/<name>/` |
| Keychain service | `KEYCHAIN_SERVICE` | `rclone-sciebo/<name>` when the default service is unchanged |
<!-- src: settings.md#profiles -->

Profile names may contain letters, digits, dot, dash, and underscore;
`default` is reserved for the project-wide layout. Manage account profiles
with `sciebo account` (see [docs/commands.md](commands.md#account)).
<!-- src: settings.md#profiles -->

## Configuration files

| File | Owner | Purpose |
| --- | --- | --- |
| `config/settings.env` | project | shipped defaults; do not edit |
| `config/settings.local.env` | you | permanent local overrides (gitignored) |
| `.env` | you | `SCIEBO_URL`, `SCIEBO_USER`, `SCIEBO_APP_PASSWORD` for `setup` (gitignored) |
| `config/sources.conf` | you | manual sources |
| `config/roots.conf` | you | roots for `discover` |
| `config/folders.conf` | `sciebo folders` | wizard-managed pairs (manual edits are preserved by appends, not by `remove`) |
| `config/sources.generated.conf` | `sciebo discover --write` | generated sources (gitignored) |
| `config/filters/clutter.txt` | project/you | global rclone filter rules |
| `config/filters/pair-<name>.txt` | wizard | per-pair filter rules |
| `config/filters/fleeting.txt` | project/you | junk globs for `cleanup --junk` |
<!-- src: settings.md#configuration-files -->

The global option `--confdir DIR` (nextcloudcmd's `-confdir`) moves the
configuration base: the settings files, manifests, filters, and account
profiles are read from `DIR`, and the default state directory becomes
`DIR/state`. Only the settings file falls back to the shipped
`config/settings.env` when `DIR` has none; `.env` stays in the project root.
`--log-dir DIR` overrides `LOG_DIR` for the run, and `--log-expire HOURS`
sets the runtime `LOG_EXPIRE_HOURS` that `cleanup --logs` honors. All three
may appear anywhere on the command line (they are consumed before the
command parser).
<!-- src: settings.md#configuration-files -->

### sources.conf and folders.conf

All manifest files (the sync list's source files) share one format:
<!-- src: settings.md#sourcesconf-and-foldersconf -->

```
mode | local_path | remote_subdir [ | filter_file ]
```

- `mode`: `sync` (one-way upload), `pull` (one-way download), or `bisync`
  (two-way sync).
- `local_path`: absolute, `~`-prefixed, or relative to the project root. No
  `|` or control bytes, no surrounding whitespace.
- `remote_subdir`: path below `<RCLONE_REMOTE>:<REMOTE_BASE>/`. Not empty,
  not absolute, no `..` or `|`, no surrounding whitespace.
- `filter_file` (optional): a bare file name in `FILTER_DIR`; `..` and
  slashes are rejected and the file must exist.
<!-- src: settings.md#sourcesconf-and-foldersconf -->

Blank lines and `#`-comments are ignored. The sanitized entry name is derived
from `remote_subdir` (`repos/my-app` → `repos_my-app`; only `A-Za-z0-9._-`
survive) and names logs, run records, blacklist entries, lock records, and
bisync workdirs. Duplicate names fail `doctor`; `sync` refuses duplicated
`bisync` entries (they would share state) and warns about duplicated
`sync`/`pull` entries. Entries are read from `sources.conf`, then
`folders.conf`, then `sources.generated.conf`.
<!-- src: settings.md#sourcesconf-and-foldersconf -->

Example:

```
sync|~/Projects/my-app|repos/my-app
pull|~/Downloads/sciebo-share|shared/downloads
bisync|~/Notes|notes|notes-extra.txt
```

### roots.conf

```
mode | root | remote_base | maxdepth
```

- `mode`: applied to every repository found (`sync`, `pull`, or `bisync`).
- `root`: folder to scan, absolute or `~`-prefixed.
- `remote_base`: remote prefix for the repositories, relative to
  `<RCLONE_REMOTE>:<REMOTE_BASE>/`.
- `maxdepth`: how deep to look for `.git` (default 3; positive integer).
<!-- src: settings.md#rootsconf -->

`sciebo discover` collapses repositories nested in other repositories and
emits `mode|repo|remote_base/relpath` lines; `--write` saves them to
`config/sources.generated.conf`. Git only locates folders; contents,
including `.git/`, are synced like any other files.
<!-- src: settings.md#rootsconf -->

### filters

Filter files are [rclone filter files](https://rclone.org/filtering/), one
rule per line (`- pattern` excludes, `+ pattern` includes, `#` comments).
`clutter.txt` applies to every source; a manifest's `filter_file` and a pair
filter written by the wizard are layered on top. `sciebo hydrate` uses the
same layering as sync. `doctor` validates every `*.txt` file in `FILTER_DIR`
through rclone's own `--filter-from` parser. A directory containing a
`.nosync` file is skipped by `sync`, `pull`, and `hydrate` (bisync cannot
use `--exclude-if-present`).
<!-- src: settings.md#filters -->

`fleeting.txt` is different: it holds one shell glob per line for
`cleanup --junk`, matched against file names under each source's local
directory (conservative defaults: `.DS_Store`, `._*`, `Thumbs.db`, `*.part`,
`*.filepart`, `*.crdownload`).
<!-- src: settings.md#filters -->

### .env

Optional, only read by `setup` (and checked by `doctor`/`logout`):

```
SCIEBO_URL="https://your-university.sciebo.de"
SCIEBO_USER="alice@your-university.de"
SCIEBO_APP_PASSWORD="app-password"
```

`.env` is gitignored; `doctor` warns when it is group/other readable or
writable, and `logout` warns when it still contains an app password.
<!-- src: settings.md#env -->

## Settings reference

Boolean settings accept exactly `0` or `1`. Duration columns use the
`<N>[smhd]` form with a bare number meaning minutes where noted.
<!-- src: settings.md#settings-reference -->

### nextcloudcmd and desktop client aliases

The Nextcloud desktop client's own `nextcloudcmd` tool and the desktop
client itself are configured through `OWNCLOUD_*` environment variables.
For compatibility, these are mapped onto this tool's settings after
`config/settings.env` is sourced and before `config/settings.local.env`; an
exported setting wins over its alias, and a plain assignment in a
local or profile file beats both. Empty or unrecognized alias values are
ignored.
<!-- src: settings.md#nextcloudcmd-and-desktop-client-aliases -->

| Alias | Setting | Conversion |
| --- | --- | --- |
| `OWNCLOUD_CHUNK_SIZE` | `CHUNK_SIZE` | copied verbatim. |
| `OWNCLOUD_TIMEOUT` | `TIMEOUT` | bare seconds become `<N>s`; anything else is ignored. |
| `OWNCLOUD_MAX_PARALLEL` | `MAX_PARALLEL_SOURCES` | copied verbatim. |
| `OWNCLOUD_CRITICAL_FREE_SPACE_BYTES` | `MIN_FREE_SPACE` | copied verbatim (bytes). |
| `OWNCLOUD_FREE_SPACE_BYTES` | `FREE_SPACE_DOWNLOAD` | copied verbatim (bytes). |
| `OWNCLOUD_BLACKLIST_TIME_MIN` / `OWNCLOUD_BLACKLIST_TIME_MAX` | `BLACKLIST_TIME_MIN` / `BLACKLIST_TIME_MAX` | copied verbatim (seconds). |
| `OWNCLOUD_UPLOAD_CONFLICT_FILES` | `CONFLICT_UPLOAD` | `1`/`true`/`yes`/`on` become `1`; `0`/`false`/`no`/`off` become `0`. |
| `OWNCLOUD_HTTP2_ENABLED` | `HTTP2_ENABLED` | same boolean conversion. |
| `OWNCLOUD_MIN_CHUNK_SIZE` | `MIN_CHUNK_SIZE` | copied verbatim. |
| `OWNCLOUD_MAX_CHUNK_SIZE` | `MAX_CHUNK_SIZE` | copied verbatim. |
| `OWNCLOUD_TARGET_CHUNK_UPLOAD_DURATION` | `TARGET_CHUNK_UPLOAD_DURATION` | copied verbatim. |
<!-- src: settings.md#nextcloudcmd-and-desktop-client-aliases -->

The chunk aliases are desktop-client compatibility: `MIN_CHUNK_SIZE` and
`MAX_CHUNK_SIZE` clamp the upload chunk size, and
`TARGET_CHUNK_UPLOAD_DURATION` now drives the run-level derivation below
when a throughput is available. rclone still uploads each run with one fixed
chunk size, so the value is resolved once per run rather than per chunk.
<!-- src: settings.md#nextcloudcmd-and-desktop-client-aliases -->

### Connection

| Setting | Default | Meaning |
| --- | --- | --- |
| `RCLONE_REMOTE` | `sciebo` | name of the rclone remote (the connection to your account; also the keychain account). |
| `REMOTE_BASE` | `backup` | folder below the remote that all sources live in. |
| `RCLONE_CONFIG` | `${HOME}/.config/rclone/rclone.conf` | rclone config file path. |
| `RCLONE_BIN` | discovered | rclone binary; normally resolved from `PATH`, `RCLONE_BIN` wins when set and executable. |
| `CRYPT_REMOTE` | empty (derives `<RCLONE_REMOTE>-crypt`) | name of the rclone crypt remote `setup --crypt` creates, wrapping the configured WebDAV remote. |
<!-- src: settings.md#connection -->

### Transfer tuning

These become rclone flags per entry. Defaults are deliberately gentle for
sciebo (the service asks users to avoid hammering it and to keep sync
intervals large).
<!-- src: settings.md#transfer-tuning -->

| Setting | Default | Meaning |
| --- | --- | --- |
| `TRANSFERS` | `2` | `--transfers`. |
| `CHECKERS` | `4` | `--checkers`. |
| `TPSLIMIT` | `8` | `--tpslimit`. |
| `RETRIES` | `3` | `--retries`. |
| `LOW_LEVEL_RETRIES` | `10` | `--low-level-retries`. |
| `TIMEOUT` | `10m` | `--timeout`. |
| `CONTIMEOUT` | `30s` | `--contimeout`. |
| `STATS` | `30s` | `--stats` (with `--stats-one-line`). |
| `LOG_LEVEL` | `INFO` | `--log-level`; one of `DEBUG`, `INFO`, `NOTICE`, `WARNING`, `ERROR`. |
| `RETRIES_SLEEP` | empty | `--retries-sleep`: delay between rclone's high-level retries (e.g. `5s`); empty keeps rclone's default. |
| `TRANSFER_PARTIAL` | `0` | `1` passes `--partial`, keeping interrupted downloads for resume on backends that support it. |
| `TRANSFER_INPLACE` | `0` | `1` passes `--inplace`, writing straight to the destination instead of a temp file plus rename. |
<!-- src: settings.md#transfer-tuning -->

### rclone compatibility

| Setting | Default | Meaning |
| --- | --- | --- |
| `RCLONE_MIN_VERSION` | `1.69` | minimum `MAJOR.MINOR[.PATCH]`; `doctor` and `sync` refuse older binaries (bisync resilience flags need it). |
<!-- src: settings.md#rclone-compatibility -->

### Bisync

| Setting | Default | Meaning |
| --- | --- | --- |
| `BISYNC_CONFLICT_RESOLVE` | `newer` | `--conflict-resolve`: `none`, `newer`, `older`, `larger`, `smaller`, `path1`, `path2`. |
| `BISYNC_CONFLICT_LOSER` | `num` | `--conflict-loser`: `num`, `pathname`, or `delete`. |
| `BISYNC_CONFLICT_SUFFIX` | `(conflicted copy)` | text in the loser's new name; with `num` the result is `<name>.<suffix><N>`. |
| `BISYNC_RESILIENT` | `1` | add `--resilient`: retry recoverable errors instead of demanding `--resync`. |
| `BISYNC_RECOVER` | `1` | add `--recover`: resume interrupted runs. |
| `BISYNC_MAX_LOCK` | `2m` | `--max-lock`: expire a stale bisync workdir lock. |
| `BISYNC_RESYNC_MODE` | `newer` | `--resync-mode` on `--resync` runs (two-way sync's first-time reset); same values as `BISYNC_CONFLICT_RESOLVE`. |
<!-- src: settings.md#bisync -->

### Transfer safeguards

| Setting | Default | Meaning |
| --- | --- | --- |
| `CREATE_EMPTY_SRC_DIRS` | `0` | `1` passes `--create-empty-src-dirs`. |
| `TRACK_RENAMES` | `0` | `1` passes `--track-renames`. |
| `MAX_DELETE` | `-1` | `--max-delete`; `-1` means unlimited, `0` blocks all deletes. |
| `BW_LIMIT_UP` | empty | upload cap, e.g. `2M`; becomes `--bwlimit up:down`. |
| `BW_LIMIT_DOWN` | empty | download cap, e.g. `5M`. |
| `BW_SCHEDULE` | empty | rclone `--bwlimit` timetable, e.g. `Mon-Fri 08:00,2M Mon-Fri 18:00,off`. When set it takes precedence over `BW_LIMIT_UP`/`BW_LIMIT_DOWN`; an active `sciebo limit` marker beats both. |
| `CHUNK_SIZE` | empty | `--webdav-nextcloud-chunk-size`; empty follows the cached server capability or the run-level derivation below, and the value a sync/pull/bisync run uses is clamped to `MIN_CHUNK_SIZE`/`MAX_CHUNK_SIZE`. `setup` logs a suggestion when the server reports a different value; `doctor` reports the server's maximum. |
| `MIN_CHUNK_SIZE` | empty | lower bound for the chunk size a sync/pull/bisync run uses (rclone SizeSuffix, e.g. `5Mi`); a smaller value is clamped up and a warning names the bounds. Empty disables the bound. |
| `MAX_CHUNK_SIZE` | empty | upper bound for the chunk size (e.g. `100Mi`); a larger value is clamped down. Empty disables the bound. |
| `TARGET_CHUNK_UPLOAD_DURATION` | empty | desktop-client target chunk duration in milliseconds (the shipped example `60000` is 60s); an `s`/`m`/`h`/`d` suffix is also accepted. With `CHUNK_SIZE` unset and a throughput available, a run-level chunk is derived as `throughput * duration`, capped at the server maximum and `MIN_CHUNK_SIZE`/`MAX_CHUNK_SIZE`; without a throughput the server maximum is used. This is a once-per-run derivation, not per-chunk resizing. |
| `TARGET_UPLOAD_THROUGHPUT` | empty | upload throughput (rclone SizeSuffix in bytes per second, e.g. `10M`) used with `TARGET_CHUNK_UPLOAD_DURATION` to derive the run-level chunk. An active `BW_LIMIT_UP` wins over it; empty (or `BW_LIMIT_UP` empty) disables the derivation. |
| `CHECKSUM` | `0` | `1` compares transfers by checksum where the server supports it: `--checksum` for sync/pull, `--compare size,modtime,checksum` for bisync. |
| `BACKUP_DIR` | empty | preserve overwritten/deleted local files on `pull` runs under `BACKUP_DIR/<name>` (rclone `--backup-dir`). Empty disables the copies. |
| `SKIP_HIDDEN` | `0` | `0` syncs dot-files/directories (desktop-client behavior); `1` excludes them (nextcloudcmd's default). |
<!-- src: settings.md#transfer-safeguards -->

### Disk space guards

Both are rclone size suffixes (e.g. `512M`, `1G`) checked against the local
destination filesystem with `df -Pk`; empty disables the guard.
<!-- src: settings.md#disk-space-guards -->

| Setting | Default | Meaning |
| --- | --- | --- |
| `MIN_FREE_SPACE` | empty | a pull/bisync entry whose destination has less free space fails the run (the desktop client uses `512M`). |
| `FREE_SPACE_DOWNLOAD` | empty | a pull/bisync entry below this much free space is skipped, not failed (the desktop client uses `1G`). |
<!-- src: settings.md#disk-space-guards -->

`doctor` reports the free space of `STATE_DIR` against both thresholds.
<!-- src: settings.md#disk-space-guards -->

### Server quota warning

| Setting | Default | Meaning |
| --- | --- | --- |
| `QUOTA_WARN_PERCENT` | `0` | `sync` and `doctor` warn when the server quota used is at or above this percentage (integer `0`-`100`; `0` disables). The quota is read once per run with `rclone about --json`, and a probe error only warns. |
<!-- src: settings.md#server-quota-warning -->

The percentage is the floor of `used * 100 / total`; a server that reports no
quota (`total` of `0` or absent) is skipped. In `sync` the check runs once
before the entries and never fails a run; `doctor` reports it as
`quota: N% of <remote>: used` (WARN at or above the threshold, PASS below).
Both share one cached probe, so a run never queries the quota twice.
<!-- src: settings.md#server-quota-warning -->

### Conflict handling

| Setting | Default | Meaning |
| --- | --- | --- |
| `CONFLICT_UPLOAD` | `0` | `0` excludes local conflict copies from uploads (they stay on the machine that created them); `1` uploads them again. |
| `CONFLICT_PATTERN` | `conflicted copy` | substring `sciebo conflicts` matches in local file names and the exclusion pattern for uploads. |
| `MAX_DOWNLOAD_SIZE` | empty | ask/proceed guard for pull/bisync applies whose remote source is larger (rclone SizeSuffix, e.g. `10G`); empty disables the guard. |
| `ASK_DOWNLOAD_SIZE` | `1` | `1` lets an interactive apply ask before exceeding `MAX_DOWNLOAD_SIZE`; a non-interactive run skips the source unless `sync --yes`. |
<!-- src: settings.md#conflict-handling -->

### Desktop-parity policies

Folder and name safety policies modeled on the Nextcloud desktop client. The
wizard applies them when adding a pair, sync preflight applies them per
entry, and `doctor` scans and reports the active policies. A condition that
the policy does not allow skips the entry or pair with a warning instead of
failing the run.
<!-- src: settings.md#desktop-parity-policies -->

| Setting | Default | Meaning |
| --- | --- | --- |
| `SYMLINK_POLICY` | `skip` | how rclone treats symbolic links: `skip` (`--skip-links`, the desktop-client behavior), `follow` (`--copy-links`), or `translate` (`.rclonelink` files, `--links`). |
| `INVALID_NAME_POLICY` | `exclude` | Windows-invalid names (`<>:"\|?*`, brackets, trailing dot or space, reserved device names): `exclude` adds rclone exclude rules, `warn` scans local trees and warns, `allow` does nothing. |
| `CASE_CLASH_POLICY` | `exclude` | paths that differ only by case: `exclude` excludes the loser, `warn` only reports, `rename` quarantines a local loser as `<name> (case conflict)<ext>` on an apply. Applied to local trees by default and to the remote subtree only when `CASE_CLASH_REMOTE_SCAN=1`. |
| `CASE_CLASH_REMOTE_SCAN` | `0` | `1` adds an opt-in online scan of each source's remote subtree (`rclone lsf -R`, bounded by `POLICY_CASE_SCAN_LIMIT`) to the sync preflight and applies `CASE_CLASH_POLICY` to remote clashes too. Remote paths are never renamed: `warn` reports, `exclude` and `rename` both exclude the losing path (with a warning for `rename`). Off by default because a full remote listing is expensive. |
| `E2EE_POLICY` | `exclude` | server-side end-to-end encrypted folders on pull/bisync: `exclude` excludes them, `warn` only reports, `allow` syncs the encrypted blobs. An entry whose remote root is end-to-end encrypted is skipped unless `allow`. |
| `EXTERNAL_STORAGE_POLICY` | `ask` | remote roots on server-mounted external storage: `allow`, `warn`, `ask` (TTY confirmation, skipped otherwise), or `skip`. External subfolders only warn. |
| `BIG_FOLDER_POLICY` | `ask` | folder picker gate for a remote folder above `BIG_FOLDER_SIZE`: `warn` adds it with a warning, `ask` confirms on a TTY (skipped otherwise), `skip` refuses it. |
| `BIG_FOLDER_EXISTING_POLICY` | `warn` | sync preflight for an already-configured source whose remote grew past `BIG_FOLDER_SIZE`: `warn`, `skip`, or `allow`. |
<!-- src: settings.md#desktop-parity-policies -->

The end-to-end encryption and external-storage checks need a Nextcloud
WebDAV remote and a server that exposes the property; on other setups they
stay silent. See [docs/parity.md](parity.md) for how these policies map to
the desktop client's own behavior.
<!-- src: settings.md#desktop-parity-policies -->

### Delete guard and local trash

| Setting | Default | Meaning |
| --- | --- | --- |
| `DELETE_FILES_THRESHOLD` | `100` | deletion count at which the safety brake stops a run (non-negative integer). |
| `ASK_DELETE` | `1` | `1` arms the delete guard (`--max-delete DELETE_FILES_THRESHOLD`); `0` disables it. |
| `MOVE_TO_TRASH` | `0` | `1` moves files deleted or overwritten by a pull/bisync apply under `LOCAL_TRASH_DIR` (or `BACKUP_DIR`) instead of deleting them (rclone `--backup-dir`). |
| `LOCAL_TRASH_DIR` | empty (derives `<STATE_DIR>/trash`) | destination for `MOVE_TO_TRASH=1`, with the per-source `<name>` subdirectory appended. |
<!-- src: settings.md#delete-guard-and-local-trash -->

`MAX_DELETE` wins over the guard: an explicit `MAX_DELETE` of `0` or more is
passed as `--max-delete` unchanged and turns `ASK_DELETE` off. With the
default `MAX_DELETE=-1`, `ASK_DELETE=1` adds `--max-delete
DELETE_FILES_THRESHOLD` to every entry; when rclone aborts after the
threshold, an interactive run asks whether to re-run the entry without the
cap, while a declined prompt or a non-interactive run fails the entry and
tells you to re-run with `sync --yes`. `sync --yes` disables the guard (and
the `MAX_DOWNLOAD_SIZE` skip) for the run.
<!-- src: settings.md#delete-guard-and-local-trash -->

`MOVE_TO_TRASH` sets rclone `--backup-dir` for pull and bisync applies with
the per-source subdirectory appended. `BACKUP_DIR` takes precedence when
set: on pull it keeps its usual `<BACKUP_DIR>/<name>` behavior even with
`MOVE_TO_TRASH=0`, and on bisync `MOVE_TO_TRASH=1` uses `BACKUP_DIR` when
set, otherwise `LOCAL_TRASH_DIR`. Empty `LOCAL_TRASH_DIR` derives
`<STATE_DIR>/trash`.
<!-- src: settings.md#delete-guard-and-local-trash -->

### Failure blacklist

| Setting | Default | Meaning |
| --- | --- | --- |
| `BLACKLIST_ENABLED` | `1` | `1` tracks paths that error during sync/pull/bisync; `0` disables tracking entirely. |
| `BLACKLIST_MAX_FAILS` | `3` | a path erroring this many times is added to the retry blacklist and excluded from later runs until `sciebo retry` clears it. |
| `BLACKLIST_MODE` | `count` | `count` keeps the three-strikes behavior; `backoff` excludes a path only until its recorded retry time. |
| `BLACKLIST_TIME_MIN` | `25` | `backoff`: first retry delay in seconds. |
| `BLACKLIST_TIME_MAX` | `86400` | `backoff`: cap for the doubling delay, in seconds. |
<!-- src: settings.md#failure-blacklist -->

### HTTP and TLS

| Setting | Default | Meaning |
| --- | --- | --- |
| `HTTP_TIMEOUT` | `30` | curl timeout in seconds for the direct WebDAV/OCS calls made through `lib/adapters/http.sh` and `lib/adapters/nc_api.sh` (share, notifications, activity, presence, lock, trash, versions, file, search, recent, comments, favorites, tags). |
| `HTTP_RETRIES` | `2` | curl retries for those calls. |
| `HTTP_RETRY_DELAY` | `1` | seconds curl waits between retries (`--retry-delay`). |
| `HTTP_FOLLOW_REDIRECTS` | `1` | `1` makes GET/HEAD calls follow redirects up to `HTTP_MAX_REDIRS` hops (`--location`); writes never follow, so a POST/PUT body is never silently dropped. |
| `HTTP_MAX_REDIRS` | `5` | maximum redirect hops for GET/HEAD when `HTTP_FOLLOW_REDIRECTS=1` (`--max-redirs`). |
| `HTTP2_ENABLED` | `1` | `0` forces HTTP/1.1 (the desktop client default): rclone gets `--disable-http2` and the curl calls get `--http1.1`; `1` keeps the tools' HTTP/2 default. |
| `TLS_INSECURE` | `0` | `1` accepts invalid TLS certificates: rclone gets `--no-check-certificate` and the `lib/adapters/http.sh` curl calls get `--insecure`, including the server feature check. Also available per run as the global `--trust`. The browser sign-in flow's own curl calls verify certificates by default too and honor `--trust`/`TLS_INSECURE=1` as well (a one-time warning prints when verification is disabled). |
<!-- src: settings.md#http-and-tls -->

`HTTP_CONNECT_TIMEOUT` (environment, default `15`) bounds the connect phase
of every `lib/adapters/http.sh` curl call. It is a runtime knob, not a
`settings.env` key.
<!-- src: settings.md#http-and-tls -->

### Client certificates and User-Agent

Mutual TLS (mTLS), a custom trust store, and a User-Agent override, matching
the desktop client. All are empty by default. Each path must name an
existing, readable file when set: `lib/config/settings.sh` fails fast at
load time, while `doctor` (which sets `SCIEBO_SKIP_FILE_CHECKS=1`) reports
the missing file as a FAIL instead of aborting the report.
`CLIENT_KEY_PASSWORD` and `USER_AGENT` are not paths. Layering is the same
as every other setting (see [Precedence](#precedence));
`TLS_INSECURE`/`--trust` is independent.
<!-- src: settings.md#client-certificates-and-user-agent -->

| Setting | Default | Meaning |
| --- | --- | --- |
| `CLIENT_CERT` | empty | PEM client certificate; rclone `--client-cert`, curl `--cert`. |
| `CLIENT_KEY` | empty | PEM private key for `CLIENT_CERT`; rclone `--client-key`, curl `--key`. |
| `CLIENT_KEY_PASSWORD` | empty | plaintext passphrase for an encrypted `CLIENT_KEY`; rclone receives a reversibly-encoded (rclone calls this "obscured") `--client-pass` (sciebo encodes it first, because rclone expects that encoded value), and curl receives it through a mode-600 `--config` file (`pass = "..."`), never `--pass` in the visible command arguments. |
| `CA_CERT` | empty | PEM CA bundle used to verify the server instead of the system trust store; rclone `--ca-cert`, curl `--cacert`. |
| `USER_AGENT` | empty | overrides the HTTP User-Agent; rclone `--user-agent`, curl `-A`; empty keeps each tool's default. |
<!-- src: settings.md#client-certificates-and-user-agent -->

### Key storage

| Setting | Default | Meaning |
| --- | --- | --- |
| `KEYCHAIN` | `1` | `1` stores the plaintext app password in the system's password manager (`security` on macOS, `secret-tool`, or `pass` on Linux) so HTTP commands never reveal it; `0` keeps the reversibly-encoded ("obscured") password in the rclone config. |
| `KEYCHAIN_SERVICE` | `rclone-sciebo` | keychain service name; a named profile gets `rclone-sciebo/<name>` automatically when this is unchanged. New setups store the plaintext item under account `<RCLONE_REMOTE>#plain`; a legacy obscured item under the bare account name `RCLONE_REMOTE` is migrated on first use. See [Key storage backends](#key-storage-backends) for the full picture. |
<!-- src: settings.md#key-storage -->

### Server capabilities cache

| Setting | Default | Meaning |
| --- | --- | --- |
| `CAPABILITIES_MAX_AGE` | `86400` | seconds a cached server feature check (the OCS capabilities probe) stays fresh. |
<!-- src: settings.md#server-capabilities-cache -->

### Notifications

| Setting | Default | Meaning |
| --- | --- | --- |
| `NOTIFY` | `1` | master switch for desktop notifications (`osascript` on macOS, `notify-send` on Linux); `0` silences them, and without a backend every send is a no-op. |
| `NOTIFY_SUCCESS` | `0` | `1` also sends a notification for an apply run with no failures and no conflicts. |
| `NOTIFY_APPS` | empty | allowlist of notification app names used by `sciebo notifications`; empty means all (`--app` overrides for one run). |
| `NOTIFY_TYPES` | empty | allowlist of notification object types; empty means all (`--type` overrides for one run). |
| `NOTIFY_WATCH_INTERVAL` | `60` | default poll interval in seconds for `sciebo notifications --watch` (`--watch N` overrides). |
<!-- src: settings.md#notifications -->

An apply run sends at most one notification: failures win over conflict
copies, and conflicts win over `NOTIFY_SUCCESS`; a failure body also names
the conflict copies the run created. Dry runs, runs without sources, and a
missing notification backend stay silent. `NOTIFY` also gates the sends of
`notifications --notify`, `activity --notify`, `watch --notify`, and the
big-folder notice. The two allowlists match app and type names exactly and
case-sensitively; multiple values are comma, space, or colon separated.
<!-- src: settings.md#notifications -->

### Folder picker

| Setting | Default | Meaning |
| --- | --- | --- |
| `FOLDERS_SCAN_DEPTH` | `2` | how deep `sciebo folders choose` scans the remote. |
| `DEFAULT_PAIR_MODE` | `bisync` | suggested direction for new pairs (`sync`, `pull`, `bisync`). |
| `FOLDERS_LOCAL_ROOT` | `${HOME}/sciebo` | root for suggested local destinations. |
<!-- src: settings.md#folder-picker -->

### On-demand mounts

| Setting | Default | Meaning |
| --- | --- | --- |
| `MOUNT_ROOT` | `${HOME}/sciebo-mount` | root for mountpoints. |
| `MOUNT_CACHE_MAX_SIZE` | `5G` | `--vfs-cache-max-size` for read-write mounts. |
| `MOUNT_FILTERS` | `1` | apply `clutter.txt` (and a matching pair filter) to mounts. |
| `MOUNT_NO_SYNC` | `1` | pass `--exclude-if-present .nosync` (honored only where the mount backend supports it). |
| `MOUNT_EXTRA_FLAGS` | empty | extra raw rclone flags appended to `nfsmount`. |
<!-- src: settings.md#on-demand-mounts -->

### Scheduling

Used by `sciebo schedule` (scheduled runs) with the launchd (macOS) or
`systemd --user` (Linux) backend. On a system with only `crontab`, the
command refuses to manage the schedule and tells you to edit the crontab
yourself.
<!-- src: settings.md#scheduling -->

| Setting | Default | Meaning |
| --- | --- | --- |
| `LAUNCHD_LABEL` | `de.rclone-sciebo.sync` | label: launchd label and plist name, or the base name of the systemd units. |
| `SCHEDULE_HOUR` | `12` | hour (`0`–`23`) of the daily run when `SCHEDULE_INTERVAL` is empty (`StartCalendarInterval` / `OnCalendar`). |
| `SCHEDULE_MINUTE` | `30` | minute (`0`–`59`) of the daily run. |
| `SCHEDULE_INTERVAL` | empty | when set to a positive number of seconds, run on `StartInterval` / `OnUnitActiveSec` instead of daily. |
| `SCHEDULE_JITTER` | `0` | random delay in seconds before each run (`sleep $((RANDOM % N))` on launchd, `RandomizedDelaySec` on systemd). |
| `SCHEDULE_WATCH_PATH` | empty | also trigger a run when this path changes (`~` is expanded; the path must exist; `WatchPaths` / a systemd `.path` unit). |
| `SCHEDULE_AT_LOGIN` | `0` | `1` makes `schedule install` start the agent at login/boot (`RunAtLoad` on launchd, `[Install] WantedBy=default.target` on systemd); `--at-login` overrides. |
| `SCHEDULE_PROFILES` | empty | extra account profiles to render one agent each for, labelled `<LAUNCHD_LABEL>.<profile>` and run with `--profile`; comma or space separated; `--profiles` overrides. Empty means only the active profile. |
<!-- src: settings.md#scheduling -->

### Automatic sync (watch)

`sciebo watch` (live sync) watches the local directories of the configured
sources and runs `sync --apply --quiet --only NAME` when one changes. Like
`schedule`, this is opt-in: nothing runs in the background unless you start
it.
<!-- src: settings.md#automatic-sync-watch -->

| Setting | Default | Meaning |
| --- | --- | --- |
| `WATCH_INTERVAL` | `60` | poll interval in seconds, and the minimum seconds between two runs of the same source. |
| `WATCH_DEBOUNCE` | `10` | seconds to coalesce change events for one source. |
| `WATCH_REMOTE_INTERVAL` | `0` | seconds between remote-change checks (`check --quiet`, which notifies when the remote differs); `0` disables. |
| `WATCH_BACKEND` | `auto` | `auto`, `fswatch`, `inotify`, or `poll`; `auto` picks `fswatch`, then `inotifywait`, then the portable poll. |
<!-- src: settings.md#automatic-sync-watch -->

### Metered networks

| Setting | Default | Meaning |
| --- | --- | --- |
| `METERED_POLICY` | `allow` | `allow`, `ask`, or `skip` on a metered (pay-per-use or capped) connection; `ask` prompts on a TTY and skips otherwise. `sync --metered-ok` overrides it for one run. |
| `METERED_SSIDS` | empty | Wi-Fi names treated as metered on top of the OS report (comma or whitespace separated, case-insensitive exact match); hotspot-looking names (`iPhone`, `AndroidAP`, `Hotspot`, `tether`) are always metered. |
<!-- src: settings.md#metered-networks -->

### Server-side filters and big folders

| Setting | Default | Meaning |
| --- | --- | --- |
| `FILTER_SERVER_SYNC` | `0` | `1` passes the generated server exclude filter (`config/filters/server-exclude.txt`, written by `filters sync`) to sync/pull/bisync/hydrate ahead of `clutter.txt` and the entry filter. |
| `SERVER_EXCLUDE_MAX_AGE` | `604800` | seconds before `doctor` calls the cached server exclude list stale (7 days). |
| `BIG_FOLDER_SIZE` | empty | during pull/bisync entries, warn (and desktop-notify when `NOTIFY=1`) about unconfigured remote subfolders larger than this (rclone SizeSuffix, e.g. `10G`); each folder is reported once, and empty disables the scan. |
| `BIGFOLDER_SCAN_TTL` | `1h` | how long `bigfolder_notify` reuses a cached scan (under `STATE_DIR/bigfolder/scan-<name>`) before it scans the remote again (duration, e.g. `30m` or `2h`); `0` disables the cache and always scans. |
<!-- src: settings.md#server-side-filters-and-big-folders -->

`filters sync` caches the raw list under `SERVER_EXCLUDE_FILE` and
regenerates the rclone filter atomically. With `FILTER_SERVER_SYNC=1` the
generated filter is passed to rclone before `clutter.txt` and the entry
filter, so its rules match first. A missing cache is not layered at all,
and `doctor` warns; a stale cache is still layered, and `doctor` only warns
(against `SERVER_EXCLUDE_MAX_AGE`).
<!-- src: settings.md#server-side-filters-and-big-folders -->

### Housekeeping

| Setting | Default | Meaning |
| --- | --- | --- |
| `LOG_RETENTION_DAYS` | `14` | `cleanup --logs` deletes `*.log` older than this many days. |
| `LOG_MAX_BYTES` | `5M` | `cleanup --logs` rotates a larger `*.log` to `<file>.1`; empty disables rotation. |
| `LOG_EXPIRE_HOURS` | unset | runtime setting, set by the global `--log-expire HOURS` (or `SCIEBO_LOG_EXPIRE_HOURS`); `cleanup --logs` uses it as the minimum log age in hours and it wins over `LOG_RETENTION_DAYS`. |
| `CHUNK_CLEANUP_MIN_AGE` | `24h` | minimum age before `cleanup --uploads` may delete a chunk upload. |
| `STATE_CLEANUP_MIN_AGE` | `24h` | minimum age before `cleanup --state` may remove bisync workdirs, lock leftovers, temp files, or mount records. |
| `JUNK_CLEANUP_MIN_AGE` | `24h` | minimum age before `cleanup --junk` may delete a file matching a `fleeting.txt` glob. |
<!-- src: settings.md#housekeeping -->

The global `--log-dir DIR` overrides `LOG_DIR` (default `<STATE_DIR>/logs`)
for the run.
<!-- src: settings.md#housekeeping -->

### Run history and parallelism

| Setting | Default | Meaning |
| --- | --- | --- |
| `HISTORY_MAX_ENTRIES` | `50` | per-source run records kept for `sciebo status --history`; `0` disables the history files. |
| `MAX_PARALLEL_SOURCES` | `1` | how many sources one `sciebo sync` run processes at the same time; `1` is the gentle default. |
<!-- src: settings.md#run-history-and-parallelism -->

### Server extras

| Setting | Default | Meaning |
| --- | --- | --- |
| `SEARCH_LIMIT` | `20` | results requested by `sciebo search` (`--limit` overrides). |
| `RECENT_LIMIT` | `50` | files printed by `sciebo recent` (`--limit` overrides). |
| `AVATAR_SIZE` | `128` | avatar size in pixels for `sciebo account avatar` (`--size` overrides). |
| `COMMENTS_LIMIT` | `50` | comments listed by `sciebo comments`. |
| `FILE_ACTIVITY_LIMIT` | `50` | activity entries shown by `sciebo file activity` (`--limit` overrides). |
| `DOWNLOAD_DIR` | empty | directory a bare `sciebo download REMOTE` writes into (empty = the current directory). |
| `PREVIEW_SIZE` | `256` | pixels per side requested by `sciebo preview` (`--size` overrides). |
| `DEFAULT_PREVIEW_FILE` | `./preview` | file `sciebo preview` writes when `--output` is omitted (`--output -` writes to stdout). |
<!-- src: settings.md#server-extras -->

## Key storage backends

With `KEYCHAIN=1` (the default), the backend is selected by
`lib/adapters/platform.sh`:
<!-- src: settings.md#key-storage-backends -->

- macOS: the login Keychain via `security`.
- Linux: `secret-tool` (libsecret) when installed, otherwise `pass`. Both
  read the secret from stdin, so it never reaches the process arguments.
- New setups store the plaintext app password under service
  `KEYCHAIN_SERVICE` and account `<RCLONE_REMOTE>#plain`; the rclone config
  then holds a reversibly-encoded ("obscured") empty value. Keeping the
  plaintext in the keychain means the HTTP layer (`lib/adapters/http.sh`)
  reads it directly and never runs `rclone reveal`, whose visible-argument
  encoded value would be exposed to the process list.
- A legacy install that still holds the obscured password under the bare
  account name `RCLONE_REMOTE` is migrated once on first use: the obscured
  item is revealed in memory and rewritten to the `#plain` slot. The legacy
  item is left in place (the migration never reads it again) and `logout`
  deletes both items.
<!-- src: settings.md#key-storage-backends -->

Fallback: with `KEYCHAIN=0`, no backend installed, or `--no-keychain` /
`--rotate --no-keychain` for one run, the obscured password lives in the
rclone config (`rclone obscure`; a reversible encoding, not encryption) and
is still revealed with `rclone reveal` when the HTTP layer needs the
plaintext. `doctor` fails when `KEYCHAIN=1` is set but no backend exists,
reports the active backend, and warns when a keychain-enabled setup still
carries the password in the config.
<!-- src: settings.md#key-storage-backends -->

See [SECURITY.md](../SECURITY.md) for the full threat model.
<!-- src: settings.md#key-storage-backends -->

## TLS

Certificate verification is on by default. `TLS_INSECURE=1` or the global
`--trust` flag accepts invalid certificates for rclone and the
`lib/adapters/http.sh` curl calls (`--no-check-certificate` / `--insecure`),
including the OCS server feature check; use it only on trusted networks
against self-signed servers, and prefer fixing the certificate. The browser
sign-in flow's own curl calls verify certificates by default as well;
`--trust`/`TLS_INSECURE=1` disables that check too, printing a one-time
warning.
<!-- src: settings.md#tls -->

## Proxy

| Setting | Default | Meaning |
| --- | --- | --- |
| `PROXY_TYPE` | `system` | proxy mode: `system` uses `PROXY` when set and otherwise the standard `HTTP_PROXY`/`HTTPS_PROXY` environment (`PROXY_DIRECT=1` strips it), `none` ignores all proxy settings, and `http`/`socks5` require `PROXY` and use it explicitly. |
| `PROXY` | empty | explicit proxy URL, e.g. `http://proxy.example.org:8080` or `socks5://127.0.0.1:1080`; empty keeps the standard environment variables. |
| `PROXY_DIRECT` | `0` | `1` ignores the proxy environment for rclone and curl in `system` mode. |
<!-- src: settings.md#proxy -->

Behavior: an explicit `http://` or `https://` `PROXY` is exported to the
rclone and `lib/adapters/http.sh` curl children through
`HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY`, so any embedded credentials never
appear in the process's visible arguments. A `socks5://` `PROXY` keeps the
explicit flags instead (`--http-proxy` for rclone, `-x URL` for curl;
environment socks support is not guaranteed), so its credentials remain
visible to anyone who can list processes. `PROXY_DIRECT=1` strips
`HTTP_PROXY` / `HTTPS_PROXY` (and their lowercase forms, plus `ALL_PROXY`)
from rclone's child environment and passes `--noproxy '*'` to curl. When
both are set, `PROXY_DIRECT` wins (`doctor` and `network` report the
effective mode). `PROXY_TYPE` selects which of these layers applies:
`system` (the default) keeps the behavior above, `none` ignores all proxy
settings, and `http`/`socks5` take the proxy from `PROXY` (missing `PROXY`
is an error, never a silent direct connection).
<!-- src: settings.md#proxy -->

The underlying tools otherwise read the standard variables directly:

- `HTTPS_PROXY` / `HTTP_PROXY` — proxy URL for rclone and curl.
- `NO_PROXY` — comma-separated hosts that bypass the proxy.
<!-- src: settings.md#proxy -->

Set them in the environment that runs `sciebo` (scheduler agents do not
inherit your shell environment; use a wrapper, the launchd plist, or a
systemd `Environment=` line).
<!-- src: settings.md#proxy -->

## State layout

With the default profile, `STATE_DIR` (this tool's local record-keeping
folder) is `state/` in the project checkout (under `<confdir>/state` when
`--confdir` is used). Named account profiles use
`state/profiles/<name>/`.
<!-- src: settings.md#state-layout -->

| Path | Contents |
| --- | --- |
| `state/logs/` | per-source rclone logs (`<name>-<stamp>[-dryrun].log`), mount logs, scheduler output |
| `state/locks/sync.lock/` | the single-run lock (pid + process start time) |
| `state/bisync/<name>/` | rclone bisync bookkeeping; required before a bisync entry runs |
| `state/last/<name>` | last-run record for `sciebo status` |
| `state/history/<name>.log` | run history for `sciebo status --history` |
| `state/blacklist/<name>` | failure-count records for the retry blacklist |
| `state/trash/<name>/` | local trash for `MOVE_TO_TRASH=1` pulls/bisyncs (unless `LOCAL_TRASH_DIR` or `BACKUP_DIR` is set) |
| `state/remote-locks/<name>.state` | lock tokens recorded by `sciebo lock` |
| `state/notifications-seen`, `state/activity-seen` | ids already reported by `--notify` |
| `state/mounts/<name>.state` | recorded mounts |
| `state/mount-cache/` | rclone VFS cache for read-write mounts |
| `state/capabilities.env`, `state/capabilities.json` | cached server feature check (parsed and raw) |
| `state/watch/` | watcher pid record (`watch.pid`), per-source poll markers and last-run stamps |
| `state/bwlimit` | active `sciebo limit` marker (`until`, `up`, `down`) |
| `state/sync-exclude.lst` | cached raw server sync-exclude list fetched by `filters sync` |
| `state/bigfolder/<name>` | large unconfigured remote folders already reported per source, and `scan-<name>` a cached scan reused for `BIGFOLDER_SCAN_TTL` |
| `state/support-<stamp>.tar.gz` | redacted debug archives written by `support` |
| `state/nextcloudcmd/<key>/` | per-URL bisync workdirs used by this tool's nextcloudcmd-compatible command |
| `state/paused` | pause marker (`until=<epoch>`; `0` = indefinite) |
| `state/pairs/<name>` | per-pair flags (`paused=1`, `hidden=1`; mode 600) written by `folders pause`/`folders resume` and `account import` |
| `state/VERSION` | state layout version used by migrations |
| `config/filters/server-exclude.txt` | generated rclone filter from the server exclude list (layered when `FILTER_SERVER_SYNC=1`) |
<!-- src: settings.md#state-layout -->

`bin/sciebo` sets `umask 077`, and records are written atomically with mode
600. A state directory written by a newer layout version is refused so an
old binary cannot corrupt it (see
[docs/architecture.md](architecture.md#state-and-configuration)).
<!-- src: settings.md#state-layout -->

## Path overrides (isolated runs)

This section is for contributors and test authors: every path below can be
overridden from the environment, and commands never write outside them.
This is how the test suites stay isolated; day-to-day use of this tool does
not need it.
<!-- src: settings.md#path-overrides-isolated-runs -->

| Variable | Default (default profile / named profile) |
| --- | --- |
| `SCIEBO_CONFDIR` | unset; set by `--confdir DIR`, which moves the whole configuration base |
| `SETTINGS_FILE` | `config/settings.env` (falls back to the project copy under `--confdir`) |
| `SETTINGS_LOCAL_FILE` | `config/settings.local.env` |
| `ENV_FILE` | `.env` in the project root |
| `SCIEBO_LOG_DIR` | unset; set by `--log-dir DIR`, which overrides `LOG_DIR` |
| `SCIEBO_LOG_EXPIRE_HOURS` / `LOG_EXPIRE_HOURS` | unset; set by `--log-expire HOURS` |
| `PROFILES_DIR` | `config/profiles` |
| `PROFILES_STATE_DIR` | `state/profiles` |
| `PROFILE_DIR` | `config/profiles/<name>` when a profile is active |
| `SETTINGS_PROFILE_FILE` / `SETTINGS_PROFILE_LOCAL_FILE` | `<profile>/settings.env` / `<profile>/settings.local.env` |
| `MANIFEST_FILE` | `config/sources.conf` / `<profile>/sources.conf` |
| `FOLDERS_FILE` | `config/folders.conf` / `<profile>/folders.conf` |
| `MANIFEST_GENERATED_FILE` | `config/sources.generated.conf` / `<profile>/sources.generated.conf` |
| `ROOTS_FILE` | `config/roots.conf` / `<profile>/roots.conf` |
| `FILTER_DIR` | `config/filters` / `<profile>/filters` |
| `STATE_DIR` | `state` / `state/profiles/<name>` |
| `PAIR_FLAGS_DIR` | `<STATE_DIR>/pairs` (not derived when `STATE_DIR` is empty) |
| `LOG_DIR` | `<STATE_DIR>/logs` |
| `LOCK_DIR` | `<STATE_DIR>/locks` |
| `BISYNC_DIR` | `<STATE_DIR>/bisync` |
| `MOUNTS_DIR` | `<STATE_DIR>/mounts` |
| `MOUNT_CACHE_DIR` | `<STATE_DIR>/mount-cache` |
| `RUNSTATE_DIR` | `<STATE_DIR>/last` |
| `PAUSE_FILE` | `<STATE_DIR>/paused` |
| `CAPABILITIES_CACHE` / `CAPABILITIES_JSON` | `<STATE_DIR>/capabilities.env` / `.json` |
| `REMOTE_LOCKS_DIR` | `<STATE_DIR>/remote-locks` |
| `NOTIFICATIONS_SEEN` / `ACTIVITY_SEEN` | `<STATE_DIR>/notifications-seen` / `activity-seen` |
| `BLACKLIST_DIR` | `<STATE_DIR>/blacklist` |
| `HISTORY_DIR` | `<STATE_DIR>/history` |
| `LOCAL_TRASH_DIR` | `<STATE_DIR>/trash` |
| `WATCH_DIR` | `<STATE_DIR>/watch` |
| `BW_LIMIT_FILE` | `<STATE_DIR>/bwlimit` |
| `SERVER_EXCLUDE_FILE` | `<STATE_DIR>/sync-exclude.lst` |
| `SERVER_EXCLUDE_FILTER` | `<FILTER_DIR>/server-exclude.txt` |
| `STATE_VERSION_FILE` | `<STATE_DIR>/VERSION` |
<!-- src: settings.md#path-overrides-isolated-runs -->

### Development knobs

Also for contributors and test authors. These are read from the environment
by specific commands; they exist mainly for tests and debugging and are not
part of the supported surface:
<!-- src: settings.md#development-knobs -->

| Variable | Default | Used by |
| --- | --- | --- |
| `LOGIN_FLOW_POLL_INTERVAL` / `LOGIN_FLOW_TIMEOUT` / `LOGIN_FLOW_MAX_POLLS` | `2` / `1200` / unset | `setup --login` polling (the browser sign-in flow). |
| `LOGIN_FLOW_NO_BROWSER` | unset | print the login URL instead of opening a browser. |
| `DOCTOR_NAME_SCAN_LIMIT` | `50000` | cap on paths inspected per source by the `doctor` name-hygiene scan. |
| `SCIEBO_KEYCHAIN_BACKEND` / `SCIEBO_NOTIFY_BACKEND` / `SCIEBO_SCHEDULER_BACKEND` / `SCIEBO_NETWORK_BACKEND` | unset | override backend probing in `lib/adapters/platform.sh` (tests; the network backend accepts `macos`, `linux`, or `none`). |
<!-- src: settings.md#development-knobs -->

## Limitations

- Do not edit `config/settings.env` in a working tree; overrides belong in
  `settings.local.env` or a profile, so an update to the project does not
  overwrite them.
  <!-- src: settings.md#precedence -->
- `REMOTE_BASE` must be a relative path with no `..` and no `|`.
  <!-- src: settings.md#precedence -->
- `commands.md` documents that `doctor`'s end-to-end-encryption, external
  storage, and big-folder scans use a setting named
  `DOCTOR_REMOTE_SCAN_LIMIT`, but this document's Settings reference has no
  row for it and it is not one of the keys defined in
  `config/settings.env`. This is a gap in the source documentation, not a
  contradiction: rather than invent a default, this rewrite carries the gap
  forward. Check `config/settings.env` and `lib/commands/doctor.sh` directly
  if you need that setting's current default.
- The path-override table and the development knobs are for contributors
  and test authors; they are not part of the day-to-day settings surface
  and (for the development knobs) are explicitly not a supported interface
  that will stay stable.
  <!-- src: settings.md#path-overrides-isolated-runs -->

## Glossary

Terms used on this page, in plain wording:

| Term | Meaning |
| --- | --- |
| sciebo | The Hochschulcloud.NRW cloud storage service for NRW universities; this project is an unofficial client for it. |
| `sciebo` (command) | The command this tool installs; named after the service. |
| Nextcloud | The open-source server software sciebo and other institutions run; this tool talks to any Nextcloud server, not only sciebo. |
| rclone | The third-party file-transfer engine this tool is built on; this tool configures and runs it rather than talking to the server directly for transfers. |
| remote / rclone remote (the connection to your account) | A named rclone configuration entry (default name `sciebo`) that holds the server URL and how to authenticate. Not the same as "remote" meaning "on the server" in casual use. |
| the network protocol this tool uses to talk to Nextcloud (WebDAV) | The file-access protocol rclone and this tool's direct HTTP calls use against the server. |
| app password (a password just for this tool) | A Nextcloud-issued password scoped to one application/device, used instead of the account's main password. |
| the browser sign-in flow (Login Flow v2) | Nextcloud's browser-based authentication handshake that `setup --login` drives; produces an app password without the user typing one in. |
| the system's password manager (keychain) | The OS-level secret store (macOS Keychain, Linux secret-tool/pass) this tool prefers for the app password over the rclone config file. |
| the sync list (manifest) | The set of configured folder pairs (from `sources.conf`, `folders.conf`, `sources.generated.conf`) that `sync`/`check`/etc. act on. |
| a configured folder pair (folder pair / source / entry) | One line in the sync list: a local folder, a remote folder, and a direction. |
| one-way upload (sync) | Direction that mirrors local → remote; local deletions are sent to the server. |
| one-way download (pull) | Direction that mirrors remote → local; local deletions from this run are permanent unless a backup/trash setting is on. |
| two-way sync (bisync) | Direction that reconciles both sides; needs one-time initialization and can create conflict copies. |
| a preview that changes nothing (dry run) | A run (`check`, or any command's `--dry-run`) that reports the plan without transferring, deleting, or writing state. |
| the safety brake on deletions (delete guard) | A check that stops a run before it deletes more files than a configured threshold, asking for confirmation instead. |
| two-way sync's first-time reset (bisync resync) | The one-time `--resync` step that initializes bisync's bookkeeping; can copy or delete files on both sides and must be reviewed as a dry run first. |
| a conflict copy | A file bisync creates when both sides changed the same file, kept alongside the original rather than silently overwriting. |
| end-to-end encryption (E2EE) | Nextcloud's client-side encryption feature; this tool (like rclone) only ever sees the encrypted bytes and excludes E2EE folders by default. |
| server-mounted external storage | A Nextcloud folder backed by another storage system on the server side (not local disk), which this tool treats more cautiously by default. |
| Nextcloud's API (OCS) | Nextcloud's Open Collaboration Services API, used for shares, notifications, activity, and other non-file operations. |
| the server feature check (capabilities probe) | A one-time-per-cache-window API call that discovers what the connected server supports (chunk size, trashbin, checksums, version). |
| account profile (profile) | An independent, named account setup (its own remote, sync list, filters, and state), used to manage more than one Nextcloud account. |
| a filter file | A plain-text rule file (rclone syntax) that excludes or includes paths from a sync. |
| a safety policy (policy, e.g. E2EE_POLICY) | A named setting that chooses how this tool reacts to a risky situation: allow it, warn, ask first, or skip/exclude it. |
| this tool's local record-keeping folder (state directory) | Where this tool stores run history, locks, caches, and other bookkeeping, separate from your synced files. |
| the single-run lock (run lock) | A safeguard that stops two sync/cleanup runs from overlapping on the same machine. |
| a metered (pay-per-use or capped) network | A connection this tool can detect and treat more cautiously, e.g. a mobile hotspot. |
| the retry blacklist (blacklist) | The list of paths this tool has temporarily stopped retrying after repeated failures, until `sciebo retry` clears them. |
| live sync (watch) | An optional, foreground command that syncs a folder as soon as it changes; not a background service. |
| scheduled runs (schedule) | An optional, installable background job (via the OS's own scheduler) that runs sync periodically; opt-in, not automatic. |
| the Nextcloud desktop client's `nextcloudcmd` tool | The separate, third-party command-line tool that ships with Nextcloud's desktop client packages. |
| this tool's nextcloudcmd-compatible command (`sciebo nextcloudcmd`) | This project's own command, built to accept the external tool's option names for easy migration; not the same program. |
<!-- src: rewrite_report.md#shared-terminology-table -->
