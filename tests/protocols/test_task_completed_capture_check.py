"""Integration tests for scripts/task-completed-capture-check.sh.

Exercises the TaskCompleted hook end-to-end by running it as a subprocess with
fabricated hook-input payloads. The four verification cases from implement-rewrite
task #4:

    1. Worker report with Tier 2 evidence + Tier 3 candidates → exit 0
    2. Worker report missing template_version: → warn+pass (legacy path preserved)
    3. Researcher report with Assertions: → exit 0 (researcher path unchanged)
    4. Worker report with malformed Tier 3 candidates (missing source_artifact_ids)
       → exit 2

Complements tests/test_task_completed_compat.sh (the bash regression suite for
the backwards-compat gate) — this pytest file is the dedicated protocol-level
coverage for the Tier 2 / Tier 3 section shape-check added in task #4.
"""
from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

import pytest


SCRIPTS_DIR = Path(__file__).resolve().parents[2] / "scripts"
HOOK = SCRIPTS_DIR / "task-completed-capture-check.sh"


# A representative `template_version` line — any non-empty hash-shaped value satisfies
# the backwards-compat gate. The literal value is opaque to the hook.
TEMPLATE_VERSION_LINE = "template_version: d88dfde3c627"


# A single structured Observations entry that satisfies validate-structured-report.py.
# Kept as a module-level constant so every worker-path test pays the same 6-field cost.
STRUCTURED_OBSERVATION = """\
**Observations:**
- claim: "The hook accepts the extended worker report shape."
  file: scripts/task-completed-capture-check.sh
  line_range: 150-165
  falsifier: "A worker report with valid Tier 2/3 sections exiting 2."
  significance: medium

**Convention handling:** none in scope
"""


@pytest.fixture
def team_fixture(tmp_path: Path) -> Path:
    """Stage a fake HOME with an impl-*/spec-* team config so the hook can
    resolve agentType. Returns the staged HOME path."""
    teams_dir = tmp_path / ".claude" / "teams"
    for name in ("impl-test-slug", "spec-test-slug"):
        (teams_dir / name).mkdir(parents=True, exist_ok=True)
        (teams_dir / name / "config.json").write_text(
            json.dumps(
                {
                    "members": [
                        {"name": "worker-1", "agentType": "general-purpose"},
                        {"name": "researcher-1", "agentType": "Explore"},
                        {"name": "team-lead", "agentType": "team-lead"},
                    ]
                }
            )
        )
    return tmp_path


def _run_hook(home: Path, payload: dict) -> tuple[int, str]:
    """Invoke the hook with JSON `payload` on stdin. Returns (exit_code, stderr).

    stdout is not returned because the hook writes all operator-visible
    diagnostics to stderr; tests only assert on the exit code and stderr
    content. Keeping the tuple tight avoids unused-variable lint warnings.
    """
    env = os.environ.copy()
    env.update(HOME=str(home), LORE_FRAMEWORK="claude-code", LORE_DATA_DIR=str(home / ".lore"), LORE_KNOWLEDGE_DIR=str(home / ".lore"))
    env.pop("LORE_AGENT_DISABLED", None)
    env.pop("LORE_LIB_DIR", None)
    proc = subprocess.run(
        ["bash", str(HOOK)],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        env=env,
    )
    return proc.returncode, proc.stderr


def test_hook_script_present() -> None:
    """Pre-flight: the hook script must exist and be executable."""
    assert HOOK.exists(), f"hook script not found at {HOOK}"
    assert os.access(HOOK, os.X_OK), f"hook script not executable: {HOOK}"


# ---------------------------------------------------------------------------
# Case 1: Worker report with Tier 2 evidence + Tier 3 candidates → exit 0
# ---------------------------------------------------------------------------

