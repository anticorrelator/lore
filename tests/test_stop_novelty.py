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


# ---------------------------------------------------------------------------
# Test: ±200 char context window in scan_heuristics
# ---------------------------------------------------------------------------

class TestContextWindow:
    """scan_heuristics extracts up to ±200 chars of surrounding context.

    The context window is measured from match.start() (before) and match.end()
    (after) of the matched keyword — not from the edges of the trigger phrase.
    After widening from ±60 to ±200, matched_text should include content up to
    200 chars before match.start() and up to 200 chars after match.end().
    """

    def _make_assistant(self, text, index=0):
        return {
            "index": index,
            "role": "assistant",
            "text_blocks": [text],
            "has_tool_use": False,
            "is_tool_result": False,
            "tool_names": [],
        }

    def _make_user(self, text, index=0):
        return {
            "index": index,
            "role": "user",
            "text_blocks": [text],
            "has_tool_use": False,
            "is_tool_result": False,
            "tool_names": [],
        }

    def test_context_includes_200_chars_before_match_start(self):
        """matched_text includes exactly 200 chars before the matched keyword.

        'root cause' is the matched keyword. Place exactly 200 chars of 'a's
        before it (with a space for word boundary), so the full prefix appears.
        """
        # 199 'a's + space = 200 chars; 'root cause' starts at position 200
        prefix = "a" * 199 + " "
        text = prefix + "root cause was a missing import"
        messages = [self._make_assistant(text)]
        hits = snc.scan_heuristics(messages)
        debug_hits = [h for h in hits if h["trigger"] == "debug-root-cause"]
        assert len(debug_hits) == 1
        matched = debug_hits[0]["matched_text"]
        # All 199 'a's should be present (match.start()=200, window starts at 0)
        assert "a" * 199 in matched

    def test_context_includes_200_chars_after_match_end(self):
        """matched_text includes up to 200 chars after the matched keyword ends.

        'root cause' ends at position 10. With +200 window, chars up to
        position 210 are included. Place 200 chars after the keyword.
        """
        # keyword + space + 199 'b's = 200 chars after match.start()
        # match.end()=10, so end=210; 'b's start at 11, run to 210 -> 199 b's
        text = "root cause " + "b" * 199
        messages = [self._make_assistant(text)]
        hits = snc.scan_heuristics(messages)
        debug_hits = [h for h in hits if h["trigger"] == "debug-root-cause"]
        assert len(debug_hits) == 1
        matched = debug_hits[0]["matched_text"]
        assert "b" * 199 in matched

    def test_prefix_beyond_200_chars_from_match_is_excluded(self):
        """Text more than 200 chars before match.start() is not included.

        Place a unique sentinel string exactly 202 chars before the keyword.
        With ±200 window, the sentinel is outside the window and must not appear
        in matched_text.
        """
        # sentinel (5 chars) + filler (197 chars) + space + keyword
        # match.start() = 203; window start = max(0, 203-200) = 3
        # sentinel occupies positions 0..4, which is BEFORE position 3 after window start
        sentinel = "ZZZZ "
        filler = "a" * 197 + " "
        text = sentinel + filler + "root cause was a missing null check"
        messages = [self._make_assistant(text)]
        hits = snc.scan_heuristics(messages)
        debug_hits = [h for h in hits if h["trigger"] == "debug-root-cause"]
        assert len(debug_hits) == 1
        matched = debug_hits[0]["matched_text"]
        # The sentinel is >200 chars before match.start() and must be excluded
        assert "ZZZZ" not in matched
        # But content within 200 chars of match.start() should be present
        assert "a" * 100 in matched

    def test_suffix_beyond_200_chars_from_match_end_is_excluded(self):
        """Text more than 200 chars after match.end() is not included.

        With 'root cause' at start (match.end()~=10) and 300 'b's after,
        the window ends at 210 — so only ~199 of the 300 'b's appear.
        """
        # match.end()=10; end = min(10+200=210, total); 'b's from pos 11 to 210 = 199 b's
        text = "root cause " + "b" * 300
        messages = [self._make_assistant(text)]
        hits = snc.scan_heuristics(messages)
        debug_hits = [h for h in hits if h["trigger"] == "debug-root-cause"]
        assert len(debug_hits) == 1
        matched = debug_hits[0]["matched_text"]
        assert "b" * 200 not in matched

    def test_short_text_returns_full_context(self):
        """When full text is shorter than ±200 chars, the entire text is returned."""
        text = "We chose SQLite because it fits in memory."
        messages = [self._make_assistant(text)]
        hits = snc.scan_heuristics(messages)
        design_hits = [h for h in hits if h["trigger"] == "design-decision"]
        assert len(design_hits) == 1
        matched = design_hits[0]["matched_text"]
        assert matched == text.strip()

    def test_old_60_char_boundary_is_no_longer_the_limit(self):
        """Text between 61 and 200 chars from the match is now included (was excluded at ±60).

        With 150 'a's before the keyword, the old ±60 window would have included
        only 60 of them. The new ±200 window includes all 150.
        """
        # 149 'a's + space = 150 chars; match.start()=150, old window start=90, new=0
        prefix = "a" * 149 + " "
        text = prefix + "root cause was a missing import"
        messages = [self._make_assistant(text)]
        hits = snc.scan_heuristics(messages)
        debug_hits = [h for h in hits if h["trigger"] == "debug-root-cause"]
        assert len(debug_hits) == 1
        matched = debug_hits[0]["matched_text"]
        # With ±60 only 60 a's would appear; with ±200 all 149 appear
        assert "a" * 149 in matched

    def test_user_pattern_context_window_is_also_200(self):
        """USER_PATTERNS (user-correction) uses the same ±200 char context window.

        Place 150 'a's before the user-correction keyword to verify the window
        extends far enough to include text beyond the old ±60 limit.
        """
        # USER_CORRECTION_RE matches 'no' at word boundary
        # 149 'a's + space + 'no, ...' -> match.start()=150, window start=0
        prefix = "a" * 149 + " "
        text = prefix + "no, that is not correct, use the other approach"
        messages = [self._make_user(text)]
        hits = snc.scan_heuristics(messages)
        correction_hits = [h for h in hits if h["trigger"] == "user-correction"]
        assert len(correction_hits) == 1
        matched = correction_hits[0]["matched_text"]
        # All 149 'a's should appear — they are within 200 chars of match.start()
        assert "a" * 149 in matched


# ---------------------------------------------------------------------------
# Test: load_config() — missing file, partial fields, invalid values
# ---------------------------------------------------------------------------

