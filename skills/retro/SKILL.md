---
name: retro
description: "Evaluate knowledge system effectiveness after a work cycle — scores 5 dimensions, writes journal entry, suggests protocol evolution"
user_invocable: true
argument_description: "[work item name or slug]"
---

# /retro Skill

Evaluate how the memory system performed during a specific work cycle. Core question: did the knowledge system make this work meaningfully better?

Self-evolving protocol — every invocation produces at least one evolution suggestion (applied via `/evolve`).

## Step 1: Resolve Work Item

```bash
lore resolve
```

Set `KNOWLEDGE_DIR` to result, `WORK_DIR` to `$KNOWLEDGE_DIR/_work`.

1. Parse argument as work item slug (exact → substring title → substring slug → branch → recency → archive fallback)
2. Load `plan.md`, `notes.md`, `_meta.json` from `$WORK_DIR/<slug>/` (or `_archive/<slug>/` if archived)
3. No argument → infer from current git branch
4. No match → ask user

Report: `[retro] Evaluating: <title> (<slug>) [archived]`

## Step 2: Gather Evidence

Read existing artifacts only. No new exploration needed.

**Work cycle type:** Detect implementation (has `tasks.json`/`/implement` entries), review/research (no workers), or spec-short (`/spec short` — single-agent, no workers). Affects D1 and D4 scoring — spec-short scores D1 as "setup quality" for future workers.

### 2a: Worker observations

Primary source: **`execution-log.md`** if it exists — per-task entries with Changes, Observations, and test results. Secondary: worker SendMessage reports in conversation context. Cross-session fallback: `notes.md` session entries. Review-only: check subagent launches and knowledge preambles.

When both exist: execution-log for task-level decisions; notes.md for session-level context (blockers, cross-task synthesis).

### 2b: Knowledge delivery audit

1. Read `plan.md`, extract `**Knowledge context:**` blocks per phase
2. Check delivery mode per phase (`**Knowledge delivery:** full` vs annotation-only default)
3. **Zero-context-block check:** If 0/N phases have context blocks, check via `lore search` whether relevant entries existed. See `failure-modes.md` "Plan-level context block omission"
4. **Delivery mode mismatch:** For `full` phases, verify tasks.json matches. Plan says full but tasks.json has annotation-only = pipeline failure, D1 ≤ 3
5. **Backlink resolution rate:** Count resolved vs unresolved in `## Prior Knowledge`. >30% unresolved caps D1 at 2
6. **Annotation completeness:** For annotation-only phases, count entries with vs without annotation text. >40% empty caps D1 at 3. Subtract `## Related`-sourced bare entries and `_work/` paths from denominator (see `failure-modes.md` for details)
7. **Prefetch hit rate (spec-only):** Useful vs empty results. <40% → disambiguate coverage gap vs query recall failure

### 2c–2e: Logs

- **Session entries:** Read `notes.md` `## YYYY-MM-DD` entries. Empty = degraded evidence.
- **Retrieval log:** `$KNOWLEDGE_DIR/_meta/retrieval-log.jsonl` filtered to work period.
- **Friction log:** `$KNOWLEDGE_DIR/_meta/friction-log.jsonl` filtered to work period.

### 2f: Token efficiency

Annotation-only: wrong-path explorations prevented, first-attempt accuracy gains. Full-resolution: file reads replaced (~500-3000 tokens/file).

Report:
```
[retro] Evidence gathered:
  Worker observations: N tasks | Context blocks: N phases (M/K resolved)
  Sessions: N entries | Retrieval: N events | Friction: N events
  Token savings: ~Nk estimate
```

## Step 2.5: Low-Diagnostic Check

Before scoring, detect whether this retro will produce meaningful signal.

**Trigger** (ANY of):
- ≤5 tasks, all deletion/simple edits, 0 escalations, 0 captures
- All tasks are prescriptive prose edits (SKILL.md, protocol files, convention files)
- &gt;80% of task subjects contain verbatim edit instructions (exact text to add/remove)

When triggered, produce a **compressed assessment**:

```
[retro] <slug> — LOW-DIAGNOSTIC
  Scope: <N tasks, prescriptive/trivial/prose>
  Delivery worked: yes/no (brief note)
  Notable: <anything surprising, or "none — scope too narrow for signal">
```

Log scores with `"low_diagnostic": true` in journal entry. D1-D4 scored honestly but flagged for trend weighting. Focus narrative on D5 only. Skip to Step 4.

**Why:** Prescriptive/trivial retros consistently produce all-ceiling D1-D4 that inflate averages. Knowledge value concentrates at spec time; implementation-time scoring is low-signal. Full ceremony wastes evaluation effort.

