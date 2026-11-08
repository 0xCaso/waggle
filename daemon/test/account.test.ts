import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { RelaySharing, SIGN_IN_ENDED, SIGN_IN_FIRST } from "../src/connectors/relay";
import { MemorySecretStore } from "../src/connectors/secrets";
import { EventBus } from "../src/events";
import { Store } from "../src/store";
import { FakeRelay } from "./fake-relay";
import { mkdirSync, writeFileSync } from "node:fs";
import { rmrf, stageIncoming, tmpHome } from "./helpers";

// WAG-392: the Waggle account (device flow), shares list, stop from another Mac, update, open page.

let home: string;
let relay: FakeRelay;
let store: Store;
let secrets: MemorySecretStore;
let sharing: RelaySharing;
let caseId: string;
let logs: string[];
let fetchCalls: number;

function make(): RelaySharing {
  return new RelaySharing({
    store,
    secrets,
    baseUrl: relay.baseUrl,
    connectPollMs: 5,
    deviceLabel: () => "Ada's MacBook",
    log: (l) => logs.push(l),
    fetch: (i, init) => {
      fetchCalls++;
      return fetch(i, init);
    },
  });
}

function newCase(title: string): string {
  const task = store.createTask({ name: "t", project: "p" });
  return store.createCase(task.id, {
    kind: "question",
    title,
    need: "Pick one",
    why: "w",
    recommendation: "A",
    recommendation_why: "r",
    options: [{ id: "A", label: "A" }],
  }).id;
}

const wait = async (cond: () => boolean, ms = 2000) => {
  const end = Date.now() + ms;
  while (!cond() && Date.now() < end) await Bun.sleep(5);
  expect(cond()).toBe(true);
};

async function signIn(): Promise<void> {
  relay.autoApprove = true;
  await sharing.connectStart();
  await wait(() => sharing.accountState().signed_in);
}

beforeEach(() => {
  home = tmpHome();
  relay = new FakeRelay();
  store = new Store(new Database(join(home, "knock.db")), home, new EventBus());
  secrets = new MemorySecretStore();
  logs = [];
  fetchCalls = 0;
  sharing = make();
  caseId = newCase("Which plan?");
});

afterEach(() => {
  sharing.stop();
  relay.stop();
  rmrf(home);
});

describe("Sharing off", () => {
  test("account.get works and no call is made; connect_start says Sharing is off", async () => {
    expect(sharing.accountState()).toEqual({ signed_in: false, email: null, connect: null, error: null });
    await expect(sharing.connectStart()).rejects.toThrow("Sharing is off. Turn it on in Settings.");
    expect(await sharing.accountShares()).toEqual({ shares: [], error: null });
    await expect(sharing.signOut()).rejects.toThrow("Sharing is off");
    await expect(sharing.accountStopShare("x")).rejects.toThrow("Sharing is off");
    expect(fetchCalls).toBe(0);
    expect(relay.calls).toHaveLength(0);
  });
});

describe("Device flow", () => {
  beforeEach(() => {
    sharing.setEnabled(true);
  });

  test("connect shows a code, polls, stores the token only in the secret store", async () => {
    const started = await sharing.connectStart();
    expect(started.signed_in).toBe(false);
    expect(started.connect).toMatchObject({ user_code: "WXYZ-2000", verify_url: expect.stringContaining("/connect?code=WXYZ-2000") });
    expect(started.connect!.expires_at).toBeGreaterThan(Date.now());
    expect(relay.calls[0]!.body).toEqual({ label: "Ada's MacBook" });
    // A second start returns the same code and makes no second device request.
    const again = await sharing.connectStart();
    expect(again.connect?.user_code).toBe("WXYZ-2000");
    expect(relay.calls.filter((c) => c.path === "/api/auth/device")).toHaveLength(1);

    await Bun.sleep(30);
    expect(sharing.accountState().signed_in).toBe(false);
    relay.approve("WXYZ-2000", "ada@example.test");
    await wait(() => sharing.accountState().signed_in);
    const state = sharing.accountState();
    expect(state).toEqual({ signed_in: true, email: "ada@example.test", connect: null, error: null });

    const token = secrets.get("relay-device")!;
    expect(token).toStartWith("dev_");
    // The token is nowhere else: not in knock.db, not in a log, not in an RPC result.
    expect(readFileSync(join(home, "knock.db")).includes(Buffer.from(token))).toBe(false);
    expect(readFileSync(join(home, "knock.db-wal"), { flag: "a+" }).includes(Buffer.from(token))).toBe(false);
    expect(JSON.stringify(store.getConnectorSetting("relay", { safeParse: (v: unknown) => ({ success: true, data: v }) }))).not.toContain(token);
    expect(logs.join("\n")).not.toContain(token);
    expect(JSON.stringify(sharing.state(caseId))).not.toContain(token);
    expect(JSON.stringify(state)).not.toContain(token);
  });

  test("the email survives a restart and needs no network", async () => {
    await signIn();
    const before = relay.calls.length;
    const again = make();
    expect(again.accountState()).toMatchObject({ signed_in: true, email: "ada@example.test" });
    expect(relay.calls.length).toBe(before);
  });

  test("cancel stops the polling", async () => {
    await sharing.connectStart();
    expect(sharing.connectCancel().connect).toBeNull();
    const n = relay.calls.length;
    await Bun.sleep(40);
    expect(relay.calls.length).toBe(n);
  });

  test("an expired code ends with a plain error", async () => {
    await sharing.connectStart();
    relay.deviceCodes.forEach((d) => (d.expired = true));
    await wait(() => sharing.accountState().error !== null);
    expect(sharing.accountState()).toEqual({ signed_in: false, email: null, connect: null, error: "The sign-in code ran out. Try again." });
  });

  test("a relay that cannot be reached at the start fails in plain words", async () => {
    relay.stop();
    await expect(sharing.connectStart()).rejects.toThrow("could not reach the sharing service");
    expect(sharing.accountState().connect).toBeNull();
  });

  test("turning Sharing off stops a running sign-in", async () => {
    await sharing.connectStart();
    sharing.setEnabled(false);
    expect(sharing.accountState().connect).toBeNull();
  });
});

