SHELL := $(shell command -v bash)
BASH := $(SHELL)
SCIEBO := bin/sciebo
VERSION := $(shell cat VERSION 2>/dev/null)
PREFIX ?= $(HOME)/.local
DIST_NAME := rclone-sciebo-$(VERSION)
.DEFAULT_GOAL := help

.PHONY: help setup doctor discover list check sync verify status pause resume bisync-resync \
	folders folders-list mount umount mount-status \
	cleanup-logs cleanup-logs-apply cleanup-uploads cleanup-uploads-apply trash \
	check-bash lint test test-fast screenshots schedule-install schedule-uninstall schedule-status \
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

lint: check-bash ## shellcheck + shfmt + bash-min/drift guards over the CLI and tests
	@status=0; \
	if command -v shellcheck >/dev/null 2>&1; then \
	  echo "shellcheck -x -P SCRIPTDIR bin/sciebo scripts/*.sh tests/*.sh tests/features/*.sh lib/*.sh lib/commands/*.sh"; \
	  shellcheck -x -P SCRIPTDIR $(SCIEBO) scripts/*.sh tests/*.sh tests/features/*.sh lib/*.sh lib/commands/*.sh || status=1; \
	else \
	  echo "WARN: shellcheck not found; skipping shellcheck" >&2; \
	fi; \
	if command -v shfmt >/dev/null 2>&1; then \
	  echo "shfmt -i 2 -ci -d bin/sciebo scripts/*.sh lib tests"; \
	  shfmt -i 2 -ci -d $(SCIEBO) scripts/*.sh lib tests || status=1; \
	else \
	  echo "WARN: shfmt not found; skipping shfmt" >&2; \
	fi; \
	echo "scripts/check-bash-min.sh"; \
	scripts/check-bash-min.sh || status=1; \
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

install: ## install the tree under PREFIX (default ~/.local) and link bin/sciebo
	@test -n "$(VERSION)" || { echo "VERSION file missing" >&2; exit 1; }
	@dest="$(PREFIX)/share/rclone-sciebo"; \
	mkdir -p "$$dest" "$(PREFIX)/bin" "$(PREFIX)/share/man/man1"; \
	for item in bin lib config config/filters launchd scripts docs man completions \
	    VERSION README.md LICENSE .env.example; do \
	  [ -e "$$item" ] || continue; \
	  mkdir -p "$$dest/$$(dirname $$item)"; \
	  cp -R "$$item" "$$dest/$$(dirname $$item)/"; \
	done; \
	printf '#!/usr/bin/env bash\nexec bash "%s/bin/sciebo" "$$@"\n' "$$dest" >"$(PREFIX)/bin/sciebo"; \
	chmod +x "$(PREFIX)/bin/sciebo"; \
	if [ -f man/sciebo.1 ]; then cp man/sciebo.1 "$(PREFIX)/share/man/man1/sciebo.1"; fi; \
	rm -f "$$dest/config/settings.local.env"; \
	rm -rf "$$dest/state"; \
	printf 'installed sciebo %s to %s/bin/sciebo\n' "$(VERSION)" "$(PREFIX)"

uninstall: ## remove the installed tree, wrapper, and man page under PREFIX
	@dest="$(PREFIX)/share/rclone-sciebo"; \
	if [ -d "$$dest" ]; then rm -rf "$$dest"; printf 'removed %s\n' "$$dest"; fi; \
	if [ -f "$(PREFIX)/bin/sciebo" ]; then rm -f "$(PREFIX)/bin/sciebo"; printf 'removed %s\n' "$(PREFIX)/bin/sciebo"; fi; \
	if [ -f "$(PREFIX)/share/man/man1/sciebo.1" ]; then \
	  rm -f "$(PREFIX)/share/man/man1/sciebo.1"; \
	  printf 'removed %s\n' "$(PREFIX)/share/man/man1/sciebo.1"; \
	fi

update: ## git pull --ff-only (in a worktree), then lint + test
	@if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then \
	  git pull --ff-only; \
	else \
	  echo "not a git worktree; skipping pull" >&2; \
	fi
	$(MAKE) lint
	$(MAKE) test

dist: ## build a source tarball (dist/$(DIST_NAME).tar.gz)
	@test -n "$(VERSION)" || { echo "VERSION file missing" >&2; exit 1; }
	@rm -rf dist "$(DIST_NAME)" && mkdir -p "dist/$(DIST_NAME)"
	@for item in bin lib config launchd scripts tests tools docs man completions \
	    VERSION README.md CONTRIBUTING.md SECURITY.md Makefile LICENSE .env.example; do \
	  [ -e "$$item" ] || continue; \
	  mkdir -p "dist/$(DIST_NAME)/$$(dirname $$item)"; \
	  cp -R "$$item" "dist/$(DIST_NAME)/$$(dirname $$item)/"; \
	done
	@rm -rf "dist/$(DIST_NAME)/state"
	@tar -czf "dist/$(DIST_NAME).tar.gz" -C dist "$(DIST_NAME)"
	@rm -rf "dist/$(DIST_NAME)"
	@printf 'wrote dist/%s.tar.gz\n' "$(DIST_NAME)"

clean-dist: ## remove dist/
	rm -rf dist "$(DIST_NAME)"
