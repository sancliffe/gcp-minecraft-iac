#!/bin/bash
# Take a consistent local backup of the Bedrock world: stop the server, archive
# data/, then start the server again. Run this on the VM.
#
# Usage: backup.sh [SERVER_DIR]
#
# SERVER_DIR is the directory that holds docker-compose.yml and data/. It
# defaults to ~/minecraft-bedrock (where setup-vm.sh installs the server). From a
# clone of the repo, pass the clone's path, e.g. `scripts/backup.sh .`.
# The archive is written to SERVER_DIR as minecraft-backup-<timestamp>.tar.gz.
#
# This is separate from the daily cloud backup that setup-vm.sh schedules, which
# runs while the server is up and uploads to Cloud Storage.
set -euo pipefail

SERVER_DIR="${1:-$HOME/minecraft-bedrock}"

if [ ! -f "$SERVER_DIR/docker-compose.yml" ] || [ ! -d "$SERVER_DIR/data" ]; then
  echo "ERROR: $SERVER_DIR must contain docker-compose.yml and data/." >&2
  echo "Usage: $0 [SERVER_DIR]" >&2
  exit 1
fi

cd "$SERVER_DIR"
ARCHIVE="minecraft-backup-$(date +%F-%H%M%S).tar.gz"

# Always bring the server back, even if tar fails.
restart_server() {
  echo "Restarting Minecraft server..."
  sudo docker compose up -d
}
trap restart_server EXIT

echo "Stopping Minecraft server..."
sudo docker compose down

echo "Creating backup archive $ARCHIVE..."
sudo tar -czf "$ARCHIVE" data/

echo "Backup completed successfully: $SERVER_DIR/$ARCHIVE"
