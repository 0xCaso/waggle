import { env } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { sha256Hex } from "../src/auth";
import worker, { type Env } from "../src/index";
import { FakeArtifacts } from "./fake-artifacts";
import { newUser } from "./helpers";

// The production store (ROUND_STORE=artifacts) with a fake Artifacts binding and a fake Git remote.
// The daemon uploads `files`; the Worker has to turn them into a Git commit the page can show (WAG-391 G1).

const base = env as unknown as Env;
let fake: FakeArtifacts;
let A: Env;

beforeEach(() => {
  fake = new FakeArtifacts();
  fake.install();
  A = { ...base, ROUND_STORE: "artifacts", ARTIFACTS: fake.binding() } as Env;
});
afterEach(() => vi.restoreAllMocks());

function call(path: string, init: RequestInit & { origin?: string } = {}): Promise<Response> {
  const headers = new Headers(init.headers);
  if (init.body && !headers.has("content-type")) headers.set("content-type", "application/json");
  return worker.fetch(new Request((init.origin ?? A.APP_ORIGIN) + path, { ...init, headers }), A);
}

async function newCase(extra: Record<string, unknown> = {}) {
  const key = "owner-key-" + crypto.randomUUID();
  const me = await newUser(call, A);
  const res = await call("/api/cases", {
    method: "POST",
    headers: me.bearer,
    body: JSON.stringify({ title: "Pricing", mode: "link", owner_key_hash: await sha256Hex(key), ...extra }),
  });
  expect([200, 201]).toContain(res.status);
  const c = (await res.json()) as { id: string; store: string; repo: string };
  return { ...c, status: res.status, key, auth: { authorization: `Bearer ${key}` } };
}

const files = (html = "<h1>Hi</h1>") => [
  { path: "index.html", body_base64: btoa(html) },
  { path: "css/style.css", body_base64: btoa("h1{color:red}") },
];

const post = (c: Awaited<ReturnType<typeof newCase>>, body: Record<string, unknown>) =>
  call(`/api/cases/${c.id}/rounds`, { method: "POST", headers: c.auth, body: JSON.stringify(body) });

describe("rounds with ROUND_STORE=artifacts", () => {
  it("turns an uploaded round into a Git commit the page shows", async () => {
    const c = await newCase();
    expect(c.store).toBe("artifacts");
    const res = await post(c, { label: "Two layouts", entry: "index.html", files: files() });
    expect(res.status).toBe(201);
    const round = (await res.json()) as { seq: number; commit: string };
    expect(round.commit).toMatch(/^[0-9a-f]{40}$/);
    expect(fake.pushes).toHaveLength(1);
    expect(fake.paths(c.repo, round.commit).sort()).toEqual(["css/style.css", "index.html"]);

    const state = (await (await call(`/api/cases/${c.id}/state`)).json()) as { rounds: { seq: number; src: string; commit_id: string }[] };
    expect(state.rounds.map((r) => r.commit_id)).toEqual([round.commit]);
    const page = await call(state.rounds[0].src.slice(A.CONTENT_ORIGIN.length), { origin: A.CONTENT_ORIGIN });
    expect(page.status).toBe(200);
    expect(await page.text()).toContain("<h1>Hi</h1>");
    const css = await call(state.rounds[0].src.slice(A.CONTENT_ORIGIN.length).replace("index.html", "css/style.css"), { origin: A.CONTENT_ORIGIN });
    expect(css.headers.get("content-type")).toContain("text/css");
  });

  it("chains the next round on the branch and gives a variant its own branch", async () => {
    const c = await newCase();
    const r1 = (await (await post(c, { label: "A", entry: "index.html", files: files("one") })).json()) as { commit: string };
    const r2 = (await (await post(c, { label: "B", entry: "index.html", files: files("two") })).json()) as { seq: number; commit: string };
    expect(r2.seq).toBe(2);
    expect(fake.parentOf(c.repo, r2.commit)).toBe(r1.commit);
    expect(fake.repos.get(c.repo)!.refs.get("refs/heads/main")).toBe(r2.commit);
    const r3 = (await (await post(c, { label: "C", variant: "dark", entry: "index.html", files: files("three") })).json()) as { commit: string };
    expect(fake.repos.get(c.repo)!.refs.get("refs/heads/dark")).toBe(r3.commit);
    expect(fake.parentOf(c.repo, r3.commit)).toBeNull();
  });

  it("gives a retried upload the same round and pushes nothing new", async () => {
    const c = await newCase();
    const a = (await (await post(c, { label: "A", entry: "index.html", files: files() })).json()) as { seq: number; commit: string };
    const b = await post(c, { label: "A", entry: "index.html", files: files() });
    expect(b.status).toBe(200);
    expect(await b.json()).toEqual(a);
    expect(fake.pushes).toHaveLength(1);
  });

  it("still takes a round pushed by a Git client (commit id)", async () => {
    const c = await newCase();
    const a = (await (await post(c, { label: "A", entry: "index.html", files: files() })).json()) as { commit: string };
    const known = await post(c, { label: "Again", entry: "index.html", commit: a.commit });
    expect(known.status).toBe(200);
    const missing = await post(c, { label: "X", entry: "index.html", commit: "0".repeat(40) });
    expect(missing.status).toBe(400);
    expect(((await missing.json()) as { error: string }).error).toContain("not in the case's repo");
  });

  it("refuses what is too big, with the reason", async () => {
    const c = await newCase();
    const big = await post(c, { label: "A", entry: "a", files: [{ path: "a", body_base64: "A".repeat(1_400_001) }] });
    expect(big.status).toBe(413);
    expect(((await big.json()) as { error: string }).error).toContain("over 1 MB");
    const many = await post(c, { label: "A", entry: "f0", files: Array.from({ length: 201 }, (_, i) => ({ path: `f${i}`, body_base64: "QQ==" })) });
    expect(many.status).toBe(400);
    expect(((await many.json()) as { error: string }).error).toBe("200 files at most");
    const dup = await post(c, { label: "A", entry: "a", files: [{ path: "a", body_base64: "QQ==" }, { path: "./a", body_base64: "QQ==" }] });
    expect(dup.status).toBe(400);
    expect(fake.pushes).toHaveLength(0);
  });

  it("answers 502 with a plain reason when the Git remote says no, and adds no round", async () => {
    const c = await newCase();
    fake.refuse = 503;
    const res = await post(c, { label: "A", entry: "index.html", files: files() });
    expect(res.status).toBe(502);
    expect(((await res.json()) as { error: string }).error).toContain("refused the push");
    fake.refuse = null;
    const n = await env.DB.prepare("SELECT COUNT(*) AS n FROM rounds WHERE case_id = ?").bind(c.id).first<{ n: number }>();
    expect(n!.n).toBe(0);
    expect((await post(c, { label: "A", entry: "index.html", files: files() })).status).toBe(201);
  });

  it("deletes the repo with the case", async () => {
    const c = await newCase();
    await post(c, { label: "A", entry: "index.html", files: files() });
    expect((await call(`/api/cases/${c.id}`, { method: "DELETE", headers: c.auth })).status).toBe(200);
    expect(fake.repos.has(c.repo)).toBe(false);
  });
});