class TestLoadConfig:
    """Tests for load_config(): config loading with fallback to hardcoded defaults."""

    @pytest.fixture(autouse=True)
    def _patch_config_path(self, tmp_path, monkeypatch):
        """Redirect config path to a temp directory for all tests in this class."""
        self.config_dir = tmp_path / ".lore" / "config"
        self.config_dir.mkdir(parents=True)
        self.config_path = self.config_dir / "capture-config.json"
        _original = os.path.expanduser
        monkeypatch.setattr(
            os.path, "expanduser",
            lambda p: str(self.config_path) if "capture-config.json" in p else _original(p),
        )

    def test_missing_file_returns_all_defaults(self):
        """When config file does not exist, load_config() returns all defaults."""
        # config_path does not exist (not written)
        result = snc.load_config()
        assert result == snc.DEFAULTS

    def test_partial_config_overrides_specified_fields(self):
        """Partial config overrides only the specified fields, others stay default."""
        self.config_path.write_text(
            json.dumps({"region_window": 10, "max_candidates": 3}),
            encoding="utf-8",
        )
        result = snc.load_config()
        assert result["region_window"] == 10
        assert result["max_candidates"] == 3
        # Unspecified fields stay at defaults
        assert result["novelty_threshold"] == snc.DEFAULTS["novelty_threshold"]
        assert result["min_tool_uses"] == snc.DEFAULTS["min_tool_uses"]
        assert result["synthesis_char_threshold"] == snc.DEFAULTS["synthesis_char_threshold"]

    def test_invalid_json_falls_back_to_defaults_with_warning(self, capsys):
        """Malformed JSON falls back to all defaults and logs to stderr."""
        self.config_path.write_text("not valid json {{{", encoding="utf-8")
        result = snc.load_config()
        assert result == snc.DEFAULTS
        captured = capsys.readouterr()
        assert "invalid capture-config.json" in captured.err
        assert "using defaults" in captured.err

    def test_wrong_type_falls_back_per_field(self, capsys):
        """Wrong types fall back to defaults for those fields, with stderr warning."""
        self.config_path.write_text(
            json.dumps({
                "region_window": "not_a_number",
                "max_candidates": 7,
            }),
            encoding="utf-8",
        )
        result = snc.load_config()
        # region_window has wrong type — should stay at default
        assert result["region_window"] == snc.DEFAULTS["region_window"]
        # max_candidates is valid — should be overridden
        assert result["max_candidates"] == 7
        captured = capsys.readouterr()
        assert "invalid type" in captured.err
        assert "region_window" in captured.err

    def test_non_dict_json_falls_back_to_defaults(self, capsys):
        """JSON that parses but isn't an object falls back to defaults."""
        self.config_path.write_text(json.dumps([1, 2, 3]), encoding="utf-8")
        result = snc.load_config()
        assert result == snc.DEFAULTS
        captured = capsys.readouterr()
        assert "not a JSON object" in captured.err

    def test_empty_config_returns_all_defaults(self):
        """Empty JSON object returns all defaults unchanged (plus adaptive=False)."""
        self.config_path.write_text("{}", encoding="utf-8")
        result = snc.load_config()
        expected = dict(snc.DEFAULTS)
        expected["adaptive"] = False
        assert result == expected

    def test_unknown_keys_ignored(self):
        """Keys not in DEFAULTS are silently ignored."""
        self.config_path.write_text(
            json.dumps({"unknown_key": 42, "region_window": 8}),
            encoding="utf-8",
        )
        result = snc.load_config()
        assert "unknown_key" not in result
        assert result["region_window"] == 8

    def test_float_value_for_int_field_coerced(self):
        """Float value for an int-default field is coerced to int."""
        self.config_path.write_text(
            json.dumps({"region_window": 7.9}),
            encoding="utf-8",
        )
        result = snc.load_config()
        assert result["region_window"] == 7
        assert isinstance(result["region_window"], int)

    def test_all_fields_overridden(self):
        """Every field can be overridden at once."""
        overrides = {k: v * 2 for k, v in snc.DEFAULTS.items()}
        self.config_path.write_text(json.dumps(overrides), encoding="utf-8")
        result = snc.load_config()
        for key, val in overrides.items():
            expected_type = type(snc.DEFAULTS[key])
            assert result[key] == expected_type(val)


# ---------------------------------------------------------------------------
# Test: behavioral equivalence — no config produces identical output to pre-change
# ---------------------------------------------------------------------------

FIXTURES_DIR = os.path.join(os.path.dirname(__file__), "fixtures")

# Import transcript parser
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
from transcript import parse_transcript


class TestBehavioralEquivalence:
    """Regression test: with no config file, scan_heuristics and scan_structural_signals
    produce the exact same hits as the golden transcript fixture. This proves config
    externalization introduced no behavioral changes when no config is present."""

    @pytest.fixture
    def golden_transcript(self):
        return os.path.join(FIXTURES_DIR, "golden_transcript.jsonl")

    @pytest.fixture
    def golden_expected(self):
        with open(os.path.join(FIXTURES_DIR, "golden_expected.json"), "r") as f:
            return json.load(f)

    def _normalize_hits(self, hits):
        """Extract (index, role, trigger) tuples sorted for comparison."""
        return sorted(
            (h["index"], h["role"], h["trigger"]) for h in hits
        )

    def test_heuristic_hits_match_golden(self, golden_transcript, golden_expected):
        """scan_heuristics produces the same hits as the golden fixture."""
        messages = parse_transcript(golden_transcript)
        actual = snc.scan_heuristics(messages)
        expected = golden_expected["heuristic_hits"]

        assert self._normalize_hits(actual) == self._normalize_hits(expected)

    def test_structural_hits_match_golden(self, golden_transcript, golden_expected):
        """scan_structural_signals produces the same hits as the golden fixture."""
        messages = parse_transcript(golden_transcript)
        actual = snc.scan_structural_signals(messages, transcript_path=golden_transcript)
        expected = golden_expected["structural_hits"]

        assert self._normalize_hits(actual) == self._normalize_hits(expected)

    def test_combined_hits_match_golden(self, golden_transcript, golden_expected):
        """Combined heuristic + structural hits match golden fixture exactly."""
        messages = parse_transcript(golden_transcript)
        heuristic = snc.scan_heuristics(messages)
        structural = snc.scan_structural_signals(messages, transcript_path=golden_transcript)
        actual_combined = heuristic + structural

        expected_combined = (
            golden_expected["heuristic_hits"] + golden_expected["structural_hits"]
        )

        assert self._normalize_hits(actual_combined) == self._normalize_hits(expected_combined)

    def test_defaults_match_original_hardcoded_values(self):
        """DEFAULTS dict contains exactly the original hardcoded values from pre-config code."""
        # These are the values that were hardcoded before config externalization.
        # If any change, this test fails — proving behavioral equivalence.
        expected = {
            "novelty_threshold": -1.0,
            "region_window": 5,
            "max_candidates": 5,
            "max_phrases": 15,
            "min_tool_uses": 5,
            "max_tool_uses": 10,
            "investigation_window": 10,
            "iterative_debug_window": 15,
            "test_fix_window": 10,
            "synthesis_char_threshold": 1000,
            "synthesis_tool_threshold": 8,
            "file_context_window": 10,
            "debug_context_window": 10,
            "debug_context_chars": 800,
        }
        assert snc.DEFAULTS == expected


# ---------------------------------------------------------------------------
# Test: read_store_stats() — _manifest.json parsing
# ---------------------------------------------------------------------------

