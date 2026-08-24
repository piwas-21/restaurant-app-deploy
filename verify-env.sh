#!/usr/bin/env bash
# Health-check a RUMI environment end-to-end from the outside. One command instead
# of hand-running curl/openssl each time.
#   ./verify-env.sh staging     # https://staging.fooderist.com
#   ./verify-env.sh prod        # https://www.rumirestaurant.ch
#   ./verify-env.sh https://any.host
# Exit 0 iff frontend + /api/health both return 200. Prints cert + build identity.
set -uo pipefail

case "${1:-}" in
  staging) HOST="https://staging.fooderist.com" ;;
  prod)    HOST="https://www.rumirestaurant.ch" ;;
  https://*) HOST="$1" ;;
  *) echo "usage: $0 <staging|prod|https://host>" >&2; exit 2 ;;
esac
DOMAIN="${HOST#https://}"

# A bare "HTTP 000" is what got reported in deploy #146 and it says nothing: DNS,
# TCP and TLS failures all look identical from the outside. curl already knows
# which one it was, so probe() hands the exit code back with the status code.
# (It is returned through stdout, not a global — the caller runs this in a command
# substitution, i.e. a subshell, so a global assigned in here would be lost.)
probe() {
  local url="$1" out="" rc=0
  out=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 12 "$url" 2>/dev/null) || rc=$?
  [[ -z "$out" ]] && out="000"
  printf '%s %s' "$out" "$rc"
}

why() {
  case "$1" in
    6)  echo "DNS — '$DOMAIN' does not resolve from here (wrong name, missing A record, or a local resolver cache)" ;;
    7)  echo "TCP — nothing accepted a connection on :443" ;;
    28) echo "timed out" ;;
    35|58|59|60|77|91)
        echo "TLS — handshake/certificate failure. Caddy aborts an unknown SNI with 'tlsv1 alert internal error': is this host really a site address in the box's Caddyfile, and is its DNS zone one we control (ACME cannot issue for a *.megasrv.de box hostname)?" ;;
    *)  echo "curl exit $1" ;;
  esac
}

echo "==> $HOST"
read -r FE FE_ERR <<<"$(probe "$HOST/")"
read -r HE HE_ERR <<<"$(probe "$HOST/api/health")"
echo "   frontend /        : $FE"
[[ "$FE" == "000" ]] && echo "     why: $(why "$FE_ERR")"
echo "   backend  /api/health: $HE"
[[ "$HE" == "000" ]] && echo "     why: $(why "$HE_ERR")"

echo "==> TLS cert"
echo | openssl s_client -connect "${DOMAIN}:443" -servername "$DOMAIN" 2>/dev/null \
  | openssl x509 -noout -issuer -subject -enddate 2>/dev/null | sed 's/^/   /' \
  || echo "   (no cert / handshake failed)"

echo "==> build identity (/api/version)"
curl -sS --max-time 12 "$HOST/api/version" 2>/dev/null | sed 's/^/   /'; echo

if [[ "$FE" == "200" && "$HE" == "200" ]]; then
  echo "==> OK: $HOST is healthy"; exit 0
else
  echo "==> FAIL: frontend=$FE api/health=$HE" >&2; exit 1
fi
