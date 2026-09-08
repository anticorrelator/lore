#!/usr/bin/env python3
"""Canonical parsing and selection for Lore session routes."""

from __future__ import annotations

import argparse
import json
import os
import shlex
import sys
from pathlib import Path
from typing import Any, Mapping


class RouteConfigError(ValueError):
    def __init__(self, code: str, message: str, path: str = "") -> None:
        super().__init__(message)
        self.code, self.message, self.path = code, message, path

    def as_dict(self) -> dict[str, Any]:
        value: dict[str, Any] = {"code": self.code, "message": self.message}
        if self.path:
            value["path"] = self.path
        return value


def _load_json(path: Path, code: str) -> Any:
    try:
        with path.open(encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        raise RouteConfigError(code, f"cannot read {path}: {exc}", str(path)) from exc


def load_registries(repo_root: str | os.PathLike[str]) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any]]:
    root = Path(repo_root)
    result = (
        _load_json(root / "adapters/capabilities.json", "registry_unavailable"),
        _load_json(root / "adapters/roles.json", "registry_unavailable"),
        _load_json(root / "adapters/ceremonies.json", "registry_unavailable"),
    )
    capabilities, roles, ceremonies = result
    if not isinstance(capabilities, dict) or not isinstance(capabilities.get("frameworks"), dict):
        raise RouteConfigError("invalid_registry", "capabilities registry must contain a frameworks object", "adapters/capabilities.json")
    for framework, block in capabilities["frameworks"].items():
        routing = block.get("model_routing") if isinstance(block, dict) else None
        if not isinstance(framework, str) or not framework or not isinstance(routing, dict) or routing.get("shape") not in {"single", "multi"} or not isinstance(routing.get("options"), dict):
            raise RouteConfigError("invalid_registry", f"framework '{framework}' has malformed model_routing", f"frameworks.{framework}.model_routing")
        for option, values in routing["options"].items():
            if not isinstance(option, str) or not isinstance(values, list) or any(not isinstance(item, str) or not item for item in values) or len(values) != len(set(values)):
                raise RouteConfigError("invalid_registry", f"framework '{framework}' has malformed option '{option}'", f"frameworks.{framework}.model_routing.options.{option}")
    if not isinstance(roles, dict) or not isinstance(roles.get("roles"), list):
        raise RouteConfigError("invalid_registry", "roles registry must contain a roles array", "adapters/roles.json")
    if not isinstance(ceremonies, dict) or not isinstance(ceremonies.get("ceremonies"), list):
        raise RouteConfigError("invalid_registry", "ceremonies registry must contain a ceremonies array", "adapters/ceremonies.json")
    return result


def _source(layer: str, role: str, ceremony: str | None = None) -> dict[str, str]:
    result = {"layer": layer, "role": role}
    if ceremony is not None:
        result["ceremony"] = ceremony
    return result


def _validate_source(value: Any) -> dict[str, str]:
    if not isinstance(value, dict) or set(value) - {"layer", "role", "ceremony"}:
        raise RouteConfigError("invalid_routing_source", "routing_source must contain only layer, role, and optional ceremony", "routing_source")
    if value.get("layer") not in {"env", "per-repo", "ceremony-overlay", "routes", "default", "override", "native-models"}:
        raise RouteConfigError("invalid_routing_source", "routing_source.layer is invalid", "routing_source.layer")
    if not isinstance(value.get("role"), str) or not value["role"]:
        raise RouteConfigError("invalid_routing_source", "routing_source.role is required", "routing_source.role")
    if "ceremony" in value and (not isinstance(value["ceremony"], str) or not value["ceremony"]):
        raise RouteConfigError("invalid_routing_source", "routing_source.ceremony must be a non-empty string", "routing_source.ceremony")
    return dict(value)


_NO_SOURCE = object()