describe("Sign out", () => {
  beforeEach(() => {
    sharing.setEnabled(true);
  });

  test("revokes at the relay, then removes the token and the email", async () => {
    await signIn();
    const token = secrets.get("relay-device")!;
    const state = await sharing.signOut();
    expect(state).toEqual({ signed_in: false, email: null, connect: null, error: null });
    const del = relay.calls.find((c) => c.method === "DELETE" && c.path === "/api/me/device")!;
    expect(del.auth).toBe(`Bearer ${token}`);
    expect(relay.devices.get(token)!.revoked).toBe(true);
    expect(secrets.get("relay-device")).toBeNull();
    expect(sharing.accountState().email).toBeNull();
    // Sharing stays on.
    expect(sharing.enabled()).toBe(true);
  });

  test("a 401 on revoke counts as done", async () => {
    await signIn();
    relay.devices.get(secrets.get("relay-device")!)!.revoked = true;
    const state = await sharing.signOut();
    expect(state.signed_in).toBe(false);
    expect(state.error).toBeNull();
  });

  test("a network failure keeps the sign-in and sets an error", async () => {
    await signIn();
    relay.failWith = 500;
    const state = await sharing.signOut();
    expect(state.signed_in).toBe(true);
    expect(state.email).toBe("ada@example.test");
    expect(state.error).toContain("sharing service");
    expect(secrets.get("relay-device")).not.toBeNull();
  });
});

