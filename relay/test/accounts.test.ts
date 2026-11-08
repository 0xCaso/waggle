import { env } from "cloudflare:workers";
import { afterEach, describe, expect, it, vi } from "vitest";
import { cleanup } from "../src/accounts";
import { sha256Hex } from "../src/auth";
import worker, { type Env } from "../src/index";
import { cookieOf, ipHeader, lastMail, linkIn, newUser, webSignIn, type Call } from "./helpers";

// Accounts (WAG-392): email link, Google, the Mac connect flow, ownership, invites, limits and cleanup.

const E = env as unknown as Env;
const APP = E.APP_ORIGIN;

function callFor(e: Env): Call {
  return (path, init = {}) => {
    const headers = new Headers(init.headers);
    if (init.body && !headers.has("content-type")) headers.set("content-type", "application/json");
    return worker.fetch(new Request((init.origin ?? e.APP_ORIGIN) + path, { ...init, headers }), e);
  };
}
const call = callFor(E);
const page = (cookie?: string) => ({ origin: APP, ...(cookie ? { cookie } : {}) });
const rnd = () => crypto.randomUUID().slice(0, 8);

async function share(me: { bearer: Record<string, string> }, extra: Record<string, unknown> = {}, e: Env = E) {
  const key = "key-" + crypto.randomUUID();
  const res = await callFor(e)("/api/cases", {
    method: "POST",
    headers: me.bearer,
    body: JSON.stringify({ title: 'Pricing "page"', mode: "link", owner_key_hash: await sha256Hex(key), ...extra }),
  });
  return { res, key, keyAuth: { authorization: `Bearer ${key}` }, body: res.ok ? ((await res.json()) as { id: string; url: string }) : null };
}

async function addRound(id: string, auth: Record<string, string>) {
  const r = await call(`/api/cases/${id}/rounds`, {
    method: "POST",
    headers: auth,
    body: JSON.stringify({ label: "L", entry: "index.html", files: [{ path: "index.html", body_base64: btoa("<h1>Hi</h1>") }] }),
  });
  expect(r.status).toBe(201);
}

afterEach(() => vi.restoreAllMocks());

describe("email sign-in", () => {
  it("sends a one-time link to the dev outbox, in text and html, and gives the same answer for any address", async () => {
    const known = `known-${rnd()}@example.com`;
    await webSignIn(call, E, known);
    const logs: string[] = [];
    vi.spyOn(console, "log").mockImplementation((...a: unknown[]) => void logs.push(a.join(" ")));
    const a = await call("/api/auth/email", { method: "POST", headers: { ...page(), ...ipHeader() }, body: JSON.stringify({ email: known }) });
    const b = await call("/api/auth/email", { method: "POST", headers: { ...page(), ...ipHeader() }, body: JSON.stringify({ email: `new-${rnd()}@example.com` }) });
    expect(a.status).toBe(202);
    expect(b.status).toBe(202);
    expect(await a.json()).toEqual(await b.json());
    const mail = await lastMail(E, known);
    expect(mail.subject).toBe("Your Waggle sign-in link");
    expect(mail.body_text).toContain(`${APP}/signin/`);
    expect(mail.body_html).toContain("<a href=");
    expect(mail.body_text).not.toMatch(/account|list/i);
    // In dev the mail is logged too.
    expect(logs.some((l) => l.includes("[dev mail]"))).toBe(true);
  });

  it("sends through the EMAIL binding when there is one, from Waggle <signin@waggle.so>, and never logs the link", async () => {
    const sent: unknown[] = [];
    const prod = { ...E, DEV_MODE: undefined, EMAIL: { send: async (m: unknown) => void sent.push(m) } } as unknown as Env;
    const logs: string[] = [];
    vi.spyOn(console, "log").mockImplementation((...a: unknown[]) => void logs.push(a.join(" ")));
    vi.spyOn(console, "error").mockImplementation((...a: unknown[]) => void logs.push(a.join(" ")));
    const email = `bind-${rnd()}@example.com`;
    const res = await callFor(prod)("/api/auth/email", { method: "POST", headers: { ...page(), ...ipHeader() }, body: JSON.stringify({ email }) });
    expect(res.status).toBe(202);
    expect(sent).toHaveLength(1);
    const m = sent[0] as { from: { name: string; email: string }; to: string; text: string; html: string };
    expect(m.from).toEqual({ name: "Waggle", email: "signin@waggle.so" });
    expect(m.to).toBe(email);
    expect(m.text).toContain("/signin/");
    expect(m.html).toContain("/signin/");
    expect(logs.join("\n")).not.toContain("/signin/");
    const row = await E.DB.prepare("SELECT COUNT(*) AS n FROM dev_outbox WHERE to_email = ?").bind(email).first<{ n: number }>();
    expect(row!.n).toBe(0);
  });

  it("a self-hosted relay sends from its own MAIL_FROM address", async () => {
    const sent: unknown[] = [];
    const own = { ...E, DEV_MODE: undefined, MAIL_FROM: "signin@relay.example.com", EMAIL: { send: async (m: unknown) => void sent.push(m) } } as unknown as Env;
    const res = await callFor(own)("/api/auth/email", { method: "POST", headers: { ...page(), ...ipHeader() }, body: JSON.stringify({ email: `own-${rnd()}@example.com` }) });
    expect(res.status).toBe(202);
    expect((sent[0] as { from: unknown }).from).toEqual({ name: "Waggle", email: "signin@relay.example.com" });
  });

  it("does not log a link or record an outbox row in production when the binding is missing", async () => {
    const prod = { ...E, DEV_MODE: undefined } as unknown as Env;
    const logs: string[] = [];
    vi.spyOn(console, "log").mockImplementation((...a: unknown[]) => void logs.push(a.join(" ")));
    vi.spyOn(console, "error").mockImplementation((...a: unknown[]) => void logs.push(a.join(" ")));
    const email = `nobind-${rnd()}@example.com`;
    const res = await callFor(prod)("/api/auth/email", { method: "POST", headers: { ...page(), ...ipHeader() }, body: JSON.stringify({ email }) });
    expect(res.status).toBe(202);
    expect(logs.join("\n")).not.toContain("/signin/");
    expect((await E.DB.prepare("SELECT COUNT(*) AS n FROM dev_outbox WHERE to_email = ?").bind(email).first<{ n: number }>())!.n).toBe(0);
    // And the outbox route does not exist there.
    expect((await callFor(prod)("/api/dev/outbox")).status).toBe(404);
  });

  it("opens a page that signs in on POST, once, with a safe cookie, and goes to next", async () => {
    const email = `Ann-${rnd()}@Example.com`;
    await call("/api/auth/email", { method: "POST", headers: { ...page(), ...ipHeader() }, body: JSON.stringify({ email, next: "/d/abc123" }) });
    const link = linkIn((await lastMail(E, email.toLowerCase())).body_text).slice(APP.length);
    // A scanner that only fetches the link signs nobody in.
    const get = await call(link);
    expect(get.status).toBe(200);
    expect(await get.text()).toContain('method="post"');
    expect(get.headers.get("set-cookie")).toBeNull();
    // A cross-site post is refused.
    expect((await call(link, { method: "POST", headers: { origin: "https://evil.example" } })).status).toBe(403);
    const post = await call(link, { method: "POST", headers: page() });
    expect(post.status).toBe(303);
    expect(post.headers.get("location")).toBe("/d/abc123");
    const cookie = post.headers.get("set-cookie")!;
    expect(cookie).toContain("HttpOnly");
    expect(cookie).toContain("SameSite=Lax");
    expect(cookie).toContain(`Max-Age=${30 * 86400}`);
    expect(cookie).toContain("Path=/");
    expect((await call(link, { method: "POST", headers: page() })).status).toBe(410);
    // The email is stored in lower case and the token only as a hash.
    const user = await E.DB.prepare("SELECT email FROM users WHERE email = ?").bind(email.toLowerCase()).first();
    expect(user).toBeTruthy();
    const token = link.split("/").pop()!;
    const raw = await E.DB.prepare("SELECT COUNT(*) AS n FROM signin_links WHERE token_hash = ?").bind(token).first<{ n: number }>();
    expect(raw!.n).toBe(0);
  });

  it("sets the Secure flag on the real https address", async () => {
    const https = { ...E, APP_ORIGIN: "https://app.waggle.so", DEV_MODE: "1" } as Env;
    const c = callFor(https);
    const email = `sec-${rnd()}@example.com`;
    await c("/api/auth/email", { method: "POST", headers: { origin: https.APP_ORIGIN, ...ipHeader() }, body: JSON.stringify({ email }) });
    const link = linkIn((await lastMail(E, email)).body_text);
    const res = await c(new URL(link).pathname, { method: "POST", headers: { origin: https.APP_ORIGIN } });
    expect(res.headers.get("set-cookie")).toContain("Secure");
  });

  it("refuses a next that leaves the site", async () => {
    for (const next of ["https://evil.example/x", "//evil.example", "/\\evil.example", "javascript:alert(1)", "/ok\nSet-Cookie: a=b", "http://localhost:8787.evil.example/"]) {
      const email = `next-${rnd()}@example.com`;
      await call("/api/auth/email", { method: "POST", headers: { ...page(), ...ipHeader() }, body: JSON.stringify({ email, next }) });
      const link = linkIn((await lastMail(E, email)).body_text).slice(APP.length);
      const res = await call(link, { method: "POST", headers: page() });
      expect(res.headers.get("location"), next).toBe("/");
    }
    const email = `next-${rnd()}@example.com`;
    await call("/api/auth/email", { method: "POST", headers: { ...page(), ...ipHeader() }, body: JSON.stringify({ email, next: "/connect?code=ABCD-2345" }) });
    const res = await call(linkIn((await lastMail(E, email)).body_text).slice(APP.length), { method: "POST", headers: page() });
    expect(res.headers.get("location")).toBe("/connect?code=ABCD-2345");
  });

  it("refuses a bad email and a cross-site request", async () => {
    expect((await call("/api/auth/email", { method: "POST", headers: { ...page(), ...ipHeader() }, body: JSON.stringify({ email: "nope" }) })).status).toBe(400);
    expect((await call("/api/auth/email", { method: "POST", headers: { origin: "https://evil.example", ...ipHeader() }, body: JSON.stringify({ email: "a@b.co" }) })).status).toBe(403);
  });

  it("signs out", async () => {
    const cookie = await webSignIn(call, E, `out-${rnd()}@example.com`);
    expect(((await (await call("/api/auth/session", { headers: { cookie } })).json()) as { signed_in: boolean }).signed_in).toBe(true);
    const out = await call("/api/auth/signout", { method: "POST", headers: page(cookie) });
    expect(out.headers.get("set-cookie")).toContain("Max-Age=0");
    expect(((await (await call("/api/auth/session", { headers: { cookie } })).json()) as { signed_in: boolean }).signed_in).toBe(false);
  });
});

