#!/usr/bin/env bash
# Behaviour tests that need no box: the archive RETENTION CLOCK and the control plane's
# JOB FILTER. Both are places where the failure is silent and the blast radius is a
# customer's only remaining copy of their data.
#
#   part 1  backup-archive-tenant.sh --prune   run for real against a temp archive tree
#   part 2  the job filter inside backup-agent.sh, fed hostile payloads
#
# Part 2 EXTRACTS the filter from backup-agent.sh between its markers rather than copying
# it here, for the reason tests/admin-password.sh gives: a copy is a second source of
# truth that passes forever after the original changes.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
AGENT="$ROOT/backup-agent.sh"
ARCHIVER="$ROOT/backup-archive-tenant.sh"
[[ -f "$AGENT" && -f "$ARCHIVER" ]] || { echo "cannot find the backup scripts next to $HERE"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
pass() { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; fail=1; }

# ── part 1: the archive retention clock ─────────────────────────────────────────────
export BACKUP_ROOT="$TMP/backups"
export DUMP_DIR="$BACKUP_ROOT/dumps"
export TENANT_DUMP_DIR="$DUMP_DIR/tenants"
export ARCHIVE_DIR="$BACKUP_ROOT/archive"
export ERASURE_LOG="$BACKUP_ROOT/erasures.log"

# Eight months before NOW, computed rather than written down: a hardcoded 2025 stamp
# would quietly stop testing "survives 24 months" once the wall clock passed it.
EIGHT_MONTHS_AGO="$(python3 -c '
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(days=243)).strftime("%Y%m%dT%H%M%SZ"))')"

