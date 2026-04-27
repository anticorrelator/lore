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

The federation commands (`lore retro export --redact`, `lore retro import <file>`, `lore retro aggregate`) that *distribute* retro evidence across operators are CLI-level verbs enforced by `cli/lore` dispatch via `require_maintainer`. They are **not** part of this skill's workflow — a `/retro` invocation never produces an import/aggregate as a side effect, and a contributor running `/retro` does not need to read about federation to do their job.

Run every step as written. Role-gating applies to `/evolve` and to CLI-level retro federation verbs, not to the retro ceremony itself.

## Execution order (load-bearing)

The step numbering encodes a dependency order that downstream `/evolve` and trend analysis rely on. Running steps out of order produces coherent-looking output whose headline misrepresents the window.

1. **Steps 1–2.7**: setup, evidence gathering, selective batch audit. Steps 1–2.6 run unconditionally. Step 2.7 is **signal-triggered** (runs only when promoted Tier 3 claims are uncovered and not already in the priority-audit queue) — advisory for observational windows. Step 2.7 must complete before any scorecard read so Step 3.8's routing-realization check sees current `rows.jsonl`.
2. **Step 2.8**: escalation telemetry. Non-scored, feeds retro prose only.
3. **Step 2.9**: scale access appropriateness. Qualitative cycle-level field — two graded sub-questions emitted as sidecar row to `retro-scale-access.jsonl`. Runs unconditionally alongside Step 2.8; never affects `pipeline-degraded` state.
4. **Step 3.8** (settlement pipeline health checks): **runs before** any scorecard-consumption step. Sets `window_state = "pipeline-degraded" | "warmup" | normal`. If degraded, Steps 3.0/3.9 skip.
5. **Step 3.0** (scorecard delta surface, *primary*): tier-partitioned. Runs only on normal windows. Skipped on `pipeline-degraded`.
6. **Step 3** (dimension scores): demoted to narrative coda. Always scored for longitudinal trend, never the headline.
7. **Step 3.5** (memory system telemetry): reads `tier: telemetry` rows + sidecars; observability only, **never feeds `/evolve`**. Runs on all windows.
8. **Step 3.6–3.7**: scorecard forward guidance + behavioral-health — coda/diagnostic.
9. **Step 3.9** (non-compensatory headline): filters `tier: template` only. Runs only on normal windows. Skipped on `pipeline-degraded`.
10. **Steps 4–6**: journal persistence, evolution suggestions, operator-facing report. Branch on `window_state` so `pipeline-degraded` never surfaces a pass/weak/fail headline.

**Phase 7b (health checks at Step 3.8) ships alongside Phase 7 (scorecard consumption at 3.0/3.9)** — they share no schema but interlock: 3.8 gates the evidentiary status of the window; 3.0 and 3.9 refuse to read a degraded window. Editing either section must preserve the `pipeline-degraded` short-circuit in the downstream consumers (Steps 3.0, 3.9, 4, 6).

## Tier-aware reading (canonical contract)

`/retro` is a **tier-aware reader** of `rows.jsonl`. The tier enum values and their /retro semantics are:

| `tier` | /retro treatment |
|---|---|
| `task-evidence` | Step 3.0 delta surface emits a tier-partitioned view; never contributes to Step 3.9 headline. |
| `reusable` | Step 3.0 delta surface; never Step 3.9 headline. |
| `correction` | Step 3.0 delta surface. May factor into /evolve secondary doctrine-correction gate (see `skills/evolve/SKILL.md` Step 5). No Step 3.9 headline weight. |
| `template` | Step 3.0 delta surface + **Step 3.9 non-compensatory headline** (sole headline-eligible tier). Feeds /evolve primary template-mutation gate. |
| `telemetry` | Step 3.5 memory-system telemetry **only**. Never Step 3.0/3.9. Never /evolve. P2.3-16 anti-coupling invariant. |

**Missing-tier legacy policy.** Rows written before the tier enum extension have no `tier` field. Readers MUST treat missing `tier` as `tier: telemetry` (safest default — non-evidentiary for /evolve; visible in Step 3.5 but excluded from template-behavior headline).

**Post-migration warm-up.** Immediately after the tier substrate migration lands, `rows.jsonl` will contain many pre-migration rows (all mapped to `tier: telemetry`) and few `tier: template` rows. If the `tier: template` row count is below the Step 3.9 sample-size minimum (n ≥ 10) in the current window, Step 3.8 reports `warmup: awaiting-template-tier-rows` — a distinct state from `pipeline-degraded`. Warm-up is informational; it does NOT gate /evolve runs. The warm-up state clears as soon as enough new-tier rows accumulate.

### Step 1: Resolve Work Item

```bash
lore resolve
```

Set `KNOWLEDGE_DIR` to result, `WORK_DIR` to `$KNOWLEDGE_DIR/_work`.

1. Parse argument as work item slug (exact → substring title → substring slug → branch → recency → archive fallback)
2. Load `plan.md`, `notes.md`, `_meta.json` from `$WORK_DIR/<slug>/` (or `_archive/<slug>/` if archived)
3. No argument → infer from current git branch
4. No match → ask user

Report: `[retro] Evaluating: <title> (<slug>) [archived]`

### Step 2: Gather Evidence

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

### 2b.5: Surfaced concerns (off-scale routing)

Check for worker-surfaced concerns that were routed during implementation:

```bash
KDIR=$(lore resolve)
SC_FILE="$KDIR/_work/<slug>/surfaced_concerns.jsonl"
[ -f "$SC_FILE" ] && cat "$SC_FILE"
```

If `surfaced_concerns.jsonl` is non-empty, read each entry. For each concern:

- **Count them** in the evidence summary (see format below)
- **Assess disposition:** Were the concerns addressed in the work? Check plan.md Design Decisions and Open Questions for matching content.
- **Feed D3 scoring** (Knowledge Capture & Propagation): unaddressed concerns that reveal genuine gaps in the plan's scope inform D3 — workers shouldn't need to route off-scale for concerns that a well-scoped plan would have anticipated.
- **Do not re-resolve them here.** Report their presence and disposition as evidence; resolution is a spec-lead or follow-on spec decision.

### 2b.6: Channel-contract review loop

Aggregate channel-shopping signals per role × slot over the last 5 retro cycles (or all available cycles if fewer than 5 exist). Three signal types:

- **`under_routing`** — off-scale concerns that were routed by workers but, in retrospect, should have been emitted as captures. Inferred from `surfaced_concerns.jsonl` entries that were later addressed inline (`accepted-one-shot`) rather than resolved via follow-on or knowledge promotion. High rate = workers routing things off-scale that the channel contract should have told them to capture directly.
- **`over_capture`** — captures that should have been off-scale routes. Inferred from knowledge entries later corrected (have `corrections[]` within 2 cycles) or off-scale routes resolved as `declined` by the lead. High rate = workers capturing speculative/architectural content as settled knowledge.
- **`evidence_only_durable`** — worker reports where Investigation or Tests contain durable architectural claims never promoted. Heuristic: execution-log entries with declarative architectural language ("X always does Y", "the invariant is", "every Z must") in Investigation/Tests with no corresponding `lore capture` in the session.

**Computation (per role × slot, over last N cycles up to 5):**
```
For each signal_type in {under_routing, over_capture, evidence_only_durable}:
  numerator   = count of outputs in that role×slot matching the signal heuristic
  denominator = total outputs in that role×slot in the window
  rate        = numerator / denominator  (skip if denominator == 0)
```

**Threshold:** Rate > 0.30 over at least 3 cycles fires a flag. Below 3 cycles is too noisy to attribute to systematic drift vs one-cycle variance.

**When a flag fires**, emit a sidecar row:
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

The script writes to `$KDIR/_scorecards/retro-channel-flags.jsonl`. One row per flagged role × slot per retro cycle.

**Remedy narrative (when flags fire):** Add a prose paragraph to the retro narrative (Step 6) naming the role × slot, signal type, rate, and a proposed remedy. Remedies target the **workflow contract**, not the individual producer.

Remedy heuristics by signal type:
- `under_routing`: consider adding a worked example of this slot's capture threshold to the channel-contract matrix, or lowering the capture bar for this role × slot.
- `over_capture`: consider adding an ingestion warning that speculative claims in this slot should be routed off-scale; or raise the capture confidence threshold.
- `evidence_only_durable`: consider adding a protocol step that requires workers to decide capture-vs-route for declarative claims before closing a task.

**When no flags fire: no prose.** Per the healthy-case silence invariant (same rationale as Step 3.8 health checks). Channel-contract drift is only notable when it crosses the threshold.

**Invariant.** This step never calls `scorecard-append`. The `retro_flag` sidecar rows are NOT settlement signal — they are qualitative drift indicators. Routing them through `rows.jsonl` would expose them to `/evolve` consumption and create a scoring incentive to suppress flags.

### 2b.7: Consumption-contradiction evidence

New evidence class introduced by the consumer-contradiction-channel substrate. Consumer contradictions are **observational** signals — a reader (worker, spec-lead, implement-lead) prefetched a commons entry and observed it is false in the context of their current work. They are a distinct evidence class from the adjudicative three-judge pipeline.

**Enumerate `$KDIR/_work/<slug>/consumption-contradictions.jsonl`** across work items with activity in the retro window. Each row carries:
- `contradiction_id` — slug-form identifier unique per work item
- `claim_id` — the commons-entry claim being contradicted
- `corrected_entry_path` — the commons entry the contradiction targets
- `template_id`, `template_version` — the template that produced the contradicted entry (for attribution)
- `status` — `routed | verified | rejected` (lifecycle state from correctness-gate audit)
- `verified_by_verdict_id` — present when `status=verified`; the settlement record id
- `dispatch_status` — `routed` when `consumption-contradiction-append.sh` priority-dispatched to `lore audit`
- `captured_at_sha`, `observed_at`

Count rows by status: `routed`, `verified`, `rejected`. Report:

```
Consumption contradictions: N total (R routed to audit, V verified, J rejected)
  pending verdict (routed, no verdict yet): <P>
```

The `verified` count feeds Step 3.0 `contradiction_verification_rate` and Step 3.8 consumer-contradiction routing health. The `routed` set is excluded from Step 2.7 batch audit (already priority-dispatched).

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
  Surfaced concerns: N entries (M addressed / K pending)
  Consumption contradictions: N total (R routed, V verified, J rejected)
  Sessions: N entries | Retrieval: N events | Friction: N events
  Token savings: ~Nk estimate