def parse_route(value: Any, repo_root: str | os.PathLike[str], routing_source: Any = _NO_SOURCE, *, allow_canonical: bool = True) -> dict[str, Any]:
    """Parse a route shorthand/object into {framework, model, options[, routing_source]}."""
    capabilities, _, _ = load_registries(repo_root)
    frameworks = capabilities.get("frameworks", {})
    if isinstance(value, str):
        if not value:
            raise RouteConfigError("invalid_route", "route string must not be empty")
        framework, separator, model = value.partition("/")
        if not separator or framework not in frameworks:
            raise RouteConfigError("unknown_framework" if separator else "missing_framework", "route string must start with a registered framework and '/'", "framework")
        if not model:
            raise RouteConfigError("invalid_model", "route model must not be empty", "model")
        options: dict[str, str] = {}
        if framework == "codex":
            allowed_efforts = frameworks[framework].get("model_routing", {}).get("options", {}).get("effort", [])
            head, dash, suffix = model.rpartition("-")
            if dash and suffix in allowed_efforts and head:
                model, options["effort"] = head, suffix
    elif isinstance(value, dict):
        if "options" in value or "routing_source" in value:
            if not allow_canonical:
                field = "options" if "options" in value else "routing_source"
                raise RouteConfigError("canonical_route_in_settings", f"canonical field '{field}' is not accepted in settings", field)
            unknown = sorted(set(value) - {"framework", "model", "options", "routing_source"})
            if unknown:
                raise RouteConfigError("unknown_route_field", f"unknown canonical route field '{unknown[0]}'", unknown[0])
            raw_options = value.get("options")
            if not isinstance(raw_options, dict):
                raise RouteConfigError("invalid_route_options", "route.options must be an object", "options")
            raw_framework = value.get("framework")
            declared_options = frameworks.get(raw_framework, {}).get("model_routing", {}).get("options", {})
            unknown_options = set(raw_options) - set(declared_options)
            if unknown_options:
                key = sorted(unknown_options)[0]
                raise RouteConfigError("unknown_route_option", f"unknown route option '{key}'", f"options.{key}")
            canonical_source_present = "routing_source" in value
            canonical_source = value.get("routing_source")
            value = {"framework": value.get("framework"), "model": value.get("model"), **raw_options}
            if routing_source is _NO_SOURCE and canonical_source_present:
                routing_source = canonical_source
        allowed = {"framework", "model", "effort", "service_tier"}
        unknown = sorted(set(value) - allowed)
        if unknown:
            raise RouteConfigError("unknown_route_field", f"unknown route field '{unknown[0]}'", unknown[0])
        framework = value.get("framework")
        model = value.get("model")
        if not isinstance(framework, str) or not framework:
            raise RouteConfigError("missing_framework", "route.framework is required", "framework")
        if framework not in frameworks:
            raise RouteConfigError("unknown_framework", f"unknown framework '{framework}'", "framework")
        if not isinstance(model, str) or not model:
            raise RouteConfigError("invalid_model", "route.model must be a non-empty string", "model")
        options = {key: value[key] for key in ("effort", "service_tier") if key in value}
    else:
        raise RouteConfigError("invalid_route", "route must be a qualified string or object")

    declarations = frameworks[framework].get("model_routing", {}).get("options", {})
    for option, option_value in options.items():
        if option not in declarations:
            raise RouteConfigError("unknown_route_option", f"framework '{framework}' does not support option '{option}'", option)
        if not isinstance(option_value, str) or not option_value or option_value not in declarations[option]:
            raise RouteConfigError("invalid_route_option", f"invalid {option} for framework '{framework}'", option)
    shape = frameworks[framework].get("model_routing", {}).get("shape")
    if shape not in {"single", "multi"}:
        raise RouteConfigError("invalid_registry", f"framework '{framework}' has invalid model routing shape", f"frameworks.{framework}.model_routing.shape")
    if shape == "single" and "/" in model:
        raise RouteConfigError("invalid_model_shape", f"framework '{framework}' requires a native model without a provider prefix", "model")
    if shape == "multi" and "/" not in model:
        raise RouteConfigError("invalid_model_shape", f"framework '{framework}' requires provider/model", "model")
    if shape == "multi" and any(not part for part in model.split("/", 1)):
        raise RouteConfigError("invalid_model_shape", f"framework '{framework}' requires non-empty provider/model parts", "model")
    result: dict[str, Any] = {"framework": framework, "model": model, "options": options}
    if routing_source is not _NO_SOURCE:
        result["routing_source"] = _validate_source(routing_source)
    return result


def _ids(registry: dict[str, Any], key: str) -> list[str]:
    try:
        result = [entry["id"] for entry in registry[key] if isinstance(entry, dict)]
    except (KeyError, TypeError) as exc:
        raise RouteConfigError("invalid_registry", f"{key} registry rows require string ids", key) from exc
    if len(result) != len(registry[key]) or any(not isinstance(value, str) or not value for value in result) or len(set(result)) != len(result):
        raise RouteConfigError("invalid_registry", f"{key} registry rows require distinct non-empty string ids", key)
    return result


