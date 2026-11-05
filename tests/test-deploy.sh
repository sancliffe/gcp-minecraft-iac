#!/bin/bash
# Test scripts/deploy.sh without GCP. gcloud and terraform are replaced by stubs
# that record their arguments, and the script runs in a scratch copy of the repo
# because it writes terraform/minecraft.auto.tfvars. Run it with `make test`.
#
# Stub controls (environment variables):
#   STUB_PROJECT          project printed by `gcloud config get-value project`
#   STUB_BUCKET_EXISTS    yes: the backup bucket exists
#   STUB_REMOTE_STATE     yes: gs://<bucket>/terraform/state/default.tfstate exists
#   STUB_VM_EXISTS        yes: the VM exists
#   STUB_STATE            resource addresses in the Terraform state ("state list")
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

STUBS="$WORK/stubs"
CALLS="$WORK/calls.log"
RESTORED="$WORK/restored-state"
mkdir -p "$STUBS"

cat > "$STUBS/gcloud" << STUB
#!/bin/bash
echo "gcloud \$*" >> "$CALLS"
rc=0
case "\$*" in
  "config get-value project") printf '%s\n' "\${STUB_PROJECT:-}" ;;
  "storage buckets describe"*) [ "\${STUB_BUCKET_EXISTS:-no}" = yes ] || rc=1 ;;
  "storage ls "*) [ "\${STUB_REMOTE_STATE:-no}" = yes ] || rc=1 ;;
  "storage cp "*) echo google_storage_bucket.minecraft_backups > "$RESTORED" ;;
  "compute instances list"*) [ "\${STUB_VM_EXISTS:-no}" = yes ] && echo free-tier-vm ;;
esac
exit \$rc
STUB
cat > "$STUBS/terraform" << STUB
#!/bin/bash
echo "terraform \$*" >> "$CALLS"
case "\$1" in
  state)
    cat "$RESTORED" 2>/dev/null || true
    [ -n "\${STUB_STATE:-}" ] && printf '%s\n' "\$STUB_STATE"
    exit 0
    ;;
esac
STUB
chmod +x "$STUBS"/*
export PATH="$STUBS:$PATH"

fail() { echo "FAIL: $*" >&2; exit 1; }
check() {
  local desc="$1"
  shift
  "$@" || fail "$desc"
  echo "ok   $desc"
}
calls_contain() { grep -qF -- "$1" "$CALLS"; }
calls_lack() { ! grep -qF -- "$1" "$CALLS"; }

# Fresh scratch copy of the repo pieces the script touches.
fresh_repo() {
  rm -rf "$WORK/repo" "$RESTORED"
  mkdir -p "$WORK/repo"
  cp -r "$REPO/scripts" "$REPO/terraform" "$WORK/repo/"
  rm -f "$WORK/repo/terraform/minecraft.auto.tfvars"
  : > "$CALLS"
}
DEPLOY="$WORK/repo/scripts/deploy.sh"

# --- first deploy: no tfvars, no bucket, empty state, no VM ---------------------
fresh_repo
STUB_PROJECT=my-proj bash "$DEPLOY" --yes > "$WORK/out1.log" 2>&1 || { cat "$WORK/out1.log"; fail "first deploy exited non-zero"; }
echo "ok   first deploy completes"
TFV="$WORK/repo/terraform/minecraft.auto.tfvars"
check "tfvars created with project from gcloud" grep -q 'project_id *= "my-proj"' "$TFV"
check "tfvars default bucket name" grep -q 'backup_bucket_name *= "my-proj-minecraft-backups"' "$TFV"
check "init is plain (local state, no backend config)" calls_contain "terraform init -input=false"
check "init passes no -backend-config" calls_lack "backend-config"
check "no bucket is created by the script" calls_lack "buckets create"
check "missing bucket is not imported" calls_lack "terraform import"
check "--yes passes -auto-approve" calls_contain "terraform apply -auto-approve"

# --- re-run: state already has the bucket ----------------------------------------
: > "$CALLS"
STUB_BUCKET_EXISTS=yes STUB_STATE=google_storage_bucket.minecraft_backups bash "$DEPLOY" > "$WORK/out2.log" 2>&1 || { cat "$WORK/out2.log"; fail "re-run exited non-zero"; }
echo "ok   re-run completes"
check "bucket already in state is not imported" calls_lack "terraform import"
check "without --yes apply prompts" grep -qx "terraform apply" "$CALLS"

# --- bucket exists but state is empty (leftover bucket): import it --------------
fresh_repo
printf 'project_id = "p"\n' > "$WORK/repo/terraform/minecraft.auto.tfvars"
STUB_BUCKET_EXISTS=yes bash "$DEPLOY" --yes > "$WORK/out3.log" 2>&1 || { cat "$WORK/out3.log"; fail "leftover bucket deploy failed"; }
check "leftover bucket is imported" calls_contain "terraform import -input=false google_storage_bucket.minecraft_backups p-minecraft-backups"

# --- custom bucket name in tfvars is honoured ------------------------------------
fresh_repo
printf 'project_id = "p"\nbackup_bucket_name = "custom-bucket"\n' > "$WORK/repo/terraform/minecraft.auto.tfvars"
STUB_BUCKET_EXISTS=yes bash "$DEPLOY" --yes > "$WORK/out4.log" 2>&1 || { cat "$WORK/out4.log"; fail "custom bucket deploy failed"; }
check "custom bucket name used" calls_contain "terraform import -input=false google_storage_bucket.minecraft_backups custom-bucket"

# --- upgrade from older versions: state was stored in the bucket -------------------
fresh_repo
printf 'project_id = "p"\n' > "$WORK/repo/terraform/minecraft.auto.tfvars"
STUB_BUCKET_EXISTS=yes STUB_REMOTE_STATE=yes STUB_VM_EXISTS=yes bash "$DEPLOY" --yes > "$WORK/out5.log" 2>&1 || { cat "$WORK/out5.log"; fail "state restore deploy failed"; }
echo "ok   upgrade with bucket-stored state completes"
check "old state restored from the bucket" calls_contain "gcloud storage cp gs://p-minecraft-backups/terraform/state/default.tfstate terraform.tfstate"
check "restored bucket is not re-imported" calls_lack "terraform import"

# --- lost state: VM exists, nothing to restore -> stop with a clear error --------
fresh_repo
printf 'project_id = "p"\n' > "$WORK/repo/terraform/minecraft.auto.tfvars"
if STUB_VM_EXISTS=yes bash "$DEPLOY" --yes > "$WORK/out6.log" 2>&1; then
  fail "should refuse to apply when the VM exists but the state is empty"
fi
check "lost state: clear error" grep -q 'Terraform.s state is empty' "$WORK/out6.log"
check "lost state: nothing applied" calls_lack "terraform apply"

# --- errors -----------------------------------------------------------------------
fresh_repo
if STUB_PROJECT="(unset)" bash "$DEPLOY" --yes > "$WORK/out7.log" 2>&1; then
  fail "should fail when no gcloud project is set"
fi
check "no project: clear error" grep -q 'no GCP project set' "$WORK/out7.log"
check "no project: nothing applied" calls_lack "terraform"

rc=0
bash "$DEPLOY" --bogus > /dev/null 2>&1 || rc=$?
check "unknown argument exits 2" test "$rc" -eq 2

echo "All deploy.sh tests passed."
