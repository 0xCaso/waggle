// What the Claude Code mod's band draws for one session (HAIL-134): the session's
// oldest ask that waits for the human, and its newest answer. Read from the cases
// the daemon already holds. Agent text is shown as one plain line (AGENTS.md).
import type { Case, ModAnswer, ModOpenAsk } from "../protocol";
import { clamp, plain } from "./context";

export interface ModStatus {
  open_ask: ModOpenAsk | null;
  open_count: number;
  answer: ModAnswer | null;
  other_open_count: number;
  sig: string;
}

const TITLE_MAX = 90;
const CHOICE_MAX = 80;
const NOTE_MAX = 160;

function optionText(c: Case, id: string): string {
  const set = c.latest_reply_from_first_options ? c.first_options : c.options;
  const option = set.find((o) => o.id === id) ?? c.options.find((o) => o.id === id);
  return option ? option.title ?? option.label : id;
}

// The words of the latest reply's choice: one option, a list of options, or null.
function choiceText(c: Case): string | null {
  const ids = c.latest_reply_choices.length > 0 ? c.latest_reply_choices : c.latest_reply_choice ? [c.latest_reply_choice] : [];
  if (ids.length === 0) return null;
  return clamp(plain(ids.map((id) => optionText(c, id)).join(", ")), CHOICE_MAX);
}

// `needsYou` is every case waiting on the human, any session: the cases of other
// sessions are counted for the band's "+N in other sessions".
export function modStatus(taskId: string | null, taskCases: Case[], needsYou: Case[]): ModStatus {
  const other_open_count = needsYou.filter((c) => !c.dismissed_at && !c.withdrawn_at && c.task_id !== taskId).length;
  const live = taskCases.filter((c) => !c.dismissed_at && !c.withdrawn_at);
  const open = live
    .filter((c) => c.status === "needs_you")
    .sort((a, b) => Date.parse(a.created_at) - Date.parse(b.created_at));
  const first = open[0];
  let answer: ModAnswer | null = null;
  for (const c of live) {
    if (!c.latest_reply_at || c.latest_reply_intent === "more_detail" || c.latest_reply_intent === "discuss") continue;
    const choice = choiceText(c);
    const note = c.latest_reply_message ? clamp(plain(c.latest_reply_message), NOTE_MAX) : null;
    if (choice === null && !note) continue;
    if (answer && Date.parse(answer.answered_at) >= Date.parse(c.latest_reply_at)) continue;
    answer = {
      case_id: c.id,
      title: clamp(plain(c.title), TITLE_MAX),
      choice,
      note: note || null,
      answered_at: c.latest_reply_at,
    };
  }
  const open_ask: ModOpenAsk | null = first
    ? { case_id: first.id, title: clamp(plain(first.title), TITLE_MAX), created_at: first.created_at, waiting_since: first.updated_at }
    : null;
  const sig = [open_ask?.case_id ?? "", open.length, other_open_count, answer ? `${answer.case_id}@${answer.answered_at}` : ""].join("|");
  return { open_ask, open_count: open.length, answer, other_open_count, sig };
}
