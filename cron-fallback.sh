#!/usr/bin/env bash
# Box-side redundant trigger for the sofra control-plane cron sweeps (#165).
#
# WHY THIS EXISTS
# ---------------
# On 2026-08-24 GitHub began refusing to START every scheduled job on piwas-21/sofra —
# an Actions billing block, `"steps": []`, a job that lived one second. All SIX scheduled
# workflows were down for SIX DAYS and nothing noticed. It was found because a release
# coordinator happened to open the Actions tab.
#
# A watchdog INSIDE Actions would have been killed by the same block. That is the whole
# lesson: a signal that only reports when its own reporter is alive is not a signal. So
# this runs from the box's own crontab, on the box's own clock, and needs nothing from
# GitHub at all.
#
# It is a REDUNDANT trigger, not a replacement. The workflows stay; this is the second
# path, and either one alone keeps the sweeps running.
#
# DOUBLE-FIRING
# -------------
# Measured against the live control plane on 2026-09-04, each endpoint called twice back
# to back:
#
#   trial-warnings   {"considered":0,...}                      identical both times
#   go-live          {"considered":0,"announced":0,...}        identical both times
#   retention        {"deleted":{...0,0,0}}                    identical both times
#   backup-alerts    1st {"decision":"recovered","emailed":true}
#                    2nd {"decision":"healthy","emailed":false}
#
# The first three are send-once by audit marker: firing them again sends nothing. The
# fourth is EDGE-TRIGGERED — it mails on a state TRANSITION — so a second call does not
# duplicate a mail, but an extra call can notice a transition sooner than Actions would
# have. That is a difference in timing, not in content, and it is the reason the schedule
# below is offset rather than doubled-up.
#
# USAGE
#   ./cron-fallback.sh                       # every sweep
#   ./cron-fallback.sh trial-warnings        # one sweep
#   ./cron-fallback.sh --dry-run             # show what would be called, call nothing
#
# INSTALL (see DEPLOYMENT.md for the crontab lines and why the hours are what they are).
set -euo pipefail

cd "$(dirname "$0")"

LOG="${CRON_FALLBACK_LOG:-/opt/rumi/cron-fallback.log}"
BASE="${SOFRA_BASE_URL:-https://sofrapiwas.com}"
ALL=(trial-warnings go-live backup-alerts retention)

DRY=0
TARGETS=()
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    -*) echo "ERROR: unknown flag '$arg'" >&2; exit 2 ;;
    *)
      # Whitelisted, not interpolated blindly: this value becomes part of a URL.
      ok=0
      for e in "${ALL[@]}"; do [[ "$arg" == "$e" ]] && ok=1; done
      [[ "$ok" -eq 1 ]] || { echo "ERROR: unknown endpoint '$arg' (expected one of: ${ALL[*]})" >&2; exit 2; }
      TARGETS+=("$arg")
      ;;
  esac
done
[[ ${#TARGETS[@]} -gt 0 ]] || TARGETS=("${ALL[@]}")

SECRET="$(grep -E '^SOFRA_CRON_SECRET=' .env | cut -d= -f2- | tr -d '"'"'"'' || true)"
# Fail LOUDLY rather than skipping. The caller workflows warn-and-exit-0 when the secret
# is absent, which is right for a CI job nobody depends on — but this exists precisely
# because the other path went quiet, and a fallback that silently does nothing is the
# same defect wearing a different hat.
[[ -n "$SECRET" ]] || { echo "ERROR: SOFRA_CRON_SECRET not set in $(pwd)/.env — refusing to run silently" >&2; exit 1; }

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$LOG"; }

rc=0
for ep in "${TARGETS[@]}"; do
  url="${BASE}/api/cron/${ep}"

  if [[ "$DRY" -eq 1 ]]; then
    log "DRY  ${ep} -> POST ${url}"
    continue
  fi

  # `--retry-all-errors` so a 5xx is retried too, not just a connection failure. The
  # endpoints are idempotent (see the measurement above), so a retry cannot double-send.
  resp="$(curl -sS --max-time 60 --retry 3 --retry-delay 10 --retry-all-errors \
    -X POST "$url" -H "Authorization: Bearer ${SECRET}" -w $'\n%{http_code}' 2>&1)" || true
  code="$(printf '%s' "$resp" | tail -n1)"
  body="$(printf '%s' "$resp" | sed '$d' | tr -d '\n' | cut -c1-300)"

  if [[ "$code" == "200" ]]; then
    log "OK   ${ep} 200 ${body}"
  else
    # Non-zero at the end, but keep going: one broken sweep must not stop the other three,
    # and this is the path that runs when the other one is already down.
    log "FAIL ${ep} ${code} ${body}"
    rc=1
  fi
done

exit "$rc"
