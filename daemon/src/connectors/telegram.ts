import { z } from "zod";
import type { TelegramStatus } from "../protocol";
import type { Store } from "../store";
import type { SecretStore } from "./secrets";
import { makeCode, safeEqual, sleep } from "./util";
import type {
  AnswerResult,
  AskMessage,
  Connector,
  ConnectorHost,
  OutcomeMessage,
  SentMessage,
} from "./types";

// The Telegram connector (HAIL-144). The daemon calls the Bot API directly and only outbound:
// getUpdates long polling plus sendMessage, editMessageText and answerCallbackQuery. No listener,
// no webhook, no relay for chat. Off until the operator connects it. The Telegram connector calls only
// the base URL below (api.telegram.org). Sharing a case (WAG-387) is a separate opt-in with its own host.

export const TELEGRAM_BASE_URL = "https://api.telegram.org";
const SECRET_NAME = "telegram-bot-token";

// A bot token looks like 123456789:AAH... (digits, a colon, a secret). Returns plain words for the
// operator when the text cannot be one, or null. Looks only at the shape, never at the network.
export function telegramTokenProblem(token: string): string | null {
  if (/^\d{3,}:[A-Za-z0-9_-]{6,}$/.test(token)) return null;
  if (/^(xoxb|xapp)-/.test(token)) return "That is a Slack token. Telegram bot tokens look like 123456789:ABC... Copy it from BotFather.";
  return "That does not look like a bot token. It has digits, a colon, then letters and numbers, like 123456789:ABC... Copy it from BotFather again.";
}

// Shown to the operator in plain words. Never holds the token or the request URL.
export class TelegramError extends Error {
  constructor(
    message: string,
    public status?: number,
  ) {
    super(message);
  }
}

const Saved = z.object({
  bot_name: z.string(),
  bot_username: z.string().nullable(),
  chat_id: z.number().optional(),
  chat_label: z.string().optional(),
});
type Saved = z.infer<typeof Saved>;

// What this connector keeps for each ask message: where it is, and the option ids behind the
// buttons (a tap carries the index, so callback_data stays under Telegram's 64 byte limit).
interface TelegramRef {
  chat_id: number;
  message_id: number;
  options: string[];
}

interface TgUpdate {
  update_id: number;
  message?: {
    message_id: number;
    chat: { id: number; type: string; first_name?: string; title?: string; username?: string };
    text?: string;
    reply_to_message?: { message_id: number };
  };
  callback_query?: {
    id: string;
    data?: string;
    message?: { message_id: number; chat: { id: number } };
  };
}

export interface TelegramOptions {
  store: Store;
  secrets: SecretStore;
  host: ConnectorHost;
  baseUrl?: string;
  // Tests pass a fetch that talks to a fake Bot API. Never a real one.
  fetch?: typeof fetch;
  // getUpdates long-poll length, in seconds.
  pollTimeoutS?: number;
  // A pause after an empty poll. 0 in production: Telegram holds the call itself.
  idleDelayMs?: number;
  // The first pause after a failed poll; it doubles up to 30 s.
  retryDelayMs?: number;
  log?: (line: string) => void;
}

export class TelegramConnector implements Connector {
  readonly id = "telegram" as const;
  private token: string | null = null;
  private saved: Saved | null = null;
  private code: string | null = null;
  private lastError: string | null = null;
  private offset: number | undefined;
  private abort: AbortController | null = null;
  private loop: Promise<void> | null = null;
  private baseUrl: string;
  private doFetch: typeof fetch;
  private pollTimeoutS: number;
  private idleDelayMs: number;
  private retryDelayMs: number;
  private log: (line: string) => void;

  constructor(private opts: TelegramOptions) {
    this.baseUrl = opts.baseUrl ?? TELEGRAM_BASE_URL;
    this.doFetch = opts.fetch ?? fetch;
    this.pollTimeoutS = opts.pollTimeoutS ?? 25;
    this.idleDelayMs = opts.idleDelayMs ?? 0;
    this.retryDelayMs = opts.retryDelayMs ?? 2000;
    this.log = opts.log ?? ((line) => process.stderr.write(`${line}\n`));
  }

