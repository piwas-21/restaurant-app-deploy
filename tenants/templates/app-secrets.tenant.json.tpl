{
  "_comment": "TENANT template (sofra ADR-003). Rendered by provision-tenant.sh into /opt/rumi/tenants/<slug>/app-secrets.json (box-only, never committed). Fresh JWT secret + printer key per tenant; issuer/audience are tenant-scoped so tokens never validate across instances.",

  "JwtSettings": {
    "Secret": "__JWT_SECRET__",
    "Issuer": "sofra-__SLUG__",
    "Audience": "sofra-__SLUG__",
    "ExpiryMinutes": 60,
    "RefreshTokenExpiryDays": 7
  },

  "_email_note": "FromEmail is rendered from PLATFORM_MAIL_DOMAIN on the box (<slug>@<domain>), or from the entry's `mail_from:` when the tenant brings its own verified domain. FromName stays the restaurant, so the guest sees the restaurant and not the vendor. If PLATFORM_MAIL_DOMAIN is unset this renders Resend's shared onboarding@resend.dev, which reaches ONLY the Resend account owner's address (403 for everyone else) — provisioning warns about it. Reputation-protection rule is unchanged: never send as rumirestaurant.ch.",
  "EmailSettings": {
    "Provider": "Resend",
    "ResendApiKey": "__RESEND_API_KEY__",
    "FromEmail": "__FROM_EMAIL__",
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
