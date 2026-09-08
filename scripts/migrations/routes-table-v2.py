#!/usr/bin/env python3
"""Loss-aware settings migration from harness role maps to route tables."""

from __future__ import annotations

import argparse
import copy
import fcntl
import importlib.util
import json
import os
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Any


class MigrationError(ValueError):
    pass


def load_route_config(repo_root: Path):
    path = repo_root / "scripts/route_config.py"
    spec = importlib.util.spec_from_file_location("route_config", path)
    if spec is None or spec.loader is None:
        raise MigrationError(f"cannot load canonical route validator: {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def qualify(binding: Any, framework: str, frameworks: set[str], path: str) -> str:
    if not isinstance(binding, str) or not binding:
        raise MigrationError(f"{path}: expected a non-empty model string")
    prefix, separator, _ = binding.partition("/")
    return binding if separator and prefix in frameworks else f"{framework}/{binding}"


def extract_codex_options(argv: Any, path: str) -> tuple[list[str], dict[str, str]]:
    if not isinstance(argv, list) or any(not isinstance(item, str) for item in argv):
        raise MigrationError(f"{path}: expected an array of strings")
    kept: list[str] = []
    found: dict[str, str] = {}
    index = 0
    names = {"model_reasoning_effort": "effort", "service_tier": "service_tier"}
    while index < len(argv):
        if argv[index] in {"-c", "--config"} and index + 1 < len(argv):
            assignment = argv[index + 1]
            key, separator, raw = assignment.partition("=")
            if separator and key in names:
                value = raw.strip('"\'')
                option = names[key]
                if option in found and found[option] != value:
                    raise MigrationError(f"{path}: conflicting {key} values")
                found[option] = value
                index += 2
                continue
        kept.append(argv[index])
        index += 1
    return kept, found


def route_object(binding: Any, framework: str, frameworks: set[str], route_config: Any, repo_root: Path, path: str) -> dict[str, Any]:
    qualified = qualify(binding, framework, frameworks, path) if isinstance(binding, str) else binding
    try:
        parsed = route_config.parse_route(qualified, repo_root)
    except route_config.RouteConfigError as exc:
        raise MigrationError(f"{path}: {exc.message}") from exc
    result = {"framework": parsed["framework"], "model": parsed["model"]}
    result.update(parsed["options"])
    return result


def migrate(document: dict[str, Any], repo_root: Path) -> dict[str, Any]:
    route_config = load_route_config(repo_root)
    capabilities, roles_registry, ceremonies_registry = route_config.load_registries(repo_root)
    frameworks = set(capabilities["frameworks"])
    roles = [row["id"] for row in roles_registry["roles"]]
    ceremonies = {row["id"] for row in ceremonies_registry["ceremonies"]}
    if document.get("version") == 2:
        try:
            route_config.validate_settings(document, repo_root)
        except route_config.RouteConfigError as exc:
            raise MigrationError(f"version 2 settings are invalid at {exc.path or '<root>'}: {exc.message}") from exc
        return copy.deepcopy(document)
    if document.get("version") != 1:
        raise MigrationError(f"version: expected 1 or 2, found {document.get('version')!r}")
    harnesses = document.get("harnesses")
    if not isinstance(harnesses, dict):
        raise MigrationError("harnesses: expected an object")
    if "routes" in document and any(isinstance(block, dict) and ({"roles", "ceremony_roles"} & set(block)) for block in harnesses.values()):
        raise MigrationError("routes: new routes cannot coexist with retired harnesses.<framework>.roles or ceremony_roles")
    if "routes" in document:
        raise MigrationError("routes: version 1 settings cannot contain the version 2 routes key")

    claude = harnesses.get("claude-code")
    if not isinstance(claude, dict) or not isinstance(claude.get("roles"), dict):
        raise MigrationError("harnesses.claude-code.roles: required as the legacy global route source")
    legacy_global = claude["roles"]
    if "default" not in legacy_global:
        raise MigrationError("harnesses.claude-code.roles.default: required")

    result = copy.deepcopy(document)
    result["version"] = 2
    routes: dict[str, Any] = {}
    for role in roles:
        if role in legacy_global:
            routes[role] = route_object(legacy_global[role], "claude-code", frameworks, route_config, repo_root, f"harnesses.claude-code.roles.{role}")

    # Ceremony policy can become global only when every harness that declares
    # the cell agrees after framework qualification.
    overlay_cells: dict[tuple[str, str], list[tuple[str, dict[str, Any]]]] = {}
    for framework in sorted(harnesses):
        block = harnesses[framework]
        if not isinstance(block, dict):
            raise MigrationError(f"harnesses.{framework}: expected an object")
        legacy_ceremonies = block.get("ceremony_roles", {})
        if not isinstance(legacy_ceremonies, dict):
            raise MigrationError(f"harnesses.{framework}.ceremony_roles: expected an object")
        for ceremony, bindings in legacy_ceremonies.items():
            if ceremony not in ceremonies:
                raise MigrationError(f"harnesses.{framework}.ceremony_roles.{ceremony}: unknown ceremony")
            if not isinstance(bindings, dict):
                raise MigrationError(f"harnesses.{framework}.ceremony_roles.{ceremony}: expected an object")
            for role, binding in bindings.items():
                if role not in roles:
                    raise MigrationError(f"harnesses.{framework}.ceremony_roles.{ceremony}.{role}: unknown role")
                # These two legacy Claude cells expressed native affinity. The
                # new native_models.default supplies the same value directly.
                legacy_native = block.get("roles", {}) if isinstance(block.get("roles"), dict) else {}
                native_binding = legacy_native.get(role, legacy_native.get("default"))
                if isinstance(native_binding, str):
                    native_prefix, native_separator, _ = native_binding.partition("/")
                    if native_separator and native_prefix in frameworks and native_prefix != framework:
                        native_binding = legacy_native.get("default")
                if framework == "claude-code" and binding == "opus" and native_binding == "opus" and ((ceremony, role) in {("pr-review", "reviewer"), ("implement", "advisor")}):
                    continue
                value = route_object(binding, framework, frameworks, route_config, repo_root, f"harnesses.{framework}.ceremony_roles.{ceremony}.{role}")
                overlay_cells.setdefault((ceremony, role), []).append((framework, value))
    overlays: dict[str, dict[str, Any]] = {}
    for (ceremony, role), values in sorted(overlay_cells.items()):
        distinct = {json.dumps(value, sort_keys=True) for _, value in values}
        if len(distinct) != 1:
            paths = ", ".join(f"harnesses.{framework}.ceremony_roles.{ceremony}.{role}" for framework, _ in values)
            raise MigrationError(f"conflicting ceremony routes cannot be represented globally: {paths}")
        overlays.setdefault(ceremony, {})[role] = values[0][1]
    if overlays:
        routes["ceremony_overlays"] = overlays

    # Args and autonomous_args carry process-wide Codex options in version 1.
    codex = result["harnesses"].get("codex")
    profile_options: dict[str, dict[str, str]] = {}
    if isinstance(codex, dict):
        for profile in ("args", "autonomous_args"):
            if profile in codex:
                kept, options = extract_codex_options(codex[profile], f"harnesses.codex.{profile}")
                codex[profile] = kept
                profile_options[profile] = options
    option_names = {name for values in profile_options.values() for name in values}
    divergent_options: set[str] = set()
    for option in sorted(option_names):
        supplied = {profile: values.get(option) for profile, values in profile_options.items()}
        if len(set(supplied.values())) > 1:
            divergent_options.add(option)
    inherited_options = next(iter(profile_options.values()), {})
    if len(profile_options) == 2:
        inherited_options = {key: next(iter({values[key] for values in profile_options.values()})) for key in option_names - divergent_options}

    if divergent_options:
        applicable: list[tuple[str, dict[str, Any]]] = []
        for role in roles:
            if role in routes and routes[role]["framework"] == "codex":
                applicable.append((f"routes.{role}", routes[role]))
        for ceremony, bindings in routes.get("ceremony_overlays", {}).items():
            for role, route in bindings.items():
                if route["framework"] == "codex":
                    applicable.append((f"routes.ceremony_overlays.{ceremony}.{role}", route))
        legacy_codex_roles = codex.get("roles", {}) if isinstance(codex, dict) and isinstance(codex.get("roles"), dict) else {}
        for role, binding in legacy_codex_roles.items():
            parsed = route_object(binding, "codex", frameworks, route_config, repo_root, f"harnesses.codex.roles.{role}")
            if parsed["framework"] == "codex":
                applicable.append((f"harnesses.codex.roles.{role}", parsed))
        for option in sorted(divergent_options):
            missing = [path for path, route in applicable if option not in route]
            if missing:
                profiles = ", ".join(f"harnesses.codex.{profile}" for profile in profile_options)
                raise MigrationError(f"conflicting {option} values in {profiles}; {missing[0]} has no explicit {option}")

    def apply_options(route: dict[str, Any], path: str) -> None:
        if route["framework"] != "codex":
            return
        for option, value in inherited_options.items():
            route.setdefault(option, value)
        if route.get("model") == "gpt-5.6-sol" and path.split(".")[-1] in {"worker", "worker-mechanical", "worker-judgment-dense"}:
            route.setdefault("service_tier", "fast")

    for role in roles:
        if role in routes:
            apply_options(routes[role], f"routes.{role}")
    for ceremony, bindings in routes.get("ceremony_overlays", {}).items():
        for role, route in bindings.items():
            apply_options(route, f"routes.ceremony_overlays.{ceremony}.{role}")
    result["routes"] = routes

    if inherited_options.get("service_tier") and isinstance(codex, dict) and isinstance(codex.get("roles"), dict):
        raise MigrationError("harnesses.codex.args: service_tier cannot be preserved in scalar harnesses.codex.native_models; remove it or express it on global routes before migration")

    new_harnesses: dict[str, Any] = {}
    for framework, original_block in result["harnesses"].items():
        block = copy.deepcopy(original_block)
        legacy_roles = block.pop("roles", None)
        block.pop("ceremony_roles", None)
        if not isinstance(legacy_roles, dict) or "default" not in legacy_roles:
            raise MigrationError(f"harnesses.{framework}.roles.default: required for native_models.default")
        unknown_roles = sorted(set(legacy_roles) - set(roles))
        if unknown_roles:
            raise MigrationError(f"harnesses.{framework}.roles.{unknown_roles[0]}: unknown role")
        def native_value(role: str, binding: Any) -> Any:
            path = f"harnesses.{framework}.roles.{role}"
            if not isinstance(binding, str) or not binding:
                raise MigrationError(f"{path}: expected a non-empty model string")
            prefix, separator, remainder = binding.partition("/")
            if separator and prefix in frameworks:
                if prefix == framework:
                    return remainder
                global_route = routes.get(role)
                mirrored = route_object(binding, framework, frameworks, route_config, repo_root, path)
                apply_options(mirrored, f"routes.{role}")
                if isinstance(global_route, dict) and global_route == mirrored:
                    return None
                raise MigrationError(f"{path}: foreign route conflicts with the global route and cannot become a native binding")
            return binding

        default_binding = native_value("default", legacy_roles["default"])
        if default_binding is None:
            raise MigrationError(f"harnesses.{framework}.roles.default: foreign binding cannot supply native_models.default")
        native = {"default": default_binding}
        for role, binding in legacy_roles.items():
            if role != "default":
                value = native_value(role, binding)
                if value is not None and value != default_binding:
                    native[role] = value
        # Codex native routes previously inherited effort from args. Preserve
        # it in the native shorthand suffix because native_models is scalar.
        if framework == "codex" and inherited_options.get("effort"):
            effort = inherited_options["effort"]
            allowed = capabilities["frameworks"]["codex"]["model_routing"]["options"]["effort"]
            for role, binding in list(native.items()):
                if isinstance(binding, str) and not any(binding.endswith(f"-{candidate}") for candidate in allowed):
                    native[role] = f"{binding}-{effort}"
        block["native_models"] = native
        new_harnesses[framework] = block
    result["harnesses"] = new_harnesses
    try:
        route_config.validate_settings(result, repo_root)
    except route_config.RouteConfigError as exc:
        raise MigrationError(f"migrated settings are invalid at {exc.path or '<root>'}: {exc.message}") from exc
    return result


def run(settings_path: Path, repo_root: Path, dry_run: bool) -> bool:
    settings_path.parent.mkdir(parents=True, exist_ok=True)
    lock_path = settings_path.parent / ".settings.lock"
    with lock_path.open("a+") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        original = settings_path.read_bytes()
        try:
            document = json.loads(original)
        except json.JSONDecodeError as exc:
            raise MigrationError(f"{settings_path}: invalid JSON: {exc}") from exc
        migrated = migrate(document, repo_root)
        if document.get("version") == 2:
            return False
        if dry_run:
            return True
        backup = settings_path.with_name(settings_path.name + ".routes-v1.bak")
        if backup.exists() and backup.read_bytes() != original:
            raise MigrationError(f"{backup}: existing backup does not match the settings being migrated")
        if not backup.exists():
            backup.write_bytes(original)
        rendered = (json.dumps(migrated, indent=2, ensure_ascii=False) + "\n").encode()
        fd, temporary = tempfile.mkstemp(prefix=".settings.routes-v2.", suffix=".tmp", dir=settings_path.parent)
        try:
            with os.fdopen(fd, "wb") as handle:
                handle.write(rendered)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, settings_path)
        except BaseException:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass
            raise
        return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--settings", required=True)
    parser.add_argument("--repo-root", default=str(Path(__file__).resolve().parents[2]))
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    try:
        changed = run(Path(args.settings), Path(args.repo_root), args.dry_run)
    except (MigrationError, OSError) as exc:
        print(f"route settings migration refused: {exc}", file=sys.stderr)
        return 2
    print("would migrate settings to version 2" if args.dry_run and changed else "migrated settings to version 2" if changed else "settings already valid at version 2")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
