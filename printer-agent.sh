#!/usr/bin/env bash
# Host-only printer credential agent. No SSH / Docker capability reaches Sofra.
set -euo pipefail
cd "$(dirname "$0")"
umask 077
exec 9>/tmp/rumi-printer-agent.lock
flock -n 9 || exit 0
exec python3 printer-agent.py "$@"
