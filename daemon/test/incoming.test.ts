import { afterEach, describe, expect, test } from "bun:test";
import { createHash, randomUUID } from "node:crypto";
import {
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { dirname, join } from "node:path";
import { Database } from "bun:sqlite";
import { EventBus } from "../src/events";
import type { RpcServer } from "../src/server";
import { startRpcServer } from "../src/server";
import { Store } from "../src/store";
import {
  ArtifactError,
  ingestBundle,
  ingestDiagram,
  ingestMarkdown,
  ingestScreenshot,
  ingestScreenshots,
  NOT_STAGED_BY_SHIM,
  resolveIncoming,
} from "../src/artifacts/ingest";
import type { KnockAskInput } from "../src/protocol";
import { rmrf, rpcConnect, tmpHome } from "./helpers";

const PNG_SIG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

const homes: string[] = [];
const servers: RpcServer[] = [];

function newHome(): string {
  const h = tmpHome();
  homes.push(h);
  return h;
}

afterEach(() => {
  for (const server of servers.splice(0)) {
    try {
      server.stop();
    } catch {
      // Already stopped.
    }
  }
  for (const h of homes.splice(0)) {
    rmrf(h);
  }
});

function write(path: string, data: string | Buffer): void {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, data);
}

function pngBytes(): Buffer {
  return Buffer.concat([PNG_SIG, Buffer.from("ingest png")]);
}

function sha256(data: Buffer): string {
  return createHash("sha256").update(data).digest("hex");
}

// A screenshot file planted directly in incoming/<uuid>/shot.png, as the shim
// would have left it.
function plantScreenshot(home: string, data: Buffer): string {
  const dir = join(home, "incoming", randomUUID());
  write(join(dir, "shot.png"), data);
  return join(dir, "shot.png");
}

// A bundle dir planted directly in incoming/<uuid>/.
function plantBundle(home: string, files: Record<string, string | Buffer>): string {
  const dir = join(home, "incoming", randomUUID());
  for (const [name, data] of Object.entries(files)) {
    write(join(dir, name), data);
  }
  return dir;
}

// A markdown file planted directly in incoming/<uuid>/note.md, as the shim
// would have left it.
function plantMarkdown(home: string, data: string): string {
  const dir = join(home, "incoming", randomUUID());
  write(join(dir, "note.md"), data);
  return join(dir, "note.md");
}

// A diagram file planted directly in incoming/<uuid>/diagram.<ext>, as the shim
// would have left it.
function plantDiagram(home: string, data: string, ext: "mmd" | "svg"): string {
  const dir = join(home, "incoming", randomUUID());
  write(join(dir, `diagram.${ext}`), data);
  return join(dir, `diagram.${ext}`);
}

// Screenshots planted directly in one shared incoming/<uuid>/, as the shim
// would have left them (shot-1.png, shot-2.png, ...).
function plantScreenshots(home: string, items: { data: Buffer; caption?: string }[]): { path: string; caption?: string }[] {
  const dir = join(home, "incoming", randomUUID());
  return items.map((item, i) => {
    const path = join(dir, `shot-${i + 1}.png`);
    write(path, item.data);
    return { path, ...(item.caption !== undefined ? { caption: item.caption } : {}) };
  });
}

function assertReadOnly(root: string): void {
  const st = lstatSync(root);
  expect(st.mode & 0o222).toBe(0);
  if (st.isDirectory()) {
    for (const name of readdirSync(root)) {
      assertReadOnly(join(root, name));
    }
  }
}

