import { accountLink, accountRoutes, cleanup, clientIp, LIMITS, limit } from "./accounts";
import {
  bearer,
  caseId,
  deviceUser,
  displayName,
  keyMatches,
  randomToken,
  sameOrigin,
  sha256Hex,
  startSession,
  ticket,
  viewer,
  webUser,
  type Viewer,
} from "./auth";
import { messagePage, authHeaders } from "./authpages";
import { serveContent } from "./content";
import type { Env } from "./env";
import { FONTS } from "./fonts";
import { body, EMAIL, HttpError, json, text } from "./http";
import { inviteMail, sendMail } from "./mail";
import { casePage, notFoundPage } from "./page";
import { BadInput, cleanPath, contentId, roundStore, StoreError, type RoundFile } from "./store";

export type { Env };

const LINK_MINUTES = 15;
// The limits for the files of one round. The daemon checks the same numbers before it uploads.
const MAX_FILES = 200;
const MAX_FILE_BASE64 = 1_400_000;
const MAX_ROUND_BASE64 = 20_000_000;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    // One Worker, two origins. The content origin serves untrusted artifact files only.
    if (url.origin === env.CONTENT_ORIGIN) return serveContent(env, request, url);
    if (url.origin !== env.APP_ORIGIN) return new Response("Not found", { status: 404 });
    try {
      return await app(request, env, url);
    } catch (e) {
      if (e instanceof HttpError) return json({ error: e.message, ...(e.code ? { code: e.code } : {}) }, e.status, e.headers);
      if (e instanceof BadInput) return json({ error: e.message }, 400);
      if (e instanceof StoreError) return json({ error: e.message }, 502);
      console.error(e);
      return json({ error: "Something went wrong" }, 500);
    }
  },
  // The daily Cron Trigger: sessions, links, device codes and old limit rows.
  async scheduled(_controller: ScheduledController, env: Env, ctx: ExecutionContext): Promise<void> {
    ctx.waitUntil(cleanup(env).then((n) => console.log(`cleanup ${JSON.stringify(n)}`)));
  },
} satisfies ExportedHandler<Env>;

// The question the agent asks the team. Plain text only: the page sets it with textContent.
export type Ask = {
  need: string;
  why?: string;
  recommendation?: string;
  options?: { title: string; label: string; recommended?: boolean }[];
};

export function askOf(v: unknown): Ask | null {
  if (v === undefined || v === null) return null;
  if (typeof v !== "object" || Array.isArray(v)) throw new HttpError(400, "ask must be an object");
  const o = v as Record<string, unknown>;
  const ask: Ask = { need: text(o.need, "ask.need", 600)! };
  const why = text(o.why, "ask.why", 1000, false);
  if (why) ask.why = why;
  const recommendation = text(o.recommendation, "ask.recommendation", 300, false);
  if (recommendation) ask.recommendation = recommendation;
  if (o.options !== undefined && o.options !== null) {
    if (!Array.isArray(o.options)) throw new HttpError(400, "ask.options must be a list");
    if (o.options.length > 12) throw new HttpError(400, "ask.options has 12 options at most");
    ask.options = o.options.map((x) => {
      if (typeof x !== "object" || x === null || Array.isArray(x)) throw new HttpError(400, "ask.options must hold objects");
      const op = x as Record<string, unknown>;
      if (op.recommended !== undefined && typeof op.recommended !== "boolean") throw new HttpError(400, "ask.options.recommended must be true or false");
      const item: { title: string; label: string; recommended?: boolean } = {
        title: text(op.title, "ask.options.title", 80)!,
        label: text(op.label, "ask.options.label", 600)!,
      };
      if (op.recommended) item.recommended = true;
      return item;
    });
  }
  return ask;
}

function parseGallery(v: unknown): string[] {
  try {
    const a = typeof v === "string" ? JSON.parse(v) : [];
    return Array.isArray(a) ? a.filter((n): n is string => typeof n === "string") : [];
  } catch {
    return [];
  }
}

function parseAsk(v: unknown): Ask | null {
  try {
    return typeof v === "string" ? (JSON.parse(v) as Ask) : null;
  } catch {
    return null;
  }
}

type CaseRow = {
  id: string;
  title: string;
  mode: "link" | "emails";
  repo: string | null;
  ask?: string | null;
  owner_user_id: string | null;
  status?: "open" | "decided";
  decided?: string | null;
  comments_closed?: number;
};

async function loadCase(env: Env, id: string): Promise<CaseRow> {
  const row = await env.DB.prepare("SELECT id, title, mode, repo, ask, owner_user_id, status, decided, comments_closed FROM cases WHERE id = ?").bind(id).first<CaseRow>();
  if (!row) throw new HttpError(404, "No such case");
  return row;
}

// A stopped link answers 410 with its own words. A link that never existed answers 404.
async function loadCaseOrStopped(env: Env, id: string): Promise<CaseRow> {
  try {
    return await loadCase(env, id);
  } catch (e) {
    if (e instanceof HttpError && e.status === 404 && (await env.DB.prepare("SELECT 1 FROM stopped_cases WHERE id = ?").bind(id).first())) {
      throw new HttpError(410, STOPPED, {}, "stopped");
    }
    throw e;
  }
}

