"""Branch-map coverage for Settlement._apply_correction_from_verdict.

Phase 1 verification (D2 closed taxonomy) requires every contradicted-verdict
return path inside `_apply_correction_from_verdict` to assign exactly one
`correction_outcome` whose `status` and `reason` belong to the closed taxonomy.
The shell harness in `tests/test_settlement_auto_correction.sh` exercises four
branches end-to-end (applied, not_mechanically_applicable, auto_correction_disabled,
and the verified-skip non-branch). The remaining branches are awkward to trigger
from a shell harness because they require failure modes of the find-correction
or apply-correction subprocesses themselves. This module monkeypatches the
`subprocess.run` seam inside settlement-processor and drives each of those
branches directly.
"""

from __future__ import annotations

import importlib.util
import subprocess
import types
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parent.parent
SETTLEMENT_PATH = REPO_ROOT / "scripts" / "settlement-processor.py"


def _load_settlement_module() -> types.ModuleType:
    spec = importlib.util.spec_from_file_location("settlement_processor", SETTLEMENT_PATH)
    assert spec and spec.loader, f"could not load {SETTLEMENT_PATH}"
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


settlement_processor = _load_settlement_module()


class _FakeProc:
    def __init__(self, returncode: int = 0, stdout: str = "", stderr: str = ""):
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr


def _settlement_with_kdir(tmp_path: Path) -> "settlement_processor.Settlement":
    return settlement_processor.Settlement(tmp_path)


def _contradicted_run(run_id: str = "run-test-001", correction: str | None = "fix") -> dict:
    return {
        "run_id": run_id,
        "verdict": {
            "verdict": "contradicted",
            "evidence": "drift",
            "correction": correction,
        },
    }


def _item(claim: str | None = "claim text", source_file: str = "scripts/router.py") -> dict:
    return {
        "claim": claim,
        "source": {"file": source_file, "line_range": "10-12"},
    }


def _make_subprocess_run(scripts: dict[str, object]):
    """Return a fake subprocess.run that dispatches based on the script name
    appearing in argv (find-correction-targets.sh vs apply-correction.sh).
    Each value in `scripts` is either a _FakeProc (returned) or an Exception
    (raised).
    """
    def _run(cmd, *args, **kwargs):
        argv_str = " ".join(str(c) for c in cmd)
        for key, behavior in scripts.items():
            if key in argv_str:
                if isinstance(behavior, BaseException):
                    raise behavior
                return behavior
        raise AssertionError(f"unexpected subprocess.run argv: {argv_str}")
    return _run


@pytest.fixture
def env_no_killswitch(monkeypatch):
    monkeypatch.delenv("LORE_SETTLEMENT_DISABLE_AUTO_CORRECTION", raising=False)


def test_verified_verdict_returns_none(tmp_path):
    s = _settlement_with_kdir(tmp_path)
    run = {"run_id": "r-1", "verdict": {"verdict": "verified", "evidence": "ok"}}
    assert s._apply_correction_from_verdict(run, _item()) is None


def test_auto_correction_disabled(monkeypatch, tmp_path):
    monkeypatch.setenv("LORE_SETTLEMENT_DISABLE_AUTO_CORRECTION", "1")
    s = _settlement_with_kdir(tmp_path)
    outcome = s._apply_correction_from_verdict(_contradicted_run(), _item())
    assert outcome == {"status": "skipped", "reason": "auto_correction_disabled"}


def test_empty_correction_text(env_no_killswitch, tmp_path):
    s = _settlement_with_kdir(tmp_path)
    outcome = s._apply_correction_from_verdict(_contradicted_run(correction=""), _item())
    assert outcome == {"status": "skipped", "reason": "empty_correction_text"}


def test_empty_correction_text_none_correction(env_no_killswitch, tmp_path):
    s = _settlement_with_kdir(tmp_path)
    outcome = s._apply_correction_from_verdict(_contradicted_run(correction=None), _item())
    assert outcome == {"status": "skipped", "reason": "empty_correction_text"}


def test_empty_claim_text(env_no_killswitch, tmp_path):
    s = _settlement_with_kdir(tmp_path)
    outcome = s._apply_correction_from_verdict(_contradicted_run(), _item(claim=""))
    assert outcome == {"status": "skipped", "reason": "empty_claim_text"}


def test_find_targets_subprocess_error(env_no_killswitch, monkeypatch, tmp_path):
    monkeypatch.setattr(
        settlement_processor.subprocess,
        "run",
        _make_subprocess_run({"find-correction-targets.sh": OSError("boom")}),
    )
    s = _settlement_with_kdir(tmp_path)
    outcome = s._apply_correction_from_verdict(_contradicted_run(), _item())
    assert outcome is not None
    assert outcome["status"] == "failed"
    assert outcome["reason"] == "find_targets_subprocess_error"
    assert "boom" in outcome["detail"]


