# RUMI deploy — single-box (Netcup RS 2000), tenant 1: rumirestaurant.ch

Source of truth for the production box's infra. **Deploy/rollback runbook:**
[DEPLOYMENT.md](DEPLOYMENT.md).

Self-contained Docker Compose deployment. **No AWS, no DB recovery required** to go live — the
backend auto-migrates and seeds a fresh Postgres on first boot, and file uploads use the built-in
**Local** storage provider (served off the box), so the deferred AWS database/S3 work does not block this.

## How the box stays in sync
This repo is the source of truth; the box (`/opt/rumi/deploy`) is a plain directory, not a git
checkout. On every push to `main`, **`.github/workflows/sync-to-box.yml` rsyncs these files to the
box** over SSH (read-only deploy access; `.env` and `app-secrets.json` are excluded and never
touched — edit those on the box directly). Requires `rsync` on the box (installed) and repo secrets
`DEPLOY_HOST` / `DEPLOY_USER` / `DEPLOY_SSH_KEY` / `DEPLOY_KNOWN_HOSTS`. App **image** rollouts are
separate — each app repo's own `deploy.yml` handles those (see [DEPLOYMENT.md](DEPLOYMENT.md)).

## Stack
Caddy (auto-TLS) → frontend (Next.js :3000) / backend (.NET 10 :8080) → Postgres 16 + Redis 7.
Routing: `/api/*`→backend, `/uploads/*`→static files, everything else→frontend.

## Images
Built in CI and pushed to **GHCR** by each repo's `.github/workflows/build-image.yml`:
`ghcr.io/piwas-21/restaurant-app-{backend,frontend}`. The box **pulls** these — no source
checkout or on-box build. Frontend `NEXT_PUBLIC_*` are baked at CI build time.
> After the first publish, set both GHCR packages to **public** (repo → Packages → package →
> Settings → Change visibility) so the box pulls without auth. Otherwise `docker login ghcr.io`
> with a read-only PAT on the box.

## Server layout
```
/opt/rumi/
  deploy/     # only this folder is needed: compose, Caddyfile, .env, app-secrets.json, scripts
```

## One-time prep (do now, before the box is ready)
1. **Gather secrets** (none need AWS):
   - SMTP user/pass — from **Infomaniak** mailbox (only thing that truly gates email).
   - Google: **no client secret needed** (login validates the Google ID token against the client ID). Just add
     `https://www.rumirestaurant.ch` to the OAuth client's *Authorized JavaScript origins* in Google Cloud console.
   - Run `./gen-secrets.sh` to scaffold `.env` + `app-secrets.json` with fresh `POSTGRES_PASSWORD`,
     `JwtSettings.Secret`, `PrinterSettings.ApiKey`. Then fill the SMTP/AdminEmail fields it lists as TODO.
2. **Backend uploads-dir fix** — DONE in backend PR #99 (Dockerfile pre-creates `/app/wwwroot/uploads`
   owned by the non-root user so the Local provider can write). Merge to `develop`, then promote to `main`.
