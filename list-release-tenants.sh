#!/usr/bin/env bash
# Which tenants must have their FRONTEND image REBUILT when the frontend releases?
#
# Prints a JSON plan on stdout; human notes on stderr. Reads the registry, touches
# nothing, and is safe to run anywhere (it is a pure read plus DNS lookups).
#
#   ./list-release-tenants.sh [path/to/registry.yml]
#
# ── Why this exists ──────────────────────────────────────────────────────────────
# The BACKEND already had this chain: backend `build-image` on main -> backend
# `refresh-tenants.yml` -> `refresh-tenant-images.sh backend latest` on the box. The
# FRONTEND never did, and could not use the same shape, because a frontend tenant image
# is not re-pullable: NEXT_PUBLIC_* are baked into the bundle at BUILD time, so every
# tenant needs its OWN rebuild of the released source before anything can be rolled.
# `build-tenant-image.yml` was therefore dispatched only by
# `provision-on-registry-merge.yml`, which does FIRST PROVISIONING ONLY by its own
# header — so a self-serve tenant was built once, on the day it was created, and never
# again.
#
# Measured 2026-08-30, with each host's own `GET /api/frontend/version`: frontend `main`
# was fa978f99; www.rumirestaurant.ch served fa978f9 (RUMI is the prod stack, rolled by
# the frontend repo's deploy.yml) and demo.sofrapiwas.com served develop-tip (rebuilt by
# build-demo-tenant.yml on every develop push) — while kebabdilhan.sofrapiwas.com served
# 9de1f87c, the PREVIOUS release, and obresse served cd395d7, ELEVEN DAYS old. The two
# real reseller tenants were the only two with no builder at all. The registry was
# correct throughout; the trigger was absent. That is the same sentence
# refresh-tenant-images.sh's own header writes about the backend side of this.
#
# ── The selection, and why each rule is the rule ──────────────────────────────────
# ELIGIBLE = a tenant this release must reach. All four must hold:
#   managed == scripts   legacy (tenant 1, RUMI) is excluded here as everywhere else,
#                        ADR-006. It rides the shared :latest tag and the prod compose
#                        project; deploy.yml already rolls it.
#   status  == active    `retired` is owed nothing. `provisioning` belongs to
#                        provision-on-registry-merge.yml, which is standing that tenant
#                        up right now with its own image build; two builders racing on
#                        one tag is how a half-provisioned tenant gets an image nobody
#                        can attribute.
#   backend_tag == latest
#                        This is the RELEASE-TRACKING test and it needs its sentence.
#                        `:latest` is published from main only, so a tenant pinned to it
#                        has asked for RELEASED code — and released frontend is what this
#                        chain ships. A tenant on a develop tag (`demo`, backend_tag:
#                        staging) is a develop SHOWCASE whose frontend is already owned by
#                        build-demo-tenant.yml; rebuilding it from main would be a
#                        DOWNGRADE, and would put a main bundle in front of a develop API.
#                        A tenant pinned to an immutable `sha-…` was pinned deliberately.
#                        Deriving this from an existing field rather than adding a new
#                        `frontend_track:` one is on purpose: a new field has a default,
#                        and a default is what somebody forgets. Every entry the control
#                        plane generates already carries `backend_tag: latest`, so a
#                        tenant created tomorrow is covered on the day it exists.
#   domain resolves      THE GUARD. See below — it is the one rule that is not about
#                        housekeeping.
#
# ── The DNS guard: a rebuild is NOT a safe no-op ──────────────────────────────────
# `refresh-tenant-images.sh` re-pulls an image somebody else built. THIS chain BAKES a
# new one, and what it bakes is the registry's `domain` as NEXT_PUBLIC_API_URL /
# NEXT_PUBLIC_IMAGE_BASE_URL. So if the registry names a host that does not exist, a
# refresh does not leave the tenant where it was — it replaces a working bundle with one
# whose every API call, every image and every fetch dies, on a host for which ACME can
# never issue a certificate either.
#
# That is not hypothetical. obresse was moved onto the partner's own zone on 2026-08-21
# (`domain: obresse.solutioneva.com`, §D1, the first real use of `base_domain`), the
# partner has never published the A record, and the box is still serving that tenant on
# its pre-move alias obresse.sofrapiwas.com — verified 2026-08-30 by its own baked CSP,
# `connect-src … https://obresse.sofrapiwas.com`. It is stale and it is WORKING. An
# automation that "helpfully" refreshed it would have killed a paying partner's client.
#
# So: an unresolvable `domain` REFUSES that tenant. It does not skip it quietly, and it
# does not fall back to a hostname that happens to answer — a registry that disagrees
# with the running bundle about the ORIGIN is a provisioning decision for a human, not a
# refresh. The caller is expected to turn a non-empty `refused` list into a red run.
#
# ── Acknowledging a block, so the alarm keeps meaning something ───────────────────
# A refusal that is already known, already decided and cannot be fixed by anyone reading
# the run would make every frontend release red until a third party acts, and an alarm
# that is red for weeks is not an alarm. So a registry entry may carry
#
#     frontend_refresh_blocked: "<date> — why, and what unblocks it"
#
# Its PRESENCE downgrades that tenant's refusal to a warning: still listed, still
# printed, never silent, but not a failure. Its ABSENCE is what re-arms the alarm — so
# the fix for a blocked tenant is to delete the key, and forgetting to delete it is the
# only way to stay quiet. There is deliberately no boolean and no `false`: the value is
# the reason, and an entry that cannot say why it is blocked is not acknowledged.
#
# Everything below is grammar-gated at this seam for the reason
# provision-on-registry-merge.yml gives at the same seam: these values become arguments
# to a workflow dispatch that splices them into a NEWLINE-DELIMITED build-args list, so a
# control character in a free-text `name` from a public signup form could inject a second
# build arg into a tenant's bundle.
set -euo pipefail
cd "$(dirname "$0")"

