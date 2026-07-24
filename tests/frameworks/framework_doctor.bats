#!/usr/bin/env bats
# framework_doctor.bats — `lore framework doctor` ceremony-overlay rendering.
#
# scripts/framework-doctor.sh enumerates roles from adapters/roles.json and
# resolves each one with NO ceremony argument, which skips layer 3 of
# resolve_model_for_role (harnesses.<active>.ceremony_roles.<ceremony>.<role>).
# A store with ceremony_roles.spec.lead=fable therefore rendered a clean
# all-opus [roles] table while every /spec lead ran on fable. These tests pin
# the overlay onto the output.
#
# Coverage:
#   - A ceremony binding that overrides the [roles] row is rendered and marked.
#   - The [roles] block is unchanged (both surfaces, no silent rewrite).
#   - Ceremony ids come from adapters/ceremonies.json, not a list in doctor.
#   - A ceremony with no bindings says so instead of going unmentioned.
#   - The class-role fallback (worker-mechanical -> worker) inherits a ceremony
#     binding, so those pairs are surfaced too.
#   - A binding written under ceremony_roles but beaten by a higher-precedence
#     layer is called out as shadowed rather than reported as operative.
#   - Exit-code contract: divergence alone is not a diagnostic (0); a ceremony
#     binding that conflicts with the harness model_routing shape fires (3).
#   - --json carries the same rows.
#
# Style: bats + fixture settings.json, mirroring tests/frameworks/roles.bats.

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"
DOCTOR="$REPO_DIR/scripts/framework-doctor.sh"
ROLES="$REPO_DIR/adapters/roles.json"
CEREMONIES="$REPO_DIR/adapters/ceremonies.json"

setup() {
  [ -f "$DOCTOR" ]      || skip "scripts/framework-doctor.sh missing"
  [ -f "$ROLES" ]       || skip "adapters/roles.json missing"
  [ -f "$CEREMONIES" ]  || skip "adapters/ceremonies.json missing"
  command -v jq >/dev/null 2>&1      || skip "jq not installed"
  command -v python3 >/dev/null 2>&1 || skip "python3 not installed"

  # An ambient LORE_MODEL_<ROLE> in the caller's environment is layer 1 and
  # would shadow every fixture binding below. Clear the whole family so these
  # tests read the same inside and outside a lore session.
  for _v in $(env | sed -n 's/^\(LORE_MODEL_[A-Z_]*\)=.*/\1/p'); do
    unset "$_v"
  done

  FIXTURE_DIR="$(mktemp -d)"
  mkdir -p "$FIXTURE_DIR/config"
}

teardown() {
  [ -n "${FIXTURE_DIR:-}" ] && rm -rf "$FIXTURE_DIR"
  return 0
}

# Assertion helpers, not bare `[[ ... ]]`. Under this bash, `[[ ]]` is exempt
# from errexit, so a failing `[[ ]]` that is not the test's last command is
# silently ignored and the assertion never bites. A function returning non-zero
# does abort the test, so every assertion below is load-bearing.
assert_has() {
  echo "$output" | grep -qF -- "$1" || {
    echo "expected output to contain: $1" >&2
    echo "--- actual ---" >&2
    echo "$output" >&2
    return 1
  }
}

assert_missing() {
  if echo "$output" | grep -qF -- "$1"; then
    echo "expected output NOT to contain: $1" >&2
    echo "--- actual ---" >&2
    echo "$output" >&2
    return 1
  fi
}

write_settings() {
  cat > "$FIXTURE_DIR/config/settings.json"
}

# Run doctor against the fixture config with claude-code active.
doctor() {
  LORE_DATA_DIR="$FIXTURE_DIR" LORE_FRAMEWORK=claude-code bash "$DOCTOR" "$@"
}

# A config whose general roles are uniform, so any divergence in the output
# can only have come from the ceremony overlay.
uniform_roles_with_ceremony() {
  write_settings <<JSON
{ "version": 1, "tui_launch_framework": "claude-code",
  "harnesses": {
    "claude-code": { "args": [],
      "roles": {"lead": "opus", "worker": "opus", "researcher": "opus", "default": "opus"},
      "ceremony_roles": $1 },
    "opencode": {"args": []}, "codex": {"args": []} } }
JSON
}

# ============================================================
# Ceremony overlay rendering
# ============================================================

@test "doctor renders a ceremony binding that overrides the roles table" {
  uniform_roles_with_ceremony '{ "spec": {"lead": "fable"} }'
  run doctor
  [ "$status" -eq 0 ]
  assert_has "[ceremony roles]"
  assert_has "lead -> fable"
  assert_has "OVERRIDES"
}

@test "doctor still renders the general roles table unchanged" {
  uniform_roles_with_ceremony '{ "spec": {"lead": "fable"} }'
  run doctor
  [ "$status" -eq 0 ]
  # The [roles] block keeps reporting the role-overlay answer; the ceremony
  # block is additive, not a rewrite of it.
  assert_has "lead -> opus"
}

@test "doctor names every ceremony from the closed registry" {
  uniform_roles_with_ceremony '{ "spec": {"lead": "fable"} }'
  run doctor
  [ "$status" -eq 0 ]
  ceremony_block="${output#*\[ceremony roles\]}"
  while read -r cid; do
    [ -n "$cid" ] || continue
    echo "$ceremony_block" | grep -qF -- "$cid" || {
      echo "ceremony '$cid' from $CEREMONIES missing from doctor output" >&2
      return 1
    }
  done < <(jq -r '.ceremonies[].id' "$CEREMONIES")
}

