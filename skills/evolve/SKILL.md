---
name: evolve
description: "Review and apply accumulated protocol evolution suggestions from retro and self-test"
user_invocable: true
argument_description: "[--since <date>]"
---

# /evolve Skill

Turn accumulated retro and self-test suggestions into evidence-gated, lead-authored protocol changes. Two deterministic verbs hold the bookkeeping envelope: `prepare` reconstructs and freezes the review queue; `file` preserves the lead's decisions and recovers their sanctioned sinks. The evolve lead alone decides what a proposal deserves and authors every target-file edit.

The authority boundary is load-bearing:

- The mechanism owns cutoff reconstruction, source coverage, parsing, grouping, eligibility arithmetic, canonical serialization, lifecycle writes, version provenance, recovery, and outcome filing.
- The lead owns `apply | reject | escalate`, escalation judgment, recurring-cluster dispositions, edit text, and direct edit application.
- Eligibility is evidence sufficiency, never a recommendation. Neither verb selects, ranks, synthesizes, or applies a proposal.

## Role-based routing

Resolve the operator role before rendering the workflow:

```bash
role=$(bash -c 'source ~/.lore/scripts/lib.sh; resolve_role')
```

| Section | contributor | maintainer |
|---|---|---|
| Base ceremony, Steps 1–9 | render | render |
| Maintainer path | skip entirely | render |
| `--pooled` / `--shrink` | reject: `requires role=maintainer` | render |

The base ceremony is identical across roles. Never render maintainer-only federation affordances to a contributor — a rendered mode is an affordance the session may act on, only to fail later at the role gate.

## Base ceremony

### Step 1: Resolve the store and maintainer preflight

Run `lore resolve` and bind the result as `KNOWLEDGE_DIR`.

When `role == maintainer`, run the push-path preflight once before template-mutating work — it surfaces a non-writable `origin` before the maintainer authors edits the federation will never see:

```bash
PREFLIGHT_MARKER="${TMPDIR:-/tmp}/lore-maintainer-preflight.$$"
bash ~/.lore/scripts/maintainer-preflight.sh \
  --session-marker "$PREFLIGHT_MARKER" \
  --repo-dir "$(pwd)" 2>&1 || true
```

The preflight warns but does not block; a read-only origin may be intentional. If it warns, surface the failure and confirm the maintainer wants to continue.

### Step 2: Prepare the evidence queue

Run the hands-only prepare verb. Pass `--since` only when the caller explicitly supplied an override; there is no timestamp default in the skill:

```bash
lore evolve prepare [--since <RFC3339>] --json
```

`prepare` returns the immutable `_evolve/review-queues/<queue_id>.json` for the reconstructed cutoff and source snapshot. A matching queue is reused; a corrupt artifact, identity collision, journal prefix drift, or accepted-but-incomplete prior filing is refused with a named repair target.

The queue-v1 top level is normative:

```text
schema_version, queue_id, input_fingerprint, source_fingerprint,
artifact_sha256, run, cutoff, due_claim, source_manifest, items,
groups, recurring_clusters, summary, provenance
```

Key contracts:

- `cutoff = {basis, lower, upper, interval:"(lower,upper]", since_override}`. Each boundary cursor carries `timestamp`, `row_ordinal`, `row_sha256`, and journal identity. Equal timestamps remain distinct. The upper cursor advances past a malformed row only after a later valid row proves it interior; a malformed tail never advances the cursor.
- `run = {queue_run_id, role, mode:"local", predecessor}`. `predecessor` pins the latest completed filing and its cutoff, or is null on legacy migration.
- `due_claim = {attempted:false, outcome_ids:[], disposition:"not-applicable", warning:null}`. Evolve v1 has no DUE producer; do not invent a handle call.
- Each `source_manifest[]` row declares `{source_id, reader, resolved_source, coverage, content_identity, cursor, warnings, reason}`. Coverage is exactly `read | absent | unreadable | stale | not_computable`.
- Each `items[]` row declares `{item_id, source_role, source_cursor, work_item, parse, proposal, group_key, gate_path, eligibility}`. Invalid proposals remain in the artifact with `parse.status=invalid`; they are never inferred from partial prose.
- Canonical JSON recursively sorts object keys, preserves array order, uses compact UTF-8, and has no trailing newline.

