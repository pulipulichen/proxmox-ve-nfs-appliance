#!/usr/bin/env bash
set -Eeuo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root inside the LXC container." >&2
  exit 1
fi

REPO_DIR=/opt/proxmox-ve-nfs-appliance
if [ ! -d "$REPO_DIR/.git" ]; then
  echo "Repository missing. Clone it at $REPO_DIR first." >&2
  exit 1
fi
git -C "$REPO_DIR" pull --ff-only origin main
"$REPO_DIR/start.sh"
echo "Updated appliance from GitHub. /srv/nfs data and credentials were preserved."
