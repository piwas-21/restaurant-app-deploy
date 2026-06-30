#!/usr/bin/env bash
# Scaffold .env and app-secrets.json with freshly generated random secrets.
# Run ON THE BOX (or locally) from /opt/rumi/deploy. Never commits anything
# (.env and app-secrets.json are git-ignored). Existing files are NOT
# overwritten — delete them first if you want fresh values.
#
#   ./gen-secrets.sh
#
# Generates: POSTGRES_PASSWORD, JwtSettings.Secret, PrinterSettings.ApiKey.
# You still must fill by hand: SMTP creds (Infomaniak), AdminEmail, and
# (if used) Android/iOS Google client IDs. The script prints the TODO list.
set -euo pipefail
cd "$(dirname "$0")"

# URL/connection-string-safe randoms (no / + = which can break the PG conn string or JSON)
rand() { openssl rand -base64 "$1" | tr -d '/+=' | cut -c1-"$2"; }
POSTGRES_PASSWORD="$(rand 48 32)"
JWT_SECRET="$(openssl rand -base64 48)"   # JSON string — base64 is fine here
PRINTER_APIKEY="$(openssl rand -hex 32)"

if [[ -f .env ]]; then
  echo "skip: .env already exists"
else
  sed -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${POSTGRES_PASSWORD}|" .env.example > .env
  echo "wrote .env (POSTGRES_PASSWORD set)"
fi

if [[ -f app-secrets.json ]]; then
  echo "skip: app-secrets.json already exists"
else
  sed -e "s|REPLACE_WITH_openssl_rand_base64_48|${JWT_SECRET}|" \
      -e "s|REPLACE_WITH_openssl_rand_hex_32|${PRINTER_APIKEY}|" \
      app-secrets.example.json > app-secrets.json
  chmod 600 app-secrets.json
  echo "wrote app-secrets.json (JWT + printer key set, mode 600)"
fi

cat <<'EOF'

Still TODO by hand in app-secrets.json:
  • EmailSettings.SmtpUsername / SmtpPassword   -> from Infomaniak mailbox
  • EmailSettings.AdminEmail / FromEmail        -> the addresses to use
  • Authentication.Google.AndroidClientId/IosClientId -> only if you have those clients (else leave "")
And in Google Cloud console:
  • Add https://www.rumirestaurant.ch to the OAuth client's Authorized JavaScript origins
EOF
