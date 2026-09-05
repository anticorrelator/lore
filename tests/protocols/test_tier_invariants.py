"""Cross-skill sole-writer contract."""
import re
from pathlib import Path
import lib


SKILLS_DIR = Path(__file__).resolve().parents[2] / "skills"

DIRECT_WRITE_PATTERNS = [
    r">>\s*rows\.jsonl",
    r"tee\s+rows\.jsonl",
    r"echo\s.*>\s*rows\.jsonl",
    r"printf\s.*>\s*rows\.jsonl",
]

def _all_skill_names() -> list[str]:
    return [p.name for p in SKILLS_DIR.iterdir() if p.is_dir()]

def test_no_skill_writes_rows_jsonl_directly() -> None:
    """No SKILL.md may contain a direct write invocation targeting rows.jsonl.

    The sole-writer invariant requires all rows to flow through
    scorecard-append.sh. Direct shell redirects (`>> rows.jsonl`,
    `tee rows.jsonl`, `echo ... > rows.jsonl`) bypass the validator and
    produce corrupt rows by definition.
    """
    violations: list[str] = []

    for skill_name in _all_skill_names():
        try:
            text = lib.read_skill(skill_name)
        except FileNotFoundError:
            continue

        for pattern in DIRECT_WRITE_PATTERNS:
            for lineno, line in enumerate(text.splitlines(), start=1):
                if re.search(pattern, line):
                    violations.append(
                        f"{skill_name}/SKILL.md:{lineno}: "
                        f"direct write to rows.jsonl: {line.strip()!r}"
                    )

    assert not violations, "Skills with direct rows.jsonl writes:\n" + "\n".join(
        violations
    )
