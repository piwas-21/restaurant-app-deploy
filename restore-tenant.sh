#!/usr/bin/env bash
# Restore REHEARSAL and restore, for one tenant. A backup that has never been restored
# is a hope, not a backup — this is the script that turns the hope into a measurement.
#
#   ./restore-tenant.sh <slug>                          # REHEARSE (default): load into a
#                                                       # throwaway DB, verify, drop it
#   ./restore-tenant.sh <slug> --from archive:latest    # rehearse the archive instead
#   ./restore-tenant.sh <slug> --from <ref>             # rehearse one exact artifact
#   ./restore-tenant.sh <slug> --into <db> --force      # REAL restore into <db>
#   ./restore-tenant.sh <slug> --list                   # what is restorable, newest first
#
# The default is the rehearsal, deliberately: the dangerous mode is the one you have to
# ask for by name, and the safe one is what a cron job or a half-remembered command runs.
#
# What the rehearsal proves — the whole point, since "the file exists and is 4 MB" proves
# nothing at all:
#   1. the gzip stream is intact end to end (gzip -t)
#   2. the checksum recorded when it was written still matches (sidecar / manifest)
#   3. postgres ACCEPTS it: it loads into a scratch database with no unexpected ERROR
#   4. it is COMPLETE: the number of tables postgres ended up with equals the number of
#      CREATE TABLE statements in the artifact — a truncated dump fails this even when it
#      loads without complaint, which is exactly the failure a "did it run?" check misses
#   5. it is NOT EMPTY: the loaded rows are counted and reported
# then it drops the scratch database and the role it may have had to invent, on a trap,
# so a failed rehearsal leaves nothing behind either.
#
# Run ON THE BOX as the deploy user from /opt/rumi/deploy. Weekly in CI against staging:
# .github/workflows/backup-rehearsal.yml (same precedent as provisioning-smoke.yml).
set -euo pipefail
cd "$(dirname "$0")"

# shellcheck source=backup-lib.sh
. ./backup-lib.sh

SLUG=""
FROM="latest"
INTO=""
FORCE=false
LIST=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from) FROM="${2:?--from needs a value}"; shift 2 ;;
    --into) INTO="${2:?--into needs a database name}"; shift 2 ;;
    --force) FORCE=true; shift ;;
    --list) LIST=true; shift ;;
    --dry-run|-n) shift ;;   # the default; accepted so the safe intent can be explicit
    -*) bk_die "unknown flag '$1'" ;;
    *) [[ -z "$SLUG" ]] || bk_die "unexpected argument '$1'"; SLUG="$1"; shift ;;
  esac
done
[[ -n "$SLUG" ]] || bk_die "usage: $0 <slug> [--from latest|archive:latest|<ref>] [--into <db> --force] [--list]"
bk_slug_ok "$SLUG" || bk_die "slug must be lowercase [a-z0-9-], 2-31 chars"

[[ -f .env ]] || bk_die "box .env missing (run from /opt/rumi/deploy)"

# ── what is restorable, newest first ────────────────────────────────────────────────
list_artifacts() {
  local d="${TENANT_DUMP_DIR}/${SLUG}"
  [[ -d "$d" ]] && find "$d" -maxdepth 1 -type f -name '*.sql.gz' | sort -r
  d="${ARCHIVE_DIR}/${SLUG}"
  [[ -d "$d" ]] && find "$d" -mindepth 1 -maxdepth 1 -type d | sort -r
  return 0
}

if $LIST; then
  bk_log "restorable artifacts for '${SLUG}'"
  found=false
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    found=true
    printf '  %-12s %s\n' "$([[ -d "$p" ]] && echo archive || echo dump)" "${p#"${BACKUP_ROOT}"/}"
  done < <(list_artifacts)
  $found || echo "  (none)"
  exit 0
fi

# ── resolve --from to one file on disk ──────────────────────────────────────────────
resolve_from() {
  local want="$1" p=""
  case "$want" in
    latest)
      p="$(list_artifacts | head -1)" ;;
    archive:latest)
      p="$([[ -d "${ARCHIVE_DIR}/${SLUG}" ]] && find "${ARCHIVE_DIR}/${SLUG}" -mindepth 1 -maxdepth 1 -type d | sort -r | head -1)" ;;
    *)
      bk_ref_ok "$want" "$SLUG" || bk_die "refusing ref '$want' — must be dumps/tenants/${SLUG}/… or archive/${SLUG}/… with no traversal"
      p="${BACKUP_ROOT}/${want}" ;;
  esac
  [[ -n "$p" ]] || bk_die "no artifact found for '$SLUG' (try --list)"
  if [[ -d "$p" ]]; then
    [[ -f "${p}/db.sql.gz" ]] || bk_die "archive ${p#"${BACKUP_ROOT}"/} holds no db.sql.gz (files-only archive — nothing to load)"
    printf '%s' "${p}/db.sql.gz"
  else
    [[ -f "$p" ]] || bk_die "no such artifact: ${p#"${BACKUP_ROOT}"/}"
    printf '%s' "$p"
  fi
}

