#!/usr/bin/env bats

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"
CORPUS="$REPO_DIR/tests/fixtures/route-parity.json"

setup_file() {
  source "$REPO_DIR/scripts/lib.sh"
  ensure_yaml_python
  command -v python3 >/dev/null || return 1
  command -v jq >/dev/null || return 1
  command -v go >/dev/null || return 1
  python3 -c 'import jsonschema' || return 1
  ROUTE_PARITY_DIR="$(mktemp -d)"
  export GOCACHE=/tmp/routes-task9-gocache
  mkdir -p "$ROUTE_PARITY_DIR/config"
  ln -s "$REPO_DIR/scripts" "$ROUTE_PARITY_DIR/scripts"
  cp "$REPO_DIR/adapters/settings.template.json" "$ROUTE_PARITY_DIR/config/settings.json"
  (cd "$REPO_DIR/tui" && go build -o "$ROUTE_PARITY_DIR/parity-harness" ./internal/config/cmd/parity-harness) || return 1
  export ROUTE_PARITY_DIR
}

teardown_file() { rm -rf "${ROUTE_PARITY_DIR:?}"; }

python_request() {
  printf '%s' "$1" | python3 "$REPO_DIR/scripts/route_config.py"
}

@test "golden parse corpus matches Python CLI and Go canonical client" {
  export LORE_DATA_DIR="$ROUTE_PARITY_DIR"
  while IFS= read -r row; do
    input="$(jq -c '.input' <<<"$row")"
    expected="$(jq -cS '.expected' <<<"$row")"
    request="$(jq -cn --arg root "$REPO_DIR" --argjson route "$input" '{operation:"parse",repo_root:$root,route:$route}')"
    py="$(python_request "$request" | jq -ceS 'select(.ok).result')"
    go="$($ROUTE_PARITY_DIR/parity-harness parse_route "$input" | jq -cS '.')"
    [ "$py" = "$expected" ]
    [ "$go" = "$expected" ]
    api="$(python3 - "$REPO_DIR" "$input" <<'PY'
import importlib.util, json, sys
spec=importlib.util.spec_from_file_location('route_config', sys.argv[1]+'/scripts/route_config.py')
mod=importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
print(json.dumps(mod.parse_route(json.loads(sys.argv[2]), sys.argv[1]), sort_keys=True, separators=(',', ':')))
PY
)"
    [ "$api" = "$expected" ]
  done < <(jq -c '.parse[]' "$CORPUS")
}

@test "golden refusal corpus reports exact Python code and path and Go refuses" {
  export LORE_DATA_DIR="$ROUTE_PARITY_DIR"
  while IFS= read -r row; do
    input="$(jq -c '.input' <<<"$row")"
    expected="$(jq -c '{code,path}' <<<"$row")"
    request="$(jq -cn --arg root "$REPO_DIR" --argjson route "$input" '{operation:"parse",repo_root:$root,route:$route}')"
    run python_request "$request"
    [ "$status" -eq 2 ]
    [ "$(jq -c '.error|{code,path}' <<<"$output")" = "$expected" ]
    run "$ROUTE_PARITY_DIR/parity-harness" parse_route "$input"
    [ "$status" -ne 0 ]
    [[ "$output" == *"$(jq -r .code <<<"$row") at $(jq -r .path <<<"$row")"* ]]
  done < <(jq -c '.errors[]' "$CORPUS")
}

@test "golden flag corpus matches both actual adapter projectors and Go" {
  export LORE_DATA_DIR="$ROUTE_PARITY_DIR"
  while IFS= read -r row; do
    route="$(jq -c '.route' <<<"$row")"
    framework="$(jq -r '.route.framework' <<<"$row")"
    expected="$(jq -c '.expected' <<<"$row")"
    shell="$(bash "$REPO_DIR/adapters/agents/$framework.sh" route_flags "$route")"
    go="$($ROUTE_PARITY_DIR/parity-harness route_flags "$route")"
    [ "$shell" = "$expected" ]
    [ "$go" = "$expected" ]
  done < <(jq -c '.flags[]' "$CORPUS")
}