```

### Step 2.5: Low-Diagnostic Check

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

### Step 2.7: Selective batch audit (signal-triggered)

Under the lazy-audit model, `lore audit` is **decorative, not a publication precondition** — audit coverage below 60% is *expected*, not pipeline degradation. This step selectively batch-dispatches `lore audit` for promoted Tier 3 claims whose audit coverage is lagging, using a fallback substrate that does not depend on `flow-events.jsonl` (which is a future substrate and not yet available).

**Observational windows.** Advisory for review-only, spec-only, or prose-only retros where no producer artifacts were emitted. Skip with: `[retro] No eligible artifacts for batch audit; skipping.`

**D8 fallback substrate — what this step reads in lieu of `flow-events.jsonl`:**

- **Promotion-time proxy** (precedence order, chosen to avoid filesystem ctime instability):
  1. **Primary:** entry-internal `learned:` timestamp in commons markdown YAML frontmatter — the canonical field written by `capture.sh` / `lore-promote.sh`. Use this when present; stable across filesystem operations, restores, and syncs.
  2. **Secondary:** filesystem *birthtime* (`stat -f %SB` macOS, `stat -c %W` Linux) when the filesystem supports it. Stable for the file's lifetime but unavailable on some filesystems.
  3. **Tertiary (degraded):** filesystem `ctime` only as a last resort. Under ctime-only conditions, Step 3.8 Audit-coverage lag sub-check runs in **advisory mode** (see Step 3.8 below) — this step still enumerates candidates but reports reduced-confidence in the output.
- **Audit-triggered proxy:** rows in `$KDIR/_scorecards/audit-attempts.jsonl` + `$KDIR/_scorecards/audit-trigger-log.jsonl` (written by `probabilistic-audit-trigger.py`) = "audit dispatched for artifact." Stands in for the future `audit_triggered` event rows.
- **Verdict rows:** `kind==scored` entries in `rows.jsonl` with `template_id in {correctness-gate, curator, reverse-auditor}` = "audit completed + produced verdict."

**Signal for eligibility.**

An artifact is eligible for batch dispatch when both hold:
1. **Promoted Tier 3 claim** in the retro window (identified via promotion-time proxy falling in the window).
2. **Uncovered** — no row in `$KDIR/_scorecards/rows.jsonl` whose `source_artifact_ids` includes this artifact's id AND whose `window_start`/`window_end` overlap this retro window.

**Exclusions.**

- **Priority-routed consumption-contradiction artifacts.** Rows in any `$KDIR/_work/<slug>/consumption-contradictions.jsonl` with `dispatch_status: routed` are already in the priority-audit queue via `consumption-contradiction-append.sh`. Double-dispatching wastes audit budget. Exclude these from the batch.
- **Observational windows** (see above) skip entirely.

**Dispatch.** For each eligible artifact, invoke:

```bash
lore audit "<artifact-id>"
```

`lore audit` resolves the artifact, routes it through the three-judge pipeline, and appends verdict rows to `$KDIR/_scorecards/rows.jsonl` via `scorecard-append.sh`. No new retro-side persistence is required — Step 3.8 reads the same `rows.jsonl` and picks up backfilled rows automatically.

**Rate limit and failure handling.**
- Do **not** batch more than **20 uncovered artifacts per retro invocation**. If the uncovered set is larger, audit the 20 highest-priority (by `scripts/audit-sample.sh` risk weights, or by recency when the sampler is not yet wired) and report the remainder as a pending-backlog counter. A window with 50+ uncovered artifacts is itself a pipeline-health signal (Step 3.8 routing-realization check will surface it). Unbounded batching would make retro execution time O(uncovered artifacts).
- Treat non-zero exit codes from `lore audit` as partial failures: log artifact-id + exit code to `$KDIR/_meta/retro-audit-log.jsonl` and continue.
- Stub phases of `lore audit` (pre full routing) may exit 0 without writing rows. That is expected — Step 3.8 will see the coverage shortfall and emit `pipeline-degraded` once ≥10 eligible artifacts have produced no verdicts, the canonical signal the pipeline stub is still in place.

**Output:**
```
[retro] Batch audit: <K> eligible / <M> uncovered (post-exclusion)
  audited: <A> (rows written: <R>)
  deferred: <D> (queue backlog — see Step 3.8 audit-coverage)
  excluded: <E> (priority-routed consumption-contradictions)
  failed: <F> (see $KDIR/_meta/retro-audit-log.jsonl)
```

**Why this is selective, not unconditional.** The pre-lazy-audit version of this step unconditionally ran `lore audit` to close coverage gaps before Step 3.8's 60% threshold tripped. Under lazy-audit, that threshold no longer applies — coverage is expected to be incomplete, and audits are sampled probabilistically. Unconditional batch would (a) double-dispatch consumption-contradiction artifacts already in the priority queue, (b) saturate audit capacity on low-risk material, and (c) inflate retro latency without a health-check benefit.

**Flow-events swap-in (future work).** When `flow-events.jsonl` lands, the promotion-time-proxy + audit-attempts.jsonl reads are replaced by structured event rows (`tier3_emitted`, `audit_triggered`). The logic shape here stays the same; only the signal sources change. That swap is explicitly out of scope for this rewrite and is tracked separately.

### Step 2.8: Escalation verdict surface (work-item telemetry, not scored)

**Diagnostic, not scored.** When a worker returns a structured escalation verdict of the shape `{escalation: "task-too-trivial-for-solo-decomposition", rationale: "<one-sentence reason>"}` (validated at `scripts/validate-structured-report.py`), /retro surfaces it here as **work-item telemetry**. This surface is intentionally off-band from the dimension scores in Step 3 and off-band from the scorecard substrate:

- **Not wired to `/evolve`.** Escalation rate must never drive template mutation. Scoring producers on how often they escalate creates perverse incentives — either workers suppress legitimate escalations to keep their "rate" down, or they escalate trivially to game the signal.
- **Not rolled into any producer template scorecard.** No `kind == "scored"` row is written for an escalation. This is the **canonical precedent for the `kind` discriminator rule**: any observation type that must not drive template mutation stays off `kind == "scored"`. Future row types that face the same incentive hazard (e.g., advisor consultation counts, trigger-realization rates) should cite this precedent in their design docs.
- **Work-item scope, not portfolio scope.** Counts and rates are attributed per work item, not aggregated across templates, because the relevant remediation (re-scope the plan, merge the sub-task, accept one-shot) happens at the plan level.

### 2.8a: Inputs

Read escalation verdicts from the cycle's worker reports:
- **Primary:** `execution-log.md` entries in `$WORK_DIR/<slug>/` — each completed task's worker report is persisted there; the report text contains the escalation stanza when one was emitted.
- **Secondary:** cross-session worker SendMessage reports surfaced in `notes.md` session entries, when `execution-log.md` is absent (review-only cycles) but a worker still returned an escalation.

Parse each report with the same regex pattern used by `validate-structured-report.py:find_escalation()` so this surface counts exactly what the gate counts — `VALID_ESCALATION = "task-too-trivial-for-solo-decomposition"` with a non-empty `rationale`. Malformed escalations are explicitly excluded.

### 2.8b: Lead disposition

For each escalation verdict, record a **lead disposition** — what the lead agent (team-lead or /implement orchestrator) did with the escalation. Closed enum:

- `merged` — lead merged the sub-task into a larger peer task rather than decomposing further.
- `re-scoped` — lead edited the plan to replace the escalated task with a wider-scope alternative, then discarded the original.
- `accepted-one-shot` — lead accepted the escalation but proceeded with the original trivial task as-is (no plan change).
- `unreviewed` — no visible lead response before the retro fires. Either the work is still in-flight or the lead missed the escalation. Distinct from `accepted-one-shot` because the intent signal is missing.

Infer disposition from `tasks.json` and `plan.md` state at retro time:
- Escalated task's subject rewritten + sibling absorbed it → `merged`.
- Plan's phase edited after escalation timestamp AND task set changed → `re-scoped`.
- Task completed with `status: completed` and no plan/tasks edit followed → `accepted-one-shot`.
- Task still `in_progress` or `pending` → `unreviewed`.

### 2.8c: Report shape

Render as a compact work-item telemetry block, **separate from dimension scores in Step 3 and separate from the Step 3.8 pipeline-degraded block**. Empty when zero escalations fired.

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

When zero escalations fired, emit **no prose** — consistent with the Step 3.8 silence invariant.

### 2.8d: Journal persistence

Write a separate journal entry so longitudinal queries can filter cleanly:

```bash
lore journal write \
  --observation "Escalations: <N> (<a> merged, <b> re-scoped, <c> one-shot, <d> unreviewed) | rate: <N>/<T> | rationales: <brief joined list>" \
  --context "retro-escalations: <slug>" \
  --work-item "<slug>" \
  --role "retro-escalations"
```

`--role "retro-escalations"` is distinct from `retro` (dimension scores), `retro-behavioral-health` (qualitative), and `retro-evolution` (suggestions). **Four separate roles by design** — collapsing them would force consumers to demux by observation prose, which is fragile.

**Invariant.** This step never calls `scorecard-append`. There is no scorecard row written for an escalation — not `kind="scored"`, not `kind="telemetry"`. Journal-only storage structurally rules out any back-door through which /evolve could eventually consume escalation data.

### Step 2.9: Scale access appropriateness (qualitative cycle-level field)

**Qualitative, not scored.** Ask the spec-lead (or the agent running `/retro`) two sub-questions about how retrieval scale was managed during the cycle. This step produces **one sidecar row per cycle** in `$KDIR/_scorecards/retro-scale-access.jsonl` — separate from `rows.jsonl` to keep it out of the settlement pipeline.

This is a cycle-level observation, NOT a producer scoring metric. It feeds longitudinal trend tracking only — never `/evolve` template mutations, never the pass|weak|fail headline.

### Sub-question (a): Abstraction level

> "Did agents get context at the right level of abstraction — enough to reason at the scale of the problem, without fine detail crowding out the framing or forcing descent to reconstruct it?"

Grade: `right-sized | too-coarse | too-fine`

One-line rationale citing specific retrieval calls observed in evidence (Step 2b's delivery audit, Step 2c's retrieval log). The rationale must name at least one concrete retrieval event or cite "no retrieval log — evidence absent" if the log is missing.

**Directionality** (for longitudinal interpretation):
- `too-coarse` → missing or under-linked child entries; the knowledge store has the concept but not the implementation-level detail workers needed.
- `too-fine` → missing bridging parent entries; workers were handed implementation detail without the framing context.
- `right-sized` → no structural gap surfaced.

### Sub-question (b): Scale-agnostic recall utility

> "Was scale-agnostic recall useful in this cycle — did choosing the abstraction level substitute for reading code or drilling into finer-scale entries, or was the capability redundant?"

Grade: `useful | neutral | not-useful`

One-line rationale. Cite whether workers bypassed code reads due to knowledge delivery, or whether store entries were consulted but didn't reduce exploration.

### Emission

```bash
KDIR=$(lore resolve)
bash ~/.lore/scripts/retro-scale-access-append.sh \
  --cycle-id "<slug>" \
  --abstraction-grade "<right-sized|too-coarse|too-fine>" \
  --abstraction-rationale "<one-line citing retrieval calls>" \
  --recall-grade "<useful|neutral|not-useful>" \
  --recall-rationale "<one-line>"
