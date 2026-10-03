#!/usr/bin/env bash
# Execute both production env branches with fixture identity/credential helpers.
# No Docker, registry lookup, real credentials or database operations are involved.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
# shellcheck source=../tenant-feature-flags.sh
source "$ROOT/tenant-feature-flags.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
sed -n '/^# --- BEGIN tenant-env-rollout /,/^# --- END tenant-env-rollout /p' \
  "$ROOT/provision-tenant.sh" > "$WORK/env-branch.sh"
grep -Fq 'validate_table_account_env' "$WORK/env-branch.sh"
mkdir -p "$WORK/tenants/templates"
cp "$ROOT/tenants/templates/tenant.env.tpl" "$WORK/tenants/templates/tenant.env.tpl"

# Inputs unrelated to rollout policy are fixtures. Keep the real rendering branch,
# real template and real validator; identity setters cannot change a rollout choice.
run_branch() (
  set -euo pipefail
  local mode="$1" override="$2"
  cd "$WORK"
  export TENANT_TABLE_ACCOUNT_V1="$override"
  TENANT_DIR="$WORK/$mode"
  mkdir -p "$TENANT_DIR"
  if [[ "$mode" == existing ]]; then
    printf 'TENANT_TABLE_ACCOUNT_V1=true\n' > "$TENANT_DIR/.env"
  fi
  export SLUG=rollout-fixture
  export REG_DOMAIN=fixture.invalid REG_BACKEND_TAG=staging REG_FRONTEND_TAG=staging
  export REG_DB=fixture REG_DB_ROLE=fixture REG_ADMIN_EMAIL=fixture
  export REG_CURRENCY=CHF REG_LANGUAGES=en REG_MODULES=core
  export ENV_NAME=Fixture ENV_CITY=Fixture TENANT_TEMPLATE=classic
  rand() { printf '%s' fixture; }
  gen_admin_password() { printf '%s' fixture; }
  sed_escape() { printf '%s' "$1"; }
  strip_ws() { printf '%s' "$1"; }
  set_env_line() { :; }
  # shellcheck disable=SC1091 # Production branch is extracted above, not a static file.
  source "$WORK/env-branch.sh"
)

for mode in fresh existing; do
  if run_branch "$mode" maybe >/dev/null 2>&1; then
    echo "$mode provision accepted malformed shell override" >&2; exit 1
  fi
  rm -rf "${WORK:?}/${mode:?}"
  run_branch "$mode" true >/dev/null
  if [[ "$mode" == fresh ]]; then
    grep -qx 'TENANT_TABLE_ACCOUNT_V1=false' "$WORK/$mode/.env"
  else
    grep -qx 'TENANT_TABLE_ACCOUNT_V1=true' "$WORK/$mode/.env"
  fi
  printf '  ok   %s provision validates shell overrides and preserves template/operator value\n' "$mode"
done
echo 'table-account-provision-rollout: all checks passed'
