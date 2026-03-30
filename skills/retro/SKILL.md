---
name: retro
description: "Evaluate knowledge system effectiveness after a work cycle — scores 5 dimensions, writes journal entry, suggests protocol evolution"
user_invocable: true
argument_description: "[work item name or slug]"
---

# /retro Skill

Evaluate how the memory system performed during a specific work cycle. The core question: did the knowledge system make this work meaningfully better, or would you have done the same thing without it?

This is a self-evolving protocol. Like `/self-test`, every invocation must produce at least one concrete evolution suggestion (applied in batch via `/evolve`).

## Step 1: Resolve Work Item

```bash
lore resolve
```

Set `KNOWLEDGE_DIR` to the result and `WORK_DIR` to `$KNOWLEDGE_DIR/_work`.

1. Parse the argument as a work item slug. Use the same fuzzy matching as `/work`:
   - Exact slug match -> substring match on title -> substring on slug -> branch match -> recency -> archive fallback
2. Load `plan.md`, `notes.md`, `_meta.json` from `$WORK_DIR/<slug>/`. If the resolved item is tagged `[archived]`, load from `$WORK_DIR/_archive/<slug>/` instead.
3. If no argument provided, infer from the current git branch.
4. If no work item found, ask the user what work cycle to evaluate.

Report:
```
[retro] Evaluating: <work item title> (<slug>) [archived]  ← include [archived] only when item was resolved from archive
```

## Step 2: Gather Evidence

Read existing artifacts only. No new exploration or code reading needed.

**Work cycle type detection:** Determine if this was an implementation cycle (has `tasks.json` or `/implement` session entries), a review/research cycle (no workers, findings came from interactive dialog), or a **spec-short cycle** (`/spec short` — single-agent plan authoring, no workers or subagents). This affects how Dimensions 1 and 4 are scored — see scoring notes below.

**Spec-short cycle evidence profile:** Most evidence steps return empty (no workers, no friction log). Primary evidence: `plan.md` (design decisions + knowledge context blocks), `tasks.json` (backlink resolution quality), conversation context. Score Dimension 1 as "setup quality" (did the plan set up good delivery for future workers?) and Dimension 4 on whether knowledge entries were load-bearing in design decisions.

### 2a: Worker observations

Worker observations come from the **implementation transcript** (worker SendMessage reports to the lead and TaskUpdate descriptions), NOT from `tasks.json` (which is pre-generated before workers run and contains task definitions, not results). For retros run in the same session as `/implement`, observations are available in the conversation context. For cross-session retros, check `notes.md` for session entries from `/implement` runs that reference worker findings (the `/implement` lead records key findings in its session entry). For review-only cycles, note "no workers" and instead look for subagent launches (background analysis agents in `/pr-self-review`, `/pr-review`) and whether they received knowledge preambles.

**If `execution-log.md` exists** in the work item directory, read it as the **primary** implementation evidence source. Extract per-task completion entries organized by phase: each entry records the task subject, worker Changes and Observations fields, and test result. This is more complete than notes.md session summaries (which capture phase-level highlights) and more reliable than cross-session memory (which degrades). Treat execution-log entries as authoritative for task-level decisions — use them to answer: which tasks completed vs. were rejected, what observations were reported, and which changes were made.

### 2b: Knowledge context blocks and backlink resolution

Read `plan.md` and extract every `**Knowledge context:**` block per phase. These record what knowledge was supposed to be delivered to workers/researchers. For review-only cycles, also check for inline `[knowledge: ...]` citations in plan.md tasks — these indicate knowledge was consulted during plan authoring even without formal context blocks.

**Backlink resolution audit:** First, check which phases used `**Knowledge delivery:** full` vs. annotation-only (the default). For **full-resolution phases**, check `## Prior Knowledge` sections in task descriptions for `[unresolved — Target not found]` markers. Count resolved vs unresolved backlinks. A high unresolved rate (>30%) indicates knowledge store restructuring broke plan references — this is a delivery failure independent of content quality. Report the resolution rate.

**Annotation quality audit (annotation-only phases):** For phases *without* `**Knowledge delivery:** full`, check the `## Prior Knowledge` section for empty annotation entries — backlinks appearing as `- **[[target]]**` with no `— annotation` suffix. Empty annotations mean the spec lead wrote bare backlinks without `— why relevant` text. Count entries with annotation vs. entries without. A high empty-annotation rate (>40%) is a delivery failure for annotation-only phases — the entire ROI of this delivery mode depends on annotation text. Report as: "Annotation completeness: N/M entries had annotation text (X%)."

