# Uber channel gateway sandbox ingress

Run on **STAGING ONLY**, through `.ssh/staging.sh`; never a tenant or control-plane database.
Source: backend ADR-005; image `ghcr.io/piwas-21/sofra-channel-gateway:sha-<reviewed-develop-commit>`.
This receives signed notification references. It does **not** publish menus, accept orders or inject orders.
Do not place a test order until its accept/deny flow is implemented.

## Configuration

Copy `.env.channels-sandbox.example` to `.env.channels-sandbox` **on the box**, mode 600. Generate separate,
random hex-only `CHANNELS_OWNER_PASSWORD` and `CHANNELS_INGRESS_PASSWORD`. Set the pinned image, testing app
ID and approved test-store UUID. Save the existing Uber **testing app client secret** only with owner
authorization; a restaurant login password is not a webhook signing secret. Empty client secret = HTTP 503
for every webhook. Never put credentials in Git, commands, PRs or logs. Double literal `$` as `$$` for Compose.

The webhook origin is `channels-sandbox.sofrapiwas.com` (wildcard A record points to staging). No production
key, store or tenant mapping is configured. Keep DB owner and ingress passwords independent; the API receives
only its own role password, with INSERT/SELECT privileges and no schema, UPDATE or DELETE permission.

## First deployment

Execute inside `/opt/rumi/deploy` on staging after the gated infra release syncs these files:

```bash
docker compose --env-file .env.channels-sandbox -f docker-compose.channels-sandbox.yml up -d --wait channels-db
# Pull the exact image named in .env.channels-sandbox without displaying that file's secret values.
docker compose --env-file .env.channels-sandbox -f docker-compose.channels-sandbox.yml pull channels-sandbox
```

Apply `/app/migrations/001_webhook_inbox.sql` **from that exact gateway image**, once, as `channels_owner`
against `channels_sandbox`. The API never auto-migrates. Extract the SQL with `docker run --rm --entrypoint cat
<pinned-image> /app/migrations/001_webhook_inbox.sql`, then pipe it to `docker compose --env-file
.env.channels-sandbox -f docker-compose.channels-sandbox.yml exec -T channels-db psql -U channels_owner
-d channels_sandbox -v ON_ERROR_STOP=1`. Grant `USAGE ON SCHEMA public` and `INSERT, SELECT ON
channel_webhook_receipts` to `channels_ingress` afterward. API deployment is separate from schema application:

```bash
docker compose --env-file .env.channels-sandbox -f docker-compose.channels-sandbox.yml up -d channels-sandbox
```

Render `channels/webhook.caddy.template` by replacing `__CHANNELS_DOMAIN__` with the approved host into
`caddy-tenants/channels-sandbox.caddy`. Validate Caddy configuration, then reload Caddy. This is a **directory
mount**, so reload sees the new fragment; replacing the main bind-mounted Caddyfile would require recreation.
No existing tenant block, container, database or entitlement is changed by this standalone compose project.

## Verify before registering the primary webhook

- HTTPS `/api/health` returns the gateway identity and pinned revision, with a valid certificate. This is
  liveness, not DB readiness. Existing staging tenant/control-plane endpoints continue serving.
- Without a configured app secret, POST `/api/webhooks/uber-eats` returns 503. After configuring the secret,
  unsigned POST returns 401. Never register an unconfigured receiver as ready.
- Use the approved app secret to sign a synthetic provisioning reference for the allowlisted sandbox store.
  Require empty HTTP 200 and **one row** in the isolated database. Resend identical bytes; require empty 200
  and still one row. A signature over altered bytes must return 401 and create no row.
- Use the ingress role to prove SELECT works and DELETE fails. Container restart preserves the receipt and
  still deduplicates the same event. Do not expose an anonymous receipt reader or log provider payloads.

Only after these checks configure the testing app's single Primary Webhook URL:
`https://channels-sandbox.sofrapiwas.com/api/webhooks/uber-eats` and verify saved dashboard state. Confirm to Uber
support that the sandbox receiver is ready, with no claim that order processing/production certification is done.
Sending that reply requires the owner's explicit authorization.

## Operations and rollback

The dedicated `channels_db` volume preserves sandbox notification metadata across restarts. Before order
processing, add the approved backup/restore, retention, encrypted payload storage, monitoring and alerting policy.
There is no raw-body/customer data store or tenant credential in this initial inbox. Status remains `Received`;
it does not imply an order was processed. Acknowledge only when the insert commits; DB outage and rate throttling
return 503 so Uber can retry. Same event ID with changed bytes returns 409 for investigation.

Rollback: remove only `caddy-tenants/channels-sandbox.caddy` and reload Caddy; stop only this standalone compose
project's API. Preserve its database volume. Pin the previous reviewed image to roll back code. Never use
`down -v`, alter tenant stacks or delete receipts to recover an ingress deployment.
