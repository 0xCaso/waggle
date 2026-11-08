// A fake Telegram Bot API for tests and evidence runs (HAIL-144). It listens on localhost only.
// No test and no evidence run ever calls the real api.telegram.org.

export interface FakeCall {
  method: string;
  token: string;
  body: Record<string, unknown>;
}

export class FakeTelegram {
  calls: FakeCall[] = [];
  // Every message Waggle sent, with the id the fake gave it.
  sent: { message_id: number; body: Record<string, unknown> }[] = [];
  validToken = "123456:TEST-token";
  botName = "Waggle Test Bot";
  botUsername = "knock_test_bot";
  private updates: Record<string, unknown>[] = [];
  private nextUpdateId = 100;
  private nextMessageId = 500;
  private server: ReturnType<typeof Bun.serve>;
  // How long an empty getUpdates is held, standing in for Telegram's long poll.
  holdMs = 40;

  constructor() {
    this.server = Bun.serve({ port: 0, hostname: "127.0.0.1", fetch: (req) => this.handle(req) });
  }

  get baseUrl(): string {
    return `http://127.0.0.1:${this.server.port}`;
  }

  stop(): void {
    this.server.stop(true);
  }

  // --- what the operator does in the chat ---

  private push(update: Record<string, unknown>): void {
    this.updates.push({ update_id: this.nextUpdateId++, ...update });
  }

  sendText(chatId: number, text: string, extra: Record<string, unknown> = {}): number {
    const message_id = this.nextMessageId++;
    this.push({
      message: {
        message_id,
        chat: { id: chatId, type: "private", first_name: "Sam" },
        text,
        ...extra,
      },
    });
    return message_id;
  }

  replyTo(chatId: number, messageId: number, text: string): number {
    return this.sendText(chatId, text, { reply_to_message: { message_id: messageId } });
  }

  tap(chatId: number, messageId: number, data: string): void {
    this.push({
      callback_query: { id: `cq${this.nextUpdateId}`, data, message: { message_id: messageId, chat: { id: chatId } } },
    });
  }

  // --- what Waggle did ---

  called(method: string): FakeCall[] {
    return this.calls.filter((c) => c.method === method);
  }

  private async handle(req: Request): Promise<Response> {
    const m = /^\/bot([^/]+)\/(\w+)$/.exec(new URL(req.url).pathname);
    if (!m) return Response.json({ ok: false, error_code: 404, description: "Not Found" }, { status: 404 });
    const token = decodeURIComponent(m[1]!);
    const method = m[2]!;
    const body = (await req.json().catch(() => ({}))) as Record<string, unknown>;
    this.calls.push({ method, token, body });
    if (token !== this.validToken) {
      return Response.json({ ok: false, error_code: 401, description: "Unauthorized" }, { status: 401 });
    }
    switch (method) {
      case "getMe":
        return Response.json({ ok: true, result: { id: 1, is_bot: true, first_name: this.botName, username: this.botUsername } });
      case "getUpdates": {
        const offset = typeof body.offset === "number" ? body.offset : 0;
        this.updates = this.updates.filter((u) => (u.update_id as number) >= offset);
        const deadline = Date.now() + this.holdMs;
        while (this.updates.length === 0 && Date.now() < deadline) await Bun.sleep(5);
        return Response.json({ ok: true, result: this.updates.slice() });
      }
      case "sendMessage": {
        const message_id = this.nextMessageId++;
        this.sent.push({ message_id, body });
        return Response.json({ ok: true, result: { message_id } });
      }
      case "editMessageText":
      case "answerCallbackQuery":
        return Response.json({ ok: true, result: true });
      default:
        return Response.json({ ok: false, error_code: 400, description: "unknown method" }, { status: 400 });
    }
  }
}

export async function until(check: () => boolean, ms = 3000): Promise<void> {
  const end = Date.now() + ms;
  while (!check()) {
    if (Date.now() > end) throw new Error("timed out waiting for the condition");
    await Bun.sleep(10);
  }
}
