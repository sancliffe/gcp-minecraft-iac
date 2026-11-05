#!/bin/bash
# Test scripts/startup.sh without a VM. The script runs for real against a
# scratch directory (STARTUP_ROOT); the system commands it calls (apt-get,
# systemctl, docker, curl for the metadata server, ...) are replaced by stubs
# that record their arguments. Run it with `make test`.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

STUBS="$WORK/stubs"
CALLS="$WORK/calls.log"
mkdir -p "$STUBS"
: > "$CALLS"

# Stubs that only record that they ran.
for cmd in sshd apt-get mkswap swapon dpkg systemctl; do
  printf '#!/bin/bash\necho "%s $*" >> "%s"\n' "$cmd" "$CALLS" > "$STUBS/$cmd"
done
# fallocate: record, and create an empty file (the last argument) like the real one.
# shellcheck disable=SC2016  # the $ expressions are meant for the stub, not this shell
printf '#!/bin/bash\necho "fallocate $*" >> "%s"\ntouch "${*: -1}"\n' "$CALLS" > "$STUBS/fallocate"
# chown: records its arguments and whether allowlist.json and server.properties
# already exist in the target directory (the script must chown after writing them).
cat > "$STUBS/chown" << STUB
#!/bin/bash
dir="\${*: -1}"
present=no
[ -f "\$dir/allowlist.json" ] && [ -f "\$dir/server.properties" ] && present=yes
echo "chown \$* [files_present=\$present]" >> "$CALLS"
STUB
# docker: present, so the install step is skipped; records its arguments. Set
# STUB_PULL_FAIL=1 to make `compose pull` fail like an unreachable registry.
cat > "$STUBS/docker" << STUB
#!/bin/bash
echo "docker \$*" >> "$CALLS"
if [ "\$*" = "compose pull --quiet" ] && [ "\${STUB_PULL_FAIL:-0}" = 1 ]; then exit 1; fi
exit 0
STUB
# curl: stands in for the metadata server. The last argument is the URL.
cat > "$STUBS/curl" << STUB
#!/bin/bash
url="\${*: -1}"
case "\$url" in
  */docker-compose-yml) cat "$REPO/docker-compose.yml" ;;
  */allowlist-json)     cat "$REPO/data/allowlist.json" ;;
  */server-properties)  cat "$REPO/data/server.properties" ;;
  */server-image)       printf 'example/img:1.2.3' ;;
  */backup-bucket)      printf 'test-bucket' ;;
  *) echo "unexpected curl: \$url" >&2; exit 22 ;;
