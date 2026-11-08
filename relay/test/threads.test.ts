import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import worker, { type Env } from "../src/index";
import { sha256Hex } from "../src/auth";
import { newUser } from "./helpers";

// WAG-394: threads, resolve, the decision, closed comments, the ask of a round, image rounds, stopped links.
const E = env as unknown as Env;
const APP = E.APP_ORIGIN;
const CONTENT = E.CONTENT_ORIGIN;

function call(path: string, init: RequestInit & { origin?: string } = {}): Promise<Response> {
  const headers = new Headers(init.headers);
  if (init.body && !headers.has("content-type")) headers.set("content-type", "application/json");
  return worker.fetch(new Request((init.origin ?? APP) + path, { ...init, headers }), E);
}
const page = (cookie?: string) => ({ origin: APP, ...(cookie ? { cookie } : {}) });
const cookieOf = (res: Response) => (res.headers.get("set-cookie") ?? "").split(";")[0];

async function newCase() {
  const key = "owner-key-" + crypto.randomUUID();
  const me = await newUser(call, E);
  const res = await call("/api/cases", { method: "POST", headers: me.bearer, body: JSON.stringify({ title: "Threads", owner_key_hash: await sha256Hex(key) }) });
  expect(res.status).toBe(201);
  const c = (await res.json()) as { id: string };
  return { id: c.id, key, me, auth: { authorization: `Bearer ${key}` } };
}
type Case = Awaited<ReturnType<typeof newCase>>;

async function addRound(c: Case, over: Record<string, unknown> = {}) {
  const res = await call(`/api/cases/${c.id}/rounds`, {
    method: "POST",
    headers: c.auth,
    body: JSON.stringify({ entry: "index.html", files: [{ path: "index.html", body_base64: btoa("<p>Hello " + crypto.randomUUID() + "</p>") }], ...over }),
  });
  expect([200, 201]).toContain(res.status);
  return (await res.json()) as { seq: number };
}

async function guest(c: Case, name: string) {
  const join = await call(`/api/cases/${c.id}/guest`, { method: "POST", headers: page(), body: JSON.stringify({ name }) });
  expect(join.status).toBe(200);
  return cookieOf(join);
}

async function post(c: Case, cookie: string, body: Record<string, unknown>) {
  return call(`/api/cases/${c.id}/comments`, { method: "POST", headers: page(cookie), body: JSON.stringify({ round_seq: 1, ...body }) });
}

type Comment = { id: string; parent_id: string | null; resolved_at: number | null; resolved_by: string | null; can_resolve: boolean; author_kind: string; author_name: string; round_seq: number; body: string };
const stateOf = async (c: Case, cookie?: string) =>
  (await (await call(`/api/cases/${c.id}/state`, { headers: cookie ? { cookie } : {} })).json()) as {
    status: string;
    decided: { options: string[]; note?: string; at: number } | null;
    comments_closed: boolean;
    ask: { need: string } | null;
    rounds: { seq: number; src: string; ask: { need: string } | null }[];
    comments: Comment[];
  };

