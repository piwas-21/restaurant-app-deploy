#!/usr/bin/env bash
# Stamp out (or idempotently re-apply) a tenant instance on THIS box — sofra
# ADR-001 (instance-per-tenant), ADR-003 (scripts-first provisioning),
# ADR-007 (registry-driven). Run ON THE BOX as the deploy user from
# /opt/rumi/deploy after the tenant is committed to tenants/registry.yml and
# synced here.
#
#   ./provision-tenant.sh <slug>
#
# What it does, in order:
#   1. preflight    — BOX_ROLE matches the registry entry; refuses managed:legacy
#   2. render       — /opt/rumi/tenants/<slug>/{.env,app-secrets.json,docker-compose.yml}
#                     (secrets are generated once and survive re-provision)
#   3. database     — tenant role + database on the shared postgres (idempotent)
#   4. containers   — pull + up the tenant compose project; wait for /api/health
#   5. caddy        — render caddy-tenants/<slug>.caddy + zero-downtime reload
#
# Prereqs (fail loudly if missing): DNS for the tenant domain points at this
# box (subdomain tenants ride the *.sofrapiwas.com wildcard); the per-tenant
# frontend image exists (frontend repo: build-tenant-image.yml).
#
# Teardown: ./deprovision-tenant.sh <slug> [--drop-db] [--purge]
set -euo pipefail
cd "$(dirname "$0")"

SLUG="${1:?usage: $0 <slug>   (a tenant key in tenants/registry.yml)}"
[[ "$SLUG" =~ ^[a-z0-9][a-z0-9-]{1,30}$ ]] || { echo "ERROR: slug must be lowercase [a-z0-9-], 2-31 chars" >&2; exit 2; }

REGISTRY="tenants/registry.yml"
TENANT_DIR="/opt/rumi/tenants/${SLUG}"
DEPLOY_COMPOSE="docker compose -f docker-compose.prod.yml"
BE_REPO="ghcr.io/piwas-21/restaurant-app-backend"

echo "==> Preflight"
[[ -f .env ]] || { echo "ERROR: box .env missing" >&2; exit 1; }
[[ -f "$REGISTRY" ]] || { echo "ERROR: $REGISTRY missing (push + sync the deploy repo first)" >&2; exit 1; }
python3 -c 'import yaml' 2>/dev/null || { echo "ERROR: python3-yaml missing (apt-get install -y python3-yaml)" >&2; exit 1; }

BOX_ROLE="$(grep -E '^BOX_ROLE=' .env | cut -d= -f2- || true)"
[[ -n "$BOX_ROLE" ]] || { echo "ERROR: BOX_ROLE not set in the box .env (prod|staging) — refusing to guess" >&2; exit 1; }

# Shared fleet-observability + error-tracking config, flowed from the box .env into every
# tenant .env below so a new tenant gets fleet telemetry + Sentry automatically. Both are
# SHARED (not per-tenant): one SENTRY_DSN / PRINTER_TELEMETRY_SECRET per box. Empty on the
# box => that tenant's telemetry stays inert (the backend pusher self-guards; Sentry no-ops).
BOX_SENTRY_DSN="$(grep -E '^SENTRY_DSN=' .env | cut -d= -f2- || true)"
BOX_TELEMETRY_SECRET="$(grep -E '^PRINTER_TELEMETRY_SECRET=' .env | cut -d= -f2- || true)"
# Same shape, same reasoning: ONE platform key per box, not per tenant. A Stripe restricted key
# cannot be scoped to a single connected account, so the key is narrowed by permission and by an
# Access policy pinning it to the box IPs (SOFRA-PAYMENTS-PLAN §4). Empty on the box => every
# tenant on it stays inert, because the backend gateway needs key AND account AND the module.
BOX_STRIPE_KEY="$(grep -E '^STRIPE_PLATFORM_API_KEY=' .env | cut -d= -f2- || true)"

# The Resend-verified domain every tenant on this box sends from (EMAIL-IDENTITY-PLAN).
# Quotes are stripped because .env is read by BOTH bash (which sources it) and this grep,
# so a value may legitimately be written `PLATFORM_MAIL_DOMAIN="send.sofrapiwas.com"`.
PLATFORM_MAIL_DOMAIN="$(grep -E '^PLATFORM_MAIL_DOMAIN=' .env | cut -d= -f2- | tr -d '"'"'"'' || true)"

# Read the tenant's registry entry into REG_* shell vars (lists -> csv).
eval "$(python3 - "$SLUG" <<'PY'
import sys, yaml, shlex
slug = sys.argv[1]
with open("tenants/registry.yml") as f:
    reg = yaml.safe_load(f)
t = (reg.get("tenants") or {}).get(slug)
if not t:
    print(f"echo 'ERROR: tenant {slug} not found in tenants/registry.yml'; exit 1")
    sys.exit(0)
for k in ("name", "status", "managed", "box", "domain", "domain_mode",
          "domain_aliases", "db", "db_role", "compose_project", "backend_tag",
          "frontend_tag", "currency", "languages", "modules", "admin_email",
          "city", "template", "stripe_account", "mail_from"):
    v = t.get(k, "")
    if isinstance(v, list):
        v = ",".join(map(str, v))
    print(f"REG_{k.upper()}={shlex.quote(str(v))}")
PY
)"

[[ "$REG_MANAGED" == "scripts" ]] || { echo "ERROR: tenant '$SLUG' is managed:'$REG_MANAGED' — this script only touches managed:scripts tenants (ADR-006 protects tenant 1)" >&2; exit 1; }
[[ "$REG_BOX" == "$BOX_ROLE" ]] || { echo "ERROR: tenant '$SLUG' belongs on box '$REG_BOX' but this box is '$BOX_ROLE'" >&2; exit 1; }
for f in name domain db db_role compose_project frontend_tag admin_email; do
  var="REG_$(echo "$f" | tr '[:lower:]' '[:upper:]')"
  [[ -n "${!var}" ]] || { echo "ERROR: registry entry '$SLUG' missing required field '$f'" >&2; exit 1; }
done

# UI template (frontend ADR-006 / S15 T2): optional, absent -> classic. Anything
# outside the allowed set is a typo that must NOT silently provision as default.
TENANT_TEMPLATE="${REG_TEMPLATE:-classic}"
case "$TENANT_TEMPLATE" in
  classic|craft) ;;
  *) echo "ERROR: registry entry '$SLUG' has template '$TENANT_TEMPLATE' — allowed: classic | craft (absent = classic)" >&2; exit 1 ;;
esac

# Online payments needs BOTH halves or it is not a working purchase. A tenant that bought the
# module but has no connected account would provision happily and then fail at the diner's first
# card payment — the worst place to discover it. Refuse here instead. (The reverse, an account
# recorded before the module is bought, is fine: it stays inert until the module is added.)
if [[ " ${REG_MODULES//,/ } " == *" online-payments "* && -z "$REG_STRIPE_ACCOUNT" ]]; then
  echo "ERROR: tenant '$SLUG' buys 'online-payments' but has no 'stripe_account' in the registry" >&2
  echo "       Onboard the restaurant at Stripe first (hosted onboarding — see the runbook), then record its acct_ id." >&2
  exit 1
