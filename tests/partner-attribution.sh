#!/usr/bin/env bash
# Unit test for provision-tenant.sh's partner-attribution contract
# (SOFRA-PARTNER-PLAN §11d/§11d2, D-B2).
#
# WHY this exists, and it is one specific failure. The registry entry is read by
# `yaml.safe_load` + `str(v)`, and Python renders a YAML boolean CAPITALISED — a
# restaurant that writes `partner_attribution: false` produces the shell string
# `False`. The obvious comparison against `"false"` therefore never matches, and the
# result is not a crash: the partner's name STAYS in the restaurant's footer after the
# restaurant asked for it to come off, and the provision reports success. That is the
# whole point of this file — every other assertion here is cheap, and this one is the
# reason the file was written.
#
# The second property is the one a naive "only write it when present" implementation
# gets wrong: attribution OFF must REMOVE an existing credit from a tenant .env, not
# merely decline to add one. It is asserted against the real set_env_line, on a real
# temporary .env.
#
# The functions are EXTRACTED from provision-tenant.sh rather than copied here, for the
# reason tests/admin-password.sh and tests/domain-base.sh both give: a copy is a second
# source of truth that passes forever after the original changes.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../provision-tenant.sh"
TPL="$HERE/../tenants/templates/tenant.env.tpl"
[[ -f "$SCRIPT" ]] || { echo "cannot find provision-tenant.sh next to $HERE"; exit 1; }

FNS="$(mktemp)"
WORK="$(mktemp -d)"
trap 'rm -rf "$FNS" "$WORK"' EXIT

# is_plausible_host lives in the domain block and partner_url reuses it deliberately —
# one hostname rule for the domain, the aliases, the base and now the partner link.
sed -n '/^# --- BEGIN domain helpers/,/^# --- END domain helpers/p' "$SCRIPT" >  "$FNS"
sed -n '/^# --- BEGIN partner attribution helpers/,/^# --- END partner attribution helpers/p' "$SCRIPT" >> "$FNS"
# set_env_line + its escape helper are not inside a marker block; take them by their
# own definitions, still from the original file.
sed -n '/^sed_escape() {/,/^}/p'   "$SCRIPT" >> "$FNS"
sed -n '/^set_env_line() {/,/^}/p' "$SCRIPT" >> "$FNS"
for fn in is_plausible_host resolve_partner_attribution sed_escape set_env_line; do
  grep -q "^${fn}() {" "$FNS" || { echo "extraction failed for ${fn} — did the markers move?"; exit 1; }
done
# shellcheck disable=SC1090
source "$FNS"

fail=0
pass() { local desc="$1"; printf '  ok   %s\n' "$desc"; }
bad()  { local desc="$1"; printf '  FAIL %s\n' "$desc"; fail=1; }

# The partner under test, named once: the same brand and link appear in a couple of
# dozen assertions, and a literal repeated that often is one typo away from a test that
# asserts something nobody meant.
PARTNER="Solution Eva"
PARTNER_LINK="https://solutioneva.com"

RC=0; NAME=""; URL=""; ERR=""
run_partner() { # $1=slug $2=name $3=url $4=attribution
  local slug="$1" name="$2" url="$3" flag="$4" out errf
  errf="$(mktemp)"
  RC=0
  out="$(resolve_partner_attribution "$slug" "$name" "$url" "$flag" 2>"$errf")" || RC=$?
  NAME="$(printf '%s' "$out" | sed -n '1p')"
  URL="$(printf '%s'  "$out" | sed -n '2p')"
  ERR="$(cat "$errf")"
  rm -f "$errf"
}

# ── The measurement this file exists for ─────────────────────────────────────────
# Not an assumption about python: the actual reader is run against a fixture, and its
# output is fed to the function under test. If yaml/str ever stop capitalising, this
# still passes — and if the function is "simplified" to compare against `false`, it
# goes red here first.
echo "the registry reader's actual spelling of a YAML boolean:"
# Heredoc deliberately UNQUOTED so the fixture carries the same brand as every
# assertion below — one name, one place to change it.
cat > "$WORK/fixture.yml" <<YML
version: 1
tenants:
  on_by_default:
    partner_name: ${PARTNER}
    partner_url: ${PARTNER_LINK}
  switched_off:
    partner_name: ${PARTNER}
    partner_url: ${PARTNER_LINK}
    partner_attribution: false
  switched_on:
    partner_name: ${PARTNER}
    partner_attribution: true
