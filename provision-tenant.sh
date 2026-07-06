#!/usr/bin/env bash
# Stamp out (or idempotently re-apply) a tenant instance on THIS box — sofra
# ADR-001 (instance-per-tenant), ADR-003 (scripts-first provisioning),
# ADR-007 (registry-driven). Run ON THE BOX as the deploy user from
# /opt/rumi/deploy after the tenant is committed to tenants/registry.yml and
# synced here.
#
#   ./provision-tenant.sh <slug>
#
# What it does, in order:
#   1. preflight    — BOX_ROLE matches the registry entry; refuses managed:legacy
#   2. render       — /opt/rumi/tenants/<slug>/{.env,app-secrets.json,docker-compose.yml}
#                     (secrets are generated once and survive re-provision)
#   3. database     — tenant role + database on the shared postgres (idempotent)
#   4. containers   — pull + up the tenant compose project; wait for /api/health
#   5. caddy        — render caddy-tenants/<slug>.caddy + zero-downtime reload
#
# Prereqs (fail loudly if missing): DNS for the tenant domain points at this
# box (subdomain tenants ride the *.sofrapiwas.com wildcard); the per-tenant
# frontend image exists (frontend repo: build-tenant-image.yml).
#
# Teardown: ./deprovision-tenant.sh <slug> [--drop-db] [--purge]
set -euo pipefail
cd "$(dirname "$0")"

SLUG="${1:?usage: $0 <slug>   (a tenant key in tenants/registry.yml)}"
[[ "$SLUG" =~ ^[a-z0-9][a-z0-9-]{1,30}$ ]] || { echo "ERROR: slug must be lowercase [a-z0-9-], 2-31 chars"; exit 2; }

REGISTRY="tenants/registry.yml"
TENANT_DIR="/opt/rumi/tenants/${SLUG}"
DEPLOY_COMPOSE="docker compose -f docker-compose.prod.yml"
BE_REPO="ghcr.io/piwas-21/restaurant-app-backend"
FE_REPO="ghcr.io/piwas-21/restaurant-app-frontend"

echo "==> Preflight"
[[ -f .env ]] || { echo "ERROR: box .env missing"; exit 1; }
[[ -f "$REGISTRY" ]] || { echo "ERROR: $REGISTRY missing (push + sync the deploy repo first)"; exit 1; }
python3 -c 'import yaml' 2>/dev/null || { echo "ERROR: python3-yaml missing (apt-get install -y python3-yaml)"; exit 1; }

BOX_ROLE="$(grep -E '^BOX_ROLE=' .env | cut -d= -f2- || true)"
[[ -n "$BOX_ROLE" ]] || { echo "ERROR: BOX_ROLE not set in the box .env (prod|staging) — refusing to guess"; exit 1; }

# Read the tenant's registry entry into REG_* shell vars (lists -> csv).
eval "$(python3 - "$SLUG" <<'PY'
import sys, yaml, shlex
slug = sys.argv[1]
with open("tenants/registry.yml") as f:
    reg = yaml.safe_load(f)
t = (reg.get("tenants") or {}).get(slug)
if not t:
    print(f"echo 'ERROR: tenant {slug} not found in tenants/registry.yml'; exit 1")
    sys.exit(0)
for k in ("name", "status", "managed", "box", "domain", "domain_mode", "db",
          "db_role", "compose_project", "backend_tag", "frontend_tag",
          "currency", "languages", "modules", "admin_email"):
    v = t.get(k, "")
    if isinstance(v, list):
        v = ",".join(map(str, v))
    print(f"REG_{k.upper()}={shlex.quote(str(v))}")
PY
)"

[[ "$REG_MANAGED" == "scripts" ]] || { echo "ERROR: tenant '$SLUG' is managed:'$REG_MANAGED' — this script only touches managed:scripts tenants (ADR-006 protects tenant 1)"; exit 1; }
[[ "$REG_BOX" == "$BOX_ROLE" ]] || { echo "ERROR: tenant '$SLUG' belongs on box '$REG_BOX' but this box is '$BOX_ROLE'"; exit 1; }
for f in name domain db db_role compose_project frontend_tag; do
  var="REG_$(echo "$f" | tr '[:lower:]' '[:upper:]')"
  [[ -n "${!var}" ]] || { echo "ERROR: registry entry '$SLUG' missing required field '$f'"; exit 1; }
done

BOX_IP="$(curl -4 -sS --max-time 10 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
DOMAIN_IP="$(getent hosts "$REG_DOMAIN" | awk '{print $1}' | head -1 || true)"
if [[ "$DOMAIN_IP" != "$BOX_IP" ]]; then
  echo "WARN: $REG_DOMAIN resolves to '${DOMAIN_IP:-nothing}' but this box is '$BOX_IP'."
  echo "      Caddy cannot get a certificate until DNS points here. Continuing (record may still be propagating)."
fi

