# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.3.0] - 2026-10-20

### Added

- `backup`: restic snapshots of local folders, stored encrypted and
  deduplicated in a repository on the same remote (`BACKUP_REMOTE_PATH`,
  default `restic`, outside the sync tree). restic reaches the server through
  `rclone serve restic`, so the account, proxy, TLS, bandwidth, and rate-limit
  settings apply. Extra tier until a live sciebo run has passed.
  - Subcommands `init`, `run`, `list`, `add`, `remove`, `snapshots`, `ls`,
    `restore`, `forget`, `check`, `unlock`, `info`, and `key show`. `forget`
    is a dry run without `--apply`; `restore` refuses non-empty targets and
    sync folders without `--force`; `init` prints the generated password once.
  - Sources in `config/backups.conf` (`name|local[|filter]`). rclone filter
    files are translated to restic excludes; only exclude rules are accepted.
  - Settings: `RESTIC_BIN`, `RESTIC_MIN_VERSION` (0.17), `BACKUP_HOST`,
    `BACKUP_REMOTE_PATH`, pack size, connections, chunk size, compression,
    the per-run exclude flags, tags, the `BACKUP_KEEP_*` retention policy,
    prune and maintenance cadence, quota policy, cache and password-file
    paths. The repository password lives in the keychain under
    `<remote>#restic`, or in a mode-600 `backup.key` with `KEYCHAIN=0`.
  - Maintenance from `backup run` when due: `forget`/prune every 30 days and
    `check --read-data-subset` every 7 days, for this host's snapshots only
    and only after every source succeeded.
  - `schedule install --backup` (or `SCHEDULE_BACKUP=1`) adds a daily backup
    agent (`BACKUP_LAUNCHD_LABEL`, `SCHEDULE_BACKUP_HOUR`,
    `SCHEDULE_BACKUP_MINUTE`); `status` and `uninstall` know about it,
    profiles included.
  - `doctor` checks the backup setup (one PASS line when backups are unused)
    and adds a `backup` object to `--json`; `status` lists backup sources;
    `logs` lists `backup-NAME` and `backup-maintenance`; `support` collects
    backup logs, `backups.conf`, and `backup info`; `cleanup --cache` runs
    `restic cache --cleanup`; `folders` and `provision` refuse a remote folder
    that overlaps the repository.
  - Named locks (`state/locks/<name>.lock`, so a backup can run beside a
    sync) and run-record namespaces (`state/last/@backup/<name>`).
  - Makefile targets `backup`, `backup-check`, and `backup-forget`.

### Changed

- The macOS Keychain write runs `security` in interactive mode with the
  secret hex-encoded on stdin, so neither the app password nor the restic
  password appears in any process's arguments. The write is verified by
  reading the item back.
- `sync`, `check`, and `backup run` refuse to run while a pair's remote
  folder overlaps `BACKUP_REMOTE_PATH`.
- `logout` also offers to remove the restic repository password, after a
  confirmation that spells out the consequence (`--yes` confirms,
  `--keep-backup-key` keeps it).
- `cleanup --state` removes stale lock directories of every named lock, not
  only `sync.lock`.

## [0.2.0] - 2026-09-24

First public release. Everything below is relative to the 0.1.0 internal
snapshot.

### Added

- Multi-account profiles (`account`, `--profile`, `logout`), with
  `account import` to migrate an existing Nextcloud desktop client config
  (`nextcloud.cfg`) and `provision` for non-interactive setup.
- Nextcloud-desktop-style extras: `share` (links, users, groups, email,
  guest, circle, Talk, and federated shares, including pending
  accept/decline), `notifications`, `activity`, `presence`,
  `lock`/`unlock`/`locks`, `trash`, `versions`, `quota`, `comments`,
  `favorites`, `tags`, and `server`.
- Safety and housekeeping: desktop-parity policies (invalid names, case
  clashes, E2EE folders, external storages, big folders, a delete guard)
  reported by `doctor`; `cleanup` for old logs, stale chunk uploads, and
  other state; a failure blacklist with `retry`.
- Opt-in always-on options: `watch` (foreground, change-driven or polling)
  and `schedule install --at-login` for a launchd/systemd agent.
- New commands: `announcements`, `preview`, `download` (resumable),
  `update`, `hydrate`, `edit`, `ignored`, `logs`, `config`, `support`,
  `nextcloudcmd`, `limit`/`unlimited`, `network`, `filters`, `file`,
  `search`, `recent`, `open`, and `conflicts`.
