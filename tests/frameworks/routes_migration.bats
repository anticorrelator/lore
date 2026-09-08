#!/usr/bin/env bats

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"
MIGRATOR="$REPO_DIR/scripts/migrations/routes-table-v2.py"
INSTALL="$REPO_DIR/install.sh"

setup() {
  TEST_ROOT="$(mktemp -d)"
  export HOME="$TEST_ROOT/home"
  export LORE_DATA_DIR="$TEST_ROOT/lore"
  mkdir -p "$HOME" "$LORE_DATA_DIR/config"
  SETTINGS="$LORE_DATA_DIR/config/settings.json"
}

teardown() { chmod -R u+w "$TEST_ROOT" 2>/dev/null || true; rm -rf "$TEST_ROOT"; }

write_owner_fixture() {
  python3 - "$SETTINGS" <<'PY'
import json, sys
global_roles = {
 "lead":"codex/gpt-6-astra", "worker":"codex/gpt-5.6-sol",
 "worker-mechanical":"codex/gpt-5.6-sol", "worker-judgment-dense":"codex/gpt-5.6-sol",
 "researcher":"codex/gpt-6-astra", "reviewer":"codex/gpt-6-astra",
 "advisor":"codex/gpt-6-astra", "default":"opus"}
doc={"version":1,"tui_launch_framework":"claude-code","harnesses":{
 "claude-code":{"args":["--dangerously-skip-permissions"],"roles":global_roles,
   "ceremony_roles":{"pr-review":{"reviewer":"opus"},"implement":{"advisor":"opus"}},"ceremonies":{}},
 "codex":{"args":["--one","a","-c","model_reasoning_effort=\"high\"","--two"],
   "autonomous_args":["--one","b","-c","model_reasoning_effort=\"high\""],
   "roles":{"default":"gpt-6-astra","worker":"gpt-5.6-sol","worker-mechanical":"gpt-5.6-sol","worker-judgment-dense":"gpt-5.6-sol"},"ceremony_roles":{},"ceremonies":{}},
 "opencode":{"args":[],"roles":{"default":"anthropic/opus"},"ceremony_roles":{},"ceremonies":{}}},
 "capability_overrides":{},"tui":{"layout":"left-right"}}
with open(sys.argv[1],"w") as f: json.dump(doc,f,indent=2); f.write("\n")
PY
}

@test "generic template is valid version 2 without owner model ids" {
  run python3 "$REPO_DIR/scripts/route_config.py" validate-settings <<JSON
{"repo_root":"$REPO_DIR","settings_path":"$REPO_DIR/adapters/settings.template.json"}
JSON
  [ "$status" -eq 0 ]
  [[ "$output" == *'"valid":true'* ]]
  ! grep -Eq 'gpt-5\.6-sol|gpt-6-astra|/Users/' "$REPO_DIR/adapters/settings.template.json"
}

@test "owner migration preserves global policy and native affinity" {
  write_owner_fixture
  run python3 "$MIGRATOR" --settings "$SETTINGS" --repo-root "$REPO_DIR"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.version' "$SETTINGS")" = 2 ]
  [ "$(jq -r '.routes.worker.framework + "/" + .routes.worker.model' "$SETTINGS")" = codex/gpt-5.6-sol ]
  [ "$(jq -r '.routes.worker.effort + ":" + .routes.worker.service_tier' "$SETTINGS")" = high:fast ]
  [ "$(jq -r '.routes.lead.effort' "$SETTINGS")" = high ]
  [ "$(jq -r '.routes.lead.service_tier // "absent"' "$SETTINGS")" = absent ]
  [ "$(jq -r '.harnesses."claude-code".native_models.default' "$SETTINGS")" = opus ]
  [ "$(jq -r '.harnesses.codex.native_models.worker' "$SETTINGS")" = gpt-5.6-sol-high ]
  [ "$(jq -r '.routes.ceremony_overlays // "absent"' "$SETTINGS")" = absent ]
  [ "$(jq -c '.harnesses.codex.args' "$SETTINGS")" = '["--one","a","--two"]' ]
  [ -f "$SETTINGS.routes-v1.bak" ]
}

@test "valid version 2 migration is byte-preserving" {
  cp "$REPO_DIR/adapters/settings.template.json" "$SETTINGS"
  before="$(shasum -a 256 "$SETTINGS" | awk '{print $1}')"
  run python3 "$MIGRATOR" --settings "$SETTINGS" --repo-root "$REPO_DIR"
  [ "$status" -eq 0 ]
  [ "$before" = "$(shasum -a 256 "$SETTINGS" | awk '{print $1}')" ]
  [ ! -e "$SETTINGS.routes-v1.bak" ]
}

