import {
  bearer,
  deviceUser,
  endWebSession,
  hmac,
  randomToken,
  readCookie,
  sameOrigin,
  sha256Hex,
  startWebSession,
  webUser,
  type User,
} from "./auth";
import { authHeaders, connectPage, homePage, linkPage, messagePage, signInPage, type HomeCase } from "./authpages";
import type { Env } from "./env";
import { body, EMAIL, HttpError, json, text } from "./http";
import { sendMail, signInMail } from "./mail";

// Accounts (WAG-392): email link and Google sign-in, the Mac connect flow, and the account routes.

export const LINK_MINUTES = 15;
const DEVICE_MINUTES = 10;
const USER_CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
const HOUR = 3600_000;
const DAY = 24 * HOUR;

// --- limits ---

// A fixed window in D1. The call that goes over the limit gets 429 with plain words the app can show.
export async function limit(env: Env, key: string, max: number, windowMs: number, message: string): Promise<void> {
  // The window is stored as its start time (ms), so cleanup needs no window length.
  const window = Math.floor(Date.now() / windowMs) * windowMs;
  const row = await env.DB.prepare(
    "INSERT INTO rate_limits (key, window, count) VALUES (?, ?, 1) ON CONFLICT (key, window) DO UPDATE SET count = count + 1 RETURNING count",
  )
    .bind(key, window)
    .first<{ count: number }>();
  if ((row?.count ?? 1) > max) {
    const wait = Math.max(1, Math.ceil((window + windowMs - Date.now()) / 1000));
    throw new HttpError(429, message, { "retry-after": String(wait) });
  }
}

export const LIMITS = {
  emailPerAddress: 5,
  emailPerAddressDay: 30,
  emailPerIp: 20,
  invitesPerUserDay: 100,
  invitesPerCall: 50,
  devicePerIp: 10,
  casesPerUserDay: 30,
  guestsPerIp: 20,
  commentsPerPersonHour: 60,
  commentsPerCase: 2000,
  approvePerIp: 30,
};

// The app host is a Cloudflare custom domain, so Cloudflare sets cf-connecting-ip and a client cannot
// forge it. x-forwarded-for is never read: any client can send it.
export function clientIp(request: Request): string {
  return request.headers.get("cf-connecting-ip") ?? "unknown";
}

// --- helpers ---

// Only a path on this site. Anything else (another host, //host, a backslash) becomes "/".
export function safeNext(env: Env, next: unknown): string {
  if (typeof next !== "string" || next === "" || next.length > 300) return "/";
  if (!next.startsWith("/") || next.startsWith("//") || /[\\\u0000-\u001f]/.test(next)) return "/";
  try {
    const u = new URL(next, env.APP_ORIGIN);
    if (u.origin !== env.APP_ORIGIN) return "/";
    return u.pathname + u.search;
  } catch {
    return "/";
  }
}