describe("reply threads", () => {
  it("puts a reply under its comment, and a reply to a reply under the root", async () => {
    const c = await newCase();
    await addRound(c);
    const ada = await guest(c, "Ada");
    const root = ((await (await post(c, ada, { body: "Why every hour?", quote: "Hello" })).json()) as { comment: Comment }).comment;
    const bob = await guest(c, "Bob");
    const r1 = ((await (await post(c, bob, { body: "Same question", parent_id: root.id })).json()) as { comment: Comment }).comment;
    expect(r1.parent_id).toBe(root.id);
    const r2 = ((await (await post(c, ada, { body: "Thanks", parent_id: r1.id })).json()) as { comment: Comment }).comment;
    expect(r2.parent_id).toBe(root.id);
    const s = await stateOf(c);
    expect(s.comments.map((x) => x.parent_id)).toEqual([null, root.id, root.id]);
    expect(s.comments.every((x) => x.round_seq === 1)).toBe(true);
  });

  it("refuses a reply to a comment that is not in the case", async () => {
    const c = await newCase();
    await addRound(c);
    const other = await newCase();
    await addRound(other);
    const root = ((await (await post(other, await guest(other, "Zed"), { body: "elsewhere" })).json()) as { comment: Comment }).comment;
    const res = await post(c, await guest(c, "Ada"), { body: "x", parent_id: root.id });
    expect(res.status).toBe(400);
  });

  it("lets the owner's Mac reply as the owner or as the agent; only the owner starts a thread", async () => {
    const c = await newCase();
    await addRound(c);
    const root = ((await (await post(c, await guest(c, "Ada"), { body: "Question" })).json()) as { comment: Comment }).comment;
    const send = (b: Record<string, unknown>, headers: Record<string, string> = c.auth) =>
      call(`/api/cases/${c.id}/comments`, { method: "POST", headers, body: JSON.stringify(b) });
    expect((await send({ body: "no parent", author_kind: "agent" })).status).toBe(400);
    expect((await send({ body: "bad kind", parent_id: root.id, author_kind: "guest" })).status).toBe(400);
    expect((await send({ body: "x", parent_id: root.id, author_kind: "agent" }, { authorization: "Bearer nope" })).status).toBe(401);
    const agent = ((await (await send({ body: "Done in round 2", parent_id: root.id, author_kind: "agent" })).json()) as { comment: Comment }).comment;
    expect(agent).toMatchObject({ author_kind: "agent", author_name: "Agent", parent_id: root.id });
    const mine = ((await (await send({ body: "Fixed", parent_id: root.id, author_kind: "owner" }, c.me.bearer)).json()) as { comment: Comment }).comment;
    expect(mine).toMatchObject({ author_kind: "owner", parent_id: root.id });
    expect(mine.author_name).toContain(c.me.email.split("@")[0]);
    // WAG-397: "On the page" in the app posts a new owner thread on a round.
    const top = ((await (await send({ body: "From the Mac", round_seq: 1, author_kind: "owner" }, c.me.bearer)).json()) as { comment: Comment }).comment;
    expect(top).toMatchObject({ author_kind: "owner", parent_id: null, body: "From the Mac" });
  });

  it("does not let a guest take the name Agent", async () => {
    const c = await newCase();
    const res = await call(`/api/cases/${c.id}/guest`, { method: "POST", headers: page(), body: JSON.stringify({ name: "agent" }) });
    expect(res.status).toBe(400);
  });
});

describe("resolve", () => {
  it("lets the owner and the author resolve and reopen, and nobody else", async () => {
    const c = await newCase();
    await addRound(c);
    const ada = await guest(c, "Ada");
    const bob = await guest(c, "Bob");
    const root = ((await (await post(c, ada, { body: "Question" })).json()) as { comment: Comment }).comment;
    const reply = ((await (await post(c, bob, { body: "me too", parent_id: root.id })).json()) as { comment: Comment }).comment;
    const url = (id: string, what: string) => `/api/cases/${c.id}/comments/${id}/${what}`;

    expect((await stateOf(c, ada)).comments.find((x) => x.id === root.id)!.can_resolve).toBe(true);
    expect((await stateOf(c, bob)).comments.find((x) => x.id === root.id)!.can_resolve).toBe(false);
    expect((await call(url(root.id, "resolve"), { method: "POST", headers: page(bob) })).status).toBe(403);
    // A reply id resolves the thread it belongs to. The author of the root may do it.
    const done = await call(url(reply.id, "resolve"), { method: "POST", headers: page(ada) });
    expect(done.status).toBe(200);
    const after = (await stateOf(c)).comments;
    expect(after.find((x) => x.id === root.id)).toMatchObject({ resolved_by: "Ada" });
    expect(after.find((x) => x.id === root.id)!.resolved_at).toBeGreaterThan(0);
    // The Mac reads the resolved threads with its comments.
    const mac = (await (await call(`/api/cases/${c.id}/comments`, { headers: c.auth })).json()) as { resolved: { id: string }[] };
    expect(mac.resolved.map((x) => x.id)).toEqual([root.id]);
    // A cookie write must come from the page.
    expect((await call(url(root.id, "reopen"), { method: "POST", headers: { cookie: ada } })).status).toBe(403);
    // The owner reopens with the owner key.
    expect((await call(url(root.id, "reopen"), { method: "POST", headers: c.auth })).status).toBe(200);
    expect((await stateOf(c)).comments.find((x) => x.id === root.id)!.resolved_at).toBeNull();
  });

  it("lets only the owner resolve a comment of the agent", async () => {
    const c = await newCase();
    await addRound(c);
    const root = ((await (await post(c, await guest(c, "Ada"), { body: "Q" })).json()) as { comment: Comment }).comment;
    const agent = ((await (await call(`/api/cases/${c.id}/comments`, { method: "POST", headers: c.auth, body: JSON.stringify({ body: "A", parent_id: root.id, author_kind: "agent" }) })).json()) as { comment: Comment }).comment;
    const s = await stateOf(c, await guest(c, "Bob"));
    expect(s.comments.find((x) => x.id === agent.id)!.can_resolve).toBe(false);
    expect((await call(`/api/cases/${c.id}/comments/${agent.id}/resolve`, { method: "POST", headers: c.me.bearer })).status).toBe(200);
  });
});

