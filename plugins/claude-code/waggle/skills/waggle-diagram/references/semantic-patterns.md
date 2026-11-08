# Semantic patterns

A pattern says what a system does. A type says how to lay it out. Choose a pattern first when behaviour, state, enforcement or risk is the point. Then use its nearest type for the layout. Use one pattern for each diagram. If no pattern fits, choose a type from `types.md`.

Every pattern must read in one still frame. Write each label and each outcome in text, not in colour alone.

| The reader must see | Pattern | Nearest type |
|---|---|---|
| Many arrivals that compete for a limited service | Fan-in queue / bottleneck | Data flow |
| The same questions, inputs, controls and outputs in each stage | Stage framework with slots | Process |
| A loose talk that becomes a structured record | Unstructured input to structured artifact | Data flow |
| Why two similar requests got different results, and where they first differ | Paired policy traces | Flowchart |
| Which routes cross a trust boundary and which are blocked | Secure paved road | Architecture |
| Which controls apply on which enforcement surface | Control catalog | Layer stack |
| How each defence covers the gap of the one before, and what risk is left | Compensating layers | Layer stack |
| Parts that each have a stable id and a link to their code | Traceable block decomposition | Tree |
| One subject through phases, waits, retries, cancel and end states | Lifecycle phase map | State machine |

## Limits and traps for each pattern

1. **Fan-in queue.** At most 5 sources, 5 queue slots, 1 bottleneck, 2 outcomes. Show units (`8/hour`, `3 slots`). Trap: arrows merge before the reader can trace them.
2. **Stage framework.** 3 to 6 stages, 3 to 4 slot kinds, at most 20 filled cells. Keep the slot order the same in every stage. Show empty slots as `Not applicable`.
3. **Input to artifact.** At most 4 exchanges, 6 fields, 1 transformation, 3 provenance links. Show a short excerpt beside the finished artifact. Show unknown fields.
4. **Paired traces.** Exactly 2 traces, 3 to 6 rules, 1 first-divergence marker. Use the same rule order in both. `SKIPPED` means the rule was bypassed. `NOT REACHED` means the evaluation stopped before it.
5. **Secure paved road.** At most 3 trust zones, 8 components, 10 paths, 2 forbidden paths, 1 privileged gate. A blocked path must stop before the boundary. Use line style and a stop symbol, not colour alone.
6. **Control catalog.** 3 to 5 surfaces, at most 24 controls. Each control names its actor (`code`, `platform`, `human`) and its time (`write`, `merge`, `deploy`, `run`). Show gaps.
7. **Compensating layers.** 3 to 5 layers, 1 risk thread. Show what each layer stops, what escapes, and the risk that remains at the end. Never imply zero risk.
8. **Block decomposition.** Follow the Tree limits. Give each block a dotted id (for example `PAY-001-02`) in the type tag chip. Name blocks with nouns, not verbs.
9. **Lifecycle map.** 4 to 5 phases on a left-to-right rail. Put waits and retries in a band below the rail. Put end states (done, cancelled, failed) in their own band.

Source: the patterns of `diagram-design` by Cathryn Lavery (MIT), shortened.
