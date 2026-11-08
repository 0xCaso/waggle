import type { Env } from "./env";
import { GitPushError, pushFiles } from "./git";

// Where the files of a round live. Deployed: Cloudflare Artifacts (one Git repo per case,
// one commit per round, one branch per variant). Local dev: D1, because Artifacts has no
// local simulator.
export interface RoundStore {
  kind: "artifacts" | "d1";
  createRepo(caseId: string): Promise<string | null>;
  deleteRepo(caseId: string): Promise<void>;
  // A short-lived Git write token for the owner's push. Null when the store has no Git.
  pushAccess(caseId: string): Promise<{ remote: string; token: string; expiresAt: number } | null>;
  hasCommit(caseId: string, commitId: string): Promise<boolean>;
  readFile(caseId: string, commitId: string, path: string): Promise<{ body: ArrayBuffer; type: string } | null>;
  // Stores the files of one round and returns its commit id. D1 keeps the files; Artifacts gets a Git
  // commit pushed from the Worker, so the daemon only ever talks to the relay.
  putRound(caseId: string, files: RoundFile[], opts: { variant: string; label: string }): Promise<string>;
}

export type RoundFile = { path: string; content_type?: string; body_base64: string };

export function repoName(caseId: string) {
  return `waggle-${caseId}`;
}

export function roundStore(env: Env): RoundStore {
  return env.ROUND_STORE === "artifacts" ? artifactsStore(env) : d1Store(env);
}

function artifactsStore(env: Env): RoundStore {
  const artifacts = env.ARTIFACTS;
  if (!artifacts) throw new Error("ROUND_STORE=artifacts needs the ARTIFACTS binding");
  return {
    kind: "artifacts",
    async createRepo(caseId) {
      const created = await artifacts.create(repoName(caseId), { setDefaultBranch: "main" });
      return created.name;
    },
    async deleteRepo(caseId) {
      await artifacts.delete(repoName(caseId));
    },
    async pushAccess(caseId) {
      using repo = await artifacts.get(repoName(caseId));
      const info = await repo.info();
      const token = await repo.createToken("write", 600);
      return { remote: info.remote, token: token.plaintext, expiresAt: Date.parse(String(token.expiresAt)) || 0 };
    },
    async hasCommit(caseId, commitId) {
      using repo = await artifacts.get(repoName(caseId));
      return (await repo.readCommit(commitId)) !== null;
    },
    async readFile(caseId, commitId, path) {
      using repo = await artifacts.get(repoName(caseId));
      const blob = await repo.readFile({ ref: commitId, path });
      if (!blob) return null;
      return { body: await blob.arrayBuffer(), type: contentTypeFor(path, blob.type) };
    },
    async putRound(caseId, files, opts) {
      const access = await this.pushAccess(caseId);
      if (!access) throw new Error("No push access");
      const decoded = files.map((f) => ({ path: cleanPath(f.path), bytes: fromBase64(f.body_base64) }));
      if (new Set(decoded.map((f) => f.path)).size !== decoded.length) throw new BadInput("Two files have the same path");
      try {
        return await pushFiles({ remote: access.remote, token: access.token, branch: safeBranch(opts.variant), files: decoded, message: opts.label });
      } catch (e) {
        if (e instanceof GitPushError) throw new StoreError(e.message);
        throw e;
      }
    },
  };
}

function d1Store(env: Env): RoundStore {
  return {
    kind: "d1",
    async createRepo() {
      return null;
    },
    async deleteRepo() {},
    async pushAccess() {
      return null;
    },
    async hasCommit(caseId, commitId) {
      const row = await env.DB.prepare("SELECT 1 FROM round_files WHERE case_id = ? AND commit_id = ? LIMIT 1")
        .bind(caseId, commitId)
        .first();
      return row !== null;
    },
    async readFile(caseId, commitId, path) {
      const row = await env.DB.prepare(
        "SELECT content_type, body FROM round_files WHERE case_id = ? AND commit_id = ? AND path = ?",
      )
        .bind(caseId, commitId, path)
        .first<{ content_type: string; body: ArrayBuffer | number[] }>();
      if (!row) return null;
      const body = row.body instanceof ArrayBuffer ? row.body : new Uint8Array(row.body).buffer;
      return { body, type: row.content_type };
    },
    async putRound(caseId, files) {
      const decoded = files.map((f) => ({ path: cleanPath(f.path), type: contentTypeFor(f.path, f.content_type), bytes: fromBase64(f.body_base64) }));
      decoded.sort((a, b) => (a.path < b.path ? -1 : 1));
      // A stand-in for a Git commit id: SHA-1 over the paths and bytes.
      const parts: Uint8Array[] = [];
      for (const f of decoded) parts.push(new TextEncoder().encode(f.path + "\0"), f.bytes);
      const commitId = await sha1Hex(concat(parts));
      await env.DB.batch(
        decoded.map((f) =>
          env.DB.prepare(
            "INSERT OR REPLACE INTO round_files (case_id, commit_id, path, content_type, body) VALUES (?, ?, ?, ?, ?)",
          ).bind(caseId, commitId, f.path, f.type, f.bytes),
        ),
      );
      return commitId;
    },
  };
}

// A hash of the paths and bytes of a round. The same files give the same id, so a retried upload
// does not make a second round (each Git push makes a new commit, so the commit id cannot tell).
export async function contentId(files: RoundFile[]): Promise<string> {
  const decoded = files.map((f) => ({ path: cleanPath(f.path), bytes: fromBase64(f.body_base64) }));
  decoded.sort((a, b) => (a.path < b.path ? -1 : 1));
  const parts: Uint8Array[] = [];
  for (const f of decoded) parts.push(new TextEncoder().encode(f.path + "\0"), f.bytes);
  return sha1Hex(concat(parts));
}

// A caller error the API turns into a 400.
export class BadInput extends Error {}

// The store could not keep the round (the Git remote said no). The API turns it into a 502.
export class StoreError extends Error {}

// A variant names a Git branch: letters, digits, dot, dash, underscore, slash.
function safeBranch(variant: string): string {
  if (!/^[A-Za-z0-9][A-Za-z0-9._\/-]{0,59}$/.test(variant) || variant.includes("..") || variant.endsWith("/") || variant.endsWith(".lock")) {
    throw new BadInput("variant is not a branch name");
  }
  return variant;
}

export function cleanPath(path: string): string {
  const parts = path.split("/").filter((p) => p !== "" && p !== ".");
  if (parts.length === 0 || parts.some((p) => p === "..")) throw new BadInput(`That path is not allowed: ${path}`);
  return parts.join("/");
}

const TYPES: Record<string, string> = {
  html: "text/html; charset=utf-8",
  htm: "text/html; charset=utf-8",
  md: "text/markdown; charset=utf-8",
  css: "text/css; charset=utf-8",
  js: "text/javascript; charset=utf-8",
  json: "application/json",
  svg: "image/svg+xml",
  png: "image/png",
  jpg: "image/jpeg",
  jpeg: "image/jpeg",
  gif: "image/gif",
  webp: "image/webp",
  txt: "text/plain; charset=utf-8",
};

export function contentTypeFor(path: string, given?: string): string {
  const ext = path.split(".").pop()?.toLowerCase() ?? "";
  return TYPES[ext] ?? (given && given !== "" ? given : "application/octet-stream");
}

function fromBase64(s: string): Uint8Array {
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function concat(parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) {
    out.set(p, at);
    at += p.length;
  }
  return out;
}

async function sha1Hex(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-1", bytes);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