  // --- Connector ---

  isActive(): boolean {
    return this.token !== null && this.saved?.chat_id !== undefined;
  }

  // Resume from the Keychain and the saved setting. With nothing saved: no call at all.
  start(): void {
    this.saved = this.opts.store.getConnectorSetting("telegram", Saved);
    this.token = this.saved ? this.opts.secrets.get(SECRET_NAME) : null;
    if (!this.token) this.saved = null;
    this.ensureLoop();
  }

  stop(): void {
    this.abort?.abort();
  }

  async disconnect(): Promise<void> {
    this.reset();
    this.opts.secrets.delete(SECRET_NAME);
    this.opts.store.setConnectorSetting("telegram", null);
    this.lastError = null;
  }

  status(): TelegramStatus {
    const state = !this.token || !this.saved
      ? "off"
      : this.saved.chat_id !== undefined
        ? "connected"
        : this.code !== null
          ? "waiting_for_start"
          : "token_checked";
    return {
      state,
      bot_name: this.saved?.bot_name ?? null,
      bot_username: this.saved?.bot_username ?? null,
      chat_label: this.saved?.chat_label ?? null,
      code: state === "waiting_for_start" ? this.code : null,
      error: this.lastError,
    };
  }

  // --- connect steps (RPC) ---

  // Step 2: ask Telegram who the bot is. A good token goes to the Keychain.
  async checkToken(token: string): Promise<TelegramStatus> {
    const wrong = telegramTokenProblem(token);
    if (wrong) throw new TelegramError(wrong);
    const me = await this.call<{ first_name: string; username?: string }>(token, "getMe", {});
    this.reset();
    this.opts.secrets.set(SECRET_NAME, token);
    this.token = token;
    this.saved = { bot_name: me.first_name, bot_username: me.username ?? null };
    this.opts.store.setConnectorSetting("telegram", this.saved);
    this.lastError = null;
    return this.status();
  }

  // Step 3: make the one-time code and watch for `/start <code>`.
  startPairing(): TelegramStatus {
    if (!this.token || !this.saved) throw new TelegramError("Paste the bot token first.");
    this.saved = { bot_name: this.saved.bot_name, bot_username: this.saved.bot_username };
    this.opts.store.setConnectorSetting("telegram", this.saved);
    this.code = makeCode();
    this.lastError = null;
    this.ensureLoop();
    return this.status();
  }

  async sendTest(): Promise<void> {
    const chat = this.saved?.chat_id;
    if (!this.token || chat === undefined) throw new TelegramError("Connect a chat first.");
    await this.call(this.token, "sendMessage", {
      chat_id: chat,
      text: "Waggle test: this chat is connected. New decisions will show up here.",
    });
  }

  async sendAsk(ask: AskMessage): Promise<SentMessage | null> {
    const chat = this.saved?.chat_id;
    if (!this.token || chat === undefined) return null;
    const buttons: { text: string; callback_data: string }[][] = [];
    if (ask.select === "one") {
      ask.options.forEach((o, i) => {
        buttons.push([{ text: o.title, callback_data: `o:${ask.case_id}:${i}` }]);
      });
    }
    buttons.push([{ text: "Ask for more detail", callback_data: `d:${ask.case_id}` }]);
    const lines = [ask.title, ...(ask.work_line ? [ask.work_line] : []), "", ask.need_line];
    if (ask.recommendation) {
      lines.push("", `Recommended: ${ask.recommendation}${ask.recommendation_why ? `. ${ask.recommendation_why}` : ""}`);
    }
    if (ask.artifact_word) lines.push("", `Open Waggle on your Mac to see the ${ask.artifact_word}.`);
    lines.push(
      "",
      ask.options.length === 0
        ? "Reply to this message to answer."
        : ask.select === "many"
          ? "This decision takes more than one pick. Reply to this message with your answer, or open Waggle on your Mac."
          : "Tap an option, or reply to this message to answer in your own words.",
    );
    const sent = await this.call<{ message_id: number }>(this.token, "sendMessage", {
      chat_id: chat,
      text: lines.join("\n").slice(0, 4000),
      reply_markup: { inline_keyboard: buttons },
    });
    const ref: TelegramRef = { chat_id: chat, message_id: sent.message_id, options: ask.options.map((o) => o.id) };
    return { key: `${chat}:${sent.message_id}`, ref };
  }

