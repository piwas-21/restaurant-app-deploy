#!/usr/bin/env bash
# Unit test for harden-tenant-db-access.sh's "does PUBLIC hold CONNECT?" check.
#
# WHY this exists. The first version of that check pattern-matched the ACL TEXT for
# `=Tc/`, which is the marker for PUBLIC holding exactly TEMP+CONNECT. It was wrong in
# the worst possible direction for a security check — it reported "already restricted"
# for the two states where PUBLIC has MORE than that:
#
#   =c/owner     CONNECT only, no TEMP — what a partial "revoke TEMP from PUBLIC"
#                hardening leaves behind.
#   =CTc/owner   GRANT ALL TO PUBLIC — the most permissive state a database can be in.
#
# and it was wrong in the other direction too: `tenant_b=Tc/owner` is a grant to a
# NAMED role, and it contains the substring, so a properly hardened database reported a
# pending change on every run and the script never converged.
#
# The SQL is EXTRACTED from the script rather than copied. A copy is a second source of
# truth that keeps passing after the original changes, and "two places that were
# supposed to agree" is the whole bug class here.
#
# Needs docker (a throwaway postgres:16, the image docker-compose.prod.yml pins). Skips
# cleanly when docker is unavailable so it never blocks a laptop without it — the CI
# runner has one.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../harden-tenant-db-access.sh"
[[ -f "$SCRIPT" ]] || { echo "cannot find harden-tenant-db-access.sh next to $HERE"; exit 1; }

if ! docker info >/dev/null 2>&1; then
  echo "SKIP tenant-db-acl: docker unavailable"
  exit 0
fi

# The predicate, lifted out of the function body so the test cannot drift from it.
# The predicate text ends at `datname=` — everything after it on that line is the
# shell call, not SQL. Cut there and re-terminate with a psql variable.
SQL_BODY="$(sed -n '/^acl_public_connect()/,/^}/p' "$SCRIPT" \
  | sed -n '/SELECT CASE/,/WHERE datname=/p' \
  | sed "s/WHERE datname=.*/WHERE datname = :'db'/")"
[[ -n "$SQL_BODY" ]] || { echo "FAIL: could not extract the ACL predicate from the script"; exit 1; }

CID="$(docker run -d --rm -e POSTGRES_PASSWORD=t -e POSTGRES_USER=t postgres:16)"
trap 'docker rm -f "$CID" >/dev/null 2>&1 || true' EXIT

for _ in $(seq 1 60); do
  docker exec "$CID" pg_isready -U t -q && break
  sleep 1
done
docker exec "$CID" pg_isready -U t -q || { echo "FAIL: postgres never became ready"; exit 1; }

q() { docker exec -i "$CID" psql -v ON_ERROR_STOP=1 -U t -d postgres -tA "$@"; }

# `probe_c` NEVER receives a grant anywhere. It is the oracle's role, and keeping it
# separate from `other_b` matters: `d_named_grant` grants CONNECT to `other_b`
# explicitly, so probing with that role would answer "can connect" for a database
# where PUBLIC has correctly been revoked — the oracle would be measuring the named
# grant instead of PUBLIC's. That mistake was made first and this test caught it.
q -c "CREATE ROLE owner_a LOGIN; CREATE ROLE other_b LOGIN; CREATE ROLE probe_c LOGIN;" >/dev/null

# One row per ACL shape the script can meet, with the TRUTH stated independently of
# the ACL text: can `other_b` — a role with no grant of its own — actually connect?
setup_default()        { q -c "CREATE DATABASE d_default OWNER owner_a"; }
setup_hardened()       { q -c "CREATE DATABASE d_hardened OWNER owner_a"; q -c "REVOKE CONNECT ON DATABASE d_hardened FROM PUBLIC"; }
setup_connect_no_temp(){ q -c "CREATE DATABASE d_connect_no_temp OWNER owner_a"; q -c "REVOKE ALL ON DATABASE d_connect_no_temp FROM PUBLIC"; q -c "GRANT CONNECT ON DATABASE d_connect_no_temp TO PUBLIC"; }
setup_public_all()     { q -c "CREATE DATABASE d_public_all OWNER owner_a"; q -c "GRANT ALL ON DATABASE d_public_all TO PUBLIC"; }
setup_named_grant()    { q -c "CREATE DATABASE d_named_grant OWNER owner_a"; q -c "REVOKE CONNECT ON DATABASE d_named_grant FROM PUBLIC"; q -c "GRANT TEMP, CONNECT ON DATABASE d_named_grant TO other_b"; }

for s in default hardened connect_no_temp public_all named_grant; do "setup_$s" >/dev/null; done

fail=0
check() {
  local db="$1" expected="$2"
  local said
  # Fed on STDIN, not with `-c`: psql performs variable interpolation for stdin and
  # files, but sends a `-c` string to the server verbatim, so `:'db'` would arrive
  # literally and fail to parse.
  said="$(printf '%s\n' "$SQL_BODY" | q -v db="$db" | tr -d '[:space:]')"

  # The oracle is not the ACL string: it is whether `probe_c` — a role holding no grant
  # of its own, anywhere — can open a session. Computed by DOING it, so the test cannot
  # agree with the code for the same wrong reason.
  local really
  if docker exec -i "$CID" psql -U probe_c -d "$db" -tAc 'SELECT 1' >/dev/null 2>&1; then
    really=yes
  else
    really=no
  fi

  if [[ "$said" != "$expected" || "$really" != "$expected" ]]; then
    echo "FAIL $db: predicate said '$said', a real connect says '$really', expected '$expected'"
    fail=1
  else
    echo "  ok  $db: public_connect=$said (confirmed by a real connect)"
  fi
}

check d_default          yes
check d_hardened         no
check d_connect_no_temp  yes
check d_public_all       yes
check d_named_grant      no

[[ "$fail" -eq 0 ]] || { echo "FAIL: the ACL predicate disagrees with what PostgreSQL actually permits"; exit 1; }
echo "PASS tenant-db-acl: the predicate matches real connectability on all five ACL shapes"
