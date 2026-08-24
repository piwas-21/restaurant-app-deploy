#!/usr/bin/env bash
# Unit test for the staging site address and for verify-env.sh's failure reporting.
#
# WHY this exists. deploy #146: `v2202607374190477434.megasrv.de` over https — the
# STAGING VERIFY URL every runbook named — answered `tlsv1 alert internal error` / HTTP 000 from
# a laptop and from inside the box, while every other site on the same Caddy was 200.
#
# It was never a certificate failure. That name is the box's Netcup reverse-DNS name: the
# zone is the provider's, we cannot answer an ACME challenge in it, so the box was moved
# onto `staging.fooderist.com` long ago and NOTHING in git followed. Caddy was never asked
# to serve the megasrv name, so it had no certificate for that SNI and aborted the
# handshake — correct behaviour, opaque symptom.
#
# Two regressions are frozen here, because both are invisible to a linter and to CI:
#   1. no committed file may hand a human or a build an `https://…megasrv.de` URL again;
#   2. verify-env.sh must SAY why a probe returned 000 — the bare "HTTP 000" in the issue
#      is what made a five-second diagnosis take a day.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
VERIFY="$ROOT/verify-env.sh"
[[ -x "$VERIFY" ]] || { echo "cannot find an executable verify-env.sh next to $HERE"; exit 1; }

fail=0
pass() { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; fail=1; }

# ── 1. No box hostname is ever offered as an https:// endpoint ──────────────────
echo "staging site address:"

# Mentions in prose are fine and wanted (they explain the trap). A URL is not: it is
# something a human pastes or a build bakes in, and it can never work.
if hits=$(grep -rIn --exclude-dir=.git 'https://[a-zA-Z0-9.-]*\(megasrv\|happysrv\)\.de' "$ROOT" 2>/dev/null); then
  bad "a Netcup box hostname is offered as an https:// URL:"
  printf '       %s\n' "$hits"
else
  pass "no committed file hands out an https://*.megasrv.de / *.happysrv.de URL"
fi

# The shorthand every runbook tells a human to run must point at the name the box
# actually serves.
if grep -qE '^\s+staging\)\s+HOST="https://staging\.fooderist\.com"' "$VERIFY"; then
  pass "verify-env.sh staging -> https://staging.fooderist.com (the name Caddy holds a cert for)"
else
  bad "verify-env.sh's 'staging' shorthand no longer resolves to staging.fooderist.com"
fi

# The compose default is the last line of defence for a box whose .env forgets the var:
# it must still be a name we can get a certificate for.
if grep -qE 'STAGING_DOMAIN: "\$\{STAGING_DOMAIN:-staging\.fooderist\.com\}"' "$ROOT/docker-compose.prod.yml"; then
  pass "compose defaults STAGING_DOMAIN to a name whose zone we control"
else
  bad "the STAGING_DOMAIN default is gone or is not staging.fooderist.com"
fi

# ── 2. verify-env.sh names the cause of a 000 ──────────────────────────────────
echo
echo "verify-env.sh failure reporting:"

# A name that can never resolve (RFC 2606 reserves .invalid), so this needs no network
# and cannot be a flake.
out=$("$VERIFY" https://verify-env-test.invalid 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 1 ]]; then
  pass "an unreachable host exits 1"
else
  bad "expected exit 1 for an unreachable host, got $rc"
fi
if grep -q "why: DNS" <<<"$out"; then
  pass "a name that does not resolve is reported as DNS, not as a bare 000"
else
  bad "no 'why: DNS' line — a 000 is unexplained again:"; printf '       %s\n' "$out"
fi

# Usage still guards a typo'd environment name rather than probing something random.
"$VERIFY" >/dev/null 2>&1 && rc=0 || rc=$?
if [[ $rc -eq 2 ]]; then
  pass "no argument prints usage and exits 2"
else
  bad "expected exit 2 with no argument, got $rc"
fi

echo
if [[ $fail -eq 0 ]]; then
  echo "staging-domain/verify-env: all checks passed"
else
  echo "staging-domain/verify-env: FAILURES above"; exit 1
fi
