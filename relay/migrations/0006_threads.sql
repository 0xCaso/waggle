-- WAG-394: reply threads, resolve, the decision, closed comments, a question for each round, and a
-- record of stopped links.

-- The agent can reply, so author_kind takes "agent". SQLite cannot change a CHECK, so the table is rebuilt.
-- parent_id: one level only (a reply to a reply is stored against the root). resolved_at and resolved_by sit on
-- the root comment of a thread. author_key = the limit key of the writer (u:<user> or s:<session>), used only to
-- say who may resolve their own comment. It is never sent out.
CREATE TABLE comments_new (
  id TEXT PRIMARY KEY,
  case_id TEXT NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
  round_seq INTEGER NOT NULL,
  commit_id TEXT NOT NULL,
  path TEXT,
  quote TEXT,
  prefix TEXT,
  suffix TEXT,
  body TEXT NOT NULL,
  author_kind TEXT NOT NULL CHECK (author_kind IN ('guest', 'email', 'owner', 'agent')),
  author_name TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  box TEXT,
  author_email TEXT,
  author_user_id TEXT,
  parent_id TEXT,
  resolved_at INTEGER,
  resolved_by TEXT,
  author_key TEXT
);
INSERT INTO comments_new (id, case_id, round_seq, commit_id, path, quote, prefix, suffix, body, author_kind, author_name, created_at, box, author_email, author_user_id)
  SELECT id, case_id, round_seq, commit_id, path, quote, prefix, suffix, body, author_kind, author_name, created_at, box, author_email, author_user_id FROM comments;
DROP TABLE comments;
ALTER TABLE comments_new RENAME TO comments;
CREATE INDEX comments_by_case ON comments (case_id, created_at);
CREATE INDEX comments_by_parent ON comments (parent_id);

-- The decision. status = open | decided. decided is JSON: {"options": [titles], "note"?, "at"}.
-- comments_closed = 1 when the owner closed the comments.
ALTER TABLE cases ADD COLUMN status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'decided'));
ALTER TABLE cases ADD COLUMN decided TEXT;
ALTER TABLE cases ADD COLUMN comments_closed INTEGER NOT NULL DEFAULT 0;

-- The question of each round. The page shows the question that belongs to the round it shows.
ALTER TABLE rounds ADD COLUMN ask TEXT;

-- A stopped link keeps a trace, so the page can say it was stopped and not "not here".
CREATE TABLE stopped_cases (
  id TEXT PRIMARY KEY,
  stopped_at INTEGER NOT NULL
);
