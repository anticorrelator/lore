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

`resolve_role()` returns exactly `maintainer` or `contributor`. Default when no config is set: `contributor`. See `scripts/lib.sh:112` for precedence: `$LORE_ROLE` env var → per-repo `$KDIR/config.json` → user-level `~/.lore/config/settings.json` → default `contributor`.

**Section routing table:**

| Section | contributor | maintainer |
|---|---|---|
| Steps 1–9 (base pipeline) | render | render |
| "Maintainer path" section (below) | **skip entirely** | render |
| `--pooled` mode | rejects with `requires role=maintainer` | render |
| `--shrink` mode | rejects with `requires role=maintainer` | render |

**How to render for contributors:** execute Steps 1–9 with only local-journal inputs. Do not surface the "Maintainer path" section in output. When a contributor invokes `--pooled` or `--shrink`, reject with `requires role=maintainer` and stop.

**How to render for maintainers:** execute Steps 1–9 normally, then offer the "Maintainer path" sections (`--pooled`, `--shrink`) as additional modes. The base pipeline is identical in both roles — it's the federation-specific modes that differ.

**Why skip instead of conditional execution:** contributor sessions that see the "Maintainer path" text risk agent-template drift — an agent might infer "I should consider the pooled mode" from reading it, then take an action that fails at the role gate further down. Skipping the section entirely keeps contributor prompts focused on what they can do and removes invisible affordances.

Task-54 moves hard rejection of maintainer-only verbs up to the `cli/lore` dispatch layer, so by the time a non-maintainer reaches this skill, the flow is already contributor-only. This section documents the intent; the CLI is the enforcement.

### Step 1: Resolve Knowledge Directory

```bash
lore resolve
```

Set `KNOWLEDGE_DIR` to the result.

### 1a. Maintainer push-path preflight (maintainer only, once per session)

When `role == "maintainer"`, run the safety backstop before any template-mutating work. This surfaces a non-writable `origin` (SSH key expired, remote revoked, network partition, fork-only access) *before* the operator commits edits locally that the federation will never see.

```bash
# Session-scoped marker — adjust the directory to match your tmp convention.
PREFLIGHT_MARKER="${TMPDIR:-/tmp}/lore-maintainer-preflight.$$"

bash ~/.lore/scripts/maintainer-preflight.sh \
  --session-marker "$PREFLIGHT_MARKER" \
  --repo-dir "$(pwd)" 2>&1 || true
```

`maintainer-preflight.sh`:
- Exits 0 silently for contributors (this step is effectively a no-op off the maintainer path).
- Short-circuits on subsequent `/evolve` invocations in the same session (the marker file).
- Runs `git push --dry-run origin HEAD` and surfaces the failure reason verbatim when push is not writable.
- **Warns, never blocks.** A maintainer with a read-only origin may still want to run `/evolve` locally — they know their setup. The warning just ensures the push-path failure is visible.

Surface any warning to the operator before proceeding. Do not proceed to Step 2 if a push-path warning appears; confirm the operator wants to continue despite the warning.

### Step 2: Find the Last /evolve Run

Determine the cutoff date for suggestions to review. Only suggestions logged *after* the last `/evolve` run are shown — earlier suggestions have already been reviewed.

```bash
lore journal show --role evolve --limit 1
```

If an entry exists, extract its timestamp. Set `SINCE` to that timestamp.

If no `evolve` entry exists, set `SINCE` to the beginning of time (no cutoff — show all accumulated suggestions).

If the user passed `--since <date>`, override `SINCE` with that value.

Report:
```
[evolve] Checking for suggestions since: <SINCE or "all time">
```

### Step 3: Load Pending Suggestions

Read all staged evolution suggestions:

```bash
lore journal show --role retro-evolution --since "$SINCE"
lore journal show --role self-test-evolution --since "$SINCE"
```

Collect all entries returned by both commands. Each entry has the structured format:

```
Target: <file> | Change type: <type> | Section: <section> | Suggestion: <text> | Evidence: <retro finding>
```

If both commands return zero entries, report:
```
[evolve] No pending suggestions. Run /retro or /self-test to generate suggestions.
```
And stop.

