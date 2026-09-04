#!/usr/bin/env bash
# Unit test for provision-tenant.sh's `tenant_has_module` helper.
#
# WHY this exists, and it is one specific failure. `modules` arrives from the registry as a csv
# string, so membership is tested as a PADDED needle in a PADDED haystack:
#
#     [[ " ${REG_MODULES//,/ } " == *" $1 "* ]]
#
# Every one of those spaces is load-bearing. Drop the padding around the needle and
# `online-payments` also matches a module named `no-online-payments` or `online-payments-extra`;
# drop it around the haystack and the FIRST and LAST entries in the list stop matching. Neither
# mistake is a crash — the first silently enables Stripe on a tenant that never bought it, the
# second silently refuses to enable it on one that did. Both report a successful provision.
#
# The helper was extracted from four hand-written copies of that expression (SonarCloud
# shelldre:S1192 on PR #187 is what surfaced them). Four copies meant four independent chances to
# get the padding wrong; one copy means one place to test, which is this file.
#
# The function is EXTRACTED from provision-tenant.sh rather than copied here, for the reason
# tests/partner-attribution.sh, tests/admin-password.sh and tests/domain-base.sh all give: a copy
# is a second source of truth that passes forever after the original changes.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../provision-tenant.sh"
[[ -f "$SCRIPT" ]] || { echo "cannot find provision-tenant.sh next to $HERE"; exit 1; }

FNS="$(mktemp)"
trap 'rm -f "$FNS"' EXIT

sed -n '/^# --- BEGIN module membership helpers/,/^# --- END module membership helpers/p' \
  "$SCRIPT" > "$FNS"
grep -q "^tenant_has_module() {" "$FNS" \
  || { echo "extraction failed for tenant_has_module — did the markers move?"; exit 1; }
# shellcheck disable=SC1090
source "$FNS"

FAILED=0
check() {
  local modules="$1" needle="$2" expected="$3" actual
  # shellcheck disable=SC2034  # read by tenant_has_module, which is sourced at runtime from
  # provision-tenant.sh — shellcheck cannot see through the extraction, so it reads as unused here.
  REG_MODULES="$modules"
  if tenant_has_module "$needle"; then actual=YES; else actual=NO; fi
  if [[ "$actual" == "$expected" ]]; then
    printf '  ok    modules=[%s] has %-16s -> %s\n' "$modules" "'$needle'" "$actual"
  else
    printf '  FAIL  modules=[%s] has %-16s -> %s (expected %s)\n' \
      "$modules" "'$needle'" "$actual" "$expected"
    FAILED=1
  fi
}

echo "== tenant_has_module =="

# Present, in each position — the haystack padding is what makes first and last work.
check "core,online-payments,printing" online-payments YES
check "online-payments,core"          online-payments YES
check "core,online-payments"          online-payments YES
check "online-payments"               online-payments YES

# Absent.
check "core,printing"                 online-payments NO
check ""                              online-payments NO

# The needle padding. Both of these CONTAIN the substring `online-payments` and must not match:
# without the spaces around the needle, the first would silently enable Stripe on a tenant that
# never bought it.
check "core,no-online-payments"       online-payments NO
check "core,online-payments-extra"    online-payments NO

# Not specific to online-payments — every caller passes a different module.
check "core,cashier,server"           cashier         YES
check "core,cashier,server"           kitchen-board   NO
check "core"                          core            YES

if (( FAILED )); then
  echo "tenant-module-membership: FAILED"
  exit 1
fi
echo "tenant-module-membership: all checks passed"
