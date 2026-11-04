#!/bin/bash
# Test scripts/deploy.sh without GCP. gcloud and terraform are replaced by stubs
# that record their arguments, and the script runs in a scratch copy of the repo
# because it writes terraform/minecraft.auto.tfvars. Run it with `make test`.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

STUBS="$WORK/stubs"
CALLS="$WORK/calls.log"
mkdir -p "$STUBS"

cat > "$STUBS/gcloud" << STUB
#!/bin/bash
echo "gcloud \$*" >> "$CALLS"
case "\$*" in
  "config get-value project") printf '%s\n' "\${STUB_PROJECT:-}" ;;
  "storage buckets describe"*) [ "\${STUB_BUCKET_EXISTS:-no}" = yes ] ;;
esac
STUB
cat > "$STUBS/terraform" << STUB
#!/bin/bash
echo "terraform \$*" >> "$CALLS"
case "\$1" in
  state) printf '%s\n' "\${STUB_STATE:-}" ;;
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
  rm -rf "$WORK/repo"
  mkdir -p "$WORK/repo"
  cp -r "$REPO/scripts" "$REPO/terraform" "$WORK/repo/"
  rm -f "$WORK/repo/terraform/minecraft.auto.tfvars"
  : > "$CALLS"
}
DEPLOY="$WORK/repo/scripts/deploy.sh"

# --- first deploy: no tfvars, no bucket, empty state ---------------------------
fresh_repo
STUB_PROJECT=my-proj bash "$DEPLOY" --yes > "$WORK/out1.log" 2>&1 || { cat "$WORK/out1.log"; fail "first deploy exited non-zero"; }
echo "ok   first deploy completes"
TFV="$WORK/repo/terraform/minecraft.auto.tfvars"
check "tfvars created with project from gcloud" grep -q 'project_id *= "my-proj"' "$TFV"
check "tfvars default bucket name" grep -q 'backup_bucket_name *= "my-proj-minecraft-backups"' "$TFV"
check "storage API enabled" calls_contain "gcloud services enable storage.googleapis.com --project my-proj"
check "missing bucket is created in US by default" calls_contain "gcloud storage buckets create gs://my-proj-minecraft-backups --project my-proj --location=US"
check "init uses the bucket" calls_contain "terraform init -input=false -backend-config=bucket=my-proj-minecraft-backups -backend-config=backend.hcl"
check "bucket imported when not in state" calls_contain "terraform import -input=false google_storage_bucket.minecraft_backups my-proj-minecraft-backups"
check "--yes passes -auto-approve" calls_contain "terraform apply -auto-approve"

# --- re-run: bucket exists and is already in state ---------------------------
: > "$CALLS"
STUB_BUCKET_EXISTS=yes STUB_STATE=google_storage_bucket.minecraft_backups bash "$DEPLOY" > "$WORK/out2.log" 2>&1 || { cat "$WORK/out2.log"; fail "re-run exited non-zero"; }
echo "ok   re-run completes"
check "existing bucket is not recreated" calls_lack "buckets create"
check "bucket not imported twice" calls_lack "terraform import"
check "without --yes apply prompts" grep -qx "terraform apply" "$CALLS"

# --- custom bucket name in tfvars is honoured -----------------------------------
fresh_repo
printf 'project_id = "p"\nbackup_bucket_name = "custom-bucket"\n' > "$WORK/repo/terraform/minecraft.auto.tfvars"
bash "$DEPLOY" --yes > "$WORK/out3.log" 2>&1 || { cat "$WORK/out3.log"; fail "custom bucket deploy failed"; }
check "custom bucket name used" calls_contain "gcloud storage buckets create gs://custom-bucket"

# --- bucket_location in tfvars is honoured ---------------------------------------
fresh_repo
printf 'project_id = "p"\nbucket_location = "us-central1"\n' > "$WORK/repo/terraform/minecraft.auto.tfvars"
bash "$DEPLOY" --yes > "$WORK/out5.log" 2>&1 || { cat "$WORK/out5.log"; fail "bucket_location deploy failed"; }
check "bucket_location used when creating the bucket" calls_contain "--location=us-central1"

# --- errors ---------------------------------------------------------------------
fresh_repo
if STUB_PROJECT="(unset)" bash "$DEPLOY" --yes > "$WORK/out4.log" 2>&1; then
  fail "should fail when no gcloud project is set"
fi
check "no project: clear error" grep -q 'no GCP project set' "$WORK/out4.log"
check "no project: nothing applied" calls_lack "terraform"

rc=0
bash "$DEPLOY" --bogus > /dev/null 2>&1 || rc=$?
check "unknown argument exits 2" test "$rc" -eq 2

echo "All deploy.sh tests passed."
