#!/usr/bin/env bash
# Exercise the real resolver; no box secrets, network or provisioning writes.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "$HERE/tenant_admin_email_test.py"
