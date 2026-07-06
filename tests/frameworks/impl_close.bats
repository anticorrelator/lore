#!/usr/bin/env bats
# impl_close.bats — Coverage for `lore impl close` (impl-close.sh)
#
# Asserts:
#   - --verdict and --summary are required; verdict enum-validated
#   - per-verdict field contract (--divergence, --residue-title/--residue-anchor)
#   - REMAINING_COUNT precondition: unchecked plan.md tasks refuse the close
#     (no closure block, not archived, followup filed)
#   - --check-task reconciles plan.md before the precondition is evaluated
#   - full close: closure block written (sole-writer schema), archive verified,
#     retro-bundle.json written, execution-log entry with source impl-verb,
#     one kind=telemetry row with 12-hex template_version and attribution counts
#   - partial close: child work item created and linked, parent held open,
#     notes.md appended, divergence banner, exit 3
#   - none close: no child, parent held open, exit 3
#   - legacy items: full archives without a closure block; partial/none refused
#   - blocker entries in execution-log.md create a followup on a clean close
#   - tri-state reference resolution passthrough; --json output shape
#
# All tests use an isolated knowledge directory via LORE_KNOWLEDGE_DIR.

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"
LORE_CLI="$REPO_DIR/cli/lore"
CLOSE_SH="$REPO_DIR/scripts/impl-close.sh"

setup() {
  [ -x "$LORE_CLI" ] || skip "cli/lore missing"
  [ -f "$CLOSE_SH" ] || skip "impl-close.sh missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 required"
  command -v jq >/dev/null 2>&1 || skip "jq required for scorecard-append.sh"

  TEST_KDIR="$(mktemp -d)"
  export LORE_KNOWLEDGE_DIR="$TEST_KDIR"

  WORK_DIR="$TEST_KDIR/_work"
  mkdir -p "$WORK_DIR/anchored-done" "$WORK_DIR/anchored-open" "$WORK_DIR/legacy-done"

  make_meta "$WORK_DIR/anchored-done/_meta.json" "anchored-done" "Anchored Done" "Deliver the close capability."
  make_meta "$WORK_DIR/anchored-open/_meta.json" "anchored-open" "Anchored Open" "Deliver X and Y."
  make_meta "$WORK_DIR/legacy-done/_meta.json" "legacy-done" "Legacy Done" ""

  printf -- '- [x] Build the verb\n- [x] Test the verb\n' > "$WORK_DIR/anchored-done/plan.md"
  printf -- '- [x] Build X\n- [ ] Build Y\n' > "$WORK_DIR/anchored-open/plan.md"
  printf -- '- [x] Old task\n' > "$WORK_DIR/legacy-done/plan.md"

  printf '{"claim_id":"c1"}\n{"claim_id":"c2"}\n' > "$WORK_DIR/anchored-done/task-claims.jsonl"

  echo "notes" > "$WORK_DIR/anchored-done/notes.md"
  echo "notes" > "$WORK_DIR/anchored-open/notes.md"
  echo "notes" > "$WORK_DIR/legacy-done/notes.md"
}

teardown() {
  if [ -n "${TEST_KDIR:-}" ] && [ -d "$TEST_KDIR" ]; then
    rm -rf "$TEST_KDIR"
  fi
  unset LORE_KNOWLEDGE_DIR
  unset LORE_SESSION_INSTANCE LORE_SESSION_SLUG LORE_SESSION_TYPE
}

make_meta() {
  python3 - "$1" "$2" "$3" "$4" <<'PYEOF'
import json, sys
path, slug, title, anchor = sys.argv[1:5]
meta = {"slug": slug, "title": title, "status": "active",
        "created": "2026-06-01T00:00:00Z", "updated": "2026-06-01T00:00:00Z"}
if anchor:
    meta["intent_anchor"] = anchor
with open(path, "w") as f:
    json.dump(meta, f, indent=2)
PYEOF
}

closure_of() {
  python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])).get("closure")))' "$1"
}

