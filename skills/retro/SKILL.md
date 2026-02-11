---
name: retro
description: "Evaluate knowledge system effectiveness after a work cycle — scores 5 dimensions, writes journal entry, evolves the protocol"
user_invocable: true
argument_description: "[work item name or slug]"
---

# /retro Skill

Evaluate how the memory system performed during a specific work cycle. The core question: did the knowledge system make this work meaningfully better, or would you have done the same thing without it?

This is a self-evolving protocol. Like `/self-test`, every invocation must produce at least one concrete protocol improvement.

## Step 1: Resolve Work Item

```bash
lore resolve
```

Set `KNOWLEDGE_DIR` to the result and `WORK_DIR` to `$KNOWLEDGE_DIR/_work`.

1. Parse the argument as a work item slug. Use the same fuzzy matching as `/work`:
   - Exact slug match -> substring match on title -> substring on slug -> branch match -> recency
2. Load `plan.md`, `notes.md`, `_meta.json` from `$WORK_DIR/<slug>/`.
3. If no argument provided, infer from the current git branch.
4. If no work item found, ask the user what work cycle to evaluate.

Report:
```
[retro] Evaluating: <work item title> (<slug>)
```

## Step 2: Gather Evidence

Read existing artifacts only. No new exploration or code reading needed.

**Work cycle type detection:** Determine if this was an implementation cycle (has `tasks.json` or `/implement` session entries) or a review/research cycle (no workers, findings came from interactive dialog). This affects how Dimensions 1 and 4 are scored — see scoring notes below.

### 2a: Worker observations

Worker observations come from the **implementation transcript** (worker SendMessage reports to the lead and TaskUpdate descriptions), NOT from `tasks.json` (which is pre-generated before workers run and contains task definitions, not results). For retros run in the same session as `/implement`, observations are available in the conversation context. For cross-session retros, check `notes.md` for session entries from `/implement` runs that reference worker findings (the `/implement` lead records key findings in its session entry). For review-only cycles, note "no workers" and instead look for subagent launches (background analysis agents in `/pr-self-review`, `/pr-review`) and whether they received knowledge preambles.

### 2b: Knowledge context blocks and backlink resolution

Read `plan.md` and extract every `**Knowledge context:**` block per phase. These record what knowledge was supposed to be delivered to workers/researchers. For review-only cycles, also check for inline `[knowledge: ...]` citations in plan.md tasks — these indicate knowledge was consulted during plan authoring even without formal context blocks.

**Backlink resolution audit:** If `tasks.json` exists, check the `## Prior Knowledge` sections in task descriptions for `[unresolved — Target not found]` markers. Count resolved vs unresolved backlinks. A high unresolved rate (>30%) indicates knowledge store restructuring broke plan references — this is a delivery failure independent of content quality. Report the resolution rate in the evidence summary.

**Fallback path audit:** If `tasks.json` does not exist and `lore work tasks` was used (check notes.md for `/implement` session entries), compare the plan's `**Knowledge context:**` backlinks against what the generated task descriptions actually contain. If plan phases have backlinks but generated tasks show "No backlinks found" or lack `## Prior Knowledge` sections, this is a **pipeline delivery failure** — the task generation script dropped the plan's knowledge context. This is worse than an unresolved backlink (which at least signals something was attempted) because it's completely silent. Score Dimension 1 no higher than 2 when this occurs.

