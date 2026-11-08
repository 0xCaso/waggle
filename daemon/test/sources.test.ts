import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { askMessageFor, plainLine } from "../src/connectors/manager";
import { EventBus } from "../src/events";
import { KnockAskInput, KnockUpdateInput, SOURCE_KINDS, SourcesField, stripSourceMarkers } from "../src/protocol";
import { cwdSlug, plain } from "../src/sessions/context";
import { checkSources } from "../src/sessions/sources-check";
import { Store } from "../src/store";
import type { UsageLogger } from "../src/usage";

// WAG-354: sources on a request. Schema, markers, the one-line places and the check for each kind.

const ASKED = "2026-10-10T10:50:00.000Z";
const SESSION = "sess-sources-1";
const CWD = "/tmp/waggle-sources-proj";

let root: string;
let prevRoot: string | undefined;

beforeEach(() => {
  root = join(tmpdir(), `knock-sources-${crypto.randomUUID()}`);
  mkdirSync(join(root, cwdSlug(CWD)), { recursive: true });
  prevRoot = process.env.KNOCK_CLAUDE_PROJECTS;
  process.env.KNOCK_CLAUDE_PROJECTS = root;
});

afterEach(() => {
  if (prevRoot === undefined) delete process.env.KNOCK_CLAUDE_PROJECTS;
  else process.env.KNOCK_CLAUDE_PROJECTS = prevRoot;
  rmSync(root, { recursive: true, force: true });
});

const use = (name: string, input: Record<string, unknown>, at = "2026-10-10T10:41:00.000Z", extra: object = {}) => ({
  type: "assistant",
  timestamp: at,
  message: { content: [{ type: "tool_use", name, input }] },
  ...extra,
});
const said = (text: string, at = "2026-10-10T10:00:00.000Z") => ({
  type: "user",
  timestamp: at,
  message: { content: text },
});

function writeTranscript(records: object[]): void {
  writeFileSync(join(root, cwdSlug(CWD), `${SESSION}.jsonl`), records.map((r) => JSON.stringify(r)).join("\n") + "\n");
}

const base: KnockAskInput = {
  title: "Tabs?",
  need: "Pick the tab layout.",
  why: "The tab row reads revisions. [[s:a]]",
  items: [
    {
      id: "main",
      options: [
        { id: "x", label: "One per name [[s:a]]" },
        { id: "y", label: "One per round" },
      ],
      recommendation: "x",
      recommendation_why: "It is simple. [[s:a]]",
    },
  ],
};

const plainItems = [
  { id: "main", options: [{ id: "x", label: "One" }, { id: "y", label: "Two" }], recommendation: "x", recommendation_why: "Simple." },
];

function setup(usage?: UsageLogger): { store: Store; taskId: string } {
  const store = new Store(new Database(":memory:"), join(root, "home"), new EventBus(), usage);
  return { store, taskId: store.createTask({ name: "WAG-354", project: "app" }).id };
}

const ask = (s: ReturnType<typeof setup>, input: KnockAskInput) =>
  s.store.createCase(s.taskId, input, "claude", undefined, { id: SESSION, cwd: CWD });

const src = (id: string, kind: string, extra: object = {}) => ({ id, kind, label: `label ${id}`, ...extra });

describe("sources schema", () => {
  test("all 16 kinds parse", () => {
    expect(SOURCE_KINDS.length).toBe(16);
    for (const kind of SOURCE_KINDS) expect(SourcesField.safeParse([src("a", kind)]).success).toBe(true);
  });

  test("limits: 24 entries, id shape, unique ids, one-line label, note length", () => {
    const many = (n: number) => Array.from({ length: n }, (_, i) => src(`s${i}`, "none"));
    expect(SourcesField.safeParse(many(24)).success).toBe(true);
    expect(SourcesField.safeParse(many(25)).success).toBe(false);
    expect(SourcesField.safeParse([src("A", "file")]).success).toBe(false);
    expect(SourcesField.safeParse([src("a".repeat(25), "file")]).success).toBe(false);
    expect(SourcesField.safeParse([src("a", "file"), src("a", "web")]).success).toBe(false);
    expect(SourcesField.safeParse([{ ...src("a", "file"), label: "x".repeat(61) }]).success).toBe(false);
    expect(SourcesField.safeParse([{ ...src("a", "file"), label: "two\nlines" }]).success).toBe(false);
    expect(SourcesField.safeParse([{ ...src("a", "file"), note: "n".repeat(301) }]).success).toBe(false);
    expect(SourcesField.safeParse([src("a", "mystery")]).success).toBe(false);
  });

  test("ask and update accept sources; 9 markers and unknown ids are not a schema error", () => {
    const markers = Array.from({ length: 9 }, () => "[[s:zz]]").join(" ");
    expect(KnockAskInput.safeParse({ ...base, why: markers, sources: [src("a", "none")] }).success).toBe(true);
    expect(KnockUpdateInput.safeParse({ case_id: "c1", message: "Hi [[s:a]]", sources: [src("a", "none")] }).success).toBe(true);
  });

  test("a long excerpt is accepted and cut at 600 with an ellipsis", () => {
    const input = { ...base, sources: [src("a", "none", { excerpt: "e".repeat(900) })] };
    expect(KnockAskInput.safeParse(input).success).toBe(true);
    const c = ask(setup(), KnockAskInput.parse(input));
    expect(c.sources![0]!.excerpt!.length).toBe(600);
    expect(c.sources![0]!.excerpt!.endsWith("…")).toBe(true);
  });
});

