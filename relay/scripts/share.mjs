#!/usr/bin/env node
// Plays the daemon's part against a relay: share a case, push a round, read the comments.
// The owner key stays on this Mac: in the login Keychain (default) or, for tests, in a file
// named by RELAY_KEY_FILE. The relay only ever sees the key's SHA-256 hash and Bearer calls.
//
// "create" needs an account: set WAGGLE_DEVICE_TOKEN to a device token (the Mac connect flow gives one).
//
//   node scripts/share.mjs create "<title>" [--emails a@x.com,b@y.com]
//   node scripts/share.mjs push <case> <folder> --label "<label>" [--entry index.html] [--variant main]
//   node scripts/share.mjs comments <case>
//   node scripts/share.mjs open <case>
//   node scripts/share.mjs delete <case>
//
// RELAY_URL defaults to http://localhost:8787 (wrangler dev).

import { execFileSync } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { cpSync, existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, relative } from "node:path";

const RELAY = process.env.RELAY_URL ?? "http://localhost:8787";
const SERVICE = "dev.limone.knock.relay";
const KEY_FILE = process.env.RELAY_KEY_FILE;

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i > 0 ? process.argv[i + 1] : fallback;
}

function saveKey(id, key) {
  if (KEY_FILE) {
    const all = existsSync(KEY_FILE) ? JSON.parse(readFileSync(KEY_FILE, "utf8")) : {};
    all[id] = key;
    writeFileSync(KEY_FILE, JSON.stringify(all, null, 2), { mode: 0o600 });
    return;
  }
  execFileSync("security", ["add-generic-password", "-U", "-s", SERVICE, "-a", id, "-w", key]);
}

function loadKey(id) {
  if (KEY_FILE) return JSON.parse(readFileSync(KEY_FILE, "utf8"))[id];
  return execFileSync("security", ["find-generic-password", "-s", SERVICE, "-a", id, "-w"]).toString().trim();
}

function dropKey(id) {
  if (KEY_FILE) {
    const all = JSON.parse(readFileSync(KEY_FILE, "utf8"));
    delete all[id];
    writeFileSync(KEY_FILE, JSON.stringify(all, null, 2), { mode: 0o600 });
    return;
  }
  execFileSync("security", ["delete-generic-password", "-s", SERVICE, "-a", id]);
}

async function api(path, { method = "GET", body, key } = {}) {
  const headers = { "content-type": "application/json" };
  if (key) headers.authorization = `Bearer ${key}`;
  const res = await fetch(RELAY + path, { method, headers, body: body ? JSON.stringify(body) : undefined });
  const data = await res.json().catch(() => ({}));
  if (!res.ok && res.status !== 409) throw new Error(`${method} ${path}: ${res.status} ${data.error ?? ""}`);
  return { status: res.status, data };
}

function files(dir) {
  const out = [];
  (function walk(d) {
    for (const name of readdirSync(d)) {
      if (name === ".git") continue;
      const p = join(d, name);
      if (statSync(p).isDirectory()) walk(p);
      else out.push(relative(dir, p));
    }
  })(dir);
  return out;
}

function git(cwd, token, ...args) {
  // The token goes in a header, never in the remote URL or the repo config.
  return execFileSync("git", ["-c", `http.extraHeader=Authorization: Bearer ${token}`, ...args], { cwd, stdio: ["ignore", "pipe", "pipe"] })
    .toString()
    .trim();
}

const [cmd, id, folder] = process.argv.slice(2);

if (cmd === "create") {
  const title = id;
  const emails = (arg("emails", "") || "").split(",").filter(Boolean);
  const key = randomBytes(32).toString("base64url");
  const hash = createHash("sha256").update(key).digest("hex");
  const { data } = await api("/api/cases", {
    method: "POST",
    key: process.env.WAGGLE_DEVICE_TOKEN,
    body: { title, mode: emails.length ? "emails" : "link", emails, owner_key_hash: hash },
  });
  saveKey(data.id, key);
  console.log(JSON.stringify(data, null, 2));
} else if (cmd === "push") {
  const key = loadKey(id);
  const label = arg("label", "Round");
  const entry = arg("entry", "index.html");
  const variant = arg("variant", "main");
  const t0 = Date.now();
  const access = await api(`/api/cases/${id}/push-access`, { method: "POST", key });
  let round;
  if (access.status === 409) {
    // Local dev: no Git in the relay, so upload the files.
    const list = files(folder).map((p) => ({ path: p, body_base64: readFileSync(join(folder, p)).toString("base64") }));
    round = (await api(`/api/cases/${id}/rounds`, { method: "POST", key, body: { label, entry, variant, files: list } })).data;
  } else {
    const { remote, token } = access.data;
    const work = mkdtempSync(join(tmpdir(), "waggle-relay-"));
    try {
      try {
        git(tmpdir(), token, "clone", "--quiet", "--branch", variant, remote, work);
      } catch {
        // A new repo or a new variant branch: start it.
        rmSync(work, { recursive: true, force: true });
        try {
          git(tmpdir(), token, "clone", "--quiet", remote, work);
        } catch {
          execFileSync("git", ["init", "--quiet", "-b", "main", work]);
        }
        try {
          git(work, token, "checkout", "--quiet", "-b", variant);
        } catch {}
      }
      for (const name of readdirSync(work)) if (name !== ".git") rmSync(join(work, name), { recursive: true, force: true });
      cpSync(folder, work, { recursive: true });
      git(work, token, "add", "-A");
      git(work, token, "-c", "user.name=Waggle", "-c", "user.email=relay@waggle.so", "commit", "--quiet", "--allow-empty", "-m", label);
      const commit = git(work, token, "rev-parse", "HEAD");
      git(work, token, "push", "--quiet", remote, `HEAD:${variant}`);
      round = (await api(`/api/cases/${id}/rounds`, { method: "POST", key, body: { label, entry, variant, commit } })).data;
    } finally {
      rmSync(work, { recursive: true, force: true });
    }
  }
  console.log(JSON.stringify({ ...round, ms: Date.now() - t0 }, null, 2));
} else if (cmd === "comments") {
  const { data } = await api(`/api/cases/${id}/comments`, { key: loadKey(id) });
  for (const c of data.comments) {
    console.log(`round ${c.round_seq} · ${c.author_name} (${c.author_kind})${c.quote ? ` on "${c.quote}"` : ""}: ${c.body}`);
  }
} else if (cmd === "open") {
  const { data } = await api(`/api/cases/${id}/owner-link`, { method: "POST", key: loadKey(id) });
  console.log(data.url);
} else if (cmd === "delete") {
  await api(`/api/cases/${id}`, { method: "DELETE", key: loadKey(id) });
  dropKey(id);
  console.log("deleted");
} else {
  console.error("usage: share.mjs create|push|comments|open|delete");
  process.exit(2);
}