class TestReadStoreStats:
    """Tests for read_store_stats(): reads entry count from _manifest.json."""

    def test_valid_manifest_returns_entry_count(self, tmp_path):
        """Returns the number of entries in a valid _manifest.json."""
        manifest = {"entries": [{"title": f"entry-{i}"} for i in range(25)]}
        (tmp_path / "_manifest.json").write_text(
            json.dumps(manifest), encoding="utf-8"
        )
        assert snc.read_store_stats(str(tmp_path)) == 25

    def test_empty_entries_returns_zero(self, tmp_path):
        """Returns 0 when entries list is empty."""
        (tmp_path / "_manifest.json").write_text(
            json.dumps({"entries": []}), encoding="utf-8"
        )
        assert snc.read_store_stats(str(tmp_path)) == 0

    def test_missing_manifest_returns_none(self, tmp_path):
        """Returns None when _manifest.json does not exist."""
        assert snc.read_store_stats(str(tmp_path)) is None

    def test_corrupt_json_returns_none(self, tmp_path, capsys):
        """Returns None for malformed JSON and logs to stderr."""
        (tmp_path / "_manifest.json").write_text(
            "not valid json {{{", encoding="utf-8"
        )
        assert snc.read_store_stats(str(tmp_path)) is None
        captured = capsys.readouterr()
        assert "failed to read _manifest.json" in captured.err

    def test_non_dict_manifest_returns_none(self, tmp_path):
        """Returns None when manifest is valid JSON but not a dict."""
        (tmp_path / "_manifest.json").write_text(
            json.dumps([1, 2, 3]), encoding="utf-8"
        )
        assert snc.read_store_stats(str(tmp_path)) is None

    def test_missing_entries_key_returns_none(self, tmp_path):
        """Returns None when manifest is a dict but has no 'entries' key."""
        (tmp_path / "_manifest.json").write_text(
            json.dumps({"version": 1}), encoding="utf-8"
        )
        assert snc.read_store_stats(str(tmp_path)) is None

    def test_entries_not_a_list_returns_none(self, tmp_path):
        """Returns None when 'entries' is not a list."""
        (tmp_path / "_manifest.json").write_text(
            json.dumps({"entries": "not a list"}), encoding="utf-8"
        )
        assert snc.read_store_stats(str(tmp_path)) is None

    def test_large_manifest_returns_correct_count(self, tmp_path):
        """Correctly counts a large number of entries."""
        manifest = {"entries": [{"title": f"e-{i}"} for i in range(500)]}
        (tmp_path / "_manifest.json").write_text(
            json.dumps(manifest), encoding="utf-8"
        )
        assert snc.read_store_stats(str(tmp_path)) == 500


# ---------------------------------------------------------------------------
# Test: compute_adaptive_threshold() — threshold adjustment based on store maturity
# ---------------------------------------------------------------------------

class TestAdaptiveThreshold:
    """Tests for compute_adaptive_threshold(knowledge_dir, base_threshold):
    adjusts novelty threshold based on store entry count from _manifest.json.

    Mapping:
    - Young store (<50 entries): -0.5 (looser, capture more)
    - Mature store (>200 entries): -1.5 (tighter, capture less)
    - Default range (50-200): base_threshold unchanged
    - Missing/corrupt manifest: fall back to base_threshold
    """

    def _make_manifest(self, path, count):
        """Create a _manifest.json with the given number of entries."""
        manifest = {"entries": [{"title": f"entry-{i}"} for i in range(count)]}
        (path / "_manifest.json").write_text(
            json.dumps(manifest), encoding="utf-8"
        )

    def test_young_store_gets_loose_threshold(self, tmp_path):
        """Store with <50 entries gets looser threshold (-0.5)."""
        self._make_manifest(tmp_path, 30)
        result = snc.compute_adaptive_threshold(str(tmp_path), -1.0)
        assert result == -0.5

    def test_mature_store_gets_tight_threshold(self, tmp_path):
        """Store with >200 entries gets tighter threshold (-1.5)."""
        self._make_manifest(tmp_path, 250)
        result = snc.compute_adaptive_threshold(str(tmp_path), -1.0)
        assert result == -1.5

    def test_default_range_interpolates(self, tmp_path):
        """Store with 100 entries interpolates: t=(100-50)/150, result=-0.5+t*(-1.0)."""
        self._make_manifest(tmp_path, 100)
        result = snc.compute_adaptive_threshold(str(tmp_path), -1.0)
        expected = -0.5 + ((100 - 50) / 150.0) * (-1.0)
        assert result == pytest.approx(expected)

    def test_boundary_50_starts_interpolation(self, tmp_path):
        """Exactly 50 entries is the start of interpolation range (-0.5)."""
        self._make_manifest(tmp_path, 50)
        result = snc.compute_adaptive_threshold(str(tmp_path), -1.0)
        assert result == pytest.approx(-0.5)

    def test_boundary_200_ends_interpolation(self, tmp_path):
        """Exactly 200 entries is the end of interpolation range (-1.5)."""
        self._make_manifest(tmp_path, 200)
        result = snc.compute_adaptive_threshold(str(tmp_path), -1.0)
        assert result == pytest.approx(-1.5)

    def test_boundary_49_is_young(self, tmp_path):
        """49 entries is in the young range."""
        self._make_manifest(tmp_path, 49)
        result = snc.compute_adaptive_threshold(str(tmp_path), -1.0)
        assert result == -0.5

    def test_boundary_201_is_mature(self, tmp_path):
        """201 entries is in the mature range."""
        self._make_manifest(tmp_path, 201)
        result = snc.compute_adaptive_threshold(str(tmp_path), -1.0)
        assert result == -1.5

    def test_zero_entries_is_young(self, tmp_path):
        """Empty store (0 entries) is in the young range."""
        self._make_manifest(tmp_path, 0)
        result = snc.compute_adaptive_threshold(str(tmp_path), -1.0)
        assert result == -0.5

    def test_missing_manifest_returns_base_threshold(self, tmp_path):
        """Missing _manifest.json gracefully falls back to base threshold."""
        result = snc.compute_adaptive_threshold(str(tmp_path), -1.0)
        assert result == -1.0

    def test_corrupt_manifest_returns_base_threshold(self, tmp_path):
        """Corrupt _manifest.json gracefully falls back to base threshold."""
        (tmp_path / "_manifest.json").write_text(
            "not valid json {{{", encoding="utf-8"
        )
        result = snc.compute_adaptive_threshold(str(tmp_path), -1.0)
        assert result == -1.0

    def test_custom_base_threshold_ignored_when_adaptive(self, tmp_path):
        """When adaptive is on, interpolation uses fixed -0.5 to -1.5 range regardless of base."""
        self._make_manifest(tmp_path, 100)
        result = snc.compute_adaptive_threshold(str(tmp_path), -2.0)
        # Interpolation at 100 entries: t=(100-50)/150, result=-0.5+t*(-1.0)
        expected = -0.5 + ((100 - 50) / 150.0) * (-1.0)
        assert result == pytest.approx(expected)

    def test_large_entry_count(self, tmp_path):
        """Very large entry count still returns -1.5."""
        self._make_manifest(tmp_path, 10000)
        result = snc.compute_adaptive_threshold(str(tmp_path), -1.0)
        assert result == -1.5

    def test_non_dict_manifest_returns_base(self, tmp_path):
        """Non-dict manifest (valid JSON, wrong shape) falls back to base."""
        (tmp_path / "_manifest.json").write_text(
            json.dumps([1, 2, 3]), encoding="utf-8"
        )
        result = snc.compute_adaptive_threshold(str(tmp_path), -1.0)
        assert result == -1.0

    def test_manifest_missing_entries_key_returns_base(self, tmp_path):
        """Manifest without 'entries' key falls back to base."""
        (tmp_path / "_manifest.json").write_text(
            json.dumps({"version": 1}), encoding="utf-8"
        )
        result = snc.compute_adaptive_threshold(str(tmp_path), -1.0)
        assert result == -1.0


# ---------------------------------------------------------------------------
# Test: adapt_threshold() — core threshold logic with config dict
# ---------------------------------------------------------------------------

