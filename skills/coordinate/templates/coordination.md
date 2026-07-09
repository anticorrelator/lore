# Coordination Ledger — <feature name>

<!-- Copied from skills/coordinate/templates/coordination.md. Authored directly by the
     coordinator (freeform work-item artifact). Resumability test: a fresh coordinator
     or the human can resume mid-flight from this file + item notes alone.
     Vocabulary is pinned in skills/coordinate/SKILL.md § The ledger:
       step status:    pending | in-flight | blocked-on:<ref> | blocked-on-input | done | dropped
       step verdict:   full | partial | none
       gate mechanism: hold | flag | notify
       retro outcome:  due (unhandled) | done | deferred (rate, stratum) | skipped (user) | dispatched:<ref> -->

**Feature under coordination:** <one line — what this arc delivers>
**Intent anchor:** [[work:<slug>]] — read it there; don't paraphrase it here.
**Budget posture:** <e.g. cost-sensitive; duration-only until spend telemetry lands>
**Standing directives in force:** <model floor, routing policy, retro cadence — cite the preference entries>

**Retro checkpoint:** Read `lore retro queue`; for each `outcome=due`, `disposition=unhandled` identity, record exactly one explicit disposition through `lore retro handle --outcome-id <id> --action <dispatched|deferred|skipped> --handled-by coordinate`, then ledger the matching outcome. The read is the retro substrate's narrow fold only; it never auto-runs `/retro`.

## Journal cursor

`next_cursor: 0` <!-- opaque; take it from the final {"next_cursor": N} row on `lore session events` stdout (or `--cursor-only`), store verbatim, echo via --since, never compute -->

## Step Ledger

| # | Step | Rung | Executor / route | Call + one-line rationale | Gate | Status | Verdict | Evidence / SHA |
|---|------|------|------------------|---------------------------|------|--------|---------|----------------|
| 1 | <e.g. /spec on item X> | 2 | <hands session / subagent (model)> | <depth/routing/granularity call + why> | notify | pending | — | — |

## Dynamic-acts log

<!-- Everything that isn't a step row: mid-flight item creation, design amendments,
     rubric revisions, inline gate reviews, interview questions and answers,
     unknowns-inventory results, capture-question answers ("nothing" is valid, ledgered).
     Shape: dated entry — decision, one-line rationale, evidence pointer. -->

## Friction log

<!-- Bookkeeping you hand-rolled that a verb should own → feeds the SKILL.md
     "verbs this role wants" list and the sibling verb-namespace item. -->
