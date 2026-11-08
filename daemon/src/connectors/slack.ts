import { z } from "zod";
import type { SlackStatus } from "../protocol";
import type { Store } from "../store";
import type { SecretStore } from "./secrets";
import type {
  AnswerResult,
  AskMessage,
  Connector,
  ConnectorHost,
  OutcomeMessage,
  SentMessage,
} from "./types";
import { makeCode, safeEqual, sleep } from "./util";

// The Slack connector (HAIL-145). Socket Mode: the daemon opens an outbound WebSocket
// (apps.connections.open gives the wss-*.slack.com URL) and calls the Web API for chat.postMessage,
// chat.update and conversations.open. No listener, no webhook, no relay. Off until the operator
// connects it. The daemon talks only to slack.com and wss-*.slack.com, and only after connecting.

export const SLACK_BASE_URL = "https://slack.com";
const APP_SECRET = "slack-app-token";
const BOT_SECRET = "slack-bot-token";

// Shown to the operator in plain words. Never holds a token.
export class SlackError extends Error {
  constructor(
    message: string,
    public status?: number,
    public code?: string,
  ) {
    super(message);
  }
}

// The Slack app the operator creates from this manifest (api.slack.com/apps, "From a manifest").
// Socket Mode and interactivity are on. The bot reads only DMs sent to it.
export function slackManifest(): string {
  return JSON.stringify(
    {
      display_information: {
        name: "Waggle",
        description: "Sends the decisions from your coding agents to you, and takes your answers back.",
      },
      features: {
        app_home: { home_tab_enabled: false, messages_tab_enabled: true, messages_tab_read_only_enabled: false },
        bot_user: { display_name: "Waggle", always_online: false },
      },
      oauth_config: { scopes: { bot: ["chat:write", "im:write", "im:history", "users:read"] } },
      settings: {
        event_subscriptions: { bot_events: ["message.im"] },
        interactivity: { is_enabled: true },
        org_deploy_enabled: false,
        socket_mode_enabled: true,
        token_rotation_enabled: false,
      },
    },
    null,
    2,
  );
}

const Saved = z.object({
  workspace: z.string(),
  bot_name: z.string(),
  // Ids for the deep links (HAIL-148). Optional: an older saved setting has none.
  team_id: z.string().optional(),
  bot_user_id: z.string().optional(),
  app_id: z.string().optional(),
  user_id: z.string().optional(),
  user_label: z.string().optional(),
  channel_id: z.string().optional(),
});
type Saved = z.infer<typeof Saved>;

// What this connector keeps for each ask message: where it is (`ts` is Slack's message id), and the
// option ids behind the buttons (a press carries the index).
interface SlackRef {
  channel: string;
  ts: string;
  options: string[];
}

interface Envelope {
  type?: string;
  envelope_id?: string;
  reason?: string;
  payload?: {
    type?: string;
    event?: SlackMessageEvent;
    user?: { id?: string };
    channel?: { id?: string };
    actions?: { action_id?: string; value?: string }[];
  };
}

interface SlackMessageEvent {
  type?: string;
  channel_type?: string;
  channel?: string;
  user?: string;
  text?: string;
  ts?: string;
  thread_ts?: string;
  subtype?: string;
  bot_id?: string;
}

export interface SlackSocket {
  onmessage: ((ev: { data: unknown }) => void) | null;
  onclose: (() => void) | null;
  onerror: (() => void) | null;
  send(data: string): void;
  close(): void;
}

export interface SlackOptions {
  store: Store;
  secrets: SecretStore;
  host: ConnectorHost;
  baseUrl?: string;
  // Tests pass a fetch and a WebSocket that talk to a fake Slack. Never a real one.
  fetch?: typeof fetch;
  // Replaces the wss URL that apps.connections.open returns.
  socketUrl?: string;
  webSocket?: (url: string) => SlackSocket;
  // The first pause after a failed connection; it doubles up to 30 s.
  retryDelayMs?: number;
  // A short pause before a new connection after a good one ended (a refresh or a drop).
  reconnectDelayMs?: number;
  // How long a new socket may take to say hello.
  helloTimeoutMs?: number;
  log?: (line: string) => void;
}

// Slack's own error codes in plain words for the operator.
export function isAppToken(t: string): boolean {
  return t.startsWith("xapp-");
}
export function isBotToken(t: string): boolean {
  return t.startsWith("xoxb-");
}

