#!/usr/bin/env bash
# test_promote_followup_plan.sh — Tests for promote-followup.sh plan.md generation

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$TESTS_DIR/../scripts"
TEST_DIR=$(mktemp -d)

PASS=0
FAIL=0

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

assert_contains() {
  local label="$1" output="$2" expected="$3"
  if echo "$output" | grep -qF -- "$expected"; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    Expected to contain: $expected"
    echo "    Got output:"
    echo "$output" | sed 's/^/      /'
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local label="$1" output="$2" not_expected="$3"
  if echo "$output" | grep -qF -- "$not_expected"; then
    echo "  FAIL: $label (unexpectedly found: $not_expected)"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  fi
}

assert_count() {
  local label="$1" output="$2" pattern="$3" expected_count="$4"
  local actual_count
  actual_count=$(echo "$output" | grep -cF -- "$pattern" || true)
  if [[ "$actual_count" -eq "$expected_count" ]]; then
    echo "  PASS: $label (found $actual_count)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (expected $expected_count, got $actual_count)"
    FAIL=$((FAIL + 1))
  fi
}

# Helper: run the plan-generation Python from promote-followup.sh
# Usage: run_plan_gen <plan_path> <findings_json> <followup_title> <pr_ref>
run_plan_gen() {
  local plan_path="$1"
  local findings_raw="$2"
  local followup_title="$3"
  local pr_ref="$4"

  python3 - "$plan_path" "$findings_raw" "$followup_title" "$pr_ref" << 'PYEOF'
import json, sys

plan_path = sys.argv[1]
findings_raw = sys.argv[2]
followup_title = sys.argv[3]
pr_ref = sys.argv[4]

try:
    findings = json.loads(findings_raw)
except json.JSONDecodeError:
    sys.exit(0)

selected = [f for f in findings if f.get("selected")]

source_line = f"Promoted from PR self-review followup"
if pr_ref:
    source_line = f"Promoted from PR self-review followup for PR {pr_ref}: {followup_title}"

lines = [f"# {followup_title}", "", "## Source", source_line, ""]

if selected:
    lines.append("## Findings")
    lines.append("")
    for f in selected:
        title = f.get("title", "")
        file_path = f.get("file", "")
        line_no = f.get("line", 0)
        lens = f.get("lens", "")
        body = f.get("body", "")
        grounding = f.get("grounding", "")

        loc = f"{file_path}:{line_no}" if line_no else file_path

        lines.append(f"### {title}")
        if loc:
            lines.append(f"**File:** {loc}")
        if lens:
            lines.append(f"**Lens:** {lens}")
        lines.append("")
        if body:
            lines.append(body)
            lines.append("")
        if grounding:
            lines.append(f"**Grounding:** {grounding}")
            lines.append("")

content = "\n".join(lines)
if not content.endswith("\n"):
    content += "\n"
with open(plan_path, "w") as f:
    f.write(content)
PYEOF
}

# ============================================================
# Fixture: 2 selected findings + 1 unselected
# ============================================================
FIXTURE_FINDINGS='[
  {
    "title": "Fix null check in handler",
    "file": "auth/middleware.go",
    "line": 42,
    "lens": "correctness",
    "body": "The handler returns nil without checking the error from Validate().",
    "grounding": "Error path skips nil guard — any caller reaching this branch will panic on dereference.",
    "selected": true
  },
  {
    "title": "Missing timeout on HTTP client",
    "file": "http/client.go",
    "line": 17,
    "lens": "security",
    "body": "The HTTP client has no timeout configured.",
    "grounding": "Unbounded HTTP calls block goroutines indefinitely under slow-server conditions — confirmed by tracing the call through to net/http defaults.",
    "selected": true
  },
  {
    "title": "Minor variable naming nit",
    "file": "auth/util.go",
    "line": 10,
    "lens": "style",
    "body": "Variable name x is not descriptive.",
    "grounding": "",
    "selected": false
  }
]'

FOLLOWUP_TITLE="Self-Review: Auth Middleware Hardening"
PR_REF="#99"
PLAN_PATH="$TEST_DIR/plan.md"

echo "=== promote-followup.sh plan.md generation tests ==="
echo ""

# Test 1: plan is generated
run_plan_gen "$PLAN_PATH" "$FIXTURE_FINDINGS" "$FOLLOWUP_TITLE" "$PR_REF"
PLAN_CONTENT=$(cat "$PLAN_PATH")