FILE="$(resolve_from "$FROM")"
REF="${FILE#"${BACKUP_ROOT}"/}"
bk_log "artifact: ${REF} ($(bk_size "$FILE") bytes)"

# ── 1. the stream is intact ─────────────────────────────────────────────────────────
echo "==> gzip integrity"
gzip -t "$FILE"
echo "   ok"

# ── 2. the checksum recorded at write time still matches ────────────────────────────
echo "==> checksum"
EXPECTED=""
if [[ -f "${FILE}.sha256" ]]; then
  EXPECTED="$(cut -d' ' -f1 < "${FILE}.sha256")"
elif [[ -f "$(dirname "$FILE")/manifest.json" ]]; then
  EXPECTED="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(((d.get("db") or {}).get("sha256")) or "")' "$(dirname "$FILE")/manifest.json")"
fi
if [[ -z "$EXPECTED" ]]; then
  echo "   WARN: no recorded checksum beside this artifact — integrity unverified"
else
  ACTUAL="$(bk_sha256 "$FILE")"
  [[ "$ACTUAL" == "$EXPECTED" ]] || bk_die "CHECKSUM MISMATCH for ${REF} — the artifact has rotted or been altered"
  echo "   ok (${EXPECTED:0:12}…)"
fi

PGUSER="$(bk_pg_user)"
bk_pg_up "$PGUSER"

psql_q() { $BK_COMPOSE exec -T postgres psql -U "$PGUSER" -d "$1" -tAc "$2"; }
psql_admin() { $BK_COMPOSE exec -T postgres psql -v ON_ERROR_STOP=1 -U "$PGUSER" -d postgres -c "$1" >/dev/null; }

eval "$(bk_registry_eval "$SLUG")"
# The owning role: the registry first, then the ARCHIVE'S OWN MANIFEST. That second source
# is the one that matters here — a departed tenant may already have been struck from the
# registry, and its dump is full of `ALTER … OWNER TO <role>` naming a role that was
# dropped with the database. The manifest is why an archive is self-describing.
DB_ROLE="${REG_DB_ROLE:-}"
if [[ -z "$DB_ROLE" && -f "$(dirname "$FILE")/manifest.json" ]]; then
  DB_ROLE="$(python3 -c 'import json,sys; print(((json.load(open(sys.argv[1])).get("database") or {}).get("role")) or "")' "$(dirname "$FILE")/manifest.json")"
fi
DB_ROLE="${DB_ROLE:-tenant_${SLUG//-/_}}"

# ── choose the target ───────────────────────────────────────────────────────────────
CREATED_ROLE=false
SCRATCH=""
if [[ -n "$INTO" ]]; then
  # A real restore may only ever land in the tenant's OWN database or in an obviously
  # disposable one. Everything else is someone about to overwrite the wrong customer.
  [[ "$INTO" =~ ^[a-z_][a-z0-9_]{0,62}$ ]] || bk_die "--into '$INTO' is not a plain lowercase identifier"
  if [[ "$INTO" != "${REG_DB:-}" && "$INTO" != restore_* ]]; then
    bk_die "--into '$INTO' is neither tenant '${SLUG}'s registry db ('${REG_DB:-none}') nor a restore_* scratch name"
  fi
  TARGET="$INTO"
  $FORCE || bk_die "--into is a REAL restore into '${TARGET}'. Re-run with --force once you have rehearsed (no --into) and stopped the tenant's containers."
  if bk_db_exists "$PGUSER" "$TARGET"; then
    echo "==> target ${TARGET} exists — restoring INTO it (objects that already exist will error)"
  else
    echo "==> creating ${TARGET}"
    psql_admin "CREATE DATABASE ${TARGET}"
  fi
else
  # Rehearsal. Name is unique per run and self-describing, so an abandoned one after a
  # hard kill is obvious rather than mysterious.
  SCRATCH="restore_check_${SLUG//-/_}_$(date -u +%Y%m%d%H%M%S)"
  TARGET="$SCRATCH"
fi

