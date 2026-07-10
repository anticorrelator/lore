#!/usr/bin/env bats
# spec_finalize.bats — Coverage for `lore spec finalize` (scripts/spec-finalize.sh)
#
# Asserts:
#   - cmd_spec router surface (usage, unknown verb, no args, top-level listing)
#   - write-execution-log.sh --source enum accepts spec-verb, rejects unknowns
#   - happy path: exit 0, one telemetry row, attribution counts include the
#     finalize atom itself, --json shape (backlinks/anchor/contract_asserts/telemetry)
#   - intent-anchor gate refusal: exit 3, verifier code named, no regen, no row
#   - no-anchor item: gate reported skipped (never passed), still exits 0
#   - unresolved backlinks: warn and continue to attribution + telemetry
#   - emission-contract assert: empty seeds refuse naming the phase, no row
#   - re-finalize appends a fresh point-event row (no dedup)
#   - resolver tri-state passthrough (no match 1, ambiguous 2)
#   - SKILL.md Step 5.5 routes through the verb (no hand-run verifier sequence)
#
# All tests use an isolated knowledge directory via LORE_KNOWLEDGE_DIR.

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"
LORE_CLI="$REPO_DIR/cli/lore"
FINALIZE_SH="$REPO_DIR/scripts/spec-finalize.sh"

# Writes a plan.md for slug $1 with intent-anchor body $2 (empty = no section)
# and retrieval-directive style $3 (v2 | legacy-empty-seeds | none).
write_plan() {
  local dir="$1" anchor_body="$2" directive="$3" extra_context="${4:-}"
  {
    echo "# Fixture Item"
    echo ""
    echo "## Goal"
    echo "Ship the fixture."
    echo ""
    if [ -n "$extra_context" ]; then
      echo "## Context"
      echo "$extra_context"
      echo ""
    fi
    if [ -n "$anchor_body" ]; then
      echo "## Intent Anchor"
      echo "$anchor_body"
      echo ""
      echo "**Scope delta:** none — anchor preserved unchanged"
      echo ""
    fi
    echo "## Phases"
    echo ""
    echo "### Phase 1: Build"
    echo "**Objective:** Build the module"
    case "$directive" in
      v2)
        echo '**Retrieval directive:**'
        echo '```yaml'
        echo 'retrieval_directive:'
        echo '  version: 2'
        echo '  topics:'
        echo '    - role: focal'
        echo '      topic: "finalize module"'
        echo '      seeds:'
        echo '        - "scripts/spec-finalize.sh"'
        echo '      scale_set: [implementation]'
        echo '      limit: 4'
        echo '```'
        ;;
      legacy-empty-seeds)
        echo '**Retrieval directive:**'
        echo '- seeds:'
        echo '- scale_set: implementation'
        ;;
      none)
        ;;
    esac
    echo "**Tasks:**"
    echo "- [ ] build the module [class: standard]"
  } > "$dir/plan.md"
}

make_item() {
  # $1 slug, $2 intent_anchor meta value (empty = omit), $3 plan anchor body,
  # $4 directive style, $5 optional extra context line
  local dir="$WORK_DIR/$1"
  mkdir -p "$dir"
  if [ -n "$2" ]; then
    _LORE_ANCHOR="$2" python3 - "$dir/_meta.json" "$1" <<'PYEOF'
import json, os, sys
meta = {"title": sys.argv[2], "status": "active",
        "intent_anchor": os.environ["_LORE_ANCHOR"]}
with open(sys.argv[1], "w") as f:
    json.dump(meta, f)
PYEOF
  else
    printf '{"title": "%s", "status": "active"}\n' "$1" > "$dir/_meta.json"
  fi
  write_plan "$dir" "$3" "$4" "${5:-}"
}

setup() {
  [ -x "$LORE_CLI" ] || skip "cli/lore missing"
  [ -f "$FINALIZE_SH" ] || skip "spec-finalize.sh missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 required"

  TEST_KDIR="$(mktemp -d)"
  TEST_DATA_DIR="$(mktemp -d)"
  export LORE_KNOWLEDGE_DIR="$TEST_KDIR"
  export LORE_DATA_DIR="$TEST_DATA_DIR"
  cd "$TEST_KDIR"

  WORK_DIR="$TEST_KDIR/_work"
  mkdir -p "$WORK_DIR"

  make_item "finalize-item" "Deliver the finalize capability." \
    "Deliver the finalize capability." v2
}

