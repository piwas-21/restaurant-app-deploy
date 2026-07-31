# Tenant instance .env — rendered by provision-tenant.sh into
# /opt/rumi/tenants/<slug>/.env (box-only, never committed; survives
# re-provision so the DB password is stable). Values come from
# tenants/registry.yml at render time; image tags are re-pinnable here the
# same way BACKEND_TAG/FRONTEND_TAG work for the main stack.
TENANT_SLUG=__SLUG__
TENANT_DOMAIN=__DOMAIN__
# Tenant identity (deploy#16): seeds the RestaurantInfo singleton on the first
# boot of an empty DB via RestaurantInfoSeed__* in the compose template
# (backend #120). Free text — provision-tenant.sh escapes sed metacharacters.
TENANT_NAME=__NAME__
TENANT_CITY=__CITY__
BACKEND_TAG=__BACKEND_TAG__
FRONTEND_TAG=__FRONTEND_TAG__
TENANT_DB=__DB__
TENANT_DB_ROLE=__DB_ROLE__
TENANT_DB_PASSWORD=__DB_PASSWORD__
# Seeded admin bootstrap (backend #116) — generated once at provision time;
# the operator logs in with these and changes the password immediately.
TENANT_ADMIN_EMAIL=__ADMIN_EMAIL__
TENANT_ADMIN_PASSWORD=__ADMIN_PASSWORD__
# Login attempts allowed per 15-minute window, per client IP. Unset = the
# backend's production default (5). Raise it ONLY on a staging surface (demo);
# a real tenant is production and keeps the tight throttle.
#   TENANT_AUTH_PERMIT_LIMIT=20
TENANT_CURRENCY=__CURRENCY__
TENANT_LANGUAGES=__LANGUAGES__
TENANT_MODULES=__MODULES__
# Module RUNTIME ENFORCEMENT (backend #268 / sofra ADR-010). This file is rendered
# ONLY when a tenant is provisioned for the FIRST time, so `true` here is the
# birth default: a new tenant is held to the TENANT_MODULES list above from its
# first boot. That is what the customer paid for — before this line was active a
# tenant buying Core (€19) received all eight modules, and closing that gap was a
# per-tenant step nothing in the funnel performed.
#
# It stays an OPERATOR control, not a registry field: provision-tenant.sh only
# *validates* this line on a re-provision and never rewrites or clears it, so a
# tenant you deliberately un-enforce stays un-enforced across registry edits.
#
# Exactly `true` or `false`. It binds to a C# bool the backend resolves at startup,
# so `1`/`yes`/`on` do not mean true — they throw before the app listens and
# crash-loop the container. provision-tenant.sh rejects them.
#
# Two safety valves mean this default cannot stand a tenant up crippled: an empty
# TENANT_MODULES reads as unrestricted, and `core` is always on regardless of the
# list. Verify the effective set against the running instance, never this file:
#   curl -s https://<domain>/api/tenant/modules
# To un-enforce: set `false` here and `docker compose up -d --force-recreate
# backend-<slug>`.
TENANT_MODULES_ENFORCE=true
# UI template (frontend ADR-006 / S15 T2): classic | craft, from the registry's
# optional `template` field (absent -> classic; anything else fails provisioning).
# NEXT_PUBLIC_* are baked at frontend image build, so this line records intent —
# it becomes effective with the frontend T2 template-alias PR (build input).
NEXT_PUBLIC_TEMPLATE=__TEMPLATE__
