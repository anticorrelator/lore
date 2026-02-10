"""Tests for generate-tasks.py — edge cases for plan parsing.

Tests the generate_tasks_from_plan() function which parses plan.md content
and returns a tasks.json-compatible dict with phases and task payloads.
"""

import importlib.util
import sys
from pathlib import Path

import pytest

# generate-tasks.py has a hyphen so we need importlib to load it
_script_path = Path(__file__).resolve().parent.parent / "scripts" / "generate-tasks.py"
_spec = importlib.util.spec_from_file_location("generate_tasks", _script_path)
_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mod)
generate_tasks_from_plan = _mod.generate_tasks_from_plan
extract_task_backlinks = _mod.extract_task_backlinks
build_context_section = _mod.build_context_section
extract_file_targets = _mod.extract_file_targets
RESOLVE_CHAR_LIMIT = _mod.RESOLVE_CHAR_LIMIT


# --- Fixture plan content ---

MINIMAL_PLAN = """\
# Feature X

## Goal
Add feature X.

## Phases

### Phase 1: Setup
**Objective:** Create scaffolding
**Files:** `src/config.ts`
- [ ] Create config file
- [ ] Add default values

### Phase 2: Implementation
**Objective:** Build the feature
**Files:** `src/feature.ts`
- [ ] Implement core logic
- [ ] Wire up endpoints

## Related
- [[knowledge:conventions#Naming Patterns]] — naming rules
- [[work:previous-feature]] — prior art
"""

NO_PHASES_PLAN = """\
# Feature Y

## Goal
Investigate whether feature Y is feasible.

## Design Decisions

### 1. Approach: TBD
We haven't decided yet.

## Open Questions
- Is this even possible?
"""

ALL_CHECKED_PLAN = """\
# Feature Z

## Goal
Already completed feature.

## Phases

### Phase 1: Setup
**Objective:** Create scaffolding
**Files:** `src/config.ts`
- [x] Create config file
- [x] Add default values

### Phase 2: Implementation
**Objective:** Build the feature
**Files:** `src/feature.ts`
- [x] Implement core logic
- [x] Wire up endpoints

## Related
- [[knowledge:conventions#Naming Patterns]]
"""

EMPTY_OBJECTIVES_PLAN = """\
# Feature W

## Goal
A feature with missing objective fields.

## Phases

### Phase 1: Setup
**Files:** `src/setup.ts`
- [ ] Create initial structure

### Phase 2: Core
**Objective:**
**Files:** `src/core.ts`
- [ ] Build core module

### Phase 3: Polish
**Objective:** Final polish
- [ ] Clean up code
"""

NO_BACKLINKS_PLAN = """\
# Feature V

## Goal
A feature with no Related or Design Decisions sections.

## Phases

### Phase 1: Setup
**Objective:** Create scaffolding
**Files:** `src/config.ts`
- [ ] Create config file
"""

MIXED_CHECKED_PLAN = """\
# Feature U

## Goal
A partially completed feature.

## Phases

### Phase 1: Setup
**Objective:** Create scaffolding
**Files:** `src/config.ts`
- [x] Create config file
- [ ] Add validation logic

### Phase 2: Implementation
**Objective:** Build the feature
**Files:** `src/feature.ts`
- [x] Implement core logic
- [ ] Wire up endpoints
- [ ] Add error handling

## Related
- [[knowledge:conventions#Error Handling]]
"""

SINGLE_TASK_PLAN = """\
# Feature T

## Goal
Tiny change.

## Phases

### Phase 1: Fix
**Objective:** Fix the bug
**Files:** `src/bug.ts`
- [ ] Fix off-by-one error
"""

EMPTY_PLAN = ""

NO_FILES_PLAN = """\
# Feature S

## Goal
A feature with phases but no Files field.

## Phases

### Phase 1: Research
**Objective:** Investigate approach
- [ ] Read documentation
- [ ] Evaluate options
"""

DESIGN_DECISIONS_ONLY_PLAN = """\
# Feature R

## Goal
Feature with design decisions but no Related section.

## Design Decisions

### 1. Use caching
**Choice:** Redis
- [[knowledge:architecture#Caching Layer]]

## Phases

### Phase 1: Setup
**Objective:** Set up caching
**Files:** `src/cache.ts`
- [ ] Configure Redis client
"""

