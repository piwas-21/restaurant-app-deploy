#!/usr/bin/env bash
# Revoke PUBLIC's CONNECT on every database on this box that belongs to a tenant or
# to the control plane, granting it to that database's own role instead (#155).
#
# WHY THIS EXISTS SEPARATELY FROM provision-tenant.sh
# ---------------------------------------------------
# PostgreSQL grants CONNECT on a new database to PUBLIC — i.e. to every role on the
# cluster, including every other tenant's. provision-tenant.sh now revokes that at
# creation, but it does FIRST provisioning only, so a database created before that
# change keeps the loose default forever. This is the repair for those, and for the
# control-plane databases, which provisioning never touches at all.
#
# Measured on the staging box before either change:
#
#     $ psql -U tenant_demo -d tenant_kebabdilhan -tAc 'SELECT current_database()'
#     tenant_kebabdilhan          <- succeeded
#
# No data was exposed: table reads and schema writes both fail closed. This is a
# defence-in-depth gap, not an active leak.
#
# SAFETY
# ------
# * GRANT runs BEFORE REVOKE, deliberately. They are separate statements, so if the
#   GRANT fails (a typo'd role, a role that does not exist) nothing has changed yet.
#   The other order can strand a role that is NOT the database owner: an owner keeps
#   CONNECT through ownership, but a non-owner role loses it the instant PUBLIC's
#   grant is gone. Every scripts-provisioned tenant IS its database's owner, which is
#   exactly why the wrong order would have looked safe for as long as anyone tested it.
# * Superusers bypass these ACLs entirely, so backup-dump.sh, restore-tenant.sh,
#   deprovision-tenant.sh and every psql_deploy call — all of which run as
#   POSTGRES_USER — are unaffected.
# * Idempotent, and it CONVERGES: the check asks PostgreSQL whether PUBLIC holds
#   CONNECT rather than pattern-matching the ACL text (see acl_public_connect below).
# * Reversible: `GRANT CONNECT ON DATABASE <db> TO PUBLIC` restores the default.
#
# Usage (on the box, from /opt/rumi/deploy):
#     ./harden-tenant-db-access.sh            # report what WOULD change
#     ./harden-tenant-db-access.sh --apply    # make the change
#
# A dry run is the default deliberately: this reaches every application database on
# the box at once, and "what would this touch" is the question worth answering first.
set -euo pipefail

cd "$(dirname "$0")"

APPLY=0
case "${1:-}" in
  "") ;;
  --apply) APPLY=1 ;;
  *) echo "ERROR: unknown argument '$1' (expected --apply or nothing)" >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { echo "ERROR: too many arguments" >&2; exit 2; }

[[ -f tenants/registry.yml ]] || { echo "ERROR: tenants/registry.yml missing (sync the deploy repo first)" >&2; exit 1; }
python3 -c 'import yaml' 2>/dev/null || { echo "ERROR: python3-yaml missing (apt-get install -y python3-yaml)" >&2; exit 1; }

PGUSER="$(grep -E '^POSTGRES_USER=' .env | cut -d= -f2- | tr -d '"'"'"'' || true)"
[[ -n "$PGUSER" ]] || { echo "ERROR: POSTGRES_USER not set in .env" >&2; exit 1; }

# Which box this is. provision-tenant.sh refuses a tenant belonging to the other box;
# so does this. Without it a PROD tenant's entry is applied to whatever database of
# the same name happens to exist here — and `restaurantdb` exists on BOTH boxes.
BOX_ROLE="$(grep -E '^BOX_ROLE=' .env | cut -d= -f2- | tr -d '"'"'"'' || true)"
[[ -n "$BOX_ROLE" ]] || { echo "ERROR: BOX_ROLE not set in .env (prod|staging) — refusing to guess" >&2; exit 1; }

DEPLOY_COMPOSE="docker compose -f docker-compose.prod.yml"
psql_deploy() { $DEPLOY_COMPOSE exec -T postgres psql -v ON_ERROR_STOP=1 -U "$PGUSER" -d postgres "$@"; }

# Reachability, before anything reads a table. Without it a stopped container makes
# every `SELECT 1 FROM pg_database` return empty, every database read as "does not
# exist", and the script report a clean box with exit 0 — a reassuring summary from a
# run that examined nothing. deprovision-tenant.sh probes for the same reason.
psql_deploy -tAc 'SELECT 1' >/dev/null 2>&1 \
  || { echo "ERROR: cannot reach postgres as '$PGUSER' — is the stack up?" >&2; exit 1; }

# A plain lowercase identifier, matching restore-tenant.sh's `--into` guard. These
# values come from tenants/registry.yml, which is GENERATED from partner-supplied
# signup data, and they are interpolated into `psql -c`. Unvalidated, a registry `db`
# of `x; CREATE ROLE evil SUPERUSER LOGIN PASSWORD 'p'; --` executes — demonstrated.
valid_ident() { local ident="$1"; [[ "$ident" =~ ^[a-z_][a-z0-9_]{0,62}$ ]]; }

