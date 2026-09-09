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

@test "shipped spawn snippets bind every canonical-route consumer placeholder" {
  run python3 -c 'import pathlib,re,sys; root=pathlib.Path(sys.argv[1]); worker=(root/"skills/implement/templates/worker-spawn.md").read_text(); advisor=(root/"skills/implement/templates/advisor-spawn.md").read_text(); session=(root/"agents/session-worker.md").read_text(); assert "--session-route \"$SESSION_ROUTE\"" in session; assert "SESSION_ROUTE=\x27{{session_route}}\x27" in session; assert "{{native_route}} set to $CODEX_ROUTE" in worker; assert "route_flags" in worker; assert re.search(r"ADVISOR_TOOL_FIELDS=.*native_tool_fields.*ADVISOR_ROUTE", advisor); assert "fields: \"$ADVISOR_TOOL_FIELDS\"" in advisor' "$REPO_DIR"
  [ "$status" -eq 0 ]
}

@test "role registry retains eight identities and fallback edges" {
  jq -e '(.roles | length) == 8 and ([.roles[].id] | sort) == (["advisor","default","lead","researcher","reviewer","worker","worker-judgment-dense","worker-mechanical"] | sort) and (.roles[] | select(.id == "worker-mechanical") | .fallback_role) == "worker" and (.roles[] | select(.id == "worker-judgment-dense") | .fallback_role) == "worker"' "$REPO_DIR/adapters/roles.json"
}
