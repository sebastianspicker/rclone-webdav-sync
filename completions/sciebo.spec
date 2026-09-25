# completions/sciebo.spec - declarative completion spec.
#
# scripts/gen-completions.sh reads this file and writes
# completions/sciebo.bash, completions/_sciebo (zsh), and
# completions/sciebo.fish. Edit this file, then run `make gen`
# (or `scripts/gen-completions.sh`) to regenerate all three;
# `scripts/gen-completions.sh --check` reports drift without writing.
#
# Fields are pipe-separated ("|"); no field may itself contain a literal
# "|" (a value list inside a field, e.g. an ENUM action, is comma-
# separated instead). Blank lines and lines starting with "#" are ignored.
# Every other line starts with one of five row kinds:
#
# GLOBAL|<names>|<placeholder>|<kind>|<action>|<description>
#   A global option (mirrors bin/sciebo's _SCIEBO_GLOBAL_SPECS plus
#   -h/--help), available with every command and subcommand. <names> is a
#   comma-separated list of flag spellings (long and/or short); the first
#   is the primary spelling. <placeholder>/<kind>/<action> follow OPT's
#   fields below ("flag" or "value"; no global option is optional-value/
#   repeatable/two-arg today).
#
# COMMAND|<name>|<tier>|<description>
#   One row per top-level command, in the order bin/sciebo's COMMANDS
#   string lists them, plus a trailing `help` row (handled specially by
#   bin/sciebo, so it is not itself in COMMANDS). <tier> is "core" or
#   "extra"; a later phase will use it to split completion output, so it
#   is carried through unused for now (always "core" today).
#
# SUB|<command>|<name>|<description>
#   One row per subcommand of a command that dispatches on its first
#   positional word (folders, share, trash, schedule, account, presence,
#   config, filters, file, tags, server, logs). `comments` and
#   `favorites` take a fixed positional word too, but it is a plain enum
#   value, not a dispatch word with its own option set, so they are
#   declared with a POS ENUM action instead (see below).
#
# OPT|<command>|<sub>|<names>|<placeholder>|<kind>|<action>|<description>
#   One option. <sub> is "-" for a command with no subcommands, or the
#   subcommand it applies to; `logs` also has one <sub>="-" row for the
#   pre-dispatch `--json` it accepts before a subcommand word is typed
#   (matching its "with no subcommand, behaves like `logs list`" default).
#   <names> is a comma-separated flag spelling list (e.g. "--resume,
#   --continue" or "--user,-u"); the first is primary. <placeholder> is
#   the value placeholder shown in usage text (e.g. "N", "path"); empty
#   for a flag. <kind> is one of:
#     flag             takes no value
#     value            takes exactly one value
#     optional-value   takes zero or one value (the value is omitted by
#                      typing the next option or nothing; the command's
#                      own default then applies)
#     repeatable       a value option that may be repeated
#     two-arg          takes exactly two plain values (only --action ID
#                      LABEL); completion treats it like "value" (it
#                      consumes one following word) and never completes
#                      either value, matching the previous behavior
#   <action> is NONE, or one of the value actions below.
#
# POS|<command>|<sub>|<index>|<label>|<action>
#   One positional argument. <index> is a 1-based position, "?N" for an
#   optional position N, or "*" for a repeatable catch-all (any number of
#   remaining args, e.g. `trash restore ID...`). <label> is descriptive
#   text (zsh shows it; bash/fish only use <action>).
#
# Value/positional actions:
#   NONE        no completion beyond the shell's default
#   FILES       local file completion
#   DIRS        local directory completion
#   PROFILES    profile names under config/profiles/ plus "default"
#   COMMANDS    the COMMAND list (used by `help`'s positional)
#   ENUM:a,b,c  one of the given literal, comma-separated words

# --- global options ---------------------------------------------------
GLOBAL|-h,--help||flag|NONE|show help
GLOBAL|--profile|profile|value|PROFILES|select a profile
GLOBAL|--trust||flag|NONE|accept invalid TLS certificates
GLOBAL|--non-interactive||flag|NONE|never prompt; fail or skip instead
GLOBAL|--debug||flag|NONE|verbose rclone/HTTP output
GLOBAL|--log-file|file|value|FILES|write the rclone log here
GLOBAL|--confdir|directory|value|DIRS|configuration and state directory
GLOBAL|--log-dir|directory|value|DIRS|write run logs here
GLOBAL|--log-expire|hours|value|NONE|delete logs older than this many hours
GLOBAL|--version,-V||flag|NONE|show the version