// What is wrong with the two pasted tokens, in plain words naming the field, or null when each
// has the right prefix. Never holds a token.
export function wrongFieldMessage(appToken: string, botToken: string): string | null {
  if (isBotToken(appToken)) {
    return "The app-level token starts with xapp-. The one in that box starts with xoxb-, which is the bot token. Put it in the bot token box.";
  }
  if (!isAppToken(appToken)) return "The app-level token starts with xapp-. Check the one you pasted.";
  if (isAppToken(botToken)) {
    return "The bot token starts with xoxb-. The one in that box starts with xapp-, which is the app-level token. Put it in the app-level box.";
  }
  if (!isBotToken(botToken)) return "The bot token starts with xoxb-. Check the one you pasted.";
  return null;
}

function wordsFor(code: string, needed?: string): string {
  switch (code) {
    case "invalid_auth":
    case "not_authed":
    case "token_revoked":
    case "token_expired":
    case "account_inactive":
      return "Slack did not accept that token. Check it and try again.";
    case "missing_scope":
      return `The Slack app is missing a permission${needed ? ` (${needed})` : ""}. Create the app again from the manifest.`;
    case "not_allowed_token_type":
      return "Slack did not accept that kind of token. Use the app-level token (xapp-) and the bot token (xoxb-).";
    case "channel_not_found":
    case "is_archived":
      return "Slack cannot find the chat with your bot. Disconnect and connect again.";
    default:
      return `Slack said: ${code.replace(/_/g, " ")}.`;
  }
}

const FATAL_CODES = new Set(["invalid_auth", "not_authed", "token_revoked", "token_expired", "account_inactive"]);

export class SlackConnector implements Connector {
  readonly id = "slack" as const;
  private appToken: string | null = null;
  private botToken: string | null = null;
  private saved: Saved | null = null;
  private code: string | null = null;
  private lastError: string | null = null;
  // The app id from the last look-up, before the tokens are checked. Memory only.
  private hintAppId: string | null = null;
  private abort: AbortController | null = null;
  private loop: Promise<void> | null = null;
  private baseUrl: string;
  private doFetch: typeof fetch;
  private retryDelayMs: number;
  private reconnectDelayMs: number;
  private helloTimeoutMs: number;
  private log: (line: string) => void;

  constructor(private opts: SlackOptions) {
    this.baseUrl = opts.baseUrl ?? SLACK_BASE_URL;
    this.doFetch = opts.fetch ?? fetch;
    this.retryDelayMs = opts.retryDelayMs ?? 2000;
    this.reconnectDelayMs = opts.reconnectDelayMs ?? 1000;
    this.helloTimeoutMs = opts.helloTimeoutMs ?? 15_000;
    this.log = opts.log ?? ((line) => process.stderr.write(`${line}\n`));
  }

  // --- Connector ---

  isActive(): boolean {
    return this.botToken !== null && this.appToken !== null && this.saved?.channel_id !== undefined;
  }

  // Resume from the Keychain and the saved setting. With nothing saved: no call at all.
  start(): void {
    this.saved = this.opts.store.getConnectorSetting("slack", Saved);
    this.appToken = this.saved ? this.opts.secrets.get(APP_SECRET) : null;
    this.botToken = this.saved ? this.opts.secrets.get(BOT_SECRET) : null;
    if (!this.appToken || !this.botToken) {
      this.appToken = this.botToken = this.saved = null;
    }
    this.ensureLoop();
  }

  stop(): void {
    this.abort?.abort();
  }

  async disconnect(): Promise<void> {
    this.reset();
    this.opts.secrets.delete(APP_SECRET);
    this.opts.secrets.delete(BOT_SECRET);
    this.opts.store.setConnectorSetting("slack", null);
    this.lastError = null;
  }

  status(): SlackStatus {
    const state =
      !this.botToken || !this.appToken || !this.saved
        ? "off"
        : this.saved.channel_id !== undefined
          ? "connected"
          : this.code !== null
            ? "waiting_for_start"
            : "token_checked";
    return {
      state,
      workspace: this.saved?.workspace ?? null,
      bot_name: this.saved?.bot_name ?? null,
      user_label: this.saved?.user_label ?? null,
      app_id: this.saved?.app_id ?? this.hintAppId,
      team_id: this.saved?.team_id ?? null,
      bot_user_id: this.saved?.bot_user_id ?? null,
      code: state === "waiting_for_start" ? this.code : null,
      manifest: slackManifest(),
      error: this.lastError,
    };
  }

