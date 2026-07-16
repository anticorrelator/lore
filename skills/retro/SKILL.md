---
name: retro
description: "Evaluate knowledge-system effectiveness after a work cycle from a source-manifested evidence pack, then atomically persist explicit diagnostic judgments and any evolution suggestions"
user_invocable: true
argument_description: "[work item name or slug]"
---

# /retro Skill

Ask one question: did the knowledge system make this work meaningfully better?

The ceremony has hands, not a borrowed head. `lore retro prepare` assembles the reproducible evidence envelope. The retro lead interprets that evidence, scores the dimensions, answers the behavioral checks, names causes, and chooses whether any proposal is substantive. `lore retro file` preserves those explicit commitments through the existing writers. Neither verb diagnoses the system or decides what should change.

A completed retro may honestly conclude `no-substantive-suggestion`. Healthy silence is an outcome, not a missing step.

## Decision rights

The lead owns every judgment that could change the meaning of the cycle:

- causal interpretation and remedy selection;
- D1–D5 scores and rationales;
- behavioral-health prose, including Check 7;
- escalation and scale-access judgments;
- channel-flag selection;
- suggestion selection and proposal text;
- any decision to graduate or remove a rubric.

The verbs own resolution, published-reader calls, fixed arithmetic, source coverage, canonical identities, validation, atomic publication, replay, recovery, and writer bookkeeping. If a proposed mechanical change would choose any lead-owned value, reject it.

## Role and federation boundary

Run the ceremony identically for contributors and maintainers. Federation commands such as `lore retro export`, `import`, and `aggregate` are separate CLI surfaces; `/retro` never invokes them as a side effect.

Cadence also remains human-owned. The retro-sampling gate may record a DUE outcome, but it never auto-runs `/retro` and never blocks a completed spec or implementation cycle.

## Execution order

Run these steps in order:

1. Select one cycle and explicit UTC window; invoke `prepare`.
2. Verify pack completeness and read its facts, calculations, and fixed-health state.
3. Interpret the cycle and author all diagnostic judgments.
4. Build the exact v1 judgment manifest, including a suggestion outcome.
5. Invoke `file`; recover an accepted partial filing by exact replay.
6. Report the evidence state first and the qualitative coda second.

Do not write journal rows or retro sidecars by hand. Do not read private storage to fill a pack gap. Do not turn absent evidence into a favorable signal.

### Step 1: Resolve Work Item

Choose the work item and window before asking the machinery for evidence. When the user did not supply a reference, use the current branch through `lore work resolve`; ask only when the resolver cannot choose uniquely. Archived cycles are valid inputs and need no restoration.

Invoke:

```bash
lore retro prepare "$ARG" \
  --window-start "<RFC3339 UTC>" \
  --window-end "<RFC3339 UTC>" \
  --json
```

Both bounds are required because Lore has no canonical retro-window inference. The returned `cycle_id` is the canonical slug. Preserve the artifact path, `pack_id`, and SHA for Steps 4 and 5.

**DUE lifecycle compatibility.** The queue vocabulary remains `done | deferred | skipped | due`. A DUE begins as `record_type=outcome` with `disposition=unhandled`; its transition is a separate `record_type=disposition` with `disposition=handled` and an action from `dispatched | deferred | skipped`. `lore retro queue` remains the public fold. Prepare performs a best-effort DUE claim equivalent to:

```bash
lore retro handle --cycle-id "$SLUG" \
  --action dispatched --handled-by retro-lead
```

If the queue reader fails, prepare warns `DUE queue reader failed`; if the claim write itself fails, it warns `best-effort DUE claim failed`. It MUST warn and continue in either case: the claim is never a precondition for the retro, never changes the selected cycle, and never creates another run obligation.

### Step 2: Gather Evidence

Read `<cycle>/retro-evidence-pack.json`. Do not recompute its arithmetic or supplement an unavailable source with a private-file fallback.

