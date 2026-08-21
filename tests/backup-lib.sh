#!/usr/bin/env bash
# Unit tests for backup-lib.sh — the shared spine of the backup family
# (backup-dump.sh, backup-tenant.sh, backup-archive-tenant.sh, restore-tenant.sh,
# backup-erase-tenant.sh, backup-agent.sh).
#
# WHY these four things and not others. Everything else in that family needs a running
# postgres and a real box; these do not, and they are the parts where a silent wrong
# answer is expensive:
#
#   1. bk_ref_ok        — a TRUST BOUNDARY. Refs come from the control plane, which is the
#                         public, internet-facing half of the system. Every path the
#                         family builds interpolates one. A missed `..` here is a remote
#                         file-delete primitive, so it is tested adversarially.
#   2. bk_ts_older_than_months — the retention clock. Wrong by one month, and a departed
#                         tenant's only remaining copy is deleted early; the failure is
#                         silent, permanent, and discovered by the customer.
#   3. bk_registry_tenants — the ONE place `managed: legacy` is filtered out. RUMI (tenant
#                         1, a live paying restaurant sharing the MAIN compose project)
#                         must never appear in a loop that dumps or archives per tenant —
#                         ADR-006. Asserted against the registry ACTUALLY COMMITTED here,
#                         so adding a legacy tenant without updating the filter fails CI.
#   4. bk_inventory_json — the wire contract with the sofra control plane. The two halves
#                         were built in parallel against a written spec, so the shape is
#                         asserted field by field rather than "it produced some JSON".
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../backup-lib.sh"
REGISTRY="$HERE/../tenants/registry.yml"
[[ -f "$LIB" ]] || { echo "cannot find backup-lib.sh next to $HERE"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Point the whole library at a temp tree BEFORE sourcing — every path it defines is
# `${VAR:-default}`, so this is also a test that none of them is hardcoded.
export BACKUP_ROOT="$TMP/backups"
export DUMP_DIR="$BACKUP_ROOT/dumps"
export TENANT_DUMP_DIR="$DUMP_DIR/tenants"
export ARCHIVE_DIR="$BACKUP_ROOT/archive"
export ERASURE_LOG="$BACKUP_ROOT/erasures.log"
# shellcheck source=../backup-lib.sh
. "$LIB"

fail=0
pass() { local desc="$1"; printf '  ok   %s\n' "$desc"; }
bad()  { local desc="$1"; printf '  FAIL %s\n' "$desc"; fail=1; }
check() { # <desc> <rc> <expected rc>
  local desc="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then pass "$desc"; else bad "$desc (rc=$got, wanted $want)"; fi
}

echo "bk_slug_ok:"
for s in demo obresse a1 x-y-z tenant-with-a-name; do
  rc=0; bk_slug_ok "$s" || rc=$?; check "accepts '$s'" "$rc" 0
done
for s in "" A Demo "de mo" "-demo" "demo/" "../etc" "x" "$(printf 'a%.0s' $(seq 1 40))"; do
  rc=0; bk_slug_ok "$s" || rc=$?; check "rejects '$s'" "$rc" 1
done

echo "bk_ref_ok (adversarial — these strings arrive from the internet-facing control plane):"
good_refs=(
  "dumps/tenants/demo/demo-scheduled-20260821T021500Z.sql.gz"
  "dumps/tenants/demo/demo-manual-20260821T021500Z.sql.gz.sha256"
  "archive/demo/20260821T021500Z"
  "archive/demo/20260821T021500Z/db.sql.gz"
)
for r in "${good_refs[@]}"; do
  rc=0; bk_ref_ok "$r" demo || rc=$?; check "accepts $r" "$rc" 0
done
bad_refs=(
  ""                                            # nothing
  "/etc/passwd"                                 # absolute
  "/opt/rumi/backups/dumps/tenants/demo/x"      # absolute even though it looks right
  "dumps/tenants/demo/../../../etc/passwd"      # traversal out
  "dumps/tenants/demo/..%2f..%2fetc"            # traversal, encoded
  "archive/other/20260821T021500Z"              # ANOTHER tenant's archive
  "dumps/tenants/demo2/x.sql.gz"                # prefix collision on the slug
  "dumps/cluster-20260821T021500Z.sql.gz"       # the whole-cluster dump is not a tenant ref
  "archive/demo/\$(rm -rf /)"                   # shell metacharacters
  "archive/demo/x;rm -rf /"
  "archive/demo/x y"
  "tenants/demo/x.sql.gz"                       # right shape, wrong root
)
for r in "${bad_refs[@]}"; do
  rc=0; bk_ref_ok "$r" demo || rc=$?; check "rejects '$r'" "$rc" 1
done
rc=0; bk_ref_ok "archive/demo/20260821T021500Z" "../etc" || rc=$?
check "rejects a bad SLUG even with a well-formed ref" "$rc" 1

echo "bk_ts_of:"
[[ "$(bk_ts_of 'dumps/tenants/demo/demo-scheduled-20260821T021500Z.sql.gz')" == "20260821T021500Z" ]] \
  && pass "reads the stamp out of a dump name" || bad "dump name"
[[ "$(bk_ts_of 'archive/demo/20260821T021500Z')" == "20260821T021500Z" ]] \
  && pass "reads the stamp out of an archive dir" || bad "archive dir"
[[ -z "$(bk_ts_of 'archive/demo/whenever')" ]] && pass "empty when there is no stamp" || bad "no stamp"

echo "bk_ts_older_than_months (the retention clock — rc 0 = expired, 1 = keep, 2 = unusable):"
# Boundary: expiry is inclusive at the exact instant, and one second earlier is a keep.
rc=0; bk_ts_older_than_months 20240821T021500Z 24 20260821T021500Z || rc=$?
check "exactly 24 months later -> expired" "$rc" 0
rc=0; bk_ts_older_than_months 20240821T021500Z 24 20260821T021459Z || rc=$?
check "one second short of 24 months -> keep" "$rc" 1
rc=0; bk_ts_older_than_months 20250820T000000Z 24 20260821T021500Z || rc=$?
check "a year old -> keep (the case the whole feature exists for)" "$rc" 1
# Calendar months, not 30-day arithmetic: 24 * 30 days would expire this SIX WEEKS early.
rc=0; bk_ts_older_than_months 20240101T000000Z 24 20251202T000000Z || rc=$?
check "23 months + 1 day -> keep (30-day math would have deleted it)" "$rc" 1
# Month-end clamp: 31 Jan + 1 month has no 31 Feb.
rc=0; bk_ts_older_than_months 20260131T000000Z 1 20260228T000000Z || rc=$?
check "31 Jan + 1 month clamps to 28 Feb -> expired" "$rc" 0
rc=0; bk_ts_older_than_months 20240131T000000Z 1 20240229T000000Z || rc=$?
check "leap year: 31 Jan + 1 month -> 29 Feb -> expired" "$rc" 0
rc=0; bk_ts_older_than_months 20260821T021500Z 0 20260821T021500Z || rc=$?
check "zero months is valid (expire immediately)" "$rc" 0
for bad_ts in "" "notatimestamp" "2026-08-21" "20261321T021500Z"; do
  rc=0; bk_ts_older_than_months "$bad_ts" 24 20260821T021500Z || rc=$?
  check "unparseable '$bad_ts' -> rc 2 (caller KEEPS it)" "$rc" 2
done
rc=0; bk_ts_older_than_months 20240821T021500Z -1 20260821T021500Z || rc=$?
check "negative window -> rc 2, never a mass-delete" "$rc" 2

echo "bk_registry_tenants (ADR-006: managed:legacy must never enter a per-tenant loop):"
staging="$(bk_registry_tenants staging "$REGISTRY")"
prod="$(bk_registry_tenants prod "$REGISTRY")"
echo "$staging" | grep -q '^obresse$' && pass "staging includes the live reseller tenant 'obresse'" \
  || bad "obresse missing from the staging list"
echo "$staging" | grep -q '^demo$' && pass "staging includes 'demo'" || bad "demo missing"
if echo "$staging$prod" | grep -q '^rumi$'; then
  bad "RUMI (managed:legacy) appears in a per-tenant list — it shares the MAIN compose project"
else
  pass "RUMI is absent from BOTH boxes' lists"
fi
if echo "$staging" | grep -q '^smoke$'; then
  pass "the 'smoke' fixture IS listed (status is not filtered — a missing DB is skipped at dump time)"
else
  bad "smoke missing: status must not be used as the filter"
fi
# Cross-check against the file itself, so a new legacy tenant added later cannot slip in.
legacy_leak="$(python3 - "$REGISTRY" <<'PY'
import sys, yaml
reg = yaml.safe_load(open(sys.argv[1])) or {}
print(" ".join(s for s, t in (reg.get("tenants") or {}).items()
                if isinstance(t, dict) and t.get("managed") != "scripts"))
PY
)"
leaked=""
for s in $legacy_leak; do
  echo "$staging$prod" | grep -q "^${s}$" && leaked="$leaked $s"