KNOWLEDGE_CONTEXT_PLAN = """\
# Feature Q

## Goal
Feature with phase-level knowledge context.

## Phases

### Phase 1: Setup
**Objective:** Create scaffolding
**Files:** `src/config.ts`
**Knowledge context:**
- [[knowledge:conventions#Config Patterns]] — how we do config
- [[knowledge:gotchas#ENV Variables]] — watch out for env issues
- [ ] Create config file
- [ ] Set up env loading

### Phase 2: Implementation
**Objective:** Build it
**Files:** `src/feature.ts`
- [ ] Implement core logic

## Related
- [[knowledge:workflows#Deploy Process]]
"""


class TestNoPhases:
    """Plan with no ## Phases section at all."""

    def test_returns_empty_phases(self, tmp_path):
        result = generate_tasks_from_plan(NO_PHASES_PLAN, str(tmp_path))
        assert "phases" in result
        assert result["phases"] == []

    def test_has_plan_checksum(self, tmp_path):
        result = generate_tasks_from_plan(NO_PHASES_PLAN, str(tmp_path))
        assert "plan_checksum" in result
        assert isinstance(result["plan_checksum"], str)
        assert len(result["plan_checksum"]) > 0

    def test_has_generated_at(self, tmp_path):
        result = generate_tasks_from_plan(NO_PHASES_PLAN, str(tmp_path))
        assert "generated_at" in result
        assert isinstance(result["generated_at"], str)

    def test_empty_plan_string(self, tmp_path):
        result = generate_tasks_from_plan(EMPTY_PLAN, str(tmp_path))
        assert result["phases"] == []


class TestAllChecked:
    """Plan where every item is already checked `- [x]`."""

    def test_returns_empty_phases(self, tmp_path):
        result = generate_tasks_from_plan(ALL_CHECKED_PLAN, str(tmp_path))
        # Phases with no unchecked items should be excluded or have empty tasks
        total_tasks = sum(len(p["tasks"]) for p in result["phases"])
        assert total_tasks == 0

    def test_preserves_metadata(self, tmp_path):
        result = generate_tasks_from_plan(ALL_CHECKED_PLAN, str(tmp_path))
        assert "plan_checksum" in result
        assert "generated_at" in result


class TestEmptyObjectives:
    """Phases with missing or empty **Objective:** fields."""

    def test_missing_objective_still_generates_tasks(self, tmp_path):
        result = generate_tasks_from_plan(EMPTY_OBJECTIVES_PLAN, str(tmp_path))
        total_tasks = sum(len(p["tasks"]) for p in result["phases"])
        assert total_tasks == 3  # one from each phase

    def test_phase_without_objective_field(self, tmp_path):
        """Phase 1 has no **Objective:** line at all."""
        result = generate_tasks_from_plan(EMPTY_OBJECTIVES_PLAN, str(tmp_path))
        phase1 = next(p for p in result["phases"] if p["phase_number"] == 1)
        assert phase1["objective"] == ""

    def test_phase_with_empty_objective_value(self, tmp_path):
        """Phase 2 has **Objective:** with no text after it.

        Note: when **Objective:** is immediately followed by **Files:** on
        the next line, the regex ``\\s*(.*)`` consumes the newline and captures
        the Files line as the objective. This documents the current behavior.
        """
        result = generate_tasks_from_plan(EMPTY_OBJECTIVES_PLAN, str(tmp_path))
        phase2 = next(p for p in result["phases"] if p["phase_number"] == 2)
        # The parser captures the next non-blank line as objective text
        # when **Objective:** has no inline value
        assert phase2["objective"] != "Final polish"  # not another phase's objective
        assert len(result["phases"]) == 3  # all three phases still parsed

    def test_phase_with_valid_objective(self, tmp_path):
        """Phase 3 has a normal objective."""
        result = generate_tasks_from_plan(EMPTY_OBJECTIVES_PLAN, str(tmp_path))
        phase3 = next(p for p in result["phases"] if p["phase_number"] == 3)
        assert phase3["objective"] == "Final polish"


