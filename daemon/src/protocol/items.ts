// The three blocks model (WAG-312, spec WAG-310): Ask, Reply, Round.
//
// An Ask carries items. This module turns every old waggle_ask shape (options, questions, review, plan,
// reply-only) into items, projects items back to the old columns for the dual write, derives the items of
// a stored round, and classifies a reply as decide or talk. Every function here is pure: no store, no
// clock, no I/O. The schemas (Item, Group, ItemAnswer, Round, ReplyOutcome) live in nouns.ts and
// states.ts because Case and Reply need them; they are re-exported here so one import finds them all.
import {
  type Artifact,
  type Group,
  type Item,
  type ItemAnswer,
  type Option,
  type PlanStage,
  POINT_DEFAULT_CHOICES,
  type PointOption,
  type Question,
  type PointAnswer,
  type QuestionPoint,
} from "./nouns";
import type { ReplyOutcome } from "./states";
import { type ItemInput, type KnockAskInput, type KnockUpdateInput, recommendationIds } from "./mcp";

export { Group, Item, ItemAnswer, ItemAnswers, ITEMS_MAX, ItemSelect, Round } from "./nouns";
export { ReplyOutcome } from "./states";

// The ask, normalised. `kind` is the stored kind: a plan is a question with a stage.
export interface NormalizedAsk {
  kind: "question" | "review";
  title: string;
  need: string;
  why: string;
  items: Item[];
  // The artifact shortcut becomes a list of one. Empty when the ask has none.
  artifacts: Artifact[];
  stage?: PlanStage;
  // Values the legacy columns must keep exactly as the agent sent them, when no item can hold them: the
  // ask-level recommendation of a questions request, and the free-text recommendation of a review.
  legacy?: { recommendation?: string | string[]; recommendation_why?: string };
  follows?: string;
  replaces?: string;
  topic?: string;
  session_title?: string;
}

// What the old columns hold for an ask: cases.kind, options_json, select_mode, max_choices,
// recommendation, recommendation_why, recommendations_json and questions_json.
export interface LegacyAsk {
  kind: "question" | "review";
  options: Option[];
  select: "one" | "many";
  max: number | null;
  recommendation: string;
  recommendation_why: string;
  recommendations: string[];
  questions: Question[];
}

const REVIEW_APPROVE = "approve";
const REVIEW_CHANGES = "request_changes";
export const MAIN_ITEM_ID = "main";

// The item a review shortcut builds when it gives no options (spec 2.4).
export const REVIEW_OPTIONS: Option[] = [
  { id: REVIEW_APPROVE, title: "Approve", label: "Approve: ship it as it is" },
  { id: REVIEW_CHANGES, title: "Request changes", label: "Request changes: use my comments" },
];

// Drops keys whose value is undefined, so two equal items are deep-equal and serialise the same.
function compact<T extends object>(o: T): T {
  return Object.fromEntries(Object.entries(o).filter(([, v]) => v !== undefined)) as T;
}

// "Request changes", "request-changes" and "REQUEST_CHANGES" all name the second review option.
function reviewOptionId(text: string): string | null {
  const key = text.trim().toLowerCase().replace(/[\s-]+/g, "_");
  return key === REVIEW_APPROVE || key === REVIEW_CHANGES ? key : null;
}

// The recommendation of a "many" item is always a list; of a "one" or "reply" item, always a string.
function canonicalRecommendation(select: Item["select"], rec: string | string[] | undefined): string | string[] | undefined {
  if (rec === undefined) return undefined;
  if (select === "many") return recommendationIds(rec);
  return Array.isArray(rec) ? rec[0] : rec;
}

function makeItem(parts: {
  id: string;
  question?: string;
  select: Item["select"];
  max?: number;
  options?: Option[];
  recommendation?: string | string[];
  recommendation_why?: string;
  group?: Group;
}): Item {
  return compact({
    id: parts.id,
    question: parts.question,
    select: parts.select,
    max: parts.select === "many" ? parts.max : undefined,
    options: parts.options ?? [],
    recommendation: canonicalRecommendation(parts.select, parts.recommendation),
    recommendation_why: parts.recommendation_why,
    group: parts.group,
  });
}

