#!/usr/bin/env bash
# Unit test for provision-tenant.sh's domain / base_domain contract.
#
# WHY this exists. `domain_mode: subdomain` used to hardcode `sofrapiwas.com`, so a
# reseller partner could not put his clients under his own zone
# (`obresse.solutioneva.com` — SOFRA-PARTNER-FLEXIBILITY-PLAN §D1). Adding an optional
# `base_domain:` generalises the cross-check, and the whole risk of that change is
# regression: FOUR TENANTS ARE ALREADY IN THE REGISTRY, one of them a live business,
# and every one of them omits the new field. So the property under test is not "the new
# field works" but "an entry WITHOUT the new field behaves exactly as it did before it
# existed" — asserted below against a frozen copy of the old logic and against every
# entry actually committed to tenants/registry.yml.
#
# The second thing tested is the DNS diagnostic. Our base domain has a wildcard A
# record; a partner's has nothing and never will, so "the partner forgot the record" is
# now the predictable failure, and its symptom is a fully built tenant answering with a
# TLS error — indistinguishable from a broken product. The message therefore has to name
# the exact record (name / type / value), and that text is asserted here so it cannot
# rot into "check your DNS".
#
# The functions are EXTRACTED from provision-tenant.sh between its markers rather than
# copied here, for the reason tests/admin-password.sh gives: a copy is a second source
# of truth that passes forever after the original changes.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../provision-tenant.sh"
REGISTRY="$HERE/../tenants/registry.yml"
[[ -f "$SCRIPT" ]] || { echo "cannot find provision-tenant.sh next to $HERE"; exit 1; }

FNS="$(mktemp)"
trap 'rm -f "$FNS"' EXIT
sed -n '/^# --- BEGIN domain helpers/,/^# --- END domain helpers/p' "$SCRIPT" > "$FNS"
for fn in is_plausible_host resolve_domain_mode dns_record_advice; do
  grep -q "^${fn}() {" "$FNS" || { echo "extraction failed for ${fn} — did the markers move?"; exit 1; }
done
grep -q '^PLATFORM_BASE_DOMAIN=' "$FNS" || { echo "extraction missed PLATFORM_BASE_DOMAIN"; exit 1; }
# shellcheck disable=SC1090
source "$FNS"

fail=0
pass() { local desc="$1"; printf '  ok   %s\n' "$desc"; }
bad()  { local desc="$1"; printf '  FAIL %s\n' "$desc"; fail=1; }

# ── The frozen old logic ─────────────────────────────────────────────────────────
# A VERBATIM copy of provision-tenant.sh's domain-mode block as it stood at 31d1a62,
# immediately before `base_domain:` existed. It is a deliberate second implementation:
# the property "no base_domain == the old behaviour" cannot be asserted against an
# original that has been replaced, so the original is kept here and the verdicts are
# diffed. Do NOT "fix" or extend it — if it ever disagrees with resolve_domain_mode on
# an input with no base_domain, the NEW function is the one that is wrong.
legacy_domain_mode() { # $1=slug $2=domain $3=domain_mode ('' = infer)
  local slug="$1" domain="$2" mode="$3"
  if [[ -z "$mode" ]]; then
    if [[ "$domain" == *.sofrapiwas.com ]]; then mode=subdomain; else mode=byo; fi
  fi
  case "$mode" in
    subdomain)
      [[ "$domain" == "${slug}.sofrapiwas.com" ]] || return 1 ;;
    byo)
      [[ "$domain" == *.sofrapiwas.com ]] && return 1
      [[ "$domain" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] || return 1 ;;
    *) return 1 ;;
  esac
  printf '%s' "$mode"
}

# ── Helpers ──────────────────────────────────────────────────────────────────────
# Runs resolve_domain_mode and reports rc + stdout + stderr through globals, because
# bash 3.2 (the boxes are bash 5, a laptop is not) has no nameref to return them with.
RC=0; OUT=""; ERR=""
run_resolve() { # $1=slug $2=domain $3=mode $4=base
  local slug="$1" domain="$2" mode="$3" base="$4"
  local errf; errf="$(mktemp)"
  RC=0
  OUT="$(resolve_domain_mode "$slug" "$domain" "$mode" "$base" 2>"$errf")" || RC=$?
  ERR="$(cat "$errf")"
  rm -f "$errf"
}

