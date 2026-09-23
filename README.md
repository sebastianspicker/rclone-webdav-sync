# rclone-sciebo-webdav

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform: macOS | Linux](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey.svg)](#requirements)
[![Bash 5.3+](https://img.shields.io/badge/bash-5.3%2B-blue.svg)](#requirements)
[![rclone >= 1.69](https://img.shields.io/badge/rclone-%E2%89%A5%201.69-4a90d9.svg)](https://rclone.org)

<!-- Once the repository has a public home, add the CI badge:
[![CI](https://github.com/<owner>/<repo>/actions/workflows/ci.yml/badge.svg)](https://github.com/<owner>/<repo>/actions/workflows/ci.yml)
-->

`rclone-sciebo-webdav` keeps folders and git repositories mirrored to
[sciebo](https://www.sciebo.de) (or any other Nextcloud server) with
[rclone](https://rclone.org/webdav/), without clutter, leftover temporary
files, or surprises.

You choose a direction for every source: upload (`sync`), download (`pull`), or
two-way (`bisync`). `sciebo check` shows you the plan, `sciebo sync` applies
it, and a lock makes sure two runs never overlap. `sciebo verify` proves the
two sides match, and `sciebo status` shows the last run of every source. On
top of that come the Nextcloud-client-style surface: a folder wizard with
editable selective sync, git-repo discovery, filters including the server's
exclude list, `.nosync`, on-demand mounts, `edit`/`hydrate` for single files
and paths, a "not synced" listing (`ignored`), per-source sync logs (`logs`),
browser login with keychain storage, shares (link, user, group, email, guest,
circle, Talk, federated) including pending-share accept/decline, file-drop and
file-request links, conflict review and
resolution including local and remote case clashes, notifications with
filters/actions/watch,
activity, user status, WebDAV file locks, trash, file versions, quota,
comments/favorites/tags, and named profiles for multiple accounts. `sciebo
provision` configures an account non-interactively, `sciebo account import`
migrates a Nextcloud desktop client `nextcloud.cfg`, `sciebo watch` and
`sciebo schedule install --at-login` add an opt-in always-on path, `sciebo
limit` caps bandwidth at runtime, and `sciebo config`, `sciebo network`,
`sciebo nextcloudcmd`, and `sciebo support` make the setup inspectable,
scriptable, and supportable.

Desktop-parity policies follow the desktop client's safe defaults: invalid
names, local case-only collisions, and server-side E2EE folders are excluded,
external storages and newly picked big folders ask on a terminal (existing
big folders warn), symlinks are skipped, and an apply that would delete more
than `DELETE_FILES_THRESHOLD` files stops unless `sync --yes` is given. Remote
case-only collisions are opt-in (`CASE_CLASH_REMOTE_SCAN=1` during a sync, or
`conflicts --kind case --remote` on demand). Every policy can be relaxed in
`config/settings.local.env`.

## Screenshot tour

Every image below is real CLI output, captured against a temporary local
rclone remote. Regenerate them with `make screenshots`.

Know before you sync:

![bin/sciebo doctor --offline](docs/assets/screenshots/doctor.svg)

Dry-run the whole setup, then apply it for real:

![bin/sciebo check](docs/assets/screenshots/check.svg)

![bin/sciebo sync](docs/assets/screenshots/sync.svg)

See when each source last ran and what it did:

![bin/sciebo status](docs/assets/screenshots/status.svg)

Prefer a Nextcloud-client-style picker? Browse the remote and add pairs:

![bin/sciebo folders choose](docs/assets/screenshots/folders.svg)

## Requirements

- macOS or Linux. The code targets Bash 5.3 or newer. macOS ships Bash 3.2 as
  `/bin/bash`, so install a newer bash (`brew install bash`) and make sure it
  is first on `PATH`; `sciebo` refuses to start on an older shell with a clear
  message.
- [rclone](https://rclone.org/downloads/) 1.69 or newer (tested with 1.75.1).
  `RCLONE_MIN_VERSION` sets the floor; `doctor` and `sync` refuse older
  binaries because bisync needs `--resilient`, `--recover`, and
  `--resync-mode`.
- curl, used for the Login Flow, the capabilities probe, and the direct
  Nextcloud HTTP/DAV/OCS calls (macOS ships it in `/usr/bin`).
- A sciebo account.
- Optional helpers: `fzf` only makes the folder picker nicer; `fswatch`
  (macOS/Linux) or `inotifywait` (Linux) only makes `sciebo watch`
  event-driven, and without either `watch` falls back to portable polling.

Platform caveats:

| Feature | macOS | Linux |
| --- | --- | --- |
| Key storage (`KEYCHAIN=1`) | Keychain via `security` | `secret-tool` (libsecret) when installed, else `pass`; with neither, use `KEYCHAIN=0` (obscured password in the rclone config) |
| Desktop notifications (`NOTIFY`) | `osascript` | `notify-send`; without it, notifications are silent no-ops |
| Scheduled agent (`sciebo schedule`) | launchd | `systemd --user`; a bare `crontab` is detected but not managed |
| Change detection (`sciebo watch`) | `fswatch` when installed, else portable polling | `fswatch` or `inotifywait` when installed, else portable polling |
| Metered detection (`sciebo network`) | Wi-Fi SSID plus `METERED_SSIDS` and hotspot-name heuristics; no OS metered flag | NetworkManager (`nmcli`) reports `connection.metered` when installed |
| Open local folders (`sciebo open`) | `open` | `xdg-open` |
| On-demand mount (`sciebo mount`) | `rclone nfsmount`, no macFUSE | `rclone nfsmount`; needs the kernel NFS client and usually root |

## Install

Run from the checkout, or install it on your `PATH`:

```sh
git clone <repo-url> rclone-sciebo-webdav
cd rclone-sciebo-webdav

bin/sciebo help          # run straight from the checkout

make install             # copies the tree to ~/.local/share/rclone-sciebo
                         # and writes a ~/.local/bin/sciebo wrapper
make install PREFIX=/usr/local
make dist                # source tarball: dist/rclone-sciebo-<version>.tar.gz
```

`make install` never copies `config/settings.local.env` or `state/` into the
installation prefix; per-machine overrides and state belong to the checkout
you run from.

## Quick start

**1. Connect your account.** The quickest path is the Nextcloud Login Flow:

```sh
bin/sciebo setup --login    # opens the browser; password goes to the keychain
```

`--login` prompts for the server base URL (`--url URL` skips the prompt), opens
the authorization page, and polls until you grant access. The app password it
receives is stored in the platform keychain by default (macOS Keychain via
`security`, libsecret via `secret-tool`, or `pass`; service
`KEYCHAIN_SERVICE`, account `<remote>#plain`), and the rclone config then holds
only an obscured empty value. Storing the plaintext means HTTP-backed commands
never run `rclone reveal`; a legacy obscured keychain item is migrated once on
first use, and `logout` removes both items. With `KEYCHAIN=0`, `--no-keychain`
for one run, or no backend installed, the obscured password lives in the
rclone config instead.

Or create an app password by hand in sciebo under *Settings → Security →
Devices & sessions* (required with two-factor authentication and recommended
for third-party clients; see the
[sciebo docs](https://docs.sciebo.de/docs/sicherheit/); never use your main
password) and provide it in `.env`:

```sh
cp .env.example .env    # fill in SCIEBO_URL, SCIEBO_USER, SCIEBO_APP_PASSWORD
bin/sciebo setup        # writes the remote into ~/.config/rclone/rclone.conf
```

`SCIEBO_USER` looks like `alice@uni-muenster.de`. Find your institution's
server in the
[sciebo server list](https://docs.sciebo.de/docs/getting-started/webinterface/serverliste/).
`setup` normalizes the URL to `https://<host>/remote.php/dav/files/<user>/` so
Nextcloud chunked uploads work, validates the remote, probes and prints the
server capabilities, and never writes credentials into this repository.
`sciebo setup --rotate` fetches a fresh app password for an already-configured
remote without changing its URL or user.

Coming from the Nextcloud desktop client? `bin/sciebo account import
--dry-run` previews how `nextcloud.cfg` maps (accounts to profiles, folders to
`bisync` pairs, the known General options to settings), and `bin/sciebo
account import` applies it. Passwords are never imported, so finish every
imported profile with `bin/sciebo setup --login` (add `--profile NAME` for a
named profile, or run `setup --rotate` when the remote already exists).

**2. Multiple accounts?** Profiles keep their own manifests, filters, state,
and keychain service:

```sh
bin/sciebo account add work --remote sciebo-work --base backup
bin/sciebo --profile work setup --login
bin/sciebo --profile work folders choose
```

**3. Add what to sync.** Either edit `config/sources.conf`:

```
sync|~/Projects/my-app|repos/my-app
bisync|~/Notes|notes
```

or let the wizard pick remote folders for you:

```sh
bin/sciebo folders choose
```

You can also import a `nextcloudcmd --unsyncedfolders` list with
`bin/sciebo folders import`.

**4. Look before you leap.**

```sh
bin/sciebo doctor       # preflight checks (add --offline to skip the network)
bin/sciebo list         # parsed sources at a glance
bin/sciebo check        # dry run of everything, with a plan: line per source
bin/sciebo sync         # apply
bin/sciebo status       # last run per source (+ --history)
```

Initialize each `bisync` source once with `bin/sciebo sync --resync --apply`
(`make bisync-resync`), and review the resync warning under
[Direction semantics](docs/commands.md#direction-semantics) first.

**5. Inspect and tune.**

```sh
bin/sciebo config check      # settings, manifest, filters, state dirs
bin/sciebo config list       # effective settings and their source layer
bin/sciebo network           # interface, metered state, proxy mode
bin/sciebo limit --up 2M --until 2h   # cap later runs; `unlimited` lifts it
```

`config get KEY` prints one effective value, and `config edit` opens
`config/settings.local.env`. For a time-of-day cap instead of a one-shot
marker, set `BW_SCHEDULE` (rclone's timetable syntax).

**6. Keep it running (opt-in).**

```sh
bin/sciebo watch              # foreground: sync sources when they change
bin/sciebo schedule install --at-login --profiles work,home
```

`watch` is a foreground command, not a daemon: it uses `fswatch` or
`inotifywait` when installed and falls back to portable polling, with
`--remote-interval` optionally polling the server (dry run, notify only).
`schedule install --at-login` installs a launchd or systemd `--user` agent
that runs `sync --apply --quiet` periodically, one agent per profile with
`--profiles`. Nothing runs in the background unless you start or install it.

## Commands

Run `bin/sciebo` from the project root, or put it on your `PATH`. Common
commands have a `make` target (`make help` lists them; they don't forward
extra arguments), but the CLI is the full interface.

| Command | Purpose |
| --- | --- |
| `sciebo setup [--login] [--url URL] [--no-keychain] [--rotate] [--proxy URL] [--crypt]` | create, update, or rotate the sciebo rclone remote (or a crypt wrapper) |
| `sciebo provision --userid USER --apppassword PASS --serverurl URL [--localdirpath PATH] [--remotedirpath PATH] [--isvfsenabled 0\|1] [--profile NAME]` | non-interactive account and folder pair setup (desktop provisioning flags) |
| `sciebo doctor [--offline] [--json]` | preflight checks (PASS/WARN/FAIL report, including the parity policies and the `QUOTA_WARN_PERCENT` quota check) |
| `sciebo config <list\|get\|check\|edit>` | effective settings and their source layer |
| `sciebo discover [--write]` | find git repositories under `roots.conf` |
| `sciebo list [--json]` | list configured sources (read-only) |
| `sciebo check [sync options]` | dry run of all sources (no changes) |
| `sciebo sync [options]` | apply sync/pull/bisync for all sources (`--metered-ok` overrides metered gating) |
| `sciebo verify [--only NAME] [--download] [--size-only] [--quiet]` | compare sources with destinations (read-only) |
| `sciebo status [--only NAME] [--history [N]] [--json] [--watch [N]] [--quiet]` | last run per source, pause state, run history |
| `sciebo watch [--interval N] [--debounce N] [--backend BACKEND] [--only NAME] [--remote-interval N] [--once] [--notify\|--no-notify]` | sync sources when they change (foreground, not a daemon) |
| `sciebo pause [--for DURATION]` / `sciebo resume` | skip sync/check runs until resumed |
| `sciebo folders [choose\|add\|import\|edit\|list\|pause\|resume\|remove]` | manage folder pairs (`choose` is the default and applies the folder policies; `edit` rewrites a pair's `--local`/`--remote` path, filter, or mode, refusing a stale-bisync `--remote` change unless `--force`; `list --json` shows the paused/hidden flags; `pause`/`resume` skip or re-enable a pair; `remove --purge` also drops the pair's bisync state and flags) |
| `sciebo filters <sync\|list\|show\|check>` | filter files and the server's exclude list |
| `sciebo mount [options]` / `sciebo umount <selector>` / `sciebo mounts [--check] [--prune] [--json]` | on-demand `rclone nfsmount` and its state |
| `sciebo hydrate SUB [--dest DIR] [--dry-run] [--quiet] [--json] [--progress]` | download a remote path on demand, with sync's filter layering |
| `sciebo edit SUB [--editor CMD] [--no-upload] [--lock]` | download one file, open it, and upload it again when it changed |
| `sciebo ignored [SUB] [--source NAME] [--json]` | list local files sync would not transfer ("Not synced") |
| `sciebo announcements [--limit N] [--json]` | list server announcements (announcementcenter app) |
| `sciebo preview SUB [--output FILE] [--size N]` | download a preview image for a remote file |
| `sciebo download SUB [DEST] [--dry-run] [--force] [--resume] [--json] [--progress]` | download a remote file (resumable) or directory; a symlinked destination is refused |
| `sciebo update [--check] [--json]` | update the local checkout from its git upstream |
| `sciebo logs [list]` / `sciebo logs show NAME` / `sciebo logs tail NAME` / `sciebo logs path [NAME]` | resolve, print, or follow per-source sync logs |
| `sciebo cleanup (--logs \| --uploads \| --state \| --junk \| --cache \| --support) [--apply]` | housekeeping, dry run by default |
| `sciebo limit [--up RATE] [--down RATE] [--until DUR] [--show] [--clear] [--json]` / `sciebo unlimited` | runtime bandwidth cap for later syncs |
| `sciebo network [--json]` | active interface, metered state, and proxy mode |
| `sciebo schedule (install [--at-login] [--profiles LIST] \| uninstall \| status)` | scheduler agent lifecycle (launchd or systemd --user) |
| `sciebo nextcloudcmd [OPTIONS] SOURCEDIR NEXTCLOUDURL` | one nextcloudcmd-compatible two-way run (`--progress`/`-P` shows rclone progress on a terminal) |
| `sciebo trash [list\|restore\|rm\|empty]` | Nextcloud trashbin |
| `sciebo versions SUB [options]` | list, download, restore, or delete file versions |
| `sciebo share <subcommand>` | create, list (with `--json`/`--reshares`), update, remove shares; `pending`/`accept`/`decline` (including `accept\|decline --all`); `send-email`; accepted federated shares with `remote-list`; copy links; email/guest/circle/Talk/federated; file-drop and file-request links |
| `sciebo notifications [options]` | list, filter, act on, watch, or delete Nextcloud notifications |
| `sciebo activity [options]` | show (or notify about) the activity stream |
| `sciebo presence [show\|set\|clear]` | show or set your Nextcloud user status |
| `sciebo lock SUB` / `sciebo unlock SUB` / `sciebo unlock --all` / `sciebo locks [--prune\|--unlock-all]` | WebDAV file locks; `unlock --all`/`locks --unlock-all` release every recorded lock (confirmed) |
| `sciebo quota [--json]` | server quota usage |
| `sciebo file <info\|activity\|shares>` | details, activity, and shares for one remote path (`--json` on all three) |
| `sciebo search TERM [--limit N] [--json] [--open]` | unified search on the server |
| `sciebo recent [--since DUR] [--limit N] [--json]` | recently modified remote files |
| `sciebo comments <SUB [list] \| SUB add MESSAGE \| SUB delete ID>` | file comments (Nextcloud comments app) |
| `sciebo favorites [list\|add\|remove] [--json]` | list or toggle server-side favorites |
| `sciebo tags <list\|create\|assign\|clear> [--json]` | list system tags and assign them |
| `sciebo server <info\|capabilities\|status>` | server URL, user, capabilities, reachability |
| `sciebo account <list\|add\|import\|remove\|use\|info\|avatar\|status>` / `sciebo logout [--revoke] [--yes]` | manage profiles, credentials, account info, and desktop-client migration (`import`); `logout --revoke` revokes the app password server-side first |
| `sciebo open [SUB] [--print] [--web]` | open a local sync folder or the web UI |
| `sciebo conflicts [--kind copy\|case\|all] [--remote] [--open] [--only NAME] [--quiet]` / `sciebo conflicts --resolve MODE [--apply] [--yes]` | find or resolve local conflict copies and case-clash quarantines, or list remote case clashes with `--remote` |
| `sciebo support [--output FILE] [--no-network] [--json]` | build a redacted debug archive |
| `sciebo retry [NAME [PATH]] [--list] [--all]` | clear failure-blacklist entries |
| `sciebo help [command]` | usage; `<command> --help` works too |

Global options may appear before or after the command, but they are consumed
before the command runs: `--profile NAME`, `--trust`,
`--non-interactive`, `--debug`, `--log-file FILE`, `--log-dir DIR`,
`--log-expire HOURS`, `--confdir DIR`, `--version`. Full option tables,
confirmation requirements, and exit codes are in
[docs/commands.md](docs/commands.md).

## Documentation

| Page | Contents |
| --- | --- |
| [docs/commands.md](docs/commands.md) | every command, subcommand, option, exit code, and example |
| [docs/settings.md](docs/settings.md) | every setting, precedence, profiles, state layout |
| [docs/architecture.md](docs/architecture.md) | module map, command conventions, lock/state/HTTP design |
| [docs/parity.md](docs/parity.md) | Nextcloud Desktop parity matrix and its limits |
| [SECURITY.md](SECURITY.md) | where the app password lives and what protects it |
| [CONTRIBUTING.md](CONTRIBUTING.md) | development setup, tests, style |

[docs/index.html](docs/index.html) is a standalone demo page with the full
screenshot gallery and quick-start snippets.

## sciebo etiquette

sciebo warns that WebDAV is unsupported and asks users to keep sync intervals
large and sync only what is needed. The defaults are deliberately gentle
(`TRANSFERS=2`, `CHECKERS=4`, `TPSLIMIT=8`); override them in
`config/settings.local.env`. Nextcloud admins can raise the chunk size to 1 GB
server-side for better throughput ([Nextcloud
docs](https://docs.nextcloud.com/server/latest/admin_manual/configuration_files/big_file_upload_configuration.html#adjust-chunk-size-on-nextcloud-side)).
`MAX_PARALLEL_SOURCES` is `1` for the same reason; raise it only if the server
can take the extra connections. Upload chunking follows the desktop client:
with `CHUNK_SIZE` unset, a chunk is derived once per run from
`TARGET_CHUNK_UPLOAD_DURATION` times the effective upload throughput
(`BW_LIMIT_UP`, else `TARGET_UPLOAD_THROUGHPUT`), capped at the server's
maximum and clamped to `MIN_CHUNK_SIZE`/`MAX_CHUNK_SIZE` (`CHUNK_SIZE` always
wins).

## Caveats

- Git is deliberately **not** special-cased. `.git/` is synced as files, so a
  sync while `git gc`, `fetch`, or a commit rewrites objects can leave an
  inconsistent repository in the cloud. For repos that have a git remote this
  is usually fine; uncomment `- .git/` in `config/filters/clutter.txt` for
  working trees only.
- Don't run `bisync` on repositories you are actively working on.
- A bisync conflict copy is a new file and can still reach the other side in
  the run that creates it; later runs leave existing copies alone
  (`CONFLICT_UPLOAD=0`), and `sync`/`pull` never upload them. The Nextcloud
  desktop client always keeps its conflict copies local. `sciebo conflicts
  --resolve MODE` resolves copies locally (dry run without `--apply`); a
  `keep-both` copy is renamed so it no longer matches `CONFLICT_PATTERN` and
  uploads on the next run.
- `sciebo watch` is a foreground command, not a background service: close it
  (Ctrl-C) to stop watching. It detects local changes with `fswatch` or
  `inotifywait` when installed and portable polling otherwise. There is no
  notify_push integration, so remote changes need `--remote-interval` (a dry
  run that only notifies) or a normal `sync`/`schedule` run.
- The policy defaults change what a run touches. Non-portable names
  (Windows-invalid characters, brackets, trailing dot or space, reserved
  device names) are excluded from the transfer
  (`INVALID_NAME_POLICY=exclude`, the desktop client's behavior) and reported
  by `doctor`; set `INVALID_NAME_POLICY=warn` to sync them with a warning.
  Server-side E2EE folders are excluded the same way (`E2EE_POLICY=exclude`),
  and external storages and big folders are gated
  (`EXTERNAL_STORAGE_POLICY=ask`, `BIG_FOLDER_POLICY=ask`,
  `BIG_FOLDER_EXISTING_POLICY=warn`).
- Local case-only collisions (`Report.txt` vs `report.txt`) are detected in
  the sync preflight; with the default `CASE_CLASH_POLICY=exclude` the later
  path is not transferred, `rename` quarantines it as
  `<name> (case conflict)<ext>`, and `conflicts --kind case` lists those
  quarantines. Remote-side collisions are opt-in: `conflicts --kind case
  --remote` lists them on demand, and `CASE_CLASH_REMOTE_SCAN=1` applies the
  same policy during a sync. Remote paths are never renamed, so `rename`
  excludes the losing path there instead.
- The delete guard is on by default: an apply that would delete more than
  `DELETE_FILES_THRESHOLD` (100) files is stopped. On a terminal `sync` asks
  once; a non-interactive run fails that source with a message, and
  `sync --yes` allows the deletions. Set `ASK_DELETE=0` to disable the guard,
  or `MOVE_TO_TRASH=1` to move locally deleted pull/bisync files into
  `LOCAL_TRASH_DIR` (or `BACKUP_DIR`) instead.
- `folders pause NAME` skips one pair without pausing every source: the pair
  is reported as skipped by `sync`/`check` until `folders resume NAME`, and
  `sync --force` overrides it for one run. The related hidden flag (set by
  `account import` from the desktop client's `ignoreHiddenFiles`) excludes
  dot-files for that pair alone, like `SKIP_HIDDEN=1` does globally.
- Mutual TLS, a custom trust store, and a User-Agent override are available
  through `CLIENT_CERT`, `CLIENT_KEY`, `CLIENT_KEY_PASSWORD`, `CA_CERT`, and
  `USER_AGENT`; each set PEM path must exist and be readable, and
  `CLIENT_KEY_PASSWORD` is obscured before rclone receives it.
- Direct WebDAV/OCS calls are bounded by `HTTP_TIMEOUT`, `HTTP_RETRIES`, and
  `HTTP_RETRY_DELAY`, and GET/HEAD requests follow up to `HTTP_MAX_REDIRS`
  redirects when `HTTP_FOLLOW_REDIRECTS=1` (writes never follow, so a
  redirected POST cannot drop its body).
- Nextcloud end-to-end encryption (E2EE) is not implemented: sciebo cannot
  read E2EE folders, and the default `E2EE_POLICY=exclude` leaves them out of
  the transfer entirely (`allow` downloads the undecryptable blobs).
  `sciebo setup --crypt` creates an rclone crypt remote as an alternative for
  protecting data on the server, but its passwords stay obscured in the
  rclone config (the keychain stores one secret per remote) and the encrypted
  content is opaque to the web UI, sharing, and other clients as well.
- Unicode normalization is not checked: names that differ only in NFC/NFD form
  are treated as different names, which can look like duplicates on other
  systems.
- Multi-account setups are supported through `--profile`; each profile has its
  own remote, manifests, filters, state, locks, and keychain service,
  `account import` can seed them from the desktop client, and `schedule
  install --profiles` can render one agent per profile. Deliberately not
  implemented: a native macOS File Provider / Windows virtual-files overlay
  and a background notify_push daemon; `sciebo mount` covers on-demand access
  where the platform NFS client allows it.
- sciebo does not officially support WebDAV and offers no support for related
  issues. Keep backups.

## Development

```sh
make lint         # shellcheck + shfmt, plus a syntax check of tools/screenshots.py
make test         # tests/unit.sh + tests/features.sh + tests/integration.sh
make screenshots  # regenerate docs/assets/screenshots/*.svg
```

The tests never touch sciebo or your real configuration: state, manifests, and
the remote are redirected into a temp directory, and the integration suite runs
against a temporary `local` rclone remote. See
[docs/architecture.md](docs/architecture.md#tests) for the suite layout and
[CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.

## Migrating from `scripts/*.sh`

If a launchd agent was installed for the old `scripts/sync.sh` entrypoint,
re-run `bin/sciebo schedule install` once; it rewrites the plist to run
`bash <project>/bin/sciebo sync --apply --quiet`. `sciebo doctor` and
`sciebo schedule status` warn while an installed plist still points at the old
entrypoint. A compatibility shim remains at `scripts/sync.sh` (`--apply` means
`sync`, `--list` means `list`), and `scripts/nextcloudcmd` forwards to
`bin/sciebo nextcloudcmd` for cron jobs and scripts that still call the old
nextcloudcmd wrapper; delete both once every machine has been updated.

## License

[MIT](LICENSE)
