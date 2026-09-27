#!/usr/bin/env bash
# Exercise verify-catalogue-backup.sh with disposable, synthetic Postgres archives.
# One archive has the real catalogue shape but no revisions (the current draft state);
# a second proves a nonempty revision survives pg_dump/pg_restore. No deployment data
# or credentials are used.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY="$HERE/../verify-catalogue-backup.sh"
[[ -f "$VERIFY" ]] || { echo "cannot find verify-catalogue-backup.sh" >&2; exit 1; }

if ! docker info >/dev/null 2>&1; then
  echo "SKIP catalogue-backup-restore: docker unavailable"
  exit 0
fi

TMP="$(mktemp -d)"
CONTAINER="catalogue-backup-fixture-$$"
if ! command -v openssl >/dev/null 2>&1; then
  echo "ERROR: openssl is required to generate a disposable fixture password" >&2
  exit 1
fi
catalogue_fixture_password="$(openssl rand -hex 32)"
cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

POSTGRES_PASSWORD="$catalogue_fixture_password" docker run -d --rm --network none --name "$CONTAINER" \
  -e POSTGRES_USER=restore_admin \
  -e POSTGRES_PASSWORD \
  postgres:16 >/dev/null
unset catalogue_fixture_password

ready=0
for _ in $(seq 1 30); do
  if docker exec "$CONTAINER" pg_isready -U restore_admin >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
[[ "$ready" == "1" ]] || { echo "FAIL: fixture Postgres did not become ready" >&2; exit 1; }

docker exec -i "$CONTAINER" psql -U restore_admin -d postgres -v ON_ERROR_STOP=1 <<'SQL'
CREATE ROLE sofra_catalogue_owner LOGIN;
CREATE ROLE sofra_catalogue_reader LOGIN;
CREATE DATABASE sofra_catalogue OWNER sofra_catalogue_owner;
SQL

# Keep only the DB contract needed by the restore rehearsal. The repository's Sofra
# migration tests cover the full production DDL; this fixture isolates archive behavior.
docker exec -i "$CONTAINER" psql -U sofra_catalogue_owner -d sofra_catalogue -v ON_ERROR_STOP=1 <<'SQL'
CREATE SCHEMA catalogue;
REVOKE ALL ON SCHEMA catalogue FROM PUBLIC;
CREATE TABLE catalogue.template (template_id text PRIMARY KEY);
CREATE TABLE catalogue.revision (
  template_id text NOT NULL,
  revision integer NOT NULL,
  PRIMARY KEY (template_id, revision)
);
CREATE TABLE catalogue.revision_event (
  event_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  template_id text NOT NULL,
  revision integer NOT NULL,
  event_type text NOT NULL
);
CREATE VIEW catalogue.public_revision WITH (security_barrier = true) AS
  SELECT revision.template_id, revision.revision
  FROM catalogue.revision AS revision
  JOIN catalogue.revision_event AS event USING (template_id, revision)
  WHERE event.event_type = 'PUBLISHED';
CREATE VIEW catalogue.public_current WITH (security_barrier = true) AS
  SELECT DISTINCT ON (template_id) template_id, revision
  FROM catalogue.public_revision ORDER BY template_id, revision DESC;
GRANT USAGE ON SCHEMA catalogue TO sofra_catalogue_reader;
GRANT SELECT ON catalogue.public_revision, catalogue.public_current TO sofra_catalogue_reader;
SQL

dump_fixture() {
  local archive="$1"
  docker exec "$CONTAINER" pg_dump -Fc -U restore_admin -d sofra_catalogue > "$archive"
  [[ -s "$archive" ]] || { echo "FAIL: synthetic catalogue archive is empty" >&2; return 1; }
}

empty_archive="$TMP/catalogue-empty.dump"
dump_fixture "$empty_archive"
"$VERIFY" "$empty_archive" > "$TMP/empty-result.txt"
grep -Fq '0 immutable revision(s) restored; 0 published revision(s) and 0 current template(s) visible' "$TMP/empty-result.txt" || {
  cat "$TMP/empty-result.txt" >&2
  echo "FAIL: empty source-only catalogue was not accepted" >&2
  exit 1
}
echo "  ok   source-only empty catalogue archive restores with schema and reader ACLs"

docker exec "$CONTAINER" psql -U sofra_catalogue_owner -d sofra_catalogue -v ON_ERROR_STOP=1 \
  -c "INSERT INTO catalogue.template (template_id) VALUES ('synthetic-review-fixture')" \
  -c "INSERT INTO catalogue.revision (template_id, revision) VALUES ('synthetic-review-fixture', 1)" \
  -c "INSERT INTO catalogue.revision_event (template_id, revision, event_type) VALUES ('synthetic-review-fixture', 1, 'PUBLISHED')" >/dev/null

nonempty_archive="$TMP/catalogue-nonempty.dump"
dump_fixture "$nonempty_archive"
"$VERIFY" "$nonempty_archive" > "$TMP/nonempty-result.txt"
grep -Fq '1 immutable revision(s) restored; 1 published revision(s) and 1 current template(s) visible' "$TMP/nonempty-result.txt" || {
  cat "$TMP/nonempty-result.txt" >&2
  echo "FAIL: synthetic nonempty catalogue archive did not round-trip" >&2
  exit 1
}
echo "  ok   synthetic immutable revision survives pg_dump/pg_restore"
