#!/usr/bin/env bash
# Long-retention archive of a tenant that has GONE AWAY — a lapsed trial, a churned
# customer, a torn-down instance. This is the artifact that answers the owner's actual
# requirement: "auto backups for tenant's data even if they are in trial, in case they
# want to come back later on."
#
#   ./backup-archive-tenant.sh <slug> [--reason deprovision|trial-lapsed|manual]
#                                     [--allow-missing-db] [--dry-run]
#   ./backup-archive-tenant.sh --prune [--dry-run]     # expire archives past the horizon
#
# WHY it is not just "keep the nightly dumps longer". The rolling backups exist to
# survive an incident: 7 days locally, and off-box `--keep-daily 7 --keep-weekly 4
# --keep-monthly 6`, which tops out at ~6 months. A trial tenant who comes back after
# eight months currently has NOTHING. Stretching the rolling series to two years instead
# would multiply the daily cost of EVERY tenant by ~4x to serve the one tenant that left.
# A departed tenant is a different shape: their data stopped changing the day they left,
# so ONE consolidated copy — database + their uploads + a manifest — is a complete and
# permanent record at a fraction of the bytes.
#
# Horizon: ARCHIVE_KEEP_MONTHS, default 24 (backup-lib.sh). Chosen so it stays INSIDE the
# longest retention the privacy pack already commits to, rather than outliving it — see
# DEPLOYMENT.md §Backups & restore for the GDPR reasoning, which is part of the design
# and not a footnote.
#
# What the archive DELIBERATELY does not contain: the tenant's .env and app-secrets.json.
# provision-tenant.sh regenerates those on the way back in, so a two-year-old JWT signing
# key and printer API key in cold storage would be pure liability with no restore value.
# (backup-dump.sh's nightly tenants-<ts>.tar.gz does carry them, at 7-day/6-month
# operational retention — that is the copy that exists to rebuild a box, not to outlive a
# customer.)
set -euo pipefail
cd "$(dirname "$0")"

# shellcheck source=backup-lib.sh
. ./backup-lib.sh

MODE=archive
SLUG=""
REASON=manual
ALLOW_MISSING_DB=false
DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prune) MODE=prune; shift ;;
    --reason) REASON="${2:?--reason needs a value}"; shift 2 ;;
    --allow-missing-db) ALLOW_MISSING_DB=true; shift ;;
    --dry-run|-n) DRY_RUN=true; shift ;;
    -*) bk_die "unknown flag '$1'" ;;
    *) [[ -z "$SLUG" ]] || bk_die "unexpected argument '$1'"; SLUG="$1"; shift ;;
  esac
done

# ── --prune: expire archives past the horizon ────────────────────────────────────────
# Separate from backup-dump.sh's `find -mtime` prune on purpose: mtime is the wrong clock
# for an archive (an rsync or a filesystem move rewrites it, silently resetting a
# two-year retention), so expiry is computed from the TIMESTAMP IN THE NAME, which is
# the moment the data was taken and cannot drift.
if [[ "$MODE" == prune ]]; then
  [[ -z "$SLUG" ]] || bk_die "--prune takes no slug"
  bk_log "prune archives older than ${ARCHIVE_KEEP_MONTHS} months in ${ARCHIVE_DIR}"
  [[ -d "$ARCHIVE_DIR" ]] || { bk_log "nothing to prune (no ${ARCHIVE_DIR})"; exit 0; }
  pruned=0
  while IFS= read -r box; do
    [[ -n "$box" ]] || continue
    ts="$(bk_ts_of "$box")"
    [[ -n "$ts" ]] || { echo "   skip (no timestamp in name): $box"; continue; }
    # A legal hold — an open dispute, an unpaid invoice, a pending DSR — is a file the
    # operator drops in the archive. Retention must not fight it.
    if [[ -f "${box}/.hold" ]]; then
      echo "   held (.hold present): ${box}"
      continue
    fi
    rc=0; bk_ts_older_than_months "$ts" "$ARCHIVE_KEEP_MONTHS" || rc=$?
    if [[ $rc -eq 0 ]]; then
      if $DRY_RUN; then
        echo "   WOULD expire: $box"
      else
        rm -rf "${box:?}"
        printf '%s\tprune\t%s\texpired after %s months\n' \
          "$(bk_now)" "${box#"${BACKUP_ROOT}"/}" "$ARCHIVE_KEEP_MONTHS" >> "$ERASURE_LOG"
        echo "   expired: $box"
      fi
      pruned=$((pruned + 1))
    elif [[ $rc -eq 2 ]]; then
      echo "   WARN: unparseable timestamp, keeping: $box" >&2
    fi
  done < <(find "$ARCHIVE_DIR" -mindepth 2 -maxdepth 2 -type d | sort)
  bk_log "prune done (${pruned} archive(s) affected)"
  exit 0