def test_find_targets_timeout_routes_to_subprocess_error(env_no_killswitch, monkeypatch, tmp_path):
    monkeypatch.setattr(
        settlement_processor.subprocess,
        "run",
        _make_subprocess_run({
            "find-correction-targets.sh": subprocess.TimeoutExpired(cmd="find", timeout=30),
        }),
    )
    s = _settlement_with_kdir(tmp_path)
    outcome = s._apply_correction_from_verdict(_contradicted_run(), _item())
    assert outcome["status"] == "failed"
    assert outcome["reason"] == "find_targets_subprocess_error"


def test_find_targets_nonzero_exit(env_no_killswitch, monkeypatch, tmp_path):
    monkeypatch.setattr(
        settlement_processor.subprocess,
        "run",
        _make_subprocess_run({
            "find-correction-targets.sh": _FakeProc(returncode=2, stdout="", stderr="index missing"),
        }),
    )
    s = _settlement_with_kdir(tmp_path)
    outcome = s._apply_correction_from_verdict(_contradicted_run(), _item())
    assert outcome["status"] == "failed"
    assert outcome["reason"] == "find_targets_nonzero_exit"
    assert "exit 2" in outcome["detail"]


def test_find_targets_nonzero_exit_zero_returncode_empty_stdout(env_no_killswitch, monkeypatch, tmp_path):
    """When find exits 0 but produces no stdout the loop still routes to
    find_targets_nonzero_exit (the `or not find_proc.stdout.strip()` guard)."""
    monkeypatch.setattr(
        settlement_processor.subprocess,
        "run",
        _make_subprocess_run({
            "find-correction-targets.sh": _FakeProc(returncode=0, stdout="   "),
        }),
    )
    s = _settlement_with_kdir(tmp_path)
    outcome = s._apply_correction_from_verdict(_contradicted_run(), _item())
    assert outcome["status"] == "failed"
    assert outcome["reason"] == "find_targets_nonzero_exit"


def test_find_targets_json_parse(env_no_killswitch, monkeypatch, tmp_path):
    monkeypatch.setattr(
        settlement_processor.subprocess,
        "run",
        _make_subprocess_run({
            "find-correction-targets.sh": _FakeProc(returncode=0, stdout="not json {{"),
        }),
    )
    s = _settlement_with_kdir(tmp_path)
    outcome = s._apply_correction_from_verdict(_contradicted_run(), _item())
    assert outcome["status"] == "failed"
    assert outcome["reason"] == "find_targets_json_parse"


def test_concordance_unavailable(env_no_killswitch, monkeypatch, tmp_path):
    monkeypatch.setattr(
        settlement_processor.subprocess,
        "run",
        _make_subprocess_run({
            "find-correction-targets.sh": _FakeProc(
                returncode=0,
                stdout='{"index_state": "missing", "targets": []}',
            ),
        }),
    )
    s = _settlement_with_kdir(tmp_path)
    outcome = s._apply_correction_from_verdict(_contradicted_run(), _item())
    assert outcome == {"status": "skipped", "reason": "concordance_unavailable"}


def test_no_commons_target(env_no_killswitch, monkeypatch, tmp_path):
    monkeypatch.setattr(
        settlement_processor.subprocess,
        "run",
        _make_subprocess_run({
            "find-correction-targets.sh": _FakeProc(
                returncode=0,
                stdout='{"index_state": "ready", "targets": []}',
            ),
        }),
    )
    s = _settlement_with_kdir(tmp_path)
    outcome = s._apply_correction_from_verdict(_contradicted_run(), _item())
    assert outcome == {"status": "skipped", "reason": "no_commons_target"}


def test_target_path_missing(env_no_killswitch, monkeypatch, tmp_path):
    monkeypatch.setattr(
        settlement_processor.subprocess,
        "run",
        _make_subprocess_run({
            "find-correction-targets.sh": _FakeProc(
                returncode=0,
                stdout='{"index_state": "ready", "targets": [{"path": ""}]}',
            ),
        }),
    )
    s = _settlement_with_kdir(tmp_path)
    outcome = s._apply_correction_from_verdict(_contradicted_run(), _item())
    assert outcome == {"status": "skipped", "reason": "target_path_missing"}