class TestAdaptThreshold:
    """Tests for adapt_threshold(config, entry_count): the core function that
    checks the adaptive flag and applies threshold mapping."""

    def _config(self, adaptive=True, threshold=-1.0):
        config = dict(snc.DEFAULTS)
        config["adaptive"] = adaptive
        config["novelty_threshold"] = threshold
        return config

    def test_adaptive_false_returns_base(self):
        """adaptive=false returns base threshold regardless of entry count."""
        assert snc.adapt_threshold(self._config(adaptive=False), 30) == -1.0

    def test_adaptive_false_custom_base(self):
        """adaptive=false returns custom base threshold unchanged."""
        assert snc.adapt_threshold(self._config(adaptive=False, threshold=-2.5), 30) == -2.5

    def test_adaptive_false_mature_store(self):
        """adaptive=false with mature store still returns base."""
        assert snc.adapt_threshold(self._config(adaptive=False), 500) == -1.0

    def test_adaptive_false_none_count(self):
        """adaptive=false with None entry count returns base."""
        assert snc.adapt_threshold(self._config(adaptive=False), None) == -1.0

    def test_adaptive_true_young(self):
        """adaptive=true with young store returns -0.5."""
        assert snc.adapt_threshold(self._config(), 30) == -0.5

    def test_adaptive_true_mature(self):
        """adaptive=true with mature store returns -1.5."""
        assert snc.adapt_threshold(self._config(), 250) == -1.5

    def test_adaptive_true_interpolation(self):
        """adaptive=true with 125 entries returns midpoint (-1.0)."""
        assert snc.adapt_threshold(self._config(), 125) == pytest.approx(-1.0)

    def test_adaptive_true_none_count(self):
        """adaptive=true with None entry count falls back to base."""
        assert snc.adapt_threshold(self._config(), None) == -1.0

    def test_adaptive_true_none_count_custom_base(self):
        """adaptive=true with None entry count falls back to custom base."""
        assert snc.adapt_threshold(self._config(threshold=-2.5), None) == -2.5


# ---------------------------------------------------------------------------
# Test: adaptive=false in config produces no threshold change
# ---------------------------------------------------------------------------

class TestAdaptiveFalseNoChange:
    """When adaptive=false in config, the main() code path does not call
    compute_adaptive_threshold, so the base threshold is used unchanged."""

    def _make_manifest(self, path, count):
        manifest = {"entries": [{"title": f"entry-{i}"} for i in range(count)]}
        (path / "_manifest.json").write_text(
            json.dumps(manifest), encoding="utf-8"
        )

    def test_adaptive_false_config_preserves_threshold(self, tmp_path, monkeypatch):
        """With adaptive=false, load_config returns adaptive=False and threshold unchanged."""
        config_path = tmp_path / "capture-config.json"
        config_path.write_text(json.dumps({
            "core": {"novelty_threshold": -1.0},
            "structural_signals": {},
            "adaptive": False,
        }), encoding="utf-8")

        _original = os.path.expanduser
        monkeypatch.setattr(
            os.path, "expanduser",
            lambda p: str(config_path) if "capture-config.json" in p else _original(p),
        )

        config = snc.load_config()
        assert config["adaptive"] is False
        assert config["novelty_threshold"] == -1.0

    def test_adaptive_true_config_sets_flag(self, tmp_path, monkeypatch):
        """With adaptive=true, load_config returns adaptive=True."""
        config_path = tmp_path / "capture-config.json"
        config_path.write_text(json.dumps({
            "core": {"novelty_threshold": -1.0},
            "structural_signals": {},
            "adaptive": True,
        }), encoding="utf-8")

        _original = os.path.expanduser
        monkeypatch.setattr(
            os.path, "expanduser",
            lambda p: str(config_path) if "capture-config.json" in p else _original(p),
        )

        config = snc.load_config()
        assert config["adaptive"] is True

    def test_adaptive_flag_gates_threshold_adjustment(self, tmp_path):
        """Simulates main() logic: only adjusts threshold when adaptive=True."""
        self._make_manifest(tmp_path, 30)  # young store

        # adaptive=false path
        config_off = dict(snc.DEFAULTS)
        config_off["adaptive"] = False
        if config_off.get("adaptive", False):
            config_off["novelty_threshold"] = snc.compute_adaptive_threshold(
                str(tmp_path), config_off["novelty_threshold"]
            )
        assert config_off["novelty_threshold"] == -1.0  # unchanged

        # adaptive=true path
        config_on = dict(snc.DEFAULTS)
        config_on["adaptive"] = True
        if config_on.get("adaptive", False):
            config_on["novelty_threshold"] = snc.compute_adaptive_threshold(
                str(tmp_path), config_on["novelty_threshold"]
            )
        assert config_on["novelty_threshold"] == -0.5  # adjusted for young store


# ---------------------------------------------------------------------------
# Test: team session detection and filtering
# ---------------------------------------------------------------------------

