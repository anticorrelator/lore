"""Tests for event-driven settlement dispatch (census retirement, memo §5).

Covers the dispute detector, the spot-sample budget dial, rollup re-homing off
scan(), the census posture gates in process_once / recompute_queue /
apply_recomputed_batch, and the status dispatch block's JSON contract.
"""

import importlib.util
import json
import os
import sys

import pytest

_SCRIPTS_DIR = os.path.join(os.path.dirname(__file__), "..", "scripts")
sys.path.insert(0, _SCRIPTS_DIR)

_spec = importlib.util.spec_from_file_location(
    "settlement_processor", os.path.join(_SCRIPTS_DIR, "settlement-processor.py")
)
proc = importlib.util.module_from_spec(_spec)
sys.modules["settlement_processor"] = proc
_spec.loader.exec_module(proc)


def make_settings(census: bool = False, budget: int = 12, enabled: bool = True) -> dict:
    return {
        "enabled": enabled,
        "max_concurrency": 1,
        "lease_ttl_seconds": 900,
        "executor_timeout_seconds": 300,
        "batch_size": 12,
        "batch_recompute_min_interval_seconds": 0,
        "concordance_window_size": 8,
        "active_hours": {"enabled": False, "timezone": "local", "ranges": []},
        "harness_selection": {"mode": "first_eligible", "eligible_frameworks": ["claude-code"], "random_seed": 0},
        "dispatch": {"census_enabled": census, "spot_sample_weekly_budget": budget},
        "max_auto_retry_attempts": 3,
    }


def task_claim_row(claim_id: str) -> str:
    return json.dumps({
        "claim_id": claim_id,
        "claim": f"claim {claim_id}",
        "file": "/repo/a.py",
        "line_range": "1-2",
        "falsifier": "look at the code",
        "change_context": {"diff_ref": None, "changed_files": ["/repo/a.py"], "summary": "s"},
    })


def ledger_row(event_id: str, disposition: str, entry: str, observed_at: str = "2026-07-01T00:00:00Z", **payload_extra) -> str:
    payload = {
        "disposition": disposition,
        "file": "/repo/x.py",
        "line_range": "1-1",
        "exact_snippet": "snippet",
        "normalized_snippet_hash": "h",
    }
    payload.update(payload_extra)
    return json.dumps({
        "schema_version": "1",
        "event": "consumption-verification",
        "event_id": event_id,
        "entry_path": entry,
        "source": "worker",
        "observed_at": observed_at,
        "captured_at_branch": None,
        "captured_at_sha": None,
        "captured_at_merge_base_sha": None,
        "payload": payload,
    })


def cc_row(contradiction_id: str, status: str = "pending") -> str:
    return json.dumps({
        "contradiction_id": contradiction_id,
        "status": status,
        "claim_payload": {
            "claim_id": "k1",
            "file": "/repo/c.py",
            "line_range": "5-6",
            "falsifier": "f",
            "claim_text": "entry says X",
        },
        "entry_path": "conventions/e.md",
    })


@pytest.fixture
def kdir(tmp_path):
    kd = tmp_path / "kd"
    (kd / "_work" / "wi1").mkdir(parents=True)
    (kd / "_trust").mkdir()
    (kd / "conventions").mkdir()
    (kd / "conventions" / "e.md").write_text("# E\n", encoding="utf-8")
    return kd


@pytest.fixture
def settlement(kdir):
    return proc.Settlement(kdir)


def write_ledger(kdir, lines: list[str]) -> None:
    (kdir / "_trust" / "trust-events.jsonl").write_text("\n".join(lines) + "\n", encoding="utf-8")