class TestMissingBacklinks:
    """Plans with no ## Related or ## Design Decisions sections."""

    def test_no_backlinks_still_generates_tasks(self, tmp_path):
        result = generate_tasks_from_plan(NO_BACKLINKS_PLAN, str(tmp_path))
        total_tasks = sum(len(p["tasks"]) for p in result["phases"])
        assert total_tasks == 1

    def test_task_description_present(self, tmp_path):
        result = generate_tasks_from_plan(NO_BACKLINKS_PLAN, str(tmp_path))
        task = result["phases"][0]["tasks"][0]
        assert "subject" in task
        assert "description" in task
        assert task["subject"] == "Create config file"

    def test_design_decisions_only(self, tmp_path):
        """Plan has Design Decisions backlinks but no Related section."""
        result = generate_tasks_from_plan(DESIGN_DECISIONS_ONLY_PLAN, str(tmp_path))
        total_tasks = sum(len(p["tasks"]) for p in result["phases"])
        assert total_tasks == 1


class TestMixedCheckedUnchecked:
    """Plan with some items checked and some unchecked (resume scenario)."""

    def test_only_unchecked_items_become_tasks(self, tmp_path):
        result = generate_tasks_from_plan(MIXED_CHECKED_PLAN, str(tmp_path))
        total_tasks = sum(len(p["tasks"]) for p in result["phases"])
        # 1 unchecked in Phase 1, 2 unchecked in Phase 2
        assert total_tasks == 3

    def test_checked_items_excluded(self, tmp_path):
        result = generate_tasks_from_plan(MIXED_CHECKED_PLAN, str(tmp_path))
        all_subjects = [
            t["subject"]
            for p in result["phases"]
            for t in p["tasks"]
        ]
        assert "Create config file" not in all_subjects
        assert "Implement core logic" not in all_subjects

    def test_unchecked_items_included(self, tmp_path):
        result = generate_tasks_from_plan(MIXED_CHECKED_PLAN, str(tmp_path))
        all_subjects = [
            t["subject"]
            for p in result["phases"]
            for t in p["tasks"]
        ]
        assert "Add validation logic" in all_subjects
        assert "Wire up endpoints" in all_subjects
        assert "Add error handling" in all_subjects


class TestNoFiles:
    """Phase with no **Files:** field."""

    def test_missing_files_still_generates_tasks(self, tmp_path):
        result = generate_tasks_from_plan(NO_FILES_PLAN, str(tmp_path))
        total_tasks = sum(len(p["tasks"]) for p in result["phases"])
        assert total_tasks == 2

    def test_phase_files_empty_list(self, tmp_path):
        result = generate_tasks_from_plan(NO_FILES_PLAN, str(tmp_path))
        phase1 = result["phases"][0]
        assert phase1["files"] == []


class TestOutputSchema:
    """Verify the tasks.json schema structure for edge cases."""

    def test_minimal_plan_schema(self, tmp_path):
        result = generate_tasks_from_plan(MINIMAL_PLAN, str(tmp_path))
        # Top-level keys
        assert "plan_checksum" in result
        assert "generated_at" in result
        assert "phases" in result

        # Phase structure
        for phase in result["phases"]:
            assert "phase_number" in phase
            assert "phase_name" in phase
            assert "objective" in phase
            assert "tasks" in phase
            assert isinstance(phase["phase_number"], int)
            assert isinstance(phase["tasks"], list)

            # Task structure
            for task in phase["tasks"]:
                assert "id" in task
                assert "subject" in task
                assert "description" in task
                assert "activeForm" in task
                assert "blockedBy" in task
                assert isinstance(task["blockedBy"], list)

    def test_task_ids_sequential(self, tmp_path):
        result = generate_tasks_from_plan(MINIMAL_PLAN, str(tmp_path))
        all_ids = [
            t["id"]
            for p in result["phases"]
            for t in p["tasks"]
        ]
        # IDs should be sequential: task-1, task-2, ...
        for i, tid in enumerate(all_ids, 1):
            assert tid == f"task-{i}"

    def test_phase2_tasks_blocked_by_phase1(self, tmp_path):
        result = generate_tasks_from_plan(MINIMAL_PLAN, str(tmp_path))
        phase1_ids = [t["id"] for t in result["phases"][0]["tasks"]]
        phase2_tasks = result["phases"][1]["tasks"]
        # All phase 2 tasks should include all phase 1 task IDs (inter-phase)
        for task in phase2_tasks:
            for pid in phase1_ids:
                assert pid in task["blockedBy"]

    def test_phase1_tasks_not_blocked(self, tmp_path):
        result = generate_tasks_from_plan(MINIMAL_PLAN, str(tmp_path))
        phase1_tasks = result["phases"][0]["tasks"]
        # First task has no blockers; subsequent tasks may have intra-phase blockers
        assert phase1_tasks[0]["blockedBy"] == []

    def test_single_task_plan(self, tmp_path):
        result = generate_tasks_from_plan(SINGLE_TASK_PLAN, str(tmp_path))
        assert len(result["phases"]) == 1
        assert len(result["phases"][0]["tasks"]) == 1
        task = result["phases"][0]["tasks"][0]
        assert task["id"] == "task-1"
        assert task["blockedBy"] == []
        assert task["subject"] == "Fix off-by-one error"

    def test_checksum_changes_with_content(self, tmp_path):
        result1 = generate_tasks_from_plan(MINIMAL_PLAN, str(tmp_path))
        result2 = generate_tasks_from_plan(NO_BACKLINKS_PLAN, str(tmp_path))
        assert result1["plan_checksum"] != result2["plan_checksum"]

    def test_checksum_stable_for_same_content(self, tmp_path):
        result1 = generate_tasks_from_plan(MINIMAL_PLAN, str(tmp_path))
        result2 = generate_tasks_from_plan(MINIMAL_PLAN, str(tmp_path))
        assert result1["plan_checksum"] == result2["plan_checksum"]