describe("ingestScreenshot (daemon)", () => {
  test("moves a screenshot into blobs/<sha256>.png and removes the incoming dir", () => {
    const home = newHome();
    const data = pngBytes();
    const incomingPath = plantScreenshot(home, data);

    const staged = ingestScreenshot({ incomingPath, blobsDir: join(home, "blobs") });

    expect(staged).toMatchObject({ kind: "screenshot", sha256: sha256(data), ext: "png" });
    expect(staged.path).toBe(join(home, "blobs", `${sha256(data)}.png`));
    expect(readFileSync(staged.path).equals(data)).toBe(true);
    expect(existsSync(dirname(incomingPath))).toBe(false);
  });

  test("identical content is stored once", () => {
    const home = newHome();
    const data = pngBytes();
    const first = ingestScreenshot({ incomingPath: plantScreenshot(home, data), blobsDir: join(home, "blobs") });
    const second = ingestScreenshot({ incomingPath: plantScreenshot(home, data), blobsDir: join(home, "blobs") });

    expect(second.path).toBe(first.path);
    expect(readdirSync(join(home, "blobs"))).toHaveLength(1);
  });

  test("re-validates size and rejects a non-PNG", () => {
    const home = newHome();
    const notPng = plantScreenshot(home, Buffer.from("plain text, not a PNG"));
    expect(() => ingestScreenshot({ incomingPath: notPng, blobsDir: join(home, "blobs") })).toThrow(
      /not a PNG/,
    );
    expect(existsSync(dirname(notPng))).toBe(false);
  });
});

describe("ingestMarkdown (daemon)", () => {
  test("moves markdown into blobs/<sha256>.md and removes the incoming dir", () => {
    const home = newHome();
    const data = "# Trade-offs\n\nSome text.";
    const incomingPath = plantMarkdown(home, data);

    const staged = ingestMarkdown({ incomingPath, blobsDir: join(home, "blobs") });

    expect(staged).toMatchObject({ kind: "markdown", sha256: sha256(Buffer.from(data)) });
    expect(staged.path).toBe(join(home, "blobs", `${sha256(Buffer.from(data))}.md`));
    expect(readFileSync(staged.path, "utf8")).toBe(data);
    expect(existsSync(dirname(incomingPath))).toBe(false);
  });

  test("identical content is stored once", () => {
    const home = newHome();
    const data = "same text";
    const first = ingestMarkdown({ incomingPath: plantMarkdown(home, data), blobsDir: join(home, "blobs") });
    const second = ingestMarkdown({ incomingPath: plantMarkdown(home, data), blobsDir: join(home, "blobs") });

    expect(second.path).toBe(first.path);
    expect(readdirSync(join(home, "blobs"))).toHaveLength(1);
  });

  test("re-validates size and rejects markdown larger than 1 MB", () => {
    const home = newHome();
    const tooBig = plantMarkdown(home, "a".repeat(1024 * 1024 + 1));
    expect(() => ingestMarkdown({ incomingPath: tooBig, blobsDir: join(home, "blobs") })).toThrow(
      /larger than 1 MB/,
    );
    expect(existsSync(dirname(tooBig))).toBe(false);
  });
});

