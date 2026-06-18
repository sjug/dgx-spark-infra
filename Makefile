.PHONY: help capture diff ping apply apply-check apply-packages apply-services apply-users apply-configs apply-check-packages apply-check-services apply-check-configs minimal-packages minimal-packages-check cleanup cleanup-check cache-clean cache-clean-check reboot syntax-check syntax-check-site syntax-check-cleanup syntax-check-minimal-packages syntax-check-maintenance lint-ansible lint-yaml lint-shell lint-git validate

ANSIBLE_OPTS ?=
DEFAULT_INVENTORY := $(if $(wildcard inventory/hosts.yml),inventory/hosts.yml,inventory/hosts.example.yml)
INVENTORY ?= $(DEFAULT_INVENTORY)
TARGET ?= sync_targets
CLEANUP_TARGET ?= cleanup_targets
PACKAGE_TARGET ?= package_targets
MAINTENANCE_TARGET ?= cleanup_targets
SOURCE_HOST ?= source-node
DIFF_HOST_A ?= $(SOURCE_HOST)
DIFF_HOST_B ?= target-node
MANAGED_USER ?= admin
DGX_SSH_CONFIG ?=
ANSIBLE_LOCAL_TEMP ?= /tmp/ansible-local
ANSIBLE_REMOTE_TEMP ?= /tmp
ANSIBLE_ENV = ANSIBLE_LOCAL_TEMP=$(ANSIBLE_LOCAL_TEMP) ANSIBLE_REMOTE_TEMP=$(ANSIBLE_REMOTE_TEMP)

