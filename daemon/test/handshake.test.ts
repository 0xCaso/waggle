import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { join } from "node:path";
import { EventBus } from "../src/events";
import { DaemonRpcError } from "../src/mcp/client";
import type { RpcServer } from "../src/server";
import { startRpcServer } from "../src/server";
import { Store } from "../src/store";
import type { Case } from "../src/protocol";
import { rpcConnect, rmrf, tmpHome, type RpcClient } from "./helpers";

// HAIL-27: a client newer than the daemon gets a clear error from session.hello,
// and an unexpected handler error surfaces its cause in error.data.message so
// the CLI and the shim never print a bare "Internal error".

let home: string;
let socketPath: string;
let server: RpcServer;
let store: Store;
const clients: RpcClient[] = [];

beforeAll(() => {
  home = tmpHome();
  socketPath = join(home, "knock.sock");
  const db = new Database(join(home, "knock.db"));
  const bus = new EventBus();
  store = new Store(db, home, bus);
  server = startRpcServer({ socketPath, store, bus, version: "0.1.0" });
});

afterAll(() => {
  for (const client of clients.splice(0)) {
    try {
      client.close();
    } catch {
      // Already closed.
    }
  }
  server.stop();
  rmrf(home);
});

async function connect(): Promise<RpcClient> {
  const client = await rpcConnect(socketPath);
  clients.push(client);
  return client;
}

describe("version handshake", () => {
  test("a client newer than the daemon gets a clear error", async () => {
    const client = await connect();
    const res = await client.request("session.hello", {
      session_id: "sess-newer",
      cwd: join(home, "work"),
      parent_pid: 4242,
      client_version: "0.1.1",
    });
    expect(res.error?.code).toBe(-32005);
    expect(res.error?.message).toContain("Waggle's background service is older than this client");
    expect(res.error?.message).toContain("daemon 0.1.0, client 0.1.1");
    expect(res.error?.message).toContain("waggle doctor");
  });

  test("an equal or missing client_version is still served", async () => {
    const equal = await connect();
    const resEqual = await equal.request("session.hello", {
      session_id: "sess-equal",
      cwd: join(home, "work"),
      parent_pid: 4242,
      client_version: "0.1.0",
    });
    expect(resEqual.error).toBeUndefined();

    const missing = await connect();
    const resMissing = await missing.request("session.hello", {
      session_id: "sess-missing",
      cwd: join(home, "work"),
      parent_pid: 4242,
    });
    expect(resMissing.error).toBeUndefined();
  });
});

describe("readable internal errors", () => {
  test("an unexpected handler error returns -32603 with the cause in data.message", async () => {
    // A store that throws a non-RpcError, non-ArtifactError from a handler.
    class ThrowingStore extends Store {
      override listCases(): Case[] {
        throw new Error("boom: simulated failure");
      }
    }
    const db = new Database(":memory:");
    const throwing = new ThrowingStore(db, home);
    const srv = startRpcServer({
      socketPath: join(home, "err.sock"),
      store: throwing,
      bus: new EventBus(),
      version: "0.1.0",
    });
    try {
      const client = await rpcConnect(join(home, "err.sock"));
      const res = await client.request("cases.list", {});
      expect(res.error?.code).toBe(-32603);
      expect((res.error?.data as { message: string }).message).toBe("boom: simulated failure");
      client.close();
    } finally {
      srv.stop();
      db.close();
    }
  });

  test("DaemonRpcError surfaces data.message as its message", () => {
    const err = new DaemonRpcError(-32603, "Internal error", { message: "the real cause" });
    expect(err.message).toBe("the real cause");
    expect(err.code).toBe(-32603);

    // Without data the raw message is kept.
    const bare = new DaemonRpcError(-32001, "case not found");
    expect(bare.message).toBe("case not found");
  });
});
