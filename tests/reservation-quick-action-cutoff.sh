#!/usr/bin/env bash
# Unit test for the reservation quick-action legacy cutoff the boxes serve to the backend.
#
# WHY this exists. Backend #410 signs the approve / reject links in the restaurant's
# new-booking alert mail: before it, the bare reservation id was the whole authorisation, and
# `POST /api/Reservations` is anonymous and returns that id to the guest who made the booking —
# so a guest could approve their own table (backend #402). To avoid killing the mails already
# in the restaurant's inbox, a token-LESS link is still honoured while its own booking is
# younger than `LegacyLinkGraceDays`. That window is anchored per booking, so on its own it
# also covers bookings made AFTER the release: #402 stays reachable for two more weeks unless
# the deployment names a cutoff. Naming it is this repo's job, and its correctness rests on
# three things no linter here can see:
#
#   1. the KEY names and their lazy binding — the backend's ReservationQuickActionSettings
#      (`ReservationQuickActions:LegacyLinkCutoffUtc` / `:LegacyLinkGraceDays`, bound from the
#      `__` env form by a plain Configure<T>(section), i.e. NOT validated at startup;
#   2. the VALUE — the instant the release image began serving on prod, which is a measurement
#      of a past event (backend PR #412) and not a round number somebody may "tidy up";
#   3. the .NET binder's behaviour on the edge values, measured on 2026-08-25 (see below).
#
# The failure is silent on the box in every direction: the stack is up, /api/health is 200, and
# the only witness is either a guest approving their own booking or a restaurant clicking a
# dead button in a mail it already received.
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

# The value under test, frozen. It is the instant the backend release began serving on prod:
# `docker inspect deploy-backend-1` StartedAt 2026-08-25T00:52:22.197507985Z, "Now listening on:
# http://[::]:8080" at 2026-08-25T00:52:24.772025841Z (backend PR #412, comment 5403547658),
# truncated DOWN to the whole second. Both directions are wrong: later and an id-only link still
# approves a fresh booking; earlier and the last mails the OLD image sent have dead buttons.
CUTOFF="2026-08-25T00:52:24Z"
# The backend's OWN default (appsettings.json: "LegacyLinkGraceDays": 14), mirrored here only so
# that closing the window later costs a box .env line instead of a release of this repo.
GRACE_DAYS="14"

fail=0
pass() { local desc="$1"; printf '  ok   %s\n' "$desc"; }
bad()  { local desc="$1"; printf '  FAIL %s\n' "$desc"; fail=1; }

# ── The compose wiring ───────────────────────────────────────────────────────────
echo "docker-compose.prod.yml (both boxes run this file):"

if grep -qE '^\s+ReservationQuickActions__LegacyLinkCutoffUtc: "\$\{RESERVATION_QUICK_ACTIONS_LEGACY_CUTOFF_UTC:-'"$CUTOFF"'\}"$' "$COMPOSE"; then
  pass "the cutoff defaults to $CUTOFF (a box needs no .env line)"
else
  bad "the cutoff is missing or no longer defaults to $CUTOFF — #402 would stay reachable for every new booking"
fi

if grep -qE '^\s+ReservationQuickActions__LegacyLinkGraceDays: "\$\{RESERVATION_QUICK_ACTIONS_LEGACY_GRACE_DAYS:-'"$GRACE_DAYS"'\}"$' "$COMPOSE"; then
  pass "the grace window is wired at the backend's own default ($GRACE_DAYS), so today it changes nothing"
else
  bad "the grace window is gone or no longer defaults to $GRACE_DAYS — retiring the legacy path would need a release"
fi

# Both keys have to be on the BACKEND service; anywhere else they are inert and invisible.
backend_block="$(awk '/^  backend:/{b=1;next} /^  [a-z]/{b=0} b' "$COMPOSE")"
for key in ReservationQuickActions__LegacyLinkCutoffUtc ReservationQuickActions__LegacyLinkGraceDays; do
  if grep -q "$key" <<<"$backend_block"; then pass "$key sits in the backend service block"
  else bad "$key is not inside the backend service — it would never reach the app"; fi
done

# ── The value itself ─────────────────────────────────────────────────────────────
echo "the cutoff value:"