**Generator injection adjustment (REQUIRED before scoring):** Before computing annotation completeness, check whether bare backlinks in `## Prior Knowledge` originate from the plan's `## Related` section rather than from `**Knowledge context:**` blocks. The task generator (`lore work tasks`) injects all `## Related` backlinks into every task as bare entries — this is expected generator behavior, not a spec authoring failure. To detect: compare bare backlinks in tasks.json against the plan's `## Related` section; if all bare entries match `## Related` entries, this is generator injection. **Subtract these bare entries from the annotation completeness denominator before scoring.** Use only entries that appear in per-phase `**Knowledge context:**` as the denominator. See `failure-modes.md` Section A "Related-section injection by task generator" for scoring impact. Failure to apply this adjustment will over-penalize specs that correctly placed cross-cutting references in `## Related` instead of per-phase context blocks.

**Fallback path audit:** If `tasks.json` does not exist and `lore work tasks` was used (check notes.md for `/implement` session entries), compare the plan's `**Knowledge context:**` backlinks against what the generated task descriptions actually contain. If plan phases have backlinks but generated tasks show "No backlinks found" or lack `## Prior Knowledge` sections, this is a **pipeline delivery failure** — the task generation script dropped the plan's knowledge context. This is worse than an unresolved backlink (which at least signals something was attempted) because it's completely silent. Score Dimension 1 no higher than 2 when this occurs.

