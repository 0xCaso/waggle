# The 44 visual types

Choose the type by what you show. Then use the rules in `SKILL.md`. Every type obeys the same budget and the same connector rules. The layout of one type is a grammar: keep to it and do not mix two.

Source: the type list of `diagram-design` by Cathryn Lavery (MIT). Waggle ships the list. It does not ship the long per-type pages.

## Systems and structure

| You show | Type |
|---|---|
| Parts and links of one system | Architecture |
| A structural change between a Before and an After, with a list of changes | Architecture delta |
| An old IT landscape by phase or team (the before state) | IT current-state |
| Where software runs: zones, hosts, replicas, ports | Deployment |
| What depends on what, with fan-in and cycles | Dependency graph |
| Layers of abstraction | Layer stack |
| Containment and scope | Nested |
| Parent and children | Tree |
| Owners, reporting and escalation | Org chart |
| Classes with operations, inheritance and composition | UML class |
| Entities, fields and relations | ER / data model |
| Physical tables with SQL types, keys and indexes | Database schema |
| Parts of one object pulled apart on one axis | Exploded axonometric |
| One floor or site seen from above at an angle | Axonometric plan |

## Behaviour and flow

| You show | Type |
|---|---|
| Decision logic with branches | Flowchart |
| Messages between actors over time | Sequence |
| States, transitions and guards | State machine |
| A process with handoffs across teams | Swimlane |
| A process with several actors and data handoffs | Process |
| A cycle where the last step feeds the first | Loop |
| Who does what at each step of a data pipeline | Data flow |
| A data stack on a container cluster | High-level |
| Tiers of stored data with quality levels | Medallion |
| Sources, a core and consumers of a data platform | DP integration |
| Permissions per role and component | DP security matrix |
| A quantity that splits and merges across stages | Sankey |

## Time and plans

| You show | Type |
|---|---|
| Events placed in time | Timeline |
| Tasks and phases on a timeline | Gantt |
| A person's steps through an experience, and how it feels | User journey |
| Work in progress by state, with limits | Kanban |
| A story backbone cut into releases | Story map |

## Position, ranking and numbers

| You show | Type |
|---|---|
| Two-axis positioning or priority | Quadrant |
| Entities scored on 3 to 5 criteria | Radar / spider |
| One series over cyclic categories | Polar chart |
| Overlap between sets | Venn |
| A ranked hierarchy or a drop-off | Pyramid / funnel |
| Value chain against evolution | Wardley map |
| Causes of one effect, grouped | Fishbone |
| A comparison across categories | Bar chart |
| A start total bridged to an end total | Waterfall |
| Part of a whole, size is the story | Treemap |
| Cells whose fill shows a value | Heatmap |
| Trends, slopegraph, ridgeline or bump chart | Line chart |
| Two variables: scatter, bubble or beeswarm | Scatter plot |

## Rules of thumb

- Most Waggle asks need one of: Architecture, Flowchart, Sequence, State machine, Swimlane, Timeline, Tree, Layer stack, ER, Quadrant. Start there.
- Charts that show data (the last group) are better as an html_bundle chart with the real numbers. Use `dataviz` if you have it.
- Over the budget in `SKILL.md`: split into an overview and a detail.