done
[[ -z "$leaked" ]] && pass "no non-scripts tenant leaks into any box list (${legacy_leak:-none in registry})" \
  || bad "leaked:$leaked"
[[ -z "$(bk_registry_tenants nosuchbox "$REGISTRY")" ]] && pass "an unknown box role lists nothing" \
  || bad "unknown box role listed something"

echo "bk_inventory_json (the wire contract with the sofra control plane):"
mkdir -p "$TENANT_DUMP_DIR/demo" "$ARCHIVE_DIR/obresse/20260819T030000Z" \
         "$ARCHIVE_DIR/gone/20260101T000000Z" "$ARCHIVE_DIR/demo/not-a-timestamp"
printf 'x' > "$TENANT_DUMP_DIR/demo/demo-scheduled-20260820T021500Z.sql.gz"
printf 'deadbeef  demo-scheduled-20260820T021500Z.sql.gz\n' \
  > "$TENANT_DUMP_DIR/demo/demo-scheduled-20260820T021500Z.sql.gz.sha256"
printf 'yy' > "$TENANT_DUMP_DIR/demo/demo-manual-20260821T101500Z.sql.gz"
printf 'zzz'  > "$ARCHIVE_DIR/obresse/20260819T030000Z/db.sql.gz"
printf 'wwww' > "$ARCHIVE_DIR/obresse/20260819T030000Z/uploads.tar.gz"
cat > "$ARCHIVE_DIR/obresse/20260819T030000Z/manifest.json" <<'JSON'
{"schema":1,"reason":"deprovision","db":{"file":"db.sql.gz","sha256":"cafe1234"}}
JSON
printf 'q' > "$ARCHIVE_DIR/gone/20260101T000000Z/db.sql.gz"

