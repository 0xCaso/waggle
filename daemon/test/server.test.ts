import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { rmSync } from "node:fs";
import { join } from "node:path";
import { EventBus } from "../src/events";
import type { RpcServer } from "../src/server";
import { startRpcServer } from "../src/server";
import { Store } from "../src/store";
import { rpcConnect, tmpHome } from "./helpers";

// In-process server over a real unix socket: proves the JSON-RPC dispatch,
// the -32602 invalid-params path, and that events.subscribe streams one event
// to every subscriber.
let home: string;
let socketPath: string;
let server: RpcServer;
let store: Store;
let bus: EventBus;
let seededCaseId: string;

beforeAll(() => {
  home = tmpHome();
  socketPath = join(home, "knock.sock");
  const db = new Database(join(home, "knock.db"));
  bus = new EventBus();
  store = new Store(db, home, bus);
  const task = store.createTask({ name: "checkout", project: "knock" });
  seededCaseId = store.createCase(task.id, {
    kind: "question",
    title: "Checkout layout",
    need: "Pick a layout",
    why: "I cannot decide",
    recommendation: "Compact",
    recommendation_why: "It fits on one line",
  }).id;
  server = startRpcServer({ socketPath, store, bus, version: "0.1.0", execPath: "/real/knock" });
});

afterAll(() => {
  server.stop();
  rmSync(home, { recursive: true, force: true });
});

describe("JSON-RPC socket server", () => {
  test("service.status returns version and data root", async () => {
    const client = await rpcConnect(socketPath);
    const res = await client.request("service.status", {});
    const status = res.result as {
      version: string;
      data_root: string;
      sessions_live: number;
      cases_open: number;
      exec_path: string;
    };
    expect(status).toMatchObject({ version: "0.1.0", data_root: home, exec_path: "/real/knock" });
    expect(status.sessions_live).toBe(0);
    expect(status.cases_open).toBeGreaterThanOrEqual(1);
    client.close();
  });

  test("cases.list returns the seeded case", async () => {
    const client = await rpcConnect(socketPath);
    const res = await client.request("cases.list", {});
    const ids = (res.result as { id: string }[]).map((c) => c.id);
    expect(ids).toContain(seededCaseId);
    client.close();
  });

  test("cases.list filters by status", async () => {
    const client = await rpcConnect(socketPath);
    const res = await client.request("cases.list", { status: "waiting_on_agent" });
    expect(res.result).toEqual([]);
    client.close();
  });

  test("cases.get returns the case detail", async () => {
    const client = await rpcConnect(socketPath);
    const res = await client.request("cases.get", { id: seededCaseId });
    expect((res.result as { case: { id: string } }).case.id).toBe(seededCaseId);
    client.close();
  });

  test("cases.get on a missing id is a JSON-RPC error", async () => {
    const client = await rpcConnect(socketPath);
    const res = await client.request("cases.get", { id: "c_missing" });
    expect(res.error?.code).toBe(-32001);
    client.close();
  });

  test("invalid params return -32602", async () => {
    const client = await rpcConnect(socketPath);
    const missing = await client.request("cases.get", {});
    expect(missing.error?.code).toBe(-32602);

    const badStatus = await client.request("cases.list", { status: "bogus" });
    expect(badStatus.error?.code).toBe(-32602);

    const badSubscribe = await client.request("events.subscribe", 42);
    expect(badSubscribe.error?.code).toBe(-32602);
    client.close();
  });

  test("an unknown method returns -32601", async () => {
    const client = await rpcConnect(socketPath);
    const res = await client.request("bogus.method", {});
    expect(res.error?.code).toBe(-32601);
    client.close();
  });

  test("events.subscribe streams one event to every subscriber", async () => {
    const a = await rpcConnect(socketPath);
    const b = await rpcConnect(socketPath);

    const ackA = await a.request("events.subscribe", {});
    const ackB = await b.request("events.subscribe", {});
    expect(ackA.result).toEqual({});
    expect(ackB.result).toEqual({});

    store.recordEvent("case.created", { case_id: "c_stream" });

    const lineA = await a.nextLine();
    const lineB = await b.nextLine();
    expect(lineA.method).toBe("event");
    expect(lineA.params).toMatchObject({ type: "case.created", case_id: "c_stream" });
    expect(lineB.params).toMatchObject({ type: "case.created", case_id: "c_stream" });

    a.close();
    b.close();
  });
});
