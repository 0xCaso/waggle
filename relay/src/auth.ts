import type { Env } from "./env";

const enc = new TextEncoder();

export function randomToken(bytes = 24): string {
  const b = crypto.getRandomValues(new Uint8Array(bytes));
  return btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

// Case ids go in links, so they are short and easy to read.
export function caseId(): string {
  const alphabet = "abcdefghijkmnpqrstuvwxyz23456789";
  const b = crypto.getRandomValues(new Uint8Array(10));
  return [...b].map((x) => alphabet[x % alphabet.length]).join("");
}

export async function sha256Hex(s: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", enc.encode(s));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export type User = { id: string; email: string; name: string | null };

// The owner key never reaches the relay's database: only its SHA-256 hash.
export async function keyMatches(env: Env, key: string, id: string): Promise<boolean> {
  if (key === "") return false;
  const row = await env.DB.prepare("SELECT owner_key_hash FROM cases WHERE id = ?").bind(id).first<{ owner_key_hash: string }>();
  if (!row) return false;
  return timingSafeEqual(row.owner_key_hash, await sha256Hex(key));
}

export function bearer(request: Request): string {
  const header = request.headers.get("authorization") ?? "";
  return header.startsWith("Bearer ") ? header.slice(7).trim() : "";
}

// The account behind a device token (a Mac that signed in). Null for a missing, unknown or revoked token.
export async function deviceUser(env: Env, request: Request): Promise<(User & { label: string }) | null> {
  const token = bearer(request);
  if (token === "") return null;
  const hash = await sha256Hex(token);
  const row = await env.DB.prepare(
    "SELECT u.id AS id, u.email AS email, u.name AS name, d.label AS label FROM device_tokens d JOIN users u ON u.id = d.user_id WHERE d.token_hash = ? AND d.revoked_at IS NULL",
  )
    .bind(hash)
    .first<User & { label: string }>();
  if (!row) return null;
  await env.DB.prepare("UPDATE device_tokens SET last_used_at = ? WHERE token_hash = ?").bind(Date.now(), hash).run();
  return row;
}

export type Viewer = {
  kind: "guest" | "member" | "owner";
  name: string;
  email: string | null;
  userId: string | null;
  // Counts this person's comments for the rate limit.
  limitKey: string;
  // True when an account session is behind it (the page shows Sign out).
  signedIn: boolean;
};

export const SESSION_DAYS = 30;

export function cookieName(id: string) {
  return `wr_${id}`;
}

export const WEB_COOKIE = "wr_session";

// The account behind the web session cookie.
export async function webUser(env: Env, request: Request): Promise<User | null> {
  const token = readCookie(request, WEB_COOKIE);
  if (!token) return null;
  return env.DB.prepare(
    "SELECT u.id AS id, u.email AS email, u.name AS name FROM web_sessions s JOIN users u ON u.id = s.user_id WHERE s.token_hash = ? AND s.expires_at > ?",
  )
    .bind(await sha256Hex(token), Date.now())
    .first<User>();
}

export async function startWebSession(env: Env, userId: string): Promise<string> {
  const token = randomToken();
  const now = Date.now();
  await env.DB.prepare("INSERT INTO web_sessions (token_hash, user_id, created_at, expires_at) VALUES (?, ?, ?, ?)")
    .bind(await sha256Hex(token), userId, now, now + SESSION_DAYS * 86400_000)
    .run();
  return webCookie(env, token, SESSION_DAYS * 86400);
}

export async function endWebSession(env: Env, request: Request): Promise<string> {
  const token = readCookie(request, WEB_COOKIE);
  if (token) await env.DB.prepare("DELETE FROM web_sessions WHERE token_hash = ?").bind(await sha256Hex(token)).run();
  return webCookie(env, "", 0);
}

// HttpOnly, SameSite=Lax, 30 days. Secure on https (the relay's real address); plain localhost has no https.
export function webCookie(env: Env, token: string, maxAge: number): string {
  const secure = env.APP_ORIGIN.startsWith("https://") ? "; Secure" : "";
  return `${WEB_COOKIE}=${token}; Path=/; HttpOnly; SameSite=Lax; Max-Age=${maxAge}${secure}`;
}

export function displayName(u: { email: string; name: string | null }): string {
  return u.name ?? u.email;
}

type CaseAccess = { id: string; mode: "link" | "emails"; owner_user_id: string | null };

// Who is looking at a case. "outsider" = signed in, but not on the list of an emails case.
// A signed-in person is always their account: the owner, or a member. Without an account the per-case
// cookie gives a guest (link mode) or the owner of a case that has only an owner key.
export async function viewer(env: Env, request: Request, c: CaseAccess): Promise<Viewer | "outsider" | null> {
  const user = await webUser(env, request);
  if (user) {
    const base = { name: displayName(user), email: user.email, userId: user.id, limitKey: `u:${user.id}`, signedIn: true };
    if (c.owner_user_id === user.id) return { kind: "owner", ...base };
    if (c.mode === "link") return { kind: "member", ...base };
    const listed = await env.DB.prepare("SELECT 1 FROM case_emails WHERE case_id = ? AND email = ?").bind(c.id, user.email).first();
    if (listed) return { kind: "member", ...base };
  }
  const token = readCookie(request, cookieName(c.id));
  if (token) {
    const row = await env.DB.prepare("SELECT kind, name, email, token_hash FROM sessions WHERE token_hash = ? AND case_id = ? AND expires_at > ?")
      .bind(await sha256Hex(token), c.id, Date.now())
      .first<{ kind: "guest" | "email" | "owner"; name: string | null; email: string | null; token_hash: string }>();
    // A guest session counts only while the case is in link mode. An emails case never accepts one.
    const allowed =
      row &&
      (row.kind === "owner" ||
        (row.kind === "guest" && c.mode === "link") ||
        (row.kind === "email" && !!(await env.DB.prepare("SELECT 1 FROM case_emails WHERE case_id = ? AND email = ?").bind(c.id, row.email).first())));
    if (row && allowed) {
      return {
        kind: row.kind === "email" ? "member" : row.kind,
        name: row.name ?? row.email ?? "Someone",
        email: row.email,
        userId: null,
        limitKey: `s:${row.token_hash.slice(0, 16)}`,
        signedIn: false,
      };
    }
  }
  return user ? "outsider" : null;
}

export async function startSession(
  env: Env,
  id: string,
  v: { kind: "guest" | "owner"; name: string; email: string | null },
): Promise<string> {
  const token = randomToken();
  const now = Date.now();
  await env.DB.prepare(
    "INSERT INTO sessions (token_hash, case_id, kind, name, email, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
  )
    .bind(await sha256Hex(token), id, v.kind, v.name, v.email, now, now + SESSION_DAYS * 86400_000)
    .run();
  return sessionCookie(env, id, token, SESSION_DAYS * 86400);
}

export function sessionCookie(env: Env, id: string, token: string, maxAge: number): string {
  const secure = env.APP_ORIGIN.startsWith("https://") ? "; Secure" : "";
  return `${cookieName(id)}=${token}; Path=/; HttpOnly; SameSite=Lax; Max-Age=${maxAge}${secure}`;
}

export function readCookie(request: Request, name: string): string | null {
  const header = request.headers.get("cookie") ?? "";
  for (const part of header.split(";")) {
    const [k, ...v] = part.trim().split("=");
    if (k === name) return v.join("=");
  }
  return null;
}

// A cookie-authenticated write must come from the app's own page.
export function sameOrigin(env: Env, request: Request): boolean {
  const origin = request.headers.get("origin");
  if (origin === env.APP_ORIGIN) return true;
  // A form post from a no-referrer page sends `Origin: null`; the browser's Sec-Fetch-Site still
  // says where it came from, and a page cannot set that header.
  return (origin === null || origin === "null") && request.headers.get("sec-fetch-site") === "same-origin";
}

// Content tickets: the content origin has no cookies, so the page gives the iframe a signed,
// short-lived path prefix for one round. Relative links inside the bundle keep the prefix.
export const TICKET_SECONDS = 3600;

export async function hmac(env: Env, data: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", enc.encode(env.TICKET_SECRET), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", key, enc.encode(data));
  return btoa(String.fromCharCode(...new Uint8Array(sig))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export async function ticket(env: Env, id: string, commitId: string, now = Date.now()): Promise<string> {
  const exp = Math.floor(now / 1000) + TICKET_SECONDS;
  return `${exp}.${await hmac(env, `${id}/${commitId}/${exp}`)}`;
}

export async function checkTicket(env: Env, t: string, id: string, commitId: string, now = Date.now()): Promise<boolean> {
  const [expText, sig] = t.split(".");
  const exp = Number(expText);
  if (!Number.isFinite(exp) || !sig || exp * 1000 < now) return false;
  return timingSafeEqual(sig, await hmac(env, `${id}/${commitId}/${exp}`));
}
