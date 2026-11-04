#!/usr/bin/env bash
set -euo pipefail

echo "=========================================="
echo " Starting Repository Reorganization"
echo "=========================================="

# 1. Create directory structure
echo "[*] Creating target directories..."
mkdir -p .github/workflows
mkdir -p modules/compute
mkdir -p modules/networking
mkdir -p modules/storage
mkdir -p scripts
mkdir -p environments/dev
mkdir -p environments/prod

# 2. Relocate shell scripts to the scripts/ directory
echo "[*] Organizing utility and startup scripts..."
for f in *.sh; do
    if [ -f "$f" ] && [ "$f" != "reorganize.sh" ]; then
        mv "$f" scripts/
        echo "    -> Moved $f to scripts/"
    fi
done

# Also check if there's an old scripts/ subfolder or loose files
if [ -d "startup" ]; then
    cp -r startup/* modules/compute/ 2>/dev/null || true
    echo "    -> Copied startup files into modules/compute/"
fi

# 3. Relocate environment configuration files
echo "[*] Organizing Terraform variable files..."
for f in *.tfvars; do
    if [ -f "$f" ]; then
        mv "$f" environments/prod/
        echo "    -> Moved $f to environments/prod/"
    fi
done

# 4. Handle workflow migrations if necessary
if [ -d "workflows" ] && [ ! -f ".github/workflows/main.yml" ]; then
    mv workflows/* .github/workflows/ 2>/dev/null || true
    rmdir workflows 2>/dev/null || true
    echo "    -> Migrated workflows directory to .github/workflows/"
fi

echo "=========================================="
echo " Reorganization complete successfully!"
echo " Next steps: Review your module imports in main.tf"
echo " and test with 'terraform init'."
echo "=========================================="
