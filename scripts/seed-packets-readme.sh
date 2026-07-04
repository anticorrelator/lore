#!/usr/bin/env bash
# seed-packets-readme.sh — Write $KDIR/_packets/README.md if missing.
# Usage: bash seed-packets-readme.sh <packets-dir>
#
# Called by packet-append.sh and packet-assessment-append.sh (first-use lazy
# seed). Idempotent — no-op if README already present.

set -euo pipefail

PACKETS_DIR="${1:-}"
if [[ -z "$PACKETS_DIR" ]]; then
  echo "Usage: seed-packets-readme.sh <packets-dir>" >&2
  exit 1
fi

mkdir -p "$PACKETS_DIR"
README="$PACKETS_DIR/README.md"
if [[ -f "$README" ]]; then
  exit 0
fi

cat > "$README" << 'EOF'
# _packets/

Append-only storage for context-packet delivery records and their post-hoc
assessments. A packet is the evaluable unit of knowledge delivery: one row
per delivery event recording exactly what was handed to an agent, at what
trust, under what budget. Assessments are verdicts about a delivered packet
written after the receiving session ends.

## Contents

- `packets.jsonl` — append-only; one JSON object per line; the delivery
  record stream. Sole writer: `scripts/packet-append.sh`.
- `assessments.jsonl` — append-only; one JSON object per line; the
  post-hoc verdict stream. Sole writer:
  `scripts/packet-assessment-append.sh`.

## Sole-writer invariant

One sanctioned writer per file. `packet-append.sh` is the **only** writer
of `packets.jsonl`; `packet-assessment-append.sh` is the **only** writer of
`assessments.jsonl`. No other script, skill, agent prompt, or human process
may append to, edit, or truncate either file directly. If a second write
verb is ever needed, it must be a thin front that shells out to the file's
existing appender — never a second physical appender. Every append is
validated against schema v1 (`scripts/packet_schema.py`) before any disk
touch; rejected rows never reach disk.

## Append-supersede posture (no dedupe)

Both files are append-only **without dedupe**. Each packet row is a
point-in-time delivery event: re-dispatching the same content is a new
delivery and produces a new row; running the same append twice produces two
rows. The same holds for assessments — a re-assessment is a new row. To
supersede a row, write a new one; never rewrite history. Readers that need
"latest" semantics order by `delivered_at` / `assessed_at`.

## Prompt-context invariant

Packet and assessment rows are **never** loaded into any agent prompt — no
skill, hook, or prefetch surface may inject them. The packet measures
delivery quality for agents whose behavior the graduation experiment
compares; letting a measured agent see its own delivery record or verdicts
contaminates the measurement. Consumers are offline readers only: the
graduation experiment, the packet assessor, `/retro`, and the demand-led
capture miner.

## Packet row schema (v1)

Every field traces to a named consumer. "Experiment" is the
compilation-graduation experiment (this substrate's first consumer, whose
runbook lives in the owning work item); "assessor" is the post-session
packet assessor; "/retro D2/D3" are the retro skill's delivery-quality and
gap dimensions; "miner" is the demand-led capture miner
(`mine-retrieval-misses.py`).

### Identity and join keys

| Field | Type | Consumer |
|---|---|---|
| `packet_id` | non-empty string | assessor (joins verdicts to deliveries); experiment (packet identity across arms) |
| `packet_scope` | `session` \| `task` | assessor (selects assessment mode); experiment (task rows only) |
| `delivery_stage` | `assembled` \| `delivered` | assessor (dispatch-confirmation: task rows stay `assembled` until an assessment confirms handoff) |
| `session_id` | string or null | assessor (transcript join); experiment (session grouping) |
| `work_item` | string or null | experiment (matched-task pairing); /retro D2/D3 (cycle scoping) |
| `phase` | string, integer, or null | experiment (pairing); /retro D2/D3 |
| `task_id` | non-empty string for `task` scope; **must be null** for `session` scope | experiment (matched-task pairing); assessor |
| `arm` | string or null — null unless an experiment runner stamped it; never inferred | experiment (arm grouping) |
| `task_scale_set` | string or null | experiment (abstraction-moderation covariate). Task-level declaration — distinct from any per-call `scale_set` retrieval provenance; do not conflate |

### Delivered entries

`delivered_entries` is an array; it may be empty **only** with a non-empty
`empty_reason` string (consumer: assessor — distinguishes "nothing relevant"
from a broken emitter). When the array is non-empty, `empty_reason` must be
absent or null. Each element:

| Field | Type | Consumer |
|---|---|---|
| `path` | non-empty string (KDIR-relative entry path) | assessor (unused/harmful verdicts); miner (missing-gap joins) |
| `render_mode` | `full` \| `summary` \| `snippet` \| `backlink` \| `skipped` — union of the dispatch-manifest ladder (full/snippet/backlink) and the session-load tiers (full/summary/skipped) | assessor (was content present or only referenced); /retro D2 |
| `trust.score` | number or null — the **live-fold ledger score** at delivery, never the cached `trust_score` column | experiment (trust-pricing covariate); /retro D3 |
| `trust.status` | non-empty string (entry status at delivery) | experiment; /retro D3 |
| `trust.confidence` | non-empty string (entry confidence at delivery) | experiment; /retro D3 |
| `trust.correction_recency` | string or null | experiment; /retro D3 |
| `ranking_path` | `search-order` (trust-weighted) \| `composite-rerank` (trust-blind) | experiment (which ranking the entry experienced is itself a covariate) |

Per-entry ledger event counts are deliberately **not** stored: the trust
ledger's fold is order-independent and append-only, so counts as-of
`delivered_at` are reconstructable by joining ledger rows with
`observed_at <= delivered_at`.

### Budget accounting

| Field | Type | Consumer |
|---|---|---|
| `budget.chars_used` | integer >= 0 or null | /retro D2 (delivery quality); experiment |
| `budget.chars_budget` | integer >= 1 or null | /retro D2; experiment |

Extra keys under `budget` (e.g. per-tier counts) are permitted.

### Stamps

| Field | Type | Consumer |
|---|---|---|
| `delivered_at` | ISO 8601 string (writer-stamped when absent) | assessor (ordering); experiment; trust-ledger as-of joins |
| `schema_version` | the string `"1"` (writer-stamped) | all readers (upgrade policy) |
| `packet_schema_sha` | 64-char sha256 hex of `packet_schema.py` (writer-stamped, authoritative) | all readers (schema-drift detection across rows) |
| `trust_compute_sha` | 64-char sha256 hex of `trust-compute.py` — freezes the fold identity so score semantics don't drift across the experiment window | experiment; /retro D3 |
| `template_version` | 12-char hex or null — template of the receiving agent; register via `template-registry-register.sh` like scorecard rows | experiment; /retro D2 |
| `model` | non-empty string (writer-stamped: row > `--model` > `LORE_MODEL` > `unrecorded`) | /retro, experiment (model-generation segmentation) |
| `captured_at_branch` / `captured_at_sha` / `captured_at_merge_base_sha` | string or null (writer-stamped trio) | all readers (branch provenance) |

## Assessment row schema (v1)

| Field | Type | Consumer |
|---|---|---|
| `packet_id` | non-empty string — references exactly one packet row | experiment; /retro D2/D3 |
| `assessed_at` | ISO 8601 string (writer-stamped when absent) | /retro (windowing) |
| `assessor_schema_sha` | 64-char sha256 hex of the assessor artifact | all readers (assessor-drift detection) |
| `source_transcript` | non-empty string (transcript the verdicts were derived from) | audit of assessments |
| `dispatch_confirmed` | boolean — did the packet demonstrably reach the receiving agent | experiment (excludes unconfirmed deliveries); /retro D2 |
| `unused` | array of objects, or null | /retro D2 (delivered-but-unused) |
| `harmful` | array of objects, or null | /retro D2 (delivered-but-harmful) |
| `missing` | array of objects, or null | miner (Step-0a candidate creation); retained here for /retro D3 traceability even when also handed to the miner |
| `unattributed_retrieval` | array of objects, or null | /retro D3 (retrieval that bypassed the packet) |
| stamps (`schema_version`, `packet_schema_sha`, `model`, branch trio) | as in packet rows | all readers |

Verdict-array semantics: an **empty array** means "assessed, no finding".
**Null** means that verdict class was not assessable and requires a
class-specific `<class>_not_assessable_reason` string (e.g.
`unused_not_assessable_reason`). Row-level `not_assessable_reason` is
reserved for packets that cannot be assessed at all — when set, all four
verdict classes must be null and per-class reasons are not required.

## Reader contract

Readers MUST treat any row that fails `packet_schema.py` validation as
corrupt: emit a one-line stderr warning
(`[packet] warning: <file>:<N> corrupt — <reason>`), exclude the row from
any aggregate or join, and never silently count it.

## Operational

- Both `.jsonl` files are append-only. Do not rewrite history; supersede by
  appending.
- Schema evolution: bump `schema_version` on the write side and branch the
  validator on it; v1 rows must keep validating.
EOF

echo "[packet] Seeded $README" >&2
