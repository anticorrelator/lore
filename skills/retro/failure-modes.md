# Retro Failure Mode Reference

Specific failure patterns discovered across retros. Consult when scoring reveals anomalies — not every pattern applies to every retro.

## A. Backlink Resolution Failures

Affects: Dimension 1 (Delivery), Dimension 3 (Gaps)

**Stale backlinks:** Entry existed once but was moved/renamed by `/renormalize`. The slug was valid at plan-authoring time. Fix: `/renormalize` should update backlinks in active work items. >30% unresolved rate caps Dimension 1 at 2.

**Phantom backlinks:** Plan author cited entries that *never existed* — the slug describes a concept that should have an entry but doesn't. Signals a coverage gap, not infrastructure failure. Affects Dimension 3 more than Dimension 1. Collect phantom slugs as proactive capture candidates.

**Detection:** For each unresolved backlink, search by slug fragments across categories. Match found under different path = stale. No match anywhere = phantom.

**Pipeline delivery failure:** Plan has `**Knowledge context:**` backlinks but task generation produces tasks without resolved knowledge. Silent failure — plan looks complete, tasks look reasonable, workers get zero context. Caps Dimension 1 at 2.

**Partial resolution:** Some tasks in a phase get `## Prior Knowledge`, others don't, despite phase-level backlinks applying to all. Root cause: backlink resolution matches on task keywords rather than inheriting phase-level context. Caps Dimension 1 at 3. Fix: propagate phase-level backlinks to all tasks.

**Annotation-only delivery:** `## Prior Knowledge` sections contain plan-author annotations (one-sentence summaries from `**Knowledge context:**` blocks) rather than full entry content. Format: `**[[knowledge:...]]** — <annotation from plan>`. Workers receive the behavioral directive in compressed form but not supporting reasoning, examples, or caveats. Scoring impact: caps Dimension 1 at 3 for general implementation cycles where workers may need supporting reasoning and examples that annotations omit. Exception: for **prose/convention implementation cycles** (editing SKILL.md, protocol documents, convention files), the main SKILL.md rubric applies — annotation-only CAN score 5 when (a) annotations are implementation-facing with specific behavioral directives, (b) completeness is high (>80% non-empty), and (c) implementation output shows correct application across tasks. The rationale: prose workers need WHY orientation to write correct prose; they don't need full code-level examples. If workers misapplied or ignored annotated principles, score Dimension 1 = 2 regardless of cycle type. Distinct from "pointer bypass" (which gives no content at all) and full resolution (which embeds full entry prose). Detection: check if `## Prior Knowledge` section entries contain prose beyond the annotation or just the `[[backlink]] — annotation` format.

**Compound failures:** When multiple backlink failure modes co-occur, the lowest individual dimension cap applies. Do not average — compound failures are worse than their components because each compensating layer (tasks.json pre-resolution → lead prefetch → lead manual embedding) failed in sequence.

**Cross-cutting backlink redundancy:** All phases share the same backlinks with no phase-specific entries. Task descriptions receive identical `## Prior Knowledge` content regardless of phase. Technically correct delivery (0 unresolved, content is relevant), but phases that needed different knowledge got the same content — delivery precision is low. Does NOT cap Dimension 1 (content was delivered and relevant), but note as a spec authoring signal: the plan author didn't identify phase-specific knowledge needs. Flag in D1 narrative when all N tasks share identical backlink sets. Mitigation: during `/spec` synthesis, distinguish cross-cutting references (go in `## Related`) from phase-specific knowledge (go in phase-level `**Knowledge context:**` blocks).

**Exception — single-file prose rewrite cycles:** When all phases edit the same prose file (SKILL.md, protocol document, convention file), cross-cutting backlink redundancy is *expected and correct* — all phases need the same conventions because they're editing the same artifact type. Do not flag as low delivery precision in this scenario. Reserve the redundancy note for multi-file cycles where different phases target different subsystems or artifact types and same knowledge is genuinely an imprecision, not a correct invariant.