fi

# Sending identity (EMAIL-IDENTITY-PLAN). Two sources, in precedence order:
#
#   1. the entry's `mail_from:`   -> the tenant brought its OWN verified domain
#   2. <slug>@$PLATFORM_MAIL_DOMAIN -> the shared platform domain (the default)
#
# The display name stays the restaurant either way (FromName in the template), so
# a guest reads "Kebab House", not "Sofra". Only the envelope domain is shared.
#
# This is checked BEFORE anything is written, because the failure it guards is not
# a bounce and not a log line — with neither source set the tenant falls back to
# Resend's shared onboarding@resend.dev, which answers 403 for every recipient
# except the Resend account owner's own address. The tenant then serves its guests
# perfectly and silently emails none of them.
TENANT_FROM_EMAIL=""
if [[ -n "$REG_MAIL_FROM" ]]; then
  # A typo here is silent and total — the address lands in app-secrets.json and every
  # send 4xxs — so it is shape-checked rather than trusted.
  [[ "$REG_MAIL_FROM" =~ ^[A-Za-z0-9._%+-]+@[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] \
    || { echo "ERROR: registry entry '$SLUG' has mail_from '$REG_MAIL_FROM' — expected a bare address like info@kebabhouse.ch (no display name, no angle brackets)" >&2; exit 1; }
  # The one address the platform must never send as: RUMI's verified domain is
  # tenant 1's identity, and a second tenant borrowing it puts tenant 1's
  # deliverability behind a stranger's spam complaints.
  [[ "$REG_MAIL_FROM" == *@rumirestaurant.ch ]] && [[ "$SLUG" != "rumi" ]] \
    && { echo "ERROR: tenant '$SLUG' cannot send as rumirestaurant.ch — that is tenant 1's verified domain" >&2; exit 1; }
  TENANT_FROM_EMAIL="$REG_MAIL_FROM"
  # Own domain = a real monitored mailbox, so replies already land somewhere a human
  # reads. Adding a Reply-To here would be noise at best and, if it pointed at the
  # operator's alerting inbox, would publish that inbox to every guest.
  TENANT_REPLY_TO=""
  echo "NOTE: tenant '$SLUG' sends from its own address '$TENANT_FROM_EMAIL'" >&2
  echo "      That domain must be VERIFIED in Resend or every send 403s." >&2
elif [[ -n "$PLATFORM_MAIL_DOMAIN" ]]; then
  TENANT_FROM_EMAIL="${SLUG}@${PLATFORM_MAIL_DOMAIN}"
  # On the SHARED domain the From is <slug>@send.sofrapiwas.com — an address nobody
  # reads. Without this, a guest replying to an order confirmation is talking to a
  # black hole. admin_email is the right target: it is the tenant's own contact
  # address and the same value that seeds RestaurantInfo.Email.
  TENANT_REPLY_TO="$REG_ADMIN_EMAIL"
else
  TENANT_FROM_EMAIL="onboarding@resend.dev"
  TENANT_REPLY_TO="$REG_ADMIN_EMAIL"
  echo "WARN: PLATFORM_MAIL_DOMAIN is unset on this box and tenant '$SLUG' has no" >&2
  echo "      'mail_from', so it falls back to Resend's shared onboarding@resend.dev." >&2
  echo "      That sender reaches ONLY the Resend account owner's own address — every" >&2
  echo "      other recipient is refused 403. For this tenant that means:" >&2
  echo "        - /forgot-password answers HTTP 502 to the owner, permanently;" >&2
  echo "        - verification, welcome, order and reservation mail fail SILENTLY." >&2
  echo "      Do not hand this tenant to a paying customer. Verify a platform sending" >&2
  echo "      domain in Resend, set PLATFORM_MAIL_DOMAIN, and re-run." >&2
fi

# Module flags (ADR-010 catalog). Same reasoning as `template`: an unknown value
# is a typo, and a typo here is SILENT — it lands in the tenant env and the
# tenant simply never gets the module they are paying for. The vocabulary is
# mirrored in the control plane (sofra lib/module-catalog.ts) and here; both
# refuse, so a bad value cannot arrive from either direction.
# Trim whitespace from a comma-split registry value (the lists are hand-written
# YAML, so "a, b" is normal and " " is not a module).
strip_ws() { local raw="$1"; printf '%s' "$raw" | tr -d '[:space:]'; }

KNOWN_MODULES="core kitchen-board cashier server reservations loyalty printing online-payments extra-languages"
IFS=',' read -ra _MODULES <<< "$REG_MODULES"
for m in "${_MODULES[@]}"; do
  m="$(strip_ws "$m")"
  [[ -z "$m" ]] && continue
  [[ " $KNOWN_MODULES " == *" $m "* ]] \
    || { echo "ERROR: registry entry '$SLUG' lists unknown module '$m' — allowed: $KNOWN_MODULES" >&2; exit 1; }
done
[[ " ${REG_MODULES//,/ } " == *" core "* ]] \
  || echo "WARN: tenant '$SLUG' has no 'core' module — every instance runs the core surface regardless" >&2

# Languages (EMAIL-LOCALISATION-PLAN §5 S9). Validated for the same reason the modules are,
# and from S9 on it matters twice: this list is no longer only the UI switcher, it is the set
# of languages the tenant's MAIL may be written in (Localization__SupportedLanguages). The
# backend drops a code it has no copy for, so an unknown value does not break a boot — it just
# quietly shrinks the list, and a tenant that believes it sells in that language never mails in
# it. The vocabulary is the product's ten UI locales (backend LanguageCode.Supported /
# frontend src/i18n.ts); it is refused here rather than shrugged off there.
#
# Deliberately STRICTER than the backend, which also accepts "FR" and "fr-CH" and normalises
# them: the registry is a canonical record, not a request. The message says so, because an
# operator who wrote `fr-CH` has misspelled a language the product HAS, and being told it is
# unknown sends them looking for the wrong thing.
KNOWN_LANGUAGES="ar de en es fr it nl ru tr zh"
IFS=',' read -ra _LANGUAGES <<< "$REG_LANGUAGES"
for l in "${_LANGUAGES[@]}"; do
  l="$(strip_ws "$l")"
  [[ -z "$l" ]] && continue
  [[ " $KNOWN_LANGUAGES " == *" $l "* ]] \
    || { echo "ERROR: registry entry '$SLUG' lists unknown language '$l' — allowed: $KNOWN_LANGUAGES (lower-case primary subtag only: 'fr', never 'FR' or 'fr-CH')" >&2; exit 1; }
done
[[ -n "$(strip_ws "$REG_LANGUAGES")" ]] \
  || echo "WARN: tenant '$SLUG' lists no languages — the backend then offers all ten and mails in 'en'" >&2

# The operator's optional override for OPERATOR-facing mail (alerts, background jobs). Like
# TENANT_MODULES_ENFORCE it is hand-written into the tenant .env and never touched by the
# registry, so this is the only place it can be checked. A value outside the tenant's own list
# is not an error in the backend — it logs a warning and uses the first entry — which means the
# operator gets exactly what they did not ask for, silently, until someone reads a container
# log. Catch it here instead.
#
# The value is compared against the tenant's EFFECTIVE set, not the literal registry string:
# an empty `languages` means ALL TEN downstream (compose passes "", the backend reads that as
# unconfigured), so validating against the empty string would refuse a default that the running
# container accepts and honours — and would do it on a re-provision the operator started for
# some entirely unrelated reason.
#
# It is read the way `.env` actually gets written, not the way it is documented: quotes and a
# trailing ` # comment` are both legal there and both stripped by docker compose, so a raw grep
# refuses a tenant that is configured correctly and running correctly. Same reason
# PLATFORM_MAIL_DOMAIN is read with `tr -d '"'` at the top of this script. LAST occurrence, not
# first: a duplicated key means compose uses the last one, so checking the first would validate
# a line the container never sees.
# The read itself is a function because it is now used twice, and because the inline version had
# a defect that only a value with BOTH a quote and a trailing comment could show:
# `TENANT_DEFAULT_LANGUAGE="de"   # staff read German` stripped the comment, left the trailing
# SPACES, and so never matched the `["']$` rule — the value came out as `de"` and the check
# refused a tenant docker compose reads perfectly well. Trailing whitespace is dropped BEFORE the
# closing quote, and both are dropped before the value is used.
env_value() {
  local key="$1" file="$2"

  strip_ws "$(grep "^${key}=" "$file" | tail -1 | cut -d= -f2- \
    | sed -e 's/[[:space:]]#.*$//' -e 's/[[:space:]]*$//' -e 's/^["'"'"']//' -e 's/["'"'"']$//' || true)"
}

if [[ -f "$TENANT_DIR/.env" ]]; then
  _DEFAULT_LANG="$(env_value TENANT_DEFAULT_LANGUAGE "$TENANT_DIR/.env")"
  if [[ -n "$_DEFAULT_LANG" ]]; then
    _EFFECTIVE_LANGS="$(strip_ws "$REG_LANGUAGES" | tr ',' ' ')"
    [[ -n "$_EFFECTIVE_LANGS" ]] || _EFFECTIVE_LANGS="$KNOWN_LANGUAGES"
    [[ " $_EFFECTIVE_LANGS " == *" $_DEFAULT_LANG "* ]] \
      || { echo "ERROR: tenant '$SLUG' sets TENANT_DEFAULT_LANGUAGE='$_DEFAULT_LANG', which is not one of its languages ($_EFFECTIVE_LANGS)" >&2; exit 1; }
  fi

  # Same read, same trap (last occurrence, quotes and trailing comments stripped), for the
  # tenant's wall clock (backend #363). A typo'd id is not fatal in the container — the
  # backend logs it and falls back to Europe/Zurich — which is precisely why it is refused
  # HERE: the alternative is a tenant that mails the wrong hour, in the right format, with
  # the reason buried in a startup log nobody reads. Checked against the box's own tzdata,
  # which is the same database the container carries; if this host has none, the check is
  # skipped rather than turned into a refusal it cannot justify.
  _TENANT_TZ="$(env_value TENANT_TIMEZONE "$TENANT_DIR/.env")"
  if [[ -n "$_TENANT_TZ" && -d /usr/share/zoneinfo ]]; then
    [[ -f "/usr/share/zoneinfo/$_TENANT_TZ" ]] \
      || { echo "ERROR: tenant '$SLUG' sets TENANT_TIMEZONE='$_TENANT_TZ' (read with whitespace removed), which is not an IANA timezone this box knows (e.g. Europe/Zurich)" >&2; exit 1; }
  fi
fi


# Backend tag (deploy #61, optional half; reframed 2026-07-31). `:latest` is published
# ONLY from refs/heads/main and `:staging` ONLY from develop, so the TAG — not the box —
# decides which code a tenant runs. sofra lib/provisioning-registry.ts now always emits
# `latest`; a hand-edited entry can still say anything, and since the ADR-012 chain
# provisions unattended, the box has to say the consequence out loud.
#
# This block used to warn on `box: staging` + `:latest`, back when the generator derived
# the tag from the box. That is now the correct default for every paying tenant, so the
# old warning would have fired on every real customer — and a warning that fires on the
# legitimate case teaches the operator to ignore it. Two separate questions are asked
# instead, because they have different answers and different fixes:
#
#   1. WHICH CODE does this tenant run?      -> informational; only `:staging` is notable
#   2. WILL ANYTHING EVER ROLL IT?           -> a real defect when the answer is no
BACKEND_TAG_EFFECTIVE="${REG_BACKEND_TAG:-latest}"

if [[ "$BACKEND_TAG_EFFECTIVE" == "staging" ]]; then
  # Not a verdict: `demo` wants exactly this. Both readings are named so that whichever
  # one applies, the operator recognises it rather than reading past it.
  echo "NOTE: tenant '$SLUG' rides backend_tag ':staging' — the DEVELOP build." >&2
  echo "      Every backend develop merge re-pulls and recreates it, applying develop's" >&2
  echo "      migrations to its database. Correct for a showcase; wrong for a paying" >&2
  echo "      customer, who should carry 'backend_tag: latest'." >&2
fi

# Q2: a MOVING tag is only useful if something on THIS box re-pulls it when it moves.
# Both refreshers run on the staging box and nowhere else — `:staging` from the backend's
# deploy-staging.yml, `:latest` from refresh-tenants.yml. So a moving
# tag on any other box describes a tenant that is provisioned once and then frozen for
# good, with nothing to signal it. An immutable `sha-…` pin is deliberately NOT flagged:
# never moving is the whole point of pinning one.
if [[ "$BACKEND_TAG_EFFECTIVE" == "latest" || "$BACKEND_TAG_EFFECTIVE" == "staging" ]] \
   && [[ "$REG_BOX" != "staging" ]]; then
  echo "WARN: tenant '$SLUG' is on box '$REG_BOX' and rides the moving tag" >&2
  echo "      ':$BACKEND_TAG_EFFECTIVE', but only the STAGING box refreshes tenants" >&2
  echo "      (refresh-tenant-images.sh is called by the backend repo's" >&2
  echo "      deploy-staging.yml and refresh-tenants.yml, both of which SSH to the" >&2
  echo "      staging box only). Nothing will ever roll this tenant — pin an explicit" >&2
  echo "      'sha-…' if that is intended, or plan to refresh it by hand." >&2
fi

# Domain mode (ADR-002). Absent -> inferred from the domain, so pre-S10 entries
# keep working. The consistency check is the point: a `byo` entry that actually
# sits under sofrapiwas.com (or the reverse) sends the founder chasing the wrong
# DNS record, and the tenant sits certless while everyone looks at Caddy.
DOMAIN_MODE="$REG_DOMAIN_MODE"
if [[ -z "$DOMAIN_MODE" ]]; then
  [[ "$REG_DOMAIN" == *.sofrapiwas.com ]] && DOMAIN_MODE=subdomain || DOMAIN_MODE=byo
fi
case "$DOMAIN_MODE" in
  subdomain)
    [[ "$REG_DOMAIN" == "${SLUG}.sofrapiwas.com" ]] \
      || { echo "ERROR: domain_mode 'subdomain' expects domain '${SLUG}.sofrapiwas.com', registry says '$REG_DOMAIN' (use domain_mode: byo for a tenant-owned domain)" >&2; exit 1; } ;;
  byo)
    [[ "$REG_DOMAIN" == *.sofrapiwas.com ]] \
      && { echo "ERROR: domain_mode 'byo' but '$REG_DOMAIN' is ours — a sofrapiwas.com host rides the wildcard, use domain_mode: subdomain" >&2; exit 1; }
    [[ "$REG_DOMAIN" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] \
      || { echo "ERROR: '$REG_DOMAIN' is not a plausible hostname (lowercase labels, no scheme, no trailing dot)" >&2; exit 1; } ;;
  *) echo "ERROR: registry entry '$SLUG' has domain_mode '$DOMAIN_MODE' — allowed: subdomain | byo (absent = inferred)" >&2; exit 1 ;;