  // --- connect steps (RPC) ---

  // Step 2: check both tokens. auth.test names the workspace and the bot; apps.connections.open and
  // a short Socket Mode connection prove the app token and that Socket Mode is on. Good tokens go to
  // the Keychain.
  async checkTokens(appTokenIn: string, botTokenIn: string): Promise<SlackStatus> {
    // Both pasted in the wrong boxes: fix it without a fuss.
    const swapped = isBotToken(appTokenIn) && isAppToken(botTokenIn);
    const appToken = swapped ? botTokenIn : appTokenIn;
    const botToken = swapped ? appTokenIn : botTokenIn;
    const wrong = wrongFieldMessage(appToken, botToken);
    if (wrong) throw new SlackError(wrong);
    const auth = await this.api<{ team?: string; team_id?: string; user?: string; user_id?: string; bot_id?: string }>(
      botToken,
      "auth.test",
      {},
    );
    const appId = await this.appIdFor(botToken, auth.bot_id);
    const url = await this.socketUrl(appToken);
    const probe = new AbortController();
    const result = await this.session(url, probe.signal, { onHello: () => probe.abort() });
    if (!result.hello) {
      throw new SlackError("Waggle could not open a Socket Mode connection. Check that Socket Mode is on for the app.");
    }
    this.reset();
    this.opts.secrets.set(APP_SECRET, appToken);
    this.opts.secrets.set(BOT_SECRET, botToken);
    this.appToken = appToken;
    this.botToken = botToken;
    this.saved = {
      workspace: auth.team ?? "your workspace",
      bot_name: auth.user ?? "Waggle",
      ...(auth.team_id ? { team_id: auth.team_id } : {}),
      ...(auth.user_id ? { bot_user_id: auth.user_id } : {}),
      ...(appId ? { app_id: appId } : {}),
    };
    this.opts.store.setConnectorSetting("slack", this.saved);
    this.lastError = null;
    return this.status();
  }

  // The app's id, from the bot token alone, so Settings can link the app's own page before the
  // app-level token exists. Saves nothing. A failed look-up answers null, never an error: the
  // link then goes to the list of apps.
  async lookUpApp(botTokenIn: string): Promise<SlackStatus> {
    const botToken = botTokenIn.trim();
    if (!isBotToken(botToken)) throw new SlackError(wrongFieldMessage("xapp-", botToken) ?? "The bot token starts with xoxb-.");
    const auth = await this.api<{ bot_id?: string }>(botToken, "auth.test", {});
    this.hintAppId = await this.appIdFor(botToken, auth.bot_id);
    return this.status();
  }

  private async appIdFor(botToken: string, botId?: string): Promise<string | null> {
    if (!botId) return null;
    try {
      const info = await this.api<{ bot?: { app_id?: string } }>(botToken, "bots.info", { bot: botId });
      return info.bot?.app_id ?? null;
    } catch {
      return null;
    }
  }

  // Step 3: make the one-time code and watch for it in a DM to the bot.
  startPairing(): SlackStatus {
    if (!this.botToken || !this.appToken || !this.saved) throw new SlackError("Paste the tokens first.");
    const { user_id: _u, user_label: _l, channel_id: _c, ...kept } = this.saved;
    this.saved = kept;
    this.opts.store.setConnectorSetting("slack", this.saved);
    this.code = makeCode();
    this.lastError = null;
    this.ensureLoop();
    return this.status();
  }

  async sendTest(): Promise<void> {
    const channel = this.saved?.channel_id;
    if (!this.botToken || channel === undefined) throw new SlackError("Connect a chat first.");
    await this.post(this.botToken, {
      channel,
      text: "Waggle test: this chat is connected. New decisions will show up here.",
    });
  }

