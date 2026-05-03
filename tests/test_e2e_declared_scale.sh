#!/usr/bin/env bash
# test_e2e_declared_scale.sh — End-to-end declared-scale contract tests.
# Covers the full declared-capture/declared-retrieval contract:
#   - capture hard-fail (missing --scale, invalid enum, unknown rejected)
#   - capture success for all 4 buckets + META written
#   - retrieval hard-fail (prefetch, lore query, lore search --json, lore search interactive)
#   - resolve-manifest.sh hard-fail (null directive, missing scale_set, empty seeds)
#   - classifier verifier-only (no primary_assignments, no hybrid mode)
#   - /retro signal block (six signals in SKILL.md; retro-scale-access-append.sh schema v2;
#                          retro-aggregate-compute.py emits scale_signals)
#   - scale-coverage.sh deleted; scale-registry has 4 buckets, no 'unknown'

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/scripts"
CLI="$REPO_ROOT/cli/lore"
CAPTURE_SH="$SCRIPTS_DIR/capture.sh"
PREFETCH_SH="$SCRIPTS_DIR/prefetch-knowledge.sh"
RESOLVE_MANIFEST_SH="$SCRIPTS_DIR/resolve-manifest.sh"
APPEND_SH="$SCRIPTS_DIR/retro-scale-access-append.sh"
COMPUTE_PY="$SCRIPTS_DIR/retro-aggregate-compute.py"
CLASSIFIER="$REPO_ROOT/agents/classifier.md"
RETRO_SKILL="$REPO_ROOT/skills/retro/SKILL.md"

TEST_DIR=$(mktemp -d)
KNOWLEDGE_DIR="$TEST_DIR/knowledge"
export LORE_KNOWLEDGE_DIR="$KNOWLEDGE_DIR"

PASS=0
FAIL=0

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

# ── helpers ────────────────────────────────────────────────────────────────────

assert_exit_zero() {
  local label="$1" exit_code="$2"
  if [[ "$exit_code" -eq 0 ]]; then
    echo "  PASS: $label"; PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (expected exit 0, got $exit_code)"; FAIL=$((FAIL + 1))
  fi
}

assert_exit_nonzero() {
  local label="$1" exit_code="$2"
  if [[ "$exit_code" -ne 0 ]]; then
    echo "  PASS: $label"; PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (expected non-zero, got 0)"; FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local label="$1" output="$2" expected="$3"
  if echo "$output" | grep -qF -- "$expected"; then
    echo "  PASS: $label"; PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    Expected to contain: $expected"
    echo "    Got: $(echo "$output" | head -3)"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -qF -- "$needle"; then
    echo "  FAIL: $label (unexpected: $needle)"; FAIL=$((FAIL + 1))
  else
    echo "  PASS: $label"; PASS=$((PASS + 1))
  fi
}

assert_file_contains() {
  local label="$1" filepath="$2" expected="$3"
  if [[ -f "$filepath" ]] && grep -qF -- "$expected" "$filepath"; then
    echo "  PASS: $label"; PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    if [[ ! -f "$filepath" ]]; then
      echo "    File does not exist: $filepath"
    else
      echo "    Expected file to contain: $expected"
    fi
    FAIL=$((FAIL + 1))
  fi
}

assert_file_not_exists() {
  local label="$1" filepath="$2"
  if [[ ! -f "$filepath" ]]; then
    echo "  PASS: $label"; PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (file should not exist: $filepath)"; FAIL=$((FAIL + 1))
  fi
}

assert_json_field() {
  local label="$1" json="$2" field="$3" expected="$4"
  actual=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get(sys.argv[2],'MISSING'))" "$json" "$field" 2>/dev/null)
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $label"; PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (expected $expected, got $actual)"; FAIL=$((FAIL + 1))
  fi
}

setup_knowledge_store() {
  rm -rf "$KNOWLEDGE_DIR"
  mkdir -p "$KNOWLEDGE_DIR"
  echo '{}' > "$KNOWLEDGE_DIR/_manifest.json"
}

