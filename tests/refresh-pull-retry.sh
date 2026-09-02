#!/usr/bin/env bash
# What `refresh-tenant-images.sh` does when the box cannot reach GHCR.
#
# This exists because it happened, on a release, to a paying tenant. 2026-09-02: the frontend
# release reached prod, and `release-tenant-images.yml` failed twice — including on a re-run —
# with `net/http: TLS handshake timeout` against ghcr.io, leaving kebabdilhan on the previous
# image. Measured on the box afterwards: 2 of 5 TLS handshakes to ghcr.io hung past 25s while 3
# finished in under a second, with DNS, load and disk all clean.
#
# The property under test is not "it retries" — it is that it NEVER reports success while the
# tenant is stale. A fallback onto whatever sits in the local image cache would do exactly that,
# and staleness is the failure this whole script exists to end.
#
# `docker` is stubbed on PATH, so no daemon and no network are involved.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../refresh-tenant-images.sh"
[[ -f "$SCRIPT" ]] || { echo "cannot find refresh-tenant-images.sh next to $HERE"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
pass() { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; fail=1; }

FNS="$TMP/fns.sh"
sed -n '/^# --- BEGIN pull_service/,/^# --- END pull_service/p' "$SCRIPT" > "$FNS"
grep -q 'pull_service()' "$FNS" || { echo "extraction failed — did the markers move?"; exit 1; }
grep -q 'roll_service()' "$FNS" || { echo "extraction failed — did the markers move?"; exit 1; }

# A `docker` stub whose behaviour is driven by files, so each scenario is one line of setup.
#   $TMP/compose_pull_fails_until  compose pull fails while the attempt counter is below this
#   $TMP/direct_pull_ok            'yes' => a plain `docker pull` succeeds
mkdir -p "$TMP/bin" "$TMP/tenant"
cat > "$TMP/bin/docker" <<'STUB'
#!/usr/bin/env bash
log() { printf '%s\n' "$*" >> "$TMPDIR_FOR_STUB/calls"; }
if [[ "${1:-}" == "compose" ]]; then
  shift
  case "${1:-}" in
    pull)
      n=$(( $(cat "$TMPDIR_FOR_STUB/attempts" 2>/dev/null || echo 0) + 1 ))
      echo "$n" > "$TMPDIR_FOR_STUB/attempts"
      log "compose-pull#$n"
      until_n="$(cat "$TMPDIR_FOR_STUB/compose_pull_fails_until" 2>/dev/null || echo 0)"
      (( n > until_n )) && exit 0 || exit 1
      ;;
    config) log "compose-config"; echo "ghcr.io/piwas-21/restaurant-app-frontend:tenant-acme"; exit 0 ;;
    *) exit 0 ;;
  esac
fi
if [[ "${1:-}" == "pull" ]]; then
  log "direct-pull"
  [[ "$(cat "$TMPDIR_FOR_STUB/direct_pull_ok" 2>/dev/null || echo no)" == "yes" ]] && exit 0 || exit 1
fi
exit 0
STUB
chmod +x "$TMP/bin/docker"
export PATH="$TMP/bin:$PATH"
export TMPDIR_FOR_STUB="$TMP"
# Zero backoff: the test is about the DECISIONS, not about waiting out 30s of real sleeps three
# times over. The default (10s) is exercised on the box, not here.
export PULL_BACKOFF_BASE=0

# shellcheck source=/dev/null
. "$FNS"

reset() { : > "$TMP/calls"; echo 0 > "$TMP/attempts"; echo "${1:-0}" > "$TMP/compose_pull_fails_until"; echo "${2:-no}" > "$TMP/direct_pull_ok"; }
calls() { tr '\n' ' ' < "$TMP/calls"; }
count() { grep -c "$1" "$TMP/calls" 2>/dev/null || true; }

echo "a healthy registry costs exactly one call:"
reset 0 no
if pull_service "$TMP/tenant" frontend-acme >/dev/null 2>&1 && [[ "$(count compose-pull)" == 1 ]]; then
  pass "one compose pull, no retry, no fallback"