@test "dry run neither writes settings nor backup" {
  write_owner_fixture
  before="$(shasum -a 256 "$SETTINGS" | awk '{print $1}')"
  run python3 "$MIGRATOR" --settings "$SETTINGS" --repo-root "$REPO_DIR" --dry-run
  [ "$status" -eq 0 ]
  [ "$before" = "$(shasum -a 256 "$SETTINGS" | awk '{print $1}')" ]
  [ ! -e "$SETTINGS.routes-v1.bak" ]
}

@test "mixed old and new routing shape refuses without mutation" {
  write_owner_fixture
  tmp="$TEST_ROOT/mixed"; jq '.routes={default:"claude-code/opus"}' "$SETTINGS" > "$tmp"; mv "$tmp" "$SETTINGS"
  before="$(shasum -a 256 "$SETTINGS" | awk '{print $1}')"
  run python3 "$MIGRATOR" --settings "$SETTINGS" --repo-root "$REPO_DIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot coexist"* ]]
  [ "$before" = "$(shasum -a 256 "$SETTINGS" | awk '{print $1}')" ]
}

@test "genuinely conflicting foreign native policy refuses with source path" {
  write_owner_fixture
  tmp="$TEST_ROOT/conflict"; jq '.harnesses.codex.roles.reviewer="opencode/anthropic/opus"' "$SETTINGS" > "$tmp"; mv "$tmp" "$SETTINGS"
  run python3 "$MIGRATOR" --settings "$SETTINGS" --repo-root "$REPO_DIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"harnesses.codex.roles.reviewer"* ]]
}

@test "foreign native mirror with distinct effort refuses" {
  write_owner_fixture
  tmp="$TEST_ROOT/foreign-effort"; jq '.harnesses.opencode.roles.worker="codex/gpt-5.6-sol-low"' "$SETTINGS" > "$tmp"; mv "$tmp" "$SETTINGS"
  run python3 "$MIGRATOR" --settings "$SETTINGS" --repo-root "$REPO_DIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"harnesses.opencode.roles.worker"* ]]
}

@test "unknown legacy role refuses even when equal to native default" {
  write_owner_fixture
  tmp="$TEST_ROOT/role"; jq '.harnesses.codex.roles.spectator=.harnesses.codex.roles.default' "$SETTINGS" > "$tmp"; mv "$tmp" "$SETTINGS"
  run python3 "$MIGRATOR" --settings "$SETTINGS" --repo-root "$REPO_DIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"harnesses.codex.roles.spectator"* ]]
}

@test "argument profile divergence refuses when an applicable binding lacks the option" {
  write_owner_fixture
  tmp="$TEST_ROOT/diverge"; jq '.harnesses.codex.autonomous_args=["-c","model_reasoning_effort=\"low\""]' "$SETTINGS" > "$tmp"; mv "$tmp" "$SETTINGS"
  run python3 "$MIGRATOR" --settings "$SETTINGS" --repo-root "$REPO_DIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"conflicting effort"* ]]
}

@test "explicit route and native effort survives inherited profile effort" {
  write_owner_fixture
  tmp="$TEST_ROOT/explicit"
  jq '.harnesses."claude-code".roles.worker="codex/gpt-5.6-sol-low" | .harnesses.codex.roles.worker="gpt-5.6-sol-low"' "$SETTINGS" > "$tmp"; mv "$tmp" "$SETTINGS"
  run python3 "$MIGRATOR" --settings "$SETTINGS" --repo-root "$REPO_DIR"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.routes.worker.effort' "$SETTINGS")" = low ]
  [ "$(jq -r '.harnesses.codex.native_models.worker' "$SETTINGS")" = gpt-5.6-sol-low ]
}

@test "divergent profiles succeed when every applicable binding is explicit" {
  write_owner_fixture
  tmp="$TEST_ROOT/all-explicit"
  jq '.harnesses.codex.autonomous_args=["-c","model_reasoning_effort=\"low\""]
      | .harnesses."claude-code".roles |= with_entries(if (.value | startswith("codex/")) then .value += "-high" else . end)
      | .harnesses.codex.roles |= with_entries(.value += "-high")' "$SETTINGS" > "$tmp"; mv "$tmp" "$SETTINGS"
  run python3 "$MIGRATOR" --settings "$SETTINGS" --repo-root "$REPO_DIR"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.routes.lead.effort' "$SETTINGS")" = high ]
  [ "$(jq -r '.harnesses.codex.native_models.default' "$SETTINGS")" = gpt-6-astra-high ]
}