REGISTRY="${1:-tenants/registry.yml}"
[[ -f "$REGISTRY" ]] || { echo "ERROR: registry not found: $REGISTRY" >&2; exit 1; }
python3 -c 'import yaml' 2>/dev/null || { echo "ERROR: python3 PyYAML missing" >&2; exit 1; }

# Test seam, and the only one. When set, hostnames are resolved against this
# space-separated allowlist instead of against real DNS, so tests/list-release-tenants.sh
# can assert the guard's BEHAVIOUR without depending on the state of the public DNS on
# the day it runs — including the day the obresse A record finally appears. Never set in
# CI or on a box; the workflow does not pass it.
FAKE_DNS="${LIST_RELEASE_TENANTS_FAKE_DNS-}"

export REGISTRY FAKE_DNS
python3 <<'PY'
import json, os, re, socket, sys

registry = os.environ["REGISTRY"]
fake = os.environ.get("FAKE_DNS", "")
use_fake = "LIST_RELEASE_TENANTS_FAKE_DNS" in os.environ
fake_hosts = set(fake.split())

import yaml

# fullmatch and no trailing `$`, for the reason provision-on-registry-merge.yml spells
# out: Python's `$` also matches just before a trailing newline, so a re.match with `$`
# accepts "demo\n".
def ok(pattern, value):
    return bool(re.fullmatch(pattern, value or ""))

SLUG = r"[a-z0-9][a-z0-9-]{1,30}"
HOST = r"[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+"
TAG = r"[A-Za-z0-9][A-Za-z0-9._-]{0,62}"
CTRL = re.compile(r"[\x00-\x1f\x7f]")
# Language, optional script, optional region — deliberately NARROWER than BCP-47. This
# gate exists to catch the typo (`fr_FR`, `french`, `FR-fr`) before a ~20-minute tenant
# image build, not to be an authority on locale tags: build-tenant-image.yml validates
# the same value canonically with Intl.getCanonicalLocales, which is the real check.
LOCALE = r"[a-z]{2,3}(-[A-Z][a-z]{3})?(-([A-Z]{2}|[0-9]{3}))?"

# Tags this chain must never publish to. `latest` is the PROD frontend tag the RUMI box
# pins; `staging` is the develop tag. Building a tenant-domain bundle onto either would
# put one restaurant's baked origin in front of another stack — the worst outcome this
# file can produce, so it is a refusal rather than a skip even though `managed: scripts`
# already makes it unreachable today.
FORBIDDEN_TAGS = {"latest", "staging"}


def resolves(host):
    if use_fake:
        return host in fake_hosts
    try:
        socket.getaddrinfo(host, None)
        return True
    except socket.gaierror:
        return False


with open(registry) as f:
    reg = yaml.safe_load(f) or {}

eligible, excluded, refused = [], [], []


def skip(slug, why):
    excluded.append({"slug": slug, "reason": why})


def refuse(slug, why, acknowledged=None):
    refused.append({"slug": slug, "reason": why, "acknowledged": acknowledged})