expect_mode() { # <desc> <expected mode> <slug> <domain> <mode> <base>
  local desc="$1" want="$2"; shift 2
  run_resolve "$@"
  if [[ "$RC" -eq 0 && "$OUT" == "$want" ]]; then pass "$desc"
  else bad "$desc (rc=$RC out='$OUT', wanted mode '$want') ${ERR%%$'\n'*}"; fi
}

expect_reject() { # <desc> <substring the message must contain> <slug> <domain> <mode> <base>
  local desc="$1" needle="$2"; shift 2
  run_resolve "$@"
  if [[ "$RC" -eq 0 ]]; then bad "$desc — accepted (mode '$OUT'), expected a refusal"
  elif [[ "$ERR" != *"$needle"* ]]; then bad "$desc — refused, but the message never says '$needle': ${ERR%%$'\n'*}"
  else pass "$desc"; fi
}

echo "PLATFORM_BASE_DOMAIN:"
if [[ "$PLATFORM_BASE_DOMAIN" == "sofrapiwas.com" ]]; then pass "still sofrapiwas.com"
else bad "is '$PLATFORM_BASE_DOMAIN' — every absent base_domain silently moved with it"; fi

echo "is_plausible_host:"
for h in solutioneva.com obresse.solutioneva.com www.rumirestaurant.ch a-b.co.uk x1.y2.zz; do
  if is_plausible_host "$h"; then pass "accepts $h"; else bad "rejects $h"; fi
done
for h in "" solutioneva "https://solutioneva.com" "solutioneva.com." ".solutioneva.com" \
         "SolutionEva.com" "solution_eva.com" "solutioneva.com/clients" "-eva.com" "eva-.com" \
         "obresse.solutioneva.com:443" "obresse solutioneva.com"; do
  if is_plausible_host "$h"; then bad "accepts '$h'"; else pass "rejects '$h'"; fi
done

# ── base_domain ABSENT == the behaviour that shipped before the field existed ─────
echo "absent base_domain == pre-base_domain behaviour (the acceptance property):"
# slug|domain|domain_mode  — '' is an absent domain_mode.
legacy_cases=(
  "demo|demo.sofrapiwas.com|subdomain"
  "demo|demo.sofrapiwas.com|"
  "smoke|smoke.sofrapiwas.com|subdomain"
  "obresse|obresse.sofrapiwas.com|subdomain"
  "rumi|www.rumirestaurant.ch|byo"
  "rumi|www.rumirestaurant.ch|"
  "kebab|kebabhouse.ch|byo"
  "kebab|kebabhouse.ch|"
  "demo|other.sofrapiwas.com|subdomain"
  "demo|demo.sofrapiwas.com|byo"
  "demo|deep.demo.sofrapiwas.com|subdomain"
  "demo|demo.sofrapiwas.com|SUBDOMAIN"
  "demo|demo.sofrapiwas.com|wildcard"
  "demo|Demo.Example.COM|byo"
  "demo|demo.example.com.|byo"
  "demo|https://demo.example.com|byo"
  "demo|localhost|byo"
  "demo|localhost|"
)
for case_ in "${legacy_cases[@]}"; do
  IFS='|' read -r c_slug c_domain c_mode <<< "$case_"
  want_rc=0; want_out=""
  want_out="$(legacy_domain_mode "$c_slug" "$c_domain" "$c_mode")" || want_rc=$?
  run_resolve "$c_slug" "$c_domain" "$c_mode" ""
  if [[ "$RC" -eq 0 && "$want_rc" -eq 0 && "$OUT" == "$want_out" ]]; then
    pass "same verdict (accept '$want_out'): ${c_slug} ${c_domain} mode='${c_mode}'"
  elif [[ "$RC" -ne 0 && "$want_rc" -ne 0 ]]; then
    pass "same verdict (refuse): ${c_slug} ${c_domain} mode='${c_mode}'"
  else
    bad "DIVERGED from pre-base_domain behaviour: ${c_slug} ${c_domain} mode='${c_mode}' — old rc=$want_rc out='$want_out', new rc=$RC out='$OUT'"
  fi