esac

# Optional extra hostnames that should reach this tenant (typically the `www.`
# of a BYO apex). They REDIRECT to the canonical domain rather than proxying:
# the frontend image bakes NEXT_PUBLIC_* for one origin, so serving the app on a
# second hostname would produce cross-origin API calls and a broken CORS story.
# Normalised ONCE into DOMAIN_ALIASES so every later loop iterates clean values.
DOMAIN_ALIASES=()
# Guarded so the split is skipped entirely when the field is absent — bash 5 on
# the boxes copes with the empty case, older bashes (a laptop running the script
# to eyeball it) treat the unset array as an unbound variable under `set -u`.
IFS=',' read -ra _RAW_ALIASES <<< "${REG_DOMAIN_ALIASES:-}"
for _a in ${_RAW_ALIASES[@]+"${_RAW_ALIASES[@]}"}; do
  _a="$(strip_ws "$_a")"
  [[ -z "$_a" ]] && continue
  [[ "$_a" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] \
    || { echo "ERROR: domain_alias '$_a' is not a plausible hostname" >&2; exit 1; }
  [[ "$_a" == "$REG_DOMAIN" ]] \
    && { echo "ERROR: domain_alias '$_a' duplicates the canonical domain" >&2; exit 1; }
  DOMAIN_ALIASES+=("$_a")
done

BOX_IP="$(curl -4 -sS --max-time 10 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
dns_check() { # $1=hostname — warn (never fail) so a propagating record doesn't block a re-run
  local host="$1" ip
  ip="$(getent hosts "$host" | awk '{print $1}' | head -1 || true)"
  [[ "$ip" == "$BOX_IP" ]] && return 0
  echo "WARN: $host resolves to '${ip:-nothing}' but this box is '$BOX_IP'." >&2
  if [[ "$DOMAIN_MODE" == byo ]]; then
    echo "      BYO domain: the tenant must create  A  $host  ->  $BOX_IP  (TTL >= 7200) at their registrar." >&2
  else
    echo "      Subdomain tenants ride the *.sofrapiwas.com wildcard A record — check it still points here." >&2
  fi
  echo "      Caddy cannot get a certificate until then. Continuing (a fresh record may still be propagating)." >&2
}
dns_check "$REG_DOMAIN"
for alias in ${DOMAIN_ALIASES[@]+"${DOMAIN_ALIASES[@]}"}; do
  dns_check "$alias"
done

echo "==> Tenant dir: $TENANT_DIR"
# /opt/rumi/tenants is also bind-mounted (ro) into Caddy; if compose created it
# first it is root-owned — hand it to the deploy user via the docker group.
if [[ ! -w /opt/rumi/tenants ]]; then
  install -d /opt/rumi/tenants 2>/dev/null \
    || docker run --rm -v /opt/rumi:/r alpine:3 sh -c "mkdir -p /r/tenants && chown $(id -u):$(id -g) /r/tenants"
fi
install -d "$TENANT_DIR" "$TENANT_DIR/uploads"

# URL/connection-string-safe randoms (same recipe as gen-secrets.sh).
rand() { local bytes="$1" len="$2"; openssl rand -base64 "$bytes" | tr -d '/+=' | cut -c1-"$len"; }

# Escape free-text registry values (name, city) for use in a sed REPLACEMENT:
# backslash, ampersand, and the | delimiter would otherwise corrupt the render.
sed_escape() { local text="$1"; printf '%s' "$text" | sed -e 's/[\\&|]/\\&/g'; }

# Replace-or-append KEY=value in the tenant .env (idempotent). $TENANT_DIR resolves at call
# time. Used for registry-owned identity lines and the shared fleet/Sentry values.
set_env_line() { # $1=key $2=value (free text)
  local key="$1" value="$2"
  if grep -q "^$key=" "$TENANT_DIR/.env"; then
    sed -i "s|^$key=.*|$key=$(sed_escape "$value")|" "$TENANT_DIR/.env"
  else
    printf '%s=%s\n' "$key" "$value" >> "$TENANT_DIR/.env"
  fi
}

# Free-text values landing in the tenant .env are interpolated by docker
# compose — a literal $ must be doubled or compose silently mangles it (same
# trap as DEV_PORTAL_AUTH_HASH; see DEPLOYMENT.md §Developer Portal).
ENV_NAME="$(printf '%s' "$REG_NAME" | sed -e 's/\$/$$/g')"
ENV_CITY="$(printf '%s' "$REG_CITY" | sed -e 's/\$/$$/g')"

echo "==> Tenant .env"
FRESH_ENV=0
if [[ -f "$TENANT_DIR/.env" ]]; then
  echo "   keep: .env exists (DB password preserved). Registry tag/identity changes ARE re-applied below."
  # Re-apply the registry-owned values on every run (tags + identity are the
  # things that legitimately drift); generated secrets stay stable per tenant.
  sed -i -e "s|^BACKEND_TAG=.*|BACKEND_TAG=${REG_BACKEND_TAG:-latest}|" \
         -e "s|^FRONTEND_TAG=.*|FRONTEND_TAG=${REG_FRONTEND_TAG}|" "$TENANT_DIR/.env"
  # Identity lines may be absent on a pre-#16 .env — replace or append (set_env_line, top-level).
  set_env_line TENANT_NAME "$ENV_NAME"
  set_env_line TENANT_CITY "$ENV_CITY"
  set_env_line NEXT_PUBLIC_TEMPLATE "$TENANT_TEMPLATE"
  # Product facts, re-applied for the same reason the tags are: they legitimately drift.
  # Until module enforcement (S11) these were written ONLY on the fresh-render path, so a
  # registry edit reached a re-provisioned tenant's .env never — harmless while nothing read
  # them, and a live trap the moment `modules` became binding: an upgrade would silently keep
  # serving the list the tenant was FIRST provisioned with. strip_ws because the YAML string
  # form (`modules: "core, kitchen-board"`) arrives unnormalised and the ids have no spaces.
  set_env_line TENANT_CURRENCY "$(strip_ws "$REG_CURRENCY")"
  set_env_line TENANT_LANGUAGES "$(strip_ws "$REG_LANGUAGES")"
  set_env_line TENANT_MODULES "$(strip_ws "$REG_MODULES")"
  # The operator's enforcement opt-in is hand-written into this .env (it is a rollout
  # control, not a product fact, so it is deliberately NOT in the registry) — which makes it
  # the only unvalidated value in the file. It binds to a C# bool, and the backend resolves
  # that eagerly at startup, so `TENANT_MODULES_ENFORCE=1` does not mean "on": it throws
  # before the app listens and `restart: unless-stopped` turns it into a crash loop. Catch a
  # typo here, where it costs a message, instead of there, where it costs the tenant.
  _ENFORCE="$(strip_ws "$(grep -m1 '^TENANT_MODULES_ENFORCE=' "$TENANT_DIR/.env" | cut -d= -f2- || true)")"
  if [[ -n "$_ENFORCE" ]]; then
    shopt -s nocasematch
    [[ "$_ENFORCE" == "true" || "$_ENFORCE" == "false" ]] \
      || { echo "ERROR: tenant '$SLUG' .env has TENANT_MODULES_ENFORCE='$_ENFORCE' — must be exactly true or false (it binds to a bool; anything else crash-loops the backend)" >&2; shopt -u nocasematch; exit 1; }
    shopt -u nocasematch
  fi
else
  FRESH_ENV=1
  TENANT_DB_PASSWORD="$(rand 48 32)"
  # Admin bootstrap password (backend #116): the "!Aa1" suffix guarantees the
  # upper/lower/digit/symbol classes the backend's Identity policy requires —
  # random alnum alone can miss a class and the seeder would silently skip.
  TENANT_ADMIN_PASSWORD="$(rand 48 24)!Aa1"
  # strip_ws on the three product lists (currency/languages/modules), because the
  # RE-PROVISION path above already writes them stripped (set_env_line "$(strip_ws ...)").
  # Without it a tenant's .env said `TENANT_LANGUAGES=en, nl` on its first day and `en,nl`
  # after any later re-provision — the same tenant, two spellings, and every reader has to
  # forgive both forever. The YAML string form (`languages: "en, nl"`) is what produces it.
  sed -e "s|__SLUG__|${SLUG}|g" \
      -e "s|__DOMAIN__|${REG_DOMAIN}|g" \
      -e "s|__NAME__|$(sed_escape "$ENV_NAME")|g" \
      -e "s|__CITY__|$(sed_escape "$ENV_CITY")|g" \
      -e "s|__BACKEND_TAG__|${REG_BACKEND_TAG:-latest}|g" \
      -e "s|__FRONTEND_TAG__|${REG_FRONTEND_TAG}|g" \
      -e "s|__DB__|${REG_DB}|g" \
      -e "s|__DB_ROLE__|${REG_DB_ROLE}|g" \
      -e "s|__DB_PASSWORD__|${TENANT_DB_PASSWORD}|g" \
      -e "s|__ADMIN_EMAIL__|${REG_ADMIN_EMAIL}|g" \
      -e "s|__ADMIN_PASSWORD__|${TENANT_ADMIN_PASSWORD}|g" \
      -e "s|__CURRENCY__|$(strip_ws "$REG_CURRENCY")|g" \
      -e "s|__LANGUAGES__|$(strip_ws "$REG_LANGUAGES")|g" \
      -e "s|__MODULES__|$(strip_ws "$REG_MODULES")|g" \
      -e "s|__TEMPLATE__|${TENANT_TEMPLATE}|g" \
      tenants/templates/tenant.env.tpl > "$TENANT_DIR/.env"
  chmod 600 "$TENANT_DIR/.env"
  echo "   wrote .env (fresh DB password + admin bootstrap credentials)"
fi
TENANT_DB_PASSWORD="$(grep '^TENANT_DB_PASSWORD=' "$TENANT_DIR/.env" | cut -d= -f2-)"

# Flow the shared fleet/Sentry values into the tenant .env on every run (fresh AND existing),
# so the tenant compose can interpolate ${SENTRY_DSN} / ${PRINTER_TELEMETRY_SECRET}. Rotatable —
# a changed box value is re-applied on the next provision. Reuses set_env_line (top-level).
set_env_line SENTRY_DSN "$BOX_SENTRY_DSN"
set_env_line SENTRY_ENVIRONMENT "$BOX_ROLE"
set_env_line PRINTER_TELEMETRY_SECRET "$BOX_TELEMETRY_SECRET"

# Stripe: the key is the box's, the account is the tenant's, and ENABLED is derived from the
# module list rather than being a separate operator switch — a tenant that did not buy
# online-payments must not be one env edit away from taking card payments.
set_env_line STRIPE_PLATFORM_API_KEY "$BOX_STRIPE_KEY"
set_env_line STRIPE_CONNECTED_ACCOUNT_ID "$REG_STRIPE_ACCOUNT"
if [[ " ${REG_MODULES//,/ } " == *" online-payments "* ]]; then
  set_env_line STRIPE_ENABLED "true"
else
  set_env_line STRIPE_ENABLED "false"
fi

echo "==> Tenant app-secrets.json"
if [[ -f "$TENANT_DIR/app-secrets.json" ]]; then
  echo "   keep: app-secrets.json exists (JWT/printer secrets preserved)"
  # The keep is deliberate, but it means the sender resolved above is NOT applied to
  # an already-provisioned tenant. Left unsaid, that is the original defect repeating:
  # the operator sets PLATFORM_MAIL_DOMAIN, re-runs, sees a green provision, and the
  # tenant goes on emailing nobody. Compare and say so; do not rewrite a secrets file.
  CURRENT_FROM="$(python3 -c 'import json;print(json.load(open("'"$TENANT_DIR"'/app-secrets.json")).get("EmailSettings",{}).get("FromEmail",""))' 2>/dev/null || true)"
  if [[ -n "$CURRENT_FROM" && "$CURRENT_FROM" != "$TENANT_FROM_EMAIL" ]]; then
    echo "WARN: this tenant still sends as '$CURRENT_FROM', but its configured sender is now" >&2
    echo "      '$TENANT_FROM_EMAIL'. Re-provisioning does NOT change it (secrets are kept)." >&2
    if [[ "$CURRENT_FROM" == "onboarding@resend.dev" ]]; then
      echo "      Until it is changed this tenant can email only the Resend account owner." >&2
    fi
    # Printed as two single-line commands on purpose. An earlier version echoed a
    # multi-line python heredoc, which reads as an actual heredoc OPENING in this
    # script to anyone (or anything) scanning it — it already cost one reviewer a
    # false "unbalanced if/fi" verdict. Keep emitted instructions free of shell
    # block syntax.
    echo "      Apply by hand on the box, then restart the tenant:" >&2
    echo "        python3 -c \"import json;p='$TENANT_DIR/app-secrets.json';d=json.load(open(p));d['EmailSettings']['FromEmail']='$TENANT_FROM_EMAIL';json.dump(d,open(p,'w'),indent=2)\"" >&2
    echo "        docker compose -p ${REG_COMPOSE_PROJECT} -f $TENANT_DIR/docker-compose.yml up -d" >&2
  fi
else
  # Reuse this box's Resend key (tenants send via onboarding@resend.dev — see
  # template note). Reads the key from the box's own app-secrets.json.
  RESEND_KEY="$(python3 -c 'import json;print(json.load(open("app-secrets.json")).get("EmailSettings",{}).get("ResendApiKey",""))' 2>/dev/null || true)"
  [[ -n "$RESEND_KEY" ]] || echo "   WARN: no ResendApiKey found in the box app-secrets.json — tenant email will fail until set"
  JWT_SECRET="$(openssl rand -base64 48)"
  PRINTER_APIKEY="$(openssl rand -hex 32)"
  # Rendered with python3, not sed: values like the base64 JWT secret or a
  # free-text tenant name can contain sed metacharacters (&, |) that would
  # silently corrupt the JSON. Also parse-checks the result before writing.
  T_SLUG="$SLUG" T_DOMAIN="$REG_DOMAIN" T_NAME="$REG_NAME" T_ADMIN="$REG_ADMIN_EMAIL" \
  T_JWT="$JWT_SECRET" T_PRINTER="$PRINTER_APIKEY" T_RESEND="$RESEND_KEY" \
  T_FROM="$TENANT_FROM_EMAIL" T_REPLY_TO="$TENANT_REPLY_TO" \
  T_OUT="$TENANT_DIR/app-secrets.json" python3 - <<'PY'
import json, os
tpl = open("tenants/templates/app-secrets.tenant.json.tpl").read()
for token, env in (("__SLUG__", "T_SLUG"), ("__DOMAIN__", "T_DOMAIN"),
                   ("__TENANT_NAME__", "T_NAME"), ("__ADMIN_EMAIL__", "T_ADMIN"),
                   ("__JWT_SECRET__", "T_JWT"), ("__PRINTER_APIKEY__", "T_PRINTER"),
                   ("__RESEND_API_KEY__", "T_RESEND"), ("__FROM_EMAIL__", "T_FROM"),
                   ("__REPLY_TO_EMAIL__", "T_REPLY_TO")):
    tpl = tpl.replace(token, json.dumps(os.environ[env])[1:-1])
json.loads(tpl)  # refuse to write corrupt JSON
os.umask(0o177)
with open(os.environ["T_OUT"], "w") as f:
    f.write(tpl)
PY
  chmod 600 "$TENANT_DIR/app-secrets.json"
  echo "   wrote app-secrets.json (fresh JWT + printer key, mode 600)"
fi

echo "==> Render docker-compose.yml"
sed -e "s|__SLUG__|${SLUG}|g" \
    tenants/templates/docker-compose.tenant.yml.tpl > "$TENANT_DIR/docker-compose.yml"

echo "==> Database (role + db on the shared postgres, idempotent)"
PGUSER="$(grep '^POSTGRES_USER=' .env | cut -d= -f2- || true)"
[[ -n "$PGUSER" ]] || { echo "ERROR: POSTGRES_USER not set in .env" >&2; exit 1; }
psql_deploy() { $DEPLOY_COMPOSE exec -T postgres psql -v ON_ERROR_STOP=1 -U "$PGUSER" -d postgres "$@"; }
if psql_deploy -tAc "SELECT 1 FROM pg_roles WHERE rolname='${REG_DB_ROLE}'" | grep -q 1; then
  echo "   keep: role ${REG_DB_ROLE} exists"
else
  psql_deploy -c "CREATE ROLE ${REG_DB_ROLE} LOGIN PASSWORD '${TENANT_DB_PASSWORD}'"
  echo "   created role ${REG_DB_ROLE}"
fi
if psql_deploy -tAc "SELECT 1 FROM pg_database WHERE datname='${REG_DB}'" | grep -q 1; then
  echo "   keep: database ${REG_DB} exists"
else
  psql_deploy -c "CREATE DATABASE ${REG_DB} OWNER ${REG_DB_ROLE}"
  echo "   created database ${REG_DB} (owner ${REG_DB_ROLE})"
fi

echo "==> Pull images (project tenant-${SLUG})"
(cd "$TENANT_DIR" && docker compose pull)

echo "==> Fix file ownership for the backend container user"
# Backend runs non-root; app-secrets.json must be group-readable by its gid and
# the uploads bind dir writable by its uid. rumi's docker-group membership is
# the privilege here — no sudo (box sudo is deliberately scoped). Runs after
# the pull so the uid:gid inspection never triggers (or fails on) an implicit
# image pull of its own.
BE_IDS="$(docker run --rm --entrypoint sh "${BE_REPO}:${REG_BACKEND_TAG:-latest}" -c 'echo "$(id -u):$(id -g)"' 2>/dev/null || true)"
if [[ -n "$BE_IDS" ]]; then
  docker run --rm -v "$TENANT_DIR":/t alpine:3 sh -c \
    "chown $(id -u):${BE_IDS#*:} /t/app-secrets.json && chmod 640 /t/app-secrets.json && chown -R ${BE_IDS} /t/uploads"
  echo "   app-secrets.json -> $(id -un):${BE_IDS#*:} mode 640; uploads -> ${BE_IDS}"
else
  echo "   WARN: could not determine backend uid:gid; secrets/uploads may be unreadable by the container"
fi

echo "==> Up (project tenant-${SLUG})"
# Clear the completion marker BEFORE touching the running containers. This is a
# re-provision path too (module upsell, BYO domain, a corrected name), and the next
# three stages can each exit 1 — the health wait, the admin bootstrap smoke check, the
# Caddy validate. Without this, such a run leaves the tenant recreated-and-broken while
# the PREVIOUS run's marker still says provisioned, and the merge chain — which reads
# the marker as authoritative `done` — would then decline to complete it, forever.
# `.chain-provisioned` is the pre-2026-08-01 name; clear it too or it outvotes us.
rm -f "${TENANT_DIR}/.provisioned" "${TENANT_DIR}/.chain-provisioned"
(cd "$TENANT_DIR" && docker compose up -d)

echo "==> Wait for backend health (migrations + seed run on first boot)"
for i in $(seq 1 60); do
  if docker run --rm --network deploy_rumi curlimages/curl:8.10.1 -sf "http://backend-${SLUG}:8080/api/health" >/dev/null 2>&1; then
    echo "   backend-${SLUG} healthy"
    break
  fi
  [[ "$i" == 60 ]] && { echo "ERROR: backend-${SLUG} not healthy after 5m — check: (cd $TENANT_DIR && docker compose logs backend-${SLUG})" >&2; exit 1; }
  sleep 5
done

echo "==> Admin bootstrap smoke check (seeded admin can log in)"
# Catches the silent-failure mode where an injected password fails the
# backend's Identity policy: the seeder logs an error but startup succeeds,
# leaving a tenant with no admin. Only meaningful on the boot that actually
# seeds — i.e. when this run rendered a fresh .env for a fresh DB. On
# re-provision the operator may have rotated the password (as instructed),
# so checking the bootstrap value again would falsely abort a healthy run.
ADMIN_EMAIL_CHECK="$(grep '^TENANT_ADMIN_EMAIL=' "$TENANT_DIR/.env" | cut -d= -f2- || true)"
ADMIN_PW_CHECK="$(grep '^TENANT_ADMIN_PASSWORD=' "$TENANT_DIR/.env" | cut -d= -f2- || true)"
if [[ "$FRESH_ENV" == 1 && -n "$ADMIN_EMAIL_CHECK" && -n "$ADMIN_PW_CHECK" ]]; then
  LOGIN_BODY="{\"email\":\"${ADMIN_EMAIL_CHECK}\",\"password\":\"${ADMIN_PW_CHECK}\"}"
  if docker run --rm --network deploy_rumi curlimages/curl:8.10.1 -sf -X POST \
       -H 'Content-Type: application/json' -d "$LOGIN_BODY" \
       "http://backend-${SLUG}:8080/api/auth/login" | grep -q '"success":true'; then
    echo "   admin login OK (${ADMIN_EMAIL_CHECK})"
  else
    echo "ERROR: seeded admin login FAILED — check backend logs for the seeder warning/error" >&2
    echo "       (cd $TENANT_DIR && docker compose logs backend-${SLUG} | grep -i -A2 seed)" >&2
    echo "       Note: the seeder only creates the admin on an EMPTY database; on an existing" >&2
    echo "       DB the bootstrap credentials in .env do not apply (use the app's password reset)." >&2
    exit 1
  fi
elif [[ "$FRESH_ENV" == 0 ]]; then
  echo "   skip: re-provision (bootstrap creds only apply to the first boot; the admin may have rotated the password since)"
else
  echo "   skip: no TENANT_ADMIN_* in the tenant .env (pre-#116 tenant — adopting needs a DB reset: deprovision --drop-db, then provision fresh)"
fi

echo "==> Stripe payment methods (only when this tenant bought online-payments)"
# MEASURED, not assumed (SOFRA-PAYMENTS-PLAN §3): TWINT is OFF by default and will not appear at
# checkout even with the capability active — with twint_payments:active, dynamic methods still
# returned ['card','link','klarna']. Flipping the display preference to `on` is what adds it. For a
# Swiss restaurant that is not a nice-to-have; TWINT is the local default.
#
# Each connected account has TWO payment-method configurations: its own (parent:None — the one
# Checkout actually uses) and one inherited from the platform's. This flips the account's OWN one.
if [[ " ${REG_MODULES//,/ } " == *" online-payments "* ]]; then
  if [[ -z "$BOX_STRIPE_KEY" ]]; then
    echo "ERROR: tenant '$SLUG' bought online-payments but STRIPE_PLATFORM_API_KEY is unset on this box" >&2
    echo "       The tenant would provision with a checkout that cannot take a card. Set it and re-run." >&2
    exit 1
  fi

  # The account's own configuration is the one with no parent. jq is not assumed present on the
  # box (nothing else in this script needs it), so python3 — already a hard dependency above —
  # does the parsing.
  PMC_JSON="$(curl -sS --max-time 20 \
    -u "${BOX_STRIPE_KEY}:" \
    -H "Stripe-Account: ${REG_STRIPE_ACCOUNT}" \
    "https://api.stripe.com/v1/payment_method_configurations" || true)"

  PMC_ID="$(printf '%s' "$PMC_JSON" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for cfg in data.get("data", []):
    # parent is null on the account own configuration; the inherited one names the platform.
    if not cfg.get("parent"):
        print(cfg.get("id", ""))
        break
' || true)"

  if [[ -z "$PMC_ID" ]]; then
    echo "ERROR: could not read the payment-method configuration for '$REG_STRIPE_ACCOUNT'" >&2
    echo "       Stripe said: $(printf '%s' "$PMC_JSON" | head -c 300)" >&2
    exit 1
  fi

  # FAILS THE PROVISION on purpose. A tenant who paid for online payments and silently got a
  # checkout without TWINT is a broken purchase that nobody would notice until a Swiss diner
  # complained — the "gate that fails open" shape this repo has been bitten by before.
  if curl -sS --fail --max-time 20 \
      -u "${BOX_STRIPE_KEY}:" \
      -H "Stripe-Account: ${REG_STRIPE_ACCOUNT}" \
      -X POST "https://api.stripe.com/v1/payment_method_configurations/${PMC_ID}" \
      -d "twint[display_preference][preference]=on" >/dev/null; then
    echo "   ok: TWINT display preference on for ${REG_STRIPE_ACCOUNT} (${PMC_ID})"
  else
    echo "ERROR: failed to enable TWINT on ${REG_STRIPE_ACCOUNT} (${PMC_ID})" >&2
    exit 1
  fi
else
  echo "   skip: '$SLUG' has no online-payments module"
fi

echo "==> Caddy site block + validate + reload"
sed -e "s|__SLUG__|${SLUG}|g" \
    -e "s|__DOMAIN__|${REG_DOMAIN}|g" \
    tenants/templates/site.caddy.tpl > "caddy-tenants/${SLUG}.caddy"
# Alias hostnames get their own tiny redirect site (301 to the canonical origin),
# appended to the same file so teardown still removes everything in one unlink.
for alias in ${DOMAIN_ALIASES[@]+"${DOMAIN_ALIASES[@]}"}; do
  cat >> "caddy-tenants/${SLUG}.caddy" <<CADDY

# Alias -> canonical. A redirect, not a proxy: the frontend bundle bakes
# NEXT_PUBLIC_* for one origin (see the alias note in provision-tenant.sh).
${alias} {
	redir https://${REG_DOMAIN}{uri} permanent
}
CADDY
  echo "   alias: ${alias} -> https://${REG_DOMAIN}"
done
# The tenants dir is bind-mounted as a DIRECTORY, so the new file is already
# visible in the container and a plain reload re-globs the imports (the
# single-file Caddyfile inode gotcha only applies to the main Caddyfile).
# Validate FIRST and roll the file back on failure — never force-recreate here:
# recreating with a broken import would take down every site on the box.
if ! $DEPLOY_COMPOSE exec caddy caddy validate --config /etc/caddy/Caddyfile; then
  rm -f "caddy-tenants/${SLUG}.caddy"
  echo "ERROR: rendered caddy block failed validation — removed it again; live config untouched" >&2
  exit 1
fi
$DEPLOY_COMPOSE exec caddy caddy reload --config /etc/caddy/Caddyfile

# Printer-app onboarding bundle — the three values the tenant enters in the printer-app's
# Settings screen. The key is a box-only secret (never committed); surfaced here once so the
# founder can hand it over if the tenant buys the printer service.
PRINTER_KEY="$(python3 -c 'import json,sys; print((json.load(open(sys.argv[1])).get("PrinterSettings") or {}).get("ApiKey") or "")' "$TENANT_DIR/app-secrets.json" 2>/dev/null || true)"

# What the RUNNING backend says about modules — never what the .env says. The .env is
# intent; this is the effective set, and they diverge for real reasons: an empty list
# reads as unrestricted, `core` is on regardless of the list, and an id outside the
# catalog is dropped with a startup warning. A fresh tenant enforces by default
# (tenants/templates/tenant.env.tpl), and this is the line that proves it did rather
# than asserting it. Same in-network curl the health wait uses, so it needs neither
# Caddy nor the certificate that has not been issued yet.
MODULES_JSON="$(docker run --rm --network deploy_rumi curlimages/curl:8.10.1 \
  -sf --max-time 10 "http://backend-${SLUG}:8080/api/tenant/modules" 2>/dev/null || true)"
# A failure to OBSERVE must never read as "enforced, all good" — hence the third branch.
MODULES_NOTE="$(MJ="$MODULES_JSON" REG="$(strip_ws "$REG_MODULES")" ENVF="$TENANT_DIR/.env" python3 <<'PY' || true
import json, os

pad = "\n" + " " * 16
raw, want = os.environ.get("MJ", ""), os.environ.get("REG", "")
try:
    data = json.loads(raw).get("data") or {}
    got, enforced = sorted(data["modules"]), bool(data["enforced"])
except Exception:
    print("? could not read /api/tenant/modules from the running backend, so this run"
          + pad + "proves NOTHING about enforcement either way. Check it by hand:"
          + pad + "  curl -s https://<domain>/api/tenant/modules")
    raise SystemExit(0)

expect = sorted({m for m in want.split(",") if m} | {"core"})
if not enforced:
    # `enforced` is ONE field with TWO causes — the backend computes
    # `IsEnforced = Enforce && known.Length > 0`, so an empty Modules:Enabled reports
    # false even with the flag on. Since the template now hardcodes the flag, the empty
    # list is the LIKELIER cause of the two, and naming only the flag would send the
    # operator to grep a line that already says `true` and stop there. `modules:` is not
    # a required registry field (provision-tenant.sh only WARNs on a missing `core`), so
    # an entry can legitimately arrive with none.
    print("! NOT enforced — this tenant serves EVERY module whatever it bought."
          + pad + "Two causes, and the registry list is the likelier one:"
          + pad + "  * `modules:` empty in the registry — an empty list reads as"
          + pad + "    unrestricted even with the flag on. Registry says: "
          + (", ".join(expect) if want else "(nothing)")
          + pad + "  * TENANT_MODULES_ENFORCE overridden in " + os.environ.get("ENVF", ".env")
          + pad + "Fix whichever applies, then recreate this tenant's backend.")
elif got != expect:
    print("! enforced, but the effective set is NOT the registry list."
          + pad + "serving : " + ", ".join(got)
          + pad + "registry: " + ", ".join(expect)
          + pad + "The customer is short a module they paid for, or has one they did not.")
else:
    print("+ enforced, and the backend confirms exactly these ids (core is always on).")
PY
)"