function itemFromInput(input: ItemInput, fallback: { recommendation?: string | string[]; recommendation_why?: string }): Item {
  const select = input.select ?? (input.options !== undefined ? "one" : "reply");
  return makeItem({
    id: input.id,
    question: input.question,
    select,
    max: input.max,
    options: input.options,
    recommendation: input.recommendation ?? fallback.recommendation,
    recommendation_why: input.recommendation_why ?? fallback.recommendation_why,
    group: input.group,
  });
}

// A point option (a string, or { label, pros?, cons? }) as an Option with a derived id o1, o2, ...
function optionFromPoint(o: PointOption, n: number): Option {
  if (typeof o === "string") return { id: `o${n}`, label: o };
  return compact({ id: `o${n}`, label: o.label, pros: o.pros, cons: o.cons, effects: o.effects });
}

// One item per point, grouped by question. The item id is "<question id>/<point id>" (up to 81 characters).
export function itemsFromQuestions(questions: readonly Question[]): Item[] {
  return questions.flatMap((q) => {
    const group: Group = compact({
      id: q.id,
      title: q.title,
      now: q.now,
      variants: q.variants,
      variant_label: q.variant_label,
    });
    return q.points.map((p) =>
      makeItem({
        id: `${q.id}/${p.id}`,
        question: p.text,
        select: "one",
        options: (p.options ?? POINT_DEFAULT_CHOICES).map((o, i) => optionFromPoint(o, i + 1)),
        group,
      }),
    );
  });
}

// A canonical review: an artifact and one "one" item with exactly the Approve and Request changes options.
function looksLikeReview(items: Item[], artifacts: Artifact[]): boolean {
  if (artifacts.length === 0 || items.length !== 1) return false;
  const item = items[0]!;
  if (item.select !== "one" || item.options.length !== 2) return false;
  const ids = item.options.map((o) => o.id);
  return ids.includes(REVIEW_APPROVE) && ids.includes(REVIEW_CHANGES);
}

// The review item for `kind: "review"` with no options and no items (spec 2.4). A recommendation that
// names an option marks it. Free text marks nothing and becomes the start of recommendation_why.
function reviewItem(recommendation: string, why: string): { item: Item; legacy: NormalizedAsk["legacy"] } {
  const optionId = reviewOptionId(recommendation);
  if (optionId !== null) {
    return {
      item: makeItem({ id: "decision", select: "one", options: REVIEW_OPTIONS, recommendation: optionId, recommendation_why: why }),
      legacy: undefined,
    };
  }
  const text = recommendation.trim();
  const lead = /[.!?]$/.test(text) ? text : `${text}.`;
  return {
    item: makeItem({
      id: "decision",
      select: "one",
      options: REVIEW_OPTIONS,
      recommendation_why: text === "" ? why : `${lead} ${why}`.trim(),
    }),
    legacy: { recommendation, recommendation_why: why },
  };
}