describe("markers", () => {
  test("unknown id: ask accepted, marker removed from stored text, one warning", () => {
    const s = setup();
    const c = ask(s, KnockAskInput.parse({ ...base, why: "Because. [[s:ghost]] And so. [[s:a,ghost]]", sources: [src("a", "none")] }));
    expect(c.why).toBe("Because. And so. [[s:a]]");
    expect(c.words_warning).toContain("unknown id (ghost)");
    const stored = s.store.caseById(c.id)!;
    expect(stored.why).toBe("Because. And so. [[s:a]]");
    expect(JSON.stringify(stored.items)).toContain("[[s:a]]");
  });

  test("marker with no sources at all is removed", () => {
    const c = ask(setup(), KnockAskInput.parse(base));
    expect(c.why).toBe("The tab row reads revisions.");
    expect(c.words_warning).toContain("unknown id (a)");
    expect(JSON.stringify(c.items)).not.toContain("[[s:");
    expect(c.sources).toBeUndefined();
  });

  test("9 markers give a warning, not a refusal", () => {
    const why = Array.from({ length: 9 }, () => "Fact. [[s:a]]").join(" ");
    const c = ask(setup(), KnockAskInput.parse({ ...base, why, items: plainItems, sources: [src("a", "none")] }));
    expect(c.words_warning).toContain("9 source markers");
    expect(c.why.match(/\[\[s:a\]\]/g)!.length).toBe(9);
  });

  test("8 markers and known ids give no warning", () => {
    const why = Array.from({ length: 8 }, () => "Fact. [[s:a]]").join(" ");
    const c = ask(setup(), KnockAskInput.parse({ ...base, why, items: plainItems, sources: [src("a", "none")] }));
    expect(c.words_warning ?? "").not.toContain("source markers");
  });

  test("update: message-only update cites the round's sources and merges its own", () => {
    const s = setup();
    const c = ask(s, KnockAskInput.parse({ ...base, sources: [src("a", "none")] }));
    const u = s.store.updateCase(c.id, KnockUpdateInput.parse({ case_id: c.id, message: "More. [[s:a]] New. [[s:b]] Bad. [[s:q]]", sources: [src("b", "none")] }))!;
    expect(u.words_warning).toContain("unknown id (q)");
    expect(u.sources!.map((x) => x.id)).toEqual(["a", "b"]);
    const detail = JSON.stringify(s.store.caseById(c.id)!.sources);
    expect(detail).toContain('"id":"b"');
  });

  test("update with new items cites only its own sources", () => {
    const s = setup();
    const c = ask(s, KnockAskInput.parse({ ...base, sources: [src("a", "none")] }));
    const u = s.store.updateCase(
      c.id,
      KnockUpdateInput.parse({
        case_id: c.id,
        message: "Round two. [[s:a]]",
        items: [{ id: "m", options: [{ id: "p", label: "P" }, { id: "q", label: "Q" }], recommendation: "p" }],
        sources: [src("b", "none")],
      }),
    )!;
    expect(u.sources!.map((x) => x.id)).toEqual(["b"]);
    expect(u.words_warning).toContain("unknown id (a)");
  });

  test("WAG-359: one uncited source gives one warning and the ask is accepted", () => {
    const c = ask(setup(), KnockAskInput.parse({ ...base, why: "Plain. [[s:a]]", sources: [src("a", "none"), src("b", "none")] }));
    expect(c.words_warning).toContain("Source b is in sources but no text cites it. Put [[s:id]] after the sentence it supports.");
    expect(c.words_warning).not.toContain("Source a");
    expect(c.sources!.map((x) => x.id)).toEqual(["a", "b"]);
  });

  test("WAG-359: several uncited sources give one plural line", () => {
    const c = ask(setup(), KnockAskInput.parse({ ...base, why: "Plain.", items: plainItems, sources: [src("a", "none"), src("b", "none")] }));
    const w = c.words_warning!;
    expect(w).toContain("Sources a, b are in sources but no text cites them.");
    expect(w.match(/no text cites/g)!.length).toBe(1);
  });

  test("WAG-359: no warning when each source is cited or there are no sources", () => {
    const c = ask(setup(), KnockAskInput.parse({ ...base, why: "Plain. [[s:a]] More. [[s:b]]", sources: [src("a", "none"), src("b", "none")] }));
    expect(c.words_warning ?? "").not.toContain("no text cites");
    const d = ask(setup(), KnockAskInput.parse({ ...base, why: "Plain.", items: plainItems }));
    expect(d.words_warning ?? "").not.toContain("no text cites");
  });

  test("WAG-359: an update with sources warns about an uncited one", () => {
    const s = setup();
    const c = ask(s, KnockAskInput.parse({ ...base, sources: [src("a", "none")] }));
    const u = s.store.updateCase(c.id, KnockUpdateInput.parse({ case_id: c.id, message: "More. [[s:b]]", sources: [src("b", "none"), src("c", "none")] }))!;
    expect(u.words_warning).toContain("Source c is in sources but no text cites it.");
    expect(u.words_warning).not.toContain("Source b");
  });

  test("an ask with no sources is stored and served as before", () => {
    const s = setup();
    const c = ask(s, KnockAskInput.parse({ ...base, why: "Plain.", items: plainItems }));
    expect("sources" in c).toBe(false);
    expect("sources" in s.store.caseById(c.id)!).toBe(false);
    expect(c.words_warning).toBeNull();
  });
});

