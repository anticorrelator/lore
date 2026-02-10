"""Tests for stop-novelty-check.py — dual-criteria novelty detection stop hook."""

import hashlib
import json
import os
import sys
import tempfile
from unittest import mock

import pytest

# Add scripts dir to path so we can import the module
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))

# The module has a hyphenated name, so use importlib
import importlib

snc = importlib.import_module("stop-novelty-check")


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture
def knowledge_dir(tmp_path):
    """Create a temporary knowledge directory."""
    kd = tmp_path / "knowledge"
    kd.mkdir()
    return kd


@pytest.fixture
def transcript_path(tmp_path):
    """Create a temporary JSONL transcript file with enough tool uses to pass guards."""
    tp = tmp_path / "transcript.jsonl"
    lines = []
    # Generate 12 assistant messages with tool_use to pass the >10 tool_use guard
    for i in range(12):
        lines.append(json.dumps({
            "message": {
                "role": "assistant",
                "content": [
                    {"type": "text", "text": f"Step {i}"},
                    {"type": "tool_use", "name": "Bash"},
                ],
            }
        }))
    # Add user messages in between
    for i in range(6):
        lines.append(json.dumps({
            "message": {
                "role": "user",
                "content": [{"type": "text", "text": f"User message {i}"}],
            }
        }))
    tp.write_text("\n".join(lines), encoding="utf-8")
    return tp


# ---------------------------------------------------------------------------
# Test: _pending_captures/ with existing files causes main() to exit 0
# ---------------------------------------------------------------------------

class TestPendingCapturesEarlyExit:
    """When _pending_captures/ directory has existing .md files, main() should
    exit 0 without blocking — preventing the false-positive re-blocking loop."""

    def test_existing_captures_causes_silent_exit(self, knowledge_dir, transcript_path):
        """main() exits 0 when _pending_captures/ has .md files."""
        # Create _pending_captures/ with an existing candidate file
        pending_dir = knowledge_dir / "_pending_captures"
        pending_dir.mkdir()
        (pending_dir / "abc123def456.md").write_text(
            "# Capture Candidate: gotcha\n\n**Trigger:** gotcha\n",
            encoding="utf-8",
        )

        hook_input = json.dumps({
            "stop_hook_active": False,
            "transcript_path": str(transcript_path),
        })

        # Mock resolve-repo.sh to return our temp knowledge_dir
        mock_result = mock.MagicMock()
        mock_result.stdout = str(knowledge_dir) + "\n"

        with mock.patch("sys.stdin", mock.MagicMock(read=mock.MagicMock(return_value=hook_input))):
            with mock.patch("subprocess.run", return_value=mock_result):
                with pytest.raises(SystemExit) as exc_info:
                    snc.main()

        # Should exit 0 (allow stop, no blocking)
        assert exc_info.value.code == 0

    def test_empty_pending_dir_does_not_early_exit(self, knowledge_dir, transcript_path):
        """main() does NOT early-exit when _pending_captures/ exists but is empty."""
        # Create an empty _pending_captures/ directory
        pending_dir = knowledge_dir / "_pending_captures"
        pending_dir.mkdir()

        hook_input = json.dumps({
            "stop_hook_active": False,
            "transcript_path": str(transcript_path),
        })

        mock_result = mock.MagicMock()
        mock_result.stdout = str(knowledge_dir) + "\n"

        with mock.patch("sys.stdin", mock.MagicMock(read=mock.MagicMock(return_value=hook_input))):
            with mock.patch("subprocess.run", return_value=mock_result):
                with pytest.raises(SystemExit) as exc_info:
                    snc.main()

        # Should still exit 0 (no heuristic hits on bland transcript),
        # but it should have passed Guard 4 and reached the heuristic scan
        assert exc_info.value.code == 0

    def test_no_pending_dir_does_not_early_exit(self, knowledge_dir, transcript_path):
        """main() does NOT early-exit when _pending_captures/ doesn't exist at all."""
        hook_input = json.dumps({
            "stop_hook_active": False,
            "transcript_path": str(transcript_path),
        })

        mock_result = mock.MagicMock()
        mock_result.stdout = str(knowledge_dir) + "\n"

        with mock.patch("sys.stdin", mock.MagicMock(read=mock.MagicMock(return_value=hook_input))):
            with mock.patch("subprocess.run", return_value=mock_result):
                with pytest.raises(SystemExit) as exc_info:
                    snc.main()

        # Should exit 0 (no heuristic hits), but passed Guard 4
        assert exc_info.value.code == 0

    def test_non_md_files_do_not_trigger_early_exit(self, knowledge_dir, transcript_path):
        """main() does NOT early-exit when _pending_captures/ has only non-.md files."""
        pending_dir = knowledge_dir / "_pending_captures"
        pending_dir.mkdir()
        (pending_dir / ".gitkeep").write_text("", encoding="utf-8")
        (pending_dir / "notes.txt").write_text("not a candidate", encoding="utf-8")

        hook_input = json.dumps({
            "stop_hook_active": False,
            "transcript_path": str(transcript_path),
        })

        mock_result = mock.MagicMock()
        mock_result.stdout = str(knowledge_dir) + "\n"

        with mock.patch("sys.stdin", mock.MagicMock(read=mock.MagicMock(return_value=hook_input))):
            with mock.patch("subprocess.run", return_value=mock_result):
                with pytest.raises(SystemExit) as exc_info:
                    snc.main()

        # Should pass Guard 4 (no .md files) and continue
        assert exc_info.value.code == 0


