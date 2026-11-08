import { afterEach, describe, expect, test } from "bun:test";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join } from "node:path";
import {
  ArtifactError,
  MAX_BUNDLE_BYTES,
  MAX_BUNDLE_FILES,
  MAX_DIAGRAM_BYTES,
  MAX_MARKDOWN_BYTES,
  MAX_SCREENSHOT_BYTES,
  stageBundle,
  stageDiagram,
  stageMarkdown,
  stageScreenshot,
  stageScreenshots,
} from "../src/artifacts";
import { rmrf } from "./helpers";

const PNG_SIG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
const JPEG_SIG = Buffer.from([0xff, 0xd8, 0xff]);

const temps: string[] = [];

function tmp(): string {
  const dir = mkdtempSync(join(tmpdir(), "knock-art-"));
  temps.push(dir);
  return dir;
}

afterEach(() => {
  for (const dir of temps.splice(0)) {
    rmrf(dir);
  }
});

function write(path: string, data: string | Buffer): void {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, data);
}

function pngBytes(): Buffer {
  return Buffer.concat([PNG_SIG, Buffer.from("fake png body")]);
}

function jpegBytes(): Buffer {
  return Buffer.concat([JPEG_SIG, Buffer.from("fake jpeg body")]);
}

describe("stageScreenshot (shim -> incoming)", () => {
  test("copies a PNG into incoming/<uuid>/shot.png", () => {
    const home = tmp();
    const cwd = join(home, "work");
    const incomingDir = join(home, "incoming");
    const data = pngBytes();
    write(join(cwd, "shots", "a.png"), data);

    const staged = stageScreenshot({ path: "./shots/a.png", cwd, incomingDir });

    expect(staged.kind).toBe("screenshot");
    expect(staged.ext).toBe("png");
    expect(dirname(staged.path)).toMatch(/\/incoming\/[0-9a-f-]{36}$/);
    expect(basename(staged.path)).toBe("shot.png");
    expect(readFileSync(staged.path).equals(data)).toBe(true);
  });

  test("accepts JPEG and normalizes .jpeg to .jpg", () => {
    const home = tmp();
    const cwd = join(home, "work");
    const incomingDir = join(home, "incoming");
    const jpg = jpegBytes();
    write(join(cwd, "shot.jpg"), jpg);
    write(join(cwd, "shot.jpeg"), jpg);

    expect(stageScreenshot({ path: "./shot.jpg", cwd, incomingDir }).ext).toBe("jpg");
    expect(basename(stageScreenshot({ path: "./shot.jpeg", cwd, incomingDir }).path)).toBe("shot.jpg");
  });

  test("rejects a screenshot larger than 20 MB", () => {
    const home = tmp();
    const cwd = join(home, "work");
    write(join(cwd, "big.png"), Buffer.concat([PNG_SIG, Buffer.alloc(MAX_SCREENSHOT_BYTES + 1)]));

    expect(() =>
      stageScreenshot({ path: "./big.png", cwd, incomingDir: join(home, "incoming") }),
    ).toThrow(/larger than 20 MB/);
  });

  test("rejects a non-image file with a png extension", () => {
    const home = tmp();
    const cwd = join(home, "work");
    write(join(cwd, "not.png"), "plain text, not a PNG");

    expect(() =>
      stageScreenshot({ path: "./not.png", cwd, incomingDir: join(home, "incoming") }),
    ).toThrow(/not a PNG/);
  });

  test("rejects an unknown extension", () => {
    const home = tmp();
    const cwd = join(home, "work");
    write(join(cwd, "shot.gif"), pngBytes());

    expect(() =>
      stageScreenshot({ path: "./shot.gif", cwd, incomingDir: join(home, "incoming") }),
    ).toThrow(/\.png or \.jpg/);
  });

  test("rejects a missing file", () => {
    const home = tmp();
    const cwd = join(home, "work");
    mkdirSync(cwd, { recursive: true });

    expect(() =>
      stageScreenshot({ path: "./gone.png", cwd, incomingDir: join(home, "incoming") }),
    ).toThrow(ArtifactError);
  });

  test("rejects a directory path", () => {
    const home = tmp();
    const cwd = join(home, "work");
    mkdirSync(join(cwd, "dir.png"), { recursive: true });

    expect(() =>
      stageScreenshot({ path: "./dir.png", cwd, incomingDir: join(home, "incoming") }),
    ).toThrow(/not a regular file/);
  });
});

