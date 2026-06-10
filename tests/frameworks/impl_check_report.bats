#!/usr/bin/env bats
# impl_check_report.bats — Coverage for `lore impl check-report` (impl-check-report.sh)
#
# Asserts:
#   - --task, --report, --phase are required; report file must exist;
#     --provider-status enum-validated; --spawned-advisors needs --provider-status
#   - tri-state reference resolution passthrough (1 no-match, 2 ambiguous)
#   - Tier 2 cross-reference checks the canonical task-claims.jsonl, not the
#     report's self-assertion: missing claim_ids -> mechanical_pass=false,
#     exit 3, missing ids named; all-present -> pass; `none` -> pass;
#     missing section -> fail
#   - required-consultation acknowledgement: phase brief domains matched
#     against report Consultations entries + transcript records; unsatisfied
#     domains block; required domains without --transcript exit 1
#   - convention-handling completeness is non-blocking: findings surfaced,
#     mechanical_pass unaffected; no --woven-norm -> loud skipped status
#   - fabrication guard: handler: agent entries need --provider-status;
#     verified entries roll up to scorecard rows; unverified entries are
#     stripped and logged `fabrication-guard: skipped <id>`; provider
#     unavailable withholds the rollup; handler: lead entries bypass
#   - one execution-log entry with source impl-verb on pass AND on mechanical
#     fail; --json output shape with explicit exit 0/3
#
# All tests use an isolated knowledge directory via LORE_KNOWLEDGE_DIR.

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"
LORE_CLI="$REPO_DIR/cli/lore"
CHECK_SH="$REPO_DIR/scripts/impl-check-report.sh"

setup() {
  [ -x "$LORE_CLI" ] || skip "cli/lore missing"
  [ -f "$CHECK_SH" ] || skip "impl-check-report.sh missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 required"
  command -v jq >/dev/null 2>&1 || skip "jq required for scorecard-append.sh"

  TEST_KDIR="$(mktemp -d)"
  export LORE_KNOWLEDGE_DIR="$TEST_KDIR"

  WORK_DIR="$TEST_KDIR/_work"
  ITEM_DIR="$WORK_DIR/report-item"
  mkdir -p "$ITEM_DIR"

  python3 - "$ITEM_DIR/_meta.json" <<'PYEOF'
import json, sys
meta = {"slug": "report-item", "title": "Report Item", "status": "active",
        "intent_anchor": "Reports get verified.",
        "created": "2026-06-01T00:00:00Z", "updated": "2026-06-01T00:00:00Z"}
with open(sys.argv[1], "w") as f:
    json.dump(meta, f, indent=2)
PYEOF
  echo "notes" > "$ITEM_DIR/notes.md"

  printf '{"claim_id":"c1","task_id":"5"}\n{"claim_id":"c2","task_id":"5"}\n' \
    > "$ITEM_DIR/task-claims.jsonl"

  python3 - "$ITEM_DIR/tasks.json" <<'PYEOF'
import json, sys
tasks = {"phases": [
    {"phase_context": "**Phase 1 objective:** no consultations here.\n"},
    {"phase_context": "**Phase 2 objective:** consult first.\n\n"
                      "**Consultations required:** security\n"},
]}
with open(sys.argv[1], "w") as f:
    json.dump(tasks, f, indent=2)
PYEOF

  REPORT="$TEST_KDIR/report.md"
  TRANSCRIPT="$TEST_KDIR/transcript.jsonl"
}

teardown() {
  if [ -n "${TEST_KDIR:-}" ] && [ -d "$TEST_KDIR" ]; then
    rm -rf "$TEST_KDIR"
  fi
  unset LORE_KNOWLEDGE_DIR
}

write_basic_report() {
  cat > "$REPORT" <<'EOF'
**Task:** Do the thing
**Changes:**
- file: x
**Tier 2 evidence:**
c1
c2
**Convention handling:**
- honored: norm-a
**Surfaced concerns:** None
EOF
}

json_line() { echo "$output" | grep '^{'; }

log_file() { echo "$ITEM_DIR/execution-log.md"; }

rows_file() { echo "$TEST_KDIR/_scorecards/rows.jsonl"; }

# --- Required flags ----------------------------------------------------------

@test "missing --task exits 1 naming the flag" {
  write_basic_report
  run bash "$LORE_CLI" impl check-report report-item --report "$REPORT" --phase 1
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- "--task is required"
}

@test "missing --report exits 1 naming the flag" {
  run bash "$LORE_CLI" impl check-report report-item --task 5 --phase 1
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- "--report is required"
}