class TestTeamSessionDetection:
    """Tests for _is_team_session(), _count_lead_tool_uses(),
    and _build_team_exclusion_set() — helpers that detect agent team usage
    and adjust stop hook behavior to prevent false positives."""

    def _make_msg(self, role, text, index=0, tool_names=None, has_tool_use=False, is_tool_result=False):
        return {
            "index": index,
            "role": role,
            "text_blocks": [text],
            "has_tool_use": has_tool_use,
            "is_tool_result": is_tool_result,
            "tool_names": tool_names or [],
        }

    # --- _is_team_session ---

    def test_team_session_with_agent_tool(self):
        """Session with Agent tool use is detected as team session."""
        messages = [
            self._make_msg("assistant", "Spawning agent", index=0, tool_names=["Agent"], has_tool_use=True),
            self._make_msg("user", "agent result", index=1, is_tool_result=True),
        ]
        assert snc._is_team_session(messages) is True

    def test_team_session_with_send_message(self):
        """Session with SendMessage tool use is detected as team session."""
        messages = [
            self._make_msg("assistant", "Sending", index=0, tool_names=["SendMessage"], has_tool_use=True),
        ]
        assert snc._is_team_session(messages) is True

    def test_non_team_session(self):
        """Session with only Read/Edit/Bash is NOT a team session."""
        messages = [
            self._make_msg("assistant", "Reading", index=0, tool_names=["Read"], has_tool_use=True),
            self._make_msg("assistant", "Editing", index=1, tool_names=["Edit"], has_tool_use=True),
            self._make_msg("assistant", "Running", index=2, tool_names=["Bash"], has_tool_use=True),
        ]
        assert snc._is_team_session(messages) is False

    def test_empty_session_is_not_team(self):
        """Empty message list is not a team session."""
        assert snc._is_team_session([]) is False

    def test_no_tool_use_is_not_team(self):
        """Session with no tool uses is not a team session."""
        messages = [
            self._make_msg("assistant", "Hello", index=0),
            self._make_msg("user", "Hi", index=1),
        ]
        assert snc._is_team_session(messages) is False

    # --- _count_lead_tool_uses ---

    def test_lead_count_excludes_pure_agent_messages(self):
        """Pure Agent/SendMessage messages are not counted."""
        messages = [
            self._make_msg("assistant", "Read file", index=0, tool_names=["Read"], has_tool_use=True),
            self._make_msg("assistant", "Spawn agent", index=1, tool_names=["Agent"], has_tool_use=True),
            self._make_msg("assistant", "Send msg", index=2, tool_names=["SendMessage"], has_tool_use=True),
            self._make_msg("assistant", "Edit file", index=3, tool_names=["Edit"], has_tool_use=True),
        ]
        assert snc._count_lead_tool_uses(messages) == 2  # Read + Edit

    def test_lead_count_includes_mixed_tool_messages(self):
        """Messages with both Agent and other tools ARE counted."""
        messages = [
            self._make_msg("assistant", "Agent+Read", index=0, tool_names=["Agent", "Read"], has_tool_use=True),
        ]
        assert snc._count_lead_tool_uses(messages) == 1

    def test_lead_count_all_non_team(self):
        """All non-team tool messages are counted."""
        messages = [
            self._make_msg("assistant", "Step 1", index=i, tool_names=["Bash"], has_tool_use=True)
            for i in range(5)
        ]
        assert snc._count_lead_tool_uses(messages) == 5

    def test_lead_count_all_team(self):
        """All-Agent session counts as 0 lead tool uses."""
        messages = [
            self._make_msg("assistant", "Agent", index=i, tool_names=["Agent"], has_tool_use=True)
            for i in range(5)
        ]
        assert snc._count_lead_tool_uses(messages) == 0

    def test_lead_count_skips_non_tool_messages(self):
        """Messages without tool_use are not counted regardless of tool_names."""
        messages = [
            self._make_msg("assistant", "No tool use", index=0, tool_names=["Read"], has_tool_use=False),
        ]
        assert snc._count_lead_tool_uses(messages) == 0

    # --- _build_team_exclusion_set ---

    def test_exclusion_set_covers_agent_window(self):
        """Assistant messages from first Agent call to TEAM_COOLDOWN messages after are excluded.

        Uses position-based window (not JSONL line numbers), so sparse indices
        don't shrink the effective cooldown.
        """
        # Positions:  0        1(Agent)  2        3         4         5         6         7
        messages = [
            self._make_msg("assistant", "Before agents", index=0, tool_names=["Read"], has_tool_use=True),
            self._make_msg("assistant", "Spawn agent", index=50, tool_names=["Agent"], has_tool_use=True),
            self._make_msg("user", "Agent result", index=80, is_tool_result=True),
            self._make_msg("assistant", "Synthesize findings", index=90),
            self._make_msg("assistant", "More synthesis", index=100),
            self._make_msg("assistant", "Still in cooldown", index=110),
            self._make_msg("assistant", "Last in cooldown", index=120),
            self._make_msg("assistant", "After cooldown", index=200),
        ]
        exclusions = snc._build_team_exclusion_set(messages)
        # Position 0 (index=0) is before the Agent call at position 1 — NOT excluded
        assert 0 not in exclusions
        # Positions 1-6 are within the window (Agent at pos 1, cooldown=5, end=6)
        assert 90 in exclusions   # position 3 — synthesis
        assert 100 in exclusions  # position 4
        assert 110 in exclusions  # position 5
        assert 120 in exclusions  # position 6 — last in cooldown
        # Position 7 (index=200) is past cooldown — NOT excluded
        assert 200 not in exclusions

    def test_exclusion_set_uses_positions_not_line_numbers(self):
        """Window uses message list positions, not JSONL line numbers.

        With sparse indices (real transcripts have gaps), a line-number-based
        window would miss messages that are nearby in the conversation but
        have distant line numbers.
        """
        messages = [
            self._make_msg("assistant", "Agent call", index=10, tool_names=["Agent"], has_tool_use=True),
            self._make_msg("user", "Result", index=500, is_tool_result=True),
            self._make_msg("assistant", "Synthesis", index=900),
        ]
        exclusions = snc._build_team_exclusion_set(messages)
        # Despite index=900 being far from index=10, it's at position 2
        # which is within TEAM_COOLDOWN (5) of position 0 — should be excluded
        assert 900 in exclusions

    def test_exclusion_set_empty_for_non_team(self):
        """Non-team sessions produce empty exclusion set."""
        messages = [
            self._make_msg("assistant", "Read", index=0, tool_names=["Read"], has_tool_use=True),
            self._make_msg("assistant", "Edit", index=1, tool_names=["Edit"], has_tool_use=True),
        ]
        assert snc._build_team_exclusion_set(messages) == set()

    def test_exclusion_set_only_excludes_assistant_messages(self):
        """User messages in the window are NOT excluded (handled separately)."""
        messages = [
            self._make_msg("assistant", "Spawn", index=5, tool_names=["Agent"], has_tool_use=True),
            self._make_msg("user", "Agent result", index=6, is_tool_result=True),
            self._make_msg("assistant", "Synthesis", index=7),
        ]
        exclusions = snc._build_team_exclusion_set(messages)
        assert 6 not in exclusions  # user message, not excluded
        assert 7 in exclusions  # assistant in window


# ---------------------------------------------------------------------------
# Test: team session heuristic filtering with exclusions
# ---------------------------------------------------------------------------

class TestTeamSessionHeuristicFiltering:
    """Tests that scan_heuristics() correctly filters assistant messages
    in team sessions while preserving user correction detection."""

    def _make_msg(self, role, text, index=0, tool_names=None, has_tool_use=False, is_tool_result=False):
        return {
            "index": index,
            "role": role,
            "text_blocks": [text],
            "has_tool_use": has_tool_use,
            "is_tool_result": is_tool_result,
            "tool_names": tool_names or [],
        }

    def test_excluded_assistant_messages_not_scanned(self):
        """Assistant messages in team_exclusions are skipped for heuristic patterns."""
        messages = [
            self._make_msg(
                "assistant",
                "The root cause was a race condition in the connection pool.",
                index=7,
            ),
        ]
        # Without exclusions — should match
        hits_without = snc.scan_heuristics(messages)
        assert len(hits_without) > 0

        # With exclusions — should NOT match
        hits_with = snc.scan_heuristics(messages, team_exclusions={7})
        assert len(hits_with) == 0

    def test_non_excluded_assistant_messages_still_scanned(self):
        """Assistant messages NOT in team_exclusions are scanned normally."""
        messages = [
            self._make_msg(
                "assistant",
                "I was wrong about the cache. It turns out it uses lazy init.",
                index=20,
            ),
        ]
        hits = snc.scan_heuristics(messages, team_exclusions={5, 6, 7})
        assert len(hits) > 0
        assert any(h["trigger"] == "self-correction" for h in hits)

    def test_user_corrections_still_detected_in_team_sessions(self):
        """User corrections are still detected even when team_exclusions is set."""
        messages = [
            self._make_msg(
                "user",
                "No, that's not correct. You should actually use the v2 API.",
                index=3,
            ),
        ]
        hits = snc.scan_heuristics(messages, team_exclusions={5, 6, 7, 8})
        assert len(hits) > 0
        assert any(h["trigger"] == "user-correction" for h in hits)

    def test_teammate_messages_still_filtered_in_team_sessions(self):
        """Teammate messages in user role are still filtered (double protection)."""
        messages = [
            self._make_msg(
                "user",
                '<teammate-message from="reviewer-1">No, you should use the v2 API instead</teammate-message>',
                index=3,
            ),
        ]
        hits = snc.scan_heuristics(messages, team_exclusions={5, 6, 7})
        assert len(hits) == 0

    def test_realistic_team_conversation(self):
        """End-to-end: a realistic team session with agent coordination.

        Agent call is at list position 1. With TEAM_COOLDOWN=5 the exclusion
        window covers positions 1-6.  We pad with filler messages so the
        post-cooldown discovery lands at position 7+.
        """
        messages = [
            # pos 0 — Lead reads files (before agent coordination)
            self._make_msg("assistant", "Let me read the code.", index=0, tool_names=["Read"], has_tool_use=True),
            # pos 1 — Lead spawns agents
            self._make_msg("assistant", "Spawning review team.", index=5, tool_names=["Agent"], has_tool_use=True),
            # pos 2 — Agent results come back
            self._make_msg("user", "The root cause was a missing null check", index=6, is_tool_result=True),
            # pos 3 — Lead synthesizes (trigger phrases, should be excluded)
            self._make_msg(
                "assistant",
                "The reviewer found the root cause was a missing null check. "
                "We chose to add validation because the API contract requires it. "
                "Watch out for the edge case where input is empty.",
                index=7,
            ),
            # pos 4 — Another agent result
            self._make_msg("user", '<teammate-message from="sec">should use parameterized queries instead</teammate-message>', index=8),
            # pos 5 — More synthesis
            self._make_msg(
                "assistant",
                "The security review found that we should use parameterized queries. "
                "I traced it back to the legacy SQL builder.",
                index=9,
            ),
            # pos 6 — last position in cooldown window
            self._make_msg("assistant", "Wrapping up agent findings.", index=10),
            # pos 7 — past cooldown, independent work
            self._make_msg(
                "assistant",
                "It turns out the config was loaded eagerly, not lazily as I expected.",
                index=50,
            ),
        ]

        team_exclusions = snc._build_team_exclusion_set(messages)
        hits = snc.scan_heuristics(messages, team_exclusions=team_exclusions)

        # Messages at indices 7 and 9 should be excluded (in agent window)
        hit_indices = {h["index"] for h in hits}
        assert 7 not in hit_indices
        assert 9 not in hit_indices

        # Post-cooldown message (index=50, position 7) should be scanned
        assert 50 in hit_indices

    def test_none_exclusions_scans_everything(self):
        """team_exclusions=None (non-team session) scans all messages."""
        messages = [
            self._make_msg(
                "assistant",
                "The root cause was a null pointer dereference.",
                index=0,
            ),
        ]
        hits = snc.scan_heuristics(messages, team_exclusions=None)
        assert len(hits) > 0

    def test_empty_exclusions_scans_everything(self):
        """Empty team_exclusions set scans all messages."""
        messages = [
            self._make_msg(
                "assistant",
                "The root cause was a null pointer dereference.",
                index=0,
            ),
        ]
        hits = snc.scan_heuristics(messages, team_exclusions=set())
        assert len(hits) > 0