// HAIL-33: the markdown artifact is staged the same way as a screenshot, at
// most 1 MB, into incoming/<uuid>/note.md.
describe("stageMarkdown (shim -> incoming)", () => {
  test("copies a .md file into incoming/<uuid>/note.md", () => {
    const home = tmp();
    const cwd = join(home, "work");
    const incomingDir = join(home, "incoming");
    write(join(cwd, "notes", "explanation.md"), "# Trade-offs\n\nSome text.");

    const staged = stageMarkdown({ path: "./notes/explanation.md", cwd, incomingDir });

    expect(staged.kind).toBe("markdown");
    expect(dirname(staged.path)).toMatch(/\/incoming\/[0-9a-f-]{36}$/);
    expect(basename(staged.path)).toBe("note.md");
    expect(readFileSync(staged.path, "utf8")).toBe("# Trade-offs\n\nSome text.");
  });

  test("accepts .markdown too", () => {
    const home = tmp();
    const cwd = join(home, "work");
    const incomingDir = join(home, "incoming");
    write(join(cwd, "explanation.markdown"), "hello");

    const staged = stageMarkdown({ path: "./explanation.markdown", cwd, incomingDir });
    expect(basename(staged.path)).toBe("note.md");
  });

  test("rejects markdown larger than 1 MB", () => {
    const home = tmp();
    const cwd = join(home, "work");
    write(join(cwd, "big.md"), Buffer.alloc(MAX_MARKDOWN_BYTES + 1, "a"));

    expect(() =>
      stageMarkdown({ path: "./big.md", cwd, incomingDir: join(home, "incoming") }),
    ).toThrow(/larger than 1 MB/);
  });

  test("rejects an unsupported extension", () => {
    const home = tmp();
    const cwd = join(home, "work");
    write(join(cwd, "notes.txt"), "hello");

    expect(() =>
      stageMarkdown({ path: "./notes.txt", cwd, incomingDir: join(home, "incoming") }),
    ).toThrow(/\.md or \.markdown/);
  });

  test("rejects a missing file", () => {
    const home = tmp();
    const cwd = join(home, "work");
    mkdirSync(cwd, { recursive: true });

    expect(() =>
      stageMarkdown({ path: "./gone.md", cwd, incomingDir: join(home, "incoming") }),
    ).toThrow(ArtifactError);
  });

  test("rejects a directory path", () => {
    const home = tmp();
    const cwd = join(home, "work");
    mkdirSync(join(cwd, "dir.md"), { recursive: true });

    expect(() =>
      stageMarkdown({ path: "./dir.md", cwd, incomingDir: join(home, "incoming") }),
    ).toThrow(/not a regular file/);
  });
});

// HAIL-141: a diagram artifact is one .mmd or .svg file, at most 512 KB,
// staged the same way as markdown, into incoming/<uuid>/diagram.<ext>.
describe("stageDiagram (shim -> incoming)", () => {
  test("copies a .mmd file into incoming/<uuid>/diagram.mmd", () => {
    const home = tmp();
    const cwd = join(home, "work");
    const incomingDir = join(home, "incoming");
    const source = "flowchart TD\n    A --> B\n";
    write(join(cwd, "notes", "flow.mmd"), source);

    const staged = stageDiagram({ path: "./notes/flow.mmd", cwd, incomingDir });

    expect(staged.kind).toBe("diagram");
    expect(staged.ext).toBe("mmd");
    expect(dirname(staged.path)).toMatch(/\/incoming\/[0-9a-f-]{36}$/);
    expect(basename(staged.path)).toBe("diagram.mmd");
    expect(readFileSync(staged.path, "utf8")).toBe(source);
  });

  test("copies a .svg file into incoming/<uuid>/diagram.svg", () => {
    const home = tmp();
    const cwd = join(home, "work");
    const incomingDir = join(home, "incoming");
    const source = "<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>";
    write(join(cwd, "notes", "flow.svg"), source);

    const staged = stageDiagram({ path: "./notes/flow.svg", cwd, incomingDir });

    expect(staged.kind).toBe("diagram");
    expect(staged.ext).toBe("svg");
    expect(basename(staged.path)).toBe("diagram.svg");
  });

  test("rejects a diagram larger than 512 KB", () => {
    const home = tmp();
    const cwd = join(home, "work");
    write(join(cwd, "big.mmd"), Buffer.alloc(MAX_DIAGRAM_BYTES + 1, "a"));

    expect(() =>
      stageDiagram({ path: "./big.mmd", cwd, incomingDir: join(home, "incoming") }),
    ).toThrow(/larger than 512 KB/);
  });

  test("rejects an unsupported extension", () => {
    const home = tmp();
    const cwd = join(home, "work");
    write(join(cwd, "flow.txt"), "flowchart TD");

    expect(() =>
      stageDiagram({ path: "./flow.txt", cwd, incomingDir: join(home, "incoming") }),
    ).toThrow(/\.mmd or \.svg/);
  });

  test("rejects a .png path", () => {
    const home = tmp();
    const cwd = join(home, "work");
    write(join(cwd, "flow.png"), pngBytes());

    expect(() =>
      stageDiagram({ path: "./flow.png", cwd, incomingDir: join(home, "incoming") }),
    ).toThrow(/\.mmd or \.svg/);
  });

  test("rejects a missing file", () => {
    const home = tmp();
    const cwd = join(home, "work");
    mkdirSync(cwd, { recursive: true });

    expect(() =>
      stageDiagram({ path: "./gone.mmd", cwd, incomingDir: join(home, "incoming") }),
    ).toThrow(ArtifactError);
  });

  test("rejects a directory path", () => {
    const home = tmp();
    const cwd = join(home, "work");
    mkdirSync(join(cwd, "dir.mmd"), { recursive: true });

    expect(() =>
      stageDiagram({ path: "./dir.mmd", cwd, incomingDir: join(home, "incoming") }),
    ).toThrow(/not a regular file/);
  });
});

