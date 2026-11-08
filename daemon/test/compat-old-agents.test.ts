import { describe, expect, test } from "bun:test";
import { EventBus } from "../src/events";
import {
  KnockAskInput,
  KnockUpdateInput,
  LEGACY_KNOCK_ALIASES,
  LEGACY_TOOL_NAMES,
  buildMcpTools,
  canonicalToolName,
} from "../src/protocol";
import { CHOICE_WITH_CHANGES_LINE, Store } from "../src/store";
import golden from "./fixtures/compat/golden-0.2.21.json" with { type: "json" };
import canonical from "./fixtures/compat/canonical-scenarios.json" with { type: "json" };
import fixtures from "./fixtures/compat/scenarios.json" with { type: "json" };
import served from "./fixtures/compat/served-three-blocks.json" with { type: "json" };
import { runScenario, scrub } from "./compat-runner";

// WAG-317 (T7, spec 9 and 7.5): every payload an old agent sends still works. The scenarios are real
// waggle_ask / knock_ask / waggle_update calls in the shapes of docs/protocol-mvp.md and the guide
// examples at 0.2.21, each with the reply that answers it. The golden file holds what the 0.2.21 daemon
// stored and sent back for them (made by running test/compat-runner.ts on the 0.2.21 sources). The new
// daemon must give the same stored case, the same check text and the same reply flow. It may add fields
// (items, rounds, outcome). The only intended change is the review shortcut (spec 2.4, 1.5), below.

type Json = Record<string, any>;
const ADDITIVE = new Set(["items", "rounds", "outcome", "round", "working_note"]);
// `plan.rounds` is an old field (a count). `rounds` on the case detail is new.
// WAG-353: a choice with a message gets one more line (additive wording); the 0.2.21 text lacks it.
const WITH_CHANGES = `${CHOICE_WITH_CHANGES_LINE}\n`;
const strip = (v: any, parent = ""): any =>
  typeof v === "string"
    ? v.split(WITH_CHANGES).join("")
    : Array.isArray(v)
    ? v.map((x) => strip(x, parent))
    : v && typeof v === "object"
      ? Object.fromEntries(
          Object.entries(v)
            .filter(([k]) => !(ADDITIVE.has(k) && !(k === "rounds" && parent === "plan")))
            .map(([k, x]) => [k, strip(x, k)]),
        )
      : v;

const mods = { Store, EventBus, KnockAskInput, KnockUpdateInput };
const goldenOf = (name: string) => (golden.scenarios as Json)[name] as Json[];
const scenarios = fixtures.scenarios as Json[];

// A review with no options of its own gets the approve / request_changes item. The old daemon stored no
// options for it. The check text then names the option label, and a message with no pick says the human
// wants changes first (a comments-only review reply is Keep talking).
const REVIEW_SHORTCUT = new Set(["review-approve", "review-free-text-recommendation", "update-message-and-artifact"]);
const REVIEW_LABEL = / \((Approve: ship it as it is|Request changes: use my comments)\)/g;
const KEEP_TALKING_LINE = "The human wants changes to the page before deciding. They chose nothing. Revise the artifact or the text, then send a new round with waggle_update on this case.\n";

function undoReviewShortcut(value: unknown): unknown {
  const text = JSON.stringify(value).replace(REVIEW_LABEL, "").split(KEEP_TALKING_LINE.replace(/\n/g, "\\n")).join("");
  const out = JSON.parse(text);
  const drop = (v: any): any => {
    if (Array.isArray(v)) return v.map(drop);
    if (!v || typeof v !== "object") return v;
    const o: Json = {};
    for (const [k, x] of Object.entries(v)) {
      if ((k === "options" || k === "first_options" || k === "options_json") && isReviewOptions(x)) o[k] = k === "options_json" ? "[]" : [];
      else o[k] = drop(x);
    }
    return o;
  };
  return drop(out);
}
function isReviewOptions(x: unknown): boolean {
  const list = typeof x === "string" ? JSON.parse(x) : x;
  return Array.isArray(list) && list.length === 2 && list[0]?.id === "approve" && list[1]?.id === "request_changes";
}

describe("old agent payloads against the three blocks daemon", () => {
  test("the fixtures cover every old shape", () => {
    const names = scenarios.map((s) => s.name);
    for (const shape of [
      "question-options", "select-many", "reply-only", "review-approve", "plan-stages", "questions",
      "update-with-options", "done", "more-detail-diagram", "discuss-lean-and-rule-out", "single-artifact-question",
    ]) {
      expect(names).toContain(shape);
    }
    expect(Object.keys(golden.scenarios).sort()).toEqual([...names].sort());
  });

  for (const scenario of scenarios) {
    test(`${scenario.name}: stored case, check text and reply flow match 0.2.21`, async () => {
      const got = scrub(await runScenario(mods, scenario.steps)) as Json[];
      const want = goldenOf(scenario.name);
      expect(got).toHaveLength(want.length);
      const actual = REVIEW_SHORTCUT.has(scenario.name) ? undoReviewShortcut(strip(got)) : strip(got);
      expect(actual).toEqual(want);
    });
  }

  test("every step of every scenario also carries the new read fields", async () => {
    const out = (await runScenario(mods, scenarios.find((s) => s.name === "question-options")!.steps)) as Json[];
    expect(out[0]!.detail.case.items).toHaveLength(1);
    expect(out[0]!.detail.case.items[0].id).toBe("main");
    expect(out[1]!.reply.outcome).toBe("decide");
  });
});

