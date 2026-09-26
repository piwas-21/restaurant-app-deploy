#!/usr/bin/env bash
# Restore one standalone catalogue archive into an isolated disposable Postgres
# container and verify its schema, stored revisions, and read-only runtime view.
# This script never connects to the live deployment.
set -euo pipefail

if [[ $# -ne 1 || ! -f "$1" ]]; then
  echo "Usage: $0 /path/to/catalogue-<timestamp>.dump" >&2
  exit 2
fi

ARCHIVE="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
CONTAINER="catalogue-restore-check-$$"
cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker run -d --rm --name "$CONTAINER" \
  -e POSTGRES_USER=restore_admin \
  -e POSTGRES_PASSWORD=restore-only \
  postgres:16 >/dev/null

ready=0
ready_attempt=0
for attempt in $(seq 1 30); do
  ready_attempt="$attempt"
  if docker exec "$CONTAINER" pg_isready -U restore_admin >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
[[ "$ready" == "1" ]] || {
  echo "ERROR: disposable Postgres did not become ready after ${ready_attempt} attempts" >&2
  exit 1
}

docker exec "$CONTAINER" psql -U restore_admin -d postgres -v ON_ERROR_STOP=1 \
  -c "CREATE ROLE sofra_catalogue_owner LOGIN;" \
  -c "CREATE ROLE sofra_catalogue_reader LOGIN;" \
  -c "CREATE DATABASE sofra_catalogue OWNER sofra_catalogue_owner;" >/dev/null
docker exec -i "$CONTAINER" pg_restore -U restore_admin --role=sofra_catalogue_owner \
  --exit-on-error -d sofra_catalogue < "$ARCHIVE"

revision_count="$(docker exec "$CONTAINER" psql -U sofra_catalogue_owner -d sofra_catalogue -At \
  -c "SELECT count(*) FROM catalogue.revision")"
[[ "$revision_count" =~ ^[1-9][0-9]*$ ]] || {
  echo "ERROR: restored archive has no catalogue revisions" >&2
  exit 1
}

# A successful SELECT through the application role verifies view access. Direct base
# table access must fail so the runtime credential cannot bypass publication filtering.
docker exec "$CONTAINER" psql -U sofra_catalogue_reader -d sofra_catalogue -v ON_ERROR_STOP=1 \
  -c "SELECT count(*) FROM catalogue.public_current" >/dev/null
if docker exec "$CONTAINER" psql -U sofra_catalogue_reader -d sofra_catalogue -v ON_ERROR_STOP=1 \
  -c "SELECT count(*) FROM catalogue.revision" >/dev/null 2>&1; then
  echo "ERROR: restored reader role can read unpublished base revisions" >&2
  exit 1
fi

echo "Catalogue backup restore check passed: ${revision_count} immutable revision(s) restored; reader role is view-only."
