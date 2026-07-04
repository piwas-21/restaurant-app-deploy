# RUMI deploy — Agent Rules

> Auto-loaded by Claude Code on every session in this repository. This repo is the **source of truth for RUMI's infrastructure** (compose, Caddy, deploy/provision scripts). **Production is LIVE for a paying client — act deliberately.**

## Identity

- Self-hosted **single-box Docker Compose** on Netcup RS boxes: Caddy (auto-TLS) → frontend + backend → Postgres 16 + Redis 7. Images pulled from GHCR (built by the app repos).
- Two environments: **prod** (`www.rumirestaurant.ch`, box `159.195.137.101`) and **staging** (`staging.fooderist.com`, box `159.195.34.105`).
- One of three repos under the [rumi-workspace](../); cross-repo plans + roadmap live at the workspace root.

## Subagents (delegate to the right one)

Versioned subagents live in [.claude/agents/](.claude/agents/):

| Agent | Lives in | Use for |
|---|---|---|
| **devops** | this repo ([.claude/agents/devops.md](.claude/agents/devops.md)) | any infra/deploy/ops task — boxes, Caddy/TLS, DNS, secrets, provisioning, release. It knows the exact commands + traps so it uses the wrappers/scripts instead of experimenting on live infra. |
| **backend** | backend repo | .NET code work |
| **frontend** | frontend repo | Next.js code work |

## Critical files to read

| When | Read |
|---|---|
| Deploy / rollback | [DEPLOYMENT.md](DEPLOYMENT.md) (canonical runbook) |
| Box setup / secrets / topology | [README.md](README.md) |
| Any infra op | the **devops** agent above — it encodes the deploy model + hard traps |

## Discipline (hard)

- **No live-infra experimentation.** Use the wrappers (`.ssh/box.sh` prod-root, `.ssh/staging.sh` staging-rumi), `verify-env.sh`, `domainio-dns.sh`.
- **Never use a Netcup box hostname (`*.megasrv.de`/`*.happysrv.de`) for a public TLS cert** — shared-domain Let's Encrypt rate limit (429). Use a real domain via the domainio API (`host` field, `ttl≥7200`).
- **Secrets (`.env`, `app-secrets.json`) live only on the box**, never committed.
- Changes ship as PRs through the review-gate (Stop + pre-push hooks). **No `--no-verify`, no bypasses.** Deploy-user sudo stays scoped to `chown -h` — never `NOPASSWD:ALL`.
- Staging exists to protect the one prod client: validate there first, then promote.

See the **devops** agent for the full command set and the environment/deploy-model tables.