HELD_X2 = [
    ledger_row("e1", "held", "conventions/e.md"),
    ledger_row("e2", "held", "conventions/e.md", observed_at="2026-07-02T00:00:00Z", file="/repo/y.py"),
]
# Third held keeps net trust >= HIGH_TRUST_THRESHOLD after the contradiction
# (signal 3-2=1 -> 0.5) so the high-trust arm alone fires.
HELD_X3 = HELD_X2 + [ledger_row("e2b", "held", "conventions/e.md", file="/repo/y2.py")]
CONTRADICTED_BRIDGED = ledger_row(
    "e3", "contradicted", "conventions/e.md",
    observed_at="2026-07-03T00:00:00Z",
    work_item="wi1", contradiction_id="cc-1",
)


# ---------------------------------------------------------------------------
# Settings posture
# ---------------------------------------------------------------------------

def test_default_posture_is_event_driven(tmp_path, monkeypatch):
    monkeypatch.setenv("LORE_SETTLEMENT_SETTINGS_FILE", str(tmp_path / "missing.json"))
    settings = proc.settlement_settings()
    assert settings["dispatch"]["census_enabled"] is False
    assert settings["dispatch"]["spot_sample_weekly_budget"] == proc.DEFAULT_SPOT_SAMPLE_WEEKLY_BUDGET == 12


# ---------------------------------------------------------------------------
# Dispute detector
# ---------------------------------------------------------------------------

def test_dispute_enqueues_exactly_once(kdir, settlement):
    write_ledger(kdir, HELD_X3 + [CONTRADICTED_BRIDGED])
    (kdir / "_work" / "wi1" / "consumption-contradictions.jsonl").write_text(cc_row("cc-1") + "\n", encoding="utf-8")

    out = settlement.detect_disputes(3)
    assert out["enqueued"] == 1 and out["unroutable"] == 0

    # Replay: call-site guard sees the queued item; nothing new lands.
    again = settlement.detect_disputes(3)
    assert again["enqueued"] == 0 and again["duplicates"] == 1

    items = settlement.load_queue()["items"]
    disputes = [it for it in items if it.get("selection_reason") == "dispute"]
    assert len(disputes) == 1
    assert disputes[0]["kind"] == proc.KIND_CONSUMPTION_CONTRADICTION


def test_dispute_conflict_arm_fires_without_high_trust(kdir, settlement):
    # One held + one contradicted: trust 0.0 (below threshold) but conflicting.
    write_ledger(kdir, [HELD_X2[0], CONTRADICTED_BRIDGED])
    (kdir / "_work" / "wi1" / "consumption-contradictions.jsonl").write_text(cc_row("cc-1") + "\n", encoding="utf-8")
    out = settlement.detect_disputes(3)
    assert out["enqueued"] == 1


def test_contradiction_against_unobserved_entry_skips(kdir, settlement):
    # No held rows anywhere: neither high-trust nor conflicting.
    write_ledger(kdir, [CONTRADICTED_BRIDGED])
    (kdir / "_work" / "wi1" / "consumption-contradictions.jsonl").write_text(cc_row("cc-1") + "\n", encoding="utf-8")
    out = settlement.detect_disputes(3)
    assert out["enqueued"] == 0 and out["skipped"] == 1


def test_unbridged_contradiction_is_unroutable_not_guessed(kdir, settlement):
    # No work_item/contradiction_id in the ledger payload: legible unroutable count.
    row = ledger_row("e9", "contradicted", "conventions/e.md")
    write_ledger(kdir, HELD_X3 + [row])
    out = settlement.detect_disputes(3)
    assert out["unroutable"] == 1 and out["enqueued"] == 0


def test_settled_cc_row_never_reenqueued(kdir, settlement):
    write_ledger(kdir, HELD_X3 + [CONTRADICTED_BRIDGED])
    (kdir / "_work" / "wi1" / "consumption-contradictions.jsonl").write_text(cc_row("cc-1", status="verified") + "\n", encoding="utf-8")
    out = settlement.detect_disputes(3)
    assert out["enqueued"] == 0


# ---------------------------------------------------------------------------
# Spot-sample budget
# ---------------------------------------------------------------------------

def write_claims(kdir, n: int) -> None:
    lines = "\n".join(task_claim_row(f"c{i}") for i in range(n)) + "\n"
    (kdir / "_work" / "wi1" / "task-claims.jsonl").write_text(lines, encoding="utf-8")