# ---------------------------------------------------------------------------
# Test: write_pending_captures() creates content-hash named files idempotently
# ---------------------------------------------------------------------------

class TestWritePendingCaptures:
    """write_pending_captures() should create _pending_captures/ with one file
    per candidate, named by content hash. Re-running with the same candidates
    should produce the same filenames (idempotent)."""

    SAMPLE_CANDIDATES = [
        {
            "trigger": "debug-root-cause",
            "matched_text": "the root cause was a missing import",
            "novel_phrase": "missing import pattern",
            "heuristic_index": 5,
            "novelty_index": 7,
        },
        {
            "trigger": "gotcha",
            "matched_text": "edge case when input is empty",
            "novel_phrase": "empty input handling",
            "heuristic_index": 12,
            "novelty_index": 14,
        },
    ]

    def _expected_hash(self, candidate):
        """Compute expected hash for a candidate."""
        key = candidate["trigger"] + candidate["matched_text"]
        return hashlib.sha256(key.encode("utf-8")).hexdigest()[:12]

    def test_creates_directory_and_files(self, knowledge_dir):
        """write_pending_captures() creates _pending_captures/ with one .md file per candidate."""
        snc.write_pending_captures(str(knowledge_dir), self.SAMPLE_CANDIDATES)

        pending_dir = knowledge_dir / "_pending_captures"
        assert pending_dir.is_dir()

        files = sorted(os.listdir(str(pending_dir)))
        assert len(files) == 2
        assert all(f.endswith(".md") for f in files)

    def test_filenames_are_content_hashes(self, knowledge_dir):
        """File names match sha256(trigger + matched_text)[:12].md."""
        snc.write_pending_captures(str(knowledge_dir), self.SAMPLE_CANDIDATES)

        pending_dir = knowledge_dir / "_pending_captures"
        files = sorted(os.listdir(str(pending_dir)))

        expected_names = sorted(
            f"{self._expected_hash(c)}.md" for c in self.SAMPLE_CANDIDATES
        )
        assert files == expected_names

    def test_idempotent_same_candidates(self, knowledge_dir):
        """Re-running with same candidates produces same filenames, no extras."""
        snc.write_pending_captures(str(knowledge_dir), self.SAMPLE_CANDIDATES)
        files_first = sorted(os.listdir(str(knowledge_dir / "_pending_captures")))

        snc.write_pending_captures(str(knowledge_dir), self.SAMPLE_CANDIDATES)
        files_second = sorted(os.listdir(str(knowledge_dir / "_pending_captures")))

        assert files_first == files_second

    def test_different_candidates_produce_different_files(self, knowledge_dir):
        """Different candidates produce different filenames."""
        snc.write_pending_captures(str(knowledge_dir), self.SAMPLE_CANDIDATES)

        different_candidates = [
            {
                "trigger": "design-decision",
                "matched_text": "we chose Redis because of latency requirements",
                "novel_phrase": "Redis latency",
                "heuristic_index": 20,
                "novelty_index": 22,
            },
        ]
        snc.write_pending_captures(str(knowledge_dir), different_candidates)

        pending_dir = knowledge_dir / "_pending_captures"
        files = sorted(os.listdir(str(pending_dir)))

        # Should have 3 files total: 2 original + 1 new
        assert len(files) == 3

    def test_file_content_includes_required_fields(self, knowledge_dir):
        """Each candidate file contains trigger, context, novel phrase, transcript region, and evaluation prompt."""
        snc.write_pending_captures(str(knowledge_dir), self.SAMPLE_CANDIDATES)

        pending_dir = knowledge_dir / "_pending_captures"
        candidate = self.SAMPLE_CANDIDATES[0]
        filename = f"{self._expected_hash(candidate)}.md"
        content = (pending_dir / filename).read_text(encoding="utf-8")

        assert f"**Trigger:** {candidate['trigger']}" in content
        assert f"**Context:** {candidate['matched_text']}" in content
        assert f"**Novel phrase:** {candidate['novel_phrase']}" in content
        assert f"**Transcript region:** messages {candidate['heuristic_index']}-{candidate['novelty_index']}" in content
        assert "capture gate" in content.lower()

    def test_single_candidate(self, knowledge_dir):
        """Works correctly with a single candidate."""
        single = [self.SAMPLE_CANDIDATES[0]]
        snc.write_pending_captures(str(knowledge_dir), single)

        pending_dir = knowledge_dir / "_pending_captures"
        files = os.listdir(str(pending_dir))
        assert len(files) == 1

    def test_empty_candidates_creates_directory_only(self, knowledge_dir):
        """Empty candidates list creates the directory but no files."""
        snc.write_pending_captures(str(knowledge_dir), [])

        pending_dir = knowledge_dir / "_pending_captures"
        assert pending_dir.is_dir()
        assert os.listdir(str(pending_dir)) == []


