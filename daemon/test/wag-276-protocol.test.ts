import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { Database } from "bun:sqlite";
import { EventBus } from "../src/events";
import { Store } from "../src/store";
import { Artifact, KnockAskInput, KnockUpdateInput, Option } from "../src/protocol";
import { withStagedArtifact } from "../src/mcp/shim";
import { rmrf, tmpHome } from "./helpers";

// WAG-276: options carry pros, cons, artifact_ref and anchor; artifacts carry a name; revisions
// return name and kind.

const homes: string[] = [];
afterEach(() => {
  for (const h of homes.splice(0)) rmrf(h);
});

const fullOption = {
  id: "a",
  label: "Use the flow shown in the diagram",
  title: "Diagram flow",
  pros: ["Fast to build", "Easy to test"],
  cons: ["Less flexible"],
  artifact_ref: "Flow diagram",
  anchor: "step-2",
};

const planAsk = {
  kind: "plan" as const,
  stage: { name: "questions" as const, step: 1, total: 3 },
  title: "Plan: flow",
  need: "Which flow?",
  why: "It sets the first screen.",
  recommendation: "a",
  recommendation_why: "Simple.",
  options: [fullOption, { id: "b", label: "Old style option" }],
};

function setup(): { store: Store; home: string; taskId: string } {
  const home = tmpHome();
  homes.push(home);
  const store = new Store(new Database(join(home, "knock.db")), home, new EventBus());
  return { store, home, taskId: store.createTask({ name: "WAG-276", project: "app" }).id };
}

function stagedMarkdown(home: string, file: string, name?: string): Artifact {
  const dir = join(home, "incoming", file);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "a.md"), `# ${file}`);
  return { type: "markdown", path: join(dir, "a.md"), ...(name ? { name } : {}) };
}

describe("Option fields", () => {
  test("all four new fields parse and old id+label options still parse", () => {
    expect(Option.parse(fullOption)).toEqual(fullOption);
    expect(Option.parse({ id: "x", label: "y" })).toEqual({ id: "x", label: "y" });
  });

  test("trims, and rejects too many or too long entries", () => {
    expect(Option.parse({ id: "x", label: "y", artifact_ref: "  Flow  ", anchor: " s " })).toMatchObject({
      artifact_ref: "Flow",
      anchor: "s",
    });
    expect(Option.safeParse({ id: "x", label: "y", pros: ["1", "2", "3", "4", "5", "6"] }).success).toBe(false);
    expect(Option.safeParse({ id: "x", label: "y", cons: ["x".repeat(161)] }).success).toBe(false);
    expect(Option.safeParse({ id: "x", label: "y", pros: [""] }).success).toBe(false);
    expect(Option.safeParse({ id: "x", label: "y", artifact_ref: "x".repeat(81) }).success).toBe(false);
    expect(Option.safeParse({ id: "x", label: "y", anchor: "x".repeat(121) }).success).toBe(false);
  });

  test("an ask keeps the fields in case options, first_options, the list, and plan rounds", () => {
    const { store, taskId } = setup();
    const created = store.createCase(taskId, KnockAskInput.parse(planAsk));
    const detail = store.getCase(created.id)!;
    expect(detail.case.options[0]).toEqual(fullOption);
    expect(detail.case.options[1]).toEqual({ id: "b", label: "Old style option" });
    expect(detail.plan_rounds![0]!.options[0]).toEqual(fullOption);
    const listed = store.listCases().find((c) => c.id === created.id)!;
    expect(listed.options[0]).toEqual(fullOption);
  });

  test("an update with options keeps the fields and first_options keeps the ask's set", () => {
    const { store, taskId } = setup();
    const created = store.createCase(taskId, KnockAskInput.parse(planAsk));
    const newOpt = { ...fullOption, id: "z", pros: ["Cheap"], anchor: "other" };
    const upd = KnockUpdateInput.parse({
      case_id: created.id,
      message: "Next round",
      stage: { name: "approaches" },
      options: [newOpt, { id: "y", label: "Plain" }],
      recommendation: "z",
    });
    store.updateCase(created.id, upd);
    const detail = store.getCase(created.id)!;
    expect(detail.case.options[0]).toEqual(newOpt);
    expect(detail.case.first_options[0]).toEqual(fullOption);
    expect(detail.plan_rounds![1]!.options[0]).toEqual(newOpt);
  });
});