  async sendAsk(ask: AskMessage): Promise<SentMessage | null> {
    const channel = this.saved?.channel_id;
    if (!this.botToken || channel === undefined) return null;
    // Plain text only: agent text goes in plain_text fields, so Slack never parses it.
    const blocks: object[] = [
      { type: "header", text: { type: "plain_text", text: ask.title.slice(0, 150), emoji: false } },
      ...(ask.work_line
        ? [{ type: "context", elements: [{ type: "plain_text", text: ask.work_line.slice(0, 300), emoji: false }] }]
        : []),
      { type: "section", text: { type: "plain_text", text: ask.need_line.slice(0, 2900), emoji: false } },
    ];
    if (ask.recommendation) {
      const why = ask.recommendation_why ? `. ${ask.recommendation_why}` : "";
      blocks.push({
        type: "section",
        text: { type: "plain_text", text: `Recommended: ${ask.recommendation}${why}`.slice(0, 2900), emoji: false },
      });
    }
    if (ask.artifact_word) {
      blocks.push({
        type: "context",
        elements: [{ type: "plain_text", text: `Open Waggle on your Mac to see the ${ask.artifact_word}.`, emoji: false }],
      });
    }
    const elements: object[] = [];
    if (ask.select === "one") {
      ask.options.slice(0, 24).forEach((o, i) => {
        elements.push({
          type: "button",
          action_id: `o:${i}`,
          text: { type: "plain_text", text: o.title.slice(0, 75) || "Option", emoji: false },
          value: `${ask.case_id}:${i}`,
        });
      });
    }
    elements.push({
      type: "button",
      action_id: "d",
      text: { type: "plain_text", text: "Ask for more detail", emoji: false },
      value: ask.case_id,
    });
    blocks.push({ type: "actions", elements });
    blocks.push({
      type: "context",
      elements: [
        {
          type: "plain_text",
          text:
            ask.options.length === 0
              ? "Reply in this thread to answer."
              : ask.select === "many"
                ? "This decision takes more than one pick. Reply in this thread with your answer, or open Waggle on your Mac."
                : "Press an option, or reply in this thread to answer in your own words.",
          emoji: false,
        },
      ],
    });
    const sent = await this.post(this.botToken, { channel, text: ask.title, blocks });
    const ref: SlackRef = { channel: sent.channel ?? channel, ts: sent.ts, options: ask.options.map((o) => o.id) };
    return { key: `${ref.channel}:${ref.ts}`, ref };
  }

  async updateOutcome(sent: SentMessage, outcome: OutcomeMessage): Promise<void> {
    if (!this.botToken) return;
    const ref = sent.ref as SlackRef;
    await this.api(this.botToken, "chat.update", {
      channel: ref.channel,
      ts: ref.ts,
      text: `${outcome.title}: ${outcome.text}`.slice(0, 3000),
      parse: "none",
      blocks: [
        { type: "header", text: { type: "plain_text", text: outcome.title.slice(0, 150), emoji: false } },
        { type: "section", text: { type: "plain_text", text: outcome.text.slice(0, 2900), emoji: false } },
      ],
    });
  }

  // --- Web API ---

  // One Web API call. The token is in a header, so no error ever carries it.
  private async api<T>(token: string, method: string, body: object): Promise<T> {
    let res: Response;
    try {
      res = await this.doFetch(`${this.baseUrl}/api/${method}`, {
        method: "POST",
        headers: { "content-type": "application/json; charset=utf-8", authorization: `Bearer ${token}` },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(20_000),
      });
    } catch {
      throw new SlackError("Could not reach Slack. Check your connection.");
    }
    let json: { ok?: boolean; error?: string; needed?: string } & Record<string, unknown>;
    try {
      json = (await res.json()) as typeof json;
    } catch {
      throw new SlackError(`Slack sent an answer Waggle could not read (HTTP ${res.status}).`, res.status);
    }
    if (!json.ok) {
      const code = json.error ?? `http_${res.status}`;
      throw new SlackError(wordsFor(code, json.needed), res.status, code);
    }
    return json as T;
  }

  // chat.postMessage with parsing off: nothing from an agent turns into a mention or a link.
  private post(token: string, body: { channel: string; text: string; blocks?: object[]; thread_ts?: string }) {
    return this.api<{ ts: string; channel?: string }>(token, "chat.postMessage", {
      ...body,
      parse: "none",
      link_names: false,
      unfurl_links: false,
      unfurl_media: false,
      mrkdwn: false,
    });
  }

