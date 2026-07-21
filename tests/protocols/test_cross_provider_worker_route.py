from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
IMPLEMENT = (ROOT / "skills/implement/SKILL.md").read_text()
SPAWN = (ROOT / "skills/implement/templates/worker-spawn.md").read_text()
CHAPERONE = (ROOT / "agents/codex-worker.md").read_text()


def _section(text: str, start: str, end: str) -> str:
    return text[text.index(start) : text.index(end)]


def test_implement_consumes_structured_worker_routes():
    for field in (
        "binding",
        "source_framework",
        "target_framework",
        "native_binding",
        "qualified",
    ):
        assert f"`{field}`" in IMPLEMENT
    assert "Keep `worker_class_models` as the raw scalar bindings" in IMPLEMENT
    assert "bind `worker_class_routes` as the structured dispatch map" in IMPLEMENT


def test_codex_route_precedence_and_bridge_are_explicit():
    codex = _section(SPAWN, "## Codex-routed route", "## Session-routed route")
    assert "explicit per-run model or route pin" in SPAWN
    assert "target_framework == codex" in codex
    assert "source_framework == target_framework" in SPAWN
    assert "every other foreign pair refuses before spawn" in SPAWN
    assert "user/plan-directed Codex route remains available for unqualified bindings" in codex


def test_codex_relay_uses_source_tier_without_prompting():
    codex = _section(SPAWN, "## Codex-routed route", "## Session-routed route")
    assert 'framework_model_routing_tiers "$SOURCE_FRAMEWORK" | head -n1' in codex
    assert "haiku relay OK" in codex
    assert "do not prompt again" in codex
    assert "omit the `model:` field" in codex
    assert "ask the user which tier" not in codex


def test_chaperone_prefers_injected_native_binding_then_legacy_resolution():
    assert 'RESOLVED_NATIVE_BINDING="{{native_binding}}"' in CHAPERONE
    assert 'if [[ -n "$RESOLVED_NATIVE_BINDING" ]]; then' in CHAPERONE
    assert 'BINDING="$RESOLVED_NATIVE_BINDING"' in CHAPERONE
    assert 'LORE_FRAMEWORK=codex bash "$CODEX_ADAPTER" resolve_model_for_role' in CHAPERONE
    assert 'split_model_variant "$BINDING"' in CHAPERONE


def test_chaperone_contract_remains_relay_verbatim_or_degraded():
    for marker in (
        "--sandbox workspace-write",
        "evidence-append.sh",
        "**Spend:**",
        "Everything else in Codex's report is relayed verbatim",
        "**Status:** degraded",
        "re-dispatch the task through the native same-harness route",
    ):
        assert marker in SPAWN + CHAPERONE
