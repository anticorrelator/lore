---
name: evolve
description: "Review and apply accumulated protocol evolution suggestions from retro and self-test"
user_invocable: true
argument_description: "[--since <date>]"
---

# /evolve Skill

Review evolution suggestions accumulated in the journal from `/retro` and `/self-test` runs. Present them grouped by target for human approval, apply approved suggestions as file edits, and record the outcome.

## Role-based section routing

`/evolve` behaves differently for maintainers vs. contributors. Resolve the operator role first and render ONLY the section matching that role. Sections for other roles should not appear in the output shown to the operator — they are noise that enables irrelevant behavior.

**Resolve role:**

```bash
role=$(bash -c 'source ~/.lore/scripts/lib.sh; resolve_role')
```

`resolve_role()` returns `maintainer` or `contributor` (default `contributor`). Precedence: `$LORE_ROLE` → `$KDIR/config.json` → `~/.lore/config/settings.json` → default. See `scripts/lib.sh:112`.

**Section routing table:**

| Section | contributor | maintainer |
|---|---|---|
| Steps 1–9 (base pipeline) | render | render |
| "Maintainer path" section (below) | **skip entirely** | render |
| `--pooled` mode | rejects with `requires role=maintainer` | render |
| `--shrink` mode | rejects with `requires role=maintainer` | render |

**Contributors:** run Steps 1–9 against local-journal inputs only; never surface the "Maintainer path" section; reject `--pooled`/`--shrink` with `requires role=maintainer`.

**Maintainers:** run Steps 1–9, then offer the "Maintainer path" modes (`--pooled`, `--shrink`). The base pipeline is identical across roles — only the federation modes differ.

**Why skip instead of conditional execution:** contributor sessions that see the "Maintainer path" text risk agent-template drift — an agent might infer "I should consider the pooled mode" from reading it, then take an action that fails at the role gate further down. Skipping the section entirely keeps contributor prompts focused on what they can do and removes invisible affordances.

Task-54 moves maintainer-only rejection up to `cli/lore` dispatch; this section documents the intent until then.

### Step 1: Resolve Knowledge Directory

```bash
lore resolve
```

Set `KNOWLEDGE_DIR` to the result.

### 1a. Maintainer push-path preflight (maintainer only, once per session)

When `role == "maintainer"`, run the safety backstop before any template-mutating work. This surfaces a non-writable `origin` (SSH key expired, remote revoked, network partition, fork-only access) *before* the operator commits edits locally that the federation will never see.

```bash
PREFLIGHT_MARKER="${TMPDIR:-/tmp}/lore-maintainer-preflight.$$"
bash ~/.lore/scripts/maintainer-preflight.sh \
  --session-marker "$PREFLIGHT_MARKER" \
  --repo-dir "$(pwd)" 2>&1 || true
```

`maintainer-preflight.sh` is silent for contributors and short-circuits on re-invocation (marker file). It runs `git push --dry-run origin HEAD` and surfaces the failure verbatim. **Warns, never blocks** — a read-only origin may be intentional.

If a warning appears, surface it and confirm the operator wants to continue before Step 2.

### Step 2: Find the Last /evolve Run

Determine the cutoff date — only suggestions logged *after* the last `/evolve` run are shown.

```bash
lore journal show --role evolve --limit 1
```

Set `SINCE` to the entry's timestamp if present; otherwise to the beginning of time. If `--since <date>` was passed, override with that value.

Report: `[evolve] Checking for suggestions since: <SINCE or "all time">`

### Step 3: Load Pending Suggestions

```bash
lore journal show --role retro-evolution --since "$SINCE"
lore journal show --role self-test-evolution --since "$SINCE"
```

Each entry has the format:

```
Target: <file> | Change type: <type> | Section: <section> | Suggestion: <text> | Evidence: <retro finding>
```

If both commands return zero entries, report `[evolve] No pending suggestions. Run /retro or /self-test to generate suggestions.` and stop.

Otherwise: `[evolve] Found N suggestions (M from retro, K from self-test)`

### Step 4: Parse and Group Suggestions

Parse each observation by structured fields:
- **Target** — file to edit (e.g., `skills/retro/SKILL.md`, `skills/retro/failure-modes.md`)
- **Change type** — change category (e.g., `ceiling-raise`, `new-failure-mode`, `dead-dimension`)
- **Section** — section or step modified
- **Suggestion** — proposed change in plain text
- **Evidence** — the retro/self-test finding motivating it