@test "doctor says so when a ceremony carries no bindings" {
  uniform_roles_with_ceremony '{ "spec": {"lead": "fable"} }'
  run doctor
  [ "$status" -eq 0 ]
  assert_has "implement: (no bindings"
}

@test "doctor renders the ceremony block when ceremony_roles is absent entirely" {
  write_settings <<'JSON'
{ "version": 1, "tui_launch_framework": "claude-code",
  "harnesses": {
    "claude-code": { "args": [], "roles": {"lead": "opus", "default": "opus"} },
    "opencode": {"args": []}, "codex": {"args": []} } }
JSON
  run doctor
  [ "$status" -eq 0 ]
  assert_has "[ceremony roles]"
  assert_has "spec: (no bindings"
  assert_has "implement: (no bindings"
}

@test "a class role inherits a ceremony binding through fallback_role" {
  uniform_roles_with_ceremony '{ "implement": {"worker": "haiku"} }'
  run doctor
  [ "$status" -eq 0 ]
  # worker-mechanical has no key under ceremony_roles.implement, but
  # resolve_model_for_role forwards the ceremony through the fallback_role
  # re-resolve, so its operative model moves too.
  assert_has "worker-mechanical -> haiku"
  assert_has "worker-judgment-dense -> haiku"
}

@test "a ceremony binding beaten by a higher layer is marked shadowed" {
  uniform_roles_with_ceremony '{ "spec": {"lead": "fable"} }'
  LORE_MODEL_LEAD=sonnet run doctor
  [ "$status" -eq 0 ]
  assert_has "SHADOWED"
  assert_has "lead -> sonnet"
}

@test "a ceremony binding equal to the roles row is not reported as a divergence" {
  uniform_roles_with_ceremony '{ "spec": {"lead": "opus"} }'
  run doctor
  [ "$status" -eq 0 ]
  assert_has "spec: (bindings present, none change the resolved model)"
  assert_missing "OVERRIDES"
}

# ============================================================
# Exit-code contract
# ============================================================

@test "a diverging ceremony binding does not fire a diagnostic" {
  # Divergence is the overlay working as designed, not a misconfiguration.
  uniform_roles_with_ceremony '{ "spec": {"lead": "fable"}, "implement": {"worker": "haiku"} }'
  run doctor
  [ "$status" -eq 0 ]
}

@test "a ceremony binding conflicting with model_routing shape exits 3" {
  # claude-code declares model_routing.shape=single, so provider/model syntax
  # is invalid there — including inside the ceremony overlay.
  uniform_roles_with_ceremony '{ "spec": {"lead": "anthropic/opus"} }'
  run doctor
  [ "$status" -eq 3 ]
  assert_has "[diagnostic] role-binding conflicts"
  assert_has "(ceremony: spec)"
}

@test "an unknown role key under ceremony_roles is named, not read as shadowing" {
  # The resolver rejects the whole ceremony_roles map, so every ceremony-scoped
  # call fails. An empty resolution must not be reported as a binding that a
  # higher layer shadowed — that is a confident wrong answer of exactly the
  # kind this block exists to remove.
  uniform_roles_with_ceremony '{ "spec": {"lead": "fable", "spectator": "haiku"} }'
  run doctor
  [ "$status" -eq 3 ]
  assert_has "(unresolvable)"
  assert_has "unknown role 'spectator'"
  assert_missing "SHADOWED"
}

@test "an unknown ceremony key is named even though the render walks the registry" {
  # Nothing in the registry loop would ever print "deploy", and no
  # (ceremony, role) pair exists to hang the error on, so it needs its own row.
  uniform_roles_with_ceremony '{ "deploy": {"lead": "haiku"} }'
  run doctor
  [ "$status" -eq 3 ]
  assert_has "deploy: UNKNOWN ceremony"
}

@test "existing role-binding conflict diagnostics still fire" {
  # Pins the pre-existing diagnostic: a bad general binding must keep exiting 3
  # with no ceremony attribution on the row.
  write_settings <<'JSON'
{ "version": 1, "tui_launch_framework": "claude-code",
  "harnesses": {
    "claude-code": { "args": [], "roles": {"lead": "anthropic/opus", "default": "opus"} },
    "opencode": {"args": []}, "codex": {"args": []} } }
JSON
  run doctor
  [ "$status" -eq 3 ]
  assert_has "lead -> anthropic/opus"
  assert_has "lore framework set-model lead"
}

# ============================================================
# JSON surface
# ============================================================

@test "doctor --json carries ceremony_roles rows" {
  uniform_roles_with_ceremony '{ "spec": {"lead": "fable"} }'
  run doctor --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json, sys
d = json.load(sys.stdin)
rows = d["ceremony_roles"]
hit = [r for r in rows if r["ceremony"] == "spec" and r["role"] == "lead"]
assert hit, "no spec/lead row in ceremony_roles: {}".format(rows)
r = hit[0]
assert r["resolved"] == "fable", r
assert r["general"] == "opus", r
assert r["differs"] is True, r
assert r["shadowed"] is False, r
'
}

@test "doctor --json ceremony_roles is empty when nothing is bound" {
  write_settings <<'JSON'
{ "version": 1, "tui_launch_framework": "claude-code",
  "harnesses": {
    "claude-code": { "args": [], "roles": {"lead": "opus", "default": "opus"} },
    "opencode": {"args": []}, "codex": {"args": []} } }
JSON
  run doctor --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["ceremony_roles"] == [], d["ceremony_roles"]
'
}
