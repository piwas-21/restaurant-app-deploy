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
# Language for mail with NO guest to follow — the operator's own new-order and
# new-reservation alerts, and anything a background job sends. Unset = the FIRST
# entry of TENANT_LANGUAGES above, computed by the backend, which is what a tenant
# that sells in one language wants. Set it only to split the two: a venue whose
# staff read German while its guests are served French first. It must be one of the
# languages listed above (provision-tenant.sh refuses anything else) — a guest's own
# mail is NEVER affected by this, that follows the guest.
#   TENANT_DEFAULT_LANGUAGE=de
# The restaurant's own wall clock, as an IANA timezone id. Unset = Europe/Zurich,
# which is what the backend has always assumed. It decides the time printed in a
# mail (with its offset marker, e.g. "21:30 (UTC+02:00)") and the answer to "are we
# open now" — so a tenant outside Switzerland MUST set it or both are an hour or
# more out. provision-tenant.sh refuses an id the box does not know.
#   TENANT_TIMEZONE=Europe/Amsterdam
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

# --- Tenant→diner Stripe Connect (ADR-011 Job B, SOFRA-PAYMENTS-PLAN §4) -----------------
# All three lines are written by provision-tenant.sh on EVERY run, so they are recorded here
# only for readability — editing them by hand is overwritten on the next re-provision.
#
# STRIPE_PLATFORM_API_KEY is the BOX's, not the tenant's: a Stripe restricted key cannot be
# bound to a single connected account, so one key serves every tenant on the box and is
# narrowed by permission (Checkout write, PaymentIntent read, NO refunds) plus an Access
# policy pinning it to the box IPs. Empty on the box => every tenant here stays inert.
#
# STRIPE_ENABLED is DERIVED from the registry's `modules` list, not an operator switch —
# unlike TENANT_MODULES_ENFORCE above. A tenant that did not buy online-payments must not be
# one env edit away from taking card payments on someone else's Stripe account.
#
# Refunds are deliberately impossible from here: the restaurant has a full Stripe dashboard
# and a refund is two clicks there. That is what makes a leaked key survivable.
# Deliberately literal rather than __PLACEHOLDER__ substitutions: set_env_line rewrites all
# three on every run, so a placeholder would only ever be visible if that rewrite failed — and
# then it would render as the literal string, which STRIPE_ENABLED would reject at startup.
# Safe-by-default values mean a half-finished provision leaves the tenant inert, not broken.
STRIPE_ENABLED=false
STRIPE_PLATFORM_API_KEY=
STRIPE_CONNECTED_ACCOUNT_ID=

# --- Partner attribution (SOFRA-PARTNER-PLAN §11d, channel C) ----------------------------
# "Site by <name>", linked, in the tenant footer — the reseller who built and provisioned
# this site. Both lines are written by provision-tenant.sh on EVERY run from the registry's
# `partner_name` / `partner_url` / `partner_attribution`, so editing them by hand is
# overwritten on the next re-provision.
#
# The registry's BOOLEAN does not appear here, deliberately: provision-tenant.sh resolves it
# and writes EMPTY values when attribution is off, so this file — and the backend that reads
# it — carries exactly one meaning, WHAT TO DISPLAY. Empty = display nothing, which is also
# the state of every tenant with no partner. That is what makes switching attribution off
# REMOVE the credit on the next re-provision instead of merely not adding it.
#
# Literal empties rather than __PLACEHOLDER__ substitutions, for the same reason the three
# STRIPE_ lines above are: set_env_line rewrites both on every run, so a placeholder would
# only ever be visible if that rewrite failed — and it would then render as the literal
# string `__PARTNER_NAME__` in a diner's footer. Safe by default: a half-finished provision
# credits nobody rather than crediting a placeholder.
TENANT_PARTNER_NAME=
TENANT_PARTNER_URL=
