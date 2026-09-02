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

# --- BEGIN pull_service (extracted verbatim by tests/refresh-pull-retry.sh) ---
# A tenant roll dies on the BOX'S LINK TO GHCR more often than on anything we control. Measured
# 2026-09-02: 2 of 5 TLS handshakes from the staging box to ghcr.io hung past 25s while 3 finished
# in under a second, with DNS, load and disk all clean — and a frontend release reached prod while
# leaving a paying tenant on the previous image, twice, including on a re-run.
#
# So: retry, then fall back — but only onto an image we have JUST PROVED we can fetch. The trap to
# avoid is recreating from whatever happens to be in the local cache, which would report success
# while leaving the tenant stale, and staleness is the exact thing this script exists to end.
#
# Linear backoff, 10s then 20s. Overridable so the unit test can run at zero and so an operator can
# widen it from the shell during a bad spell, without editing a script that only reaches the box
# through a deploy release.
PULL_BACKOFF_BASE="${PULL_BACKOFF_BASE:-10}"

pull_service() { # <dir> <svc> -> 0 when the service's image is present AND current
  local dir="$1" svc="$2" try image
  for try in 1 2 3; do
    (cd "$dir" && docker compose pull "$svc") && return 0
    echo "   pull attempt ${try}/3 for ${svc} failed" >&2
    sleep $(( try * PULL_BACKOFF_BASE ))
  done

  # `docker compose pull` re-resolves the manifest against the registry EVEN WHEN THE TAG IS
  # ALREADY LOCAL, so it can fail where a plain `docker pull` of the same image succeeds — that is
  # precisely what happened on 2026-09-02. A direct pull that succeeds proves local == remote,
  # which is the only condition under which carrying on is honest.
  image="$(cd "$dir" && docker compose config --images "$svc" 2>/dev/null | head -1)"
  if [[ -z "$image" ]]; then
    echo "   could not resolve an image for ${svc} — giving up" >&2
    return 1
  fi
  echo "   compose pull exhausted; trying a direct pull of ${image}" >&2
  if docker pull -q "$image" >/dev/null 2>&1; then
    echo "   direct pull succeeded — the local tag is the published one" >&2
    return 0
  fi
  echo "   direct pull of ${image} failed too" >&2
  return 1
}
# --- END pull_service ---

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
  if pull_service "$DIR" "$SVC" && (cd "$DIR" && docker compose up -d "$SVC"); then
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
