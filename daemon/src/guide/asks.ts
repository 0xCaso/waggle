import {
  type AskDetail,
  type AskFrequency,
  type AskReach,
  type AskLess,
  type AskTopic,
  type AskTopics,
  type AskLearn,
  type AskWords,
  DEFAULT_ASK_DETAIL,
  DEFAULT_ASK_FREQUENCY,
  DEFAULT_ASK_LEARN,
  DEFAULT_ASK_REACH,
  DEFAULT_ASK_TOPICS,
  DEFAULT_ASK_WORDS,
} from "../protocol/rpc";
import { ASD_STE100_SECTION } from "./ste100";

// The operator's Setup step 3 / Settings > Asks preferences (HAIL-101), as the
// text agents read. One generator, so the app, `waggle mcp` (initialize) and
// waggle_guide (index) always say the same thing.

export interface AskPreferences {
  topics: AskTopics;
  frequency: AskFrequency;
  detail: AskDetail;
  reach: AskReach;
  words: AskWords;
  learn: AskLearn;
}

export const DEFAULT_ASK_PREFERENCES: AskPreferences = {
  topics: DEFAULT_ASK_TOPICS,
  frequency: DEFAULT_ASK_FREQUENCY,
  detail: DEFAULT_ASK_DETAIL,
  reach: DEFAULT_ASK_REACH,
  words: DEFAULT_ASK_WORDS,
  learn: DEFAULT_ASK_LEARN,
};

const TOPIC_PHRASES: Record<AskTopic, string> = {
  marketing: "marketing and campaigns",
  design: "design and UX",
  operations: "operations and process",
  pricing: "pricing and money",
  code: "code and architecture",
  writing: "writing and naming",
  data: "data and numbers",
  personal: "personal and creative",
  reviews: "reviews before something ships",
  private_info: "info only I have (keys, accounts)",
};

const FREQUENCY_PHRASES: Record<AskFrequency, string> = {
  blocked: "only when you are blocked on me",
  choice: "whenever there is a real choice to make",
  chat: "for anything you would normally ask me in the chat",
};

export const DETAIL_SENTENCES: Record<AskDetail, string> = {
  brief: "Keep each ask short: the need, one line on why, and for each item its options and your recommendation.",
  rich: "Make each ask rich: add where things stand and what you have tried, and attach a short markdown write-up as an artifact when the answer depends on more than a few sentences.",
};

// How the person likes to learn (WAG-384): one line for the chosen style.
export const LEARN_STYLES: Record<AskLearn, string> = {
  short: "Answer in up to 3 short lines",
  diagram: "Start with a diagram of the parts, then up to 3 short lines",
  steps: "Use numbered steps",
  try: "Send a small html_bundle they can click through",
};

export function learnSentence(learn: AskLearn): string {
  return `When the human asks how something works, explain only the part they name. ${LEARN_STYLES[learn]}. Cite the files you read.`;
}

// What stays in the terminal (HAIL-109). "everything" adds nothing.
export const REACH_SENTENCES: Record<AskReach, string> = {
  off: "Waggle is Off. Do not call waggle_ask: ask me everything in the terminal, as you would without Waggle. This replaces any other instruction to use Waggle.",
  everything: "",
  written:
    "Bring me asks with something to look at or to read (a write-up, a draft, a plan) in Waggle. Ask a quick question I can answer in a word or a yes/no (a name, a default, a go-ahead) in the terminal.",
  visual:
    "Use Waggle only for asks with something to look at: a prototype, designs, screenshots, a chart or a page. Ask everything else in the terminal, including write-ups and quick questions.",
};

// The words the person sees for each level (menu bar, Settings), and what an agent does at that level.
// A running session gets the line below in its next tool result after the person changes the level (HAIL-193).
export const REACH_LABELS: Record<AskReach, string> = {
  off: "Off",
  visual: "Things to look at",
  written: "Look and read",
  everything: "Everything",
};

const REACH_TO_DO: Record<AskReach, string> = {
  off: "Do not call waggle_ask. Ask the person in the terminal.",
  visual:
    "Send waggle_ask only when the person must see something: a prototype, design, screenshot, chart or page. Ask other questions in the terminal.",
  written:
    "Send waggle_ask for things to look at and things to read: a plan, a trade-off, a draft. Ask quick questions in the terminal.",
  everything: "Send every question, decision and review through waggle_ask. Do not ask in the terminal.",
};

export function reachModeNote(reach: AskReach): string {
  return `Waggle mode changed: ${REACH_LABELS[reach]}. ${REACH_TO_DO[reach]}`;
}

// Semicolons, not commas and "and": the topic phrases hold "and" themselves.
function joinList(items: string[]): string {
  return items.join("; ");
}

// The one-line preference plus the Detail sentence.
export function askPreferencesText(prefs: AskPreferences): string {
  const when = FREQUENCY_PHRASES[prefs.frequency];
  const picked = prefs.topics.picked.map((t) => TOPIC_PHRASES[t]);
  const where =
    prefs.topics.scope === "pick" && picked.length > 0
      ? `${when}: ${joinList(picked)}`
      : `${when}, whatever the topic`;
  const reach = REACH_SENTENCES[prefs.reach];
  // Below "everything" some asks stay in the terminal, so "not in the terminal" would contradict.
  // Off says it all: no topic, no detail, nothing to bring.
  if (prefs.reach === "off") return reach;
  const lead = reach ? `Ask me in Waggle (waggle_ask) ${where}. ${reach} ` : `Ask me in Waggle (waggle_ask), not in the terminal, ${where}. `;
  return (
    lead +
    `Keep working on anything that does not depend on my answer. ${DETAIL_SENTENCES[prefs.detail]}`
  );
}

// The section waggle_guide's index carries and `waggle mcp` appends to its
// initialize instructions. While `words` is "asd" it also carries the
// ASD-STE100 writing section; "normal" serves today's text (the preferences
// sentence only).
export function askPreferencesSection(prefs: AskPreferences): string {
  return `## Operator preferences · asks\n\n${askAgentText(prefs)}`;
}

// The full text agents read from the `askText` setting: the HAIL-109
// preferences sentence, plus the ASD-STE100 writing section while `words` is
// "asd".
export function askAgentText(prefs: AskPreferences): string {
  // Off sends no ask, so there is nothing to learn or write in ASD-STE100.
  const base = prefs.reach === "off" ? askPreferencesText(prefs) : `${askPreferencesText(prefs)} ${learnSentence(prefs.learn)}`;
  return prefs.words === "asd" && prefs.reach !== "off" ? `${base}\n\n${ASD_STE100_SECTION}` : base;
}

// WAG-412: the "Let the agent decide small things" line. Written in ASD-STE100. The caller shows it only while the
// master switch is on, so agents never see `category` while it is off.
export function askLessSection(askLess: AskLess): string {
  const on = (Object.keys(askLess.rules) as (keyof AskLess["rules"])[]).filter((c) => askLess.rules[c]);
  const where = on.length > 0 ? `Categories that are on: ${on.join(", ")}.` : "No category is on now.";
  return (
    "## Operator preferences · small choices\n\n" +
    "The human lets Waggle decide small choices. A small choice is easy to undo. " +
    "Send category with the ask and send a recommendation. " +
    `${where} ` +
    "Waggle may then decide for the human and return at once with status auto_decided. Do not wait. Use the answer. " +
    "Never send category for a choice that deletes data, spends money or ships."
  );
}
