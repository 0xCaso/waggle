import { chmodSync, copyFileSync, lstatSync, mkdirSync, realpathSync, rmSync } from "node:fs";
import { basename, extname, isAbsolute, join, sep } from "node:path";
import { ArtifactError } from "./stage";
import { incomingDir } from "./ingest";

// WAG-345: files a person attaches to a reply. The app stages each file into
// KNOCK_HOME/incoming/<uuid>/<name>. The daemon checks that copy, copies it
// to KNOCK_HOME/attachments/<reply id>/<name>, makes it read-only and gives
// the agent that absolute path. The daemon never reads a path outside its
// data root.
export const MAX_REPLY_ATTACHMENTS = 10;
export const MAX_ATTACHMENT_BYTES = 25 * 1024 * 1024;
export const ATTACHMENTS_DIR_NAME = "attachments";

export interface ReplyAttachmentRecord {
  name: string;
  path: string;
  size: number;
  type: string;
}

// One entry of reply.submit / reply.replace. A new file names its incoming copy. A file the reply
// already holds (reply.replace only) names its stored path.
export interface ReplyAttachmentInput {
  name: string;
  incoming_path?: string;
  path?: string;
  type?: string;
}

export function attachmentsDir(dataRoot: string): string {
  return join(dataRoot, ATTACHMENTS_DIR_NAME);
}

export function replyAttachmentsDir(dataRoot: string, replyId: string): string {
  return join(attachmentsDir(dataRoot), replyId);
}

const MIME_BY_EXT: Record<string, string> = {
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
  ".heic": "image/heic",
  ".svg": "image/svg+xml",
  ".pdf": "application/pdf",
  ".md": "text/markdown",
  ".txt": "text/plain",
  ".csv": "text/csv",
  ".json": "application/json",
  ".html": "text/html",
  ".zip": "application/zip",
  ".mov": "video/quicktime",
  ".mp4": "video/mp4",
  ".mp3": "audio/mpeg",
  ".wav": "audio/wav",
};
const MIME_SHAPE = /^[A-Za-z0-9][A-Za-z0-9.+-]*\/[A-Za-z0-9][A-Za-z0-9.+-]*$/;

// A plain file name: no folder part, no control characters, at most 120 characters.
export function safeAttachmentName(raw: string): string {
  const cleaned = basename(raw.replace(/\\/g, "/"))
    // eslint-disable-next-line no-control-regex
    .replace(/[\u0000-\u001f\u007f]/g, "")
    .trim();
  if (cleaned === "" || cleaned === "." || cleaned === "..") return "file";
  if (cleaned.length <= 120) return cleaned;
  const ext = extname(cleaned).slice(0, 20);
  return cleaned.slice(0, 120 - ext.length) + ext;
}

export function attachmentType(name: string, hint?: string): string {
  if (hint !== undefined && MIME_SHAPE.test(hint)) return hint.toLowerCase();
  return MIME_BY_EXT[extname(name).toLowerCase()] ?? "application/octet-stream";
}

// "a.png", then "a 2.png", "a 3.png" for a name already taken in this reply.
function uniqueName(name: string, taken: Set<string>): string {
  if (!taken.has(name)) return name;
  const ext = extname(name);
  const stem = name.slice(0, name.length - ext.length);
  for (let n = 2; ; n += 1) {
    const candidate = `${stem} ${n}${ext}`;
    if (!taken.has(candidate)) return candidate;
  }
}

function realIncomingFile(value: string, dataRoot: string): string {
  const root = incomingDir(dataRoot);
  const fail = (): never => {
    throw new ArtifactError("attachment must be staged under the Waggle incoming folder", "attachment_not_staged");
  };
  if (!isAbsolute(value)) return fail();
  let real: string;
  let realRoot: string;
  try {
    real = realpathSync(value);
    realRoot = realpathSync(root);
  } catch {
    return fail();
  }
  if (!real.startsWith(realRoot + sep)) return fail();
  return real;
}

export interface IngestedAttachments {
  records: ReplyAttachmentRecord[];
  // The incoming/<uuid> folders the daemon copied from. Remove them once the reply is committed.
  incomingDirs: string[];
}

// Checks every input and copies the new files to attachments/<replyId>/. Throws ArtifactError with the
// copies removed when one input is bad. `existing` is what a queued reply holds now (reply.replace).
export function ingestReplyAttachments(input: {
  inputs: ReplyAttachmentInput[];
  existing: ReplyAttachmentRecord[];
  dataRoot: string;
  replyId: string;
}): IngestedAttachments {
  const { inputs, existing, dataRoot, replyId } = input;
  if (inputs.length > MAX_REPLY_ATTACHMENTS) {
    throw new ArtifactError(`a reply holds at most ${MAX_REPLY_ATTACHMENTS} files`, "attachment_limit");
  }
  const dir = replyAttachmentsDir(dataRoot, replyId);
  const records: ReplyAttachmentRecord[] = [];
  const incomingDirs: string[] = [];
  const copied: string[] = [];
  const taken = new Set<string>();
  try {
    for (const item of inputs) {
      if ((item.incoming_path === undefined) === (item.path === undefined)) {
        throw new ArtifactError("an attachment names either incoming_path or path", "attachment_source_ambiguous");
      }
      if (item.path !== undefined) {
        const kept = existing.find((e) => e.path === item.path);
        if (!kept) throw new ArtifactError("attachment path is not a file of this reply", "attachment_not_found");
        taken.add(basename(kept.path));
        records.push(kept);
        continue;
      }
      const source = realIncomingFile(item.incoming_path!, dataRoot);
      const stat = lstatSync(source);
      if (!stat.isFile()) throw new ArtifactError("attachment is not a regular file", "not_regular_file");
      const name = safeAttachmentName(item.name);
      if (stat.size > MAX_ATTACHMENT_BYTES) {
        throw new ArtifactError(`${name} is larger than ${MAX_ATTACHMENT_BYTES / (1024 * 1024)} MB`, "too_large");
      }
      const stored = uniqueName(name, taken);
      taken.add(stored);
      mkdirSync(dir, { recursive: true });
      const dest = join(dir, stored);
      copyFileSync(source, dest);
      chmodSync(dest, 0o444);
      copied.push(dest);
      incomingDirs.push(join(source, ".."));
      records.push({ name: stored, path: dest, size: stat.size, type: attachmentType(stored, item.type) });
    }
  } catch (err) {
    for (const path of copied) rmSync(path, { force: true });
    throw err;
  }
  return { records, incomingDirs: [...new Set(incomingDirs)] };
}

// Removes the incoming folder of a staged file, only when it is a folder inside incoming/.
export function removeIncomingDirs(dirs: string[], dataRoot: string): void {
  const root = incomingDir(dataRoot);
  for (const dir of dirs) {
    if (!dir.startsWith(root + sep) && !dir.startsWith(realpathOrSelf(root) + sep)) continue;
    rmSync(dir, { recursive: true, force: true });
  }
}

function realpathOrSelf(path: string): string {
  try {
    return realpathSync(path);
  } catch {
    return path;
  }
}

// Removes the stored files of a reply (a purged case). The files are read-only, the folder is not.
export function removeReplyAttachments(dataRoot: string, replyId: string): void {
  rmSync(replyAttachmentsDir(dataRoot, replyId), { recursive: true, force: true });
}

// Removes the stored files a replaced reply no longer lists.
export function removeDroppedAttachments(before: ReplyAttachmentRecord[], after: ReplyAttachmentRecord[]): void {
  const keep = new Set(after.map((a) => a.path));
  for (const old of before) if (!keep.has(old.path)) rmSync(old.path, { force: true });
}