# --- commands (bin/sciebo COMMANDS order, plus help) -------------------
COMMAND|setup|core|create/update the sciebo rclone remote
COMMAND|doctor|core|preflight checks (PASS/WARN/FAIL report)
COMMAND|discover|core|find git repositories under roots.conf
COMMAND|list|core|list configured sources
COMMAND|check|core|dry run of all sources
COMMAND|sync|core|apply sync/pull/bisync for all sources
COMMAND|verify|core|check that sources match their destinations
COMMAND|status|core|last run per source, plus the pause state
COMMAND|pause|core|skip sync/check runs until resumed
COMMAND|resume|core|clear the pause marker
COMMAND|folders|core|choose/add/list/edit/remove folder pairs
COMMAND|mount|core|mount the remote on demand (nfsmount)
COMMAND|umount|core|unmount a recorded mount
COMMAND|mounts|core|show recorded mounts
COMMAND|cleanup|core|old logs / stale chunk-upload housekeeping
COMMAND|schedule|core|install/uninstall/status of the launchd agent
COMMAND|trash|core|list/restore/remove/empty the Nextcloud trashbin
COMMAND|versions|core|list/download/restore/delete file versions
COMMAND|share|core|create, list, update, or remove Nextcloud shares
COMMAND|notifications|extra|list or delete Nextcloud notifications
COMMAND|activity|extra|show the Nextcloud activity stream
COMMAND|presence|extra|show or set your Nextcloud user status
COMMAND|lock|core|lock a remote file (WebDAV)
COMMAND|unlock|core|unlock a remote file (WebDAV)
COMMAND|locks|core|list locks recorded by sciebo lock
COMMAND|quota|core|show server quota usage
COMMAND|open|core|open a local sync folder
COMMAND|conflicts|core|find local conflict copies
COMMAND|retry|core|clear failure-blacklist entries
COMMAND|account|core|manage profiles (list/add/remove/use/info/avatar)
COMMAND|logout|core|remove credentials for the active remote
COMMAND|config|core|show effective settings and their source
COMMAND|support|core|build a redacted debug archive
COMMAND|nextcloudcmd|core|nextcloudcmd-compatible single sync run
COMMAND|watch|core|run sync when local files change
COMMAND|limit|core|cap bandwidth for later runs
COMMAND|unlimited|core|lift the bandwidth cap
COMMAND|network|core|show the active network and metered state
COMMAND|filters|core|manage filter files (sync/list/show/check)
COMMAND|file|extra|file details, activity, and shares
COMMAND|search|extra|unified search on the server
COMMAND|recent|extra|recently modified remote files
COMMAND|comments|extra|file comments (Nextcloud comments app)
COMMAND|favorites|extra|list or toggle server-side favorites
COMMAND|tags|extra|list system tags and assign them
COMMAND|server|extra|server information and capabilities
COMMAND|hydrate|core|download a remote path on demand
COMMAND|provision|core|non-interactive account and folder setup
COMMAND|logs|core|list, show, or tail per-source sync logs
COMMAND|edit|extra|download, edit, and upload one remote file
COMMAND|ignored|core|list files excluded from syncing
COMMAND|announcements|extra|list server announcements
COMMAND|preview|extra|download a preview image for a remote file
COMMAND|download|core|download a remote file or directory
COMMAND|update|core|update the local checkout from git
COMMAND|help|core|show help for a command

# --- setup ---------------------------------------------------------
OPT|setup|-|--login||flag|NONE|authenticate with the Nextcloud Login Flow v2
OPT|setup|-|--url|url|value|NONE|base URL for --login
OPT|setup|-|--rotate||flag|NONE|fetch a fresh app password for the configured remote
OPT|setup|-|--no-keychain||flag|NONE|store the obscured password in the rclone config
OPT|setup|-|--proxy|url|value|NONE|proxy URL for this setup run
OPT|setup|-|--crypt||flag|NONE|create the crypt remote wrapping the WebDAV remote

# --- doctor ----------------------------------------------------------
OPT|doctor|-|--offline||flag|NONE|skip network checks
OPT|doctor|-|--json||flag|NONE|print a JSON document instead of the text report

# --- discover ----------------------------------------------------------
OPT|discover|-|--write||flag|NONE|write config/sources.generated.conf

# --- list ----------------------------------------------------------
OPT|list|-|--json||flag|NONE|print the valid sources as JSON

# --- check / sync (share one option set) --------------------------------
OPT|check|-|--apply||flag|NONE|transfer data (default for sync; check stays a dry run)
OPT|check|-|--dry-run||flag|NONE|explicit dry run (default for check)
OPT|check|-|--only|source name|value|NONE|run only this source
OPT|check|-|--list||flag|NONE|print the parsed sources and exit (same as `sciebo list`)
OPT|check|-|--resync||flag|NONE|allow rclone bisync --resync
OPT|check|-|--yes||flag|NONE|ignore the MAX_DOWNLOAD_SIZE and delete guards
OPT|check|-|--metered-ok||flag|NONE|run even on a metered connection
OPT|check|-|--quiet||flag|NONE|only print failures, warnings, and the summary
OPT|check|-|--no-lock||flag|NONE|do not take the run lock
OPT|check|-|--force||flag|NONE|run even while paused
OPT|sync|-|--apply||flag|NONE|transfer data (default for sync; check stays a dry run)
OPT|sync|-|--dry-run||flag|NONE|explicit dry run (default for check)
OPT|sync|-|--only|source name|value|NONE|run only this source
OPT|sync|-|--list||flag|NONE|print the parsed sources and exit (same as `sciebo list`)
OPT|sync|-|--resync||flag|NONE|allow rclone bisync --resync
OPT|sync|-|--yes||flag|NONE|ignore the MAX_DOWNLOAD_SIZE and delete guards
OPT|sync|-|--metered-ok||flag|NONE|run even on a metered connection
OPT|sync|-|--quiet||flag|NONE|only print failures, warnings, and the summary
OPT|sync|-|--no-lock||flag|NONE|do not take the run lock
OPT|sync|-|--force||flag|NONE|run even while paused

# --- verify ----------------------------------------------------------
OPT|verify|-|--only|source name|value|NONE|check only this source
OPT|verify|-|--download||flag|NONE|download remote files and hash them
OPT|verify|-|--size-only||flag|NONE|compare sizes only, skip hashes
OPT|verify|-|--quiet||flag|NONE|only print failures and the summary

