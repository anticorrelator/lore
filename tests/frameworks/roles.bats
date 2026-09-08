#!/usr/bin/env bats
# roles.bats — Validates adapters/roles.json, adapters/ceremonies.json, and
# the role->model binding rules enforced in scripts/lib.sh (Phase 1, T14).
#
# Coverage:
#   - roles.json parses as JSON and has the expected top-level shape.
#   - default_role is "default" and "default" appears in the closed role list.
#   - Every role id is unique within the registry.
#   - Every non-default role has at least one call_site (default has none).
#   - Every call_site path under repo root exists on disk (catches stale
#     references when a script/skill is renamed).
#   - ceremonies.json parses, has unique ids, and every call_site path exists.
#   - resolve_model_for_role rejects unknown role names with non-zero exit.
#   - resolve_model_for_role ceremony layer: ceremony binding beats the role
#     overlay, absent binding falls through, env override still wins, role-only
#     resolution is byte-identical, and unknown ceremony/role keys are rejected.
#   - validate_role_model_binding rejects: unknown role, empty model,
#     provider/model syntax under a single-shape harness.
#   - validate_role_model_binding accepts: bare model on any harness,
#     provider/model on a multi-shape harness.
#   - codex split_model_variant subcommand splits the effort suffix.
#   - claude-code model_routing.tiers ascend cheapest-first (chaperone reads [0]).
#
# Style: bats + python3 helpers, mirroring tests/frameworks/capabilities.bats.

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"
ROLES="$REPO_DIR/adapters/roles.json"
CEREMONIES="$REPO_DIR/adapters/ceremonies.json"
CAPS="$REPO_DIR/adapters/capabilities.json"
LIB="$REPO_DIR/scripts/lib.sh"
SET_MODEL="$REPO_DIR/scripts/framework-set-model.sh"

setup() {
  [ -f "$ROLES" ] || skip "adapters/roles.json missing"
  [ -f "$CAPS" ]  || skip "adapters/capabilities.json missing"
  [ -f "$LIB" ]   || skip "scripts/lib.sh missing"
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  FIXTURE_DIR="$(mktemp -d)"
  mkdir -p "$FIXTURE_DIR/config"
  export LORE_DATA_DIR="$FIXTURE_DIR"
  write_route_settings
}

teardown() {
  [ -n "${FIXTURE_DIR:-}" ] && rm -rf "$FIXTURE_DIR"
  unset LORE_DATA_DIR
}

# Write a settings.json fixture (JSON on stdin) into the per-test data dir.
# Callers point resolve_model_for_role at it with
# LORE_DATA_DIR="$FIXTURE_DIR" LORE_FRAMEWORK=<harness>.
write_settings() {
  python3 -c '
import json,sys
d=json.load(sys.stdin); hs=d.get("harnesses",{}); launch=d.get("tui_launch_framework","claude-code")
source=hs.get(launch,{}); roles=source.get("roles",{})
def qualify(v, fw=launch):
    return v if isinstance(v,dict) or any(v.startswith(x+"/") for x in ("claude-code","codex","opencode")) else fw+"/"+v
routes={k:qualify(v) for k,v in roles.items()}
routes.setdefault("default", "claude-code/opus")
overlays={}
for ceremony,bindings in source.get("ceremony_roles",{}).items():
    overlays[ceremony]={k:qualify(v) for k,v in bindings.items()}
if overlays: routes["ceremony_overlays"]=overlays
out={"version":2,"tui_launch_framework":d.get("tui_launch_framework","claude-code"),"routes":routes,"harnesses":{}}
for fw in ("claude-code","codex","opencode"):
    block=hs.get(fw,{})
    native={k:(v.split("/",1)[1] if isinstance(v,str) and v.startswith(fw+"/") else v) for k,v in block.get("roles",{}).items() if not (isinstance(v,str) and "/" in v and not v.startswith(fw+"/"))}
    native.setdefault("default", {"claude-code":"opus","codex":"gpt-5.5-high","opencode":"anthropic/opus"}[fw])
    out["harnesses"][fw]={"args":block.get("args",[]),"native_models":native}
json.dump(out,sys.stdout)
' > "$FIXTURE_DIR/config/settings.json"
}