describe("one-line places", () => {
  test("stripSourceMarkers", () => {
    expect(stripSourceMarkers("A fact. [[s:a]] Next. [[s:a,b]]")).toBe("A fact. Next.");
    expect(stripSourceMarkers("No marker")).toBe("No marker");
    expect(stripSourceMarkers("Odd [[s:]] and [[s:Bad Id]] gone")).toBe("Odd and gone");
  });

  test("plainLine (queue, Telegram, Slack) and the Context card drop the markers", () => {
    expect(plainLine("**Pick** it. [[s:a]]")).toBe("Pick it.");
    expect(plainLine("[[s:a]]\nSecond line [[s:b]]")).toBe("Second line");
    expect(plain("I read it. [[s:a]]")).toBe("I read it.");
  });

  test("no raw marker reaches a connector message", () => {
    const s = setup();
    const c = ask(
      s,
      KnockAskInput.parse({
        title: "Pick? [[s:a]]",
        need: "Pick the layout. [[s:a]]",
        why: "Why. [[s:a]]",
        items: [
          {
            id: "main",
            options: [
              { id: "x", title: "One [[s:a]]", label: "One per name [[s:a]]" },
              { id: "y", label: "Two [[s:a]]" },
            ],
            recommendation: "x",
            recommendation_why: "Simple. [[s:a]]",
          },
        ],
        sources: [src("a", "none")],
      }),
    );
    expect(c.need).toContain("[[s:a]]");
    expect(JSON.stringify(askMessageFor(s.store.caseById(c.id)!))).not.toContain("[[s:");
  });
});

