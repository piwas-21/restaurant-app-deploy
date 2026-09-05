#!/usr/bin/env bash
# Unit test for provision-tenant.sh's `payments_link_url` contract
# (Stripe Connect EXPRESS — the restaurant's own onboarding page).
#
# WHY this exists, and it is one specific failure. The value is a FINISHED absolute URL
# whose last path segment is a 32-byte bearer token over one restaurant's Stripe
# onboarding. The control plane composes it; this script must COPY it and never assemble
# it. An implementation that concatenated a base URL here would be able to get the ORIGIN
# wrong per environment, and the symptom of that is not an error — it is a link that
# works and points at the wrong site.
#
# The property a naive "only write it when present" implementation gets wrong is REMOVAL.
# A tenant whose Stripe account is unset in the registry must not keep an old onboarding
# link sitting in its .env while the provision reports success. That is the same failure
# tests/partner-attribution.sh was written for, on a value that is a credential.
#
# The functions are EXTRACTED from provision-tenant.sh rather than copied, for the reason
# tests/admin-password.sh gives: a copy is a second source of truth that passes forever
# after the original changes.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../provision-tenant.sh"
[[ -f "$SCRIPT" ]] || { echo "cannot find provision-tenant.sh next to $HERE"; exit 1; }

FNS="$(mktemp)"; WORK="$(mktemp -d)"
trap 'rm -rf "$FNS" "$WORK"' EXIT

sed -n '/^sed_escape() {/,/^}/p'   "$SCRIPT" >  "$FNS"
sed -n '/^set_env_line() {/,/^}/p' "$SCRIPT" >> "$FNS"
for fn in sed_escape set_env_line; do
  grep -q "^${fn}() {" "$FNS" || { echo "extraction failed for ${fn} — did it move?"; exit 1; }
done
# shellcheck disable=SC1090
source "$FNS"

fail=0
pass() { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; fail=1; }

LINK="https://sofrapiwas.com/onboarding/payments/DZ2p0mVQ0RmTESTTOKENnotreal"

# --- 1. the registry key is actually extracted -------------------------------------
# provision-tenant.sh reads a FIXED TUPLE; a key missing from it is silently ignored and
# the env line would render empty forever, with a green provision. Assert the key is in
# the tuple, with a positive control on a sibling key so an empty grep cannot pass.
if grep -q '"payments_link_url"' "$SCRIPT"; then
  pass "payments_link_url is in the registry extraction tuple"
else
  bad  "payments_link_url is NOT extracted — the env line would render empty forever"
fi
grep -q '"stripe_account"' "$SCRIPT" \
  || bad "POSITIVE CONTROL FAILED: stripe_account not found either — the grep is broken, not the code"

# --- 2. it is copied, never assembled ----------------------------------------------
# The box must not learn that part of the value is a credential, and must not be able to
# choose an origin. Assert the env line renders the variable alone.
if grep -qE '^set_env_line STRIPE_PAYMENTS_LINK_URL "\$\{REG_PAYMENTS_LINK_URL:-\}"$' "$SCRIPT"; then
  pass "the link is copied verbatim from the registry, not assembled"
else
  bad  "STRIPE_PAYMENTS_LINK_URL is not a verbatim copy of REG_PAYMENTS_LINK_URL"
fi

# --- 3. writing, on a real .env, through the real set_env_line ----------------------
# set_env_line writes to "$TENANT_DIR/.env" — point it at a temp dir, do not reimplement it.
TENANT_DIR="$WORK"
ENVF="$TENANT_DIR/.env"
printf 'FOO=bar\n' > "$ENVF"
REG_PAYMENTS_LINK_URL="$LINK"
set_env_line STRIPE_PAYMENTS_LINK_URL "${REG_PAYMENTS_LINK_URL:-}"
if grep -qF "STRIPE_PAYMENTS_LINK_URL=$LINK" "$ENVF"; then
  pass "a tenant with a link gets it written to its .env"
else
  bad  "the link was not written to the .env"
fi

# --- 4. REMOVAL — the direction that matters ---------------------------------------
# The tenant above now has a stale link. Re-provision it with NO link in the registry.
REG_PAYMENTS_LINK_URL=""
set_env_line STRIPE_PAYMENTS_LINK_URL "${REG_PAYMENTS_LINK_URL:-}"
if grep -qF "STRIPE_PAYMENTS_LINK_URL=$LINK" "$ENVF"; then
  bad  "a removed link SURVIVED in the .env — a dead onboarding token stays live on the box"
else
  pass "removing the link from the registry empties it in the .env"
fi
# The line must still EXIST (empty), not vanish: the backend reports empty as null, and a
# missing key and an empty key must not be two different stories.
grep -q '^STRIPE_PAYMENTS_LINK_URL=' "$ENVF" \
  && pass "the key remains present-but-empty rather than disappearing" \
  || bad  "the key vanished entirely instead of being emptied"

# --- 5. the untouched neighbour ----------------------------------------------------
grep -q '^FOO=bar$' "$ENVF" && pass "unrelated .env lines are untouched" \
  || bad "set_env_line disturbed an unrelated line"

echo
[[ $fail -eq 0 ]] && echo "payments-link-url: all assertions passed" || echo "payments-link-url: FAILURES"
exit $fail
