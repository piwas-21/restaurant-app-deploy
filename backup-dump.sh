#!/usr/bin/env bash
# Nightly LOCAL backup dump — runs on BOTH boxes from /opt/rumi/deploy (cron;
# see DEPLOYMENT.md §Backups & restore). Produces under /opt/rumi/backups/dumps/:
#   cluster-<ts>.sql.gz        pg_dumpall of the shared postgres (all DBs + roles)
#   uploads-<ts>.tar.gz        the base stack's uploads volume (RUMI images)
#   tenants-<ts>.tar.gz        /opt/rumi/tenants (per-tenant uploads + .env/app-secrets)
#   deploy-config-<ts>.tar.gz  box-local never-in-git config (.env, app-secrets.json, dozzle-users.yml)
#   tenants/<slug>/<slug>-scheduled-<ts>.sql.gz   PER-TENANT dump, one per managed:scripts
#                              tenant on this box (backup-tenant.sh). Complements the
#                              cluster dump — see that script's header for why both.
# Keeps KEEP_DAYS (default 7) days locally, and prunes the long-retention archive of
# departed tenants on its own calendar clock (backup-archive-tenant.sh --prune). Off-box
# shipping is backup-offsite.sh (prod only). Read-only against the running stack;
# contains secrets and customer data -> dirs are 700.
set -euo pipefail
cd "$(dirname "$0")"

# BACKUP_ROOT / DUMP_DIR / TENANT_DUMP_DIR / ARCHIVE_DIR and the tenant helpers live in
# backup-lib.sh so this script, backup-tenant.sh, restore-tenant.sh and backup-agent.sh
# cannot drift about where a backup lives.
# shellcheck source=backup-lib.sh
. ./backup-lib.sh

KEEP_DAYS="${KEEP_DAYS:-7}"
DEPLOY_COMPOSE="docker compose -f docker-compose.prod.yml"
TS="$(date -u +%Y%m%dT%H%M%SZ)"

echo "==> [$(date -u +%FT%TZ)] backup-dump start"
[[ -f .env ]] || { echo "ERROR: box .env missing (run from /opt/rumi/deploy)" >&2; exit 1; }
PGUSER="$(grep -E '^POSTGRES_USER=' .env | cut -d= -f2- || true)"
[[ -n "$PGUSER" ]] || { echo "ERROR: POSTGRES_USER not set in .env" >&2; exit 1; }
install -d -m 700 "$BACKUP_ROOT" "$DUMP_DIR"

# Fail loudly if postgres is down — a down container must not look like a
# successful empty backup (same guard as deprovision-tenant.sh).
$DEPLOY_COMPOSE exec -T postgres psql -U "$PGUSER" -d postgres -c 'SELECT 1' >/dev/null

echo "==> pg_dumpall (all databases + roles)"
# Atomic: write .tmp, mv on success — a mid-dump abort must never leave a
# partial file with a valid-looking name for the offsite run to ship.
$DEPLOY_COMPOSE exec -T postgres pg_dumpall -U "$PGUSER" --clean --if-exists \
  | gzip > "${DUMP_DIR}/cluster-${TS}.sql.gz.tmp"
mv "${DUMP_DIR}/cluster-${TS}.sql.gz.tmp" "${DUMP_DIR}/cluster-${TS}.sql.gz"

# Per-tenant dumps — one restorable artifact per managed tenant, beside (NOT instead of)
# the cluster dump above. The cluster dump is the box-loss path: it alone carries the
# ROLES, so it cannot be replaced by a bag of per-database dumps. What it cannot do is
# hand you ONE tenant without carving them out of an all-database file under pressure,
# and that is the case this loop covers — plus it is the only shape the control plane's
# "back this tenant up / restore this tenant" surface can be built on.
#
# managed:legacy (RUMI, ADR-006) is excluded by bk_registry_tenants, not by a special
# case here — RUMI shares the MAIN compose project and these scripts must keep refusing
# to touch it. A tenant with no database on this box (the `smoke` fixture between runs)
# is skipped, not failed.
#
# One tenant's failure must not lose the other tenants' backups, so failures are
# collected and re-raised at the end — after the cluster dump and the tars are safely on
# disk. The cron log still goes red.
echo "==> per-tenant dumps"
TENANT_FAILURES=0
if [[ -f "$BK_REGISTRY" ]]; then
  BOX_ROLE="$(grep -E '^BOX_ROLE=' .env | cut -d= -f2- || true)"
  if [[ -z "$BOX_ROLE" ]]; then
    echo "   WARN: BOX_ROLE not set in .env — skipping per-tenant dumps" >&2
    TENANT_FAILURES=1
  else
    # fd 3, because backup-tenant.sh runs `docker compose exec -T`, which forwards stdin
    # into the container and would swallow the rest of this list.
    while IFS= read -r slug <&3; do
      [[ -n "$slug" ]] || continue
      ./backup-tenant.sh "$slug" --kind scheduled --skip-missing </dev/null \
        || { echo "   ERROR: per-tenant dump failed for '${slug}'" >&2; TENANT_FAILURES=$((TENANT_FAILURES + 1)); }
    done 3< <(bk_registry_tenants "$BOX_ROLE")
  fi