describe("the check", () => {
  const sources = [
    src("file", "file", { ref: { path: "src/store.ts" } }),
    src("doc", "document", { ref: { path: "docs/spec.md" } }),
    src("img", "image", { ref: { path: "shots/a.png" } }),
    src("rule", "rule", { ref: { path: "AGENTS.md" } }),
    src("grep", "search", { ref: { command: "createCase" } }),
    src("rg", "search", { ref: { command: "sourcesJson" } }),
    src("hist", "history", { ref: { command: "git log" } }),
    src("test", "test", { ref: { command: "bun test" } }),
    src("db", "database", { ref: { command: "sqlite3" } }),
    src("api", "api", { ref: { url: "https://api.example.com/v1" } }),
    src("tool", "tool", { ref: { tool: "pencil" } }),
    src("design", "design", { ref: { tool: "mobbin" } }),
    src("web", "web", { ref: { url: "https://docs.example.com/a" } }),
    src("agent", "agent", { ref: { tool: "reviewer" } }),
    src("said", "you_said", { excerpt: "Use  the tabs\nby round please, and more words after that" }),
    src("none", "none"),
    src("noref", "file"),
    src("miss", "test", { ref: { command: "swift test" } }),
    src("late", "file", { ref: { path: "after/the/ask.ts" } }),
  ];
  const transcript = [
    said("hello. use the TABS by round please, and more words after that, and then some"),
    use("Read", { file_path: "/tmp/p/src/store.ts" }, "2026-10-10T10:40:00.000Z"),
    use("Read", { file_path: "/tmp/p/docs/spec.md" }),
    use("Read", { file_path: "/tmp/p/shots/a.png" }),
    use("Read", { file_path: "/tmp/p/AGENTS.md" }),
    use("Grep", { pattern: "createCase", path: "src" }),
    use("Bash", { command: "cd x && rg sourcesJson src" }),
    use("Bash", { command: "git log --oneline" }),
    use("Bash", { command: "bun test test/sources.test.ts" }),
    use("Bash", { command: "sqlite3 knock.db 'select 1'" }, "2026-10-10T10:41:30.000Z"),
    use("Bash", { command: "curl https://api.example.com/v1/things" }),
    use("mcp__pencil__execute", { filePath: "x.pen" }),
    use("mcp__mobbin__search_screens", { q: "tabs" }),
    use("WebFetch", { url: "https://docs.example.com/a", prompt: "p" }),
    use("Task", { description: "Reviewer pass on the diff", subagent_type: "general-purpose" }),
    use("Read", { file_path: "/tmp/p/after/the/ask.ts" }, "2999-01-01T00:00:00.000Z"),
    // A helper's own work does not count, and neither does a Waggle tool.
    use("Bash", { command: "swift test" }, "2026-10-10T10:42:00.000Z", { isSidechain: true }),
    use("mcp__plugin_waggle_waggle__waggle_ask", { title: "pencil sqlite3 swift test" }),
  ];
  const states = (out: ReturnType<typeof checkSources>) => Object.fromEntries(out.map((o) => [o.id, o.state]));

  test("each kind is seen when its call is in the session", () => {
    writeTranscript(transcript);
    const out = ask(setup(), KnockAskInput.parse({ ...base, sources })).sources!;
    expect(states(out)).toEqual({
      file: "seen", doc: "seen", img: "seen", rule: "seen", grep: "seen", rg: "seen", hist: "seen", test: "seen",
      db: "seen", api: "seen", tool: "seen", design: "seen", web: "seen", agent: "seen", said: "seen",
      none: "assumption", noref: "stated", miss: "stated", late: "stated",
    });
    const byId = Object.fromEntries(out.map((o) => [o.id, o]));
    expect(byId.file!.seen_at).toBe("2026-10-10T10:40:00.000Z");
    expect(byId.db!.seen_at).toBe("2026-10-10T10:41:30.000Z");
    expect(byId.none!.seen_at).toBeUndefined();
    expect(byId.miss!.seen_at).toBeUndefined();
    // Only the result is stored, never transcript content.
    expect(JSON.stringify(out)).not.toContain("/tmp/p/");
  });

  test("a relative or dot path matches the end of the read path", () => {
    writeTranscript(transcript);
    const out = checkSources([src("a", "file", { ref: { path: "./store.ts" } })], { sessionId: SESSION, cwd: CWD, transcriptAllowed: true, askedAt: ASKED, decisionRepliedAt: () => null });
    expect(out[0]!.state).toBe("seen");
  });

  test("the read is not allowed: every transcript source is stated, kind none stays an assumption", () => {
    writeTranscript(transcript);
    const off = { tools: { transcriptEnabled: false }, record() {}, projectHash: () => "", askHash: () => "000000000000" } as unknown as UsageLogger;
    const out = ask(setup(off), KnockAskInput.parse({ ...base, sources })).sources!;
    expect(new Set(out.filter((o) => o.kind !== "none").map((o) => o.state))).toEqual(new Set(["stated"]));
    expect(out.find((o) => o.kind === "none")!.state).toBe("assumption");
  });

  test("no transcript file: stated", () => {
    const out = ask(setup(), KnockAskInput.parse({ ...base, sources })).sources!;
    expect(out.find((o) => o.id === "file")!.state).toBe("stated");
  });

  test("a damaged transcript line does not stop the check", () => {
    writeFileSync(join(root, cwdSlug(CWD), `${SESSION}.jsonl`), "not json\n" + transcript.map((r) => JSON.stringify(r)).join("\n") + "\n{\"cut");
    const out = ask(setup(), KnockAskInput.parse({ ...base, sources })).sources!;
    expect(out.find((o) => o.id === "file")!.state).toBe("seen");
  });

  test("decision: seen once the case has a reply", () => {
    const s = setup();
    const earlier = ask(s, KnockAskInput.parse({ ...base, why: "Plain.", items: plainItems }));
    const cite = KnockAskInput.parse({ ...base, title: "Next?", sources: [src("d", "decision", { ref: { case_id: earlier.id } }), src("e", "decision", { ref: { case_id: "c_missing" } })] });
    expect(ask(s, cite).sources!.map((x) => x.state)).toEqual(["stated", "stated"]);
    s.store.submitReply(earlier.id, { idempotency_key: "k1", choice: "x", comments: [], captures: [] });
    const out = ask(s, { ...cite, title: "Third?" }).sources!;
    expect(out.map((x) => x.state)).toEqual(["seen", "stated"]);
    expect(out[0]!.seen_at).toBeTruthy();
  });
});