// HAIL-40: a screenshots artifact stages 2 to 12 images into one shared
// incoming/<uuid>/ directory, each the same way a single screenshot is.
describe("stageScreenshots (shim -> incoming)", () => {
  test("copies every item into one incoming/<uuid>/ dir, in order, with captions preserved", () => {
    const home = tmp();
    const cwd = join(home, "work");
    const incomingDir = join(home, "incoming");
    const png = pngBytes();
    const jpg = jpegBytes();
    write(join(cwd, "shots", "a.png"), png);
    write(join(cwd, "shots", "b.jpg"), jpg);

    const staged = stageScreenshots({
      items: [
        { path: "./shots/a.png", caption: "Home screen" },
        { path: "./shots/b.jpg" },
      ],
      cwd,
      incomingDir,
    });

    expect(staged.kind).toBe("screenshots");
    expect(staged.items).toHaveLength(2);
    expect(dirname(staged.items[0]!.path)).toBe(dirname(staged.items[1]!.path));
    expect(dirname(staged.items[0]!.path)).toMatch(/\/incoming\/[0-9a-f-]{36}$/);
    expect(basename(staged.items[0]!.path)).toBe("shot-1.png");
    expect(basename(staged.items[1]!.path)).toBe("shot-2.jpg");
    expect(readFileSync(staged.items[0]!.path).equals(png)).toBe(true);
    expect(readFileSync(staged.items[1]!.path).equals(jpg)).toBe(true);
    expect(staged.items[0]!.caption).toBe("Home screen");
    expect(staged.items[1]!.caption).toBeUndefined();
  });

  test("rejects an item larger than 20 MB and writes nothing", () => {
    const home = tmp();
    const cwd = join(home, "work");
    const incomingDir = join(home, "incoming");
    write(join(cwd, "a.png"), pngBytes());
    write(join(cwd, "big.png"), Buffer.concat([PNG_SIG, Buffer.alloc(MAX_SCREENSHOT_BYTES + 1)]));

    expect(() =>
      stageScreenshots({
        items: [{ path: "./a.png" }, { path: "./big.png" }],
        cwd,
        incomingDir,
      }),
    ).toThrow(/screenshot 2.*larger than 20 MB/);
    expect(existsSync(incomingDir)).toBe(false);
  });

  test("rejects a non-image item with the item's own 1-based number", () => {
    const home = tmp();
    const cwd = join(home, "work");
    const incomingDir = join(home, "incoming");
    write(join(cwd, "a.png"), pngBytes());
    write(join(cwd, "b.png"), "plain text, not a PNG");

    expect(() =>
      stageScreenshots({
        items: [{ path: "./a.png" }, { path: "./b.png" }],
        cwd,
        incomingDir,
      }),
    ).toThrow(/screenshot 2.*not a PNG/);
  });

  test("rejects a missing item", () => {
    const home = tmp();
    const cwd = join(home, "work");
    write(join(cwd, "a.png"), pngBytes());

    expect(() =>
      stageScreenshots({
        items: [{ path: "./a.png" }, { path: "./gone.png" }],
        cwd,
        incomingDir: join(home, "incoming"),
      }),
    ).toThrow(ArtifactError);
  });
});

