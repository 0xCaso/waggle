# Which follow-up cuts from the repo audit should I make?

Decided: 2026-11-10 · Case: c_8dc6f244-41af-46d9-a320-97b82b2d3d47

## Question and choice
The audit found four changes that were not routine cleanup. The human picked three:

- "Cut test-only Swift code": delete the Swift functions and values that only tests call, and the tests that cover them.
- "Simplify the case list query": the case list SQL finds the latest reply one time, not 14 times for each row.
- "Remove unused RPC registries": delete `rpcMethods` and `sessionMethods` in `daemon/src/protocol/rpc.ts`.

## Why
The human gave no reason in words. The agent's reasons:

- Code that only tests call looks alive but no screen uses it.
- The registries claim to be the single source of truth, but the server never reads them.
- The query repeats one lookup 14 times, which makes it hard to change.

## Constraints
- The app builds and both test suites pass after each change.
- `cases.list` and `cases.get` return the same fields with the same values as before.
- `docs/protocol-mvp.md` does not change: no method, param or result changes on the wire.
- A symbol stays when the system calls it (delegate methods, `@main`, a decoded enum case).

## Ruled out
- "Trim the event log": not picked. The events table keeps every row. Migration 58 (the index) makes its size cheap to read.
- "Stop here": not picked.

## Comments
none

## Open questions
- Retention for the events table is still not decided.

## Sources
- Case c_8dc6f244-41af-46d9-a320-97b82b2d3d47, artifact "Audit report".
- `daemon/src/store.ts` (`caseSelectColumns`), `daemon/src/protocol/rpc.ts`, `daemon/src/schema.ts` (migration 58).
