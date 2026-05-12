#!/usr/bin/env bash
# test_find_correction_targets_json.sh — Tests for find-correction-targets.sh
#
# Covers (per D4):
#   - Text mode (no --json): output format unchanged (byte-compatible with pre-D4)
#   - --json with >=1 match: emits parseable JSON {targets[...], index_state, resolver_version}
#   - --json with 0 matches: emits {targets: [], index_state: "ready", ...} and exits 0
#   - --json with missing concordance DB: emits {targets: [], index_state: "missing", ...} and exits 0
#   - Text mode preserves exit 2 when concordance DB is missing
#   - Usage error (no --claim-text) exits 1 in both modes

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/find-correction-targets.sh"
TEST_DIR=$(mktemp -d)
KNOWLEDGE_DIR="$TEST_DIR/knowledge"

PASS=0
FAIL=0

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    Expected: $expected"
    echo "    Actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local label="$1" output="$2" expected="$3"
  if echo "$output" | grep -qF -- "$expected"; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    Expected to contain: $expected"
    echo "    Got: $(echo "$output" | head -5)"
    FAIL=$((FAIL + 1))
  fi
}

assert_matches() {
  local label="$1" output="$2" pattern="$3"
  if echo "$output" | grep -qE -- "$pattern"; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    Expected pattern: $pattern"
    echo "    Got: $(echo "$output" | head -5)"
    FAIL=$((FAIL + 1))
  fi
}

# Build a small knowledge store with a concordance index using pk_search.Indexer +
# Concordance.build_vectors — the same path `lore rebuild` exercises.
setup_indexed_store() {
  rm -rf "$KNOWLEDGE_DIR"
  mkdir -p "$KNOWLEDGE_DIR/conventions"
  echo '{"format_version": 2}' > "$KNOWLEDGE_DIR/_manifest.json"

  cat > "$KNOWLEDGE_DIR/conventions/audit-runs-three-judges.md" <<'EOF'
# Audit runs three judges

The audit pipeline runs three independent judges (correctness, regression,
security) over each contradicted claim. Each judge emits a verdict envelope
with the same shape so downstream consumers can aggregate uniformly.

<!-- learned: 2026-01-01 | confidence: high | source: worker | related_files: scripts/audit.sh, scripts/judge.py -->
EOF

  cat > "$KNOWLEDGE_DIR/conventions/unrelated-naming-rule.md" <<'EOF'
# Database naming

Tables use snake_case plural nouns. Columns use snake_case singular. Foreign
keys follow the pattern referenced_table_id.

<!-- learned: 2026-01-01 | confidence: high | source: worker | related_files: db/schema.sql -->
EOF

  # Use pk_search.Indexer + Concordance.build_vectors to populate .pk_search.db.
  PYTHONPATH="$REPO_ROOT/scripts" python3 - "$KNOWLEDGE_DIR" <<'PYEOF'
import sys
from pk_search import Indexer
from pk_concordance import Concordance
import os

kdir = sys.argv[1]
idx = Indexer(kdir)
idx.index_all()
db = os.path.join(kdir, ".pk_search.db")
Concordance(db).build_vectors()
PYEOF
}

setup_empty_store_no_db() {
  rm -rf "$KNOWLEDGE_DIR"
  mkdir -p "$KNOWLEDGE_DIR"
  echo '{"format_version": 2}' > "$KNOWLEDGE_DIR/_manifest.json"
  # Intentionally do NOT build .pk_search.db
}

# All invocations target the test knowledge dir via LORE_KNOWLEDGE_DIR override
# (resolve-repo.sh short-circuits to this when set; see scripts/resolve-repo.sh:23).
export LORE_KNOWLEDGE_DIR="$KNOWLEDGE_DIR"

echo "=== find-correction-targets.sh Tests ==="

# =============================================
# Test 1: Usage error — no --claim-text exits 1 (both modes)
# =============================================
echo ""
echo "Test 1: usage error (missing --claim-text)"
setup_indexed_store
EXIT_CODE=0
STDERR=$("$SCRIPT" 2>&1 >/dev/null) || EXIT_CODE=$?
assert_eq "no --claim-text exits 1" "$EXIT_CODE" "1"
assert_contains "stderr mentions --claim-text" "$STDERR" "--claim-text"

EXIT_CODE=0
STDERR=$("$SCRIPT" --json 2>&1 >/dev/null) || EXIT_CODE=$?
assert_eq "no --claim-text exits 1 (--json mode too)" "$EXIT_CODE" "1"