describe("Google sign-in", () => {
  const G = { ...E, GOOGLE_CLIENT_ID: "test-client-id", GOOGLE_CLIENT_SECRET: "test-client-secret", GOOGLE_TOKEN_URL: "http://127.0.0.1:9/token", GOOGLE_AUTH_URL: "http://127.0.0.1:9/auth" } as Env;
  const gcall = callFor(G);

  function idToken(claims: Record<string, unknown>) {
    const enc = (o: unknown) => btoa(JSON.stringify(o)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
    return `${enc({ alg: "none" })}.${enc({ iss: "https://accounts.google.com", aud: "test-client-id", exp: Math.floor(Date.now() / 1000) + 600, ...claims })}.x`;
  }

  async function start(next = "/d/xyz") {
    const res = await gcall(`/api/auth/google/start?next=${encodeURIComponent(next)}`);
    expect(res.status).toBe(303);
    const loc = new URL(res.headers.get("location")!);
    return { loc, state: loc.searchParams.get("state")!, cookie: cookieOf(res, "wr_oauth") };
  }

  function fakeGoogle(claims: Record<string, unknown>, ok = true) {
    const seen: { url: string; body: URLSearchParams }[] = [];
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
      seen.push({ url: String(input), body: new URLSearchParams(String((init as RequestInit).body)) });
      return ok ? Response.json({ id_token: idToken(claims) }) : new Response("no", { status: 400 });
    });
    return seen;
  }

  it("starts the code flow with state, PKCE and the openid email scope", async () => {
    const { loc, state, cookie } = await start();
    expect(loc.origin + loc.pathname).toBe("http://127.0.0.1:9/auth");
    expect(loc.searchParams.get("client_id")).toBe("test-client-id");
    expect(loc.searchParams.get("redirect_uri")).toBe(`${APP}/api/auth/google/callback`);
    expect(loc.searchParams.get("scope")).toBe("openid email");
    expect(loc.searchParams.get("response_type")).toBe("code");
    expect(loc.searchParams.get("code_challenge_method")).toBe("S256");
    expect(loc.searchParams.get("code_challenge")).toBeTruthy();
    expect(cookie).toBe(`wr_oauth=${state}`);
  });

  it("signs in a verified address, exchanges the code on the Worker with the PKCE verifier, and joins the email user", async () => {
    const email = `gina-${rnd()}@example.com`;
    const before = await webSignIn(call, E, email);
    expect(before).toBeTruthy();
    const { loc, state, cookie } = await start("/d/xyz");
    const seen = fakeGoogle({ email, email_verified: true, sub: "sub-" + rnd(), name: "Gina" });
    const res = await gcall(`/api/auth/google/callback?code=abc&state=${state}`, { headers: { cookie } });
    expect(res.status).toBe(303);
    expect(res.headers.get("location")).toBe("/d/xyz");
    expect(cookieOf(res, "wr_session")).toBeTruthy();
    expect(seen[0].url).toBe("http://127.0.0.1:9/token");
    expect(seen[0].body.get("client_secret")).toBe("test-client-secret");
    expect(seen[0].body.get("code")).toBe("abc");
    // The challenge Google got matches the verifier the Worker sent.
    const verifier = seen[0].body.get("code_verifier")!;
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
    const challenge = btoa(String.fromCharCode(...new Uint8Array(digest))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
    expect(challenge).toBe(loc.searchParams.get("code_challenge"));
    // The same email is the same user.
    const rows = await E.DB.prepare("SELECT COUNT(*) AS n, MAX(google_sub) AS sub FROM users WHERE email = ?").bind(email).first<{ n: number; sub: string | null }>();
    expect(rows!.n).toBe(1);
    expect(rows!.sub).toMatch(/^sub-/);
  });

  it("F8: matches by google_sub first, and refuses another sub on a linked email", async () => {
    const email = `ann-${rnd()}@example.com`;
    const sub1 = "sub-" + rnd();
    const login = async (claims: Record<string, unknown>) => {
      const s = await start();
      fakeGoogle(claims);
      const res = await gcall(`/api/auth/google/callback?code=a&state=${s.state}`, { headers: { cookie: s.cookie } });
      vi.restoreAllMocks();
      return res;
    };
    expect((await login({ email, email_verified: true, sub: sub1 })).status).toBe(303);
    const first = await E.DB.prepare("SELECT id FROM users WHERE email = ?").bind(email).first<{ id: string }>();
    // The same person again: the same account.
    expect((await login({ email, email_verified: true, sub: sub1 })).status).toBe(303);
    // The same sub with a new email still finds the account.
    const moved = await login({ email: `ann2-${rnd()}@example.com`, email_verified: true, sub: sub1 });
    expect(moved.status).toBe(303);
    const sess = await E.DB.prepare("SELECT user_id FROM web_sessions ORDER BY created_at DESC, rowid DESC LIMIT 1").first<{ user_id: string }>();
    expect(sess!.user_id).toBe(first!.id);
    // The same email with another sub does not take over the account.
    const before = (await E.DB.prepare("SELECT COUNT(*) AS n FROM web_sessions").first<{ n: number }>())!.n;
    const taken = await login({ email, email_verified: true, sub: "sub-other-" + rnd() });
    expect(taken.status).toBe(400);
    expect(taken.headers.get("set-cookie") ?? "").not.toContain("wr_session=");
    expect(await taken.text()).toContain("different Google account");
    expect((await E.DB.prepare("SELECT COUNT(*) AS n FROM web_sessions").first<{ n: number }>())!.n).toBe(before);
    expect((await E.DB.prepare("SELECT google_sub FROM users WHERE id = ?").bind(first!.id).first<{ google_sub: string }>())!.google_sub).toBe(sub1);
  });

  it("refuses an unverified address, a wrong state, a missing cookie, a reused state and a wrong audience", async () => {
    const email = `bad-${rnd()}@example.com`;
    let s = await start();
    fakeGoogle({ email, email_verified: false, sub: "s1" });
    let res = await gcall(`/api/auth/google/callback?code=a&state=${s.state}`, { headers: { cookie: s.cookie } });
    expect(res.status).toBe(400);
    expect(res.headers.get("set-cookie")).toBeNull();
    expect(await E.DB.prepare("SELECT 1 FROM users WHERE email = ?").bind(email).first()).toBeNull();
    vi.restoreAllMocks();

    s = await start();
    fakeGoogle({ email, email_verified: true, sub: "s2" });
    expect((await gcall(`/api/auth/google/callback?code=a&state=other`, { headers: { cookie: s.cookie } })).status).toBe(400);
    expect((await gcall(`/api/auth/google/callback?code=a&state=${s.state}`)).status).toBe(400);
    expect((await gcall(`/api/auth/google/callback?code=a&state=${s.state}`, { headers: { cookie: s.cookie } })).status).toBe(303);
    expect((await gcall(`/api/auth/google/callback?code=a&state=${s.state}`, { headers: { cookie: s.cookie } })).status).toBe(400);
    vi.restoreAllMocks();

    s = await start();
    fakeGoogle({ email, email_verified: true, sub: "s3", aud: "someone-else" });
    res = await gcall(`/api/auth/google/callback?code=a&state=${s.state}`, { headers: { cookie: s.cookie } });
    expect(res.status).toBe(400);
  });

  it("hides the Google button and the routes when the two secrets are missing", async () => {
    expect((await call("/api/auth/google/start")).status).toBe(404);
    expect(await (await call("/signin")).text()).not.toContain("Continue with Google");
    expect(await (await gcall("/signin")).text()).toContain("Continue with Google");
    expect(await (await call("/api/auth/session")).json()).toMatchObject({ google: false });
    const half = { ...E, GOOGLE_CLIENT_ID: "x" } as Env;
    expect((await callFor(half)("/api/auth/google/start")).status).toBe(404);
  });

  it("ignores the endpoint overrides outside dev mode", async () => {
    const prod = { ...G, DEV_MODE: undefined } as unknown as Env;
    const res = await callFor(prod)("/api/auth/google/start");
    expect(new URL(res.headers.get("location")!).origin).toBe("https://accounts.google.com");
    const state = new URL(res.headers.get("location")!).searchParams.get("state")!;
    const seen = fakeGoogle({ email: `p-${rnd()}@example.com`, email_verified: true, sub: "p1" });
    await callFor(prod)(`/api/auth/google/callback?code=a&state=${state}`, { headers: { cookie: `wr_oauth=${state}` } });
    expect(seen[0].url).toBe("https://oauth2.googleapis.com/token");
  });
});