The queue may contain source-authored suggestion text. It must never contain `recommended_verdict`, `recommendation`, `selected`, `approved`, `decision`, `verdict`, `edit`, `edit_text`, or `application` fields.

### Step 3: Read eligibility as evidence state

Preparation reads the raw/full journal range, scorecard rows, template registry, schema-v1 accepted clusters, active and archived consumption-contradiction sidecars, degradation rows, and completed prior evolve filings. It does not use the display-limited `journal show` surface.

Eligibility has exactly four states:

| Status | Meaning | Lead action |
|---|---|---|
| `eligible` | Every declared evidence predicate holds. | Review in Step 6. |
| `no_op` | Trustworthy, complete evidence definitively fails a predicate. | No verdict; retain the reason. |
| `abstained` | Trustworthy evidence exists, but the declared sample floor is not met. | No verdict; retain the arithmetic. |
| `not_computable` | A required source is absent, unreadable, stale, malformed, or cannot support the arithmetic. | No verdict; repair the source contract separately. |

Missing, invalid, degraded, or below-floor evidence never becomes eligible. `no_op`, `abstained`, and `not_computable` are queue facts, not disguised lead decisions.

Gate paths remain distinct:

| `change_type` | Gate path | Required evidence |
|---|---|---|
| Default template-behavior change | Primary | registered `tier=template`, `kind=scored`, calibrated, non-degraded row with cited metric/sample |
| `doctrine-correction` | Correction | `tier=correction`, `kind=scored`, permitted calibration, non-degraded row with half-floor arithmetic |
| `claim-retraction` / `falsified-doctrine` | Claim retraction | verified active-or-archived `consumption-contradictions.jsonl` row; no synthetic `kind` projection |
| `recurring-failure` | Recurring failure | prior unconsumed accepted-cluster evidence over `(target, change_type)` with distinct-work-item union at K≥3 |

Never fall back from one gate path to another. Stable no-op reasons include `no_eligible_template_row`, `telemetry_only`, `pre_calibration_only`, `unregistered_template_only`, `pipeline_degraded_window_only`, `wrong_tier`, `no_eligible_correction_row`, `no_verified_contradiction`, and `no_accepted_cluster`. Below-floor evidence is `abstained`; unavailable or invalid sources are `not_computable`.

Claim retraction reads the real lifecycle shape: `contradiction_id`, `status=verified`, `prefetched_commons_entry.knowledge_path`, and lifecycle timestamps across active and archived sidecars. Do not require a nonexistent `kind` field and do not project contradiction evidence into scorecard rows.

Recurring-failure arithmetic groups strictly by `(target, change_type)` and unions distinct `work_items`; raw row count cannot inflate K. Accepted clusters are one-shot evidence.

**Recurring-failure gate**

- **Inputs:** raw role=`retro-evolution` journal rows, prior schema-v1 rows in `_evolve/accepted-clusters.jsonl`, and the staged `(target, change_type)` key.
- **Success route:** read `_evolve/accepted-clusters.jsonl` directly. Group rows by the `(target, change_type)` key, take the union of distinct `work_item` values, and clear the gate only when the union size is **≥ K (K = 3)**. The proposal cites at least one row by `cluster_id`.
- **Conservative fallback:** no prior unconsumed match yields `no_op` reason `no_accepted_cluster`; never fall back to another evidence class.
- **Lifecycle constraints:** Run N may accept a candidate; Run N+1 may consume it. Same-run re-entry is forbidden — the enforced pause keeps a same-session burst of similar retros from self-amplifying into a binding edit — and a consumed row never fires again.

