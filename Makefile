# Terraform lives in terraform/. Override TERRAFORM to use another binary,
# e.g. `make TERRAFORM=tofu fmt-check`.
TERRAFORM ?= terraform
TF_DIR    := terraform
# Set YES=1 to skip the apply confirmation prompt: `make deploy YES=1`.
YES       ?=

.PHONY: deploy init plan apply destroy fmt fmt-check validate shellcheck test check ssh logs

# The one command you need: creates the settings file and state bucket if
# missing, then runs init, import and apply. See scripts/deploy.sh.
deploy:
	TERRAFORM=$(TERRAFORM) ./scripts/deploy.sh $(if $(YES),--yes)

# Needs terraform/minecraft.auto.tfvars (see minecraft.auto.tfvars.example).
init:
	TERRAFORM=$(TERRAFORM) ./scripts/terraform-init.sh

plan:
	$(TERRAFORM) -chdir=$(TF_DIR) plan

apply:
	$(TERRAFORM) -chdir=$(TF_DIR) apply

destroy:
	$(TERRAFORM) -chdir=$(TF_DIR) destroy

# SSH to the VM through IAP, using the command Terraform prints.
ssh:
	@$$($(TERRAFORM) -chdir=$(TF_DIR) output -raw ssh_command_iap)

# Follow the VM's startup script (Docker install and server start) over IAP.
logs:
	@$$($(TERRAFORM) -chdir=$(TF_DIR) output -raw ssh_command_iap) --command 'sudo journalctl -u google-startup-scripts -f'

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
	shellcheck scripts/*.sh tests/*.sh

# Runs scripts/startup.sh and scripts/deploy.sh against stubbed commands. No
# VM, GCP account or Terraform needed.
test:
	./tests/test-startup.sh
	./tests/test-deploy.sh

# Everything CI runs, except the TFLint and tfsec scans.
check: fmt-check validate shellcheck test
