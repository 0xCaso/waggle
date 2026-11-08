import { inflateSync } from "node:zlib";
import { vi } from "vitest";

// A fake Cloudflare Artifacts (WAG-391): the Workers binding and the Git smart-HTTP remote it hands
// out. The remote parses the real receive-pack request and the real pack, so a wrong pack, a wrong
// ref update or a wrong token fails here as it would on the real service.

const dec = new TextDecoder();
const ZERO = "0".repeat(40);
const hex = (b: Uint8Array) => [...b].map((x) => x.toString(16).padStart(2, "0")).join("");

async function sha1(b: Uint8Array) {
  return new Uint8Array(await crypto.subtle.digest("SHA-1", b as BufferSource));
}

type Obj = { type: number; body: Uint8Array };

export class FakeArtifacts {
  repos = new Map<string, { objects: Map<string, Obj>; refs: Map<string, string>; token: string }>();
  pushes: { repo: string; ref: string; old: string; commit: string }[] = [];
  created: string[] = [];
  // When set, git-receive-pack answers with this status.
  refuse: number | null = null;
  private n = 0;

  remoteOf(name: string) {
    return `https://fake.artifacts.test/git/waggle/${name}.git`;
  }

  // The Workers binding, as the relay uses it.
  binding() {
    const self = this;
    return {
      async create(name: string) {
        if (self.repos.has(name)) throw new Error("exists");
        self.repos.set(name, { objects: new Map(), refs: new Map(), token: `art_v1_${(++self.n).toString(16).padStart(40, "0")}` });
        self.created.push(name);
        return { name };
      },
      async delete(name: string) {
        self.repos.delete(name);
      },
      async get(name: string) {
        const repo = self.repos.get(name);
        if (!repo) throw new Error("no such repo");
        return {
          [(Symbol as unknown as { dispose: symbol }).dispose]() {},
          async info() {
            return { remote: self.remoteOf(name) };
          },
          async createToken() {
            return { plaintext: repo.token, expiresAt: new Date(Date.now() + 600_000).toISOString() };
          },
          async readCommit(id: string) {
            return repo.objects.get(id)?.type === 1 ? { id } : null;
          },
          async readFile({ ref, path }: { ref: string; path: string }) {
            const bytes = self.fileAt(name, ref, path);
            return bytes ? new Blob([bytes as unknown as ArrayBuffer], { type: "" }) : null;
          },
        };
      },
    } as unknown as Artifacts;
  }

  fileAt(name: string, commit: string, path: string): Uint8Array | null {
    const repo = this.repos.get(name)!;
    const c = repo.objects.get(commit);
    if (!c || c.type !== 1) return null;
    let id = /^tree ([0-9a-f]{40})/.exec(dec.decode(c.body))![1]!;
    const parts = path.split("/");
    for (let i = 0; i < parts.length; i++) {
      const entries = this.entries(repo.objects.get(id)!.body);
      const e = entries.find((x) => x.name === parts[i]);
      if (!e) return null;
      id = e.id;
      if (i === parts.length - 1) return repo.objects.get(id)!.body;
    }
    return null;
  }

  // Every file path in a commit's tree.
  paths(name: string, commit: string, tree?: string, prefix = ""): string[] {
    const repo = this.repos.get(name)!;
    const t = tree ?? /^tree ([0-9a-f]{40})/.exec(dec.decode(repo.objects.get(commit)!.body))![1]!;
    return this.entries(repo.objects.get(t)!.body).flatMap((e) =>
      e.mode === "40000" ? this.paths(name, commit, e.id, `${prefix}${e.name}/`) : [`${prefix}${e.name}`],
    );
  }

  parentOf(name: string, commit: string): string | null {
    return /\nparent ([0-9a-f]{40})/.exec(dec.decode(this.repos.get(name)!.objects.get(commit)!.body))?.[1] ?? null;
  }

  private entries(body: Uint8Array) {
    const out: { mode: string; name: string; id: string }[] = [];
    let at = 0;
    while (at < body.length) {
      const nul = body.indexOf(0, at);
      const [mode, name] = dec.decode(body.subarray(at, nul)).split(" ");
      out.push({ mode: mode!, name: name!, id: hex(body.subarray(nul + 1, nul + 21)) });
      at = nul + 21;
    }
    return out;
  }