parse_route_test() {
  jq -cn --arg root "$REPO_DIR" --arg route "$1" '{operation:"parse",repo_root:$root,route:$route}' \
    | python3 "$REPO_DIR/scripts/route_config.py"
}

write_route_settings() {
  cat > "$FIXTURE_DIR/config/settings.json" <<'JSON'
{"version":2,"tui_launch_framework":"claude-code","routes":{"default":"claude-code/opus","worker":{"framework":"codex","model":"gpt-5.6-sol","effort":"high","service_tier":"fast"},"ceremony_overlays":{"implement":{"advisor":"codex/gpt-6-astra-high"}}},"harnesses":{"claude-code":{"args":[],"native_models":{"default":"opus","advisor":"opus"}},"codex":{"args":[],"native_models":{"default":"gpt-5.5-high"}},"opencode":{"args":[],"native_models":{"default":"anthropic/opus"}}}}
JSON
}

@test "global route resolution preserves target options and provenance" {
  write_route_settings
  run env LORE_DATA_DIR="$FIXTURE_DIR" LORE_FRAMEWORK=claude-code bash -c "source '$LIB'; resolve_route_for_role worker implement"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.framework=="codex" and .model=="gpt-5.6-sol" and .options=={"effort":"high","service_tier":"fast"} and .routing_source.layer=="routes"'
}

@test "native route resolution uses the parent native map for a foreign global route" {
  write_route_settings
  run env LORE_DATA_DIR="$FIXTURE_DIR" LORE_FRAMEWORK=claude-code bash -c "source '$LIB'; resolve_native_route_for_role advisor implement claude-code"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.framework=="claude-code" and .model=="opus" and .routing_source.layer=="native-models"'
}

@test "route validation rejects malformed unused entries before selection" {
  write_route_settings
  jq '.routes.reviewer={framework:"codex",model:"gpt-5.5",bogus:true}' "$FIXTURE_DIR/config/settings.json" > "$FIXTURE_DIR/bad"
  mv "$FIXTURE_DIR/bad" "$FIXTURE_DIR/config/settings.json"
  run env LORE_DATA_DIR="$FIXTURE_DIR" LORE_FRAMEWORK=claude-code bash -c "source '$LIB'; resolve_route_for_role worker"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown route field"* ]]
}

@test "set-model persists a flat route object and overlays options after shorthand parsing" {
  write_route_settings
  run env LORE_DATA_DIR="$FIXTURE_DIR" bash "$SET_MODEL" set-model worker codex/gpt-5.5-high --service-tier fast --json
  [ "$status" -eq 0 ]
  jq -e '.routes.worker == {framework:"codex",model:"gpt-5.5",effort:"high",service_tier:"fast"}' "$FIXTURE_DIR/config/settings.json"
}

@test "set-model keeps an object model suffix literal and reports duplicate options as JSON" {
  write_route_settings
  run env LORE_DATA_DIR="$FIXTURE_DIR" bash "$SET_MODEL" set-model worker '{"framework":"codex","model":"custom-high"}' --json
  [ "$status" -eq 0 ]
  jq -e '.routes.worker == {framework:"codex",model:"custom-high"}' "$FIXTURE_DIR/config/settings.json"
  run env LORE_DATA_DIR="$FIXTURE_DIR" bash "$SET_MODEL" set-model worker '{"framework":"codex","model":"gpt-5.5","effort":"high"}' --effort medium --json
  [ "$status" -eq 3 ]
  echo "$output" | jq -e '.status == "binding-conflict" and (.message | contains("duplicates"))'
}