def test_spot_sample_respects_budget(kdir, settlement):
    write_claims(kdir, 6)
    out = settlement.spot_sample(make_settings(budget=3))
    assert out["enqueued"] == 3 and out["used_this_week"] == 3
    items = settlement.load_queue()["items"]
    assert all(it["selection_reason"] == "spot_sample" for it in items)

    # Same week replay: budget already consumed.
    again = settlement.spot_sample(make_settings(budget=3))
    assert again["enqueued"] == 0 and again["reason"] == "budget_exhausted"


def test_spot_sample_zero_budget_is_legible(kdir, settlement):
    write_claims(kdir, 2)
    out = settlement.spot_sample(make_settings(budget=0))
    assert out["enqueued"] == 0 and out["reason"] == "budget_zero"


def test_spot_sample_skips_terminal_and_queued(kdir, settlement):
    write_claims(kdir, 2)
    first = settlement.spot_sample(make_settings(budget=12))
    assert first["enqueued"] == 2
    # Everything queued; a fresh call finds no candidates.
    out = settlement.spot_sample(make_settings(budget=12))
    assert out["enqueued"] == 0


# ---------------------------------------------------------------------------
# Rollup re-homing + pump
# ---------------------------------------------------------------------------

def test_pump_enqueues_rollups_without_scan(kdir, settlement):
    out = settlement.pump_triggers(make_settings(), force=True)
    assert out["ran"] is True
    assert out["rollup"]["enqueued"] == len(proc.ROLLUP_JUDGES)
    assert out["dispatch_mode"] == "event-driven"


def test_pump_throttles_between_runs(kdir, settlement):
    first = settlement.pump_triggers(make_settings(), force=True)
    assert first["ran"] is True
    second = settlement.pump_triggers(make_settings())
    assert second["ran"] is False and second["reason"] == "throttled"
    forced = settlement.pump_triggers(make_settings(), force=True)
    assert forced["ran"] is True


# ---------------------------------------------------------------------------
# Census posture gates
# ---------------------------------------------------------------------------

def test_process_once_event_mode_does_not_refill_from_backlog(kdir, settlement, monkeypatch, tmp_path):
    settings_file = tmp_path / "settings.json"
    settings_file.write_text(json.dumps({"version": 1, "harnesses": {"claude-code": {"args": []}}}), encoding="utf-8")
    monkeypatch.setenv("LORE_SETTLEMENT_SETTINGS_FILE", str(settings_file))
    write_claims(kdir, 4)  # backlog exists in the source stream
    out = settlement.process_once(make_settings(census=False))
    assert out["dispatched"] is False
    assert out["reason"] == "empty_queue"
    assert settlement.load_queue()["items"] == []


def test_recompute_refused_in_event_mode_and_allowed_in_census(kdir, settlement):
    write_claims(kdir, 2)
    refused = settlement.recompute_queue(make_settings(census=False))
    assert refused["recomputed"] is False and refused["reason"] == "census_disabled"
    allowed = settlement.recompute_queue(make_settings(census=True))
    assert allowed["recomputed"] is True
    assert len(settlement.load_queue()["items"]) == 2


def test_census_recompute_preserves_event_trigger_items(kdir, settlement):
    # A dispute item must survive a census-mode recompute even when the batch
    # window is smaller than the backlog.
    write_ledger(kdir, HELD_X3 + [CONTRADICTED_BRIDGED])
    (kdir / "_work" / "wi1" / "consumption-contradictions.jsonl").write_text(cc_row("cc-1") + "\n", encoding="utf-8")
    assert settlement.detect_disputes(3)["enqueued"] == 1
    write_claims(kdir, 8)
    settings = make_settings(census=True)
    settings["batch_size"] = 2
    settlement.recompute_queue(settings)
    items = settlement.load_queue()["items"]
    disputes = [it for it in items if it.get("selection_reason") == "dispute"]
    assert len(disputes) == 1


