#!/bin/bash
# One-command deploy: everything between a fresh clone and a running server.
#
# Usage: scripts/deploy.sh [--yes]      (or: make deploy / make deploy YES=1)
#
# It is safe to re-run. It will:
#   1. create terraform/minecraft.auto.tfvars from your gcloud project if missing
#   2. enable the Cloud Storage API and create the backup bucket if missing
#   3. run terraform init for the local backend
#   4. import the backup bucket into the local Terraform state if it isn't tracked yet
#   5. run terraform apply (--yes skips the confirmation prompt)
#
# The VM's startup script then installs Docker and starts the server on its own,
# so there is no SSH step. Needs `gcloud` (authenticated, with application
# default credentials) and `terraform`. Set TERRAFORM=tofu to use OpenTofu.
set -euo pipefail

TERRAFORM="${TERRAFORM:-terraform}"
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
  cat > "$TFVARS" << EOF
project_id         = "$PROJECT_ID"
backup_bucket_name = "${PROJECT_ID}-minecraft-backups"
EOF
  echo "Created terraform/$TFVARS for project $PROJECT_ID."
fi
load_tfvars
if [ -z "$PROJECT_ID" ]; then
  echo "ERROR: project_id is not set in terraform/$TFVARS." >&2
  exit 1
fi

# 2. Backup bucket. Ensure the GCS bucket for world backups exists in GCP.
BUCKET_LOCATION=$(tfvar bucket_location)
BUCKET_LOCATION="${BUCKET_LOCATION:-US}"
echo "Using project $PROJECT_ID and backup bucket gs://$BUCKET ($BUCKET_LOCATION)"
gcloud services enable storage.googleapis.com --project "$PROJECT_ID"
if ! gcloud storage buckets describe "gs://$BUCKET" --project "$PROJECT_ID" >/dev/null 2>&1; then
  echo "Creating backup bucket gs://$BUCKET ..."
  gcloud storage buckets create "gs://$BUCKET" --project "$PROJECT_ID" \
    --location="$BUCKET_LOCATION" --uniform-bucket-level-access --public-access-prevention
fi

# 3. Init (Local backend)
"$TERRAFORM" init -input=false -reconfigure

# 4. Import the bucket into local state if it exists in GCP but isn't tracked yet,
#    preventing 409 "already exists" conflicts during apply.
STATE_LIST=$("$TERRAFORM" state list 2>/dev/null || true)
if ! grep -qx 'google_storage_bucket.minecraft_backups' <<< "$STATE_LIST"; then
  if gcloud storage buckets describe "gs://$BUCKET" --project "$PROJECT_ID" >/dev/null 2>&1; then
    echo "Importing existing bucket into local Terraform state..."
    "$TERRAFORM" import -input=false google_storage_bucket.minecraft_backups "$BUCKET"
  fi
fi

# 5. Apply
"$TERRAFORM" apply ${APPLY_ARGS[@]+"${APPLY_ARGS[@]}"}

echo
echo "Done. The VM installs Docker and starts the server by itself; allow a few"
echo "minutes on first boot. Progress:  make logs"
echo "Join with the static_external_ip above, port 19132."