fi

# ── archive one tenant ───────────────────────────────────────────────────────────────
[[ -n "$SLUG" ]] || bk_die "usage: $0 <slug> [--reason ...] | $0 --prune"
bk_slug_ok "$SLUG" || bk_die "slug must be lowercase [a-z0-9-], 2-31 chars"
case "$REASON" in
  deprovision|trial-lapsed|manual) ;;
  *) bk_die "--reason must be deprovision|trial-lapsed|manual (got '$REASON')" ;;
esac

[[ -f .env ]] || bk_die "box .env missing (run from /opt/rumi/deploy)"
[[ -f "$BK_REGISTRY" ]] || bk_die "$BK_REGISTRY missing"
BOX_ROLE="$(grep -E '^BOX_ROLE=' .env | cut -d= -f2- || true)"
[[ -n "$BOX_ROLE" ]] || bk_die "BOX_ROLE not set in the box .env"

eval "$(bk_registry_eval "$SLUG")"
[[ "${REG_FOUND:-0}" == "1" ]] || bk_die "tenant '$SLUG' not found in $BK_REGISTRY"
[[ "${REG_MANAGED:-}" == "scripts" ]] || bk_die "tenant '$SLUG' is managed:'${REG_MANAGED:-}' — refusing (ADR-006 protects tenant 1)"
[[ "${REG_BOX:-}" == "$BOX_ROLE" ]] || bk_die "tenant '$SLUG' belongs on box '${REG_BOX:-}', this box is '$BOX_ROLE'"
[[ -n "${REG_DB:-}" ]] || bk_die "registry entry '$SLUG' has no 'db'"

TS="$(bk_ts)"
OUT_DIR="${ARCHIVE_DIR}/${SLUG}/${TS}"
TENANT_DIR="/opt/rumi/tenants/${SLUG}"

bk_log "archive tenant '${SLUG}' (reason=${REASON}) -> ${OUT_DIR}"
if $DRY_RUN; then
  echo "   DRY RUN — nothing written"
  exit 0
fi

PGUSER="$(bk_pg_user)"
bk_pg_up "$PGUSER"

install -d -m 700 "$BACKUP_ROOT" "$ARCHIVE_DIR" "${ARCHIVE_DIR}/${SLUG}" "$OUT_DIR"

DB_FILE="${OUT_DIR}/db.sql.gz"
DB_PRESENT=false
if bk_db_exists "$PGUSER" "$REG_DB"; then
  echo "   pg_dump ${REG_DB}"
  $BK_COMPOSE exec -T postgres pg_dump -U "$PGUSER" "$REG_DB" | gzip > "${DB_FILE}.tmp"
  gzip -t "${DB_FILE}.tmp"
  mv "${DB_FILE}.tmp" "$DB_FILE"
  DB_PRESENT=true
elif $ALLOW_MISSING_DB; then
  echo "   WARN: database ${REG_DB} does not exist — archiving files only"
else
  rmdir "$OUT_DIR" 2>/dev/null || true
  bk_die "database ${REG_DB} does not exist (pass --allow-missing-db to archive files only)"
fi

UPLOADS_FILE="${OUT_DIR}/uploads.tar.gz"
UPLOADS_PRESENT=false
if [[ -d "${TENANT_DIR}/uploads" ]]; then
  echo "   uploads"
  bk_tar_dir "${TENANT_DIR}/uploads" "$UPLOADS_FILE"
  UPLOADS_PRESENT=true
else
  echo "   skip: no ${TENANT_DIR}/uploads"
fi

