# Dark Mode: how does Waggle choose its look?

Decided: 2026-11-11 · Case: c_a7df3a60-77de-4579-add7-69980736bb63

## Question and choice
The app forces the light look today. Dark Mode comes in a later release. How does Waggle choose between the
light and the dark look?

The human chose "Follow macOS, with a setting": "Waggle follows the macOS appearance by default. Settings gets
one control: System, Light or Dark."

## Why
- The human asked: "next PR is gonna be implementing Dark Mode, for a later release".
- It is the behaviour a Mac user expects, and the setting keeps a way back to the light look.
- Agent's reason: one stored setting with three values is the smallest control that covers each case.

## Constraints
- One pull request on waggle-so/waggle. No push and no merge until the human asks. It ships in a later release.
- This reverses the old rule "Light look always". The rule that stays: each text field has an explicit text
  colour and background, in both looks.
- Agent content (prototypes, HTML pages, screenshots) keeps its own colours. Waggle does not recolour it.
- The brand colours keep their meaning in both looks: honey for selected and recommended, red for needs you,
  green for decided, blue for working.
- Text contrast in the dark look is at least 4.5 to 1 for body text.
- UI copy uses plain words and no em-dashes (AGENTS.md). Tests that wait poll with a deadline (AGENTS.md).
- The dark palette is the agent's design call. The human reviews it before the build covers the whole app.

## Ruled out
- "Stay light, dark on request": most people never find the setting.
- "Follow macOS, no setting": nobody can keep the light look on a dark Mac.

## Comments
none

## Palette (approved)
- Surfaces: sidebar #141517, canvas #18191C, window #1C1E21. Text: #F1F1EF, body #C5C7CB, meta #9C9EA3.
- Honey and red fills do not change. Green (#4CC38A) and blue (#8DA6FF) are lighter so they read as text.
- The primary button is light with dark text (`onFill` #16181A). Two new tokens: `onAccent` (white on red, both
  looks) and `accentText` (red as text, #FF8A80 in the dark look).
- Agent's note: a `KNOCK_APPEARANCE` env value (system, light, dark) wins over the stored setting, so a test
  build picks its look without a click.

## Open questions
- Closed 2026-11-11: the human approved the dark palette (case c_61023221-f738-4e16-a943-b4a5ab670e53) from
  captures of four real screens in both looks. The values are in Theme/Theme.swift (`Color(light:dark:)`).
- Closed 2026-11-11 (agent's design call, open to review in the pull request): the control is an "Appearance"
  switch at the bottom of the Settings sidebar, above the version. No page is about the look, and there the
  change shows on each page.

- Closed 2026-11-11 (task 5): the main window, the request page, Settings, first run, the paused card, the
  Sent toast and the caught-up pane were checked in both looks in a dev build with a temporary KNOCK_HOME. One
  fix came from it: the Interact and Comment switch over an artifact had white text on its light dark-look fill.
  A test holds the dark text colours at 4.5 to 1 or more on each surface.
- Agent's call, open to review in the pull request: agent pages (HTML bundles) always render in the light look,
  so a page written for a white canvas reads the same when Waggle is dark.
- Closed 2026-11-11: the human saw seven screens in both looks and chose "Push and open the pull request"
  (case c_b6f19a3a-ea70-4435-ab07-2459533a8532). The merge stays with the human.

## Sources
- Case c_a7df3a60-77de-4579-add7-69980736bb63 (the choice).
- apps/macos/Sources/Knock/Theme/Theme.swift: 48 colour tokens, each with one light value.
- `.preferredColorScheme(.light)` in 8 places: KnockApp.swift:105,154,165 · Settings/SettingsView.swift:32 ·
  Settings/ClaudeAppPlace.swift:243 · Home/HomeView.swift:88 · Screenshots/ScreenshotViews.swift:87.
- About 100 colours written outside the theme (grep of `Color(red:`, `Color.white`, `Color.black`).

## Tasks
1. Draw the dark palette and ask. Criteria: each of the 48 tokens has a dark value; four real screens (main
   window, request page, Settings, first run) are shown in both looks; the human approves before task 3.
   From: Open questions, line 1, and Constraints, line 7.
2. Appearance setting. Criteria: one stored value (system, light, dark), default system; one control in
   Settings; each window follows it at once, with no restart; a test covers the stored value and the default.
   From: Question and choice.
3. Theme tokens with two values. Criteria: each token resolves by the current look; no
   `.preferredColorScheme(.light)` stays; the light look is pixel-equal to today on the four screens.
   From: Constraints, line 2, and Sources, line 3.
4. Move the colours written outside the theme to tokens. Criteria: no `Color.white`, `Color.black` or raw
   colour value outside Theme, except agent content frames; each text field sets its text colour and
   background from tokens. From: Constraints, lines 2 and 3, and Sources, line 4.
5. Check both looks in the app. Criteria: the four screens, the paused card, the Sent toast and the caught-up
   pane are captured in both looks from a dev build with a temporary KNOCK_HOME; body text contrast is at
   least 4.5 to 1; the suites pass. From: Constraints, lines 4 and 5.