#### Pack v1 contract

The top-level object is exactly:

```text
schema_version, pack_id, input_fingerprint, source_fingerprint,
artifact_sha256, cycle, window, due_claim, source_manifest, facts,
calculations, fixed_health, provenance
```

Identity layers answer different questions:

- `input_fingerprint` identifies the requested cycle and caller-supplied window.
- `source_fingerprint` identifies the ordered source snapshot and calculation contract.
- `pack_id` identifies their semantic combination.
- `artifact_sha256` verifies the canonical pack; the hash is computed with that top-level member removed.

Never substitute one identity for another.

The required v1 sources are `cycle_work`, `due_queue`, `settlement`, `scorecard_rows`, `scorecard_current`, `session_events`, `journal`, and `consumer_contradiction_lifecycle`. Every source row carries `reader`, `resolved_source`, `reader_contract_version`, `projection_mode`, `stable_empty_shape`, `coverage`, `content_identity`, `cursor`, `window_field`, `warnings`, and `reason`. Coverage is exactly `read | absent | unreadable | stale | not-computable`.

The registered reader is the reader prepare executes — never a paraphrase or a sibling implementation path. History readers take the caller's half-open `[start,end)` window and return their declared stable empty shape; `cycle_work` and `scorecard_current` stay snapshots because filtering them by event time would misstate their meaning. Content identity hashes only the stable projection fields capable of changing pack facts.

Each reader seam is one versioned contract: command, window or snapshot semantics, success shape, stable empty shape, malformed-source behavior, and the fact-relevant projection. A semantic change to any of these increments that seam's `reader_contract_version` and updates its writer-driven contract test in the same change. Never add a sibling reader beside a canonical one — extend the existing namespace, or retire the old surface in the same change that replaces it.

Style, compression, and reorganization of this skill travel with the semantic change they describe. A standalone prose pass after behavior or contract tests have moved leaves three descriptions of one seam; keep prose, reader, and test moving as one mutation chain.

The required fact groups are `cycle_artifacts`, `task_context_backlinks`, `concerns_contradictions`, `session_retrieval_friction_packets`, `review_events`, `scale_signals`, `scorecard_eligibility_deltas`, `telemetry_attribution_rework`, and `settlement_health_inputs`. A fact group is `available | absent | not-computable`; non-available facts carry `values: null` and a reason.

Every calculation row names its calculation/version, source IDs, numerator, denominator, value, unit, sample floor, threshold, disposition, and reason. Disposition is exactly `green | tripped | abstained | not-computable`.

#### Absence is never green

Treat each state literally:

- `abstained` means a trustworthy statistic is below its declared floor.
- `not-computable` means the published substrate cannot support the statistic.
- `absent`, `unreadable`, and `stale` are evidence states, never favorable verdicts.
- `fixed_health.state=not-computable` withholds `normal`; it does not imply `pipeline-degraded` and does not invite the lead to guess.

The six load-bearing calculations consume only the versioned published projections. Missing, unreadable, stale, malformed, or below-floor evidence keeps the calculation's emitted `not-computable` or `abstained` disposition and its reason — never green. A disabled settlement census stays an explicit `abstained: dormant-census`; judge liveness abstains below its registered sample floor; an empty bounded contradiction lifecycle is below sample, not proof of healthy routing.

Do not consume or mutate `_evolve/accepted-clusters.jsonl` to fill any of these gaps.

#### Tier-aware evidence

Preserve the scorecard tier boundaries surfaced by the pack:

| Tier | Retro use |
|---|---|
| `template` | Headline and template-behavior deltas. |
| `correction` | Doctrine-correction deltas; never merged into template cells. |
| `reusable` | Informational commons evidence. |
| `task-evidence` | Task-local grounding evidence. |
| `telemetry` or missing legacy tier | Observability only; never `/evolve` evidence. |

