import { workLine } from "./naming";
import type { EventBus } from "../events";
import { stripSourceMarkers } from "../protocol";
import type { Case, Event, PlanRound, PlanStage, Reply } from "../protocol";
import { ChoiceNotOfferedError, type Store } from "../store";
import type {
  AnswerInput,
  AnswerResult,
  AskMessage,
  Connector,
  ConnectorHost,
  ConnectorId,
  OutcomeMessage,
} from "./types";

// The first line of agent text as plain text: markers stripped (docs/protocol-mvp.md, text from
// agents). Chats never get markdown from an agent.
export function plainLine(text: string, max = 300): string {
  const line =
    stripSourceMarkers(text)
      .split("\n")
      .map((l) => l.trim())
      .find((l) => l !== "") ?? "";
  const plain = line
    .replace(/^#{1,6}\s+/, "")
    .replace(/^[-*+]\s+/, "")
    .replace(/^\d+[.)]\s+/, "")
    .replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/[*_`~]/g, "")
    .trim();
  return plain.length > max ? `${plain.slice(0, max - 1).trimEnd()}...` : plain;
}

const ARTIFACT_WORDS: Record<string, string> = {
  html_bundle: "prototype",
  markdown: "write-up",
  screenshot: "screenshot",
  screenshots: "screenshots",
  diagram: "diagram",
};

function optionTitle(o: { title?: string; label: string }): string {
  return plainLine(o.title ?? o.label, 60);
}

// The plain second line of a plan ask (HAIL-151): "Brainstorm · question 3 of ~5". The Mac app has
// the same wording in PlanStageText, so the queue row and the phone read alike.
export function planStageLine(stage: PlanStage): string {
  const count = (noun: string): string => {
    if (stage.step === undefined) return "";
    const total = stage.total !== undefined ? ` of ${stage.total_is_estimate ? "~" : ""}${stage.total}` : "";
    return ` · ${noun} ${stage.step}${total}`;
  };
  switch (stage.name) {
    case "questions":
      return `Brainstorm${count("question")}`;
    case "approaches":
      return "Approaches · pick one";
    case "design":
      return `Design${count("section")}`;
    case "spec":
      return "Spec · ready for review";
  }
}

// `question` is the text of a plan ask's newest round; any other ask shows its need. `round` is that
// round: the phone notes an artifact only when the round itself sent one (HAIL-156).
export function askMessageFor(c: Case, question?: string, round?: PlanRound): AskMessage {
  const artifactKind = round !== undefined ? (round.own_artifact ? round.artifact_kind : null) : c.has_artifact ? (c.artifact_kind ?? "") : null;
  const recommended = c.options.find((o) => o.id === c.recommendation);
  return {
    case_id: c.id,
    title: c.plan ? `${planStageLine(c.plan.stage)} · ${plainLine(c.title, 150)}` : plainLine(c.title, 200),
    work_line: plainLine(workLine(c), 200),
    need_line: plainLine(question && question !== "" ? question : c.need),
    recommendation: recommended ? optionTitle(recommended) : null,
    recommendation_why: plainLine(c.recommendation_why),
    options: c.options.map((o) => ({ id: o.id, title: optionTitle(o) })),
    select: c.select,
    artifact_word: artifactKind !== null ? (ARTIFACT_WORDS[artifactKind] ?? "attachment") : null,
  };
}

// How an ask ended, in plain words, for the message a chat shows. Null while the ask is open.
export function outcomeFor(c: Case, reply: Reply | null): string | null {
  if (!reply) return c.status === "resolved" ? "Closed on your Mac" : null;
  if (reply.state === "failed" || reply.state === "superseded") return null;
  if (reply.intent === "more_detail") return "Asked for more detail";
  if (reply.intent === "discuss") return "Talking it over on your Mac";
  if (reply.source === "mac") return "Answered on your Mac";
  if (reply.choice !== undefined) {
    const o = [...c.options, ...c.first_options].find((x) => x.id === reply.choice);
    return `Answered: ${o ? optionTitle(o) : plainLine(reply.choice, 60)}`;
  }
  if (reply.message !== undefined) return `Answered: ${plainLine(reply.message, 80)}`;
  return "Answered";
}

// Owns the connectors and joins them to the ask flow: a new ask goes out to every active
// connector, a reply from a connector comes in as a normal reply with its source, and an ended ask
// edits the chat message. Nothing here knows Telegram or Slack.
export class ConnectorManager implements ConnectorHost {
  private unsubscribe: (() => void) | null = null;

  private connectors: Connector[];

  constructor(
    private store: Store,
    private bus: EventBus,
    connectors: Connector[] = [],
    private log: (line: string) => void = (line) => process.stderr.write(`${line}\n`),
  ) {
    this.connectors = [...connectors];
  }

  // A connector is added before start(). The host and the connector need each other, so the
  // manager is made first.
  add(connector: Connector): void {
    this.connectors.push(connector);
  }

  get(id: ConnectorId): Connector | undefined {
    return this.connectors.find((c) => c.id === id);
  }

  start(): void {
    this.unsubscribe = this.bus.subscribe((event) => this.onEvent(event));
    for (const c of this.connectors) c.start();
  }

  stop(): void {
    this.unsubscribe?.();
    this.unsubscribe = null;
    for (const c of this.connectors) c.stop();
  }

  // The daemon must not idle-exit while a connector is on and an ask waits: a phone reply would
  // have nowhere to go.
  keepAlive(): boolean {
    return this.connectors.some((c) => c.isActive()) && this.store.countNeedsYouCases() > 0;
  }

  // --- ConnectorHost ---

  answer(connector: ConnectorId, input: AnswerInput): AnswerResult {
    // The daemon owns the idempotency key: a repeat of the same tap or message finds the reply
    // it already made and never makes a second one.
    const key = `${connector}:${input.key}`;
    if (this.store.findReplyByIdempotencyKey(key) !== null) return { ok: true, duplicate: true };
    const c = this.store.getCase(input.case_id)?.case;
    if (!c) return { ok: false, reason: "unknown_case" };
    if (c.status !== "needs_you") return { ok: false, reason: "closed" };
    try {
      this.store.submitReply(input.case_id, {
        idempotency_key: key,
        ...(input.choice !== undefined ? { choice: input.choice } : {}),
        ...(input.message !== undefined ? { message: input.message } : {}),
        intent: input.intent ?? "decision",
        comments: [],
        captures: [],
        source: connector,
      });
    } catch (err) {
      if (err instanceof ChoiceNotOfferedError) return { ok: false, reason: "not_offered" };
      throw err;
    }
    return { ok: true, duplicate: false };
  }

  caseForMessage(connector: ConnectorId, key: string): string | null {
    return this.store.findConnectorMessageByKey(connector, key)?.case_id ?? null;
  }

  messageRef(connector: ConnectorId, caseId: string): unknown | null {
    return this.store.findConnectorMessage(connector, caseId)?.ref ?? null;
  }

  // --- the ask flow ---

  private onEvent(event: Event): void {
    if (!event.case_id) return;
    if (event.type === "case.created") void this.sendAsk(event.case_id);
    else if (event.type === "reply.state_changed" || event.type === "case.updated") {
      const caseId = event.case_id;
      void this.nextPlanRound(caseId).then(() => this.syncOutcome(caseId));
    }
  }

  // A plan ask (HAIL-151) is one case with many rounds. A new round goes to the phone as a new
  // message, like a normal ask, once the message for the earlier round is closed out. The new message
  // replaces the saved one for the case.
  private async nextPlanRound(caseId: string): Promise<void> {
    const c = this.store.getCase(caseId)?.case;
    if (!c?.plan || c.status !== "needs_you") return;
    const rounds = this.store.getCase(caseId)?.plan_rounds ?? [];
    const newest = rounds[rounds.length - 1];
    if (!newest) return;
    const due = this.connectors.some((connector) => {
      const sent = this.store.findConnectorMessage(connector.id, caseId);
      return connector.isActive() && sent !== null && sent.outcome !== null && sent.created_at < newest.created_at;
    });
    if (due) await this.sendAsk(caseId);
  }

  private async sendAsk(caseId: string): Promise<void> {
    const detail = this.store.getCase(caseId);
    const c = detail?.case;
    if (!c || c.status !== "needs_you") return;
    const ask = askMessageFor(c, detail?.plan_rounds?.at(-1)?.question, detail?.plan_rounds?.at(-1));
    for (const connector of this.connectors) {
      if (!connector.isActive()) continue;
      try {
        const sent = await connector.sendAsk(ask);
        if (sent) this.store.saveConnectorMessage(connector.id, caseId, sent.key, sent.ref);
      } catch (err) {
        this.log(`waggle: ${connector.id} could not send an ask: ${(err as Error).message}`);
      }
    }
    // The ask may have been answered on the Mac while the message was on its way.
    await this.syncOutcome(caseId);
  }

  private async syncOutcome(caseId: string): Promise<void> {
    const detail = this.store.getCase(caseId);
    if (!detail) return;
    const c = detail.case;
    const reply = c.latest_reply_id ? this.store.getReply(c.latest_reply_id) : null;
    const text = outcomeFor(c, reply);
    if (text === null) return;
    const outcome: OutcomeMessage = { title: plainLine(c.title, 200), text };
    for (const connector of this.connectors) {
      const sent = this.store.findConnectorMessage(connector.id, caseId);
      if (!sent || sent.outcome === text || !connector.isActive()) continue;
      // Record first: a second event during the edit must not edit twice.
      this.store.setConnectorOutcome(connector.id, caseId, text);
      try {
        await connector.updateOutcome({ key: sent.msg_key, ref: sent.ref }, outcome);
      } catch (err) {
        this.log(`waggle: ${connector.id} could not update a message: ${(err as Error).message}`);
      }
    }
  }
}

export { ChoiceNotOfferedError };