# ---------------------------------------------------------------------------
# Test: tool_result messages excluded from USER_PATTERNS heuristic scan
# ---------------------------------------------------------------------------

class TestToolResultExcludedFromUserPatterns:
    """tool_result messages should be excluded from USER_PATTERNS matching.
    These messages contain tool/teammate output, not genuine user corrections."""

    def test_tool_result_with_correction_pattern_not_matched(self):
        """A tool_result message containing user-correction patterns should NOT produce hits."""
        messages = [
            {
                "index": 0,
                "role": "user",
                "text_blocks": [
                    "no, that's not correct, you should actually use the other approach"
                ],
                "has_tool_use": False,
                "is_tool_result": True,
                "tool_names": [],
            },
        ]
        hits = snc.scan_heuristics(messages)
        assert len(hits) == 0

    def test_genuine_user_message_with_correction_pattern_matched(self):
        """A genuine user message (not tool_result) with correction patterns SHOULD produce hits."""
        messages = [
            {
                "index": 0,
                "role": "user",
                "text_blocks": [
                    "no, that's not correct, you should actually use the other approach"
                ],
                "has_tool_use": False,
                "is_tool_result": False,
                "tool_names": [],
            },
        ]
        hits = snc.scan_heuristics(messages)
        assert len(hits) > 0
        assert any(h["trigger"] == "user-correction" for h in hits)

    def test_tool_result_with_multiple_user_patterns_all_excluded(self):
        """All USER_PATTERNS are excluded for tool_result messages, not just one."""
        messages = [
            {
                "index": 0,
                "role": "user",
                "text_blocks": [
                    "nope, don't do it like that. "
                    "You should actually use the correct method instead."
                ],
                "has_tool_use": False,
                "is_tool_result": True,
                "tool_names": [],
            },
        ]
        hits = snc.scan_heuristics(messages)
        # No user-correction hits since this is a tool_result
        user_hits = [h for h in hits if h["trigger"] == "user-correction"]
        assert len(user_hits) == 0

    def test_tool_result_does_not_affect_assistant_patterns(self):
        """Assistant messages with is_tool_result should still be scanned for HEURISTIC_PATTERNS."""
        messages = [
            {
                "index": 0,
                "role": "assistant",
                "text_blocks": [
                    "I traced it back to a missing import in the config module. "
                    "The root cause was that the module wasn't loaded."
                ],
                "has_tool_use": False,
                "is_tool_result": False,
                "tool_names": [],
            },
        ]
        hits = snc.scan_heuristics(messages)
        assert len(hits) > 0
        assert any(h["trigger"] == "debug-root-cause" for h in hits)

    def test_mixed_messages_only_genuine_user_matched(self):
        """In a mix of tool_result and genuine user messages, only genuine ones match."""
        messages = [
            {
                "index": 0,
                "role": "user",
                "text_blocks": ["nope, that's wrong, you should use the other one instead"],
                "has_tool_use": False,
                "is_tool_result": True,  # tool result — should be excluded
                "tool_names": [],
            },
            {
                "index": 1,
                "role": "user",
                "text_blocks": ["no, that's not correct, you should actually fix it"],
                "has_tool_use": False,
                "is_tool_result": False,  # genuine user — should match
                "tool_names": [],
            },
        ]
        hits = snc.scan_heuristics(messages)
        user_hits = [h for h in hits if h["trigger"] == "user-correction"]
        assert len(user_hits) == 1
        assert user_hits[0]["index"] == 1  # only the genuine user message


