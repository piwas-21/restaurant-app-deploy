# Per-tenant compose project template (sofra ADR-001: instance-per-tenant).
# Rendered by provision-tenant.sh into /opt/rumi/tenants/<slug>/docker-compose.yml
# (__SLUG__-style tokens are replaced with sed; ${VAR} stays for compose runtime
# interpolation from the tenant dir's .env). Do NOT edit the rendered copy by
# hand — change this template / the registry and re-provision.
#
# Isolation model:
#   - own compose project (name: tenant-__SLUG__) -> own volumes (project-prefixed)
#   - own backend + frontend + redis containers; service names are slug-suffixed
#     because everything joins the SHARED deploy_rumi network (compose always
#     registers the service name as a DNS alias there — a bare "backend" would
#     collide with the box's RUMI stack and round-robin traffic across tenants)
#   - shared Postgres SERVER (the deploy stack's `postgres`), own database + role
#     per tenant (created by provision-tenant.sh)
#   - shared Caddy fronts the tenant via caddy-tenants/<slug>.caddy
#   - uploads are a host bind (not a named volume) under /opt/rumi/tenants/__SLUG__/uploads
#     so the shared Caddy can file_server them via its /srv/tenants parent mount

name: tenant-__SLUG__

# Per-tenant resource guardrails (DEV-PHASES-PLAN W0, sized 2026-07-07 like the
# base stack's): each tenant instance is capped at ~1.75g total so a runaway
# tenant can't starve the box or its neighbours.
services:
  backend-__SLUG__:
    image: ghcr.io/piwas-21/restaurant-app-backend:${BACKEND_TAG:-latest}
    pull_policy: always
    restart: unless-stopped
    mem_limit: 1g
    cpus: 2.0
    environment:
      ASPNETCORE_ENVIRONMENT: Production
      # Aspire components expect connection strings named "restaurantdb" / "redis".
      # The DB lives on the shared postgres server under the tenant's own database+role.
      # Maximum Pool Size caps this tenant's Npgsql pool (default 100) so tenants
      # can't exhaust the shared server's max_connections=300 (cost plan §5.2).
      ConnectionStrings__restaurantdb: "Host=postgres;Port=5432;Database=${TENANT_DB};Username=${TENANT_DB_ROLE};Password=${TENANT_DB_PASSWORD};Maximum Pool Size=20"
      ConnectionStrings__redis: "redis-__SLUG__:6379"
      # Fresh per-tenant admin bootstrap (backend #116): the seeder creates the
      # admin from these on first boot of an empty DB and skips when they're
      # absent. Values live only in the tenant .env on the box.
      SeedSettings__AdminEmail: "${TENANT_ADMIN_EMAIL:-}"
      SeedSettings__AdminPassword: "${TENANT_ADMIN_PASSWORD:-}"
      # Tenant identity seed (backend #120): fills the RestaurantInfo singleton
      # on the first boot of an empty DB while the row is pristine. No-op when
      # Name/Email are empty, and on any already-seeded DB — so existing
      # tenants keep their current identity even after a re-provision.
      RestaurantInfoSeed__Name: "${TENANT_NAME:-}"
      RestaurantInfoSeed__City: "${TENANT_CITY:-}"
      RestaurantInfoSeed__Email: "${TENANT_ADMIN_EMAIL:-}"
      # Emits the `tenant` claim in access tokens (backend #117) — makes a
      # token from this instance attributable to this tenant.
      JwtSettings__TenantSlug: "__SLUG__"
      # Registry-recorded tenant facts (ADR-007/ADR-010). Inert until module
      # enforcement ships (S11) — recorded now so re-provisioning is the only
      # mechanism that changes them.
      TENANT_SLUG: "__SLUG__"
      TENANT_CURRENCY: "${TENANT_CURRENCY}"
      # Feeds the backend's LocalizationSettings.Currency (Localization/Currency
      # config section/key) so this tenant's order emails show its own currency
      # instead of the CHF default. Empty-defaulted (:-) so the backend's own CHF
      # fallback stays the single source of truth. TENANT_CURRENCY above stays too
      # (inert record, same pattern as TENANT_LANGUAGES/TENANT_MODULES below).
      Localization__Currency: "${TENANT_CURRENCY:-}"
      TENANT_LANGUAGES: "${TENANT_LANGUAGES}"
      TENANT_MODULES: "${TENANT_MODULES}"
    volumes:
      - ./app-secrets.json:/app/app-secrets.json:ro
      - backend_keys:/app/keys
      - /opt/rumi/tenants/__SLUG__/uploads:/app/wwwroot/uploads
    depends_on:
      redis-__SLUG__:
        condition: service_healthy
    networks: [rumi]
    # Backend auto-runs EF migrations + seeders on startup — a fresh tenant DB
    # gets its schema, roles, working hours and the seeded admin automatically.

  frontend-__SLUG__:
    # Per-tenant image: NEXT_PUBLIC_* are baked per domain (frontend repo's
    # build-tenant-image.yml). There is no :latest fallback on purpose — a
    # missing tenant image must fail loudly, not silently serve another
    # tenant's baked URLs.
    image: ghcr.io/piwas-21/restaurant-app-frontend:${FRONTEND_TAG:?FRONTEND_TAG must be set in the tenant .env}
    pull_policy: always
    restart: unless-stopped
    mem_limit: 512m
    cpus: 1.0
    depends_on:
      - backend-__SLUG__
    networks: [rumi]

  # Per-tenant Redis container (ADR-001 left index-vs-container open; a container
  # avoids auditing the backend for DB-0 assumptions and costs a few MB).
  redis-__SLUG__:
    image: redis:7-alpine
    restart: unless-stopped
    mem_limit: 256m
    cpus: 1.0
    # maxmemory below the 256m container cap (Gemini triage on #22): the
    # backend uses redis as IDistributedCache — volatile-lru evicts only
    # TTL'd cache entries under pressure (graceful) instead of the container
    # getting OOM-killed; keys without TTL are never evicted.
    command:
      [
        "redis-server",
        "--appendonly", "yes",
        "--maxmemory", "192mb",
        "--maxmemory-policy", "volatile-lru",
      ]
    volumes:
      - redisdata:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks: [rumi]

networks:
  # The deploy stack's network — shared so Caddy can reverse_proxy the tenant
  # services and the tenant backend can reach the shared postgres.
  rumi:
    external: true
    name: deploy_rumi

volumes:
  backend_keys:
  redisdata:
