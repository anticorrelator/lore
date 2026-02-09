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

Check for `tasks.json` in the work item directory. If it exists, read task descriptions from the `phases[].tasks[]` arrays and extract all `**Observations:**` sections. If `tasks.json` does not exist, check `notes.md` for session entries from `/implement` runs that reference worker findings. For review-only cycles, note "no workers" and instead look for subagent launches (background analysis agents in `/pr-self-review`, `/pr-review`) and whether they received knowledge preambles.

### 2b: Knowledge context blocks

Read `plan.md` and extract every `**Knowledge context:**` block per phase. These record what knowledge was supposed to be delivered to workers/researchers. For review-only cycles, also check for inline `[knowledge: ...]` citations in plan.md tasks — these indicate knowledge was consulted during plan authoring even without formal context blocks.

### 2c: Session entries

Read `notes.md` and extract all `## YYYY-MM-DD` session entries. These record what actually happened: progress, findings, blockers, remaining work. If `notes.md` is empty or missing session entries, note this as degraded evidence — scoring will rely on plan.md, thread entries, and retrieval logs instead.

### 2d: Retrieval log

Determine the work period from `notes.md` timestamps (first session entry to last). Read `$KNOWLEDGE_DIR/_meta/retrieval-log.jsonl` and filter entries within that timestamp range. Summarize: total retrievals, average budget usage, branches active.

### 2e: Friction log

Read `$KNOWLEDGE_DIR/_meta/friction-log.jsonl` and filter entries within the same timestamp range. Summarize: total friction events, outcomes breakdown (found / found_but_unhelpful / not_found).

Report:
```
[retro] Evidence gathered:
  Worker observations: N tasks with observations
  Knowledge context blocks: N phases with context
  Session entries: N entries spanning <date range>
  Retrieval events: N in period
  Friction events: N in period
```

## Step 3: Evaluate Dimensions

Score each dimension 1-5 with concrete evidence from Step 2. Do not self-assess hypothetically — cite specific artifacts.

### Dimension 1 — Knowledge Delivery

Was knowledge context prefetched and delivered to workers/researchers? For each phase, compare `**Knowledge context:**` in plan.md against what workers actually referenced in their `**Observations:**`.

**For review-only cycles:** Score based on whether background analysis agents received knowledge preambles and whether the reviewer's session-start retrieval provided useful orientation context.

**Scoring:**
- 5: Every phase had knowledge context, and workers referenced or built on it
- 4: Most phases had context delivered; workers used it with minor gaps
- 3: Context was delivered but workers didn't reference it (decorative)
- 2: Some phases lacked context; workers searched manually. For reviews: knowledge was consulted during authoring but not delivered to subagents
- 1: No knowledge context delivered; workers started from scratch

### Dimension 2 — Retrieval Quality

Of the knowledge entries that were delivered, were they relevant to the actual work? Check for: entries about the right subsystem, entries at the right abstraction level, entries that were current (not stale).

Evidence comes from worker Observations and any friction-log entries during the period.

**Scoring:**
- 5: All delivered entries were directly relevant and current
- 4: Most entries relevant; one minor mismatch or slightly stale entry
- 3: Mixed — some relevant, some off-target or stale
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

Would this work cycle have gone meaningfully differently without the memory system? Be honest. Consider: would workers have been slower? Would they have made mistakes the knowledge prevented? Or would they have read the same source files and produced the same output regardless?

**Scoring:**
- 5: Memory system was essential — work would have been significantly slower or wrong without it
- 4: Clear speedup or prevented at least one mistake
- 3: Modest help — saved some exploration time but workers would have figured it out
- 2: Marginal — system was consulted but didn't change outcomes
- 1: No measurable impact — work would have been identical without it

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

Record all changes in the journal entry and the report.

## Step 6: Report

```
[retro] <slug>
  Delivery: X/5 | Quality: X/5 | Gaps: X/5 | Alignment: X/5 | Delta: X/5
  Key finding: <one sentence>
  Protocol changes: <what evolved>
```
