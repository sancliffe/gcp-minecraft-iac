#!/bin/bash
# VM startup script. Terraform passes this file to the instance as its startup
# script, and Google Compute Engine runs it as root on every boot. It is safe to
# re-run: every step checks before it changes anything.
#
# It hardens sshd, adds swap, installs Docker and the Ops Agent, writes the
# server files from instance metadata, schedules the daily Cloud Storage backup,
# and starts the Minecraft container. No SSH session is needed to bring the
# server up.
#
# Progress: sudo journalctl -u google-startup-scripts -f
set -euo pipefail

# ROOT is empty on the VM. tests/test-startup.sh points it at a scratch
# directory so the file-writing steps can run without touching the host.
ROOT="${STARTUP_ROOT:-}"
MC_DIR="$ROOT/opt/minecraft"
SWAPFILE="$ROOT/swapfile"
META_URL="http://metadata.google.internal/computeMetadata/v1/instance/attributes"

# Print one instance metadata attribute. Terraform sets these (see main.tf).
meta() {
  curl -fsS -H "Metadata-Flavor: Google" "$META_URL/$1"
}

# 0. Harden sshd. OS Login handles authentication, so password and root logins
#    are never needed. Keyboard-interactive is left alone because OS Login 2FA
#    uses it. The config is validated before sshd reloads.
install -d -m 0755 "$ROOT/etc/ssh/sshd_config.d"
printf '%s\n' \
  'PermitRootLogin no' \
  'PasswordAuthentication no' \
  'PermitEmptyPasswords no' \
  'X11Forwarding no' \
  'AllowAgentForwarding no' \
  'MaxAuthTries 3' \
  'LoginGraceTime 30' \
  > "$ROOT/etc/ssh/sshd_config.d/10-hardening.conf"
if sshd -t; then
  systemctl reload ssh
else
  rm -f "$ROOT/etc/ssh/sshd_config.d/10-hardening.conf"
fi

# 1. 1 GB swap. Read /proc/swaps instead of piping swapon into grep: with
#    pipefail, grep -q closing the pipe early can make that pipeline "fail".
if [ ! -f "$SWAPFILE" ]; then
  fallocate -l 1G "$SWAPFILE"
  chmod 600 "$SWAPFILE"
  mkswap "$SWAPFILE"
  swapon "$SWAPFILE"
  echo "$SWAPFILE none swap sw 0 0" >> "$ROOT/etc/fstab"
elif ! grep -q "$SWAPFILE" /proc/swaps; then
  swapon "$SWAPFILE"
fi

# 2. Docker and unattended upgrades
apt-get update -qq
apt-get install -y -qq unattended-upgrades ca-certificates curl gnupg

if ! command -v docker >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  # shellcheck disable=SC1091  # /etc/os-release only exists on the VM
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null

  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

# 3a. One-time migration from the old layout. Before this script existed, the
#     server was started by hand with setup-vm.sh in ~/minecraft-bedrock. Stop
#     that container (it would clash on the name and ports) and move its world
#     here, so upgrading an existing VM keeps the world. Skipped once
#     $MC_DIR/data/worlds exists. The old cron backup entry is not touched:
#     remove it with `crontab -e` (see the README).
if [ ! -e "$MC_DIR/data/worlds" ]; then
  for legacy in "$ROOT"/home/*/minecraft-bedrock; do
    [ -d "$legacy/data/worlds" ] || continue
    echo "Migrating existing world from $legacy to $MC_DIR"
    (cd "$legacy" && docker compose down) || true
    install -d -m 0755 "$MC_DIR"
    rm -rf "${MC_DIR:?}/data"
    mv "$legacy/data" "$MC_DIR/data"
    break
  done
fi

# 3. Server files, from instance metadata (Terraform copies docker-compose.yml
#    and data/allowlist.json from this repo). The compose file is rewritten on
#    every boot so the repo stays the source of truth. The allowlist is only
#    seeded once, because the server edits it when you run `allowlist add`.
install -d -m 0755 "$MC_DIR" "$MC_DIR/data"
meta docker-compose-yml > "$MC_DIR/docker-compose.yml.new"
mv "$MC_DIR/docker-compose.yml.new" "$MC_DIR/docker-compose.yml"
if [ ! -f "$MC_DIR/data/allowlist.json" ]; then
  meta allowlist-json > "$MC_DIR/data/allowlist.json"
fi

# 4. Daily world backup to Cloud Storage at 04:00 (VM time, which is UTC). Backups
#    go under backups/, the prefix the bucket's lifecycle rule expires after
#    30 days. The script reads the bucket name from metadata when it runs.
install -d -m 0755 "$ROOT/usr/local/bin" "$ROOT/etc/systemd/system"
cat > "$ROOT/usr/local/bin/minecraft-backup" << 'EOF'
#!/bin/bash
set -euo pipefail
BUCKET=$(curl -fsS -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/attributes/backup-bucket")
ARCHIVE=$(mktemp --suffix=".tar.gz")
trap 'rm -f "$ARCHIVE"' EXIT
tar -czf "$ARCHIVE" -C /opt/minecraft data
gcloud storage cp "$ARCHIVE" "gs://$BUCKET/backups/world-backup-$(date +%F).tar.gz"
EOF
chmod 755 "$ROOT/usr/local/bin/minecraft-backup"

cat > "$ROOT/etc/systemd/system/minecraft-backup.service" << 'EOF'
[Unit]
Description=Back up the Minecraft world to Cloud Storage

[Service]
Type=oneshot
ExecStart=/usr/local/bin/minecraft-backup
EOF

cat > "$ROOT/etc/systemd/system/minecraft-backup.timer" << 'EOF'
[Unit]
Description=Daily Minecraft world backup

[Timer]
OnCalendar=*-*-* 04:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now minecraft-backup.timer

# 5. Start (or update) the server. This is a no-op when nothing changed.
(cd "$MC_DIR" && docker compose up -d)

# 6. Google Cloud Ops Agent. Last, so a failure here cannot keep the server down.
if ! dpkg -s google-cloud-ops-agent >/dev/null 2>&1; then
  curl -sSO https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh
  bash add-google-cloud-ops-agent-repo.sh --also-install
fi