seed_archives() {
  rm -rf "$ARCHIVE_DIR"
  # An 8-month-old archive is THE SCENARIO THIS FEATURE EXISTS FOR: "a trial tenant who
  # comes back later on". Under the default 24-month horizon it must survive; under a
  # 1-month horizon (used below to keep the test fast and deterministic) it must not.
  mkdir -p "$ARCHIVE_DIR/lapsed/$EIGHT_MONTHS_AGO"
  mkdir -p "$ARCHIVE_DIR/recent/$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$ARCHIVE_DIR/held/$EIGHT_MONTHS_AGO"
  mkdir -p "$ARCHIVE_DIR/weird/no-timestamp-here"
  for d in "$ARCHIVE_DIR"/*/*; do printf 'x' > "$d/db.sql.gz"; done
  # A legal hold: an open dispute, an unpaid invoice, a pending data-subject request.
  # Retention must never win against one.
  : > "$ARCHIVE_DIR/held/$EIGHT_MONTHS_AGO/.hold"
}

echo "backup-archive-tenant.sh --prune:"
seed_archives
ARCHIVE_KEEP_MONTHS=24 "$ARCHIVER" --prune > "$TMP/out1" 2>&1 || bad "prune (24m) exited non-zero"
[[ -d "$ARCHIVE_DIR/lapsed/$EIGHT_MONTHS_AGO" ]] \
  && pass "an 8-month-old archive SURVIVES the 24-month horizon (the returning-trial case)" \
  || bad "the returning-trial archive was deleted by the default horizon"

seed_archives
ARCHIVE_KEEP_MONTHS=1 "$ARCHIVER" --prune --dry-run > "$TMP/out2" 2>&1 || bad "prune --dry-run exited non-zero"
if [[ -d "$ARCHIVE_DIR/lapsed/$EIGHT_MONTHS_AGO" ]] && grep -q 'WOULD expire' "$TMP/out2"; then
  pass "--dry-run reports what it would expire and deletes nothing"
else
  bad "--dry-run deleted something or reported nothing"
fi
[[ ! -s "$ERASURE_LOG" ]] && pass "--dry-run writes no tombstone" || bad "--dry-run wrote to the erasure log"

ARCHIVE_KEEP_MONTHS=1 "$ARCHIVER" --prune > "$TMP/out3" 2>&1 || bad "prune (1m) exited non-zero"
[[ ! -d "$ARCHIVE_DIR/lapsed/$EIGHT_MONTHS_AGO" ]] && pass "an expired archive is removed" \
  || bad "an expired archive survived"
[[ -n "$(find "$ARCHIVE_DIR/recent" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)" ]] \
  && pass "a fresh archive is kept" || bad "a fresh archive was removed"
[[ -d "$ARCHIVE_DIR/held/$EIGHT_MONTHS_AGO" ]] \
  && pass "an expired archive with a .hold file is KEPT (legal hold beats retention)" \
  || bad "a .hold archive was deleted"
[[ -d "$ARCHIVE_DIR/weird/no-timestamp-here" ]] \
  && pass "a directory with an unparseable name is kept, never guessed at" \
  || bad "an unparseable archive name was deleted"
grep -q 'prune' "$ERASURE_LOG" && pass "the deletion left a tombstone in the erasure log" \
  || bad "no tombstone written"
if grep -qiE '@|password|secret' "$ERASURE_LOG"; then
  bad "the erasure log contains something that looks like PII or a secret"
else
  pass "the erasure log holds only slug + ref + time (no PII, no secrets)"
fi

# The prune path must never touch the OPERATIONAL dumps beside it — different purpose,
# different clock, and a bug here would silently shorten every tenant's daily backup.
mkdir -p "$TENANT_DUMP_DIR/demo"
printf 'x' > "$TENANT_DUMP_DIR/demo/demo-scheduled-20200101T000000Z.sql.gz"
ARCHIVE_KEEP_MONTHS=1 "$ARCHIVER" --prune >/dev/null 2>&1 || true
[[ -f "$TENANT_DUMP_DIR/demo/demo-scheduled-20200101T000000Z.sql.gz" ]] \
  && pass "--prune leaves the operational per-tenant dumps alone" \
  || bad "--prune deleted an operational dump"

echo "backup-archive-tenant.sh refusals:"
rc=0; "$ARCHIVER" --prune extra >/dev/null 2>&1 || rc=$?
[[ $rc -ne 0 ]] && pass "--prune with a slug is refused (it is a whole-tree operation)" || bad "--prune accepted a slug"
rc=0; "$ARCHIVER" "BAD-SLUG" >/dev/null 2>&1 || rc=$?
[[ $rc -ne 0 ]] && pass "an invalid slug is refused" || bad "invalid slug accepted"
rc=0; "$ARCHIVER" demo --reason whatever >/dev/null 2>&1 || rc=$?
[[ $rc -ne 0 ]] && pass "an unknown --reason is refused (the vocabulary is fixed)" || bad "unknown --reason accepted"

# ── part 2: the control plane's job payload is untrusted input ───────────────────────
echo "backup-agent.sh job filter (payloads from the internet-facing control plane):"
FILTER="$TMP/filter.py"
sed -n "/^# --- BEGIN job filter/,/^# --- END job filter/p" "$AGENT" \
  | sed -n "/<<'PY'/,/^PY$/p" | sed '1d;$d' > "$FILTER"
grep -q 'SLUG.match' "$FILTER" || { echo "extraction failed — did the markers move?"; exit 1; }

run_filter() { # <json>  -> filtered lines on stdout
  printf '%s' "$1" > "$TMP/jobs.json"
  python3 "$FILTER" "$TMP/jobs.json" 10
}

out="$(run_filter '{"jobs":[{"id":"job_1","action":"create","tenantSlug":"obresse","ref":null}]}')"
[[ "$out" == "job_1	create	obresse	" ]] && pass "a well-formed create job passes through" || bad "create job: got '$out'"

out="$(run_filter '{"jobs":[{"id":"j2","action":"delete","tenantSlug":"demo","ref":"archive/demo/20260101T000000Z"}]}')"
[[ "$out" == "j2	delete	demo	archive/demo/20260101T000000Z" ]] && pass "a well-formed delete job passes through" || bad "delete job: got '$out'"

hostile=(
  '{"jobs":[{"id":"j","action":"create","tenantSlug":"demo; rm -rf /","ref":null}]}|slug with a shell command'
  '{"jobs":[{"id":"j","action":"provision","tenantSlug":"demo","ref":null}]}|an action outside create/delete'
  '{"jobs":[{"id":"j","action":"drop-db","tenantSlug":"demo","ref":null}]}|an action that sounds destructive'
  '{"jobs":[{"id":"j $(id)","action":"create","tenantSlug":"demo","ref":null}]}|a job id with a substitution'
  '{"jobs":[{"id":"j","action":"delete","tenantSlug":"demo","ref":"../../../etc/passwd"}]}|a traversing ref'
  '{"jobs":[{"id":"j","action":"delete","tenantSlug":"demo","ref":"/etc/passwd"}]}|an absolute ref'
  '{"jobs":[{"id":"j","action":"delete","tenantSlug":"demo","ref":"dumps/cluster-20260101T000000Z.sql.gz"}]}|a ref pointing at the whole-cluster dump'
  '{"jobs":[{"id":"j","action":"create","tenantSlug":"RUMI","ref":null}]}|an uppercase slug'
  '{"jobs":["not-an-object"]}|a job that is not an object'
  '{"jobs":"nope"}|jobs that is not a list'
  '{}|no jobs key'
  'not json at all|a body that is not JSON'
)
for h in "${hostile[@]}"; do
  payload="${h%%|*}"; desc="${h##*|}"
  out="$(run_filter "$payload" || true)"
  [[ -z "$out" ]] && pass "drops ${desc}" || bad "ACCEPTED ${desc}: '$out'"
done

# A control plane that has gone mad (or been taken over) must not be able to queue a
# thousand jobs into one tick.
many="$(python3 -c '
import json
print(json.dumps({"jobs": [{"id": "j%d" % i, "action": "create", "tenantSlug": "demo", "ref": None} for i in range(50)]}))')"
n="$(run_filter "$many" | wc -l | tr -d ' ')"
[[ "$n" == "10" ]] && pass "the per-tick job cap is enforced (50 offered, 10 taken)" || bad "job cap: took $n"

echo
if [[ $fail -eq 0 ]]; then echo "backup-retention/agent: all checks passed"; else echo "backup-retention/agent: FAILURES"; fi
exit "$fail"