# Keep the Z. Measured on the .NET invariant DateTime converter: with `Z` the value binds
# Kind=Local and ReservationQuickActionLinks.AsUtc() converts it back, so the instant is right
# whatever TZ the container runs in; without it the value binds Unspecified and is merely
# ASSUMED to be UTC. Both work today — the `Z` is what keeps that true if a box ever gets a TZ.
if [[ "$CUTOFF" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
  pass "it is a whole-second UTC instant ending in Z"
else
  bad "the cutoff is not the strict UTC shape the backend is fed elsewhere"
fi

# It is a record of something that already happened. A future instant would mean every booking
# made between now and then can still be approved with the id alone — #402, wide open, and the
# most plausible way this line rots is somebody "updating" it.
now_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [[ "$CUTOFF" < "$now_utc" ]]; then
  pass "it is in the PAST ($CUTOFF < $now_utc) — a measurement, not a plan"
else
  bad "the cutoff is in the future ($CUTOFF >= $now_utc) — every booking until then keeps the token-less path"
fi

# ── Not a secret, and not per-tenant ─────────────────────────────────────────────
# A timestamp is public by nature: it says when a release happened, which the git log says too.
echo "the secret templates:"
for secrets_tpl in "$HERE/../app-secrets.example.json" "$HERE/../app-secrets.staging.example.json"; do
  if grep -qi 'ReservationQuickActions' "$secrets_tpl"; then
    bad "$(basename "$secrets_tpl") carries the cutoff — a release timestamp is not a secret"
  else
    pass "$(basename "$secrets_tpl") stays free of it"
  fi
done

# A provisioned tenant's backend is refreshed on ITS own schedule (refresh-tenant-images.sh),
# so RUMI's release instant is the wrong cutoff there: it would refuse token-less links for
# bookings whose mail that tenant's OLD image sent after this instant. Absent = the per-booking
# window only, which still closes by itself.
echo "per-tenant template:"
if grep -q 'ReservationQuickActions' "$TENANT_TPL"; then
  bad "the tenant template carries a cutoff — RUMI's release instant is not a tenant's"
else
  pass "no cutoff reaches a provisioned tenant (its own image moves on its own schedule)"
fi

# ── The .env templates ───────────────────────────────────────────────────────────
echo ".env templates (prod + staging take the same value):"
for env_tpl in "$HERE/../.env.example" "$HERE/../.env.staging.example"; do
  name="$(basename "$env_tpl")"
  if grep -q 'RESERVATION_QUICK_ACTIONS_LEGACY_GRACE_DAYS' "$env_tpl"; then
    pass "$name documents the follow-up (grace days -> 0)"
  else
    bad "$name says nothing about retiring the legacy path"
  fi
  for var in RESERVATION_QUICK_ACTIONS_LEGACY_CUTOFF_UTC RESERVATION_QUICK_ACTIONS_LEGACY_GRACE_DAYS; do
    if grep -qE "^[[:space:]]*${var}=" "$env_tpl"; then
      bad "$name sets $var uncommented — the value would live in two places"
    else
      pass "$name leaves $var commented out"
    fi
  done
done

# ── The deploy.sh preflight guard ────────────────────────────────────────────────
echo "deploy.sh preflight guard:"
FNS="$(mktemp)"; FIX="$(mktemp -d)"
trap 'rm -rf "$FNS" "$FIX"' EXIT
sed -n '/^# --- BEGIN quick-action cutoff guard/,/^# --- END quick-action cutoff guard/p' "$DEPLOY" > "$FNS"
grep -q '^quick_action_cutoff_warning() {' "$FNS" || { echo "extraction failed — did the markers move?"; exit 1; }
# shellcheck disable=SC1090
source "$FNS"

# Fixtures shaped like `docker compose config` output — which quotes the value, as measured:
#   ReservationQuickActions__LegacyLinkCutoffUtc: "2026-08-25T00:52:24Z"
key="ReservationQuickActions__LegacyLinkCutoffUtc"
printf '    environment:\n      %s: "%s"\n' "$key" "$CUTOFF"                  > "$FIX/good.yml"
printf '    environment:\n      %s: %s\n'   "$key" "$CUTOFF"                  > "$FIX/unquoted.yml"
printf '    environment:\n      %s: "%s"\n' "$key" "2026-08-25 00:52:24Z"     > "$FIX/spaced.yml"
printf '    environment:\n      %s: ""\n'   "$key"                            > "$FIX/empty.yml"
printf '    environment:\n      %s: "   "\n' "$key"                           > "$FIX/blank.yml"
printf '    environment:\n      %s: "not-a-date"\n' "$key"                    > "$FIX/garbage.yml"
printf '    environment:\n      SENTRY_DSN: ""\n'                             > "$FIX/stale.yml"

for f in good unquoted spaced; do
  out="$(quick_action_cutoff_warning "$FIX/$f.yml")"
  if [[ -z "$out" ]]; then pass "a value the backend accepts ($f) produces no noise"
  else bad "false alarm on $f: '$out'"; fi
done

# Absent and empty are the SAME consequence — the binder maps "" to null, so the window runs
# unbounded and #402 is reachable for a booking made today.
for f in stale empty; do
  out="$(quick_action_cutoff_warning "$FIX/$f.yml")"
  if [[ "$out" == *"NO reservation quick-action cutoff"* && "$out" == *"#402"* ]]; then
    pass "no resolved cutoff ($f) is reported, and the message names the consequence"
  else bad "no resolved cutoff ($f) went unreported: '$out'"; fi
done

# Whitespace is the OPPOSITE failure and deserves its own words: it binds DateTime.MinValue,
# so every booking postdates the cutoff and every token-less link is refused.
out="$(quick_action_cutoff_warning "$FIX/blank.yml")"
if [[ "$out" == *"WHITESPACE"* && "$out" == *"MinValue"* ]]; then
  pass "a whitespace cutoff is called out as refusing EVERY legacy link"
else bad "a whitespace cutoff was not distinguished from an absent one: '$out'"; fi

out="$(quick_action_cutoff_warning "$FIX/garbage.yml")"
if [[ "$out" == *"not a parseable instant"* ]]; then
  pass "an unparseable cutoff is reported before a person meets the exception"
else bad "an unparseable cutoff went unreported: '$out'"; fi

# A grep that matches nothing must not take the DEPLOY down with it (set -o pipefail).
# shellcheck disable=SC1090
if ( set -euo pipefail; source "$FNS"; quick_action_cutoff_warning "$FIX/stale.yml" >/dev/null ); then
  pass "a missing key warns instead of aborting a strict-mode deploy"
else
  bad "the guard exits non-zero on a missing key — deploy.sh would abort"
fi

# Nothing to read yet (compose config failed) must be silent, not a second error.
if out="$(quick_action_cutoff_warning "$FIX/does-not-exist.yml")" && [[ -z "$out" ]]; then
  pass "an unreadable config is left to compose's own error"
else
  bad "the guard misbehaves when there is no resolved config"
fi

# An extracted-but-uncalled guard passes this file and does nothing on a box.
if grep -qE '^\s*quick_action_cutoff_warning "\$RESOLVED_CONFIG"' "$DEPLOY"; then
  pass "deploy.sh calls the guard on its own resolved config"
else
  bad "deploy.sh defines the guard but never calls it"
fi

# ── The property both defaults depend on ─────────────────────────────────────────
# Measured on docker compose v2 (2026-08-24, deploy #144): `${VAR:-default}` substitutes the
# default when VAR is EMPTY as well as when it is unset. That matters more for the INT than for
# the timestamp: an empty LegacyLinkGraceDays does not fall back to the C# default, it throws
# ("Failed to convert configuration value '' … to type 'System.Int32'") and takes the
# quick-action links with it. Asserted with bash's identical `:-`.
RESERVATION_QUICK_ACTIONS_LEGACY_GRACE_DAYS=""
if [[ "${RESERVATION_QUICK_ACTIONS_LEGACY_GRACE_DAYS:-$GRACE_DAYS}" == "$GRACE_DAYS" ]]; then
  pass ":- falls back on an EMPTY override, so a blank .env line cannot break the binder"
else
  bad ":- semantics changed — an empty override would now reach the .NET binder"
fi

[[ "$fail" -eq 0 ]] || { echo "FAILED"; exit 1; }
echo "all reservation quick-action cutoff checks passed"
