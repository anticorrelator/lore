from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
COORDINATE = (ROOT / "skills/coordinate/SKILL.md").read_text()
IMPLEMENT = (ROOT / "skills/implement/SKILL.md").read_text()
REFERENCE = (ROOT / "skills/coordinate/session-reference.md").read_text()
TEMPLATE = (ROOT / "skills/coordinate/templates/coordination.md").read_text()
ARCHITECTURE = (ROOT / "docs/coordination-architecture.md").read_text()
SUBSTRATE = (ROOT / "docs/session-substrate.md").read_text()


def prose(text: str) -> str:
    return " ".join(text.split())


def test_board_uses_explicit_edges_eager_join_and_settings_capacity():
    coordinate = prose(COORDINATE)
    implement = prose(IMPLEMENT)

    for token in (
        "Depends on",
        "Tree",
        "lore coordinate status",
        "settings-derived concurrency ceiling",
        "readiness is derived",
        "Dispatch every ready stream",
        "unrelated writer never creates a barrier",
    ):
        assert token in coordinate

    for stale_clause in (
        "Re-join at every wave boundary",
        "tree-writer is any stream that mutates the working tree; one at a time",
        "When a batch of workers has all reported completion",
        "min(recommended_workers, 4)",
    ):
        assert stale_clause not in coordinate + implement

    header = next(line for line in TEMPLATE.splitlines() if line.startswith("| # |"))
    cells = {cell.strip() for cell in header.strip("|").split("|")}
    assert {"Depends on", "Tree", "Status", "Verdict", "Worktree / attempt"} <= cells


def test_mutating_subagents_require_a_seat_lease_and_never_allocate():
    combined = prose(COORDINATE + IMPLEMENT + REFERENCE + SUBSTRATE)
    for token in (
        "allocation authority never",
        "dispatching seat",
        "seat's durable lease",
        "item-backed worker session",
        "Unleased mutating subagents are prohibited",
        "Read-only streams need no worktree",
    ):
        assert token.lower() in combined.lower()


def test_guard_identity_is_the_canonical_managed_placement_seam():
    for document in (REFERENCE, ARCHITECTURE, SUBSTRATE):
        normalized = prose(document)
        assert "tui/internal/worktree/guard.go" in normalized
        assert "guard identity" in normalized.lower()

    substrate = prose(SUBSTRATE)
    for field in ("worktree_id", "execution_dir", "900-second lease"):
        assert field in substrate


def test_reconciliation_and_cleanup_are_terminal_preconditions():
    combined = prose(COORDINATE + IMPLEMENT + REFERENCE + TEMPLATE + ARCHITECTURE + SUBSTRATE)
    for token in (
        "immutable source",
        "integrated manifest",
        "stable control checkout",
        "worker makes source edits",
        "cleanup_blocked",
        "path absence",
        "Git-registry absence",
        "branch/ref disposition",
        "recovery evidence before removal",
    ):
        assert token.lower() in combined.lower()

    closure = prose(IMPLEMENT[IMPLEMENT.index("### Step 6: Closure verdict") :])
    assert "Unproven removal" in closure
    assert "failed close" in closure
