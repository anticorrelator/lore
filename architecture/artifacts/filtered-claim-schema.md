### Filtered-claim sidecar — schema and contract for `_work/<slug>/filtered-claims.jsonl`

The filtered-claim sidecar records Tier-2 claims that the settlement→commons
propagation filter (D5) either *excluded* from settlement enqueue or *reported*
after a verdict without changing the enqueue decision. Each row is an append-only,
schema-validated JSON object written exclusively by `scripts/filtered-claim-append.sh`.

## Purpose

The propagation filter gates evidence rows on their viability of producing a
commons correction. Rows the filter cannot trace to a discoverable target are
either dropped (definite-invalid signals) or surfaced for review
(heuristic/unknown signals); both outcomes write a row here. Downstream
reconciliation (`propagation-reconcile.sh`) reads this sidecar to answer
"why was claim X not propagated?" without re-running the predicate.

## Sole-writer invariant

`scripts/filtered-claim-append.sh` is the only sanctioned writer of
`_work/<slug>/filtered-claims.jsonl`. All schema validation happens before
filesystem access; rejected rows never reach disk. No read-modify-write; rows
are append-only. Readers MUST treat lines that did not flow through the
sole-writer as corrupt and exclude them from aggregation.

## Required fields

| Field              | Type            | Notes                                                                                                |
|--------------------|-----------------|------------------------------------------------------------------------------------------------------|
| `work_item`        | string          | Work-item slug (mirror of the `--work-item` flag).                                                   |
| `claim_id`         | string          | Source Tier-2 claim id this filter decision pertains to.                                             |
| `reason`           | enum (4)        | `templated-claim` \| `templated-falsifier` \| `no-discoverable-target` \| `concordance-stale`.       |
| `mode`             | enum (2)        | `exclude` \| `report-only`. Drives the `enqueued_anyway` consistency rule.                           |
| `stage`            | enum (2)        | `pre-enqueue` \| `post-verdict`. **Load-bearing discriminator** — see Stage-conditional rule below.  |
| `settlement_run_id`| string          | **REQUIRED iff `stage=post-verdict`; ABSENT iff `stage=pre-enqueue`.** See rule below.               |
| `file`             | string          | Absolute path anchoring the filtered claim (passed through from the source row).                     |
| `line_range`       | string          | `N` or `N-M`. Validated by regex `^[0-9]+(-[0-9]+)?$`.                                               |
| `change_context`   | object          | Pass-through from the source row — opaque JSON object preserved verbatim.                            |
| `enqueued_anyway`  | bool            | `true` for `mode=report-only`, `false` for `mode=exclude`. Mismatches are rejected at write time.    |
| `resolver_version` | string          | Version stamp of the resolver that produced the filter decision; participates in `dedupe_key`.       |
| `created_at`       | string (ISO8601)| Write-time UTC timestamp.                                                                            |
| `dedupe_key`       | string (sha256) | `sha256(claim_id\|stage\|reason\|settlement_run_id\|resolver_version)`; 64-char lowercase hex.       |
| `captured_at_branch`         | string \| null | Branch-provenance trio; always emitted (JSON null when unavailable). |
| `captured_at_sha`            | string \| null | Branch-provenance trio; always emitted (JSON null when unavailable). |
| `captured_at_merge_base_sha` | string \| null | Branch-provenance trio; always emitted (JSON null when unavailable). |

## Stage-conditional rule (load-bearing invariant)

The `stage` field discriminates two filter paths and the conditional
`settlement_run_id` presence rule prevents the downstream reconciliation
script from miscounting pre-enqueue rows as satisfying the post-verdict
invariant:

- `stage=pre-enqueue` → `settlement_run_id` MUST be absent from the row.
  (The filter ran before any settlement attempt; there is no run id to attach.)
- `stage=post-verdict` → `settlement_run_id` MUST be present and non-empty.
  (The filter ran after settlement produced a verdict; the verdict's run id
  is required to trace the report back to its origin.)

Rows that violate this rule are rejected with exit 1 by the sole-writer.
The rule is enforced twice: once on the CLI flag pairing before serialization,
and again on the serialized row via `jq -e` (defense-in-depth).

This mirrors the tier-conditional gates in `scripts/scorecard-append.sh`
(reusable rows require `source_artifact_ids`; template rows require
`template_id` + 12-char `template_version`; etc.) — a single closed-set
discriminator drives a per-bucket required-field rule.

## Mode↔enqueued_anyway consistency

`mode` and `enqueued_anyway` are not independent; the writer enforces the
documented pairing at validation time:

- `mode=exclude`     ⇒ `enqueued_anyway=false` (the claim was NOT enqueued).
- `mode=report-only` ⇒ `enqueued_anyway=true`  (the claim WAS enqueued).

A mismatch is a malformed row and rejected with exit 1.

## Dedupe key

```
dedupe_key = sha256(claim_id | stage | reason | settlement_run_id | resolver_version)
```

When `stage=pre-enqueue` (and therefore `settlement_run_id` is absent), the
empty string is substituted in the hash input so the key remains well-defined
for both stages. Re-appending a row with a matching `dedupe_key` is a silent
no-op (exit 0, no duplicate line). This keeps lazy re-evaluation of the
predicate idempotent — the propagation filter can be re-run against the same
candidate set without producing duplicate filter records.

## Closed-set semantics

The `reason`, `mode`, and `stage` enums are CLOSED. Extending any of them
requires:

1. Updating this schema doc (additive entry with semantics + rationale).
2. Updating the validator's `case` arm in `scripts/filtered-claim-append.sh`.
3. Updating consumers (`propagation-reconcile.sh`, `settlement-processor.py`,
   any rollup/reporting scripts) to handle the new value.

Additive extension is permitted; renaming or removing existing values is a
breaking change that requires migration of the existing sidecars.

## Reader contract

Consumers MUST:

- Parse each line as a JSON object; skip blank lines.
- Treat any line missing required fields, with an invalid enum value, or
  whose `(stage, settlement_run_id)` pairing violates the stage-conditional
  rule, as corrupt — log a `[filtered-claim] warning: <slug>/filtered-claims.jsonl:<N> corrupt — <reason>`
  to stderr and EXCLUDE the row from aggregation.
- Use `dedupe_key` for idempotency; readers MUST NOT assume each
  `(claim_id, stage)` pair appears only once across reasons or resolver
  versions.
- Treat `change_context` as opaque — it round-trips an upstream object whose
  shape is producer-defined.

## See also

- `scripts/filtered-claim-append.sh` — the sole writer (CLI flags + validation).
- `scripts/scorecard-append.sh` — pattern reference for closed-set + bucket-conditional validation.
- `scripts/consumption-contradiction-append.sh` — pattern reference for sole-writer + dedupe-key idempotency.
- Work item `[[work:settlement-commons-propagation]]` plan D5 — design rationale for the two filter modes.
