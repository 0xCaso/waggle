// A fake Slack for tests and evidence runs (HAIL-145): Web API over HTTP and Socket Mode over a
// WebSocket, in one local server. It listens on 127.0.0.1 only. No test and no evidence run ever
// calls the real slack.com.

export interface FakeSlackCall {
  method: string;
  token: string;
  body: Record<string, unknown>;
}

type Sock = Bun.ServerWebSocket<unknown>;

export class FakeSlack {
  calls: FakeSlackCall[] = [];
  // Every chat.postMessage Waggle made, with the ts the fake gave it.
  posted: { ts: string; body: Record<string, unknown> }[] = [];
  validAppToken = "xapp-1-TEST-app-token";
  validBotToken = "xoxb-TEST-bot-token";
  workspace = "Acme Inc";
  botName = "knock";
  userId = "U0SAM";
  userName = "Sam";
  dmChannel = "D0SAM";
  // Envelope ids Waggle acked, and when.
  acks: { id: string; at: number }[] = [];
  // Whether the socket says hello. Off makes the Socket Mode check fail.
  sayHello = true;
  private sockets = new Set<Sock>();
  private nextTs = 1;
  private nextEnvelope = 1;
  private server: ReturnType<typeof Bun.serve>;
  // How many sockets were ever opened.
  opened = 0;

  constructor() {
    this.server = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch: (req, server) => this.handle(req, server),
      websocket: {
        open: (ws) => {
          this.sockets.add(ws);
          this.opened++;
          if (this.sayHello) ws.send(JSON.stringify({ type: "hello", num_connections: this.sockets.size }));
        },
        message: (_ws, raw) => {
          const msg = JSON.parse(String(raw)) as { envelope_id?: string };
          if (msg.envelope_id) this.acks.push({ id: msg.envelope_id, at: Date.now() });
        },
        close: (ws) => {
          this.sockets.delete(ws);
        },
      },
    });
  }

  get baseUrl(): string {
    return `http://127.0.0.1:${this.server.port}`;
  }

  get socketUrl(): string {
    return `ws://127.0.0.1:${this.server.port}/link`;
  }

  get connections(): number {
    return this.sockets.size;
  }

  stop(): void {
    for (const s of this.sockets) s.close();
    this.server.stop(true);
  }

  // --- what Slack does to the socket ---

  /** Drops every socket without a goodbye, like a network drop. */
  drop(): void {
    for (const s of [...this.sockets]) s.close(1006);
  }

  /** Slack asks the app to reconnect (a refresh). */
  refresh(): void {
    for (const s of this.sockets) s.send(JSON.stringify({ type: "disconnect", reason: "refresh_requested" }));
  }

  private envelope(type: string, payload: unknown): string {
    const id = `env-${this.nextEnvelope++}`;
    const data = JSON.stringify({ type, envelope_id: id, accepts_response_payload: false, payload });
    for (const s of this.sockets) s.send(data);
    return id;
  }

  // --- what the operator does in Slack ---

  /** A DM to the bot. `thread` makes it a reply in that message's thread. */
  dm(text: string, opts: { user?: string; channel?: string; thread?: string; extra?: Record<string, unknown> } = {}): string {
    const ts = `1700000${String(this.nextTs++).padStart(3, "0")}.000200`;
    this.envelope("events_api", {
      type: "event_callback",
      event: {
        type: "message",
        channel_type: "im",
        channel: opts.channel ?? this.dmChannel,
        user: opts.user ?? this.userId,
        text,
        ts,
        ...(opts.thread ? { thread_ts: opts.thread } : {}),
        ...opts.extra,
      },
    });
    return ts;
  }

  /** A button press on a message Waggle posted. Returns the envelope id. */
  press(ts: string, actionId: string, value: string, opts: { user?: string; channel?: string } = {}): string {
    return this.envelope("interactive", {
      type: "block_actions",
      user: { id: opts.user ?? this.userId },
      channel: { id: opts.channel ?? this.dmChannel },
      container: { type: "message", message_ts: ts },
      message: { ts },
      actions: [{ action_id: actionId, value, type: "button" }],
    });
  }

  // --- what Waggle did ---

  called(method: string): FakeSlackCall[] {
    return this.calls.filter((c) => c.method === method);
  }

  private async handle(req: Request, server: Bun.Server): Promise<Response | undefined> {
    const url = new URL(req.url);
    if (url.pathname === "/link") {
      return server.upgrade(req) ? undefined : new Response("upgrade failed", { status: 400 });
    }
    const m = /^\/api\/([\w.]+)$/.exec(url.pathname);
    if (!m) return Response.json({ ok: false, error: "unknown_method" }, { status: 404 });
    const method = m[1]!;
    const token = (req.headers.get("authorization") ?? "").replace(/^Bearer /, "");
    const body = (await req.json().catch(() => ({}))) as Record<string, unknown>;
    this.calls.push({ method, token, body });
    const wantsToken = method === "apps.connections.open" ? this.validAppToken : this.validBotToken;
    if (token !== wantsToken) return Response.json({ ok: false, error: "invalid_auth" });
    switch (method) {
      case "auth.test":
        return Response.json({ ok: true, team: this.workspace, team_id: "T0ACME", user: this.botName, user_id: "UBOT", bot_id: "BBOT" });
      case "bots.info":
        return Response.json({ ok: true, bot: { id: "BBOT", app_id: "A0KNOCK" } });
      case "apps.connections.open":
        return Response.json({ ok: true, url: this.socketUrl });
      case "conversations.open":
        return Response.json({ ok: true, channel: { id: this.dmChannel } });
      case "users.info":
        return Response.json({ ok: true, user: { id: this.userId, name: "sam", real_name: this.userName, profile: { display_name: "" } } });
      case "chat.postMessage": {
        const ts = `1800000${String(this.nextTs++).padStart(3, "0")}.000100`;
        this.posted.push({ ts, body });
        return Response.json({ ok: true, channel: body.channel, ts });
      }
      case "chat.update":
        return Response.json({ ok: true, channel: body.channel, ts: body.ts });
      default:
        return Response.json({ ok: false, error: "unknown_method" });
    }
  }
}