describe("connect a Mac (device flow)", () => {
  it("gives a code, polls pending, then a device token once, kept only as a hash", async () => {
    const cookie = await webSignIn(call, E, `mac-${rnd()}@example.com`);
    const made = await call("/api/auth/device", { method: "POST", headers: ipHeader(), body: JSON.stringify({ label: "Ada's MacBook" }) });
    expect(made.status).toBe(201);
    const d = (await made.json()) as { device_code: string; user_code: string; verify_url: string; expires_in: number };
    expect(d.user_code).toMatch(/^[A-Z2-9]{4}-[A-Z2-9]{4}$/);
    expect(d.verify_url).toBe(`${APP}/connect?code=${d.user_code}`);
    expect(d.expires_in).toBe(600);
    const poll = () => call("/api/auth/device/poll", { method: "POST", body: JSON.stringify({ device_code: d.device_code }) });
    expect(await (await poll()).json()).toEqual({ status: "pending" });

    // The connect page asks for sign-in first, then shows the Mac name.
    const anon = await call(`/connect?code=${d.user_code}`);
    expect(anon.status).toBe(303);
    expect(anon.headers.get("location")).toBe(`/signin?next=${encodeURIComponent(`/connect?code=${d.user_code}`)}`);
    const confirm = await call(`/connect?code=${d.user_code}`, { headers: { cookie } });
    expect(confirm.status).toBe(200);
    const html = await confirm.text();
    expect(html).toContain("Connect Ada&#39;s MacBook".replace("&#39;", "'") + " to your Waggle account?");
    // WAG-396: the real mark and tab icon, and a result step with the way back to the app.
    expect(html).toContain('<svg class="mark"');
    expect(html).toContain('rel="icon"');
    expect(html).toContain('<div id="done" class="stack done" hidden>');
    expect(html).toContain('href="waggle://">Back to Waggle</a>');
    expect(html).not.toContain("\u2014");
    // Only a signed-in person on the app's own page can approve.
    const body = JSON.stringify({ user_code: d.user_code });
    expect((await call("/api/auth/device/approve", { method: "POST", headers: { origin: APP, ...ipHeader() }, body })).status).toBe(401);
    expect((await call("/api/auth/device/approve", { method: "POST", headers: { origin: "https://evil.example", cookie }, body })).status).toBe(403);
    expect((await call("/api/auth/device/approve", { method: "POST", headers: { origin: APP, cookie, ...ipHeader() }, body })).status).toBe(200);

    const got = (await (await poll()).json()) as { status: string; device_token: string; email: string };
    expect(got.status).toBe("approved");
    expect(got.device_token.length).toBeGreaterThan(30);
    expect((await poll()).status).toBe(410);
    const stored = await E.DB.prepare("SELECT token_hash, label FROM device_tokens WHERE token_hash = ?").bind(await sha256Hex(got.device_token)).first<{ label: string }>();
    expect(stored!.label).toBe("Ada's MacBook");
    expect(await E.DB.prepare("SELECT 1 FROM device_tokens WHERE token_hash = ?").bind(got.device_token).first()).toBeNull();
    const me = (await (await call("/api/me", { headers: { authorization: `Bearer ${got.device_token}` } })).json()) as { email: string };
    expect(me.email).toBe(got.email);
  });

  it("lets a code run out after 10 minutes, and refuses an unknown code", async () => {
    const cookie = await webSignIn(call, E, `exp-${rnd()}@example.com`);
    const d = (await (await call("/api/auth/device", { method: "POST", headers: ipHeader(), body: "{}" })).json()) as { device_code: string; user_code: string };
    await E.DB.prepare("UPDATE device_codes SET expires_at = ? WHERE user_code = ?").bind(Date.now() - 1, d.user_code).run();
    expect((await call("/api/auth/device/poll", { method: "POST", body: JSON.stringify({ device_code: d.device_code }) })).status).toBe(410);
    expect((await call("/api/auth/device/approve", { method: "POST", headers: { origin: APP, cookie, ...ipHeader() }, body: JSON.stringify({ user_code: d.user_code }) })).status).toBe(404);
    expect((await call(`/connect?code=${d.user_code}`, { headers: { cookie } })).status).toBe(404);
    expect((await call("/api/auth/device/poll", { method: "POST", body: JSON.stringify({ device_code: "nope" }) })).status).toBe(410);
  });

  it("revokes the device token on sign out, and lists the account's shared links", async () => {
    const me = await newUser(call, E);
    const a = await share(me);
    const b = await share(me, { title: "Second" });
    const list = (await (await call("/api/me/cases", { headers: me.bearer })).json()) as { cases: { id: string; url: string; mode: string; comment_count: number; device_label: string; title: string }[] };
    expect(list.cases.map((c) => c.id).sort()).toEqual([a.body!.id, b.body!.id].sort());
    expect(list.cases[0]).toMatchObject({ device_label: "Test Mac", comment_count: 0, mode: "link" });
    expect(list.cases[0].url).toBe(`${APP}/d/${list.cases[0].id}`);
    // Someone else sees none of them.
    const other = await newUser(call, E);
    expect(((await (await call("/api/me/cases", { headers: other.bearer })).json()) as { cases: unknown[] }).cases).toHaveLength(0);

    expect((await call("/api/me/device", { method: "DELETE", headers: me.bearer })).status).toBe(200);
    expect((await call("/api/me", { headers: me.bearer })).status).toBe(401);
    expect((await call("/api/me/cases", { headers: me.bearer })).status).toBe(401);
    expect((await call("/api/me/device", { method: "DELETE", headers: me.bearer })).status).toBe(401);
  });
});

