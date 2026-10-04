#!/usr/bin/env bash
# Keep the seven backend rollout contracts default-off and operator-owned.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
# shellcheck source=../tenant-feature-flags.sh
source "$ROOT/tenant-feature-flags.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Literal contract oracle: do not derive the API keys from implementation source.
contracts=(
  'TableAccountV1:TENANT_TABLE_ACCOUNT_V1'
  'OrderAmendmentsV1:TENANT_ORDER_AMENDMENTS_V1'
  'TableGuestVisitsV1:TENANT_TABLE_GUEST_VISITS_V1'
  'TableAccountPaymentsV1:TENANT_TABLE_ACCOUNT_PAYMENTS_V1'
  'TableGuestAccountPaymentsV1:TENANT_TABLE_GUEST_ACCOUNT_PAYMENTS_V1'
  'TableVisitReadinessV1:TENANT_TABLE_VISIT_READINESS_V1'
  'ServerAccountCollectionV1:TENANT_SERVER_ACCOUNT_COLLECTION_V1'
)
for contract in "${contracts[@]}"; do
  field="${contract%%:*}" key="${contract#*:}"
  mapping="TenantFeatures__${field}: \"\${${key}:-false}\""
  for compose in docker-compose.prod.yml tenants/templates/docker-compose.tenant.yml.tpl; do
    [[ "$(grep -Fc "$mapping" "$ROOT/$compose" || true)" == 1 ]] \
      || { echo "missing or duplicate default-off mapping: $field" >&2; exit 1; }
  done
  for example in .env.example .env.staging.example tenants/templates/tenant.env.tpl; do
    [[ "$(grep -xc "$key=false" "$ROOT/$example" || true)" == 1 ]] \
      || { echo "missing default-off example: $key" >&2; exit 1; }
  done
  for value in '' true false TRUE False '  true  '; do
    printf '%s=%s\n' "$key" "$value" > "$WORK/.env"
    cp "$WORK/.env" "$WORK/before"
    validate_table_account_env "$WORK/.env" demo
    cmp -s "$WORK/before" "$WORK/.env"
  done
  for value in yes 1 maybe 't r u e' 'false true' '"true"'; do
    printf '%s=%s\n' "$key" "$value" > "$WORK/.env"
    if validate_table_account_env "$WORK/.env" demo >/dev/null 2>&1; then
      echo "invalid $key accepted" >&2; exit 1
    fi
  done
  for second in true false ''; do
    printf '%s=true\n%s=%s\n' "$key" "$key" "$second" > "$WORK/.env"
    if validate_table_account_env "$WORK/.env" demo >/dev/null 2>&1; then
      echo "duplicate $key accepted" >&2; exit 1
    fi
  done
  : > "$WORK/.env"
  env "$key=true" bash "$ROOT/tenant-feature-flags.sh" "$WORK/.env" demo >/dev/null
  if env "$key=maybe" bash "$ROOT/tenant-feature-flags.sh" "$WORK/.env" demo >/dev/null 2>&1; then
    echo "invalid shell override for $key accepted" >&2; exit 1
  fi
  printf '  ok   %s mappings, preservation and refusal controls\n' "$field"
done

: > "$WORK/.env"
validate_table_account_env "$WORK/.env" demo
# An unrelated setting is outside this validator's scope.
printf 'UNRELATED_FLAG=maybe\n' > "$WORK/.env"
validate_table_account_env "$WORK/.env" demo
if validate_table_account_env "$WORK/missing" demo >/dev/null 2>&1; then
  echo 'missing env accepted' >&2; exit 1
fi
# Existing provisioning callers also reject duplicates through the shared validator.
printf 'TENANT_SERVER_WORKSPACE_V2=true\nTENANT_SERVER_WORKSPACE_V2=false\n' > "$WORK/.env"
if validate_bool_env_line TENANT_SERVER_WORKSPACE_V2 demo "$WORK/.env" >/dev/null 2>&1; then
  echo 'existing Server Workspace duplicate accepted' >&2; exit 1
fi
# Both entry points call the same validation before recreating containers.
# shellcheck disable=SC2016 # Check literal production calls.
grep -Fq 'validate_table_account_env "$TENANT_DIR/.env" "$SLUG"' "$ROOT/provision-tenant.sh"
grep -Fq 'validate_table_account_env .env main-stack' "$ROOT/deploy.sh"
bash "$ROOT/tenant-feature-flags.sh" "$WORK/.env" demo >/dev/null
if bash "$ROOT/tenant-feature-flags.sh" "$WORK/missing" demo >/dev/null 2>&1; then
  echo 'standalone validator accepted missing file' >&2; exit 1
fi
echo 'table-account-rollout: all checks passed'
