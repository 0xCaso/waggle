// A small line diff for an edited markdown document (HAIL-168). No dependency: the daemon
// sends the agent a unified diff of the human's edit and counts the changed passages.

export interface DiffResult {
  // A unified diff with 2 lines of context. Empty when the two texts are equal.
  unified: string;
  // How many separate groups of changed lines the edit has (a "passage").
  passages: number;
}

type Op = { kind: " " | "-" | "+"; text: string };

// Longest common subsequence over lines, after the shared head and tail are cut off.
// A very large middle part falls back to "all removed, all added" (still a correct diff).
const MAX_CELLS = 16_000_000;

function lineOps(a: string[], b: string[]): Op[] {
  let head = 0;
  while (head < a.length && head < b.length && a[head] === b[head]) head++;
  let tail = 0;
  while (tail < a.length - head && tail < b.length - head && a[a.length - 1 - tail] === b[b.length - 1 - tail]) tail++;
  const midA = a.slice(head, a.length - tail);
  const midB = b.slice(head, b.length - tail);
  const ops: Op[] = a.slice(0, head).map((text) => ({ kind: " ", text }));
  if (midA.length * midB.length > MAX_CELLS) {
    for (const text of midA) ops.push({ kind: "-", text });
    for (const text of midB) ops.push({ kind: "+", text });
  } else {
    const w = midB.length + 1;
    const table = new Uint32Array((midA.length + 1) * w);
    for (let i = midA.length - 1; i >= 0; i--) {
      for (let j = midB.length - 1; j >= 0; j--) {
        table[i * w + j] =
          midA[i] === midB[j]
            ? table[(i + 1) * w + j + 1]! + 1
            : Math.max(table[(i + 1) * w + j]!, table[i * w + j + 1]!);
      }
    }
    let i = 0;
    let j = 0;
    while (i < midA.length && j < midB.length) {
      if (midA[i] === midB[j]) {
        ops.push({ kind: " ", text: midA[i]! });
        i++;
        j++;
      } else if (table[(i + 1) * w + j]! >= table[i * w + j + 1]!) {
        ops.push({ kind: "-", text: midA[i++]! });
      } else {
        ops.push({ kind: "+", text: midB[j++]! });
      }
    }
    while (i < midA.length) ops.push({ kind: "-", text: midA[i++]! });
    while (j < midB.length) ops.push({ kind: "+", text: midB[j++]! });
  }
  for (const text of a.slice(a.length - tail)) ops.push({ kind: " ", text });
  return ops;
}

export function diffMarkdown(before: string, after: string, fromLabel: string, toLabel: string): DiffResult {
  if (before === after) return { unified: "", passages: 0 };
  const ops = lineOps(before.split("\n"), after.split("\n"));
  const CONTEXT = 2;
  // Group the changed ops into hunks, each with CONTEXT lines around it.
  const changed: number[] = [];
  ops.forEach((op, index) => {
    if (op.kind !== " ") changed.push(index);
  });
  const ranges: [number, number][] = [];
  let passages = 0;
  let lastChanged = -2;
  for (const index of changed) {
    if (index !== lastChanged + 1) passages++;
    lastChanged = index;
    const start = Math.max(0, index - CONTEXT);
    const end = Math.min(ops.length - 1, index + CONTEXT);
    const prev = ranges[ranges.length - 1];
    if (prev && start <= prev[1] + 1) prev[1] = end;
    else ranges.push([start, end]);
  }
  // Line numbers (1-based) of each op in the old and the new text.
  const oldAt: number[] = [];
  const newAt: number[] = [];
  let o = 1;
  let n = 1;
  for (const op of ops) {
    oldAt.push(o);
    newAt.push(n);
    if (op.kind !== "+") o++;
    if (op.kind !== "-") n++;
  }
  const out = [`--- ${fromLabel}`, `+++ ${toLabel}`];
  for (const [start, end] of ranges) {
    const slice = ops.slice(start, end + 1);
    const oldCount = slice.filter((op) => op.kind !== "+").length;
    const newCount = slice.filter((op) => op.kind !== "-").length;
    out.push(`@@ -${oldCount === 0 ? oldAt[start]! - 1 : oldAt[start]},${oldCount} +${newCount === 0 ? newAt[start]! - 1 : newAt[start]},${newCount} @@`);
    for (const op of slice) out.push(`${op.kind}${op.text}`);
  }
  return { unified: out.join("\n"), passages };
}
