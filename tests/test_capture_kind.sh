#!/usr/bin/env bash
# test_capture_kind.sh — Tests for the epistemic --kind contract in capture.sh
# Covers: the fact default and its footer position, registry reader verbs,
# unregistered kind rejection, per-kind lifecycle vocabulary, kind/field
# applicability, footer sanitizing of free-text values, and the two projection
# seams (batch-capture.sh, lore-promote.sh) that must carry the same flags.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts"
TEST_DIR=$(mktemp -d)
KNOWLEDGE_DIR="$TEST_DIR/knowledge"
CAPTURE_SH="$SCRIPT_DIR/capture.sh"
KIND_REGISTRY_SH="$SCRIPT_DIR/kind-registry.sh"
BATCH_CAPTURE_SH="$SCRIPT_DIR/batch-capture.sh"
PROMOTE_SH="$SCRIPT_DIR/lore-promote.sh"

PASS=0
FAIL=0

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

assert_exit_nonzero() {
  local label="$1"
  local exit_code="$2"
  if [[ "$exit_code" -ne 0 ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (expected non-zero exit, got 0)"
    FAIL=$((FAIL + 1))
  fi
}

assert_exit_zero() {
  local label="$1"
  local exit_code="$2"
  if [[ "$exit_code" -eq 0 ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (expected exit 0, got $exit_code)"
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

assert_equals() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    Expected: $expected"
    echo "    Got:      $actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_file_contains() {
  local label="$1" filepath="$2" expected="$3"
  if [[ -f "$filepath" ]] && grep -qF -- "$expected" "$filepath"; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    if [[ ! -f "$filepath" ]]; then
      echo "    File does not exist: $filepath"
    else
      echo "    Expected file to contain: $expected"
      echo "    Got: $(tail -1 "$filepath")"
    fi
    FAIL=$((FAIL + 1))
  fi
}

assert_file_not_contains() {
  local label="$1" filepath="$2" unexpected="$3"
  if [[ ! -f "$filepath" ]]; then
    echo "  FAIL: $label (file does not exist: $filepath)"
    FAIL=$((FAIL + 1))
    return
  fi
  if grep -qF -- "$unexpected" "$filepath"; then
    echo "  FAIL: $label"
    echo "    Did not expect file to contain: $unexpected"
    echo "    Got: $(tail -1 "$filepath")"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  fi
}

run_capture() {
  bash "$CAPTURE_SH" "$@" 2>&1
  echo "EXIT:$?"
}

get_exit() {
  echo "$1" | grep "^EXIT:" | sed 's/EXIT://'
}

get_output() {
  echo "$1" | grep -v "^EXIT:"
}

setup_knowledge_store() {
  rm -rf "$KNOWLEDGE_DIR"
  mkdir -p "$KNOWLEDGE_DIR"
  echo '{}' > "$KNOWLEDGE_DIR/_manifest.json"
}

latest_entry() {
  find "$KNOWLEDGE_DIR" -name "*.md" 2>/dev/null | head -1
}

export LORE_KNOWLEDGE_DIR="$KNOWLEDGE_DIR"

echo "=== Capture Kind Tests ==="
echo ""

# =============================================
# Test 1: kind-registry.sh reader verbs
# =============================================
echo "Test 1: kind-registry.sh exposes the vocabulary and each kind's fields"

assert_equals "get-version prints an integer" \
  "$(bash "$KIND_REGISTRY_SH" get-version)" "1"
assert_equals "get-ids prints the four kind ids in ordinal order" \
  "$(bash "$KIND_REGISTRY_SH" get-ids | tr '\n' ' ')" "fact hypothesis question theory "
assert_equals "get-label resolves an id" \
  "$(bash "$KIND_REGISTRY_SH" get-label hypothesis)" "hypothesis"
assert_equals "get-statuses lists the hypothesis lifecycle" \
  "$(bash "$KIND_REGISTRY_SH" get-statuses hypothesis | tr '\n' ' ')" "untested supported refuted "
assert_equals "get-statuses lists the question lifecycle" \
  "$(bash "$KIND_REGISTRY_SH" get-statuses question | tr '\n' ' ')" "open answered dissolved "
assert_equals "get-statuses is empty for fact" \
  "$(bash "$KIND_REGISTRY_SH" get-statuses fact)" ""
assert_equals "get-fields lists required then optional question fields" \
  "$(bash "$KIND_REGISTRY_SH" get-fields question | tr '\n' ' ')" "kind_status where_looked answered_by "
assert_equals "get-required-fields names theory's subsystem" \
  "$(bash "$KIND_REGISTRY_SH" get-required-fields theory)" "subsystem"

REG_RESULT=$(bash "$KIND_REGISTRY_SH" get-label belief 2>&1; echo "EXIT:$?")
assert_exit_nonzero "unknown id is a lookup error" "$(get_exit "$REG_RESULT")"

# =============================================
# Test 2: no --kind emits `kind: fact` next to scale
# =============================================
echo ""
echo "Test 2: capture with no --kind defaults to fact, emitted after scale"
setup_knowledge_store

RESULT=$(run_capture --insight "default kind test insight" --scale implementation)
assert_exit_zero "capture without --kind succeeds" "$(get_exit "$RESULT")"
ENTRY=$(latest_entry)
assert_file_contains "kind: fact emitted immediately after scale" \
  "$ENTRY" "| scale: implementation | kind: fact | captured_at_branch:"
assert_file_not_contains "fact entry omits kind_status" "$ENTRY" "kind_status"
assert_file_not_contains "fact entry omits subsystem" "$ENTRY" "subsystem:"

# =============================================
# Test 3: hypothesis round-trips through the footer parser
# =============================================
echo ""
echo "Test 3: --kind hypothesis --kind-status untested round-trips"
setup_knowledge_store

RESULT=$(run_capture \
  --insight "hypothesis kind test insight" \
  --scale implementation \
  --kind hypothesis \
  --kind-status untested)
assert_exit_zero "hypothesis capture succeeds" "$(get_exit "$RESULT")"
ENTRY=$(latest_entry)
assert_file_contains "kind: hypothesis in footer" "$ENTRY" "| kind: hypothesis"
assert_file_contains "kind_status: untested in footer" "$ENTRY" "| kind_status: untested"

# The primary footer parser's KV scan is what every retrieval consumer reads
# through; assert it sees both keys with the values the writer emitted.
PARSED=$(python3 - "$SCRIPT_DIR" "$ENTRY" <<'PY'
import pathlib, sys
sys.path.insert(0, sys.argv[1])
from pk_markdown import MarkdownParser

text = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
for match in MarkdownParser._METADATA_COMMENT_RE.finditer(text):
    inner = match.group(1)
    if "learned:" not in inner:
        continue
    kv = {
        m.group(1).strip(): m.group(2).strip()
        for m in MarkdownParser._METADATA_KV_RE.finditer(inner)
    }
    print(f"kind={kv.get('kind')} kind_status={kv.get('kind_status')} status={kv.get('status')}")
    break
PY
)
assert_equals "footer parser KV scan sees kind, kind_status, and an untouched status" \
  "$PARSED" "kind=hypothesis kind_status=untested status=current"

# =============================================
# Test 4: free-text footer values are sanitized
# =============================================
echo ""
echo "Test 4: a --where-looked value containing a pipe is sanitized"
setup_knowledge_store

RESULT=$(run_capture \
  --insight "question kind sanitizer test insight" \
  --scale implementation \
  --kind question \
  --kind-status open \
  --where-looked "grep pk_search.py | head -20 and then scale > kind")
assert_exit_zero "question capture with a pipe in --where-looked succeeds" "$(get_exit "$RESULT")"
ENTRY=$(latest_entry)
assert_file_contains "pipe and angle bracket replaced with spaces" \
  "$ENTRY" "| where_looked: grep pk_search.py head -20 and then scale kind |"

FOOTER=$(tail -1 "$ENTRY")
FIELD_COUNT=$(echo "$FOOTER" | tr '|' '\n' | wc -l | tr -d ' ')
# The leading "<!-- learned:" segment plus one per " | key: value" pair:
# confidence, source, scale, kind, kind_status, where_looked, the branch trio,
# and status. A raw pipe inside a value would push this count up by one.
assert_equals "sanitized value adds no extra footer segments" "$FIELD_COUNT" "11"

# =============================================
# Test 5: unregistered kind is refused
# =============================================
echo ""
echo "Test 5: an unregistered kind id is refused with a bracketed diagnostic"
setup_knowledge_store

RESULT=$(run_capture --insight "bad kind test" --scale implementation --kind=belief)
assert_exit_nonzero "exits non-zero when kind=belief" "$(get_exit "$RESULT")"
assert_contains "diagnostic is bracketed" "$(get_output "$RESULT")" "[capture] Error:"
assert_contains "diagnostic names the rejection" "$(get_output "$RESULT")" "is not a registered kind id"
assert_contains "diagnostic lists fact" "$(get_output "$RESULT")" "fact"
assert_contains "diagnostic lists hypothesis" "$(get_output "$RESULT")" "hypothesis"
assert_contains "diagnostic lists question" "$(get_output "$RESULT")" "question"
assert_contains "diagnostic lists theory" "$(get_output "$RESULT")" "theory"

# =============================================
# Test 6: per-kind lifecycle vocabulary and required fields
# =============================================
echo ""
echo "Test 6: kind_status vocabulary and required fields are per-kind"
setup_knowledge_store

RESULT=$(run_capture --insight "cross vocabulary test" --scale implementation \
  --kind hypothesis --kind-status open)
assert_exit_nonzero "a question's status is rejected on a hypothesis" "$(get_exit "$RESULT")"
assert_contains "diagnostic names the invalid kind_status" "$(get_output "$RESULT")" \
  "is not valid for --kind \"hypothesis\""

RESULT=$(run_capture --insight "missing status test" --scale implementation --kind hypothesis)
assert_exit_nonzero "hypothesis without --kind-status is refused" "$(get_exit "$RESULT")"
assert_contains "diagnostic lists the hypothesis vocabulary" "$(get_output "$RESULT")" \
  "untested, supported, refuted"

RESULT=$(run_capture --insight "theory without subsystem test" --scale architecture --kind theory)
assert_exit_nonzero "theory without --subsystem is refused" "$(get_exit "$RESULT")"
assert_contains "diagnostic names --subsystem" "$(get_output "$RESULT")" "--subsystem is required"

RESULT=$(run_capture --insight "kind field applicability test" --scale implementation \
  --kind fact --subsystem retrieval)
assert_exit_nonzero "--subsystem on a fact is refused rather than dropped" "$(get_exit "$RESULT")"
assert_contains "diagnostic says the field belongs to theory" "$(get_output "$RESULT")" \
  "--subsystem does not apply"

RESULT=$(run_capture --insight "where looked applicability test" --scale implementation \
  --kind hypothesis --kind-status untested --where-looked "somewhere")
assert_exit_nonzero "--where-looked on a hypothesis is refused" "$(get_exit "$RESULT")"
assert_contains "diagnostic says the field belongs to question" "$(get_output "$RESULT")" \
  "--where-looked does not apply"

# =============================================
# Test 7: theory carries subsystem and no kind_status
# =============================================
echo ""
echo "Test 7: theory emits subsystem and omits kind_status"
setup_knowledge_store

RESULT=$(run_capture \
  --insight "theory kind test insight" \
  --scale architecture \
  --category architecture \
  --kind theory \
  --subsystem "knowledge retrieval")
assert_exit_zero "theory capture with --subsystem succeeds" "$(get_exit "$RESULT")"
ENTRY=$(latest_entry)
assert_file_contains "kind: theory in footer" "$ENTRY" "| kind: theory"
assert_file_contains "subsystem in footer" "$ENTRY" "| subsystem: knowledge retrieval"
assert_file_not_contains "theory entry omits kind_status" "$ENTRY" "kind_status"

# =============================================
# Test 8: batch-capture.sh carries the kind flags
# =============================================
echo ""
echo "Test 8: batch-capture.sh passes the kind flags to capture.sh"
setup_knowledge_store

BATCH_FILE="$TEST_DIR/batch.json"
cat > "$BATCH_FILE" <<'JSON'
[{"insight": "batch seam kind test insight",
  "scale": "implementation",
  "kind": "question",
  "kind_status": "answered",
  "where_looked": "scripts/batch-capture.sh",
  "answered_by": "conventions/scripting/shell-script-conventions.md"}]
JSON

BATCH_RESULT=$(bash "$BATCH_CAPTURE_SH" --file "$BATCH_FILE" 2>&1; echo "EXIT:$?")
assert_exit_zero "batch-capture succeeds" "$(get_exit "$BATCH_RESULT")"
ENTRY=$(latest_entry)
assert_file_contains "batch-capture carried kind" "$ENTRY" "| kind: question"
assert_file_contains "batch-capture carried kind_status" "$ENTRY" "| kind_status: answered"
assert_file_contains "batch-capture carried where_looked" "$ENTRY" \
  "| where_looked: scripts/batch-capture.sh"
assert_file_contains "batch-capture carried answered_by" "$ENTRY" \
  "| answered_by: conventions/scripting/shell-script-conventions.md"

# =============================================
# Test 9: lore-promote.sh carries the kind flags
# =============================================
echo ""
echo "Test 9: lore-promote.sh passes the kind flags through to capture.sh"
setup_knowledge_store

if ! command -v jq >/dev/null 2>&1; then
  echo "  SKIP: jq not available — lore-promote.sh seam not exercised"
else
  ROW_FILE="$TEST_DIR/tier3.json"
  cat > "$ROW_FILE" <<'JSON'
{"claim_id": "promote-seam-kind-01",
 "tier": "reusable",
 "claim": "Promotion carries the epistemic kind through to the entry writer",
 "producer_role": "worker",
 "protocol_slot": "implement-step-3",
 "scale": "implementation",
 "why_future_agent_cares": "A kind that survives capture but not promote is half a field",
 "falsifier": "A promoted entry whose footer carries no kind field",
 "related_files": ["scripts/lore-promote.sh"],
 "source_artifact_ids": ["t2-kind-seam"],
 "work_item": "epistemic-kinds-substrate-kind-field-writer-sweep",
 "confidence": "unaudited",
 "captured_at_sha": "0000000000000000000000000000000000000000",
 "kind": "hypothesis",
 "kind_status": "untested"}
JSON

  PROMOTE_RESULT=$(bash "$PROMOTE_SH" --file "$ROW_FILE" \
    --work-item epistemic-kinds-substrate-kind-field-writer-sweep --dry-run 2>&1; echo "EXIT:$?")
  assert_exit_zero "promote --dry-run succeeds" "$(get_exit "$PROMOTE_RESULT")"
  assert_contains "planned capture invocation carries --kind" \
    "$(get_output "$PROMOTE_RESULT")" "--kind hypothesis"
  assert_contains "planned capture invocation carries --kind-status" \
    "$(get_output "$PROMOTE_RESULT")" "--kind-status untested"
fi

# =============================================
# Test 10: every kind flag accepts the --flag=value spelling
# =============================================
echo ""
echo "Test 10: all five kind flags accept the equals form"
setup_knowledge_store

RESULT=$(run_capture \
  --insight "equals form kind flags test insight" \
  --scale=implementation \
  --kind=question \
  --kind-status=answered \
  --where-looked=scripts/capture.sh \
  --answered-by=tests/test_capture_kind.sh)
assert_exit_zero "question capture in equals form succeeds" "$(get_exit "$RESULT")"
ENTRY=$(latest_entry)
assert_file_contains "equals form carried kind" "$ENTRY" "| kind: question"
assert_file_contains "equals form carried kind_status" "$ENTRY" "| kind_status: answered"
assert_file_contains "equals form carried where_looked" "$ENTRY" \
  "| where_looked: scripts/capture.sh"
assert_file_contains "equals form carried answered_by" "$ENTRY" \
  "| answered_by: tests/test_capture_kind.sh"

setup_knowledge_store
RESULT=$(run_capture \
  --insight "equals form subsystem test insight" \
  --scale=architecture \
  --kind=theory \
  --subsystem=knowledge-retrieval)
assert_exit_zero "theory capture in equals form succeeds" "$(get_exit "$RESULT")"
assert_file_contains "equals form carried subsystem" "$(latest_entry)" \
  "| subsystem: knowledge-retrieval"

# =============================================
# Test 11: an unreadable registry refuses non-fact kinds, still writes facts
# =============================================
echo ""
echo "Test 10: with the registry unreadable, fact still lands and other kinds are refused"
setup_knowledge_store

# A scripts/ dir holding everything except the registry, so capture.sh runs with
# its registry reads failing rather than returning empty declarations.
NOREG_DIR="$TEST_DIR/scripts-no-registry"
mkdir -p "$NOREG_DIR"
for f in "$SCRIPT_DIR"/*; do
  [[ "$(basename "$f")" == "kind-registry.json" ]] && continue
  ln -s "$f" "$NOREG_DIR/$(basename "$f")"
done

NOREG_RESULT=$(bash "$NOREG_DIR/capture.sh" --insight "registry absent fact probe insight" \
  --scale implementation 2>&1; echo "EXIT:$?")
assert_exit_zero "a default fact capture still lands" "$(get_exit "$NOREG_RESULT")"
assert_file_contains "and still carries kind: fact" "$(latest_entry)" "| kind: fact"

NOREG_RESULT=$(bash "$NOREG_DIR/capture.sh" --insight "registry absent hypothesis probe" \
  --scale implementation --kind hypothesis --kind-status untested 2>&1; echo "EXIT:$?")
assert_exit_nonzero "a hypothesis capture is refused" "$(get_exit "$NOREG_RESULT")"
assert_contains "diagnostic names the unreadable registry" "$(get_output "$NOREG_RESULT")" \
  "cannot read the kind registry"

# =============================================
# Summary
# =============================================
echo ""
echo "=== Results ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo ""

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
