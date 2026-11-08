import { existsSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

// SYL-2: the optional design kit. The shim (never the daemon: HAIL-26) reads
// `.knock/design-kit.md` from the project root and adds it to the guide text.
// No file means no change at all.

export const DESIGN_KIT_PATH = ".knock/design-kit.md";
export const DESIGN_KIT_MAX_BYTES = 8 * 1024;

// The project root is the git root, else the folder the shim runs in.
export function readDesignKit(cwd: string, gitRoot: string | null): string | null {
  for (const root of [gitRoot, cwd]) {
    if (!root) continue;
    const file = join(root, DESIGN_KIT_PATH);
    try {
      if (!existsSync(file) || !statSync(file).isFile()) continue;
      const text = readFileSync(file, "utf8").slice(0, DESIGN_KIT_MAX_BYTES).trim();
      if (text) return text;
    } catch {
      // An unreadable kit counts as no kit.
    }
  }
  return null;
}

export function designKitSection(kit: string): string {
  return `## This project's design kit

This project has a design kit (${DESIGN_KIT_PATH}). Read it before you design or write copy.
Design in the Pen file it names, reuse its components, and follow its brand values and tone of
copy. Read the files it names with your normal tools.

${kit}`;
}

// HAIL-166: the default kit, set in Settings > Artifacts or with waggle_settings, stored in the daemon.
// It is written in the same markdown shape as .knock/design-kit.md, so agents read both the same way.
// Empty fields are left out. Returns null when no field has text.
export function defaultKitMarkdown(kit: { design_system: string; pen_file: string; tone: string }): string | null {
  const parts: string[] = [];
  const add = (title: string, text: string) => {
    if (text.trim()) parts.push(`## ${title}\n${text.trim()}`);
  };
  add("Design system", cutDesignSystem(kit.design_system));
  add("Pen file", kit.pen_file);
  add("Tone of copy", kit.tone);
  if (parts.length === 0) return null;
  return `# Design kit\n\n${parts.join("\n\n")}`;
}

export const DESIGN_KIT_CUT_NOTE = "(Design kit cut at 8 KB. Ask the person in Waggle for the rest if you need it.)";

// The stored design system can be long (up to 1 MB); agents get the first 8 KB, cut at a line break,
// then a note. The cap is bytes, so the cut also stays on a character edge.
export function cutDesignSystem(text: string): string {
  const bytes = new TextEncoder().encode(text.trim());
  if (bytes.length <= DESIGN_KIT_MAX_BYTES) return text;
  let head = new TextDecoder().decode(bytes.slice(0, DESIGN_KIT_MAX_BYTES)).replace(/\uFFFD+$/, "");
  if (bytes[DESIGN_KIT_MAX_BYTES] !== 0x0a) {
    const nl = head.lastIndexOf("\n");
    if (nl > 0) head = head.slice(0, nl);
  }
  return `${head.trimEnd()}\n${DESIGN_KIT_CUT_NOTE}`;
}

export function defaultDesignKitSection(kit: string): string {
  return `## Default design kit

The person set a default design kit in Waggle (Settings > Artifacts). Read it before you design or write
copy. Design in the Pen file it names, reuse its components, and follow its tone of copy. A project's own
${DESIGN_KIT_PATH} would replace it. Read the files it names with your normal tools.

${kit}`;
}

export const DEFAULT_DESIGN_KIT_INDEX_NOTE = `The person set a default design kit in Waggle. Read the "artifacts" topic before you design.`;

export const DESIGN_KIT_INDEX_NOTE = `This project has a design kit (${DESIGN_KIT_PATH}). Read the "artifacts" topic before you design.`;

// Topics that carry the kit: the ones about building what the person sees.
const KIT_TOPICS = new Set(["artifacts"]);

// `kit` is the project kit. `defaultKit` is the stored default (HAIL-166): used only when there is no
// project kit, so a project kit always wins.
export function withDesignKit(
  topic: string | undefined,
  text: string,
  kit: string | null,
  defaultKit: string | null = null,
): string {
  const source = kit ? "project" : defaultKit ? "default" : null;
  if (!source) return text;
  if (topic === undefined) {
    return `${text.trimEnd()}\n\n${source === "project" ? DESIGN_KIT_INDEX_NOTE : DEFAULT_DESIGN_KIT_INDEX_NOTE}\n`;
  }
  if (!KIT_TOPICS.has(topic)) return text;
  return `${text.trimEnd()}\n\n${source === "project" ? designKitSection(kit as string) : defaultDesignKitSection(defaultKit as string)}\n`;
}