setup_kdir() {
  local kdir="$TEST_DIR/kdir_$$_$RANDOM"
  mkdir -p "$kdir/_meta" "$kdir/_work"
  echo '{}' > "$kdir/_manifest.json"
  echo "$kdir"
}

echo "=== test_e2e_declared_scale.sh ==="
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# Section 1: Capture hard-fail
# ═══════════════════════════════════════════════════════════════════════════════
echo "--- Section 1: Capture hard-fail ---"
echo ""

echo "Test 1.1: capture without --scale exits non-zero + error mentions --scale"
setup_knowledge_store
OUT=$(bash "$CAPTURE_SH" --insight "test" --context "ctx" --confidence high 2>&1)
EC=$?
assert_exit_nonzero "capture exits non-zero without --scale" "$EC"
assert_contains "error mentions --scale" "$OUT" "--scale"

echo ""
echo "Test 1.2: capture --scale=invalid exits non-zero + lists all 4 valid buckets"
setup_knowledge_store
OUT=$(bash "$CAPTURE_SH" --insight "test" --context "ctx" --confidence high --scale=invalid 2>&1)
EC=$?
assert_exit_nonzero "capture exits non-zero for invalid enum" "$EC"
assert_contains "error lists implementation" "$OUT" "implementation"
assert_contains "error lists subsystem"      "$OUT" "subsystem"
assert_contains "error lists architecture"   "$OUT" "architecture"
assert_contains "error lists abstract"        "$OUT" "abstract"

echo ""
echo "Test 1.3: capture --scale=unknown rejected (not in registry)"
setup_knowledge_store
OUT=$(bash "$CAPTURE_SH" --insight "test" --context "ctx" --confidence high --scale=unknown 2>&1)
EC=$?
assert_exit_nonzero "capture exits non-zero for scale=unknown" "$EC"
assert_contains "unknown rejection mentions valid values" "$OUT" "is not a registered scale id"

# ═══════════════════════════════════════════════════════════════════════════════
# Section 2: Capture success — all 4 buckets + META written
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "--- Section 2: Capture success — all 4 buckets + META written ---"
echo ""

for BUCKET in implementation subsystem architecture abstract; do
  setup_knowledge_store
  OUT=$(bash "$CAPTURE_SH" \
    --insight "e2e bucket $BUCKET test" \
    --context "end-to-end test context" \
    --confidence high \
    --scale="$BUCKET" 2>&1)
  EC=$?
  assert_exit_zero "capture --scale=$BUCKET exits 0" "$EC"
  ENTRY=$(find "$KNOWLEDGE_DIR" -name "*.md" ! -name "_manifest.json" 2>/dev/null | head -1)
  assert_file_contains "scale=$BUCKET written to entry metadata" "$ENTRY" "scale: $BUCKET"
done

# ═══════════════════════════════════════════════════════════════════════════════
# Section 3: Deleted scripts absent
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "--- Section 3: Deleted scripts absent ---"
echo ""
assert_file_not_exists "scale-coverage.sh deleted" "$SCRIPTS_DIR/scale-coverage.sh"
assert_file_not_exists "scale-compute.sh deleted"  "$SCRIPTS_DIR/scale-compute.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# Section 4: Retrieval hard-fail
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "--- Section 4: Retrieval hard-fail ---"
echo ""

echo "Test 4.1: prefetch-knowledge.sh without --scale-set exits non-zero"
OUT=$(bash "$PREFETCH_SH" "some topic" 2>&1)
EC=$?
assert_exit_nonzero "prefetch exits non-zero without --scale-set" "$EC"
assert_contains "prefetch error mentions --scale-set" "$OUT" "--scale-set"

echo ""
echo "Test 4.2: prefetch-knowledge.sh --scale-context (deprecated) alone exits non-zero"
OUT=$(bash "$PREFETCH_SH" "some topic" --scale-context worker 2>&1)
EC=$?
assert_exit_nonzero "prefetch --scale-context alone exits non-zero" "$EC"