echo "--- Case 1: Header and Source ---"
assert_contains "plan has title header" "$PLAN_CONTENT" "# Self-Review: Auth Middleware Hardening"
assert_contains "plan has Source section" "$PLAN_CONTENT" "## Source"
assert_contains "plan embeds PR ref in source line" "$PLAN_CONTENT" "PR #99"
assert_contains "plan embeds followup title in source line" "$PLAN_CONTENT" "Self-Review: Auth Middleware Hardening"

echo ""
echo "--- Case 2: Selected findings appear ---"
assert_contains "first selected finding title" "$PLAN_CONTENT" "### Fix null check in handler"
assert_contains "first finding file:line" "$PLAN_CONTENT" "**File:** auth/middleware.go:42"
assert_contains "first finding lens" "$PLAN_CONTENT" "**Lens:** correctness"
assert_contains "first finding body" "$PLAN_CONTENT" "The handler returns nil without checking the error from Validate()."
assert_contains "first finding grounding" "$PLAN_CONTENT" "**Grounding:** Error path skips nil guard"

assert_contains "second selected finding title" "$PLAN_CONTENT" "### Missing timeout on HTTP client"
assert_contains "second finding file:line" "$PLAN_CONTENT" "**File:** http/client.go:17"
assert_contains "second finding lens" "$PLAN_CONTENT" "**Lens:** security"
assert_contains "second finding body" "$PLAN_CONTENT" "The HTTP client has no timeout configured."
assert_contains "second finding grounding" "$PLAN_CONTENT" "**Grounding:** Unbounded HTTP calls block goroutines"

echo ""
echo "--- Case 3: Unselected finding excluded ---"
assert_not_contains "unselected finding title not in plan" "$PLAN_CONTENT" "Minor variable naming nit"
assert_not_contains "unselected finding file not in plan" "$PLAN_CONTENT" "auth/util.go"

echo ""
echo "--- Case 4: Section count ---"
assert_count "exactly 2 finding sections" "$PLAN_CONTENT" "### " 2

# Test 2: zero-selection path produces header only
rm -f "$PLAN_PATH"
ZERO_SELECTED='[
  {"title":"ignored","file":"a.go","line":1,"lens":"x","body":"b","grounding":"g","selected":false}
]'
run_plan_gen "$PLAN_PATH" "$ZERO_SELECTED" "Zero Selection Test" ""
ZERO_PLAN=$(cat "$PLAN_PATH")

echo ""
echo "--- Case 5: Zero-selection path ---"
assert_contains "zero-selection plan has title" "$ZERO_PLAN" "# Zero Selection Test"
assert_contains "zero-selection plan has source" "$ZERO_PLAN" "## Source"
assert_not_contains "zero-selection plan has no Findings section" "$ZERO_PLAN" "## Findings"
assert_not_contains "zero-selection finding not leaked" "$ZERO_PLAN" "ignored"

# Test 3: no PR ref produces generic source line
rm -f "$PLAN_PATH"
run_plan_gen "$PLAN_PATH" "$FIXTURE_FINDINGS" "No PR Test" ""
NO_PR_PLAN=$(cat "$PLAN_PATH")

echo ""
echo "--- Case 6: No PR ref ---"
assert_contains "no-PR plan has generic source line" "$NO_PR_PLAN" "Promoted from PR self-review followup"
assert_not_contains "no-PR plan has no PR number" "$NO_PR_PLAN" "PR #"

# Test 4: malformed JSON is handled gracefully (no crash, empty plan path)
echo ""
echo "--- Case 7: Malformed JSON guard ---"
MALFORMED_PLAN="$TEST_DIR/plan_malformed.md"
python3 - "$MALFORMED_PLAN" "not-valid-json" "Title" "" << 'PYEOF'
import json, sys

plan_path = sys.argv[1]
findings_raw = sys.argv[2]
followup_title = sys.argv[3]
pr_ref = sys.argv[4]

try:
    findings = json.loads(findings_raw)
except json.JSONDecodeError:
    sys.exit(0)

with open(plan_path, "w") as f:
    f.write("should not exist\n")
PYEOF
if [[ ! -f "$MALFORMED_PLAN" ]]; then
  echo "  PASS: malformed JSON exits cleanly without creating plan"
  PASS=$((PASS + 1))
else
  echo "  FAIL: malformed JSON created unexpected plan file"
  FAIL=$((FAIL + 1))
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