  // Routes fetch() for the fake remote. Everything else goes to the real fetch.
  install() {
    const real = globalThis.fetch;
    return vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
      const req = new Request(input as RequestInfo, init);
      const url = new URL(req.url);
      if (url.host !== "fake.artifacts.test") return real(input as RequestInfo, init);
      return this.handle(req, url);
    });
  }

  private async handle(req: Request, url: URL): Promise<Response> {
    const m = url.pathname.match(/^\/git\/waggle\/(.+)\.git\/(info\/refs|git-receive-pack)$/);
    const repo = m ? this.repos.get(m[1]!) : undefined;
    if (!m || !repo) return new Response("not found", { status: 404 });
    if (req.headers.get("authorization") !== `Bearer ${repo.token}`) return new Response("no", { status: 401 });
    if (this.refuse !== null) return new Response("refused", { status: this.refuse });
    if (m[2] === "info/refs") {
      const refs = [...repo.refs].map(([r, o]) => `${o} ${r}`);
      const lines = refs.length ? refs : [`${ZERO} capabilities^{}`];
      const first = `${lines[0]}\0report-status agent=fake\n`;
      const rest = lines.slice(1).map((l) => `${l}\n`);
      const pkt = (s: string) => (s.length + 4).toString(16).padStart(4, "0") + s;
      return new Response(`${pkt("# service=git-receive-pack\n")}0000${[first, ...rest].map(pkt).join("")}0000`);
    }
    return this.receive(m[1]!, repo, new Uint8Array(await req.arrayBuffer()));
  }

  private async receive(name: string, repo: { objects: Map<string, Obj>; refs: Map<string, string> }, bytes: Uint8Array) {
    const len = parseInt(dec.decode(bytes.subarray(0, 4)), 16);
    const [cmd] = dec.decode(bytes.subarray(4, len)).split("\0");
    const [old, commit, ref] = cmd!.trim().split(" ");
    if (dec.decode(bytes.subarray(len, len + 4)) !== "0000") throw new Error("flush missing");
    const pack = bytes.subarray(len + 4);
    const fail = (why: string) => {
      const line = `unpack ${why}\n`;
      return new Response((line.length + 4).toString(16).padStart(4, "0") + line + "0000");
    };
    if (dec.decode(pack.subarray(0, 4)) !== "PACK") return fail("bad header");
    const body = pack.subarray(0, pack.length - 20);
    if (hex(pack.subarray(pack.length - 20)) !== hex(await sha1(body))) return fail("bad checksum");
    const count = new DataView(pack.buffer, pack.byteOffset).getUint32(8);
    let at = 12;
    for (let i = 0; i < count; i++) {
      let b = pack[at++]!;
      const type = (b >> 4) & 7;
      let size = b & 15;
      let shift = 4;
      while (b & 0x80) {
        b = pack[at++]!;
        size += (b & 0x7f) * 2 ** shift;
        shift += 7;
      }
      const r = inflateSync(pack.subarray(at, body.length), { info: true }) as unknown as { buffer: Uint8Array; engine: { bytesWritten: number } };
      if (r.buffer.length !== size) return fail("bad size");
      at += r.engine.bytesWritten;
      const data = new Uint8Array(r.buffer);
      const kind = type === 1 ? "commit" : type === 2 ? "tree" : "blob";
      const id = hex(await sha1(new Uint8Array([...new TextEncoder().encode(`${kind} ${data.length}\0`), ...data])));
      repo.objects.set(id, { type, body: data });
    }
    if (at !== body.length) return fail("trailing bytes");
    if (!repo.objects.has(commit!)) return fail("commit not in pack");
    const tip = repo.refs.get(ref!) ?? ZERO;
    if (tip !== old) return new Response("stale", { status: 409 });
    repo.refs.set(ref!, commit!);
    this.pushes.push({ repo: name, ref: ref!, old: old!, commit: commit! });
    const pkt = (s: string) => (s.length + 4).toString(16).padStart(4, "0") + s;
    return new Response(`${pkt("unpack ok\n")}${pkt(`ok ${ref}\n`)}0000`);
  }
}