describe("ownership", () => {
  it("needs a device token to make a case, and records the owner", async () => {
    const none = await call("/api/cases", { method: "POST", body: JSON.stringify({ title: "x", owner_key_hash: await sha256Hex("k") }) });
    expect(none.status).toBe(401);
    expect(((await none.json()) as { error: string }).error).toBe("Sign in to Waggle first.");
    const wrong = await call("/api/cases", { method: "POST", headers: { authorization: "Bearer made-up" }, body: JSON.stringify({ title: "x", owner_key_hash: await sha256Hex("k") }) });
    expect(wrong.status).toBe(401);
    const me = await newUser(call, E);
    const { body } = await share(me);
    const row = await E.DB.prepare("SELECT owner_user_id, device_label FROM cases WHERE id = ?").bind(body!.id).first<{ owner_user_id: string; device_label: string }>();
    expect(row!.owner_user_id).toBeTruthy();
    expect(row!.device_label).toBe("Test Mac");
  });

  it("lets the owner act with the device token, the web session or the owner key, and nobody else", async () => {
    const me = await newUser(call, E);
    const { body, keyAuth } = await share(me);
    const id = body!.id;
    await addRound(id, me.bearer);
    await addRound(id, keyAuth).catch(() => {});
    for (const auth of [me.bearer, keyAuth]) {
      expect((await call(`/api/cases/${id}/comments`, { headers: auth })).status).toBe(200);
    }
    expect((await call(`/api/cases/${id}/comments`, { headers: { cookie: me.cookie } })).status).toBe(200);
    // A write by cookie must come from the app's page.
    expect((await call(`/api/cases/${id}`, { method: "PATCH", headers: { cookie: me.cookie, origin: "https://evil.example" }, body: JSON.stringify({ mode: "link" }) })).status).toBe(403);

    const other = await newUser(call, E);
    expect((await call(`/api/cases/${id}/comments`, { headers: other.bearer })).status).toBe(401);
    expect((await call(`/api/cases/${id}/comments`, { headers: { cookie: other.cookie } })).status).toBe(401);
    expect((await call(`/api/cases/${id}`, { method: "DELETE", headers: other.bearer })).status).toBe(401);
    expect((await call(`/api/cases/${id}/comments`)).status).toBe(401);
    // A revoked token is no owner.
    await call("/api/me/device", { method: "DELETE", headers: me.bearer });
    expect((await call(`/api/cases/${id}/comments`, { headers: me.bearer })).status).toBe(401);
    // The key still works, and the web session too.
    expect((await call(`/api/cases/${id}/comments`, { headers: keyAuth })).status).toBe(200);
    expect((await call(`/api/cases/${id}`, { method: "DELETE", headers: { cookie: me.cookie } })).status).toBe(403);
    expect((await call(`/api/cases/${id}`, { method: "DELETE", headers: { cookie: me.cookie, origin: APP } })).status).toBe(200);
  });

  it("keeps a case made before accounts working with its owner key", async () => {
    const key = "old-key";
    await E.DB.prepare("INSERT INTO cases (id, title, mode, owner_key_hash, repo, created_at) VALUES ('oldcase01', 'Old', 'link', ?, NULL, ?)").bind(await sha256Hex(key), Date.now()).run();
    const auth = { authorization: `Bearer ${key}` };
    await addRound("oldcase01", auth);
    expect((await call("/api/cases/oldcase01/comments", { headers: auth })).status).toBe(200);
    const link = (await (await call("/api/cases/oldcase01/owner-link", { method: "POST", headers: auth })).json()) as { url: string };
    expect(link.url).toContain("/auth/oldcase01/");
    const signIn = await call(link.url.slice(APP.length));
    const state = (await (await call("/api/cases/oldcase01/state", { headers: { cookie: cookieOf(signIn) } })).json()) as { viewer: { kind: string } };
    expect(state.viewer.kind).toBe("owner");
    expect((await call("/api/cases/oldcase01", { method: "DELETE", headers: auth })).status).toBe(200);
  });
});

describe("the home page after a web sign-in", () => {
  it("sends a signed-out visitor to sign in", async () => {
    const res = await call("/");
    expect(res.status).toBe(303);
    expect(res.headers.get("location")).toBe("/signin");
  });

  it("shows the email, the owner's links and the cases shared with the person, escaped", async () => {
    const owner = await newUser(call, E);
    const friend = await newUser(call, E);
    const a = await share(owner, { mode: "emails", emails: [friend.email], title: "Plan <b>v2</b>" });
    const mineHome = await (await call("/", { headers: { cookie: owner.cookie } })).text();
    expect(mineHome).toContain(owner.email);
    expect(mineHome).not.toContain("You are signed in");
    expect(mineHome).toContain("Your cases");
    expect(mineHome).toContain("Shared by you");
    expect(mineHome).toContain("Shared with you");
    expect(mineHome).toContain("Nobody has shared a case with you yet.");
    expect(mineHome).toContain("Only listed people");
    expect(mineHome).toMatch(/Shared \d{1,2} [A-Z][a-z]{2}|Updated /);
    expect(mineHome).toContain("Open Waggle on your Mac");
    expect(mineHome).toContain("https://waggle.so/privacy");
    expect(mineHome).not.toContain("—");
    expect(mineHome).toContain(`/d/${a.body!.id}`);
    expect(mineHome).toContain("Plan &lt;b&gt;v2&lt;/b&gt;");
    expect(mineHome).not.toContain("<b>v2</b>");
    const friendHome = await (await call("/", { headers: { cookie: friend.cookie } })).text();
    expect(friendHome).toContain(`/d/${a.body!.id}`);
    expect(friendHome).toContain("You have not shared a case yet. Open a case in Waggle on your Mac and choose Share.");
    expect(friendHome).toContain(`from ${owner.email.split("@")[0]}`);
    expect(friendHome).not.toContain(`from ${owner.email}`);
  });
});

