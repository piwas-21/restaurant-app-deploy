#!/usr/bin/env bash
# Tear down a tenant instance provisioned by provision-tenant.sh. Run ON THE
# BOX as the deploy user from /opt/rumi/deploy.
#
#   ./deprovision-tenant.sh <slug>            # stop traffic + containers; keep volumes, DB, files
#   ./deprovision-tenant.sh <slug> --drop-db  # + pg_dump backup, then DROP DATABASE + ROLE
#   ./deprovision-tenant.sh <slug> --purge    # + remove volumes and /opt/rumi/tenants/<slug>
#
# Order matters: the Caddy block goes first (traffic stops), then containers,
# then (optionally) data. DB backups land in /opt/rumi/tenant-backups/ and are
# NEVER deleted by this script.
#
# Safety: refuses managed:legacy registry entries (RUMI/tenant 1 — ADR-006) and
# anything not on this box. The registry itself is not edited — flip the
# tenant's status in git (tenants/registry.yml) to keep the record honest.
set -euo pipefail
cd "$(dirname "$0")"

SLUG="${1:?usage: $0 <slug> [--drop-db] [--purge]}"
[[ "$SLUG" =~ ^[a-z0-9][a-z0-9-]{1,30}$ ]] || { echo "ERROR: slug must be lowercase [a-z0-9-], 2-31 chars"; exit 2; }
shift || true
DROP_DB=false; PURGE=false
for a in "$@"; do
  case "$a" in
    --drop-db) DROP_DB=true ;;
    --purge)   PURGE=true ;;
    *) echo "ERROR: unknown flag '$a'"; exit 2 ;;
  esac
done

REGISTRY="tenants/registry.yml"
TENANT_DIR="/opt/rumi/tenants/${SLUG}"
BACKUP_DIR="/opt/rumi/tenant-backups"
DEPLOY_COMPOSE="docker compose -f docker-compose.prod.yml"

echo "==> Preflight"
[[ -f .env ]] || { echo "ERROR: box .env missing"; exit 1; }
[[ -f "$REGISTRY" ]] || { echo "ERROR: $REGISTRY missing"; exit 1; }
BOX_ROLE="$(grep -E '^BOX_ROLE=' .env | cut -d= -f2- || true)"
[[ -n "$BOX_ROLE" ]] || { echo "ERROR: BOX_ROLE not set in the box .env"; exit 1; }

eval "$(python3 - "$SLUG" <<'PY'
import sys, yaml, shlex
slug = sys.argv[1]
with open("tenants/registry.yml") as f:
    reg = yaml.safe_load(f)
t = (reg.get("tenants") or {}).get(slug)
if not t:
    print(f"echo 'ERROR: tenant {slug} not found in tenants/registry.yml'; exit 1")
    sys.exit(0)
for k in ("managed", "box", "db", "db_role"):
    print(f"REG_{k.upper()}={shlex.quote(str(t.get(k, '')))}")
PY
)"
[[ "$REG_MANAGED" == "scripts" ]] || { echo "ERROR: tenant '$SLUG' is managed:'$REG_MANAGED' — refusing (ADR-006 protects tenant 1)"; exit 1; }
[[ "$REG_BOX" == "$BOX_ROLE" ]] || { echo "ERROR: tenant '$SLUG' belongs on box '$REG_BOX', this box is '$BOX_ROLE'"; exit 1; }

echo "==> Remove Caddy site block (stops public traffic)"
if [[ -f "caddy-tenants/${SLUG}.caddy" ]]; then
  rm "caddy-tenants/${SLUG}.caddy"
  # Dir mount -> removal is already visible in the container; reload re-globs
  # the imports. Reload validates internally and keeps the old config on
  # failure, so this can't take the box's other sites down.
  $DEPLOY_COMPOSE exec caddy caddy reload --config /etc/caddy/Caddyfile
  echo "   removed caddy-tenants/${SLUG}.caddy + reloaded"
else
  echo "   skip: no caddy block present"
fi

echo "==> Stop tenant containers"
if [[ -f "$TENANT_DIR/docker-compose.yml" ]]; then
  if $PURGE; then
    (cd "$TENANT_DIR" && docker compose down --volumes --remove-orphans)
    echo "   down + volumes removed"
  else
    (cd "$TENANT_DIR" && docker compose down --remove-orphans)
    echo "   down (volumes kept — pass --purge to remove)"
  fi
else
  echo "   skip: no compose project at $TENANT_DIR"
fi

# The completion marker means "this tenant is up" (provision-tenant.sh writes it as its
# last act), so a teardown has to clear it whether or not the directory goes with it.
# Without this, a `--purge`-less teardown leaves a marker asserting a tenant that is now
# stopped, and the merge chain — which reads the marker as `done` — would decline to
# stand it back up. `.chain-provisioned` is the pre-2026-08-01 name, cleared too.
rm -f "$TENANT_DIR/.provisioned" "$TENANT_DIR/.chain-provisioned"

if $DROP_DB; then
  echo "==> Backup + drop database ${REG_DB} (role ${REG_DB_ROLE})"
  PGUSER="$(grep '^POSTGRES_USER=' .env | cut -d= -f2- || true)"
  [[ -n "$PGUSER" ]] || { echo "ERROR: POSTGRES_USER not set in .env"; exit 1; }
  install -d "$BACKUP_DIR"
  # Fail loudly if postgres itself is unreachable — otherwise a down container
  # would be indistinguishable from "database does not exist" below and the
  # drop would be silently skipped while reporting success.
  $DEPLOY_COMPOSE exec -T postgres psql -U "$PGUSER" -d postgres -c 'SELECT 1' >/dev/null
  if $DEPLOY_COMPOSE exec -T postgres psql -U "$PGUSER" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${REG_DB}'" | grep -q 1; then
    TS="$(date -u +%Y%m%dT%H%M%SZ)"
    $DEPLOY_COMPOSE exec -T postgres pg_dump -U "$PGUSER" "${REG_DB}" | gzip > "${BACKUP_DIR}/${SLUG}-${REG_DB}-${TS}.sql.gz"
    echo "   backup: ${BACKUP_DIR}/${SLUG}-${REG_DB}-${TS}.sql.gz ($(du -h "${BACKUP_DIR}/${SLUG}-${REG_DB}-${TS}.sql.gz" | cut -f1))"
    $DEPLOY_COMPOSE exec -T postgres psql -v ON_ERROR_STOP=1 -U "$PGUSER" -d postgres \
      -c "DROP DATABASE ${REG_DB}" -c "DROP ROLE IF EXISTS ${REG_DB_ROLE}"
    echo "   dropped database + role"
  else
    echo "   skip: database ${REG_DB} does not exist"
  fi
else
  echo "==> DB kept (pass --drop-db to back up + drop)"
fi

if $PURGE; then
  echo "==> Purge tenant dir"
  # Backups live in $BACKUP_DIR, outside the tenant dir — safe to remove.
  # Files are root/backend-uid owned (bind mounts), so purge via a container.
  docker run --rm -v /opt/rumi/tenants:/tenants alpine:3 rm -rf "/tenants/${SLUG}"
  echo "   removed $TENANT_DIR"
fi

cat <<EOF

==> Deprovisioned tenant '${SLUG}'.
    Completion marker cleared, so the merge chain can stand this tenant up again.
    Remember: flip its status in tenants/registry.yml (git) to keep the registry honest.
EOF
