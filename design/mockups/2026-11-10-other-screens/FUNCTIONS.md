# Functions per screen (read from the SwiftUI code, 2026-11-10)

Each mockup in `index.html` must show every item of its list. Source files are under
`apps/macos/Sources/Knock/`. Numbers count the items below.

## Home (17) - `Home/HomeView.swift`, `Settings/PluginOfferViews.swift`, `Settings/PluginSetup.swift`
Shown when no ask is open and none needs you. Nothing in the steps can be clicked.
1. Main window sidebar (same as the request page: Needs you, Working, In planning, Answered, footer)
2. Plugin offer card: title "Waggle now has a Claude Code plugin"
3. Plugin offer body text
4. Button "Install plugin"
5. Button "Not now" (hides the card for good)
6. "Installing" status line, or the failure line, under the buttons
7. Plugin setup card: title "Setting up the Claude Code plugin" / "Claude Code plugin is working"
8. Checklist rows: Plugin installed, Old connection removed, Seen in <session> · <time> / Waiting for a Claude Code session…, Test decision arrived
9. Waiting hint "Start a new session or restart an open one, then try it:" + the test prompt
10. Band preview line ("Waggle · still waiting on your answer · 2m · 1: open")
11. Buttons "Copy test prompt" (then "Copied"), "Skip", "Done"
12. Headline "Plan it. See the options. Decide."
13. Lead line
14. Step card "Plan" with its picture and line
15. Step card "Prototype variants" with its picture and line
16. Step card "Decide" with its picture, the "Decided" pill and line
17. Foot line "It starts in your agent's session…"; arrows between cards (row when wide, column when narrow)

## New idea (19) - `NewIdea/NewIdeaModel.swift`, `StartFromDocument/StartFromDocumentViews.swift`, `DocumentPrompt.swift`, `StartMenuLayout.swift`
NOTE: today there is no New idea view. WAG-362 removed the page and its entry points (a test,
`WAG362Tests.theIdeaBoxAndItsEntryPointsAreGone`, keeps them out). The model, the agent chip and its menu
are still in the code. The mockup draws the page from the model.
1. Idea box (multi-line text), focused after a drop
2. Attached files as chips, each with remove
3. "Add files…" (picker: "Add notes, screenshots or a PRD"); drop files on the window
4. Goal chips: Plan it with me, Options to decide on, Clickable prototype, Review
5. The chosen goal's detail line
6. Folder chip (folder name, picker "Choose")
7. Agent chip: "Claude Code · Terminal", or "<project> · Running session"; honey when it differs from the default
8. Start button: "Start planning" / "Start" / "Send to <name>"; disabled with no text and no file; busy state
9. Error line (session closed, cannot take a prompt, did not arrive, launcher error)
10. Agent menu: Claude Code | Codex switch
11. Place rows with a check on the pick: Terminal, Claude app / Codex app, Superset, Conductor ("Prompt filled in, you press Enter"), T3 Code
12. "Send to a running session" row with "N sessions" and a submenu
13. Session submenu rows: name, "working now" (dot) or "idle", check on the pick, folder as tooltip
14. "N more places to set up · Show/Hide" fold
15. Set-up rows: place, reason ("Claude Code not found on this Mac"), "Set up ›"
16. "Places in Settings ›" link
17. "Use as my default" checkbox (disabled for a running session)
18. Sidebar (main window)
19. The ask that the start makes lands in the sidebar (Working row)

