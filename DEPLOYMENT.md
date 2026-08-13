# RUMI + Sofra — Deployment & Rollback runbook

Canonical runbook for shipping RUMI to production (and Sofra to the staging box)
and rolling back. Each environment is a single Netcup box running the stack via
Docker Compose; images are built in CI and pulled from GHCR. The app repos link here.

> **Audience:** anyone promoting a release or responding to a bad deploy.
> **Box / secrets setup:** see [README.md](README.md).

---

## Topology

```
merge to main ─► build-image.yml ─► GHCR (:latest, :sha-<commit>) ─► deploy.yml ─► SSH ─► box: deploy.sh
 (app repo)       (build + push)        (image registry)            (auto/manual)        (pull + up -d)

push to main ─► sync-to-box.yml (prod) + sync-to-staging.yml (staging) ─► rsync ─► box: /opt/rumi/deploy   (this repo: infra files only)
 (this repo)
```

- **Two app repos, one box.** `restaurant-app-backend` and `restaurant-app-frontend`
  each build their own image and each have their own `deploy.yml`. A deploy from
  one repo only re-points **that repo's** service.
- **This repo is the source of truth for infra files** (compose, Caddyfile,
  `deploy.sh`, scripts). `sync-to-box.yml` rsyncs them to the box on every push;
  the box is a plain directory, not a git checkout.
- **Image tags.** Every push to `main` publishes `latest` (moving) and
  `sha-<40-hex-commit>` (immutable). Rollbacks target the immutable `sha-` tag.
- **`.env` on the box pins what's running:** `BACKEND_TAG` / `FRONTEND_TAG`.
  `deploy.sh` persists whatever tag it deploys, so a rollback survives restarts
  and the next real release moves the service forward again.

---

## Staging environment (separate box)

A **second, independent Netcup box** (`v2202607374190477434.megasrv.de`,
`159.195.34.105`) runs the same stack as a staging/rehearsal environment, fully
isolated from the client's prod box. Purpose: validate fixes and the SaaS
transition live before promoting to the one production tenant (rumirestaurant.ch).

**How staging differs from prod — three files only:**
- `Caddyfile.staging` — same routing, different site address (the box's own
  `*.megasrv.de` host, which Let's Encrypt issues for reliably). Selected via
  `CADDYFILE=./Caddyfile.staging` in the staging box's `.env` — the compose file
  (`docker-compose.prod.yml`) and `deploy.sh` are **shared, unchanged**.
- `.env.staging.example` → the box's `.env`: `FRONTEND_TAG=staging`,
  `BACKEND_TAG=staging`, fresh Postgres creds.
- `app-secrets.staging.example.json` → the box's `app-secrets.json`: staging URLs,
  CORS = the staging origin, and email via `onboarding@resend.dev` so staging
  **cannot dent rumirestaurant.ch's sending reputation**.

**Image model:** staging tracks `develop`; **both** services pin their repo's
moving **`:staging`** tag, published on every `develop` push. The **frontend**
`:staging` image differs from prod's (it bakes staging `NEXT_PUBLIC_*` at build
time); the **backend** image is domain-agnostic (URLs/CORS come from
`app-secrets.json`), so its `:staging` tag is just an alias for the same `develop`
build's `:sha-<commit>`. **Do not pin `BACKEND_TAG=latest`** — since 2026-07-16
`:latest` means `main` (prod), so it would roll staging back to prod code on
deploy (the `:latest` fix gated it to `main`; backend + frontend both publish
`:staging` from `develop`).

**First-time bring-up (once the box is provisioned):**
```bash
# 1. Provision (as root on the staging box) — installs Docker, rumi user, hardening:
ssh root@159.195.34.105 'bash -s' < provision.sh      # SEED SSH_PUBKEY first (see README)
# 2. Get infra files onto the box (manual until sync-to-staging.yml is enabled):
rsync -az --exclude='.git/' --exclude='.env' --exclude='app-secrets.json' \
  ./ rumi@159.195.34.105:/opt/rumi/deploy/
# 3. On the box: scaffold .env + app-secrets.json FROM THE STAGING TEMPLATES with
#    fresh random secrets (gen-secrets skips files that already exist, so let it
#    create them — do NOT pre-copy):
ssh rumi@159.195.34.105
cd /opt/rumi/deploy
ENV_EXAMPLE=.env.staging.example SECRETS_EXAMPLE=app-secrets.staging.example.json ./gen-secrets.sh
#   then edit .env (DEV_PORTAL_AUTH_HASH) + app-secrets.json (ResendApiKey, AdminEmail).
#   CADDYFILE / STAGING_DOMAIN / FRONTEND_TAG=staging are already set by the template.
# 4. Dozzle login must exist BEFORE the stack starts, or Docker creates a directory at
#    the bind-mount path and dozzle fails to start:
docker run --rm amir20/dozzle:v10.6.6 generate admin --name 'RUMI Staging Ops' --password 'CHOOSE_ONE' > dozzle-users.yml
# 5. Deploy (DNS already resolves — it's the box's own hostname):
./deploy.sh
```
Verify: `https://v2202607374190477434.megasrv.de/` (200) and
`.../api/health` (200), same as the prod checks below.

**Auto-sync:** `sync-to-staging.yml` triggers on push to `main` (enabled 2026-07-03
once the `STAGING_*` repo secrets were set), so staging tracks infra changes
automatically (like `sync-to-box.yml` does for prod). `workflow_dispatch` remains
available for manual re-syncs.

### Sofra marketing site (staging box only)

The staging box also serves the Sofra landing page (`https://sofrapiwas.com`,
image `ghcr.io/piwas-21/sofra`) — see the `sofra` service in
`docker-compose.prod.yml`. It is gated behind the `sofra` compose profile: the
staging box sets `COMPOSE_PROFILES=sofra` (plus `SOFRA_DOMAIN`,
`SOFRA_WWW_DOMAIN`, and the waitlist vars — see `.env.staging.example`) in its
`.env`; prod sets none of them, so nothing changes there. Roll out with
`docker compose -f docker-compose.prod.yml up -d sofra` and remember a changed
`Caddyfile.staging` needs `up -d --force-recreate caddy` (bind-mount inode
gotcha). Verify: `https://sofrapiwas.com/en` (200) and the RUMI staging URL
still healthy.

#### Sofra control plane (partner program — DB + migrations)

The sofra app has its own database (`sofra` DB + role) on the shared postgres
container (sofra ADR-008). One-time setup:

```bash
cd /opt/rumi/deploy
# role + database (password = SOFRA_DB_PASSWORD from .env)
docker compose -f docker-compose.prod.yml exec postgres \
  psql -U rumi -d postgres -c "CREATE ROLE sofra LOGIN PASSWORD '<SOFRA_DB_PASSWORD>'" \
                            -c "CREATE DATABASE sofra OWNER sofra"
```

**Every release that ships migrations** (founder-run — migrations never run on
container start):

```bash
docker pull ghcr.io/piwas-21/sofra:migrate
docker run --rm --network deploy_rumi \
  -e DATABASE_URL="postgresql://sofra:<SOFRA_DB_PASSWORD>@postgres:5432/sofra" \
  ghcr.io/piwas-21/sofra:migrate          # = prisma migrate deploy
docker compose -f docker-compose.prod.yml up -d sofra
```

#### Sofra STAGING control plane (develop-tracking)

A second control plane at `staging.sofrapiwas.com`, on the same box and the same shared
postgres, with its **own database** — so the deployed control plane can be exercised
without touching production data. Opt in with `sofra-staging` in `COMPOSE_PROFILES`.

Why it exists: the sofra repo's own e2e suite is already unmocked (real build, real
Postgres, a real Mollie **test-key** payment), but it runs locally. It cannot see the
things that only exist once deployed — env wiring, the founder-run migrate one-off,
Caddy, and the actually-published image.

One-time setup:

```bash
cd /opt/rumi/deploy
# role + database (password = SOFRA_STAGING_DB_PASSWORD from .env)
docker compose -f docker-compose.prod.yml exec postgres \
  psql -U rumi -d postgres -c "CREATE ROLE sofra_staging LOGIN PASSWORD '<SOFRA_STAGING_DB_PASSWORD>'" \
                            -c "CREATE DATABASE sofra_staging OWNER sofra_staging"
```

Every develop merge that ships migrations (same founder-run rule as prod, against the
**`:migrate-staging`** image so the schema matches develop, not main):

```bash
docker pull ghcr.io/piwas-21/sofra:migrate-staging
docker run --rm --network deploy_rumi \
  -e DATABASE_URL="postgresql://sofra_staging:<SOFRA_STAGING_DB_PASSWORD>@postgres:5432/sofra_staging" \
  ghcr.io/piwas-21/sofra:migrate-staging
docker compose -f docker-compose.prod.yml pull sofra-staging
docker compose -f docker-compose.prod.yml up -d sofra-staging
```

**Box `.env` keys** — `SOFRA_STAGING_DB_PASSWORD`, `SOFRA_STAGING_AUTH_SECRET` (its own,
never prod's — a shared secret would make a staging session valid on sofrapiwas.com),
`SOFRA_STAGING_DOMAIN=staging.sofrapiwas.com`, and `MOLLIE_API_KEY_TEST` (the **test**
key; the service maps it to `MOLLIE_API_KEY`).

**Left unset on purpose** — each is a live capability on prod that a staging copy would
aim at the real world: `PROVISION_GITHUB_TOKEN` (would open real registry PRs),
`RESEND_API_KEY` (would email real people), `PRINTER_TELEMETRY_SECRET`, `CRON_SECRET`
(the retention sweep is data-loss class). Do not copy the prod values across.

Not indexed: `robots.ts` disallows everything when the baked `NEXT_PUBLIC_SITE_URL` is
not the canonical host, and Caddy adds `X-Robots-Tag: noindex` for crawlers that skip
robots.txt. The staging image is its own bake for exactly this reason.

**Confirming what is actually deployed** (either sofra environment): `curl -s https://<host>/api/health`
returns the commit the running image was baked from —

```bash
curl -s https://staging.sofrapiwas.com/api/health
# {"status":"ok","service":"sofra-control-plane","version":"<sha>","builtAt":"…"}
```

Use it to confirm a rollout landed, or which build to roll back to. `status: "ok"` means the
process serves HTTP — it does **not** mean the database is reachable, by design.

Verify with the suite, not by hand — `npm run test:e2e:staging` in the sofra repo
(`tests/e2e/staging-live.spec.ts`). It checks the entry points serve, that staging is
noindex in **both** robots.txt and the header while production is still crawlable, that an
admin can sign in (which is what proves the box env reached the container and the migrate
one-off actually ran), that a Mollie key is wired in, and — asserted positively — that
provisioning is still DISARMED. It is read-only: no account, no payment, no row.

It needs `STAGING_ADMIN='{email: …, password: …}'` in the sofra repo's gitignored `.env`.
**The quotes are load-bearing**: `scripts/e2e-suite.sh` sources that file with
`set -a && . ./.env`, and bash reads an unquoted brace value as an assignment followed by a
command, which kills the whole local e2e suite under `set -euo pipefail`.

Do not run the rest of the Playwright directory against this host — those specs mutate
(real signups, real test-key payments). `playwright.config.ts` enforces the split both
ways, so an `E2E_REMOTE` run cannot reach them however it is invoked.

---

**One-time admin seed** (then use the site's "Forgot password" to set your own):

```bash
docker run --rm --network deploy_rumi \
  -e DATABASE_URL="postgresql://sofra:<SOFRA_DB_PASSWORD>@postgres:5432/sofra" \
  -e ADMIN_EMAIL=<founder email> -e ADMIN_NAME=Founder -e ADMIN_PASSWORD=<throwaway ≥12 chars> \
  ghcr.io/piwas-21/sofra:migrate node scripts/seed-admin.mjs
```

Verify: `https://sofrapiwas.com/login` 200, sign-in works, and the RUMI
staging URL still healthy. The sofra DB is covered by the nightly
cluster-wide `pg_dumpall` (see §Backups & restore).

---

## Tenant provisioning (S14 v1 — sofra ADR-001/003/007)

Each tenant is its **own compose project** (backend + frontend + redis) behind
the box's shared Caddy and Postgres, stamped out by `provision-tenant.sh` from
the committed registry (`tenants/registry.yml`). Founder-operated; the control
plane later calls the same scripts (ADR-003 — no parallel mechanism).

**Provision a tenant (in order):**

1. **Registry**: add the tenant to `tenants/registry.yml` (slug, domain, db,
   tags, currency/languages/modules, `city` for the seeded RestaurantInfo
   identity), PR → merge → sync to the box.

   **`template`** (optional, frontend ADR-006 / S15 T2): the tenant's UI
   template — `classic` (the current RUMI look) or `craft`; absent = `classic`.
   `provision-tenant.sh` validates it (any other value fails loudly) and renders
   it into the tenant `.env` as `NEXT_PUBLIC_TEMPLATE`. It is consumed at
   frontend **image build** via the `build-tenant-image.yml` `template` input +
   Dockerfile ARG (shipped 2026-07-10, frontend #165; `craft` is buildable
   since frontend #166 — its full T3 DoD is still in progress).
2. **DNS**: subdomain tenants ride the `*.sofrapiwas.com` wildcard A record
   (already points at the staging box, added 2026-07-06 via
   `./domainio-dns.sh add-a sofrapiwas.com '*' 159.195.34.105`). BYO domains
   need their own A record + nothing else — the same script provisions them.
3. **Frontend image**: `NEXT_PUBLIC_*` are baked per domain, so build the
   tenant's image first (frontend repo):
   `gh workflow run build-tenant-image.yml -f tenant_domain=<domain> -f image_tag=tenant-<slug> -f restaurant_name="<registry name>" -f template=<registry template> -f currency=<registry currency>`
   — `restaurant_name` bakes the page-metadata `<title>` (frontend #125 part 1);
   `template` bakes the UI template (ADR-006, default `classic`); `currency`
   bakes `NEXT_PUBLIC_TENANT_CURRENCY` for all displayed prices (frontend #169,
   default `CHF` — pair it with the registry `currency:` field, whose backend
   half `TENANT_CURRENCY` → `Localization__Currency` ships via the tenant
   compose template since #33). All three are optional (defaults preserve old
   dispatches) but every real tenant should pass the registry values.
4. **Provision** (on the box):
   ```bash
   bash .ssh/staging.sh 'cd /opt/rumi/deploy && ./provision-tenant.sh <slug>'
   ```
   Idempotent: re-running re-pins image tags from the registry and re-applies
   compose/caddy, but never regenerates existing secrets or the DB password.
5. **Verify**: `./verify-env.sh https://<domain>` (200 + 200). The script has
   already smoke-checked that the seeded admin can log in — a **fresh random
   password per tenant** (backend #116), injected via `SeedSettings__*` env
   vars and stored only as `TENANT_ADMIN_PASSWORD` in the tenant `.env`
   (mode 600). Log in with it and **change it** before handing the tenant over.
   Tenant identity (deploy#16): `curl -s https://<domain>/api/restaurant-info`
   should return the registry name/city/admin_email (not RUMI values), the
   page `<title>` and footer © should show the tenant name, and a decoded
   access token should carry `tenant: <slug>` (backend #117).

### Tenant sending identity (`PLATFORM_MAIL_DOMAIN` — EMAIL-IDENTITY-PLAN)

A tenant's `FromEmail` is resolved at provision time, in precedence order:

| source | result |
|---|---|
| the registry entry's `mail_from:` | that address — the tenant brought its **own** Resend-verified domain |
| box `.env` `PLATFORM_MAIL_DOMAIN` | `<slug>@<domain>` — the shared platform domain, the normal case |
| neither | `onboarding@resend.dev` — **broken, see below** |

`FromName` is always the restaurant's registry `name`, so a guest reads
`Kebab House <kebabhouse@send.sofrapiwas.com>`. Only the envelope domain is shared.

⚠️ **The fallback does not degrade, it fails.** Resend accepts `onboarding@resend.dev`
**only for the Resend account owner's own address** and answers **403** for every other
recipient. A tenant left on it serves its guests perfectly and emails none of them:
`/forgot-password` answers **HTTP 502** to the owner permanently, while verification,
welcome and order/reservation mail fail **silently** (they are swallowed so a dead mailer
cannot fail a booking). `provision-tenant.sh` **warns loudly** rather than refusing —
a tenant with broken mail still beats a funnel that cannot provision at all — but this is
not a state to hand a paying customer.

⚠️ **Setting `PLATFORM_MAIL_DOMAIN` does NOT fix an already-provisioned tenant.**
`app-secrets.json` is *kept* when it exists so JWT and printer secrets survive, so a
re-run shows a green provision and changes nothing. The script detects the mismatch and
prints the exact one-line hand-fix plus the compose restart. Treat that as a real step.

Setting the var requires a Resend plan that allows a second domain (free tier is **one**,
already spent on `rumirestaurant.ch`, **and** caps sending at 100/day) and DKIM/SPF
published **by hand** — `sofrapiwas.com`'s zone is not writable through `domainio-dns.sh`
(domainio#231). Full owner checklist: the workspace repo's `docs/plans/EMAIL-IDENTITY-PLAN.md`.

### Module runtime enforcement (S11 — backend #268, sofra ADR-010)

The registry's `modules:` list is **enforced at runtime**. Since 2026-08-01 a tenant
provisioned for the **first** time enforces by default — `tenants/templates/tenant.env.tpl`
renders `TENANT_MODULES_ENFORCE=true`, so a customer is held to what they bought from their
first boot. Everything below is about the tenants that default did **not** reach.

**Why the default moved.** `provision-tenant.sh` wrote `TENANT_MODULES` and not the enforce
flag, so every tenant the merge chain stood up served all eight modules whatever it paid for —
a customer on Core (€19) received the lot. The flip was a manual per-tenant step nothing in the
funnel performed, which made it a step that did not happen.

**It is still an OPERATOR control, not a registry field.** `provision-tenant.sh` only
*validates* the line on a re-provision and never rewrites or clears it, so a tenant you
deliberately un-enforce stays un-enforced across registry edits. The default is a birth value,
not a policy applied on every run.

**RUMI is never flipped, and cannot be.** It runs the main `deploy` compose project, not the
tenant template, so it never receives `Modules__*` at all — and an absent list means
*unrestricted*, deliberately. Its registry `modules:` line documents what tenant 1 has; it is
not a control.

**A missing list is safe; a WRONG list is not, and that asymmetry is the point.** An empty
`TENANT_MODULES` reads as unrestricted (the backend computes `IsEnforced = Enforce && known
.Length > 0`, so it reports `enforced:false` even with the flag on), and `core` is on
regardless. So the default cannot stand a tenant up with no app. But a **partial** list is
binding — `[core, cashier]` serves core and cashier and nothing else. That is exactly what
enforcement is for, and it means **the registry entry is now the thing to read carefully at
the merge checkpoint**: an id missing there is a feature the customer paid for and will not
get. `/api/tenant/modules` on the live tenant is the check.

**Turning it on for a tenant provisioned before the default** (roll out newest first, never
RUMI). First make sure the `.env` carries the list you think it does — before deploy #68,
`TENANT_MODULES` was written *only* on the fresh-render path, so a later registry edit never
reached a tenant that has not been re-provisioned since:

```bash
grep TENANT_MODULES= /opt/rumi/tenants/<slug>/.env     # must match the registry
cd /opt/rumi/deploy && ./provision-tenant.sh <slug>    # if it does not
```

Then set-or-replace, because a tenant turned off earlier already has the line and a presence
check would silently skip it:

```bash
cd /opt/rumi/tenants/<slug>
sed -i '/^TENANT_MODULES_ENFORCE=/d' .env && echo 'TENANT_MODULES_ENFORCE=true' >> .env
docker compose up -d --force-recreate backend-<slug>
```

The value must be exactly `true` or `false` — it binds to a bool the backend resolves at
startup, so `1`/`yes`/`on` crash-loop the container rather than meaning true.
`provision-tenant.sh` rejects them, but it only runs when you run it.

**Verify against the running instance, not the `.env`:**

```bash
curl -s https://<domain>/api/tenant/modules
```

`{"data":{"modules":[…],"enforced":true}}`. `enforced:false` has **two** causes — the flag did
not take, *or* it took and `TENANT_MODULES` is empty in that `.env` (an empty list means
unrestricted, deliberately). An unexpectedly *long* module list is the same signal, since
unrestricted reports the whole vocabulary. The backend also logs
`Module enforcement ON — enabled: …` once at startup.

**Changing what a tenant has** is: edit `modules:` in the registry → PR → merge → sync →
re-provision (re-applies it to the `.env`) → restart that tenant's backend. **No image
rebuild** — the flags are served from the backend rather than baked as `NEXT_PUBLIC_*`,
precisely so an upsell is not a rebuild.

**Provisioning now reports the answer to this question itself.** `provision-tenant.sh` ends by
querying the tenant's own `/api/tenant/modules` over the internal docker network and printing
what the **running backend** says — enforced or not, and whether the effective ids are the
registry list. A run that could not reach the endpoint says so rather than staying quiet, so
"no warning" is never the same as "verified".

**Give the UI a second request before believing it.** The frontend reads the module set
server-side with a 30 s ISR cache, per path. After a flip the first request to each route
serves the *previously rendered* HTML and only then regenerates — so a nav that still offers a
module you just removed is the cache, not a broken gate. Reload once more before diagnosing.
Verified on `demo` 2026-07-29: pass 1 still showed the reservations nav and the home hero CTA,
pass 2 had dropped both.

**To turn it off**, set `TENANT_MODULES_ENFORCE=false` (or delete the line) and recreate the
backend. Nothing else is stateful.

**Proven on `demo` 2026-07-29** — the first tenant ever flipped, so this is the only evidence
that the gates gate rather than that the unrestricted path works:

| Check | Result |
|---|---|
| `/api/tenant/modules` | `enforced: true`, exactly the six bought ids (not the whole vocabulary) |
| startup log | `Module enforcement ON — enabled: core, kitchen-board, cashier, server, reservations, loyalty` |
| `printing` **not bought** — `GET /api/orders/printer-feed` with a **valid** `X-Api-Key` | **404 `ModuleNotEnabled`** |
| `printing` **not bought** — `GET /api/devices` with an **admin JWT** | **404 `ModuleNotEnabled`** |
| the six bought surfaces (`/api/Events/kitchen`, `/api/Events/service`, `/api/Orders/z-report`, `/api/Reservations`, `/api/admin/PointRules`, `/api/UserGroup`) | all serve |
| UI, module temporarily narrowed | `/reservations` renders a themed *"Not available here"*; the nav entry, the home hero CTA and all four loyalty admin links disappear |

Two traps that cost time proving it, worth knowing before the next flip:

- **A bare 404 is not evidence of a gate.** A wrong path 404s with an *empty body*; the gate
  404s with `errorCode: ModuleNotEnabled`. Assert on the body, never the status alone.
- **A 401 is not evidence either.** `[Authorize]` is consumed by middleware that runs *ahead*
  of the module filter, so on an authenticated endpoint an unauthenticated caller gets 401
  whether or not the module is enabled. `/api/devices` answers 401 anonymously and only reveals
  the 404 once a real token is attached.

### BYO custom domain (ADR-002 path 2 — S10)

A tenant who owns `bistronova.nl` keeps it. The registry entry changes in three
places and nothing else does:

```yaml
  bistronova:
    domain: bistronova.nl
    domain_mode: byo
    domain_aliases: [www.bistronova.nl]   # optional; 301s to the canonical domain
```

Order matters, because a certificate cannot be issued before DNS resolves here:

1. **The tenant creates the records at their registrar** — `A bistronova.nl → <box IP>`
   (TTL ≥ 7200), plus one per alias. No CNAME at the apex; that is why these are A
   records. `provision-tenant.sh` prints the exact record it expected when a lookup
   disagrees, and warns rather than fails so a propagating record doesn't block a re-run.
2. **Build the tenant frontend image with the real domain** (`-f tenant_domain=bistronova.nl`).
   `NEXT_PUBLIC_*` are baked per origin — an image built for the subdomain will make
   cross-origin API calls from the custom domain. Moving an existing tenant to a custom
   domain therefore means a **rebuild**, not just a registry edit.
3. **Provision** as usual. Caddy issues the certificate on the first request (~30 s).
4. **Verify** `./verify-env.sh https://bistronova.nl` and that the alias 301s.

Aliases **redirect**, they do not serve — same baked-origin reason. Two hostnames both
serving the app is a CORS bug waiting for its first order.

Buying a domain *through* Sofra (ADR-002 path 3) is not built: it needs the domainio
org API key + prepaid balance (ROADMAP S10 prereqs).

### Provisioning from the control plane (ADR-012 chain)

The steps above are the founder-operated path and stay the fallback. The control
plane drives the same scripts through a git-native chain — no box credential ever
reaches the public container (ADR-012 invariant 2):

```
/admin/provision  ──PR──▶  deploy repo (develop)  ──merge──▶  sync-registry-to-staging
                                                                      │
                                                     workflow_run     ▼
                                        provision-on-registry-merge.yml (this repo)
                                                    │              │
       build-tenant-image.yml (frontend repo) ◀──────┘              │
                                                                    ▼
                                                    ./provision-tenant.sh <slug>  (SSH)
```

**A merge now stands up infrastructure** (SOFRA-ONBOARDING-PLAN §2, option B, since
O3). It did not before, and several places used to say so — this section included.
The human checkpoint did not disappear, it *is* the merge: the founder still reads
the proposed YAML, and that was always where the checkpoint's value lay. What went
away is the founder copying two `gh workflow run` commands out of the PR body.

1. **Propose** — `/admin/provision` (admin-only) computes the registry entry and
   opens a PR on this repo via `PROVISION_GITHUB_TOKEN`. Unset → the page shows a
   "not configured" banner and nothing else happens. The token is **fine-grained,
   scoped to this repo, Contents + Pull requests: write** — it can propose a
   tenant, never provision one.
2. **Review + merge** the PR. This is the human checkpoint; the entry is plain YAML.
3. **Sync** — merging to `develop` fires `sync-registry-to-staging.yml`, which
   copies **only** `tenants/registry.yml` to the box. (`sync-to-staging.yml` still
   ships everything else from `main` — the templates in `tenants/` included.)
4. **Build + provision — automatic.** The sync's success chains
   `provision-on-registry-merge.yml`, which builds the per-tenant frontend image
   (`build-tenant-image.yml` on the frontend repo, ~3 min — `NEXT_PUBLIC_*` are baked
   per domain, so it must finish before provisioning or the pull fails on an image
   nobody published), waits for it, then SSHes to the box and runs the same
   idempotent `provision-tenant.sh`.

   **What it acts on, and why it is safe to leave unattended:**

   | | |
   |---|---|
   | eligible slug | the entry says `managed: scripts` + `box: staging` + `status: provisioning`, and the chain has not already finished it |
   | idempotency key | `/opt/rumi/tenants/<slug>/.provisioned`, written by **`provision-tenant.sh` itself** as its last act, whichever route ran it — the chain, or a `provision-tenant.yml` dispatch. Box state, not the push diff, so a re-merge, a re-run of the sync and a **revert-and-remerge** all skip. Cleared at the start of every run and by `deprovision-tenant.sh` (with or without `--purge`), so it never outlives the thing it asserts. (Before 2026-08-01 the *chain* wrote `.chain-provisioned` over ssh, so a tenant stood up **by hand** carried no marker at all and was re-provisioned on every later registry merge — see below. The old name is still accepted.) |
   | **not** the tenant's `.env` | `provision-tenant.sh` renders `.env` early and then keeps going through `docker compose pull`, `up -d` and a 5-minute health wait, so `.env` means "the script started". Keying on it would make a provision that died at `pull` invisible: the retry would skip and report green |
   | `.env` but no marker | **completed**, not skipped — the script is idempotent, so the chain finishes an interrupted run and says so in its report |
   | first provisioning only | a tenant the chain has finished is never re-applied automatically. Module upsells and corrections stay a manual `provision-tenant.yml` dispatch (below) |
   | `box: prod` entries | reported — on the PR, not just in the run log — and never provisioned. This chain reaches the staging box only, like the sync it follows |
   | batch cap | refuses more than 2 tenants in one run and provisions none of them |
   | reporting | a comment on the merged registry PR, plus an issue on this repo if anything failed — **including a failed registry sync**, which is checked in a step rather than the job's `if:` precisely so the reporter still runs |
   | trigger provenance | asserted before the checkout: the upstream run must be **this repo's `develop`**. `workflow_run` is the classic confused-deputy trigger — it carries this repo's secrets against a ref someone else chose — and this job holds the box SSH key plus a cross-repo dispatch token. A fork cannot cause it today (the sync only triggers on a `develop` push), but that is an assumption about another file, so it fails closed rather than trusting it |

   Needs the repo secret **`FRONTEND_DISPATCH_TOKEN`** (fine-grained PAT, repo access
   `piwas-21/restaurant-app-frontend` only, **Actions: read and write**, nothing else)
   to dispatch the image build. Absent ⇒ the chain fails loudly and opens the issue
   rather than going quietly green — the failure mode `PROVISION_GITHUB_TOKEN` taught
   us. Calendar its expiry alongside that one.
5. **Provision by hand** — still supported and still the fallback:
   `gh workflow run provision-tenant.yml -f slug=<slug>` (or the control plane's
   `repository_dispatch`). This is the route for **re-provisioning** a live tenant
   after a registry edit, which the chain deliberately will not do. Both paths share
   the `provision-tenant` concurrency group, so they cannot collide on the box.
6. **Verify** — step 5 of the manual runbook (`./verify-env.sh https://<domain>`),
   then flip the registry `status` to `active` in git. The chain does not flip it
   (ADR-007: no script edits the registry).

   **This paragraph used to add "and it does not need to — a provisioned tenant is
   skipped on `.env` presence whatever its `status` says". That was false, and the
   falsehood is why the following went unnoticed for as long as it did.** The chain
   skips on the **marker**, never on `.env`: `.env` present + no marker is `partial`,
   which the chain *provisions*. So before 2026-08-01, when only the chain wrote a
   marker, a tenant stood up **by hand** (step 5 — every re-provision, module upsell
   and BYO domain) sat at `partial` for as long as its entry read
   `status: provisioning`, and each later registry merge re-ran provisioning against
   it: containers of a **live** tenant recreated by an unrelated edit, and one of the
   two `MAX_PER_RUN` slots gone for good. Three such tenants and the cap refuses the
   whole batch, so a new customer is not provisioned at all.

   `provision-tenant.sh` now writes the marker itself, which removes that entirely.
   The `status` flip is still yours, and it is now only about keeping the registry
   honest — nothing behavioural hangs on it.

**Tear down:**

```bash
bash .ssh/staging.sh 'cd /opt/rumi/deploy && ./deprovision-tenant.sh <slug>'            # traffic + containers only
bash .ssh/staging.sh 'cd /opt/rumi/deploy && ./deprovision-tenant.sh <slug> --drop-db --purge'  # + DB (after pg_dump to /opt/rumi/tenant-backups/) + volumes + files
```

Then flip the tenant's `status` in `tenants/registry.yml` in git — scripts
never edit the registry.

**Layout on the box:** `/opt/rumi/tenants/<slug>/{.env,app-secrets.json,docker-compose.yml,uploads/}`
(generated, never synced) · `caddy-tenants/<slug>.caddy` (generated, gitignored;
dir-mounted into Caddy so a plain `caddy reload` applies changes — the
single-file inode gotcha does not apply here).

**Login throttle per tenant.** The backend allows 5 login attempts per 15-minute
window **per client IP** (`RateLimiterSettings.AuthPermitLimit`) and that is the
only active brute-force throttle on the login path, so production tenants keep
it. A develop-tracking **staging surface** may raise it by setting
`TENANT_AUTH_PERMIT_LIMIT` in its own `/opt/rumi/tenants/<slug>/.env` (demo runs
20): a showcase people are invited to poke at otherwise locks its single admin
out for a quarter of an hour after five fumbled logins. The knob is plumbed in
`templates/docker-compose.tenant.yml.tpl` and defaults to the production 5, so
existing tenants are unaffected. Note the 429 is **per IP**, not per account —
two people behind one NAT share the bucket, which is what makes a mysterious
"Too many requests" during a demo usually be someone else's attempts.

**v1 limitations (tracked):** Google login is off per tenant (OAuth origins); tenant
email sends via `onboarding@resend.dev`. The bootstrap password no longer has to be
handed over — since the frontend release of 2026-07-30 a freshly provisioned tenant
serves `/forgot-password` and `/reset-password`, so the owner sets their own password
and the generated one stays on the box as break-glass. `currency/languages/modules`
**are** enforced at runtime as of S11/O5 — see §"Module runtime enforcement" above.
Every tenant provisioned since 2026-08-01 enforces from its first boot; older ones are
gated only if an operator flipped them (`demo` is the one such tenant).

---

## Normal deployment (automatic)

1. Merge your PR into `develop`; validate on the test environment.
2. Promote `develop` → `main` (the release PR).
3. The push to `main` triggers `build-image` → publishes `:latest` + `:sha-<commit>`.
4. On success, `deploy.yml` fires automatically (`workflow_run`) and deploys
   `latest` for that repo's service. **No manual step.**

### Tenants on moving tags (`refresh-tenant-images.sh`)

A tenant pinned to a moving tag (the demo tenant rides `backend_tag: staging`)
only tracks it if something rolls it. The RUMI stack has `deploy-staging.yml`
and the demo frontend has `deploy-demo-staging.yml`, but a **backend-only**
develop build used to leave tenant backends behind — demo sat 44h stale with
the fleet endpoints missing while its registry config was already correct
(deploy #52). `refresh-tenant-images.sh` closes that:

```bash
./refresh-tenant-images.sh backend staging      # every managed:scripts tenant on
./refresh-tenant-images.sh frontend tenant-demo # this box pinned to that tag
```

It reads `tenants/registry.yml`, so a second develop-tracking tenant is covered
the day it is registered — no workflow edit, no hardcoded slug. Nothing matched
is a clean exit 0; a tenant that fails to roll is reported and exits non-zero
(the point is to stop being silent).

**Both callers live in the backend repo, and both run on the STAGING box** —
that is where every `managed: scripts` tenant lives, because it is where the
control plane runs:

| Caller | When | Refreshes |
|---|---|---|
| `deploy-staging.yml` | every merge to backend `develop` | tenants on `backend_tag: staging` |
| `refresh-tenants.yml` | every backend **release** to `main` | tenants on `backend_tag: latest` |

Both share `/tmp/rumi-deploy.lock` with the RUMI rolls.

**Which tag a tenant should carry.** `:latest` (released code) for a paying
customer; `:staging` (the develop build) only for a showcase like `demo`. The
sofra control plane emits `latest` for every generated entry — a showcase is a
hand-edit at the review checkpoint. The distinction is not cosmetic: a
`:staging` tenant has **develop's EF migrations applied to its database** on
every develop merge, and that is not reversible by re-pointing the image.
A moving tag on any box other than staging is never refreshed at all;
`provision-tenant.sh` warns on exactly that.

## Manual deploy / redeploy (no rollback)

In the app repo: **Actions → deploy → Run workflow** → leave `image_tag = latest`.
Identical to the automatic path; use it to re-run a deploy without a new merge.

---

## Rollback

Re-points the running container at an **already-published** image — builds nothing,
fast, and only affects the service whose repo you run it from.

1. **Find the last-good `sha-` tag.** From the app repo: `git log --oneline main`
   → copy the full 40-char SHA of the known-good commit → the tag is `sha-<sha>`.
   (Or browse the GHCR package's **Tags** and pick the `sha-…` before the bad one.)
2. **Run it.** In the affected app repo: **Actions → deploy → Run workflow** →
   `image_tag = sha-<40hex>` → Run. Sets `BACKEND_TAG` / `FRONTEND_TAG` in the box
   `.env`, pulls that image, restarts that one service.
3. **Confirm** (see below).

**Roll forward again:** merge+promote a fix (auto-deploys `latest`), or run the
workflow with `image_tag = latest` to clear the pin.

> ⚠️ **Backend schema caveat.** The backend auto-runs EF migrations on startup, so
> rolling the **backend** image back does **not** revert migrations the bad build
> already applied. Prefer rolling *forward* with a fix for schema problems; only
> hard-rollback the backend when the bad build added no migration.

> ⚠️ **A backend rollback does NOT roll tenants back.** The release that just went
> bad also refreshed every `backend_tag: latest` tenant on the staging box (the
> backend repo's `refresh-tenants.yml`), so they are running the bad build too. The
> dispatch rollback above re-points **prod's** container and does **not** move the
> `:latest` tag, so it reaches no tenant.
>
> **Which tenants are affected** — read the registry, do not run the refresh script
> to find out: it *pulls and recreates*, and while `:latest` still resolves to the
> bad build that would re-apply it (and re-run its migrations) to every tenant.
>
> ```bash
> grep -B25 'backend_tag: latest' /opt/rumi/deploy/tenants/registry.yml
> ```
>
> **Step 4 — repair them.** Two paths; the first is preferred:
>
> 1. **Roll forward.** Merge the fix and release. That moves `:latest` and
>    `refresh-tenants.yml` picks the tenants up automatically. Nothing manual.
> 2. **Break-glass retag**, when a forward release is not available fast enough.
>    Backend repo → Actions → **retag-mutable-tags** → the last-good 40-char SHA.
>    That re-points `:latest` server-side at the good build. Then, because
>    `retag-mutable-tags` is `workflow_dispatch`-only and therefore does not chain
>    `refresh-tenants.yml`, finish by hand: re-run the prod `deploy` dispatch with
>    `image_tag = latest`, and on the **staging** box run
>    `./refresh-tenant-images.sh backend latest` — which now genuinely repairs the
>    tenants, because `:latest` is good again.
>
> Today no tenant is affected — every one is on `:staging`, retired, or legacy RUMI —
> but that changes with the first paying customer.

---

## Verifying a deploy

```bash
# from a machine with box SSH access (see .ssh/box.sh — runs as root):
bash .ssh/box.sh 'cd /opt/rumi/deploy && grep -E "^(BACKEND|FRONTEND)_TAG=" .env && docker compose -f docker-compose.prod.yml ps'
```
```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://www.rumirestaurant.ch/          # frontend -> 200
curl -sS -o /dev/null -w '%{http_code}\n' https://www.rumirestaurant.ch/api/health  # backend  -> 200
```
Backend startup / migration logs:
```bash
bash .ssh/box.sh 'cd /opt/rumi/deploy && docker compose -f docker-compose.prod.yml logs --tail=80 backend'
```

**Do not verify a data-repair migration from the log. Pre-measure instead.**

Grepping for a migration's `RAISE NOTICE` text is a **false positive**: EF logs each migration's SQL
*body* as it executes it, and the body contains the notice string as a literal, so the text is in the
log whether or not the notice ever fired. Measured on the 2026-07-28 release (§9.5,
`AddUniquePrimaryProductCategoryIndex`): `grep -iE "9\.5|demoted"` returned **8 hits on a prod
database that had nothing to repair** — the migration body has 4 matching lines (`DECLARE demoted
integer;`, `GET DIAGNOSTICS demoted = ROW_COUNT;`, `IF demoted > 0 THEN`, and the `RAISE NOTICE` line
itself) and the body is echoed **twice** on a boot, once under `Command execution completed` and once
bare. Not a log-level artefact: that box logs `Executed DbCommand` (Information) 262 times and
`Executing DbCommand` (Debug) zero times.

⚠️ **The obvious fix — grepping the substituted form — is NOT known to work, so do not rely on it.**
Two reasons it may be structurally blind, neither yet tested against a notice that actually fired:

- Migrations run through the **app**, not `psql`, so the familiar `NOTICE:` prefix never appears —
  Npgsql renders a notice as `Received notice: <text>`. A grep for `NOTICE:` is dead text here.
- Whether Npgsql's notice line reaches the container log at the configured level is unverified.
  `appsettings.json` sets `Logging:LogLevel:Default = Information` with no Npgsql override, and
  `docker-compose.prod.yml` passes an explicit env **allowlist** with no `Logging__*` entry, so a box
  `.env` cannot raise it either.

A detector that is blind and a true negative produce identical output, and the 2026-07-28 run only
ever exercised the negative case. Until someone fires one deliberately on staging and records what
the log actually shows, treat the log as **evidence of nothing** in either direction.

**What to do instead — run the migration's own predicate against the database BEFORE releasing**, so
the answer is known going in and the deploy log is never load-bearing:
```bash
# example: the §9.5 demotion predicate, run against prod while the release PR is still open
bash .ssh/box.sh 'cd /opt/rumi/deploy && docker compose -f docker-compose.prod.yml exec -T postgres \
  psql -U "$(grep -E "^POSTGRES_USER=" .env | cut -d= -f2)" -d "$(grep -E "^POSTGRES_DB=" .env | cut -d= -f2)" \
  -c "SELECT count(*) FROM product_categories pc WHERE pc.is_primary AND pc.id <> (SELECT k.id FROM product_categories k WHERE k.product_id=pc.product_id AND k.is_primary ORDER BY k.display_order, k.id LIMIT 1);"'
```
Then confirm the *effect* afterwards (here: the index exists and duplicates are zero), which is
observable in the schema rather than in log text.

This is the **mirror** of the E2E-fixture trap under *E2E menu fixture (staging only)* further down
this file, which fails the other way — a false **negative** on every re-roll. On this box, "the log
said so" has now been wrong in both directions.

**What's actually deployed** — one URL shows both services' build identity (commit
+ build time), reflecting the *running* containers rather than `.env`:
```bash
curl -sS https://www.rumirestaurant.ch/api/version          # { frontend:{commit,buildTime,...}, backend:{...} }
```
Richer, admin-only diagnostics (full SHA, .NET version, DB status, last applied
migration) — requires an Admin bearer token:
```bash
curl -sS https://www.rumirestaurant.ch/api/diagnostics -H "Authorization: Bearer <admin-jwt>"
```

---

## Viewing logs in the browser (Dozzle)

Live container logs are available at **https://www.rumirestaurant.ch/logs** behind a
login (Dozzle simple auth). This complements the SSH `docker compose logs` commands
above — no shell access needed for read-only log viewing.

**One-time setup on the box** (the credentials file is gitignored + excluded from CI
sync; it lives only on the server, like `app-secrets.json`):
```bash
ssh rumi@159.195.137.101
cd /opt/rumi/deploy
# Generate the login (bcrypt-hashed); pick a strong password:
docker run --rm amir20/dozzle:v10.6.6 generate admin \
  --name 'RUMI Ops' --password 'STRONG_PASSWORD_HERE' > dozzle-users.yml
./deploy.sh                                                   # brings up the dozzle service
# Caddyfile change (the /logs route) needs the caddy container recreated, NOT
# just reloaded — see the warning under "Updating infra files" below for why.
docker compose -f docker-compose.prod.yml up -d --force-recreate caddy
```
The `dozzle-users.yml` file **must exist before** the stack starts — otherwise Docker
creates a directory at that bind-mount path and Dozzle fails to read users. See
`dozzle-users.example.yml` for the schema.

Security: Dozzle mounts the docker socket **read-only** and is never published to a
host port — it is reachable only through Caddy at `/logs`, gated by its own login.
Logs can contain PII, so the login is mandatory; rotate the password by regenerating
`dozzle-users.yml` and restarting the `dozzle` service.

---

## Developer Portal (`/dev-portal`)

An internal ops dashboard (frontend repo: `src/app/dev-portal/page.tsx`) showing
combined frontend+backend version info, backend diagnostics (DB connectivity,
migrations), and a link to the Dozzle log viewer. It is **deliberately not part of
the tenant app** — no i18n, no tenant login — because RUMI is moving toward
multi-tenant SaaS and this tool must stay decoupled from any one tenant's auth/UI.

Access is gated by **Caddy Basic Auth** at the proxy layer (see `Caddyfile`'s
`/dev-portal` + `/dev-portal/*` block), independent of the restaurant's Admin/Staff
role system — same pattern as Dozzle above, just HTTP Basic Auth instead of Dozzle's
own login page.

**One-time setup / password rotation on the box:**
```bash
ssh rumi@159.195.137.101
cd /opt/rumi/deploy
docker run --rm caddy:2-alpine caddy hash-password --plaintext 'STRONG_PASSWORD_HERE'
# IMPORTANT: double every literal $ in the hash before pasting into .env — Compose
# interpolates .env values when substituting them into docker-compose.prod.yml, so
# a raw `$2a$14$abc...` gets partially swallowed (e.g. `$Gkg` silently resolves to
# "" if no such shell/compose variable exists), corrupting the hash. Escape as $$:
#   $2a$14$Gkg.abc...   ->   $$2a$$14$$Gkg.abc...
# Paste the ESCAPED hash into .env as DEV_PORTAL_AUTH_HASH=... (see .env.example)
docker compose -f docker-compose.prod.yml up -d --force-recreate caddy
# Verify the hash reached the container unmangled (compare byte-for-byte against
# what `caddy hash-password` printed — no warnings like `The "Xyz" variable is not
# set` should appear in the `up` output above; that warning means the escaping was
# missed):
docker compose -f docker-compose.prod.yml exec caddy printenv DEV_PORTAL_AUTH_HASH
```
The diagnostics card additionally requires the developer to be logged into the
restaurant's `/admin` UI as Admin in the same browser (it calls the backend's
admin-gated `/api/diagnostics` via the normal tenant auth token, unchanged) —
the page degrades gracefully if that token is absent.

The frontend's own `/api/frontend/version` route needs a matching exact-path
`handle` block in the Caddyfile. Caddy matches `handle` blocks by path specificity
(exact paths beat the `/api/*` wildcard) regardless of document order, so this
works even though the block also happens to be placed above the generic `/api/*`
block for readability. See the comment above that block in `Caddyfile`.

---

## Emergency manual deploy (CI/SSH-from-Actions unavailable)

```bash
ssh rumi@159.195.137.101
cd /opt/rumi/deploy
BACKEND_TAG=sha-<40hex> ./deploy.sh      # rollback backend
FRONTEND_TAG=latest    ./deploy.sh       # redeploy frontend
./deploy.sh                              # deploy whatever .env currently pins
```
`deploy.sh` is idempotent and persists the tag to `.env`.

---

## Updating infra files (compose / Caddyfile / deploy.sh)

Edit here, open a PR, merge to `main` → `sync-to-box.yml` (prod) + `sync-to-staging.yml` (staging) rsync to the boxes.
The sync **copies files only** — it does not restart anything:

- A `docker-compose.prod.yml` change takes effect on the next `./deploy.sh`.
- A `Caddyfile` change needs the **caddy container recreated**, not just reloaded:
  `bash .ssh/box.sh 'cd /opt/rumi/deploy && docker compose -f docker-compose.prod.yml up -d --force-recreate caddy'`.
  **Do not use `caddy reload`** — `sync-to-box.yml`'s rsync replaces `Caddyfile` via an
  atomic rename, which leaves the caddy container's single-file bind mount pinned to
  the *old* inode. `caddy reload` re-parses a file the container can no longer see as
  changed, so it silently no-ops on the new content. Verify the fix took with
  `bash .ssh/box.sh 'cd /opt/rumi/deploy && md5sum Caddyfile && docker compose -f docker-compose.prod.yml exec caddy md5sum /etc/caddy/Caddyfile'`
  — both hashes must match.

`.env` and `app-secrets.json` are **never** synced (excluded) — edit those on the
box directly.

## Container resource limits (DEV-PHASES W0, since 2026-07-07)

Every service in `docker-compose.prod.yml` (and each tenant instance via
`tenants/templates/docker-compose.tenant.yml.tpl`) carries `mem_limit` + `cpus`:
backend **1g / 2 cpu**, postgres **2g / 2 cpu**, frontend/sofra **512m / 1 cpu**,
caddy/redis/dozzle **256m**. These are OOM/runaway *guardrails* (3–8× the peaks
observed in the 2026-07-07 `docker stats` sizing snapshot), not tight quotas — a
leaking container gets OOM-killed and restarted (`restart: unless-stopped`)
instead of taking the box down.

**Postgres connections (2026-07-09, workspace cost plan §5.2):** the shared
postgres runs `max_connections=300` (compose `command`), and every backend
connection string carries `Maximum Pool Size=20` (base compose + tenant tpl) so
N backends can't exhaust the server (Npgsql's default pool is 100 *per
backend*). Postgres `mem_limit` is 2g to match the higher ceiling. Already-
rendered tenant composes keep their old connection string until the tenant is
re-provisioned (idempotent re-run re-renders compose).

- Limit changes take effect on the next `up -d` (containers are recreated).
- If a service starts getting OOM-killed legitimately (check
  `docker inspect <ctr> --format '{{.State.OOMKilled}}'` / Dozzle), raise its
  limit in a PR — don't remove it.
- **Quarterly re-tune** (DEV-PHASES §4.6): snapshot
  `docker stats --no-stream` on both boxes, compare against the limits, adjust
  in a PR with the new numbers in the commit message.

### Snapshot 2026-07-09 (DEV-PHASES W3 — first quarterly re-tune) → **no change**

Read-only `docker stats --no-stream` + `docker inspect .State.OOMKilled` on both
boxes. **Every container is under 19 % of its limit; zero restarts, zero OOM
kills** — the guardrails hold with ~5–6× headroom, nothing to tune.

| Service | Limit | Prod (159.195.137.101) | Staging (159.195.34.105) |
|---|---|---|---|
| backend | 1g | 178 MiB (17 %) | 164 MiB (16 %) |
| frontend | 512m | 75 MiB (15 %) | 71 MiB (14 %) |
| sofra | 512m | — (staging-only) | 95 MiB (19 %) |
| postgres | 1g | 24 MiB (2 %) | 24 MiB (2 %) |
| redis | 256m | 8 MiB (3 %) | 8 MiB (3 %) |
| caddy | 256m | 25 MiB (10 %) | 22 MiB (9 %) |
| dozzle | 256m | 14 MiB (6 %) | 15 MiB (6 %) |

Prod box: 15 GiB RAM, ~14 GiB free at snapshot. (This also confirms a
*co-located* self-hosted Sentry is a non-starter — its ~16 GiB minimum would
starve the live client stack — so error tracking stays on Sentry SaaS EU.)

## Backups & restore (cross-box, since 2026-07-09)

**Design** (workspace cost plan §10.1 — box loss must not mean data loss): both
boxes dump nightly to a local dir; prod then ships everything off-box with
restic. Each box's data ends up **encrypted on the other box**:

| Script | Runs on | Produces |
|---|---|---|
| `backup-dump.sh` | both boxes, 02:15 box-local (cron) | `/opt/rumi/backups/dumps/`: `pg_dumpall` of the whole cluster (all DBs + roles), uploads-volume tar, `/opt/rumi/tenants` tar, box-config tar (`.env`, `app-secrets.json`, `dozzle-users.yml`); keeps 7 days locally |
| `backup-offsite.sh` | **prod only**, 03:00 (cron, root) | restic **repo A** `sftp:rumi@staging:/opt/rumi/backups/restic-prod` ← prod dumps · restic **repo B** `/opt/rumi/backups/restic-staging` (on prod) ← staging dumps (rsync-pulled first) · per repo: `forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune` + `check --read-data-subset=10%` |

Key direction is deliberately one-way: **prod holds the only cross-box key**
(`/root/.ssh/rumi_backup_ed25519` → `rumi@staging`, `restrict,from=` pinned in
staging's `authorized_keys`). Staging never gets a key to prod — no
privilege-escalation path from the weaker box to the client box. Both repos are
restic-encrypted with the password in `/root/.rumi-backup-env` (prod, mode 600);
**escrow that password off-box** (owner's workspace-root `.env` + password
manager) — after a prod loss the staging-held repo A is unreadable without it.

`/root/.rumi-backup-env` template (never in git):

```
RESTIC_PASSWORD=<generated once — escrowed>
# Optional overrides (defaults live in backup-offsite.sh):
# STAGING_HOST=159.195.34.105   STAGING_USER=rumi
# SSH_KEY=/root/.ssh/rumi_backup_ed25519
# REPO_PROD=sftp:rumi@159.195.34.105:/opt/rumi/backups/restic-prod
#   -> later, swap to an s3:/b2: URL for a third-party off-site tier
#      (true provider-level DR — cost plan §10.1's ~€4-6/mo upgrade).
```

**One-time setup** (done 2026-07-09; repeat only on a box rebuild):

1. prod: `apt-get install -y restic` · `ssh-keygen -t ed25519 -f /root/.ssh/rumi_backup_ed25519 -N '' -C rumi-backup-prod` · `ssh-keyscan 159.195.34.105 >> /root/.ssh/known_hosts`
2. staging: `install -d -m 700 /opt/rumi/backups` · append to `~rumi/.ssh/authorized_keys`: `restrict,from="159.195.137.101" <pubkey>`
3. prod: write `/root/.rumi-backup-env` (template above, `chmod 600`) · `restic init` on both repos — **repo A needs the same `-o "sftp.command=ssh -i /root/.ssh/rumi_backup_ed25519 -o IdentitiesOnly=yes rumi@159.195.34.105 -s sftp"` as backup-offsite.sh** (non-default key name; plain ssh won't offer it)
4. crontabs — staging (`crontab -e` as rumi): `15 2 * * * /opt/rumi/deploy/backup-dump.sh >> /opt/rumi/backups/backup.log 2>&1` · prod (root): the same at 02:15 → `/var/log/rumi-backup.log`, plus `0 3 * * * /opt/rumi/deploy/backup-offsite.sh >> /var/log/rumi-backup.log 2>&1`

**Verify** any time: `restic -r <repo> snapshots` shows last night's pair; the
nightly `check --read-data-subset=10%` continuously exercises repo integrity.
Logs: `/var/log/rumi-backup.log` (prod), `/opt/rumi/backups/backup.log`
(staging). Check freshness during the quarterly `docker stats` re-tune ritual.

**Restore — single database** (inspect or recover one DB, e.g. `restaurantdb`):

```bash
# restic restores ABSOLUTE paths under --target — the two repos hold different dirs:
#   repo B (staging's data, local on prod):  .../staging-mirror/cluster-<ts>.sql.gz
#   repo A (prod's data, sftp on staging):   .../dumps/cluster-<ts>.sql.gz  (add the
#   same -o "sftp.command=…" as backup-offsite.sh)
restic -r /opt/rumi/backups/restic-staging restore latest --target /tmp/r
gunzip /tmp/r/opt/rumi/backups/staging-mirror/cluster-<ts>.sql.gz
# cluster dump is plain SQL: load it into a scratch postgres:16 container on the
# private network, then pg_dump just the database you need out of it.
```

**Restore — full box loss**: provision the replacement (provision.sh §Phase 0/1),
restore the latest snapshot from the *surviving* box's repo, load the cluster
dump into the fresh postgres (`gunzip -c cluster-*.sql.gz | docker compose exec -T postgres psql -U <user> -d postgres`),
untar uploads into the volume and `deploy-config`/`tenants` into place, `up -d`,
re-point DNS. Drill this quarterly alongside the re-tune.

## Error tracking (Sentry — DEV-PHASES W3)

Sentry is wired into the apps but **inert until a DSN is set** (the SDK is a
no-op with no DSN, so merging the code changed nothing live):

- **sofra** — full capture (server + browser + root React errors). Browser
  capture needs `NEXT_PUBLIC_SENTRY_DSN` at **image build** time (a build arg in
  the sofra repo's `build-image.yml`) plus the CSP allow it already derives.
- **frontend** (RUMI) — **server-side only** (SSR / route handlers / RSC).
  Browser capture is deferred: it needs a CSP `connect-src` change in the
  frontend `next.config.ts`, a §9 explicit-instruction-only edit.
- **backend** (.NET) — **errors only** (`Sentry.AspNetCore`, env-gated on
  `SENTRY_DSN` in `Program.cs`): no PII, no request bodies, tracing/performance
  off. `SENTRY_ENVIRONMENT` labels the box (both boxes run
  `ASPNETCORE_ENVIRONMENT=Production`); it falls back to the ASP.NET
  environment name when unset.

**Enable server-side capture** (no image rebuild — just env + recreate):

1. Add to the box `.env` (both boxes; value is the Sentry **SaaS EU** DSN —
   low-sensitivity, but config lives on the box, never committed):
   ```
   SENTRY_DSN=https://<key>@<org>.ingest.de.sentry.io/<project>
   SENTRY_ENVIRONMENT=prod   # or "staging" on the staging box
   ```
2. Recreate the services that read it:
   `docker compose -f docker-compose.prod.yml up -d frontend backend` (+ `sofra`
   on staging). Same image, one added env var — Sentry just starts reporting.
3. Verify: trigger a server error and confirm it lands in the Sentry EU
   dashboard; check `docker logs` shows no Sentry init error.

**Self-host later?** The provided DSN is Sentry SaaS EU (EU data residency).
Going self-hosted is just **swapping the DSN value** — no code change — but it
needs its own box (Sentry self-hosted ≈ 16 GiB RAM / ~20 containers; don't
co-locate on a live app box).

## Fleet observability (Track S — printer-app → backend → sofra `/admin/fleet`)

Each tenant backend runs a `FleetSummaryPushService` that POSTs its device roster +
missed-order/error counts to the sofra control plane's `/api/telemetry/fleet` route;
`/admin/fleet` renders them. See
`docs/plans/PRINTER-APP-FLEET-OBSERVABILITY-PLAN.md` in the workspace.

**One shared secret per box, set once — then it's automatic for every tenant:**

1. Generate one secret and put the **same value** on the sofra box **and** every box
   that runs tenant backends:
   ```
   PRINTER_TELEMETRY_SECRET=<openssl rand -hex 32>
   ```
   (staging box `.env` — sofra reads it for the ingest route; prod box `.env` — tenant
   backends read it. Both boxes must carry the identical value.)
2. **New tenants: nothing else to do.** `provision-tenant.sh` flows `PRINTER_TELEMETRY_SECRET`
   + `SENTRY_DSN` from the box `.env` into each tenant `.env`, and the tenant compose wires
   `FleetPush__*` + `SENTRY_DSN` into the backend. The backend auto-migrates the fleet tables
   on startup. So a freshly provisioned tenant reports to `/admin/fleet` automatically. Until
   the secret is set the pusher is **inert** (self-guards on an empty secret) — safe to ship.
3. **Roll sofra** to pick up the ingest secret: `docker compose -f docker-compose.prod.yml up -d sofra`.
4. **RUMI (the main stack):** its `FleetPush__*` is now wired straight into `docker-compose.prod.yml`
   (`FleetPush__Enabled` defaults on; slug `rumi`). So once the backend fleet code is on the prod box
   (backend #199–#203, released to `main` + auto-deployed) and `PRINTER_TELEMETRY_SECRET` is set
   (step 1), just **roll the backend** to pick up the env: `docker compose -f docker-compose.prod.yml up -d backend`.
   The **staging** box must set `FLEET_PUSH_ENABLED=false` in its `.env` — otherwise the staging RUMI
   backend would push as `rumi` too and clobber prod's fleet rows in the single sofra control plane.

**Printer-app onboarding for a tenant** who buys the printer service: they enter three values
in the app's Settings — **API Base URL** (`https://<their-domain>`), **Tenant Slug**, and
**Printer Key** (`PrinterSettings.ApiKey`, auto-generated per tenant). `provision-tenant.sh`
prints all three in its summary; the key also lives in `/opt/rumi/tenants/<slug>/app-secrets.json`.
The control plane deliberately does **not** store the key (ADR-012 — sofra never holds box
secrets); a self-serve "reveal your printer key" surface would live in the **tenant's own admin**
(their trust boundary), not the SaaS control plane.

## E2E menu fixture (staging only) — `SEED_E2E_MENU_FIXTURES`

The printer-app E2E suite cannot assert kitchen routing without a bundle whose components resolve to
**different** kitchens, and staging ships no products at all (backend #238). `E2EMenuFixtureSeeder`
provides one — but it is the only seeder that inserts a **visible, orderable** product, so it is
opt-in and **defaults to false**.

`docker-compose.prod.yml` runs on **both** boxes, so the switch is deliberately the inverse of
`FLEET_PUSH_ENABLED` above: forgetting that one is loud, forgetting this one must be **safe**,
because the failure mode is "E2E Menu Deal" appearing on a paying tenant's menu. Env vars bind
**last** in `Program.cs`, so the compose default also outranks any `SeedSettings` block someone adds
to a box `app-secrets.json` — prod is pinned off, not merely un-enabled.

Per-tenant stacks deliberately have **no such lever**: `docker-compose.tenant.yml.tpl` does not
forward the variable and `provision-tenant.sh` harvests only `SENTRY_DSN` +
`PRINTER_TELEMETRY_SECRET` from the box `.env`, so the fixture cannot reach `demo.sofrapiwas.com`
or any provisioned tenant.

To enable it on **staging only**:

0. **Release this repo first.** A `docker-compose.prod.yml` change reaches a box only after a
   `develop` → `main` PR and the `sync-to-staging.yml` rsync. Skipping this makes steps 1-2 a
   **silent no-op**: without the passthrough the resolved container config is unchanged, so compose
   does not even recreate the container and nothing errors. Confirm first:
   ```
   grep SeedSettings__SeedE2EMenuFixtures /opt/rumi/deploy/docker-compose.prod.yml
   ```
1. Add to the **staging** box `.env` (never the prod box):
   ```
   SEED_E2E_MENU_FIXTURES=true
   ```
   The value must be literally `true` or `false`. Anything else — `0`, `1`, `yes`, `on` — fails
   bool binding, which throws out of the startup migration, so the backend never reaches
   `app.Run()` and restart-loops. (Same hazard the tenant template documents for
   `RateLimiter__AuthPermitLimit`.)
2. Roll the backend so it re-reads the environment and the seeder runs:
   ```
   docker compose -f docker-compose.prod.yml up -d backend
   ```
3. Verify against what the E2E suite actually reads, not the log:
   ```
   curl -s https://staging.fooderist.com/api/products | grep "E2E Menu Deal"
   ```
   The seeder logs at **warning** level on the boot that inserts, but the idempotent path logs
   "E2E menu fixture already present — skipping." at information level — so a log grep returns
   empty on every re-roll after the first and reads as "it never fired". Use
   `grep -i "E2E menu fixture"` if you do want the log, since that matches both paths.

**There is no un-seed.** Turning the flag back off stops future boots inserting; it does not remove
what a previous boot inserted. That is deliberate — production's code path stays a pure early return
with no delete logic in it. To clear a staging tenant, delete these four fixed ids by hand:

```
e2e00000-0000-0000-0000-000000000001   -- combo product ("E2E Menu Deal")
e2e00000-0000-0000-0000-000000000002   -- component ("E2E Beef Burger", FrontKitchen)
e2e00000-0000-0000-0000-000000000003   -- component ("E2E Fries", BackKitchen)
e2e00000-0000-0000-0000-000000000010   -- the MenuDefinition (also the idempotency sentinel)
```


