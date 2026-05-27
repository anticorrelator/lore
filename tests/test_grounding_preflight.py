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


def run_preflight(
    payload: dict,
    repo_root: str | None = None,
    cascade: bool = False,
) -> tuple[int, dict]:
    """Run the preflight CLI. Defaults to --no-cascade to exercise the legacy
    on-disk path; tests that target the cwd cascade pass `cascade=True`."""
    if repo_root is None:
        repo_root = str(REPO_ROOT)
    argv = [sys.executable, str(SCRIPT), "--repo-root", repo_root]
    if not cascade:
        argv.append("--no-cascade")
    result = subprocess.run(
        argv,
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


def _git(args: list[str], cwd: str, env: dict | None = None) -> subprocess.CompletedProcess:
    full_env = os.environ.copy()
    # Quiet, deterministic git invocations in tests.
    full_env.update({
        "GIT_AUTHOR_NAME": "test",
        "GIT_AUTHOR_EMAIL": "test@example.com",
        "GIT_COMMITTER_NAME": "test",
        "GIT_COMMITTER_EMAIL": "test@example.com",
    })
    if env:
        full_env.update(env)
    return subprocess.run(
        ["git", *args], cwd=cwd, capture_output=True, text=True, env=full_env, check=True
    )


def _git_show_returncode(args: list[str], cwd: str) -> int:
    return subprocess.run(
        ["git", *args], cwd=cwd, capture_output=True, text=False, check=False
    ).returncode


class TestCwdCascade(unittest.TestCase):
    """End-to-end cascade tests using a tmpdir git repo as the cwd repo.

    Layout per test:
        upstream/   bare repo serving as "origin"
        cwd/        clone of upstream; this is repo_root passed to preflight.
                    Commits made here can simulate captured_at_sha; commits
                    fetched from upstream simulate origin/main; commits NOT
                    pushed/fetched simulate the unpushed_local_only anchor.
    """

    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.mkdtemp(prefix="preflight-cascade-")

    @classmethod
    def tearDownClass(cls):
        import shutil
        shutil.rmtree(cls._tmp, ignore_errors=True)

    def setUp(self):
        # Per-test repo so each test sees a clean cascade state.
        import shutil, uuid
        self.repo_dir = os.path.join(self._tmp, f"repo-{uuid.uuid4().hex[:8]}")
        self.upstream = os.path.join(self.repo_dir, "upstream.git")
        self.cwd = os.path.join(self.repo_dir, "cwd")
        os.makedirs(self.repo_dir)
        # Bare upstream
        _git(["init", "--bare", "-b", "main", self.upstream], cwd=self.repo_dir)
        # Working clone
        _git(["clone", self.upstream, self.cwd], cwd=self.repo_dir)

    def _commit(self, path_rel: str, content: str, message: str) -> str:
        """Write a file, commit it, and return the resulting HEAD sha."""
        full = os.path.join(self.cwd, path_rel)
        os.makedirs(os.path.dirname(full) or self.cwd, exist_ok=True)
        with open(full, "w", encoding="utf-8") as f:
            f.write(content)
        _git(["add", path_rel], cwd=self.cwd)
        _git(["commit", "-m", message], cwd=self.cwd)
        sha = _git(["rev-parse", "HEAD"], cwd=self.cwd).stdout.strip()
        return sha

    def _push(self):
        _git(["push", "origin", "main"], cwd=self.cwd)
        _git(["fetch", "origin"], cwd=self.cwd)

    def _claim(self, **overrides) -> dict:
        base = {
            "file": "fixture.txt",
            "file_relative": "fixture.txt",
            "line_range": "2-3",
            "exact_snippet": "line two\nline three",
            "falsifier": "x",
            "why_it_matters": "y",
        }
        base.update(overrides)
        return base

    # --- Step 1: captured_at_sha resolves ---
    def test_ok_via_step1_captured_at_sha(self):
        sha = self._commit(
            "fixture.txt",
            "line one\nline two\nline three\nline four\nline five\n",
            "init fixture",
        )
        self._push()
        # Then add a drifted commit so origin/main no longer has the same shape
        # — but captured_at_sha should still reach the original blob.
        self._commit("other.txt", "noise\n", "noise commit")
        self._push()

        claim = self._claim(captured_at_sha=sha, captured_origin_ref="origin/main")
        rc, result = run_preflight({"omission_claim": claim}, self.cwd, cascade=True)
        self.assertEqual(rc, 0, msg=f"got: {result}")
        self.assertTrue(result["pass"], msg=f"got: {result}")
        self.assertEqual(result["reason"], "ok")
        self.assertIn(sha[:7], result["detail"])

    # --- Step 2: captured_at_sha unreachable, captured_origin_ref resolves ---
    def test_ok_via_step2_captured_origin_ref(self):
        self._commit(
            "fixture.txt",
            "line one\nline two\nline three\nline four\nline five\n",
            "init fixture",
        )
        self._push()
        # Use a bogus sha for step 1 so it cannot resolve.
        bogus = "0" * 40
        claim = self._claim(
            captured_at_sha=bogus, captured_origin_ref="origin/main"
        )
        rc, result = run_preflight({"omission_claim": claim}, self.cwd, cascade=True)
        self.assertEqual(rc, 0, msg=f"got: {result}")
        self.assertTrue(result["pass"], msg=f"got: {result}")
        self.assertEqual(result["reason"], "ok")
        self.assertIn("origin/main", result["detail"])

    # --- Step 3: only origin/main fallback resolves ---
    def test_ok_via_step3_origin_main(self):
        self._commit(
            "fixture.txt",
            "line one\nline two\nline three\nline four\nline five\n",
            "init fixture",
        )
        self._push()
        # No captured_at_sha, no captured_origin_ref; cascade reaches step 3.
        claim = self._claim()
        rc, result = run_preflight({"omission_claim": claim}, self.cwd, cascade=True)
        self.assertEqual(rc, 0, msg=f"got: {result}")
        self.assertTrue(result["pass"], msg=f"got: {result}")
        self.assertEqual(result["reason"], "ok")
        self.assertIn("origin/main", result["detail"])

    # --- Step 4: substring at HEAD (line drift but content present) ---
    def test_verified_with_drift_via_step4_head(self):
        # captured anchor: claim is for lines 2-3 = "line two\nline three"
        sha = self._commit(
            "fixture.txt",
            "line one\nline two\nline three\nline four\nline five\n",
            "init fixture",
        )
        self._push()
        # Drift: prepend a header line so the same content is now lines 3-4,
        # not 2-3. Hash compare at lines 2-3 will fail (different content there);
        # substring still finds "line two\nline three" in HEAD.
        self._commit(
            "fixture.txt",
            "HEADER\nline one\nline two\nline three\nline four\nline five\n",
            "drift fixture",
        )
        self._push()

        # captured_at_sha would still match cleanly, so omit it to force
        # the cascade to fail steps 1-3 on origin/main (and the missing-ref
        # captured_origin_ref) — substring at HEAD then catches the snippet.
        claim = self._claim()
        rc, result = run_preflight({"omission_claim": claim}, self.cwd, cascade=True)
        self.assertEqual(rc, 0, msg=f"got: {result}")
        self.assertTrue(result["pass"], msg=f"got: {result}")
        self.assertEqual(result["reason"], "verified-with-drift")
        self.assertIn("HEAD", result["detail"])

    # --- Step 5: substring at origin/main (after HEAD drifts beyond it) ---
    def test_verified_with_drift_via_step5_origin_main(self):
        # Seed origin/main with the original content.
        self._commit(
            "fixture.txt",
            "line one\nline two\nline three\nline four\nline five\n",
            "init fixture",
        )
        self._push()
        # Make a local HEAD that DELETES the snippet (and does not push).
        with open(os.path.join(self.cwd, "fixture.txt"), "w") as f:
            f.write("only one line\n")
        _git(["add", "fixture.txt"], cwd=self.cwd)
        _git(["commit", "-m", "drop snippet from HEAD"], cwd=self.cwd)

        # claim has only a line_range that's now out of bounds in HEAD;
        # without captured_at_sha the cascade falls through to substring,
        # which misses HEAD (snippet was deleted) and hits origin/main.
        claim = self._claim(line_range="100-101")
        rc, result = run_preflight({"omission_claim": claim}, self.cwd, cascade=True)
        self.assertEqual(rc, 0, msg=f"got: {result}")
        self.assertTrue(result["pass"], msg=f"got: {result}")
        self.assertEqual(result["reason"], "verified-with-drift")
        self.assertIn("origin/main", result["detail"])

    # --- snippet-mismatch (blob+range valid, hash diff, no substring) ---
    def test_snippet_mismatch(self):
        # Seed with content the claim's hash will not match.
        self._commit(
            "fixture.txt",
            "alpha\nbravo\ncharlie\ndelta\necho\n",
            "init fixture",
        )
        self._push()
        # Claim's snippet "line two\nline three" is NOT present anywhere,
        # so substring fallback misses too. line_range 2-3 IS valid in the
        # blob → hash compare fails, no substring → snippet-mismatch.
        claim = self._claim()
        rc, result = run_preflight({"omission_claim": claim}, self.cwd, cascade=True)
        self.assertEqual(rc, 0, msg=f"got: {result}")
        self.assertFalse(result["pass"], msg=f"got: {result}")
        self.assertEqual(result["reason"], "snippet-mismatch")

    # --- line-out-of-range (blob returned, range invalid, no substring) ---
    def test_line_out_of_range_via_cascade(self):
        self._commit(
            "fixture.txt",
            "alpha\nbravo\ncharlie\n",
            "init fixture",
        )
        self._push()
        # line_range 50-60 exceeds the 3-line blob; substring also misses
        # ("line two" not in alpha/bravo/charlie) → line-out-of-range.
        claim = self._claim(line_range="50-60")
        rc, result = run_preflight({"omission_claim": claim}, self.cwd, cascade=True)
        self.assertEqual(rc, 0, msg=f"got: {result}")
        self.assertFalse(result["pass"], msg=f"got: {result}")
        self.assertEqual(result["reason"], "line-out-of-range")

    # --- field-missing (required field absent — pre-cascade gate) ---
    def test_field_missing_pre_cascade(self):
        claim = self._claim()
        del claim["falsifier"]
        rc, result = run_preflight({"omission_claim": claim}, self.cwd, cascade=True)
        self.assertEqual(rc, 0, msg=f"got: {result}")
        self.assertFalse(result["pass"])
        self.assertEqual(result["reason"], "field-missing")
        self.assertIn("falsifier", result["detail"])

    # --- provenance-unknown (no blob anywhere, no substring) ---
    def test_provenance_unknown_no_blob(self):
        # Cwd repo has commits, but NOT the claimed file.
        self._commit("other.txt", "unrelated\n", "init other")
        self._push()
        claim = self._claim(file_relative="ghost.txt")
        rc, result = run_preflight({"omission_claim": claim}, self.cwd, cascade=True)
        self.assertEqual(rc, 0, msg=f"got: {result}")
        self.assertFalse(result["pass"])
        self.assertEqual(result["reason"], "provenance-unknown")
        self.assertIn("git fetch origin", result["detail"])

    # --- Legacy downgrade (no file_relative on claim) ---
    def test_legacy_downgrade_missing_file_relative(self):
        self._commit(
            "fixture.txt",
            "line one\nline two\nline three\n",
            "init fixture",
        )
        self._push()
        claim = self._claim()
        del claim["file_relative"]  # legacy pre-Phase-1 row
        rc, result = run_preflight({"omission_claim": claim}, self.cwd, cascade=True)
        self.assertEqual(rc, 0, msg=f"got: {result}")
        self.assertFalse(result["pass"])
        self.assertEqual(result["reason"], "provenance-unknown")
        self.assertEqual(result["detail"], "legacy-pre-capture")

    # --- Full-file hash vs snippet hash semantics ---
    def test_snippet_hash_not_full_file_hash(self):
        # If the cascade were hashing the whole blob, a different content at
        # any non-anchored line would break verification. Insert noise at
        # line 5 between captured_at_sha and origin/main, then assert step 1
        # still matches via the line-range hash (not full-file hash).
        sha = self._commit(
            "fixture.txt",
            "line one\nline two\nline three\nline four\nline five\n",
            "init fixture",
        )
        self._push()
        # Append noise after the snippet → different file hash, same line 2-3.
        self._commit(
            "fixture.txt",
            "line one\nline two\nline three\nline four\nNEW LINE FIVE\nextra\n",
            "rewrite tail",
        )
        self._push()

        # Claim still anchors on lines 2-3 with the captured_at_sha snapshot.
        claim = self._claim(
            captured_at_sha=sha, captured_origin_ref="origin/main"
        )
        rc, result = run_preflight({"omission_claim": claim}, self.cwd, cascade=True)
        self.assertEqual(rc, 0, msg=f"got: {result}")
        self.assertTrue(result["pass"])
        self.assertEqual(result["reason"], "ok")

    # --- anchor_warning passthrough from a sibling clone (no captured ref) ---
    def test_unpushed_local_only_from_sibling_clone(self):
        # Sibling-clone simulation: the claim was captured against a commit
        # the auditing cwd never received (captured_origin_ref=null,
        # anchor_warning=unpushed_local_only). Auditing cwd has nothing.
        # Result should be provenance-unknown (no blob reachable anywhere).
        # Initial unrelated push so HEAD exists.
        self._commit("placeholder.txt", "ignore\n", "init")
        self._push()

        claim = self._claim(
            file_relative="never-pushed.txt",
            captured_at_sha="deadbeef" * 5,
            anchor_warning="unpushed_local_only",
        )
        # captured_origin_ref intentionally absent (null at capture).
        rc, result = run_preflight({"omission_claim": claim}, self.cwd, cascade=True)
        self.assertEqual(rc, 0, msg=f"got: {result}")
        self.assertFalse(result["pass"])
        self.assertEqual(result["reason"], "provenance-unknown")


if __name__ == "__main__":
    unittest.main(verbosity=2)
