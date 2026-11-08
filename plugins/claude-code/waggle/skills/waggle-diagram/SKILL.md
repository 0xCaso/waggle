---
name: waggle-diagram
description: Use when you draw a flow, architecture, sequence, state, timeline, data model or other diagram for a Waggle ask, or send a diagram artifact in waggle_ask or waggle_update. Gives the layout rules, the complexity budget and two check scripts, and takes colours and fonts from the project's design system.
license: MIT
---

# Waggle diagram

A person reads your diagram in Waggle and decides. It must be clean, have few parts and look like the project it is for. Read this before you draw any diagram for a Waggle ask.

This skill is an adapted copy of `diagram-design` by Cathryn Lavery (https://github.com/cathrynlavery/diagram-design), MIT license. The license text is in `LICENSE-diagram-design`. Waggle kept the layout rules and the geometry checks. Waggle removed the brand: colours, fonts and radii come from the project's design system.

## 1. Decide if you need a diagram

Ask: does the person learn more from a picture than from a paragraph or a table? If not, write the paragraph or the table. Do not draw one shape. Do not draw a list.

The best move is to delete. Each node is one idea. Each arrow carries information. The diagram is done when you cannot remove anything.

## 2. Choose the pattern, then the type

1. If behaviour, state, enforcement or risk is the point, read `references/semantic-patterns.md` and choose one pattern. It names the nearest type.
2. Choose the visual type in `references/types.md` (44 types). Choose the type by what you show. If two types fit, choose the one for the main axis.
3. If a 3-column table says the same, use the table.

## 3. Confirm the plan before you draw

Write the plan in the ask, in 3 lines: the type (and pattern), the source of the look (section 5), and what the budget forces out. The person can redirect before you build. If the request already fixes type and content, skip this step.

## 4. Rules that never bend

**Budget.** At most 9 nodes. At most 12 arrows. At most 2 focal nodes. At most 2 callouts. Over the budget, make two diagrams: an overview and a detail.

**Focus.** Use the accent role on 1 or 2 nodes only. All other nodes use ink, muted or soft.

**Grid.** Node origins, widths, heights, gaps and padding divide by 4 px. Type sizes follow the type scale, not the grid.

**Connectors** (full text in `references/geometry.md`):

1. Orthogonal only. Use rounded right-angle elbows. Use a straight line only when both ends share x or y. A diagonal fails.
2. Each arrow label sits on an opaque mask. A gap of 6 to 10 px keeps it clear of its line. Use 14 characters at most.
3. No two connectors share a stroke. Keep parallel routes 12 px or more apart.
4. Each connector on one box edge gets its own attach point, 12 px or more from the next.
5. No connector passes behind a box that is not its start or end.
6. No label mask overlaps a node that you draw after it.

Draw in this order: background, zones, arrows, label masks, nodes. Never use vertical text on an arrow. Never use a shadow. Use a border.

## 5. Use the project's design system

Do not use the upstream fonts or colours. Do not invent a brand. Find the project's own look with the steps in `../waggle-prototype/design-system.md` (search steps, `tokens.css`, the `.waggle/design-tokens.json` cache and the one line the ask must say). Then map the roles in `references/output.md` onto the project's tokens.

With no design system found, use a neutral palette and the system UI font. Say it in the ask: `No design system found; neutral style.`

## 6. Choose the output

| The person needs | Send | Why |
|---|---|---|
| To look at the diagram, zoom and pin comments | `diagram` artifact, `.svg` (or `.mmd` for a plain flow) | Waggle shows it offline with zoom and pan. At most 512 KB. |
| A diagram with a title, a legend, cards or notes around it | `html_bundle` with `tokens.css` | You control the page. Give it a purpose-built preview. |
| A plain file for the user's repo | `.svg` or `.mmd` file in the repo | The repo keeps a file that tools can read. |

Default: use the `diagram` artifact. Use the `html_bundle` only when the page around the diagram carries meaning. Read `references/output.md` for the bundle layout, the roles map and the preview. Read the guide topic `artifacts` (waggle_guide) for the artifact limits.

## 7. Check before you send

Run both scripts with the system `python3`. They need no packages and no network.

```bash
python3 -I <skill-dir>/scripts/verify-geometry.py diagram.svg
python3 -I <skill-dir>/scripts/self_check.py diagram.svg
```

- `verify-geometry.py` fails on a diagonal connector, a connector on a node border, a port near a corner, ports closer than 12 px, stacked connectors, a clipped label mask, more than 9 nodes and more than 12 arrows.
- `self_check.py` fails on a missing title or desc, a script, an event attribute or a remote reference.

Fix every finding. Then walk this list:

1. The plan was confirmed or the assumptions are in the ask.
2. You tried to remove a node, an arrow and a label.
3. 1 or 2 nodes use the accent. A legend covers only what the diagram uses.
4. The diagram has `role="img"`, a `<title>` as first child and a `<desc>`. The ids have a prefix.
5. Every colour, font and radius is a token. No raw hex in the diagram.
6. It renders at 1400, 900 and 390 px wide. The SVG sits in a wrapper with `overflow-x: auto` and a `min-width` equal to its `viewBox` width.
7. The copy is plain and has no em-dash.
