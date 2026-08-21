#!/usr/bin/env bash
# Nightly OFF-BOX backup shipping — PROD BOX ONLY, as root, after backup-dump.sh
# (cron 03:00; see DEPLOYMENT.md §Backups & restore). Cross-box design: each
# box's data must survive the loss of its own box.
#   repo A  sftp://<staging>/opt/rumi/backups/restic-prod   <- THIS box's dumps
#   repo B  /opt/rumi/backups/restic-staging (local)        <- staging's dumps,
#           rsync-pulled here first (prod holds the only cross-box key:
#           prod->staging; staging never gets a key to prod).
# Each repo now holds TWO tagged series with DIFFERENT retention:
#   --tag prod-dumps / staging-dumps  rolling operational (7d/4w/6m)
#   --tag tenant-archive              departed tenants, kept ARCHIVE_KEEP_MONTHS (24)
# Both repos are restic-encrypted (RESTIC_PASSWORD). Config outside git:
# /root/.rumi-backup-env — template in DEPLOYMENT.md. Swap REPO_PROD to an
# s3:/b2: URL there later for a third-party off-site target (cost plan §10.1).
set -euo pipefail

ENV_FILE="/root/.rumi-backup-env"
[[ -f "$ENV_FILE" ]] || { echo "ERROR: $ENV_FILE missing — one-time setup in DEPLOYMENT.md §Backups" >&2; exit 1; }
# shellcheck source=/dev/null
source "$ENV_FILE"
: "${RESTIC_PASSWORD:?RESTIC_PASSWORD not set in $ENV_FILE}"
export RESTIC_PASSWORD

STAGING_HOST="${STAGING_HOST:-159.195.34.105}"
STAGING_USER="${STAGING_USER:-rumi}"
SSH_KEY="${SSH_KEY:-/root/.ssh/rumi_backup_ed25519}"
DUMP_DIR="/opt/rumi/backups/dumps"
ARCHIVE_DIR="/opt/rumi/backups/archive"
MIRROR_DIR="/opt/rumi/backups/staging-mirror"
ARCHIVE_MIRROR_DIR="/opt/rumi/backups/staging-archive-mirror"
REPO_PROD="${REPO_PROD:-sftp:${STAGING_USER}@${STAGING_HOST}:/opt/rumi/backups/restic-prod}"
REPO_STAGING_LOCAL="${REPO_STAGING_LOCAL:-/opt/rumi/backups/restic-staging}"
SSH_CMD="ssh -i ${SSH_KEY} -o IdentitiesOnly=yes -o ConnectTimeout=15"
SFTP_CMD="${SSH_CMD} ${STAGING_USER}@${STAGING_HOST} -s sftp"
# OPERATIONAL retention — the rolling series that answers "the box burned down". Tops out
# at ~6 months, and that is fine for its purpose.
KEEP=(--keep-daily 7 --keep-weekly 4 --keep-monthly 6)
# ARCHIVE retention — a DEPARTED tenant's single consolidated copy, kept for years so a
# lapsed trial that comes back still has its data. Different purpose, different clock,
# so it must not be governed by KEEP above.
#
# ⚠️ THE `--tag` ARGUMENTS BELOW ARE LOAD-BEARING. `restic forget` with no tag filter
# applies its policy to EVERY snapshot in the repo, so the moment archive snapshots share
# a repo with dump snapshots, an untagged `forget --keep-monthly 6` would quietly delete
# the multi-year archive six months in — the exact failure this whole feature exists to
# prevent. Every forget in this script is tag-scoped.
ARCHIVE_KEEP_MONTHS="${ARCHIVE_KEEP_MONTHS:-24}"
KEEP_ARCHIVE=(--keep-within "${ARCHIVE_KEEP_MONTHS}m")

command -v restic >/dev/null || { echo "ERROR: restic not installed (apt-get install -y restic)" >&2; exit 1; }
[[ -f "$SSH_KEY" ]] || { echo "ERROR: ${SSH_KEY} missing — one-time setup in DEPLOYMENT.md §Backups" >&2; exit 1; }
[[ -d "$DUMP_DIR" ]] || { echo "ERROR: ${DUMP_DIR} missing — has backup-dump.sh run?" >&2; exit 1; }

