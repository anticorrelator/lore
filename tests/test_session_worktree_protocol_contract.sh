#!/usr/bin/env bash
# Semantic sentinels for the operator-visible session-worktree contract.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - \
  "$REPO_ROOT/docs/session-substrate.md" \
  "$REPO_ROOT/skills/coordinate/SKILL.md" \
  "$REPO_ROOT/skills/coordinate/session-reference.md" <<'PYEOF'
from pathlib import Path
import sys

substrate, coordinate, reference = (Path(path).read_text() for path in sys.argv[1:])

lifecycle = substrate.split("## Session worktree identity and lifecycle", 1)[1].split("## Request queue", 1)[0]
lifecycle = " ".join(lifecycle.split())
for token in (
    "canonical path",
    "Git common-dir",
    "per-worktree git-dir",
    "epoch",
    "HEAD OID",
    "index digest",
    "worktree digest",
    "target ref",
    "target OID",
    "captured → active → publishable → published | quarantined",
    "teardown-pending",
    "published`, `restore_refused`, and `worktree_quarantined",
    "byte-for-byte unchanged",
    "durable result ref and patch",
    "projects to the normal exactly-once `closed` session terminal",
    "appends its own `worktree_published` journal row naming the destination checkout",
    "session-scoped write allowlist",
    "worktree_write_refused",
    "outside-session-allowlist",
    "containment-context-missing",
    # The fence is partial by construction; each uncovered path is pinned by its
    # own token rather than by a count, so naming a fourth later stays legal.
    "a write issued through a shell command is outside it entirely",
    "names no path at all is approved without classification",
    "registered for claude-code only",
):
    assert token in lifecycle, f"session substrate missing worktree obligation: {token}"

for prose in (" ".join(coordinate.split()), " ".join(reference.split())):
    for token in (
        "session-owned worktree",
        "teardown-pending",
        "published",
        "restore_refused",
        "worktree_quarantined",
        "worktree_published",
        "session-scoped write allowlist",
        "byte-for-byte unchanged",
        "durable result ref/patch",
    ):
        assert token in prose, f"coordinate guidance missing worktree obligation: {token}"

assert "does not retain the physical directory forever" in coordinate
assert "Quarantine preserves content, not the physical directory" in reference
reference_flat = " ".join(reference.split())
for managed_contract in (
    "sole manager",
    "reserved → bound → active|recovered → quiescent → reconciling → cleanup_due → removed",
    "dispatching seat",
    "900-second lease",
    "immutable source manifest",
    "integrated manifest",
    "git worktree list --porcelain",
    "cleanup_blocked",
):
    assert managed_contract in reference_flat, f"managed worktree contract missing: {managed_contract}"

print("session worktree protocol contract: PASS")
PYEOF
