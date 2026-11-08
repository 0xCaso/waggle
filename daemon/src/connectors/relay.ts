import { createHash, randomBytes } from "node:crypto";
import { hostname } from "node:os";
import { lstatSync, readdirSync, readFileSync } from "node:fs";
import { extname, join, relative, sep } from "node:path";
import { z } from "zod";
import type { EventBus } from "../events";
import type {
  AccountShare,
  AccountShares,
  AccountState,
  AgentSharedComment,
  Case,
  InviteCounts,
  SharedComment,
  SharingMode,
  SharingNotifications,
  SharingState,
  SharingUnread,
} from "../protocol";
import type { RelayCommentInput, RelayShare, Store } from "../store";
import { plainLine } from "./manager";
import type { SecretStore } from "./secrets";

// Sharing a case (WAG-387). The one host the daemon calls for it. Dev builds may replace it through
// connectorConfig() (KNOCK_RELAY_BASE_URL); a release daemon always uses this.
export const RELAY_BASE_URL = "https://app.waggle.so";

// The one switch for Sharing (operator decision 8 Nov, case c_186e3e80). False: the feature is hidden. The daemon
// makes no relay call whatever the saved setting says, and the app hides the Sharing and Account pages and every
// share action. Existing pages on the relay stay up. Set it to true to bring Sharing back.
export const SHARING_AVAILABLE = false;

// One try per minute at most after a failure (no retry storm), and the poll interval for a shared
// case that waits for the operator.
export const RELAY_RETRY_MS = 60_000;
export const RELAY_POLL_MS = 60_000;

// How often the background fetches the comments of a shared case (WAG-394). Every minute while the case is
// open (an ask waits, or the app opened it) or was touched in the last hour; every 10 minutes after; every
// hour once nothing happened for 7 days. The tick itself runs every RELAY_POLL_MS.
export const COMMENTS_EVERY_MS = { active: 60_000, quiet: 10 * 60_000, old: 60 * 60_000 };
const ACTIVE_WINDOW_MS = 60 * 60_000;
const OLD_AFTER_MS = 7 * 24 * 60 * 60_000;

// The relay's limits for the files of one round. The daemon checks the same numbers before it uploads.
const MAX_FILES = 200;
// A file over 1,400,000 base64 characters (about 1 MB) is refused.
const MAX_BASE64 = 1_400_000;
// A round over 20,000,000 base64 characters (about 15 MB) in all is refused.
const MAX_ROUND_BASE64 = 20_000_000;
// The relay takes 50 emails at most.
export const MAX_EMAILS = 50;

export const KEY_MISSING = "This Mac no longer has the key for this link.";

// A problem the operator can read: one plain line. Never a status dump or a secret.
export class RelayError extends Error {}

// The relay answered with an error (`status`), or could not be reached (`status` null).
// `said` is the relay's own words, when it gave some.
export class RelayCallError extends RelayError {
  constructor(
    message: string,
    readonly status: number | null,
  ) {
    super(message);
  }
}

// `account_email` is the signed-in Waggle account (WAG-392). The device token itself is in the secret store.
const Saved = z.object({ enabled: z.boolean(), account_email: z.string().optional() });

// The secret-store name of the device token (WAG-392). Never knock.db, a log or an RPC result.
export const DEVICE_SECRET = "relay-device";
export const SIGN_IN_FIRST = "Sign in to Waggle first.";
export const SIGN_IN_ENDED = "Your Waggle sign-in ended. Sign in again.";
export const CODE_RAN_OUT = "The sign-in code ran out. Try again.";

const DeviceStart = z.object({
  device_code: z.string().min(1),
  user_code: z.string().min(1),
  verify_url: z.string().min(1),
  expires_in: z.number().optional(),
  interval: z.number().optional(),
});
const DevicePoll = z.object({ status: z.string(), device_token: z.string().optional(), email: z.string().optional() });
const MeCases = z.object({
  cases: z.array(
    z.object({
      id: z.string().min(1),
      title: z.string(),
      url: z.string(),
      mode: z.string(),
      created_at: z.number(),
      comment_count: z.number().optional(),
      device_label: z.string().nullable().optional(),
    }),
  ),
});

// The Mac name the relay shows beside a shared link: ComputerName, else the host name.
export function macLabel(): string {
  try {
    const r = Bun.spawnSync(["/usr/sbin/scutil", "--get", "ComputerName"], { stdout: "pipe", stderr: "pipe" });
    const name = r.stdout.toString().trim();
    if (r.exitCode === 0 && name !== "") return name.slice(0, 80);
  } catch {
    // fall through
  }
  return hostname().slice(0, 80) || "Mac";
}

const RelayComment = z.object({
  id: z.string().min(1),
  round_seq: z.number().int(),
  author_name: z.string(),
  author_kind: z.string(),
  author_email: z.string().nullable().optional(),
  body: z.string(),
  quote: z.string().nullable().optional(),
  prefix: z.string().nullable().optional(),
  suffix: z.string().nullable().optional(),
  box: z
    .object({ x: z.number(), y: z.number(), w: z.number(), h: z.number(), vw: z.number(), near: z.string() })
    .nullable()
    .optional(),
  created_at: z.number(),
  parent_id: z.string().nullable().optional(),
  resolved_at: z.number().nullable().optional(),
  resolved_by: z.string().nullable().optional(),
});
const RelayResolved = z.object({ id: z.string(), resolved_at: z.number(), resolved_by: z.string().nullable().optional() });
const RelayCaseInfo = z.object({ comments_closed: z.boolean().optional() });

export interface RelayOptions {
  store: Store;
  bus?: EventBus;
  secrets: SecretStore;
  baseUrl?: string;
  fetch?: typeof fetch;
  now?: () => number;
  pollMs?: number;
  retryMs?: number;
  // Test hooks: the sign-in poll interval (ms) instead of the relay's, and the Mac label.
  connectPollMs?: number;
  deviceLabel?: () => string;
  log?: (line: string) => void;
  // Is Sharing available at all (SHARING_AVAILABLE)? The daemon passes the switch. Default true, for tests.
  available?: boolean;
}

// The question the page shows beside the rounds. All text is cut to these lengths.
const ASK_CAPS = { need: 600, why: 1000, recommendation: 300, title: 80, label: 600, options: 12 };

export interface RelayAsk {
  need: string;
  why?: string;
  recommendation?: string;
  options?: { title: string; label: string; recommended?: boolean }[];
}

function cut(text: string, max: number): string {
  const t = text.trim();
  return t.length <= max ? t : `${t.slice(0, max - 3).trimEnd()}...`;
}