describe("the home page time text", () => {
  const now = Date.UTC(2026, 9, 18, 12, 0);
  it("says Updated when the case changed after it was shared, else Shared with the date", async () => {
    const { whenText } = await import("../src/authpages");
    expect(whenText({ id: "a", title: "t", mode: "link", comment_count: 0, created_at: now - 9e6, last_at: now - 7200000 }, now)).toBe("Updated 2 h ago");
    expect(whenText({ id: "a", title: "t", mode: "link", comment_count: 0, created_at: Date.UTC(2026, 9, 17), last_at: Date.UTC(2026, 9, 17) }, now)).toBe("Shared 17 Oct");
  });
});

describe("the sign-in link form in a real browser", () => {
  it("signs in when the browser sends Origin null with Sec-Fetch-Site same-origin, and refuses a cross-site post", async () => {
    const me = await newUser(call, E);
    const { body } = await share(me, { mode: "emails", emails: [`other-${rnd()}@example.com`] });
    const id = body!.id;
    const mk = async () => ((await (await call(`/api/cases/${id}/owner-link`, { method: "POST", headers: me.bearer })).json()) as { url: string }).url.slice(APP.length);
    const cross = await call(await mk(), { method: "POST", headers: { origin: "null", "sec-fetch-site": "cross-site" } });
    expect(cross.status).toBe(403);
    const bare = await call(await mk(), { method: "POST", headers: { origin: "null" } });
    expect(bare.status).toBe(403);
    const ok = await call(await mk(), { method: "POST", headers: { origin: "null", "sec-fetch-site": "same-origin" } });
    expect(ok.headers.get("location")).toBe(`/d/${id}`);
    expect(cookieOf(ok, "wr_session")).toBeTruthy();
  });

  it("serves the sign-in pages with a same-origin referrer policy", async () => {
    const res = await call("/signin");
    expect(res.headers.get("referrer-policy")).toBe("same-origin");
  });
});

describe("the owner opens the page, and comments carry who wrote them", () => {
  it("lands the owner signed in, and their comment is an owner comment with the email", async () => {
    const me = await newUser(call, E);
    const { body } = await share(me, { mode: "emails", emails: [`other-${rnd()}@example.com`] });
    const id = body!.id;
    await addRound(id, me.bearer);
    const link = (await (await call(`/api/cases/${id}/owner-link`, { method: "POST", headers: me.bearer })).json()) as { url: string };
    expect(link.url).toContain(`${APP}/signin/`);
    const landing = await call(link.url.slice(APP.length), { method: "POST", headers: page() });
    expect(landing.headers.get("location")).toBe(`/d/${id}`);
    const cookie = cookieOf(landing, "wr_session");
    const state = (await (await call(`/api/cases/${id}/state`, { headers: { cookie } })).json()) as { viewer: { kind: string; email: string; signed_in: boolean } };
    expect(state.viewer).toMatchObject({ kind: "owner", email: me.email, signed_in: true });
    const post = await call(`/api/cases/${id}/comments`, { method: "POST", headers: page(cookie), body: JSON.stringify({ round_seq: 1, body: "My own note" }) });
    expect(post.status).toBe(201);
    const fetched = (await (await call(`/api/cases/${id}/comments`, { headers: me.bearer })).json()) as { comments: { author_kind: string; author_name: string; author_email: string }[] };
    expect(fetched.comments[0]).toMatchObject({ author_kind: "owner", author_name: me.email, author_email: me.email });
  });

  it("shows a signed-in visitor of a link case as a member, a guest as a guest, and refuses a guest who takes a real name", async () => {
    const me = await newUser(call, E);
    const { body } = await share(me);
    const id = body!.id;
    await addRound(id, me.bearer);
    const bea = `bea-${rnd()}@example.com`;
    const beaCookie = await webSignIn(call, E, bea);
    expect((await call(`/api/cases/${id}/comments`, { method: "POST", headers: page(beaCookie), body: JSON.stringify({ round_seq: 1, body: "From Bea" }) })).status).toBe(201);
    const guest = await call(`/api/cases/${id}/guest`, { method: "POST", headers: { ...page(), ...ipHeader() }, body: JSON.stringify({ name: "Visitor" }) });
    expect(guest.status).toBe(200);
    await call(`/api/cases/${id}/comments`, { method: "POST", headers: page(cookieOf(guest)), body: JSON.stringify({ round_seq: 1, body: "From a guest" }) });
    const fetched = (await (await call(`/api/cases/${id}/comments`, { headers: me.bearer })).json()) as { comments: { author_kind: string; author_email: string | null; body: string }[] };
    expect(fetched.comments.map((c) => [c.author_kind, c.author_email])).toEqual([["member", bea], ["guest", null]]);
    const state = (await (await call(`/api/cases/${id}/state`)).json()) as { comments: { author_kind: string }[] };
    expect(state.comments.map((c) => c.author_kind)).toEqual(["member", "guest"]);

    // Names a guest may not use: Owner, a signed-in author on this case, the owner, a listed email.
    for (const name of ["Owner", "OWNER", bea.toUpperCase(), me.email]) {
      const r = await call(`/api/cases/${id}/guest`, { method: "POST", headers: { ...page(), ...ipHeader() }, body: JSON.stringify({ name }) });
      expect(r.status, name).toBe(400);
    }
    expect((await call(`/api/cases/${id}/guest`, { method: "POST", headers: { ...page(), ...ipHeader() }, body: JSON.stringify({ name: "Ada" }) })).status).toBe(200);
  });
});

