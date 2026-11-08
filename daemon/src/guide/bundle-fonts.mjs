// Run on the agent's side BEFORE knock_ask: node bundle-fonts.mjs <bundle-dir>
// Makes a Pen HTML export keep its fonts offline. The daemon and the app never
// use the network; only this script does, and only when the agent runs it.
import { createHash } from "node:crypto";
import { mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { basename, dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const CSS_HOST = "fonts.googleapis.com";
const FILE_HOST = "fonts.gstatic.com";
const LINK_RE = /<link\b[^>]*>\s*/gi;
const BROWSER_UA =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15";

const hrefOf = (tag) => /\bhref\s*=\s*["']([^"']+)["']/i.exec(tag)?.[1]?.replace(/&amp;/g, "&");
const hostOf = (href) => {
  try {
    return new URL(href).hostname;
  } catch {
    return undefined;
  }
};

// Splits html into the Google Fonts stylesheet urls and the html without any
// Google Fonts <link> (stylesheets and preconnect hints).
export function stripFontLinks(html) {
  const sheets = [];
  const out = html.replace(LINK_RE, (tag) => {
    const href = hrefOf(tag);
    const host = href ? hostOf(href) : undefined;
    const isSheet = host === CSS_HOST && new URL(href).pathname.startsWith("/css");
    if (isSheet) sheets.push(href);
    return host === CSS_HOST || host === FILE_HOST ? "" : tag;
  });
  return { html: out, sheets };
}

// Rewrites every gstatic url(...) in a stylesheet to a local file name.
// Returns the new css and the [name, remoteUrl] files to download.
export function localizeCss(css) {
  const files = new Map();
  const out = css.replace(/url\(\s*["']?(https:\/\/fonts\.gstatic\.com\/[^)"'\s]+)["']?\s*\)/g, (_, remote) => {
    const ext = /\.(woff2|woff|ttf|otf)(?:$|\?)/.exec(remote)?.[1] ?? "woff2";
    const name = `${createHash("sha1").update(remote).digest("hex").slice(0, 12)}.${ext}`;
    files.set(name, remote);
    return `url(${name})`;
  });
  return { css: out, files: [...files] };
}

function htmlFiles(dir) {
  return readdirSync(dir).flatMap((entry) => {
    const path = join(dir, entry);
    if (statSync(path).isDirectory()) return entry === "fonts" ? [] : htmlFiles(path);
    return /\.html?$/i.test(entry) ? [path] : [];
  });
}

// io = { fetchText(url), fetchBytes(url) }. Returns warnings (empty on success).
export async function bundleFonts(dir, io) {
  const warnings = [];
  const fontsDir = join(dir, "fonts");
  const cache = new Map(); // stylesheet url -> local css file, or null on failure
  let count = 0;

  async function localSheet(url) {
    if (cache.has(url)) return cache.get(url);
    let local = null;
    try {
      const { css, files } = localizeCss(await io.fetchText(url));
      if (files.length === 0) throw new Error("no font files in the stylesheet");
      mkdirSync(fontsDir, { recursive: true });
      for (const [name, remote] of files) writeFileSync(join(fontsDir, name), await io.fetchBytes(remote));
      local = `fonts-${++count}.css`;
      writeFileSync(join(fontsDir, local), css);
    } catch (error) {
      warnings.push(`could not download ${url}: ${error.message}`);
    }
    cache.set(url, local);
    return local;
  }

  for (const file of htmlFiles(dir)) {
    const { html, sheets } = stripFontLinks(readFileSync(file, "utf8"));
    if (html === readFileSync(file, "utf8")) continue;
    let links = "";
    for (const url of new Set(sheets)) {
      const local = await localSheet(url);
      if (local) links += `<link rel="stylesheet" href="${relative(dirname(file), join(fontsDir, local))}">\n`;
    }
    writeFileSync(file, links ? html.replace(/<\/head>/i, `${links}</head>`) : html);
  }
  return warnings;
}

async function main() {
  const dir = process.argv[2];
  if (!dir) {
    console.error("Usage: node bundle-fonts.mjs <bundle-dir>");
    return 2;
  }
  const get = async (url, init) => {
    const res = await fetch(url, init);
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return res;
  };
  const warnings = await bundleFonts(dir, {
    fetchText: async (url) => (await get(url, { headers: { "User-Agent": BROWSER_UA } })).text(),
    fetchBytes: async (url) => new Uint8Array(await (await get(url)).arrayBuffer()),
  });
  for (const w of warnings) console.error(`warning: ${w}; the remote font links were removed, text falls back to system-ui`);
  return 0;
}

if (process.argv[1] && basename(process.argv[1]) === basename(fileURLToPath(import.meta.url))) {
  process.exitCode = await main();
}
