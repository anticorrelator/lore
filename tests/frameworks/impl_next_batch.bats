#!/usr/bin/env bats
# impl_next_batch.bats — Coverage for `lore impl next-batch` (scripts/impl-next-batch.sh)
#
# Asserts the batch-candidate discovery emitter:
#   - unblocked pending set computed from plan.md checkboxes + tasks.json edges
#   - refreshed per-task Tier 2 extracts (task_id and file-target overlap)
#   - --active tasks excluded and counted as incomplete blockers
#   - empty unblocked set is success (status all-blocked / all-complete)
#   - unmatched subjects warned and treated as incomplete
#   - same-file collision groups within the batch returned as conditions
#   - the four lead-inline conditions as separate fields, no aggregate boolean
#   - the execution-log attribution row is the only filesystem write
#   - resolver tri-state propagation, archived refusal, missing tasks.json
#
# The plan checksum is intentionally NOT enforced by next-batch (checking
# boxes edits plan.md mid-run by design), so fixtures use a stale checksum.

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"
LORE_CLI="$REPO_DIR/cli/lore"
NEXT_SH="$REPO_DIR/scripts/impl-next-batch.sh"

setup() {
  [ -x "$LORE_CLI" ] || skip "cli/lore missing"
  [ -x "$NEXT_SH" ]  || skip "impl-next-batch.sh missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 required"

  TEST_KDIR="$(mktemp -d)"
  TEST_DATA_DIR="$(mktemp -d)"
  export LORE_KNOWLEDGE_DIR="$TEST_KDIR"
  export LORE_DATA_DIR="$TEST_DATA_DIR"
  cd "$TEST_KDIR"

  WORK_DIR="$TEST_KDIR/_work"
  ITEM_DIR="$WORK_DIR/batch-item"
  mkdir -p "$ITEM_DIR"

  cat > "$ITEM_DIR/_meta.json" <<'EOF'
{"title": "Batch Item", "status": "active", "intent_anchor": "anchor"}
EOF
  # task-1 already checked complete; task-2 unblocked once task-1 is done;
  # task-3 blocked behind task-2.
  cat > "$ITEM_DIR/plan.md" <<'EOF'
# Batch Item

## Phases

### Phase 1: Build
- [x] build alpha module
- [ ] build beta module

### Phase 2: Verify
- [ ] verify alpha module
EOF
  python3 - "$ITEM_DIR/tasks.json" <<'PYEOF'
import json, sys
data = {
 "plan_checksum": "stale-by-design-for-next-batch",
 "generated_at": "2026-06-10T00:00:00Z",
 "recommended_workers": 1,
 "phases": [
  {"phase_number": 1, "phase_name": "Build", "objective": "Build", "files": [],
   "retrieval_directive": None,
   "tasks": [
    {"id": "task-1", "subject": "build alpha module", "activeForm": "Building alpha",
     "blockedBy": [], "file_targets": ["/src/alpha.sh"], "description": "**Phase:** 1"},
    {"id": "task-2", "subject": "build beta module", "activeForm": "Building beta",
     "blockedBy": ["task-1"], "file_targets": ["/src/beta.sh"], "description": "**Phase:** 1"}]},
  {"phase_number": 2, "phase_name": "Verify", "objective": "Verify", "files": [],
   "retrieval_directive": None,
   "tasks": [
    {"id": "task-3", "subject": "verify alpha module", "activeForm": "Verifying alpha",
     "blockedBy": ["task-2"], "file_targets": ["/src/alpha.sh"], "description": "**Phase:** 2"}]}]}
with open(sys.argv[1], "w") as f:
    json.dump(data, f, indent=1)
PYEOF

  cat > "$ITEM_DIR/task-claims.jsonl" <<'EOF'
{"claim_id": "b1", "task_id": "task-2", "claim": "beta direct", "captured_at_sha": "abc"}
{"claim_id": "b2", "task_id": "task-9", "file": "/src/beta.sh", "claim": "beta by file", "captured_at_sha": "def"}
EOF
}

teardown() {
  for d in "${TEST_KDIR:-}" "${TEST_DATA_DIR:-}"; do
    if [ -n "$d" ] && [ -d "$d" ]; then
      rm -rf "$d"
    fi
  done
  unset LORE_KNOWLEDGE_DIR LORE_DATA_DIR
}

payload() {
  # `run` merges stderr warnings into $output; the payload is the JSON line.
  echo "$output" | grep '"slug"'
}

