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

1. **Steps 1–2.6**: setup, evidence gathering. Run unconditionally. Commons audit is no longer dispatched here — promotions enqueue a `commons` settlement audit at write time, so `/retro` reads settlement health (Step 3.8) rather than backfilling coverage reactively. Step 3.8's routing-realization check reads the settlement substrate (`_settlement/queue.json` + `runs/`) directly and is independent of any earlier scorecard read.
2. **Step 2.8**: escalation telemetry. Non-scored, feeds retro prose only.
3. **Step 2.9**: scale signal block. Six factual + eval signals (declaration_coverage, redeclare_rate, off_scale_routes_emitted, verifier_disagreements, off_altitude_skipped, counterfactual_better) emitted as sidecar row to `retro-scale-access.jsonl` plus three "better than no scale" derivations. Runs unconditionally alongside Step 2.8; never affects `pipeline-degraded` state.
4. **Step 3.8** (settlement pipeline health checks): **runs before** any scorecard-consumption step. Sets `window_state = "pipeline-degraded" | "warmup" | normal`. If degraded, Steps 3.0/3.9 skip.
5. **Step 3.0** (scorecard delta surface, *primary*): tier-partitioned. Runs only on normal windows. Skipped on `pipeline-degraded`.
6. **Step 3** (dimension scores): demoted to narrative coda. Always scored for longitudinal trend, never the headline.
7. **Step 3.5** (memory system telemetry) + **Step 3.5a** (judgment-class routing attribution): read `kind`/`tier: telemetry` rows + sidecars; observability only, **never feed `/evolve`**. Run on all windows.
8. **Step 3.6–3.7**: scorecard forward guidance + behavioral-health — coda/diagnostic.
9. **Step 3.9** (non-compensatory headline): filters `tier: template` only. Runs only on normal windows. Skipped on `pipeline-degraded`.
10. **Steps 4–6**: journal persistence, evolution suggestions, operator-facing report. Branch on `window_state` so `pipeline-degraded` never surfaces a pass/weak/fail headline.

**Phase 7b (health checks at Step 3.8) ships alongside Phase 7 (scorecard consumption at 3.0/3.9)** — they share no schema but interlock: 3.8 gates the evidentiary status of the window; 3.0 and 3.9 refuse to read a degraded window. Editing either section must preserve the `pipeline-degraded` short-circuit in the downstream consumers (Steps 3.0, 3.9, 4, 6).

## Tier-aware reading (canonical contract)

/retro is a **tier-aware reader** of `rows.jsonl`. The tier enum values and their /retro semantics are:

| `tier` | /retro treatment |
|---|---|
| `task-evidence` | Step 3.0 delta surface emits a tier-partitioned view; never contributes to Step 3.9 headline. |
| `reusable` | Step 3.0 delta surface; never Step 3.9 headline. |
| `correction` | Step 3.0 delta surface. May factor into /evolve secondary doctrine-correction gate (see `skills/evolve/SKILL.md` Step 5). Also read observationally by Step 3.5a as a work-item rework overlay. No Step 3.9 headline weight. |
| `template` | Step 3.0 delta surface + **Step 3.9 non-compensatory headline** (sole headline-eligible tier). Feeds /evolve primary template-mutation gate. |
| `telemetry` | Step 3.5 memory-system telemetry + Step 3.5a judgment-class routing attribution **only**. Never Step 3.0/3.9. Never /evolve. P2.3-16 anti-coupling invariant. |

**Missing-tier legacy policy.** Rows written before the tier enum extension have no `tier` field. Readers MUST treat missing `tier` as `tier: telemetry` (safest default — non-evidentiary for /evolve; visible in Step 3.5 but excluded from template-behavior headline).

**Post-migration warm-up.** Immediately after the tier substrate migration lands, `rows.jsonl` will contain many pre-migration rows (all mapped to `tier: telemetry`) and few `tier: template` rows. If the `tier: template` row count is below the Step 3.9 sample-size minimum (n ≥ 10) in the current window, Step 3.8 reports `warmup: awaiting-template-tier-rows` — a distinct state from `pipeline-degraded`. Warm-up is informational; it does NOT gate /evolve runs. The warm-up state clears as soon as enough new-tier rows accumulate.

### Step 1: Resolve Work Item

```bash
lore resolve
```

Set `KNOWLEDGE_DIR` to result, `WORK_DIR` to `$KNOWLEDGE_DIR/_work`.