describe("ingestDiagram (daemon)", () => {
  test("moves a .mmd diagram into blobs/<sha256>.mmd and removes the incoming dir", () => {
    const home = newHome();
    const data = "flowchart TD\n    A --> B\n";
    const incomingPath = plantDiagram(home, data, "mmd");

    const staged = ingestDiagram({ incomingPath, blobsDir: join(home, "blobs") });

    expect(staged).toMatchObject({ kind: "diagram", sha256: sha256(Buffer.from(data)), ext: "mmd" });
    expect(staged.path).toBe(join(home, "blobs", `${sha256(Buffer.from(data))}.mmd`));
    expect(readFileSync(staged.path, "utf8")).toBe(data);
    expect(existsSync(dirname(incomingPath))).toBe(false);
  });

  test("moves a .svg diagram into blobs/<sha256>.svg", () => {
    const home = newHome();
    const data = "<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>";
    const incomingPath = plantDiagram(home, data, "svg");

    const staged = ingestDiagram({ incomingPath, blobsDir: join(home, "blobs") });

    expect(staged).toMatchObject({ kind: "diagram", sha256: sha256(Buffer.from(data)), ext: "svg" });
    expect(staged.path).toBe(join(home, "blobs", `${sha256(Buffer.from(data))}.svg`));
  });

  test("identical content is stored once", () => {
    const home = newHome();
    const data = "flowchart TD";
    const first = ingestDiagram({ incomingPath: plantDiagram(home, data, "mmd"), blobsDir: join(home, "blobs") });
    const second = ingestDiagram({ incomingPath: plantDiagram(home, data, "mmd"), blobsDir: join(home, "blobs") });

    expect(second.path).toBe(first.path);
    expect(readdirSync(join(home, "blobs"))).toHaveLength(1);
  });

  test("re-validates size and rejects a diagram larger than 512 KB", () => {
    const home = newHome();
    const tooBig = plantDiagram(home, "a".repeat(512 * 1024 + 1), "mmd");
    expect(() => ingestDiagram({ incomingPath: tooBig, blobsDir: join(home, "blobs") })).toThrow(
      /larger than 512 KB/,
    );
    expect(existsSync(dirname(tooBig))).toBe(false);
  });

  test("re-validates the extension and rejects a non-diagram file", () => {
    const home = newHome();
    const dir = join(home, "incoming", randomUUID());
    write(join(dir, "diagram.txt"), "flowchart TD");
    const wrong = join(dir, "diagram.txt");
    expect(() => ingestDiagram({ incomingPath: wrong, blobsDir: join(home, "blobs") })).toThrow(
      /\.mmd or \.svg/,
    );
    expect(existsSync(dirname(wrong))).toBe(false);
  });
});

describe("ingestScreenshots (daemon)", () => {
  test("moves every item into blobs/<sha256>.<ext>, in order, and removes the shared incoming dir", () => {
    const home = newHome();
    const first = pngBytes();
    const second = Buffer.concat([PNG_SIG, Buffer.from("second")]);
    const items = plantScreenshots(home, [{ data: first, caption: "Home" }, { data: second }]);
    const incomingDir = dirname(items[0]!.path);

    const staged = ingestScreenshots({ items, blobsDir: join(home, "blobs") });

    expect(staged.kind).toBe("screenshots");
    expect(staged.items).toEqual([
      { sha256: sha256(first), ext: "png", caption: "Home" },
      { sha256: sha256(second), ext: "png" },
    ]);
    expect(readFileSync(join(home, "blobs", `${sha256(first)}.png`)).equals(first)).toBe(true);
    expect(readFileSync(join(home, "blobs", `${sha256(second)}.png`)).equals(second)).toBe(true);
    expect(existsSync(incomingDir)).toBe(false);
  });

  test("re-validates each item and rejects a non-PNG with its 1-based number", () => {
    const home = newHome();
    const items = plantScreenshots(home, [
      { data: pngBytes() },
      { data: Buffer.from("plain text, not a PNG") },
    ]);
    const incomingDir = dirname(items[0]!.path);

    expect(() => ingestScreenshots({ items, blobsDir: join(home, "blobs") })).toThrow(
      /screenshot 2.*not a PNG/,
    );
    expect(existsSync(incomingDir)).toBe(false);
  });
});

