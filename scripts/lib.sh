# shellcheck shell=bash
# Shared helpers, sourced by deploy.sh. Not run directly.
#
# Expects the caller to have cd'd into the terraform/ directory.

TFVARS="minecraft.auto.tfvars"

# Print the quoted string value of a top-level `name = "value"` line in $TFVARS.
tfvar() {
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$TFVARS" | head -n1
}

# Set PROJECT_ID and BUCKET from $TFVARS. The bucket falls back to
# <project_id>-minecraft-backups, the same default main.tf uses.
load_tfvars() {
  if [ ! -f "$TFVARS" ]; then
    echo "ERROR: terraform/$TFVARS not found. Copy terraform/$TFVARS.example to terraform/$TFVARS and edit it." >&2
    return 1
  fi

  PROJECT_ID=$(tfvar project_id)
  BUCKET=$(tfvar backup_bucket_name)
  if [ -z "$BUCKET" ]; then
    if [ -z "$PROJECT_ID" ]; then
      echo "ERROR: set backup_bucket_name (or project_id) in $TFVARS." >&2
      return 1
    fi
    BUCKET="${PROJECT_ID}-minecraft-backups"
  fi
}
