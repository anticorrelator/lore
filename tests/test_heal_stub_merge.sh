#!/usr/bin/env bash
# test_heal_stub_merge.sh — Tests for scripts/merge-work-stub.sh and the
# archive-aware orphan routing in scripts/heal-work.sh.
#
# Covers:
#   - verbatim JSONL row relocation with natural-id dedupe (reattempt_id,
#     judge_run_at+artifact_id envelopes) and merge idempotency
#   - heal-scaffold _meta.json / notes.md discarded by template fingerprint
#   - non-JSONL files moved; basename collision with differing content aborts
#     before any mutation
#   - stub dir removal and work-index regeneration
#   - refusal shapes: no archive sibling, real _meta.json, underscore slug
#   - heal-work.sh routes archive-sibling orphans (bare and previously
#     scaffolded) to the merge instead of scaffolding, and still scaffolds
#     orphans without an archive sibling

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts"
MERGE="$SCRIPT_DIR/merge-work-stub.sh"
HEAL="$SCRIPT_DIR/heal-work.sh"

PASS=0
FAIL=0

TEST_DIR=$(mktemp -d)
cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    expected: $expected"
    echo "    actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -qF -- "$needle"; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    expected to contain: $needle"
    echo "    actual: $(echo "$haystack" | head -3)"
    FAIL=$((FAIL + 1))
  fi
}

