#!/usr/bin/env bats
# settings_schema_keyset_parity.bats — Closed-set keyset parity between
# adapters/settings.schema.json and the upstream registries
# (adapters/capabilities.json, adapters/roles.json) per Phase 1, T1.
#
# The unified settings schema's `tui_launch_framework` enum, `harnesses` keyset,
# `$defs/role_id` enum, and `$defs/capability_id` enum are derived from
# upstream registries. Hand-maintaining the same list in two places is a
# drift surface (a new framework added to capabilities.json without a
# matching schema update would silently route through the schema's stale
# enum). This suite asserts the four parity invariants:
#
#   1. schema.tui_launch_framework.enum == capabilities.json frameworks keyset
#   2. schema.harnesses.properties keyset == capabilities.json frameworks keyset
#   3. schema.$defs.role_id.enum == roles.json roles[].id list
#   4. schema.$defs.capability_id.enum == capabilities.json capabilities keyset
#
# Falsifier (worker-1 verified manually): adding a fake framework
# "phantom-harness" to capabilities.json without updating the schema causes
# tests 1 and 2 to fail. Adding a fake role "spectator" to roles.json
# without updating $defs/role_id causes test 3 to fail. Removing a
# capability from capabilities.json `capabilities` map without updating
# $defs/capability_id causes test 4 to fail.

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"
SCHEMA="$REPO_DIR/adapters/settings.schema.json"
CAPS="$REPO_DIR/adapters/capabilities.json"
ROLES="$REPO_DIR/adapters/roles.json"

setup() {
  [ -f "$SCHEMA" ] || skip "adapters/settings.schema.json missing"
  [ -f "$CAPS" ]   || skip "adapters/capabilities.json missing"
  [ -f "$ROLES" ]  || skip "adapters/roles.json missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"
}

# --- Helpers -----------------------------------------------------------------

# Print one line per element, sorted, deduped.
sorted_lines() {
  awk 'NF' | LC_ALL=C sort -u
}

frameworks_from_caps() {
  CAPS="$CAPS" python3 - <<'PY'
import json, os
with open(os.environ["CAPS"]) as f:
    d = json.load(f)
for k in d.get("frameworks", {}).keys():
    print(k)
PY
}

capabilities_from_caps() {
  CAPS="$CAPS" python3 - <<'PY'
import json, os
with open(os.environ["CAPS"]) as f:
    d = json.load(f)
for k in d.get("capabilities", {}).keys():
    print(k)
PY
}

roles_from_roles() {
  ROLES="$ROLES" python3 - <<'PY'
import json, os
with open(os.environ["ROLES"]) as f:
    d = json.load(f)
for r in d.get("roles", []):
    print(r["id"])
PY
}

schema_tui_launch_framework_enum() {
  SCHEMA="$SCHEMA" python3 - <<'PY'
import json, os
with open(os.environ["SCHEMA"]) as f:
    s = json.load(f)
# Resolve $ref to $defs/framework_id for tui_launch_framework.
node = s["properties"]["tui_launch_framework"]
if "$ref" in node:
    ref = node["$ref"]
    assert ref.startswith("#/$defs/"), ref
    node = s["$defs"][ref.split("/")[-1]]
for v in node["enum"]:
    print(v)
PY
}

schema_harnesses_keyset() {
  SCHEMA="$SCHEMA" python3 - <<'PY'
import json, os
with open(os.environ["SCHEMA"]) as f:
    s = json.load(f)
for k in s["properties"]["harnesses"]["properties"].keys():
    print(k)
PY
}

schema_role_id_enum() {
  SCHEMA="$SCHEMA" python3 - <<'PY'
import json, os
with open(os.environ["SCHEMA"]) as f:
    s = json.load(f)
for v in s["$defs"]["role_id"]["enum"]:
    print(v)
PY
}

schema_capability_id_enum() {
  SCHEMA="$SCHEMA" python3 - <<'PY'
import json, os
with open(os.environ["SCHEMA"]) as f:
    s = json.load(f)
for v in s["$defs"]["capability_id"]["enum"]:
    print(v)
PY
}

# --- Tests -------------------------------------------------------------------

@test "schema tui_launch_framework enum matches capabilities.json frameworks keyset" {
  schema_set=$(schema_tui_launch_framework_enum | sorted_lines)
  caps_set=$(frameworks_from_caps | sorted_lines)
  [ -n "$schema_set" ]
  [ -n "$caps_set" ]
  diff <(printf '%s\n' "$schema_set") <(printf '%s\n' "$caps_set")
}