```

The script writes to `$KDIR/_scorecards/retro-scale-access.jsonl` (created on first use). It validates grades against the closed enum before appending.

**Report shape:**
```
[retro] Scale access: abstraction=<grade> | recall=<grade>
  abstraction: <one-line rationale>
  recall: <one-line rationale>
```

**Invariant.** This step never calls `scorecard-append`. The sidecar is not a scorecard row — it has no `calibration_state`, no `template_version`, no `kind: scored`, no `tier`. Mixing it into `rows.jsonl` would expose it to `/evolve` consumption; the separate file structurally prevents that.

### Step 3.0: Scorecard delta surface (primary, tier-partitioned)

**This step is primary.** The scorecard delta surface leads the /retro output (Step 6 report). Dimension scoring (Step 3) is the qualitative coda — useful for describing knowledge-system behavior in prose, but **not** the operator-facing headline. Step 3.9's non-compensatory `pass|weak|fail` per template-version is the primary headline; Step 3.0 shows what *changed* since the last window to explain why the headline moved (or didn't).

**Why delta-first.** A single-window scorecard cell tells you where a template stands; a delta tells you which direction it's moving. A template at `factual_precision=0.72` might be `weak` in absolute terms but trending sharply upward (last window: 0.58) — the delta is the actionable signal.

**Relationship to other steps.**
- Step 3.8 (health checks) runs first; if `pipeline-degraded`, Step 3.0's deltas are non-evidentiary and the surface reads "not computed — window is pipeline-degraded, see Step 3.8".
- Step 3.9 (headline) supplies the current-window values; Step 3.0 supplies the deltas *against* the previous eligible window.
- Step 3 (dimensions) runs after Step 3.0 and is demoted to **narrative coda**.

### 3.0a: Inputs

- `$KDIR/_scorecards/_current.json` — the rollup produced by `scorecard-rollup.sh` for the current retro window.
- Previous window's rollup — the rollup snapshot whose `window_end` is the most recent value **strictly earlier than** the current retro window's start. If no prior eligible window exists, report "first eligible window — no delta baseline" and emit no delta rows; downstream readers treat this as informational, not a degradation signal.
- `$KDIR/_scorecards/template-registry.json` — unregistered rows render as `unregistered:<hash>` and are excluded from delta surfaces (same rule as Step 3.9).
- `$KDIR/_work/*/consumption-contradictions.jsonl` — for the `contradiction_verification_rate` metric added below.
- The set of `pipeline-degraded` windows (from Step 4's journal) — if either the current or previous window is degraded, the delta for that template-version is **skipped**, not zeroed.

### 3.0b: Tier partitioning

Partition rows by `tier` and emit **one delta surface per tier** in this order (most actionable first):

1. **`tier: template`** — template-behavior deltas. Primary surface. Feeds Step 3.9 headline and /evolve Step 5 primary gate.
2. **`tier: correction`** — doctrine-correction deltas. Secondary. May feed /evolve's doctrine-correction gate (see `skills/evolve/SKILL.md` Step 5).
3. **`tier: reusable`** — reusable commons-entry deltas. Informational; no /evolve weight.
4. **`tier: task-evidence`** — task-local grounding deltas. Informational; no /evolve weight.

Each tier's surface is computed independently with the same 3-filter gate described below. Mixing tiers would Goodhart the template metric — task-local claim quality ≠ template-produced claim quality.

**Never mix tiers in a single delta cell.** A `tier: task-evidence` factual_precision reading and a `tier: template` factual_precision reading measure different things.

### 3.0c: Delta computation

For each registered `(template_id, template_version)` that has `kind==scored, calibrated` rows in both the current and previous windows, scoped to one tier at a time:

```
delta_{metric} = current_{metric} - previous_{metric}
```

Compute a delta per metric in the six-MVP-metric vector from Step 3.9, plus the new `contradiction_verification_rate` metric (see below). Two of the MVP metrics are inverted (`triviality_rate`, `omission_rate`) — *improvement* means the delta is **negative**. The surface notation uses an explicit direction indicator (↑ improving, ↓ regressing) so readers don't track direction per metric.

**New metric: `contradiction_verification_rate`.** For `tier: template` surfaces only:

```
contradiction_verification_rate = |{consumption-contradictions with status=verified against this template in window}|
                                / |{consumption-contradictions with status ∈ {verified, rejected} against this template in window}|
```

A high rate indicates the template is producing claims that field observers repeatedly find false — a strong signal for template mutation. The rate is **inverted**: lower is better.

### 3.0d: 3-filter surface gate (load-bearing)

The delta surface is **not** a per-cell dump. It surfaces only deltas that carry actionable signal. A delta is surfaced when **all three** hold:

1. **Large change.** `|delta|` exceeds the per-metric magnitude threshold. MVP thresholds:
   - `factual_precision`: |delta| ≥ 0.05
   - `curated_rate`: |delta| ≥ 0.05
   - `triviality_rate`: |delta| ≥ 0.05
   - `omission_rate`: |delta| ≥ 0.03 (more sensitive; small changes in portfolio-level miss rate are load-bearing)
   - `external_confirm_rate`: |delta| ≥ 0.05
   - `observation_promotion_rate`: |delta| ≥ 0.03
   - `contradiction_verification_rate`: |delta| ≥ 0.10 (observational signal is coarser than adjudicative)
2. **Sufficient sample size.** Both windows must have n ≥ 10 rows for that metric. Below-sample deltas are noise.
3. **Registered template_version in both windows.** If either current or previous `template_version` is unregistered, skip — we can't attribute the delta to a known template lineage.

Deltas that pass the filter are **surfaced**; deltas that fail are **suppressed** but counted (one line at the end: "<N> small / below-sample / unregistered deltas suppressed"). Preserves the "did something change?" signal without drowning the surface in noise.

### 3.0e: Report shape (per tier)

The delta surface is the first block of the Step 6 report output. Structure:

```
[retro] Scorecard deltas — primary surface

  Window: <current-window-id>  vs  <previous-window-id>

  --- tier: template ---
  Eligible templates with deltas: <N> surfaced, <M> suppressed

  <template_id>@<version-prefix-12>:
    factual_precision:             0.72 → 0.81  (↑ +0.09, n=24)     [delta-pass → regressing]
    curated_rate:                  0.48 → 0.41  (↓ -0.07, n=18)     [regressing]
    omission_rate:                 0.22 → 0.14  (↓ -0.08, n=32)     [inverted: ↓ is improving]
    contradiction_verification_rate: 0.08 → 0.17 (↑ +0.09, n=12)     [inverted: ↑ is regressing]
    (other metrics: unchanged or below threshold)

  Suppressed: 12 (7 below-sample, 3 unregistered, 2 below-magnitude)

  --- tier: correction ---
  <template_id>@<version-prefix-12>:
    factual_precision (correction): 0.82 → 0.88  (↑ +0.06, n=11)     [improving]

  --- tier: reusable ---
  (informational — no deltas meet the 3-filter gate)

  --- tier: task-evidence ---
  (informational — no deltas meet the 3-filter gate)
```

Each surfaced delta line reads left-to-right:
`<metric>: <previous> → <current>  (<direction symbol> <signed delta>, n=<current sample>)  [<classification change if any>]`

"Classification change" is derived from Step 3.9's headline thresholds (applies to `tier: template` surface only): a delta that moved the metric from `weak` to `pass`, or from `pass` to `fail`, is flagged.

**Pipeline-degraded windows.** If either window was `pipeline-degraded`, emit per affected template-version:
```
  Deltas for <template_id>@<version>: skipped (degraded window — see Step 3.8)
```

**First-window case.** If no prior eligible window exists:
```
  First eligible window — no delta baseline. Full current-window values
  appear in Step 3.9's headline block below.
```

### 3.0f: Journal persistence

Deltas are derived signal, not source data. They are NOT written to `rows.jsonl` — the scorecard substrate remains append-only with first-derivative storage only. The delta surface IS persisted to the retro journal entry (Step 4) under a `scorecard_deltas` field keyed by tier:

```json
{
  "scorecard_deltas": {
    "template": {
      "<template_id>@<version>": {
        "factual_precision": {"prev": 0.72, "curr": 0.81, "delta": 0.09, "n_curr": 24, "surfaced": true},
        "contradiction_verification_rate": {"prev": 0.08, "curr": 0.17, "delta": 0.09, "n_curr": 12, "surfaced": true},
        ...
      }
    },
    "correction": { ... },
    "reusable": { ... },
    "task-evidence": { ... }
  }
}
```

`surfaced: true` iff the delta passed all three filters. This lets downstream readers (dashboards, /evolve ranking) access both the full delta map and the filtered view without re-computing.

**Invariant — no compensation.** A large improvement on one metric does NOT suppress a surfaced regression on another metric for the same template. The surface shows all surfaced deltas; the reader (human or `/evolve`) composes them. This mirrors the Step 3.9 non-compensatory rule.

### Step 3: Evaluate Dimensions (narrative coda)

*Dimension scoring is the narrative coda — not the headline.* The operator-facing headline is Step 3.9's `pass|weak|fail` per template-version; the actionable signal is Step 3.0's scorecard delta surface. Dimension scores persist for longitudinal trend tracking and for cases where settlement data is sparse (new repos, first few retros), but they no longer lead the report.

Keep scoring honest: the scores are still 1-5 and still cite concrete evidence. Do not inflate or deflate to match the scorecard headline — if the dimension score disagrees with the headline, that disagreement is itself diagnostic. The Step 6 report frames dimensions under "Narrative coda" below the scorecard delta block and the headline block.

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

### Step 3.5: Memory System Telemetry

**Observability only — MUST NOT feed `/evolve` or the F1 harmonic-mean template ranking.** These metrics describe how the knowledge store is behaving as a system. They are NOT verdict-level scores on individual producer templates; surfacing them here is for the operator's situational awareness, not for driving template mutations. Any `/evolve` citation that references a metric from this section is invalid and must be rejected.

**P2.3-16 anti-coupling invariant.** The `tier: telemetry` enum value exists specifically to keep these rows out of /evolve's citation gate. Any row emitted by this step carries `tier: telemetry` (or no tier — readers apply the missing-tier legacy policy and treat it as telemetry). If /evolve's citation gate ever accepts a `tier: telemetry` row as evidence for template mutation, the anti-coupling has been broken — this is the highest-priority silent-breakage risk in the memory-telemetry pipeline.

Read `$KDIR/_scorecards/rows.jsonl` filtered to rows with `tier: telemetry` in the retro window. For each metric below, compute a one-line summary and select the top-3 highlights.

When a metric has zero rows in `rows.jsonl` for the window, emit: `<metric>: no data in window` and continue. Do not treat absence as a failure.

---

### Retention after renormalize

**Source:** rows where `metric == "retention_after_renormalize"`.
Key fields: `entry_id`, `cycles_survived`, `template_id` (producer template), `run_id`.

**Summary:** median `cycles_survived` across all entries in window; count of entries with `cycles_survived >= 3` (signal of durable high-quality output).

**Top-3 highlights:** entries with the highest `cycles_survived`.

```
retention_after_renormalize:
  median cycles_survived: <N>  |  entries with ≥3 cycles: <K>/<total>
  top survivors:
    <entry_id>  cycles=<N>  producer=<template_id>
    <entry_id>  cycles=<N>  producer=<template_id>
    <entry_id>  cycles=<N>  producer=<template_id>
```

---

### Downstream adoption rate

**Source:** rows where `metric == "downstream_adoption_rate"`.
Key fields: `entry_id`, `value` (adoption rate 0.0–1.0), `status`, `window_days`.

**Summary:** mean adoption rate across entries in window; fraction with `value > 0.5`.

**Top-3 highlights:** entries with the highest adoption rate, with their `status`.

```
downstream_adoption_rate:
  mean rate: <val>  |  entries >50%: <K>/<total>
  top adopters:
    <entry_id>  rate=<val>  status=<status>
    <entry_id>  rate=<val>  status=<status>
    <entry_id>  rate=<val>  status=<status>
```

---

### Route precision

**Source:** rows where `metric == "route_precision"`.
Key fields: `role`, `outcome` (accepted/declined), `route_id`, `template_id`.

**Summary:** acceptance rate per role (accepted / total routes) in window.

**Top-3 highlights:** roles with the lowest acceptance rate (most likely to benefit from channel-contract adjustment).

```
route_precision:
  <role>: <accepted>/<total> routes accepted (<pct>%)
  <role>: <accepted>/<total> routes accepted (<pct>%)
  <role>: <accepted>/<total> routes accepted (<pct>%)
```

---

### Supersession quality

**Source:** rows where `metric == "supersession_quality"`.
Key fields: `superseded_entry_id`, `successor_entry_id`, `quality` (improved/neutral/regressed).

**Summary:** fraction of supersessions marked `improved` in window.

**Top-3 highlights:** any `neutral` or `regressed` supersessions.

```
supersession_quality:
  improved: <K>/<total> (<pct>%)  |  neutral: <N>  |  regressed: <M>
  notable (non-improved):
    <superseded_entry_id> → <successor_entry_id>  quality=<neutral|regressed>
    ...
```

When all supersessions are `improved` and count ≥ 1: emit `supersession_quality: all improved (<K> total)` with no highlights.

---

### Scale drift rate

**Source:** rows where `metric == "scale_drift_rate"`.
Key fields: `producer_role`, `value` (drift rate 0.0–1.0), `run_id`.

**Summary:** drift rate per role; flag any role where `value > 0.20` (guardrail threshold).

**Top-3 highlights:** roles with highest drift rate.

```
scale_drift_rate:
  <producer_role>: drift=<val>  [ABOVE-THRESHOLD]
  <producer_role>: drift=<val>
  <producer_role>: drift=<val>
```

When no role exceeds 0.20: emit `scale_drift_rate: all roles within guardrail` with no highlights.

---

### Label revision rate

**Source:** rows where `metric == "label_revision_rate"`.
Key fields: `scale_id`, `value`, `run_id`.

**Summary:** label revision rate per scale_id; flag `registry_design_flag` rows if present.

**Top-3 highlights:** scale_ids with highest revision rate.

```
label_revision_rate:
  <scale_id>: rate=<val>  [DESIGN-FLAG]
  <scale_id>: rate=<val>
  <scale_id>: rate=<val>
```

---

### Scale access appropriateness (sidecar)

**Source:** `$KDIR/_scorecards/retro-scale-access.jsonl` — the row whose `cycle_id` matches the current retro slug (most recent by `ts` if multiple).

```
scale_access_appropriateness:
  abstraction: <right-sized|too-coarse|too-fine>  — <one-line rationale>
  recall:      <useful|neutral|not-useful>         — <one-line rationale>
```

When no row exists for this cycle: `scale_access_appropriateness: not assessed this cycle`.

---

### Channel-contract flags (sidecar)

**Source:** `$KDIR/_scorecards/retro-channel-flags.jsonl` — all rows whose `cycle_id` matches the current retro slug.

```
channel-contract flags:
  <role>/<slot>  signal=<signal_type>  rate=<pct>  over <N> cycles
    remedy: <remedy_hint or "see Step 2b.6 guidance">
```

When no flags fired: `channel-contract flags: none`.

---

**Step 3.5 invariant — no `/evolve` coupling.** The metrics in this section describe memory-system health, not producer-template quality. They inform the operator's understanding of how the knowledge store is aging, routing, and self-correcting — they do not adjudicate whether any template produced correct output. `/evolve` MUST NOT cite any metric from this section as evidence for a template mutation. If `/evolve` sees a "retention_after_renormalize" or "downstream_adoption_rate" citation, it must skip that citation as non-evidentiary (enforced structurally by the `tier: template` filter in `/evolve` Step 5).

### Step 3.6: Scorecard data (forward guidance)

`/retro` is a primary reader of `$KDIR/_scorecards/_current.json` and `$KDIR/_scorecards/rows.jsonl`. This step captures the load-bearing invariants so future edits don't drift.

**CC-04 Sole-writer invariant.** `scripts/scorecard-append.sh` (surfaced as `lore scorecard append`) is the **only** sanctioned writer of `rows.jsonl`. Never append to that file directly from this skill, from agents it spawns, or from edits it proposes. /retro is a READER only.

**Corrupt-row handling.** Any row failing schema validation (`schema_version` absent, `kind ∉ {scored, telemetry, consumption-contradiction}`, `calibration_state ∉ {calibrated, pre-calibration, unknown}`, or `tier ∉ {task-evidence, reusable, correction, template, telemetry}` — except legacy missing-tier rows which are treated as telemetry) is treated as corrupt. The rollup emits a `[scorecard] warning: rows.jsonl:<N> corrupt — <reason>` stderr line and EXCLUDES the row from aggregation.

**Unregistered-hash rendering.** When `_current.json` references a `template_version` hash not present in `$KDIR/_scorecards/template-registry.json`, render the hash as `unregistered:<hash>` in summaries and **assign it no scorecard weight** (exclude from D1–D5 evidence and from any trend comparison). This isolates the registry-write path from the scorecard-write path.

**Prompt-context invariant.** Scorecard rows are never loaded into an agent prompt. `/retro` consumes `_current.json` in this skill's own runtime; it does not inject raw rows into spawned subagents or into the journal entry. Summaries into aggregate statistics are fine; raw row content is not.

### Step 3.7: Behavioral Health

Qualitative counter-loop to scorecard Goodhart. Tests for the *kind of work* the agents are doing, not the conformance of the artifact. Answerable from existing cycle artifacts — no new schema, no new instrumentation. Each check produces a sentence or two of observation, not a number. Value is longitudinal.

### Rotation policy

Don't run all 7 checks every retro — rotation prevents ritualization and stops agents from shaping artifacts to the check.

**Default rotation:** on each `/retro` invocation, select **3 checks uniformly at random from Checks 1–6, plus Check 7 always** — yielding 4 checks total. Check 7 (qualitative ground-truth) is never rotated out; it is the irreducible human-reads-the-work floor.

**Selection timing invariant:** checks are selected **at invocation time** (when `/retro` begins executing Step 3.7), NOT at the start of the work cycle. If agents know in advance which checks will run, they can shape their artifacts to the check and the observational value collapses. **Late binding is load-bearing, not cosmetic.**

**Implementation sketch:** in Step 3.7, draw 3 integers from `{1,2,3,4,5,6}` without replacement (any entropy source — system randomness, hash of current timestamp), union with `{7}`, run those checks, and record which four were selected in the journal entry so longitudinal analysis can track each check's rotation frequency.

**Do not** pre-compute the rotation at cycle start, persist the selection in `plan.md`, or otherwise make the check set visible to producers before they finish their work.

### Drift modes being watched

1. **Ritualization** — outputs technically conformant but generic.
2. **Confirmation bias** — agents under-produce findings that contradict prior knowledge; the store calcifies.
3. **Form-filling vs. substance** — required fields get content, optional fields go empty. Schema crowds out craft.
4. **Goodhart drift** — behavior bends toward any added metric and away from the underlying goal.
5. **Judgment atrophy** — agents stop making non-obvious calls because the protocol doesn't reward them.
6. **Calibration drift** — auto-disposition, routing, or scoring thresholds fall out of alignment with human override patterns.
7. **Compliance theater** — multi-step skills where every step "succeeds" but the substance was thin.

### Candidate checks

Each is a question answerable from artifacts in the cycle just completed. Record a 1–3 sentence qualitative answer. Do not score.

**Check 1 — Observation substance (ritualization probe).** Pick 2–3 worker Observations from `execution-log.md` at random. For each: could a different worker on a different task have written the same sentence? If yes, the observation was ritual.

**Check 2 — Knowledge promotion rate (substance probe).** Of the worker Observations from this cycle, how many were promoted into knowledge captures? Compare against recent retros. A falling rate suggests Observations converging on cheap talk.

**Check 3 — Surprise rate (confirmation-bias probe).** Across investigation findings in the window (`/spec`, `/pr-review`, `/pr-self-review`), what fraction were genuinely surprising — extended or contradicted prior knowledge — vs. confirmed what was already documented? Heavy confirmation skew suggests prior-knowledge injection is anchoring rather than orienting.

**Check 4 — Narrative slot health (form-filling / judgment-atrophy probe).** For skills with optional freeform fields (worker **Investigation** field, finding narrative sections, retro narrative coda): are they being used? If required fields are populated and freeform ones are skipped, the schema is crowding out judgment.

**Check 5 — Disposition skew (Goodhart / auto-disposition probe).** In `/pr-self-review`, what's the distribution of dispositions (`action | accepted | deferred | open`)? Heavy skew toward `accepted` suggests authors rationalizing away findings. Heavy skew toward `action` suggests over-conservative auto-disposition.

**Check 6 — User override rate (calibration-drift probe).** In the followup TUI, how often does the user override the auto-disposition? High rate → self-review template is miscalibrated. Zero rate → either auto-disposition is excellent or the user has disengaged. Both interpretations matter.

**Check 7 — "Did this feel like real work?" (qualitative ground-truth).** Looking at the cycle's artifacts, did the agents seem to be *thinking* or *complying*? Answer in 2–3 sentences. Unscientific by design — the purpose is to force the question, not standardize the answer. Check 7 is the irreducible ground truth and must never be replaced by a number.

### How to keep the checks themselves from becoming ritual

- **Rotate.** See *Rotation policy* above — 3 of Checks 1–6 + Check 7 always, selected at invocation time.
- **Demand prose, not scores.** Each check produces a sentence or two, never a number.
- **Pair quantitative with qualitative.** Where a count is computable (Checks 2, 5, 6), require an explanation alongside it.
- **Meta-check periodically.** See *Tuning cadence* — formulaic answers are a tuning trigger, not a passing observation.

### Tuning cadence

The check set is not frozen. As answers accumulate across retros they reveal which checks surface signal and which have gone formulaic.

**Trigger condition.** Run the tuning pass when **any** holds:
- Six or more `retro-behavioral-health` journal entries have landed since the last tuning pass.
- A single check has answered "same phrasing" across ≥3 consecutive selections — that check has gone formulaic.
- A check has been selected ≥5 times over the window and its answers have never once diverged from the dimension-score narrative — it is redundant.

**Pass procedure.** When the trigger fires:
1. Query the journal: `jq -c 'select(.role == "retro-behavioral-health")' _meta/effectiveness-journal.jsonl | tail -<N>`.
2. For each of Checks 1–6, read the most recent ≥3 answers and classify each as *surprising*, *formulaic*, or *redundant-with-dimensions*.
3. Check 7 is never tuned away — its answer quality can drift but its slot is protected.
4. For checks that are formulaic or redundant, either (a) reword the check prompt to target the *underlying* drift mode more directly, or (b) retire the check and replace it with a new candidate from the drift-mode list. Record the edit in a journal entry with `--role "retro-behavioral-health-tuning"`.
5. Bump template-version so the tuning edit is visible to the scorecard substrate as a distinct version.

**Cadence floor.** Do not tune more often than the trigger. Tuning before the journal has enough entries just churns the question set without evidence.

### Recording

Behavioral-health answers go into a **separate** journal entry (see Step 4a). They are prose observations, not scored fields. Record which 4 checks were selected so rotation frequency can be tracked longitudinally.

### Step 3.8: Settlement pipeline health checks

Settlement signal is only trustworthy when the pipeline that produced it was actually alive. Step 3.8 verifies settlement *liveness*. Each check reads a telemetry file the earlier phases already write — no new schema.

**Healthy-case silence (invariant — load-bearing).** When a check is green, it emits **no prose**. No "(green)" bullet, no "(ok)" line, no "all checks passed" summary. The operator-facing retro surface in a healthy window is indistinguishable from a window where Step 3.8 did not run — checks compute silently in the background and only speak when they find something wrong.

Rationale: if every retro narrated "audit coverage nominal, provenance ok" the checks become ritual recitation that agents learn to produce without thought, the retro prose grows with each new check, and the *signal* of a tripped check drowns in boilerplate green.

Only tripped checks generate narrative. The `pipeline-degraded` headline is the sole indicator in a healthy window that the checks are there at all: it doesn't appear, and the dimension-score headline reads normally.

**Where the invariant is enforced.**
- Each `### Check:` subsection below carries a `**When green: no prose.**` line — load-bearing, not decorative. A check that emits a green line on passing violates the invariant.
- The Step 6 report's `pipeline-degraded` block is the only place tripped-check narrative appears. The normal-window block reports the scorecard delta + headline + dimension scores only — never `Health checks: all green`.
- A future check added under this step MUST include the silent-when-green clause.

**Degraded state — `pipeline-degraded`.** A retro headline state, **distinct from `pass | weak | fail`**, emitted when any Step 3.8 health check trips. Not a fourth tier of the non-compensatory headline — a separate axis that **supersedes** the headline for the window:

- A clean scorecard over a broken pipeline is **not** `pass`. When `pipeline-degraded` fires, the dimension-score headline is replaced by `pipeline-degraded` in the journal and the final report. Underlying scores may still be computed and recorded (for trend analysis) but the operator-facing headline is the degraded state.
- `/evolve` treats `pipeline-degraded` windows as **non-evidentiary**. No template mutation may cite a scorecard cell, retro finding, or reconciliation delta from a `pipeline-degraded` window, regardless of the dimension scores or scorecard cell values. See `skills/evolve/SKILL.md` Step 5 for enforcement.
- The prose section in Step 6 lists which checks tripped and points at the relevant telemetry file(s). Checks that did *not* trip remain silent.

Computationally: let `tripped = [<names of checks that fired>]`. If `tripped` is non-empty, set `window_state = "pipeline-degraded"`; otherwise the window inherits the Step 3.9 non-compensatory headline (`pass | weak | fail`). A pure function of Step 3.8 outputs — deterministic, consultable by `/evolve` without re-running the checks.

**Warm-up state — `warmup: awaiting-template-tier-rows`.** Distinct from `pipeline-degraded`. Emitted when the tier migration has recently landed and `tier: template` row counts are below Step 3.9's sample-size minimum (n ≥ 10). Informational, not a gate — `/evolve` runs proceed, but the Step 3.9 headline naturally shows `insufficient:<N>` until enough new-tier rows accumulate. The warm-up state clears automatically as rows arrive.

### Check: Audit coverage (D6/D8 rewrite — lag + routing-realization, NOT coverage-threshold)

**What it measures.** Two independent sub-checks, both of which must be healthy for the check to be green under the lazy-audit model.

**Why the old 60% coverage threshold was retired.** Under lazy-audit (`lore audit` is decorative, not publication precondition), coverage < 60% is *expected* behavior, not degradation. The old threshold tripped every window and destroyed the signal-to-noise ratio of `pipeline-degraded` — every window looked degraded, so /evolve treated every window as non-evidentiary. The rewrite re-anchors the check to lag and routing realization, which are genuine failure signals under lazy-audit.

**Sub-check 1: Lag.**

Median time from promotion-time proxy to audit-triggered-proxy for promoted Tier 3 claims in the window is ≤ configurable threshold (default: **7 days**). Exceeding → this sub-check trips.

**Promotion-time precedence (D8 fallback):**
1. Primary: entry-internal `learned:` timestamp in commons markdown YAML frontmatter.
2. Secondary: filesystem birthtime (`stat -f %SB` macOS, `stat -c %W` Linux).
3. Tertiary (degraded): filesystem `ctime`. When only `ctime` is available, the lag sub-check runs in **advisory mode**: the sub-check reports its observation in the output but does NOT trigger `pipeline-degraded` state (ctime is noisy and would wrongly gate /evolve on filesystem quirks). The routing sub-check remains authoritative even under ctime-only conditions.

**Audit-triggered proxy:** rows in `$KDIR/_scorecards/audit-attempts.jsonl` + `$KDIR/_scorecards/audit-trigger-log.jsonl`.

**Sub-check 2: Routing realization.**

For the set of audit-triggered-proxy rows older than a **grace period of 24h** in the window, compute:

```
verdict_realization_ratio = |{rows with corresponding verdict row in rows.jsonl}| / |audit-triggered rows older than grace period|
```

Healthy when **either**:
- Ratio ≥ **0.50** with sample size ≥ **10**, OR
- **≥ 3 verdicts** when sample size < 10.

Below threshold → routing partially failed (triggers fired, verdicts aren't landing) — this sub-check trips.

**Why both sub-checks.** Routing realization catches the case where triggers fire but downstream judges don't produce verdicts (earlier Round 1 design tested only "at least one verdict" which missed partial routing failure — 100 triggered, 1 verdict would pass). Lag catches slow pipelines even when routing is complete. Both together catch the main failure modes under lazy-audit.

**Alignment with Trigger realization rate check.** The routing realization sub-check is **distinct** from the existing Trigger realization rate check, which measures "did probabilistic triggers fire at the configured rate?". Routing realization measures the downstream half: "of triggers that fired, did verdicts land?" Both are preserved and measure different failure surfaces.

**When green: no prose.**

**When tripped, output:**
```
[retro] pipeline-degraded: audit coverage
  lag: median <days> (threshold 7 days)     [advisory-mode | authoritative]
    promotion-time source: learned | birthtime | ctime
  routing_realization: <ratio> (threshold 0.50 @ n≥10, or ≥3 verdicts @ n<10)
    triggered_old_enough=<N>  verdicts_landed=<M>
  see: $KDIR/_scorecards/audit-attempts.jsonl and rows.jsonl
```

If only one sub-check tripped, omit the healthy sub-check's detail line.

**Distinguished from.** Old "coverage < 60%" absolute-coverage threshold is retired. The lag + routing-realization design catches real failure modes (slow pipelines, broken routing) without false-alarming on expected sparse coverage.

### Check: Trigger realization rate

**What it measures.** For each ceremony with a configured probability `p > 0` in `~/.lore/config/settlement-config.json`, compute the observed firing rate over the retro window and compare to the configured `p`. Flag any ceremony whose observed rate falls outside a **±50% relative tolerance band** around `p`, computed over **≥10 ceremonies**. Below 10 samples the check abstains — too noisy to distinguish drift from Bernoulli variance.

**Why it matters.** The probabilistic trigger hook writes a `trigger-log.jsonl` row for **every** ceremony roll — fired and not-fired alike. If the hook is broken, if the queue is stalled, or if the config has drifted, the observed rate diverges from `p`. Three failure modes that look identical to downstream scorecard aggregates but have different fixes.

**Inputs.**
- `$KDIR/_scorecards/trigger-log.jsonl` — filter to rows whose `triggered_at` falls inside the retro window; group by `ceremony`.
- `~/.lore/config/settlement-config.json` — read configured `p` per ceremony.

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

**Threshold.** `|observed_rate - configured_p| / configured_p > 0.5` with `total_c ≥ 10` trips. 10-sample floor is deliberately conservative.

**When green: no prose.**

**When tripped, output (one block per tripped ceremony):**
```
[retro] pipeline-degraded: trigger realization rate
  ceremony=<type> observed=<rate> configured=<p> (band ±50%, min 10 samples)
  rolls=<total> fires=<fires> divergence=<pct>
  see: $KDIR/_scorecards/trigger-log.jsonl and ~/.lore/config/settlement-config.json
```

**Distinguished from.** Audit coverage measures whether triggered audits produced *verdicts*; trigger realization measures whether ceremonies produced *triggers*. A window can have healthy verdict flow but broken trigger rates and vice versa.

### Check: Grounding failure rate

**What it measures.** For each work item with reverse-auditor emissions in the retro window, the fraction that **failed the grounding preflight** before reaching the correctness-gate. Failures are broken down by `reason` — `file-missing | line-out-of-range | snippet-mismatch | field-missing`.

**Why it matters.** The reverse-auditor is a producer of structured evidence claims. If its emissions fail the preflight at an elevated rate, the template is **fabricating evidence pointers**. Each reason is a distinct pathology with a different fix.

**Inputs.**
- `$KDIR/_work/<slug>/audit-attempts.jsonl` — one file per work item with failed preflights; each row carries `{attempt_id, verdict_source: "reverse-auditor", reason, created_at}`.
- `$KDIR/_work/<slug>/audit-candidates.jsonl` — passed preflights. Denominator = attempts + candidates, filtered to window.

**Computation.**
```
For each work item with activity in window:
  failed   = |audit-attempts.jsonl rows with verdict_source=="reverse-auditor" and created_at ∈ window|
  passed   = |audit-candidates.jsonl rows in window|
  total    = failed + passed
  if total == 0: skip
  grounding_failure_rate = failed / total
  per_reason[r] = |failed rows with reason==r| / failed   for r in the four reasons
```

Aggregate across work items by summing numerator and denominator separately.

**Thresholds.** Trips when **either** holds:
1. Aggregate `grounding_failure_rate > 0.30` over the window with `total ≥ 10`.
2. Any single `per_reason[r] > 0.50` within a non-empty `failed` set with `failed ≥ 5`.

**When green: no prose.**

**When tripped, output:**
```
[retro] pipeline-degraded: grounding failure rate
  aggregate=<pct> (threshold 30%, N=<total>)
  per_reason: file-missing=<pct>  line-out-of-range=<pct>
              snippet-mismatch=<pct>  field-missing=<pct>
  dominant=<reason> (concentration=<pct>, threshold 50%)
  see: $KDIR/_work/<slug>/audit-attempts.jsonl (per-work-item breakdown)
```

### Check: Candidate-queue backlog

**What it measures.** For each work item with reverse-auditor activity in the retro window, the growth trend of `$KDIR/_work/<slug>/audit-candidates.jsonl`. Queue length = count of rows with `status: pending_correctness_gate`.

**Two distinct failure modes:** **growth-rate trip** (`added / max(resolved, 1) > 2.0` with `added ≥ 10`) and **absolute-size trip** (>50 pending cluster-wide at window close).

**Why it matters.** The candidate queue is the handoff from reverse-auditor to correctness-gate. Unbounded growth means reverse-auditor is *outrunning* the gate. Either the gate is not firing or it's firing but slowly. Both cases silently starve L2 commons promotion.

**Inputs.** `$KDIR/_work/<slug>/audit-candidates.jsonl` per work item.

**Computation.**
```
For each work item:
  added_w      = |rows with created_at ∈ window|
  resolved_w   = |rows whose status transitioned to gate-passed|gate-failed|retired with ts ∈ window|
  pending_w    = |rows with status == "pending_correctness_gate" at window close|

Aggregate:
  added = sum(added_w); resolved = sum(resolved_w); pending_total = sum(pending_w)
  growth_ratio = added / max(resolved, 1)
```

**Thresholds.** Trips when either: `growth_ratio > 2.0` with `added ≥ 10`; or `pending_total > 50` cluster-wide.

**When green: no prose.**

**When tripped, output:**
```
[retro] pipeline-degraded: candidate-queue backlog
  added=<N> resolved=<M> growth_ratio=<ratio> (threshold 2.0, min N=10)
  pending_total=<K> (threshold 50)
  see: $KDIR/_work/*/audit-candidates.jsonl
