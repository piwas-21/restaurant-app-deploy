# Rotating a secret

> Every application secret in this platform was permanent until 2026-09-04: `gen-secrets.sh`
> generates three of them once, at box setup, and **refuses to overwrite an existing file** —
> correct for scaffolding, and explicitly not a rotation tool (#162).
>
> This runbook is written from a rotation that was actually **rehearsed on the staging box**,
> not from reading the scripts. Four of the things below are only visible from doing it, and
> two of them make a *failed* rotation look like a successful one.

---

## Read this first — four traps

**1. `docker compose restart` does NOT pick up a changed `.env`.** It restarts the existing
container with the environment it was created with. Every value here is injected through
compose interpolation, so a rotation needs:

```bash
docker compose up -d --no-deps --force-recreate <service>
```

**2. The app keeps working on STALE POOLED CONNECTIONS.** PostgreSQL does not terminate
existing sessions when a role's password changes, and Npgsql holds a pool. Measured: after
`ALTER ROLE … PASSWORD` plus a `restart`, `/api/Menus` answered **200 for as long as the pool
lived** — and 500 the moment the sessions were killed. A rotation verified only by "the site
still loads" is not verified at all; it is a time bomb that detonates when the pool recycles.
Force the question:

```bash
docker compose -f docker-compose.prod.yml exec -T postgres \
  psql -U "$POSTGRES_USER" -d postgres -tAc \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='<tenant_db>'"
```

**3. A tenant's compose service is `backend-<slug>`, not `backend`.** `docker compose restart
backend` inside a tenant directory fails with `no such service: backend` — and if stderr is
discarded, it looks like it worked while nothing was recreated. Check `docker compose ps`
before and after, and read the `Recreated` line.

**4. Do NOT verify a database password from inside the postgres container.** `pg_hba.conf`
carries `host all all 127.0.0.1/32 trust`, so a `docker exec … psql -h 127.0.0.1` session
authenticates **any** password, including a deliberately wrong one — measured. Containers
reach the database as `Host=postgres` over the docker network and hit
`host all all all scram-sha-256`, where the password is real. Verify there:

```bash
docker run --rm --network deploy_rumi -e PGPASSWORD='<wrong>' postgres:16 \
  psql -U <role> -h postgres -d <db> -tAc 'SELECT 1'     # MUST fail
docker run --rm --network deploy_rumi -e PGPASSWORD='<new>' postgres:16 \
  psql -U <role> -h postgres -d <db> -tAc 'SELECT 1'     # MUST succeed
```

The wrong-password call is the control. Without it you cannot tell "the new password works"
from "this connection path never checks passwords".

---

## What is rotatable, and what is not

| Secret | Where | Rotatable in place? |
|---|---|---|
| Tenant DB password | `tenants/<slug>/.env` | **Yes** — rehearsed below |
| `POSTGRES_PASSWORD` | deploy `.env` | Yes, but it is the superuser every script uses — see below |
| `PrinterSettings.ApiKey` | `app-secrets.json` (per tenant) | Yes, cheap today (no hardware — ROADMAP SD1) |
| `RESEND_API_KEY` | deploy `.env` + every tenant `app-secrets.json` | Yes, but N files at once |
| `SOFRA_AUTH_SECRET` | deploy `.env` | Yes — signs out every control-plane session |
| `BACKUP_AGENT_SECRET` | deploy `.env` | Yes |
| `JwtSettings.Secret` (per tenant) | `app-secrets.json` | Yes, but **signs out every live session** for that tenant — guest, cashier, kitchen screen. No dual-secret window exists |
| `RESTIC_PASSWORD` | `/root/.rumi-backup-env` | **NO — re-key, not rotate.** See below |

### `RESTIC_PASSWORD` is not rotatable

Changing the value **orphans every existing snapshot**. restic re-keying is a repository
operation (`restic key add` / `restic key remove`), and the old key must keep working until
every snapshot that needs it has been re-encrypted or aged out. Treat losing this value as
unrecoverable: regenerating it does **not** decrypt what is already stored.

`DEPLOYMENT.md` records the escrowed copy as `<generated once — escrowed>`. **Confirm the
escrow still exists off-box before touching anything else here** — it is the one secret whose
loss cannot be repaired by any procedure in this file.

---

## When to rotate

The trigger rule matters more than the calendar:

* **an operator leaves** — anyone who had box access had every secret on it;
* **any suspected exposure** — a pasted credential, a laptop lost, a screenshot;
* **after an incident** involving the secret, even if the secret is not believed to be the cause.

Absent a trigger, an annual pass over the table above is proportionate for this platform's
size. A cadence nobody keeps is worse than a trigger everybody understands.

---

## Procedure: a tenant's database password

**Rehearsed on staging against `demo`, 2026-09-04.** Roughly 2 minutes, one restart of that
tenant's backend. The tenant is briefly unavailable between the `ALTER` and the recreate.

```bash
# On the box.
SLUG=demo
ROLE="tenant_${SLUG}"                    # or the registry's db_role
DB="tenant_${SLUG}"                      # or the registry's db
NEW="$(openssl rand -base64 48 | tr -d '/+=' | cut -c1-32)"   # conn-string-safe: no / + =

# 1. change it in postgres
cd /opt/rumi/deploy
docker compose -f docker-compose.prod.yml exec -T postgres \
  psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres \
  -c "ALTER ROLE ${ROLE} PASSWORD '${NEW}'"

# 2. change it in the tenant env
cd "/opt/rumi/tenants/${SLUG}"
sed -i -E "s|^TENANT_DB_PASSWORD=.*|TENANT_DB_PASSWORD=${NEW}|" .env

# 3. RECREATE — not restart, and mind the service name
docker compose up -d --no-deps --force-recreate "backend-${SLUG}"
docker compose ps        # expect: backend-<slug>  Up <seconds>
```

**Verify — all four, in this order:**

```bash
# a. the app serves
curl -s -o /dev/null -w '%{http_code}\n' "https://<tenant domain>/api/Menus?page=1&pageSize=1"

# b. it is not living on a stale pool: kill the sessions, then ask again
docker compose -f /opt/rumi/deploy/docker-compose.prod.yml exec -T postgres \
  psql -U "$POSTGRES_USER" -d postgres -tAc \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${DB}'"
curl -s -o /dev/null -w '%{http_code}\n' "https://<tenant domain>/api/Menus?page=1&pageSize=1"

# c. a WRONG password is refused over the network (the control)
# The pragma has to sit on the line detect-secrets flags, and that line cannot be the
# `docker run` one — it ends in a `\` continuation, where a trailing comment truncates the
# command. Hoisting the value onto its own line is the fix, and it reads better anyway.
# Inline rather than baselined: a baseline entry is pinned to a line NUMBER, and this file
# will be edited above this point.
WRONG='definitely-not-it'  # pragma: allowlist secret
docker run --rm --network deploy_rumi -e PGPASSWORD="$WRONG" postgres:16 \
  psql -U "$ROLE" -h postgres -d "$DB" -tAc 'SELECT 1'      # expect: password authentication failed

# d. the new one is accepted over the network
docker run --rm --network deploy_rumi -e PGPASSWORD="$NEW" postgres:16 \
  psql -U "$ROLE" -h postgres -d "$DB" -tAc 'SELECT current_database()'
```

**What breaks if you get it wrong:** step 3 with `restart` instead of `up -d
--force-recreate` leaves the container on the old password. It will keep serving until the
connection pool recycles, then 500 for every request. Step (b) is the only check that
catches it while you are still watching.

---

## Procedure: `POSTGRES_PASSWORD` (the cluster superuser)

Higher blast radius than any tenant's: this value is in the deploy `.env` **and** is the user
`backup-dump.sh`, `backup-tenant.sh`, `restore-tenant.sh`, `deprovision-tenant.sh`,
`provision-tenant.sh` and `harden-tenant-db-access.sh` all connect as. They read it from
`.env` at run time, so they follow automatically — but the **running containers do not**.

```bash
cd /opt/rumi/deploy
NEW="$(openssl rand -base64 48 | tr -d '/+=' | cut -c1-32)"
docker compose -f docker-compose.prod.yml exec -T postgres \
  psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres \
  -c "ALTER ROLE ${POSTGRES_USER} PASSWORD '${NEW}'"
sed -i -E "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${NEW}|" .env
docker compose -f docker-compose.prod.yml up -d --force-recreate backend
```

**Verify:** run `./backup-dump.sh` and confirm it completes — the backup path is the one that
fails *silently and overnight* if this is missed, which is why it is the verification rather
than an afterthought.

---

## Procedure: a tenant's printer API key

Cheapest one today: there is **no printer hardware** (ROADMAP SD1), so nothing holds the old
value. It will not stay cheap once a device is paired.

```bash
SLUG=<slug>
NEW="$(openssl rand -hex 32)"
cd "/opt/rumi/tenants/${SLUG}"
python3 - "$NEW" <<'PY'
import json, sys
p = "app-secrets.json"
d = json.load(open(p))
d.setdefault("PrinterSettings", {})["ApiKey"] = sys.argv[1]
json.dump(d, open(p, "w"), indent=2)
PY
docker compose up -d --no-deps --force-recreate "backend-${SLUG}"
```

**Verify** (the tenant must have the `printing` module, or the endpoint answers
`ModuleNotEnabled` rather than 401/200 and proves nothing):

```bash
curl -s -o /dev/null -w 'no key  -> %{http_code}\n' "https://<domain>/api/orders/printer-feed"
curl -s -o /dev/null -w 'old key -> %{http_code}\n' -H "X-Api-Key: <old>" "https://<domain>/api/orders/printer-feed"
curl -s -o /dev/null -w 'new key -> %{http_code}\n' -H "X-Api-Key: <new>" "https://<domain>/api/orders/printer-feed"
```

Expect `401`, `401`, `200`. The old-key line is the one that proves the rotation happened
rather than that a key exists.

> **Do not leave this key blank.** `ApiKeyAuthFilter` fails OPEN on an empty value — it
> returns early and the endpoint serves the order feed, with customer names, phone numbers and
> addresses, to anyone (backend #475).

---

## Procedure: `JwtSettings.Secret` (per tenant)

Rotatable, and the most disruptive: it invalidates **every** access and refresh token for that
tenant at once. Every logged-in guest, cashier and kitchen screen is signed out and must log
in again. There is no dual-secret validation, so there is no gentle window.

Pick a genuinely quiet hour, tell the restaurant first, then edit
`JwtSettings.Secret` in that tenant's `app-secrets.json` and
`up -d --no-deps --force-recreate backend-<slug>`.

**Verify:** an access token captured before the change must be refused (401) and a fresh login
must succeed. Checking only that login works proves nothing — it would work whether or not the
secret changed.

Making this cheap needs dual-secret validation in the backend (accept old + new during a
window). That is a code change, not a runbook, and is worth its own issue: today the platform's
highest-value secret is also its hardest to rotate.

---

## Procedure: `RESEND_API_KEY`

Lives in the deploy `.env` **and** in every tenant's `app-secrets.json`. Rotate at the
provider, then rewrite all of them in one pass and recreate each backend. A wrong value does
not degrade — every send 403s.

**Verify** by triggering one real mail per stack (a password-reset request is the cheapest) and
reading the outbound ledger, not the container log.

---

## After any rotation

* Re-read `verify-env.sh` output — it is the one place that checks the box's env is complete.
* If the secret was in a tenant's `app-secrets.json`, confirm the file is still mode `640` and
  owned for the backend's uid/gid. `chmod 600` makes it unreadable to the container and the
  backend fails to start (a trap this platform has hit before).
* Record what you rotated and when. There is no automated inventory; this file plus the commit
  log is the audit trail.
