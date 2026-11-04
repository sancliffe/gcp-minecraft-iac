#!/bin/bash
set -euo pipefail

BACKUP_DIR="/tmp/minecraft-backup"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
ARCHIVE_NAME="minecraft-backup-$TIMESTAMP.tar.gz"
BUCKET="gs://steanlabs-web-minecraft-backups/backups"

mkdir -p "$BACKUP_DIR"
echo "Creating archive of world data..."
tar -czf "$BACKUP_DIR/$ARCHIVE_NAME" -C ~/git-projects/gcp-minecraft/data .

echo "Uploading to Google Cloud Storage..."
gsutil cp "$BACKUP_DIR/$ARCHIVE_NAME" "$BUCKET/$ARCHIVE_NAME"

echo "Cleaning up local temporary backup..."
rm -rf "$BACKUP_DIR/$ARCHIVE_NAME"
echo "Backup completed successfully: $ARCHIVE_NAME"