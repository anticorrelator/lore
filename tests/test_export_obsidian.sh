#!/usr/bin/env bash
# test_export_obsidian.sh — Tests for scripts/export-obsidian.sh.
#
# Builds a minimal synthetic knowledge store under a tempdir and exercises
# every Phase 1 verification bullet from the obsidian-vault-mirror-adapter
# plan, plus the refinement plan
# `refine-obsidian-mirror-folder-path-links-single-no` (D1–D6):
# folder-path link translation (D1), single consolidated _work/<slug>.md
# (D2), first-write-only .obsidian/graph.json seed (D3), dot-prefix
# exclusion under _threads/ (D4), --allow-collisions deprecation notice
# with collision check kept as a defensive trap (D6), plus marker gating,
# --init flow, full-export idempotence, deletion reconciliation,
# frontmatter variance (D8), folder-note synthesis (D5), year hubs (D6),
# thread export, CLI argument errors.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/export-obsidian.sh"
CLI="$REPO_ROOT/cli/lore"

TEST_DIR=$(mktemp -d)
KDIR="$TEST_DIR/kdir"
VAULT="$TEST_DIR/vault"
DATA="$TEST_DIR/lore_data"

PASS=0
FAIL=0

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

assert_pass() {
  local label="$1"
  echo "  PASS: $label"
  PASS=$((PASS + 1))
}
assert_fail() {
  local label="$1" detail="$2"
  echo "  FAIL: $label"
  if [[ -n "$detail" ]]; then
    echo "    $detail"
  fi
  FAIL=$((FAIL + 1))
}

assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    assert_pass "$label"
  else
    assert_fail "$label" "expected: $expected | got: $actual"
  fi
}

assert_file_exists() {
  local label="$1" filepath="$2"
  if [[ -f "$filepath" ]]; then
    assert_pass "$label"
  else
    assert_fail "$label" "file does not exist: $filepath"
  fi
}

assert_file_missing() {
  local label="$1" filepath="$2"
  if [[ ! -f "$filepath" ]]; then
    assert_pass "$label"
  else
    assert_fail "$label" "file should not exist: $filepath"
  fi
}

assert_file_contains() {
  local label="$1" filepath="$2" expected="$3"
  if [[ -f "$filepath" ]] && grep -qF -- "$expected" "$filepath"; then
    assert_pass "$label"
  else
    assert_fail "$label" "file: $filepath | expected to contain: $expected"
  fi
}

assert_file_not_contains() {
  local label="$1" filepath="$2" unexpected="$3"
  if [[ -f "$filepath" ]] && grep -qF -- "$unexpected" "$filepath"; then
    assert_fail "$label" "file: $filepath | should NOT contain: $unexpected"
  else
    assert_pass "$label"
  fi
}

assert_exit_nonzero() {
  local label="$1" rc="$2"
  if [[ "$rc" -ne 0 ]]; then
    assert_pass "$label"
  else
    assert_fail "$label" "expected non-zero exit, got $rc"
  fi
}

assert_exit_zero() {
  local label="$1" rc="$2"
  if [[ "$rc" -eq 0 ]]; then
    assert_pass "$label"
  else
    assert_fail "$label" "expected zero exit, got $rc"
  fi
}

run_export() {
  LORE_KNOWLEDGE_DIR="$KDIR" LORE_DATA_DIR="$DATA" bash "$SCRIPT" "$@"
}

# --- Setup synthetic knowledge store -----------------------------------

