import { describe, expect, test } from "bun:test";
import { Comment, Artifact, KnockAskInput, KnockCheckInput, KnockUpdateInput } from "../src/protocol";

function screenshotItems(n: number): { path: string; caption?: string }[] {
  return Array.from({ length: n }, (_, i) => ({ path: `./shots/${i + 1}.png` }));
}

// Each MCP input parses one valid and one invalid sample, per KNOCK-01.
describe("waggle_ask input", () => {
  const validQuestion = {
    kind: "question",
    title: "Checkout layout",
    need: "Pick a layout",
    why: "I cannot decide",
    recommendation: "Compact",
    recommendation_why: "It fits on one line",
  };

  const validReview = {
    kind: "review",
    title: "Checkout layout",
    need: "Approve the layout",
    why: "It needs a human eye",
    recommendation: "a",
    recommendation_why: "It is the default",
    options: [
      { id: "a", label: "Compact" },
      { id: "b", label: "Detailed" },
    ],
    artifact: { type: "screenshot", path: "./shots/a.png" },
  };

  test("parses a valid question", () => {
    expect(KnockAskInput.safeParse(validQuestion).success).toBe(true);
  });

  test("parses a valid review with an artifact", () => {
    expect(KnockAskInput.safeParse(validReview).success).toBe(true);
  });

  test("accepts options with and without a title (HAIL-85)", () => {
    const mixed = { ...validReview, options: [{ id: "a", label: "Compact: one screen", title: "Compact" }, { id: "b", label: "Detailed" }] };
    const parsed = KnockAskInput.safeParse(mixed);
    expect(parsed.success).toBe(true);
    if (parsed.success) {
      expect(parsed.data.options?.[0].title).toBe("Compact");
      expect(parsed.data.options?.[1].title).toBeUndefined();
    }
  });

  test("rejects an empty option title", () => {
    const bad = { ...validReview, options: [{ id: "a", label: "Compact", title: "" }, { id: "b", label: "Detailed" }] };
    expect(KnockAskInput.safeParse(bad).success).toBe(false);
  });

  test("rejects an empty title", () => {
    expect(KnockAskInput.safeParse({ ...validQuestion, title: "" }).success).toBe(false);
  });

  test("rejects a review without an artifact", () => {
    const { artifact: _artifact, ...rest } = validReview;
    expect(KnockAskInput.safeParse(rest).success).toBe(false);
  });

  test("rejects a recommendation that is not an option id", () => {
    expect(KnockAskInput.safeParse({ ...validReview, recommendation: "c" }).success).toBe(false);
  });

  // HAIL-37: why up to 500 chars (after trimming) is accepted; 501 is rejected
  // with the exact message the agent needs to fix its own input.
  test("accepts why at exactly 500 characters", () => {
    const result = KnockAskInput.safeParse({ ...validQuestion, why: "a".repeat(500) });
    expect(result.success).toBe(true);
  });

  test("rejects why at 501 characters with the exact error text", () => {
    const result = KnockAskInput.safeParse({ ...validQuestion, why: "a".repeat(501) });
    expect(result.success).toBe(false);
    if (!result.success) {
      const issue = result.error.issues.find((i) => i.path.join(".") === "why");
      expect(issue?.message).toBe(
        "why is 501 characters; the maximum is 500. Keep why to 1 to 3 sentences and put the " +
          "details in an artifact: markdown for reasoning, html_bundle for a prototype, chart or plan.",
      );
    }
  });

  test("counts why's length after trimming", () => {
    const result = KnockAskInput.safeParse({ ...validQuestion, why: `  ${"a".repeat(500)}  ` });
    expect(result.success).toBe(true);
  });

  // recommendation_why: same rule, 300-character limit.
  test("accepts recommendation_why at exactly 300 characters", () => {
    const result = KnockAskInput.safeParse({
      ...validQuestion,
      recommendation_why: "a".repeat(300),
    });
    expect(result.success).toBe(true);
  });

  test("rejects recommendation_why at 301 characters with the exact error text", () => {
    const result = KnockAskInput.safeParse({
      ...validQuestion,
      recommendation_why: "a".repeat(301),
    });
    expect(result.success).toBe(false);
    if (!result.success) {
      const issue = result.error.issues.find((i) => i.path.join(".") === "recommendation_why");
      expect(issue?.message).toBe(
        "recommendation_why is 301 characters; the maximum is 300. Keep recommendation_why to 1 to " +
          "3 sentences and put the details in an artifact: markdown for reasoning, html_bundle for " +
          "a prototype, chart or plan.",
      );
    }
  });

  test("counts recommendation_why's length after trimming", () => {
    const result = KnockAskInput.safeParse({
      ...validQuestion,
      recommendation_why: `  ${"a".repeat(300)}  `,
    });
    expect(result.success).toBe(true);
  });
});