YML
read_flag() { # $1=slug — exactly the reader provision-tenant.sh uses, on this fixture
  local slug="$1"
  python3 - "$WORK/fixture.yml" "$slug" <<'PY'
import sys, yaml
reg = yaml.safe_load(open(sys.argv[1]))
print(str((reg["tenants"][sys.argv[2]]).get("partner_attribution", "")))
PY
}
RAW_OFF="$(read_flag switched_off)"
RAW_ON="$(read_flag switched_on)"
echo "  partner_attribution: false -> shell string '${RAW_OFF}'"
echo "  partner_attribution: true  -> shell string '${RAW_ON}'"
if [[ "$RAW_OFF" == "False" && "$RAW_ON" == "True" ]]; then
  pass "the reader really does capitalise (measured, not assumed)"
else
  bad "the reader now spells them '${RAW_OFF}'/'${RAW_ON}' — re-read the comment in provision-tenant.sh"
fi
# The literal 'false' a `[[ ... == "false" ]]` would have compared against must NOT be
# what the reader produces; if it ever is, the trap comment is stale.
[[ "$RAW_OFF" != "false" ]] \
  && pass "a bare == 'false' comparison would still miss it" \
  || bad "the reader now emits lowercase 'false' — the trap comment needs updating"

echo "resolution:"
run_partner t "$PARTNER" "$PARTNER_LINK" "$RAW_OFF"
if [[ "$RC" -eq 0 && -z "$NAME" && -z "$URL" ]]; then
  pass "attribution off (the reader's own '${RAW_OFF}') displays nothing"
else bad "attribution off yielded name='$NAME' url='$URL' rc=$RC — THE OFF-SWITCH IS A NO-OP"; fi

run_partner t "$PARTNER" "$PARTNER_LINK" "$RAW_ON"
if [[ "$RC" -eq 0 && "$NAME" == "$PARTNER" && "$URL" == "$PARTNER_LINK" ]]; then
  pass "attribution on displays the name and the url"
else bad "attribution on yielded name='$NAME' url='$URL' rc=$RC"; fi

run_partner t "$PARTNER" "$PARTNER_LINK" ""
if [[ "$RC" -eq 0 && "$NAME" == "$PARTNER" ]]; then
  pass "absent attribution means TRUE (D-B2)"
else bad "absent attribution did not default to on: name='$NAME' rc=$RC"; fi

run_partner t "" "" ""
if [[ "$RC" -eq 0 && -z "$NAME" && -z "$URL" ]]; then
  pass "no partner at all: two empty values, no error"
else bad "an entry with no partner keys was not inert: name='$NAME' url='$URL' rc=$RC"; fi

run_partner t "$PARTNER" "" "$RAW_ON"
if [[ "$RC" -eq 0 && "$NAME" == "$PARTNER" && -z "$URL" ]]; then
  pass "a name with no url is a credit with no link, not an error"
else bad "name-only entry rejected: name='$NAME' url='$URL' rc=$RC"; fi

# ── Loud refusals ────────────────────────────────────────────────────────────────
echo "refusals:"
for v in 1 yes on "" 0 no off TRUE_ish maybe; do
  [[ -z "$v" ]] && continue
  # The four spellings the function must ACCEPT are exercised in their own loop below.
  case "$v" in
    true|false|True|False) continue ;;
    *) ;;
  esac
  run_partner t "$PARTNER" "" "$v"
  if [[ "$RC" -ne 0 && "$ERR" == *"partner_attribution"* ]]; then
    pass "attribution '$v' refused loudly"
  else bad "attribution '$v' was ACCEPTED (rc=$RC) — a guessed value must not read as 'on'"; fi
done
# Case is normalised, not refused: YAML 1.1 spells a boolean several ways and the
# reader capitalises one of them itself.
for v in TRUE True true; do
  run_partner t "$PARTNER" "" "$v"
  [[ "$RC" -eq 0 && "$NAME" == "$PARTNER" ]] && pass "attribution '$v' reads as on" || bad "attribution '$v' rc=$RC name='$NAME'"