teardown() {
  for d in "${TEST_KDIR:-}" "${TEST_DATA_DIR:-}"; do
    if [ -n "$d" ] && [ -d "$d" ]; then
      rm -rf "$d"
    fi
  done
  unset LORE_KNOWLEDGE_DIR LORE_DATA_DIR
  unset LORE_SESSION_INSTANCE LORE_SESSION_SLUG LORE_SESSION_TYPE
}

rows_file() { echo "$TEST_KDIR/_scorecards/rows.jsonl"; }

row_count() {
  if [ -f "$(rows_file)" ]; then
    grep -c '"spec_finalize_bookkeeping"' "$(rows_file)" || true
  else
    echo 0
  fi
}

json_payload() {
  # `run` merges stderr warnings into $output; the payload is the JSON line.
  echo "$output" | grep '"slug"'
}

# --- Router surface -----------------------------------------------------

@test "lore spec with no args prints usage and exits non-zero" {
  run bash "$LORE_CLI" spec
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "finalize"
}

@test "lore spec --help lists the finalize verb" {
  run bash "$LORE_CLI" spec --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "finalize"
}

@test "unknown spec verb exits non-zero with error" {
  run bash "$LORE_CLI" spec no-such-verb
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "unknown spec verb"
}

@test "top-level lore usage mentions the spec subgroup" {
  run bash "$LORE_CLI" --help
  echo "$output" | grep -q "lore spec --help"
}

# --- write-execution-log.sh enum extension --------------------------------

@test "write-execution-log.sh accepts --source spec-verb directly" {
  echo "direct body" | bash "$REPO_DIR/scripts/write-execution-log.sh" \
    --slug finalize-item --source spec-verb
  grep -q "source: spec-verb" "$WORK_DIR/finalize-item/execution-log.md"
}

@test "write-execution-log.sh rejects unknown sources, naming spec-verb in the enum" {
  run bash -c 'echo body | bash "'"$REPO_DIR"'/scripts/write-execution-log.sh" --slug finalize-item --source bogus'
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "spec-verb"
}

# --- Happy path -------------------------------------------------------------

@test "finalize on a valid anchored item exits 0 and appends one telemetry row" {
  run bash "$LORE_CLI" spec finalize finalize-item
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Finalize complete"
  [ -f "$WORK_DIR/finalize-item/tasks.json" ]
  [ "$(row_count)" -eq 1 ]
}

@test "telemetry row counts match execution-log source atoms including the finalize atom" {
  # One pre-existing hand-run atom + the spec-verb atom finalize writes.
  echo "hand-run body" | bash "$REPO_DIR/scripts/write-execution-log.sh" \
    --slug finalize-item --source spec-lead
  run bash "$LORE_CLI" spec finalize finalize-item
  [ "$status" -eq 0 ]
  python3 - "$(rows_file)" <<'PYEOF'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
rows = [r for r in rows if r.get("metric") == "spec_finalize_bookkeeping"]
assert len(rows) == 1, rows
row = rows[0]
assert row["kind"] == "telemetry", row
assert row["tier"] == "telemetry", row
assert row["calibration_state"] == "pre-calibration", row
assert row["event_type"] == "spec-finalize", row
assert row["work_item"] == "finalize-item", row
assert row["verb_mediated_count"] == 1, row
assert row["hand_run_count"] == 1, row
assert row["template_version"], row
PYEOF
}

@test "finalize stamps exactly one spec-verb execution-log atom" {
  run bash "$LORE_CLI" spec finalize finalize-item
  [ "$status" -eq 0 ]
  count=$(grep -c "| source: spec-verb" "$WORK_DIR/finalize-item/execution-log.md")
  [ "$count" -eq 1 ]
}

@test "--json output carries backlinks, anchor, contract_asserts, and telemetry fields" {
  run bash "$LORE_CLI" spec finalize finalize-item --json
  [ "$status" -eq 0 ]
  json_payload | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
assert d["slug"] == "finalize-item"
assert d["backlinks"]["status"] == "passed", d["backlinks"]
assert d["anchor"]["status"] == "passed", d["anchor"]
assert d["contract_asserts"]["status"] == "passed", d["contract_asserts"]
assert d["telemetry"]["status"] == "appended", d["telemetry"]
assert d["telemetry"]["metric"] == "spec_finalize_bookkeeping"
assert d["verb_mediated_count"] == 1
'
}