Never mix tiers in one cell — the same metric measures different things at different tiers. Never let an improvement in one metric compensate for a regression in another; offsetting is exactly how a regression hides. When fixed health is `pipeline-degraded`, treat headline and delta cells as non-evidentiary. When it is `not-computable`, name the missing substrate rather than manufacturing a headline.

#### Consumer-contradiction vocabulary

The row schema names `status` — `pending | verified | contradicted`; the terminal pair is `verified | contradicted`. The published `lore consumption-contradiction read` projection exposes each row's `created_at`, terminal `settled_at`, status, work-item identity, and settling run identity, across active and archived cycles within the caller's half-open window. Consume that lifecycle array directly; do not inspect sidecar files or substitute scorecard verdicts.

Compatibility guard: reject the retired lifecycle words `routed`, `rejected`, `accepted`, `declined`, `remediated` as status values. The narrative report shape is `Consumption contradictions: N total (P pending verdict, V verified, C contradicted)`; the routing denominator is every produced lifecycle row and the numerator is `status ∈ {verified, contradicted}`.

### Step 3: Adjudicate the Cycle

The pack answers what was present and what fixed rules produced. The lead answers what it means.

Read the cycle artifacts named in `source_manifest`, then write concise judgments grounded by `source:<source_id>`, `calculation:<calculation_id>`, or `pack:<JSON Pointer>` references. A source gap may itself support a diagnosis, but it cannot support a favorable deterministic claim.

#### Dimension scores

Score every dimension from 1–5 and give a concrete rationale. Do not adjust a score merely to agree with a deterministic headline; disagreement between the two is diagnostic.

##### D1 — Knowledge Delivery

Judge whether relevant knowledge reached the working agents and shaped their choices. Implementation output is valid evidence of internalization; citation is not required. Review work should show knowledge preambles. Spec-only work is predictive.

`5` every phase delivered with high completeness | `4` most phases with minor gaps | `3` low annotation quality or spec-only agents lacked available context | `2` phases missing, unresolved delivery, or a silent pipeline drop | `1` no delivery

D1 stays in the ceremony: its delivery-plumbing half is mechanically evidenced, but internalization remains evaluative. D1 is the named graduation candidate; removal requires a separately registered window with routed-model response variable, denominator, undefined-statistic branch, and one-direction qualitative veto. This implementation does not graduate it.

##### D2 — Retrieval Quality

Judge relevance, currency, and abstraction fit.

`5` all relevant/current/right-sized | `4` one minor mismatch | `3` topical but wrong altitude | `2` mostly irrelevant or stale | `1` actively misleading

##### D3 — Gap Analysis

Separate coverage failures from genuinely novel discoveries. Coverage failures weigh more heavily; corrections with no new captures can indicate maturity rather than failure.

`5` no gaps | `4` one minor gap or only novel discoveries | `3` one significant coverage failure | `2` multiple coverage failures | `1` no knowledge-system support

##### D4 — Plan–Knowledge Alignment

Judge whether cited knowledge actually shaped implementation. Decorative references do not count.

`5` decisions shaped implementation | `4` most influenced, one or two decorative | `3` present but agents chose independently | `2` cited then diverged | `1` no alignment

##### D5 — Spec Utility

Judge whether the spec reduced unnecessary exploration while leaving intended discovery work free to discover.

`5` spec-guided with no escalation | `4` minor exploration or one escalation | `3` several independent reads or two to three escalations | `2` frequent exploration and divergence | `1` no meaningful guidance

#### Escalation, scale, and channel judgments

Evaluate each branch explicitly. Use `{applicability:"not-applicable", reason}` only when the branch truly did not apply.

- Escalation stays qualitative and off scorecards — a scored escalation rate teaches workers to suppress or game it. If applicable, provide the lead's observation and evidence references.
- Scale access uses the sanctioned `right-sized | too-coarse | too-fine` and `better | same | worse` vocabularies plus rationales.
- Channel flags use `under_routing | over_capture | evidence_only_durable`. An applicable branch may return `value: []`, meaning it was evaluated and no flags were selected.