-include .env.mk

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-25s\033[0m %s\n", $$1, $$2}'

capture: ## Capture the source node's current state into variable files
	@MANAGED_USER=$(MANAGED_USER) bash scripts/capture.sh $(SOURCE_HOST)

diff: ## Quick SSH-based diff between two machines
	@MANAGED_USER=$(MANAGED_USER) DGX_SSH_CONFIG="$(DGX_SSH_CONFIG)" bash scripts/diff-machines.sh $(DIFF_HOST_A) $(DIFF_HOST_B)

ping: ## Test Ansible connectivity to all hosts
	ANSIBLE_BECOME_ASK_PASS=false ansible -i $(INVENTORY) dgx_spark -m ping $(ANSIBLE_OPTS)

apply-check: ## Dry-run full sync (shows what would change)
	ansible-playbook -i $(INVENTORY) playbooks/site.yml --check --diff -e "target=$(TARGET)" $(ANSIBLE_OPTS)

apply: ## Apply full sync to target
	ansible-playbook -i $(INVENTORY) playbooks/site.yml -e "target=$(TARGET)" $(ANSIBLE_OPTS)

apply-packages: ## Sync only packages
	ansible-playbook -i $(INVENTORY) playbooks/site.yml --tags packages -e "target=$(TARGET)" $(ANSIBLE_OPTS)

apply-services: ## Sync only services
	ansible-playbook -i $(INVENTORY) playbooks/site.yml --tags services -e "target=$(TARGET)" $(ANSIBLE_OPTS)

apply-users: ## Sync only user groups
	ansible-playbook -i $(INVENTORY) playbooks/site.yml --tags users -e "target=$(TARGET)" $(ANSIBLE_OPTS)

apply-configs: ## Sync only config files
	ansible-playbook -i $(INVENTORY) playbooks/site.yml --tags configs -e "target=$(TARGET)" $(ANSIBLE_OPTS)

apply-check-packages: ## Dry-run package sync
	ansible-playbook -i $(INVENTORY) playbooks/site.yml --tags packages --check --diff -e "target=$(TARGET)" $(ANSIBLE_OPTS)

apply-check-services: ## Dry-run service sync
	ansible-playbook -i $(INVENTORY) playbooks/site.yml --tags services --check --diff -e "target=$(TARGET)" $(ANSIBLE_OPTS)

apply-check-configs: ## Dry-run config file sync
	ansible-playbook -i $(INVENTORY) playbooks/site.yml --tags configs --check --diff -e "target=$(TARGET)" $(ANSIBLE_OPTS)

reboot: ## Clean ML caches, reboot DGX Spark nodes, then drop kernel caches
	$(ANSIBLE_ENV) ansible-playbook -i $(INVENTORY) playbooks/reboot.yml $(ANSIBLE_OPTS)

syntax-check: syntax-check-site syntax-check-cleanup syntax-check-minimal-packages syntax-check-maintenance ## Run Ansible syntax validation

syntax-check-site: ## Run syntax validation for the full sync playbook
	$(ANSIBLE_ENV) ansible-playbook -i $(INVENTORY) playbooks/site.yml --syntax-check

syntax-check-cleanup: ## Run syntax validation for the systemd cleanup playbook
	$(ANSIBLE_ENV) ansible-playbook -i $(INVENTORY) playbooks/systemd_cleanup.yml --syntax-check

syntax-check-minimal-packages: ## Run syntax validation for the minimal packages playbook
	$(ANSIBLE_ENV) ansible-playbook -i $(INVENTORY) playbooks/minimal_packages.yml --syntax-check

syntax-check-maintenance: ## Run syntax validation for the maintenance playbook
	$(ANSIBLE_ENV) ansible-playbook -i $(INVENTORY) playbooks/maintenance.yml --syntax-check

lint-ansible: ## Run ansible-lint
	$(ANSIBLE_ENV) ansible-lint

lint-yaml: ## Run yamllint
	yamllint .

lint-shell: ## Run shellcheck on project scripts
	shellcheck scripts/*.sh

lint-git: ## Check committed, staged, and unstaged changes for whitespace errors
	git diff-tree --check --no-commit-id --root -r HEAD
	git diff --cached --check
	git diff --check

cleanup-check: ## Dry-run snap and systemd cleanup on cleanup targets
	$(ANSIBLE_ENV) ansible-playbook -i $(INVENTORY) playbooks/systemd_cleanup.yml --check --diff -e "target=$(CLEANUP_TARGET)" $(ANSIBLE_OPTS)

cleanup: ## Apply snap and systemd cleanup to cleanup targets
	$(ANSIBLE_ENV) ansible-playbook -i $(INVENTORY) playbooks/systemd_cleanup.yml -e "target=$(CLEANUP_TARGET)" $(ANSIBLE_OPTS)

minimal-packages-check: ## Dry-run minimal package install on package targets
	$(ANSIBLE_ENV) ansible-playbook -i $(INVENTORY) playbooks/minimal_packages.yml --check --diff -e "target=$(PACKAGE_TARGET)" $(ANSIBLE_OPTS)

minimal-packages: ## Install minimal packages on package targets
	$(ANSIBLE_ENV) ansible-playbook -i $(INVENTORY) playbooks/minimal_packages.yml -e "target=$(PACKAGE_TARGET)" $(ANSIBLE_OPTS)

cache-clean-check: ## Dry-run ML cache cleanup and kernel cache flush
	$(ANSIBLE_ENV) ansible-playbook -i $(INVENTORY) playbooks/maintenance.yml --check --diff -e "target=$(MAINTENANCE_TARGET)" $(ANSIBLE_OPTS)

cache-clean: ## Clean ML compilation caches and drop kernel filesystem caches
	$(ANSIBLE_ENV) ansible-playbook -i $(INVENTORY) playbooks/maintenance.yml -e "target=$(MAINTENANCE_TARGET)" $(ANSIBLE_OPTS)

validate: syntax-check lint-ansible lint-yaml lint-shell lint-git ## Run all local validation checks

# Local defaults:      copy .env.mk.example to .env.mk
# Override source:     make capture SOURCE_HOST=real-source
# Override user:       make capture MANAGED_USER=real-admin-user
# Extra ansible opts:  make apply ANSIBLE_OPTS="-v"