# --- status ----------------------------------------------------------
OPT|status|-|--only|source name|value|NONE|show only this source
OPT|status|-|--history|N|optional-value|NONE|print the last N recorded runs
OPT|status|-|--json||flag|NONE|print the report as JSON
OPT|status|-|--watch|N|optional-value|NONE|refresh the report every N seconds
OPT|status|-|--quiet||flag|NONE|only print rows that need attention

# --- pause ----------------------------------------------------------
OPT|pause|-|--for|duration|value|NONE|pause for this long

# --- resume: no options ------------------------------------------------

# --- folders ----------------------------------------------------------
SUB|folders|choose|browse the remote and pick folders (default)
SUB|folders|add|add a single pair without browsing
SUB|folders|import|add a pair from a nextcloudcmd --unsyncedfolders list
SUB|folders|edit|rewrite a wizard pair subfolder filter or mode
SUB|folders|list|table of all configured pairs
SUB|folders|pause|skip a pair in sync/check
SUB|folders|resume|clear a pair paused flag
SUB|folders|remove|remove a wizard-managed pair from folders.conf

OPT|folders|choose|--depth|depth|value|NONE|remote scan depth
OPT|folders|choose|--local-root|directory|value|DIRS|local root for default destinations
OPT|folders|choose|--mode|mode|value|ENUM:sync,pull,bisync|fix the direction for all picks
OPT|folders|choose|--select||flag|NONE|pick which subfolders to sync
OPT|folders|choose|--no-fzf||flag|NONE|always use the numbered menu
OPT|folders|choose|--no-dry-run||flag|NONE|do not offer a dry run after adding pairs

OPT|folders|add|--remote|remote subfolder|value|NONE|remote subfolder below the remote base
OPT|folders|add|--local|path|value|FILES|local path
OPT|folders|add|--mode|mode|value|ENUM:sync,pull,bisync|direction
OPT|folders|add|--select||flag|NONE|interactively pick subfolders to sync
OPT|folders|add|--include|subfolder|repeatable|NONE|sync only this subfolder below --remote
OPT|folders|add|--exclude|subfolder|repeatable|NONE|exclude this subfolder
OPT|folders|add|--local-root|directory|value|DIRS|local root for the default destination

POS|folders|import|1|FILE|FILES
OPT|folders|import|--remote|remote subfolder|value|NONE|remote subfolder below the remote base
OPT|folders|import|--local|path|value|FILES|local path
OPT|folders|import|--mode|mode|value|ENUM:sync,pull,bisync|direction
OPT|folders|import|--local-root|directory|value|DIRS|local root for the default destination
OPT|folders|import|--select||flag|NONE|sync only the listed folders

POS|folders|edit|1|NAME|NONE
OPT|folders|edit|--local|path|value|FILES|replace the local folder
OPT|folders|edit|--remote|remote subfolder|value|NONE|replace the remote subfolder
OPT|folders|edit|--force||flag|NONE|allow a remote change with stale bisync state
OPT|folders|edit|--include|subfolder|repeatable|NONE|sync only these immediate subfolders
OPT|folders|edit|--exclude|subfolder|repeatable|NONE|exclude this subfolder
OPT|folders|edit|--mode|mode|value|ENUM:sync,pull,bisync|change the direction
OPT|folders|edit|--select||flag|NONE|interactively pick subfolders to sync
OPT|folders|edit|--clear||flag|NONE|remove the pair filter (no rules)

OPT|folders|list|--json||flag|NONE|print the pairs as JSON

POS|folders|pause|1|pair name|NONE
POS|folders|resume|1|pair name|NONE

POS|folders|remove|1|NAME|NONE
OPT|folders|remove|--purge||flag|NONE|also delete the pair state and filter

# --- mount ----------------------------------------------------------
OPT|mount|-|--folder|remote subfolder|value|NONE|remote subfolder below the remote base
OPT|mount|-|--mountpoint|directory|value|DIRS|local mountpoint
OPT|mount|-|--ro||flag|NONE|read-only mount, no VFS cache
OPT|mount|-|--foreground||flag|NONE|run rclone in the foreground
OPT|mount|-|--sudo||flag|NONE|run rclone as root

# --- umount ----------------------------------------------------------
OPT|umount|-|--folder|remote subfolder|value|NONE|unmount the mount for this remote subfolder
OPT|umount|-|--mountpoint|directory|value|DIRS|unmount the mount for this local mountpoint
OPT|umount|-|--all||flag|NONE|unmount every recorded mount
OPT|umount|-|--sudo||flag|NONE|run umount as root

# --- mounts ----------------------------------------------------------
OPT|mounts|-|--folder|remote subfolder|value|NONE|only show this remote subfolder
OPT|mounts|-|--check||flag|NONE|exit 1 when a recorded mount is not visible
OPT|mounts|-|--prune||flag|NONE|remove stale mount records
OPT|mounts|-|--json||flag|NONE|print the mounts as JSON

# --- cleanup ----------------------------------------------------------
OPT|cleanup|-|--logs||flag|NONE|delete old log files and rotate large ones
OPT|cleanup|-|--uploads||flag|NONE|delete stale chunk uploads
OPT|cleanup|-|--state||flag|NONE|delete stale bisync, lock, temp, and mount state
OPT|cleanup|-|--junk||flag|NONE|delete files matching fleeting.txt
OPT|cleanup|-|--cache||flag|NONE|delete stale mount-cache files
OPT|cleanup|-|--support||flag|NONE|keep the newest support archives
OPT|cleanup|-|--keep|N|value|NONE|archives to keep for --support
OPT|cleanup|-|--apply||flag|NONE|actually delete (default is a dry run)