@test "set-model rejects empty option flags and unset-default validation stays structured" {
  write_route_settings
  run env LORE_DATA_DIR="$FIXTURE_DIR" bash "$SET_MODEL" set-model worker codex/gpt-5.5 --effort ""
  [ "$status" -eq 1 ]
  [[ "$output" == *"--effort requires a non-empty value"* ]]
  run env LORE_DATA_DIR="$FIXTURE_DIR" bash "$SET_MODEL" unset-model default --json
  [ "$status" -eq 3 ]
  echo "$output" | jq -e '.status == "binding-conflict" and (.message | contains("invalid"))'
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
    env["LORE_FRAMEWORK"] = "claude-code"
    # Hyphens in the role id map to underscores in the env-var name (class roles
    # like worker-mechanical) — the resolver derives the name the same way.
    # Built on its own line with double quotes to avoid clashing with the outer
    # single-quoted bash block and Python f-string quote nesting.
    env_key = "LORE_MODEL_" + role.upper().replace("-", "_")
    env[env_key] = "claude-code/stub-model"
    out = subprocess.check_output(["bash", "-c", f"source $LIB && resolve_model_for_role {role}"], env=env, text=True).strip()
    assert out == "stub-model", f"role {role}: got {out!r}"
PYEOF
  '
  [ "$status" -eq 0 ]
}

# ============================================================
# validate_role_model_binding tests
# ============================================================

@test "route parser requires a qualified model" {
  run parse_route_test sonnet
  [ "$status" -ne 0 ]
}

@test "validate_role_model_binding accepts bare model on opencode (multi shape)" {
  run parse_route_test opencode/anthropic/sonnet
  [ "$status" -eq 0 ]
}

@test "validate_role_model_binding rejects provider/model on claude-code (single shape)" {
  run parse_route_test claude-code/anthropic/sonnet
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid_model"* ]]
}

@test "validate_role_model_binding rejects provider/model on codex (single shape)" {
  run parse_route_test codex/openai/gpt-4
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid_model"* ]]
}

@test "validate_role_model_binding accepts provider/model on opencode (multi shape)" {
  run parse_route_test opencode/anthropic/sonnet
  [ "$status" -eq 0 ]
}

@test "route resolver rejects unknown role" {
  run bash -c "source '$LIB'; resolve_route_for_role bogus_role"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown role"* ]]
}

@test "route parser rejects empty model" {
  run parse_route_test claude-code/
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid_model"* ]]
}

# ============================================================
# ceremonies.json registry-shape tests
# ============================================================

@test "ceremonies.json parses as JSON" {
  [ -f "$CEREMONIES" ] || skip "adapters/ceremonies.json missing"
  run python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$CEREMONIES"
  [ "$status" -eq 0 ]
}

@test "ceremonies.json has required top-level keys" {
  [ -f "$CEREMONIES" ] || skip "adapters/ceremonies.json missing"
  run python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
missing = [k for k in ["version", "description", "ceremonies"] if k not in d]
if missing:
    print("missing keys:", missing); sys.exit(1)
' "$CEREMONIES"
  [ "$status" -eq 0 ]
}

@test "every ceremony id is unique" {
  [ -f "$CEREMONIES" ] || skip "adapters/ceremonies.json missing"
  run python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
ids = [c["id"] for c in d["ceremonies"]]
dupes = {i for i in ids if ids.count(i) > 1}
if dupes:
    print("duplicate ceremony ids:", sorted(dupes)); sys.exit(1)
' "$CEREMONIES"
  [ "$status" -eq 0 ]
}

@test "every ceremony has at least one call_site" {
  [ -f "$CEREMONIES" ] || skip "adapters/ceremonies.json missing"
  run python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
bad = [c["id"] for c in d["ceremonies"] if not (c.get("call_sites") or [])]
if bad:
    print("ceremonies missing call_sites:", bad); sys.exit(1)
' "$CEREMONIES"
  [ "$status" -eq 0 ]
}

