# Contributing

Thanks for stopping by. Bug reports, ideas, and pull requests are all welcome.

## Getting set up

All you need is macOS or Linux with Bash 5.3+ and [rclone](https://rclone.org).
macOS ships Bash 3.2 as `/bin/bash`, so `brew install bash` and make sure it
is first on `PATH`. There is no build step: clone the repository and run
`bin/sciebo` straight from the checkout. `shellcheck`, `shfmt`, and `python3`
are optional locally (two linters and one screenshot tool), but CI expects
the first two.

## What this codebase cares about

- **Bash 5.3+.** launchd starts whichever bash `sciebo` was run with; the
  entrypoint requires the interpreter to be at least 5.3. The guard
  `scripts/check-bash-min.sh` enforces the 5.3 floor by probing the running
  interpreter for the features the code relies on (forkless command
  substitution, `${x@U}`, `SRANDOM`, `wait -n -p`, `BASH_MONOSECONDS`) and
  scans the trees for a curated list of post-5.3 constructs.
- **No new dependencies.** The runtime is bash, rclone, and the `curl` macOS
  already ships (used by the Login Flow, the capabilities probe, and the
  read-only `trash`/`versions` listings). Optional tools (`fzf`, linters) must
  stay optional, and there is no build step.
- **Commands stay independent.** Command modules return a status instead of
  calling each other; only `die` (exit 1) and `usage_error` (exit 2) exit
  directly. Commands that need another command spawn `bin/sciebo`.
- **Credentials never get committed.** `.env` and
  `config/settings.local.env` are gitignored. Keep them that way, and don't
  paste real credentials or private sciebo URLs into issues.

## Before you open a pull request

```sh
make lint   # shellcheck + shfmt, plus a syntax check of the screenshot tool
make test   # unit + feature + integration tests, fully isolated from sciebo
```

The unit tests only exercise libraries. The integration tests need `rclone`
and run the whole CLI against a throwaway `local` remote in a temp directory;
they never touch a real remote, your configuration, or launchd.

## Screenshots

The README and the [demo page](docs/index.html) show real CLI output rendered
to SVG. If you change user-visible output, refresh them:

```sh
make screenshots   # sandboxed run; writes docs/assets/screenshots/*.svg
```

This uses `rclone` and `python3` and talks to a temporary `local` remote, so
your real sciebo account is never involved.

## Style

- Keep changes small and focused, and say *why* in the commit message.
- Match the surrounding code, including the module comment at the top of each
  file.
- Run `make lint` before pushing; it is the formatting authority.
- Update the docs when behavior changes. If a claim in the README stops being
  true, that is a bug too.
