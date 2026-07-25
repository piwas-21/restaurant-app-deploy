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
# UI template (frontend ADR-006 / S15 T2): classic | craft, from the registry's
# optional `template` field (absent -> classic; anything else fails provisioning).
# NEXT_PUBLIC_* are baked at frontend image build, so this line records intent —
# it becomes effective with the frontend T2 template-alias PR (build input).
NEXT_PUBLIC_TEMPLATE=__TEMPLATE__