**Prefetch hit rate (spec-only cycles):** When the spec lead ran `lore prefetch` for each investigation topic, count how many returned useful content vs. empty results. A low hit rate (<40%) indicates either a domain coverage gap OR a query recall failure — disambiguate by checking the knowledge index for entries in the same domain under different terms. If entries exist but queries missed them, this is a recall failure (see `failure-modes.md` Section C), not a coverage gap. Report as: "Prefetch hit rate: N/M investigations received prior knowledge (X%). Cause: coverage gap / query recall failure / mixed." Affects Dimension 1 (attempted delivery but nothing to deliver ≠ didn't attempt delivery ≠ failed to retrieve what exists) and Dimension 3 (coverage gap only, not recall failure). A low hit rate from recall failure with entries confirmed present signals a retrieval tooling problem, not a store quality problem — score Dimension 3 based on actual coverage, not prefetch results.

### 2c: Session entries

Read `notes.md` and extract all `## YYYY-MM-DD` session entries. These record what actually happened: progress, findings, blockers, remaining work. If `notes.md` is empty or missing session entries, note this as degraded evidence — scoring will rely on plan.md, thread entries, and retrieval logs instead.

**Source hierarchy when `execution-log.md` exists:** If `execution-log.md` has entries covering the implementation period (timestamped entries from `implement-lead`), prefer those for **task-level decisions** — which tasks ran, what changed, what workers observed. Use `notes.md` for **session-level context** that execution-log doesn't capture: blockers encountered mid-session, "what's next" notes, and the lead's synthesis of cross-task patterns. The two sources are complementary, not redundant.

### 2d: Retrieval log

Determine the work period from `notes.md` timestamps (first session entry to last). Read `$KNOWLEDGE_DIR/_meta/retrieval-log.jsonl` and filter entries within that timestamp range. Summarize: total retrievals, average budget usage, branches active.

### 2e: Friction log

Read `$KNOWLEDGE_DIR/_meta/friction-log.jsonl` and filter entries within the same timestamp range. Summarize: total friction events, outcomes breakdown (found / found_but_unhelpful / not_found).

### 2f: Token efficiency estimate

Token efficiency differs by delivery mode — evaluate each phase accordingly.

**Annotation-only phases (default):** `## Prior Knowledge` contains labels + annotation text (~50-200 tokens per phase total). This mode does *not* substitute for file reads — workers still read source files. Estimate value as: (1) wrong-path explorations prevented by orientation framing, (2) first-attempt accuracy gains from "why a choice was made" context, (3) context window savings from not loading full resolved content (~2k-4k tokens avoided per task per phase). Do not apply file-read-replacement estimates here.

**Full-resolution phases (`**Knowledge delivery:** full`):** Estimate how many file reads the resolved content replaced and the approximate token cost (~500-3000 tokens per file). Count: files a worker would have needed to read to discover the same information, grep/search cycles avoided, and wrong-path explorations short-circuited. Summarize as: total file reads prevented, estimated tokens saved.

Report:
```
[retro] Evidence gathered:
  Worker observations: N tasks with observations
  Knowledge context blocks: N phases with context (M/K backlinks resolved)
  Session entries: N entries spanning <date range>
  Retrieval events: N in period
  Friction events: N in period
  Token efficiency: ~N file reads prevented, ~Nk tokens saved (estimate)
```

## Step 3: Evaluate Dimensions

Score each dimension 1-5 with concrete evidence from Step 2. Do not self-assess hypothetically — cite specific artifacts.

### Dimension 1 — Knowledge Delivery

Was knowledge context prefetched and delivered to workers/researchers? For each phase, compare `**Knowledge context:**` in plan.md against what workers actually referenced in their `**Observations:**`.

**For review-only cycles:** Score based on whether background analysis agents received knowledge preambles and whether the reviewer's session-start retrieval provided useful orientation context.

**For spec-only cycles:** Also audit ad-hoc subagents spawned during interactive spec work (e.g., Explore agents for investigation). These are not formal "workers" but still benefit from knowledge preambles. If the spec author dispatched subagents without knowledge context while knowledge search tools were available, this is a delivery failure — the same push-over-pull gap that affects implementation workers applies to spec-time exploration.

**For prose/convention implementation cycles:** When workers edit prose files (SKILL.md, protocol documents, convention files), implementation output is a valid evidence source for knowledge application — not just explicit worker citations in `**Observations:**`. A worker who received `push-over-pull` and produced "This gate is not skippable" and "wait for explicit approval" in the output has demonstrably applied the knowledge, even without citing it. Score Dimension 1 based on the implementation output's alignment with delivered design principles, not solely on whether workers named the entries. Do not penalize workers for applying knowledge silently when the output proves the application.

**Annotation-only delivery note:** For the default annotation-only path, workers don't reference `## Prior Knowledge` entries by name — they internalize orientation framing from annotation text. Evidence of delivery success is the *implementation output*: correct approach choices, absence of wrong-path detours, first-attempt accuracy. Do not penalize annotation-only phases for lack of explicit citation.

**Scoring:**
- 5: Every phase had knowledge context delivered; implementation output shows correct approach choices aligned with design rationale (explicit citations OR correct application evident). For annotation-only: annotations were implementation-facing and completeness was high (>80% non-empty).
- 4: Most phases had context delivered with minor gaps. For annotation-only: some annotations were filing-facing but implementation output still shows orientation effects.
- 3: Context delivered but annotation-only phases had high filing-facing or empty annotation rate (>40%) — framing arrived structurally but was too vague to orient workers. OR: spec-only cycles where the author consulted knowledge but ad-hoc subagents received none.
- 2: Some phases lacked context; workers searched manually. Also: full-resolution phases with >30% unresolved backlinks. Also: pipeline dropped backlinks silently (plan had context blocks but tasks show none). For reviews: knowledge consulted during authoring but not delivered to subagents.
- 1: No knowledge context delivered; workers started from scratch.

### Dimension 2 — Retrieval Quality

Of the knowledge entries that were delivered, were they relevant to the actual work? Check for: entries about the right subsystem, entries at the right abstraction level, entries that were current (not stale).

Evidence comes from worker Observations and any friction-log entries during the period.

**Abstraction-level mismatch:** Entries can be topically relevant but at the wrong abstraction level for the work type. Design rationale entries (WHY) delivered to implementation workers who need code-level guidance (WHERE/HOW) are technically on-topic but not actionable — workers won't reference them. Distinguish this from topical irrelevance (wrong subsystem entirely). Abstraction-level mismatch caps quality at 3; topical irrelevance caps at 2.

**Scoring:**
- 5: All delivered entries were directly relevant, current, and at the right abstraction level for the work type
- 4: Most entries relevant and actionable; one minor mismatch or slightly stale entry
- 3: Entries topically relevant but at wrong abstraction level (e.g., design rationale for implementation workers), OR mixed relevance with some off-target
- 2: Mostly irrelevant or stale entries delivered
- 1: Delivered entries were actively misleading

### Dimension 3 — Gap Analysis

What did workers need that wasn't in the store? Look for: workers who reported searching manually, workers who discovered patterns not in any knowledge entry, workers who hit problems the knowledge store should have warned about.

**Execution-log gap inference:** `source: remember` entries in `execution-log.md` enumerate mid-cycle captures. Each capture listed was absent from the store at cycle start — use them as a confirmed gap list. More reliable than reconstructing worker reports. Severity assessment: (a) *Pattern knowable in advance* — an existing convention or known gotcha that wasn't yet captured. Genuine coverage failure. (b) *Genuinely novel discovery* — implementation surfaced something new, not previously encountered anywhere. Expected; not a coverage failure. Distinguish by reading each capture's `context` field: if it describes re-discovering something that should have been known, score as (a); if it describes first-time observation during implementation, score as (b). A cycle with 0 mid-cycle captures scores 5 by default on this signal.

**Trivial-scope D3=5 note:** For small, single-phase, single-file work items (≤4 tasks, 1-2 target files), D3=5 is trivially achievable — the scope is too narrow to expose knowledge gaps. When scoring D3=5 on such work items, note "trivial scope — gap dimension low-signal" in the narrative. This is not a scoring error but a reduced-confidence indicator. Do not artificially lower the score — just flag it so trend analysis across retros can weight it appropriately.

**Stale-correction-only cycles:** When `/remember` produces 0 new captures but corrects N stale entries, this is a positive D3 signal — the store was comprehensive enough that implementation revealed only drift (outdated claims), not absence (missing patterns). Stale corrections confirm coverage; they do not count as gaps. Score D3 based on uncorrected gaps only. Note "N stale corrections, 0 new gaps" in the narrative as evidence of store maturity for the affected domain.

**Novel-vs-coverage split:** When mid-cycle captures include a mix of genuinely novel discoveries and coverage failures, weight coverage failures more heavily than novel discoveries. A cycle with 2 captures where both are genuinely novel (first-time observation of a runtime behavior never encountered in the codebase) scores D3=4; a cycle with 2 captures where both are coverage failures (pattern exists elsewhere in codebase but wasn't captured) scores D3=3. Mixed cycles: count coverage failures for the primary score, then note novel discoveries as expected and non-penalizing.

**Scoring:**
- 5: No significant gaps — workers found everything they needed
- 4: One minor gap that didn't slow work, OR only genuinely novel discoveries (not coverage failures)
- 3: One significant coverage failure or several minor ones (patterns that should have been in the store)
- 2: Multiple coverage failures; workers did significant manual exploration
- 1: Workers essentially worked without knowledge system support

### Dimension 4 — Plan-Knowledge Alignment

Did the plan's design decisions reference knowledge entries that actually influenced the implementation? Or were they decorative citations? Compare design decision rationale against what workers actually did.

**For review-only cycles:** Did knowledge entries influence the review findings, or did the review produce findings that then corrected/updated knowledge? If knowledge flowed predominantly review→store rather than store→review, score lower — the store was a consumer, not a contributor.

**Scoring:**
- 5: Design decisions directly shaped implementation; knowledge citations were load-bearing
- 4: Most design decisions influenced work; one or two were decorative
- 3: Design decisions existed but workers made independent choices anyway. For reviews: knowledge was cited but findings came primarily from source reading
- 2: Plan cited knowledge entries but implementation diverged significantly. For reviews: knowledge was stale and needed correction from review findings
- 1: No meaningful alignment between plan knowledge and actual work

### Dimension 5 — Spec Utility

Did the spec give workers sufficient guidance that they needed less independent exploration than raw codebase reading would have required?

**Spec-only cycle scoring:** When no `/implement` workers have run yet, Dimension 5 is scored on **structural plan quality** — not worker behavior. Evidence: scope constraints, verification criteria, knowledge context coverage, annotation completeness, external review corrections. Always tag the score as `(predictive)` and note "validate after implementation." A spec that required N external review corrections before handoff caps at 4/5 predictive — the corrections indicate gaps that workers *would have* hit. The definitive D5 score comes from the post-implementation retro, which should re-score this dimension based on actual worker behavior and explicitly compare against the predictive score.

**Evidence sources:** Read execution-log entries and worker completion reports. Look for:
- **Worker escalations** — workers who sent messages asking for clarification or raised blockers (each escalation signals a gap in spec guidance)
- **Out-of-scope file reads** — workers who read files not listed in the phase's `**Files:**` or `**Scope:**` fields (signals that spec didn't provide sufficient orientation; discount reads of obvious shared utilities like lib.sh)
- **Divergent implementation choices** — workers who chose a different approach than the spec suggested (check execution-log Observations or worker completion report Discoveries fields for "I did X instead of Y")
- **Unexpected discoveries** — execution-log Observations fields reporting non-obvious patterns workers had to discover themselves (signals gaps in spec context that knowledge delivery should have covered)

**Scoring:**
- 5: Workers needed no out-of-scope exploration — all decisions were spec-guided. Zero escalations. No unexpected discoveries that spec should have anticipated. Workers' Observations confirm spec context was sufficient.
- 4: Workers made one or two out-of-scope reads for minor orientation, or one escalation, but implementations matched spec intent. Unexpected discoveries were genuinely novel (not spec gaps).
- 3: Workers made several out-of-scope reads or had 2-3 escalations. Some divergent choices. Unexpected discoveries suggest the spec left workers to infer context the spec author had but didn't encode.
- 2: Workers frequently explored beyond spec-listed files or escalated repeatedly. Multiple divergent choices. Spec provided task decomposition but insufficient guidance — workers essentially re-investigated the codebase independently.
- 1: Spec provided no meaningful guidance beyond task names. Workers did all orientation themselves. Equivalent to receiving a task list with no context.

**Interpretation notes:** See `failure-modes.md` section D for Spec Utility modifiers. Out-of-scope reads for obviously-shared utilities (lib.sh, test fixtures) should not count against the score. Divergent choices are only penalties when the spec had a clear intent that workers ignored — if the spec was silent on approach, worker divergence is expected. A spec that achieves 5 on this dimension has converted knowledge into structural guidance workers followed without independent re-investigation.

## Step 4: Write Journal Entry

**This step is mandatory.** Call `lore journal write` with:

```bash
lore journal write \
  --observation "Delivery: X/5 | Quality: X/5 | Gaps: X/5 | Alignment: X/5 | Spec Utility: X/5. Key finding: <one sentence summary of most important insight>. Most actionable gap: <specific gap that should be addressed>." \
  --context "retro: <slug>" \
  --work-item "<slug>" \
  --role "retro" \
  --scores '{"d1_delivery": X, "d2_quality": X, "d3_gaps": X, "d4_alignment": X, "d5_spec_utility": X}'
```

## Step 5: Log Evolution Suggestions

**This step is mandatory.** At least one concrete suggestion per retro. Log suggestions to the journal — do **not** edit `skills/retro/SKILL.md` or `skills/retro/failure-modes.md` directly. The `/evolve` skill applies batched journal suggestions on demand.

### Meta-patterns to watch for

1. **Ceiling dimensions:** Any dimension at 5/5 for 2+ consecutive retros on different work items — raise the bar or replace with a dimension that produces more signal.
2. **New failure modes:** If this retro revealed a failure not in `failure-modes.md`, suggest adding it.
3. **Dead dimensions:** Dimensions that consistently score 3/5 regardless of performance — restructure scoring criteria or replace.
4. **Evidence quality:** If a score was hard to justify because evidence didn't exist in artifacts, note what's needed and whether it's worth adding to worker/spec reporting.

### Specific failure mode reference

Consult `skills/retro/failure-modes.md` when scoring reveals anomalies. It catalogs five groups:
- **A. Backlink resolution failures** — stale, phantom, pipeline, partial, compound (affects Dim 1, 3)
- **B. Lead bypass** — full, pointer, justified, with evidence availability notes (affects Dim 1, 5)
- **C. Cold-start and prefetch failures** — domain gaps, silent tool failures, spec-cycle tracking (affects Dim 1, 3)
- **C2. Spec investigation factual errors** — lifecycle misclassification, duplication overestimates, caller count errors (affects Dim 3, 4)
- **D. Spec Utility modifiers** — prototype-cascade, knowledge saturation, meta-work, plumbing-vs-value gap, prescriptive micro-scope ceiling (affects Dim 5)

### Logging suggestions

For each protocol improvement identified, write a journal entry:

```bash
lore journal write \
  --observation "Target: <file> | Change type: <ceiling/new-failure-mode/dead-dimension/evidence-gap> | Section: <section> | Suggestion: <specific change> | Evidence: <retro finding that surfaced this>" \
  --context "retro-evolution: <slug>" \
  --work-item "<slug>" \
  --role "retro-evolution"
```

**One entry per suggestion.** If multiple improvements are identified, write multiple journal entries. The observation should be 2-4 sentences: the suggested change, the target (SKILL.md section or failure-modes.md group), the rationale, and which meta-pattern triggered it.

**Minimum bar:** At least one suggestion per retro. If scoring went smoothly and no improvements are obvious, log why each dimension is still producing useful signal — the justification is the deliverable.

Record all suggestions in the Step 6 report.

## Step 6: Report

```
[retro] <slug>
  Delivery: X/5 | Quality: X/5 | Gaps: X/5 | Alignment: X/5 | Spec Utility: X/5
  Key finding: <one sentence>
  Evolution suggestions logged: N (run /evolve retro to apply)
```
