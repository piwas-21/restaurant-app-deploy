#!/usr/bin/env bash
# Restore one standalone catalogue archive into an isolated disposable Postgres
# container and verify its schema, stored revisions, and read-only runtime views.
# This script never connects to the live deployment.
set -euo pipefail

if [[ $# -ne 1 || ! -f "$1" ]]; then
  echo "Usage: $0 /path/to/catalogue-<timestamp>.dump" >&2
  exit 2
fi

ARCHIVE="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
CONTAINER="catalogue-restore-check-$$"
if ! command -v openssl >/dev/null 2>&1; then
  echo "ERROR: openssl is required to generate a disposable restore password" >&2
  exit 1
fi
catalogue_restore_password="$(openssl rand -hex 32)"
cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

POSTGRES_PASSWORD="$catalogue_restore_password" docker run -d --rm --network none --name "$CONTAINER" \
  -e POSTGRES_USER=restore_admin \
  -e POSTGRES_PASSWORD \
  postgres:16 >/dev/null
unset catalogue_restore_password

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

schema_ready="$(docker exec "$CONTAINER" psql -U sofra_catalogue_owner -d sofra_catalogue -At \
  -v ON_ERROR_STOP=1 -c "SELECT to_regnamespace('catalogue') IS NOT NULL
    AND to_regclass('catalogue.revision') IS NOT NULL
    AND to_regclass('catalogue.public_revision') IS NOT NULL
    AND to_regclass('catalogue.public_current') IS NOT NULL")"
[[ "$schema_ready" == "t" ]] || {
  echo "ERROR: restored archive is missing the catalogue schema, revision table, or published views" >&2
  exit 1
}

revision_count="$(docker exec "$CONTAINER" psql -U sofra_catalogue_owner -d sofra_catalogue -At \
  -c "SELECT count(*) FROM catalogue.revision")"
[[ "$revision_count" =~ ^[0-9]+$ ]] || {
  echo "ERROR: restored archive returned an invalid catalogue revision count" >&2
  exit 1
}

# A restored catalogue may validly contain zero revisions while every starter manifest
# is still a source-only draft. Verify both published views are readable, the reader has
# no schema-create or relation-write rights, and it cannot bypass the views to read base
# catalogue tables.
reader_acl="$(docker exec -i "$CONTAINER" psql -U sofra_catalogue_owner -d sofra_catalogue -At \
  -v ON_ERROR_STOP=1 <<'SQL'
WITH expected_access(relation_name, can_select) AS (
  VALUES
    ('public_revision', true),
    ('public_current', true),
    ('template', false),
    ('revision', false),
    ('revision_event', false)
), checked_access AS (
  SELECT can_select = has_table_privilege('sofra_catalogue_reader',
           format('catalogue.%I', relation_name), 'SELECT')
      AND NOT has_table_privilege('sofra_catalogue_reader', format('catalogue.%I', relation_name), 'INSERT')
      AND NOT has_table_privilege('sofra_catalogue_reader', format('catalogue.%I', relation_name), 'UPDATE')
      AND NOT has_table_privilege('sofra_catalogue_reader', format('catalogue.%I', relation_name), 'DELETE')
      AND NOT has_table_privilege('sofra_catalogue_reader', format('catalogue.%I', relation_name), 'TRUNCATE')
      AND NOT has_table_privilege('sofra_catalogue_reader', format('catalogue.%I', relation_name), 'REFERENCES')
      AND NOT has_table_privilege('sofra_catalogue_reader', format('catalogue.%I', relation_name), 'TRIGGER') AS valid
  FROM expected_access
)
SELECT has_schema_privilege('sofra_catalogue_reader', 'catalogue', 'USAGE')
   AND NOT has_schema_privilege('sofra_catalogue_reader', 'catalogue', 'CREATE')
   AND bool_and(valid)
FROM checked_access;
SQL
)"
[[ "$reader_acl" == "t" ]] || {
  echo "ERROR: restored reader role does not have view-only catalogue permissions" >&2
  exit 1
}
view_counts="$(docker exec "$CONTAINER" psql -U sofra_catalogue_reader -d sofra_catalogue -At \
  -v ON_ERROR_STOP=1 -c "SELECT (SELECT count(*) FROM catalogue.public_revision)::text || ':' ||
    (SELECT count(*) FROM catalogue.public_current)::text")"
[[ "$view_counts" =~ ^[0-9]+:[0-9]+$ ]] || {
  echo "ERROR: restored reader role returned invalid published-view counts" >&2
  exit 1
}
IFS=: read -r public_revision_count public_current_count <<< "$view_counts"

echo "Catalogue backup restore check passed: ${revision_count} immutable revision(s) restored; ${public_revision_count} published revision(s) and ${public_current_count} current template(s) visible; reader role is view-only."
