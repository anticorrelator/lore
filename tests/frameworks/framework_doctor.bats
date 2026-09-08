#!/usr/bin/env bats

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"
DOCTOR="$REPO_DIR/scripts/framework-doctor.sh"
STATUS="$REPO_DIR/scripts/framework-status.sh"

setup() {
  FIXTURE_DIR="$(mktemp -d)"
  mkdir -p "$FIXTURE_DIR/config" "$FIXTURE_DIR/repo"
  cp "$REPO_DIR/adapters/settings.template.json" "$FIXTURE_DIR/config/settings.json"
  for name in $(env | sed -n 's/^\(LORE_MODEL_[A-Z_]*\)=.*/\1/p'); do unset "$name"; done
}
teardown() { rm -rf "$FIXTURE_DIR"; }

doctor() { (cd "$FIXTURE_DIR/repo" && LORE_DATA_DIR="$FIXTURE_DIR" bash "$DOCTOR" "$@"); }
status_cmd() { (cd "$FIXTURE_DIR/repo" && LORE_DATA_DIR="$FIXTURE_DIR" bash "$STATUS" "$@"); }
mutate() { tmp="$FIXTURE_DIR/settings.tmp"; jq "$1" "$FIXTURE_DIR/config/settings.json" > "$tmp" && mv "$tmp" "$FIXTURE_DIR/config/settings.json"; }

@test "doctor validates a foreign target with the target framework shape" {
  mutate '.routes.worker={framework:"codex",model:"gpt-5.6-sol",effort:"high",service_tier:"fast"}'
  run doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"codex/gpt-5.6-sol"* ]]
  [[ "$output" == *'"effort":"high","service_tier":"fast"'* ]]
}

@test "doctor rejects retired keys with their exact settings path" {
  mutate '.harnesses.codex.roles={default:"gpt-5.5"}'
  run doctor
  [ "$status" -eq 3 ]
  [[ "$output" == *"retired_settings_key"* ]]
  [[ "$output" == *"harnesses.codex.roles"* ]]
}

@test "doctor JSON rejects unknown options actionably" {
  mutate '.routes.worker={framework:"codex",model:"gpt-5.5",turbo:"yes"}'
  run doctor --json
  [ "$status" -eq 3 ]
  echo "$output" | jq -e '.config_status=="invalid" and .error.code=="unknown_route_field" and .error.path=="routes.worker.turbo"'
}

@test "doctor validates malformed unused routes even behind env precedence" {
  mutate '.routes.advisor={framework:"codex",model:"gpt-5.5",effort:null}'
  LORE_MODEL_WORKER=codex/gpt-5.6-sol-high run doctor
  [ "$status" -eq 3 ]
  [[ "$output" == *"routes.advisor.effort"* ]]
}

@test "doctor reports malformed env route as a structured diagnostic" {
  LORE_MODEL_WORKER=bad run doctor --json
  [ "$status" -eq 3 ]
  echo "$output" | jq -e '.config_status=="invalid" and .role=="worker" and .error.code=="missing_framework" and .diagnostics_fired==1'
}

@test "doctor reports malformed per-repo route without a traceback" {
  printf '%s\n' 'model_for_worker=bad' > "$FIXTURE_DIR/repo/.lore.config"
  run doctor
  [ "$status" -eq 3 ]
  [[ "$output" == *"invalid resolved route for worker"* ]]
  [[ "$output" == *"missing_framework"* ]]
  [[ "$output" != *"Traceback"* ]]
}

@test "doctor per-repo diff names the actual configured fallback route" {
  mutate 'del(.routes."worker-mechanical") | .routes.worker={framework:"codex",model:"gpt-5.6-sol",effort:"high",service_tier:"fast"}'
  printf '%s\n' 'model_for_worker-mechanical=claude-code/opus' > "$FIXTURE_DIR/repo/.lore.config"
  run doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *'worker-mechanical: cwd=claude-code/opus  user-config=codex/gpt-5.6-sol {"effort":"high","service_tier":"fast"}'* ]]
}

