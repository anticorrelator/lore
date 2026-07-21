#!/usr/bin/env bats
# impl_start.bats — Coverage for `lore impl start` (scripts/impl-start.sh)
#
# Asserts the Step 1 envelope absorber:
#   - start struct in text and --json modes (title, anchor, counts, models,
#     template versions, branch-cache status)
#   - intent anchor returned verbatim (multi-line preserved; null when absent)
#   - prior task-claims.jsonl parsed into by_task/by_file maps, malformed
#     lines skipped
#   - branch cache written as the only artifact; skipped for archived items
#   - validation failures: missing plan.md, no unchecked tasks
#   - resolver tri-state propagation: no-match exit 1, ambiguous exit 2
#
# All tests use an isolated knowledge directory via LORE_KNOWLEDGE_DIR and a
# throwaway git repo so branch names are deterministic.

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"
LORE_CLI="$REPO_DIR/cli/lore"
START_SH="$REPO_DIR/scripts/impl-start.sh"

setup() {
  [ -x "$LORE_CLI" ]  || skip "cli/lore missing"
  [ -x "$START_SH" ]  || skip "impl-start.sh missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 required"

  TEST_KDIR="$(mktemp -d)"
  export LORE_KNOWLEDGE_DIR="$TEST_KDIR"

  # cli/lore intentionally dispatches through ~/.lore/scripts. Point that
  # install-shaped path at this checkout so the test exercises the worktree
  # implementation instead of whichever Lore revision the operator installed.
  ORIGINAL_HOME="$HOME"
  export HOME="$TEST_KDIR/home"
  mkdir -p "$HOME/.lore"
  ln -s "$REPO_DIR/scripts" "$HOME/.lore/scripts"

  # Role->model env overrides are resolution order #1, so tests never read
  # the operator's settings.json.
  export LORE_MODEL_LEAD="test-lead-model"
  export LORE_MODEL_WORKER="test-worker-model"
  export LORE_MODEL_ADVISOR="test-advisor-model"
  export LORE_FRAMEWORK="claude-code"

  # Throwaway git repo: cache-branch.sh derives the branch from cwd.
  FAKE_REPO="$TEST_KDIR/fake-repo"
  mkdir -p "$FAKE_REPO"
  git -C "$FAKE_REPO" init -q
  git -C "$FAKE_REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$FAKE_REPO" checkout -qb impl-start-test-branch
  cd "$FAKE_REPO"

  WORK_DIR="$TEST_KDIR/_work"
  ARCHIVE_DIR="$WORK_DIR/_archive"
  mkdir -p "$WORK_DIR/widget-pipeline" "$ARCHIVE_DIR/retired-widget"

  cat > "$WORK_DIR/widget-pipeline/_meta.json" <<'EOF'
{
  "title": "Widget Pipeline",
  "status": "active",
  "intent_anchor": "Anchor line one.\nAnchor line two."
}
EOF
  cat > "$WORK_DIR/widget-pipeline/plan.md" <<'EOF'
# Widget Pipeline

## Phases

### Phase 1: Build
- [x] completed task
- [ ] open task a
- [ ] open task b

### Phase 2: Verify
- [ ] open task c
EOF
  cat > "$WORK_DIR/widget-pipeline/task-claims.jsonl" <<'EOF'
{"claim_id": "claim-a", "task_id": "task-1", "file": "/src/alpha.sh", "claim": "alpha claim"}
{"claim_id": "claim-b", "task_id": "task-2", "file": "/src/beta.sh", "claim": "beta claim"}
this line is not JSON
EOF

  printf '{"title":"Retired Widget","intent_anchor":"archived anchor"}\n' \
    > "$ARCHIVE_DIR/retired-widget/_meta.json"
  printf '## Phases\n\n### Phase 1: x\n- [ ] still open\n' \
    > "$ARCHIVE_DIR/retired-widget/plan.md"
}

teardown() {
  if [ -n "${TEST_KDIR:-}" ] && [ -d "$TEST_KDIR" ]; then
    rm -rf "$TEST_KDIR"
  fi
  export HOME="$ORIGINAL_HOME"
  unset LORE_KNOWLEDGE_DIR LORE_MODEL_LEAD LORE_MODEL_WORKER LORE_MODEL_ADVISOR LORE_FRAMEWORK
}

# --- Happy path: text mode ---------------------------------------------