done

# ── The committed registry, entry by entry ───────────────────────────────────────
# The strongest form of the same property: every tenant actually in the file must
# still resolve, and must resolve to what the OLD code said. Reading the real registry
# (rather than a fixture) is the point — a change that would refuse a live tenant fails
# here rather than on the box.
echo "every entry in tenants/registry.yml:"
python3 -c 'import yaml' 2>/dev/null \
  || { echo "  FAIL python3 PyYAML missing — provision-tenant.sh requires it on the box too"; exit 1; }
while IFS='|' read -r r_slug r_domain r_mode r_base; do
  [[ -n "$r_slug" ]] || continue
  run_resolve "$r_slug" "$r_domain" "$r_mode" "$r_base"
  if [[ "$RC" -ne 0 ]]; then
    bad "committed entry '$r_slug' ($r_domain) is REFUSED: ${ERR%%$'\n'*}"
    continue
  fi
  if [[ -z "$r_base" ]]; then
    want_rc=0; want_out="$(legacy_domain_mode "$r_slug" "$r_domain" "$r_mode")" || want_rc=$?
    if [[ "$want_rc" -eq 0 && "$want_out" == "$OUT" ]]; then
      pass "committed entry '$r_slug' ($r_domain) -> $OUT, unchanged from before base_domain"
    else
      bad "committed entry '$r_slug' changed meaning: old rc=$want_rc out='$want_out', new '$OUT'"
    fi
  else
    pass "committed entry '$r_slug' ($r_domain) -> $OUT under base_domain '$r_base'"
  fi
done < <(python3 - "$REGISTRY" <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    reg = yaml.safe_load(f) or {}
for slug, t in sorted((reg.get("tenants") or {}).items()):
    t = t or {}
    print("|".join(str(t.get(k, "") or "") for k in ("domain", "domain_mode", "base_domain")).join((slug + "|", "")))
PY
)

# ── The new field ────────────────────────────────────────────────────────────────
echo "base_domain, present:"
expect_mode "partner zone: obresse.solutioneva.com" subdomain \
  obresse obresse.solutioneva.com subdomain solutioneva.com
expect_mode "partner zone, domain_mode inferred" subdomain \
  obresse obresse.solutioneva.com "" solutioneva.com
expect_mode "an explicit base_domain of OUR domain is the default, spelled out" subdomain \
  demo demo.sofrapiwas.com subdomain sofrapiwas.com
expect_reject "the host must be the SLUG under the base, not any label" "expects domain 'obresse.solutioneva.com'" \
  obresse clients.solutioneva.com subdomain solutioneva.com
expect_reject "no extra label under the base either" "expects domain 'obresse.solutioneva.com'" \
  obresse obresse.clients.solutioneva.com subdomain solutioneva.com
expect_reject "a base_domain that does not match the domain at all" "base_domain: solutioneva.com" \
  obresse obresse.sofrapiwas.com subdomain solutioneva.com

echo "base_domain, malformed (never a silent default):"
expect_reject "with a scheme"        "has base_domain 'https://solutioneva.com'" obresse obresse.solutioneva.com subdomain "https://solutioneva.com"
expect_reject "uppercase"            "has base_domain 'SolutionEva.com'"         obresse obresse.solutioneva.com subdomain "SolutionEva.com"
expect_reject "trailing dot"         "has base_domain 'solutioneva.com.'"        obresse obresse.solutioneva.com subdomain "solutioneva.com."
expect_reject "leading dot"          "has base_domain '.solutioneva.com'"        obresse obresse.solutioneva.com subdomain ".solutioneva.com"
expect_reject "no dot at all"        "has base_domain 'solutioneva'"             obresse obresse.solutioneva   subdomain "solutioneva"
expect_reject "a path"               "has base_domain 'solutioneva.com/x'"       obresse obresse.solutioneva.com subdomain "solutioneva.com/x"
expect_reject "whitespace"           "expected a bare dotted hostname"           obresse obresse.solutioneva.com subdomain "solutioneva .com"

