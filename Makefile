SHELL := /bin/bash
SCIEBO := bin/sciebo
.DEFAULT_GOAL := help

.PHONY: help setup doctor discover list check sync bisync-resync \
	folders folders-list mount umount mount-status \
	cleanup-logs cleanup-logs-apply cleanup-uploads cleanup-uploads-apply \
	lint test schedule-install schedule-uninstall schedule-status

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

lint: ## shellcheck + shfmt over the CLI and tests
	@status=0; \
	if command -v shellcheck >/dev/null 2>&1; then \
	  echo "shellcheck -x bin/sciebo scripts/sync.sh tests/*.sh"; \
	  shellcheck -x $(SCIEBO) scripts/sync.sh tests/*.sh || status=1; \
	else \
	  echo "WARN: shellcheck not found; skipping shellcheck" >&2; \
	fi; \
	if command -v shfmt >/dev/null 2>&1; then \
	  echo "shfmt -i 2 -ci -d bin/sciebo scripts/sync.sh lib tests"; \
	  shfmt -i 2 -ci -d $(SCIEBO) scripts/sync.sh lib tests || status=1; \
	else \
	  echo "WARN: shfmt not found; skipping shfmt" >&2; \
	fi; \
	exit $$status

test: ## unit + integration tests (isolated, never sciebo)
	/bin/bash tests/unit.sh
	/bin/bash tests/integration.sh

schedule-install: ## install the launchd agent
	$(SCIEBO) schedule install

schedule-uninstall: ## remove the launchd agent
	$(SCIEBO) schedule uninstall

schedule-status: ## show launchd agent status
	$(SCIEBO) schedule status