def validate_settings(settings: Any, repo_root: str | os.PathLike[str]) -> dict[str, Any]:
    """Validate the complete version-2 routing subtree and return settings unchanged."""
    capabilities, roles_registry, ceremonies_registry = load_registries(repo_root)
    if not isinstance(settings, dict):
        raise RouteConfigError("invalid_settings", "settings must be an object")
    schema = _load_json(Path(repo_root) / "adapters/settings.schema.json", "registry_unavailable")
    root_properties = set(schema.get("properties", {}))
    unknown_root = sorted(set(settings) - root_properties)
    if unknown_root:
        raise RouteConfigError("unknown_settings_key", f"unknown settings key '{unknown_root[0]}'", unknown_root[0])
    for required in schema.get("required", []):
        if required not in settings:
            raise RouteConfigError("missing_settings_key", f"settings.{required} is required", required)
    if settings.get("version") != 2:
        raise RouteConfigError("unsupported_settings_version", "routing requires settings version 2", "version")
    frameworks = set(capabilities.get("frameworks", {}))
    roles = set(_ids(roles_registry, "roles"))
    ceremonies = set(_ids(ceremonies_registry, "ceremonies"))
    if settings.get("tui_launch_framework") not in frameworks:
        raise RouteConfigError("unknown_framework", "tui_launch_framework must name a registered framework", "tui_launch_framework")
    role_rows = {row["id"]: row for row in roles_registry["roles"]}
    for start in sorted(roles):
        seen: set[str] = set()
        current: str | None = start
        while current is not None:
            if current not in role_rows or current in seen:
                raise RouteConfigError("fallback_cycle", f"invalid fallback chain from '{start}'", "roles")
            seen.add(current)
            fallback = role_rows[current].get("fallback_role")
            if fallback is not None and not isinstance(fallback, str):
                raise RouteConfigError("invalid_registry", "fallback_role must be a string", "roles")
            current = fallback
    routes = settings.get("routes")
    if not isinstance(routes, dict):
        raise RouteConfigError("missing_routes", "settings.routes must be an object", "routes")
    unknown_route_keys = set(routes) - roles - {"ceremony_overlays"}
    if unknown_route_keys:
        key = sorted(unknown_route_keys)[0]
        raise RouteConfigError("unknown_role", f"unknown route role '{key}'", f"routes.{key}")
    if "default" not in routes:
        raise RouteConfigError("missing_default_route", "settings.routes.default is required", "routes.default")
    for role in sorted(roles & set(routes)):
        try:
            parse_route(routes[role], repo_root, allow_canonical=False)
        except RouteConfigError as exc:
            exc.path = f"routes.{role}" + (f".{exc.path}" if exc.path else "")
            raise
    overlays = routes.get("ceremony_overlays", {})
    if not isinstance(overlays, dict):
        raise RouteConfigError("invalid_ceremony_overlays", "routes.ceremony_overlays must be an object", "routes.ceremony_overlays")
    for ceremony in sorted(overlays):
        bindings = overlays[ceremony]
        if ceremony not in ceremonies:
            raise RouteConfigError("unknown_ceremony", f"unknown ceremony '{ceremony}'", f"routes.ceremony_overlays.{ceremony}")
        if not isinstance(bindings, dict):
            raise RouteConfigError("invalid_ceremony_overlay", "ceremony overlay must be an object", f"routes.ceremony_overlays.{ceremony}")
        for role in sorted(bindings):
            value = bindings[role]
            if role not in roles:
                raise RouteConfigError("unknown_role", f"unknown role '{role}'", f"routes.ceremony_overlays.{ceremony}.{role}")
            try:
                parse_route(value, repo_root, allow_canonical=False)
            except RouteConfigError as exc:
                exc.path = f"routes.ceremony_overlays.{ceremony}.{role}" + (f".{exc.path}" if exc.path else "")
                raise
    harnesses = settings.get("harnesses")
    if not isinstance(harnesses, dict):
        raise RouteConfigError("invalid_harnesses", "settings.harnesses must be an object", "harnesses")
    for harness in sorted(harnesses):
        block = harnesses[harness]
        if harness not in frameworks:
            raise RouteConfigError("unknown_framework", f"unknown harness '{harness}'", f"harnesses.{harness}")
        if not isinstance(block, dict):
            raise RouteConfigError("invalid_harness", "harness settings must be an object", f"harnesses.{harness}")
        for retired in ("roles", "ceremony_roles"):
            if retired in block:
                raise RouteConfigError("retired_settings_key", f"harnesses.{harness}.{retired} is retired", f"harnesses.{harness}.{retired}")
        allowed_harness = set(schema["$defs"]["harness_block"]["properties"])
        unknown_harness = sorted(set(block) - allowed_harness)
        if unknown_harness:
            key = unknown_harness[0]
            raise RouteConfigError("unknown_harness_key", f"unknown harness setting '{key}'", f"harnesses.{harness}.{key}")
        if not isinstance(block.get("args"), list) or any(not isinstance(item, str) for item in block["args"]):
            raise RouteConfigError("invalid_harness_args", "harness args must be an array of strings", f"harnesses.{harness}.args")
        native = block.get("native_models")
        if not isinstance(native, dict) or "default" not in native:
            raise RouteConfigError("missing_native_default", f"harnesses.{harness}.native_models.default is required", f"harnesses.{harness}.native_models.default")
        for role in sorted(native):
            binding = native[role]
            if role not in roles:
                raise RouteConfigError("unknown_role", f"unknown native role '{role}'", f"harnesses.{harness}.native_models.{role}")
            try:
                parsed = parse_route(f"{harness}/{binding}" if isinstance(binding, str) else binding, repo_root)
            except RouteConfigError as exc:
                exc.path = f"harnesses.{harness}.native_models.{role}" + (f".{exc.path}" if exc.path else "")
                raise
            if parsed["framework"] != harness:
                raise RouteConfigError("native_framework_mismatch", f"native route must target '{harness}'", f"harnesses.{harness}.native_models.{role}")
    return settings


