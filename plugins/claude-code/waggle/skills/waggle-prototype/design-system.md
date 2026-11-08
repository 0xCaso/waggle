# Use the project's design system

A prototype for a Waggle ask must look like the project it is for. Before you build, find the project's own look. Read the repo only. Never invent a brand.

If the person set a design kit in Waggle (waggle_guide shows it under "Default design kit"), follow the kit. Use the steps below to fill what the kit does not give.

## 1. Check the cache first

The repo root (for the cache only) is the git top-level of the folder you work in (`git rev-parse --show-toplevel`). If there is no git repo, use the folder you work in. Cache paths start at the repo root. Search paths start at the project folder (section 2).

1. Read `.waggle/design-tokens.json` in the repo root. If it does not exist, go to section 2.
2. The file names the `projectFolder` (from the repo root; `.` for the root). If it is not the project folder you found now, the cache is for another project: go to section 2. The file lists `sources`: each item has a `path` and a `sha256`. Run `shasum -a 256 <path>` for each path.
3. Run the search steps in section 2 again, but only to list file names. If a file is new, or a hash is different, or a file is gone, the cache is old. Redo section 2 and section 3.
4. If every hash matches and no file is new, reuse the cache. Skip to section 4.

## 2. Search steps

### Where to search

1. Find the project folder. Start at the files the screen will change or sit beside. Go up to the nearest folder that has its own `package.json`, `Package.swift`, `pyproject.toml`, `build.gradle`, `pubspec.yaml` or similar manifest. That folder is the project folder. If no folder has a manifest, use the top-most folder in a chain of folders that each hold an `index.html` (a plain site). If the screen has no target files, use the folder you work in.
2. Run all steps below inside the project folder only. A repo can hold more than one project (for example a Mac app and a site). Each project has its own look. Do not take tokens from a sibling project.
3. If the project folder gives nothing, widen to the git top-level and run the steps again. Widen once. Stop there.
4. Always skip `.git`, `node_modules`, `dist`, `build`, `.build`, `Pods`, `.claude/worktrees`, `.knock-review`, `.waggle` and any other worktree or scratch folder.
5. Remember which folder gave the result. The ask says it (section 5).

### Steps

Run the steps in this order. Stop at step 1 only if the doc gives colours, type, radii and spacing. Otherwise read the next step too.

| Step | Source | File globs to run | What to read |
|---|---|---|---|
| 1 | Design doc | `DESIGN.md`, `design.md`, `docs/design*.md`, `docs/design/**/*.md`, `docs/**/design-system*.md`, `**/design-system.md` | Tokens, components, do and don't |
| 2 | CSS files | `**/globals.css`, `**/global.css`, `**/variables.css`, `**/tokens.css`, `**/theme.css`, `src/**/*.css`, `app/**/*.css` | Every custom property (`--name: value`) in `:root` and `html` (and the dark block) |
| 3 | Inline styles | `**/*.html`, `**/*.vue`, `**/*.svelte`, `**/*.astro` | Every custom property in `:root` or `html` inside a `<style>` block. Many sites keep their tokens here and have no `.css` file |
| 4 | Tailwind v3 | `tailwind.config.js`, `tailwind.config.ts`, `tailwind.config.cjs`, `tailwind.config.mjs` | `theme` and `theme.extend`: `colors`, `fontFamily`, `fontSize`, `borderRadius`, `spacing`, `boxShadow` |
| 5 | Tailwind v4 | `**/*.css` that holds an `@theme` block (search for `@theme`) | Every variable in the `@theme` block |
| 6 | Swift | `**/Theme*.swift`, `**/Colors.swift`, `**/Color+*.swift`, `**/*.xcassets/**/*.colorset/Contents.json` | `static let` colours, fonts and sizes; each colorset `components` (red, green, blue, alpha) |
| 7 | Compose and Android | `**/ui/theme/*.kt`, `**/res/values/colors.xml`, `**/res/values/themes.xml`, `**/res/values/dimens.xml` | `Color(0x...)`, `<color>`, `<dimen>` and typography entries |
| 8 | Fonts | `**/*.woff2`, `**/*.ttf`, `**/*.otf`, `index.html`, `**/*.html`, `app/layout.*` | `@font-face`, `<link>` to a font CDN, `Font.custom(...)`, `next/font` calls |

Notes:

- Accept any custom property name. Do not require `--color-*`. A site can use `--ink`, `--h5`, `--faint` or `--line`. Classify each property by its value:
  - colour: `#hex`, `rgb()`, `hsl()`, `oklch()`, a colour name
  - length: a number with `px`, `rem`, `em` or `%`, or `clamp()`. These rules apply to values inside CSS rules too (`border-radius: 10px`, `padding: 12px`, `font-size: 15px`), not only to custom properties. Name tells the role: `radius`, `r-`, `round` means radius. `space`, `gap`, `pad` means spacing. `fs`, `text`, `size` means type size. If the name does not tell, a value of 0 to 24 px next to other lengths is spacing, and a value in a `border-radius` rule is a radius.
  - font: a list that ends in a generic family (`sans-serif`, `serif`, `monospace`, `system-ui`)
  - shadow: a value with two or more lengths and a colour (`0 1px 2px rgba(...)`)
  - anything else (easing, duration, z-index): keep it in `tokens.css` only if a screen needs it
- One spacing value is not a scale. Make `--space-*` tokens only when the source has two or more different spacing values that the pages use as steps. With one value, use raw spacing in the screens.
- A project can match more than one step (for example Tailwind and a global CSS file, or several HTML pages). Merge them.
- If sources give a different value for the same property, pick the winner like this:
  1. The value that most files use wins.
  2. On a tie, the file with the most components wins (count buttons, inputs, cards and rows).
  3. If a design doc (step 1) gives the value, the doc wins over all code.
  4. List each disagreement in the ask: `<name>: <winner> in <path>, <loser> in <path>`.
- The main source is the file that gave the most tokens to `tokens.css`. On a tie, use the winner of the rule above.
- Take the light values. Add dark values only if the project has them and the prototype needs them.
- Read how the project builds a button, an input, a card and a list row (one component file or one HTML block each). Copy the look: radius, padding, border, shadow, hover.

## 3. Write the tokens

Write one file in the bundle, `tokens.css`, with every token as a CSS custom property on `:root`. Map each source property to a role by its value (see the notes in section 2), and give it the role name:

- colours (`--color-*`)
- type scale and weights (`--font-size-*`, `--font-weight-*`, `--line-height-*`)
- font families (`--font-sans`, `--font-mono`)
- radii (`--radius-*`)
- spacing (`--space-*`)
- shadows (`--shadow-*`)

Example: the source has `--ink:#16181A`, `--h5:#F2B01E`, `--faint:#e6e6e6`. The file gets `--color-ink`, `--color-h5`, `--color-faint`. Keep the source name after the prefix, so a person can trace it.

Link `tokens.css` from every screen. The rule "no raw values in screen files" covers these:

- Colours, radii, font families and type sizes must use `var(--...)`. Do not write a hex value, a pixel radius, a font name or a font size in a screen file.
- Padding, margin and gap use a spacing token. If the source has no spacing scale (or only one spacing value), a raw value is allowed.
- The font `<link>` or `@import` belongs in `tokens.css`, not in a screen file.
- Inline SVG colours use `var(--color-*)` in `fill` and `stroke`.

Add a token to `tokens.css` first if you need one, and base it on a value that the project has.

Convert as needed: a Swift `Color` or a colorset becomes a hex value. `Font.custom("X", size: 16)` becomes `--font-sans: "X"` and `--font-size-body: 16px`. A Tailwind `spacing` scale becomes `--space-*`.

Fonts:

- If the font file is in the repo, copy it into the bundle and add an `@font-face` in `tokens.css`.
- If the font is on a public CDN that the project already uses (for example a Google Fonts `<link>`), put the same URL in `tokens.css` as `@import url(...)`.
- Otherwise use the closest system font (`system-ui` for a sans, `ui-serif` for a serif, `ui-monospace` for a mono) and say so in the ask.

## 4. Write the cache

Save what you found to `.waggle/design-tokens.json` in the repo root:

```json
{
  "version": 1,
  "projectFolder": "site",
  "sources": [{ "path": "src/styles/globals.css", "sha256": "..." }],
  "tokens": { "colors": {}, "fonts": {}, "radii": {}, "spacing": {}, "shadows": {}, "typeScale": {} },
  "fontFallbacks": []
}
```

- Use a `sha256` of each source file (`shasum -a 256 <path>`). Do not use file times: a git checkout changes them.
- The cache is local. Do not add `.waggle/` to `.gitignore`. Do not stage it. Do not commit it. The person decides if the cache goes into git.
- If you cannot write the file, build the prototype anyway.

## 5. Say it in the ask

Put one line in the ask `why` or in the first line of the artifact notes:

- Found: `Uses your design system: <path> (N colours, N fonts)`. Use the main source path, and write it from the repo root. Add the folder you searched: `Uses your design system: site/install/index.html (9 colours, 1 font), searched in site/`. If you widened to the git top-level, say `searched in the repo root`. N colours is the number of distinct colour tokens (`--color-*`) in `tokens.css`. N fonts is the number of font families.
- Sources disagree: add one line per disagreement (see section 2).
- Fonts replaced: add `Font <name> is not in the repo; used <system font>.`
- Nothing found: `No design system found; neutral style.` Then use a neutral style: system fonts, grey scale, one quiet accent. Never invent a brand name, logo or brand colour.
