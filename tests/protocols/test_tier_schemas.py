"""Required Tier 2 fields stay aligned with their source schema."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]


def test_tier2_schema_matches_validator():
    text = (ROOT / "architecture/artifacts/tier2-evidence-schema.md").read_text()
    table = text.split("## Required fields (fast-path)", 1)[1].split("###", 1)[0]
    documented = set(re.findall(r"^\| `([^`]+)`", table, re.MULTILINE))
    validator = (ROOT / "scripts/validate-tier2.sh").read_text()
    array = re.search(r"REQUIRED_FIELDS=\((.*?)\)", validator, re.DOTALL).group(1)
    unconditional = set(re.findall(r"^\s*([a-z_]+)\s*$", array, re.MULTILINE))
    # These are conditional on fast-path state, outside REQUIRED_FIELDS.
    conditional = {"exact_snippet", "normalized_snippet_hash", "change_context"}
    assert documented == unconditional | conditional
    for field in conditional:
        assert field in validator
