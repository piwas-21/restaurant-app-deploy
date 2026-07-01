# RUMI — Deployment & Rollback runbook

Canonical runbook for shipping RUMI to production and rolling back. Production is
a single Netcup box running the stack via Docker Compose; images are built in CI
and pulled from GHCR. The app repos link here.

> **Audience:** anyone promoting a release or responding to a bad deploy.
> **Box / secrets setup:** see [README.md](README.md).

---

## Topology

```
merge to main ─► build-image.yml ─► GHCR (:latest, :sha-<commit>) ─► deploy.yml ─► SSH ─► box: deploy.sh
 (app repo)       (build + push)        (image registry)            (auto/manual)        (pull + up -d)

push to main ─► sync-to-box.yml ─► rsync ─► box: /opt/rumi/deploy   (this repo: infra files only)
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
  `BACKEND_TAG=latest`, fresh Postgres creds.
- `app-secrets.staging.example.json` → the box's `app-secrets.json`: staging URLs,
  CORS = the staging origin, and email via `onboarding@resend.dev` so staging
  **cannot dent rumirestaurant.ch's sending reputation**.

**Image model:** the **backend image is domain-agnostic** (URLs/CORS come from
`app-secrets.json`), so staging runs the **same `:latest` backend** as prod. Only
the **frontend** bakes `NEXT_PUBLIC_*` at build time, so it needs a
staging-specific **`:staging`** image (built by the frontend repo's
`build-image.yml` from `develop`). So the staging **frontend** tracks `develop`,
while the **backend** image is shared with prod (`:latest`, built from `main`).

**First-time bring-up (once the box is provisioned):**
```bash
# 1. Provision (as root on the staging box) — installs Docker, rumi user, hardening:
ssh root@159.195.34.105 'bash -s' < provision.sh      # SEED SSH_PUBKEY first (see README)
# 2. Get infra files onto the box (manual until sync-to-staging.yml is enabled):
rsync -az --exclude='.git/' --exclude='.env' --exclude='app-secrets.json' \
  ./ rumi@159.195.34.105:/opt/rumi/deploy/
# 3. On the box: generate secrets, then fill staging URLs/CORS/email:
ssh rumi@159.195.34.105
cd /opt/rumi/deploy
cp .env.staging.example .env && cp app-secrets.staging.example.json app-secrets.json
./gen-secrets.sh          # fills POSTGRES_PASSWORD / JWT / printer key
#   then edit .env (CADDYFILE, DEV_PORTAL_AUTH_HASH) + app-secrets.json (Resend key, AdminEmail)
# 4. Deploy (DNS already resolves — it's the box's own hostname):
./deploy.sh
```
Verify: `https://v2202607374190477434.megasrv.de/` (200) and
`.../api/health` (200), same as the prod checks below.

**Auto-sync:** `sync-to-staging.yml` is currently `workflow_dispatch`-only. Once the
`STAGING_*` repo secrets are set, uncomment its `push: [main]` trigger so staging
tracks infra changes automatically (like `sync-to-box.yml` does for prod).

---

## Normal deployment (automatic)

1. Merge your PR into `develop`; validate on the test environment.
2. Promote `develop` → `main` (the release PR).
3. The push to `main` triggers `build-image` → publishes `:latest` + `:sha-<commit>`.
4. On success, `deploy.yml` fires automatically (`workflow_run`) and deploys
   `latest` for that repo's service. **No manual step.**

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
# Paste the resulting hash into .env as DEV_PORTAL_AUTH_HASH=... (see .env.example)
docker compose -f docker-compose.prod.yml up -d --force-recreate caddy
# Verify the hash reached the container unmangled (bcrypt hashes contain `$`):
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

Edit here, open a PR, merge to `main` → `sync-to-box.yml` rsyncs to the box.
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