describe("share is idempotent (G26)", () => {
  it("returns the same case for the same request_id and makes one repo", async () => {
    const hash = await sha256Hex("k");
    const me = await newUser(call, A);
    const send = () => call("/api/cases", { method: "POST", headers: me.bearer, body: JSON.stringify({ title: "T", owner_key_hash: hash, request_id: "req-1" }) });
    const first = await send();
    const second = await send();
    expect(first.status).toBe(201);
    expect(second.status).toBe(200);
    const a = (await first.json()) as { id: string };
    expect(((await second.json()) as { id: string }).id).toBe(a.id);
    expect(fake.created).toHaveLength(1);
    // Another request id, or no id, is a new case.
    const other = await call("/api/cases", { method: "POST", headers: me.bearer, body: JSON.stringify({ title: "T", owner_key_hash: hash, request_id: "req-2" }) });
    expect(((await other.json()) as { id: string }).id).not.toBe(a.id);
  });

  it("does not leave a repo behind when the case cannot be saved", async () => {
    const hash = await sha256Hex("k2");
    const me = await newUser(call, A);
    // D1 fails after the repo was made: the batch throws.
    const broken = { ...A, DB: { ...A.DB, prepare: (q: string) => A.DB.prepare(q), batch: async () => { throw new Error("D1 down"); } } } as unknown as Env;
    const before = fake.repos.size;
    const out = await worker.fetch(
      new Request(`${A.APP_ORIGIN}/api/cases`, { method: "POST", headers: { "content-type": "application/json", ...me.bearer }, body: JSON.stringify({ title: "T", owner_key_hash: hash, request_id: "other" }) }),
      broken,
    );
    expect(out.status).toBe(500);
    expect(fake.repos.size).toBe(before);
  });
});

describe("the comment cursor (G26)", () => {
  it("does not skip a second comment in the same millisecond", async () => {
    const c = await newCase();
    const ins = (id: string, at: number) =>
      env.DB.prepare(
        "INSERT INTO comments (id, case_id, round_seq, commit_id, body, author_kind, author_name, created_at) VALUES (?, ?, 1, 'c', 'hi', 'guest', 'Ada', ?)",
      ).bind(id, c.id, at).run();
    await ins("bbb", 1000);
    await ins("aaa", 1000);
    await ins("ccc", 2000);
    const get = async (q: string) =>
      ((await (await call(`/api/cases/${c.id}/comments?${q}`, { headers: c.auth })).json()) as { comments: { id: string }[] }).comments.map((x) => x.id);
    expect(await get("since=0")).toEqual(["aaa", "bbb", "ccc"]);
    // The old cursor (time only) is strict, as before.
    expect(await get("since=1000")).toEqual(["ccc"]);
    // The new cursor continues after the last comment it saw.
    expect(await get("since=1000&after=aaa")).toEqual(["bbb", "ccc"]);
    expect(await get("since=1000&after=bbb")).toEqual(["ccc"]);
    expect(await get("since=2000&after=ccc")).toEqual([]);
  });
});

describe("the round label (G23)", () => {
  it("shows Round <seq> alone when the label repeats it", async () => {
    const page = await (await call(`/d/${(await newCase()).id}`)).text();
    expect(page).toContain('r.label!=="Round "+r.seq');
  });
});
