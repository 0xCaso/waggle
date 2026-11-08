# What should I build next after the fx and Scrawl checks?

Decided: 2026-10-20 · Case: c_23cdb32a-790d-4034-b85b-d24f5d951aeb

## Question and choice
Build fx support, a Scrawl recording in replies, both, or nothing for now?
The operator chose "Nothing for now": do neither now, keep both as ideas.

## Why
The operator gave no note. Neither item blocks the sharing flow, and Waggle already works with fx as it is.

## Constraints
- fx stays a client that works but is not documented or detected. Waggle cannot wake it: the agent must call waggle_check itself.
- No Scrawl code in the app or the daemon.

## Ruled out
- fx support (shorten waggle_ask to under 1024 bytes, document fx): small, but not wanted now. It was the recommendation.
- Reply with a Scrawl recording: a bigger story, and Scrawl needs macOS 26 or later.

## Comments
none

## Open questions
- The waggle_ask description is 1503 bytes. fx cuts MCP tool descriptions at 1024 bytes. Shorten it when fx support comes back.

## Sources
- Case c_23cdb32a-790d-4034-b85b-d24f5d951aeb.
- fx check: fx v0.0.14 in a sandbox HOME with a fake model. waggle_ask made the case, and waggle_check returned the reply after `fx ask --resume last`.
- https://github.com/kitlangton/scrawl (README).