@test "missing --phase exits 1 naming the flag" {
  write_basic_report
  run bash "$LORE_CLI" impl check-report report-item --task 5 --report "$REPORT"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- "--phase is required"
}

@test "nonexistent report file exits 1" {
  run bash "$LORE_CLI" impl check-report report-item --task 5 \
    --report "$TEST_KDIR/no-such-report.md" --phase 1
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "report file not found"
}

@test "invalid --provider-status exits 1 listing the enum" {
  write_basic_report
  run bash "$LORE_CLI" impl check-report report-item --task 5 --report "$REPORT" \
    --phase 1 --provider-status degraded
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "full|partial|unavailable"
}

@test "--spawned-advisors without --provider-status exits 1" {
  write_basic_report
  run bash "$LORE_CLI" impl check-report report-item --task 5 --report "$REPORT" \
    --phase 1 --spawned-advisors "abcdef123456"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- "--spawned-advisors requires --provider-status"
}

@test "--provider-status unavailable rejects --spawned-advisors" {
  write_basic_report
  run bash "$LORE_CLI" impl check-report report-item --task 5 --report "$REPORT" \
    --phase 1 --provider-status unavailable --spawned-advisors "abcdef123456"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "does not take --spawned-advisors"
}

# --- Reference resolution ----------------------------------------------------

@test "unknown reference exits 1" {
  write_basic_report
  run bash "$LORE_CLI" impl check-report no-such-item-zzz --task 5 \
    --report "$REPORT" --phase 1
  [ "$status" -eq 1 ]
}

@test "ambiguous reference exits 2" {
  write_basic_report
  mkdir -p "$WORK_DIR/other-item"
  cat > "$WORK_DIR/_index.json" <<'EOF'
{
  "version": 1,
  "plans": [
    {"slug": "report-item", "title": "Report Item", "tags": ["shared-tag"], "branches": []},
    {"slug": "other-item", "title": "Other Item", "tags": ["shared-tag"], "branches": []}
  ],
  "archived": []
}
EOF
  run bash "$LORE_CLI" impl check-report shared-tag --task 5 \
    --report "$REPORT" --phase 1
  [ "$status" -eq 2 ]
}

# --- Tier 2 cross-reference --------------------------------------------------

@test "all reported claim_ids found passes with exit 0" {
  write_basic_report
  run bash "$LORE_CLI" impl check-report report-item --task 5 \
    --report "$REPORT" --phase 1 --woven-norm norm-a
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Mechanical pass: true"
}

@test "missing claim_id fails with exit 3 and names the id" {
  cat > "$REPORT" <<'EOF'
**Tier 2 evidence:**
c1
ghost-claim-9
**Convention handling:** `none in scope`
EOF
  run bash "$LORE_CLI" impl check-report report-item --task 5 \
    --report "$REPORT" --phase 1
  [ "$status" -eq 3 ]
  echo "$output" | grep -q "ghost-claim-9"
  echo "$output" | grep -q "Mechanical pass: false"
  echo "$output" | grep -q "MUST reject"
}

@test "Tier 2 evidence of none passes the cross-reference" {
  cat > "$REPORT" <<'EOF'
**Tier 2 evidence:** none
**Convention handling:** `none in scope`
EOF
  run bash "$LORE_CLI" impl check-report report-item --task 5 \
    --report "$REPORT" --phase 1
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "none-reported"
}

@test "report without a Tier 2 evidence section fails with exit 3" {
  cat > "$REPORT" <<'EOF'
**Task:** Did stuff
**Convention handling:** `none in scope`
EOF
  run bash "$LORE_CLI" impl check-report report-item --task 5 \
    --report "$REPORT" --phase 1
  [ "$status" -eq 3 ]
  echo "$output" | grep -q "Tier 2 evidence"
}

@test "missing claim_id in --json names it in findings with exit 3" {
  cat > "$REPORT" <<'EOF'
**Tier 2 evidence:**
ghost-claim-9
**Convention handling:** `none in scope`
EOF
  run bash "$LORE_CLI" impl check-report report-item --task 5 \
    --report "$REPORT" --phase 1 --json
  [ "$status" -eq 3 ]
  json_line | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
assert d["mechanical_pass"] is False
assert "ghost-claim-9" in d["findings"]["tier2"]["missing"]
assert d["slug"] == "report-item"
assert d["task_id"] == "5"
'
}

