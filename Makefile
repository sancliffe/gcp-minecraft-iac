# Terraform lives in terraform/. Override TERRAFORM to use another binary,
# e.g. `make TERRAFORM=tofu fmt-check`.
TERRAFORM ?= terraform
TF_DIR    := terraform

.PHONY: init plan apply destroy fmt fmt-check validate shellcheck check

# Needs terraform/minecraft.auto.tfvars (see minecraft.auto.tfvars.example).
init:
	TERRAFORM=$(TERRAFORM) ./scripts/terraform-init.sh

plan:
	$(TERRAFORM) -chdir=$(TF_DIR) plan

apply:
	$(TERRAFORM) -chdir=$(TF_DIR) apply

destroy:
	$(TERRAFORM) -chdir=$(TF_DIR) destroy

fmt:
	$(TERRAFORM) fmt -recursive

fmt-check:
	$(TERRAFORM) fmt -check -recursive

# Same as CI: initialises without the remote backend, so no GCP credentials
# are needed.
validate:
	$(TERRAFORM) -chdir=$(TF_DIR) init -backend=false -input=false
	$(TERRAFORM) -chdir=$(TF_DIR) validate

shellcheck:
	shellcheck scripts/*.sh

# Everything CI runs, except the TFLint and tfsec scans.
check: fmt-check validate shellcheck