# --- schedule ----------------------------------------------------------
SUB|schedule|install|render the plist and bootstrap the agent
SUB|schedule|uninstall|bootout the agent and remove the plist
SUB|schedule|status|show whether the agent is installed and loaded

OPT|schedule|install|--at-login||flag|NONE|start the agent at login/boot
OPT|schedule|install|--profiles|profiles|value|NONE|render one extra agent per profile

# --- trash ----------------------------------------------------------
SUB|trash|list|list trashed items (default)
SUB|trash|restore|restore items into their original location
SUB|trash|rm|permanently delete items (asks on a terminal)
SUB|trash|empty|permanently delete the whole trashbin

POS|trash|restore|*|trash id|NONE
OPT|trash|restore|--all||flag|NONE|restore every listed item
OPT|trash|restore|--yes||flag|NONE|skip the confirmation

POS|trash|rm|*|trash id|NONE
OPT|trash|rm|--yes||flag|NONE|skip the confirmation

OPT|trash|empty|--yes||flag|NONE|skip the confirmation

# --- versions ----------------------------------------------------------
POS|versions|-|1|remote path|NONE
OPT|versions|-|--download|version|value|NONE|save this version
OPT|versions|-|--output|file|value|FILES|write the --download body to FILE
OPT|versions|-|--stdout||flag|NONE|stream the --download body to standard output
OPT|versions|-|--restore|version|value|NONE|restore this version
OPT|versions|-|--delete|version|value|NONE|delete this version
OPT|versions|-|--yes||flag|NONE|skip the --restore/--delete confirmation

# --- share ----------------------------------------------------------
SUB|share|link|create a public link share
SUB|share|user|share with a Nextcloud user
SUB|share|group|share with a Nextcloud group
SUB|share|email|share with an email address
SUB|share|guest|share with a guest account (share type 8)
SUB|share|circle|share with a circle
SUB|share|talk|share with a Talk conversation
SUB|share|deck|share with a Deck board
SUB|share|remote|share with a federated cloud id
SUB|share|list|list shares, optionally only for a path
SUB|share|info|show one share
SUB|share|update|change password, expiry, note, or permissions
SUB|share|remove|delete a share (asks on a terminal)
SUB|share|leave|leave a share shared with you (asks)
SUB|share|pending|list shares waiting for your acceptance
SUB|share|accept|accept a pending share (or --all)
SUB|share|decline|decline a pending share (or --all; asks or --yes)
SUB|share|send-email|email an existing share to its recipient
SUB|share|remote-list|list accepted federated shares
SUB|share|search|find users, groups, and other sharees
SUB|share|copy-link|create or reuse a public link and copy it
SUB|share|copy-internal|copy a direct internal link for a path
SUB|share|incoming|list shares shared with you

POS|share|link|1|remote path|NONE
OPT|share|link|--password|password|value|NONE|protect the link with a password
OPT|share|link|--expire|date|value|NONE|expire the link on this date
OPT|share|link|--note|text|value|NONE|attach a note
OPT|share|link|--permissions|permissions|value|NONE|permission letters or a numeric mask
OPT|share|link|--label|label|value|NONE|set a link label
OPT|share|link|--download|0 or 1|value|ENUM:0,1|allow downloads: 0 hides them
OPT|share|link|--file-drop||flag|NONE|upload-only link (permission 4)
OPT|share|link|--file-request||flag|NONE|mark the link as a file request
OPT|share|link|--json||flag|NONE|print the created share as JSON

POS|share|copy-link|1|remote path|NONE
OPT|share|copy-link|--password|password|value|NONE|protect the link with a password
OPT|share|copy-link|--expire|date|value|NONE|expire the link on this date
OPT|share|copy-link|--note|text|value|NONE|attach a note
OPT|share|copy-link|--permissions|permissions|value|NONE|permission letters or a numeric mask
OPT|share|copy-link|--label|label|value|NONE|set a link label
OPT|share|copy-link|--download|0 or 1|value|ENUM:0,1|allow downloads: 0 hides them
OPT|share|copy-link|--file-drop||flag|NONE|upload-only link (permission 4)
OPT|share|copy-link|--file-request||flag|NONE|mark the link as a file request
OPT|share|copy-link|--json||flag|NONE|print the created share as JSON

POS|share|user|1|remote path|NONE
POS|share|user|2|user or group|NONE
OPT|share|user|--permissions|permissions|value|NONE|permission letters or a numeric mask
OPT|share|user|--note|text|value|NONE|attach a note
OPT|share|user|--send-mail||flag|NONE|ask the server to email the recipient
OPT|share|user|--json||flag|NONE|print the created share as JSON

POS|share|group|1|remote path|NONE
POS|share|group|2|user or group|NONE
OPT|share|group|--permissions|permissions|value|NONE|permission letters or a numeric mask
OPT|share|group|--note|text|value|NONE|attach a note
OPT|share|group|--send-mail||flag|NONE|ask the server to email the recipient
OPT|share|group|--json||flag|NONE|print the created share as JSON

