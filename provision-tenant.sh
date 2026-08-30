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
# box (subdomain tenants under OUR base domain ride the *.sofrapiwas.com
# wildcard; a tenant under a partner's `base_domain:` has NO wildcard and needs
# its own A record — see the domain helpers below); the per-tenant frontend
# image exists (frontend repo: build-tenant-image.yml).
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
          "base_domain", "domain_aliases", "db", "db_role", "compose_project",
          "backend_tag", "frontend_tag", "currency", "languages", "modules",
          "admin_email", "city", "template", "stripe_account", "mail_from",
          "partner_name", "partner_url", "partner_attribution"):
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
  echo "       This refusal is BEFORE the database, so nothing was created — and a tenant already" >&2
  echo "       live on this slug is untouched, but every re-provision of it stops here." >&2
  echo "       Fix it in ONE registry commit: add 'stripe_account: acct_...' AND keep" >&2
  echo "       'online-payments' in modules. See docs/runbooks/signup-to-live-tenant.md §2b.5." >&2
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

# --- BEGIN domain helpers (extracted verbatim by tests/domain-base.sh) ---
# OUR base domain: the only one with a wildcard A record (`*.sofrapiwas.com`, added
# 2026-07-06). Named once, because `base_domain:` generalises every use of it — a
# reseller partner may host N of his clients under HIS zone
# (`obresse.solutioneva.com`), which has no wildcard and never will.
PLATFORM_BASE_DOMAIN="sofrapiwas.com"

# Every line of DNS advice below is printed at the same indent, as its own argument,
# so the block stays readable in a CI log. A FUNCTION rather than a format variable:
# naming the format once satisfies the "don't repeat the literal" rule, and passing a
# variable AS a printf format would trip shellcheck SC2059. One literal, four callers,
# and no way for the indent to drift between them.
dns_advice() { printf '      %s\n' "$@"; }