done
for v in FALSE False false; do
  run_partner t "$PARTNER" "" "$v"
  [[ "$RC" -eq 0 && -z "$NAME" ]] && pass "attribution '$v' reads as off" || bad "attribution '$v' rc=$RC name='$NAME'"
done

run_partner t "" "" "False"
if [[ "$RC" -ne 0 && "$ERR" == *"no 'partner_name'"* ]]; then
  pass "attribution with no partner_name is refused as a contradiction"
else bad "attribution without a name was tolerated (rc=$RC)"; fi

run_partner t "" "$PARTNER_LINK" ""
if [[ "$RC" -ne 0 && "$ERR" == *"no 'partner_name'"* ]]; then
  pass "partner_url with no partner_name is refused"
else bad "a url with no name was tolerated (rc=$RC)"; fi

# It becomes an href on a page belonging to the RESTAURANT.
for u in \
  "http://solutioneva.com" \
  "solutioneva.com" \
  "https://solutioneva.com/clients?x=1" \
  "https://solutioneva.com:8443" \
  "https://solution eva.com" \
  "https://localhost" \
  'https://x.com;curl evil.sh' \
  'javascript:alert(1)' \
  'https://$(whoami).com' ; do
  run_partner t "$PARTNER" "$u" ""
  if [[ "$RC" -ne 0 && "$ERR" == *"partner_url"* ]]; then pass "url '$u' refused"
  else bad "url '$u' was ACCEPTED (rc=$RC url='$URL') — it becomes a public href"; fi
done
for u in "$PARTNER_LINK" "https://www.solution-eva.co.uk" "https://solutioneva.com/"; do
  run_partner t "$PARTNER" "$u" ""
  [[ "$RC" -eq 0 ]] && pass "url '$u' accepted" || bad "legitimate url '$u' refused: $ERR"
done

run_partner t "$(printf 'Solution\nEva')" "" ""
[[ "$RC" -ne 0 ]] && pass "a multi-line partner_name is refused" || bad "a multi-line name was accepted"

# ── The property a naive implementation gets wrong ────────────────────────────────
# Attribution off must REMOVE the credit from an already-provisioned tenant's .env.
# Asserted against the real set_env_line, on a real file, because "we simply do not
# write the line" passes every test above and still leaves the name on the page.
echo "off REMOVES an existing credit (not merely 'does not add' it):"
# set_env_line is taken from provision-tenant.sh verbatim, and it uses GNU `sed -i EXPR`.
# BSD sed (a macOS laptop) reads that EXPR as the backup extension and then fails on the
# filename, so this section runs only where the box's sed semantics hold. It is NEVER
# skipped in CI — a silently skipped assertion is the shape this repo keeps being bitten
# by, so an unexpected sed there is a hard failure rather than a notice.
if ! sed --version >/dev/null 2>&1; then
  if [[ -n "${CI:-}" ]]; then
    echo "  FAIL the CI runner has a non-GNU sed — set_env_line's own 'sed -i' would fail on the box too"
    fail=1
  else
    echo "  SKIP (BSD sed: set_env_line's GNU 'sed -i EXPR' cannot run here; CI runs it)"
  fi
else
# set_env_line resolves $TENANT_DIR at CALL time (its own comment says so), so this is
# the whole of the fixture wiring.
# shellcheck disable=SC2034  # read by the extracted set_env_line, not by this file
TENANT_DIR="$WORK"
# Written with sed to a NEW file rather than in place: `sed -i` is the one flag whose
# spelling differs between GNU (box, CI) and BSD (a laptop), and a test that only runs
# on one of them is a test people stop running. set_env_line's own `sed -i` is fine —
# it only ever executes on the box.
sed -e "s|^TENANT_PARTNER_NAME=.*|TENANT_PARTNER_NAME=${PARTNER}|" \
    -e "s|^TENANT_PARTNER_URL=.*|TENANT_PARTNER_URL=${PARTNER_LINK}|" \
    "$TPL" > "$WORK/.env"
