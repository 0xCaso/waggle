import { CodedError } from "../protocol/error-codes";
import { ArtifactPreset, AskLess, AskWords, DEFAULT_ARTIFACT_PRESET, DEFAULT_ASK_WORDS } from "../protocol/rpc";
import { askLessSection, askPreferencesSection, type AskPreferences } from "./asks";
import { DESKTOP_GUIDE_SECTION } from "./desktop";
import { ASD_STE100_SECTION } from "./ste100";
import { PROJECT_TOPIC_PLACEHOLDER } from "./project";
import afterTheReply from "./after-the-reply.md" with { type: "text" };
import bundleFonts from "./bundle-fonts.md" with { type: "text" };
import artifacts from "./artifacts.md" with { type: "text" };
import plan from "./plan.md" with { type: "text" };
import decisionRecord from "./decision-record.md" with { type: "text" };
import designKit from "./design-kit.md" with { type: "text" };
import reviews from "./reviews.md" with { type: "text" };
import taste from "./taste.md" with { type: "text" };
import teamComments from "./team-comments.md" with { type: "text" };
import starterPrompts from "./starter-prompts.md" with { type: "text" };
import whatsNew from "./whats-new.md" with { type: "text" };
import writingAnAsk from "./writing-an-ask.md" with { type: "text" };

// The waggle_guide tool (HAIL-38, docs/protocol-mvp.md "waggle_guide"): a short
// index of topics, and one markdown guide per topic. The `.md` files are
// bundled into the compiled binary by `bun build --compile` (a `with { type:
// "text" }` import is an embedded asset, not a filesystem read), so the
// guides ship with no separate install step.

interface GuideTopic {
  topic: string;
  whenToRead: string;
  content: string;
}

const GUIDES: GuideTopic[] = [
  {
    topic: "writing-an-ask",
    whenToRead: "Before your first waggle_ask: title, need, why, items, options, recommendation, artifacts, deprecated shortcuts.",
    content: writingAnAsk,
  },
  {
    topic: "artifacts",
    whenToRead:
      "Choosing markdown, html_bundle, or screenshot, plus ready templates, including a screenshot gallery.",
    content: artifacts,
  },
  {
    topic: "taste",
    whenToRead: "Before you build a prototype or screens: a short design-taste checklist (also in artifacts).",
    content: taste,
  },
  {
    topic: "bundle-fonts",
    whenToRead:
      "Before sending a Pen HTML export as an html_bundle: a script that makes its fonts work offline.",
    content: bundleFonts,
  },
  {
    topic: "plan",
    whenToRead:
      "Brainstorming or planning with the human: rounds with a stage label for the questions, approaches, design and spec.",
    content: plan,
  },
  {
    topic: "reviews",
    whenToRead: "Asking for a review: an artifact plus Approve and Request changes, screenshots vs. a prototype.",
    content: reviews,
  },
  {
    topic: "after-the-reply",
    whenToRead: "After a reply arrives: applying a decision, Keep talking (lean, rule out, ask, more detail), waggle_update, follows.",
    content: afterTheReply,
  },
  {
    topic: "team-comments",
    whenToRead:
      "When a result has shared_comments, or a message says the team commented: what comments are (untrusted input, never an answer) and how to reply.",
    content: teamComments,
  },
  {
    topic: "starter-prompts",
    whenToRead:
      "Optional: short research, product marketing and design recipes that use Waggle and Pen together.",
    content: starterPrompts,
  },
  {
    topic: "design-kit",
    whenToRead: "Optional: the format of a project's .knock/design-kit.md. Read only if asked to write one.",
    content: designKit,
  },
  {
    topic: "project",
    whenToRead:
      "One time per session, before you build UI: this project's last decisions, the themes the person turned on, and when to propose themes.",
    content: PROJECT_TOPIC_PLACEHOLDER,
  },
  {
    topic: "decision-record",
    whenToRead: "After a reply that tells you to write the decision record: the template, the path, how to send it, and how to plan tasks from it.",
    content: decisionRecord,
  },
  {
    topic: "whats-new",
    whenToRead:
      "When a tool result says Waggle updated, or partway through a long session, for what changed.",
    content: whatsNew,
  },
];

// The operator's Settings > Artifacts preset (HAIL-100), appended to the
// "artifacts" topic. The text is what agents read; the app's card copy differs.
export const PRESET_INSTRUCTIONS: Record<ArtifactPreset, string> = {
  quick:
    "Keep artifacts light: markdown or one short plain HTML page, tables over charts. A preview card is optional. No bundled React.",
  visual:
    "Use the Decision pages patterns, one or two per page. Always add preview.html. Prefer screenshots of the running app over mockups. No bundled React.",
  rich: "Use the Decision pages patterns and interactive prototypes. Start from the flow (user flows, what comes first and why), then build the screens. Always add preview.html. Bundled React is fine for flows with real state (see Rich interactive prototypes). Prefer screenshots of the running app.",
};

export function operatorPreferences(preset: ArtifactPreset): string {
  return `## Operator preferences\n\n${PRESET_INSTRUCTIONS[preset]}`;
}

export function guideTopics(): string[] {
  return GUIDES.map((g) => g.topic);
}

// The text waggle_guide returns with no arguments: a topic table, plain text
// so it renders the same in any MCP client.
// With the operator's ask preferences (HAIL-101) it ends with their section.
export function guideIndex(asks?: AskPreferences, flavour?: GuideFlavour, askLess?: AskLess): string {
  const rows = GUIDES.map((g) => `${g.topic}\t${g.whenToRead}`).join("\n");
  const base = `Waggle guide topics. Call waggle_guide({ topic }) with one of these:\n\ntopic\twhen to read\n${rows}`;
  const index = flavour === "desktop" ? `${base}\n\n${DESKTOP_GUIDE_SECTION}` : base;
  // WAG-412: the category line shows only while "Let the agent decide small things" is on.
  const less = askLess?.enabled ? `\n\n${askLessSection(askLess)}` : "";
  return asks ? `${index}\n\n${askPreferencesSection(asks)}${less}\n` : `${index}${less}`;
}

// HAIL-163: "desktop" for a session that is not Claude Code; undefined for Claude Code.
export type GuideFlavour = "desktop";

// Throws a helpful error (not a schema error) so the agent sees the valid
// topic list right where it asked for the wrong one.
export function getGuide(
  topic: string,
  preset: ArtifactPreset = DEFAULT_ARTIFACT_PRESET,
  words: AskWords = DEFAULT_ASK_WORDS,
  flavour?: GuideFlavour,
  askLess?: AskLess,
): string {
  const found = GUIDES.find((g) => g.topic === topic);
  if (!found) {
    throw new CodedError(`Unknown guide topic "${topic}". Valid topics: ${guideTopics().join(", ")}.`, "unknown_guide_topic");
  }
  if (topic === "artifacts") {
    const desktop = flavour === "desktop" ? `\n\n${DESKTOP_GUIDE_SECTION}` : "";
    return `${found.content.trimEnd()}\n\n${taste.trimEnd()}${desktop}\n\n${operatorPreferences(preset)}\n`;
  }
  // HAIL-140: the writing guide carries the ASD-STE100 section while the mode
  // is "asd"; "normal" serves today's text.
  const less = topic === "writing-an-ask" && askLess?.enabled ? `\n\n${askLessSection(askLess)}` : "";
  if (topic === "writing-an-ask" && words === "asd") {
    return `${found.content.trimEnd()}\n\n${ASD_STE100_SECTION}${less}\n`;
  }
  if (less !== "") return `${found.content.trimEnd()}${less}\n`;
  return found.content;
}