The raw-clustering pass excludes rows whose context starts with `retro-backfill:`. Those rows belong to the pre-clustered consumption pass, so raw and backfill populations never stack toward K. `K < 3` is sub-threshold, `K == 3` is the first candidate, and `K > 3` remains one candidate with its full distinct member set.

### Step 4: Present the complete queue

Read the published queue artifact, not transient command output. Present eligible items grouped by target then change type, preserving source order within each group. Show each item's source identity, proposal, evidence references, arithmetic, and gate path. Separately summarize `no_op`, `abstained`, `not_computable`, invalid parses, source warnings, and recurring-cluster candidates so absence is never silent.

Do not sort by priority or invent a recommended order. Stable grouping is navigation, not ranking.

### Step 5: Classify sunset obligations

Before deciding a proposal, classify its proposed effect:

| Classification | Definition | Sunset required? |
|---|---|---|
| addition | Adds a behavioral rule, step, or constraint. | yes |
| removal | Deletes, collapses, or retires behavior. | no |
| modification | Changes existing behavior. | yes when strengthening; no when loosening or clarifying |

An addition or strengthening edit needs a sentence naming the motivating metric, rollback threshold, and time or sample horizon. That clause is what `/evolve --shrink` reads at its trial-window check; an addition without one accumulates silently and is never subtracted. If the lead would otherwise apply it but cannot author a defensible sunset, use `reject` or `escalate`; do not change the machine eligibility state.

When in doubt, require one.

A verified consumption contradiction against a prior evolve addition triggers immediate sunset review. Present it before the regular queue, cite the contradiction ID and knowledge path, and treat an approved removal as a normal lead-authored removal.

### Step 6: Decide and author edits

Step 6 is the only judgment and edit-authorship seat. For every `eligible` item, the lead supplies exactly one verdict and rationale:

| Verdict | Use when | Prompt behavior |
|---|---|---|
| `apply` | The evidence and proposal scope align, and the lead can directly author the edit. | No prompt. |
| `reject` | The evidence is real but the proposed change is wrong, premature, or poorly targeted. | No prompt. |
| `escalate` | A destructive change, high-confidence drop, or genuine abstention prevents a confident lead decision. | Ask the human once. |

Escalation reasons are exactly `destructive-change | high-confidence-drop | abstain`. Human resolution is exactly `pending | apply | reject | defer`. Preserve unresolved or deferred escalation as durable carry-forward; advancing the cutoff must not lose it.

The decision shape is normative:

```text
{item_id, verdict, rationale, escalation, application}
```

- `escalation` is null unless `verdict=escalate`; then it is `{reason,resolution}`.
- `application` is present only when the effective resolution is apply; then it is `{outcome,target,pre_version,post_version}` with outcome exactly `applied | failed | deferred`.
- A lead decision being accepted does not imply the edit landed. Keep verdict, human resolution, and application outcome as separate facts.

For an effective apply, snapshot the target's pre-edit version, read the current file, author the change directly, verify it, and compute the post-edit version:

```bash
PRE_VERSION=$(bash ~/.lore/scripts/template-version.sh <absolute-target-path>)
# Lead authors and applies the edit here.
POST_VERSION=$(bash ~/.lore/scripts/template-version.sh <absolute-target-path>)
```

Apply sequentially per file. A mechanism, helper, or filing verb must never supply edit text or change the target. If application fails, record `outcome=failed|deferred`; do not rewrite the verdict to hide the failure.

For each `application.outcome=applied` byte change, add one version registration:

```text
{item_id,target,template_id,template_path,pre_version,post_version,description}
```

No-byte-change, reject, and unresolved/deferred decisions cannot register a version. Registration is what links the edit to the next retro window's A/B signal; an unregistered post-edit version renders as `unregistered:<hash>` and carries no weight, so the edit is never measured.

#### Recurring-cluster dispositions

Adjudicate every `recurring_clusters[]` candidate in Step 6. The closed vocabulary is `merge | edit | split | reject | escalate`:

