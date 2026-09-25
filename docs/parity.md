# Nextcloud Desktop parity

rclone-webdav-sync is an unofficial command-line client for sciebo (Hochschulcloud.NRW) and other Nextcloud servers. This page tracks how far it matches the [Nextcloud Desktop client](https://docs.nextcloud.com/desktop/latest/user_manual/index.html), feature by feature. "Parity" means the same job can be done from the CLI with the same safety properties, such as excluding risky files by default or asking before a big deletion; it does not mean a GUI or the same look and feel.
<!-- src: parity.md -->

Three groups:

1. [Parity implemented](#parity-implemented)
2. [Implementable but not yet done](#implementable-but-not-yet-done)
3. [Not implementable](#not-implementable)

See the README's [comparison with `nextcloudcmd`](../README.md#compared-with-nextcloudcmd) for how this differs from the desktop client's single-shot command-line sync, and the [non-affiliation note](../README.md#not-affiliated-with-nextcloud-or-sciebo): this project is independent and not affiliated with, endorsed by, or supported by Nextcloud GmbH or the sciebo service operators.

## Parity implemented

The table below lists every desktop-client feature this tool matches today, split into five groups so a specific feature is easy to find rather than scanning one long list: account and setup, syncing your files, safety and policies, server features, and monitoring/connection tooling. Each row names the command or setting and how the behavior compares.
<!-- src: parity.md#parity-implemented -->

### Account and setup

Everything the desktop client's setup wizard and account manager do, this tool does as commands:

| Desktop client feature | `sciebo` equivalent | Notes |
| --- | --- | --- |
| Account setup with Login Flow / app password | `setup --login`, `setup`, `setup --rotate` | Login Flow v2 in the browser; app password in the platform keychain by default (`security`, `secret-tool`, or `pass`). The keychain stores the plaintext under account `<remote>#plain` (a legacy obscured item is migrated once on first use), so HTTP-backed commands no longer run `rclone reveal`. |
| App-password self-revocation | `logout --revoke` | Revokes the active app password server-side (OCS `DELETE /ocs/v2.php/core/apppassword`) before removing the local credentials; the revoke runs first so the stored secret is still available, and a failed revoke only warns, so the local logout still completes. |
| Provisioning flags for mass deployment (`--userid`, `--apppassword`, `--serverurl`, `--localdirpath`, ...) | `provision --userid USER --apppassword PASS --serverurl URL [--localdirpath PATH] [--remotedirpath PATH] [--isvfsenabled 0\|1] [--profile NAME]` | Non-interactive create-or-update of profile, rclone remote, and one `bisync` pair when `--localdirpath` is given (`--remotedirpath /` means the remote base). `--isvfsenabled 1` is accepted and ignored because there are no virtual files. The password is never printed; keychain by default, else obscured in the rclone config. |
| Migration from the desktop client | `account import [--nextcloud-cfg FILE] [--profile SELECTOR] [--dry-run] [--yes] [--json]` | Reads `nextcloud.cfg` (the macOS app container/legacy path, Linux, or `%APPDATA%`): `[Accounts]` become profiles (account 0 is `default`), folder entries become `bisync` pairs, and the mapped `[General]` options (chunk sizes, timeout, `moveToTrash`, delete threshold, login start, big-folder size, debug logging) land in `settings.local.env`. Passwords are never imported: run `setup --login` (or `setup --rotate`) per profile afterwards. |
| Multiple accounts | `account add/list/remove/use`, global `--profile`, `logout` | Each profile has its own remote, manifests, filters, state, locks, and keychain service. |
| Account information and avatar | `account info [--json]`, `account avatar [--output FILE] [--size N]`, `account status [--json]` | Read-only: user id, display name, email, quota, and server version, plus the avatar image; `account status` reports remote, reachability, capabilities cache age, and keychain backend. |
<!-- src: parity.md#parity-implemented -->

### Syncing your files

Choosing folders, running syncs, detecting changes, and the settings that shape a transfer:

| Desktop client feature | `sciebo` equivalent | Notes |
| --- | --- | --- |
| Sync folder connections (local folder ↔ server folder) | `sync`, `pull`, `bisync` entries in `config/sources.conf` / `folders.conf` | One direction per source; `check` dry-runs, `sync` applies. |
| Selective sync | `folders choose --select`, `folders add --include/--exclude`, `folders edit NAME [--include/--exclude/--mode/--clear/--select]`, pair filters | Include picks are written as excludes for everything not picked; `folders edit` rewrites an existing wizard pair's filter without removing and re-adding it. |
| Change a pair's local or remote path | `folders edit NAME --local PATH`, `folders edit NAME --remote SUB [--force]` | Rewrites the wizard-managed pair (`~` expands, `/` or an empty `--remote` means the remote base). A `--remote` change renames the pair and its filter and refuses a duplicate remote or clashing name; it is refused when initialized bisync state exists unless `--force`, and the stale state is kept, so re-run `sync --resync`. |
| Automatic change detection | `watch [--interval/--debounce/--backend/--only/--remote-interval/--once/--notify/--no-notify]` | Foreground, opt-in command, not a daemon: an installed `fswatch` or `inotifywait` streams events, otherwise portable polling. Changes are debounced and rate-limited per source. `--remote-interval` runs a dry-run check and only notifies (`check` never transfers); `--no-notify` forces notifications off. It is not notify_push. |
| Start at login / scheduled runs | `schedule install --at-login [--profiles LIST]`, `SCHEDULE_AT_LOGIN`, `SCHEDULE_PROFILES` | launchd `RunAtLoad` / systemd `WantedBy=default.target`; `--profiles` renders one periodic agent per profile, each with `--profile`. Periodic (`sync --apply --quiet`), not a persistent daemon. |
| Pause syncing | `pause [--for DURATION]`, `resume` | Indefinite or timed; an expired marker clears itself. |
| Conflict handling | `BISYNC_CONFLICT_RESOLVE/LOSER/SUFFIX`, `conflicts [--kind copy\|case\|all] [--remote] [--open]`, `conflicts --resolve MODE [--apply] [--yes]`, `CONFLICT_UPLOAD`, `CONFLICT_PATTERN` | See the caveat below; conflict copies stay local by default and can be reviewed and resolved locally in a batch. The `case` kind lists names quarantined by `CASE_CLASH_POLICY=rename` (or, with `--remote`, names that differ only by case on the server), and `--open` opens the affected directories. |
| Ignored-files editor | `config/filters/clutter.txt`, `pair-<name>.txt`, manifest `filter_file`, `.nosync`, `filters list/show/check` | Plain rclone filter files; `doctor` validates every one with rclone's parser. |
| "Not synced" list | `ignored [SUB] [--source NAME] [--json]` | Lists the local files sync would not transfer for the same reasons and with the same filter layering (clutter, pair filter, server excludes, conflict copies, hidden files, blacklist, `.nosync`). Read-only and local. |
| Server's canonical exclude list | `filters sync`, `FILTER_SERVER_SYNC=1`, `SERVER_EXCLUDE_MAX_AGE` | Fetches the server's `sync-exclude.lst`, caches it, and regenerates `server-exclude.txt`; with `FILTER_SERVER_SYNC=1` the generated file is layered under every source. `filters list` shows cache age and staleness. |
| Bandwidth settings | `BW_LIMIT_UP`, `BW_LIMIT_DOWN`, `BW_SCHEDULE`, `limit [--up/--down/--until/--show/--clear/--json]`, `unlimited`, `TRANSFERS`, `CHECKERS`, `TPSLIMIT` | Applied as rclone flags per entry. Precedence: an active `limit` marker (expires by itself or with `unlimited`) > `BW_SCHEDULE` timetable > static caps. |
| "Edit locally" (download, open, upload one file) | `edit SUB [--editor CMD] [--no-upload] [--lock]` | Downloads one file below a configured source (first manifest entry whose remote subdir equals or is a parent of SUB), opens `--editor CMD` / `$EDITOR` / `$VISUAL`, and uploads again only when the file changed. Without an editor it hands the file to the platform opener and skips the upload; `--lock` takes a WebDAV lock for the edit and releases it afterwards. |
| On-demand/Virtual Files access | `mount` / `umount` / `mounts`, `hydrate SUB`, `edit SUB`, `cleanup --cache` | Closest analog: an `rclone nfsmount` filesystem fetched on first access, `hydrate` to download a path explicitly with sync's filter layering, and `edit` for one file. `cleanup --cache` manages the mount cache. Not a Finder/Explorer overlay. |
| Upload chunk bounds and run-level chunk sizing | `CHUNK_SIZE`, `MIN_CHUNK_SIZE`, `MAX_CHUNK_SIZE`, `TARGET_CHUNK_UPLOAD_DURATION`, `TARGET_UPLOAD_THROUGHPUT` | `CHUNK_SIZE` is clamped to the bounds. When it is unset, a chunk is derived once per run from the desktop `TARGET_CHUNK_UPLOAD_DURATION` (milliseconds) times `BW_LIMIT_UP` (or `TARGET_UPLOAD_THROUGHPUT` when the cap is empty), capped at the server's maximum and clamped to the bounds; without a throughput the capability maximum is used. The derivation is run-level, not per-chunk adaptation, because rclone uploads with one fixed chunk size. |
| `nextcloudcmd` command-line usage | `sciebo nextcloudcmd [OPTIONS] SOURCEDIR NEXTCLOUDURL`, `folders import`, `SKIP_HIDDEN` | One two-way run per invocation with nextcloudcmd's sync options (`-u/-p/-n/-s/-h`, `--path`, `--exclude`, `--exclude-anchored FILE`, `--unsyncedfolders`, `--max-sync-retries`, `--uplimit`, `--downlimit`, `--logdebug`, `--verbose`, `-v/--version`, `--httpproxy`, `--trust`, `--confdir`, `--non-interactive`) plus `--dry-run`, which this tool adds as an extension. `-v`/`--version` prints the version, `--verbose` is the debug alias, `--exclude-anchored` reads a pattern file anchored at the sync root, and `--max-sync-retries` loops the whole sync while a dry-run probe still reports changes. The first run initializes bisync state automatically. |
| Transfer progress display | `download --progress`, `hydrate --progress`, `nextcloudcmd --progress`/`-P` | rclone's `-P`, appended only when stdout is a terminal and the run is not quiet (`--quiet`/`--json`/`--silent`); the `nextcloudcmd` `--max-sync-retries` probe never shows a bar. |
| Resumable/atomic transfers | `RETRIES_SLEEP`, `TRANSFER_PARTIAL`, `TRANSFER_INPLACE` | `--retries-sleep` spaces high-level retries; `--partial` keeps interrupted downloads for resume on supporting backends; `--inplace` writes directly to the destination. |
| Per-pair pause and hidden files | `folders pause NAME`, `folders resume NAME`, `PAIR_FLAGS_DIR`, `account import` | The desktop client's per-folder pause and `ignoreHiddenFiles` are stored as a mode-600 `paused`/`hidden` flag file per sanitized pair (default `<STATE_DIR>/pairs`). A paused pair is reported as skipped by `sync`/`check` unless `sync --force`; a hidden pair adds the same `.*` exclusion as `SKIP_HIDDEN=1`, for that pair only. |
<!-- src: parity.md#parity-implemented -->

### Safety and policies

The desktop client's safe-by-default behavior, skipping risky files, asking before a big deletion, and throttling to protect the server, has a direct equivalent:

| Desktop client feature | `sciebo` equivalent | Notes |
| --- | --- | --- |
| Case-only name collisions | `CASE_CLASH_POLICY=warn\|exclude\|rename` (`exclude` by default), `CASE_CLASH_REMOTE_SCAN`, `conflicts --kind case [--remote]`, `conflicts --open` | The sync preflight scans each local source (bounded by `POLICY_CASE_SCAN_LIMIT`): `exclude` drops the later path, `rename` quarantines it as `<name> (case conflict)<ext>`, `warn` only reports. `conflicts --kind case --remote` (or `CASE_CLASH_REMOTE_SCAN=1` during a sync) applies the same decision to a remote listing; remote paths are never renamed, so `rename` excludes the losing path there instead. |
| Metered networks / "ask before sync" | `network [--json]`, `METERED_POLICY=allow/ask/skip`, `METERED_SSIDS`, `sync --metered-ok` | `skip` refuses metered runs, `ask` prompts on a TTY and skips otherwise; `--metered-ok` overrides for one run. Linux reads NetworkManager's `connection.metered`; macOS has no OS metered flag, so detection uses the Wi-Fi SSID, `METERED_SSIDS`, and hotspot-looking names. |
| Low disk space | `MIN_FREE_SPACE`, `FREE_SPACE_DOWNLOAD`, `doctor` free-space check | Pull/bisync entries fail below `MIN_FREE_SPACE` and are skipped below `FREE_SPACE_DOWNLOAD`; `doctor` reports free space on the state filesystem. |
| Windows-invalid and non-portable file names | `INVALID_NAME_POLICY=warn\|exclude\|allow` (`exclude` by default), `doctor` name hygiene | Matches the desktop client's "names it never syncs": Windows-invalid characters (`<>:"\|?*`), brackets, trailing dot or space, and reserved device names (`CON`, `COM1`, ...) are excluded from the transfer and reported by `doctor`. `warn` reports only and `allow` syncs them. |
| E2EE and external-storage gates | `E2EE_POLICY=warn\|exclude\|allow` (`exclude`), `EXTERNAL_STORAGE_POLICY=allow\|warn\|ask\|skip` (`ask`) | Checked by the sync preflight, `doctor`, and `folders choose`. For pull/bisync entries, an E2EE remote root skips the source and an encrypted subfolder is excluded; server-mounted external storages (`oc:permissions` `M`) ask on a TTY and skip otherwise (subfolders only warn). |
| Big-folder handling | `BIG_FOLDER_POLICY=warn\|ask\|skip` (`ask`), `BIG_FOLDER_EXISTING_POLICY=warn\|skip\|allow` (`warn`), `BIG_FOLDER_SIZE` | The wizard gates a newly picked remote folder above `BIG_FOLDER_SIZE` (asking on a terminal); already-configured sources that grew past it are warned about by default, skipped with `skip`, and left silent with `allow`. |
| Symlinks and checksums | `SYMLINK_POLICY=skip\|follow\|translate` (`skip`), `CHECKSUM=0\|1` (`0`) | Symlinks are skipped like the desktop client; `follow` dereferences and `translate` writes rclone `.rclonelink` files. `CHECKSUM=1` compares by checksum (`--checksum`; bisync `--compare size,modtime,checksum`) where the server supports it. |
| Move-to-trash and the delete guard | `MOVE_TO_TRASH=0\|1`, `LOCAL_TRASH_DIR`, `ASK_DELETE=1`, `DELETE_FILES_THRESHOLD=100`, `MAX_DELETE`, `sync --yes` | Pull/bisync deletions can go to the local trash (`--backup-dir`, default `<state>/trash`) instead of disappearing. An apply that would delete more than the threshold is stopped (`--max-delete`): a terminal asks once, a non-interactive run fails the source unless `sync --yes` is given, and an explicit `MAX_DELETE` wins. |
| Policy reporting | `doctor [--json]`, `server capabilities [--json]`, `account status [--json]`, `folders list [--json]`, `folders remove --purge` | `doctor` reports the effective policies, per-source E2EE/external-storage scans, local case clashes, the delete guard, and big folders; `--json` adds the structured policy objects. `--offline` prints the policies without scanning. |
<!-- src: parity.md#parity-implemented -->

### Server features

Sharing, notifications, activity, locks, trash, versions, and the other server-side features the desktop client exposes are all available as commands:

| Desktop client feature | `sciebo` equivalent | Notes |
| --- | --- | --- |
| Sharing (public links, users, groups) | `share link/user/group/guest/list/info/update/remove/search/copy-link` | Permissions as letters or numeric mask; `copy-link` reuses or creates a link. `remove` asks on a terminal and `--yes` skips the prompt. `list [SUB] [--reshares] [--json]` prints the same rows as JSON. |
| Pending shares (local and federated) | `share pending [--local\|--remote] [--json]`, `share accept ID [--remote]`, `share decline ID [--remote] [--yes]`, `share accept\|decline --all [--remote] [--yes]` | Lists the shares waiting for acceptance (`/shares/pending` and `/remote_shares/pending`, with the older shared-with-me fallback) and answers them. `decline` asks and requires `--yes` in a non-interactive run, and `--all` answers every pending share in the selected list(s) (`--remote` restricts to federated); a bare `--remote` forces a federated lookup. |
| Email, circle, Talk, guest, and federated shares | `share email/guest/circle/talk/remote`, `share incoming`, `share leave`, `share send-email ID`, `share remote-list [--json]` | Same permission parsing; `incoming` lists shares shared with you, `send-email` asks the server to email an existing share, `remote-list` lists the accepted federated shares, and `leave` leaves one. |
| Internal link | `share copy-internal SUB` | Copies the server-side `/index.php/f/<fileid>` link. |
| Server notifications | `notifications [--limit/--app/--type/--unseen/--action/--delete/--delete-all/--notify/--json/--watch [N]]` | `--app`/`--type` are allowlists with `NOTIFY_APPS`/`NOTIFY_TYPES` defaults; `--action ID LABEL` runs the notification's own action (POST/DELETE/PUT from the payload), `--notify` reports only unseen ids and records them, `--watch` polls in the foreground, and `--json` prints the filtered list. |
| Activity stream | `activity [--limit/--since/--notify]` | Newest first, HTML stripped, local `--since` filtering. `--since` pages through the API's `since=` cursor (at most 10 pages of 50) instead of stopping at one page, and warns when the cap is hit. |
| User status (online/away/DND/offline, message, emoji) | `presence show/set/clear` | `clear` removes the custom message. |
| File locking | `lock`, `unlock`, `unlock --all`, `locks [--prune\|--unlock-all] [--yes]` | Nextcloud files_lock via WebDAV `X-User-Lock`; tokens recorded mode 600. `unlock --all`/`locks --unlock-all` release every recorded lock (confirmed, `--yes` non-interactively) and drop the records whose `UNLOCK` succeeded, keeping failures for a retry. |
| Trashbin | `trash list/restore/rm/empty` | Restore returns items to their original location. `rm` and `empty` permanently delete and ask on a terminal (`--yes` skips the prompt); a non-interactive `rm` proceeds as before. |
| File versions | `versions SUB [--download/--restore/--delete]` | Download to file or stdout. |
| Quota display and warning | `quota [--json]`, `QUOTA_WARN_PERCENT`, `doctor` quota check | `quota` prints `rclone about`. With `QUOTA_WARN_PERCENT` above `0`, `sync` warns before the entries and `doctor` reports WARN at or above the threshold (one shared `rclone about --json` probe, floor percentage, probe errors only warn). |
| File details, search, and recent files | `file info/activity/shares`, `search TERM`, `recent` | WebDAV metadata, per-file activity, unified search, and recently modified files. |
| Comments, favorites, and tags | `comments SUB [list/add/delete]`, `favorites [list/add/remove]`, `tags list/create/assign/clear` | Beyond the desktop client, which leaves these to the web UI. |
| Desktop notifications for failures | `NOTIFY`, `NOTIFY_SUCCESS`, `watch --notify`, `notifications --notify` | `osascript` on macOS, `notify-send` on Linux; a silent no-op without a backend. `watch --no-notify` disables them for one run even when `NOTIFY=1`. |
| Server announcements | `announcements [--limit N] [--json]` | The announcementcenter app's OCS endpoint, newest first; absent/disabled apps report `announcements app not available` and exit 0. |
| Thumbnails and previews | `preview SUB [--output FILE] [--size N]` | The core preview endpoint by file id; binary-safe output to a file or stdout. |
| Direct download with resume | `download SUB [DEST] [--dry-run] [--force] [--resume] [--json]` | A single file over WebDAV with an optional range-resume (`-C -`); a directory falls back to rclone copy with hydrate's filter layering. A symlinked destination is refused, and a failed GET leaves an existing destination untouched. |
| Extended sharing | `share deck`, `share guest`, `share send-email`, `share search` (users/groups/email/federated/circles/guests/Talk), user/group/... `--send-mail`, link `--download 0\|1`/`--file-drop`/`--file-request`, update `--label` | Deck (type 12) and guest (type 8) creation, typed sharee search with a users/groups fallback, the server's sendMail request, and upload-only file-drop / file-request links. Hide-download uses the Nextcloud 30+ `attributes` array (`[{"scope":"permissions","key":"download","value":false}]`) and the legacy `{"download":0}` object on older or unknown servers. |
| Open a file in the web UI | `open --web SUB` | Resolves the file id and opens `/index.php/f/<fileid>`, falling back to the Files-app folder URL. |
<!-- src: parity.md#parity-implemented -->

### Monitoring and connection tooling

Everything used to inspect, troubleshoot, or script around this tool, beyond a single sync run:

| Desktop client feature | `sciebo` equivalent | Notes |
| --- | --- | --- |
| Configuration introspection | `config list/get/check/edit` | Every effective setting with its source layer; credential-like values are REDACTED. |
| Debug archive | `support [--output FILE] [--json]` | Redacted settings and rclone config, the offline `doctor` report, state, logs, capabilities, and scheduler/mount status in one archive. Proxy credentials and URL userinfo in redacted files are masked. |
| "Open local folder" | `open [SUB] [--print] [--web]` | `open`/`xdg-open` on the local folder, or the Files app URL with `--web`. |
| Per-source logs | `logs [list]`, `logs show NAME`, `logs tail NAME`, `logs path [NAME]`, `--lines N`, `--json` | Resolves the log recorded by the last run, falling back to the newest normal log and then a dry-run log. Read-only: no lock, no state writes, no network. |
| Proxy selection | `PROXY`, `PROXY_DIRECT`, `PROXY_TYPE=system\|none\|http\|socks5` | An explicit `http://`/`https://` `PROXY` is exported to the rclone and curl children through the environment (credentials stay out of the argv); a `socks5://` or other scheme keeps the explicit flags (rclone `--http-proxy`, curl `-x`). `PROXY_DIRECT=1` ignores `HTTP(S)_PROXY` for rclone and curl in `system` mode; `none` ignores all proxy settings; `http`/`socks5` require `PROXY` and fail loudly when it is missing. `network` and `doctor` report the effective mode. |
| Machine-readable output | `list --json`, `status --json`, `logs list --json`, `ignored --json`, `folders list --json`, `account info/status --json`, `server info/capabilities --json`, `notifications --json`, `share list/pending/incoming/remote-list --json`, `file shares --json`, `doctor --json`, `mounts --json`, `network --json`, `limit --json`, `support --json` | The same facts as the text reports, for scripts; invalid manifest lines still go to stderr. |
| `OWNCLOUD_*` environment parity | `OWNCLOUD_CHUNK_SIZE`, `OWNCLOUD_MIN_CHUNK_SIZE`, `OWNCLOUD_MAX_CHUNK_SIZE`, `OWNCLOUD_TIMEOUT`, `OWNCLOUD_MAX_PARALLEL`, `OWNCLOUD_CRITICAL_FREE_SPACE_BYTES`, `OWNCLOUD_FREE_SPACE_BYTES`, `OWNCLOUD_BLACKLIST_TIME_MIN/MAX`, `OWNCLOUD_UPLOAD_CONFLICT_FILES`, `OWNCLOUD_HTTP2_ENABLED`, `OWNCLOUD_TARGET_CHUNK_UPLOAD_DURATION` | A documented subset, mapped only when this tool's own setting was not set directly; local settings files still win. |
| Connection troubleshooting | `doctor`, `server info/capabilities/status`, `network`, `filters list`, `quota`, per-source logs | `doctor --offline` checks without network; `network` shows interface, metered state, and proxy mode. HTTP and OCS failures carry an actionable hint: 401 suggests `setup --rotate`, 423 points at `locks`/`unlock`, 429/503 include `Retry-After`, and 507 reports a full server storage/quota. |
| Sync status overview | `status [--json] [--watch [N]] [--history]`, `doctor --json`, `mounts [--json]`, `network [--json]`, per-source logs, `logs` | CLI report and run history instead of tray icons; `status --watch` refreshes in the foreground. |
| App update | `update [--check] [--json]` | `git fetch`/`rev-parse` for `--check`, `git pull --ff-only` otherwise; never touches the configuration. |
| Mutual TLS, custom CA, and User-Agent | `CLIENT_CERT`, `CLIENT_KEY`, `CLIENT_KEY_PASSWORD`, `CA_CERT`, `USER_AGENT` | Client-certificate auth (`rclone --client-cert/--client-key/--client-pass`; curl `--cert`/`--key` with the passphrase in a mode-600 `--config` file), a custom trust store (`--ca-cert`/`--cacert`), and a User-Agent override (`--user-agent`/`-A`). `CLIENT_KEY_PASSWORD` is obscured before rclone receives it and never reaches the curl argv; each set PEM path must exist and be readable. |
| Robust HTTP/DAV handling | `HTTP_TIMEOUT`, `HTTP_RETRIES`, `HTTP_RETRY_DELAY`, `HTTP_FOLLOW_REDIRECTS`, `HTTP_MAX_REDIRS`, `RETRIES_SLEEP` | Direct DAV/OCS curls are bounded by `HTTP_TIMEOUT`/`HTTP_RETRIES`/`HTTP_RETRY_DELAY`; GET/HEAD follow redirects (writes do not, so a POST body is never silently dropped); `--retry-all-errors`/`--retry-delay` and actionable hints for 400/409/412/413/415/502/504 in addition to the existing 401/403/423/429/503/507. |
<!-- src: parity.md#parity-implemented -->

### Conflict-copy caveat

rclone bisync creates conflict copies as ordinary new files next to the
original (`<file>.<suffix><N>`, `CONFLICT_PATTERN` by default). The behavior
is honest but not identical to the desktop client:

- In the run that creates a conflict copy, the fresh file can still reach the
  other side; rclone's transfer list for that run may already contain it.
- Later runs do not upload existing conflict copies: `CONFLICT_UPLOAD=0` (the
  default) adds `--exclude "*<CONFLICT_PATTERN>*"` to every entry, so `sync`
  and `pull` never upload existing copies either.
- Set `CONFLICT_UPLOAD=1` to sync conflict copies to the remote again, which
  matches the old behavior. The desktop client always keeps its copies local.
- `sciebo sync` prints a `conflicts:` line for each bisync run that created
  copies, even under `--quiet`, and counts them in the summary; `sciebo
  conflicts` finds existing copies offline.
- `sciebo conflicts --resolve MODE` reviews and resolves existing copies
  locally; without `--apply` it is a dry run, and a non-interactive apply
  needs `--yes`. `keep-local` moves the copy over the original, `keep-remote`
  deletes the copy, `keep-newest`/`keep-oldest` compare mtimes, and `keep-both`
  renames the copy to `<name> (local copy)<ext>`. That renamed file no longer
  contains `CONFLICT_PATTERN`, so a later `sync` uploads it. Resolution touches
  only local files; the remote is contacted on the next run, not during the
  resolve.
<!-- src: parity.md#conflict-copy-caveat -->

See this tool's `bisync` and `conflicts` commands in [docs/commands.md](commands.md) and the [Conflict handling](settings.md) section of the settings reference for the exact flags, settings, and defaults behind this behavior.

### Policy caveats

The policy defaults are safe rather than permissive, and they change what a
run touches:

- `CASE_CLASH_POLICY=exclude` scans local trees in the preflight and drops the
  later path; `rename` moves it to `<name> (case conflict)<ext>` instead.
  Remote-side collisions are listed on demand by `conflicts --kind case
  --remote`, or during a sync with `CASE_CLASH_REMOTE_SCAN=1`; a remote rename
  is not attempted, so `rename` excludes the losing path there instead of
  quarantining it.
- `INVALID_NAME_POLICY=exclude` keeps non-portable names out of the transfer;
  `doctor` reports them, and `warn`/`allow` restore the old behavior.
- `E2EE_POLICY=exclude` keeps end-to-end encrypted folders out of the
  transfer; `allow` downloads the encrypted blobs, which other clients can
  read but this tool cannot.
- `ASK_DELETE=1` with `DELETE_FILES_THRESHOLD=100` stops an apply that would
  delete more files. A `sync` on a terminal asks once; a non-interactive run
  needs `sync --yes`. `MOVE_TO_TRASH=1` avoids the deletion question for
  pull/bisync by moving local files into `LOCAL_TRASH_DIR` (or `BACKUP_DIR`).
<!-- src: parity.md#policy-caveats -->

See the settings reference's [Desktop-parity policies](settings.md) section for every policy default in one place.

## Implementable but not yet done

Every desktop feature that maps onto a foreground CLI is implemented (see
above). The remaining differences are deliberate or need outside support:

- **Per-chunk adaptive upload sizing.** The desktop client grows or shrinks
  the chunk toward `TARGET_CHUNK_UPLOAD_DURATION` while a transfer is in
  flight; this tool resolves one chunk for the whole run from the capabilities
  maximum, the duration, and the throughput target, because rclone uploads
  with a single fixed chunk size. Per-chunk adaptation would need rclone
  support.
- **App-password listing.** `logout --revoke` revokes the active app password
  and `setup --rotate` replaces the stored one, but the provisioning API's
  app-password inventory (all issued app passwords) is not exposed as a
  command.
- **Talk conversations.** Sharing to a Talk room is supported; the Talk chat
  API itself is not (the desktop client leaves it to the web UI).
<!-- src: parity.md#implementable-but-not-yet-done -->

## Not implementable

| Desktop client feature | Why not |
| --- | --- |
| Virtual Files / macOS File Provider / Windows Cloud Files, Finder-Explorer status overlays, context-menu actions, and the file manager's "Edit locally" shell action | These require a signed platform extension or filesystem driver. `sciebo mount` (rclone nfsmount) provides on-demand access where the OS NFS client allows it; `sciebo edit SUB` downloads, opens, and uploads one file from the CLI (not from the file manager); `sciebo hydrate SUB` pre-downloads a path with sync's filters. There is no OS-level badge, sync-state integration, or right-click menu. |
| System tray GUI with menus and status icons | This tool is deliberately a CLI with no GUI toolkit dependency; `status`, `doctor`, and the notification hooks cover monitoring. |
| End-to-end encryption (E2EE) | E2EE is a desktop-client cryptographic layer: the server never sees plaintext, and clients need the E2EE app's key handling. rclone/WebDAV only sees the encrypted blobs, so this tool cannot decrypt, version, or meaningfully diff them; with the default `E2EE_POLICY=exclude` it does not transfer them at all. Notifications and activity for encrypted folders are also opaque. `setup --crypt` creates an rclone crypt remote as an honest alternative (client-side encryption with rclone-held keys), but it is a different design: the encrypted content is opaque to the web UI, sharing, and other clients too. |
| Silent auto-updater | `sciebo update [--check]` fetches and fast-forwards a git checkout, but there is no packaging channel, background updater, or signed release feed; a source tarball must be replaced by hand. |
| notify_push background push | notify_push is a server-side app plus a WebSocket/push daemon that keeps desktop clients live. This tool is request-driven: `watch --remote-interval` can poll with a dry run and notify, `notifications` (including `--watch`) and `activity` show the stream when invoked, but nothing receives server push. |
| Sync-status icons in the file manager | Same platform-extension limitation as the overlays above. |
<!-- src: parity.md#not-implementable -->

## Limitations

Beyond the specific gaps listed in [Not implementable](#not-implementable) above, this tool's daily model differs from the desktop client's on purpose, not by omission:

The desktop client is an always-on daemon: it watches the local trees, keeps a
push connection for server changes, and updates status icons. This tool keeps
nothing running in the background on its own. The opt-in, foreground `watch`
command replaces local change detection, `schedule install --at-login` covers
periodic runs, and `notifications`/`activity` read the server stream on
demand.
<!-- src: parity.md -->

## Glossary

Plain-language terms used above.

| Term | Meaning |
| --- | --- |
| sciebo | The Hochschulcloud.NRW cloud storage service for NRW universities; this project is an unofficial client for it. |
| `sciebo` (command) | The command this tool installs; named after the service. |
| Nextcloud | The open-source server software this tool talks to. |
| rclone | The third-party file-transfer engine this tool is built on. |
| remote / rclone remote | A named rclone configuration entry that holds the server URL and how to authenticate. |
| WebDAV | The network protocol rclone and this tool's direct HTTP calls use to talk to Nextcloud. |
| app password | A Nextcloud-issued password scoped to one application/device, used instead of the account's main password. |
| the browser sign-in flow (Login Flow v2) | Nextcloud's browser-based authentication handshake that `setup --login` drives. |
| keychain / the system's password manager | The OS-level secret store this tool prefers for the app password over the rclone config file. |
| manifest / sync list | The set of configured folder pairs that `sync`/`check`/etc. act on. |
| folder pair | One line in the sync list: a local folder, a remote folder, and a direction. |
| sync (one-way upload) | Direction that mirrors local to remote; local deletions are sent to the server. |
| pull (one-way download) | Direction that mirrors remote to local; local deletions from this run are permanent unless a backup/trash setting is on. |
| bisync (two-way sync) | Direction that reconciles both sides; needs one-time initialization and can create conflict copies. |
| dry run | A run that reports the plan without transferring, deleting, or writing state. |
| delete guard | The safety check that stops a run before it deletes more files than a configured threshold, asking for confirmation instead. |
| conflict copy | A file bisync creates when both sides changed the same file, kept alongside the original rather than silently overwriting. |
| E2EE (end-to-end encryption) | Nextcloud's client-side encryption feature; this tool only ever sees the encrypted bytes and excludes E2EE folders by default. |
| external storage | A Nextcloud folder backed by another storage system on the server side, which this tool treats more cautiously by default. |
| OCS | Nextcloud's Open Collaboration Services API, used for shares, notifications, activity, and other non-file operations. |
| capabilities probe / server feature check | A one-time-per-cache-window API call that discovers what the connected server supports. |
| account profile | An independent, named account setup used to manage more than one Nextcloud account. |
| filter file | A plain-text rule file that excludes or includes paths from a sync. |
| safety policy | A named setting that chooses how this tool reacts to a risky situation: allow it, warn, ask first, or skip/exclude it. |
| watch (live sync) | An optional, foreground command that syncs a folder as soon as it changes; not a background service. |
| scheduled runs | An optional, installable background job that runs sync periodically; opt-in, not automatic. |
| the Nextcloud desktop client's `nextcloudcmd` tool | The separate, third-party command-line tool that ships with Nextcloud's desktop client packages. |
| this tool's nextcloudcmd-compatible command | This project's own `sciebo nextcloudcmd` command, built to accept the external tool's option names for easy migration; not the same program. |
| Virtual Files / File Provider | The OS feature that shows cloud files as if downloaded, without using disk space. This tool approximates this with `mount`/`hydrate`/`edit`, but does not replicate it (see [Not implementable](#not-implementable)). |
| notify_push | The server's live push channel the desktop client listens to for instant updates; this tool has no equivalent and is request-driven instead. |