echo ""
echo "Test 4.3: lore query without --scale-set exits non-zero"
SEED_FILE="$TEST_DIR/seed.py"
echo "# seed" > "$SEED_FILE"
OUT=$(bash "$CLI" query --seeds "$SEED_FILE" 2>&1)
EC=$?
assert_exit_nonzero "lore query exits non-zero without --scale-set" "$EC"
assert_contains "lore query error mentions --scale-set" "$OUT" "--scale-set"

echo ""
echo "Test 4.4: lore search --json without --scale-set exits non-zero"
OUT=$(bash "$CLI" search "some topic" --json 2>&1)
EC=$?
assert_exit_nonzero "lore search --json exits non-zero without --scale-set" "$EC"
assert_contains "lore search --json error mentions --scale-set" "$OUT" "--scale-set"

echo ""
echo "Test 4.5: lore search (interactive) without --scale-set exits non-zero"
OUT=$(bash "$CLI" search "some topic" 2>&1)
EC=$?
assert_exit_nonzero "lore search interactive exits non-zero without --scale-set" "$EC"
assert_contains "interactive error mentions --scale-set" "$OUT" "--scale-set"

# ═══════════════════════════════════════════════════════════════════════════════
# Section 5: lore scale compute removed
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "--- Section 5: lore scale compute removed ---"
echo ""

echo "Test 5.1: lore scale compute exits non-zero with descriptive error"
OUT=$(bash "$CLI" scale compute --work-scope subsystem --role worker --slot 1 2>&1)
EC=$?
assert_exit_nonzero "lore scale compute exits non-zero" "$EC"
assert_contains "error references 4-bucket rubric" "$OUT" "4-bucket rubric"

# ═══════════════════════════════════════════════════════════════════════════════
# Section 6: resolve-manifest.sh hard-fail
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "--- Section 6: resolve-manifest.sh hard-fail ---"
echo ""

KDIR=$(setup_kdir)
SLUG="e2e-manifest-test"
mkdir -p "$KDIR/_work/$SLUG"

echo "Test 6.1: null retrieval_directive exits non-zero"
python3 -c "import json; print(json.dumps({'phases':[{'phase_number':1,'retrieval_directive':None}]}))" \
  > "$KDIR/_work/$SLUG/tasks.json"
OUT=$(LORE_KNOWLEDGE_DIR="$KDIR" bash "$RESOLVE_MANIFEST_SH" "$SLUG" 1 2>&1)
EC=$?
assert_exit_nonzero "resolve-manifest: null directive exits non-zero" "$EC"
assert_contains "null directive error mentions retrieval_directive" "$OUT" "retrieval_directive"

echo ""
echo "Test 6.2: missing scale_set exits non-zero"
python3 -c "import json; print(json.dumps({'phases':[{'phase_number':1,'retrieval_directive':{'seeds':['scripts/capture.sh'],'hop_budget':1}}]}))" \
  > "$KDIR/_work/$SLUG/tasks.json"
OUT=$(LORE_KNOWLEDGE_DIR="$KDIR" bash "$RESOLVE_MANIFEST_SH" "$SLUG" 1 2>&1)
EC=$?
assert_exit_nonzero "resolve-manifest: missing scale_set exits non-zero" "$EC"
assert_contains "missing scale_set error mentions scale" "$OUT" "scale"

echo ""
echo "Test 6.3: empty seeds list exits non-zero"
python3 -c "import json; print(json.dumps({'phases':[{'phase_number':1,'retrieval_directive':{'seeds':[],'scale_set':['implementation'],'hop_budget':1}}]}))" \
  > "$KDIR/_work/$SLUG/tasks.json"
OUT=$(LORE_KNOWLEDGE_DIR="$KDIR" bash "$RESOLVE_MANIFEST_SH" "$SLUG" 1 2>&1)
EC=$?
assert_exit_nonzero "resolve-manifest: empty seeds exits non-zero" "$EC"
assert_contains "empty seeds error mentions seeds" "$OUT" "seeds"

# ═══════════════════════════════════════════════════════════════════════════════
# Section 7: Classifier verifier-only
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "--- Section 7: Classifier verifier-only ---"
echo ""

