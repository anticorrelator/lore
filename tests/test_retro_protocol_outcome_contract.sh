#!/usr/bin/env bash
# test_retro_protocol_outcome_contract.sh — Semantic sentinels for durable DUE adoption.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - \
  "$REPO_ROOT/skills/retro/SKILL.md" \
  "$REPO_ROOT/skills/coordinate/SKILL.md" \
  "$REPO_ROOT/skills/coordinate/templates/coordination.md" <<'PYEOF'
from pathlib import Path
import sys

retro = Path(sys.argv[1]).read_text()
coordinate = Path(sys.argv[2]).read_text()
template = Path(sys.argv[3]).read_text()

step1 = retro.split("### Step 1: Resolve Work Item", 1)[1].split("### Step 2: Gather Evidence", 1)[0]
required_step1 = [
    "done | deferred | skipped | due",
    "record_type=outcome",
    "disposition=unhandled",
    "record_type=disposition",
    "disposition=handled",
    "dispatched | deferred | skipped",
    "lore retro queue",
    'lore retro handle --cycle-id "$SLUG"',
    "--action dispatched --handled-by retro-lead",
    "DUE queue reader failed",
    "best-effort DUE claim failed",
    "MUST warn and continue",
    "never a precondition",
]
for token in required_step1:
    assert token in step1, f"retro Step 1 missing semantic token/relationship: {token}"

# The post-evolve Step 3.8/F1 liveness redirect remains present and untouched by
# the Step 1 lifecycle adoption boundary.
for token in [
    "### Check: Judge liveness (disposition: redirected per-gate to settlement run envelopes)",
    "_settlement/runs/*.json",
    "completed_runs_in_window == 0 AND settlement_queue_items_routed > 0",
]:
    assert token in retro, f"settled Step 3.8 liveness contract missing: {token}"

retro_checkpoint = coordinate.split("### Retro", 1)[1].split("## What escalates", 1)[0]
for token in [
    "lore retro queue",
    "outcome=due",
    "disposition=unhandled",
    "--outcome-id <id>",
    "--action <dispatched|deferred|skipped>",
    "disposition=handled",
    "does not auto-run `/retro`",
    "not the cross-substrate coordinator state projection",
]:
    assert token in retro_checkpoint, f"coordinate retro checkpoint missing: {token}"

for token in [
    "due (unhandled)",
    "lore retro queue",
    "outcome=due",
    "disposition=unhandled",
    "lore retro handle --outcome-id <id>",
    "dispatched|deferred|skipped",
    "never auto-runs `/retro`",
]:
    assert token in template, f"coordination template missing: {token}"

print("retro protocol outcome contract: PASS")
PYEOF
