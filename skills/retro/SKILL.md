---
name: retro
description: "Evaluate knowledge-system effectiveness after a work cycle from a source-manifested evidence pack, then atomically persist explicit diagnostic judgments and any evolution suggestions"
user_invocable: true
argument_description: "[work item name or slug]"
---

# /retro Skill

Ask one question: did the knowledge system make this work meaningfully better?

The ceremony has hands, not a borrowed head. `lore retro prepare` assembles the reproducible evidence envelope and freezes into it the rubric the judgment will be made under. The retro lead interprets that evidence, scores the dimensions or records why one could not be scored, answers the behavioral checks, names causes, and chooses whether any proposal is substantive. `lore retro file` preserves those explicit commitments through the existing writers, under the rubric identity the pack froze. Neither verb diagnoses the system or decides what should change.

A completed retro may honestly conclude `no-substantive-suggestion`. Healthy silence is an outcome, not a missing step.

## Decision rights

The lead owns every judgment that could change the meaning of the cycle:

- causal interpretation and remedy selection;
- D1–D5 scores and rationales, and D6's score or its `not-assessable` disposition;
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
4. Build the exact v2 judgment manifest, naming the frozen rubric and including a suggestion outcome.
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

**DUE lifecycle compatibility.** The queue vocabulary remains `done | deferred | skipped | due`. A DUE begins as `record_type=outcome` with `disposition=unhandled`; its transition is a separate `record_type=disposition` with `disposition=handled` and an action from `dispatched | deferred | skipped`. `lore retro queue` remains the public fold, now at fold version 2 with vocabulary version 1: dispositions fold per outcome in append order, a latest `deferred` action leaves the outcome in `unhandled_due` with its handling record beside it, and a latest `dispatched` or `skipped` handles it. A coordinator's deferral keeps a cycle claimable by a later retrospective; it does not close it. Prepare performs a best-effort DUE claim equivalent to:

```bash
lore retro handle --cycle-id "$SLUG" \
  --action dispatched --handled-by retro-lead
```

If the queue reader fails, prepare warns `DUE queue reader failed`; if the claim write itself fails, it warns `best-effort DUE claim failed`. It MUST warn and continue in either case: the claim is never a precondition for the retro, never changes the selected cycle, and never creates another run obligation. The pack's `due_claim` records what the attempt did — the candidate and appended outcome IDs, the reader and writer exit codes, the disposition, and any warning — so a failed claim is a fact in the pack rather than a silent success.

### Step 2: Gather Evidence

Read `<cycle>/retro-evidence-pack.json`. Do not recompute its arithmetic or supplement an unavailable source with a private-file fallback.

#### Pack v1 contract

The top-level object is exactly:

```text
schema_version, pack_id, input_fingerprint, source_fingerprint,
artifact_sha256, cycle, window, due_claim, rubric, source_manifest,
source_data, facts, calculations, fixed_health, provenance
```

Identity layers answer different questions:

- `input_fingerprint` identifies the requested cycle and caller-supplied window.
- `source_fingerprint` identifies the ordered source snapshot and calculation contract.
- `pack_id` identifies their semantic combination.
- `artifact_sha256` verifies the canonical pack; the hash is computed with that top-level member removed.

Never substitute one identity for another.

The required v1 sources are `cycle_work`, `packet_assessments`, `due_queue`, `scorecard_rows`, `scorecard_current`, `session_events`, and `journal`. Every source row carries `reader`, `resolved_source`, `reader_contract_version`, `projection_mode`, `stable_empty_shape`, `coverage`, `content_identity`, `cursor`, `window_field`, `warnings`, and `reason`. Coverage is exactly `read | absent | unreadable | stale | not-computable`.

The registered reader is the reader prepare executes — never a paraphrase or a sibling implementation path. History readers take the caller's half-open `[start,end)` window and return their declared stable empty shape; `cycle_work` and `scorecard_current` stay snapshots because filtering them by event time would misstate their meaning. Content identity hashes only the stable projection fields capable of changing pack facts.