describe("the decision, closed comments and the ask of a round", () => {
  it("shows the decision, and a new round with an ask opens the case again", async () => {
    const c = await newCase();
    await addRound(c, { ask: { need: "Which one?" } });
    const patch = (b: unknown) => call(`/api/cases/${c.id}`, { method: "PATCH", headers: c.auth, body: JSON.stringify(b) });
    expect((await stateOf(c)).status).toBe("open");
    const res = await patch({ status: "decided", decided: { options: ["Flag first"], note: "Ship it", at: 1700000000000 } });
    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({ status: "decided", comments_closed: false });
    const s = await stateOf(c);
    expect(s.status).toBe("decided");
    expect(s.decided).toEqual({ options: ["Flag first"], note: "Ship it", at: 1700000000000 });
    expect(s.ask).toMatchObject({ need: "Which one?" });
    expect((await patch({ status: "decided", decided: { options: "no" } })).status).toBe(400);
    expect((await patch({ status: "later" })).status).toBe(400);
    await addRound(c, { ask: { need: "And now?" } });
    const again = await stateOf(c);
    expect(again.status).toBe("open");
    expect(again.decided).toBeNull();
    expect(again.rounds.map((r) => r.ask?.need)).toEqual(["Which one?", "And now?"]);
  });

  it("changes the ask of the last round with a PATCH, without a new round", async () => {
    const c = await newCase();
    await addRound(c, { ask: { need: "Old need" } });
    await call(`/api/cases/${c.id}`, { method: "PATCH", headers: c.auth, body: JSON.stringify({ status: "decided", decided: { options: [] } }) });
    const res = await call(`/api/cases/${c.id}`, { method: "PATCH", headers: c.auth, body: JSON.stringify({ ask: { need: "New need", options: [{ title: "A", label: "Option A", recommended: true }] } }) });
    expect(res.status).toBe(200);
    const s = await stateOf(c);
    expect(s.rounds).toHaveLength(1);
    expect(s.ask).toMatchObject({ need: "New need" });
    expect(s.rounds[0].ask).toMatchObject({ need: "New need" });
    expect(s.status).toBe("open");
    expect((await call(`/api/cases/${c.id}`, { method: "PATCH", headers: c.auth, body: JSON.stringify({ ask: { why: "no need" } }) })).status).toBe(400);
    expect((await call(`/api/cases/${c.id}`, { method: "PATCH", headers: { authorization: "Bearer x" }, body: JSON.stringify({ ask: { need: "x" } }) })).status).toBe(401);
  });

  it("keeps the question of a round when the ask is for a follow-up that has no round yet", async () => {
    const c = await newCase();
    await addRound(c, { ask: { need: "First question" } });
    const patch = (b: unknown) => call(`/api/cases/${c.id}`, { method: "PATCH", headers: c.auth, body: JSON.stringify(b) });
    expect((await patch({ ask: { need: "Next step" }, round_seq: null })).status).toBe(200);
    const s = await stateOf(c);
    expect(s.ask).toMatchObject({ need: "Next step" });
    expect(s.rounds[0].ask).toMatchObject({ need: "First question" });
    expect((await patch({ ask: { need: "Named round" }, round_seq: 1 })).status).toBe(200);
    expect((await stateOf(c)).rounds[0].ask).toMatchObject({ need: "Named round" });
    expect((await patch({ ask: { need: "x" }, round_seq: "one" })).status).toBe(400);
  });

  it("closes the comments for everyone, and opens them again", async () => {
    const c = await newCase();
    await addRound(c);
    const ada = await guest(c, "Ada");
    const root = ((await (await post(c, ada, { body: "Open for now" })).json()) as { comment: Comment }).comment;
    const patch = (b: unknown, headers: Record<string, string>) => call(`/api/cases/${c.id}`, { method: "PATCH", headers, body: JSON.stringify(b) });
    expect((await patch({ comments_closed: "yes" }, c.auth)).status).toBe(400);
    expect((await patch({ comments_closed: true }, { cookie: ada, origin: APP })).status).toBe(401);
    expect(await (await patch({ comments_closed: true }, c.auth)).json()).toMatchObject({ comments_closed: true });
    expect((await stateOf(c)).comments_closed).toBe(true);
    const refused = await post(c, ada, { body: "Late" });
    expect(refused.status).toBe(403);
    expect(await refused.json()).toMatchObject({ error: "Comments are closed." });
    expect((await post(c, ada, { body: "Late reply", parent_id: root.id })).status).toBe(403);
    // The owner opens them again from the page, with the account session.
    expect((await patch({ comments_closed: false }, { cookie: c.me.cookie, origin: APP })).status).toBe(200);
    expect((await post(c, ada, { body: "Back" })).status).toBe(201);
  });

  it("lets the owner close comments from the page with a web session", async () => {
    const me = await newUser(call, E);
    const res = await call("/api/cases", { method: "POST", headers: me.bearer, body: JSON.stringify({ title: "Mine", owner_key_hash: await sha256Hex("k") }) });
    const { id } = (await res.json()) as { id: string };
    const closed = await call(`/api/cases/${id}`, { method: "PATCH", headers: { cookie: me.cookie, origin: APP }, body: JSON.stringify({ comments_closed: true }) });
    expect(closed.status).toBe(200);
    // A web session from another origin is refused.
    const wrong = await call(`/api/cases/${id}`, { method: "PATCH", headers: { cookie: me.cookie, origin: "https://evil.example" }, body: JSON.stringify({ comments_closed: false }) });
    expect(wrong.status).toBe(403);
  });

  it("carries the words of the page for the decision, closed comments, the pause and the ticket refresh", async () => {
    const c = await newCase();
    const html = await (await call(`/d/${c.id}`)).text();
    for (const w of ["Decided", "Comments are closed.", "Paused. Reload for new comments.", "Close comments", "waggle-scroll-get", "Resolve", "Reply"]) expect(html).toContain(w);
    expect(html).toContain("setInterval(poll,POLL_MS)");
    expect(html).toContain("POLL_MS=20000");
    expect(html).toContain("IDLE_MS=30*60000");
  });
});

