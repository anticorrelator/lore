#!/usr/bin/env python3
"""Generate registry-derived routing definitions in settings.schema.json."""

from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path


def generated(root: Path) -> dict:
    capabilities = json.loads((root / "adapters/capabilities.json").read_text())
    roles = [row["id"] for row in json.loads((root / "adapters/roles.json").read_text())["roles"]]
    ceremonies = [row["id"] for row in json.loads((root / "adapters/ceremonies.json").read_text())["ceremonies"]]
    frameworks = list(capabilities["frameworks"])
    branches = []
    for framework in frameworks:
        options = capabilities["frameworks"][framework]["model_routing"].get("options", {})
        properties = {
            "framework": {"const": framework},
            "model": {"type": "string", "minLength": 1},
        }
        for option, values in options.items():
            properties[option] = {"type": "string", "enum": values}
        branches.append({"type": "object", "additionalProperties": False, "required": ["framework", "model"], "properties": properties})
    route = {
        "description": "A qualified route shorthand or closed framework-specific route object.",
        "oneOf": [
            {"type": "string", "minLength": 3, "pattern": "^(" + "|".join(frameworks) + ")/.+"},
            *branches,
        ],
    }
    roles_properties = {role: {"$ref": "#/$defs/route_value"} for role in roles}
    overlay_map = {ceremony: {"$ref": "#/$defs/route_roles_overlay"} for ceremony in ceremonies}
    native_properties = {role: {"type": "string", "minLength": 1} for role in roles}
    return {
        "route_value": route,
        "route_roles_overlay": {"type": "object", "additionalProperties": False, "properties": roles_properties},
        "ceremony_route_overlays": {"type": "object", "additionalProperties": False, "properties": overlay_map},
        "routes_config": {
            "type": "object", "additionalProperties": False, "required": ["default"],
            "properties": {**roles_properties, "ceremony_overlays": {"$ref": "#/$defs/ceremony_route_overlays"}},
        },
        "native_models": {
            "type": "object", "additionalProperties": False, "required": ["default"], "properties": native_properties,
        },
    }


def update(schema: dict, root: Path) -> dict:
    schema = copy.deepcopy(schema)
    caps = json.loads((root / "adapters/capabilities.json").read_text())
    roles = [row["id"] for row in json.loads((root / "adapters/roles.json").read_text())["roles"]]
    ceremonies = [row["id"] for row in json.loads((root / "adapters/ceremonies.json").read_text())["ceremonies"]]
    frameworks = list(caps["frameworks"])
    schema["properties"]["version"] = {"const": 2, "description": "Settings schema version."}
    schema["required"] = list(dict.fromkeys([*schema["required"], "routes"]))
    schema["properties"]["routes"] = {"$ref": "#/$defs/routes_config"}
    schema["$defs"]["framework_id"]["enum"] = frameworks
    schema["properties"]["harnesses"]["properties"] = {fw: {"$ref": "#/$defs/harness_block"} for fw in frameworks}
    schema["$defs"]["role_id"]["enum"] = roles
    schema["$defs"]["ceremony_id"]["enum"] = ceremonies
    for retired in ("role_value", "roles_map_overlay", "ceremony_roles"):
        schema["$defs"].pop(retired, None)
    schema["$defs"].update(generated(root))
    harness = schema["$defs"]["harness_block"]
    harness["required"] = list(dict.fromkeys([*harness["required"], "native_models"]))
    harness["properties"].pop("roles", None)
    harness["properties"].pop("ceremony_roles", None)
    harness["properties"]["native_models"] = {"$ref": "#/$defs/native_models"}
    return schema


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--repo-root", default=str(Path(__file__).resolve().parents[1]))
    args = parser.parse_args()
    root = Path(args.repo_root)
    path = root / "adapters/settings.schema.json"
    original = json.loads(path.read_text())
    result = update(original, root)
    rendered = json.dumps(result, indent=2, ensure_ascii=False) + "\n"
    if args.check:
        if path.read_text() != rendered:
            print(f"{path} is not generated from the route registries")
            return 1
    else:
        path.write_text(rendered)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
