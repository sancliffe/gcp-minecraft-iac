#!/bin/bash
# One-command deploy, built for Google Cloud Shell: everything between a fresh
# clone and a running server.
#
# Usage: scripts/deploy.sh [--yes]      (or: make deploy / make deploy YES=1)
#
# It is safe to re-run. It will:
#   1. create terraform/minecraft.auto.tfvars from your gcloud project if missing
#   2. run terraform init (state is local: terraform/terraform.tfstate)
#   3. guard against lost local state, restoring older bucket-stored state if any
#   4. import the backup bucket if it already exists but isn't in the state
#   5. run terraform apply (--yes skips the confirmation prompt)
#
# The VM's startup script then installs Docker, pulls the server image and starts
# the server on its own, so there is no SSH step. Cloud Shell already has gcloud
# (signed in, project selected) and terraform. Set TERRAFORM=tofu to use OpenTofu.
set -euo pipefail

TERRAFORM="${TERRAFORM:-terraform}"
INSTANCE_NAME="free-tier-vm" # keep in sync with google_compute_instance in main.tf
APPLY_ARGS=()
case "${1:-}" in
  "") ;;
  --yes | -y) APPLY_ARGS+=(-auto-approve) ;;
  *)
    echo "Usage: $0 [--yes]" >&2
    exit 2
    ;;
esac

for tool in gcloud "$TERRAFORM"; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: '$tool' is not installed or not on PATH." >&2
    exit 1
  fi
done

cd "$(dirname "${BASH_SOURCE[0]}")/../terraform"
# shellcheck source=lib.sh
source ../scripts/lib.sh

# 1. Settings file
if [ ! -f "$TFVARS" ]; then
  PROJECT_ID=$(gcloud config get-value project 2>/dev/null || true)
  if [ -z "$PROJECT_ID" ] || [ "$PROJECT_ID" = "(unset)" ]; then
    echo "ERROR: no GCP project set. Run 'gcloud config set project <id>', or copy" >&2
    echo "terraform/$TFVARS.example to terraform/$TFVARS and edit it." >&2
    exit 1
  fi
  cat > "$TFVARS" << EOT
project_id         = "$PROJECT_ID"
backup_bucket_name = "${PROJECT_ID}-minecraft-backups"
EOT
  echo "Created terraform/$TFVARS for project $PROJECT_ID."
fi
load_tfvars
if [ -z "$PROJECT_ID" ]; then
  echo "ERROR: project_id is not set in terraform/$TFVARS." >&2
  exit 1
fi
echo "Using project $PROJECT_ID and backup bucket gs://$BUCKET"

# 2. Init. The state is a local file, so this needs no credentials or bucket.
"$TERRAFORM" init -input=false

# 3. Lost-state guard. Capture the lists first: `state list | grep -q` can SIGPIPE
#    under pipefail and report a false "missing".
gcloud services enable storage.googleapis.com --project "$PROJECT_ID"
BUCKET_EXISTS=no
if gcloud storage buckets describe "gs://$BUCKET" --project "$PROJECT_ID" > /dev/null 2>&1; then
  BUCKET_EXISTS=yes
fi

STATE_LIST=$("$TERRAFORM" state list 2>/dev/null || true)

# Older versions of this repo stored the state in the bucket. If the local state
# is empty and a bucket copy exists, bring it back instead of failing later.
OLD_STATE="gs://$BUCKET/terraform/state/default.tfstate"
if [ -z "$STATE_LIST" ] && [ "$BUCKET_EXISTS" = yes ] \
  && gcloud storage ls "$OLD_STATE" --project "$PROJECT_ID" > /dev/null 2>&1; then
  echo "Local state is empty; restoring the state an older version stored in the bucket ..."
  gcloud storage cp "$OLD_STATE" terraform.tfstate --project "$PROJECT_ID"
  STATE_LIST=$("$TERRAFORM" state list 2>/dev/null || true)
fi

if [ -z "$STATE_LIST" ]; then
  EXISTING=$(gcloud compute instances list --project "$PROJECT_ID" \
    --filter="name=$INSTANCE_NAME" --format="value(name)" 2> /dev/null || true)
  if [ -n "$EXISTING" ]; then
    echo "ERROR: the VM '$INSTANCE_NAME' already exists, but Terraform's state is empty." >&2
    echo "The state lives in terraform/terraform.tfstate on the machine that deployed it" >&2
    echo "(Cloud Shell, if it was reset, loses it). Applying now would fail with 409" >&2
    echo "'already exists' errors. Restore terraform/terraform.tfstate from a copy, or" >&2
    echo "delete the old resources (see README, \"Lost Terraform state\") and re-run." >&2
    exit 1
  fi
fi

# 4. Import a bucket that exists but isn't in the state (for example left over
#    from an earlier deploy), so apply doesn't fail with "409 you already own it".
if [ "$BUCKET_EXISTS" = yes ] && ! grep -qx 'google_storage_bucket.minecraft_backups' <<< "$STATE_LIST"; then
  echo "Importing existing bucket into Terraform state ..."
  "$TERRAFORM" import -input=false google_storage_bucket.minecraft_backups "$BUCKET"
fi

# 5. Apply
"$TERRAFORM" apply ${APPLY_ARGS[@]+"${APPLY_ARGS[@]}"}

echo
echo "Done. The VM installs Docker, pulls the server image and starts it by itself;"
echo "allow a few minutes on first boot. Progress:  make logs"
echo "Join with minecraft_address above (IP and port 19132)."
echo "Keep terraform/terraform.tfstate: it is the only record of what was created."
