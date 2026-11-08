import { describe, expect, test } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import { join, relative } from "node:path";

// WAG-319 (after HAIL-222): the daemon never touches a session folder or a project folder.
// macOS asks "Waggle would like to access files in your Documents folder" when the app or the
// daemon does. Only the shim, inside the agent's process, may read a project folder.
const SRC = join(import.meta.dir, "..", "src");

// Files that run in the shim only (or in the user's own terminal), never in the daemon.
const SHIM_ONLY = new Set([
  "mcp/shim.ts",
  "sessions/footprint.ts",
  "sessions/naming.ts",
  "guide/design-kit.ts",
  "artifacts/stage.ts",
  "cli/test-ask.ts",
]);
// Names that read a project folder. The daemon must not import or call them.
const PROJECT_READERS = ["gitFootprint", "gitRoot(", "gitBranch(", "readDesignKit", "stageBundle", "stageMarkdown", "stageScreenshot"];

function sourceFiles(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
    const p = join(dir, e.name);
    if (e.isDirectory()) return sourceFiles(p);
    return p.endsWith(".ts") && !p.endsWith(".test.ts") ? [p] : [];
  });
}

describe("the daemon never touches a project folder", () => {
  const files = sourceFiles(SRC).map((p) => ({ rel: relative(SRC, p), text: readFileSync(p, "utf8") }));
  const daemonFiles = files.filter((f) => !SHIM_ONLY.has(f.rel));

  test("no daemon file calls a project-folder reader", () => {
    const hits = daemonFiles.flatMap((f) =>
      PROJECT_READERS.filter((name) => f.text.includes(name)).map((name) => `${f.rel}: ${name}`),
    );
    expect(hits).toEqual([]);
  });

  test("no daemon file runs git on a path", () => {
    const hits = daemonFiles.filter((f) => /["']git["']/.test(f.text)).map((f) => f.rel);
    expect(hits).toEqual([]);
  });

  test("no daemon file passes a session cwd to a filesystem call", () => {
    const fsCall = /(existsSync|statSync|lstatSync|readdirSync|readFileSync|realpathSync|accessSync|opendirSync)\(\s*[^)]*\bcwd\b/;
    const hits = daemonFiles.filter((f) => fsCall.test(f.text)).map((f) => f.rel);
    expect(hits).toEqual([]);
  });
});