Group by **Target**, then by **Change type**. Also extract journal metadata: timestamp, work-item, source role.

### Step 5: Scorecard citation gate (evidence filter)

Template-mutating edits require evidence that clears the gate. Apply this step *before* presenting any suggestion in Step 6. Suggestions that fail all gate paths are recorded as no-ops, not shown to the user.

**Scope — which suggestions the gate applies to.** Any suggestion whose target file governs a template (skill bodies, worker prompts, agent files, ceremony scripts) is a *template-mutating* edit and must clear the gate. Documentation-only or meta edits (e.g., typo fix in an explanatory comment that does not change producer behavior) are exempt; if unsure, require the gate.

**Load the scorecard.** Read `$KDIR/_scorecards/rows.jsonl` and `$KDIR/_scorecards/template-registry.json`. If `rows.jsonl` is missing or empty, no suggestion clears the gate — proceed to Step 7 with zero approved, reporting `[evolve] no scored rows available; no template edits applied`.

**Load pipeline-degraded windows.** Read recent `/retro` journal entries (role `retro`) and collect the set of retro-window identifiers whose `scores.window_state == "pipeline-degraded"`. Phase-7b+ retros carry this field; earlier entries are treated as **not** degraded.

**Load consumption-contradiction evidence.** For each work item in the recent window (matching `SINCE`), read `$KDIR/_work/<slug>/consumption-contradictions.jsonl` and collect rows with `status: verified` — these are the claim-retraction gate inputs.

**Never-eligible rows (excluded from all gate paths).** Partition `rows.jsonl` and exclude:
- `tier: task-evidence` — task-local claim quality, not template behavior
- `tier: reusable` — promotion quality, not template behavior
- `tier: telemetry` — P2.3-16 anti-coupling invariant; includes missing-tier legacy rows (rows without a `tier` field treated as `tier: telemetry`)
- Any row from a `pipeline-degraded` window

**Evidence-class matrix.** Four gate paths exist. Route each suggestion to the path matching its `change_type`:

| `change_type` | Gate path | Required evidence |
|---|---|---|
| Any template-behavior change (default) | Primary | `tier: template + kind: scored + calibrated + non-degraded` |
| `doctrine-correction` | Secondary | `tier: correction + kind: scored + calibrated + non-degraded` |
| `claim-retraction` / `falsified-doctrine` | Claim-retraction | `kind: consumption-contradiction + status: verified + non-degraded` |
| `recurring-failure` | Recurring-failure | candidate cluster of ≥3 distinct `work_items` over `(target, change_type)` AND maintainer-accepted in a prior /evolve run (artifact: `_evolve/accepted-clusters.jsonl`) |

**Primary gate** (`change_type` ∉ {`doctrine-correction`, `claim-retraction`, `falsified-doctrine`, `recurring-failure`}):

A supporting row must satisfy ALL:
1. `tier == "template"` (rows from rollup scripts post-migration)
2. `kind == "scored"`
3. `calibration_state == "calibrated"` (pre-calibration rows may *display* in the evidence block for transparency but do not satisfy the gate; `unknown` is always excluded)
4. `template_version` is present in `template-registry.json` (unregistered hashes render as `unregistered:<hash>` and carry no weight)
5. A specific `metric` name and `sample_size` are cited in the suggestion body
6. Row's retro window is **not** pipeline-degraded

If no row satisfies → `no_op` with reason `no_eligible_template_row` (or `telemetry_only`, `pre_calibration_only`, `unregistered_template_only`, `pipeline_degraded_window_only`, `wrong_tier`).

**Secondary gate** (`change_type: "doctrine-correction"`):

Row must satisfy ALL: (1) `tier == "correction"`; (2) `kind == "scored"`; (3) `calibration_state == "calibrated"` (or `pre-calibration` with caveat in citation); (4) window not pipeline-degraded; (5) sample-size minimum is half the primary gate's (correction rows reflect targeted interventions).

If none → `no_op` reason `no_eligible_correction_row`.

**Claim-retraction gate** (`change_type: "claim-retraction"` or `"falsified-doctrine"`):

(1) ≥1 `consumption-contradictions.jsonl` row with `status: verified` for the commons entry; (2) row's window not pipeline-degraded; (3) no sample-size minimum — a single verified contradiction suffices.

If none → `no_op` reason `no_verified_contradiction`.