@test "every ceremony call_site path exists under repo root" {
  [ -f "$CEREMONIES" ] || skip "adapters/ceremonies.json missing"
  REPO="$REPO_DIR" run python3 -c '
import json, os, sys
d = json.load(open(sys.argv[1]))
repo = os.environ["REPO"]
missing = []
for c in d["ceremonies"]:
    for cs in c.get("call_sites") or []:
        if not os.path.exists(os.path.join(repo, cs)):
            missing.append("{}:{}".format(c["id"], cs))
if missing:
    print("missing call_site paths:")
    for m in missing: print(" ", m)
    sys.exit(1)
' "$CEREMONIES"
  [ "$status" -eq 0 ]
}

# ============================================================
# resolve_model_for_role ceremony-layer tests (D2 precedence)
# ============================================================

@test "resolve_model_for_role ceremony binding beats the role overlay" {
  write_settings <<'JSON'
{ "version": 1, "tui_launch_framework": "claude-code",
  "harnesses": {
    "claude-code": { "args": [], "roles": {"researcher": "opus"},
      "ceremony_roles": { "spec": {"researcher": "haiku"} } },
    "opencode": {"args": []}, "codex": {"args": []} } }
JSON
  LORE_DATA_DIR="$FIXTURE_DIR" LORE_FRAMEWORK=claude-code run bash -c "source '$LIB'; resolve_model_for_role researcher spec"
  [ "$status" -eq 0 ]
  [ "$output" = "haiku" ]
}

@test "resolve_model_for_role falls through to role overlay when ceremony key absent" {
  write_settings <<'JSON'
{ "version": 1, "tui_launch_framework": "claude-code",
  "harnesses": {
    "claude-code": { "args": [], "roles": {"researcher": "opus"} },
    "opencode": {"args": []}, "codex": {"args": []} } }
JSON
  LORE_DATA_DIR="$FIXTURE_DIR" LORE_FRAMEWORK=claude-code run bash -c "source '$LIB'; resolve_model_for_role researcher spec"
  [ "$status" -eq 0 ]
  [ "$output" = "opus" ]
}

@test "resolve_model_for_role falls through when role absent inside ceremony map" {
  write_settings <<'JSON'
{ "version": 1, "tui_launch_framework": "claude-code",
  "harnesses": {
    "claude-code": { "args": [], "roles": {"researcher": "opus", "lead": "sonnet"},
      "ceremony_roles": { "spec": {"lead": "fable"} } },
    "opencode": {"args": []}, "codex": {"args": []} } }
JSON
  LORE_DATA_DIR="$FIXTURE_DIR" LORE_FRAMEWORK=claude-code run bash -c "source '$LIB'; resolve_model_for_role researcher spec"
  [ "$status" -eq 0 ]
  [ "$output" = "opus" ]
}

@test "resolve_model_for_role role-only invocation ignores ceremony_roles (byte-identical)" {
  write_settings <<'JSON'
{ "version": 1, "tui_launch_framework": "claude-code",
  "harnesses": {
    "claude-code": { "args": [], "roles": {"researcher": "opus"},
      "ceremony_roles": { "spec": {"researcher": "haiku"} } },
    "opencode": {"args": []}, "codex": {"args": []} } }
JSON
  LORE_DATA_DIR="$FIXTURE_DIR" LORE_FRAMEWORK=claude-code run bash -c "source '$LIB'; resolve_model_for_role researcher"
  [ "$status" -eq 0 ]
  [ "$output" = "opus" ]
}

@test "resolve_model_for_role env override beats the ceremony binding" {
  write_settings <<'JSON'
{ "version": 1, "tui_launch_framework": "claude-code",
  "harnesses": {
    "claude-code": { "args": [], "roles": {"researcher": "opus"},
      "ceremony_roles": { "spec": {"researcher": "haiku"} } },
    "opencode": {"args": []}, "codex": {"args": []} } }
JSON
  LORE_DATA_DIR="$FIXTURE_DIR" LORE_FRAMEWORK=claude-code LORE_MODEL_RESEARCHER=claude-code/sonnet run bash -c "source '$LIB'; resolve_model_for_role researcher spec"
  [ "$status" -eq 0 ]
  [ "$output" = "sonnet" ]
}

