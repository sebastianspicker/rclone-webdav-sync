# Contributing

Thanks for stopping by. Bug reports, ideas, and pull requests are all
welcome.

This document is for a contributor about to open a pull request to
rclone-webdav-sync, an unofficial command-line client for sciebo
(Hochschulcloud.NRW) and other Nextcloud servers. Contributing looks like
this end to end: set up the toolchain below, follow the rules in
[What this codebase cares about](#what-this-codebase-cares-about), find the
right layer for your change in [Where code goes](#where-code-goes), then run
the checklist in [Before you open a pull request](#before-you-open-a-pull-request).
The command is named after the service it connects to; the name belongs to
the sciebo service, not to this project, and this tool works with any
Nextcloud server.
<!-- src: CONTRIBUTING.md -->

## Getting set up

You need macOS or Linux with Bash 5.3+, [rclone](https://rclone.org) 1.69 or
newer, and curl. macOS ships Bash 3.2 as `/bin/bash`, so `brew install bash`
and make sure it is first on `PATH`. There is no build step: clone the
repository and run `bin/sciebo` straight from the checkout. `make lint` needs
`shellcheck` and `shfmt` and fails without them; set `LINT_ALLOW_MISSING=1`
to skip an absent linter locally (CI never does). Linters are not runtime
dependencies.
<!-- src: CONTRIBUTING.md#getting-set-up -->

## What this codebase cares about

- **Bash 5.3+.** launchd/systemd start whichever bash `sciebo` was run with;
  `bin/sciebo` checks the running interpreter's version and refuses to start
  below 5.3, and `make lint`'s `check-bash` target does the same for the
  bash used to run the tooling.
- **No new dependencies.** The runtime is bash, rclone, and curl, used by the
  browser sign-in flow (Login Flow), the capabilities probe, and the
  read-only `trash`/`versions` listings. Optional tools (`fzf`, linters)
  must stay optional, and there is no build step.
- **Commands stay independent.** Command modules return a status instead of
  calling each other; only `die` (exit 1) and `usage_error` (exit 2) exit
  directly. A command that needs another spawns `bin/sciebo`; it does not
  call it as a function.
- **New server-API commands start as extras.** A command that wraps a
  Nextcloud server feature is added with tier `extra` in
  `lib/cli/sciebo.spec` and listed under "Extra commands" in the CLI's
  usage output; `core` is reserved for the established sync workflow.
  `make lint` checks the generated command registry and completions.
- **Credentials never get committed.** `.env` and
  `config/settings.local.env` are gitignored. Keep them that way, and don't
  paste real credentials or private sciebo (service) URLs into issues.
<!-- src: CONTRIBUTING.md#what-this-codebase-cares-about -->

## Where code goes

`lib/` is layered: `base` (no dependencies) → `adapters` (platform/HTTP/
keychain wrappers) → `config` (settings) → `state` (locks, run state) →
`sync` (policies, the sync engine) → `cli` → `commands` (one file per
subcommand). A lower layer never sources a higher one. See
[docs/architecture.md](docs/architecture.md) for the full module map and for
how to add a new command.
<!-- src: CONTRIBUTING.md#where-code-goes -->

## Before you open a pull request

```sh
make lint       # shellcheck, shfmt, and generated CLI consistency
make install PREFIX="$(mktemp -d)"  # installation smoke check
make dist       # build the source tarball
```

<!-- src: CONTRIBUTING.md#before-you-open-a-pull-request -->

## Shell completions

`completions/sciebo.bash`, `completions/_sciebo` (zsh), and
`completions/sciebo.fish` are generated from `lib/cli/sciebo.spec` (which
also generates `lib/cli/registry.sh`); edit the spec, then run `make gen` to
regenerate all four. `make lint` fails if the committed files drift from the
spec.
<!-- src: CONTRIBUTING.md#shell-completions -->

## Style

- Keep changes small and focused, and say *why* in the commit message.
- Match the surrounding code, including the module comment at the top of each
  file.
- Run `make lint` before pushing; it is the formatting authority.
- Update the docs when behavior changes. If a claim in the README stops being
  true, that is a bug too.
<!-- src: CONTRIBUTING.md#style -->

## Limitations

This document states process rules, not a formal style guide: what it lists
above is what this codebase's reviewers check for, not an exhaustive style
manual. The one rule that applies to this document too: if a claim in the
README (or in this file) stops being true, that is a bug, and the fix
includes updating the docs, not only the code.
<!-- src: CONTRIBUTING.md#style -->

## Glossary

| Term | Meaning |
| --- | --- |
| sciebo | The Hochschulcloud.NRW cloud storage service for NRW universities; this project is an unofficial client for it. |
| `sciebo` (command) | The command this tool installs; named after the service. |
| Nextcloud | The open-source server software the sciebo service and other institutions run. |
| rclone | The third-party file-transfer engine this tool is built on. |
| layer | One of seven ordered internal code groupings (from basic helpers up to individual commands); lower layers never depend on higher ones. |
| tier (core / extra) | `core` commands cover the established sync workflow; `extra` commands expose newer Nextcloud server features. |
