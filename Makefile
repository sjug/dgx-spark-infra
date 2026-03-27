.PHONY: help capture diff ping apply apply-check apply-packages apply-services apply-users apply-configs apply-check-packages apply-check-services apply-check-configs reboot syntax-check lint-ansible lint-yaml lint-shell validate

ANSIBLE_OPTS ?=
INVENTORY ?= inventory/hosts.yml
TARGET ?= sync_targets
SOURCE_HOST ?= source-node
DIFF_HOST_A ?= $(SOURCE_HOST)
DIFF_HOST_B ?= target-node
MANAGED_USER ?= admin
ANSIBLE_LOCAL_TEMP ?= /tmp/ansible-local
ANSIBLE_REMOTE_TEMP ?= /tmp/ansible-remote
ANSIBLE_ENV = ANSIBLE_LOCAL_TEMP=$(ANSIBLE_LOCAL_TEMP) ANSIBLE_REMOTE_TEMP=$(ANSIBLE_REMOTE_TEMP)

-include .env.mk

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-25s\033[0m %s\n", $$1, $$2}'

capture: ## Capture the source node's current state into variable files
	@MANAGED_USER=$(MANAGED_USER) bash scripts/capture.sh $(SOURCE_HOST)

diff: ## Quick SSH-based diff between two machines
	@MANAGED_USER=$(MANAGED_USER) bash scripts/diff-machines.sh $(DIFF_HOST_A) $(DIFF_HOST_B)

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

reboot: ## Reboot DGX Spark nodes (add ANSIBLE_OPTS="-e clean_caches=true" to purge ML caches)
	ansible-playbook -i $(INVENTORY) playbooks/reboot.yml $(ANSIBLE_OPTS)

syntax-check: ## Run Ansible syntax validation
	$(ANSIBLE_ENV) ansible-playbook -i $(INVENTORY) playbooks/site.yml --syntax-check

lint-ansible: ## Run ansible-lint
	$(ANSIBLE_ENV) ansible-lint

lint-yaml: ## Run yamllint
	yamllint .

lint-shell: ## Run shellcheck on project scripts
	shellcheck scripts/*.sh

validate: syntax-check lint-ansible lint-yaml lint-shell ## Run all local validation checks

# Local defaults:      copy .env.mk.example to .env.mk
# Override source:     make capture SOURCE_HOST=real-source
# Override user:       make capture MANAGED_USER=real-admin-user
# Extra ansible opts:  make apply ANSIBLE_OPTS="-v"
