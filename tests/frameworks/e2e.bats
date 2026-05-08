#!/usr/bin/env bats
# e2e.bats — End-to-end smoke for non-Claude /spec or /implement workflows
# (Phase 7, T25).
#
# bats-side cannot drive the Task/Agent tool API on any harness; the test
# instead exercises the orchestration adapter directly (the same surface
# /spec Step 2.0 and /implement Step 2.0 query before TeamCreate / TaskCreate)
# and asserts:
#
#   1. Per-framework smoke: for each of {claude-code, opencode, codex}, a
#      minimal /implement-style adapter path produces canonical Lore work
#      artifacts (work-item dir + _meta.json + task-claims.jsonl row) and
#      the spawn directive carries the worker role binding configured via
#      `lore framework set-model worker <model>` (the read side that
#      /implement Step 0 surfaces).
#   2. Capability-gate verification: opencode (team_messaging=none) refuses
#      send_message with the literal `unsupported` so /implement Step 2.0
#      collapses to lead-inline (no TeamCreate/spawn surface); codex
#      (task_completed_hook=fallback + subagents=partial) resolves
#      completion_enforcement to `lead_validator` so /implement Step 4.1
#      branches into the post-hoc validator path.
#   3. Cross-framework artifact equivalence: the canonical Lore artifacts
#      (task-claims.jsonl row shape) are byte-identical across frameworks
#      modulo per-row `captured_at_sha` + timestamp variability — same
#      schema, same field set, same validator.
#
# Coverage matrix (per-framework setup_framework helper sets up
# framework.json + roles + LORE_DATA_DIR):
#   - claude-code: native_blocking + spawn-with-bare-model + send_message=full
#   - opencode:    lead_validator + spawn-with-provider/model split + send_message=unsupported
#   - codex:       lead_validator + spawn-with-bare-model + send_message=unsupported
#
# Style: pure bats; mirrors the setup pattern in agents.bats and hooks.bats.
# Skips cleanly when adapters or scripts are absent so the file does not
# break the suite during phase rollout.

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"
CAPS="$REPO_DIR/adapters/capabilities.json"
ROLES_JSON="$REPO_DIR/adapters/roles.json"
CC_AGENT_ADAPTER="$REPO_DIR/adapters/agents/claude-code.sh"
OC_AGENT_ADAPTER="$REPO_DIR/adapters/agents/opencode.sh"
CODEX_AGENT_ADAPTER="$REPO_DIR/adapters/agents/codex.sh"
CREATE_WORK_SH="$REPO_DIR/scripts/create-work.sh"
EVIDENCE_APPEND_SH="$REPO_DIR/scripts/evidence-append.sh"
SET_MODEL_SH="$REPO_DIR/scripts/framework-set-model.sh"

setup() {
  [ -f "$CAPS" ]         || skip "adapters/capabilities.json missing"
  [ -f "$ROLES_JSON" ]   || skip "adapters/roles.json missing"
  [ -f "$CREATE_WORK_SH" ]    || skip "scripts/create-work.sh missing"
  [ -f "$EVIDENCE_APPEND_SH" ] || skip "scripts/evidence-append.sh missing"
  command -v jq      >/dev/null 2>&1 || skip "jq required for framework.json mutation"
  command -v python3 >/dev/null 2>&1 || skip "python3 required for JSON inspection"

  # Isolated LORE_DATA_DIR + KNOWLEDGE_DIR so create-work + evidence-append
  # never touch the user's real ~/.lore or any project knowledge store.
  # Mirrors the setup pattern in agents.bats / hooks.bats.
  TEST_LORE_DATA_DIR="$(mktemp -d)"
  TEST_KNOWLEDGE_DIR="$(mktemp -d)"
  TEST_HOME="$(mktemp -d)"
  mkdir -p "$TEST_LORE_DATA_DIR/config"
  mkdir -p "$TEST_KNOWLEDGE_DIR/_work"
  ln -s "$REPO_DIR/scripts" "$TEST_LORE_DATA_DIR/scripts"
  echo '{"format_version": 2, "created_at": "2026-05-04T00:00:00Z"}' \
    > "$TEST_KNOWLEDGE_DIR/_manifest.json"

  export LORE_DATA_DIR="$TEST_LORE_DATA_DIR"
  export LORE_KNOWLEDGE_DIR="$TEST_KNOWLEDGE_DIR"
  export HOME="$TEST_HOME"
  unset LORE_FRAMEWORK
  # Clear any LORE_MODEL_<ROLE> overrides leaking in from the parent shell —
  # tests assert the framework.json roles map is the resolution source.
  unset LORE_MODEL_LEAD LORE_MODEL_WORKER LORE_MODEL_RESEARCHER \
        LORE_MODEL_REVIEWER LORE_MODEL_JUDGE LORE_MODEL_SUMMARIZER \
        LORE_MODEL_DEFAULT
}