// The case's current ask for the relay (the optional `ask` field). Empty parts are left out; a case
// without a need sends no ask at all.
export function askForRelay(c: Case): RelayAsk | undefined {
  const need = cut(c.need, ASK_CAPS.need);
  if (need === "") return undefined;
  const ask: RelayAsk = { need };
  const why = cut(c.why, ASK_CAPS.why);
  if (why !== "") ask.why = why;
  const recommendation = cut(c.recommendation_why, ASK_CAPS.recommendation);
  if (recommendation !== "") ask.recommendation = recommendation;
  const picked = new Set(c.recommendations.length > 0 ? c.recommendations : c.recommendation ? [c.recommendation] : []);
  const options = c.options.slice(0, ASK_CAPS.options).flatMap((o) => {
    const label = cut(o.label, ASK_CAPS.label);
    if (label === "") return [];
    const title = cut(o.title ?? label, ASK_CAPS.title);
    return [{ title, label, ...(picked.has(o.id) ? { recommended: true } : {}) }];
  });
  if (options.length > 0) ask.options = options;
  return ask;
}

interface RoundUpload {
  entry: string;
  files: { path: string; body_base64: string }[];
  // The images of a screenshots round, in order. The page stacks them (WAG-394).
  gallery?: string[];
}

// What the app sees while Sharing is hidden: nothing shared, nothing to show, no account.
function unavailableState(): SharingState {
  return {
    available: false,
    enabled: false,
    shared_count: 0,
    share: null,
    comments: [],
    error: null,
    skipped: [],
    invites: { sent: 0, failed: 0, limited: 0 },
    account: { signed_in: false, email: null, connect: null, error: null },
    comments_closed: false,
    shared_before: false,
    late_comments: { count: 0, new: 0 },
  };
}

function secretName(relayId: string): string {
  return `relay-owner.${relayId}`;
}

export class RelaySharing {
  private baseUrl: string;
  private doFetch: typeof fetch;
  private now: () => number;
  private pollMs: number;
  private retryMs: number;
  private log: (line: string) => void;
  private timer: ReturnType<typeof setInterval> | null = null;
  private unsubscribe: (() => void) | null = null;
  // No background call for a scope (a case id, or `stop:<relay id>`) before this time (ms). Set after
  // a failure. One case failing never holds back another.
  private retryAt = new Map<string, number>();
  // The request id and owner key of a share that has not finished. A retry sends the same two, so if the
  // first answer was lost the relay returns the same case (the key hash is part of the match). Memory only.
  private pendingShares = new Map<string, { requestId: string; key: string; sig: string }>();
  private errors = new Map<string, string>();
  // The invite counts of the last share or audience change for each case. In memory only: a restart forgets them.
  private invites = new Map<string, InviteCounts>();
  // The next time (ms) the background fetches the comments of a case, and the last time the case was touched
  // (the app opened it, a team comment came). Memory only: a restart fetches once, then follows the schedule.
  private nextFetch = new Map<string, number>();
  private touched = new Map<string, number>();
  private accountError: string | null = null;
  private connecting: { device_code: string; user_code: string; verify_url: string; expires_at: number; intervalMs: number; timer: ReturnType<typeof setTimeout> | null; failures: number } | null = null;
  private busy = new Set<string>();
  // WAG-401: cases whose page shows open while the owner changes the answer, with the signature of the answer being changed.
  private reopened = new Map<string, string>();

  constructor(private opts: RelayOptions) {
    this.baseUrl = (opts.baseUrl ?? RELAY_BASE_URL).replace(/\/+$/, "");
    this.doFetch = opts.fetch ?? fetch;
    this.now = opts.now ?? Date.now;
    this.pollMs = opts.pollMs ?? RELAY_POLL_MS;
    this.retryMs = opts.retryMs ?? RELAY_RETRY_MS;
    this.log = opts.log ?? ((line) => process.stderr.write(`${line}\n`));
  }

  // --- lifecycle ---

  // Starts the timer and the round watcher. With Sharing off nothing here makes a call.
  start(): void {
    if (this.timer) return;
    this.timer = setInterval(() => void this.tick(), this.pollMs);
    this.timer.unref?.();
    this.unsubscribe = this.opts.bus?.subscribe((event) => {
      const id = event.case_id;
      if (!id) return;
      if (event.type === "revision.added") void this.syncRounds(id, { background: true }).then(() => this.syncAsk(id, { background: true }));
      else if (event.type === "reply.state_changed") void this.sendOutcome(id, { background: true });
      else if (event.type === "case.updated") void this.syncAsk(id, { background: true });
      else if (event.type === "case.created") void this.followUp(id);
    }) ?? null;
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
    this.unsubscribe?.();
    this.unsubscribe = null;
    this.cancelConnect();
  }

  // The daemon stays up while a case is shared and the app is connected (WAG-394): comments and the answer go up and
  // down while the app runs. With the app closed nothing keeps it up: no LaunchAgent, comments come in at the next start.
  keepAlive(appConnected: boolean): boolean {
    return appConnected && this.enabled() && this.opts.store.listRelayShares().length > 0;
  }

  available(): boolean {
    return this.opts.available ?? true;
  }

  enabled(): boolean {
    return this.available() && this.opts.store.getConnectorSetting("relay", Saved)?.enabled === true;
  }

  // --- the settings switch ---

  setEnabled(on: boolean): SharingState {
    if (on && !this.available()) throw new RelayError("Sharing is not available in this version.");
    if (!on) {
      const n = this.sharedCount();
      if (n > 0) throw new RelayError(n === 1 ? "Stop sharing the shared case first." : `Stop sharing the ${n} shared cases first.`);
    }
    const email = this.accountEmail();
    this.opts.store.setConnectorSetting("relay", on ? { enabled: true, ...(email ? { account_email: email } : {}) } : email ? { enabled: false, account_email: email } : null);
    if (!on) this.cancelConnect();
    return this.state();
  }

  // Shared cases, plus pages of deleted cases that are not down yet. The switch stays blocked for both.
  private sharedCount(): number {
    // A follow-up case uses the link of the first case: one page, one count.
    return new Set(this.opts.store.listRelayShares().map((s) => s.relay_id)).size + this.opts.store.listPendingRelayStops().length;
  }

  // What the app shows. No network call.
  state(caseId?: string): SharingState {
    if (!this.available()) return unavailableState();
    const share = caseId ? this.opts.store.getRelayShare(caseId) : null;
    return {
      available: true,
      enabled: this.enabled(),
      shared_count: this.sharedCount(),
      share: share
        ? { url: share.url, mode: share.mode, emails: share.emails, stoppable: this.opts.secrets.get(secretName(share.relay_id)) !== null || this.signedIn() }
        : null,
      // The comments stay after Stop sharing: they were fetched, the owner and the agent read them.
      comments: caseId ? this.opts.store.relayComments(caseId).map(({ agent_seen: _seen, ...c }) => c) : [],
      error: caseId ? (this.errors.get(caseId) ?? null) : null,
      skipped: caseId ? this.opts.store.relaySkipped(caseId) : [],
      invites: (caseId ? this.invites.get(caseId) : undefined) ?? { sent: 0, failed: 0, limited: 0 },
      account: this.accountState(),
      comments_closed: share?.comments_closed ?? false,
      shared_before: caseId ? this.opts.store.wasRelayShared(caseId) : false,
      late_comments: caseId ? this.opts.store.lateTeamComments(caseId) : { count: 0, new: 0 },
    };
  }