rows_file() { echo "$TEST_KDIR/_scorecards/rows.jsonl"; }

json_payload() {
  # `run` merges stderr into $output; the post-telemetry retro-sampling gate
  # writes a `[retro] …` note there on every completed close. The --json payload
  # is the object line — isolated by the JSON key `"slug"` (the gate's stderr
  # wraps the slug in single quotes, so it is not matched).
  echo "$output" | grep '"slug"'
}

# --- Required flags and enum ----------------------------------------------

@test "missing --verdict exits 1 naming the flag" {
  run bash "$LORE_CLI" impl close anchored-done --summary "done"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- "--verdict is required"
}

@test "missing --summary exits 1 naming the flag" {
  run bash "$LORE_CLI" impl close anchored-done --verdict full
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- "--summary is required"
}

@test "invalid verdict exits 1 listing the enum" {
  run bash "$LORE_CLI" impl close anchored-done --verdict mostly --summary "done"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "full|partial|none"
}

# --- Per-verdict field contract --------------------------------------------

@test "full with --divergence is rejected" {
  run bash "$LORE_CLI" impl close anchored-done --verdict full --summary "done" --divergence "stray"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- "does not take --divergence"
}

@test "partial without --divergence is rejected" {
  run bash "$LORE_CLI" impl close anchored-done --verdict partial --summary "done" \
    --residue-title "Rest" --residue-anchor "Rest works"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- "--divergence"
}

@test "partial without residue flags is rejected" {
  run bash "$LORE_CLI" impl close anchored-done --verdict partial --summary "done" --divergence "Y deferred"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- "--residue-title"
}

@test "none with residue flags is rejected" {
  run bash "$LORE_CLI" impl close anchored-done --verdict none --summary "attempted" \
    --divergence "nothing shipped" --residue-title "Rest" --residue-anchor "Rest works"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- "does not take --residue-title"
}

# --- REMAINING_COUNT precondition -------------------------------------------

@test "unchecked plan tasks refuse the close with a diagnostic" {
  run bash "$LORE_CLI" impl close anchored-open --verdict full --summary "done"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "still unchecked in plan.md"
  echo "$output" | grep -q "Build Y"
}

@test "refused close writes no closure block and does not archive" {
  run bash "$LORE_CLI" impl close anchored-open --verdict full --summary "done"
  [ "$status" -eq 1 ]
  [ "$(closure_of "$WORK_DIR/anchored-open/_meta.json")" = "null" ]
  [ -d "$WORK_DIR/anchored-open" ]
  [ ! -d "$WORK_DIR/_archive/anchored-open" ]
}

@test "refused close files a Deferred work followup" {
  run bash "$LORE_CLI" impl close anchored-open --verdict full --summary "done"
  [ "$status" -eq 1 ]
  [ -d "$TEST_KDIR/_followups/deferred-work-anchored-open" ]
  grep -q "Build Y" "$TEST_KDIR/_followups/deferred-work-anchored-open/finding.md"
}

@test "--check-task reconciles plan.md before the precondition" {
  run bash "$LORE_CLI" impl close anchored-open --verdict full --summary "X and Y shipped" \
    --check-task "Build Y"
  [ "$status" -eq 0 ]
  grep -q -- '- \[x\] Build Y' "$WORK_DIR/_archive/anchored-open/plan.md"
}

@test "unmatched --check-task subject refuses the close" {
  run bash "$LORE_CLI" impl close anchored-done --verdict full --summary "done" \
    --check-task "No Such Task Subject"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "plan reconcile failed"
}

# --- Full close --------------------------------------------------------------

@test "full close writes the closure block with the fixed schema" {
  run bash "$LORE_CLI" impl close anchored-done --verdict full --summary "capability operable"
  [ "$status" -eq 0 ]
  python3 - "$WORK_DIR/_archive/anchored-done/_meta.json" <<'PYEOF'
import json, sys
closure = json.load(open(sys.argv[1]))["closure"]
assert closure["verdict"] == "full"
assert closure["capability_incomplete"] is False
assert closure["capability_loop_summary"] == "capability operable"
assert closure["divergence_summary"] is None
assert closure["residue_followup"] is None
assert closure["verdict_at"]
assert closure["intent_anchor_at_close"] == "Deliver the close capability."
PYEOF
}

