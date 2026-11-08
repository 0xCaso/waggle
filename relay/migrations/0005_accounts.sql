-- Accounts (WAG-392). A person has one user row, whatever way they sign in (email link or Google).
-- Every token is stored as a SHA-256 hash. The plain token exists only in the link, cookie or Keychain item.

CREATE TABLE users (
  id TEXT PRIMARY KEY,
  email TEXT NOT NULL UNIQUE,
  google_sub TEXT UNIQUE,
  name TEXT,
  created_at INTEGER NOT NULL
);

-- The cookie `wr_session` on the web. One row per browser.
CREATE TABLE web_sessions (
  token_hash TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);

-- One Mac that signed in through the device flow. label = the Mac name.
CREATE TABLE device_tokens (
  token_hash TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  label TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  last_used_at INTEGER,
  revoked_at INTEGER
);
CREATE INDEX device_tokens_by_user ON device_tokens (user_id);

-- One-time links. purpose = signin (email link) or google (the OIDC state).
CREATE TABLE signin_links (
  token_hash TEXT PRIMARY KEY,
  email TEXT,
  purpose TEXT NOT NULL CHECK (purpose IN ('signin', 'google')),
  next TEXT NOT NULL DEFAULT '/',
  user_id TEXT,
  expires_at INTEGER NOT NULL,
  used_at INTEGER
);

-- The Mac connect flow. The device code is stored as a hash. The device token is made when the Mac
-- collects it (collected_at), so no plain token sits in the database.
CREATE TABLE device_codes (
  device_code_hash TEXT PRIMARY KEY,
  user_code TEXT NOT NULL UNIQUE,
  label TEXT NOT NULL,
  user_id TEXT REFERENCES users(id) ON DELETE CASCADE,
  expires_at INTEGER NOT NULL,
  approved_at INTEGER,
  collected_at INTEGER
);

-- Fixed-window counters. window = floor(now / window length).
CREATE TABLE rate_limits (
  key TEXT NOT NULL,
  window INTEGER NOT NULL,
  count INTEGER NOT NULL,
  PRIMARY KEY (key, window)
);

-- Local dev and tests only (no EMAIL binding): the mail the relay would have sent.
CREATE TABLE dev_outbox (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  to_email TEXT NOT NULL,
  subject TEXT NOT NULL,
  body_text TEXT NOT NULL,
  body_html TEXT NOT NULL,
  created_at INTEGER NOT NULL
);

-- A case made with an account has an owner. Cases made before this keep only their owner key.
ALTER TABLE cases ADD COLUMN owner_user_id TEXT REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE cases ADD COLUMN device_label TEXT;
CREATE INDEX cases_by_owner ON cases (owner_user_id);

-- A signed-in author keeps the email. author_kind stays owner | email | guest in storage; the API
-- shows "email" as "member".
ALTER TABLE comments ADD COLUMN author_email TEXT;
ALTER TABLE comments ADD COLUMN author_user_id TEXT;