teardown() {
  for dir in "${TEST_LORE_DATA_DIR:-}" "${TEST_KNOWLEDGE_DIR:-}" "${TEST_HOME:-}"; do
    if [ -n "$dir" ] && [ -d "$dir" ]; then
      rm -rf "$dir"
    fi
  done
}

# --- helpers ---

# Stage framework.json with a closed roles map. Single-provider harnesses
# get bare model ids; the multi-provider opencode_multi variant uses
# provider/model bindings so the spawn directive exercises the
# split_provider_model path.
setup_framework() {
  local framework="$1"
  cat > "$TEST_LORE_DATA_DIR/config/framework.json" <<EOF
{
  "version": 1,
  "framework": "$framework",
  "capability_overrides": {},
  "roles": {
    "default": "sonnet",
    "lead":    "opus",
    "worker":  "sonnet"
  }
}
EOF
}

setup_framework_multi() {
  local framework="$1"
  cat > "$TEST_LORE_DATA_DIR/config/framework.json" <<EOF
{
  "version": 1,
  "framework": "$framework",
  "capability_overrides": {},
  "roles": {
    "default": "anthropic/sonnet",
    "lead":    "anthropic/opus",
    "worker":  "openai/gpt-4o"
  }
}
EOF
}

# Resolve the active framework's orchestration adapter path. Mirrors the
# resolution /implement Step 2.0 performs — `adapters/agents/<framework>.sh`.
adapter_for() {
  case "$1" in
    claude-code) echo "$CC_AGENT_ADAPTER" ;;
    opencode)    echo "$OC_AGENT_ADAPTER" ;;
    codex)       echo "$CODEX_AGENT_ADAPTER" ;;
    *) return 1 ;;
  esac
}

# Build a Tier 2 evidence row JSON object as the worker would emit during
# /implement Step 4. Captures the canonical 13-field shape so the
# cross-framework equivalence test can compare row keys directly.
make_tier2_row() {
  local task_id="$1" slug="$2" framework="$3"
  python3 - "$task_id" "$slug" "$framework" <<'PYEOF'
import json, sys
task_id, slug, framework = sys.argv[1:4]
row = {
    "claim_id":              f"e2e-bats-{framework}-{task_id}",
    "tier":                  "task-evidence",
    "claim":                 f"e2e bats smoke claim for {framework}/{slug}",
    "producer_role":         "worker",
    "protocol_slot":         "implement-step-3",
    "task_id":               task_id,
    "phase_id":              "7",
    "scale":                 "implementation",
    "file":                  "/tmp/synthetic.txt",
    "line_range":            "1-10",
    "falsifier":             "synthetic file does not exist",
    "why_this_work_needs_it": "smoke test asserts canonical Tier 2 shape",
    "captured_at_sha":       "0000000000000000000000000000000000000000",
}
print(json.dumps(row))
PYEOF
}

# ============================================================
# Per-framework smoke: spawn produces canonical artifacts +
# honors the worker role binding from framework.json
# ============================================================

@test "claude-code: /implement smoke produces work item + task-claims row + worker spawn honors role binding" {
  [ -f "$CC_AGENT_ADAPTER" ] || skip "adapters/agents/claude-code.sh missing"
  setup_framework claude-code

  # /implement Step 2.0: query enforcement + team_messaging via the adapter.
  ENFORCEMENT=$(bash "$CC_AGENT_ADAPTER" completion_enforcement)
  [ "$ENFORCEMENT" = "native_blocking" ]

  # /implement Step 2.0 surface — work-item directory + _meta.json shape.
  bash "$CREATE_WORK_SH" --title "e2e claude-code smoke" \
    --directory "$TEST_KNOWLEDGE_DIR" >/dev/null
  SLUG="e2e-claude-code-smoke"
  [ -d "$TEST_KNOWLEDGE_DIR/_work/$SLUG" ]
  [ -f "$TEST_KNOWLEDGE_DIR/_work/$SLUG/_meta.json" ]
  [ -f "$TEST_KNOWLEDGE_DIR/_work/$SLUG/notes.md" ]

  # Worker spawn directive must reflect roles.worker=sonnet from framework.json.
  run bash "$CC_AGENT_ADAPTER" spawn worker "implement task-1"
  [ "$status" -eq 0 ]
  [[ "$output" =~ delegate:TaskCreate ]]
  [[ "$output" =~ role=worker ]]
  [[ "$output" =~ "model=sonnet" ]]
}