// The owner is the account that made the case (a device token, or the web session), or whoever holds the
// owner key (the WAG-391 shares, and a Mac that has the key). A web session writes only from the app's own page.
async function requireOwner(env: Env, request: Request, c: CaseRow): Promise<void> {
  if (bearer(request) !== "") {
    if (await keyMatches(env, bearer(request), c.id)) return;
    const d = await deviceUser(env, request);
    if (d && c.owner_user_id === d.id) return;
    // A token that is no device token and no owner key: the Mac must sign in again. A valid token of
    // another account gets the plain refusal below, so the Mac keeps its sign-in.
    if (!d) throw new HttpError(401, "Owner access needed", {}, "invalid_token");
  } else {
    const u = await webUser(env, request);
    if (u && c.owner_user_id === u.id) {
      if (request.method !== "GET" && !sameOrigin(env, request)) throw new HttpError(403, "Wrong origin");
      return;
    }
  }
  throw new HttpError(401, "Owner access needed");
}

// Who may read a case: anyone with the link ("link"), or a listed signed-in person ("emails").
async function reader(env: Env, request: Request, c: CaseRow): Promise<Viewer | null> {
  const v = await viewer(env, request, c);
  if (v === "outsider") throw new HttpError(403, NOT_LISTED);
  if (c.mode === "emails" && !v) throw new HttpError(401, "Sign in to open this case");
  return v;
}

const STOPPED = "Sharing for this case was stopped by its owner.";
const NOT_LISTED = "This case is shared with a list of people. You are not on it.";

// The API shows the stored "email" author as "member" (a signed-in person).
function publicKind(kind: unknown): string {
  return kind === "email" ? "member" : String(kind);
}

// Email addresses are for the case owner only. Everyone else sees the name and the kind.
function publicComment(row: Record<string, unknown>, showEmail = true): Record<string, unknown> {
  const { author_user_id: _u, author_key: _k, ...rest } = withBox(row);
  // A person without a display name is shown by their address. Others see the part before the @ only.
  const email = typeof rest.author_email === "string" ? rest.author_email : null;
  const name = !showEmail && email && rest.author_name === email ? email.split("@")[0] : rest.author_name;
  // The same rule for the person who resolved the thread: a name that is an address shows the part before the @.
  const by = typeof rest.resolved_by === "string" && !showEmail && rest.resolved_by.includes("@") ? rest.resolved_by.split("@")[0] : rest.resolved_by;
  const out = { ...rest, author_name: name, author_kind: publicKind(rest.author_kind), author_email: showEmail ? email : null };
  return "resolved_by" in rest ? { ...out, resolved_by: by } : out;
}

async function isOwner(env: Env, request: Request, c: CaseRow, v: Viewer | null): Promise<boolean> {
  if (v?.kind === "owner") return true;
  try {
    await requireOwner(env, request, c);
    return true;
  } catch (e) {
    if (e instanceof HttpError) return false;
    throw e;
  }
}

