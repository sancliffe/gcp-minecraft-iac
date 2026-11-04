#!/bin/bash
# Run this on the VM (not on your own machine) as the user that will manage the server.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="$HOME/minecraft-bedrock"
BACKUP_SCRIPT="$TARGET_DIR/backup.sh"

# Resolve the project ID from the VM's metadata server (no hardcoded fallback),
# then fall back to the gcloud config. Override with PROJECT_ID=... if needed.
if [ -z "${PROJECT_ID:-}" ]; then
  PROJECT_ID=$(curl -fsS -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/project/project-id" 2>/dev/null \
    || gcloud config get-value project 2>/dev/null || true)
fi
if [ -z "$PROJECT_ID" ]; then
  echo "ERROR: could not determine the GCP project ID. Re-run with PROJECT_ID=<id> bash setup-vm.sh" >&2
  exit 1
fi
# Bucket name: BACKUP_BUCKET env override, else the backup-bucket instance metadata
# that Terraform sets from backup_bucket_name, else the default naming pattern.
if [ -z "${BACKUP_BUCKET:-}" ]; then
  BACKUP_BUCKET=$(curl -fsS -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/attributes/backup-bucket" 2>/dev/null \
    || echo "${PROJECT_ID}-minecraft-backups")
fi

echo "=== Initializing Minecraft Bedrock Environment ==="

# 1. Docker is installed by the VM's startup script; fail early if it isn't ready yet.
if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: Docker is not installed yet. The startup script may still be running." >&2
  echo "Check progress with: sudo journalctl -u google-startup-scripts -f" >&2
  exit 1
fi

# 2. Ensure current user has docker permissions (applies after the next login)
sudo usermod -aG docker "$USER" || true

# 3. Create local directories
mkdir -p "$TARGET_DIR/data"

# 4. Install docker-compose.yml. Prefer the copy next to this script so the repo's
#    file stays the single source of truth; otherwise write the default below.
if [ -f "$SCRIPT_DIR/docker-compose.yml" ]; then
  cp "$SCRIPT_DIR/docker-compose.yml" "$TARGET_DIR/docker-compose.yml"
else
  cat << 'EOF' > "$TARGET_DIR/docker-compose.yml"
services:
  minecraft-bedrock:
    image: itzg/minecraft-bedrock-server:latest
    container_name: bedrock-server
    restart: unless-stopped
    network_mode: host
    # Cap container logs so they can't fill the 30 GB boot disk.
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    environment:
      EULA: "TRUE"
      SERVER_NAME: "Steanlabs Minecraft"
      DIFFICULTY: "normal"
      GAMEMODE: "survival"
      TRANSPORT: "nethernet"
      SERVER_PORT: "19132"
      SERVER_PORTV6: "19133"
      SERVER_UDP_PORTS: "19140-19150"
    volumes:
      - ./data:/data
EOF
fi

# 5. Write the backup script. Backups go under backups/ in the bucket, which is the
#    prefix the Terraform lifecycle rule expires after 30 days.
cat << EOF > "$BACKUP_SCRIPT"
#!/bin/bash
set -euo pipefail

STAMP=\$(date +%F)
ARCHIVE=\$(mktemp --suffix=".tar.gz")
trap 'rm -f "\$ARCHIVE"' EXIT

tar -czf "\$ARCHIVE" -C "$TARGET_DIR" data
gcloud storage cp "\$ARCHIVE" "gs://$BACKUP_BUCKET/backups/world-backup-\$STAMP.tar.gz"
EOF
chmod 755 "$BACKUP_SCRIPT"

# 6. Schedule the backup daily at 4:00 AM (idempotent: replaces any previous entry)
CRON_LINE="0 4 * * * $BACKUP_SCRIPT >> $TARGET_DIR/backup.log 2>&1"
( crontab -l 2>/dev/null | grep -vF "$BACKUP_SCRIPT" || true; echo "$CRON_LINE" ) | crontab -

echo "=== Starting Server Container ==="
cd "$TARGET_DIR"
sudo docker compose up -d

echo "=== Setup Complete ==="
echo "Server directory: $TARGET_DIR"
echo "Cloud backup target: gs://$BACKUP_BUCKET/backups/"
echo "Daily backup scheduled for 4:00 AM (log: $TARGET_DIR/backup.log)."