# --- Unblocked-set discovery -------------------------------------------------

@test "--json returns only the unblocked pending task with refreshed payload fields" {
  run bash "$LORE_CLI" impl next-batch batch-item --json
  [ "$status" -eq 0 ]
  payload | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
assert d["status"] == "batch-ready"
assert d["completed"] == ["task-1"]
assert [t["local_id"] for t in d["batch"]] == ["task-2"]
t = d["batch"][0]
assert t["subject"] == "build beta module"
assert t["description"] == "**Phase:** 1"
assert t["file_targets"] == ["/src/beta.sh"]
# Refreshed Tier 2 extract: one row by task_id, one by file overlap.
assert [r["claim_id"] for r in t["tier2_extract"]] == ["b1", "b2"]
assert d["pending_blocked"] == [{"id": "task-3", "blocked_by_pending": ["task-2"]}]
'
}

@test "rows appended after open are picked up by the refresh" {
  echo '{"claim_id": "b3", "task_id": "task-2", "claim": "late row", "captured_at_sha": "fff"}' \
    >> "$ITEM_DIR/task-claims.jsonl"
  run bash "$LORE_CLI" impl next-batch batch-item --json
  [ "$status" -eq 0 ]
  payload | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
assert [r["claim_id"] for r in d["batch"][0]["tier2_extract"]] == ["b1", "b2", "b3"]
'
}

# --- Empty-batch semantics ------------------------------------------------------

@test "fully blocked (the only unblocked task is --active) is success with an empty batch" {
  run bash "$LORE_CLI" impl next-batch batch-item --active task-2 --json
  [ "$status" -eq 0 ]
  payload | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
assert d["status"] == "all-blocked"
assert d["batch"] == []
assert d["active"] == ["task-2"]
assert d["pending_blocked"] == [{"id": "task-3", "blocked_by_pending": ["task-2"]}]
'
}

@test "all tasks checked complete is success with status all-complete" {
  python3 - "$ITEM_DIR/plan.md" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read().replace("- [ ]", "- [x]")
open(p, "w").write(s)
PYEOF
  run bash "$LORE_CLI" impl next-batch batch-item --json
  [ "$status" -eq 0 ]
  payload | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
assert d["status"] == "all-complete"
assert d["batch"] == []
assert sorted(d["completed"]) == ["task-1", "task-2", "task-3"]
'
}

@test "a subject matching no plan checkbox is unmatched, warned, and treated as incomplete" {
  python3 - "$ITEM_DIR/plan.md" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read().replace("- [ ] build beta module\n", "")
open(p, "w").write(s)
PYEOF
  run bash "$LORE_CLI" impl next-batch batch-item --json
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "task-2 subject matches no plan.md checkbox"
  payload | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
assert d["unmatched"] == ["task-2"]
assert d["batch"] == []
assert d["status"] == "all-blocked"   # task-3 still waits on the unmatched task-2
assert d["pending_blocked"] == [{"id": "task-3", "blocked_by_pending": ["task-2"]}]
'
}

@test "--active naming an unknown task warns but does not fail" {
  run bash "$LORE_CLI" impl next-batch batch-item --active task-99 --json
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- "--active task-99 matches no task"
}

# --- Collision groups ------------------------------------------------------------

@test "unblocked tasks sharing a file target are returned as a collision group" {
  python3 - "$ITEM_DIR/plan.md" "$ITEM_DIR/tasks.json" <<'PYEOF'
import json, sys
plan, tasks = sys.argv[1], sys.argv[2]
s = open(plan).read().replace("- [ ] verify alpha module",
                              "- [ ] verify alpha module\n- [ ] polish beta module")
open(plan, "w").write(s)
d = json.load(open(tasks))
d["phases"][1]["tasks"].append({
    "id": "task-4", "subject": "polish beta module", "activeForm": "Polishing beta",
    "blockedBy": [], "file_targets": ["/src/beta.sh"], "description": "**Phase:** 2"})
json.dump(d, open(tasks, "w"), indent=1)
PYEOF
  run bash "$LORE_CLI" impl next-batch batch-item --json
  [ "$status" -eq 0 ]
  payload | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
assert [t["local_id"] for t in d["batch"]] == ["task-2", "task-4"]
assert d["collision_groups"] == [{"file": "/src/beta.sh", "tasks": ["task-2", "task-4"]}]
'
}

# --- Lead-inline conditions --------------------------------------------------------

