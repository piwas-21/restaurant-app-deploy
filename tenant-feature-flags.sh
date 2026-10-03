#!/usr/bin/env bash
# Shared, read-only validation for operator-controlled rollout settings.
# May also be run before a manual Compose recreation:
#   bash tenant-feature-flags.sh /path/to/.env tenant-label

validate_bool_env_value() { # $1=value $2=key $3=label
  local value="$1" key="$2" label="$3"
  case "$value" in
    ''|[Tt][Rr][Uu][Ee]|[Ff][Aa][Ll][Ss][Ee]) return 0 ;;
    *) echo "ERROR: '$label' has invalid $key; use true or false" >&2; return 1 ;;
  esac
}

validate_bool_env_line() { # $1=key $2=label $3=env file (optional for provision callers)
  local key="$1" label="$2" file="${3:-${TENANT_DIR}/.env}" count value
  [[ -f "$file" ]] || { echo "ERROR: feature configuration file missing" >&2; return 1; }
  count="$(grep -c "^${key}=" "$file" || true)"
  if (( count > 1 )); then
    echo "ERROR: '$label' has duplicate $key entries; keep exactly one operator choice" >&2
    return 1
  fi
  # Compose applies its declared default to absent or empty values. Trim only edges:
  # internal whitespace must not reach the backend's C# boolean binder.
  value="$(grep -m1 "^${key}=" "$file" | cut -d= -f2- \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' || true)"
  validate_bool_env_value "$value" "$key" "$label"
}

validate_table_account_env() { # $1=env file $2=label
  local file="$1" label="$2" key
  for key in TENANT_TABLE_ACCOUNT_V1 TENANT_ORDER_AMENDMENTS_V1 \
    TENANT_TABLE_GUEST_VISITS_V1 TENANT_TABLE_ACCOUNT_PAYMENTS_V1 \
    TENANT_TABLE_GUEST_ACCOUNT_PAYMENTS_V1 TENANT_TABLE_VISIT_READINESS_V1 \
    TENANT_SERVER_ACCOUNT_COLLECTION_V1; do
    validate_bool_env_line "$key" "$label" "$file" || return 1
    # Exported shell values take precedence over .env in Compose. Reject a malformed
    # override too; do not print its value or evaluate the configuration as shell code.
    validate_bool_env_value "${!key-}" "$key" "$label environment override" || return 1
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  validate_table_account_env "${1:?usage: $0 <env-file> <label>}" "${2:-table-account-stack}"
  echo 'table-account feature configuration: valid'
fi
