"""Tests for generate-tasks.py Design Decisions absent-section detection (task-16)."""
from __future__ import annotations

import importlib.util
import io
import sys
from pathlib import Path

import pytest


def _load_generate_tasks():
    path = Path(__file__).resolve().parents[2] / "scripts" / "generate-tasks.py"
    spec = importlib.util.spec_from_file_location("generate_tasks", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


_mod = _load_generate_tasks()
generate_tasks_from_plan = _mod.generate_tasks_from_plan


_PLAN_WITH_DD = """\
# Plan

## Goal
Test plan

## Design Decisions

### D1: Use X
**Decision:** Use X
**Rationale:** Because it's better
**Applies to:** All phases

### Phase 1: Do things
**Objective:** Do things
**Files:** foo.py

- [ ] Write `foo.py` to do something
"""

_PLAN_WITHOUT_DD = """\
# Plan

## Goal
Test plan

### Phase 1: Do things
**Objective:** Do things
**Files:** foo.py

- [ ] Write `foo.py` to do something
"""


def _run_with_captured_stderr(plan: str):
    old_stderr = sys.stderr
    sys.stderr = io.StringIO()
    try:
        result = generate_tasks_from_plan(plan)
        return result, sys.stderr.getvalue()
    finally:
        sys.stderr = old_stderr


_EXPECTED_WARNING = (
    "[generate-tasks] warning: plan.md missing ## Design Decisions"
    " — worker tasks will not receive design-decision context"
)


def test_absent_section_emits_warning():
    _, stderr = _run_with_captured_stderr(_PLAN_WITHOUT_DD)
    assert _EXPECTED_WARNING in stderr


def test_absent_section_sets_flag_false():
    result, _ = _run_with_captured_stderr(_PLAN_WITHOUT_DD)
    assert result["design_decisions_present"] is False


def test_present_section_no_warning():
    _, stderr = _run_with_captured_stderr(_PLAN_WITH_DD)
    assert stderr.strip() == ""


def test_present_section_sets_flag_true():
    result, _ = _run_with_captured_stderr(_PLAN_WITH_DD)
    assert result["design_decisions_present"] is True


def test_present_section_injection_unchanged():
    """Existing injection flow (decisions list in tasks) is unaffected."""
    result, _ = _run_with_captured_stderr(_PLAN_WITH_DD)
    tasks = result["phases"][0]["tasks"]
    assert tasks, "expected at least one task"
    # D1 should appear in the first task's description
    assert "D1" in result["phases"][0]["phase_context"]