@test "resolve_model_for_role pr-review ceremony binding beats the reviewer overlay" {
  write_settings <<'JSON'
{ "version": 1, "tui_launch_framework": "claude-code",
  "harnesses": {
    "claude-code": { "args": [], "roles": {"reviewer": "opus"},
      "ceremony_roles": { "pr-review": {"reviewer": "haiku"} } },
    "opencode": {"args": []}, "codex": {"args": []} } }
JSON
  LORE_DATA_DIR="$FIXTURE_DIR" LORE_FRAMEWORK=claude-code run bash -c "source '$LIB'; resolve_model_for_role reviewer pr-review"
  [ "$status" -eq 0 ]
  [ "$output" = "haiku" ]
}

@test "resolve_model_for_role reviewer pr-review falls through to the reviewer overlay when the ceremony key is absent" {
  write_settings <<'JSON'
{ "version": 1, "tui_launch_framework": "claude-code",
  "harnesses": {
    "claude-code": { "args": [], "roles": {"reviewer": "opus"} },
    "opencode": {"args": []}, "codex": {"args": []} } }
JSON
  LORE_DATA_DIR="$FIXTURE_DIR" LORE_FRAMEWORK=claude-code run bash -c "source '$LIB'; resolve_model_for_role reviewer pr-review"
  [ "$status" -eq 0 ]
  [ "$output" = "opus" ]
}

@test "resolve_model_for_role rejects unknown ceremony in the query" {
  run bash -c "source '$LIB'; resolve_model_for_role researcher bogus_ceremony"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown ceremony"* ]]
  [[ "$output" == *"unknown ceremony"* ]]
}

@test "resolve_model_for_role rejects unknown ceremony key stored under ceremony_roles" {
  write_settings <<'JSON'
{ "version": 1, "tui_launch_framework": "claude-code",
  "harnesses": {
    "claude-code": { "args": [], "roles": {"researcher": "opus"},
      "ceremony_roles": { "deploy": {"researcher": "haiku"} } },
    "opencode": {"args": []}, "codex": {"args": []} } }
JSON
  LORE_DATA_DIR="$FIXTURE_DIR" LORE_FRAMEWORK=claude-code run bash -c "source '$LIB'; resolve_model_for_role researcher spec"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown ceremony 'deploy'"* ]]
  [[ "$output" == *"unknown ceremony"* ]]
}

@test "resolve_model_for_role rejects unknown role key inside a ceremony map" {
  write_settings <<'JSON'
{ "version": 1, "tui_launch_framework": "claude-code",
  "harnesses": {
    "claude-code": { "args": [], "roles": {"researcher": "opus"},
      "ceremony_roles": { "spec": {"spectator": "haiku"} } },
    "opencode": {"args": []}, "codex": {"args": []} } }
JSON
  LORE_DATA_DIR="$FIXTURE_DIR" LORE_FRAMEWORK=claude-code run bash -c "source '$LIB'; resolve_model_for_role researcher spec"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown role 'spectator'"* ]]
  [[ "$output" == *"unknown role"* ]]
}

# ============================================================
# Class-qualified worker roles: registry-driven fallback_role (D2)
# ============================================================

@test "roles.json declares fallback_role: worker for both class-qualified roles" {
  run python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
by_id = {r["id"]: r for r in d["roles"]}
for rid in ("worker-mechanical", "worker-judgment-dense"):
    assert rid in by_id, rid + " missing from roles.json"
    got = by_id[rid].get("fallback_role")
    assert got == "worker", rid + " fallback_role: " + repr(got)
' "$ROLES"
  [ "$status" -eq 0 ]
}

@test "every fallback_role target is a valid role with no fallback of its own (single-hop)" {
  # Guarantees the resolver'"'"'s fallback re-resolution terminates after one
  # hop: no fallback chain can form.
  run python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
by_id = {r["id"]: r for r in d["roles"]}
for r in d["roles"]:
    fb = r.get("fallback_role")
    if fb is None:
        continue
    assert fb in by_id, r["id"] + ": fallback_role " + repr(fb) + " not a known role"
    assert not by_id[fb].get("fallback_role"), r["id"] + ": fallback target " + repr(fb) + " has its own fallback_role (would chain)"
' "$ROLES"
  [ "$status" -eq 0 ]
}