  // --- the Waggle account (WAG-392) ---

  private accountEmail(): string | null {
    return this.opts.store.getConnectorSetting("relay", Saved)?.account_email ?? null;
  }

  private deviceToken(): string | null {
    return this.opts.secrets.get(DEVICE_SECRET);
  }

  private signedIn(): boolean {
    return this.deviceToken() !== null;
  }

  // What the app shows. No network call.
  accountState(): AccountState {
    const c = this.connecting;
    const token = this.signedIn();
    return {
      signed_in: token,
      email: token ? this.accountEmail() : null,
      connect: c ? { user_code: c.user_code, verify_url: c.verify_url, expires_at: c.expires_at } : null,
      error: this.accountError,
    };
  }

  private clearSignIn(error: string | null): void {
    this.opts.secrets.delete(DEVICE_SECRET);
    const saved = this.opts.store.getConnectorSetting("relay", Saved);
    if (saved) this.opts.store.setConnectorSetting("relay", saved.enabled ? { enabled: true } : null);
    this.accountError = error;
  }

  async connectStart(): Promise<AccountState> {
    this.requireOn();
    if (this.signedIn()) return this.accountState();
    if (this.connecting) return this.accountState();
    this.accountError = null;
    const label = (this.opts.deviceLabel ?? macLabel)();
    const made = DeviceStart.safeParse(await this.call("/api/auth/device", { method: "POST", body: { label }, scope: "account" }));
    if (!made.success) throw new RelayError("The sharing service sent an answer Waggle could not read.");
    if (this.connecting) return this.accountState();
    const d = made.data;
    const intervalMs = this.opts.connectPollMs ?? Math.max(1, d.interval ?? 2) * 1000;
    this.connecting = {
      device_code: d.device_code,
      user_code: d.user_code,
      verify_url: d.verify_url,
      expires_at: this.now() + (d.expires_in ?? 600) * 1000,
      intervalMs,
      timer: null,
      failures: 0,
    };
    this.scheduleConnectPoll(this.connecting);
    return this.accountState();
  }

  connectCancel(): AccountState {
    this.cancelConnect();
    return this.accountState();
  }

  private cancelConnect(): void {
    if (this.connecting?.timer) clearTimeout(this.connecting.timer);
    this.connecting = null;
  }

  private scheduleConnectPoll(c: NonNullable<RelaySharing["connecting"]>): void {
    c.timer = setTimeout(() => void this.pollConnect(c), c.intervalMs);
    c.timer.unref?.();
  }

  private async pollConnect(c: NonNullable<RelaySharing["connecting"]>): Promise<void> {
    if (this.connecting !== c) return;
    if (!this.enabled()) return this.cancelConnect();
    if (this.now() >= c.expires_at) return this.failConnect(c, CODE_RAN_OUT);
    let data: z.infer<typeof DevicePoll>;
    try {
      const raw = await this.call("/api/auth/device/poll", { method: "POST", body: { device_code: c.device_code }, scope: "account" });
      const parsed = DevicePoll.safeParse(raw);
      if (!parsed.success) throw new RelayError("bad answer");
      data = parsed.data;
    } catch (err) {
      if (this.connecting !== c) return;
      if (err instanceof RelayCallError && err.status === 410) return this.failConnect(c, CODE_RAN_OUT);
      c.failures += 1;
      if (c.failures >= 3) return this.failConnect(c, err instanceof RelayCallError && err.status === null ? err.message : "The sign-in did not finish. Try again.");
      this.scheduleConnectPoll(c);
      return;
    }
    if (this.connecting !== c) return;
    c.failures = 0;
    if (data.status === "approved" && data.device_token) {
      try {
        this.opts.secrets.set(DEVICE_SECRET, data.device_token);
      } catch {
        return this.failConnect(c, "Waggle could not save the sign-in on this Mac.");
      }
      this.opts.store.setConnectorSetting("relay", { enabled: true, account_email: data.email ?? "" });
      this.connecting = null;
      this.accountError = null;
      return;
    }
    this.scheduleConnectPoll(c);
  }

  private failConnect(c: NonNullable<RelaySharing["connecting"]>, error: string): void {
    if (this.connecting !== c) return;
    this.cancelConnect();
    this.accountError = error;
  }

  async signOut(): Promise<AccountState> {
    this.requireOn();
    this.cancelConnect();
    const token = this.deviceToken();
    if (token) {
      try {
        // A second revoke answers 401: the token is gone already, which is what we want.
        await this.call("/api/me/device", { method: "DELETE", key: token, scope: "account" }, [401]);
      } catch (err) {
        this.accountError = (err as Error).message;
        return this.accountState();
      }
    }
    this.clearSignIn(null);
    return this.accountState();
  }

  async accountShares(): Promise<AccountShares> {
    if (!this.enabled()) return { shares: [], error: null };
    const token = this.deviceToken();
    if (!token) return { shares: [], error: null };
    try {
      const data = MeCases.parse(await this.call("/api/me/cases", { key: token, device: true, scope: "account" }));
      return { shares: data.cases.map((c) => this.toAccountShare(c)), error: null };
    } catch (err) {
      return { shares: [], error: err instanceof z.ZodError ? "The sharing service sent an answer Waggle could not read." : (err as Error).message };
    }
  }

  private toAccountShare(c: z.infer<typeof MeCases>["cases"][number]): AccountShare {
    return {
      relay_id: c.id,
      title: c.title,
      url: c.url,
      mode: c.mode === "emails" ? "emails" : "link",
      created_at: c.created_at,
      comment_count: c.comment_count ?? 0,
      device_label: c.device_label ?? "",
      local_case_id: this.opts.store.getRelayShareByRelayId(c.id)?.case_id ?? null,
    };
  }

  // Takes a page down by its relay id, also one shared from another Mac. Uses the device token.
  async accountStopShare(relayId: string): Promise<AccountShares> {
    this.requireOn();
    const token = this.deviceToken();
    if (!token) throw new RelayError(SIGN_IN_FIRST);
    try {
      await this.call(`/api/cases/${relayId}`, { method: "DELETE", key: token, device: true, scope: "account" }, [404]);
    } catch (err) {
      return { shares: [], error: (err as Error).message };
    }
    this.dropShare(relayId);
    return this.accountShares();
  }

  // What waggle_check returns to the agent: the team's comments, never a reply.
  // The full list (the last 100). `new: true` marks a comment the agent has not been given yet.
  commentsForAgent(caseId: string): AgentSharedComment[] {
    const all = this.opts.store.relayComments(caseId);
    const resolved = new Set(all.filter((c) => c.resolved_at !== null).map((c) => c.id));
    return all.slice(-100).map((c) => toAgentComment(c, resolved.has(c.parent_id ?? c.id), !c.agent_seen));
  }

  // A team comment waits for the agent. A waiting waggle_check returns at once for it.
  hasNewComments(caseId: string): boolean {
    return this.opts.store.hasNewTeamComments(caseId);
  }

