import type { Case } from "../protocol";

// HAIL-231: the work and the agent in plain words, for the chat connectors. This is the TS twin of
// the Mac app's ProjectName and ClientName (RequestRowModel.swift, CaseDisplay.swift). Keep the two
// in step: the queue row, the Mac notification and the chat message must read alike.

// The name a person uses for the work behind an ask: the topic when the ask has one, else the project
// folder cleaned. Never the branch, a full path or a session id.
export function workName(project: string): string {
  const trimmed = project.trim();
  // A topic task has the topic as its project (HAIL-163). A name with a space shows as written.
  if (/\s/.test(trimmed)) return trimmed;
  return readableFolder(trimmed);
}

// Last path component, no hash suffix ("-fc8f1973"), dashes and underscores to spaces, first letter
// upper case: "/work/fragrant-hospital-fc8f1973" reads "Fragrant hospital".
export function readableFolder(folder: string): string {
  const parts = folder.split("/").filter((p) => p !== "");
  let name = parts.length > 0 ? parts[parts.length - 1]! : folder;
  const hash = name.match(/[-_][0-9a-f]{6,}$/);
  if (hash && /\d/.test(hash[0])) name = name.slice(0, name.length - hash[0].length);
  name = name.replace(/[-_]/g, " ").split(/\s+/).filter((w) => w !== "").join(" ");
  if (name === "") return "";
  // A name that already has capitals ("Syllotips", "waggleApp") keeps them.
  return name === name.toLowerCase() ? name.charAt(0).toUpperCase() + name.slice(1) : name;
}

const isCowork = (name: string): boolean => {
  const lower = name.toLowerCase();
  return lower.startsWith("local-agent-mode") || lower.includes("cowork");
};

// The agent in words: "Claude Code", "Claude app", "Cowork" or "Codex".
export function agentLabel(runtime: string, clientName: string | null | undefined, canNudge: boolean | null | undefined): string {
  const base = runtime === "codex" ? "Codex" : "Claude Code";
  if (runtime !== "claude" || canNudge !== false || !clientName) return base;
  if (clientName.toLowerCase().startsWith("claude-code")) return base;
  return isCowork(clientName) ? "Cowork" : "Claude app";
}

// "Pricing page · Claude Code": the one plain line a chat message leads with.
export function workLine(c: Pick<Case, "project" | "runtime" | "session_can_nudge" | "session_client_name">): string {
  const agent = agentLabel(c.runtime, c.session_client_name, c.session_can_nudge);
  const work = workName(c.project);
  return work === "" ? agent : `${work} · ${agent}`;
}