async function app(request: Request, env: Env, url: URL): Promise<Response> {
  const p = url.pathname;
  const m = request.method;
  let r: RegExpMatchArray | null;

  const account = await accountRoutes(request, env, url);
  if (account) return account;

  if (m === "GET" && (r = p.match(/^\/d\/([a-z0-9]+)$/))) {
    const c = await env.DB.prepare("SELECT id, title, mode FROM cases WHERE id = ?").bind(r[1]).first<CaseRow>();
    if (!c) {
      const gone = await env.DB.prepare("SELECT 1 FROM stopped_cases WHERE id = ?").bind(r[1]).first();
      return new Response(gone ? notFoundPage(STOPPED, "Stopped") : notFoundPage(), { status: gone ? 410 : 404, headers: htmlHeaders(env) });
    }
    const nonce = randomToken(16);
    return new Response(casePage(c, nonce), { headers: htmlHeaders(env, nonce) });
  }

  if (m === "GET" && (r = p.match(/^\/fonts\/([a-z-]+\.woff2)$/)) && FONTS[r[1]]) {
    const bytes = Uint8Array.from(atob(FONTS[r[1]]), (ch) => ch.charCodeAt(0));
    return new Response(bytes, { headers: { "content-type": "font/woff2", "cache-control": "public, max-age=31536000, immutable" } });
  }

  if (m === "GET" && (r = p.match(/^\/auth\/([a-z0-9]+)\/([A-Za-z0-9_-]+)$/))) {
    return consumeSignInLink(env, r[1], r[2]);
  }

  if (m === "POST" && p === "/api/cases") return createCase(env, request);

  // One comment: resolve or reopen its thread.
  if (m === "POST" && (r = p.match(/^\/api\/cases\/([a-z0-9]+)\/comments\/([A-Za-z0-9_-]+)\/(resolve|reopen)$/))) {
    return resolveComment(env, request, await loadCaseOrStopped(env, r[1]), r[2], r[3] === "resolve");
  }

  if (!(r = p.match(/^\/api\/cases\/([a-z0-9]+)(\/[a-z-]+)?$/))) throw new HttpError(404, "Not found");
  const id = r[1];
  const action = r[2] ?? "";
  const c = await loadCaseOrStopped(env, id);

  switch (`${m} ${action}`) {
    case "DELETE ": {
      await requireOwner(env, request, c);
      await roundStore(env).deleteRepo(id);
      await env.DB.batch([
        env.DB.prepare("INSERT OR REPLACE INTO stopped_cases (id, stopped_at) VALUES (?, ?)").bind(id, Date.now()),
        env.DB.prepare("DELETE FROM cases WHERE id = ?").bind(id),
      ]);
      return json({ deleted: true });
    }
    case "PATCH ": {
      await requireOwner(env, request, c);
      return patchCase(env, request, c);
    }
    case "POST /push-access": {
      await requireOwner(env, request, c);
      const access = await roundStore(env).pushAccess(id);
      if (!access) throw new HttpError(409, "This relay stores rounds without Git (local dev). Upload the files to /rounds.");
      return json(access);
    }
    case "POST /rounds":
      await requireOwner(env, request, c);
      return addRound(env, request, id);
    case "POST /owner-link": {
      await requireOwner(env, request, c);
      // An account case opens as the account. A WAG-391 case (owner key only) opens as the owner of that page.
      return json({ url: c.owner_user_id ? await accountLink(env, c.owner_user_id, `/d/${id}`) : await signInLink(env, id) });
    }
    case "GET /comments": {
      await requireOwner(env, request, c);
      // The cursor is (created_at, id): two comments in the same millisecond are never skipped.
      // Without `after` the cursor is the time alone, strictly later.
      const since = Number(url.searchParams.get("since") ?? 0) || 0;
      const after = url.searchParams.get("after");
      const rows = await env.DB.prepare(
        after === null
          ? "SELECT * FROM comments WHERE case_id = ? AND created_at > ? ORDER BY created_at, id"
          : "SELECT * FROM comments WHERE case_id = ? AND (created_at > ? OR (created_at = ? AND id > ?)) ORDER BY created_at, id",
      )
        .bind(...(after === null ? [id, since] : [id, since, since, after]))
        .all();
      // The state of every resolved thread comes with each answer, so the Mac sees a resolve made on the page.
      const resolved = await env.DB.prepare("SELECT id, resolved_at, resolved_by FROM comments WHERE case_id = ? AND resolved_at IS NOT NULL").bind(id).all();
      return json({
        comments: rows.results.map((row) => publicComment(row)),
        resolved: resolved.results,
        case: { status: c.status ?? "open", comments_closed: !!c.comments_closed },
      });
    }
    case "GET /state":
      return state(env, request, c);
    case "POST /guest": {
      if (!sameOrigin(env, request)) throw new HttpError(403, "Wrong origin");
      if (c.mode !== "link") throw new HttpError(403, "This case is for listed emails only");
      await limit(env, `guest:${clientIp(request)}`, LIMITS.guestsPerIp, 3600_000, "Too many people joined from this network. Try again in an hour.");
      const { name } = await body<{ name?: unknown }>(request);
      const n = guestName(name);
      await requireFreeGuestName(env, c, n);
      const cookie = await startSession(env, id, { kind: "guest", name: n, email: null });
      return json({ viewer: { kind: "guest", name: n } }, 200, { "set-cookie": cookie });
    }
    case "POST /comments": {
      // The owner's Mac posts replies with the owner key or the device token: as the owner, or as the agent.
      if (bearer(request) !== "") {
        await requireOwner(env, request, c);
        return addComment(env, request, id, null);
      }
      if (!sameOrigin(env, request)) throw new HttpError(403, "Wrong origin");
      const v = await reader(env, request, c);
      if (!v) throw new HttpError(401, "Tell us your name first");
      return addComment(env, request, id, v);
    }
  }
  throw new HttpError(404, "Not found");
}

// NFKC form, no format characters (zero-width and the like), trimmed. The checks and the store use this form.
function guestName(v: unknown): string {
  if (typeof v === "string") v = v.normalize("NFKC").replace(/\p{Cf}/gu, "");
  return text(v, "name", 60)!;
}

// A guest cannot take the name of a signed-in person on this case, or the word "owner".
async function requireFreeGuestName(env: Env, c: CaseRow, name: string): Promise<void> {
  const taken = new HttpError(400, "That name is taken. Pick another one.");
  const n = name.toLowerCase();
  if (n === "owner" || n === "agent") throw taken;
  const used = await env.DB.prepare("SELECT 1 FROM comments WHERE case_id = ? AND author_kind != 'guest' AND lower(author_name) = ?").bind(c.id, n).first();
  if (used) throw taken;
  if (c.owner_user_id) {
    const owner = await env.DB.prepare("SELECT email, name FROM users WHERE id = ?").bind(c.owner_user_id).first<{ email: string; name: string | null }>();
    if (owner && (owner.email === n || owner.name?.toLowerCase() === n)) throw taken;
  }
  const listed = await env.DB.prepare("SELECT 1 FROM case_emails WHERE case_id = ? AND email = ?").bind(c.id, n).first();
  if (listed) throw taken;
}

// --- the audience ---

function emailList(v: unknown): string[] {
  const emails = Array.isArray(v) ? v : [];
  if (emails.length > 50) throw new HttpError(400, "50 emails at most");
  return [
    ...new Set(
      emails.map((e) => {
        const s = text(e, "email", 200)!.toLowerCase();
        if (!EMAIL.test(s)) throw new HttpError(400, `${s} is not an email address`);
        return s;
      }),
    ),
  ];
}

export type Invites = { sent: number; failed: number; limited: number };

