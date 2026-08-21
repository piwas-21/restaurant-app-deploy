#!/usr/bin/env bash
# Per-tenant database dump — the artifact `cluster-<ts>.sql.gz` cannot be.
#
#   ./backup-tenant.sh <slug> [--kind scheduled|manual] [--skip-missing] [--quiet]
#
# WHY this exists next to backup-dump.sh's pg_dumpall, rather than instead of it. The
# two answer different questions and BOTH are needed:
#
#   cluster-<ts>.sql.gz   "the box is gone"      — every DB *and every ROLE*, in one
#                         restorable unit. A per-tenant dump does not carry roles, so
#                         it can never be the box-loss path.
#   this file             "restore ONE tenant"   — a single `psql` away, with no
#                         50-database dump to carve a customer out of by hand at 3am,
#                         and the only shape a product feature ("download my backup",
#                         "restore me") can be built on.
#
# So per-tenant COMPLEMENTS the cluster dump. The duplication is deliberate and its cost
# is bounded: tenant databases are small (the whole staging restic repo is 18 MiB across
# 11 snapshots as of 2026-08-20) and this writes ONE gzip per tenant per night. What it
# deliberately does NOT duplicate is uploads: those are the big bytes, they change rarely,
# and backup-dump.sh already tars /opt/rumi/tenants box-wide every night. A tenant's files
# get their own copy exactly once — when they leave (backup-archive-tenant.sh).
#
# Refuses managed:legacy (RUMI runs the MAIN compose project — ADR-006) and any tenant
# that belongs on another box; the nightly loop in backup-dump.sh gets that refusal for
# free by iterating bk_registry_tenants.
set -euo pipefail
cd "$(dirname "$0")"

# shellcheck source=backup-lib.sh
. ./backup-lib.sh

SLUG="${1:?usage: $0 <slug> [--kind scheduled|manual] [--skip-missing] [--quiet]}"
shift || true
KIND=scheduled
SKIP_MISSING=false
QUIET=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kind) KIND="${2:?--kind needs a value}"; shift 2 ;;
    --skip-missing) SKIP_MISSING=true; shift ;;
    --quiet) QUIET=true; shift ;;
    *) bk_die "unknown flag '$1'" ;;
  esac
done
case "$KIND" in
  scheduled|manual) ;;
  *) bk_die "--kind must be scheduled|manual (got '$KIND')" ;;
esac
bk_slug_ok "$SLUG" || bk_die "slug must be lowercase [a-z0-9-], 2-31 chars"

say() { $QUIET || bk_log "$@"; }

KEEP_DAYS="${KEEP_DAYS:-7}"

[[ -f .env ]] || bk_die "box .env missing (run from /opt/rumi/deploy)"
[[ -f "$BK_REGISTRY" ]] || bk_die "$BK_REGISTRY missing"
BOX_ROLE="$(grep -E '^BOX_ROLE=' .env | cut -d= -f2- || true)"
[[ -n "$BOX_ROLE" ]] || bk_die "BOX_ROLE not set in the box .env"

eval "$(bk_registry_eval "$SLUG")"
[[ "${REG_FOUND:-0}" == "1" ]] || bk_die "tenant '$SLUG' not found in $BK_REGISTRY"
[[ "${REG_MANAGED:-}" == "scripts" ]] || bk_die "tenant '$SLUG' is managed:'${REG_MANAGED:-}' — refusing (ADR-006 protects tenant 1)"
[[ "${REG_BOX:-}" == "$BOX_ROLE" ]] || bk_die "tenant '$SLUG' belongs on box '${REG_BOX:-}', this box is '$BOX_ROLE'"
[[ -n "${REG_DB:-}" ]] || bk_die "registry entry '$SLUG' has no 'db'"

PGUSER="$(bk_pg_user)"
# A down postgres must never look like a successful empty backup.
bk_pg_up "$PGUSER"

if ! bk_db_exists "$PGUSER" "$REG_DB"; then
  if $SKIP_MISSING; then
    say "skip ${SLUG}: database ${REG_DB} does not exist on this box"
    exit 0
  fi
  bk_die "database ${REG_DB} does not exist (tenant '$SLUG' is not provisioned here)"
fi

OUT_DIR="${TENANT_DUMP_DIR}/${SLUG}"
install -d -m 700 "$BACKUP_ROOT" "$DUMP_DIR" "$TENANT_DUMP_DIR" "$OUT_DIR"
TS="$(bk_ts)"
OUT="${OUT_DIR}/${SLUG}-${KIND}-${TS}.sql.gz"

say "dump ${SLUG} (${REG_DB}) -> ${OUT##*/}"
# Atomic: .tmp then mv. A mid-dump abort must not leave a partial file with a
# valid-looking name for the offsite run to ship or the inventory to advertise.
$BK_COMPOSE exec -T postgres pg_dump -U "$PGUSER" "$REG_DB" | gzip > "${OUT}.tmp"
# gzip -t on the finished stream: `pg_dump | gzip` succeeds even when pg_dump dies
# mid-stream on some shells, and a truncated gzip is the one failure a backup must
# never survive silently.
gzip -t "${OUT}.tmp"
mv "${OUT}.tmp" "$OUT"

# Sidecar checksum, written once. The inventory push runs every 5 minutes and must not
# re-hash every dump on the box each time; it reads this instead.
SHA="$(bk_sha256 "$OUT")"
[[ -n "$SHA" ]] && printf '%s  %s\n' "$SHA" "${OUT##*/}" > "${OUT}.sha256"

say "wrote ${OUT} ($(bk_size "$OUT") bytes)"

# Operational retention only — same KEEP_DAYS as the cluster dumps beside it. Keeping a
# tenant's data longer than the operational window is the ARCHIVE's job, deliberately,
# because that copy has a different purpose, a different consent story and a different
# horizon (DEPLOYMENT.md §Backups & restore).
find "$OUT_DIR" -maxdepth 1 -type f -mtime "+${KEEP_DAYS}" -delete

# The ref exactly as the control-plane contract carries it.
printf 'ref=%s\n' "${OUT#"${BACKUP_ROOT}"/}"
