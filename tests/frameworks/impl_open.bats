#!/usr/bin/env bats
# impl_open.bats — Coverage for `lore impl open` (scripts/impl-open.sh)
#
# Asserts the prepare-and-return dispatch manifest emitter:
#   - TeamCreate-first ordered manifest with complete blockedBy wiring
#   - same-file collision serialization (path-connected pairs exempt)
#   - the four lead-inline conditions as separate fields, no aggregate boolean
#   - 3-branch prior-knowledge gate routing with per-phase error containment
#   - per-task Tier 2 extracts (task_id and file-target overlap)
#   - skill-invocation map (plan + ceremony injection)
#   - selection modes (--all / --phase / --task), explicit-selection requirement
#   - the execution-log attribution row is the only filesystem write
#   - checksum gate, missing tasks.json, resolver tri-state propagation
#
# All tests use an isolated knowledge dir (LORE_KNOWLEDGE_DIR) and an isolated
# LORE_DATA_DIR so ceremony/settings/capability lookups never touch the
# operator's real config.

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"
LORE_CLI="$REPO_DIR/cli/lore"
OPEN_SH="$REPO_DIR/scripts/impl-open.sh"

# Build tasks.json from a JSON body (passed as $3) with plan_checksum computed
# from the plan file, so the load-tasks checksum gate passes.
build_tasks_json() {
  local plan="$1" out="$2" body="$3"
  _LORE_TASKS_BODY="$body" python3 - "$plan" "$out" <<'PYEOF'
import hashlib, json, os, sys
plan, out = sys.argv[1], sys.argv[2]
data = json.loads(os.environ["_LORE_TASKS_BODY"])
with open(plan, "rb") as f:
    data["plan_checksum"] = hashlib.sha256(f.read()).hexdigest()
with open(out, "w") as f:
    json.dump(data, f, indent=1)
PYEOF
}

DEFAULT_TASKS_BODY='{
 "generated_at": "2026-06-10T00:00:00Z",
 "recommended_workers": 2,
 "phases": [
  {"phase_number": 1, "phase_name": "Build", "objective": "Build modules",
   "files": ["/src/alpha.sh", "/src/beta.sh"], "retrieval_directive": null,
   "tasks": [
    {"id": "task-1", "subject": "build alpha module", "activeForm": "Building alpha module",
     "blockedBy": [], "file_targets": ["/src/alpha.sh"],
     "description": "**Phase:** 1\n\n## Prior Knowledge\n- embedded"},
    {"id": "task-2", "subject": "build beta module", "activeForm": "Building beta module",
     "blockedBy": [], "file_targets": ["/src/beta.sh"],
     "description": "**Phase:** 1\n\n## Prior Knowledge\n- embedded"}]},
  {"phase_number": 2, "phase_name": "Verify", "objective": "Verify modules",
   "files": ["/src/alpha.sh", "/src/beta.sh"], "retrieval_directive": null,
   "tasks": [
    {"id": "task-3", "subject": "verify alpha module", "activeForm": "Verifying alpha module",
     "blockedBy": ["task-1"], "file_targets": ["/src/alpha.sh"],
     "description": "**Phase:** 2"},
    {"id": "task-4", "subject": "polish beta module", "activeForm": "Polishing beta module",
     "blockedBy": [], "file_targets": ["/src/beta.sh"],
     "description": "**Phase:** 2"}]}]}'