@test "unbound class role resolves exactly as plain worker (role overlay)" {
  write_settings <<'JSON'
{ "version": 1, "tui_launch_framework": "claude-code",
  "harnesses": {
    "claude-code": { "args": [], "roles": {"worker": "sonnet"} },
    "opencode": {"args": []}, "codex": {"args": []} } }
JSON
  wm=$(LORE_DATA_DIR="$FIXTURE_DIR" LORE_FRAMEWORK=claude-code bash -c "source '$LIB'; resolve_model_for_role worker-mechanical implement")
  w=$(LORE_DATA_DIR="$FIXTURE_DIR" LORE_FRAMEWORK=claude-code bash -c "source '$LIB'; resolve_model_for_role worker implement")
  [ "$wm" = "sonnet" ]
  [ "$wm" = "$w" ]
}

@test "unbound class role falls through to roles.default just as worker does" {
  write_settings <<'JSON'
{ "version": 1, "tui_launch_framework": "claude-code",
  "harnesses": {
    "claude-code": { "args": [], "roles": {"default": "opus"} },
    "opencode": {"args": []}, "codex": {"args": []} } }
JSON
  wm=$(LORE_DATA_DIR="$FIXTURE_DIR" LORE_FRAMEWORK=claude-code bash -c "source '$LIB'; resolve_model_for_role worker-judgment-dense implement")
  w=$(LORE_DATA_DIR="$FIXTURE_DIR" LORE_FRAMEWORK=claude-code bash -c "source '$LIB'; resolve_model_for_role worker implement")
  [ "$wm" = "opus" ]
  [ "$wm" = "$w" ]
}

@test "class role bound in ceremony_roles wins over the fallback" {
  write_settings <<'JSON'
{ "version": 1, "tui_launch_framework": "claude-code",
  "harnesses": {
    "claude-code": { "args": [], "roles": {"worker": "sonnet"},
      "ceremony_roles": { "implement": {"worker-mechanical": "haiku"} } },
    "opencode": {"args": []}, "codex": {"args": []} } }
JSON
  wm=$(LORE_DATA_DIR="$FIXTURE_DIR" LORE_FRAMEWORK=claude-code bash -c "source '$LIB'; resolve_model_for_role worker-mechanical implement")
  [ "$wm" = "haiku" ]
}

@test "class role bound in the role overlay wins over the fallback" {
  write_settings <<'JSON'
{ "version": 1, "tui_launch_framework": "claude-code",
  "harnesses": {
    "claude-code": { "args": [], "roles": {"worker": "sonnet", "worker-mechanical": "haiku"} },
    "opencode": {"args": []}, "codex": {"args": []} } }
JSON
  wm=$(LORE_DATA_DIR="$FIXTURE_DIR" LORE_FRAMEWORK=claude-code bash -c "source '$LIB'; resolve_model_for_role worker-mechanical implement")
  [ "$wm" = "haiku" ]
}

@test "class role env override uses the underscore-normalized name" {
  write_settings <<'JSON'
{ "version": 1, "tui_launch_framework": "claude-code",
  "harnesses": {
    "claude-code": { "args": [], "roles": {"worker": "sonnet"} },
    "opencode": {"args": []}, "codex": {"args": []} } }
JSON
  wm=$(LORE_DATA_DIR="$FIXTURE_DIR" LORE_FRAMEWORK=claude-code LORE_MODEL_WORKER_MECHANICAL=claude-code/mech-model \
    bash -c "source '$LIB'; resolve_model_for_role worker-mechanical implement")
  [ "$wm" = "mech-model" ]
}