@test "global and native resolution preserve precedence and affinity across Python Bash and Go" {
  export LORE_DATA_DIR="$ROUTE_PARITY_DIR"
  jq '.routes.worker={framework:"codex",model:"gpt-5.6-sol",effort:"high",service_tier:"fast"}
      | .routes.ceremony_overlays.spec.lead="opencode/anthropic/opus"
      | del(.routes["worker-mechanical"], .routes.advisor)
      | .harnesses["claude-code"].native_models.worker="sonnet"' \
    "$REPO_DIR/adapters/settings.template.json" > "$ROUTE_PARITY_DIR/config/settings.json"
  while IFS= read -r row; do
    role="$(jq -r .role <<<"$row")"; ceremony="$(jq -r '.ceremony // ""' <<<"$row")"
    expected="$(jq -cS .expected <<<"$row")"
    request="$(jq -cn --arg root "$REPO_DIR" --arg settings "$ROUTE_PARITY_DIR/config/settings.json" --arg role "$role" --arg ceremony "$ceremony" '{operation:"resolve",repo_root:$root,settings_path:$settings,role:$role} + (if $ceremony != "" then {ceremony:$ceremony} else {} end)')"
    py="$(python_request "$request" | jq -ceS '.result')"
    bash_route="$(bash -c "source '$REPO_DIR/scripts/lib.sh'; resolve_route_for_role '$role' '$ceremony'" | jq -cS '.')"
    go_route="$($ROUTE_PARITY_DIR/parity-harness resolve_canonical_route "$role" "$ceremony" | jq -cS '.')"
    [ "$py" = "$expected" ]; [ "$bash_route" = "$expected" ]; [ "$go_route" = "$expected" ]
  done < <(jq -c '.resolve[]' "$CORPUS")

  while IFS= read -r row; do
    role="$(jq -r .role <<<"$row")"; ceremony="$(jq -r '.ceremony // ""' <<<"$row")"; parent="$(jq -r .harness <<<"$row")"
    expected="$(jq -cS .expected <<<"$row")"
    native_request="$(jq -cn --arg root "$REPO_DIR" --arg settings "$ROUTE_PARITY_DIR/config/settings.json" --arg role "$role" --arg ceremony "$ceremony" --arg harness "$parent" '{operation:"native",repo_root:$root,settings_path:$settings,role:$role,harness:$harness} + (if $ceremony != "" then {ceremony:$ceremony} else {} end)')"
    [ "$(python_request "$native_request" | jq -ceS '.result')" = "$expected" ]
    [ "$(bash -c "source '$REPO_DIR/scripts/lib.sh'; resolve_native_route_for_role '$role' '$ceremony' '$parent'" | jq -cS '.')" = "$expected" ]
    [ "$($ROUTE_PARITY_DIR/parity-harness resolve_native_canonical_route "$role" "$parent" "$ceremony" | jq -cS '.')" = "$expected" ]
  done < <(jq -c '.native[]' "$CORPUS")
}

@test "environment and repository precedence remain source-independent" {
  export LORE_DATA_DIR="$ROUTE_PARITY_DIR"
  jq '.routes.worker={framework:"codex",model:"gpt-5.6-sol",effort:"high"}' "$REPO_DIR/adapters/settings.template.json" > "$ROUTE_PARITY_DIR/config/settings.json"
  for source in claude-code codex opencode; do
    export LORE_FRAMEWORK="$source" LORE_MODEL_WORKER=opencode/openai/gpt-5
    expected='{"framework":"opencode","model":"openai/gpt-5","options":{},"routing_source":{"layer":"env","role":"worker"}}'
    request="$(jq -cn --arg root "$REPO_DIR" --arg settings "$ROUTE_PARITY_DIR/config/settings.json" --arg route "$LORE_MODEL_WORKER" '{operation:"resolve",repo_root:$root,settings_path:$settings,role:"worker",env:{LORE_MODEL_WORKER:$route}}')"
    [ "$(python_request "$request" | jq -cS '.result')" = "$(jq -cS . <<<"$expected")" ]
    [ "$(bash -c "source '$REPO_DIR/scripts/lib.sh'; resolve_route_for_role worker" | jq -cS .)" = "$(jq -cS . <<<"$expected")" ]
    [ "$($ROUTE_PARITY_DIR/parity-harness resolve_canonical_route worker | jq -cS .)" = "$(jq -cS . <<<"$expected")" ]
  done
  unset LORE_MODEL_WORKER
  mkdir -p "$ROUTE_PARITY_DIR/project/child"
  printf 'model_for_worker="claude-code/sonnet" # retained comment\n' > "$ROUTE_PARITY_DIR/project/.lore.config"
  expected='{"framework":"claude-code","model":"sonnet","options":{},"routing_source":{"layer":"per-repo","role":"worker"}}'
  request="$(jq -cn --arg root "$REPO_DIR" --arg settings "$ROUTE_PARITY_DIR/config/settings.json" --arg cwd "$ROUTE_PARITY_DIR/project/child" '{operation:"resolve",repo_root:$root,settings_path:$settings,cwd:$cwd,role:"worker",env:{}}')"
  [ "$(python_request "$request" | jq -cS '.result')" = "$(jq -cS . <<<"$expected")" ]
  [ "$(cd "$ROUTE_PARITY_DIR/project/child" && bash -c "source '$REPO_DIR/scripts/lib.sh'; resolve_route_for_role worker" | jq -cS .)" = "$(jq -cS . <<<"$expected")" ]
  [ "$(cd "$ROUTE_PARITY_DIR/project/child" && "$ROUTE_PARITY_DIR/parity-harness" resolve_canonical_route worker | jq -cS .)" = "$(jq -cS . <<<"$expected")" ]
}

