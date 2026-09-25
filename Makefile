SHELL := $(shell command -v bash)
BASH := $(SHELL)
SCIEBO := bin/sciebo
VERSION := $(shell cat VERSION 2>/dev/null)
PREFIX ?= $(HOME)/.local
DIST_NAME := rclone-webdav-sync-$(VERSION)
DIST_DIR ?= dist

# shellcheck runs twice. Production code is checked with -x, following every
# source into lib/. Tests are checked without following: each one sources the
# whole library through lib/sciebo.sh, so -x would re-analyze all of lib/ once
# per test file (minutes instead of seconds). The excluded codes are exactly
# the ones that need the library's view: globals it assigns (SC2154) or reads
# (SC2034), stubs it calls (SC2329), and the unfollowed source (SC1091).
SC_PROD = $(SCIEBO) .githooks/pre-commit $(wildcard .claude/hooks/*.sh) completions/sciebo.bash scripts/*.sh lib/*.sh lib/*/*.sh
SC_TESTS = tests/*.sh tests/unit/*.sh tests/contract/*.sh tests/features/*.sh
SC_TEST_EXCLUDES = SC1091,SC2154,SC2034,SC2329
# CODE_ITEMS: shipped code/assets that install/uninstall replace wholesale.
# config/ and state/ are deliberately not here: they hold the user's data and
# are handled on their own (never deleted, never clobbered on upgrade).
CODE_ITEMS := bin lib scripts launchd completions docs man \
	VERSION README.md LICENSE .env.example
.DEFAULT_GOAL := help

.PHONY: help setup doctor discover list check sync verify status pause resume bisync-resync \
	folders folders-list mount umount mount-status \
	cleanup-logs cleanup-logs-apply cleanup-uploads cleanup-uploads-apply trash \
	check-bash lint test test-fast test-one handoff hooks gen screenshots schedule-install schedule-uninstall schedule-status \
	version install uninstall update dist clean-dist

help: ## show this help
	@awk 'BEGIN {FS = ":.*## "; printf "Usage:\n  make <target>\n\nTargets:\n"} /^[a-zA-Z0-9_-]+:.*## / {printf "  %-24s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

setup: ## create/update the sciebo rclone remote
	$(SCIEBO) setup

doctor: ## preflight checks (for --offline run: bin/sciebo doctor --offline)
	$(SCIEBO) doctor

discover: ## scan roots.conf and write config/sources.generated.conf
	$(SCIEBO) discover --write

list: ## list configured sources
	$(SCIEBO) list

folders: ## choose remote folders to sync (folder wizard)
	$(SCIEBO) folders choose

folders-list: ## list configured pairs including wizard entries
	$(SCIEBO) folders list

check: ## dry-run all sources (no changes)
	$(SCIEBO) check

sync: ## apply sync/pull/bisync for all sources
	$(SCIEBO) sync

verify: ## check that sources match their destinations (rclone check)
	$(SCIEBO) verify

status: ## last run per source and the pause state
	$(SCIEBO) status

pause: ## skip sync/check runs until `make resume`
	$(SCIEBO) pause

resume: ## clear the pause marker
	$(SCIEBO) resume

bisync-resync: ## first-time bisync initialization (can copy/delete both ways)
	$(SCIEBO) sync --resync --apply

mount: ## mount the remote base on demand via nfsmount
	$(SCIEBO) mount

umount: ## unmount all recorded rclone mounts
	$(SCIEBO) umount --all

mount-status: ## show recorded rclone mounts
	$(SCIEBO) mounts

cleanup-logs: ## dry-run of old-log cleanup
	$(SCIEBO) cleanup --logs

cleanup-logs-apply: ## delete logs older than LOG_RETENTION_DAYS
	$(SCIEBO) cleanup --logs --apply

cleanup-uploads: ## dry-run of stale Nextcloud chunk-upload cleanup
	$(SCIEBO) cleanup --uploads

cleanup-uploads-apply: ## delete stale chunk uploads
	$(SCIEBO) cleanup --uploads --apply

trash: ## list the Nextcloud trashbin (read-only)
	$(SCIEBO) trash

check-bash: ## fail fast unless the selected bash is 5.3+
	@$(BASH) -c 'if ((BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 503)); then \
	  printf "check-bash: sciebo requires Bash 5.3 or newer; %s is %s.\n" "$(BASH)" "$$BASH_VERSION" >&2; \
	  printf "check-bash: install a newer bash (macOS: brew install bash) and put it first on PATH.\n" >&2; \
	  exit 1; \
	fi'

lint: check-bash ## shellcheck + shfmt + layers/drift guards (LINT_ALLOW_MISSING=1 skips absent linters)
	@status=0; \
	if command -v shellcheck >/dev/null 2>&1; then \
	  echo "shellcheck -x -P SCRIPTDIR $(SC_PROD)"; \
	  shellcheck -x -P SCRIPTDIR $(SC_PROD) || status=1; \
	  echo "shellcheck -P SCRIPTDIR -e $(SC_TEST_EXCLUDES) $(SC_TESTS)"; \
	  shellcheck -P SCRIPTDIR -e $(SC_TEST_EXCLUDES) $(SC_TESTS) || status=1; \
	elif [ -n "$(LINT_ALLOW_MISSING)" ]; then \
	  echo "WARN: shellcheck not found; skipping shellcheck (LINT_ALLOW_MISSING)" >&2; \
	else \
	  echo "ERROR: shellcheck not found; install it or set LINT_ALLOW_MISSING=1" >&2; \
	  status=1; \
	fi; \
	if command -v shfmt >/dev/null 2>&1; then \
	  echo "shfmt -i 2 -ci -d bin/sciebo .githooks/pre-commit $(wildcard .claude/hooks/*.sh) scripts/*.sh lib tests"; \
	  shfmt -i 2 -ci -d $(SCIEBO) .githooks/pre-commit $(wildcard .claude/hooks/*.sh) scripts/*.sh lib tests || status=1; \
	elif [ -n "$(LINT_ALLOW_MISSING)" ]; then \
	  echo "WARN: shfmt not found; skipping shfmt (LINT_ALLOW_MISSING)" >&2; \
	else \
	  echo "ERROR: shfmt not found; install it or set LINT_ALLOW_MISSING=1" >&2; \
	  status=1; \
	fi; \
	echo "scripts/check-layers.sh"; \
	scripts/check-layers.sh || status=1; \
	echo "scripts/gen-cli.sh --check"; \
	scripts/gen-cli.sh --check || status=1; \
	echo "DRIFT_STRICT=1 scripts/check-drift.sh"; \
	DRIFT_STRICT=1 scripts/check-drift.sh || status=1; \
	if command -v python3 >/dev/null 2>&1; then \
	  echo "python3 -m py_compile tools/screenshots.py tests/fake_server.py"; \
	  python3 -m py_compile tools/screenshots.py tests/fake_server.py || status=1; \
	else \
	  echo "WARN: python3 not found; skipping python syntax checks" >&2; \
	fi; \
	exit $$status

test: check-bash ## unit + feature + integration tests (isolated, never sciebo)
	$(BASH) tests/unit.sh
	$(BASH) tests/features.sh
	$(BASH) tests/integration.sh

test-fast: check-bash ## unit + feature tests only (pre-PR gate without integration)
	$(BASH) tests/unit.sh
	$(BASH) tests/features.sh

test-one: check-bash ## run one unit/feature test script by name (make test-one T=NAME)
	@if [ -z "$(T)" ]; then echo "usage: make test-one T=NAME" >&2; exit 2; fi
	$(BASH) tests/run-one.sh "$(T)"

handoff: ## write a .agents/handoff.md template (refuses to overwrite; FORCE=1 to replace)
	@f=.agents/handoff.md; \
	if [ -e "$$f" ] && [ -z "$(FORCE)" ]; then \
	  echo "$$f exists; edit it or rerun with FORCE=1" >&2; exit 1; \
	fi; \
	mkdir -p .agents; \
	printf '%s\n' \
	  '# Handoff' '' \
	  'Status: in-progress | ready-for-review | changes-requested | accepted' \
	  "Date: $$(date +%Y-%m-%d)" \
	  "Branch: $$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" '' \
	  '## Goal' '' '' \
	  '## Files changed' '' \
	  "$$(git status --short 2>/dev/null)" '' \
	  '## Checks (command -> exit code)' '' \
	  '- make lint -> ' '- make test -> ' '' \
	  '## Open questions / risks' '' >"$$f"; \
	printf 'wrote %s\n' "$$f"

hooks: ## opt in to the repo git hooks (.githooks/pre-commit: shfmt + shellcheck on staged files)
	git config core.hooksPath .githooks
	@printf 'git hooks enabled from .githooks (undo: git config --unset core.hooksPath)\n'

gen: ## regenerate the CLI registry and shell completions from lib/cli/sciebo.spec
	scripts/gen-cli.sh

screenshots: ## regenerate README/demo screenshots (needs rclone + python3)
	tools/screenshots.py

schedule-install: ## install the launchd agent
	$(SCIEBO) schedule install

schedule-uninstall: ## remove the launchd agent
	$(SCIEBO) schedule uninstall

schedule-status: ## show launchd agent status
	$(SCIEBO) schedule status

version: ## print the project version
	@printf '%s %s\n' sciebo "$(VERSION)"

install: ## install the tree under PREFIX (default ~/.local); never touches existing config/state
	@test -n "$(VERSION)" || { echo "VERSION file missing" >&2; exit 1; }
	@dest="$(PREFIX)/share/rclone-sciebo"; \
	mkdir -p "$$dest" "$(PREFIX)/bin" "$(PREFIX)/share/man/man1"; \
	for item in $(CODE_ITEMS); do \
	  rm -rf "$$dest/$$item"; \
	done; \
	for item in $(CODE_ITEMS); do \
	  [ -e "$$item" ] || continue; \
	  mkdir -p "$$dest/$$(dirname $$item)"; \
	  cp -R "$$item" "$$dest/$$(dirname $$item)/"; \
	done; \
	mkdir -p "$$dest/config"; \
	cp -f config/settings.env "$$dest/config/settings.env"; \
	cp -f config/settings.local.env.example "$$dest/config/settings.local.env.example"; \
	preserved=""; \
	config_files="$$(cd config && find . -type f \
	    ! -name '.*' ! -name settings.env ! -name settings.local.env.example \
	    ! -name settings.local.env ! -name sources.generated.conf \
	    | sed 's#^\./##')"; \
	for rel in $$config_files; do \
	  if [ -e "$$dest/config/$$rel" ]; then \
	    preserved="$$preserved $$rel"; \
	  else \
	    mkdir -p "$$dest/config/$$(dirname $$rel)"; \
	    cp "config/$$rel" "$$dest/config/$$rel"; \
	  fi; \
	done; \
	printf '#!/usr/bin/env bash\nexec bash "%s/bin/sciebo" "$$@"\n' "$$dest" >"$(PREFIX)/bin/sciebo"; \
	chmod +x "$(PREFIX)/bin/sciebo"; \
	if [ -f man/sciebo.1 ]; then cp man/sciebo.1 "$(PREFIX)/share/man/man1/sciebo.1"; fi; \
	if [ -n "$$preserved" ]; then \
	  printf 'preserved existing config:%s\n' "$$preserved"; \
	fi; \
	if [ -d "$$dest/state" ]; then \
	  printf 'preserved existing state/\n'; \
	fi; \
	printf 'installed sciebo %s to %s/bin/sciebo\n' "$(VERSION)" "$(PREFIX)"

uninstall: ## remove the installed code/assets, wrapper, and man page under PREFIX (keeps config/ and state/)
	@dest="$(PREFIX)/share/rclone-sciebo"; \
	if [ -d "$$dest" ]; then \
	  for item in $(CODE_ITEMS); do \
	    rm -rf "$$dest/$$item"; \
	  done; \
	  printf 'removed code and assets under %s\n' "$$dest"; \
	fi; \
	if [ -f "$(PREFIX)/bin/sciebo" ]; then rm -f "$(PREFIX)/bin/sciebo"; printf 'removed %s\n' "$(PREFIX)/bin/sciebo"; fi; \
	if [ -f "$(PREFIX)/share/man/man1/sciebo.1" ]; then \
	  rm -f "$(PREFIX)/share/man/man1/sciebo.1"; \
	  printf 'removed %s\n' "$(PREFIX)/share/man/man1/sciebo.1"; \
	fi; \
	if [ -d "$$dest" ] && [ -z "$$(ls -A "$$dest" 2>/dev/null)" ]; then \
	  rmdir "$$dest"; \
	fi; \
	if [ -d "$$dest" ]; then \
	  printf 'config and state remain in %s (remove with: rm -rf %s)\n' "$$dest" "$$dest"; \
	fi

update: ## git pull --ff-only (in a worktree), then lint + test
	@if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then \
	  git pull --ff-only; \
	else \
	  echo "not a git worktree; skipping pull" >&2; \
	fi
	$(MAKE) lint
	$(MAKE) test

dist: ## build a source tarball ($(DIST_DIR)/$(DIST_NAME).tar.gz) from the files git would publish
	@test -n "$(VERSION)" || { echo "VERSION file missing" >&2; exit 1; }
	@git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { \
	  echo "ERROR: dist must run inside a git work tree (it packages git-tracked and unignored files only)" >&2; \
	  exit 1; \
	}
	@rm -rf "$(DIST_DIR)/$(DIST_NAME)" && mkdir -p "$(DIST_DIR)/$(DIST_NAME)"
	@files="$$(git ls-files --cached --others --exclude-standard -- \
	    bin lib config launchd scripts tests tools docs man completions \
	    VERSION README.md CONTRIBUTING.md SECURITY.md Makefile LICENSE .env.example \
	    | LC_ALL=C sort -u)"; \
	for f in $$files; do \
	  [ -e "$$f" ] || continue; \
	  mkdir -p "$(DIST_DIR)/$(DIST_NAME)/$$(dirname "$$f")"; \
	  cp "$$f" "$(DIST_DIR)/$(DIST_NAME)/$$f"; \
	done
	@tar -czf "$(DIST_DIR)/$(DIST_NAME).tar.gz" -C "$(DIST_DIR)" "$(DIST_NAME)"
	@rm -rf "$(DIST_DIR)/$(DIST_NAME)"
	@printf 'wrote %s/%s.tar.gz\n' "$(DIST_DIR)" "$(DIST_NAME)"

clean-dist: ## remove $(DIST_DIR)/
	rm -rf "$(DIST_DIR)"
