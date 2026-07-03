#!/usr/bin/env bash
# Key-based, host-pinned SSH wrapper for the STAGING Netcup box (deploy user `rumi`).
# Mirrors box.sh (which targets PROD as root). No secrets inside — the private key
# lives at ~/.ssh/rumi_staging_ed25519, outside the repo; the host key is pinned in
# staging_known_hosts (committed, public material).
#
# Usage:  bash deploy/.ssh/staging.sh '<remote command>'
#   e.g.  bash deploy/.ssh/staging.sh 'cd /opt/rumi/deploy && ./deploy.sh'
#         bash deploy/.ssh/staging.sh 'cd /opt/rumi/deploy && docker compose -f docker-compose.prod.yml ps'
#
# Root ops (rare): staging SSH is key-only with NO root login. For the few root-only
# tasks (editing /etc/sudoers.d, etc.) use `su -` on the box interactively — the root
# password is the STAGING_PASSWORD line in the workspace-root .env. Do NOT `ssh root@`.
set -euo pipefail
DIR="/Users/mahmutkaya/workspace/rumi-workspace/deploy/.ssh"
exec ssh -i ~/.ssh/rumi_staging_ed25519 \
  -o UserKnownHostsFile="$DIR/staging_known_hosts" \
  -o StrictHostKeyChecking=yes \
  -o IdentitiesOnly=yes \
  -o ConnectTimeout=15 \
  rumi@159.195.34.105 "$@"
