#!/usr/bin/env bash
# Tests for list-release-tenants.sh — the selection that decides which tenants a FRONTEND
# release rebuilds and rolls.
#
# WHY THIS FILE IS THE ONE THAT MATTERS. The failure this whole chain exists to end is not
# a crash, it is a SILENCE: on 2026-08-30 the registry was perfectly correct and two real
# reseller tenants had simply never been rebuilt since the day they were provisioned —
# kebabdilhan a release behind, obresse eleven days behind — because nothing triggered.
# A selection bug here reproduces exactly that: a tenant quietly not in the list, a green
# run, and a customer on old code. So the load-bearing assertion below is not "the right
# tenants are chosen", it is **no active release-tracking tenant may vanish** — it must
# appear as eligible, or as refused with a reason, and never as nothing at all.
#
# The oracle for that assertion is DERIVED A SECOND TIME here, independently and more
# stupidly, straight out of the YAML. That duplication is deliberate and is the whole
# point: re-using the script's own selection would only prove the script agrees with
# itself. This is the one place in this repo where a second source of truth is correct.
#
# Everything else is fixtures, and they drive the DNS guard through a seam
# (LIST_RELEASE_TENANTS_FAKE_DNS) so the assertions do not depend on the state of the
# public DNS on the day CI runs — including the day the obresse A record finally appears.
# But a fake resolver can hide a real resolver that is broken in the always-false
# direction, which would refuse every tenant and look like a very cautious success. So
# there is also a POSITIVE CONTROL on the real one.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../list-release-tenants.sh"
REGISTRY="$HERE/../tenants/registry.yml"
[[ -x "$SCRIPT" ]] || { echo "cannot find an executable list-release-tenants.sh from $HERE"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail=0
pass() { local desc="$1"; printf '  ok   %s\n' "$desc"; }
bad()  { local desc="$1"; printf '  FAIL %s\n' "$desc"; fail=1; }

# `jq` is on every GitHub runner and on the boxes; used only by this test.
command -v jq >/dev/null || { echo "jq is required by this test"; exit 1; }

# Run the script on a registry, capture stdout. FAKE_DNS is passed as the FIRST arg;
# the literal string `-` means "leave the variable unset", i.e. use real DNS.
run() {
  local fake="$1" reg="$2"
  if [[ "$fake" == "-" ]]; then
    (unset LIST_RELEASE_TENANTS_FAKE_DNS; "$SCRIPT" "$reg" 2>/dev/null)
  else
    LIST_RELEASE_TENANTS_FAKE_DNS="$fake" "$SCRIPT" "$reg" 2>/dev/null
  fi
}

# ── 1. THE REGRESSION ASSERTION, against the REAL registry ───────────────────────────
# Independent oracle: every tenant that is managed:scripts AND status:active AND
# backend_tag:latest. Computed here from the YAML with no reference to the script.
echo "1. no active release-tracking tenant may vanish from the plan (real registry)"
python3 - "$REGISTRY" > "$WORK/oracle.txt" <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    reg = yaml.safe_load(f) or {}
for slug, t in sorted((reg.get("tenants") or {}).items()):
    t = t or {}
    if (t.get("managed") == "scripts"
            and str(t.get("status")) == "active"
            and str(t.get("backend_tag")) == "latest"):
        print(slug)
PY
run - "$REGISTRY" > "$WORK/real.json"
jq -r '[(.eligible[].slug), (.refused_unacknowledged[].slug), (.refused_acknowledged[].slug)] | .[]' \
  "$WORK/real.json" | sort > "$WORK/accounted.txt"

if [[ ! -s "$WORK/oracle.txt" ]]; then
  # An empty oracle would make the loop below vacuously green — the exact shape of the
  # bug being guarded against. Fail instead.
  bad "the oracle found NO active release-tracking tenant in the real registry — either the registry lost every tenant or this test's own derivation broke"
else
  missing=""
  while IFS= read -r slug; do
    grep -qx "$slug" "$WORK/accounted.txt" || missing="$missing $slug"
  done < "$WORK/oracle.txt"
  if [[ -n "$missing" ]]; then
    bad "silently dropped from the plan:$missing (must be eligible OR refused, never absent)"
  else
    pass "every active release-tracking tenant is accounted for ($(tr '\n' ' ' < "$WORK/oracle.txt"))"
  fi
fi

# ── 2. POSITIVE CONTROL on the REAL resolver ─────────────────────────────────────────
# Without this, a resolver stuck at False would refuse the whole fleet and every fixture
# below would still pass.
echo "2. the real resolver actually resolves something"
if [[ "$(jq '.eligible | length' "$WORK/real.json")" -gt 0 ]]; then
  pass "real DNS yields at least one eligible tenant: $(jq -c '[.eligible[].slug]' "$WORK/real.json")"
else
  bad "real DNS yielded NO eligible tenant — the guard is refusing everything, which is not a safe default, it is a broken instrument"
fi

# ── 3. Fixtures ──────────────────────────────────────────────────────────────────────
# One file, five tenants, each isolating one rule. `good.example` is the only host in
# the fake resolver, so every other domain below is unresolvable BY CONSTRUCTION.
cat > "$WORK/fixture.yml" <<'YML'
version: 1
tenants:
  legacyone:
    name: Legacy
    status: active
    managed: legacy
    box: prod
    domain: good.example
    backend_tag: latest
    frontend_tag: latest
  retiredone:
    name: Retired
    status: retired
    managed: scripts
    box: staging
    domain: good.example
    backend_tag: latest
    frontend_tag: tenant-retiredone
  provisioningone:
    name: Being Provisioned
    status: provisioning
    managed: scripts
    box: staging
    domain: good.example
    backend_tag: latest
    frontend_tag: tenant-provisioningone
  developone:
    name: Develop Showcase
    status: active
    managed: scripts
    box: staging
    domain: good.example
    backend_tag: staging
    frontend_tag: tenant-developone
  goodone:
    name: Real Customer
    status: active
    managed: scripts
    box: staging
    domain: good.example
    backend_tag: latest
    frontend_tag: tenant-goodone
    currency: EUR
    template: classic
YML

FIX="$(run good.example "$WORK/fixture.yml")"

# The three jq filters below are asked over and over, so they are named once rather than
# retyped (Sonar shelldre:S1192) — which also makes each assertion read as a sentence
# instead of as jq.
Q_ELIGIBLE='[.eligible[].slug] | join(",")'
Q_UNACK='[.refused_unacknowledged[].slug] | join(",")'
Q_ACK='[.refused_acknowledged[].slug] | join(",")'

# `local` for every positional, here and everywhere below (Sonar shelldre:S7679).
sel()   { local query="$1"; printf '%s' "$FIX" | jq -r "$query"; }
slugs() { local json="$1" query="$2"; printf '%s' "$json" | jq -r "$query"; }

echo "3. selection rules"
[[ "$(sel "$Q_ELIGIBLE")" == "goodone" ]] \
  && pass "exactly the active, script-managed, release-tracking tenant is eligible" \
  || bad "eligible was '$(sel "$Q_ELIGIBLE")', expected 'goodone'"

for pair in "legacyone:managed" "retiredone:status" "provisioningone:status" "developone:backend_tag"; do
  slug="${pair%%:*}"; want="${pair##*:}"
  reason="$(sel "(.excluded[] | select(.slug == \"$slug\") | .reason) // \"\"")"
  if [[ "$reason" == *"$want"* ]]; then
    pass "$slug excluded, and the reason names \`$want\`"
  else
    bad "$slug: expected an exclusion mentioning '$want', got '$reason'"
  fi
done

# ── 3b. The build inputs a matrix leg carries ────────────────────────────────────────
# `locale` decides where the currency symbol goes (de-CH: `EUR 8.00`, fr-FR: `8,00 €`),
# so an eligible tenant that does not carry one into the plan is a tenant the release
# rebuilds with Swiss formatting. Asserted on the EMITTED JSON, not on the registry text:
# it is the plan the frontend workflow's matrix reads.
echo "3b. locale reaches the plan"
[[ "$(sel '.eligible[0].locale')" == "de-CH" ]] \
  && pass "a tenant with no locale: field plans as de-CH (unchanged from before the field)" \
  || bad "absent locale planned as '$(sel '.eligible[0].locale')', expected 'de-CH'"

sed 's/^    currency: EUR$/    currency: EUR\n    locale: fr-FR/' \
  "$WORK/fixture.yml" > "$WORK/fixture-locale.yml"
grep -q 'locale: fr-FR' "$WORK/fixture-locale.yml" || { echo "fixture edit failed"; exit 1; }
WITH_LOCALE="$(run good.example "$WORK/fixture-locale.yml")"
[[ "$(slugs "$WITH_LOCALE" '.eligible[0].locale')" == "fr-FR" ]] \
  && pass "a declared locale is carried through to the plan verbatim" \
  || bad "locale: fr-FR planned as '$(slugs "$WITH_LOCALE" '.eligible[0].locale')'"

# ── 4. THE DNS GUARD ─────────────────────────────────────────────────────────────────
# Same fixture, same tenant, one thing changed: the host no longer resolves. A rebuild
# BAKES the domain as the bundle's origin, so this must refuse rather than proceed.
echo "4. the DNS guard"
NODNS="$(run "some.other.host" "$WORK/fixture.yml")"
if [[ "$(slugs "$NODNS" "$Q_ELIGIBLE")" == "" ]] \
   && [[ "$(slugs "$NODNS" "$Q_UNACK")" == "goodone" ]]; then
  pass "an unresolvable domain refuses the tenant instead of rebuilding it"
else
  bad "unresolvable domain: eligible='$(printf '%s' "$NODNS" | jq -c '[.eligible[].slug]')' refused='$(printf '%s' "$NODNS" | jq -c '[.refused_unacknowledged[].slug]')'"
fi
printf '%s' "$NODNS" | jq -e '.refused_unacknowledged[0].reason | test("does not resolve")' >/dev/null \
  && pass "the refusal says why, in the run log, not just in a status code" \
  || bad "the refusal reason does not mention resolution"

# ── 5. Acknowledging a block downgrades red to loud ──────────────────────────────────
# The obresse case, as a fixture: a real, currently-true situation (a partner has not
# published the A record for a tenant that is stale but WORKING on its old hostname).
# An alarm that stays red for weeks stops being an alarm, so an explicit registry
# acknowledgement moves it out of the failing list — and DELETING the key re-arms it.
echo "5. frontend_refresh_blocked (the obresse case)"
sed 's/^    currency: EUR$/    currency: EUR\n    frontend_refresh_blocked: "2026-08-30 — partner has not published the A record"/' \
  "$WORK/fixture.yml" > "$WORK/fixture-ack.yml"
grep -q frontend_refresh_blocked "$WORK/fixture-ack.yml" || { echo "fixture edit failed"; exit 1; }
ACK="$(run "some.other.host" "$WORK/fixture-ack.yml")"
if [[ "$(slugs "$ACK" "$Q_UNACK")" == "" ]] \
   && [[ "$(slugs "$ACK" "$Q_ACK")" == "goodone" ]]; then
  pass "an acknowledged block is reported but does not fail the run"
else
  bad "acknowledged block: unack='$(printf '%s' "$ACK" | jq -c '[.refused_unacknowledged[].slug]')' ack='$(printf '%s' "$ACK" | jq -c '[.refused_acknowledged[].slug]')'"
fi
# It must still not be BUILT — acknowledged is not permission.
[[ "$(slugs "$ACK" "$Q_ELIGIBLE")" == "" ]] \
  && pass "acknowledged still means NOT rebuilt (an acknowledgement is not permission)" \
  || bad "an acknowledged block became eligible — that is the tenant-killing rebuild this guard exists to stop"

# And the real registry's real obresse entry, as an invariant that survives the day the
# partner publishes DNS: if the domain does not resolve, it is not eligible. Full stop.
obresse_domain="$(python3 -c 'import sys,yaml;print((yaml.safe_load(open(sys.argv[1])).get("tenants") or {}).get("obresse",{}).get("domain",""))' "$REGISTRY")"
if [[ -n "$obresse_domain" ]]; then
  if getent hosts "$obresse_domain" >/dev/null 2>&1 || host "$obresse_domain" >/dev/null 2>&1; then
    pass "obresse's domain ($obresse_domain) resolves today — the guard has nothing to say about it"
  else
    jq -e '[.eligible[].slug] | index("obresse") | not' "$WORK/real.json" >/dev/null \
      && pass "obresse's domain ($obresse_domain) does not resolve and obresse is NOT eligible" \
      || bad "obresse's domain does not resolve yet obresse is eligible — a rebuild would kill a live tenant"
  fi
fi

# ── 6. Refusals that are about the shape of the entry ────────────────────────────────
echo "6. entry-shape refusals"
shape_case() {
  local desc="$1" sed_expr="$2" want="$3"
  sed "$sed_expr" "$WORK/fixture.yml" > "$WORK/shape.yml"
  local out; out="$(run good.example "$WORK/shape.yml")"
  local reason; reason="$(printf '%s' "$out" | jq -r '(.refused_unacknowledged[] | select(.slug=="goodone") | .reason) // ""')"
  if [[ "$reason" == *"$want"* ]]; then
    pass "$desc"
  else
    bad "$desc — expected a refusal mentioning '$want', got '$reason'"
  fi
}
shape_case "frontend_tag: latest is refused (it is the PROD stack's shared tag)" \
  's/^    frontend_tag: tenant-goodone$/    frontend_tag: latest/' 'SHARED stack tag'
shape_case "an unknown template is refused" \
  's/^    template: classic$/    template: brutalist/' 'is not classic|craft'
shape_case "a bad currency is refused" \
  's/^    currency: EUR$/    currency: euros/' 'ISO 4217'
# Underscore rather than a word, because `fr_FR` is the typo a human actually makes —
# it is what every POSIX locale on the box is called.
shape_case "a bad locale is refused" \
  's/^    currency: EUR$/    currency: EUR\n    locale: fr_FR/' 'is not a BCP-47 tag'
shape_case "an implausible box is refused" \
  's/^    box: staging$/    box: laptop/' 'neither prod nor staging'

echo
if [[ "$fail" -ne 0 ]]; then
  echo "list-release-tenants: FAILED"
  exit 1
fi
echo "list-release-tenants: all checks passed"
