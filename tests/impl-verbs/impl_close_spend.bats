#!/usr/bin/env bats
# impl_close_spend.bats — Coverage for the impl-close cost join (impl-close.sh).
#
# The lead records one `Spend: task=<id> key=value …` line per accepted task
# into execution-log.md (D1 vocabulary flattened). impl-close mines those lines
# and attaches each as a nullable `spend` object on the matching
# task_attribution entry of its kind=telemetry row. Asserts:
#   - absent Spend line -> spend: null; the key is present on every entry
#   - one line -> a spend object (typed: int tokens, float duration/cost,
#     string model/harness/basis/effort) with the `task=` join key stripped
#   - re-dispatch duplicates -> an ordered list, file order preserved
#   - duration-only line -> only duration_seconds + basis
#   - a malformed line (bad numeric field / missing task=) degrades that task to
#     null, warns on stderr, and never turns the close into a refusal (exit 0)
#   - a Spend line for an unknown task_id is dropped with a warning
#   - the enriched row stays kind: telemetry / tier: telemetry (no scored surface)
#
# The broader impl-close verb suite (flags, verdicts, archive, close-request)
# lives in tests/frameworks/impl_close.bats; this file is the spend-join slice.
# All tests use an isolated knowledge directory via LORE_KNOWLEDGE_DIR.

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"
LORE_CLI="$REPO_DIR/cli/lore"
CLOSE_SH="$REPO_DIR/scripts/impl-close.sh"
WRITE_LOG_SH="$REPO_DIR/scripts/write-execution-log.sh"