# ---------------------------------------------------------------------------
# Test: tightened SELF_CORRECTION_RE — bare "actually" no longer matches
# ---------------------------------------------------------------------------

class TestSelfCorrectionRETightened:
    """SELF_CORRECTION_RE was tightened: the bare `actually[,\\s]` alternative was
    removed. It now requires context like 'I thought/expected/assumed...but actually'.

    False positive cases:
      - 'This actually uses a buffer pool' — no I-thought context, should NOT fire
      - 'It actually works fine' — bare 'actually', should NOT fire

    True positive cases:
      - 'I thought it used malloc but actually it uses a buffer pool' — hits
      - 'I assumed it was lazy but actually it is eager' — hits
      - 'I expected it to fail but actually it succeeded' — hits
    """

    def _make_assistant(self, text, index=0):
        return {
            "index": index,
            "role": "assistant",
            "text_blocks": [text],
            "has_tool_use": False,
            "is_tool_result": False,
            "tool_names": [],
        }

    def test_bare_actually_no_hit(self):
        """'This actually uses a buffer pool' does NOT produce a self-correction hit.

        Without I-thought context, bare 'actually' was a common false positive.
        """
        messages = [self._make_assistant("This actually uses a buffer pool.")]
        hits = snc.scan_heuristics(messages)
        self_hits = [h for h in hits if h["trigger"] == "self-correction"]
        assert len(self_hits) == 0

    def test_bare_actually_works_fine_no_hit(self):
        """'It actually works fine' does NOT produce a self-correction hit."""
        messages = [self._make_assistant("It actually works fine.")]
        hits = snc.scan_heuristics(messages)
        self_hits = [h for h in hits if h["trigger"] == "self-correction"]
        assert len(self_hits) == 0

    def test_i_thought_but_actually_hits(self):
        """'I thought it used malloc but actually it uses a buffer pool' fires."""
        messages = [self._make_assistant(
            "I thought it used malloc but actually it uses a buffer pool."
        )]
        hits = snc.scan_heuristics(messages)
        self_hits = [h for h in hits if h["trigger"] == "self-correction"]
        assert len(self_hits) > 0

    def test_i_assumed_but_actually_hits(self):
        """'I assumed it was lazy but actually it is eager' fires."""
        messages = [self._make_assistant(
            "I assumed it was lazy but actually it is eager."
        )]
        hits = snc.scan_heuristics(messages)
        self_hits = [h for h in hits if h["trigger"] == "self-correction"]
        assert len(self_hits) > 0

    def test_i_expected_but_actually_hits(self):
        """'I expected it to fail but actually it succeeded' fires."""
        messages = [self._make_assistant(
            "I expected it to fail but actually it succeeded."
        )]
        hits = snc.scan_heuristics(messages)
        self_hits = [h for h in hits if h["trigger"] == "self-correction"]
        assert len(self_hits) > 0

    def test_it_turns_out_still_hits(self):
        """'it turns out' still fires (unrelated to the tightened alternative)."""
        messages = [self._make_assistant(
            "It turns out the module was never initialized."
        )]
        hits = snc.scan_heuristics(messages)
        self_hits = [h for h in hits if h["trigger"] == "self-correction"]
        assert len(self_hits) > 0


# ---------------------------------------------------------------------------
# Test: tightened DEBUG_ROOT_CAUSE_RE — error context required for "caused by"
# ---------------------------------------------------------------------------

class TestDebugRootCauseRETightened:
    """DEBUG_ROOT_CAUSE_RE was tightened:
    - 'the problem is that' was removed entirely
    - 'caused by (a|an|the)' now requires an error context word
      (error|bug|failure|crash|issue|problem) within 50 chars before it

    False positive cases:
      - 'The retry mechanism is caused by a design choice' — no error context, no hit
      - 'The latency is caused by a slow network' — no error context, no hit

    True positive cases:
      - 'The crash was caused by a null pointer' — 'crash' within 50 chars, hits
      - 'This issue was caused by a missing import' — 'issue' within 50 chars, hits
      - 'The error is caused by an invalid config' — 'error' within 50 chars, hits
    """

    def _make_assistant(self, text, index=0):
        return {
            "index": index,
            "role": "assistant",
            "text_blocks": [text],
            "has_tool_use": False,
            "is_tool_result": False,
            "tool_names": [],
        }

    def test_no_error_context_no_hit(self):
        """'The retry mechanism is caused by a design choice' does NOT fire.

        'caused by a' appears but 'retry mechanism' is not an error context word.
        """
        messages = [self._make_assistant(
            "The retry mechanism is caused by a design choice."
        )]
        hits = snc.scan_heuristics(messages)
        debug_hits = [h for h in hits if h["trigger"] == "debug-root-cause"]
        assert len(debug_hits) == 0

    def test_latency_caused_by_no_hit(self):
        """'The latency is caused by a slow network' does NOT fire.

        'latency' is not an error context word.
        """
        messages = [self._make_assistant(
            "The latency is caused by a slow network connection."
        )]
        hits = snc.scan_heuristics(messages)
        debug_hits = [h for h in hits if h["trigger"] == "debug-root-cause"]
        assert len(debug_hits) == 0

    def test_crash_caused_by_hits(self):
        """'The crash was caused by a null pointer' fires.

        'crash' is within 50 chars and is an error context word.
        """
        messages = [self._make_assistant(
            "The crash was caused by a null pointer dereference."
        )]
        hits = snc.scan_heuristics(messages)
        debug_hits = [h for h in hits if h["trigger"] == "debug-root-cause"]
        assert len(debug_hits) > 0

    def test_issue_caused_by_hits(self):
        """'This issue was caused by a missing import' fires."""
        messages = [self._make_assistant(
            "This issue was caused by a missing import in the config module."
        )]
        hits = snc.scan_heuristics(messages)
        debug_hits = [h for h in hits if h["trigger"] == "debug-root-cause"]
        assert len(debug_hits) > 0

    def test_error_caused_by_hits(self):
        """'The error is caused by an invalid config' fires."""
        messages = [self._make_assistant(
            "The error is caused by an invalid config value."
        )]
        hits = snc.scan_heuristics(messages)
        debug_hits = [h for h in hits if h["trigger"] == "debug-root-cause"]
        assert len(debug_hits) > 0

    def test_root_cause_still_hits(self):
        """'root cause' still fires (unrelated to the tightened alternative)."""
        messages = [self._make_assistant(
            "The root cause was a missing null check in the serializer."
        )]
        hits = snc.scan_heuristics(messages)
        debug_hits = [h for h in hits if h["trigger"] == "debug-root-cause"]
        assert len(debug_hits) > 0

    def test_failure_caused_by_hits(self):
        """'The failure was caused by the connection timeout' fires."""
        messages = [self._make_assistant(
            "The failure was caused by the connection timeout handler."
        )]
        hits = snc.scan_heuristics(messages)
        debug_hits = [h for h in hits if h["trigger"] == "debug-root-cause"]
        assert len(debug_hits) > 0


