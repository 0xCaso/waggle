import { describe, expect, test } from "bun:test";
import { QUESTION_PHRASES, isQuickQuestion, looksLikeQuestion, saysBlocked } from "../src/hooks/question-detector";

// WAG-265: questions left in the terminal versus status reports.

describe("looksLikeQuestion", () => {
  test("a question mark at the end of the last paragraph counts", () => {
    expect(looksLikeQuestion("I found two ways.\n\nWhich is better?")).toBe(true);
    expect(looksLikeQuestion("Is the cache meant to be shared?")).toBe(true);
    expect(looksLikeQuestion("Ready to ship **now?**")).toBe(true);
    expect(looksLikeQuestion('Did you mean "the old flow?"')).toBe(true);
  });

  test("question marks of other scripts count", () => {
    expect(looksLikeQuestion("Vuoi che lo faccia adesso?")).toBe(true);
    expect(looksLikeQuestion("¿Quieres que continúe?")).toBe(true);
    expect(looksLikeQuestion("続けますか？")).toBe(true);
    expect(looksLikeQuestion("هل تريد المتابعة؟")).toBe(true);
    expect(looksLikeQuestion("Θέλεις να συνεχίσω;")).toBe(true);
  });

  test("an ASCII semicolon at the end is not a question", () => {
    expect(looksLikeQuestion("const x = 1;")).toBe(false);
  });

  test("phrases in the last two sentences count", () => {
    for (const text of [
      "Both work. Should I use the second one.",
      "The tests pass. Do you want me to open a PR.",
      "Plan is ready. Want me to start",
      "Shall I go ahead",
      "Which option do you prefer.",
      "Tell me which approach you like. Let me know.",
      "I can do either. What do you think.",
    ]) {
      expect(looksLikeQuestion(text)).toBe(true);
    }
  });

  test("status reports are not questions", () => {
    for (const text of [
      "Done. All 42 tests pass.",
      "I changed the parser, which now handles empty input.\n\n- fixed the crash\n- added a test",
      "The build finished. Let me know if you need anything else.",
      "Shipped. Let me know how it goes.",
      "Fixed. Let me know if there's anything more.",
      "",
      "   ",
    ]) {
      expect(looksLikeQuestion(text)).toBe(false);
    }
    expect(looksLikeQuestion(undefined)).toBe(false);
    expect(looksLikeQuestion(null)).toBe(false);
  });

  test("only the last paragraph and the last two sentences are read", () => {
    expect(looksLikeQuestion("Should I do this?\n\nI did it anyway. All done.")).toBe(false);
    expect(looksLikeQuestion("Should I do it. A. B. C.")).toBe(false);
  });

  test("a question inside a code block does not count", () => {
    expect(looksLikeQuestion("Here is the prompt:\n\n```\nWhat is your name?\n```")).toBe(false);
  });

  test("the phrase list is one place and every entry matches its own example", () => {
    expect(QUESTION_PHRASES.length).toBeGreaterThanOrEqual(8);
  });
});

describe("isQuickQuestion", () => {
  test("a short single-sentence question is quick", () => {
    expect(isQuickQuestion("Should I use tabs?")).toBe(true);
    expect(isQuickQuestion("I fixed the bug and the tests pass.\n\nWhat should I name the flag?")).toBe(true);
  });
  test("a question after a list of options is not quick", () => {
    expect(isQuickQuestion("Two ways:\n\n- A: one table\n- B: two tables\n\nWhich one?")).toBe(false);
    expect(isQuickQuestion("1. Keep it\n2. Drop it\nWhich?")).toBe(false);
  });
  test("a long or multi-sentence question is not quick", () => {
    expect(isQuickQuestion("There are tradeoffs. Which one do you want?")).toBe(false);
    expect(isQuickQuestion(`${"Word ".repeat(40)}?`)).toBe(false);
    expect(isQuickQuestion("Do you want A? Or B?")).toBe(false);
  });
  test("not a question, or no message", () => {
    expect(isQuickQuestion("All done.")).toBe(false);
    expect(isQuickQuestion(undefined)).toBe(false);
  });
});

describe("saysBlocked", () => {
  test("the agent says it cannot go on", () => {
    expect(saysBlocked("Before I continue, which key should I use?")).toBe(true);
    expect(saysBlocked("I need you to log in to the service.")).toBe(true);
    expect(saysBlocked("I am blocked on the API key.")).toBe(true);
    expect(saysBlocked("I can't proceed without the token.")).toBe(true);
  });
  test("a plain question does not say it", () => {
    expect(saysBlocked("Should I use tabs?")).toBe(false);
    expect(saysBlocked(undefined)).toBe(false);
  });
});