// Turns any parsed waggle_ask input, old or new, into the one shape. `input` must already have passed
// KnockAskInput. The old shortcuts map as in spec table 2.3.
export function normalizeAsk(input: KnockAskInput): NormalizedAsk {
  const artifacts = input.artifacts ?? (input.artifact !== undefined ? [input.artifact] : []);
  let items: Item[];
  let legacy: NormalizedAsk["legacy"];
  if (input.items !== undefined) {
    // A top-level recommendation belongs to the one item of a single-item ask (KnockAskInput checks it).
    const fallback = input.items.length === 1 ? { recommendation: input.recommendation, recommendation_why: input.recommendation_why } : {};
    items = input.items.map((i) => itemFromInput(i, fallback));
  } else if (input.questions !== undefined) {
    items = itemsFromQuestions(input.questions);
    legacy = { recommendation: input.recommendation, recommendation_why: input.recommendation_why };
  } else if (input.options !== undefined) {
    items = [
      makeItem({
        id: MAIN_ITEM_ID,
        select: input.select ?? "one",
        max: input.max,
        options: input.options,
        recommendation: input.recommendation,
        recommendation_why: input.recommendation_why,
      }),
    ];
  } else if (input.kind === "review") {
    const review = reviewItem(typeof input.recommendation === "string" ? input.recommendation : "", input.recommendation_why ?? "");
    items = [review.item];
    legacy = review.legacy;
  } else {
    // The reply-only ask: the recommendation text is the suggested reply.
    items = [
      makeItem({
        id: MAIN_ITEM_ID,
        select: "reply",
        recommendation: typeof input.recommendation === "string" ? input.recommendation : undefined,
        recommendation_why: input.recommendation_why,
      }),
    ];
  }
  const kind = input.kind === "review" ? "review" : input.kind === undefined && looksLikeReview(items, artifacts) ? "review" : "question";
  return compact({
    kind,
    title: input.title,
    need: input.need,
    why: input.why,
    items,
    artifacts,
    stage: input.stage,
    legacy: legacy !== undefined ? compact(legacy) : undefined,
    follows: input.follows,
    replaces: input.replaces,
    topic: input.topic,
    session_title: input.session_title,
  });
}

// The Round a waggle_update carries (spec 1.4): any of an answer, a revised artifact, new items, a stage
// label and done. The options shortcut becomes one item, as in an ask.
export interface NormalizedRound {
  case_id: string;
  message: string;
  artifact?: Artifact;
  stage?: PlanStage;
  items?: Item[];
  done?: boolean;
  working?: boolean;
  session_title?: string;
}

export function normalizeUpdate(input: KnockUpdateInput): NormalizedRound {
  let items: Item[] | undefined;
  if (input.items !== undefined) {
    items = input.items.map((i) => itemFromInput(i, {}));
  } else if (input.options !== undefined) {
    items = [
      makeItem({
        id: MAIN_ITEM_ID,
        select: input.select ?? "one",
        max: input.max,
        options: input.options,
        recommendation: input.recommendation,
        recommendation_why: input.recommendation_why,
      }),
    ];
  }
  return compact({
    case_id: input.case_id,
    message: input.message,
    artifact: input.artifact,
    stage: input.stage,
    items,
    done: input.done,
    working: input.working,
    session_title: input.session_title,
  });
}

// --- Items back to the legacy columns (the dual write, spec 2.6) ---

// A point of the legacy shape for one item. A "many" item degrades to a single pick, and a "reply" item to
// the default Yes, No and Talk with the team.
function pointOfItem(item: Item, groupId: string | undefined): QuestionPoint {
  const text = item.question ?? item.id;
  const id = groupId !== undefined && item.id.startsWith(`${groupId}/`) ? item.id.slice(groupId.length + 1) : item.id;
  const labels = item.options.map((o) => o.label);
  const isDefault =
    item.options.length === POINT_DEFAULT_CHOICES.length &&
    labels.every((l, i) => l === POINT_DEFAULT_CHOICES[i]) &&
    item.options.every((o) => o.pros === undefined && o.cons === undefined && o.effects === undefined);
  if (item.select === "reply" || item.options.length === 0 || isDefault) return { id, text };
  return {
    id,
    text,
    options: item.options.map((o) => (o.pros !== undefined || o.cons !== undefined || o.effects !== undefined
        ? compact({ label: o.label, pros: o.pros, cons: o.cons, effects: o.effects })
        : o.label),
    ),
  };
}

function questionsOfItems(items: Item[]): Question[] {
  const questions: Question[] = [];
  const byGroup = new Map<string, Question>();
  for (const item of items) {
    const g = item.group;
    if (g === undefined) {
      questions.push({ id: item.id, title: item.question ?? item.id, points: [pointOfItem(item, undefined)] });
      continue;
    }
    let q = byGroup.get(g.id);
    if (q === undefined) {
      q = compact({ id: g.id, title: g.title, now: g.now, points: [], variants: g.variants, variant_label: g.variant_label });
      byGroup.set(g.id, q);
      questions.push(q);
    }
    q.points.push(pointOfItem(item, g.id));
  }
  return questions;
}

