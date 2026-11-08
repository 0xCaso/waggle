import { afterAll, beforeAll, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { join } from "node:path";
import { RelaySharing } from "../src/connectors/relay";
import { MemorySecretStore } from "../src/connectors/secrets";
import { EventBus } from "../src/events";
import { DaemonClient } from "../src/mcp/client";
import { startRpcServer, type RpcServer } from "../src/server";
import { Store } from "../src/store";
import type { SharingState } from "../src/protocol";
import { FakeRelay } from "./fake-relay";
import { rmrf, tmpHome } from "./helpers";

// WAG-387: the sharing.* socket methods, and the shared comments on case.wait (waggle_check).

let home: string;
let relay: FakeRelay;
let sharing: RelaySharing;
let server: RpcServer;
let client: DaemonClient;
let store: Store;

beforeAll(async () => {
  home = tmpHome();
  relay = new FakeRelay();
  const bus = new EventBus();
  store = new Store(new Database(join(home, "knock.db")), home, bus);
  const signedIn = new MemorySecretStore();
  signedIn.set("relay-device", relay.issueToken());
  sharing = new RelaySharing({ store, bus, secrets: signedIn, baseUrl: relay.baseUrl, log: () => {} });
  server = startRpcServer({ socketPath: join(home, "knock.sock"), store, bus, version: "0.1.0", relay: sharing });
  client = new DaemonClient();
  await client.connect(join(home, "knock.sock"));
  await client.call("session.hello", { session_id: "sess-relay", cwd: join(home, "work"), parent_pid: 4242 }, 5000);
});

afterAll(() => {
  client.close();
  server.stop();
  relay.stop();
  rmrf(home);
});

test("share, comment, check, stop over the socket", async () => {
  const state0 = (await client.call("sharing.get", {}, 5000)) as SharingState;
  expect(state0).toMatchObject({ enabled: false, shared_count: 0, share: null });

  const created = (await client.call(
    "case.create",
    { kind: "question", title: "Pick", need: "Pick one", why: "w", recommendation: "a", recommendation_why: "r", options: [{ id: "a", label: "A" }] },
    5000,
  )) as { id: string };

  // Off: the call fails in plain words and nothing reaches the relay.
  await expect(client.call("sharing.start", { case_id: created.id, mode: "link" }, 5000)).rejects.toThrow("Sharing is off");
  expect(relay.calls).toHaveLength(0);

  expect(((await client.call("sharing.set_enabled", { enabled: true }, 5000)) as SharingState).enabled).toBe(true);
  const shared = (await client.call("sharing.start", { case_id: created.id, mode: "link" }, 5000)) as SharingState;
  expect(shared.share?.url).toContain("/d/");
  expect(shared.shared_count).toBe(1);

  // A case.wait that times out still carries the comments, in the new field.
  relay.addComment(store.getRelayShare(created.id)!.relay_id, { id: "k1", created_at: 50, quote: "hourly", body: "Why?" });
  const refreshed = (await client.call("sharing.refresh", { case_id: created.id }, 5000)) as SharingState;
  expect(refreshed.comments.map((c) => c.body)).toEqual(["Why?"]);
  const pending = (await client.call("case.wait", { case_id: created.id, wait_ms: 30 }, 5000)) as {
    status: string;
    shared_comments: { author_name: string; quote: string }[];
  };
  expect(pending.status).toBe("pending");
  expect(pending.shared_comments).toMatchObject([{ author_name: "Ada", quote: "hourly" }]);

  // An answer from the human is the only thing that decides. The comment did not.
  expect(store.getCase(created.id)!.case.status).toBe("needs_you");

  const stopped = (await client.call("sharing.stop", { case_id: created.id }, 5000)) as SharingState;
  expect(stopped.share).toBeNull();
  // The comments stay after Stop sharing (WAG-391): the app section and the agent still have them.
  expect(stopped.comments.map((c) => c.body)).toEqual(["Why?"]);
  const after = (await client.call("case.wait", { case_id: created.id, wait_ms: 30 }, 5000)) as {
    shared_comments?: { author_name: string }[];
  };
  expect(after.shared_comments).toMatchObject([{ author_name: "Ada" }]);
});
