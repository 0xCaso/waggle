import { afterEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { existsSync, lstatSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { EventBus } from "../src/events";
import { Store } from "../src/store";
import { ReplySubmitParams, ReplyReplaceParams } from "../src/protocol/rpc";
import { MAX_ATTACHMENT_BYTES, MAX_REPLY_ATTACHMENTS, safeAttachmentName } from "../src/artifacts/attachments";
import type { KnockAskInput } from "../src/protocol";
import { rmrf, tmpHome } from "./helpers";

// WAG-345: files attached to a reply. The app stages each file in incoming/<uuid>/<name>. The daemon copies it
// to attachments/<reply id>/, read-only, and the agent reads the absolute path.

const ask: KnockAskInput = {
  kind: "question",
  title: "Pick a layout",
  need: "Pick a layout",
  why: "I cannot decide",
  recommendation: "a",
  recommendation_why: "It is the default",
  options: [
    { id: "a", label: "Compact layout with a sidebar", title: "Compact" },
    { id: "b", label: "Detailed layout with tabs", title: "Detailed" },
  ],
};

const homes: string[] = [];
afterEach(() => {
  for (const h of homes.splice(0)) rmrf(h);
});

function seed() {
  const home = tmpHome();
  homes.push(home);
  const db = new Database(":memory:");
  const store = new Store(db, home, new EventBus());
  const task = store.createTask({ name: "checkout", project: "knock" });
  store.createSession(task.id, { id: "sess-1", cwd: "/work", branch: null, pid: 4242 });
  const caseId = store.createCase(task.id, ask).id;
  return { home, store, caseId };
}

let counter = 0;
// What the app does: one incoming/<uuid>/ folder per file.
function stage(home: string, name: string, bytes: Buffer | string = "hello"): string {
  counter += 1;
  const dir = join(home, "incoming", `att-${counter}`);
  mkdirSync(dir, { recursive: true });
  const path = join(dir, name);
  writeFileSync(path, bytes);
  return path;
}

const text = (store: Store, replyId: string): string => {
  const block = store.buildReplyPayload(replyId)!.content[0]!;
  return block.type === "text" ? block.text : "";
};

describe("attachments on a reply", () => {
  test("a reply stores the files read-only under the data folder and lists them", () => {
    const { home, store, caseId } = seed();
    const png = stage(home, "shot.png", Buffer.from([0x89, 0x50, 0x4e, 0x47]));
    const pdf = stage(home, "brief.pdf", "%PDF-1.4");
    const reply = store.submitReply(caseId, {
      idempotency_key: "k1",
      choice: "a",
      comments: [],
      captures: [],
      attachments: [
        { name: "shot.png", incoming_path: png, type: "image/png" },
        { name: "brief.pdf", incoming_path: pdf },
      ],
    });
    expect(reply.attachments).toHaveLength(2);
    const [first, second] = reply.attachments!;
    expect(first).toMatchObject({ name: "shot.png", size: 4, type: "image/png" });
    expect(second).toMatchObject({ name: "brief.pdf", size: 8, type: "application/pdf" });
    expect(first!.path).toBe(join(home, "attachments", reply.id, "shot.png"));
    expect(readFileSync(second!.path, "utf8")).toBe("%PDF-1.4");
    expect(lstatSync(first!.path).mode & 0o222).toBe(0);
    // The incoming copies are gone.
    expect(existsSync(png)).toBe(false);
    expect(existsSync(pdf)).toBe(false);
  });

  test("the check text lists the files with name and path, after the message", () => {
    const { home, store, caseId } = seed();
    const a = stage(home, "a.txt");
    const b = stage(home, "b.csv");
    const reply = store.submitReply(caseId, {
      idempotency_key: "k2",
      choice: "b",
      message: "See the files",
      comments: [],
      captures: [],
      attachments: [
        { name: "a.txt", incoming_path: a },
        { name: "b.csv", incoming_path: b },
      ],
    });
    const out = text(store, reply.id);
    expect(out).toContain("Message: See the files");
    expect(out).toContain("Attached: 2 files");
    expect(out).toContain(`- a.txt: ${reply.attachments![0]!.path}`);
    expect(out).toContain(`- b.csv: ${reply.attachments![1]!.path}`);
  });

  test("one file reads 'Attached: 1 file'", () => {
    const { home, store, caseId } = seed();
    const reply = store.submitReply(caseId, {
      idempotency_key: "k3",
      choice: "a",
      comments: [],
      captures: [],
      attachments: [{ name: "a.txt", incoming_path: stage(home, "a.txt") }],
    });
    expect(text(store, reply.id)).toContain("Attached: 1 file\n");
  });

  test("a reply with no files has no attachments field and no Attached line (old agents)", () => {
    const { store, caseId } = seed();
    const reply = store.submitReply(caseId, { idempotency_key: "k4", choice: "a", comments: [], captures: [] });
    expect(reply.attachments).toBeUndefined();
    expect(text(store, reply.id)).not.toContain("Attached");
  });

  test("Keep talking with files only is accepted; with nothing at all it is not", () => {
    const { home, store, caseId } = seed();
    const reply = store.submitReply(caseId, {
      idempotency_key: "k5",
      intent: "discuss",
      comments: [],
      captures: [],
      attachments: [{ name: "idea.md", incoming_path: stage(home, "idea.md") }],
    });
    expect(reply.intent).toBe("discuss");
    expect(reply.outcome).toBe("talk");
    expect(text(store, reply.id)).toContain("Attached: 1 file");
    expect(() =>
      store.submitReply(caseId, { idempotency_key: "k5b", intent: "discuss", comments: [], captures: [] }),
    ).toThrow();
  });

  test("more than 10 files are refused and nothing is stored", () => {
    const { home, store, caseId } = seed();
    const attachments = Array.from({ length: MAX_REPLY_ATTACHMENTS + 1 }, (_, i) => ({
      name: `f${i}.txt`,
      incoming_path: stage(home, `f${i}.txt`),
    }));
    expect(() =>
      store.submitReply(caseId, { idempotency_key: "k6", choice: "a", comments: [], captures: [], attachments }),
    ).toThrow(/at most 10/);
    expect(existsSync(join(home, "attachments"))).toBe(false);
  });

  test("a file over 25 MB is refused with its name", () => {
    const { home, store, caseId } = seed();
    const big = stage(home, "huge.bin", Buffer.alloc(MAX_ATTACHMENT_BYTES + 1));
    expect(() =>
      store.submitReply(caseId, {
        idempotency_key: "k7",
        choice: "a",
        comments: [],
        captures: [],
        attachments: [{ name: "huge.bin", incoming_path: big }],
      }),
    ).toThrow(/huge\.bin is larger than 25 MB/);
  });

  test("a path outside incoming/ is refused", () => {
    const { home, store, caseId } = seed();
    const outside = join(home, "elsewhere.txt");
    writeFileSync(outside, "x");
    expect(() =>
      store.submitReply(caseId, {
        idempotency_key: "k8",
        choice: "a",
        comments: [],
        captures: [],
        attachments: [{ name: "elsewhere.txt", incoming_path: outside }],
      }),
    ).toThrow(/incoming/);
    expect(() =>
      store.submitReply(caseId, {
        idempotency_key: "k8b",
        choice: "a",
        comments: [],
        captures: [],
        attachments: [{ name: "x", incoming_path: "relative/x" }],
      }),
    ).toThrow(/incoming/);
  });

  test("two files with one name keep both; a folder in the name is dropped", () => {
    const { home, store, caseId } = seed();
    const reply = store.submitReply(caseId, {
      idempotency_key: "k9",
      choice: "a",
      comments: [],
      captures: [],
      attachments: [
        { name: "../../etc/shot.png", incoming_path: stage(home, "one.png") },
        { name: "shot.png", incoming_path: stage(home, "two.png") },
      ],
    });
    expect(reply.attachments!.map((a) => a.name)).toEqual(["shot.png", "shot 2.png"]);
    expect(safeAttachmentName("a/b\\c.txt")).toBe("c.txt");
    expect(safeAttachmentName("..")).toBe("file");
  });

  test("the same idempotency key does not copy the files twice and clears the staged copy", () => {
    const { home, store, caseId } = seed();
    const first = stage(home, "a.txt");
    const input = {
      idempotency_key: "k10",
      choice: "a",
      comments: [],
      captures: [],
    };
    const one = store.submitReply(caseId, { ...input, attachments: [{ name: "a.txt", incoming_path: first }] });
    const again = stage(home, "a.txt");
    const two = store.submitReply(caseId, { ...input, attachments: [{ name: "a.txt", incoming_path: again }] });
    expect(two.id).toBe(one.id);
    expect(two.attachments).toHaveLength(1);
    expect(existsSync(again)).toBe(false);
  });

  test("reply.replace keeps, adds and drops files", () => {
    const { home, store, caseId } = seed();
    const reply = store.submitReply(caseId, {
      idempotency_key: "k11",
      choice: "a",
      comments: [],
      captures: [],
      attachments: [
        { name: "a.txt", incoming_path: stage(home, "a.txt") },
        { name: "b.txt", incoming_path: stage(home, "b.txt") },
      ],
    });
    const [a, b] = reply.attachments!;
    // Omitted keeps the files.
    const kept = store.replaceReply(reply.id, { choice: "a", comments: [], captures: [] })!;
    expect(kept.attachments).toHaveLength(2);
    // Keep a, drop b, add c.
    const replaced = store.replaceReply(reply.id, {
      choice: "a",
      comments: [],
      captures: [],
      attachments: [{ name: "a.txt", path: a!.path }, { name: "c.txt", incoming_path: stage(home, "c.txt") }],
    })!;
    expect(replaced.attachments!.map((x) => x.name)).toEqual(["a.txt", "c.txt"]);
    expect(existsSync(a!.path)).toBe(true);
    expect(existsSync(b!.path)).toBe(false);
    // An empty list drops all.
    const none = store.replaceReply(reply.id, { choice: "a", comments: [], captures: [], attachments: [] })!;
    expect(none.attachments).toBeUndefined();
    // A path the reply does not hold is refused.
    expect(() =>
      store.replaceReply(reply.id, {
        choice: "a",
        comments: [],
        captures: [],
        attachments: [{ name: "x", path: join(home, "attachments", "other", "x") }],
      }),
    ).toThrow();
  });

  test("the wire schema accepts attachments and an old payload without them", () => {
    const base = { case_id: "c", idempotency_key: "k", comments: [], captures: [] };
    expect(ReplySubmitParams.parse(base).attachments).toBeUndefined();
    const parsed = ReplySubmitParams.parse({ ...base, attachments: [{ name: "a.png", incoming_path: "/x/incoming/u/a.png" }] });
    expect(parsed.attachments).toHaveLength(1);
    expect(ReplyReplaceParams.parse({ reply_id: "r", comments: [], captures: [] }).attachments).toBeUndefined();
  });

  test("a purged case removes its attached files", () => {
    const { home, store, caseId } = seed();
    const reply = store.submitReply(caseId, {
      idempotency_key: "k12",
      choice: "a",
      comments: [],
      captures: [],
      attachments: [{ name: "a.txt", incoming_path: stage(home, "a.txt") }],
    });
    const dir = join(home, "attachments", reply.id);
    expect(existsSync(dir)).toBe(true);
    store.dismissCase(caseId);
    expect(store.purgeResolvedCases().purged_cases).toBe(1);
    expect(existsSync(dir)).toBe(false);
  });
});