// HAIL-40: a screenshots artifact is 2 to 12 images the operator flips
// through, each with an optional caption.
describe("screenshots artifact", () => {
  test("parses 2 items with no captions", () => {
    const result = Artifact.safeParse({ type: "screenshots", items: screenshotItems(2) });
    expect(result.success).toBe(true);
  });

  test("parses 12 items, some with captions", () => {
    const items = screenshotItems(12).map((item, i) =>
      i % 2 === 0 ? { ...item, caption: `Screen ${i + 1}` } : item,
    );
    const result = Artifact.safeParse({ type: "screenshots", items });
    expect(result.success).toBe(true);
  });

  test("trims `item` and rejects an empty or a 41-character one", () => {
    const parse = (item: string) =>
      Artifact.safeParse({ type: "screenshots", items: screenshotItems(2).map((s) => ({ ...s, item })) });
    const ok = parse("  ring  ");
    expect(ok.success).toBe(true);
    if (ok.success && ok.data.type === "screenshots") expect(ok.data.items[0]!.item).toBe("ring");
    expect(parse("   ").success).toBe(false);
    expect(parse("x".repeat(40)).success).toBe(true);
    expect(parse("x".repeat(41)).success).toBe(false);
  });

  test("rejects 1 item", () => {
    expect(Artifact.safeParse({ type: "screenshots", items: screenshotItems(1) }).success).toBe(false);
  });

  test("rejects 13 items", () => {
    expect(Artifact.safeParse({ type: "screenshots", items: screenshotItems(13) }).success).toBe(false);
  });

  test("rejects an empty items list", () => {
    expect(Artifact.safeParse({ type: "screenshots", items: [] }).success).toBe(false);
  });

  test("a review with a screenshots artifact satisfies waggle_ask's artifact requirement", () => {
    const result = KnockAskInput.safeParse({
      kind: "review",
      title: "Onboarding flow",
      need: "Review the 3-screen onboarding flow",
      why: "It needs a human eye",
      recommendation: "ship it",
      recommendation_why: "It reads cleanly end to end",
      artifact: { type: "screenshots", items: screenshotItems(3) },
    });
    expect(result.success).toBe(true);
  });
});

// HAIL-141: a diagram artifact is one .mmd (Mermaid source) or .svg file.
describe("diagram artifact", () => {
  test("parses a .mmd path", () => {
    expect(Artifact.safeParse({ type: "diagram", path: "./notes/flow.mmd" }).success).toBe(true);
  });

  test("parses a .svg path", () => {
    expect(Artifact.safeParse({ type: "diagram", path: "./notes/flow.svg" }).success).toBe(true);
  });

  test("rejects a missing path", () => {
    expect(Artifact.safeParse({ type: "diagram" }).success).toBe(false);
  });

  test("a review with a diagram artifact satisfies waggle_ask's artifact requirement", () => {
    const result = KnockAskInput.safeParse({
      kind: "review",
      title: "Review flow",
      need: "Review this pipeline",
      why: "It needs a human eye",
      recommendation: "ship it",
      recommendation_why: "It reads cleanly",
      artifact: { type: "diagram", path: "./notes/flow.mmd" },
    });
    expect(result.success).toBe(true);
  });

  test("waggle_update accepts a diagram artifact", () => {
    const result = KnockUpdateInput.safeParse({
      case_id: "c_01J",
      message: "New diagram",
      artifact: { type: "diagram", path: "./notes/flow.svg" },
    });
    expect(result.success).toBe(true);
  });
});

describe("waggle_check input", () => {
  test("parses a valid case id", () => {
    expect(KnockCheckInput.safeParse({ case_id: "c_01J" }).success).toBe(true);
  });

  test("rejects a missing case id", () => {
    expect(KnockCheckInput.safeParse({}).success).toBe(false);
  });
});

describe("waggle_update input", () => {
  test("parses a valid message", () => {
    expect(
      KnockUpdateInput.safeParse({ case_id: "c_01J", message: "More detail" }).success,
    ).toBe(true);
  });

  test("rejects a missing case id", () => {
    expect(KnockUpdateInput.safeParse({ message: "More detail" }).success).toBe(false);
  });
});

// HAIL-150: a comment has a capture and rect, or a text anchor.
describe("Comment", () => {
  const anchor = { kind: "text" as const, revision: 1, quote: "hello", start: 2, end: 7 };
  test("accepts a capture comment unchanged", () => {
    const c = { id: "c", capture_id: "cap", n: 1, rect: { x: 0, y: 0, w: 1, h: 1 }, text: "t" };
    expect(Comment.parse(c)).toEqual(c);
  });
  test("accepts a text comment without capture or rect and round-trips it", () => {
    const c = { id: "c", n: 1, anchor, text: "t" };
    expect(Comment.parse(JSON.parse(JSON.stringify(c)))).toEqual(c);
  });
  test("rejects a comment with neither, both, or a bad range", () => {
    expect(Comment.safeParse({ id: "c", n: 1, text: "t" }).success).toBe(false);
    expect(
      Comment.safeParse({ id: "c", capture_id: "x", n: 1, rect: { x: 0, y: 0, w: 1, h: 1 }, anchor, text: "t" }).success,
    ).toBe(false);
    expect(Comment.safeParse({ id: "c", n: 1, anchor: { ...anchor, end: 2 }, text: "t" }).success).toBe(false);
  });
});