Report the count:
```
[evolve] Found N suggestions (M from retro, K from self-test)
```

### Step 4: Parse and Group Suggestions

Parse each observation string using the structured fields:
- **Target** — the file to edit (e.g., `skills/retro/SKILL.md`, `skills/retro/failure-modes.md`, `skills/self-test/SKILL.md`)
- **Change type** — the category of change (e.g., `ceiling-raise`, `new-failure-mode`, `dead-dimension`, `scoring-criteria`, `new-test-dimension`)
- **Section** — the section or step being modified
- **Suggestion** — the proposed change in plain text
- **Evidence** — the retro or self-test finding that motivated this suggestion

Group suggestions by **Target**, then by **Change type** within each target.

Also extract metadata from the journal entry itself: timestamp, work-item (if any), source role.

### Step 5: Scorecard citation gate (evidence filter)

Template-mutating edits require evidence that clears the gate. Apply this step
*before* presenting any suggestion in Step 6. Suggestions that fail all gate
paths are recorded as no-ops, not shown to the user.

**Scope — which suggestions the gate applies to.** Any suggestion whose
target file governs a template (skill bodies, worker prompts, agent files,
ceremony scripts) is a *template-mutating* edit and must clear the gate.
Documentation-only or meta edits (e.g., typo fix in an explanatory comment
that does not change producer behavior) are exempt; if unsure, require the
gate.

**Load the scorecard.** Read `$KDIR/_scorecards/rows.jsonl` and
`$KDIR/_scorecards/template-registry.json`. If `rows.jsonl` does not exist
or is empty, no suggestion can clear the gate this run — proceed to Step 7
with zero approved, reporting `[evolve] no scored rows available; no
template edits applied`.

**Load pipeline-degraded windows.** Read recent `/retro` journal entries
(role `retro`) and collect the set of retro-window identifiers whose
`scores.window_state == "pipeline-degraded"`. Retro entries in Phase 7b
and later carry this field; older entries without it are treated as
**not** degraded. This set is used in the per-suggestion gate below.

**Load consumption-contradiction evidence.** For each work item in the
recent window (matching `SINCE`), read
`$KDIR/_work/<slug>/consumption-contradictions.jsonl` and collect rows with
`status: verified`. These are the claim-retraction gate inputs.

**Never-eligible rows (excluded from all gate paths).** Before evaluating
any gate path, partition `rows.jsonl` and exclude:
- `tier: task-evidence` — task-local claim quality, not template behavior
- `tier: reusable` — promotion quality, not template behavior
- `tier: telemetry` — P2.3-16 anti-coupling invariant; includes missing-tier legacy rows (rows without a `tier` field treated as `tier: telemetry`)
- Any row from a `pipeline-degraded` window

**Evidence-class matrix.** Three gate paths exist. Route each suggestion to
the path matching its `change_type`:

| `change_type` | Gate path | Required evidence |
|---|---|---|
| Any template-behavior change (default) | Primary | `tier: template + kind: scored + calibrated + non-degraded` |
| `doctrine-correction` | Secondary | `tier: correction + kind: scored + calibrated + non-degraded` |
| `claim-retraction` / `falsified-doctrine` | Claim-retraction | `kind: consumption-contradiction + status: verified + non-degraded` |

**Primary gate** (`change_type` not `doctrine-correction`/`claim-retraction`/`falsified-doctrine`):

A supporting row must satisfy ALL:
1. `tier == "template"` (rows from rollup scripts post-migration)
2. `kind == "scored"`
3. `calibration_state == "calibrated"` (pre-calibration rows may be *displayed* in the evidence block for transparency but do not satisfy the gate; `unknown` is always excluded)
4. `template_version` is present in `template-registry.json` (unregistered hashes render as `unregistered:<hash>` and carry no weight)
5. A specific `metric` name and `sample_size` are cited in the suggestion body
6. Row's retro window is **not** pipeline-degraded

If no row satisfies (1)–(6) → `no_op` with reason `no_eligible_template_row`
(or `telemetry_only`, `pre_calibration_only`, `unregistered_template_only`,
`pipeline_degraded_window_only`, `wrong_tier` as applicable).