```

### Check: Provenance resolution rate

**What it measures.** Of the reconciliation attempts in the retro window, the fraction landing at `verified | provenance-unknown | provenance-lost`. Triggered by `provenance-unknown` share specifically.

**Why it matters.** High `provenance-unknown` means content anchors are too brittle (churn broke matching) or snippet-capture fields are underpopulated. Both fixable — first by enabling the optional token-shingle fuzzy tier, second by auditing `exact_snippet` / `symbol_anchor` capture completeness.

**Computation.**
```
total = |reconciliation attempts in window|
unknown_rate = |{verdict == "provenance-unknown"}| / total
```

**Threshold.** `unknown_rate > 0.40` trips.

**When green: no prose.**

**When tripped, output:**
```
[retro] pipeline-degraded: provenance resolution rate
  total=<N> verified=<v> provenance-unknown=<u> provenance-lost=<l>
  unknown_rate=<pct> (threshold 40%)
  tuning signal: consider enabling token-shingle fuzzy tier (same-path)
                 or audit exact_snippet/symbol_anchor capture completeness
  see: Phase 1 branch-aware reconciliation appendix
```

### Check: Judge liveness

**What it measures.** Per-judge verdict distribution. Three signatures:

1. **Gate broken** — `correctness-gate` emitting `unverified` on >80% of candidate claims.
2. **Auditor degraded** — `reverse-auditor` emitting `∅` (explicit silence) on >90% of portfolios.
3. **Zero-rows-despite-triggers** — any judge (`correctness-gate`, `curator`, `reverse-auditor`) with **zero** rows in `rows.jsonl` for the retro window *while* `trigger-log.jsonl` shows triggers firing for its role.

**Thresholds.**
- `gate_unverified_rate > 0.80` → gate-broken
- `auditor_silence_rate > 0.90` → auditor-degraded
- any judge with `rows_in_window == 0 AND triggers_fired > 0` → zero-rows-despite-triggers

**When green: no prose.**

**When tripped, output (one block per tripped signature):**
```
[retro] pipeline-degraded: judge liveness (<signature>)
  judge=<name> <metric>=<value> (threshold <pct>)
  sample=<N> window=<start>..<end>
  see: $KDIR/_scorecards/rows.jsonl (and trigger-log.jsonl for zero-rows case)