function b64url(bytes: ArrayBuffer | Uint8Array): string {
  return btoa(String.fromCharCode(...new Uint8Array(bytes))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function googleOn(env: Env): boolean {
  return !!env.GOOGLE_CLIENT_ID && !!env.GOOGLE_CLIENT_SECRET;
}

// The endpoint overrides work in dev mode only, like the other dev overrides.
function googleUrl(env: Env, kind: "auth" | "token"): string {
  const dev = env.DEV_MODE === "1";
  if (kind === "auth") return (dev && env.GOOGLE_AUTH_URL) || "https://accounts.google.com/o/oauth2/v2/auth";
  return (dev && env.GOOGLE_TOKEN_URL) || "https://oauth2.googleapis.com/token";
}

export async function userByEmail(env: Env, email: string): Promise<User> {
  const e = email.trim().toLowerCase();
  await env.DB.prepare("INSERT OR IGNORE INTO users (id, email, google_sub, name, created_at) VALUES (?, ?, NULL, NULL, ?)")
    .bind(randomToken(9), e, Date.now())
    .run();
  return (await env.DB.prepare("SELECT id, email, name FROM users WHERE email = ?").bind(e).first<User>())!;
}

// Google sign-in matches the account by google_sub first. It links by the verified email only when no user
// has that sub yet, and only when the email's account has no sub of its own. Otherwise it is refused (null):
// a reassigned email address must not take over the old account.
export async function googleUser(env: Env, email: string, sub: string, name: string | null): Promise<User | null> {
  const bySub = await env.DB.prepare("SELECT id, email, name FROM users WHERE google_sub = ?").bind(sub).first<User>();
  if (bySub) return bySub;
  const e = email.trim().toLowerCase();
  const byEmail = await env.DB.prepare("SELECT id, google_sub FROM users WHERE email = ?").bind(e).first<{ id: string; google_sub: string | null }>();
  if (byEmail?.google_sub) return null;
  if (!byEmail) {
    await env.DB.prepare("INSERT OR IGNORE INTO users (id, email, google_sub, name, created_at) VALUES (?, ?, ?, ?, ?)").bind(randomToken(9), e, sub, name, Date.now()).run();
  } else {
    await env.DB.prepare("UPDATE users SET google_sub = ? WHERE id = ? AND google_sub IS NULL").bind(sub, byEmail.id).run();
  }
  const user = await env.DB.prepare("SELECT id, email, name, google_sub FROM users WHERE email = ?").bind(e).first<User & { google_sub: string | null }>();
  // A parallel sign-in with another sub may have linked first.
  return user && user.google_sub === sub ? { id: user.id, email: user.email, name: user.name } : null;
}

async function oneTimeLink(env: Env, purpose: "signin" | "google", minutes: number, fields: { email?: string | null; next: string; userId?: string | null; token?: string }): Promise<string> {
  const token = fields.token ?? randomToken();
  await env.DB.prepare("INSERT INTO signin_links (token_hash, email, purpose, next, user_id, expires_at) VALUES (?, ?, ?, ?, ?, ?)")
    .bind(await sha256Hex(token), fields.email ?? null, purpose, fields.next, fields.userId ?? null, Date.now() + minutes * 60_000)
    .run();
  return token;
}

// A link that signs the account in on a browser and goes to `next`. The owner link for an account case uses it.
export async function accountLink(env: Env, userId: string, next: string): Promise<string> {
  const token = await oneTimeLink(env, "signin", LINK_MINUTES, { next, userId });
  return `${env.APP_ORIGIN}/signin/${token}`;
}

function page(html: string, nonce?: string, status = 200): Response {
  return new Response(html, { status, headers: authHeaders(nonce) });
}

function redirect(location: string, cookies: string[] = []): Response {
  const h = new Headers({ location, "cache-control": "no-store" });
  for (const c of cookies) h.append("set-cookie", c);
  return new Response(null, { status: 303, headers: h });
}

async function requireDevice(env: Env, request: Request) {
  const d = await deviceUser(env, request);
  if (!d) throw new HttpError(401, "Sign in to Waggle first.", {}, "invalid_token");
  return d;
}

// --- routes ---

export async function accountRoutes(request: Request, env: Env, url: URL): Promise<Response | null> {
  const p = url.pathname;
  const m = request.method;
  let r: RegExpMatchArray | null;

  if (m === "GET" && p === "/") {
    const user = await webUser(env, request);
    if (!user) return redirect("/signin");
    const cols = `c.id AS id, c.title AS title, c.mode AS mode, (SELECT COUNT(*) FROM comments m WHERE m.case_id = c.id) AS comment_count, c.created_at AS created_at,
      MAX(c.created_at, COALESCE((SELECT MAX(m.created_at) FROM comments m WHERE m.case_id = c.id), 0), COALESCE((SELECT MAX(r.created_at) FROM rounds r WHERE r.case_id = c.id), 0)) AS last_at,
      (SELECT o.email FROM users o WHERE o.id = c.owner_user_id) AS owner_email`;
    const mine = await env.DB.prepare(`SELECT ${cols} FROM cases c WHERE c.owner_user_id = ? ORDER BY c.created_at DESC LIMIT 100`)
      .bind(user.id)
      .all<HomeCase>();
    const shared = await env.DB.prepare(
      `SELECT ${cols} FROM cases c JOIN case_emails e ON e.case_id = c.id
       WHERE e.email = ? AND c.mode = 'emails' AND (c.owner_user_id IS NULL OR c.owner_user_id != ?) ORDER BY c.created_at DESC LIMIT 100`,
    )
      .bind(user.email, user.id)
      .all<HomeCase>();
    const nonce = randomToken(16);
    return page(homePage(nonce, user.email, mine.results, shared.results), nonce);
  }
  if (m === "GET" && p === "/signin") {
    const nonce = randomToken(16);
    return page(signInPage(nonce, safeNext(env, url.searchParams.get("next")), googleOn(env)), nonce);
  }
  if (m === "GET" && (r = p.match(/^\/signin\/([A-Za-z0-9_-]+)$/))) {
    const nonce = randomToken(16);
    return page(linkPage(nonce, r[1]), nonce);
  }
  if (m === "POST" && (r = p.match(/^\/signin\/([A-Za-z0-9_-]+)$/))) return consumeLink(env, request, r[1]);

  if (m === "POST" && p === "/api/auth/email") return emailLink(env, request);
  if (m === "GET" && p === "/api/auth/google/start") return googleStart(env, request, url);
  if (m === "GET" && p === "/api/auth/google/callback") return googleCallback(env, request, url);
  if (m === "POST" && p === "/api/auth/signout") {
    if (!sameOrigin(env, request)) throw new HttpError(403, "Wrong origin");
    return json({ signed_out: true }, 200, { "set-cookie": await endWebSession(env, request) });
  }
  if (m === "GET" && p === "/api/auth/session") {
    const u = await webUser(env, request);
    return json({ signed_in: !!u, email: u?.email ?? null, google: googleOn(env) });
  }

  if (m === "POST" && p === "/api/auth/device") {
    await limit(env, `device:${clientIp(request)}`, LIMITS.devicePerIp, HOUR, "Too many sign-in codes from this network. Try again in an hour.");
    const b = await body<{ label?: unknown }>(request);
    const label = (text(b.label, "label", 80, false) ?? "A Mac").replace(/[\u0000-\u001f]/g, " ");
    const deviceCode = randomToken(32);
    const bytes = crypto.getRandomValues(new Uint8Array(8));
    const chars = [...bytes].map((x) => USER_CODE_ALPHABET[x % USER_CODE_ALPHABET.length]).join("");
    const userCode = `${chars.slice(0, 4)}-${chars.slice(4)}`;
    await env.DB.prepare("INSERT INTO device_codes (device_code_hash, user_code, label, expires_at) VALUES (?, ?, ?, ?)")
      .bind(await sha256Hex(deviceCode), userCode, label, Date.now() + DEVICE_MINUTES * 60_000)
      .run();
    return json(
      { device_code: deviceCode, user_code: userCode, verify_url: `${env.APP_ORIGIN}/connect?code=${userCode}`, expires_in: DEVICE_MINUTES * 60, interval: 2 },
      201,
    );
  }
  if (m === "POST" && p === "/api/auth/device/poll") return devicePoll(env, request);
  if (m === "POST" && p === "/api/auth/device/approve") {
    if (!sameOrigin(env, request)) throw new HttpError(403, "Wrong origin");
    await limit(env, `approve:${clientIp(request)}`, LIMITS.approvePerIp, HOUR, "Too many tries. Try again in an hour.");
    const user = await webUser(env, request);
    if (!user) throw new HttpError(401, "Sign in first.");
    const b = await body<{ user_code?: unknown }>(request);
    const code = String(text(b.user_code, "user_code", 20)).toUpperCase();
    const row = await env.DB.prepare(
      "UPDATE device_codes SET user_id = ?, approved_at = ? WHERE user_code = ? AND approved_at IS NULL AND expires_at > ? RETURNING label",
    )
      .bind(user.id, Date.now(), code, Date.now())
      .first<{ label: string }>();
    if (!row) throw new HttpError(404, "This code is not valid, or it has run out. Start again in Waggle.");
    return json({ connected: true, label: row.label });
  }
  if (m === "GET" && p === "/connect") return connectRoute(env, request, url);

  if (m === "GET" && p === "/api/me") {
    const d = await requireDevice(env, request);
    return json({ email: d.email, name: d.name });
  }
  if (m === "DELETE" && p === "/api/me/device") {
    await requireDevice(env, request);
    await env.DB.prepare("UPDATE device_tokens SET revoked_at = ? WHERE token_hash = ?").bind(Date.now(), await sha256Hex(bearer(request))).run();
    return json({ revoked: true });
  }
  if (m === "GET" && p === "/api/me/cases") {
    const d = await requireDevice(env, request);
    const rows = await env.DB.prepare(
      `SELECT c.id AS id, c.title AS title, c.mode AS mode, c.created_at AS created_at, c.device_label AS device_label,
              (SELECT COUNT(*) FROM comments m WHERE m.case_id = c.id) AS comment_count
       FROM cases c WHERE c.owner_user_id = ? ORDER BY c.created_at DESC`,
    )
      .bind(d.id)
      .all<{ id: string; title: string; mode: string; created_at: number; device_label: string | null; comment_count: number }>();
    return json({
      cases: rows.results.map((c) => ({ ...c, url: `${env.APP_ORIGIN}/d/${c.id}`, device_label: c.device_label ?? "" })),
    });
  }

  if (m === "GET" && p === "/api/dev/outbox" && env.DEV_MODE === "1") {
    const to = url.searchParams.get("to");
    const rows = await env.DB.prepare(
      `SELECT id, to_email AS "to", subject, body_text AS text, body_html AS html, created_at FROM dev_outbox ${to ? "WHERE to_email = ?" : ""} ORDER BY id`,
    )
      .bind(...(to ? [to.toLowerCase()] : []))
      .all();
    return json({ messages: rows.results });
  }
  return null;
}

// --- email link ---

async function emailLink(env: Env, request: Request): Promise<Response> {
  if (!sameOrigin(env, request)) throw new HttpError(403, "Wrong origin");
  const b = await body<{ email?: unknown; next?: unknown }>(request);
  const email = text(b.email, "email", 200)!.toLowerCase();
  if (!EMAIL.test(email)) throw new HttpError(400, "That is not an email address");
  const ip = clientIp(request);
  await limit(env, `emailip:${ip}`, LIMITS.emailPerIp, HOUR, "Too many sign-in emails from this network. Try again in an hour.");
  // A stranger cannot use up the hourly count of another person: it counts requests from one network only.
  await limit(env, `email:${email}:${ip}`, LIMITS.emailPerAddress, HOUR, "Too many sign-in emails for this address. Try again in an hour.");
  await limit(env, `emailday:${email}`, LIMITS.emailPerAddressDay, DAY, "Too many sign-in emails for this address today. Try again tomorrow.");
  const token = await oneTimeLink(env, "signin", LINK_MINUTES, { email, next: safeNext(env, b.next) });
  try {
    await sendMail(env, signInMail(email, `${env.APP_ORIGIN}/signin/${token}`, LINK_MINUTES));
  } catch (e) {
    // The answer is the same whether or not the mail went out: it never tells who has an account.
    console.error("sign-in mail failed", e instanceof Error ? e.message : "unknown");
  }
  return json({ sent: true }, 202);
}

async function consumeLink(env: Env, request: Request, token: string): Promise<Response> {
  if (!sameOrigin(env, request)) throw new HttpError(403, "Wrong origin");
  const row = await env.DB.prepare(
    "UPDATE signin_links SET used_at = ? WHERE token_hash = ? AND purpose = 'signin' AND used_at IS NULL AND expires_at > ? RETURNING email, next, user_id",
  )
    .bind(Date.now(), await sha256Hex(token), Date.now())
    .first<{ email: string | null; next: string; user_id: string | null }>();
  if (!row) return page(messagePage("This link has run out", "This sign-in link has expired or was used. Ask for a new one."), undefined, 410);
  const userId = row.user_id ?? (await userByEmail(env, row.email!)).id;
  return redirect(safeNext(env, row.next), [await startWebSession(env, userId)]);
}

// --- Google (OIDC code flow with state and PKCE) ---

async function pkceVerifier(env: Env, state: string): Promise<string> {
  // Derived from the state and the server secret: nothing else to store.
  return (await hmac(env, `pkce/${state}`)) + (await hmac(env, `pkce2/${state}`));
}

async function googleStart(env: Env, request: Request, url: URL): Promise<Response> {
  if (!googleOn(env)) throw new HttpError(404, "Google sign-in is not set up");
  const next = safeNext(env, url.searchParams.get("next"));
  const state = randomToken(24);
  await oneTimeLink(env, "google", 10, { next, token: state });
  const challenge = b64url(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(await pkceVerifier(env, state))));
  const q = new URLSearchParams({
    client_id: env.GOOGLE_CLIENT_ID!,
    redirect_uri: `${env.APP_ORIGIN}/api/auth/google/callback`,
    response_type: "code",
    scope: "openid email",
    state,
    code_challenge: challenge,
    code_challenge_method: "S256",
  });
  const secure = env.APP_ORIGIN.startsWith("https://") ? "; Secure" : "";
  // The cookie ties the answer to this browser, so another person cannot send a victim a link that signs them in as someone else.
  return redirect(`${googleUrl(env, "auth")}?${q}`, [`wr_oauth=${state}; Path=/api/auth/google; HttpOnly; SameSite=Lax; Max-Age=600${secure}`]);
}

function jwtPayload(idToken: string): Record<string, unknown> | null {
  try {
    const part = idToken.split(".")[1];
    const json = atob(part.replace(/-/g, "+").replace(/_/g, "/"));
    return JSON.parse(new TextDecoder().decode(Uint8Array.from(json, (c) => c.charCodeAt(0)))) as Record<string, unknown>;
  } catch {
    return null;
  }
}

async function googleCallback(env: Env, request: Request, url: URL): Promise<Response> {
  if (!googleOn(env)) throw new HttpError(404, "Google sign-in is not set up");
  const fail = (msg: string) => page(messagePage("Sign-in did not work", msg), undefined, 400);
  const state = url.searchParams.get("state") ?? "";
  const code = url.searchParams.get("code") ?? "";
  if (url.searchParams.get("error") || !state || !code) return fail("Google did not sign you in. Go back and try again.");
  if (readCookie(request, "wr_oauth") !== state) return fail("This sign-in did not start in this browser. Go back and try again.");
  const row = await env.DB.prepare(
    "UPDATE signin_links SET used_at = ? WHERE token_hash = ? AND purpose = 'google' AND used_at IS NULL AND expires_at > ? RETURNING next",
  )
    .bind(Date.now(), await sha256Hex(state), Date.now())
    .first<{ next: string }>();
  if (!row) return fail("This sign-in ran out. Go back and try again.");

  let token: Response;
  try {
    token = await fetch(googleUrl(env, "token"), {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        code,
        client_id: env.GOOGLE_CLIENT_ID!,
        client_secret: env.GOOGLE_CLIENT_SECRET!,
        redirect_uri: `${env.APP_ORIGIN}/api/auth/google/callback`,
        grant_type: "authorization_code",
        code_verifier: await pkceVerifier(env, state),
      }),
    });
  } catch {
    return fail("Waggle could not reach Google. Try again.");
  }
  if (!token.ok) return fail("Google did not accept the sign-in. Try again.");
  // The ID token comes straight from Google's token endpoint over TLS, so its claims are read without a signature check (OIDC core 3.1.3.7).
  const claims = jwtPayload(String(((await token.json().catch(() => ({}))) as { id_token?: string }).id_token ?? ""));
  const iss = claims?.iss;
  if (
    !claims ||
    claims.aud !== env.GOOGLE_CLIENT_ID ||
    (iss !== "https://accounts.google.com" && iss !== "accounts.google.com") ||
    typeof claims.exp !== "number" ||
    claims.exp * 1000 < Date.now() ||
    typeof claims.email !== "string" ||
    typeof claims.sub !== "string"
  ) {
    return fail("Google sent an answer Waggle cannot use. Try again.");
  }
  if (claims.email_verified !== true) return fail("Google says this email address is not verified. Use an address you have verified.");
  const user = await googleUser(env, claims.email, claims.sub, typeof claims.name === "string" ? claims.name : null);
  if (!user) return fail("This email address is linked to a different Google account. Sign in with the email link instead.");
  const secure = env.APP_ORIGIN.startsWith("https://") ? "; Secure" : "";
  return redirect(safeNext(env, row.next), [await startWebSession(env, user.id), `wr_oauth=; Path=/api/auth/google; HttpOnly; SameSite=Lax; Max-Age=0${secure}`]);
}

