import { afterEach, describe, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { rmrf, tmpHome } from "./helpers";

// HAIL-239: `waggle design-helpers` adds and removes the optional Impeccable plugin. `claude` is a
// stateful fake on PATH, HOME is a temp folder: nothing here calls a real Claude Code or the network.

const ENTRY = join(import.meta.dir, "..", "src", "index.ts");

const CLAUDE_SH = `#!/bin/sh
printf 'claude %s\\n' "$*" >> "$CLAUDE_LOG"
S="$CLAUDE_STATE"
[ "$1" = "plugin" ] || exit 0
case "$2" in
  --help) echo "Manage Claude Code plugins" ;;
  marketplace)
    case "$3" in
      list) if [ -f "$S/market" ]; then echo '[{"name":"impeccable","source":"github"}]'; else echo "[]"; fi ;;
      add) if [ -n "$CLAUDE_FAIL_ADD" ]; then echo "network down" >&2; exit 1; fi; touch "$S/market" ;;
      remove) rm -f "$S/market" "$S/plugin" ;;
    esac ;;
  list) if [ -f "$S/plugin" ]; then echo '[{"id":"impeccable@impeccable","version":"4.5.0","enabled":true},{"id":"waggle@waggle","enabled":true}]'; else echo '[{"id":"waggle@waggle","enabled":true}]'; fi ;;
  install) touch "$S/plugin" ;;
  uninstall) rm -f "$S/plugin" ;;
esac
exit 0
`;

const dirs: string[] = [];
afterEach(() => {
  for (const d of dirs.splice(0)) rmrf(d);
});

function setup() {
  const dir = mkdtempSync(join(tmpdir(), "knock-dh-"));
  dirs.push(dir);
  const state = join(dir, "state");
  mkdirSync(state);
  writeFileSync(join(dir, "claude"), CLAUDE_SH);
  chmodSync(join(dir, "claude"), 0o755);
  const home = tmpHome();
  dirs.push(home);
  const env = (extra: Record<string, string> = {}) => ({
    ...process.env,
    HOME: home,
    KNOCK_HOME: home,
    PATH: `${dir}:/usr/bin:/bin`,
    CLAUDE_LOG: join(dir, "claude.log"),
    CLAUDE_STATE: state,
    ...extra,
  });
  const log = () => (existsSync(join(dir, "claude.log")) ? readFileSync(join(dir, "claude.log"), "utf8") : "");
  return { state, env, log };
}

async function waggle(args: string[], env: Record<string, string>) {
  const proc = Bun.spawn([process.execPath, ENTRY, ...args], { env, stdout: "pipe", stderr: "pipe", stdin: "ignore" });
  const code = await proc.exited;
  return { code, stdout: await new Response(proc.stdout).text(), stderr: await new Response(proc.stderr).text() };
}

describe("waggle design-helpers", () => {
  test("status says not installed, and installs nothing", async () => {
    const s = setup();
    const r = await waggle(["design-helpers", "status"], s.env());
    expect(r.code).toBe(0);
    expect(r.stdout).toBe("not installed\n");
    expect(s.log()).not.toContain("marketplace add");
    expect(s.log()).not.toContain("plugin install");
  });

  test("add adds the marketplace pbakaus/impeccable and installs the plugin at user scope", async () => {
    const s = setup();
    const r = await waggle(["design-helpers", "add"], s.env());
    expect(r.code).toBe(0);
    expect(s.log()).toContain("plugin marketplace add pbakaus/impeccable --scope user");
    expect(s.log()).toContain("plugin install impeccable@impeccable --scope user");
    expect((await waggle(["design-helpers", "status"], s.env())).stdout).toBe("installed\n");
  });

  test("add twice changes nothing the second time", async () => {
    const s = setup();
    await waggle(["design-helpers", "add"], s.env());
    const before = s.log();
    const r = await waggle(["design-helpers", "add"], s.env());
    expect(r.code).toBe(0);
    expect(r.stdout).toContain("already installed");
    expect(s.log().slice(before.length)).not.toContain("plugin install");
  });

  test("a failed marketplace add exits 1 with the reason and installs nothing", async () => {
    const s = setup();
    const r = await waggle(["design-helpers", "add"], s.env({ CLAUDE_FAIL_ADD: "1" }));
    expect(r.code).toBe(1);
    expect(r.stderr).toContain("network down");
    expect(s.log()).not.toContain("plugin install");
  });

  test("remove uninstalls the plugin and its marketplace, and leaves the Waggle plugin alone", async () => {
    const s = setup();
    await waggle(["design-helpers", "add"], s.env());
    const r = await waggle(["design-helpers", "remove"], s.env());
    expect(r.code).toBe(0);
    expect(s.log()).toContain("plugin uninstall impeccable@impeccable --scope user");
    expect(s.log()).toContain("plugin marketplace remove impeccable");
    expect(s.log()).not.toContain("waggle@waggle");
    expect((await waggle(["design-helpers", "status"], s.env())).stdout).toBe("not installed\n");
  });

  test("an unknown verb exits 2 without calling claude", async () => {
    const s = setup();
    const r = await waggle(["design-helpers", "install"], s.env());
    expect(r.code).toBe(2);
    expect(s.log()).toBe("");
  });
});