**Context backlink contamination:** Related work items (consumer references, linked issues) added to `**Knowledge context:**` blocks instead of `## Related`. These entries have no annotation text — they describe relationships, not design rationale — so they appear as bare backlinks in task `## Prior Knowledge` sections. This inflates the "bare backlink" count and depresses annotation completeness metrics even though the knowledge entries themselves are fine. Detection: bare backlinks in `## Prior Knowledge` that resolve to `_work/` paths (not `conventions/`, `architecture/`, etc.) are context backlinks, not knowledge backlinks. They dilute annotation completeness without delivering actionable content. Scoring impact: subtract context backlinks from the denominator when computing annotation completeness — a bare `[[work:...]]` is a spec authoring error, not a delivery failure of a knowledge entry. Mitigation: during `/spec` synthesis, place consumer/related work item references in `## Related`, never in `**Knowledge context:**`.

## B. Lead Bypass

Affects: Dimension 1 (Delivery), Dimension 5 (Delta)

**Full bypass** (Dimension 1 ≤ 2): Lead's TaskCreate descriptions completely omit `## Prior Knowledge` content. Workers start with zero knowledge context.

**Pointer bypass** (Dimension 1 ≤ 3): Lead includes a reference to pre-resolved knowledge but doesn't embed the actual content. Converts push delivery into pull.

**Justified bypass:** Lead reads target files, accumulates enough context to write code-level instructions (line numbers, exact edits) that are strictly more actionable than abstract knowledge entries. Two sub-levels:
- *Lead-paraphrase* (Dim 1: 3): Worker prompts include guidance traceable to knowledge entries, combined with code-level specifics. Knowledge worked through the lead as intermediary.
- *Full bypass* (Dim 1: ≤ 2): Worker prompts contain only code-level instructions with no traceable knowledge substance.

When justified bypass recurs, the knowledge system's ROI for small/well-specified work items is in plan quality (spec time), not worker efficiency (implementation time).

**Template gap:** When `~/.claude/agents/worker.md` is absent, the lead assembles an ad-hoc worker prompt from scratch. Workers receive structurally variable prompts (no canonical template), which may produce inconsistent `**Observations:**` and `**Changes:**` sections — reducing retro evidence quality. Different from full bypass (the lead still injects knowledge context) but reduces reliability of the reporting structure. Detection: check conversation context for "File does not exist" when reading `~/.claude/agents/worker.md`. Mitigation: create the agent template; until then, note as evidence quality degradation in the retro's evidence summary.

**Detection:** Compare tasks.json descriptions against actual TaskCreate descriptions. Note *justified* vs *accidental*.

**Evidence availability:** TaskCreate descriptions are ephemeral (conversation context only). Lead-bypass detection is only fully verifiable in **same-session retros**. For cross-session retros, infer from: (a) worker observations about missing context, (b) notes.md delivery gaps, (c) absence of knowledge-traceable guidance in worker reports. Cap Dimension 1 at 3 cross-session without direct evidence of delivery.

## C. Cold-Start and Prefetch Failures

Affects: Dimension 1 (Delivery), Dimension 3 (Gaps)

**Cold-start:** No knowledge exists for the investigated domain. `lore prefetch` returns empty. Valid scenario, but the researcher prompt should note "No prior knowledge found — report patterns for capture." This turns cold-start into a seeding opportunity.

**Prefetch silent failure:** `lore prefetch` exits 0 but returns empty. Lead may silently fall back to manual preambles or skip injection. Caps Dimension 1 at 3 (delivery succeeded manually but pipeline failed).

**Prefetch query recall failure:** Knowledge entries exist for the investigated domain, but `lore prefetch` returns empty because the compound multi-word query doesn't match FTS5 index terms. Distinct from cold-start (entries genuinely absent) and silent failure (tool bug). Detection: after prefetch returns empty, check the knowledge index (`_manifest.json` or `_index.md`) for entries in the same domain — if entries exist under different terms/titles, this is recall failure. Scoring impact: recall failure is worse than true cold-start for Dimension 1 because the lead could have tried decomposed single-term queries, browsed the index, or used `lore search` as fallback. When prefetch returns empty, the lead should attempt at least one alternative retrieval before concluding "no knowledge exists." Caps Dimension 1 at 2 when the lead treats recall failure as cold-start without attempting fallback retrieval.

