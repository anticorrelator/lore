# Retro Failure Mode Reference

Specific failure patterns discovered across retros. Consult when scoring reveals anomalies — not every pattern applies to every retro.

## A. Backlink Resolution Failures

Affects: Dimension 1 (Delivery), Dimension 3 (Gaps)

**Stale backlinks:** Entry existed once but was moved/renamed by `/renormalize`. The slug was valid at plan-authoring time. Fix: `/renormalize` should update backlinks in active work items. >30% unresolved rate caps Dimension 1 at 2.

**Phantom backlinks:** Plan author cited entries that *never existed* — the slug describes a concept that should have an entry but doesn't. Signals a coverage gap, not infrastructure failure. Affects Dimension 3 more than Dimension 1. Collect phantom slugs as proactive capture candidates.

**Detection:** For each unresolved backlink, search by slug fragments across categories. Match found under different path = stale. No match anywhere = phantom.

**Pipeline delivery failure:** Plan has `**Knowledge context:**` backlinks but task generation produces tasks without resolved knowledge. Silent failure — plan looks complete, tasks look reasonable, workers get zero context. Caps Dimension 1 at 2.

**Partial resolution:** Some tasks in a phase get `## Prior Knowledge`, others don't, despite phase-level backlinks applying to all. Root cause: backlink resolution matches on task keywords rather than inheriting phase-level context. Caps Dimension 1 at 3. Fix: propagate phase-level backlinks to all tasks.

**Compound failures:** When multiple backlink failure modes co-occur, the lowest individual dimension cap applies. Do not average — compound failures are worse than their components because each compensating layer (tasks.json pre-resolution → lead prefetch → lead manual embedding) failed in sequence.

## B. Lead Bypass

Affects: Dimension 1 (Delivery), Dimension 5 (Delta)

**Full bypass** (Dimension 1 ≤ 2): Lead's TaskCreate descriptions completely omit `## Prior Knowledge` content. Workers start with zero knowledge context.

**Pointer bypass** (Dimension 1 ≤ 3): Lead includes a reference to pre-resolved knowledge but doesn't embed the actual content. Converts push delivery into pull.

**Justified bypass:** Lead reads target files, accumulates enough context to write code-level instructions (line numbers, exact edits) that are strictly more actionable than abstract knowledge entries. Two sub-levels:
- *Lead-paraphrase* (Dim 1: 3): Worker prompts include guidance traceable to knowledge entries, combined with code-level specifics. Knowledge worked through the lead as intermediary.
- *Full bypass* (Dim 1: ≤ 2): Worker prompts contain only code-level instructions with no traceable knowledge substance.

When justified bypass recurs, the knowledge system's ROI for small/well-specified work items is in plan quality (spec time), not worker efficiency (implementation time).

**Detection:** Compare tasks.json descriptions against actual TaskCreate descriptions. Note *justified* vs *accidental*.

**Evidence availability:** TaskCreate descriptions are ephemeral (conversation context only). Lead-bypass detection is only fully verifiable in **same-session retros**. For cross-session retros, infer from: (a) worker observations about missing context, (b) notes.md delivery gaps, (c) absence of knowledge-traceable guidance in worker reports. Cap Dimension 1 at 3 cross-session without direct evidence of delivery.

## C. Cold-Start and Prefetch Failures

Affects: Dimension 1 (Delivery), Dimension 3 (Gaps)

**Cold-start:** No knowledge exists for the investigated domain. `lore prefetch` returns empty. Valid scenario, but the researcher prompt should note "No prior knowledge found — report patterns for capture." This turns cold-start into a seeding opportunity.

**Prefetch silent failure:** `lore prefetch` exits 0 but returns empty. Lead may silently fall back to manual preambles or skip injection. Caps Dimension 1 at 3 (delivery succeeded manually but pipeline failed).

**Prefetch query recall failure:** Knowledge entries exist for the investigated domain, but `lore prefetch` returns empty because the compound multi-word query doesn't match FTS5 index terms. Distinct from cold-start (entries genuinely absent) and silent failure (tool bug). Detection: after prefetch returns empty, check the knowledge index (`_manifest.json` or `_index.md`) for entries in the same domain — if entries exist under different terms/titles, this is recall failure. Scoring impact: recall failure is worse than true cold-start for Dimension 1 because the lead could have tried decomposed single-term queries, browsed the index, or used `lore search` as fallback. When prefetch returns empty, the lead should attempt at least one alternative retrieval before concluding "no knowledge exists." Caps Dimension 1 at 2 when the lead treats recall failure as cold-start without attempting fallback retrieval.

**Spec-cycle cold-start tracking:** Cold-start for >50% of investigations caps Delivery at 3; >75% caps at 2. If the same domain produces cold-starts across multiple specs, create a proactive knowledge-seeding work item.

## C2. Spec Investigation Factual Errors

Affects: Dimension 3 (Gaps), Dimension 4 (Alignment)

**Factual propagation:** Spec investigators produce findings that contain factual errors about the codebase (e.g., misclassifying a hook's lifecycle stage, overstating code duplication percentages). These errors propagate through plan.md design decisions into tasks.json and eventually into worker task descriptions. Workers either implement based on wrong assumptions (causing rework) or catch the error during implementation (adding evaluation overhead).

**Detection:** Compare plan assertions against worker observations. When workers report "the plan said X but I found Y", trace the error back to the spec investigation finding. Common patterns: (a) lifecycle/timing misclassification (e.g., SessionStart vs Stop hook), (b) duplication estimates based on conceptual similarity rather than code-level analysis, (c) caller/dependency counts underestimated.

**Scoring impact:** Single factual error caught by evaluation task: Dimension 4 no lower than 3 (plan was mostly correct, error contained). Factual error that caused incorrect implementation requiring rework: Dimension 4 caps at 2. Multiple factual errors: Dimension 4 caps at 1.

**Mitigation:** For consolidation/refactoring work items, spec investigations should include concrete overlap measurements (shared function counts, caller grep results) rather than conceptual similarity assessments. Phase 3 "evaluation" tasks serve as a structural safeguard — they catch spec errors before irreversible implementation.

## D. Delta Modifiers

Affects: Dimension 5 (Delta) interpretation only — does not cap scores.

**Prototype-cascade:** For batched similar tasks, knowledge value concentrates on the first task (the prototype). Subsequent workers reference the prototype as template rather than knowledge entries. Score Delta based on the full batch including prototype, not averaged.

**Same-knowledge saturation:** When all phases operate in the same domain, every phase references the same entries. First worker gets value; subsequent workers see identical content with zero marginal insight. Note in Delta analysis — contribution is front-loaded.

**Meta/self-referential work:** When implementation IS knowledge work (editing knowledge conventions, enhancing the store), Delta will be inherently low (1-2). Workers are domain-native. Score honestly but note classification for trend analysis.

**Plumbing-vs-value gap:** When Dimensions 1-4 are 4-5 but Delta is ≤3, delivery mechanics are working but value contribution is low. Consider: (a) was the work item small enough that code alone sufficed? (b) did knowledge contribute at spec time? If so, this is an expected ceiling, not a problem.