  // The wss URL for a new Socket Mode connection. Only slack.com hosts, unless a test set its own.
  private async socketUrl(appToken: string): Promise<string> {
    const res = await this.api<{ url?: string }>(appToken, "apps.connections.open", {});
    if (this.opts.socketUrl) return this.opts.socketUrl;
    let host = "";
    try {
      const u = new URL(res.url ?? "");
      host = u.protocol === "wss:" ? u.hostname : "";
    } catch {
      // falls through to the refusal below
    }
    const trusted = host === "slack.com" || host.endsWith(".slack.com");
    if (!res.url || (this.baseUrl === SLACK_BASE_URL && !trusted)) {
      throw new SlackError("Slack gave Waggle a connection address it does not trust.");
    }
    return res.url;
  }

  // --- Socket Mode ---

  private wantsConnection(): boolean {
    return (
      this.botToken !== null &&
      this.appToken !== null &&
      this.saved !== null &&
      (this.saved.channel_id !== undefined || this.code !== null)
    );
  }

  private ensureLoop(): void {
    if (this.loop || !this.wantsConnection()) return;
    const abort = new AbortController();
    this.abort = abort;
    this.loop = this.runLoop(abort.signal).finally(() => {
      this.loop = null;
    });
  }

  // Keeps one socket open. A drop or a "refresh" asks for a new one; a failure backs off up to 30 s.
  private async runLoop(signal: AbortSignal): Promise<void> {
    let delay = 0;
    while (!signal.aborted && this.wantsConnection() && this.appToken) {
      try {
        const url = await this.socketUrl(this.appToken);
        const result = await this.session(url, signal, {
          onHello: () => {
            this.lastError = null;
          },
          onEnvelope: (env) => {
            this.handle(env).catch((err) => this.log(`waggle: slack event failed: ${(err as Error).message}`));
          },
        });
        if (signal.aborted) return;
        if (result.hello) {
          delay = 0;
          await sleep(this.reconnectDelayMs, signal);
        } else {
          this.lastError = "Slack closed the connection. Waggle is trying again.";
          delay = Math.min(delay === 0 ? this.retryDelayMs : delay * 2, 30_000);
          await sleep(delay, signal);
        }
      } catch (err) {
        if (signal.aborted) return;
        const e = err as SlackError;
        if (e.code && FATAL_CODES.has(e.code)) {
          this.lastError = "Slack no longer accepts these tokens. Disconnect and connect again.";
          return;
        }
        this.lastError = e.message;
        delay = Math.min(delay === 0 ? this.retryDelayMs : delay * 2, 30_000);
        await sleep(delay, signal);
      }
    }
  }

  // One socket from open to close. Every envelope is acked at once (Slack wants it within 3 s),
  // before Waggle acts on it. Resolves when the socket ends or the signal aborts.
  private session(
    url: string,
    signal: AbortSignal,
    handlers: { onHello?: () => void; onEnvelope?: (env: Envelope) => void },
  ): Promise<{ hello: boolean }> {
    return new Promise((resolve) => {
      let hello = false;
      let done = false;
      let socket: SlackSocket | null = null;
      const finish = (): void => {
        if (done) return;
        done = true;
        clearTimeout(timer);
        signal.removeEventListener("abort", finish);
        try {
          socket?.close();
        } catch {
          // already closed
        }
        resolve({ hello });
      };
      const timer = setTimeout(finish, this.helloTimeoutMs);
      signal.addEventListener("abort", finish);
      if (signal.aborted) return finish();
      try {
        socket = this.opts.webSocket
          ? this.opts.webSocket(url)
          : (new WebSocket(url) as unknown as SlackSocket);
      } catch {
        return finish();
      }
      socket.onclose = finish;
      socket.onerror = finish;
      socket.onmessage = (ev) => {
        let env: Envelope;
        try {
          env = JSON.parse(String(ev.data)) as Envelope;
        } catch {
          return;
        }
        if (env.envelope_id) {
          try {
            socket?.send(JSON.stringify({ envelope_id: env.envelope_id }));
          } catch {
            // the socket is going away; Slack resends
          }
        }
        if (env.type === "hello") {
          hello = true;
          clearTimeout(timer);
          handlers.onHello?.();
        } else if (env.type === "disconnect") {
          finish();
        } else {
          handlers.onEnvelope?.(env);
        }
      };
    });
  }

