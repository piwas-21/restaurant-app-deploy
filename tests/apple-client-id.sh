#!/usr/bin/env bash
# Unit test for the Sign in with Apple client id the boxes serve to the backend.
#
# WHY this exists. Backend #406 made POST /api/Auth/apple-login VERIFY the identity token
# instead of decoding it, and it fails CLOSED: `appsettings.json` ships
# `Authentication:Apple:ClientIds: []`, so a deployment that configures nothing refuses every
# Apple login with 503 AppleLoginUnavailable. The whole of the configuration lives in THIS
# repo, and its correctness depends on two contracts that live in other repos and that no
# linter here can see:
#
#   1. the KEY name and its fail-closed semantics — the backend's AppleAuthSettings
#      (`Authentication:Apple:ClientIds`, bound from `Authentication__Apple__ClientIds__0`);
#   2. the VALUE — `expo.ios.bundleIdentifier` in rumi-mobile/app.json, which is the `aud`
#      Apple mints into every identity token the app sends.
#
# That is precisely the shape ci.yml's header describes: a rule enforced in another repo's
# source, whose only other detector is a customer whose login stopped working. The failure is
# silent on the box — the backend starts, /api/health is 200, and only the Apple button is
# dead — so it is worth freezing here.
#
# The deploy.sh guard is EXTRACTED between its markers rather than copied, for the reason
# tests/admin-password.sh gives: a copy is a second source of truth that passes forever after
# the original changes.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE="$HERE/../docker-compose.prod.yml"
DEPLOY="$HERE/../deploy.sh"
TENANT_TPL="$HERE/../tenants/templates/docker-compose.tenant.yml.tpl"
for f in "$COMPOSE" "$DEPLOY" "$TENANT_TPL"; do
  [[ -f "$f" ]] || { echo "cannot find $(basename "$f") next to $HERE"; exit 1; }
done

# The value under test, frozen. Read from rumi-mobile/app.json on 2026-08-24
# (expo.ios.bundleIdentifier, and expo.android.package agrees). If the app ever re-bundles,
# this line and the compose default change together — which is the point of asserting it.
BUNDLE_ID="com.rumirestaurant.app"

fail=0
pass() { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; fail=1; }

# ── The compose wiring ───────────────────────────────────────────────────────────
echo "docker-compose.prod.yml (both boxes run this file):"

# Slot 0 must exist, and its DEFAULT must be the bundle id — not empty. Every other optional
# backend setting in this file defaults empty/false on purpose; this one cannot, because
# "unset" is the broken state rather than the neutral one.
if grep -qE '^\s+Authentication__Apple__ClientIds__0: "\$\{APPLE_IOS_BUNDLE_ID:-'"$BUNDLE_ID"'\}"$' "$COMPOSE"; then
  pass "ClientIds__0 defaults to $BUNDLE_ID (a box needs no .env line)"
else
  bad "ClientIds__0 is missing, or no longer defaults to $BUNDLE_ID — Apple login would 503 on a box with no override"
fi

# It has to be on the BACKEND service; anywhere else it is inert and invisible.
if awk '/^  backend:/{b=1;next} /^  [a-z]/{b=0} b' "$COMPOSE" | grep -q 'Authentication__Apple__ClientIds__0'; then
  pass "the key sits in the backend service block"
else
  bad "the key is not inside the backend service — it would never reach the app"
fi

# Slot 1 is wired empty for the web Service ID. Blank entries are dropped by
# AppleAuthSettings.AllClientIds(), so this is inert until someone sets it.
if grep -qE '^\s+Authentication__Apple__ClientIds__1: "\$\{APPLE_WEB_SERVICE_ID:-\}"$' "$COMPOSE"; then
  pass "ClientIds__1 is reserved for the web Service ID and defaults empty"
else
  bad "ClientIds__1 slot is gone — adding the website would need a release of this repo"
fi

# ── The .env templates ───────────────────────────────────────────────────────────
# A bundle id is PUBLIC (it ships inside the app binary), so it is tracked config, not a
# secret: it must NOT appear in app-secrets*.json. The templates document the override and
# leave it commented out — the compose default is the one source of truth for the value.
echo ".env templates (prod + staging take the same value):"
for env_tpl in "$HERE/../.env.example" "$HERE/../.env.staging.example"; do
  name="$(basename "$env_tpl")"
  if grep -q 'APPLE_IOS_BUNDLE_ID' "$env_tpl"; then pass "$name documents the override"
  else bad "$name says nothing about Apple sign-in"; fi
  if grep -qE '^[[:space:]]*APPLE_IOS_BUNDLE_ID=' "$env_tpl"; then
    bad "$name sets APPLE_IOS_BUNDLE_ID uncommented — the value would live in two places"
  else
    pass "$name leaves the override commented out"
  fi
