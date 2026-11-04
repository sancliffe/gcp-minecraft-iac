#!/usr/bin/env bash
# ==============================================================================
# Script Name: setup-minecraft.sh
# Description: Automates directory setup, container deployment, persistent
#              storage, and backup automation for a GCP Minecraft server.
# ==============================================================================

set -euo pipefail

# Configuration Variables
MINECRAFT_HOME="${MINECRAFT_HOME:-/opt/minecraft}"
BACKUP_DIR="${MINECRAFT_HOME}/backups"
WORLD_DATA_DIR="${MINECRAFT_HOME}/data"
CONTAINER_RUNTIME=""
GCS_BUCKET="${GCS_BUCKET:-}"

# Colors for output
GREEN="\e[32m"
YELLOW="\e[33m"
RED="\e[31m"
RESET="\e[0m"

log_info() { echo -e "${GREEN}[INFO]${RESET} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${RESET} $1"; }
log_error() { echo -e "${RED}[ERROR]${RESET} $1"; }

# 1. Check Root Privileges
if [[ $EUID -ne 0 ]]; then
   log_error "This script must be run as root or with sudo privileges."
   exit 1
fi

# 2. Detect Container Runtime (Podman preferred, fallback to Docker)
if command -v podman &> /dev/null; then
    CONTAINER_RUNTIME="podman"
    log_info "Detected container runtime: Podman"
elif command -v docker &> /dev/null; then
    CONTAINER_RUNTIME="docker"
    log_info "Detected container runtime: Docker"
else
    log_error "Neither Podman nor Docker is installed. Please install one and retry."
    exit 1
fi

# 3. Create Required Directory Structure
log_info "Creating directory structure at ${MINECRAFT_HOME}..."
mkdir -p "${WORLD_DATA_DIR}"
mkdir -p "${BACKUP_DIR}"
chmod 755 "${MINECRAFT_HOME}"

# 4. Generate Docker Compose File
log_info "Generating optimized Compose configuration..."
cat << 'EOF' > "${MINECRAFT_HOME}/docker-compose.yml"
services:
  minecraft:
    image: itzg/minecraft-server:latest
    container_name: minecraft-server
    restart: unless-stopped
    ports:
      - "25565:25565"
      - "19132:19132/udp"
    environment:
      EULA: "TRUE"
      VERSION: "LATEST"
      TYPE: "PAPER"
      MEMORY: "2G"
      ENABLE_RCON: "true"
      RCON_PASSWORD: "changeme_secure_rcon"
    volumes:
      - ./data:/data
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF

log_info "Docker compose file written to ${MINECRAFT_HOME}/docker-compose.yml"

# 5. Create Backup Script
log_info "Creating automated backup script..."
cat << 'EOF' > "${MINECRAFT_HOME}/backup-world.sh"
#!/usr/bin/env bash
set -euo pipefail
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_PATH="/opt/minecraft/backups/minecraft_world_${TIMESTAMP}.tar.gz"
CONTAINER_NAME="minecraft-server"

echo "Starting Minecraft backup at ${TIMESTAMP}..."

# Save-lock via RCON if container is running
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    docker exec ${CONTAINER_NAME} rcon-cli save-off
    docker exec ${CONTAINER_NAME} rcon-cli save-all
    sleep 3
fi

# Create archive
tar -czf "${BACKUP_PATH}" -C /opt/minecraft data

# Resume saves
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    docker exec ${CONTAINER_NAME} rcon-cli save-on
fi

echo "Backup completed successfully: ${BACKUP_PATH}"

# Optional: Upload to GCS if bucket is configured
if [[ -n "${GCS_BUCKET:-}" ]]; then
    gsutil cp "${BACKUP_PATH}" "gs://${GCS_BUCKET}/minecraft-backups/"
    echo "Uploaded backup to gs://${GCS_BUCKET}/minecraft-backups/"
fi

# Retention policy: Keep local backups for 7 days
find /opt/minecraft/backups/ -type f -name "*.tar.gz" -mtime +7 -delete
EOF

chmod +x "${MINECRAFT_HOME}/backup-world.sh"

# 6. Setup Systemd Timer for Automated Daily Backups
log_info "Configuring systemd timer for automated backups..."
cat << 'EOF' > /etc/systemd/system/minecraft-backup.service
[Unit]
Description=Automated Minecraft World Backup Service
After=network.target

[Service]
Type=oneshot
ExecStart=/opt/minecraft/backup-world.sh
EOF

cat << 'EOF' > /etc/systemd/system/minecraft-backup.timer
[Unit]
Description=Run Minecraft Backup Daily
Requires=minecraft-backup.service

[Timer]
Unit=minecraft-backup.service
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now minecraft-backup.timer
log_info "Systemd backup timer enabled successfully."

log_info "Setup complete! Navigate to ${MINECRAFT_HOME} and run '${CONTAINER_RUNTIME} compose up -d' to start your server."
