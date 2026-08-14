#!/usr/bin/env bash
# Thin wrapper over the domainio DNS API that bakes in its quirks (field is `host`
# not `name`; ttl must be >= 7200) so DNS ops are one command, not trial-and-error.
# Requires DOMAINIO_API_KEY in the environment (it lives in the workspace .env).
# NOTE: do NOT `set -a; . workspace/.env` -- that file contains multi-line SSH
# fingerprint blocks and sourcing it fails with a syntax error. Extract just the key:
#   export DOMAINIO_API_KEY=$(grep -E '^DOMAINIO_API_KEY=' /path/to/workspace/.env | cut -d= -f2-)
#
#   ./domainio-dns.sh domains                      # list owned domains + ids
#   ./domainio-dns.sh list   <domain>              # list DNS records (ALL types)
#   ./domainio-dns.sh add-a  <domain> <host> <ip>  # create an A record (ttl 7200)
#     e.g. ./domainio-dns.sh add-a fooderist.com staging 159.195.34.105
#   ./domainio-dns.sh add    <domain> <TYPE> <host> <value> [ttl] [priority]
#     e.g. ./domainio-dns.sh add sofrapiwas.com TXT send '"v=spf1 include:amazonses.com ~all"'
#          ./domainio-dns.sh add sofrapiwas.com MX  send feedback-smtp.eu-west-1.amazonses.com 7200 10
#
# `host` is always relative to the APEX (see the trap documented on `add`).
set -euo pipefail
BASE="${DOMAINIO_BASE:-https://domainio.nl}"
: "${DOMAINIO_API_KEY:?set DOMAINIO_API_KEY (from the workspace .env)}"

api() { curl -sS --max-time 25 -H "Authorization: Bearer $DOMAINIO_API_KEY" "$@"; }

# Resolve a domain name -> its domainio id.
# Surfaces API errors instead of returning empty (an empty id used to be reported as
# "domain not found", which hides auth/quota failures behind a wrong diagnosis).
domain_id() {
  api "$BASE/api/user/domains" | NAME="$1" python3 -c "
import sys, json, os
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except ValueError:
    sys.exit('domainio API returned non-JSON: ' + raw[:200])
if not isinstance(d, dict) or d.get('success') is False:
    sys.exit('domainio API error: ' + str(d.get('error') or d.get('message') or d))
items = (d.get('data') or {}).get('items')
if items is None:
    sys.exit('domainio API: no \'items\' in response: ' + json.dumps(d)[:200])
print({x['domainName']: x['id'] for x in items}.get(os.environ['NAME'], ''))"
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
    # The API REQUIRES a `type` parameter; without it it answers
    #   {"success":false,"error":"Required parameter missing: type"}
    # and an older parser here read the absent `items` key as an empty list and printed
    # "records: 0" -- which was misread for weeks as "the zone is not activated"
    # (domainio#231). So: iterate the types, and NEVER silently turn an error into 0.
    types="${DOMAINIO_TYPES:-A AAAA CNAME TXT MX NS SRV CAA}"
    total=0; errors=0
    for t in $types; do
      body=$(api "$BASE/api/domains/$id/dns?type=$t") || {
        echo "  !! $t: curl failed" >&2; errors=$((errors+1)); continue; }
      out=$(printf '%s' "$body" | TYPE="$t" python3 -c "
import sys, json, os
t = os.environ['TYPE']
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except ValueError:
    print('ERR', t, 'non-JSON response:', raw[:200].replace(chr(10), ' '))
    sys.exit(3)
if not isinstance(d, dict) or d.get('success') is False:
    err = (d.get('error') or d.get('message') or d) if isinstance(d, dict) else d
    print('ERR', t, err)
    sys.exit(3)
data = d.get('data') or {}
items = data.get('items')
if items is None:
    # Absent key is NOT 'zero records' -- that conflation is the whole bug.
    print('ERR', t, 'no \'items\' key in response:', json.dumps(d)[:200])
    sys.exit(3)
for r in items:
    prio = ('  prio ' + str(r.get('priority'))) if r.get('priority') is not None else ''
    print('OK  %-6s %-34s -> %s  ttl %s%s' % (
        t, r.get('host') or r.get('name') or '@', r.get('value'), r.get('ttl'), prio))
") || errors=$((errors+1))
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        case "$line" in
          "OK  "*) echo "  ${line#OK  }"; total=$((total+1)) ;;
          "ERR "*) echo "  !! ${line#ERR }" >&2 ;;
        esac
      done <<< "$out"
    done
    echo "records: $total (types: $types)"
    if [[ "$errors" -gt 0 ]]; then
      echo "!! $errors record type(s) FAILED to list -- the count above is INCOMPLETE" >&2
      exit 4
    fi
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
  add)
    # Generic record creation: add <domain> <TYPE> <host> <value> [ttl] [priority]
    # `host` is relative to the APEX. This is the trap that cost `send.sofrapiwas.com`
    # its SPF: Resend's dashboard shows the record name as "send" *relative to the
    # sending subdomain*, and pasting that verbatim while the sending subdomain is
    # already `send` publishes it at `send.send.<domain>`. For a sending subdomain
    # `send.example.com` the SPF host is `send`, NOT `send.send`.
    dom="${2:?domain}"; typ="${3:?type}"; host="${4:?host}"; val="${5:?value}"
    ttl="${6:-7200}"; prio="${7:-}"
    id=$(domain_id "$dom"); [[ -n "$id" ]] || { echo "domain not found: $dom" >&2; exit 1; }
    payload=$(TYPE="$typ" HOST="$host" VAL="$val" TTL="$ttl" PRIO="$prio" python3 -c "
import json, os
d = {'type': os.environ['TYPE'], 'host': os.environ['HOST'],
     'value': os.environ['VAL'], 'ttl': int(os.environ['TTL'])}
if os.environ.get('PRIO'):
    d['priority'] = int(os.environ['PRIO'])
print(json.dumps(d))")
    resp=$(api -X POST -H "Content-Type: application/json" -d "$payload" "$BASE/api/domains/$id/dns")
    printf '%s\n' "$resp" | python3 -c "
import sys, json
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except ValueError:
    print('FAILED (non-JSON):', raw[:300]); sys.exit(1)
if isinstance(d, dict) and d.get('success') is False:
    print('FAILED:', d.get('error') or d.get('message') or d); sys.exit(1)
print('created:', json.dumps(d.get('data', d))[:300])"
    echo "-> verify: dig +short ${typ} ${host}.${dom} @1.1.1.1"
    ;;
  *)
    echo "usage: $0 {domains | list <domain> | add-a <domain> <host> <ip>" >&2
    echo "         | add <domain> <TYPE> <host> <value> [ttl] [priority]}" >&2; exit 2 ;;
esac