describe("Artifact name", () => {
  test("name parses on every variant and is trimmed", () => {
    expect(Artifact.parse({ type: "markdown", content: "x", name: " Notes " })).toMatchObject({ name: "Notes" });
    expect(Artifact.parse({ type: "diagram", path: "a.mmd", name: "Flow" })).toMatchObject({ name: "Flow" });
    expect(Artifact.parse({ type: "html_bundle", html: "<p>x</p>", name: "Page" })).toMatchObject({ name: "Page" });
    expect(Artifact.parse({ type: "screenshot", path: "a.png", name: "Shot" })).toMatchObject({ name: "Shot" });
    expect(
      Artifact.parse({ type: "screenshots", name: "Shots", items: [{ path: "a.png" }, { path: "b.png" }] }),
    ).toMatchObject({ name: "Shots" });
    expect(Artifact.safeParse({ type: "markdown", content: "x", name: "x".repeat(41) }).success).toBe(false);
    expect(Artifact.safeParse({ type: "markdown", content: "x", name: "  " }).success).toBe(false);
  });

  test("update with a named artifact stores the name; cases.get returns name and kind", () => {
    const { store, home, taskId } = setup();
    const created = store.createCase(taskId, KnockAskInput.parse(planAsk));
    store.updateCase(
      created.id,
      KnockUpdateInput.parse({ case_id: created.id, message: "Named", artifact: stagedMarkdown(home, "one", "Flow diagram") }),
    );
    store.updateCase(
      created.id,
      KnockUpdateInput.parse({ case_id: created.id, message: "Unnamed", artifact: stagedMarkdown(home, "two") }),
    );
    const revs = store.getCase(created.id)!.revisions;
    expect(revs[0]).toMatchObject({ n: 1, name: "Flow diagram", kind: "markdown" });
    expect(revs[1]!.n).toBe(2);
    expect(revs[1]!.name).toBeUndefined();
    expect(revs[1]!.kind).toBe("markdown");
  });

  test("an ask with a named artifact stores the name on revision 1", () => {
    const { store, home, taskId } = setup();
    const created = store.createCase(taskId, KnockAskInput.parse({ ...planAsk, artifact: stagedMarkdown(home, "ask", "Spec") }));
    expect(store.getCase(created.id)!.revisions[0]).toMatchObject({ name: "Spec", kind: "markdown" });
  });

  test("the shim keeps name when it stages every artifact form", () => {
    const { home } = setup();
    const prev = process.env.KNOCK_HOME;
    process.env.KNOCK_HOME = home;
    try {
      const cwd = join(home, "work");
      mkdirSync(cwd, { recursive: true });
      writeFileSync(join(cwd, "a.md"), "# hi");
      const state = { cwd } as never;
      const md = withStagedArtifact(state, { artifact: { type: "markdown", path: "a.md", name: "Notes" } });
      expect((md.artifact as { name?: string }).name).toBe("Notes");
      const inline = withStagedArtifact(state, { artifact: { type: "markdown", content: "# x", name: "Inline" } });
      expect((inline.artifact as { name?: string }).name).toBe("Inline");
      const html = withStagedArtifact(state, { artifact: { type: "html_bundle", html: "<p>x</p>", name: "Page" } });
      expect(html.artifact).toMatchObject({ type: "html_bundle", name: "Page" });
      const plain = withStagedArtifact(state, { artifact: { type: "markdown", path: "a.md" } });
      expect("name" in (plain.artifact as object)).toBe(false);
    } finally {
      if (prev === undefined) delete process.env.KNOCK_HOME;
      else process.env.KNOCK_HOME = prev;
    }
  });
});