// One invite mail for each address, at most 100 mails per owner per day and 50 per call. A mail that fails
// or is over the limit does not undo the share: the answer counts them so the owner can say so.
async function invite(env: Env, c: { id: string; title: string; owner_user_id: string | null }, emails: string[]): Promise<Invites> {
  const owner = c.owner_user_id ? await env.DB.prepare("SELECT email, name FROM users WHERE id = ?").bind(c.owner_user_id).first<{ email: string; name: string | null }>() : null;
  const who = owner ? displayName(owner) : "The owner";
  const key = `invites:${c.owner_user_id ?? `case:${c.id}`}`;
  const out: Invites = { sent: 0, failed: 0, limited: 0 };
  for (const [i, to] of emails.entries()) {
    if (i >= LIMITS.invitesPerCall) {
      out.limited++;
      continue;
    }
    // Once the day is full, the rest of this call is limited without more counting.
    if (out.limited > 0) {
      out.limited++;
      continue;
    }
    try {
      await limit(env, key, LIMITS.invitesPerUserDay, 86400_000, "Invite limit reached.");
    } catch (e) {
      if (!(e instanceof HttpError)) throw e;
      out.limited++;
      continue;
    }
    try {
      await sendMail(env, inviteMail(to, who, c.title, `${env.APP_ORIGIN}/d/${c.id}`));
      out.sent++;
    } catch (e) {
      out.failed++;
      console.error("invite mail failed", e instanceof Error ? e.message : "unknown");
    }
  }
  return out;
}

const DECISION_NOTE_MAX = 2000;

// The decision the owner made. The page shows it in a "Decided" block.
export type Decision = { options: string[]; note?: string; at: number };

function decisionOf(v: unknown): Decision {
  if (v === undefined || v === null) return { options: [], at: Date.now() };
  if (typeof v !== "object" || Array.isArray(v)) throw new HttpError(400, "decided must be an object");
  const o = v as Record<string, unknown>;
  const list = o.options === undefined || o.options === null ? [] : o.options;
  if (!Array.isArray(list)) throw new HttpError(400, "decided.options must be a list");
  if (list.length > 12) throw new HttpError(400, "decided.options has 12 options at most");
  const out: Decision = { options: list.map((x) => text(x, "decided.options", 80)!), at: typeof o.at === "number" && Number.isFinite(o.at) && o.at > 0 ? Math.round(o.at) : Date.now() };
  const note = text(o.note, "decided.note", DECISION_NOTE_MAX, false);
  if (note) out.note = note;
  return out;
}

function parseDecision(v: unknown): Decision | null {
  try {
    return typeof v === "string" ? (JSON.parse(v) as Decision) : null;
  } catch {
    return null;
  }
}

// One change of a case by its owner: the audience, the ask, the decision, closed comments. Any mix of them.
async function patchCase(env: Env, request: Request, c: CaseRow): Promise<Response> {
  const b = await body<{ mode?: unknown; emails?: unknown; ask?: unknown; round_seq?: unknown; status?: unknown; decided?: unknown; comments_closed?: unknown }>(request);
  const audience = b.mode !== undefined || b.emails !== undefined;
  const ask = b.ask === undefined || b.ask === null ? null : askOf(b.ask);
  if (b.status !== undefined && b.status !== "open" && b.status !== "decided") throw new HttpError(400, 'status is "open" or "decided"');
  if (b.comments_closed !== undefined && typeof b.comments_closed !== "boolean") throw new HttpError(400, "comments_closed must be true or false");
  if (!audience && !ask && b.status === undefined && b.comments_closed === undefined) throw new HttpError(400, "Send a mode, a list of emails, an ask, a status or comments_closed");

  const statements: D1PreparedStatement[] = [];
  let reply: Record<string, unknown> = { id: c.id };
  let added: string[] = [];
  if (audience) {
    const mode = b.mode === undefined ? c.mode : b.mode;
    if (mode !== "link" && mode !== "emails") throw new HttpError(400, 'mode is "link" or "emails"');
    const current = (await env.DB.prepare("SELECT email FROM case_emails WHERE case_id = ?").bind(c.id).all<{ email: string }>()).results.map((r) => r.email);
    const next = mode === "link" ? [] : b.emails === undefined ? current : emailList(b.emails);
    if (mode === "emails" && next.length === 0) throw new HttpError(400, "List at least one email");
    added = next.filter((e) => !current.includes(e));
    const removed = current.filter((e) => !next.includes(e));
    statements.push(
      env.DB.prepare("UPDATE cases SET mode = ? WHERE id = ?").bind(mode, c.id),
      ...removed.map((e) => env.DB.prepare("DELETE FROM case_emails WHERE case_id = ? AND email = ?").bind(c.id, e)),
      ...added.map((e) => env.DB.prepare("INSERT INTO case_emails (case_id, email) VALUES (?, ?)").bind(c.id, e)),
    );
    // Guests have no place in a list: their sessions end when the case goes to emails mode.
    if (mode === "emails") statements.push(env.DB.prepare("DELETE FROM sessions WHERE case_id = ? AND kind = 'guest'").bind(c.id));
    reply = { ...reply, mode, emails: next };
  }
  // A new need or new options reopen the case, unless the same call says which status it has.
  let status = b.status as "open" | "decided" | undefined;
  if (ask) {
    statements.push(env.DB.prepare("UPDATE cases SET ask = ? WHERE id = ?").bind(JSON.stringify(ask), c.id));
    // The round the ask belongs to: the one `round_seq` names, none for null (a follow-up that has no artifact yet,
    // so no round of its own to change), else the last round.
    if (b.round_seq !== null) {
      if (b.round_seq !== undefined && !Number.isInteger(b.round_seq)) throw new HttpError(400, "round_seq must be a whole number or null");
      if (b.round_seq !== undefined && !(await env.DB.prepare("SELECT 1 FROM rounds WHERE case_id = ? AND seq = ?").bind(c.id, b.round_seq).first())) {
        throw new HttpError(400, "That case has no such round");
      }
      statements.push(
        b.round_seq === undefined
          ? env.DB.prepare("UPDATE rounds SET ask = ? WHERE case_id = ? AND seq = (SELECT MAX(seq) FROM rounds WHERE case_id = ?)").bind(JSON.stringify(ask), c.id, c.id)
          : env.DB.prepare("UPDATE rounds SET ask = ? WHERE case_id = ? AND seq = ?").bind(JSON.stringify(ask), c.id, b.round_seq),
      );
    }
    status ??= "open";
  }
  if (status === "decided") statements.push(env.DB.prepare("UPDATE cases SET status = 'decided', decided = ? WHERE id = ?").bind(JSON.stringify(decisionOf(b.decided)), c.id));
  else if (status === "open") statements.push(env.DB.prepare("UPDATE cases SET status = 'open', decided = NULL WHERE id = ?").bind(c.id));
  if (b.comments_closed !== undefined) statements.push(env.DB.prepare("UPDATE cases SET comments_closed = ? WHERE id = ?").bind(b.comments_closed ? 1 : 0, c.id));
  await env.DB.batch(statements);

  if (audience) {
    const invites = await invite(env, c, added);
    reply = { ...reply, invited: invites.sent, invites };
  }
  if (audience && !ask && b.status === undefined && b.comments_closed === undefined) return json(reply);
  const now = await env.DB.prepare("SELECT status, comments_closed FROM cases WHERE id = ?").bind(c.id).first<{ status: string; comments_closed: number }>();
  return json({ ...reply, status: now?.status ?? "open", comments_closed: !!now?.comments_closed });
}