  // WAG-401: like hasNewComments, but a comment that came after the decision does not count. It never wakes the agent.
  hasNewEarlyComments(caseId: string): boolean {
    return this.opts.store.hasNewEarlyTeamComments(caseId);
  }

  // WAG-401: the app sent the late comments to the agent's session. They are not new any more.
  markLateGiven(caseId: string): SharingState {
    this.opts.store.markLateCommentsGiven(caseId);
    this.opts.store.recordEvent("case.updated", { case_id: caseId });
    return this.state(caseId);
  }

  // A result with these comments went to the agent: they are not new any more.
  markGivenToAgent(caseId: string): void {
    this.opts.store.markRelayCommentsGiven(caseId);
  }

  // --- the operator's actions ---

  async share(caseId: string, mode: SharingMode, emails: string[] = []): Promise<SharingState> {
    this.requireOn();
    const device = this.deviceToken();
    if (!device) throw new RelayError(SIGN_IN_FIRST);
    const store = this.opts.store;
    const c = store.getCase(caseId)?.case;
    if (!c) throw new RelayError("That case is gone.");
    if (store.getRelayShare(caseId)) return this.state(caseId);
    const list = [...new Set(emails.map((e) => e.trim().toLowerCase()).filter((e) => e !== ""))];
    if (mode === "emails" && list.length === 0) throw new RelayError("Add at least one email.");
    if (list.length > MAX_EMAILS) throw new RelayError(`${MAX_EMAILS} emails at most.`);
    for (const e of list) if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(e)) throw new RelayError(`${e} is not an email address.`);
    if (this.busy.has(caseId)) return this.state(caseId);
    this.busy.add(caseId);
    try {
      // A retry with other choices (mode, emails) is a new share, not the lost one.
      const sig = `${mode}:${list.join(",")}`;
      const old = this.pendingShares.get(caseId);
      const attempt = old?.sig === sig ? old : { requestId: randomBytes(16).toString("hex"), key: randomBytes(32).toString("base64url"), sig };
      this.pendingShares.set(caseId, attempt);
      const { key, requestId } = attempt;
      const hash = createHash("sha256").update(key).digest("hex");
      const made = await this.call<{ id: string; url: string; invites?: unknown }>("/api/cases", {
        method: "POST",
        key: device,
        device: true,
        scope: caseId,
        body: { title: plainLine(c.title, 160) || "Waggle case", mode, emails: mode === "emails" ? list : [], owner_key_hash: hash, request_id: requestId, ...askField(c) },
      });
      this.pendingShares.delete(caseId);
      try {
        this.opts.secrets.set(secretName(made.id), key);
      } catch {
        // No safe place for the key: take the case down again, with the key we still hold.
        await this.call(`/api/cases/${made.id}`, { method: "DELETE", key, scope: caseId }).catch(() => {});
        throw new RelayError("Waggle could not save the sharing key on this Mac.");
      }
      store.saveRelayShare({ case_id: caseId, relay_id: made.id, url: made.url, mode, emails: mode === "emails" ? list : [], ask_sig: askSig(c) });
      this.errors.delete(caseId);
      this.retryAt.delete(caseId);
      this.invites.set(caseId, inviteCounts(made.invites));
    } finally {
      this.busy.delete(caseId);
    }
    // The case is shared. A failed upload or fetch below shows as a line in the sheet and the timer
    // tries again; it does not undo the share.
    await this.syncRounds(caseId, { background: false });
    await this.fetchComments(caseId, { background: false });
    return this.state(caseId);
  }

  async stopSharing(caseId: string): Promise<SharingState> {
    this.requireOn();
    const share = this.opts.store.getRelayShare(caseId);
    if (!share) return this.state(caseId);
    const key = this.ownerToken(share.relay_id);
    if (!key) {
      // Nothing on this Mac can take the page down. Keep the share and say so: a quiet "stopped"
      // would leave the page public.
      this.errors.set(caseId, KEY_MISSING);
      throw new RelayError(KEY_MISSING);
    }
    try {
      await this.call(`/api/cases/${share.relay_id}`, { method: "DELETE", key: key.token, device: key.device, scope: caseId }, [404]);
    } catch (err) {
      this.errors.set(caseId, (err as Error).message);
      throw err;
    }
    this.dropShare(share.relay_id);
    this.invites.delete(caseId);
    return this.state(caseId);
  }

  // The page is down. Forget the key and every case that used the link (the first case and its follow-ups).
  private dropShare(relayId: string): void {
    this.opts.secrets.delete(secretName(relayId));
    for (const id of this.opts.store.relayShareCases(relayId)) {
      this.opts.store.deleteRelayShare(id);
      this.errors.delete(id);
      this.nextFetch.delete(id);
    }
  }

  // The owner key when this Mac has one, else the device token of the signed-in account.
  private ownerToken(relayId: string): { token: string; device: boolean } | null {
    const key = this.opts.secrets.get(secretName(relayId));
    if (key) return { token: key, device: false };
    const device = this.deviceToken();
    return device ? { token: device, device: true } : null;
  }

  async update(caseId: string, mode: SharingMode, emails: string[] = []): Promise<SharingState> {
    this.requireOn();
    const share = this.opts.store.getRelayShare(caseId);
    if (!share) throw new RelayError("That case is not shared.");
    const list = [...new Set(emails.map((e) => e.trim().toLowerCase()).filter((e) => e !== ""))];
    if (mode === "emails" && list.length === 0) throw new RelayError("Add at least one email.");
    if (list.length > MAX_EMAILS) throw new RelayError(`${MAX_EMAILS} emails at most.`);
    for (const e of list) if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(e)) throw new RelayError(`${e} is not an email address.`);
    const auth = this.ownerToken(share.relay_id);
    if (!auth) throw new RelayError(KEY_MISSING);
    const sent = mode === "emails" ? list : [];
    try {
      const res = await this.call<{ mode?: string; emails?: string[]; invites?: unknown }>(`/api/cases/${share.relay_id}`, {
        method: "PATCH",
        key: auth.token,
        device: auth.device,
        scope: caseId,
        body: { mode, emails: sent },
      });
      const gotEmails = Array.isArray(res.emails) ? res.emails.filter((e): e is string => typeof e === "string") : sent;
      for (const id of this.opts.store.relayShareCases(share.relay_id)) {
        this.opts.store.updateRelayShare(id, res.mode === "emails" || res.mode === "link" ? res.mode : mode, gotEmails);
      }
      this.errors.delete(caseId);
      this.invites.set(caseId, inviteCounts(res.invites));
    } catch (err) {
      this.errors.set(caseId, (err as Error).message);
      throw err;
    }
    return this.state(caseId);
  }

  // A one-time link that opens the shared page with the owner signed in.
  async openPage(caseId: string): Promise<{ url: string }> {
    this.requireOn();
    const share = this.opts.store.getRelayShare(caseId);
    if (!share) throw new RelayError("That case is not shared.");
    const auth = this.ownerToken(share.relay_id);
    if (!auth) throw new RelayError(KEY_MISSING);
    const res = await this.call<{ url?: unknown }>(`/api/cases/${share.relay_id}/owner-link`, { method: "POST", key: auth.token, device: auth.device, body: {}, scope: caseId });
    if (typeof res.url !== "string" || res.url === "") throw new RelayError("The sharing service sent an answer Waggle could not read.");
    return { url: res.url };
  }

  // Takes down the page of every deleted case that is still up (the store noted them when the case was
  // purged). A failure leaves the note, so the next tick tries again. Without the key nothing can be
  // done from this Mac, so the note is dropped and the line goes to the log.
  async flushPendingStops(o: { background: boolean } = { background: false }): Promise<void> {
    if (!this.enabled()) return;
    for (const relayId of this.opts.store.listPendingRelayStops()) {
      const scope = `stop:${relayId}`;
      if (this.gated(scope, o.background)) continue;
      const key = this.ownerToken(relayId);
      if (!key) {
        this.log(`waggle: no sharing key for a deleted case; its page cannot be stopped from this Mac (${relayId})`);
        this.opts.store.removePendingRelayStop(relayId);
        continue;
      }
      try {
        await this.call(`/api/cases/${relayId}`, { method: "DELETE", key: key.token, device: key.device, scope }, [404]);
      } catch {
        continue;
      }
      this.opts.secrets.delete(secretName(relayId));
      this.opts.store.removePendingRelayStop(relayId);
    }
  }

  // Called when the app opens a shared case: upload what is missing, fetch the new comments.
  async refresh(caseId: string): Promise<SharingState> {
    if (this.enabled() && this.opts.store.getRelayShare(caseId)) {
      this.touched.set(caseId, this.now());
      await this.syncRounds(caseId, { background: true });
      await this.syncAsk(caseId, { background: true });
      await this.sendOutcome(caseId, { background: true });
      await this.fetchComments(caseId, { background: true });
      this.nextFetch.set(caseId, this.now() + COMMENTS_EVERY_MS.active);
    }
    return this.state(caseId);
  }

  // --- background work ---

  private async tick(): Promise<void> {
    if (!this.enabled()) return;
    await this.flushPendingStops({ background: true });
    for (const share of this.opts.store.listRelayShares()) {
      const c = this.opts.store.getCase(share.case_id)?.case;
      if (!c) continue;
      await this.syncRounds(share.case_id, { background: true });
      await this.syncAsk(share.case_id, { background: true });
      await this.sendOutcome(share.case_id, { background: true });
      // Comments of every shared case, also after the answer, on a schedule that slows down as the case ages.
      if (this.now() >= (this.nextFetch.get(share.case_id) ?? 0)) {
        await this.fetchComments(share.case_id, { background: true });
        this.nextFetch.set(share.case_id, this.now() + this.fetchEvery(share.case_id, c));
      }
    }
  }

  private fetchEvery(caseId: string, c: Case): number {
    if (c.status === "needs_you") return COMMENTS_EVERY_MS.active;
    const touched = Math.max(Date.parse(c.updated_at) || 0, this.touched.get(caseId) ?? 0);
    const age = this.now() - touched;
    if (age < ACTIVE_WINDOW_MS) return COMMENTS_EVERY_MS.active;
    return age < OLD_AFTER_MS ? COMMENTS_EVERY_MS.quiet : COMMENTS_EVERY_MS.old;
  }

  private gated(scope: string, background: boolean): boolean {
    return background && this.now() < (this.retryAt.get(scope) ?? 0);
  }

  // Uploads every revision the relay does not have yet, in order. A round the relay can never take
  // (too big, too many files) is skipped with a reason and the next one goes up. A failure that may
  // pass (no network, a 5xx) stops this case only, and the timer tries again.
  private async syncRounds(caseId: string, o: { background: boolean }): Promise<void> {
    if (!this.enabled()) return;
    const share = this.opts.store.getRelayShare(caseId);
    if (!share) return;
    const done = this.opts.store.relayRounds(caseId);
    const skipped = new Set(this.opts.store.relaySkipped(caseId).map((r) => r.revision));
    const missing = this.opts.store.revisionNumbers(caseId).filter((n) => !done.has(n) && !skipped.has(n));
    if (missing.length === 0 || this.gated(caseId, o.background)) return;
    const key = this.ownerToken(share.relay_id);
    if (!key) {
      this.errors.set(caseId, KEY_MISSING);
      return;
    }
    const lockKey = `rounds:${caseId}`;
    if (this.busy.has(lockKey)) return;
    this.busy.add(lockKey);
    try {
      for (const n of missing) {
        let upload: RoundUpload;
        try {
          upload = this.roundFiles(caseId, n);
        } catch (err) {
          this.opts.store.skipRelayRound(caseId, n, (err as Error).message);
          continue;
        }
        const label = plainLine(this.opts.store.revisionArtifactName(caseId, n) ?? "", 120);
        try {
          const made = await this.call<{ seq: number }>(`/api/cases/${share.relay_id}/rounds`, {
            method: "POST",
            key: key.token,
            device: key.device,
            scope: caseId,
            body: { ...(label !== "" ? { label } : {}), entry: upload.entry, files: upload.files, ...(upload.gallery ? { gallery: upload.gallery } : {}), ...askField(this.opts.store.getCase(caseId)?.case) },
          });
          this.opts.store.markRelayRound(caseId, n, made.seq);
          this.opts.store.setRelayAskSig(caseId, askSig(this.opts.store.getCase(caseId)?.case));
        } catch (err) {
          const status = err instanceof RelayCallError ? err.status : null;
          // 400, 413 and 422 mean this round itself is wrong; trying again changes nothing.
          if (status === 400 || status === 413 || status === 422) {
            this.opts.store.skipRelayRound(caseId, n, `Round ${n} was not shared. ${(err as Error).message}`);
            this.retryAt.delete(caseId);
            continue;
          }
          throw err;
        }
      }
      this.errors.delete(caseId);
    } catch (err) {
      this.errors.set(caseId, (err as Error).message);
    } finally {
      this.busy.delete(lockKey);
    }
  }

  private async fetchComments(caseId: string, o: { background: boolean }): Promise<void> {
    if (!this.enabled()) return;
    const share = this.opts.store.getRelayShare(caseId);
    if (!share || this.gated(caseId, o.background)) return;
    const key = this.ownerToken(share.relay_id);
    if (!key) return;
    try {
      const data = await this.call<{ comments?: unknown[]; resolved?: unknown[]; case?: unknown }>(
        `/api/cases/${share.relay_id}/comments?since=${share.since}&after=${encodeURIComponent(share.since_id)}`,
        { key: key.token, device: key.device, scope: caseId },
      );
      const parsed = (data.comments ?? []).flatMap((c) => {
        const r = RelayComment.safeParse(c);
        return r.success ? [r.data] : [];
      });
      const { added, team } = this.opts.store.addRelayComments(caseId, parsed.map(toInput), share.root_case_id === null);
      // The state of the resolved threads comes with every answer, so a resolve made on the page arrives too.
      const resolved = (data.resolved ?? []).flatMap((r) => {
        const x = RelayResolved.safeParse(r);
        return x.success ? [{ id: x.data.id, resolved_ms: x.data.resolved_at, resolved_by: x.data.resolved_by ?? null }] : [];
      });
      const changed = Array.isArray(data.resolved) ? this.opts.store.applyRelayResolutions(caseId, resolved) : false;
      const info = RelayCaseInfo.safeParse(data.case);
      if (info.success && info.data.comments_closed !== undefined && info.data.comments_closed !== share.comments_closed) {
        this.opts.store.setRelayCommentsClosed(caseId, info.data.comments_closed);
        this.opts.store.recordEvent("case.updated", { case_id: caseId });
      }
      // The cursor is the newest (time, id) pair. The relay sorts by it, and we compare the same way.
      let at = share.since;
      let id = share.since_id;
      for (const c of parsed) {
        if (c.created_at > at || (c.created_at === at && c.id > id)) {
          at = c.created_at;
          id = c.id;
        }
      }
      if (at !== share.since || id !== share.since_id) this.opts.store.setRelayCursor(caseId, at, id);
      this.errors.delete(caseId);
      if (added > 0 || changed) this.opts.store.recordEvent("case.updated", { case_id: caseId });
      if (team > 0) {
        this.touched.set(caseId, this.now());
        this.opts.store.recordEvent("comment.added", { case_id: caseId });
      }
    } catch (err) {
      this.errors.set(caseId, (err as Error).message);
    }
  }

  // --- the ask, the answer and follow-ups (WAG-394) ---

  // The ask changed with no new artifact (new need, options or recommendation): the page gets the new ask on its
  // last round. A change that comes with a new artifact goes up with that round, so it waits for it.
  private async syncAsk(caseId: string, o: { background: boolean }): Promise<void> {
    if (!this.enabled()) return;
    const store = this.opts.store;
    const share = store.getRelayShare(caseId);
    const c = store.getCase(caseId)?.case;
    if (!share || !c) return;
    const sig = askSig(c);
    if (share.ask_sig === sig) return;
    // A share from before this version has no signature: take the ask the page has as the current one.
    if (share.ask_sig === null) return void store.setRelayAskSig(caseId, sig);
    const ask = askForRelay(c);
    if (!ask) return void store.setRelayAskSig(caseId, sig);
    const done = store.relayRounds(caseId);
    const skipped = new Set(store.relaySkipped(caseId).map((r) => r.revision));
    if (store.revisionNumbers(caseId).some((n) => !done.has(n) && !skipped.has(n))) return;
    const lock = `ask:${caseId}`;
    if (this.busy.has(lock) || this.gated(caseId, o.background)) return;
    const key = this.ownerToken(share.relay_id);
    if (!key) return;
    this.busy.add(lock);
    try {
      // The ask belongs to the newest round this case uploaded. A follow-up with no round yet changes the page's
      // question only: the first case keeps the question of its own round.
      const seqs = [...store.relayRounds(caseId).values()];
      const roundSeq = seqs.length > 0 ? Math.max(...seqs) : null;
      await this.call(`/api/cases/${share.relay_id}`, { method: "PATCH", key: key.token, device: key.device, scope: caseId, body: { ask, round_seq: roundSeq } });
      store.setRelayAskSig(caseId, sig);
      this.errors.delete(caseId);
    } catch (err) {
      this.errors.set(caseId, (err as Error).message);
    } finally {
      this.busy.delete(lock);
    }
    // The ask may have changed again while the call ran.
    if (askSig(store.getCase(caseId)?.case) !== sig && store.getRelayShare(caseId)?.ask_sig === sig) void this.syncAsk(caseId, o);
  }

  // The owner answered: the page shows the outcome (the chosen option titles, the note, the time). A reply that
  // only keeps talking decides nothing. A failed call is tried again by the tick.
  private async sendOutcome(caseId: string, o: { background: boolean }): Promise<void> {
    if (!this.enabled()) return;
    const store = this.opts.store;
    const share = store.getRelayShare(caseId);
    if (!share) return;
    const detail = store.getCase(caseId);
    const reply = detail?.replies[detail.replies.length - 1];
    if (!detail || !reply || reply.outcome !== "decide") return;
    const sig = `${reply.id}:${reply.replaced_at ?? ""}`;
    if (share.outcome_sig === sig) return;
    // WAG-401: the owner is changing the answer. The page stays open until a new answer comes.
    const held = this.reopened.get(caseId);
    if (held !== undefined) {
      if (held === sig) return;
      this.reopened.delete(caseId);
    }
    const lock = `outcome:${caseId}`;
    if (this.busy.has(lock) || this.gated(caseId, o.background)) return;
    const key = this.ownerToken(share.relay_id);
    if (!key) return;
    const ids = reply.choices ?? (reply.choice !== undefined ? [reply.choice] : []);
    const titles = ids.flatMap((id) => {
      const opt = detail.case.options.find((x) => x.id === id);
      const t = opt ? cut(opt.title ?? opt.label, ASK_CAPS.title) : "";
      return t === "" ? [] : [t];
    });
    const note = reply.message?.trim() ? cut(reply.message, 2000) : "";
    this.busy.add(lock);
    try {
      await this.call(`/api/cases/${share.relay_id}`, {
        method: "PATCH",
        key: key.token,
        device: key.device,
        scope: caseId,
        body: { status: "decided", decided: { options: titles, ...(note !== "" ? { note } : {}), at: Date.parse(reply.replaced_at ?? reply.created_at) || this.now() } },
      });
      store.setRelayOutcomeSig(caseId, sig);
      this.errors.delete(caseId);
    } catch (err) {
      this.errors.set(caseId, (err as Error).message);
    } finally {
      this.busy.delete(lock);
    }
  }

  // A follow-up ask (follows = a shared case) goes on the same link, as a new round with its ask. Only while
  // Sharing is on and the first case is shared.
  private async followUp(caseId: string): Promise<void> {
    if (!this.enabled() || !this.signedIn()) return;
    const store = this.opts.store;
    const parentId = store.followsCase(caseId);
    if (!parentId || store.getRelayShare(caseId)) return;
    const parent = store.getRelayShare(parentId);
    if (!parent) return;
    // "pending" differs from every real signature: the ask goes up even when the follow-up has no artifact.
    store.saveRelayShare({ case_id: caseId, relay_id: parent.relay_id, url: parent.url, mode: parent.mode, emails: parent.emails, root_case_id: parent.root_case_id ?? parent.case_id, ask_sig: "pending" });
    store.setRelayCommentsClosed(caseId, parent.comments_closed);
    this.touched.set(caseId, this.now());
    await this.syncRounds(caseId, { background: true });
    await this.syncAsk(caseId, { background: true });
    this.opts.store.recordEvent("case.updated", { case_id: caseId });
  }

  // --- the owner's actions on comments (WAG-394) ---

  private shareOf(caseId: string): { share: RelayShare; auth: { token: string; device: boolean } } {
    this.requireOn();
    const share = this.opts.store.getRelayShare(caseId);
    if (!share) throw new RelayError("That case is not shared.");
    const auth = this.ownerToken(share.relay_id);
    if (!auth) throw new RelayError(KEY_MISSING);
    return { share, auth };
  }

  private ownComment(caseId: string, commentId: string): void {
    if (this.opts.store.relayCommentCase(commentId)?.case_id !== caseId) throw new RelayError("That comment is not on this case.");
  }

  // Posts a reply under a thread: as the owner (the app) or as the Agent (waggle_update reply_to_comment).
  async replyToComment(caseId: string, commentId: string, body: string, as: "owner" | "agent"): Promise<void> {
    const { share, auth } = this.shareOf(caseId);
    this.ownComment(caseId, commentId);
    const made = await this.call<{ comment?: unknown }>(`/api/cases/${share.relay_id}/comments`, {
      method: "POST",
      key: auth.token,
      device: auth.device,
      scope: caseId,
      body: { parent_id: commentId, body, author_kind: as },
    });
    const c = RelayComment.safeParse(made.comment);
    if (!c.success) throw new RelayError("The sharing service sent an answer Waggle could not read.");
    this.opts.store.addRelayComments(caseId, [toInput(c.data)], share.root_case_id === null);
    this.opts.store.recordEvent("case.updated", { case_id: caseId });
  }

  async replyAsOwner(caseId: string, parentId: string, body: string): Promise<SharingState> {
    try {
      await this.replyToComment(caseId, parentId, body, "owner");
      this.errors.delete(caseId);
    } catch (err) {
      this.errors.set(caseId, (err as Error).message);
      throw err;
    }
    return this.state(caseId);
  }

  // A comment from the owner on the page with no parent (WAG-397): a new thread on the newest round the page has.
  async commentAsOwner(caseId: string, body: string): Promise<SharingState> {
    try {
      const { share, auth } = this.shareOf(caseId);
      const seqs = [...this.opts.store.relayRounds(caseId).values()];
      if (seqs.length === 0) throw new RelayError("The page has no round yet. Try again in a moment.");
      const made = await this.call<{ comment?: unknown }>(`/api/cases/${share.relay_id}/comments`, {
        method: "POST",
        key: auth.token,
        device: auth.device,
        scope: caseId,
        body: { round_seq: Math.max(...seqs), body, author_kind: "owner" },
      });
      const c = RelayComment.safeParse(made.comment);
      if (!c.success) throw new RelayError("The sharing service sent an answer Waggle could not read.");
      this.opts.store.addRelayComments(caseId, [toInput(c.data)], share.root_case_id === null);
      this.opts.store.recordEvent("case.updated", { case_id: caseId });
      this.errors.delete(caseId);
    } catch (err) {
      this.errors.set(caseId, (err as Error).message);
      throw err;
    }
    return this.state(caseId);
  }

  async resolveComment(caseId: string, commentId: string, resolved: boolean): Promise<SharingState> {
    const { share, auth } = this.shareOf(caseId);
    this.ownComment(caseId, commentId);
    try {
      const res = await this.call<{ comment?: { id?: unknown; resolved_at?: unknown; resolved_by?: unknown } }>(
        `/api/cases/${share.relay_id}/comments/${encodeURIComponent(commentId)}/${resolved ? "resolve" : "reopen"}`,
        { method: "POST", key: auth.token, device: auth.device, scope: caseId, body: {} },
      );
      const id = typeof res.comment?.id === "string" ? res.comment.id : commentId;
      const at = typeof res.comment?.resolved_at === "number" ? res.comment.resolved_at : null;
      this.opts.store.setRelayResolved(id, resolved ? (at ?? this.now()) : null, resolved && typeof res.comment?.resolved_by === "string" ? res.comment.resolved_by : null);
      this.errors.delete(caseId);
      this.opts.store.recordEvent("case.updated", { case_id: caseId });
    } catch (err) {
      this.errors.set(caseId, (err as Error).message);
      throw err;
    }
    return this.state(caseId);
  }

  // WAG-401: the owner is changing the answer (reopened = true): the page shows the case as open, without the Decided
  // block. The owner cancelled (reopened = false): the page shows the old decision again. A new answer needs neither
  // call: sendOutcome sends it as the new decision.
  async reopen(caseId: string, reopened: boolean): Promise<SharingState> {
    const { share, auth } = this.shareOf(caseId);
    const store = this.opts.store;
    const detail = store.getCase(caseId);
    const reply = detail?.replies[detail.replies.length - 1];
    if (!reply || reply.outcome !== "decide") return this.state(caseId);
    const sig = `${reply.id}:${reply.replaced_at ?? ""}`;
    try {
      if (reopened) {
        if (this.reopened.get(caseId) === sig) return this.state(caseId);
        await this.call(`/api/cases/${share.relay_id}`, { method: "PATCH", key: auth.token, device: auth.device, scope: caseId, body: { status: "open" } });
        this.reopened.set(caseId, sig);
        store.setRelayOutcomeSig(caseId, null);
      } else {
        if (!this.reopened.has(caseId)) return this.state(caseId);
        this.reopened.delete(caseId);
        await this.sendOutcome(caseId, { background: false });
      }
      this.errors.delete(caseId);
    } catch (err) {
      this.errors.set(caseId, (err as Error).message);
      throw err;
    }
    return this.state(caseId);
  }

  async closeComments(caseId: string, closed: boolean): Promise<SharingState> {
    const { share, auth } = this.shareOf(caseId);
    try {
      await this.call(`/api/cases/${share.relay_id}`, { method: "PATCH", key: auth.token, device: auth.device, scope: caseId, body: { comments_closed: closed } });
      for (const id of this.opts.store.relayShareCases(share.relay_id)) this.opts.store.setRelayCommentsClosed(id, closed);
      this.errors.delete(caseId);
      this.opts.store.recordEvent("case.updated", { case_id: caseId });
    } catch (err) {
      this.errors.set(caseId, (err as Error).message);
      throw err;
    }
    return this.state(caseId);
  }

  // The owner opened the case: its team comments are read. No network call.
  markSeen(caseId: string): SharingUnread {
    this.opts.store.markRelayCommentsRead(caseId);
    this.touched.set(caseId, this.now());
    return this.unread();
  }

  unread(): SharingUnread {
    return { cases: this.opts.store.unreadRelayComments() };
  }

  takeNotifications(): SharingNotifications {
    return { items: this.opts.store.takeRelayNotifications() };
  }

  // --- files of a round ---

  private roundFiles(caseId: string, n: number): RoundUpload {
    const art = this.opts.store.artifactPath(caseId, n);
    if (!art) throw new RelayError(`Round ${n} has no files to share.`);
    try {
      if (art.kind === "html_bundle") {
        const files = walk(art.root);
        const entry = relative(art.root, art.entry).split(sep).join("/");
        return checked(n, { entry, files });
      }
      if (art.kind === "screenshots") {
        const items = art.items ?? [];
        const files = items.map((item, i) => ({
          path: `${String(i + 1).padStart(2, "0")}${extname(item.path)}`,
          body_base64: readFileSync(item.path).toString("base64"),
        }));
        return checked(n, { entry: files[0]?.path ?? "", files, gallery: files.map((f) => f.path) });
      }
      const name = art.kind === "markdown" ? "index" : art.kind === "diagram" ? "diagram" : "screenshot";
      const path = `${name}${extname(art.root)}`;
      return checked(n, { entry: path, files: [{ path, body_base64: readFileSync(art.root).toString("base64") }] });
    } catch (err) {
      if (err instanceof RelayError) throw err;
      throw new RelayError(`Round ${n} could not be read from this Mac.`);
    }
  }

  // --- HTTP ---

  private requireOn(): void {
    if (!this.enabled()) throw new RelayError("Sharing is off. Turn it on in Settings.");
  }

  // The only place the daemon touches the network for sharing. Every caller checks enabled() first.
  // `scope` names what a failure holds back (a case id): one case failing never gates another.
  private async call<T>(
    path: string,
    o: { method?: string; body?: unknown; key?: string; device?: boolean; scope: string },
    okStatuses: number[] = [],
  ): Promise<T> {
    let res: Response;
    try {
      res = await this.doFetch(this.baseUrl + path, {
        method: o.method ?? "GET",
        headers: { "content-type": "application/json", ...(o.key ? { authorization: `Bearer ${o.key}` } : {}) },
        ...(o.body !== undefined ? { body: JSON.stringify(o.body) } : {}),
      });
    } catch {
      this.retryAt.set(o.scope, this.now() + this.retryMs);
      throw new RelayCallError("Waggle could not reach the sharing service. The case still works here.", null);
    }
    if (res.status === 401 && o.device && !okStatuses.includes(401)) {
      // Forget the sign-in only when the relay says the device token is not valid. A 401 for a case that
      // another account owns ("Owner access needed") keeps it.
      const code = await res
        .clone()
        .json()
        .then((j: unknown) => (j && typeof (j as { code?: unknown }).code === "string" ? (j as { code: string }).code : ""))
        .catch(() => "");
      if (code === "invalid_token") {
        this.clearSignIn(SIGN_IN_ENDED);
        throw new RelayCallError(SIGN_IN_ENDED, 401);
      }
    }
    if (!res.ok && !okStatuses.includes(res.status)) {
      this.retryAt.set(o.scope, this.now() + this.retryMs);
      this.log(`waggle: sharing service answered ${res.status} for ${o.method ?? "GET"} ${path.replace(/\/api\/cases\/[a-z0-9]+/, "/api/cases/<id>")}`);
      // The relay's own words ({"error": "50 emails at most"}) are plain sentences. Show them.
      const said = await res
        .json()
        .then((j: unknown) => (j && typeof (j as { error?: unknown }).error === "string" ? plainLine((j as { error: string }).error, 200) : ""))
        .catch(() => "");
      throw new RelayCallError(
        said !== "" ? `The sharing service said: ${said}${/[.!?]$/.test(said) ? "" : "."}` : `The sharing service answered ${res.status}. The case still works here.`,
        res.status,
      );
    }
    this.retryAt.delete(o.scope);
    return (await res.json().catch(() => ({}))) as T;
  }
}