Each reader seam is one versioned contract: command, window or snapshot semantics, success shape, stable empty shape, malformed-source behavior, and the fact-relevant projection. A semantic change to any of these increments that seam's `reader_contract_version` and updates its writer-driven contract test in the same change. Never add a sibling reader beside a canonical one — extend the existing namespace, or retire the old surface in the same change that replaces it.

Style, compression, and reorganization of this skill travel with the semantic change they describe. A standalone prose pass after behavior or contract tests have moved leaves three descriptions of one seam; keep prose, reader, and test moving as one mutation chain.

#### Rubric identity

The pack's `rubric` member is the frozen declaration prepare read from `skills/retro/rubric.json`: `rubric_id`, `rubric_version`, the ordered `dimensions` with their `dimension_id`, `journal_key`, `name`, five `anchors`, and `allow_not_assessable`, plus `rubric_sha256` and the exact `rubric_text`. The `rubric_id` is `retro-rubric`. The `rubric_version` is the 12-hex prefix of the SHA-256 over the rubric file's bytes, the same construction `template-version.sh` uses for a template. The whole descriptor is part of the pack's source fingerprint, so a pack prepared before a rubric edit and one prepared after it are different packs with different identities.

The judgment names the `rubric_id` and `rubric_version` it was made under. Filing checks them against the descriptor frozen in the pack, never against the rubric file on disk at filing time, so a rubric edit between prepare and file is a refusal to correct rather than a silent rescoring under a contract nobody saw. Editing this skill's prose leaves the rubric version unchanged; editing the rubric file's bytes changes it, and that is the intended way to start a new scoring series. The anchors written under each dimension below and the anchors in the rubric file say the same thing, and when one moves the other moves in the same change.

The declared dimensions are `D1` `d1_delivery`, `D2` `d2_quality`, `D3` `d3_gaps`, `D4` `d4_alignment`, `D5` `d5_spec_utility`, and `D6` `d6_packet_utility`. The first five keep the meanings, anchors, and journal keys they have always had. Only `D6` may be `not-assessable`.

#### The cycle_work projection

`cycle_work` is the work reader's published view of a work item, read at reader contract version 2. The pack schema stays at 1, and the other source readers keep their existing versions. The version bump belongs to this seam alone. The TUI work detail and `lore coordinate status` read the same view, so a missing or stale result means the same thing wherever it appears. Retro does not fold ledgers, tasks, or results on its own beside it.

The projection's `evidence` object carries one envelope per source: generated tasks, revision history, per-criterion results, packets addressed to this item, ceremony outcomes, review artifacts, nested reports, task claims, and the legacy close bundle described below. Each envelope records a `state`, a `reason`, the store-relative `path`, a `sha256` of the raw bytes, and the content or rows it read. Directory sources carry one full envelope per entry. The states are:

- `read`: the source existed and parsed. Its content is present.
- `absent`: nothing exists at the path. This establishes only that the source is not there, not why.
- `unreadable`: something exists but did not parse or validate against the schema it declares.
- `unsupported`: the source declares a schema or contract version this reader does not know. An item that predates a producer has no file for it and is `absent`, not `unsupported`.

Stale is not a fifth state. It is a freshness property derived on records that name what they were produced against. A result is stale when its revision is behind the current head, when the criterion's complete definition has changed version since it ran, when the source HEAD or worktree digest it recorded differs from the current worktree, or when the code identity recorded at its start differs from the one recorded at its end. The record lists every reason that applies. When the execution worktree can no longer be inspected, for example after cleanup, freshness is `unknown` with a reason. Unknown is neither current nor stale. Report it as unknown.

The projection's `revision` object names the committed head, its publication state, and a reason when publication is incomplete. Incomplete publication is a fact to report. The reader never regenerates tasks.