grep -q "^TENANT_PARTNER_NAME=${PARTNER}$" "$WORK/.env" \
  && pass "positive control: the .env starts out carrying a credit" \
  || bad "positive control failed — the fixture .env has no credit to remove"

run_partner t "$PARTNER" "$PARTNER_LINK" "$RAW_OFF"
set_env_line TENANT_PARTNER_NAME "$NAME"
set_env_line TENANT_PARTNER_URL "$URL"
if grep -q '^TENANT_PARTNER_NAME=$' "$WORK/.env" && grep -q '^TENANT_PARTNER_URL=$' "$WORK/.env"; then
  pass "a re-provision with attribution off blanks both lines"
else
  bad "the credit SURVIVED a re-provision with attribution off: $(grep '^TENANT_PARTNER_' "$WORK/.env")"
fi

# And back on again, so the blank is a value and not a one-way door.
run_partner t "$PARTNER" "$PARTNER_LINK" "$RAW_ON"
set_env_line TENANT_PARTNER_NAME "$NAME"
set_env_line TENANT_PARTNER_URL "$URL"
grep -q "^TENANT_PARTNER_URL=${PARTNER_LINK}$" "$WORK/.env" \
  && pass "switching it back on restores both lines" \
  || bad "re-enabling did not restore the credit: $(grep '^TENANT_PARTNER_' "$WORK/.env")"

# A name containing sed metacharacters must land verbatim — the same escaping path
# `name` and `city` take. `&` is the one that silently duplicates the pattern.
set_env_line TENANT_PARTNER_NAME 'A&B | Partners \ Co'
line="$(grep '^TENANT_PARTNER_NAME=' "$WORK/.env")"
[[ "$line" == 'TENANT_PARTNER_NAME=A&B | Partners \ Co' ]] \
  && pass "sed metacharacters in a partner name survive the render" \
  || bad "escaping mangled the name: $line"

fi

# ── The template must ship the keys, empty ───────────────────────────────────────
echo "template:"
for k in TENANT_PARTNER_NAME TENANT_PARTNER_URL; do
  grep -q "^${k}=$" "$TPL" \
    && pass "$TPL renders ${k} empty by default" \
    || bad "$TPL does not carry an empty ${k}= line (a fresh tenant would have no key to rewrite)"
done
# Comment lines are excluded on purpose: the template EXPLAINS why it does not use a
# placeholder, and a grep for the bare token would match its own explanation.
grep -qE '^[^#]*__PARTNER_NAME__' "$TPL" \
  && bad "the template uses a __PARTNER_NAME__ placeholder — set_env_line rewrites it on every run, so a failed rewrite would print the placeholder into a diner's footer" \
  || pass "no placeholder to leak into a footer (safe-by-default empties, as STRIPE_*)"

# ── The two writes must be UNCONDITIONAL ─────────────────────────────────────────
# The blanking above only removes a credit if provision-tenant.sh writes both lines on
# EVERY run. A `if [[ -n "$PARTNER_NAME" ]]` around them would pass every assertion in
# this file and still leave a withdrawn credit on the page, so the shape is asserted
# structurally: top-level calls, at column 0, exactly like the STRIPE_ lines they copy.
echo "the writes are unconditional:"
for k in TENANT_PARTNER_NAME TENANT_PARTNER_URL; do
  grep -q "^set_env_line ${k} " "$SCRIPT" \
    && pass "set_env_line ${k} is called at top level (every run, fresh and re-provision)" \
    || bad "set_env_line ${k} is absent or nested — a withdrawn credit would survive a re-provision"
done

# ── No live tenant is credited by this change ────────────────────────────────────
# The keys are documented in the registry's field notes and set on NOBODY. A future
# edit that credits a live tenant is a decision someone should make on purpose.
if grep -nE '^[[:space:]]+partner_(name|url|attribution):' "$HERE/../tenants/registry.yml" >/dev/null; then
  bad "a registry ENTRY now carries a partner_* key — that publishes a name on a live site"
else
  pass "no registry entry carries partner attribution (documented only)"
fi

[[ "$fail" -eq 0 ]] || { echo "FAILED"; exit 1; }
echo "all partner-attribution checks passed"
