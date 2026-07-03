#!/usr/bin/env bash
# Thin wrapper over the domainio DNS API that bakes in its quirks (field is `host`
# not `name`; ttl must be >= 7200) so DNS ops are one command, not trial-and-error.
# Requires DOMAINIO_API_KEY in the environment (it lives in the workspace .env):
#   export DOMAINIO_API_KEY=dk_live_...    (or: set -a; . /path/to/workspace/.env; set +a)
#
#   ./domainio-dns.sh domains                      # list owned domains + ids
#   ./domainio-dns.sh list   <domain>              # list DNS records for a domain
#   ./domainio-dns.sh add-a  <domain> <host> <ip>  # create an A record (ttl 7200)
#     e.g. ./domainio-dns.sh add-a fooderist.com staging 159.195.34.105
set -euo pipefail
BASE="${DOMAINIO_BASE:-https://domainio.nl}"
: "${DOMAINIO_API_KEY:?set DOMAINIO_API_KEY (from the workspace .env)}"

api() { curl -sS --max-time 25 -H "Authorization: Bearer $DOMAINIO_API_KEY" "$@"; }

# Resolve a domain name -> its domainio id.
domain_id() {
  api "$BASE/api/user/domains" | python3 -c "
import sys,json
items=json.load(sys.stdin).get('data',{}).get('items',[])
m={d['domainName']:d['id'] for d in items}
print(m.get('$1',''))"
}

cmd="${1:-}"
case "$cmd" in
  domains)
    api "$BASE/api/user/domains" | python3 -c "
import sys,json
for d in json.load(sys.stdin).get('data',{}).get('items',[]):
    print(f\"{d['domainName']:<24} {d['status']:<8} {d['id']}\")"
    ;;
  list)
    id=$(domain_id "${2:?domain}"); [[ -n "$id" ]] || { echo "domain not found" >&2; exit 1; }
    api "$BASE/api/domains/$id/dns" | python3 -c "
import sys,json
d=json.load(sys.stdin); items=d.get('data',{}).get('items') or []
print('records:', len(items))
for r in items: print(' ', r.get('type'), r.get('host') or r.get('name'), '->', r.get('value'), 'ttl', r.get('ttl'))"
    ;;
  add-a)
    dom="${2:?domain}"; host="${3:?host}"; ip="${4:?ip}"
    id=$(domain_id "$dom"); [[ -n "$id" ]] || { echo "domain not found: $dom" >&2; exit 1; }
    # ttl 7200 = ResellerClub minimum; lower silently fails (see mahmutkaya/domainio#229)
    api -X POST -H "Content-Type: application/json" \
      -d "{\"type\":\"A\",\"host\":\"$host\",\"value\":\"$ip\",\"ttl\":7200}" \
      "$BASE/api/domains/$id/dns"
    echo
    echo "-> verify: dig +short A ${host}.${dom} @1.1.1.1"
    ;;
  *)
    echo "usage: $0 {domains | list <domain> | add-a <domain> <host> <ip>}" >&2; exit 2 ;;
esac
