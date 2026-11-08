#!/usr/bin/env bun
// Serves a directory over http on 127.0.0.1 on an ephemeral port and prints the
// port. scripts/update-e2e.sh uses this so the Sparkle e2e test can read its
// appcast and update over a real http:// URL (Sparkle cannot download a
// file:// enclosure). Never used for a release.
import { readFile } from "node:fs/promises";
import { extname, join, normalize, resolve } from "node:path";

const dir = resolve(process.argv[2] ?? ".");

const types = {
  ".xml": "application/xml",
  ".zip": "application/octet-stream",
  ".txt": "text/plain",
  ".html": "text/html",
  ".json": "application/json",
};

const server = Bun.serve({
  hostname: "127.0.0.1",
  port: 0,
  async fetch(request) {
    const url = new URL(request.url);
    const path = normalize(decodeURIComponent(url.pathname)).replace(/^([/.])+/, "");
    const full = join(dir, path);
    if (!full.startsWith(dir)) return new Response("forbidden", { status: 403 });
    try {
      const data = await readFile(full);
      return new Response(data, {
        headers: { "content-type": types[extname(full)] ?? "application/octet-stream" },
      });
    } catch {
      return new Response("not found", { status: 404 });
    }
  },
});

process.stdout.write(String(server.port) + "\n");