echo "==> Tenant dir: $TENANT_DIR"
# /opt/rumi/tenants is also bind-mounted (ro) into Caddy; if compose created it
# first it is root-owned — hand it to the deploy user via the docker group.
if [[ ! -w /opt/rumi/tenants ]]; then
  install -d /opt/rumi/tenants 2>/dev/null \
    || docker run --rm -v /opt/rumi:/r alpine:3 sh -c "mkdir -p /r/tenants && chown $(id -u):$(id -g) /r/tenants"
fi
install -d "$TENANT_DIR" "$TENANT_DIR/uploads"

# URL/connection-string-safe randoms (same recipe as gen-secrets.sh).
rand() { openssl rand -base64 "$1" | tr -d '/+=' | cut -c1-"$2"; }

echo "==> Tenant .env"
if [[ -f "$TENANT_DIR/.env" ]]; then
  echo "   keep: .env exists (DB password preserved). Registry tag changes ARE re-applied below."
  # Re-pin image tags from the registry on every run (they're the one thing
  # that legitimately drifts); everything else in .env is stable per tenant.
  sed -i -e "s|^BACKEND_TAG=.*|BACKEND_TAG=${REG_BACKEND_TAG:-latest}|" \
         -e "s|^FRONTEND_TAG=.*|FRONTEND_TAG=${REG_FRONTEND_TAG}|" "$TENANT_DIR/.env"
else
  TENANT_DB_PASSWORD="$(rand 48 32)"
  sed -e "s|__SLUG__|${SLUG}|g" \
      -e "s|__DOMAIN__|${REG_DOMAIN}|g" \
      -e "s|__BACKEND_TAG__|${REG_BACKEND_TAG:-latest}|g" \
      -e "s|__FRONTEND_TAG__|${REG_FRONTEND_TAG}|g" \
      -e "s|__DB__|${REG_DB}|g" \
      -e "s|__DB_ROLE__|${REG_DB_ROLE}|g" \
      -e "s|__DB_PASSWORD__|${TENANT_DB_PASSWORD}|g" \
      -e "s|__CURRENCY__|${REG_CURRENCY}|g" \
      -e "s|__LANGUAGES__|${REG_LANGUAGES}|g" \
      -e "s|__MODULES__|${REG_MODULES}|g" \
      tenants/templates/tenant.env.tpl > "$TENANT_DIR/.env"
  chmod 600 "$TENANT_DIR/.env"
  echo "   wrote .env (fresh DB password)"
fi
TENANT_DB_PASSWORD="$(grep '^TENANT_DB_PASSWORD=' "$TENANT_DIR/.env" | cut -d= -f2-)"

echo "==> Tenant app-secrets.json"
if [[ -f "$TENANT_DIR/app-secrets.json" ]]; then
  echo "   keep: app-secrets.json exists (JWT/printer secrets preserved)"
else
  # Reuse this box's Resend key (tenants send via onboarding@resend.dev — see
  # template note). Reads the key from the box's own app-secrets.json.
  RESEND_KEY="$(python3 -c 'import json;print(json.load(open("app-secrets.json")).get("EmailSettings",{}).get("ResendApiKey",""))' 2>/dev/null || true)"
  [[ -n "$RESEND_KEY" ]] || echo "   WARN: no ResendApiKey found in the box app-secrets.json — tenant email will fail until set"
  JWT_SECRET="$(openssl rand -base64 48)"
  PRINTER_APIKEY="$(openssl rand -hex 32)"
  # Rendered with python3, not sed: values like the base64 JWT secret or a
  # free-text tenant name can contain sed metacharacters (&, |) that would
  # silently corrupt the JSON. Also parse-checks the result before writing.
  T_SLUG="$SLUG" T_DOMAIN="$REG_DOMAIN" T_NAME="$REG_NAME" T_ADMIN="$REG_ADMIN_EMAIL" \
  T_JWT="$JWT_SECRET" T_PRINTER="$PRINTER_APIKEY" T_RESEND="$RESEND_KEY" \
  T_OUT="$TENANT_DIR/app-secrets.json" python3 - <<'PY'
import json, os
tpl = open("tenants/templates/app-secrets.tenant.json.tpl").read()
for token, env in (("__SLUG__", "T_SLUG"), ("__DOMAIN__", "T_DOMAIN"),
                   ("__TENANT_NAME__", "T_NAME"), ("__ADMIN_EMAIL__", "T_ADMIN"),
                   ("__JWT_SECRET__", "T_JWT"), ("__PRINTER_APIKEY__", "T_PRINTER"),
                   ("__RESEND_API_KEY__", "T_RESEND")):
    tpl = tpl.replace(token, json.dumps(os.environ[env])[1:-1])
json.loads(tpl)  # refuse to write corrupt JSON
os.umask(0o177)
with open(os.environ["T_OUT"], "w") as f:
    f.write(tpl)
PY
  chmod 600 "$TENANT_DIR/app-secrets.json"
  echo "   wrote app-secrets.json (fresh JWT + printer key, mode 600)"
fi