describe("only these emails, with accounts", () => {
  it("invites each listed address once, lets them in by signing in, and shows a stranger the not-on-the-list text", async () => {
    const me = await newUser(call, E);
    const bea = `bea-${rnd()}@example.com`;
    const cy = `cy-${rnd()}@example.com`;
    const { body } = await share(me, { mode: "emails", emails: [bea, cy.toUpperCase()] });
    const id = body!.id;
    await addRound(id, me.bearer);
    const invite = await lastMail(E, bea);
    expect(invite.subject).toBe(`${me.email} shared "Pricing "page"" with you on Waggle`);
    expect(invite.body_text).toContain(`${me.email} shared "Pricing "page"" with you on Waggle.`);
    expect(invite.body_text).toContain(`${APP}/d/${id}`);
    expect(invite.body_html).toContain("&quot;page&quot;");
    expect((await E.DB.prepare("SELECT COUNT(*) AS n FROM dev_outbox WHERE to_email = ?").bind(cy).first<{ n: number }>())!.n).toBe(1);

    expect((await call(`/api/cases/${id}/state`)).status).toBe(401);
    const beaCookie = await webSignIn(call, E, bea, `/d/${id}`);
    const state = (await (await call(`/api/cases/${id}/state`, { headers: { cookie: beaCookie } })).json()) as { viewer: { kind: string; email: string }; rounds: unknown[] };
    expect(state.viewer).toMatchObject({ kind: "member", email: bea });
    expect(state.rounds).toHaveLength(1);
    expect((await call(`/api/cases/${id}/comments`, { method: "POST", headers: page(beaCookie), body: JSON.stringify({ round_seq: 1, body: "Looks right" }) })).status).toBe(201);

    const eve = await webSignIn(call, E, `eve-${rnd()}@example.com`);
    const denied = await call(`/api/cases/${id}/state`, { headers: { cookie: eve } });
    expect(denied.status).toBe(403);
    expect(((await denied.json()) as { error: string }).error).toBe("This case is shared with a list of people. You are not on it.");
    expect((await call(`/api/cases/${id}/comments`, { method: "POST", headers: page(eve), body: JSON.stringify({ round_seq: 1, body: "x" }) })).status).toBe(403);
    // The guest route is closed in this mode.
    expect((await call(`/api/cases/${id}/guest`, { method: "POST", headers: { ...page(), ...ipHeader() }, body: JSON.stringify({ name: "x" }) })).status).toBe(403);
  });

  it("changes the audience in place: same URL, comments kept, invites for new addresses only, removal ends access", async () => {
    const me = await newUser(call, E);
    const bea = `bea-${rnd()}@example.com`;
    const cy = `cy-${rnd()}@example.com`;
    const { body } = await share(me, { mode: "emails", emails: [bea] });
    const id = body!.id;
    await addRound(id, me.bearer);
    const beaCookie = await webSignIn(call, E, bea);
    await call(`/api/cases/${id}/comments`, { method: "POST", headers: page(beaCookie), body: JSON.stringify({ round_seq: 1, body: "Keep me" }) });
    const outbox = async (to: string) => (await E.DB.prepare("SELECT COUNT(*) AS n FROM dev_outbox WHERE to_email = ? AND subject LIKE '%shared%'").bind(to).first<{ n: number }>())!.n;
    expect(await outbox(bea)).toBe(1);

    const patch = (b: unknown, auth: Record<string, string> = me.bearer) => call(`/api/cases/${id}`, { method: "PATCH", headers: auth, body: JSON.stringify(b) });
    const res = await patch({ emails: [bea, cy] });
    expect(await res.json()).toEqual({ id, mode: "emails", emails: [bea, cy].sort(), invited: 1, invites: { sent: 1, failed: 0, limited: 0 } });
    expect(await outbox(bea)).toBe(1);
    expect(await outbox(cy)).toBe(1);

    // Removing bea ends her access at her next request.
    expect((await patch({ emails: [cy] })).status).toBe(200);
    expect((await call(`/api/cases/${id}/state`, { headers: { cookie: beaCookie } })).status).toBe(403);

    // To link mode: anyone can read, the list is gone, the comment stays.
    expect(await (await patch({ mode: "link" })).json()).toEqual({ id, mode: "link", emails: [], invited: 0, invites: { sent: 0, failed: 0, limited: 0 } });
    const open = (await (await call(`/api/cases/${id}/state`)).json()) as { mode: string; comments: { body: string }[] };
    expect(open.mode).toBe("link");
    expect(open.comments.map((c) => c.body)).toEqual(["Keep me"]);
    // Back to emails needs a list.
    expect((await patch({ mode: "emails" })).status).toBe(400);
    expect((await patch({ mode: "emails", emails: [bea] })).status).toBe(200);
    expect(await outbox(bea)).toBe(2);
  });

  it("checks PATCH like create: owner only, 50 cap, bad email, bad mode, empty body", async () => {
    const me = await newUser(call, E);
    const { body, keyAuth } = await share(me, { mode: "emails", emails: ["a@example.com"] });
    const id = body!.id;
    const patch = (b: unknown, auth: Record<string, string> = me.bearer) => call(`/api/cases/${id}`, { method: "PATCH", headers: auth, body: JSON.stringify(b) });
    expect((await patch({ mode: "link" }, { authorization: "Bearer nope" })).status).toBe(401);
    expect((await patch({ mode: "link" }, (await newUser(call, E)).bearer)).status).toBe(401);
    expect((await patch({})).status).toBe(400);
    expect((await patch({ mode: "everyone" })).status).toBe(400);
    expect((await patch({ emails: ["nope"] })).status).toBe(400);
    const many = Array.from({ length: 51 }, (_, i) => `p${i}@example.com`);
    const over = await patch({ emails: many });
    expect(over.status).toBe(400);
    expect(((await over.json()) as { error: string }).error).toBe("50 emails at most");
    expect((await patch({ emails: many.slice(0, 50) })).status).toBe(200);
    // The owner key may change it too.
    expect((await patch({ mode: "link" }, keyAuth)).status).toBe(200);
  });
});