POS|share|guest|1|remote path|NONE
POS|share|guest|2|user or group|NONE
OPT|share|guest|--permissions|permissions|value|NONE|permission letters or a numeric mask
OPT|share|guest|--note|text|value|NONE|attach a note
OPT|share|guest|--send-mail||flag|NONE|ask the server to email the recipient
OPT|share|guest|--json||flag|NONE|print the created share as JSON

POS|share|circle|1|remote path|NONE
POS|share|circle|2|user or group|NONE
OPT|share|circle|--permissions|permissions|value|NONE|permission letters or a numeric mask
OPT|share|circle|--note|text|value|NONE|attach a note
OPT|share|circle|--send-mail||flag|NONE|ask the server to email the recipient
OPT|share|circle|--json||flag|NONE|print the created share as JSON

POS|share|talk|1|remote path|NONE
POS|share|talk|2|user or group|NONE
OPT|share|talk|--permissions|permissions|value|NONE|permission letters or a numeric mask
OPT|share|talk|--note|text|value|NONE|attach a note
OPT|share|talk|--send-mail||flag|NONE|ask the server to email the recipient
OPT|share|talk|--json||flag|NONE|print the created share as JSON

POS|share|deck|1|remote path|NONE
POS|share|deck|2|user or group|NONE
OPT|share|deck|--permissions|permissions|value|NONE|permission letters or a numeric mask
OPT|share|deck|--note|text|value|NONE|attach a note
OPT|share|deck|--send-mail||flag|NONE|ask the server to email the recipient
OPT|share|deck|--json||flag|NONE|print the created share as JSON

POS|share|remote|1|remote path|NONE
POS|share|remote|2|federated cloud id|NONE
OPT|share|remote|--permissions|permissions|value|NONE|permission letters or a numeric mask
OPT|share|remote|--note|text|value|NONE|attach a note
OPT|share|remote|--send-mail||flag|NONE|ask the server to email the recipient
OPT|share|remote|--json||flag|NONE|print the created share as JSON

POS|share|email|1|remote path|NONE
POS|share|email|2|email address|NONE
OPT|share|email|--permissions|permissions|value|NONE|permission letters or a numeric mask
OPT|share|email|--note|text|value|NONE|attach a note
OPT|share|email|--password|password|value|NONE|protect the share with a password
OPT|share|email|--expire|date|value|NONE|expire the share on this date
OPT|share|email|--send-password-by-talk||flag|NONE|share the password through Talk
OPT|share|email|--send-mail||flag|NONE|ask the server to email the recipient
OPT|share|email|--json||flag|NONE|print the created share as JSON

POS|share|list|?1|remote path|NONE
OPT|share|list|--reshares||flag|NONE|ask the server for reshares only
OPT|share|list|--json||flag|NONE|print the shares as JSON

POS|share|info|1|share id|NONE

POS|share|update|1|share id|NONE
OPT|share|update|--password|password|value|NONE|set the password
OPT|share|update|--remove-password||flag|NONE|remove the password
OPT|share|update|--expire|date|value|NONE|set the expiration date
OPT|share|update|--remove-expire||flag|NONE|remove the expiration date
OPT|share|update|--note|text|value|NONE|attach a note
OPT|share|update|--remove-note||flag|NONE|remove the note
OPT|share|update|--permissions|permissions|value|NONE|permission letters or a numeric mask
OPT|share|update|--label|label|value|NONE|set a link label
OPT|share|update|--download|0 or 1|value|ENUM:0,1|allow downloads: 0 hides them
OPT|share|update|--send-mail||flag|NONE|ask the server to email the recipient

POS|share|remove|1|share id|NONE
OPT|share|remove|--yes||flag|NONE|skip the confirmation

POS|share|leave|1|share id|NONE
OPT|share|leave|--yes||flag|NONE|skip the confirmation

OPT|share|pending|--local||flag|NONE|only local pending shares
OPT|share|pending|--remote||flag|NONE|only federated pending shares
OPT|share|pending|--json||flag|NONE|print the pending shares as JSON

POS|share|accept|?1|pending share id|NONE
OPT|share|accept|--remote||flag|NONE|force the federated list
OPT|share|accept|--all||flag|NONE|accept every pending share

POS|share|decline|?1|pending share id|NONE
OPT|share|decline|--remote||flag|NONE|force the federated list
OPT|share|decline|--yes||flag|NONE|skip the confirmation
OPT|share|decline|--all||flag|NONE|decline every pending share

POS|share|send-email|1|share id|NONE

OPT|share|remote-list|--json||flag|NONE|print the remote shares as JSON

POS|share|search|1|query|NONE

POS|share|copy-internal|1|remote path|NONE

OPT|share|incoming|--json||flag|NONE|print the shares as JSON

# --- notifications ----------------------------------------------------------
OPT|notifications|-|--limit|N|value|NONE|print and notify at most N notifications
OPT|notifications|-|--app|list|value|NONE|only notifications from these apps
OPT|notifications|-|--type|list|value|NONE|only notifications with these object types
OPT|notifications|-|--unseen||flag|NONE|only notifications not yet in the seen cache
OPT|notifications|-|--action|id label|two-arg|NONE|run an action on a notification
OPT|notifications|-|--delete|id|value|NONE|delete one notification
OPT|notifications|-|--delete-all||flag|NONE|delete every notification
OPT|notifications|-|--notify||flag|NONE|send a notification per new notification
OPT|notifications|-|--json||flag|NONE|print the filtered notifications as JSON
OPT|notifications|-|--watch|seconds|optional-value|NONE|poll every N seconds
OPT|notifications|-|--quiet||flag|NONE|print no notification rows
OPT|notifications|-|--yes||flag|NONE|skip the --delete-all confirmation

