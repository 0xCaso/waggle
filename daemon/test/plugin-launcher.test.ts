import { afterEach, describe, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { rmrf } from "./helpers";

// HAIL-134: the plugin's launcher finds the installed Waggle without a path to one
// user's Mac, and the plugin files agree with each other. Fake binaries only.

const ROOT = join(import.meta.dir, "..", "..");
const PLUGIN = join(ROOT, "plugins", "claude-code", "waggle");
const LAUNCHER = join(PLUGIN, "bin", "waggle-launcher");

const dirs: string[] = [];
afterEach(() => {
  for (const d of dirs.splice(0)) rmrf(d);
});

function home(): string {
  const d = mkdtempSync(join(tmpdir(), "knock-launch-"));
  dirs.push(d);
  return d;
}

function fakeKnock(path: string, label: string): void {
  mkdirSync(join(path, ".."), { recursive: true });
  writeFileSync(path, `#!/bin/sh\necho "${label}: $KNOCK_RUNTIME $@"\n`);
  chmodSync(path, 0o755);
}

async function launch(env: Record<string, string>, ...args: string[]) {
  // A clean environment: no inherited KNOCK_BIN, and HOME is the temp dir.
  const proc = Bun.spawn([LAUNCHER, ...args], {
    env: { PATH: "/usr/bin:/bin", ...env },
    stdout: "pipe",
    stderr: "pipe",
    stdin: "ignore",
  });
  const code = await proc.exited;
  return { code, out: await new Response(proc.stdout).text(), err: await new Response(proc.stderr).text() };
}

describe("waggle-launcher", () => {
  test("finds ~/Applications/Waggle.app and passes the arguments and the environment", async () => {
    const h = home();
    fakeKnock(join(h, "Applications", "Waggle.app", "Contents", "Resources", "waggle"), "user-app");
    const r = await launch({ HOME: h, KNOCK_RUNTIME: "claude" }, "mcp");
    expect(r.code).toBe(0);
    expect(r.out).toBe("user-app: claude mcp\n");
  });

  test("falls back to ~/.local/bin/knock", async () => {
    const h = home();
    fakeKnock(join(h, ".local", "bin", "waggle"), "local-bin");
    const r = await launch({ HOME: h }, "mod", "poll", "--session", "s");
    expect(r.out).toBe("local-bin:  mod poll --session s\n");
  });

  test("runs the knock of the SAME bundle first, before any installed app", async () => {
    const h = home();
    const resources = join(h, "Downloads", "Waggle.app", "Contents", "Resources");
    fakeKnock(join(resources, "waggle"), "same-bundle");
    fakeKnock(join(h, "Applications", "Waggle.app", "Contents", "Resources", "waggle"), "user-app");
    mkdirSync(join(resources, "claude-plugin"), { recursive: true });
    require("node:child_process").execFileSync("cp", ["-R", PLUGIN, join(resources, "claude-plugin", "waggle")]);
    const r = await launch({ HOME: h, KNOCK_RUNTIME: "claude" }, "mcp");
    // Run through the copy's own launcher, so "here" is inside the bundle.
    const copy = Bun.spawn([join(resources, "claude-plugin", "waggle", "bin", "waggle-launcher"), "mcp"], {
      env: { PATH: "/usr/bin:/bin", HOME: h, KNOCK_RUNTIME: "claude" },
      stdout: "pipe",
      stdin: "ignore",
    });
    await copy.exited;
    expect(await new Response(copy.stdout).text()).toBe("same-bundle: claude mcp\n");
    // The repo copy is not inside a bundle, so it still finds the installed app.
    expect(r.out).toBe("user-app: claude mcp\n");
  });

  test("a cached copy uses the path waggle install recorded in the data root", async () => {
    const h = home();
    const dataRoot = join(h, "data");
    mkdirSync(dataRoot);
    fakeKnock(join(h, "Elsewhere", "Waggle.app", "Contents", "Resources", "waggle"), "recorded");
    fakeKnock(join(h, "Applications", "Waggle.app", "Contents", "Resources", "waggle"), "user-app");
    writeFileSync(join(dataRoot, "knock-path"), join(h, "Elsewhere", "Waggle.app", "Contents", "Resources", "waggle") + "\n");
    const r = await launch({ HOME: h, KNOCK_HOME: dataRoot }, "mcp");
    expect(r.out).toBe("recorded:  mcp\n");
    // A recorded path that no longer exists falls through to the usual search.
    writeFileSync(join(dataRoot, "knock-path"), join(h, "gone", "knock") + "\n");
    expect((await launch({ HOME: h, KNOCK_HOME: dataRoot }, "mcp")).out).toBe("user-app:  mcp\n");
  });

  test("KNOCK_BIN wins", async () => {
    const h = home();
    fakeKnock(join(h, "Applications", "Waggle.app", "Contents", "Resources", "waggle"), "user-app");
    fakeKnock(join(h, "dev-knock"), "dev");
    const r = await launch({ HOME: h, KNOCK_BIN: join(h, "dev-knock") }, "mcp");
    expect(r.out).toBe("dev:  mcp\n");
  });

  test("Waggle not installed: a clear error on stderr and exit 127, nothing on stdout", async () => {
    const h = home();
    const r = await launch({ HOME: h }, "mcp");
    expect(r.code).toBe(127);
    expect(r.out).toBe("");
    expect(r.err).toContain("Waggle is not installed");
  });

  test("holds no hard-coded user path", () => {
    const text = readFileSync(LAUNCHER, "utf8");
    expect(text).not.toMatch(/\/Users\//);
  });
});

describe("the plugin files", () => {
  const json = (p: string) => JSON.parse(readFileSync(p, "utf8"));

  test("the MCP server runs the launcher with the Claude runtime label", () => {
    const mcp = json(join(PLUGIN, ".mcp.json"));
    expect(mcp.mcpServers.waggle).toEqual({
      command: "${CLAUDE_PLUGIN_ROOT}/bin/waggle-launcher",
      args: ["mcp"],
      env: { KNOCK_RUNTIME: "claude" },
    });
  });

  test("the launcher is executable", () => {
    expect((Bun.file(LAUNCHER).size ?? 0) > 0).toBe(true);
    expect(require("node:fs").statSync(LAUNCHER).mode & 0o111).not.toBe(0);
  });

  test("the marketplace lists the plugin at a path that exists, under the name the plugin has", () => {
    const market = json(join(ROOT, ".claude-plugin", "marketplace.json"));
    const entry = market.plugins[0];
    expect(market.name).toBe("waggle");
    expect(entry.name).toBe(json(join(PLUGIN, ".claude-plugin", "plugin.json")).name);
    expect(existsSync(join(ROOT, entry.source, ".claude-plugin", "plugin.json"))).toBe(true);
    expect(entry.version).toBe(json(join(PLUGIN, ".claude-plugin", "plugin.json")).version);
  });

  test("the bundled marketplace (shipped in Waggle.app) lists ./waggle under the plugin's name", () => {
    const market = json(join(ROOT, "plugins", "claude-code", "bundle", "marketplace.json"));
    expect(market.name).toBe("waggle");
    expect(market.plugins[0].source).toBe("./waggle");
    expect(market.plugins[0].name).toBe(json(join(PLUGIN, ".claude-plugin", "plugin.json")).name);
    // bundle-app.sh copies the marketplace and the plugin into Contents/Resources/claude-plugin.
    const script = readFileSync(join(ROOT, "scripts", "bundle-app.sh"), "utf8");
    expect(script).toContain("Contents/Resources/claude-plugin");
    expect(script).toContain("plugins/claude-code");
  });

  test("the mod module and the skill exist", () => {
    expect(json(join(PLUGIN, "hooks", "hooks.json")).modules).toEqual(["./register.tsx"]);
    expect(existsSync(join(PLUGIN, "hooks", "register.tsx"))).toBe(true);
    expect(readFileSync(join(PLUGIN, "skills", "waggle", "SKILL.md"), "utf8")).toContain("waggle_ask");
  });

  test("the mod sends no prompt text and makes no network call", () => {
    const mod = readFileSync(join(PLUGIN, "hooks", "register.tsx"), "utf8").replace(/\/\/.*$/gm, "");
    expect(mod).not.toMatch(/\be\.text\b/);
    expect(mod).not.toMatch(/\$\.http|fetch\(/);
  });
});
