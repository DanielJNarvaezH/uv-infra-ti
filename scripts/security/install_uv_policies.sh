#!/usr/bin/env bash
set -euo pipefail

# Script to install sudoers fragment into /etc/sudoers.d/uv_policies
# Usage: sudo bash scripts/security/install_uv_policies.sh

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$REPO_ROOT/config/uv_policies.sudoers"
DEST="/etc/sudoers.d/uv_policies"

if [ ! -f "$SRC" ]; then
  echo "Source file not found: $SRC" >&2
  exit 1
fi

# Validate the fragment before copying
if ! visudo -cf "$SRC"; then
  echo "Validation failed for $SRC" >&2
  exit 2
fi

# Install with correct ownership and permissions
sudo install -m 0440 -o root:root "$SRC" "$DEST"

# Validate installed file
if ! sudo visudo -cf "$DEST"; then
  echo "Installed sudoers fragment is invalid: $DEST" >&2
  exit 3
fi

echo "Installed $DEST (mode 0440)."