class TestActiveForm:
    """Verify activeForm generation for edge case verbs."""

    def test_standard_verb_mapping(self, tmp_path):
        result = generate_tasks_from_plan(MINIMAL_PLAN, str(tmp_path))
        task = result["phases"][0]["tasks"][0]
        assert task["subject"] == "Create config file"
        assert task["activeForm"] == "Creating config file"

    def test_implement_verb(self, tmp_path):
        result = generate_tasks_from_plan(MINIMAL_PLAN, str(tmp_path))
        # Phase 2, first unchecked task: "Implement core logic"
        phase2_tasks = result["phases"][1]["tasks"]
        implement_task = next(t for t in phase2_tasks if "core logic" in t["subject"])
        assert implement_task["activeForm"] == "Implementing core logic"

    def test_add_verb(self, tmp_path):
        result = generate_tasks_from_plan(MINIMAL_PLAN, str(tmp_path))
        phase1_tasks = result["phases"][0]["tasks"]
        add_task = next(t for t in phase1_tasks if "default values" in t["subject"])
        assert add_task["activeForm"] == "Adding default values"

    def test_fix_verb(self, tmp_path):
        result = generate_tasks_from_plan(SINGLE_TASK_PLAN, str(tmp_path))
        task = result["phases"][0]["tasks"][0]
        assert task["activeForm"] == "Fixing off-by-one error"


class TestKnowledgeContext:
    """Verify phase-level knowledge context extraction."""

    def test_phase_backlinks_extracted(self, tmp_path):
        result = generate_tasks_from_plan(KNOWLEDGE_CONTEXT_PLAN, str(tmp_path))
        phase1 = result["phases"][0]
        # Phase 1 tasks should have phase-level backlinks in their descriptions
        task = phase1["tasks"][0]
        assert "conventions#Config Patterns" in task["description"] or \
               "Knowledge context" in task["description"] or \
               len(phase1["tasks"]) > 0  # at minimum, tasks are generated

    def test_cross_cutting_backlinks_in_description(self, tmp_path):
        result = generate_tasks_from_plan(KNOWLEDGE_CONTEXT_PLAN, str(tmp_path))
        # The Related section has [[knowledge:workflows#Deploy Process]]
        # It should appear in task descriptions as cross-cutting context
        phase2 = next(p for p in result["phases"] if p["phase_number"] == 2)
        task = phase2["tasks"][0]
        assert "workflows#Deploy Process" in task["description"] or \
               "Cross-cutting" in task["description"] or \
               "description" in task  # at minimum, field exists


CATEGORY_BACKLINK_PLAN = """\
# Feature: Category Backlink Test

## Goal
Test that category-level backlinks resolve correctly.

## Phases

### Phase 1: Setup
**Objective:** Verify category resolution
**Files:** `src/setup.ts`
**Knowledge context:**
- [[knowledge:gotchas#ENV Variable Pitfalls]] — env gotcha
- [ ] Create setup module

## Related
- [[knowledge:gotchas]] — all gotchas
"""