The pack may surface the factual signals `declaration_coverage`, `redeclare_rate`, `off_scale_routes_emitted`, `verifier_disagreements`, `off_altitude_skipped`, and `counterfactual_better`. They inform judgment but do not auto-suggest disabling the scale system.

#### Behavioral health

Select three checks from Checks 1–6 at invocation time, without replacement, and always include Check 7. Late selection prevents producers from shaping artifacts to the test. Answer in prose; never score the checks.

1. Could generic worker observations have been written for another task?
2. Did substantive observations become durable knowledge, or remain cheap talk?
3. Did investigations surprise or contradict prior knowledge, or merely confirm it?
4. Did optional narrative slots carry judgment, or did form-filling crowd them out?
5. Did review dispositions show suspicious skew toward dismissal or action?
6. Did user overrides suggest calibration drift or disengagement?
7. **Did this feel like real work?** Looking at the artifacts, were agents thinking or complying? Answer in 2–3 sentences. Check 7 is irreducible ground truth and must never be replaced by a number.

If a check becomes formulaic across repeated selections, propose a change through the normal suggestion branch. Never tune Check 7 away.

#### Settlement pipeline health checks

Read `fixed_health` and its referenced calculation rows before reading headline or delta facts. The script is the sole home for arithmetic, floors, and thresholds; this skill names meanings and judgment boundaries only.

- `normal`: all load-bearing calculations produced trustworthy non-tripped results.
- `warmup`: at least one trustworthy calculation abstained below floor and none tripped.
- `pipeline-degraded`: a fixed calculation tripped. Lead with the tripped calculation IDs and withhold scorecard interpretation.
- `not-computable`: at least one load-bearing calculation lacks a trustworthy published substrate. Lead with the missing source/reason and withhold a healthy headline.

Healthy checks remain silent in the report — green narration turns to ritual and buries the one check that trips. This is load-bearing healthy silence, not permission to omit pack rows.

##### Check: Judge liveness

The calculation reads completed run envelopes from the published settlement projection; fixture-calibration logs are not liveness evidence — they record calibration ceremonies, not per-verdict activity, and sit legitimately empty over healthy windows. The zero-output signature is `completed_runs_in_window == 0 AND settlement_queue_items_routed > 0`, and it trips regardless of sample size. Otherwise the registered floor applies before rate classification; below-floor completions are `abstained`, never green or tripped.

##### Check: Consumer-contradiction routing

Read the bounded `consumer_contradiction_lifecycle` projection. Below the registered floor the calculation abstains — preserve that. At or above it, the fixed arithmetic compares terminal `verified | contradicted` rows against all produced lifecycle rows. Missing or unreadable lifecycle evidence is `not-computable`, never a zero-rate shortcut and never green.

##### Check: Candidate backlog

A disabled census is `abstained: dormant-census` — never read the dormant backlog count as healthy or as tripped. With census enabled, the fixed calculation classifies pending counts from the settlement projection; a missing projection stays `not-computable`.

##### Check: Grounding, audit lag, and realization

Respect each calculation's source-coverage and disposition fields. A missing enqueue timestamp, source drift, or unavailable run envelope cannot become a zero numerator.

### Step 4: Author the Judgment Manifest

Build a v1 object with exactly:

```text
schema_version, cycle_id, pack_id, pack_sha256, actor, model,
key_finding, most_actionable_gap, dimension_judgments,
behavioral_health, causal_diagnoses, escalation_judgment,
scale_access_judgment, channel_flags, suggestion_outcome, suggestions
```

Set `pack_sha256` to the pack's `artifact_sha256`, not the serialized file digest.

