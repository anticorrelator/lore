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
    "below its declared floor",
    "never green",
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

pack_contract = text.split("#### Pack v1 contract", 1)[1].split("#### Absence is never green", 1)[0]
for token in [
    "reader_contract_version",
    "projection_mode",
    "stable_empty_shape",
    "half-open `[start,end)`",
    "retire the old surface in the same change",
    "travel with the semantic change",
]:
    assert token in pack_contract, f"reader seam doctrine missing: {token}"

assert "no-published-reader" not in text, "stale pre-reader doctrine resurfaced"
assert "not-computable:dormant-census" not in text, "dormant census is an abstention, not not-computable"

for token in [
    '"reader_contract_version":"2" if sid=="cycle_work" else "1"',
    '"projection_mode":projection_mode',
    '"stable_empty_shape":empty_shape',
]:
    assert token in prepare, f"published reader contract missing: {token}"

# The settlement pipeline and the consumption-contradiction channel are gone.
# Assert their absence: a reader, fact, or calculator that reappears here has
# no writer left to feed it and would report not-computable forever.
RETIRED = [
    "settlement",
    "consumption-contradiction",
    "consumer_contradiction_lifecycle",
    "settlement_health_inputs",
    "concerns_contradictions",
    "audit_lag",
    "audit_realization",
    "grounding_failure_rate",
    "trigger_realization",
    "candidate_queue_backlog",
    "judge_liveness",
    "consumer_contradiction_routing",
]
for token in RETIRED:
    assert token not in prepare, f"retired evidence-pack surface reintroduced in prepare: {token}"
    assert token not in text, f"retired evidence-pack surface reintroduced in the retro skill: {token}"
    assert token not in drift_check, f"retired path reintroduced in the seam-drift checker: {token}"

for token in [
    "tests/frameworks/retro_prepare.bats",
    "skills/retro/SKILL.md",
    "without retro behavior, contract-test, or protocol-check changes",
]:
    assert token in drift_check, f"seam-fix mutation doctrine missing: {token}"

# Public helper, manifest, and documented contract describe the same shape.
import runpy
root = Path(sys.argv[1]).parents[2]
helper = runpy.run_path(str(root / "scripts/work-evidence.py"))
doc = (root / "docs/protocol-evidence.md").read_text()
assert helper["READER_CONTRACT_VERSION"] == "2"
assert "Reader contract: 2" in doc
assert '"source_data"' in prepare
assert "source_data.cycle_work" in text

# --- Rubric identity and D6 are additive: D1–D5, Check 7, and escalation keep their contracts.
for token in ["D6", "not-assessable"]:
    assert token in decision_rights, f"lead-owned D6 decision missing: {token}"
top_level = pack_contract.split("```text", 1)[1].split("```", 1)[0]
for token in ["rubric", "source_data", "due_claim"]:
    assert token in top_level, f"pack top-level member missing from the contract: {token}"
assert "`packet_assessments`" in pack_contract, "packet_assessments is a required source"
rubric_section = text.split("#### Rubric identity", 1)[1].split("#### The cycle_work projection", 1)[0]
for token in [
    "`rubric_id`", "`rubric_version`", "12-hex", "`rubric_text`", "source fingerprint",
    "frozen in the pack", "never against the rubric file on disk", "Only `D6` may be `not-assessable`",
    "`d5_spec_utility`", "`d6_packet_utility`",
]:
    assert token in rubric_section, f"rubric identity doctrine missing: {token}"
fact_groups = text.split("The required fact groups are", 1)[1].split("Every calculation row", 1)[0]
for token in ["`packet_delivery`", "`packet_assessments`", "`findings: 0`", "`findings: null`", "does not read packets", "never enter the pack"]:
    assert token in fact_groups, f"packet fact doctrine missing: {token}"

d6 = text.split("##### D6 — Packet Utility", 1)[1].split("#### Escalation, scale, and channel judgments", 1)[0]
for token in [
    "**Construction.**", "**Synthesis.**", "**Receipt.**", "**Observed utility.**",
    "not evidence that anyone read it", "`dispatch_confirmed` is evidence of receipt, not of usefulness",
    "They inform the score and never produce it",
    "No arithmetic over `packet_delivery` or `packet_assessments` yields a D6 value",
    "is not a clean bill", "`disposition: not-assessable`", "`score: null`", "`reason`",
    "no numeric D6 reaches the journal or a scored row", "Do not translate absence into a number",
    "source:packet_assessments", "pack:/facts/packet_delivery", "pack:/facts/packet_assessments",
    "D5 and D6 coexist",
]:
    assert token in d6, f"D6 doctrine missing: {token}"