// --- the Mac connect flow ---

async function devicePoll(env: Env, request: Request): Promise<Response> {
  const b = await body<{ device_code?: unknown }>(request);
  const code = text(b.device_code, "device_code", 100)!;
  const hash = await sha256Hex(code);
  const row = await env.DB.prepare("SELECT user_id, approved_at, collected_at, expires_at FROM device_codes WHERE device_code_hash = ?")
    .bind(hash)
    .first<{ user_id: string | null; approved_at: number | null; collected_at: number | null; expires_at: number }>();
  const gone = new HttpError(410, "This sign-in code ran out. Start again.");
  if (!row || row.collected_at || row.expires_at < Date.now()) throw gone;
  if (!row.approved_at) return json({ status: "pending" });
  // One Mac collects the token once: the update succeeds for the first poll only.
  const claim = await env.DB.prepare("UPDATE device_codes SET collected_at = ? WHERE device_code_hash = ? AND collected_at IS NULL RETURNING user_id, label")
    .bind(Date.now(), hash)
    .first<{ user_id: string; label: string }>();
  if (!claim) throw gone;
  const deviceToken = randomToken(32);
  await env.DB.prepare("INSERT INTO device_tokens (token_hash, user_id, label, created_at) VALUES (?, ?, ?, ?)")
    .bind(await sha256Hex(deviceToken), claim.user_id, claim.label, Date.now())
    .run();
  const user = await env.DB.prepare("SELECT email FROM users WHERE id = ?").bind(claim.user_id).first<{ email: string }>();
  return json({ status: "approved", device_token: deviceToken, email: user?.email ?? "" });
}

