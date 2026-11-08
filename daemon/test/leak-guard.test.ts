import { describe, expect, test } from "bun:test";
import { leakedTestDaemons } from "./helpers";

// Global leak guard (KNOCK-18). Every test that can start a daemon stops it in
// its own afterEach (stopDaemonByHome). This file is the backstop: it fails
// when any `waggle daemon` a test started on demand is still alive under the test
// temp root. Bun runs test files serially, so at this file's turn every earlier
// file has already cleaned up and every later file has not started yet.
describe("waggle daemon leak guard", () => {
  test("no waggle daemon is left running under the test temp root", () => {
    const leaked = leakedTestDaemons();
    expect(
      leaked.map((d) => `pid ${d.pid} (KNOCK_HOME=${d.home})`),
    ).toEqual([]);
  });
});
