import { join } from "node:path";
import { tmpdir } from "node:os";

// No test may read the real ~/.claude/projects (HAIL-72). Point the transcript
// lookup at a folder that does not exist; tests that need transcripts set their own.
process.env.KNOCK_CLAUDE_PROJECTS ??= join(tmpdir(), "knock-no-claude-projects");