describe("ingestBundle (daemon)", () => {
  test("moves a bundle into bundles/<case>/r<n> read-only and removes the incoming dir", () => {
    const home = newHome();
    const src = plantBundle(home, {
      "index.html": "<h1>hi</h1>",
      "app.js": "let x = 1;",
    });

    const staged = ingestBundle({
      incomingDir: src,
      entry: "index.html",
      bundlesDir: join(home, "bundles"),
      caseId: "c_1",
      revision: 2,
    });

    expect(staged.path).toBe(join(home, "bundles", "c_1", "r2"));
    expect(staged.entry).toBe("index.html");
    expect(readFileSync(join(staged.path, "index.html"), "utf8")).toBe("<h1>hi</h1>");
    assertReadOnly(staged.path);
    expect(existsSync(src)).toBe(false);
  });

  test("re-validates and rejects a symlink planted in the incoming dir", () => {
    const home = newHome();
    const src = plantBundle(home, { "index.html": "ok" });
    write(join(home, "outside.txt"), "secret");
    symlinkSync(join(home, "outside.txt"), join(src, "link.txt"));

    expect(() =>
      ingestBundle({
        incomingDir: src,
        entry: "index.html",
        bundlesDir: join(home, "bundles"),
        caseId: "c_1",
        revision: 1,
      }),
    ).toThrow(/symlinks/);
    expect(existsSync(src)).toBe(false);
  });

  test("re-validates a missing entry", () => {
    const home = newHome();
    const src = plantBundle(home, { "index.html": "ok" });

    expect(() =>
      ingestBundle({
        incomingDir: src,
        entry: "missing.html",
        bundlesDir: join(home, "bundles"),
        caseId: "c_1",
        revision: 1,
      }),
    ).toThrow(/does not exist/);
    expect(existsSync(src)).toBe(false);
  });

  // HAIL-49: an html_bundle may declare a viewport and/or a preview file, both
  // re-validated here the same way the shim already validated them - the
  // daemon never trusts the shim's own check alone.
  test("passes a viewport through and re-validates a preview file", () => {
    const home = newHome();
    const src = plantBundle(home, { "index.html": "<h1>hi</h1>", "preview.html": "<h1>card</h1>" });

    const staged = ingestBundle({
      incomingDir: src,
      entry: "index.html",
      bundlesDir: join(home, "bundles"),
      caseId: "c_1",
      revision: 1,
      viewport: { width: 390, height: 844 },
      preview: "preview.html",
    });

    expect(staged.viewport).toEqual({ width: 390, height: 844 });
    expect(staged.preview).toBe("preview.html");
    expect(readFileSync(join(staged.path, "preview.html"), "utf8")).toBe("<h1>card</h1>");
  });

  test("rejects a preview outside the bundle dir with no partial move", () => {
    const home = newHome();
    const src = plantBundle(home, { "index.html": "ok" });
    write(join(home, "outside.html"), "<h1>outside</h1>");

    expect(() =>
      ingestBundle({
        incomingDir: src,
        entry: "index.html",
        bundlesDir: join(home, "bundles"),
        caseId: "c_1",
        revision: 1,
        preview: "../outside.html",
      }),
    ).toThrow(/"\.\."/);
    expect(existsSync(src)).toBe(false);
    expect(existsSync(join(home, "bundles"))).toBe(false);
  });

  test("rejects a preview with an unknown extension", () => {
    const home = newHome();
    const src = plantBundle(home, { "index.html": "ok", "preview.gif": "not a gif" });

    expect(() =>
      ingestBundle({
        incomingDir: src,
        entry: "index.html",
        bundlesDir: join(home, "bundles"),
        caseId: "c_1",
        revision: 1,
        preview: "preview.gif",
      }),
    ).toThrow(/\.html, \.png, or \.jpg/);
    expect(existsSync(src)).toBe(false);
  });

  test("rejects a missing preview file", () => {
    const home = newHome();
    const src = plantBundle(home, { "index.html": "ok" });

    expect(() =>
      ingestBundle({
        incomingDir: src,
        entry: "index.html",
        bundlesDir: join(home, "bundles"),
        caseId: "c_1",
        revision: 1,
        preview: "preview.html",
      }),
    ).toThrow(/does not exist/);
    expect(existsSync(src)).toBe(false);
  });
});