- Bandwidth control (`limit`, `BW_SCHEDULE`) and gating on metered networks
  or low disk space.
- Selective-sync editing (`folders edit`) and syncing the server's exclude
  list (`filters sync`).
- Conflict review and resolution (`conflicts --resolve`).
- Per-pair pause/resume and a hidden-files flag for individual folder pairs
  (`folders pause`, `folders edit`).
- A real-server contract test suite that runs against a Nextcloud container
  (nightly and on demand in CI); the isolated test suite now also runs
  against the documented minimum rclone version.

### Changed

- **Bash 5.3+ is now required** (previously 5.0). macOS ships Bash 3.2 as
  `/bin/bash`; install a newer bash with `brew install bash` and put it
  first on `PATH`. `sciebo` refuses to start on an older interpreter with a
  clear message.
- Conflict copies stay local by default now, matching the Nextcloud desktop
  client (`CONFLICT_UPLOAD=0`); set it to `1` for the old behavior, or use
  `conflicts --resolve` to review and resolve copies.
- Desktop-parity safety policies are on by default: a sync now excludes
  non-portable names, local case-only collisions, and E2EE folders, and
  asks before touching external storage or a newly picked big folder. Each
  policy can be relaxed in `config/settings.local.env`.
- `sync --yes` also bypasses the delete guard now, in addition to the
  download-size guard it already bypassed.
- HTTP and OCS errors now come with an actionable hint (for example, a 401
  points at `setup --rotate`, a 423 points at `locks`).
- The shipped `config/folders.conf` no longer ships with sample folder
  pairs.
- Runtime hints (for example after a failed sync) now name the equivalent
  `sciebo` command instead of a `make` target.
- `sciebo setup` accepts a plain Nextcloud username, not only the
  `user@domain` form sciebo uses.
- `make install` no longer deletes an existing installation's
  `config/settings.local.env` or `state/` when reinstalling over it; `make
  uninstall` now keeps `config/` and `state/` under the installed prefix
  (`$PREFIX/share/rclone-sciebo`) instead of removing them.
- Faster startup and fewer subprocesses on large manifests and list-heavy
  commands.

### Fixed

- `sciebo` could intermittently report a correctly configured rclone remote
  as "not configured" when another remote followed it in the rclone config.
- On a heavily loaded machine, one failed `stat` probe could make every
  command in that process refuse a safe settings file as "unsafe". The
  platform check no longer caches a guess after a failed probe.
- `trash` listed a non-empty Nextcloud trashbin as empty, and `trash
  restore --all` did nothing.
- `lock`/`unlock` failed against Nextcloud's files_lock app ("no
  Lock-Token header").
- `activity --since` stopped after one page instead of following the
  server's paging cursor.
- Non-ASCII and multi-byte file names were mis-encoded in requests on
  macOS.
- `doctor` could abort before printing its summary when rclone was missing
  while online.
- `share remove`/`share leave` and `trash rm` now ask for confirmation on a
  terminal instead of running immediately.

### Security

- The app password is read from the platform keychain in plaintext (a
  dedicated slot) instead of the reversible obscured value, so commands no
  longer need to reveal it via `rclone reveal`; a legacy keychain item is
  migrated automatically on first use.
- Passwords and other secrets no longer appear in process listings: they
  travel through mode-600 temp files or the environment instead of
  command-line arguments, across `setup`, `share`, `provision`, and
  mutual-TLS client-key handling.
- `--debug` output and other server/rclone-controlled text shown on the
  terminal are scrubbed of credentials and terminal escape sequences before
  they can reach a log or your screen.
- Settings, profile, and `.env` files are checked for safe ownership and
  permissions before they are read.

## [0.1.0] - 2026-09-19

Initial versioned snapshot: manifest-driven sync/pull/bisync, folder wizard,
git discovery, Login Flow v2 with Keychain storage, capabilities probe,
filters and `.nosync`, verify/status/pause, launchd scheduling, on-demand
mounts, cleanup, and the read-only trashbin/version listings.

[Unreleased]: https://github.com/sebastianspicker/rclone-webdav-sync/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/sebastianspicker/rclone-webdav-sync/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/sebastianspicker/rclone-webdav-sync/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/sebastianspicker/rclone-webdav-sync/releases/tag/v0.1.0
