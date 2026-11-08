// The connector layer (HAIL-144). A chat connector carries an ask to the operator's phone or
// chat app and brings a reply back. The ask flow talks to this one interface, so Slack
// (HAIL-145) plugs in without touching it. A connector never touches knock.db itself: replies
// go in through the host, and the manager remembers the message each connector sent.

export type ConnectorId = "telegram" | "slack";

// What a chat shows for a new ask. Plain text only: case content comes from an agent, so a
// connector never renders it as HTML or markdown.
export interface AskMessage {
  case_id: string;
  title: string;
  // The work and the agent in plain words ("Pricing page · Claude Code"), never a branch or a path (HAIL-231).
  work_line: string;
  // The first line of the need, markers stripped.
  need_line: string;
  // The recommended option's short title, or null when the ask has none.
  recommendation: string | null;
  recommendation_why: string;
  // Offered options. Empty for a free-text ask. Buttons only for select "one".
  options: { id: string; title: string }[];
  select: "one" | "many";
  // Words for the artifact when the ask has one ("prototype"), else null. Artifacts never travel.
  artifact_word: string | null;
}

// What a connector remembers about the message it sent: `key` is unique per connector and finds
// the case again when the operator replies to that message; `ref` is the connector's own data.
export interface SentMessage {
  key: string;
  ref: unknown;
}

export interface OutcomeMessage {
  title: string;
  // "Answered: Approval rules", "Answered on your Mac", ...
  text: string;
}

export interface AnswerInput {
  case_id: string;
  // Makes a repeat of the same tap or message a no-op. The connector builds it.
  key: string;
  choice?: string;
  message?: string;
  intent?: "decision" | "more_detail";
}

export type AnswerResult =
  | { ok: true; duplicate: boolean }
  | { ok: false; reason: "closed" | "not_offered" | "unknown_case" };

// What the manager gives a connector.
export interface ConnectorHost {
  // Submits a reply as a normal reply.submit with this connector as its source.
  answer(connector: ConnectorId, input: AnswerInput): AnswerResult;
  // The case a chat message was sent for, or null.
  caseForMessage(connector: ConnectorId, key: string): string | null;
  // The `ref` the connector saved for a case's message, or null.
  messageRef(connector: ConnectorId, caseId: string): unknown | null;
}

export interface Connector {
  readonly id: ConnectorId;
  // True while the connector is on and can carry an ask: the daemon makes network calls for it.
  isActive(): boolean;
  // Resume from saved state at daemon start. With nothing saved this does nothing and makes no
  // network call.
  start(): void;
  // Stop all work (daemon shutdown). Saved state stays.
  stop(): void;
  // Forget the connection: stop, drop the secret and the saved chat.
  disconnect(): Promise<void>;
  // Send a new ask. Returns what to remember, or null when nothing was sent.
  sendAsk(ask: AskMessage): Promise<SentMessage | null>;
  // Change a sent message to show how the ask ended.
  updateOutcome(sent: SentMessage, outcome: OutcomeMessage): Promise<void>;
}