describe("resolveIncoming (daemon)", () => {
  test("accepts a screenshot and a bundle inside incoming/", () => {
    const home = newHome();
    const shot = plantScreenshot(home, pngBytes());
    const bundle = plantBundle(home, { "index.html": "ok" });

    const shotResolved = resolveIncoming({ type: "screenshot", path: shot }, home);
    expect(shotResolved.type).toBe("screenshot");
    if (shotResolved.type === "screenshot") {
      expect(shotResolved.path).toBe(realpathSync(shot));
    }

    const bundleResolved = resolveIncoming(
      {
        type: "html_bundle",
        dir: bundle,
        entry: "index.html",
        viewport: { width: 390, height: 844 },
        preview: "preview.html",
      },
      home,
    );
    expect(bundleResolved.type).toBe("html_bundle");
    if (bundleResolved.type === "html_bundle") {
      expect(bundleResolved.dir).toBe(realpathSync(bundle));
      expect(bundleResolved.entry).toBe("index.html");
      expect(bundleResolved.viewport).toEqual({ width: 390, height: 844 });
      expect(bundleResolved.preview).toBe("preview.html");
    }

    const markdown = plantMarkdown(home, "hello");
    const markdownResolved = resolveIncoming({ type: "markdown", path: markdown }, home);
    expect(markdownResolved.type).toBe("markdown");
    if (markdownResolved.type === "markdown") {
      expect(markdownResolved.path).toBe(realpathSync(markdown));
    }

    const diagram = plantDiagram(home, "flowchart TD", "mmd");
    const diagramResolved = resolveIncoming({ type: "diagram", path: diagram }, home);
    expect(diagramResolved.type).toBe("diagram");
    if (diagramResolved.type === "diagram") {
      expect(diagramResolved.path).toBe(realpathSync(diagram));
    }

    const screenshotsItems = plantScreenshots(home, [{ data: pngBytes() }, { data: pngBytes(), caption: "Two" }]);
    const screenshotsResolved = resolveIncoming({ type: "screenshots", items: screenshotsItems }, home);
    expect(screenshotsResolved.type).toBe("screenshots");
    if (screenshotsResolved.type === "screenshots") {
      expect(screenshotsResolved.items).toEqual([
        { path: realpathSync(screenshotsItems[0]!.path) },
        { path: realpathSync(screenshotsItems[1]!.path), caption: "Two" },
      ]);
    }
  });

  test("rejects a screenshots item outside incoming/", () => {
    const home = newHome();
    const items = plantScreenshots(home, [{ data: pngBytes() }]);
    expect(() =>
      resolveIncoming(
        { type: "screenshots", items: [...items, { path: join(home, "blobs", "x.png") }] },
        home,
      ),
    ).toThrow(NOT_STAGED_BY_SHIM);
  });

  test("rejects a relative path (old shim) without touching the filesystem", () => {
    const home = newHome();
    expect(() =>
      resolveIncoming({ type: "screenshot", path: "./shots/a.png" }, home),
    ).toThrow(NOT_STAGED_BY_SHIM);
  });

  test("rejects an absolute path outside incoming/", () => {
    const home = newHome();
    const outside = join(home, "blobs", "x.png");
    expect(() => resolveIncoming({ type: "screenshot", path: outside }, home)).toThrow(
      NOT_STAGED_BY_SHIM,
    );
  });

  test("rejects a symlink that escapes incoming/", () => {
    const home = newHome();
    const real = join(home, "outside");
    mkdirSync(real, { recursive: true });
    write(join(real, "index.html"), "ok");
    const link = join(home, "incoming", "escape");
    mkdirSync(join(home, "incoming"), { recursive: true });
    symlinkSync(real, link);

    expect(() =>
      resolveIncoming({ type: "html_bundle", dir: link, entry: "index.html" }, home),
    ).toThrow(NOT_STAGED_BY_SHIM);
  });
});