@test "full close archives via archive-work.sh and verifies the move" {
  run bash "$LORE_CLI" impl close anchored-done --verdict full --summary "done"
  [ "$status" -eq 0 ]
  [ -d "$WORK_DIR/_archive/anchored-done" ]
  [ ! -d "$WORK_DIR/anchored-done" ]
  status_field=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' \
    "$WORK_DIR/_archive/anchored-done/_meta.json")
  [ "$status_field" = "archived" ]
}

@test "full close emits the Done report with run-context counts" {
  run bash "$LORE_CLI" impl close anchored-done --verdict full --summary "done"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "\[implement\] Done."
  echo "$output" | grep -q "Completed: 2/2 tasks"
  echo "$output" | grep -q "Closure: full"
  echo "$output" | grep -q "Tier 2 claims written: 2"
}

@test "full close appends one execution-log entry with source impl-verb" {
  run bash "$LORE_CLI" impl close anchored-done --verdict full --summary "done"
  [ "$status" -eq 0 ]
  log="$WORK_DIR/_archive/anchored-done/execution-log.md"
  [ "$(grep -c '^## ' "$log")" -eq 1 ]
  grep -q "source: impl-verb" "$log"
  grep -q '^Closure verdict: full$' "$log"
  grep -q '^Capability loop summary: "done"' "$log"
}

@test "full close writes retro-bundle.json with the nine-field schema" {
  run bash "$LORE_CLI" impl close anchored-done --verdict full --summary "done" \
    --lead-template-version aaaaaaaaaaaa --run-started-at "2026-06-10T00:00:00Z"
  [ "$status" -eq 0 ]
  python3 - "$WORK_DIR/_archive/anchored-done/retro-bundle.json" <<'PYEOF'
import json, sys
b = json.load(open(sys.argv[1]))
assert set(b) == {"work_item", "tasks_completed", "tier2_claim_ids",
                  "tier3_promoted_ids", "advisor_consultations_count", "blockers",
                  "template_versions", "captured_at_sha", "run_started_at"}, set(b)
assert b["work_item"] == "anchored-done"
assert b["tasks_completed"] == 2
assert b["tier2_claim_ids"] == ["c1", "c2"]
assert b["template_versions"]["lead"] == "aaaaaaaaaaaa"
assert b["template_versions"]["worker"] is None
assert b["run_started_at"] == "2026-06-10T00:00:00Z"
PYEOF
}

# --- Telemetry ----------------------------------------------------------------

@test "full close appends one kind=telemetry row with 12-hex template_version and counts" {
  # Pre-seed a hand-run entry so both attribution counters are exercised.
  echo "lead narration" | bash "$REPO_DIR/scripts/write-execution-log.sh" \
    --slug anchored-done --source implement-lead >/dev/null
  run bash "$LORE_CLI" impl close anchored-done --verdict full --summary "done"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$(rows_file)")" -eq 1 ]
  python3 - "$(rows_file)" <<'PYEOF'
import json, re, sys
row = json.loads(open(sys.argv[1]).read())
assert row["kind"] == "telemetry"
assert row["tier"] == "telemetry"
assert row["event_type"] == "impl-close"
assert row["work_item"] == "anchored-done"
assert row["verdict"] == "full"
assert re.fullmatch(r"[0-9a-f]{12}", row["template_version"]), row["template_version"]
assert row["verb_mediated_count"] == 1
assert row["hand_run_count"] == 1
PYEOF
}

@test "divergent close also emits a telemetry row carrying the verdict" {
  run bash "$LORE_CLI" impl close anchored-done --verdict none --summary "attempted" \
    --divergence "nothing load-bearing shipped"
  [ "$status" -eq 3 ]
  verdict=$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).read())["verdict"])' "$(rows_file)")
  [ "$verdict" = "none" ]
}

