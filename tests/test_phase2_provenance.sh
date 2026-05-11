#!/usr/bin/env bash
# test_phase2_provenance.sh — Round-trip tests for Phase 2 provenance flags.
#
# Verifies:
#   1. capture.sh writes the 5 provenance flags and 3 branch-provenance fields into the
#      metadata comment block; read-back matches.
#   2. _capture_log.csv schema carries the template_version column; round-trips.
#   3. create-followup.sh propagates provenance into _meta.json (omitted-field convention)
#      and enriches lens-findings.json per finding (per-finding wins over CLI default).
#   4. write-execution-log.sh emits `Template-version:` only when the flag is provided.
#   5. update-manifest.sh surfaces the provenance fields (null-tolerant for legacy entries
#      missing the metadata block).
#   6. work-item _meta.json `scope` field round-trips via create-work.sh and set-work-meta.sh;
#      legacy items without the field stay readable (script doesn't require it).
#   7. Capture succeeds with `null` branch/sha/merge-base when run outside a git repo.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$REPO_ROOT/scripts"
TEST_DIR=$(mktemp -d)
KNOWLEDGE_DIR="$TEST_DIR/knowledge"

PASS=0
FAIL=0

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

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
      echo "    File contents (head):"
      head -15 "$filepath" | sed 's/^/      /'
    fi
    FAIL=$((FAIL + 1))
  fi
}

assert_file_not_contains() {
  local label="$1" filepath="$2" unexpected="$3"
  if [[ -f "$filepath" ]] && grep -qF -- "$unexpected" "$filepath"; then
    echo "  FAIL: $label"
    echo "    File should NOT contain: $unexpected"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  fi
}