echo "==> Render docker-compose.yml"
sed -e "s|__SLUG__|${SLUG}|g" \
    tenants/templates/docker-compose.tenant.yml.tpl > "$TENANT_DIR/docker-compose.yml"

echo "==> Database (role + db on the shared postgres, idempotent)"
PGUSER="$(grep '^POSTGRES_USER=' .env | cut -d= -f2- || true)"
[[ -n "$PGUSER" ]] || { echo "ERROR: POSTGRES_USER not set in .env"; exit 1; }
psql_deploy() { $DEPLOY_COMPOSE exec -T postgres psql -v ON_ERROR_STOP=1 -U "$PGUSER" -d postgres "$@"; }
if psql_deploy -tAc "SELECT 1 FROM pg_roles WHERE rolname='${REG_DB_ROLE}'" | grep -q 1; then
  echo "   keep: role ${REG_DB_ROLE} exists"
else
  psql_deploy -c "CREATE ROLE ${REG_DB_ROLE} LOGIN PASSWORD '${TENANT_DB_PASSWORD}'"
  echo "   created role ${REG_DB_ROLE}"
fi
if psql_deploy -tAc "SELECT 1 FROM pg_database WHERE datname='${REG_DB}'" | grep -q 1; then
  echo "   keep: database ${REG_DB} exists"
else
  psql_deploy -c "CREATE DATABASE ${REG_DB} OWNER ${REG_DB_ROLE}"
  echo "   created database ${REG_DB} (owner ${REG_DB_ROLE})"
fi

echo "==> Pull images (project tenant-${SLUG})"
(cd "$TENANT_DIR" && docker compose pull)

echo "==> Fix file ownership for the backend container user"
# Backend runs non-root; app-secrets.json must be group-readable by its gid and
# the uploads bind dir writable by its uid. rumi's docker-group membership is
# the privilege here — no sudo (box sudo is deliberately scoped). Runs after
# the pull so the uid:gid inspection never triggers (or fails on) an implicit
# image pull of its own.
BE_IDS="$(docker run --rm --entrypoint sh "${BE_REPO}:${REG_BACKEND_TAG:-latest}" -c 'echo "$(id -u):$(id -g)"' 2>/dev/null || true)"
if [[ -n "$BE_IDS" ]]; then
  docker run --rm -v "$TENANT_DIR":/t alpine:3 sh -c \
    "chown $(id -u):${BE_IDS#*:} /t/app-secrets.json && chmod 640 /t/app-secrets.json && chown -R ${BE_IDS} /t/uploads"
  echo "   app-secrets.json -> $(id -un):${BE_IDS#*:} mode 640; uploads -> ${BE_IDS}"
else
  echo "   WARN: could not determine backend uid:gid; secrets/uploads may be unreadable by the container"
fi

echo "==> Up (project tenant-${SLUG})"
(cd "$TENANT_DIR" && docker compose up -d)

echo "==> Wait for backend health (migrations + seed run on first boot)"
for i in $(seq 1 60); do
  if docker run --rm --network deploy_rumi curlimages/curl:8.10.1 -sf "http://backend-${SLUG}:8080/api/health" >/dev/null 2>&1; then
    echo "   backend-${SLUG} healthy"
    break
  fi
  [[ "$i" == 60 ]] && { echo "ERROR: backend-${SLUG} not healthy after 5m — check: (cd $TENANT_DIR && docker compose logs backend-${SLUG})"; exit 1; }
  sleep 5
done

echo "==> Caddy site block + validate + reload"
sed -e "s|__SLUG__|${SLUG}|g" \
    -e "s|__DOMAIN__|${REG_DOMAIN}|g" \
    tenants/templates/site.caddy.tpl > "caddy-tenants/${SLUG}.caddy"
# The tenants dir is bind-mounted as a DIRECTORY, so the new file is already
# visible in the container and a plain reload re-globs the imports (the
# single-file Caddyfile inode gotcha only applies to the main Caddyfile).
# Validate FIRST and roll the file back on failure — never force-recreate here:
# recreating with a broken import would take down every site on the box.
if ! $DEPLOY_COMPOSE exec caddy caddy validate --config /etc/caddy/Caddyfile; then
  rm -f "caddy-tenants/${SLUG}.caddy"
  echo "ERROR: rendered caddy block failed validation — removed it again; live config untouched"
  exit 1
fi
$DEPLOY_COMPOSE exec caddy caddy reload --config /etc/caddy/Caddyfile

cat <<EOF

==> Provisioned tenant '${SLUG}' (${REG_NAME})
    URL       : https://${REG_DOMAIN}   (cert issues on first hit; allow ~30s)
    Verify    : ./verify-env.sh https://${REG_DOMAIN}
    Containers: (cd ${TENANT_DIR} && docker compose ps)
    Logs      : (cd ${TENANT_DIR} && docker compose logs -f backend-${SLUG})
    ⚠ The backend seeds a default admin (admin@email.com) with a WELL-KNOWN
      password on a fresh DB — log in and change it BEFORE handing the tenant
      to anyone (tracked as a provisioning-v2 hardening item).
EOF