# The skill and the frozen rubric carry the same headings, keys, and anchor lines, dimension by dimension.
rubric = runpy.run_path(str(root / "scripts/retro-rubric.py"))["load_rubric"]()
assert rubric["rubric_id"] == "retro-rubric"
assert [d["dimension_id"] for d in rubric["dimensions"]] == ["D1", "D2", "D3", "D4", "D5", "D6"]
assert [d["journal_key"] for d in rubric["dimensions"]] == [
    "d1_delivery", "d2_quality", "d3_gaps", "d4_alignment", "d5_spec_utility", "d6_packet_utility"]
assert [d["allow_not_assessable"] for d in rubric["dimensions"]] == [False] * 5 + [True]
dimensions = text.split("#### Dimension scores", 1)[1].split("#### Escalation, scale, and channel judgments", 1)[0]
for d in rubric["dimensions"]:
    assert f"##### {d['dimension_id']} — {d['name']}" in dimensions, f"{d['dimension_id']} heading differs from rubric"
    line = " | ".join(f"`{s}` {d['anchors'][s]}" for s in "54321")
    assert line in dimensions, f"{d['dimension_id']} anchor line differs between skill and rubric"
# The historical D1–D5 anchors are unchanged by the D6 addition.
HISTORICAL_ANCHORS = {
    "D1": "`5` every eligible task delivered with high completeness and cross-cutting delivery intact | `4` most eligible tasks delivered with minor gaps | `3` low annotation quality or spec-only agents lacked available context | `2` eligible tasks with no delivery, unresolved delivery, or a silent pipeline drop | `1` no delivery",
    "D2": "`5` all relevant/current/right-sized | `4` one minor mismatch | `3` topical but wrong altitude | `2` mostly irrelevant or stale | `1` actively misleading",
    "D3": "`5` no gaps | `4` one minor gap or only novel discoveries | `3` one significant coverage failure | `2` multiple coverage failures | `1` no knowledge-system support",
    "D4": "`5` decisions shaped implementation | `4` most influenced, one or two decorative | `3` present but agents chose independently | `2` cited then diverged | `1` no alignment",
    "D5": "`5` spec-guided with no escalation | `4` minor exploration or one escalation | `3` several independent reads or two to three escalations | `2` frequent exploration and divergence | `1` no meaningful guidance",
}
for did, line in HISTORICAL_ANCHORS.items():
    assert line in dimensions, f"{did} historical anchors changed"
    declared = next(d for d in rubric["dimensions"] if d["dimension_id"] == did)
    assert " | ".join(f"`{s}` {declared['anchors'][s]}" for s in "54321") == line, f"{did} rubric anchors changed"

for token in [
    "rubric_id, rubric_version", "`schema_version` is `2`", "ordered exactly D1–D6",
    "{dimension_id, disposition, score, rationale, evidence_refs}", "`disposition: scored`", "`score: null`",
    "only D6 may carry it", "retained legacy pack", "ordered exactly D1–D5", "refuses a v1 manifest",
]:
    assert token in manifest, f"v2 manifest doctrine missing: {token}"
filing = text.split("### Step 5: File and Recover", 1)[1].split("### Step 6: Report", 1)[0]
for token in [
    "`filing_id + rubric_id + rubric_version + dimension_id`", "`scorecard:dimension:<id>`",
    "`template_id=retro-rubric`", "`template_version=<rubric_version>`", "`calibration_state=pre-calibration`",
    "`scores` holds numbers only", "no journal key and no scored row", "satisfy no calibrated evidence floor", "rate no agent",
]:
    assert token in filing, f"dimension sink doctrine missing: {token}"
assert "a `not-assessable` D6 is an abstention on record" in absence
assert "D1–D6 as the narrative coda" in text and "never as a number" in text
assert "Escalation stays qualitative and off scorecards" in text
assert "Answer in prose; never score the checks." in text

recipe = text.split("### Reading scores across the rubric boundary", 1)[1]
for token in [
    "lore journal query --role retro --extract-scores --json", ".scores.d5_spec_utility", ".scores.d6_packet_utility",
    "legacy-unversioned", '"rubric_version":null', '"d6_packet_utility":null', "no common scale",
    "Nothing pools these series", "choose the columns yourself", "(template_id, template_version, metric)",
]:
    assert token in recipe, f"comparison recipe missing: {token}"

# The verbs implement the contract the prose describes.
file_verb = (root / "scripts/retro-file.sh").read_text()
for token in [
    "rubric-bound packs require v2 judgments", "judgment rubric identity differs from frozen pack",
    "scorecard:dimension:", '"calibration_state":"pre-calibration"',
]:
    assert token in file_verb, f"filing verb contract missing: {token}"
for token in ['"rubric":rubric', '"packet_assessments"', '"packet_delivery"']:
    assert token in prepare, f"prepare contract missing: {token}"
print("retro evidence-pack protocol: PASS")
PY
