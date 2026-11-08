import { afterEach, describe, expect, test } from "bun:test";
import { createHash, randomUUID } from "node:crypto";
import {
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { dirname, join } from "node:path";
import { Database } from "bun:sqlite";
import { ArtifactError } from "../src/artifacts";
import { EventBus } from "../src/events";
import { Store } from "../src/store";
import type { Artifact, Event, KnockAskInput } from "../src/protocol";
import { rmrf, stageIncoming, tmpHome } from "./helpers";

const PNG_SIG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

const homes: string[] = [];

function newHome(): string {
  const h = tmpHome();
  homes.push(h);
  return h;
}

afterEach(() => {
  for (const h of homes.splice(0)) {
    rmrf(h);
  }
});

function write(path: string, data: string | Buffer): void {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, data);
}

function pngBytes(): Buffer {
  return Buffer.concat([PNG_SIG, Buffer.from("store test png")]);
}

function sha256(data: Buffer): string {
  return createHash("sha256").update(data).digest("hex");
}

const question: KnockAskInput = {
  kind: "question",
  title: "Checkout layout",
  need: "Pick a layout",
  why: "I cannot decide",
  recommendation: "Compact",
  recommendation_why: "It fits on one line",
};

interface Harness {
  store: Store;
  db: Database;
  bus: EventBus;
  home: string;
  cwd: string;
  caseId: string;
}

function setup(events?: Event[]): Harness {
  const home = newHome();
  const cwd = join(home, "work");
  mkdirSync(cwd, { recursive: true });
  const db = new Database(join(home, "knock.db"));
  const bus = new EventBus();
  if (events) bus.subscribe((e) => events.push(e));
  const store = new Store(db, home, bus);
  const task = store.createTask({ name: "checkout", project: "knock" });
  const caseId = store.createCase(task.id, question).id;
  return { store, db, bus, home, cwd, caseId };
}

function screenshotArtifact(path: string): Artifact {
  return { type: "screenshot", path };
}

function markdownArtifact(path: string): Artifact {
  return { type: "markdown", path };
}

function screenshotsArtifact(items: { path: string; caption?: string }[]): Artifact {
  return { type: "screenshots", items };
}

// Stages the artifact like the shim would, returning the incoming artifact.
function incoming(home: string, cwd: string, artifact: Artifact): Artifact {
  return stageIncoming(home, cwd, artifact);
}