The envelopes keep the material a judgment needs inspectable rather than counted. Task bodies and dependency edges are present, not only task IDs. Each report entry carries its identifier, its declared status or `unknown` when none was declared, its size, a content hash, and the full text. Claims carry a row count together with the canonical rows. Packets name their sources and the revision they were assembled against, or an explicit unbound state for legacy packets. Result history keeps every attempt. The result summary lists, per task and per criterion, the latest result ID, its state, its freshness, and the reasons behind either. A pass on one criterion is never rolled up into a pass for the task while other criteria are failing, stale, unknown, or missing.

Result rows are read for what the runner observed, not for what the criterion intended. The `argv` in a row is the plan-owned command selected from the immutable revision, and `resolved_cwd` records the resolved placement when it was available; neither claims that a child process launched on an unavailable or skipped path, so the reviewer reads `state` and the applicability observation to determine what actually executed, and inspects the retained output bytes with their digest rather than a paraphrase. Result IDs are cited exactly, and reports remain full-text artifacts whose cited IDs the reviewer checks against the ledger. When an applicability predicate ran, its own argv, cwd, distinct exits, and separately retained output are part of the evidence, and `skipped` means one observed inapplicable exit and nothing broader. `unavailable` is observed evidence that execution could not provide a usable criterion outcome, from a launch, placement, output, source, or interruption failure; retained launch, interruption, and output facts may still exist, and the state is never folded into pass or fail. The latest attempt per criterion is the row with the greatest `execution_sequence`, an immutable positive integer the runner allocates under the results directory lock and a caller never chooses, so ordering does not depend on finish, publication, or recovery order; legacy rows without a sequence keep ledger order and precede sequenced rows. Freshness is read from the recorded identities: a result whose start and end identities differ, or whose source HEAD, worktree digest, criterion version, or revision no longer match the live root, is stale; an uninspectable root is unknown; a current record may be a pass, fail, skipped, or unavailable, and only a current pass supports a current passing check. Whether a criterion was adequate for its task, and whether the criteria together cover the original anchor, are the reviewer's authored judgments recorded with the result IDs they rest on. No result carries acceptance, checkoff, archive, or terminus authority of its own.

Schema-2 packets add binding to that account. Every packet names its `packet_id`; a schema-2 packet also names its `revision_id`, `dispatch_attempt_id`, and the committed `source_head` it was prepared against, so it can be placed beside the revision and the dispatch attempt it belongs to. Legacy schema-1 packets keep their `packet_id` but have no revision, attempt, or source binding, and project as legacy-unbound; read them as such. Preparation allocates a fresh dispatch attempt per task on a revised plan, so several packets for one task are separate candidate attempts, not one attempt repeated, and manager report attempts such as `r1` are a separate namespace recorded as an association with the dispatch id. Next-batch packets carry empty `delivered_entries` with an explicit `empty_reason`, because that path returns existing task descriptions and Tier 2 extracts and assembles no knowledge entries. That emptiness is not missing receipt proof. Every assembly path leaves receipt unknown, and the delivered-stage record is the delivery evidence to weigh. Packet assessment rows keep their verdict, null, and missing behavior; rows for schema-2 packets carry the identity fields while staying in the schema-1 assessment vocabulary.

The work reader's contract 2 carries a `packet_summary` list derived only by `scripts/work-evidence.py`. Each entry is `{packet_id, task_id, dispatch_attempt_id, revision_id, binding, receipt}`, with `binding` one of `current`, `stale` with reason `revision-mismatch`, `legacy-unbound`, `unknown`, or `invalid`, the same vocabulary the full packet records use. The coordinator status exposes exactly this summary. Retro reads the same work evidence and keeps the full packet rows and source envelopes beside it, as the TUI does, so the binding retro reports is the one derivation every reader sees. Use the summary to locate a packet's binding and the full row to weigh what was delivered and what receipt it lacks.

Read the states literally, as with every other source. An envelope that is not `read`, or a record that is stale or unknown, is not a passing result and does not supply a zero denominator. A calculation that requires that source keeps its `not-computable` disposition, and the retro reports the envelope's state and reason in its place. Calculations that do not depend on that source proceed as usual. One absent ledger does not empty the pack.