if [[ ! -f "$CLASSIFIER" ]]; then
  echo "  FAIL: agents/classifier.md not found at $CLASSIFIER"
  FAIL=$((FAIL + 1))
else
  echo "Test 7.1: classifier has advisory-only directive (does not modify entry files)"
  grep -qF "do NOT modify knowledge files" "$CLASSIFIER" \
    && { echo "  PASS: advisory invariant present"; PASS=$((PASS+1)); } \
    || { echo "  FAIL: advisory invariant missing"; FAIL=$((FAIL+1)); }
  grep -qF "lore capture" "$CLASSIFIER" \
    && { echo "  FAIL: classifier calls lore capture (should not)"; FAIL=$((FAIL+1)); } \
    || { echo "  PASS: no lore capture call in classifier"; PASS=$((PASS+1)); }

  echo ""
  echo "Test 7.2: classifier output path is _meta/classification-report.json"
  grep -qF "_meta/classification-report.json" "$CLASSIFIER" \
    && { echo "  PASS: output path declared"; PASS=$((PASS+1)); } \
    || { echo "  FAIL: output path missing"; FAIL=$((FAIL+1)); }

  echo ""
  echo "Test 7.3: no hybrid mode or primary_assignments references"
  grep -qF "classifier_mode" "$CLASSIFIER" \
    && { echo "  FAIL: classifier_mode found (should be gone)"; FAIL=$((FAIL+1)); } \
    || { echo "  PASS: no classifier_mode"; PASS=$((PASS+1)); }
  grep -qF "primary_assignments" "$CLASSIFIER" \
    && { echo "  FAIL: primary_assignments found (should be gone)"; FAIL=$((FAIL+1)); } \
    || { echo "  PASS: no primary_assignments"; PASS=$((PASS+1)); }
  grep -qF "hybrid mode" "$CLASSIFIER" \
    && { echo "  FAIL: hybrid mode found (should be gone)"; FAIL=$((FAIL+1)); } \
    || { echo "  PASS: no hybrid mode"; PASS=$((PASS+1)); }

  echo ""
  echo "Test 7.4: Task 4 is Legacy Backfill Proposal (not Primary Scale Assignment)"
  grep -qF "Legacy Backfill Proposal" "$CLASSIFIER" \
    && { echo "  PASS: Legacy Backfill Proposal present"; PASS=$((PASS+1)); } \
    || { echo "  FAIL: Legacy Backfill Proposal missing"; FAIL=$((FAIL+1)); }
  grep -qF "Primary Scale Assignment" "$CLASSIFIER" \
    && { echo "  FAIL: Primary Scale Assignment still present"; FAIL=$((FAIL+1)); } \
    || { echo "  PASS: Primary Scale Assignment removed"; PASS=$((PASS+1)); }

  echo ""
  echo "Test 7.5: output schema has backfill_proposals field"
  grep -qF '"backfill_proposals"' "$CLASSIFIER" \
    && { echo "  PASS: backfill_proposals in schema"; PASS=$((PASS+1)); } \
    || { echo "  FAIL: backfill_proposals missing from schema"; FAIL=$((FAIL+1)); }
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Section 8: /retro signal block
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "--- Section 8: /retro signal block ---"
echo ""

echo "Test 8.1: retro/SKILL.md contains all six signal names"
if [[ ! -f "$RETRO_SKILL" ]]; then
  echo "  FAIL: retro/SKILL.md not found at $RETRO_SKILL"; FAIL=$((FAIL + 1))
else
  for SIG in declaration_coverage redeclare_rate off_scale_routes_emitted \
              verifier_disagreements off_altitude_skipped counterfactual_better; do
    grep -qF "$SIG" "$RETRO_SKILL" \
      && { echo "  PASS: signal $SIG present in SKILL.md"; PASS=$((PASS+1)); } \
      || { echo "  FAIL: signal $SIG missing from SKILL.md"; FAIL=$((FAIL+1)); }
  done

  echo ""
  echo "Test 8.2: retro/SKILL.md observational-only invariant (no auto-disable recommendation)"
  grep -qF "disable the scale system" "$RETRO_SKILL" \
    && { echo "  FAIL: auto-disable recommendation found"; FAIL=$((FAIL+1)); } \
    || { echo "  PASS: no auto-disable recommendation"; PASS=$((PASS+1)); }
