#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
CHECK="$ROOT/verify-sofra-catalogue-env.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'MOCK_DOCKER'
#!/usr/bin/env bash
set -euo pipefail
[[ -z "${CATALOGUE_READ_RATE_LIMIT_MAX_REQUESTS+x}" ]] || exit 91
[[ -z "${CATALOGUE_READ_RATE_LIMIT_WINDOW_MS+x}" ]] || exit 92
env_file=""
while (($#)); do
  if [[ "$1" == "--env-file" ]]; then
    env_file="$2"
    shift 2
  else
    shift
  fi
done
[[ -n "$env_file" && -f "$env_file" ]] || exit 93
max_requests="$(awk -F= '$1 == "CATALOGUE_READ_RATE_LIMIT_MAX_REQUESTS" { value = substr($0, index($0, "=") + 1) } END { print value }' "$env_file")"
window_ms="$(awk -F= '$1 == "CATALOGUE_READ_RATE_LIMIT_WINDOW_MS" { value = substr($0, index($0, "=") + 1) } END { print value }' "$env_file")"
staging_max="${MOCK_STAGING_MAX:-$max_requests}"
python3 - "$max_requests" "$window_ms" "$staging_max" <<'PY'
import json
import sys

max_requests, window_ms, staging_max = sys.argv[1:]
base_environment = {
    "CATALOGUE_READ_RATE_LIMIT_MAX_REQUESTS": max_requests,
    "CATALOGUE_READ_RATE_LIMIT_WINDOW_MS": window_ms,
}
staging_environment = dict(base_environment)
staging_environment["CATALOGUE_READ_RATE_LIMIT_MAX_REQUESTS"] = staging_max
print(json.dumps({"services": {
    "sofra": {"environment": base_environment},
    "sofra-staging": {"environment": staging_environment},
}}))
PY
MOCK_DOCKER
chmod +x "$TMP/bin/docker"

pass() { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1" >&2; exit 1; }

printf 'CATALOGUE_READ_RATE_LIMIT_MAX_REQUESTS=300\nCATALOGUE_READ_RATE_LIMIT_WINDOW_MS=900000\n' > "$TMP/.env"
if output="$(PATH="$TMP/bin:$PATH" CATALOGUE_READ_RATE_LIMIT_MAX_REQUESTS=1 \
  CATALOGUE_READ_RATE_LIMIT_WINDOW_MS=1 "$CHECK" "$TMP/.env" 2>&1)"; then
  if [[ "$output" == *"both Sofra services have valid, matching catalogue rate limits"* ]]; then
    pass "valid box .env is accepted and exported shell values are ignored"
  else
    bad "valid configuration did not report success: $output"
  fi
else
  bad "valid configuration was rejected: $output"
fi

printf 'CATALOGUE_READ_RATE_LIMIT_MAX_REQUESTS=300\n' > "$TMP/.env"
if output="$(PATH="$TMP/bin:$PATH" "$CHECK" "$TMP/.env" 2>&1)"; then
  bad "a missing rate-limit key was accepted"
elif [[ "$output" == *"sofra requires CATALOGUE_READ_RATE_LIMIT_WINDOW_MS"* \
    && "$output" == *"sofra-staging requires CATALOGUE_READ_RATE_LIMIT_WINDOW_MS"* ]]; then
  pass "missing values are rejected for both services"
else
  bad "missing-value failure did not name the affected settings: $output"
fi

printf 'CATALOGUE_READ_RATE_LIMIT_MAX_REQUESTS=0\nCATALOGUE_READ_RATE_LIMIT_WINDOW_MS=900000\n' > "$TMP/.env"
if output="$(PATH="$TMP/bin:$PATH" "$CHECK" "$TMP/.env" 2>&1)"; then
  bad "a zero request limit was accepted"
elif [[ "$output" == *"CATALOGUE_READ_RATE_LIMIT_MAX_REQUESTS to be a positive safe integer"* ]]; then
  pass "non-positive values are rejected"
else
  bad "invalid-value failure did not identify the setting: $output"
fi

printf 'CATALOGUE_READ_RATE_LIMIT_MAX_REQUESTS=300\nCATALOGUE_READ_RATE_LIMIT_WINDOW_MS=900000\n' > "$TMP/.env"
if output="$(PATH="$TMP/bin:$PATH" MOCK_STAGING_MAX=301 "$CHECK" "$TMP/.env" 2>&1)"; then
  bad "different service limits were accepted"
elif [[ "$output" == *"sofra and sofra-staging must use the same catalogue rate limits"* ]]; then
  pass "service-specific limit drift is rejected"
else
  bad "mismatched-value failure did not identify the constraint: $output"
fi

printf 'CATALOGUE_READ_RATE_LIMIT_MAX_REQUESTS=99999999999999999999\nCATALOGUE_READ_RATE_LIMIT_WINDOW_MS=900000\n' > "$TMP/.env"
if output="$(PATH="$TMP/bin:$PATH" "$CHECK" "$TMP/.env" 2>&1)"; then
  bad "an unsafe large integer was accepted"
elif [[ "$output" == *"CATALOGUE_READ_RATE_LIMIT_MAX_REQUESTS to be a positive safe integer"* ]]; then
  pass "unsafe large integers are rejected cleanly"
else
  bad "large-value failure did not identify the setting: $output"
fi

echo "sofra-catalogue-config: all checks passed"