- `merge` or `edit` yields exactly one resulting cluster.
- `split` yields at least two resulting clusters.
- `reject` or `escalate` yields no resulting cluster.

Record `{candidate_id, disposition, rationale, resulting_clusters}`. Resulting clusters carry target, sorted unique change types, sorted unique work items, and journal row references. Do not invoke the accepted-cluster writer here; Step 7 files the lead's completed disposition. Newly accepted clusters are never consumed in this run.

Present one candidate at a time. The operator-facing shorthand may remain `[y/edit/split/n]`, but normalize it before filing: `y -> merge`, `edit -> edit`, `split -> split`, and `n -> reject`. The manifest vocabulary remains `merge | edit | split | reject | escalate`.

```text
CLUSTER REVIEW
Candidate cluster: target=<file> | change_type=<type> | K=<distinct-work-item-count>
Members:
  <timestamp> | <work_item slug> | <one-sentence excerpt>
Representative Evidence: <source evidence, verbatim>
Disposition [y/edit/split/n]:
```

`merge` may combine candidates sharing the same `(target, change_type)` pair; its result carries the union of both candidates' members. On `n`, record `reject` with no resulting cluster. Canonical vocabulary consumed by accepted-cluster-append is filed only through Step 7.

**Batch-confirmation mode (backfill input).** A maintainer may source pre-clustered candidates from `lore retro backfill`. Present one CLUSTER REVIEW prompt per candidate. Map the singular `change_type` to a one-element `change_types` list in the resulting-cluster facts, tally `proposed / confirmed / merged / rejected`, and normalize the UI shorthand to the manifest vocabulary above. Do not auto-confirm operator decisions.

### Step 7: File the lead commitment

Assemble the lead-authored manifest:

```text
{
  schema_version:1,
  queue_id,
  queue_sha256,
  actor,
  model,
  decisions,
  cluster_dispositions,
  version_registrations,
  summary
}
```

Every eligible item needs exactly one decision; machine `no_op | abstained | not_computable` items need none. Every prepared cluster candidate needs exactly one disposition. Then run:

```bash
lore evolve file \
  --queue "$KNOWLEDGE_DIR/_evolve/review-queues/<queue_id>.json" \
  --decisions <lead-authored-manifest.json> \
  --json
```

`file` validates the queue, manifest, live post-edit versions, and predecessor lineage before publishing `_evolve/review-filings/<queue_id>.json` as the immutable lead commitment. It accepts exact replay and refuses semantic reassignment or a stale competing queue.

After authority publication, `file` scans exact sink keys and invokes only missing sanctioned writers:

| Sink | Exact key | Sole writer |
|---|---|---|
| Accepted-cluster creation | `accepted-cluster:create:<cluster_id>` | `accepted-cluster-append.sh --append-exact` |
| Prior cluster consumption | `accepted-cluster:consume:<cluster_id>:<run_id>` | `accepted-cluster-append.sh --consume` |
| Template registration | `template-registry:<template_id>@<post_version>` | `template-registry-register.sh` |
| Terminal cutoff | `journal:evolve-filing:<filing_id>` | `journal.sh` |

The accepted-cluster script is the sole physical writer for `_evolve/accepted-clusters.jsonl`. Exact same-ID append is reuse; changed semantics are conflict. Consumption permits only `null -> run_id`; same-run replay is reuse; a different non-null run conflicts.

The role=`evolve` journal row is last. Its context is `evolve-filing:<filing_id>` and its observation serializes queue, filing, run, counts, proposal IDs, version bumps, and the queue's upper cutoff. Its presence is the next-run completion/cutoff marker.

### Step 8: Recover without laundering completion

Keep these states separate:

- `decision_accepted=true` means the immutable lead filing exists.
- `filing_complete=true` means every required cluster/registry sink and the terminal cutoff row exists.

File statuses are exactly `created | reused | recovered | partial | refused`:

