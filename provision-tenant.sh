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

echo "==> Preflight"
[[ -f .env ]] || { echo "ERROR: box .env missing"; exit 1; }
[[ -f "$REGISTRY" ]] || { echo "ERROR: $REGISTRY missing (push + sync the deploy repo first)"; exit 1; }
python3 -c 'import yaml' 2>/dev/null || { echo "ERROR: python3-yaml missing (apt-get install -y python3-yaml)"; exit 1; }

BOX_ROLE="$(grep -E '^BOX_ROLE=' .env | cut -d= -f2- || true)"
[[ -n "$BOX_ROLE" ]] || { echo "ERROR: BOX_ROLE not set in the box .env (prod|staging) — refusing to guess"; exit 1; }

# Shared fleet-observability + error-tracking config, flowed from the box .env into every
# tenant .env below so a new tenant gets fleet telemetry + Sentry automatically. Both are
# SHARED (not per-tenant): one SENTRY_DSN / PRINTER_TELEMETRY_SECRET per box. Empty on the
# box => that tenant's telemetry stays inert (the backend pusher self-guards; Sentry no-ops).
BOX_SENTRY_DSN="$(grep -E '^SENTRY_DSN=' .env | cut -d= -f2- || true)"
BOX_TELEMETRY_SECRET="$(grep -E '^PRINTER_TELEMETRY_SECRET=' .env | cut -d= -f2- || true)"

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
for k in ("name", "status", "managed", "box", "domain", "domain_mode",
          "domain_aliases", "db", "db_role", "compose_project", "backend_tag",
          "frontend_tag", "currency", "languages", "modules", "admin_email",
          "city", "template"):
    v = t.get(k, "")
    if isinstance(v, list):
        v = ",".join(map(str, v))
    print(f"REG_{k.upper()}={shlex.quote(str(v))}")
PY
)"

[[ "$REG_MANAGED" == "scripts" ]] || { echo "ERROR: tenant '$SLUG' is managed:'$REG_MANAGED' — this script only touches managed:scripts tenants (ADR-006 protects tenant 1)"; exit 1; }
[[ "$REG_BOX" == "$BOX_ROLE" ]] || { echo "ERROR: tenant '$SLUG' belongs on box '$REG_BOX' but this box is '$BOX_ROLE'"; exit 1; }
for f in name domain db db_role compose_project frontend_tag admin_email; do
  var="REG_$(echo "$f" | tr '[:lower:]' '[:upper:]')"
  [[ -n "${!var}" ]] || { echo "ERROR: registry entry '$SLUG' missing required field '$f'"; exit 1; }
done

# UI template (frontend ADR-006 / S15 T2): optional, absent -> classic. Anything
# outside the allowed set is a typo that must NOT silently provision as default.
TENANT_TEMPLATE="${REG_TEMPLATE:-classic}"
case "$TENANT_TEMPLATE" in
  classic|craft) ;;
  *) echo "ERROR: registry entry '$SLUG' has template '$TENANT_TEMPLATE' — allowed: classic | craft (absent = classic)"; exit 1 ;;
esac

# Module flags (ADR-010 catalog). Same reasoning as `template`: an unknown value
# is a typo, and a typo here is SILENT — it lands in the tenant env and the
# tenant simply never gets the module they are paying for. The vocabulary is
# mirrored in the control plane (sofra lib/module-catalog.ts) and here; both
# refuse, so a bad value cannot arrive from either direction.
# Trim whitespace from a comma-split registry value (the lists are hand-written
# YAML, so "a, b" is normal and " " is not a module).
strip_ws() { printf '%s' "$1" | tr -d '[:space:]'; }

KNOWN_MODULES="core kitchen-board cashier server reservations loyalty printing extra-languages"
IFS=',' read -ra _MODULES <<< "$REG_MODULES"
for m in "${_MODULES[@]}"; do
  m="$(strip_ws "$m")"
  [[ -z "$m" ]] && continue
  [[ " $KNOWN_MODULES " == *" $m "* ]] \
    || { echo "ERROR: registry entry '$SLUG' lists unknown module '$m' — allowed: $KNOWN_MODULES" >&2; exit 1; }
done
[[ " ${REG_MODULES//,/ } " == *" core "* ]] \
  || echo "WARN: tenant '$SLUG' has no 'core' module — every instance runs the core surface regardless" >&2

