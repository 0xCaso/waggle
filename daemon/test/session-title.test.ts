import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { join } from "node:path";
import { EventBus } from "../src/events";
import type { RpcServer } from "../src/server";
import { startRpcServer } from "../src/server";
import { Store } from "../src/store";
import { KnockAskInput, KnockUpdateInput, MCP_TOOLS, SessionInfo } from "../src/protocol";
import { rpcConnect, rmrf, tmpHome, type RpcClient } from "./helpers";

// WAG-279: session_title on waggle_ask and waggle_update, stored per session, latest wins.

const ask = {
  kind: "question",
  title: "Ship the rebrand?",
  need: "Ship the rebrand?",
  why: "I cannot decide",
  recommendation: "a",
  recommendation_why: "It is ready",
  options: [
    { id: "a", label: "Ship it" },
    { id: "b", label: "Wait" },
  ],
};

describe("session_title schema", () => {
  test("is optional and trimmed on both tools", () => {
    expect(KnockAskInput.parse(ask).session_title).toBeUndefined();
    expect(KnockAskInput.parse({ ...ask, session_title: "  Pricing page copy " }).session_title).toBe("Pricing page copy");
    expect(KnockUpdateInput.parse({ case_id: "c1", message: "x", session_title: "Pricing" }).session_title).toBe("Pricing");
  });

  test("is limited to 60 characters and cannot be empty", () => {
    expect(KnockAskInput.safeParse({ ...ask, session_title: "x".repeat(60) }).success).toBe(true);
    expect(KnockAskInput.safeParse({ ...ask, session_title: "x".repeat(61) }).success).toBe(false);
    expect(KnockAskInput.safeParse({ ...ask, session_title: "   " }).success).toBe(false);
  });

  test("both tool manifests name it", () => {
    for (const name of ["waggle_ask", "waggle_update"]) {
      const tool = MCP_TOOLS.find((t) => t.name === name)!;
      expect(JSON.stringify(tool.inputSchema)).toContain('"session_title"');
    }
  });

  test("SessionInfo accepts it, and accepts its absence", () => {
    const base = {
      id: "s", task_id: "t", runtime: "claude", task_name: "n", project: "p", branch: null, cwd: "/x", pid: 1,
      can_nudge: false, client_name: null, state: "live", connected_at: "a", last_seen_at: "b",
    };
    expect(SessionInfo.parse(base).session_title).toBeUndefined();
    expect(SessionInfo.parse({ ...base, session_title: "Pricing" }).session_title).toBe("Pricing");
  });
});

describe("session_title over the socket", () => {
  let home: string;
  let server: RpcServer;
  let store: Store;
  const clients: RpcClient[] = [];

  beforeAll(() => {
    home = tmpHome();
    const bus = new EventBus();
    store = new Store(new Database(join(home, "knock.db")), home, bus);
    server = startRpcServer({ socketPath: join(home, "knock.sock"), store, bus, version: "0.1.0" });
  });

  afterAll(() => {
    for (const c of clients.splice(0)) {
      try {
        c.close();
      } catch {
        // Already closed.
      }
    }
    server.stop();
    rmrf(home);
  });

  const titleOf = (id: string) => store.listSessions().find((s) => s.id === id)?.session_title;

  test("case.create stores it, case.update replaces it, an ask without one keeps it", async () => {
    const client = await rpcConnect(join(home, "knock.sock"));
    clients.push(client);
    await client.request("session.hello", { session_id: "sess-title", cwd: join(home, "work"), parent_pid: 4242 });
    expect(titleOf("sess-title")).toBeNull();

    const created = await client.request("case.create", { ...ask, session_title: "Pricing page copy" });
    const caseId = (created.result as { id: string }).id;
    expect(titleOf("sess-title")).toBe("Pricing page copy");

    await client.request("case.update", { case_id: caseId, message: "More.", session_title: "Pricing page and emails" });
    expect(titleOf("sess-title")).toBe("Pricing page and emails");

    await client.request("case.update", { case_id: caseId, message: "Again." });
    expect(titleOf("sess-title")).toBe("Pricing page and emails");
  });

  test("sessions.list returns it", async () => {
    const client = await rpcConnect(join(home, "knock.sock"));
    clients.push(client);
    const res = await client.request("sessions.list", {});
    const list = res.result as { id: string; session_title?: string | null }[];
    expect(list.find((s) => s.id === "sess-title")?.session_title).toBe("Pricing page and emails");
  });
});