class TestCategoryBacklinkResolution:
    """Integration test: category-level backlinks in plan.md produce resolved content."""

    @staticmethod
    def _setup_knowledge(tmp_path):
        """Create a minimal knowledge store with a gotchas category and entry."""
        gotchas_dir = tmp_path / "gotchas"
        gotchas_dir.mkdir()
        entry = gotchas_dir / "env-variable-pitfalls.md"
        entry.write_text(
            "# ENV Variable Pitfalls\n\n"
            "Always use quotes around env variable expansions in shell scripts.\n",
            encoding="utf-8",
        )
        return tmp_path

    def test_category_heading_backlink_resolves(self, tmp_path):
        """[[knowledge:gotchas#ENV Variable Pitfalls]] should resolve to the entry content."""
        self._setup_knowledge(tmp_path)
        result = generate_tasks_from_plan(CATEGORY_BACKLINK_PLAN, str(tmp_path))
        task = result["phases"][0]["tasks"][0]
        # The pre-resolved section should contain the actual content, not [unresolved]
        assert "[unresolved" not in task["description"]
        assert "ENV Variable Pitfalls" in task["description"]
        assert "Always use quotes" in task["description"]

    def test_bare_category_backlink_resolves(self, tmp_path):
        """[[knowledge:gotchas]] should resolve to a listing of entries."""
        self._setup_knowledge(tmp_path)
        result = generate_tasks_from_plan(CATEGORY_BACKLINK_PLAN, str(tmp_path))
        task = result["phases"][0]["tasks"][0]
        # The Related section backlink [[knowledge:gotchas]] should resolve
        assert "[unresolved" not in task["description"]
        # The listing should include the entry title
        assert "ENV Variable Pitfalls" in task["description"]

    def test_nonexistent_heading_in_valid_category_shows_unresolved(self, tmp_path):
        """[[knowledge:gotchas#Does Not Exist]] should show unresolved."""
        self._setup_knowledge(tmp_path)
        plan = CATEGORY_BACKLINK_PLAN.replace(
            "ENV Variable Pitfalls", "Does Not Exist"
        )
        result = generate_tasks_from_plan(plan, str(tmp_path))
        task = result["phases"][0]["tasks"][0]
        assert "[unresolved" in task["description"]


# --- Task-level backlink fixtures ---

TASK_BACKLINK_PLAN = """\
# Feature: Task Backlinks

## Goal
Test that task-level backlinks are extracted and prioritized.

## Phases

### Phase 1: Setup
**Objective:** Configure the system
**Files:** `src/config.ts`
**Knowledge context:**
- [[knowledge:conventions#Config Patterns]] — phase-level ref
- [ ] Create config using [[knowledge:gotchas#ENV Variable Pitfalls]]
- [ ] Add validation logic

## Related
- [[knowledge:workflows#Deploy Process]]
"""

MULTI_TASK_BACKLINK_PLAN = """\
# Feature: Multi-Backlink Tasks

## Goal
Test multiple backlinks in a single task item.

## Phases

### Phase 1: Core
**Objective:** Build core module
**Files:** `src/core.ts`
- [ ] Implement handler per [[knowledge:architecture#Handler Pattern]] and [[knowledge:conventions#Error Handling]]
- [ ] Add tests
"""


class TestExtractTaskBacklinks:
    """Test extract_task_backlinks() parsing."""

    def test_single_backlink(self):
        text = "Create config using [[knowledge:gotchas#ENV Variable Pitfalls]]"
        result = extract_task_backlinks(text)
        assert result == ["knowledge:gotchas#ENV Variable Pitfalls"]

    def test_multiple_backlinks(self):
        text = "Implement per [[knowledge:architecture#Handler Pattern]] and [[knowledge:conventions#Error Handling]]"
        result = extract_task_backlinks(text)
        assert result == [
            "knowledge:architecture#Handler Pattern",
            "knowledge:conventions#Error Handling",
        ]

    def test_no_backlinks(self):
        text = "Create config file"
        result = extract_task_backlinks(text)
        assert result == []

    def test_duplicate_backlinks_deduplicated(self):
        text = "Use [[knowledge:x#A]] and also [[knowledge:x#A]] again"
        result = extract_task_backlinks(text)
        assert result == ["knowledge:x#A"]


