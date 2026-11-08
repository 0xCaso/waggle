import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir, userInfo } from "node:os";
import { join } from "node:path";
import {
  launchAgentPath,
  PRE_RENAME_LABEL,
  removeLegacyLaunchAgent,
  SERVICE_LABEL,
} from "../src/service";
import { rmrf } from "./helpers";

const BOOTOUT_TARGET = `gui/${userInfo().uid}/${SERVICE_LABEL}`;
const PRE_RENAME_BOOTOUT_TARGET = `gui/${userInfo().uid}/${PRE_RENAME_LABEL}`;

// Legacy LaunchAgent cleanup (KNOCK-18). The pilot no longer installs a
// LaunchAgent; service.ts only removes one an older build left behind. The
// runner is injected so these tests never touch the real launchctl.

const homes: string[] = [];

afterEach(() => {
  for (const home of homes.splice(0)) rmrf(home);
});

function newHome(): string {
  const home = mkdtempSync(join(tmpdir(), "knock-service-"));
  homes.push(home);
  return home;
}

describe("launchAgentPath", () => {
  test("points at the per-user LaunchAgents dir for the label", () => {
    expect(launchAgentPath("/tmp/home")).toBe(
      join("/tmp/home", "Library", "LaunchAgents", `${SERVICE_LABEL}.plist`),
    );
  });
});

describe("removeLegacyLaunchAgent", () => {
  test("boots the label out and deletes the plist when one exists", () => {
    const home = newHome();
    const plistDir = join(home, "Library", "LaunchAgents");
    mkdirSync(plistDir, { recursive: true });
    writeFileSync(join(plistDir, `${SERVICE_LABEL}.plist`), "<plist/>");

    const calls: string[][] = [];
    const removed = removeLegacyLaunchAgent(
      (args) => {
        calls.push(args);
        return { status: 0, stdout: "", stderr: "" };
      },
      home,
    );

    expect(removed).toEqual([SERVICE_LABEL]);
    expect(calls).toEqual([["bootout", BOOTOUT_TARGET]]);
    expect(existsSync(join(plistDir, `${SERVICE_LABEL}.plist`))).toBe(false);
  });

  test("deletes the plist even when bootout is refused", () => {
    const home = newHome();
    const plistDir = join(home, "Library", "LaunchAgents");
    mkdirSync(plistDir, { recursive: true });
    writeFileSync(join(plistDir, `${SERVICE_LABEL}.plist`), "<plist/>");

    const removed = removeLegacyLaunchAgent(
      () => {
        throw new Error("refusing to run launchctl");
      },
      home,
    );

    expect(removed).toEqual([SERVICE_LABEL]);
    expect(existsSync(join(plistDir, `${SERVICE_LABEL}.plist`))).toBe(false);
  });

  test("removes the pre-rename label too", () => {
    const home = newHome();
    const plistDir = join(home, "Library", "LaunchAgents");
    mkdirSync(plistDir, { recursive: true });
    writeFileSync(join(plistDir, `${PRE_RENAME_LABEL}.plist`), "<plist/>");

    const calls: string[][] = [];
    const removed = removeLegacyLaunchAgent(
      (args) => {
        calls.push(args);
        return { status: 0, stdout: "", stderr: "" };
      },
      home,
    );

    expect(removed).toEqual([PRE_RENAME_LABEL]);
    expect(calls).toEqual([["bootout", PRE_RENAME_BOOTOUT_TARGET]]);
    expect(existsSync(join(plistDir, `${PRE_RENAME_LABEL}.plist`))).toBe(false);
  });

  test("removes both labels when both plists are present", () => {
    const home = newHome();
    const plistDir = join(home, "Library", "LaunchAgents");
    mkdirSync(plistDir, { recursive: true });
    writeFileSync(join(plistDir, `${SERVICE_LABEL}.plist`), "<plist/>");
    writeFileSync(join(plistDir, `${PRE_RENAME_LABEL}.plist`), "<plist/>");

    const calls: string[][] = [];
    const removed = removeLegacyLaunchAgent(
      (args) => {
        calls.push(args);
        return { status: 0, stdout: "", stderr: "" };
      },
      home,
    );

    expect(removed).toEqual([SERVICE_LABEL, PRE_RENAME_LABEL]);
    expect(calls).toEqual([["bootout", BOOTOUT_TARGET], ["bootout", PRE_RENAME_BOOTOUT_TARGET]]);
    expect(existsSync(join(plistDir, `${SERVICE_LABEL}.plist`))).toBe(false);
    expect(existsSync(join(plistDir, `${PRE_RENAME_LABEL}.plist`))).toBe(false);
  });

  test("returns an empty list when no plist is present", () => {
    const home = newHome();
    const calls: string[][] = [];
    const removed = removeLegacyLaunchAgent(
      (args) => {
        calls.push(args);
        return { status: 0, stdout: "", stderr: "" };
      },
      home,
    );
    expect(removed).toEqual([]);
    expect(calls).toHaveLength(0);
  });
});