# --- Intent-anchor gate ------------------------------------------------------

@test "diverged anchor body exits 3, names verifier code 3, regenerates no tasks, appends no row" {
  make_item "divergent-item" "Deliver the true capability." \
    "A paraphrased anchor that diverges." v2
  run bash "$LORE_CLI" spec finalize divergent-item
  [ "$status" -eq 3 ]
  echo "$output" | grep -q "3 = anchor body diverges"
  [ ! -f "$WORK_DIR/divergent-item/tasks.json" ]
  [ "$(row_count)" -eq 0 ]
  [ ! -f "$WORK_DIR/divergent-item/execution-log.md" ]
}

@test "missing Intent Anchor section on an anchored item exits 3 naming code 2" {
  make_item "sectionless-item" "Deliver the capability." "" v2
  run bash "$LORE_CLI" spec finalize sectionless-item
  [ "$status" -eq 3 ]
  echo "$output" | grep -q "2 = Intent Anchor section missing"
  [ "$(row_count)" -eq 0 ]
}

@test "no-anchor item reports the gate as skipped, never passed, and exits 0" {
  make_item "legacy-item" "" "" v2
  run bash "$LORE_CLI" spec finalize legacy-item
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Anchor gate:      skipped"
  echo "$output" | grep -q "no intent_anchor"
  ! echo "$output" | grep -q "Anchor gate:      passed"
  [ "$(row_count)" -eq 1 ]
}

@test "no-anchor item --json reports anchor status skipped with the verifier reason" {
  make_item "legacy-item" "" "" v2
  run bash "$LORE_CLI" spec finalize legacy-item --json
  [ "$status" -eq 0 ]
  json_payload | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
assert d["anchor"]["status"] == "skipped", d["anchor"]
assert "no intent_anchor" in d["anchor"]["reason"], d["anchor"]
'
}

# --- Backlink gate ------------------------------------------------------------

@test "unresolved backlinks warn and continue to attribution and telemetry" {
  make_item "backlink-item" "Deliver the capability." \
    "Deliver the capability." v2 "[[knowledge:nonexistent/entry-xyz]]"
  run bash "$LORE_CLI" spec finalize backlink-item
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "unresolved backlink"
  echo "$output" | grep -q "Backlinks:        warned"
  grep -q "| source: spec-verb" "$WORK_DIR/backlink-item/execution-log.md"
  [ "$(row_count)" -eq 1 ]
}

# --- Emission-contract assert ---------------------------------------------------

@test "empty seeds in a retrieval directive refuse with a diagnostic naming the phase" {
  make_item "empty-seeds-item" "Deliver the capability." \
    "Deliver the capability." legacy-empty-seeds
  run bash "$LORE_CLI" spec finalize empty-seeds-item
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "emission-contract assert failed"
  echo "$output" | grep -q "phase 1"
  echo "$output" | grep -q "empty seeds"
  [ "$(row_count)" -eq 0 ]
  ! grep -q "| source: spec-verb" "$WORK_DIR/empty-seeds-item/execution-log.md" 2>/dev/null
}

# --- Judgment-class gate --------------------------------------------------------

# Writes a no-anchor plan.md (anchor gate skips) with a custom Phase 1 body.
write_class_gate_plan() {
  local slug="$1" phase_body="$2"
  local dir="$WORK_DIR/$slug"
  mkdir -p "$dir"
  printf '{"title": "%s", "status": "active"}\n' "$slug" > "$dir/_meta.json"
  {
    echo "# Fixture Item"
    echo ""
    echo "## Goal"
    echo "Ship the fixture."
    echo ""
    echo "## Phases"
    echo ""
    echo "### Phase 1: Build"
    printf '%s\n' "$phase_body"
  } > "$dir/plan.md"
}