# ---------------------------------------------------------------------------
# Test: system-reminder content excluded from heuristic scan
# ---------------------------------------------------------------------------

class TestSystemReminderExcluded:
    """Messages containing <system-reminder> tags should be excluded from
    all heuristic pattern matching — both HEURISTIC_PATTERNS (assistant)
    and USER_PATTERNS (user)."""

    def test_assistant_with_system_reminder_excluded(self):
        """Assistant message containing system-reminder is skipped entirely."""
        messages = [
            {
                "index": 0,
                "role": "assistant",
                "text_blocks": [
                    "I was wrong about this. The root cause was a race condition. "
                    "<system-reminder>Some injected system text</system-reminder>"
                ],
                "has_tool_use": False,
                "is_tool_result": False,
                "tool_names": [],
            },
        ]
        hits = snc.scan_heuristics(messages)
        assert len(hits) == 0

    def test_user_with_system_reminder_excluded(self):
        """User message containing system-reminder is skipped entirely."""
        messages = [
            {
                "index": 0,
                "role": "user",
                "text_blocks": [
                    "no, that's not correct <system-reminder>hook feedback</system-reminder>"
                ],
                "has_tool_use": False,
                "is_tool_result": False,
                "tool_names": [],
            },
        ]
        hits = snc.scan_heuristics(messages)
        assert len(hits) == 0

    def test_system_reminder_in_separate_text_block(self):
        """system-reminder in any text block excludes the entire message."""
        messages = [
            {
                "index": 0,
                "role": "assistant",
                "text_blocks": [
                    "I was wrong about the approach.",
                    "<system-reminder>This is system content</system-reminder>",
                ],
                "has_tool_use": False,
                "is_tool_result": False,
                "tool_names": [],
            },
        ]
        hits = snc.scan_heuristics(messages)
        assert len(hits) == 0

    def test_without_system_reminder_still_matches(self):
        """Same content WITHOUT system-reminder tag still produces hits."""
        messages = [
            {
                "index": 0,
                "role": "assistant",
                "text_blocks": [
                    "I was wrong about this. The root cause was a race condition."
                ],
                "has_tool_use": False,
                "is_tool_result": False,
                "tool_names": [],
            },
        ]
        hits = snc.scan_heuristics(messages)
        assert len(hits) > 0

    def test_mixed_messages_only_clean_ones_matched(self):
        """In a mix, only messages without system-reminder are scanned."""
        messages = [
            {
                "index": 0,
                "role": "assistant",
                "text_blocks": [
                    "I was wrong. <system-reminder>noise</system-reminder>"
                ],
                "has_tool_use": False,
                "is_tool_result": False,
                "tool_names": [],
            },
            {
                "index": 1,
                "role": "assistant",
                "text_blocks": [
                    "I was wrong about the config. The root cause was a typo."
                ],
                "has_tool_use": False,
                "is_tool_result": False,
                "tool_names": [],
            },
        ]
        hits = snc.scan_heuristics(messages)
        # Only message at index 1 should produce hits
        assert all(h["index"] == 1 for h in hits)
        assert len(hits) > 0