def test_census_recompute_preserves_confirmer_sample_items(kdir, settlement):
    # confirmer-sample.sh stamps selection_reason=confirmer_sample on its
    # enqueued items (importing this module as a library); a census-mode
    # recompute must preserve them unchanged like every event-trigger item,
    # never fold them into the scored batch window.
    write_claims(kdir, 8)
    settlement.ensure()
    with proc.repo_lock(settlement.state):
        queue = settlement.load_queue()
        queue["items"].append({
            "id": settlement.item_id("wi1", "held-claim-1", "commons"),
            "kind": "commons",
            "status": "pending",
            "work_item": "wi1",
            "claim_id": "held-claim-1",
            "selection_reason": "confirmer_sample",
            "batch_id": "confirmer-abc",
            "enqueued_at": proc.utc_now(),
            "updated_at": proc.utc_now(),
        })
        settlement.save_queue(queue)
    settings = make_settings(census=True)
    settings["batch_size"] = 2
    settlement.recompute_queue(settings)
    items = settlement.load_queue()["items"]
    confirmers = [it for it in items if it.get("selection_reason") == "confirmer_sample"]
    assert len(confirmers) == 1
    assert confirmers[0]["batch_id"] == "confirmer-abc"  # preserved unchanged, not re-scored


# ---------------------------------------------------------------------------
# Status contract (TUI-parseable; scalar types stable)
# ---------------------------------------------------------------------------

def test_status_dispatch_block_shape(kdir, settlement, monkeypatch, tmp_path):
    settings_file = tmp_path / "settings.json"
    settings_file.write_text("{}", encoding="utf-8")
    monkeypatch.setenv("LORE_SETTLEMENT_SETTINGS_FILE", str(settings_file))
    settlement.ensure()
    status = settlement.status(make_settings(census=False))
    dispatch = status["dispatch"]
    assert dispatch["mode"] == "event-driven"
    assert dispatch["census_enabled"] is False
    assert isinstance(dispatch["spot_sample"]["weekly_budget"], int)
    assert isinstance(dispatch["spot_sample"]["used_this_week"], int)
    assert isinstance(dispatch["spot_sample"]["week_start"], str)
    volume = dispatch["verify_volume"]
    assert isinstance(volume["weekly_average"], float)
    assert isinstance(volume["below_threshold"], bool)
    assert isinstance(volume["weeks"], list) and len(volume["weeks"]) == proc.VERIFY_VOLUME_WINDOW_WEEKS
    json.dumps(status, sort_keys=True)  # must stay serializable end-to-end

    census_status = settlement.status(make_settings(census=True))
    assert census_status["dispatch"]["mode"] == "census"


def test_status_event_mode_backlog_not_advertised(kdir, settlement, monkeypatch, tmp_path):
    settings_file = tmp_path / "settings.json"
    settings_file.write_text("{}", encoding="utf-8")
    monkeypatch.setenv("LORE_SETTLEMENT_SETTINGS_FILE", str(settings_file))
    settlement.ensure()
    # Simulate a census-era drained batch: stale backlog_size, no pending items.
    queue = settlement.load_queue()
    queue["batch"] = {"id": "b1", "recomputed_at": "2026-07-01T00:00:00Z", "size": 0, "backlog_size": 42, "recompute_reason": "x"}
    settlement.save_queue(queue)
    status = settlement.status(make_settings(census=False))
    assert status["next_action"].startswith("idle")
    census_status = settlement.status(make_settings(census=True))
    assert census_status["next_action"] == "process once or wait for processor"


