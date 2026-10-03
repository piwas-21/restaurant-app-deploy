#!/usr/bin/env bash
# Unit test for the Server Workspace V2 rollout flag.
#
# The flag is deliberately an operator control, not a registry/module field. New tenants
# receive true from the env template, while re-provisioning must preserve an explicit true
# or false. The validator is extracted from provision-tenant.sh so this test follows the
# production preservation path rather than copying its logic.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../provision-tenant.sh"
TEMPLATE="$HERE/../tenants/templates/tenant.env.tpl"
MAIN_COMPOSE="$HERE/../docker-compose.prod.yml"
TENANT_COMPOSE="$HERE/../tenants/templates/docker-compose.tenant.yml.tpl"
[[ -f "$SCRIPT" && -f "$TEMPLATE" && -f "$MAIN_COMPOSE" && -f "$TENANT_COMPOSE" ]] \
  || { echo "missing rollout inputs" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# shellcheck source=../tenant-feature-flags.sh
source "$HERE/../tenant-feature-flags.sh"

fail=0
pass() { local description="$1"; printf '  ok   %s\n' "$description"; }
bad() { local description="$1"; printf '  FAIL %s\n' "$description"; fail=1; }

if grep -q '^TENANT_SERVER_WORKSPACE_V2=true$' "$TEMPLATE"; then
  pass 'fresh tenant template defaults Server Workspace V2 to true'
else
  bad 'fresh tenant template is missing the true default'
fi

# shellcheck disable=SC2016 # Match literal Compose variable syntax.
if grep -Fq 'TenantFeatures__ServerWorkspaceV2: "${TENANT_SERVER_WORKSPACE_V2:-true}"' "$MAIN_COMPOSE" \
    && grep -Fq 'TENANT_FEATURES_REQUEST_TIMEOUT_MS: "${TENANT_FEATURES_REQUEST_TIMEOUT_MS:-3000}"' "$MAIN_COMPOSE"; then
  pass 'main RUMI compose carries the enabled backend flag and bounded frontend lookup'
else
  bad 'main RUMI compose cannot carry the Server Workspace V2 rollout contract'
fi

# shellcheck disable=SC2016 # Match literal Compose variable syntax.
if grep -Fq 'TenantFeatures__ServerWorkspaceV2: "${TENANT_SERVER_WORKSPACE_V2:-true}"' "$TENANT_COMPOSE"; then
  pass 'provisioned tenant compose enables V2 when an older env lacks the flag'
else
  bad 'provisioned tenant compose is missing the enabled default'
fi

TENANT_DIR="$WORK/tenant"
mkdir -p "$TENANT_DIR"
for value in true false; do
  printf 'TENANT_SERVER_WORKSPACE_V2=%s\n' "$value" > "$TENANT_DIR/.env"
  before="$(cat "$TENANT_DIR/.env")"
  if validate_bool_env_line TENANT_SERVER_WORKSPACE_V2 demo \
      && [[ "$(cat "$TENANT_DIR/.env")" == "$before" ]]; then
    pass "explicit $value survives the re-provision validation path"
  else
    bad "explicit $value was rejected or rewritten"
  fi
done

printf 'TENANT_SERVER_WORKSPACE_V2=  true  \n' > "$TENANT_DIR/.env"
if validate_bool_env_line TENANT_SERVER_WORKSPACE_V2 demo; then
  pass 'leading and trailing whitespace is trimmed for validation without rewriting the env'
else
  bad 'leading or trailing whitespace was rejected instead of being trimmed for validation'
fi

printf 'TENANT_SERVER_WORKSPACE_V2=maybe\n' > "$TENANT_DIR/.env"
if validate_bool_env_line TENANT_SERVER_WORKSPACE_V2 demo >/dev/null 2>&1; then
  bad 'invalid rollout value was accepted'
else
  pass 'invalid rollout value is rejected before container recreation'
fi

printf 'TENANT_SERVER_WORKSPACE_V2=t r u e\n' > "$TENANT_DIR/.env"
if validate_bool_env_line TENANT_SERVER_WORKSPACE_V2 demo >/dev/null 2>&1; then
  bad 'internal whitespace was accepted and could be forwarded by compose'
else
  pass 'internal whitespace is rejected before compose can forward it to the backend'
fi

if (( fail )); then
  echo 'tenant-server-workspace-v2: FAILED' >&2
  exit 1
fi
echo 'tenant-server-workspace-v2: all checks passed'