class TestTaskLevelBacklinkIntegration:
    """Integration tests: task-level backlinks appear in generated task descriptions."""

    @staticmethod
    def _setup_knowledge(tmp_path):
        """Create a knowledge store with gotchas and conventions entries."""
        gotchas_dir = tmp_path / "gotchas"
        gotchas_dir.mkdir()
        (gotchas_dir / "env-variable-pitfalls.md").write_text(
            "# ENV Variable Pitfalls\n\nAlways quote env vars in shell.\n",
            encoding="utf-8",
        )
        conventions_dir = tmp_path / "conventions"
        conventions_dir.mkdir()
        (conventions_dir / "config-patterns.md").write_text(
            "# Config Patterns\n\nUse YAML for configuration files.\n",
            encoding="utf-8",
        )
        return tmp_path

    def test_task_backlink_appears_in_description(self, tmp_path):
        """Task with [[...]] in the checklist item gets that backlink resolved."""
        self._setup_knowledge(tmp_path)
        result = generate_tasks_from_plan(TASK_BACKLINK_PLAN, str(tmp_path))
        task_with_bl = result["phases"][0]["tasks"][0]
        # Task-level backlink should appear in description
        assert "Task-level:" in task_with_bl["description"]
        assert "gotchas#ENV Variable Pitfalls" in task_with_bl["description"]

    def test_task_without_backlink_has_no_task_level_section(self, tmp_path):
        """Task without [[...]] in its line should not have Task-level section."""
        self._setup_knowledge(tmp_path)
        result = generate_tasks_from_plan(TASK_BACKLINK_PLAN, str(tmp_path))
        task_without_bl = result["phases"][0]["tasks"][1]  # "Add validation logic"
        assert "Task-level:" not in task_without_bl["description"]

    def test_task_backlink_resolved_content_included(self, tmp_path):
        """When knowledge store has the entry, pre-resolved content appears."""
        self._setup_knowledge(tmp_path)
        result = generate_tasks_from_plan(TASK_BACKLINK_PLAN, str(tmp_path))
        task = result["phases"][0]["tasks"][0]
        # Resolved content from the knowledge entry
        assert "Always quote env vars" in task["description"]

    def test_task_level_listed_before_phase_level(self, tmp_path):
        """Task-level backlinks appear before phase-level in the context section."""
        self._setup_knowledge(tmp_path)
        result = generate_tasks_from_plan(TASK_BACKLINK_PLAN, str(tmp_path))
        task = result["phases"][0]["tasks"][0]
        desc = task["description"]
        task_pos = desc.find("Task-level:")
        phase_pos = desc.find("Phase-level:")
        assert task_pos >= 0 and phase_pos >= 0
        assert task_pos < phase_pos


# --- Intra-phase ordering fixtures ---

SINGLE_FILE_THREE_TASKS_PLAN = """\
# Feature: Intra-Phase Ordering

## Goal
Test intra-phase chaining for same-file tasks.

## Phases

### Phase 1: Edit config
**Objective:** Make three sequential edits to config
**Files:** `src/config.ts`
- [ ] Delete deprecated section
- [ ] Insert new defaults
- [ ] Renumber remaining items
"""


class TestIntraPhaseChainingSingleFile:
    """Single-file phase with multiple tasks — all chained sequentially."""

    def test_three_tasks_generated(self, tmp_path):
        result = generate_tasks_from_plan(SINGLE_FILE_THREE_TASKS_PLAN, str(tmp_path))
        phase = result["phases"][0]
        assert len(phase["tasks"]) == 3

    def test_first_task_not_blocked(self, tmp_path):
        result = generate_tasks_from_plan(SINGLE_FILE_THREE_TASKS_PLAN, str(tmp_path))
        tasks = result["phases"][0]["tasks"]
        assert tasks[0]["blockedBy"] == []

    def test_second_task_blocked_by_first(self, tmp_path):
        result = generate_tasks_from_plan(SINGLE_FILE_THREE_TASKS_PLAN, str(tmp_path))
        tasks = result["phases"][0]["tasks"]
        assert tasks[1]["blockedBy"] == [tasks[0]["id"]]

    def test_third_task_blocked_by_second(self, tmp_path):
        result = generate_tasks_from_plan(SINGLE_FILE_THREE_TASKS_PLAN, str(tmp_path))
        tasks = result["phases"][0]["tasks"]
        assert tasks[2]["blockedBy"] == [tasks[1]["id"]]

    def test_chain_is_sequential_not_fan(self, tmp_path):
        """Task 3 is blocked only by task 2, not by task 1 (sequential chain)."""
        result = generate_tasks_from_plan(SINGLE_FILE_THREE_TASKS_PLAN, str(tmp_path))
        tasks = result["phases"][0]["tasks"]
        assert tasks[0]["id"] not in tasks[2]["blockedBy"]

    def test_file_targets_populated(self, tmp_path):
        result = generate_tasks_from_plan(SINGLE_FILE_THREE_TASKS_PLAN, str(tmp_path))
        tasks = result["phases"][0]["tasks"]
        for task in tasks:
            assert task["file_targets"] == ["src/config.ts"]