**Secondary gate** (`change_type: "doctrine-correction"`):

A supporting row must satisfy ALL:
1. `tier == "correction"`
2. `kind == "scored"`
3. `calibration_state == "calibrated"` (or `pre-calibration` with explicit caveat noted in citation)
4. Row's retro window is **not** pipeline-degraded
5. Sample-size minimum is half the primary gate minimum (correction rows reflect targeted interventions)

If no row satisfies → `no_op` with reason `no_eligible_correction_row`.

**Claim-retraction gate** (`change_type: "claim-retraction"` or `"falsified-doctrine"`):

1. At least one `consumption-contradictions.jsonl` row exists with `status: verified` for the relevant commons entry
2. The row's originating window is **not** pipeline-degraded
3. No sample-size minimum — a single verified contradiction is sufficient

If no verified contradiction row exists → `no_op` with reason `no_verified_contradiction`.

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

Report the gate outcome before Step 6:

```
[evolve] Gate: N suggestions — K cleared (M primary, C correction, R retraction), J no-op (reasons: <breakdown>)
```

**Sole-writer invariant (CC-04).** `/evolve` does not write to `rows.jsonl`.
`scripts/scorecard-append.sh` is the only sanctioned writer. If this skill's
suggestions would result in a row being recorded (e.g., a post-application
telemetry ping), route through that script — do not append directly.

### 5a. Sunset clause requirement (additions only)

This sub-step implements the maintainer default path's anti-bloat discipline: template edits that *add* new behavioral requirements must carry a sunset clause naming the metric and threshold under which the addition will be rolled back. Removals do not need a sunset clause — the asymmetric evidence rule from `_research/multi-user-evolution-design.md §6` gives the anti-bloat path lower epistemic burden than the anti-atrophy path.

**Classify each gate-cleared suggestion.**

| Classification | Definition | Sunset required? |
|---|---|---|
| **addition** | Proposes new prose, a new step, a new agent rule, or any text that adds a behavioral constraint. | yes |
| **removal** | Proposes deleting prose, collapsing duplicated sections, retiring a rule, or other anti-bloat work. | no |
| **modification** | Proposes changing existing prose without a net addition of behavioral constraint (e.g., clarifying wording, renaming a field, tightening a threshold). | yes, when it strengthens a constraint; no, when it loosens or clarifies. **When in doubt, require one.** |

**Sunset clause shape.** A sunset clause is a single sentence inside the edit prose that names (a) the metric that motivates the addition, (b) the threshold the metric must clear, and (c) the time or sample-size horizon. Example:

> "Sunset: revert this section if `factual_precision` for `template_id=worker` does not cross 0.80 after 20 scored rows in the configured measurement window."

