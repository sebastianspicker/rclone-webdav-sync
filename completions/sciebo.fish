# fish completion for the sciebo CLI.
#
# Install by copying this file to
# ~/.config/fish/completions/sciebo.fish, or add completions/ to
# $fish_complete_path. The command list mirrors COMMANDS in bin/sciebo.

function __fish_sciebo_commands
    printf '%s\n' \
        setup doctor discover list check sync verify status pause resume \
        folders mount umount mounts cleanup schedule trash versions share \
        notifications activity presence lock unlock locks quota open \
        conflicts retry account logout config support nextcloudcmd watch \
        limit unlimited network filters file search recent comments \
        favorites tags server hydrate provision logs edit ignored \
        announcements preview download update help
end

function __fish_sciebo_needs_command
    set -l tokens (commandline -opc)
    set -e tokens[1]
    not __fish_seen_subcommand_from (__fish_sciebo_commands)
end

complete -c sciebo -f -n __fish_sciebo_needs_command -a '(__fish_sciebo_commands)'

complete -c sciebo -n __fish_sciebo_needs_command -l profile -d 'Select a profile' -r
complete -c sciebo -n __fish_sciebo_needs_command -l trust -d 'Accept invalid TLS certificates'
complete -c sciebo -n __fish_sciebo_needs_command -l non-interactive -d 'Never prompt'
complete -c sciebo -n __fish_sciebo_needs_command -l debug -d 'Verbose diagnostics'
complete -c sciebo -n __fish_sciebo_needs_command -l log-file -d 'Write the rclone log here' -rF
complete -c sciebo -n __fish_sciebo_needs_command -l confdir -d 'Configuration/state base' -rF
complete -c sciebo -n __fish_sciebo_needs_command -l log-dir -d 'Run log directory' -rF
complete -c sciebo -n __fish_sciebo_needs_command -l log-expire -d 'Log age limit in hours' -r
complete -c sciebo -n __fish_sciebo_needs_command -l version -s V -d 'Show the version'

complete -c sciebo -n '__fish_seen_subcommand_from sync check' -l apply -d 'Transfer data'
complete -c sciebo -n '__fish_seen_subcommand_from sync check' -l dry-run -d 'Dry run'
complete -c sciebo -n '__fish_seen_subcommand_from sync check' -l only -d 'Only this source' -r
complete -c sciebo -n '__fish_seen_subcommand_from sync check' -l resync -d 'First bisync initialization'
complete -c sciebo -n '__fish_seen_subcommand_from sync check' -l quiet -d 'Only warnings and errors'
complete -c sciebo -n '__fish_seen_subcommand_from sync check' -l yes -d 'Skip the delete-guard prompt'
complete -c sciebo -n '__fish_seen_subcommand_from sync check' -l metered-ok -d 'Override the metered gate'

complete -c sciebo -n '__fish_seen_subcommand_from announcements' -l limit -d 'At most N announcements' -r
complete -c sciebo -n '__fish_seen_subcommand_from announcements' -l json -d 'Print JSON'
complete -c sciebo -n '__fish_seen_subcommand_from preview' -l output -d 'Write the image to FILE' -rF
complete -c sciebo -n '__fish_seen_subcommand_from preview' -l size -d 'Preview edge size in pixels' -r
complete -c sciebo -n '__fish_seen_subcommand_from download' -l dry-run -d 'Report only'
complete -c sciebo -n '__fish_seen_subcommand_from download' -l force -d 'Download even when it matches'
complete -c sciebo -n '__fish_seen_subcommand_from download' -l resume -d 'Continue a partial file'
complete -c sciebo -n '__fish_seen_subcommand_from download' -l json -d 'Print JSON'
complete -c sciebo -n '__fish_seen_subcommand_from download hydrate' -l progress -d 'Show rclone transfer progress (terminal only)'
complete -c sciebo -n '__fish_seen_subcommand_from logout' -l revoke -d 'Revoke the app password on the server first'
complete -c sciebo -n '__fish_seen_subcommand_from logout' -l yes -d 'Do not ask for confirmation'
complete -c sciebo -n '__fish_seen_subcommand_from unlock' -l all -d 'Release every recorded lock'
complete -c sciebo -n '__fish_seen_subcommand_from unlock locks' -l yes -d 'Skip the confirmation'
complete -c sciebo -n '__fish_seen_subcommand_from locks' -l prune -d 'Forget records whose lock-token is gone'
complete -c sciebo -n '__fish_seen_subcommand_from locks' -l unlock-all -d 'Release every recorded lock'
complete -c sciebo -n '__fish_seen_subcommand_from accept decline' -l all -d 'Answer every pending share'
complete -c sciebo -n '__fish_seen_subcommand_from accept decline' -l remote -d 'Use the federated list'
complete -c sciebo -n '__fish_seen_subcommand_from decline' -l yes -d 'Skip the confirmation'
complete -c sciebo -n '__fish_seen_subcommand_from folders' -l local -d 'Replace the local folder' -rF
complete -c sciebo -n '__fish_seen_subcommand_from folders' -l remote -d 'Replace the remote subfolder' -r
complete -c sciebo -n '__fish_seen_subcommand_from folders; and __fish_seen_subcommand_from edit' -l force -d 'Allow a stale-bisync remote change'
complete -c sciebo -n '__fish_seen_subcommand_from nextcloudcmd' -l progress -s P -d 'Show rclone transfer progress (terminal only)'
complete -c sciebo -n '__fish_seen_subcommand_from update' -l check -d 'Only report the upstream state'
complete -c sciebo -n '__fish_seen_subcommand_from update' -l json -d 'Print JSON'

