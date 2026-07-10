from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SPEC = (ROOT / "skills/spec/SKILL.md").read_text()


def test_spec_verbs_prepare_and_persist_without_owning_judgment():
    for command in (
        "lore spec start",
        "lore spec discover",
        "lore spec open",
        "lore spec outcome",
        "lore spec finalize",
    ):
        assert command in SPEC

    boundary = SPEC[SPEC.index("## Judgment boundary") : SPEC.index("### Step 1:")]
    for kernel in (
        "investigation questions",
        "strict/permissive applicability",
        "synthesis",
        "contradiction decisions",
        "evaluator normalization",
        "harness-native dispatch",
    ):
        assert kernel in boundary


def test_open_contract_is_no_defaults_and_prepare_only():
    assert '"track": "full"' in SPEC
    assert '"kind": "fixed"' in SPEC
    assert '"kind": "lead-authored"' in SPEC
    assert '"scale_set": ["implementation"]' in SPEC
    assert "unknown or missing fields refuse" in SPEC
    assert "It never calls a harness tool and never persists live handles." in SPEC
    assert "Execute the returned directives in ordinal order." in SPEC


def test_ceremony_outcome_contract_is_closed_and_lead_normalized():
    assert "`completed | failed | skipped | needs-decision`" in SPEC
    assert "Preserve the evaluator's raw verdict byte-for-byte" in SPEC
    assert "Never parse evaluator prose into a disposition." in SPEC
    for field in (
        "evaluator_locator",
        "evaluator_template_version",
        "framework",
        "model",
        "final_round",
        "disposition_ledger_sha256",
        "source_plan_sha256",
    ):
        assert f'"{field}"' in SPEC


def test_post_plan_ceremony_precedes_terminal_finalize():
    post = SPEC.index("### Step 5.5: Post-plan ceremony evaluation")
    final = SPEC.index("### Step 5.6: Finalize through the spec verb")
    assert post < final
    between = SPEC[post:final]
    assert "--ceremony spec-post-plan" in between
    assert "Do not finalize" in between
