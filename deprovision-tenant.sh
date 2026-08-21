#!/usr/bin/env bash
# Tear down a tenant instance provisioned by provision-tenant.sh. Run ON THE
# BOX as the deploy user from /opt/rumi/deploy.
#
#   ./deprovision-tenant.sh <slug>            # stop traffic + containers; keep volumes, DB, files
#   ./deprovision-tenant.sh <slug> --drop-db  # + pg_dump backup, then DROP DATABASE + ROLE
#   ./deprovision-tenant.sh <slug> --purge    # + remove volumes and /opt/rumi/tenants/<slug>
#   ./deprovision-tenant.sh <slug> --drop-db --no-archive   # TEST FIXTURES ONLY
#
# Order matters: the Caddy block goes first (traffic stops), then containers,
# then (optionally) data. Before ANY data is destroyed the tenant is archived by
# backup-archive-tenant.sh into /opt/rumi/backups/archive/<slug>/<ts>/ (database +
# uploads + manifest), kept for ARCHIVE_KEEP_MONTHS (24) so a lapsed trial that comes
# back a year later can be restored — see DEPLOYMENT.md §Backups & restore. This script
# never deletes a backup. (Pre-2026-08-21 teardowns left a bare dump in
# /opt/rumi/tenant-backups/; those files are still there and still valid.)
#
# Safety: refuses managed:legacy registry entries (RUMI/tenant 1 — ADR-006) and
# anything not on this box. The registry itself is not edited — flip the
# tenant's status in git (tenants/registry.yml) to keep the record honest.
set -euo pipefail
cd "$(dirname "$0")"

SLUG="${1:?usage: $0 <slug> [--drop-db] [--purge]}"
[[ "$SLUG" =~ ^[a-z0-9][a-z0-9-]{1,30}$ ]] || { echo "ERROR: slug must be lowercase [a-z0-9-], 2-31 chars" >&2; exit 2; }
shift || true
DROP_DB=false; PURGE=false; NO_ARCHIVE=false
for a in "$@"; do
  case "$a" in
    --drop-db) DROP_DB=true ;;
    --purge)   PURGE=true ;;
    # For the `smoke` fixture only, which is torn down every week and whose data is
    # synthetic: without this, the weekly suite would file 104 archives of a robot over
    # the archive's two-year horizon and put them in front of the owner as if they were
    # a customer's. A real tenant must never be torn down with this flag.
    --no-archive) NO_ARCHIVE=true ;;
    *) echo "ERROR: unknown flag '$a'" >&2; exit 2 ;;
  esac
done

REGISTRY="tenants/registry.yml"
TENANT_DIR="/opt/rumi/tenants/${SLUG}"
DEPLOY_COMPOSE="docker compose -f docker-compose.prod.yml"

echo "==> Preflight"
[[ -f .env ]] || { echo "ERROR: box .env missing" >&2; exit 1; }
[[ -f "$REGISTRY" ]] || { echo "ERROR: $REGISTRY missing" >&2; exit 1; }
BOX_ROLE="$(grep -E '^BOX_ROLE=' .env | cut -d= -f2- || true)"
[[ -n "$BOX_ROLE" ]] || { echo "ERROR: BOX_ROLE not set in the box .env" >&2; exit 1; }

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
[[ "$REG_MANAGED" == "scripts" ]] || { echo "ERROR: tenant '$SLUG' is managed:'$REG_MANAGED' — refusing (ADR-006 protects tenant 1)" >&2; exit 1; }
[[ "$REG_BOX" == "$BOX_ROLE" ]] || { echo "ERROR: tenant '$SLUG' belongs on box '$REG_BOX', this box is '$BOX_ROLE'" >&2; exit 1; }

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

# The dump this script has always taken before dropping a database is now the SEED of the
# long-retention archive rather than a lone file in /opt/rumi/tenant-backups: same single
# pg_dump, written into archive/<slug>/<ts>/ next to the tenant's uploads and a manifest,
# on a multi-year clock (backup-archive-tenant.sh). That is what makes "a trial tenant
# comes back eight months later" answerable — the rolling backups top out at ~6 months.
#
# It runs for --purge too, not just --drop-db: --purge deletes /opt/rumi/tenants/<slug>,
# and uploads deleted without a copy are gone in exactly the same way a dropped database
# is. Archiving is BEFORE both, so a failure here stops the teardown with the data intact.
ARCHIVE_REF=""
if $NO_ARCHIVE; then
  echo "==> Archive SKIPPED (--no-archive) — data will be destroyed with no long-term copy"
elif $DROP_DB || $PURGE; then
  echo "==> Archive tenant data (pre-teardown, long retention)"
  ARCHIVE_OUT="$(./backup-archive-tenant.sh "$SLUG" --reason deprovision --allow-missing-db)"
  printf '%s\n' "$ARCHIVE_OUT" | sed 's/^/   /'
  ARCHIVE_REF="$(printf '%s\n' "$ARCHIVE_OUT" | grep '^ref=' | tail -1 | cut -d= -f2-)"
fi

if $DROP_DB; then
  echo "==> Drop database ${REG_DB} (role ${REG_DB_ROLE})"
  PGUSER="$(grep '^POSTGRES_USER=' .env | cut -d= -f2- || true)"
  [[ -n "$PGUSER" ]] || { echo "ERROR: POSTGRES_USER not set in .env" >&2; exit 1; }
  # Fail loudly if postgres itself is unreachable — otherwise a down container
  # would be indistinguishable from "database does not exist" below and the
  # drop would be silently skipped while reporting success.
  $DEPLOY_COMPOSE exec -T postgres psql -U "$PGUSER" -d postgres -c 'SELECT 1' >/dev/null
  if $DEPLOY_COMPOSE exec -T postgres psql -U "$PGUSER" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${REG_DB}'" | grep -q 1; then
    # Refuse to drop a database we did not just archive. The archive step above already
    # failed loudly if it could not dump, so reaching here without a ref means something
    # subtler went wrong — and "we dropped it, but the backup is missing" is the one
    # outcome this script must never produce.
    $NO_ARCHIVE || [[ -n "$ARCHIVE_REF" ]] || { echo "ERROR: no archive was recorded — refusing to drop ${REG_DB}" >&2; exit 1; }
    $DEPLOY_COMPOSE exec -T postgres psql -v ON_ERROR_STOP=1 -U "$PGUSER" -d postgres \
      -c "DROP DATABASE ${REG_DB}" -c "DROP ROLE IF EXISTS ${REG_DB_ROLE}"
    echo "   dropped database + role"
  else
    echo "   skip: database ${REG_DB} does not exist"
  fi
else
  echo "==> DB kept (pass --drop-db to archive + drop)"
fi

if $PURGE; then
  echo "==> Purge tenant dir"
  # Backups live in $BACKUP_DIR, outside the tenant dir — safe to remove.
  # Files are root/backend-uid owned (bind mounts), so purge via a container.
  docker run --rm -v /opt/rumi/tenants:/tenants alpine:3 rm -rf "/tenants/${SLUG}"
  echo "   removed $TENANT_DIR"
fi

cat <<EOF

==> Deprovisioned tenant '${SLUG}'.${ARCHIVE_REF:+
    Archived: ${ARCHIVE_REF} (under /opt/rumi/backups) — rehearse it with
      ./restore-tenant.sh ${SLUG} --from ${ARCHIVE_REF}}
    Completion marker cleared, so the merge chain can stand this tenant up again.
    Remember: flip its status in tenants/registry.yml (git) to keep the registry honest.
EOF
