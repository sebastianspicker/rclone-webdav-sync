# rclone-webdav-sync

[![CI](https://github.com/sebastianspicker/rclone-webdav-sync/actions/workflows/ci.yml/badge.svg)](https://github.com/sebastianspicker/rclone-webdav-sync/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform: macOS | Linux](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey.svg)](#requirements)
[![Bash 5.3+](https://img.shields.io/badge/bash-5.3%2B-blue.svg)](#requirements)
[![rclone >= 1.69](https://img.shields.io/badge/rclone-%E2%89%A5%201.69-4a90d9.svg)](https://rclone.org)

rclone-webdav-sync is an unofficial command-line client for sciebo (Hochschulcloud.NRW) and other Nextcloud servers, written in Bash. It keeps local folders and git repositories in sync with a Nextcloud server: it talks to the server over WebDAV, the file-access protocol Nextcloud exposes, and uses [rclone](https://rclone.org/webdav/) to do the actual file transfers.

It works with any Nextcloud server. Its default target is [sciebo](https://hochschulcloud.nrw/), the Nextcloud-based cloud storage service for universities in North Rhine-Westphalia, Germany. The command this tool installs is `sciebo`, named after that service; the name belongs to the sciebo service, not to this project.
<!-- src: README.md -->

## What it does

- Mirrors each folder you choose in one direction: one-way upload (`sync`), one-way download (`pull`), or two-way sync (`bisync`, which reconciles both sides and needs a one-time initialization). `check` shows the plan first as a dry run, a preview that changes nothing.
- Adds the Nextcloud desktop client's other features as plain commands: a folder-picker wizard, shares, notifications, activity, on-demand mounts, file locks, trash, file versions, quota, and multi-account profiles.
- Follows the desktop client's safe defaults: invalid names, case clashes, and end-to-end encrypted (E2EE) folders are excluded by default, and a run that would delete a lot of files stops and asks first (the delete guard).
- Runs as a plain command-line tool with no background service. `sciebo watch` (live sync as files change) and `sciebo schedule install` (periodic runs via the OS's own scheduler) add an always-on path, but only if you opt in.
<!-- src: README.md -->

## Not affiliated with Nextcloud or sciebo

This is an independent project. It is not affiliated with, endorsed by, or supported by Nextcloud GmbH or the operators of [sciebo – die Hochschulcloud.NRW](https://hochschulcloud.nrw/); Nextcloud and sciebo are trademarks/names of their respective owners.
<!-- src: README.md#not-affiliated-with-nextcloud-or-sciebo -->

## Screenshot tour

Every image below is real CLI output, captured against a temporary local rclone remote, not a real sciebo or Nextcloud account. Regenerate them with `make screenshots`.
<!-- src: README.md#screenshot-tour -->

**`sciebo help`** — one entrypoint, every command on one screen.

![sciebo help](docs/assets/screenshots/help.svg)

**`sciebo doctor --offline`** — preflight checks before anything touches the network: bash and rclone versions, config sanity, the parity policies.

![sciebo doctor --offline](docs/assets/screenshots/doctor.svg)

**`sciebo folders choose`** — a Nextcloud-client-style picker: browse the remote, multi-select folders, and set a filter for each pair.

![sciebo folders choose](docs/assets/screenshots/folders.svg)

**`sciebo list`** — the sources you ended up with: mode, name, local and remote paths, filter.

![sciebo list](docs/assets/screenshots/list.svg)

**`sciebo check`** — a dry run of the whole setup, with one `plan:` line per source and nothing changed yet.

![sciebo check](docs/assets/screenshots/check.svg)

**`sciebo sync`** — the same run, applied. Transfers go to a per-source rclone log file.

![sciebo sync](docs/assets/screenshots/sync.svg)

**`sciebo status`** — the last run of every source, and the pause state.

![sciebo status](docs/assets/screenshots/status.svg)

## Requirements

- macOS or Linux. The code targets Bash 5.3 or newer. macOS ships Bash 3.2 as `/bin/bash`, so install a newer bash (`brew install bash`) and make sure it is first on `PATH`; `sciebo` refuses to start on an older shell with a clear message.
- [rclone](https://rclone.org/downloads/) 1.69 or newer (tested with 1.75.1). `RCLONE_MIN_VERSION` sets the floor; `doctor` and `sync` refuse older binaries because bisync needs `--resilient`, `--recover`, and `--resync-mode`.
- curl, used for the browser sign-in flow (Login Flow), the server feature check (capabilities probe), and the direct Nextcloud HTTP/DAV/OCS calls.
- A sciebo account, or any other Nextcloud account.
- Optional helpers: `fzf` only makes the folder picker nicer; `fswatch` (macOS/Linux) or `inotifywait` (Linux) only makes `sciebo watch` event-driven, and without either `watch` falls back to portable polling.
<!-- src: README.md#requirements -->

Platform caveats: not every backend exists on both operating systems, so some features fall back to a plainer default.

| Feature | macOS | Linux |
| --- | --- | --- |
| Key storage (`KEYCHAIN=1`) | Keychain via `security` | `secret-tool` (libsecret) when installed, else `pass`; with neither, use `KEYCHAIN=0` (obscured password in the rclone config) |
| Desktop notifications (`NOTIFY`) | `osascript` | `notify-send`; without it, notifications are silent no-ops |
| Scheduled agent (`sciebo schedule`) | launchd | `systemd --user`; a bare `crontab` is detected but not managed |
| Change detection (`sciebo watch`) | `fswatch` when installed, else portable polling | `fswatch` or `inotifywait` when installed, else portable polling |
| Metered detection (`sciebo network`) | Wi-Fi SSID plus `METERED_SSIDS` and hotspot-name heuristics; no OS metered flag | NetworkManager (`nmcli`) reports `connection.metered` when installed |
| Open local folders (`sciebo open`) | `open` | `xdg-open` |
| On-demand mount (`sciebo mount`) | `rclone nfsmount`, no macFUSE | `rclone nfsmount`; needs the kernel NFS client and usually root |
<!-- src: README.md#requirements -->

## Install

Clone the repository and run it straight from the checkout, or install it onto your `PATH`:

```sh
git clone https://github.com/sebastianspicker/rclone-webdav-sync.git
cd rclone-webdav-sync

bin/sciebo help          # run straight from the checkout

make install             # copies the tree to ~/.local/share/rclone-sciebo
                          # and writes a ~/.local/bin/sciebo wrapper
make install PREFIX=/usr/local
make dist                # source tarball: dist/rclone-webdav-sync-<version>.tar.gz
```
<!-- src: README.md#install -->

`make install` leaves your per-machine settings and sync state alone: it never writes `config/settings.local.env` or `state/` into the installed copy, whether this is a first install or a reinstall over an existing one. `make uninstall` mirrors that and keeps `config/` and `state/` under the installed prefix (`$PREFIX/share/rclone-sciebo`) so you can remove just the code, or copy your settings forward before deleting the rest by hand.
<!-- src: README.md#install -->

### Shell completions

Completions for bash, zsh, and fish live in `completions/`, generated from `lib/cli/sciebo.spec` (`make gen`). Enable the one you use:

| Shell | How |
| --- | --- |
| bash | Copy `completions/sciebo.bash` into a `bash-completion` completions directory, for example `~/.local/share/bash-completion/completions/sciebo`, or `source` it from `.bashrc`. |
| zsh | Copy `completions/_sciebo` onto a directory on `$fpath`, then run `compinit` (or open a new shell). |
| fish | Copy `completions/sciebo.fish` to `~/.config/fish/completions/sciebo.fish`. |

## Quick start

**1. Connect your account.** The quickest path is the browser sign-in flow (Nextcloud calls it Login Flow v2):

```sh
bin/sciebo setup --login    # opens the browser; password goes to the keychain
```

`--login` prompts for the server base URL (`--url URL` skips the prompt), opens the authorization page, and polls until you grant access. The app password it receives (a password just for this tool, not your main login) is stored in the system's password manager by default (macOS Keychain via `security`, libsecret via `secret-tool`, or `pass`; service `KEYCHAIN_SERVICE`, account `<remote>#plain`), and the rclone config then holds only an obscured empty value. Storing the plaintext means HTTP-backed commands never run `rclone reveal`; a legacy obscured keychain item, kept under the bare `<remote>` account name, is migrated once on first use, and `logout` removes both items. With `KEYCHAIN=0`, `--no-keychain` for one run, or no backend installed, the obscured password lives in the rclone config instead.
<!-- src: README.md#quick-start -->

Or create an app password by hand in sciebo under *Settings → Security → Devices & sessions* (required with two-factor authentication and recommended for third-party clients; see the [sciebo docs](https://docs.sciebo.de/docs/sicherheit/); never use your main password) and provide it in `.env`:

```sh
cp .env.example .env    # fill in SCIEBO_URL, SCIEBO_USER, SCIEBO_APP_PASSWORD
bin/sciebo setup        # writes the remote into ~/.config/rclone/rclone.conf
```

`SCIEBO_USER` looks like `alice@your-university.de`, or a plain username on a Nextcloud server that doesn't use the `user@domain` scheme. Find your institution's server in the [sciebo server list](https://docs.sciebo.de/docs/getting-started/webinterface/serverliste/). `setup` normalizes the URL to `https://<host>/remote.php/dav/files/<user>/` so Nextcloud chunked uploads work, validates the remote, probes and prints the server capabilities, and never writes credentials into this repository. `sciebo setup --rotate` fetches a fresh app password for an already-configured remote without changing its URL or user.

Coming from the Nextcloud desktop client? `bin/sciebo account import --dry-run` previews how `nextcloud.cfg` maps (accounts to account profiles, folders to `bisync` pairs, the known General options to settings), and `bin/sciebo account import` applies it. Passwords are never imported, so finish every imported profile with `bin/sciebo setup --login` (add `--profile NAME` for a named profile, or run `setup --rotate` when the remote already exists).

**2. Multiple accounts?** Account profiles keep their own sync lists, filters, state, and keychain service:

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

You can also import a `nextcloudcmd --unsyncedfolders` list with `bin/sciebo folders import`.

**4. Look before you leap.**

```sh
bin/sciebo doctor       # preflight checks (add --offline to skip the network)
bin/sciebo list         # parsed sources at a glance
bin/sciebo check        # dry run of everything, with a plan: line per source
bin/sciebo sync         # apply
bin/sciebo status       # last run per source (+ --history)
```

Initialize each `bisync` source once with `bin/sciebo sync --resync --apply` (two-way sync's first-time reset: it can copy or delete files on both sides), and review the resync warning under [Direction semantics](docs/commands.md#direction-semantics) first.
<!-- src: README.md#quick-start -->

**5. Inspect and tune.**

```sh
bin/sciebo config check      # settings, manifest, filters, state dirs
bin/sciebo config list       # effective settings and their source layer
bin/sciebo network           # interface, metered state, proxy mode
bin/sciebo limit --up 2M --until 2h   # cap later runs; `unlimited` lifts it
```

`config get KEY` prints one effective value, and `config edit` opens `config/settings.local.env`. For a time-of-day cap instead of a one-shot marker, set `BW_SCHEDULE` (rclone's timetable syntax).

**6. Keep it running (opt-in).**

```sh
bin/sciebo watch              # foreground: sync sources when they change
bin/sciebo schedule install --at-login --profiles work,home
```

`watch` is a foreground command, not a daemon: it uses `fswatch` or `inotifywait` when installed and falls back to portable polling, with `--remote-interval` optionally polling the server (dry run, notify only). `schedule install --at-login` installs a launchd or systemd `--user` agent that runs `sync --apply --quiet` periodically, one agent per profile with `--profiles`. Nothing runs in the background unless you start or install it.
<!-- src: README.md#quick-start -->

## Compared with nextcloudcmd

"nextcloudcmd" names two different things in this document: the third-party [`nextcloudcmd`](https://docs.nextcloud.com/server/stable/user_manual/en/desktop/commandline.html) tool that ships with the Nextcloud desktop client packages, discussed below, and this tool's own `sciebo nextcloudcmd` command, which deliberately accepts that external tool's option names for easy migration (see the table's Migration row). Unqualified, "nextcloudcmd" below means the external tool.

It ships with the Nextcloud desktop client packages (Alpine, Debian, Fedora, Ubuntu, the Ubuntu PPA, and Windows). Per its manual, it "performs a single sync run and then exits": it does not repeat synchronizations on its own and does not monitor for file system changes. One invocation syncs one local folder against one remote location (`--path` picks a server subfolder). It is the right tool when you already run the desktop client packages and want one folder synced on demand or from a script.
<!-- src: README.md#compared-with-nextcloudcmd -->

| | `nextcloudcmd` | `sciebo` |
| --- | --- | --- |
| Trigger | one-shot; you re-run it yourself or from cron | `sync` for one-shot, opt-in `watch` for live sync, `schedule install` for periodic runs |
| Folders per run | one local folder, one remote location (`--path`) | every pair in the manifest, each with its own `sync`/`pull`/`bisync` |
| Dependencies | the desktop client packages | bash, rclone, curl |
| Credentials | `-p PASSWORD` on the command line (visible to other local users via `ps`), `-n` netrc, or `--non-interactive` with `$NC_USER`/`$NC_PASSWORD` | platform keychain by default, handed to curl through a private netrc temp file; `sciebo nextcloudcmd` also takes `--password-fd` and keeps `-p` only for drop-in compatibility |
| Selective sync | `--unsyncedfolders FILE` | `folders choose` picker, plus per-pair include/exclude filters |
| Server features | out of scope for the manual (shares, notifications, locks, trash, versions, ...) | `share`, `trash`, `versions`, `notifications`, `locks`, `quota`, `comments`, `tags`, and more |
| Safety | `--max-sync-retries`; the manual documents no dry run or delete guard | dry-run `check`, a delete guard (`DELETE_FILES_THRESHOLD`), local conflict copies, `pause`/`resume` |
| Migration | — | `sciebo nextcloudcmd` accepts `nextcloudcmd`'s own option names; `scripts/nextcloudcmd` is a drop-in shim for existing cron jobs |
<!-- src: README.md#compared-with-nextcloudcmd -->

If you already run the desktop client packages and only need one folder synced from a script or cron job, `nextcloudcmd` stays the simpler choice: it needs nothing beyond the client itself. If you want the desktop client's other behavior (several folders, shares, scheduled or live sync) on a machine without a desktop session, this tool trades that simplicity for three command-line dependencies instead of the client packages.

## The desktop client, in the shell

The table below maps the desktop client's day-to-day features onto commands; the full parity matrix, including its documented gaps, is in [docs/parity.md](docs/parity.md).

| Desktop client feature | `sciebo` command |
| --- | --- |
| Account setup (Login Flow / app password) | `setup --login`, `setup` |
| Choosing which folders sync | `folders choose` |
| Live sync on file changes | `watch` (opt-in, foreground) |
| Periodic or start-at-login sync | `schedule install --at-login` |
| Sync status and history | `status`, `logs`, `activity` |
| Pause syncing | `pause`, `resume` |
| Conflict handling | `conflicts` |
| Desktop notifications | `notifications`, the `NOTIFY` setting |
| Sharing | `share` |
| On-demand / virtual files | `mount`, `hydrate`, `download` |
| Multiple accounts | `account`, the global `--profile` flag |
| Bandwidth limits | `limit`, `unlimited` |
| Metered-network handling | `network`, `METERED_POLICY` |
<!-- src: README.md#the-desktop-client-in-the-shell -->

This tool is a CLI, not a GUI: there is no tray icon, and nothing adds a sync-state overlay to Finder or Explorer. Virtual files (the OS feature that shows cloud files as if downloaded, without using disk space) are approximated, not replicated: `mount` exposes the remote as an on-demand filesystem via `rclone nfsmount`, and `hydrate`/`edit` fetch one path or file explicitly; [docs/parity.md](docs/parity.md#not-implementable) lists what a platform file-provider extension would still be needed for.

## Commands

Run `bin/sciebo` from the project root, or put it on your `PATH` after `make install`. The commands below are grouped by what they're for, as a quick-scan preview; the full option tables, exit codes, and examples are in [docs/commands.md](docs/commands.md), which uses the same groups. Several commands also have a `make` target (`make help` lists them), but the CLI is the complete interface.

| Group | Commands |
| --- | --- |
| Account and setup | `setup`, `account`, `provision`, `logout`, `config` |
| Preflight and discovery | `doctor`, `discover`, `list`, `filters`, `ignored`, `network`, `folders`, `open` |
| Syncing | `check`, `sync`, `nextcloudcmd`, `watch`, `edit`, `verify`, `status`, `pause`, `resume`, `limit`, `unlimited` |
| Mounts | `mount`, `umount`, `mounts`, `hydrate` |
| Housekeeping and scheduling | `cleanup`, `logs`, `schedule`, `support` |
| Server data | `trash`, `versions`, `share`, `notifications`, `activity`, `presence`, `lock`, `unlock`, `locks`, `quota`, `conflicts`, `retry`, `file`, `search`, `recent`, `comments`, `favorites`, `tags`, `server`, `announcements`, `preview`, `download` |
| Other | `update`, `help` |
<!-- src: README.md#commands -->

Global options may appear before or after the command, but they are consumed before the command runs: `--profile NAME`, `--trust`, `--non-interactive`, `--debug`, `--log-file FILE`, `--log-dir DIR`, `--log-expire HOURS`, `--confdir DIR`, `--version`.

## Configuration

Settings live in `config/settings.env` (tracked defaults) and `config/settings.local.env` (your gitignored overrides); an account profile can add its own layer on top. `sciebo config list` prints every effective setting and which layer it came from, and `sciebo config edit` opens the local override file. Every setting, its default, and the precedence rules are in [docs/settings.md](docs/settings.md).
<!-- src: README.md#configuration -->

## Safety model

- `check` and `verify` never change anything; transfers and deletions happen only through `sync` and `cleanup --apply`, one run at a time behind a lock.
- Desktop-client parity policies are safe by default: invalid names, local case-only collisions, and server-side E2EE folders are excluded from a transfer; external storages and big folders ask before the first sync.
- A `sync` that would delete more files than `DELETE_FILES_THRESHOLD` stops and asks (or fails a non-interactive run) unless `sync --yes` is given.
- Git is not special-cased: `.git/` syncs as files, so avoid syncing a repo while git is rewriting objects, and don't run `bisync` on a repository you're actively working in.
- Bisync conflict copies stay local by default; `conflicts --resolve` reviews and resolves them.
<!-- src: README.md#safety-model -->

The full policy list, conflict handling, and what's deliberately out of scope (Nextcloud E2EE, a background sync daemon, a virtual-files overlay) are in [docs/parity.md](docs/parity.md).

## Being a good sciebo (service) citizen

This section is about the sciebo service specifically, not this tool's own behavior; other Nextcloud servers may set different limits. The sciebo service warns that WebDAV is unsupported and asks users to keep sync intervals large and sync only what is needed.
<!-- src: README.md#sciebo-etiquette -->

The defaults here are deliberately gentle (`TRANSFERS=2`, `CHECKERS=4`, `TPSLIMIT=8`); override them in `config/settings.local.env` for a self-hosted or more permissive server. Nextcloud admins can raise the chunk size to 1 GB server-side for better throughput ([Nextcloud docs](https://docs.nextcloud.com/server/latest/admin_manual/configuration_files/big_file_upload_configuration.html#adjust-chunk-size-on-nextcloud-side)). `MAX_PARALLEL_SOURCES` is `1` for the same reason; raise it only if the server can take the extra connections. Upload chunking follows the desktop client: with `CHUNK_SIZE` unset, a chunk is derived once per run from `TARGET_CHUNK_UPLOAD_DURATION` times the effective upload throughput (`BW_LIMIT_UP`, else `TARGET_UPLOAD_THROUGHPUT`), capped at the server's maximum and clamped to `MIN_CHUNK_SIZE`/`MAX_CHUNK_SIZE` (`CHUNK_SIZE` always wins).
<!-- src: README.md#sciebo-etiquette -->

## Documentation

| Page | Contents |
| --- | --- |
| [docs/commands.md](docs/commands.md) | every command, subcommand, option, exit code, and example |
| [docs/settings.md](docs/settings.md) | every setting, precedence, profiles, state layout |
| [docs/architecture.md](docs/architecture.md) | module map, command conventions, lock/state/HTTP design |
| [docs/parity.md](docs/parity.md) | Nextcloud Desktop parity matrix and its limits |
| [SECURITY.md](SECURITY.md) | where the app password lives and what protects it |
| [CONTRIBUTING.md](CONTRIBUTING.md) | development setup, tests, style |
| [CHANGELOG.md](CHANGELOG.md) | what changed in each release |
<!-- src: README.md#documentation -->

[docs/index.html](docs/index.html), also published at <https://sebastianspicker.github.io/rclone-webdav-sync/>, is a standalone demo page with the full screenshot gallery and quick-start snippets.

## Contributing, security, and development

Bug reports and pull requests are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md) for the full development setup, style, and pre-PR checklist. In short:

```sh
make lint         # shellcheck + shfmt, plus a syntax check of tools/screenshots.py
make test         # tests/unit.sh + tests/features.sh + tests/integration.sh
make screenshots  # regenerate docs/assets/screenshots/*.svg
```

The tests never touch sciebo or your real configuration: state, manifests, and the remote are redirected into a temp directory, and the integration suite runs against a temporary `local` rclone remote. See [docs/architecture.md](docs/architecture.md#tests-and-tooling) for the suite layout.
<!-- src: README.md#development -->

Report suspected vulnerabilities privately as described in [SECURITY.md](SECURITY.md), not in a public issue; it explains where the app password lives and what protects it.
<!-- src: README.md#contributing-and-security -->

## Migrating from `scripts/*.sh`

If a launchd agent was installed for the old `scripts/sync.sh` entrypoint, re-run `bin/sciebo schedule install` once; it rewrites the plist to run `bash <project>/bin/sciebo sync --apply --quiet`. `sciebo doctor` and `sciebo schedule status` warn while an installed plist still points at the old entrypoint. A compatibility shim remains at `scripts/sync.sh` (`--apply` means `sync`, `--list` means `list`), and `scripts/nextcloudcmd` forwards to `bin/sciebo nextcloudcmd` for cron jobs and scripts that still call the old nextcloudcmd wrapper; delete both once every machine has been updated.
<!-- src: README.md#migrating-from-scriptssh -->

## License

[MIT](LICENSE)

## Limitations

These apply regardless of how this tool is configured:

- **Not affiliated.** This project is independent of Nextcloud GmbH and the sciebo service operators; see [Not affiliated with Nextcloud or sciebo](#not-affiliated-with-nextcloud-or-sciebo) above.
- **Git is not special-cased.** `.git/` syncs as ordinary files, with no awareness of git's own object model. Avoid syncing a repository while git is rewriting objects, and don't run `bisync` on a repository you're actively working in.
<!-- src: README.md#safety-model -->
- **No tray icon or file-manager overlay.** This tool is a CLI; there is no system tray icon and nothing marks synced files in Finder or Explorer. On-demand access approximates the desktop client's virtual files through `mount`/`hydrate`/`edit`, but does not replicate it.
<!-- src: README.md#the-desktop-client-in-the-shell -->
- **Deliberately out of scope.** Full Nextcloud end-to-end encryption (E2EE), a background sync daemon that runs without being asked, and a true virtual-files overlay are not goals of this project. [docs/parity.md](docs/parity.md) lists each one with the reason it can't be built as a CLI feature.
<!-- src: README.md#safety-model -->
- **No background activity by default.** Nothing syncs, watches, or schedules unless you explicitly run `watch` or install `schedule`.
<!-- src: README.md -->

## Glossary

Plain-language terms used above; see the linked documentation pages for full detail.

| Term | Meaning |
| --- | --- |
| sciebo | The Hochschulcloud.NRW cloud storage service for NRW universities; this project is an unofficial client for it. |
| `sciebo` (command) | The command this tool installs; named after the service. |
| Nextcloud | The open-source server software the sciebo service (and other institutions) run; this tool talks to any Nextcloud server, not only sciebo. |
| rclone | The third-party file-transfer engine this tool is built on; this tool configures and runs it rather than talking to the server directly for transfers. |
| remote / rclone remote | A named rclone configuration entry (default name `sciebo`) that holds the server URL and how to authenticate. Not the same as "remote" meaning "on the server" in casual use. |
| WebDAV | The network protocol rclone and this tool's direct HTTP calls use to talk to Nextcloud. |
| app password | A Nextcloud-issued password scoped to one application/device, used instead of the account's main password. |
| the browser sign-in flow (Login Flow v2) | Nextcloud's browser-based authentication handshake that `setup --login` drives; produces an app password without the user typing one in. |
| keychain / the system's password manager | The OS-level secret store (macOS Keychain, Linux secret-tool/pass) this tool prefers for the app password over the rclone config file. |
| manifest / sync list | The set of configured folder pairs (from `sources.conf`, `folders.conf`) that `sync`/`check`/etc. act on. |
| folder pair / source | One line in the sync list: a local folder, a remote folder, and a direction. |
| sync (one-way upload) | Direction that mirrors local to remote; local deletions are sent to the server. |
| pull (one-way download) | Direction that mirrors remote to local; local deletions from this run are permanent unless a backup/trash setting is on. |
| bisync (two-way sync) | Direction that reconciles both sides; needs one-time initialization and can create conflict copies. |
| dry run | A run (`check`, or any command's `--dry-run`) that reports the plan without transferring, deleting, or writing state. |
| delete guard | The safety check that stops a run before it deletes more files than a configured threshold, asking for confirmation instead. |
| bisync resync (two-way sync's first-time reset) | The one-time `--resync` step that initializes bisync's bookkeeping; can copy or delete files on both sides and must be reviewed as a dry run first. |
| conflict copy | A file bisync creates when both sides changed the same file, kept alongside the original rather than silently overwriting. |
| E2EE (end-to-end encryption) | Nextcloud's client-side encryption feature; this tool (like rclone) only ever sees the encrypted bytes and excludes E2EE folders by default. |
| external storage | A Nextcloud folder backed by another storage system on the server side (not local disk), which this tool treats more cautiously by default. |
| capabilities probe / server feature check | A one-time-per-cache-window API call that discovers what the connected server supports (chunk size, trashbin, checksums, version). |
| account profile | An independent, named account setup (its own remote, sync list, filters, and state), used to manage more than one Nextcloud account. |
| filter file | A plain-text rule file (rclone syntax) that excludes or includes paths from a sync. |
| safety policy | A named setting that chooses how this tool reacts to a risky situation: allow it, warn, ask first, or skip/exclude it. |
| watch (live sync) | An optional, foreground command that syncs a folder as soon as it changes; not a background service. |
| scheduled runs | An optional, installable background job (via the OS's own scheduler) that runs sync periodically; opt-in, not automatic. |
| the Nextcloud desktop client's `nextcloudcmd` tool | The separate, third-party command-line tool that ships with Nextcloud's desktop client packages. |
| this tool's nextcloudcmd-compatible command | This project's own `sciebo nextcloudcmd` command, built to accept the external tool's option names for easy migration; not the same program. |
