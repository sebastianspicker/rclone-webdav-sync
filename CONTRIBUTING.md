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
to skip an absent linter locally (CI never does). `python3` is optional
(screenshot tool and a syntax check). None of these are runtime dependencies.
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
  usage output; it becomes `core` once the real-server contract suite covers
  it. `make lint` checks the two lists agree.
- **Credentials never get committed.** `.env` and
  `config/settings.local.env` are gitignored. Keep them that way, and don't
  paste real credentials or private sciebo (service) URLs into issues.
<!-- src: CONTRIBUTING.md#what-this-codebase-cares-about -->

## Where code goes

`lib/` is layered: `base` (no dependencies) → `adapters` (platform/HTTP/
keychain wrappers) → `config` (settings) → `state` (locks, run state) →
`sync` (policies, the sync engine) → `cli` → `commands` (one file per
subcommand). A lower layer never sources a higher one; `scripts/check-layers.sh`
(part of `make lint`) enforces the order. See
[docs/architecture.md](docs/architecture.md) for the full module map and for
how to add a new command.
<!-- src: CONTRIBUTING.md#where-code-goes -->

## Before you open a pull request

```sh
make lint       # shellcheck + shfmt, the completions generator --check,
                # the layering check, plus a syntax check of the screenshot tool
make test       # unit + feature + integration tests, fully isolated from sciebo
make test-fast  # unit + feature tests only, skips integration (quicker pre-PR gate)
make test-one T=NAME   # run a single unit/feature test script by name
```

The unit tests only exercise libraries. The integration tests need `rclone`
and run the whole CLI against a throwaway `local` remote in a temp directory;
they never touch a real remote, your configuration, or launchd/systemd.
<!-- src: CONTRIBUTING.md#before-you-open-a-pull-request -->

## Screenshots

The README and the [demo page](docs/index.html) show real CLI output rendered
to SVG. If you change user-visible output, refresh them:

```sh
make screenshots   # sandboxed run; writes docs/assets/screenshots/*.svg
```

This uses `rclone` and `python3` and talks to a temporary `local` remote, so
your real sciebo account is never involved.
<!-- src: CONTRIBUTING.md#screenshots -->

## Shell completions

`completions/sciebo.bash`, `completions/_sciebo` (zsh), and
`completions/sciebo.fish` are generated from `lib/cli/sciebo.spec` (which
also generates `lib/cli/registry.sh`); edit the spec, then run `make gen` to
regenerate all four. `make lint` fails if the committed files drift from the
spec.
<!-- src: CONTRIBUTING.md#shell-completions -->

## Git hooks (optional)

`make hooks` opts into a repo pre-commit hook (`.githooks/pre-commit`) that
runs `shfmt` and `shellcheck` on staged files. It's optional; `make lint`
still runs everything before a merge either way.
<!-- src: CONTRIBUTING.md#git-hooks-optional -->

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
| tier (core / extra) | `core` commands are covered by tests against a real Nextcloud server; `extra` commands are newer and tested only against a local stand-in. |