fi

echo ""
echo "Test 8.3: retro-scale-access-append.sh uses schema_version 2 + counterfactual_better"
APPEND_CONTENT=$(cat "$APPEND_SH")
assert_contains "schema_version 2 in script" "$APPEND_CONTENT" '"schema_version": "2"'
assert_not_contains "schema_version 1 removed" "$APPEND_CONTENT" '"schema_version": "1"'
assert_contains "counterfactual_better flag present" "$APPEND_CONTENT" "--counterfactual-better)"
assert_contains "counterfactual_better JSON key" "$APPEND_CONTENT" '"counterfactual_better"'
assert_not_contains "no --recall-grade flag" "$APPEND_CONTENT" "--recall-grade)"
assert_not_contains "no recall_grade JSON key" "$APPEND_CONTENT" '"recall_grade"'
assert_contains "enum is better|same|worse" "$APPEND_CONTENT" "better|same|worse"
assert_not_contains "old enum gone" "$APPEND_CONTENT" "useful|neutral|not-useful"

echo ""
echo "Test 8.4: retro-scale-access-append.sh writes schema_version=2 row"
SIDECAR_KDIR=$(mktemp -d)
bash "$APPEND_SH" \
  --cycle-id e2e-test-cycle \
  --abstraction-grade right-sized \
  --abstraction-rationale "e2e test" \
  --counterfactual-better better \
  --counterfactual-rationale "scale improved retrieval" \
  --kdir "$SIDECAR_KDIR" > /dev/null 2>&1
EC=$?
assert_exit_zero "append exits 0 with valid args" "$EC"
SIDECAR="$SIDECAR_KDIR/_scorecards/retro-scale-access.jsonl"
if [[ -f "$SIDECAR" ]]; then
  FIRST_ROW=$(head -1 "$SIDECAR")
  assert_json_field "row schema_version=2" "$FIRST_ROW" "schema_version" "2"
  assert_json_field "row counterfactual_better=better" "$FIRST_ROW" "counterfactual_better" "better"
else
  echo "  FAIL: sidecar not written at $SIDECAR"; FAIL=$((FAIL + 1))
fi
rm -rf "$SIDECAR_KDIR"

echo ""
echo "Test 8.5: retro-aggregate-compute.py emits scale_signals with correct field values"
COMPUTE_KDIR=$(mktemp -d)
mkdir -p "$COMPUTE_KDIR/_meta" "$COMPUTE_KDIR/_work/e2e-cycle"

cat > "$COMPUTE_KDIR/_meta/retrieval-log.jsonl" << 'JSONEOF'
{"event": "search", "session_id": "s1", "scale_set": "subsystem", "scale_declared": true}
{"event": "search", "session_id": "s1", "scale_set": "implementation", "scale_declared": true}
{"event": "search", "session_id": "s2", "scale_set": "subsystem", "scale_declared": true}
{"event": "search", "session_id": "s2", "scale_declared": null}
JSONEOF

printf '{"concern": "x"}\n{"concern": "y"}\n' > "$COMPUTE_KDIR/_work/e2e-cycle/off_scale_routes.jsonl"
printf '{"disagreements": ["a.md", "b.md"]}\n' > "$COMPUTE_KDIR/_meta/classification-report.json"

COMPUTE_OUT=$(python3 "$COMPUTE_PY" /tmp/nonexistent-pool-e2e \
  --kdir "$COMPUTE_KDIR" --cycle-id "e2e-cycle" 2>/dev/null)

HAS_SIGNALS=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print('yes' if 'scale_signals' in d else 'no')" "$COMPUTE_OUT" 2>/dev/null)
[[ "$HAS_SIGNALS" == "yes" ]] \
  && { echo "  PASS: scale_signals block present"; PASS=$((PASS+1)); } \
  || { echo "  FAIL: scale_signals block missing"; FAIL=$((FAIL+1)); }

