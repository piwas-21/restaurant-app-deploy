#!/usr/bin/env bash
# Regression test for the MC FOOD reservation entitlement in tenants/registry.yml.
#
# The registry is the source of truth; provision-tenant.sh carries this list into
# TENANT_MODULES and the backend/frontend module machinery enforce it. A later edit
# must not silently put reservations back on a restaurant that does not offer them.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY="$HERE/../tenants/registry.yml"
[[ -f "$REGISTRY" ]] || { echo "cannot find tenants/registry.yml" >&2; exit 1; }

python3 - "$REGISTRY" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    tenants = (yaml.safe_load(handle) or {}).get("tenants") or {}

mcdoner = tenants.get("mcdoner")
if not isinstance(mcdoner, dict):
    raise SystemExit("mcdoner registry entry is missing")

modules = mcdoner.get("modules")
if not isinstance(modules, list) or not modules:
    raise SystemExit("mcdoner must have a non-empty modules list")
if "core" not in modules:
    raise SystemExit("mcdoner must retain core")
if "reservations" in modules:
    raise SystemExit("mcdoner must not carry the reservations module")

# Positive control: this test must distinguish the intended removal from a broken
# parser or a catalog-wide removal. Demo is the reservation-enabled showcase.
demo = tenants.get("demo")
if not isinstance(demo, dict) or "reservations" not in (demo.get("modules") or []):
    raise SystemExit("positive control failed: demo must retain reservations")

print("mcdoner reservation module: disabled")
print("demo reservation module: enabled (positive control)")
PY
