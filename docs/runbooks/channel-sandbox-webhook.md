# Uber channel gateway sandbox ingress

Run on **STAGING ONLY**, through `.ssh/staging.sh`; never a tenant or control-plane database.
Source: backend ADR-005; image `ghcr.io/piwas-21/sofra-channel-gateway:sha-<reviewed-develop-commit>`.
This receives signed notification references and provides a private sandbox console for merchant connection,
test-menu publishing/readback and explicit order accept/deny. It does not inject orders into tenant POS.

## Configuration

Copy `.env.channels-sandbox.example` to `.env.channels-sandbox` **on the box**, mode 600. Generate separate,
random hex-only `CHANNELS_OWNER_PASSWORD` and `CHANNELS_INGRESS_PASSWORD`. Set the pinned image, testing app
ID and approved test-store UUID. Save the existing Uber **testing app client secret** only with owner
authorization; a restaurant login password is not a webhook signing secret. Empty client secret = HTTP 503
for every webhook. Never put credentials in Git, commands, PRs or logs. Double literal `$` as `$$` for Compose.

The webhook origin is `channels-sandbox.sofrapiwas.com` (wildcard A record points to staging). No production
key, store or tenant mapping is configured. Keep DB owner and ingress passwords independent; the API receives
only its own role password, with INSERT/SELECT privileges on receipts and no schema or receipt UPDATE/DELETE
permission. The console adds CRUD grants on its own session/state/token/action tables only.

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

The dedicated `channels_db` volume preserves sandbox notification/action metadata across restarts.
There is no raw-body/customer data store or tenant credential in this initial inbox. Status remains `Received`;
it does not imply an order was processed. Acknowledge only when the insert commits; DB outage and rate throttling
return 503 so Uber can retry. Same event ID with changed bytes returns 409 for investigation.

Rollback: remove only `caddy-tenants/channels-sandbox.caddy` and reload Caddy; stop only this standalone compose
project's API. Preserve its database volume. Pin the previous reviewed image to roll back code. Never use
`down -v`, alter tenant stacks or delete receipts to recover an ingress deployment.

## Enable the private console

Before upgrading the API, take a mode-600 custom-format `pg_dump` of `channels_sandbox` in
`.channels-sandbox-backups/`; validate with `pg_restore --list`. This dedicated sandbox is outside the tenant
nightly dump. Back up before each operator test session and code/configuration change; retain seven local
snapshots, independently of tenant backups. Store the mode-600 `.env.channels-sandbox` key/config backup
separately in the owner's credential vault. A DB copy alone cannot decrypt token/PKCE ciphertext.

Apply `/app/migrations/002_sandbox_console.sql` from the exact reviewed new gateway image once, using the
same extraction and `ON_ERROR_STOP=1` procedure as 001. Do not reapply or edit 001. Then, as channels_owner:

```sql
GRANT SELECT, INSERT, UPDATE, DELETE ON channel_console_sessions, channel_authorization_states,
  channel_sandbox_tokens, channel_sandbox_order_actions TO channels_ingress;
```

Generate a random 32-byte base64 encryption key and an independent 32-byte base64url console access key.
Save **only the SHA256 hash** of the latter as `CHANNELS_CONSOLE_ACCESS_HASH`; save the encryption key as
`CHANNELS_CONSOLE_ENCRYPTION_KEY`. Deliver the raw console access key in a private mode-600 file to the owner,
not email/chat/PRs or shell arguments. Set `CHANNELS_CONSOLE_ORIGIN` to the approved HTTPS origin and
`CHANNELS_CONSOLE_ENABLED=true`. The API validates exactly one sandbox store and refuses production Uber
origins. Docker Compose must never print the resolved environment to logs.

Update the rendered Caddy fragment from `channels/webhook.caddy.template`, validate, reload, then start
only the standalone API using the new pinned image. Verify `/console/` and assets serve with no-store/CSP,
anonymous `/api/sandbox/uber/receipts` returns 401, expired/missing callback state cannot connect, and existing
signed webhook deduplication/tenant health remains intact. Prove the ingress role still cannot UPDATE/DELETE
receipts or CREATE a schema. Console grants never apply to any tenant database.

Register the testing application's redirect URI only after the real callback is deployed:
`https://channels-sandbox.sofrapiwas.com/api/sandbox/uber/callback`. The owner signs in to the private console
then uses **Connect with Uber** and personally approves the test merchant authorization. No support-side
grant or replacement client secret is required. Browser confirmation/credential entry remains the owner's
step. The callback discovers exact store access, nominates order-manager access while retaining tablet acceptance, and reads configuration back.

Publish and verify the previewed sandbox fixture. Enable/resume order testing runs a new session-bound merchant
OAuth flow: it reactivates safely, verifies menu readback, then requests console acceptance using merchant-token
POST. App-token PATCH can only pause/relinquish access. Require a confirmed Sofra order
manager (not pending). Sign in to Uber Eats Orders with the supplied restaurant account, set the test store
Open, and place a sandbox customer order using its Hoofddorp address. Keep the console open: notifications
refresh every 30 seconds, and each newly created order needs a prompt explicit accept/deny. If Uber requires
separate customer sandbox access, ask support for it; the supplied account is a Restaurant account.

Verify one acceptance, one denial, duplicate delivery and an order with customer/item instructions. Record
provider readback, not just HTTP 200. Synthetic ingress proves durability only. Never claim a tenant POS
order, printed kitchen ticket, live merchant approval or production certification from this console test.

## Recovery, retention and rotation

The console stores no order payload/customer details. Receipt/action metadata remain for sandbox diagnosis;
do not delete action guards while a test order can still be active. Sessions expire in 60 minutes and states
in 10 minutes; login deletes expired sessions and their states. App token expiry is enforced on every read.
The isolated DB and private backup files are bounded by the sandbox test window; purge/archive according to
the production privacy policy before enabling any real merchant rather than importing test records.

If an order decision times out, refresh its canonical state. Pending/Unknown blocks any second decision;
ACCEPTED/DENIED readback resolves only the matching action. A canceled, finished or opposite-state order
needs inspection in Uber Eats Orders/support, never deleting the action row to force a resend. No background
job silently accepts orders. Missing DB, invalid token encryption or provider scope failure remains visible.

For console access-key rotation: pause testing, generate a new key/hash, delete console sessions (cascades
states), update the mode-600 environment, and recreate only the API. For encryption-key rotation: disable
the console, back up DB/key together, delete cached app tokens and console sessions/states only, replace the
encryption key, then recreate and enable. Fresh app authentication remints tokens; receipt/action guards
remain. Never reuse the app client secret as an encryption or console-access key. Client-secret rotation
also affects webhook signatures and must follow Uber's separate app credential process.

Restore into an isolated disposable database first and compare table counts/constraints and action guards;
never restore over the serving DB or a tenant. API rollback uses the previous reviewed image while retaining
002 tables. Set `CHANNELS_CONSOLE_ENABLED=false` to withdraw console access while keeping signed ingress.