Review output and report bodies travel in the projection under store-relative references, so a manifested review is judged from the pack alone. There is no private-file fallback. An envelope the pack could not read is reported as such.

The projection's `review_summary` lists every review attempt as `{attempt_id, state, reason, revision_id, purpose, ceremony, binding, result_ids, outcomes, prepared_path}`, with `seal_path`, `outcome`, `verdict`, and `execution_evidence` present once the attempt is sealed. `state` is `sealed`, `unsealed`, `unreadable`, or `missing`. An unsealed attempt is a prepared review with no verdict yet, not a failed one. An unreadable attempt has an artifact on disk that the pack could not parse or validate. A missing attempt is one a schema-2 outcome refers to whose prepared artifact is absent; it is reported from the outcome row with its reason and never becomes the bound current review. The work reader derives this list once, and the TUI and coordinator read the same rows, so retro does not fold review directories itself. A sealed review's citations are frozen copies in `cited-results.json`, so weigh a cited result against the frozen row rather than the live results ledger; `execution_evidence: none` with its stated reason is an authored limitation of the judgment, not a missing source. The `revision.review_requirement` field carries `{state, reason, value, revision_id, decision_id, inherited_from_revision}`. A `required` value records an obligation and never a gate, so a required review still outstanding beside an explicit `proceed` decision is a fact to report, not an inconsistency to resolve. Outcomes filed with a schema-1 manifest project as legacy-unbound because no revision was recorded for them. Sealed review artifacts participate in source identity like every other envelope; the two exclusions named below are the only ones.

**Source identity.** `source_data.cycle_work` carries the semantic work projection, and its content identity covers every evidence envelope and its substantive content, including each envelope's raw `sha256`. A source that moves from malformed to valid changes identity even when the parsed shape looks unchanged. Two things are excluded from identity: retro's own completion atoms in the execution log, and the evidence-pack and filing artifacts retro itself generates. Nothing else is excluded. The public raw work view still delivers the execution log in full. The pack `source_data` semantic view excludes prepare-only entries and the headers associated with them. Parsed `Spec-outcome-record` entries in that log participate in identity on their own terms and are not removed by the completion-atom filter.

#### Legacy close bundle

`impl-close.sh` writes a nine-field, unversioned `retro-bundle.json` at implementation close. The projection reads it as a declared legacy-v0 snapshot, and the pack carries its fields, provenance, and coverage as written. Its producer and write timing are unchanged.

Treat the bundle as a record of the last close, not as current revision truth. Where the bundle and the revision-bound result history disagree, the disagreement is a fact about timing to report, and the result history is the record that names revisions. A missing bundle is `absent`. That establishes only that no bundle exists, not why. A bundle that exists but does not parse is `unreadable`. Neither state says anything about the work's outcome.

The required fact groups are `cycle_artifacts`, `task_context_backlinks`, `session_retrieval_friction_packets`, `review_events`, `scale_signals`, `scorecard_eligibility_deltas`, `telemetry_attribution_rework`, `packet_delivery`, and `packet_assessments`. A fact group is `available | absent | not-computable`; non-available facts carry `values: null` and a reason.

`packet_delivery` is read from the `cycle_work` packet summary: how many distinct packets this cycle built, how many stayed assembled candidate sets, how many a dispatcher synthesized or waived, the kept/dropped/added totals with the packets excluded from each total and why, and the binding, delivery-state, and receipt-state counts. `packet_assessments` is the registered `packet_assessments` reader's cycle summary: eligible and observed packets, observations kept distinct per packet and per recipient transcript, confirmed and unconfirmed dispatches, and for each verdict class — `unused`, `harmful`, `missing`, `unattributed_retrieval` — how many observations could be assessed, how many findings they carried, and how many could not be assessed with their reasons. A class with `findings: 0` was assessed and found clean; a class with `findings: null` was not assessable. The full observation summaries sit in `source_data.packet_assessments`, keyed by opaque identities: transcript paths, queries, and verdict bodies never enter the pack. `session_retrieval_friction_packets` keeps its name and its two existing sources, session events and journal entries; it does not read packets, and the two facts above are where packet evidence lives.

