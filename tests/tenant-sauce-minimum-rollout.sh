#!/usr/bin/env bash
# Keep the sauce-minimum switch restaurant-scoped and default-off at both
# Compose entry points. Re-provisioning must reject malformed tenant values.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
MAIN="$ROOT/docker-compose.prod.yml"
TENANT="$ROOT/tenants/templates/docker-compose.tenant.yml.tpl"
ENV_TPL="$ROOT/tenants/templates/tenant.env.tpl"
PROVISION="$ROOT/provision-tenant.sh"

# shellcheck disable=SC2016 # Match the literal Compose expression.
grep -Fq 'TenantFeatures__EnforceSauceMinimum: "${ENFORCE_SAUCE_MINIMUM:-false}"' "$MAIN"
# shellcheck disable=SC2016 # Match the literal Compose expression.
grep -Fq 'TenantFeatures__EnforceSauceMinimum: "${TENANT_ENFORCE_SAUCE_MINIMUM:-false}"' "$TENANT"
grep -qx 'TENANT_ENFORCE_SAUCE_MINIMUM=false' "$ENV_TPL"
# shellcheck disable=SC2016 # Match the provisioning source, not an env value.
grep -Fq 'validate_bool_env_line TENANT_ENFORCE_SAUCE_MINIMUM "$SLUG"' "$PROVISION"

for example in "$ROOT/.env.example" "$ROOT/.env.staging.example"; do
  grep -qx 'ENFORCE_SAUCE_MINIMUM=false' "$example"
done

echo 'tenant-sauce-minimum-rollout: all checks passed'
