#!/usr/bin/env bash
# Key-based, host-pinned SSH wrapper for the Netcup box. No secrets inside.
# Usage: bash deploy/.ssh/box.sh '<remote command>'
set -euo pipefail
DIR="/Users/mahmutkaya/workspace/rumi-workspace/deploy/.ssh"
exec ssh -i ~/.ssh/rumi_netcup \
  -o UserKnownHostsFile="$DIR/known_hosts" \
  -o StrictHostKeyChecking=yes \
  -o IdentitiesOnly=yes \
  -o ConnectTimeout=15 \
  root@159.195.137.101 "$@"
