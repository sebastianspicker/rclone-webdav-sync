# Known issues in the alpha

Thank you for testing. This page lists what does not work yet, or works in
a surprising way, and how to get around it. Please read the first section
before your first sync.

## Before your first sync

- **`sciebo check` reports FAIL for a new two-way folder.** A two-way
  (`bisync`) folder must be initialized once before `check` can plan it.
  - Run `sciebo sync --resync --apply` first; after that `check` works
    normally.
  - The folder wizard's own dry run already shows a preview of this first
    run.
- **A download-only (`pull`) folder makes the local folder an exact copy of
  the server.** Files that exist only on your computer are deleted on the
  first sync, and nothing asks first while fewer than 100 files are
  affected. An empty server folder is never mirrored over a non-empty local
  folder without `sciebo sync --yes`.
  - Point a `pull` folder at an empty or new local folder.
  - Or set `MOVE_TO_TRASH=1` with `sciebo config edit`; deleted files are
    then moved to a local trash instead of being removed.
- **Large deletions are stopped on purpose.**
  - An upload or download folder stops after 100 files have been deleted.
    Those 100 files are already deleted (on the server they usually go to
    the trash bin).
  - An upload folder that is empty on your computer is not mirrored over a
    non-empty server folder (for example an unmounted disk).
  - A two-way folder stops when more than half of its files would be
    deleted on either side.
  - On a terminal you are asked once. In scheduled runs, the folder is
    skipped with a message.
  - Run `sciebo sync --yes` once if the deletions are intended.

## Installation

- **`sudo make install` is refused.** Each user installs their own copy
  with `make install` (into `~/.local`) or
  `make install PREFIX="$HOME/somewhere"`. A shared, system-wide
  installation is not supported yet.
- **Linux has had less testing than macOS.** The background agents
  (`schedule install` with systemd), the keyring backends (`secret-tool`,
  `pass`) and the cron helper scripts are expected to work but have not been
  run on a Linux machine yet. Reports from Linux testers are especially
  welcome.

## Accounts and profiles

- **Profiles created with an older version** may still share the default
  account's connection.
  - `setup`, `logout` and `provision` now refuse to run for such a profile,
    and the message names the one line to add to the profile's settings.
  - Add the line, then run `sciebo --profile NAME setup --login` again.
- **Folder filters created by an older version of the wizard** exclude
  same-named folders at every depth, not just at the top.
  - New and edited pairs are correct.
  - To fix an old pair, run `sciebo folders edit NAME --exclude ...` again
    with its excludes.
- **Importing from the desktop client into a profile that already has
  folders** keeps that profile's remote base. The imported folders then
  appear below it rather than at the top of your account; a warning says
  so. Import into a new profile instead.
- **Servers where your login name differs from your internal user name**
  (some single-sign-on setups): `setup` may build the server address with
  the login name. If `sciebo doctor` cannot reach your files, run
  `rclone config`, edit the `sciebo` remote, and set its `url` to the
  WebDAV address shown in the web interface (*Files → Settings*); keep the
  user and password as they are.

## Server features

The trash bin, file versions, sharing, downloads and conflict handling
commands have been checked only against simulated server responses so far.
Please report anything that looks wrong, especially:

- `sciebo trash` listings and `trash restore ID`;
- `sciebo share copy-link` with `--password` or `--expire` (each such
  call creates a new link);
- `sciebo download --resume` on large files;
- `sciebo conflicts --resolve`.

## Smaller rough edges

- Some confirmation prompts show `[y/N]` twice.
- `sciebo setup` can still wait for keyboard input when you pass
  `--non-interactive`; provide all values up front, or use
  `sciebo setup --login`.
- Environment variables with generic names, such as `TIMEOUT`,
  `LOG_LEVEL` or `PROXY`, override sciebo's settings. If a sync suddenly
  fails with an rclone error about a flag value, check
  `sciebo config list`; it shows where each value comes from.
- `sciebo trash rm` and `sciebo share remove` do not ask for confirmation
  when run from a script without a terminal.
- `sciebo quota` and `sciebo recent` show a raw rclone error instead of
  "run sciebo setup" when no account is configured.
- Proxy passwords given with a `socks5://` proxy are visible in the process
  list. For an authenticated proxy, prefer an `https://` proxy or the
  `HTTPS_PROXY` environment variable.

## Reporting a bug

Please include:

1. What you ran, what you expected, and what happened, with the exact error
   message.
2. `sciebo --version` and your operating system.
3. The output of `sciebo doctor --offline` and `sciebo status --json`.
4. A support archive. `sciebo support` writes a `.tar.gz` with the
   diagnostics and recent logs, with passwords and tokens masked. Open it
   and look it over before you attach it: the masking works on patterns
   and cannot catch every secret.
5. For a sync problem, the log of that run. `sciebo logs` lists the logs,
   and `sciebo logs tail NAME` shows the latest one for a folder.

Never post your app password, the contents of `.env`, or your rclone
configuration file. If you think you found a security problem, please
follow the instructions in SECURITY.md instead of opening a public issue.
