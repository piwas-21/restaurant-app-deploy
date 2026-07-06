{
  "_comment": "TENANT template (sofra ADR-003). Rendered by provision-tenant.sh into /opt/rumi/tenants/<slug>/app-secrets.json (box-only, never committed). Fresh JWT secret + printer key per tenant; issuer/audience are tenant-scoped so tokens never validate across instances.",

  "JwtSettings": {
    "Secret": "__JWT_SECRET__",
    "Issuer": "sofra-__SLUG__",
    "Audience": "sofra-__SLUG__",
    "ExpiryMinutes": 60,
    "RefreshTokenExpiryDays": 7
  },

  "_email_note": "Tenants send via the shared Resend onboarding sender until a per-tenant (or sofra brand) sending domain is verified — same reputation-protection rule as staging: never send as rumirestaurant.ch.",
  "EmailSettings": {
    "Provider": "Resend",
    "ResendApiKey": "__RESEND_API_KEY__",
    "FromEmail": "onboarding@resend.dev",
    "FromName": "__TENANT_NAME__",
    "AdminEmail": "__ADMIN_EMAIL__",
    "FrontendBaseUrl": "https://__DOMAIN__",
    "BackendBaseUrl": "https://__DOMAIN__"
  },

  "CorsSettings": {
    "AllowedOrigins": [
      "https://__DOMAIN__"
    ]
  },

  "_google_note": "Empty ClientId = Google login disabled for this tenant (only read per-request in GoogleLoginCommandHandler, startup is unaffected). To enable: register https://<domain> as an authorized JS origin on an OAuth client, put its id here AND rebuild the tenant frontend image with google_client_id.",
  "Authentication": {
    "Google": {
      "ClientId": "",
      "AndroidClientId": "",
      "IosClientId": ""
    }
  },

  "PrinterSettings": {
    "ApiKey": "__PRINTER_APIKEY__"
  },

  "FileStorage": {
    "Provider": "Local"
  },
  "LocalStorage": {
    "BaseUrl": "https://__DOMAIN__/uploads"
  }
}
