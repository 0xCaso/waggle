// A minimal Git smart-HTTP writer for a Worker (WAG-391). It builds the objects of one commit
// (blobs, trees, a commit), packs them without deltas and pushes them with git-receive-pack v1.
// Cloudflare Artifacts speaks standard Git over HTTPS, so no Git binary and no extra host is needed.

export type GitFile = { path: string; bytes: Uint8Array };

export class GitPushError extends Error {}

const enc = new TextEncoder();
const ZERO = "0".repeat(40);

const hex = (b: Uint8Array) => [...b].map((x) => x.toString(16).padStart(2, "0")).join("");

function concat(parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) {
    out.set(p, at);
    at += p.length;
  }
  return out;
}

async function sha1(bytes: Uint8Array): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-1", bytes as BufferSource));
}

type GitObject = { type: 1 | 2 | 3; body: Uint8Array; id: Uint8Array };

async function object(type: 1 | 2 | 3, body: Uint8Array): Promise<GitObject> {
  const name = type === 1 ? "commit" : type === 2 ? "tree" : "blob";
  const id = await sha1(concat([enc.encode(`${name} ${body.length}\0`), body]));
  return { type, body, id };
}

async function deflate(bytes: Uint8Array): Promise<Uint8Array> {
  const stream = new Response(bytes as BodyInit).body!.pipeThrough(new CompressionStream("deflate"));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

// Git sorts tree entries by name, and compares a directory as if its name ended with "/".
function compareEntries(a: { name: string; dir: boolean }, b: { name: string; dir: boolean }): number {
  const x = a.dir ? `${a.name}/` : a.name;
  const y = b.dir ? `${b.name}/` : b.name;
  return x < y ? -1 : x > y ? 1 : 0;
}

type Dir = { files: Map<string, GitObject>; dirs: Map<string, Dir> };

// Writes every tree under `dir` into `out` and returns the id of this one.
async function writeTree(dir: Dir, out: GitObject[]): Promise<Uint8Array> {
  const entries: { name: string; dir: boolean; mode: string; id: Uint8Array }[] = [];
  for (const [name, blob] of dir.files) entries.push({ name, dir: false, mode: "100644", id: blob.id });
  for (const [name, sub] of dir.dirs) entries.push({ name, dir: true, mode: "40000", id: await writeTree(sub, out) });
  entries.sort(compareEntries);
  const tree = await object(2, concat(entries.flatMap((e) => [enc.encode(`${e.mode} ${e.name}\0`), e.id])));
  out.push(tree);
  return tree.id;
}

// The objects of one commit that holds exactly `files`. `parent` is the branch tip, or null.
export async function buildCommit(
  files: GitFile[],
  o: { parent: string | null; message: string; time: number },
): Promise<{ commit: string; objects: GitObject[] }> {
  const root: Dir = { files: new Map(), dirs: new Map() };
  const objects: GitObject[] = [];
  for (const f of files) {
    const parts = f.path.split("/");
    const leaf = parts.pop()!;
    let dir = root;
    for (const part of parts) {
      let next = dir.dirs.get(part);
      if (!next) dir.dirs.set(part, (next = { files: new Map(), dirs: new Map() }));
      dir = next;
    }
    const blob = await object(3, f.bytes);
    objects.push(blob);
    dir.files.set(leaf, blob);
  }
  const tree = hex(await writeTree(root, objects));
  const who = `Waggle <relay@waggle.so> ${Math.floor(o.time / 1000)} +0000`;
  const text = `tree ${tree}\n${o.parent ? `parent ${o.parent}\n` : ""}author ${who}\ncommitter ${who}\n\n${o.message}\n`;
  const commit = await object(1, enc.encode(text));
  objects.push(commit);
  return { commit: hex(commit.id), objects };
}

function packHeader(type: number, size: number): Uint8Array {
  const out = [(type << 4) | (size & 15)];
  let rest = size >>> 4;
  if (rest > 0) out[0]! |= 0x80;
  while (rest > 0) {
    const low = rest & 0x7f;
    rest = Math.floor(rest / 128);
    out.push(rest > 0 ? low | 0x80 : low);
  }
  return Uint8Array.from(out);
}

export async function buildPack(objects: GitObject[]): Promise<Uint8Array> {
  // The same blob may appear twice (two equal files): a pack holds each object once.
  const seen = new Set<string>();
  const unique = objects.filter((x) => {
    const id = hex(x.id);
    if (seen.has(id)) return false;
    seen.add(id);
    return true;
  });
  const head = new Uint8Array(12);
  head.set(enc.encode("PACK"));
  const view = new DataView(head.buffer);
  view.setUint32(4, 2);
  view.setUint32(8, unique.length);
  const parts: Uint8Array[] = [head];
  for (const x of unique) parts.push(packHeader(x.type, x.body.length), await deflate(x.body));
  const body = concat(parts);
  return concat([body, await sha1(body)]);
}

function pkt(s: string): Uint8Array {
  const bytes = enc.encode(s);
  return concat([enc.encode((bytes.length + 4).toString(16).padStart(4, "0")), bytes]);
}

function readPkts(bytes: Uint8Array): (string | null)[] {
  const out: (string | null)[] = [];
  const dec = new TextDecoder();
  let at = 0;
  while (at + 4 <= bytes.length) {
    const len = parseInt(dec.decode(bytes.subarray(at, at + 4)), 16);
    if (Number.isNaN(len)) throw new GitPushError("The Git remote sent something unexpected.");
    if (len === 0) {
      out.push(null);
      at += 4;
      continue;
    }
    out.push(dec.decode(bytes.subarray(at + 4, at + len)));
    at += len;
  }
  return out;
}

// Pushes one commit with `files` to refs/heads/<branch>. Returns the new commit id.
// The token goes in a header only.
export async function pushFiles(o: {
  remote: string;
  token: string;
  branch: string;
  files: GitFile[];
  message: string;
  now?: number;
  fetch?: typeof fetch;
}): Promise<string> {
  const doFetch = o.fetch ?? fetch;
  const remote = o.remote.replace(/\/+$/, "");
  const headers = { authorization: `Bearer ${o.token}` };
  const ref = `refs/heads/${o.branch}`;

  const adv = await doFetch(`${remote}/info/refs?service=git-receive-pack`, { headers });
  if (!adv.ok) throw new GitPushError(`The Git remote refused the push (${adv.status}).`);
  let tip: string | null = null;
  for (const line of readPkts(new Uint8Array(await adv.arrayBuffer()))) {
    if (line === null || line.startsWith("#")) continue;
    const [oid, name] = line.split("\0")[0]!.trim().split(" ");
    if (name === ref && oid && oid !== ZERO) tip = oid;
  }

  const { commit, objects } = await buildCommit(o.files, { parent: tip, message: o.message, time: o.now ?? Date.now() });
  const pack = await buildPack(objects);
  const request = concat([pkt(`${tip ?? ZERO} ${commit} ${ref}\0 report-status agent=waggle-relay\n`), enc.encode("0000"), pack]);
  const res = await doFetch(`${remote}/git-receive-pack`, {
    method: "POST",
    headers: { ...headers, "content-type": "application/x-git-receive-pack-request" },
    body: request as BodyInit,
  });
  if (!res.ok) throw new GitPushError(`The Git remote refused the push (${res.status}).`);
  const report = readPkts(new Uint8Array(await res.arrayBuffer())).filter((l): l is string => l !== null);
  if (!report.some((l) => l.startsWith("unpack ok")) || !report.some((l) => l.startsWith(`ok ${ref}`))) {
    throw new GitPushError(`The Git remote did not accept the commit: ${report.join(" ").replace(/\s+/g, " ").slice(0, 160)}`);
  }
  return commit;
}
