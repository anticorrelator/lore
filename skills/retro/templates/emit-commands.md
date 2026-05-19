# Retro emit/journal-write command templates

Read this file when emitting a retro output line or invoking
`lore journal write` from one of Steps 2.7, 2.8, 2b.6, 4, 4a, or 5. Each
block below is a fill-in template — load condition is named at the SKILL.md
prose pointer for the corresponding step.

## Step 2.7 — Batch audit output

```
[retro] Batch audit: <K> eligible / <M> uncovered (post-exclusion)
  audited: <A> (rows written: <R>)
  deferred: <D> (queue backlog — see Step 3.8 audit-coverage)
  excluded: <E> (priority-routed consumption-contradictions)
  failed: <F> (see $KDIR/_meta/retro-audit-log.jsonl)
```

## Step 2.8c — Escalation telemetry output

Emit **only** when escalations fired. When zero escalations fired, emit no prose (consistent with the Step 3.8 silence invariant).

```
[retro] Escalation telemetry (diagnostic, not scored)
  total:       <N> escalations in cycle
  rate:        <N>/<T> tasks  (T = total worker tasks in cycle)
  disposition:
    merged:             <a>
    re-scoped:          <b>
    accepted-one-shot:  <c>
    unreviewed:         <d>
  per-task:
    - <task-id>: <disposition> — rationale: "<one-sentence reason from worker>"
    - ...
```

## Step 2.8d — Escalation journal write

```bash
lore journal write \
  --observation "Escalations: <N> (<a> merged, <b> re-scoped, <c> one-shot, <d> unreviewed) | rate: <N>/<T> | rationales: <brief joined list>" \
  --context "retro-escalations: <slug>" \
  --work-item "<slug>" \
  --role "retro-escalations"
```

## Step 2b.6 — Channel-contract flag emit (when a flag fires)

```bash
KDIR=$(lore resolve)
bash ~/.lore/scripts/retro-channel-flag-append.sh \
  --cycle-id "<slug>" \
  --role "<role>" \
  --slot "<slot>" \
  --signal-type "<under_routing|over_capture|evidence_only_durable>" \
  --rate "<observed rate as decimal>" \
  --window-cycles "<N cycles in window>" \
  --remedy-hint "<optional one-line remedy suggestion>"
```

## Step 4 — Retro dimension-score journal write

Two shapes depending on `window_state` from Step 3.8.

### When `window_state == "pipeline-degraded"`

```bash
lore journal write \
  --observation "pipeline-degraded | Tripped: <check-name-1>, <check-name-2>, ... | Key finding: <one sentence on which check(s) tripped and where to look>. Scorecard cells from this window are non-evidentiary for /evolve." \
  --context "retro: <slug>" \
  --work-item "<slug>" \
  --role "retro" \
  --scores '{"d1_delivery": X, "d2_quality": X, "d3_gaps": X, "d4_alignment": X, "d5_spec_utility": X, "window_state": "pipeline-degraded", "tripped_checks": ["<check-name-1>", "<check-name-2>"]}'
```

### When `window_state != "pipeline-degraded"` (normal window)

```bash
lore journal write \
  --observation "Delivery: X/5 | Quality: X/5 | Gaps: X/5 | Alignment: X/5 | Spec Utility: X/5. Key finding: <one sentence>. Most actionable gap: <specific gap>." \
  --context "retro: <slug>" \
  --work-item "<slug>" \
  --role "retro" \
  --scores '{"d1_delivery": X, "d2_quality": X, "d3_gaps": X, "d4_alignment": X, "d5_spec_utility": X, "scorecard_headline": {"<template_id>@<version>": "pass|weak|fail", ...}, "scorecard_deltas": {"template": {...}, "correction": {...}, "reusable": {...}, "task-evidence": {...}}}'
```

## Step 4a — Behavioral-health journal write

```bash
lore journal write \
  --observation "Checks: <C1,C4,C5,C7> | C1: <1–3 sentence answer> | C4: <answer> | C5: <answer> | C7: <answer>" \
  --context "retro-behavioral-health: <slug>" \
  --work-item "<slug>" \
  --role "retro-behavioral-health"
```

`Checks:` lists the 4 selected check numbers (3 random from 1–6 plus Check 7). One `C<n>: <answer>` segment per selected check, in numeric order. No score fields.

## Step 4 / 3.9 — scorecard_headline journal field

```json
{
  "scorecard_headline": {
    "<template_id>@<version>": "pass",
    "<template_id>@<version-2>": "fail"
  }
}
```

## Step 5 — Evolution-suggestion journal write

One entry per suggestion. 2–4 sentences each.

```bash
lore journal write \
  --observation "Target: <file> | Change type: <ceiling/new-failure-mode/dead-dimension/evidence-gap/template-regression> | Section: <section> | Suggestion: <specific change> | Evidence: <retro finding>" \
  --context "retro-evolution: <slug>" \
  --work-item "<slug>" \
  --role "retro-evolution"
```