DB_SHA=""; DB_SIZE=0
$DB_PRESENT && { DB_SHA="$(bk_sha256 "$DB_FILE")"; DB_SIZE="$(bk_size "$DB_FILE")"; }
UP_SHA=""; UP_SIZE=0
$UPLOADS_PRESENT && { UP_SHA="$(bk_sha256 "$UPLOADS_FILE")"; UP_SIZE="$(bk_size "$UPLOADS_FILE")"; }

# The manifest is what turns three files into an archive: it records what this is, when
# it was taken, when it expires and how to check it is intact. It carries NO secret and
# NO personal data — deliberately not even admin_email — so it is safe to read, copy and
# paste into a ticket while the data beside it is not.
BK_OUT="$OUT_DIR" BK_SLUG="$SLUG" BK_NAME="${REG_NAME:-}" BK_REASON="$REASON" \
BK_TS="$TS" BK_BOX="$BOX_ROLE" BK_DB="$REG_DB" BK_ROLE="${REG_DB_ROLE:-}" \
BK_STATUS="${REG_STATUS:-}" BK_DOMAIN="${REG_DOMAIN:-}" BK_KEEP="$ARCHIVE_KEEP_MONTHS" \
BK_DB_SHA="$DB_SHA" BK_DB_SIZE="$DB_SIZE" BK_UP_SHA="$UP_SHA" BK_UP_SIZE="$UP_SIZE" \
python3 - <<'PY'
import json, os
from datetime import datetime, timezone

ts = datetime.strptime(os.environ["BK_TS"], "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc)
keep = int(os.environ["BK_KEEP"])
y, m = ts.year, ts.month + keep
y += (m - 1) // 12
m = (m - 1) % 12 + 1
day = min(ts.day, [31, 29 if (y % 4 == 0 and (y % 100 or y % 400 == 0)) else 28,
                   31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1])
manifest = {
    "schema": 1,
    "tenantSlug": os.environ["BK_SLUG"],
    "tenantName": os.environ["BK_NAME"],
    "reason": os.environ["BK_REASON"],
    "takenAt": ts.strftime("%Y-%m-%dT%H:%M:%SZ"),
    "box": os.environ["BK_BOX"],
    "registryStatusAtArchive": os.environ["BK_STATUS"],
    "domainAtArchive": os.environ["BK_DOMAIN"],
    "database": {"name": os.environ["BK_DB"], "role": os.environ["BK_ROLE"]},
    "db": ({"file": "db.sql.gz", "sizeBytes": int(os.environ["BK_DB_SIZE"]),
            "sha256": os.environ["BK_DB_SHA"] or None}
           if os.environ["BK_DB_SIZE"] != "0" else None),
    "uploads": ({"file": "uploads.tar.gz", "sizeBytes": int(os.environ["BK_UP_SIZE"]),
                 "sha256": os.environ["BK_UP_SHA"] or None}
                if os.environ["BK_UP_SIZE"] != "0" else None),
    "excludes": [".env", "app-secrets.json"],
    "excludesWhy": "regenerated by provision-tenant.sh on restore; long-lived secrets in "
                   "cold storage are liability without restore value",
    "contains": "restaurant business data INCLUDING personal data of the restaurant's own "
                "customers (order + reservation contact snapshots, accounts). Controller: "
                "the tenant. See docs/privacy/ in the workspace repo.",
    "retention": {"keepMonths": keep,
                  "expiresAt": ts.replace(year=y, month=m, day=day).strftime("%Y-%m-%dT%H:%M:%SZ"),
                  "holdFile": ".hold"},
    "restoreWith": "./restore-tenant.sh <slug> --from <ref> --dry-run   (rehearse first)",
}
path = os.path.join(os.environ["BK_OUT"], "manifest.json")
with open(path, "w") as fh:
    json.dump(manifest, fh, indent=2, sort_keys=True)
    fh.write("\n")
print("   manifest: expires %s (keep %d months)" % (manifest["retention"]["expiresAt"], keep))
PY

chmod 700 "$OUT_DIR"
REF="${OUT_DIR#"${BACKUP_ROOT}"/}"
bk_log "archived '${SLUG}': $(du -sh "$OUT_DIR" | cut -f1)"
printf 'ref=%s\n' "$REF"