describe("Sharing with an account", () => {
  beforeEach(() => {
    sharing.setEnabled(true);
  });

  test("share while signed out fails and makes no call", async () => {
    await expect(sharing.share(caseId, "link")).rejects.toThrow(SIGN_IN_FIRST);
    expect(SIGN_IN_FIRST).toBe("Sign in to Waggle first.");
    expect(relay.calls).toHaveLength(0);
  });

  test("a new share goes up with the device token and the key hash; stoppable follows the account", async () => {
    await signIn();
    const cwd = join(home, "work");
    mkdirSync(cwd, { recursive: true });
    writeFileSync(join(cwd, "plan.md"), "# Plan");
    store.createRevision(caseId, stageIncoming(home, cwd, { type: "markdown", path: "./plan.md" }));
    const state = await sharing.share(caseId, "link");
    const create = relay.calls.find((c) => c.path === "/api/cases" && c.method === "POST")!;
    expect(create.auth).toBe(`Bearer ${secrets.get("relay-device")}`);
    expect(create.body?.owner_key_hash).toMatch(/^[0-9a-f]{64}$/);
    expect(state.share?.stoppable).toBe(true);
    expect(state.account.signed_in).toBe(true);
    // The owner key is used for later owner calls when the Mac has it.
    const rounds = relay.calls.find((c) => c.path.endsWith("/rounds"))!;
    expect(rounds.auth).not.toBe(`Bearer ${secrets.get("relay-device")}`);
  });

  test("without the owner key the device token does the owner calls", async () => {
    await signIn();
    await sharing.share(caseId, "link");
    const row = store.getRelayShare(caseId)!;
    secrets.delete(`relay-owner.${row.relay_id}`);
    expect(sharing.state(caseId).share?.stoppable).toBe(true);
    const state = await sharing.stopSharing(caseId);
    expect(state.share).toBeNull();
    expect(relay.cases.size).toBe(0);
  });

  test("a 401 for the device token clears the sign-in with a plain error", async () => {
    await signIn();
    relay.devices.get(secrets.get("relay-device")!)!.revoked = true;
    await expect(sharing.share(caseId, "link")).rejects.toThrow(SIGN_IN_ENDED);
    expect(SIGN_IN_ENDED).toBe("Your Waggle sign-in ended. Sign in again.");
    expect(secrets.get("relay-device")).toBeNull();
    expect(sharing.accountState()).toEqual({ signed_in: false, email: null, connect: null, error: SIGN_IN_ENDED });
    expect(store.getRelayShare(caseId)).toBeNull();
  });

  test("a 401 for a case of another account keeps the sign-in", async () => {
    await signIn();
    const state = await sharing.share(caseId, "link");
    const share = store.getRelayShare(caseId)!;
    // This Mac has no owner key any more, so it calls with the device token. The case belongs to someone else now.
    secrets.delete(`relay-owner.${share.relay_id}`);
    relay.cases.get(share.relay_id)!.ownerEmail = "someone-else@example.test";
    expect(state.share).not.toBeNull();
    await expect(sharing.update(caseId, "emails", ["a@example.test"])).rejects.toThrow("Owner access needed");
    expect(secrets.get("relay-device")).not.toBeNull();
    expect(sharing.accountState().signed_in).toBe(true);
    expect(store.getRelayShare(caseId)).not.toBeNull();
  });

  test("a 401 with invalid_token on a case call clears the sign-in", async () => {
    await signIn();
    await sharing.share(caseId, "link");
    const share = store.getRelayShare(caseId)!;
    secrets.delete(`relay-owner.${share.relay_id}`);
    relay.devices.get(secrets.get("relay-device")!)!.revoked = true;
    await expect(sharing.update(caseId, "emails", ["a@example.test"])).rejects.toThrow(SIGN_IN_ENDED);
    expect(secrets.get("relay-device")).toBeNull();
  });

  test("the invite counts of a share and an audience change reach the state", async () => {
    await signIn();
    expect((await sharing.share(caseId, "link")).invites).toEqual({ sent: 0, failed: 0, limited: 0 });
    relay.invites = { sent: 1, failed: 1, limited: 2 };
    const state = await sharing.update(caseId, "emails", ["a@example.test", "b@example.test", "c@example.test", "d@example.test"]);
    expect(state.invites).toEqual({ sent: 1, failed: 1, limited: 2 });
    expect((await sharing.stopSharing(caseId)).invites).toEqual({ sent: 0, failed: 0, limited: 0 });
  });

  test("a 429 gives the relay's words", async () => {
    await signIn();
    relay.rateLimitCases = true;
    await expect(sharing.share(caseId, "link")).rejects.toThrow("too many cases today");
  });

  test("shares lists the account's pages with local_case_id", async () => {
    await signIn();
    await sharing.share(caseId, "link");
    // A page from another Mac of the same account.
    const other = relay.issueToken("ada@example.test", "Work Mac");
    await fetch(`${relay.baseUrl}/api/cases`, {
      method: "POST",
      headers: { authorization: `Bearer ${other}`, "content-type": "application/json" },
      body: JSON.stringify({ title: "Other", mode: "link", owner_key_hash: "a".repeat(64) }),
    });
    const { shares, error } = await sharing.accountShares();
    expect(error).toBeNull();
    expect(shares).toHaveLength(2);
    const mine = shares.find((s) => s.title === "Which plan?")!;
    expect(mine).toMatchObject({ mode: "link", device_label: "Ada's MacBook", comment_count: 0, local_case_id: caseId });
    expect(mine.created_at).toBeGreaterThan(0);
    expect(shares.find((s) => s.title === "Other")).toMatchObject({ device_label: "Work Mac", local_case_id: null });
    // Another account's page is not listed.
    relay.cases.set("zzz", { ...[...relay.cases.values()][0]!, id: "zzz", ownerEmail: "bob@example.test" });
    expect((await sharing.accountShares()).shares).toHaveLength(2);
  });

  test("shares: a failure gives an empty list and a plain error", async () => {
    await signIn();
    relay.failWith = 500;
    const r = await sharing.accountShares();
    expect(r.shares).toEqual([]);
    expect(r.error).toContain("sharing service");
  });

  test("stop_share from another Mac needs no local row", async () => {
    await signIn();
    const other = relay.issueToken("ada@example.test", "Work Mac");
    const res = await fetch(`${relay.baseUrl}/api/cases`, {
      method: "POST",
      headers: { authorization: `Bearer ${other}`, "content-type": "application/json" },
      body: JSON.stringify({ title: "Other", mode: "link", owner_key_hash: "a".repeat(64) }),
    });
    const { id } = (await res.json()) as { id: string };
    const out = await sharing.accountStopShare(id);
    expect(out).toEqual({ shares: [], error: null });
    expect(relay.cases.has(id)).toBe(false);
  });

  test("stop_share of a page shared here removes the row, its secret and updates shared_count", async () => {
    await signIn();
    await sharing.share(caseId, "link");
    const row = store.getRelayShare(caseId)!;
    expect(sharing.state().shared_count).toBe(1);
    const out = await sharing.accountStopShare(row.relay_id);
    expect(out.shares).toEqual([]);
    expect(store.getRelayShare(caseId)).toBeNull();
    expect(secrets.get(`relay-owner.${row.relay_id}`)).toBeNull();
    expect(sharing.state().shared_count).toBe(0);
    const del = relay.calls.find((c) => c.method === "DELETE" && c.path === `/api/cases/${row.relay_id}`)!;
    expect(del.auth).toBe(`Bearer ${secrets.get("relay-device")}`);
  });

  test("stop_share treats 404 as done and a page already gone still clears the row", async () => {
    await signIn();
    await sharing.share(caseId, "link");
    const row = store.getRelayShare(caseId)!;
    relay.cases.delete(row.relay_id);
    await sharing.accountStopShare(row.relay_id);
    expect(store.getRelayShare(caseId)).toBeNull();
  });

  test("update changes the audience at the relay and in the local row", async () => {
    await signIn();
    await sharing.share(caseId, "link");
    const row = store.getRelayShare(caseId)!;
    const state = await sharing.update(caseId, "emails", ["Bob@Example.test", "bob@example.test", "cy@example.test"]);
    expect(state.share).toMatchObject({ mode: "emails", emails: ["bob@example.test", "cy@example.test"] });
    expect(relay.cases.get(row.relay_id)).toMatchObject({ mode: "emails", emails: ["bob@example.test", "cy@example.test"] });
    expect(store.getRelayShare(caseId)).toMatchObject({ mode: "emails" });
    const back = await sharing.update(caseId, "link");
    expect(back.share).toMatchObject({ mode: "link", emails: [] });
    await expect(sharing.update(caseId, "emails", [])).rejects.toThrow("Add at least one email");
    await expect(sharing.update(newCase("x"), "link")).rejects.toThrow("not shared");
  });

  test("update surfaces the relay's plain 400 and keeps the local row", async () => {
    await signIn();
    await sharing.share(caseId, "link");
    relay.failWhen = (c) => (c.method === "PATCH" ? 400 : null);
    relay.failError = "50 emails at most";
    await expect(sharing.update(caseId, "emails", ["a@example.test"])).rejects.toThrow("50 emails at most");
    expect(store.getRelayShare(caseId)).toMatchObject({ mode: "link" });
  });

  test("open_page returns the one-time owner link", async () => {
    await signIn();
    await sharing.share(caseId, "link");
    const { url } = await sharing.openPage(caseId);
    expect(url).toContain("owner=");
    const call = relay.calls.find((c) => c.path.endsWith("/owner-link"))!;
    expect(call.method).toBe("POST");
    await expect(sharing.openPage(newCase("x"))).rejects.toThrow("not shared");
  });
});

describe("Comment authors", () => {
  test("kinds map to owner, member, guest and the email is kept", async () => {
    sharing.setEnabled(true);
    await signIn();
    await sharing.share(caseId, "link");
    const id = store.getRelayShare(caseId)!.relay_id;
    relay.addComment(id, { id: "c1", created_at: 10, author_kind: "email", author_name: "Bob", author_email: "bob@example.test" });
    relay.addComment(id, { id: "c2", created_at: 11, author_kind: "owner", author_name: "Ada", author_email: "ada@example.test" });
    relay.addComment(id, { id: "c3", created_at: 12, author_kind: "guest", author_name: "Zed" });
    await sharing.refresh(caseId);
    const comments = sharing.state(caseId).comments;
    expect(comments.map((c) => [c.author_kind, c.author_email])).toEqual([
      ["member", "bob@example.test"],
      ["owner", "ada@example.test"],
      ["guest", null],
    ]);
    expect(sharing.commentsForAgent(caseId).map((c) => c.author_kind)).toEqual(["member", "owner", "guest"]);
  });
});