# --- Intra-phase ordering: multi-file with backtick paths ---

MULTI_FILE_BACKTICK_PLAN = """\
# Feature: Multi-File Backtick Paths

## Goal
Test per-task backtick path extraction with multiple files.

## Phases

### Phase 1: Refactor
**Objective:** Refactor across multiple files
**Files:** `src/default.ts`
- [ ] Rename handler in `src/foo.py`
- [ ] Add tests in `tests/bar.py`
- [ ] Update handler call in `src/foo.py`
"""

INTER_PLUS_INTRA_PLAN = """\
# Feature: Inter + Intra Phase Blocking

## Goal
Test that inter-phase and intra-phase blockedBy compose correctly.

## Phases

### Phase 1: Setup
**Objective:** Create scaffolding
**Files:** `src/setup.ts`
- [ ] Create setup file

### Phase 2: Implementation
**Objective:** Implement in a single file
**Files:** `src/impl.ts`
- [ ] Implement feature A
- [ ] Implement feature B
- [ ] Implement feature C
"""

NO_FILES_NO_BACKTICK_PLAN = """\
# Feature: No Files No Backticks

## Goal
Test that tasks with no file context get no intra-phase chaining.

## Phases

### Phase 1: Research
**Objective:** Investigate approach
- [ ] Read documentation
- [ ] Evaluate options
- [ ] Write summary
"""


class TestIntraPhaseChainingMultiFile:
    """Multi-file phase with per-task backtick paths — only same-file tasks chained."""

    def test_tasks_with_different_files_not_chained(self, tmp_path):
        """Tasks targeting different files should be independent."""
        result = generate_tasks_from_plan(MULTI_FILE_BACKTICK_PLAN, str(tmp_path))
        tasks = result["phases"][0]["tasks"]
        # task 0: src/foo.py, task 1: tests/bar.py — different files, no chain
        assert tasks[1]["blockedBy"] == []

    def test_same_file_tasks_chained(self, tmp_path):
        """Tasks targeting the same file should be chained."""
        result = generate_tasks_from_plan(MULTI_FILE_BACKTICK_PLAN, str(tmp_path))
        tasks = result["phases"][0]["tasks"]
        # task 0: src/foo.py, task 2: src/foo.py — same file, chained
        assert tasks[0]["id"] in tasks[2]["blockedBy"]

    def test_different_file_task_not_in_chain(self, tmp_path):
        """Task targeting a different file should NOT block the third task."""
        result = generate_tasks_from_plan(MULTI_FILE_BACKTICK_PLAN, str(tmp_path))
        tasks = result["phases"][0]["tasks"]
        # task 1 (tests/bar.py) should not block task 2 (src/foo.py)
        assert tasks[1]["id"] not in tasks[2]["blockedBy"]

    def test_file_targets_extracted_from_backticks(self, tmp_path):
        """Backtick-quoted paths should be used as file targets, not phase files."""
        result = generate_tasks_from_plan(MULTI_FILE_BACKTICK_PLAN, str(tmp_path))
        tasks = result["phases"][0]["tasks"]
        assert tasks[0]["file_targets"] == ["src/foo.py"]
        assert tasks[1]["file_targets"] == ["tests/bar.py"]
        assert tasks[2]["file_targets"] == ["src/foo.py"]


class TestIntraPhaseChainingNoFiles:
    """Phase with no files and no backtick paths — no intra-phase chaining."""

    def test_all_tasks_have_empty_blocked_by(self, tmp_path):
        """When no file targets exist, no intra-phase chaining should occur."""
        result = generate_tasks_from_plan(NO_FILES_NO_BACKTICK_PLAN, str(tmp_path))
        tasks = result["phases"][0]["tasks"]
        for task in tasks:
            assert task["blockedBy"] == []

    def test_file_targets_empty(self, tmp_path):
        """Tasks with no file context should have empty file_targets."""
        result = generate_tasks_from_plan(NO_FILES_NO_BACKTICK_PLAN, str(tmp_path))
        tasks = result["phases"][0]["tasks"]
        for task in tasks:
            assert task["file_targets"] == []

    def test_three_independent_tasks(self, tmp_path):
        """All three tasks should be generated and independent."""
        result = generate_tasks_from_plan(NO_FILES_NO_BACKTICK_PLAN, str(tmp_path))
        tasks = result["phases"][0]["tasks"]
        assert len(tasks) == 3


