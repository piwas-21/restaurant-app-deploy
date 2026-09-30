# Printer-app access in Sofra admin

Admins use `/admin/printers` to reveal and copy a tenant's API base URL, slug and
printer token, or request a replacement. Only active printing tenants are shown;
legacy tenants are read-only unless their own box opts in. All apps for one
restaurant share its key. Renewal restarts that tenant's backend briefly and
requires updating **every device** once the dashboard says ready.

## Installation

Release Sofra and deploy through their normal PR gates. Apply Sofra's handwritten
`20261001090000_printer_credentials` migration before its app rollout, using the
existing `:migrate` or `:migrate-staging` one-off procedure in DEPLOYMENT.md.

In the control-plane box `.env`, generate independent `openssl rand -hex 32`
values for:

- `PRINTER_CREDENTIAL_ENCRYPTION_KEY` (production encryption; escrow with box secrets)
- `PRINTER_AGENT_SECRET_PROD` and `PRINTER_AGENT_SECRET_STAGING` (dedicated box principals)
- `SOFRA_STAGING_PRINTER_ENCRYPTION_KEY` and `SOFRA_STAGING_PRINTER_AGENT_SECRET` (isolated staging tests)

Recreate the selected Sofra service so these **declared compose variables** reach
it. Do not share production credentials with the staging service. Do not replace
the encryption key casually: stored ciphertext needs its existing key to decrypt.

On each host, in `/opt/rumi/deploy/.env`:

```dotenv
PRINTER_AGENT_URL=https://sofrapiwas.com
PRINTER_AGENT_SECRET=<this box's matching PRINTER_AGENT_SECRET_PROD or STAGING>
# BOX_ROLE already identifies this host as prod or staging.
# Optional allowlist for demo-only rehearsal:
PRINTER_AGENT_TENANTS=demo
# Default false; only enable deliberately on a legacy tenant's own host:
PRINTER_AGENT_ALLOW_LEGACY_RENEW=false
```

The three agent files are synced by the normal deploy release. PyYAML and flock
are already host dependencies of the backup agent. Run as the host's existing
Docker-capable deploy user, never grant new sudo privileges:

```bash
cd /opt/rumi/deploy
bash printer-agent.sh --dry-run
bash printer-agent.sh
# Host crontab; independent from backup jobs:
# * * * * * /bin/bash /opt/rumi/deploy/printer-agent.sh >> /opt/rumi/printer-agent.log 2>&1
```

Remove the demo allowlist only when ready to report all active local printing
tenants. Existing keys are imported unchanged. The agent never reads a foreign
box's paths and never executes arbitrary server commands. Registry stays git-first.
For staging rehearsal, a mode-600 `--config /path/to/agent-staging.env` can override
URL/bearer/allowlist while preserving the box `.env`. Never log either file.

## Verify

1. Confirm the intended app revision via `/api/health` and migration via the DB.
2. Agent sync should make the demo card ready. Initial HTML must contain no key.
3. Reveal/copy setup; paste into printer-app Settings, save and test connection.
4. Request renewal by typing the demo slug. Dashboard remains pending until the
   host verifies the replacement; duplicate requests must not issue another key.
5. Check the old key returns 401, the new key returns 200, and update the emulator.
   API calls must not print feed payloads or key headers to terminal logs.
6. Failed verification keeps the job pending, restores the previous configured
   key, reports failure and retries next tick. Check agent connectivity and logs.

No print hardware is needed for credential validation. Sink receipt verification
is separate from this unchanged printer-feed authentication contract.