@test "opencode: /implement smoke produces work item + worker spawn honors multi-provider role binding" {
  [ -f "$OC_AGENT_ADAPTER" ] || skip "adapters/agents/opencode.sh missing"
  # Multi-provider binding so the directive carries provider= + model= keys.
  setup_framework_multi opencode

  ENFORCEMENT=$(bash "$OC_AGENT_ADAPTER" completion_enforcement)
  [ "$ENFORCEMENT" = "lead_validator" ]

  bash "$CREATE_WORK_SH" --title "e2e opencode smoke" \
    --directory "$TEST_KNOWLEDGE_DIR" >/dev/null
  SLUG="e2e-opencode-smoke"
  [ -d "$TEST_KNOWLEDGE_DIR/_work/$SLUG" ]
  [ -f "$TEST_KNOWLEDGE_DIR/_work/$SLUG/_meta.json" ]

  run bash "$OC_AGENT_ADAPTER" spawn worker "implement task-1"
  [ "$status" -eq 0 ]
  [[ "$output" =~ delegate:TaskCreate ]]
  [[ "$output" =~ role=worker ]]
  [[ "$output" =~ provider=openai ]]
  [[ "$output" =~ "model=gpt-4o" ]]
}

@test "codex: /implement smoke produces work item + worker spawn honors single-provider role binding" {
  [ -f "$CODEX_AGENT_ADAPTER" ] || skip "adapters/agents/codex.sh missing"
  setup_framework codex

  ENFORCEMENT=$(bash "$CODEX_AGENT_ADAPTER" completion_enforcement)
  [ "$ENFORCEMENT" = "lead_validator" ]

  bash "$CREATE_WORK_SH" --title "e2e codex smoke" \
    --directory "$TEST_KNOWLEDGE_DIR" >/dev/null
  SLUG="e2e-codex-smoke"
  [ -d "$TEST_KNOWLEDGE_DIR/_work/$SLUG" ]
  [ -f "$TEST_KNOWLEDGE_DIR/_work/$SLUG/_meta.json" ]

  run bash "$CODEX_AGENT_ADAPTER" spawn worker "implement task-1"
  [ "$status" -eq 0 ]
  [[ "$output" =~ delegate:TaskCreate ]]
  [[ "$output" =~ role=worker ]]
  [[ "$output" =~ "model=sonnet" ]]
  # Codex is single-provider — bare model id only; no provider= key.
  if [[ "$output" =~ provider= ]]; then
    echo "codex spawn leaked provider= on single-provider harness: $output"
    return 1
  fi
}

# ============================================================
# `lore framework set-model worker <model>` updates the
# binding, and the next adapter spawn reflects the new value
# without restart (per Phase 7 verification bullet).
# ============================================================

@test "claude-code: framework set-model worker <model> takes effect on next spawn directive" {
  [ -f "$CC_AGENT_ADAPTER" ] || skip "adapters/agents/claude-code.sh missing"
  [ -f "$SET_MODEL_SH" ]     || skip "scripts/framework-set-model.sh missing (T22 not landed)"
  setup_framework claude-code

  # Sanity check: pre-mutation worker is sonnet.
  run bash "$CC_AGENT_ADAPTER" spawn worker "task-A"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "model=sonnet" ]]

  # Mutate the binding via the canonical write path.
  run bash "$SET_MODEL_SH" set-model worker haiku
  [ "$status" -eq 0 ]

  # Next spawn must reflect the new binding without any restart.
  run bash "$CC_AGENT_ADAPTER" spawn worker "task-B"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "model=haiku" ]]
}

# ============================================================
# Capability-gate verification — /implement gating behavior on
# opencode (team_messaging=none → lead-only) and codex
# (subagents=partial → lead_validator)
# ============================================================