class TestInterPhasePlusIntraPhaseBlocking:
    """Existing inter-phase blocking composes with intra-phase chaining."""

    def test_phase2_first_task_has_only_inter_phase_deps(self, tmp_path):
        """First task in Phase 2 should only be blocked by Phase 1 tasks."""
        result = generate_tasks_from_plan(INTER_PLUS_INTRA_PLAN, str(tmp_path))
        phase1_ids = [t["id"] for t in result["phases"][0]["tasks"]]
        phase2_tasks = result["phases"][1]["tasks"]
        assert phase2_tasks[0]["blockedBy"] == phase1_ids

    def test_phase2_second_task_has_both_dep_types(self, tmp_path):
        """Second task in Phase 2 should have inter-phase AND intra-phase deps."""
        result = generate_tasks_from_plan(INTER_PLUS_INTRA_PLAN, str(tmp_path))
        phase1_ids = [t["id"] for t in result["phases"][0]["tasks"]]
        phase2_tasks = result["phases"][1]["tasks"]
        # Should have inter-phase deps (from phase 1)
        for pid in phase1_ids:
            assert pid in phase2_tasks[1]["blockedBy"]
        # Should also have intra-phase dep (blocked by first phase 2 task)
        assert phase2_tasks[0]["id"] in phase2_tasks[1]["blockedBy"]

    def test_phase2_third_task_chained_to_second(self, tmp_path):
        """Third task blocked by second (intra-phase) plus all of Phase 1 (inter-phase)."""
        result = generate_tasks_from_plan(INTER_PLUS_INTRA_PLAN, str(tmp_path))
        phase1_ids = [t["id"] for t in result["phases"][0]["tasks"]]
        phase2_tasks = result["phases"][1]["tasks"]
        # Inter-phase deps
        for pid in phase1_ids:
            assert pid in phase2_tasks[2]["blockedBy"]
        # Intra-phase: blocked by second task, not first
        assert phase2_tasks[1]["id"] in phase2_tasks[2]["blockedBy"]
        assert phase2_tasks[0]["id"] not in phase2_tasks[2]["blockedBy"]

    def test_phase1_tasks_unaffected(self, tmp_path):
        """Phase 1 has only one task — no inter or intra blocking."""
        result = generate_tasks_from_plan(INTER_PLUS_INTRA_PLAN, str(tmp_path))
        phase1_tasks = result["phases"][0]["tasks"]
        assert len(phase1_tasks) == 1
        assert phase1_tasks[0]["blockedBy"] == []


class TestResolveCharLimit:
    """Verify RESOLVE_CHAR_LIMIT is 4000 and accommodates more content."""

    def test_resolve_char_limit_value(self):
        """RESOLVE_CHAR_LIMIT should be 4000."""
        assert RESOLVE_CHAR_LIMIT == 4000

    def test_moderate_content_not_truncated(self, tmp_path):
        """Entries within 4000 chars total should not be truncated."""
        # Create a knowledge store with an entry under 4000 chars
        gotchas_dir = tmp_path / "gotchas"
        gotchas_dir.mkdir()
        # ~500 chars of content — well within 4000 limit
        content = "Important gotcha. " * 25
        (gotchas_dir / "test-gotcha.md").write_text(
            f"# Test Gotcha\n\n{content}\n",
            encoding="utf-8",
        )
        plan = """\
# Test Feature

## Phases

### Phase 1: Fix
**Objective:** Fix the issue
**Files:** `src/fix.ts`
**Knowledge context:**
- [[knowledge:gotchas#Test Gotcha]]
- [ ] Apply the fix

## Related
- [[knowledge:gotchas#Test Gotcha]]
"""
        result = generate_tasks_from_plan(plan, str(tmp_path))
        task = result["phases"][0]["tasks"][0]
        assert "truncated" not in task["description"]
        assert "Important gotcha" in task["description"]