describe("limits", () => {
  const status = async (p: Promise<Response>) => (await p).status;

  it("allows 5 sign-in emails per address per hour", async () => {
    const email = `lim-${rnd()}@example.com`;
    const ip = ipHeader();
    const send = (h: Record<string, string> = ip) => call("/api/auth/email", { method: "POST", headers: { ...page(), ...h }, body: JSON.stringify({ email }) });
    for (let i = 0; i < 5; i++) expect(await status(send())).toBe(202);
    const over = await send();
    expect(over.status).toBe(429);
    expect(((await over.json()) as { error: string }).error).toContain("Too many sign-in emails");
    expect(Number(over.headers.get("retry-after"))).toBeGreaterThan(0);
    // A stranger on another network used up nothing of this person's hourly count.
    expect(await status(send(ipHeader()))).toBe(202);
  });

  it("does not let one network lock a person out, and caps an address at 30 a day from all networks", async () => {
    const email = `victim-${rnd()}@example.com`;
    const attacker = ipHeader("203.0.113.40");
    const send = (h: Record<string, string>) => call("/api/auth/email", { method: "POST", headers: { ...page(), ...h }, body: JSON.stringify({ email }) });
    for (let i = 0; i < 6; i++) await send(attacker);
    expect(await status(send(ipHeader()))).toBe(202);
    // 5 + 1 counted so far (the sixth attacker call stopped at the per-network limit); 24 more reach 30.
    for (let i = 0; i < 24; i++) expect(await status(send(ipHeader()))).toBe(202);
    const over = await send(ipHeader());
    expect(over.status).toBe(429);
    expect(((await over.json()) as { error: string }).error).toContain("today");
  });

  it("allows 20 sign-in emails per network per hour", async () => {
    const ip = ipHeader("203.0.113.7");
    for (let i = 0; i < 20; i++) expect(await status(call("/api/auth/email", { method: "POST", headers: { ...page(), ...ip }, body: JSON.stringify({ email: `ip-${rnd()}@example.com` }) }))).toBe(202);
    expect(await status(call("/api/auth/email", { method: "POST", headers: { ...page(), ...ip }, body: JSON.stringify({ email: `ip-${rnd()}@example.com` }) }))).toBe(429);
  });

  it("allows 10 device codes per network per hour", async () => {
    const ip = ipHeader("203.0.113.8");
    for (let i = 0; i < 10; i++) expect(await status(call("/api/auth/device", { method: "POST", headers: ip, body: "{}" }))).toBe(201);
    expect(await status(call("/api/auth/device", { method: "POST", headers: ip, body: "{}" }))).toBe(429);
  });

  it("keys limits on cf-connecting-ip only: a forged x-forwarded-for changes nothing", async () => {
    const send = (xff: string) =>
      call("/api/auth/device", { method: "POST", headers: { "x-forwarded-for": xff, "cf-connecting-ip": "198.51.100.1" }, body: "{}" });
    for (let i = 0; i < 10; i++) expect(await status(send(`192.0.2.${i}`))).toBe(201);
    expect(await status(send("192.0.2.200"))).toBe(429);
  });

  it("allows 30 new cases per user per day, but a retried share does not count", async () => {
    const me = await newUser(call, E);
    const hash = await sha256Hex("k-lim");
    const make = (extra: Record<string, unknown> = {}) => call("/api/cases", { method: "POST", headers: me.bearer, body: JSON.stringify({ title: "T", owner_key_hash: hash, ...extra }) });
    for (let i = 0; i < 30; i++) expect(await status(make({ request_id: `r${i}` }))).toBe(201);
    expect(await status(make({ request_id: "r0" }))).toBe(200);
    const over = await make({ request_id: "r30" });
    expect(over.status).toBe(429);
    expect(((await over.json()) as { error: string }).error).toContain("30 cases");
    // Another user is not held back.
    expect(await status(share(await newUser(call, E)).then((s) => s.res))).toBe(201);
  });

  it("allows 20 guest joins per network per hour", async () => {
    const { body } = await share(await newUser(call, E));
    const ip = ipHeader("203.0.113.9");
    for (let i = 0; i < 20; i++) expect(await status(call(`/api/cases/${body!.id}/guest`, { method: "POST", headers: { ...page(), ...ip }, body: JSON.stringify({ name: `G${i}` }) }))).toBe(200);
    expect(await status(call(`/api/cases/${body!.id}/guest`, { method: "POST", headers: { ...page(), ...ip }, body: JSON.stringify({ name: "G21" }) }))).toBe(429);
  });

  it("allows 60 comments per person per hour and 2000 per case", async () => {
    const me = await newUser(call, E);
    const { body } = await share(me);
    const id = body!.id;
    await addRound(id, me.bearer);
    const cookie = await webSignIn(call, E, `chat-${rnd()}@example.com`);
    const post = (c: string) => call(`/api/cases/${id}/comments`, { method: "POST", headers: page(c), body: JSON.stringify({ round_seq: 1, body: "hi" }) });
    for (let i = 0; i < 60; i++) expect(await status(post(cookie))).toBe(201);
    const over = await post(cookie);
    expect(over.status).toBe(429);
    expect(((await over.json()) as { error: string }).error).toContain("Try again");
    // Another person on the same case can still comment.
    expect(await status(post(await webSignIn(call, E, `chat-${rnd()}@example.com`)))).toBe(201);
    // 2000 per case.
    const fill = [];
    for (let i = 0; i < 2000; i++) {
      fill.push(E.DB.prepare("INSERT OR IGNORE INTO comments (id, case_id, round_seq, commit_id, body, author_kind, author_name, created_at) VALUES (?, ?, 1, 'c', 'x', 'guest', 'F', ?)").bind(`fill${i}`, id, i));
    }
    await E.DB.batch(fill);
    const full = await post(await webSignIn(call, E, `chat-${rnd()}@example.com`));
    expect(full.status).toBe(429);
    expect(((await full.json()) as { error: string }).error).toContain("2000");
  });

  it("sends at most 50 invites in one call", async () => {
    const me = await newUser(call, E);
    const emails = Array.from({ length: 50 }, (_, i) => `inv${i}-${rnd()}@example.com`);
    const ok = await share(me, { mode: "emails", emails });
    expect(ok.res.status).toBe(201);
    const n = await E.DB.prepare("SELECT COUNT(*) AS n FROM dev_outbox WHERE subject LIKE '%shared%' AND to_email IN (" + emails.map(() => "?").join(",") + ")").bind(...emails).first<{ n: number }>();
    expect(n!.n).toBe(50);
    const over = await share(me, { mode: "emails", emails: [...emails, "one-more@example.com"] });
    expect(over.res.status).toBe(400);
  });
});

describe("review fixes (WAG-392)", () => {
  const status = async (p: Promise<Response>) => (await p).status;

  it("F1: a guest loses access when the case goes to emails mode", async () => {
    const me = await newUser(call, E);
    const { body } = await share(me);
    const id = body!.id;
    await addRound(id, me.bearer);
    const guest = await call(`/api/cases/${id}/guest`, { method: "POST", headers: { ...page(), ...ipHeader() }, body: JSON.stringify({ name: "Gus" }) });
    const cookie = cookieOf(guest);
    expect(await status(call(`/api/cases/${id}/state`, { headers: { cookie } }))).toBe(200);
    const patch = await call(`/api/cases/${id}`, { method: "PATCH", headers: me.bearer, body: JSON.stringify({ mode: "emails", emails: ["a@example.com"] }) });
    expect(patch.status).toBe(200);
    expect(await status(call(`/api/cases/${id}/state`, { headers: { cookie } }))).toBe(401);
    expect(await status(call(`/api/cases/${id}/comments`, { method: "POST", headers: page(cookie), body: JSON.stringify({ round_seq: 1, body: "x" }) }))).toBe(401);
    expect((await E.DB.prepare("SELECT COUNT(*) AS n FROM sessions WHERE case_id = ? AND kind = 'guest'").bind(id).first<{ n: number }>())!.n).toBe(0);
    // A guest session that survives (an old row) is refused by the mode check itself.
    await E.DB.prepare("INSERT INTO sessions (token_hash, case_id, kind, name, email, created_at, expires_at) VALUES (?, ?, 'guest', 'Old', NULL, ?, ?)").bind(await sha256Hex("old-token"), id, Date.now(), Date.now() + 100000).run();
    expect(await status(call(`/api/cases/${id}/state`, { headers: { cookie: `wr_${id}=old-token` } }))).toBe(401);
  });

  it("F3, F6: invites are limited to 50 per call and 100 per user per day, and the answer counts them", async () => {
    const me = await newUser(call, E);
    const { body } = await share(me, { mode: "emails", emails: ["first@example.com"] });
    const id = body!.id;
    const list = (tag: string, n: number) => Array.from({ length: n }, (_, i) => `${tag}${i}-${rnd()}@example.com`);
    const patch = async (emails: string[]) => (await (await call(`/api/cases/${id}`, { method: "PATCH", headers: me.bearer, body: JSON.stringify({ emails }) })).json()) as { invites: { sent: number; failed: number; limited: number }; emails: string[] };
    const one = await patch(list("a", 50));
    expect(one.invites).toEqual({ sent: 50, failed: 0, limited: 0 });
    // 1 (create) + 50 so far; 49 more fit in the day, the rest is limited. The share still works.
    const two = await patch(list("b", 50));
    expect(two.invites).toEqual({ sent: 49, failed: 0, limited: 1 });
    expect(two.emails).toHaveLength(50);
    const three = await patch(list("c", 3));
    expect(three.invites).toEqual({ sent: 0, failed: 0, limited: 3 });
  });

  it("F6: a failed invite mail is counted, and the share still works", async () => {
    const me = await newUser(call, E);
    const broken = { ...E, EMAIL: { send: async () => { throw new Error("no"); } } } as unknown as Env;
    vi.spyOn(console, "error").mockImplementation(() => {});
    const res = await callFor(broken)("/api/cases", { method: "POST", headers: me.bearer, body: JSON.stringify({ title: "T", mode: "emails", emails: ["x@example.com", "y@example.com"], owner_key_hash: await sha256Hex("k-f6") }) });
    expect(res.status).toBe(201);
    expect(((await res.json()) as { invites: unknown }).invites).toEqual({ sent: 0, failed: 2, limited: 0 });
  });

  it("F3: the sign-in answer stays the same for every address, whatever the mail does", async () => {
    const broken = { ...E, EMAIL: { send: async () => { throw new Error("no"); } } } as unknown as Env;
    vi.spyOn(console, "error").mockImplementation(() => {});
    const r = await callFor(broken)("/api/auth/email", { method: "POST", headers: { ...page(), ...ipHeader() }, body: JSON.stringify({ email: `q-${rnd()}@example.com` }) });
    expect(r.status).toBe(202);
    expect(await r.json()).toEqual({ sent: true });
  });

  it("F4: only the owner sees author_email in the state", async () => {
    const me = await newUser(call, E);
    const { body, keyAuth } = await share(me);
    const id = body!.id;
    await addRound(id, me.bearer);
    const bea = `bea-${rnd()}@example.com`;
    const beaCookie = await webSignIn(call, E, bea);
    await call(`/api/cases/${id}/comments`, { method: "POST", headers: page(beaCookie), body: JSON.stringify({ round_seq: 1, body: "Hi" }) });
    type S = { comments: { author_email: string | null; author_kind: string; author_name: string }[] };
    const read = async (h: Record<string, string>) => ((await (await call(`/api/cases/${id}/state`, { headers: h })).json()) as S).comments[0];
    // Others: name and kind, no address.
    // A member shown by address has only the part before the @ for others, so the address does not leak through the name.
    expect(await read({})).toMatchObject({ author_email: null, author_kind: "member", author_name: bea.split("@")[0] });
    expect(JSON.stringify(await read({}))).not.toContain("@");
    expect(await read({ cookie: beaCookie })).toMatchObject({ author_email: null });
    // The owner, by each path.
    expect(await read(me.bearer)).toMatchObject({ author_email: bea, author_name: bea });
    expect((await read(keyAuth)).author_email).toBe(bea);
    const ownerCookie = await webSignIn(call, E, me.email);
    expect((await read({ cookie: ownerCookie })).author_email).toBe(bea);
    const link = (await (await call(`/api/cases/${id}/owner-link`, { method: "POST", headers: me.bearer, body: "{}" })).json()) as { url: string };
    const opened = await call(link.url.slice(APP.length), { method: "POST", headers: { origin: APP } });
    expect((await read({ cookie: cookieOf(opened, "wr_session") })).author_email).toBe(bea);
  });

  it("F7: only an unknown device token gets the invalid_token code; a valid token on a foreign case does not", async () => {
    const me = await newUser(call, E);
    const other = await newUser(call, E);
    const { body } = await share(me);
    const id = body!.id;
    const foreign = await call(`/api/cases/${id}`, { method: "PATCH", headers: other.bearer, body: JSON.stringify({ mode: "link" }) });
    expect(foreign.status).toBe(401);
    expect(((await foreign.json()) as { code?: string }).code).toBeUndefined();
    const bad = await call(`/api/cases/${id}`, { method: "PATCH", headers: { authorization: "Bearer nope" }, body: JSON.stringify({ mode: "link" }) });
    expect(bad.status).toBe(401);
    expect(((await bad.json()) as { code?: string }).code).toBe("invalid_token");
    const me2 = await call("/api/me/cases", { headers: { authorization: "Bearer nope" } });
    expect(((await me2.json()) as { code?: string }).code).toBe("invalid_token");
  });

  it("F2: the upstream host is gone: workers.dev hosts get 404", async () => {
    const res = await worker.fetch(new Request("https://waggle-relay.example.workers.dev/d/abc"), E);
    expect(res.status).toBe(404);
  });
});