echo "byo + base_domain is a contradiction, not a shrug:"
expect_reject "refused loudly"       "those contradict" rumi www.rumirestaurant.ch byo solutioneva.com
expect_reject "and says which to drop" "drop base_domain, or set domain_mode: subdomain" \
  rumi www.rumirestaurant.ch byo solutioneva.com

echo "byo still refuses a host under OUR base:"
expect_reject "byo pointing at sofrapiwas.com" "rides the wildcard" demo demo.sofrapiwas.com byo ""
expect_mode   "byo with a real tenant domain"  byo rumi www.rumirestaurant.ch byo ""

echo "unknown domain_mode:"
expect_reject "typo'd mode"        "allowed: subdomain | byo" demo demo.sofrapiwas.com subdomian ""
expect_reject "typo'd mode + base" "allowed: subdomain | byo" demo demo.solutioneva.com subdomian solutioneva.com

# ── The DNS diagnostic ───────────────────────────────────────────────────────────
# The failure this slice exists to make survivable: a partner base domain has no
# wildcard, so a missing A record is the likely outcome and its symptom (a built tenant
# with no certificate) looks like a broken product. The message must therefore name the
# record — not the problem.
echo "dns_record_advice:"
advice="$(dns_record_advice obresse.solutioneva.com solutioneva.com 159.195.34.105)"
for needle in "PARTNER BASE DOMAIN 'solutioneva.com'" "NO wildcard" "name  : obresse" \
              "type  : A" "value : 159.195.34.105" "TTL   : 7200" "obresse.solutioneva.com" \
              "certificate"; do
  if [[ "$advice" == *"$needle"* ]]; then pass "partner advice names: $needle"
  else bad "partner advice is missing '$needle'"; fi
done

advice="$(dns_record_advice demo.sofrapiwas.com sofrapiwas.com 159.195.34.105)"
if [[ "$advice" == *"wildcard A record"* && "$advice" != *"type  : A"* ]]; then
  pass "our own base: points at the wildcard, asks for no per-tenant record"
else bad "our own base advice changed shape: $advice"; fi

advice="$(dns_record_advice www.rumirestaurant.ch sofrapiwas.com 159.195.137.101)"
for needle in "name  : www.rumirestaurant.ch" "type  : A" "value : 159.195.137.101"; do
  if [[ "$advice" == *"$needle"* ]]; then pass "byo advice names: $needle"
  else bad "byo advice is missing '$needle'"; fi
done

# An alias need not sit under the tenant's base, and must not be told it rides a
# wildcard that does not cover it.
advice="$(dns_record_advice www.obresse.fr solutioneva.com 159.195.34.105)"
if [[ "$advice" == *"name  : www.obresse.fr"* && "$advice" != *"wildcard"* ]]; then
  pass "an alias outside the base gets its own record, not the wildcard line"
else bad "alias advice is wrong: $advice"; fi

# ── The guard that must never weaken ─────────────────────────────────────────────
# RUMI is tenant 1 of a live business and is managed:legacy; both scripts refuse to
# touch it (ADR-006). Nothing in this slice goes near that, which is exactly why it is
# worth a canary: a refactor of the preflight is how such a guard disappears.
echo "managed:legacy guard (ADR-006):"
for s in provision-tenant.sh deprovision-tenant.sh; do
  if grep -q '\[\[ "$REG_MANAGED" == "scripts" \]\]' "$HERE/../$s"; then pass "$s still refuses a non-scripts tenant"
  else bad "$s lost its managed:scripts guard"; fi
done
if grep -qE '^\s+managed: legacy' "$REGISTRY"; then pass "the registry still marks a tenant managed: legacy"
else bad "no managed: legacy entry left in the registry — did tenant 1 change?"; fi

[[ "$fail" -eq 0 ]] || { echo "FAILED"; exit 1; }
echo "all domain/base_domain checks passed"