assert_exists() {
  local label="$1" path="$2"
  if [[ -e "$path" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label — missing: $path"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_exists() {
  local label="$1" path="$2"
  if [[ ! -e "$path" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label — should not exist: $path"
    FAIL=$((FAIL + 1))
  fi
}

# --- Fixtures ---

fresh_store() {
  # fresh_store <name> — creates an isolated store and points resolution at it
  export LORE_KNOWLEDGE_DIR="$TEST_DIR/$1"
  mkdir -p "$LORE_KNOWLEDGE_DIR/_work/_archive"
}

make_archive_item() {
  # make_archive_item <slug> — archived item with settlement artifacts
  local slug="$1" dir="$LORE_KNOWLEDGE_DIR/_work/_archive/$1"
  mkdir -p "$dir/verdicts"
  cat > "$dir/_meta.json" <<EOF
{"slug":"$slug","title":"Real Item","status":"archived","project":"proj-x","created":"2026-01-01T00:00:00Z","updated":"2026-02-01T00:00:00Z","intent_anchor":"real anchor"}
EOF
  echo "# Session Notes: Real Item" > "$dir/notes.md"
  echo "## 2026-02-01T00:00 real session entry" >> "$dir/notes.md"
  echo "archive evidence body" > "$dir/evidence.md"
  echo '{"reattempt_id":"reatt-arch","artifact_id":"'"$slug"'","status":"pending_reattempt"}' > "$dir/audit-reattempts.jsonl"
  echo '{"judge_run_at":"2026-07-02T05:13:45Z","artifact_id":"'"$slug"'","judge":"correctness-gate-assertion"}' > "$dir/verdicts/task-claims.jsonl"
}

make_scaffold_stub() {
  # make_scaffold_stub <slug> — active stub as a prior heal run leaves it:
  # scaffold-fingerprint _meta.json + scaffold notes.md
  local slug="$1" dir="$LORE_KNOWLEDGE_DIR/_work/$1"
  local title
  title=$(echo "$slug" | tr '-' ' ' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)}1')
  mkdir -p "$dir"
  cat > "$dir/_meta.json" <<EOF
{
  "slug": "$slug",
  "title": "$title",
  "status": "active",
  "scope": "subsystem",
  "project": "",
  "branches": [],
  "tags": [],
  "issue": "",
  "pr": "",
  "created": "2026-07-02T06:37:08Z",
  "updated": "2026-07-02T06:37:08Z",
  "related_knowledge": [],
  "related_work": [],
  "intent_anchor": ""
}
EOF
  cat > "$dir/notes.md" <<EOF
# Session Notes: $title

<!-- Append session entries below. Entry format: ## YYYY-MM-DDTHH:MM followed by **Focus:**, **Progress:**, **Next:** fields. -->
EOF
}

DUP_ROW='{"reattempt_id":"reatt-arch","artifact_id":"stub-item","status":"pending_reattempt"}'
NEW_ROW='{"reattempt_id":"reatt-new","artifact_id":"stub-item","status":"pending_reattempt"}'
NEW_ENVELOPE='{"judge_run_at":"2026-07-02T06:15:06Z","artifact_id":"stub-item","judge":"reverse-auditor"}'
DUP_ENVELOPE='{"judge_run_at":"2026-07-02T05:13:45Z","artifact_id":"stub-item","judge":"correctness-gate-assertion","note":"same natural key, different content"}'

make_residue_files() {
  # make_residue_files <slug> — settlement rows inside the active stub
  local dir="$LORE_KNOWLEDGE_DIR/_work/$1"
  mkdir -p "$dir/verdicts"
  printf '%s\n%s\n' "$DUP_ROW" "$NEW_ROW" > "$dir/audit-reattempts.jsonl"
  printf '%s\n%s\n' "$NEW_ENVELOPE" "$DUP_ENVELOPE" > "$dir/verdicts/task-claims.jsonl"
}

# ============================================================
echo "Test: merge relocates rows verbatim with natural-id dedupe"
# ============================================================
fresh_store t1
make_archive_item stub-item
make_scaffold_stub stub-item
make_residue_files stub-item
ARCH="$LORE_KNOWLEDGE_DIR/_work/_archive/stub-item"

OUT=$(bash "$MERGE" stub-item)
assert_contains "reports relocated reattempt row" "$OUT" "audit-reattempts.jsonl: +1 rows (1 duplicates skipped)"
assert_contains "reports relocated envelope row" "$OUT" "verdicts/task-claims.jsonl: +1 rows (1 duplicates skipped)"

assert_eq "reattempt rows = active∪archive union" "$(wc -l < "$ARCH/audit-reattempts.jsonl" | tr -d ' ')" "2"
assert_eq "envelope rows = active∪archive union" "$(wc -l < "$ARCH/verdicts/task-claims.jsonl" | tr -d ' ')" "2"
assert_eq "duplicate reattempt_id not double-appended" "$(grep -cF 'reatt-arch' "$ARCH/audit-reattempts.jsonl")" "1"
assert_eq "relocated row is byte-verbatim" "$(grep -cxF "$NEW_ROW" "$ARCH/audit-reattempts.jsonl")" "1"
assert_eq "envelope with duplicate natural key skipped (archive wins)" "$(grep -cF 'same natural key' "$ARCH/verdicts/task-claims.jsonl")" "0"

assert_not_exists "stub dir removed" "$LORE_KNOWLEDGE_DIR/_work/stub-item"
assert_contains "archive _meta.json untouched (scaffold discarded)" "$(cat "$ARCH/_meta.json")" "real anchor"
assert_contains "archive notes.md untouched (scaffold discarded)" "$(cat "$ARCH/notes.md")" "real session entry"

assert_exists "work index regenerated" "$LORE_KNOWLEDGE_DIR/_work/_index.json"
INDEX_STATE=$(python3 -c "
import json
idx = json.load(open('$LORE_KNOWLEDGE_DIR/_work/_index.json'))
active = [p['slug'] for p in idx['plans']]
archived = [a['slug'] for a in idx['archived']]
print(('stub-item' in active), ('stub-item' in archived))
")
assert_eq "slug archived-only in index" "$INDEX_STATE" "False True"

# ============================================================
echo "Test: re-running the merge on recreated residue is a no-op"
# ============================================================
mkdir -p "$LORE_KNOWLEDGE_DIR/_work/stub-item/verdicts"
printf '%s\n%s\n' "$DUP_ROW" "$NEW_ROW" > "$LORE_KNOWLEDGE_DIR/_work/stub-item/audit-reattempts.jsonl"
printf '%s\n' "$NEW_ENVELOPE" > "$LORE_KNOWLEDGE_DIR/_work/stub-item/verdicts/task-claims.jsonl"
OUT=$(bash "$MERGE" stub-item)
assert_contains "reattempt rows all deduped" "$OUT" "audit-reattempts.jsonl: +0 rows (2 duplicates skipped)"
assert_contains "envelope rows all deduped" "$OUT" "verdicts/task-claims.jsonl: +0 rows (1 duplicates skipped)"
assert_eq "reattempt count unchanged" "$(wc -l < "$ARCH/audit-reattempts.jsonl" | tr -d ' ')" "2"
assert_eq "envelope count unchanged" "$(wc -l < "$ARCH/verdicts/task-claims.jsonl" | tr -d ' ')" "2"
assert_not_exists "recreated stub removed again" "$LORE_KNOWLEDGE_DIR/_work/stub-item"

# ============================================================
echo "Test: non-JSONL files move; identical copies are discarded"
# ============================================================
fresh_store t2
make_archive_item stub-item
mkdir -p "$LORE_KNOWLEDGE_DIR/_work/stub-item"
echo "stray scratch content" > "$LORE_KNOWLEDGE_DIR/_work/stub-item/scratch.txt"
echo "archive evidence body" > "$LORE_KNOWLEDGE_DIR/_work/stub-item/evidence.md"
OUT=$(bash "$MERGE" stub-item)
assert_contains "new file moved" "$OUT" "scratch.txt: moved to archive"
assert_eq "moved file content intact" "$(cat "$LORE_KNOWLEDGE_DIR/_work/_archive/stub-item/scratch.txt")" "stray scratch content"
assert_not_exists "stub removed after move" "$LORE_KNOWLEDGE_DIR/_work/stub-item"

# ============================================================
echo "Test: content collision aborts before any mutation"
# ============================================================
fresh_store t3
make_archive_item stub-item
mkdir -p "$LORE_KNOWLEDGE_DIR/_work/stub-item"
echo "DIFFERENT evidence body" > "$LORE_KNOWLEDGE_DIR/_work/stub-item/evidence.md"
printf '%s\n' "$NEW_ROW" > "$LORE_KNOWLEDGE_DIR/_work/stub-item/audit-reattempts.jsonl"
RC=0
ERR=$(bash "$MERGE" stub-item 2>&1 >/dev/null) || RC=$?
assert_eq "collision exits 1" "$RC" "1"
assert_contains "collision names the file" "$ERR" "'evidence.md' exists in both"
assert_exists "stub left intact" "$LORE_KNOWLEDGE_DIR/_work/stub-item/evidence.md"
assert_eq "no rows were merged before abort" "$(wc -l < "$LORE_KNOWLEDGE_DIR/_work/_archive/stub-item/audit-reattempts.jsonl" | tr -d ' ')" "1"
assert_eq "archive file unchanged" "$(cat "$LORE_KNOWLEDGE_DIR/_work/_archive/stub-item/evidence.md")" "archive evidence body"

# ============================================================
echo "Test: refusal shapes"
# ============================================================
fresh_store t4
mkdir -p "$LORE_KNOWLEDGE_DIR/_work/no-archive-sibling"
RC=0
bash "$MERGE" no-archive-sibling >/dev/null 2>&1 || RC=$?
assert_eq "no archive sibling refused" "$RC" "1"

make_archive_item real-item
mkdir -p "$LORE_KNOWLEDGE_DIR/_work/real-item"
cat > "$LORE_KNOWLEDGE_DIR/_work/real-item/_meta.json" <<EOF
{"slug":"real-item","title":"Real Item","status":"active","project":"proj-x","created":"2026-01-01T00:00:00Z","updated":"2026-03-01T00:00:00Z","intent_anchor":"live work"}
EOF
RC=0
bash "$MERGE" --check real-item >/dev/null 2>&1 || RC=$?
assert_eq "--check exits 2 on real _meta.json" "$RC" "2"
RC=0
bash "$MERGE" real-item >/dev/null 2>&1 || RC=$?
assert_eq "merge refuses real _meta.json" "$RC" "2"
assert_exists "real item untouched" "$LORE_KNOWLEDGE_DIR/_work/real-item/_meta.json"

RC=0
bash "$MERGE" _archive >/dev/null 2>&1 || RC=$?
assert_eq "underscore slug refused" "$RC" "1"

fresh_store t5
make_archive_item check-item
mkdir -p "$LORE_KNOWLEDGE_DIR/_work/check-item"
printf '%s\n' "$NEW_ROW" > "$LORE_KNOWLEDGE_DIR/_work/check-item/audit-reattempts.jsonl"
OUT=$(bash "$MERGE" --check check-item)
RC=$?
assert_eq "--check exits 0 on mergeable residue" "$RC" "0"
assert_contains "--check reports eligibility" "$OUT" "mergeable residue"
assert_exists "--check does not mutate the stub" "$LORE_KNOWLEDGE_DIR/_work/check-item/audit-reattempts.jsonl"
assert_not_exists "--check does not write the index" "$LORE_KNOWLEDGE_DIR/_work/_index.json"

# ============================================================
echo "Test: heal routes archive-sibling orphans to the merge"
# ============================================================
fresh_store t6
make_archive_item stub-item
mkdir -p "$LORE_KNOWLEDGE_DIR/_work/stub-item"
printf '%s\n' "$NEW_ROW" > "$LORE_KNOWLEDGE_DIR/_work/stub-item/audit-reattempts.jsonl"
mkdir -p "$LORE_KNOWLEDGE_DIR/_work/plain-orphan"
echo "orphan artifact" > "$LORE_KNOWLEDGE_DIR/_work/plain-orphan/stray.md"

OUT=$(bash "$HEAL" "$LORE_KNOWLEDGE_DIR")
assert_contains "heal reports the merge" "$OUT" "Merged residue stub 'stub-item' into _archive/stub-item"
assert_not_exists "heal did not scaffold the residue stub" "$LORE_KNOWLEDGE_DIR/_work/stub-item"
assert_eq "residue row landed in archive" "$(grep -cxF "$NEW_ROW" "$LORE_KNOWLEDGE_DIR/_work/_archive/stub-item/audit-reattempts.jsonl")" "1"
assert_contains "orphan without archive sibling still scaffolds" "$OUT" "Created missing _meta.json for 'plain-orphan'"
assert_exists "scaffolded orphan _meta.json" "$LORE_KNOWLEDGE_DIR/_work/plain-orphan/_meta.json"

OUT=$(bash "$HEAL" "$LORE_KNOWLEDGE_DIR")
assert_contains "re-running heal finds nothing stub-related" "$OUT" "No issues found."

# ============================================================
echo "Test: heal merges a previously legitimized scaffold stub"
# ============================================================
fresh_store t7
make_archive_item stub-item
make_scaffold_stub stub-item
make_residue_files stub-item
OUT=$(bash "$HEAL" "$LORE_KNOWLEDGE_DIR")
assert_contains "heal merges scaffold-fingerprint stub" "$OUT" "Merged residue stub 'stub-item' into _archive/stub-item"
assert_not_exists "legitimized stub retired" "$LORE_KNOWLEDGE_DIR/_work/stub-item"

# ============================================================
echo "Test: heal surfaces an unmergeable stub as a warning"
# ============================================================
fresh_store t8
make_archive_item stub-item
mkdir -p "$LORE_KNOWLEDGE_DIR/_work/stub-item"
echo "DIFFERENT evidence body" > "$LORE_KNOWLEDGE_DIR/_work/stub-item/evidence.md"
OUT=$(bash "$HEAL" "$LORE_KNOWLEDGE_DIR")
assert_contains "heal reports merge failure" "$OUT" "Could not merge stub 'stub-item'"
assert_exists "conflicted stub left in place" "$LORE_KNOWLEDGE_DIR/_work/stub-item/evidence.md"
assert_not_exists "conflicted stub not scaffolded" "$LORE_KNOWLEDGE_DIR/_work/stub-item/_meta.json"

echo ""
echo "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0 ? 1 : 0))