setup_kdir() {
  rm -rf "$KDIR" "$VAULT" "$DATA"
  mkdir -p "$KDIR"
  mkdir -p "$KDIR/conventions"
  mkdir -p "$KDIR/architecture"
  mkdir -p "$KDIR/principles"
  mkdir -p "$KDIR/_work/active-slug"
  mkdir -p "$KDIR/_work/_archive/old-slug"
  mkdir -p "$KDIR/_work/_archive/older-slug"
  mkdir -p "$KDIR/_threads/topic-one"
  mkdir -p "$KDIR/_threads/topic-two"
  # Dot-prefix dir under _threads/ — must be skipped (D4).
  mkdir -p "$KDIR/_threads/.pre-migration-backup"

  # Knowledge entry with single scale, with double-comment footer (D8)
  cat > "$KDIR/conventions/single-scale.md" <<'EOF'
# Single Scale Entry
Body referencing [[knowledge:architecture/foo]] and [[work:active-slug]]
and bare [[plan]] and [[name|display]] and [[type:target]]
and [[plan:active-slug]] (legacy alias).

See also: [[knowledge:gotchas/whatever]]
<!-- source: renormalize-backlinks -->
<!-- learned: 2026-05-03 | confidence: high | source: manual | scale: subsystem | related_files: scripts/foo.sh,/abs/path/scripts/bar.sh -->
EOF

  # Knowledge entry with multi-value scale (D8) and unaudited confidence
  cat > "$KDIR/architecture/multi-scale.md" <<'EOF'
# Multi Scale Entry
Body that mentions [[knowledge:conventions/single-scale#Section]] heading.
<!-- learned: 2026-05-03 | confidence: unaudited | scale: architecture,subsystem | related_files: a.sh,b.sh -->
EOF

  # Sourced category index — should rename index.md → principles.md (D5)
  cat > "$KDIR/principles/index.md" <<'EOF'
# Principles Index

- [single-scale entry](../conventions/single-scale.md)
- [[knowledge:architecture/multi-scale]]
EOF

  # Active work item (D7)
  cat > "$KDIR/_work/active-slug/_meta.json" <<'EOF'
{"slug":"active-slug","title":"Active Slug","status":"active","branches":["main"],"tags":["a","b"],"created":"2026-05-01T00:00:00Z","updated":"2026-05-03T12:00:00Z","related_knowledge":[]}
EOF
  cat > "$KDIR/_work/active-slug/notes.md" <<'EOF'
notes content with [[work:other]] and [[knowledge:conventions/single-scale]].
EOF
  cat > "$KDIR/_work/active-slug/plan.md" <<'EOF'
plan content
EOF
  cat > "$KDIR/_work/active-slug/execution-log.md" <<'EOF'
log content
EOF
  cat > "$KDIR/_work/active-slug/evidence.md" <<'EOF'
evidence content
EOF
  # Files that must NOT be mirrored (D7)
  cat > "$KDIR/_work/active-slug/tasks.json" <<'EOF'
{"tasks":[{"id":"1","subject":"x"}]}
EOF
  cat > "$KDIR/_work/active-slug/task-claims.jsonl" <<'EOF'
{"claim_id":"x"}
EOF

  # Archive items in different years (D6)
  cat > "$KDIR/_work/_archive/old-slug/_meta.json" <<'EOF'
{"slug":"old-slug","title":"Old 2026 Slug","status":"archived","branches":[],"tags":[],"created":"2026-01-15T00:00:00Z","updated":"2026-02-15T00:00:00Z"}
EOF
  cat > "$KDIR/_work/_archive/old-slug/notes.md" <<'EOF'
old archived notes
EOF
  cat > "$KDIR/_work/_archive/older-slug/_meta.json" <<'EOF'
{"slug":"older-slug","title":"Older 2025 Slug","status":"archived","branches":[],"tags":[],"created":"2025-11-01T00:00:00Z","updated":"2025-12-01T00:00:00Z"}
EOF
  cat > "$KDIR/_work/_archive/older-slug/notes.md" <<'EOF'
older archived notes
EOF

  # Threads (Open Question 4 — in scope)
  cat > "$KDIR/_threads/topic-one/_meta.json" <<'EOF'
{"topic":"Topic One","tier":"pinned","created":"2026-01-01T00:00:00Z","updated":"2026-03-01T00:00:00Z","sessions":3}
EOF
  cat > "$KDIR/_threads/topic-one/2026-01-01.md" <<'EOF'
**Summary:** thread one body. References [[work:active-slug]] and [[knowledge:conventions/single-scale]].
EOF
  cat > "$KDIR/_threads/topic-one/2026-02-01.md" <<'EOF'
**Summary:** another entry in topic one.
EOF
  cat > "$KDIR/_threads/topic-two/_meta.json" <<'EOF'
{"topic":"Topic Two","tier":"casual","created":"2026-02-01T00:00:00Z","updated":"2026-03-01T00:00:00Z","sessions":1}
EOF
  cat > "$KDIR/_threads/topic-two/2026-02-15.md" <<'EOF'
**Summary:** topic two body.
EOF
  cat > "$KDIR/_threads/.pre-migration-backup/_meta.json" <<'EOF'
{"topic":"Pre-Migration Backup","tier":"casual","created":"2025-01-01T00:00:00Z","updated":"2025-01-01T00:00:00Z","sessions":0}
EOF
  cat > "$KDIR/_threads/.pre-migration-backup/legacy.md" <<'EOF'
**Summary:** legacy thread that should not be mirrored.
EOF
}

# --- Setup git so resolve-repo.sh doesn't clobber LORE_KNOWLEDGE_DIR ----
# We rely on LORE_KNOWLEDGE_DIR; resolve-repo.sh respects it.

echo "=== export-obsidian.sh tests ==="
echo ""

# =======================================================================
# Test group 1: CLI argument errors and help
# =======================================================================
echo "Test 1: CLI argument handling"

OUT=$(bash "$SCRIPT" --help 2>&1)
RC=$?
assert_exit_zero "  --help exits 0" "$RC"
[[ "$OUT" == *"export-obsidian.sh"* ]] && assert_pass "  --help prints usage" || assert_fail "  --help prints usage" "got: $OUT"

OUT=$(bash "$SCRIPT" --bogus 2>&1) ; RC=$?
assert_exit_nonzero "  unknown flag exits non-zero" "$RC"
[[ "$OUT" == *"unknown flag"* ]] && assert_pass "  unknown flag prints diagnostic" || assert_fail "  unknown flag prints diagnostic" "got: $OUT"

OUT=$(bash "$SCRIPT" 2>&1) ; RC=$?
assert_exit_nonzero "  missing mode exits non-zero" "$RC"
[[ "$OUT" == *"mode flag is required"* ]] && assert_pass "  missing mode prints diagnostic" || assert_fail "  missing mode prints diagnostic" "got: $OUT"

OUT=$(bash "$SCRIPT" --init 2>&1) ; RC=$?
assert_exit_nonzero "  --init without path exits non-zero" "$RC"

OUT=$(bash "$SCRIPT" --file 2>&1) ; RC=$?
assert_exit_nonzero "  --file without path exits non-zero" "$RC"

OUT=$(bash "$SCRIPT" /tmp/x /tmp/y --full 2>&1) ; RC=$?
assert_exit_nonzero "  two positionals exits non-zero" "$RC"

# =======================================================================
# Test group 2: --init writes config + marker, runs first --full
# =======================================================================
echo ""
echo "Test 2: --init flow"
setup_kdir

OUT=$(run_export --init "$VAULT" 2>&1) ; RC=$?
assert_exit_zero "  --init exits 0" "$RC"
assert_file_exists "  config file created" "$DATA/config/obsidian.json"
assert_file_exists "  marker file created" "$VAULT/.lore-obsidian-mirror.json"
assert_file_contains "  config has vault_path" "$DATA/config/obsidian.json" "$VAULT"
assert_file_contains "  config has repo_path" "$DATA/config/obsidian.json" "$KDIR"
assert_file_contains "  marker has repo_path" "$VAULT/.lore-obsidian-mirror.json" "$KDIR"
assert_file_contains "  marker has schema_version" "$VAULT/.lore-obsidian-mirror.json" '"schema_version": 1'
# --init falls through to a full export
assert_file_exists "  --init triggered full export (knowledge entry)" "$VAULT/conventions/single-scale.md"
assert_file_exists "  --init triggered full export (work hub)" "$VAULT/_work.md"
# D2: single consolidated work file (no per-slug subdir).
assert_file_exists "  --init triggered full export (consolidated work file)" "$VAULT/_work/active-slug.md"
# D3: graph.json seeded on first --init when absent.
assert_file_exists "  --init seeded .obsidian/graph.json" "$VAULT/.obsidian/graph.json"
assert_file_contains "  graph.json contains _work/ filter" "$VAULT/.obsidian/graph.json" "_work/"
assert_file_contains "  graph.json contains _threads/ filter" "$VAULT/.obsidian/graph.json" "_threads/"

# D3: re-running --init on a vault with a hand-modified graph.json does NOT
# overwrite the user-customized file.
echo '{"theme":"custom","search":"user-edit"}' > "$VAULT/.obsidian/graph.json"
PRE_BYTES=$(shasum "$VAULT/.obsidian/graph.json" | awk '{print $1}')
run_export --init "$VAULT" >/dev/null 2>&1
POST_BYTES=$(shasum "$VAULT/.obsidian/graph.json" | awk '{print $1}')
assert_eq "  --init re-run preserves modified graph.json" "$POST_BYTES" "$PRE_BYTES"
assert_file_contains "  modified graph.json kept user search" "$VAULT/.obsidian/graph.json" "user-edit"

# =======================================================================
# Test group 3: knowledge entry conversion (D8 variance)
# =======================================================================
echo ""
echo "Test 3: frontmatter and link conversion (D8, D1)"
ENTRY="$VAULT/conventions/single-scale.md"
assert_file_contains "  frontmatter learned field" "$ENTRY" "learned: 2026-05-03"
assert_file_contains "  frontmatter confidence high" "$ENTRY" "confidence: high"
assert_file_contains "  scale rendered as YAML list" "$ENTRY" "scale: [subsystem]"
assert_file_contains "  related_files absolute path stripped" "$ENTRY" "bar.sh"
assert_file_not_contains "  related_files no abs path" "$ENTRY" "/abs/path/scripts/bar.sh"
assert_file_contains "  lore_managed flag" "$ENTRY" "lore_managed: true"
# Link translation (D1: folder-path under parent prefix)
assert_file_contains "  knowledge: rewritten to folder-path" "$ENTRY" "[[architecture/foo]]"
assert_file_contains "  work: rewritten to _work/<slug>" "$ENTRY" "[[_work/active-slug]]"
assert_file_contains "  plan: legacy alias rewritten to _work/<slug>" "$ENTRY" "[[_work/active-slug]]"
assert_file_contains "  bare wikilink passes through" "$ENTRY" "[[plan]]"
assert_file_contains "  display alias passes through" "$ENTRY" "[[name|display]]"
assert_file_contains "  unknown scheme passes through" "$ENTRY" "[[type:target]]"
assert_file_not_contains "  no [[knowledge:]] in body" "$ENTRY" "[[knowledge:"
assert_file_not_contains "  no [[work:]] in body" "$ENTRY" "[[work:"
assert_file_not_contains "  no [[plan:]] in body" "$ENTRY" "[[plan:"
# D1: source [[foo]] basename-collapsed link MUST NOT appear (legacy shape).
assert_file_not_contains "  no legacy [[foo]] basename link" "$ENTRY" "[[foo]]"
# Footer comment is stripped
assert_file_not_contains "  HTML footer comment removed from body" "$ENTRY" "<!-- learned:"
assert_file_not_contains "  renormalize-backlinks comment removed" "$ENTRY" "renormalize-backlinks"
# See-also lines removed
assert_file_not_contains "  See also: lines removed" "$ENTRY" "See also:"

# Multi-scale + unaudited
M="$VAULT/architecture/multi-scale.md"
assert_file_exists "  multi-scale entry written" "$M"
assert_file_contains "  multi-scale yields list" "$M" "scale: [architecture, subsystem]"
assert_file_contains "  unaudited confidence permitted" "$M" "confidence: unaudited"
# Heading-fragment link translation (D1: folder-path with anchor preserved)
assert_file_contains "  heading fragment preserved" "$M" "[[conventions/single-scale#Section]]"

# =======================================================================
# Test group 4: folder-note synthesis (D5)
# =======================================================================
echo ""
echo "Test 4: folder-note synthesis (D5, D1)"
# principles/ has index.md → expect principles.md (renamed)
assert_file_exists "  sourced index.md → <dirname>.md" "$VAULT/principles/principles.md"
# conventions/ has no index.md → expect synthesized conventions.md
assert_file_exists "  unsourced category synthesizes folder note" "$VAULT/conventions/conventions.md"
assert_file_contains "  synthesized note flagged" "$VAULT/conventions/conventions.md" "synthesized: true"
# D1: folder note lists entries with folder-path wikilinks, not bare basenames.
assert_file_contains "  synthesized note lists entries with folder path" "$VAULT/conventions/conventions.md" "[[conventions/single-scale]]"
assert_file_not_contains "  no legacy bare-basename entry link" "$VAULT/conventions/conventions.md" "- [[single-scale]]"

# =======================================================================
# Test group 5: work item conversion (D2 — single consolidated file)
# =======================================================================
echo ""
echo "Test 5: consolidated work item (D2)"
# D2: one file per work item at _work/<slug>.md; no <slug>/ subdir.
WORK_FILE="$VAULT/_work/active-slug.md"
assert_file_exists "  consolidated work file" "$WORK_FILE"
assert_file_missing "  no per-slug subdir folder note" "$VAULT/_work/active-slug/active-slug.md"
assert_file_missing "  notes.md sibling does NOT exist (D2)" "$VAULT/_work/active-slug/notes.md"
assert_file_missing "  plan.md sibling does NOT exist (D2)" "$VAULT/_work/active-slug/plan.md"
assert_file_missing "  execution-log.md sibling does NOT exist (D2)" "$VAULT/_work/active-slug/execution-log.md"
assert_file_missing "  evidence.md sibling does NOT exist (D2)" "$VAULT/_work/active-slug/evidence.md"
# Frontmatter hoisted from _meta.json.
assert_file_contains "  consolidated file has title" "$WORK_FILE" "title: Active Slug"
assert_file_contains "  consolidated file has slug" "$WORK_FILE" "slug: active-slug"
assert_file_contains "  consolidated file has status" "$WORK_FILE" "status: active"
assert_file_contains "  consolidated file lore_managed" "$WORK_FILE" "lore_managed: true"
# H2 sections in plan → notes → execution-log → evidence order (D2).
assert_file_contains "  consolidated file has Plan H2" "$WORK_FILE" "## Plan"
assert_file_contains "  consolidated file has Notes H2" "$WORK_FILE" "## Notes"
assert_file_contains "  consolidated file has Execution log H2" "$WORK_FILE" "## Execution log"
assert_file_contains "  consolidated file has Evidence H2" "$WORK_FILE" "## Evidence"
SECTION_ORDER=$(grep -n '^## ' "$WORK_FILE" | awk -F: '{print $2}' | tr '\n' '|')
assert_eq "  H2 section order: plan→notes→execution-log→evidence" "$SECTION_ORDER" "## Plan|## Notes|## Execution log|## Evidence|"
# Inner sidecar content present.
assert_file_contains "  Plan section body present" "$WORK_FILE" "plan content"
assert_file_contains "  Notes section body present" "$WORK_FILE" "notes content"
assert_file_contains "  Execution log section body present" "$WORK_FILE" "log content"
assert_file_contains "  Evidence section body present" "$WORK_FILE" "evidence content"
# Link translation inside the consolidated body (D1: work: → _work/<slug>; knowledge: → folder-path).
assert_file_contains "  body has translated work link" "$WORK_FILE" "[[_work/other]]"
assert_file_contains "  body has translated knowledge link" "$WORK_FILE" "[[conventions/single-scale]]"
assert_file_not_contains "  body has no [[work:]]" "$WORK_FILE" "[[work:"
assert_file_not_contains "  body has no [[knowledge:]]" "$WORK_FILE" "[[knowledge:"
# Non-mirrored sources still excluded.
assert_file_missing "  tasks.json NOT mirrored" "$VAULT/_work/active-slug/tasks.json"
assert_file_missing "  task-claims.jsonl NOT mirrored" "$VAULT/_work/active-slug/task-claims.jsonl"
assert_file_missing "  _meta.json NOT mirrored as file" "$VAULT/_work/active-slug/_meta.json"

# Empty H2 elision: an active item with only plan.md must produce only ## Plan.
mkdir -p "$KDIR/_work/plan-only-slug"
cat > "$KDIR/_work/plan-only-slug/_meta.json" <<'EOF'
{"slug":"plan-only-slug","title":"Plan Only","status":"active","branches":[],"tags":[],"created":"2026-05-03T00:00:00Z","updated":"2026-05-03T00:00:00Z"}
EOF
cat > "$KDIR/_work/plan-only-slug/plan.md" <<'EOF'
plan only.
EOF
run_export "$VAULT" --full >/dev/null 2>&1
PLAN_ONLY="$VAULT/_work/plan-only-slug.md"
assert_file_exists "  plan-only consolidated file" "$PLAN_ONLY"
assert_file_contains "  plan-only has ## Plan" "$PLAN_ONLY" "## Plan"
assert_file_not_contains "  plan-only has no ## Notes" "$PLAN_ONLY" "## Notes"
assert_file_not_contains "  plan-only has no ## Execution log" "$PLAN_ONLY" "## Execution log"
assert_file_not_contains "  plan-only has no ## Evidence" "$PLAN_ONLY" "## Evidence"
rm -rf "$KDIR/_work/plan-only-slug"
run_export "$VAULT" --full >/dev/null 2>&1

# =======================================================================
# Test group 6: archive year hubs (D6)
# =======================================================================
echo ""
echo "Test 6: year hubs and archive hub (D6, D1)"
assert_file_exists "  year hub 2026.md" "$VAULT/_work/_archive/2026.md"
assert_file_exists "  year hub 2025.md" "$VAULT/_work/_archive/2025.md"
assert_file_exists "  top-level archive hub" "$VAULT/_work/_archive/_archive.md"
# D1: hub links use folder-path under _work/_archive/.
assert_file_contains "  2026 hub lists old-slug" "$VAULT/_work/_archive/2026.md" "[[_work/_archive/old-slug]]"
assert_file_contains "  2025 hub lists older-slug" "$VAULT/_work/_archive/2025.md" "[[_work/_archive/older-slug]]"
assert_file_contains "  archive hub links year buckets" "$VAULT/_work/_archive/_archive.md" "[[_work/_archive/2026]]"
assert_file_contains "  archive hub links 2025" "$VAULT/_work/_archive/_archive.md" "[[_work/_archive/2025]]"

# =======================================================================
# Test group 7: thread export
# =======================================================================
echo ""
echo "Test 7: thread folder notes + bodies (D1, D4)"
TD="$VAULT/_threads/topic-one"
assert_file_exists "  thread folder note synthesized" "$TD/topic-one.md"
assert_file_exists "  thread body 2026-01-01.md mirrored" "$TD/2026-01-01.md"
assert_file_exists "  thread body 2026-02-01.md mirrored" "$TD/2026-02-01.md"
assert_file_contains "  thread folder note has topic" "$TD/topic-one.md" "topic: Topic One"
# D1: folder note links body under folder-path `_threads/<topic>/<entry>`.
assert_file_contains "  thread folder note links body (folder-path)" "$TD/topic-one.md" "[[_threads/topic-one/2026-01-01]]"
# D1: bodies translate work: → _work/<slug>, knowledge: → folder-path.
assert_file_contains "  thread body link translated work (D1)" "$TD/2026-01-01.md" "[[_work/active-slug]]"
assert_file_contains "  thread body link translated knowledge (D1)" "$TD/2026-01-01.md" "[[conventions/single-scale]]"
assert_file_not_contains "  thread body no [[work:]] left" "$TD/2026-01-01.md" "[[work:"
assert_file_not_contains "  thread body no [[knowledge:]] left" "$TD/2026-01-01.md" "[[knowledge:"

# D4: dot-prefix directories under _threads/ are excluded entirely.
assert_file_missing "  .pre-migration-backup/ folder note NOT mirrored" "$VAULT/_threads/.pre-migration-backup/.pre-migration-backup.md"
[[ ! -d "$VAULT/_threads/.pre-migration-backup" ]] && assert_pass "  .pre-migration-backup/ dir NOT created in vault" || assert_fail "  .pre-migration-backup/ dir NOT created in vault" "dir exists at $VAULT/_threads/.pre-migration-backup"
assert_file_missing "  .pre-migration-backup/ legacy body NOT mirrored" "$VAULT/_threads/.pre-migration-backup/legacy.md"

# =======================================================================
# Test group 8: idempotence
# =======================================================================
echo ""
echo "Test 8: full-export idempotence (stateless)"
HASH1=$(find "$VAULT" -type f -name '*.md' -exec sha256sum {} \; | sort | sha256sum)
run_export "$VAULT" --full >/dev/null 2>&1
HASH2=$(find "$VAULT" -type f -name '*.md' -exec sha256sum {} \; | sort | sha256sum)
[[ "$HASH1" == "$HASH2" ]] && assert_pass "  byte-identical second run" || assert_fail "  idempotence" "hashes differ"

# =======================================================================
# Test group 9: deletion reconciliation
# =======================================================================
echo ""
echo "Test 9: deletion reconciliation (D10)"
# Source removed → vault file removed on next --full
rm "$KDIR/architecture/multi-scale.md"
run_export "$VAULT" --full >/dev/null 2>&1
assert_file_missing "  vault file deleted after source removal" "$VAULT/architecture/multi-scale.md"

# Restore for next tests
cat > "$KDIR/architecture/multi-scale.md" <<'EOF'
# Multi Scale Entry
Body.
<!-- learned: 2026-05-03 | confidence: high | scale: architecture,subsystem -->
EOF
run_export "$VAULT" --full >/dev/null 2>&1
assert_file_exists "  vault file restored after source recreated" "$VAULT/architecture/multi-scale.md"

# =======================================================================
# Test group 10: marker / config gating
# =======================================================================
echo ""
echo "Test 10: marker and config gating (D11)"

# A vault with no marker — explicit path
NO_MARKER="$TEST_DIR/no-marker-vault"
mkdir -p "$NO_MARKER"
OUT=$(run_export "$NO_MARKER" --full 2>&1) ; RC=$?
assert_exit_nonzero "  --full on uninitialized vault exits non-zero" "$RC"
[[ "$OUT" == *"vault not initialized"* ]] && assert_pass "  diagnostic mentions vault not initialized" || assert_fail "  diagnostic mentions vault not initialized" "got: $OUT"
# No content written
COUNT=$(find "$NO_MARKER" -type f | wc -l | tr -d ' ')
assert_eq "  no files written to uninitialized vault" "$COUNT" "0"

# Marker repo mismatch
MISMATCH="$TEST_DIR/mismatch-vault"
mkdir -p "$MISMATCH"
cat > "$MISMATCH/.lore-obsidian-mirror.json" <<'EOF'
{"schema_version":1,"initialized_at":"2026-05-03T00:00:00Z","repo_path":"/some/other/repo","mirror_ignore":[]}
EOF
OUT=$(run_export "$MISMATCH" --full 2>&1) ; RC=$?
assert_exit_nonzero "  marker mismatch exits non-zero" "$RC"
[[ "$OUT" == *"different repo"* ]] && assert_pass "  diagnostic mentions different repo" || assert_fail "  diagnostic mentions different repo" "got: $OUT"

# --file with no config: silent no-op
NO_CFG_DATA="$TEST_DIR/no-cfg-data"
RC=0
LORE_KNOWLEDGE_DIR="$KDIR" LORE_DATA_DIR="$NO_CFG_DATA" bash "$SCRIPT" --file "$KDIR/conventions/single-scale.md" 2>&1 || RC=$?
assert_exit_zero "  --file with no config is silent no-op (exit 0)" "$RC"

# --work-hubs with no config: silent no-op
RC=0
LORE_KNOWLEDGE_DIR="$KDIR" LORE_DATA_DIR="$NO_CFG_DATA" bash "$SCRIPT" --work-hubs 2>&1 || RC=$?
assert_exit_zero "  --work-hubs with no config is silent no-op (exit 0)" "$RC"

# --full with no config and no positional: error
RC=0
LORE_KNOWLEDGE_DIR="$KDIR" LORE_DATA_DIR="$NO_CFG_DATA" bash "$SCRIPT" --full 2>&1 >/dev/null || RC=$?
assert_exit_nonzero "  --full with no config and no positional exits non-zero" "$RC"

# =======================================================================
# Test group 11: .obsidian/ and marker preserved
# =======================================================================
echo ""
echo "Test 11: .obsidian/ and marker preserved across --full"
mkdir -p "$VAULT/.obsidian"
echo '{"theme":"dark"}' > "$VAULT/.obsidian/app.json"
run_export "$VAULT" --full >/dev/null 2>&1
assert_file_exists "  .obsidian/app.json untouched" "$VAULT/.obsidian/app.json"
assert_file_exists "  marker file untouched" "$VAULT/.lore-obsidian-mirror.json"

# =======================================================================
# Test group 12: --file mode (per-file projection)
# =======================================================================
echo ""
echo "Test 12: --file mode"
# Add a fresh knowledge entry, then --file it explicitly
cat > "$KDIR/conventions/fresh-entry.md" <<'EOF'
# Fresh Entry
Body.
<!-- learned: 2026-05-03 | confidence: high | scale: subsystem -->
EOF
# Need explicit vault since --file reads config
LORE_KNOWLEDGE_DIR="$KDIR" LORE_DATA_DIR="$DATA" bash "$SCRIPT" --file "$KDIR/conventions/fresh-entry.md" >/dev/null 2>&1
assert_file_exists "  --file projected new entry" "$VAULT/conventions/fresh-entry.md"

# Delete source then --file: vault file should be removed
rm "$KDIR/conventions/fresh-entry.md"
LORE_KNOWLEDGE_DIR="$KDIR" LORE_DATA_DIR="$DATA" bash "$SCRIPT" --file "$KDIR/conventions/fresh-entry.md" >/dev/null 2>&1
assert_file_missing "  --file removed deleted source" "$VAULT/conventions/fresh-entry.md"

# =======================================================================
# Test group 13: collision check defensive trap + --allow-collisions
# deprecation notice (D6)
# =======================================================================
echo ""
echo "Test 13: collision defensive trap + --allow-collisions deprecation (D6)"

# Under D1 folder-path translation, two source paths cannot resolve to the
# same vault path by construction. A bare --full on the synthetic corpus
# must therefore exit 0 cleanly with no collision warnings on stderr.
OUT=$(run_export "$VAULT" --full 2>&1) ; RC=$?
assert_exit_zero "  --full exits 0 with no collisions" "$RC"
[[ "$OUT" != *"vault path collisions"* ]] && assert_pass "  no collision warnings under folder-path links" || assert_fail "  no collision warnings under folder-path links" "got: $OUT"

# --allow-collisions is a deprecated no-op: the run must still exit 0 and
# the deprecation notice must appear on stderr.
OUT=$(run_export "$VAULT" --full --allow-collisions 2>&1) ; RC=$?
assert_exit_zero "  --full --allow-collisions exits 0 (no-op)" "$RC"
[[ "$OUT" == *"--allow-collisions is now a no-op"* ]] && assert_pass "  --allow-collisions emits deprecation notice" || assert_fail "  --allow-collisions emits deprecation notice" "got: $OUT"
[[ "$OUT" == *"will be removed in a future release"* ]] && assert_pass "  deprecation notice mentions future removal" || assert_fail "  deprecation notice mentions future removal" "got: $OUT"

# =======================================================================
# Test group 14: CLI integration (cli/lore export-obsidian)
# =======================================================================
echo ""
echo "Test 14: CLI surface integration"
OUT=$(LORE_KNOWLEDGE_DIR="$KDIR" LORE_DATA_DIR="$DATA" bash "$CLI" export-obsidian --help 2>&1) ; RC=$?
assert_exit_zero "  lore export-obsidian --help exits 0" "$RC"
[[ "$OUT" == *"export-obsidian.sh"* ]] && assert_pass "  CLI delegates to script for --help" || assert_fail "  CLI delegates to script for --help" "got: $OUT"

OUT=$(LORE_KNOWLEDGE_DIR="$KDIR" LORE_DATA_DIR="$DATA" bash "$CLI" export-obsidian --bogus 2>&1) ; RC=$?
assert_exit_nonzero "  unknown flag through CLI exits non-zero" "$RC"

# Top-level usage mentions export-obsidian
OUT=$(LORE_KNOWLEDGE_DIR="$KDIR" LORE_DATA_DIR="$DATA" bash "$CLI" --help 2>&1)
[[ "$OUT" == *"export-obsidian"* ]] && assert_pass "  top-level usage lists export-obsidian" || assert_fail "  top-level usage lists export-obsidian" "got first line: $(echo "$OUT" | head -1)"

# =======================================================================
echo ""
echo "=== Summary ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