done
for secrets_tpl in "$HERE/../app-secrets.example.json" "$HERE/../app-secrets.staging.example.json"; do
  if grep -qi 'apple' "$secrets_tpl"; then
    bad "$(basename "$secrets_tpl") carries an Apple entry — a public bundle id does not belong in the secret store"
  else
    pass "$(basename "$secrets_tpl") stays free of Apple config"
  fi
done

# ── Per-tenant stacks deliberately have no such key ──────────────────────────────
# The bundle id is RUMI's own app. A provisioned tenant has no mobile app at all, and giving
# its backend RUMI's `aud` would make it accept identity tokens minted for a different
# product. Absent == refuses, which is the correct answer there.
echo "per-tenant template:"
if grep -q 'Authentication__Apple' "$TENANT_TPL"; then
  bad "the tenant template forwards an Apple client id — a tenant would accept RUMI's app tokens"
else
  pass "no Apple client id reaches a provisioned tenant (absent = refuse, correct)"
fi

# ── The deploy.sh preflight guard ────────────────────────────────────────────────
# It reads the RESOLVED config, not .env, and the reason is measured below: compose's `:-`
# substitutes the default on an EMPTY variable as well as on an unset one, so an
# `APPLE_IOS_BUNDLE_ID=` line cannot empty the value and grepping .env for one would catch nothing.
# The failure that IS reachable is a box running an older docker-compose.prod.yml — a release
# of this repo that was never rsynced — where the key is simply absent.
echo "deploy.sh preflight guard:"
FNS="$(mktemp)"; FIX="$(mktemp -d)"
trap 'rm -rf "$FNS" "$FIX"' EXIT
sed -n '/^# --- BEGIN apple client id guard/,/^# --- END apple client id guard/p' "$DEPLOY" > "$FNS"
grep -q '^apple_client_id_warning() {' "$FNS" || { echo "extraction failed — did the markers move?"; exit 1; }
# shellcheck disable=SC1090
source "$FNS"

# Fixtures shaped like `docker compose config` output.
printf '    environment:\n      Authentication__Apple__ClientIds__0: %s\n' "$BUNDLE_ID" > "$FIX/good.yml"
printf '    environment:\n      Authentication__Apple__ClientIds__0: ""\n'                > "$FIX/empty.yml"
printf '    environment:\n      Authentication__Apple__ClientIds__0: "   "\n'             > "$FIX/blank.yml"
printf '    environment:\n      SENTRY_DSN: ""\n'                                         > "$FIX/stale.yml"

out="$(apple_client_id_warning "$FIX/good.yml")"
if [[ -z "$out" ]]; then pass "a wired stack produces no noise"
else bad "false alarm on a wired stack: '$out'"; fi
for f in stale empty blank; do
  out="$(apple_client_id_warning "$FIX/$f.yml")"
  if [[ "$out" == *"WARN"* && "$out" == *"503"* ]]; then pass "no resolved client id ($f) is reported, and the message names the symptom"
  else bad "no resolved client id ($f) went unreported: '$out'"; fi
done
# A grep that matches nothing must not take the DEPLOY down with it (set -o pipefail).
# shellcheck disable=SC1090
if ( set -euo pipefail; source "$FNS"; apple_client_id_warning "$FIX/stale.yml" >/dev/null ); then
  pass "a missing key warns instead of aborting a strict-mode deploy"
else
  bad "the guard exits non-zero on a missing key — deploy.sh would abort"
fi
# Nothing to read yet (compose config failed) must be silent, not a second error.
if out="$(apple_client_id_warning "$FIX/does-not-exist.yml")" && [[ -z "$out" ]]; then
  pass "an unreadable config is left to compose's own error"
else
  bad "the guard misbehaves when there is no resolved config"
fi
# The guard must actually be CALLED — an extracted-but-unused function passes this file and
# does nothing on a box.
if grep -qE '^\s*apple_client_id_warning "\$RESOLVED_CONFIG"' "$DEPLOY"; then pass "deploy.sh calls the guard on its own resolved config"
else bad "deploy.sh defines the guard but never calls it"; fi

# ── The property the guard depends on ────────────────────────────────────────────
# Measured on docker compose v2 (2026-08-24): `${VAR:-default}` substitutes the default when
# VAR is EMPTY as well as when it is unset. That is why an empty .env override is harmless and
# why the guard does not look for one. Asserted with bash's identical `:-`, so the day the
# compose default is rewritten to the `${VAR-default}` form (unset only) this line still holds
# but the compose grep above is what changes — keeping the two claims from drifting apart.
APPLE_IOS_BUNDLE_ID="" ; resolved="${APPLE_IOS_BUNDLE_ID:-$BUNDLE_ID}"
if [[ "$resolved" == "$BUNDLE_ID" ]]; then pass ":- falls back on an EMPTY override, not only an unset one"
else bad ":- semantics changed — an empty override would now blank the audience"; fi

[[ "$fail" -eq 0 ]] || { echo "FAILED"; exit 1; }
echo "all Apple client id checks passed"