`dimension_judgments` is ordered exactly D1–D5. Each row is `{dimension_id, score, rationale, evidence_refs}`. `behavioral_health` is an ordered array of `{check_id, answer, evidence_refs}` and includes Check 7. `causal_diagnoses` is an array of `{diagnosis_id, interpretation, evidence_refs}` and may be empty.

The three conditional fields — `escalation_judgment`, `scale_access_judgment`, and `channel_flags` — are never absent or null:

```json
{"applicability":"applicable","value":{}}
{"applicability":"not-applicable","reason":"..."}
```

For `channel_flags`, applicable `value` is an array and may be empty. Escalation and scale-access values, each channel-flag row, and every dimension, behavioral answer, diagnosis, and substantive suggestion carry at least one resolving evidence reference.

#### Suggestion outcome

Choose exactly one:

- `substantive`: provide one or more `{target, change_type, section, suggestion, evidence, evidence_refs}` objects.
- `no-substantive-suggestion`: provide `suggestions: []`.

Never create a placeholder `retro-evolution` suggestion to prove the step ran. The filing artifact and terminal telemetry make the honest negative durable without polluting `/evolve`'s proposal stream.

Suggestion selection remains lead-owned. Watch for recurring ceiling dimensions, new failure modes, dead dimensions, evidence-quality gaps, and template regressions, but do not force one to exist.

### Step 5: File and Recover

Invoke:

```bash
lore retro file "$SLUG" \
  --pack "<cycle-dir>/retro-evidence-pack.json" \
  --judgments "<lead-authored-v1.json>" \
  --json
```

The authoritative `retro-filing.json` is a single immutable assignment for the cycle. `judgment_accepted=true` means that assignment exists and matches. `filing_complete=true` means every required sanctioned sink exists and the terminal `event_type=retro-filing` telemetry row has landed.

The immutable assignment requires primary, behavioral, escalation, proposal, scale-access, channel-flag, and completion-telemetry sinks. Their replay identities are unchanged: the primary, behavioral, and escalation journal rows match on `role + work_item + filing_id + sink`; each substantive proposal on that journal identity plus its `proposal ordinal`; scale access on `cycle_id` with exact writer-field equality; channel flags on `cycle_id + role + slot + signal_type` with exact field equality; completion telemetry on `event_type=retro-filing + filing_id`.

Every write goes through its sanctioned writer: `journal.sh`, `retro-scale-access-append.sh`, `retro-channel-flag-append.sh`, or `scorecard-append.sh`. The verb never appends their files directly. Completion telemetry is last.

On `status=partial`, the judgment is accepted but the filing is incomplete. Preserve the immutable manifest, repair the named sink condition, and replay the exact same command; replay invokes only missing writers. Do not edit the manifest to work around a sink failure; a semantic difference is a collision, not a revision.

### Step 6: Report

Lead with the deterministic evidence state:

```text
[retro] <cycle>
  pack: <pack_id> (<created|reused|recovered|replaced>)
  fixed health: <normal|warmup|pipeline-degraded|not-computable>
  tripped/withheld: <calculation ids and reasons, or none>
  filing: judgment_accepted=<bool> filing_complete=<bool>
  missing sinks: <list or none>
```

Then report, in order:

1. scorecard deltas and headline only when the pack says they are evidentiary;
2. key finding and most actionable gap;
3. causal diagnoses;
4. escalation, scale-access, and channel judgments;
5. behavioral-health answers, with Check 7 visible;
6. D1–D5 as the narrative coda;
7. `substantive` suggestion titles or the explicit `no-substantive-suggestion` outcome.

When health is `pipeline-degraded` or `not-computable`, do not place pass/weak/fail prose above the evidence warning. When a below-floor calculation abstains, say `abstained: below-sample`; never translate it to weak, fail, or green.

`/retro` never edits proposal targets. `/evolve` remains the only consumer that applies substantive `retro-evolution` suggestions. A no-suggestion filing gives `/evolve` nothing to consume, by design.