// The legacy columns for a normalised ask, so an old app and cases.list keep their meaning. One item
// fills options and recommendation; more than one fills questions. The Question `artifact_ref` field is
// reserved and ignored, so it does not survive the round trip. A default-choices point comes back
// without options, and an option object with no pros or cons comes back as a plain string.
export function projectLegacy(ask: Pick<NormalizedAsk, "kind" | "items" | "legacy">): LegacyAsk {
  const only = ask.items.length === 1 ? ask.items[0]! : undefined;
  const recommendation = ask.legacy?.recommendation ?? only?.recommendation;
  const ids = recommendation === undefined ? [] : recommendationIds(recommendation).filter((id) => id !== "");
  const why = ask.legacy?.recommendation_why ?? only?.recommendation_why ?? "";
  if (only === undefined) {
    return {
      kind: ask.kind,
      options: [],
      select: "one",
      max: null,
      recommendation: ids[0] ?? "",
      recommendation_why: why,
      recommendations: ids,
      questions: questionsOfItems(ask.items),
    };
  }
  return {
    kind: ask.kind,
    options: only.select === "reply" ? [] : only.options,
    select: only.select === "many" ? "many" : "one",
    max: only.select === "many" ? (only.max ?? null) : null,
    recommendation: ids[0] ?? "",
    recommendation_why: why,
    recommendations: ids,
    questions: [],
  };
}

// --- Items of a stored round (spec 3.3) ---

// The columns of one option_sets row that items come from. `items_json` is NULL for every row written
// before migration 41.
export interface RoundRow {
  seq: number;
  items_json?: string | null;
  options_json: string;
  recommendation: string;
  recommendation_why?: string | null;
  select_mode?: "one" | "many" | null;
  max_choices?: number | null;
  recommendations_json?: string | null;
}

export interface RoundCaseRow {
  questions_json?: string | null;
}

// The items of one round, read from the row: its own items, else the questions of the ask (round 0),
// else its options, else one reply item. No limit applies: stored requests may exceed the input limits.
export function itemsOfRound(row: RoundRow, caseRow: RoundCaseRow): Item[] {
  if (row.items_json !== null && row.items_json !== undefined) return JSON.parse(row.items_json) as Item[];
  if (row.seq === 0) {
    const questions = JSON.parse(caseRow.questions_json ?? "[]") as Question[];
    if (questions.length > 0) return itemsFromQuestions(questions);
  }
  const options = JSON.parse(row.options_json) as Option[];
  const why = row.recommendation_why ? row.recommendation_why : undefined;
  if (options.length > 0) {
    const select = row.select_mode === "many" ? "many" : "one";
    const listed = row.recommendations_json !== null && row.recommendations_json !== undefined ? (JSON.parse(row.recommendations_json) as string[]) : [];
    const stored = listed.length > 0 ? listed : row.recommendation ? [row.recommendation] : [];
    const ids = stored.filter((id) => options.some((o) => o.id === id));
    // A recommendation that names no option is free text (a review sent it): it leads the why, as in normalizeAsk.
    const freeText = ids.length === 0 && stored.length > 0 ? stored[0]!.trim() : "";
    const lead = freeText === "" ? "" : /[.!?]$/.test(freeText) ? freeText : `${freeText}.`;
    return [
      makeItem({
        id: MAIN_ITEM_ID,
        select,
        max: row.max_choices ?? undefined,
        options,
        recommendation: select === "many" ? (ids.length > 0 ? ids : undefined) : ids[0],
        recommendation_why: lead === "" ? why : `${lead} ${why ?? ""}`.trim(),
      }),
    ];
  }
  return [
    makeItem({
      id: MAIN_ITEM_ID,
      select: "reply",
      recommendation: row.recommendation ? row.recommendation : undefined,
      recommendation_why: why,
    }),
  ];
}

// --- Reply outcome (spec 1.3) ---