describe("session.hello project naming from git_root", () => {
  function setup() {
    const home = newHome();
    const db = new Database(join(home, "knock.db"));
    const bus = new EventBus();
    const store = new Store(db, home, bus);
    const server = startRpcServer({ socketPath: join(home, "knock.sock"), store, bus, version: "0.1.0" });
    servers.push(server);
    return { home, store };
  }

  test("project is the git root basename when git_root is sent", async () => {
    const { home, store } = setup();
    const client = await rpcConnect(join(home, "knock.sock"));
    const res = await client.request("session.hello", {
      session_id: "sess-gr",
      cwd: "/repo/omea-web/apps/web",
      git_root: "/repo/omea-web",
      parent_pid: process.pid,
    });
    const task = store.db
      .query(`SELECT name, project FROM tasks WHERE id = ?`)
      .get((res.result as { task_id: string }).task_id) as { name: string; project: string };
    expect(task.project).toBe("omea-web");
    expect(task.name).toBe("web");
    client.close();
  });

  test("project falls back to the cwd basename when git_root is absent", async () => {
    const { home, store } = setup();
    const client = await rpcConnect(join(home, "knock.sock"));
    const res = await client.request("session.hello", {
      session_id: "sess-nogr",
      cwd: "/work/checkout",
      parent_pid: process.pid,
    });
    const task = store.db
      .query(`SELECT project FROM tasks WHERE id = ?`)
      .get((res.result as { task_id: string }).task_id) as { project: string };
    expect(task.project).toBe("checkout");
    client.close();
  });
});

describe("case.create rejects a non-incoming artifact (old shim)", () => {
  const review: KnockAskInput = {
    kind: "review",
    title: "Checkout layout",
    need: "Approve the layout",
    why: "It needs a human eye",
    recommendation: "a",
    recommendation_why: "It is the default",
    options: [
      { id: "a", label: "Compact" },
      { id: "b", label: "Detailed" },
    ],
    artifact: { type: "screenshot", path: "./shots/a.png" },
  };

  function setup() {
    const home = newHome();
    const db = new Database(join(home, "knock.db"));
    const bus = new EventBus();
    const store = new Store(db, home, bus);
    const server = startRpcServer({ socketPath: join(home, "knock.sock"), store, bus, version: "0.1.0" });
    servers.push(server);
    return { home, store };
  }

  test("returns a clear error telling the agent to restart the session", async () => {
    const { home, store } = setup();
    const client = await rpcConnect(join(home, "knock.sock"));
    await client.request("session.hello", {
      session_id: "sess-old",
      cwd: "/work/checkout",
      parent_pid: process.pid,
    });

    const res = await client.request("case.create", review);
    expect(res.error?.code).toBe(-32004);
    expect(res.error?.message).toContain("artifact must be staged by the shim");
    expect(res.error?.message).toContain("restart the session");
    expect(store.listCases()).toHaveLength(0);
    client.close();
  });
});

// HAIL-33 amendment: waggle_ask's optional follows, validated over the socket.
describe("case.create with follows (HAIL-33 amendment)", () => {
  const question: KnockAskInput = {
    kind: "question",
    title: "Pick a layout",
    need: "Pick a layout",
    why: "I cannot decide",
    recommendation: "a",
    recommendation_why: "It is the default",
  };

  function setup() {
    const home = newHome();
    const db = new Database(join(home, "knock.db"));
    const bus = new EventBus();
    const store = new Store(db, home, bus);
    const server = startRpcServer({ socketPath: join(home, "knock.sock"), store, bus, version: "0.1.0" });
    servers.push(server);
    return { home, store };
  }

  test("follows an earlier case from the same session's task", async () => {
    const { home, store } = setup();
    const client = await rpcConnect(join(home, "knock.sock"));
    await client.request("session.hello", { session_id: "sess-follow", cwd: "/work", parent_pid: process.pid });

    const earlier = await client.request("case.create", question);
    const earlierId = (earlier.result as { id: string }).id;

    const followUp = await client.request("case.create", { ...question, follows: earlierId });
    expect((followUp.result as { follows_case_id: string | null }).follows_case_id).toBe(earlierId);
    expect(store.listCases()).toHaveLength(2);
    client.close();
  });

  test("rejects an unknown follows id with a clear error and creates no case", async () => {
    const { home, store } = setup();
    const client = await rpcConnect(join(home, "knock.sock"));
    await client.request("session.hello", { session_id: "sess-follow-bad", cwd: "/work", parent_pid: process.pid });

    const res = await client.request("case.create", { ...question, follows: "c_missing" });
    expect(res.error?.code).toBe(-32007);
    expect(store.listCases()).toHaveLength(0);
    client.close();
  });

  test("rejects a follows naming another session's case", async () => {
    const { home, store } = setup();
    const clientA = await rpcConnect(join(home, "knock.sock"));
    await clientA.request("session.hello", { session_id: "sess-A", cwd: "/work/a", parent_pid: process.pid });
    const caseA = await clientA.request("case.create", question);
    const caseAId = (caseA.result as { id: string }).id;

    const clientB = await rpcConnect(join(home, "knock.sock"));
    await clientB.request("session.hello", { session_id: "sess-B", cwd: "/work/b", parent_pid: process.pid });
    const res = await clientB.request("case.create", { ...question, follows: caseAId });

    expect(res.error?.code).toBe(-32007);
    expect(store.listCases()).toHaveLength(1);
    clientA.close();
    clientB.close();
  });
});

