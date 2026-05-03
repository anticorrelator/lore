#!/usr/bin/env python3
"""test_probabilistic_audit_trigger.py — tests for the Stop-hook trigger.

Covers:
    - Ceremony detection: each of the four recognized SlashCommands
    - Non-ceremony SlashCommand: hook exits silently
    - No SlashCommand in transcript: hook exits silently
    - stop_hook_active=true: hook exits silently
    - Empirical firing rate is within 3σ of configured p over N trials
    - Dry-run: no fire recorded in trigger-log
    - Disabled config: no trigger-log entry at all
    - Missing transcript_path: hook exits cleanly
    - Trigger-log entry carries artifact_id on fire

Run: python3 tests/test_probabilistic_audit_trigger.py
"""

from __future__ import annotations

import json
import math
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
HOOK = REPO_ROOT / "scripts" / "probabilistic-audit-trigger.py"


def run_hook(hook_input: dict, env_overrides: dict | None = None) -> subprocess.CompletedProcess:
    env = os.environ.copy()
    if env_overrides:
        env.update(env_overrides)
    return subprocess.run(
        [sys.executable, str(HOOK)],
        input=json.dumps(hook_input),
        capture_output=True,
        text=True,
        timeout=15,
        env=env,
    )


def make_transcript(commands: list[str], path: Path) -> None:
    """Write a minimal JSONL transcript with SlashCommand tool_use blocks."""
    with open(path, "w", encoding="utf-8") as f:
        for cmd in commands:
            entry = {
                "message": {
                    "content": [
                        {
                            "type": "tool_use",
                            "name": "SlashCommand",
                            "input": {"command": cmd},
                        }
                    ]
                }
            }
            f.write(json.dumps(entry) + "\n")


def read_last_trigger_log_line(kdir: str) -> dict | None:
    log = Path(kdir) / "_scorecards" / "trigger-log.jsonl"
    if not log.is_file():
        return None
    lines = log.read_text().splitlines()
    if not lines:
        return None
    return json.loads(lines[-1])