def test_worker_with_tier2_and_tier3_passes(team_fixture: Path) -> None:
    """Extended worker report carrying well-formed Tier 2 evidence and Tier 3
    candidates sections must pass the hook with exit 0."""
    report = f"""**Task:** Extend hook for Tier 2/3 shapes
{TEMPLATE_VERSION_LINE}
**Changes:**
- scripts/task-completed-capture-check.sh: added tier-section shape check

{STRUCTURED_OBSERVATION}
**Tier 2 evidence:**
- claim-id-abc123
- claim-id-def456

**Tier 3 candidates:**
- claim: "Hook is a gate, not a sole-writer; validates shape only."
  why_future_agent_cares: "Attempting claim-content validation would duplicate evidence-append.sh and cause drift."
  falsifier: "A future hook change that re-validates claim content, duplicating the sole-writer's checks."
  source_artifact_ids: ["claim-id-abc123"]

**Blockers:** none
"""
    payload = {
        "team_name": "impl-test-slug",
        "task_description": report,
        "agent_name": "worker-1",
    }
    code, err = _run_hook(team_fixture, payload)
    assert code == 0, f"expected exit 0, got {code}; stderr: {err}"


# ---------------------------------------------------------------------------
# Case 2: Worker report missing template_version: → warn+pass (legacy path)
# ---------------------------------------------------------------------------

def test_worker_without_template_version_warn_pass(team_fixture: Path) -> None:
    """Legacy worker report (no template_version: header) must warn+pass —
    this is the CC-01 backwards-compat path and MUST survive the Tier 2/3
    extension."""
    report = """**Task:** Legacy pre-F0 work
**Changes:** some prose
**Observations:** No structured entries, just prose.
**Blockers:** none
"""
    payload = {
        "team_name": "impl-test-slug",
        "task_description": report,
        "agent_name": "worker-1",
    }
    code, err = _run_hook(team_fixture, payload)
    assert code == 0, f"legacy report must pass; got {code}; stderr: {err}"
    # The warning must surface somewhere — either on stderr (fallback path)
    # or in the work-item's execution-log (slug path). Under the pytest
    # sandbox HOME we expect the stderr fallback.
    assert (
        "LEGACY REPORT" in err or "warning:" in err
    ), f"legacy warning not surfaced; stderr: {err}"


# ---------------------------------------------------------------------------
# Case 3: Researcher Assertions: path unchanged → exit 0
# ---------------------------------------------------------------------------

def test_researcher_assertions_unchanged(team_fixture: Path) -> None:
    """Researcher (Explore) reports with a valid Assertions block must continue
    to pass unchanged — the Tier 2/3 shape-check applies only to workers."""
    report = f"""**Question:** Does the hook preserve researcher Assertions?
{TEMPLATE_VERSION_LINE}
**Findings:** Yes.
**Assertions:**
- claim: "Researcher reports bypass the Tier 2/3 shape-check."
  file: scripts/task-completed-capture-check.sh
  line_range: 185-195
  falsifier: "A researcher report with a Tier 2/3 block being hard-rejected."
  significance: low
"""
    payload = {
        "team_name": "spec-test-slug",
        "task_description": report,
        "agent_name": "researcher-1",
    }
    code, err = _run_hook(team_fixture, payload)
    assert code == 0, f"researcher report must pass; got {code}; stderr: {err}"


# ---------------------------------------------------------------------------
# Case 4: Malformed Tier 3 candidate (missing source_artifact_ids) → exit 2
# ---------------------------------------------------------------------------

def test_worker_tier3_missing_source_artifact_ids_fails(team_fixture: Path) -> None:
    """Worker report where a Tier 3 candidate entry is missing `source_artifact_ids`
    must exit 2 with a diagnostic pointing at the missing field."""
    report = f"""**Task:** Attempt to promote without evidence attribution
{TEMPLATE_VERSION_LINE}
**Changes:** none

{STRUCTURED_OBSERVATION}
**Tier 3 candidates:**
- claim: "A candidate without source_artifact_ids must be rejected."
  why_future_agent_cares: "Without attribution, promotion breaks the audit trail."
  falsifier: "A Tier 3 row landing without a source artifact."

**Blockers:** none
"""
    payload = {
        "team_name": "impl-test-slug",
        "task_description": report,
        "agent_name": "worker-1",
    }
    code, err = _run_hook(team_fixture, payload)
    assert code == 2, f"malformed Tier 3 report must exit 2; got {code}; stderr: {err}"
    assert "source_artifact_ids" in err, (
        f"error diagnostic must name source_artifact_ids; stderr: {err}"
    )