@test "unannotated task line refuses naming the offending line, no row or atom" {
  write_class_gate_plan "unannotated-item" "$(printf '%s\n' \
    '**Objective:** Build the module' \
    '**Tasks:**' \
    '- [ ] build the module with no class marker')"
  run bash "$LORE_CLI" spec finalize unannotated-item
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "judgment-class gate"
  echo "$output" | grep -q "unannotated task line"
  echo "$output" | grep -q "build the module with no class marker"
  [ "$(row_count)" -eq 0 ]
  ! grep -q "| source: spec-verb" "$WORK_DIR/unannotated-item/execution-log.md" 2>/dev/null
}

@test "multi-task phase without split rationale refuses naming the phase, no row" {
  write_class_gate_plan "no-rationale-item" "$(printf '%s\n' \
    '**Objective:** Build the module' \
    '**Tasks:**' \
    '- [ ] build the core in `src/a.py` [class: judgment-dense]' \
    '- [ ] apply the sweep in `src/b.py` [class: mechanical]')"
  run bash "$LORE_CLI" spec finalize no-rationale-item
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "judgment-class gate"
  echo "$output" | grep -q "phase 1"
  echo "$output" | grep -q "Split rationale"
  [ "$(row_count)" -eq 0 ]
}

@test "annotated multi-task phase finalizes and stamps split_rationale + class_distribution" {
  write_class_gate_plan "annotated-item" "$(printf '%s\n' \
    '**Objective:** Build the module' \
    '**Split rationale:**' \
    'Separates the judgment-dense parser core from the mechanical rename sweep so each routes to its own worker tier.' \
    '**Tasks:**' \
    '- [ ] build the core in `src/a.py` [class: judgment-dense]' \
    '- [ ] apply the sweep in `src/b.py` [class: mechanical]')"
  run bash "$LORE_CLI" spec finalize annotated-item
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE "Class gate:.*passed"
  [ "$(row_count)" -eq 1 ]
  python3 - "$(rows_file)" <<'PYEOF'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
rows = [r for r in rows if r.get("metric") == "spec_finalize_bookkeeping"]
assert rows, "no telemetry row"
r = rows[-1]
assert r["class_distribution"]["judgment-dense"] == 1, r
assert r["class_distribution"]["mechanical"] == 1, r
assert r["class_distribution"]["standard"] == 0, r
assert "1" in r["split_rationale"], r
assert "judgment-dense parser core" in r["split_rationale"]["1"], r
PYEOF
}

# --- Point-event semantics -------------------------------------------------------

@test "re-running finalize appends a fresh row rather than deduplicating" {
  run bash "$LORE_CLI" spec finalize finalize-item
  [ "$status" -eq 0 ]
  run bash "$LORE_CLI" spec finalize finalize-item
  [ "$status" -eq 0 ]
  [ "$(row_count)" -eq 2 ]
  # Second run counts the first run's atom as verb-mediated too.
  python3 - "$(rows_file)" <<'PYEOF'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
rows = [r for r in rows if r.get("metric") == "spec_finalize_bookkeeping"]
assert [r["verb_mediated_count"] for r in rows] == [1, 2], rows
PYEOF
}

# --- Reference resolution: tri-state passthrough ----------------------------------

@test "no-match reference exits 1" {
  run bash "$LORE_CLI" spec finalize no-such-item-zzz
  [ "$status" -eq 1 ]
}

@test "ambiguous reference exits 2" {
  make_item "other-item" "Other anchor." "Other anchor." v2
  cat > "$WORK_DIR/_index.json" <<'EOF'
{
  "version": 1,
  "plans": [
    {"slug": "finalize-item", "title": "Finalize Item", "tags": ["shared-tag"], "branches": []},
    {"slug": "other-item", "title": "Other Item", "tags": ["shared-tag"], "branches": []}
  ],
  "archived": []
}
EOF
  run bash "$LORE_CLI" spec finalize shared-tag
  [ "$status" -eq 2 ]
}

@test "archived work item is rejected" {
  mkdir -p "$WORK_DIR/_archive/done-item"
  printf '{"title": "Done Item", "intent_anchor": "old"}\n' > "$WORK_DIR/_archive/done-item/_meta.json"
  run bash "$LORE_CLI" spec finalize done-item
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "archived"
}

# --- SKILL.md Step 5.6 finalize contract -------------------------------------------

