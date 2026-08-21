#!/usr/bin/env bash
# ERASURE — delete a tenant's backup artifacts, on request. This is the script that makes
# the multi-year archive defensible: a copy you cannot delete on request is not a backup
# policy, it is an unbounded liability.
#
#   ./backup-erase-tenant.sh <slug> --confirm <slug>                # every artifact of that tenant
#   ./backup-erase-tenant.sh <slug> --confirm <slug> --ref <ref>    # one artifact
#   ./backup-erase-tenant.sh <slug> --confirm <slug> --dry-run      # show, delete nothing
#
# Reached three ways: by hand (a GDPR erasure request routed through docs/privacy/dsr.md),
# by the control plane (a `delete` job — see backup-agent.sh, and note it is OPT-IN per box),
# and by the retention horizon itself (backup-archive-tenant.sh --prune).
#
# WHAT IT REACHES, honestly, because a half-answer here is worse than none:
#   * dumps/tenants/<slug>/…        — this tenant's own dumps          -> DELETED
#   * archive/<slug>/…              — this tenant's long archive       -> DELETED
#   * restic snapshots on this box  — via `restic rewrite --exclude`, which strips the
#                                     paths out of existing snapshots  -> REWRITTEN (prod)
#   * cluster-<ts>.sql.gz           — the whole-cluster pg_dumpall     -> NOT TOUCHED
#   * tenants-<ts>.tar.gz           — the box-wide tenant files tar    -> NOT TOUCHED
#
# The last two are the honest residual: they are single objects covering the whole box, so
# surgically removing one tenant from them would mean rewriting every historical dump, and
# a rewritten backup is no longer the backup that was taken. They age out on the ordinary
# operational schedule instead — 7 days locally, and at most ~6 months off-box
# (`--keep-monthly 6`). That is the standard, documented position for backup media under
# GDPR: erasure is immediate in live systems and in long-term storage, and residual copies
# in time-boxed rolling backups expire on a stated schedule and are not restored into
# production without re-applying the erasure. It is stated in DEPLOYMENT.md §Backups so it
# can be shown to whoever asks.
#
# Cross-box: staging holds every managed tenant; prod holds the mirror + both restic repos
# and is the ONLY box with a key to the other (the direction is deliberate — DEPLOYMENT.md).
# So a full erasure is TWO runs: on staging (deletes the source; prod's nightly
# `rsync --delete` then removes it from the mirror), then on prod (rewrites the repos).
set -euo pipefail
cd "$(dirname "$0")"

# shellcheck source=backup-lib.sh
. ./backup-lib.sh

SLUG=""
CONFIRM=""
REF=""
DRY_RUN=false
NO_RESTIC=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm) CONFIRM="${2:?--confirm needs the slug again}"; shift 2 ;;
    --ref) REF="${2:?--ref needs a value}"; shift 2 ;;
    --dry-run|-n) DRY_RUN=true; shift ;;
    --no-restic) NO_RESTIC=true; shift ;;
    -*) bk_die "unknown flag '$1'" ;;
    *) [[ -z "$SLUG" ]] || bk_die "unexpected argument '$1'"; SLUG="$1"; shift ;;
  esac
done
[[ -n "$SLUG" ]] || bk_die "usage: $0 <slug> --confirm <slug> [--ref <ref>] [--dry-run]"
bk_slug_ok "$SLUG" || bk_die "slug must be lowercase [a-z0-9-], 2-31 chars"
# Typing the slug twice is the entire guard against erasing the wrong customer. There is
# no undo below this line and no other copy afterwards.
[[ "$CONFIRM" == "$SLUG" ]] || bk_die "refusing: pass --confirm ${SLUG} to prove you mean this tenant (this is not reversible)"

TARGETS=()
if [[ -n "$REF" ]]; then
  bk_ref_ok "$REF" "$SLUG" || bk_die "refusing ref '$REF' — must be dumps/tenants/${SLUG}/… or archive/${SLUG}/… with no traversal"
  P="${BACKUP_ROOT}/${REF}"
  [[ -e "$P" ]] || bk_die "no such artifact: ${REF}"
  TARGETS+=("$P")
else
  for d in "${TENANT_DUMP_DIR}/${SLUG}" "${ARCHIVE_DIR}/${SLUG}"; do
    [[ -e "$d" ]] && TARGETS+=("$d")
  done
fi