Every calculation row names its calculation/version, source IDs, numerator, denominator, value, unit, sample floor, threshold, disposition, and reason. Disposition is exactly `green | tripped | abstained | not-computable`.

#### Absence is never green

Treat each state literally:

- `abstained` means a trustworthy statistic is below its declared floor.
- `not-computable` means the published substrate cannot support the statistic.
- `absent`, `unreadable`, `unsupported`, and `stale` are evidence states, never favorable verdicts.
- `fixed_health.state=not-computable` withholds `normal`; it does not imply `pipeline-degraded` and does not invite the lead to guess.
- a `not-assessable` D6 is an abstention on record with its reason; it is never a score, and no numeric D6 stands in for it.

The load-bearing calculations consume only the versioned published projections. Missing, unreadable, stale, malformed, or below-floor evidence keeps the calculation's emitted `not-computable` or `abstained` disposition and its reason — never green. An empty window is below sample, not proof of health.

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

#### Verification vocabulary

Verification is in-band and agent-owned. An agent that checks a knowledge entry against code reports `held` when the code confirms the entry and `contradicted` when it falsifies it, and every `contradicted` report names the resolution its reporter owned: `corrected` rewrote the entry in place, `disputed` left a dated marker for the next agent with wider context. Both are settled outcomes. Read a `disputed` marker as work completed and open to revision, never as queue depth.

Compatibility guard: there is no out-of-band queue, no backlog, and no sidecar lifecycle to fold, so there is no routing rate, no backlog depth, and no lag statistic to compute or report over verification. Reject the retired lifecycle words `pending`, `routed`, `verified`, `rejected`, `accepted`, `declined`, and `remediated` as verification statuses. The resolution vocabulary is exactly `corrected | disputed`, and a contradiction has no state between its report and its resolution.

### Step 3: Adjudicate the Cycle

The pack answers what was present and what fixed rules produced. The lead answers what it means.

Reports, review artifacts, result attempts, and claims are inside the `cycle_work` evidence envelopes. Judge them from the pack rather than opening the work directory. Read the cycle artifacts named in `source_manifest`, then write concise judgments grounded by `source:<source_id>`, `calculation:<calculation_id>`, or `pack:<JSON Pointer>` references. A source gap may itself support a diagnosis, but it cannot support a favorable deterministic claim.

#### Dimension scores

Score D1–D5 from 1–5, score D6 from 1–5 or record why it cannot be scored, and give a concrete rationale for each. Do not adjust a score merely to agree with a deterministic headline; disagreement between the two is diagnostic. Each dimension's anchor line below is the same text the frozen rubric carries.

##### D1 — Knowledge Delivery

Judge whether relevant knowledge reached the working agents and shaped their choices. Implementation output is valid evidence of internalization; citation is not required. Review work should show knowledge preambles. Spec-only work is predictive.

Delivery has exactly two tiers and they are scored separately. Task-level delivery is the `**Knowledge context:**` a plan attached to one task's own files; cross-cutting delivery is the material the plan aimed at the whole cycle rather than at any single task. Deduplicate within each tier and across the pair: an entry delivered to one task counts once for that task however often it appears there, and an entry that is both cross-cutting and attached to a specific task counts once in each tier and no more.

Read the cycle's tasks from the generated-task envelope in the `cycle_work` projection before scoring either tier. When that envelope is `read`, its content is the cycle's `tasks.json`. When it is `absent`, `unreadable`, or `unsupported`, both tiers are a delivery-evidence gap carrying the envelope's reason, not a zero numerator. Other calculations that do not depend on the task list are unaffected. Prefer the top-level `tasks[]` array; when it is absent, flatten a valid `phases[]` into the tasks it contains and score those. A document carrying neither shape is a delivery-evidence gap — report it as one, never as a zero numerator. Equivalent delivery facts score the same whichever shape recorded them; the nesting a cycle happened to use is not a difference in delivery.