// The parts of a reply that replyOutcome reads. Reply and the reply.submit params both fit.
export interface ReplyLike {
  intent: "decision" | "more_detail" | "discuss";
  message?: string;
  choice?: string;
  choices?: readonly string[];
  answers?: readonly unknown[];
  item_answers?: readonly unknown[];
}

// The parts of a case that replyOutcome reads: its items, or the legacy options and questions.
export interface OutcomeCase {
  items?: readonly Item[];
  options?: readonly unknown[];
  questions?: readonly unknown[];
}

// Decide or Keep talking. A more_detail or discuss reply is talk. So is a feedback reply: a decision
// with a message and no pick, on an ask that offers something to pick (WAG-285). Everything else decides.
export function replyOutcome(c: OutcomeCase, reply: ReplyLike): ReplyOutcome {
  if (reply.intent === "more_detail" || reply.intent === "discuss") return "talk";
  if (!reply.message) return "decide";
  if (reply.choice !== undefined || reply.choices !== undefined) return "decide";
  if (reply.answers !== undefined && reply.answers.length > 0) return "decide";
  if (reply.item_answers !== undefined && reply.item_answers.length > 0) return "decide";
  const offersPick =
    c.items !== undefined ? c.items.some((i) => i.select !== "reply") : (c.questions?.length ?? 0) > 0 || (c.options?.length ?? 0) > 0;
  return offersPick ? "talk" : "decide";
}

// --- Reply answers, old and new (spec 2.3, 2.5) ---

export interface LegacyReplyFields {
  choice?: string;
  choices?: string[];
  answers?: PointAnswer[];
  message?: string;
}

// A reply's picks as item answers. `choice` and `choices` mean item 0 of a single-item ask. A legacy
// answer keyed "<question>/<point>" becomes the item of that id, with the option id found by its label.
// A decision reply with a message and no pick on a reply item is that item's text. Item answers pass through.
export function normalizeReply(items: readonly Item[], reply: ReplyLike & { answers?: readonly PointAnswer[]; item_answers?: readonly ItemAnswer[] }): ItemAnswer[] {
  if (reply.item_answers !== undefined && reply.item_answers.length > 0) return [...reply.item_answers];
  const first = items[0];
  const out: ItemAnswer[] = [];
  if (first !== undefined) {
    if (reply.choices !== undefined) out.push({ item_id: first.id, choices: [...reply.choices] });
    else if (reply.choice !== undefined) out.push({ item_id: first.id, choice: reply.choice });
    else if (items.length === 1 && first.select === "reply" && reply.intent === "decision" && reply.message) {
      out.push({ item_id: first.id, text: reply.message });
    }
  }
  for (const a of reply.answers ?? []) {
    const id = `${a.question_id}/${a.point_id}`;
    const option = items.find((i) => i.id === id)?.options.find((o) => o.label === a.choice);
    out.push(compact({ item_id: id, choice: option?.id ?? a.choice, note: a.note }));
  }
  return out;
}

// The old reply fields for item answers: choice, choices or message on a single-item ask; answers
// (question id, point id, option label, note) on a multi-item ask. A note on a single item has no old field.
export function projectLegacyReply(items: readonly Item[], answers: readonly ItemAnswer[]): LegacyReplyFields {
  if (items.length === 1) {
    const a = answers.find((x) => x.item_id === items[0]!.id);
    if (a === undefined) return {};
    if (a.choices !== undefined) return { choices: [...a.choices] };
    if (a.choice !== undefined) return { choice: a.choice };
    return a.text !== undefined ? { message: a.text } : {};
  }
  const out: PointAnswer[] = [];
  for (const a of answers) {
    const item = items.find((i) => i.id === a.item_id);
    if (item === undefined) continue;
    const groupId = item.group?.id;
    const pointId = groupId !== undefined && item.id.startsWith(`${groupId}/`) ? item.id.slice(groupId.length + 1) : item.id;
    const questionId = groupId ?? item.id;
    const picked = a.choice ?? a.text ?? "";
    const label = item.options.find((o) => o.id === picked)?.label ?? picked;
    out.push(compact({ question_id: questionId, point_id: pointId, choice: label, note: a.note }));
  }
  return { answers: out };
}
