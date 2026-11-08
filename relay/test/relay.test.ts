import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import worker, { type Env } from "../src/index";
import { sha256Hex } from "../src/auth";
import { scaleBox } from "../src/box";
import { newUser } from "./helpers";

const E = env as unknown as Env;
const APP = E.APP_ORIGIN;
const CONTENT = E.CONTENT_ORIGIN;

function call(path: string, init: RequestInit & { origin?: string } = {}): Promise<Response> {
  const headers = new Headers(init.headers);
  if (init.body && !headers.has("content-type")) headers.set("content-type", "application/json");
  return worker.fetch(new Request((init.origin ?? APP) + path, { ...init, headers }), E);
}

const fromPage = (cookie?: string) => ({ origin: APP, ...(cookie ? { cookie } : {}) });

function b64(s: string) {
  return btoa(s);
}

// A case now needs an account: a fresh user signs in and connects a Mac.
async function newCase(mode: "link" | "emails" = "link", emails: string[] = []) {
  const key = "owner-key-" + crypto.randomUUID();
  const me = await newUser(call, E);
  const res = await call("/api/cases", {
    method: "POST",
    headers: me.bearer,
    body: JSON.stringify({ title: "Pricing page: flagged first?", mode, emails, owner_key_hash: await sha256Hex(key) }),
  });
  expect(res.status).toBe(201);
  const c = (await res.json()) as { id: string; url: string; store: string };
  return { ...c, key, me, auth: { authorization: `Bearer ${key}` } };
}

async function addRound(c: Awaited<ReturnType<typeof newCase>>, html = "<h1>Flagged first</h1><p>The scraper fills the page cache every hour.</p>") {
  const res = await call(`/api/cases/${c.id}/rounds`, {
    method: "POST",
    headers: c.auth,
    body: JSON.stringify({
      label: "Two layouts",
      entry: "index.html",
      files: [
        { path: "index.html", body_base64: b64(html) },
        { path: "style.css", body_base64: b64("h1{color:red}") },
      ],
    }),
  });
  expect(res.status).toBe(201);
  return (await res.json()) as { seq: number; commit: string };
}

function cookieOf(res: Response) {
  return (res.headers.get("set-cookie") ?? "").split(";")[0];
}

describe("cases and rounds", () => {
  it("creates a case with the owner key hash only, and refuses a bad hash", async () => {
    const c = await newCase();
    expect(c.url).toBe(`${APP}/d/${c.id}`);
    expect(c.store).toBe("d1");
    const row = await E.DB.prepare("SELECT owner_key_hash FROM cases WHERE id = ?").bind(c.id).first<{ owner_key_hash: string }>();
    expect(row!.owner_key_hash).not.toContain("owner-key");
    const bad = await call("/api/cases", { method: "POST", headers: c.me.bearer, body: JSON.stringify({ title: "x", owner_key_hash: "nope" }) });
    expect(bad.status).toBe(400);
  });

  it("adds rounds only for the owner, and the same files give the same round", async () => {
    const c = await newCase();
    const denied = await call(`/api/cases/${c.id}/rounds`, { method: "POST", headers: { authorization: "Bearer wrong" }, body: "{}" });
    expect(denied.status).toBe(401);
    const r1 = await addRound(c);
    expect(r1.seq).toBe(1);
    expect(r1.commit).toMatch(/^[0-9a-f]{40}$/);
    const again = await call(`/api/cases/${c.id}/rounds`, {
      method: "POST",
      headers: c.auth,
      body: JSON.stringify({ label: "Same", entry: "index.html", files: [
        { path: "index.html", body_base64: b64("<h1>Flagged first</h1><p>The scraper fills the page cache every hour.</p>") },
        { path: "style.css", body_base64: b64("h1{color:red}") },
      ] }),
    });
    expect(((await again.json()) as { seq: number }).seq).toBe(1);
    const r2 = await addRound(c, "<h1>Newest first</h1>");
    expect(r2.seq).toBe(2);
  });

  it("refuses a path that leaves the round", async () => {
    const c = await newCase();
    const res = await call(`/api/cases/${c.id}/rounds`, {
      method: "POST",
      headers: c.auth,
      body: JSON.stringify({ label: "x", entry: "../secret", files: [{ path: "index.html", body_base64: b64("x") }] }),
    });
    expect(res.status).toBe(400);
  });

  it("says that local dev has no Git push", async () => {
    const c = await newCase();
    const res = await call(`/api/cases/${c.id}/push-access`, { method: "POST", headers: c.auth });
    expect(res.status).toBe(409);
  });
});