@test "telemetry row carries a per-task class-routing attribution array" {
  # Env override is resolution order #1, so the standard class resolves without
  # touching operator settings; the class-qualified roles fall back to it.
  export LORE_MODEL_WORKER="test-worker-model"
  cat > "$WORK_DIR/anchored-done/tasks.json" <<'EOF'
{"plan_checksum": "x", "phases": [
  {"phase_number": 1, "tasks": [
    {"id": "task-1", "subject": "build the verb", "judgment_class": null,
     "context_cost_estimate": {"total_chars": 1200}},
    {"id": "task-2", "subject": "test the verb", "judgment_class": "standard",
     "context_cost_estimate": {"total_chars": 3400}},
    {"id": "task-3", "subject": "reason about the verb", "judgment_class": "judgment-dense",
     "context_cost_estimate": {"total_chars": 9000}}]}]}
EOF
  run bash "$LORE_CLI" impl close anchored-done --verdict full --summary "done"
  [ "$status" -eq 0 ]
  python3 - "$(rows_file)" <<'PYEOF'
import json, sys
row = json.loads(open(sys.argv[1]).read())
attr = row["task_attribution"]
assert [a["task_id"] for a in attr] == ["task-1", "task-2", "task-3"]
assert [a["judgment_class"] for a in attr] == [None, "standard", "judgment-dense"]
assert [a["context_cost_estimate"] for a in attr] == [1200, 3400, 9000]
by_id = {a["task_id"]: a for a in attr}
# null and standard both route as plain worker → the env-bound model.
assert by_id["task-1"]["worker_model"] == "test-worker-model"
assert by_id["task-2"]["worker_model"] == "test-worker-model"
# The class-qualified role resolves to the worker fallback once registered, or
# null before task-1 lands the role in the registry — both are acceptable here.
assert by_id["task-3"]["worker_model"] in ("test-worker-model", None)
PYEOF
}

# --- Partial close --------------------------------------------------------------

partial_close() {
  bash "$LORE_CLI" impl close anchored-done --verdict partial --summary "X shipped" \
    --divergence "Y deferred to child" \
    --residue-title "Deliver Y capability" --residue-anchor "Y is operable end to end" "$@"
}

@test "partial close creates the residue child linked to the parent" {
  run partial_close
  [ "$status" -eq 3 ]
  child="$WORK_DIR/deliver-y-capability"
  [ -d "$child" ]
  python3 - "$child/_meta.json" <<'PYEOF'
import json, sys
meta = json.load(open(sys.argv[1]))
assert meta["intent_anchor"] == "Y is operable end to end"
assert meta["related_work"] == ["anchored-done"]
PYEOF
}

@test "partial close writes the closure block and holds the parent open" {
  run partial_close
  [ "$status" -eq 3 ]
  [ -d "$WORK_DIR/anchored-done" ]
  [ ! -d "$WORK_DIR/_archive/anchored-done" ]
  python3 - "$WORK_DIR/anchored-done/_meta.json" <<'PYEOF'
import json, sys
closure = json.load(open(sys.argv[1]))["closure"]
assert closure["verdict"] == "partial"
assert closure["capability_incomplete"] is True
assert closure["divergence_summary"] == "Y deferred to child"
assert closure["residue_followup"] == "deliver-y-capability"
PYEOF
}

@test "partial close appends the closure note to parent notes.md" {
  run partial_close
  [ "$status" -eq 3 ]
  grep -q '^\*\*Closure (partial):\*\* see follow-up `deliver-y-capability`' \
    "$WORK_DIR/anchored-done/notes.md"
}

@test "partial close emits the divergence banner with no Done text" {
  run partial_close
  [ "$status" -eq 3 ]
  echo "$output" | grep -q "DIVERGED FROM ANCHOR"
  echo "$output" | grep -q "Residue follow-up: deliver-y-capability"
  ! echo "$output" | grep -q "\[implement\] Done."
}