function inviteCounts(v: unknown): InviteCounts {
  const n = (x: unknown) => (typeof x === "number" && Number.isInteger(x) && x >= 0 ? x : 0);
  const o = v && typeof v === "object" ? (v as Record<string, unknown>) : {};
  return { sent: n(o.sent), failed: n(o.failed), limited: n(o.limited) };
}

// A signature of the ask the page shows. A change in it means the page needs the new ask.
function askSig(c: Case | undefined): string {
  return JSON.stringify((c ? askForRelay(c) : undefined) ?? null);
}

function toInput(c: z.infer<typeof RelayComment>): RelayCommentInput {
  return {
    id: c.id,
    round_seq: c.round_seq,
    author_name: c.author_name,
    author_kind: c.author_kind === "owner" || c.author_kind === "member" || c.author_kind === "agent" ? c.author_kind : c.author_kind === "email" ? "member" : "guest",
    author_email: c.author_email ?? null,
    body: c.body,
    quote: c.quote ?? null,
    prefix: c.prefix ?? null,
    suffix: c.suffix ?? null,
    box: c.box ?? null,
    created_ms: c.created_at,
    parent_id: c.parent_id ?? null,
    resolved_ms: c.resolved_at ?? null,
    resolved_by: c.resolved_by ?? null,
  };
}