for slug, t in sorted((reg.get("tenants") or {}).items()):
    t = t or {}
    slug = str(slug)
    if t.get("managed") != "scripts":
        skip(slug, f"managed: {t.get('managed')} — not stamped out by the scripts (ADR-006)")
        continue
    status = str(t.get("status") or "")
    if status != "active":
        skip(slug, f"status: {status or '(absent)'} — only `active` tenants are refreshed")
        continue
    backend_tag = str(t.get("backend_tag") or "")
    if backend_tag != "latest":
        skip(slug, f"backend_tag: {backend_tag or '(absent)'} — not release-tracking; "
                   "a develop showcase is rebuilt by build-demo-tenant.yml and a pinned "
                   "tenant is pinned on purpose")
        continue

    blocked = t.get("frontend_refresh_blocked")
    blocked = str(blocked) if blocked else None

    name = str(t.get("name") or "")
    base_domain = str(t.get("base_domain") or "sofrapiwas.com")
    domain = str(t.get("domain") or f"{slug}.{base_domain}")
    template = str(t.get("template") or "classic")
    currency = str(t.get("currency") or "CHF")
    # Absent -> `de-CH`, the same fallback src/lib/config.ts and build-tenant-image.yml
    # already apply, so emitting it for EVERY tenant changes no existing build: the
    # Swiss tenants were getting de-CH before this field existed and still do. It is the
    # EUR tenants that need it said out loud — de-CH renders `EUR 8.00`, fr-FR `8,00 €`.
    # Paired with `currency:` and never derived from it: EUR is spoken in fr-FR, nl-NL
    # and de-DE, which place and punctuate the same amount three different ways.
    locale = str(t.get("locale") or "de-CH")
    pwa_theme_color = str(t.get("pwa_theme_color") or "")
    pwa_background_color = str(t.get("pwa_background_color") or "")
    image_tag = str(t.get("frontend_tag") or f"tenant-{slug}")
    box = str(t.get("box") or "")

    grammar = None
    if not ok(SLUG, slug):
        grammar = "slug fails the registry grammar"
    elif CTRL.search(name) or len(name) > 200:
        grammar = "name holds a control character or is over 200 chars"
    elif not ok(HOST, domain):
        grammar = f"domain '{domain}' is not a plausible hostname"
    elif template not in ("classic", "craft"):
        grammar = f"template '{template}' is not classic|craft"
    elif not ok(r"[A-Z]{3}", currency):
        grammar = f"currency '{currency}' is not a 3-letter ISO 4217 code"
    elif not ok(LOCALE, locale):
        grammar = f"locale '{locale}' is not a BCP-47 tag like de-CH or fr-FR"
    elif not ok(TAG, image_tag):
        grammar = f"frontend_tag '{image_tag}' is not a usable image tag"
    elif image_tag in FORBIDDEN_TAGS:
        grammar = (f"frontend_tag '{image_tag}' is a SHARED stack tag — building a "
                   "tenant-domain bundle onto it would re-point another stack's image")
    elif box not in ("prod", "staging"):
        grammar = f"box '{box}' is neither prod nor staging"
    else:
        for key, value in (("pwa_theme_color", pwa_theme_color),
                           ("pwa_background_color", pwa_background_color)):
            if value and not ok(r"#[0-9a-fA-F]{6}", value):
                grammar = f"{key} '{value}' is not #rrggbb"
                break

    if grammar:
        refuse(slug, grammar, blocked)
        continue

    if not resolves(domain):
        refuse(slug,
               f"domain '{domain}' does not resolve — a rebuild BAKES it as the bundle's "
               "origin, so refreshing would replace a working tenant with a dead one",
               blocked)
        continue

    eligible.append({
        "slug": slug, "domain": domain, "name": name, "template": template,
        "currency": currency, "locale": locale, "image_tag": image_tag, "box": box,
        "pwa_theme_color": pwa_theme_color,
        "pwa_background_color": pwa_background_color,
    })

plan = {
    "eligible": eligible,
    "excluded": excluded,
    # Split so the caller can be red about one and merely loud about the other, without
    # re-deriving the rule. `unacknowledged` non-empty MUST fail the run.
    "refused_unacknowledged": [r for r in refused if not r["acknowledged"]],
    "refused_acknowledged": [r for r in refused if r["acknowledged"]],
}
json.dump(plan, sys.stdout, indent=2)
sys.stdout.write("\n")

def note(line):
    print(line, file=sys.stderr)

note(f"eligible for a frontend release refresh: {[e['slug'] for e in eligible] or 'none'}")
for e in excluded:
    note(f"  skip   {e['slug']}: {e['reason']}")
for r in plan["refused_acknowledged"]:
    note(f"  BLOCKED (acknowledged) {r['slug']}: {r['reason']}")
    note(f"           frontend_refresh_blocked: {r['acknowledged']}")
for r in plan["refused_unacknowledged"]:
    note(f"  REFUSED {r['slug']}: {r['reason']}")
PY