describe("anyone with the link", () => {
  it("lets anyone read, and asks for a name before a comment", async () => {
    const c = await newCase();
    const round = await addRound(c);
    const state = (await (await call(`/api/cases/${c.id}/state`)).json()) as { viewer: null; rounds: { src: string }[] };
    expect(state.viewer).toBeNull();
    expect(state.rounds[0].src.startsWith(`${CONTENT}/t/`)).toBe(true);

    const anon = await call(`/api/cases/${c.id}/comments`, { method: "POST", headers: fromPage(), body: JSON.stringify({ round_seq: 1, body: "hi" }) });
    expect(anon.status).toBe(401);

    const join = await call(`/api/cases/${c.id}/guest`, { method: "POST", headers: fromPage(), body: JSON.stringify({ name: "Ada" }) });
    expect(join.status).toBe(200);
    const cookie = cookieOf(join);
    expect(join.headers.get("set-cookie")).toContain("HttpOnly");

    const post = await call(`/api/cases/${c.id}/comments`, {
      method: "POST",
      headers: fromPage(cookie),
      body: JSON.stringify({ round_seq: 1, body: "Why every hour?", quote: "every hour", prefix: "fills the page cache ", suffix: "." }),
    });
    expect(post.status).toBe(201);

    // The owner reads what the team said, with the anchor, as the daemon will.
    const owner = (await (await call(`/api/cases/${c.id}/comments`, { headers: c.auth })).json()) as {
      comments: { author_name: string; author_kind: string; quote: string; prefix: string; commit_id: string }[];
    };
    expect(owner.comments).toHaveLength(1);
    expect(owner.comments[0]).toMatchObject({ author_name: "Ada", author_kind: "guest", quote: "every hour", prefix: "fills the page cache ", commit_id: round.commit });
    const notOwner = await call(`/api/cases/${c.id}/comments`, { headers: { cookie } });
    expect(notOwner.status).toBe(401);
  });

  it("keeps a comment on an area of the page, and refuses a bad area", async () => {
    const c = await newCase();
    await addRound(c);
    const cookie = cookieOf(await call(`/api/cases/${c.id}/guest`, { method: "POST", headers: fromPage(), body: JSON.stringify({ name: "Ada" }) }));
    const box = { x: 40.4, y: 120, w: 320, h: 180, vw: 900, near: "  Pricing card  " };
    const post = await call(`/api/cases/${c.id}/comments`, { method: "POST", headers: fromPage(cookie), body: JSON.stringify({ round_seq: 1, body: "Too much air here", box }) });
    expect(post.status).toBe(201);
    const want = { x: 40, y: 120, w: 320, h: 180, vw: 900, near: "Pricing card" };
    const owner = (await (await call(`/api/cases/${c.id}/comments`, { headers: c.auth })).json()) as { comments: { box: unknown; quote: unknown }[] };
    expect(owner.comments[0]).toMatchObject({ box: want, quote: null });
    const state = (await (await call(`/api/cases/${c.id}/state`)).json()) as { comments: { box: unknown }[] };
    expect(state.comments[0].box).toEqual(want);

    for (const bad of [{ ...box, w: "320" }, { ...box, x: -1 }, { ...box, h: 1 }, { ...box, y: 1e9 }, "box"]) {
      const r = await call(`/api/cases/${c.id}/comments`, { method: "POST", headers: fromPage(cookie), body: JSON.stringify({ round_seq: 1, body: "x", box: bad }) });
      expect(r.status).toBe(400);
    }
  });

  it("refuses a cookie write from another origin", async () => {
    const c = await newCase();
    await addRound(c);
    const join = await call(`/api/cases/${c.id}/guest`, { method: "POST", headers: fromPage(), body: JSON.stringify({ name: "Ada" }) });
    const evil = await call(`/api/cases/${c.id}/comments`, {
      method: "POST",
      headers: { origin: CONTENT, cookie: cookieOf(join) },
      body: JSON.stringify({ round_seq: 1, body: "x" }),
    });
    expect(evil.status).toBe(403);
  });
});

