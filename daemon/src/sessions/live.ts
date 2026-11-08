// What the Claude Code mod says about its session (HAIL-134). Kept in memory only:
// it is a heartbeat, not history, and a daemon restart loses nothing the mod does
// not send again. Local only. The mod sends no prompt text, only the event and a
// tool name.
//
// "Fresh" means the mod polled recently. A mod that stopped (the session closed, the
// plugin was disabled) leaves state that goes stale, and the transcript reading of
// HAIL-124 takes over again.
import type { LiveState, ModEvent } from "../protocol";

// A mod polls every 20 s and holds each poll at most 25 s. One missed cycle is
// still attached; two are not.
export const MOD_ATTACHED_MS = 45_000;
// A mod that handed over a nudge has this long to take it.
export const MOD_PICKUP_MS = 8_000;
// HAIL-137: Codex hooks report on events and never poll, so their state stays fresh this long
// after the last event (a long tool call sends no event while it runs).
export const HOOKS_FRESH_MS = 15 * 60_000;
// HAIL-137: the Stop hook continues a turn at most this many times for one case.
export const MOD_STOP_MAX_CONTINUES = 3;

interface Entry {
  phase: "working" | "idle" | null;
  since: number;
  lastTool: string | null;
  lastToolAt: number | null;
  toolCount: number;
  lastEvent: LiveState["last_event"] | null;
  lastEventAt: number;
  lastPollAt: number;
  pendingPolls: number;
  version: string | null;
  // True when the Codex hooks reported (no poll heartbeat).
  hooks: boolean;
}

export interface QueuedNudge {
  case_id: string;
  text: string;
}

interface PendingNudge {
  nudge: QueuedNudge;
  taken: (ok: boolean) => void;
}

export class ModRegistry {
  private entries = new Map<string, Entry>();
  private nudges = new Map<string, PendingNudge>();
  // Cases whose nudge the mod took and may still report as failed.
  private handedOver = new Set<string>();
  private wakers = new Map<string, Set<() => void>>();
  // HAIL-137: Codex hook session id -> Waggle session id, for a hook session whose id the
  // shim could not share.
  private aliases = new Map<string, string>();
  private stopContinues = new Map<string, number>();

  constructor(
    private now: () => number = Date.now,
    private pickupMs: number = MOD_PICKUP_MS,
  ) {}

  private entry(id: string): Entry {
    let e = this.entries.get(id);
    if (!e) {
      e = {
        phase: null,
        since: 0,
        lastTool: null,
        lastToolAt: null,
        toolCount: 0,
        lastEvent: null,
        lastEventAt: 0,
        lastPollAt: 0,
        pendingPolls: 0,
        version: null,
        hooks: false,
      };
      this.entries.set(id, e);
    }
    return e;
  }

  // The Waggle session a hook session id stands for (itself when not linked).
  linked(hookId: string): string {
    return this.aliases.get(hookId) ?? hookId;
  }

  // Says that `hookId` (a Codex hook session) is Waggle session `sessionId`. Live state
  // reported under the hook id so far moves to the Waggle session.
  link(hookId: string, sessionId: string): void {
    if (hookId === sessionId) return;
    this.aliases.set(hookId, sessionId);
    const early = this.entries.get(hookId);
    if (early) {
      this.entries.delete(hookId);
      if (!this.entries.has(sessionId)) this.entries.set(sessionId, early);
    }
  }

  // True when some hook session is already linked to this Waggle session.
  isLinkTarget(sessionId: string): boolean {
    for (const v of this.aliases.values()) if (v === sessionId) return true;
    return false;
  }

  // Counts one Stop continue for `caseId`. True while the count is within the cap.
  noteStopContinue(caseId: string): boolean {
    const n = (this.stopContinues.get(caseId) ?? 0) + 1;
    this.stopContinues.set(caseId, n);
    return n <= MOD_STOP_MAX_CONTINUES;
  }

