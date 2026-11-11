# Which home page stays on waggle.so: the one on main, or the new design?

Decided: 2026-11-10 · Cases: c_0f3776ce-a5f1-4c02-b494-b67352b19f49, c_2d86afa5-7d9a-404e-9303-7e9f7e820453

## Question and choice
The operator asked for "a full glow up to the landing page" and to "make it more interactive". Three designs went to the operator. The operator picked "Product first, animated".

The design was built on the old repository, where the home page was the manifesto hero. The home page on main was newer (8 November). The second question was which page stays. The choice: "Replace it with my design". "I move my design to the correct repo and add the GitHub link and the open source section from the page on main."

## Why
The operator's words in the design round:

- "i like the interactiveness of "try the ask" but wihtout the agent closing the loop it doesn't make sense?"
- "i preferred the animated product-first variant"
- "where the example of prototype mockup is?"

The operator gave no reason in words for "Replace".

## Constraints
- Download for Mac is at the top of the home page and opens `/download/`.
- The app preview plays a demo by itself, stops when the visitor clicks, and does not play with Reduce Motion on.
- The demo shows the agent's work: each option has its prototype screen, and the request shows that the agent continues after the answer.
- The header has the GitHub link. The footer says "Open source · Apache 2.0". The page has the "Stays on your Mac" and "Open source" texts from the page it replaces.
- Copy is plain and friendly, with no em-dashes.

## Ruled out
- "Keep the page on main": the agent's recommendation. Not picked.
- "Keep it, add parts of mine": not picked.
- "Try the ask" (the hero is one request the visitor answers): the operator liked the interaction but preferred the product-first page.
- "The hive" (a scroll story with the bees): not picked.

## Comments
- "without the agent closing the loop it doesn't make sense": the demo shows "Sent. The agent is building it now" and the request moves to a working state.
- "where the example of prototype mockup is?": each option in the demo has its own prototype screen, under "The work to look at".

## Open questions
- The page it replaces had an "Install with your agent" button, a hero loop with three requests and a pricing review. They are not on the new page. The install page keeps "Install with your agent".
- The prototype screens in the demo are small drawings. A real Waggle screenshot can replace them later.

## Sources
- Cases c_0f3776ce-a5f1-4c02-b494-b67352b19f49 and c_2d86afa5-7d9a-404e-9303-7e9f7e820453.
- `site/index.html` before and after this change.
- `docs/decisions/2026-11-08-site-open-source-launch.md`, `docs/decisions/2026-11-10-site-tracker.md`.
