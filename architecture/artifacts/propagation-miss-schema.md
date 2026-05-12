# Propagation Miss Schema

### Summary

`_work/<slug>/propagation-misses.jsonl` is the **operational-failure log** for
the settlement → commons propagation chain. Rows are appended by the sole-writer
`scripts/propagation-miss-append.sh` when the propagation backstop
(`scripts/propagation-reconcile.sh`) — or any other detector — observes that a
settlement run that *should* have produced a downstream artifact did not.
Examples: a post-verdict hook crashed, the hook was disabled at the time of the
verdict, the emit script crashed, or Tier-2 evidence rehydration failed.

This sidecar exists to make the propagation chain auditable end-to-end. Without
a dedicated miss log, an operational failure looks identical to the legitimate
"contradicted verdict, but no commons target was discoverable" outcome — and
the two demand very different responses (re-run the hook vs. file a report).

## What this sidecar is NOT for

`propagation-misses.jsonl` captures **operational failures only**. A
contradicted verdict that legitimately produced **zero** correction targets is
NOT a miss — that signal belongs in `filtered-claims.jsonl` with
`stage=post-verdict` (see [[knowledge:design/heuristic-vs-definite-condition-hooks]]).

The discriminator is:

| Signal                                                       | Goes to                              | Rationale |
| ------------------------------------------------------------ | ------------------------------------ | --------- |
| Post-verdict hook crashed before emitting                    | `propagation-misses.jsonl`           | Operational |
| Post-verdict hook disabled in settings; verdict had no later run | `propagation-misses.jsonl`        | Operational |
| Emit script (`correction-candidate-append.sh`) crashed       | `propagation-misses.jsonl`           | Operational |
| Tier-2 rehydration failed mid-emit                           | `propagation-misses.jsonl`           | Operational |
| Verdict ran cleanly; resolver returned zero targets          | `filtered-claims.jsonl` (stage=post-verdict) | Heuristic |
| Verdict ran cleanly; concordance index was stale             | `filtered-claims.jsonl` (stage=post-verdict) | Heuristic |

Conflating the two paths would let operational regressions hide inside the
report-only filter signal and silently degrade propagation health.

## Sole-writer invariant

`scripts/propagation-miss-append.sh` is the only sanctioned writer of
`$KDIR/_work/<slug>/propagation-misses.jsonl`. All schema validation happens
before any filesystem access; rejected rows never reach disk. No
read-modify-write on the sidecar — appends only.

## Required fields

Every row MUST carry these top-level fields, all non-empty:

| Field                | Type   | Notes |
| -------------------- | ------ | ----- |
| `settlement_run_id`  | string | The settlement run the miss is anchored to. Required; the miss is meaningless without it. |
| `reason`             | string | Closed set: `hook_crashed` \| `hook_disabled` \| `rehydration_failed` \| `emit_failed`. |
| `detected_at`        | string | ISO-8601 UTC timestamp when the detector observed the miss. Defaults to `timestamp_iso()` when not supplied. |
| `work_item`          | string | Work-item slug (matches the `_work/<slug>/` parent directory). |
| `claim_id`           | string | Tier-2 `claim_id` from `task-claims.jsonl` that the settlement run was scoring. Traceback to the originating task-claim. |
| `detector`           | string | Name of the script that detected the miss (e.g., `propagation-reconcile.sh`). |
| `dedupe_key`         | string | 64-char hex sha256 of `settlement_run_id\|reason`. Re-emission with the same key is a silent no-op (exit 0). |

## Reason enum semantics

| Value                | When to emit |
| -------------------- | ------------ |
| `hook_crashed`       | The post-verdict hook started and aborted (non-zero exit, exception). |
| `hook_disabled`      | The hook was disabled in settings at the time of the verdict and no later run filled the gap. |
| `rehydration_failed` | Tier-2 evidence rehydration failed mid-emit (e.g., `task-claims.jsonl` row missing or malformed). |
| `emit_failed`        | The downstream emit script (e.g., `correction-candidate-append.sh`) exited non-zero. |

The set is closed. Adding a new reason requires updating both this schema doc
and the writer's enum validator in lockstep
(see [[knowledge:conventions/design/when-extending-closed-set-schema-field-to-support]]).

## Idempotency

`dedupe_key = sha256(settlement_run_id|reason)`.

Re-emission with the same key is a silent no-op (exit 0; no duplicate
line written). This makes the reconciliation backstop safe to re-fire on the
same settlement run without inflating the miss count. The dedupe scope is
`(settlement_run_id, reason)` — the same run failing for two *different*
reasons (e.g., `hook_crashed` first, then `emit_failed` on retry) yields two
distinct rows, which is the intended diagnostic granularity.

## CLI

```
propagation-miss-append.sh \
    --work-item <slug> \
    --settlement-run-id <id> \
    --reason <hook_crashed|hook_disabled|rehydration_failed|emit_failed> \
    --claim-id <id> \
    --detector <script-name> \
    [--detected-at <iso8601>] \
    [--kdir <path>] \
    [--json]
```

Exit codes:
- `0` — row appended OR deduped no-op.
- `1` — validation failure, unknown flag, or work-item not found.

In `--json` mode, successes emit `{"path", "dedupe_key", "reason",
"appended": true}` on stdout; failures emit
`{"error": "[propagation-miss] ..."}` with exit 1.