def read_repo_config(cwd: str | os.PathLike[str], key: str) -> str | None:
    """Walk upward and parse one .lore.config assignment without executing it."""
    directory = Path(cwd).resolve()
    for candidate_dir in (directory, *directory.parents):
        candidate = candidate_dir / ".lore.config"
        if not candidate.is_file():
            continue
        for raw_line in candidate.read_text(encoding="utf-8").splitlines():
            stripped = raw_line.strip()
            if not stripped or stripped.startswith("#") or "=" not in stripped:
                continue
            name, raw_value = stripped.split("=", 1)
            if name.strip() != key:
                continue
            try:
                words = shlex.split(raw_value, comments=True, posix=True)
            except ValueError as exc:
                raise RouteConfigError("invalid_repo_config", f"invalid quoted value for {key}: {exc}", str(candidate)) from exc
            return " ".join(words)
        return None
    return None


def _settings_input(settings: dict[str, Any] | None, settings_path: str | os.PathLike[str] | None) -> dict[str, Any]:
    if settings is not None:
        return settings
    if settings_path is None:
        raise RouteConfigError("missing_settings", "settings or settings_path is required")
    return _load_json(Path(settings_path), "invalid_settings_json")


_ABSENT = object()


def resolve_route_for_role(role: str, ceremony: str | None = None, *, repo_root: str | os.PathLike[str], settings: dict[str, Any] | None = None, settings_path: str | os.PathLike[str] | None = None, cwd: str | os.PathLike[str] | None = None, env: Mapping[str, str] | None = None, override: Any = _ABSENT) -> dict[str, Any]:
    """Resolve a global route with env, repository, overlay, role and fallback precedence."""
    settings = _settings_input(settings, settings_path)
    validate_settings(settings, repo_root)
    _, roles_registry, ceremonies_registry = load_registries(repo_root)
    roles = {entry["id"]: entry for entry in roles_registry["roles"]}
    ceremonies = set(_ids(ceremonies_registry, "ceremonies"))
    if role not in roles:
        raise RouteConfigError("unknown_role", f"unknown role '{role}'", "role")
    if ceremony is not None and ceremony not in ceremonies:
        raise RouteConfigError("unknown_ceremony", f"unknown ceremony '{ceremony}'", "ceremony")
    if override is not _ABSENT:
        return parse_route(override, repo_root, _source("override", role, ceremony))
    environment = dict(os.environ if env is None else env)
    env_name = "LORE_MODEL_" + role.upper().replace("-", "_")
    if env_name in environment:
        return parse_route(environment[env_name], repo_root, _source("env", role, ceremony))
    if cwd is not None:
        repo_value = read_repo_config(cwd, f"model_for_{role}")
        if repo_value is not None:
            return parse_route(repo_value, repo_root, _source("per-repo", role, ceremony))

    routes = settings["routes"]
    if ceremony is not None and role in routes.get("ceremony_overlays", {}).get(ceremony, {}):
        return parse_route(routes["ceremony_overlays"][ceremony][role], repo_root, _source("ceremony-overlay", role, ceremony))
    if role in routes:
        return parse_route(routes[role], repo_root, _source("routes", role, ceremony))
    seen = {role}
    fallback = roles[role].get("fallback_role")
    while fallback:
        if fallback in seen or fallback not in roles:
            raise RouteConfigError("fallback_cycle", f"invalid fallback chain at '{fallback}'", "roles")
        seen.add(fallback)
        env_name = "LORE_MODEL_" + fallback.upper().replace("-", "_")
        if env_name in environment:
            return parse_route(environment[env_name], repo_root, _source("env", fallback, ceremony))
        if cwd is not None:
            repo_value = read_repo_config(cwd, f"model_for_{fallback}")
            if repo_value is not None:
                return parse_route(repo_value, repo_root, _source("per-repo", fallback, ceremony))
        if ceremony is not None and fallback in routes.get("ceremony_overlays", {}).get(ceremony, {}):
            return parse_route(routes["ceremony_overlays"][ceremony][fallback], repo_root, _source("ceremony-overlay", fallback, ceremony))
        if fallback in routes:
            return parse_route(routes[fallback], repo_root, _source("routes", fallback, ceremony))
        fallback = roles[fallback].get("fallback_role")
    return parse_route(routes["default"], repo_root, _source("default", role, ceremony))