setup() {
  [ -x "$LORE_CLI" ] || skip "cli/lore missing"
  [ -x "$OPEN_SH" ]  || skip "impl-open.sh missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 required"

  TEST_KDIR="$(mktemp -d)"
  TEST_DATA_DIR="$(mktemp -d)"
  export LORE_KNOWLEDGE_DIR="$TEST_KDIR"
  export LORE_DATA_DIR="$TEST_DATA_DIR"
  cd "$TEST_KDIR"

  WORK_DIR="$TEST_KDIR/_work"
  ITEM_DIR="$WORK_DIR/widget-pipeline"
  mkdir -p "$ITEM_DIR"

  cat > "$ITEM_DIR/_meta.json" <<'EOF'
{"title": "Widget Pipeline", "status": "active", "intent_anchor": "anchor"}
EOF
  cat > "$ITEM_DIR/plan.md" <<'EOF'
# Widget Pipeline

## Context

**Related skills:**
- /semgrep — static analysis advisory. [on-demand]

## Phases

### Phase 1: Build
- [ ] build alpha module
- [ ] build beta module

### Phase 2: Verify
- [ ] verify alpha module
- [ ] polish beta module
EOF
  build_tasks_json "$ITEM_DIR/plan.md" "$ITEM_DIR/tasks.json" "$DEFAULT_TASKS_BODY"

  cat > "$ITEM_DIR/task-claims.jsonl" <<'EOF'
{"claim_id": "c1", "task_id": "task-1", "file": "/src/alpha.sh", "claim": "alpha claim", "captured_at_sha": "abc"}
{"claim_id": "c2", "task_id": "task-9", "file": "/src/beta.sh", "claim": "beta claim", "captured_at_sha": "def"}
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

# --- Manifest contract ----------------------------------------------------

@test "--all --json returns a TeamCreate-first manifest with complete blockedBy edges" {
  run bash "$LORE_CLI" impl open widget-pipeline --all --json
  [ "$status" -eq 0 ]
  payload | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
assert d["status"] == "ready"
assert d["team_name"] == "impl-widget-pipeline"
m = d["manifest"]
assert m[0]["op"] == "TeamCreate" and m[0]["team_name"] == "impl-widget-pipeline"
creates = [op for op in m if op["op"] == "TaskCreate"]
assert [c["local_id"] for c in creates] == ["task-1", "task-2", "task-3", "task-4"]
assert all(m.index(c) < min(m.index(u) for u in m if u["op"] == "TaskUpdate") for c in creates)
updates = {op["local_id"]: op for op in m if op["op"] == "TaskUpdate"}
assert updates["task-3"]["add_blocked_by"] == ["task-1"]
assert d["initial_unblocked"] == ["task-1", "task-2"]
'
}

@test "judgment_class projects into TaskCreate entries; absent marker is null" {
  # Patch in place — plan_checksum is a hash of plan.md and stays valid.
  python3 - "$ITEM_DIR/tasks.json" <<'PYEOF'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["phases"][0]["tasks"][0]["judgment_class"] = "mechanical"  # task-1
json.dump(d, open(p, "w"), indent=1)
PYEOF
  run bash "$LORE_CLI" impl open widget-pipeline --all --json
  [ "$status" -eq 0 ]
  payload | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
creates = {op["local_id"]: op for op in d["manifest"] if op["op"] == "TaskCreate"}
assert creates["task-1"]["judgment_class"] == "mechanical"
assert creates["task-2"]["judgment_class"] is None
'
}

@test "same-file concurrent tasks get a serialization edge; path-connected pairs do not" {
  run bash "$LORE_CLI" impl open widget-pipeline --all --json
  [ "$status" -eq 0 ]
  payload | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
# task-2 / task-4 share /src/beta.sh with no dependency path: serialized.
assert d["collisions"] == [{"file": "/src/beta.sh", "tasks": ["task-2", "task-4"],
                            "serialized_edge": {"blocker": "task-2", "blocked": "task-4"}}]
updates = {op["local_id"]: op for op in d["manifest"] if op["op"] == "TaskUpdate"}
assert updates["task-4"]["add_blocked_by"] == ["task-2"]
assert updates["task-4"]["collision_serialized"] == ["task-2"]
# task-1 / task-3 share /src/alpha.sh but are path-connected: no collision edge.
assert "collision_serialized" not in updates["task-3"]
'
}

@test "the four lead-inline conditions are separate fields with no aggregate boolean" {
  run bash "$LORE_CLI" impl open widget-pipeline --all --json
  [ "$status" -eq 0 ]
  payload | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
c = d["lead_inline_conditions"]
assert set(c.keys()) == {"single_task", "prescriptive", "no_persistent_advisor",
                         "no_required_consultation", "detail"}
assert c["single_task"] is False
assert c["no_persistent_advisor"] is True
assert c["no_required_consultation"] is False  # plan declares /semgrep
assert "eligible" not in json.dumps(c).lower()
'
}

@test "single prescriptive task with no orchestration reports all four conditions true" {
  ITEM2="$WORK_DIR/tiny-fix"
  mkdir -p "$ITEM2"
  printf '{"title": "Tiny Fix", "status": "active", "intent_anchor": "a"}\n' > "$ITEM2/_meta.json"
  cat > "$ITEM2/plan.md" <<'EOF'
# Tiny Fix

## Phases

### Phase 1: Fix
**Task format:** prescriptive
- [ ] fix the typo
EOF
  build_tasks_json "$ITEM2/plan.md" "$ITEM2/tasks.json" '{
   "generated_at": "x", "recommended_workers": 1,
   "phases": [{"phase_number": 1, "phase_name": "Fix", "objective": "Fix",
    "files": ["/src/a.sh"], "retrieval_directive": null,
    "tasks": [{"id": "task-1", "subject": "fix the typo", "activeForm": "Fixing the typo",
     "blockedBy": [], "file_targets": ["/src/a.sh"],
     "description": "**Phase:** 1\n\n## Prior Knowledge\n- embedded"}]}]}'
  run bash "$LORE_CLI" impl open tiny-fix --all --json
  [ "$status" -eq 0 ]
  payload | python3 -c '
import json, sys
c = json.loads(sys.stdin.read())["lead_inline_conditions"]
assert c["single_task"] is True
assert c["prescriptive"] is True
assert c["no_persistent_advisor"] is True
assert c["no_required_consultation"] is True
assert c["detail"]["file_count_diagnostic"] == 1
'
}