INV="$TMP/inv.json"
bk_inventory_json staging 2026-08-21T09:00:00Z > "$INV"

if python3 - "$INV" <<'PY'
import json, sys

doc = json.load(open(sys.argv[1]))
errs = []
if doc.get("box") != "staging":
    errs.append("box")
if doc.get("reportedAt") != "2026-08-21T09:00:00Z":
    errs.append("reportedAt")
arts = {a["ref"]: a for a in doc["artifacts"]}

want_keys = {"tenantSlug", "kind", "takenAt", "sizeBytes", "location", "ref", "sha256"}
for ref, a in arts.items():
    if set(a) != want_keys:
        errs.append("keys of %s: %s" % (ref, sorted(set(a) ^ want_keys)))
    if a["location"] != "local":
        errs.append("location of " + ref)
    if a["kind"] not in ("scheduled", "manual", "deprovision", "archive"):
        errs.append("kind vocabulary: " + a["kind"])

d = arts.get("dumps/tenants/demo/demo-scheduled-20260820T021500Z.sql.gz")
if not d:
    errs.append("scheduled dump missing")
else:
    if d["kind"] != "scheduled":
        errs.append("scheduled kind")
    if d["tenantSlug"] != "demo":
        errs.append("slug")
    if d["takenAt"] != "2026-08-20T02:15:00Z":
        errs.append("takenAt ISO: " + d["takenAt"])
    if d["sizeBytes"] != 1:
        errs.append("sizeBytes")
    if d["sha256"] != "deadbeef":
        errs.append("sha256 from the sidecar")

m = arts.get("dumps/tenants/demo/demo-manual-20260821T101500Z.sql.gz")
if not m or m["kind"] != "manual":
    errs.append("manual dump kind")
elif m["sha256"] is not None:
    errs.append("sha256 must be null, not '' or absent, when there is no sidecar")

a = arts.get("archive/obresse/20260819T030000Z")
if not a:
    errs.append("archive missing")
else:
    if a["kind"] != "deprovision":
        errs.append("an archive taken BY a teardown reports kind=deprovision")
    # db.sql.gz (3) + uploads.tar.gz (4) + manifest.json: the archive reports the whole
    # directory as ONE artifact, because that is what makes it restorable.
    if a["sizeBytes"] < 3 + 4 + 10:
        errs.append("archive size must sum every file in the dir, got %d" % a["sizeBytes"])
    if a["sha256"] != "cafe1234":
        errs.append("sha256 from the manifest")

g = arts.get("archive/gone/20260101T000000Z")
if not g or g["kind"] != "archive" or g["sha256"] is not None:
    errs.append("a manifest-less archive still reports, as kind=archive with sha256 null")

if any(r.startswith("archive/demo/") for r in arts):
    errs.append("a directory with no timestamp must be ignored, not reported")
if len(arts) != 4:
    errs.append("expected exactly 4 artifacts, got %d: %s" % (len(arts), sorted(arts)))

# The whole-cluster dump is NOT a tenant artifact and must never be attributed to one.
if any(a["tenantSlug"] in ("", None) for a in arts.values()):
    errs.append("an artifact with no tenant")

if errs:
    print("   " + "\n   ".join(errs))
    sys.exit(1)
PY
then pass "the inventory matches the contract field for field"
else bad "inventory shape (details above)"
fi

# An empty box must still produce a valid, EMPTY inventory — the endpoint is a whole-box
# upsert, so "no artifacts" has to be sayable. A box that skipped the push instead would
# leave deleted artifacts on the control plane forever.
rm -rf "${TENANT_DUMP_DIR:?}" "${ARCHIVE_DIR:?}"
if bk_inventory_json prod | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["artifacts"]==[] and d["box"]=="prod" and d["reportedAt"] else 1)'; then
  pass "a box with no artifacts emits {artifacts: []}, not an error"
else
  bad "empty box inventory"
fi

echo
if [[ $fail -eq 0 ]]; then echo "backup-lib: all checks passed"; else echo "backup-lib: FAILURES"; fi
exit "$fail"