# ---------------------------------------------------------------------------
# Additional shape-check coverage (task #4 scope)
# ---------------------------------------------------------------------------

def test_worker_tier3_empty_source_artifact_ids_fails(team_fixture: Path) -> None:
    """A Tier 3 entry with `source_artifact_ids: []` (empty array literal) must
    fail the shape check — empty attribution is as broken as missing attribution."""
    report = f"""**Task:** Empty array attribution attempt
{TEMPLATE_VERSION_LINE}

{STRUCTURED_OBSERVATION}
**Tier 3 candidates:**
- claim: "Empty array must be rejected."
  why_future_agent_cares: "Keeps attribution invariant."
  falsifier: "A Tier 3 row with empty source_artifact_ids landing."
  source_artifact_ids: []

**Blockers:** none
"""
    payload = {
        "team_name": "impl-test-slug",
        "task_description": report,
        "agent_name": "worker-1",
    }
    code, err = _run_hook(team_fixture, payload)
    assert code == 2
    assert "source_artifact_ids" in err


def test_worker_empty_tier2_evidence_passes(team_fixture: Path) -> None:
    """A Tier 2 evidence heading with no body lines is accepted — the worker
    may have made zero Tier 2 claims this task."""
    report = f"""**Task:** No Tier 2 claims this task
{TEMPLATE_VERSION_LINE}

{STRUCTURED_OBSERVATION}
**Tier 2 evidence:**

**Blockers:** none
"""
    payload = {
        "team_name": "impl-test-slug",
        "task_description": report,
        "agent_name": "worker-1",
    }
    code, err = _run_hook(team_fixture, payload)
    assert code == 0, f"empty Tier 2 list must pass; got {code}; stderr: {err}"


def test_worker_tier2_with_non_list_prose_fails(team_fixture: Path) -> None:
    """A Tier 2 evidence body containing non-list prose lines must fail the
    shape check."""
    report = f"""**Task:** Malformed Tier 2 section
{TEMPLATE_VERSION_LINE}

{STRUCTURED_OBSERVATION}
**Tier 2 evidence:**
This is prose, not a list item.
- claim-id-actually-a-list-item

**Blockers:** none
"""
    payload = {
        "team_name": "impl-test-slug",
        "task_description": report,
        "agent_name": "worker-1",
    }
    code, err = _run_hook(team_fixture, payload)
    assert code == 2
    assert "Tier 2 evidence" in err


# ---------------------------------------------------------------------------
# D10 umbrella test: all four extended-worker-shape cases are covered
# ---------------------------------------------------------------------------
#
# This test is a structural check that the four task-#4 verification cases
# have dedicated tests in this module (named-falsifiable-claims pattern).
# If a refactor renames or removes any of the four, this umbrella test
# fails fast and the refactor is forced to acknowledge the D10 schema.

def test_task_completed_hook_extended_worker_shape_cases() -> None:
    """All four D10 verification cases must be covered by a dedicated test
    in this module: (1) worker w/ Tier 2+3 passes, (2) legacy warn+pass,
    (3) researcher Assertions unchanged, (4) malformed Tier 3 fails."""
    import sys
    this_module = sys.modules[__name__]
    required_test_names = (
        "test_worker_with_tier2_and_tier3_passes",
        "test_worker_without_template_version_warn_pass",
        "test_researcher_assertions_unchanged",
        "test_worker_tier3_missing_source_artifact_ids_fails",
    )
    missing = [n for n in required_test_names if not hasattr(this_module, n)]
    assert not missing, (
        "D10 coverage gap — the following extended-worker-shape tests are "
        f"missing from {__name__}: {', '.join(missing)}"
    )
