import { afterEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { join } from "node:path";
import { EventBus } from "../src/events";
import { startRpcServer, type RpcServer } from "../src/server";
import { Store } from "../src/store";
import type { KnockAskInput } from "../src/protocol";
import { rmrf, rpcConnect, tmpHome, type RpcClient } from "./helpers";

// HAIL-197: case.create with a client_request_id is idempotent per session, also across a daemon restart.

const ask: KnockAskInput = {
  kind: "question",
  title: "Pick a layout",
  need: "Pick a layout",
  why: "I cannot decide",
  recommendation: "a",
  recommendation_why: "It is the default",
  options: [
    { id: "a", label: "Compact" },
    { id: "b", label: "Detailed" },
  ],
};

const homes: string[] = [];
const closers: Array<() => void> = [];

afterEach(() => {
  for (const close of closers.splice(0).reverse()) {
    try {
      close();
    } catch {
      // Already closed.
    }
  }
  for (const home of homes.splice(0)) rmrf(home);
});

function boot(home: string): { db: Database; server: RpcServer } {
  const db = new Database(join(home, "knock.db"));
  const bus = new EventBus();
  const store = new Store(db, home, bus);
  const server = startRpcServer({ socketPath: join(home, "knock.sock"), store, bus, version: "0.1.0", onRestart: () => {} });
  closers.push(() => db.close());
  closers.push(() => server.stop());
  return { db, server };
}

async function hello(home: string, sessionId: string): Promise<RpcClient> {
  const client = await rpcConnect(join(home, "knock.sock"));
  closers.push(() => client.close());
  const res = await client.request("session.hello", { session_id: sessionId, cwd: join(home, "work"), parent_pid: 4242 });
  expect(res.error).toBeUndefined();
  return client;
}

const count = (db: Database, sql: string) => (db.query(sql).get() as { n: number }).n;

describe("case.create client_request_id", () => {
  test("the same id twice makes one case and one case.created event", async () => {
    const home = tmpHome();
    homes.push(home);
    const { db } = boot(home);
    const client = await hello(home, "s1");
    const first = await client.request("case.create", { ...ask, client_request_id: "req-0001-aaaa" });
    const second = await client.request("case.create", { ...ask, client_request_id: "req-0001-aaaa" });
    expect(first.error).toBeUndefined();
    const a = first.result as Record<string, unknown>;
    const b = second.result as Record<string, unknown>;
    expect(b.id).toBe(a.id);
    // Every key of a fresh create is present; the stored row may add optional ones.
    for (const key of Object.keys(a)) expect(Object.keys(b)).toContain(key);
    expect(b.title).toBe(a.title);
    expect(b.status).toBe(a.status);
    expect(b.replaced_answer_note).toBeNull();
    expect(b.words_warning).toBeNull();
    expect(count(db, `SELECT COUNT(*) AS n FROM cases`)).toBe(1);
    expect(count(db, `SELECT COUNT(*) AS n FROM events WHERE type = 'case.created'`)).toBe(1);
  });

  test("a different id, or another session with the same id, makes a new case", async () => {
    const home = tmpHome();
    homes.push(home);
    const { db } = boot(home);
    const one = await hello(home, "s1");
    const two = await hello(home, "s2");
    const a = (await one.request("case.create", { ...ask, client_request_id: "req-0001-aaaa" })).result as { id: string };
    const b = (await one.request("case.create", { ...ask, title: "Another ask", client_request_id: "req-0002-bbbb" })).result as { id: string };
    const c = (await two.request("case.create", { ...ask, client_request_id: "req-0001-aaaa" })).result as { id: string };
    expect(new Set([a.id, b.id, c.id]).size).toBe(3);
    expect(count(db, `SELECT COUNT(*) AS n FROM cases`)).toBe(3);
  });

  test("an ask with no id behaves as before: every call makes a case", async () => {
    const home = tmpHome();
    homes.push(home);
    const { db } = boot(home);
    const client = await hello(home, "s1");
    await client.request("case.create", ask);
    await client.request("case.create", { ...ask, title: "Another ask" });
    expect(count(db, `SELECT COUNT(*) AS n FROM cases`)).toBe(2);
  });

  test("a daemon restart between the first try and the retry still returns the first case", async () => {
    const home = tmpHome();
    homes.push(home);
    let { db, server } = boot(home);
    let client = await hello(home, "s1");
    const first = (await client.request("case.create", { ...ask, client_request_id: "req-0001-aaaa" })).result as { id: string };
    client.close();
    server.stop();
    db.close();

    ({ db } = boot(home));
    client = await hello(home, "s1");
    const retry = (await client.request("case.create", { ...ask, client_request_id: "req-0001-aaaa" })).result as { id: string };
    expect(retry.id).toBe(first.id);
    expect(count(db, `SELECT COUNT(*) AS n FROM cases`)).toBe(1);
  });
});