echo "==> [$(date -u +%FT%TZ)] backup-offsite start"

# Repo A FIRST: shipping prod's data off-box is the crown jewel — it must not
# be skipped because the staging-dump pull (a different concern) failed.
echo "==> restic repo A: prod dumps -> staging box"
restic -r "$REPO_PROD" -o "sftp.command=${SFTP_CMD}" backup "$DUMP_DIR" --tag prod-dumps
restic -r "$REPO_PROD" -o "sftp.command=${SFTP_CMD}" forget --tag prod-dumps "${KEEP[@]}"

# Prod's own departed-tenant archives, on the long clock. Backed up as its own snapshot
# with its own tag so the two retention policies never touch each other's data.
if [[ -d "$ARCHIVE_DIR" ]]; then
  echo "==> restic repo A: prod tenant ARCHIVE -> staging box (keep ${ARCHIVE_KEEP_MONTHS}m)"
  restic -r "$REPO_PROD" -o "sftp.command=${SFTP_CMD}" backup "$ARCHIVE_DIR" --tag tenant-archive
  restic -r "$REPO_PROD" -o "sftp.command=${SFTP_CMD}" forget --tag tenant-archive "${KEEP_ARCHIVE[@]}"
fi
# One prune per repo, after every forget for that repo — pruning is the expensive part
# and it is what actually reclaims the space both policies just released.
restic -r "$REPO_PROD" -o "sftp.command=${SFTP_CMD}" prune
restic -r "$REPO_PROD" -o "sftp.command=${SFTP_CMD}" check --read-data-subset=10%

echo "==> pull staging dumps -> ${MIRROR_DIR}"
install -d -m 700 "$MIRROR_DIR"
# --delete is deliberate and is now load-bearing twice: it keeps the mirror honest, AND
# it is how an erasure performed on staging (where every managed tenant lives) reaches
# prod's copy — backup-erase-tenant.sh relies on this run happening before the prod-side
# restic rewrite.
rsync -az --delete -e "$SSH_CMD" \
  "${STAGING_USER}@${STAGING_HOST}:/opt/rumi/backups/dumps/" "${MIRROR_DIR}/"

# Staging holds EVERY managed tenant, so staging's archive is the crown jewel of the
# long-retention promise: without this pull, a departed tenant's only copy would sit on
# the box that is least protected. `|| true` on the pull alone — an empty/absent archive
# dir on staging is the normal state until the first tenant leaves, and must not fail the
# run that has already shipped prod's data.
echo "==> pull staging tenant ARCHIVE -> ${ARCHIVE_MIRROR_DIR}"
install -d -m 700 "$ARCHIVE_MIRROR_DIR"
rsync -az --delete -e "$SSH_CMD" \
  "${STAGING_USER}@${STAGING_HOST}:/opt/rumi/backups/archive/" "${ARCHIVE_MIRROR_DIR}/" \
  || echo "   note: no archive dir on staging yet (no tenant has departed)"

echo "==> restic repo B: staging mirror -> prod-local repo"
restic -r "$REPO_STAGING_LOCAL" backup "$MIRROR_DIR" --tag staging-dumps
restic -r "$REPO_STAGING_LOCAL" forget --tag staging-dumps "${KEEP[@]}"
echo "==> restic repo B: staging tenant ARCHIVE (keep ${ARCHIVE_KEEP_MONTHS}m)"
restic -r "$REPO_STAGING_LOCAL" backup "$ARCHIVE_MIRROR_DIR" --tag tenant-archive
restic -r "$REPO_STAGING_LOCAL" forget --tag tenant-archive "${KEEP_ARCHIVE[@]}"
restic -r "$REPO_STAGING_LOCAL" prune
restic -r "$REPO_STAGING_LOCAL" check --read-data-subset=10%

echo "==> latest snapshots (A then B)"
restic -r "$REPO_PROD" -o "sftp.command=${SFTP_CMD}" snapshots --latest 1 --compact
restic -r "$REPO_STAGING_LOCAL" snapshots --latest 1 --compact

echo "==> [$(date -u +%FT%TZ)] backup-offsite done"
