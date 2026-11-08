-- The relay keeps the people and the comments. The rounds themselves live in Artifacts
-- (one repo per case) or, in local dev, in round_files.

CREATE TABLE cases (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  mode TEXT NOT NULL CHECK (mode IN ('link', 'emails')),
  owner_key_hash TEXT NOT NULL,
  repo TEXT,
  created_at INTEGER NOT NULL
);

CREATE TABLE case_emails (
  case_id TEXT NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
  email TEXT NOT NULL,
  PRIMARY KEY (case_id, email)
);

-- One row per round the owner registered. variant names the branch ("main" for the main line).
CREATE TABLE rounds (
  case_id TEXT NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
  seq INTEGER NOT NULL,
  commit_id TEXT NOT NULL,
  label TEXT NOT NULL,
  variant TEXT NOT NULL DEFAULT 'main',
  entry TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (case_id, seq),
  UNIQUE (case_id, commit_id)
);

-- Local dev only (ROUND_STORE=d1): the files of each round.
CREATE TABLE round_files (
  case_id TEXT NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
  commit_id TEXT NOT NULL,
  path TEXT NOT NULL,
  content_type TEXT NOT NULL,
  body BLOB NOT NULL,
  PRIMARY KEY (case_id, commit_id, path)
);

CREATE TABLE sessions (
  token_hash TEXT PRIMARY KEY,
  case_id TEXT NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK (kind IN ('guest', 'email', 'owner')),
  name TEXT,
  email TEXT,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);

-- One-time sign-in links: email links ("Only these emails") and owner links (open from the Mac).
CREATE TABLE sign_in_links (
  token_hash TEXT PRIMARY KEY,
  case_id TEXT NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK (kind IN ('email', 'owner')),
  email TEXT,
  expires_at INTEGER NOT NULL,
  used_at INTEGER
);

CREATE TABLE comments (
  id TEXT PRIMARY KEY,
  case_id TEXT NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
  round_seq INTEGER NOT NULL,
  commit_id TEXT NOT NULL,
  path TEXT,
  quote TEXT,
  prefix TEXT,
  suffix TEXT,
  body TEXT NOT NULL,
  author_kind TEXT NOT NULL CHECK (author_kind IN ('guest', 'email', 'owner')),
  author_name TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX comments_by_case ON comments (case_id, created_at);
