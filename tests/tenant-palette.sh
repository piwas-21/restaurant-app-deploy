#!/usr/bin/env bash
# Unit test for the PWA palette pass-through: tenants/registry.yml -> the tenant image
# build's `pwa_theme_color` / `pwa_background_color` inputs (frontend #644).
#
# WHY this exists, and it is one specific failure. The palette is not stored on the box
# and is not in any tenant .env: NEXT_PUBLIC_* are baked at frontend BUILD time, so the
# ONLY way a registry palette reaches a tenant is by being forwarded, as a workflow
# input, in one `gh workflow run` line inside provision-on-registry-merge.yml. Delete
# that one line and NOTHING fails: the registry still parses, the chain still builds an
# image, provisioning still succeeds, the tenant still comes up — wearing RUMI's red
# (#c00000), which is the frontend's default when the input is empty. A field that is
# read, validated, carried through a JSON plan and then silently dropped at the last
# step is indistinguishable from a field that works, and the tell only appears on a
# customer's phone. So the forwarding itself is asserted here.
#
# The assertion is deliberately NOT a list of two literal key names. It DERIVES the set
# of palette keys from the workflow's own candidate record and requires each one to be
# forwarded, so a third palette key added to the registry reader is covered the day it
# is added rather than the day someone remembers this file.
#
# The logic is EXTRACTED from the workflow rather than copied here, for the reason
# tests/admin-password.sh, tests/domain-base.sh and tests/partner-attribution.sh all
# give: a copy is a second source of truth that passes forever after the original
# changes.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WF="$HERE/../.github/workflows/provision-on-registry-merge.yml"
[[ -f "$WF" ]] || { echo "cannot find provision-on-registry-merge.yml from $HERE"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail=0
pass() { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; fail=1; }

# ── Extract the registry reader out of the workflow's heredoc ────────────────────────
# Between `<<'PY'` and the closing `PY`, dedented by the 10 spaces of YAML indentation.
sed -n "/<<'PY'/,/^ *PY$/p" "$WF" | sed '1d;$d' | sed 's/^          //' > "$WORK/reader.py"
grep -q 'candidates.append' "$WORK/reader.py" \
  || { echo "extraction failed — did the heredoc markers move?"; exit 1; }

# ── The key set under test, derived from the workflow, not typed here ────────────────
# Every `pwa_*` key the reader puts into a candidate record. Empty is a failure, not a
# pass: otherwise deleting BOTH sides of the pass-through would leave this file green.
# `while read` rather than `mapfile`: mapfile is bash 4+, and macOS ships bash 3.2 —
# a test that only runs on the CI runner is a test the author cannot rehearse.
PWA_KEYS=()
while IFS= read -r k; do
  [[ -n "$k" ]] && PWA_KEYS+=("$k")
done < <(grep -oE '"pwa_[a-z_]+":' "$WORK/reader.py" | tr -d '":' | sort -u)
if [[ ${#PWA_KEYS[@]} -eq 0 ]]; then
  bad "no pwa_* keys found in the workflow's candidate record — nothing to forward"
else
  pass "palette keys derived from the workflow: ${PWA_KEYS[*]}"
fi

# ── 1. Each derived key is FORWARDED to the tenant image build ───────────────────────
# The whole point of the file. `-f <key>="$VAR"` must be present in the dispatch, and
# $VAR must itself be read out of the plan — a forwarded variable that is never assigned
# expands to the empty string under `set -u`... only if it were unset, and this workflow
# would not even fail then, so both halves are checked.
for key in "${PWA_KEYS[@]}"; do
  var="$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')"
  if grep -qF -- "-f ${key}=\"\$${var}\"" "$WF"; then
    pass "$key is forwarded to build-tenant-image.yml as -f $key=\"\$$var\""
  else
    bad  "$key is read from the registry but NEVER forwarded to the tenant image build"
  fi
  if grep -qF "${var}=\"\$(jq -r \".todo[\$i].${key}" "$WF"; then
    pass "$var is read out of the provisioning plan"
  else
    bad  "$var is passed to the dispatch but never read out of plan.json"
  fi
done

# ── 2. The reader carries a registry palette into the candidate record ───────────────
run_reader() { # $1 = registry yaml body; prints candidates.json
  local dir="$WORK/run"
  rm -rf "$dir"; mkdir -p "$dir/tenants"
  printf '%s\n' "$1" > "$dir/tenants/registry.yml"
  ( cd "$dir" && python3 - candidates.json < "$WORK/reader.py" ) >/dev/null
  cat "$dir/candidates.json"
}

base_entry() { # $1 = extra keys, indented 4
  cat <<YAML
tenants:
  demo:
    managed: scripts
    status: provisioning
    box: staging
    name: Demo Restaurant
    domain: demo.sofrapiwas.com
$1
YAML
}

out="$(run_reader "$(base_entry '    pwa_theme_color: "#0f766e"
    pwa_background_color: "#f8fafc"')")"
if [[ "$(jq -r '.candidates[0].pwa_theme_color' <<<"$out")" == "#0f766e" \
   && "$(jq -r '.candidates[0].pwa_background_color' <<<"$out")" == "#f8fafc" ]]; then
  pass "a registry palette reaches the candidate record verbatim"
else
  bad  "a registry palette did not reach the candidate record: $out"
fi

# ── 3. ABSENT is empty, never the string 'None' ──────────────────────────────────────
# `str(t.get(k))` on a missing key yields "None", which would be forwarded as a literal
# colour and rejected by the frontend's #rrggbb gate — a whole tenant build failed by a
# field nobody set. The `or ""` is what prevents it, and this is what proves it.
out="$(run_reader "$(base_entry '    template: classic')")"
if [[ "$(jq -r '.candidates[0].pwa_theme_color' <<<"$out")" == "" ]]; then
  pass "an entry with no palette forwards the empty default (not 'None')"
else
  bad  "an absent palette became: $(jq -c '.candidates[0].pwa_theme_color' <<<"$out")"
fi

# ── 4. A malformed colour is REJECTED, and rejected as a whole entry ─────────────────
# Refused here rather than at the frontend, because between the two lies a ~20-minute
# image build; a rejected dispatch input reads as a broken build, not a bad registry.
for bad_value in 'red' '#12345' '#1234567' 'c00000'; do
  out="$(run_reader "$(base_entry "    pwa_theme_color: \"$bad_value\"")")"
  if [[ "$(jq '.candidates | length' <<<"$out")" -eq 0 ]] \
     && jq -e '.elsewhere[0] | test("pwa_theme_color")' <<<"$out" >/dev/null; then
    pass "palette '$bad_value' is rejected with a reason naming the field"
  else
    bad  "palette '$bad_value' was accepted: $out"
  fi
done

# ── 5. A valid uppercase colour is accepted ──────────────────────────────────────────
# #RRGGBB is as legal as #rrggbb in CSS and in the manifest; refusing it would be a
# rule nobody documented.
out="$(run_reader "$(base_entry '    pwa_background_color: "#FFEEDD"')")"
if [[ "$(jq -r '.candidates[0].pwa_background_color' <<<"$out")" == "#FFEEDD" ]]; then
  pass "an uppercase #RRGGBB is accepted"
else
  bad  "an uppercase #RRGGBB was refused: $out"
fi

if [[ "$fail" -ne 0 ]]; then
  echo "tenant-palette: FAILED"
  exit 1
fi
echo "tenant-palette: all assertions passed"
