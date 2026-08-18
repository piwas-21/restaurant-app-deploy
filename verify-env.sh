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

code() {
  local url="$1"
  curl -sS -o /dev/null -w '%{http_code}' --max-time 12 "$url" 2>/dev/null || echo "000"
  return 0
}

echo "==> $HOST"
FE=$(code "$HOST/"); HE=$(code "$HOST/api/health")
echo "   frontend /        : $FE"
echo "   backend  /api/health: $HE"

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
