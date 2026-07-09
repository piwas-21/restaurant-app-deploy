#!/usr/bin/env bash
# Nightly OFF-BOX backup shipping — PROD BOX ONLY, as root, after backup-dump.sh
# (cron 03:00; see DEPLOYMENT.md §Backups & restore). Cross-box design: each
# box's data must survive the loss of its own box.
#   repo A  sftp://<staging>/opt/rumi/backups/restic-prod   <- THIS box's dumps
#   repo B  /opt/rumi/backups/restic-staging (local)        <- staging's dumps,
#           rsync-pulled here first (prod holds the only cross-box key:
#           prod->staging; staging never gets a key to prod).
# Both repos are restic-encrypted (RESTIC_PASSWORD). Config outside git:
# /root/.rumi-backup-env — template in DEPLOYMENT.md. Swap REPO_PROD to an
# s3:/b2: URL there later for a third-party off-site target (cost plan §10.1).
set -euo pipefail

ENV_FILE="/root/.rumi-backup-env"
[[ -f "$ENV_FILE" ]] || { echo "ERROR: $ENV_FILE missing — one-time setup in DEPLOYMENT.md §Backups"; exit 1; }
# shellcheck source=/dev/null
source "$ENV_FILE"
: "${RESTIC_PASSWORD:?RESTIC_PASSWORD not set in $ENV_FILE}"
export RESTIC_PASSWORD

STAGING_HOST="${STAGING_HOST:-159.195.34.105}"
STAGING_USER="${STAGING_USER:-rumi}"
SSH_KEY="${SSH_KEY:-/root/.ssh/rumi_backup_ed25519}"
DUMP_DIR="/opt/rumi/backups/dumps"
MIRROR_DIR="/opt/rumi/backups/staging-mirror"
REPO_PROD="${REPO_PROD:-sftp:${STAGING_USER}@${STAGING_HOST}:/opt/rumi/backups/restic-prod}"
REPO_STAGING_LOCAL="${REPO_STAGING_LOCAL:-/opt/rumi/backups/restic-staging}"
SSH_CMD="ssh -i ${SSH_KEY} -o IdentitiesOnly=yes -o ConnectTimeout=15"
SFTP_CMD="${SSH_CMD} ${STAGING_USER}@${STAGING_HOST} -s sftp"
KEEP=(--keep-daily 7 --keep-weekly 4 --keep-monthly 6)

command -v restic >/dev/null || { echo "ERROR: restic not installed (apt-get install -y restic)"; exit 1; }
[[ -f "$SSH_KEY" ]] || { echo "ERROR: ${SSH_KEY} missing — one-time setup in DEPLOYMENT.md §Backups"; exit 1; }
[[ -d "$DUMP_DIR" ]] || { echo "ERROR: ${DUMP_DIR} missing — has backup-dump.sh run?"; exit 1; }

echo "==> [$(date -u +%FT%TZ)] backup-offsite start"

# Repo A FIRST: shipping prod's data off-box is the crown jewel — it must not
# be skipped because the staging-dump pull (a different concern) failed.
echo "==> restic repo A: prod dumps -> staging box"
restic -r "$REPO_PROD" -o "sftp.command=${SFTP_CMD}" backup "$DUMP_DIR" --tag prod-dumps
restic -r "$REPO_PROD" -o "sftp.command=${SFTP_CMD}" forget "${KEEP[@]}" --prune
restic -r "$REPO_PROD" -o "sftp.command=${SFTP_CMD}" check --read-data-subset=10%

echo "==> pull staging dumps -> ${MIRROR_DIR}"
install -d -m 700 "$MIRROR_DIR"
rsync -az --delete -e "$SSH_CMD" \
  "${STAGING_USER}@${STAGING_HOST}:/opt/rumi/backups/dumps/" "${MIRROR_DIR}/"

echo "==> restic repo B: staging mirror -> prod-local repo"
restic -r "$REPO_STAGING_LOCAL" backup "$MIRROR_DIR" --tag staging-dumps
restic -r "$REPO_STAGING_LOCAL" forget "${KEEP[@]}" --prune
restic -r "$REPO_STAGING_LOCAL" check --read-data-subset=10%

echo "==> latest snapshots (A then B)"
restic -r "$REPO_PROD" -o "sftp.command=${SFTP_CMD}" snapshots --latest 1 --compact
restic -r "$REPO_STAGING_LOCAL" snapshots --latest 1 --compact

echo "==> [$(date -u +%FT%TZ)] backup-offsite done"