describe("image rounds", () => {
  const PNG = btoa("\x89PNG\r\n\x1a\nfake");
  async function imageRound(c: Case, path: string, body: string) {
    await addRound(c, { entry: path, files: [{ path, body_base64: body }] });
    const s = await stateOf(c);
    return s.rounds[s.rounds.length - 1].src;
  }

  it("wraps a screenshot in a page with the area script, and serves the raw file without the query", async () => {
    const c = await newCase();
    const src = await imageRound(c, "shot one.png", PNG);
    expect(src.endsWith("?view=1")).toBe(true);
    const wrapped = await call(src.slice(CONTENT.length), { origin: CONTENT });
    expect(wrapped.status).toBe(200);
    expect(wrapped.headers.get("content-type")).toContain("text/html");
    expect(wrapped.headers.get("content-security-policy")).toContain("sandbox allow-scripts");
    const html = await wrapped.text();
    expect(html).toContain('<img data-wg="shot one.png" src="shot%20one.png"');
    expect(html).toContain("waggle-area");
    expect(html).toContain('"name":"shot one.png"');
    expect(html).toContain('"image "+g.it.name');
    const raw = await call(src.slice(CONTENT.length).replace("?view=1", ""), { origin: CONTENT });
    expect(raw.headers.get("content-type")).toBe("image/png");
  });

  it("stacks the images of a screenshots round, each with its own name", async () => {
    const c = await newCase();
    await addRound(c, {
      entry: "01.png",
      gallery: ["01.png", "02.png", "03.png"],
      files: [
        { path: "01.png", body_base64: PNG },
        { path: "02.png", body_base64: PNG },
        { path: "03.png", body_base64: PNG },
      ],
    });
    const s = await stateOf(c);
    const src = s.rounds[0].src;
    expect(src).toContain("?view=1&g=01.png,02.png,03.png");
    const html = await (await call(src.slice(CONTENT.length), { origin: CONTENT })).text();
    for (const n of ["01.png", "02.png", "03.png"]) expect(html).toContain(`<img data-wg="${n}" src="${n}"`);
    expect(html).toContain('"name":"03.png","kind":"img"');
    // A name that is not a plain file name never reaches the wrapper, and a bad gallery is refused.
    const odd = await (await call(src.slice(CONTENT.length).replace("g=01.png", 'g="><script>x</script>,01.png'), { origin: CONTENT })).text();
    expect(odd).not.toContain("<script>x</script>");
    const bad = await call(`/api/cases/${c.id}/rounds`, {
      method: "POST",
      headers: c.auth,
      body: JSON.stringify({ entry: "a.png", gallery: ["../x.png"], files: [{ path: "a.png", body_base64: PNG }] }),
    });
    expect(bad.status).toBe(400);
  });

  it("puts an SVG diagram inline, so its text can be selected", async () => {
    const c = await newCase();
    const svg = '<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 40"><text x="5" y="20">Cache</text></svg>';
    const src = await imageRound(c, "flow.svg", btoa(svg));
    const html = await (await call(src.slice(CONTENT.length), { origin: CONTENT })).text();
    expect(html).toContain("<svg");
    expect(html).toContain(">Cache</text>");
    expect(html).not.toContain("<?xml");
    expect(html).toContain("waggle-selection");
    expect(html).toContain('"kind":"svg"');
    expect(html).toContain("IMG=[{");
  });

  it("does not wrap an image that an HTML round loads", async () => {
    const c = await newCase();
    await addRound(c, { entry: "index.html", files: [{ path: "index.html", body_base64: btoa('<img src="a.png">') }, { path: "a.png", body_base64: PNG }] });
    const s = await stateOf(c);
    expect(s.rounds[0].src.endsWith("?view=1")).toBe(false);
    const img = await call(s.rounds[0].src.slice(CONTENT.length).replace("index.html", "a.png"), { origin: CONTENT });
    expect(img.headers.get("content-type")).toBe("image/png");
  });
});