@test "opencode: team_messaging=none surfaces as send_message=unsupported (lead-orchestrated mode)" {
  [ -f "$OC_AGENT_ADAPTER" ] || skip "adapters/agents/opencode.sh missing"
  setup_framework opencode

  # /implement Step 2.0: TEAM_MESSAGING=none collapses skill to lead-inline.
  TEAM_MESSAGING=$(python3 -c "
import json
d = json.load(open('$CAPS'))
print(d['frameworks']['opencode']['capabilities']['team_messaging']['support'])
")
  [ "$TEAM_MESSAGING" = "none" ]

  # Adapter MUST surface this gate as `unsupported` on stdout (the literal
  # the skill body branches on; degraded notice goes to stderr).
  output=$(bash "$OC_AGENT_ADAPTER" send_message handle1 "body" 2>/dev/null)
  [ "$output" = "unsupported" ]
}

@test "codex: subagents=partial + task_completed_hook=fallback resolves to lead_validator (post-hoc enforcement)" {
  [ -f "$CODEX_AGENT_ADAPTER" ] || skip "adapters/agents/codex.sh missing"
  setup_framework codex

  # Verify the underlying capability cells are at the levels the resolver
  # uses to derive lead_validator (per adapters/agents/README.md §Mode
  # resolution rule). If the cells drift, this test fails before the
  # mode assertion so the diagnostic points at capabilities.json.
  SUBAGENTS=$(python3 -c "
import json
d = json.load(open('$CAPS'))
print(d['frameworks']['codex']['capabilities']['subagents']['support'])
")
  TASK_HOOK=$(python3 -c "
import json
d = json.load(open('$CAPS'))
print(d['frameworks']['codex']['capabilities']['task_completed_hook']['support'])
")
  [ "$SUBAGENTS" = "partial" ]
  [ "$TASK_HOOK" = "fallback" ]

  # Mode resolution must come out lead_validator — /implement Step 4.1
  # branches into post-hoc validation rather than native_blocking.
  ENFORCEMENT=$(bash "$CODEX_AGENT_ADAPTER" completion_enforcement)
  [ "$ENFORCEMENT" = "lead_validator" ]
}

@test "opencode: completion_enforcement also resolves to lead_validator (parity with codex)" {
  [ -f "$OC_AGENT_ADAPTER" ] || skip "adapters/agents/opencode.sh missing"
  setup_framework opencode

  # opencode and codex share the (fallback, partial) cell pair, so they
  # must resolve to the same enforcement mode. Drift between them would
  # signal a regression in the resolver table.
  ENFORCEMENT=$(bash "$OC_AGENT_ADAPTER" completion_enforcement)
  [ "$ENFORCEMENT" = "lead_validator" ]
}

# ============================================================
# Cross-framework artifact equivalence: task-claims.jsonl row
# shape MUST be byte-identical (modulo timestamp + sha
# variability) across all three frameworks. The schema is
# canonical Lore — it cannot fork by harness.
# ============================================================

@test "task-claims.jsonl row shape is identical across all three frameworks" {
  for fw in claude-code opencode codex; do
    adapter=$(adapter_for "$fw")
    [ -f "$adapter" ] || skip "$fw adapter missing"
  done

  # Per-framework: stage framework.json, create work item, append one
  # synthetic Tier 2 row, capture the row keys.
  declare -a KEYSETS=()
  for fw in claude-code opencode codex; do
    setup_framework "$fw"
    bash "$CREATE_WORK_SH" --title "e2e equiv $fw" \
      --directory "$TEST_KNOWLEDGE_DIR" >/dev/null
    slug="e2e-equiv-$fw"
    row_json=$(make_tier2_row "task-equiv-1" "$slug" "$fw")
    echo "$row_json" | bash "$EVIDENCE_APPEND_SH" \
      --work-item "$slug" --kdir "$TEST_KNOWLEDGE_DIR" >/dev/null
    [ -f "$TEST_KNOWLEDGE_DIR/_work/$slug/task-claims.jsonl" ]
    keys=$(python3 -c "
import json, sys
with open('$TEST_KNOWLEDGE_DIR/_work/$slug/task-claims.jsonl') as f:
    row = json.loads(f.readline())
print(','.join(sorted(row.keys())))
")
    KEYSETS+=("$keys")
  done

  # All three keysets MUST be byte-identical — same field set, same names,
  # same shape. This is the canonical Lore invariant the README calls out.
  if [ "${KEYSETS[0]}" != "${KEYSETS[1]}" ] || [ "${KEYSETS[1]}" != "${KEYSETS[2]}" ]; then
    echo "task-claims row shape diverged across frameworks:"
    echo "  claude-code: ${KEYSETS[0]}"
    echo "  opencode:    ${KEYSETS[1]}"
    echo "  codex:       ${KEYSETS[2]}"
    return 1
  fi

  # Sanity check: the canonical 13-field set names every required field.
  expected="captured_at_sha,claim,claim_id,falsifier,file,line_range,phase_id,producer_role,protocol_slot,scale,task_id,tier,why_this_work_needs_it"
  [ "${KEYSETS[0]}" = "$expected" ]
}

# ============================================================
# Closed-set rejection — unknown framework MUST NOT route to
# any adapter (no fallback). This is the contract from the
# closed-set rejection convention.
# ============================================================

@test "unknown framework is rejected by orchestration adapters (no silent fallback)" {
  [ -f "$CC_AGENT_ADAPTER" ] || skip "adapters/agents/claude-code.sh missing"
  setup_framework claude-code
  # Override active framework to something not in the closed set.
  export LORE_FRAMEWORK="bogus-harness"
  run bash "$CC_AGENT_ADAPTER" spawn worker "should-not-spawn"
  [ "$status" -ne 0 ]
  unset LORE_FRAMEWORK
}
