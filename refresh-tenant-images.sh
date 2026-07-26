#!/usr/bin/env bash
# Re-pull + recreate the tenant containers on THIS box that ride a moving image
# tag which just moved — deploy #52.
#
#   ./refresh-tenant-images.sh backend <tag>     # e.g. backend staging
#   ./refresh-tenant-images.sh frontend <tag>
#
# Why: the RUMI stack has deploy-staging.yml to roll `:staging` after a develop
# build, and the demo tenant has deploy-demo-staging.yml to roll its own frontend
# build — but nothing rolled a TENANT's backend when only the backend moved. The
# demo tenant sat 44h behind develop with the fleet endpoints missing while its
# registry config was perfectly correct; the config was never the problem, the
# absent trigger was.
#
# Registry-driven on purpose (ADR-007): it refreshes every managed:scripts tenant
# on this box whose `backend_tag`/`frontend_tag` equals the tag that moved, so a
# second develop-tracking tenant is covered the day it is registered — no
# workflow edit, no hardcoded slug. Immutable tags (`sha-…`) and tenants pinned
# elsewhere are simply not matched.
#
# Safe to run when nothing matches (exit 0, prints why) — the callers are CI
# steps that must not turn a deploy red because a box has no tenants yet.
set -euo pipefail
cd "$(dirname "$0")"

SERVICE_KIND="${1:?usage: $0 <backend|frontend> <tag>}"
TAG="${2:?usage: $0 <backend|frontend> <tag>}"
case "$SERVICE_KIND" in
  backend|frontend) ;;
  *) echo "ERROR: first arg must be 'backend' or 'frontend' (got '$SERVICE_KIND')" >&2; exit 2 ;;
esac
# The tag reaches this script from a workflow input; keep it to the grammar the
# registry and GHCR both use before it is compared or printed.
[[ "$TAG" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || { echo "ERROR: implausible tag '$TAG'" >&2; exit 2; }

[[ -f .env ]] || { echo "ERROR: box .env missing" >&2; exit 1; }
[[ -f tenants/registry.yml ]] || { echo "ERROR: tenants/registry.yml missing (sync the deploy repo first)" >&2; exit 1; }
python3 -c 'import yaml' 2>/dev/null || { echo "ERROR: python3-yaml missing (apt-get install -y python3-yaml)" >&2; exit 1; }

BOX_ROLE="$(grep -E '^BOX_ROLE=' .env | cut -d= -f2- || true)"
[[ -n "$BOX_ROLE" ]] || { echo "ERROR: BOX_ROLE not set in the box .env (prod|staging) — refusing to guess" >&2; exit 1; }

# Slugs of managed:scripts tenants on THIS box pinned to this moving tag.
# managed:legacy (tenant 1) is excluded here as everywhere else — ADR-006.
SLUGS="$(python3 - "$BOX_ROLE" "$SERVICE_KIND" "$TAG" <<'PY'
import sys, yaml
box, kind, tag = sys.argv[1], sys.argv[2], sys.argv[3]
with open("tenants/registry.yml") as f:
    reg = yaml.safe_load(f) or {}
for slug, t in (reg.get("tenants") or {}).items():
    if not isinstance(t, dict):
        continue
    if t.get("managed") != "scripts" or str(t.get("box", "")) != box:
        continue
    if str(t.get(f"{kind}_tag", "")) != tag:
        continue
    if str(t.get("status", "")) == "retired":
        continue
    print(slug)
PY
)"

if [[ -z "$SLUGS" ]]; then
  echo "==> No managed:scripts tenant on box '$BOX_ROLE' rides ${SERVICE_KIND}_tag='$TAG' — nothing to refresh"
  exit 0
fi

FAILED=""
for SLUG in $SLUGS; do
  DIR="/opt/rumi/tenants/${SLUG}"
  SVC="${SERVICE_KIND}-${SLUG}"
  if [[ ! -f "$DIR/docker-compose.yml" ]]; then
    # Registered but never provisioned on this box (or torn down): not an error.
    echo "==> skip ${SLUG}: $DIR/docker-compose.yml not present"
    continue
  fi
  echo "==> Refresh ${SVC} (${DIR})"
  # Per-tenant failure must not abort the others, but must be reported: a silent
  # skip is the exact failure mode this script exists to end.
  if (cd "$DIR" && docker compose pull "$SVC" && docker compose up -d "$SVC"); then
    echo "   ${SVC} up to date"
  else
    echo "   ERROR: refreshing ${SVC} failed" >&2
    FAILED="${FAILED} ${SVC}"
  fi
done

if [[ -n "$FAILED" ]]; then
  echo "ERROR: failed to refresh:${FAILED}" >&2
  exit 1
fi