**Recurring-failure gate** (`change_type: "recurring-failure"`):

A **two-state, two-run lifecycle** over retro-evolution journal rows. Acceptance in run N persists an `accepted_cluster` artifact; the gate in run N+1 reads that artifact to clear the suggestion. Same-run Step 5 re-entry is **NOT** permitted — newly accepted clusters never gate suggestions in the same /evolve invocation that accepted them (per D5e).

Routing-gate properties:

- **Inputs:** `_meta/effectiveness-journal.jsonl` rows with `role == "retro-evolution"` (raw pass); `_evolve/accepted-clusters.jsonl` rows from prior runs (consumption pass); the staged suggestion's `(target, change_type)` key.
- **Success route:** clears when `(target, change_type)` matches an `accepted_cluster` row whose `consumed_at_run_id` is unset; the row is marked consumed for this run.
- **Conservative fallback:** no match → `no_op` reason `no_accepted_cluster`. Does NOT silently re-route to primary/secondary gate (different evidence classes by definition).
- **Lifecycle:** writes to `_evolve/accepted-clusters.jsonl` happen only in Step 6's CLUSTER REVIEW block; this gate path is read-only over that artifact.

**K threshold (candidate-cluster formation, raw pass):**

| K (distinct `work_items`) | Cluster status | /evolve action |
|---|---|---|
| K < 3 | sub-threshold | discard; no suggestion presented |
| K == 3 | candidate cluster | present in Step 6 CLUSTER REVIEW for maintainer adjudication |
| K > 3 | candidate cluster | present in Step 6 CLUSTER REVIEW (member list shows all) |

K=3 is the smallest threshold deserving "recurring" — K=2 is anecdote; the scorecard primary-gate threshold (K=7) would conflate evidence classes. K counts *distinct* `work_item` values (not raw row count): one work item with 5 retro-evolution rows on the same target is K=1, not K=5.

**Two-run lifecycle (state table):**

| Run | Step 5 inputs | Step 6 action | Persisted artifact |
|---|---|---|---|
| Run N | retro-evolution rows scanned for K≥3 candidate clusters | maintainer accepts/edits/splits/rejects each candidate; accepted clusters written to `_evolve/accepted-clusters.jsonl` | `accepted_cluster` rows with `accepted_at_run_id` set, `consumed_at_run_id` unset |
| Run N+1 | `_evolve/accepted-clusters.jsonl` rows with `consumed_at_run_id` unset | each consumed cluster gates exactly one staged `recurring-failure` suggestion | `consumed_at_run_id` populated on consumed rows |

The two-run delay is load-bearing: it forces a human-in-loop pause between cluster identification and template mutation, so a same-session burst of similar retros cannot self-amplify into a binding edit.

**Two-pass scan over retro-evolution rows:**

1. **Raw clustering pass.** Rows whose `context` does **NOT** start with `retro-backfill:`. Bucket by `(Target, Change type)`; for each bucket count distinct `work_item` values; emit candidate when K ≥ 3.
2. **Pre-clustered consumption pass.** Rows whose `context` starts with `retro-backfill:` (Phase 5 backfill artifacts). Each backfill row is already a cluster — treat its observation as one candidate without re-bucketing. K threshold does not re-apply.

The two passes produce a unified candidate-cluster list for Step 6.

**Accepted-cluster artifact format.** When the maintainer accepts a candidate in Step 6 CLUSTER REVIEW, append a row to `$KDIR/_evolve/accepted-clusters.jsonl`:

```json
{
  "cluster_id": "<sha256[:16] of (target + change_types[] sorted + work_items[] sorted)>",
  "target": "<file path>",
  "change_types": ["<change_type>", ...],
  "work_items": ["<work_item slug>", ...],
  "journal_row_refs": [{"timestamp": "<iso>", "work_item": "<slug>"}, ...],
  "accepted_at": "<iso8601 timestamp>",
  "accepted_at_run_id": "<evolve run id from Step 8 journal cutoff>",
  "accepted_by_maintainer_decision": "merge" | "edit" | "split",
  "consumed_at_run_id": null
}
```

`consumed_at_run_id` starts `null` and is updated to the consuming run's id when the gate fires in run N+1. Sole writer: `bash ~/.lore/scripts/accepted-cluster-append.sh` (Phase 5 dependency) — `/evolve` does NOT write the file directly outside that script.