else
  bad  "expected a single compose pull, calls were: $(calls)"
fi

echo "a flaky registry is retried rather than surrendered to:"
reset 2 no          # first two compose pulls fail, the third works
if pull_service "$TMP/tenant" frontend-acme >/dev/null 2>&1 \
   && [[ "$(count compose-pull)" == 3 && "$(count direct-pull)" == 0 ]]; then
  pass "succeeds on the third attempt without needing the fallback"
else
  bad  "expected 3 compose pulls and no direct pull, calls were: $(calls)"
fi

echo "when compose pull is exhausted it falls back to a DIRECT pull:"
# `docker compose pull` re-resolves the manifest even when the tag is already local, so it can
# fail where a plain `docker pull` of the same image succeeds — that is what happened on the box.
reset 99 yes
if pull_service "$TMP/tenant" frontend-acme >/dev/null 2>&1 \
   && [[ "$(count compose-pull)" == 3 && "$(count direct-pull)" == 1 ]]; then
  pass "3 compose attempts, then one direct pull that succeeds"
else
  bad  "expected 3 compose pulls then a direct pull, calls were: $(calls)"
fi

echo "and it REFUSES when nothing could be fetched — the property that matters:"
reset 99 no
if pull_service "$TMP/tenant" frontend-acme >/dev/null 2>&1; then
  bad  "returned success with no image fetched — the tenant would be left stale and reported fine"
else
  pass "returns non-zero, so the caller records the tenant as FAILED instead of stale"
fi

echo "an unresolvable service name is refused rather than guessed at:"
# The direct pull SUCCEEDS in this stub, deliberately. With it failing too, the refusal comes from
# the failed pull and the `[[ -z "$image" ]]` guard is never the thing under test — deleting that
# guard outright still passed. Now only the guard can produce this result.
reset 99 yes
cat > "$TMP/bin/docker" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == "compose" && "${2:-}" == "config" ]] && exit 1   # no image resolves
[[ "${1:-}" == "compose" ]] && exit 1                            # compose pull always fails
[[ "${1:-}" == "pull" ]] && exit 0                               # a direct pull WOULD work
exit 0
STUB
chmod +x "$TMP/bin/docker"
if pull_service "$TMP/tenant" frontend-nope >/dev/null 2>&1; then
  bad  "returned success although no image could even be resolved"
else
  pass "returns non-zero when the service has no resolvable image"
fi

echo "the ROLL never goes back to the registry — the whole point of the retry above:"
# This is the call site the previous round left untested, and it is where the 2026-09-02 incident
# actually lived: both tenant services declare `pull_policy: always`, so a bare `up -d` pulls again
# and the flaky handshake kills the roll anyway. The stub below FAILS every registry-touching
# invocation, so the only way this can pass is if the roll asks for none.
: > "$TMP/calls"
cat > "$TMP/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TMPDIR_FOR_STUB/calls"
# A dead registry: anything that would reach out fails.
for a in "$@"; do [[ "$a" == "--pull" ]] && seen_pull_flag=1; done
if [[ "${1:-}" == "pull" ]] || { [[ "${1:-}" == "compose" && "${2:-}" == "pull" ]]; }; then exit 1; fi
if [[ "${1:-}" == "compose" && "${2:-}" == "up" && "${seen_pull_flag:-}" != "1" ]]; then exit 1; fi
exit 0
STUB
chmod +x "$TMP/bin/docker"
if roll_service "$TMP/tenant" frontend-acme >/dev/null 2>&1; then
  pass "the roll succeeds against a dead registry"
else
  bad  "the roll tried to reach the registry: $(calls)"
fi
if grep -q -- '--pull never' "$TMP/calls"; then
  pass "it passes --pull never"
else
  bad  "no --pull never in the roll: $(calls)"
fi
if grep -q -- '--no-deps' "$TMP/calls"; then
  pass "it passes --no-deps, so a frontend roll does not drag the backend image through GHCR"
else
  bad  "no --no-deps in the roll: $(calls)"
fi

exit "$fail"