@test "a mode: persistent advisor declaration flips no_persistent_advisor and is returned parsed" {
  cat >> "$ITEM_DIR/plan.md" <<'EOF'

**Advisors:**
- security-advisor — security review. mode: persistent
EOF
  build_tasks_json "$ITEM_DIR/plan.md" "$ITEM_DIR/tasks.json" "$DEFAULT_TASKS_BODY"
  run bash "$LORE_CLI" impl open widget-pipeline --all --json
  [ "$status" -eq 0 ]
  payload | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
assert d["lead_inline_conditions"]["no_persistent_advisor"] is False
adv = d["advisors"][0]
assert adv["name"] == "security-advisor"
assert adv["mode"] == "persistent"
assert adv["domain"] == "security review"
'
}

# --- Prior-knowledge 3-branch gate ------------------------------------------

@test "embedded Prior Knowledge skips prefetch; bare phase needs a declared fallback scale" {
  run bash "$LORE_CLI" impl open widget-pipeline --all --json
  [ "$status" -eq 0 ]
  payload | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
pk = {p["phase_number"]: p for p in d["prior_knowledge"]}
assert pk[1]["branch"] == "task-descriptions"
assert pk[1]["status"] == "skipped-embedded"
assert pk[2]["branch"] == "fallback"
assert pk[2]["status"] == "needs-prefetch"   # no --fallback-scale-set declared
assert pk[2]["fallback_query"].startswith("Verify modules")
'
}

@test "a failing retrieval_directive is contained per phase, not fatal to the manifest" {
  python3 - "$ITEM_DIR/tasks.json" <<'PYEOF'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["phases"][1]["retrieval_directive"] = {"seeds": [], "scale_set": "implementation"}
json.dump(d, open(p, "w"), indent=1)
PYEOF
  run bash "$LORE_CLI" impl open widget-pipeline --all --json
  [ "$status" -eq 0 ]
  payload | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
assert d["status"] == "ready"
pk2 = {p["phase_number"]: p for p in d["prior_knowledge"]}[2]
assert pk2["branch"] == "directive"
assert pk2["status"] == "error"
'
}

@test "invalid --fallback-scale-set bucket is rejected" {
  run bash "$LORE_CLI" impl open widget-pipeline --all --fallback-scale-set bogus
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "fallback-scale-set bucket"
}

# --- Tier 2 extracts ----------------------------------------------------------

@test "Tier 2 extracts match by task_id and by file-target overlap" {
  run bash "$LORE_CLI" impl open widget-pipeline --all --json
  [ "$status" -eq 0 ]
  payload | python3 -c '
import json, sys
t2 = json.loads(sys.stdin.read())["tier2_extracts"]
assert [r["claim_id"] for r in t2["task-1"]] == ["c1"]    # task_id match
assert [r["claim_id"] for r in t2["task-2"]] == ["c2"]    # file overlap
assert [r["claim_id"] for r in t2["task-4"]] == ["c2"]    # file overlap
'
}