3. **Merge + promote both deploy PRs** (backend #99, frontend #107) to `develop`, then promote `develop`→`main`.
   The `main` push triggers `build-image` in each repo and publishes `:latest` to GHCR. Make the two GHCR
   packages public (see Images, above).
4. Decide DNS TTL: lower it on Infomaniak now so cutover is fast later.

## Deploy (once the box exists + images published)
```bash
# 1. As root on the fresh server:
scp provision.sh root@<ip>:/root/ && ssh root@<ip> 'SSH_PUBKEY="ssh-ed25519 AAAA..." bash provision.sh'

# 2. As the rumi user: put this deploy folder at /opt/rumi/deploy, then:
cd /opt/rumi/deploy
cp .env.example .env                         # set IMAGE_TAG + POSTGRES_PASSWORD
cp app-secrets.example.json app-secrets.json # fill SMTP, Google, JWT, printer key
chmod +x deploy.sh
./deploy.sh                                   # pulls GHCR images, starts the stack

# 3. Watch the fresh DB migrate + seed:
docker compose -f docker-compose.prod.yml logs -f backend   # expect "Migrations successfully applied"
```

## DNS cutover (Infomaniak)
State as of 2026-06-29: stack deployed + validated on the box (159.195.137.101). Backend/frontend
verified 200 internally. **Caddy is intentionally stopped** so it doesn't burn Let's Encrypt
validation attempts while DNS still points at the old IP. Cutover = point DNS, then start Caddy.

1. Set records at Infomaniak → the Netcup box:
   - `A    www.rumirestaurant.ch  -> 159.195.137.101`
   - `AAAA www.rumirestaurant.ch  -> <Netcup IPv6>`
   - `A    rumirestaurant.ch      -> 159.195.137.101`   (Caddy redirects apex→www)
2. Wait for propagation (`dig +short www.rumirestaurant.ch` returns the Netcup IP).
3. Start Caddy — it then obtains the Let's Encrypt cert via HTTP-01:
   ```
   ssh rumi@159.195.137.101 'cd /opt/rumi/deploy && docker compose -f docker-compose.prod.yml start caddy'
   ```
4. Confirm: `https://www.rumirestaurant.ch` (valid cert), login (Google + email), an image upload +
   display, and SSE live order updates (cashier/kitchen). Add the prod origin to the Google OAuth client
   (Authorized JS origins) if not done.

> If cert issuance is rate-limited from the pre-cutover failures, Caddy retries automatically (up to ~1h).

## Known follow-ups (non-blocking)
- **Frontend healthcheck** reports `unhealthy` (cosmetic): `healthcheck.js` probes `localhost` (resolves to
  IPv6 `::1`) but Next listens on IPv4 `0.0.0.0`. App serves fine. Fix = use `127.0.0.1` in `healthcheck.js`.
- **Frontend dependency CVEs** (npm audit / OSV): pre-existing; address with a separate `npm audit fix` PR.

## Operational notes
- **Persistence:** `pgdata`, `redisdata`, `backend_keys` (DataProtection — keep, or redeploys invalidate
  tokens/sessions), `uploads`, `caddy_data` (ACME certs) are named volumes. Back these up.
- **Seed login:** first boot seeds users (see backend `UserSeeder`). Verify/rotate the seeded admin
  credentials immediately after go-live.
- **Real prod data later:** when AWS/devops access returns, restore the S3 PITR dump into this Postgres
  and re-run migrations — do it *before* much fresh data accrues (see ../docs/plans/HETZNER-MIGRATION-PLAN.md §6).
- **Updates (auto-deploy):** merge to `develop` → promote to `main` → each repo's `build-image`
  workflow publishes `:latest` + `:sha-<commit>`, then its **`deploy.yml` workflow SSHes into this
  box and runs `deploy.sh` automatically** (no manual step). Each repo deploys only **its own**
  service (`BACKEND_TAG` / `FRONTEND_TAG` in `.env`). To deploy/roll back by hand, set the service
  tag and run `./deploy.sh` (e.g. `BACKEND_TAG=sha-<commit> ./deploy.sh`).
- **Rollback** is a first-class workflow: in the affected repo, **Actions → deploy → Run workflow**
  with `image_tag = sha-<40hex>` (or `latest` to roll forward). Full runbook:
  `<repo>/docs/runbooks/DEPLOYMENT.md`.
- This folder should become its own git repo (`rumi-deploy`); `.env` and `app-secrets.json` stay git-ignored.

## CI/CD auto-deploy + rollback (GitHub Actions → this box)
Each repo's `.github/workflows/deploy.yml` runs on `main` (auto, after `build-image` succeeds) or
via `workflow_dispatch` (manual deploy/rollback to a chosen GHCR tag) and SSHes here to run
`deploy.sh` with its service tag. One-time setup to activate it (**already done** as of 2026-06-30):

1. **Dedicated deploy keypair** (do NOT reuse a personal key):
   ```bash
   ssh-keygen -t ed25519 -C "rumi-ci-deploy" -f rumi_ci_deploy -N ""
   # append the .pub to the deploy user on the box:
   ssh-copy-id -i rumi_ci_deploy.pub rumi@159.195.137.101   # or paste into ~/.ssh/authorized_keys
   ```
2. **Actions secrets** in *both* repos (or org-level, shared):
   | Secret | Value |
   |---|---|
   | `DEPLOY_HOST` | `159.195.137.101` |
   | `DEPLOY_USER` | `rumi` |
   | `DEPLOY_SSH_KEY` | contents of the **private** `rumi_ci_deploy` |
   | `DEPLOY_SSH_FINGERPRINT` | `ssh-keyscan -t ed25519 159.195.137.101` (the host key line) |
3. **Passwordless sudo** for the one `sudo chown` in `deploy.sh` (non-interactive SSH can't answer a
   password prompt). As root: `echo 'rumi ALL=(root) NOPASSWD: /usr/bin/chown' > /etc/sudoers.d/rumi-deploy && chmod 440 /etc/sudoers.d/rumi-deploy`
   (or drop the `chown` from `deploy.sh` if `app-secrets.json` perms are already correct).
4. `deploy.yml` wraps the remote call in `flock -n /tmp/rumi-deploy.lock` so a frontend and
   backend deploy firing at the same moment serialize instead of racing, and passes the chosen
   tag via appleboy `envs` (not string-interpolated).
