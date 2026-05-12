# Correction Candidate Schema

### Summary

`_work/<slug>/correction-candidates.jsonl` is the pre-calibration source of
truth for settlement-emitted "this claim contradicts a commons entry" verdicts.
Rows are appended by the sole-writer `scripts/correction-candidate-append.sh`
after the settlement post-verdict hook resolves a `contradicted` verdict
against a target commons entry. The sidecar is *never* mutated directly;
downstream calibration (out of scope for this work item, lives in `/evolve`)
reads it and — on elevation — emits a `tier=correction` scorecard row that
`apply-correction.sh` consumes.

This schema is the bridge between settlement verdicts and the eventual
commons mutation. It carries enough provenance to let the calibration pass
reconstruct (a) which settlement run produced the verdict, (b) which target
entry the resolver selected, (c) the originating task-claim anchor, and
(d) a stable dedupe key so re-runs of the post-verdict hook are no-ops.

## Sole-writer invariant

`scripts/correction-candidate-append.sh` is the only sanctioned writer of
`$KDIR/_work/<slug>/correction-candidates.jsonl`. All schema validation
happens before any filesystem access; rejected rows never reach disk. No
read-modify-write on the sidecar — appends only.

## Required fields

Every row MUST carry these top-level fields, all non-empty:

| Field                        | Type   | Notes |
| ---------------------------- | ------ | ----- |
| `candidate_id`               | string | Producer-generated. Stable handle for downstream references. Defaults to `cc-<12 hex>` when not supplied. |
| `candidate_for_verdict_id`   | string | The originating `settlement_run_id` (the verdict envelope this candidate was emitted for). Dual-keyed with `settlement_run_id` for clarity; see "Dual-key verdict_id" below. |
| `settlement_run_id`          | string | The settlement run that produced the verdict. Same value as `candidate_for_verdict_id` at emission time. |
| `work_item`                  | string | Work-item slug (matches the `_work/<slug>/` parent directory). |
| `claim_id`                   | string | Tier 2 `claim_id` from `task-claims.jsonl` that the settlement verdict scored. |
| `target_entry_path`          | string | Commons-entry path the resolver selected as the contradiction target. KDIR-relative. |
| `target_rank`                | number | 1-based rank of this entry in the resolver's `--json` output. Integer ≥ 1. |
| `target_overlap`             | bool   | Whether the resolver flagged a token-overlap match (true) vs. similarity-only (false). |
| `target_sim`                 | number | Similarity score from the resolver. Float in `[0.0, 1.0]`. |
| `verdict`                    | string | Literal `"contradicted"`. Other settlement verdicts (`grounded`, `inconclusive`, etc.) do not produce candidates. |
| `verdict_evidence`           | string | Free-text evidence excerpt from the settlement verdict envelope. |
| `verdict_correction_text`    | string | The proposed correction prose from the settlement verdict envelope. |
| `task_claim_anchor`          | object | See "task_claim_anchor sub-schema" below. Carries enough provenance to re-locate the originating task-claim row. |
| `resolver_version`           | string | Hash identifying the resolver implementation that produced the target match. Part of `dedupe_key`. |
| `emitted_at`                 | string | ISO-8601 UTC timestamp at emission. Defaults to `timestamp_iso()` when not supplied. |
| `dedupe_key`                 | string | 64-char hex sha256 of `candidate_for_verdict_id|target_entry_path|resolver_version`. Re-emission with the same key is a silent no-op (exit 0). |

### task_claim_anchor sub-schema

`task_claim_anchor` is an object with five required string fields:

| Sub-field         | Type   | Notes |
| ----------------- | ------ | ----- |
| `file`            | string | Absolute path the originating claim was anchored to. |
| `line_range`      | string | `N` or `N-M` (matches the Tier 2 `line_range` shape). |
| `scale`           | string | One of `abstract`, `architecture`, `subsystem`, `implementation` (Tier 2 declared scale). |
| `producer_role`   | string | Producer role of the originating claim (e.g., `worker`, `researcher`). |
| `change_context`  | object | Free-form context object passed through verbatim from the Tier 2 row's `change_context`. |

## Idempotency

`dedupe_key = sha256(candidate_for_verdict_id|target_entry_path|resolver_version)`.

Re-emission with the same key is a silent no-op (exit 0; no duplicate
line written). This makes the post-verdict hook safe to retry and the
reconciliation backstop safe to re-fire. The dedupe check linear-scans
the sidecar; volume is bounded by the settlement queue depth per work
item, which is small.

## Dual-key verdict_id (downstream-consumer contract)

Per plan D6 and Codex Round 2 P3: when `/evolve` calibration eventually
elevates a candidate, the resulting `tier=correction` scorecard row MUST
set **both** `verdict_id = settlement_run_id` AND
`calibrated_by_verdict_id = settlement_run_id`. Rationale:

- `scripts/scorecard-append.sh` validates `tier=correction` rows by checking
  `calibrated_by_verdict_id` (and `corrected_entry_path`,
  `correction_target ∈ {claim|observation|doctrine}`).
- `scripts/apply-correction.sh:171` looks up the row by the field name
  `verdict_id`, not `calibrated_by_verdict_id`.

Setting only one of the two would either fail the append validator (missing
`calibrated_by_verdict_id`) or be invisible to `apply-correction.sh`
(missing `verdict_id`). This work item documents the contract; the actual
dual-key write happens in the `/evolve` calibration consumer, not here.

## CLI

```
correction-candidate-append.sh \
    --work-item <slug> \
    --candidate-for-verdict-id <id> \
    --settlement-run-id <id> \
    --claim-id <id> \
    --target-entry-path <path> \
    --target-rank <int> \
    --target-overlap true|false \
    --target-sim <float> \
    --verdict-evidence <text> \
    --verdict-correction-text <text> \
    --task-claim-anchor-file <abs-path> \
    --task-claim-anchor-line-range <N-M> \
    --task-claim-anchor-scale <scale> \
    --task-claim-anchor-producer-role <role> \
    --task-claim-anchor-change-context <json> \
    --resolver-version <hash> \
    [--candidate-id <id>] \
    [--emitted-at <iso8601>] \
    [--kdir <path>] \
    [--json]
```

`--verdict` is fixed to `"contradicted"` and not configurable — settlement
emits candidates only for `contradicted` verdicts. Other verdicts produce
no row.

Exit codes:
- `0` — row appended OR deduped no-op.
- `1` — validation failure, unknown flag, or work-item not found.

In `--json` mode, successes emit `{"path", "candidate_id", "dedupe_key",
"appended": true}` on stdout; failures emit `{"error": "[correction-candidate] ..."}`
with exit 1.
