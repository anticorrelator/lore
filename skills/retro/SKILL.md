---
name: retro
description: "Evaluate knowledge system effectiveness after a work cycle — scores 5 dimensions, writes journal entry, suggests protocol evolution"
user_invocable: true
argument_description: "[work item name or slug]"
---

# /retro Skill

Evaluate how the memory system performed during a specific work cycle. Core question: did the knowledge system make this work meaningfully better?

Self-evolving protocol — every invocation produces at least one evolution suggestion (applied via `/evolve`).

## Role-based section routing

`/retro` runs **identically for contributors and maintainers**. The Steps 1–6 pipeline is role-agnostic: both roles gather evidence, score dimensions, run health checks, write journal entries, and log evolution suggestions to the local journal. No sections in this skill are conditional on role.

The federation commands (`lore retro export --redact`, `lore retro import <file>`, `lore retro aggregate`) that *distribute* retro evidence across operators are CLI-level verbs, enforced by `cli/lore` dispatch via `require_maintainer` (see task-54). They are **not** part of this skill's workflow — a `/retro` invocation never produces an import/aggregate as a side effect, and a contributor running `/retro` does not need to read about federation to do their job.

If you are reading this skill and wondering whether you need to skip sections based on role: the answer is **no**. Run every step as written. Role-gating applies to `/evolve` (see `skills/evolve/SKILL.md`'s "Role-based section routing" preamble) and to CLI-level retro federation verbs, not to the retro ceremony itself.

## Step order (load-bearing)

The step numbering is not alphabetical padding — it encodes a dependency order that downstream `/evolve` and trend analysis rely on. Running steps out of order produces coherent-looking output whose headline misrepresents the window.

1. **Steps 1–2.7**: setup, evidence gathering, batch audit backfill. These run unconditionally. The backfill (Step 2.7) must complete before any scorecard read so Step 3.8's audit-coverage check sees a representative `rows.jsonl`.
2. **Step 2.8**: escalation telemetry. Non-scored, feeds retro prose only.
3. **Step 3.8** (Phase 7b — settlement pipeline health checks): **runs before** any scorecard-consumption step. Sets `window_state = "pipeline-degraded" | normal`. If degraded, Steps 3.0/3.9 skip.
4. **Step 3.0** (Phase 7 — scorecard delta surface, *primary*): runs only on normal windows. Skipped on `pipeline-degraded`.
5. **Step 3** (dimension scores): demoted to narrative coda. Always scored for longitudinal trend, never the headline.
6. **Step 3.6–3.7**: scorecard forward guidance + behavioral health — coda/diagnostic.
7. **Step 3.9** (Phase 7 — non-compensatory headline): runs only on normal windows. Skipped on `pipeline-degraded`.
8. **Steps 4–6**: journal persistence, evolution suggestions, operator-facing report. Branch on `window_state` so `pipeline-degraded` never surfaces a pass/weak/fail headline.

**Phase 7b (health checks at Step 3.8) ships alongside Phase 7 (scorecard consumption at 3.0/3.9)** — they share no schema but interlock: 3.8 gates the evidentiary status of the window; 3.0 and 3.9 refuse to read a degraded window. Editing either section must preserve the `pipeline-degraded` short-circuit in the three downstream consumers (Steps 3.0, 3.9, 4, 6).

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

## Step 2.7: Batch audit backfill

Probabilistic post-ceremony triggers (Phase 5, `lore audit` fired at `p ≈ 0.2-0.3` per ceremony) intentionally leave most artifacts unaudited in any given window. Retro-batch backfill closes the coverage gap before Step 3.8's health checks read `rows.jsonl` — without this backfill, Step 3.8 `Audit coverage` reliably trips `pipeline-degraded` even when the pipeline is healthy, because the probabilistic triggers alone never reach the 60% threshold.

This step is advisory for **observational windows** (review-only, spec-only, prose-only retros where no producer artifacts were emitted). Skip by reporting `[retro] No eligible artifacts for batch audit; skipping.`

**What to batch.** Any artifact in the retro window that is both:
1. **Eligible** — ceremony with non-zero configured `p` in `~/.lore/config/settlement-config.json` (implement, pr-self-review, pr-review, spec), AND
2. **Uncovered** — no existing row in `$KDIR/_scorecards/rows.jsonl` whose `source_artifact_ids` includes this artifact's ID and whose `window_start`/`window_end` overlap this retro window.

**Enumeration.** Walk `$KDIR/_work/<slug>/` for work items whose `_meta.json` `created_at` falls in the retro window. For each, scan `execution-log.md`, `plan.md` (spec-sourced assertions), and any `$KDIR/_followups/<slug>/lens-findings.json` tied to the work item. Candidate artifact IDs are work-item slugs and followup slugs.

**Dispatch.** For each uncovered artifact, invoke:

```bash
lore audit "<artifact-id>"
```

The `lore audit` dispatch (see `architecture/audit-pipeline/contract.md`) resolves the artifact, routes it through the three-judge pipeline, and appends verdict rows to `$KDIR/_scorecards/rows.jsonl` via `scorecard-append.sh`. No new retro-side persistence is required — Step 3.8 reads the same `rows.jsonl` and picks up backfilled rows automatically.

**Rate-limit and failure handling.**
- Do **not** batch more than 20 uncovered artifacts per retro invocation. If the uncovered set is larger, audit the 20 highest-priority (by `scripts/audit-sample.sh` risk weights, or by recency when the sampler is not yet wired) and report the remainder as a pending-backlog counter in the retro output. Rationale: a retro window with 50+ uncovered artifacts is itself a pipeline-health signal (Step 3.8 `Audit coverage` will catch it); batch-auditing all of them inline would make the retro step unbounded.
- Treat non-zero exit codes from `lore audit` as partial failures: log the artifact-id + exit code to `$KDIR/_meta/retro-audit-log.jsonl` and continue. A single audit crash must not block the retro; Step 3.8 will surface the resulting rows.jsonl gap naturally.
- The stub phase of `lore audit` (pre tasks #12/#17/#22) exits 0 without writing rows. That is expected; Step 3.8 will see the coverage shortfall and emit `pipeline-degraded` once the configured `p` ceremonies have produced ≥10 eligible artifacts without verdict rows — the canonical signal that the pipeline stub is still in place.

**Output:**
```
[retro] Batch audit: <K> eligible / <M> uncovered
  audited: <A> (rows written: <R>)
  deferred: <D> (queue backlog — see /retro Step 3.8 audit-coverage)
  failed: <F> (see $KDIR/_meta/retro-audit-log.jsonl)
```

**Why:** Phase 5 probabilistic triggers alone underfill the scorecard. Without retro backfill, Step 3.8 `Audit coverage` trips every window and `/evolve` sees every window as `pipeline-degraded` — the degraded-state signal loses meaning. Retro batch is the compromise between strict always-audit (violates out-of-band by making every ceremony's downstream latency audit-dependent) and purely probabilistic (too sparse for statistical power).

## Step 2.8: Escalation verdict surface (work-item telemetry, not scored)

**Diagnostic, not scored.** When a worker returns a structured escalation
verdict of the shape `{escalation: "task-too-trivial-for-solo-decomposition",
rationale: "<one-sentence reason>"}` (validated at
`scripts/validate-structured-report.py`), /retro surfaces it here as
**work-item telemetry**. This surface is intentionally off-band from
the dimension scores in Step 3 and off-band from the scorecard substrate:

- **Not wired to `/evolve`.** Escalation rate must never drive template
  mutation. Scoring producers on how often they escalate creates perverse
  incentives — either workers suppress legitimate escalations to keep
  their "rate" down, or they escalate trivially to game the signal.
  Either collapse destroys the diagnostic utility this surface exists
  for.
- **Not rolled into any producer template scorecard.** No `kind ==
  "scored"` row is written for an escalation. This is the **canonical
  precedent for the `kind` discriminator rule**: any observation type
  that must not drive template mutation stays off `kind == "scored"`.
  Future row types that face the same incentive hazard (e.g., advisor
  consultation counts, trigger-realization rates) should cite this
  precedent in their design docs.
- **Work-item scope, not portfolio scope.** Counts and rates are
  attributed per work item, not aggregated across templates, because the
  relevant remediation (re-scope the plan, merge the sub-task, accept
  one-shot) happens at the plan level, not the template level.

### 2.8a: Inputs

Read escalation verdicts from the cycle's worker reports:

- **Primary:** `execution-log.md` entries in `$WORK_DIR/<slug>/` —
  each completed task's worker report is persisted there; the report
  text contains the escalation stanza when one was emitted.
- **Secondary:** cross-session worker SendMessage reports surfaced in
  `notes.md` session entries, when `execution-log.md` is absent
  (review-only cycles) but a worker still returned an escalation.

Parse each report with the same regex pattern used by
`validate-structured-report.py:find_escalation()` so this surface counts
exactly what the gate counts — `VALID_ESCALATION =
"task-too-trivial-for-solo-decomposition"` with a non-empty
`rationale`. Malformed escalations are explicitly excluded; they
surface in the hook's own error stream, not here.

### 2.8b: Lead disposition

For each escalation verdict, the retro surface records a **lead
disposition** — what the lead agent (team-lead or /implement
orchestrator) did with the escalation. The disposition is a closed
enum:

- `merged` — lead merged the sub-task into a larger peer task
  rather than decomposing further.
- `re-scoped` — lead edited the plan to replace the escalated task
  with a wider-scope alternative, then discarded the original.
- `accepted-one-shot` — lead accepted the escalation but proceeded
  with the original trivial task as-is (no plan change). The
  escalation was acknowledged but not acted on.
- `unreviewed` — no visible lead response before the retro fires.
  Either the work is still in-flight or the lead missed the
  escalation. Distinct from `accepted-one-shot` because the intent
  signal is missing.

Infer disposition from the `tasks.json` and `plan.md` state at retro
time:
- If the escalated task's subject was rewritten and a sibling task
  absorbed it → `merged`.
- If the plan's phase containing the task was edited after the
  escalation timestamp AND the task set changed → `re-scoped`.
- If the task completed with `status: completed` and no plan/tasks
  edit followed the escalation → `accepted-one-shot`.
- If the task is still `in_progress` or `pending` at retro time →
  `unreviewed`.

### 2.8c: Report shape

Render the surface as a compact work-item telemetry block, **separate
from dimension scores in Step 3 and separate from the Step 3.8
pipeline-degraded block**. Empty when zero escalations fired in the
cycle.

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

When zero escalations fired, emit **no prose** — consistent with the
Step 3.8 silence invariant and for the same reason (escalations are
already noteworthy when they happen; routine absence is not).

### 2.8d: Journal persistence

Write a separate journal entry for this surface so longitudinal
queries can filter cleanly:

```bash
lore journal write \
  --observation "Escalations: <N> (<a> merged, <b> re-scoped, <c> one-shot, <d> unreviewed) | rate: <N>/<T> | rationales: <brief joined list>" \
  --context "retro-escalations: <slug>" \
  --work-item "<slug>" \
  --role "retro-escalations"
```

`--role "retro-escalations"` is distinct from `retro` (dimension
scores), `retro-behavioral-health` (qualitative), and
`retro-evolution` (suggestions). Four separate roles by design, for
the same reason the dimensions split: collapsing them would require
consumers to demux by observation prose, which is fragile.

**Invariant.** This step never calls `scorecard-append`. There is no
scorecard row written for an escalation — not `kind="scored"`, not
`kind="telemetry"`. The settlement substrate is not the right
persistence layer for this signal; the journal is. Mixing the two
opens a back-door through which /evolve could eventually start
consuming escalation data even though this step explicitly declares
it off-limits. Journal-only storage structurally rules that out.

## Step 3.0: Scorecard delta surface (primary)

**This step is primary.** The scorecard delta surface leads the /retro
output (Step 6 report). Dimension scoring (Step 3) becomes the
qualitative coda — useful for describing knowledge-system behavior in
prose, but **not** the operator-facing headline. Step 3.9's
non-compensatory `pass|weak|fail` per template-version is the primary
headline; Step 3.0 shows what *changed* since the last window to explain
why the headline moved (or didn't).

**Why delta-first.** A single-window scorecard cell tells you where a
template stands; a delta tells you which direction it's moving. A
template at `factual_precision=0.72` might be `weak` in absolute terms
but trending sharply upward (last window: 0.58) — the delta is the
actionable signal, not the absolute value. Dimension scores (Step 3)
correlate with knowledge-delivery quality but they don't answer "is
the settlement pipeline learning?", which is the question Step 3.0
addresses.

**Relationship to other steps.**
- Step 3.8 (health checks) runs first; if `pipeline-degraded`, Step
  3.0's deltas are non-evidentiary and the surface reads "not
  computed — window is pipeline-degraded, see Step 3.8".
- Step 3.9 (headline) supplies the current-window values; Step 3.0
  supplies the deltas *against* the previous eligible window.
- Step 3 (dimensions) runs after Step 3.0 and is demoted to
  **narrative coda**. Its purpose shifts from "primary scoring" to
  "qualitative complement that explains *why* scorecard cells moved
  when the delta surface calls for an explanation". Dimension scores
  are still persisted to the journal (Step 4); they're still useful
  longitudinal signal; they are no longer the headline.

### 3.0a: Inputs

- `$KDIR/_scorecards/_current.json` — the rollup produced by
  `scorecard-rollup.sh` for the current retro window.
- Previous window's rollup — the rollup snapshot whose
  `window_end` is the most recent value **strictly earlier than** the
  current retro window's start. If no prior eligible window exists
  (fresh install, first retro after a long hiatus, etc.), report
  "first eligible window — no delta baseline" and emit no delta rows;
  downstream readers treat this as informational, not a degradation
  signal.
- `$KDIR/_scorecards/template-registry.json` — unregistered rows
  render as `unregistered:<hash>` and are excluded from the delta
  surface (same rule as Step 3.9).
- The set of `pipeline-degraded` windows (from Step 4's journal) — if
  either the current or previous window is degraded, the delta for
  that template-version is **skipped**, not zeroed. Zeroing would
  Goodhart to "no change" on a broken pipeline.

### 3.0b: Delta computation

For each registered `(template_id, template_version)` that has
kind==scored, calibrated rows in both the current and previous windows:

```
delta_{metric} = current_{metric} - previous_{metric}
```

Compute a delta per metric in the six-MVP-metric vector from Step 3.9.
Two of the six are inverted (`triviality_rate`, `omission_rate`) —
*improvement* means the delta is **negative**. The surface notation
uses an explicit direction indicator (↑ improving, ↓ regressing) so
the reader doesn't have to track direction per metric.

### 3.0c: Surface filters

The delta surface is **not** a per-cell dump. It surfaces only deltas
that carry actionable signal. A delta is surfaced when **all three**
hold:

1. **Large change.** `|delta|` exceeds the per-metric magnitude
   threshold. MVP thresholds (tunable after data):
   - `factual_precision`: |delta| ≥ 0.05
   - `curated_rate`: |delta| ≥ 0.05
   - `triviality_rate`: |delta| ≥ 0.05
   - `omission_rate`: |delta| ≥ 0.03 (more sensitive; small changes
     in portfolio-level miss rate are load-bearing)
   - `external_confirm_rate`: |delta| ≥ 0.05
   - `observation_promotion_rate`: |delta| ≥ 0.03
2. **Sufficient sample size.** Both windows must have n ≥ 10 rows
   for that metric. Below-sample deltas are noise; a metric that
   went from 0.2 (n=3) to 0.8 (n=2) is not a signal.
3. **Registered template_version in both windows.** If the current
   or previous `template_version` is unregistered, skip — we can't
   attribute the delta to a known template lineage. (Unregistered
   rows land in the evidence block below for transparency but do not
   drive surfaced deltas.)

Deltas that pass the filter are **surfaced**; deltas that fail it are
**suppressed** but counted (one line at the end: "<N> small / below-
sample / unregistered deltas suppressed"). This preserves the "did
something change?" signal without drowning the surface in noise.

### 3.0d: Report shape

The delta surface is the first block of the Step 6 report output, above
all other sections. Structure:

```
[retro] Scorecard deltas — primary surface

  Window: <current-window-id>  vs  <previous-window-id>
  Eligible templates with deltas: <N> surfaced, <M> suppressed

  <template_id>@<version-prefix-12>:
    factual_precision:          0.72 → 0.81  (↑ +0.09, n=24)     [delta-pass → regressing]
    curated_rate:               0.48 → 0.41  (↓ -0.07, n=18)     [delta-pass → improving]
    omission_rate:              0.22 → 0.14  (↓ -0.08, n=32)     [inverted: ↓ is improving]
    (other metrics: unchanged or below threshold)

  <template_id-2>@<version-prefix-12>:
    observation_promotion_rate: 0.31 → 0.22  (↓ -0.09, n=15)     [regressing]
    (other metrics: unchanged or below threshold)

  Suppressed: 12 (7 below-sample, 3 unregistered, 2 below-magnitude)
```

Each surfaced delta line reads left-to-right:
  `<metric>: <previous> → <current>  (<direction symbol> <signed delta>, n=<current sample>)  [<classification change if any>]`

Where "classification change" is derived from Step 3.9's headline
thresholds: a delta that moved the metric from `weak` to `pass`, or
from `pass` to `fail`, is flagged. Deltas within a classification
band (e.g., 0.72 → 0.81 both-pass) show direction without
classification annotation.

**Pipeline-degraded windows.** If either window was
`pipeline-degraded`, emit a single line:
```
  Deltas for <template_id>@<version>: skipped (degraded window — see Step 3.8)
```
per affected template-version, rather than a full delta block. The
report then continues to the next template.

**First-window case.** If no prior eligible window exists, emit:
```
  First eligible window — no delta baseline. Full current-window values
  appear in Step 3.9's headline block below.
```

### 3.0e: Journal persistence

Deltas are derived signal, not source data. They are NOT written to
`rows.jsonl` — the scorecard substrate remains append-only with
first-derivative storage only. The delta surface IS persisted to the
retro journal entry (Step 4) under a `scorecard_deltas` field:

```json
{
  "scorecard_deltas": {
    "<template_id>@<version>": {
      "factual_precision": {"prev": 0.72, "curr": 0.81, "delta": 0.09, "n_curr": 24, "surfaced": true},
      ...
    },
    ...
  }
}
```

`surfaced: true` iff the delta passed all three filters above. This
lets downstream readers (dashboards, `/evolve` ranking) access both
the full delta map and the filtered view without re-computing.

**Invariant — no compensation.** A large improvement on one metric
does NOT suppress a surfaced regression on another metric for the
same template. The surface shows all surfaced deltas; the reader
(human or `/evolve`) composes them. This mirrors the Step 3.9
non-compensatory rule; the delta surface inherits the invariant
rather than restating it.

## Step 3: Evaluate Dimensions (narrative coda)

*As of the Step 3.0 primary-surface refactor, dimension scoring is the
narrative coda — not the headline.* The operator-facing headline is
Step 3.9's `pass|weak|fail` per template-version; the actionable signal
is Step 3.0's scorecard delta surface. Dimension scores persist for
longitudinal trend tracking and for cases where settlement data is
sparse (new repos, first few retros), but they no longer lead the
report.

Keep scoring honest: the scores are still 1-5 and still cite concrete
evidence. Do not inflate or deflate them to match the scorecard
headline — if the dimension score disagrees with the headline, that
disagreement is itself diagnostic. The Step 6 report frames dimensions
under "Narrative coda" and places them below the scorecard delta block
and the headline block.

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

## Step 3.6: Scorecard data (forward guidance)

`/retro` is a primary reader of `$KDIR/_scorecards/_current.json` when scorecard
data becomes a downstream input (F1 settlement pipeline and onward). This step
captures the load-bearing invariants ahead of that integration so future edits
don't drift.

**Sole-writer invariant.** `scripts/scorecard-append.sh` (surfaced as
`lore scorecard append`) is the only sanctioned writer of `rows.jsonl`. Never
append to that file directly from this skill, from agents it spawns, or from
edits it proposes.

**Corrupt-row handling.** Any row failing schema validation
(`schema_version` absent, `kind ∉ {scored, telemetry}`, or
`calibration_state ∉ {calibrated, pre-calibration, unknown}`) is treated as
corrupt. The rollup emits a `[scorecard] warning: rows.jsonl:<N> corrupt —
<reason>` stderr line and EXCLUDES the row from aggregation. Do not manually
count corrupt rows into any dimension score.

**Unregistered-hash rendering.** When `_current.json` references a
`template_version` hash that is not present in
`$KDIR/_scorecards/template-registry.json`, render the hash as
`unregistered:<hash>` in any summary shown to the user and **assign it no
scorecard weight** (exclude from D1–D5 evidence and from any trend
comparison). This isolates the registry-write path from the scorecard-write
path: rows can be accepted even when the corresponding template was
mid-edited or never registered, but those rows do not contribute to
settlement signal until the template is registered with a non-null
description.

**Prompt-context invariant.** Scorecard rows are never loaded into an agent
prompt. `/retro` consumes `_current.json` in this skill's own runtime; it
does not inject raw rows into spawned subagents or into the journal entry.
Summaries into aggregate statistics are fine; raw row content is not.

## Step 3.7: Behavioral Health

Qualitative counter-loop to scorecard Goodhart. Tests for the *kind of work*
the agents are doing, not the conformance of the artifact. Answerable from
existing cycle artifacts — no new schema, no new instrumentation. Each check
produces a sentence or two of observation, not a number. The value is
longitudinal: patterns emerge across retros.

Baselining and tuning of the question set are tracked separately (see
[[work:03-settlement-architecture-lore-agent-flows]] Phase 0 / tasks 3–4).

### Rotation policy

Don't run all 7 checks every retro — rotation prevents ritualization and
stops agents from shaping artifacts to the check.

**Default rotation:** on each `/retro` invocation, select **3 checks
uniformly at random from Checks 1–6, plus Check 7 always** — yielding 4
checks total. Check 7 (qualitative ground-truth) is never rotated out; it
is the irreducible human-reads-the-work floor.

**Selection timing invariant:** checks are selected **at invocation time**
(when `/retro` begins executing Step 3.7), not at the start of the work
cycle. If agents know in advance which checks will run, they can shape
their artifacts to the check and the observational value collapses. Late
binding is load-bearing, not cosmetic.

**Implementation sketch:** in Step 3.7, draw 3 integers from `{1,2,3,4,5,6}`
without replacement (any source of entropy is fine — system randomness,
hash of current timestamp, etc.), union with `{7}`, run those checks, and
record which four were selected in the journal entry so longitudinal
analysis can track each check's rotation frequency.

**Do not** pre-compute the rotation at cycle start, persist the selection
in `plan.md`, or otherwise make the check set visible to producers before
they finish their work.

### Drift modes being watched

1. **Ritualization** — outputs technically conformant but generic.
2. **Confirmation bias** — agents under-produce findings that contradict
   prior knowledge; the store calcifies.
3. **Form-filling vs. substance** — required fields get content, optional
   fields go empty. Schema crowds out craft.
4. **Goodhart drift** — behavior bends toward any added metric and away
   from the underlying goal.
5. **Judgment atrophy** — agents stop making non-obvious calls because the
   protocol doesn't reward them.
6. **Calibration drift** — auto-disposition, routing, or scoring
   thresholds fall out of alignment with human override patterns.
7. **Compliance theater** — multi-step skills where every step "succeeds"
   but the substance was thin.

### Candidate checks

Each is a question answerable from artifacts in the cycle just completed.
Record a 1–3 sentence qualitative answer. Do not score.

**Check 1 — Observation substance (ritualization probe).** Pick 2–3 worker
Observations from `execution-log.md` at random. For each: could a different
worker on a different task have written the same sentence? If yes, the
observation was ritual. Note the pattern.

**Check 2 — Knowledge promotion rate (substance probe).** Of the worker
Observations from this cycle, how many were promoted into knowledge
captures? Compare against recent retros. A falling rate suggests
Observations converging on cheap talk.

**Check 3 — Surprise rate (confirmation-bias probe).** Across investigation
findings in the window (`/spec`, `/pr-review`, `/pr-self-review`), what
fraction were genuinely surprising — extended or contradicted prior
knowledge — vs. confirmed what was already documented? Heavy confirmation
skew suggests prior-knowledge injection is anchoring rather than orienting.

**Check 4 — Narrative slot health (form-filling / judgment-atrophy probe).**
For skills with optional freeform fields (worker **Investigation** field,
finding narrative sections, retro narrative coda): are they being used? If
required fields are populated and freeform ones are skipped, the schema is
crowding out judgment. The freeform slot is the canary.

**Check 5 — Disposition skew (Goodhart / auto-disposition probe).** In
`/pr-self-review`, what's the distribution of dispositions
(`action | accepted | deferred | open`)? Heavy skew toward `accepted`
suggests authors rationalizing away findings. Heavy skew toward `action`
suggests over-conservative auto-disposition. Healthy distributions usually
have meaningful representation in all four.

**Check 6 — User override rate (calibration-drift probe).** In the followup
TUI, how often does the user override the auto-disposition? High rate →
self-review template is miscalibrated. Zero rate → either auto-disposition
is excellent or the user has disengaged. Both interpretations matter.

**Check 7 — "Did this feel like real work?" (qualitative ground-truth).**
Looking at the cycle's artifacts, did the agents seem to be *thinking* or
*complying*? Answer in 2–3 sentences. Unscientific by design — the purpose
is to force the question, not standardize the answer. Check 7 is the
irreducible ground truth against which every metric is calibrated and must
never be replaced by a number.

### How to keep the checks themselves from becoming ritual

Behavioral-health checks could themselves become form-filling. Mitigations:

- **Rotate.** See *Rotation policy* above — 3 of Checks 1–6 + Check 7
  always, selected at invocation time, not at cycle start.
- **Demand prose, not scores.** Each check produces a sentence or two of
  observation, never a number.
- **Pair quantitative with qualitative.** Where a count is computable
  (Checks 2, 5, 6), require an explanation alongside it.
- **Meta-check periodically.** See *Tuning cadence* below — formulaic
  answers are a tuning trigger, not a passing observation.

### Tuning cadence

The check set is not frozen. As answers accumulate across retros they
reveal which checks surface signal and which have gone formulaic. Tuning
is how the check set stays alive.

**Trigger condition.** Run the tuning pass when **any** of these holds:

- Six or more `retro-behavioral-health` journal entries have landed since
  the last tuning pass (or since Step 3.7 first shipped).
- A single check has answered "same phrasing" across ≥3 consecutive
  selections — that check has gone formulaic and needs replacement or
  rewording.
- A check has been selected ≥5 times over the window and its answers have
  never once diverged from the dimension-score narrative — it is
  redundant with the numeric dimensions and adds no new signal.

**Pass procedure.** When the trigger fires:

1. Query the journal: `jq -c 'select(.role == "retro-behavioral-health")' _meta/effectiveness-journal.jsonl | tail -<N>`.
2. For each of Checks 1–6, read the most recent ≥3 answers and classify
   each as *surprising*, *formulaic*, or *redundant-with-dimensions*.
3. Check 7 is never tuned away — its answer quality can drift but its slot
   is protected.
4. For checks that are formulaic or redundant, either (a) reword the
   check prompt to target the *underlying* drift mode more directly, or
   (b) retire the check and replace it with a new candidate from the
   drift-mode list. Record the edit in a journal entry with
   `--role "retro-behavioral-health-tuning"` naming which check changed
   and why.
5. Bump template-version (leveraging F0 Phase 6) so the tuning edit is
   visible to the scorecard substrate as a distinct version.

**How this differs from rotation.** Rotation shuffles *which* checks run
each retro; tuning edits *what the checks ask*. Rotation runs every
retro; tuning runs on trigger.

**Cadence floor.** Do not tune more often than the trigger. Tuning before
the journal has enough entries just churns the question set without
evidence.

### Recording

Behavioral-health answers go into the journal entry alongside the dimension
scores (see Step 4). They are prose observations, not scored fields. Record
which 4 checks were selected (the 3 random picks from 1–6, plus Check 7)
so rotation frequency can be tracked longitudinally.

## Step 3.8: Settlement pipeline health checks

Settlement signal is only trustworthy when the pipeline that produced it
was actually alive. Phase 7 consumes settlement *output*; Phase 7b (this
step) verifies settlement *liveness*. Each check reads a telemetry file
the earlier phases already write — no new schema.

**Healthy-case silence (invariant).** When a check is green, it emits
**no prose**. No "(green)" bullet, no "(ok)" line, no "all checks passed"
summary. The operator-facing retro surface in a healthy window is
indistinguishable from a window where Step 3.8 did not run — checks
compute silently in the background and only speak when they find
something wrong. Rationale: this is Principle 8 (surface-area discipline)
applied to health monitoring. If every retro narrated "audit coverage
nominal, tournament completion nominal, provenance ok" the checks become
ritual recitation that agents learn to produce without thought, the retro
prose grows with each new check, and the *signal* of a tripped check —
the whole point — drowns in boilerplate green.

Only tripped checks generate narrative, and they do so by naming the
check, the observed value, and the telemetry file the operator should
open. The `pipeline-degraded` headline (below) is the sole indicator in
a healthy window that the checks are there at all: it doesn't appear,
and the dimension-score headline reads normally.

**Where the invariant is enforced.**
- Each `### Check:` subsection below carries a `**When green: no
  prose.**` line — this is load-bearing, not decorative. A check that
  emits a green line on passing violates the invariant.
- The Step 6 report's `pipeline-degraded` block is the only place
  tripped-check narrative appears. The normal-window block reports
  dimension scores only — never `Health checks: all green` or similar.
- A future Phase 7b check added under this step MUST include the silent-
  when-green clause. Do not add check types that inherently need a green
  running status (those belong in a separate health-dashboard surface,
  not in `/retro`).

**Degraded state — `pipeline-degraded`.** A new retro headline state,
**distinct from `pass | weak | fail`**, emitted when any Phase 7b health
check trips. It is *not* a fourth tier of the non-compensatory headline —
it is a separate axis that **supersedes** the headline for the window:

- A clean scorecard over a broken pipeline is **not** `pass`. When
  `pipeline-degraded` fires, the dimension-score headline is replaced by
  `pipeline-degraded` in the journal and the final report. The underlying
  scores may still be computed and recorded (for trend analysis) but the
  operator-facing headline is the degraded state.
- `/evolve` treats `pipeline-degraded` windows as **non-evidentiary**. No
  template mutation may cite a scorecard cell, retro finding, or
  reconciliation delta from a `pipeline-degraded` window, regardless of
  the dimension scores or scorecard cell values. See
  `skills/evolve/SKILL.md` Step 5 for enforcement.
- The prose section in Step 6 lists which checks tripped and points at
  the relevant telemetry file(s). Checks that did *not* trip remain
  silent (per the silence invariant above).

Computationally: let `tripped = [<names of checks that fired>]`. If
`tripped` is non-empty, set `window_state = "pipeline-degraded"`;
otherwise the window inherits the Step 3/6 non-compensatory headline
(`pass | weak | fail`). This is a pure function of Step 3.8 outputs, so
it is deterministic and can be consulted by `/evolve` without re-running
the checks.

### Check: Audit coverage

**What it measures.** Fraction of eligible artifacts in the retro window
that produced at least one verdict row in `$KDIR/_scorecards/rows.jsonl`.
"Eligible artifact" = any artifact whose ceremony has a non-zero trigger
probability `p` in `~/.lore/config/settlement-config.json` and whose
creation timestamp falls in the window.

**Why it matters.** Low coverage with healthy-looking scorecard cells
indicates **biased sampling, not health**. If only the "easy" artifacts
are being audited while hard ones silently miss the sampler, scorecard
aggregates are unrepresentative and `/evolve` risks mutating templates
against a skewed slice.

**Inputs.**
- `$KDIR/_scorecards/rows.jsonl` — filter to rows whose
  `window_start`/`window_end` overlap the retro window; collect distinct
  `source_artifact_ids`.
- Artifact registry for the window — enumerate eligible artifacts by
  ceremony type (implement, pr-self-review, pr-review, spec) whose
  creation timestamp is inside the retro window.
- `~/.lore/config/settlement-config.json` — read the configured `p` per
  ceremony type to decide which ceremonies count as eligible.

**Computation.**
```
coverage = |{eligible artifacts with ≥1 verdict row}| / |eligible artifacts|
```
Compute one coverage ratio per ceremony type whose configured `p ≥ 0.2`,
then report the minimum across those types as the degradation signal.

**Threshold.** `coverage < 0.60` on any ceremony type with configured
`p ≥ 0.2` trips the check. Rationale: below 60%, even a healthy-looking
cell aggregates over <60% of the population and the scorecard is being
read as representative when it isn't. Ceremonies with `p < 0.2` are
intentionally low-coverage and do not trip this check — sampling sparsity
is expected there.

**When green: no prose.** Per the silence invariant above.

**When tripped, output:**
```
[retro] pipeline-degraded: audit coverage
  ceremony=<type> coverage=<pct> (threshold 60% at p=<configured>)
  eligible=<N> audited=<M>
  see: $KDIR/_scorecards/rows.jsonl and ~/.lore/config/settlement-config.json
```

**Distinguished from.** This check is about *whether rows exist*, not
*what verdict they carry*. Judge liveness (task-42) is about verdict
distribution within rows that do exist; audit coverage is about the rows
never landing in the first place.

### Check: Trigger realization rate

**What it measures.** For each ceremony with a configured probability
`p > 0` in `~/.lore/config/settlement-config.json`, compute the observed
firing rate over the retro window and compare to the configured `p`. Flag
any ceremony whose observed rate falls outside a **±50% relative tolerance
band** around `p`, computed over **≥10 ceremonies** in the window. Below
10 samples the check abstains — too noisy to distinguish drift from
Bernoulli variance.

**Why it matters.** The probabilistic trigger hook (task-27) writes a
`trigger-log.jsonl` row for **every** ceremony roll — fired and not-fired
alike. If the hook is broken (never writes), if the queue is stalled (no
rolls ever), or if the config has drifted (configured `p` no longer
matches what the hook applies), the observed rate diverges from `p`. All
three failure modes look identical to downstream scorecard aggregates —
audits just stop happening — but they have different fixes, so the check
flags *trigger realization* before coverage and liveness checks can
silently hide them as "low-sample-size" noise.

**Inputs.**
- `$KDIR/_scorecards/trigger-log.jsonl` — filter to rows whose
  `triggered_at` falls inside the retro window; group by `ceremony`.
- `~/.lore/config/settlement-config.json` — read configured `p` per
  ceremony so the observed rate is compared against the live config
  value at read time, not any historical value.

**Computation.**
```
For each ceremony c with configured_p[c] > 0:
  total_c   = |{rows where ceremony == c and triggered_at ∈ window}|
  fires_c   = |{rows above where fired == true}|
  if total_c < 10: skip c (abstain on low sample)
  observed_rate[c] = fires_c / total_c
  lower[c] = configured_p[c] * 0.5
  upper[c] = configured_p[c] * 1.5
  if observed_rate[c] < lower[c] or observed_rate[c] > upper[c]:
      c trips check with divergence = |observed_rate[c] - configured_p[c]| / configured_p[c]
```
The ±50% band is relative to configured_p. A ceremony at `p=0.3` trips
when observed rate is outside `[0.15, 0.45]`; a ceremony at `p=0.2`
trips outside `[0.10, 0.30]`. Relative bands scale with `p` so the check
remains sensitive at low `p` without false-alarming on high-`p`
ceremonies.

**Threshold.** `|observed_rate - configured_p| / configured_p > 0.5`
with `total_c ≥ 10` trips the check for ceremony `c`. The 10-sample
floor is deliberately conservative — smaller windows mean Bernoulli
variance dominates and the check fires on noise.

**When green: no prose.** Per the silence invariant above.

**When tripped, output (one block per tripped ceremony):**
```
[retro] pipeline-degraded: trigger realization rate
  ceremony=<type> observed=<rate> configured=<p> (band ±50%, min 10 samples)
  rolls=<total> fires=<fires> divergence=<pct>
  see: $KDIR/_scorecards/trigger-log.jsonl and ~/.lore/config/settlement-config.json
```

The `rolls` vs. `fires` breakdown lets the operator distinguish the three
failure modes:
- **Hook broken**: `total_c = 0` for many ceremonies → hook not writing.
  (This appears as "skip c" in the abstention branch; still a signal, but
  surfaces via Audit coverage / Judge liveness rather than this check.)
- **Queue stalled / under-firing**: `total_c ≥ 10` with `fires_c`
  substantially below expected — the sampler reached the log but
  downstream sampling is clamped.
- **Config drift**: `observed_rate` close to a *different* configured `p`
  than today's — operator changed the config between rolls and the
  window-average now straddles the change.

**Distinguished from.** Audit coverage (task-41) measures whether audits
produced *rows*; trigger realization rate measures whether audits
produced *attempts*. A window can have 100% of fired rolls landing rows
(passing Audit coverage) but still trip Trigger realization rate if the
hook's firing rate itself is off — and a window can pass Trigger
realization but fail Audit coverage if every fire dispatches but
downstream judges never emit rows. The two checks decompose the failure
surface so `/evolve` sees which lever is broken.

### Check: Tournament completion

**What it measures.** For PRs merged in the retro window, the fraction
that produced **all three** of: (1) a `/pr-review` external run, (2) a
`/pr-self-review` sidecar, and (3) a completed reconciliation (Phase 6 —
the programmatic stage that tags each self-review finding as `confirm |
extend | contradict | orthogonal` against the external review). A PR is
"complete" only when all three exist; any one missing makes it partial.

**Why it matters.** The tournament reconciliation metrics
(`external_confirm_rate`, `coverage_miss_rate`, `external_contradict_rate`)
are **biased by selection** when reconciliation runs only on PRs that
happen to have both reviews. If half the merged PRs skip `/pr-self-review`
entirely, the reconciliation metrics aggregate over a non-representative
slice — authors who self-review may differ systematically from those who
don't, and the scorecard reads the sample as if it were the population.

**Inputs.**
- Git log of merges into main (or the configured trunk) within the retro
  window — enumerates the denominator (merged PRs in window).
- `$KDIR/_followups/` — locate `/pr-review` external-run artifacts keyed
  to PR number.
- `$KDIR/_followups/<pr>/pr-self-review-sidecar.json` or equivalent —
  locate `/pr-self-review` sidecar artifacts.
- Reconciliation output for each PR — Phase 6 persists a reconciliation
  record tagging each self-review finding against the external review;
  check for its presence and `completed_at` timestamp.

**Computation.**
```
denom     = |{PRs merged inside the retro window}|
external  = |{PRs above with a /pr-review artifact}|
self      = |{PRs above with a /pr-self-review sidecar}|
tri       = |{PRs above with BOTH reviews AND reconciliation completed}|
completion_rate = tri / denom
```
Report `external`, `self`, and `tri` alongside `completion_rate` so the
operator can see which corner is missing when the rate is low.

**Threshold.** `completion_rate < 0.70` trips the check. Rationale: below
70%, more than a third of the merged-PR population is missing from
tournament settlement, and the biased-sample failure mode dominates.

**When green: no prose.** Per the silence invariant above.

**When tripped, output:**
```
[retro] pipeline-degraded: tournament completion
  merged=<denom> /pr-review=<external> /pr-self-review=<self> reconciled=<tri>
  completion_rate=<pct> (threshold 70%)
  see: $KDIR/_followups/ and reconciliation records
```

**Distinguished from.** Audit coverage (task-41) measures settlement
coverage over *all* eligible artifacts; tournament completion measures
three-way matching of reviews+reconciliation over *merged PRs only*. A
PR can show up in the audit-coverage check as covered (because a row
exists from either review) while still tripping tournament completion
(because the other review or the reconciliation is missing).

### Check: Grounding failure rate

**What it measures.** For each work item with reverse-auditor emissions
in the retro window, the fraction that **failed the grounding preflight**
(task-23) before reaching the correctness-gate. Failures are broken down
by `reason` — `file-missing | line-out-of-range | snippet-mismatch |
field-missing` — so the tripped output names which mechanical failure
mode dominates. Inputs are the `audit-attempts.jsonl` sidecars that
task-24 writes per work item.

**Why it matters.** The reverse-auditor is a producer of structured
evidence claims. If its emissions fail the preflight at an elevated rate,
the template is **fabricating evidence pointers** — naming files that
don't exist, citing line ranges that are out of bounds, shipping
snippets that don't match, or leaving required fields empty. Each of
those is a distinct pathology:

- `file-missing`: the template is naming paths it hasn't verified exist.
- `line-out-of-range`: the template has a line-counting bug or is
  citing stale file content.
- `snippet-mismatch`: the template is paraphrasing when the
  content-anchor protocol requires verbatim — hash round-trip fails.
- `field-missing`: the template is emitting under-specified claims
  (missing `falsifier` or `why-it-matters`) the pipeline rejects.

All four are template-level signals: the reverse-auditor prompt or its
few-shot examples need tuning. `/evolve` can act on a per-reason
breakdown but only if the check surfaces the breakdown rather than a
collapsed total.

**Inputs.**
- `$KDIR/_work/<slug>/audit-attempts.jsonl` (one file per work item that
  produced at least one failed preflight in the window) — each row
  carries `{attempt_id, verdict_source: "reverse-auditor", work_item,
  claim_payload, reason, created_at}`.
- `$KDIR/_work/<slug>/audit-candidates.jsonl` — passed preflights. The
  denominator for grounding_failure_rate is `attempts + candidates`, both
  filtered to the window via `created_at`.

**Computation.**
```
For each work item with activity in the window:
  failed   = |audit-attempts.jsonl rows with verdict_source=="reverse-auditor"
                                 and created_at ∈ window|
  passed   = |audit-candidates.jsonl rows in window|
  total    = failed + passed
  if total == 0: skip (no reverse-auditor activity in window)
  grounding_failure_rate = failed / total
  per_reason[r] = |failed rows with reason==r| / failed   for r in the four reasons
```
Aggregate `grounding_failure_rate` across work items by summing the
numerator and denominator separately — do **not** average per-work-item
rates, which double-weights low-activity items.

**Thresholds.** The check trips when **either** holds:
1. Aggregate `grounding_failure_rate > 0.30` over the window with
   `total ≥ 10` (below 10 emissions, variance dominates).
2. Any single `per_reason[r] > 0.50` within a non-empty `failed` set
   with `failed ≥ 5` — concentration in one bucket is a sharper signal
   than a diffuse 30% across all four.

The two triggers decompose differently: aggregate >30% tells the operator
the reverse-auditor is broadly fabricating; concentration >50%
in one bucket tells the operator which specific pathology to fix.

**When green: no prose.** Per the silence invariant above.

**When tripped, output (one block per triggering condition):**
```
[retro] pipeline-degraded: grounding failure rate
  aggregate=<pct> (threshold 30%, N=<total>)
  per_reason: file-missing=<pct>  line-out-of-range=<pct>
              snippet-mismatch=<pct>  field-missing=<pct>
  dominant=<reason> (concentration=<pct>, threshold 50%)
  see: $KDIR/_work/<slug>/audit-attempts.jsonl (per-work-item breakdown)
```
If aggregate trips but no single reason exceeds 50%, omit the `dominant`
line. If a reason concentration trips but aggregate does not, report the
reason alone; aggregate is below threshold so the issue is localized.

**Distinguished from.** Provenance resolution rate (task-46) also reads
a mechanical failure mode against reverse-auditor output, but at a
different pipeline stage:

- Grounding failure rate (this check) is **pre-settlement**: the
  preflight runs *before* any judge reads the claim. `file-missing` here
  means the reverse-auditor cited a path that doesn't exist at all —
  template fabrication, not a reconciliation ambiguity.
- Provenance resolution rate is **post-settlement**: the branch-aware
  reconciliation ladder ran and landed at one of its three terminal
  states. `provenance-unknown` there means the file exists somewhere but
  content-locate couldn't align it to the captured ref — a reconciliation
  ambiguity, not a fabrication.

A window can trip grounding failure rate (template fabricating
pointers) while passing provenance (rare) or vice versa (template
grounds cleanly but reconciliation often lands at provenance-unknown
because of branch divergence). The two checks target distinct fix
surfaces: grounding failures tune the reverse-auditor template;
provenance-unknown tunes the content-anchor snippet-capture protocol or
upgrades to fuzzy-tier reconciliation.

**Distinguished from.** Correctness-gate's `audit_contradiction_rate`
(task-14) is an *adjudicative* failure — the reverse-auditor cited a
real file with valid snippet but misread what it said. Grounding failure
rate is *mechanical* — the pointer itself didn't resolve. Conflating
them hides which template lever to pull: contradictions tune the
reverse-auditor's *reasoning*; grounding failures tune its *evidence
discipline*.

### Check: Candidate-queue backlog

**What it measures.** For each work item with reverse-auditor activity
in the retro window, the growth trend of
`$KDIR/_work/<slug>/audit-candidates.jsonl` (task-26 lifecycle writer).
Queue length is the count of rows with `status: pending_correctness_gate`;
added in window = rows whose `created_at` falls inside the window; resolved
in window = rows that flipped to `gate-passed | gate-failed | retired`
with the transition timestamp inside the window. The check surfaces two
distinct failure modes: **growth-rate trip** (queue more than doubled
within the window — `added / max(resolved, 1) > 2.0`) and **absolute-size
trip** (>50 pending candidates cluster-wide at window close).

**Why it matters.** The candidate queue is the handoff from the
reverse-auditor to the correctness-gate. If it grows unboundedly, the
reverse-auditor is *outrunning* the gate — either the gate is not firing
(execution-path break, caught by Judge liveness) or the gate is firing
but so slowly that gated-passed candidates never reach parity with new
emissions. Both cases silently starve L2 commons promotion: verified
candidates are the only ones eligible for promotion, and a backlog of
`pending_correctness_gate` means the commons never sees the insights the
reverse-auditor is surfacing. A clean scorecard over a starved queue is
not health — it's invisibility.

The absolute-size threshold (50 pending cluster-wide) is a hard cap:
even with zero growth, a backlog above that cap indicates the queue has
become a sink rather than a transit — candidates are accumulating
without ever being adjudicated.

**Inputs.**
- `$KDIR/_work/<slug>/audit-candidates.jsonl` (one file per work item
  with reverse-auditor activity) — each row carries `{candidate_id,
  verdict_source, work_item, file, line_range, falsifier, rationale,
  status, created_at}` per task-26's lifecycle schema. Transitions to
  `gate-passed | gate-failed | retired` rewrite the row or append a
  status-transition row (implementation detail of task-26's writer).

**Computation.**
```
For each work item with audit-candidates.jsonl in the window:
  added_w      = |rows with created_at ∈ window|
  resolved_w   = |rows whose status transitioned to gate-passed|gate-failed|retired
                  with transition timestamp ∈ window|
  pending_w    = |rows with status == "pending_correctness_gate"
                  at window close|
Aggregate:
  added         = sum(added_w)
  resolved      = sum(resolved_w)
  pending_total = sum(pending_w)
  growth_ratio  = added / max(resolved, 1)
```

**Thresholds.** The check trips when **either** holds:
1. `growth_ratio > 2.0` with `added ≥ 10` (below 10 new candidates,
   variance dominates the ratio).
2. `pending_total > 50` cluster-wide at window close, regardless of
   growth ratio.

The two triggers decompose the dynamic failure (growth outrunning
adjudication) from the static failure (accumulated backlog). A window
can pass #1 but fail #2 if the queue was already saturated before the
window opened and held steady; the static cap catches that case.

**When green: no prose.** Per the silence invariant above.

**When tripped, output:**
```
[retro] pipeline-degraded: candidate-queue backlog
  added=<N> resolved=<M> growth_ratio=<ratio> (threshold 2.0, min N=10)
  pending_total=<K> (threshold 50)
  see: $KDIR/_work/*/audit-candidates.jsonl
```
If only one trigger fires, omit the line for the non-tripping threshold
so the operator focuses on the actionable failure mode.

**Distinguished from.** Judge liveness (task-42) checks whether the
correctness-gate is *firing at all* on rows that do exist; backlog
checks whether the *rate* at which the gate resolves candidates keeps
pace with the rate at which the reverse-auditor emits them. A gate that
fires on every candidate but takes seven days to adjudicate each one
passes Judge liveness (non-zero rows, distribution looks healthy) while
tripping Candidate-queue backlog (growth_ratio >2× because the gate is
slower than emission). The two checks catch "gate broken" vs "gate too
slow" — different fixes.

**Distinguished from.** Grounding failure rate (task-45) measures what
the reverse-auditor *fabricates before* reaching the queue; backlog
measures what the queue *does with* candidates that grounded
successfully. A window can have low grounding failure rate (reverse-
auditor is disciplined) but high backlog (gate is the bottleneck); or
high grounding failure rate (reverse-auditor fabricates often) but low
backlog (few valid candidates ever make it in). The two are separate
levers on the same pipeline — preflight tunes the emitter, backlog tunes
the throughput.

### Check: Provenance resolution rate

**What it measures.** Of the reconciliation attempts in the retro window,
the fraction that landed at each terminal label of the Phase-1
branch-aware resolution ladder: `verified`, `provenance-unknown`, or
`provenance-lost`. The check is triggered by the `provenance-unknown`
share specifically — it's the *tunable* failure mode.

**Why it matters.** The resolution ladder uses content anchoring
(`file:line` + exact snippet + `normalized_snippet_hash`) to locate a
claim's current home after squashes, rewrites, and rebases. When too
many attempts fall through to `provenance-unknown`, either the content
anchors are too brittle (churn broke exact + whitespace-normalized
matching) or the snippet-capture fields are underpopulated at authoring
time. Both are fixable — first by opting in to the optional token-shingle
fuzzy tier (same-path only, per the plan's appendix), second by auditing
what producers are putting in `exact_snippet` / `symbol_anchor`. A high
`provenance-lost` rate is a different failure (content actively deleted
from main and the captured branch) and is not the signal this check
surfaces; the check tunes on `provenance-unknown`.

**Inputs.**
- Reconciliation records for the retro window — each carries a
  terminal verdict in `{verified | provenance-unknown | provenance-lost}`
  plus the `file:line` + snippet that drove the lookup. Exact storage
  path TBD by the Phase 1 reconciliation appendix implementation; check
  the artifact settlement record or a dedicated reconciliation log.
- Optional: per-verdict breakdown by file extension or directory to help
  the operator see whether a specific surface is churning.

**Computation.**
```
total = |reconciliation attempts in window|
verified          = |{verdict == "verified"}|
provenance_unknown = |{verdict == "provenance-unknown"}|
provenance_lost   = |{verdict == "provenance-lost"}|
unknown_rate      = provenance_unknown / total
```

**Threshold.** `unknown_rate > 0.40` trips the check. Rationale: once
more than 40% of attempts are falling through exact + whitespace-
normalized matching, the resolution ladder is running outside its
designed operating regime — the optional fuzzy tier exists for exactly
this case, and the content-anchor capture discipline is worth auditing.
Below 40% is the designed-for state; most attempts resolve cleanly or
land at `provenance-lost` because the content really was deleted.

**When green: no prose.** Per the silence invariant above.

**When tripped, output:**
```
[retro] pipeline-degraded: provenance resolution rate
  total=<N> verified=<v> provenance-unknown=<u> provenance-lost=<l>
  unknown_rate=<pct> (threshold 40%)
  tuning signal: consider enabling token-shingle fuzzy tier (same-path)
                 or audit exact_snippet/symbol_anchor capture completeness
  see: Phase 1 branch-aware reconciliation appendix
```

**Distinguished from.** Grounding failure rate (task-45) measures the
reverse-auditor's *pre-settlement* preflight — fabricated pointers that
never reach reconciliation. Provenance resolution rate measures the
*post-settlement* content-locate stage for claims that passed preflight
and then had to be matched against a changed codebase. A claim can
succeed at preflight (pointer was real at capture time) and still land
at `provenance-unknown` (content moved or was rewritten by the time
reconciliation fires).

### Check: Judge liveness

**What it measures.** Per-judge verdict distribution over the retro
window. Three distinct failure signatures — each trips the check on its
own, with its own threshold and remediation pointer:

1. **Gate broken** — `correctness-gate` emitting `unverified` on more
   than 80% of candidate claims it adjudicates. Far more likely that
   the gate is malfunctioning than that 80%+ of producers are fabricating.
2. **Auditor degraded** — `reverse-auditor` emitting `∅` (explicit
   silence / no omission claim) on more than 90% of portfolios. The
   reverse-auditor is designed to emit its single strongest grounded
   claim *or* explicit silence; a near-total-silence rate suggests
   either template degradation or over-conservative sampling.
3. **Zero-rows-despite-triggers** — any judge (`correctness-gate`,
   `curator`, `reverse-auditor`) with **zero** rows in `rows.jsonl`
   for the retro window *while* `trigger-log.jsonl` shows triggers
   firing for its role. Execution path is broken between trigger and
   scorecard append.

**Why it matters.** Scorecard aggregates compute equally over all rows
regardless of whether the emitting judge is healthy — a silently broken
judge produces either uniform verdicts (gate) or no verdicts (auditor,
execution-path failure) and pollutes downstream metrics. Judge liveness
distinguishes "producers are doing poorly" (legitimate scored signal)
from "the judge stopped working" (noise masquerading as signal).

**Inputs.**
- `$KDIR/_scorecards/rows.jsonl` — filter to the retro window; group
  rows by judge identity (from `metric` naming convention or an
  explicit `judge` field once F0 surfaces one).
- `$KDIR/_scorecards/trigger-log.jsonl` — used for the
  zero-rows-despite-triggers signature; cross-reference trigger
  firings for each judge role against the presence of rows.

**Computation.** Compute three independent signals:
```
gate_unverified_rate       = unverified / total        (correctness-gate only)
auditor_silence_rate       = silence    / total        (reverse-auditor only)
zero_rows_per_judge        = {judge: rows_in_window == 0 AND triggers_fired > 0}
```

**Thresholds.**
- `gate_unverified_rate > 0.80` → signature = gate-broken
- `auditor_silence_rate > 0.90` → signature = auditor-degraded
- any judge in `zero_rows_per_judge` set → signature =
  zero-rows-despite-triggers (`<judge-name>`)

Any one signature tripping sets `window_state = "pipeline-degraded"`.

**When green: no prose.** Per the silence invariant above.

**When tripped, output (one block per tripped signature):**
```
[retro] pipeline-degraded: judge liveness (<signature>)
  judge=<name> <metric>=<value> (threshold <pct>)
  sample=<N> window=<start>..<end>
  see: $KDIR/_scorecards/rows.jsonl (and trigger-log.jsonl for zero-rows case)
```

**Distinguished from.** Audit coverage (task-41) measures whether any
row exists for an eligible artifact; judge liveness measures what the
rows *say* once they exist. A window can have high coverage (rows exist)
but tripped judge liveness (the rows are uniform-unverified or uniform-
silent), and the scorecard would read misleadingly healthy in both
checks if only the first existed.

### Check: Calibration state surface

**What it measures.** For each judge (`correctness-gate`, `curator`,
`reverse-auditor`), the current scorecard-weight state:

- `calibrated` — judge passed its discrimination test (known-true vs.
  known-false fixtures); rows it emits carry full scorecard weight.
- `calibration-pending` — calibration run hasn't happened yet or is in
  progress; rows emit but are non-load-bearing.
- `calibration-failed` — calibration run completed and failed; rows
  emit but must be treated as advisory only.

Source of truth: each judge's calibration log (Phases 2–4 of the
settlement plan write these — correctness-gate at task-15, curator at
task-19, reverse-auditor implicit in Phase 4's calibration step).

**Why it matters.** A judge that has fired in the window but is not
`calibrated` emits rows that look identical to calibrated rows in
`rows.jsonl` — same schema, same fields, same `kind: "scored"`. If
`/retro` and `/evolve` treat those rows as load-bearing, the pipeline
silently aggregates untrusted signal into scorecard cells and drives
template mutation from evidence the calibration process hasn't yet
validated. This is exactly the "plausibility without verification"
failure mode the three-judge pipeline is trying to avoid.

**Inputs.**
- Per-judge calibration log — path is set by the respective Phase 2–4
  implementation (e.g., a JSON state file inside `$KDIR/_scorecards/`
  or attached to the template registry). Fields required: `judge_id`,
  `state` ∈ `{calibrated | calibration-pending | calibration-failed}`,
  `last_run_at`, `reason_if_failed` (when `state == "calibration-failed"`).
- `$KDIR/_scorecards/rows.jsonl` — filter to the retro window; compute
  per-judge counts of rows emitted.

**Computation.**
```
for each judge J:
  state_J       = read from J's calibration log (default "calibration-pending")
  rows_J        = |{rows in window attributable to J}|
  if state_J != "calibrated" and rows_J > 0:
    tripped.append((J, state_J, rows_J))
```

The check trips when **any** judge has `state != "calibrated"` AND
`rows_J > 0` — i.e., when untrusted rows are actually landing in the
window. A judge that is uncalibrated but hasn't fired in the window is
silent (no rows, no degradation signal needed).

**Threshold.** Any tripped tuple (uncalibrated judge with rows > 0 in
the window) sets `window_state = "pipeline-degraded"`. No numeric
tolerance — a single uncalibrated row is non-load-bearing by
construction.

**When green: no prose.** Per the silence invariant above.

**When tripped, output (one block per tripped judge):**
```
[retro] pipeline-degraded: calibration state surface
  judge=<name> state=<calibration-pending | calibration-failed>
  rows_in_window=<N> (non-load-bearing — /retro will not count)
  reason_if_failed=<text or "n/a">
  see: <judge's calibration log path>
```

**Non-load-bearing in /retro.** When this check trips, rows from the
offending judge are **excluded** from the Step 3 dimension-score
evidence and from the scorecard headline (task-38). They remain in
`rows.jsonl` (storage is append-only), but `/retro`'s scoring must
filter them out — render the rows as `calibration-pending:<judge>` or
`calibration-failed:<judge>` in any per-row display, and exclude their
cells from any aggregate that implies a quality judgment. This filter
is a local pre-processing step on the Step 3.8 output, not a new
schema field.

**Distinguished from.** Judge liveness (task-42) measures whether a
calibrated judge is actually *emitting meaningful verdicts*.
Calibration state surface measures whether the judge's emissions are
*trusted at all*. An uncalibrated judge with 100% `verified` verdicts
still trips this check (and the verdicts are ignored); a calibrated
judge with 100% `unverified` verdicts trips Judge liveness but not
this check (the verdicts count — the producers are fabricating).
Template registry's registered/unregistered distinction (task-36 in
`/evolve`) is orthogonal — it gates *template* trust; this check gates
*judge* trust. Both can be off simultaneously.

## Step 3.9: Non-compensatory scorecard headline (per template-version)

Complementary to Step 3's dimension scores (subjective, about knowledge
delivery) and Step 3.8's pipeline-degraded state (objective, about
settlement liveness). Step 3.9 computes a **`pass | weak | fail`
headline per template-version** from the six MVP scorecard metrics
using **worst-dimension-wins** — never a weighted average.

**When this step runs.** Only when Step 3.8 did NOT trip
`pipeline-degraded`. A degraded window's dimension scores and scorecard
cells are non-evidentiary per task-48, so computing a per-template
headline from them would be misleading. If `window_state ==
"pipeline-degraded"`, skip Step 3.9 entirely and carry `pipeline-degraded`
straight through to the Step 4 journal entry and Step 6 report.

**Input filter.** Read `$KDIR/_scorecards/rows.jsonl`, filter strictly
to rows where ALL of:
- `kind == "scored"` — telemetry rows are excluded from headline
  computation. They may appear elsewhere in `/retro` prose as
  observational context but never in the headline.
- `calibration_state == "calibrated"` — `pre-calibration` and
  `unknown` rows are displayed in the evidence block for transparency
  (per Step 3.6) but do not contribute to the headline.
- `template_version` is present in
  `$KDIR/_scorecards/template-registry.json` — unregistered rows
  render as `unregistered:<hash>` and are excluded from the headline.
- The row's retro window is NOT in the set of `pipeline-degraded`
  windows (reuses the same filter as `/evolve` Step 5 — a row from a
  degraded window is non-evidentiary regardless of the window being
  scored in the current `/retro` cycle).

**The six MVP metrics (see plan's "MVP scorecard vector" table).**

| Metric | Granularity | Template scored | Direction |
|---|---|---|---|
| `factual_precision` | claim-local | producer | higher = better |
| `curated_rate` | set-level | producer | higher = better |
| `triviality_rate` | set-level | producer | **lower = better** |
| `omission_rate` | portfolio-level | producer | **lower = better** |
| `external_confirm_rate` | claim-local | pr-self-review | higher = better |
| `observation_promotion_rate` | claim-local | producer | higher = better |

Two of the six (`triviality_rate`, `omission_rate`) are **inverted** —
high values are bad. The threshold table below accounts for direction.

**Per-metric thresholds (MVP — subject to tuning after early data).**

| Metric | pass (need ≥) | fail (flag if ≤) | Rationale |
|---|---|---|---|
| `factual_precision` | 0.85 | 0.65 | correctness floor |
| `curated_rate` | 0.40 | 0.20 | curator keeps ≥40% of verified candidates |
| `triviality_rate` (inverted) | ≤ 0.30 | ≥ 0.55 | curator drops <55% as trivial |
| `omission_rate` (inverted) | ≤ 0.20 | ≥ 0.45 | portfolio-level miss rate |
| `external_confirm_rate` | 0.60 | 0.35 | self-review agrees with external |
| `observation_promotion_rate` | 0.25 | 0.10 | `/remember` capture rate |

Rows between pass and fail thresholds are `weak`. The thresholds are
policy; `/evolve` should not mutate them — they calibrate over the data
collection, not over /evolve-cycle template edits.

**Minimum sample for headline computation.** A metric with fewer than
10 rows aggregated over the retro window is rendered as
`insufficient:<N>` and treated as `weak` for headline purposes — not
`fail`, because the signal is absent rather than negative. Below-sample
metrics are listed separately in the operator-facing report so the
maintainer can tell "low metric with N=50" from "low metric with N=3".

**Per-template-version grouping.** Group the filtered rows by
`template_version` (hashed template identity). Compute each metric's
aggregate value (mean across rows with that metric for that template
version) per-template-version. Emit one headline per distinct
template_version; `/retro` shows the full table.

**Worst-dimension-wins combination per template_version.**
```
per_metric_classification = {pass | weak | fail | insufficient:<N>} for each of the 6 metrics
headline_per_template = worst(per_metric_classification)
```
Where `worst` maps:
- any `fail` → `fail`
- no `fail` but any `weak` (including insufficient:<N>) → `weak`
- all `pass` → `pass`

**Never a weighted average.** This is load-bearing: a weighted average
would let high scores on one metric compensate for low scores on
another, which is exactly the failure mode the non-compensatory headline
exists to prevent. A template with perfect factual_precision (0.95) and
terrible omission_rate (0.60) is `fail`, not `weak-but-close-to-pass`.

**Report shape (per template-version).**
```
[retro] Scorecard headline — per template-version (non-compensatory)

  <template_id>@<version-prefix-12>        HEADLINE=<pass|weak|fail>
    factual_precision:            <val>    [<pass|weak|fail|insufficient:<N>>]  n=<N>
    curated_rate:                 <val>    [<pass|weak|fail|insufficient:<N>>]  n=<N>
    triviality_rate:              <val>    [<pass|weak|fail|insufficient:<N>>]  n=<N>
    omission_rate:                <val>    [<pass|weak|fail|insufficient:<N>>]  n=<N>
    external_confirm_rate:        <val>    [<pass|weak|fail|insufficient:<N>>]  n=<N>
    observation_promotion_rate:   <val>    [<pass|weak|fail|insufficient:<N>>]  n=<N>
    worst: <metric-that-set-headline>
    unregistered/pre-calibration/degraded-window rows excluded: <count>
```

One such block per distinct registered `template_version` with rows in
the window. If the filter produces zero eligible rows for every
template, render `[retro] Scorecard headline: no eligible rows
(all-filtered)` — this is a condition adjacent to `pipeline-degraded`
(data exists but none pass the evidentiary filter), distinct from a
healthy green window.

**Journal persistence.** The headline goes into the existing retro
journal entry (Step 4) under a `scorecard_headline` field in
`--scores`. One map per template-version:
```json
{
  "scorecard_headline": {
    "<template_id>@<version>": "pass",
    "<template_id>@<version-2>": "fail",
    ...
  }
}
```
so that `/evolve` can read per-template state without re-running Step
3.9. `/evolve` then ranks templates by harmonic mean for mutation
prioritization (per plan). The headline and the harmonic-mean ranking
are distinct artifacts — headline is the pass/weak/fail gate; harmonic
mean is the "which template most needs attention" order within a
failing set.

**Invariant.** `/evolve` reads `scorecard_headline` to gate template
mutations: a `fail` template can be edited from evidence in the
current window (if it also passes the Step 5 citation gate); a `pass`
template should not be edited from this window absent a specific
failing-metric citation; a `weak` template is editable but
deprioritized. `/evolve` does not re-derive these verdicts; the
headline is the single source of truth.

## Step 4: Write Journal Entry

**Mandatory.**

Two shapes depending on `window_state` from Step 3.8:

**When `window_state == "pipeline-degraded"`:**

```bash
lore journal write \
  --observation "pipeline-degraded | Tripped: <check-name-1>, <check-name-2>, ... | Key finding: <one sentence on which check(s) tripped and where to look>. Scorecard cells from this window are non-evidentiary for /evolve." \
  --context "retro: <slug>" \
  --work-item "<slug>" \
  --role "retro" \
  --scores '{"d1_delivery": X, "d2_quality": X, "d3_gaps": X, "d4_alignment": X, "d5_spec_utility": X, "window_state": "pipeline-degraded", "tripped_checks": ["<check-name-1>", "<check-name-2>"]}'
```

Dimension scores are still written (for trend analysis) but the headline
prose leads with `pipeline-degraded`, and the `window_state` +
`tripped_checks` fields make the degraded status queryable by `/evolve`.

**When `window_state != "pipeline-degraded"` (normal window):**

```bash
lore journal write \
  --observation "Delivery: X/5 | Quality: X/5 | Gaps: X/5 | Alignment: X/5 | Spec Utility: X/5. Key finding: <one sentence>. Most actionable gap: <specific gap>." \
  --context "retro: <slug>" \
  --work-item "<slug>" \
  --role "retro" \
  --scores '{"d1_delivery": X, "d2_quality": X, "d3_gaps": X, "d4_alignment": X, "d5_spec_utility": X}'
```

### Step 4a: Behavioral-health journal entry

**Mandatory when Step 3.7 ran.** Persists the rotation selection and
answers into the journal so task-3's baseline window and task-4's question
tuning have a queryable trail. Separate entry (distinct `--role`) so
longitudinal queries filter cleanly from dimension-score entries.

```bash
lore journal write \
  --observation "Checks: <C1,C4,C5,C7> | C1: <1–3 sentence answer> | C4: <answer> | C5: <answer> | C7: <answer>" \
  --context "retro-behavioral-health: <slug>" \
  --work-item "<slug>" \
  --role "retro-behavioral-health"
```

`Checks:` lists the 4 selected check numbers (the 3 random picks from 1–6
plus 7). One `C<n>: <answer>` segment per selected check, in numeric order.
No score fields — these are prose observations only.

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

**When `window_state == "pipeline-degraded"`:**

```
[retro] <slug> — PIPELINE-DEGRADED
  Tripped: <check-name-1>, <check-name-2>, ...
  <per-tripped-check block from Step 3.8's tripped-output templates>

  Dimension scores (recorded but non-headline):
    Delivery: X/5 | Quality: X/5 | Gaps: X/5 | Alignment: X/5 | Spec Utility: X/5

  /evolve will refuse to cite this window's scorecard cells. Fix the
  tripped pipeline stage(s), then re-run /retro on the next window.
  Evolution suggestions logged: N (will NOT be applied from this window)
```

**When `window_state != "pipeline-degraded"` (normal window):**

Scorecard-first shape: delta surface + headline first, dimension scores
relegated to narrative coda.

```
[retro] <slug>

  # Primary: scorecard deltas (Step 3.0)
  Scorecard deltas — window <current-window-id> vs <previous-window-id>
    <template_id>@<version-prefix-12>:
      <metric>: <prev> → <curr>  (<direction> <signed delta>, n=<N>)  [<classification change>]
      ...
    Suppressed: <N> (below-sample / below-magnitude / unregistered)

  # Headline: non-compensatory pass|weak|fail per template-version (Step 3.9)
  Scorecard headline (non-compensatory, worst-dimension-wins):
    <template_id>@<version-prefix-12>  HEADLINE=<pass|weak|fail>
      worst metric: <metric>
    <template_id-2>@<version-prefix-12>  HEADLINE=<pass|weak|fail>
      worst metric: <metric>

  # Narrative coda: dimension scores (Step 3)
  Narrative coda (dimension scores, not headline):
    Delivery: X/5 | Quality: X/5 | Gaps: X/5 | Alignment: X/5 | Spec Utility: X/5
    Key finding: <one sentence on the knowledge-system behavior this cycle>
    Disagreement with scorecard headline? <none | brief note>

  # Behavioral-health coda (Step 3.7)
  <4 selected checks + answers — 1-3 sentences each>

  Evolution suggestions logged: N (run /evolve to apply)
```

**Section order is load-bearing.** The delta surface leads because it
is the actionable signal. The headline follows because it is the
settlement verdict. Dimension scores come last because they're
longitudinal context, not primary signal. Reversing this order would
re-establish the dimension-score-as-headline pattern that task-35 is
explicitly retiring.

**First-retro / zero-delta-window case.** If Step 3.0 reported "first
eligible window — no delta baseline", skip the delta block and lead
with the headline block. The narrative coda still appears at the end.
