#!/usr/bin/env bash
# framework-status.sh — Canonical route and native-model status for Lore settings.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
JSON_OUTPUT=0
case "${1:-}" in --json) JSON_OUTPUT=1; shift;; --help|-h) echo 'Usage: lore framework status [--json]' >&2; exit 0;; esac
[[ $# -eq 0 ]] || { echo "Error: unknown framework status flag '$1'" >&2; exit 1; }
DATA_DIR="${LORE_DATA_DIR:-$HOME/.lore}"
SETTINGS="$DATA_DIR/config/settings.json"
ACTIVE_FRAMEWORK="$(resolve_active_framework 2>/dev/null || true)"
python3 - "$SCRIPT_DIR" "$SETTINGS" "$JSON_OUTPUT" "$ACTIVE_FRAMEWORK" <<'PY'
import importlib.util, json, os, pathlib, sys
scripts, settings_path, json_output, active = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
spec = importlib.util.spec_from_file_location("route_config", scripts / "route_config.py")
route_config = importlib.util.module_from_spec(spec); spec.loader.exec_module(route_config)
def emit_error(kind, message, code=""):
    value={"config_status":kind,"config_path":str(settings_path),"error":{"code":code or kind,"message":message}}
    if json_output: print(json.dumps(value, indent=2))
    else:
        print(f"[config] {kind}: {message}")
        print("  Run: bash install.sh --framework <name>" if kind == "absent" else "  Repair settings, then run: lore framework status")
    raise SystemExit(2)
if not settings_path.exists(): emit_error("absent", f"settings not found at {settings_path}")
try: settings=json.loads(settings_path.read_text())
except (OSError,json.JSONDecodeError) as exc: emit_error("malformed", str(exc), "invalid_settings_json")
try:
    route_config.validate_settings(settings, scripts.parent)
    caps, roles_registry, _ = route_config.load_registries(scripts.parent)
    routes=[]
    for row in roles_registry["roles"]:
        route=route_config.resolve_route_for_role(row["id"], repo_root=scripts.parent, settings=settings, cwd=os.getcwd())
        routes.append({"requested_role":row["id"], **route})
except route_config.RouteConfigError as exc:
    path=f" at {exc.path}" if exc.path else ""
    emit_error("invalid", f"{exc.message}{path}", exc.code)
if active not in caps["frameworks"]: emit_error("invalid", "active framework does not name a registered framework", "unknown_framework")
overrides=settings.get("capability_overrides",{})
profile=caps["frameworks"][active]
capabilities=[]
for name, cell in profile.get("capabilities",{}).items():
    capabilities.append({"name":name,"support":overrides.get(name,cell.get("support","none")),"source":"override" if name in overrides else "profile","notes":cell.get("notes", ""),"evidence":cell.get("evidence", "")})
for name, support in overrides.items():
    if not any(row["name"] == name for row in capabilities):
        capabilities.append({"name":name,"support":support,"source":"override","notes":"","evidence":""})
native=settings["harnesses"][active]["native_models"]
out={"config_status":"present","config_path":str(settings_path),"framework":{"name":active,"display_name":profile.get("display_name",active),"binary":profile.get("binary",""),"model_routing":profile.get("model_routing",{})},"capabilities":capabilities,"routes":routes,"native_models":native,"artifacts":{"capabilities_profile":str(scripts.parent/"adapters/capabilities.json"),"capabilities_evidence":str(scripts.parent/"adapters/capabilities-evidence.md"),"framework_compatibility":str(scripts.parent/"docs/framework-compatibility.md")}}
if json_output: print(json.dumps(out,indent=2)); raise SystemExit(0)
print(f"[framework] {out['framework']['display_name']} ({active})")
print(f"  Config: {settings_path}")
print("\n[routes]")
for route in routes:
    src=route["routing_source"]; suffix="" if not route["options"] else " "+json.dumps(route["options"],sort_keys=True,separators=(',',':'))
    print(f"  {route['requested_role']} -> {route['framework']}/{route['model']}{suffix} ({src['layer']}:{src['role']})")
print(f"\n[native_models: {active}]")
for role, model in native.items(): print(f"  {role} -> {model}")
print("\n[capabilities]")
for row in capabilities: print(f"  {row['name']} -> {row['support']} ({row['source']})" + (f" — {row['notes']}" if row['notes'] else ""))
print("\n[artifacts]")
for name, path in out["artifacts"].items(): print(f"  {name}: {path}")
PY
