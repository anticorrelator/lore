#!/usr/bin/env bash
# Semantic sentinels for the harness-neutral bootstrap and renormalize protocols.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - \
  "$REPO_ROOT/skills/bootstrap" \
  "$REPO_ROOT/skills/renormalize" <<'PYEOF'
from pathlib import Path
import re
import sys


def markdown_bundle(root: Path) -> str:
    files = sorted(root.rglob("*.md"))
    assert files, f"no Markdown protocol files found under {root}"
    return "\n".join(path.read_text() for path in files)


def require(text: str, tokens: tuple[str, ...], protocol: str) -> None:
    for token in tokens:
        assert token in text, f"{protocol} missing stable contract marker: {token}"


bootstrap = markdown_bundle(Path(sys.argv[1]))
renormalize = markdown_bundle(Path(sys.argv[2]))

# Both orchestration skills bind to resolved defaults and publish the same
# durable report/evidence/session surfaces, independent of adapter prose.
shared_markers = (
    "lore defaults",
    "Report-schema: 1",
    "Report-id:",
    "**Artifacts:**",
    "--scale-set",
    "evidence-append.sh",
    "lore verify",
    "session-step.sh",
)
require(bootstrap, shared_markers, "bootstrap")
require(renormalize, shared_markers, "renormalize")

for text, protocol in ((bootstrap, "bootstrap"), (renormalize, "renormalize")):
    resolve_at = text.index("lore resolve")
    defaults_at = text.index("lore defaults")
    report_at = text.index("Report-schema: 1")
    assert resolve_at < defaults_at < report_at, (
        f"{protocol} must bind lore defaults after resolution and before report handling"
    )

# Domain bootstrap is a narrow-results action that creates one reusable
# architecture/subsystem entry with complete capture provenance.
require(
    bootstrap,
    (
        "--domain <topic>",
        "scale: architecture,subsystem",
        "confidence: medium",
        "producer_role",
        "work_item",
        "source_artifact_ids",
    ),
    "bootstrap",
)

# Renormalize preserves trust identity through the sanctioned migration seam;
# direct trust-ledger writes are intentionally not part of the skill contract.
require(renormalize, ("trust-event-migrate.sh",), "renormalize")
assert "trust-ledger.jsonl" not in renormalize, (
    "renormalize must not direct workers to write trust-ledger.jsonl"
)

# Standing prose is harness neutral: routing syntax, team-config discovery,
# and model aliases belong to adapters/defaults rather than these skills.
combined = bootstrap + "\n" + renormalize
for token in (
    "TeamCreate",
    "TaskCreate",
    "Task tool params",
    "resolve_harness_install_path teams",
    "/.claude/teams/",
):
    assert token not in combined, f"stale harness-specific token remains: {token}"

assert not re.search(r"\b(?:opus|sonnet)\b", combined, re.IGNORECASE), (
    "hardcoded opus/sonnet model token remains"
)

print("bootstrap/renormalize protocol contracts: PASS")
PYEOF