# Completion marker — written HERE, by the script, and only once every step above has
# succeeded (`set -e`, so reaching this line IS the success condition). Nothing below
# it can fail; it is a heredoc.
#
# What it asserts, precisely: **a complete provisioning run finished for this tenant.**
# Not "the site is serving" — the liveness gate above is the backend's /api/health, and
# a frontend container that starts and then crash-loops still gets here. `verify-env.sh`
# remains the up-check. The marker is cleared again at the top of every run (see the
# note by `docker compose up -d`), so it never survives a run that died half-way.
#
# It moved here from the merge chain, which used to write `.chain-provisioned` over ssh
# after the script exited 0. That made the marker mean "the CHAIN provisioned this",
# when what the chain actually needs to know is "this tenant is already up". Those
# differ for every tenant stood up by hand (DEPLOYMENT.md / runbook §6 — every
# re-provision, module upsell and BYO domain), and the difference was a live bug:
# such a tenant has a `.env` but no marker, so the chain read it as `partial` and,
# on EVERY subsequent registry merge, re-ran provisioning against it — restarting a
# tenant serving real traffic, which the chain's own header promises it never does —
# while permanently occupying one of its MAX_PER_RUN slots. Three of them and the cap
# refuses the whole batch, blocking a genuinely new customer.
#
# The registry `status:` flip was the only thing standing between us and that, and
# nothing derived or verified it. Now the box records the fact itself.
date -u +%Y-%m-%dT%H:%M:%SZ > "${TENANT_DIR}/.provisioned"