```

### Check: Calibration state surface

**What it measures.** For each judge (`correctness-gate`, `curator`, `reverse-auditor`), the current scorecard-weight state:
- `calibrated` — judge passed discrimination test; rows carry full scorecard weight.
- `calibration-pending` — calibration hasn't happened yet or is in progress; rows emit but are non-load-bearing.
- `calibration-failed` — calibration completed and failed; rows emit but advisory only.

Source of truth: each judge's calibration log.

**Why it matters.** An uncalibrated judge emits rows that look identical to calibrated rows in `rows.jsonl`. If /retro and /evolve treat those as load-bearing, the pipeline silently aggregates untrusted signal.

**Computation.**
```
for each judge J:
  state_J       = read from J's calibration log (default "calibration-pending")
  rows_J        = |{rows in window attributable to J}|
  if state_J != "calibrated" and rows_J > 0:
    tripped.append((J, state_J, rows_J))
```

**Threshold.** Any tripped tuple (uncalibrated judge with rows > 0 in the window) sets `window_state = "pipeline-degraded"`.

**When green: no prose.**

**When tripped, output (one block per tripped judge):**
```
[retro] pipeline-degraded: calibration state surface
  judge=<name> state=<calibration-pending | calibration-failed>
  rows_in_window=<N> (non-load-bearing — /retro will not count)
  reason_if_failed=<text or "n/a">
  see: <judge's calibration log path>