- `partial` means authority exists but at least one sanctioned sink is missing or conflicted. The terminal cutoff is withheld. Return non-zero and name the retry target.
- `recovered` means an exact retry repaired one or more missing sinks and completed the filing.
- `reused` means the exact filing and all exact sink keys were already complete.
- `refused` means validation, lineage, identity, or semantic conflict prevented acceptance.

After `partial`, replay the same queue and manifest. Do not prepare a successor: `prepare` refuses past an accepted-but-incomplete filing so unfinished work cannot disappear behind a later cutoff. There is no cross-file rollback claim.

Completed filings become the sole carry-forward authority after accepted-cluster evidence is consumed. A later `prepare` carries only pending/deferred escalations and failed/deferred applications, preserving original item and filing identity. Carry-forward ends only with effective reject, or effective apply whose application landed and required registration sink completed.

### Step 9: Report the run

Report from the queue and filing responses:

```text
[evolve] Done
  Queue:              <queue_id> (<created|reused>)
  Reviewed:           <eligible count>
  Applied:            <count>
  Rejected:           <count>
  Escalated:          <count; pending/deferred called out>
  No-op:              <count + reason breakdown>
  Abstained:          <count + floor arithmetic>
  Not computable:     <count + source reasons>
  Decision accepted: <true|false>
  Filing complete:   <true|false>
  Filing:             <created|reused|recovered|partial|refused>
  Bumps:              <template_id>@<pre>..<post, or none>
```

List each applied change and each missing sink. Never print a success-shaped `Done` when `filing_complete=false`.

## Staged suggestion boundary

The staged rows in `_evolve/accepted-clusters.jsonl` and the effectiveness journal are evidence inputs, not an implementation backlog to mutate during this ceremony. The active+archived claim-retraction reader semantically moots exactly the 2026-07-09T23:07:07Z suggestion targeting `skills/evolve/SKILL.md`; leave that row untouched. The other 14 staged suggestions remain live and unconsumed because they concern retro, implement, settlement, rubric, or source-contract behavior outside this queue ceremony.

## Maintainer path (role=maintainer only)

These existing modes remain outside the v1 `prepare`/`file` pair. They are lead-owned alternate evidence modes, not hidden branches of the new verbs. Preserve their role gate and judgment boundary.

### Mode: `/evolve --pooled <aggregate-path>`

Use a `lore retro aggregate` artifact instead of the local queue inputs.

1. Require `role=maintainer`.
2. Load `{generated_at, source_bundles, contributors, groups}` and treat missing tier as telemetry.
3. Only `tag=convergent` groups are candidates. `tier=template` uses the primary evidence class; `tier=correction` uses the correction class. Exclude task-evidence, reusable, telemetry, missing-tier, mixed, and insufficient groups.
4. Require `total_n >= 15` and `contributor_count >= 2`.
5. The maintainer authors any edit text during review. Pooled evidence never supplies a default edit.
6. Additions require a failing scored metric and a sunset clause. Removals may proceed on staleness, duplication, budget, or failed-trial evidence.
7. Each applied change carries a thin public trace naming the window, contributors, sample size, metric expectation, and sunset.

Report: `Pooled: <aggregate-path> (N convergent [P primary/C correction] / M idiosyncratic / K mixed / J insufficient)`.

### Mode: `/evolve --shrink`

Run a subtraction-only review.

1. Require `role=maintainer`.
2. Inspect expired sunset conditions, duplicated protocol wording, skills over 300 lines, agents over 200 lines, and failed post-bump trial windows.
3. Propose only removals, collapses, and pre-authored reverts. Never add a behavioral requirement.
4. Staleness, duplication, budget excess, or a failed trial window each suffice; no failing scored metric is required for subtraction.
5. The lead still decides and directly authors each change. Every applied removal receives a version bump so the next retro can measure the effect.

Report: `Shrink: <N> removes / <M> collapses / <K> reverts applied (budget: <file> @ <lines>/<limit>)`.
