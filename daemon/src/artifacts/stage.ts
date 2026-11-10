import { randomUUID } from "node:crypto";
import {
  chmodSync,
  copyFileSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { basename, extname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { CodedError } from "../protocol/error-codes";

// Hard limits from docs/protocol-mvp.md "Artifacts". A screenshot is at most
// 20 MB. A bundle is at most 50 MB and 2000 files. A markdown artifact
// (HAIL-33) is at most 1 MB.
export const MAX_SCREENSHOT_BYTES = 20 * 1024 * 1024;
export const MAX_BUNDLE_BYTES = 50 * 1024 * 1024;
export const MAX_BUNDLE_FILES = 2000;
export const MAX_MARKDOWN_BYTES = 1 * 1024 * 1024;
export const MAX_DIAGRAM_BYTES = 512 * 1024;

const PNG_SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

// A staging failure. The message tells the caller (eventually the agent) what
// to fix. No partial copy is left behind (see stageBundle).
export class ArtifactError extends CodedError {
  constructor(message: string, code: string) {
    super(message, code);
    this.name = "ArtifactError";
  }
}

export type ScreenshotExt = "png" | "jpg";

// The shim stages an artifact into KNOCK_HOME/incoming/<uuid>/. This is the
// only place a path resolves against the agent's cwd: the daemon never reads
// the agent's project folder (HAIL-26). The daemon later re-validates and
// moves the incoming copy into blobs/ or bundles/ (see ingest.ts).

export interface StageScreenshotInput {
  path: string;
  cwd: string;
  incomingDir: string;
}

export interface StageBundleInput {
  dir: string;
  entry: string;
  cwd: string;
  incomingDir: string;
  viewport?: { width: number; height: number };
  preview?: string;
}

export interface StageMarkdownInput {
  path: string;
  cwd: string;
  incomingDir: string;
}

export interface StageScreenshotsInput {
  items: { path?: string; data_base64?: string; caption?: string; item?: string }[];
  cwd: string;
  incomingDir: string;
}

export interface StagedIncomingScreenshot {
  kind: "screenshot";
  ext: ScreenshotExt;
  path: string;
}

export interface StagedIncomingBundle {
  kind: "html_bundle";
  path: string;
  entry: string;
  viewport?: { width: number; height: number };
  preview?: string;
}

export interface StagedIncomingMarkdown {
  kind: "markdown";
  path: string;
}

export interface StagedIncomingScreenshotsItem {
  path: string;
  caption?: string;
  item?: string;
}

export interface StagedIncomingScreenshots {
  kind: "screenshots";
  items: StagedIncomingScreenshotsItem[];
}

export interface StageDiagramInput {
  path: string;
  cwd: string;
  incomingDir: string;
}

export interface StagedIncomingDiagram {
  kind: "diagram";
  ext: DiagramExt;
  path: string;
}

// Copies one screenshot into incoming/<uuid>/shot.<ext>. The source path
// resolves against cwd (absolute paths are accepted: the agent may hand back an
// absolute screenshot path). Every validation rule from docs/protocol-mvp.md is
// applied here, in the shim, before the daemon ever sees the path.
export function stageScreenshot(input: StageScreenshotInput): StagedIncomingScreenshot {
  const source = resolve(input.cwd, input.path);

  let stat;
  try {
    stat = statSync(source);
  } catch (err) {
    throw new ArtifactError(`screenshot cannot be read: ${(err as Error).message}`, "file_unreadable");
  }
  if (!stat.isFile()) {
    throw new ArtifactError("screenshot is not a regular file", "not_regular_file");
  }
  if (stat.size > MAX_SCREENSHOT_BYTES) {
    throw new ArtifactError("screenshot is larger than 20 MB", "too_large");
  }

  let data: Buffer;
  try {
    data = readFileSync(source);
  } catch (err) {
    throw new ArtifactError(`screenshot cannot be read: ${(err as Error).message}`, "file_unreadable");
  }

  const ext = screenshotExt(input.path, data);
  const dir = join(input.incomingDir, randomUUID());
  mkdirSync(dir, { recursive: true });
  const dest = join(dir, `shot.${ext}`);
  writeFileSync(dest, data);
  return { kind: "screenshot", ext, path: dest };
}

// Copies one markdown file into incoming/<uuid>/note.md (HAIL-33). Staged the
// same way as a screenshot: resolved against cwd, size-checked, copied before
// the daemon ever sees the path.
export function stageMarkdown(input: StageMarkdownInput): StagedIncomingMarkdown {
  const source = resolve(input.cwd, input.path);

  let stat;
  try {
    stat = statSync(source);
  } catch (err) {
    throw new ArtifactError(`markdown cannot be read: ${(err as Error).message}`, "file_unreadable");
  }
  if (!stat.isFile()) {
    throw new ArtifactError("markdown is not a regular file", "not_regular_file");
  }
  if (stat.size > MAX_MARKDOWN_BYTES) {
    throw new ArtifactError("markdown is larger than 1 MB", "too_large");
  }
  const ext = extname(basename(input.path)).toLowerCase();
  if (ext !== ".md" && ext !== ".markdown") {
    throw new ArtifactError("markdown must be a .md or .markdown file", "markdown_bad_extension");
  }

  let data: Buffer;
  try {
    data = readFileSync(source);
  } catch (err) {
    throw new ArtifactError(`markdown cannot be read: ${(err as Error).message}`, "file_unreadable");
  }

  const dir = join(input.incomingDir, randomUUID());
  mkdirSync(dir, { recursive: true });
  const dest = join(dir, "note.md");
  writeFileSync(dest, data);
  return { kind: "markdown", path: dest };
}

// Copies one diagram file into incoming/<uuid>/diagram.<ext> (HAIL-141). Staged
// the same way as markdown: resolved against cwd, extension-checked (.mmd or
// .svg only), size-checked (at most 512 KB) and copied before the daemon ever
// sees the path. The source content is not parsed here - the app renders it.
export function stageDiagram(input: StageDiagramInput): StagedIncomingDiagram {
  const source = resolve(input.cwd, input.path);

  let stat;
  try {
    stat = statSync(source);
  } catch (err) {
    throw new ArtifactError(`diagram cannot be read: ${(err as Error).message}`, "file_unreadable");
  }
  if (!stat.isFile()) {
    throw new ArtifactError("diagram is not a regular file", "not_regular_file");
  }
  if (stat.size > MAX_DIAGRAM_BYTES) {
    throw new ArtifactError("diagram is larger than 512 KB", "too_large");
  }
  const ext = diagramExt(input.path);

  let data: Buffer;
  try {
    data = readFileSync(source);
  } catch (err) {
    throw new ArtifactError(`diagram cannot be read: ${(err as Error).message}`, "file_unreadable");
  }

  const dir = join(input.incomingDir, randomUUID());
  mkdirSync(dir, { recursive: true });
  const dest = join(dir, `diagram.${ext}`);
  writeFileSync(dest, data);
  return { kind: "diagram", ext, path: dest };
}

// --- Inline content (HAIL-163) ---
//
// A client with no project folder (the Claude desktop app, Cowork) sends the artifact itself. These
// stage it into the same incoming/<uuid>/ shape a path produces, with the same size limits, so the
// daemon cannot tell the two apart. The limit for base64 is the screenshot limit applied to the
// decoded bytes (20 MB); the encoded text may be a third larger.

export interface StageMarkdownContentInput {
  content: string;
  incomingDir: string;
}

export function stageMarkdownContent(input: StageMarkdownContentInput): StagedIncomingMarkdown {
  if (Buffer.byteLength(input.content, "utf8") > MAX_MARKDOWN_BYTES) {
    throw new ArtifactError("markdown is larger than 1 MB", "too_large");
  }
  const dir = join(input.incomingDir, randomUUID());
  mkdirSync(dir, { recursive: true });
  const dest = join(dir, "note.md");
  writeFileSync(dest, input.content);
  return { kind: "markdown", path: dest };
}

export interface StageBundleHtmlInput {
  html: string;
  incomingDir: string;
  viewport?: { width: number; height: number };
}

// One HTML string becomes a bundle of one file, index.html.
export function stageBundleHtml(input: StageBundleHtmlInput): StagedIncomingBundle {
  if (input.html.trim() === "") throw new ArtifactError("html must not be empty", "html_empty");
  if (Buffer.byteLength(input.html, "utf8") > MAX_BUNDLE_BYTES) {
    throw new ArtifactError("bundle is larger than 50 MB", "too_large");
  }
  const dest = join(input.incomingDir, randomUUID());
  mkdirSync(dest, { recursive: true });
  writeFileSync(join(dest, "index.html"), input.html);
  return {
    kind: "html_bundle",
    path: dest,
    entry: "index.html",
    ...(input.viewport !== undefined ? { viewport: input.viewport } : {}),
  };
}

// Decodes base64 image data and checks it is a PNG or JPEG, under the screenshot size limit.
// `label` is "screenshot" or "screenshot 2", so errors read like the path form's.
export function decodeScreenshotBase64(data: string, label = "screenshot"): { data: Buffer; ext: ScreenshotExt } {
  const text = data.replace(/^data:image\/[a-z]+;base64,/i, "").replace(/\s+/g, "");
  if (text === "" || !/^[A-Za-z0-9+/]*={0,2}$/.test(text) || text.length % 4 === 1) {
    throw new ArtifactError(`${label} is not valid base64`, "invalid_base64");
  }
  const bytes = Buffer.from(text, "base64");
  if (bytes.length > MAX_SCREENSHOT_BYTES) throw new ArtifactError(`${label} is larger than 20 MB`, "too_large");
  if (bytes.length >= 8 && bytes.subarray(0, 8).equals(PNG_SIGNATURE)) return { data: bytes, ext: "png" };
  if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) {
    return { data: bytes, ext: "jpg" };
  }
  throw new ArtifactError(`${label} is not a PNG or JPEG image`, "not_png_or_jpeg");
}

export interface StageScreenshotBase64Input {
  data_base64: string;
  incomingDir: string;
}

export function stageScreenshotBase64(input: StageScreenshotBase64Input): StagedIncomingScreenshot {
  const { data, ext } = decodeScreenshotBase64(input.data_base64);
  const dir = join(input.incomingDir, randomUUID());
  mkdirSync(dir, { recursive: true });
  const dest = join(dir, `shot.${ext}`);
  writeFileSync(dest, data);
  return { kind: "screenshot", ext, path: dest };
}

// Copies 2 to 12 screenshots into one incoming/<uuid>/ directory, as
// shot-1.<ext> .. shot-N.<ext> in the given order (HAIL-40). Every item is
// resolved and validated (same rules as stageScreenshot) before anything is
// written, so a rejected item leaves no partial incoming copy - the same
// two-pass shape as stageBundle.
export function stageScreenshots(input: StageScreenshotsInput): StagedIncomingScreenshots {
  const validated = input.items.map((item, i) => {
    if (item.data_base64 !== undefined) {
      try {
        const { data, ext } = decodeScreenshotBase64(item.data_base64, `screenshot ${i + 1}`);
        return { data, ext, caption: item.caption, item: item.item };
      } catch (err) {
        throw err instanceof ArtifactError ? err : itemError(i, err as ArtifactError);
      }
    }
    if (item.path === undefined) throw new ArtifactError(`screenshot ${i + 1} needs a path or data_base64`, "screenshot_source_missing");
    const itemPath = item.path;
    const source = resolve(input.cwd, itemPath);
    let stat;
    try {
      stat = statSync(source);
    } catch (err) {
      throw new ArtifactError(`screenshot ${i + 1} cannot be read: ${(err as Error).message}`, "file_unreadable");
    }
    if (!stat.isFile()) {
      throw new ArtifactError(`screenshot ${i + 1} is not a regular file`, "not_regular_file");
    }
    if (stat.size > MAX_SCREENSHOT_BYTES) {
      throw new ArtifactError(`screenshot ${i + 1} is larger than 20 MB`, "too_large");
    }
    let data: Buffer;
    try {
      data = readFileSync(source);
    } catch (err) {
      throw new ArtifactError(`screenshot ${i + 1} cannot be read: ${(err as Error).message}`, "file_unreadable");
    }
    let ext: ScreenshotExt;
    try {
      ext = screenshotExt(itemPath, data);
    } catch (err) {
      throw itemError(i, err as ArtifactError);
    }
    return { data, ext, caption: item.caption, item: item.item };
  });

  const dir = join(input.incomingDir, randomUUID());
  mkdirSync(dir, { recursive: true });
  const items: StagedIncomingScreenshotsItem[] = validated.map((v, i) => {
    const dest = join(dir, `shot-${i + 1}.${v.ext}`);
    writeFileSync(dest, v.data);
    return {
      path: dest,
      ...(v.caption !== undefined ? { caption: v.caption } : {}),
      ...(v.item !== undefined ? { item: v.item } : {}),
    };
  });
  return { kind: "screenshots", items };
}

// Copies one HTML bundle directory into incoming/<uuid>/. The copy is validated
// against every rule from docs/protocol-mvp.md (relative paths only, no
// symlinks, entry present, file-count and size limits) before anything is
// written, so a rejection never leaves a partial incoming copy.
export function stageBundle(input: StageBundleInput): StagedIncomingBundle {
  const dir = validateRelativePath(input.dir, "bundle dir");
  const entry = validateRelativePath(input.entry, "bundle entry");

  const source = resolve(input.cwd, dir);

  let srcStat;
  try {
    srcStat = lstatSync(source);
  } catch {
    throw new ArtifactError(`bundle dir not found: ${input.dir}`, "bundle_dir_not_found");
  }
  if (srcStat.isSymbolicLink()) {
    throw new ArtifactError("bundle dir must not be a symlink", "bundle_dir_symlink");
  }
  if (!srcStat.isDirectory()) {
    throw new ArtifactError("bundle dir is not a directory", "bundle_dir_not_directory");
  }

  // The entry must resolve inside the dir and be a regular file, not a symlink.
  const entryAbs = resolve(source, entry);
  if (entryAbs !== source && !entryAbs.startsWith(source + sep)) {
    throw new ArtifactError("bundle entry is outside the bundle dir", "bundle_entry_outside");
  }
  let entryStat;
  try {
    entryStat = lstatSync(entryAbs);
  } catch {
    throw new ArtifactError(`bundle entry does not exist: ${input.entry}`, "bundle_entry_missing");
  }
  if (entryStat.isSymbolicLink()) {
    throw new ArtifactError("bundle entry must not be a symlink", "bundle_entry_symlink");
  }
  if (!entryStat.isFile()) {
    throw new ArtifactError("bundle entry is not a file", "bundle_entry_not_file");
  }

  // preview (HAIL-49): same path rules as entry - must resolve inside dir, no
  // symlink, must be a regular file, and its extension decides how Waggle
  // renders it (previewKind throws for anything else).
  const preview = input.preview !== undefined ? validateRelativePath(input.preview, "preview") : undefined;
  if (preview !== undefined) {
    const previewAbs = resolve(source, preview);
    if (previewAbs !== source && !previewAbs.startsWith(source + sep)) {
      throw new ArtifactError("preview is outside the bundle dir", "preview_outside");
    }
    let previewStat;
    try {
      previewStat = lstatSync(previewAbs);
    } catch {
      throw new ArtifactError(`preview does not exist: ${input.preview}`, "preview_missing");
    }
    if (previewStat.isSymbolicLink()) {
      throw new ArtifactError("preview must not be a symlink", "preview_symlink");
    }
    if (!previewStat.isFile()) {
      throw new ArtifactError("preview is not a file", "preview_not_file");
    }
    previewKind(preview);
  }

  // First pass over the tree: reject symlinks and check the size and file
  // count limits before copying anything.
  countTree(source);

  const dest = join(input.incomingDir, randomUUID());
  copyTree(source, dest);

  return {
    kind: "html_bundle",
    path: dest,
    entry,
    ...(input.viewport !== undefined ? { viewport: input.viewport } : {}),
    ...(preview !== undefined ? { preview } : {}),
  };
}

// The kind of a preview file (HAIL-49), from its extension: "html" for
// `.html` (Waggle renders it, like `entry`), "image" for `.png`/`.jpg`/`.jpeg`
// (shown as is). Any other extension is rejected.
export function previewKind(path: string): "html" | "image" {
  const ext = extname(basename(path)).toLowerCase();
  if (ext === ".html") return "html";
  if (ext === ".png" || ext === ".jpg" || ext === ".jpeg") return "image";
  throw new ArtifactError(`preview must be a .html, .png, or .jpg file: ${path}`, "preview_bad_extension");
}

// A relative path with no absolute form and no ".." segment. Empty and "."
// segments are dropped; ".." is rejected rather than collapsed so it can never
// escape the bundle dir.
export function validateRelativePath(value: string, label: string): string {
  if (value === "") {
    throw new ArtifactError(`${label} must not be empty`, "path_empty");
  }
  if (isAbsolute(value)) {
    throw new ArtifactError(`${label} must be a relative path: ${value}`, "path_not_relative");
  }
  const parts = value.split("/").filter((part) => part !== "" && part !== ".");
  if (parts.length === 0) {
    throw new ArtifactError(`${label} must not be empty`, "path_empty");
  }
  if (parts.includes("..")) {
    throw new ArtifactError(`${label} must not contain "..": ${value}`, "path_traversal");
  }
  return parts.join("/");
}

export type DiagramExt = "mmd" | "svg";

// The extension of a diagram file (HAIL-141): .mmd (Mermaid source) or .svg.
// Rejected for anything else, before the content is even read.
export function diagramExt(path: string): DiagramExt {
  const ext = extname(basename(path)).toLowerCase();
  if (ext === ".mmd") return "mmd";
  if (ext === ".svg") return "svg";
  throw new ArtifactError("diagram must be a .mmd or .svg file", "diagram_bad_extension");
}

export function screenshotExt(path: string, data: Buffer): ScreenshotExt {
  const ext = extname(basename(path)).toLowerCase();
  if (ext === ".png") {
    if (data.length < 8 || !data.subarray(0, 8).equals(PNG_SIGNATURE)) {
      throw new ArtifactError("screenshot is not a PNG image", "screenshot_not_png");
    }
    return "png";
  }
  if (ext === ".jpg" || ext === ".jpeg") {
    if (data.length < 3 || data[0] !== 0xff || data[1] !== 0xd8 || data[2] !== 0xff) {
      throw new ArtifactError("screenshot is not a JPEG image", "screenshot_not_jpeg");
    }
    return "jpg";
  }
  throw new ArtifactError("screenshot must be a .png or .jpg file", "screenshot_bad_extension");
}

// Rewrites a per-screenshot error ("screenshot is not a PNG image") into a
// per-item one ("screenshot 2 is not a PNG image"), for a screenshots
// artifact's stage/ingest loop (HAIL-40).
export function itemMessage(index: number, err: Error): string {
  return err.message.replace(/^screenshot\b/, `screenshot ${index + 1}`);
}

// The same error for item `index`, with the code kept.
export function itemError(index: number, err: Error): ArtifactError {
  return new ArtifactError(itemMessage(index, err), (err as Partial<CodedError>).errorCode ?? "artifact_invalid");
}

// Walks the tree once to count regular files and total bytes, rejecting
// symlinks and unsupported entries. Fails fast on the size and count limits.
export function countTree(root: string): { files: number; bytes: number } {
  let files = 0;
  let bytes = 0;
  visit(root);
  return { files, bytes };

  function visit(dir: string): void {
    let entries;
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch (err) {
      throw new ArtifactError(`bundle dir cannot be read: ${(err as Error).message}`, "bundle_dir_unreadable");
    }
    for (const entry of entries) {
      const abs = join(dir, entry.name);
      const st = lstatSync(abs);
      if (st.isSymbolicLink()) {
        throw new ArtifactError(`bundle must not contain symlinks: ${relative(root, abs)}`, "bundle_symlink");
      }
      if (st.isDirectory()) {
        visit(abs);
      } else if (st.isFile()) {
        files += 1;
        bytes += st.size;
        if (files > MAX_BUNDLE_FILES) {
          throw new ArtifactError(`bundle has more than ${MAX_BUNDLE_FILES} files`, "bundle_too_many_files");
        }
        if (bytes > MAX_BUNDLE_BYTES) {
          throw new ArtifactError("bundle is larger than 50 MB", "too_large");
        }
      } else {
        throw new ArtifactError(`bundle contains an unsupported entry: ${relative(root, abs)}`, "bundle_unsupported_entry");
      }
    }
  }
}

// Recursive copy that never follows symlinks. Re-checks each entry with lstat
// so an entry that became a symlink after countTree is still rejected.
export function copyTree(src: string, dest: string): void {
  const st = lstatSync(src);
  if (st.isSymbolicLink()) {
    throw new ArtifactError(`bundle must not contain symlinks: ${src}`, "bundle_symlink");
  }
  if (st.isDirectory()) {
    mkdirSync(dest, { recursive: true });
    for (const entry of readdirSync(src)) {
      copyTree(join(src, entry), join(dest, entry));
    }
  } else if (st.isFile()) {
    copyFileSync(src, dest);
  } else {
    throw new ArtifactError(`bundle contains an unsupported entry: ${src}`, "bundle_unsupported_entry");
  }
}

// Removes every write bit (chmod a-w) from the tree, deepest first.
export function makeReadOnly(root: string): void {
  const st = lstatSync(root);
  if (st.isDirectory()) {
    for (const entry of readdirSync(root)) {
      makeReadOnly(join(root, entry));
    }
  }
  chmodSync(root, st.mode & ~0o222);
}
