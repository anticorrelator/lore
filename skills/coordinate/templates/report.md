# Arc Report — <feature name>

<!-- Copied from skills/coordinate/templates/report.md. Authored by the coordinator at
     arc close (obligation: skills/coordinate/SKILL.md § Close the arc). Lives beside
     the ledger: project home for a multi-item arc, the item's directory for a
     single-item arc.
     Perfect tense throughout — what the arc made permanently true. The Brief says
     what works now; the report says what became true.
     Written for a reader spanning many concurrent arcs who holds none of this arc's
     context or vocabulary: no term the arc coined appears unless re-grounded from
     zero. Before the report is final, a fresh-context advisor reads the draft and
     flags every term it cannot ground from general knowledge; re-ground or remove
     every flagged term.
     Form: concise, bulleted, minimal prose. Section names are free content, not
     pinned vocabulary — rename them freely, but keep all three filter sections and
     their derived/judged split. -->

**Arc:** <one line — what this arc was for>
**Closed:** <date> — <closure verdict in one plain clause>

## What the arc built

<!-- One architecture diagram at arc scale, spec-diagram style: plain-text
     box-drawing, actual file/module/verb names, annotated arrows. Compose it from
     the member specs' Architecture Diagram sections — merge overlapping components,
     keep the boundaries between what different streams built, show the arc's work
     as one picture; never stack member diagrams verbatim. When a member spec has no
     diagram, derive its contribution from its plan's phases and file lists. A
     single-item arc composes from its one spec the same way. -->

```
<composed arc-level diagram>
```

<1–2 sentences reading the diagram for someone who won't study it>

## Decisions that never passed through you

<!-- Derived, not judged — this section is a mechanical diff, which is what makes it
     trustworthy. When a kickoff or interview record exists: enumerate the scope the
     human actually touched (the kickoff record plus interview entries in the
     ledger's dynamic-acts log), enumerate what was decided (ledger decision rows
     plus member specs' Design Decisions), and every subsystem or decision in the
     second list never named in the first lands here. When no kickoff or interview
     record exists: the arc's intent anchor is the only human-passed scope — every
     decided subsystem not named in the anchor is a candidate, and err toward
     inclusion. In either branch, an architecture that went undiscussed gets at
     least a passing mention. Execution-routing decisions drop. -->

- <decision, re-grounded from zero> — <what it forecloses or enables>

## Cut against convention

<!-- Judged: decisions that went against a standing convention or preference. Name
     the convention and say why the cut was right (or knowingly costly). When unsure
     whether a decision qualifies, include it — a spare bullet is cheap to strike, a
     missing one is invisible. -->

- <decision> — <the convention it cut against, and why>

## Surprises

<!-- Judged: what turned out differently than planned — reversals, guards firing on
     unanticipated cases, mechanisms that behaved unexpectedly — each stated with
     what is now true as a result. Same inclusion bias: when unsure, include. -->

- <surprise> — <what is permanently true because of it>
