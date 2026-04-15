#!/bin/bash
set -euo pipefail

SUBMODULE="traefik"

echo "➡️ Attempting deinit (ignore if missing)..."
git submodule deinit -f "$SUBMODULE" 2>/dev/null || true

echo "➡️ Removing from index (if exists)..."
git rm -f "$SUBMODULE" 2>/dev/null || true

echo "➡️ Removing from .gitmodules (if present)..."
if [ -f .gitmodules ]; then
    git config -f .gitmodules --remove-section "submodule.$SUBMODULE" 2>/dev/null || true
    git add .gitmodules || true
fi

echo "➡️ Cleaning .git/modules..."
rm -rf ".git/modules/$SUBMODULE"

echo "➡️ Removing working directory..."
rm -rf "$SUBMODULE"

echo "➡️ Final cleanup..."
git add -A

git commit -m "Remove $SUBMODULE submodule" 2>/dev/null || \
    echo "ℹ️ Nothing to commit"

git push origin main || true

echo "✅ Cleanup complete"