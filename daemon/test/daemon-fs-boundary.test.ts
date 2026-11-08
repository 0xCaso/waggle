import { afterEach, describe, expect, mock, test } from "bun:test";
import { createRequire } from "node:module";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Database } from "bun:sqlite";
import { EventBus } from "../src/events";
import type { RpcServer } from "../src/server";
import { startRpcServer } from "../src/server";
import { Store } from "../src/store";
import { rmrf, rpcConnect, stageIncoming, tmpHome } from "./helpers";

// HAIL-26 acceptance: the daemon never calls stat / open / readdir (or reads)
// a path outside KNOCK_HOME. The shim does all the project-folder reading; this
// test wraps node:fs so any such access throws, then drives a full ask, reply
// and ack with a screenshot and an HTML bundle whose source lives OUTSIDE
// KNOCK_HOME.

// `createRequire` reaches the real node:fs even while mock.module replaces the
// ESM view of it below, so the wrapped functions can delegate.
const require = createRequire(import.meta.url);
const realFs = require("node:fs") as typeof import("node:fs");

// The project folder the daemon must never touch. The guard arms once the
// fixtures and incoming staging are done.
let forbiddenRoot: string | null = null;
const touched: string[] = [];

function guard(...args: unknown[]): void {
  if (forbiddenRoot === null) return;
  for (const arg of args) {
    if (typeof arg === "string" && (arg === forbiddenRoot || arg.startsWith(forbiddenRoot + "/"))) {
      touched.push(arg);
      throw new Error(`daemon touched the project folder: ${arg}`);
    }
  }
}

const WRAPPED = new Set([
  "statSync",
  "lstatSync",
  "readFileSync",
  "readdirSync",
  "realpathSync",
  "openSync",
  "accessSync",
  "existsSync",
  "copyFileSync",
  "renameSync",
  "readlinkSync",
]);

mock.module("node:fs", () => {
  const out: Record<string, unknown> = {};
  for (const key of WRAPPED) {
    const impl = realFs[key as keyof typeof realFs] as (...args: unknown[]) => unknown;
    out[key] = (...args: unknown[]) => {
      guard(...args);
      return impl(...args);
    };
  }
  return out;
});

// HAIL-222: git is a read of the project folder too. Any process the daemon spawns while the
// guard is armed, other than a tool that is not given the project folder, fails the test.
const realSpawn = Bun.spawn;
const spawned: string[][] = [];

const PNG_SIG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

const homes: string[] = [];
const projects: string[] = [];
const servers: RpcServer[] = [];

afterEach(() => {
  forbiddenRoot = null;
  (Bun as { spawn: unknown }).spawn = realSpawn;
  for (const server of servers.splice(0)) {
    try {
      server.stop();
    } catch {
      // Already stopped.
    }
  }
  for (const h of homes.splice(0)) rmrf(h);
  for (const p of projects.splice(0)) rmrf(p);
});