**Do NOT:**
- silently fall back to the primary or secondary gate when an accepted cluster is missing — emit `no_op` with reason `no_accepted_cluster` and surface the reason in Step 9 reporting.
- re-enter Step 5 in the same invocation after Step 6 CLUSTER REVIEW writes accepted-cluster rows; the two-run lifecycle is the design.
- treat raw-clustering pass rows whose `context` starts with `retro-backfill:` as raw — they belong to the consumption pass.
- bucket on `target` alone; the bucketing key is `(target, change_type)`.

**Attach citation.** For suggestions that clear the primary or secondary gate:

```
Citation: kind=scored | tier=<tier> | template=<template_id>@<template_version>
          metric=<metric> | value=<value> | sample_size=<n>
          window=<window_start>..<window_end>
```

For claim-retraction, attach the contradiction ID:
```
Citation: kind=consumption-contradiction | contradiction_id=<id>
          knowledge_path=<path> | status=verified
```

For recurring-failure, attach the accepted-cluster reference:
```
Citation: kind=accepted-cluster | cluster_id=<id> | target=<file>
          change_types=<comma-list> | work_items=<comma-list>
          K=<distinct-work-item-count> | accepted_at_run_id=<run_id>
```

Report the gate outcome before Step 6:

```
[evolve] Gate: N suggestions — K cleared (M primary, C correction, R retraction, F recurring-failure), J no-op (reasons: <breakdown>)
```

**Sole-writer invariant (CC-04).** `/evolve` does not write to `rows.jsonl`. `scripts/scorecard-append.sh` is the only sanctioned writer. Any post-application telemetry row routes through that script — do not append directly.

### 5a. Sunset clause requirement (additions only)

This sub-step implements the maintainer default path's anti-bloat discipline: template edits that *add* new behavioral requirements must carry a sunset clause naming the metric and threshold under which the addition will be rolled back. Removals do not need a sunset clause — the asymmetric evidence rule from `_research/multi-user-evolution-design.md §6` gives the anti-bloat path lower epistemic burden than the anti-atrophy path.

**Classify each gate-cleared suggestion.**

| Classification | Definition | Sunset required? |
|---|---|---|
| **addition** | New prose, step, agent rule, or any text adding a behavioral constraint. | yes |
| **removal** | Deletes prose, collapses duplicates, retires a rule, or other anti-bloat work. | no |
| **modification** | Changes existing prose without net addition of behavioral constraint (clarifying wording, field rename, threshold tightening). | yes when it strengthens a constraint; no when it loosens or clarifies. **When in doubt, require one.** |

**Sunset clause shape.** A sunset clause is a single sentence inside the edit prose that names (a) the metric that motivates the addition, (b) the threshold the metric must clear, and (c) the time or sample-size horizon. Example:

> "Sunset: revert this section if `factual_precision` for `template_id=worker` does not cross 0.80 after 20 scored rows in the configured measurement window."