@test "the four lead-inline conditions are separate fields with no aggregate boolean" {
  run bash "$LORE_CLI" impl next-batch batch-item --json
  [ "$status" -eq 0 ]
  payload | python3 -c '
import json, sys
c = json.loads(sys.stdin.read())["lead_inline_conditions"]
assert set(c.keys()) == {"single_task", "prescriptive", "no_persistent_advisor",
                         "no_required_consultation", "detail"}
assert c["single_task"] is False
assert c["no_persistent_advisor"] is True
assert c["no_required_consultation"] is True
assert "eligible" not in json.dumps(c).lower()
'
}

# --- Write discipline ----------------------------------------------------------------

@test "the execution-log attribution row is the only filesystem write" {
  before="$(find "$TEST_KDIR" -type f | sort)"
  run bash "$LORE_CLI" impl next-batch batch-item --json
  [ "$status" -eq 0 ]
  after="$(find "$TEST_KDIR" -type f | sort)"
  diff <(echo "$before") <(echo "$after") > "$BATS_TEST_TMPDIR/fsdiff" || true
  new_files="$(grep '^>' "$BATS_TEST_TMPDIR/fsdiff" | sed 's/^> //')"
  [ "$new_files" = "$ITEM_DIR/execution-log.md" ]
  grep -q "source: impl-verb" "$ITEM_DIR/execution-log.md"
  grep -q "Implement next-batch: 1 unblocked task(s) returned" "$ITEM_DIR/execution-log.md"
}

@test "each invocation appends exactly one attribution row" {
  run bash "$LORE_CLI" impl next-batch batch-item --json
  [ "$status" -eq 0 ]
  run bash "$LORE_CLI" impl next-batch batch-item --json
  [ "$status" -eq 0 ]
  count="$(grep -c "Implement next-batch:" "$ITEM_DIR/execution-log.md")"
  [ "$count" -eq 2 ]
}

# --- Validation / resolver tri-state ---------------------------------------------------

@test "missing tasks.json exits 1 directing to lore work tasks" {
  rm "$ITEM_DIR/tasks.json"
  run bash "$LORE_CLI" impl next-batch batch-item
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "lore work tasks batch-item"
}

@test "archived item is refused" {
  mkdir -p "$WORK_DIR/_archive/old-item"
  printf '{"title": "Old Item"}\n' > "$WORK_DIR/_archive/old-item/_meta.json"
  run bash "$LORE_CLI" impl next-batch old-item
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "archived"
}

@test "no match exits 1 with the resolver error" {
  run bash "$LORE_CLI" impl next-batch absolutely-no-such-thing-9999
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "No match for reference"
}

@test "ambiguous reference propagates exit 2 with candidates" {
  mkdir -p "$WORK_DIR/alpha-shared" "$WORK_DIR/beta-shared"
  printf '{"title": "Alpha Shared"}\n' > "$WORK_DIR/alpha-shared/_meta.json"
  printf '{"title": "Beta Shared"}\n'  > "$WORK_DIR/beta-shared/_meta.json"
  cat > "$WORK_DIR/_index.json" <<'EOF'
{"version": 1, "plans": [
 {"slug": "alpha-shared", "title": "Alpha Shared", "tags": ["duptag"], "updated": "2026-01-01T00:00:00Z"},
 {"slug": "beta-shared", "title": "Beta Shared", "tags": ["duptag"], "updated": "2026-01-02T00:00:00Z"}
], "archived": []}
EOF
  run bash "$LORE_CLI" impl next-batch duptag --json
  [ "$status" -eq 2 ]
  echo "$output" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
assert "error" in d
assert sorted(d["candidates"]) == ["alpha-shared", "beta-shared"]
'
}

@test "missing ref argument returns a usage error" {
  run bash "$LORE_CLI" impl next-batch
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "missing required argument"
}

@test "unknown flag returns an error" {
  run bash "$LORE_CLI" impl next-batch batch-item --no-such-flag
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "Unknown flag"
}

@test "text mode renders the batch, blockers, and conditions" {
  run bash "$LORE_CLI" impl next-batch batch-item
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "\[impl next-batch\] batch-item"
  echo "$output" | grep -q "Status: batch-ready"
  echo "$output" | grep -q "task-2 (phase 1): build beta module"
  echo "$output" | grep -q "blocked: task-3 <- task-2"
  echo "$output" | grep -q "single_task: False"
}

@test "lore impl usage mentions the next-batch verb" {
  run bash "$LORE_CLI" impl --help
  echo "$output" | grep -q "next-batch"
}