cleanup() {
  local rc=$?
  if [[ -n "$SCRATCH" ]]; then
    $BK_COMPOSE exec -T postgres psql -U "$PGUSER" -d postgres \
      -c "DROP DATABASE IF EXISTS ${SCRATCH} WITH (FORCE)" >/dev/null 2>&1 || true
    echo "   cleaned up scratch database ${SCRATCH}"
  fi
  if $CREATED_ROLE; then
    $BK_COMPOSE exec -T postgres psql -U "$PGUSER" -d postgres \
      -c "DROP ROLE IF EXISTS ${DB_ROLE}" >/dev/null 2>&1 || true
    echo "   cleaned up placeholder role ${DB_ROLE}"
  fi
  exit "$rc"
}
trap cleanup EXIT

if [[ -n "$SCRATCH" ]]; then
  echo "==> scratch database ${SCRATCH}"
  psql_admin "CREATE DATABASE ${SCRATCH}"
fi

# A plain pg_dump carries `ALTER … OWNER TO <role>`; for a DEPARTED tenant that role was
# dropped with the database, so the load would fail on every object. Invent it for the
# rehearsal (NOLOGIN — it can authenticate nothing) and drop it again on the way out.
if ! psql_q postgres "SELECT 1 FROM pg_roles WHERE rolname='${DB_ROLE}'" | grep -q 1; then
  echo "==> role ${DB_ROLE} is gone — creating it NOLOGIN for the rehearsal"
  psql_admin "CREATE ROLE ${DB_ROLE} NOLOGIN"
  CREATED_ROLE=true
fi

# ── 3. postgres accepts it ──────────────────────────────────────────────────────────
echo "==> loading into ${TARGET}"
ERRLOG="$(mktemp)"
LOADRC=0
gunzip -c "$FILE" | $BK_COMPOSE exec -T postgres psql -U "$PGUSER" -d "$TARGET" -q >/dev/null 2>"$ERRLOG" || LOADRC=$?

# ON_ERROR_STOP is NOT used, on purpose: a dump of a live database legitimately emits a
# handful of benign complaints (below), and stopping on the first would report a healthy
# artifact as broken. Instead every error line is read, the known-benign ones are struck
# out BY EXACT TEXT, and anything left over fails the rehearsal.
BENIGN='schema "public" already exists|role "[a-z0-9_]+" (already exists|does not exist)|must be owner of schema public|extension "[a-z0-9_]+" already exists'
REAL_ERRORS="$(grep -E '^(psql:)?.*ERROR:' "$ERRLOG" | grep -Ev "$BENIGN" || true)"
if [[ -n "$REAL_ERRORS" ]]; then
  echo "   unexpected errors while loading ${REF}:" >&2
  printf '%s\n' "$REAL_ERRORS" | head -20 >&2
  rm -f "$ERRLOG"
  bk_die "restore rehearsal FAILED for ${REF}"
fi
[[ $LOADRC -eq 0 ]] || echo "   note: psql exited ${LOADRC} but no unexpected ERROR lines were logged"
rm -f "$ERRLOG"

# ── 4. it is complete ───────────────────────────────────────────────────────────────
echo "==> completeness"
WANT_TABLES="$(gunzip -c "$FILE" | grep -c '^CREATE TABLE ' || true)"
GOT_TABLES="$(psql_q "$TARGET" "SELECT count(*) FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema')" | tr -d '[:space:]')"
echo "   CREATE TABLE statements in artifact: ${WANT_TABLES}"
echo "   tables present after load:           ${GOT_TABLES}"
[[ "$WANT_TABLES" -gt 0 ]] || bk_die "artifact ${REF} declares NO tables — it is not a usable tenant dump"
[[ "$GOT_TABLES" == "$WANT_TABLES" ]] || bk_die "incomplete restore: ${GOT_TABLES}/${WANT_TABLES} tables — the artifact is truncated or the load was rejected"

# ── 5. it is not empty ──────────────────────────────────────────────────────────────
ROWS="$(psql_q "$TARGET" "SELECT COALESCE(sum(cnt),0) FROM (SELECT (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', schemaname, tablename), false, true, '')))[1]::text::bigint AS cnt FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema')) s" | tr -d '[:space:]')"
echo "   rows restored: ${ROWS:-unknown}"

if [[ -n "$SCRATCH" ]]; then
  bk_log "REHEARSAL PASSED — ${REF} restores cleanly (${GOT_TABLES} tables, ${ROWS:-?} rows). Scratch DB dropped."
else
  bk_log "RESTORE COMPLETE — ${REF} -> ${TARGET} (${GOT_TABLES} tables, ${ROWS:-?} rows)"
  echo "    Next: re-provision the tenant (./provision-tenant.sh ${SLUG}) so its containers,"
  echo "    secrets and Caddy block match the restored database."
fi
