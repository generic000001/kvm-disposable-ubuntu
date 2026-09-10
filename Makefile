SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

REPO_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
TERRAFORM_DIR := $(REPO_ROOT)/terraform
OFFLINE_TFRC := $(REPO_ROOT)/.cache/terraform/terraformrc.offline.tfrc

ifdef OFFLINE
export TF_CLI_CONFIG_FILE := $(OFFLINE_TFRC)
endif

.PHONY: help check bootstrap download-image verify-image prepare-offline offline-check init fmt validate plan create status ip ssh cloud-init-status destroy rebuild clean purge-cache export-offline-bundle verify-offline-bundle remove-host-tools lint

help: ## Show available targets
	@awk 'BEGIN {FS = ":.*## "}; /^[a-zA-Z0-9_.-]+:.*## / {printf "\033[36m%-24s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

check: ## Run repository checks without provisioning
	@bash -n bootstrap.sh remove-host-tools.sh scripts/*.sh
	@./scripts/check-prerequisites.sh --advisory
	@$(MAKE) lint
	@if command -v terraform >/dev/null 2>&1; then terraform -chdir=$(TERRAFORM_DIR) fmt -check; else echo "[WARN] terraform not installed; skipping terraform fmt -check"; fi
	@if command -v terraform >/dev/null 2>&1; then terraform -chdir=$(TERRAFORM_DIR) init -backend=false >/dev/null; else echo "[WARN] terraform not installed; skipping terraform init -backend=false"; fi
	@if command -v terraform >/dev/null 2>&1; then terraform -chdir=$(TERRAFORM_DIR) validate; else echo "[WARN] terraform not installed; skipping terraform validate"; fi
	@if command -v python3 >/dev/null 2>&1; then python3 -c 'import importlib.util, pathlib, sys; spec = importlib.util.find_spec("yaml"); sys.exit(print("[WARN] PyYAML not installed; skipping YAML validation") or 0) if spec is None else None; yaml = __import__("yaml"); [yaml.safe_load(pathlib.Path(path).read_text()) for path in ("terraform/cloud-init/meta-data.yaml.tftpl", "terraform/cloud-init/network-config.yaml.tftpl")]; print("[INFO] Static YAML validation passed")'; else echo "[WARN] python3 not installed; skipping YAML validation"; fi

bootstrap: ## Install and configure host tooling idempotently
	@./bootstrap.sh

download-image: ## Download the official Ubuntu cloud image into the local cache
	@./scripts/download-image.sh $(ARGS)

verify-image: ## Verify the cached Ubuntu cloud image checksum
	@./scripts/verify-image.sh

prepare-offline: ## Populate the image cache and provider mirror for offline use
	@./scripts/prepare-offline.sh

offline-check: ## Verify that offline prerequisites are present locally
	@test -f $(OFFLINE_TFRC) || { echo "[ERROR] Missing $(OFFLINE_TFRC). Run make prepare-offline first."; exit 1; }
	@./scripts/offline-check.sh $(if $(MODE),$(MODE),auto)
	@TF_CLI_CONFIG_FILE=$(OFFLINE_TFRC) terraform -chdir=$(TERRAFORM_DIR) init -backend=false -lockfile=readonly
	@TF_CLI_CONFIG_FILE=$(OFFLINE_TFRC) terraform -chdir=$(TERRAFORM_DIR) validate

init: ## Initialise Terraform in the terraform/ directory
	@terraform -chdir=$(TERRAFORM_DIR) init -backend=false
	@./scripts/record-terraform-pool-dir.sh >/dev/null

fmt: ## Format Terraform files
	@terraform -chdir=$(TERRAFORM_DIR) fmt

validate: ## Validate the Terraform configuration
	@terraform -chdir=$(TERRAFORM_DIR) validate

plan: ## Create an execution plan without applying it
	@terraform -chdir=$(TERRAFORM_DIR) plan -out=tfplan

create: ## Apply the Terraform configuration interactively
	@./scripts/record-terraform-pool-dir.sh >/dev/null
	@terraform -chdir=$(TERRAFORM_DIR) apply

status: ## Show VM and environment status
	@./scripts/status.sh

ip: ## Discover the VM IP address
	@./scripts/discover-vm-ip.sh

ssh: ## Connect to the VM over SSH
	@mkdir -p $(REPO_ROOT)/.cache && VM_IP="$$(./scripts/discover-vm-ip.sh)" && VM_USER="$$(terraform -chdir=$(TERRAFORM_DIR) output -raw ssh_username 2>/dev/null || printf '%s\n' ubuntu)" && exec ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$(REPO_ROOT)/.cache/known_hosts "$${VM_USER}@$$VM_IP"

cloud-init-status: ## Wait for or display cloud-init status
	@./scripts/wait-for-cloud-init.sh $(ARGS)

destroy: ## Destroy only Terraform-managed infrastructure interactively
	@./scripts/record-terraform-pool-dir.sh >/dev/null
	@terraform -chdir=$(TERRAFORM_DIR) destroy

rebuild: ## Destroy and recreate the VM after explicit confirmation
	@read -r -p "This will destroy and recreate the Terraform-managed VM. Continue [y/N]: " response; [[ "$$response" =~ ^[Yy]([Ee][Ss])?$$ ]] || exit 1; $(MAKE) destroy && $(MAKE) create

clean: ## Remove local generated project artefacts without touching Terraform state or managed disks
	@rm -rf $(TERRAFORM_DIR)/.terraform
	@rm -f $(TERRAFORM_DIR)/tfplan $(TERRAFORM_DIR)/*.log
	@rm -rf $(REPO_ROOT)/.tmp

purge-cache: ## Remove local caches and cached images after confirmation
	@read -r -p "Purge provider caches and cached images from this repository [y/N]: " response; [[ "$$response" =~ ^[Yy]([Ee][Ss])?$$ ]] || exit 1; rm -rf $(REPO_ROOT)/.cache $(REPO_ROOT)/images/*.img $(REPO_ROOT)/images/*.SHA256SUMS $(REPO_ROOT)/images/*.SHA256SUMS.gpg $(REPO_ROOT)/images/*.metadata.json $(REPO_ROOT)/images/*.qcow2

export-offline-bundle: ## Export a local offline bundle archive
	@./scripts/export-offline-bundle.sh

verify-offline-bundle: ## Verify the newest offline bundle or the bundle passed as ARGS
	@./scripts/verify-offline-bundle.sh $(ARGS)

remove-host-tools: ## Interactively remove host tooling recorded by this repository
	@./remove-host-tools.sh

lint: ## Run ShellCheck if it is installed
	@if command -v shellcheck >/dev/null 2>&1; then shellcheck bootstrap.sh remove-host-tools.sh scripts/*.sh; else echo "[WARN] shellcheck not installed; skipping ShellCheck"; fi
