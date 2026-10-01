#!/usr/bin/env bash
# Prove fresh sandbox initialization and ingress privileges against real PostgreSQL.
set -euo pipefail
cd "$(dirname "$0")/.."
project="channels-db-test-$$"
fixture="$(mktemp)"
cleanup() {
  docker compose -p "$project" --env-file "$fixture" -f docker-compose.channels-sandbox.yml down -v >/dev/null 2>&1 || true
  rm -f "$fixture"
}
trap cleanup EXIT
cat > "$fixture" <<'ENV'
CHANNELS_OWNER_PASSWORD=ci-placeholder-owner
CHANNELS_INGRESS_PASSWORD=ci-placeholder-ingress
CHANNELS_SANDBOX_IMAGE=unused-in-database-test
UBER_SANDBOX_CLIENT_ID=ci-placeholder-client
UBER_SANDBOX_STORE_ID=89dd9741-66b5-4bb4-b216-a813f3b21b4f
ENV
compose=(docker compose -p "$project" --env-file "$fixture" -f docker-compose.channels-sandbox.yml)
"${compose[@]}" up -d --wait --wait-timeout 60 channels-db
owner=("${compose[@]}" exec -T channels-db psql -U channels_owner -d channels_sandbox -v ON_ERROR_STOP=1)
"${owner[@]}" <<'SQL'
CREATE TABLE channel_privilege_probe (id integer PRIMARY KEY);
GRANT USAGE ON SCHEMA public TO channels_ingress;
GRANT SELECT, INSERT ON channel_privilege_probe TO channels_ingress;
SQL
ingress=("${compose[@]}" exec -T -e PGPASSWORD=ci-placeholder-ingress channels-db psql
  -h 127.0.0.1 -U channels_ingress -d channels_sandbox -v ON_ERROR_STOP=1)
"${ingress[@]}" -c 'INSERT INTO channel_privilege_probe VALUES (1);'
[[ "$("${ingress[@]}" -Atc 'SELECT count(*) FROM channel_privilege_probe;')" == 1 ]]
if denial="$("${ingress[@]}" -c 'DELETE FROM channel_privilege_probe;' 2>&1)"; then
  echo 'ERROR: ingress role could delete receipts' >&2
  exit 1
fi
[[ "$denial" == *'permission denied'* ]]
if denial="$("${ingress[@]}" -c 'CREATE TABLE unauthorized_table (id integer);' 2>&1)"; then
  echo 'ERROR: ingress role could create schema objects' >&2
  exit 1
fi
[[ "$denial" == *'permission denied'* ]]
echo 'Sandbox database initialization, INSERT/SELECT and denied DELETE/CREATE passed'
