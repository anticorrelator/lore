# Tier 2 Evidence Schema (`task-claims.jsonl`)

This document is the canonical schema reference for Tier 2 producer evidence rows. The validator (`scripts/validate-tier2.sh`) and the sole-writer (`scripts/evidence-append.sh`) are the authoritative implementations; this document explains the shape they enforce.

One row per claim. JSONL — one JSON object per line. Sole writer: `evidence-append.sh`.

## Required fields (fast-path)

| Field | Type | Notes |
|---|---|---|
| `claim_id` | string | Unique within the work item. |
| `tier` | string | Must equal the literal `"task-evidence"`. |
| `claim` | string | Non-empty. The assertion being substantiated. |
| `producer_role` | string | One of `researcher`, `worker`, `advisor`, `spec-lead`, `implement-lead`. |
| `protocol_slot` | string | Where in the protocol this was emitted (e.g. `implement-phase-1`). |
| `task_id` | string | Task ID this claim is attached to. |
| `phase_id` | string | Phase ID this claim is attached to. |
| `scale` | string | One of the IDs from `scale-registry.sh get-ids`; `"unknown"` is rejected. |
| `file` | string | Non-empty path to the file the claim anchors on. |
| `line_range` | string | `N-M` with `N <= M`. |
| `exact_snippet` | string | Verbatim substring of `file` at `line_range`. Non-empty. |
| `normalized_snippet_hash` | string | Lowercase 64-char hex, equal to `sha256(v1_normalize(exact_snippet))`. The v1 recipe lives only in `scripts/snippet_normalize.py`. |
| `falsifier` | string | Non-empty. How the claim could be falsified. |
| `why_this_work_needs_it` | string | Non-empty. Why this claim is load-bearing for the work item. |
| `captured_at_sha` | string | `git rev-parse HEAD` at capture time. |
| `change_context` | object | See below. |

### `change_context` (required on fast-path rows)

| Field | Type | Notes |
|---|---|---|
| `diff_ref` | string \| null | Optional diff reference. |
| `changed_files` | array of non-empty strings | Must include `file`. |
| `summary` | string | Non-empty. |

## Slow-path (legacy migration) terminal state

Pre-Phase-1 rows backfilled by the migration writer (`evidence-update.sh`) carry `provenance: "legacy-no-snippet"` and:

- MUST omit both `exact_snippet` and `normalized_snippet_hash`.
- MAY omit `change_context` (D2 grandfather waiver).
- MUST satisfy every other required field.

`evidence-append.sh` rejects the legacy marker at the writer-path gate. Only the migration writer is sanctioned to emit it.

## Optional source-anchor metadata (additive, non-gating)

Derived automatically by `evidence-append.sh` at capture time. The validator type-checks them when present but never requires them — pre-existing rows without these fields continue to validate.

| Field | Type | Derivation |
|---|---|---|
| `file_relative` | string | Path of `file` relative to its nearest `.git/` ancestor. When `file` is already a relative path, equal to `file` verbatim. Omitted silently when no `.git/` ancestor exists. |
| `captured_origin_ref` | string \| null | First ref under `refs/remotes/origin/` that contains the cwd repo's HEAD (e.g. `"origin/main"`). `null` when HEAD is not reachable from any `origin/*` ref. Omitted when not inside a git work tree. |
| `anchor_warning` | string | Set to `"unpushed_local_only"` iff `captured_origin_ref` is `null`. `evidence-append.sh` additionally emits a single-line stderr soft-warning so the producer sees the anchor is fragile. Capture continues — this is informational, not gating. |

These fields exist to give the audit-side claim-reconciliation cascade (see `architecture/evidence/claim-reconciliation-in-lore-anchors-on-content-no.md`) a stable mid-tier anchor between the volatile `captured_at_sha` (orphaned by squash) and the over-broad `origin/main` (which decays as the file evolves). Phase 2's preflight cascade reads them; Phase 1's substrate captures them.

## Validation model

- Validation is inline jq + Python in `scripts/validate-tier2.sh`. No separate JSON Schema file. See `[[knowledge:conventions/schema-validation-in-settlement-sidecar-substrate]]`.
- `evidence-append.sh` is the sole sanctioned writer for new producer rows. Bypassing it silently invalidates the evidence trail for the work item.
- The validator is read-only and idempotent — safe to invoke from tests, hooks, and audits.
