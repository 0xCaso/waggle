-- A retried share (the answer was lost) sends the same request_id and gets the same case back.
ALTER TABLE cases ADD COLUMN request_id TEXT;
CREATE UNIQUE INDEX cases_by_request ON cases (owner_key_hash, request_id) WHERE request_id IS NOT NULL;
-- The comment cursor is (created_at, id).
DROP INDEX comments_by_case;
CREATE INDEX comments_by_case ON comments (case_id, created_at, id);
-- A hash of the uploaded files, so a retried upload does not make a second round.
ALTER TABLE rounds ADD COLUMN content_id TEXT;
CREATE INDEX rounds_by_content ON rounds (case_id, content_id);
