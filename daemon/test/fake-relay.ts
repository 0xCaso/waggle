import { createHash } from "node:crypto";

// A fake Waggle relay for tests and evidence runs (WAG-387). It listens on localhost only and keeps
// cases in memory. No test calls the real app.waggle.so.

export interface FakeRelayCall {
  method: string;
  path: string;
  auth: string | null;
  body: Record<string, unknown> | null;
}

interface FakeCase {
  id: string;
  title: string;
  mode: string;
  emails: string[];
  hash: string;
  // The last `ask` the owner sent (on create or with a round), as the page would show it.
  ask: unknown;
  rounds: { seq: number; label: string; entry: string; files: { path: string; body_base64: string }[]; content: string; ask: unknown }[];
  // WAG-394: the decision, closed comments.
  status: "open" | "decided";
  decided: unknown;
  commentsClosed: boolean;
  comments: Record<string, unknown>[];
  requestId: string | null;
  ownerEmail: string;
  deviceLabel: string;
  createdAt: number;
}

interface FakeDevice {
  token: string;
  email: string;
  label: string;
  revoked: boolean;
}

function f_bad(files: { path: string }[]): string {
  return files.find((f) => f.path.split("/").some((p) => p === ".."))!.path;
}

export class FakeRelay {
  calls: FakeRelayCall[] = [];
  cases = new Map<string, FakeCase>();
  // When set, every call answers with this status.
  failWith: number | null = null;
  // When set, a call it returns a status for answers with that status (a per-case failure).
  failWhen: ((call: FakeRelayCall) => number | null) | null = null;
  // Words the relay puts in a failure body ({"error": ...}). Null: an empty body, as a gateway sends.
  failError: string | null = null;
  // Accounts (WAG-392). Devices by token; device codes by code.
  devices = new Map<string, FakeDevice>();
  deviceCodes = new Map<string, { user_code: string; label: string; email: string | null; collected: boolean; expired: boolean }>();
  // When true, the first poll of a device code is approved at once, as <autoApproveEmail>. For tests.
  autoApprove = false;
  autoApproveEmail = "ada@example.test";
  // When true, POST /api/cases answers 429 with a plain text.
  rateLimitCases = false;
  // When set, share and PATCH answers carry these invite counts instead of "all sent".
  invites: { sent: number; failed: number; limited: number } | null = null;
  private nextDevice = 1;
  private server: ReturnType<typeof Bun.serve>;
  private nextCase = 1;

  constructor() {
    this.server = Bun.serve({ port: 0, hostname: "127.0.0.1", fetch: (req) => this.handle(req) });
  }

  get baseUrl(): string {
    return `http://127.0.0.1:${this.server.port}`;
  }

  stop(): void {
    this.server.stop(true);
  }

  // Makes a signed-in device directly (skips the flow). Returns its token.
  issueToken(email = "ada@example.test", label = "Test Mac"): string {
    const token = `dev_${this.nextDevice++}_${Math.random().toString(36).slice(2, 12)}`;
    this.devices.set(token, { token, email, label, revoked: false });
    return token;
  }

  // The person approves a code in the browser.
  approve(userCode: string, email = "ada@example.test"): void {
    for (const d of this.deviceCodes.values()) if (d.user_code === userCode) d.email = email;
  }

  // A guest's comment, as the relay's GET /comments returns it.
  addComment(caseId: string, c: Partial<Record<string, unknown>> & { id: string; created_at: number }): void {
    this.cases.get(caseId)!.comments.push({
      round_seq: 1,
      path: "index.md",
      quote: null,
      prefix: null,
      suffix: null,
      box: null,
      body: "Looks good",
      author_kind: "guest",
      author_name: "Ada",
      ...c,
    });
  }