## Step 3: Evaluate Dimensions

Score each 1-5 with concrete evidence. Cite specific artifacts. Consult `failure-modes.md` when anomalies appear.

### Dimension 1 — Knowledge Delivery

Was knowledge delivered to workers? Compare `**Knowledge context:**` in plan against worker behavior.

**Evidence by cycle type:**
- **Implementation:** Explicit citations in Observations OR correct approach choices in output. Annotation-only: workers internalize framing, not cite by name — implementation output is the evidence.
- **Review:** Subagents received knowledge preambles.
- **Spec-only:** Ad-hoc subagents dispatched without knowledge context when available = delivery failure.
- **Prose/convention:** Output aligned with delivered principles = knowledge applied, even without citation.

Scoring: 5 = every phase delivered, high completeness | 4 = most phases, minor gaps | 3 = low annotation quality or spec-only without subagent delivery | 2 = phases missing, >30% unresolved, or pipeline silent drop | 1 = no delivery

### Dimension 2 — Retrieval Quality

Were delivered entries relevant, current, and at the right abstraction level?

Scoring: 5 = all relevant + current + right level | 4 = mostly, one minor mismatch | 3 = topically relevant but wrong abstraction level | 2 = mostly irrelevant/stale | 1 = actively misleading

Note: Abstraction mismatch on prescriptive tasks is structural, not retrieval failure. See low-diagnostic check.

### Dimension 3 — Gap Analysis

What did workers need that wasn't in the store? Use `execution-log.md` `source: remember` entries as confirmed gap list.

- Distinguish *coverage failures* (pattern existed elsewhere, wasn't captured) from *genuinely novel discoveries*. Coverage failures weigh heavier.
- ≤4 tasks, 1-2 files = "trivial scope — gap dimension low-signal"
- Stale corrections (0 new captures, N corrections) = positive maturity signal, not gaps

Scoring: 5 = no gaps | 4 = one minor or only novel discoveries | 3 = one significant coverage failure | 2 = multiple coverage failures | 1 = no knowledge system support

### Dimension 4 — Plan-Knowledge Alignment

Did plan design decisions reference entries that actually influenced implementation?

Review cycles: knowledge flow store→review (good) vs review→store (lower — store was consumer).

Scoring: 5 = decisions shaped implementation | 4 = most influenced, 1-2 decorative | 3 = existed but workers chose independently | 2 = cited but diverged | 1 = no alignment

### Dimension 5 — Spec Utility

Did the spec reduce workers' need for independent exploration?

Evidence: escalations, out-of-scope file reads, divergent choices, unexpected discoveries. See `failure-modes.md` Section D for modifiers.

- **Spec-only:** Score structural quality as `(predictive)`. N corrections caps at 4.
- **Intent tasks:** Out-of-scope reads for discovery are by-design, not gaps.

Scoring: 5 = spec-guided, 0 escalations | 4 = minor exploration, ≤1 escalation | 3 = several reads, 2-3 escalations | 2 = frequent exploration, multiple divergences | 1 = no meaningful guidance

## Step 4: Write Journal Entry

**Mandatory.**

```bash
lore journal write \
  --observation "Delivery: X/5 | Quality: X/5 | Gaps: X/5 | Alignment: X/5 | Spec Utility: X/5. Key finding: <one sentence>. Most actionable gap: <specific gap>." \
  --context "retro: <slug>" \
  --work-item "<slug>" \
  --role "retro" \
  --scores '{"d1_delivery": X, "d2_quality": X, "d3_gaps": X, "d4_alignment": X, "d5_spec_utility": X}'
```

## Step 5: Log Evolution Suggestions

**Mandatory.** At least one per retro. Log to journal — do NOT edit files directly. `/evolve` applies batched suggestions.

Watch for: ceiling dimensions (5/5 for 2+ retros), new failure modes, dead dimensions (stuck at 3), evidence quality gaps.

```bash
lore journal write \
  --observation "Target: <file> | Change type: <ceiling/new-failure-mode/dead-dimension/evidence-gap> | Section: <section> | Suggestion: <specific change> | Evidence: <retro finding>" \
  --context "retro-evolution: <slug>" \
  --work-item "<slug>" \
  --role "retro-evolution"
```

One entry per suggestion. 2-4 sentences each.

## Step 6: Report

```
[retro] <slug>
  Delivery: X/5 | Quality: X/5 | Gaps: X/5 | Alignment: X/5 | Spec Utility: X/5
  Key finding: <one sentence>
  Evolution suggestions logged: N (run /evolve to apply)
```