  async updateOutcome(sent: SentMessage, outcome: OutcomeMessage): Promise<void> {
    if (!this.token) return;
    const ref = sent.ref as TelegramRef;
    try {
      await this.call(this.token, "editMessageText", {
        chat_id: ref.chat_id,
        message_id: ref.message_id,
        text: `${outcome.title}\n\n${outcome.text}`.slice(0, 4000),
        reply_markup: { inline_keyboard: [] },
      });
    } catch (err) {
      // Telegram refuses an edit that changes nothing. Not a problem.
      if (!/not modified/i.test((err as Error).message)) throw err;
    }
  }

  // --- Bot API ---

  // One Bot API call. The URL holds the token, so no error ever carries it.
  private async call<T>(token: string, method: string, body: object, signal?: AbortSignal): Promise<T> {
    let res: Response;
    try {
      res = await this.doFetch(`${this.baseUrl}/bot${token}/${method}`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(body),
        ...(signal ? { signal } : {}),
      });
    } catch {
      throw new TelegramError("Could not reach Telegram. Check your connection.");
    }
    let json: { ok?: boolean; result?: T; description?: string; error_code?: number };
    try {
      json = (await res.json()) as typeof json;
    } catch {
      throw new TelegramError(`Telegram sent an answer Waggle could not read (HTTP ${res.status}).`, res.status);
    }
    if (!json.ok) {
      const status = json.error_code ?? res.status;
      const text =
        status === 401 || status === 404
          ? "Telegram did not accept that token. Check it and try again."
          : (json.description ?? `Telegram said no (HTTP ${status}).`);
      throw new TelegramError(text, status);
    }
    return json.result as T;
  }

  // --- receiving ---

  private wantsPolling(): boolean {
    return this.token !== null && this.saved !== null && (this.saved.chat_id !== undefined || this.code !== null);
  }

  private ensureLoop(): void {
    if (this.loop || !this.wantsPolling()) return;
    const abort = new AbortController();
    this.abort = abort;
    this.loop = this.runLoop(abort.signal).finally(() => {
      this.loop = null;
    });
  }

  private async runLoop(signal: AbortSignal): Promise<void> {
    let delay = 0;
    while (!signal.aborted && this.wantsPolling() && this.token) {
      try {
        const updates = await this.call<TgUpdate[]>(
          this.token,
          "getUpdates",
          {
            ...(this.offset !== undefined ? { offset: this.offset } : {}),
            timeout: this.pollTimeoutS,
            allowed_updates: ["message", "callback_query"],
          },
          AbortSignal.any([signal, AbortSignal.timeout((this.pollTimeoutS + 20) * 1000)]),
        );
        this.lastError = null;
        delay = 0;
        for (const update of updates) {
          this.offset = update.update_id + 1;
          try {
            await this.handle(update);
          } catch (err) {
            this.log(`waggle: telegram update failed: ${(err as Error).message}`);
          }
        }
        if (updates.length === 0 && this.idleDelayMs > 0) await sleep(this.idleDelayMs, signal);
      } catch (err) {
        if (signal.aborted) return;
        const e = err as TelegramError;
        if (e.status === 401) {
          this.lastError = "Telegram no longer accepts this token. Disconnect and connect again.";
          return;
        }
        this.lastError = e.message;
        delay = Math.min(delay === 0 ? this.retryDelayMs : delay * 2, 30_000);
        await sleep(delay, signal);
      }
    }
  }

  // Stops the poll and forgets the in-memory connection (not the saved one).
  private reset(): void {
    this.abort?.abort();
    this.token = null;
    this.saved = null;
    this.code = null;
    this.offset = undefined;
  }

  private async handle(update: TgUpdate): Promise<void> {
    if (update.callback_query) return this.onCallback(update.callback_query);
    if (update.message) return this.onMessage(update.message);
  }

  private async onMessage(m: NonNullable<TgUpdate["message"]>): Promise<void> {
    const token = this.token;
    if (!token || !this.saved) return;
    // Pairing: only `/start <code>` from a private chat, and only the right code.
    if (this.saved.chat_id === undefined) {
      const match = /^\/start(?:@\w+)?\s+(\S+)\s*$/.exec(m.text ?? "");
      if (this.code === null || !match || m.chat.type !== "private" || !safeEqual(match[1]!, this.code)) return;
      const label = m.chat.first_name ?? m.chat.title ?? m.chat.username ?? "your chat";
      this.saved = { ...this.saved, chat_id: m.chat.id, chat_label: label };
      this.code = null;
      this.opts.store.setConnectorSetting("telegram", this.saved);
      await this.call(token, "sendMessage", {
        chat_id: m.chat.id,
        text: "Connected. Waggle will send new decisions here. Tap a button or reply to answer.",
      }).catch(() => {});
      return;
    }
    // Only the saved chat counts. Everything else is ignored.
    if (m.chat.id !== this.saved.chat_id) return;
    const text = m.text?.trim();
    if (!text || !m.reply_to_message) return;
    const caseId = this.opts.host.caseForMessage("telegram", `${m.chat.id}:${m.reply_to_message.message_id}`);
    if (!caseId) return;
    const result = this.opts.host.answer("telegram", {
      case_id: caseId,
      key: `msg:${m.chat.id}:${m.message_id}`,
      message: text.slice(0, 4000),
    });
    if (!result.ok) {
      await this.call(token, "sendMessage", {
        chat_id: m.chat.id,
        reply_to_message_id: m.message_id,
        text: failureText(result),
      }).catch(() => {});
    }
  }

  private async onCallback(q: NonNullable<TgUpdate["callback_query"]>): Promise<void> {
    const token = this.token;
    if (!token || this.saved?.chat_id === undefined) return;
    if (q.message?.chat.id !== this.saved.chat_id) return;
    const reply = (text: string): Promise<unknown> =>
      this.call(token, "answerCallbackQuery", { callback_query_id: q.id, text }).catch(() => {});
    const [kind, caseId, index] = (q.data ?? "").split(":");
    if (!caseId || (kind !== "o" && kind !== "d")) return void (await reply("Waggle did not understand that."));
    let result: AnswerResult;
    if (kind === "d") {
      result = this.opts.host.answer("telegram", {
        case_id: caseId,
        key: `cb:${caseId}:detail`,
        intent: "more_detail",
      });
    } else {
      const ref = this.opts.host.messageRef("telegram", caseId) as TelegramRef | null;
      const choice = ref?.options[Number(index)];
      if (choice === undefined) return void (await reply("That option is gone."));
      result = this.opts.host.answer("telegram", { case_id: caseId, key: `cb:${caseId}:${index}`, choice });
    }
    await reply(result.ok ? (result.duplicate ? "Already sent" : "Sent") : failureText(result));
  }
}

function failureText(result: Extract<AnswerResult, { ok: false }>): string {
  switch (result.reason) {
    case "closed":
      return "That decision is already answered.";
    case "not_offered":
      return "That option is no longer offered.";
    case "unknown_case":
      return "Waggle cannot find that decision.";
  }
}