  private async handle(req: Request): Promise<Response> {
    const url = new URL(req.url);
    const text = req.method === "GET" || req.method === "DELETE" ? "" : await req.text();
    const body = text ? (JSON.parse(text) as Record<string, unknown>) : null;
    const auth = req.headers.get("authorization");
    this.calls.push({ method: req.method, path: url.pathname + url.search, auth, body });
    const json = (v: unknown, status = 200) => Response.json(v, { status });
    if (this.failWith !== null) return json(this.failError ? { error: this.failError } : {}, this.failWith);
    const failed = this.failWhen?.(this.calls[this.calls.length - 1]!) ?? null;
    if (failed !== null) return json(this.failError ? { error: this.failError } : {}, failed);

    const bearer = auth?.replace(/^Bearer /, "") ?? "";
    const device = [...this.devices.values()].find((d) => d.token === bearer && !d.revoked) ?? null;

    if (req.method === "POST" && url.pathname === "/api/auth/device") {
      const label = typeof body?.label === "string" ? body.label.trim() : "";
      if (label === "" || label.length > 80) return json({ error: "label is missing or too long" }, 400);
      const code = `code_${this.deviceCodes.size + 1}_${Math.random().toString(36).slice(2, 10)}`;
      const userCode = `WXYZ-${String(2000 + this.deviceCodes.size)}`;
      this.deviceCodes.set(code, { user_code: userCode, label, email: null, collected: false, expired: false });
      return json({ device_code: code, user_code: userCode, verify_url: `https://app.example.test/connect?code=${userCode}`, expires_in: 600, interval: 2 }, 201);
    }
    if (req.method === "POST" && url.pathname === "/api/auth/device/poll") {
      const dc = typeof body?.device_code === "string" ? this.deviceCodes.get(body.device_code) : undefined;
      if (!dc || dc.collected || dc.expired) return json({ error: "That code ran out" }, 410);
      if (this.autoApprove && dc.email === null) dc.email = this.autoApproveEmail;
      if (dc.email === null) return json({ status: "pending" });
      dc.collected = true;
      const token = this.issueToken(dc.email, dc.label);
      return json({ status: "approved", device_token: token, email: dc.email });
    }
    if (url.pathname === "/api/me" && req.method === "GET") {
      if (!device) return json({ error: "Sign in to Waggle first.", code: "invalid_token" }, 401);
      return json({ email: device.email, name: device.email.split("@")[0] });
    }
    if (url.pathname === "/api/me/device" && req.method === "DELETE") {
      if (!device) return json({ error: "Sign in to Waggle first.", code: "invalid_token" }, 401);
      device.revoked = true;
      return json({ revoked: true });
    }
    if (url.pathname === "/api/me/cases" && req.method === "GET") {
      if (!device) return json({ error: "Sign in to Waggle first.", code: "invalid_token" }, 401);
      const cases = [...this.cases.values()]
        .filter((x) => x.ownerEmail === device.email)
        .sort((a, b) => b.createdAt - a.createdAt)
        .map((x) => ({
          id: x.id,
          title: x.title,
          url: `https://app.example.test/d/${x.id}`,
          mode: x.mode,
          created_at: x.createdAt,
          comment_count: x.comments.length,
          device_label: x.deviceLabel,
        }));
      return json({ cases });
    }

    // The rest refuses what the real relay (relay/src/index.ts) refuses, so a test cannot pass here
    // and fail in production. Keep the limits in step with the relay.
    if (req.method === "POST" && url.pathname === "/api/cases") {
      if (!device) return json({ error: "Sign in to Waggle first.", code: "invalid_token" }, 401);
      if (this.rateLimitCases) return json({ error: "You have shared too many cases today. Try again tomorrow." }, 429);
      const title = typeof body?.title === "string" ? body.title.trim() : "";
      if (title === "") return json({ error: "title is missing" }, 400);
      if (title.length > 160) return json({ error: "title is longer than 160 characters" }, 400);
      const mode = body?.mode ?? "link";
      if (mode !== "link" && mode !== "emails") return json({ error: 'mode is "link" or "emails"' }, 400);
      if (!/^[0-9a-f]{64}$/.test(String(body?.owner_key_hash))) return json({ error: "owner_key_hash is a SHA-256 hex digest" }, 400);
      const emails = Array.isArray(body?.emails) ? (body.emails as unknown[]) : [];
      if (mode === "emails" && emails.length === 0) return json({ error: "List at least one email" }, 400);
      if (emails.length > 50) return json({ error: "50 emails at most" }, 400);
      for (const e of emails) {
        if (typeof e !== "string" || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(e)) return json({ error: `${String(e)} is not an email address` }, 400);
      }
      const requestId = typeof body?.request_id === "string" ? body.request_id : null;
      if (requestId) {
        const same = [...this.cases.values()].find((x) => x.hash === body?.owner_key_hash && x.requestId === requestId);
        if (same) return json({ id: same.id, url: `https://app.example.test/d/${same.id}` }, 200);
      }
      const id = `c${this.nextCase++}x${Math.random().toString(36).slice(2, 8)}`;
      this.cases.set(id, {
        id,
        title: String(body?.title),
        mode: String(body?.mode),
        emails: (body?.emails as string[]) ?? [],
        hash: String(body?.owner_key_hash),
        ask: body?.ask ?? null,
        status: "open",
        decided: null,
        commentsClosed: false,
        rounds: [],
        comments: [],
        requestId,
        ownerEmail: device.email,
        deviceLabel: device.label,
        createdAt: Date.now(),
      });
      return json({ id, url: `https://app.example.test/d/${id}`, invites: this.invites ?? { sent: mode === "emails" ? emails.length : 0, failed: 0, limited: 0 } }, 201);
    }
    const rm = url.pathname.match(/^\/api\/cases\/([a-z0-9]+)\/comments\/([A-Za-z0-9_-]+)\/(resolve|reopen)$/);
    const m = rm ? ([rm[0], rm[1], "/resolve"] as RegExpMatchArray) : url.pathname.match(/^\/api\/cases\/([a-z0-9]+)(\/[a-z-]+)?$/);
    const c = m ? this.cases.get(m[1]!) : undefined;
    if (!m || !c) return json({ error: "Not found" }, 404);
    const keyOk = createHash("sha256").update(bearer).digest("hex") === c.hash;
    const deviceOk = device !== null && device.email === c.ownerEmail;
    // As the relay: a token that is no device and no owner key is invalid_token; a valid device of another account is not.
    if (!keyOk && !deviceOk) return device ? json({ error: "Owner access needed" }, 401) : json({ error: "Owner access needed", code: "invalid_token" }, 401);
    const action = m[2] ?? "";
    if (rm && req.method === "POST") {
      const row = c.comments.find((x) => x.id === rm[2]);
      if (!row) return json({ error: "No such comment" }, 404);
      const root = row.parent_id ? c.comments.find((x) => x.id === row.parent_id)! : row;
      root.resolved_at = rm[3] === "resolve" ? Date.now() : null;
      root.resolved_by = rm[3] === "resolve" ? "Owner" : null;
      return json({ comment: { id: root.id, resolved_at: root.resolved_at, resolved_by: root.resolved_by } });
    }
    if (req.method === "POST" && action === "/comments") {
      if (c.commentsClosed) return json({ error: "Comments are closed." }, 403);
      if (body?.author_kind !== "owner" && body?.author_kind !== "agent") return json({ error: 'author_kind is "owner" or "agent"' }, 400);
      // WAG-397: an owner comment with no parent starts a thread on a round. The real relay must accept this too.
      if (body?.parent_id === undefined || body?.parent_id === null) {
        if (body?.author_kind !== "owner") return json({ error: "parent_id is missing" }, 400);
        if (typeof body?.body !== "string" || body.body.trim() === "") return json({ error: "comment is missing" }, 400);
        const top = {
          id: `t${c.comments.length + 1}x${Math.random().toString(36).slice(2, 6)}`,
          round_seq: body.round_seq,
          path: null,
          quote: null,
          prefix: null,
          suffix: null,
          box: null,
          body: body.body,
          author_kind: "owner",
          author_name: "Ada",
          author_email: null,
          created_at: Date.now(),
          parent_id: null,
          resolved_at: null,
          resolved_by: null,
        };
        c.comments.push(top);
        return json({ comment: top }, 201);
      }
      const parent = c.comments.find((x) => x.id === body?.parent_id);
      if (!parent) return json({ error: "No such comment" }, 400);
      const root = parent.parent_id ? c.comments.find((x) => x.id === parent.parent_id)! : parent;
      if (typeof body?.body !== "string" || body.body.trim() === "") return json({ error: "comment is missing" }, 400);
      const comment = {
        id: `r${c.comments.length + 1}x${Math.random().toString(36).slice(2, 6)}`,
        round_seq: root.round_seq,
        path: root.path,
        quote: null,
        prefix: null,
        suffix: null,
        box: null,
        body: body.body,
        author_kind: body.author_kind,
        author_name: body.author_kind === "agent" ? "Agent" : "Ada",
        author_email: null,
        created_at: Date.now(),
        parent_id: root.id,
        resolved_at: null,
        resolved_by: null,
      };
      c.comments.push(comment);
      return json({ comment }, 201);
    }
    if (req.method === "PATCH" && action === "") {
      if (body?.status !== undefined && body.status !== "open" && body.status !== "decided") return json({ error: 'status is "open" or "decided"' }, 400);
      if (body?.comments_closed !== undefined && typeof body.comments_closed !== "boolean") return json({ error: "comments_closed must be true or false" }, 400);
      if (body?.ask !== undefined && (typeof body.ask !== "object" || body.ask === null || typeof (body.ask as { need?: unknown }).need !== "string")) return json({ error: "ask.need is missing" }, 400);
      if (body?.mode === undefined && body?.emails === undefined) {
        // Not the audience: the ask, the decision, closed comments.
        if (body?.ask !== undefined) {
          c.ask = body.ask;
          // As the relay: null changes no round, a number names one, else the last round.
          const target = body.round_seq === null ? undefined : typeof body.round_seq === "number" ? c.rounds.find((r) => r.seq === body.round_seq) : c.rounds[c.rounds.length - 1];
          if (target) target.ask = body.ask;
          c.status = "open";
          c.decided = null;
        }
        if (body?.status === "decided") {
          c.status = "decided";
          c.decided = body.decided ?? null;
        } else if (body?.status === "open") {
          c.status = "open";
          c.decided = null;
        }
        if (typeof body?.comments_closed === "boolean") c.commentsClosed = body.comments_closed;
        return json({ id: c.id, status: c.status, comments_closed: c.commentsClosed });
      }
      const mode = body?.mode ?? c.mode;
      if (mode !== "link" && mode !== "emails") return json({ error: 'mode is "link" or "emails"' }, 400);
      const emails = Array.isArray(body?.emails) ? (body.emails as unknown[]) : mode === "emails" ? c.emails : [];
      if (mode === "emails" && emails.length === 0) return json({ error: "List at least one email" }, 400);
      if (emails.length > 50) return json({ error: "50 emails at most" }, 400);
      for (const e of emails) {
        if (typeof e !== "string" || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(e)) return json({ error: `${String(e)} is not an email address` }, 400);
      }
      c.mode = String(mode);
      c.emails = mode === "emails" ? (emails as string[]) : [];
      return json({ id: c.id, mode: c.mode, emails: c.emails, invited: c.emails.length, invites: this.invites ?? { sent: c.emails.length, failed: 0, limited: 0 } });
    }
    if (req.method === "POST" && action === "/owner-link") return json({ url: `https://app.example.test/d/${c.id}?owner=one-time-${c.id}` });
    if (req.method === "DELETE" && action === "") {
      this.cases.delete(c.id);
      return json({ deleted: true });
    }
    if (req.method === "POST" && action === "/rounds") {
      if (body?.label !== undefined && typeof body.label !== "string") return json({ error: "label must be text" }, 400);
      if (typeof body?.label === "string" && body.label.length > 120) return json({ error: "label is longer than 120 characters" }, 400);
      if (typeof body?.entry !== "string" || body.entry.trim() === "") return json({ error: "entry is missing" }, 400);
      const files = body?.files as { path: string; body_base64: string }[] | undefined;
      if (!Array.isArray(files) || files.length === 0) return json({ error: "files are missing" }, 400);
      if (files.length > 200) return json({ error: "200 files at most" }, 400);
      let total = 0;
      for (const f of files) {
        if (typeof f?.path !== "string" || typeof f.body_base64 !== "string") return json({ error: "Each file needs a path and body_base64" }, 400);
        if (f.body_base64.length > 1_400_000) return json({ error: `${f.path} is over 1 MB` }, 413);
        total += f.body_base64.length;
      }
      if (total > 20_000_000) return json({ error: "The round is over 15 MB" }, 413);
      if (files.some((f) => f.path.split("/").some((p) => p === ".."))) return json({ error: `That path is not allowed: ${f_bad(files)}` }, 400);
      const content = createHash("sha1").update(JSON.stringify(files.map((f) => [f.path, f.body_base64]).sort())).digest("hex");
      if (body?.ask !== undefined) c.ask = body.ask;
      const again = c.rounds.find((r) => r.content === content);
      if (again) {
        if (body?.ask !== undefined) again.ask = body.ask;
        return json({ seq: again.seq, commit: `commit${again.seq}` });
      }
      const seq = c.rounds.length + 1;
      c.rounds.push({ seq, label: typeof body?.label === "string" ? body.label : "", entry: String(body?.entry), files, content, ask: body?.ask ?? null });
      if (body?.ask !== undefined) {
        c.status = "open";
        c.decided = null;
      }
      return json({ seq, commit: `commit${seq}` }, 201);
    }
    if (req.method === "GET" && action === "/comments") {
      // The cursor is (created_at, id), as in the relay. Without `after` it is the time alone, strictly later.
      const since = Number(url.searchParams.get("since") ?? 0) || 0;
      const after = url.searchParams.get("after");
      const rows = c.comments
        .filter((x) => {
          const at = x.created_at as number;
          return after === null ? at > since : at > since || (at === since && String(x.id) > after);
        })
        .sort((a, b) => (a.created_at as number) - (b.created_at as number) || (String(a.id) < String(b.id) ? -1 : 1));
      return json({
        comments: rows,
        resolved: c.comments.filter((x) => x.resolved_at).map((x) => ({ id: x.id, resolved_at: x.resolved_at, resolved_by: x.resolved_by })),
        case: { status: c.status, comments_closed: c.commentsClosed },
      });
    }
    return json({ error: "Not found" }, 404);
  }
}