else
  echo "   skip: $BK_REGISTRY not present on this box"
fi

# Tar a live dir via a root container (tenant files can be root-owned; named
# volumes have no stable host path). Tolerates tar rc=1 ("file changed as we
# read it" on a live volume — archive still written); rc>=2 is a real error.
tar_via_container() {
  local vol="$1" out="$2" rc=0
  docker run --rm -v "${vol}" alpine:3 tar -czf - -C /src . > "${out}.tmp" || rc=$?
  if [[ $rc -ge 2 ]]; then
    echo "ERROR: tar ${vol} failed (rc=${rc})" >&2
    rm -f "${out}.tmp"
    return "$rc"
  fi
  [[ $rc -eq 1 ]] && echo "   warn: tar rc=1 (file changed while reading) — archive kept"
  mv "${out}.tmp" "${out}"
}

echo "==> uploads volume"
tar_via_container "deploy_uploads:/src:ro" "${DUMP_DIR}/uploads-${TS}.tar.gz"

echo "==> tenants dir (per-tenant uploads + env/secrets)"
tar_via_container "/opt/rumi/tenants:/src:ro" "${DUMP_DIR}/tenants-${TS}.tar.gz"

echo "==> box-local deploy config"
CONF_FILES=()
for f in .env app-secrets.json dozzle-users.yml; do
  [[ -f "/opt/rumi/deploy/$f" ]] && CONF_FILES+=("$f")
done
if [[ ${#CONF_FILES[@]} -gt 0 ]]; then
  tar -czf "${DUMP_DIR}/deploy-config-${TS}.tar.gz.tmp" -C /opt/rumi/deploy "${CONF_FILES[@]}"
  mv "${DUMP_DIR}/deploy-config-${TS}.tar.gz.tmp" "${DUMP_DIR}/deploy-config-${TS}.tar.gz"
else
  echo "   skip: no config files found"
fi

echo "==> prune local dumps older than ${KEEP_DAYS} days"
find "$DUMP_DIR" -maxdepth 1 -type f -mtime "+${KEEP_DAYS}" -delete
# The per-tenant dumps live one level deeper (dumps/tenants/<slug>/) so that restic ships
# them off-box with no extra wiring; -maxdepth 1 above cannot see them. Each
# backup-tenant.sh run prunes its own tenant, and this is the sweep that also catches a
# tenant that has stopped being dumped (deprovisioned) and would otherwise keep its last
# week forever. Empty per-tenant dirs are then removed, so the inventory stops
# advertising a tenant with nothing in it.
find "$TENANT_DUMP_DIR" -mindepth 2 -maxdepth 2 -type f -mtime "+${KEEP_DAYS}" -delete 2>/dev/null || true
find "$TENANT_DUMP_DIR" -mindepth 1 -maxdepth 1 -type d -empty -delete 2>/dev/null || true

# The long-retention archive of DEPARTED tenants is pruned on its own clock (calendar
# months from the timestamp in the name, not mtime — see backup-archive-tenant.sh).
if [[ -d "$ARCHIVE_DIR" ]]; then
  ./backup-archive-tenant.sh --prune </dev/null || echo "   WARN: archive prune failed" >&2
fi

echo "==> [$(date -u +%FT%TZ)] backup-dump done"
find "$DUMP_DIR" -maxdepth 1 -type f -name "*${TS}*" -exec du -h {} +

if [[ "$TENANT_FAILURES" -gt 0 ]]; then
  echo "ERROR: ${TENANT_FAILURES} per-tenant dump(s) failed — the cluster dump and tars above are intact" >&2
  exit 1
fi
