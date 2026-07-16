#!/usr/bin/env bash
# Semantic sentinels for the prepare -> lead judgment -> file boundary.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$REPO_ROOT/skills/retro/SKILL.md" "$REPO_ROOT/scripts/retro-prepare.sh" "$REPO_ROOT/scripts/check-retro-seam-drift.sh" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text()
prepare = Path(sys.argv[2]).read_text()
drift_check = Path(sys.argv[3]).read_text()

for token in [
    "lore retro prepare",
    "lore retro file",
    "source_manifest",
    "green | tripped | abstained | not-computable",
    "Absence is never green",
    "no-substantive-suggestion",
    "judgment_accepted=true",
    "filing_complete=true",
    "Completion telemetry is last",
]:
    assert token in text, f"missing prepare/file contract token: {token}"

decision_rights = text.split("## Decision rights", 1)[1].split("## Role and federation boundary", 1)[0]
for token in ["causal interpretation", "D1–D5", "Check 7", "suggestion selection", "graduate"]:
    assert token in decision_rights, f"lead-owned decision missing: {token}"

absence = text.split("#### Absence is never green", 1)[1].split("#### Tier-aware evidence", 1)[0]
for token in [
    "not-computable",
    "dormant-census",
    "abstains below its registered sample floor",
]:
    assert token in absence, f"absence doctrine missing: {token}"

manifest = text.split("### Step 4: Author the Judgment Manifest", 1)[1].split("### Step 5: File and Recover", 1)[0]
for token in ["dimension_judgments", "behavioral_health", "causal_diagnoses", "suggestion_outcome"]:
    assert token in manifest, f"judgment schema missing: {token}"
assert "At least one per retro" not in text
assert "Self-evolving protocol — every invocation produces at least one" not in text

assert "D1 is the named graduation candidate" in text
assert "This implementation does not graduate it" in text
assert "Check 7 is irreducible ground truth and must never be replaced by a number" in text

for token in [
    '"reader_contract_version":"1"',
    '"projection_mode":projection_mode',
    '"stable_empty_shape":empty_shape',
    "consumer_contradiction_lifecycle",
    "queue_transitions",
    "completed_envelopes",
    "grounding_outcomes",
]:
    assert token in prepare, f"published reader contract missing: {token}"

for token in [
    "tests/frameworks/retro_prepare.bats",
    "skills/retro/SKILL.md",
    "without retro behavior, contract-test, or protocol-check changes",
]:
    assert token in drift_check, f"seam-fix mutation doctrine missing: {token}"

print("retro evidence-pack protocol: PASS")
PY