cat <<EOF

==> Provisioned tenant '${SLUG}' (${REG_NAME})
    URL       : https://${REG_DOMAIN}   (cert issues on first hit; allow ~30s)
    Verify    : ./verify-env.sh https://${REG_DOMAIN}
    Containers: (cd ${TENANT_DIR} && docker compose ps)
    Logs      : (cd ${TENANT_DIR} && docker compose logs -f backend-${SLUG})
    Admin     : ${REG_ADMIN_EMAIL} — point the owner at
                https://${REG_DOMAIN}/forgot-password and let them set their own
                password. DO NOT read out the bootstrap password: since the
                frontend release of 2026-07-30 the reset pages exist and work on a
                freshly provisioned tenant (verified on the chain's first real run),
                so no credential has to leave this box at all.
                The generated bootstrap password is still the TENANT_ADMIN_PASSWORD
                line in ${TENANT_DIR}/.env (mode 600) as break-glass — if you ever
                do use it, change it immediately.
    Modules   : ${REG_MODULES}
                ${MODULES_NOTE}
    Printer app (if the tenant buys the printer service — enter in the app's Settings):
                API Base URL : https://${REG_DOMAIN}
                Tenant Slug  : ${SLUG}
                Printer Key  : ${PRINTER_KEY}
                (the key is PrinterSettings.ApiKey in ${TENANT_DIR}/app-secrets.json)
    Fleet obs : automatic — this tenant's backend pushes to sofra /admin/fleet when
                PRINTER_TELEMETRY_SECRET is set on the box (currently: $([[ -n "$BOX_TELEMETRY_SECRET" ]] && echo set || echo UNSET → inert)).
EOF
