<!--
  PR template — restaurant-app-deploy (LIVE box infra source of truth).
  PRs target `develop`; releases ship via a `develop` → `main` release PR (CLAUDE.md "Discipline (hard)").
  A merge to `main` rsyncs this repo to BOTH boxes (sync-to-box.yml → prod, sync-to-staging.yml → staging).
  Treat every release merge as applied-to-production config. Delete sections that don't apply.
-->

## Summary
- ...

## Issue / plan link
- Closes #
- Plan / runbook: <!-- DEPLOYMENT.md section / workspace ROADMAP row -->

## Type
- [ ] `feat` (new service/tenant machinery) · [ ] `fix` · [ ] `chore` · [ ] `docs`

## NFR triage (DEV-PHASES-PLAN P1 — one line per touched dimension, "rest: n/a because …")
<!-- D1 security · D3 cpu/mem (limits!) · D8 observability (healthchecks/logs/alerts) are the usual suspects here. -->
- D…:
- Rest: n/a because …

## Blast radius
- [ ] Prod box affected · [ ] Staging box affected · [ ] Both (both sync workflows fire on the release merge to `main`)
- Services touched: <!-- caddy / postgres / backend / frontend / sofra / tenant-* / dozzle -->
- Applies on: <!-- next rsync (config on disk) vs next `up -d` / recreate — say which, per the Caddyfile inode + tenants-dir mount traps -->

## Safety checklist
- [ ] No secret values in the diff (box `.env` / `app-secrets.json` stay box-local; `$` values documented as `$$`-escaped)
- [ ] No TLS/Caddy blocks on Netcup box hostnames (LE 429 trap)
- [ ] Scripts keep `set -euo pipefail`, pinned host keys, deploy flock, scoped sudo
- [ ] Tenant artifacts only via `tenants/templates/` + scripts; `registry.yml` edited by humans only
- [ ] `DEPLOYMENT.md` / runbook updated in this PR for any behavior change
- [ ] New/removed env keys mirrored into `.env.example` / `.env.staging.example` (no automated drift check exists — this is the contract)

## Rollout / verification plan
<!-- Exact commands (box.sh / staging.sh), what to check after, and the rollback path. -->
- [ ] ...
- [ ] Post-rollout: `verify-env.sh <staging|prod>` green (frontend + `/api/health` 200, cert sane)

## Deploy notes
- Requires manual action on box(es) after merge: no / yes (steps)
- Rollback: <!-- e.g. revert commit (rsync restores), force-recreate caddy, prior image tag -->
