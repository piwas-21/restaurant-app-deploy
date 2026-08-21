#!/usr/bin/env bash
# Backup AGENT — the box half of the backup control-plane contract.
#
#   ./backup-agent.sh [--once] [--dry-run]
#
# Runs on the BOX HOST from cron every 5 minutes (NOT in a container — see the note on
# BACKUP_AGENT_SECRET below), from /opt/rumi/deploy, as the same user that runs
# backup-dump.sh. It does exactly two things:
#
#   1. PUSH the inventory      POST <sofra>/api/telemetry/backups
#   2. PULL and run jobs       GET  <sofra>/api/backups/jobs?box=<role>
#                              POST <sofra>/api/backups/jobs/<id>/result
#
# WHY THE BOX POLLS INSTEAD OF SOFRA PUSHING — this is the whole security design, not an
# implementation detail. Every credential points BOX -> SOFRA; the control plane never
# holds a credential that can reach a box (ADR-012 invariant 2: a compromised public
# sofra container can propose a tenant but never provision one). The obvious alternative,
# giving sofra a GitHub `Actions: write` token to dispatch a backup workflow, is REJECTED
# because `Actions: write` cannot be narrowed to one workflow (runbook §0b) — that token
# could equally dispatch deprovision-tenant.yml --drop-db. A backup feature must not hand
# anyone a tenant-destruction primitive. The cost is latency: a job is picked up on the
# next poll, up to 5 minutes. A backup is not interactive; that is acceptable.
#
# BACKUP_AGENT_SECRET lives in the box .env and this script reads it from there directly,
# because it runs on the HOST. The SOFRA CONTAINER needs the same value to verify the
# bearer, and for that it must be DECLARED in docker-compose.prod.yml — a .env var does
# NOT reach a container on its own. Both halves are wired; see .env.example.
#
# Same bearer posture as PRINTER_TELEMETRY_SECRET / CRON_SECRET. Unset -> this script is
# INERT (exits 0 silently), so it is safe to ship before the secret exists.
set -euo pipefail
cd "$(dirname "$0")"

# shellcheck source=backup-lib.sh
. ./backup-lib.sh

DRY_RUN=false
for a in "$@"; do
  case "$a" in
    --once) ;;             # accepted and ignored: one pass is all this ever does
    --dry-run|-n) DRY_RUN=true ;;
    *) bk_die "unknown flag '$a'" ;;
  esac
done

[[ -f .env ]] || bk_die "box .env missing (run from /opt/rumi/deploy)"
env_val() { grep -E "^$1=" .env | cut -d= -f2- | tr -d '"'"'"'' | tail -1 || true; }

SECRET="$(env_val BACKUP_AGENT_SECRET)"
if [[ -z "$SECRET" ]]; then
  # Inert, and quiet about it: this runs every 5 minutes and a chatty no-op is a log
  # nobody reads. Same self-guard the fleet pusher uses.
  exit 0
fi
BOX_ROLE="$(env_val BOX_ROLE)"
[[ -n "$BOX_ROLE" ]] || bk_die "BOX_ROLE not set in the box .env"
BASE_URL="$(env_val BACKUP_AGENT_URL)"
BASE_URL="${BASE_URL:-https://sofrapiwas.com}"
BASE_URL="${BASE_URL%/}"
# Deletion is OPT-IN per box and OFF by default. The control plane is the public,
# internet-facing half of this system; if it is ever compromised, the worst it can do
# through this channel is ask for MORE backups. Turning a public web app into a remote
# "delete this customer's backups" button is not a trade worth making silently — the
# owner enables it per box, knowingly, when the erasure workflow is wanted.
ALLOW_DELETE="$(env_val BACKUP_AGENT_ALLOW_DELETE)"
MAX_JOBS="${BACKUP_AGENT_MAX_JOBS:-10}"

