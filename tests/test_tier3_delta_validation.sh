#!/usr/bin/env bash
# test_tier3_delta_validation.sh - Focused validation for Tier 3 producer delta.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$REPO_ROOT/scripts"

PASS=0
FAIL=0

assert_success() {
  local label="$1"
  shift
  if "$@" >/tmp/tier3_delta_stdout.$$ 2>/tmp/tier3_delta_stderr.$$; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    stderr:"
    sed 's/^/      /' /tmp/tier3_delta_stderr.$$ || true
    FAIL=$((FAIL + 1))
  fi
}

assert_failure_contains() {
  local label="$1"
  local expected="$2"
  shift 2
  if "$@" >/tmp/tier3_delta_stdout.$$ 2>/tmp/tier3_delta_stderr.$$; then
    echo "  FAIL: $label - expected failure"
    FAIL=$((FAIL + 1))
    return
  fi
  if grep -qiF -- "$expected" /tmp/tier3_delta_stdout.$$ /tmp/tier3_delta_stderr.$$; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    Expected diagnostic containing: $expected"
    echo "    stdout:"
    sed 's/^/      /' /tmp/tier3_delta_stdout.$$ || true
    echo "    stderr:"
    sed 's/^/      /' /tmp/tier3_delta_stderr.$$ || true
    FAIL=$((FAIL + 1))
  fi
}

cleanup() {
  rm -f /tmp/tier3_delta_stdout.$$ /tmp/tier3_delta_stderr.$$
}
trap cleanup EXIT

section_report() {
  local delta="$1"
  local closest_line="${2:-}"
  cat <<EOF
Template-version: abc123
**Observations:**
- claim: "Report has an observation"
  file: /tmp/example
  line_range: 1-1
  falsifier: "No such report"
  significance: low
**Tier 2 evidence:**
- task-claim-1
**Tier 3 candidates:**
- claim_id: reusable-claim-1
  tier: reusable
  claim: "Reusable claim"
  producer_role: worker
  protocol_slot: implement-step-3
  scale: implementation
  delta: $delta
$closest_line
  why_future_agent_cares: "Future workers avoid re-deriving this."
  falsifier: "A counterexample in code."
  related_files: [/tmp/example]
  source_artifact_ids: [task-claim-1]
  work_item: sample-work
  captured_at_sha: deadbeef
**Blockers:** none
EOF
}

section_validate() {
  python3 "$SCRIPT_DIR/validate-tier-sections.py"
}

tier3_row() {
  local delta="$1"
  local closest_json="${2:-}"
  python3 - "$delta" "$closest_json" <<'PY'
import json
import sys

delta = sys.argv[1]
closest = sys.argv[2]
row = {
    "claim_id": "reusable-claim-1",
    "tier": "reusable",
    "claim": "Reusable claim",
    "producer_role": "worker",
    "protocol_slot": "implement-step-3",
    "scale": "implementation",
    "delta": delta,
    "why_future_agent_cares": "Future workers avoid re-deriving this.",
    "falsifier": "A counterexample in code.",
    "related_files": ["/tmp/example"],
    "source_artifact_ids": ["task-claim-1"],
    "work_item": "sample-work",
    "confidence": "unaudited",
    "captured_at_sha": "deadbeef",
}
if closest:
    row["closest_entry"] = closest
print(json.dumps(row))
PY
}

tier3_validate() {
  bash "$SCRIPT_DIR/validate-tier3.sh"
}

validate_section_case() {
  local delta="$1"
  local closest_line="${2:-}"
  section_report "$delta" "$closest_line" | section_validate
}

validate_json_case() {
  local delta="$1"
  local closest_json="${2:-}"
  tier3_row "$delta" "$closest_json" | tier3_validate
}

echo "=== Tier 3 Delta Validation Tests ==="
echo ""

echo "Test 1: section validator accepts absent delta"
assert_success "section delta=absent passes" validate_section_case absent

echo "Test 2: section validator accepts covered without closest_entry"
assert_success "section delta=covered passes without closest_entry" validate_section_case covered

echo "Test 3: section validator requires closest_entry for extends"
assert_failure_contains "section delta=extends missing closest_entry fails" "closest_entry" validate_section_case extends

echo "Test 4: section validator requires closest_entry for contradicts"
assert_failure_contains "section delta=contradicts missing closest_entry fails" "closest_entry" validate_section_case contradicts

echo "Test 5: section validator rejects invalid delta"
assert_failure_contains "section invalid delta fails" "invalid delta" validate_section_case duplicate

echo "Test 6: validate-tier3 accepts absent delta"
assert_success "json delta=absent passes" validate_json_case absent

echo "Test 7: validate-tier3 accepts covered without closest_entry"
assert_success "json delta=covered passes without closest_entry" validate_json_case covered

echo "Test 8: validate-tier3 requires closest_entry for extends"
assert_failure_contains "json delta=extends missing closest_entry fails" "closest_entry" validate_json_case extends

echo "Test 9: validate-tier3 requires closest_entry for contradicts"
assert_failure_contains "json delta=contradicts missing closest_entry fails" "closest_entry" validate_json_case contradicts

echo "Test 10: validate-tier3 rejects invalid delta"
assert_failure_contains "json invalid delta fails" "invalid delta" validate_json_case duplicate

echo ""
echo "=== Results ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