# --- None close -------------------------------------------------------------------

@test "none close records capability_incomplete with no child and exits 3" {
  run bash "$LORE_CLI" impl close anchored-done --verdict none --summary "attempted" \
    --divergence "nothing load-bearing shipped"
  [ "$status" -eq 3 ]
  [ -d "$WORK_DIR/anchored-done" ]
  python3 - "$WORK_DIR/anchored-done/_meta.json" <<'PYEOF'
import json, sys
closure = json.load(open(sys.argv[1]))["closure"]
assert closure["verdict"] == "none"
assert closure["capability_incomplete"] is True
assert closure["residue_followup"] is None
PYEOF
}

# --- Legacy items ------------------------------------------------------------------

@test "legacy full close archives without writing a closure block" {
  run bash "$LORE_CLI" impl close legacy-done --verdict full --summary "done"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Closure: legacy"
  [ -d "$WORK_DIR/_archive/legacy-done" ]
  [ "$(closure_of "$WORK_DIR/_archive/legacy-done/_meta.json")" = "null" ]
}

@test "legacy partial is refused as anchor-relative" {
  run bash "$LORE_CLI" impl close legacy-done --verdict partial --summary "x" \
    --divergence "y" --residue-title "Rest" --residue-anchor "Rest works"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "no intent_anchor"
}

# --- Blocker followup on a clean close ----------------------------------------------

@test "blockers in execution-log.md create a followup and render in the Done report" {
  printf 'Report body\n**Blockers:** flaky CI runner blocked task 4\n' \
    | bash "$REPO_DIR/scripts/write-execution-log.sh" --slug anchored-done --source implement-lead >/dev/null
  run bash "$LORE_CLI" impl close anchored-done --verdict full --summary "done"
  [ "$status" -eq 0 ]
  [ -d "$TEST_KDIR/_followups/deferred-work-anchored-done" ]
  grep -q "flaky CI runner" "$TEST_KDIR/_followups/deferred-work-anchored-done/finding.md"
  echo "$output" | grep -q "Followup: Deferred work: Anchored Done"
}

@test "Blockers: none does not create a followup" {
  printf 'Report body\n**Blockers:** none\n' \
    | bash "$REPO_DIR/scripts/write-execution-log.sh" --slug anchored-done --source implement-lead >/dev/null
  run bash "$LORE_CLI" impl close anchored-done --verdict full --summary "done"
  [ "$status" -eq 0 ]
  [ ! -d "$TEST_KDIR/_followups/deferred-work-anchored-done" ]
}

# --- Reference resolution and archived refusal ---------------------------------------

@test "no-match reference exits 1" {
  run bash "$LORE_CLI" impl close no-such-item-zzz --verdict full --summary "done"
  [ "$status" -eq 1 ]
}

@test "ambiguous reference exits 2" {
  cat > "$WORK_DIR/_index.json" <<'EOF'
{
  "version": 1,
  "plans": [
    {"slug": "anchored-done", "title": "Anchored Done", "tags": ["shared-tag"], "branches": []},
    {"slug": "anchored-open", "title": "Anchored Open", "tags": ["shared-tag"], "branches": []}
  ],
  "archived": []
}
EOF
  run bash "$LORE_CLI" impl close shared-tag --verdict full --summary "done"
  [ "$status" -eq 2 ]
}

@test "already-archived work item is rejected" {
  mkdir -p "$WORK_DIR/_archive/old-item"
  printf '{"slug": "old-item", "title": "Old Item", "status": "archived"}\n' \
    > "$WORK_DIR/_archive/old-item/_meta.json"
  run bash "$LORE_CLI" impl close old-item --verdict full --summary "done"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "already archived"
}

# --- JSON output -----------------------------------------------------------------------

@test "--json on full close returns the close summary object" {
  run bash "$LORE_CLI" impl close anchored-done --verdict full --summary "done" --json
  [ "$status" -eq 0 ]
  json_payload | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
assert d["slug"] == "anchored-done"
assert d["verdict"] == "full"
assert d["archived"] is True
assert d["residue_followup"] is None
assert d["report_exit"] == 0
assert "[implement] Done." in d["report"]
'
}