@test "doctor renders canonical ceremony overlays with options" {
  mutate '.routes.ceremony_overlays."pr-review".reviewer={framework:"codex",model:"gpt-5.6-sol",effort:"high",service_tier:"fast"}'
  run doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"[ceremony roles]"* ]]
  [[ "$output" == *"reviewer -> codex/gpt-5.6-sol"* ]]
  [[ "$output" == *"service_tier"* ]]
  [[ "$output" == *"OVERRIDES"* ]]
}

@test "doctor ceremony resolution follows role fallback" {
  mutate 'del(.routes."worker-mechanical") | .routes.ceremony_overlays.implement.worker="codex/gpt-5.6-sol-high"'
  run doctor --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ceremony_roles[] | select(.ceremony=="implement" and .role=="worker-mechanical") | .route.routing_source.layer=="ceremony-overlay" and .route.routing_source.role=="worker" and .route.options.effort=="high"'
}

@test "doctor marks a canonical ceremony binding shadowed by env" {
  mutate '.routes.ceremony_overlays."pr-review".reviewer="codex/gpt-5.6-sol-high"'
  LORE_MODEL_REVIEWER=claude-code/opus run doctor --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ceremony_roles[] | select(.ceremony=="pr-review" and .role=="reviewer") | .shadowed==true and .route.routing_source.layer=="env" and .general_route.routing_source.layer=="env"'
}

@test "doctor absent settings keeps the absent diagnostic path" {
  rm "$FIXTURE_DIR/config/settings.json"
  run doctor --json
  [ "$status" -eq 2 ]
  echo "$output" | jq -e '.config_status=="absent" and .diagnostics_fired==0'
}

@test "status shows canonical global routes and active native models" {
  LORE_FRAMEWORK=claude-code run status_cmd --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.config_status=="present" and (.routes|length)>0 and .routes[0].routing_source.layer and (.native_models.default | length)>0'
  LORE_FRAMEWORK=claude-code run status_cmd
  [ "$status" -eq 0 ]
  [[ "$output" == *"[routes]"* ]]
  [[ "$output" == *"[native_models: claude-code]"* ]]
}

@test "status honors per-repo routes and reports their true source" {
  printf '%s\n' 'model_for_worker=codex/gpt-5.6-sol-high' > "$FIXTURE_DIR/repo/.lore.config"
  run status_cmd --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.routes[] | select(.requested_role=="worker") | .framework=="codex" and .model=="gpt-5.6-sol" and .options.effort=="high" and .routing_source.layer=="per-repo" and .routing_source.role=="worker"'
}

@test "status uses runtime harness for native models and keeps fallback request roles" {
  mutate 'del(.routes."worker-mechanical") | .routes.worker="codex/gpt-5.6-sol-high"'
  LORE_FRAMEWORK=codex run status_cmd --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.framework.name=="codex" and .native_models.default=="gpt-5.5-high" and (.routes[] | select(.requested_role=="worker-mechanical") | .routing_source.role=="worker" and .framework=="codex")'
}

@test "status retains capability notes and artifact pointers" {
  run status_cmd --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '(.capabilities[] | has("notes") and has("evidence")) and (.artifacts.capabilities_evidence | endswith("adapters/capabilities-evidence.md"))'
}

@test "status distinguishes absent settings from invalid configured values" {
  rm "$FIXTURE_DIR/config/settings.json"
  run status_cmd --json
  [ "$status" -eq 2 ]
  echo "$output" | jq -e '.config_status=="absent" and .error.code=="absent"'
  cp "$REPO_DIR/adapters/settings.template.json" "$FIXTURE_DIR/config/settings.json"
  mutate '.routes.worker={framework:"codex",model:"gpt-5.5",effort:"impossible"}'
  run status_cmd --json
  [ "$status" -eq 2 ]
  echo "$output" | jq -e '.config_status=="invalid" and .error.code=="invalid_route_option"'
}