```

**Non-load-bearing in /retro.** When this check trips, rows from the offending judge are **excluded** from Step 3 dimension-score evidence and from the scorecard headline. They remain in `rows.jsonl` (storage is append-only), but `/retro`'s scoring must filter them out.

### Check: Consumer-contradiction routing

**NEW check** introduced by the consumer-contradiction-channel substrate. Verifies priority-routing is actually producing verdicts.

**What it measures.** Of the consumption-contradiction rows in the retro window with `dispatch_status: routed`, the fraction with a verdict landed in `rows.jsonl` (kind == "consumption-contradiction" with `status: verified` or `status: rejected`).

**Why it matters.** `consumption-contradiction-append.sh` priority-dispatches rows to `lore audit` bypassing probabilistic sampling. If routed rows never produce verdicts, the priority-routing path is broken (analogous to the zero-rows-despite-triggers Judge liveness signature).

**Inputs.**
- `$KDIR/_work/*/consumption-contradictions.jsonl` — all rows in window, group by `dispatch_status`.
- `$KDIR/_scorecards/rows.jsonl` — rows with `kind == "consumption-contradiction"` for the window.

**Computation.**
```
routed = |{contradictions in window with dispatch_status: routed}|
verdicts = |{kind==consumption-contradiction rows with status ∈ {verified, rejected} in window}|

if routed ≥ 10 and verdicts == 0:
    check trips — priority routing appears broken
if routed ≥ 10 and (verdicts / routed) < 0.10:
    check trips — routing nominally works but almost nothing is being adjudicated
```

**Threshold.** `routed ≥ 10 AND (verdicts / routed) < 0.10` trips.

**When green: no prose.**

**When tripped, output:**
```
[retro] pipeline-degraded: consumer-contradiction routing
  routed=<N>  verdicts_landed=<M>  realization=<pct> (threshold 10% at N≥10)
  see: $KDIR/_work/*/consumption-contradictions.jsonl and rows.jsonl