describe("daily cleanup", () => {
  it("deletes expired sessions, used or expired links, old device codes and old limit rows", async () => {
    const now = Date.now();
    const user = await newUser(call, E);
    const uid = (await E.DB.prepare("SELECT id FROM users WHERE email = ?").bind(user.email).first<{ id: string }>())!.id;
    const old = now - 3 * 86400_000;
    await E.DB.batch([
      E.DB.prepare("INSERT INTO web_sessions (token_hash, user_id, created_at, expires_at) VALUES ('old-ws', ?, ?, ?)").bind(uid, old, now - 1000),
      E.DB.prepare("INSERT INTO signin_links (token_hash, email, purpose, next, expires_at, used_at) VALUES ('used-l', 'a@b.co', 'signin', '/', ?, ?)").bind(now + 99999, now),
      E.DB.prepare("INSERT INTO signin_links (token_hash, email, purpose, next, expires_at) VALUES ('exp-l', 'a@b.co', 'signin', '/', ?)").bind(now - 1),
      E.DB.prepare("INSERT INTO signin_links (token_hash, email, purpose, next, expires_at) VALUES ('live-l', 'a@b.co', 'signin', '/', ?)").bind(now + 600_000),
      E.DB.prepare("INSERT INTO device_codes (device_code_hash, user_code, label, expires_at) VALUES ('old-d', 'OLD-0001', 'm', ?)").bind(now - 1),
      E.DB.prepare("INSERT INTO device_codes (device_code_hash, user_code, label, expires_at) VALUES ('live-d', 'LIV-0001', 'm', ?)").bind(now + 600_000),
      E.DB.prepare("INSERT INTO rate_limits (key, window, count) VALUES ('old-k', ?, 3)").bind(old),
      E.DB.prepare("INSERT INTO rate_limits (key, window, count) VALUES ('new-k', ?, 3)").bind(now),
    ]);
    const exists = async (sql: string) => !!(await E.DB.prepare(sql).first());
    // The Cron Trigger calls the scheduled handler.
    const waits: Promise<unknown>[] = [];
    await worker.scheduled!({} as ScheduledController, E, { waitUntil: (p: Promise<unknown>) => void waits.push(p), passThroughOnException() {} } as unknown as ExecutionContext);
    await Promise.all(waits);
    expect(await exists("SELECT 1 FROM web_sessions WHERE token_hash = 'old-ws'")).toBe(false);
    expect(await exists("SELECT 1 FROM signin_links WHERE token_hash = 'used-l'")).toBe(false);
    expect(await exists("SELECT 1 FROM signin_links WHERE token_hash = 'exp-l'")).toBe(false);
    expect(await exists("SELECT 1 FROM signin_links WHERE token_hash = 'live-l'")).toBe(true);
    expect(await exists("SELECT 1 FROM device_codes WHERE device_code_hash = 'old-d'")).toBe(false);
    expect(await exists("SELECT 1 FROM device_codes WHERE device_code_hash = 'live-d'")).toBe(true);
    expect(await exists("SELECT 1 FROM rate_limits WHERE key = 'old-k'")).toBe(false);
    expect(await exists("SELECT 1 FROM rate_limits WHERE key = 'new-k'")).toBe(true);
    // Cases have no time to live.
    const me = await newUser(call, E);
    const { body } = await share(me);
    await E.DB.prepare("UPDATE cases SET created_at = 1 WHERE id = ?").bind(body!.id).run();
    await cleanup(E);
    expect(await exists(`SELECT 1 FROM cases WHERE id = '${body!.id}'`)).toBe(true);
    // A live device token survives.
    expect((await call("/api/me", { headers: me.bearer })).status).toBe(200);
  });
});

describe("dev-only routes", () => {
  it("reads the outbox in dev mode only", async () => {
    const email = `box-${rnd()}@example.com`;
    await call("/api/auth/email", { method: "POST", headers: { ...page(), ...ipHeader() }, body: JSON.stringify({ email }) });
    const out = (await (await call(`/api/dev/outbox?to=${encodeURIComponent(email)}`)).json()) as { messages: { to: string; text: string }[] };
    expect(out.messages).toHaveLength(1);
    expect(out.messages[0].to).toBe(email);
    const prod = { ...E, DEV_MODE: undefined } as unknown as Env;
    expect((await callFor(prod)(`/api/dev/outbox?to=${encodeURIComponent(email)}`)).status).toBe(404);
  });
});