## Plan (16) - `Plan/PlanText.swift`, `Plan/PlanViews.swift`, `Plan/PlanArtifacts.swift`, `Plan/AskArtifactLayout.swift`, `Queue/SidebarSections.swift`, `Queue/RoundHeading.swift`
A plan ask is a request page with plan parts. The cases mockup already draws an Approaches round; this one
draws the Spec round and the parts that mockup does not show.
1. Sidebar "IN PLANNING · N" section: row title, meta "Questions · working"
2. Needs-you row of a plan: meta with the stage
3. "Plan · round N" chip on a plan row
4. Stage track: Questions, Approaches, Design, Spec (done tick, current dark, upcoming outline)
5. Progress label: "Question 3 of ~5", "Approaches", "Design · section 1 of 3", "Spec"
6. Round tag "ROUND 4" (eyebrow) and title
7. Earlier rounds fold "3 answered · Show/Hide": question, answer, "See vN" / "Viewing"
8. Need and why
9. Options (radio), recommended tag
10. Primary button per stage: Next question / Use this approach / Approve section / Approve and start planning
11. Secondary button: Change (design) / Request changes (spec)
12. Field placeholder "What should change?" after Change with no note
13. Artifact beside: "Background write-up" / the artifact's name, version
14. Stale line "Still showing v2 · not updated with the 14:27 change"
15. Pinned artifact bar when the pane is narrow (name, "Prototype · v2", Open)
16. Answer tools (Let's discuss, Ask for…)

## Usage (14) - `Settings/UsageSettingsView.swift` (Settings › Data & privacy, section USAGE)
1. Section label USAGE + what is kept ("Waggle keeps a private list…")
2. Toggle "Record usage on this Mac" (retention days in the line)
3. Toggle "Measure token use from my agent's session log" (off when recording is off)
4. Toggle "Include my notes and comments in the export" + hint
5. Row "Tool calls": "N calls · N tokens · last 7 days"
6. One row per tool: "N calls · N written · N received · N re-read"
7. Row "Waiting for you": checks, share of tokens, minutes waiting
8. Rows "Top session by tokens" / "Next session": client · calls · tokens
9. Estimate line ("Token counts are estimates…")
10. Row "Export usage" + button "Export usage…" (save panel)
11. Export result line ("Saved N tool calls to …, with a CSV beside it. Nothing has been sent.")
12. Row "Delete usage data" + button "Delete usage data…"
13. Confirm alert "Delete usage data?" (Cancel / Delete)
14. Buttons disabled while busy

## Menu bar (9) - `Notifications/MenuBarController.swift`
A native NSMenu from the status item.
1. Status item: Waggle mark + Needs-you count, or "Off"
2. "TEST COPY" line (test builds only)
3. "Agents bring you" title + switch: Off / Things to look at / Look and read / Everything
4. Separator
5. "Open Waggle"
6. "Send a screenshot" ⌃⌥S (hidden while Screenshots are Off)
7. "Snip an area" ⌃⇧W (hidden while Snip is Off)
8. Separator
9. "Check for Updates…", or "Updates are off in development builds" (disabled)

## Onboarding (24) - `Onboarding/*`, `Queue/FirstRunViews.swift`, `Onboarding/CoachMark*`
Window 760 × 660, two steps; then the getting-started list and the tour in the main window.
1. Step pills: 1 Connect, 2 Your first job (done tick, current dark)
2. Step 1 header "Connect your agent", subtitle, "Step 1 of 2"
3. Runtime rows Claude Code, Codex: status chip (Connected, Checking…, Couldn't check, Not installed, Not connected)
4. Row buttons: Connect, Connecting, Retry, "Installed as … plugin", "Trust the Waggle hooks once: type /hooks in Codex"
5. Claude app and Cowork row: line, Connect, confirm sheet "Add Waggle to the Claude app?" (Cancel / Add Waggle), restart note
6. Line "Only this step is needed…"
7. "Next: your first job →" (disabled until one agent is connected)
8. Step 2 header "What are you working on?" + subtitle
9. PROJECT chips (open sessions, recent folders, "Something else" / "Pick a folder")
10. FIRST JOB cards: "Let the agent find a real decision" (✦ Default), suggestions (Suggested), "Type your own"
11. Own-job field "What are you deciding right now?"
12. Route line ("Sends to your open Claude Code session in …" / "Waggle starts a new Claude Code session…") + Change
13. "Prompt copied. Paste it in Codex or the Claude app."
14. Buttons Back, Copy prompt, Send to my session / Start in Terminal / Starting…; failure line
15. Getting started list in the sidebar: title, Hide, progress "2 of 6 done"
16. Six items: Connect an agent, Send your agent a first job, Get your first decision, Keep talking once, Allow notifications (Allow), Add a design kit (Add), each with its line and done tick
17. Working row "Your agent is on it" with "First job" tag and "<project> · finding a real decision · 2 min"
18. Pane "Your agent is on it": what the agent does, the ask opens here
19. "No ask after 3 minutes? Try a sample instead" / "Making the sample…"
20. Notifications tip "Next: hear when an agent needs you" pointing at the list
21. Coach mark tour: "1 of 3", title, body, Skip, Next / Got it
22. Tour marks: What the agent brings, Decide or keep talking, A new round
23. "Your agents now know how to use Waggle" panel + "See the exact instructions"
24. Exact instructions sheet (THEY COME TO YOU WHEN…, THEY WON'T…, EVERY REQUEST HAS…, full text, Close)

## Settings (13 pages, 112) - `Settings/*`
Window 820 × 600, sidebar 210 pt with an icon per page; each page: title, subtitle, sections.
- Sidebar (2): 13 pages in order (Sharing and Account only when the service is available); the selected page.
- Agents (24): runtime card (Claude Code, Claude app and Cowork, Codex with status chips and Connect / Reconnect / Retry / Remove old entry / Remove / Show file), note "Waggle changes the Claude app's settings only after…", plugin offer row + Install plugin, "Claude Code plugin" toggle + Working, setup checklist, Design helpers (Impeccable, Add to Claude Code / Remove), ASKING IN WAGGLE (Catch decisions in the terminal; Add a Waggle rule … Add/Remove per file; Codex note), T3 CODE card (status, Install line, Check again / Connect / Renew / Disconnect), CLAUDE APP, CODEX APP, SUPERSET (Install, Sign in + Copy line), CONDUCTOR cards with Download, USE IT ON YOUR REAL WORK (two Copy rows), SHARING YOUR AGENT SETUP (Copy waggle.so/install), Starter prompts (Research / Product marketing / Design tabs, two prompts each with Copy, footnote), "See the exact instructions", "Run setup again".
- Notifications (7): macOS notifications status + Allow notifications / Open System Settings ›, Dock badge line, Sound picker + play, Show the decision in the notification, Remind me if a decision waits.
- Previews (4): Show HTML previews, Ask before opening links, SAFETY sandbox line, Check passed / failed chip.
- Screenshots (6): title + line, three choices (Off, After every screenshot, Only with a shortcut), thumbnail tip, Snip an area title + line, Off / On.
- Artifacts (12): presets Quick / Visual / Rich with bullets and mini pictures, note, DESIGN KIT On/Off switch, Design system (paste / Upload .md… / Expand / size line), Pen file path (Choose…), Tone of copy, card note, changed-by line + Undo, error line, FOR ONE PROJECT Copy row.
- Requests (10): BRING ME (Anything / Let me pick + topic checklist of 10), WHAT COMES TO WAGGLE (slider Off + 3 columns, examples, Recommended, summary line), HOW OFTEN, DETAIL (+ note), HOW AGENTS WRITE TO YOU (+ note), HOW YOU LIKE TO LEARN (+ note), AFTER YOU DECIDE (+ note), generated text box, footer note.
- Ask less (5): master toggle, WHICH SMALL THINGS (Naming, Wording, Formatting, Test choices toggles, dim when off), note, error line, footer.
- Phone (14): TELEGRAM guide (Step n of 3, Start over, Open BotFather, I have my token, Bot token field, Check token, Get my code, Open your bot, /start code, Next / Back, Connected, Send a test, Disconnect), SLACK guide (5 steps, Copy manifest, tokens, Check tokens, Swap them, Back), privacy lines.
- Sharing (3): SHARING toggle + line, status line ("N shared…"), Keychain line.
- Account (6): Signed in / Not signed in, Sign in / Sign out / Try again / Cancel, YOUR SHARED LINKS rows with Open and Stop sharing, empty line, confirm.
- Updates (6): version row + Check now + "Checked 5 minutes ago", What's new, three toggles, dev-build line.
- Data & privacy (6 + Usage): Data folder + Show in Finder, Logs + Show logs, Answered requests + Clear answered… + confirm, then the Usage section (own mockup).
- Help (7): COMMON FIXES (Waggle unavailable; Run setup again), DIAGNOSTICS Copy, Install guide ↗, Check my setup + Run check, check results with ok / fail / skip icons.