The task-level denominator is the count of generated tasks eligible for delivery. Every generated task is eligible unless the cycle names a reason it could not receive delivery — a cold-start target with no entries to deliver, or a generator artifact that is not a real unit of work. Name each exclusion in the rationale; an unnamed exclusion is a gap, not a smaller denominator. Evaluate cross-cutting delivery once for the plan and report it beside the task-level ratio; it never enters that denominator.

`5` every eligible task delivered with high completeness and cross-cutting delivery intact | `4` most eligible tasks delivered with minor gaps | `3` low annotation quality or spec-only agents lacked available context | `2` eligible tasks with no delivery, unresolved delivery, or a silent pipeline drop | `1` no delivery

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

##### D6 — Packet Utility

Judge whether the packets built for this cycle gave their recipients useful prior knowledge at the point they needed it, kept irrelevant and harmful material out of their way, and reduced rediscovery of what the store already held. This is a judgment about use. The pack hands you four different kinds of evidence about a packet, and the score rests on the fourth:

- **Construction.** A packet was assembled: one retrieval pass produced a candidate set. `facts.packet_delivery` counts these as `unique_packets` and `assembled_candidates`.
- **Synthesis.** A dispatcher read the candidate set and recorded what it kept, dropped, and added, or waived synthesis with a reason. `synthesized_packets`, `synthesis_counts`, and `waivers` describe that judgment. It is the dispatcher's read of the packet, not the recipient's.
- **Receipt.** `receipt_state_counts.delivered`, and `dispatch_confirmed` on an assessment observation, say a recipient session ran with the packet in hand. Receipt is not use.
- **Observed utility.** The assessor read a recipient's transcript and recorded findings per class in `facts.packet_assessments`: entries delivered and never used, entries that misled, knowledge the recipient needed and the packet lacked, retrieval the recipient did that the packet should have covered. Beside those findings sit the recipient's own outcomes in the `cycle_work` envelopes — what a report says it had to derive, what its claims and verification events cite.

A synthesized packet is evidence of construction and of one colleague's judgment, not evidence that anyone read it. `dispatch_confirmed` is evidence of receipt, not of usefulness. Counts describe opportunity and gaps: how many packets, how many recipients were observed, how much went unused, what could not be assessed. They inform the score and never produce it. No arithmetic over `packet_delivery` or `packet_assessments` yields a D6 value, and an assessor's silence — a class that was not assessable, a recipient with no observation — is not a clean bill.

`5` recipients worked from packet entries at the point of need, with no harmful material and no rediscovery of what the packet carried | `4` packet entries shaped the work with one minor gap: a little unused material, or one rediscovery the packet could have spared | `3` the packet was topical but the recipient rediscovered much of it, or unused material outweighed what was used | `2` the packet mostly missed the need: recipients derived their prior knowledge elsewhere while it carried irrelevant or stale material | `1` packet material misled a recipient or obstructed the work

D6 is the one dimension that may abstain. When the cycle built no eligible packets, or when no recipient-use evidence exists — every verdict class not assessable, no observation inside the window, an assessment source that is absent or unreadable — record `disposition: not-assessable` with `score: null`, a `reason`, and the evidence references that show the gap. The judgment stays in the filing artifact; no numeric D6 reaches the journal or a scored row. Do not translate absence into a number: a 1 says the packet misled someone, a 3 says it half-helped, a 5 says it was used well, and none of those is what missing evidence says. A scored D6 needs concrete packet evidence and a recipient outcome to read it against.

