#!/usr/bin/env bash
# Pull the pinned GHCR images and (re)start the RUMI stack.
# Run as the deploy user from /opt/rumi/deploy.
#
# Per-service image tags live in .env (BACKEND_TAG / FRONTEND_TAG) and are the
# source of truth for what is deployed. A one-off override updates .env, then
# deploys — so a rollback survives the next restart but the next real release
# moves the service forward again.
#
#   ./deploy.sh                          # deploy whatever .env currently pins
#   BACKEND_TAG=latest ./deploy.sh       # roll backend forward to latest (CI auto-deploy)
#   BACKEND_TAG=sha-<40hex> ./deploy.sh  # roll backend back to a specific build
#   FRONTEND_TAG=v1.2.3 ./deploy.sh      # pin frontend to a release tag
set -euo pipefail

cd "$(dirname "$0")"
COMPOSE="docker compose -f docker-compose.prod.yml"
BE_REPO="ghcr.io/piwas-21/restaurant-app-backend"

echo "==> Preflight: required config present"
[[ -f .env ]] || { echo "ERROR: .env missing (cp .env.example .env and fill in)"; exit 1; }
[[ -f app-secrets.json ]] || { echo "ERROR: app-secrets.json missing (cp app-secrets.example.json app-secrets.json and fill in)"; exit 1; }

# Upsert KEY=VALUE in .env (replace in place, or append if absent).
upsert_env() {
  local key="$1" val="$2"
  if grep -q "^${key}=" .env; then
    sed -i "s|^${key}=.*|${key}=${val}|" .env
  else
    printf '%s=%s\n' "$key" "$val" >> .env
  fi
}

# Apply one-off tag overrides passed in the environment (CI sets these), then
# seed any still-missing tag from the legacy IMAGE_TAG (or "latest").
if [[ -n "${BACKEND_TAG:-}" ]];  then upsert_env BACKEND_TAG  "${BACKEND_TAG}";  fi
if [[ -n "${FRONTEND_TAG:-}" ]]; then upsert_env FRONTEND_TAG "${FRONTEND_TAG}"; fi
grep -q '^BACKEND_TAG='  .env || upsert_env BACKEND_TAG  "${IMAGE_TAG:-latest}"
grep -q '^FRONTEND_TAG=' .env || upsert_env FRONTEND_TAG "${IMAGE_TAG:-latest}"

BE_TAG=$(grep '^BACKEND_TAG='  .env | cut -d= -f2-)
FE_TAG=$(grep '^FRONTEND_TAG=' .env | cut -d= -f2-)
echo "==> Deploying  backend=${BE_TAG}  frontend=${FE_TAG}"

# GHCR pull: public packages need no login. If the packages are private,
# run once:  echo "$GHCR_PAT" | docker login ghcr.io -u <user> --password-stdin
echo "==> Pull images"
$COMPOSE pull

# The backend runs as a non-root user (uid/gid baked in the image, e.g. 1654).
# app-secrets.json is mounted read-only and is written 600 by gen-secrets.sh, so
# the container user can't read it. Make it group-readable by the backend's gid
# (owner rumi keeps write; not world-readable).
echo "==> Fix app-secrets.json perms for the backend container user"
BE_GID=$(docker run --rm --entrypoint sh "${BE_REPO}:${BE_TAG}" -c 'id -g' 2>/dev/null || echo "")
if [[ -n "$BE_GID" ]]; then
  sudo chown "$(id -un):${BE_GID}" app-secrets.json && chmod 640 app-secrets.json
  echo "   app-secrets.json -> group ${BE_GID}, mode 640"
else
  echo "   WARN: could not determine backend gid; ensure app-secrets.json is readable by the container user"
fi

echo "==> Up"
$COMPOSE up -d

echo "==> Prune dangling images"
docker image prune -f

echo "==> Status"
$COMPOSE ps
echo "Tail backend startup (migrations/seed):  $COMPOSE logs -f backend"