  report(id: string, event: ModEvent, tool?: string, count = 1, hooks = false): void {
    if (event === "nudge.failed") return;
    if (event === "session.end") {
      this.entries.delete(id);
      for (const [k, v] of this.aliases) if (k === id || v === id) this.aliases.delete(k);
      return;
    }
    const e = this.entry(id);
    const t = this.now();
    e.lastEvent = event;
    e.lastEventAt = t;
    if (hooks) e.hooks = true;
    // The report itself proves the mod is alive. Hooks do not poll: they must not look like
    // a polling mod (that would make the session nudgeable through a mod that is not there).
    else e.lastPollAt = Math.max(e.lastPollAt, t);
    if (event === "turn.start") {
      e.phase = "working";
      e.since = t;
      e.toolCount = 0;
      e.lastTool = null;
      e.lastToolAt = null;
    } else if (event === "turn.complete") {
      e.phase = "idle";
      e.since = t;
    } else if (event === "tool.call") {
      // A tool call proves a turn is running even if turn.start was missed.
      if (e.phase !== "working") {
        e.phase = "working";
        e.since = t;
        e.toolCount = 0;
      }
      e.toolCount += count;
      if (tool) {
        e.lastTool = tool;
        e.lastToolAt = t;
      }
    }
  }

  beginPoll(id: string, version?: string): void {
    const e = this.entry(id);
    e.pendingPolls += 1;
    e.lastPollAt = this.now();
    if (version) e.version = version;
  }

  endPoll(id: string): void {
    const e = this.entry(id);
    e.pendingPolls = Math.max(0, e.pendingPolls - 1);
    e.lastPollAt = this.now();
  }

  // The mod of this session is polling (or just did).
  attached(id: string): boolean {
    const e = this.entries.get(id);
    if (!e) return false;
    return e.pendingPolls > 0 || this.now() - e.lastPollAt <= MOD_ATTACHED_MS;
  }

  // The reported state while the mod is attached and has reported at least once.
  live(id: string): LiveState | null {
    const e = this.entries.get(id);
    if (!e || !e.phase || !e.lastEvent) return null;
    const fresh = this.attached(id) || (e.hooks && this.now() - e.lastEventAt <= HOOKS_FRESH_MS);
    if (!fresh) return null;
    const iso = (ms: number) => new Date(ms).toISOString();
    return {
      phase: e.phase,
      since: iso(e.since),
      last_tool: e.lastTool,
      last_tool_at: e.lastToolAt === null ? null : iso(e.lastToolAt),
      tool_count: e.toolCount,
      last_event: e.lastEvent,
      last_event_at: iso(e.lastEventAt),
    };
  }

  // --- nudges handed to the mod ---

  // Queues one nudge for the mod's next poll. Resolves true when a poll took it,
  // false when none did within MOD_PICKUP_MS.
  queueNudge(id: string, nudge: QueuedNudge): Promise<boolean> {
    this.nudges.get(id)?.taken(false);
    return new Promise<boolean>((resolve) => {
      const timer = setTimeout(() => {
        if (this.nudges.get(id)?.nudge === nudge) this.nudges.delete(id);
        resolve(false);
      }, this.pickupMs);
      this.nudges.set(id, {
        nudge,
        taken: (ok) => {
          clearTimeout(timer);
          resolve(ok);
        },
      });
      this.wake(id);
    });
  }

  peekNudge(id: string): QueuedNudge | null {
    return this.nudges.get(id)?.nudge ?? null;
  }

  // The poll that returns the nudge takes it.
  takeNudge(id: string): QueuedNudge | null {
    const pending = this.nudges.get(id);
    if (!pending) return null;
    this.nudges.delete(id);
    this.handedOver.add(pending.nudge.case_id);
    pending.taken(true);
    return pending.nudge;
  }

  // True once per handed-over case: the mod then failed to submit it.
  failNudge(caseId: string): boolean {
    return this.handedOver.delete(caseId);
  }

  // --- long poll ---

  // Calls `fn` once when something for this session happens (a nudge is queued).
  onWake(id: string, fn: () => void): () => void {
    let set = this.wakers.get(id);
    if (!set) this.wakers.set(id, (set = new Set()));
    set.add(fn);
    return () => {
      set!.delete(fn);
      if (set!.size === 0) this.wakers.delete(id);
    };
  }

  private wake(id: string): void {
    for (const fn of [...(this.wakers.get(id) ?? [])]) fn();
  }
}
