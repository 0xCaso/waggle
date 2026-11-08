import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DESIGN_KIT_MAX_BYTES, readDesignKit, withDesignKit } from "../src/guide/design-kit";
import { getGuide, guideTopics } from "../src/guide";

const dirs: string[] = [];
function project(kit?: string): string {
  const dir = mkdtempSync(join(tmpdir(), "knock-kit-"));
  dirs.push(dir);
  if (kit !== undefined) {
    mkdirSync(join(dir, ".knock"));
    writeFileSync(join(dir, ".knock", "design-kit.md"), kit);
  }
  return dir;
}
afterEach(() => {
  for (const d of dirs.splice(0)) rmSync(d, { recursive: true, force: true });
});

describe("design kit (SYL-2)", () => {
  test("no file: no kit, and the text passes through unchanged", () => {
    const dir = project();
    expect(readDesignKit(dir, dir)).toBeNull();
    expect(withDesignKit("artifacts", "TEXT", null)).toBe("TEXT");
    expect(withDesignKit(undefined, "INDEX", null)).toBe("INDEX");
  });

  test("an empty file counts as no kit", () => {
    const dir = project("  \n");
    expect(readDesignKit(dir, null)).toBeNull();
  });

  test("the git root wins, the cwd is the fallback, and the size is capped", () => {
    const root = project("root kit");
    const sub = join(root, "pkg");
    mkdirSync(sub);
    expect(readDesignKit(sub, root)).toBe("root kit");
    const solo = project("x".repeat(DESIGN_KIT_MAX_BYTES + 100));
    expect(readDesignKit(solo, null)?.length).toBe(DESIGN_KIT_MAX_BYTES);
  });

  test("the kit goes on the artifacts topic and the index only", () => {
    const out = withDesignKit("artifacts", "TEXT", "## Pen file\nd.pen");
    expect(out).toContain("design in the Pen file".replace("design", "Design"));
    expect(out).toContain("d.pen");
    expect(withDesignKit("reviews", "TEXT", "k")).toBe("TEXT");
    expect(withDesignKit(undefined, "INDEX", "k")).toContain(".knock/design-kit.md");
  });

  test("the starter prompts topic exists and names Pen, with no em-dash", () => {
    expect(guideTopics()).toContain("starter-prompts");
    const text = getGuide("starter-prompts");
    for (const phrase of ["Waggle a research question", "Variants of a deck in Pen", "From idea to prototype in Pen"]) {
      expect(text).toContain(phrase);
    }
    expect(text).not.toContain("—");
    expect(getGuide("design-kit")).not.toContain("—");
  });
});