# =============================================
# Test 2: Text mode — at least one match, format unchanged (byte-compatible)
# =============================================
echo ""
echo "Test 2: text mode emits ranked lines"
setup_indexed_store
STDOUT=$("$SCRIPT" --claim-text "audit pipeline runs three judges correctness regression security" 2>/dev/null || true)
# Format per pre-D4 header: "<path>  [overlap=yes|no]  [sim=0.NNNN]"
assert_matches "text-mode line shape" "$STDOUT" '\[overlap=(yes|no)\][[:space:]]+\[sim=0\.[0-9]{4}\]'
assert_contains "text-mode includes audit-runs-three-judges path" "$STDOUT" "audit-runs-three-judges.md"

# =============================================
# Test 3: Text mode — zero matches, prints sentinel line
# =============================================
echo ""
echo "Test 3: text mode zero matches"
setup_indexed_store
STDOUT=$("$SCRIPT" --claim-text "totally unrelated xyzzy unique gibberish phrase" --threshold 0.95 2>/dev/null)
assert_eq "zero-match text output verbatim" "$STDOUT" "No matching entries found"

# =============================================
# Test 4: --json with matches — parseable shape
# =============================================
echo ""
echo "Test 4: --json with matches"
setup_indexed_store
STDOUT=$("$SCRIPT" --json --claim-text "audit pipeline runs three judges correctness regression security" 2>/dev/null)
# Must parse as JSON
echo "$STDOUT" | jq -e 'type == "object"' >/dev/null
assert_eq "json parses as object" "$?" "0"
assert_eq "index_state ready" "$(echo "$STDOUT" | jq -r '.index_state')" "ready"
assert_eq "resolver_version non-empty" "$(echo "$STDOUT" | jq -r '.resolver_version | length > 0')" "true"
assert_eq "targets is array" "$(echo "$STDOUT" | jq -r '.targets | type')" "array"
TARGET_COUNT=$(echo "$STDOUT" | jq -r '.targets | length')
if (( TARGET_COUNT >= 1 )); then
  echo "  PASS: at least one target ($TARGET_COUNT)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: expected >= 1 target, got $TARGET_COUNT"
  FAIL=$((FAIL + 1))
fi
# First target shape: path, rank, overlap, sim
assert_eq "targets[0].rank is 1" "$(echo "$STDOUT" | jq -r '.targets[0].rank')" "1"
assert_eq "targets[0].overlap is bool" "$(echo "$STDOUT" | jq -r '.targets[0].overlap | type')" "boolean"
assert_eq "targets[0].sim is number" "$(echo "$STDOUT" | jq -r '.targets[0].sim | type')" "number"
assert_contains "targets[0].path ends in .md" "$(echo "$STDOUT" | jq -r '.targets[0].path')" ".md"

# =============================================
# Test 5: --json with zero matches — empty targets, exit 0, index_state=ready
# =============================================
echo ""
echo "Test 5: --json with zero matches"
setup_indexed_store
EXIT_CODE=0
STDOUT=$("$SCRIPT" --json --claim-text "totally unrelated xyzzy unique gibberish" --threshold 0.95 2>/dev/null) || EXIT_CODE=$?
assert_eq "zero-match --json exits 0" "$EXIT_CODE" "0"
assert_eq "targets is empty array" "$(echo "$STDOUT" | jq -r '.targets | length')" "0"
assert_eq "index_state ready (zero match)" "$(echo "$STDOUT" | jq -r '.index_state')" "ready"

# =============================================
# Test 6: --json with missing concordance DB — index_state=missing, exit 0
# =============================================
echo ""
echo "Test 6: --json with no .pk_search.db"
setup_empty_store_no_db
EXIT_CODE=0
STDOUT=$("$SCRIPT" --json --claim-text "any claim text" 2>/dev/null) || EXIT_CODE=$?
assert_eq "missing-db --json exits 0" "$EXIT_CODE" "0"
assert_eq "missing-db targets is empty" "$(echo "$STDOUT" | jq -r '.targets | length')" "0"
assert_eq "missing-db index_state=missing" "$(echo "$STDOUT" | jq -r '.index_state')" "missing"
assert_eq "missing-db resolver_version non-empty" "$(echo "$STDOUT" | jq -r '.resolver_version | length > 0')" "true"

# =============================================
# Test 7: Text mode preserves exit-2 when concordance DB is missing
# =============================================
echo ""
echo "Test 7: text mode preserves exit 2 on missing index"
setup_empty_store_no_db
EXIT_CODE=0
STDERR=$("$SCRIPT" --claim-text "any" 2>&1 >/dev/null) || EXIT_CODE=$?
assert_eq "text-mode missing-db exits 2" "$EXIT_CODE" "2"
assert_contains "text-mode missing-db stderr names index" "$STDERR" "concordance index not found"

# =============================================
# Summary
# =============================================
echo ""
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
echo "================================"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