function htmlHeaders(env: Env, nonce?: string): HeadersInit {
  const script = nonce ? `'nonce-${nonce}'` : "'none'";
  return {
    "content-type": "text/html; charset=utf-8",
    "content-security-policy": `default-src 'self'; script-src ${script}; style-src 'unsafe-inline'; font-src 'self'; frame-src ${env.CONTENT_ORIGIN}; connect-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'self'`,
    "cache-control": "no-store",
    "x-frame-options": "DENY",
    "referrer-policy": "no-referrer",
  };
}

async function createCase(env: Env, request: Request): Promise<Response> {
  // A case needs an account: the Mac signs in first (the device flow).
  const owner = await deviceUser(env, request);
  if (!owner) throw new HttpError(401, "Sign in to Waggle first.");
  const b = await body<{ title?: unknown; mode?: unknown; emails?: unknown; owner_key_hash?: unknown; ask?: unknown; request_id?: unknown }>(request);
  const title = text(b.title, "title", 160)!;
  const mode = b.mode === undefined ? "link" : b.mode;
  if (mode !== "link" && mode !== "emails") throw new HttpError(400, 'mode is "link" or "emails"');
  const hash = text(b.owner_key_hash, "owner_key_hash", 64)!;
  if (!/^[0-9a-f]{64}$/.test(hash)) throw new HttpError(400, "owner_key_hash is a SHA-256 hex digest");
  const ask = askOf(b.ask);
  const emails = Array.isArray(b.emails) ? b.emails : [];
  if (mode === "emails" && emails.length === 0) throw new HttpError(400, "List at least one email");
  const list = emailList(emails);

  // A retried share (the answer was lost) sends the same request_id and gets the same case back.
  const requestId = text(b.request_id, "request_id", 64, false);
  const store = roundStore(env);
  const made = (row: { id: string; mode: string; repo: string | null }, status: number, invites?: Invites) =>
    json({ id: row.id, url: `${env.APP_ORIGIN}/d/${row.id}`, mode: row.mode, store: store.kind, repo: row.repo, ...(invites ? { invites } : {}) }, status);
  const findSame = () =>
    requestId
      ? env.DB.prepare("SELECT id, mode, repo FROM cases WHERE owner_key_hash = ? AND request_id = ?").bind(hash, requestId).first<{ id: string; mode: string; repo: string | null }>()
      : Promise.resolve(null);
  const same = await findSame();
  if (same) return made(same, 200);
  await limit(env, `cases:${owner.id}`, LIMITS.casesPerUserDay, 86400_000, "You shared 30 cases today. Try again tomorrow.");

  const id = caseId();
  const repo = await store.createRepo(id);
  try {
    await env.DB.batch([
      env.DB.prepare("INSERT INTO cases (id, title, mode, owner_key_hash, repo, created_at, ask, request_id, owner_user_id, device_label) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)").bind(
        id,
        title,
        mode,
        hash,
        repo,
        Date.now(),
        ask ? JSON.stringify(ask) : null,
        requestId,
        owner.id,
        owner.label,
      ),
      ...[...new Set(list)].map((e) => env.DB.prepare("INSERT INTO case_emails (case_id, email) VALUES (?, ?)").bind(id, e)),
    ]);
  } catch (e) {
    // The batch failed: do not leave an orphaned repo. A parallel retry with the same id may have won.
    await store.deleteRepo(id).catch(() => {});
    const winner = await findSame();
    if (winner) return made(winner, 200);
    throw e;
  }
  // Each listed person gets one invite mail. A failed mail does not undo the share.
  const invites = mode === "emails" ? await invite(env, { id, title, owner_user_id: owner.id }, list) : { sent: 0, failed: 0, limited: 0 };
  return made({ id, mode, repo }, 201, invites);
}

