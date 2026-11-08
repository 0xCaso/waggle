export interface Env {
  DB: D1Database;
  ARTIFACTS?: Artifacts;
  ROUND_STORE: "artifacts" | "d1";
  // The page and the API.
  APP_ORIGIN: string;
  // Artifact files only. A different site from APP_ORIGIN, so untrusted HTML cannot reach the app's cookies.
  CONTENT_ORIGIN: string;
  // Signs the content tickets. A secret (wrangler secret put TICKET_SECRET), .dev.vars locally.
  TICKET_SECRET: string;
  // Sign-in email (WAG-392): the Workers send_email binding `EMAIL`. Without it (local dev, tests) the
  // relay records the mail in dev_outbox.
  EMAIL?: SendEmail;
  // The sender address of that mail. Its domain must be onboarded in Cloudflare Email Service.
  // Default: signin@waggle.so (the waggle.so relay). A self-hosted relay sets its own.
  MAIL_FROM?: string;
  // Google sign-in. Worker secrets (wrangler secret put). Without both, the sign-in page has no Google button.
  GOOGLE_CLIENT_ID?: string;
  GOOGLE_CLIENT_SECRET?: string;
  // "1" in local dev and tests only. Turns on the dev outbox route and the Google endpoint overrides.
  // Never set in the production environment.
  DEV_MODE?: string;
  GOOGLE_AUTH_URL?: string;
  GOOGLE_TOKEN_URL?: string;
}