@test "passing report in --json carries mechanical_pass true with exit 0" {
  write_basic_report
  run bash "$LORE_CLI" impl check-report report-item --task 5 \
    --report "$REPORT" --phase 1 --woven-norm norm-a --json
  [ "$status" -eq 0 ]
  json_line | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
assert d["mechanical_pass"] is True
assert d["findings"]["tier2"]["status"] == "ok"
assert d["execution_log"] == "appended"
'
}

# --- Required-consultation acknowledgement ------------------------------------

write_consulted_report() {
  cat > "$REPORT" <<'EOF'
**Tier 2 evidence:**
c1
**Convention handling:** `none in scope`
**Consultations:**
- consultation_id: c-100
  handler: lead
  domain: security
  query_summary: how to validate
  advice_summary: validate at the boundary
  was_followed: true
EOF
}

@test "phase without required consultations reports not-required" {
  write_basic_report
  run bash "$LORE_CLI" impl check-report report-item --task 5 \
    --report "$REPORT" --phase 1
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Required consultations: not-required"
}

@test "required domain with acknowledged transcript record is satisfied" {
  write_consulted_report
  printf '{"consultation_id":"c-100","worker":"worker-5","domain":"security","handler":"lead","replied_at":"2026-06-10T00:00:00Z"}\n' \
    > "$TRANSCRIPT"
  run bash "$LORE_CLI" impl check-report report-item --task 5 \
    --report "$REPORT" --phase 2 --transcript "$TRANSCRIPT"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Required consultations: satisfied"
}

@test "required domain with no Consultations entry fails naming the domain" {
  cat > "$REPORT" <<'EOF'
**Tier 2 evidence:**
c1
**Convention handling:** `none in scope`
EOF
  printf '{"consultation_id":"c-100","worker":"worker-5","domain":"security","handler":"lead","replied_at":"2026-06-10T00:00:00Z"}\n' \
    > "$TRANSCRIPT"
  run bash "$LORE_CLI" impl check-report report-item --task 5 \
    --report "$REPORT" --phase 2 --transcript "$TRANSCRIPT"
  [ "$status" -eq 3 ]
  echo "$output" | grep -q "security"
  echo "$output" | grep -q "Mechanical pass: false"
}

@test "consultation_id absent from transcript fails the domain" {
  write_consulted_report
  printf '{"consultation_id":"c-999","worker":"worker-5","domain":"security","handler":"lead","replied_at":"2026-06-10T00:00:00Z"}\n' \
    > "$TRANSCRIPT"
  run bash "$LORE_CLI" impl check-report report-item --task 5 \
    --report "$REPORT" --phase 2 --transcript "$TRANSCRIPT"
  [ "$status" -eq 3 ]
  echo "$output" | grep -q "no acknowledged transcript record"
}

@test "required domains without --transcript exit 1 naming the flag" {
  write_consulted_report
  run bash "$LORE_CLI" impl check-report report-item --task 5 \
    --report "$REPORT" --phase 2
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- "--transcript"
}

# --- Convention-handling completeness (non-blocking) --------------------------

@test "missing woven norm is surfaced but does not block" {
  write_basic_report
  run bash "$LORE_CLI" impl check-report report-item --task 5 \
    --report "$REPORT" --phase 1 --woven-norm norm-a --woven-norm norm-b
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "missing: norm-b"
  echo "$output" | grep -q "Mechanical pass: true"
}

@test "unrecognized dispositioned label is surfaced" {
  cat > "$REPORT" <<'EOF'
**Tier 2 evidence:**
c1
**Convention handling:**
- honored: norm-a
- honored: never-woven-norm
EOF
  run bash "$LORE_CLI" impl check-report report-item --task 5 \
    --report "$REPORT" --phase 1 --woven-norm norm-a
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "unrecognized: never-woven-norm"
}

@test "none in scope with woven norms is a completeness finding" {
  cat > "$REPORT" <<'EOF'
**Tier 2 evidence:**
c1
**Convention handling:** `none in scope`
EOF
  run bash "$LORE_CLI" impl check-report report-item --task 5 \
    --report "$REPORT" --phase 1 --woven-norm norm-a
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "'none in scope' reported but woven norms exist"
}

@test "no --woven-norm flags yields a loud skipped status" {
  write_basic_report
  run bash "$LORE_CLI" impl check-report report-item --task 5 \
    --report "$REPORT" --phase 1
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Convention handling: skipped-no-woven-list"
}

