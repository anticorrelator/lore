#!/usr/bin/env python3
"""test_grounding_preflight.py — unit tests for scripts/grounding-preflight.py.

Covers:
    - Silence envelope passes with reason="silence"
    - Happy path: file exists, line_range in bounds, exact snippet match
    - Happy path: normalized-snippet match (different whitespace)
    - field-missing: each required field individually
    - field-missing: why_it_matters with both key spellings
    - field-missing: malformed line_range
    - file-missing: file does not exist
    - line-out-of-range: start < 1
    - line-out-of-range: end > file bounds
    - snippet-mismatch: content differs after normalization
    - snippet-mismatch: normalized matches but claim hash is stale
    - Absolute vs relative file paths both resolve
    - The preflight is fast (<10 ms per claim)

Run: python3 tests/test_grounding_preflight.py
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPT = REPO_ROOT / "scripts" / "grounding-preflight.py"


def normalize_hash(s: str) -> str:
    s = s.replace("‘", "'").replace("’", "'")
    s = s.replace("“", '"').replace("”", '"')
    s = re.sub(r"\s+", " ", s).strip()
    return hashlib.sha256(s.encode("utf-8")).hexdigest()


def run_preflight(payload: dict, repo_root: str | None = None) -> tuple[int, dict]:
    if repo_root is None:
        repo_root = str(REPO_ROOT)
    result = subprocess.run(
        [sys.executable, str(SCRIPT), "--repo-root", repo_root],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        timeout=10,
    )
    if result.returncode != 0 and not result.stdout:
        return result.returncode, {"_stderr": result.stderr}
    return result.returncode, json.loads(result.stdout)


class TestGroundingPreflight(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Write a stable fixture file under a temp dir so tests don't depend
        # on the repo's mutable content line-for-line.
        cls.tmp = tempfile.mkdtemp(prefix="preflight-test-")
        cls.fixture_path = os.path.join(cls.tmp, "fixture.txt")
        with open(cls.fixture_path, "w", encoding="utf-8") as f:
            # 5 lines; 1-indexed slicing target: lines 2-3.
            f.write(
                "line one\n"
                "line two\n"
                "line three\n"
                "line four\n"
                "line five\n"
            )
        cls.repo_root = cls.tmp

    @classmethod
    def tearDownClass(cls):
        import shutil

        shutil.rmtree(cls.tmp, ignore_errors=True)

    # --- Silence ---
    def test_silence_passes(self):
        rc, result = run_preflight({"omission_claim": None})
        self.assertEqual(rc, 0)
        self.assertTrue(result["pass"])
        self.assertEqual(result["reason"], "silence")

    def test_no_omission_verdict_passes(self):
        rc, result = run_preflight({"verdict": "no-omission", "omission_claim": None})
        self.assertEqual(rc, 0)
        self.assertTrue(result["pass"])
        self.assertEqual(result["reason"], "silence")

    # --- Happy path: exact + normalized ---
    def test_happy_path_exact_match(self):
        payload = {
            "omission_claim": {
                "file": "fixture.txt",
                "line_range": "2-3",
                "exact_snippet": "line two\nline three",
                "falsifier": "would disprove X",
                "why_it_matters": "matters because Y",
            },
        }
        rc, result = run_preflight(payload, self.repo_root)
        self.assertEqual(rc, 0)
        self.assertTrue(result["pass"])
        self.assertEqual(result["reason"], "ok")

    def test_happy_path_normalized_match(self):
        # Mismatched whitespace: tabs, doubled spaces. Normalization collapses.
        payload = {
            "omission_claim": {
                "file": "fixture.txt",
                "line_range": "2-3",
                "exact_snippet": "line   two\tline three",
                "falsifier": "x",
                "why_it_matters": "y",
            },
        }
        rc, result = run_preflight(payload, self.repo_root)
        self.assertEqual(rc, 0, msg=f"got: {result}")
        self.assertTrue(result["pass"])
        self.assertEqual(result["reason"], "ok")
        self.assertIn("normalized", result["detail"])

    def test_happy_path_with_why_it_matters_hyphen(self):
        # Alternate spelling from plan wording.
        payload = {
            "omission_claim": {
                "file": "fixture.txt",
                "line_range": "1-1",
                "exact_snippet": "line one",
                "falsifier": "x",
                "why-it-matters": "y",
            },
        }
        rc, result = run_preflight(payload, self.repo_root)
        self.assertEqual(rc, 0, msg=f"got: {result}")
        self.assertTrue(result["pass"])

    # --- field-missing ---
    def test_field_missing_file(self):
        payload = {
            "omission_claim": {
                "line_range": "1-1",
                "exact_snippet": "x",
                "falsifier": "x",
                "why_it_matters": "y",
            },
        }
        rc, result = run_preflight(payload, self.repo_root)
        self.assertEqual(rc, 0)
        self.assertFalse(result["pass"])
        self.assertEqual(result["reason"], "field-missing")
        self.assertIn("file", result["detail"])

    def test_field_missing_line_range(self):
        payload = {
            "omission_claim": {
                "file": "fixture.txt",
                "exact_snippet": "x",
                "falsifier": "x",
                "why_it_matters": "y",
            },
        }
        rc, result = run_preflight(payload, self.repo_root)
        self.assertFalse(result["pass"])
        self.assertEqual(result["reason"], "field-missing")
        self.assertIn("line_range", result["detail"])

    def test_field_missing_exact_snippet(self):
        payload = {
            "omission_claim": {
                "file": "fixture.txt",
                "line_range": "1-1",
                "falsifier": "x",
                "why_it_matters": "y",
            },
        }
        rc, result = run_preflight(payload, self.repo_root)
        self.assertFalse(result["pass"])
        self.assertEqual(result["reason"], "field-missing")

    def test_field_missing_falsifier(self):
        payload = {
            "omission_claim": {
                "file": "fixture.txt",
                "line_range": "1-1",
                "exact_snippet": "line one",
                "why_it_matters": "y",
            },
        }
        rc, result = run_preflight(payload, self.repo_root)
        self.assertFalse(result["pass"])
        self.assertEqual(result["reason"], "field-missing")
        self.assertIn("falsifier", result["detail"])

    def test_field_missing_why_it_matters(self):
        payload = {
            "omission_claim": {
                "file": "fixture.txt",
                "line_range": "1-1",
                "exact_snippet": "line one",
                "falsifier": "x",
            },
        }
        rc, result = run_preflight(payload, self.repo_root)
        self.assertFalse(result["pass"])
        self.assertEqual(result["reason"], "field-missing")
        self.assertIn("why_it_matters", result["detail"])

    def test_empty_falsifier_is_missing(self):
        payload = {
            "omission_claim": {
                "file": "fixture.txt",
                "line_range": "1-1",
                "exact_snippet": "line one",
                "falsifier": "",
                "why_it_matters": "y",
            },
        }
        rc, result = run_preflight(payload, self.repo_root)
        self.assertFalse(result["pass"])
        self.assertEqual(result["reason"], "field-missing")

    def test_malformed_line_range(self):
        payload = {
            "omission_claim": {
                "file": "fixture.txt",
                "line_range": "not-a-range",
                "exact_snippet": "x",
                "falsifier": "x",
                "why_it_matters": "y",
            },
        }
        rc, result = run_preflight(payload, self.repo_root)
        self.assertFalse(result["pass"])
        self.assertEqual(result["reason"], "field-missing")
        self.assertIn("line_range", result["detail"])

    def test_reversed_line_range(self):
        # start > end is invalid.
        payload = {
            "omission_claim": {
                "file": "fixture.txt",
                "line_range": "5-2",
                "exact_snippet": "x",
                "falsifier": "x",
                "why_it_matters": "y",
            },
        }
        rc, result = run_preflight(payload, self.repo_root)
        self.assertFalse(result["pass"])
        self.assertEqual(result["reason"], "field-missing")

    # --- file-missing ---
    def test_file_missing(self):
        payload = {
            "omission_claim": {
                "file": "does-not-exist.txt",
                "line_range": "1-1",
                "exact_snippet": "x",
                "falsifier": "x",
                "why_it_matters": "y",
            },
        }
        rc, result = run_preflight(payload, self.repo_root)
        self.assertFalse(result["pass"])
        self.assertEqual(result["reason"], "file-missing")

    # --- line-out-of-range ---
    def test_line_out_of_range_start_zero(self):
        # Parser rejects start=0 as malformed line_range (field-missing,
        # not line-out-of-range — the regex requires start >= 1).
        payload = {
            "omission_claim": {
                "file": "fixture.txt",
                "line_range": "0-1",
                "exact_snippet": "x",
                "falsifier": "x",
                "why_it_matters": "y",
            },
        }
        rc, result = run_preflight(payload, self.repo_root)
        self.assertFalse(result["pass"])
        self.assertEqual(result["reason"], "field-missing")

    def test_line_out_of_range_end_past_eof(self):
        payload = {
            "omission_claim": {
                "file": "fixture.txt",
                "line_range": "3-100",
                "exact_snippet": "x",
                "falsifier": "x",
                "why_it_matters": "y",
            },
        }
        rc, result = run_preflight(payload, self.repo_root)
        self.assertFalse(result["pass"])
        self.assertEqual(result["reason"], "line-out-of-range")

    # --- snippet-mismatch ---
    def test_snippet_mismatch_content(self):
        payload = {
            "omission_claim": {
                "file": "fixture.txt",
                "line_range": "2-3",
                "exact_snippet": "totally different content",
                "falsifier": "x",
                "why_it_matters": "y",
            },
        }
        rc, result = run_preflight(payload, self.repo_root)
        self.assertFalse(result["pass"])
        self.assertEqual(result["reason"], "snippet-mismatch")

    def test_snippet_mismatch_stale_hash(self):
        # Claim's normalized_snippet_hash is stale but content matches file
        # after normalization. Per fail-closed rule, this is a mismatch.
        payload = {
            "omission_claim": {
                "file": "fixture.txt",
                "line_range": "2-3",
                "exact_snippet": "line two\nline three",
                "normalized_snippet_hash": "0" * 64,
                "falsifier": "x",
                "why_it_matters": "y",
            },
        }
        rc, result = run_preflight(payload, self.repo_root)
        # Exact match wins before hash check; hash is only checked in the
        # normalized-match branch. Feed a whitespace-variant snippet to land
        # in the normalized branch.
        payload["omission_claim"]["exact_snippet"] = "line   two\tline three"
        rc, result = run_preflight(payload, self.repo_root)
        self.assertFalse(result["pass"])
        self.assertEqual(result["reason"], "snippet-mismatch")
        self.assertIn("hash", result["detail"])

    def test_valid_hash_passes_normalized(self):
        claim_snippet = "line   two\tline three"
        valid_hash = normalize_hash(claim_snippet)
        payload = {
            "omission_claim": {
                "file": "fixture.txt",
                "line_range": "2-3",
                "exact_snippet": claim_snippet,
                "normalized_snippet_hash": valid_hash,
                "falsifier": "x",
                "why_it_matters": "y",
            },
        }
        rc, result = run_preflight(payload, self.repo_root)
        self.assertEqual(rc, 0)
        self.assertTrue(result["pass"])

    # --- path resolution ---
    def test_absolute_path_works(self):
        payload = {
            "omission_claim": {
                "file": self.fixture_path,
                "line_range": "1-1",
                "exact_snippet": "line one",
                "falsifier": "x",
                "why_it_matters": "y",
            },
        }
        # Use a different repo_root to prove the absolute path is used directly.
        rc, result = run_preflight(payload, "/tmp")
        self.assertTrue(result["pass"])

    # --- input error paths ---
    def test_empty_stdin_exits_1(self):
        result = subprocess.run(
            [sys.executable, str(SCRIPT)],
            input="",
            capture_output=True,
            text=True,
            timeout=5,
        )
        self.assertEqual(result.returncode, 1)

    def test_malformed_json_exits_1(self):
        result = subprocess.run(
            [sys.executable, str(SCRIPT)],
            input="not json",
            capture_output=True,
            text=True,
            timeout=5,
        )
        self.assertEqual(result.returncode, 1)

    def test_non_object_input_exits_1(self):
        result = subprocess.run(
            [sys.executable, str(SCRIPT)],
            input='"string-not-object"',
            capture_output=True,
            text=True,
            timeout=5,
        )
        self.assertEqual(result.returncode, 1)

    # --- performance sanity ---
    def test_preflight_is_fast(self):
        payload = {
            "omission_claim": {
                "file": "fixture.txt",
                "line_range": "2-3",
                "exact_snippet": "line two\nline three",
                "falsifier": "x",
                "why_it_matters": "y",
            },
        }
        # In-process validation for a meaningful timing measurement —
        # subprocess cold-start dominates wall time for a single call.
        sys.path.insert(0, str(REPO_ROOT / "scripts"))
        import importlib.util

        spec = importlib.util.spec_from_file_location(
            "grounding_preflight", str(SCRIPT)
        )
        gp = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gp)

        claim = payload["omission_claim"]
        start = time.perf_counter()
        for _ in range(100):
            gp.validate_claim(claim, self.repo_root)
        elapsed = (time.perf_counter() - start) / 100
        # Well under the 10 ms / claim budget from the plan. Allow 5 ms as
        # a CI-safe ceiling that is still 2x under budget.
        self.assertLess(elapsed, 0.005, f"preflight averaged {elapsed*1000:.2f} ms/claim (budget: 10 ms)")


if __name__ == "__main__":
    unittest.main(verbosity=2)
