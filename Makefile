SHELL := $(shell command -v bash)
BASH := $(SHELL)
SCIEBO := bin/sciebo
VERSION := $(shell cat VERSION 2>/dev/null)
PREFIX ?= $(HOME)/.local
DIST_NAME := rclone-webdav-sync-$(VERSION)
DIST_DIR ?= dist

SC_PROD = $(SCIEBO) completions/sciebo.bash scripts/*.sh lib/*.sh lib/*/*.sh
# CODE_ITEMS: shipped code/assets that install/uninstall replace wholesale.
# config/ and state/ are deliberately not here: they hold the user's data and
# are handled on their own (never deleted, never clobbered on upgrade).
CODE_ITEMS := bin lib scripts launchd completions docs man \
	VERSION README.md LICENSE .env.example
.DEFAULT_GOAL := help

.PHONY: help setup doctor discover list check sync verify status pause resume bisync-resync \
	folders folders-list mount umount mount-status \
	cleanup-logs cleanup-logs-apply cleanup-uploads cleanup-uploads-apply trash \
	check-bash lint gen schedule-install schedule-uninstall schedule-status \
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

lint: check-bash ## shellcheck + shfmt + generated CLI check (LINT_ALLOW_MISSING=1 skips absent linters)
	@status=0; \
	if command -v shellcheck >/dev/null 2>&1; then \
	  echo "shellcheck -x -P SCRIPTDIR $(SC_PROD)"; \
	  shellcheck -x -P SCRIPTDIR $(SC_PROD) || status=1; \
	elif [ -n "$(LINT_ALLOW_MISSING)" ]; then \
	  echo "WARN: shellcheck not found; skipping shellcheck (LINT_ALLOW_MISSING)" >&2; \
	else \
	  echo "ERROR: shellcheck not found; install it or set LINT_ALLOW_MISSING=1" >&2; \
	  status=1; \
	fi; \
	if command -v shfmt >/dev/null 2>&1; then \
	  echo "shfmt -i 2 -ci -d $(SCIEBO) scripts/*.sh lib"; \
	  shfmt -i 2 -ci -d $(SCIEBO) scripts/*.sh lib || status=1; \
	elif [ -n "$(LINT_ALLOW_MISSING)" ]; then \
	  echo "WARN: shfmt not found; skipping shfmt (LINT_ALLOW_MISSING)" >&2; \
	else \
	  echo "ERROR: shfmt not found; install it or set LINT_ALLOW_MISSING=1" >&2; \
	  status=1; \
	fi; \
	echo "scripts/gen-cli.sh --check"; \
	scripts/gen-cli.sh --check || status=1; \
	exit $$status

gen: ## regenerate the CLI registry and shell completions from lib/cli/sciebo.spec
	scripts/gen-cli.sh

schedule-install: ## install the launchd agent
	$(SCIEBO) schedule install

schedule-uninstall: ## remove the launchd agent
	$(SCIEBO) schedule uninstall

schedule-status: ## show launchd agent status
	$(SCIEBO) schedule status

version: ## print the project version
	@printf '%s %s\n' sciebo "$(VERSION)"

install: check-bash ## install the tree under PREFIX (default ~/.local); never touches existing config/state
	@$(BASH) scripts/install.sh install "$(PREFIX)" "$(VERSION)" $(CODE_ITEMS)

uninstall: check-bash ## remove the installed code/assets, wrapper, and man page under PREFIX (keeps config/ and state/)
	@$(BASH) scripts/install.sh uninstall "$(PREFIX)" "$(VERSION)" $(CODE_ITEMS)

update: ## git pull --ff-only (in a worktree), then lint
	@if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then \
	  git pull --ff-only; \
	else \
	  echo "not a git worktree; skipping pull" >&2; \
	fi
	$(MAKE) lint

dist: ## build a source tarball ($(DIST_DIR)/$(DIST_NAME).tar.gz) from the files git would publish
	@test -n "$(VERSION)" || { echo "VERSION file missing" >&2; exit 1; }
	@git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { \
	  echo "ERROR: dist must run inside a git work tree (it packages git-tracked and unignored files only)" >&2; \
	  exit 1; \
	}
	@rm -rf "$(DIST_DIR)/$(DIST_NAME)" && mkdir -p "$(DIST_DIR)/$(DIST_NAME)"
	@files="$$(git ls-files --cached --others --exclude-standard -- \
	    bin lib config launchd scripts docs man completions \
	    VERSION README.md CHANGELOG.md CONTRIBUTING.md SECURITY.md Makefile LICENSE .env.example \
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