DECL=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('scale_signals',{}).get('declaration_coverage',{}).get('declared','MISSING'))" "$COMPUTE_OUT" 2>/dev/null)
TOTAL=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('scale_signals',{}).get('declaration_coverage',{}).get('total','MISSING'))" "$COMPUTE_OUT" 2>/dev/null)
ROUTES=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('scale_signals',{}).get('off_scale_routes_emitted',{}).get('count','MISSING'))" "$COMPUTE_OUT" 2>/dev/null)
DISAGREE=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('scale_signals',{}).get('verifier_disagreements',{}).get('count','MISSING'))" "$COMPUTE_OUT" 2>/dev/null)

[[ "$DECL"     == "3" ]] && { echo "  PASS: declaration_coverage.declared=3";     PASS=$((PASS+1)); } || { echo "  FAIL: declaration_coverage.declared expected 3, got $DECL";     FAIL=$((FAIL+1)); }
[[ "$TOTAL"    == "4" ]] && { echo "  PASS: declaration_coverage.total=4";         PASS=$((PASS+1)); } || { echo "  FAIL: declaration_coverage.total expected 4, got $TOTAL";        FAIL=$((FAIL+1)); }
[[ "$ROUTES"   == "2" ]] && { echo "  PASS: off_scale_routes_emitted.count=2";     PASS=$((PASS+1)); } || { echo "  FAIL: off_scale_routes_emitted expected 2, got $ROUTES";         FAIL=$((FAIL+1)); }
[[ "$DISAGREE" == "2" ]] && { echo "  PASS: verifier_disagreements.count=2";       PASS=$((PASS+1)); } || { echo "  FAIL: verifier_disagreements expected 2, got $DISAGREE";         FAIL=$((FAIL+1)); }

rm -rf "$COMPUTE_KDIR"

echo ""
echo "Test 8.6: scale_signals absent when --kdir omitted"
OUT_NO_KDIR=$(python3 "$COMPUTE_PY" /tmp/nonexistent-pool-e2e 2>/dev/null)
HAS_NO=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print('yes' if 'scale_signals' in d else 'no')" "$OUT_NO_KDIR" 2>/dev/null)
[[ "$HAS_NO" == "no" ]] \
  && { echo "  PASS: scale_signals absent without --kdir"; PASS=$((PASS+1)); } \
  || { echo "  FAIL: scale_signals unexpectedly present without --kdir"; FAIL=$((FAIL+1)); }

# ═══════════════════════════════════════════════════════════════════════════════
# Section 9: scale-registry has 4 buckets, no 'unknown'
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "--- Section 9: scale registry — 4 buckets, no 'unknown' ---"
echo ""

REGISTRY="$SCRIPTS_DIR/scale-registry.json"
if [[ ! -f "$REGISTRY" ]]; then
  echo "  FAIL: scale-registry.json not found at $REGISTRY"; FAIL=$((FAIL + 1))
else
  echo "Test 9.1: all 4 scale buckets registered"
  for BUCKET in implementation subsystem architecture abstract; do
    python3 -c "
import json, sys
reg = json.load(open(sys.argv[1]))
ids = [s['id'] for s in reg.get('scales', [])]
sys.exit(0 if sys.argv[2] in ids else 1)
" "$REGISTRY" "$BUCKET" \
      && { echo "  PASS: bucket '$BUCKET' in registry"; PASS=$((PASS+1)); } \
      || { echo "  FAIL: bucket '$BUCKET' missing from registry"; FAIL=$((FAIL+1)); }
  done

  echo ""
  echo "Test 9.2: 'unknown' is not registered"
  python3 -c "
import json, sys
reg = json.load(open(sys.argv[1]))
ids = [s['id'] for s in reg.get('scales', [])]
sys.exit(0 if 'unknown' not in ids else 1)
" "$REGISTRY" \
    && { echo "  PASS: 'unknown' not in registry"; PASS=$((PASS+1)); } \
    || { echo "  FAIL: 'unknown' still registered — should be removed"; FAIL=$((FAIL+1)); }
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Results ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo ""

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