@test "schema harnesses keyset matches capabilities.json frameworks keyset" {
  schema_set=$(schema_harnesses_keyset | sorted_lines)
  caps_set=$(frameworks_from_caps | sorted_lines)
  [ -n "$schema_set" ]
  [ -n "$caps_set" ]
  diff <(printf '%s\n' "$schema_set") <(printf '%s\n' "$caps_set")
}

@test "schema \$defs/role_id enum matches roles.json roles[].id" {
  schema_set=$(schema_role_id_enum | sorted_lines)
  roles_set=$(roles_from_roles | sorted_lines)
  [ -n "$schema_set" ]
  [ -n "$roles_set" ]
  diff <(printf '%s\n' "$schema_set") <(printf '%s\n' "$roles_set")
}

@test "schema \$defs/capability_id enum matches capabilities.json capabilities keyset" {
  schema_set=$(schema_capability_id_enum | sorted_lines)
  caps_set=$(capabilities_from_caps | sorted_lines)
  [ -n "$schema_set" ]
  [ -n "$caps_set" ]
  diff <(printf '%s\n' "$schema_set") <(printf '%s\n' "$caps_set")
}

@test "schema capability_overrides properties keyset matches capabilities.json capabilities keyset" {
  schema_set=$(SCHEMA="$SCHEMA" python3 - <<'PY' | sorted_lines
import json, os
with open(os.environ["SCHEMA"]) as f:
    s = json.load(f)
for k in s["$defs"]["capability_overrides_map"]["properties"].keys():
    print(k)
PY
)
  caps_set=$(capabilities_from_caps | sorted_lines)
  [ -n "$schema_set" ]
  [ -n "$caps_set" ]
  diff <(printf '%s\n' "$schema_set") <(printf '%s\n' "$caps_set")
}

@test "harness_block requires args + permits enabled, roles, ceremonies + rejects unknown keys" {
  SCHEMA="$SCHEMA" python3 - <<'PY'
import json, os
with open(os.environ["SCHEMA"]) as f:
    s = json.load(f)
hb = s["$defs"]["harness_block"]
assert hb["additionalProperties"] is False, "harness_block must close additionalProperties"
assert "args" in hb["required"], "harness_block must require args"
props = set(hb["properties"].keys())
# `enabled` is the per-harness toggle (default-on; absence ≡ enabled).
# `roles` and `ceremonies` are optional overlay maps.
assert props == {"args", "enabled", "roles", "ceremonies"}, f"unexpected harness_block props: {props}"
# enabled must be a plain boolean (no enum, no minLength) so absence ≡ enabled
# is a clean default-on semantic.
en = hb["properties"]["enabled"]
assert en.get("type") == "boolean", f"harness_block.enabled type: {en}"
PY
}

@test "$defs/role_value rejects empty string (minLength 1)" {
  SCHEMA="$SCHEMA" python3 - <<'PY'
import json, os
with open(os.environ["SCHEMA"]) as f:
    s = json.load(f)
rv = s["$defs"]["role_value"]
assert rv.get("minLength") == 1, f"role_value must have minLength 1, got {rv}"
assert rv.get("type") == "string"
PY
}

@test "ceremonies_map permits empty arrays (minItems 0) and uniqueItems" {
  SCHEMA="$SCHEMA" python3 - <<'PY'
import json, os
with open(os.environ["SCHEMA"]) as f:
    s = json.load(f)
cm = s["$defs"]["ceremonies_map"]
ap = cm["additionalProperties"]
assert ap["type"] == "array"
assert ap.get("minItems") == 0, "empty-array suppression override must be allowed"
assert ap.get("uniqueItems") is True
PY
}

@test "root additionalProperties:false (rejects _deprecated_legacy_source implicitly)" {
  SCHEMA="$SCHEMA" python3 - <<'PY'
import json, os
with open(os.environ["SCHEMA"]) as f:
    s = json.load(f)
assert s["additionalProperties"] is False, "root must close additionalProperties"
# Spot-check every nested object closes additionalProperties OR uses
# additionalProperties as an explicit shape.
def closed(node, path="$"):
    if not isinstance(node, dict):
        return
    if node.get("type") == "object":
        ap = node.get("additionalProperties")
        if "patternProperties" not in node and ap is not False and not isinstance(ap, dict):
            raise AssertionError(f"{path}: object missing additionalProperties:false or shape — got {ap!r}")
    for k, v in node.items():
        closed(v, f"{path}.{k}")
closed(s["properties"], "$.properties")
closed(s["$defs"],      "$.$defs")
PY
}

@test "tui.layout enum is exhaustive (left-right, top-bottom)" {
  SCHEMA="$SCHEMA" python3 - <<'PY'
import json, os
with open(os.environ["SCHEMA"]) as f:
    s = json.load(f)
enum = s["properties"]["tui"]["properties"]["layout"]["enum"]
assert sorted(enum) == sorted(["left-right", "top-bottom"]), f"unexpected tui.layout enum: {enum}"
PY
}

