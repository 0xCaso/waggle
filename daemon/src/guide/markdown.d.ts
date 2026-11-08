// A `.md` guide imported with `with { type: "text" }` (guide/index.ts): Bun
// embeds it as text at compile time. bun-types only declares this shape for
// `*.txt`; mirror it here for `*.md`.
declare module "*.md" {
  var text: string;
  export = text;
}