@test "--json on validation error returns an error object with exit 1" {
  run bash "$LORE_CLI" impl close anchored-done --json
  [ "$status" -eq 1 ]
  echo "$output" | python3 -c 'import json, sys; d = json.loads(sys.stdin.read()); assert "error" in d'
}

# --- D4 protocol-terminus close-request --------------------------------------
# The post-telemetry step self-addresses a session close-request only inside a
# TUI-hosted session (LORE_SESSION_* set), best-effort, and never disturbs the
# verb's exit code, verdict, or telemetry. A completed close emits regardless of
# whether the report exits 0 (full/legacy) or 3 (partial/none divergence); a
# refused close (exit 1, before the emission point) emits nothing.

close_request_count() {
  local dir="$TEST_KDIR/_sessions/close-requests"
  if [ -d "$dir" ]; then
    find "$dir" -maxdepth 1 -name '*.json' | wc -l | tr -d ' '
  else
    echo 0
  fi
}

@test "a full close inside a TUI session emits one self-addressed close-request" {
  export LORE_SESSION_INSTANCE="tui-a1b2c3"
  export LORE_SESSION_SLUG="anchored-done"
  export LORE_SESSION_TYPE="implement"
  run bash "$LORE_CLI" impl close anchored-done --verdict full --summary "done"
  [ "$status" -eq 0 ]
  [ "$(close_request_count)" -eq 1 ]
}

@test "a divergence close (exit 3) is a completed close and emits a close-request" {
  # The session's protocol step completed — the close ran its full write sequence
  # to a terminal verdict — so exit 3 emits, unlike a refused close.
  export LORE_SESSION_INSTANCE="tui-a1b2c3"
  export LORE_SESSION_SLUG="anchored-done"
  export LORE_SESSION_TYPE="implement"
  run bash "$LORE_CLI" impl close anchored-done --verdict none --summary "attempted" \
    --divergence "nothing load-bearing shipped"
  [ "$status" -eq 3 ]
  [ "$(close_request_count)" -eq 1 ]
}

@test "close outside a session emits no close-request and archives as before" {
  unset LORE_SESSION_INSTANCE LORE_SESSION_SLUG LORE_SESSION_TYPE
  run bash "$LORE_CLI" impl close anchored-done --verdict full --summary "done"
  [ "$status" -eq 0 ]
  [ -d "$WORK_DIR/_archive/anchored-done" ]
  [ "$(close_request_count)" -eq 0 ]
  [ ! -d "$TEST_KDIR/_sessions/close-requests" ]
}

@test "a failing session-close.sh leaves the close exit code and telemetry untouched" {
  # Plant a regular file where session-close.sh expects to mkdir close-requests/,
  # forcing the real script to fail — no stub, a genuine failure condition.
  mkdir -p "$TEST_KDIR/_sessions"
  printf 'not-a-dir\n' > "$TEST_KDIR/_sessions/close-requests"
  export LORE_SESSION_INSTANCE="tui-a1b2c3"
  export LORE_SESSION_SLUG="anchored-done"
  export LORE_SESSION_TYPE="implement"
  run bash "$LORE_CLI" impl close anchored-done --verdict full --summary "done"
  [ "$status" -eq 0 ]
  [ -f "$(rows_file)" ]
  [ "$(wc -l < "$(rows_file)")" -eq 1 ]
  echo "$output" | grep -q "session close-request failed"
}

@test "a refused close (unchecked tasks, exit 1) emits no close-request inside a session" {
  export LORE_SESSION_INSTANCE="tui-a1b2c3"
  export LORE_SESSION_SLUG="anchored-open"
  export LORE_SESSION_TYPE="implement"
  run bash "$LORE_CLI" impl close anchored-open --verdict full --summary "done"
  [ "$status" -eq 1 ]
  [ "$(close_request_count)" -eq 0 ]
}
