#!/usr/bin/env bats

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"

@test "documented canonical route projects through the Codex adapter" {
  local route='{"framework":"codex","model":"gpt-5.6-sol","options":{"effort":"high","service_tier":"fast"},"routing_source":{"layer":"routes","role":"worker"}}'
  run bash "$REPO_DIR/adapters/agents/codex.sh" route_flags "$route"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '. == ["-m","gpt-5.6-sol","-c","model_reasoning_effort=\"high\"","-c","service_tier=\"fast\""]'
}

@test "native Claude resolution keeps its native model when the global advisor route is Codex" {
  local data; data="$(mktemp -d)"
  mkdir -p "$data/config"
  ln -s "$REPO_DIR/scripts" "$data/scripts"
  printf '%s\n' '{"version":2,"tui_launch_framework":"claude-code","routes":{"default":"claude-code/sonnet","advisor":"codex/gpt-6-astra-high"},"harnesses":{"claude-code":{"args":[],"native_models":{"default":"opus"}},"codex":{"args":[],"native_models":{"default":"gpt-5.5-high"}}}}' > "$data/config/settings.json"
  run env LORE_DATA_DIR="$data" LORE_FRAMEWORK=claude-code bash -c 'source "$1/scripts/lib.sh"; resolve_native_route_for_role advisor implement claude-code' _ "$REPO_DIR"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.framework == "claude-code" and .model == "opus" and .routing_source.layer == "native-models"'
}

@test "shipped native assignment lines execute without compiled-only inputs" {
  local data; data="$(mktemp -d)"
  mkdir -p "$data/config"
  ln -s "$REPO_DIR/scripts" "$data/scripts"
  printf '%s\n' '{"version":2,"tui_launch_framework":"claude-code","routes":{"default":"claude-code/sonnet","worker":"claude-code/opus","advisor":"claude-code/opus","reviewer":"claude-code/opus"},"harnesses":{"claude-code":{"args":[],"native_models":{"default":"opus"}}}}' > "$data/config/settings.json"
  run env LORE_DATA_DIR="$data" LORE_FRAMEWORK=claude-code REPO_DIR="$REPO_DIR" bash -c '
    source "$REPO_DIR/scripts/lib.sh"
    FRAMEWORK=claude-code; WORKER_ROLE=worker; ADAPTER="$REPO_DIR/adapters/agents/claude-code.sh"
    eval "$(grep -m1 "^WORKER_NATIVE_ROUTE=" "$REPO_DIR/skills/implement/templates/worker-spawn.md")"
    eval "$(grep -m1 "^WORKER_TOOL_FIELDS=" "$REPO_DIR/skills/implement/templates/worker-spawn.md")"
    eval "$(grep -m1 "^ADVISOR_ROUTE=" "$REPO_DIR/skills/implement/templates/advisor-spawn.md")"
    eval "$(grep -m1 "^ADVISOR_TOOL_FIELDS=" "$REPO_DIR/skills/implement/templates/advisor-spawn.md")"
    LENS_FRAMEWORK=claude-code
    eval "$(grep -m1 "^LENS_ROUTE=" "$REPO_DIR/skills/pr-review/SKILL.md")"
    eval "$(grep -m1 "^LENS_TOOL_FIELDS=" "$REPO_DIR/skills/pr-review/SKILL.md")"
    [[ "$(jq -r .model <<<"$WORKER_TOOL_FIELDS")" == opus ]]
    [[ "$(jq -r .model <<<"$ADVISOR_TOOL_FIELDS")" == opus ]]
    [[ "$(jq -r .model <<<"$LENS_TOOL_FIELDS")" == opus ]]
  '
  [ "$status" -eq 0 ]
}

@test "shipped session request block forwards canonical route as one argument" {
  local block route
  route='{"framework":"codex","model":"gpt-5.6-sol","options":{"effort":"high","service_tier":"fast"},"routing_source":{"layer":"routes","role":"worker"}}'
  block="$(awk '/^if \[\[ "$DISPATCH_ROUTE" == "compiled" \]\]; then$/{emit=1} emit{print} /^ENQUEUE_RC=/{exit}' "$REPO_DIR/agents/session-worker.md")"
  run env BLOCK="$block" EXPECTED_ROUTE="$route" bash -c '
    lore() {
      if [[ "$1 $2" == "session events" ]]; then
        printf "%s\n" "{\"next_cursor\":0}"
      else
        args=("$@")
        for ((i=0; i<${#args[@]}; i++)); do
          if [[ "${args[i]}" == --session-route ]]; then [[ "${args[i+1]}" == "$EXPECTED_ROUTE" ]] || return 9; found=1; fi
        done
        [[ "${found:-}" == 1 ]] || return 8
      fi
    }
    DISPATCH_ROUTE=legacy; DERIVED_SLUG=w1; SESSION_ROUTE='"'"'{"framework":"codex","model":"gpt-5.6-sol","options":{"effort":"high","service_tier":"fast"},"routing_source":{"layer":"routes","role":"worker"}}'"'"'; BRIEF_FILE=/tmp/brief
    printf x > "$BRIEF_FILE"
    eval "$BLOCK"
  '
  [ "$status" -eq 0 ]
}

@test "role registry retains eight identities and fallback edges" {
  jq -e '(.roles | length) == 8 and ([.roles[].id] | sort) == (["advisor","default","lead","researcher","reviewer","worker","worker-judgment-dense","worker-mechanical"] | sort) and (.roles[] | select(.id == "worker-mechanical") | .fallback_role) == "worker" and (.roles[] | select(.id == "worker-judgment-dense") | .fallback_role) == "worker"' "$REPO_DIR/adapters/roles.json"
}