# Domain mode (ADR-002). Absent -> inferred from the domain, so pre-S10 entries
# keep working. The consistency check is the point: a `byo` entry that actually
# sits under sofrapiwas.com (or the reverse) sends the founder chasing the wrong
# DNS record, and the tenant sits certless while everyone looks at Caddy.
DOMAIN_MODE="$REG_DOMAIN_MODE"
if [[ -z "$DOMAIN_MODE" ]]; then
  [[ "$REG_DOMAIN" == *.sofrapiwas.com ]] && DOMAIN_MODE=subdomain || DOMAIN_MODE=byo
fi
case "$DOMAIN_MODE" in
  subdomain)
    [[ "$REG_DOMAIN" == "${SLUG}.sofrapiwas.com" ]] \
      || { echo "ERROR: domain_mode 'subdomain' expects domain '${SLUG}.sofrapiwas.com', registry says '$REG_DOMAIN' (use domain_mode: byo for a tenant-owned domain)" >&2; exit 1; } ;;
  byo)
    [[ "$REG_DOMAIN" == *.sofrapiwas.com ]] \
      && { echo "ERROR: domain_mode 'byo' but '$REG_DOMAIN' is ours — a sofrapiwas.com host rides the wildcard, use domain_mode: subdomain" >&2; exit 1; }
    [[ "$REG_DOMAIN" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] \
      || { echo "ERROR: '$REG_DOMAIN' is not a plausible hostname (lowercase labels, no scheme, no trailing dot)" >&2; exit 1; } ;;
  *) echo "ERROR: registry entry '$SLUG' has domain_mode '$DOMAIN_MODE' — allowed: subdomain | byo (absent = inferred)" >&2; exit 1 ;;
esac