@test "support_level enum matches capabilities.json support_levels keyset" {
  schema_set=$(SCHEMA="$SCHEMA" python3 - <<'PY' | sorted_lines
import json, os
with open(os.environ["SCHEMA"]) as f:
    s = json.load(f)
for v in s["$defs"]["support_level"]["enum"]:
    print(v)
PY
)
  caps_set=$(CAPS="$CAPS" python3 - <<'PY' | sorted_lines
import json, os
with open(os.environ["CAPS"]) as f:
    d = json.load(f)
for k in d.get("support_levels", {}).keys():
    print(k)
PY
)
  diff <(printf '%s\n' "$schema_set") <(printf '%s\n' "$caps_set")
}

@test "template validates against schema (jsonschema or jq fallback)" {
  TEMPLATE="$REPO_DIR/adapters/settings.template.json"
  [ -f "$TEMPLATE" ] || skip "settings.template.json missing"
  if python3 -c "import jsonschema" 2>/dev/null; then
    SCHEMA="$SCHEMA" TEMPLATE="$TEMPLATE" python3 - <<'PY'
import json, os, sys
import jsonschema
with open(os.environ["SCHEMA"]) as f:
    schema = json.load(f)
with open(os.environ["TEMPLATE"]) as f:
    instance = json.load(f)
jsonschema.validate(instance, schema)
PY
  else
    skip "python3 jsonschema package not installed (template validation deferred to lore doctor)"
  fi
}

@test "settlement schema defaults fail closed with built-in executor" {
  SCHEMA="$SCHEMA" TEMPLATE="$REPO_DIR/adapters/settings.template.json" python3 - <<'PY'
import json, os
with open(os.environ["SCHEMA"]) as f:
    s = json.load(f)
with open(os.environ["TEMPLATE"]) as f:
    t = json.load(f)
cfg = t["settlement"]
assert cfg["enabled"] is False
assert cfg["max_concurrency"] == 1
assert cfg["batch_size"] == 12
assert cfg["batch_recompute_min_interval_seconds"] == 60
assert cfg["concordance_window_size"] == 8
assert cfg["concordance_window_size"] <= cfg["batch_size"]
assert "budgets" not in cfg
assert cfg["active_hours"]["enabled"] is False
assert cfg["active_hours"]["timezone"] == "local"
defs = s["$defs"]["settlement_config"]["properties"]
assert defs["enabled"]["default"] is False
assert "executor" not in defs
assert "paused" not in defs
assert defs["max_concurrency"]["minimum"] == 1
assert defs["batch_size"]["minimum"] == 1
assert defs["batch_size"]["default"] == 12
assert defs["batch_recompute_min_interval_seconds"]["minimum"] == 0
assert defs["batch_recompute_min_interval_seconds"]["default"] == 60
assert defs["concordance_window_size"]["minimum"] == 0
assert defs["concordance_window_size"]["default"] == 8
assert "days" not in defs["active_hours"]["properties"]
assert "start" not in defs["active_hours"]["properties"]
assert "end" not in defs["active_hours"]["properties"]
assert defs["active_hours"]["properties"]["ranges"]["items"]["properties"]["days"]["items"]["enum"] == ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
assert defs["active_hours"]["properties"]["ranges"]["minItems"] == 1
assert defs["active_hours"]["properties"]["ranges"]["items"]["required"] == ["days", "start", "end"]
assert defs["harness_selection"]["properties"]["mode"]["enum"] == ["first_eligible", "random", "active"]
PY
}

@test "schema rejects _deprecated_legacy_source at root" {
  python3 -c "import jsonschema" 2>/dev/null || skip "python3 jsonschema package not installed"
  SCHEMA="$SCHEMA" python3 - <<'PY'
import json, os, sys
import jsonschema
with open(os.environ["SCHEMA"]) as f:
    schema = json.load(f)
instance = {
    "version": 1,
    "tui_launch_framework": "claude-code",
    "harnesses": {"claude-code": {"args": []}, "opencode": {"args": []}, "codex": {"args": []}},
    "_deprecated_legacy_source": "/Users/x/.lore/config/framework.json"
}
try:
    jsonschema.validate(instance, schema)
except jsonschema.ValidationError:
    sys.exit(0)
sys.exit("schema FAILED to reject _deprecated_legacy_source at root")
PY
}