@test "Claude ceremony exception is retained when native resolution differs" {
  write_owner_fixture
  tmp="$TEST_ROOT/ceremony"
  jq '.harnesses."claude-code".roles.reviewer="sonnet"' "$SETTINGS" > "$tmp"; mv "$tmp" "$SETTINGS"
  run python3 "$MIGRATOR" --settings "$SETTINGS" --repo-root "$REPO_DIR"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.routes.ceremony_overlays."pr-review".reviewer.framework + "/" + .routes.ceremony_overlays."pr-review".reviewer.model' "$SETTINGS")" = claude-code/opus ]
}

@test "native service tier loss refuses atomically with source path" {
  write_owner_fixture
  tmp="$TEST_ROOT/tier"
  jq '.harnesses.codex.args += ["-c","service_tier=\"fast\""] | .harnesses.codex.autonomous_args += ["-c","service_tier=\"fast\""]' "$SETTINGS" > "$tmp"; mv "$tmp" "$SETTINGS"
  before="$(shasum -a 256 "$SETTINGS" | awk '{print $1}')"
  run python3 "$MIGRATOR" --settings "$SETTINGS" --repo-root "$REPO_DIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"harnesses.codex.args"* ]]
  [[ "$output" == *"service_tier"* ]]
  [ "$before" = "$(shasum -a 256 "$SETTINGS" | awk '{print $1}')" ]
}

@test "mismatched existing backup refuses before changing settings" {
  write_owner_fixture
  printf '%s\n' different > "$SETTINGS.routes-v1.bak"
  before="$(shasum -a 256 "$SETTINGS" | awk '{print $1}')"
  run python3 "$MIGRATOR" --settings "$SETTINGS" --repo-root "$REPO_DIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"existing backup does not match"* ]]
  [ "$before" = "$(shasum -a 256 "$SETTINGS" | awk '{print $1}')" ]
}

@test "migrate-settings-only exits before install links" {
  write_owner_fixture
  run bash "$INSTALL" --migrate-settings-only --framework claude-code
  [ "$status" -eq 0 ]
  [ "$(jq -r '.version' "$SETTINGS")" = 2 ]
  [ ! -e "$HOME/.local/bin/lore" ]
  [ ! -e "$LORE_DATA_DIR/scripts" ]
}

@test "migrate-settings-only refuses a missing settings file before creation" {
  run bash "$INSTALL" --migrate-settings-only --framework claude-code
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires an existing"* ]]
  [ ! -e "$SETTINGS" ]
  [ ! -e "$LORE_DATA_DIR/repos" ]
}

@test "fragmented role config is converted before first unified write" {
  mkdir -p "$TEST_ROOT/bin"
  cat > "$TEST_ROOT/bin/go" <<'SH'
#!/bin/sh
output=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-o" ] && [ "$#" -gt 1 ]; then output="$2"; shift 2; continue; fi
  shift
done
if [ -n "$output" ]; then mkdir -p "$(dirname "$output")"; : > "$output"; chmod +x "$output"; fi
exit 0
SH
  chmod +x "$TEST_ROOT/bin/go"
  export PATH="$TEST_ROOT/bin:$PATH"
  source "$REPO_DIR/scripts/lib.sh"
  ensure_yaml_python
  python3 - "$LORE_DATA_DIR/config/framework.json" "$REPO_DIR/adapters/roles.json" <<'PY'
import json, sys
roles = json.load(open(sys.argv[2]))["roles"]
with open(sys.argv[1], "w") as handle:
    json.dump({"framework":"claude-code","roles":{row["id"]:"opus" for row in roles}}, handle)
PY
  run bash "$INSTALL" --framework claude-code
  if [ "$status" -ne 0 ]; then echo "$output" >&2; fi
  [ "$status" -eq 0 ]
  [ "$(jq -r '.version' "$SETTINGS")" = 2 ]
  [ "$(jq -r '.routes.default' "$SETTINGS")" = null ] || [ "$(jq -r '.routes.default.framework + "/" + .routes.default.model' "$SETTINGS")" = claude-code/opus ]
  ! jq -e '.harnesses[] | has("roles") or has("ceremony_roles")' "$SETTINGS"
}