describe("a stopped link", () => {
  it("says the owner stopped sharing, and keeps 'not here' for a link that never existed", async () => {
    const c = await newCase();
    await addRound(c);
    expect((await call(`/api/cases/${c.id}`, { method: "DELETE", headers: c.auth })).status).toBe(200);
    const gone = await call(`/d/${c.id}`);
    expect(gone.status).toBe(410);
    expect(await gone.text()).toContain("Sharing for this case was stopped by its owner.");
    const api = await call(`/api/cases/${c.id}/state`);
    expect(api.status).toBe(410);
    expect(await api.json()).toMatchObject({ error: "Sharing for this case was stopped by its owner.", code: "stopped" });
    const never = await call("/d/neverwas");
    expect(never.status).toBe(404);
    expect(await never.text()).toContain("This case is not here");
  });
});

describe("tickets", () => {
  it("gives a fresh ticket with each answer, and the frame script can give back its scroll", async () => {
    const c = await newCase();
    await addRound(c);
    const a = (await stateOf(c)).rounds[0].src;
    const exp = Number(/\/t\/(\d+)\./.exec(a)![1]);
    expect(exp * 1000).toBeGreaterThan(Date.now() + 3000_000);
    const html = await (await call(a.slice(CONTENT.length), { origin: CONTENT })).text();
    expect(html).toContain("waggle-scroll-get");
    expect(html).toContain("waggle-scroll-set");
    const old = a.replace(/\/t\/\d+\./, "/t/1.");
    expect((await call(old.slice(CONTENT.length), { origin: CONTENT })).status).toBe(403);
  });
});

