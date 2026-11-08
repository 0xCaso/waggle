# Geometry and markup

The full text of the six connector rules, the 4 px grid and the SVG parts. The rules come from `diagram-design` by Cathryn Lavery (MIT). The colour and font values do not. They come from the project's tokens (see `output.md`).

In the markup below, `paper`, `ink`, `muted`, `accent` and `link` are roles. In an html_bundle write them as `var(--color-...)`. In a standalone `.svg` write the value of the token.

## The 4 px grid

Structural geometry divides by 4: node origins, widths, heights, gaps and padding. Type sizes, radii, stroke widths and half-pixel offsets for crisp 1 px strokes are off the grid.

| What | Values |
|---|---|
| Node width and height | 80, 96, 112, 120, 128, 140, 144, 160, 180, 200, 240, 320 |
| Gap between nodes | 20, 24, 32, 40, 48 |
| Padding inside a box | 8, 12, 16 |
| Radius | The project's small radius. With no design system, 4 to 8 |

## Paint order

1. Background: one `<rect>` filled with `paper`. No dot pattern.
2. Zones (grouping boxes).
3. Arrows. Lines sit behind nodes.
4. Label masks and labels.
5. Nodes.
6. Legend.

## The six connector rules

1. **Orthogonal only.** Use rounded right-angle elbows. Each bend is a quarter arc with r=8 (r=6 in a tight layout). Use a straight `<line>` only when both ends share x or y. A diagonal always fails. A connector leaves and enters a box at right angles to the edge. Its port sits on the straight part of the edge, 8 px or more from a corner. A segment that runs along a box border hides behind the fill and looks like it leaves the corner.
2. **Label gap.** An arrow label never sits on its arrow. Put the label above the line, or beside a vertical line. Keep 6 to 10 px between the bottom of the mask and the stroke. Use 14 characters at most, in capitals, centred on the segment. Never use vertical text.
3. **No overlaps.** Two connectors never share a stroke. Where two arrows must run side by side, keep them 12 px or more apart for their whole length. Where two arrows cross, draw a small hop on one. If you stack connectors, the nodes are too close or the diagram is over budget. Split it.
4. **Fan the attach points.** Each connector on one edge gets its own point. For N connectors on an edge of length L, point k sits at `L * k / (N + 1)`. Keep the points 12 px or more apart (8 px on a box with an edge shorter than 48 px).
5. **No transit behind a box.** Route around a box that is not the start or end. Only when no route exists: draw the stroke dashed (`4,3`), put the label at the visible end and put no arrowhead on the box in the way.
6. **Mask before node.** A label mask must not overlap a node that you draw after it. The node fill covers the mask and the text breaks. A mask fully inside a node (a badge) is fine. A mask over a zone is fine.

## Arrow markers

Define one marker for each arrow colour you use.

```svg
<marker id="arrow" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto">
  <polygon points="0 0, 8 3, 0 6" fill="MUTED"/>
</marker>
<marker id="arrow-accent" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto">
  <polygon points="0 0, 8 3, 0 6" fill="ACCENT"/>
</marker>
```

| Arrow | Stroke | Use |
|---|---|---|
| Default | `muted` | Most arrows |
| Accent | `accent` | The one headline path |
| Link | `link` | Calls to an outside system or an API |
| Dashed `5,4` | Any role | Optional, passive, return or async |

## Node box

```svg
<!-- 1. An opaque mask, so arrows do not show through -->
<rect x="X" y="Y" width="W" height="H" rx="R" fill="PAPER"/>
<!-- 2. The box. Focal: accent border and accent-tint fill. Others: ink or muted border. -->
<rect x="X" y="Y" width="W" height="H" rx="R" fill="PAPER" stroke="INK" stroke-width="1"/>
<!-- 3. The name, in the body font -->
<text x="CX" y="CY" fill="INK" font-size="12" font-weight="600" text-anchor="middle">Node name</text>
<!-- 4. A technical sublabel (port, command, path), in the mono font -->
<text x="CX" y="CY+16" fill="MUTED" font-size="9" text-anchor="middle">tech:port</text>
```

Use the mono font only for technical content. Names use the body font. No shadow. Vary the boxes: one shape for every node hides the order of importance.

Node types and how to draw them: focal (accent border, accent-tint fill), service or step (ink border), store (muted border, a second line at the top), outside system (dashed muted border), input or user (soft fill), optional or async (dashed).

## Arrow label

```svg
<rect x="MID_X-18" y="ARROW_Y-20" width="36" height="12" rx="2" fill="PAPER"/>
<text x="MID_X" y="ARROW_Y-11" fill="MUTED" font-size="8" text-anchor="middle" letter-spacing="0.06em">WRITE</text>
```

A text width is about 0.60 em for each sans character and 0.62 em for each mono character. Use this to size the mask. The script checks the mask against nodes. It does not check that the text fits.

## Legend

One horizontal strip at the bottom of the diagram. Add about 60 px to the `viewBox` height. Cover only the node types and arrow types the diagram uses. Never float a legend inside the diagram area.

## Accessible SVG

1. `<svg>` has `role="img"` and `aria-labelledby="<slug>-title <slug>-desc"`.
2. `<title id="<slug>-title">` is the first child, before `<defs>`. It is the short name of the subject, 60 characters or fewer.
3. `<desc id="<slug>-desc">` is one sentence about the content, not the geometry.
4. The slug is unique in the page. Never use a bare `title` or `desc` id.
5. An SVG that only decorates has `aria-hidden="true"`.

## Per-type limits

Each type has its own limit on top of the 9 node and 12 arrow budget: sequence 5 lifelines, swimlane 5 lanes, quadrant 12 items, ER 8 entities, tree depth 4, org chart 12 nodes, layer stack 6 layers, Venn 3 circles, radar 5 axes and 5 series, bar chart 8 bars, Gantt 12 tasks, scatter 30 points, Sankey 8 nodes and 12 flows, kanban 5 columns and 12 cards, journey 6 stages, deployment 3 zones, dependency graph 9 nodes and 14 edges, UML class 7 classes. The tighter limit wins.
