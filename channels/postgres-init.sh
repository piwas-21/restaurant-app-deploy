#!/bin/bash
# Runs only on a fresh, dedicated sandbox volume. API role cannot alter/delete receipts.
set -euo pipefail
: "${CHANNELS_INGRESS_PASSWORD:?Missing ingress password}"
psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  --set=ON_ERROR_STOP=1 --set=app_password="$CHANNELS_INGRESS_PASSWORD" <<'SQL'
CREATE ROLE channels_ingress LOGIN PASSWORD :'app_password';
REVOKE CONNECT ON DATABASE channels_sandbox FROM PUBLIC;
GRANT CONNECT ON DATABASE channels_sandbox TO channels_ingress;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
SQL