esac
STUB
chmod +x "$STUBS"/*

export STARTUP_ROOT="$WORK/root"
export PATH="$STUBS:$PATH"
mkdir -p "$STARTUP_ROOT"

fail() { echo "FAIL: $*" >&2; exit 1; }
check() { # check "description" command...
  local desc="$1"
  shift
  "$@" || fail "$desc"
  echo "ok   $desc"
}
calls_contain() { grep -qF -- "$1" "$CALLS"; }

# --- first boot -------------------------------------------------------------
bash "$REPO/scripts/startup.sh" > "$WORK/run1.log" 2>&1 || { cat "$WORK/run1.log"; fail "first run exited non-zero"; }
echo "ok   first boot completes"

R="$STARTUP_ROOT"
check "sshd hardening written" grep -q 'PermitRootLogin no' "$R/etc/ssh/sshd_config.d/10-hardening.conf"
check "sshd reloaded after config check" calls_contain "systemctl reload ssh"
check "swapfile enabled" calls_contain "swapon $R/swapfile"
check "swapfile in fstab" grep -qF "$R/swapfile none swap" "$R/etc/fstab"
check "compose file written from metadata" cmp -s "$REPO/docker-compose.yml" "$R/opt/minecraft/docker-compose.yml"
check "allowlist seeded from metadata" cmp -s "$REPO/data/allowlist.json" "$R/opt/minecraft/data/allowlist.json"
check "backup script installed and executable" test -x "$R/usr/local/bin/minecraft-backup"
check "backup script is valid bash" bash -n "$R/usr/local/bin/minecraft-backup"
check "backup uploads under backups/" grep -q 'backups/world-backup-' "$R/usr/local/bin/minecraft-backup"
# shellcheck disable=SC2016  # matching the literal text $(date ...) in the generated script
check "backup name includes the time (no same-day overwrite)" grep -qF 'world-backup-$(date +%F-%H%M%S)' "$R/usr/local/bin/minecraft-backup"
check "backup timer unit written" grep -q 'OnCalendar=' "$R/etc/systemd/system/minecraft-backup.timer"
check "backup timer enabled" calls_contain "systemctl enable --now minecraft-backup.timer"
check "server.properties written from metadata" cmp -s "$REPO/data/server.properties" "$R/opt/minecraft/data/server.properties"
check "image reference written to .env" grep -qx 'MC_IMAGE=example/img:1.2.3' "$R/opt/minecraft/.env"
check "data directory handed to UID 999" calls_contain "chown -R 999:999 $R/opt/minecraft/data"
check "chown ran after the files were written" calls_contain "files_present=yes"
check "image pulled before the server starts" test "$(grep -n 'docker compose pull --quiet' "$CALLS" | head -1 | cut -d: -f1)" -lt "$(grep -n 'docker compose up -d' "$CALLS" | head -1 | cut -d: -f1)"
check "server started with docker compose" calls_contain "docker compose up -d"

# --- second boot: idempotent, keeps player edits to the allowlist ----------------
echo '[{"name":"added-in-game"}]' > "$R/opt/minecraft/data/allowlist.json"
echo '# stale local edit' >> "$R/opt/minecraft/docker-compose.yml"
echo 'max-players=99' >> "$R/opt/minecraft/data/server.properties"
: > "$CALLS"
bash "$REPO/scripts/startup.sh" > "$WORK/run2.log" 2>&1 || { cat "$WORK/run2.log"; fail "second run exited non-zero"; }
echo "ok   second boot completes"
check "allowlist edits survive a reboot" grep -q 'added-in-game' "$R/opt/minecraft/data/allowlist.json"
check "compose file is refreshed from metadata" cmp -s "$REPO/docker-compose.yml" "$R/opt/minecraft/docker-compose.yml"
check "server.properties is refreshed from metadata" cmp -s "$REPO/data/server.properties" "$R/opt/minecraft/data/server.properties"
check "swapfile not recreated" test "$(grep -c '^fallocate' "$CALLS")" -eq 0
check "fstab has one swap entry" test "$(grep -c "$R/swapfile" "$R/etc/fstab")" -eq 1

# --- a failed image pull must not keep the server down -----------------------------
: > "$CALLS"
STUB_PULL_FAIL=1 bash "$REPO/scripts/startup.sh" > "$WORK/run-pullfail.log" 2>&1 || { cat "$WORK/run-pullfail.log"; fail "run exited non-zero when the pull failed"; }
echo "ok   boot completes when the pull fails"
check "pull failure warned" grep -q 'could not pull the image' "$WORK/run-pullfail.log"
check "server still started with the cached image" calls_contain "docker compose up -d"

# --- upgrade from the old setup-vm.sh layout keeps the world ---------------------
rm -rf "$STARTUP_ROOT"
mkdir -p "$R/home/alice/minecraft-bedrock/data/worlds/Bedrock level"
echo "world-bytes" > "$R/home/alice/minecraft-bedrock/data/worlds/Bedrock level/level.dat"
echo '[{"name":"old-player"}]' > "$R/home/alice/minecraft-bedrock/data/allowlist.json"
: > "$CALLS"
bash "$REPO/scripts/startup.sh" > "$WORK/run-migrate.log" 2>&1 || { cat "$WORK/run-migrate.log"; fail "migration run exited non-zero"; }
echo "ok   upgrade run completes"
check "old container stopped first" calls_contain "docker compose down"
check "world moved to /opt/minecraft" grep -q world-bytes "$R/opt/minecraft/data/worlds/Bedrock level/level.dat"
check "old allowlist kept, not overwritten by seed" grep -q old-player "$R/opt/minecraft/data/allowlist.json"
check "old data directory is gone" test ! -e "$R/home/alice/minecraft-bedrock/data"
check "server started after migration" calls_contain "docker compose up -d"
: > "$CALLS"
bash "$REPO/scripts/startup.sh" > "$WORK/run-migrate2.log" 2>&1 || fail "run after migration exited non-zero"
check "no second migration" test "$(grep -c 'docker compose down' "$CALLS")" -eq 0

# --- failure: metadata unreachable must fail loudly, not start a bad server ------
rm -rf "$STARTUP_ROOT"
mkdir -p "$STARTUP_ROOT"
printf '#!/bin/bash\nexit 22\n' > "$STUBS/curl"
: > "$CALLS"
if bash "$REPO/scripts/startup.sh" > "$WORK/run3.log" 2>&1; then
  fail "script should fail when metadata is unreachable"
fi
echo "ok   fails when metadata is unreachable"
check "server not started after failure" test "$(grep -c 'docker compose up' "$CALLS")" -eq 0

echo "All startup.sh tests passed."