```

### Step 3.9: Non-compensatory scorecard headline (per template-version, tier:template only)

Complementary to Step 3's dimension scores (subjective, about knowledge delivery) and Step 3.8's pipeline-degraded state (objective, about settlement liveness). Step 3.9 computes a **`pass | weak | fail` headline per template-version** from the seven MVP scorecard metric families using **worst-dimension-wins** — never a weighted average.

**When this step runs.** Only when Step 3.8 did NOT trip `pipeline-degraded`. A degraded window's dimension scores and scorecard cells are non-evidentiary, so computing a per-template headline from them would be misleading. If `window_state == "pipeline-degraded"`, skip Step 3.9 entirely and carry `pipeline-degraded` straight through to the Step 4 journal entry and Step 6 report.

**Input filter (tier-aware).** Read `$KDIR/_scorecards/rows.jsonl`, filter strictly to rows where ALL of:

- **`tier == "template"`** — **required for headline computation.** This is the sole tier eligible for the non-compensatory headline per the canonical Tier Contract. `task-evidence`, `reusable`, `correction`, and `telemetry` rows are excluded regardless of their metric values. Legacy missing-tier rows are treated as `tier: telemetry` (excluded).
- `kind == "scored"` — `consumption-contradiction` and `telemetry` rows are excluded.
- `calibration_state == "calibrated"` — `pre-calibration` and `unknown` rows appear in evidence block for transparency but do not contribute to the headline.
- `template_version` is present in `$KDIR/_scorecards/template-registry.json` — unregistered rows render as `unregistered:<hash>` and are excluded.
- The row's retro window is NOT in the set of `pipeline-degraded` windows (reuses the same filter as `/evolve` Step 5).

**The seven MVP metric families.**

| Metric | Granularity | Template scored | Direction |
|---|---|---|---|
| `factual_precision` | claim-local | producer | higher = better |
| `curated_rate` | set-level | producer | higher = better |
| `triviality_rate` | set-level | producer | **lower = better** |
| `omission_rate` | portfolio-level | producer | **lower = better** |
| `external_confirm_rate` | claim-local | pr-self-review | higher = better |
| `observation_promotion_rate` | claim-local | producer | higher = better |
| `fidelity_verdict_*` (family: `_aligned`, `_drifted`, `_contradicts`, `_unjudgeable`) | portfolio-level | `worker` (producer) | `_aligned` higher = better; `_drifted`, `_contradicts`, `_unjudgeable` **lower = better** |

Three of the seven families are **inverted** — high values are bad: `triviality_rate`, `omission_rate`, and the `_drifted | _contradicts | _unjudgeable` members of the `fidelity_verdict_*` family.

**Attribution note (`fidelity_verdict_*`).** The `tier: template` filter is the gate; the row's `template_id` is the **worker** (the producer of the artifact being judged), not the fidelity-judge. Judge provenance rides in sidecar `verdict_source: "fidelity-judge"` and `judge_template_version` fields (per D12) — these do not affect headline aggregation.

**Per-metric thresholds (MVP — subject to tuning after early data).**

| Metric | pass (need ≥) | fail (flag if ≤) | Rationale |
|---|---|---|---|
| `factual_precision` | 0.85 | 0.65 | correctness floor |
| `curated_rate` | 0.40 | 0.20 | curator keeps ≥40% of verified candidates |
| `triviality_rate` (inverted) | ≤ 0.30 | ≥ 0.55 | curator drops <55% as trivial |
| `omission_rate` (inverted) | ≤ 0.20 | ≥ 0.45 | portfolio-level miss rate |
| `external_confirm_rate` | 0.60 | 0.35 | self-review agrees with external |
| `observation_promotion_rate` | 0.25 | 0.10 | `/remember` capture rate |
| `fidelity_verdict_contradicts` (inverted) | ≤ 0.0 | > 0.0 | any worker→plan contradiction is a `fail`; non-compensatory floor |
| `fidelity_verdict_drifted` (inverted) | ≤ 0.15 | ≥ 0.40 | scope drift rate above 40% indicates structural intent-loss |
| `fidelity_verdict_unjudgeable` (inverted) | ≤ 0.15 | ≥ 0.40 | high `unjudgeable` clusters indicate spec-quality upstream issue |
| `fidelity_verdict_aligned` | derived | derived | sum-to-one across the family on `kind: "verdict"` rows; no independent threshold |

Rows between pass and fail thresholds are `weak`. Thresholds are policy — `/evolve` should not mutate them.

**`fidelity_verdict_*` family aggregation.** Filter to `tier: template` AND `metric` matching the family. Per `(template_id, template_version)` window, sum each metric's `value` and divide by the window's row count for that metric (each row's `value ∈ {0.0, 1.0}` per Phase 4 emission contract — the four metrics sum to `sample_size` for `kind: "verdict"` rows; `kind: "exempt"` artifacts emit zero rows and do not contribute). The four resulting fractions feed the per-metric classification independently — the family participates in worst-dimension-wins as four columns, not one combined column. `fidelity_verdict_aligned` is informational (sum-to-one with the other three) and is not classified independently.

**Minimum sample for headline computation.** A metric with fewer than 10 rows aggregated over the retro window is rendered as `insufficient:<N>` and treated as `weak` for headline purposes — not `fail`, because signal is absent rather than negative. Below-sample metrics are listed separately.

**Per-template-version grouping.** Group the filtered rows by `template_version`. Compute each metric's aggregate value (mean across rows) per-template-version. Emit one headline per distinct `template_version`.

**Worst-dimension-wins combination per template_version.**
```
per_metric_classification = {pass | weak | fail | insufficient:<N>} for each of the 9 classified metrics
                            (6 original + fidelity_verdict_contradicts + _drifted + _unjudgeable;
                             fidelity_verdict_aligned is derived/informational and excluded from classification)
headline_per_template = worst(per_metric_classification)
```
- any `fail` → `fail`
- no `fail` but any `weak` (including insufficient:<N>) → `weak`
- all `pass` → `pass`

The `fidelity_verdict_*` family composes naturally — its three classified members participate as additional columns under the same worst-dimension-wins rule with no bespoke branching.

**Never a weighted average.** Load-bearing: a weighted average would let high scores on one metric compensate for low scores on another, exactly the failure mode the non-compensatory headline exists to prevent. A template with perfect factual_precision (0.95) and terrible omission_rate (0.60) is `fail`, not `weak-but-close-to-pass`.

**Report shape (per template-version).**
```
[retro] Scorecard headline — per template-version (non-compensatory, tier:template only)

  <template_id>@<version-prefix-12>        HEADLINE=<pass|weak|fail>
    factual_precision:            <val>    [<pass|weak|fail|insufficient:<N>>]  n=<N>
    curated_rate:                 <val>    [<pass|weak|fail|insufficient:<N>>]  n=<N>
    triviality_rate:              <val>    [<pass|weak|fail|insufficient:<N>>]  n=<N>
    omission_rate:                <val>    [<pass|weak|fail|insufficient:<N>>]  n=<N>
    external_confirm_rate:        <val>    [<pass|weak|fail|insufficient:<N>>]  n=<N>
    observation_promotion_rate:   <val>    [<pass|weak|fail|insufficient:<N>>]  n=<N>
    fidelity_verdict_contradicts: <val>    [<pass|weak|fail|insufficient:<N>>]  n=<N>
    fidelity_verdict_drifted:     <val>    [<pass|weak|fail|insufficient:<N>>]  n=<N>
    fidelity_verdict_unjudgeable: <val>    [<pass|weak|fail|insufficient:<N>>]  n=<N>
    fidelity_verdict_aligned:     <val>    [derived]                            n=<N>
    worst: <metric-that-set-headline>
    unregistered/pre-calibration/degraded-window/wrong-tier rows excluded: <count>
```

One such block per distinct registered `template_version` with tier:template rows in the window. If the filter produces zero eligible rows for every template, render `[retro] Scorecard headline: no eligible rows (all-filtered)` — a condition adjacent to `pipeline-degraded`.

If the `tier: template` row count is below the 10-sample floor on every metric, emit:
```
[retro] Scorecard headline: warmup — awaiting-template-tier-rows
  tier:template rows in window: <N> (below n≥10 minimum for all metrics)
  /evolve runs proceed; individual metrics show insufficient:<N> until sample accumulates.
```

**Journal persistence.** The headline goes into the retro journal entry (Step 4) under a `scorecard_headline` field in `--scores`:
```json
{
  "scorecard_headline": {
    "<template_id>@<version>": "pass",
    "<template_id>@<version-2>": "fail"
  }
}
```

So `/evolve` can read per-template state without re-running Step 3.9. `/evolve` ranks templates by harmonic mean for mutation prioritization (per plan). Headline and harmonic-mean ranking are distinct — headline is the pass/weak/fail gate; harmonic mean orders within a failing set.

**Invariant.** `/evolve` reads `scorecard_headline` to gate template mutations: a `fail` template can be edited from evidence in the current window (if it also passes the Step 5 citation gate); a `pass` template should not be edited from this window absent a specific failing-metric citation; a `weak` template is editable but deprioritized. `/evolve` does not re-derive these verdicts.

### Step 3.95: Fidelity Response Behavior (telemetry-only)

**Observability only — `kind: telemetry` rows; MUST NOT feed `/evolve` and MUST NOT contribute to the Step 3.9 non-compensatory headline.** This section consumes the four `fidelity_*` telemetry families W06 emits from `/implement` Step 4.1 branch handlers. They describe how the lead is *responding* to fidelity verdicts (which branches they pick, whether respawned workers converge, how often the override budget trips, how `unjudgeable` verdicts resolve) — not whether the worker output was correct. The `/evolve` `tier: template` filter (Step 5) excludes these rows structurally; this is the same anti-coupling invariant as Step 3.5 (P2.3-16), and it applies for the same reason: response observability informs operator situational awareness about whether the forced-branch mechanism (D1 + D5 + D6) is doing real work, but mixing response telemetry into producer-template scoring would Goodhart the headline.

**Source.** Read `$KDIR/_scorecards/rows.jsonl` filtered to rows where ALL of:
- `kind == "telemetry"`, `tier == "telemetry"` (legacy missing-tier rows are also telemetry per the canonical Tier Contract)
- `metric` matches one of the four `fidelity_*` telemetry families below
- The row's `source_artifact_ids` reference fidelity artifacts within the current work item (cross-work-item aggregation is forbidden — response patterns are work-item-local)

When a metric has zero rows in the window, emit `<metric>: no data in window` and continue. Do not treat absence as a failure.

#### Render order — warning-pattern flags FIRST, distributions AFTER

Three warning-pattern flags surface at the top of the section, before any distribution detail. Each is a single line citing the phase, the value that tripped the threshold, and a short rationale tag. Thresholds are policy constants — Phase 5 eval may tune them, but `/evolve` MUST NOT mutate them.

| Flag | Threshold | Why this fires |
|---|---|---|
| `HIGH_AMEND_RATE` | Per phase: `count(fidelity_branch_choice == "amend" AND verdict ∈ {drifted, contradicts}) / count(verdict ∈ {drifted, contradicts}) > 0.60` | Lead is rationalizing drift via amendment instead of correcting via respawn — D6's override-budget mechanism is being soft-bypassed. |
| `LOW_RESPAWN_EFFECTIVENESS` | Per phase: `count(fidelity_respawn_outcome == "resolved_aligned") / (count("resolved_aligned") + count("persistent_drift")) < 0.50` | Correction feedback loop is broken; respawned workers aren't converging on the corrected intent. |
| `UNJUDGEABLE_CLUSTER` | ≥ 2 `unjudgeable` fidelity artifacts in the work item that share a task shape — file-path prefix overlap OR phase-objective token overlap ≥ 40%. | `/spec` task-contract quality is systematically insufficient — D3's upstream surface is firing. |

Render the warnings as one-liners:

```
[fidelity-response] warning flags
  [HIGH_AMEND_RATE] Phase 3: amend-rate 73% on drifted verdicts (8/11)
  [LOW_RESPAWN_EFFECTIVENESS] Phase 4: 2/5 respawns resolved aligned (40%)
  [UNJUDGEABLE_CLUSTER] 3 unjudgeable verdicts share `agents/*` file-path prefix
```

If no warnings fire, emit a single confirmation line:

```
[fidelity-response] warning flags: no response-pattern anomalies detected
```

After warnings, render the five distributions in the order below. Each distribution is its own block; missing data renders as `no data in window`.

##### (a) Verdict distribution by trigger source

**Source:** read `_fidelity/<artifact-key>.json` artifacts within the work item; group by the artifact's `trigger` field (per W06 D7 sampling policy — set in `/implement` Step 4.1).

```
verdict_distribution_by_trigger:
  mandatory:phase_deliverable        aligned=<N>  drifted=<N>  contradicts=<N>  unjudgeable=<N>
  mandatory:architectural            aligned=<N>  drifted=<N>  contradicts=<N>  unjudgeable=<N>
  mandatory:retried                  aligned=<N>  drifted=<N>  contradicts=<N>  unjudgeable=<N>
  mandatory:risk_keyword             aligned=<N>  drifted=<N>  contradicts=<N>  unjudgeable=<N>
  mandatory:overlapping_file         aligned=<N>  drifted=<N>  contradicts=<N>  unjudgeable=<N>
  sampled:within_phase_random        aligned=<N>  drifted=<N>  contradicts=<N>  unjudgeable=<N>