# --- activity ----------------------------------------------------------
OPT|activity|-|--limit|N|value|NONE|print and notify at most N activities
OPT|activity|-|--since|duration|value|NONE|only activities newer than DURATION (paged)
OPT|activity|-|--notify||flag|NONE|send a notification per new activity
OPT|activity|-|--quiet||flag|NONE|print no activity rows

# --- presence ----------------------------------------------------------
SUB|presence|show|show the current status and message
SUB|presence|set|set the status and an optional message
SUB|presence|clear|clear the custom status message

POS|presence|set|1|status|ENUM:online,away,dnd,offline
OPT|presence|set|--message|text|value|NONE|publish a custom message
OPT|presence|set|--emoji|emoji|value|NONE|publish a status emoji
OPT|presence|set|--clear-after|duration|value|NONE|expire the message after

# --- lock ----------------------------------------------------------
POS|lock|-|1|remote file|NONE

# --- unlock ----------------------------------------------------------
POS|unlock|-|?1|remote file|NONE
OPT|unlock|-|--all||flag|NONE|release every recorded lock
OPT|unlock|-|--yes||flag|NONE|skip the --all confirmation

# --- locks ----------------------------------------------------------
OPT|locks|-|--prune||flag|NONE|forget records whose lock-token is gone
OPT|locks|-|--unlock-all||flag|NONE|release every recorded lock
OPT|locks|-|--yes||flag|NONE|skip the --unlock-all confirmation

# --- quota ----------------------------------------------------------
OPT|quota|-|--json||flag|NONE|print rclone JSON output

# --- open ----------------------------------------------------------
POS|open|-|?1|remote path, local path, or name|FILES
OPT|open|-|--print||flag|NONE|print the resolved path or URL instead of opening it
OPT|open|-|--web||flag|NONE|open the folder in the Nextcloud web UI

# --- conflicts ----------------------------------------------------------
OPT|conflicts|-|--resolve|mode|value|ENUM:keep-local,keep-remote,keep-newest,keep-oldest,keep-both|resolve conflict files instead of listing
OPT|conflicts|-|--only|source name|value|NONE|scan or resolve only this source
OPT|conflicts|-|--kind|kind|value|ENUM:copy,case,all|scan or resolve only one conflict kind
OPT|conflicts|-|--remote||flag|NONE|list case clashes on the server instead of local files
OPT|conflicts|-|--open||flag|NONE|open the conflict directories with the platform opener
OPT|conflicts|-|--apply||flag|NONE|carry out the planned actions
OPT|conflicts|-|--yes||flag|NONE|skip the --apply confirmation
OPT|conflicts|-|--json||flag|NONE|print the resolve result as JSON
OPT|conflicts|-|--quiet||flag|NONE|print nothing; exit 1 when conflict files exist

# --- retry ----------------------------------------------------------
POS|retry|-|?1|source name|NONE
POS|retry|-|?2|path|NONE
OPT|retry|-|--list||flag|NONE|show all blacklist records and exit
OPT|retry|-|--all||flag|NONE|clear every source records

# --- account ----------------------------------------------------------
SUB|account|list|show every profile
SUB|account|add|create a profile
SUB|account|import|import accounts from the Nextcloud desktop client
SUB|account|remove|delete a profile config and state
SUB|account|use|show how to activate a profile
SUB|account|info|show the account on the server
SUB|account|avatar|download the account avatar
SUB|account|status|remote, server, cache, and keychain state

POS|account|add|1|profile name|NONE
OPT|account|add|--remote|remote|value|NONE|rclone remote name
OPT|account|add|--base|base|value|NONE|remote base folder

OPT|account|import|--nextcloud-cfg|file|value|FILES|read FILE instead of the default nextcloud.cfg
OPT|account|import|--profile|account|value|NONE|import only the matching account
OPT|account|import|--dry-run||flag|NONE|print the plan and write nothing
OPT|account|import|--yes||flag|NONE|merge without asking
OPT|account|import|--json||flag|NONE|print the plan as JSON

POS|account|remove|1|profile name|PROFILES
OPT|account|remove|--yes||flag|NONE|skip the confirmation

POS|account|use|1|profile name|PROFILES

OPT|account|info|--json||flag|NONE|print the account info as JSON

OPT|account|avatar|--output|file|value|FILES|write the avatar to FILE
OPT|account|avatar|--size|pixels|value|NONE|avatar pixel size

OPT|account|status|--json||flag|NONE|print the status as JSON

# --- logout ----------------------------------------------------------
OPT|logout|-|--revoke||flag|NONE|revoke the app password on the server first
OPT|logout|-|--yes||flag|NONE|do not ask for confirmation

# --- config ----------------------------------------------------------
SUB|config|list|print every setting as KEY=VALUE<TAB>source
SUB|config|get|print the effective value of one setting
SUB|config|check|check the settings and required files
SUB|config|edit|edit config/settings.local.env

OPT|config|list|--json||flag|NONE|print the result as JSON
OPT|config|list|--all||flag|NONE|also show settings whose value is empty

POS|config|get|1|KEY|NONE
OPT|config|get|--json||flag|NONE|print the result as JSON

OPT|config|check|--json||flag|NONE|print the result as JSON

