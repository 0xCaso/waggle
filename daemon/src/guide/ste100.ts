// ASD-STE100 (HAIL-140): the writing mode that agents get by default, its
// guidance section, and the checker that warns when an ask breaks its limits.
//
// The mode is an operator setting (`askWords`, "asd" by default, "normal" to
// switch it off). The checker never rejects an ask: it only reports the limits
// an ask breaks, and only while the mode is "asd".

// The section served with the writing guidance while the mode is "asd". Kept
// short: one lead paragraph, then one rule per line.
export const ASD_STE100_SECTION = `## Write asks in ASD-STE100

Write asks in ASD-STE100 Simplified Technical English. Follow its writing rules and use only its approved words with their approved meaning; technical names from this project are allowed.

- Write one instruction per sentence.
- Keep a procedural sentence to 20 words or less, and a descriptive one to 25.
- Use the active voice and simple tenses.
- Do not use -ing forms, except in technical names.
- Do not use the passive voice in instructions.
- Write at most 6 sentences per paragraph, one topic per paragraph.
- Use vertical lists for steps.
- Use the same word for the same thing.`;

// The prose fields of an ask, checked against the ASD-STE100 limits. `need`
// and option labels are instruction-like (20 words); `why` and
// `recommendation_why` are descriptive (25 words). `why` also keeps its own
// 3-sentence cap, and every prose field is one paragraph (at most 6 sentences).
export interface AskWordsInput {
  need?: string;
  why?: string;
  options?: { label: string; title?: string }[];
  recommendation_why?: string;
}

function sentences(text: string): string[] {
  return text
    .split(/[.!?]+/)
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
}

function wordCount(text: string): number {
  const trimmed = text.trim();
  return trimmed.length === 0 ? 0 : trimmed.split(/\s+/).length;
}

function maxSentenceWords(text: string): number {
  return sentences(text).reduce((max, s) => Math.max(max, wordCount(s)), 0);
}

function sentenceCount(text: string): number {
  return sentences(text).length;
}

// The limits an ask breaks, as short labels, in a fixed order. An empty list
// means the ask is clean. Each limit appears at most once.
export function checkAskWords(input: AskWordsInput): string[] {
  const violations: string[] = [];
  if (input.need !== undefined && maxSentenceWords(input.need) > 20) {
    violations.push("need sentence over 20 words");
  }
  if (input.why !== undefined) {
    if (maxSentenceWords(input.why) > 25) violations.push("why sentence over 25 words");
    if (sentenceCount(input.why) > 3) violations.push("why over 3 sentences");
  }
  const options = input.options ?? [];
  if (options.length > 6) violations.push("over 6 options");
  for (const option of options) {
    if (maxSentenceWords(option.label) > 20) violations.push("option label sentence over 20 words");
    if (option.title !== undefined && wordCount(option.title) > 6) {
      violations.push("option title over 6 words");
    }
  }
  if (input.recommendation_why !== undefined && maxSentenceWords(input.recommendation_why) > 25) {
    violations.push("recommendation_why sentence over 25 words");
  }
  const paragraphs = [
    input.need,
    input.why,
    input.recommendation_why,
    ...options.map((o) => o.label),
  ].filter((t): t is string => t !== undefined);
  if (paragraphs.some((p) => sentenceCount(p) > 6)) {
    violations.push("a paragraph over 6 sentences");
  }
  return [...new Set(violations)];
}

// The one line waggle_ask / waggle_update prepends when an ask breaks a limit in
// "asd" mode. `violations` is `checkAskWords`'s non-empty list.
export function wordsWarning(violations: string[]): string {
  return `Waggle: this ask breaks ASD-STE100 limits (${violations.join(", ")}).`;
}

// WAG-249: a request's title stays short. The app shows a longer title as its
// first sentence plus a description, so the warning asks agents to write it that
// way. It does not depend on the writing mode and never rejects.
export const TITLE_MAX_LENGTH = 80;
export const TITLE_WARNING = "Start with a short question (under 80 characters). Put details after a blank line.";

// The warning when `text` (an ask title, or the first line of a round message)
// is over 80 characters, else null.
export function titleLengthWarning(text: string | undefined): string | null {
  const firstLine = (text ?? "").trim().split(/\r?\n/)[0]!.trim();
  return firstLine.length > TITLE_MAX_LENGTH ? TITLE_WARNING : null;
}

// WAG-361: unrelated decisions go in separate requests. The warning shows when a request has 2 or more
// items and they do not all carry one group id. It never rejects.
export const NO_GROUP_WARNING =
  "These items share no group. Send unrelated decisions as separate requests, one waggle_ask each. Give items that go together the same group.";

export function noGroupWarning(items: { group?: { id: string } | null }[] | undefined): string | null {
  if (items === undefined || items.length < 2) return null;
  const first = items[0]!.group?.id;
  return first !== undefined && items.every((item) => item.group?.id === first) ? null : NO_GROUP_WARNING;
}

// WAG-371: a suggested reply is the human's answer, written as the human. An agent sometimes sends an
// instruction to the human instead ("Describe the button..."). The warning shows when a reply item's
// suggested reply starts with an imperative word. It never rejects.
export const INSTRUCTION_REPLY_WARNING =
  "A suggested reply is the human's answer, written as the human. Leave it out when only the human knows the answer.";

const INSTRUCTION_START = /^(describe|tell me|explain|share|paste|list|send|give|provide|write|let me know|please)\b/i;

export function instructionReplyWarning(
  items: { select?: string; options?: unknown[]; recommendation?: string | string[] }[] | undefined,
): string | null {
  for (const item of items ?? []) {
    const isReply = item.select === "reply" || (item.select === undefined && (item.options ?? []).length === 0);
    if (isReply && typeof item.recommendation === "string" && INSTRUCTION_START.test(item.recommendation.trim())) {
      return INSTRUCTION_REPLY_WARNING;
    }
  }
  return null;
}

// Joins the warnings that apply into the one `words_warning` string.
export function joinWarnings(...warnings: (string | null)[]): string | null {
  const present = warnings.filter((w): w is string => w !== null);
  return present.length > 0 ? present.join(" ") : null;
}