**Where a cycle comes from.** The retro-sampling gate (`scripts/retro-sampling-gate.sh`, consulted at the spec-finalize and impl-close termini) decides per cycle whether a retro is *due now* (surfaced to the operator) or *deferred* to a batch. Sampled-out cycles are recorded — never silence — as rows in `$KNOWLEDGE_DIR/_scorecards/retro-deferred-queue.jsonl` (outcome vocabulary `done | deferred | skipped`, the coordinate ledger's grammar). A deferred-batch retro run resolves its cycles from that queue; the gate itself neither runs nor blocks `/retro`.

1. Resolve the argument to a canonical slug via `lore work resolve`:
   ```bash
   if RESULT=$(lore work resolve "$ARG" --branch "$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"); then
     SLUG=$(printf '%s' "$RESULT" | sed -n '1p')
     ARCHIVED=$(printf '%s' "$RESULT" | sed -n '2p')
   else
     case $? in
       1) ;;  # no match → fall through to step 3 (branch inference) or step 4 (ask user)
       2) echo "Multiple work items match '$ARG' (candidates on stderr above)." >&2; exit 1 ;;
     esac
   fi
   ```
   `/retro` is read-only — surface `ARCHIVED=true` items silently with an `[archived]` tag; no confirmation prompt.
2. Load `plan.md`, `notes.md`, `_meta.json` from `$WORK_DIR/<slug>/` (or `_archive/<slug>/` if `ARCHIVED=true`).
3. No argument → invoke `lore work resolve` with the current git branch (passing the branch as `--branch`); when only branch inference is needed, pass the literal ref `recent` to fall back to most-recent active item.
4. No match → ask user.

Report: `[retro] Evaluating: <title> (<slug>) [archived]`

### Step 2: Gather Evidence

Read existing artifacts only. No new exploration needed.

**Work cycle type:** Detect implementation (has `tasks.json`/`/implement` entries), review/research (no workers), or spec-short (`/spec short` — single-agent, no workers). Affects D1 and D4 scoring — spec-short scores D1 as "setup quality" for future workers.

### 2a: Worker observations

Primary source: **`execution-log.md`** if it exists — per-task entries with Changes, Observations, and test results. Secondary: worker SendMessage reports in conversation context. Cross-session fallback: `notes.md` session entries. Review-only: check subagent launches and knowledge preambles. When both exist: execution-log for task-level decisions; notes.md for session-level context (blockers, cross-task synthesis).

**Evidence anomaly screen:** before scoring, scan execution-log for anomalies that degrade evidence and signal lead-orchestration gaps: duplicate task subjects with near-identical Changes (worker task race), `pending worker report` placeholder observations (premature logging), and multi-task batched entries (per-task sequence lost). Note each in the evidence block and treat affected entries as degraded — they feed the narrative, never silently into dimension scores. Also classify the cycle: code vs prose/protocol editing — code-centric criteria (out-of-scope reads, wrong-path exploration) mis-fit prose cycles; read those through the low-diagnostic lens.
<!-- Sunset: remove if retro-evolution rows targeting skills/retro/SKILL.md change-type evidence-gap citing execution-log anomalies or prose-cycle misfit recur from ≥3 new distinct work items within the next 20 retro cycles. -->

### 2b: Knowledge delivery audit

1. Read `plan.md`; extract `**Knowledge context:**` blocks per phase.
2. Check delivery mode per phase (`**Knowledge delivery:** full` vs annotation-only default).
3. **Zero-context-block check:** if 0/N phases have context blocks, check via `lore search` whether relevant entries existed. See `failure-modes.md` "Plan-level context block omission".
4. **Delivery mode mismatch:** for `full` phases, verify tasks.json matches — plan says full but tasks.json has annotation-only = pipeline failure, D1 ≤ 3.
5. **Backlink resolution rate:** count resolved vs unresolved in `## Prior Knowledge`. >30% unresolved caps D1 at 2.
6. **Annotation completeness:** for annotation-only phases, count entries with vs without annotation text. >40% empty caps D1 at 3. Subtract `## Related`-sourced bare entries and `_work/` paths from denominator (see `failure-modes.md`).
7. **Prefetch hit rate (spec-only):** useful vs empty results. <40% → disambiguate coverage gap vs query recall failure.

### 2b.5: Surfaced concerns (off-scale routing)

Check for worker-surfaced concerns routed during implementation: `KDIR=$(lore resolve); SC_FILE="$KDIR/_work/<slug>/surfaced_concerns.jsonl"; [ -f "$SC_FILE" ] && cat "$SC_FILE"`.

If non-empty, read each entry. For each concern: **count** them in the evidence summary; **assess disposition** — were they addressed in the work? Check plan.md Design Decisions and Open Questions for matching content; **feed D3 scoring** (Knowledge Capture & Propagation) — unaddressed concerns that reveal genuine gaps in the plan's scope inform D3 since workers shouldn't need to route off-scale for concerns a well-scoped plan would have anticipated; **do not re-resolve them here** — report presence and disposition as evidence; resolution is a spec-lead or follow-on spec decision.

### 2b.6: Channel-contract review loop

Aggregate channel-shopping signals per role × slot over the last 5 retro cycles (or all available cycles if fewer than 5 exist). Three signal types:

- **`under_routing`** — off-scale concerns workers routed that, in retrospect, should have been emitted as captures. Inferred from `surfaced_concerns.jsonl` entries later addressed inline (`accepted-one-shot`) rather than resolved via follow-on or knowledge promotion. High rate = workers routing things off-scale the channel contract should have told them to capture directly.
- **`over_capture`** — captures that should have been off-scale routes. Inferred from knowledge entries later corrected (`corrections[]` within 2 cycles) or off-scale routes resolved as `declined` by the lead. High rate = workers capturing speculative/architectural content as settled knowledge.
- **`evidence_only_durable`** — worker reports where Investigation or Tests carry durable architectural claims never promoted. Heuristic: execution-log entries with declarative architectural language ("X always does Y", "the invariant is", "every Z must") in Investigation/Tests with no corresponding `lore capture` in the session.

**Computation (per role × slot, over last N cycles up to 5):** for each signal_type in `{under_routing, over_capture, evidence_only_durable}`, compute `rate = numerator/denominator` where numerator = count of outputs in that role×slot matching the signal heuristic, denominator = total outputs in that role×slot in the window (skip if denominator == 0).

**Threshold:** rate > 0.30 over at least 3 cycles fires a flag. Below 3 cycles is too noisy to attribute to systematic drift vs one-cycle variance.

**When a flag fires**, emit a sidecar row — read `skills/retro/templates/emit-commands.md` § "Step 2b.6 — Channel-contract flag emit" for the `retro-channel-flag-append.sh` invocation. The script writes to `$KDIR/_scorecards/retro-channel-flags.jsonl`. One row per flagged role × slot per retro cycle.

**Remedy narrative (when flags fire):** Add a prose paragraph to the retro narrative (Step 6) naming the role × slot, signal type, rate, and a proposed remedy. Remedies target the **workflow contract**, not the individual producer. Remedy heuristics: `under_routing` — add a worked example of this slot's capture threshold to the channel-contract matrix, or lower the capture bar for this role × slot; `over_capture` — add an ingestion warning that speculative claims in this slot should be routed off-scale, or raise the capture confidence threshold; `evidence_only_durable` — add a protocol step that requires workers to decide capture-vs-route for declarative claims before closing a task.

**When no flags fire: no prose.** Per the healthy-case silence invariant (same rationale as Step 3.8 health checks). Channel-contract drift is only notable when it crosses the threshold.

**Invariant.** This step never calls `scorecard-append`. The `retro_flag` sidecar rows are NOT settlement signal — they are qualitative drift indicators. Routing them through `rows.jsonl` would expose them to `/evolve` consumption and create a scoring incentive to suppress flags.

### 2b.7: Consumption-contradiction evidence

**Invariant — canonical contradiction vocabulary.** The canonical lifecycle trio is `routed | verified | rejected` and future edits to this section MUST preserve it verbatim:

- The lifecycle `status` field for a consumption-contradiction row is exactly the trio `routed | verified | rejected` — no other value is canonical.
- The `dispatch_status` field is orthogonal and takes only the literal `routed`, set when `consumption-contradiction-append.sh` priority-dispatches to `lore audit`. `status: routed` (lifecycle, "awaiting verdict") and `dispatch_status: routed` (dispatch, "priority-audit was triggered") are independent — do not collapse them.
- Drift = any row whose `status` is not in the `routed | verified | rejected` trio (e.g. legacy producer enums like `pending`, `accepted`, `declined`, `remediated` leaking into the consumer side); detect with `jq -r '.status' $KDIR/_work/*/consumption-contradictions.jsonl | sort -u` and assert the output is a subset of `{routed, verified, rejected}`.
- Any value outside `routed | verified | rejected` silently silences the Step 3.0 `contradiction_verification_rate` gate (numerator counts only `verified`; denominator counts only `verified | rejected`) even when producer enums are correct, so prose changes that paraphrase the trio's spelling or order break the read-side invariant the gate depends on.

New evidence class introduced by the consumer-contradiction-channel substrate. Consumer contradictions are **observational** signals — a reader (worker, spec-lead, implement-lead) prefetched a commons entry and observed it is false in the context of their current work. They are a distinct evidence class from the adjudicative three-judge pipeline.

**Enumerate `$KDIR/_work/<slug>/consumption-contradictions.jsonl`** across work items with activity in the retro window. Each row carries: `contradiction_id` (slug-form identifier unique per work item), `claim_id` (commons-entry claim being contradicted), `corrected_entry_path` (the entry the contradiction targets), `template_id` / `template_version` (the template that produced the contradicted entry, for attribution), `status` — `routed | verified | rejected` (lifecycle state from correctness-gate audit), `verified_by_verdict_id` (present when `status=verified`; the settlement record id), `dispatch_status` — `routed` when `consumption-contradiction-append.sh` priority-dispatched to `lore audit`, `captured_at_sha`, `observed_at`.

Count rows by status: `routed`, `verified`, `rejected`. Report shape: `Consumption contradictions: N total (R routed to audit, V verified, J rejected)` plus a `pending verdict (routed, no verdict yet): <P>` indented line. The `verified` count feeds Step 3.0 `contradiction_verification_rate` and Step 3.8 consumer-contradiction routing health. The `routed` set is already priority-dispatched to `lore audit` by `consumption-contradiction-append.sh` — a distinct channel from the proactive `commons` settlement audit enqueued at promotion time.

### 2c–2e: Logs

Read three logs filtered to the work period: session entries from `notes.md` `## YYYY-MM-DD` blocks (empty = degraded evidence); retrieval log at `$KNOWLEDGE_DIR/_meta/retrieval-log.jsonl`; friction log at `$KNOWLEDGE_DIR/_meta/friction-log.jsonl`. Also read packet assessments at `$KNOWLEDGE_DIR/_packets/assessments.jsonl` filtered by `assessed_at` to the work period — cite matching `packet_id` + verdict class as D2 evidence (`unused`, `harmful`) and D3 evidence (`missing`, `unattributed_retrieval`).

### 2c.6: Review-gate audit (`_sessions/events.jsonl`)

A fourth windowed log read — the review-mechanism audit (contract: `docs/review-gates.md` § "Audit semantics"). Read the four review events (`review_flagged`, `review_held`, `review_notified`, `review_released`) from `$KNOWLEDGE_DIR/_sessions/events.jsonl`, filtered to the work period by each row's `ts`. **Re-read the journal at authoring time** — compute these figures fresh when writing the journal entry (Step 4), never inheriting a count captured in an earlier step. `events.jsonl` is append-only and continuously written, so a snapshot taken earlier in the cycle can undercount within the same cycle even when the direction holds.

Three signals:

- **Dwell** — for each gate-open row (`review_flagged` / `review_held`), join its `event_id` to the `gate_id` field of the matching `review_released` row and compute `dwell = review_released.ts − gate_open.ts`. Report the dwell distribution. A gate still open at retro time (no matching release in the window) has no dwell — it counts under flag-pileup, not as zero dwell.
- **Rubber-stamp signal** — near-zero dwell on `review_held` gates. A hold cleared almost immediately after it opened is a comprehension checkpoint that was skipped, not honored — the qualitative inverse of the gate's purpose.
- **Flag-pileup** — the count of currently-gated items, read from `_index.json` `plans[].review` (mechanism present), not from the journal. A rising backlog of unreleased gates means flags are accumulating unread.

**Routing.** Findings land as **journal-entry evidence** — folded into the retro journal entry (Step 4) and cited in the Step 6 narrative, the same off-band destination the escalation (Step 2.8) and scale-signal (Step 2.9) surfaces use. A rubber-stamp or pileup finding that is an actionable, recurring drift (not one-cycle variance) is a qualitative drift indicator of the same class as the Step 2b.6 `retro_flag` rows; route it to that sidecar (`$KDIR/_scorecards/retro-channel-flags.jsonl`). Its signal-type enum currently carries only the channel-contract types (`under_routing|over_capture|evidence_only_durable`), so a review-gate signal type is the extension point in `retro-channel-flag-append.sh` when mechanical emission is wanted. Either way, propose the remedy in the Step 6 narrative and target the gate *policy* — which mechanism per step, packet-authoring discipline, owned by `/coordinate` — never an individual producer.

**Invariant.** This step never calls `scorecard-append`. Dwell and rubber-stamp figures are precisely "tuning signal, not surveillance": routing them through `rows.jsonl` would expose them to `/evolve` consumption and create a scoring incentive to *suppress* gates — the exact failure the review mechanism exists to prevent. Same off-band rationale as Step 2b.6's `retro_flag` invariant and Steps 2.8 / 2.9.

**Selective-run posture.** This read-path is batch, windowed, and artifact-fed — it runs when the operator runs `/retro`, and nothing about the review mechanism requires `/retro` to run per-gate. A release is observable in the `_meta.json` review block and the journal whether or not a retro ever reads it.

**Named experiment (archive-directive review trigger).** `docs/review-gates.md` § "Named experiment" ships the "done = work-complete AND comprehension-complete" archive-blocking change with an explicit review trigger: after ~5 releases **or** 4 weeks of first use (whichever comes first), a `/retro` run evaluates this surface — did flags actually get read (the dwell distribution) and did the active list stay signal-rich (the flag-pileup trend). When that trigger window has elapsed, name the evaluation in the retro narrative; if flags are piling up unread, the archive-blocking directive is what to revisit, not the metric.

**When no review events fall in the window: no prose** — the healthy-case silence invariant (same as Steps 2b.6 / 2.8 / 2.9).

### 2f: Token efficiency

Annotation-only: wrong-path explorations prevented, first-attempt accuracy gains. Full-resolution: file reads replaced (~500-3000 tokens/file).

Emit a one-block `[retro] Evidence gathered:` report covering worker observations (N tasks), context blocks (N phases, M/K resolved), surfaced concerns (N entries, M addressed / K pending), consumption contradictions (N total, R routed, V verified, J rejected), sessions (N entries), retrieval/friction events (N each), and a token-savings estimate (~Nk). When review events fell in the window (Step 2c.6), add `review gates: N released (median dwell D), P still gated` — omit the clause entirely when none did, per the silence invariant.

**Historical-unaudited commons coverage line.** Also include one line: `historical-unaudited (outside settlement coverage): <H>` — the count of commons entries with `confidence: unaudited` frontmatter that have **no** corresponding `commons` queue entry in `$KNOWLEDGE_DIR/_settlement/queue.json` (never enqueued by the forward loop). This is the honesty companion to Step 3.8's forward-settlement coverage ratio: the ratio measures forward coverage only, so this standalone count keeps the operator from reading a clean ratio as whole-store coverage. It is evidence context, not a health-check trip — these entries are out of scope for the forward loop (Design Decision D6) and are surfaced here precisely so the silent-when-green Step 3.8 check need not break its invariant to report them.

### Step 2.5: Low-Diagnostic Check

Before scoring, detect whether this retro will produce meaningful signal.

**Trigger** (ANY of): ≤5 tasks, all deletion/simple edits, 0 escalations, 0 captures; all tasks are prescriptive prose edits (SKILL.md, protocol files, convention files); >80% of task subjects contain verbatim edit instructions (exact text to add/remove).

When triggered, produce a **compressed assessment** — a `[retro] <slug> — LOW-DIAGNOSTIC` block with scope (N tasks + character), delivery worked yes/no with brief note, and notable surprises (or "none — scope too narrow for signal"). Log scores with `"low_diagnostic": true` in journal entry. D1-D4 scored honestly but flagged for trend weighting. Focus narrative on D5 only. Skip to Step 4.

**Why:** Prescriptive/trivial retros consistently produce all-ceiling D1-D4 that inflate averages. Knowledge value concentrates at spec time; implementation-time scoring is low-signal. Full ceremony wastes evaluation effort.

**Plan-saturated sentinel (post-scoring):** if no trigger fired here but Step 3 lands D1–D5 all at 5 with 0 escalations and 0 surfaced concerns, add `"plan_saturated": true` to the journal entry scores. All-ceiling retros on well-specified cycles are saturation, not signal — the flag lets longitudinal averages weight them distinctly without suppressing the scores.
<!-- Sunset: remove if ceiling-class retro-evolution rows targeting skills/retro/SKILL.md recur from ≥3 new distinct work items within the next 20 retro cycles. -->

### Step 2.8: Escalation verdict surface (work-item telemetry, not scored)

**Diagnostic, not scored.** When a worker returns a structured escalation verdict of the shape `{escalation: "task-too-trivial-for-solo-decomposition", rationale: "<one-sentence reason>"}` (validated at `scripts/validate-structured-report.py`), /retro surfaces it here as **work-item telemetry**. This surface is intentionally off-band from the dimension scores in Step 3 and off-band from the scorecard substrate:

- **Not wired to `/evolve`.** Escalation rate must never drive template mutation. Scoring producers on how often they escalate creates perverse incentives — either workers suppress legitimate escalations to keep their "rate" down, or they escalate trivially to game the signal.
- **Not rolled into any producer template scorecard.** No `kind == "scored"` row is written for an escalation. This is the **canonical precedent for the `kind` discriminator rule**: any observation type that must not drive template mutation stays off `kind == "scored"`. Future row types that face the same incentive hazard (e.g., advisor consultation counts, trigger-realization rates) should cite this precedent in their design docs.
- **Work-item scope, not portfolio scope.** Counts and rates are attributed per work item, not aggregated across templates, because the relevant remediation (re-scope the plan, merge the sub-task, accept one-shot) happens at the plan level.

### 2.8a: Inputs

Read escalation verdicts from the cycle's worker reports. **Primary:** `execution-log.md` entries in `$WORK_DIR/<slug>/` — each completed task's worker report is persisted there with the escalation stanza when one was emitted. **Secondary:** cross-session worker SendMessage reports surfaced in `notes.md` session entries, when `execution-log.md` is absent (review-only cycles) but a worker still returned an escalation.

Parse each report with the same regex pattern used by `validate-structured-report.py:find_escalation()` so this surface counts exactly what the gate counts — `VALID_ESCALATION = "task-too-trivial-for-solo-decomposition"` with a non-empty `rationale`. Malformed escalations are explicitly excluded.

### 2.8b: Lead disposition

For each escalation verdict, record a **lead disposition** — what the lead agent (team-lead or /implement orchestrator) did with the escalation. Closed enum: `merged` (lead merged the sub-task into a larger peer task rather than decomposing further); `re-scoped` (lead edited the plan to replace the escalated task with a wider-scope alternative, then discarded the original); `accepted-one-shot` (lead accepted the escalation but proceeded with the original trivial task as-is, no plan change); `unreviewed` (no visible lead response before the retro fires — either the work is still in-flight or the lead missed the escalation; distinct from `accepted-one-shot` because the intent signal is missing).

Infer disposition from `tasks.json` and `plan.md` state at retro time: escalated task's subject rewritten + sibling absorbed it → `merged`; plan's phase edited after escalation timestamp AND task set changed → `re-scoped`; task completed with `status: completed` and no plan/tasks edit followed → `accepted-one-shot`; task still `in_progress` or `pending` → `unreviewed`.

### 2.8c: Report shape

Render as a compact work-item telemetry block, **separate from dimension scores in Step 3 and separate from the Step 3.8 pipeline-degraded block**. Empty when zero escalations fired.

For the emit format, read `skills/retro/templates/emit-commands.md` § "Step 2.8c — Escalation telemetry output".

When zero escalations fired, emit **no prose** — consistent with the Step 3.8 silence invariant.

### 2.8d: Journal persistence

Write a separate journal entry so longitudinal queries can filter cleanly. Read `skills/retro/templates/emit-commands.md` § "Step 2.8d — Escalation journal write" for the `lore journal write` invocation.

`--role "retro-escalations"` is distinct from `retro` (dimension scores), `retro-behavioral-health` (qualitative), and `retro-evolution` (suggestions). **Four separate roles by design** — collapsing them would force consumers to demux by observation prose, which is fragile.

**Invariant.** This step never calls `scorecard-append`. There is no scorecard row written for an escalation — not `kind="scored"`, not `kind="telemetry"`. Journal-only storage structurally rules out any back-door through which /evolve could eventually consume escalation data.

### Step 2.9: Scale signal block (six factual + eval signals)

**Observational, not scored.** This step surfaces six per-cycle scale signals — four factual (read from existing telemetry) and two eval (agent self-report at reflection time). It produces **one sidecar row per cycle** in `$KDIR/_scorecards/retro-scale-access.jsonl` plus three “better than no scale” derivations. Runs unconditionally alongside Step 2.8; never affects `pipeline-degraded` state; never feeds `/evolve` or the pass|weak|fail headline.

### Four factual signals (read from telemetry)

Compute four signals from telemetry: **1. `declaration_coverage`** (fraction of retrieval opportunities where `scale_declared=true` in `retrieval-log.jsonl`, computed over **agent-driven rows only**, keyed by **exclusion** so new agent callers count by default: exclude rows with **no `caller` field** (session-startup hook writers — load-knowledge.sh logs its own retrieval records without one) and rows with caller in {`lore-query`, `resolve-manifest`} (background machinery whose call sites never require `--scale-set` and dilute the signal toward zero); the live agent-driven vocabulary as of 2026-06 is {`worker`, `worker-N`, `lead`, `prefetch`, `cli`, per-agent names like `tradeoffs`/`crossref-scout`} and all of it counts — do not re-key to an include-list without checking the log's actual caller values first (`jq -r '.caller // "<absent>"' retrieval-log.jsonl | sort | uniq -c`); treat `scale_declared` as true for boolean true OR a non-empty scale-set string <!-- Sunset: revert caller filtering if declaration_coverage remains <10% over the next 10 retro cycles after filtering — would indicate the dilution hypothesis was wrong -->); **2. `redeclare_rate`** (fraction of session retrievals re-issued at a different scale set from the previous call in the same session — measures rubric ↔ agent reality drift); **3. `off_scale_routes_emitted`** (count of worker-surfaced concerns routed off-scale, from `_work/<slug>/off_scale_routes.jsonl`); **4. `verifier_disagreements`** (count of classifier disagreements from the most recent `/renormalize` run, from `$KDIR/_meta/classification-report.json` or `scale_drift_rate` telemetry).

For the bash scripts that compute each signal, read `skills/retro/templates/step2-9-signal-scripts.md` — sections "Factual signal 1" through "Factual signal 4".

### Two eval signals (agent self-report)

Two prompts the agent answers from its own session experience: **5. `off_altitude_skipped`** (count of retrieved entries judged wrong-altitude and skipped this cycle); **6. `counterfactual_better`** (grade `better | same | worse`: would retrieval without declared scale have produced different results?). For the verbatim prompt text, read `skills/retro/templates/step2-9-signal-scripts.md` — sections "Eval signal 5" and "Eval signal 6".

### Sub-question: Abstraction level (retained)

> "Did agents get context at the right level of abstraction — enough to reason at the scale of the problem, without fine detail crowding out the framing or forcing descent to reconstruct it?"

Grade: `right-sized | too-coarse | too-fine`. One-line rationale citing specific retrieval calls observed in evidence (Step 2b's delivery audit, Step 2c's retrieval log). The rationale must name at least one concrete retrieval event or cite "no retrieval log — evidence absent" if the log is missing.

**Directionality** (for longitudinal interpretation): `too-coarse` → missing or under-linked child entries; the knowledge store has the concept but not the implementation-level detail workers needed. `too-fine` → missing bridging parent entries; workers were handed implementation detail without the framing context. `right-sized` → no structural gap surfaced.

### Emission

Invoke `retro-scale-access-append.sh` with the six signals — read `skills/retro/templates/step2-9-signal-scripts.md` § "Emission" for the bash invocation. The script writes to `$KDIR/_scorecards/retro-scale-access.jsonl` (schema_version: 2, created on first use). It validates grades against the closed enum before appending.

### Three "better than no scale" derivations

After computing the six signals, evaluate the three derivation tests:

1. **`off_scale_routes_emitted > 0`** — at least one worker coupled capture-or-route during the cycle. This shows the scale system is active and influencing agent routing decisions.
2. **`counterfactual_better` dominantly `same` or `worse`** — declared scale is at least as good as no-scale baseline. A majority `better` result would indicate the scale system is actively harmful and warrants investigation (but never automatic disablement).
3. **`redeclare_rate` stable or decreasing** — rubric ↔ agent reality alignment is stable. An increasing trend across cycles indicates rubric drift requiring attention.

**Report shape:** read `skills/retro/templates/step3-telemetry-outputs.md` § "scale signals (sidecar)" — the same emit format is reused by Step 3.5.

**Invariant.** This step never calls `scorecard-append`. The sidecar is not a scorecard row — it has no `calibration_state`, no `template_version`, no `kind: scored`, no `tier`. Mixing it into `rows.jsonl` would expose it to `/evolve` consumption; the separate file structurally prevents that. /retro is observational-only — it emits the signals and derivations but never auto-suggests disabling the scale system based on its own evaluation.
### Step 3.0: Scorecard delta surface (primary, tier-partitioned)

**This step is primary.** The scorecard delta surface leads the /retro output (Step 6 report). Dimension scoring (Step 3) is the qualitative coda — useful for describing knowledge-system behavior in prose, but **not** the operator-facing headline. Step 3.9's non-compensatory `pass|weak|fail` per template-version is the primary headline; Step 3.0 shows what *changed* since the last window to explain why the headline moved (or didn't).

**Why delta-first.** A single-window scorecard cell tells you where a template stands; a delta tells you which direction it's moving. A template at `factual_precision=0.72` might be `weak` in absolute terms but trending sharply upward (last window: 0.58) — the delta is the actionable signal.

**Relationship to other steps.** Step 3.8 (health checks) runs first; if `pipeline-degraded`, Step 3.0's deltas are non-evidentiary and the surface reads "not computed — window is pipeline-degraded, see Step 3.8". Step 3.9 (headline) supplies current-window values; Step 3.0 supplies deltas *against* the previous eligible window. Step 3 (dimensions) runs after Step 3.0 and is demoted to **narrative coda**.

### 3.0a: Inputs

- `$KDIR/_scorecards/_current.json` — current window's rollup (`scorecard-rollup.sh`).
- **Previous window's rollup** — selected from `$KDIR/_scorecards/snapshots/*.json` (per-rollup snapshots; same JSON content as `_current.json` from that rollup; filename matches top-level `window_end`). Selection rule: (1) List candidates from `snapshots/*.json` — **do not** include `_current.json` (lives in parent dir, not a snapshot); (2) Parse each candidate's top-level `window_end`; exclude missing/empty/invalid (no filename fallback — the field is the selection key per D5); (3) Pick the snapshot whose `window_end` is the **max value strictly earlier than** the current retro window's start (strict inequality; at-or-after-start excluded); (4) If no candidate satisfies (3), report "first eligible window — no delta baseline" and emit no delta rows — informational, not a degradation signal.
- `$KDIR/_scorecards/template-registry.json` — unregistered rows render as `unregistered:<hash>`, excluded from delta surfaces (same rule as Step 3.9).
- `$KDIR/_work/*/consumption-contradictions.jsonl` — for the `contradiction_verification_rate` metric below.
- The set of `pipeline-degraded` windows (from Step 4's journal) — if either window is degraded, the delta for that template-version is **skipped**, not zeroed.

### 3.0b: Tier partitioning

Partition rows by `tier` and emit **one delta surface per tier** in this order (most actionable first):

1. **`tier: template`** — template-behavior deltas. Primary. Feeds Step 3.9 headline and /evolve Step 5 primary gate.
2. **`tier: correction`** — doctrine-correction deltas. Secondary. May feed /evolve's doctrine-correction gate (see `skills/evolve/SKILL.md` Step 5).
3. **`tier: reusable`** — reusable commons-entry deltas. Informational; no /evolve weight.
4. **`tier: task-evidence`** — task-local grounding deltas. Informational; no /evolve weight.

Each tier's surface is computed independently with the same 3-filter gate below. Mixing tiers would Goodhart the template metric — task-local claim quality ≠ template-produced claim quality.

**Never mix tiers in a single delta cell.** A `tier: task-evidence` factual_precision reading and a `tier: template` factual_precision reading measure different things.

### 3.0c: Delta computation

For each registered `(template_id, template_version)` with `kind==scored, calibrated` rows in both the current and previous windows, scoped to one tier at a time: `delta_{metric} = current_{metric} - previous_{metric}`.

Compute a delta per metric in the six-MVP-metric vector from Step 3.9, plus the new `contradiction_verification_rate` metric below. Two MVP metrics are inverted (`triviality_rate`, `omission_rate`) — *improvement* means the delta is **negative**. The surface notation uses an explicit direction indicator (↑ improving, ↓ regressing) so readers don't track direction per metric.

**New metric: `contradiction_verification_rate`.** For `tier: template` surfaces only: `contradiction_verification_rate = |{contradictions with status=verified against this template in window}| / |{contradictions with status ∈ {verified, rejected} against this template in window}|`. A high rate indicates the template is producing claims that field observers repeatedly find false — a strong signal for template mutation. The rate is **inverted**: lower is better.

### 3.0d: 3-filter surface gate (load-bearing)

The delta surface is **not** a per-cell dump. It surfaces only deltas that carry actionable signal. A delta is surfaced when **all three** hold:

1. **Large change.** `|delta|` exceeds the per-metric magnitude threshold (MVP): `factual_precision` ≥ 0.05; `curated_rate` ≥ 0.05; `triviality_rate` ≥ 0.05; `omission_rate` ≥ 0.03 (more sensitive — small changes in portfolio-level miss rate are load-bearing); `observation_promotion_rate` ≥ 0.03; `contradiction_verification_rate` ≥ 0.10 (observational signal is coarser than adjudicative).
2. **Sufficient sample size.** Both windows must have n ≥ 10 rows for that metric. Below-sample deltas are noise.
3. **Registered template_version in both windows.** If either current or previous `template_version` is unregistered, skip — we can't attribute the delta to a known template lineage.

Deltas that pass the filter are **surfaced**; failures are **suppressed** but counted (one line at the end: "<N> small / below-sample / unregistered deltas suppressed") — preserves the "did something change?" signal without drowning the surface in noise.

### 3.0e: Report shape (per tier)

For the delta-surface output template (the first block of the Step 6 report), read `skills/retro/templates/step3-telemetry-outputs.md` — section "Step 3.0e — Delta surface report shape (per tier)".

Each surfaced delta line reads left-to-right:
`<metric>: <previous> → <current>  (<direction symbol> <signed delta>, n=<current sample>)  [<classification change if any>]`

"Classification change" is derived from Step 3.9's headline thresholds (applies to `tier: template` surface only): a delta that moved the metric from `weak` to `pass`, or from `pass` to `fail`, is flagged.

**Pipeline-degraded windows.** If either window was `pipeline-degraded`, emit per affected template-version: `Deltas for <template_id>@<version>: skipped (degraded window — see Step 3.8)`.

**First-window case.** If no prior eligible window exists, emit `First eligible window — no delta baseline. Full current-window values appear in Step 3.9's headline block below.`

### 3.0f: Journal persistence

Deltas are derived signal, not source data. They are NOT written to `rows.jsonl` — the scorecard substrate remains append-only with first-derivative storage only. The delta surface IS persisted to the retro journal entry (Step 4) under a `scorecard_deltas` field keyed by tier. Read `skills/retro/templates/step3-telemetry-outputs.md` § "Step 3.0f — scorecard_deltas journal-persistence JSON" for the full schema. `surfaced: true` iff the delta passed all three filters — lets downstream readers (dashboards, /evolve ranking) access both the full delta map and the filtered view without re-computing.

**Invariant — no compensation.** A large improvement on one metric does NOT suppress a surfaced regression on another metric for the same template. The surface shows all surfaced deltas; the reader (human or `/evolve`) composes them. This mirrors the Step 3.9 non-compensatory rule.

### Step 3: Evaluate Dimensions (narrative coda)

*Dimension scoring is the narrative coda — not the headline.* The operator-facing headline is Step 3.9's `pass|weak|fail` per template-version; the actionable signal is Step 3.0's scorecard delta surface. Dimension scores persist for longitudinal trend tracking and for cases where settlement data is sparse (new repos, first few retros), but they no longer lead the report.

Keep scoring honest: the scores are still 1-5 and still cite concrete evidence. Do not inflate or deflate to match the scorecard headline — if the dimension score disagrees with the headline, that disagreement is itself diagnostic. The Step 6 report frames dimensions under "Narrative coda" below the scorecard delta block and the headline block.

Score each 1-5 with concrete evidence. Cite specific artifacts. Consult `failure-modes.md` when anomalies appear.

### Dimension 1 — Knowledge Delivery

Was knowledge delivered to workers? Compare `**Knowledge context:**` in plan against worker behavior.

**Evidence by cycle type:** *Implementation* — explicit citations in Observations OR correct approach choices in output (annotation-only: workers internalize framing, not cite by name — implementation output is the evidence). *Review* — subagents received knowledge preambles. *Spec-only* — ad-hoc subagents dispatched without knowledge context when available = delivery failure. *Prose/convention* — output aligned with delivered principles = knowledge applied, even without citation.

Scoring: 5 = every phase delivered, high completeness | 4 = most phases, minor gaps | 3 = low annotation quality or spec-only without subagent delivery | 2 = phases missing, >30% unresolved, or pipeline silent drop | 1 = no delivery

### Dimension 2 — Retrieval Quality

Were delivered entries relevant, current, and at the right abstraction level? Scoring: 5 = all relevant + current + right level | 4 = mostly, one minor mismatch | 3 = topically relevant but wrong abstraction level | 2 = mostly irrelevant/stale | 1 = actively misleading. Note: abstraction mismatch on prescriptive tasks is structural, not retrieval failure (see low-diagnostic check).

### Dimension 3 — Gap Analysis

What did workers need that wasn't in the store? Use `execution-log.md` `source: remember` entries as confirmed gap list. Distinguish *coverage failures* (pattern existed elsewhere, wasn't captured) from *genuinely novel discoveries* — coverage failures weigh heavier. ≤4 tasks, 1-2 files = "trivial scope — gap dimension low-signal". Stale corrections (0 new captures, N corrections) = positive maturity signal, not gaps.

Scoring: 5 = no gaps | 4 = one minor or only novel discoveries | 3 = one significant coverage failure | 2 = multiple coverage failures | 1 = no knowledge system support

### Dimension 4 — Plan-Knowledge Alignment

Did plan design decisions reference entries that actually influenced implementation? Review cycles: knowledge flow store→review (good) vs review→store (lower — store was consumer).

Scoring: 5 = decisions shaped implementation | 4 = most influenced, 1-2 decorative | 3 = existed but workers chose independently | 2 = cited but diverged | 1 = no alignment

### Dimension 5 — Spec Utility

Did the spec reduce workers' need for independent exploration? Evidence: escalations, out-of-scope file reads, divergent choices, unexpected discoveries. See `failure-modes.md` Section D for modifiers. Spec-only: score structural quality as `(predictive)`; N corrections caps at 4. Intent tasks: out-of-scope reads for discovery are by-design, not gaps.

Scoring: 5 = spec-guided, 0 escalations | 4 = minor exploration, ≤1 escalation | 3 = several reads, 2-3 escalations | 2 = frequent exploration, multiple divergences | 1 = no meaningful guidance

### Step 3.5: Memory System Telemetry

**Observability only — MUST NOT feed `/evolve` or the F1 harmonic-mean template ranking.** These metrics describe how the knowledge store is behaving as a system. They are NOT verdict-level scores on individual producer templates; surfacing them here is for the operator's situational awareness, not for driving template mutations. Any `/evolve` citation that references a metric from this section is invalid and must be rejected.

**P2.3-16 anti-coupling invariant.** The `tier: telemetry` enum value exists specifically to keep these rows out of /evolve's citation gate. Any row emitted by this step carries `tier: telemetry` (or no tier — readers apply the missing-tier legacy policy and treat it as telemetry). If /evolve's citation gate ever accepts a `tier: telemetry` row as evidence for template mutation, the anti-coupling has been broken — this is the highest-priority silent-breakage risk in the memory-telemetry pipeline.

Read `$KDIR/_scorecards/rows.jsonl` filtered to rows with `tier: telemetry` in the retro window. For each metric below, compute a one-line summary and select the top-3 highlights. When a metric has zero rows in the window, emit `<metric>: no data in window` and continue — do not treat absence as a failure. For per-metric output templates, read `skills/retro/templates/step3-telemetry-outputs.md` § "Step 3.5 — Memory-system telemetry per-metric output blocks"; entries below name source rows and summary computation, the emit format lives in the sidecar.

### Retention after renormalize

Source: rows where `metric == "retention_after_renormalize"`. Key fields: `entry_id`, `cycles_survived`, `template_id` (producer template), `run_id`. Summary: median `cycles_survived` across all entries in window; count of entries with `cycles_survived >= 3` (signal of durable high-quality output). Top-3 highlights: entries with the highest `cycles_survived`.

### Downstream adoption rate

Source: rows where `metric == "downstream_adoption_rate"`. Key fields: `entry_id`, `value` (adoption rate 0.0–1.0), `status`, `window_days`. Summary: mean adoption rate across entries in window; fraction with `value > 0.5`. Top-3 highlights: entries with the highest adoption rate, with their `status`.

### Route precision

Source: rows where `metric == "route_precision"`. Key fields: `role`, `outcome` (accepted/declined), `route_id`, `template_id`. Summary: acceptance rate per role (accepted / total routes) in window. Top-3 highlights: roles with the lowest acceptance rate (most likely to benefit from channel-contract adjustment).

### Supersession quality

Source: rows where `metric == "supersession_quality"`. Key fields: `superseded_entry_id`, `successor_entry_id`, `quality` (improved/neutral/regressed). Summary: fraction of supersessions marked `improved` in window. Top-3 highlights: any `neutral` or `regressed` supersessions. When all supersessions are `improved` and count ≥ 1: emit `supersession_quality: all improved (<K> total)` with no highlights.

### Scale drift rate

Source: rows where `metric == "scale_drift_rate"`. Key fields: `producer_role`, `value` (drift rate 0.0–1.0), `run_id`. Summary: drift rate per role; flag any role where `value > 0.20` (guardrail threshold). Top-3 highlights: roles with highest drift rate. When no role exceeds 0.20: emit `scale_drift_rate: all roles within guardrail` with no highlights.

### Scale signals (sidecar)

Source: `$KDIR/_scorecards/retro-scale-access.jsonl` — the row whose `cycle_id` matches the current retro slug (most recent by `ts` if multiple). When no row exists for this cycle: `scale signals: not assessed this cycle`.

### Channel-contract flags (sidecar)

Source: `$KDIR/_scorecards/retro-channel-flags.jsonl` — all rows whose `cycle_id` matches the current retro slug. When no flags fired: `channel-contract flags: none`.

**Step 3.5 invariant — no `/evolve` coupling.** The metrics in this section describe memory-system health, not producer-template quality. They inform the operator's understanding of how the knowledge store is aging, routing, and self-correcting — they do not adjudicate whether any template produced correct output. `/evolve` MUST NOT cite any metric from this section as evidence for a template mutation. If `/evolve` sees a "retention_after_renormalize" or "downstream_adoption_rate" citation, it must skip that citation as non-evidentiary (enforced structurally by the `tier: template` filter in `/evolve` Step 5).

### Step 3.5a: Judgment-class routing attribution (observability — never `/evolve`)

**Observability only — MUST NOT feed `/evolve` or template ranking.** Same anti-coupling as Step 3.5: the inputs are `kind: telemetry` rows (P2.3-16), and the author-inflation falsifier targets spec-author decomposition calibration, not producer-template mutation. Any `/evolve` citation of a figure from this surface is invalid and must be rejected.

This surface closes the class-aware-decomposition calibration loop: `/spec` assigns each task a `[class: …]` (mechanical | standard | judgment-dense), `/implement` routes the worker model per class, and this step measures whether the classes actually earn their routing — reporting **rework rate per `(judgment_class, worker_model, size bucket)`** and flagging the **author-inflation falsifier** (judgment-dense-labeled work with a mechanical-level rework profile). Read-only; runs on all windows; emits no scorecard row.

This step also pairs **measured cost** with that quality signal so routing beliefs become falsifiable rather than asserted: each surfaced cell carries median worker token/duration spend beside its rework rate, a per-work-item session-spend line reports the orchestration's own `closed`-event cost, and a `cost-vs-quality:` block states cost per accepted task per routed cohort (the surface that lets a claim like "codex workers are cheaper at equal quality" be checked against data). Cost is telemetry, never a scored axis (`kind-discriminator` precedent — scoring token count incentivizes gaming it directly), and — by the Goodhart guard written into the Invariant below — never renders without its paired quality figure in the same block.

**3.5a-i: Inputs (all read-only).**

- **Per-task attribution** — `$KDIR/_scorecards/rows.jsonl`, rows with `kind == "telemetry"`, `event_type == "impl-close"`, and `metric == "impl_close_bookkeeping"` whose `ts` falls in the retro window. Each carries a `task_attribution` array of `{task_id, judgment_class, worker_model, context_cost_estimate}`, one object per task in the closed cycle. `judgment_class` is `null` on unannotated/legacy tasks; `context_cost_estimate` is the integer `total_chars` (or `null`). An absent or empty `task_attribution` array (the latter when the item had no readable `tasks.json` at close) means no class-routed tasks to attribute — skip it; absence is not a failure. **`worker_model` fidelity:** it is re-resolved from the current class binding at close time (`null` when the class role has no binding and cannot fall back), so it reflects the *class binding*, not a runtime user model pin that may have overridden it at dispatch — read `(class, worker_model)` cells as binding-level, and treat the model axis as approximate whenever a user pin was in play (per `worker-sub-agent-model-selection-is-user-directed`).
- **Split rationale (authoring-intent context)** — rows with `kind == "telemetry"`, `event_type == "spec-finalize"`, and `metric == "spec_finalize_bookkeeping"` in the window carry `split_rationale` (object keyed by phase number **as a string** — `"1"`, `"2"` — to rationale text; only phases with a `**Split rationale:**` block appear, `{}` when none) and `class_distribution` (all three keys always present → per-class task counts the author declared at finalize). The row is appended fresh on every finalize with **no dedup**, so key on the latest row per work item (same as the sibling `verb_mediated_count`/`hand_run_count` fields). Surface these beside the rework table so a divergence between the declared class mix and observed rework is legible — they explain why a phase was split and what class mix the author expected.
- **Rework signals (per task):**
  1. **Re-dispatch (primary, task-keyed).** In `execution-log.md`, a task whose `task_id` (or verbatim subject, which retains the `[class: …]` marker) heads **more than one** entry was re-dispatched — sent back and re-run. This is the same duplicate-subject pattern Step 2a's evidence-anomaly screen already detects; reuse that scan. Count one rework event per extra entry.
  2. **`tier: correction` rows (secondary, work-item-keyed).** `rows.jsonl` rows with `tier == "correction"` in the window signal that a producer's captured claim/observation/doctrine was corrected (`corrected_entry_path`, `correction_target`). They key on the corrected entry and its producing template, **not** on `task_id`/`judgment_class`, so they attribute to the **work item**, not cleanly to one class cell. Report them as a work-item-level correction-pressure figure beside the table; fold a correction into a specific `(class, model, size)` cell only when its `corrected_entry_path` traces to exactly one task in this cycle's attribution set.

  A task is **reworked** when it has ≥1 re-dispatch entry OR ≥1 task-attributable correction row.
- **Per-task worker spend (nullable)** — each `task_attribution` object carries a `spend` sub-object in the D1 vocabulary (`input_tokens`, `output_tokens`, `total_tokens`, `duration_seconds`, `cost_usd`, `model`, `harness`, `basis` — token fields omitted, never zero-filled, when the harness does not expose them). It is `null` for Task-tool (claude-native) workers, which have no exposed token stream — honestly **unmeasured, not zero**; codex-routed workers carry measured tokens (`basis: rollout`). A re-dispatched task keeps **all** its spend entries in dispatch order (impl-close appends with no dedup, so rework cost is visible per attempt). Read `spend` per attempt and treat `null` as a missing data point, never as `0`.
- **Session-level spend** — `closed` rows in `$KDIR/_sessions/events.jsonl` whose `ts` falls in the retro window **and** whose `slug` matches this work item. Each carries a `spend` object in the same D1 vocabulary (the lead's claude-code session binds its transcript deterministically → `basis: transcript` with real tokens; codex/opencode-hosted sessions degrade to `basis: duration-only`). **Reuse the Step 2c.6 journal read** — the same windowed pass over `events.jsonl`, re-read at authoring time — and inherit its reader-tolerance contract verbatim: an interior-malformed row is excluded with a warning and the cursor advances, a trailing torn row stops the read at the last valid row ([[knowledge:conventions/byte-offset-append-only-journal-reader-must-treat]]). These are point events — window-filter by `ts`, never reconstruct session activity intervals ([[knowledge:conventions/scorecard-rollup-helpers-use-point-in-time-window]]).

  **Derived-slug worker sessions are intentionally out of this line.** The exact-work-item-slug match above excludes PTY-hosted worker sessions dispatched by `/implement`'s session route — those run under a derived slug (`<work-item-slug>--w<n>`), so their `closed` rows never match this work item's bare slug. This is by design, not a gap: worker-session cost is attributed *per task* through the execution-log `Spend: task=<id>` line (which `impl-close` joins onto `task_attribution`), while this session-spend line measures *the orchestration's own cost* — the lead's implement session. Counting derived-slug workers here would double-count the same tokens the per-task attribution already carries. The join choice is the design decision, not an omission (per [[knowledge:conventions/spend-telemetry-substrate-is-type-agnostic-by-desi]]); leave this line keyed on the bare work-item slug.

**3.5a-ii: Size bucket.** In the attribution object, `context_cost_estimate` is the task's total character count (a scalar integer — `impl-close.sh` flattens `context_cost_estimate.total_chars` to it — or `null` when the task carried no estimate). Bucket it: `small` < 15000; `medium` 15000–29999 (the historical ~22KB homogeneous split price lands here); `large` ≥ 30000; `unknown` when `null`.

**3.5a-iii: Computation.** For each task in the joined attribution set, assign `(judgment_class, worker_model, size_bucket)` and the boolean `reworked`. Group and compute `rework_rate = |reworked| / |tasks|` per group. Surface only groups with `|tasks| ≥ 3` — below that a "rate" is single-task noise; suppressed groups are counted in one trailing line (`<N> below-sample groups suppressed`), mirroring Step 3.0's below-sample suppression.

**Cost computation (same grouping).** For each surfaced cell, compute **median `total_tokens`** and **median `duration_seconds`** over its tasks' spend entries — one data point per spend entry, so a re-dispatched task's attempts each count. A `null`-spend task contributes no data point; a cell whose spend is entirely `null` yields `n/a` for both cost columns, never `0`. Because `worker_model` is part of the cell key, claude-native (`null`) cells and codex (measured) cells never share a cell — so no median blends the two bases; hold that separation as a rule, not a coincidence of the key. **Per routed cohort** — codex-routed (spend carries measured tokens) vs. claude-native (spend `null` or `duration-only`) — compute **cost per accepted task**: for the measured cohort, sum `total_tokens` across every spend entry (rework attempts included) divided by the count of distinct accepted tasks, so rework inflates the per-accepted-task cost; the claude-native cohort's token cost is `null` (unmeasured — report its `duration_seconds`-per-accepted-task only when the lead timed dispatch→acceptance, marked `duration-only`, never as tokens). Costs in different bases are never summed or averaged across cohorts. **Session totals:** sum `total_tokens` over the joined `closed` rows that carry measured tokens, and tally the `basis` mix (e.g. `2 transcript, 1 duration-only`).

**3.5a-iv: Author-inflation falsifier.** The class system's premise is that judgment-dense tasks are genuinely harder — they rework more when under-resourced — while mechanical tasks stay cheap and rework little. The falsifier of an *inflated* label is the inverse: a `judgment-dense` cohort whose rework rate is **at or below** the `mechanical` cohort's rework rate in the same window. When judgment-dense work is not reworking more than mechanical work, the label is not tracking real difficulty and the author may be inflating class to claim the capability premium — routing to an expensive model the task did not need. Flag any such cohort, and name the individual `judgment-dense` tasks sitting in a mechanical-level low-rework profile. This is a **calibration signal for the spec author** — it informs plan-review judgment on future decompositions, never a template mutation.

**3.5a-v: Report shape.** When no `impl-close` row carries `task_attribution` in the window, emit one line — `judgment-class attribution: no class-routed implementation in window` — and continue (same "no data in window" discipline as Step 3.5); no cost surface renders in this case. Otherwise emit a compact block:

- One line per surfaced `(judgment_class, worker_model, size_bucket)` group, **rework and cost paired on the same line**: `<class> / <model> / <bucket>: rework <reworked>/<tasks> (<rate>) — median <tokens> tok, <duration>s`. When the cell's spend is entirely `null`, the cost fields read `median n/a tok, n/a s` — the rework figure still renders (quality is never suppressed for want of cost). A cost field never appears on a line without its rework figure.
- The below-sample suppression line and the work-item correction-pressure figure, as before.
- **Session-spend line** (per work item): `session spend: <total> tok across <N> closed sessions (<basis mix>) — cycle rework <reworked>/<tasks>`. The paired cycle-rework figure is mandatory; the session cost never renders alone. When no joined `closed` row carries measured tokens, degrade to one line: `session spend: no measured closed-session spend in window`.
- **`cost-vs-quality:` block** — one line per routed cohort, cost paired with quality: `codex-routed: <tok>/accepted-task, rework <rate>` and `claude-native: cost null (no token stream), rework <rate>` (or `claude-native: <s>/accepted-task duration-only, rework <rate>` when dispatch→acceptance timing was recorded). The two cohorts stay on their own lines in their own units — never averaged into a single figure. This is the falsifiability surface for routing beliefs; a cohort's cost never renders without its rework rate. When no worker spend was measured in the window, degrade to one line: `cost-vs-quality: no measured worker spend in window`.
- Under an `author-inflation:` heading, any flagged cohorts (or `author-inflation: none` when the falsifier does not fire).

This block appears alongside Step 3.5 telemetry in the Step 6 normal-window report.

**Invariant.** This step never calls `scorecard-append` — it is a pure reader, and the scorecard sole-writer invariant (CC-04) is untouched. Rework rates and inflation flags are derived signal: surfaced in the report, never written back to `rows.jsonl`, never journaled under a scored role, never cited by `/evolve`.

**Cost-pairing invariant (Goodhart guard — step law).** No cost figure — a per-cell median column, the session-spend line, or a `cost-vs-quality:` cohort figure — may render unless its paired quality figure renders in the same block: the cell's rework rate for the cost columns, the cohort's rework rate for the cost-vs-quality lines, and the cycle-rework figure for the session-spend line. If the quality figure is unavailable, the cost figure is **suppressed, not shown alone**. This is not prose advice — it is the structural expression of the standing commitment to never score on token count alone, and it survives template drift because a cost-only render is malformed output, not a stylistic lapse. Every cost figure inherits this step's invariants verbatim: it is `kind: telemetry` by the kind-discriminator precedent (cost-scoring incentivizes token gaming directly), read by a pure reader that never calls `scorecard-append`, never journaled under a scored role, and **never cited by `/evolve`** — any `/evolve` citation of a cost figure is invalid and must be rejected, exactly as for the rework figures above. `null` spend is never coerced to `0`, and unmeasured cohorts are never averaged into measured ones: the `n/a` and `null` markers are load-bearing signal that the harness exposed no token stream, not a value to fill.

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
3. **Form-filling vs. substance** — required fields get content, optional fields go empty; schema crowds out craft.
4. **Goodhart drift** — behavior bends toward any added metric and away from the underlying goal.
5. **Judgment atrophy** — agents stop making non-obvious calls because the protocol doesn't reward them.
6. **Calibration drift** — auto-disposition, routing, or scoring thresholds fall out of alignment with human override patterns.
7. **Compliance theater** — multi-step skills where every step "succeeds" but substance was thin.

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

**Rotate** (see *Rotation policy* above — 3 of Checks 1–6 + Check 7 always, selected at invocation time). **Demand prose, not scores** — each check produces a sentence or two, never a number. **Pair quantitative with qualitative** — where a count is computable (Checks 2, 5, 6), require an explanation alongside it. **Meta-check periodically** (see *Tuning cadence* — formulaic answers are a tuning trigger, not a passing observation).

### Tuning cadence

The check set is not frozen. As answers accumulate across retros they reveal which checks surface signal and which have gone formulaic.

**Trigger condition.** Run the tuning pass when **any** holds:
- Six or more `retro-behavioral-health` journal entries have landed since the last tuning pass.
- A single check has answered "same phrasing" across ≥3 consecutive selections — that check has gone formulaic.
- A check has been selected ≥5 times over the window and its answers have never once diverged from the dimension-score narrative — it is redundant.

**Pass procedure.** When the trigger fires: (1) Query the journal — `jq -c 'select(.role == "retro-behavioral-health")' _meta/effectiveness-journal.jsonl | tail -<N>`; (2) For each of Checks 1–6, read the most recent ≥3 answers and classify each as *surprising*, *formulaic*, or *redundant-with-dimensions*; (3) Check 7 is never tuned away — its answer quality can drift but its slot is protected; (4) For checks that are formulaic or redundant, either (a) reword the check prompt to target the *underlying* drift mode more directly, or (b) retire and replace from the drift-mode list. Record the edit in a journal entry with `--role "retro-behavioral-health-tuning"`; (5) Bump template-version so the tuning edit is visible to the scorecard substrate as a distinct version.

**Cadence floor.** Do not tune more often than the trigger. Tuning before the journal has enough entries just churns the question set without evidence.

### Recording

Behavioral-health answers go into a **separate** journal entry (see Step 4a). They are prose observations, not scored fields. Record which 4 checks were selected so rotation frequency can be tracked longitudinally.

### Step 3.8: Settlement pipeline health checks

Settlement signal is only trustworthy when the pipeline that produced it was actually alive. Step 3.8 verifies settlement *liveness*. Each check reads a telemetry file the earlier phases already write — no new schema.

**Healthy-case silence (invariant — load-bearing).** When a check is green, it emits **no prose**. No "(green)" bullet, no "(ok)" line, no "all checks passed" summary. The operator-facing retro surface in a healthy window is indistinguishable from a window where Step 3.8 did not run — checks compute silently in the background and only speak when they find something wrong.

Rationale: if every retro narrated "audit coverage nominal, provenance ok" the checks become ritual recitation that agents learn to produce without thought, the retro prose grows with each new check, and the *signal* of a tripped check drowns in boilerplate green.

Only tripped checks generate narrative. The `pipeline-degraded` headline is the sole indicator in a healthy window that the checks are there at all: it doesn't appear, and the dimension-score headline reads normally.

**Where the invariant is enforced.** Each `### Check:` subsection below carries a `**When green: no prose.**` line — load-bearing, not decorative; a check that emits a green line on passing violates the invariant. The Step 6 report's `pipeline-degraded` block is the only place tripped-check narrative appears — the normal-window block reports the scorecard delta + headline + dimension scores only, never `Health checks: all green`. A future check added under this step MUST include the silent-when-green clause.

**Degraded state — `pipeline-degraded`.** A retro headline state, **distinct from `pass | weak | fail`**, emitted when any Step 3.8 health check trips. Not a fourth tier of the non-compensatory headline — a separate axis that **supersedes** the headline for the window:

- A clean scorecard over a broken pipeline is **not** `pass`. When `pipeline-degraded` fires, the dimension-score headline is replaced by `pipeline-degraded` in the journal and the final report. Underlying scores may still be computed and recorded (for trend analysis) but the operator-facing headline is the degraded state.
- `/evolve` treats `pipeline-degraded` windows as **non-evidentiary**. No template mutation may cite a scorecard cell, retro finding, or reconciliation delta from a `pipeline-degraded` window, regardless of the dimension scores or scorecard cell values. See `skills/evolve/SKILL.md` Step 5 for enforcement.
- Step 6's prose section lists which checks tripped and points at the relevant telemetry file(s). Checks that did *not* trip remain silent.

Computationally: let `tripped = [<names of checks that fired>]`. If `tripped` is non-empty, set `window_state = "pipeline-degraded"`; otherwise the window inherits the Step 3.9 non-compensatory headline (`pass | weak | fail`). A pure function of Step 3.8 outputs — deterministic, consultable by `/evolve` without re-running the checks.

**Warm-up state — `warmup: awaiting-template-tier-rows`.** Distinct from `pipeline-degraded`. Emitted when the tier migration has recently landed and `tier: template` row counts are below Step 3.9's sample-size minimum (n ≥ 10). Informational, not a gate — `/evolve` runs proceed, but the Step 3.9 headline naturally shows `insufficient:<N>` until enough new-tier rows accumulate. The warm-up state clears automatically as rows arrive.

### Check: Audit coverage (G1 disposition: redirected to settlement substrate)

**What it measures.** Two independent sub-checks, both of which must be healthy for the check to be green under the settlement-pipeline model.

**G1 disposition (substrate redirect).** Audit coverage now reads from the settlement substrate — `_settlement/runs/*.json` (verdict-landing ratios) and `_settlement/queue.json` (enqueue→completion times) — rather than from the older `audit-attempts.jsonl` + `rows.jsonl` pair. The sub-check semantics (lag + routing realization) are preserved; only the read sources change. The settlement substrate is the canonical input under the post-Phase-1 substrate; older sources are retained only for back-compat reads when the settlement substrate is absent.

**Sub-check 1: Lag.** Median time from settlement-queue enqueue to settlement-run completion for items in the window is ≤ configurable threshold (default: **7 days**). Exceeding → this sub-check trips.

**Source-of-truth.** Read enqueue→completion timings from `_settlement/queue.json` entries (each carries `enqueued_at` and either `completed_at` or `status: pending`); join against `_settlement/runs/*.json` to confirm completion timestamps. When a queue entry's `completed_at` is missing but a corresponding run record exists, prefer the run record's timestamp.

**Sub-check 2: Routing realization.** For settlement queue entries enqueued more than a **grace period of 24h** before window close, compute:

```
verdict_realization_ratio = |{queue entries with a corresponding completed run in _settlement/runs/}| / |queue entries enqueued > grace period before window close|
```

Healthy when **either**: Ratio ≥ **0.50** with sample size ≥ **10**, OR **≥ 3 completed runs** when sample size < 10. Below threshold → routing partially failed (items enqueued, runs aren't completing) — this sub-check trips.

**Denominator semantics — forward-settlement coverage only (load-bearing).** This ratio measures *forward-settlement* coverage exclusively: its denominator is the set of `_settlement/queue.json` entries the forward loop enqueued (`commons` audits enqueued at promotion time, plus the other settlement kinds). It is **not** a coverage ratio over all commons entries. Pre-existing `unaudited` entries that predate enqueue-at-promotion are never enqueued by the forward loop, so they fall **outside** this denominator entirely — they neither inflate it nor trip the check.

**Historical-unaudited count (honesty companion — surfaced as evidence, not as a check output).** Because those pre-existing entries sit outside the forward-settlement denominator, a clean `verdict_realization_ratio` would read falsely-green about *total* commons audit coverage. The honest count is therefore surfaced in the Step 2f evidence block (not here), so it does **not** depend on this check tripping and does **not** violate the silent-when-green invariant: count commons entries with `confidence: unaudited` in their markdown frontmatter that have **no** corresponding `commons` queue entry in `_settlement/queue.json` (i.e., never enqueued by the forward loop). This is a **reporting line, not a backfill and not a trip condition** — these entries lack the structured falsifier the correctness-gate needs and are out of scope for the forward loop (see Design Decision D6 in the plan); surfacing their count prevents the forward-coverage ratio from being misread as whole-store coverage.

**Why both sub-checks.** Routing realization catches the case where queue items don't progress to completed runs (analogous to the earlier "triggers fire but verdicts don't land" failure mode, restated against the settlement substrate). Lag catches slow pipelines even when routing is complete.

**Alignment with trigger realization (deferred).** The routing realization sub-check measures "of items enqueued, did runs complete?" Trigger realization (deferred) measures whether ceremonies produced enqueue events at the configured probability. The two are distinct and remain so under the substrate redirect.

**When green: no prose.**

**When tripped, output:** read `skills/retro/templates/step3-8-tripped-outputs.md` § "Audit coverage" for the tripped-output block.

**Distinguished from.** Old "coverage < 60%" absolute-coverage threshold remains retired. The lag + routing-realization design catches real failure modes (slow pipelines, broken routing) without false-alarming on expected sparse coverage. Under the G1 substrate redirect, the read sources are `_settlement/queue.json` and `_settlement/runs/*.json` rather than the older `audit-attempts.jsonl` + `rows.jsonl` pair.

### Check: Trigger realization rate

**Status.** Deferred until the open probabilistic-audit work item reintroduces a live trigger source. The previous `settlement-config.json` / `trigger-log.jsonl` implementation was removed after the hook adapters stopped installing it.

**What it will measure.** For each future audit-trigger source with a configured probability `p > 0`, compute the observed firing rate over the retro window and compare to the configured `p`. Flag any source whose observed rate falls outside a **±50% relative tolerance band** around `p`, computed over **≥10 rolls**. Below 10 samples the check abstains — too noisy to distinguish drift from Bernoulli variance.

**Why it matters.** The future trigger must write a row for **every** roll — fired and not-fired alike. If the hook is broken, if the queue is stalled, or if the config has drifted, the observed rate diverges from `p`. Three failure modes that look identical to downstream scorecard aggregates but have different fixes.

**Inputs.**
- Future trigger-roll telemetry — filter to rows whose trigger timestamp falls inside the retro window; group by trigger source.
- Future probabilistic-audit configuration — read configured `p` per trigger source.

**Computation.**
```
For each trigger source c with configured_p[c] > 0:
  total_c   = |{rows where source == c and triggered_at ∈ window}|
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

**When tripped, output (one block per tripped ceremony):** read `skills/retro/templates/step3-8-tripped-outputs.md` § "Trigger realization rate".

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

**When tripped, output:** read `skills/retro/templates/step3-8-tripped-outputs.md` § "Grounding failure rate".

### Check: Candidate-queue backlog (G1 disposition: redirected to settlement substrate, per-kind)

**What it measures.** The growth trend of the settlement queue, broken down by `kind` (e.g., task-evidence, omission-candidate, consumption-contradiction). Queue length = count of `_settlement/queue.json` items with `status: pending` per kind.

**G1 disposition (substrate redirect).** Replaces the older per-work-item `audit-candidates.jsonl` read with a single cluster-wide read of `_settlement/queue.json`, grouped by `kind`. The substrate is now kind-aware (post-Phase-1), so the backlog check operates per-kind instead of cluster-wide-only — a backlog in one kind (e.g., consumption-contradiction) is informative even when other kinds are healthy.

**Two distinct failure modes (per kind):** **growth-rate trip** (`added / max(resolved, 1) > 2.0` with `added ≥ 10` for that kind) and **absolute-size trip** (>50 pending cluster-wide at window close, summed across kinds, OR >25 pending in any single kind).

**Why it matters.** The settlement queue is the handoff from producers (capture, reverse-auditor, consumption-contradiction) to the three-judge settlement pipeline. Unbounded growth in any kind means producers are outrunning the gate-and-curator pipeline for that kind. Per-kind visibility lets the operator localize the failure (e.g., consumption-contradiction backlog signals priority routing problems; task-evidence backlog signals correctness-gate throughput).

**Inputs.** `$KDIR/_settlement/queue.json` (cluster-wide; entries carry `kind`, `status`, `enqueued_at`, and either `completed_at` or `status: pending`).

**Computation.**
```
For each kind K observed in _settlement/queue.json:
  added_K      = |entries with kind == K and enqueued_at ∈ window|
  resolved_K   = |entries with kind == K and status transitioned to completed|gate-failed|retired with ts ∈ window|
  pending_K    = |entries with kind == K and status == "pending" at window close|
  growth_ratio_K = added_K / max(resolved_K, 1)

Aggregate (cluster-wide totals):
  pending_total = sum(pending_K) across all kinds
```

**Thresholds.** A kind trips when either: `growth_ratio_K > 2.0` with `added_K ≥ 10`; or `pending_K > 25`. The check also trips on the cluster-wide aggregate when `pending_total > 50`.

**When green: no prose.**

**When tripped, output (one block per tripped kind plus a cluster-aggregate line when the aggregate trips):** read `skills/retro/templates/step3-8-tripped-outputs.md` § "Candidate-queue backlog".

### Check: Provenance resolution rate (G1 disposition: retired)

**Status.** Retired under G1. The previous design measured the share of reconciliation attempts landing at `provenance-unknown` to detect brittle content anchors; under the post-Phase-1 settlement substrate, content-anchor failures surface through the per-kind correctness-gate's grounding preflight (see Grounding failure rate above, with the `field-missing` and `snippet-mismatch` reasons covering the same pathology). A second standalone provenance check produced redundant pipeline-degraded fires against the same failure mode.

**Migration path.** Operators previously triggered by this check should read Grounding failure rate's per-reason breakdown for the same diagnostic signal. The `tuning signal` line ("consider enabling token-shingle fuzzy tier") remains valid but moves out of the retro pipeline-degraded surface.

### Check: Judge liveness (G1 disposition: redefined per-gate against calibration logs)

**What it measures.** Per-gate verdict distribution and recent-run liveness, read from each gate's calibration log at `_calibration/<gate>/calibration-log.jsonl`. The post-Phase-2 substrate forks the correctness-gate into three kind-specialized gates (one per kind), each with its own calibration log; this check evaluates liveness per-gate.

**G1 disposition (substrate redirect).** Replaces the older `rows.jsonl` + future-trigger-telemetry pair with a single read of each gate's `_calibration/<gate>/calibration-log.jsonl`. The calibration log carries one row per gate run with the verdict and timestamp; reading per-gate logs both localizes the signal (which gate is degraded) and aligns the liveness check with the calibrated write-gate model (calibration-log is the operational truth for each gate's recent activity).

**Three signatures (evaluated per gate):**

1. **Gate broken** — a gate emits `unverified` (or the gate-specific equivalent rejection verdict) on >80% of its calibration-log entries in the window.
2. **Auditor degraded** — for gates that admit an explicit-silence verdict (`reverse-auditor`-class gates), the silence rate exceeds >90% of entries in the window.
3. **Zero-rows-despite-routing** — any gate with **zero** entries in its calibration-log for the retro window *while* the settlement queue (`_settlement/queue.json`) shows items routed to that gate during the same window.

**Thresholds (per gate).**
- `gate_unverified_rate > 0.80` over the window → gate-broken
- `auditor_silence_rate > 0.90` over the window → auditor-degraded
- any gate with `calibration_log_rows_in_window == 0 AND settlement_queue_items_routed > 0` → zero-rows-despite-routing

**When green: no prose.**

**When tripped, output (one block per tripped gate × signature combination):** read `skills/retro/templates/step3-8-tripped-outputs.md` § "Judge liveness".

### Check: Calibration state surface (demoted — per-row filter, NOT a `pipeline-degraded` trigger)

**What it does.** Excludes non-`calibrated` rows from `/retro` scoring — the *same* per-row rule `/evolve` Step 5 already applies. It does **not** set `window_state`.

Each scorecard row carries its own `calibration_state` ∈ {`calibrated`, `pre-calibration`, `calibration-failed`}. `/retro` scoring (Step 3 dimensions, Step 3.9 headline) counts only `calibrated` rows; `pre-calibration` and `calibration-failed` rows are filtered out at read time. Rows stay in `rows.jsonl` (append-only).

**Why this is NOT `pipeline-degraded` (the cut).** `pre-calibration` is the *designed steady state* for soft-cal judges (curator, reverse-auditor) that have no calibration runner — see [`architecture/soft-cal-judges-curator-reverse-auditor-are-handle.md`](../../architecture/soft-cal-judges-curator-reverse-auditor-are-handle.md). A judge sitting at `pre-calibration` is expected, not a failure. The earlier version escalated *any* non-`calibrated` judge with rows > 0 to `pipeline-degraded`, which was both:
- **redundant** — `/evolve`'s per-row `calibration_state == "calibrated"` gate already excludes those rows, so the window-level flag protected nothing; and
- **harmful** — it poisoned the *calibrated* judges' rows that merely shared the window, discarding good signal and stamping every real window degraded (curator + reverse-auditor emit on essentially every window by design).

Genuine judge breakage (a gate emitting its rejection verdict on > 80% of runs, or zero-rows-despite-routing) is still caught by the **Judge liveness** check above, which legitimately sets `pipeline-degraded`. Calibration *state* alone never does.

**Never narrates.** No green prose, no tripped block — a silent per-row filter.

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

**When tripped, output:** read `skills/retro/templates/step3-8-tripped-outputs.md` § "Consumer-contradiction routing".

### Step 3.9: Non-compensatory scorecard headline (per template-version, tier:template only)

Complementary to Step 3's dimension scores (subjective, about knowledge delivery) and Step 3.8's pipeline-degraded state (objective, about settlement liveness). Step 3.9 computes a **`pass | weak | fail` headline per template-version** from the seven MVP scorecard metric families using **worst-dimension-wins** — never a weighted average.

**When this step runs.** Only when Step 3.8 did NOT trip `pipeline-degraded`. A degraded window's dimension scores and scorecard cells are non-evidentiary, so computing a per-template headline from them would be misleading. If `window_state == "pipeline-degraded"`, skip Step 3.9 entirely and carry `pipeline-degraded` straight through to the Step 4 journal entry and Step 6 report.

**Input filter (tier-aware).** Read `$KDIR/_scorecards/rows.jsonl`, filter strictly to rows where ALL of:

- **`tier == "template"`** — **required for headline computation.** This is the sole tier eligible for the non-compensatory headline per the canonical Tier Contract. `task-evidence`, `reusable`, `correction`, and `telemetry` rows are excluded regardless of their metric values. Legacy missing-tier rows are treated as `tier: telemetry` (excluded).
- `kind == "scored"` — `consumption-contradiction` and `telemetry` rows are excluded.
- `calibration_state == "calibrated"` — `pre-calibration` and `unknown` rows appear in evidence block for transparency but do not contribute to the headline.
- `template_version` is present in `$KDIR/_scorecards/template-registry.json` — unregistered rows render as `unregistered:<hash>` and are excluded.
- The row's retro window is NOT in the set of `pipeline-degraded` windows (reuses the same filter as `/evolve` Step 5).

**The six MVP metric families.**

| Metric | Granularity | Template scored | Direction |
|---|---|---|---|
| `factual_precision` | claim-local | producer | higher = better |
| `curated_rate` | set-level | producer | higher = better |
| `triviality_rate` | set-level | producer | **lower = better** |
| `omission_rate` | portfolio-level | producer | **lower = better** |
| `observation_promotion_rate` | claim-local | producer | higher = better |

Two of the five families are **inverted** — high values are bad: `triviality_rate` and `omission_rate`.

**Per-metric thresholds (MVP — subject to tuning after early data).**

| Metric | pass (need ≥) | fail (flag if ≤) | Rationale |
|---|---|---|---|
| `factual_precision` | 0.85 | 0.65 | correctness floor |
| `curated_rate` | 0.40 | 0.20 | curator keeps ≥40% of verified candidates |
| `triviality_rate` (inverted) | ≤ 0.30 | ≥ 0.55 | curator drops <55% as trivial |
| `omission_rate` (inverted) | ≤ 0.20 | ≥ 0.45 | portfolio-level miss rate |
| `observation_promotion_rate` | 0.25 | 0.10 | `/remember` capture rate |

Rows between pass and fail thresholds are `weak`. Thresholds are policy — `/evolve` should not mutate them.

**Minimum sample for headline computation.** A metric with fewer than 10 rows aggregated over the retro window is rendered as `insufficient:<N>` and treated as `weak` for headline purposes — not `fail`, because signal is absent rather than negative. Below-sample metrics are listed separately.

**Per-template-version grouping.** Group the filtered rows by `template_version`. Compute each metric's aggregate value (mean across rows) per-template-version. Emit one headline per distinct `template_version`.

**Worst-dimension-wins combination per template_version.** Classify each of the 6 metrics as `{pass | weak | fail | insufficient:<N>}`, then `headline_per_template = worst(per_metric_classification)`: any `fail` → `fail`; no `fail` but any `weak` (including insufficient:<N>) → `weak`; all `pass` → `pass`.

**Never a weighted average.** Load-bearing: a weighted average would let high scores on one metric compensate for low scores on another, exactly the failure mode the non-compensatory headline exists to prevent. A template with perfect factual_precision (0.95) and terrible omission_rate (0.60) is `fail`, not `weak-but-close-to-pass`.

**Report shape (per template-version).** Read `skills/retro/templates/step3-telemetry-outputs.md` — section "Step 3.9 — Scorecard headline per template-version" — for the per-template-version output block, the all-filtered fallback line, and the warmup block.

**Journal persistence.** The headline goes into the retro journal entry (Step 4) under a `scorecard_headline` field in `--scores` — read `skills/retro/templates/emit-commands.md` § "Step 4 / 3.9 — scorecard_headline journal field" for the JSON shape. So `/evolve` can read per-template state without re-running Step 3.9. `/evolve` ranks templates by harmonic mean for mutation prioritization (per plan). Headline and harmonic-mean ranking are distinct — headline is the pass/weak/fail gate; harmonic mean orders within a failing set.

**Invariant.** `/evolve` reads `scorecard_headline` to gate template mutations: a `fail` template can be edited from evidence in the current window (if it also passes the Step 5 citation gate); a `pass` template should not be edited from this window absent a specific failing-metric citation; a `weak` template is editable but deprioritized. `/evolve` does not re-derive these verdicts.

### Step 4: Write Journal Entry (retro dimension scores)

**Mandatory.**

Two shapes depending on `window_state` from Step 3.8 — read `skills/retro/templates/emit-commands.md` § "Step 4 — Retro dimension-score journal write" for both `lore journal write` invocations.

**When `window_state == "pipeline-degraded"`:** dimension scores are still written (for trend analysis) but the headline prose leads with `pipeline-degraded`. The `window_state` + `tripped_checks` fields make the degraded status queryable by `/evolve`.

**When `window_state != "pipeline-degraded"` (normal window):** observation carries 1-5 scores per dimension plus key finding + actionable gap; `--scores` carries dimensional values, `scorecard_headline`, and `scorecard_deltas` per tier.

### Step 4a: Behavioral-health journal entry

**Mandatory when Step 3.7 ran.** Persists the rotation selection and answers into the journal so tuning has a queryable trail. Separate entry (distinct `--role`) so longitudinal queries filter cleanly from dimension-score entries.

Read `skills/retro/templates/emit-commands.md` § "Step 4a — Behavioral-health journal write" for the `lore journal write` invocation. `Checks:` lists the 4 selected check numbers (3 random from 1–6 plus Check 7). One `C<n>: <answer>` segment per selected check, in numeric order. No score fields.

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

Read `skills/retro/templates/emit-commands.md` § "Step 5 — Evolution-suggestion journal write" for the `lore journal write` invocation. One entry per suggestion. 2–4 sentences each.

**CC-05 closed loop invariant.** `/retro` → `lore journal write --role retro-evolution` → `/evolve` Step 3 reads exclusively this role (and `self-test-evolution`) → `/evolve` applies edits → `/evolve` Step 7.5 bumps template-version → next `/retro` A/B compares pre/post.

**`/retro` never edits files directly.** The only mutation path is via journal entries that `/evolve` reads. If a future /retro step proposes a direct file edit, it has broken the closed loop — reject the change.

### Step 6: Report

When emitting the report, read `skills/retro/templates/step6-report.md` for the two output templates (pipeline-degraded variant + normal-window variant). Branch on `window_state` from Step 3.8.

**When `window_state == "pipeline-degraded"`:** emit the pipeline-degraded variant — tripped-check blocks lead, dimension scores recorded but non-headline, evolution suggestions logged but won't be applied.

**When `window_state != "pipeline-degraded"` (normal window):** emit the normal-window variant — scorecard-first shape with deltas + headline first, dimension scores relegated to narrative coda, then Step 3.5 memory telemetry, Step 3.5a judgment-class routing attribution, Step 2.9 scale signals, Step 2b.6 channel-contract flags (when fired), Step 3.7 behavioral-health coda.

**Section order is load-bearing.** The delta surface leads because it is the actionable signal. The headline follows because it is the settlement verdict. Dimension scores come last because they're longitudinal context, not primary signal. Reversing this order would re-establish the dimension-score-as-headline pattern that was explicitly retired.

**First-retro / zero-delta-window case.** If Step 3.0 reported "first eligible window — no delta baseline", skip the delta block and lead with the headline block. The narrative coda still appears at the end.

**Warm-up case.** If Step 3.9 reported `warmup: awaiting-template-tier-rows`, the headline block shows the warm-up line and individual metrics' `insufficient:<N>` status. The rest of the report (deltas, dimension scores, telemetry, behavioral-health) runs normally.