Evidence references for D6 look like `source:packet_assessments`, `pack:/facts/packet_delivery`, `pack:/facts/packet_assessments/values/classes/unused`, `pack:/source_data/packet_assessments/summary/observation_summaries/0`, and the `cycle_work` report envelope of the recipient whose work the score rests on. An abstention cites the fact group itself — `pack:/facts/packet_delivery` or `pack:/facts/packet_assessments`, with `source:packet_assessments` — because a group whose status is `absent` or `not-computable` carries `values: null` and no pointer beneath it resolves.

D5 and D6 coexist on a new cycle and measure different things. D5 asks whether the spec spared the workers needless exploration; D6 asks whether the packet carried prior knowledge to the point of need. Neither replaces the other, and a D6 that cannot be scored says nothing about D5.

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

#### Fixed health

Read `fixed_health` and its referenced calculation rows before reading headline or delta facts. The script is the sole home for arithmetic, floors, thresholds, and which calculations are load-bearing; this skill names meanings and judgment boundaries only.

- `normal`: all load-bearing calculations produced trustworthy non-tripped results.
- `warmup`: at least one trustworthy calculation abstained below floor and none tripped.
- `pipeline-degraded`: a fixed calculation tripped. Lead with the tripped calculation IDs and withhold scorecard interpretation.
- `not-computable`: at least one load-bearing calculation lacks a trustworthy published substrate. Lead with the missing source/reason and withhold a healthy headline.

Healthy checks remain silent in the report — green narration turns to ritual and buries the one check that trips. This is load-bearing healthy silence, not permission to omit pack rows.

Respect each calculation's source-coverage and disposition fields. Source drift, a missing timestamp, or an unavailable projection cannot become a zero numerator.

### Step 4: Author the Judgment Manifest

Build a v2 object with exactly:

```text
schema_version, cycle_id, pack_id, pack_sha256, rubric_id, rubric_version,
actor, model, key_finding, most_actionable_gap, dimension_judgments,
behavioral_health, causal_diagnoses, escalation_judgment,
scale_access_judgment, channel_flags, suggestion_outcome, suggestions
```

`schema_version` is `2`. Set `pack_sha256` to the pack's `artifact_sha256`, not the serialized file digest. Copy `rubric_id` and `rubric_version` from the pack's `rubric` member; filing refuses a manifest whose identity differs from the frozen descriptor.

`dimension_judgments` is ordered exactly D1–D6. Each row is `{dimension_id, disposition, score, rationale, evidence_refs}`. A scored row has `disposition: scored` and an integer `score` from 1 to 5. A `not-assessable` row has `score: null` and adds a non-empty `reason`; only D6 may carry it. Every row keeps a non-empty rationale and at least one resolving evidence reference, abstentions included. `behavioral_health` is an ordered array of `{check_id, answer, evidence_refs}` and includes Check 7. `causal_diagnoses` is an array of `{diagnosis_id, interpretation, evidence_refs}` and may be empty.

A pack with no `rubric` member is a retained legacy pack. It takes the v1 manifest — the same root without `rubric_id` and `rubric_version`, `schema_version` 1, and `dimension_judgments` ordered exactly D1–D5 as `{dimension_id, score, rationale, evidence_refs}` — and files into its original sink set. A rubric-bound pack refuses a v1 manifest, and a legacy pack refuses a v2 one. Replaying a retained legacy filing never adds a D6, a guessed version, or a dimension row it did not originally have.

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

The immutable assignment requires primary, behavioral, escalation, proposal, scale-access, channel-flag, dimension, and completion-telemetry sinks. Their replay identities are unchanged: the primary, behavioral, and escalation journal rows match on `role + work_item + filing_id + sink`; each substantive proposal on that journal identity plus its `proposal ordinal`; scale access on `cycle_id` with exact writer-field equality; channel flags on `cycle_id + role + slot + signal_type` with exact field equality; each dimension row on `filing_id + rubric_id + rubric_version + dimension_id`; completion telemetry on `event_type=retro-filing + filing_id`.