skill_step_5_6() {
  awk '/^### Step 5\.6/,/^### Step 6/' "$REPO_DIR/skills/spec/SKILL.md"
}

@test "spec SKILL.md Step 5.6 invokes lore spec finalize" {
  skill_step_5_6 | grep -q "lore spec finalize"
}

@test "spec SKILL.md Step 5.6 no longer hand-runs the verifier or regen sequence" {
  ! skill_step_5_6 | grep -q "verify-plan-intent-anchor.sh"
  ! skill_step_5_6 | grep -q "lore work regen-tasks"
}

@test "spec SKILL.md Step 5.6 retains the two lead-owned preflight asserts" {
  skill_step_5_6 | grep -q "live script"
  skill_step_5_6 | grep -q "Tier-2 emission instructions"
}

@test "spec SKILL.md Step 5.6 instructs fixing plan.md and re-running on refusal" {
  skill_step_5_6 | grep -qi "fix \`plan.md\`"
  skill_step_5_6 | grep -q "re-run"
}

# --- D4 protocol-terminus close-request --------------------------------------
# The post-telemetry step self-addresses a session close-request only inside a
# TUI-hosted session (LORE_SESSION_* set), best-effort, and never disturbs the
# verb's exit code, refusal semantics, or telemetry. session-close.sh --self
# writes the request into the isolated kdir; count those files to prove emission.

close_request_count() {
  local dir="$TEST_KDIR/_sessions/close-requests"
  if [ -d "$dir" ]; then
    find "$dir" -maxdepth 1 -name '*.json' | wc -l | tr -d ' '
  else
    echo 0
  fi
}

@test "finalize inside a TUI session emits one self-addressed close-request" {
  command -v jq >/dev/null 2>&1 || skip "jq required for session-close.sh"
  export LORE_SESSION_INSTANCE="tui-a1b2c3"
  export LORE_SESSION_SLUG="finalize-item"
  export LORE_SESSION_TYPE="spec"
  run bash "$LORE_CLI" spec finalize finalize-item
  [ "$status" -eq 0 ]
  [ "$(row_count)" -eq 1 ]
  [ "$(close_request_count)" -eq 1 ]
}

@test "finalize outside a session emits no close-request and still finalizes" {
  unset LORE_SESSION_INSTANCE LORE_SESSION_SLUG LORE_SESSION_TYPE
  run bash "$LORE_CLI" spec finalize finalize-item
  [ "$status" -eq 0 ]
  [ "$(row_count)" -eq 1 ]
  [ "$(close_request_count)" -eq 0 ]
  [ ! -d "$TEST_KDIR/_sessions/close-requests" ]
}

@test "a failing session-close.sh leaves the finalize exit code and telemetry untouched" {
  command -v jq >/dev/null 2>&1 || skip "jq required for session-close.sh"
  # Plant a regular file where session-close.sh expects to mkdir close-requests/,
  # forcing the real script to fail — no stub, a genuine failure condition.
  mkdir -p "$TEST_KDIR/_sessions"
  printf 'not-a-dir\n' > "$TEST_KDIR/_sessions/close-requests"
  export LORE_SESSION_INSTANCE="tui-a1b2c3"
  export LORE_SESSION_SLUG="finalize-item"
  export LORE_SESSION_TYPE="spec"
  run bash "$LORE_CLI" spec finalize finalize-item
  [ "$status" -eq 0 ]
  [ "$(row_count)" -eq 1 ]
  echo "$output" | grep -q "session close-request failed"
}

@test "a refused finalize (anchor gate, exit 3) emits no close-request inside a session" {
  # spec-finalize's exit 3 is a REFUSAL (anchor gate) reached before telemetry,
  # so the close-request step never runs — unlike impl-close, where exit 3 is a
  # completed divergence that does emit.
  make_item "divergent-item" "Deliver the true capability." \
    "A paraphrased anchor that diverges." v2
  export LORE_SESSION_INSTANCE="tui-a1b2c3"
  export LORE_SESSION_SLUG="divergent-item"
  export LORE_SESSION_TYPE="spec"
  run bash "$LORE_CLI" spec finalize divergent-item
  [ "$status" -eq 3 ]
  [ "$(row_count)" -eq 0 ]
  [ "$(close_request_count)" -eq 0 ]
}
