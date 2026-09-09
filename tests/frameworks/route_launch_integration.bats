#!/usr/bin/env bats

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"
REQUEST="$REPO_DIR/scripts/session-request.sh"

setup() {
  command -v jq >/dev/null || return 1
  command -v python3 >/dev/null || return 1
  TEST_ROOT="$(mktemp -d)"
  export LORE_DATA_DIR="$TEST_ROOT/data"
  export LORE_SESSION_INSTANCE="route-integration-test"
  mkdir -p "$LORE_DATA_DIR/config" "$LORE_DATA_DIR/coordination" "$TEST_ROOT/kdir/_work/demo"
  ln -s "$REPO_DIR/scripts" "$LORE_DATA_DIR/scripts"
  cp "$REPO_DIR/adapters/settings.template.json" "$LORE_DATA_DIR/config/settings.json"
  jq -cn --arg checkout "$REPO_DIR" '{schema_version:1,slug:"demo",title:"Demo",status:"active",source_checkout:$checkout}' > "$TEST_ROOT/kdir/_work/demo/_meta.json"
  printf '{}\n' > "$TEST_ROOT/kdir/_work/demo/tasks.json"
  mkdir -p "$TEST_ROOT/kdir/_sessions/instances"
  jq -cn --arg checkout "$REPO_DIR" '{name:"route-fixture-host",pid:4242,repo:"lore",started:"2026-09-09T00:00:00Z",initiator_default:"human",project_dir:$checkout,sessions:[]}' > "$TEST_ROOT/kdir/_sessions/instances/route-fixture-host.json"
}

teardown() { rm -rf "${TEST_ROOT:?}"; }

pending_row() { jq -c '.' "$(ls -t "$TEST_ROOT/kdir/_sessions/requests/pending"/*.json | head -1)"; }

@test "option floor equals the composed route-aware source vintage" {
  floor="$(TZ=UTC git -C "$REPO_DIR" show -s --date=format-local:'%Y-%m-%dT%H:%M:%SZ' --format='%cd' 6d55b308ee6f62ab357b8dc243b5feee59c01019)"
  [ "$floor" = 2026-09-09T01:27:42Z ]
  grep -q 'ROUTE_OPTIONS_VINTAGE="2026-09-09T01:27:42Z"' "$REQUEST"
}

@test "option-bearing request freezes route in row and event and raises vintage floor" {
  jq '.routes.worker={framework:"codex",model:"gpt-5.6-sol",effort:"high",service_tier:"fast"}' \
    "$REPO_DIR/adapters/settings.template.json" > "$LORE_DATA_DIR/config/settings.json"
  run bash "$REQUEST" --type worker --slug demo--w1 --context "compiled test brief" --anywhere --kdir "$TEST_ROOT/kdir" --yes --json
  [ "$status" -eq 0 ]
  row="$(pending_row)"
  event="$(tail -1 "$TEST_ROOT/kdir/_sessions/events.jsonl")"
  [ "$(jq -c '.route' <<<"$row")" = "$(jq -c '.route' <<<"$event")" ]
  [ "$(jq -r '.route.options.effort' <<<"$row")" = high ]
  [ "$(jq -r '.route.options.service_tier' <<<"$row")" = fast ]
  [ "$(jq -r '.min_vintage' <<<"$row")" = 2026-09-09T01:27:42Z ]
}

@test "caller floor is maximized with route-aware floor and empty options retain legacy omission" {
  run bash "$REQUEST" --type worker --slug demo--w1 --context "compiled test brief" --session-route codex/gpt-5.5-high --min-vintage 2026-01-01T00:00:00Z --anywhere --kdir "$TEST_ROOT/kdir" --yes --json
  [ "$status" -eq 0 ]
  [ "$(pending_row | jq -r '.min_vintage')" = 2026-09-09T01:27:42Z ]

  run bash "$REQUEST" --type spec --slug demo --session-route claude-code/opus --anywhere --kdir "$TEST_ROOT/kdir" --yes --json
  [ "$status" -eq 0 ]
  row="$(pending_row)"
  [ "$(jq 'has("min_vintage")' <<<"$row")" = false ]
}

@test "production queue, descriptor launch, direct enqueue and retry paths retain frozen options" {
  export GOCACHE=/tmp/routes-task9-gocache
  export PKG_CONFIG="$REPO_DIR/tui/internal/work/libghostty/pkg-config-shim.sh"
  run bash -c "cd '$REPO_DIR/tui' && go test ./internal/work -run 'TestStartTerminalCmdCodexRouteOptionsReachActualArgv' && go test ./internal/session -run 'TestQueueTickMinVintage|TestClaimableByOptionRouteRequiresKnownVintage|TestReadRowRejectsUnknownCanonicalRouteFieldAndBadProjection' && go test . -run 'TestRouteRequestQueueDescriptorLaunchIntegration|TestEnqueueSessionUsesSoleWriterWithFrozenRoute|TestDirectEnqueueCompletionPreservesClaimedPanelAndRefusesPhantom' && cd '$REPO_DIR' && python3 -m unittest tests.test_session_managed_routes"
  [ "$status" -eq 0 ]
}

@test "child route overrides are transported separately from the frozen session route" {
  run bash "$REQUEST" --type spec --slug demo --route worker=opencode/openai/gpt-5 --session-route claude-code/opus --anywhere --kdir "$TEST_ROOT/kdir" --yes --json
  [ "$status" -eq 0 ]
  row="$(pending_row)"
  [ "$(jq -r '.route.framework+":"+.route.model' <<<"$row")" = claude-code:opus ]
  [ "$(jq -r '.routing_overrides.worker' <<<"$row")" = opencode/openai/gpt-5 ]
}