The primary journal row carries the numeric scores under their journal keys and the `rubric_id` and `rubric_version` at the entry root; `scores` holds numbers only. Each scored dimension also lands one `scorecard:dimension:<id>` row through the scorecard writer: `kind=scored`, `tier=template`, `template_id=retro-rubric`, `template_version=<rubric_version>`, `metric=<journal_key>`, `value=<score>`, `sample_size=1`, `calibration_state=pre-calibration`, `verdict_source=retro-lead`, with the filing, pack, model, window bounds, rationale, and evidence references beside them. A `not-assessable` D6 has no journal key and no scored row; its judgment lives in the filing artifact alone. These rows are observations kept for later comparison. They are pre-calibration, they satisfy no calibrated evidence floor, and they rate no agent.

Every write goes through its sanctioned writer: `journal.sh`, `retro-scale-access-append.sh`, `retro-channel-flag-append.sh`, or `scorecard-append.sh`. The verb never appends their files directly. Completion telemetry is last.

On `status=partial`, the judgment is accepted but the filing is incomplete. Preserve the immutable manifest, repair the named sink condition, and replay the exact same command; replay invokes only missing writers. Do not edit the manifest to work around a sink failure; a semantic difference is a collision, not a revision.

### Step 6: Report

Lead with the deterministic evidence state:

```text
[retro] <cycle>
  pack: <pack_id> (<created|reused|recovered|replaced>)
  fixed health: <normal|warmup|pipeline-degraded|not-computable>
  evidence: <envelopes not read, each with state and reason, or all read; results whose freshness is stale or unknown, with reasons>
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
6. D1–D6 as the narrative coda, with a `not-assessable` D6 reported as such and never as a number;
7. `substantive` suggestion titles or the explicit `no-substantive-suggestion` outcome.

When health is `pipeline-degraded` or `not-computable`, do not place pass/weak/fail prose above the evidence warning. When a below-floor calculation abstains, say `abstained: below-sample`; never translate it to weak, fail, or green.

`/retro` never edits proposal targets. `/evolve` remains the only consumer that applies substantive `retro-evolution` suggestions. A no-suggestion filing gives `/evolve` nothing to consume, by design.

### Reading scores across the rubric boundary

Historical journal entries carry `d5_spec_utility` and no rubric identity. New entries carry `rubric_id` and `rubric_version` at the entry root, and `d6_packet_utility` beside `d5_spec_utility` whenever D6 was scored. The journal reader labels an unversioned entry `legacy-unversioned` with a null version at read time and leaves its stored bytes untouched; no historical score is renamed, re-keyed, or given a version it never had. Nothing pools these series. When you want to look across the boundary, choose the columns yourself:

```bash
lore journal query --role retro --extract-scores --json |
  jq '[.[] | {date: .timestamp, rubric_id, rubric_version,
              d5_spec_utility: .scores.d5_spec_utility,
              d6_packet_utility: .scores.d6_packet_utility}]'
```

Example output, with an illustrative version:

```json
[
  {"date":"2026-07-01","rubric_id":"legacy-unversioned","rubric_version":null,"d5_spec_utility":3,"d6_packet_utility":null},
  {"date":"2026-09-06","rubric_id":"retro-rubric","rubric_version":"3f9a1c2b7d4e","d5_spec_utility":4,"d6_packet_utility":4},
  {"date":"2026-09-12","rubric_id":"retro-rubric","rubric_version":"3f9a1c2b7d4e","d5_spec_utility":4,"d6_packet_utility":null}
]
```

The first row predates the rubric declaration: its version is unknown and it never had a D6. The third row was scored under the current rubric and abstained on D6, so its null means `not-assessable`, not zero and not lost data. D5 and D6 share a 1–5 range and have no common scale: one measures what the spec spared, the other what the packet carried. A change in either column across rows is a fact about two different judgments made on two different cycles; it becomes an improvement or a regression only once someone has argued why, and this reader will not argue it for you. The scorecard's aggregate readers group scored rows by `(template_id, template_version, metric)`, so a rubric edit starts a new series rather than extending the old one, and a comparison across versions is likewise one you make and defend.