assert_contains() {
  local label="$1" haystack="$2" expected="$3"
  if [[ "$haystack" == *"$expected"* ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    Expected output to contain: $expected"
    echo "    Output: $haystack"
    FAIL=$((FAIL + 1))
  fi
}

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

assert_exit_nonzero() {
  local label="$1" rc="$2"
  if [[ "$rc" -ne 0 ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label — expected non-zero exit"
    FAIL=$((FAIL + 1))
  fi
}

# --- Setup test knowledge store ---
setup_knowledge_store() {
  rm -rf "$KNOWLEDGE_DIR"
  mkdir -p "$KNOWLEDGE_DIR"/{_work,conventions}
  echo '{"format_version": 2, "created_at": "2026-01-01T00:00:00Z"}' > "$KNOWLEDGE_DIR/_manifest.json"
}

setup_knowledge_store
export LORE_KNOWLEDGE_DIR="$KNOWLEDGE_DIR"

echo "=== Phase 2 Provenance Tests ==="
echo ""

# =============================================
# Test 1: capture.sh writes all provenance + branch-provenance fields
# =============================================
echo "Test 1: capture.sh — all 5 provenance flags surface in entry metadata"

bash "$SCRIPT_DIR/capture.sh" \
  --insight "All provenance round trip for capture" \
  --category "conventions" \
  --scale "implementation" \
  --producer-role "worker" \
  --protocol-slot "capture" \
  --template-version "sha256:deadbeef" \
  --capturer-role "lead" \
  --source-artifact-ids "art-1,art-2" \
  --captured-at-branch "feat/test" \
  --captured-at-sha "abcdef0" \
  --captured-at-merge-base-sha "fedcba1" \
  --skip-manifest > /dev/null 2>&1

ENTRY_FILE=$(ls "$KNOWLEDGE_DIR/conventions/"*.md 2>/dev/null | head -1)
assert_file_contains "producer_role in metadata" "$ENTRY_FILE" "producer_role: worker"
assert_file_contains "protocol_slot in metadata" "$ENTRY_FILE" "protocol_slot: capture"
assert_file_contains "template_version in metadata" "$ENTRY_FILE" "template_version: sha256:deadbeef"
assert_file_contains "capturer_role in metadata" "$ENTRY_FILE" "capturer_role: lead"
assert_file_contains "source_artifact_ids in metadata" "$ENTRY_FILE" "source_artifact_ids: art-1,art-2"
assert_file_contains "captured_at_branch in metadata" "$ENTRY_FILE" "captured_at_branch: feat/test"
assert_file_contains "captured_at_sha in metadata" "$ENTRY_FILE" "captured_at_sha: abcdef0"
assert_file_contains "captured_at_merge_base_sha in metadata" "$ENTRY_FILE" "captured_at_merge_base_sha: fedcba1"

# =============================================
# Test 2: capture.sh — omitted provenance flags do not surface (omitted-field convention)
# =============================================
echo ""
echo "Test 2: capture.sh — omitted provenance fields are absent"
setup_knowledge_store

bash "$SCRIPT_DIR/capture.sh" \
  --insight "Legacy capture without provenance" \
  --category "conventions" \
  --scale "implementation" \
  --captured-at-branch "null" \
  --captured-at-sha "null" \
  --captured-at-merge-base-sha "null" \
  --skip-manifest > /dev/null 2>&1

ENTRY_FILE=$(ls "$KNOWLEDGE_DIR/conventions/"*.md 2>/dev/null | head -1)
assert_file_not_contains "no producer_role when omitted" "$ENTRY_FILE" "producer_role:"
assert_file_not_contains "no protocol_slot when omitted" "$ENTRY_FILE" "protocol_slot:"
assert_file_not_contains "no template_version when omitted" "$ENTRY_FILE" "template_version:"
assert_file_not_contains "no capturer_role when omitted" "$ENTRY_FILE" "capturer_role:"
assert_file_not_contains "no source_artifact_ids when omitted" "$ENTRY_FILE" "source_artifact_ids:"

# =============================================
# Test 3: _capture_log.csv — schema includes template_version column
# =============================================
echo ""
echo "Test 3: _capture_log.csv — template_version column round-trips"
setup_knowledge_store

bash "$SCRIPT_DIR/capture.sh" \
  --insight "TV populated" --category "conventions" \
  --scale "implementation" \
  --template-version "tv-one" \
  --captured-at-branch "null" --captured-at-sha "null" --captured-at-merge-base-sha "null" \
  --skip-manifest > /dev/null 2>&1

bash "$SCRIPT_DIR/capture.sh" \
  --insight "TV omitted" --category "conventions" \
  --scale "implementation" \
  --captured-at-branch "null" --captured-at-sha "null" --captured-at-merge-base-sha "null" \
  --skip-manifest > /dev/null 2>&1

LOG_FILE="$KNOWLEDGE_DIR/_capture_log.csv"
HEADER=$(head -1 "$LOG_FILE")
assert_eq "CSV header includes template_version" "$HEADER" "timestamp,source,category,confidence,template_version"

# Row 1 (TV populated): 5th field = tv-one
ROW1_TV=$(awk -F, 'NR==2 {print $5}' "$LOG_FILE")
assert_eq "row 1 template_version = tv-one" "$ROW1_TV" "tv-one"

# Row 2 (TV omitted): 5th field = "" (empty)
ROW2_TV=$(awk -F, 'NR==3 {print $5}' "$LOG_FILE")
assert_eq "row 2 template_version empty when omitted" "$ROW2_TV" ""

# =============================================
# Test 4: create-followup.sh — provenance fields in _meta.json (all 5 set)
# =============================================
echo ""
echo "Test 4: create-followup.sh — provenance in _meta.json"
setup_knowledge_store

bash "$SCRIPT_DIR/create-followup.sh" \
  --title "Full provenance followup" \
  --source "worker-2" \
  --producer-role "worker" \
  --protocol-slot "review" \
  --template-version "tv-fu" \
  --capturer-role "lead" \
  --source-artifact-ids "a1,a2" > /dev/null 2>&1

FU_META="$KNOWLEDGE_DIR/_followups/full-provenance-followup/_meta.json"
PR=$(python3 -c "import json; print(json.load(open('$FU_META'))['producer_role'])")
assert_eq "followup _meta.json producer_role" "$PR" "worker"
PS=$(python3 -c "import json; print(json.load(open('$FU_META'))['protocol_slot'])")
assert_eq "followup _meta.json protocol_slot" "$PS" "review"
TV=$(python3 -c "import json; print(json.load(open('$FU_META'))['template_version'])")
assert_eq "followup _meta.json template_version" "$TV" "tv-fu"
CR=$(python3 -c "import json; print(json.load(open('$FU_META'))['capturer_role'])")
assert_eq "followup _meta.json capturer_role" "$CR" "lead"
SA=$(python3 -c "import json; print(json.load(open('$FU_META'))['source_artifact_ids'])")
assert_eq "followup _meta.json source_artifact_ids" "$SA" "a1,a2"

# Legacy followup (no provenance): keys must not appear
bash "$SCRIPT_DIR/create-followup.sh" \
  --title "Legacy followup" \
  --source "test" > /dev/null 2>&1
LEGACY_META="$KNOWLEDGE_DIR/_followups/legacy-followup/_meta.json"
HAS_PR=$(python3 -c "import json; print('producer_role' in json.load(open('$LEGACY_META')))")
assert_eq "legacy followup has no producer_role" "$HAS_PR" "False"

# =============================================
# Test 5: create-followup.sh — lens-findings enrichment (per-finding wins)
# =============================================
echo ""
echo "Test 5: create-followup.sh — lens-findings per-finding provenance wins over CLI default"
setup_knowledge_store

cat > "$TEST_DIR/lens.json" << 'LENSEOF'
{
  "pr": 42,
  "work_item": "",
  "findings": [
    {"severity": "blocking", "title": "Bare finding", "file": "x.py", "line": 10, "body": "b", "lens": "correctness", "grounding": "g", "selected": true},
    {"severity": "suggestion", "title": "Attributed finding", "file": "y.py", "line": 0, "body": "b2", "lens": "security", "grounding": "g2", "selected": true, "producer_role": "researcher"}
  ]
}
LENSEOF

bash "$SCRIPT_DIR/create-followup.sh" \
  --title "Self review test" \
  --source "pr-self-review" \
  --lens-findings "$TEST_DIR/lens.json" \
  --producer-role "worker" \
  --protocol-slot "review" \
  --template-version "tv-cli" > /dev/null 2>&1

LENS_OUT="$KNOWLEDGE_DIR/_followups/self-review-test/lens-findings.json"

F0_PR=$(python3 -c "import json; print(json.load(open('$LENS_OUT'))['findings'][0]['producer_role'])")
assert_eq "finding 0 got CLI producer_role" "$F0_PR" "worker"
F0_TV=$(python3 -c "import json; print(json.load(open('$LENS_OUT'))['findings'][0]['template_version'])")
assert_eq "finding 0 got CLI template_version" "$F0_TV" "tv-cli"

F1_PR=$(python3 -c "import json; print(json.load(open('$LENS_OUT'))['findings'][1]['producer_role'])")
assert_eq "finding 1 kept its own producer_role" "$F1_PR" "researcher"
F1_PS=$(python3 -c "import json; print(json.load(open('$LENS_OUT'))['findings'][1]['protocol_slot'])")
assert_eq "finding 1 got CLI protocol_slot (missing)" "$F1_PS" "review"

# Without CLI provenance flags, the lens-findings payload is written byte-identically.
setup_knowledge_store

bash "$SCRIPT_DIR/create-followup.sh" \
  --title "Legacy lens" \
  --source "pr-self-review" \
  --lens-findings "$TEST_DIR/lens.json" > /dev/null 2>&1
LEGACY_LENS_OUT="$KNOWLEDGE_DIR/_followups/legacy-lens/lens-findings.json"
HAS_TV=$(python3 -c "import json; print(any('template_version' in f for f in json.load(open('$LEGACY_LENS_OUT'))['findings']))")
assert_eq "legacy lens-findings has no injected template_version" "$HAS_TV" "False"

# =============================================
# Test 6: write-execution-log.sh — Template-version line only when flag supplied
# =============================================
echo ""
echo "Test 6: write-execution-log.sh — Template-version header gating"
setup_knowledge_store

# Create a work item the script will append into
bash "$SCRIPT_DIR/create-work.sh" --title "Exec log target" --scope subsystem > /dev/null 2>&1

echo "entry body one" | bash "$SCRIPT_DIR/write-execution-log.sh" \
  --slug "exec-log-target" \
  --source "manual" \
  --template-version "tv-exec-1" > /dev/null 2>&1

LOG_FILE="$KNOWLEDGE_DIR/_work/exec-log-target/execution-log.md"
assert_file_contains "log has Template-version line when flag set" "$LOG_FILE" "Template-version: tv-exec-1"

echo "entry body two" | bash "$SCRIPT_DIR/write-execution-log.sh" \
  --slug "exec-log-target" \
  --source "manual" > /dev/null 2>&1

# Count Template-version lines: should still be exactly 1 (first entry only).
TV_LINES=$(grep -c "^Template-version:" "$LOG_FILE" || true)
assert_eq "only flagged entry has Template-version line" "$TV_LINES" "1"

# =============================================
# Test 7: update-manifest.sh — surfaces provenance fields (null-tolerant for legacy)
# =============================================
echo ""
echo "Test 7: update-manifest.sh — provenance surfaces in manifest; null for legacy"
setup_knowledge_store

# Entry with full provenance
bash "$SCRIPT_DIR/capture.sh" \
  --insight "Manifest entry with provenance" --category "conventions" \
  --scale "implementation" \
  --producer-role "worker" --protocol-slot "capture" --template-version "tv-mf" \
  --captured-at-branch "main" --captured-at-sha "aaaa" --captured-at-merge-base-sha "bbbb" \
  --skip-manifest > /dev/null 2>&1

# Legacy entry (no metadata comment block at all)
cat > "$KNOWLEDGE_DIR/conventions/legacy-entry.md" << 'LEGACYEOF'
# Legacy Entry
This entry predates Phase 2 and has no provenance metadata comment.
LEGACYEOF

bash "$SCRIPT_DIR/update-manifest.sh" > /dev/null 2>&1

MANIFEST="$KNOWLEDGE_DIR/_manifest.json"
assert_file_contains "manifest surfaces producer_role" "$MANIFEST" '"producer_role": "worker"'
assert_file_contains "manifest surfaces template_version" "$MANIFEST" '"template_version": "tv-mf"'
assert_file_contains "manifest surfaces captured_at_branch" "$MANIFEST" '"captured_at_branch": "main"'

# Legacy entry: producer_role should be null
LEGACY_PR=$(python3 -c "
import json
m = json.load(open('$MANIFEST'))
for e in m.get('entries', []):
    if 'legacy-entry' in e.get('path', ''):
        print(e.get('producer_role'))
        break
")
assert_eq "legacy entry producer_role is null" "$LEGACY_PR" "None"

# =============================================
# Test 8: work-item scope — create/set round-trip + enum validation
# =============================================
echo ""
echo "Test 8: work-item scope round-trip"
setup_knowledge_store

# Default scope
bash "$SCRIPT_DIR/create-work.sh" --title "Default scope item" > /dev/null 2>&1
SCOPE=$(python3 -c "import json; print(json.load(open('$KNOWLEDGE_DIR/_work/default-scope-item/_meta.json'))['scope'])")
assert_eq "default scope is subsystem" "$SCOPE" "subsystem"

# Explicit scope
bash "$SCRIPT_DIR/create-work.sh" --title "Arch item" --scope architectural > /dev/null 2>&1
SCOPE=$(python3 -c "import json; print(json.load(open('$KNOWLEDGE_DIR/_work/arch-item/_meta.json'))['scope'])")
assert_eq "create --scope architectural" "$SCOPE" "architectural"

# Intent anchor preserves capability intent for downstream /spec without storing raw conversational pressure.
ANCHOR="Capability: queued claims are actually judged by a real settlement executor; partial if only queue/status UI exists."
bash "$SCRIPT_DIR/create-work.sh" --title "Intent anchor item" --intent-anchor "$ANCHOR" > /dev/null 2>&1
ANCHOR_META=$(python3 -c "import json; print(json.load(open('$KNOWLEDGE_DIR/_work/intent-anchor-item/_meta.json'))['intent_anchor'])")
assert_eq "create stores intent anchor" "$ANCHOR_META" "$ANCHOR"
assert_file_contains "notes include intent anchor section" "$KNOWLEDGE_DIR/_work/intent-anchor-item/notes.md" "$ANCHOR"
LOAD_OUTPUT=$(bash "$SCRIPT_DIR/load-work-item.sh" intent-anchor-item)
assert_contains "load output shows intent anchor" "$LOAD_OUTPUT" "Intent anchor: $ANCHOR"
LOAD_JSON=$(bash "$SCRIPT_DIR/load-work-item.sh" --json intent-anchor-item)
LOAD_ANCHOR=$(python3 -c "import json,sys; print(json.load(sys.stdin)['intent_anchor'])" <<< "$LOAD_JSON")
assert_eq "load json includes intent anchor" "$LOAD_ANCHOR" "$ANCHOR"

# Invalid scope on create
set +e
bash "$SCRIPT_DIR/create-work.sh" --title "Bogus" --scope banana > /dev/null 2>&1
RC=$?
set -e
assert_exit_nonzero "create --scope banana rejected" "$RC"

# set --scope updates the field
bash "$SCRIPT_DIR/set-work-meta.sh" default-scope-item --scope implementation > /dev/null 2>&1
SCOPE=$(python3 -c "import json; print(json.load(open('$KNOWLEDGE_DIR/_work/default-scope-item/_meta.json'))['scope'])")
assert_eq "set --scope implementation" "$SCOPE" "implementation"

# set --scope on legacy item (no scope field) inserts it
mkdir -p "$KNOWLEDGE_DIR/_work/legacy-item"
cat > "$KNOWLEDGE_DIR/_work/legacy-item/_meta.json" << 'LEGACYMETAEOF'
{
  "slug": "legacy-item",
  "title": "Legacy Item",
  "status": "active",
  "branches": [],
  "tags": [],
  "issue": "",
  "pr": "",
  "created": "2025-01-01T00:00:00Z",
  "updated": "2025-01-01T00:00:00Z",
  "related_knowledge": [],
  "related_work": []
}
LEGACYMETAEOF

bash "$SCRIPT_DIR/set-work-meta.sh" legacy-item --scope granular-fix > /dev/null 2>&1
SCOPE=$(python3 -c "import json; print(json.load(open('$KNOWLEDGE_DIR/_work/legacy-item/_meta.json'))['scope'])")
assert_eq "set --scope on legacy item inserts scope" "$SCOPE" "granular-fix"

# Invalid scope on set
set +e
bash "$SCRIPT_DIR/set-work-meta.sh" legacy-item --scope banana > /dev/null 2>&1
RC=$?
set -e
assert_exit_nonzero "set --scope banana rejected" "$RC"

# --- verify-plan-intent-anchor.sh contract (D4) ---
# Build hand-crafted fixtures under a scratch work-dir so we can exercise the
# extraction-boundary, divergence, and skip shapes precisely. Pass --work-dir
# to the verifier; do not touch the live knowledge store.
VERIFIER="$SCRIPT_DIR/verify-plan-intent-anchor.sh"
ANCHOR_WORK_DIR="$TEST_DIR/anchor-work"
mkdir -p "$ANCHOR_WORK_DIR"

# Multi-line anchor body (internal blank line + multiple non-blank lines)
# exercises the extraction-boundary rule from D3.
ANCHOR_MULTILINE=$'Capability: queued claims are actually judged by a real settlement executor.\n\nPartial: only queue or status UI exists without the judging step wired through.'

write_anchor_fixture() {
  local slug="$1" anchor="$2" plan_body="$3"
  local dir="$ANCHOR_WORK_DIR/$slug"
  mkdir -p "$dir"
  python3 - "$dir/_meta.json" "$slug" "$anchor" <<'PYEOF'
import json, sys
path, slug, anchor = sys.argv[1], sys.argv[2], sys.argv[3]
meta = {
    "slug": slug,
    "title": slug,
    "status": "active",
    "branches": [],
    "tags": [],
    "issue": "",
    "pr": "",
    "created": "2026-01-01T00:00:00Z",
    "updated": "2026-01-01T00:00:00Z",
    "related_knowledge": [],
    "related_work": [],
    "scope": "subsystem",
    "intent_anchor": anchor,
}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(meta, fh, indent=2)
PYEOF
  printf '%s' "$plan_body" > "$dir/plan.md"
}

# (a) Exit 0 on a multi-line anchor body — extraction boundary respects internal blank lines.
PLAN_PASS=$'# Multi Anchor\n\n## Intent Anchor\nCapability: queued claims are actually judged by a real settlement executor.\n\nPartial: only queue or status UI exists without the judging step wired through.\n\n**Scope delta:** none — anchor preserved unchanged.\n\n## Strategy\nbody.\n'
write_anchor_fixture "anchor-pass" "$ANCHOR_MULTILINE" "$PLAN_PASS"
set +e
bash "$VERIFIER" anchor-pass --work-dir "$ANCHOR_WORK_DIR" > /dev/null 2> "$TEST_DIR/verr.log"
RC=$?
set -e
assert_eq "verifier (a) exit 0 on multi-line anchor" "$RC" "0"

# (b) Exit 2 when `## Intent Anchor` section is absent.
PLAN_NO_SECTION=$'# Missing Section\n\n## Narrative\nNo anchor section here.\n\n## Strategy\nbody.\n'
write_anchor_fixture "anchor-missing-section" "$ANCHOR_MULTILINE" "$PLAN_NO_SECTION"
set +e
bash "$VERIFIER" anchor-missing-section --work-dir "$ANCHOR_WORK_DIR" > /dev/null 2> "$TEST_DIR/verr.log"
RC=$?
set -e
assert_eq "verifier (b) exit 2 when section missing" "$RC" "2"

# (c) Exit 3 when anchor body diverges by a single character.
PLAN_DIVERGE=$'# Diverged\n\n## Intent Anchor\nCapability: queued claims are actually judged by a real settlement executor.\n\nPartial: only queue or status UI exists without the judging step wired throughX.\n\n**Scope delta:** none — anchor preserved unchanged.\n'
write_anchor_fixture "anchor-diverge" "$ANCHOR_MULTILINE" "$PLAN_DIVERGE"
set +e
bash "$VERIFIER" anchor-diverge --work-dir "$ANCHOR_WORK_DIR" > /dev/null 2> "$TEST_DIR/verr.log"
RC=$?
set -e
assert_eq "verifier (c) exit 3 on single-character body divergence" "$RC" "3"

# (d) Exit 4 when `**Scope delta:**` line is absent (section + matching body, but no scope-delta before next heading / EOF).
PLAN_NO_SCOPE=$'# Missing Scope Delta\n\n## Intent Anchor\nCapability: queued claims are actually judged by a real settlement executor.\n\nPartial: only queue or status UI exists without the judging step wired through.\n\n## Strategy\nNo scope-delta line preceded this next heading.\n'
write_anchor_fixture "anchor-no-scope-delta" "$ANCHOR_MULTILINE" "$PLAN_NO_SCOPE"
set +e
bash "$VERIFIER" anchor-no-scope-delta --work-dir "$ANCHOR_WORK_DIR" > /dev/null 2> "$TEST_DIR/verr.log"
RC=$?
set -e
assert_eq "verifier (d) exit 4 when scope-delta line missing" "$RC" "4"

# (e) Exit 0 + documented stderr skip message when `_meta.json` lacks `intent_anchor`.
NO_ANCHOR_DIR="$ANCHOR_WORK_DIR/anchor-skipped"
mkdir -p "$NO_ANCHOR_DIR"
cat > "$NO_ANCHOR_DIR/_meta.json" << 'METAEOF'
{
  "slug": "anchor-skipped",
  "title": "anchor-skipped",
  "status": "active",
  "branches": [],
  "tags": [],
  "issue": "",
  "pr": "",
  "created": "2026-01-01T00:00:00Z",
  "updated": "2026-01-01T00:00:00Z",
  "related_knowledge": [],
  "related_work": [],
  "scope": "subsystem"
}
METAEOF
cat > "$NO_ANCHOR_DIR/plan.md" << 'PLANEOF'
# Plan with no anchor in meta
## Narrative
Legacy item — no intent_anchor in _meta.json.
PLANEOF
set +e
STDERR_OUT=$(bash "$VERIFIER" anchor-skipped --work-dir "$ANCHOR_WORK_DIR" 2>&1 >/dev/null)
RC=$?
set -e
assert_eq "verifier (e) exit 0 when meta has no intent_anchor" "$RC" "0"
assert_contains "verifier (e) stderr documents the skip" "$STDERR_OUT" "[verify-plan-intent-anchor] anchor-skipped: no intent_anchor in _meta.json — skipping"

# (f) Exit 0 when surrounding blank lines differ but internal content matches (trim rule).
PLAN_EXTRA_BLANKS=$'# Extra Blanks\n\n## Intent Anchor\n\n\nCapability: queued claims are actually judged by a real settlement executor.\n\nPartial: only queue or status UI exists without the judging step wired through.\n\n\n**Scope delta:** none — anchor preserved unchanged.\n'
write_anchor_fixture "anchor-blank-tolerant" "$ANCHOR_MULTILINE" "$PLAN_EXTRA_BLANKS"
set +e
bash "$VERIFIER" anchor-blank-tolerant --work-dir "$ANCHOR_WORK_DIR" > /dev/null 2> "$TEST_DIR/verr.log"
RC=$?
set -e
assert_eq "verifier (f) exit 0 with extra surrounding blank lines (trim respected)" "$RC" "0"

# =============================================
# Test 9: capture.sh outside a git repo — branch/sha resolve to "null"
# =============================================
echo ""
echo "Test 9: capture.sh outside a git repo — branch trio resolves to null"
setup_knowledge_store

# Run capture from a temp dir that is NOT a git repo, and cd there so
# `git rev-parse` has no repo to read. Use a subshell so we don't clobber cwd.
NONGIT_DIR="$TEST_DIR/not-a-repo"
mkdir -p "$NONGIT_DIR"

(
  cd "$NONGIT_DIR"
  # Belt-and-suspenders: unset any inherited GIT_* env vars that would point at a repo.
  unset GIT_DIR GIT_WORK_TREE || true
  bash "$SCRIPT_DIR/capture.sh" \
    --insight "Capture outside repo" --category "conventions" \
    --scale "implementation" \
    --skip-manifest > /dev/null 2>&1
)

ENTRY_FILE=$(ls "$KNOWLEDGE_DIR/conventions/"*.md 2>/dev/null | head -1)
assert_file_contains "outside-repo captured_at_branch = null" "$ENTRY_FILE" "captured_at_branch: null"
assert_file_contains "outside-repo captured_at_sha = null" "$ENTRY_FILE" "captured_at_sha: null"
assert_file_contains "outside-repo captured_at_merge_base_sha = null" "$ENTRY_FILE" "captured_at_merge_base_sha: null"

# =============================================
# Summary
# =============================================
echo ""
echo "=== Results ==="
TOTAL=$((PASS + FAIL))
echo "$PASS/$TOTAL passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  exit 1
else
  echo "All Phase 2 provenance tests passed!"
  exit 0
fi