```

##### (b) Branch-choice distribution

**Source:** rows where `metric == "fidelity_branch_choice"`. Each row's `value_label ∈ {"respawn", "amend", "escalate", "clarify_rerun"}`. Group by the originating verdict (carried in the row's sidecar fields per Phase 6 emission contract).

```
fidelity_branch_choice:
  drifted:        respawn=<N> (<pct>%)  amend=<N> (<pct>%)  escalate=<N> (<pct>%)
  contradicts:    respawn=<N> (<pct>%)  amend=<N> (<pct>%)  escalate=<N> (<pct>%)
  unjudgeable:    clarify_rerun=<N> (<pct>%)  escalate=<N> (<pct>%)
```

##### (c) Respawn effectiveness

**Source:** rows where `metric == "fidelity_respawn_outcome"`. Each row's `value_label ∈ {"resolved_aligned", "persistent_drift", "respawn_failed"}`. Group by phase.

```
fidelity_respawn_outcome:
  Phase <N>: effectiveness=<pct>% (resolved=<R>/<R+P>; respawn_failed=<F> separately)
  Phase <N>: ...
```

Effectiveness is `resolved_aligned / (resolved_aligned + persistent_drift)`. `respawn_failed` is reported as a separate count, not folded into the effectiveness denominator (a failed respawn is a control-flow event, not a correction outcome).

##### (d) Override-budget activations

**Source:** rows where `metric == "fidelity_override_count"`. Each row's `value_label ∈ {"second_opinion", "user_escalation"}` and fires only when D6's per-phase budget (≥3 amendments) is hit. Group by phase.

```
fidelity_override_count:
  Phase <N>: budget tripped <K> times — second_opinion=<X>  user_escalation=<Y>
  Phase <N>: budget not tripped (amendments=<M> < 3 threshold)
```

##### (e) Unjudgeable resolution mode

**Source:** rows where `metric == "fidelity_unjudgeable_resolution_mode"`. Each row's `value_label ∈ {"spec_clarified_resolved", "spec_clarified_persistent", "user_escalated"}`. This complements (and is the resolution-side counterpart to) the `UNJUDGEABLE_CLUSTER` warning above.

```
fidelity_unjudgeable_resolution_mode:
  spec_clarified_resolved:    <N> (<pct>%)
  spec_clarified_persistent:  <N> (<pct>%)
  user_escalated:             <N> (<pct>%)
```

A high `spec_clarified_persistent` rate alongside `UNJUDGEABLE_CLUSTER` flags is the strong signal that `/spec` template quality — not the worker — is the upstream cause.

**Step 3.95 invariant — telemetry-only.** Every row this section reads carries `kind: telemetry` AND `tier: telemetry`. Such rows MUST NOT inject into producer prompts and MUST NOT feed `/evolve`'s template-mutation citation gate. The `/evolve` Step 5 `tier: template` filter is what enforces the anti-coupling structurally; this section's renderings are operator-facing only. Cross-phase aggregation is within the current work item only — never mix response patterns across work items.

### Step 4: Write Journal Entry (retro dimension scores)

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

Dimension scores are still written (for trend analysis) but the headline prose leads with `pipeline-degraded`. The `window_state` + `tripped_checks` fields make the degraded status queryable by `/evolve`.

**When `window_state != "pipeline-degraded"` (normal window):**

```bash
lore journal write \
  --observation "Delivery: X/5 | Quality: X/5 | Gaps: X/5 | Alignment: X/5 | Spec Utility: X/5. Key finding: <one sentence>. Most actionable gap: <specific gap>." \
  --context "retro: <slug>" \
  --work-item "<slug>" \
  --role "retro" \
  --scores '{"d1_delivery": X, "d2_quality": X, "d3_gaps": X, "d4_alignment": X, "d5_spec_utility": X, "scorecard_headline": {"<template_id>@<version>": "pass|weak|fail", ...}, "scorecard_deltas": {"template": {...}, "correction": {...}, "reusable": {...}, "task-evidence": {...}}}'
```

### Step 4a: Behavioral-health journal entry

**Mandatory when Step 3.7 ran.** Persists the rotation selection and answers into the journal so tuning has a queryable trail. Separate entry (distinct `--role`) so longitudinal queries filter cleanly from dimension-score entries.

```bash
lore journal write \
  --observation "Checks: <C1,C4,C5,C7> | C1: <1–3 sentence answer> | C4: <answer> | C5: <answer> | C7: <answer>" \
  --context "retro-behavioral-health: <slug>" \
  --work-item "<slug>" \
  --role "retro-behavioral-health"
```

`Checks:` lists the 4 selected check numbers (3 random from 1–6 plus Check 7). One `C<n>: <answer>` segment per selected check, in numeric order. No score fields.

### Four journal roles — load-bearing

The /retro ceremony emits **four distinct journal roles** across Steps 2.8d, 4, 4a, and 5:

| `--role` | Purpose | Reader |
|---|---|---|
| `retro` | Dimension scores + scorecard headline + deltas | longitudinal analysis, /evolve (delta + headline only) |
| `retro-behavioral-health` | Qualitative drift-mode checks (rotated) | tuning cadence, longitudinal analysis |
| `retro-escalations` | Escalation telemetry per work item | plan-level remediation, never /evolve |
| `retro-evolution` | Evolution suggestions (Step 5) | /evolve Step 3 (CC-05 closed loop) |

**Do NOT collapse these roles into one.** Each consumer filters by role — /evolve reads exclusively `retro-evolution` + `self-test-evolution`; tuning reads exclusively `retro-behavioral-health`. Collapsing forces consumers to demux by observation prose, which is fragile and silently breaks when prose format changes.

### Step 5: Log Evolution Suggestions (CC-05 closed loop)

**Mandatory.** At least one per retro. Log to journal — do NOT edit files directly. `/evolve` applies batched suggestions.

Watch for: ceiling dimensions (5/5 for 2+ retros), new failure modes, dead dimensions (stuck at 3), evidence quality gaps, tier:template scorecard regressions.

```bash
lore journal write \
  --observation "Target: <file> | Change type: <ceiling/new-failure-mode/dead-dimension/evidence-gap/template-regression> | Section: <section> | Suggestion: <specific change> | Evidence: <retro finding>" \
  --context "retro-evolution: <slug>" \
  --work-item "<slug>" \
  --role "retro-evolution"
```

One entry per suggestion. 2-4 sentences each.

**CC-05 closed loop invariant.** `/retro` → `lore journal write --role retro-evolution` → `/evolve` Step 3 reads exclusively this role (and `self-test-evolution`) → `/evolve` applies edits → `/evolve` Step 7.5 bumps template-version → next `/retro` A/B compares pre/post.

**`/retro` never edits files directly.** The only mutation path is via journal entries that `/evolve` reads. If a future /retro step proposes a direct file edit, it has broken the closed loop — reject the change.

### Step 6: Report

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

Scorecard-first shape: delta surface + headline first, dimension scores relegated to narrative coda.

```
[retro] <slug>

  # Primary: scorecard deltas (Step 3.0), partitioned by tier
  Scorecard deltas — window <current-window-id> vs <previous-window-id>

    --- tier: template ---
    <template_id>@<version-prefix-12>:
      <metric>: <prev> → <curr>  (<direction> <signed delta>, n=<N>)  [<classification change>]
      ...
    Suppressed: <N> (below-sample / below-magnitude / unregistered)

    --- tier: correction ---
    <template_id>@<version-prefix-12>:
      <metric>: <prev> → <curr>  ...
    --- tier: reusable ---
    (informational)
    --- tier: task-evidence ---
    (informational)

  # Headline: non-compensatory pass|weak|fail per template-version (Step 3.9, tier:template only)
  Scorecard headline (non-compensatory, worst-dimension-wins, tier:template):
    <template_id>@<version-prefix-12>  HEADLINE=<pass|weak|fail>
      worst metric: <metric>
    <template_id-2>@<version-prefix-12>  HEADLINE=<pass|weak|fail>
      worst metric: <metric>

  # Narrative coda: dimension scores (Step 3)
  Narrative coda (dimension scores, not headline):
    Delivery: X/5 | Quality: X/5 | Gaps: X/5 | Alignment: X/5 | Spec Utility: X/5
    Key finding: <one sentence on the knowledge-system behavior this cycle>
    Disagreement with scorecard headline? <none | brief note>

  ## Memory System Telemetry (Step 3.5 — observability only, does not feed /evolve)

  retention_after_renormalize:
    median cycles_survived: <N>  |  entries with ≥3 cycles: <K>/<total>
    top survivors: <entry_id> cycles=<N> | ...

  downstream_adoption_rate:
    mean rate: <val>  |  entries >50%: <K>/<total>
    top adopters: <entry_id> rate=<val> status=<status> | ...

  route_precision:
    <role>: <accepted>/<total> (<pct>%)  |  ...

  supersession_quality:
    improved: <K>/<total>  |  neutral: <N>  |  regressed: <M>
    notable (non-improved): ...  (or "all improved")

  scale_drift_rate: <role>: drift=<val> [ABOVE-THRESHOLD if >0.20]  |  ...

  label_revision_rate: <scale_id>: rate=<val> [DESIGN-FLAG if flagged]  |  ...

  scale_access_appropriateness:
    abstraction: <grade>  — <rationale>
    recall: <grade>  — <rationale>

  channel-contract flags: <none | one line per flag>

  # Scale access (Step 2.9)
  Scale access: abstraction=<grade> | recall=<grade>
    abstraction: <one-line rationale>
    recall: <one-line rationale>

  # Channel-contract flags (Step 2b.6) — omit when no flags fired
  Channel-contract drift detected:
    <role>/<slot>  signal=<signal_type>  rate=<pct> over <N> cycles
      Remedy: <one-line targeting workflow contract, not individual producers>

  # Behavioral-health coda (Step 3.7)
  <4 selected checks + answers — 1-3 sentences each>

  Evolution suggestions logged: N (run /evolve to apply)
```

**Section order is load-bearing.** The delta surface leads because it is the actionable signal. The headline follows because it is the settlement verdict. Dimension scores come last because they're longitudinal context, not primary signal. Reversing this order would re-establish the dimension-score-as-headline pattern that was explicitly retired.

**First-retro / zero-delta-window case.** If Step 3.0 reported "first eligible window — no delta baseline", skip the delta block and lead with the headline block. The narrative coda still appears at the end.

**Warm-up case.** If Step 3.9 reported `warmup: awaiting-template-tier-rows`, the headline block shows the warm-up line and individual metrics' `insufficient:<N>` status. The rest of the report (deltas, dimension scores, telemetry, behavioral-health) runs normally.
