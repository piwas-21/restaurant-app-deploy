#!/usr/bin/env bash
# Unit test for provision-tenant.sh's admin bootstrap password generator.
#
# WHY this exists. On 2026-08-18 a real provision died at the seeded-admin login check
# because the generated password began `WWW`: the backend's own policy
# (`StrongPasswordValidator.HasRepeatingPatterns`, `(.)\1{2,}`) rejects three identical
# characters in a row, and the generator knew nothing about that rule. The tenant was
# fully built by then — database, containers, Caddy block, certificate — and had no admin
# account. ~0.56% of first provisions (24 characters over a 62-symbol alphabet), which is
# about one in 178: rare enough to read as a fluke, common enough to hit a paying customer.
# Worse, it is not recoverable by re-running — the database exists, so the bootstrap
# credentials no longer apply and the tenant needs a `--drop-db` teardown first.
#
# The functions are EXTRACTED from provision-tenant.sh between its markers rather than
# copied here. A copy is a second source of truth that passes forever after the original
# changes, and this whole class of bug is "two places that were supposed to agree".
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../provision-tenant.sh"
[ -f "$SCRIPT" ] || { echo "cannot find provision-tenant.sh next to $HERE"; exit 1; }

FNS="$(mktemp)"
trap 'rm -f "$FNS"' EXIT
# `rand` (which the generator calls) plus everything between the markers.
grep -E '^rand\(\) \{' "$SCRIPT" > "$FNS"
sed -n '/^# --- BEGIN admin-password helpers/,/^# --- END admin-password helpers/p' "$SCRIPT" >> "$FNS"
grep -q 'gen_admin_password()' "$FNS" || { echo "extraction failed — did the markers move?"; exit 1; }
grep -q '^rand() {' "$FNS" || { echo "extraction missed rand()"; exit 1; }
# shellcheck disable=SC1090
source "$FNS"

fail=0
check() { # <description> <expected 0|1> <string>
  local desc="$1" want="$2" s="$3" got=0
  has_triple_run "$s" || got=1
  if [ "$got" = "$want" ]; then printf '  ok   %s\n' "$desc"
  else printf '  FAIL %s (wanted %s, got %s)\n' "$desc" "$want" "$got"; fail=1; fi
}

echo "has_triple_run:"
# 0 = "yes, it has a run". The first case is the EXACT shape that broke the real provision.
check "leading run (the 2026-08-18 failure: WWW…)" 0 'WWWane5xQ7bTk2mPqRs1!Aa1'
check "run in the middle"                          0 'abcQQQdef'
check "run at the very end"                         0 'abcdefZZZ'
check "run of four"                                 0 'abGGGGhi'
check "a DOUBLE is allowed — the rule is three"     1 'abcQQdef'
check "the mandatory !Aa1 suffix is itself clean"   1 '!Aa1'
check "short strings do not crash the scan"         1 'ab'
check "empty string"                                1 ''

echo "gen_admin_password:"
draws=500
bad=0
for _ in $(seq 1 "$draws"); do
  p="$(gen_admin_password)"
  has_triple_run "$p" && bad=$((bad + 1))
  case "$p" in *'!Aa1') ;; *) echo "  FAIL suffix lost: $p"; fail=1 ;; esac
  # 24 random + the 4-character suffix. A shorter one would mean `rand` silently
  # produced fewer characters than asked for, which is how the class guarantee is lost.
  [ "${#p}" -eq 28 ] || { echo "  FAIL length ${#p}, expected 28"; fail=1; }
done
if [ "$bad" -eq 0 ]; then printf '  ok   %s generated passwords, none with a repeated run\n' "$draws"
else printf '  FAIL %s of %s generated passwords had a repeated run\n' "$bad" "$draws"; fail=1; fi

# Distinctness: the backend also requires a minimum number of DIFFERENT characters, and a
# generator that satisfied the run rule by shrinking the alphabet would trade one policy
# violation for another.
p="$(gen_admin_password)"
distinct="$(printf '%s' "$p" | fold -w1 | sort -u | wc -l | tr -d ' ')"
if [ "$distinct" -ge 12 ]; then printf '  ok   %s distinct characters\n' "$distinct"
else printf '  FAIL only %s distinct characters\n' "$distinct"; fail=1; fi

[ "$fail" -eq 0 ] || { echo "FAILED"; exit 1; }
echo "all admin-password checks passed"
