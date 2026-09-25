# Commands

This is the complete command reference for rclone-webdav-sync, an
unofficial command-line client for sciebo (Hochschulcloud.NRW) and other
Nextcloud servers: every command, every option, every exit code, every
place a command asks before doing something destructive, and a runnable
example for each. It is generated from and kept in sync with
[`lib/cli/sciebo.spec`](../lib/cli/sciebo.spec), which generates the
command list `lib/cli/registry.sh` exposes as `SCIEBO_COMMANDS`; `sciebo
help <command>` or `<command> --help` prints the same usage text this
page documents, so this page is meant to be read alongside the `sciebo`
command's own help, not instead of it.

Commands come in two tiers, shown separately by `sciebo help`. **Core**
commands are the sync workflow plus the file operations that the
real-server contract suite (`tests/contract/`) exercises against a live
Nextcloud. **Extra** commands (`notifications`, `activity`, `presence`,
`file`, `search`, `recent`, `comments`, `favorites`, `tags`, `server`,
`edit`, `announcements`, `preview`) wrap further Nextcloud server features;
the isolated test suite covers them, the contract suite does not yet.
<!-- src: commands.md -->

- [How to read this reference](#how-to-read-this-reference)
- [Account and setup](#account-and-setup)
  - [setup](#setup) · [account](#account) · [provision](#provision) · [logout](#logout) · [config](#config)
- [Preflight and discovery](#preflight-and-discovery)
  - [doctor](#doctor) · [discover](#discover) · [list](#list) · [filters](#filters) · [ignored](#ignored) · [network](#network) · [folders](#folders) · [open](#open)
- [Syncing](#syncing)
  - [check](#check) · [sync](#sync) · [nextcloudcmd](#nextcloudcmd) · [watch](#watch) · [edit](#edit) · [verify](#verify) · [status](#status) · [pause](#pause) · [resume](#resume) · [limit](#limit) · [unlimited](#unlimited)
- [Mounts](#mounts)
  - [mount](#mount) · [umount](#umount) · [mounts](#mounts-1) · [hydrate](#hydrate)
- [Housekeeping and scheduling](#housekeeping-and-scheduling)
  - [cleanup](#cleanup) · [logs](#logs) · [schedule](#schedule) · [support](#support)
- [Server data](#server-data)
  - [trash](#trash) · [versions](#versions) · [share](#share) · [notifications](#notifications) · [activity](#activity) · [presence](#presence) · [lock](#lock) · [unlock](#unlock) · [locks](#locks) · [quota](#quota) · [conflicts](#conflicts) · [retry](#retry) · [file](#file) · [search](#search) · [recent](#recent) · [comments](#comments) · [favorites](#favorites) · [tags](#tags) · [server](#server) · [announcements](#announcements) · [preview](#preview) · [download](#download)
- [Other](#other)
  - [update](#update)
- [Help](#help)
- [Direction semantics](#direction-semantics)
- [Limitations](#limitations)
- [Glossary](#glossary)

<!--
Editor's note (grouping): README.md's own "Commands" table groups `open`
under "Mounts" and groups `retry`/`conflicts` under a section it calls
"Server features"; this reference groups `open` under "Preflight and
discovery" and `retry`/`conflicts` under "Server data" instead, following
this document's own body structure, since this document is the
authoritative reference and README's table is a simplified preview. See
verify-commands.md for the full note. This table of contents also lists
`announcements`, `preview`, `download`, and `update`, which the previous
version of this table omitted even though each already had its own
section.
-->

## How to read this reference

```
sciebo <command> [options]
```

The command is named after the service it connects to; the name belongs
to the sciebo service, not to this project.

Run `bin/sciebo` from the project root, or put the installed wrapper on
your `PATH`. Global options may appear before or after the command, but
they are consumed before the command runs; command parsers never see them.

### Global options

| Option | Effect |
| --- | --- |
| `--profile NAME`, `--profile=NAME` | select a named account profile from `config/profiles/NAME` (state under `state/profiles/NAME`). Equivalent to exporting `SCIEBO_PROFILE=NAME`. `default` is reserved for the project-wide layout. |
| `--confdir DIR`, `--confdir=DIR` | redirect the configuration base (nextcloudcmd's `-confdir`): settings, sync lists, filters, and the default state live under DIR. A DIR without its own `settings.env` falls back to the project copy. |
| `--trust` | accept invalid TLS certificates for this run: rclone gets `--no-check-certificate`, curl gets `--insecure`. Same as `TLS_INSECURE=1`. |
| `--non-interactive` | never prompt. Honored by the shared confirmation helpers (comments, versions, lock, share, conflicts, notifications, trash), by the shared terminal-detection gate (the `sync` download-size guard and delete-guard retry), by `share` through its own stdin check, and by the direct checks in `account import` and `nextcloudcmd`. It is exported as `SCIEBO_NON_INTERACTIVE`, so a flag-set run counts as non-interactive even when stdin is a terminal. |
| `--debug` | verbose diagnostics: rclone runs with `-vv`, curl with `-v`. Debug traces can print the basic-auth header; see [SECURITY.md](../SECURITY.md). |
| `--log-file FILE`, `--log-file=FILE` | write the rclone log of `sync`/`check` entries to FILE instead of `state/logs/<name>-<stamp>.log`. `-` writes to stdout. Other commands ignore it. |
| `--log-dir DIR`, `--log-dir=DIR` | write run logs under DIR instead of `state/logs/`. |
| `--log-expire HOURS`, `--log-expire=HOURS` | age limit for `cleanup --logs`; when set it wins over `LOG_RETENTION_DAYS`. |
| `--version`, `-V` | print `sciebo <version>` and exit 0. |
| `-h`, `--help`, `help [command]` | usage text. |

Environment variables the CLI itself understands:

| Variable | Effect |
| --- | --- |
| `SCIEBO_PROFILE` | active profile (the `--profile` flag wins). |
| `SCIEBO_CONFDIR` | configuration base (the `--confdir` flag wins). |
| `SCIEBO_DEBUG` | set by `--debug`; also honored when exported directly. |
| `SCIEBO_LOG_FILE` | set by `--log-file`. |
| `SCIEBO_LOG_DIR` | set by `--log-dir`. |
| `SCIEBO_LOG_EXPIRE_HOURS` | set by `--log-expire`; read by `cleanup --logs`. |
| `SCIEBO_NON_INTERACTIVE` | set by `--non-interactive`. |
| `HTTPS_PROXY`, `HTTP_PROXY`, `NO_PROXY` | proxy environment honored by rclone and curl; `PROXY`, `PROXY_DIRECT`, and `PROXY_TYPE` add this tool's own control over it (see [settings](settings.md#proxy)). |

<!-- src: commands.md#invocation-and-global-options -->

### Exit codes

| Code | Meaning |
| --- | --- |
| `0` | success (including "nothing to do" outcomes) |
| `1` | operational failure: a hard error (setup/provision validation, remote errors, HTTP failures, missing files), or a report with failures (`doctor` FAIL, `config check` FAIL, `filters check` rejecting a file, `verify` differences, `server status`/`account status` unreachable, failed `sync`/`check`/`nextcloudcmd` runs, `conflicts --quiet` with copies, `conflicts --resolve --apply` with failed actions, `mounts --check` unhealthy, `schedule status` not loaded, `cleanup` errors, `retry` for an unknown path, `status --only` for an unknown name, an unknown `logs`/`share` name, `edit` download/upload failures, `ignored` when a listing fails, `share pending` when neither pending list could be read) |
| `2` | usage error: unknown command/option, missing required argument, an invalid option value, or a confirmation that is required but unavailable (`--yes` missing in a non-interactive run). Usage text goes to stderr. |
| `130` / `143` | interrupted with SIGINT / SIGTERM; the run lock is released and the active rclone child is stopped. `status --watch` exits the same way. |

<!-- src: commands.md#exit-codes -->

### Destructive operations and confirmations

Read this table before your first real run: it lists everything this tool
will ask about, and everything it will not.

| Operation | Confirmation |
| --- | --- |
| `sync` / `check` | `check` never changes anything; `sync` applies without an extra prompt, except that the safety brake on deletions (the delete guard) stops a run that would delete more than `DELETE_FILES_THRESHOLD` files (`--yes` disables the guard; on a terminal the guard asks once to continue). |
| `cleanup --apply` | no prompt; without `--apply` it is a dry run. |
| `conflicts --resolve MODE --apply` | one interactive prompt for the whole plan; a non-interactive run needs `--yes`. Without `--apply` it is a dry run that prints the planned actions and changes nothing. |
| `hydrate SUB` | writes the remote path into the local destination (creating directories) and takes the run lock; it never deletes. No prompt; `--dry-run` reports the plan and `--quiet`/`--json` change only the output. |
| `edit SUB` | takes the run lock, downloads the file, opens the editor, and uploads it again only when it changed. No prompt; `--no-upload` keeps the local copy. |
| `comments SUB delete ID` | interactive prompt; a non-interactive run needs `--yes`. |
| `share leave ID` | asks on a terminal unless `--yes` is given; a non-interactive run proceeds as before. |
| `share decline ID` | asks on a terminal unless `--yes` is given; a non-interactive run **requires** `--yes` (exit 2 otherwise), because declining can lose access to the share. |
| `trash rm ID...` | asks on a terminal unless `--yes` is given; a non-interactive run deletes the items as before. |
| `trash restore ID...` | no prompt (restoring is non-destructive). |
| `trash restore --all`, `trash empty` | interactive prompt; a non-interactive run fails with exit 2 unless `--yes` is given. |
| `versions --restore`, `versions --delete` | interactive prompt; non-interactive needs `--yes`. |
| `notifications --delete ID` | no prompt. |
| `notifications --delete-all` | interactive prompt; non-interactive needs `--yes`. |
| `share remove ID` | asks on a terminal unless `--yes` is given; a non-interactive run proceeds as before. |
| `account remove NAME` | interactive prompt; non-interactive (or `--non-interactive`) needs `--yes`. |
| `logout` | interactive prompt; non-interactive (or `--non-interactive`) needs `--yes`. |
| `mounts --prune` | no prompt; removes state records, not files. |
| `folders remove NAME` | no prompt; removes the wizard entry from `folders.conf` only. With `--purge` it also deletes the pair's local state records and filter. |

<!-- src: commands.md#destructive-operations-and-confirmations -->

## Account and setup

### setup

```
sciebo setup [--login] [--url URL] [--no-keychain] [--rotate]
             [--proxy URL] [--crypt]
```

Create or update the rclone remote named `RCLONE_REMOTE` as a Nextcloud
WebDAV backend, validate it with `rclone lsd`, print the quota, probe the
server capabilities, and point out the server's chunk size when it differs
from `CHUNK_SIZE`.

| Option | Effect |
| --- | --- |
| `--login` | authenticate with the browser sign-in flow (Nextcloud's Login Flow v2: browser + poll) and receive a fresh app password. |
| `--url URL` | base URL for `--login`; without it the URL is prompted (or taken from `SCIEBO_URL`). |
| `--rotate` | run the browser sign-in flow against the already-configured remote's base URL and replace only its app password, keeping url and user. Cannot be combined with `--login`, `--url`, or `--crypt`. |
| `--no-keychain` | for this run, store the obscured password in the rclone config instead of the system's password manager. |
| `--proxy URL` | use URL as the proxy for this setup run only: `PROXY_TYPE` is forced to `system` and `HTTP_PROXY`/`HTTPS_PROXY` are exported so the direct-curl sign-in flow honors it. An `http://`/`https://` URL reaches rclone and curl through the child environment; a `socks5://` (or other scheme) URL goes through rclone's `--http-proxy` / curl's `-x`. Settings files are never written; the command prints how to set `PROXY` for later runs. |
| `--crypt` | create the crypt remote named by `CRYPT_REMOTE` (default `<RCLONE_REMOTE>-crypt`) wrapping the configured WebDAV remote, with fresh randomly generated passwords. Validated with `rclone lsd`; prints what to set to sync through it. Cannot be combined with `--login`, `--rotate`, or `--url`. |
| `-h`, `--help` | usage. |

Connection values come from the environment, from `.env` in the project
root, or interactively (prompts are skipped when all three are set):

- `SCIEBO_URL` — Nextcloud base URL, e.g. `https://your-university.sciebo.de`
  (the remote's stored URL always gets `/remote.php/dav/files/<user>/`
  appended).
- `SCIEBO_USER` — sciebo ID in `<localid>@<scope>` form.
- `SCIEBO_APP_PASSWORD` — an app password (a password just for this tool,
  not your main login) from *Settings → Security → Devices & sessions*;
  never the main password.

The app password is never printed. With the default `KEYCHAIN=1`, a new
setup stores it in the system's password manager (macOS Keychain via
`security`, libsecret via `secret-tool`, or `pass`) under service
`KEYCHAIN_SERVICE` and account `<RCLONE_REMOTE>#plain`, and the rclone
config holds an obscured empty value; a bare `RCLONE_REMOTE` account (no
`#plain` suffix) is only the legacy slot from an older obscured-password
setup, migrated once on first use, not where a new setup writes. With
`KEYCHAIN=0`, no backend installed, or `--no-keychain`, the password is
obscured (reversibly encoded, not encrypted) and written to the rclone
config instead. `--rotate` finishes with
`rotated the app password for <user>@<host>`.
<!-- src: commands.md#setup; corrected against lib/adapters/keychain.sh's keychain_account_plain() (account "<RCLONE_REMOTE>#plain") and keychain_account() (legacy, migrated-from "RCLONE_REMOTE"); the previous wording here named the bare RCLONE_REMOTE account for a new setup, which disagreed with README.md, docs/settings.md, SECURITY.md, docs/parity.md, and this file's own logout section — see verify-commands.md item 1 -->

Examples:

```sh
sciebo setup --login
sciebo --profile work setup --login --url https://your-university.sciebo.de
sciebo setup --rotate --no-keychain
sciebo setup --proxy http://proxy.example:3128
sciebo setup --crypt
```

### account

```
sciebo account <list|add|import|remove|use|info|avatar|status> [options]
```

Manage named account profiles (multi-account support). Every profile has
its own `config/profiles/<name>/` sync lists and filters and its own
`state/profiles/<name>/` state, so two accounts never share locks,
workdirs, or run history. The system password manager's service name
becomes `rclone-sciebo/<name>` when the default service is left unchanged.
`default` is the project-wide layout and cannot be added or removed.

| Subcommand | Behavior |
| --- | --- |
| `list` (default) | table of `PROFILE`, `REMOTE`, `BASE`, `SOURCES`, `KEYCHAIN SERVICE`; named profiles also show `ready` or `no state yet`. |
| `add NAME [--remote R] [--base B]` | create `config/profiles/NAME` with an empty sync list, an empty `folders.conf`, an empty `roots.conf`, a copied `filters/clutter.txt`, a generated `settings.local.env`, and `state/profiles/NAME`. With `--remote`/`--base` those values are written; without them, run `setup --login` under the profile next. |
| `import [options]` | import accounts and folder pairs from the Nextcloud desktop client's `nextcloud.cfg` (see below). |
| `remove NAME [--yes]` | delete the profile's config directory and state directory. Prompts on a terminal; without a TTY (or with `--non-interactive`) `--yes` is required, otherwise exit 2. |
| `use NAME` | print how to activate the profile: `export SCIEBO_PROFILE=NAME` or `sciebo --profile NAME ...`. |
| `info [--json]` | show the server-side account: id, display name, email, server base, quota (best effort), and cached server version. |
| `avatar [--output FILE] [--size N]` | download the account avatar (the image never reaches stdout) and print the path; default `./avatar-<user>.png`, size `AVATAR_SIZE` or 128. |
| `status [--json]` | print remote configured, server reachability, capabilities cache age, and keychain backend; exits 1 when the server is not reachable. |

Options for `info`/`avatar`/`status`:

| Option | Effect |
| --- | --- |
| `--json` | `info`: print a JSON document instead of the label/value table. `status`: print `{remote,configured,reachable,capabilities_cache_age,last_check,keychain_backend}` (still exits 1 when unreachable). Rejected by `list`, `add`, `remove`, `use`, and `avatar`; `import` has its own `--json`. |
| `--output FILE` | `avatar`: write the image to FILE. |
| `--size N` | `avatar`: pixel size, a positive integer (default `AVATAR_SIZE`, else 128). |

`import` options:

| Option | Effect |
| --- | --- |
| `--nextcloud-cfg FILE` | read FILE instead of the default `nextcloud.cfg` (also honored: the `NEXTCLOUD_CFG` environment variable). The defaults are the macOS app container, the macOS legacy path, Linux (`~/.config/Nextcloud/nextcloud.cfg`), and `%APPDATA%/Nextcloud/nextcloud.cfg`. |
| `--profile NAME` | import only the account matching NAME: a 0-based account index, a user id, or the profile name the account would get. This is the global `--profile` flag reused as the selector; without it every configured account is imported. |
| `--dry-run` | print the full plan and write nothing. |
| `--yes` | merge into an existing profile or sync list without asking (non-interactive runs need this). |
| `--json` | print `{"dry_run":bool,"imports":[...]}` instead of the text plan. |

The INI file's `[Accounts]` entries are mapped one profile per configured
account: account 0 becomes the `default` profile, other accounts become a
profile named after their user id when that is a safe name, else
`account<N>` (with a numeric suffix on collisions). The `[General]` section
maps the values that have an equivalent in this tool — `chunkSize`,
`minChunkSize`, `maxChunkSize`, `timeout`, `moveToTrash`,
`promptDeleteAllFiles`, `deleteFilesThreshold`, `launchOnSystemStartup`,
`newBigFolderSizeLimit`, and `logDebug` — into the profile's
`settings.local.env`; the desktop client's folder pairs
(`localPath`/`targetPath`) are added as `bisync` pairs, and pairs that are
already configured are counted as skipped. The desktop client's per-folder
`paused` and `ignoreHiddenFiles` booleans are persisted as the pair's
`paused`/`hidden` flags under `PAIR_FLAGS_DIR` (default
`<STATE_DIR>/pairs`), so an imported paused pair is skipped by `sync` and
an imported hidden pair excludes dot-files. A paused pair can be resumed
with `sciebo folders resume NAME`.

Passwords are never imported. Every imported profile still needs an app
password: the plan's `next:` line points at `sciebo [--profile NAME] setup
--login` or `setup --rotate`. An existing profile directory or a profile
whose sync list already holds entries is "blocked": for a real (non-dry)
run a terminal asks once to merge, and a non-interactive or `--json` run
without `--yes` refuses to overwrite (usage error, exit 2). `--dry-run`
always prints the plan and writes nothing. A config file that cannot be
found, contains no accounts, or matches no `--profile` selector exits 1.

Examples:

```sh
sciebo account list
sciebo account add work --remote sciebo-work --base backup
sciebo --profile work setup --login
sciebo account info --json
sciebo account avatar --size 256
sciebo account status --json
sciebo account import --dry-run
sciebo account import --nextcloud-cfg ~/nextcloud.cfg --yes
sciebo account remove work --yes
```

### provision

```
sciebo provision --userid USER (--apppassword PASS | --apppassword-fd N)
                  --serverurl URL
                  [--localdirpath PATH] [--remotedirpath PATH]
                  [--isvfsenabled 0|1] [--profile NAME]
```

Create an account profile and configure its rclone remote without any
prompt, the way the Nextcloud desktop client's provisioning flags do. The
rclone remote is named after the profile; without `--profile` (or a global
`--profile`/`SCIEBO_PROFILE`) the profile is `provision-<sanitized
userid>`. Creating is create-or-update: an existing profile is left
untouched and an existing remote is updated, so unlike `account add` the
command can be re-run.

| Option | Effect |
| --- | --- |
| `--userid USER` | Nextcloud user id (required). |
| `--apppassword PASS` | app password (required unless `--apppassword-fd`; never printed). The value is visible in the process list, so `--apppassword-fd` is preferred. |
| `--apppassword-fd N` | read the app password from the already-open file descriptor N (e.g. `3<<<"$PW"`); keeps it out of the process list. |
| `--serverurl URL` | server base URL (required). A URL that already looks like a WebDAV path fails; plain `http://` warns. |
| `--localdirpath PATH` | local folder to pair (optional; without it only the account is created). |
| `--remotedirpath PATH` | remote folder below the remote base (default `/`, i.e. the base itself, written as `.`). |
| `--isvfsenabled 0|1` | desktop-client compatibility flag; `1` warns and is ignored because there are no virtual files: the pair stays a regular two-way sync (bisync). Any other value is a usage error. |
| `--profile NAME` | profile to create or update. |
| `-h`, `--help` | usage. |

The pair is validated before anything is written, so a bad path cannot
leave a half-provisioned account behind. A folder pair is only added when
`--localdirpath` is given; an existing source name or remote folder in the
profile fails rather than merging. The app password goes to the system's
password manager when `KEYCHAIN` is enabled, otherwise it is stored
obscured in the rclone config, exactly like `setup`. The remote is
validated with `rclone lsd`; a failed validation exits 1 with a message
pointing at `--serverurl`/`--userid`/`--apppassword`. On success the
command prints the profile, remote, server, password storage, and the pair
(or `pair: none`). No confirmation is ever required: a missing required
flag or an invalid `--isvfsenabled` is a usage error (exit 2), a validation
or write failure exits 1, and success exits 0.

```sh
sciebo provision --userid alice --apppassword-fd 3 \
  --serverurl https://your-university.sciebo.de \
  --localdirpath ~/sciebo --remotedirpath backup 3<<<"$PW"
sciebo --profile work provision --userid alice --apppassword "$PW" \
  --serverurl https://your-university.sciebo.de
```

### logout

```
sciebo logout [--revoke] [--yes]
```

Remove the rclone remote entry and both stored keychain items for the
active remote (`--profile` selects which one; the plaintext
`<remote>#plain` slot and a legacy obscured slot are both removed). Sync
lists, state, and synced files are left alone. Credentials still present in
`.env` are reported for manual removal. Without `--yes` the command prompts
on a terminal; a non-interactive run fails with exit 2. Prints
`nothing to do` when neither a remote entry nor a keychain item existed.

| Option | Effect |
| --- | --- |
| `--revoke` | revoke the app password on the server first (the Nextcloud API's `DELETE /ocs/v2.php/core/apppassword`); needs `--yes` or a terminal confirmation. The revoke runs before the local credentials are deleted, and a failed revoke only warns, so the local logout still completes. |
| `--yes` | do not ask for confirmation. |

### config

```
sciebo config <subcommand> [options]
```

Inspect the effective settings and where each value comes from. The
layered files (`config/settings.env`, the environment,
`config/settings.local.env`, and the active profile) are read without
contacting a remote. The `source` column is one of `profile`, `local`,
`environment`, or `default`.

| Subcommand | Behavior |
| --- | --- |
| `list [--json] [--all]` | print every setting as `KEY=VALUE<TAB>source`. Without `--all`, settings with an empty value are hidden. Values whose key looks like a credential (password, secret, token, apikey, proxy) print as `REDACTED`. |
| `get KEY [--json]` | print the effective value of one setting; an unknown key exits 1. |
| `check [--json]` | check settings and required files as `PASS`/`WARN`/`FAIL` lines plus a summary; exits 1 on any FAIL. Checks: settings load and validate, sync-list and folders files exist (WARN when missing), the clutter filter exists, the rclone config is readable, and the state directory is writable. |
| `edit` | create `config/settings.local.env` from the shipped example when missing and open it in `$EDITOR` (falling back to `vi`); a non-interactive run prints the path. |

| Option | Effect |
| --- | --- |
| `--json` | print the result as JSON (`list`, `get`, `check`). |
| `--all` | `list`: also show settings whose value is empty. |

```sh
sciebo config list
sciebo config get RCLONE_REMOTE
sciebo config check --json
sciebo config edit
```

## Preflight and discovery

### doctor

```
sciebo doctor [--offline] [--json]
```

Run preflight checks and print `PASS`/`WARN`/`FAIL` lines plus a summary.
Exits 1 when any check fails, 0 otherwise (warnings do not fail).

Checks: rclone availability and minimum version, rclone config and remote
type/url/vendor, the active scheduler/keychain/notification backends, the
app password storage and secret file permissions (`.env` and the rclone
config), free space on the state filesystem, the proxy mode, server
capabilities (fresh probe or cache), end-to-end encryption, the cached
server-exclude list, state directories, filter files parsed by rclone
itself, the sync list (invalid entries, duplicate names/remotes,
overlapping local directories), name hygiene (platform-invalid names,
case-only collisions in existing local trees), conflict copies in the
local trees, the watch pid record, the network and metered state, network
reachability (`rclone lsd`, `rclone about`), and the launchd agent
(macOS).

Policy checks cover the desktop-parity safety policies:

| Check | Behavior |
| --- | --- |
| `policies` | one compact `PASS` line naming the active `INVALID_NAME_POLICY`, `CASE_CLASH_POLICY`, `E2EE_POLICY`, `EXTERNAL_STORAGE_POLICY`, `SYMLINK_POLICY`, `CHECKSUM`, `MOVE_TO_TRASH`, and the delete-guard state. |
| `case clashes` | scans the existing local directories of the sync list for case-only collisions (`CASE_CLASH_POLICY=exclude`/`rename`/`warn`); `WARN` with up to five samples when any were found, `PASS` otherwise. |
| `e2ee folders` | online, queries the first `DOCTOR_REMOTE_SCAN_LIMIT` sources for end-to-end encrypted folders and reports them with `E2EE_POLICY`; a non-Nextcloud remote only warns, and offline runs print the policy only. Never fails. |
| `external storage` | same shape for server-mounted external storages (`oc:permissions`), reporting `EXTERNAL_STORAGE_POLICY`; never fails. |
| `delete guard` | reports `ASK_DELETE`, `DELETE_FILES_THRESHOLD`, and an explicit `MAX_DELETE` cap (`ASK_DELETE=0` means the threshold is not enforced). |
| `big folders` | online, compares the first `DOCTOR_REMOTE_SCAN_LIMIT` sources against `BIG_FOLDER_SIZE` with `rclone size` and lists the sources over the limit with `BIG_FOLDER_EXISTING_POLICY`; silent when `BIG_FOLDER_SIZE` is empty. |
| `quota` | reads the server quota once with the shared sync probe and reports the floor percentage used (`quota: N% of <remote>: used`): `WARN` at or above `QUOTA_WARN_PERCENT`, `PASS` below, and a `WARN` when the probe fails. Silent when `QUOTA_WARN_PERCENT=0`; an offline run reports the threshold only. |

`DOCTOR_REMOTE_SCAN_LIMIT` (used by the `e2ee folders` and `big folders`
checks above) has no documented default in
[docs/settings.md](settings.md); check `config/settings.env` for its
current value rather than assuming one.
<!-- src: commands.md#doctor; documentation gap noted against docs/settings.md, see verify-commands.md -->

| Option | Effect |
| --- | --- |
| `--offline` | skip the network checks and read capabilities from the cache. |
| `--json` | print only a JSON document instead of the text report. In addition to `ok` and `checks`, the document carries the policy objects `policies`, `name_hygiene`, `case_clashes`, `e2ee`, `external`, `delete_guard`, and `big_folders`. |

The `--json` document shape is
`{"ok":bool,"policies":{"invalid_names","case_clashes","e2ee","external_storage","symlinks","checksum","move_to_trash","delete_guard"},"name_hygiene":{"policy","scanned","invalid","collisions","paths":[]},"case_clashes":{"policy","count","pairs":[]},"e2ee":{"policy","checked","paths":[]},"external":{"policy","checked","paths":[]},"delete_guard":{"ask","threshold","max_delete","detail"},"big_folders":{"limit","policy","checked","over":[{"name","remote","bytes"}]},"checks":[{"name","status","detail"}]}`.

### discover

```
sciebo discover [--write]
```

Scan the roots in `config/roots.conf` for git repositories and emit
sync-list lines. The roots file format is
`mode | root | remote_base | maxdepth` (maxdepth defaults to 3; see
[docs/settings.md](settings.md#rootsconf)). Repositories nested inside
other repositories are collapsed into the outermost one. Git is only used
to locate folders; `.git/` and all other content are treated as ordinary
files.

| Option | Effect |
| --- | --- |
| `--write` | atomically write `config/sources.generated.conf` (under the run lock); without it the sync-list lines are printed. |

Exits 1 when any root or repository was skipped (unreadable or
unrepresentable), 0 otherwise.

```sh
sciebo discover --write && sciebo check
```

### list

```
sciebo list [--json]
```

Print every parsed source: mode, sanitized name, local path, remote path,
and optional filter. Invalid sync-list lines are printed with their error.
Read-only; no lock, no network. `sync --list` is an accepted alias.

`--json` prints the valid entries as `{"sources":[...]}` with their origin
(`manual`, `folders`, or `generated`); invalid lines keep going to stderr.

### filters

```
sciebo filters <subcommand>
```

Manage the rclone filter files in `FILTER_DIR`.

| Subcommand | Behavior |
| --- | --- |
| `sync [--json]` | fetch the server's `sync-exclude.lst`, cache the raw body (`state/sync-exclude.lst`), and regenerate the server filter (`filters/server-exclude.txt`). Atomic; takes no run lock. |
| `list [--json]` | table of `*.txt` filter files (`NAME`, `RULES`, `MTIME`, `SERVER`) plus the age and staleness of the server cache. |
| `show NAME` | print one filter file (bare file name). |
| `check` | validate every `*.txt` filter with rclone's parser, one `PASS`/`FAIL` line per file; exits 1 when any file is rejected. A directory with no `*.txt` files warns. |

`filters sync` honors `HTTP_TIMEOUT`, `HTTP_RETRIES`, `HTTP_RETRY_DELAY`,
`HTTP_FOLLOW_REDIRECTS`/`HTTP_MAX_REDIRS`, and `TLS_INSECURE`/`--trust`; an
empty response fails.

```sh
sciebo filters sync
sciebo filters list
sciebo filters show clutter.txt
sciebo filters check
```

### ignored

```
sciebo ignored [SUB] [options]
```

List the local files that `sync` would not transfer (the desktop client's
"Not synced" analog). Each entry's local directory is listed twice with
`rclone lsf --files-only -R` — once unfiltered and once with sync's filter
layering — and the difference is reported. Read-only: no run lock, no
state writes, and no remote contact.

The filtering mirrors `sync`: the server-exclude filter (when
`FILTER_SERVER_SYNC=1`), `clutter.txt`, the entry's pair filter, the
conflict-pattern exclusion (unless `CONFLICT_UPLOAD=1`), hidden files
(when `SKIP_HIDDEN=1`), the failure-blacklist excludes, and
`--exclude-if-present .nosync` for sync/pull entries (bisync entries
ignore `.nosync`).

| Option | Effect |
| --- | --- |
| `SUB` | restrict the result to files under one local, local-relative, or remote-relative path prefix. At most one positional is allowed. |
| `--source NAME` | restrict the scan to one configured source (sanitized name); an unknown name exits 1. |
| `--json` | print `{"ignored":[{"source","local","path"}]}` instead of the table. |

Rows print as `SOURCE<TAB>LOCAL<TAB>RELATIVE-PATH`; with no matches the
text output is `no ignored files`, otherwise the last line is `<N> ignored
files`. A source whose local directory is missing is skipped with a
warning and does not fail the run; an `rclone lsf` failure for one entry
warns, the remaining sources are still scanned, and the command exits 1.
No confirmation is involved; more than one positional or an unknown
`--source` is an error (exit 2 for the positional, 1 for the unknown
source).

```sh
sciebo ignored
sciebo ignored notes/drafts
sciebo ignored --source notes --json
```

### network

```
sciebo network [--json]
```

Show the active network interface and Wi-Fi name, whether the connection
is metered (a pay-per-use or capped network this tool can detect and treat
more cautiously, such as a mobile hotspot) — from the OS report,
`METERED_SSIDS`, or a hotspot-looking SSID — the `METERED_POLICY` in
effect, and the proxy mode for rclone and curl: the configured `PROXY`
value, `direct` when `PROXY_DIRECT=1` ignores the environment, or
`environment`. Read-only: only local probes run, nothing is written and no
server is contacted.

`--json` prints `{interface, ssid, metered, policy, proxy}`.

```sh
sciebo network
sciebo network --json
```

### folders

```
sciebo folders [command] [options]
```

Choose sciebo folders to pair with local directories, Nextcloud-client
style. The default command is `choose`. The wizard writes only
`config/folders.conf` and pair filter files under `config/filters/`; it
never transfers data and never touches the manual sync list
(`sources.conf`/`sources.generated.conf`). Commits take the run lock.
After adding pairs, run `sciebo check` for a dry run, then `sciebo sync`; a
new bisync pair needs one `sciebo sync --resync --apply` first.

Commands: `choose` (default), `add`, `import`, `edit`, `list`, `pause`,
`resume`, `remove`.

Each configured pair also carries optional per-pair flags stored under
`PAIR_FLAGS_DIR` (default `<STATE_DIR>/pairs`) as a mode-600
`paused=1`/`hidden=1` file named after the sanitized entry. `folders
pause` sets the first, `folders resume` clears it; a paused pair is
reported as skipped by `sync`/`check` (with the `folders resume` hint)
unless `sync --force` runs it anyway. The hidden flag excludes dot-files
for that pair alone, like `SKIP_HIDDEN=1` does globally. `account import`
writes both flags from the desktop client's per-folder `paused` and
`ignoreHiddenFiles`.

`choose` options:

| Option | Effect |
| --- | --- |
| `--depth N` | remote scan depth (default: `FOLDERS_SCAN_DEPTH`, 2). |
| `--local-root DIR` | root for suggested destinations (default: `FOLDERS_LOCAL_ROOT`, `~/sciebo`). |
| `--mode MODE` | fix the direction for all picks (`sync`, `pull`, or `bisync`); otherwise every pick is prompted with `DEFAULT_PAIR_MODE` as default. |
| `--select` | pick which immediate subfolders to sync (include flow); the complement becomes excludes. |
| `--no-fzf` | always use the numbered menu, even when `fzf` is installed. |
| `--no-dry-run` | do not offer the `check --only NAME` dry run after adding pairs. |

The picker shows unconfigured remote folders (already-configured ones are
skipped with a note), uses `fzf` when available and interactive, and
accepts `1 3 5-7` or `all` on the numbered menu.

Before a proposed pair is accepted, `choose` applies three safety policies
in order: `BIG_FOLDER_POLICY` (default `ask`) when the remote folder
exceeds `BIG_FOLDER_SIZE`, `EXTERNAL_STORAGE_POLICY` (default `ask`) when
the folder or its immediate parent is server-mounted external storage, and
`E2EE_POLICY` (default `exclude`) when it is end-to-end encrypted. `ask`
confirms on a terminal and skips the pair otherwise, `warn` warns and
proceeds, `skip`/`exclude` skip the pair, and `allow` proceeds silently.
The big-folder gate uses one bounded `rclone size` lookup; an unreadable
size, an empty `BIG_FOLDER_SIZE`, or a non-Nextcloud remote proceeds (the
external-storage and E2EE checks stay silent on other backends).

`add` options:

| Option | Effect |
| --- | --- |
| `--remote SUB` | remote subfolder below the remote base (required). |
| `--local PATH` | local path (default: `<local-root>/<SUB>`). |
| `--mode MODE` | direction (default: `DEFAULT_PAIR_MODE`). |
| `--select` | interactively pick subfolders to sync. |
| `--include SUB` | sync only this immediate subfolder of `--remote` (repeatable). Mutually exclusive with `--select`. |
| `--exclude SUB` | exclude SUB below the chosen folder (repeatable). |
| `--local-root DIR` | root for the default destination. |

`import` migrations:

```
sciebo folders import FILE --remote SUB [--local PATH] [--mode MODE]
                           [--local-root DIR] [--select]
```

`FILE` is a `nextcloudcmd --unsyncedfolders` list: one folder path per
line, relative to `--remote`, with or without a trailing slash; blank
lines and `#`-comments are ignored. The list names the folders that were
*not* synced by nextcloudcmd (the Nextcloud desktop client's own
command-line tool, not this tool's `nextcloudcmd` subcommand below), so every
listed folder is written as an exclude by default. With `--select`, the
list is instead treated as an include list: every other immediate child
of `--remote` is excluded.

`edit NAME` rewrites a wizard-managed pair's local path, remote subfolder,
filter, or mode. `NAME` is the sanitized entry name from `folders list`;
at least one option is required and the pair must be wizard-managed
(manual entries must be edited in their own file). A `--remote` change
renames the pair (and its pair filter) to the new remote's sanitized name,
so the previous name from `folders list` is what you pass in.

| Edit option | Effect |
| --- | --- |
| `--local PATH` | rewrite the pair's local path (`~` is expanded; the path must be safe). |
| `--remote SUB` | rewrite the pair's remote subfolder; `/` or an empty value means the remote base, stored as `.`. The pair name follows the new remote (`repos/my-app` → `repos_my-app`), and a remote already configured by another pair or a clashing name is refused. |
| `--force` | allow a `--remote` change even though initialized bisync state under `state/bisync/<name>` no longer matches the new path; without it such a change is refused. The state is kept, so re-initialize with `sync --resync` afterwards. |
| `--include SUB` | sync only these immediate subfolders (repeatable); every other immediate child is excluded. Mutually exclusive with `--select`. |
| `--exclude SUB` | exclude SUB below the pair (repeatable). |
| `--mode MODE` | change the direction (`sync`, `pull`, or `bisync`). |
| `--select` | interactively pick subfolders to sync. |
| `--clear` | remove the pair filter (no rules); cannot be combined with filter options. |

Other subcommands:

| Command | Behavior |
| --- | --- |
| `list [--json]` | table with `NAME`, `MODE`, `LOCAL`, `REMOTE`, `SOURCE` (`manual`/`wizard`/`discovered`), `FILTER`, `BISYNC` (`initialized`/`missing`), the newest matching log file (`LASTLOG`), and the per-pair `PAUSED`/`HIDDEN` flags (`yes`/`no`). Read-only; `--json` prints the same rows as `{"pairs":[{"name","mode","local","remote","source","filter","bisync","lastlog","paused","hidden"}]}` (with boolean `paused`/`hidden`) while invalid lines keep going to stderr. |
| `pause NAME` | set NAME's per-pair paused flag so `sync`/`check` skip it (reported as skipped, not failed). `NAME` is the sanitized name from `folders list`. |
| `resume NAME` | clear NAME's paused flag. |
| `remove NAME [--purge]` | remove a wizard-managed pair from `folders.conf`; manual entries must be edited in their own file. Without `--purge` it prints a note when leftover bisync state exists under `state/bisync/NAME`. `--purge` also deletes that bisync workdir, the run record (`state/last/NAME`), the history file (`state/history/NAME.log`), the blacklist record, the pair filter, and the pair flags file; local data directories are never touched. |

Examples:

```sh
sciebo folders choose --select --mode bisync
sciebo folders add --remote papers --local ~/papers --mode pull --exclude drafts
sciebo folders add --remote projects --include code --include docs --mode bisync
sciebo folders import ~/unsyncedfolders.txt --remote backup
sciebo folders edit papers --include final --mode pull
sciebo folders edit papers --local ~/Documents/papers
sciebo folders edit papers --remote archive/papers
sciebo folders edit papers --remote archive/papers --force
sciebo folders edit papers --clear
sciebo folders list
sciebo folders list --json
sciebo folders pause papers
sciebo folders resume papers
sciebo folders remove papers
sciebo folders remove papers --purge
```

### open

```
sciebo open [SUB] [--print] [--web]
```

Open the local folder for `SUB`. The first valid sync-list entry whose
`remote_subdir`, local path, or sanitized name equals `SUB` wins; without a
match, `SUB` is resolved below `FOLDERS_LOCAL_ROOT` (the root itself when
`SUB` is omitted). The folder must already exist, so run `sciebo sync`
first. `--print` prints the resolved path instead of opening it; opening
uses `open` on macOS and `xdg-open` elsewhere. Read-only and offline.

With `--web`, open the Nextcloud Files app at `/<REMOTE_BASE>[/SUB]` in
the browser instead of the local folder; `--print` then prints the URL.
When `SUB` resolves to a remote file, `--web` opens its direct link
(`<base>/index.php/f/<fileid>`) instead, and falls back to the Files-app
URL when the file id cannot be resolved. This variant loads the settings
and needs the remote's base URL, so it is not offline.

```sh
sciebo open notes
sciebo open --print
sciebo open notes --web
sciebo open papers/report.pdf --web
```

## Syncing

### check

```
sciebo check [sync options]
```

The same run as `sync` with `--dry-run` forced. It changes nothing and
prints, per source, a status row and (unless `--quiet`) a `plan:` line
with the number of copies, deletes, and other skipped actions plus up to
three example paths. `check --apply` still runs as a dry run, so the
delete guard never applies. All [sync options](#sync) are accepted
(including `--metered-ok`); `--list` still aliases `list`.

### sync

```
sciebo sync [options]
```

Apply sync/pull/bisync entries from `config/sources.conf`,
`config/folders.conf`, and `config/sources.generated.conf`, in that order.

| Option | Effect |
| --- | --- |
| `--apply` | transfer data (the default for `sync`). |
| `--dry-run` | explicit dry run (the default for `check`). |
| `--only NAME` | run only entries whose sanitized name is `NAME` (see `sciebo list`). An unknown name fails with exit 1. |
| `--resync` | allow rclone bisync `--resync`, the first-time initialization. WARNING: resync can copy or delete files in **both** directions; review a dry run with `--resync` first. A resync also passes `BISYNC_RESYNC_MODE`. |
| `--yes` | proceed with pull/bisync sources that exceed `MAX_DOWNLOAD_SIZE` and disable the delete guard for this run. |
| `--metered-ok` | run even when the connection is metered, overriding `METERED_POLICY=skip`/`ask` for this run. |
| `--quiet` | only print failures, warnings, and the final summary. |
| `--no-lock` | do not take the run lock (use with care; overlapping runs are then possible). |
| `--force` | run even while paused (the global `sciebo pause` marker or a per-pair `folders pause` flag). |
| `--list` | compatibility alias for `sciebo list`. |
| `-h`, `--help` | usage. |

Behavior highlights:

- A run takes the single-run lock (a safeguard against two sync/cleanup
  runs overlapping on the same machine) unless `--no-lock` is given; a
  stale lock is replaced automatically. `--resync` prints a
  both-directions warning.
- `bisync` entries without initialized state fail unless `--resync` is
  given; duplicate bisync names are refused because they would share
  state.
- Filters (`clutter.txt`, per-source/pair filters), `.nosync` markers for
  sync/pull, the conflict-copy upload exclusion, `SKIP_HIDDEN`, the
  retry blacklist, and the chunk size setting are applied to the rclone
  flags.
- Desktop-parity exclusions are added per entry: with
  `INVALID_NAME_POLICY=exclude` (the default) non-portable names (the
  Windows-invalid characters `<>:"|?*`, brackets, a trailing dot or
  space, and the reserved device names `CON`/`PRN`/`AUX`/`NUL`/`COM1-9`/
  `LPT1-9`) are excluded; `warn` only reports them and `allow` keeps
  rclone's behavior. With `CASE_CLASH_POLICY=exclude` (the default) the
  later name of a local case-only collision (in `LC_ALL=C` order) is
  excluded, `rename` quarantines it on an apply as `<name> (case
  conflict)<ext>` (a dry run only prints the planned rename), and `warn`
  only reports the pair. With `CASE_CLASH_REMOTE_SCAN=1` the same policy
  also applies to remote case-only collisions found by an `rclone lsf -R`
  listing (off by default); remote paths are never renamed, so `rename`
  excludes the losing path there.
- Remote policy preflights run before a skipped entry touches local
  files: `E2EE_POLICY=exclude` (the default) excludes end-to-end
  encrypted subfolders from pull/bisync and skips an entry whose own
  remote root is E2EE (`warn` only warns, `allow` is silent);
  `EXTERNAL_STORAGE_POLICY=ask` (the default) asks once on a terminal
  before syncing a remote root on server-mounted external storage and
  skips otherwise (`skip`, `warn`, and `allow` behave as named);
  `BIG_FOLDER_EXISTING_POLICY=warn` (the default) warns when a
  configured source exceeds `BIG_FOLDER_SIZE` (`skip` skips it, `allow`
  is silent). Pull/bisync entries also warn about unconfigured remote
  subfolders over `BIG_FOLDER_SIZE`, reusing a cached scan for
  `BIGFOLDER_SCAN_TTL`. The E2EE and external-storage checks stay silent
  on non-Nextcloud remotes and when the server does not expose the
  property.
- `MOVE_TO_TRASH=1` moves files deleted or overwritten by pull/bisync
  runs into `LOCAL_TRASH_DIR` (default `<state>/trash`, rclone
  `--backup-dir` per source) instead of deleting them; a configured
  `BACKUP_DIR` takes precedence. `CHECKSUM=1` compares transfers by
  checksum (`--checksum` for sync/pull, `--compare
  size,modtime,checksum` for bisync). `SYMLINK_POLICY` selects `skip`
  (default, `--skip-links`), `follow` (`--copy-links`), or `translate`
  (`--links`).
- The delete guard: with `ASK_DELETE=1` (the default) and an unlimited
  `MAX_DELETE` (`-1`), each apply passes `--max-delete
  DELETE_FILES_THRESHOLD` (default 100, per
  [docs/settings.md](settings.md)). When rclone stops because the
  threshold was reached, a terminal asks once to continue without the
  cap; a non-interactive run fails the entry with `delete guard: more
  than N file(s) to delete; re-run with --yes to allow`. `--yes` disables
  the guard for the run, and an explicit `MAX_DELETE >= 0` overrides it.
  <!-- src: commands.md#sync; the literal default (100) is documented in docs/settings.md, cross-referenced here, not restated as this file's own claim -->
- The upload chunk size is resolved once per run. `CHUNK_SIZE` wins; when
  it is unset and the remote is nextcloud, the value is derived from
  `TARGET_CHUNK_UPLOAD_DURATION` (milliseconds) times `BW_LIMIT_UP` (or
  `TARGET_UPLOAD_THROUGHPUT` when `BW_LIMIT_UP` is empty), capped at the
  server's maximum. Without a throughput the cached server maximum is
  used. The result is clamped to `MIN_CHUNK_SIZE`/`MAX_CHUNK_SIZE` when
  those are set; a clamp prints `chunk size X clamped to Y`. `PROXY_TYPE`
  selects the proxy mode: `system` (default) uses `PROXY` when set and
  otherwise the proxy environment (`PROXY_DIRECT=1` strips it), `none`
  ignores all proxy settings, and `http`/`socks5` require `PROXY`, which
  is passed as rclone `--http-proxy` (Go accepts `socks5://` URLs) and
  curl `-x`. This is a run-level derivation, not the desktop client's
  per-chunk resizing.
- Dry runs report a `plan:` line; applied bisync runs report a
  `conflicts:` line when conflict copies were created (even under
  `--quiet`).
- Metered connection: entries are skipped when `METERED_POLICY=skip`
  (`metered connection (METERED_POLICY=skip)`); `--metered-ok` overrides
  that for the run. With `METERED_POLICY=ask` the run asks on a TTY.
- Free disk space: pull and bisync entries fail when it is below
  `MIN_FREE_SPACE` (`free space below MIN_FREE_SPACE`) and are skipped
  when it is below `FREE_SPACE_DOWNLOAD` (`free space below
  FREE_SPACE_DOWNLOAD`).
- Server quota: with `QUOTA_WARN_PERCENT` above `0`, the server quota is
  probed once before the entries (shared with `doctor`) and a `quota
  guard: N% of <remote>: used ...` warning is printed at or above the
  threshold. A probe error warns and the run continues; the check never
  fails a run.
- The summary line counts sources and conflicts; the exit status is 1
  when any source failed, 0 otherwise. A notification is sent for apply
  runs depending on `NOTIFY`/`NOTIFY_SUCCESS`.
- With `MAX_PARALLEL_SOURCES` > 1, entries run in bounded parallel worker
  subshells with output printed per entry when it finishes; counters,
  conflicts, notifications, blacklist, and runstate match the serial
  path.
- SIGINT/SIGTERM stops the active rclone child (and parallel workers)
  and releases the lock; the exit status is 130/143.

### nextcloudcmd

```
sciebo nextcloudcmd [OPTIONS] SOURCEDIR NEXTCLOUDURL
```

This is this tool's own nextcloudcmd-compatible command, not the external
tool — it accepts the Nextcloud desktop client's separate `nextcloudcmd`
command-line tool's option names for easy migration, but it is this
project's own implementation. It runs one two-way sync between SOURCEDIR
and NEXTCLOUDURL. The WebDAV folder is
`<url>/remote.php/dav/files/<user>/<--path>`; the first run initializes
the rclone bisync state automatically (`--resync`). The command uses its
own dedicated rclone remote (`sciebo-nextcloudcmd`), so a normal `sciebo
setup` remote is neither read nor changed. `scripts/nextcloudcmd` is a
shim that forwards here.

| Option | Effect |
| --- | --- |
| `--path SUB` | remote folder below the user root. |
| `--confdir DIR` | configuration base for this run (ignored when `SCIEBO_CONFDIR` is already set). |
| `--user USER`, `-u USER` | user name. |
| `--password PASS`, `-p PASS` | password (an app password is recommended). The value is visible in the process list; prefer `--password-fd`. |
| `--password-fd N` | read the password from the already-open file descriptor N (e.g. `3<<<"$PW"`); keeps it out of the process list. |
| `-n` | read credentials from `~/.netrc` (machine entry for the URL host). |
| `--non-interactive` | never prompt. |
| `--silent`, `-s` | errors only (`--log-level ERROR --stats 0`). |
| `--trust` | accept invalid TLS certificates. |
| `--httpproxy URL` | HTTP proxy URL (falls back to `PROXY`). An http(s) proxy is exported to the rclone child's environment instead of its argv, so its credentials never reach `ps`; `PROXY_TYPE`/`PROXY_DIRECT` apply as everywhere else. |
| `--exclude FILE` | read exclude patterns from FILE. |
| `--exclude-anchored FILE` | read patterns from FILE and anchor each at the sync root (rclone `--exclude "/PAT"`); blank lines and `#`-comments are ignored and a missing file fails. |
| `--unsyncedfolders FILE` | exclude every folder listed in FILE (one path per line; blank lines and `#`-comments are ignored). |
| `--max-sync-retries N` | retry the whole sync up to N times: after a successful run, a dry-run probe is repeated while it still reports `as --dry-run is set`, and every following full run counts toward N. A failed probe stops the retries with a warning. |
| `--uplimit RATE` / `--downlimit RATE` | upload/download bandwidth caps (rclone `--bwlimit up:down`). |
| `--logdebug`, `--verbose` | debug-level logging (rclone `--log-level DEBUG`). |
| `--progress`, `-P` | show rclone's transfer progress (`-P`). Terminal only, and suppressed by `--silent` and by the internal `--max-sync-retries` dry-run probe. |
| `-v`, `--version` | print the version and exit. |
| `-h` | sync hidden files (disables the default `--exclude ".*"`). Note: `-h` is **not** help. |
| `--dry-run` | report what would change, change nothing. |
| `--help` | show help. |

Credential precedence: `--user`/`--password` (or `--password-fd`) >
userinfo in NEXTCLOUDURL > `NC_USER`/`NC_PASSWORD` (non-interactive only)
> `~/.netrc` with `-n` > interactive prompt. A non-interactive run without
credentials fails. The bisync workdir is `state/nextcloudcmd/<host>-<path>`,
shared by later runs against the same host and path. Without `-h`, hidden
files are excluded; conflict copies are excluded unless
`CONFLICT_UPLOAD=1`. Exit 1 when rclone fails.

```sh
scripts/nextcloudcmd --path notes ~/notes https://your-university.sciebo.de
sciebo nextcloudcmd --user alice@your-university.de --password "$PW" ~/notes https://your-university.sciebo.de
sciebo nextcloudcmd --user alice@your-university.de --password-fd 3 3<<<"$PW" ~/notes https://your-university.sciebo.de
sciebo nextcloudcmd --dry-run ~/notes https://your-university.sciebo.de
sciebo nextcloudcmd --exclude-anchored .sync-exclude ~/notes https://your-university.sciebo.de
```

### watch

```
sciebo watch [options]
```

Watch the local directories of the configured sources and run `sciebo
sync --apply --quiet --only NAME` when one changes. This is a foreground
command, not a background service: it runs only while you keep it running
(use `sciebo schedule install` for a periodic background job instead). One
watcher per profile is tracked in `state/watch/watch.pid`; starting a
second watcher fails. A source whose local directory is missing is
skipped with a warning, and runs are skipped while `sciebo pause` is
active.

| Option | Effect |
| --- | --- |
| `--interval N` | poll interval and minimum seconds between two runs of the same source (default `WATCH_INTERVAL`). |
| `--debounce N` | coalesce change events for N seconds (default `WATCH_DEBOUNCE`). |
| `--only NAME` | watch only this source; repeatable. An unknown name fails. |
| `--remote-interval N` | check the remote every N seconds and notify when it differs; 0 disables (default `WATCH_REMOTE_INTERVAL`). |
| `--backend BACKEND` | `auto`, `fswatch`, `inotify`, or `poll` (default `WATCH_BACKEND`); a requested backend that is not installed fails. |
| `--once` | run one detection cycle, sync affected sources, exit. |
| `--notify` | allow desktop notifications (overrides `NOTIFY`). Mutually exclusive with `--no-notify`. |
| `--no-notify` | disable desktop notifications even when `NOTIFY=1`. Mutually exclusive with `--notify`. |
| `--quiet` | only warnings and errors. |
| `-h`, `--help` | usage. |

```sh
sciebo watch --only notes --only papers
sciebo watch --once --backend poll
```

### edit

```
sciebo edit SUB [options]
```

Download one remote file on demand, open it in an editor, and upload it
again when it changed. `SUB` is resolved through the sync list only: the
first valid entry whose `remote_subdir` equals `SUB` or is a parent of
`SUB` wins (like `hydrate`), and the local copy lives at that entry's
local path. Unlike `hydrate` there is no `FOLDERS_LOCAL_ROOT` fallback —
`edit` needs a configured source — and `SUB` must name a file, not a
directory; a missing remote path exits 1.

The run lock is held for the whole operation. The file is downloaded with
`rclone copyto` before the editor opens. The editor is `--editor CMD`
when given, else `$EDITOR`, else `$VISUAL`; `CMD` may carry arguments
(split on spaces, the file path is appended last). Without any editor the
platform opener (`open` on macOS, `xdg-open` on Linux) is used and the
upload is skipped, as if `--no-upload` had been given.

| Option | Effect |
| --- | --- |
| `--editor CMD` | editor command, possibly with arguments. |
| `--no-upload` | download and edit, but never upload. |
| `--lock` | take a WebDAV lock (`sciebo lock`) while editing and release it afterwards; a failed release only warns. |
| `-h`, `--help` | usage. |

Change detection compares `<mtime>:<size>` before and after the editor
exits, so a size change with a preserved mtime still counts. An editor
that exits non-zero still has its changes checked (a warning is printed).
If the editor removed the local file, the command exits 1 and uploads
nothing. Otherwise the outcomes are `edit: uploaded SUB`, `edit: SUB
unchanged, not uploaded`, or `edit: SUB changed, not uploaded
(--no-upload)`; an upload failure exits 1. No prompt is involved, so
`edit` works from scripts as long as an editor command is configured; a
missing `SUB`, an extra positional, or an unsafe remote path is a usage
error (exit 2), and a missing sync-list entry or remote path exits 1.

```sh
sciebo edit notes/todo.md
sciebo edit notes/todo.md --editor "code --wait"
sciebo edit notes/todo.md --lock --no-upload
```

### verify

```
sciebo verify [options]
```

Check that every configured source matches its destination with `rclone
check`. verify never transfers, deletes, takes the run lock, or writes
logs. Sync sources are checked local → remote, pull sources remote →
local, and bisync sources two-way.

| Option | Effect |
| --- | --- |
| `--only NAME` | check only the source with this sanitized name. |
| `--download` | download remote files and hash them (slow; catches server-side corruption). |
| `--size-only` | compare sizes only, skipping hashes. |
| `--quiet` | only print failures and the summary. |

Failures print up to five output lines from rclone. Exit 1 when any
source failed, 0 otherwise.

### status

```
sciebo status [options]
```

Show the pause state and the last recorded run per source: name, mode,
state, when it ran, and details (exit code and conflicts, or the recorded
reason). Sources that never ran show `never`; failed rows also print
their log path. Read-only: status never takes the run lock or writes
logs; the only write is removing an expired pause marker.

| Option | Effect |
| --- | --- |
| `--only NAME` | show only this source. An unknown name prints to stderr and exits 1. |
| `--history [N]` | after each row, print its last N recorded runs (default 10, newest first) as `<date> <sTATUS> <detail>`. Combined with `--quiet`, nothing is printed (exit 0). |
| `--json` | print the pause state and one row per source as a single JSON document; cannot be combined with `--watch`. |
| `--watch [N]` | refresh the report every N seconds (default 5) until interrupted with INT/TERM (exit 130/143). On a TTY the screen is cleared before each snapshot. |
| `--quiet` | print only rows that need attention (failed/skipped/never) plus the pause state and summary. |

### pause

```
sciebo pause [--for DURATION]
```

Skip sync and check runs until `sciebo resume`. Without `--for` the pause
is indefinite. `DURATION` is a number with an optional `s`, `m`, `h`, or
`d` suffix (`90m`, `24h`, `1d`); a bare number means minutes. An expired
marker is removed automatically on the next check. Prints `paused until
<stamp>` or `paused (indefinite)`.

### resume

```
sciebo resume
```

Clear the pause marker. Prints `resumed` when a pause was active and
`not paused` otherwise.

### limit

```
sciebo limit [options]
```

Cap rclone bandwidth for later `sciebo sync` runs. The limit is stored as
a local marker (`state/bwlimit`, no server contact) and applies until it
expires or `sciebo unlimited` removes it. An active marker takes
precedence over `BW_SCHEDULE` and `BW_LIMIT_UP`/`BW_LIMIT_DOWN`; an
expired marker is removed automatically on the next read. At least one of
`--up`, `--down`, `--until`, `--show`, or `--clear` is required.

| Option | Effect |
| --- | --- |
| `--up RATE` | upload cap (rclone size suffix, e.g. `2M`; `off` = no cap). |
| `--down RATE` | download cap (e.g. `5M`). |
| `--until DUR` | expire after this long; a bare number means minutes, `0` means no expiry (default). |
| `--show` | print the current limit without changing it. |
| `--clear` | remove the marker (same as `sciebo unlimited`). |
| `--json` | print the state as JSON (`{active, up, down, until, until_stamp}`). |
| `-h`, `--help` | usage. |

`--show` and `--clear` are mutually exclusive and cannot be combined with
`--up`/`--down`/`--until`. With a marker, the text output is `limited:
up=... down=... until=...`; without one it is `unlimited`.

```sh
sciebo limit --down 5M --until 2h
sciebo limit --up 1M --down off
sciebo limit --show
sciebo limit --clear
```

### unlimited

```
sciebo unlimited
```

Remove the bandwidth marker written by `sciebo limit` so later sync runs
are uncapped again (unless `BW_SCHEDULE` or `BW_LIMIT_UP`/`BW_LIMIT_DOWN`
is configured). Prints `unlimited`.

## Mounts

### mount

```
sciebo mount [--folder SUB] [--mountpoint PATH] [--ro] [--foreground] [--sudo]
```

Expose the remote (or a subfolder) as a local filesystem with `rclone
nfsmount`: files are fetched on first access instead of being synced up
front. No macFUSE is needed on macOS. Mounts are never scheduled; they
exist only while the rclone process runs.

| Option | Effect |
| --- | --- |
| `--folder SUB` | remote subfolder below the remote base (default: the remote base itself, mount name `root`). |
| `--mountpoint PATH` | local mountpoint (default: `MOUNT_ROOT` or `MOUNT_ROOT/<name>`). Must be empty or absent. |
| `--ro` | read-only mount, no VFS cache. |
| `--foreground` | run rclone in the foreground; Ctrl-C unmounts. A state record is written and removed on exit. |
| `--sudo` | run rclone as root; macOS NFS mounts usually need this. |

Read-write mounts (the default) stage opened files in a VFS cache bounded
by `MOUNT_CACHE_MAX_SIZE` under `state/mount-cache/`. With
`MOUNT_FILTERS=1` the clutter list and a matching pair filter are applied;
`MOUNT_NO_SYNC=1` passes `--exclude-if-present .nosync` (honored only
where the mount backend supports it). Fails when the remote folder is
missing, the mountpoint is occupied, or a state record already exists
(unmount first).

```sh
sciebo mount --folder notes --ro
sciebo mount --folder notes --foreground
```

### umount

```
sciebo umount (--folder SUB | --mountpoint PATH | --all) [--sudo]
```

Unmount a recorded mount and remove its state record. Exactly one
selector is required. The recorded rclone process is stopped only when it
is still the `nfsmount` for that mountpoint. macOS NFS unmounts usually
need `--sudo`.

### mounts

```
sciebo mounts [--folder SUB] [--check] [--prune] [--json]
```

Show recorded mounts with mount visibility, rclone pid, and pid liveness:
`<name> <folder|(base)> <mountpoint> mounted=<yes|no> pid=<pid|-> alive=<yes|no>`.

| Option | Effect |
| --- | --- |
| `--folder SUB` | only show the mount recorded for this remote subfolder. |
| `--check` | print a summary and exit 1 when a recorded mount is not visible or its rclone process is gone. |
| `--prune` | remove records whose mountpoint is not mounted and whose pid is not alive. |
| `--json` | print `{"mounts":[{...}]}` instead of the table (pid is null when unknown). |

### hydrate

```
sciebo hydrate SUB [options]
```

Download a remote path below the remote base on demand (the VFS "keep
downloaded" analog). `SUB` is copied with the same filter layering as
sync: the server-exclude filter (when `FILTER_SERVER_SYNC=1`),
`clutter.txt`, the matching sync-list entry's filter file, the
conflict-pattern exclusion (unless `CONFLICT_UPLOAD=1`), hidden files
(when `SKIP_HIDDEN=1`), the failure-blacklist excludes, and `.nosync`
markers. The destination is the local directory of the first sync-list
entry whose `remote_subdir` equals `SUB` or is a parent of `SUB`, with the
remaining relative path appended; without a match it is
`FOLDERS_LOCAL_ROOT/SUB`. With `--dest DIR` the contents of `SUB` are
copied into `DIR` instead (the matching sync-list entry's filter still
applies). Hydrate takes the run lock and creates missing destination
directories; it never deletes.

| Option | Effect |
| --- | --- |
| `--dest DIR` | copy the contents of SUB into DIR instead of the resolved destination (the matching sync-list entry's filter still applies). |
| `--dry-run` | report what would be copied; changes nothing. |
| `--quiet` | do not print the success line (rclone output still shows). |
| `--json` | print `{"path","dest","dry_run"}` instead of the text line. |
| `--progress` | show rclone's transfer progress (`-P`). Terminal only, and suppressed by `--quiet` and `--json`. |

```sh
sciebo hydrate notes/todo.md
sciebo hydrate notes --dest /tmp/notes --dry-run
```

## Housekeeping and scheduling

### cleanup

```
sciebo cleanup (--logs | --uploads | --state | --junk | --cache | --support) [--apply]
```

Housekeeping. Dry run by default: nothing is deleted without `--apply`.
At least one mode is required; modes can be combined. The command refuses
to run while the local sync lock is held; runs on other devices cannot be
detected, so age guards exist for everything that could belong to a run
elsewhere.

| Mode | Behavior |
| --- | --- |
| `--logs` | report/delete `*.log` files older than `LOG_RETENTION_DAYS` (or `LOG_EXPIRE_HOURS` when set) and rotate `*.log` files larger than `LOG_MAX_BYTES` to `<file>.1` (age candidates are not rotated). |
| `--uploads` | report/delete stale Nextcloud chunk uploads under `/remote.php/dav/uploads/<user>/` older than `CHUNK_CLEANUP_MIN_AGE`, then remove emptied transfer directories. |
| `--state` | report/remove orphaned state older than `STATE_CLEANUP_MIN_AGE`: bisync workdirs no valid sync-list entry uses, leftover lock directories, atomic-write `*.tmp.XXXXXX` staging files under `config/` and `state/`, and mount records whose mount and process are gone. |
| `--junk` | report/delete files matching a glob in `FILTER_DIR/fleeting.txt` under every valid sync-list source directory, older than `JUNK_CLEANUP_MIN_AGE`. Dry runs show at most five examples. |
| `--cache` | report/delete files under `MOUNT_CACHE_DIR` older than `STATE_CLEANUP_MIN_AGE`. Dry runs show at most five examples. |
| `--support` | keep the newest support archives under `STATE_DIR` and report/delete the older ones; `--keep N` sets how many to keep (default 5). |

| Option | Effect |
| --- | --- |
| `--apply` | actually delete or rotate; without it everything is a dry run. |
| `--keep N` | `--support`: number of archives to keep (default 5). Requires `--support`. |

Exit 1 when a delete or rotate failed, 0 otherwise.

```sh
sciebo cleanup --junk              # report
sciebo cleanup --junk --apply      # delete
sciebo cleanup --logs --state --apply
sciebo cleanup --cache --apply
sciebo cleanup --support --keep 3 --apply
```

### logs

```
sciebo logs [list]
       sciebo logs show NAME [--lines N]
       sciebo logs tail NAME [--lines N]
       sciebo logs path [NAME]
```

List, print, or follow the per-source sync logs in `LOG_DIR` (`state/logs/`
by default, `--log-dir` overrides). Sources come from the sync list, the
run records under `state/last/`, and the per-source `*.log` files in
`LOG_DIR`. Read-only: no run lock, no state writes, and no network.

| Subcommand | Behavior |
| --- | --- |
| `list` (default) | table with `NAME`, `MODE`, `PATH`, `SIZE`, `MTIME`, and `STATUS` (the last recorded run, uppercased, or `never`). `--json` prints the same rows as `{"logs":[{"source","mode","path","size","mtime","status"}]}`. |
| `show NAME` | print the last `--lines` lines of NAME's log (default 50). The log recorded by the last run is preferred; otherwise the newest normal log, falling back to a dry-run log with a note on stderr. |
| `tail NAME` | like `show`, but follow the file with `tail -f` until interrupted. |
| `path [NAME]` | print NAME's resolved log path as `name<TAB>path` (`-` when no log exists); without NAME, one line per known source. |

| Option | Effect |
| --- | --- |
| `--lines N` | number of trailing lines `show`/`tail` print (default 50); a missing, zero, or non-numeric value is a usage error. |
| `--json` | `list`: print `{"logs":[...]}`. Rejected by the other subcommands. |
| `-h`, `--help` | usage. |

`NAME` is sanitized before lookup; an unknown name exits 1 with the known
names in the message, and `show`/`tail`/`path` exit 1 when the source has
no log yet. A source whose name is a prefix of another (`repo` vs
`repo-b`) never matches the wrong file, and a dry-run log is only used
when no normal log exists. No confirmation is involved; an unknown
subcommand or a bad `--lines` value is a usage error (exit 2), and `list`
exits 0.

```sh
sciebo logs
sciebo logs show notes --lines 100
sciebo logs tail notes
sciebo logs path notes
sciebo logs list --json
```

### schedule

```
sciebo schedule install|uninstall|status
```

Manage the per-user scheduler agent — an opt-in, installable background
job. The backend is selected by platform: launchd on macOS, `systemd
--user` on Linux. Both run `bash <project>/bin/sciebo sync --apply
--quiet` daily at `SCHEDULE_HOUR:SCHEDULE_MINUTE`, every
`SCHEDULE_INTERVAL` seconds, or when `SCHEDULE_WATCH_PATH` changes;
`SCHEDULE_JITTER` adds a random pre-delay. A bare `crontab` binary is
detected but not managed: on such a system the command fails with a
message to add or remove the crontab entry by hand.
<!-- src: commands.md#schedule -->

| Subcommand | Behavior |
| --- | --- |
| `install` | launchd: render `launchd/de.rclone-sciebo.sync.plist.in` to `~/Library/LaunchAgents/<LAUNCHD_LABEL>.plist`, lint it with `plutil`, and bootstrap it with `launchctl`. systemd: write `<LAUNCHD_LABEL>.service` and `.timer` (plus a `.path` unit when `SCHEDULE_WATCH_PATH` is set) under `~/.config/systemd/user/`, then `daemon-reload` and `enable --now`. |
| `uninstall` | launchd: boot out the agent and remove the plist. systemd: disable and remove the units and reload the daemon. |
| `status` | print `not installed` (exit 0), `installed and loaded` plus mode lines (exit 0), or `installed but not loaded` (exit 1). Warnings point out units that still run the old `scripts/sync.sh` entrypoint. |

Options for `install`:

| Option | Effect |
| --- | --- |
| `--at-login` | start the agent at login/boot (`RunAtLoad` on launchd, `[Install] WantedBy=default.target` on systemd); overrides `SCHEDULE_AT_LOGIN=1`. |
| `--profiles LIST` | render one extra agent per profile, labelled `<LAUNCHD_LABEL>.<profile>`, each running with `--profile`; comma or space separated, overrides `SCHEDULE_PROFILES`. Every listed profile directory must exist. |

The run lock prevents overlap with manual runs. Mounts are never
scheduled.

### support

```
sciebo support [--output FILE] [--no-network] [--json]
```

Build a redacted debug archive for bug reports. The archive contains the
version banner, the doctor report, redacted settings and rclone config,
state/runstate listings, the newest logs (last 200 lines each, at most
five), capabilities, and the scheduler/mount status. Passwords, secrets,
tokens, and proxy values are replaced with `REDACTED`; `.env` is never
included. The doctor always runs offline, so the archive needs no network
access.

| Option | Effect |
| --- | --- |
| `--output FILE` | archive path (default `state/support-<YYYYmmdd-HHMMSS>.tar.gz`). |
| `--no-network` | accepted for nextcloudcmd-style callers; the doctor is offline anyway. |
| `--json` | print `{"archive":"...","files":N,"bytes":N}`. |

```sh
sciebo support
sciebo support --output /tmp/sciebo-support.tar.gz
```

## Server data

The commands in this section build on the configured remote. The ones
that talk to Nextcloud's API (OCS) or WebDAV directly (`share`,
`notifications`, `activity`, `presence`, `lock`, `trash`, `versions`,
`file`, `search`, `comments`, `favorites`, `tags`, `server`) honor
`HTTP_TIMEOUT`, `HTTP_RETRIES`, `HTTP_RETRY_DELAY`,
`HTTP_FOLLOW_REDIRECTS`/`HTTP_MAX_REDIRS`, and `TLS_INSECURE`/`--trust`.
The browser sign-in flow uses its own curl calls with their own timeouts;
certificate verification there is on by default as well, and
`--trust`/`TLS_INSECURE=1` opts out of it too (with a one-time warning).

### trash

```
sciebo trash [list]
sciebo trash restore ID [ID ...] [--yes]
sciebo trash restore --all [--yes]
sciebo trash rm ID [ID ...] [--yes]
sciebo trash empty [--yes]
```

List or clean up the Nextcloud trashbin. The listing (default) is
read-only: original name, original location, deletion time, and size.
IDs are the last path segment printed by the listing.

| Action | Behavior |
| --- | --- |
| `restore ID ...` | MOVE each item back to its original location. No prompt. |
| `restore --all` | restore every listed item after one confirmation; `--yes` (or an interactive yes) is needed. Restores are done through the server. |
| `rm ID ...` | permanently delete items. Asks once on a terminal unless `--yes` is given; a non-interactive run deletes them as before. |
| `empty` | permanently delete the whole trashbin after one confirmation; needs `--yes` when not interactive. |

```sh
sciebo trash
sciebo trash restore 12345
sciebo trash rm 12345 --yes
sciebo trash empty --yes
```

### versions

```
sciebo versions SUB [options]
```

List the Nextcloud versions of a remote path below the remote base
(read-only unless an action option is given). `SUB` must exist and be a
file; the path is resolved to a file id first.

| Option | Effect |
| --- | --- |
| `--download VERSION` | save the version; default target `./<basename>.<VERSION>`. |
| `--output FILE` | write the `--download` body to FILE. Requires `--download`. |
| `--stdout` | stream the `--download` body to standard output. Requires `--download`; mutually exclusive with `--output`. |
| `--restore VERSION` | restore the version (asks first; needs `--yes` when not interactive). |
| `--delete VERSION` | delete the version (asks first; needs `--yes` when not interactive). |
| `--yes` | skip the `--restore`/`--delete` confirmation. |

`--download`, `--restore`, and `--delete` are mutually exclusive. VERSION
is numeric.

```sh
sciebo versions notes/todo.md
sciebo versions notes/todo.md --download 1712345678 --output /tmp/todo.md.bak
sciebo versions notes/todo.md --restore 1712345678 --yes
```

### share

```
sciebo share <subcommand> [options]
```

Manage Nextcloud shares through the OCS sharing API. `SUB` is a remote
path below the remote base. Permissions are letters (`r`=read,
`w`=update, `d`=delete, `c`=create, `s`=reshare) or a numeric mask; link
shares default to read-only (`1`), the other share types to all (`31`).

| Subcommand | Behavior |
| --- | --- |
| `link SUB [options]` | create a public link share; prints `created share <id>` and the URL. |
| `user SUB USER [options]` | share with a Nextcloud user. |
| `group SUB GROUP [options]` | share with a Nextcloud group. |
| `email SUB ADDRESS [options]` | share with an email address. |
| `guest SUB GUEST [options]` | share with a guest account (share type 8, from the guests app). |
| `circle SUB CIRCLE_ID [options]` | share with a circle. |
| `talk SUB ROOM_TOKEN [options]` | share with a Talk conversation. |
| `deck SUB CARD_ID [options]` | share with a Deck card/board. |
| `remote SUB [USER@]SERVER [options]` | share with a federated cloud id. |
| `list [SUB] [--reshares] [--json]` | list shares, optionally filtered to one path; `--reshares` asks the server for reshares only and `--json` prints the rows as JSON. |
| `info ID` | show one share. |
| `update ID [options]` | change a share; at least one change option is required. |
| `remove ID [--yes]` | delete a share. Asks on a terminal unless `--yes` is given; a non-interactive run proceeds as before. |
| `leave ID [--yes]` | leave a share shared with you. Asks on a terminal unless `--yes` is given; a non-interactive run proceeds as before. |
| `pending [--local\|--remote] [--json]` | list shares waiting for your acceptance. |
| `accept ID [--remote]` / `accept --all [--remote]` | accept one pending share, or with `--all` every pending share of the selected kind(s). `--remote` forces the federated list. `--all` cannot be combined with an explicit id. |
| `decline ID [--remote] [--yes]` / `decline --all [--remote] [--yes]` | decline one pending share, or with `--all` every pending share. Asks on a terminal unless `--yes` is given; a non-interactive run **requires** `--yes` (exit 2 otherwise), because a declined share can be lost. `--all` cannot be combined with an explicit id. |
| `send-email ID` | ask the server to email an existing share to its recipient (`POST /shares/{id}/send-email`). |
| `remote-list [--json]` | list the accepted federated shares (`GET /remote_shares`) as an `ID`/`Type`/`Owner`/`Target` table, or as `{"remote_shares":[...]}` with `--json`. |
| `search QUERY` | find sharees: users, groups, email, federated, circles, guests, and Talk rooms (a server that rejects the extra types is retried with users and groups only). Results are labelled with the sharee type. |
| `copy-link SUB [options]` | reuse SUB's existing public link or create one, then copy it with `pbcopy` when available (otherwise print it). |
| `copy-internal SUB` | copy a direct internal link (`<base>/index.php/f/<fileid>`) with `pbcopy` when available (otherwise print it). |
| `incoming [--json]` | list shares shared with you, adding a `Shared-by` column; `--json` prints the shares as JSON. |

The create subcommands (`link`, `copy-link`, `user`, `group`, `email`,
`guest`, `circle`, `talk`, `deck`, `remote`) accept `--json`: instead of
the text line they print `{"id","type","url","permissions"}`, omitting
`url` when the server returned none. `copy-link --json` fails (exit 1)
when the server returned no public link.

Link and `copy-link` options:

| Option | Effect |
| --- | --- |
| `--password P` | protect the link with password P. |
| `--expire YYYY-MM-DD` | expire the link on that date. |
| `--note TEXT` | attach a note. |
| `--permissions LETTERS` | permission letters or a numeric mask. |
| `--label LABEL` | set a link label. |
| `--download 0\|1` | `0` hides the download button, `1` allows it. On Nextcloud 30+ this is the `attributes` array element `{"scope":"permissions","key":"download","value":false}`; older servers (or an unknown version) keep the legacy `{"download":0}` object. |
| `--file-drop` | make the link upload-only; unless `--permissions` overrides it, this sets the create permission (mask `4`). |
| `--file-request` | mark the link as a file request (`{"scope":"fileRequest","key":"enabled","value":true}`), combined with the download attribute when both are given. |
| `--json` | print the created/reused share as JSON. |

`user`, `group`, `guest`, `circle`, `talk`, `deck`, and `remote` options:

| Option | Effect |
| --- | --- |
| `--permissions LETTERS` | permission letters or a numeric mask. |
| `--note TEXT` | attach a note. |
| `--send-mail` | ask the server to email the share recipient. |

`email` options add link-style password/expiry:

| Option | Effect |
| --- | --- |
| `--permissions LETTERS` | permission letters or a numeric mask. |
| `--note TEXT` | attach a note. |
| `--password P` | protect the share with password P. |
| `--expire YYYY-MM-DD` | expire the share on that date. |
| `--send-password-by-talk` | share the password through Talk (requires `--password`). |
| `--send-mail` | ask the server to email the share recipient. |

`update` change options (at least one required):

```
sciebo share update ID [--password P | --remove-password]
                       [--expire DATE | --remove-expire]
                       [--note TEXT | --remove-note]
                       [--permissions LETTERS]
                       [--label LABEL] [--download 0|1] [--send-mail]
```

`pending` options:

| Option | Effect |
| --- | --- |
| `--local` | only local pending shares. Mutually exclusive with `--remote`. |
| `--remote` | only federated pending shares. Mutually exclusive with `--local`. |
| `--json` | print `{"pending":[{"kind","id","type","owner","target","created"}]}` instead of the `Kind ID Type Owner Created Target` table. |

`pending` fetches both lists by default (local first); a list that
cannot be read is warned about, and the command exits 1 only when
neither list could be read. `accept` and `decline` resolve an id against
the local list first and the federated list second; `--remote` forces the
federated list. An id that is not pending fails with exit 1. With
`--all`, every pending share in the selected list(s) is answered as
`accepted <kind> share <id>` / `declined <kind> share <id>`, or `no
pending shares` when none matched; `decline --all` confirms first and
needs `--yes` in a non-interactive run.

Share type labels: `user`, `group`, `link`, `email`, `remote`, `circle`,
`talk`, `deck`, `guest`; unknown types print their numeric value.

```sh
sciebo share link papers --expire 2026-12-31
sciebo share link uploads --file-drop
sciebo share link requests --file-request --download 0
sciebo share email papers alice@example.com --send-password-by-talk --password secret
sciebo share guest papers guest@example.com --send-mail
sciebo share search alice
sciebo share user papers alice@your-university.de
sciebo share list papers
sciebo share list --reshares --json
sciebo share remote-list --json
sciebo share incoming --json
sciebo share pending
sciebo share pending --remote --json
sciebo share accept 42
sciebo share accept --all
sciebo share decline 42 --yes
sciebo share decline --all --remote --yes
sciebo share send-email 42
sciebo share remove 42 --yes
sciebo share copy-link papers
sciebo share copy-internal papers
```

### notifications

```
sciebo notifications [options]
```

List the Nextcloud notifications of the configured remote, newest first.
`--app`/`--type` are allowlists matched case-sensitively and exactly;
multiple values are comma/space/colon separated. When those options are
absent the `NOTIFY_APPS`/`NOTIFY_TYPES` settings apply as defaults (empty
= all). `--limit` and the allowlists apply before `--notify` sends
anything, so a notified run is bounded by them as well.

| Option | Effect |
| --- | --- |
| `--limit N` | print and notify at most N notifications after filtering (non-negative integer). |
| `--app LIST` | only notifications from these apps (overrides `NOTIFY_APPS`). |
| `--type LIST` | only notifications with these object types (overrides `NOTIFY_TYPES`). |
| `--unseen` | only notifications not yet recorded in `state/notifications-seen`; listing with `--unseen` does not write the cache. |
| `--action ID LABEL` | after the listing, run the action labelled LABEL (case-insensitive) on notification ID; the action's `POST`/`DELETE`/`PUT` method is used. Cannot be combined with `--delete`/`--delete-all`. |
| `--delete ID` | delete one notification after listing. No prompt. Mutually exclusive with `--delete-all`. |
| `--delete-all` | delete every notification; asks first and needs `--yes` when not interactive. Mutually exclusive with `--delete`. |
| `--notify` | send a desktop notification for each not-yet-seen notification and remember its id in `state/notifications-seen`. Best effort; never changes the exit status. |
| `--json` | print the filtered notifications as one document (`{"notifications":[...]}` with id, app, object_type, subject, message, link, datetime, and a `seen` flag). Cannot be combined with `--watch`. |
| `--watch [N]` | poll every N seconds (default `NOTIFY_WATCH_INTERVAL`) and print/record new notifications until interrupted (exit 130/143). Cannot be combined with `--delete`/`--delete-all`/`--action`/`--json`; a watch run always treats the seen cache as the "new" boundary. |
| `--quiet` | print no notification rows. |
| `--yes` | skip the `--delete-all` confirmation. |

```sh
sciebo notifications --unseen --notify
sciebo notifications --app files --type file --limit 5
sciebo notifications --action 72345 "Dismiss"
sciebo notifications --watch 30
sciebo notifications --json
```

### activity

```
sciebo activity [options]
```

Show the Nextcloud activity stream, newest first. Rows contain datetime,
app, subject, and link.

| Option | Effect |
| --- | --- |
| `--limit N` | print and notify at most N activities (default 20, capped at 100). |
| `--since DURATION` | only activities newer than DURATION (`90m`, `24h`, `7d`; a bare number means minutes). Because the API's `since` is an activity id, the command walks the cursor backwards page by page (50 entries each) until a page crosses the cutoff, the stream ends, or 10 pages were fetched; hitting the cap warns that older entries were not fetched. `--notify` is bounded by the same window, and an unparsable timestamp is kept. |
| `--notify` | send a desktop notification for each not-yet-seen activity and remember its id in `state/activity-seen`. Best effort; never changes the exit status. |
| `--quiet` | print no activity rows. |

### presence

```
sciebo presence [show]
sciebo presence set online|away|dnd|offline [options]
sciebo presence clear
```

Show (the default), set, or clear your Nextcloud user status. `show`
prints the status type, custom message, emoji, and when the message
expires.

| Option (with `set`) | Effect |
| --- | --- |
| `--message TEXT` | publish a custom message. |
| `--emoji EMOJI` | publish a status emoji (`statusIcon`). |
| `--clear-after DUR` | expire the message after `<N>[smhd]` (bare N means minutes); `--clear-after 0` clears the message. A duration > 0 requires `--message` or `--emoji`. |

`presence clear` deletes the custom message; the status type is changed
with `presence set`. Options are only valid with `set`.

```sh
sciebo presence show
sciebo presence set dnd --message "Deep work" --emoji "<emoji>" --clear-after 2h
sciebo presence clear
```

### lock

```
sciebo lock SUB
```

Manually lock a remote file below the remote base with a WebDAV `LOCK`
carrying the Nextcloud `X-User-Lock: 1` header. The lock token is
recorded locally (mode 600, `state/remote-locks/<name>.state`) so
`unlock` can release it. A missing path, or one already locked (HTTP
423), fails with exit 1.

### unlock

```
sciebo unlock SUB
sciebo unlock --all [--yes]
```

Release a manual lock with `UNLOCK`. The token comes from the record
written by `sciebo lock`; without a record it is looked up on the server
with a `PROPFIND` for `nc:lock-token`. Fails when the path is not locked.

With `--all`, every lock recorded under `state/remote-locks/` is released
and the records whose `UNLOCK` succeeded are removed, printing `unlocked
PATH` per lock. It confirms first and needs `--yes` in a non-interactive
run (exit 2 otherwise); `--all` takes no `SUB`. A record whose `UNLOCK`
fails is warned about and kept for a later retry.

### locks

```
sciebo locks [--prune | --unlock-all] [--yes]
```

List the locks recorded by `sciebo lock` as `NAME`, `PATH`, and `TOKEN`
(NAME is the sanitized path). `--prune` checks every recorded path over
PROPFIND and forgets records whose lock-token is gone, printing `pruned
NAME`. Unreadable/malformed records are reported and skipped.

`--unlock-all` is the same bulk release as `unlock --all`: it asks for
confirmation (`--yes` in a non-interactive run), releases every recorded
lock with `UNLOCK`, and drops the records that succeeded. `--prune` and
`--unlock-all` are mutually exclusive.

Note: this lock is a courtesy against accidental concurrent edits, not
access control — it does not stop another local user on the same machine
from bypassing it. See [SECURITY.md](../SECURITY.md) for the full scope.
<!-- src: commands.md#locks; cross-referencing SECURITY.md's "not an access control against other local users" caveat -->

### quota

```
sciebo quota [--json]
```

Print the quota usage reported by `rclone about <remote>`. `--json`
prints rclone's JSON document instead of the plain table. Read-only;
failures carry rclone's own message.

### conflicts

```
sciebo conflicts [options]
sciebo conflicts --resolve MODE [options]
```

Find local conflict files below every configured source. The scan is
read-only: nothing is uploaded, deleted, or written. Two kinds are
listed:

- `copy` — conflict copies matching `CONFLICT_PATTERN` (default
  `conflicted copy`), as created by rclone bisync and the desktop client.
- `case` — files quarantined by `CASE_CLASH_POLICY=rename` and renamed to
  `<name> (case conflict)<ext>`.

The default scan is purely local and contacts no remote. With `--remote`
the scan is an opt-in online variant: it lists each source's remote
subtree with `rclone lsf -R` and reports names that differ only by ASCII
case as kind `case`. It is read-only and needs a reachable remote; it
never renames anything server-side. `CASE_CLASH_REMOTE_SCAN=1` enables the
same scan during `sync`.

See also the [conflict-copy caveat](parity.md#conflict-copy-caveat): a
fresh conflict copy made by a bisync run can still reach the other side in
that same run.
<!-- src: commands.md#conflicts -->

| Option | Effect |
| --- | --- |
| `--resolve MODE` | resolve conflict files instead of listing them (see below). Without `--apply` it is a dry run that prints one line per planned action and changes nothing. Cannot be combined with `--remote`. |
| `--only NAME` | scan or resolve only the source with this sanitized name. |
| `--kind KIND` | scan or resolve only one conflict kind: `copy`, `case`, or `all` (default `all`). With `--remote` only `case` and `all` are accepted. |
| `--remote` | list remote case clashes (read-only) instead of local files. Cannot be combined with `--resolve`, `--apply`, `--yes`, or `--open`; `--only` and `--kind` still apply. |
| `--open` | list, then open each containing directory of a match once with the platform opener (`open` on macOS, `xdg-open` on Linux). Read-only and unconfirmed; exits 0 (opener failures aside) and prints `no conflicts` when there is nothing to open. Cannot be combined with `--resolve`, `--apply`, `--yes`, or `--json`; `--only` and `--kind` still apply. |
| `--apply` | carry out the planned actions; requires `--resolve`. Destructive: files are overwritten, renamed, or deleted. A terminal run asks once; a non-interactive run needs `--yes`. |
| `--yes` | skip the `--apply` confirmation; requires `--resolve`. |
| `--json` | print the result as JSON: the resolve result (requires `--resolve`) or the remote clash list (with `--remote`). Resolve items carry a `kind` field (`copy` or `case`); remote items carry `source`, `kind`, `first`, and `second`. |
| `--quiet` | print nothing; exit 1 when conflicts exist (except with `--open`, which exits 0). |

`--resolve MODE`:

| Mode | Action |
| --- | --- |
| `keep-local` | move the copy over the original (overwrite). |
| `keep-remote` | delete the copy, keeping the original. |
| `keep-newest` | keep the newer of the two files. |
| `keep-oldest` | keep the older of the two files. |
| `keep-both` | rename the copy to `<name> (local copy)<ext>` (adds `-2`, `-3`, ... when taken). |

Planned actions print as `<source> <path> -> <action> <target>`; an
applied run ends with `resolved N conflict copy(ies)`, a dry run with `N
to resolve (dry run)`. The JSON document is `{total, resolved, skipped,
items:[{source, path, kind, action, target}]}`. Listing rows show source,
relative path, modification time, size, and kind. A missing local
directory is warned about and skipped, never an error.

### retry

```
sciebo retry [NAME [PATH]] [--list] [--all]
```

Clear failure-blacklist entries (the retry blacklist: paths this tool has
temporarily stopped retrying after repeated failures) so the next sync
tries those paths again. A path that errored `BLACKLIST_MAX_FAILS` times
is excluded from later runs until cleared.

| Form | Behavior |
| --- | --- |
| `retry --list` | print tab-separated `<name>`, `<count>`, `<path>`, `<error>` rows and exit. Records written in backoff mode (`BLACKLIST_MODE`) add a fifth `<next>` retry-time column. |
| `retry --all` | clear every source's records. |
| `retry NAME` | clear every blacklisted path of that source. An unknown name exits 1. |
| `retry NAME PATH` | clear a single path. Exits 1 when no such entry exists. |

`--list` and `--all` are mutually exclusive and cannot be combined with a
source name. Read-only until something is cleared; no network, no run
lock.

### file

```
sciebo file <subcommand> [options]
```

Show details for a remote path below `<RCLONE_REMOTE>:<REMOTE_BASE>/`.

| Subcommand | Behavior |
| --- | --- |
| `info SUB [--json]` | show WebDAV metadata for SUB. |
| `activity SUB [--limit N] [--json]` | show the activity stream of SUB. |
| `shares SUB [--json]` | list the shares of SUB (same as `share list SUB`; `--json` forwards to `share list SUB --json`). |

| Option | Effect |
| --- | --- |
| `--json` | `info`/`activity`/`shares`: print the result as JSON. |
| `--limit N` | `activity`: print at most N entries (default `FILE_ACTIVITY_LIMIT`). |

```sh
sciebo file info notes/todo.md
sciebo file activity notes --limit 5 --json
sciebo file shares notes
sciebo file shares notes --json
```

### search

```
sciebo search TERM [--limit N] [--json] [--open]
```

Search files on the server with Nextcloud's unified search. TERM is a
single argument (quote it to search for spaces). Results are printed as
`TITLE<TAB>SUBLINE<TAB>RESOURCEURL`, or `no matches`.

| Option | Effect |
| --- | --- |
| `--limit N` | ask the server for at most N results (default `SEARCH_LIMIT`). |
| `--json` | print the results as JSON. |
| `--open` | open the first result with the platform opener (`open` on macOS, `xdg-open` on Linux); refused unless the URL is http(s) and shares scheme and host with the configured server base; no effect when nothing matched. |

```sh
sciebo search "quarterly report"
sciebo search budget --limit 5 --json
sciebo search budget --open
```

### recent

```
sciebo recent [--since DUR] [--limit N] [--json]
```

List recently modified files below `<RCLONE_REMOTE>:<REMOTE_BASE>/`
through rclone, newest first, as `MODIFIED<TAB>SIZE<TAB>PATH`.

| Option | Effect |
| --- | --- |
| `--since DURATION` | only files modified within DURATION (`90m`, `24h`, `7d`; a bare number means minutes). |
| `--limit N` | print at most N files (default `RECENT_LIMIT`). |
| `--json` | print the files as JSON. |

```sh
sciebo recent --since 24h
sciebo recent --limit 10 --json
```

### comments

```
sciebo comments SUB [list] [--json] [--limit N]
       sciebo comments SUB add MESSAGE
       sciebo comments SUB delete ID [--yes]
```

List, add, or delete comments on the remote path SUB below
`<RCLONE_REMOTE>:<REMOTE_BASE>/` (Nextcloud comments app). `list` is the
default and prints the comment id, actor, creation time, verb, and
message.

| Subcommand | Behavior |
| --- | --- |
| `SUB [list]` | list the comments of SUB (default). |
| `SUB add MESSAGE` | post a new comment; prints `added comment <id>`. |
| `SUB delete ID` | delete one comment (asks first; needs `--yes` when not running interactively). |

| Option | Effect |
| --- | --- |
| `--limit N` | `list`: print at most N comments (default: `COMMENTS_LIMIT`, 50). |
| `--json` | `list`: print the listing as JSON. `add` and `delete` reject it. |
| `--yes` | skip the `delete` confirmation; only valid with `delete`. |

```sh
sciebo comments notes/todo.md
sciebo comments notes/todo.md add "needs review"
sciebo comments notes/todo.md delete 42 --yes
```

### favorites

```
sciebo favorites [list] [--json]
       sciebo favorites add SUB
       sciebo favorites remove SUB
```

List the server-side favorites of the configured remote, or mark SUB (a
remote path below `<RCLONE_REMOTE>:<REMOTE_BASE>/`) as a favorite. `list`
is the default and prints the path, size, and last-modified time. `add`
and `remove` change the server's `oc:favorite` flag without a prompt.

| Subcommand | Behavior |
| --- | --- |
| `[list]` | list favorites (default). |
| `add SUB` | mark SUB as a favorite. |
| `remove SUB` | clear the favorite flag of SUB. |

`--json` prints the listing as JSON and is rejected by `add`/`remove`.

```sh
sciebo favorites
sciebo favorites add notes/todo.md
sciebo favorites remove notes/todo.md
```

### tags

```
sciebo tags list [--json]
       sciebo tags create NAME
       sciebo tags assign SUB ID[,ID...]
       sciebo tags clear SUB
```

Manage Nextcloud system tags. `list` prints the id, display name, and the
user-visible/user-assignable flags. `assign` replaces the tags of SUB (a
remote path below `<RCLONE_REMOTE>:<REMOTE_BASE>/`) with a comma-separated
id list; `clear` removes all of them.

| Subcommand | Behavior |
| --- | --- |
| `list` | list the system tags (default). |
| `create NAME` | create a user-visible, user-assignable tag. |
| `assign SUB IDS` | replace the tags of SUB with IDS (e.g. `3,4`). |
| `clear SUB` | remove every tag from SUB. |

`--json` prints the listing as JSON and is rejected by the other
subcommands.

```sh
sciebo tags list
sciebo tags create "to review"
sciebo tags assign notes/todo.md 3,4
sciebo tags clear notes/todo.md
```

### server

```
sciebo server <subcommand> [options]
```

Inspect the configured Nextcloud server (URL, user, capabilities) or
check that the remote answers.

| Subcommand | Behavior |
| --- | --- |
| `info [--json]` | server URL, user, and capability facts (version, chunking, trashbin, checksums). Reads the capabilities cache when fresh. |
| `capabilities [--raw] [--json]` | parsed capabilities summary; `--raw` prints the cached raw OCS response instead (probing once when no raw cache exists, and failing when none can be produced), `--json` prints the same facts as a JSON document. `--raw` and `--json` are mutually exclusive. |
| `status` | reachability check with `rclone lsd` (`PASS`/`FAIL`); exits 1 on FAIL. |

| Option | Effect |
| --- | --- |
| `--json` | `info`/`capabilities`: print a JSON document (rejected by `status`). |
| `--raw` | `capabilities`: print the cached raw OCS response (rejected by `info` and `status`). |

```sh
sciebo server info
sciebo server capabilities
sciebo server capabilities --raw
sciebo server status
```

### announcements

```
sciebo announcements [--limit N] [--no-dismiss] [--json]
```

List the Nextcloud announcements of the configured server, newest first.
The announcementcenter app must be installed and enabled; when it is
absent or disabled the command prints `announcements app not available`
and exits 0. `--limit` (default 20, max 100) caps the list, `--no-dismiss`
is accepted for compatibility, and `--json` prints an
`available`/`announcements` document.

```sh
sciebo announcements
sciebo announcements --limit 5 --json
```

### preview

```
sciebo preview SUB [--output FILE] [--size N]
```

Download a preview image of the remote file `SUB` below the configured
remote base. `--output` writes to `FILE` (default `DEFAULT_PREVIEW_FILE`,
`./preview`; `-` writes to stdout) and `--size` sets the edge size in
pixels (default `PREVIEW_SIZE`, 256). Files Nextcloud cannot render fail
with `previews are not available for this file`.

```sh
sciebo preview Photos/holiday.jpg --output /tmp/holiday.png --size 1024
sciebo preview Notes/todo.md --output -
```

### download

```
sciebo download SUB [DEST] [--dry-run] [--force] [--resume] [--quiet] [--json] [--progress]
```

Download a remote file or directory below `<RCLONE_REMOTE>:<REMOTE_BASE>/`.
A single file is fetched over WebDAV to `DEST` (default: its basename
under the current directory, or below `DOWNLOAD_DIR` when set). A
destination that already matches the remote size is left alone unless
`--force` is given; `--resume` (alias `--continue`) continues a partial
destination with a range request, and a hard failure removes the partial
file. A destination that is a symlink is refused, and the WebDAV body is
written to a same-directory temp file and moved into place only on
success, so a failed request never truncates an existing `DEST`. A
directory (or a `DEST` ending in `/`) is copied with rclone using the
same filter layering as `hydrate`.

| Option | Effect |
| --- | --- |
| `--dry-run` | report what would be transferred; change nothing. |
| `--force` | download even when the destination already matches the remote size. |
| `--resume`, `--continue` | continue a partial destination with a range request. |
| `--quiet` | do not print the success line. |
| `--json` | print a structured summary. |
| `--progress` | show rclone's transfer progress (`-P`); rclone transfers only, terminal only, and suppressed by `--quiet` and `--json`. |

```sh
sciebo download Notes/plan.md
sciebo download Photos --resume
sciebo download archive/ --dry-run
```

## Other

### update

```
sciebo update [--check] [--json]
```

Update the local checkout from its git upstream. `--check` fetches the
upstream and reports current/ahead/behind/diverged without changing the
working tree; a source tarball or a branch without an upstream is
reported and exits 0. Without `--check` the checkout is updated with `git
pull --ff-only` and the follow-up command is printed. The user's
configuration is never modified.

```sh
sciebo update --check
sciebo update
```

## Help

```
sciebo help [command]
sciebo <command> --help
```

Print the main usage or one command's usage. Unknown commands exit 2 and
print the main usage to stderr.

## Direction semantics

- `sync` mirrors local → sciebo (one-way upload). When you delete
  something locally, the next run sends it to the Nextcloud trash (sciebo
  keeps deleted files for at least 7 days), so no `--backup-dir` clutter
  is needed. A `.nosync` marker (a file that tells this tool to skip its
  directory) works here. `BACKUP_DIR` is not used for `sync`.
- `pull` mirrors sciebo → local (one-way download). Local deletions made
  by a run are permanent; use it with care. A `.nosync` marker works here
  too. With `BACKUP_DIR` set, overwritten and deleted local files are
  preserved below `BACKUP_DIR/<name>` (rclone `--backup-dir`).
- `bisync` is two-way sync. Initialize each source once with `sciebo sync
  --resync --apply`, and review a dry run with `--resync` first: a resync
  can copy or delete files in BOTH directions. Resyncs run with
  `BISYNC_RESYNC_MODE` (`newer` by default), so a first sync honors
  `BISYNC_CONFLICT_RESOLVE` instead of silently preferring the local
  side; incremental runs never pass `--resync-mode`. When both sides
  changed the same file, the loser is copied to `<file>.<suffix><N>`,
  following `BISYNC_CONFLICT_LOSER` and `BISYNC_CONFLICT_SUFFIX`. In the
  run that creates a conflict copy, the fresh file can still reach the
  other side; `CONFLICT_UPLOAD=0` (the default) excludes existing copies
  from every later run, so `sync` and `pull` never upload them and they
  stay on the machine that created them. Set `CONFLICT_UPLOAD=1` to sync
  them again. `sciebo sync` prints a `conflicts:` line and counts
  conflicts in the summary; see the caveat in
  [docs/parity.md](parity.md#conflict-copy-caveat). When you delete a
  bisync source, remove its `state/bisync/<name>` directory as well.
  rclone bisync does not support `--exclude-if-present`, so `.nosync`
  markers are ignored by `bisync` entries.

Dry runs change nothing on either side and print a `plan:` line per
source with the number of copies, deletes, and other skipped actions,
plus up to three example paths. A `pull` entry without a local directory
yet, or a `bisync` entry without a remote directory yet, is reported as
skipped ("first apply will create it"); the first apply creates it. The
same applies to a `bisync` entry in `sync --resync` mode.

Source and filter formats, profiles, and every setting are documented in
[docs/settings.md](settings.md).

## Limitations

This section collects the guardrails and scope limits that are already
stated next to the commands above, in one place for a quick check before
you script against them.

- `check --apply` still runs as a dry run; the delete guard and every
  other apply-only behavior never triggers under `check`, whatever
  options you pass it. <!-- src: commands.md#check -->
- `verify` never transfers, deletes, takes the run lock, or writes logs —
  it is read-only in every mode, including `--download`.
  <!-- src: commands.md#verify -->
- The lock taken by `sciebo lock`/`unlock`/`locks` is a courtesy against
  accidental concurrent edits between runs of this tool (and the desktop
  client), not access control: it does not stop another local user on
  the same machine from reading or changing the file. See
  [SECURITY.md](../SECURITY.md). <!-- src: commands.md#locks -->
- `mount`/`umount` need no macFUSE on macOS, but macOS NFS mounts and
  unmounts usually need `--sudo`. <!-- src: commands.md#mount -->
- `nextcloudcmd` (this tool's subcommand) and `discover`/`hydrate`/`edit`
  read the sync list, but the wizard commands under `folders` never
  touch the manual sync list files — the two configuration paths stay
  separate by design. <!-- src: commands.md#folders -->
- `DOCTOR_REMOTE_SCAN_LIMIT`, used by `doctor`'s `e2ee folders` and `big
  folders` checks, has no documented default in
  [docs/settings.md](settings.md); this is a documentation gap in that
  file, not a claim this reference makes up a number for.
  <!-- src: commands.md#doctor -->
- This reference documents behavior for commands as implemented; no
  Nextcloud server version is asserted to have been tested against as a
  whole, beyond the Nextcloud 30+ share-download attribute noted in
  [`share`](#share).

## Glossary

Plain-language definitions for terms used throughout this reference. See
[docs/settings.md](settings.md) for the full settings reference and
[docs/parity.md](parity.md) for how these map to Nextcloud desktop-client
features.

| Term | Meaning |
| --- | --- |
| sciebo | The Hochschulcloud.NRW cloud storage service for NRW universities; this project is an unofficial client for it. |
| `sciebo` (command) | The command this tool installs; named after the service. |
| Nextcloud | The open-source server software the sciebo service and other institutions run; this tool talks to any Nextcloud server. |
| rclone | The third-party file-transfer engine this tool is built on; this tool configures and runs it rather than talking to the server directly for transfers. |
| the connection to your account (remote) | A named rclone configuration entry (default name `sciebo`, the `RCLONE_REMOTE` setting) that holds the server URL and how to authenticate. |
| the network protocol this tool uses to talk to Nextcloud (WebDAV) | The file-access protocol rclone and this tool's direct HTTP calls use against the server. |
| app password (a password just for this tool) | A Nextcloud-issued password scoped to one application/device, used instead of the account's main password. |
| the browser sign-in flow (Login Flow v2) | Nextcloud's browser-based authentication handshake that `setup --login` drives; produces an app password without the user typing one in. |
| the system's password manager (keychain) | The OS-level secret store (macOS Keychain, Linux secret-tool/pass) this tool prefers for the app password over the rclone config file. |
| the sync list (manifest) | The set of configured folder pairs (from `sources.conf`, `folders.conf`, `sources.generated.conf`) that `sync`/`check`/etc. act on. |
| a configured folder pair (source / entry) | One line in the sync list: a local folder, a remote folder, and a direction. |
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
| account profile | An independent, named account setup (its own remote, sync list, filters, and state), used to manage more than one Nextcloud account. |
| a filter file | A plain-text rule file (rclone syntax) that excludes or includes paths from a sync. |
| a safety policy | A named setting that chooses how this tool reacts to a risky situation: allow it, warn, ask first, or skip/exclude it. |
| how well-tested a command is (tier: core / extra) | `core` commands are covered by tests against a real Nextcloud server; `extra` commands are newer and tested only against a local stand-in. |
| this tool's local record-keeping folder (state directory) | Where this tool stores run history, locks, caches, and other bookkeeping — separate from your synced files. |
| the single-run lock (run lock) | A safeguard that stops two sync/cleanup runs from overlapping on the same machine. |
| a metered (pay-per-use or capped) network | A connection this tool can detect and treat more cautiously, e.g. a mobile hotspot. |
| the retry blacklist | The list of paths this tool has temporarily stopped retrying after repeated failures, until `sciebo retry` clears them. |
| live sync (watch) | An optional, foreground command that syncs a folder as soon as it changes; not a background service. |
| scheduled runs (schedule) | An optional, installable background job (via the OS's own scheduler) that runs sync periodically; opt-in, not automatic. |
| the Nextcloud desktop client's `nextcloudcmd` tool | The separate, third-party command-line tool that ships with Nextcloud's desktop client packages. |
| this tool's nextcloudcmd-compatible command (`sciebo nextcloudcmd`) | This project's own command, built to accept the external tool's option names for easy migration; not the same program. |