setup() {
  [ -x "$LORE_CLI" ] || skip "cli/lore missing"
  [ -f "$CLOSE_SH" ] || skip "impl-close.sh missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 required"
  command -v jq >/dev/null 2>&1 || skip "jq required for scorecard-append.sh"

  TEST_KDIR="$(mktemp -d)"
  export LORE_KNOWLEDGE_DIR="$TEST_KDIR"

  WORK_DIR="$TEST_KDIR/_work"
  mkdir -p "$WORK_DIR/anchored-done"
  make_meta "$WORK_DIR/anchored-done/_meta.json" "anchored-done" "Anchored Done" \
    "Deliver the close capability."
  printf -- '- [x] Build the verb\n- [x] Test the verb\n' > "$WORK_DIR/anchored-done/plan.md"
  echo "notes" > "$WORK_DIR/anchored-done/notes.md"
  seed_tasks
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

# task-1 claude-native (judgment_class null), task-2 standard, task-3 mechanical.
seed_tasks() {
  cat > "$WORK_DIR/anchored-done/tasks.json" <<'EOF'
{"plan_checksum": "x", "phases": [
  {"phase_number": 1, "tasks": [
    {"id": "task-1", "subject": "build the verb", "judgment_class": null,
     "context_cost_estimate": {"total_chars": 100}},
    {"id": "task-2", "subject": "test the verb", "judgment_class": "standard",
     "context_cost_estimate": {"total_chars": 200}},
    {"id": "task-3", "subject": "reason about it", "judgment_class": "mechanical",
     "context_cost_estimate": {"total_chars": 300}}]}]}
EOF
}

# Record one Spend: line into execution-log.md exactly as the lead would.
add_spend() {
  printf '%s\n' "$1" | bash "$WRITE_LOG_SH" \
    --slug anchored-done --source implement-lead >/dev/null
}

rows_file() { echo "$TEST_KDIR/_scorecards/rows.jsonl"; }

# --- Absent -----------------------------------------------------------------

@test "no Spend lines: every task_attribution entry carries spend: null" {
  run bash "$LORE_CLI" impl close anchored-done --verdict full --summary "done"
  [ "$status" -eq 0 ]
  python3 - "$(rows_file)" <<'PYEOF'
import json, sys
row = json.loads(open(sys.argv[1]).read())
attr = row["task_attribution"]
assert [a["task_id"] for a in attr] == ["task-1", "task-2", "task-3"]
assert all("spend" in a for a in attr), attr
assert [a["spend"] for a in attr] == [None, None, None], attr
PYEOF
}

# --- Single line ------------------------------------------------------------

@test "one Spend line attaches a typed D1 spend object with the task key stripped" {
  add_spend "Spend: task=task-1 harness=codex model=gpt-5-codex effort=high input_tokens=100 output_tokens=50 cache_read_input_tokens=10 cache_creation_input_tokens=4 reasoning_output_tokens=8 total_tokens=172 cost_usd=0.12 duration_seconds=42 basis=rollout"
  run bash "$LORE_CLI" impl close anchored-done --verdict full --summary "done"
  [ "$status" -eq 0 ]
  python3 - "$(rows_file)" <<'PYEOF'
import json, sys
row = json.loads(open(sys.argv[1]).read())
by_id = {a["task_id"]: a for a in row["task_attribution"]}
s = by_id["task-1"]["spend"]
assert isinstance(s, dict), s
assert "task" not in s, "join key must not leak into the spend object"
assert s["harness"] == "codex"
assert s["model"] == "gpt-5-codex"
assert s["effort"] == "high"
assert s["basis"] == "rollout"
for f in ("input_tokens", "output_tokens", "cache_read_input_tokens",
          "cache_creation_input_tokens", "reasoning_output_tokens", "total_tokens"):
    assert isinstance(s[f], int), (f, s[f])
assert s["input_tokens"] == 100 and s["total_tokens"] == 172
assert isinstance(s["cost_usd"], float) and s["cost_usd"] == 0.12
assert isinstance(s["duration_seconds"], float) and s["duration_seconds"] == 42.0
# the other two tasks stay null
assert by_id["task-2"]["spend"] is None
assert by_id["task-3"]["spend"] is None
PYEOF
}

@test "measured and null cells coexist on one row (the empirical comparison shape)" {
  add_spend "Spend: task=task-2 harness=codex model=m input_tokens=10 total_tokens=10 duration_seconds=5 basis=rollout"
  run bash "$LORE_CLI" impl close anchored-done --verdict full --summary "done"
  [ "$status" -eq 0 ]
  python3 - "$(rows_file)" <<'PYEOF'
import json, sys
row = json.loads(open(sys.argv[1]).read())
by_id = {a["task_id"]: a for a in row["task_attribution"]}
assert by_id["task-1"]["spend"] is None          # claude-native, honest null
assert isinstance(by_id["task-2"]["spend"], dict)  # codex, measured
assert by_id["task-3"]["spend"] is None
PYEOF
}

# --- Duplicates (re-dispatch) -----------------------------------------------

@test "duplicate Spend lines for a re-dispatched task are kept as an ordered list" {
  add_spend "Spend: task=task-2 harness=codex model=m1 input_tokens=10 total_tokens=10 duration_seconds=5 basis=rollout"
  add_spend "Spend: task=task-2 harness=codex model=m2 input_tokens=20 total_tokens=20 duration_seconds=6 basis=rollout"
  run bash "$LORE_CLI" impl close anchored-done --verdict full --summary "done"
  [ "$status" -eq 0 ]
  python3 - "$(rows_file)" <<'PYEOF'
import json, sys
row = json.loads(open(sys.argv[1]).read())
by_id = {a["task_id"]: a for a in row["task_attribution"]}
s = by_id["task-2"]["spend"]
assert isinstance(s, list) and len(s) == 2, s
assert s[0]["model"] == "m1" and s[0]["input_tokens"] == 10
assert s[1]["model"] == "m2" and s[1]["input_tokens"] == 20
PYEOF
}

# --- Degradation ------------------------------------------------------------

@test "duration-only Spend line attaches only duration_seconds and basis" {
  add_spend "Spend: task=task-3 duration_seconds=30 basis=duration-only"
  run bash "$LORE_CLI" impl close anchored-done --verdict full --summary "done"
  [ "$status" -eq 0 ]
  python3 - "$(rows_file)" <<'PYEOF'
import json, sys
row = json.loads(open(sys.argv[1]).read())
by_id = {a["task_id"]: a for a in row["task_attribution"]}
assert by_id["task-3"]["spend"] == {"duration_seconds": 30.0, "basis": "duration-only"}
PYEOF
}

@test "a malformed numeric field degrades the task to null, warns, and exits 0" {
  add_spend "Spend: task=task-1 harness=codex input_tokens=oops total_tokens=5 basis=rollout"
  run bash "$LORE_CLI" impl close anchored-done --verdict full --summary "done"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "malformed Spend: line"
  python3 - "$(rows_file)" <<'PYEOF'
import json, sys
row = json.loads(open(sys.argv[1]).read())
by_id = {a["task_id"]: a for a in row["task_attribution"]}
assert by_id["task-1"]["spend"] is None
PYEOF
}

@test "a Spend line missing task= is ignored with a warning" {
  add_spend "Spend: harness=codex input_tokens=10 total_tokens=10 basis=rollout"
  run bash "$LORE_CLI" impl close anchored-done --verdict full --summary "done"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "malformed Spend: line"
  python3 - "$(rows_file)" <<'PYEOF'
import json, sys
row = json.loads(open(sys.argv[1]).read())
assert all(a["spend"] is None for a in row["task_attribution"])
PYEOF
}

@test "a Spend line for an unknown task_id is dropped with a warning" {
  add_spend "Spend: task=task-99 harness=codex input_tokens=10 total_tokens=10 basis=rollout"
  run bash "$LORE_CLI" impl close anchored-done --verdict full --summary "done"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "no matching task_attribution entry"
  python3 - "$(rows_file)" <<'PYEOF'
import json, sys
row = json.loads(open(sys.argv[1]).read())
assert all(a["spend"] is None for a in row["task_attribution"])
PYEOF
}

@test "a valid line surviving alongside a malformed duplicate still attaches" {
  add_spend "Spend: task=task-2 harness=codex model=good input_tokens=10 total_tokens=10 basis=rollout"
  add_spend "Spend: task=task-2 harness=codex input_tokens=bad total_tokens=99 basis=rollout"
  run bash "$LORE_CLI" impl close anchored-done --verdict full --summary "done"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "malformed Spend: line"
  python3 - "$(rows_file)" <<'PYEOF'
import json, sys
row = json.loads(open(sys.argv[1]).read())
by_id = {a["task_id"]: a for a in row["task_attribution"]}
s = by_id["task-2"]["spend"]
# only the well-formed line survives -> a single object, not a list
assert isinstance(s, dict) and s["model"] == "good", s
PYEOF
}

# --- Kind discriminator -----------------------------------------------------

@test "the spend-enriched row stays kind: telemetry / tier: telemetry" {
  add_spend "Spend: task=task-1 harness=codex input_tokens=10 total_tokens=10 basis=rollout"
  run bash "$LORE_CLI" impl close anchored-done --verdict full --summary "done"
  [ "$status" -eq 0 ]
  python3 - "$(rows_file)" <<'PYEOF'
import json, sys
row = json.loads(open(sys.argv[1]).read())
assert row["kind"] == "telemetry"
assert row["tier"] == "telemetry"
PYEOF
}