# --- support ----------------------------------------------------------
OPT|support|-|--output|file|value|FILES|archive path
OPT|support|-|--no-network||flag|NONE|accepted for compatibility; doctor runs offline
OPT|support|-|--json||flag|NONE|print the archive summary as JSON

# --- nextcloudcmd ----------------------------------------------------------
POS|nextcloudcmd|-|1|SOURCEDIR|DIRS
POS|nextcloudcmd|-|2|NEXTCLOUDURL|NONE
OPT|nextcloudcmd|-|--path|subfolder|value|NONE|remote folder below the user root
OPT|nextcloudcmd|-|--confdir|directory|value|DIRS|configuration base for this run
OPT|nextcloudcmd|-|--user,-u|user|value|NONE|user name
OPT|nextcloudcmd|-|--password,-p|password|value|NONE|password
OPT|nextcloudcmd|-|--password-fd|fd|value|NONE|read the password from an already-open file descriptor
OPT|nextcloudcmd|-|-n||flag|NONE|read credentials from ~/.netrc
OPT|nextcloudcmd|-|--silent,-s||flag|NONE|errors only
OPT|nextcloudcmd|-|--httpproxy|url|value|NONE|HTTP proxy URL
OPT|nextcloudcmd|-|--exclude|file|value|FILES|read exclude patterns from FILE
OPT|nextcloudcmd|-|--exclude-anchored|file|value|FILES|read sync-root patterns from FILE
OPT|nextcloudcmd|-|--unsyncedfolders|file|value|FILES|exclude every folder listed in FILE
OPT|nextcloudcmd|-|--max-sync-retries|N|value|NONE|retry the whole sync up to N times
OPT|nextcloudcmd|-|--uplimit|rate|value|NONE|upload bandwidth cap
OPT|nextcloudcmd|-|--downlimit|rate|value|NONE|download bandwidth cap
OPT|nextcloudcmd|-|--logdebug,--verbose||flag|NONE|debug-level logging
OPT|nextcloudcmd|-|--progress,-P||flag|NONE|show rclone transfer progress (terminal only)
OPT|nextcloudcmd|-|-v,--version||flag|NONE|print the version and exit
OPT|nextcloudcmd|-|-h||flag|NONE|sync hidden files
OPT|nextcloudcmd|-|--dry-run||flag|NONE|report what would change, change nothing

# --- watch ----------------------------------------------------------
OPT|watch|-|--interval|seconds|value|NONE|poll interval in seconds
OPT|watch|-|--debounce|seconds|value|NONE|coalesce change events for N seconds
OPT|watch|-|--only|source name|repeatable|NONE|watch only this source
OPT|watch|-|--remote-interval|seconds|value|NONE|check the remote every N seconds
OPT|watch|-|--backend|backend|value|ENUM:auto,fswatch,inotify,poll|change-detection backend
OPT|watch|-|--once||flag|NONE|run one detection cycle and exit
OPT|watch|-|--notify||flag|NONE|allow desktop notifications
OPT|watch|-|--no-notify||flag|NONE|disable desktop notifications even when NOTIFY=1
OPT|watch|-|--quiet||flag|NONE|only warnings and errors

# --- limit ----------------------------------------------------------
OPT|limit|-|--up|rate|value|NONE|upload cap, e.g. 2M
OPT|limit|-|--down|rate|value|NONE|download cap, e.g. 5M
OPT|limit|-|--until|duration|value|NONE|expire after this long
OPT|limit|-|--show||flag|NONE|print the current limit
OPT|limit|-|--clear||flag|NONE|remove the marker
OPT|limit|-|--json||flag|NONE|print the state as JSON

# --- unlimited: no options ----------------------------------------------

# --- network ----------------------------------------------------------
OPT|network|-|--json||flag|NONE|print the state as JSON

# --- filters ----------------------------------------------------------
SUB|filters|sync|fetch the server sync-exclude list and regenerate the filter
SUB|filters|list|table of filter files and server-cache staleness
SUB|filters|show|print one filter file
SUB|filters|check|validate every filter with rclone

OPT|filters|sync|--json||flag|NONE|print the result as JSON
OPT|filters|list|--json||flag|NONE|print the result as JSON
POS|filters|show|1|filter file|NONE

# --- file ----------------------------------------------------------
SUB|file|info|show WebDAV metadata for a path
SUB|file|activity|show the activity stream of a path
SUB|file|shares|list the shares of a path

POS|file|info|1|remote path|NONE
OPT|file|info|--json||flag|NONE|print the metadata as JSON

POS|file|activity|1|remote path|NONE
OPT|file|activity|--limit|N|value|NONE|print at most N entries
OPT|file|activity|--json||flag|NONE|print the activity as JSON

POS|file|shares|1|remote path|NONE
OPT|file|shares|--json||flag|NONE|print the shares as JSON

# --- search ----------------------------------------------------------
POS|search|-|1|TERM|NONE
OPT|search|-|--limit|N|value|NONE|ask the server for at most N results
OPT|search|-|--json||flag|NONE|print the results as JSON
OPT|search|-|--open||flag|NONE|open the first result with the platform opener

# --- recent ----------------------------------------------------------
OPT|recent|-|--since|duration|value|NONE|only files modified within DURATION
OPT|recent|-|--limit|N|value|NONE|print at most N files
OPT|recent|-|--json||flag|NONE|print the files as JSON

