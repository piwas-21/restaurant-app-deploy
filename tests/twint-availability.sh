#!/usr/bin/env bash
# Unit test for provision-tenant.sh's TWINT read-back
# (Stripe Connect EXPRESS — ADR-011 amendment).
#
# WHY this exists, and it is one measured failure. Enabling TWINT is a POST to the account's own
# payment-method configuration. MEASURED on a LIVE CH Express account 2026-09-05: that POST returns
# HTTP 200 with `display_preference.value: on` while `twint.available` stays FALSE, because the
# PLATFORM's twint_payments capability is inactive. In TEST mode the same call answers
# `available: true`, which is why the block was first written trusting curl --fail.
#
# So `--fail` guards a REFUSAL that never comes, and without a read-back a Swiss tenant provisions
# GREEN with no TWINT at checkout — the exact "broken purchase nobody notices until a Swiss diner
# complains" the block's own comment says it exists to prevent.
#
# These assertions are SOURCE-SHAPE, deliberately. The behaviour lives inside a curl to Stripe, and
# this repo's tests take no network — so what is pinned here is that the script READS the answer
# instead of the status code, and that it says so out loud when the answer is false.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../provision-tenant.sh"
[[ -f "$SCRIPT" ]] || { echo "cannot find provision-tenant.sh next to $HERE"; exit 1; }

fail=0
pass() { local desc="$1"; printf '  ok   %s\n' "$desc"; }
bad()  { local desc="$1"; printf '  FAIL %s\n' "$desc"; fail=1; }

# --- 1. the response is captured, not discarded --------------------------------------
# The original wrote the body to /dev/null and branched on curl's exit code alone.
if grep -qE 'TWINT_RESP="\$\(curl' "$SCRIPT"; then
  pass "the TWINT POST response is captured"
else
  bad  "the TWINT POST response is discarded — only the status code would be checked"
fi

# --- 2. twint.available is actually parsed out of it ---------------------------------
if grep -q 'get("twint", {}).get("available")' "$SCRIPT"; then
  pass "twint.available is parsed from the response"
else
  bad  "twint.available is not parsed — a 200 would still read as success"
fi

# --- 3. the TRUE branch is the only one that reports plain success -------------------
if grep -qE '\[\[ "\$TWINT_AVAILABLE" == "true" \]\]' "$SCRIPT"; then
  pass "success is conditioned on available == true"
else
  bad  "nothing conditions the success message on availability"
fi

# --- 4. the false case is LOUD, and on stderr ----------------------------------------
# It deliberately does not exit 1 (that would block every CH tenant on a Stripe approval queue we
# do not control) — so the warning is the entire safety net, and it must not be silent.
if grep -q 'WARNING: TWINT is NOT available' "$SCRIPT"; then
  pass "an unavailable TWINT is announced"
else
  bad  "an unavailable TWINT is silent — the provision would look clean"
fi
# NOTE, and it cost a debug cycle: do NOT write this as
#   grep -A 6 ... "$SCRIPT" | grep -q '>&2'
# Under `set -o pipefail`, `grep -q` exits on its first match and closes the pipe, the upstream grep
# dies of SIGPIPE (141), and pipefail reports the PIPELINE as failed — so a correct file reads as a
# broken one. Count into a variable instead; no early exit, no signal.
warn_stderr="$(grep -A 6 'WARNING: TWINT is NOT available' "$SCRIPT" | grep -c '>&2' || true)"
if [[ "${warn_stderr:-0}" -gt 0 ]]; then
  pass "the warning goes to stderr"
else
  bad  "the warning does not go to stderr"
fi

# --- 5. POSITIVE CONTROL on the instrument -------------------------------------------
# Every assertion above is a grep, and a grep that cannot match anything passes nothing. This
# proves the file is readable and the pattern style works, so an all-green run above is a real
# result rather than an empty one.
grep -q 'tenant_has_module online-payments' "$SCRIPT" \
  && pass "POSITIVE CONTROL: a known-present line is found" \
  || bad  "POSITIVE CONTROL FAILED: the script is unreadable or the grep style is broken"

echo
if [[ $fail -eq 0 ]]; then echo "twint-availability: all assertions passed"; else echo "twint-availability: FAILURES"; fi
exit $fail
