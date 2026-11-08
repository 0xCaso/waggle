# Which friend-usage fixes and ideas do we do first?

Decided: 2026-10-27 · Case: c_dfc32820-9435-4c69-943e-0f63619530fb

## Question and choice
We read a friend's usage export (6 to 27 Oct, app 0.2.62). The question was which fixes and ideas to do first. The operator chose five of six:

1. "Fix errorKind in shim.ts: classify from the error type and code, not from words in the text. Add a coded
   error_code (no text) to the tool-call log and the export."
2. "Show on the case that the agent session ended before you type. Offer to continue in a new session with
   your answer and the case context."
3. "Make the reply composer the main path, with quick reply chips such as Go ahead and Show me more."
4. "Cut low-stakes asks: a Let the agent decide rule per kind of ask, or batch small asks into one case."
5. "Build on region comments and zoom: compare two screenshots, comment on regions in a bundle."

## Why
- Error labels: `errorKind` (`daemon/src/mcp/shim.ts:484`) matches words like "artifact" or "file" anywhere in
  the text. An unknown guide topic counts as `error_artifact` because the message lists "artifacts". Without
  true labels and a coded reason, we cannot find why some html_bundle asks failed on 10 and 19 Oct.
- Ended session: many `reply_failed` events. The cause is
  `session_unreachable`: the friend answers after the Claude session closed (`store.ts` `setSessionState`).
- Composer: many replies are a message only, and many use the "discuss" intent.
- Fewer asks: many dismisses, rising after 19 Oct. On decision asks the friend took the
  recommendation more often than not.
- Visual review: region comments (62) and screenshot zoom (104) started on 23 Oct and grow fast.

## Constraints
- No error text and no ask text go into the usage log or the export. Only coded values.
- Local only. Continuing in a new session uses the existing start-a-session path (Terminal or T3 Code). No new
  network calls.
- Features stay optional. "Let the agent decide" is off until the operator turns it on.
- UI copy: plain, friendly, no em-dashes.

## Ruled out
- Group the queue by session or project: not chosen now. 2 sessions hold most cases, but the friend triages from
  the queue and auto-advance without trouble.

## Comments
- Operator: "make sure the Ask for chips are all visible or scrollable horizontally right above the input box
  as well". Today `AskForDetailRowView` (`apps/macos/Sources/Knock/Composer/AskForDetailView.swift`) drops the
  pills that do not fit (`PillFit.count`). Added to task 3: every pill is reachable, in a row that scrolls
  horizontally, placed right above the input box.

## Open questions
- Fewer asks: a per-kind rule, batching, or both. This needs a design round before the build.
- Visual review: which comes first, compare two screenshots or comments on bundle regions.
- Continue in a new session: which context goes into the new prompt (the question, the options, the answer,
  the last artifact).

## Sources
- Case c_dfc32820-9435-4c69-943e-0f63619530fb
- `~/Downloads/waggle-usage-2026-10-27.json`
- `daemon/src/mcp/shim.ts:484` (`errorKind`)
- `daemon/src/store.ts` (`setSessionState`, `insertReply`, `retryReply`)
- `apps/macos/Sources/Knock/Composer/AskForDetailView.swift`

## Tasks

### T1. True error labels and a coded error reason
From: Question and choice, item 1.
- `errorKind` no longer reads free text. A guide topic error is `error_invalid`, not `error_artifact`.
- Each `ArtifactError` and validation error carries a stable code (for example `bundle_dir_not_found`,
  `bundle_entry_missing`, `html_empty`, `unknown_guide_topic`).
- `tool_calls` gets an `error_code` column. The export and the usage report include it. No error text is stored.
- Tests: one per code family, plus the guide-topic case that is wrong today.

### T2. Ended session: tell me before I type, and continue in a new session
From: Question and choice, item 2.
- A case whose owning session is ended shows that on the case, above the composer, before any typing.
- The case offers "Continue in a new session". It starts a session with the existing start-a-session path,
  with the question, the options and the operator's answer in the prompt.
- A reply to an ended session is not lost: it stays visible and goes to the new session.
- `reply_failed` for an ended session drops in the usage log. Daemon and app tests cover the new path.

### T3. Composer first, and every Ask for chip reachable
From: Question and choice, item 3, and Comments line 1.
- The reply input is the main control of the case pane. Options stay one click away.
- Quick reply chips ("Go ahead", "Show me more" and the current Ask for pills) sit in one row right above the
  input box.
- Every chip is reachable. When they do not fit, the row scrolls horizontally. No chip is dropped.
- Design first: send a prototype in Waggle for review before the SwiftUI build. Follow waggle-taste.

### T4. Fewer low-stakes asks (design round)
From: Question and choice, item 4, and Open questions line 1.
- A design round in Waggle compares a per-kind "Let the agent decide" rule and batching small asks.
- The operator picks one before any build.
- The feature is off by default.

### T5. More visual review (design round)
From: Question and choice, item 5, and Open questions line 2.
- A design round in Waggle shows compare two screenshots and comments on bundle regions.
- The operator picks the first one to build.