# OFF-BOX reporting, opt-in per box because only ONE box can do it. Measured
# 2026-08-21: staging has no restic binary and no repository password, and the repo
# directory it hosts is prod's — encrypted and opaque to it. Prod holds
# `restic-staging`, which is where the STAGING box's per-tenant dumps land, so the box
# that can see a tenant's off-box copy is not the box that runs the tenant. Set
# BACKUP_AGENT_RESTIC_REPO on the box that holds the repository; leave it unset
# everywhere else and this whole path is skipped.
RESTIC_REPO="$(env_val BACKUP_AGENT_RESTIC_REPO)"
RESTIC_TAGS="$(env_val BACKUP_AGENT_RESTIC_TAGS)"
RESTIC_TAGS="${RESTIC_TAGS:-staging-dumps tenant-archive}"
# The repository password is NOT in the box .env and must not be copied there: it lives
# in /root/.rumi-backup-env, which backup-offsite.sh already sources, mode 600.
RESTIC_ENV="$(env_val BACKUP_AGENT_RESTIC_ENV)"
RESTIC_ENV="${RESTIC_ENV:-/root/.rumi-backup-env}"

command -v curl >/dev/null || bk_die "curl not installed"

# One agent at a time. A `create` job can outrun the 5-minute cron tick, and two
# concurrent pg_dumps of the same tenant is the shape that fills a disk at 3am.
LOCK="/tmp/rumi-backup-agent.lock"
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK"
  flock -n 9 || { echo "another backup-agent run holds the lock — skipping this tick"; exit 0; }
fi

# The bearer goes in a 600 curl config file, never on the command line: argv is visible
# to every process on the box via /proc, and this secret authenticates the whole fleet.
CURL_CFG="$(mktemp)"
BODY="$(mktemp)"
INV="$(mktemp)"
OFFBOX="$(mktemp)"
trap 'rm -f "$CURL_CFG" "$BODY" "$INV" "$OFFBOX"' EXIT
chmod 600 "$CURL_CFG"
printf 'header = "Authorization: Bearer %s"\n' "$SECRET" > "$CURL_CFG"
printf 'header = "Content-Type: application/json"\n' >> "$CURL_CFG"
printf 'silent\nshow-error\nmax-time = 30\nretry = 2\n' >> "$CURL_CFG"

HTTP_CODE=0
api() { # <method> <url> [payload-file]  -> body in $BODY, status in $HTTP_CODE
  local method="$1" url="$2" payload="${3:-}"
  if [[ -n "$payload" ]]; then
    HTTP_CODE="$(curl -K "$CURL_CFG" -X "$method" --data-binary "@${payload}" \
      -o "$BODY" -w '%{http_code}' "$url" || echo 000)"
  else
    HTTP_CODE="$(curl -K "$CURL_CFG" -X "$method" -o "$BODY" -w '%{http_code}' "$url" || echo 000)"
  fi
}

# ── 1. push the inventory ────────────────────────────────────────────────────────────

# Merge the off-box artifacts into the local walk, or REFUSE TO PUSH.
#
# The refusal is the important half. The ingest is a WHOLE-BOX upsert that PRUNES what
# it stops listing, so an inventory missing its restic rows does not read as "we could
# not look" — it reads as "those copies are gone", and deletes them from the control
# plane. Every failure here therefore aborts the push entirely rather than sending the
# local half: the box then stops reporting, goes `quiet` after six hours, and the
# twice-daily alarm says so by name. Silence that is alarmed beats a confident wrong
# answer that is not.
#
# Returns 1 when the caller must not push.
merge_offbox() {
  [[ -n "$RESTIC_REPO" ]] || return 0
  if [[ ! -f "$RESTIC_ENV" ]]; then
    echo "   WARN: ${RESTIC_ENV} missing — NOT pushing (a listing without the off-box rows would prune them)" >&2
    return 1
  fi
  # In a subshell: RESTIC_PASSWORD must not leak into the environment of the job
  # handlers below, which run pg_dump and tar.
  if ! (
    # shellcheck source=/dev/null
    . "$RESTIC_ENV"
    export RESTIC_PASSWORD
    # shellcheck disable=SC2086  # tags are a deliberate word-split list
    bk_restic_artifacts_json "$RESTIC_REPO" $RESTIC_TAGS
  ) > "$OFFBOX"; then
    echo "   WARN: restic enumeration failed for ${RESTIC_REPO} — NOT pushing this tick" >&2
    return 1
  fi
  python3 - "$INV" "$OFFBOX" <<'PY' || return 1
import json, sys

inv = json.load(open(sys.argv[1]))
off = json.load(open(sys.argv[2]))
inv["artifacts"].extend(off)
json.dump(inv, open(sys.argv[1], "w"), separators=(",", ":"))
PY
  return 0
}