@test "unbound class role reaches the required global default when nothing else binds" {
  write_settings <<'JSON'
{ "version": 1, "tui_launch_framework": "claude-code",
  "harnesses": { "claude-code": { "args": [] }, "opencode": {"args": []}, "codex": {"args": []} } }
JSON
  LORE_DATA_DIR="$FIXTURE_DIR" LORE_FRAMEWORK=claude-code run bash -c "source '$LIB'; resolve_model_for_role worker-mechanical implement"
  [ "$status" -eq 0 ]
  [ "$output" = "opus" ]
}

# ============================================================
# Framework-qualified structured routes
# ============================================================

@test "resolve_route_for_role preserves an unqualified OpenCode provider/model binding" {
  write_settings <<'JSON'
{ "version": 1, "tui_launch_framework": "opencode",
  "harnesses": {
    "claude-code": {"args": []},
    "opencode": {"args": [], "roles": {"worker": "openai/gpt-5.5"}},
    "codex": {"args": []} } }
JSON
  LORE_DATA_DIR="$FIXTURE_DIR" LORE_FRAMEWORK=opencode run bash -c "source '$LIB'; resolve_route_for_role worker implement"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.framework')" = "opencode" ]
  [ "$(printf '%s' "$output" | jq -r '.model')" = "openai/gpt-5.5" ]
}

@test "resolve_route_for_role selects a registered Codex target and strips only its qualifier" {
  write_settings <<'JSON'
{ "version": 1, "tui_launch_framework": "claude-code",
  "harnesses": {
    "claude-code": {"args": [], "roles": {"worker-mechanical": "codex/gpt-5.5-medium"}},
    "opencode": {"args": []}, "codex": {"args": []} } }
JSON
  LORE_DATA_DIR="$FIXTURE_DIR" LORE_FRAMEWORK=claude-code run bash -c "source '$LIB'; resolve_route_for_role worker-mechanical implement"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.framework')" = "codex" ]
  [ "$(printf '%s' "$output" | jq -r '.model')" = "gpt-5.5" ]
  [ "$(printf '%s' "$output" | jq -r '.options.effort')" = "medium" ]
}

@test "resolve_route_for_role strips same-framework qualifiers for every registered framework" {
  cases=(
    "claude-code|claude-code/sonnet|sonnet"
    "opencode|opencode/openai/gpt-5.5|openai/gpt-5.5"
    "codex|codex/gpt-5.5-high|gpt-5.5-high"
  )
  for case_value in "${cases[@]}"; do
    IFS='|' read -r framework binding native <<<"$case_value"
    route=$(LORE_FRAMEWORK="$framework" LORE_MODEL_WORKER="$binding" bash -c "source '$LIB'; resolve_route_for_role worker")
    [ "$(printf '%s' "$route" | jq -r '.framework')" = "$framework" ]
    if [ "$framework" = codex ]; then
      [ "$(printf '%s' "$route" | jq -r '.model')-$(printf '%s' "$route" | jq -r '.options.effort')" = "gpt-5.5-high" ]
    else
      [ "$(printf '%s' "$route" | jq -r '.model')" = "$native" ]
    fi
  done
}

@test "resolve_route_for_role class miss remains exactly the plain worker route" {
  write_settings <<'JSON'
{ "version": 1, "tui_launch_framework": "claude-code",
  "harnesses": {
    "claude-code": {"args": [], "roles": {"worker": "codex/gpt-5.5-high"}},
    "opencode": {"args": []}, "codex": {"args": []} } }
JSON
  class_route=$(LORE_DATA_DIR="$FIXTURE_DIR" LORE_FRAMEWORK=claude-code bash -c "source '$LIB'; resolve_route_for_role worker-judgment-dense implement")
  worker_route=$(LORE_DATA_DIR="$FIXTURE_DIR" LORE_FRAMEWORK=claude-code bash -c "source '$LIB'; resolve_route_for_role worker implement")
  [ "$class_route" = "$worker_route" ]
}