describe("Store revisions", () => {
  test("createRevision ingests a screenshot as revision 1 and flips has_artifact", () => {
    const { store, home, cwd, caseId } = setup();
    const data = pngBytes();
    write(join(cwd, "shots", "a.png"), data);

    const revision = store.createRevision(
      caseId,
      incoming(home, cwd, screenshotArtifact("./shots/a.png")),
    );

    expect(revision).toMatchObject({ case_id: caseId, n: 1 });
    expect(readFileSync(join(home, "blobs", `${sha256(data)}.png`)).equals(data)).toBe(true);
    expect(store.listCases()[0].has_artifact).toBe(true);
    expect(store.getCase(caseId)!.revisions).toHaveLength(1);
  });

  test("successive revisions number 1..n", () => {
    const { store, home, cwd, caseId } = setup();
    const data = pngBytes();
    write(join(cwd, "a.png"), data);
    write(join(cwd, "b.png"), data);

    expect(store.createRevision(caseId, incoming(home, cwd, screenshotArtifact("./a.png"))).n).toBe(1);
    expect(store.createRevision(caseId, incoming(home, cwd, screenshotArtifact("./b.png"))).n).toBe(2);
    expect(store.getCase(caseId)!.revisions.map((r) => r.n)).toEqual([1, 2]);
  });

  test("two identical screenshots share one blob", () => {
    const { store, home, cwd, caseId } = setup();
    const data = pngBytes();
    write(join(cwd, "a.png"), data);
    write(join(cwd, "b.png"), data);

    store.createRevision(caseId, incoming(home, cwd, screenshotArtifact("./a.png")));
    store.createRevision(caseId, incoming(home, cwd, screenshotArtifact("./b.png")));

    const blobs = readdirSync(join(home, "blobs"));
    expect(blobs).toEqual([`${sha256(data)}.png`]);
  });

  test("createRevision emits revision.added with the case id", () => {
    const events: Event[] = [];
    const { store, home, cwd, caseId } = setup(events);
    write(join(cwd, "a.png"), pngBytes());

    store.createRevision(caseId, incoming(home, cwd, screenshotArtifact("./a.png")));

    expect(events.map((e) => e.type)).toEqual(["case.created", "revision.added"]);
    expect(events[1]).toMatchObject({ type: "revision.added", case_id: caseId });
  });

  test("artifactPath returns the absolute staged path for a screenshot and a bundle", () => {
    const { store, home, cwd, caseId } = setup();

    const data = pngBytes();
    write(join(cwd, "shot.png"), data);
    store.createRevision(caseId, incoming(home, cwd, screenshotArtifact("./shot.png")));
    expect(store.artifactPath(caseId, 1)).toEqual({
      kind: "screenshot",
      root: join(home, "blobs", `${sha256(data)}.png`),
      entry: "",
    });

    write(join(cwd, "proto", "index.html"), "<h1>hi</h1>");
    write(join(cwd, "proto", "app.js"), "let x = 1;");
    store.createRevision(
      caseId,
      incoming(home, cwd, { type: "html_bundle", dir: "proto", entry: "index.html" }),
    );
    expect(store.artifactPath(caseId, 2)).toEqual({
      kind: "html_bundle",
      root: join(home, "bundles", caseId, "r2"),
      entry: join(home, "bundles", caseId, "r2", "index.html"),
    });
  });

  test("artifactPath returns null for an unknown revision", () => {
    const { store, home, cwd, caseId } = setup();
    write(join(cwd, "shot.png"), pngBytes());
    store.createRevision(caseId, incoming(home, cwd, screenshotArtifact("./shot.png")));
    expect(store.artifactPath(caseId, 2)).toBeNull();
  });

  test("createRevision rejects an unknown case", () => {
    const { store, home, cwd } = setup();
    write(join(cwd, "shot.png"), pngBytes());
    expect(() =>
      store.createRevision("c_missing", incoming(home, cwd, screenshotArtifact("./shot.png"))),
    ).toThrow(ArtifactError);
  });

  test("a rejected bundle adds no revision and leaves no partial copy", () => {
    const { store, home, cwd, caseId } = setup();
    // Plant a symlink inside the incoming dir directly, so the daemon's own
    // re-validation (not the shim's) rejects it.
    const uuidDir = join(home, "incoming", randomUUID());
    write(join(uuidDir, "index.html"), "ok");
    write(join(cwd, "outside.txt"), "secret");
    symlinkSync(join(cwd, "outside.txt"), join(uuidDir, "link.txt"));

    expect(() =>
      store.createRevision(caseId, { type: "html_bundle", dir: uuidDir, entry: "index.html" }),
    ).toThrow(/symlinks/);

    expect(store.getCase(caseId)!.revisions).toEqual([]);
    const caseDir = join(home, "bundles", caseId);
    if (existsSync(caseDir)) {
      expect(readdirSync(caseDir)).toEqual([]);
    }
    expect(existsSync(uuidDir)).toBe(false);
  });

  // HAIL-33: markdown is a third artifact kind, staged like a screenshot.
  test("createRevision ingests markdown as blobs/<sha256>.md", () => {
    const { store, home, cwd, caseId } = setup();
    write(join(cwd, "notes", "explain.md"), "# Trade-offs\n");

    const revision = store.createRevision(
      caseId,
      incoming(home, cwd, markdownArtifact("./notes/explain.md")),
    );

    expect(revision).toMatchObject({ case_id: caseId, n: 1 });
    expect(store.listCases()[0].artifact_kind).toBe("markdown");
    expect(store.artifactPath(caseId, 1)).toEqual({
      kind: "markdown",
      root: join(home, "blobs", `${sha256(Buffer.from("# Trade-offs\n"))}.md`),
      entry: "",
    });
  });

  // waggle_update (case.update / store.updateCase) shares the same ingest path
  // as waggle_ask; a markdown explanation lands as the next revision and the
  // case returns to needs_you (AC "the returned round shows a markdown
  // explanation").
  test("updateCase (waggle_update) adds a markdown revision and returns needs_you", () => {
    const { store, home, cwd, caseId } = setup();
    store.submitReply(caseId, { idempotency_key: "key-detail", intent: "more_detail", comments: [], captures: [] });
    expect(store.getCase(caseId)!.case.status).toBe("waiting_on_agent");

    write(join(cwd, "explain.md"), "# The trade-offs\n\nHere is why.");

    const updated = store.updateCase(caseId, {
      case_id: caseId,
      message: "Here is the trade-off write-up.",
      artifact: incoming(home, cwd, markdownArtifact("./explain.md")),
    })!;

    expect(updated.status).toBe("needs_you");
    expect(updated.artifact_kind).toBe("markdown");
    const detail = store.getCase(caseId)!;
    expect(detail.revisions).toHaveLength(1);
    expect(detail.messages.at(-1)).toMatchObject({
      role: "agent",
      text: "Here is the trade-off write-up.",
    });
  });

  // HAIL-40: a screenshots artifact stores an ordered list in one revision
  // (items_json), each image content-addressed the same way a single
  // screenshot is.
  test("createRevision ingests a screenshots artifact and stores its ordered items", () => {
    const { store, home, cwd, caseId } = setup();
    const first = pngBytes();
    const second = Buffer.concat([PNG_SIG, Buffer.from("second image")]);
    write(join(cwd, "shots", "1.png"), first);
    write(join(cwd, "shots", "2.png"), second);

    const revision = store.createRevision(
      caseId,
      incoming(
        home,
        cwd,
        screenshotsArtifact([
          { path: "./shots/1.png", caption: "Home" },
          { path: "./shots/2.png" },
        ]),
      ),
    );

    expect(revision).toMatchObject({ case_id: caseId, n: 1 });
    expect(store.listCases()[0].artifact_kind).toBe("screenshots");
    expect(store.listCases()[0].has_artifact).toBe(true);
    expect(readFileSync(join(home, "blobs", `${sha256(first)}.png`)).equals(first)).toBe(true);
    expect(readFileSync(join(home, "blobs", `${sha256(second)}.png`)).equals(second)).toBe(true);

    expect(store.artifactPath(caseId, 1)).toEqual({
      kind: "screenshots",
      root: "",
      entry: "",
      items: [
        { path: join(home, "blobs", `${sha256(first)}.png`), caption: "Home" },
        { path: join(home, "blobs", `${sha256(second)}.png`) },
      ],
    });
  });

  test("rejects a screenshots item that fails re-validation and adds no revision", () => {
    const { store, home, cwd, caseId } = setup();
    write(join(cwd, "1.png"), pngBytes());
    write(join(cwd, "2.png"), pngBytes());
    const staged = incoming(
      home,
      cwd,
      screenshotsArtifact([{ path: "./1.png" }, { path: "./2.png" }]),
    );
    // Corrupt the second staged item after the shim copied it, so the
    // daemon's own re-validation (not the shim's) rejects it.
    if (staged.type === "screenshots") {
      writeFileSync(staged.items[1]!.path, "not a png any more");
    }

    expect(() => store.createRevision(caseId, staged)).toThrow(/not a PNG/);
    expect(store.getCase(caseId)!.revisions).toEqual([]);
  });

  // waggle_update (case.update / store.updateCase) shares the same ingest path
  // as waggle_ask; a screenshots artifact lands as the next revision.
  test("updateCase (waggle_update) adds a screenshots revision and returns needs_you", () => {
    const { store, home, cwd, caseId } = setup();
    store.submitReply(caseId, { idempotency_key: "key-detail", intent: "more_detail", comments: [], captures: [] });
    write(join(cwd, "1.png"), pngBytes());
    write(join(cwd, "2.png"), Buffer.concat([PNG_SIG, Buffer.from("two")]));
    write(join(cwd, "3.png"), Buffer.concat([PNG_SIG, Buffer.from("three")]));

    const updated = store.updateCase(caseId, {
      case_id: caseId,
      message: "Here are the 3 onboarding screens.",
      artifact: incoming(
        home,
        cwd,
        screenshotsArtifact([{ path: "./1.png" }, { path: "./2.png" }, { path: "./3.png" }]),
      ),
    })!;

    expect(updated.status).toBe("needs_you");
    expect(updated.artifact_kind).toBe("screenshots");
    expect(store.artifactPath(caseId, 1)!.items).toHaveLength(3);
  });

  test("a staged bundle copy is read-only and immune to later source edits", () => {
    const { store, home, cwd, caseId } = setup();
    const src = join(cwd, "proto");
    write(join(src, "index.html"), "<h1>v1</h1>");
    write(join(src, "app.js"), "let v = 1;");

    store.createRevision(
      caseId,
      incoming(home, cwd, { type: "html_bundle", dir: "proto", entry: "index.html" }),
    );
    const { root } = store.artifactPath(caseId, 1)!;

    writeFileSync(join(src, "index.html"), "<h1>v2</h1>");
    rmSync(join(src, "app.js"));

    expect(readFileSync(join(root, "index.html"), "utf8")).toBe("<h1>v1</h1>");
    expect(readFileSync(join(root, "app.js"), "utf8")).toBe("let v = 1;");
    assertReadOnly(root);
  });
});

function assertReadOnly(root: string): void {
  const st = lstatSync(root);
  expect(st.mode & 0o222).toBe(0);
  if (st.isDirectory()) {
    for (const name of readdirSync(root)) {
      assertReadOnly(join(root, name));
    }
  }
}