push_inventory() {
  bk_inventory_json "$BOX_ROLE" > "$INV"
  merge_offbox || return 0
  local n
  n="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["artifacts"]))' "$INV")"
  if $DRY_RUN; then
    echo "   DRY RUN: would POST ${n} artifact(s) to ${BASE_URL}/api/telemetry/backups"
    return 0
  fi
  api POST "${BASE_URL}/api/telemetry/backups" "$INV"
  if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "204" ]]; then
    echo "   pushed ${n} artifact(s) (HTTP ${HTTP_CODE})"
  else
    # Not fatal: the inventory is a report. Failing the whole run here would also skip
    # the jobs, and a control plane that is down must not stop the box doing its work.
    echo "   WARN: inventory push failed (HTTP ${HTTP_CODE}): $(head -c 200 "$BODY")" >&2
  fi
}

bk_log "backup-agent (box=${BOX_ROLE}) -> ${BASE_URL}"
push_inventory

# ── 2. pull jobs ─────────────────────────────────────────────────────────────────────
if $DRY_RUN; then
  bk_log "DRY RUN: not pulling jobs"
  exit 0
fi

api GET "${BASE_URL}/api/backups/jobs?box=${BOX_ROLE}"
if [[ "$HTTP_CODE" != "200" ]]; then
  echo "   WARN: job poll failed (HTTP ${HTTP_CODE})" >&2
  exit 0
fi

# Parse defensively: this payload comes from the internet-facing half of the system.
# Anything malformed, over-long, or outside the vocabulary is dropped here rather than
# reaching a shell. id/slug/ref are shape-checked again before use.
# --- BEGIN job filter (extracted verbatim by tests/backup-retention.sh) ---
JOBS="$(python3 - "$BODY" "$MAX_JOBS" <<'PY'
import json, re, sys
ID = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
SLUG = re.compile(r"^[a-z0-9][a-z0-9-]{1,30}$")
# The same shape backup-lib.sh's bk_ref_ok enforces, so this filter can never pass
# something the script it feeds would refuse: <tree>/<slug>/<rest>, relative, no
# traversal, no metacharacters. Both checks stay — this one keeps a hostile string out
# of the shell at all, bk_ref_ok is the one that knows which tenant it may belong to.
REF = re.compile(r"^(dumps/tenants|archive)/[a-z0-9][a-z0-9-]{1,30}/[A-Za-z0-9._/-]{1,150}$")
try:
    with open(sys.argv[1]) as fh:
        doc = json.load(fh)
    jobs = doc.get("jobs") or []
except (OSError, ValueError):
    sys.exit(0)
out = []
for j in jobs[: int(sys.argv[2])]:
    if not isinstance(j, dict):
        continue
    jid, action, slug = str(j.get("id", "")), str(j.get("action", "")), str(j.get("tenantSlug", ""))
    ref = j.get("ref") or ""
    ref = str(ref)
    if not (ID.match(jid) and action in ("create", "delete") and SLUG.match(slug)):
        continue
    if ref and (not REF.match(ref) or ".." in ref):
        continue
    out.append("\t".join((jid, action, slug, ref)))
print("\n".join(out))
PY
)"
# --- END job filter ---