describe("content origin", () => {
  it("serves round files with a valid ticket only, sandboxed, with relative links kept", async () => {
    const c = await newCase();
    await addRound(c);
    const { rounds } = (await (await call(`/api/cases/${c.id}/state`)).json()) as { rounds: { src: string }[] };
    const src = rounds[0].src;
    const page = await call(src.slice(CONTENT.length), { origin: CONTENT });
    expect(page.status).toBe(200);
    const csp = page.headers.get("content-security-policy")!;
    expect(csp).toContain("sandbox allow-scripts");
    expect(csp).toContain("connect-src 'none'");
    expect(csp).toContain(`frame-ancestors ${APP}`);
    const html = await page.text();
    expect(html).toContain("Flagged first");
    expect(html).toContain("waggle-selection");

    const css = await call(src.slice(CONTENT.length).replace("index.html", "style.css"), { origin: CONTENT });
    expect(css.headers.get("content-type")).toContain("text/css");

    const forged = src.slice(CONTENT.length).replace(/\/t\/(\d+)\.[^/]+\//, "/t/$1.AAAA/");
    expect((await call(forged, { origin: CONTENT })).status).toBe(403);

    // The app's API is not on the content origin.
    expect((await call(`/api/cases/${c.id}/state`, { origin: CONTENT })).status).toBe(404);
  });

  it("serves the page with a nonce CSP that only frames the content origin", async () => {
    const c = await newCase();
    const res = await call(`/d/${c.id}`);
    expect(res.status).toBe(200);
    const csp = res.headers.get("content-security-policy")!;
    expect(csp).toMatch(/script-src 'nonce-[A-Za-z0-9_-]+'/);
    expect(csp).toContain(`frame-src ${CONTENT}`);
    expect(res.headers.get("x-frame-options")).toBe("DENY");
    expect((await call("/d/nosuchcase")).status).toBe(404);
  });

  it("puts the artifact first: ask bar, latest round, earlier rounds menu, Expand", async () => {
    const c = await newCase();
    const html = await (await call(`/d/${c.id}`)).text();
    for (const copy of [
      "askbar", "I recommend ", "Show", "Hide", "Decided: ", " options",
      "Latest", "Earlier rounds (", "Rounds, newest first", "Today, ", "Yesterday, ",
      "You are viewing round ", "Comments here go to round ", "Go to latest",
      "Comment on an area", "Open in new tab", "noopener", "Expand", "Exit", "Esc", "Comments \"+",
      "waggle-ask:", "waggle-fold:", "position:fixed;inset:0", "width:min(380px,100vw)",
    ]) expect(html, copy).toContain(copy);
    expect(html).toMatch(/nonce="[A-Za-z0-9_-]+"/);
    expect(html).not.toContain("\u2014");
  });

  it("deletes a case and everything in it for the owner", async () => {
    const c = await newCase();
    await addRound(c);
    expect((await call(`/api/cases/${c.id}`, { method: "DELETE", headers: { authorization: "Bearer x" } })).status).toBe(401);
    expect((await call(`/api/cases/${c.id}`, { method: "DELETE", headers: c.auth })).status).toBe(200);
    const left = await E.DB.prepare("SELECT COUNT(*) AS n FROM round_files WHERE case_id = ?").bind(c.id).first<{ n: number }>();
    expect(left!.n).toBe(0);
  });
});

describe("the ask", () => {
  const ask = {
    need: "Pick the layout.",
    why: "Both work.",
    recommendation: "Go with B.",
    options: [
      { title: "A", label: "Flagged first" },
      { title: "B", label: "Newest first", recommended: true },
    ],
  };
  const create = async (extra: Record<string, unknown>) =>
    call("/api/cases", { method: "POST", headers: (await newUser(call, E)).bearer, body: JSON.stringify({ title: "Q", owner_key_hash: await sha256Hex("k"), ...extra }) });
  const stateOf = async (id: string) => (await (await call(`/api/cases/${id}/state`)).json()) as { ask: unknown };

  it("stores the ask with the case, returns it in the state, and shows null without one", async () => {
    const res = await create({ ask });
    expect(res.status).toBe(201);
    const { id } = (await res.json()) as { id: string };
    expect((await stateOf(id)).ask).toEqual(ask);
    const plain = (await (await create({})).json()) as { id: string };
    expect((await stateOf(plain.id)).ask).toBeNull();
  });

  it("takes a newer ask with a round, and keeps the old one when a round has none", async () => {
    const c = await newCase();
    await addRound(c);
    const send = (extra: Record<string, unknown>, html: string) =>
      call(`/api/cases/${c.id}/rounds`, {
        method: "POST",
        headers: c.auth,
        body: JSON.stringify({ label: "L", entry: "index.html", files: [{ path: "index.html", body_base64: b64(html) }], ...extra }),
      });
    expect((await send({ ask }, "<p>two</p>")).status).toBe(201);
    expect((await stateOf(c.id)).ask).toEqual(ask);
    expect((await send({}, "<p>three</p>")).status).toBe(201);
    expect((await stateOf(c.id)).ask).toEqual(ask);
    expect((await send({ ask: { need: "Newer" } }, "<p>four</p>")).status).toBe(201);
    expect((await stateOf(c.id)).ask).toEqual({ need: "Newer" });
  });

  it("refuses a bad ask with 400", async () => {
    const opt = { title: "A", label: "a" };
    const bad: unknown[] = [
      "text",
      [],
      {},
      { need: "" },
      { need: 5 },
      { need: "x".repeat(601) },
      { need: "x", why: "y".repeat(1001) },
      { need: "x", recommendation: "r".repeat(301) },
      { need: "x", options: "A" },
      { need: "x", options: Array(13).fill(opt) },
      { need: "x", options: [{ title: "t".repeat(81), label: "a" }] },
      { need: "x", options: [{ title: "A", label: "l".repeat(601) }] },
      { need: "x", options: [{ title: "A" }] },
      { need: "x", options: [{ ...opt, recommended: "yes" }] },
      { need: "x", options: ["A"] },
    ];
    for (const a of bad) expect((await create({ ask: a })).status, JSON.stringify(a).slice(0, 60)).toBe(400);
    const c = await newCase();
    const r = await call(`/api/cases/${c.id}/rounds`, {
      method: "POST",
      headers: c.auth,
      body: JSON.stringify({ label: "L", entry: "index.html", files: [{ path: "index.html", body_base64: b64("x") }], ask: { need: "" } }),
    });
    expect(r.status).toBe(400);
  });

  it("keeps markup as text: the page builds the ask with textContent only", async () => {
    const res = await call(`/d/${(await newCase()).id}`);
    const html = await res.text();
    expect(html).toContain("function askBlock");
    const block = html.slice(html.indexOf("function askBlock"), html.indexOf("// --- the rounds toolbar"));
    expect(block).not.toMatch(/innerHTML|insertAdjacentHTML|outerHTML/);
  });
});

describe("the page and the frame", () => {
  it("scales an area by the frame width and keeps y and h", () => {
    const b = { x: 100, y: 40, w: 200, h: 50, vw: 1000 };
    expect(scaleBox(b, 500)).toEqual({ x: 50, y: 40, w: 100, h: 50 });
    expect(scaleBox(b, 1000)).toEqual({ x: 100, y: 40, w: 200, h: 50 });
    expect(scaleBox(b, 2000)).toEqual({ x: 200, y: 40, w: 400, h: 50 });
    expect(scaleBox({ x: 1, y: 2, w: 3, h: 4 }, 500)).toEqual({ x: 1, y: 2, w: 3, h: 4 });
    expect(scaleBox({ ...b, vw: 0 }, 500).x).toBe(100);
    expect(scaleBox(b, 0).x).toBe(100);
  });

  it("embeds a plain scaleBox in the frame script", async () => {
    const c = await newCase();
    await addRound(c);
    const { rounds } = (await (await call(`/api/cases/${c.id}/state`)).json()) as { rounds: { src: string }[] };
    const html = await (await call(rounds[0].src.slice(CONTENT.length), { origin: CONTENT })).text();
    expect(html).toContain("function scaleBox");
    expect(html).not.toContain("__name");
    expect(html).toContain("waggle-clear-quote");
  });

  it("serves the two fonts from the app origin, and the CSP allows only that", async () => {
    for (const name of ["inter-tight", "jetbrains-mono"]) {
      const res = await call(`/fonts/${name}.woff2`);
      expect(res.status).toBe(200);
      expect(res.headers.get("content-type")).toBe("font/woff2");
      const bytes = new Uint8Array(await res.arrayBuffer());
      expect(String.fromCharCode(...bytes.slice(0, 4))).toBe("wOF2");
    }
    expect((await call("/fonts/nope.woff2")).status).toBe(404);
    const c = await newCase();
    const page = await call(`/d/${c.id}`);
    expect(page.headers.get("content-security-policy")).toContain("font-src 'self'");
    expect(await page.text()).toContain("/fonts/inter-tight.woff2");
  });
});
