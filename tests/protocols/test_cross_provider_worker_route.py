from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SPAWN = (ROOT / "skills/implement/templates/worker-spawn.md").read_text()
CHAPERONE = (ROOT / "agents/codex-worker.md").read_text()


def _section(text: str, start: str, end: str) -> str:
    return text[text.index(start) : text.index(end)]


def test_codex_relay_uses_source_tier_without_prompting():
    codex = _section(SPAWN, "## Codex-routed route", "## Session-routed route")
    assert 'framework_model_routing_tiers "$SOURCE_FRAMEWORK" | head -n1' in codex
    assert "haiku relay OK" in codex
    assert "do not prompt again" in codex
    assert "omit the `model:` field" in codex
    assert "ask the user which tier" not in codex


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
