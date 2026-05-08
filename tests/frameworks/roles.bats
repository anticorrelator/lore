#!/usr/bin/env bats
# roles.bats — Validates adapters/roles.json and the role->model binding
# rules enforced in scripts/lib.sh (Phase 1, T14).
#
# Coverage:
#   - roles.json parses as JSON and has the expected top-level shape.
#   - default_role is "default" and "default" appears in the closed role list.
#   - Every role id is unique within the registry.
#   - Every non-default role has at least one call_site (default has none).
#   - Every call_site path under repo root exists on disk (catches stale
#     references when a script/skill is renamed).
#   - resolve_model_for_role rejects unknown role names with non-zero exit.
#   - validate_role_model_binding rejects: unknown role, empty model,
#     provider/model syntax under a single-shape harness.
#   - validate_role_model_binding accepts: bare model on any harness,
#     provider/model on a multi-shape harness.
#
# Style: bats + python3 helpers, mirroring tests/frameworks/capabilities.bats.

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"
ROLES="$REPO_DIR/adapters/roles.json"
CAPS="$REPO_DIR/adapters/capabilities.json"
LIB="$REPO_DIR/scripts/lib.sh"

setup() {
  [ -f "$ROLES" ] || skip "adapters/roles.json missing"
  [ -f "$CAPS" ]  || skip "adapters/capabilities.json missing"
  [ -f "$LIB" ]   || skip "scripts/lib.sh missing"
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
}

# ============================================================
# Schema-shape tests
# ============================================================

@test "roles.json parses as JSON" {
  run python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$ROLES"
  [ "$status" -eq 0 ]
}

@test "roles.json has required top-level keys" {
  run python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
required = ["version", "default_role", "roles"]
missing = [k for k in required if k not in d]
if missing:
    print("missing keys:", missing); sys.exit(1)
' "$ROLES"
  [ "$status" -eq 0 ]
}

@test "default_role is 'default' and present in roles list" {
  run python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert d["default_role"] == "default", "expected default_role=default, got {!r}".format(d["default_role"])
ids = [r["id"] for r in d["roles"]]
assert "default" in ids, "default role not in {}".format(ids)
' "$ROLES"
  [ "$status" -eq 0 ]
}

@test "every role id is unique" {
  run python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
ids = [r["id"] for r in d["roles"]]
dupes = {i for i in ids if ids.count(i) > 1}
if dupes:
    print("duplicate role ids:", sorted(dupes)); sys.exit(1)
' "$ROLES"
  [ "$status" -eq 0 ]
}

@test "every non-default role has at least one call_site" {
  run python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
bad = []
for r in d["roles"]:
    if r["id"] == "default":
        continue
    cs = r.get("call_sites") or []
    if not cs:
        bad.append(r["id"])
if bad:
    print("roles missing call_sites:", bad); sys.exit(1)
' "$ROLES"
  [ "$status" -eq 0 ]
}

@test "every call_site path exists under repo root" {
  REPO="$REPO_DIR" run python3 -c '
import json, os, sys
d = json.load(open(sys.argv[1]))
repo = os.environ["REPO"]
missing = []
for r in d["roles"]:
    for cs in r.get("call_sites") or []:
        if not os.path.exists(os.path.join(repo, cs)):
            missing.append("{}:{}".format(r["id"], cs))
if missing:
    print("missing call_site paths:")
    for m in missing: print(" ", m)
    sys.exit(1)
' "$ROLES"
  [ "$status" -eq 0 ]
}

# ============================================================
# resolve_model_for_role tests
# ============================================================

@test "resolve_model_for_role rejects unknown role" {
  run bash -c "source '$LIB'; resolve_model_for_role bogus_role"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown role"* ]]
}

@test "resolve_model_for_role accepts every role in the closed registry (env override)" {
  REPO="$REPO_DIR" LIB="$LIB" run bash -c '
    set -e
    source "$LIB"
    python3 - <<PYEOF
import json, sys, subprocess, os
d = json.load(open("$REPO/adapters/roles.json"))
ids = [r["id"] for r in d["roles"]]
# default may legitimately not have a call site; resolve via env override.
for role in ids:
    env = os.environ.copy()
    env[f"LORE_MODEL_{role.upper()}"] = "stub-model"
    out = subprocess.check_output(["bash", "-c", f"source $LIB && resolve_model_for_role {role}"], env=env, text=True).strip()
    assert out == "stub-model", f"role {role}: got {out!r}"
PYEOF
  '
  [ "$status" -eq 0 ]
}

# ============================================================
# validate_role_model_binding tests
# ============================================================

@test "validate_role_model_binding accepts bare model on claude-code (single shape)" {
  LORE_FRAMEWORK=claude-code run bash -c "source '$LIB'; validate_role_model_binding lead sonnet"
  [ "$status" -eq 0 ]
}

@test "validate_role_model_binding accepts bare model on opencode (multi shape)" {
  LORE_FRAMEWORK=opencode run bash -c "source '$LIB'; validate_role_model_binding lead sonnet"
  [ "$status" -eq 0 ]
}

@test "validate_role_model_binding rejects provider/model on claude-code (single shape)" {
  LORE_FRAMEWORK=claude-code run bash -c "source '$LIB'; validate_role_model_binding lead anthropic/sonnet"
  [ "$status" -ne 0 ]
  [[ "$output" == *"single-provider"* ]]
}

@test "validate_role_model_binding rejects provider/model on codex (single shape)" {
  LORE_FRAMEWORK=codex run bash -c "source '$LIB'; validate_role_model_binding worker openai/gpt-4"
  [ "$status" -ne 0 ]
  [[ "$output" == *"single-provider"* ]]
}

@test "validate_role_model_binding accepts provider/model on opencode (multi shape)" {
  LORE_FRAMEWORK=opencode run bash -c "source '$LIB'; validate_role_model_binding lead anthropic/sonnet"
  [ "$status" -eq 0 ]
}

@test "validate_role_model_binding rejects unknown role" {
  run bash -c "source '$LIB'; validate_role_model_binding bogus_role sonnet"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown role"* ]]
}

@test "validate_role_model_binding rejects empty model" {
  run bash -c "source '$LIB'; validate_role_model_binding lead ''"
  [ "$status" -ne 0 ]
  [[ "$output" == *"empty model binding"* ]]
}
