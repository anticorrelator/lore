#!/usr/bin/env bash
# seed-scorecards-readme.sh — Write $KDIR/_scorecards/README.md if missing.
# Usage: bash seed-scorecards-readme.sh <scorecards-dir>
#
# Called by scorecard-append.sh (first-use lazy seed) and init-repo.sh
# (store init). Idempotent — no-op if README already present.

set -euo pipefail

SCORECARDS_DIR="${1:-}"
if [[ -z "$SCORECARDS_DIR" ]]; then
  echo "Usage: seed-scorecards-readme.sh <scorecards-dir>" >&2
  exit 1
fi

mkdir -p "$SCORECARDS_DIR"
README="$SCORECARDS_DIR/README.md"
if [[ -f "$README" ]]; then
  exit 0
fi

cat > "$README" << 'EOF'
# _scorecards/

Append-only sidecar storage for template-level evaluation signal. Readers
only: `/retro`, `/evolve`, `scripts/scorecard-rollup.sh`, and human-facing
CLI views (`lore scorecard …`).

## Contents

- `rows.jsonl` — append-only; one JSON object per line; the authoritative
  event log of scored + telemetry rows.
- `_current.json` — rollup written by `scorecard-rollup.sh` aggregating
  `rows.jsonl` into per-`(template_version, template_id, metric)`
  summaries. Regenerable from `rows.jsonl`; safe to delete.

## Sole-writer invariant

`scripts/scorecard-append.sh` (surfaced as `lore scorecard append`) is the
**only** sanctioned writer of `rows.jsonl`. No other script, skill, agent
prompt, or human process may append to, edit, or truncate that file
directly.

Every append is validated at write time for:

- `schema_version` — present and non-null
- `kind` — enum: `scored | telemetry`
- `calibration_state` — enum: `calibrated | pre-calibration | unknown`

See `architecture/scorecards/row-schema.md` for the full row schema.

### Why the invariant is load-bearing

Downstream consumers (`/evolve` metric citations, F1 harmonic-mean template
ranking, F2 drift telemetry) filter rows by `kind` and `calibration_state`
to distinguish **deliberate outcome-linked evaluation** (`scored`) from
**passive corpus observation** (`telemetry`). Without enforcement at write
time, the read side must infer regime from brittle signals (`granularity`,
`source`, prose). The sole-writer invariant guarantees that every row a
reader ever sees has already been regime-tagged and enum-checked, so
`kind == "scored"` is a reliable filter rather than a hopeful one.

## Reader contract

Readers MUST treat any row missing `schema_version`, `kind`, or
`calibration_state`, or carrying a value outside the defined enums, as
**corrupt**:

- EMIT a one-line stderr warning of the form
  `[scorecard] warning: rows.jsonl:<N> corrupt — <reason>`
- EXCLUDE the row from aggregation / metric citation
- Do NOT silently count a corrupt row toward any summary statistic

`scorecard-rollup.sh` implements this contract; new readers should follow
the same pattern.

## Prompt-context invariant

Scorecard rows are **never** loaded into agent prompt context. Writing
agents never see their own scores. The only consumers of `_current.json`
and `rows.jsonl` are `/retro`, `/evolve`, `scripts/scorecard-rollup.sh`,
and human-facing CLI views (`lore scorecard …`). This separation is the
mechanism by which template-level reputation accumulates across versions
without contaminating the agents it measures.

### Entry points that DO load scorecard data

- `scripts/scorecard-rollup.sh` (also surfaced as `lore scorecard rollup`
  and transitively as `lore scorecard current`): reads `rows.jsonl`,
  writes `_current.json`.
- `scripts/scorecard-append.sh` (also surfaced as `lore scorecard
  append`): reads `rows.jsonl` indirectly (append-only writes) and
  re-reads to surface `lore scorecard rows`.
- `/retro` and `/evolve` skills: consume `_current.json` for
  template-version ranking and drift telemetry. Neither skill injects
  raw rows into any downstream agent prompt — they summarize.
- `scripts/seed-scorecards-readme.sh` and `scripts/init-repo.sh`:
  initialize the directory layout; no row reads.

### Entry points that explicitly DO NOT load scorecard data

Audited at Phase 2 close (see `tests/test_phase2_provenance.sh` for the
complementary flag round-trip coverage). Each of the paths below was
grep-checked against `_scorecards` / `scorecards` and found to make
no reference:

- `scripts/load-knowledge.sh` — the SessionStart knowledge loader. Pulls
  `_index.md`, `_manifest.json`, and priority entries only.
- `scripts/prefetch-knowledge.sh` — the agent-spawn knowledge prefetcher.
  Scoped to knowledge-entry retrieval; has no scorecard hook.
- `scripts/load-followup.sh`, `load-tasks.sh`, `load-threads.sh`,
  `load-work-item.sh`, `load-work.sh` — the other on-demand loaders.
  None reference `_scorecards/`.
- All files under `agents/` — no scorecard references.
- All files under `skills/` — no scorecard references outside `/retro`
  and `/evolve` read paths, which summarize rather than inject.

If a future change introduces a new scorecard reader, update this list
AND confirm that the reader either (a) summarizes into aggregate
statistics before any prompt injection, or (b) keeps scorecard content
on the human-facing CLI path only. Never embed raw `rows.jsonl` or
`_current.json` content into an agent prompt.

## Template registry

`template-registry.json` resolves a 12-char `template_version` hash
(produced by `scripts/template-version.sh`) into a human-readable entry
`{template_id, template_path, first_seen, description}`. Managed through
`scripts/template-registry-register.sh` (INSERT OR IGNORE semantics).

### Auto-register at first spawn

`/implement`, `/spec`, `/pr-self-review`, and `/remember` compute
`template_version` at agent-spawn or capture time and call
`template-registry-register.sh`. If the `(template_id, template_version)`
pair is new, a registry entry is written with `description: null`.
Subsequent spawns of the same template version are silent no-ops.

### Concurrency

INSERT OR IGNORE via tmpfile + atomic rename. Agent-spawn registration is
low-frequency and idempotent; two concurrent writers for the same pair are
both harmless (both no-op for existing pair, both produce equivalent rows
for a new one). This is NOT a lock; do not use this helper for high-rate
concurrent writes.

### Unregistered-hash rendering

When a scorecard row references a `template_version` hash that is not
present in `template-registry.json`, readers MUST render it as
`unregistered:<hash>` in any user-facing summary and assign it **no
scorecard weight**:

- Exclude from `/evolve` citation pools and harmonic-mean template
  rankings
- Exclude from `/retro` dimension evidence and trend comparisons
- Exclude from any "top N templates" view
- Retain the row in storage — it may become registered later and
  thereafter count

This isolates the registry-write path from the scorecard-write path.
Rows can be accepted (the append validator does not know about the
registry) even when the producing template was edited mid-cycle or never
formally registered, but those rows do not influence settlement signal
until a human or ceremony fills in the registry entry's `description`
(non-null description is the gate for scorecard weight).

## Operational

- `rows.jsonl` is append-only. Do not rewrite history; supersede by writing
  a new row instead.
- `_current.json` is safe to delete — regenerate with
  `lore scorecard rollup` (or `scripts/scorecard-rollup.sh`).
- `template-registry.json` is append-only via the register helper. Editing
  the `description` field by hand is fine (and is the intended path for
  making an entry "count" in settlement signal).
- Schema evolution: bump `schema_version` on the write side; readers may
  upgrade or reject stale versions deterministically.
EOF

echo "[scorecard] Seeded $README" >&2
