// Checks src/git.ts against a real `git receive-pack` (dev check, needs git and bun; the Worker needs neither).
//   bun scripts/verify-git-push.ts
import { execFileSync, spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pushFiles } from "../src/git";

const bare = mkdtempSync(join(tmpdir(), "waggle-bare-"));
execFileSync("git", ["init", "--quiet", "--bare", "-b", "main", bare]);
const TOKEN = "art_v1_test";

function rpc(args: string[], input?: Uint8Array): Promise<Uint8Array> {
  return new Promise((resolve, reject) => {
    const p = spawn("git", ["receive-pack", ...args, bare]);
    const out: Buffer[] = [];
    p.stdout.on("data", (d) => out.push(d));
    p.on("close", () => resolve(new Uint8Array(Buffer.concat(out))));
    p.on("error", reject);
    p.stdin.end(input ? Buffer.from(input) : undefined);
  });
}

const server = Bun.serve({
  port: 0,
  hostname: "127.0.0.1",
  async fetch(req) {
    if (req.headers.get("authorization") !== `Bearer ${TOKEN}`) return new Response("no", { status: 401 });
    const url = new URL(req.url);
    if (url.pathname.endsWith("/info/refs")) {
      const adv = await rpc(["--stateless-rpc", "--advertise-refs"]);
      const head = new TextEncoder().encode("001f# service=git-receive-pack\n0000");
      return new Response(Buffer.concat([head, adv]));
    }
    return new Response(await rpc(["--stateless-rpc"], new Uint8Array(await req.arrayBuffer())));
  },
});

const remote = `http://127.0.0.1:${server.port}/git/waggle/repo.git`;
const files = (n: number) => [
  { path: "index.html", bytes: new TextEncoder().encode(`<h1>Round ${n}</h1>`) },
  { path: "css/style.css", bytes: new TextEncoder().encode("h1{color:red}") },
  { path: "css/a/deep.txt", bytes: new TextEncoder().encode("deep") },
  { path: "css.txt", bytes: new TextEncoder().encode("sorts after the css folder? no: before") },
  { path: "dup1.txt", bytes: new TextEncoder().encode("same") },
  { path: "dup2.txt", bytes: new TextEncoder().encode("same") },
  { path: "big.bin", bytes: crypto.getRandomValues(new Uint8Array(200_000)) },
];
const git = (...a: string[]) => execFileSync("git", ["-C", bare, ...a]).toString().trim();

const c1 = await pushFiles({ remote, token: TOKEN, branch: "main", files: files(1), message: "Round 1" });
const c2 = await pushFiles({ remote, token: TOKEN, branch: "main", files: files(2), message: "Round 2" });
const c3 = await pushFiles({ remote, token: TOKEN, branch: "side", files: files(3), message: "Round 3 side" });
git("fsck", "--strict", "--no-dangling");
if (git("rev-parse", "main") !== c2) throw new Error("main tip is not the second commit");
if (git("rev-parse", "main~1") !== c1) throw new Error("second commit has no parent");
if (git("rev-parse", "side") !== c3) throw new Error("side branch missing");
if (git("show", "main:index.html") !== "<h1>Round 2</h1>") throw new Error("content differs");
if (git("show", "main:css/a/deep.txt") !== "deep") throw new Error("nested file differs");
console.log(git("ls-tree", "-r", "--name-only", "main"));
console.log(`OK fsck --strict clean, 3 commits (${c1.slice(0, 7)} ${c2.slice(0, 7)} ${c3.slice(0, 7)})`);
server.stop(true);
rmSync(bare, { recursive: true, force: true });