complete -c sciebo -n '__fish_seen_subcommand_from link copy-link' -l file-drop -d 'Upload-only link (permission 4)'
complete -c sciebo -n '__fish_seen_subcommand_from link copy-link' -l file-request -d 'Mark the link as a file request'
complete -c sciebo -n '__fish_seen_subcommand_from link copy-link' -l download -d 'Allow downloads (0 hides them)' -r
complete -c sciebo -n '__fish_seen_subcommand_from user group email guest circle talk deck remote' -l send-mail -d 'Ask the server to email the recipient'
complete -c sciebo -n '__fish_seen_subcommand_from share; and __fish_seen_subcommand_from update' -l send-mail -d 'Ask the server to email the recipient'
complete -c sciebo -n '__fish_seen_subcommand_from list' -l reshares -d 'Ask the server for reshares only'
complete -c sciebo -n '__fish_seen_subcommand_from list remote-list' -l json -d 'Print JSON'
complete -c sciebo -n '__fish_seen_subcommand_from folders' -l json -d 'Print the pairs as JSON'
complete -c sciebo -n '__fish_seen_subcommand_from folders' -l purge -d 'Also delete the pair state and filter'
complete -c sciebo -n '__fish_seen_subcommand_from file' -l json -d 'Print the file details/activity/shares as JSON'

complete -c sciebo -n '__fish_seen_subcommand_from folders' -l select -d 'Interactively pick which subfolders to sync'
complete -c sciebo -n '__fish_seen_subcommand_from announcements' -l no-dismiss -d 'Accepted for compatibility; announcements are not dismissed'
complete -c sciebo -n '__fish_seen_subcommand_from notifications' -l unseen -d 'Only notifications not yet in the seen cache'
complete -c sciebo -n '__fish_seen_subcommand_from open' -l web -d 'Open the folder in the Nextcloud web UI'
complete -c sciebo -n '__fish_seen_subcommand_from versions' -l stdout -d 'Stream the --download body to standard output'
complete -c sciebo -n '__fish_seen_subcommand_from conflicts' -l kind -d 'Only one conflict kind' -x -a 'copy case all'
complete -c sciebo -n '__fish_seen_subcommand_from conflicts' -l resolve -d 'Resolve conflict files instead of listing' -x -a 'keep-local keep-remote keep-newest keep-oldest keep-both'
complete -c sciebo -n '__fish_seen_subcommand_from trash' -l all -d 'Restore every listed item'
complete -c sciebo -n '__fish_seen_subcommand_from umount' -l all -d 'Unmount every recorded mount'
complete -c sciebo -n '__fish_seen_subcommand_from retry' -l all -d 'Clear every source record'
complete -c sciebo -n '__fish_seen_subcommand_from config' -l all -d 'Also show settings whose value is empty'
complete -c sciebo -n '__fish_seen_subcommand_from provision' -l apppassword-fd -d 'Read the app password from an open file descriptor' -r

complete -c sciebo -n '__fish_seen_subcommand_from share' -a 'link user group email guest circle talk deck remote list info update remove leave pending accept decline send-email remote-list search copy-link copy-internal incoming'
complete -c sciebo -n '__fish_seen_subcommand_from trash' -a 'list restore rm empty'
complete -c sciebo -n '__fish_seen_subcommand_from folders' -a 'choose add import edit list pause resume remove'
complete -c sciebo -n '__fish_seen_subcommand_from schedule' -a 'install uninstall status'
complete -c sciebo -n '__fish_seen_subcommand_from server' -a 'info capabilities status'
complete -c sciebo -n '__fish_seen_subcommand_from filters' -a 'sync list show check'
complete -c sciebo -n '__fish_seen_subcommand_from tags' -a 'list create assign clear'
complete -c sciebo -n '__fish_seen_subcommand_from account' -a 'list add import remove use info avatar status'
complete -c sciebo -n '__fish_seen_subcommand_from config' -a 'list get check edit'
complete -c sciebo -n '__fish_seen_subcommand_from logs' -a 'list show tail path'
complete -c sciebo -n '__fish_seen_subcommand_from cleanup' -a '--logs --uploads --state --junk --cache --support'
