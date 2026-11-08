import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { bundleFonts, localizeCss, stripFontLinks } from "../src/guide/bundle-fonts.mjs";
import { getGuide } from "../src/guide";

const SHEET = "https://fonts.googleapis.com/css2?family=Inter:wght@400;600&display=swap";
const EXPORT = `<!doctype html><html><head>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="${SHEET.replace("&", "&amp;")}" rel="stylesheet">
<link rel="stylesheet" href="local.css">
</head><body>hi</body></html>`;
const CSS = `@font-face { font-family: 'Inter'; font-weight: 400; src: url(https://fonts.gstatic.com/s/inter/v1/a.woff2) format('woff2'); }
@font-face { font-family: 'Inter'; font-weight: 600; src: url(https://fonts.gstatic.com/s/inter/v1/b.woff2) format('woff2'); }`;

const dirs: string[] = [];
function bundle(): string {
  const dir = mkdtempSync(join(tmpdir(), "knock-fonts-"));
  dirs.push(dir);
  mkdirSync(join(dir, "sub"));
  writeFileSync(join(dir, "index.html"), EXPORT);
  writeFileSync(join(dir, "sub", "page.html"), EXPORT);
  return dir;
}
afterEach(() => dirs.splice(0).forEach((d) => rmSync(d, { recursive: true, force: true })));

const okIo = {
  fetchText: async (url: string) => {
    expect(url).toBe(SHEET);
    return CSS;
  },
  fetchBytes: async (url: string) => new TextEncoder().encode(`bytes:${url}`),
};

describe("bundle-fonts", () => {
  test("stripFontLinks removes Google links only", () => {
    const { html, sheets } = stripFontLinks(EXPORT);
    expect(sheets).toEqual([SHEET]);
    expect(html).not.toContain("google");
    expect(html).not.toContain("gstatic");
    expect(html).toContain('href="local.css"');
  });

  test("localizeCss rewrites urls to local names", () => {
    const { css, files } = localizeCss(CSS);
    expect(css).not.toContain("gstatic");
    expect(files).toHaveLength(2);
    for (const [name] of files) expect(css).toContain(`url(${name})`);
  });

  test("rewrites the bundle with local fonts", async () => {
    const dir = bundle();
    expect(await bundleFonts(dir, okIo)).toEqual([]);
    const files = readdirSync(join(dir, "fonts"));
    expect(files.filter((f) => f.endsWith(".woff2"))).toHaveLength(2);
    const css = readFileSync(join(dir, "fonts", "fonts-1.css"), "utf8");
    expect(css).not.toContain("http");
    const root = readFileSync(join(dir, "index.html"), "utf8");
    expect(root).toContain('<link rel="stylesheet" href="fonts/fonts-1.css">');
    expect(root).not.toContain("google");
    expect(readFileSync(join(dir, "sub", "page.html"), "utf8")).toContain('href="../fonts/fonts-1.css"');
  });

  test("on failure removes links and warns", async () => {
    const dir = bundle();
    const warnings = await bundleFonts(dir, {
      fetchText: async () => {
        throw new Error("offline");
      },
      fetchBytes: async () => new Uint8Array(),
    });
    expect(warnings).toHaveLength(1);
    expect(warnings[0]).toContain("offline");
    const root = readFileSync(join(dir, "index.html"), "utf8");
    expect(root).not.toContain("google");
    expect(root).not.toContain("gstatic");
    expect(root).not.toContain("fonts/");
  });

  test("the guide topic embeds the script and artifacts points to it", () => {
    const topic = getGuide("bundle-fonts") as string;
    expect(topic).toContain("export async function bundleFonts");
    expect(getGuide("artifacts")).toContain("bundle-fonts");
  });
});