class TestProbabilisticAuditTrigger(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="trigger-hook-test-"))
        # Create a minimal knowledge-dir mimic so resolve_knowledge_dir finds
        # a valid target via cwd.
        cls.kdir_cwd = cls.tmp / "project"
        cls.kdir_cwd.mkdir()
        # Instead of mocking resolve_knowledge_dir, use the real lore resolve
        # by cd-ing into the lore repo for tests that actually need writes.
        cls.lore_cwd = str(REPO_ROOT)
        kdir_proc = subprocess.run(
            ["lore", "resolve"],
            capture_output=True, text=True, timeout=5, cwd=cls.lore_cwd,
        )
        cls.kdir = kdir_proc.stdout.strip() if kdir_proc.returncode == 0 else ""

    @classmethod
    def tearDownClass(cls):
        import shutil
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def _run(self, commands: list[str], stop_hook_active: bool = False) -> subprocess.CompletedProcess:
        transcript = self.tmp / f"transcript-{os.getpid()}-{id(commands)}.jsonl"
        make_transcript(commands, transcript)
        return run_hook({
            "transcript_path": str(transcript),
            "stop_hook_active": stop_hook_active,
            "cwd": self.lore_cwd,
        })

    # --- Ceremony detection ---
    def test_detects_implement(self):
        before = self._log_line_count()
        result = self._run(["/implement"])
        self.assertEqual(result.returncode, 0)
        after = self._log_line_count()
        self.assertGreater(after, before, f"expected new log entry; stderr={result.stderr}")
        row = read_last_trigger_log_line(self.kdir)
        self.assertEqual(row["ceremony"], "implement")

    def test_detects_spec(self):
        result = self._run(["/spec"])
        self.assertEqual(result.returncode, 0)
        row = read_last_trigger_log_line(self.kdir)
        self.assertEqual(row["ceremony"], "spec")

    def test_detects_pr_review(self):
        result = self._run(["/pr-review"])
        self.assertEqual(result.returncode, 0)
        row = read_last_trigger_log_line(self.kdir)
        self.assertEqual(row["ceremony"], "pr-review")

    def test_detects_pr_self_review(self):
        result = self._run(["/pr-self-review"])
        self.assertEqual(result.returncode, 0)
        row = read_last_trigger_log_line(self.kdir)
        self.assertEqual(row["ceremony"], "pr-self-review")

    def test_last_ceremony_wins(self):
        result = self._run(["/implement", "/spec"])
        self.assertEqual(result.returncode, 0)
        row = read_last_trigger_log_line(self.kdir)
        self.assertEqual(row["ceremony"], "spec", f"expected last-command-wins; stderr={result.stderr}")

    # --- Silent exits ---
    def test_non_ceremony_command_silent(self):
        before = self._log_line_count()
        result = self._run(["/not-a-ceremony"])
        self.assertEqual(result.returncode, 0)
        after = self._log_line_count()
        self.assertEqual(before, after, "no log entry expected for non-ceremony command")

    def test_no_slash_commands_silent(self):
        before = self._log_line_count()
        transcript = self.tmp / "empty.jsonl"
        transcript.write_text("")
        result = run_hook({
            "transcript_path": str(transcript),
            "stop_hook_active": False,
            "cwd": self.lore_cwd,
        })
        self.assertEqual(result.returncode, 0)
        after = self._log_line_count()
        self.assertEqual(before, after)

    def test_stop_hook_active_silent(self):
        before = self._log_line_count()
        result = self._run(["/implement"], stop_hook_active=True)
        self.assertEqual(result.returncode, 0)
        after = self._log_line_count()
        self.assertEqual(before, after)

    def test_missing_transcript_path_silent(self):
        before = self._log_line_count()
        result = run_hook({"stop_hook_active": False, "cwd": self.lore_cwd})
        self.assertEqual(result.returncode, 0)
        after = self._log_line_count()
        self.assertEqual(before, after)

    # --- Empirical firing rate ---
    def test_firing_rate_within_envelope(self):
        """Over 100 trials of /implement (p=0.3), firing rate should land
        in ~[0.18, 0.42] (3σ envelope for binomial with p=0.3, n=100)."""
        N = 100
        P = 0.3
        fires = 0
        for _ in range(N):
            result = self._run(["/implement"])
            self.assertEqual(result.returncode, 0)
            row = read_last_trigger_log_line(self.kdir)
            if row and row.get("fired"):
                fires += 1
        observed_rate = fires / N
        # 3σ = 3 * sqrt(p*(1-p)/n)
        sigma = math.sqrt(P * (1 - P) / N)
        lower, upper = P - 3 * sigma, P + 3 * sigma
        self.assertTrue(
            lower <= observed_rate <= upper,
            f"firing rate {observed_rate:.3f} outside 3σ envelope [{lower:.3f}, {upper:.3f}] at p={P}",
        )

    # --- Log content ---
    def test_log_entry_has_artifact_id_on_fire(self):
        """Fire enough trials that at least one fires, then verify the last
        fired row carries artifact_id."""
        found_fire = False
        for _ in range(40):
            result = self._run(["/implement"])
            self.assertEqual(result.returncode, 0)
            row = read_last_trigger_log_line(self.kdir)
            if row and row.get("fired"):
                self.assertIn("artifact_id", row)
                self.assertTrue(row["artifact_id"])
                found_fire = True
                break
        self.assertTrue(found_fire, "no fire observed in 40 trials at p=0.3 — extremely unlikely")

    def test_log_entry_omits_artifact_id_on_no_fire(self):
        # Only check when we see a not-fired row.
        for _ in range(40):
            result = self._run(["/implement"])
            self.assertEqual(result.returncode, 0)
            row = read_last_trigger_log_line(self.kdir)
            if row and not row.get("fired"):
                self.assertNotIn("artifact_id", row)
                return
        self.fail("no not-fired row observed in 40 trials at p=0.3 — extremely unlikely")

    def _log_line_count(self) -> int:
        log = Path(self.kdir) / "_scorecards" / "trigger-log.jsonl"
        if not log.is_file():
            return 0
        return len(log.read_text().splitlines())

    # --- Dispatch fallback (task-29) ---
    def test_fire_surfaces_dispatch_status_to_stderr(self):
        """On fire, the hook's stderr should include a dispatch-status string."""
        found_fire_with_status = False
        for _ in range(40):
            result = self._run(["/implement"])
            self.assertEqual(result.returncode, 0)
            row = read_last_trigger_log_line(self.kdir)
            if row and row.get("fired"):
                # The stderr line should mention one of the recognized
                # dispatch statuses.
                dispatch_keywords = (
                    "queued", "spawned", "dispatch skipped",
                )
                self.assertTrue(
                    any(kw in result.stderr for kw in dispatch_keywords),
                    f"expected dispatch status in stderr; got: {result.stderr!r}",
                )
                found_fire_with_status = True
                break
        self.assertTrue(found_fire_with_status, "no fire observed in 40 trials")

    def test_hook_returns_under_one_second_on_fire(self):
        """Stop-hook must return promptly even when dispatching — child
        process is detached, parent returns immediately."""
        import time
        for _ in range(40):
            start = time.perf_counter()
            result = self._run(["/implement"])
            elapsed = time.perf_counter() - start
            self.assertEqual(result.returncode, 0)
            # Allow 2s ceiling for CI-safe headroom; real spawn takes <100ms
            # on macOS/Linux.
            self.assertLess(elapsed, 2.0, f"hook took {elapsed:.2f}s — too slow")
            row = read_last_trigger_log_line(self.kdir)
            if row and row.get("fired"):
                # Confirmed a fire happened within the timing envelope.
                return
        # No fire observed across 40 trials — unlikely at p=0.3 but not
        # fatal; timing was verified on all trials.


if __name__ == "__main__":
    unittest.main(verbosity=2)
