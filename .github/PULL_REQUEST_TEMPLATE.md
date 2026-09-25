## Summary

<!-- What changed and why. Link the issue if there is one. -->

## Checklist

- [ ] `make lint` passes (shellcheck + shfmt + bash-min + drift).
- [ ] `make test` passes (unit + feature + integration).
- [ ] New command/setting is documented in `docs/commands.md` /
      `docs/settings.md`, `config/settings.env`, and the man page; a new
      command/option is also added to `completions/sciebo.spec` (run
      `make gen` to regenerate the completion files, never edit them by hand).
- [ ] `CHANGELOG.md` has an entry.
- [ ] No secrets, credentials, or real account data are included.

## Notes for reviewers

<!-- Anything that is intentionally out of scope, or that needs a maintainer's
     decision (behavior change, new dependency, packaging). -->
