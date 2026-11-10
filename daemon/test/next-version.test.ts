import { describe, expect, test } from "bun:test";
// @ts-expect-error: a plain .mjs script outside the daemon sources
import { nextVersion } from "../../scripts/lib/next-version.mjs";

describe("next-version (release on merge)", () => {
  test("a merge with no label bumps the patch", () => {
    expect(nextVersion("0.2.65")).toBe("0.2.66");
    expect(nextVersion("0.2.65", ["bug", ""])).toBe("0.2.66");
  });

  test("release:minor and release:major bump more", () => {
    expect(nextVersion("0.2.65", ["release:minor"])).toBe("0.3.0");
    expect(nextVersion("0.2.65", ["release:major"])).toBe("1.0.0");
    expect(nextVersion("0.2.65", ["release:minor", "release:major"])).toBe("1.0.0");
  });

  test("skip-release makes no release", () => {
    expect(nextVersion("0.2.65", ["release:minor", "skip-release"])).toBe("skip");
  });

  test("a bad version throws", () => {
    expect(() => nextVersion("v0.2")).toThrow();
  });
});
