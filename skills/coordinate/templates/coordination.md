# Coordination Ledger — <feature name>

<!-- Copied from skills/coordinate/templates/coordination.md. Authored directly by the
     coordinator (freeform work-item artifact). Resumability test: a fresh coordinator
     or the human can resume mid-flight from this file + item notes alone.
     Vocabulary is pinned in skills/coordinate/SKILL.md § The ledger:
       step status:    pending | in-flight | blocked-on:<ref> | blocked-on-input | done | dropped
       step verdict:   full | partial | none
       gate mechanism: hold | flag | notify
       retro outcome:  done | deferred (rate, stratum) | skipped (user) | dispatched:<ref> -->

**Feature under coordination:** <one line — what this arc delivers>
**Intent anchor:** [[work:<slug>]] — read it there; don't paraphrase it here.
**Budget posture:** <e.g. cost-sensitive; duration-only until spend telemetry lands>
**Standing directives in force:** <model floor, routing policy, retro cadence — cite the preference entries>

## Journal cursor

`next_cursor: 0` <!-- opaque; store verbatim from `lore session events`, echo via --since, never compute -->

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