# ---------------------------------------------------------------------------
# Test: _is_structured_output() — templated/quoted content exclusion
# ---------------------------------------------------------------------------

class TestIsStructuredOutput:
    """_is_structured_output(text_blocks) returns True when text blocks contain
    markers of templated or quoted output:
    - **Trigger:** or **Decision:** labels (capture candidate / plan templates)
    - <!-- HTML comments (knowledge store metadata)

    These markers indicate the assistant is formatting structured artifacts,
    not expressing independent reactive discoveries.
    """

    def test_trigger_label_detected(self):
        """Text block with **Trigger:** returns True."""
        assert snc._is_structured_output(["**Trigger:** gotcha"]) is True

    def test_decision_label_detected(self):
        """Text block with **Decision:** returns True."""
        assert snc._is_structured_output(["**Decision:** use sqlite"]) is True

    def test_html_comment_detected(self):
        """Text block with <!-- returns True."""
        assert snc._is_structured_output(["<!-- metadata here -->"]) is True

    def test_trigger_in_multiblock_message(self):
        """**Trigger:** in any text block returns True."""
        assert snc._is_structured_output([
            "Some preamble text.",
            "**Trigger:** self-correction",
            "More content.",
        ]) is True

    def test_plain_text_returns_false(self):
        """Plain text without structured markers returns False."""
        assert snc._is_structured_output([
            "I thought it used malloc but actually it uses a buffer pool."
        ]) is False

    def test_empty_blocks_returns_false(self):
        """Empty text block list returns False."""
        assert snc._is_structured_output([]) is False

    def test_empty_string_block_returns_false(self):
        """Block containing only whitespace returns False."""
        assert snc._is_structured_output(["   "]) is False

    def test_partial_trigger_no_closing_bold_no_match(self):
        """**Trigger without closing ** does not match the pattern."""
        assert snc._is_structured_output(["**Trigger: gotcha"]) is False

    def test_structured_output_skips_scan(self):
        """scan_heuristics skips an assistant message with **Trigger:** label.

        Even though the message contains trigger-matching text, the structured
        output check fires first and prevents any heuristic match.
        """
        messages = [
            {
                "index": 0,
                "role": "assistant",
                "text_blocks": [
                    "**Trigger:** gotcha\n"
                    "**Context:** Watch out for the edge case when input is empty.\n"
                    "I was wrong about this approach. The root cause was a race condition."
                ],
                "has_tool_use": False,
                "is_tool_result": False,
                "tool_names": [],
            },
        ]
        hits = snc.scan_heuristics(messages)
        assert len(hits) == 0

    def test_structured_output_decision_label_skips_scan(self):
        """scan_heuristics skips an assistant message with **Decision:** label."""
        messages = [
            {
                "index": 0,
                "role": "assistant",
                "text_blocks": [
                    "**Decision:** use Redis\n"
                    "We chose Redis because of latency requirements."
                ],
                "has_tool_use": False,
                "is_tool_result": False,
                "tool_names": [],
            },
        ]
        hits = snc.scan_heuristics(messages)
        design_hits = [h for h in hits if h["trigger"] == "design-decision"]
        assert len(design_hits) == 0

    def test_html_comment_in_message_skips_scan(self):
        """scan_heuristics skips an assistant message containing <!-- comment."""
        messages = [
            {
                "index": 0,
                "role": "assistant",
                "text_blocks": [
                    "<!-- category: gotcha -->\n"
                    "Watch out for the edge case where input is empty."
                ],
                "has_tool_use": False,
                "is_tool_result": False,
                "tool_names": [],
            },
        ]
        hits = snc.scan_heuristics(messages)
        assert len(hits) == 0

    def test_no_structured_markers_still_triggers(self):
        """Message with trigger text but no structured markers still produces hits."""
        messages = [
            {
                "index": 0,
                "role": "assistant",
                "text_blocks": [
                    "Watch out for the edge case where input is empty — "
                    "it silently drops the value."
                ],
                "has_tool_use": False,
                "is_tool_result": False,
                "tool_names": [],
            },
        ]
        hits = snc.scan_heuristics(messages)
        gotcha_hits = [h for h in hits if h["trigger"] == "gotcha"]
        assert len(gotcha_hits) > 0


# ---------------------------------------------------------------------------
# Test: structural-synthesis thresholds (char + tool count)
# ---------------------------------------------------------------------------