**Spec-cycle cold-start tracking:** Cold-start for >50% of investigations caps Delivery at 3; >75% caps at 2. If the same domain produces cold-starts across multiple specs, create a proactive knowledge-seeding work item.

**Explore agent shell fallback gap:** The researcher template documents `lore search` as a fallback retrieval mechanism when prefetch returns empty. But Explore agents lack Bash access and cannot execute shell commands — the fallback is dead code for non-general-purpose agents. Detection: prefetch returned empty AND researchers were spawned as Explore type. Recovery is impossible after dispatch — the gap must be caught at dispatch time. Scoring impact: caps Dimension 1 at 2 (same as prefetch recall failure with no fallback attempted). Mitigation: when `lore prefetch` returns empty before spawning Explore researchers, the lead must (a) try decomposed single-term queries with `lore search`, (b) browse `_manifest.json` for relevant domain entries, and (c) manually inject any found entries into researcher prompts. Use general-purpose agents only when active runtime knowledge retrieval is needed during investigation (e.g., web research, dynamic search). Do not rely on Explore agents to self-recover from empty prefetch results.

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

**Spec-completeness ceiling:** When a spec's investigation phase is thorough enough to produce a complete implementation recipe (exact line numbers, exact edits, exact function signatures), the knowledge system's value at implementation time is structurally capped — workers follow the recipe rather than relying on knowledge orientation. Delta ≤3 is expected and not a failure. The knowledge system's ROI for this cycle was front-loaded into the spec phase, not the implementation phase. Detection: plan.md contains line-number-level specificity and exact edit instructions for every task; execution-log shows workers made zero divergent choices. This is a sub-case of plumbing-vs-value gap but distinct because it's a sign of *high-quality spec work*, not *low-quality knowledge delivery*. Do not mark as a failure — note in Delta analysis and score Gap/Creation dimension (Dim 3) based on what gaps the implementation phase surfaced for future cycles.

**Micro-fix ceiling:** Single-file interactive fixes under ~50 lines done without workers have a structural Delta ceiling of 2, regardless of delivery quality. The knowledge system's ROI on micro-fixes is almost entirely **creation** (new patterns captured) rather than **consumption** (existing patterns applied). Dimensions 1 and 4 are inherently low-signal for micro-fix cycles — score them honestly but note that low scores don't indicate a failure worth fixing. Focus Dimension 3 (gaps) on whether the cycle produced captures that improve future coverage. Detection: work item has 1 phase, 1 task, no workers, notes.md empty, execution-log entries only from `/remember`.

**Sequential same-file phantom work:** When multiple sequential tasks all target the same file, one fast worker typically implements beyond their assigned scope, leaving subsequent workers to claim their tasks and report "no changes needed — already implemented." Observable in retro via worker completion reports containing "no new changes needed." Affects Delta interpretation: idle workers aren't a knowledge system failure, but they indicate over-serialization in task design. Note when >2 workers report phantom completion on the same file. Mitigation at spec time: consolidate sequential same-file edits into a single task, or explicitly note "worker-3 before worker-4 on this file."

**Shared-artifact sequential bottleneck:** When all tasks in a phase write to the same foundational artifact (e.g., a protocol doc, a shared schema file), they must be ordered strictly sequentially regardless of team size — workers 2-N are idle while worker-1 completes the chain. Distinct from "sequential same-file phantom work" (which is about workers running ahead of scope): here the sequencing is intentional to prevent merge conflicts, but the team size is over-provisioned for that phase. Observable in retro: workers 2-N report "no unblocked tasks available" during Phase 1 then become active in later phases. Affects Delta interpretation — team efficiency is front-loaded. Mitigation at spec time: (a) consolidate shared-artifact phase into a single task covering all sections (one worker, one pass, no coordination cost), OR (b) ensure the shared-artifact phase is short relative to total work so idling time is bounded. Affects Dimension 1 scoring only if idle workers indicate a knowledge delivery failure (they don't in this case — it's a task design constraint).