A sunset clause is load-bearing because `/evolve --shrink` (the maintainer's subtraction pass — see "Maintainer path" section below) reads the clause at its trial-window check. Additions without sunset clauses accumulate silently and are never subtracted — that's exactly the Goodhart failure Phase 9's federation discipline was introduced to prevent.

**Per-suggestion sunset check.** For each gate-cleared suggestion:

1. Classify per the table above. `addition` or `modification-strengthening` requires a sunset clause.
2. If absent, prompt the authoring agent (or maintainer at Step 6 review) to add one. The author composes from the gate-satisfying row — metric name and sample-size are already attached.
3. Still absent after review → `no_op` reason `missing_sunset`; do not apply in Step 7.

Report: `[evolve] Sunset check: K approved (R removals exempt, A additions with sunset, M modifications clarifying), J no-op (missing_sunset: J)`

**Immediate sunset trigger (consumption-contradiction).** A verified consumption-contradiction against a claim that was *added* via a prior `/evolve` run triggers immediate sunset review for that addition, regardless of its sunset window horizon:

1. When loading consumption-contradiction evidence (claim-retraction gate), cross-reference each `contradiction_id` against the file's prior `/evolve`-applied additions by `knowledge_path` → target.
2. Any match marks the addition for immediate sunset review — do not wait for the metric threshold or time horizon.
3. Present in Step 6 under a dedicated section: `[sunset-triggered] <addition summary> — contradicted by <contradiction_id>`.
4. Maintainer-approved removal processes in Step 7 as a removal (no sunset clause for the removal itself, per asymmetric rule).

This closes the feedback loop between the claim-retraction gate and the subtraction affordance — a falsifying contradiction should not wait a full measurement window before the addition it falsifies is reviewed.

**Why this lives on the default maintainer path, not just `--pooled`.** Task-56 places the requirement on the *default* path so a single-contributor edit carries the same subtraction affordance as a pooled aggregate. Local-scorecard maintainers bear the same bloat risk; sunset is evidence-coupled irrespective of input source.

**Cross-reference.** The `--pooled` mode restates this requirement in its step-4 rules ("Asymmetric evidence rules"). Edits here must also update the pooled-mode restatement.

### Step 6: Apply Gate-Cleared Suggestions (Agent-Primary, Human Escalation on Threshold/Abstain)

For each target file, the lead is the primary applier of gate-cleared suggestions. Iterate the queue; per suggestion emit one verdict: `apply`, `reject`, or `escalate`. `apply` and `reject` proceed without `AskUserQuestion`; `escalate` routes through it for human adjudication. Report applied/rejected/escalated counts in the run summary so the user can object after the fact.

**Verdict criteria:**

- **`apply`** — clears Step 5, evidence cites a calibrated source, no escalation threshold crossed. Default for gate-cleared suggestions whose evidence and scope match the cited metric. Enters `approved` with rationale logged.
- **`reject`** — clears Step 5 but the lead judges the change wrong or premature against the cited evidence (e.g., the metric trend is genuine but the proposed edit doesn't address it). Enters `rejected` with rationale logged.
- **`escalate`** — lead cannot confidently apply or reject. Route through `AskUserQuestion` — the single canonical trigger for human prompts in Step 6.

**Escalation thresholds (when `escalate` is required, not optional):** the lead MUST escalate when any of:

1. **Destructive change** — removes or rewrites load-bearing prose (binding gate, contract clause, routing rule), vs. clarifying/extending. Step 4 change-type is the first-cut signal: `removal`/`rewrite` cross; `addition`/`clarification`/`re-ordering` do not by default.
2. **High-confidence-drop** — would replace an existing canonical statement evidenced at high confidence (e.g., knowledge entry `confidence: high`, or a `/evolve` addition with an active sunset). The new evidence must exceed the existing weight; if uncertain, escalate.
3. **Abstain** — cannot decide between apply and reject (ambiguous trend, scope spans two change types, etc.). Catch-all escalation reason; one-sentence rationale.

(1) and (2) are named so a future evolution agent can predict the surface; (3) is free-form. All three feed the same `AskUserQuestion` path.

**When escalating, present the suggestion in this format:**

```
─────────────────────────────────────────────
Target:      <file>
Change type: <type>
Section:     <section>
From:        <timestamp> (<source role>)
Evidence:    <evidence text>
Citation:    kind=scored | template=<template_id>@<template_version>
             metric=<metric> value=<value> sample_size=<n>
             window=<window_start>..<window_end>
             calibration_state=<state>

Suggestion:
  <suggestion text>

Escalation reason: <destructive-change | high-confidence-drop | abstain>
Lead's reading: <one-line context the lead would offer if asked>
─────────────────────────────────────────────
Apply this suggestion? [y/n/skip/quit]
```

- **y** — approved by human, will apply
- **n** — rejected by human, will record as rejected
- **skip** — deferred, not recorded (will appear in next `/evolve` run)
- **quit** — stop reviewing; apply what's been approved so far

Track: `approved`, `rejected`, `skipped`, `escalated`, `no_op` (pre-populated by Step 5). Each apply/reject without `AskUserQuestion` records the rationale; each escalate carries reason + human resolution.

Multiple suggestions for the same section may conflict — warn before applying (lead-attested; not an escalation unless the conflict itself is destructive).

**Sunset-triggered additions.** If Step 5a marked any existing `/evolve` addition for immediate sunset review (consumption-contradiction trigger), present these in a dedicated block before the regular queue:

```
═══════════════════════════════════════════════
SUNSET-TRIGGERED REVIEW
═══════════════════════════════════════════════
[sunset-triggered] <addition summary>
Contradicted by: contradiction_id=<id> | knowledge_path=<path>
Original addition from: <evolve run date>

Remove this addition? [y/n/skip]
```

Approved removals enter `approved` with `change_type: "removal"`. Skipped sunset items enter `skipped`. Both flow into Step 7 with normal approved suggestions.

**CLUSTER REVIEW (recurring-failure candidates).** Present candidate clusters from Step 5.x (raw-pass K≥3 buckets OR consumption-pass backfill payloads) AFTER the per-suggestion queue completes. Sole human-in-loop surface for cluster identity — no separate `lore` CLI for cluster merging (per D8). One cluster at a time:

```
═══════════════════════════════════════════════
CLUSTER REVIEW
═══════════════════════════════════════════════
Candidate cluster: target=<file> | change_type=<type> | K=<distinct-work-item-count>

Members:
  <timestamp> | <work_item slug> | <one-sentence excerpt from observation>
  <timestamp> | <work_item slug> | <one-sentence excerpt from observation>
  <timestamp> | <work_item slug> | <one-sentence excerpt from observation>
  ...
Representative Evidence: <Evidence line from one member, verbatim>

Merge cluster as recurring-failure suggestion? [y/edit/split/n]
```

- **y** — accept verbatim; append `accepted_cluster` row (decision: `merge`).
- **edit** — accept a maintainer-edited member set before persisting (decision: `edit`).
- **split** — accept as ≥2 sub-clusters; one `accepted_cluster` row per (decision: `split`).
- **n** — reject; no row written. Candidate does not re-appear unless future rows push K back above threshold from a fresh distinct work_item.

Acceptance side effects and the two-run lifecycle are stated canonically in Step 5's Recurring-failure gate; writes happen here, consumption in run N+1, no same-run re-entry.

Append via the sole-writer script:

```bash
bash ~/.lore/scripts/accepted-cluster-append.sh \
  --target "<file>" \
  --change-types "<comma-list>" \
  --work-items "<comma-list>" \
  --decision "merge|edit|split" \
  --accepted-at-run-id "<run_id>"
```

(`accepted-cluster-append.sh` lands with Phase 5; until then, the CLUSTER REVIEW block reports candidates but the persistence step is a stub.)

### Step 7: Apply Approved Suggestions

For each approved suggestion, apply the change as a direct file edit.

**Application order:** sequential per file (not parallel) to avoid conflicts.

**Per suggestion:**
1. Read the current target file
2. Locate the **Section**
3. Apply the **Suggestion**
4. Confirm the edit applied cleanly

If unclean (section gone, conflicting prior edit), report `[evolve] Could not apply: <summary> — <reason>. Recording as skipped.` and move to `skipped`.

**Snapshot pre-edit template versions.** Before any edit, for each unique target file record:

```bash
PRE_VERSION=$(bash ~/.lore/scripts/template-version.sh <absolute-target-path>)
```

Store as `pre_versions[<target>] = <hash>`. Step 7.5 needs the pre-edit hash for the before→after pair — this is the last moment the pre-edit file is on disk.

### Step 7.5: Bump Template Versions and Register

Template-mutating edits must bump the producer's `template_version` and register the new pair so next-cycle scorecard rows against this template attribute to the post-edit version. Without this step, `/evolve` edits are invisible to `/retro`'s A/B-next-window comparison — rows keep citing the pre-edit hash because registration is lazy elsewhere in the system.

Track `bumps = []`.

For each **target file that received at least one applied edit** (skip rejected/skipped-only files):

1. **Compute post-edit version:**
   ```bash
   POST_VERSION=$(bash ~/.lore/scripts/template-version.sh <absolute-target-path>)
   ```
2. **Derive `template_id` from path:**
   - `agents/<name>.md` → `<name>` (e.g., `agents/worker.md` → `worker`)
   - `skills/<name>/SKILL.md` → `<name>` (e.g., `skills/retro/SKILL.md` → `retro`)
   - Otherwise: basename stem with `.md` stripped.
3. **If `PRE_VERSION == POST_VERSION`, skip** — no-op edits (e.g., reverted whitespace) do not bump. Record `{target, reason: "no-change"}` in `bumps`.
4. **Register the post-edit pair:**
   ```bash
   bash ~/.lore/scripts/template-registry-register.sh \
     --template-id "<template_id>" \
     --template-version "$POST_VERSION" \
     --template-path "<relative-to-KDIR path, or absolute if outside>" \
     --description "Post-evolve bump: <one-line change summary from approved suggestion>" \
     --json
   ```
   INSERT OR IGNORE: pre-existing pair → `status: "exists"` (handles rare revert-to-prior-hash); new pair → `status: "registered"`.
5. **Append** `{target, template_id, pre_version, post_version, status}` to `bumps`.

Report:
```
[evolve] Bumped N template versions:
  - <target>: <template_id>@<pre>..<post> (registered | exists)
  - <target>: <template_id>@<pre>..<post> (no-change)
```

**Why this matters.** The registry bump is the link between an `/evolve` edit and the next retro window's A/B signal. `/retro` computes the non-compensatory headline per `template_version`; if the post-edit version is not registered, its rows render as `unregistered:<hash>` and carry no weight..., so the edit never gets measured for whether it improved the target metric. The bump is therefore load-bearing, not cosmetic — it is the plumbing that closes the suggest → apply → measure loop.

### Step 8: Write Outcome Journal Entry

After all approved suggestions are applied (or the user quit early), write a summary:

```bash
lore journal write \
  --observation "Evolve run: N suggestions reviewed. Applied: <count> | Rejected: <count> | Skipped: <count> | No-op (gate): <count> (<reason breakdown>). Applied to: <comma-separated target files>. Bumps: <template_id>@<pre>..<post>, <template_id>@<pre>..<post>, ... Summary: <1-2 sentences on what changed and why>." \
  --context "evolve" \
  --role "evolve"
```

The `Bumps:` field is how the next `/retro` window detects that an edit landed and has a post-edit `template_version` to A/B against. Emit one comma-separated entry per registered bump from Step 7.5; omit no-change entries. If zero bumps occurred, emit `Bumps: none`.

This entry establishes the cutoff for the next `/evolve` run. Write it even if zero suggestions were approved — it records that the review happened and advances the cutoff.

### Step 9: Report

```
[evolve] Done
  Reviewed:    N suggestions
  Applied:     N (to: <files>)
  Rejected:    N
  Skipped:     N (will appear in next run)
  No-op(gate): N (telemetry-only / pre-calibration / unregistered / pipeline-degraded / no scored row / no accepted cluster)
  Bumps:       N template versions registered (K no-change)
```

If suggestions were applied, list each change and its template-version bump:
```
  Changes:
    - skills/retro/SKILL.md: <one-line summary>  [retro@<pre>..<post>]
    - skills/retro/failure-modes.md: <one-line summary>  [retro-failure-modes@<pre>..<post>]
    ...
```

The `<template_id>@<pre>..<post>` annotation is what `/retro` reads next window to measure whether the edit improved the target metric. Missing annotations short-circuit the measurement loop.

## Maintainer path (role=maintainer only)

The sections above apply in both roles. The two modes below apply only when role is `maintainer` — see `_research/multi-user-evolution-design.md` for the full federation design and cross-linkage with `lore retro import | aggregate`.

Role resolution is inline today (`~/.lore/config/settings.json` → `.role`, then per-repo `$KDIR/config.json`, default `contributor`). Task-53 introduces `resolve_role()` in `lib.sh`; task-54 moves the gate into CLI dispatch. Until then, each mode's first action is the inline check; contributors invoking these modes hit a clear gate error.

### Mode: `/evolve --pooled <aggregate-path>`

Replaces Step 3 (Load Pending Suggestions) and Step 5 (gate) inputs with a pooled aggregate. Everything else (Steps 6, 7, 7.5, 8, 9) runs identically.

1. **Role gate.** Non-maintainer → exit `requires role=maintainer`. No approval loop.
2. **Load aggregate.** Path produced by `lore retro aggregate`. JSON: `{generated_at, source_bundles, contributors, groups: [{template_id, template_version, metric, tag, tier, total_n, contributor_count, row_weighted_mean, contributor_balanced_mean, by_contributor}, ...]}`. The `tier` field is required — `lore retro aggregate` must propagate it from source rows so filtering is tier-aware. Missing-`tier` groups are treated as `tier: telemetry` and excluded from both pools.
3. **Filter by tag and tier.** Only `tag == "convergent"` drives edits. Within convergent:
   - **Primary pool:** `tier == "template"` — same evidence class as Step 5 primary gate.
   - **Correction pool:** `tier == "correction"` — same as Step 5 secondary gate (half sample-size minimum).
   - **Excluded:** `task-evidence`, `reusable`, `telemetry`, missing-tier — never eligible even when convergent.

   `idiosyncratic` groups go to an "ideas queue" (maintainer may investigate via deferred canary; no auto-suggestion). `mixed` and `insufficient` are informational only.
4. **Synthesize candidates per convergent group.** Emit one with:
   - `template_id`, `template_version` (base) from the group
   - Citation: convergent across N contributors, n=K scored samples, mean row-weighted=M_rw, contributor-balanced=M_cb
   - Proposed edit: **maintainer authors inline during review.** `--pooled` supplies evidence, not edit text. Invariant: evidence-cited mutation; the edit text is human judgment from the aggregated signal.
5. **Asymmetric evidence rules (additions vs. removals).** See the anti-bloat mechanisms in `multi-user-evolution-design.md §6`: Additions — require a failing `kind == 'scored'` metric AND a sunset clause in the edit prose ("roll back if <metric> doesn't improve past <threshold> after <N> samples"). Without a sunset, mark the suggestion `no_op` with reason `missing_sunset` and skip. Removals — accepted on staleness, duplication, budget-exceeded, or failed-trial-window grounds, without a failing-metric requirement. The subtraction path is asymmetric by design.
6. **Thresholds.** Convergent groups with `total_n < 15` or `contributor_count < 2` (research §5) → `insufficient`; excluded from approval regardless of tag.
7. **Commit trace.** Each applied edit MUST include the thin public trace (research §8):
   ```
   <target-file>: <one-line summary>

   Driven by <window> pooled retro evidence:
   - convergent across <N> contributors
   - n=<K> scored samples
   - <metric> <value_pre> → <value_post> expected (aggregate mean)
   - sunset: revert if <metric> regresses past <threshold> by <deadline>
   ```
   This is the only settlement surface contributors see on aggregate edits — substitute for peer-visible retros in the maintainer-private-pool topology.

Report line adds: `Pooled: <aggregate-path> (N convergent [P primary/C correction] / M idiosyncratic / K mixed / J insufficient)`.

### Mode: `/evolve --shrink`

Periodic subtraction pass. Proposes only removes and collapses — never new behavioral requirements. Anti-bloat mechanism from `multi-user-evolution-design.md §6`.

1. **Role gate.** Same as `--pooled`. Contributors cannot invoke.
2. **Inputs, in order:**
   - **Staleness.** Sunset-tagged entries whose evaluation window expired and whose condition was met. Extract from local journal `retro-evolution` entries; cross-reference current template content.
   - **Duplication.** Near-identical wording across templates (similarity pass on skill/agent markdown). Propose collapse into a shared fragment or cross-reference.
   - **Budget-exceeded.** Files past size budget (default: 300 lines per skill, 200 per agent). Propose compression or extraction.
   - **Failed trial windows.** Bumps whose post-edit version showed metric decline over the measurement window (`_scorecards/_current.json`). **Automatic revert candidates** — sunset condition is pre-authored, revert text already in the bump commit trailer.
3. **NO additions permitted.** This mode explicitly cannot propose new behavioral requirements, new skill steps, new agent sections, or any text that adds a behavioral constraint. To add, use plain `/evolve` or `/evolve --pooled`.
4. **Evidence rule asymmetry.** Removals follow the asymmetric-evidence rule stated canonically in Step 5a: staleness, duplication, budget, or a failed trial window each suffice on their own; no failing `kind == "scored"` metric required. Anti-bloat has lower epistemic burden than anti-atrophy by design.
5. **Application.** Reuses Steps 6, 7, 7.5, 8, 9. Every removal bumps the target's version like an addition — `/retro` needs the bump to measure whether the shrink helped (e.g., did the agent become more effective without the removed text?).

Report line adds: `Shrink: <N> removes / <M> collapses / <K> reverts applied (budget: <file> @ <lines>/<limit>)`.

### Where these modes read role

Both modes open with an inline check identical to `scripts/retro-import.sh`:

```
ROLE="contributor"
[[ -f ~/.lore/config/settings.json ]] && ROLE=$(jq -r '.role // "contributor"' ~/.lore/config/settings.json)
[[ -f "$KDIR/config.json" ]] && ROLE=$(jq -r '.role // ""' "$KDIR/config.json" || echo "$ROLE")
[[ "$ROLE" != "maintainer" ]] && die "requires role=maintainer"
```

Task-53 replaces this with `resolve_role()` from `lib.sh`; task-54 moves the gate into `cli/lore` dispatch. Until then, each mode performs the inline check.