# ---------------------------------------------------------------------------
# Test: normal user/assistant messages still trigger heuristic patterns
# ---------------------------------------------------------------------------

class TestNormalMessagesStillTrigger:
    """Regression tests: normal messages (no system-reminder, not tool_result)
    should still trigger all heuristic patterns correctly after the exclusion
    logic was added."""

    def _make_msg(self, role, text, index=0, is_tool_result=False):
        return {
            "index": index,
            "role": role,
            "text_blocks": [text],
            "has_tool_use": False,
            "is_tool_result": is_tool_result,
            "tool_names": [],
        }

    def test_self_correction_triggers(self):
        """Assistant self-correction pattern fires on normal message."""
        messages = [self._make_msg(
            "assistant",
            "I initially assumed the config was loaded eagerly, but it turns out "
            "it uses lazy initialization instead."
        )]
        hits = snc.scan_heuristics(messages)
        triggers = [h["trigger"] for h in hits]
        assert "self-correction" in triggers

    def test_debug_root_cause_triggers(self):
        """Assistant debug-root-cause pattern fires on normal message."""
        messages = [self._make_msg(
            "assistant",
            "I found the source of the failure. The root cause was a missing "
            "null check in the serialization path."
        )]
        hits = snc.scan_heuristics(messages)
        triggers = [h["trigger"] for h in hits]
        assert "debug-root-cause" in triggers

    def test_design_decision_triggers(self):
        """Assistant design-decision pattern fires on normal message."""
        messages = [self._make_msg(
            "assistant",
            "We chose SQLite over PostgreSQL because the dataset fits in memory "
            "and we need zero-configuration deployment."
        )]
        hits = snc.scan_heuristics(messages)
        triggers = [h["trigger"] for h in hits]
        assert "design-decision" in triggers

    def test_gotcha_triggers(self):
        """Assistant gotcha/pitfall pattern fires on normal message."""
        messages = [self._make_msg(
            "assistant",
            "Watch out for the edge case where the input list is empty — the "
            "function silently returns None instead of raising."
        )]
        hits = snc.scan_heuristics(messages)
        triggers = [h["trigger"] for h in hits]
        assert "gotcha" in triggers

    def test_user_correction_triggers(self):
        """User correction pattern fires on genuine user message."""
        messages = [self._make_msg(
            "user",
            "No, that's not correct. You should actually use the v2 API endpoint."
        )]
        hits = snc.scan_heuristics(messages)
        triggers = [h["trigger"] for h in hits]
        assert "user-correction" in triggers

    def test_all_patterns_in_mixed_conversation(self):
        """Multiple patterns fire across a realistic conversation."""
        messages = [
            self._make_msg(
                "assistant",
                "I initially thought the cache was invalidated on write, "
                "but actually it uses a TTL-based approach.",
                index=0,
            ),
            self._make_msg(
                "user",
                "No, that's not correct. You need to use the manual invalidation API.",
                index=1,
            ),
            self._make_msg(
                "assistant",
                "I traced it back to a stale cache entry. The root cause was "
                "that TTL wasn't being reset on update.",
                index=2,
            ),
            self._make_msg(
                "assistant",
                "Be careful with the cache config — there's a subtle edge case "
                "where concurrent writes silently drop the second update.",
                index=3,
            ),
        ]
        hits = snc.scan_heuristics(messages)
        triggers = set(h["trigger"] for h in hits)
        # Should have hits from multiple trigger categories
        assert "self-correction" in triggers
        assert "user-correction" in triggers
        assert "debug-root-cause" in triggers
        assert "gotcha" in triggers

    def test_bland_messages_produce_no_hits(self):
        """Messages without trigger patterns should not produce false positives."""
        messages = [
            self._make_msg("assistant", "I'll read the file now.", index=0),
            self._make_msg("user", "Thanks, looks good.", index=1),
            self._make_msg("assistant", "The tests all pass.", index=2),
        ]
        hits = snc.scan_heuristics(messages)
        assert len(hits) == 0