function askField(c: Case | undefined): { ask?: RelayAsk } {
  const ask = c ? askForRelay(c) : undefined;
  return ask ? { ask } : {};
}

function checked(n: number, upload: RoundUpload): RoundUpload {
  if (upload.files.length === 0) throw new RelayError(`Round ${n} has no files to share.`);
  if (upload.files.length > MAX_FILES) throw new RelayError(`Round ${n} has more than ${MAX_FILES} files.`);
  const big = upload.files.find((f) => f.body_base64.length > MAX_BASE64);
  if (big) throw new RelayError(`${big.path} in round ${n} is over 1 MB.`);
  if (upload.files.reduce((sum, f) => sum + f.body_base64.length, 0) > MAX_ROUND_BASE64) throw new RelayError(`Round ${n} is over 15 MB.`);
  return upload;
}

// Every regular file under dir, as relative paths with forward slashes. Links and .git are skipped.
function walk(dir: string): { path: string; body_base64: string }[] {
  const out: { path: string; body_base64: string }[] = [];
  const visit = (d: string): void => {
    for (const name of readdirSync(d).sort()) {
      if (name === ".git") continue;
      const p = join(d, name);
      const st = lstatSync(p);
      if (st.isSymbolicLink()) continue;
      if (st.isDirectory()) visit(p);
      else if (st.isFile()) out.push({ path: relative(dir, p).split(sep).join("/"), body_base64: readFileSync(p).toString("base64") });
    }
  };
  visit(dir);
  return out;
}

function toAgentComment(c: SharedComment, resolved: boolean, isNew: boolean): AgentSharedComment {
  // An area always tells the agent where. The words under the box if there are some, else the box itself.
  const area = c.box ? (c.box.near !== "" ? c.box.near : `a region ${c.box.w} by ${c.box.h} px at ${c.box.x}, ${c.box.y}`) : null;
  return {
    id: c.id,
    author_name: c.author_name,
    author_kind: c.author_kind,
    author_email: c.author_email,
    body: c.body,
    quote: c.quote,
    area,
    revision: c.revision,
    created_at: c.created_at,
    reply_to: c.parent_id,
    resolved,
    ...(isNew ? { new: true as const } : {}),
  };
}

export type { RelayShare };