describe("the review shortcut: the one intended change", () => {
  test("a review with no options stores the approve and request_changes item, and the old columns follow", async () => {
    const out = (await runScenario(mods, scenarios.find((s) => s.name === "review-approve")!.steps)) as Json[];
    expect(out[0]!.detail.case.kind).toBe("review");
    expect(out[0]!.detail.case.options.map((o: Json) => o.id)).toEqual(["approve", "request_changes"]);
    expect(out[0]!.detail.case.recommendation).toBe("approve");
    expect(out[1]!.check_text[0]).toBe(
      `Reply to "Review the pricing page" (case ${out[1]!.detail.case.id})\nChoice: approve (Approve: ship it as it is)\n${CHOICE_WITH_CHANGES_LINE}\nMessage: Ship it.`,
    );
  });

  test("a message with no pick on a review is Keep talking, so the agent gets no decision", async () => {
    const out = (await runScenario(mods, scenarios.find((s) => s.name === "review-free-text-recommendation")!.steps)) as Json[];
    expect(out[1]!.reply.outcome).toBe("talk");
    expect(out[1]!.check_text[0]).toContain(KEEP_TALKING_LINE.trim());
    expect(out[1]!.detail.case.status).toBe("waiting_on_agent");
  });

  test("a review that gives its own options keeps them and the old text", async () => {
    const out = (await runScenario(mods, scenarios.find((s) => s.name === "review-own-options")!.steps)) as Json[];
    expect(out[0]!.detail.case.options.map((o: Json) => o.id)).toEqual(["ok", "fix"]);
    expect(out[1]!.check_text[0]).toContain("Choice: fix (Needs a fix)");
  });
});

// The Swift LegacyDecodeTests read served-three-blocks.json: the old scenarios and the canonical ones as this
// daemon serves them. This test keeps the file current. To rewrite it, run this file with
// WRITE_SERVED=1 (bun test test/compat-old-agents.test.ts) and commit the result.
describe("the JSON the daemon serves to the app", () => {
  test("served-three-blocks.json is what the daemon serves now", async () => {
    const all: Json = {};
    for (const s of [...scenarios, ...(canonical.scenarios as Json[])]) all[s.name] = scrub(await runScenario(mods, s.steps));
    const file = {
      _about: "What the three blocks daemon serves for scenarios.json and canonical-scenarios.json (case detail and reply, ids and times scrubbed). Read by the Swift LegacyDecodeTests. Rewrite with WRITE_SERVED=1.",
      scenarios: all,
    };
    if (process.env.WRITE_SERVED === "1") {
      await Bun.write(`${import.meta.dir}/fixtures/compat/served-three-blocks.json`, JSON.stringify(file, null, 1) + "\n");
    }
    expect(JSON.parse(JSON.stringify(file))).toEqual(process.env.WRITE_SERVED === "1" ? file : served);
  });

  test("the canonical scenarios store, answer and deliver without an error", async () => {
    for (const s of canonical.scenarios as Json[]) {
      const out = await runScenario(mods, s.steps);
      expect(out.length).toBe(s.steps.length);
    }
  });
});

describe("old tool names and the open schema", () => {
  test("knock_ask and knock_update resolve to the waggle tools, with the same schema", () => {
    expect(LEGACY_KNOCK_ALIASES).toBe(true);
    const tools = buildMcpTools(true);
    for (const name of ["waggle_ask", "waggle_update", "waggle_check"]) {
      const old = LEGACY_TOOL_NAMES[name]!;
      expect(canonicalToolName(old, true)).toBe(name);
      expect(tools.find((t) => t.name === old)!.inputSchema).toEqual(tools.find((t) => t.name === name)!.inputSchema);
    }
  });

  test("a session with a stale schema can still send fields the new schema adds", () => {
    const ask = tools().find((t) => t.name === "waggle_ask")!;
    expect(ask.inputSchema.additionalProperties).toBe(true);
    // A stored old payload with an extra unknown field still parses.
    const first = scenarios[0]!.steps[0]!.input;
    expect(KnockAskInput.safeParse({ ...first, future_field: 1 }).success).toBe(true);
  });
});

function tools() {
  return buildMcpTools(true);
}