def resolve_native_route_for_role(role: str, ceremony: str | None, harness: str, *, repo_root: str | os.PathLike[str], settings: dict[str, Any] | None = None, settings_path: str | os.PathLike[str] | None = None, cwd: str | os.PathLike[str] | None = None, env: Mapping[str, str] | None = None) -> dict[str, Any]:
    """Resolve the route a native subagent of harness should receive."""
    settings = _settings_input(settings, settings_path)
    if not isinstance(harness, str) or not harness:
        raise RouteConfigError("unknown_framework", "native harness is required", "harness")
    global_route = resolve_route_for_role(role, ceremony, repo_root=repo_root, settings=settings, cwd=cwd, env=env)
    if global_route["framework"] == harness:
        return global_route
    native = settings["harnesses"].get(harness, {}).get("native_models")
    if native is None:
        raise RouteConfigError("unknown_framework", f"harness '{harness}' is not configured", "harness")
    source_role = role if role in native else "default"
    binding = native[source_role]
    return parse_route(f"{harness}/{binding}" if isinstance(binding, str) else binding, repo_root, _source("native-models", source_role, ceremony))


def _operation(payload: dict[str, Any]) -> Any:
    operation = payload.get("operation") or payload.get("op")
    root = payload.get("repo_root")
    if not isinstance(root, str) or not root:
        raise RouteConfigError("missing_repo_root", "repo_root is required", "repo_root")
    if operation == "parse":
        if "routing_source" in payload:
            return parse_route(payload.get("route"), root, payload["routing_source"])
        return parse_route(payload.get("route"), root)
    if operation == "validate-settings":
        validate_settings(_settings_input(payload.get("settings"), payload.get("settings_path")), root)
        return {"valid": True}
    common = dict(repo_root=root, settings=payload.get("settings"), settings_path=payload.get("settings_path"), cwd=payload.get("cwd"), env=payload.get("env"))
    if operation == "resolve":
        kwargs = dict(common)
        if "override" in payload:
            kwargs["override"] = payload["override"]
        return resolve_route_for_role(payload.get("role"), payload.get("ceremony"), **kwargs)
    if operation == "native":
        return resolve_native_route_for_role(payload.get("role"), payload.get("ceremony"), payload.get("harness"), **common)
    raise RouteConfigError("unknown_operation", f"unknown operation '{operation}'", "operation")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("operation", nargs="?", choices=["parse", "resolve", "native", "validate-settings"])
    args = parser.parse_args(argv)
    try:
        payload = json.load(sys.stdin)
        if not isinstance(payload, dict):
            raise RouteConfigError("invalid_request", "request must be a JSON object")
        if args.operation:
            payload["operation"] = args.operation
        print(json.dumps({"ok": True, "result": _operation(payload)}, separators=(",", ":"), sort_keys=True))
        return 0
    except RouteConfigError as exc:
        print(json.dumps({"ok": False, "error": exc.as_dict()}, separators=(",", ":"), sort_keys=True))
        return 2
    except (json.JSONDecodeError, OSError) as exc:
        error = RouteConfigError("invalid_request_json", str(exc))
        print(json.dumps({"ok": False, "error": error.as_dict()}, separators=(",", ":"), sort_keys=True))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