@test "start returns the text struct with title, counts, models, and anchor" {
  run bash "$LORE_CLI" impl start widget-pipeline
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "\[impl start\] Widget Pipeline"
  echo "$output" | grep -q "Slug: widget-pipeline  (archived: false)"
  echo "$output" | grep -q "Models: lead=test-lead-model  worker=test-worker-model  advisor=test-advisor-model"
  echo "$output" | grep -q "Phases: 2 with 3 unchecked tasks"
  echo "$output" | grep -q "Prior Tier 2 claims: 2 rows loaded from task-claims.jsonl"
  echo "$output" | grep -q "Branch cache: written ('impl-start-test-branch' -> 'widget-pipeline')"
  echo "$output" | grep -q "Anchor line one."
  echo "$output" | grep -q "Anchor line two."
}

@test "start with no prior claims reports first run" {
  rm "$WORK_DIR/widget-pipeline/task-claims.jsonl"
  run bash "$LORE_CLI" impl start widget-pipeline
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Prior Tier 2 claims: none — first run"
}

# --- Happy path: --json -------------------------------------------------

@test "--json returns the full start struct" {
  run bash "$LORE_CLI" impl start widget-pipeline --json
  [ "$status" -eq 0 ]
  # `run` merges the stderr malformed-line warning into $output; parse the
  # JSON object line only.
  echo "$output" | grep '"slug"' | python3 -c '
import json, re, sys
d = json.loads(sys.stdin.read())
assert d["slug"] == "widget-pipeline"
assert d["archived"] is False
assert d["title"] == "Widget Pipeline"
assert d["intent_anchor"] == "Anchor line one.\nAnchor line two."
assert d["plan"] == {"phases": 2, "unchecked_tasks": 3}
assert d["branch_cache"]["status"] == "written"
assert d["branch_cache"]["branch"] == "impl-start-test-branch"
assert d["models"] == {"lead": "test-lead-model", "worker": "test-worker-model", "advisor": "test-advisor-model"}
for tv in d["template_versions"].values():
    assert re.fullmatch(r"[0-9a-f]{12}", tv), tv
'
}

@test "--json exposes the three worker-class bindings; standard is the plain worker model" {
  run bash "$LORE_CLI" impl start widget-pipeline --json
  [ "$status" -eq 0 ]
  echo "$output" | grep '"slug"' | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
wc = d["worker_class_models"]
assert set(wc.keys()) == {"mechanical", "standard", "judgment-dense"}
# standard == plain worker (env-bound); the class roles fall back to it once
# registered, or resolve to null before that registry entry lands.
assert wc["standard"] == "test-worker-model"
assert wc["mechanical"] in ("test-worker-model", None)
assert wc["judgment-dense"] in ("test-worker-model", None)
# The canonical role bindings are untouched by the class block.
assert d["models"] == {"lead": "test-lead-model", "worker": "test-worker-model", "advisor": "test-advisor-model"}
'
}

@test "--json exposes structured worker-class routes without replacing scalar bindings" {
  run bash "$LORE_CLI" impl start widget-pipeline --json
  [ "$status" -eq 0 ]
  echo "$output" | grep '"slug"' | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
routes = d["worker_class_routes"]
assert set(routes) == {"mechanical", "standard", "judgment-dense"}
for route in routes.values():
    assert route["source_framework"] == "claude-code"
    assert route["target_framework"] == "claude-code"
    assert route["native_binding"] == route["binding"]
    assert route["qualified"] is False
assert d["worker_class_models"]["standard"] == "test-worker-model"
'
}

@test "text mode renders the worker class bindings line" {
  run bash "$LORE_CLI" impl start widget-pipeline
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Worker class bindings (implement ceremony): mechanical=.* standard=test-worker-model  judgment-dense="
}

@test "start refuses an unsupported registered foreign worker route" {
  export LORE_MODEL_WORKER_MECHANICAL="opencode/openai/gpt-5.5"
  run bash "$LORE_CLI" impl start widget-pipeline --json
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported framework bridge 'claude-code->opencode'"* ]]
  [[ "$output" == *"refusing to prepare dispatch"* ]]
}