describe("WAG-394 review fixes", () => {
  it("R1: shows no address to a reader who is not the owner, in the resolver name either", async () => {
    const c = await newCase();
    await addRound(c);
    const ada = await guest(c, "Ada");
    const root = ((await (await post(c, ada, { body: "Q" })).json()) as { comment: Comment }).comment;
    // The owner's Mac resolves. The account has no display name, so the resolver name is the address.
    expect((await call(`/api/cases/${c.id}/comments/${root.id}/resolve`, { method: "POST", headers: c.me.bearer })).status).toBe(200);
    await call(`/api/cases/${c.id}/comments`, { method: "POST", headers: c.me.bearer, body: JSON.stringify({ body: "Fixed", parent_id: root.id, author_kind: "owner" }) });
    const local = c.me.email.split("@")[0];
    const anon = await (await call(`/api/cases/${c.id}/state`)).text();
    const asGuest = await (await call(`/api/cases/${c.id}/state`, { headers: { cookie: ada } })).text();
    for (const raw of [anon, asGuest]) {
      expect(raw).not.toContain(c.me.email);
      expect(raw).not.toContain("@");
      expect(raw).toContain(local);
    }
    const owner = await (await call(`/api/cases/${c.id}/state`, { headers: { cookie: c.me.cookie } })).text();
    expect(owner).toContain(c.me.email);
  });

  it("R2: the case cap and closed comments do not stop the owner or the agent", async () => {
    const c = await newCase();
    await addRound(c);
    const ada = await guest(c, "Ada");
    const root = ((await (await post(c, ada, { body: "Q" })).json()) as { comment: Comment }).comment;
    const row = (await E.DB.prepare("SELECT commit_id FROM comments WHERE id = ?").bind(root.id).first<{ commit_id: string }>())!;
    await E.DB.prepare(
      `WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 2000)
       INSERT INTO comments (id, case_id, round_seq, commit_id, body, author_kind, author_name, created_at) SELECT 'f' || i, ?, 1, ?, 'x', 'guest', 'Fill', 1 FROM n`,
    )
      .bind(c.id, row.commit_id)
      .run();
    const send = (b: Record<string, unknown>, headers: Record<string, string>) => call(`/api/cases/${c.id}/comments`, { method: "POST", headers, body: JSON.stringify(b) });
    expect((await post(c, ada, { body: "More" })).status).toBe(429);
    expect((await send({ body: "A", parent_id: root.id, author_kind: "agent" }, c.auth)).status).toBe(201);
    expect((await send({ body: "O", parent_id: root.id, author_kind: "owner" }, c.me.bearer)).status).toBe(201);
    // Closed comments stop guests but not the owner or the agent.
    await call(`/api/cases/${c.id}`, { method: "PATCH", headers: c.auth, body: JSON.stringify({ comments_closed: true }) });
    expect((await post(c, ada, { body: "Late", parent_id: root.id })).status).toBe(403);
    expect((await send({ body: "A2", parent_id: root.id, author_kind: "agent" }, c.auth)).status).toBe(201);
    expect((await send({ body: "O2", parent_id: root.id, author_kind: "owner" }, c.me.bearer)).status).toBe(201);
  });

  it("R3: refuses a round_seq that names no round", async () => {
    const c = await newCase();
    await addRound(c);
    const res = await call(`/api/cases/${c.id}`, { method: "PATCH", headers: c.auth, body: JSON.stringify({ ask: { need: "x" }, round_seq: 99 }) });
    expect(res.status).toBe(400);
    expect(res.headers.get("content-type")).toContain("json");
    expect((await call(`/api/cases/${c.id}`, { method: "PATCH", headers: c.auth, body: JSON.stringify({ ask: { need: "x" }, round_seq: 1 }) })).status).toBe(200);
  });

  it("R4: refuses reserved and taken names written with other letters or hidden characters", async () => {
    const c = await newCase();
    const join = (name: string) => call(`/api/cases/${c.id}/guest`, { method: "POST", headers: page(), body: JSON.stringify({ name }) });
    for (const name of ["Ａgent", "Age​nt", "ＯＷＮＥＲ", "Own⁠er", " ​Agent "]) expect((await join(name)).status).toBe(400);
    const ok = await join("  Ａda​ ");
    expect(ok.status).toBe(200);
    expect(await ok.json()).toMatchObject({ viewer: { name: "Ada" } });
  });
});
