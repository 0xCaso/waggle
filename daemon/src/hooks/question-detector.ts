// WAG-265: does the last message of an agent turn ask the human something? The Claude Code Stop
// hook (`waggle mod claude-hook Stop`) uses this to catch a question left in the terminal. The
// whole list lives here, so a test can pin it. A false "yes" costs one blocked stop, never two.

// Phrases that ask a question without a question mark. English only. Each one must sit in the
// last two sentences of the message.
export const QUESTION_PHRASES: readonly RegExp[] = [
  /\bshould i\b/i,
  /\bshall i\b/i,
  /\bdo you want\b/i,
  /\bwant me to\b/i,
  /\bwould you like\b/i,
  /\bdo you prefer\b/i,
  /\bwhich (?:one|option|approach|way|of|do you|would you|should)\b/i,
  /\bwhat do you think\b/i,
  /\bhow (?:would|do) you want\b/i,
  /\blet me know\b/i,
];

// "Let me know if you need anything" is a sign-off on a finished report, not a question.
export const SIGN_OFF: RegExp =
  /\blet me know (?:if (?:you(?:'d| would)? (?:need|have|run|hit|see|notice|find|encounter|get|want anything)|there(?:'s| is| are) (?:anything|any|something|more)|anything|something)|how it goes|when )/i;

// Characters that end a question in the scripts Waggle sees: ASCII, fullwidth, Arabic, Greek
// (U+037E, not the ASCII semicolon), Armenian (U+055E), Ethiopic (U+1367), reversed (U+2E2E).
const QUESTION_MARKS = ["?", "？", "؟", "\u037E", "\u055E", "\u1367", "\u2E2E"];
// Markdown and quote characters that may close a paragraph after the mark.
const TRAILING = /[\s*_`"'”’»›)\]}>]+$/u;

function withoutCode(text: string): string {
  return text.replace(/```[\s\S]*?(?:```|$)/g, "");
}

function lastParagraph(text: string): string {
  const paragraphs = withoutCode(text)
    .split(/\n\s*\n/)
    .map((p) => p.trim())
    .filter((p) => p.length > 0);
  return paragraphs[paragraphs.length - 1] ?? "";
}

function lastSentences(paragraph: string, count: number): string {
  // A line break ends a sentence too: list items and short lines carry no full stop.
  const sentences = paragraph
    .split(/(?<=[.!?？؟])\s+|\n+/u)
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
  return sentences.slice(-count).join(" ");
}

export function endsWithQuestionMark(paragraph: string): boolean {
  const trimmed = paragraph.replace(TRAILING, "");
  return trimmed.length > 0 && QUESTION_MARKS.includes(Array.from(trimmed).pop() ?? "");
}

export function looksLikeQuestion(message: string | undefined | null): boolean {
  if (typeof message !== "string" || message.trim() === "") return false;
  const paragraph = lastParagraph(message);
  if (paragraph === "") return false;
  if (endsWithQuestionMark(paragraph)) return true;
  const tail = lastSentences(paragraph, 2);
  if (SIGN_OFF.test(tail)) return false;
  return QUESTION_PHRASES.some((phrase) => phrase.test(tail));
}

// WAG-273: what kind of question is it? The Stop hook asks these two when the operator's Requests
// settings narrow what belongs in Waggle. Both live here so a test can pin them.

const LIST_ITEM = /^\s*(?:[-*\u2022]|\d+[.)]|[a-d][.)])\s+\S/m;
const QUICK_MAX_CHARS = 160;

// A quick question: the last paragraph is one short sentence that ends in a question mark, and
// neither of the last two paragraphs lists options. "Should I use tabs?" is quick. "Which layout?"
// after a list of layouts is not.
export function isQuickQuestion(message: string | undefined | null): boolean {
  if (typeof message !== "string") return false;
  const paragraphs = withoutCode(message)
    .split(/\n\s*\n/)
    .map((p) => p.trim())
    .filter((p) => p.length > 0);
  const last = paragraphs[paragraphs.length - 1] ?? "";
  if (last === "" || last.length > QUICK_MAX_CHARS || last.includes("\n")) return false;
  if (paragraphs.slice(-2).some((p) => LIST_ITEM.test(p))) return false;
  if (!endsWithQuestionMark(last)) return false;
  const marks = Array.from(last).filter((c) => QUESTION_MARKS.includes(c)).length;
  return marks === 1 && last.split(/(?<=[.!?？؟])\s+/u).length === 1;
}

// Phrases that say the agent cannot go on without the answer.
export const BLOCKED_PHRASES: readonly RegExp[] = [
  /\bbefore i (?:continue|proceed|go on|go any further|can (?:continue|proceed|go on))\b/i,
  /\bi need (?:you|your|a decision|an answer|an? (?:key|token|password|login))\b/i,
  /\bi(?:'m| am) (?:blocked|stuck)\b/i,
  /\bblocked (?:on|by|until)\b/i,
  /\b(?:cannot|can't|can not|unable to) (?:continue|proceed|go on|go further)\b/i,
  /\bwaiting (?:for|on) (?:you|your)\b/i,
];

export function saysBlocked(message: string | undefined | null): boolean {
  if (typeof message !== "string") return false;
  const paragraphs = withoutCode(message)
    .split(/\n\s*\n/)
    .map((p) => p.trim())
    .filter((p) => p.length > 0);
  const tail = paragraphs.slice(-2).join(" ");
  return BLOCKED_PHRASES.some((phrase) => phrase.test(tail));
}
