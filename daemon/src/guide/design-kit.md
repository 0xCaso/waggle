# Design kit (optional)

A project may hold a design kit: one markdown file at `.knock/design-kit.md` in the project
root (the git root, or the folder you run in when there is no git). It is optional. When the
file is absent, do nothing and do not ask the person to create one.

When the file is present, waggle_guide adds its content to the artifacts topic under
"This project's design kit". Read it before you design or write copy. Design in the Pen file
it names, reuse its components, and follow its brand values and tone of copy.

## The default kit, and waggle_settings

The person can also set a default design kit in Waggle (Settings > Artifacts). It has the same
sections (Design system, Pen file, Tone of copy). When it is on and the project has no
`.knock/design-kit.md`, waggle_guide adds it under "Default design kit". A project kit always wins.

Use waggle_settings to read or change it. Call `{ action: "get" }` to read the kit and the artifact
preset. Call `{ action: "set", design_system, pen_file, tone, enabled, artifact_preset }` with only the
fields you change. Rules:

- To set up a kit, read the project's design.md or design system, then propose a kit.
- Ask the person in Waggle (waggle_ask) before you turn the kit on or replace a design system that
  is not empty. Do not change settings they did not ask about.
- design_system is markdown, up to 1 MB. Agents get only the first 8 KB, so put what matters first. pen_file is an absolute path; Waggle never opens the file.
- Every change shows as yours, and the person can undo it in Settings > Artifacts.

## Format

Plain markdown. Every section is optional. Keep it under 8 KB.

    # Design kit

    ## Design system
    docs/design.md (or a tokens file: design/tokens.json)

    ## Pen file
    design/system.pen
    Components: Button, Card, Sheet header

    ## Brand
    Colours, type, spacing, logo rules, in a few lines.

    ## Tone of copy
    Plain and warm. No jargon. No em-dashes.

Paths are relative to the project root. Read the files they name with your normal tools
(Pen files only through the Pen tools).

## WRONG / right

WRONG: "Before we start, please create a design kit file."

Right: no kit file, no mention of it. Work as usual.