describe("daemon fs boundary", () => {
  test("a full ask, reply and ack never reads the project folder", async () => {
    const home = tmpHome();
    homes.push(home);
    // The agent's project folder lives OUTSIDE KNOCK_HOME.
    const projectDir = mkdtempSync(join(tmpdir(), "knock-project-"));
    projects.push(projectDir);

    // Build the project fixtures: a screenshot and an HTML bundle.
    const png = Buffer.concat([PNG_SIG, Buffer.from("boundary png")]);
    mkdirSync(join(projectDir, "shots"), { recursive: true });
    writeFileSync(join(projectDir, "shots", "a.png"), png);
    mkdirSync(join(projectDir, "proto"), { recursive: true });
    writeFileSync(join(projectDir, "proto", "index.html"), "<h1>hi</h1>");
    writeFileSync(join(projectDir, "proto", "app.js"), "let x = 1;");

    // Stage both artifacts into incoming exactly as the shim would.
    const shot = stageIncoming(home, projectDir, { type: "screenshot", path: "./shots/a.png" });
    const bundle = stageIncoming(home, projectDir, {
      type: "html_bundle",
      dir: "proto",
      entry: "index.html",
    });

    const db = new Database(join(home, "knock.db"));
    const bus = new EventBus();
    const store = new Store(db, home, bus);
    const server = startRpcServer({
      socketPath: join(home, "knock.sock"),
      store,
      bus,
      version: "0.1.0",
    });
    servers.push(server);

    // A real Claude transcript for the session, so sessions.list builds a context for it.
    const claudeRoot = mkdtempSync(join(tmpdir(), "knock-claude-"));
    projects.push(claudeRoot);
    const saved = process.env.KNOCK_CLAUDE_PROJECTS;
    process.env.KNOCK_CLAUDE_PROJECTS = claudeRoot;
    mkdirSync(join(claudeRoot, projectDir.replace(/[^A-Za-z0-9]/g, "-")), { recursive: true });
    writeFileSync(
      join(claudeRoot, projectDir.replace(/[^A-Za-z0-9]/g, "-"), "sess-boundary.jsonl"),
      JSON.stringify({ type: "ai-title", aiTitle: "Boundary" }) + "\n",
    );
    // The project is a real git repository: a daemon that ran git on it would succeed, so the
    // spawn guard is what proves it does not.
    realFs.mkdirSync(join(projectDir, ".git"), { recursive: true });

    // Arm the seam: from here on the daemon must not touch the project folder.
    forbiddenRoot = projectDir;
    (Bun as { spawn: unknown }).spawn = ((cmd: string[], ...rest: unknown[]) => {
      spawned.push(cmd);
      if (cmd.some((arg) => typeof arg === "string" && arg.startsWith(projectDir))) {
        touched.push(cmd.join(" "));
        throw new Error(`daemon ran a process on the project folder: ${cmd.join(" ")}`);
      }
      return (realSpawn as (...a: unknown[]) => unknown)(cmd, ...rest);
    }) as typeof Bun.spawn;

    const client = await rpcConnect(join(home, "knock.sock"));
    await client.request("session.hello", {
      session_id: "sess-boundary",
      cwd: projectDir,
      branch: "ome-412-x",
      git_root: projectDir,
      parent_pid: process.pid,
      changes: { files: 1, added: 2, removed: 0, clean: false, last_commit: "From the shim" },
    });

    const created = await client.request("case.create", {
      kind: "review",
      title: "Boundary check",
      need: "Approve the layout",
      why: "It needs a human eye",
      recommendation: "a",
      recommendation_why: "It is the default",
      options: [
        { id: "a", label: "Compact" },
        { id: "b", label: "Detailed" },
      ],
      artifact: shot,
    });
    const caseId = (created.result as { id: string }).id;

    const updated = await client.request("case.update", {
      case_id: caseId,
      message: "Second revision is an HTML bundle.",
      artifact: bundle,
    });
    expect((updated.result as { status: string }).status).toBe("needs_you");

    const submitted = await client.request("reply.submit", {
      case_id: caseId,
      idempotency_key: "boundary-key",
      choice: "a",
      message: "Go with A.",
      comments: [],
      captures: [],
    });
    expect((submitted.result as { state: string }).state).toBe("queued");

    const waited = await client.request("case.wait", { case_id: caseId, wait_ms: 1000 });
    const replyId = (waited.result as { reply_id: string }).reply_id;
    const acked = await client.request("reply.ack", { reply_id: replyId });
    expect((acked.result as { state: string }).state).toBe("delivered");

    // The queue: the app polls sessions.list. It shows the shim's footprint and reads no git.
    const listed = await client.request("sessions.list", {});
    const mine = (listed.result as any[]).find((s) => s.id === "sess-boundary");
    expect(mine.project).toBe(projectDir.split("/").pop());
    expect(mine.context.changes).toEqual({ files: 1, added: 2, removed: 0, clean: false, last_commit: "From the shim" });
    expect((await client.request("cases.list", {})).error).toBeUndefined();

    forbiddenRoot = null;
    if (saved === undefined) delete process.env.KNOCK_CLAUDE_PROJECTS;
    else process.env.KNOCK_CLAUDE_PROJECTS = saved;
    client.close();

    // The daemon never touched the project folder.
    expect(touched).toEqual([]);
    expect(spawned.filter((cmd) => cmd.includes("git"))).toEqual([]);

    // The artifacts are staged: screenshot as a blob, bundle as r2, read-only.
    const detail = store.getCase(caseId)!;
    expect(detail.revisions.map((r) => r.n)).toEqual([1, 2]);
    const blobRoot = store.artifactPath(caseId, 1)!;
    expect(readFileSync(blobRoot.root).equals(png)).toBe(true);
    const bundleRoot = store.artifactPath(caseId, 2)!;
    expect(readFileSync(join(bundleRoot.root, "index.html"), "utf8")).toBe("<h1>hi</h1>");
    // The incoming staging directories are gone.
    expect(readdirSync(join(home, "incoming"))).toEqual([]);
  });
});

// The daemon runtime must not even contain the means to read the agent's cwd:
// no git helper, no cwd-resolving staging function. This locks the construction
// in case a later change re-introduces a git -C <cwd> call (HAIL-26).
describe("daemon runtime source never reads cwd", () => {
  const daemonFiles = ["server.ts", "store.ts", "daemon.ts", join("sessions", "context.ts")];

  test("no git helper or shim staging call in the daemon runtime", () => {
    for (const name of daemonFiles) {
      const source = readFileSync(join(import.meta.dir, "..", "src", name), "utf8");
      expect(source).not.toMatch(/\bgitRoot\(/);
      expect(source).not.toMatch(/\bgitBranch\(/);
      expect(source).not.toMatch(/spawnSync/);
      expect(source).not.toMatch(/Bun\.spawn\(/);
      expect(source).not.toMatch(/sessions\/footprint/);
      expect(source).not.toMatch(/\bstageScreenshot\(/);
      expect(source).not.toMatch(/\bstageBundle\(/);
    }
  });
});
