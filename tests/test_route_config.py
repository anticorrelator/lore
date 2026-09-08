import importlib.util
import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("route_config", ROOT / "scripts/route_config.py")
route_config = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(route_config)


def settings():
    return {
        "version": 2,
        "tui_launch_framework": "claude-code",
        "routes": {
            "default": "claude-code/opus",
            "worker": {"framework": "codex", "model": "gpt-5.6-sol", "effort": "high", "service_tier": "fast"},
            "ceremony_overlays": {"spec": {"lead": "codex/gpt-6-astra-high"}},
        },
        "harnesses": {
            "claude-code": {"args": [], "native_models": {"default": "opus"}},
            "codex": {"args": [], "native_models": {"default": "gpt-5.5-high"}},
            "opencode": {"args": [], "native_models": {"default": "anthropic/opus"}},
        },
    }


class RouteConfigTests(unittest.TestCase):
    def test_string_and_object_canonicalize_identically(self):
        shorthand = route_config.parse_route("codex/gpt-5.6-sol-high", ROOT)
        flat = route_config.parse_route({"framework": "codex", "model": "gpt-5.6-sol", "effort": "high"}, ROOT)
        self.assertEqual(shorthand, flat)

    def test_provider_model_remains_intact_for_multiroute_framework(self):
        self.assertEqual(route_config.parse_route("opencode/openai/gpt-5", ROOT)["model"], "openai/gpt-5")

    def test_options_are_framework_closed(self):
        with self.assertRaisesRegex(route_config.RouteConfigError, "does not support"):
            route_config.parse_route({"framework": "claude-code", "model": "opus", "effort": "high"}, ROOT)

    def test_canonical_envelope_is_validated(self):
        value = {"framework": "codex", "model": "gpt-5.6-sol", "options": {"effort": "high"}, "routing_source": {"layer": "routes", "role": "worker"}}
        self.assertEqual(route_config.parse_route(value, ROOT), value)

    def test_canonical_options_cannot_overwrite_route_identity(self):
        value = {"framework": "codex", "model": "gpt-5.6-sol", "options": {"model": "changed"}}
        with self.assertRaises(route_config.RouteConfigError) as caught:
            route_config.parse_route(value, ROOT)
        self.assertEqual(caught.exception.code, "unknown_route_option")

    def test_explicit_null_routing_source_is_invalid(self):
        value = {"framework": "codex", "model": "gpt-5.6-sol", "options": {}, "routing_source": None}
        with self.assertRaises(route_config.RouteConfigError) as caught:
            route_config.parse_route(value, ROOT)
        self.assertEqual(caught.exception.code, "invalid_routing_source")

    def test_canonical_envelope_fields_are_not_valid_settings_syntax(self):
        value = settings()
        value["routes"]["worker"] = {"framework": "codex", "model": "gpt-5.6-sol", "options": {}}
        with self.assertRaises(route_config.RouteConfigError) as caught:
            route_config.validate_settings(value, ROOT)
        self.assertEqual(caught.exception.code, "canonical_route_in_settings")

    def test_malformed_registry_has_typed_error(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "adapters").mkdir()
            for name in ("capabilities.json", "roles.json", "ceremonies.json"):
                shutil.copy(ROOT / "adapters" / name, root / "adapters" / name)
            capabilities = json.loads((root / "adapters/capabilities.json").read_text())
            capabilities["frameworks"]["codex"]["model_routing"] = []
            (root / "adapters/capabilities.json").write_text(json.dumps(capabilities))
            with self.assertRaises(route_config.RouteConfigError) as caught:
                route_config.parse_route("codex/gpt-5.5", root)
            self.assertEqual(caught.exception.code, "invalid_registry")

    def test_multiroute_requires_nonempty_provider_and_model(self):
        for value in ("opencode//model", "opencode/provider/"):
            with self.subTest(value=value), self.assertRaises(route_config.RouteConfigError) as caught:
                route_config.parse_route(value, ROOT)
            self.assertEqual(caught.exception.code, "invalid_model_shape")

    def test_complete_settings_validate_before_env_precedence(self):
        value = settings()
        value["harnesses"]["claude-code"]["roles"] = {"default": "opus"}
        with self.assertRaisesRegex(route_config.RouteConfigError, "retired"):
            route_config.resolve_route_for_role("worker", repo_root=ROOT, settings=value, env={"LORE_MODEL_WORKER": "codex/gpt-5.5-high"})

    def test_precedence_and_fallback_record_actual_role(self):
        value = settings()
        del value["routes"]["worker"]
        route = route_config.resolve_route_for_role("worker-mechanical", repo_root=ROOT, settings=value, env={"LORE_MODEL_WORKER": "codex/gpt-5.5-high"})
        self.assertEqual(route["routing_source"], {"layer": "env", "role": "worker"})
        self.assertEqual(route["options"], {"effort": "high"})

    def test_repo_config_quotes_comments_and_walkup(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            child = root / "a" / "b"
            child.mkdir(parents=True)
            (root / ".lore.config").write_text('model_for_worker="codex/gpt-5.5-high" # comment\n')
            route = route_config.resolve_route_for_role("worker", repo_root=ROOT, settings=settings(), cwd=child, env={})
            self.assertEqual(route["routing_source"]["layer"], "per-repo")

    def test_explicit_null_override_is_invalid(self):
        with self.assertRaises(route_config.RouteConfigError) as caught:
            route_config.resolve_route_for_role("worker", repo_root=ROOT, settings=settings(), override=None)
        self.assertEqual(caught.exception.code, "invalid_route")

    def test_native_foreign_route_uses_parent_native_default(self):
        route = route_config.resolve_native_route_for_role("worker", None, "claude-code", repo_root=ROOT, settings=settings(), env={})
        self.assertEqual(route["model"], "opus")
        self.assertEqual(route["routing_source"]["layer"], "native-models")

    def test_cli_has_typed_error_envelope(self):
        request = {"operation": "parse", "repo_root": str(ROOT), "route": "opus"}
        result = subprocess.run(["python3", str(ROOT / "scripts/route_config.py")], input=json.dumps(request), text=True, capture_output=True)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stdout)["error"]["code"], "missing_framework")


if __name__ == "__main__":
    unittest.main()