// HAIL-44: waggle_ask's optional replaces, validated over the socket.
describe("case.create with replaces (HAIL-44)", () => {
  const question: KnockAskInput = {
    kind: "question",
    title: "Pick a layout",
    need: "Pick a layout",
    why: "I cannot decide",
    recommendation: "a",
    recommendation_why: "It is the default",
  };

  function setup() {
    const home = newHome();
    const db = new Database(join(home, "knock.db"));
    const bus = new EventBus();
    const store = new Store(db, home, bus);
    const server = startRpcServer({ socketPath: join(home, "knock.sock"), store, bus, version: "0.1.0" });
    servers.push(server);
    return { home, store };
  }

  test("replaces an earlier case from the same session's task, and withdraws it", async () => {
    const { home, store } = setup();
    const client = await rpcConnect(join(home, "knock.sock"));
    await client.request("session.hello", { session_id: "sess-replace", cwd: "/work", parent_pid: process.pid });

    const earlier = await client.request("case.create", question);
    const earlierId = (earlier.result as { id: string }).id;

    const replacement = await client.request("case.create", { ...question, replaces: earlierId });
    const result = replacement.result as { replaces_case_id: string | null; replaced_answer_note: string | null };
    expect(result.replaces_case_id).toBe(earlierId);
    expect(result.replaced_answer_note).toBeNull();
    expect(store.getCase(earlierId)!.case.status).toBe("resolved");
    expect(store.getCase(earlierId)!.case.withdrawn_at).not.toBeNull();
    expect(store.listCases()).toHaveLength(2);
    client.close();
  });

  test("rejects an unknown replaces id with a clear error and creates no case", async () => {
    const { home, store } = setup();
    const client = await rpcConnect(join(home, "knock.sock"));
    await client.request("session.hello", { session_id: "sess-replace-bad", cwd: "/work", parent_pid: process.pid });

    const res = await client.request("case.create", { ...question, replaces: "c_missing" });
    expect(res.error?.code).toBe(-32008);
    expect(store.listCases()).toHaveLength(0);
    client.close();
  });

  test("rejects a replaces naming another session's case", async () => {
    const { home, store } = setup();
    const clientA = await rpcConnect(join(home, "knock.sock"));
    await clientA.request("session.hello", { session_id: "sess-A2", cwd: "/work/a", parent_pid: process.pid });
    const caseA = await clientA.request("case.create", question);
    const caseAId = (caseA.result as { id: string }).id;

    const clientB = await rpcConnect(join(home, "knock.sock"));
    await clientB.request("session.hello", { session_id: "sess-B2", cwd: "/work/b", parent_pid: process.pid });
    const res = await clientB.request("case.create", { ...question, replaces: caseAId });

    expect(res.error?.code).toBe(-32008);
    expect(store.listCases()).toHaveLength(1);
    expect(store.getCase(caseAId)!.case.status).toBe("needs_you");
    clientA.close();
    clientB.close();
  });
});
