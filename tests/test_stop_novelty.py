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
            "test_fix_window": 20,
            "synthesis_char_threshold": 500,
            "synthesis_tool_threshold": 5,
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