if [[ -z "$JOBS" ]]; then
  bk_log "no jobs"
  exit 0
fi

# The artifact block for a result, read back off disk so the control plane is told what
# EXISTS rather than what the script believes it wrote.
artifact_json() { # <ref>
  bk_inventory_json "$BOX_ROLE" | python3 -c '
import json, sys
ref = sys.argv[1]
doc = json.load(sys.stdin)
for a in doc["artifacts"]:
    if a["ref"] == ref:
        print(json.dumps(a, separators=(",", ":")))
        break
else:
    print("null")
' "$1"
}

report() { # <job-id> <ok true|false> <error-or-empty> <artifact-json|null>
  local rf
  rf="$(mktemp)"
  BK_OK="$2" BK_ERR="$3" BK_ART="$4" python3 - > "$rf" <<'PY'
import json, os
err = os.environ["BK_ERR"].strip()
art = os.environ["BK_ART"].strip() or "null"
try:
    art = json.loads(art)
except ValueError:
    art = None
print(json.dumps({
    "ok": os.environ["BK_OK"] == "true",
    # Bounded: a stack of shell output is not a useful error and an unbounded one is a
    # log-injection surface on the other side.
    "error": err[:500] or None,
    "artifact": art,
}, separators=(",", ":")))
PY
  api POST "${BASE_URL}/api/backups/jobs/$1/result" "$rf"
  rm -f "$rf"
  echo "   result for job $1: ok=$2 (HTTP ${HTTP_CODE})"
}

# Read the job list on fd 3, not stdin: every branch below runs `docker compose exec -T`,
# which forwards stdin into the container and would eat the rest of this list.
while IFS=$'\t' read -r JOB_ID ACTION SLUG REF <&3; do
  [[ -n "${JOB_ID:-}" ]] || continue
  bk_log "job ${JOB_ID}: ${ACTION} ${SLUG}${REF:+ (${REF})}"
  LOG="$(mktemp)"
  case "$ACTION" in
    create)
      if ./backup-tenant.sh "$SLUG" --kind manual --quiet >"$LOG" 2>&1 </dev/null; then
        NEW_REF="$(grep '^ref=' "$LOG" | tail -1 | cut -d= -f2-)"
        report "$JOB_ID" true "" "$(artifact_json "$NEW_REF")"
      else
        report "$JOB_ID" false "$(tail -c 400 "$LOG")" null
      fi
      ;;
    delete)
      if [[ "$ALLOW_DELETE" != "true" ]]; then
        # Refused, but ANSWERED — a job that silently never completes is the worst of
        # both worlds: the owner watches a spinner and nobody learns why.
        report "$JOB_ID" false "delete refused: BACKUP_AGENT_ALLOW_DELETE is not true on box ${BOX_ROLE}" null
      elif [[ -z "$REF" ]]; then
        report "$JOB_ID" false "delete refused: no ref (whole-tenant erasure is a deliberate on-box run of backup-erase-tenant.sh)" null
      # --no-restic: a control-plane delete removes the artifact from THIS box only.
      # Rewriting an encrypted repo and pruning it is a heavy, root-owned, prod-only
      # operation, and a GDPR erasure has to reach both boxes anyway — so that path stays
      # a deliberate on-box run (DEPLOYMENT.md §Privacy), not something a web request
      # triggers as a side effect.
      elif ./backup-erase-tenant.sh "$SLUG" --confirm "$SLUG" --ref "$REF" --no-restic >"$LOG" 2>&1 </dev/null; then
        report "$JOB_ID" true "" null
      else
        report "$JOB_ID" false "$(tail -c 400 "$LOG")" null
      fi
      ;;
    *)
      report "$JOB_ID" false "unknown action" null ;;
  esac
  rm -f "$LOG"
done 3<<< "$JOBS"

# Re-push so the control plane reflects what just happened without waiting 5 minutes.
push_inventory
bk_log "backup-agent done"