**Prefetch hit rate (spec-only cycles):** When the spec lead ran `lore prefetch` for each investigation topic, count how many returned useful content vs. empty results. A low hit rate (<40%) indicates a domain coverage gap — the spec investigated an area where little or no prior knowledge exists. This is the most direct measure of store coverage for the investigated domain. Report as: "Prefetch hit rate: N/M investigations received prior knowledge (X%)". Affects Dimension 1 (attempted delivery but nothing to deliver ≠ didn't attempt delivery) and Dimension 3 (systematic coverage gap). A low hit rate with high Dimension 2 (what existed was good) and low Dimension 3 (many gaps) signals a focused coverage gap worth proactive seeding — the store's quality is fine, its breadth is the problem.

### 2c: Session entries

Read `notes.md` and extract all `## YYYY-MM-DD` session entries. These record what actually happened: progress, findings, blockers, remaining work. If `notes.md` is empty or missing session entries, note this as degraded evidence — scoring will rely on plan.md, thread entries, and retrieval logs instead.

### 2d: Retrieval log

Determine the work period from `notes.md` timestamps (first session entry to last). Read `$KNOWLEDGE_DIR/_meta/retrieval-log.jsonl` and filter entries within that timestamp range. Summarize: total retrievals, average budget usage, branches active.

### 2e: Friction log

Read `$KNOWLEDGE_DIR/_meta/friction-log.jsonl` and filter entries within the same timestamp range. Summarize: total friction events, outcomes breakdown (found / found_but_unhelpful / not_found).

### 2f: Token efficiency estimate

For each knowledge context block delivered to workers, estimate how many file reads it replaced and the approximate token cost of those reads (~500-3000 tokens per file depending on size). This is a rough estimate, not an exact measurement. Count: files a worker would have needed to read to discover the same information, grep/search cycles that were avoided, and wrong-path explorations that were short-circuited by the knowledge context. Summarize as: total file reads prevented, estimated tokens saved.

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

**Scoring:**
- 5: Every phase had knowledge context, and workers referenced or built on it
- 4: Most phases had context delivered; workers used it with minor gaps
- 3: Context was delivered but workers didn't reference it (decorative). Also: spec-only cycles where the author consulted knowledge but ad-hoc subagents received none
- 2: Some phases lacked context; workers searched manually. Also: context blocks existed but >30% of backlinks were unresolved (ghost references from knowledge store restructuring). Also: plan had backlinks but task generation pipeline dropped them (fallback path failure). For reviews: knowledge was consulted during authoring but not delivered to subagents
- 1: No knowledge context delivered; workers started from scratch

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

**Scoring:**
- 5: No significant gaps — workers found everything they needed
- 4: One minor gap that didn't slow work
- 3: One significant gap or several minor ones
- 2: Multiple gaps; workers did significant manual exploration
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

### Dimension 5 — Overall Delta

Would this work cycle have gone meaningfully differently without the memory system? Be honest. Consider three value dimensions: (1) **mistake prevention** — design rationale that guided workers toward correct implementation choices on the first attempt, (2) **token efficiency** — eliminated unnecessary code reading, file exploration, or re-discovery, (3) **outcome quality** — better design from knowledge-informed decisions.

Workers who read code *with* design rationale ("we're resisting instruction fade via structural enforcement") make different implementation choices than workers who read the same code cold and infer intent. Even when workers must still read the actual files, the "why" context prevents wrong-path explorations and produces first-attempt accuracy. "Would have figured it out" understates the value — figuring out WHAT code does is different from understanding WHY a design choice was made.

**Scoring:**
- 5: Memory system was essential — prevented significant mistakes, produced first-attempt accuracy across workers, OR saved substantial exploration (estimate: >10 file reads prevented, ~20k+ tokens). Work would have been materially slower or wrong without it
- 4: Clear quality improvement — workers made consistently correct implementation choices guided by design rationale. Demonstrable token savings (estimate: 5-10 file reads prevented, ~10-20k tokens) OR prevented wrong-path explorations
- 3: Saved meaningful exploration time (estimate: 2-5 file reads prevented, ~5-10k tokens) — workers would have reached the same conclusion but spent more context window getting there. Design rationale provided but didn't measurably change worker choices
- 2: Marginal — system was consulted but savings were minimal (estimate: <2 file reads prevented, <5k tokens). Didn't change outcomes or significantly reduce exploration
- 1: No measurable impact — work would have been identical without it

**Interpretation note:** When Dimensions 1-4 are all 4-5 but Delta is 3 or below, this is a **plumbing-vs-value gap** — the delivery mechanics were sound but the knowledge didn't change outcomes. This is expected for small, well-patterned work items where existing code already demonstrates the pattern. The knowledge system's delta for such items is primarily at *spec time* (informing scope, design decisions, gap identification), not implementation time. Score Delta based on the full work cycle including spec, not just implementation.

**Token efficiency note:** A 150-token knowledge entry that eliminates 5000 tokens of code reading is a 33x efficiency gain. When estimating token savings, count: file reads prevented (each ~500-2000 tokens), grep/search cycles avoided, wrong-path explorations short-circuited. "Would have figured it out" is not neutral if figuring it out costs thousands of tokens of context window.

**Meta/self-referential work items:** When the implementation IS knowledge work (creating entries, editing knowledge conventions, enhancing the knowledge store itself), Delta will be inherently low (1-2) regardless of delivery quality. Workers are already knowledge-domain-native — they understand entry formats, capture criteria, and store conventions from their agent prompt and task descriptions. The knowledge system helps build itself, but the tasks don't need its guidance the way code-implementation tasks do. Score honestly but note the meta-work classification so it doesn't drag down trend analysis. These items are better evaluated on *outcome quality* (did the new entries/conventions actually improve subsequent work?) than on *implementation delta*.

## Step 4: Write Journal Entry

**This step is mandatory.** Call `lore journal write` with:

```bash
lore journal write \
  --observation "Delivery: X/5 | Quality: X/5 | Gaps: X/5 | Alignment: X/5 | Delta: X/5. Key finding: <one sentence summary of most important insight>. Most actionable gap: <specific gap that should be addressed>." \
  --context "retro: <slug>" \
  --work-item "<slug>" \
  --role "retro"
```

## Step 5: Evolve the Protocol

**This step is mandatory.** At least one concrete change per retro. Edit `skills/retro/SKILL.md` directly.

Patterns to watch for:

1. **Ceiling dimensions:** Any dimension at 5/5 for 2+ consecutive retros on different work items: raise the bar (add sub-criteria, require stronger evidence) or replace with a dimension that produces more signal.

2. **New failure modes:** If this retro revealed a knowledge system failure not covered by any existing dimension, add a sub-dimension or new dimension to catch it in future retros.

3. **Dead dimensions:** Dimensions that consistently produce no signal (always 3/5 regardless of actual performance): restructure the scoring criteria to discriminate better, or replace.

4. **Evidence quality:** If a dimension score was hard to justify because the right evidence didn't exist in the artifacts, note what evidence would be needed and whether it's worth adding to worker/spec reporting.

5. **Knowledge-as-consumer vs knowledge-as-contributor:** If a retro reveals the knowledge store was primarily *updated by* the work rather than *informing* the work, note this in Dimension 4. This is a signal the store is lagging behind active development and needs proactive updates before the next cycle.

6. **Plumbing-vs-value gap:** If Dimensions 1-4 are all 4-5/5 but Delta is ≤3/5, the knowledge system's delivery mechanics are working but its *value contribution* is low for this work item type. Before treating this as a problem, consider: (a) was the work item small/well-patterned enough that code alone was sufficient? (b) did the knowledge contribute at spec time rather than implementation time? If (a), this is an expected ceiling — the knowledge system adds more value to novel or cross-cutting work. If (b), consider whether the retro should expand its scope to include the spec phase, not just implementation.

7. **Backlink staleness:** If >30% of backlinks in tasks.json `## Prior Knowledge` sections are unresolved, knowledge store restructuring (e.g., `/renormalize`) broke plan references. This is a delivery infrastructure failure — entries exist but can't be found. Consider: (a) whether `/renormalize` should update backlinks in active work items, (b) whether `tasks.json` generation should warn on unresolved backlinks rather than silently including `[unresolved]` markers.

8. **Pipeline delivery failures:** If the plan has `**Knowledge context:**` backlinks but the task generation path (especially fallback `lore work tasks`) produces tasks without resolved knowledge, the entire knowledge delivery pipeline is broken for that implementation. This is a silent failure — the plan looks complete, the tasks look reasonable, but workers get zero knowledge context. Track whether this recurs across retros; if so, the fix is in `generate-tasks.py` backlink resolution, not in `/implement` or `/retro`.

9. **Lead-bypass of pre-resolved knowledge:** When tasks.json has `## Prior Knowledge` sections (backlinks resolved, content embedded) but the lead writes custom TaskCreate descriptions that omit or condense this content, workers receive degraded knowledge store context despite the pipeline succeeding. Two severity levels:

   **Full bypass** (Dimension 1 ≤ 2): Lead's TaskCreate descriptions completely omit `## Prior Knowledge` content. Workers start with zero knowledge context. This happens when the lead judges a concrete code reference (e.g., "read sibling-script.sh") as more actionable than abstracted knowledge entries. For pattern-following work items where a sibling file IS the reference, this may be justified — but it should be explicit, not silent.

   **Pointer bypass** (Dimension 1 ≤ 3): Lead's TaskCreate descriptions include a reference/pointer to pre-resolved knowledge (e.g., "Tasks contain pre-resolved knowledge — read the full task description for design rationale") but don't embed the actual content. Workers know knowledge exists but must search for it, converting push delivery into pull. Less severe than full bypass because awareness is maintained, but violates push-over-pull — the content was already resolved and available.

   Detection: compare tasks.json task descriptions against the actual TaskCreate descriptions used in the `/implement` session. Note whether the bypass was *justified* vs *accidental* (lead condensed descriptions for brevity without realizing the content loss).

10. **Cold-start research penalty:** When `/spec` investigates a domain with no existing knowledge entries, `lore prefetch` returns empty and the lead may skip embedding preambles entirely — researchers then do 100% manual exploration. This is a valid cold-start scenario (no knowledge exists yet), but the lead should still run prefetch and embed whatever is returned (even cross-domain entries can provide useful orientation). When prefetch returns truly nothing, the researcher prompt should explicitly note "No prior knowledge found for this domain — report any architectural patterns or conventions you discover for capture." This turns cold-start research into a knowledge-seeding opportunity rather than a silent gap. Track cold-start occurrences: if the same domain gets cold-start penalties across retros, the store has a coverage gap worth proactively filling.

11. **Prefetch pipeline silent failure:** When `lore prefetch` produces no output (exits 0 but returns empty), the lead may silently fall back to manually composing preambles from session-start context or skip knowledge injection entirely. This masks a tool failure — researchers get knowledge through a fragile manual path (or none at all) while the pipeline appears functional. Detection: check whether researcher prompts contain `## Prior Knowledge` blocks that came from prefetch output vs manually-composed content from session-start loaded entries. If the lead composed preambles manually while prefetch was available, this is a pipeline failure regardless of whether researchers got useful context. Scoring impact: Dimension 1 no higher than 3 (delivery succeeded manually but pipeline failed). Track whether prefetch failures correlate with specific query patterns or knowledge store sizes.

12. **Phantom backlinks vs stale backlinks:** Distinguish between two causes of unresolved backlinks in tasks.json:

   **Stale backlinks** (item 7): Entry existed once but was moved/renamed by `/renormalize` or manual restructuring. The slug was valid at plan-authoring time. Fix: update backlinks in active work items during renormalize.

   **Phantom backlinks**: Plan author cited entries that *never existed* — the slug describes a concept that should have an entry but doesn't. This signals a **knowledge coverage gap**, not an infrastructure failure. The plan author's intuition about what knowledge should exist is itself valuable signal.

   Detection: for each unresolved backlink, check whether any entry ever existed at that path (search by slug fragments across categories). If no match anywhere, it's phantom. If a similar entry exists under a different path/name, it's stale.

   Scoring impact: Phantom backlinks affect Dimension 3 (gaps) more than Dimension 1 (delivery) — the pipeline correctly reported "not found" because the knowledge genuinely doesn't exist. Stale backlinks affect Dimension 1 (delivery infrastructure failed). When both co-occur, score both dimensions accordingly.

   Action: Phantom backlink slugs from retros should be collected as proactive capture candidates. If the same domain produces phantoms across retros, create a work item for knowledge seeding in that area.

13. **Compound failure scoring:** When multiple failure modes co-occur (e.g., high unresolved rate + lead bypass + phantom backlinks), the lowest individual dimension cap applies. Do not average — compound failures are worse than their individual components because each layer that should compensate (tasks.json pre-resolution → lead prefetch → lead manual embedding) failed in sequence. When all three layers fail, Dimension 1 is 1-2 regardless of whether workers eventually found what they needed through manual exploration.

14. **Prototype-cascade effect on Delta scoring:** When a batch of similar tasks exists (e.g., 5 lens skills following the same skeleton), the knowledge system's value concentrates on the first task — the prototype. Once the prototype is created, subsequent workers reference it as the primary template rather than knowledge entries. This is correct behavior (concrete code > abstract conventions), but it means Delta for the batch overstates the knowledge system's per-task contribution. When scoring Delta for batched work, assess: (a) did knowledge entries shape the prototype's design? (b) would the prototype have been different without knowledge context? If yes to both, the knowledge system's contribution is real but indirect for tasks 2-N. Score Delta based on the full batch including the prototype, not averaged across tasks. Note when prototype-cascade occurred so trend analysis can distinguish "knowledge shaped the template" from "knowledge was irrelevant after task 1."

15. **Spec-cycle cold-start tracking:** When `/spec` runs prefetch for researcher prompts and gets empty results, this signals a knowledge coverage gap in that investigation domain. The lead should: (a) note which investigations had cold-start (empty prefetch) in the `/remember` step as knowledge-seeding targets, (b) after investigations complete, assess whether the findings would have been useful as pre-existing knowledge entries (most will be — that's what capture is for). Scoring impact on Dimension 1: cold-start for >50% of investigations caps Delivery at 3 — the pipeline worked but the store lacked coverage. Cold-start for >75% caps at 2. When the same investigation domains produce cold-starts across multiple specs (e.g., "agent communication patterns" is always empty), create a proactive knowledge-seeding work item rather than waiting for organic capture.

16. **Justified lead-bypass and the code-level-instructions pattern:** When the lead reads all target files before spawning workers (to verify plan feasibility or compose dependencies), the lead accumulates enough context to write code-level worker prompts (exact line numbers, code snippets, precise edit instructions). These prompts are strictly more actionable than abstract knowledge entries for simple, well-specified edits. The lead then rationally bypasses tasks.json knowledge content — not from ignorance but from having better information. Detection: lead's worker prompts contain code-level specifics (line numbers, function signatures, exact before/after) rather than referencing `## Prior Knowledge` sections. Scoring: Dimension 1 stays at 2 (workers still received zero knowledge context), but Delta should note that the bypass was rational — knowledge value was at spec time (plan authoring), not implementation time. The actionable takeaway is not "deliver knowledge to workers" but "the knowledge system's ROI for small/well-specified work items is in plan quality, not worker efficiency." When this pattern recurs, consider whether `/implement` should skip knowledge delivery for work items below a complexity threshold (e.g., ≤5 tasks, all single-file edits).

Record all changes in the journal entry and the report.

## Step 6: Report

```
[retro] <slug>
  Delivery: X/5 | Quality: X/5 | Gaps: X/5 | Alignment: X/5 | Delta: X/5
  Key finding: <one sentence>
  Protocol changes: <what evolved>
```