A sunset clause is load-bearing because `/evolve --shrink` (the maintainer's subtraction pass — see "Maintainer path" section below) reads the clause at its trial-window check. Additions without sunset clauses accumulate silently and are never subtracted — that's exactly the Goodhart failure Phase 9's federation discipline was introduced to prevent.

**Per-suggestion sunset check.** For each suggestion that passed the scored-row citation gate:

1. Classify per the table above. If `addition` or `modification-strengthening`: require a sunset clause.
2. If the suggestion's `Suggestion` field does not already contain a sunset sentence, prompt the authoring agent (or the maintainer at review time in Step 6) to add one. The authoring agent composes the sunset from the same scored row that satisfied the gate — the metric name and sample-size are already attached to the suggestion.
3. If after review the suggestion still lacks a sunset clause, record as `no_op` with reason `missing_sunset` and do not apply in Step 7.

Report:
```
[evolve] Sunset check: K approved (R removals exempt, A additions with sunset, M modifications clarifying), J no-op (missing_sunset: J)
```

**Immediate sunset trigger (consumption-contradiction).** A verified consumption-contradiction against a claim that was *added* via a prior `/evolve` run triggers immediate sunset review for that addition, regardless of its sunset window horizon. Specifically:

1. When loading consumption-contradiction evidence in Step 5 (claim-retraction gate), cross-reference each `contradiction_id` against the current file's `/evolve`-applied additions by matching `knowledge_path` to the addition's target.
2. If any gate-cleared claim-retraction row targets an existing `/evolve` addition, mark that addition for immediate sunset review — do not wait for the stated metric threshold or time horizon to lapse.
3. Present the addition and its contradiction citation to the maintainer in Step 6 under a dedicated section: `[sunset-triggered] <addition summary> — contradicted by <contradiction_id>`.
4. If the maintainer approves removal in Step 6, process as a removal in Step 7 (no sunset clause required for the removal itself — see asymmetric evidence rule above).

This rule closes the feedback loop between the claim-retraction gate and the subtraction affordance: a contradiction that clears the gate should not wait a full measurement window before the addition it falsifies is reviewed.

**Why this lives on the maintainer default path rather than just `--pooled`.** Task-56's plan bullet places the sunset-clause requirement on the *default* maintainer path — not only on pooled aggregate runs — so a single-contributor edit still carries the same subtraction affordance. The maintainer working from local scorecards bears the same bloat risk as the maintainer working from pooled evidence; the sunset clause is evidence-coupled irrespective of input source.

**Cross-reference.** The `--pooled` mode in the "Maintainer path" section restates this requirement in its step-4 rules (see `Mode: /evolve --pooled <aggregate-path>` → "Asymmetric evidence rules"). That restatement stays aligned with Step 5a; any edit here must also update the pooled-mode rules.

### Step 6: Present for Review

For each target file, present gate-cleared suggestions grouped by change
type. One at a time, ask the user to approve or reject each suggestion.

Present each suggestion in this format:

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
─────────────────────────────────────────────
Apply this suggestion? [y/n/skip/quit]
```

- **y** — approved, will apply
- **n** — rejected, will record as rejected
- **skip** — deferred, not recorded (will appear in next `/evolve` run)
- **quit** — stop reviewing; apply what's been approved so far

Track: `approved = []`, `rejected = []`, `skipped = []`, `no_op = []`
(pre-populated by the Step 5 gate).

If the user approves multiple suggestions for the same section of the same file, note that they may conflict — present a brief warning before applying.

**Sunset-triggered additions.** If Step 5a marked any existing `/evolve` addition for immediate sunset review (consumption-contradiction immediate trigger), present these in a dedicated block before the regular suggestion queue:

```
═══════════════════════════════════════════════
SUNSET-TRIGGERED REVIEW
═══════════════════════════════════════════════
[sunset-triggered] <addition summary>
Contradicted by: contradiction_id=<id> | knowledge_path=<path>
Original addition from: <evolve run date>

Remove this addition? [y/n/skip]
```

Approved removals enter `approved` with `change_type: "removal"`. Skipped sunset items enter `skipped`. These are processed in Step 7 alongside normal approved suggestions.

### Step 7: Apply Approved Suggestions

For each approved suggestion, apply the change as a direct file edit.

**Application order:** Process suggestions targeting the same file sequentially (not in parallel) to avoid conflicts.

**Per suggestion:**
1. Read the current content of the target file
2. Locate the section identified by the suggestion's **Section** field
3. Apply the change described in the **Suggestion** field
4. Confirm the edit was applied cleanly

If a suggestion cannot be applied cleanly (e.g., the target section no longer exists, conflicting prior edit in this session), report:
```
[evolve] Could not apply: <suggestion summary> — <reason>. Recording as skipped.
```
Move it to `skipped`.

**Snapshot pre-edit template versions.** Before applying any edit, for each
unique target file, record its current `template_version`:

```bash
PRE_VERSION=$(bash ~/.lore/scripts/template-version.sh <absolute-target-path>)
```

Store these as `pre_versions[<target>] = <hash>`. The Step 7.5 bump step
needs the pre-edit hash for the before→after pair, and this is the last
moment the pre-edit file contents are on disk.

### Step 7.5: Bump Template Versions and Register

Template-mutating edits must bump the producer's `template_version` and
register the new pair so next-cycle scorecard rows against this template
attribute to the post-edit version. Without this step, `/evolve` edits are
invisible to `/retro`'s A/B-next-window comparison — rows keep citing the
pre-edit hash because registration is lazy elsewhere in the system.

Track `bumps = []`.

For each **target file that received at least one applied edit** (edits from
Steps 6/7; skip files that were only rejected/skipped):

1. **Compute the post-edit `template_version`:**
   ```bash
   POST_VERSION=$(bash ~/.lore/scripts/template-version.sh <absolute-target-path>)
   ```
2. **Derive `template_id` from the target path:**
   - For `agents/<name>.md` → `template_id = <name>` (e.g., `agents/worker.md` → `worker`, `agents/reverse-auditor.md` → `reverse-auditor`)
   - For `skills/<name>/SKILL.md` → `template_id = <name>` (e.g., `skills/retro/SKILL.md` → `retro`)
   - For other templates, use the file's basename stem with `.md` stripped.
3. **If `PRE_VERSION == POST_VERSION`, skip.** No-op edits (e.g., whitespace-only reformat reverted by the same Step-7 pass) do not bump. Record `{target, reason: "no-change"}` in `bumps` for the journal.
4. **Register the post-edit pair:**
   ```bash
   bash ~/.lore/scripts/template-registry-register.sh \
     --template-id "<template_id>" \
     --template-version "$POST_VERSION" \
     --template-path "<relative-to-KDIR path, or absolute if outside>" \
     --description "Post-evolve bump: <one-line change summary from approved suggestion>" \
     --json
   ```
   The register helper is INSERT OR IGNORE — a pre-existing `(template_id, template_version)` pair is a silent no-op (status: `"exists"`), which correctly handles the rare case where an edit reverts the template to a prior hash. New pairs land as `status: "registered"`.
5. **Record the bump:** append `{target, template_id, pre_version, post_version, status}` to `bumps`.

Report before moving on:
```
[evolve] Bumped N template versions:
  - <target>: <template_id>@<pre>..<post> (registered | exists)
  - <target>: <template_id>@<pre>..<post> (no-change)
```

**Why this matters.** The registry bump is the link between an `/evolve`
edit and the next retro window's A/B signal. `/retro` computes the
non-compensatory headline per `template_version`; if the post-edit version
is not registered, its rows render as `unregistered:<hash>` and carry no
weight (per `skills/evolve/SKILL.md:106` gate), so the edit never gets
measured for whether it improved the target metric. The bump is therefore
load-bearing, not cosmetic — it is the plumbing that closes the
suggest → apply → measure loop.

**Sole-writer invariant preserved.** This step registers template
*versions*; it does not write to `rows.jsonl`. `scripts/scorecard-append.sh`
remains the sole writer of scorecard rows.

### Step 8: Write Outcome Journal Entry

After all approved suggestions have been applied (or if the user quit early), write a summary entry to the journal:

```bash
lore journal write \
  --observation "Evolve run: N suggestions reviewed. Applied: <count> | Rejected: <count> | Skipped: <count> | No-op (gate): <count> (<reason breakdown>). Applied to: <comma-separated target files>. Bumps: <template_id>@<pre>..<post>, <template_id>@<pre>..<post>, ... Summary: <1-2 sentences on what changed and why>." \
  --context "evolve" \
  --role "evolve"
```

The `Bumps:` field is how the next `/retro` window detects that an edit
landed and has a post-edit `template_version` to A/B against. Emit one
comma-separated entry per registered bump from Step 7.5; omit no-change
entries. If zero bumps occurred (no files edited, or all edits were
no-change), emit `Bumps: none`.

This entry establishes the cutoff for the next `/evolve` run.

If zero suggestions were approved, still write the entry — it records that the review happened and advances the cutoff.

### Step 9: Report

```
[evolve] Done
  Reviewed:    N suggestions
  Applied:     N (to: <files>)
  Rejected:    N
  Skipped:     N (will appear in next run)
  No-op(gate): N (telemetry-only / pre-calibration / unregistered / pipeline-degraded / no scored row)
  Bumps:       N template versions registered (K no-change)
```

If suggestions were applied, list each change briefly and name its
template-version bump alongside:
```
  Changes:
    - skills/retro/SKILL.md: <one-line summary>  [retro@<pre>..<post>]
    - skills/retro/failure-modes.md: <one-line summary>  [retro-failure-modes@<pre>..<post>]
    ...
```

The `<template_id>@<pre>..<post>` annotation is what `/retro` reads next
window to measure whether the edit improved the target metric. Missing
annotations short-circuit the measurement loop.

## Maintainer path (role=maintainer only)

The sections above apply in both roles. The two modes below apply only
when the resolved role is `maintainer` — see `_research/multi-user-evolution-design.md`
for the full federation design and `skills/evolve/SKILL.md` cross-linkage
with `lore retro import | aggregate`.

Role resolution today is inline (read `~/.lore/config/settings.json`
→ `.role`, fall back to per-repo `~/.lore/repos/<repo>/config.json`,
default `contributor`). Task-53 introduces `resolve_role()` in `lib.sh`
and task-54 moves this gate into the CLI dispatch; until those land,
contributors who invoke the maintainer-only modes will see a clear
error from the gate check that opens each mode.

### Mode: `/evolve --pooled <aggregate-path>`

Replace the "Load Pending Suggestions" (Step 3) and "Scorecard citation
gate" (Step 5) inputs with a pooled aggregate. Everything else — user
review (Step 6), application (Step 7), version bump (Step 7.5), journal
and report — runs identically.

1. **Role gate.** If resolved role is not `maintainer`, exit with
   `requires role=maintainer`. No approval loop runs.
2. **Load the aggregate.** Argument is a path produced by
   `lore retro aggregate` (JSON shape: `{generated_at, source_bundles,
   contributors, groups: [{template_id, template_version, metric, tag,
   tier, total_n, contributor_count, row_weighted_mean,
   contributor_balanced_mean, by_contributor}, ...]}`).
   The `tier` field is required in the aggregate output — `lore retro aggregate`
   must propagate `tier` from its source `rows.jsonl` rows so that `--pooled`
   filtering is tier-aware. Aggregate files without a `tier` field on each group
   are treated as `tier: telemetry` (missing-tier legacy policy) and are
   excluded from both pools below.
3. **Filter groups by tag and tier.** Only `tag == "convergent"` groups drive
   template edits. Within convergent groups, apply tier-based routing:
   - **Primary pool:** `tier == "template"` — these drive template-behavior mutations
     (same evidence class as the Step 5 primary gate).
   - **Correction pool:** `tier == "correction"` — these drive doctrine-correction edits
     (same evidence class as the Step 5 secondary gate; half sample-size minimum).
   - **Excluded tiers:** `tier: task-evidence`, `tier: reusable`, `tier: telemetry`,
     and missing-tier groups are never eligible — not even under convergent tag.
   `idiosyncratic` groups (regardless of tier) are listed separately under an
   "ideas queue" — the maintainer may investigate via deferred canary
   but they do not auto-generate suggestions. `mixed` and `insufficient`
   are reported as informational only.
4. **Synthesize per-convergent-group candidate suggestions.** For each
   convergent group, emit one candidate with:
   - `template_id` = group's template_id
   - `template_version` = group's template_version (the base)
   - Evidence citation: convergent across N contributors, n=K scored
     samples, metric mean row-weighted=M_rw, contributor-balanced=M_cb
   - Proposed edit: **the maintainer authors this inline during review**
     — `/evolve --pooled` supplies the evidence but not the edit text.
     The invariant is evidence-cited mutation; the authored edit is a
     human judgment from the aggregated signal.
5. **Asymmetric evidence rules (additions vs. removals).** See the
   anti-bloat mechanisms in `multi-user-evolution-design.md §6`:
   - **Additions** — require a failing `kind == "scored"` metric AND a
     **sunset clause** in the edit prose ("roll back if <metric> doesn't
     improve past <threshold> after <N> samples"). Without a sunset,
     mark the suggestion `no_op` with reason `missing_sunset` and skip.
   - **Removals** — accepted on staleness, duplication, budget-exceeded,
     or failed-trial-window grounds, without a failing-metric
     requirement. The subtraction path is asymmetric by design.
6. **Thresholds.** Convergent groups below the sample threshold
   (research doc §5: `total_n < 15` or `contributor_count < 2`) are
   treated as `insufficient` and excluded from approval, regardless of
   their tag.
7. **Commit trace.** Each applied edit from a pooled aggregate MUST
   include the thin public trace in its commit message (see research
   doc §8):
   ```
   <target-file>: <one-line summary>

   Driven by <window> pooled retro evidence:
   - convergent across <N> contributors
   - n=<K> scored samples
   - <metric> <value_pre> → <value_post> expected (aggregate mean)
   - sunset: revert if <metric> regresses past <threshold> by <deadline>
   ```
   This is the only settlement surface contributors see on aggregate
   edits; it's the substitute for peer-visible retros in the
   maintainer-private-pool topology.

Report line adds: `Pooled: <aggregate-path> (N convergent [P primary/C correction] / M idiosyncratic / K mixed / J insufficient)`.

### Mode: `/evolve --shrink`

Periodic subtraction pass. Proposes **only removes and collapses** —
never new behavioral requirements. Anti-bloat mechanism from
`multi-user-evolution-design.md §6`.

1. **Role gate.** Same as `--pooled`. Contributors cannot invoke.
2. **Inputs, in order:**
   - **Staleness.** Entries in skill/agent files tagged with a sunset
     clause whose evaluation window has expired and whose sunset
     condition (e.g., "metric X didn't improve past Y") was met.
     Extract these from the local journal's `retro-evolution` entries
     and cross-reference to the current template content.
   - **Duplication.** Sections with near-identical wording across
     templates — use a similarity pass on skill/agent markdown. Propose
     a collapse into a shared fragment or cross-reference.
   - **Budget-exceeded.** Template files exceeding a configurable size
     budget (default: 300 lines per skill, 200 per agent). Propose
     compression or section extraction.
   - **Failed trial windows.** Edits whose template-version bump
     triggered a metric decline over the configured measurement window
     (reads `_scorecards/_current.json` and compares pre/post template
     versions). These are **automatic revert candidates** — the sunset
     condition is pre-authored, so revert text is already available from
     the bump commit's trailer.
3. **NO additions permitted.** This mode explicitly cannot propose new
   behavioral requirements, new skill steps, new agent sections, or any
   text that adds a behavioral constraint. If the maintainer wants to
   add, they use plain `/evolve` or `/evolve --pooled`.
4. **Evidence rule asymmetry.** Removals do not require a failing
   `kind == "scored"` metric — staleness, duplication, budget, or a
   failed trial window each suffice on their own. This is the
   asymmetric evidence rule from §6: the anti-bloat path has lower
   epistemic burden than the anti-atrophy path, by design.
5. **Application.** Same approval loop (Step 6), application (Step 7),
   version bump (Step 7.5), journal (Step 8), report (Step 9). Every
   applied removal bumps the target template's version just like an
   addition — `/retro` needs the version bump to measure whether the
   shrink was beneficial (e.g., did the agent become more effective
   without the removed text?).

Report line adds: `Shrink: <N> removes / <M> collapses / <K> reverts applied (budget: <file> @ <lines>/<limit>)`.

### Where these modes read role

Both modes start with an inline role check identical to
`scripts/retro-import.sh`:

```
ROLE="contributor"
[[ -f ~/.lore/config/settings.json ]] && ROLE=$(jq -r '.role // "contributor"' ~/.lore/config/settings.json)
[[ -f "$KDIR/config.json" ]] && ROLE=$(jq -r '.role // ""' "$KDIR/config.json" || echo "$ROLE")
[[ "$ROLE" != "maintainer" ]] && die "requires role=maintainer"
```

Task-53 replaces this inline block with `resolve_role()` from `lib.sh`.
Task-54 moves the gate up one level into `cli/lore` dispatch so the
/evolve skill doesn't have to enforce it itself. Until those land,
each mode's first action is the inline check.