# A plausible public hostname: lowercase labels, at least one dot, no scheme, no
# trailing dot, no underscore. One rule for the domain, the aliases and the base.
is_plausible_host() { # $1=hostname
  local host="$1"
  [[ "$host" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]
}

# Resolve `domain_mode` (ADR-002) and cross-check it against the domain and the
# tenant's base domain. Echoes the effective mode; prints the reason and returns 1 on
# any inconsistency. Pure — no I/O, no globals but PLATFORM_BASE_DOMAIN — so
# tests/domain-base.sh can drive every branch without a box.
#
# The check is not bookkeeping. A mislabelled entry sends the founder chasing the
# wrong DNS record while the tenant sits certless and everyone looks at Caddy; that
# was true of `byo` vs `subdomain` and it is truer now, because a partner base domain
# has no wildcard to fall back on.
#
# `base_domain:` ABSENT MEANS EXACTLY THE PRE-2026-08-20 BEHAVIOUR — every entry
# written before the field existed provisions identically. tests/domain-base.sh holds
# a frozen copy of the old logic and asserts the two agree on every such input.
resolve_domain_mode() { # $1=slug $2=domain $3=domain_mode ('' = infer) $4=base_domain ('' = ours)
  local slug="$1" domain="$2" mode="$3" raw_base="$4" base="$PLATFORM_BASE_DOMAIN"

  if [[ -n "$raw_base" ]]; then
    if ! is_plausible_host "$raw_base"; then
      echo "ERROR: registry entry '$slug' has base_domain '$raw_base' — expected a bare dotted hostname like 'solutioneva.com': lowercase labels, at least one dot, no scheme, no trailing dot, no leading dot. Omit the field entirely to mean '${PLATFORM_BASE_DOMAIN}'." >&2
      return 1
    fi
    base="$raw_base"
  fi

  # Inference, for pre-S10 entries carrying no domain_mode: a name under the
  # EFFECTIVE base is a subdomain tenant, anything else is a domain of its own.
  if [[ -z "$mode" ]]; then
    if [[ "$domain" == *".$base" ]]; then mode=subdomain; else mode=byo; fi
  fi

  case "$mode" in
    subdomain)
      if [[ "$domain" != "${slug}.${base}" ]]; then
        echo "ERROR: domain_mode 'subdomain' expects domain '${slug}.${base}', registry says '$domain'" >&2
        if [[ -z "$raw_base" ]]; then
          echo "       This entry has no 'base_domain:', so the base is OURS (${PLATFORM_BASE_DOMAIN})." >&2
          echo "       If this tenant lives under a partner's own zone, add 'base_domain: <their domain>';" >&2
          echo "       if the domain belongs to the restaurant, use 'domain_mode: byo'." >&2
        else
          echo "       This entry declares 'base_domain: ${base}', so the host must be the slug and" >&2
          echo "       nothing else under it — exactly one label, matching the tenant key." >&2
        fi
        return 1
      fi ;;
    byo)
      # A contradiction, refused rather than quietly ignored. `byo` means the
      # RESTAURANT owns the whole name and publishes its own record; `base_domain`
      # names a zone WE place tenants under, which is the subdomain shape. Accepting
      # both would leave an entry whose two halves disagree about who owns the DNS,
      # and then silently drop one of them — reintroducing, in a new place, the exact
      # failure this cross-check exists to prevent.
      if [[ -n "$raw_base" ]]; then
        echo "ERROR: registry entry '$slug' sets domain_mode 'byo' AND base_domain '$raw_base' — those contradict" >&2
        echo "       'byo'        = a domain the RESTAURANT owns; there is no base to be under." >&2
        echo "       'base_domain'= a zone we put tenants under; that is 'domain_mode: subdomain'." >&2
        echo "       Pick one: drop base_domain, or set domain_mode: subdomain." >&2
        return 1
      fi
      if [[ "$domain" == *".$PLATFORM_BASE_DOMAIN" ]]; then
        echo "ERROR: domain_mode 'byo' but '$domain' is ours — a ${PLATFORM_BASE_DOMAIN} host rides the wildcard, use domain_mode: subdomain" >&2
        return 1
      fi
      if ! is_plausible_host "$domain"; then
        echo "ERROR: '$domain' is not a plausible hostname (lowercase labels, no scheme, no trailing dot)" >&2
        return 1
      fi ;;
    *)
      echo "ERROR: registry entry '$slug' has domain_mode '$mode' — allowed: subdomain | byo (absent = inferred)" >&2
      return 1 ;;
  esac

  printf '%s' "$mode"
}

# The exact record a human has to publish for $1 to reach this box, as name / type /
# value. "Check your DNS" is not an instruction anyone can act on, and this is now the
# PREDICTABLE failure rather than an unlikely one: our own base has a wildcard, a
# partner's base has nothing, so "the partner forgot the A record" ends in a fully
# built tenant with no certificate — which looks, to the customer, exactly like a
# broken product.
#
# Classified by the HOSTNAME, not by domain_mode, so a `domain_aliases:` entry (which
# need not sit under the tenant's base at all) gets the right advice too.
dns_record_advice() { # $1=host $2=the tenant's base domain $3=this box's IP
  local host="$1" base="$2" ip="$3"
  if [[ -n "$base" && "$base" != "$PLATFORM_BASE_DOMAIN" && "$host" == *".$base" ]]; then
    dns_advice \
      "PARTNER BASE DOMAIN '$base' — there is NO wildcard covering it, so this one" \
      "record is the only thing that can ever make '$host' resolve." \
      "Ask whoever runs DNS for '$base' to publish:" \
      "" \
      "          name  : ${host%".$base"}   (fully qualified: $host)" \
      "          type  : A" \
      "          value : $ip" \
      "          TTL   : 7200 or more" \
      ""
  elif [[ "$host" == *".$PLATFORM_BASE_DOMAIN" ]]; then
    dns_advice \
      "'$host' is under our own base domain, so it rides the *.${PLATFORM_BASE_DOMAIN}" \
      "wildcard A record and needs no record of its own. Check that the wildcard still" \
      "points at this box:  A  *.${PLATFORM_BASE_DOMAIN}  ->  $ip" \
      "(the zone is edited by hand, not through ./domainio-dns.sh — DEPLOYMENT.md)."
  else
    dns_advice \
      "'$host' is a domain we do not host. At its registrar / DNS provider, publish:" \
      "" \
      "          name  : $host" \
      "          type  : A" \
      "          value : $ip" \
      "          TTL   : 7200 or more" \
      ""
  fi
  dns_advice \
    "Until that resolves, Caddy cannot answer the HTTP-01 challenge and issues NO" \
    "certificate: the tenant is built and running, and every visit fails on TLS."
}
# --- END domain helpers ---