def test_apply_subprocess_error(env_no_killswitch, monkeypatch, tmp_path):
    monkeypatch.setattr(
        settlement_processor.subprocess,
        "run",
        _make_subprocess_run({
            "find-correction-targets.sh": _FakeProc(
                returncode=0,
                stdout='{"index_state": "ready", "targets": [{"path": "conventions/x.md"}]}',
            ),
            "apply-correction.sh": OSError("apply boom"),
        }),
    )
    s = _settlement_with_kdir(tmp_path)
    outcome = s._apply_correction_from_verdict(_contradicted_run(), _item())
    assert outcome["status"] == "failed"
    assert outcome["reason"] == "apply_subprocess_error"
    assert outcome["target_entry"] == "conventions/x.md"
    assert "apply boom" in outcome["detail"]


def test_apply_unexpected_exit(env_no_killswitch, monkeypatch, tmp_path):
    monkeypatch.setattr(
        settlement_processor.subprocess,
        "run",
        _make_subprocess_run({
            "find-correction-targets.sh": _FakeProc(
                returncode=0,
                stdout='{"index_state": "ready", "targets": [{"path": "conventions/x.md"}]}',
            ),
            "apply-correction.sh": _FakeProc(returncode=7, stderr="weird"),
        }),
    )
    s = _settlement_with_kdir(tmp_path)
    outcome = s._apply_correction_from_verdict(_contradicted_run(), _item())
    assert outcome["status"] == "failed"
    assert outcome["reason"] == "apply_unexpected_exit"
    assert outcome["target_entry"] == "conventions/x.md"
    assert "exit 7" in outcome["detail"]


def test_applied(env_no_killswitch, monkeypatch, tmp_path):
    monkeypatch.setattr(
        settlement_processor.subprocess,
        "run",
        _make_subprocess_run({
            "find-correction-targets.sh": _FakeProc(
                returncode=0,
                stdout='{"index_state": "ready", "targets": [{"path": "conventions/x.md"}]}',
            ),
            "apply-correction.sh": _FakeProc(returncode=0),
        }),
    )
    s = _settlement_with_kdir(tmp_path)
    outcome = s._apply_correction_from_verdict(_contradicted_run(), _item())
    assert outcome == {"status": "applied", "reason": "applied", "target_entry": "conventions/x.md"}


def test_not_mechanically_applicable(env_no_killswitch, monkeypatch, tmp_path):
    monkeypatch.setattr(
        settlement_processor.subprocess,
        "run",
        _make_subprocess_run({
            "find-correction-targets.sh": _FakeProc(
                returncode=0,
                stdout='{"index_state": "ready", "targets": [{"path": "conventions/x.md"}]}',
            ),
            "apply-correction.sh": _FakeProc(returncode=2, stderr="superseded_text not present"),
        }),
    )
    s = _settlement_with_kdir(tmp_path)
    outcome = s._apply_correction_from_verdict(_contradicted_run(), _item())
    assert outcome == {
        "status": "skipped",
        "reason": "not_mechanically_applicable",
        "target_entry": "conventions/x.md",
    }


CLOSED_TAXONOMY = {
    "applied": {"applied"},
    "skipped": {
        "empty_correction_text",
        "empty_claim_text",
        "concordance_unavailable",
        "no_commons_target",
        "target_path_missing",
        "not_mechanically_applicable",
        "auto_correction_disabled",
    },
    "failed": {
        "find_targets_subprocess_error",
        "find_targets_nonzero_exit",
        "find_targets_json_parse",
        "apply_subprocess_error",
        "apply_unexpected_exit",
    },
}


@pytest.mark.parametrize(
    "outcome",
    [
        {"status": "applied", "reason": "applied", "target_entry": "x"},
        {"status": "skipped", "reason": "auto_correction_disabled"},
        {"status": "skipped", "reason": "empty_correction_text"},
        {"status": "skipped", "reason": "empty_claim_text"},
        {"status": "skipped", "reason": "concordance_unavailable"},
        {"status": "skipped", "reason": "no_commons_target"},
        {"status": "skipped", "reason": "target_path_missing"},
        {"status": "skipped", "reason": "not_mechanically_applicable"},
        {"status": "failed", "reason": "find_targets_subprocess_error"},
        {"status": "failed", "reason": "find_targets_nonzero_exit"},
        {"status": "failed", "reason": "find_targets_json_parse"},
        {"status": "failed", "reason": "apply_subprocess_error"},
        {"status": "failed", "reason": "apply_unexpected_exit"},
    ],
)
def test_closed_taxonomy_membership(outcome):
    """Documents the closed taxonomy as a literal allowlist. Adding a new
    status/reason without updating this list will fail the suite — the intent
    is that this test breaks if D2's closed taxonomy expands silently."""
    assert outcome["status"] in CLOSED_TAXONOMY
    assert outcome["reason"] in CLOSED_TAXONOMY[outcome["status"]]
