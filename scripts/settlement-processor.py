#!/usr/bin/env python3
"""Durable settlement queue and processor.

State lives under <KDIR>/_settlement, outside _work:
  queue.json   owned by settlement-queue.sh and this processor
  leases.json  owned by this processor
  usage.json   owned by this processor
  runs/*.json  owned by this processor
  _meta.json   describes the global JSON shapes and ownership matrix
"""

from __future__ import annotations

import argparse
import hashlib
import heapq
import json
import os
import random
import shlex
import subprocess
import sys
import time
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError


VERSION = 1
TERMINAL = {"completed", "failed", "blocked"}
SUPPORT_OK = {"full", "partial", "fallback"}
DAY_IDS = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
DEFAULT_BATCH_SIZE = 12
DEFAULT_BATCH_RECOMPUTE_MIN_INTERVAL_SECONDS = 60
DEFAULT_CONCORDANCE_WINDOW_SIZE = 8
DEFAULT_EXECUTOR_TIMEOUT_SECONDS = 300
STATUS_RECENT_RUNS_LIMIT = 25
STATUS_TERMINAL_PREVIEW_LIMIT = 5

# Source-stream registry. Each kind maps to:
#   filename: glob-relative name under _work/<slug>/
#   id_field: field on the source row that uniquely identifies it within the file
KIND_TASK_CLAIM = "task-claim"
KIND_OMISSION = "omission"
KIND_CONSUMPTION_CONTRADICTION = "consumption-contradiction"
KIND_COMMONS = "commons"
KINDS = (KIND_TASK_CLAIM, KIND_OMISSION, KIND_CONSUMPTION_CONTRADICTION, KIND_COMMONS)
KIND_SOURCES = {
    KIND_TASK_CLAIM: {"filename": "task-claims.jsonl", "id_field": "claim_id"},
    KIND_OMISSION: {"filename": "audit-candidates.jsonl", "id_field": "candidate_id"},
    KIND_CONSUMPTION_CONTRADICTION: {"filename": "consumption-contradictions.jsonl", "id_field": "contradiction_id"},
    KIND_COMMONS: {"filename": "promoted-commons.jsonl", "id_field": "claim_id"},
}

# Maps a queue item's kind to the kind-specialized correctness-gate it will
# dispatch through. Only the hard-cal gates (assertion + contradiction) drive
# mutation; the omission gate is soft-cal-with-discrimination and the
# precondition logic explicitly skips it. The settlement processor consults
# this table at the start of each process_once() invocation to decide whether
# the dispatch needs a calibration self-precondition run for this kind.
KIND_TO_GATE = {
    KIND_TASK_CLAIM: "correctness-gate-assertion",
    KIND_OMISSION: "correctness-gate-omission",
    KIND_CONSUMPTION_CONTRADICTION: "correctness-gate-contradiction",
    KIND_COMMONS: "correctness-gate-assertion",
}
HARD_CAL_GATES = {"correctness-gate-assertion", "correctness-gate-contradiction"}

# Rollup queue items aggregate per-claim tier=reusable scorecard rows into
# per-template tier=template rows that /evolve's primary gate consumes. They
# are kept ORTHOGONAL to KINDS / KIND_SOURCES / KIND_TO_GATE because they have
# no `_work/<slug>/<file>` source row — see D6. Direct-enqueued via
# enqueue_rollup_item; dispatched via execute_item's rollup branch; never
# walked by scan()'s source-stream loop.
KIND_ROLLUP_CORRECTNESS_GATE_ASSERTION = "rollup-correctness-gate-assertion"
KIND_ROLLUP_CORRECTNESS_GATE_OMISSION = "rollup-correctness-gate-omission"
KIND_ROLLUP_CORRECTNESS_GATE_CONTRADICTION = "rollup-correctness-gate-contradiction"
KIND_ROLLUP_CURATOR = "rollup-curator"
KIND_ROLLUP_REVERSE_AUDITOR = "rollup-reverse-auditor"
ROLLUP_KINDS = (
    KIND_ROLLUP_CORRECTNESS_GATE_ASSERTION,
    KIND_ROLLUP_CORRECTNESS_GATE_OMISSION,
    KIND_ROLLUP_CORRECTNESS_GATE_CONTRADICTION,
    KIND_ROLLUP_CURATOR,
    KIND_ROLLUP_REVERSE_AUDITOR,
)
ROLLUP_KIND_TO_SCRIPT = {
    KIND_ROLLUP_CORRECTNESS_GATE_ASSERTION: ("correctness-gate-rollup.sh", "correctness-gate-assertion"),
    KIND_ROLLUP_CORRECTNESS_GATE_OMISSION: ("correctness-gate-rollup.sh", "correctness-gate-omission"),
    KIND_ROLLUP_CORRECTNESS_GATE_CONTRADICTION: ("correctness-gate-rollup.sh", "correctness-gate-contradiction"),
    KIND_ROLLUP_CURATOR: ("curator-rollup.sh", "curator"),
    KIND_ROLLUP_REVERSE_AUDITOR: ("reverse-auditor-rollup.sh", "reverse-auditor"),
}
ROLLUP_JUDGE_TO_KIND = {judge: kind for kind, (_script, judge) in ROLLUP_KIND_TO_SCRIPT.items()}
ROLLUP_JUDGES = tuple(judge for _kind, (_script, judge) in ROLLUP_KIND_TO_SCRIPT.items())
ROLLUP_BACKFILL_DEFAULT_WEEKS = 30
ROLLUP_BACKFILL_MAX_WEEKS = 104

# Event-driven dispatch (settlement disposition memo, transition safeguards §5).
# The always-on census (scan-as-enqueue + recompute-from-backlog refill + TUI
# auto-process tick) is retired but dormant: settlement.dispatch.census_enabled
# re-enables it wholesale, and `lore settlement scan` stays manually invocable
# in either posture. Enqueue in the event-driven posture happens only through
# the trigger pump (disputes, spot-sample, rollup steady-state) and explicit
# `enqueue` calls.
DEFAULT_SPOT_SAMPLE_WEEKLY_BUDGET = 12  # memo §5.1: starts HIGH — a throttled census while peer volume is unproven
HIGH_TRUST_THRESHOLD = 0.5  # trust-compute score; 0.5 = one net held-equivalent of ledger signal
# confirmer_sample is stamped by scripts/confirmer-sample.sh (which imports
# this module as a library) after its own enqueue+placement intervention.
EVENT_TRIGGER_REASONS = ("dispute", "spot_sample", "confirmer_sample")
TRIGGER_PUMP_MIN_INTERVAL_SECONDS = 300  # the TUI status tick runs every 5s; the pump self-throttles
VERIFY_VOLUME_THIN_THRESHOLD = 10  # memo §5.3: <10 verify events/week avg over 4 weeks = thin
VERIFY_VOLUME_WINDOW_WEEKS = 4


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def utc_now_dt() -> datetime:
    override = os.environ.get("LORE_SETTLEMENT_NOW")
    if override:
        dt = datetime.fromisoformat(override.replace("Z", "+00:00"))
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.astimezone(timezone.utc)
    return datetime.now(timezone.utc)


def monday_floor_utc(dt: datetime) -> datetime:
    """Return Monday 00:00:00 UTC of the week containing `dt`."""
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    dt = dt.astimezone(timezone.utc)
    day_floor = dt.replace(hour=0, minute=0, second=0, microsecond=0)
    weekday = day_floor.weekday()  # Mon=0, Sun=6
    return day_floor - timedelta(days=weekday)