async function addRound(env: Env, request: Request, id: string): Promise<Response> {
  const b = await body<{ label?: unknown; variant?: unknown; entry?: unknown; commit?: unknown; files?: RoundFile[]; ask?: unknown; gallery?: unknown }>(request);
  const ask = askOf(b.ask);
  const gallery = galleryOf(b.gallery);
  // The artifact name. Without one the page shows just "Round <seq>".
  const label = text(b.label, "label", 120, false) ?? "";
  const variant = text(b.variant, "variant", 60, false) ?? "main";
  const entry = cleanPath(text(b.entry, "entry", 300)!);
  const store = roundStore(env);
  let commitId: string;
  let content: string | null = null;
  if (b.files !== undefined) {
    if (!Array.isArray(b.files) || b.files.length === 0) throw new HttpError(400, "files are missing");
    if (b.files.length > MAX_FILES) throw new HttpError(400, `${MAX_FILES} files at most`);
    let total = 0;
    for (const f of b.files) {
      if (typeof f?.path !== "string" || typeof f.body_base64 !== "string") throw new HttpError(400, "Each file needs a path and body_base64");
      if (f.body_base64.length > MAX_FILE_BASE64) throw new HttpError(413, `${f.path} is over 1 MB`);
      total += f.body_base64.length;
    }
    if (total > MAX_ROUND_BASE64) throw new HttpError(413, "The round is over 15 MB");
    content = await contentId(b.files);
    const again = await env.DB.prepare("SELECT seq, commit_id FROM rounds WHERE case_id = ? AND content_id = ?").bind(id, content).first<{ seq: number; commit_id: string }>();
    if (again) {
      if (ask) await setAsk(env, id, ask, again.seq);
      return json({ seq: again.seq, commit: again.commit_id });
    }
    commitId = await store.putRound(id, b.files, { variant, label: label || "Round" });
  } else {
    if (store.kind === "d1") throw new HttpError(400, "files are missing");
    commitId = text(b.commit, "commit", 40)!;
    if (!/^[0-9a-f]{40}$/.test(commitId)) throw new HttpError(400, "commit is a 40-character Git commit id");
    if (!(await store.hasCommit(id, commitId))) throw new HttpError(400, "That commit is not in the case's repo. Push it first.");
  }
  // The latest ask wins, also when the files are the same round as before.
  const existing = await env.DB.prepare("SELECT seq FROM rounds WHERE case_id = ? AND commit_id = ?").bind(id, commitId).first<{ seq: number }>();
  if (existing) {
    if (ask) await setAsk(env, id, ask, existing.seq);
    return json({ seq: existing.seq, commit: commitId });
  }
  const last = await env.DB.prepare("SELECT MAX(seq) AS seq FROM rounds WHERE case_id = ?").bind(id).first<{ seq: number | null }>();
  const seq = (last?.seq ?? 0) + 1;
  await env.DB.prepare(
    "INSERT INTO rounds (case_id, seq, commit_id, label, variant, entry, created_at, content_id, ask, gallery) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
  )
    .bind(id, seq, commitId, label, variant, entry, Date.now(), content, ask ? JSON.stringify(ask) : null, gallery ? JSON.stringify(gallery) : null)
    .run();
  // A new round with an ask is a new question: the case is open again.
  if (ask) await env.DB.prepare("UPDATE cases SET ask = ?, status = 'open', decided = NULL WHERE id = ?").bind(JSON.stringify(ask), id).run();
  return json({ seq, commit: commitId }, 201);
}

// The names of the images of a screenshots round, in order. Plain file names only; the page lists them in the link.
function galleryOf(v: unknown): string[] | null {
  if (v === undefined || v === null) return null;
  if (!Array.isArray(v) || v.length > 12) throw new HttpError(400, "gallery is a list of 12 names at most");
  return v.map((n) => {
    if (typeof n !== "string" || !/^[A-Za-z0-9._-]{1,100}$/.test(n)) throw new HttpError(400, "gallery holds plain file names");
    return n;
  });
}

// The ask of a round that exists. The case keeps the latest ask too.
async function setAsk(env: Env, id: string, ask: Ask, seq: number): Promise<void> {
  await env.DB.batch([
    env.DB.prepare("UPDATE cases SET ask = ? WHERE id = ?").bind(JSON.stringify(ask), id),
    env.DB.prepare("UPDATE rounds SET ask = ? WHERE case_id = ? AND seq = ?").bind(JSON.stringify(ask), id, seq),
  ]);
}

const IMAGE_ENTRY = /\.(png|jpe?g|gif|webp|svg)$/i;