# --- Skill-invocation map + ceremony injection ---------------------------------

@test "ceremony-configured skills merge into the map and are logged in the attribution row" {
  mkdir -p "$TEST_DATA_DIR/config"
  printf '{"harnesses": {"claude-code": {"ceremonies": {"implement": ["pr-review"]}}}}\n' \
    > "$TEST_DATA_DIR/config/settings.json"
  run bash "$LORE_CLI" impl open widget-pipeline --all --json
  [ "$status" -eq 0 ]
  payload | python3 -c '
import json, re, sys
d = json.loads(sys.stdin.read())
m = d["skill_invocation_map"]
assert m["semgrep"]["source"] == "plan"
assert m["pr-review"]["source"] == "ceremony"
assert re.fullmatch(r"[0-9a-f]{12}", m["pr-review"]["skill_template_version"])
assert d["lead_inline_conditions"]["detail"]["ceremony_skills"] == ["pr-review"]
'
  grep -q "Ceremony-injected skill: pr-review" "$ITEM_DIR/execution-log.md"
}

# --- Selection modes -----------------------------------------------------------

@test "selection is required: no default mode" {
  run bash "$LORE_CLI" impl open widget-pipeline --json
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "selection is required"
}

@test "selection modes are exclusive" {
  run bash "$LORE_CLI" impl open widget-pipeline --all --phase 2
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "exactly one of"
}

@test "--phase selection surfaces out-of-selection blockers as external_blocked_by" {
  run bash "$LORE_CLI" impl open widget-pipeline --phase 2 --json
  [ "$status" -eq 0 ]
  payload | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
creates = {op["local_id"]: op for op in d["manifest"] if op["op"] == "TaskCreate"}
assert sorted(creates) == ["task-3", "task-4"]
assert creates["task-3"]["external_blocked_by"] == ["task-1"]
assert d["initial_unblocked"] == ["task-4"]
'
}

@test "--task selection matching nothing is a successful empty manifest with status" {
  run bash "$LORE_CLI" impl open widget-pipeline --task task-99 --json
  [ "$status" -eq 0 ]
  payload | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
assert d["status"] == "empty"
assert d["manifest"] == []
assert "matched no tasks" in d["status_reason"]
'
}

@test "tasks already checked complete in plan.md are excluded and their edges treated satisfied" {
  python3 - "$ITEM_DIR/plan.md" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read().replace("- [ ] build alpha module", "- [x] build alpha module")
open(p, "w").write(s)
PYEOF
  build_tasks_json "$ITEM_DIR/plan.md" "$ITEM_DIR/tasks.json" "$DEFAULT_TASKS_BODY"
  run bash "$LORE_CLI" impl open widget-pipeline --all --json
  [ "$status" -eq 0 ]
  payload | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
assert d["already_complete"] == ["task-1"]
creates = [op["local_id"] for op in d["manifest"] if op["op"] == "TaskCreate"]
assert creates == ["task-2", "task-3", "task-4"]
updates = {op["local_id"]: op for op in d["manifest"] if op["op"] == "TaskUpdate"}
assert "task-3" not in updates           # its only blocker is complete
assert "task-3" not in json.dumps([op.get("external_blocked_by") for op in d["manifest"]])
'
}

# --- Write discipline -----------------------------------------------------------