@test "schema rejects empty-string role_value (harness role overlay)" {
  python3 -c "import jsonschema" 2>/dev/null || skip "python3 jsonschema package not installed"
  SCHEMA="$SCHEMA" python3 - <<'PY'
import json, os, sys
import jsonschema
with open(os.environ["SCHEMA"]) as f:
    schema = json.load(f)
instance = {
    "version": 1,
    "tui_launch_framework": "claude-code",
    "harnesses": {
        "claude-code": {"args": [], "roles": {"lead": ""}},
        "opencode": {"args": []},
        "codex": {"args": []}
    }
}
try:
    jsonschema.validate(instance, schema)
except jsonschema.ValidationError:
    sys.exit(0)
sys.exit("schema FAILED to reject empty-string role value")
PY
}

@test "schema accepts harness ceremonies overlay with empty array (suppression override)" {
  python3 -c "import jsonschema" 2>/dev/null || skip "python3 jsonschema package not installed"
  SCHEMA="$SCHEMA" python3 - <<'PY'
import json, os, sys
import jsonschema
with open(os.environ["SCHEMA"]) as f:
    schema = json.load(f)
instance = {
    "version": 1,
    "tui_launch_framework": "codex",
    "harnesses": {
        "claude-code": {"args": []},
        "opencode":    {"args": []},
        "codex": {
            "args": [],
            "ceremonies": {
                "spec-design":    [],
                "spec-post-plan": [],
                "pr-review":      []
            }
        }
    }
}
jsonschema.validate(instance, schema)
PY
}

@test "schema rejects top-level ceremonies" {
  python3 -c "import jsonschema" 2>/dev/null || skip "python3 jsonschema package not installed"
  SCHEMA="$SCHEMA" python3 - <<'PY'
import json, os, sys
import jsonschema
with open(os.environ["SCHEMA"]) as f:
    schema = json.load(f)
instance = {
    "version": 1,
    "tui_launch_framework": "codex",
    "harnesses": {
        "claude-code": {"args": []},
        "opencode": {"args": []},
        "codex": {"args": []}
    },
    "ceremonies": {"spec-design": ["codex-design-review"]}
}
try:
    jsonschema.validate(instance, schema)
except jsonschema.ValidationError:
    sys.exit(0)
sys.exit("schema FAILED to reject top-level ceremonies")
PY
}

@test "schema rejects unknown role_id key in roles overlay" {
  python3 -c "import jsonschema" 2>/dev/null || skip "python3 jsonschema package not installed"
  SCHEMA="$SCHEMA" python3 - <<'PY'
import json, os, sys
import jsonschema
with open(os.environ["SCHEMA"]) as f:
    schema = json.load(f)
instance = {
    "version": 1,
    "tui_launch_framework": "claude-code",
    "harnesses": {
        "claude-code": {"args": [], "roles": {"unknown_role": "opus"}},
        "opencode": {"args": []},
        "codex": {"args": []}
    }
}
try:
    jsonschema.validate(instance, schema)
except jsonschema.ValidationError:
    sys.exit(0)
sys.exit("schema FAILED to reject unknown role_id in overlay")
PY
}

@test "install.sh SUPPORTED_FRAMEWORKS allowlist matches capabilities.json frameworks keyset" {
  # T5 D3a: install.sh's framework allowlist is sourced from capabilities.json
  # at runtime (no hardcoded array). This test verifies install.sh's
  # closed-set rejection error names exactly the capabilities.json frameworks
  # — drift would let install accept a framework capabilities.json rejects.
  INSTALL_SH="$REPO_DIR/install.sh"
  [ -f "$INSTALL_SH" ] || skip "install.sh missing"
  caps_set=$(frameworks_from_caps | sorted_lines | tr '\n' ' ' | sed 's/[[:space:]]*$//')

  # Trigger the error message and assert each framework name appears in it.
  run bash "$INSTALL_SH" --framework phantom-harness --dry-run
  [ "$status" -ne 0 ]
  for fw in $caps_set; do
    [[ "$output" == *"$fw"* ]] || {
      echo "install.sh error message did not mention '$fw'"
      echo "actual output: $output"
      false
    }
  done
}

@test "schema rejects unknown framework key in harnesses" {
  python3 -c "import jsonschema" 2>/dev/null || skip "python3 jsonschema package not installed"
  SCHEMA="$SCHEMA" python3 - <<'PY'
import json, os, sys
import jsonschema
with open(os.environ["SCHEMA"]) as f:
    schema = json.load(f)
instance = {
    "version": 1,
    "tui_launch_framework": "claude-code",
    "harnesses": {
        "claude-code": {"args": []},
        "opencode": {"args": []},
        "codex": {"args": []},
        "phantom-harness": {"args": []}
    }
}
try:
    jsonschema.validate(instance, schema)
except jsonschema.ValidationError:
    sys.exit(0)
sys.exit("schema FAILED to reject unknown harness key")
PY
}