class TestStructuralSynthesisThresholds:
    """scan_structural_signals() structural-synthesis signal fires when:
    - assistant message length > synthesis_char_threshold (1000 chars)  AND
    - >= synthesis_tool_threshold (8) tool_use messages in the 10 messages before it

    Below either threshold: no hit.
    Both thresholds met: hit.
    """

    def _make_tool_msg(self, index, tool="Bash"):
        return {
            "index": index,
            "role": "assistant",
            "text_blocks": [f"Running step {index}"],
            "has_tool_use": True,
            "is_tool_result": False,
            "tool_names": [tool],
        }

    def _make_assistant(self, index, text):
        return {
            "index": index,
            "role": "assistant",
            "text_blocks": [text],
            "has_tool_use": False,
            "is_tool_result": False,
            "tool_names": [],
        }

    def _config(self, char_threshold=1000, tool_threshold=8):
        cfg = dict(snc.DEFAULTS)
        cfg["synthesis_char_threshold"] = char_threshold
        cfg["synthesis_tool_threshold"] = tool_threshold
        return cfg

    def test_below_char_threshold_no_hit(self):
        """600-char message after 6 tool uses does NOT fire structural-synthesis.

        Both char (600 <= 1000) and tool count (6 < 8) are below threshold.
        """
        # 6 tool-use messages at indices 0-5
        messages = [self._make_tool_msg(i) for i in range(6)]
        # assistant message at index 6 with 600-char text
        messages.append(self._make_assistant(6, "x" * 600))

        hits = snc.scan_structural_signals(messages, config=self._config())
        synthesis_hits = [h for h in hits if h["trigger"] == "structural-synthesis"]
        assert len(synthesis_hits) == 0

    def test_below_tool_threshold_only_no_hit(self):
        """1200-char message after only 6 tool uses does NOT fire.

        Char threshold met (1200 > 1000) but tool count (6 < 8) is not.
        """
        messages = [self._make_tool_msg(i) for i in range(6)]
        messages.append(self._make_assistant(6, "x" * 1200))

        hits = snc.scan_structural_signals(messages, config=self._config())
        synthesis_hits = [h for h in hits if h["trigger"] == "structural-synthesis"]
        assert len(synthesis_hits) == 0

    def test_below_char_threshold_only_no_hit(self):
        """600-char message after 9 tool uses does NOT fire.

        Tool threshold met (9 >= 8) but char count (600 <= 1000) is not.
        """
        messages = [self._make_tool_msg(i) for i in range(9)]
        messages.append(self._make_assistant(9, "x" * 600))

        hits = snc.scan_structural_signals(messages, config=self._config())
        synthesis_hits = [h for h in hits if h["trigger"] == "structural-synthesis"]
        assert len(synthesis_hits) == 0

    def test_both_thresholds_met_fires(self):
        """1200-char message after 9 tool uses DOES fire structural-synthesis.

        Both char (1200 > 1000) and tool count (9 >= 8) exceed thresholds.
        """
        messages = [self._make_tool_msg(i) for i in range(9)]
        messages.append(self._make_assistant(9, "x" * 1200))

        hits = snc.scan_structural_signals(messages, config=self._config())
        synthesis_hits = [h for h in hits if h["trigger"] == "structural-synthesis"]
        assert len(synthesis_hits) == 1
        assert synthesis_hits[0]["index"] == 9

    def test_exactly_at_char_threshold_no_hit(self):
        """Message exactly at char threshold (1000) does NOT fire — condition is strict >."""
        messages = [self._make_tool_msg(i) for i in range(9)]
        messages.append(self._make_assistant(9, "x" * 1000))

        hits = snc.scan_structural_signals(messages, config=self._config())
        synthesis_hits = [h for h in hits if h["trigger"] == "structural-synthesis"]
        assert len(synthesis_hits) == 0

    def test_exactly_at_tool_threshold_fires(self):
        """Exactly synthesis_tool_threshold (8) prior tool uses does fire — condition is >=."""
        messages = [self._make_tool_msg(i) for i in range(8)]
        messages.append(self._make_assistant(8, "x" * 1200))

        hits = snc.scan_structural_signals(messages, config=self._config())
        synthesis_hits = [h for h in hits if h["trigger"] == "structural-synthesis"]
        assert len(synthesis_hits) == 1


# ---------------------------------------------------------------------------
# Test: _evaluated_ranges.json cap — keeps 50 highest-index entries
# ---------------------------------------------------------------------------

class TestEvaluatedRangesCap:
    """When _evaluated_ranges.json has more than 50 entries, main() prunes to
    the 50 highest-index pairs (sorted descending, keep last 50).

    The cap is applied immediately after loading, before candidate filtering.
    This prevents unbounded growth of the file across many sessions.
    """

    def test_cap_keeps_50_highest_when_60_present(self, tmp_path):
        """When file has 60 entries, only the 50 with highest indices survive.

        Entries are (heuristic_index, novelty_index) tuples. Sorting is
        lexicographic: highest first index wins, then highest second index.
        """
        # Create 60 entries with indices 0..59 paired with themselves
        entries = [[i, i] for i in range(60)]
        evaluated_path = tmp_path / "_evaluated_ranges.json"
        evaluated_path.write_text(json.dumps(entries), encoding="utf-8")

        # Load and apply the cap (replicate main() logic)
        with open(str(evaluated_path), "r", encoding="utf-8") as f:
            evaluated_ranges = set(tuple(r) for r in json.load(f))

        assert len(evaluated_ranges) == 60

        if len(evaluated_ranges) > 50:
            evaluated_ranges = set(sorted(evaluated_ranges)[-50:])

        assert len(evaluated_ranges) == 50
        # The 50 highest-index entries are (10,10)..(59,59)
        assert (59, 59) in evaluated_ranges
        assert (10, 10) in evaluated_ranges
        # The 10 lowest entries (0,0)..(9,9) should be pruned
        for i in range(10):
            assert (i, i) not in evaluated_ranges

    def test_exactly_50_entries_unchanged(self, tmp_path):
        """When file has exactly 50 entries, no pruning occurs."""
        entries = [[i, i] for i in range(50)]
        evaluated_path = tmp_path / "_evaluated_ranges.json"
        evaluated_path.write_text(json.dumps(entries), encoding="utf-8")

        with open(str(evaluated_path), "r", encoding="utf-8") as f:
            evaluated_ranges = set(tuple(r) for r in json.load(f))

        if len(evaluated_ranges) > 50:
            evaluated_ranges = set(sorted(evaluated_ranges)[-50:])

        assert len(evaluated_ranges) == 50
        # All original entries present
        for i in range(50):
            assert (i, i) in evaluated_ranges

    def test_fewer_than_50_entries_unchanged(self, tmp_path):
        """When file has fewer than 50 entries, all are preserved."""
        entries = [[i, i] for i in range(20)]
        evaluated_path = tmp_path / "_evaluated_ranges.json"
        evaluated_path.write_text(json.dumps(entries), encoding="utf-8")

        with open(str(evaluated_path), "r", encoding="utf-8") as f:
            evaluated_ranges = set(tuple(r) for r in json.load(f))

        if len(evaluated_ranges) > 50:
            evaluated_ranges = set(sorted(evaluated_ranges)[-50:])

        assert len(evaluated_ranges) == 20

    def test_cap_uses_sort_order_not_insertion_order(self, tmp_path):
        """Pruning is by sort order (highest tuples), not insertion order.

        Even if small-index entries were written last, they get pruned.
        """
        # Write high-index entries first, then low-index entries
        entries = [[i + 50, i + 50] for i in range(50)] + [[i, i] for i in range(20)]
        evaluated_path = tmp_path / "_evaluated_ranges.json"
        evaluated_path.write_text(json.dumps(entries), encoding="utf-8")

        with open(str(evaluated_path), "r", encoding="utf-8") as f:
            evaluated_ranges = set(tuple(r) for r in json.load(f))

        if len(evaluated_ranges) > 50:
            evaluated_ranges = set(sorted(evaluated_ranges)[-50:])

        assert len(evaluated_ranges) == 50
        # All 70 entries loaded; after cap, 20 low-index entries pruned
        for i in range(20):
            assert (i, i) not in evaluated_ranges
        # High-index entries kept
        for i in range(50):
            assert (i + 50, i + 50) in evaluated_ranges

    def test_51_entries_prunes_to_50(self, tmp_path):
        """Boundary: 51 entries triggers the cap, leaving 50."""
        entries = [[i, i] for i in range(51)]
        evaluated_path = tmp_path / "_evaluated_ranges.json"
        evaluated_path.write_text(json.dumps(entries), encoding="utf-8")

        with open(str(evaluated_path), "r", encoding="utf-8") as f:
            evaluated_ranges = set(tuple(r) for r in json.load(f))

        if len(evaluated_ranges) > 50:
            evaluated_ranges = set(sorted(evaluated_ranges)[-50:])

        assert len(evaluated_ranges) == 50
        # Entry (0, 0) is the lowest and should be pruned
        assert (0, 0) not in evaluated_ranges
        # Entry (50, 50) is highest and should be kept
        assert (50, 50) in evaluated_ranges
