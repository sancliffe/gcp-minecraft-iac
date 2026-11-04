#!/bin/bash
# Run `terraform init` with the state bucket read from
# terraform/minecraft.auto.tfvars.
#
# Terraform backends cannot read variables or .tfvars files, so this wrapper
# extracts backup_bucket_name (falling back to <project_id>-minecraft-backups)
# and passes it as -backend-config="bucket=...". The remaining backend settings
# (the state prefix) come from terraform/backend.hcl. Extra arguments go to
# terraform init, e.g. ./scripts/terraform-init.sh -reconfigure
#
# Most people want scripts/deploy.sh (make deploy), which also creates the
# bucket and runs apply.
#
# Set TERRAFORM=tofu (or another binary name) to use something other than
# `terraform`. Works from any directory.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../terraform"
# shellcheck source=lib.sh
source ../scripts/lib.sh

load_tfvars

echo "Initialising Terraform with state bucket: $BUCKET"
exec "${TERRAFORM:-terraform}" init -backend-config="bucket=$BUCKET" -backend-config=backend.hcl "$@"
