# Contributing

Thanks for stopping by. Bug reports, ideas, and pull requests are all welcome.

## Getting set up

All you need is macOS or Linux with Bash 5.3+ and [rclone](https://rclone.org).
macOS ships Bash 3.2 as `/bin/bash`, so `brew install bash` and make sure it
is first on `PATH`. There is no build step: clone the repository and run
`bin/sciebo` straight from the checkout. `make lint` needs `shellcheck` and
`shfmt` and fails without them; set `LINT_ALLOW_MISSING=1` to skip an absent
linter locally (CI never does). `python3` is optional (screenshot tool and a
syntax check). None of these are runtime dependencies.

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
- **New server-API commands start as extras.** A command that wraps a
  Nextcloud server feature is added with tier `extra` in
  `completions/sciebo.spec` and listed under "Extra commands" in
  `usage_main`; it becomes `core` once `tests/contract/real-smoke.sh`
  covers it against a real server. `make lint` checks the two lists agree.
- **Credentials never get committed.** `.env` and
  `config/settings.local.env` are gitignored. Keep them that way, and don't
  paste real credentials or private sciebo URLs into issues.

## Before you open a pull request

```sh
make lint   # shellcheck + shfmt, the completions generator --check, plus a
            # syntax check of the screenshot tool
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

## Shell completions

`completions/sciebo.bash`, `completions/_sciebo` (zsh), and
`completions/sciebo.fish` are generated from `completions/sciebo.spec`; edit
the spec, then run `make gen` to regenerate all three. `make lint` runs
`scripts/gen-completions.sh --check` and fails if the committed files drift
from the spec.

## Style

- Keep changes small and focused, and say *why* in the commit message.
- Match the surrounding code, including the module comment at the top of each
  file.
- Run `make lint` before pushing; it is the formatting authority.
- Update the docs when behavior changes. If a claim in the README stops being
  true, that is a bug too.