async function state(env: Env, request: Request, c: CaseRow): Promise<Response> {
  const v = await reader(env, request, c);
  const owner = await isOwner(env, request, c, v);
  const rounds = await env.DB.prepare(
    "SELECT seq, commit_id, label, variant, entry, created_at, ask, gallery FROM rounds WHERE case_id = ? ORDER BY seq",
  )
    .bind(c.id)
    .all<{ seq: number; commit_id: string; label: string; variant: string; entry: string; created_at: number; ask: string | null; gallery: string | null }>();
  const withSrc = await Promise.all(
    rounds.results.map(async ({ ask, gallery, ...r }) => {
      const names = parseGallery(gallery);
      return {
        ...r,
        ask: parseAsk(ask),
        // An image or a diagram opens in a wrapper page that has the area script. The query asks for it, and
        // for a screenshots round it lists the other images.
        src: `${env.CONTENT_ORIGIN}/t/${await ticket(env, c.id, r.commit_id)}/${c.id}/${r.commit_id}/${r.entry.split("/").map(encodeURIComponent).join("/")}${IMAGE_ENTRY.test(r.entry) ? `?view=1${names.length > 1 ? `&g=${names.map(encodeURIComponent).join(",")}` : ""}` : ""}`,
      };
    }),
  );
  const comments = await env.DB.prepare(
    "SELECT id, round_seq, path, quote, box, body, author_kind, author_name, author_email, created_at, parent_id, resolved_at, resolved_by, author_key FROM comments WHERE case_id = ? ORDER BY created_at, id",
  )
    .bind(c.id)
    .all<Record<string, unknown>>();
  return json({
    id: c.id,
    title: c.title,
    mode: c.mode,
    ask: parseAsk(c.ask),
    status: c.status ?? "open",
    decided: parseDecision(c.decided),
    comments_closed: !!c.comments_closed,
    viewer: v ? { kind: v.kind, name: v.name, email: v.email, signed_in: v.signedIn } : null,
    rounds: withSrc,
    comments: comments.results.map((row) => {
      // The owner and the author of the first comment of a thread may resolve it.
      const can = !!v && (owner || (!row.parent_id && !!row.author_key && row.author_key === v.limitKey));
      return { ...publicComment(row, owner), can_resolve: can };
    }),
  });
}