@test "resolve_route_for_role rejects a registered qualifier with empty native payload" {
  write_settings <<'JSON'
{ "version": 1, "tui_launch_framework": "claude-code",
  "harnesses": {
    "claude-code": {"args": [], "roles": {"worker": "codex/"}},
    "opencode": {"args": []}, "codex": {"args": []} } }
JSON
  LORE_DATA_DIR="$FIXTURE_DIR" LORE_FRAMEWORK=claude-code run bash -c "source '$LIB'; resolve_route_for_role worker"
  [ "$status" -ne 0 ]
  [[ "$output" == *"must not be empty"* ]]
}

@test "resolve_route_for_role validates the native payload against the selected target shape" {
  write_settings <<'JSON'
{ "version": 1, "tui_launch_framework": "claude-code",
  "harnesses": {
    "claude-code": {"args": [], "roles": {"worker": "codex/openai/gpt-5.5"}},
    "opencode": {"args": []}, "codex": {"args": []} } }
JSON
  LORE_DATA_DIR="$FIXTURE_DIR" LORE_FRAMEWORK=claude-code run bash -c "source '$LIB'; resolve_route_for_role worker"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires a native model without a provider prefix"* ]]
}

@test "resolve_route_for_role permits a registered foreign global route" {
  write_settings <<'JSON'
{ "version": 1, "tui_launch_framework": "claude-code",
  "harnesses": {
    "claude-code": {"args": [], "roles": {"worker": "opencode/openai/gpt-5.5"}},
    "opencode": {"args": []}, "codex": {"args": []} } }
JSON
  LORE_DATA_DIR="$FIXTURE_DIR" LORE_FRAMEWORK=claude-code run bash -c "source '$LIB'; resolve_route_for_role worker"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.framework == "opencode" and .model == "openai/gpt-5.5"'
}

@test "validate_role_model_binding accepts a supported qualified Codex route" {
  run parse_route_test codex/gpt-5.5-medium
  [ "$status" -eq 0 ]
}

@test "Codex effort splitting receives only the route's native payload" {
  route=$(LORE_FRAMEWORK=claude-code LORE_MODEL_WORKER=codex/gpt-5.5-medium \
    bash -c "source '$LIB'; resolve_route_for_role worker")
  native=$(printf '%s' "$route" | jq -r '.native_binding')
  run bash "$REPO_DIR/adapters/agents/codex.sh" split_model_variant "$native"
  [ "$status" -eq 0 ]
  [[ "$output" == *"model=gpt-5.5"* ]]
  [[ "$output" == *"reasoning_effort=medium"* ]]
  [[ "$output" != *"codex/"* ]]
}

# ============================================================
# codex split_model_variant subcommand
# ============================================================

@test "codex split_model_variant splits the effort suffix" {
  run bash "$REPO_DIR/adapters/agents/codex.sh" split_model_variant gpt-5.5-high
  [ "$status" -eq 0 ]
  [[ "$output" == *"model=gpt-5.5"* ]]
  [[ "$output" == *"reasoning_effort=high"* ]]
}

@test "codex split_model_variant on a bare model emits model= only" {
  run bash "$REPO_DIR/adapters/agents/codex.sh" split_model_variant gpt-5.5
  [ "$status" -eq 0 ]
  [ "$output" = "model=gpt-5.5" ]
}

# ============================================================
# capabilities.json model_routing.tiers ordering contract
# ============================================================

@test "claude-code model_routing.tiers ascend cheapest-first (codex-worker chaperone presents tiers[0])" {
  # At codex-dispatch the lead puts the chaperone's tier to the user (see
  # skills/implement/templates/worker-spawn.md) — tiers[0] as the cheapest
  # option per the wrapper design, or opus per the standing model floor. The
  # ladder must stay cheapest-first so tiers[0] is genuinely the cheapest option
  # presented; if it is reordered, the "cheapest" option is a lie. Pin the order.
  run python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
tiers = d["frameworks"]["claude-code"]["model_routing"]["tiers"]
expected = ["haiku", "sonnet", "opus", "fable"]
assert tiers == expected, "claude-code model_routing.tiers drifted from cheapest-first {}: {}".format(expected, tiers)
' "$CAPS"
  [ "$status" -eq 0 ]
}