describe("stageBundle (shim -> incoming)", () => {
  test("copies a valid bundle into incoming/<uuid>/ and returns the entry", () => {
    const home = tmp();
    const cwd = join(home, "work");
    const incomingDir = join(home, "incoming");
    write(join(cwd, "proto", "index.html"), "<h1>Hello</h1>");
    write(join(cwd, "proto", "style.css"), "body {}");
    write(join(cwd, "proto", "assets", "logo.txt"), "logo");

    const staged = stageBundle({
      dir: "./proto",
      entry: "./index.html",
      cwd,
      incomingDir,
    });

    expect(staged.kind).toBe("html_bundle");
    expect(staged.entry).toBe("index.html");
    expect(dirname(staged.path)).toBe(incomingDir);
    expect(readFileSync(join(staged.path, "index.html"), "utf8")).toBe("<h1>Hello</h1>");
    expect(readFileSync(join(staged.path, "assets", "logo.txt"), "utf8")).toBe("logo");
  });

  test("stages a nested entry path", () => {
    const home = tmp();
    const cwd = join(home, "work");
    const incomingDir = join(home, "incoming");
    write(join(cwd, "proto", "pages", "home.html"), "<p>home</p>");

    const staged = stageBundle({
      dir: "proto",
      entry: "pages/home.html",
      cwd,
      incomingDir,
    });

    expect(staged.entry).toBe("pages/home.html");
    expect(existsSync(join(staged.path, "pages", "home.html"))).toBe(true);
  });

  test("rejects a symlink inside the tree with no partial copy", () => {
    const home = tmp();
    const cwd = join(home, "work");
    const incomingDir = join(home, "incoming");
    write(join(cwd, "proto", "index.html"), "ok");
    write(join(cwd, "outside.txt"), "secret");
    symlinkSync(join(cwd, "outside.txt"), join(cwd, "proto", "link.txt"));

    expect(() =>
      stageBundle({ dir: "proto", entry: "index.html", cwd, incomingDir }),
    ).toThrow(/symlinks/);
    expect(existsSync(incomingDir)).toBe(false);
  });

  test("rejects a symlinked bundle root", () => {
    const home = tmp();
    const cwd = join(home, "work");
    const incomingDir = join(home, "incoming");
    write(join(cwd, "real", "index.html"), "ok");
    symlinkSync(join(cwd, "real"), join(cwd, "proto"));

    expect(() =>
      stageBundle({ dir: "proto", entry: "index.html", cwd, incomingDir }),
    ).toThrow(/must not be a symlink/);
  });

  test("rejects an absolute dir", () => {
    const home = tmp();
    const cwd = join(home, "work");
    const incomingDir = join(home, "incoming");
    mkdirSync(join(cwd, "proto"), { recursive: true });

    expect(() =>
      stageBundle({
        dir: join(cwd, "proto"),
        entry: "index.html",
        cwd,
        incomingDir,
      }),
    ).toThrow(/relative path/);
  });

  test("rejects a dir with a .. segment", () => {
    const home = tmp();
    const cwd = join(home, "work");
    const incomingDir = join(home, "incoming");

    expect(() =>
      stageBundle({ dir: "../proto", entry: "index.html", cwd, incomingDir }),
    ).toThrow(/"\.\."/);
  });

  test("rejects an absolute entry", () => {
    const home = tmp();
    const cwd = join(home, "work");
    const incomingDir = join(home, "incoming");
    write(join(cwd, "proto", "index.html"), "ok");

    expect(() =>
      stageBundle({
        dir: "proto",
        entry: join(cwd, "proto", "index.html"),
        cwd,
        incomingDir,
      }),
    ).toThrow(/relative path/);
  });

  test("rejects an entry with a .. segment", () => {
    const home = tmp();
    const cwd = join(home, "work");
    const incomingDir = join(home, "incoming");
    write(join(cwd, "proto", "index.html"), "ok");

    expect(() =>
      stageBundle({ dir: "proto", entry: "../secret.html", cwd, incomingDir }),
    ).toThrow(/"\.\."/);
  });

  test("rejects a missing entry", () => {
    const home = tmp();
    const cwd = join(home, "work");
    const incomingDir = join(home, "incoming");
    write(join(cwd, "proto", "index.html"), "ok");

    expect(() =>
      stageBundle({ dir: "proto", entry: "missing.html", cwd, incomingDir }),
    ).toThrow(/does not exist/);
  });

  test("rejects a directory entry", () => {
    const home = tmp();
    const cwd = join(home, "work");
    const incomingDir = join(home, "incoming");
    mkdirSync(join(cwd, "proto", "pages"), { recursive: true });

    expect(() =>
      stageBundle({ dir: "proto", entry: "pages", cwd, incomingDir }),
    ).toThrow(/not a file/);
  });

  test("rejects a symlink entry", () => {
    const home = tmp();
    const cwd = join(home, "work");
    const incomingDir = join(home, "incoming");
    write(join(cwd, "proto", "index.html"), "ok");
    symlinkSync(join(cwd, "proto", "index.html"), join(cwd, "proto", "entry.html"));

    expect(() =>
      stageBundle({ dir: "proto", entry: "entry.html", cwd, incomingDir }),
    ).toThrow(/must not be a symlink/);
  });

  test("rejects a bundle with more than 2000 files", () => {
    const home = tmp();
    const cwd = join(home, "work");
    const incomingDir = join(home, "incoming");
    mkdirSync(join(cwd, "many"), { recursive: true });
    for (let i = 0; i <= MAX_BUNDLE_FILES; i++) {
      writeFileSync(join(cwd, "many", `${i}.txt`), "x");
    }

    expect(() =>
      stageBundle({ dir: "many", entry: "0.txt", cwd, incomingDir }),
    ).toThrow(/more than 2000 files/);
    expect(existsSync(incomingDir)).toBe(false);
  });

  test("rejects a bundle larger than 50 MB", () => {
    const home = tmp();
    const cwd = join(home, "work");
    const incomingDir = join(home, "incoming");
    mkdirSync(join(cwd, "big"), { recursive: true });
    writeFileSync(join(cwd, "big", "big.bin"), Buffer.alloc(MAX_BUNDLE_BYTES + 1));

    expect(() =>
      stageBundle({ dir: "big", entry: "big.bin", cwd, incomingDir }),
    ).toThrow(/larger than 50 MB/);
    expect(existsSync(incomingDir)).toBe(false);
  });

  test("changing or deleting the source after staging does not change the incoming copy", () => {
    const home = tmp();
    const cwd = join(home, "work");
    const incomingDir = join(home, "incoming");
    const src = join(cwd, "proto");
    write(join(src, "index.html"), "<h1>v1</h1>");
    write(join(src, "app.js"), "let v = 1;");

    const staged = stageBundle({
      dir: "proto",
      entry: "index.html",
      cwd,
      incomingDir,
    });

    writeFileSync(join(src, "index.html"), "<h1>v2</h1>");
    rmSync(join(src, "app.js"));

    expect(readFileSync(join(staged.path, "index.html"), "utf8")).toBe("<h1>v1</h1>");
    expect(readFileSync(join(staged.path, "app.js"), "utf8")).toBe("let v = 1;");
  });

  // HAIL-49: an html_bundle may declare a viewport and/or a preview file for
  // the case pane's card. Both are optional and pass through unchanged when
  // valid; preview is re-checked with the same path rules as entry.
  test("passes viewport through unchanged", () => {
    const home = tmp();
    const cwd = join(home, "work");
    const incomingDir = join(home, "incoming");
    write(join(cwd, "proto", "index.html"), "<h1>Hello</h1>");

    const staged = stageBundle({
      dir: "proto",
      entry: "index.html",
      cwd,
      incomingDir,
      viewport: { width: 390, height: 844 },
    });

    expect(staged.viewport).toEqual({ width: 390, height: 844 });
    expect(staged.preview).toBeUndefined();
  });

  test("accepts a preview.html file inside the bundle", () => {
    const home = tmp();
    const cwd = join(home, "work");
    const incomingDir = join(home, "incoming");
    write(join(cwd, "proto", "index.html"), "<h1>Hello</h1>");
    write(join(cwd, "proto", "preview.html"), "<h1>Summary</h1>");

    const staged = stageBundle({
      dir: "proto",
      entry: "index.html",
      cwd,
      incomingDir,
      preview: "preview.html",
    });

    expect(staged.preview).toBe("preview.html");
    expect(readFileSync(join(staged.path, "preview.html"), "utf8")).toBe("<h1>Summary</h1>");
  });

  test("accepts a preview.png file inside the bundle", () => {
    const home = tmp();
    const cwd = join(home, "work");
    const incomingDir = join(home, "incoming");
    write(join(cwd, "proto", "index.html"), "<h1>Hello</h1>");
    write(join(cwd, "proto", "preview.png"), pngBytes());

    const staged = stageBundle({
      dir: "proto",
      entry: "index.html",
      cwd,
      incomingDir,
      preview: "preview.png",
    });

    expect(staged.preview).toBe("preview.png");
  });

  test("rejects a preview outside the bundle dir", () => {
    const home = tmp();
    const cwd = join(home, "work");
    const incomingDir = join(home, "incoming");
    write(join(cwd, "proto", "index.html"), "ok");
    write(join(cwd, "outside.html"), "<h1>Outside</h1>");

    expect(() =>
      stageBundle({ dir: "proto", entry: "index.html", cwd, incomingDir, preview: "../outside.html" }),
    ).toThrow(/"\.\."/);
  });

  test("rejects an absolute preview path", () => {
    const home = tmp();
    const cwd = join(home, "work");
    const incomingDir = join(home, "incoming");
    write(join(cwd, "proto", "index.html"), "ok");

    expect(() =>
      stageBundle({
        dir: "proto",
        entry: "index.html",
        cwd,
        incomingDir,
        preview: join(cwd, "proto", "preview.html"),
      }),
    ).toThrow(/relative path/);
  });

  test("rejects a preview with an unknown extension", () => {
    const home = tmp();
    const cwd = join(home, "work");
    const incomingDir = join(home, "incoming");
    write(join(cwd, "proto", "index.html"), "ok");
    write(join(cwd, "proto", "preview.gif"), "not really a gif");

    expect(() =>
      stageBundle({ dir: "proto", entry: "index.html", cwd, incomingDir, preview: "preview.gif" }),
    ).toThrow(/\.html, \.png, or \.jpg/);
  });

  test("rejects a missing preview file", () => {
    const home = tmp();
    const cwd = join(home, "work");
    const incomingDir = join(home, "incoming");
    write(join(cwd, "proto", "index.html"), "ok");

    expect(() =>
      stageBundle({ dir: "proto", entry: "index.html", cwd, incomingDir, preview: "preview.html" }),
    ).toThrow(/does not exist/);
  });

  test("rejects a symlinked preview file", () => {
    const home = tmp();
    const cwd = join(home, "work");
    const incomingDir = join(home, "incoming");
    write(join(cwd, "proto", "index.html"), "ok");
    write(join(cwd, "proto", "real.html"), "<h1>Real</h1>");
    symlinkSync(join(cwd, "proto", "real.html"), join(cwd, "proto", "preview.html"));

    expect(() =>
      stageBundle({ dir: "proto", entry: "index.html", cwd, incomingDir, preview: "preview.html" }),
    ).toThrow(/must not be a symlink/);
  });

  test("rejects a directory as the preview", () => {
    const home = tmp();
    const cwd = join(home, "work");
    const incomingDir = join(home, "incoming");
    write(join(cwd, "proto", "index.html"), "ok");
    mkdirSync(join(cwd, "proto", "preview.html"), { recursive: true });

    expect(() =>
      stageBundle({ dir: "proto", entry: "index.html", cwd, incomingDir, preview: "preview.html" }),
    ).toThrow(/not a file/);
  });

  test("stages the checkout-proto fixture with no external URLs", () => {
    const home = tmp();
    const incomingDir = join(home, "incoming");
    const cwd = import.meta.dir;
    const fixture = join(cwd, "fixtures", "checkout-proto");

    const staged = stageBundle({
      dir: "fixtures/checkout-proto",
      entry: "index.html",
      cwd,
      incomingDir,
    });

    expect(staged.entry).toBe("index.html");
    for (const name of ["index.html", "style.css", "app.js"]) {
      const source = readFileSync(join(fixture, name), "utf8");
      const copy = readFileSync(join(staged.path, name), "utf8");
      expect(copy).toBe(source);
      expect(source).not.toMatch(/https?:\/\//);
    }
  });
});

// The daemon-side ingest keeps the read-only and content-addressing behaviour;
// that is covered in test/incoming.test.ts.