@test "filesystem writes are the execution-log row plus the packet substrate" {
  before="$(find "$TEST_KDIR" -type f | sort)"
  run bash "$LORE_CLI" impl open widget-pipeline --all --json
  [ "$status" -eq 0 ]
  after="$(find "$TEST_KDIR" -type f | sort)"
  diff <(echo "$before") <(echo "$after") > "$BATS_TEST_TMPDIR/fsdiff" || true
  new_files="$(grep '^>' "$BATS_TEST_TMPDIR/fsdiff" | sed 's/^> //' | sort)"
  expected="$(printf '%s\n%s\n%s\n' \
    "$TEST_KDIR/_packets/README.md" \
    "$TEST_KDIR/_packets/packets.jsonl" \
    "$ITEM_DIR/execution-log.md" | sort)"
  [ "$new_files" = "$expected" ]
  grep -q "source: impl-verb" "$ITEM_DIR/execution-log.md"
  grep -q "Implement open: dispatch manifest prepared" "$ITEM_DIR/execution-log.md"
  grep -q "Collisions serialized: 1" "$ITEM_DIR/execution-log.md"
  grep -q "Task-scope packets appended: 4" "$ITEM_DIR/execution-log.md"
}

@test "one task-scope packet row per eligible task; manifest TaskCreate entries carry packet_id" {
  run bash "$LORE_CLI" impl open widget-pipeline --all --json
  [ "$status" -eq 0 ]
  payload > "$BATS_TEST_TMPDIR/payload.json"
  python3 - "$BATS_TEST_TMPDIR/payload.json" "$TEST_KDIR/_packets/packets.jsonl" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
rows = [json.loads(l) for l in open(sys.argv[2]) if l.strip()]
assert [r["task_id"] for r in rows] == ["task-1", "task-2", "task-3", "task-4"]
assert all(r["packet_scope"] == "task" for r in rows)
assert all(r["delivery_stage"] == "assembled" for r in rows)
assert all(r["arm"] is None for r in rows)
# no retrieval directive in the fixture: empty deliveries carry a reason
assert all(r["delivered_entries"] == [] and r["empty_reason"] for r in rows)
creates = {op["local_id"]: op for op in d["manifest"] if op["op"] == "TaskCreate"}
by_task = {r["task_id"]: r["packet_id"] for r in rows}
assert {p["task_id"]: p["packet_id"] for p in d["packets"]} == by_task
for tid, pid in by_task.items():
    assert creates[tid]["packet_id"] == pid
# tier2 extract references travel with the packet
assert rows[0]["tier2_claim_ids"] == ["c1"]
PYEOF
}

# --- Validation gates ------------------------------------------------------------

@test "checksum mismatch (plan.md edited after generation) exits 1 with regen guidance" {
  echo "- a late edit" >> "$ITEM_DIR/plan.md"
  run bash "$LORE_CLI" impl open widget-pipeline --all
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "regen-tasks"
}

@test "missing tasks.json exits 1 directing to lore work tasks" {
  rm "$ITEM_DIR/tasks.json"
  run bash "$LORE_CLI" impl open widget-pipeline --all
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "lore work tasks widget-pipeline"
}

@test "archived item is refused" {
  mkdir -p "$WORK_DIR/_archive/old-item"
  printf '{"title": "Old Item"}\n' > "$WORK_DIR/_archive/old-item/_meta.json"
  run bash "$LORE_CLI" impl open old-item --all
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "archived"
}

# --- Resolver tri-state / CLI surface ---------------------------------------------

@test "no match exits 1 with the resolver error" {
  run bash "$LORE_CLI" impl open absolutely-no-such-thing-9999 --all
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
  run bash "$LORE_CLI" impl open duptag --all --json
  [ "$status" -eq 2 ]
  echo "$output" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
assert "error" in d
assert sorted(d["candidates"]) == ["alpha-shared", "beta-shared"]
'
}

@test "missing ref argument returns a usage error" {
  run bash "$LORE_CLI" impl open --all
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "missing required argument"
}

@test "unknown flag returns an error" {
  run bash "$LORE_CLI" impl open widget-pipeline --all --no-such-flag
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "Unknown flag"
}

@test "text mode renders the manifest, conditions, and checksum line" {
  run bash "$LORE_CLI" impl open widget-pipeline --all
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "\[impl open\] Widget Pipeline"
  echo "$output" | grep -q "1. TeamCreate impl-widget-pipeline"
  echo "$output" | grep -q "TaskUpdate task-4 addBlockedBy=\[task-2\]"
  echo "$output" | grep -q "single_task: False"
  echo "$output" | grep -q "checksum: .* MATCH"
}

@test "lore impl usage mentions the open verb" {
  run bash "$LORE_CLI" impl --help
  echo "$output" | grep -q "open"
}