# Optional extra hostnames that should reach this tenant (typically the `www.`
# of a BYO apex). They REDIRECT to the canonical domain rather than proxying:
# the frontend image bakes NEXT_PUBLIC_* for one origin, so serving the app on a
# second hostname would produce cross-origin API calls and a broken CORS story.
# Normalised ONCE into DOMAIN_ALIASES so every later loop iterates clean values.
DOMAIN_ALIASES=()
IFS=',' read -ra _RAW_ALIASES <<< "$REG_DOMAIN_ALIASES"
for _a in "${_RAW_ALIASES[@]}"; do
  _a="$(strip_ws "$_a")"
  [[ -z "$_a" ]] && continue
  [[ "$_a" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] \
    || { echo "ERROR: domain_alias '$_a' is not a plausible hostname" >&2; exit 1; }
  [[ "$_a" == "$REG_DOMAIN" ]] \
    && { echo "ERROR: domain_alias '$_a' duplicates the canonical domain" >&2; exit 1; }
  DOMAIN_ALIASES+=("$_a")
done

BOX_IP="$(curl -4 -sS --max-time 10 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
dns_check() { # $1=hostname — warn (never fail) so a propagating record doesn't block a re-run
  local host="$1" ip
  ip="$(getent hosts "$host" | awk '{print $1}' | head -1 || true)"
  [[ "$ip" == "$BOX_IP" ]] && return 0
  echo "WARN: $host resolves to '${ip:-nothing}' but this box is '$BOX_IP'." >&2
  if [[ "$DOMAIN_MODE" == byo ]]; then
    echo "      BYO domain: the tenant must create  A  $host  ->  $BOX_IP  (TTL >= 7200) at their registrar." >&2
  else
    echo "      Subdomain tenants ride the *.sofrapiwas.com wildcard A record — check it still points here." >&2
  fi
  echo "      Caddy cannot get a certificate until then. Continuing (a fresh record may still be propagating)." >&2
}
dns_check "$REG_DOMAIN"
for alias in "${DOMAIN_ALIASES[@]}"; do
  dns_check "$alias"
done

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

# Escape free-text registry values (name, city) for use in a sed REPLACEMENT:
# backslash, ampersand, and the | delimiter would otherwise corrupt the render.
sed_escape() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

# Replace-or-append KEY=value in the tenant .env (idempotent). $TENANT_DIR resolves at call
# time. Used for registry-owned identity lines and the shared fleet/Sentry values.
set_env_line() { # $1=key $2=value (free text)
  if grep -q "^$1=" "$TENANT_DIR/.env"; then
    sed -i "s|^$1=.*|$1=$(sed_escape "$2")|" "$TENANT_DIR/.env"
  else
    printf '%s=%s\n' "$1" "$2" >> "$TENANT_DIR/.env"
  fi
}

# Free-text values landing in the tenant .env are interpolated by docker
# compose — a literal $ must be doubled or compose silently mangles it (same
# trap as DEV_PORTAL_AUTH_HASH; see DEPLOYMENT.md §Developer Portal).
ENV_NAME="$(printf '%s' "$REG_NAME" | sed -e 's/\$/$$/g')"
ENV_CITY="$(printf '%s' "$REG_CITY" | sed -e 's/\$/$$/g')"

echo "==> Tenant .env"
FRESH_ENV=0
if [[ -f "$TENANT_DIR/.env" ]]; then
  echo "   keep: .env exists (DB password preserved). Registry tag/identity changes ARE re-applied below."
  # Re-apply the registry-owned values on every run (tags + identity are the
  # things that legitimately drift); generated secrets stay stable per tenant.
  sed -i -e "s|^BACKEND_TAG=.*|BACKEND_TAG=${REG_BACKEND_TAG:-latest}|" \
         -e "s|^FRONTEND_TAG=.*|FRONTEND_TAG=${REG_FRONTEND_TAG}|" "$TENANT_DIR/.env"
  # Identity lines may be absent on a pre-#16 .env — replace or append (set_env_line, top-level).
  set_env_line TENANT_NAME "$ENV_NAME"
  set_env_line TENANT_CITY "$ENV_CITY"
  set_env_line NEXT_PUBLIC_TEMPLATE "$TENANT_TEMPLATE"
else
  FRESH_ENV=1
  TENANT_DB_PASSWORD="$(rand 48 32)"
  # Admin bootstrap password (backend #116): the "!Aa1" suffix guarantees the
  # upper/lower/digit/symbol classes the backend's Identity policy requires —
  # random alnum alone can miss a class and the seeder would silently skip.
  TENANT_ADMIN_PASSWORD="$(rand 48 24)!Aa1"
  sed -e "s|__SLUG__|${SLUG}|g" \
      -e "s|__DOMAIN__|${REG_DOMAIN}|g" \
      -e "s|__NAME__|$(sed_escape "$ENV_NAME")|g" \
      -e "s|__CITY__|$(sed_escape "$ENV_CITY")|g" \
      -e "s|__BACKEND_TAG__|${REG_BACKEND_TAG:-latest}|g" \
      -e "s|__FRONTEND_TAG__|${REG_FRONTEND_TAG}|g" \
      -e "s|__DB__|${REG_DB}|g" \
      -e "s|__DB_ROLE__|${REG_DB_ROLE}|g" \
      -e "s|__DB_PASSWORD__|${TENANT_DB_PASSWORD}|g" \
      -e "s|__ADMIN_EMAIL__|${REG_ADMIN_EMAIL}|g" \
      -e "s|__ADMIN_PASSWORD__|${TENANT_ADMIN_PASSWORD}|g" \
      -e "s|__CURRENCY__|${REG_CURRENCY}|g" \
      -e "s|__LANGUAGES__|${REG_LANGUAGES}|g" \
      -e "s|__MODULES__|${REG_MODULES}|g" \
      -e "s|__TEMPLATE__|${TENANT_TEMPLATE}|g" \
      tenants/templates/tenant.env.tpl > "$TENANT_DIR/.env"
  chmod 600 "$TENANT_DIR/.env"
  echo "   wrote .env (fresh DB password + admin bootstrap credentials)"
fi
TENANT_DB_PASSWORD="$(grep '^TENANT_DB_PASSWORD=' "$TENANT_DIR/.env" | cut -d= -f2-)"

# Flow the shared fleet/Sentry values into the tenant .env on every run (fresh AND existing),
# so the tenant compose can interpolate ${SENTRY_DSN} / ${PRINTER_TELEMETRY_SECRET}. Rotatable —
# a changed box value is re-applied on the next provision. Reuses set_env_line (top-level).
set_env_line SENTRY_DSN "$BOX_SENTRY_DSN"
set_env_line SENTRY_ENVIRONMENT "$BOX_ROLE"
set_env_line PRINTER_TELEMETRY_SECRET "$BOX_TELEMETRY_SECRET"

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

echo "==> Admin bootstrap smoke check (seeded admin can log in)"
# Catches the silent-failure mode where an injected password fails the
# backend's Identity policy: the seeder logs an error but startup succeeds,
# leaving a tenant with no admin. Only meaningful on the boot that actually
# seeds — i.e. when this run rendered a fresh .env for a fresh DB. On
# re-provision the operator may have rotated the password (as instructed),
# so checking the bootstrap value again would falsely abort a healthy run.
ADMIN_EMAIL_CHECK="$(grep '^TENANT_ADMIN_EMAIL=' "$TENANT_DIR/.env" | cut -d= -f2- || true)"
ADMIN_PW_CHECK="$(grep '^TENANT_ADMIN_PASSWORD=' "$TENANT_DIR/.env" | cut -d= -f2- || true)"
if [[ "$FRESH_ENV" == 1 && -n "$ADMIN_EMAIL_CHECK" && -n "$ADMIN_PW_CHECK" ]]; then
  LOGIN_BODY="{\"email\":\"${ADMIN_EMAIL_CHECK}\",\"password\":\"${ADMIN_PW_CHECK}\"}"
  if docker run --rm --network deploy_rumi curlimages/curl:8.10.1 -sf -X POST \
       -H 'Content-Type: application/json' -d "$LOGIN_BODY" \
       "http://backend-${SLUG}:8080/api/auth/login" | grep -q '"success":true'; then
    echo "   admin login OK (${ADMIN_EMAIL_CHECK})"
  else
    echo "ERROR: seeded admin login FAILED — check backend logs for the seeder warning/error"
    echo "       (cd $TENANT_DIR && docker compose logs backend-${SLUG} | grep -i -A2 seed)"
    echo "       Note: the seeder only creates the admin on an EMPTY database; on an existing"
    echo "       DB the bootstrap credentials in .env do not apply (use the app's password reset)."
    exit 1
  fi
elif [[ "$FRESH_ENV" == 0 ]]; then
  echo "   skip: re-provision (bootstrap creds only apply to the first boot; the admin may have rotated the password since)"
else
  echo "   skip: no TENANT_ADMIN_* in the tenant .env (pre-#116 tenant — adopting needs a DB reset: deprovision --drop-db, then provision fresh)"
fi

echo "==> Caddy site block + validate + reload"
sed -e "s|__SLUG__|${SLUG}|g" \
    -e "s|__DOMAIN__|${REG_DOMAIN}|g" \
    tenants/templates/site.caddy.tpl > "caddy-tenants/${SLUG}.caddy"
# Alias hostnames get their own tiny redirect site (301 to the canonical origin),
# appended to the same file so teardown still removes everything in one unlink.
for alias in "${DOMAIN_ALIASES[@]}"; do
  cat >> "caddy-tenants/${SLUG}.caddy" <<CADDY

# Alias -> canonical. A redirect, not a proxy: the frontend bundle bakes
# NEXT_PUBLIC_* for one origin (see the alias note in provision-tenant.sh).
${alias} {
	redir https://${REG_DOMAIN}{uri} permanent
}
CADDY
  echo "   alias: ${alias} -> https://${REG_DOMAIN}"
done
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

# Printer-app onboarding bundle — the three values the tenant enters in the printer-app's
# Settings screen. The key is a box-only secret (never committed); surfaced here once so the
# founder can hand it over if the tenant buys the printer service.
PRINTER_KEY="$(python3 -c 'import json,sys; print((json.load(open(sys.argv[1])).get("PrinterSettings") or {}).get("ApiKey") or "")' "$TENANT_DIR/app-secrets.json" 2>/dev/null || true)"

cat <<EOF

==> Provisioned tenant '${SLUG}' (${REG_NAME})
    URL       : https://${REG_DOMAIN}   (cert issues on first hit; allow ~30s)
    Verify    : ./verify-env.sh https://${REG_DOMAIN}
    Containers: (cd ${TENANT_DIR} && docker compose ps)
    Logs      : (cd ${TENANT_DIR} && docker compose logs -f backend-${SLUG})
    Admin     : ${REG_ADMIN_EMAIL} — the generated bootstrap password is the
                TENANT_ADMIN_PASSWORD line in ${TENANT_DIR}/.env (mode 600).
                Log in and CHANGE IT before handing the tenant to anyone.
    Printer app (if the tenant buys the printer service — enter in the app's Settings):
                API Base URL : https://${REG_DOMAIN}
                Tenant Slug  : ${SLUG}
                Printer Key  : ${PRINTER_KEY}
                (the key is PrinterSettings.ApiKey in ${TENANT_DIR}/app-secrets.json)
    Fleet obs : automatic — this tenant's backend pushes to sofra /admin/fleet when
                PRINTER_TELEMETRY_SECRET is set on the box (currently: $([[ -n "$BOX_TELEMETRY_SECRET" ]] && echo set || echo UNSET → inert)).
EOF