bk_log "erase backups for tenant '${SLUG}'${REF:+ (ref ${REF})}"
if [[ ${#TARGETS[@]} -eq 0 ]]; then
  echo "   nothing on this box to erase"
else
  for t in "${TARGETS[@]}"; do
    printf '   %s %s (%s)\n' "$($DRY_RUN && echo WOULD-DELETE || echo delete)" \
      "${t#"${BACKUP_ROOT}"/}" "$(du -sh "$t" 2>/dev/null | cut -f1)"
    if ! $DRY_RUN; then
      rm -rf "${t:?}"
      # Tombstone: slug + ref + when, never a name, an email or a byte of content. It is
      # the evidence that the request was executed, and it must not itself hold PII.
      printf '%s\terase\t%s\t%s\n' "$(bk_now)" "${t#"${BACKUP_ROOT}"/}" "requested" >> "$ERASURE_LOG"
    fi
  done
fi

# ── restic: strip the paths out of existing snapshots (prod only) ────────────────────
# `restic forget` cannot drop one path out of a snapshot; `restic rewrite` can, and
# --forget replaces the originals. Then `prune` is what actually reclaims the data — a
# rewrite alone leaves the blobs in the repo, which is precisely the thing an erasure is
# supposed to remove.
ENV_FILE="/root/.rumi-backup-env"
if $NO_RESTIC; then
  echo "==> restic skipped (--no-restic)"
elif ! command -v restic >/dev/null 2>&1 || [[ ! -f "$ENV_FILE" ]]; then
  cat <<EOF
==> restic not configured on this box — off-box copies NOT touched here.
    Expected: this is the staging box. The prod box holds both repos and the only
    cross-box key. Finish the erasure there:
      ssh prod 'cd /opt/rumi/deploy && ./backup-erase-tenant.sh ${SLUG} --confirm ${SLUG}'
    (prod's nightly rsync --delete removes this tenant from the staging mirror first,
     so run it AFTER the next 03:00 offsite run, or the rewrite will find them again.)
EOF
else
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  : "${RESTIC_PASSWORD:?RESTIC_PASSWORD not set in $ENV_FILE}"
  export RESTIC_PASSWORD
  STAGING_HOST="${STAGING_HOST:-159.195.34.105}"
  STAGING_USER="${STAGING_USER:-rumi}"
  SSH_KEY="${SSH_KEY:-/root/.ssh/rumi_backup_ed25519}"
  REPO_PROD="${REPO_PROD:-sftp:${STAGING_USER}@${STAGING_HOST}:/opt/rumi/backups/restic-prod}"
  REPO_STAGING_LOCAL="${REPO_STAGING_LOCAL:-/opt/rumi/backups/restic-staging}"
  SFTP_CMD="ssh -i ${SSH_KEY} -o IdentitiesOnly=yes -o ConnectTimeout=15 ${STAGING_USER}@${STAGING_HOST} -s sftp"

  # Every path a tenant's data can occupy in either repo. Patterns that match nothing are
  # harmless, so both repos get the full list rather than a clever per-repo subset.
  EXCLUDES=(
    --exclude "/opt/rumi/backups/dumps/tenants/${SLUG}/**"
    --exclude "/opt/rumi/backups/archive/${SLUG}/**"
    --exclude "/opt/rumi/backups/staging-mirror/tenants/${SLUG}/**"
    --exclude "/opt/rumi/backups/staging-archive-mirror/${SLUG}/**"
  )
  # Written as two branches rather than an assembled flag array: an empty array under
  # `set -u` is a bash-version minefield, and this runs as root against the only copy of
  # the data that survives the box.
  rewrite_repo() { # <restic args…>
    if $DRY_RUN; then
      restic "$@" rewrite "${EXCLUDES[@]}" --forget --dry-run
    else
      restic "$@" rewrite "${EXCLUDES[@]}" --forget
    fi
  }

  echo "==> restic repo A (prod dumps, on staging): rewrite"
  rewrite_repo -r "$REPO_PROD" -o "sftp.command=${SFTP_CMD}"
  echo "==> restic repo B (staging mirror, local): rewrite"
  rewrite_repo -r "$REPO_STAGING_LOCAL"
  if $DRY_RUN; then
    echo "   (dry run — no prune; a real run prunes both repos to reclaim the data)"
  else
    echo "==> prune both repos (this is what actually removes the blobs)"
    restic -r "$REPO_PROD" -o "sftp.command=${SFTP_CMD}" prune
    restic -r "$REPO_STAGING_LOCAL" prune
    printf '%s\terase-restic\t%s\t%s\n' "$(bk_now)" "$SLUG" "rewrite+prune both repos" >> "$ERASURE_LOG"
  fi
fi

DRY_LABEL=""
$DRY_RUN && DRY_LABEL=" (DRY RUN — nothing was deleted)"
cat <<EOF

==> Erasure pass complete for '${SLUG}'${DRY_LABEL}.
    NOT removed, by design: cluster-*.sql.gz and tenants-*.tar.gz still contain this
    tenant until they age out (7 days locally; <= ~6 months off-box). Do not restore an
    old cluster dump into production without re-running this erasure afterwards.
EOF