def test_missing_and_empty_eligible_frameworks_block_status(kdir, settlement, monkeypatch, tmp_path):
    settings_file = tmp_path / "settings.json"
    settings_file.write_text(json.dumps({"version": 1, "harnesses": {"claude-code": {"args": []}}}), encoding="utf-8")
    monkeypatch.setenv("LORE_SETTLEMENT_SETTINGS_FILE", str(settings_file))

    missing = make_settings(census=False)
    missing["harness_selection"].pop("eligible_frameworks", None)
    missing_status = settlement.status(missing)
    assert proc.ELIGIBLE_FRAMEWORKS_SETTINGS_KEY in missing_status["blocked_reason"]
    assert proc.ELIGIBLE_FRAMEWORKS_REMEDIATION in missing_status["next_action"]
    assert missing_status["harness"]["settings_key"] == proc.ELIGIBLE_FRAMEWORKS_SETTINGS_KEY

    empty = make_settings(census=False)
    empty["harness_selection"]["eligible_frameworks"] = []
    empty_status = settlement.status(empty)
    assert proc.ELIGIBLE_FRAMEWORKS_SETTINGS_KEY in empty_status["blocked_reason"]
    assert proc.ELIGIBLE_FRAMEWORKS_REMEDIATION in empty_status["next_action"]


def test_declared_dispatch_framework_flip_and_same_framework_quiet(kdir, settlement, monkeypatch, tmp_path):
    settings_file = tmp_path / "settings.json"
    settings_file.write_text(
        json.dumps({"version": 1, "harnesses": {"claude-code": {"args": []}, "codex": {"args": []}}}),
        encoding="utf-8",
    )
    executor = tmp_path / "success-exec.sh"
    executor.write_text("#!/usr/bin/env bash\ncat >/dev/null\nexit 0\n", encoding="utf-8")
    executor.chmod(0o755)
    monkeypatch.setenv("LORE_SETTLEMENT_SETTINGS_FILE", str(settings_file))
    monkeypatch.setenv("LORE_SETTLEMENT_EXECUTOR", str(executor))

    for claim_id in ("flip-1", "flip-2", "flip-3"):
        settlement.enqueue_row("wi1", json.loads(task_claim_row(claim_id)))

    first_settings = make_settings(census=False)
    first_settings["harness_selection"]["eligible_frameworks"] = ["claude-code"]
    first = settlement.process_once(first_settings)
    assert first["dispatched"] is True
    assert first["run"]["framework"] == "claude-code"
    assert "framework_changed" not in first["run"]

    second_settings = make_settings(census=False)
    second_settings["harness_selection"]["eligible_frameworks"] = ["codex"]
    second = settlement.process_once(second_settings)
    assert second["dispatched"] is True
    assert second["run"]["framework_changed"] == {"from": "claude-code", "to": "codex"}

    third = settlement.process_once(second_settings)
    assert third["dispatched"] is True
    assert "framework_changed" not in third["run"]

    pump_log = kdir / "_settlement" / "pump-log.jsonl"
    events = [json.loads(line) for line in pump_log.read_text(encoding="utf-8").splitlines()]
    flips = [event for event in events if event.get("event") == "framework_changed"]
    assert len(flips) == 1
    assert flips[0]["from"] == "claude-code"
    assert flips[0]["to"] == "codex"
    assert flips[0]["run_id"] == second["run"]["run_id"]


# ---------------------------------------------------------------------------
# Verify-volume measurement (memo §5.3)
# ---------------------------------------------------------------------------

def test_verify_volume_counts_and_threshold(kdir, settlement, monkeypatch):
    monkeypatch.setenv("LORE_SETTLEMENT_NOW", "2026-07-03T12:00:00Z")
    # 2026-06-29 is the Monday of the current week; prior weeks get 1 event each.
    write_ledger(kdir, [
        ledger_row("v1", "held", "conventions/e.md", observed_at="2026-06-03T00:00:00Z"),
        ledger_row("v2", "held", "conventions/e.md", observed_at="2026-06-10T00:00:00Z", file="/b.py"),
        ledger_row("v3", "held", "conventions/e.md", observed_at="2026-07-01T00:00:00Z", file="/c.py"),
    ])
    volume = settlement.verify_volume()
    assert volume["current_week_events"] == 1
    assert sum(w["events"] for w in volume["weeks"]) == 2
    assert volume["below_threshold"] is True  # avg 0.5 < 10
