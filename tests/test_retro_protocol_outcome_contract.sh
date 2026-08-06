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

# Verification is in-band and agent-owned. Assert the out-of-band path's
# distinguishing tokens are absent from every protocol surface this contract
# covers — a positive-only check would pass with both forms present.
removed = [
    "settlement",
    "Settlement",
    "consumption-contradiction",
    "consumer_contradiction_lifecycle",
    "settlement_health_inputs",
    "Judge liveness",
    "audit_lag",
    "dormant-census",
]
for name, text in (("retro", retro), ("coordinate", coordinate), ("coordination template", template)):
    for token in removed:
        assert token not in text, f"{name} still names the removed out-of-band path: {token}"

# The surviving verification vocabulary is the in-band pair and its resolutions.
for token in [
    "#### Verification vocabulary",
    "`held`",
    "`contradicted`",
    "resolution vocabulary is exactly `corrected | disputed`",
]:
    assert token in retro, f"retro verification vocabulary missing: {token}"

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
