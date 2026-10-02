from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SPEC = (ROOT / "skills/spec/SKILL.md").read_text()
COMMISSIONING = (ROOT / "skills/spec/commissioning.md").read_text()


def test_spec_prose_names_its_verbs():
    for command in (
        "lore spec start",
        "lore spec discover",
        "lore spec open",
        "lore spec finalize",
    ):
        assert command in SPEC + COMMISSIONING


def test_investigation_document_uses_the_fields_open_reads():
    assert '"track": "full"' in COMMISSIONING
    assert '"kind": "lead-authored"' in COMMISSIONING