# --- BEGIN partner attribution helpers (extracted verbatim by tests/partner-attribution.sh) ---
# Resolve the registry's THREE partner keys into the TWO values the tenant .env carries
# (SOFRA-PARTNER-PLAN §11d/§11d2, D-B2). The boolean is resolved HERE, on purpose: the
# .env — and therefore the backend, and therefore a diner's footer — then carries exactly
# one meaning, WHAT TO DISPLAY. Nothing downstream gets a second flag it could interpret
# differently. Attribution off == the same state as no partner at all: two empty values.
#
# Echoes two lines, name then url (either or both may be empty). Prints the reason and
# returns 1 on any inconsistency. Pure — no I/O, no globals but is_plausible_host — so
# tests/partner-attribution.sh can drive every branch without a box.
#
# ⚠️ MEASURED 2026-08-28, and it is the SILENT direction. The registry reader above is
# `yaml.safe_load` + `str(v)`, and Python renders a YAML boolean CAPITALISED: an entry
# written `partner_attribution: false` arrives in this shell as the string `False`, and
# `true` arrives as `True`. Proven against a fixture before this was written:
#     partner_attribution False -> str(): 'False'
#     partner_attribution True  -> str(): 'True'
# So the obvious `[[ "$REG_PARTNER_ATTRIBUTION" == "false" ]]` NEVER MATCHES, and the
# restaurant's off-switch becomes a no-op that reads as ON — the partner's name stays on
# the restaurant's public page after the restaurant asked for it to come off, and nothing
# says so. The spelling is normalised below, and anything that is not exactly
# true/false/absent is REFUSED rather than defaulted — the same posture
# TENANT_MODULES_ENFORCE takes when it rejects `1`/`yes`/`on`.
resolve_partner_attribution() { # $1=slug $2=partner_name $3=partner_url $4=partner_attribution
  local slug="$1" name="$2" url="$3" raw_flag="$4" flag host

  flag="$(printf '%s' "$raw_flag" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
  if [[ -n "$flag" && "$flag" != "true" && "$flag" != "false" ]]; then
    echo "ERROR: registry entry '$slug' has partner_attribution '$raw_flag' — must be exactly true or false (a YAML boolean), or the key omitted entirely (= true)" >&2
    echo "       It is the RESTAURANT's off-switch for the partner credit in its footer;" >&2
    echo "       a value nobody can interpret must not silently read as 'on'." >&2
    return 1
  fi

  # A contradiction, refused rather than quietly ignored — the posture the
  # domain_mode/base_domain cross-check already takes. Both of the other keys are
  # meaningless without a name to display: `partner_attribution: false` with no
  # `partner_name` reads as "the switch is doing something" when it is doing nothing,
  # and a `partner_url` with no name is a link with no text.
  if [[ -z "$name" ]]; then
    if [[ -n "$flag" ]]; then
      echo "ERROR: registry entry '$slug' sets partner_attribution '$raw_flag' but has no 'partner_name'" >&2
      echo "       The flag is only ever consulted when a partner name exists, so this entry" >&2
      echo "       claims to switch something that was never on. Add 'partner_name:', or drop" >&2
      echo "       'partner_attribution:' — an absent partner already displays nothing." >&2
      return 1
    fi
    if [[ -n "$url" ]]; then
      echo "ERROR: registry entry '$slug' sets partner_url '$url' but has no 'partner_name'" >&2
      echo "       The footer renders a LINKED NAME; a URL with no name has nothing to be." >&2
      return 1
    fi
    printf '\n'
    return 0
  fi

  # The name becomes visible text on a public page and, above, a sed REPLACEMENT and a
  # two-line protocol. A newline in it would silently truncate one of those, so it is
  # refused here rather than half-rendered.
  if [[ "$name" == *$'\n'* ]]; then
    echo "ERROR: registry entry '$slug' has a multi-line partner_name — it is one line of footer text; use a plain YAML scalar" >&2
    return 1
  fi

  # It becomes an href on a page belonging to a THIRD PARTY (the restaurant), so it is
  # https-only and a BARE HOST — no path, no query, no port, no credentials, and nothing
  # a shell or a sed replacement could reinterpret. http:// is refused rather than
  # upgraded: silently rewriting a partner's own URL is a decision, not a fix.
  if [[ -n "$url" ]]; then
    if [[ "$url" != https://* ]]; then
      echo "ERROR: registry entry '$slug' has partner_url '$url' — must start with 'https://' (http:// is refused, not upgraded)" >&2
      return 1
    fi
    host="${url#https://}"
    host="${host%/}"   # one trailing slash is idiomatic and harmless; anything else is a path
    if ! is_plausible_host "$host"; then
      echo "ERROR: registry entry '$slug' has partner_url '$url' — expected 'https://' plus a bare dotted hostname like 'https://solutioneva.com': lowercase labels, at least one dot, no path, no query, no port, no spaces." >&2
      echo "       This value becomes an href on the RESTAURANT's public page; it is not the" >&2
      echo "       place to accept something nobody has read." >&2
      return 1
    fi
  fi

  # Absent means TRUE (D-B2): the partner built and provisioned the site, so the credit
  # is the default and the restaurant opts OUT. Off yields two empty values, which is
  # byte-for-byte the state of a tenant with no partner — so switching it off and
  # re-provisioning REMOVES the credit, it does not merely stop adding it.
  if [[ "$flag" == "false" ]]; then
    printf '\n'
    return 0
  fi
  printf '%s\n%s\n' "$name" "$url"
}
# --- END partner attribution helpers ---

# Domain mode (ADR-002) + the zone this tenant lives under
# (SOFRA-PARTNER-FLEXIBILITY-PLAN §D1). Absent `domain_mode` is inferred from the
# domain, so pre-S10 entries keep working; absent `base_domain` is ours, so every
# entry that predates the field keeps its meaning.
BASE_DOMAIN="${REG_BASE_DOMAIN:-$PLATFORM_BASE_DOMAIN}"
DOMAIN_MODE="$(resolve_domain_mode "$SLUG" "$REG_DOMAIN" "$REG_DOMAIN_MODE" "$REG_BASE_DOMAIN")" || exit 1
if [[ -n "$REG_BASE_DOMAIN" && "$REG_BASE_DOMAIN" != "$PLATFORM_BASE_DOMAIN" ]]; then
  echo "NOTE: tenant '$SLUG' lives under the PARTNER base domain '$BASE_DOMAIN', not ours." >&2
  echo "      That zone has no wildcard: this tenant needs its own A record, published by" >&2
  echo "      the partner, before any certificate can issue. The DNS check below says so" >&2
  echo "      precisely if it is missing." >&2
fi

# Partner attribution (SOFRA-PARTNER-PLAN §11d, channel C). Resolved BEFORE the
# database, the containers and Caddy, so a malformed value costs a message rather
# than a half-built tenant — the same placement as the online-payments refusal.
_PARTNER_RESOLVED="$(resolve_partner_attribution "$SLUG" "$REG_PARTNER_NAME" "$REG_PARTNER_URL" "$REG_PARTNER_ATTRIBUTION")" || exit 1
PARTNER_NAME="$(printf '%s' "$_PARTNER_RESOLVED" | sed -n '1p')"
PARTNER_URL="$(printf '%s' "$_PARTNER_RESOLVED" | sed -n '2p')"
if [[ -n "$REG_PARTNER_NAME" && -z "$PARTNER_NAME" ]]; then
  echo "NOTE: tenant '$SLUG' has partner '$REG_PARTNER_NAME' but partner_attribution is off —" >&2
  echo "      no credit is displayed, and any credit this tenant carried is REMOVED by this run." >&2
fi

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
  is_plausible_host "$_a" \
    || { echo "ERROR: domain_alias '$_a' is not a plausible hostname" >&2; exit 1; }
  [[ "$_a" == "$REG_DOMAIN" ]] \
    && { echo "ERROR: domain_alias '$_a' duplicates the canonical domain" >&2; exit 1; }
  DOMAIN_ALIASES+=("$_a")
done

BOX_IP="$(curl -4 -sS --max-time 10 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
# Every hostname that did NOT resolve here, so the whole diagnostic can be repeated as
# the last thing this script says (bottom of the file). A warning printed at second 5
# of a six-minute provision scrolls away under the image pull, and with a partner base
# domain this is the likely failure, not an exotic one.
DNS_UNRESOLVED=()
dns_check() { # $1=hostname — warns, never fails (justified at the bottom of this file)
  local host="$1" ip
  ip="$(getent hosts "$host" | awk '{print $1}' | head -1 || true)"
  [[ "$ip" == "$BOX_IP" ]] && return 0
  DNS_UNRESOLVED+=("$host")
  echo "WARN: $host resolves to '${ip:-nothing}' but this box is '$BOX_IP'." >&2
  dns_record_advice "$host" "$BASE_DOMAIN" "$BOX_IP" >&2
  echo "      Continuing anyway: a fresh record may still be propagating, Caddy retries" >&2
  echo "      issuance on its own, and refusing here would abort the re-provision of a" >&2
  echo "      LIVE tenant over one resolver hiccup." >&2
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

# --- BEGIN admin-password helpers (extracted verbatim by tests/admin-password.sh) ---
# True when the same character appears three times in a row anywhere in $1.
#
# Written in bash rather than as `grep -E '(.)\1{2,}'` on purpose: that pattern needs a
# BACKREFERENCE, which POSIX ERE does not have. GNU grep happens to accept it and BusyBox
# does not, so the grep spelling would silently stop matching on an Alpine box and the
# guard below would pass everything — a check that fails open, on the one box nobody would
# think to re-test.
has_triple_run() {
  local s="$1" i
  for (( i = 2; i < ${#s}; i++ )); do
    if [[ "${s:i-2:1}" == "${s:i-1:1}" && "${s:i-1:1}" == "${s:i:1}" ]]; then return 0; fi
  done
  return 1
}

# An admin bootstrap password the backend will actually accept. See the call site for what
# happens when it does not. Bounded: at ~0.56% per candidate, ten tries fail once in 10^23
# provisions, and an unbounded loop against a future rule that rejects EVERYTHING would
# hang the provision instead of failing it.
gen_admin_password() {
  local candidate i
  for (( i = 0; i < 10; i++ )); do
    candidate="$(rand 48 24)!Aa1"
    if ! has_triple_run "$candidate"; then printf '%s' "$candidate"; return 0; fi
  done
  echo "ERROR: could not generate an admin password without a repeated run in 10 tries" >&2
  return 1
}
# --- END admin-password helpers ---

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
# Same treatment for the partner credit: `partner_name` is free text from the registry
# and lands in the same interpolated file. (The URL is already shape-checked to a bare
# https host, so it cannot contain a `$` — it is doubled anyway rather than relying on
# a rule enforced two hundred lines away.)
ENV_PARTNER_NAME="$(printf '%s' "$PARTNER_NAME" | sed -e 's/\$/$$/g')"
ENV_PARTNER_URL="$(printf '%s' "$PARTNER_URL" | sed -e 's/\$/$$/g')"

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
  #
  # But the classes are not the only rule. `StrongPasswordValidator.HasRepeatingPatterns`
  # rejects any password containing the SAME CHARACTER THREE TIMES IN A ROW — `(.)\1{2,}`
  # — and `rand` knows nothing about that. MEASURED 2026-08-18 on a real provision: the
  # generated password began `WWW`, the seeder logged "Failed to create admin user:
  # Password contains repeating patterns", and the provision died at the login smoke check
  # BELOW — after the database, the containers, the Caddy block and the certificate all
  # existed. 24 characters over a 62-symbol alphabet gives ~0.56%, about 1 provision in
  # 178: rare enough to read as a fluke, common enough to hit a paying customer.
  #
  # And it is NOT recoverable by re-running. The database now exists, so the next
  # provision takes the `keep:` path and the bootstrap credentials no longer apply — the
  # tenant needs a `--drop-db` teardown first. Which is why this is generated correctly
  # rather than merely detected.
  TENANT_ADMIN_PASSWORD="$(gen_admin_password)"
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

# Partner attribution, written on EVERY run (fresh AND existing) for the reason the
# Stripe lines are: it legitimately drifts, and the direction that matters is REMOVAL.
# A tenant that asks for its partner's credit to come off gets `partner_attribution:
# false` in the registry and a re-provision — and an implementation that only wrote
# these lines when a partner was present would leave the old values sitting in the .env
# and the credit on the page, with a green provision saying it had been applied.
# Both values are already resolved (§11d2): they are empty together or set together, and
# empty means display nothing.
set_env_line TENANT_PARTNER_NAME "$ENV_PARTNER_NAME"
set_env_line TENANT_PARTNER_URL "$ENV_PARTNER_URL"

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
    echo "       If the log says 'Password contains repeating patterns', the generated" >&2
    echo "       bootstrap password broke the backend's own policy — gen_admin_password above" >&2
    echo "       is supposed to make that impossible, so treat it as a defect in this script." >&2
    echo "       Recovery is NOT a re-run: ./deprovision-tenant.sh $SLUG --drop-db --purge first." >&2
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

# Assembled before the heredoc rather than inside it: a `$( ... )` that can exit
# non-zero inside a heredoc is how a summary line silently disappears.
DOMAIN_NOTE="domain_mode ${DOMAIN_MODE}"
if [[ "$DOMAIN_MODE" == subdomain ]]; then
  DOMAIN_NOTE="${DOMAIN_NOTE} under ${BASE_DOMAIN}"
fi
if [[ -n "$REG_BASE_DOMAIN" && "$REG_BASE_DOMAIN" != "$PLATFORM_BASE_DOMAIN" ]]; then
  DOMAIN_NOTE="${DOMAIN_NOTE} — a PARTNER-owned zone: one A record per client, no wildcard"
fi

cat <<EOF

==> Provisioned tenant '${SLUG}' (${REG_NAME})
    URL       : https://${REG_DOMAIN}   (cert issues on first hit; allow ~30s)
    Domain    : ${DOMAIN_NOTE}
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

# The DNS warning is printed at the top of the run and then buried under an image pull,
# a five-minute health wait and this summary. Repeat it — record and all — as the LAST
# thing on screen, because "the A record was never published" is the failure a partner
# base domain makes likely, and its symptom (a built tenant answering with a TLS error)
# is indistinguishable from a broken product.
#
# Deliberately a WARNING and not an exit, and the reasons are asymmetric enough to be
# worth stating: this check runs on every RE-provision too (a module upsell, a corrected
# name), the box's own resolver view is not authoritative, a record published a minute
# ago may still be propagating, and Caddy retries issuance by itself — so refusing here
# would abort healthy runs over a condition that fixes itself, and would do it after the
# tenant already exists on some earlier run. What it must never be is quiet.
if [[ ${#DNS_UNRESOLVED[@]} -gt 0 ]]; then
  {
    echo
    echo "############################################################################"
    echo "## ACTION REQUIRED — ${#DNS_UNRESOLVED[@]} hostname(s) of '${SLUG}' do NOT point at this box"
    echo "## This tenant is BUILT and RUNNING and is NOT reachable: with no A record"
    echo "## there is no certificate, so https://${REG_DOMAIN} fails on TLS."
    for _h in ${DNS_UNRESOLVED[@]+"${DNS_UNRESOLVED[@]}"}; do
      echo "##"
      echo "## $_h"
      dns_record_advice "$_h" "$BASE_DOMAIN" "$BOX_IP" | sed -e 's/^      /##   /'
    done
    echo "##"
    echo "## Re-check with:  getent hosts ${REG_DOMAIN}"
    echo "############################################################################"
  } >&2
fi
