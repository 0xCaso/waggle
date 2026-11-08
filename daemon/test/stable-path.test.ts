import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { daemonCommand } from "../src/on-demand";
import { rmrf } from "./helpers";

// HAIL-27: the on-demand start command must prefer the stable install path so
// a shim or CLI that survived an update never respawns the binary Sparkle moved
// aside. These tests drive daemonCommand with a fake HOME and a fake execPath.

const homes: string[] = [];

afterEach(() => {
  for (const home of homes.splice(0)) rmrf(home);
});

function tempHome(): string {
  const home = mkdtempSync(join(tmpdir(), "knock-path-"));
  homes.push(home);
  return home;
}

function appKnockPath(home: string): string {
  return join(home, "Applications", "Waggle.app", "Contents", "Resources", "waggle");
}

function localBinKnockPath(home: string): string {
  return join(home, ".local", "bin", "waggle");
}

function sparkleCacheKnockPath(home: string): string {
  return join(
    home,
    "Library",
    "Caches",
    "dev.limone.knock",
    "org.sparkle-project.Sparkle",
    "Installation",
    "x",
    "Waggle.app",
    "Contents",
    "Resources",
    "knock",
  );
}

function writeFile(path: string): void {
  mkdirSync(join(path, ".."), { recursive: true });
  writeFileSync(path, "#!/bin/sh\n");
}

describe("daemonCommand stable spawn path", () => {
  test("prefers the app bundle binary", () => {
    const home = tempHome();
    writeFile(appKnockPath(home));

    const { bin, args } = daemonCommand({ HOME: home }, sparkleCacheKnockPath(home));

    expect(bin).toBe(appKnockPath(home));
    expect(args).toEqual(["daemon"]);
  });

  test("falls back to the ~/.local/bin symlink when the app is not installed", () => {
    const home = tempHome();
    writeFile(localBinKnockPath(home));

    const { bin, args } = daemonCommand({ HOME: home }, sparkleCacheKnockPath(home));

    expect(bin).toBe(localBinKnockPath(home));
    expect(args).toEqual(["daemon"]);
  });

  test("rejects a Sparkle cache execPath when a stable path exists", () => {
    const home = tempHome();
    writeFile(appKnockPath(home));
    writeFile(sparkleCacheKnockPath(home));

    const { bin } = daemonCommand({ HOME: home }, sparkleCacheKnockPath(home));

    expect(bin).toBe(appKnockPath(home));
    expect(bin).not.toContain("org.sparkle-project.Sparkle");
    expect(bin).not.toContain("Library/Caches");
  });

  test("uses execPath only when neither standard location exists", () => {
    const home = tempHome();

    const { bin, args } = daemonCommand({ HOME: home }, "/opt/homebrew/bin/bun");

    expect(bin).toBe("/opt/homebrew/bin/bun");
    expect(args).toContain("daemon");
  });
});

describe("daemonCommand in a test or dev copy", () => {
  test("a custom KNOCK_HOME never resolves the installed app binary", () => {
    const home = tempHome();
    writeFile(appKnockPath(home));
    const own = join(home, "build", "Waggle.app", "Contents", "Resources", "waggle");

    const { bin } = daemonCommand({ HOME: home, KNOCK_HOME: join(home, "k") }, own);

    expect(bin).toBe(own);
  });

  test("KNOCK_STABLE_BIN wins over everything", () => {
    const home = tempHome();
    writeFile(appKnockPath(home));
    const pinned = join(home, "pinned", "knock");
    writeFile(pinned);

    const { bin } = daemonCommand({ HOME: home, KNOCK_HOME: join(home, "k"), KNOCK_STABLE_BIN: pinned }, "/x/knock");

    expect(bin).toBe(pinned);
  });
});
