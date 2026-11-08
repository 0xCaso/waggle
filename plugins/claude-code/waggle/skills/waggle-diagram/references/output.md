# Output: tokens, bundle, preview

## 1. Map the roles onto the project's tokens

Find the project's design system first. Use `../waggle-prototype/design-system.md` (cache, search steps, `tokens.css`, the line for the ask). Then map each role to the project's own token. Take the closest one by value and by use.

| Role | Use | Map to the project's... | Neutral fallback |
|---|---|---|---|
| `paper` | Page and mask fill | Page background | `#ffffff` |
| `paper-2` | Zone and card fill | Surface or card background | `#f5f5f5` |
| `ink` | Text, node borders | Primary text colour | `#1f2328` |
| `muted` | Default arrows, sublabels | Secondary text colour | `#59636e` |
| `soft` | Quiet fills, rules | Border or divider colour | `#d1d9e0` |
| `accent` | 1 or 2 focal nodes, the headline arrow | Primary or brand colour | `#2f6fdd` |
| `accent-tint` | Fill of a focal node | The accent at about 10 percent over `paper` | `#e8f0fc` |
| `link` | Outside calls, API arrows | Link colour. With none, use `accent` | `#2f6fdd` |

Fonts: `--font-sans` for names and titles, `--font-mono` for technical sublabels and arrow labels. Radius: the project's small radius for nodes (`--radius-sm`). Type sizes: the project's scale, nearest to 12 for a name and 8 to 10 for sublabels and arrow labels.

Rules:

- Do not use Instrument Serif, Geist or a coral accent. Do not copy any brand from the upstream skill.
- Never invent a brand colour. Use only a value the project has, or the neutral fallback.
- With no design system: use the neutral fallback column, the system UI font (`system-ui`) and `ui-monospace`. Say `No design system found; neutral style.` in the ask.
- If the project has a dark mode, give the diagram the light values unless the person asks for dark.

## 2. html_bundle

Use it when the page around the diagram carries meaning (a title, cards, a legend, notes, a before and after).

```text
index.html     the page and the inline <svg>
tokens.css     every token as a custom property on :root (see design-system.md)
```

- `index.html` links `tokens.css`. The diagram colours are `var(--color-paper)`, `var(--color-ink)` and so on, set in `fill` and `stroke`. Add the role names you need to `tokens.css` as aliases of the project's tokens (for example `--color-accent-tint`).
- No script, no remote file, no `@import` in `index.html`. A font `@import` or `@font-face` goes in `tokens.css`.
- Put the SVG in a wrapper with `overflow-x: auto`. Give the SVG a `min-width` equal to its `viewBox` width. A phone then scrolls the diagram, not the page.
- Layout: a header (eyebrow, title, one line of subtitle), the diagram, then at most 3 summary cards of different widths (for example `1.1fr 1fr 0.9fr`) with a 1 px border and the project's radius. No shadow.
- Write a purpose-built preview (the first screen the person sees in the queue and the review): the diagram at a size that reads, with the title. Do not use a blank page or a plain screenshot of a full page.
- Name the bundle entry in the ask as the diagram, not as a file.

## 3. diagram artifact (.svg or .mmd)

Use it when the person needs the diagram alone: Waggle shows it offline with zoom, pan and comments. At most 512 KB.

- `.svg`: the file stands alone. It has no `tokens.css`, so write the token values as literals (`fill="#ffffff"`). Waggle removes scripts, event attributes, `foreignObject` and links when it shows the file. Set `font-family` to the project's stack with a generic fallback (`"Inter", system-ui, sans-serif`). A font file does not load, so the fallback shows if the person has no font.
- `.mmd` (Mermaid): use it for a plain flow or a plain structure that reads well from a small source. It cannot follow the six connector rules, so use `.svg` when the layout matters.
- Write the file into the working tree. Pass its path: `artifact: { type: "diagram", path: "./notes/review-flow.svg" }`.

## 4. Which one

| Case | Send |
|---|---|
| One diagram, the person reviews and comments on its parts | `diagram` with `.svg` |
| A flow of 5 boxes or fewer with no layout need | `diagram` with `.mmd` |
| A diagram plus cards, a legend, notes or two linked views | `html_bundle` |
| The user's repo wants a plain file (docs, README) | Write `.svg` or `.mmd` in the repo. Attach it as `diagram` too |
| Several diagrams to compare | `html_bundle` with all of them on one page |

## 5. Say it in the ask

Put one line in `why` or in the first line of the notes:

- Found: `Uses your design system: <path> (N colours, N fonts)`. See `design-system.md`.
- Nothing found: `No design system found; neutral style.`
- Plan (section 3 of `SKILL.md`): `Type: <type>. Cut: <what the budget removed>.`
