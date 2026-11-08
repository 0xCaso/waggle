-- The question the agent asked, shown above the round. JSON: {"need","why"?,"recommendation"?,"options"?}.
-- The latest ask wins: a new round may send a new one.
ALTER TABLE cases ADD COLUMN ask TEXT;