def iso_z(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def now_epoch() -> int:
    return int(time.time())


def parse_hhmm(value: Any, fallback: str) -> int:
    text = value if isinstance(value, str) else fallback
    try:
        hh, mm = text.split(":", 1)
        hour = int(hh)
        minute = int(mm)
    except Exception:
        hh, mm = fallback.split(":", 1)
        hour = int(hh)
        minute = int(mm)
    if hour < 0 or hour > 23 or minute < 0 or minute > 59:
        hh, mm = fallback.split(":", 1)
        hour = int(hh)
        minute = int(mm)
    return hour * 60 + minute


def active_hours_now(tz_name: str) -> datetime:
    tz = None
    if tz_name and tz_name != "local":
        tz = ZoneInfo(tz_name)
    override = os.environ.get("LORE_SETTLEMENT_NOW")
    if override:
        dt = datetime.fromisoformat(override.replace("Z", "+00:00"))
        if tz is not None:
            return dt.astimezone(tz) if dt.tzinfo else dt.replace(tzinfo=tz)
        return dt.astimezone() if dt.tzinfo else dt
    return datetime.now(tz) if tz is not None else datetime.now().astimezone()


def parse_active_hours_range(raw: Any) -> dict[str, Any] | None:
    if not isinstance(raw, dict):
        return None
    days = raw.get("days") if isinstance(raw.get("days"), list) else []
    days = [d for d in days if d in DAY_IDS]
    if not days:
        return None
    start = raw.get("start") if isinstance(raw.get("start"), str) else "09:00"
    end = raw.get("end") if isinstance(raw.get("end"), str) else "17:00"
    return {
        "days": days,
        "start": start,
        "end": end,
        "start_minutes": parse_hhmm(start, "09:00"),
        "end_minutes": parse_hhmm(end, "17:00"),
    }


def range_allows(current: datetime, entry: dict[str, Any]) -> bool:
    start = int(entry["start_minutes"])
    end = int(entry["end_minutes"])
    today = DAY_IDS[current.weekday()]
    minute = current.hour * 60 + current.minute
    window_day = today
    if start > end and minute < end:
        window_day = DAY_IDS[(current.weekday() - 1) % 7]
    if window_day not in entry["days"]:
        return False
    if start == end:
        return True
    if start < end:
        return start <= minute < end
    return minute >= start or minute < end


def range_public(entry: dict[str, Any]) -> dict[str, Any]:
    return {"days": entry["days"], "start": entry["start"], "end": entry["end"]}


def json_dump(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(tmp, path)


def json_load(path: Path, default: Any) -> Any:
    if not path.exists():
        return default
    with path.open(encoding="utf-8") as fh:
        return json.load(fh)


def compact(obj: Any) -> str:
    return json.dumps(obj, separators=(",", ":"), sort_keys=True)


def parse_int(value: Any, default: int, minimum: int) -> int:
    try:
        return max(minimum, int(value))
    except (TypeError, ValueError):
        return max(minimum, default)


@contextmanager
def repo_lock(state_dir: Path):
    state_dir.mkdir(parents=True, exist_ok=True)
    lock_dir = state_dir / ".lock.d"
    start = time.time()
    while True:
        try:
            lock_dir.mkdir()
            break
        except FileExistsError:
            if time.time() - start > 10:
                raise SystemExit(f"[settlement] Error: could not acquire {lock_dir} after 10s")
            time.sleep(0.05)
    try:
        yield
    finally:
        try:
            lock_dir.rmdir()
        except OSError:
            pass


class Settlement:
    def __init__(self, kdir: Path):
        self.kdir = kdir
        self.state = kdir / "_settlement"
        self.queue_path = self.state / "queue.json"
        self.leases_path = self.state / "leases.json"
        self.usage_path = self.state / "usage.json"
        self.meta_path = self.state / "_meta.json"
        self.runs_dir = self.state / "runs"
        self.capabilities_path = Path(__file__).resolve().parent.parent / "adapters" / "capabilities.json"

    def ensure(self) -> None:
        self.state.mkdir(parents=True, exist_ok=True)
        self.runs_dir.mkdir(parents=True, exist_ok=True)
        if not self.queue_path.exists():
            self.save_queue({"version": VERSION, "items": []})
        if not self.leases_path.exists():
            self.save_leases({"version": VERSION, "leases": {}})
        if not self.usage_path.exists():
            self.save_usage({"version": VERSION, "day": utc_now()[:10], "jobs_started": 0, "runtime_seconds_reserved": 0})
        self.write_meta()

    def write_meta(self) -> None:
        data = {
            "version": VERSION,
            "state_dir": str(self.state),
            "shapes": {
                "queue_item": {
                    "id": "sha256(kind:work_item:source_id)",
                    "kind": "task-claim|omission|consumption-contradiction",
                    "status": "pending|leased",
                    "work_item": "slug",
                    "source_id": "source row's natural id (claim_id|candidate_id|contradiction_id)",
                    "source": {"file": "relative path", "line_range": "N-M"},
                    "selection": "pending items carry selection_score, selection_reason, batch_id; leased items also carry selected_at",
                },
                "lease": {"lease_id": "lease-<hash>", "item_id": "queue id", "run_id": "run id", "expires_at_epoch": "integer"},
                "run": {"run_id": "run-<hash>", "item_id": "queue id", "status": "completed|failed|blocked", "framework": "chosen harness"},
                "budget": {"day": "YYYY-MM-DD", "jobs_started": "integer", "runtime_seconds_reserved": "integer"},
            },
            "ownership_matrix": {
                "queue.json": ["settlement-queue.sh", "settlement-processor.py"],
                "leases.json": ["settlement-processor.py"],
                "usage.json": ["settlement-processor.py"],
                "runs/*.json": ["settlement-processor.py"],
                "_work/*/task-claims.jsonl": ["evidence-append.sh"],
                "_work/*/audit-candidates.jsonl": ["audit-queue-route.sh", "audit-artifact.sh", "audit-candidate-transition.sh"],
                "_work/*/consumption-contradictions.jsonl": ["consumption-contradiction-append.sh", "consumption-contradiction-update-status.sh"],
                "settings.json:settlement": ["settings.sh", "lore_settings.py", "operator"],
            },
        }
        json_dump(self.meta_path, data)

    def load_queue(self) -> dict[str, Any]:
        return json_load(self.queue_path, {"version": VERSION, "items": []})

    def save_queue(self, data: dict[str, Any]) -> None:
        data.setdefault("version", VERSION)
        data.setdefault("items", [])
        json_dump(self.queue_path, data)

    def load_leases(self) -> dict[str, Any]:
        return json_load(self.leases_path, {"version": VERSION, "leases": {}})

    def save_leases(self, data: dict[str, Any]) -> None:
        data.setdefault("version", VERSION)
        data.setdefault("leases", {})
        json_dump(self.leases_path, data)

    def load_usage(self) -> dict[str, Any]:
        usage = json_load(self.usage_path, {"version": VERSION, "day": utc_now()[:10], "jobs_started": 0, "runtime_seconds_reserved": 0})
        today = utc_now()[:10]
        if usage.get("day") != today:
            usage = {"version": VERSION, "day": today, "jobs_started": 0, "runtime_seconds_reserved": 0}
        usage.setdefault("runtime_seconds_reserved", 0)
        return usage

    def save_usage(self, data: dict[str, Any]) -> None:
        data.setdefault("version", VERSION)
        json_dump(self.usage_path, data)

    def item_id(self, work_item: str, source_id: str, kind: str = KIND_TASK_CLAIM) -> str:
        # The hash spans kind:work_item:source_id so two different streams can carry the
        # same natural id (e.g., a task-claim and an omission row each named "claim-0")
        # without colliding in queue.json.
        digest = hashlib.sha256(f"{kind}:{work_item}:{source_id}".encode()).hexdigest()[:20]
        return f"{kind}-{digest}"

    def row_change_context(self, row: dict[str, Any]) -> tuple[dict[str, Any] | None, str]:
        source = row.get("source") if isinstance(row.get("source"), dict) else {}
        file_path = row.get("file") or source.get("file")
        raw = row.get("change_context")
        if isinstance(raw, dict):
            changed_files = [
                str(v)
                for v in raw.get("changed_files", [])
                if isinstance(v, str) and v.strip()
            ] if isinstance(raw.get("changed_files"), list) else []
            summary = raw.get("summary") if isinstance(raw.get("summary"), str) else ""
            diff_ref = raw.get("diff_ref")
            if diff_ref is not None and not isinstance(diff_ref, str):
                diff_ref = None
            if changed_files and summary.strip():
                return {
                    "diff_ref": diff_ref,
                    "changed_files": list(dict.fromkeys(changed_files)),
                    "summary": summary.strip(),
                }, "row"
        if isinstance(file_path, str) and file_path.strip():
            summary = row.get("why_this_work_needs_it") or row.get("claim") or row.get("claim_text") or ""
            if isinstance(summary, str) and summary.strip():
                diff_ref = row.get("captured_at_sha") if isinstance(row.get("captured_at_sha"), str) else None
                return {
                    "diff_ref": diff_ref,
                    "changed_files": [file_path],
                    "summary": summary.strip(),
                }, "synthesized_from_legacy_row"
        return None, ""

    def task_claim_invalid_reason(self, work_item: str, row: dict[str, Any]) -> str:
        reasons: list[str] = []
        source = row.get("source") if isinstance(row.get("source"), dict) else {}
        checks = {
            "claim_id": row.get("claim_id"),
            "claim": row.get("claim") or row.get("claim_text"),
            "file": row.get("file") or source.get("file"),
            "line_range": row.get("line_range") or source.get("line_range"),
            "falsifier": row.get("falsifier") or row.get("why_this_work_needs_it"),
        }
        for field, value in checks.items():
            if not isinstance(value, str) or not value.strip():
                reasons.append(f"missing {field}")
        context, _source = self.row_change_context(row)
        if context is None:
            reasons.append("missing change_context")
        return f"_work/{work_item}/task-claims.jsonl: " + "; ".join(reasons) if reasons else ""

    def omission_invalid_reason(self, work_item: str, row: dict[str, Any]) -> str:
        # audit-candidates.jsonl rows are written by audit-queue-route.sh after
        # reverse-auditor + grounding-preflight; the producer already enforced
        # presence of file/line_range/falsifier. Re-check defensively here so a
        # malformed manual edit cannot drive the audit pipeline.
        reasons: list[str] = []
        for field in ("candidate_id", "file", "line_range", "falsifier"):
            value = row.get(field)
            if not isinstance(value, str) or not value.strip():
                reasons.append(f"missing {field}")
        return f"_work/{work_item}/audit-candidates.jsonl: " + "; ".join(reasons) if reasons else ""

    def consumption_contradiction_invalid_reason(self, work_item: str, row: dict[str, Any]) -> str:
        # consumption-contradiction-append.sh validates the row at write time;
        # this is a defensive re-check that follows the sole-writer schema.
        reasons: list[str] = []
        if not isinstance(row.get("contradiction_id"), str) or not row.get("contradiction_id").strip():
            reasons.append("missing contradiction_id")
        claim_payload = row.get("claim_payload") if isinstance(row.get("claim_payload"), dict) else None
        if claim_payload is None:
            reasons.append("missing claim_payload")
        else:
            for field in ("claim_id", "file", "line_range", "falsifier"):
                value = claim_payload.get(field)
                if not isinstance(value, str) or not value.strip():
                    reasons.append(f"missing claim_payload.{field}")
        return f"_work/{work_item}/consumption-contradictions.jsonl: " + "; ".join(reasons) if reasons else ""

    def commons_invalid_reason(self, work_item: str, row: dict[str, Any]) -> str:
        # promote-commons-append.sh validates the row at write time; this is a
        # defensive re-check. entry_path becomes mutation authority at flowback,
        # so reject any row whose target does not resolve to an existing commons
        # entry inside the store (escaping paths, deleted entries, typos).
        reasons: list[str] = []
        for field in ("claim_id", "claim", "falsifier", "scale", "entry_path"):
            value = row.get(field)
            if not isinstance(value, str) or not value.strip():
                reasons.append(f"missing {field}")
        related = row.get("related_files")
        if not isinstance(related, list) or not related:
            reasons.append("missing related_files")
        entry_path = row.get("entry_path")
        if isinstance(entry_path, str) and entry_path.strip():
            resolved = (self.kdir / entry_path).resolve()
            try:
                resolved.relative_to(self.kdir.resolve())
                inside = True
            except ValueError:
                inside = False
            if not inside:
                reasons.append("entry_path escapes knowledge store")
            elif not resolved.is_file():
                reasons.append("entry_path does not point at an existing entry")
        return f"_work/{work_item}/promoted-commons.jsonl: " + "; ".join(reasons) if reasons else ""

    def kind_invalid_reason(self, kind: str, work_item: str, row: dict[str, Any]) -> str:
        if kind == KIND_TASK_CLAIM:
            return self.task_claim_invalid_reason(work_item, row)
        if kind == KIND_OMISSION:
            return self.omission_invalid_reason(work_item, row)
        if kind == KIND_CONSUMPTION_CONTRADICTION:
            return self.consumption_contradiction_invalid_reason(work_item, row)
        if kind == KIND_COMMONS:
            return self.commons_invalid_reason(work_item, row)
        return f"unknown kind: {kind}"

    def source_id_for_row(self, kind: str, row: dict[str, Any]) -> str:
        field = KIND_SOURCES.get(kind, {}).get("id_field", "")
        if not field:
            return ""
        if kind == KIND_CONSUMPTION_CONTRADICTION:
            # contradiction_id lives at the row top level; the actual file/line
            # anchor sits inside claim_payload but the natural id is top-level.
            return str(row.get(field) or "")
        return str(row.get(field) or "")

    def item_from_row(self, work_item: str, row: dict[str, Any], order: int, kind: str = KIND_TASK_CLAIM) -> dict[str, Any]:
        if kind == KIND_TASK_CLAIM:
            claim_id = str(row.get("claim_id") or "")
            source = row.get("source") if isinstance(row.get("source"), dict) else {}
            context, context_source = self.row_change_context(row)
            item = {
                "id": self.item_id(work_item, claim_id, KIND_TASK_CLAIM),
                "kind": KIND_TASK_CLAIM,
                "status": "pending",
                "work_item": work_item,
                "source_id": claim_id,
                "claim_id": claim_id,
                "task_id": row.get("task_id"),
                "phase_id": row.get("phase_id"),
                "scale": row.get("scale"),
                "claim": row.get("claim") or row.get("claim_text"),
                "source": {"file": row.get("file") or source.get("file"), "line_range": row.get("line_range") or source.get("line_range")},
                "falsifier": row.get("falsifier") or row.get("why_this_work_needs_it"),
                "exact_snippet": row.get("exact_snippet"),
                "change_context": context,
                "change_context_source": context_source,
                "evidence_ref": {"path": f"_work/{work_item}/task-claims.jsonl", "claim_id": claim_id},
                "attempts": 0,
                "enqueued_at": row.get("captured_at") or row.get("created_at") or "",
                "updated_at": utc_now(),
                "_backlog_order": order,
            }
            return item
        if kind == KIND_OMISSION:
            candidate_id = str(row.get("candidate_id") or "")
            return {
                "id": self.item_id(work_item, candidate_id, KIND_OMISSION),
                "kind": KIND_OMISSION,
                "status": "pending",
                "work_item": work_item,
                "source_id": candidate_id,
                "candidate_id": candidate_id,
                "claim": row.get("rationale") or row.get("why_it_matters"),
                "source": {"file": row.get("file"), "line_range": row.get("line_range")},
                "falsifier": row.get("falsifier"),
                "evidence_ref": {"path": f"_work/{work_item}/audit-candidates.jsonl", "candidate_id": candidate_id},
                "attempts": 0,
                "enqueued_at": row.get("created_at") or "",
                "updated_at": utc_now(),
                "_backlog_order": order,
            }
        if kind == KIND_CONSUMPTION_CONTRADICTION:
            contradiction_id = str(row.get("contradiction_id") or "")
            claim_payload = row.get("claim_payload") if isinstance(row.get("claim_payload"), dict) else {}
            return {
                "id": self.item_id(work_item, contradiction_id, KIND_CONSUMPTION_CONTRADICTION),
                "kind": KIND_CONSUMPTION_CONTRADICTION,
                "status": "pending",
                "work_item": work_item,
                "source_id": contradiction_id,
                "contradiction_id": contradiction_id,
                "claim_id": claim_payload.get("claim_id"),
                "claim": claim_payload.get("claim_text"),
                "source": {"file": claim_payload.get("file"), "line_range": claim_payload.get("line_range")},
                "falsifier": claim_payload.get("falsifier"),
                "exact_snippet": claim_payload.get("exact_snippet"),
                "evidence_ref": {"path": f"_work/{work_item}/consumption-contradictions.jsonl", "contradiction_id": contradiction_id},
                "attempts": 0,
                "enqueued_at": row.get("created_at") or "",
                "updated_at": utc_now(),
                "_backlog_order": order,
            }
        if kind == KIND_COMMONS:
            claim_id = str(row.get("claim_id") or "")
            related = row.get("related_files") if isinstance(row.get("related_files"), list) else []
            return {
                "id": self.item_id(work_item, claim_id, KIND_COMMONS),
                "kind": KIND_COMMONS,
                "status": "pending",
                "work_item": work_item,
                "source_id": claim_id,
                "claim_id": claim_id,
                "scale": row.get("scale"),
                "claim": row.get("claim"),
                # entry_path is the flowback target — carried verbatim so the
                # terminus resolves the mutation entry without re-running search.
                "entry_path": row.get("entry_path"),
                "source": {"file": (related[0] if related else None), "line_range": None},
                "falsifier": row.get("falsifier"),
                "evidence_ref": {"path": f"_work/{work_item}/promoted-commons.jsonl", "claim_id": claim_id},
                "attempts": 0,
                "enqueued_at": "",
                "updated_at": utc_now(),
                "_backlog_order": order,
            }
        raise ValueError(f"unknown kind: {kind}")

    def enqueue_row(self, work_item: str, row: dict[str, Any], kind: str = KIND_TASK_CLAIM, selection_reason: str | None = None) -> dict[str, Any]:
        self.ensure()
        source_id = self.source_id_for_row(kind, row)
        if not source_id:
            id_field = KIND_SOURCES.get(kind, {}).get("id_field", "source_id")
            raise SystemExit(f"[settlement] Error: {kind} row missing {id_field}")
        invalid_reason = self.kind_invalid_reason(kind, work_item, row)
        if invalid_reason:
            raise ValueError(f"invalid {kind} row: {invalid_reason}")
        if kind == KIND_CONSUMPTION_CONTRADICTION:
            # Only `pending` CC rows are enqueue candidates. `verified`/`rejected`
            # are terminal states set by the update-status writer after a
            # correctness-gate verdict landed — re-enqueuing them would drive
            # duplicate adjudication. Legacy values (accepted/declined/remediated)
            # are not in the canonical enum any longer and were never wired
            # through any update path; skip defensively rather than fail.
            status = row.get("status")
            if status != "pending":
                return {"ok": True, "action": "skipped", "reason": f"non-pending status: {status}", "queue_path": str(self.queue_path)}
        item_id = self.item_id(work_item, source_id, kind)
        with repo_lock(self.state):
            queue = self.load_queue()
            for item in queue["items"]:
                if item.get("id") == item_id:
                    return {"ok": True, "action": "duplicate", "item": item, "queue_path": str(self.queue_path)}
            item = self.item_from_row(work_item, row, len(queue.get("items", [])), kind)
            item["enqueued_at"] = utc_now()
            item.pop("_backlog_order", None)
            if selection_reason:
                # Event-driven triggers stamp their reason at enqueue time so
                # (1) the legacy-pending-normalization branch in process_once
                # never recomputes over them, and (2) apply_recomputed_batch
                # preserves them through any census-mode recompute instead of
                # letting them fall outside the batch window.
                item["selection_reason"] = selection_reason
                item["selected_at"] = item["enqueued_at"]
            queue["items"].append(item)
            self.save_queue(queue)
            return {"ok": True, "action": "enqueued", "item": item, "queue_path": str(self.queue_path)}

    # --- Rollup queue helpers (D3, D6, D7, D11, D12) ---
    #
    # Rollup queue items aggregate the per-claim tier=reusable scorecard rows
    # written by audit-artifact.sh into per-(judge, template, window) tier=template
    # rows that /evolve's primary gate consumes. They are direct-enqueued under
    # repo_lock and never go through item_from_row / enqueue_row / KIND_SOURCES.

    @staticmethod
    def is_rollup_kind(kind: str) -> bool:
        return isinstance(kind, str) and kind.startswith("rollup-")

    @staticmethod
    def rollup_item_id(kind: str, judge: str, window_start: str) -> str:
        # D6 deterministic id derivation: sha256("{kind}|{judge}|{window_start}")[:20].
        # The whole hash IS the id (no prefix) so the dedupe scan in
        # enqueue_rollup_item just compares ids directly.
        return hashlib.sha256(f"{kind}|{judge}|{window_start}".encode()).hexdigest()[:20]

    @staticmethod
    def rollup_item_invalid_reason(item: dict[str, Any]) -> str:
        # Rollup items must carry kind, judge, window_start, window_end. No
        # work_item / source_id / source row — those belong to the source-row
        # KINDS (D6).
        reasons: list[str] = []
        kind = item.get("kind")
        if not Settlement.is_rollup_kind(str(kind or "")) or kind not in ROLLUP_KIND_TO_SCRIPT:
            reasons.append(f"unknown rollup kind: {kind}")
        for field in ("judge", "window_start", "window_end"):
            value = item.get(field)
            if not isinstance(value, str) or not value.strip():
                reasons.append(f"missing {field}")
        return "; ".join(reasons)

    def enqueue_rollup_item(self, kind: str, judge: str, window_start: str, window_end: str) -> dict[str, Any]:
        # D6: bypass item_from_row / enqueue_row entirely. Writes a direct-shaped
        # item under repo_lock. selection_reason="rollup_window" at enqueue time
        # so the legacy-pending-normalization branch in process_once does NOT
        # trigger a batch recompute for rollups (settlement-processor.py:1485).
        if kind not in ROLLUP_KIND_TO_SCRIPT:
            raise SystemExit(f"[settlement] Error: unknown rollup kind: {kind}")
        if not (isinstance(judge, str) and judge.strip()):
            raise SystemExit("[settlement] Error: enqueue_rollup_item requires non-empty judge")
        if not (isinstance(window_start, str) and window_start.strip()):
            raise SystemExit("[settlement] Error: enqueue_rollup_item requires window_start")
        if not (isinstance(window_end, str) and window_end.strip()):
            raise SystemExit("[settlement] Error: enqueue_rollup_item requires window_end")
        self.ensure()
        item_id = self.rollup_item_id(kind, judge, window_start)
        now = utc_now()
        item = {
            "id": item_id,
            "kind": kind,
            "status": "pending",
            "judge": judge,
            "window_start": window_start,
            "window_end": window_end,
            "attempts": 0,
            "enqueued_at": now,
            "updated_at": now,
            "selection_reason": "rollup_window",
        }
        with repo_lock(self.state):
            queue = self.load_queue()
            for existing in queue.get("items", []):
                if existing.get("id") == item_id:
                    return {"ok": True, "action": "duplicate", "item": existing, "queue_path": str(self.queue_path)}
            queue.setdefault("items", []).append(item)
            self.save_queue(queue)
        return {"ok": True, "action": "enqueued", "item": item, "queue_path": str(self.queue_path)}

    def tier_template_exists(self, judge: str, window_start: str) -> bool:
        # D11: existence check is a sequential read of _scorecards/rows.jsonl,
        # short-circuited on first match. If no match, ALSO consult
        # _settlement/runs/ for a completed rollup run record whose item_id
        # matches the deterministic rollup id for (kind, judge, window_start) —
        # empty completed windows emit zero rows but DO leave a completed run
        # record. Without that fallback the enqueuer would re-enqueue empty
        # windows forever.
        #
        # Cached within one scan() invocation via the lazy attribute populated
        # by _refresh_rollup_check_cache.
        cache = getattr(self, "_rollup_existence_cache", None)
        if cache is None:
            cache = self._refresh_rollup_existence_cache()
        rows = cache["template_rows"]
        for row in rows:
            if row.get("verdict_source") == judge and row.get("window_start") == window_start:
                return True
        run_ids = cache["completed_rollup_run_item_ids"]
        kind = ROLLUP_JUDGE_TO_KIND.get(judge)
        if kind:
            item_id = self.rollup_item_id(kind, judge, window_start)
            if item_id in run_ids:
                return True
        return False

    def _refresh_rollup_existence_cache(self) -> dict[str, Any]:
        template_rows: list[dict[str, Any]] = []
        rows_path = self.kdir / "_scorecards" / "rows.jsonl"
        if rows_path.exists():
            try:
                with rows_path.open(encoding="utf-8") as fh:
                    for line in fh:
                        line = line.strip()
                        if not line:
                            continue
                        try:
                            row = json.loads(line)
                        except json.JSONDecodeError:
                            continue
                        if not isinstance(row, dict):
                            continue
                        if row.get("tier") != "template":
                            continue
                        template_rows.append({
                            "verdict_source": row.get("verdict_source"),
                            "window_start": row.get("window_start"),
                        })
            except OSError:
                pass
        completed_item_ids: set[str] = set()
        if self.runs_dir.exists():
            for path in self.runs_dir.glob("*.json"):
                try:
                    run = json_load(path, {})
                except Exception:
                    continue
                if not isinstance(run, dict):
                    continue
                if run.get("invalidated_at") or run.get("invalidated"):
                    continue
                if run.get("status") != "completed":
                    continue
                if not self.is_rollup_kind(str(run.get("kind") or "")):
                    continue
                item_id = run.get("item_id")
                if isinstance(item_id, str) and item_id:
                    completed_item_ids.add(item_id)
        cache = {"template_rows": template_rows, "completed_rollup_run_item_ids": completed_item_ids}
        self._rollup_existence_cache = cache
        return cache

    def _invalidate_rollup_existence_cache(self) -> None:
        if hasattr(self, "_rollup_existence_cache"):
            try:
                delattr(self, "_rollup_existence_cache")
            except AttributeError:
                pass

    @staticmethod
    def completed_weekly_windows(weeks: int, now: datetime | None = None) -> list[tuple[str, str]]:
        # D12: completed Monday-to-Monday UTC windows. Half-open [W_start, W_end).
        # Returns oldest-first so the backfill enqueues with deterministic order.
        if weeks <= 0:
            return []
        if now is None:
            now = utc_now_dt()
        this_monday = monday_floor_utc(now)
        windows: list[tuple[str, str]] = []
        for i in range(weeks, 0, -1):
            start = this_monday - timedelta(weeks=i)
            end = start + timedelta(weeks=1)
            windows.append((iso_z(start), iso_z(end)))
        return windows

    @staticmethod
    def current_completed_weekly_window(now: datetime | None = None) -> tuple[str, str]:
        # D12: steady-state enqueuer targets the most recently COMPLETED week,
        # not the in-progress week. Enqueueing on the in-progress week makes
        # D11's existence check satisfy prematurely once the first tier=template
        # row lands, causing rows arriving later that week to never be aggregated.
        if now is None:
            now = utc_now_dt()
        this_monday = monday_floor_utc(now)
        end = this_monday
        start = end - timedelta(weeks=1)
        return iso_z(start), iso_z(end)

    def enqueue_rollup_backfill(self, weeks: int, judges: list[str] | None = None) -> dict[str, Any]:
        # D5+D12: one-shot loop over the N most recent COMPLETED weekly windows
        # for each judge; D11 existence check then enqueue_rollup_item.
        if weeks < 1:
            raise SystemExit("[settlement] Error: --weeks must be >= 1")
        if weeks > ROLLUP_BACKFILL_MAX_WEEKS:
            raise SystemExit(f"[settlement] Error: --weeks must be <= {ROLLUP_BACKFILL_MAX_WEEKS}")
        target_judges = list(judges) if judges else list(ROLLUP_JUDGES)
        for j in target_judges:
            if j not in ROLLUP_JUDGE_TO_KIND:
                raise SystemExit(f"[settlement] Error: unknown judge: {j}")
        self.ensure()
        self._invalidate_rollup_existence_cache()
        enqueued = 0
        duplicates = 0
        skipped_existing = 0
        windows = self.completed_weekly_windows(weeks)
        for judge in target_judges:
            kind = ROLLUP_JUDGE_TO_KIND[judge]
            for window_start, window_end in windows:
                if self.tier_template_exists(judge, window_start):
                    skipped_existing += 1
                    continue
                res = self.enqueue_rollup_item(kind, judge, window_start, window_end)
                if res["action"] == "enqueued":
                    enqueued += 1
                else:
                    duplicates += 1
        return {
            "ok": True,
            "enqueued": enqueued,
            "duplicates": duplicates,
            "skipped_existing": skipped_existing,
            "weeks": weeks,
            "judges": target_judges,
        }

    def scan_rollup_steady_state(self) -> dict[str, Any]:
        # D4+D11+D12: at the start of each scan cycle, for each of the 5 judges,
        # compute the most-recently-completed weekly window. Run D11's existence
        # check; on miss, enqueue. Five bounded checks per cycle.
        window_start, window_end = self.current_completed_weekly_window()
        enqueued = 0
        duplicates = 0
        skipped_existing = 0
        for judge in ROLLUP_JUDGES:
            kind = ROLLUP_JUDGE_TO_KIND[judge]
            if self.tier_template_exists(judge, window_start):
                skipped_existing += 1
                continue
            res = self.enqueue_rollup_item(kind, judge, window_start, window_end)
            if res["action"] == "enqueued":
                enqueued += 1
            else:
                duplicates += 1
        return {
            "enqueued": enqueued,
            "duplicates": duplicates,
            "skipped_existing": skipped_existing,
            "window_start": window_start,
            "window_end": window_end,
        }

    def scan(self) -> dict[str, Any]:
        # The census walk. Retired as an automatic driver (memo §5.2) but
        # RETAINED manually invocable: nothing calls this except an explicit
        # `lore settlement scan`. Dormant, not deleted — one evaluation window.
        self.ensure()
        # Refresh the rollup existence cache once per scan() invocation so
        # steady-state enqueuer checks share a single read of rows.jsonl and
        # _settlement/runs/.
        self._invalidate_rollup_existence_cache()
        self._refresh_rollup_existence_cache()
        scanned = 0
        enqueued = 0
        duplicates = 0
        errors: list[str] = []
        work_root = self.kdir / "_work"
        if not work_root.exists():
            rollup_summary = self.scan_rollup_steady_state()
            return {
                "ok": True,
                "scanned": 0,
                "enqueued": 0,
                "duplicates": 0,
                "errors": [],
                "rollup_enqueued": rollup_summary["enqueued"],
                "rollup_duplicates": rollup_summary["duplicates"],
                "rollup_skipped_existing": rollup_summary["skipped_existing"],
                "rollup_window_start": rollup_summary["window_start"],
                "rollup_window_end": rollup_summary["window_end"],
            }
        # Walk all three source streams. enqueue_row dispatches per-kind; CC
        # rows that are already terminal (verified|rejected) are quietly skipped.
        skipped = 0
        for kind in KINDS:
            filename = KIND_SOURCES[kind]["filename"]
            for source_file in sorted(work_root.glob(f"*/{filename}")):
                work_item = source_file.parent.name
                # Underscore-prefixed dirs (_archive, _index, ...) are
                # infrastructure, not work-item slugs. A stray source file at
                # the archive root would otherwise enqueue items whose
                # work_item is literally "_archive" — the audit script
                # fail-closes on those ("'_archive' is the archive root, not
                # a work-item slug"), burning a judge dispatch per scan.
                if work_item.startswith("_"):
                    continue
                with source_file.open(encoding="utf-8") as fh:
                    for line_no, line in enumerate(fh, 1):
                        if not line.strip():
                            continue
                        scanned += 1
                        try:
                            row = json.loads(line)
                            res = self.enqueue_row(work_item, row, kind)
                            if res["action"] == "enqueued":
                                enqueued += 1
                            elif res["action"] == "skipped":
                                skipped += 1
                            else:
                                duplicates += 1
                        except Exception as exc:  # continue scanning other rows
                            errors.append(f"{source_file}:{line_no}: {exc}")
        rollup_summary = self.scan_rollup_steady_state()
        return {
            "ok": not errors,
            "scanned": scanned,
            "enqueued": enqueued,
            "duplicates": duplicates,
            "skipped": skipped,
            "errors": errors,
            "rollup_enqueued": rollup_summary["enqueued"],
            "rollup_duplicates": rollup_summary["duplicates"],
            "rollup_skipped_existing": rollup_summary["skipped_existing"],
            "rollup_window_start": rollup_summary["window_start"],
            "rollup_window_end": rollup_summary["window_end"],
        }

    # --- Event-driven triggers (memo §5; the enqueue surface that replaces the census) ---
    #
    # Lifecycle: the pump runs on the TUI status tick (loadSettlementStatus in
    # tui/commands.go) and via manual `lore settlement triggers`; it self-throttles
    # to TRIGGER_PUMP_MIN_INTERVAL_SECONDS. It only ENQUEUES — dispatch stays with
    # process_once, driven by the TUI auto-process gate (pending items only in the
    # event-driven posture) and manual process/drain.

    @property
    def trust_ledger_path(self) -> Path:
        return self.kdir / "_trust" / "trust-events.jsonl"

    @staticmethod
    def _trust_compute_module():
        import importlib.util
        if "trust_compute" in sys.modules:
            return sys.modules["trust_compute"]
        path = Path(__file__).resolve().with_name("trust-compute.py")
        spec = importlib.util.spec_from_file_location("trust_compute", str(path))
        module = importlib.util.module_from_spec(spec)
        sys.modules["trust_compute"] = module
        spec.loader.exec_module(module)
        return module

    def read_verify_events(self) -> list[dict[str, Any]]:
        """All parseable consumption-verification rows from the trust ledger."""
        rows: list[dict[str, Any]] = []
        try:
            with self.trust_ledger_path.open(encoding="utf-8") as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        row = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if isinstance(row, dict) and row.get("event") == "consumption-verification":
                        rows.append(row)
        except FileNotFoundError:
            pass
        return rows

    def detect_disputes(self) -> dict[str, Any]:
        """Dispute gate.

        Inputs: contradicted consumption-verification ledger rows (joined to
        their bridged CC source row by payload work_item + contradiction_id),
        the published trust fold (trust-compute.py), the queue, and terminal
        run records.
        Route: a contradicted report against a high-trust entry
        (score >= HIGH_TRUST_THRESHOLD) or an entry with conflicting reports
        (held AND contradicted) enqueues its CC row through enqueue_row with
        selection_reason="dispute".
        Fallback: no ledger -> no-op; rows without the CC bridge fields are
        counted unroutable, never guessed; a trust-fold failure disables only
        the high-trust arm (reported as a warning) — the conflict arm still runs.
        Idempotency (two-layer): call-site skip on queue membership + terminal
        run records by deterministic item_id, then enqueue_row's own id dedupe
        and pending-only CC status check.
        """
        events = self.read_verify_events()
        if not events:
            return {"considered": 0, "enqueued": 0, "duplicates": 0, "unroutable": 0, "skipped": 0}
        scores: dict[str, dict] = {}
        migrations: dict[str, str] = {}
        warning = ""
        tc = None
        try:
            tc = self._trust_compute_module()
            scores, migrations, _w = tc.compute_trust(str(self.kdir))
        except Exception as exc:
            warning = f"trust fold unavailable; high-trust arm disabled: {exc}"

        dispositions: dict[str, set[str]] = {}
        for row in events:
            payload = row.get("payload") or {}
            entry = str(row.get("entry_path") or "")
            if entry:
                dispositions.setdefault(entry, set()).add(str(payload.get("disposition") or ""))

        queue_ids = {item.get("id") for item in self.load_queue().get("items", [])}
        terminal_ids = self.terminal_run_item_ids()

        considered = 0
        enqueued = 0
        duplicates = 0
        unroutable = 0
        skipped = 0
        for row in events:
            payload = row.get("payload") or {}
            if payload.get("disposition") != "contradicted":
                continue
            considered += 1
            entry = str(row.get("entry_path") or "")
            high_trust = False
            if tc is not None and entry:
                summary = tc.score_for_entry(scores, migrations, entry)
                high_trust = summary is not None and summary["score"] >= HIGH_TRUST_THRESHOLD
            conflicting = entry and {"held", "contradicted"} <= dispositions.get(entry, set())
            if not (high_trust or conflicting):
                skipped += 1
                continue
            work_item = str(payload.get("work_item") or "")
            contradiction_id = str(payload.get("contradiction_id") or "")
            if not work_item or not contradiction_id:
                unroutable += 1
                continue
            item_id = self.item_id(work_item, contradiction_id, KIND_CONSUMPTION_CONTRADICTION)
            if item_id in queue_ids or item_id in terminal_ids:
                duplicates += 1
                continue
            cc_row = self.find_source_row(KIND_CONSUMPTION_CONTRADICTION, work_item, contradiction_id)
            if cc_row is None:
                unroutable += 1
                continue
            try:
                res = self.enqueue_row(work_item, cc_row, KIND_CONSUMPTION_CONTRADICTION, selection_reason="dispute")
            except (ValueError, SystemExit):
                unroutable += 1
                continue
            if res["action"] == "enqueued":
                enqueued += 1
                queue_ids.add(item_id)
            else:
                duplicates += 1
        out = {
            "considered": considered,
            "enqueued": enqueued,
            "duplicates": duplicates,
            "unroutable": unroutable,
            "skipped": skipped,
        }
        if warning:
            out["warning"] = warning
        return out

    def spot_sample_week_start(self) -> str:
        return iso_z(monday_floor_utc(utc_now_dt()))

    def spot_sample_used_this_week(self) -> int:
        """Budget accounting: spot_sample enqueues this ISO week, from queue
        items plus (non-invalidated) run records — enqueue-time count, so a
        dispatched-and-completed sample still consumes budget."""
        week_start = self.spot_sample_week_start()
        used_ids: set[str] = set()
        for item in self.load_queue().get("items", []):
            if item.get("selection_reason") == "spot_sample" and str(item.get("enqueued_at") or "") >= week_start:
                used_ids.add(str(item.get("id")))
        for run in self.load_runs():
            if self.run_invalidated(run):
                continue
            selection = run.get("selection") if isinstance(run.get("selection"), dict) else {}
            if selection.get("reason") == "spot_sample" and str(selection.get("selected_at") or "") >= week_start:
                used_ids.add(str(run.get("item_id")))
        return len(used_ids)

    def spot_sample(self, settings: dict[str, Any]) -> dict[str, Any]:
        """Spot-sample gate — the memo §5.1 fallback dial (a throttled census).

        Inputs: settlement.dispatch.spot_sample_weekly_budget (visible dial),
        the source-stream backlog (iter_backlog_items — claim plumbing
        preserved as trigger intake), queue membership, and run records.
        Route: up to the remaining weekly budget of not-yet-audited candidates
        are enqueued with selection_reason="spot_sample"; sampling is seeded on
        the week start, so a re-run in the same week re-picks the same
        candidates and dedupes to a no-op.
        Fallback: budget 0 or exhausted -> legible skip reason, no enqueue.
        Idempotency (two-layer): call-site skip on queue membership + terminal
        run ids, then enqueue_row's id dedupe.
        """
        budget = int(settings["dispatch"]["spot_sample_weekly_budget"])
        week_start = self.spot_sample_week_start()
        if budget <= 0:
            return {"enqueued": 0, "budget": budget, "used_this_week": 0, "week_start": week_start, "reason": "budget_zero"}
        used = self.spot_sample_used_this_week()
        remaining = budget - used
        if remaining <= 0:
            return {"enqueued": 0, "budget": budget, "used_this_week": used, "week_start": week_start, "reason": "budget_exhausted"}
        backlog, _errors = self.iter_backlog_items()
        queue_ids = {item.get("id") for item in self.load_queue().get("items", [])}
        terminal_ids = self.terminal_run_item_ids()
        candidates = [item for item in backlog if item.get("id") not in queue_ids and item.get("id") not in terminal_ids]
        rng = random.Random(f"spot-sample|{week_start}")
        rng.shuffle(candidates)
        enqueued = 0
        duplicates = 0
        for candidate in candidates:
            if enqueued >= remaining:
                break
            kind = str(candidate.get("kind") or KIND_TASK_CLAIM)
            work_item = str(candidate.get("work_item") or "")
            source_id = str(candidate.get("source_id") or candidate.get("claim_id") or candidate.get("candidate_id") or candidate.get("contradiction_id") or "")
            row = self.find_source_row(kind, work_item, source_id)
            if row is None:
                continue
            try:
                res = self.enqueue_row(work_item, row, kind, selection_reason="spot_sample")
            except (ValueError, SystemExit):
                continue
            if res["action"] == "enqueued":
                enqueued += 1
            else:
                duplicates += 1
        return {
            "enqueued": enqueued,
            "duplicates": duplicates,
            "budget": budget,
            "used_this_week": used + enqueued,
            "week_start": week_start,
        }

    def verify_volume(self) -> dict[str, Any]:
        """Memo §5.3 volume measurement: weekly consumption-verification event
        counts from ledger observed_at, over the trailing evaluation window."""
        events = self.read_verify_events()
        now = utc_now_dt()
        current_week = monday_floor_utc(now)
        weeks: list[dict[str, Any]] = []
        for back in range(VERIFY_VOLUME_WINDOW_WEEKS, 0, -1):
            start = current_week - timedelta(weeks=back)
            end = start + timedelta(weeks=1)
            start_s, end_s = iso_z(start), iso_z(end)
            count = sum(1 for row in events if start_s <= str(row.get("observed_at") or "") < end_s)
            weeks.append({"week_start": start_s, "events": count})
        current_count = sum(1 for row in events if str(row.get("observed_at") or "") >= iso_z(current_week))
        avg = round(sum(w["events"] for w in weeks) / max(len(weeks), 1), 2)
        return {
            "weeks": weeks,
            "current_week_events": current_count,
            "window_weeks": VERIFY_VOLUME_WINDOW_WEEKS,
            "weekly_average": avg,
            "thin_threshold": VERIFY_VOLUME_THIN_THRESHOLD,
            "below_threshold": avg < VERIFY_VOLUME_THIN_THRESHOLD,
        }

    def pump_triggers(self, settings: dict[str, Any], force: bool = False) -> dict[str, Any]:
        """Run the three event-driven enqueue triggers: rollup steady-state
        (re-homed off scan(), memo §4.2(d) MOVE), the dispute detector, and
        the spot-sampler. Enqueue-only; throttled via queue.json's triggers
        block so the TUI's 5s status tick stays cheap."""
        self.ensure()
        mode = "census" if settings["dispatch"]["census_enabled"] else "event-driven"
        with repo_lock(self.state):
            queue = self.load_queue()
            triggers_state = queue.get("triggers") if isinstance(queue.get("triggers"), dict) else {}
            last = str(triggers_state.get("pump_ran_at") or "")
            if not force and last:
                try:
                    last_dt = datetime.fromisoformat(last.replace("Z", "+00:00"))
                    if (datetime.now(timezone.utc) - last_dt).total_seconds() < TRIGGER_PUMP_MIN_INTERVAL_SECONDS:
                        return {"ok": True, "ran": False, "reason": "throttled", "pump_ran_at": last, "dispatch_mode": mode}
                except ValueError:
                    pass
            queue["triggers"] = {"pump_ran_at": utc_now()}
            self.save_queue(queue)
        self._invalidate_rollup_existence_cache()
        self._refresh_rollup_existence_cache()
        rollup = self.scan_rollup_steady_state()
        disputes = self.detect_disputes()
        sample = self.spot_sample(settings)
        return {
            "ok": True,
            "ran": True,
            "dispatch_mode": mode,
            "rollup": rollup,
            "disputes": disputes,
            "spot_sample": sample,
            "verify_volume": self.verify_volume(),
        }

    def iter_backlog_items(self) -> tuple[list[dict[str, Any]], list[str]]:
        errors: list[str] = []
        items: list[dict[str, Any]] = []
        seen: set[str] = set()
        work_root = self.kdir / "_work"
        if not work_root.exists():
            return items, errors
        order = 0
        for kind in KINDS:
            filename = KIND_SOURCES[kind]["filename"]
            for source_file in sorted(work_root.glob(f"*/{filename}")):
                work_item = source_file.parent.name
                # Mirror the scan() guard: underscore-prefixed dirs are not
                # work-item slugs (see scan()).
                if work_item.startswith("_"):
                    continue
                try:
                    lines = source_file.read_text(encoding="utf-8").splitlines()
                except OSError as exc:
                    errors.append(f"{source_file}: {exc}")
                    continue
                for line_no, line in enumerate(lines, 1):
                    if not line.strip():
                        continue
                    try:
                        row = json.loads(line)
                        source_id = self.source_id_for_row(kind, row)
                        if not source_id:
                            id_field = KIND_SOURCES[kind]["id_field"]
                            raise ValueError(f"{kind} row missing {id_field}")
                        invalid_reason = self.kind_invalid_reason(kind, work_item, row)
                        if invalid_reason:
                            raise ValueError(f"invalid {kind} row: {invalid_reason}")
                        if kind == KIND_CONSUMPTION_CONTRADICTION and row.get("status") != "pending":
                            # Already-settled CC rows are not backlog candidates.
                            continue
                        item = self.item_from_row(work_item, row, order, kind)
                        item["evidence_ref"]["line"] = line_no
                        order += 1
                        if item["id"] in seen:
                            continue
                        seen.add(item["id"])
                        items.append(item)
                    except Exception as exc:
                        errors.append(f"{source_file}:{line_no}: {exc}")
        return items, errors

    def load_runs(self) -> list[dict[str, Any]]:
        runs: list[dict[str, Any]] = []
        if not self.runs_dir.exists():
            return runs
        for path in sorted(self.runs_dir.glob("*.json")):
            try:
                run = json_load(path, {})
                if isinstance(run, dict):
                    run.setdefault("run_ref", f"_settlement/runs/{path.name}")
                    runs.append(run)
            except Exception:
                continue
        return runs

    def recent_runs(self, limit: int = STATUS_RECENT_RUNS_LIMIT) -> list[dict[str, Any]]:
        runs: list[dict[str, Any]] = []
        if not self.runs_dir.exists() or limit <= 0:
            return runs
        entries: list[tuple[float, str, str]] = []
        try:
            scanner = os.scandir(self.runs_dir)
        except OSError:
            return runs
        with scanner as it:
            for entry in it:
                name = entry.name
                if not name.endswith(".json") or name.startswith("."):
                    continue
                try:
                    stat = entry.stat()
                except OSError:
                    continue
                if not (entry.is_file(follow_symlinks=False) or entry.is_symlink()):
                    continue
                entries.append((stat.st_mtime, name, entry.path))
        if not entries:
            return runs
        top = heapq.nlargest(limit, entries, key=lambda row: (row[0], row[1]))
        for _mtime, name, path_str in top:
            try:
                run = json_load(Path(path_str), {})
            except Exception:
                continue
            if isinstance(run, dict):
                run.setdefault("run_ref", f"_settlement/runs/{name}")
                runs.append(run)
        return runs

    def run_invalidated(self, run: dict[str, Any]) -> bool:
        return bool(run.get("invalidated_at") or run.get("invalidated"))

    def terminal_run_item_ids(self) -> set[str]:
        return {str(run.get("item_id")) for run in self.load_runs() if not self.run_invalidated(run) and run.get("status") in TERMINAL and run.get("item_id")}

    def terminal_items_from_runs(self, limit: int = STATUS_TERMINAL_PREVIEW_LIMIT) -> list[dict[str, Any]]:
        out: list[dict[str, Any]] = []
        for run in self.recent_runs(STATUS_RECENT_RUNS_LIMIT):
            if self.run_invalidated(run):
                continue
            if run.get("status") not in TERMINAL:
                continue
            verdict = run.get("verdict") if isinstance(run.get("verdict"), dict) else {}
            verdict_label = verdict.get("verdict") if isinstance(verdict.get("verdict"), str) else ""
            verdict_summary = verdict.get("evidence") if isinstance(verdict.get("evidence"), str) else ""
            correction = verdict.get("correction") if isinstance(verdict.get("correction"), str) else None
            correction_outcome = run.get("correction_outcome") if isinstance(run.get("correction_outcome"), dict) else None
            run_kind = str(run.get("kind") or KIND_TASK_CLAIM)
            run_source_id = str(run.get("source_id") or run.get("claim_id") or "")
            row = self.find_source_row(run_kind, str(run.get("work_item") or ""), run_source_id) or {}
            source = row.get("source") if isinstance(row.get("source"), dict) else {}
            item: dict[str, Any] = {
                "id": run.get("item_id"),
                "kind": run_kind,
                "status": run.get("status"),
                "work_item": run.get("work_item"),
                "claim_id": run.get("claim_id"),
                "claim": run.get("claim") or row.get("claim"),
                "source": run.get("source") or {"file": row.get("file") or source.get("file"), "line_range": row.get("line_range") or source.get("line_range")},
                "falsifier": run.get("falsifier") or row.get("falsifier") or row.get("why_this_work_needs_it"),
                "run_id": run.get("run_id"),
                "verdict": verdict,
                "verdict_label": verdict_label,
                "verdict_summary": verdict_summary,
                "correction": correction,
                "result": {
                    "run_ref": f"_settlement/runs/{run.get('run_id')}.json",
                    "verdict_ref": run.get("verdict_ref"),
                    "correction_ref": run.get("correction_ref"),
                    "reason": run.get("reason"),
                    "verdict": verdict,
                    "verdict_label": verdict_label,
                    "summary": verdict_summary,
                    "correction": correction,
                },
                "selection": run.get("selection"),
                "completed_at": run.get("completed_at"),
            }
            if correction_outcome is not None:
                item["correction_outcome"] = correction_outcome
            out.append(item)
        out.sort(key=lambda item: str(item.get("completed_at") or ""), reverse=True)
        return out[:limit]

    def item_invalid_reason(self, item: dict[str, Any]) -> str:
        kind = str(item.get("kind") or KIND_TASK_CLAIM)
        if self.is_rollup_kind(kind):
            # Rollup items have no work_item / source_id; valid shape is just
            # {kind, judge, window_start, window_end} (D6). MUST short-circuit
            # before the work_item/source_id check below.
            return self.rollup_item_invalid_reason(item)
        work_item = str(item.get("work_item") or "")
        source_id = str(item.get("source_id") or item.get("claim_id") or item.get("candidate_id") or item.get("contradiction_id") or "")
        if not work_item or not source_id:
            return "queue item missing work_item or source_id"
        row = self.find_source_row(kind, work_item, source_id)
        if row is None:
            # The row went away after enqueue (work item archived between scan
            # and process). For task-claim, fall back to validating the item's
            # own embedded fields — otherwise mark the queue item invalid.
            if kind == KIND_TASK_CLAIM:
                item_row = {
                    "claim_id": source_id,
                    "claim": item.get("claim"),
                    "file": (item.get("source") or {}).get("file") if isinstance(item.get("source"), dict) else None,
                    "line_range": (item.get("source") or {}).get("line_range") if isinstance(item.get("source"), dict) else None,
                    "falsifier": item.get("falsifier"),
                    "change_context": item.get("change_context"),
                }
                item_reason = self.task_claim_invalid_reason(work_item, item_row)
                if not item_reason:
                    return ""
            return f"missing source row for {kind} {work_item}/{source_id}"
        return self.kind_invalid_reason(kind, work_item, row)

    def write_invalid_claim_run(self, item: dict[str, Any], reason: str) -> dict[str, Any]:
        run_id = f"run-{hashlib.sha256((str(item.get('id') or '') + utc_now()).encode()).hexdigest()[:20]}"
        evidence = f"invalid Tier 2 claim skipped before executor: {reason}"
        if len(evidence) > 240:
            evidence = evidence[:237] + "..."
        item_kind = str(item.get("kind") or KIND_TASK_CLAIM)
        item_source_id = str(item.get("source_id") or item.get("claim_id") or item.get("candidate_id") or item.get("contradiction_id") or "")
        run = {
            "version": VERSION,
            "run_id": run_id,
            "item_id": item.get("id"),
            "kind": item_kind,
            "source_id": item_source_id,
            "work_item": item.get("work_item"),
            "claim_id": item.get("claim_id"),
            "claim": item.get("claim"),
            "source": item.get("source"),
            "falsifier": item.get("falsifier"),
            "framework": "",
            "framework_capability": {},
            "status": "completed",
            "reason": f"invalid_{item_kind.replace('-', '_')}",
            "started_at": utc_now(),
            "completed_at": utc_now(),
            "runtime_seconds_reserved": 0,
            "verdict": {
                "claim_id": item.get("claim_id"),
                "verdict": "skipped",
                "evidence": evidence,
                "correction": None,
                "verdict_format": "preflight",
            },
            "verdict_ref": f"_settlement/runs/{run_id}.json#verdict",
            "correction_ref": None,
            "selection": self.selection_block(item),
        }
        return self.write_run_record_once(run)

    def retryable_infrastructure_failure_reason(self, run: dict[str, Any]) -> str:
        if self.run_invalidated(run):
            return ""
        if run.get("status") == "blocked" and run.get("reason") == "executor_timeout":
            return "previous_executor_timeout"
        if run.get("status") not in {"completed", "failed"}:
            return ""
        verdict = run.get("verdict")
        if not isinstance(verdict, dict):
            return ""
        if verdict.get("verdict_format") == "envelope" and verdict.get("verdict") == "error":
            return "previous_audit_error"
        # Skips emitted because the executor couldn't find the work-item artifact
        # (typical cause: the work item was archived between enqueue and process)
        # are infrastructure failures, not real "nothing-to-audit" outcomes. The
        # executor now falls back to _archive/, so a retry should succeed.
        if (
            verdict.get("verdict_format") == "envelope"
            and verdict.get("verdict") == "skipped"
            and str(verdict.get("evidence") or "").startswith("no auditable artifact")
        ):
            return "previous_artifact_unresolved"
        return ""

    def find_source_row(self, kind: str, work_item: str, source_id: str) -> dict[str, Any] | None:
        # Try the active work directory first, then fall back to the archive.
        # Archived work items retain their source JSONL under _archive/<slug>/,
        # so retries for queue items orphaned by archival can still resolve.
        filename = KIND_SOURCES.get(kind, {}).get("filename", "")
        id_field = KIND_SOURCES.get(kind, {}).get("id_field", "")
        if not filename or not id_field:
            return None
        candidates = [
            (self.kdir / "_work" / work_item / filename, f"_work/{work_item}/{filename}"),
            (self.kdir / "_work" / "_archive" / work_item / filename, f"_work/_archive/{work_item}/{filename}"),
        ]
        for path, rel_path in candidates:
            if not path.exists():
                continue
            try:
                lines = path.read_text(encoding="utf-8").splitlines()
            except OSError:
                continue
            for line_no, line in enumerate(lines, 1):
                if not line.strip():
                    continue
                try:
                    row = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(row, dict):
                    continue
                if str(row.get(id_field) or "") == source_id:
                    row = dict(row)
                    row.setdefault("evidence_ref", {"path": rel_path, "line": line_no})
                    return row
        return None

    def find_task_claim_row(self, work_item: str, claim_id: str) -> dict[str, Any] | None:
        # Back-compat shim for code paths that still take a (work_item, claim_id)
        # pair directly (the run-records path that always emits kind=task-claim).
        return self.find_source_row(KIND_TASK_CLAIM, work_item, claim_id)

    def retry_error_audits(self, work_item: str | None = None, claim_ids: list[str] | None = None, dry_run: bool = False) -> dict[str, Any]:
        self.ensure()
        claim_filter = set(claim_ids or [])
        with repo_lock(self.state):
            queue = self.load_queue()
            leases = self.load_leases()
            active_item_ids = {str(lease.get("item_id")) for lease in leases.get("leases", {}).values() if lease.get("state") == "active"}
            queued_item_ids = {str(item.get("id")) for item in queue.get("items", []) if item.get("status") in {"pending", "leased"}}
            latest_by_item: dict[str, dict[str, Any]] = {}
            for run in sorted(self.load_runs(), key=lambda r: str(r.get("completed_at") or r.get("started_at") or "")):
                if self.run_invalidated(run):
                    continue
                if run.get("status") not in TERMINAL or not run.get("item_id"):
                    continue
                latest_by_item[str(run.get("item_id"))] = run

            targets: list[tuple[dict[str, Any], dict[str, Any], str, str]] = []
            skipped: list[dict[str, Any]] = []
            for run in latest_by_item.values():
                retry_reason = self.retryable_infrastructure_failure_reason(run)
                if not retry_reason:
                    continue
                run_work_item = str(run.get("work_item") or "")
                run_kind = str(run.get("kind") or KIND_TASK_CLAIM)
                run_source_id = str(run.get("source_id") or run.get("claim_id") or "")
                item_id = str(run.get("item_id") or "")
                if work_item and run_work_item != work_item:
                    continue
                if claim_filter and run_source_id not in claim_filter:
                    continue
                if item_id in active_item_ids:
                    skipped.append({"run_id": run.get("run_id"), "item_id": item_id, "reason": "active_lease"})
                    continue
                if item_id in queued_item_ids:
                    skipped.append({"run_id": run.get("run_id"), "item_id": item_id, "reason": "already_queued"})
                    continue
                row = self.find_source_row(run_kind, run_work_item, run_source_id)
                if row is None:
                    skipped.append({"run_id": run.get("run_id"), "item_id": item_id, "reason": f"missing_{run_kind.replace('-', '_')}"})
                    continue
                targets.append((run, row, retry_reason, run_kind))

            retry_items: list[dict[str, Any]] = []
            batch_id = f"retry-{hashlib.sha256((utc_now() + str(len(targets))).encode()).hexdigest()[:16]}"
            recomputed_at = utc_now()
            for order, (run, row, retry_reason, run_kind) in enumerate(targets):
                item = self.item_from_row(str(run.get("work_item") or ""), row, order, run_kind)
                item["enqueued_at"] = recomputed_at
                item["updated_at"] = recomputed_at
                item["selection_score"] = None
                item["selection_reason"] = "retry_infrastructure_failure"
                item["batch_id"] = batch_id
                item["retry_of_run_id"] = run.get("run_id")
                item["retry_reason"] = retry_reason
                item.pop("_backlog_order", None)
                retry_items.append(item)

            if not dry_run and retry_items:
                leased = [item for item in queue.get("items", []) if item.get("status") == "leased"]
                pending = [item for item in queue.get("items", []) if item.get("status") == "pending" and item.get("id") not in {ri.get("id") for ri in retry_items}]
                queue["items"] = leased + retry_items + pending
                queue["batch"] = {
                    "id": batch_id,
                    "recomputed_at": recomputed_at,
                    "size": len([item for item in queue["items"] if item.get("status") == "pending"]),
                    "backlog_size": len(retry_items) + len(pending),
                    "recompute_reason": "retry_error_audits",
                    "errors": [],
                }
                for run, _row, retry_reason, _kind in targets:
                    run["invalidated_at"] = recomputed_at
                    run["invalidated_reason"] = "retry_infrastructure_failure"
                    run["invalidated_detail"] = retry_reason
                    run["retry_batch_id"] = batch_id
                    json_dump(self.run_path(str(run["run_id"])), run)
                self.save_queue(queue)

            return {
                "ok": True,
                "dry_run": dry_run,
                "matched": len(targets),
                "invalidated": 0 if dry_run else len(retry_items),
                "enqueued": 0 if dry_run else len(retry_items),
                "batch_id": batch_id if targets else "",
                "items": retry_items,
                "skipped": skipped,
            }

    def last_settled(self) -> dict[str, Any] | None:
        items = self.terminal_items_from_runs(limit=1)
        return items[0] if items else None

    def run_path(self, run_id: str) -> Path:
        return self.runs_dir / f"{run_id}.json"

    def write_run_record_once(self, run: dict[str, Any]) -> dict[str, Any]:
        self.runs_dir.mkdir(parents=True, exist_ok=True)
        path = self.run_path(str(run["run_id"]))
        if path.exists():
            existing = json_load(path, {})
            return existing if isinstance(existing, dict) else run
        json_dump(path, run)
        return run

    def write_run_correction_outcome_once(self, run_id: str, outcome: dict[str, Any]) -> dict[str, Any]:
        """Identity-verified read-modify-write of `correction_outcome` on the
        existing run record. Idempotent: if the field is already present, the
        existing value wins (matching `write_run_record_once` semantics).
        """
        path = self.run_path(str(run_id))
        if not path.exists():
            return outcome
        existing = json_load(path, {})
        if not isinstance(existing, dict):
            return outcome
        if existing.get("run_id") != run_id:
            return outcome
        if isinstance(existing.get("correction_outcome"), dict):
            return existing["correction_outcome"]
        existing["correction_outcome"] = outcome
        json_dump(path, existing)
        return outcome

    def selection_block(self, item: dict[str, Any]) -> dict[str, Any]:
        block = {
            "batch_id": item.get("batch_id"),
            "score": item.get("selection_score"),
            "reason": item.get("selection_reason"),
            "selected_at": item.get("selected_at"),
        }
        if "selection_signals" in item:
            block["signals"] = item.get("selection_signals")
        return block

    def heal_queue(self, queue: dict[str, Any], leases: dict[str, Any]) -> int:
        healed = 0
        terminal_ids = self.terminal_run_item_ids()
        active_item_ids = {str(lease.get("item_id")) for lease in leases.get("leases", {}).values() if lease.get("state") == "active"}
        new_items: list[dict[str, Any]] = []
        for item in queue.get("items", []):
            status = item.get("status")
            if item.get("id") in terminal_ids:
                for lease in leases.get("leases", {}).values():
                    if lease.get("item_id") == item.get("id") and lease.get("state") == "active":
                        lease["state"] = "released"
                        lease["released_at"] = utc_now()
                healed += 1
                continue
            if status in TERMINAL:
                run_id = str(item.get("run_id") or f"run-{hashlib.sha256((item.get('id', '') + str(item.get('updated_at', ''))).encode()).hexdigest()[:20]}")
                run = {
                    "version": VERSION,
                    "run_id": run_id,
                    "item_id": item.get("id"),
                    "work_item": item.get("work_item"),
                    "claim_id": item.get("claim_id"),
                    "framework": item.get("framework", ""),
                    "framework_capability": {},
                    "status": status,
                    "reason": (item.get("result") or {}).get("reason") or "legacy_terminal_queue_item",
                    "started_at": item.get("selected_at") or item.get("updated_at") or utc_now(),
                    "completed_at": item.get("updated_at") or utc_now(),
                    "runtime_seconds_reserved": 0,
                    "verdict": {"claim_id": item.get("claim_id"), "verdict": status, "evidence": "migrated from legacy terminal queue item", "correction": None, "verdict_format": "legacy"},
                    "verdict_ref": f"_settlement/runs/{run_id}.json#verdict",
                    "correction_ref": None,
                    "selection": self.selection_block(item),
                }
                self.write_run_record_once(run)
                healed += 1
                continue
            if status == "leased" or item.get("id") in active_item_ids:
                new_items.append(item)
                continue
            if status == "pending":
                new_items.append(item)
        if healed:
            queue["items"] = new_items
        return healed

    def should_recompute(self, queue: dict[str, Any], settings: dict[str, Any], force: bool = False) -> bool:
        if force:
            return True
        min_interval = int(settings["batch_recompute_min_interval_seconds"])
        if min_interval <= 0:
            return True
        raw = queue.get("batch", {}).get("recomputed_at") if isinstance(queue.get("batch"), dict) else None
        if not isinstance(raw, str) or not raw:
            return True
        try:
            last = datetime.fromisoformat(raw.replace("Z", "+00:00"))
        except ValueError:
            return True
        return (datetime.now(timezone.utc) - last).total_seconds() >= min_interval

    def active_batch_drained_with_backlog(self, queue: dict[str, Any]) -> bool:
        batch = queue.get("batch") if isinstance(queue.get("batch"), dict) else {}
        try:
            backlog_size = int(batch.get("backlog_size") or 0)
        except (TypeError, ValueError):
            backlog_size = 0
        if backlog_size <= 0:
            return False
        return not any(item.get("status") in {"pending", "leased"} for item in queue.get("items", []))

    def score_item(self, item: dict[str, Any]) -> tuple[float | None, str, dict[str, Any] | None]:
        if os.environ.get("LORE_SETTLEMENT_RELEVANCE_DISABLED") == "1":
            return None, "fallback_fifo", None
        hook = os.environ.get("LORE_SETTLEMENT_SCORE_HOOK", "").strip()
        if not hook:
            return None, "fallback_fifo", None
        try:
            proc = subprocess.run(
                shlex.split(hook),
                input=compact(item),
                text=True,
                capture_output=True,
                timeout=5,
                check=False,
            )
            if proc.returncode != 0:
                return None, "fallback_error", {"exit": proc.returncode, "stderr_tail": proc.stderr[-500:]}
            raw = json.loads(proc.stdout or "null")
            score = raw.get("score") if isinstance(raw, dict) else raw
            return float(score), "relevance", raw if isinstance(raw, dict) else None
        except Exception as exc:
            return None, "fallback_error", {"error": str(exc)}

    def apply_recomputed_batch(self, queue: dict[str, Any], settings: dict[str, Any], reason: str) -> dict[str, Any]:
        active_leased = [item for item in queue.get("items", []) if item.get("status") == "leased"]
        legacy_pending = [item for item in queue.get("items", []) if item.get("status") == "pending"]
        # Rollup items are direct-enqueued and have no source row to recompute
        # from (D6); they must be preserved through batch recompute unchanged
        # (no selection_reason pop, no score_item pass). Event-trigger items
        # (dispute / spot_sample) get the same protection: they were selected
        # by their gate, not by batch scoring, and a census-mode recompute
        # must not strand them outside the batch window.
        def _preserved(item: dict[str, Any]) -> bool:
            return self.is_rollup_kind(str(item.get("kind") or "")) or item.get("selection_reason") in EVENT_TRIGGER_REASONS

        legacy_pending_rollup = [item for item in legacy_pending if _preserved(item)]
        legacy_pending_source = [item for item in legacy_pending if not _preserved(item)]
        preserved_ids = {item.get("id") for item in active_leased}
        preserved_ids.update(item.get("id") for item in legacy_pending_rollup)
        terminal_ids = self.terminal_run_item_ids()
        backlog, errors = self.iter_backlog_items()
        backlog_ids = {item.get("id") for item in backlog}
        for item in legacy_pending_source:
            if item.get("id") in backlog_ids:
                continue
            clone = dict(item)
            clone["_backlog_order"] = len(backlog)
            clone.pop("selection_score", None)
            clone.pop("selection_reason", None)
            clone.pop("batch_id", None)
            clone.pop("selected_at", None)
            backlog.append(clone)
        candidates = [item for item in backlog if item.get("id") not in preserved_ids and item.get("id") not in terminal_ids]
        batch_size = int(settings["batch_size"])
        score_window = candidates[:batch_size]
        scored: list[dict[str, Any]] = []
        batch_id = f"batch-{hashlib.sha256((utc_now() + str(len(backlog))).encode()).hexdigest()[:16]}"
        recomputed_at = utc_now()
        for candidate in score_window:
            score, selection_reason, signals = self.score_item(candidate)
            candidate["selection_score"] = score
            candidate["selection_reason"] = selection_reason
            candidate["batch_id"] = batch_id
            candidate["_sort_score"] = -score if score is not None else 0.0
            if signals is not None and (os.environ.get("LORE_SETTLEMENT_DEBUG_SIGNALS") == "1" or selection_reason in {"fallback_error", "degraded"}):
                candidate["selection_signals"] = signals
            scored.append(candidate)
        scored.sort(key=lambda item: (item["_sort_score"], int(item.get("_backlog_order", 0)), str(item.get("id"))))
        pending: list[dict[str, Any]] = []
        for item in scored:
            item.pop("_sort_score", None)
            item.pop("_backlog_order", None)
            pending.append(item)
        # Rollup items go AFTER source-row pending: source-row items represent
        # real-time audits with stricter time pressure; rollups are weekly
        # aggregations that are intentionally cold-path. Preserving the rollup
        # items unchanged (no score, no reason rewrite) is what matters for
        # D6 isolation — their position relative to source-row items can be
        # last without weakening that invariant.
        queue["items"] = active_leased + pending + legacy_pending_rollup
        queue["batch"] = {
            "id": batch_id,
            "recomputed_at": recomputed_at,
            "size": len(pending),
            "backlog_size": len(candidates),
            "recompute_reason": reason,
            "errors": errors,
        }
        return queue["batch"]

    def recompute_queue(self, settings: dict[str, Any], reason: str = "recompute", force: bool = False) -> dict[str, Any]:
        self.ensure()
        if not settings["dispatch"]["census_enabled"]:
            # Recompute rebuilds pending from the full source-stream backlog —
            # a census-wide enqueue. Refuse legibly in the event-driven posture
            # rather than quietly running it; re-enabling the dormant census
            # (settlement.dispatch.census_enabled=true) is the sanctioned path.
            return {"ok": True, "recomputed": False, "reason": "census_disabled", "dispatch_mode": "event-driven"}
        with repo_lock(self.state):
            queue = self.load_queue()
            leases = self.load_leases()
            healed = self.heal_queue(queue, leases)
            if not self.should_recompute(queue, settings, force=force):
                if healed:
                    self.save_queue(queue)
                return {"ok": True, "recomputed": False, "reason": "throttled", "healed": healed, "batch": queue.get("batch", {})}

            self.apply_recomputed_batch(queue, settings, reason)
            self.save_queue(queue)
            return {"ok": True, "recomputed": True, "reason": reason, "healed": healed, "batch": queue["batch"]}

    def expire_stale_leases(self, queue: dict[str, Any], leases: dict[str, Any]) -> int:
        current = now_epoch()
        expired = 0
        by_id = {item["id"]: item for item in queue.get("items", [])}
        for lease_id, lease in list(leases.get("leases", {}).items()):
            if lease.get("state") != "active":
                continue
            if int(lease.get("expires_at_epoch") or 0) > current:
                continue
            lease["state"] = "expired"
            lease["expired_at"] = utc_now()
            item = by_id.get(lease.get("item_id"))
            if item and item.get("status") == "leased" and item.get("lease_id") == lease_id:
                item["status"] = "pending"
                item["updated_at"] = utc_now()
                item["reclaimed_from_lease"] = lease_id
                expired += 1
        return expired

    def status(self, settings: dict[str, Any]) -> dict[str, Any]:
        queue = self.load_queue()
        leases = self.load_leases()
        usage = self.load_usage()
        current = now_epoch()
        stale_active = sum(
            1
            for v in leases.get("leases", {}).values()
            if v.get("state") == "active" and int(v.get("expires_at_epoch") or 0) <= current
        )
        counts: dict[str, int] = {}
        for item in queue.get("items", []):
            counts[item.get("status", "unknown")] = counts.get(item.get("status", "unknown"), 0) + 1
        active_lease_rows = [v for v in leases.get("leases", {}).values() if v.get("state") == "active"]
        pending_count = counts.get("pending", 0)
        terminal_items = self.terminal_items_from_runs()
        last_settled = terminal_items[0] if terminal_items else None
        for terminal in TERMINAL:
            counts.pop(terminal, None)
        budget = self.budget_status(usage)
        active_hours = self.active_hours_status(settings)
        eligible, rejected = self.eligible_frameworks(settings)
        census = bool(settings["dispatch"]["census_enabled"])
        # The drained-batch backlog only feeds dispatch under the census
        # posture; in the event-driven posture a stale backlog_size must not
        # advertise work that no longer auto-refills.
        backlog_waiting = census and self.active_batch_drained_with_backlog(queue)
        blocked_reason = ""
        if not settings["enabled"]:
            blocked_reason = "disabled"
        elif not active_hours["allowed"]:
            blocked_reason = active_hours["reason"]
        elif not eligible:
            blocked_reason = "no_eligible_harnesses"
        elif len(active_lease_rows) >= int(settings["max_concurrency"]):
            blocked_reason = "max_concurrency_reached"
        next_action = "idle"
        if blocked_reason:
            next_action = f"blocked: {blocked_reason}"
        elif pending_count > 0 or backlog_waiting:
            next_action = "process once or wait for processor"
        elif active_lease_rows:
            next_action = "processor active"
        elif not census:
            next_action = "idle (event-driven: triggers enqueue disputes/samples)"
        return {
            "ok": True,
            "enabled": bool(settings["enabled"]),
            "dispatch": {
                "mode": "census" if census else "event-driven",
                "census_enabled": census,
                "spot_sample": {
                    "weekly_budget": int(settings["dispatch"]["spot_sample_weekly_budget"]),
                    "used_this_week": self.spot_sample_used_this_week(),
                    "week_start": self.spot_sample_week_start(),
                },
                "verify_volume": self.verify_volume(),
            },
            "queue": {
                "pending": counts.get("pending", 0),
                "running": counts.get("leased", 0),
                "total": len(queue.get("items", [])),
            },
            "counts": counts,
            "items": queue.get("items", []),
            "batch": {
                "id": queue.get("batch", {}).get("id", ""),
                "batch_id": queue.get("batch", {}).get("id", ""),
                "recomputed_at": queue.get("batch", {}).get("recomputed_at", ""),
                "size": queue.get("batch", {}).get("size", counts.get("pending", 0)),
                "backlog_size": queue.get("batch", {}).get("backlog_size", counts.get("pending", 0)),
                "recompute_reason": queue.get("batch", {}).get("recompute_reason", ""),
            },
            "bounds": {
                "batch_size": int(settings["batch_size"]),
                "batch_recompute_min_interval_seconds": int(settings["batch_recompute_min_interval_seconds"]),
                "concordance_window_size": int(settings["concordance_window_size"]),
                "effective_batch_size": int(settings["batch_size"]),
                "effective_concordance_window": min(int(settings["concordance_window_size"]), int(settings["batch_size"])),
            },
            "leases": active_lease_rows,
            "active_leases": len(active_lease_rows),
            "stale_active_leases": stale_active,
            "harness": {
                "mode": settings["harness_selection"].get("mode", "first_eligible"),
                "selected": eligible[0]["framework"] if eligible else "",
                "random": settings["harness_selection"].get("mode") == "random",
                "concurrency": int(settings["max_concurrency"]),
                "cap_total": budget["runtime_seconds_per_day"],
                "cap_remaining": budget["runtime_seconds_remaining"],
                "runtime_seconds_total": budget["runtime_seconds_per_day"],
                "runtime_seconds_remaining": budget["runtime_seconds_remaining"],
                "active_leases": len(active_lease_rows),
                "blocked_reason": blocked_reason if blocked_reason == "no_eligible_harnesses" else "",
                "eligible_frameworks": eligible,
                "rejected_frameworks": rejected,
            },
            "usage": {
                "state": "blocked" if blocked_reason.startswith("active_hours") or blocked_reason == "outside_active_hours" else "ok",
                "cap_total": budget["runtime_seconds_per_day"],
                "cap_remaining": budget["runtime_seconds_remaining"],
                "runtime_seconds_total": budget["runtime_seconds_per_day"],
                "runtime_seconds_remaining": budget["runtime_seconds_remaining"],
                "started": budget["jobs_started"],
                "rate_remaining": budget["jobs_remaining"],
                "launch_rate": "process-once",
            },
            "budget": budget,
            "active_hours": active_hours,
            "blocked_reason": blocked_reason,
            "next_action": next_action,
            "state_dir": str(self.state),
            "terminal_items": terminal_items,
            "last_settled": last_settled,
        }

    def budget_status(self, usage: dict[str, Any]) -> dict[str, Any]:
        runtime_seconds_per_day = None
        runtime_reserved = int(usage.get("runtime_seconds_reserved", 0))
        return {
            "day": usage.get("day"),
            "jobs_started": usage.get("jobs_started", 0),
            "jobs_per_day": None,
            "jobs_remaining": None,
            "runtime_minutes_per_day": None,
            "runtime_seconds_per_day": runtime_seconds_per_day,
            "runtime_seconds_reserved": runtime_reserved,
            "runtime_seconds_remaining": None,
            "runtime_seconds_per_job": None,
        }

    def active_hours_status(self, settings: dict[str, Any]) -> dict[str, Any]:
        cfg = settings["active_hours"]
        ranges = cfg["ranges"]
        out = {
            "enabled": bool(cfg["enabled"]),
            "allowed": True,
            "reason": "",
            "timezone": cfg["timezone"],
            "ranges": [range_public(r) for r in ranges],
            "now": "",
        }
        if ranges:
            first = ranges[0]
            out["start"] = first["start"]
            out["end"] = first["end"]
            out["days"] = first["days"]
        if not cfg["enabled"]:
            return out
        if not ranges:
            return out
        try:
            current = active_hours_now(cfg["timezone"])
        except (ValueError, ZoneInfoNotFoundError) as exc:
            out["allowed"] = False
            out["reason"] = "active_hours_invalid_timezone"
            out["error"] = str(exc)
            return out
        out["now"] = current.isoformat()
        for entry in ranges:
            if range_allows(current, entry):
                return out
        out["allowed"] = False
        out["reason"] = "outside_active_hours"
        return out

    def set_enabled(self, enabled: bool) -> dict[str, Any]:
        settings_file = settings_path()
        doc = read_settings_doc()
        section = doc.setdefault("settlement", {})
        section["enabled"] = enabled
        settings_file.parent.mkdir(parents=True, exist_ok=True)
        json_dump(settings_file, doc)
        refreshed = settlement_settings()
        return {
            "ok": True,
            "action": "enable" if enabled else "disable",
            "enabled": enabled,
            "message": "settlement enabled" if enabled else "settlement disabled",
            "settings_path": str(settings_file),
            "status": self.status(refreshed),
        }

    def eligible_frameworks(self, settings: dict[str, Any]) -> tuple[list[dict[str, Any]], list[dict[str, str]]]:
        caps = json_load(self.capabilities_path, {})
        frameworks = caps.get("frameworks", {})
        requested = settings["harness_selection"].get("eligible_frameworks") or sorted(frameworks.keys())
        out: list[dict[str, Any]] = []
        rejected: list[dict[str, str]] = []
        harnesses = read_settings_doc().get("harnesses", {})
        for fw in requested:
            if fw not in frameworks:
                rejected.append({"framework": fw, "reason": "unknown"})
                continue
            if harnesses.get(fw, {}).get("enabled") is False:
                rejected.append({"framework": fw, "reason": "disabled"})
                continue
            cell = frameworks[fw].get("capabilities", {}).get("headless_runner", {})
            support = cell.get("support", "none")
            evidence = cell.get("evidence") or ""
            install_paths = frameworks[fw].get("install_paths", {})
            if support not in SUPPORT_OK:
                rejected.append({"framework": fw, "reason": "unsupported"})
                continue
            if not evidence:
                rejected.append({"framework": fw, "reason": "no-evidence"})
                continue
            if not install_paths.get("agents"):
                rejected.append({"framework": fw, "reason": "missing-install-path"})
                continue
            out.append({"framework": fw, "support": support, "evidence": evidence, "install_path_agents": install_paths.get("agents")})
        return out, rejected

    def choose_framework(self, settings: dict[str, Any], eligible: list[dict[str, Any]]) -> dict[str, Any]:
        mode = settings["harness_selection"].get("mode", "first_eligible")
        if mode == "first_eligible":
            return eligible[0]
        if mode == "random":
            rng = random.Random(int(settings["harness_selection"].get("random_seed", 0)))
            return rng.choice(eligible)
        if mode == "active":
            active = os.environ.get("LORE_FRAMEWORK") or "claude-code"
            for fw in eligible:
                if fw["framework"] == active:
                    return fw
            raise NoDispatch("process_framework_ineligible")
        raise NoDispatch(f"invalid_harness_selection_mode:{mode}")

    def reserve_budget(self, settings: dict[str, Any], usage: dict[str, Any]) -> None:
        usage["jobs_started"] = int(usage.get("jobs_started", 0)) + 1
        usage["runtime_seconds_reserved"] = int(usage.get("runtime_seconds_reserved", 0)) + int(settings["executor_timeout_seconds"])

    def calibration_marker_path(self) -> Path:
        return self.kdir / "_scorecards" / "calibration-state.json"

    def read_marker_state(self, judge_id: str, judge_version: str) -> str:
        path = self.calibration_marker_path()
        if not path.exists():
            return "pre-calibration"
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return "pre-calibration"
        if not isinstance(data, dict):
            return "pre-calibration"
        entry = data.get(f"{judge_id}:{judge_version}")
        if not isinstance(entry, dict):
            return "pre-calibration"
        state = entry.get("calibration_state")
        if state in ("calibrated", "pre-calibration", "calibration-failed"):
            return state
        return "pre-calibration"

    def gate_template_version(self, gate_name: str) -> str | None:
        template_path = Path(__file__).resolve().parent.parent / "agents" / f"{gate_name}.md"
        if not template_path.exists():
            return None
        version_script = Path(__file__).resolve().with_name("template-version.sh")
        if not version_script.exists():
            return None
        try:
            proc = subprocess.run(
                [str(version_script), str(template_path)],
                capture_output=True,
                text=True,
                check=False,
            )
        except OSError:
            return None
        if proc.returncode != 0:
            return None
        version = (proc.stdout or "").strip()
        return version or None

    def invoke_calibration_runner(self, gate_name: str) -> tuple[bool, str]:
        """Invoke `scorecards-calibrate.sh --judge <gate>` against the gate's
        canonical fixture set. Returns (success, reason).
        """
        fixture_set = self.kdir / "_calibration" / gate_name
        if not fixture_set.is_dir():
            # Substrate not installed in this knowledge directory. Treat this
            # as a "calibration not yet provisioned" signal rather than a
            # hard fail-shut — without a fixture set the runner has nothing
            # to discriminate against, and refusing dispatch on substrate
            # absence would break every workspace that has not yet shipped
            # the per-gate fixture trees. Production KDIRs ship the trees
            # from `scripts/calibration-fixture-builder.py --gate all`.
            return True, f"fixture_set_missing:{fixture_set} (substrate not provisioned; dispatch allowed)"
        runner = Path(__file__).resolve().with_name("scorecards-calibrate.sh")
        if not runner.exists():
            return False, f"runner_missing:{runner}"
        try:
            proc = subprocess.run(
                [
                    "bash", str(runner),
                    "--judge", gate_name,
                    "--fixture-set", str(fixture_set),
                    "--determinism-rerun",
                    "--kdir", str(self.kdir),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
        except OSError as exc:
            return False, f"runner_oserror:{exc}"
        if proc.returncode != 0:
            tail = (proc.stderr or proc.stdout or "").splitlines()[-1:] if (proc.stderr or proc.stdout) else []
            tail_text = tail[0] if tail else ""
            return False, f"calibration-failed:{tail_text[:160]}"
        return True, "calibrated"

    def calibration_precondition(self, item: dict[str, Any]) -> tuple[bool, str, dict[str, Any]]:
        """Calibration self-precondition for the queued item. Soft-cal gates
        always allow dispatch; hard-cal gates require a `calibrated` marker
        entry for the current template-version. Returns (ok, reason,
        telemetry); ok=False carries reason="audit-error: hard-cal gate
        uncalibrated (...)".
        """
        kind = str(item.get("kind") or KIND_TASK_CLAIM)
        gate = KIND_TO_GATE.get(kind)
        telemetry = {
            "gate": gate,
            "kind": kind,
            "is_hard_cal": gate in HARD_CAL_GATES,
        }
        if not gate:
            return True, "", telemetry  # unknown kinds are filtered earlier by item_invalid_reason
        if gate not in HARD_CAL_GATES:
            # Soft-cal gates (omission, curator, reverse-auditor) do not gate
            # dispatch. Calibration may still be run out-of-band by a separate
            # ceremony; the processor does not stop them.
            telemetry["state"] = "soft-cal-skipped"
            return True, "", telemetry
        version = self.gate_template_version(gate)
        if not version:
            telemetry["state"] = "template-unresolvable"
            return False, f"audit-error: hard-cal gate uncalibrated ({gate}: template unresolvable)", telemetry
        telemetry["gate_template_version"] = version
        state = self.read_marker_state(gate, version)
        telemetry["initial_state"] = state
        if state == "calibrated":
            telemetry["state"] = "calibrated"
            return True, "", telemetry
        # pre-calibration: run the calibration runner once before the first
        # dispatch on this template-version. calibration-failed: refuse to
        # dispatch until the template version changes — there is no inline
        # manual override.
        if state == "calibration-failed":
            telemetry["state"] = "calibration-failed"
            return False, f"audit-error: hard-cal gate uncalibrated ({gate}: calibration-failed at template-version {version})", telemetry
        ok, runner_reason = self.invoke_calibration_runner(gate)
        telemetry["runner_invoked"] = True
        telemetry["runner_reason"] = runner_reason
        if not ok:
            telemetry["state"] = "calibration-failed"
            return False, f"audit-error: hard-cal gate uncalibrated ({gate}: {runner_reason})", telemetry
        # Substrate-missing case: runner returned ok with a fixture_set_missing
        # note. Treat as "calibration substrate not yet installed in this
        # KDIR" and allow dispatch. Production KDIRs ship the fixture trees
        # from `scripts/calibration-fixture-builder.py --gate all` so this
        # branch is reached only in workspaces that have not yet provisioned
        # the substrate (legacy KDIRs, isolated test KDIRs).
        if runner_reason.startswith("fixture_set_missing:"):
            telemetry["state"] = "substrate-not-provisioned"
            return True, "", telemetry
        # Re-check marker after a successful run.
        post_state = self.read_marker_state(gate, version)
        telemetry["state"] = post_state
        if post_state == "calibrated":
            return True, "", telemetry
        return False, f"audit-error: hard-cal gate uncalibrated ({gate}: runner_ok but marker not flipped)", telemetry

    def process_once(self, settings: dict[str, Any]) -> dict[str, Any]:
        self.ensure()
        # GC orphaned leases and structural inconsistencies on every tick,
        # regardless of dispatch state. Pausing the queue, out-of-hours, or
        # no-eligible-harness should NOT prevent reclaiming dead leases —
        # otherwise a crashed worker can wedge the dispatcher indefinitely.
        with repo_lock(self.state):
            queue = self.load_queue()
            leases = self.load_leases()
            healed = self.heal_queue(queue, leases)
            expired = self.expire_stale_leases(queue, leases)
            if healed or expired:
                self.save_queue(queue)
                self.save_leases(leases)

            # Dispatch guards run after GC so the reclaim is durable
            # before any short-circuit return.
            if not settings["enabled"]:
                return {"ok": True, "dispatched": False, "reason": "disabled", "expired_leases_reclaimed": expired, "healed": healed}
            active_hours = self.active_hours_status(settings)
            if not active_hours["allowed"]:
                return {"ok": True, "dispatched": False, "reason": active_hours["reason"], "active_hours": active_hours, "expired_leases_reclaimed": expired, "healed": healed}
            eligible, rejected = self.eligible_frameworks(settings)
            if not eligible:
                return {"ok": True, "dispatched": False, "reason": "no_eligible_harnesses", "rejected_harnesses": rejected, "expired_leases_reclaimed": expired, "healed": healed}
            executor = executor_command(settings)

            active = [lease for lease in leases.get("leases", {}).values() if lease.get("state") == "active"]
            if len(active) >= int(settings["max_concurrency"]):
                self.save_queue(queue)
                self.save_leases(leases)
                return {"ok": True, "dispatched": False, "reason": "max_concurrency_reached", "active_leases": len(active), "expired_leases_reclaimed": expired}
            # Census posture gate (memo §5.2): batch recompute pulls the full
            # source-stream backlog through iter_backlog_items — that refill IS
            # the census. In the event-driven posture the queue is an inbox:
            # items dispatch in queue order and an empty queue is empty, never
            # silently refilled. The recompute machinery stays intact (dormant)
            # behind settlement.dispatch.census_enabled.
            census = bool(settings["dispatch"]["census_enabled"])
            legacy_pending = census and any(it.get("status") == "pending" and not it.get("selection_reason") for it in queue.get("items", []))
            if legacy_pending:
                self.apply_recomputed_batch(queue, settings, "legacy_pending_normalization")
            item = next((it for it in queue.get("items", []) if it.get("status") == "pending"), None)
            if item is None:
                if census and (self.active_batch_drained_with_backlog(queue) or self.should_recompute(queue, settings)):
                    self.apply_recomputed_batch(queue, settings, "process_once")
                    item = next((it for it in queue.get("items", []) if it.get("status") == "pending"), None)
                elif healed:
                    self.save_queue(queue)
                    self.save_leases(leases)
                    return {"ok": True, "dispatched": False, "reason": "empty_queue", "expired_leases_reclaimed": expired, "healed": healed}
            if item is None:
                self.save_queue(queue)
                self.save_leases(leases)
                return {"ok": True, "dispatched": False, "reason": "empty_queue", "expired_leases_reclaimed": expired}
            invalid_reason = self.item_invalid_reason(item)
            if invalid_reason:
                run = self.write_invalid_claim_run(item, invalid_reason)
                queue["items"] = [it for it in queue.get("items", []) if it.get("id") != item.get("id")]
                self.save_queue(queue)
                self.save_leases(leases)
                return {"ok": True, "dispatched": False, "reason": "invalid_task_claim", "item_id": item.get("id"), "run": run}
            # For hard-cal gates the marker for the current gate
            # template-version must read `calibrated` before dispatch. On
            # pre-calibration the runner runs once and the marker is
            # re-checked; on calibration-failed dispatch is refused and an
            # audit-error event is surfaced. The item stays at the head of
            # the queue so a later template-version change can lift the gate.
            ok_calibration, calibration_reason, calibration_telemetry = self.calibration_precondition(item)
            if not ok_calibration:
                self.save_queue(queue)
                self.save_leases(leases)
                return {
                    "ok": True,
                    "dispatched": False,
                    "reason": calibration_reason,
                    "item_id": item.get("id"),
                    "calibration": calibration_telemetry,
                }
            usage = self.load_usage()
            try:
                self.reserve_budget(settings, usage)
                chosen = self.choose_framework(settings, eligible)
            except NoDispatch as exc:
                self.save_queue(queue)
                self.save_leases(leases)
                self.save_usage(usage)
                return {"ok": True, "dispatched": False, "reason": str(exc), "rejected_harnesses": rejected}
            run_id = f"run-{hashlib.sha256((item['id'] + utc_now()).encode()).hexdigest()[:20]}"
            lease_id = f"lease-{hashlib.sha256((run_id + item['id']).encode()).hexdigest()[:20]}"
            item["status"] = "leased"
            item["lease_id"] = lease_id
            item["run_id"] = run_id
            item["attempts"] = int(item.get("attempts") or 0) + 1
            item["selected_at"] = utc_now()
            item["updated_at"] = utc_now()
            leases["leases"][lease_id] = {
                "lease_id": lease_id,
                "item_id": item["id"],
                "run_id": run_id,
                "holder": f"pid-{os.getpid()}",
                "state": "active",
                "acquired_at": utc_now(),
                "expires_at_epoch": now_epoch() + int(settings["lease_ttl_seconds"]),
            }
            self.save_queue(queue)
            self.save_leases(leases)
            self.save_usage(usage)

        run = self.execute_item(item, run_id, chosen, settings, executor)

        with repo_lock(self.state):
            queue = self.load_queue()
            leases = self.load_leases()
            queue["items"] = [it for it in queue.get("items", []) if it.get("id") != item["id"]]
            if lease_id in leases.get("leases", {}):
                leases["leases"][lease_id]["state"] = "released"
                leases["leases"][lease_id]["released_at"] = utc_now()
            self.save_queue(queue)
            self.save_leases(leases)
        return {"ok": True, "dispatched": True, "item_id": item["id"], "run": run}

    def drain(self, settings: dict[str, Any], max_iterations: int = 200) -> dict[str, Any]:
        iterations = 0
        dispatched = 0
        aborted = False
        last_reason = ""
        while iterations < max_iterations:
            iterations += 1
            result = self.process_once(settings)
            reason = str(result.get("reason") or "")
            last_reason = reason
            if result.get("dispatched"):
                dispatched += 1
                continue
            if reason == "empty_queue":
                break
            if reason == "pipeline-degraded" or reason.startswith("audit-error: hard-cal gate uncalibrated"):
                aborted = True
                break
            break
        queue = self.load_queue()
        remaining = sum(1 for it in queue.get("items", []) if it.get("status") == "pending")
        return {
            "ok": True,
            "aborted": aborted,
            "iterations": iterations,
            "dispatched": dispatched,
            "remaining": remaining,
            "last_reason": last_reason,
        }

    def execute_item(self, item: dict[str, Any], run_id: str, chosen: dict[str, Any], settings: dict[str, Any], executor: list[str]) -> dict[str, Any]:
        # D7: rollup items bypass settlement-audit-executor.sh entirely. They
        # have no `lore audit --kind <K> --id <ID>` shape, no per-claim verdict,
        # no aggregate gate counts — invoking the audit executor would 1) reject
        # the missing source row at preflight and 2) couple two unrelated
        # dispatch shapes in one shell file. Branch in-Python; synthesize a
        # minimal run record with verdict_format=rollup; skip the correction
        # pipeline (_apply_correction_from_verdict + _emit_correction_evidence).
        kind = str(item.get("kind") or KIND_TASK_CLAIM)
        if self.is_rollup_kind(kind):
            return self._execute_rollup_item(item, run_id, chosen, settings)
        env = os.environ.copy()
        env["LORE_FRAMEWORK"] = chosen["framework"]
        started = utc_now()
        status = "completed"
        reason = "executor_exit_0"
        stderr = ""
        stdout = ""
        try:
            proc = subprocess.run(
                executor,
                input=compact({"item": item, "run_id": run_id}),
                text=True,
                capture_output=True,
                env=env,
                timeout=int(settings.get("executor_timeout_seconds", DEFAULT_EXECUTOR_TIMEOUT_SECONDS)),
                check=False,
            )
            stdout = proc.stdout
            stderr = proc.stderr[-2000:]
            status = "completed" if proc.returncode == 0 else "failed"
            reason = f"executor_exit_{proc.returncode}"
        except subprocess.TimeoutExpired:
            status = "blocked"
            reason = "executor_timeout"
        except OSError as exc:
            status = "failed"
            reason = "executor_launch_failed"
            stderr = str(exc)[-2000:]
        self._last_executor_audit = None
        verdict = self.parse_verdict_envelope(stdout) if status == "completed" else None
        if verdict is None:
            verdict = {
                "claim_id": item.get("claim_id"),
                "verdict": "unverified" if status == "completed" else status,
                "evidence": "settlement processor recorded the validated Tier 2 claim for downstream audit",
                "correction": None,
                "verdict_format": "opaque",
            }
        else:
            verdict["claim_id"] = item.get("claim_id")
            if verdict.get("verdict") == "error":
                status = "failed"
                reason = "executor_audit_error"
        item_kind = str(item.get("kind") or KIND_TASK_CLAIM)
        item_source_id = str(item.get("source_id") or item.get("claim_id") or item.get("candidate_id") or item.get("contradiction_id") or "")
        run = {
            "version": VERSION,
            "run_id": run_id,
            "item_id": item["id"],
            "kind": item_kind,
            "source_id": item_source_id,
            "work_item": item.get("work_item"),
            "claim_id": item.get("claim_id"),
            "claim": item.get("claim"),
            "source": item.get("source"),
            "falsifier": item.get("falsifier"),
            "framework": chosen["framework"],
            "framework_capability": {k: chosen[k] for k in ("support", "evidence", "install_path_agents")},
            "status": status,
            "reason": reason,
            "started_at": started,
            "completed_at": utc_now(),
            "runtime_seconds_reserved": int(settings["executor_timeout_seconds"]),
            "verdict": verdict,
            "verdict_ref": f"_settlement/runs/{run_id}.json#verdict",
            "correction_ref": None,
            "selection": self.selection_block(item),
        }
        executor_audit = getattr(self, "_last_executor_audit", None)
        if executor_audit is not None:
            run["executor_audit"] = executor_audit
            self._last_executor_audit = None
        if stderr:
            run["stderr_tail"] = stderr
        written = self.write_run_record_once(run)
        outcome = self._apply_correction_from_verdict(written, item)
        if isinstance(outcome, dict):
            persisted = self.write_run_correction_outcome_once(str(written.get("run_id") or ""), outcome)
            written["correction_outcome"] = persisted
            # Correction-evidence rows feed /evolve's secondary (doctrine-
            # correction) gate, whose evidence class is protocol/template
            # corrections from task-claim audits. Commons-kind corrections are
            # knowledge-drift signal, not doctrine signal — their /evolve
            # channel is the claim-retraction gate (verified consumption-
            # contradictions), and their forensic record is the entry's
            # corrections[] trail + this run's correction_outcome. Emitting
            # them here would conflate evidence classes and let bulk drift-
            # sweep corrections satisfy the secondary gate's sample-size
            # minimum. Decision record:
            # _work/decide-commons-correction-feed-evolve-secondary-ga
            if (
                persisted.get("status") == "applied"
                and str(item.get("kind") or KIND_TASK_CLAIM) == KIND_TASK_CLAIM
            ):
                self._emit_correction_evidence(str(written.get("run_id") or ""), persisted)
        self._apply_audit_candidate_transition(written, item)
        return written

    def _execute_rollup_item(self, item: dict[str, Any], run_id: str, chosen: dict[str, Any], settings: dict[str, Any]) -> dict[str, Any]:
        # D7 rollup dispatch: shell out to the per-judge rollup script in its
        # --aggregate-window mode. Synthesize a verdict_format=rollup envelope;
        # skip _apply_correction_from_verdict / _emit_correction_evidence
        # (rollups carry no correction).
        kind = str(item.get("kind") or "")
        judge = str(item.get("judge") or "")
        window_start = str(item.get("window_start") or "")
        window_end = str(item.get("window_end") or "")
        script_filename, _judge_for_kind = ROLLUP_KIND_TO_SCRIPT[kind]
        script_path = str(Path(__file__).resolve().with_name(script_filename))
        cmd = [
            "bash",
            script_path,
            "--aggregate-window",
            "--judge", judge,
            "--window-start", window_start,
            "--window-end", window_end,
            "--kdir", str(self.kdir),
        ]
        started = utc_now()
        status = "completed"
        reason = "rollup_exit_0"
        stdout = ""
        stderr = ""
        try:
            proc = subprocess.run(
                cmd,
                input="",
                text=True,
                capture_output=True,
                timeout=int(settings.get("executor_timeout_seconds", DEFAULT_EXECUTOR_TIMEOUT_SECONDS)),
                check=False,
                env={**os.environ, "LORE_KNOWLEDGE_DIR": str(self.kdir)},
            )
            stdout = proc.stdout
            stderr = proc.stderr[-2000:]
            status = "completed" if proc.returncode == 0 else "failed"
            reason = f"rollup_exit_{proc.returncode}"
            returncode = proc.returncode
        except subprocess.TimeoutExpired:
            status = "blocked"
            reason = "rollup_timeout"
            returncode = -1
        except OSError as exc:
            status = "failed"
            reason = "rollup_launch_failed"
            stderr = str(exc)[-2000:]
            returncode = -1
        # Stderr summary line: the rollup script writes a final
        # "[rollup] Aggregated: templates=<N> rows=<M> window=<...>" line.
        # Pull the last non-empty stderr line as the verdict evidence.
        summary_tail = ""
        for line in reversed((stderr or "").splitlines()):
            line = line.strip()
            if line:
                summary_tail = line
                break
        if status == "completed":
            verdict_label = "rollup-complete"
            evidence = summary_tail or "rollup exit=0 (n=0 stderr summary)"
        else:
            verdict_label = "rollup-failed"
            evidence = f"rollup script exit={returncode}: {summary_tail or stderr[-200:]}"
        verdict = {
            "verdict": verdict_label,
            "evidence": evidence,
            "correction": None,
            "verdict_format": "rollup",
        }
        run = {
            "version": VERSION,
            "run_id": run_id,
            "item_id": item["id"],
            "kind": kind,
            "source_id": "",
            "judge": judge,
            "window_start": window_start,
            "window_end": window_end,
            "framework": chosen["framework"],
            "framework_capability": {k: chosen[k] for k in ("support", "evidence", "install_path_agents")},
            "status": status,
            "reason": reason,
            "started_at": started,
            "completed_at": utc_now(),
            "runtime_seconds_reserved": int(settings["executor_timeout_seconds"]),
            "verdict": verdict,
            "verdict_ref": f"_settlement/runs/{run_id}.json#verdict",
            "correction_ref": None,
            "selection": self.selection_block(item),
        }
        if stderr:
            run["stderr_tail"] = stderr
        if stdout:
            run["stdout_tail"] = stdout[-2000:]
        written = self.write_run_record_once(run)
        # Rollup runs invalidate the cached existence check: a fresh tier=template
        # row may now exist for (judge, window_start). The next scan() will
        # rebuild the cache, but if execute_item is called multiple times in one
        # process (e.g., drain), invalidate now.
        self._invalidate_rollup_existence_cache()
        return written

    def _emit_correction_evidence(self, run_id: str, outcome: dict[str, Any]) -> None:
        """Bridge a settlement-applied correction into `_scorecards/rows.jsonl`
        as a `tier:correction + kind:scored` row so /evolve's secondary gate
        can re-acquire the recurring-failure signal (D2).

        Sole-writer discipline: never write to rows.jsonl directly — shell out
        to `scorecard-append.sh` which is the only sanctioned writer.

        Idempotent: scans the existing `rows.jsonl` for a row matching
        `tier == "correction" AND kind == "scored" AND
        calibrated_by_verdict_id == run_id`; if found, skip emission silently
        (covers settlement-processor retry on a previously-applied run, since
        `write_run_correction_outcome_once` returns the existing outcome on
        retry without signaling whether it was newly written).

        Failures are logged to stderr but never raised — emission is best-
        effort downstream telemetry, not part of the correction-application
        critical path.
        """
        if not run_id:
            return
        target_entry = str(outcome.get("target_entry") or "")
        if not target_entry:
            sys.stderr.write(
                f"[settlement] correction-evidence emission skipped run_id={run_id}: missing target_entry\n"
            )
            return
        rows_path = self.kdir / "_scorecards" / "rows.jsonl"
        if rows_path.exists():
            try:
                with rows_path.open(encoding="utf-8") as fh:
                    for line in fh:
                        line = line.strip()
                        if not line:
                            continue
                        try:
                            existing = json.loads(line)
                        except json.JSONDecodeError:
                            continue
                        if (
                            isinstance(existing, dict)
                            and existing.get("tier") == "correction"
                            and existing.get("kind") == "scored"
                            and existing.get("calibrated_by_verdict_id") == run_id
                        ):
                            return  # idempotent retry — row already emitted
            except OSError as exc:
                sys.stderr.write(
                    f"[settlement] correction-evidence emission failed run_id={run_id}: read rows.jsonl: {exc}\n"
                )
                return
        row = {
            "tier": "correction",
            "kind": "scored",
            "calibration_state": "pre-calibration",
            "calibrated_by_verdict_id": run_id,
            "corrected_entry_path": target_entry,
            "correction_target": "claim",
            "schema_version": 1,
        }
        scripts_dir = os.path.dirname(os.path.abspath(__file__))
        append_cmd = [
            "bash",
            os.path.join(scripts_dir, "scorecard-append.sh"),
            "--kdir", str(self.kdir),
        ]
        try:
            subprocess.run(
                append_cmd,
                input=compact(row),
                text=True,
                capture_output=True,
                timeout=30,
                check=True,
                env={**os.environ, "LORE_KNOWLEDGE_DIR": str(self.kdir)},
            )
        except subprocess.CalledProcessError as exc:
            stderr_tail = (exc.stderr or "")[-500:]
            sys.stderr.write(
                f"[settlement] correction-evidence emission failed run_id={run_id}: scorecard-append exit {exc.returncode}: {stderr_tail}\n"
            )
        except (subprocess.TimeoutExpired, OSError) as exc:
            sys.stderr.write(
                f"[settlement] correction-evidence emission failed run_id={run_id}: {exc}\n"
            )

    def _apply_audit_candidate_transition(self, written: dict[str, Any], item: dict[str, Any]) -> None:
        """Advance the audit-candidate source row through the correctness-gate
        lifecycle after a completed omission run.

        Mapping (D2):
          verified                -> gate-passed
          unverified|contradicted -> gate-failed
          error|blocked|other     -> no transition (row retried on next dispatch)

        Best-effort: subprocess failures (including legal-illegal transition
        rejects from re-emit on an already-terminal row) are logged to stderr
        and never raised. audit-candidate-transition.sh remains the sole
        sanctioned post-append writer of the `status` field per the
        ownership_matrix.
        """
        if str(item.get("kind") or "") != KIND_OMISSION:
            return
        if str(written.get("status") or "") != "completed":
            return
        candidate_id = str(item.get("source_id") or item.get("candidate_id") or "")
        work_item = str(item.get("work_item") or "")
        run_id = str(written.get("run_id") or "")
        if not candidate_id or not work_item:
            sys.stderr.write(
                f"[settlement] audit-candidate transition skipped run_id={run_id}: "
                f"missing candidate_id or work_item (candidate_id={candidate_id!r} work_item={work_item!r})\n"
            )
            return
        verdict = written.get("verdict") if isinstance(written.get("verdict"), dict) else {}
        verdict_value = str(verdict.get("verdict") or "").strip()
        if verdict_value == "verified":
            new_status = "gate-passed"
        elif verdict_value in ("unverified", "contradicted"):
            new_status = "gate-failed"
        else:
            return
        scripts_dir = os.path.dirname(os.path.abspath(__file__))
        cmd = [
            "bash",
            os.path.join(scripts_dir, "audit-candidate-transition.sh"),
            "--kdir", str(self.kdir),
            "--work-item", work_item,
            "--candidate-id", candidate_id,
            "--status", new_status,
        ]
        try:
            proc = subprocess.run(
                cmd,
                text=True,
                capture_output=True,
                timeout=30,
                check=False,
            )
        except (subprocess.TimeoutExpired, OSError) as exc:
            sys.stderr.write(
                f"[settlement] audit-candidate transition failed run_id={run_id} "
                f"work_item={work_item} candidate_id={candidate_id}: {exc}\n"
            )
            return
        if proc.returncode != 0:
            stderr_tail = (proc.stderr or "").strip().splitlines()[-1:] if (proc.stderr or "").strip() else []
            tail_text = stderr_tail[0] if stderr_tail else ""
            sys.stderr.write(
                f"[settlement] audit-candidate transition failed run_id={run_id} "
                f"work_item={work_item} candidate_id={candidate_id} exit={proc.returncode}: {tail_text[:200]}\n"
            )

    def _apply_correction_from_verdict(self, run: dict[str, Any], item: dict[str, Any]) -> dict[str, Any] | None:
        """Autonomous correction terminus. On contradicted verdicts, attempt to
        mutate the commons entry directly via apply-correction.sh with
        --allow-settlement-verdict. The mutation is single-shot and gated on
        exact superseded_text match.

        Returns a `correction_outcome` dict for every branch reached after a
        contradicted verdict (closed taxonomy in D2), or None for non-contradicted
        verdicts. Stderr lines are preserved as the live-operator surface.

        Commons kind flows both verdict directions through this same terminus:
        verified -> advance the entry's confidence; contradicted -> mutate the
        entry resolved from the producer row's entry_path. See
        _apply_commons_flowback.
        """
        if str(run.get("kind") or KIND_TASK_CLAIM) == KIND_COMMONS:
            return self._apply_commons_flowback(run, item)
        verdict = run.get("verdict") if isinstance(run.get("verdict"), dict) else {}
        if verdict.get("verdict") != "contradicted":
            return None
        # Auto-correction (--mutate path) only applies to task-claim runs whose
        # contradicted verdict carries a claim+correction pair that mutates an
        # existing commons entry. omission and consumption-contradiction kinds
        # do not produce direct mutations through this path (their commons
        # interactions land via --add-entry in Phase 2/3 ceremony work).
        if str(run.get("kind") or KIND_TASK_CLAIM) != KIND_TASK_CLAIM:
            return {"status": "skipped", "reason": "non_task_claim_kind"}
        run_id = str(run.get("run_id") or "")
        if os.environ.get("LORE_SETTLEMENT_DISABLE_AUTO_CORRECTION", "").strip():
            return {"status": "skipped", "reason": "auto_correction_disabled"}
        if not run_id:
            return {"status": "skipped", "reason": "auto_correction_disabled"}
        correction_text = verdict.get("correction")
        if not (isinstance(correction_text, str) and correction_text.strip()):
            sys.stderr.write(f"[settlement] auto-correction skipped run_id={run_id}: empty correction text\n")
            return {"status": "skipped", "reason": "empty_correction_text"}
        evidence_text = verdict.get("evidence") or ""
        claim_text = item.get("claim") or ""
        if not claim_text.strip():
            sys.stderr.write(f"[settlement] auto-correction skipped run_id={run_id}: empty claim text\n")
            return {"status": "skipped", "reason": "empty_claim_text"}
        # Tier 2 row's file + line_range live under item["source"] per
        # item_from_row (line 318). Top-level item.get("file") would always be None.
        source = item.get("source") if isinstance(item.get("source"), dict) else {}
        item_file = str(source.get("file") or item.get("file") or "")
        item_line_range = str(source.get("line_range") or item.get("line_range") or "")
        file_line_arg = f"{item_file}:{item_line_range}" if item_file else ""
        scripts_dir = os.path.dirname(os.path.abspath(__file__))
        find_cmd = [
            "bash",
            os.path.join(scripts_dir, "find-correction-targets.sh"),
            "--json",
            "--claim-text", claim_text,
            "--limit", "1",
        ]
        if file_line_arg:
            find_cmd.extend(["--file-line", file_line_arg])
        try:
            find_proc = subprocess.run(
                find_cmd,
                text=True,
                capture_output=True,
                timeout=30,
                check=False,
                env={**os.environ, "LORE_KNOWLEDGE_DIR": str(self.kdir)},
            )
        except (subprocess.TimeoutExpired, OSError) as exc:
            sys.stderr.write(f"[settlement] auto-correction skipped run_id={run_id}: find-correction-targets failed: {exc}\n")
            return {"status": "failed", "reason": "find_targets_subprocess_error", "detail": str(exc)[:200]}
        if find_proc.returncode != 0 or not find_proc.stdout.strip():
            sys.stderr.write(f"[settlement] auto-correction skipped run_id={run_id}: find-correction-targets exit {find_proc.returncode}\n")
            return {"status": "failed", "reason": "find_targets_nonzero_exit", "detail": f"exit {find_proc.returncode}: {find_proc.stderr[-160:]}"}
        try:
            find_result = json.loads(find_proc.stdout)
        except json.JSONDecodeError as exc:
            sys.stderr.write(f"[settlement] auto-correction skipped run_id={run_id}: find-correction-targets JSON parse: {exc}\n")
            return {"status": "failed", "reason": "find_targets_json_parse", "detail": str(exc)[:200]}
        index_state = find_result.get("index_state")
        targets = find_result.get("targets") or []
        if index_state == "missing":
            sys.stderr.write(f"[settlement] auto-correction skipped run_id={run_id}: concordance index missing\n")
            return {"status": "skipped", "reason": "concordance_unavailable"}
        if not targets:
            sys.stderr.write(f"[settlement] auto-correction skipped run_id={run_id}: no commons target for claim\n")
            return {"status": "skipped", "reason": "no_commons_target"}
        target = targets[0]
        target_path_relative = str(target.get("path") or "")
        if not target_path_relative:
            sys.stderr.write(f"[settlement] auto-correction skipped run_id={run_id}: target row missing path\n")
            return {"status": "skipped", "reason": "target_path_missing"}
        # find-correction-targets returns paths relative to KDIR; resolve absolute.
        kdir = str(getattr(self, "kdir", "") or os.environ.get("LORE_KNOWLEDGE_DIR", ""))
        if kdir and not os.path.isabs(target_path_relative):
            target_path = os.path.join(kdir, target_path_relative)
        else:
            target_path = target_path_relative
        evidence_for_apply = evidence_text if evidence_text else f"settlement_run_id={run_id}"
        apply_cmd = [
            "bash",
            os.path.join(scripts_dir, "apply-correction.sh"),
            "--entry", target_path,
            "--verdict-id", run_id,
            "--verdict-source", "correctness-gate",
            "--evidence", evidence_for_apply,
            "--superseded-text", claim_text,
            "--replacement-text", correction_text,
            "--allow-settlement-verdict",
        ]
        try:
            apply_proc = subprocess.run(
                apply_cmd,
                text=True,
                capture_output=True,
                timeout=30,
                check=False,
                env={**os.environ, "LORE_KNOWLEDGE_DIR": str(self.kdir)},
            )
        except (subprocess.TimeoutExpired, OSError) as exc:
            sys.stderr.write(f"[settlement] auto-correction failed run_id={run_id}: apply-correction subprocess: {exc}\n")
            return {"status": "failed", "reason": "apply_subprocess_error", "target_entry": target_path_relative, "detail": str(exc)[:200]}
        if apply_proc.returncode == 0:
            sys.stderr.write(f"[settlement] auto-correction APPLIED run_id={run_id} entry={target_path}\n")
            return {"status": "applied", "reason": "applied", "target_entry": target_path_relative}
        if apply_proc.returncode == 2:
            sys.stderr.write(f"[settlement] auto-correction skipped run_id={run_id}: superseded_text not present in {target_path} (not_mechanically_applicable)\n")
            return {"status": "skipped", "reason": "not_mechanically_applicable", "target_entry": target_path_relative}
        sys.stderr.write(f"[settlement] auto-correction failed run_id={run_id}: apply-correction exit {apply_proc.returncode}: {apply_proc.stderr[-500:]}\n")
        return {"status": "failed", "reason": "apply_unexpected_exit", "target_entry": target_path_relative, "detail": f"exit {apply_proc.returncode}: {apply_proc.stderr[-160:]}"}

    def _apply_commons_flowback(self, run: dict[str, Any], item: dict[str, Any]) -> dict[str, Any] | None:
        """Commons-kind half of the correction terminus. Both verdict directions
        land here: verified advances the entry's confidence (unaudited -> high),
        contradicted mutates the entry text. The mutation target is the producer
        row's entry_path (carried on the item), NOT a re-run of find-correction-
        targets — the promotion already named the exact entry the audit covers.

        Best-effort per the terminus contract: subprocess failures are logged to
        stderr with run_id + work_item + claim_id and never raised. Returns a
        correction_outcome dict for every reached branch, or None for verdicts
        this terminus does not act on (e.g. unverified/error).
        """
        verdict = run.get("verdict") if isinstance(run.get("verdict"), dict) else {}
        verdict_value = str(verdict.get("verdict") or "").strip()
        run_id = str(run.get("run_id") or "")
        work_item = str(item.get("work_item") or "")
        claim_id = str(item.get("claim_id") or item.get("source_id") or "")
        if verdict_value not in ("verified", "contradicted"):
            return None
        if os.environ.get("LORE_SETTLEMENT_DISABLE_AUTO_CORRECTION", "").strip():
            return {"status": "skipped", "reason": "auto_correction_disabled"}
        if not run_id:
            return {"status": "skipped", "reason": "auto_correction_disabled"}

        # entry_path passed commons_invalid_reason at enqueue, but the entry may
        # have moved or been superseded since — re-validate before mutating.
        entry_rel = str(item.get("entry_path") or "")
        if not entry_rel:
            sys.stderr.write(f"[settlement] commons flowback skipped run_id={run_id} work_item={work_item} claim_id={claim_id}: item missing entry_path\n")
            return {"status": "skipped", "reason": "missing_entry_path"}
        entry_abs = (self.kdir / entry_rel).resolve()
        try:
            entry_abs.relative_to(self.kdir.resolve())
            inside = True
        except ValueError:
            inside = False
        if not inside or not entry_abs.is_file():
            sys.stderr.write(f"[settlement] commons flowback skipped run_id={run_id} work_item={work_item} claim_id={claim_id}: entry_path no longer resolves ({entry_rel})\n")
            return {"status": "skipped", "reason": "entry_path_unresolved", "target_entry": entry_rel}

        scripts_dir = os.path.dirname(os.path.abspath(__file__))
        evidence_text = verdict.get("evidence") or f"settlement_run_id={run_id}"

        if verdict_value == "verified":
            cmd = [
                "bash",
                os.path.join(scripts_dir, "apply-correction.sh"),
                "--advance-confidence",
                "--entry", str(entry_abs),
                "--verdict-id", run_id,
                "--verdict-source", "correctness-gate",
                "--evidence", evidence_text,
                "--allow-settlement-verdict",
            ]
            try:
                proc = subprocess.run(
                    cmd, text=True, capture_output=True, timeout=30, check=False,
                    env={**os.environ, "LORE_KNOWLEDGE_DIR": str(self.kdir)},
                )
            except (subprocess.TimeoutExpired, OSError) as exc:
                sys.stderr.write(f"[settlement] commons flowback failed run_id={run_id} work_item={work_item} claim_id={claim_id}: advance-confidence subprocess: {exc}\n")
                return {"status": "failed", "reason": "advance_subprocess_error", "target_entry": entry_rel, "detail": str(exc)[:200]}
            if proc.returncode == 0:
                sys.stderr.write(f"[settlement] commons flowback ADVANCED run_id={run_id} entry={entry_rel}\n")
                return {"status": "advanced", "reason": "confidence_advanced", "target_entry": entry_rel}
            sys.stderr.write(f"[settlement] commons flowback failed run_id={run_id} work_item={work_item} claim_id={claim_id}: advance-confidence exit {proc.returncode}: {proc.stderr[-300:]}\n")
            return {"status": "failed", "reason": "advance_unexpected_exit", "target_entry": entry_rel, "detail": f"exit {proc.returncode}: {proc.stderr[-160:]}"}

        # contradicted -> mutate. Reuse the exact-match safety boundary: the
        # claim text must be present verbatim in the entry body or apply-
        # correction exits 2 (a safe skip, not an error).
        correction_text = verdict.get("correction")
        if not (isinstance(correction_text, str) and correction_text.strip()):
            sys.stderr.write(f"[settlement] commons flowback skipped run_id={run_id} work_item={work_item} claim_id={claim_id}: empty correction text\n")
            return {"status": "skipped", "reason": "empty_correction_text", "target_entry": entry_rel}
        claim_text = item.get("claim") or ""
        if not str(claim_text).strip():
            sys.stderr.write(f"[settlement] commons flowback skipped run_id={run_id} work_item={work_item} claim_id={claim_id}: empty claim text\n")
            return {"status": "skipped", "reason": "empty_claim_text", "target_entry": entry_rel}
        cmd = [
            "bash",
            os.path.join(scripts_dir, "apply-correction.sh"),
            "--entry", str(entry_abs),
            "--verdict-id", run_id,
            "--verdict-source", "correctness-gate",
            "--evidence", evidence_text,
            "--superseded-text", str(claim_text),
            "--replacement-text", correction_text,
            "--allow-settlement-verdict",
        ]
        try:
            proc = subprocess.run(
                cmd, text=True, capture_output=True, timeout=30, check=False,
                env={**os.environ, "LORE_KNOWLEDGE_DIR": str(self.kdir)},
            )
        except (subprocess.TimeoutExpired, OSError) as exc:
            sys.stderr.write(f"[settlement] commons flowback failed run_id={run_id} work_item={work_item} claim_id={claim_id}: apply-correction subprocess: {exc}\n")
            return {"status": "failed", "reason": "apply_subprocess_error", "target_entry": entry_rel, "detail": str(exc)[:200]}
        if proc.returncode == 0:
            sys.stderr.write(f"[settlement] commons flowback APPLIED run_id={run_id} entry={entry_rel}\n")
            return {"status": "applied", "reason": "applied", "target_entry": entry_rel}
        if proc.returncode == 2:
            sys.stderr.write(f"[settlement] commons flowback skipped run_id={run_id} work_item={work_item} claim_id={claim_id}: superseded_text not present in {entry_rel} (not_mechanically_applicable)\n")
            return {"status": "skipped", "reason": "not_mechanically_applicable", "target_entry": entry_rel}
        sys.stderr.write(f"[settlement] commons flowback failed run_id={run_id} work_item={work_item} claim_id={claim_id}: apply-correction exit {proc.returncode}: {proc.stderr[-300:]}\n")
        return {"status": "failed", "reason": "apply_unexpected_exit", "target_entry": entry_rel, "detail": f"exit {proc.returncode}: {proc.stderr[-160:]}"}

    def parse_verdict_envelope(self, stdout: str) -> dict[str, Any] | None:
        self._last_executor_audit = None
        if not stdout.strip():
            return None
        try:
            envelope = json.loads(stdout)
        except json.JSONDecodeError:
            return None
        if not isinstance(envelope, dict):
            return None
        if envelope.get("verdict_envelope_version") != 1:
            return None
        verdict = envelope.get("verdict")
        evidence = envelope.get("evidence")
        if not isinstance(verdict, str) or not verdict:
            return None
        if not isinstance(evidence, str) or not evidence:
            return None
        if "correction" not in envelope:
            return None
        correction = envelope.get("correction")
        if correction is not None and not isinstance(correction, str):
            return None
        audit = envelope.get("audit")
        if audit is not None:
            self._last_executor_audit = audit
        return {
            "verdict": verdict,
            "evidence": evidence,
            "correction": correction,
            "verdict_format": "envelope",
        }


class NoDispatch(Exception):
    pass


def executor_command(settings: dict[str, Any] | None = None) -> list[str]:
    del settings
    override = os.environ.get("LORE_SETTLEMENT_EXECUTOR", "").strip()
    if override:
        return shlex.split(override)
    return [str(Path(__file__).resolve().with_name("settlement-audit-executor.sh"))]


def settings_path() -> Path:
    override = os.environ.get("LORE_SETTLEMENT_SETTINGS_FILE")
    if override:
        return Path(override)
    data_dir = Path(os.environ.get("LORE_DATA_DIR") or Path.home() / ".lore")
    return data_dir / "config" / "settings.json"


def read_settings_doc() -> dict[str, Any]:
    path = settings_path()
    if not path.exists():
        return {}
    try:
        data = json_load(path, {})
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def settlement_settings() -> dict[str, Any]:
    raw = read_settings_doc().get("settlement", {})
    if not isinstance(raw, dict):
        raw = {}
    active_hours = raw.get("active_hours") if isinstance(raw.get("active_hours"), dict) else {}
    hs = raw.get("harness_selection") if isinstance(raw.get("harness_selection"), dict) else {}
    dispatch = raw.get("dispatch") if isinstance(raw.get("dispatch"), dict) else {}
    ranges = []
    if isinstance(active_hours.get("ranges"), list):
        ranges = [r for r in (parse_active_hours_range(x) for x in active_hours.get("ranges", [])) if r is not None]
    return {
        "enabled": bool(raw.get("enabled", False)),
        "max_concurrency": parse_int(raw.get("max_concurrency"), 1, 1),
        "lease_ttl_seconds": parse_int(raw.get("lease_ttl_seconds"), 900, 1),
        "executor_timeout_seconds": parse_int(raw.get("executor_timeout_seconds"), DEFAULT_EXECUTOR_TIMEOUT_SECONDS, 1),
        "batch_size": parse_int(raw.get("batch_size"), DEFAULT_BATCH_SIZE, 1),
        "batch_recompute_min_interval_seconds": parse_int(raw.get("batch_recompute_min_interval_seconds"), DEFAULT_BATCH_RECOMPUTE_MIN_INTERVAL_SECONDS, 0),
        "concordance_window_size": parse_int(raw.get("concordance_window_size"), DEFAULT_CONCORDANCE_WINDOW_SIZE, 0),
        "active_hours": {
            "enabled": bool(active_hours.get("enabled", False)),
            "timezone": active_hours.get("timezone") if isinstance(active_hours.get("timezone"), str) and active_hours.get("timezone") else "local",
            "ranges": ranges,
        },
        "harness_selection": {
            "mode": hs.get("mode", "first_eligible"),
            "eligible_frameworks": hs.get("eligible_frameworks") if isinstance(hs.get("eligible_frameworks"), list) else [],
            "random_seed": int(hs.get("random_seed", 0)),
        },
        # Dispatch posture (memo §5.2): census_enabled=false is the default
        # event-driven posture; true re-enables the dormant census wholesale
        # (scan-era recompute refill + TUI auto-process backlog arm).
        "dispatch": {
            "census_enabled": bool(dispatch.get("census_enabled", False)),
            "spot_sample_weekly_budget": parse_int(dispatch.get("spot_sample_weekly_budget"), DEFAULT_SPOT_SAMPLE_WEEKLY_BUDGET, 0),
        },
    }


def resolve_kdir(arg: str | None) -> Path:
    if arg:
        return Path(arg)
    script_dir = Path(__file__).resolve().parent
    proc = subprocess.run([str(script_dir / "resolve-repo.sh")], text=True, capture_output=True, check=False)
    if proc.returncode != 0:
        raise SystemExit(proc.stderr or "could not resolve knowledge directory")
    return Path(proc.stdout.strip())


def main() -> int:
    ap = argparse.ArgumentParser(prog="settlement-processor.py")
    ap.add_argument("command", choices=["enqueue", "scan", "status", "process", "enable", "disable", "queue", "retry-errors", "drain", "enqueue-rollup-backfill", "triggers"])
    ap.add_argument("subcommand", nargs="?")
    ap.add_argument("--kdir")
    ap.add_argument("--work-item")
    ap.add_argument("--kind", choices=list(KINDS), default=KIND_TASK_CLAIM)
    ap.add_argument("--claim-id", action="append", default=[])
    ap.add_argument("--row-file")
    ap.add_argument("--once", action="store_true")
    ap.add_argument("--force", action="store_true", help="triggers: bypass the pump throttle")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--max-iterations", type=int, default=200)
    ap.add_argument("--weeks", type=int, default=ROLLUP_BACKFILL_DEFAULT_WEEKS, help="enqueue-rollup-backfill: number of trailing completed weekly windows (1-104)")
    ap.add_argument("--judge", choices=list(ROLLUP_JUDGES), default=None, help="enqueue-rollup-backfill: limit to one judge (default: all 5)")
    args = ap.parse_args()

    settlement = Settlement(resolve_kdir(args.kdir))
    settings = settlement_settings()

    if args.command == "enqueue":
        if not args.work_item:
            raise SystemExit("[settlement] Error: enqueue requires --work-item")
        row_text = Path(args.row_file).read_text(encoding="utf-8") if args.row_file else sys.stdin.read()
        out = settlement.enqueue_row(args.work_item, json.loads(row_text), args.kind)
    elif args.command == "scan":
        out = settlement.scan()
    elif args.command == "status":
        out = settlement.status(settings)
    elif args.command == "enable":
        out = settlement.set_enabled(True)
    elif args.command == "disable":
        out = settlement.set_enabled(False)
    elif args.command == "process":
        if not args.once:
            raise SystemExit("[settlement] Error: process currently requires --once")
        out = settlement.process_once(settings)
    elif args.command == "queue":
        if args.subcommand != "recompute":
            raise SystemExit("[settlement] Error: queue currently requires recompute")
        out = settlement.recompute_queue(settings, reason="manual", force=False)
    elif args.command == "retry-errors":
        out = settlement.retry_error_audits(work_item=args.work_item, claim_ids=args.claim_id, dry_run=args.dry_run)
    elif args.command == "drain":
        if args.max_iterations <= 0:
            raise SystemExit("[settlement] Error: --max-iterations must be > 0")
        out = settlement.drain(settings, max_iterations=args.max_iterations)
    elif args.command == "enqueue-rollup-backfill":
        judges = [args.judge] if args.judge else None
        out = settlement.enqueue_rollup_backfill(weeks=args.weeks, judges=judges)
    elif args.command == "triggers":
        out = settlement.pump_triggers(settings, force=args.force)
    else:
        raise AssertionError(args.command)

    if args.json:
        print(json.dumps(out, sort_keys=True))
    else:
        print(compact(out))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