# Does PUBLIC hold CONNECT on this database? Asked of PostgreSQL rather than matched
# against the ACL TEXT.
#
# The text-matching version of this check was wrong in the worst direction. `=Tc/` is
# the marker for PUBLIC holding exactly TEMP+CONNECT, so it MISSED both
# `=c/owner` (CONNECT only — what a partial CIS-style hardening leaves behind) and
# `=CTc/owner` (GRANT ALL TO PUBLIC — the most permissive state a database can be in),
# reporting each as "already restricted". It also matched `tenant_b=Tc/owner`, a grant
# to a NAMED role, so a database with PUBLIC already revoked reported a pending change
# on every run, for ever.
#
# `grantee = 0` is PUBLIC. `acldefault('d', datdba)` materialises the NULL default, so
# a never-touched database and an explicitly-granted one are answered by one query.
acl_public_connect() {
  local db="$1"
  psql_deploy -tAc "
    SELECT CASE WHEN EXISTS (
             SELECT 1 FROM aclexplode(coalesce(datacl, acldefault('d', datdba))) a
             WHERE a.grantee = 0 AND a.privilege_type = 'CONNECT')
           THEN 'yes' ELSE 'no' END
    FROM pg_database WHERE datname='$db'" | tr -d '[:space:]'
}

db_exists() { local db="$1"; psql_deploy -tAc "SELECT 1 FROM pg_database WHERE datname='$db'" | grep -q 1; }

# The registry is the authority on which database belongs to which tenant. Reading it
# rather than matching `tenant_%` matters twice: tenant 1's database is `restaurantdb`,
# which no prefix would catch, and a stray database that is NOT a tenant's must not
# have its ACL rewritten.
#
# The control-plane databases are appended explicitly because they are not tenants and
# never appear in the registry — and leaving them out would have been the reciprocal
# hole: every tenant role could open a session on the database holding partner,
# billing and CRM records, which is the most sensitive one on the box.
mapfile -t ENTRIES < <(python3 - "$BOX_ROLE" <<'PY'
import sys, yaml
box = sys.argv[1]
reg = yaml.safe_load(open("tenants/registry.yml")) or {}
for slug, t in (reg.get("tenants") or {}).items():
    db, role = t.get("db"), t.get("db_role")
    if not db or not role:
        continue
    # `retired` is reported, not hardened: deprovision-tenant.sh KEEPS the database
    # and the login role unless --drop-db was passed, so a retired slug can still
    # have exactly the loose database this script exists to close. Silently
    # filtering it out is how that stays invisible.
    status = t.get("status")
    kind = "retired" if status == "retired" else "tenant"
    if (t.get("box") or "prod") != box:
        kind = "otherbox"
    print(f"{slug}\t{db}\t{role}\t{kind}")
PY
)
for platform in sofra:sofra sofra_staging:sofra_staging; do
  ENTRIES+=("${platform%%:*}(control-plane)	${platform%%:*}	${platform##*:}	platform")
done

echo "==> box '$BOX_ROLE': ${#ENTRIES[@]} candidate database(s)"
changed=0
skipped_retired=0
for entry in "${ENTRIES[@]}"; do
  IFS=$'\t' read -r slug db role kind <<<"$entry"

  if [[ "$kind" == "otherbox" ]]; then
    continue
  fi

  valid_ident "$db"   || { echo "ERROR: registry db '$db' for '$slug' is not a plain identifier" >&2; exit 1; }
  valid_ident "$role" || { echo "ERROR: registry db_role '$role' for '$slug' is not a plain identifier" >&2; exit 1; }

  if ! db_exists "$db"; then
    [[ "$kind" == "platform" ]] || echo "   SKIP ${slug}: database ${db} is not on this box"
    continue
  fi

  if [[ "$kind" == "retired" ]]; then
    # It exists despite being retired, i.e. it was torn down without --drop-db.
    skipped_retired=$((skipped_retired + 1))
    echo "   NOTE ${slug}: RETIRED but ${db} still exists (public_connect=$(acl_public_connect "$db")) — deprovision with --drop-db, or harden by hand"
    continue
  fi

  if [[ "$(acl_public_connect "$db")" == "no" ]]; then
    echo "   ok   ${slug}: ${db} already restricted"
    continue
  fi

  changed=$((changed + 1))
  if [[ "$APPLY" -eq 1 ]]; then
    # GRANT first — see SAFETY above.
    psql_deploy -c "GRANT CONNECT ON DATABASE ${db} TO ${role}" >/dev/null
    psql_deploy -c "REVOKE CONNECT ON DATABASE ${db} FROM PUBLIC" >/dev/null
    echo "   DONE ${slug}: ${db} -> CONNECT for ${role} (+ superusers) only"
  else
    echo "   WOULD ${slug}: GRANT CONNECT ON ${db} TO ${role}; REVOKE CONNECT FROM PUBLIC"
  fi
done

[[ "$skipped_retired" -eq 0 ]] || echo "==> ${skipped_retired} retired tenant database(s) still present — see NOTE lines above"
if [[ "$APPLY" -eq 1 ]]; then
  echo "==> ${changed} database(s) hardened"
else
  echo "==> ${changed} database(s) would change. Re-run with --apply to make it so."
fi
