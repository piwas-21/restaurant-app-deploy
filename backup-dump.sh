#!/usr/bin/env bash
# Nightly LOCAL backup dump — runs on BOTH boxes from /opt/rumi/deploy (cron;
# see DEPLOYMENT.md §Backups & restore). Produces under /opt/rumi/backups/dumps/:
#   cluster-<ts>.sql.gz        pg_dumpall of the shared postgres (all DBs + roles)
#   uploads-<ts>.tar.gz        the base stack's uploads volume (RUMI images)
#   tenants-<ts>.tar.gz        /opt/rumi/tenants (per-tenant uploads + .env/app-secrets)
#   deploy-config-<ts>.tar.gz  box-local never-in-git config (.env, app-secrets.json, dozzle-users.yml)
# Keeps KEEP_DAYS (default 7) days locally. Off-box shipping is backup-offsite.sh
# (prod only). Read-only against the running stack; contains secrets -> dir is 700.
set -euo pipefail
cd "$(dirname "$0")"

BACKUP_ROOT="/opt/rumi/backups"
DUMP_DIR="${BACKUP_ROOT}/dumps"
KEEP_DAYS="${KEEP_DAYS:-7}"
DEPLOY_COMPOSE="docker compose -f docker-compose.prod.yml"
TS="$(date -u +%Y%m%dT%H%M%SZ)"

echo "==> [$(date -u +%FT%TZ)] backup-dump start"
[[ -f .env ]] || { echo "ERROR: box .env missing (run from /opt/rumi/deploy)"; exit 1; }
PGUSER="$(grep -E '^POSTGRES_USER=' .env | cut -d= -f2- || true)"
[[ -n "$PGUSER" ]] || { echo "ERROR: POSTGRES_USER not set in .env"; exit 1; }
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

# Tar a live dir via a root container (tenant files can be root-owned; named
# volumes have no stable host path). Tolerates tar rc=1 ("file changed as we
# read it" on a live volume — archive still written); rc>=2 is a real error.
tar_via_container() {
  local vol="$1" out="$2" rc=0
  docker run --rm -v "${vol}" alpine:3 tar -czf - -C /src . > "${out}.tmp" || rc=$?
  if [[ $rc -ge 2 ]]; then
    echo "ERROR: tar ${vol} failed (rc=${rc})"
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

echo "==> [$(date -u +%FT%TZ)] backup-dump done"
find "$DUMP_DIR" -maxdepth 1 -type f -name "*${TS}*" -exec du -h {} +