async function connectRoute(env: Env, request: Request, url: URL): Promise<Response> {
  const code = (url.searchParams.get("code") ?? "").toUpperCase().slice(0, 20);
  const user = await webUser(env, request);
  if (!user) return redirect(`/signin?next=${encodeURIComponent(safeNext(env, `/connect?code=${encodeURIComponent(code)}`))}`);
  const row = await env.DB.prepare("SELECT label FROM device_codes WHERE user_code = ? AND approved_at IS NULL AND expires_at > ?")
    .bind(code, Date.now())
    .first<{ label: string }>();
  if (!row) return page(messagePage("This code has run out", "Go back to Waggle and start the sign-in again."), undefined, 404);
  const nonce = randomToken(16);
  return page(connectPage(nonce, row.label, code, user.email), nonce);
}

// --- cleanup (the daily Cron Trigger) ---

export async function cleanup(env: Env, now = Date.now()): Promise<Record<string, number>> {
  const run = async (sql: string, ...binds: unknown[]) => (await env.DB.prepare(sql).bind(...binds).run()).meta.changes ?? 0;
  return {
    web_sessions: await run("DELETE FROM web_sessions WHERE expires_at < ?", now),
    case_sessions: await run("DELETE FROM sessions WHERE expires_at < ?", now),
    signin_links: await run("DELETE FROM signin_links WHERE used_at IS NOT NULL OR expires_at < ?", now),
    owner_links: await run("DELETE FROM sign_in_links WHERE used_at IS NOT NULL OR expires_at < ?", now),
    device_codes: await run("DELETE FROM device_codes WHERE expires_at < ? OR collected_at IS NOT NULL", now),
    // A window is at most a day long. Keep two days.
    rate_limits: await run("DELETE FROM rate_limits WHERE window < ?", now - 2 * DAY),
    dev_outbox: await run("DELETE FROM dev_outbox WHERE created_at < ?", now - DAY),
  };
}