# --- comments ----------------------------------------------------------
POS|comments|-|1|remote path|NONE
POS|comments|-|2|action|ENUM:list,add,delete
POS|comments|-|3|argument|NONE
OPT|comments|-|--limit|N|value|NONE|list at most N comments
OPT|comments|-|--json||flag|NONE|print the listing as JSON
OPT|comments|-|--yes||flag|NONE|skip the delete confirmation

# --- favorites ----------------------------------------------------------
POS|favorites|-|1|subcommand|ENUM:list,add,remove
POS|favorites|-|2|remote path|NONE
OPT|favorites|-|--json||flag|NONE|print the listing as JSON

# --- tags ----------------------------------------------------------
SUB|tags|list|list the system tags (default)
SUB|tags|create|create a user-visible, user-assignable tag
SUB|tags|assign|replace the tags of a path with an id list
SUB|tags|clear|remove every tag from a path

OPT|tags|list|--json||flag|NONE|print the listing as JSON
POS|tags|create|1|NAME|NONE
POS|tags|assign|1|remote path|NONE
POS|tags|assign|2|tag ids|NONE
POS|tags|clear|1|remote path|NONE

# --- server ----------------------------------------------------------
SUB|server|info|server URL, user, and capability facts
SUB|server|capabilities|parsed capabilities summary
SUB|server|status|reachability check with rclone lsd

OPT|server|info|--json||flag|NONE|print a JSON document
OPT|server|capabilities|--raw||flag|NONE|print the cached raw OCS response
OPT|server|capabilities|--json||flag|NONE|print the capabilities as JSON

# --- hydrate ----------------------------------------------------------
POS|hydrate|-|1|remote path|NONE
OPT|hydrate|-|--dest|directory|value|DIRS|copy into DIR instead of the resolved destination
OPT|hydrate|-|--dry-run||flag|NONE|report what would be copied; changes nothing
OPT|hydrate|-|--quiet||flag|NONE|do not print the success line
OPT|hydrate|-|--json||flag|NONE|print the result as JSON
OPT|hydrate|-|--progress||flag|NONE|show rclone transfer progress (terminal only)

# --- provision ----------------------------------------------------------
OPT|provision|-|--userid|user id|value|NONE|Nextcloud user id
OPT|provision|-|--apppassword|password|value|NONE|app password
OPT|provision|-|--apppassword-fd|fd|value|NONE|read the app password from this open file descriptor
OPT|provision|-|--serverurl|url|value|NONE|server base URL
OPT|provision|-|--localdirpath|directory|value|DIRS|local folder to pair
OPT|provision|-|--remotedirpath|remote subfolder|value|NONE|remote folder below the remote base
OPT|provision|-|--isvfsenabled|0 or 1|value|ENUM:0,1|desktop compatibility flag; 1 warns and is ignored
OPT|provision|-|--profile|profile|value|PROFILES|profile to create or update

# --- logs ----------------------------------------------------------
SUB|logs|list|table of sources and their logs (default)
SUB|logs|show|print the last lines of a source log
SUB|logs|tail|follow a source log with tail -f
SUB|logs|path|print a source log path

OPT|logs|-|--json||flag|NONE|print the rows as JSON
OPT|logs|list|--json||flag|NONE|print the rows as JSON
POS|logs|show|1|source name|NONE
OPT|logs|show|--lines|N|value|NONE|trailing lines to print
POS|logs|tail|1|source name|NONE
OPT|logs|tail|--lines|N|value|NONE|trailing lines to print
POS|logs|path|?1|source name|NONE

# --- edit ----------------------------------------------------------
POS|edit|-|1|remote file|NONE
OPT|edit|-|--editor|command|value|NONE|editor command, possibly with arguments
OPT|edit|-|--no-upload||flag|NONE|do not upload after editing
OPT|edit|-|--lock||flag|NONE|take a WebDAV lock while editing

# --- ignored ----------------------------------------------------------
POS|ignored|-|?1|local, local-relative, or remote-relative prefix|NONE
OPT|ignored|-|--source|source name|value|NONE|restrict the scan to one source
OPT|ignored|-|--json||flag|NONE|print the ignored files as JSON

# --- announcements ----------------------------------------------------------
OPT|announcements|-|--limit|N|value|NONE|print at most N announcements
OPT|announcements|-|--no-dismiss||flag|NONE|accepted for compatibility
OPT|announcements|-|--json||flag|NONE|print the announcements as JSON

# --- preview ----------------------------------------------------------
POS|preview|-|1|remote file|NONE
OPT|preview|-|--output|file|value|FILES|write the image to FILE
OPT|preview|-|--size|pixels|value|NONE|preview edge size in pixels

# --- download ----------------------------------------------------------
POS|download|-|1|remote path|NONE
POS|download|-|2|destination|NONE
OPT|download|-|--dry-run||flag|NONE|report what would be transferred; change nothing
OPT|download|-|--force||flag|NONE|download even when the destination matches
OPT|download|-|--resume,--continue||flag|NONE|continue a partial file
OPT|download|-|--quiet||flag|NONE|do not print the success line
OPT|download|-|--json||flag|NONE|print a structured summary
OPT|download|-|--progress||flag|NONE|show rclone transfer progress (terminal only)

# --- update ----------------------------------------------------------
OPT|update|-|--check||flag|NONE|only report the local vs upstream state
OPT|update|-|--json||flag|NONE|print the report as JSON

# --- help ----------------------------------------------------------
POS|help|-|1|command|COMMANDS