@test "diverged entries are listed verbatim for the caller to assess" {
  cat > "$REPORT" <<'EOF'
**Tier 2 evidence:**
c1
**Convention handling:**
- diverged: norm-a — the norm assumes a queue this change does not have
EOF
  run bash "$LORE_CLI" impl check-report report-item --task 5 \
    --report "$REPORT" --phase 1 --woven-norm norm-a
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "diverged: norm-a"
  echo "$output" | grep -q "the norm assumes a queue"
}

# --- Fabrication guard + advisor rollup ---------------------------------------

write_agent_report() {
  cat > "$REPORT" <<'EOF'
**Tier 2 evidence:**
c1
**Convention handling:** `none in scope`
**Consultations:**
- consultation_id: c-200
  handler: agent
  domain: security
  advisor_template_version: abcdef123456
  query_summary: is this safe
  advice_summary: yes with validation
  was_followed: true
EOF
}

@test "agent consultations without --provider-status exit 1" {
  write_agent_report
  run bash "$LORE_CLI" impl check-report report-item --task 5 \
    --report "$REPORT" --phase 1
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- "--provider-status"
}

@test "provider full requires --spawned-advisors" {
  write_agent_report
  run bash "$LORE_CLI" impl check-report report-item --task 5 \
    --report "$REPORT" --phase 1 --provider-status full
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- "requires --spawned-advisors"
}

@test "verified agent consultation rolls up scorecard rows" {
  write_agent_report
  run bash "$LORE_CLI" impl check-report report-item --task 5 \
    --report "$REPORT" --phase 1 --provider-status full \
    --spawned-advisors "abcdef123456"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Advisor rollup: appended"
  grep -q '"metric": *"consultation_rate"' "$(rows_file)" \
    || grep -q '"metric":"consultation_rate"' "$(rows_file)"
  grep -q "abcdef123456" "$(rows_file)"
}

@test "unverified advisor is stripped and logged; rollup withheld" {
  write_agent_report
  run bash "$LORE_CLI" impl check-report report-item --task 5 \
    --report "$REPORT" --phase 1 --provider-status full --spawned-advisors ""
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Advisor rollup: skipped (all-entries-stripped)"
  grep -q "fabrication-guard: skipped abcdef123456" "$(log_file)"
  [ ! -f "$(rows_file)" ]
}

@test "provider unavailable withholds the rollup and logs the branch" {
  write_agent_report
  run bash "$LORE_CLI" impl check-report report-item --task 5 \
    --report "$REPORT" --phase 1 --provider-status unavailable
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Advisor rollup: skipped (provider-unavailable)"
  grep -q "fabrication-guard: provider-unavailable; rollup skipped" "$(log_file)"
  [ ! -f "$(rows_file)" ]
}

@test "handler lead consultations bypass the guard and emit no rows" {
  write_consulted_report
  printf '{"consultation_id":"c-100","worker":"worker-5","domain":"security","handler":"lead","replied_at":"2026-06-10T00:00:00Z"}\n' \
    > "$TRANSCRIPT"
  run bash "$LORE_CLI" impl check-report report-item --task 5 \
    --report "$REPORT" --phase 2 --transcript "$TRANSCRIPT"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Fabrication guard: no-agent-consultations"
  [ ! -f "$(rows_file)" ]
}

# --- Execution-log filing ------------------------------------------------------

@test "passing check appends one execution-log entry with source impl-verb" {
  write_basic_report
  run bash "$LORE_CLI" impl check-report report-item --task 5 \
    --report "$REPORT" --phase 1 --woven-norm norm-a
  [ "$status" -eq 0 ]
  grep -q "source: impl-verb" "$(log_file)"
  grep -q "Check-report task: 5" "$(log_file)"
  grep -q "Mechanical pass: true" "$(log_file)"
}

@test "mechanical fail still files the findings in the execution log" {
  cat > "$REPORT" <<'EOF'
**Tier 2 evidence:**
ghost-claim-9
**Convention handling:** `none in scope`
EOF
  run bash "$LORE_CLI" impl check-report report-item --task 5 \
    --report "$REPORT" --phase 1
  [ "$status" -eq 3 ]
  grep -q "source: impl-verb" "$(log_file)"
  grep -q "Mechanical pass: false" "$(log_file)"
  grep -q "ghost-claim-9" "$(log_file)"
}

@test "archived work item is refused" {
  write_basic_report
  mkdir -p "$WORK_DIR/_archive"
  mv "$ITEM_DIR" "$WORK_DIR/_archive/report-item"
  run bash "$LORE_CLI" impl check-report report-item --task 5 \
    --report "$REPORT" --phase 1
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "archived"
}
