import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { Database } from "bun:sqlite";
import { EventBus } from "../src/events";
import type { RpcServer } from "../src/server";
import { startRpcServer } from "../src/server";
import { Store } from "../src/store";
import { rmrf, rpcConnect, stageIncoming, tmpHome } from "./helpers";

const PNG_SIG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

let home: string;
let cwd: string;
let socketPath: string;
let server: RpcServer;
let store: Store;
let caseId: string;

beforeAll(() => {
  home = tmpHome();
  cwd = join(home, "work");
  mkdirSync(cwd, { recursive: true });
  socketPath = join(home, "knock.sock");
  const db = new Database(join(home, "knock.db"));
  const bus = new EventBus();
  store = new Store(db, home, bus);
  const task = store.createTask({ name: "checkout", project: "knock" });
  caseId = store.createCase(task.id, {
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
  }).id;

  // Revision 1: a screenshot. Revision 2: an html bundle.
  const png = Buffer.concat([PNG_SIG, Buffer.from("rpc test png")]);
  write(join(cwd, "shots", "a.png"), png);
  store.createRevision(
    caseId,
    stageIncoming(home, cwd, { type: "screenshot", path: "./shots/a.png" }),
  );

  write(join(cwd, "proto", "index.html"), "<h1>hi</h1>");
  write(join(cwd, "proto", "app.js"), "let x = 1;");
  store.createRevision(
    caseId,
    stageIncoming(home, cwd, { type: "html_bundle", dir: "proto", entry: "index.html" }),
  );

  // Revision 3: an html bundle declaring a viewport (HAIL-49).
  write(join(cwd, "phone", "index.html"), "<h1>phone</h1>");
  store.createRevision(
    caseId,
    stageIncoming(home, cwd, {
      type: "html_bundle",
      dir: "phone",
      entry: "index.html",
      viewport: { width: 390, height: 844 },
    }),
  );

  // Revision 4: an html bundle with a preview.html card (HAIL-49).
  write(join(cwd, "withpreview", "index.html"), "<h1>page</h1>");
  write(join(cwd, "withpreview", "preview.html"), "<h1>card</h1>");
  store.createRevision(
    caseId,
    stageIncoming(home, cwd, {
      type: "html_bundle",
      dir: "withpreview",
      entry: "index.html",
      preview: "preview.html",
    }),
  );

  server = startRpcServer({ socketPath, store, bus, version: "0.1.0" });
});

afterAll(() => {
  server.stop();
  rmrf(home);
});

function write(path: string, data: string | Buffer): void {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, data);
}

describe("artifact.path RPC", () => {
  test("returns the absolute staged screenshot path", async () => {
    const client = await rpcConnect(socketPath);
    const res = await client.request("artifact.path", { case_id: caseId, revision: 1 });
    const result = res.result as { kind: string; root: string; entry: string };
    expect(result.kind).toBe("screenshot");
    expect(result.root.startsWith(join(home, "blobs", ""))).toBe(true);
    expect(result.root.endsWith(".png")).toBe(true);
    expect(existsSync(result.root)).toBe(true);
    expect(result.entry).toBe("");
    client.close();
  });

  test("returns the absolute staged bundle root and entry", async () => {
    const client = await rpcConnect(socketPath);
    const res = await client.request("artifact.path", { case_id: caseId, revision: 2 });
    const result = res.result as { kind: string; root: string; entry: string };
    expect(result.kind).toBe("html_bundle");
    expect(result.root).toBe(join(home, "bundles", caseId, "r2"));
    expect(result.entry).toBe(join(home, "bundles", caseId, "r2", "index.html"));
    client.close();
  });

  test("returns the declared viewport for a revision that has one", async () => {
    const client = await rpcConnect(socketPath);
    const res = await client.request("artifact.path", { case_id: caseId, revision: 3 });
    const result = res.result as { kind: string; viewport?: { width: number; height: number } };
    expect(result.kind).toBe("html_bundle");
    expect(result.viewport).toEqual({ width: 390, height: 844 });
    client.close();
  });

  test("returns the preview's absolute path and html kind for a revision that has one", async () => {
    const client = await rpcConnect(socketPath);
    const res = await client.request("artifact.path", { case_id: caseId, revision: 4 });
    const result = res.result as {
      kind: string;
      root: string;
      preview?: { kind: string; path: string };
    };
    expect(result.kind).toBe("html_bundle");
    expect(result.preview).toEqual({ kind: "html", path: join(result.root, "preview.html") });
    client.close();
  });

  test("omits viewport and preview for a revision that declares neither", async () => {
    const client = await rpcConnect(socketPath);
    const res = await client.request("artifact.path", { case_id: caseId, revision: 2 });
    const result = res.result as { viewport?: unknown; preview?: unknown };
    expect(result.viewport).toBeUndefined();
    expect(result.preview).toBeUndefined();
    client.close();
  });

  test("returns -32001 for an unknown revision", async () => {
    const client = await rpcConnect(socketPath);
    const res = await client.request("artifact.path", { case_id: caseId, revision: 99 });
    expect(res.error?.code).toBe(-32001);
    expect(res.error?.message).toBe("revision not found");
    client.close();
  });

  test("returns -32001 for an unknown case", async () => {
    const client = await rpcConnect(socketPath);
    const res = await client.request("artifact.path", { case_id: "c_missing", revision: 1 });
    expect(res.error?.code).toBe(-32001);
    expect(res.error?.message).toBe("case not found");
    client.close();
  });

  test("returns -32602 for invalid params", async () => {
    const client = await rpcConnect(socketPath);
    const res = await client.request("artifact.path", {});
    expect(res.error?.code).toBe(-32602);
    client.close();
  });
});