@test "--json prior-claims maps are keyed by task and by file; malformed lines skipped" {
  run bash "$LORE_CLI" impl start widget-pipeline --json
  [ "$status" -eq 0 ]
  # The malformed-line warning goes to stderr; `run` merges streams, so parse
  # the JSON object line only.
  echo "$output" | grep '"slug"' | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
pc = d["prior_claims"]
assert pc["total"] == 2
assert sorted(pc["by_task"].keys()) == ["task-1", "task-2"]
assert pc["by_task"]["task-1"][0]["claim_id"] == "claim-a"
assert pc["by_file"] == {"/src/alpha.sh": ["claim-a"], "/src/beta.sh": ["claim-b"]}
'
  echo "$output" | grep -q "skipping malformed line 3"
}

@test "absent intent_anchor returns null anchor (legacy item)" {
  python3 - "$WORK_DIR/widget-pipeline/_meta.json" <<'PYEOF'
import json, sys
p = sys.argv[1]
with open(p) as f: d = json.load(f)
del d["intent_anchor"]
with open(p, "w") as f: json.dump(d, f)
PYEOF
  run bash "$LORE_CLI" impl start widget-pipeline --json
  [ "$status" -eq 0 ]
  echo "$output" | grep '"slug"' | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
assert d["intent_anchor"] is None
'
}

# --- Branch cache -------------------------------------------------------

@test "start writes the branch cache for an active item" {
  [ ! -f "$TEST_KDIR/_branch_cache.json" ]
  run bash "$LORE_CLI" impl start widget-pipeline
  [ "$status" -eq 0 ]
  [ -f "$TEST_KDIR/_branch_cache.json" ]
  python3 - "$TEST_KDIR/_branch_cache.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["impl-start-test-branch"]["slug"] == "widget-pipeline"
PYEOF
}

@test "archived item skips the branch cache write" {
  run bash "$LORE_CLI" impl start retired-widget --json
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_KDIR/_branch_cache.json" ]
  echo "$output" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
assert d["archived"] is True
assert d["branch_cache"]["status"] == "skipped-archived"
'
}

# --- Validation ---------------------------------------------------------

@test "missing plan.md exits 1 with a re-spec diagnostic and writes no cache" {
  rm "$WORK_DIR/widget-pipeline/plan.md"
  run bash "$LORE_CLI" impl start widget-pipeline
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "No structured plan found"
  [ ! -f "$TEST_KDIR/_branch_cache.json" ]
}

@test "plan with no unchecked tasks exits 1 with already-complete diagnostic" {
  printf '## Phases\n\n### Phase 1: x\n- [x] done\n' > "$WORK_DIR/widget-pipeline/plan.md"
  run bash "$LORE_CLI" impl start widget-pipeline
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "All plan tasks are already complete"
}

@test "--json validation failure returns an error object" {
  rm "$WORK_DIR/widget-pipeline/plan.md"
  run bash "$LORE_CLI" impl start widget-pipeline --json
  [ "$status" -eq 1 ]
  echo "$output" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); assert "error" in d'
}

# --- Resolver tri-state propagation --------------------------------------

@test "no match exits 1 with the resolver error" {
  run bash "$LORE_CLI" impl start absolutely-no-such-thing-9999
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "No match for reference"
}

@test "ambiguous reference propagates exit 2 with candidates" {
  mkdir -p "$WORK_DIR/alpha-shared" "$WORK_DIR/beta-shared"
  printf '{"title":"Alpha Shared"}\n' > "$WORK_DIR/alpha-shared/_meta.json"
  printf '{"title":"Beta Shared"}\n'  > "$WORK_DIR/beta-shared/_meta.json"
  cat > "$WORK_DIR/_index.json" <<'EOF'
{"version":1,"plans":[
 {"slug":"alpha-shared","title":"Alpha Shared","tags":["duptag"],"updated":"2026-01-01T00:00:00Z"},
 {"slug":"beta-shared","title":"Beta Shared","tags":["duptag"],"updated":"2026-01-02T00:00:00Z"}
],"archived":[]}
EOF
  run bash "$LORE_CLI" impl start duptag --json
  [ "$status" -eq 2 ]
  echo "$output" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
assert "error" in d
assert sorted(d["candidates"]) == ["alpha-shared", "beta-shared"]
'
}

# --- CLI surface ----------------------------------------------------------

@test "missing ref argument returns a usage error" {
  run bash "$LORE_CLI" impl start
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "missing required argument"
}

@test "unknown flag returns an error" {
  run bash "$LORE_CLI" impl start widget-pipeline --no-such-flag
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "Unknown flag"
}

@test "lore impl usage mentions the start verb" {
  run bash "$LORE_CLI" impl --help
  echo "$output" | grep -q "start"
}