// A comment on the page. v = the person; null = the owner's Mac (owner key or device token), which writes
// as the owner (a new thread or a reply) or as the agent (a reply only).
async function addComment(env: Env, request: Request, id: string, v: Viewer | null): Promise<Response> {
  const b = await body<{ round_seq?: unknown; path?: unknown; quote?: unknown; prefix?: unknown; suffix?: unknown; box?: unknown; body?: unknown; parent_id?: unknown; author_kind?: unknown }>(request);
  const closed = await env.DB.prepare("SELECT comments_closed AS closed, owner_user_id FROM cases WHERE id = ?").bind(id).first<{ closed: number; owner_user_id: string | null }>();
  // Closed comments stop members and guests. The owner and the agent may still reply.
  if (closed?.closed && v && v.kind !== "owner") throw new HttpError(403, "Comments are closed.");
  let who: { kind: string; name: string; email: string | null; userId: string | null; key: string };
  if (v) who = { kind: v.kind === "member" ? "email" : v.kind, name: v.name, email: v.email, userId: v.userId, key: v.limitKey };
  else {
    if (b.author_kind !== "owner" && b.author_kind !== "agent") throw new HttpError(400, 'author_kind is "owner" or "agent"');
    if (b.author_kind === "agent" && (b.parent_id === undefined || b.parent_id === null)) throw new HttpError(400, "parent_id is missing");
    if (b.author_kind === "agent") who = { kind: "agent", name: "Agent", email: null, userId: null, key: `agent:${id}` };
    else {
      const user = closed?.owner_user_id ? await env.DB.prepare("SELECT id, email, name FROM users WHERE id = ?").bind(closed.owner_user_id).first<{ id: string; email: string; name: string | null }>() : null;
      who = { kind: "owner", name: user ? displayName(user) : "Owner", email: user?.email ?? null, userId: user?.id ?? null, key: user ? `u:${user.id}` : `owner:${id}` };
    }
  }

  // A reply goes under the first comment of its thread, whichever comment it answers.
  let root: { id: string; round_seq: number; commit_id: string; path: string | null } | null = null;
  if (b.parent_id !== undefined && b.parent_id !== null) {
    const pid = text(b.parent_id, "parent_id", 64)!;
    const parent = await env.DB.prepare("SELECT id, parent_id, round_seq, commit_id, path FROM comments WHERE id = ? AND case_id = ?").bind(pid, id).first<{ id: string; parent_id: string | null; round_seq: number; commit_id: string; path: string | null }>();
    if (!parent) throw new HttpError(400, "No such comment");
    root = parent.parent_id
      ? await env.DB.prepare("SELECT id, round_seq, commit_id, path FROM comments WHERE id = ? AND case_id = ?").bind(parent.parent_id, id).first<{ id: string; round_seq: number; commit_id: string; path: string | null }>()
      : parent;
    if (!root) throw new HttpError(400, "No such comment");
  }
  const seq = root ? root.round_seq : Number(b.round_seq);
  const round = await env.DB.prepare("SELECT commit_id, entry FROM rounds WHERE case_id = ? AND seq = ?")
    .bind(id, Number.isInteger(seq) ? seq : -1)
    .first<{ commit_id: string; entry: string }>();
  if (!round) throw new HttpError(400, "No such round");
  await limit(env, `comments:${who.key}`, LIMITS.commentsPerPersonHour, 3600_000, "You posted a lot of comments. Try again in a while.");
  // The cap counts and blocks member and guest comments only. Owner and agent replies are never blocked by it.
  const count = await env.DB.prepare("SELECT COUNT(*) AS n FROM comments WHERE case_id = ? AND author_kind IN ('email', 'guest')").bind(id).first<{ n: number }>();
  if (v && v.kind !== "owner" && (count?.n ?? 0) >= LIMITS.commentsPerCase) throw new HttpError(429, `This case has reached its limit of ${LIMITS.commentsPerCase} comments.`);
  const comment = {
    id: randomToken(9),
    round_seq: seq,
    commit_id: root ? root.commit_id : round.commit_id,
    path: root ? root.path : (text(b.path, "path", 300, false) ?? round.entry),
    // A reply points at nothing: its thread already does.
    quote: root ? null : text(b.quote, "quote", 1000, false),
    prefix: !root && typeof b.prefix === "string" ? b.prefix.slice(0, 64) : null,
    suffix: !root && typeof b.suffix === "string" ? b.suffix.slice(0, 64) : null,
    box: root ? null : areaOf(b.box),
    body: text(b.body, "comment", 4000)!,
    author_kind: who.kind,
    author_name: who.name,
    author_email: who.email,
    author_user_id: who.userId,
    author_key: who.key,
    parent_id: root ? root.id : null,
    created_at: Date.now(),
  };
  await env.DB.prepare(
    `INSERT INTO comments (id, case_id, round_seq, commit_id, path, quote, prefix, suffix, box, body, author_kind, author_name, created_at, author_email, author_user_id, parent_id, author_key)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  )
    .bind(
      comment.id,
      id,
      comment.round_seq,
      comment.commit_id,
      comment.path,
      comment.quote,
      comment.prefix,
      comment.suffix,
      comment.box ? JSON.stringify(comment.box) : null,
      comment.body,
      comment.author_kind,
      comment.author_name,
      comment.created_at,
      comment.author_email,
      comment.author_user_id,
      comment.parent_id,
      comment.author_key,
    )
    .run();
  return json({ comment: publicComment(comment) }, 201);
}

// Resolve or reopen a thread. The owner and the author of its first comment may do it.
async function resolveComment(env: Env, request: Request, c: CaseRow, commentId: string, resolve: boolean): Promise<Response> {
  const row = await env.DB.prepare("SELECT id, parent_id, author_key FROM comments WHERE id = ? AND case_id = ?").bind(commentId, c.id).first<{ id: string; parent_id: string | null; author_key: string | null }>();
  if (!row) throw new HttpError(404, "No such comment");
  const root = row.parent_id ? await env.DB.prepare("SELECT id, author_key FROM comments WHERE id = ? AND case_id = ?").bind(row.parent_id, c.id).first<{ id: string; author_key: string | null }>() : row;
  if (!root) throw new HttpError(404, "No such comment");
  let by: string;
  if (bearer(request) !== "") {
    await requireOwner(env, request, c);
    const user = c.owner_user_id ? await env.DB.prepare("SELECT email, name FROM users WHERE id = ?").bind(c.owner_user_id).first<{ email: string; name: string | null }>() : null;
    by = user ? displayName(user) : "Owner";
  } else {
    if (!sameOrigin(env, request)) throw new HttpError(403, "Wrong origin");
    const v = await reader(env, request, c);
    if (!v) throw new HttpError(401, "Tell us your name first");
    if (!(await isOwner(env, request, c, v)) && !(root.author_key && root.author_key === v.limitKey)) {
      throw new HttpError(403, "Only the owner or the person who wrote it can resolve this.");
    }
    by = v.name;
  }
  await env.DB.prepare("UPDATE comments SET resolved_at = ?, resolved_by = ? WHERE id = ?").bind(resolve ? Date.now() : null, resolve ? by : null, root.id).run();
  const out = await env.DB.prepare("SELECT id, resolved_at, resolved_by FROM comments WHERE id = ?").bind(root.id).first();
  return json({ comment: out });
}

// An area the reader dragged over the page, in document CSS pixels. Optional.
type Area = { x: number; y: number; w: number; h: number; vw: number; near: string };
const MAX_PX = 100_000;

function areaOf(v: unknown): Area | null {
  if (v == null) return null;
  if (typeof v !== "object") throw new HttpError(400, "Bad area");
  const o = v as Record<string, unknown>;
  const n = (k: string, min: number) => {
    const x = o[k];
    if (typeof x !== "number" || !Number.isFinite(x) || x < min || x > MAX_PX) throw new HttpError(400, "Bad area");
    return Math.round(x);
  };
  return { x: n("x", 0), y: n("y", 0), w: n("w", 4), h: n("h", 4), vw: n("vw", 1), near: typeof o.near === "string" ? o.near.trim().slice(0, 200) : "" };
}

function withBox(row: Record<string, unknown>): Record<string, unknown> {
  return { ...row, box: typeof row.box === "string" ? JSON.parse(row.box) : null };
}

// A one-time link for an owner-key case (WAG-391): it opens the page as the owner.
async function signInLink(env: Env, id: string): Promise<string> {
  const token = randomToken();
  await env.DB.prepare("INSERT INTO sign_in_links (token_hash, case_id, kind, email, expires_at) VALUES (?, ?, 'owner', NULL, ?)")
    .bind(await sha256Hex(token), id, Date.now() + LINK_MINUTES * 60_000)
    .run();
  return `${env.APP_ORIGIN}/auth/${id}/${token}`;
}

async function consumeSignInLink(env: Env, id: string, token: string): Promise<Response> {
  const hash = await sha256Hex(token);
  // One use only: the update succeeds for the first request and for no other.
  const row = await env.DB.prepare(
    "UPDATE sign_in_links SET used_at = ? WHERE token_hash = ? AND case_id = ? AND kind = 'owner' AND used_at IS NULL AND expires_at > ? RETURNING kind",
  )
    .bind(Date.now(), hash, id, Date.now())
    .first<{ kind: string }>();
  if (!row) {
    return new Response(messagePage("This link has run out", "This sign-in link has expired or was used. Ask for a new one."), { status: 410, headers: authHeaders() });
  }
  const cookie = await startSession(env, id, { kind: "owner", name: "Owner", email: null });
  return new Response(null, { status: 303, headers: { location: `/d/${id}`, "set-cookie": cookie } });
}
