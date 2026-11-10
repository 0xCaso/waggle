import { createHash } from "node:crypto";
import {
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  realpathSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { dirname, isAbsolute, join, resolve, sep } from "node:path";
import type { Artifact } from "../protocol";
import {
  ArtifactError,
  countTree,
  diagramExt,
  itemError,
  makeReadOnly,
  MAX_DIAGRAM_BYTES,
  MAX_MARKDOWN_BYTES,
  MAX_SCREENSHOT_BYTES,
  previewKind,
  screenshotExt,
  validateRelativePath,
  type DiagramExt,
  type ScreenshotExt,
} from "./stage";
export { ArtifactError } from "./stage";

// The daemon half of artifact staging (HAIL-26). The shim already resolved and
// validated the artifact against the agent's cwd and copied it into
// KNOCK_HOME/incoming/<uuid>/. Here the daemon re-validates that incoming copy
// with the same rules, moves it into blobs/ or bundles/, makes it read-only and
// removes the incoming directory. It never opens, stats or reads a path outside
// KNOCK_HOME/incoming/.

export const INCOMING_DIR_NAME = "incoming";

export function incomingDir(dataRoot: string): string {
  return join(dataRoot, INCOMING_DIR_NAME);
}

export interface StagedScreenshot {
  kind: "screenshot";
  sha256: string;
  ext: ScreenshotExt;
  path: string;
}

export interface StagedBundle {
  kind: "html_bundle";
  path: string;
  entry: string;
  viewport?: { width: number; height: number };
  preview?: string;
}

export interface StagedMarkdown {
  kind: "markdown";
  sha256: string;
  path: string;
}

export interface StagedDiagram {
  kind: "diagram";
  sha256: string;
  ext: DiagramExt;
  path: string;
}

export interface StagedScreenshotsItem {
  sha256: string;
  ext: ScreenshotExt;
  caption?: string;
  item?: string;
}

export interface StagedScreenshots {
  kind: "screenshots";
  items: StagedScreenshotsItem[];
}

// An artifact whose screenshot path / bundle dir / markdown path has been
// resolved to a real absolute path inside KNOCK_HOME/incoming/.
export type IncomingArtifact =
  | { type: "screenshot"; path: string }
  | {
      type: "html_bundle";
      dir: string;
      entry: string;
      viewport?: { width: number; height: number };
      preview?: string;
    }
  | { type: "markdown"; path: string }
  | { type: "diagram"; path: string }
  | { type: "screenshots"; items: { path: string; caption?: string; item?: string }[] };

export const NOT_STAGED_BY_SHIM =
  "artifact must be staged by the shim; restart the session so the connector picks up the updated shim";

// Checks that an artifact's path is inside KNOCK_HOME/incoming/. A relative
// path (an old 0.1.0 shim sends one) is rejected without touching the
// filesystem; an absolute path is realpath'd so a ".." or symlink cannot
// escape the incoming directory. The daemon therefore never stats a path
// outside its data root.
export function resolveIncoming(artifact: Artifact, dataRoot: string): IncomingArtifact {
  const root = incomingDir(dataRoot);
  if (artifact.type === "screenshot") {
    return { type: "screenshot", path: realIncomingPath(artifact.path, root) };
  }
  if (artifact.type === "markdown") {
    return { type: "markdown", path: realIncomingPath(artifact.path, root) };
  }
  if (artifact.type === "diagram") {
    return { type: "diagram", path: realIncomingPath(artifact.path, root) };
  }
  if (artifact.type === "screenshots") {
    return {
      type: "screenshots",
      items: artifact.items.map((item) => ({
        path: realIncomingPath(item.path, root),
        ...(item.caption !== undefined ? { caption: item.caption } : {}),
        ...(item.item !== undefined ? { item: item.item } : {}),
      })),
    };
  }
  if (artifact.entry === undefined) throw new ArtifactError(NOT_STAGED_BY_SHIM, "not_staged_by_shim");
  return {
    type: "html_bundle",
    dir: realIncomingPath(artifact.dir, root),
    entry: artifact.entry,
    ...(artifact.viewport !== undefined ? { viewport: artifact.viewport } : {}),
    ...(artifact.preview !== undefined ? { preview: artifact.preview } : {}),
  };
}

function realIncomingPath(value: string | undefined, root: string): string {
  // HAIL-163: inline content (content, data_base64, html) is staged by the shim into a path; a call
  // that still carries content did not come through the shim.
  if (value === undefined || !isAbsolute(value) || !(value === root || value.startsWith(root + sep))) {
    throw new ArtifactError(NOT_STAGED_BY_SHIM, "not_staged_by_shim");
  }
  // Realpath both sides: macOS resolves /var to /private/var, so a lexical
  // prefix check alone would reject a valid incoming path.
  let real: string;
  let realRoot: string;
  try {
    real = realpathSync(value);
    realRoot = realpathSync(root);
  } catch {
    throw new ArtifactError(NOT_STAGED_BY_SHIM, "not_staged_by_shim");
  }
  if (real !== realRoot && !real.startsWith(realRoot + sep)) {
    throw new ArtifactError(NOT_STAGED_BY_SHIM, "not_staged_by_shim");
  }
  return real;
}

// Re-validates the incoming screenshot and moves it into content-addressed
// storage at blobs/<sha256>.<ext>, then removes the incoming/<uuid> directory.
export function ingestScreenshot(input: {
  incomingPath: string;
  blobsDir: string;
}): StagedScreenshot {
  const { incomingPath, blobsDir } = input;
  const uuidDir = dirname(incomingPath);
  try {
    let data: Buffer;
    try {
      data = readFileSync(incomingPath);
    } catch (err) {
      throw new ArtifactError(`screenshot cannot be read: ${(err as Error).message}`, "file_unreadable");
    }
    if (data.length > MAX_SCREENSHOT_BYTES) {
      throw new ArtifactError("screenshot is larger than 20 MB", "too_large");
    }
    const ext = screenshotExt(incomingPath, data);
    const sha256 = createHash("sha256").update(data).digest("hex");
    const dest = join(blobsDir, `${sha256}.${ext}`);
    mkdirSync(blobsDir, { recursive: true });
    if (!existsSync(dest)) {
      try {
        writeFileSync(dest, data, { flag: "wx" });
      } catch (err) {
        // Another ingest wrote the same content first: that is fine, keep it.
        if ((err as { code?: string }).code !== "EEXIST") throw err;
      }
    }
    return { kind: "screenshot", sha256, ext, path: dest };
  } finally {
    rmSync(uuidDir, { recursive: true, force: true });
  }
}

// Re-validates the incoming markdown file and moves it into content-addressed
// storage at blobs/<sha256>.md (HAIL-33), then removes the incoming/<uuid>
// directory. Staged the same way as a screenshot.
export function ingestMarkdown(input: {
  incomingPath: string;
  blobsDir: string;
}): StagedMarkdown {
  const { incomingPath, blobsDir } = input;
  const uuidDir = dirname(incomingPath);
  try {
    let data: Buffer;
    try {
      data = readFileSync(incomingPath);
    } catch (err) {
      throw new ArtifactError(`markdown cannot be read: ${(err as Error).message}`, "file_unreadable");
    }
    if (data.length > MAX_MARKDOWN_BYTES) {
      throw new ArtifactError("markdown is larger than 1 MB", "too_large");
    }
    const sha256 = createHash("sha256").update(data).digest("hex");
    const dest = join(blobsDir, `${sha256}.md`);
    mkdirSync(blobsDir, { recursive: true });
    if (!existsSync(dest)) {
      try {
        writeFileSync(dest, data, { flag: "wx" });
      } catch (err) {
        // Another ingest wrote the same content first: that is fine, keep it.
        if ((err as { code?: string }).code !== "EEXIST") throw err;
      }
    }
    return { kind: "markdown", sha256, path: dest };
  } finally {
    rmSync(uuidDir, { recursive: true, force: true });
  }
}

// Re-validates the incoming diagram file and moves it into content-addressed
// storage at blobs/<sha256>.<ext> (HAIL-141), then removes the incoming/<uuid>
// directory. Staged the same way as markdown; the ext is .mmd or .svg.
export function ingestDiagram(input: {
  incomingPath: string;
  blobsDir: string;
}): StagedDiagram {
  const { incomingPath, blobsDir } = input;
  const uuidDir = dirname(incomingPath);
  try {
    let data: Buffer;
    try {
      data = readFileSync(incomingPath);
    } catch (err) {
      throw new ArtifactError(`diagram cannot be read: ${(err as Error).message}`, "file_unreadable");
    }
    if (data.length > MAX_DIAGRAM_BYTES) {
      throw new ArtifactError("diagram is larger than 512 KB", "too_large");
    }
    const ext = diagramExt(incomingPath);
    const sha256 = createHash("sha256").update(data).digest("hex");
    const dest = join(blobsDir, `${sha256}.${ext}`);
    mkdirSync(blobsDir, { recursive: true });
    if (!existsSync(dest)) {
      try {
        writeFileSync(dest, data, { flag: "wx" });
      } catch (err) {
        // Another ingest wrote the same content first: that is fine, keep it.
        if ((err as { code?: string }).code !== "EEXIST") throw err;
      }
    }
    return { kind: "diagram", sha256, ext, path: dest };
  } finally {
    rmSync(uuidDir, { recursive: true, force: true });
  }
}

// Re-validates every incoming screenshot of a screenshots artifact (HAIL-40)
// and moves each into content-addressed storage at blobs/<sha256>.<ext>, in
// order, then removes the shared incoming/<uuid> directory. Mirrors
// ingestScreenshot per item; a rejected item still removes the whole
// incoming/<uuid> dir (nothing partial is left behind).
export function ingestScreenshots(input: {
  items: { path: string; caption?: string; item?: string }[];
  blobsDir: string;
}): StagedScreenshots {
  const { items, blobsDir } = input;
  const uuidDir = dirname(items[0]!.path);
  try {
    const staged = items.map((item, i) => {
      let data: Buffer;
      try {
        data = readFileSync(item.path);
      } catch (err) {
        throw new ArtifactError(`screenshot ${i + 1} cannot be read: ${(err as Error).message}`, "file_unreadable");
      }
      if (data.length > MAX_SCREENSHOT_BYTES) {
        throw new ArtifactError(`screenshot ${i + 1} is larger than 20 MB`, "too_large");
      }
      let ext: ScreenshotExt;
      try {
        ext = screenshotExt(item.path, data);
      } catch (err) {
        throw itemError(i, err as ArtifactError);
      }
      const sha256 = createHash("sha256").update(data).digest("hex");
      const dest = join(blobsDir, `${sha256}.${ext}`);
      mkdirSync(blobsDir, { recursive: true });
      if (!existsSync(dest)) {
        try {
          writeFileSync(dest, data, { flag: "wx" });
        } catch (err) {
          if ((err as { code?: string }).code !== "EEXIST") throw err;
        }
      }
      return {
        sha256,
        ext,
        ...(item.caption !== undefined ? { caption: item.caption } : {}),
        ...(item.item !== undefined ? { item: item.item } : {}),
      };
    });
    return { kind: "screenshots", items: staged };
  } finally {
    rmSync(uuidDir, { recursive: true, force: true });
  }
}

// Re-validates the incoming bundle directory and moves it into
// bundles/<case_id>/r<revision>/, makes it read-only and removes the incoming
// directory (the move empties it). The same rules as the shim: no symlinks, no
// absolute or ".." entry, entry exists, file-count and total-size limits.
export function ingestBundle(input: {
  incomingDir: string;
  entry: string;
  bundlesDir: string;
  caseId: string;
  revision: number;
  viewport?: { width: number; height: number };
  preview?: string;
}): StagedBundle {
  const { incomingDir: src, entry: rawEntry, bundlesDir, caseId, revision, viewport, preview: rawPreview } = input;
  try {
    const entry = validateRelativePath(rawEntry, "bundle entry");

    let srcStat;
    try {
      srcStat = lstatSync(src);
    } catch {
      throw new ArtifactError("bundle dir not found", "bundle_dir_not_found");
    }
    if (srcStat.isSymbolicLink()) {
      throw new ArtifactError("bundle dir must not be a symlink", "bundle_dir_symlink");
    }
    if (!srcStat.isDirectory()) {
      throw new ArtifactError("bundle dir is not a directory", "bundle_dir_not_directory");
    }

    const entryAbs = resolve(src, entry);
    if (entryAbs !== src && !entryAbs.startsWith(src + sep)) {
      throw new ArtifactError("bundle entry is outside the bundle dir", "bundle_entry_outside");
    }
    let entryStat;
    try {
      entryStat = lstatSync(entryAbs);
    } catch {
      throw new ArtifactError(`bundle entry does not exist: ${rawEntry}`, "bundle_entry_missing");
    }
    if (entryStat.isSymbolicLink()) {
      throw new ArtifactError("bundle entry must not be a symlink", "bundle_entry_symlink");
    }
    if (!entryStat.isFile()) {
      throw new ArtifactError("bundle entry is not a file", "bundle_entry_not_file");
    }

    const preview = rawPreview !== undefined ? validateRelativePath(rawPreview, "preview") : undefined;
    if (preview !== undefined) {
      const previewAbs = resolve(src, preview);
      if (previewAbs !== src && !previewAbs.startsWith(src + sep)) {
        throw new ArtifactError("preview is outside the bundle dir", "preview_outside");
      }
      let previewStat;
      try {
        previewStat = lstatSync(previewAbs);
      } catch {
        throw new ArtifactError(`preview does not exist: ${rawPreview}`, "preview_missing");
      }
      if (previewStat.isSymbolicLink()) {
        throw new ArtifactError("preview must not be a symlink", "preview_symlink");
      }
      if (!previewStat.isFile()) {
        throw new ArtifactError("preview is not a file", "preview_not_file");
      }
      previewKind(preview);
    }

    countTree(src);

    const caseDir = join(bundlesDir, caseId);
    mkdirSync(caseDir, { recursive: true });
    const finalDir = join(caseDir, `r${revision}`);
    renameSync(src, finalDir);
    try {
      makeReadOnly(finalDir);
    } catch (err) {
      rmSync(finalDir, { recursive: true, force: true });
      throw err;
    }
    return {
      kind: "html_bundle",
      path: finalDir,
      entry,
      ...(viewport !== undefined ? { viewport } : {}),
      ...(preview !== undefined ? { preview } : {}),
    };
  } finally {
    // On success the rename already emptied the incoming/<uuid> dir; on any
    // failure this removes the still-present incoming copy so nothing leaks.
    rmSync(src, { recursive: true, force: true });
  }
}
