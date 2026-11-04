#!/bin/bash
# Run `terraform init` with the state bucket read from minecraft.auto.tfvars.
#
# Terraform backends cannot read variables or .tfvars files, so this wrapper
# extracts backup_bucket_name (falling back to <project_id>-minecraft-backups)
# and passes it as -backend-config="bucket=...". The remaining backend settings
# (the state prefix) come from backend.hcl. Extra arguments go to terraform init,
# e.g. ./terraform-init.sh -reconfigure
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
TFVARS="minecraft.auto.tfvars"

# Print the quoted string value of a top-level `name = "value"` line in $TFVARS.
tfvar() {
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$TFVARS" | head -n1
}

if [ ! -f "$TFVARS" ]; then
  echo "ERROR: $TFVARS not found." >&2
  exit 1
fi

BUCKET=$(tfvar backup_bucket_name)
if [ -z "$BUCKET" ]; then
  PROJECT_ID=$(tfvar project_id)
  if [ -z "$PROJECT_ID" ]; then
    echo "ERROR: set backup_bucket_name (or project_id) in $TFVARS." >&2
    exit 1
  fi
  BUCKET="${PROJECT_ID}-minecraft-backups"
fi

echo "Initialising Terraform with state bucket: $BUCKET"
exec terraform init -backend-config="bucket=$BUCKET" -backend-config=backend.hcl "$@"
