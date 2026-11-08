# Open source launch: relay, NOTICE, usage numbers, daily work

Decided: 2026-11-08 · Case: c_186e3e80-65a1-4a6e-8d28-1e6eb4682aec

## Question and choice
Four open points before the first public commit of waggle-so/waggle.

- Relay: "Hide Sharing in the app until the relay is ready for others."
- NOTICE holder: "Simone Staffa and the Waggle contributors".
- Usage numbers in three decision records: "Remove the numbers and keep the reasoning."
- Daily work: "Code work happens in waggle-so/waggle. Stories, plans and fleet setup go to a private waggle-so/waggle-internal repo."

## Why
- Relay: the operator first leaned to "Setting in the app", then wrote "maybe we can mute that relay function for now". A custom relay address needs sign-in and Keychain entries per host. Hiding Sharing defers that work and keeps the launch small.
- NOTICE: a personal name is true now. It can change if a company is formed.
- Usage numbers: the friend did not agree to a public export. The reasoning stays clear without them.
- Daily work: contributors see real work and can send PRs against current code.

## Constraints
- The relay code stays in the public repo, with placeholders and the deploy guide (earlier decision, case c_33b3a143).
- Sharing is hidden in the app, so no Settings entry and no share action are visible. The daemon makes no relay call while it is hidden.
- Existing shared pages are not deleted by the hide. Their links keep working on app.waggle.so.
- Stories, plans, research and fleet config never go to the public repo.

## Ruled out
- No custom relay yet (keep Sharing on, app talks to app.waggle.so only): the operator chose to mute the feature instead.
- Keep relay code private: readers could not check the sharing privacy claims.
- Setting in the app now: more work (UI, sign-in per host, Keychain per host) and a phishing risk.
- Company as NOTICE holder: no company yet.
- Keep the usage numbers: no consent from the friend.
- Private repo with a public mirror: outside PRs are hard to merge.

## Comments
- "maybe we can mute that relay function for now": I asked what to mute, with three options. The operator chose "Hide Sharing in the app".

## Open questions
- Hide Sharing in every build, or only until a later release brings it back? This record assumes: hidden in every build until the operator turns it back on.
- What happens for a user who shares pages today? This record assumes: the links keep working and the app shows nothing about them.
- When to move waggle-releases to the org, and credit for the second author (from the earlier record).

## Sources
- Case c_186e3e80-65a1-4a6e-8d28-1e6eb4682aec.
- docs/decisions/2026-11-08-open-source-waggle.md (the launch plan and tasks).
- daemon/src/connectors/relay.ts, daemon/src/connectors/overrides.ts (one relay host, dev overrides only).
- relay/wrangler.jsonc, relay/README.md (placeholders and the deploy guide).

## Tasks

1. **Hide Sharing.** Criteria: Settings shows no Sharing section, and no share action shows on a case. The daemon makes no relay call, even when the saved `connector.relay` setting is on. One switch in code brings it back. Tests cover the hidden state. The README and SECURITY.md network tables mark Sharing as not available now. From: Question and choice, line 1.
2. **Remove the usage numbers.** Criteria: the three decision records keep their reasoning but no counts from the friend's export. From: Question and choice, line 3.
3. **Create waggle-so/waggle-internal.** Criteria: a private repo holds docs/stories, MVP.md, PLAN.md, original-plan.md, docs/research, DOGFOOD, PILOT, the brand notes, design/knock.pen and .fleet/config. The fleet config points at the public repo for code. From: Question and choice, line 4.
4. **Rewrite AGENTS.md for outside contributors.** Criteria: no fleet, story or Pen-worker rules. It keeps the launchd, KNOCK_HOME, screen-capture and local-only rules, and it links CONTRIBUTING.md. From: Question and choice, line 4.
