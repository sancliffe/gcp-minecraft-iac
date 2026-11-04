#!/bin/bash
set -eu

cd "$(dirname "$0")"

echo "Stopping Minecraft server..."
sudo docker compose down

echo "Creating backup archive..."
sudo tar -czf minecraft-backup-$(date +%F-%H%M%S).tar.gz data/

echo "Restarting Minecraft server..."
sudo docker compose up -d

echo "Backup completed successfully!"