  // Stops the connection and forgets the in-memory connection (not the saved one).
  private reset(): void {
    this.abort?.abort();
    this.appToken = null;
    this.botToken = null;
    this.saved = null;
    this.code = null;
    this.hintAppId = null;
  }

  // --- receiving ---

  private async handle(env: Envelope): Promise<void> {
    if (env.type === "events_api" && env.payload?.event?.type === "message") {
      return this.onMessage(env.payload.event);
    }
    if (env.type === "interactive" && env.payload?.type === "block_actions") {
      return this.onAction(env.payload);
    }
  }

  private async onMessage(m: SlackMessageEvent): Promise<void> {
    const token = this.botToken;
    if (!token || !this.saved) return;
    // Only plain DMs from a person. Edits, deletes and bot posts have a subtype or a bot id.
    if (m.channel_type !== "im" || m.subtype || m.bot_id || !m.user || !m.channel || !m.ts) return;
    const text = m.text?.trim();
    if (!text) return;
    // Pairing: the right code in a DM to the bot saves that person and that DM.
    if (this.saved.channel_id === undefined) {
      if (this.code === null || !safeEqual(text.toUpperCase(), this.code)) return;
      await this.pair(token, m.user, m.channel);
      return;
    }
    // Only the saved person in the saved DM counts. Everything else is ignored.
    if (m.user !== this.saved.user_id || m.channel !== this.saved.channel_id) return;
    if (!m.thread_ts) return;
    const caseId = this.opts.host.caseForMessage("slack", `${m.channel}:${m.thread_ts}`);
    if (!caseId) return;
    const result = this.opts.host.answer("slack", {
      case_id: caseId,
      key: `msg:${m.channel}:${m.ts}`,
      message: text.slice(0, 4000),
    });
    if (!result.ok) {
      await this.post(token, { channel: m.channel, thread_ts: m.thread_ts, text: failureText(result) }).catch(() => {});
    }
  }

  private async pair(token: string, userId: string, eventChannel: string): Promise<void> {
    if (!this.saved) return;
    // conversations.open names the DM for this person; the event's own channel is the fallback.
    const opened = await this.api<{ channel?: { id?: string } }>(token, "conversations.open", { users: userId }).catch(
      () => null,
    );
    const channel = opened?.channel?.id ?? eventChannel;
    const info = await this.api<{ user?: { real_name?: string; name?: string; profile?: { display_name?: string } } }>(
      token,
      "users.info",
      { user: userId },
    ).catch(() => null);
    const label = info?.user?.profile?.display_name || info?.user?.real_name || info?.user?.name || "your Slack account";
    this.saved = { ...this.saved, user_id: userId, user_label: label, channel_id: channel };
    this.code = null;
    this.opts.store.setConnectorSetting("slack", this.saved);
    await this.post(token, {
      channel,
      text: "Connected. Waggle will send new decisions here. Press a button or reply in the thread to answer.",
    }).catch(() => {});
  }

  private async onAction(p: NonNullable<Envelope["payload"]>): Promise<void> {
    const token = this.botToken;
    const saved = this.saved;
    if (!token || saved?.channel_id === undefined) return;
    if (p.user?.id !== saved.user_id || p.channel?.id !== saved.channel_id) return;
    const action = p.actions?.[0];
    if (!action) return;
    const [caseId, index] = (action.value ?? "").split(":");
    if (!caseId || (action.action_id !== "d" && !action.action_id?.startsWith("o:"))) return;
    const ref = this.opts.host.messageRef("slack", caseId) as SlackRef | null;
    let result: AnswerResult;
    if (action.action_id === "d") {
      result = this.opts.host.answer("slack", { case_id: caseId, key: `cb:${caseId}:detail`, intent: "more_detail" });
    } else {
      const choice = ref?.options[Number(index)];
      if (choice === undefined) {
        await this.say(token, ref, saved.channel_id, "That option is gone.");
        return;
      }
      result = this.opts.host.answer("slack", { case_id: caseId, key: `cb:${caseId}:${index}`, choice });
    }
    // A good press shows as the updated message. Only a refusal needs words.
    if (!result.ok) await this.say(token, ref, saved.channel_id, failureText(result));
  }

  private async say(token: string, ref: SlackRef | null, channel: string, text: string): Promise<void> {
    await this.post(token, { channel, ...(ref ? { thread_ts: ref.ts } : {}), text }).catch(() => {});
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
