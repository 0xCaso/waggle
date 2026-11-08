import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { main } from "../src/cli";
import { TEST_CASE } from "../src/cli/test-ask";
import { TEST_FIXTURE } from "../src/cli/test-ask-fixture";
import { KnockAskInput } from "../src/protocol";

// Dispatch and pure-helper tests only. The side-effectful subcommands
// (install, doctor, test-ask, uninstall) are exercised in cli-install.test.ts
// through a spawned binary with HOME, KNOCK_HOME and PATH pointed at temp dirs,
// so nothing here touches real user settings.

describe("knock CLI dispatch", () => {
  test("--version exits 0", async () => {
    expect(await main(["--version"])).toBe(0);
  });

  test("an unknown command exits 2", async () => {
    expect(await main(["bogus"])).toBe(2);
  });

  test("no arguments exits 2", async () => {
    expect(await main([])).toBe(2);
  });

  test("install rejects an unrecognized runtime name", async () => {
    expect(await main(["install", "bogus"])).toBe(2);
  });

  test("uninstall rejects an unknown argument without side effects", async () => {
    expect(await main(["uninstall", "--bogus"])).toBe(2);
  });
});

describe("test-ask fixture", () => {
  test("the embedded fixture matches daemon/test/fixtures/pricing-card", () => {
    const dir = join(import.meta.dir, "fixtures", "pricing-card");
    for (const name of Object.keys(TEST_FIXTURE) as (keyof typeof TEST_FIXTURE)[]) {
      expect(TEST_FIXTURE[name]).toBe(readFileSync(join(dir, name), "utf8"));
    }
  });
});

describe("test-ask sample (WAG-338)", () => {
  const artifact = { type: "html_bundle", dir: "./proto", entry: "index.html" };

  test("is an ask in the three blocks shape: need, why, items with a recommendation, an artifact", () => {
    const parsed = KnockAskInput.parse({ ...TEST_CASE, artifact });
    expect(parsed.need.length).toBeGreaterThan(0);
    expect(parsed.why.length).toBeGreaterThan(0);
    expect(parsed.items).toHaveLength(1);
    const item = parsed.items![0];
    expect(item.select).toBe("one");
    expect(item.options!.length).toBeGreaterThanOrEqual(2);
    expect(item.options!.map((o) => o.id)).toContain(item.recommendation as string);
    expect(item.recommendation_why!.length).toBeGreaterThan(0);
    expect(parsed.artifact).toBeDefined();
  });

  test("uses no old shortcut: no kind, no top-level options or recommendation", () => {
    const sample = TEST_CASE as Record<string, unknown>;
    for (const key of ["kind", "options", "recommendation", "recommendation_why", "questions"]) {
      expect(key in sample).toBe(false);
    }
  });

  test("gives each option a short title and no A or B prefix in its label", () => {
    for (const option of TEST_CASE.items[0].options) {
      expect(option.title.split(" ").length).toBeLessThanOrEqual(6);
      expect(option.label).not.toMatch(/^[A-Z] ·|^\d\./);
    }
  });
});