@test "missing helper and registry fail closed and registry mutation invalidates stale schema" {
  export LORE_DATA_DIR="$ROUTE_PARITY_DIR"
  broken="$(mktemp -d)"; mkdir -p "$broken/adapters" "$broken/scripts"
  cp "$REPO_DIR/scripts/route_config.py" "$broken/scripts/"
  cp "$REPO_DIR/scripts/lib.sh" "$broken/scripts/"
  cp "$REPO_DIR/adapters/"{capabilities,roles,ceremonies,settings.schema}.json "$broken/adapters/"
  mkdir -p "$broken/adapters/agents"
  cp "$REPO_DIR/adapters/agents/codex.sh" "$broken/adapters/agents/"
  jq '.frameworks.codex.model_routing.options.verbosity=["brief"]' "$broken/adapters/capabilities.json" > "$broken/adapters/c" && mv "$broken/adapters/c" "$broken/adapters/capabilities.json"
  run python3 "$REPO_DIR/scripts/generate-route-schema.py" --check --repo-root "$broken"
  [ "$status" -ne 0 ]
  request="$(jq -cn --arg root "$broken" '{operation:"parse",repo_root:$root,route:{framework:"codex",model:"gpt-5.5",options:{verbosity:"brief"}}}')"
  run python_request "$request"
  [ "$status" -eq 2 ]
  [ "$(jq -r '.error.code' <<<"$output")" = unknown_route_field ]
  route='{"framework":"codex","model":"gpt-5.5","options":{"verbosity":"brief"}}'
  run bash "$broken/adapters/agents/codex.sh" route_flags "$route"
  [ "$status" -ne 0 ]
  mkdir -p "$broken/config"
  cp "$REPO_DIR/adapters/settings.template.json" "$broken/config/settings.json"
  run env LORE_DATA_DIR="$broken" "$ROUTE_PARITY_DIR/parity-harness" route_flags "$route"
  [ "$status" -ne 0 ]

  printf '{malformed\n' > "$broken/adapters/capabilities.json"
  run python_request "$(jq -cn --arg root "$broken" '{operation:"parse",repo_root:$root,route:"codex/gpt-5.5"}')"
  [ "$status" -eq 2 ]
  [ "$(jq -r '.error.code' <<<"$output")" = registry_unavailable ]
  cp "$REPO_DIR/adapters/capabilities.json" "$broken/adapters/capabilities.json"
  rm "$broken/adapters/roles.json"
  run python_request "$(jq -cn --arg root "$broken" '{operation:"parse",repo_root:$root,route:"codex/gpt-5.5"}')"
  [ "$status" -eq 2 ]
  [ "$(jq -r '.error.code' <<<"$output")" = registry_unavailable ]
  rm "$broken/scripts/route_config.py"
  run env LORE_DATA_DIR="$broken" "$ROUTE_PARITY_DIR/parity-harness" parse_route '"codex/gpt-5.5-high"'
  [ "$status" -ne 0 ]
}

@test "invalid unused settings remain visible behind an environment override" {
  export LORE_DATA_DIR="$ROUTE_PARITY_DIR"
  jq '.harnesses.codex.native_models.worker=[]' "$REPO_DIR/adapters/settings.template.json" > "$ROUTE_PARITY_DIR/config/settings.json"
  export LORE_MODEL_WORKER=codex/gpt-5.5-high
  run bash -c "source '$REPO_DIR/scripts/lib.sh'; resolve_route_for_role worker"
  [ "$status" -ne 0 ]

  jq '.routes.worker={framework:"codex",model:"gpt-5.5",effort:"bogus"}' "$REPO_DIR/adapters/settings.template.json" > "$ROUTE_PARITY_DIR/config/settings.json"
  run bash -c "source '$REPO_DIR/scripts/lib.sh'; resolve_route_for_role worker"
  [ "$status" -ne 0 ]

  jq '.harnesses["claude-code"].roles={default:"opus"}' "$REPO_DIR/adapters/settings.template.json" > "$ROUTE_PARITY_DIR/config/settings.json"
  run bash -c "source '$REPO_DIR/scripts/lib.sh'; resolve_route_for_role worker"
  [ "$status" -ne 0 ]
}

@test "native adapter refuses a canonical service tier it cannot transport" {
  fake="$(mktemp -d)"; printf '#!/bin/sh\nexit 0\n' > "$fake/codex"; chmod +x "$fake/codex"
  run env PATH="$fake:$PATH" bash "$REPO_DIR/adapters/agents/codex.sh" native_tool_fields '{"framework":"codex","model":"gpt-5.6-sol","options":{"service_tier":"fast"}}'
  [ "$status" -ne 0 ]
  [[ "$output" == *unsupported_native_option* || "$output" == *unsupported*service_tier* ]]
}
