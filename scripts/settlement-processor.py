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
from datetime import datetime, timezone
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


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


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
        # In-memory predicate cache for the path-to-commons filter (D3).
        # Key: (item_id, predicate_input_hash, resolver_version) → state dict.
        # Rebuilds on restart — this is bounded-cost-per-recompute caching,
        # not durable state.
        self._path_to_commons_cache: dict[tuple[str, str, str], dict[str, Any]] = {}

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
                    "id": "sha256(work_item:claim_id)",
                    "kind": "task-claim",
                    "status": "pending|leased",
                    "work_item": "slug",
                    "claim_id": "Tier 2 claim_id",
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

    def item_id(self, work_item: str, claim_id: str) -> str:
        digest = hashlib.sha256(f"{work_item}:{claim_id}".encode()).hexdigest()[:20]
        return f"task-claim-{digest}"

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

    def item_from_row(self, work_item: str, row: dict[str, Any], order: int) -> dict[str, Any]:
        claim_id = str(row.get("claim_id") or "")
        source = row.get("source") if isinstance(row.get("source"), dict) else {}
        context, context_source = self.row_change_context(row)
        return {
            "id": self.item_id(work_item, claim_id),
            "kind": "task-claim",
            "status": "pending",
            "work_item": work_item,
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

    def enqueue_row(self, work_item: str, row: dict[str, Any]) -> dict[str, Any]:
        self.ensure()
        claim_id = str(row.get("claim_id") or "")
        if not claim_id:
            raise SystemExit("[settlement] Error: Tier 2 row missing claim_id")
        invalid_reason = self.task_claim_invalid_reason(work_item, row)
        if invalid_reason:
            raise ValueError(f"invalid Tier 2 row: {invalid_reason}")
        item_id = self.item_id(work_item, claim_id)
        with repo_lock(self.state):
            queue = self.load_queue()
            for item in queue["items"]:
                if item.get("id") == item_id:
                    return {"ok": True, "action": "duplicate", "item": item, "queue_path": str(self.queue_path)}
            item = self.item_from_row(work_item, row, len(queue.get("items", [])))
            item["enqueued_at"] = utc_now()
            item.pop("_backlog_order", None)
            queue["items"].append(item)
            self.save_queue(queue)
            return {"ok": True, "action": "enqueued", "item": item, "queue_path": str(self.queue_path)}

    def scan(self) -> dict[str, Any]:
        self.ensure()
        scanned = 0
        enqueued = 0
        duplicates = 0
        errors: list[str] = []
        work_root = self.kdir / "_work"
        if not work_root.exists():
            return {"ok": True, "scanned": 0, "enqueued": 0, "duplicates": 0, "errors": []}
        for claims in sorted(work_root.glob("*/task-claims.jsonl")):
            work_item = claims.parent.name
            with claims.open(encoding="utf-8") as fh:
                for line_no, line in enumerate(fh, 1):
                    if not line.strip():
                        continue
                    scanned += 1
                    try:
                        row = json.loads(line)
                        res = self.enqueue_row(work_item, row)
                        if res["action"] == "enqueued":
                            enqueued += 1
                        else:
                            duplicates += 1
                    except Exception as exc:  # continue scanning other rows
                        errors.append(f"{claims}:{line_no}: {exc}")
        return {"ok": not errors, "scanned": scanned, "enqueued": enqueued, "duplicates": duplicates, "errors": errors}

    def iter_backlog_items(self) -> tuple[list[dict[str, Any]], list[str]]:
        errors: list[str] = []
        items: list[dict[str, Any]] = []
        seen: set[str] = set()
        work_root = self.kdir / "_work"
        if not work_root.exists():
            return items, errors
        order = 0
        for claims in sorted(work_root.glob("*/task-claims.jsonl")):
            work_item = claims.parent.name
            try:
                lines = claims.read_text(encoding="utf-8").splitlines()
            except OSError as exc:
                errors.append(f"{claims}: {exc}")
                continue
            for line_no, line in enumerate(lines, 1):
                if not line.strip():
                    continue
                try:
                    row = json.loads(line)
                    claim_id = str(row.get("claim_id") or "")
                    if not claim_id:
                        raise ValueError("Tier 2 row missing claim_id")
                    invalid_reason = self.task_claim_invalid_reason(work_item, row)
                    if invalid_reason:
                        raise ValueError(f"invalid Tier 2 row: {invalid_reason}")
                    item = self.item_from_row(work_item, row, order)
                    item["evidence_ref"]["line"] = line_no
                    order += 1
                    if item["id"] in seen:
                        continue
                    seen.add(item["id"])
                    items.append(item)
                except Exception as exc:
                    errors.append(f"{claims}:{line_no}: {exc}")
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
            row = self.find_task_claim_row(str(run.get("work_item") or ""), str(run.get("claim_id") or "")) or {}
            source = row.get("source") if isinstance(row.get("source"), dict) else {}
            out.append({
                "id": run.get("item_id"),
                "kind": "task-claim",
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
            })
        out.sort(key=lambda item: str(item.get("completed_at") or ""), reverse=True)
        return out[:limit]

    def item_invalid_reason(self, item: dict[str, Any]) -> str:
        work_item = str(item.get("work_item") or "")
        claim_id = str(item.get("claim_id") or "")
        if not work_item or not claim_id:
            return "queue item missing work_item or claim_id"
        row = self.find_task_claim_row(work_item, claim_id)
        if row is None:
            item_row = {
                "claim_id": claim_id,
                "claim": item.get("claim"),
                "file": (item.get("source") or {}).get("file") if isinstance(item.get("source"), dict) else None,
                "line_range": (item.get("source") or {}).get("line_range") if isinstance(item.get("source"), dict) else None,
                "falsifier": item.get("falsifier"),
                "change_context": item.get("change_context"),
            }
            item_reason = self.task_claim_invalid_reason(work_item, item_row)
            if not item_reason:
                return ""
            return f"missing task-claims row for {work_item}/{claim_id}"
        return self.task_claim_invalid_reason(work_item, row)

    def write_invalid_claim_run(self, item: dict[str, Any], reason: str) -> dict[str, Any]:
        run_id = f"run-{hashlib.sha256((str(item.get('id') or '') + utc_now()).encode()).hexdigest()[:20]}"
        evidence = f"invalid Tier 2 claim skipped before executor: {reason}"
        if len(evidence) > 240:
            evidence = evidence[:237] + "..."
        run = {
            "version": VERSION,
            "run_id": run_id,
            "item_id": item.get("id"),
            "work_item": item.get("work_item"),
            "claim_id": item.get("claim_id"),
            "claim": item.get("claim"),
            "source": item.get("source"),
            "falsifier": item.get("falsifier"),
            "framework": "",
            "framework_capability": {},
            "status": "completed",
            "reason": "invalid_task_claim",
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
        return ""

    def find_task_claim_row(self, work_item: str, claim_id: str) -> dict[str, Any] | None:
        path = self.kdir / "_work" / work_item / "task-claims.jsonl"
        if not path.exists():
            return None
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except OSError:
            return None
        for line_no, line in enumerate(lines, 1):
            if not line.strip():
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(row, dict):
                continue
            if str(row.get("claim_id") or "") == claim_id:
                row = dict(row)
                row.setdefault("evidence_ref", {"path": f"_work/{work_item}/task-claims.jsonl", "line": line_no})
                return row
        return None

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

            targets: list[tuple[dict[str, Any], dict[str, Any], str]] = []
            skipped: list[dict[str, Any]] = []
            for run in latest_by_item.values():
                retry_reason = self.retryable_infrastructure_failure_reason(run)
                if not retry_reason:
                    continue
                run_work_item = str(run.get("work_item") or "")
                run_claim_id = str(run.get("claim_id") or "")
                item_id = str(run.get("item_id") or "")
                if work_item and run_work_item != work_item:
                    continue
                if claim_filter and run_claim_id not in claim_filter:
                    continue
                if item_id in active_item_ids:
                    skipped.append({"run_id": run.get("run_id"), "item_id": item_id, "reason": "active_lease"})
                    continue
                if item_id in queued_item_ids:
                    skipped.append({"run_id": run.get("run_id"), "item_id": item_id, "reason": "already_queued"})
                    continue
                row = self.find_task_claim_row(run_work_item, run_claim_id)
                if row is None:
                    skipped.append({"run_id": run.get("run_id"), "item_id": item_id, "reason": "missing_task_claim"})
                    continue
                targets.append((run, row, retry_reason))

            retry_items: list[dict[str, Any]] = []
            batch_id = f"retry-{hashlib.sha256((utc_now() + str(len(targets))).encode()).hexdigest()[:16]}"
            recomputed_at = utc_now()
            for order, (run, row, retry_reason) in enumerate(targets):
                item = self.item_from_row(str(run.get("work_item") or ""), row, order)
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
                for run, _row, retry_reason in targets:
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

    def _templated_text(self, text: Any) -> bool:
        if not isinstance(text, str):
            return True
        s = text.strip()
        if not s:
            return True
        if len(s) < 40:
            return True
        return s.startswith(("TODO", "<", "{{"))

    def _predicate_input_hash(self, item: dict[str, Any]) -> str:
        source = item.get("source") if isinstance(item.get("source"), dict) else {}
        parts = [
            str(item.get("claim") or ""),
            str(source.get("file") or ""),
            str(source.get("line_range") or ""),
            str(item.get("falsifier") or ""),
        ]
        return hashlib.sha256("|".join(parts).encode("utf-8")).hexdigest()

    def _run_find_correction_targets(self, claim_text: str, file_line: str) -> dict[str, Any] | None:
        """Invoke find-correction-targets.sh --json. Returns the parsed JSON
        dict on success, or None on subprocess failure (logged to stderr)."""
        script = Path(__file__).resolve().with_name("find-correction-targets.sh")
        try:
            proc = subprocess.run(
                ["bash", str(script), "--json", "--claim-text", claim_text, "--file-line", file_line],
                text=True,
                capture_output=True,
                timeout=15,
                check=False,
                env={**os.environ, "LORE_KNOWLEDGE_DIR": str(self.kdir)},
            )
        except Exception as exc:
            sys.stderr.write(f"[settlement] path-to-commons predicate: subprocess failed: {exc}\n")
            return None
        if proc.returncode != 0:
            sys.stderr.write(f"[settlement] path-to-commons predicate: find-correction-targets.sh exit {proc.returncode}: {proc.stderr[-500:]}\n")
            return None
        try:
            return json.loads(proc.stdout)
        except json.JSONDecodeError as exc:
            sys.stderr.write(f"[settlement] path-to-commons predicate: malformed JSON: {exc}\n")
            return None

    def has_commons_path(self, item: dict[str, Any]) -> dict[str, Any]:
        """Three-state predicate for D3/D4. Returns a dict shape:
            {"state": <has-path|no-path-definite|no-path-heuristic|unknown>,
             "reason": <templated-claim|templated-falsifier|no-discoverable-target|concordance-stale|null>,
             "resolver_version": <str>,
             "predicate_called": <bool>}
        Cached on (item_id, predicate_input_hash, resolver_version) — the
        resolver_version is unknown until the subprocess runs, so cache
        lookups use the wildcard sentinel until we've made one call.
        """
        # Templated detection runs first — it's free and a definite-invalid
        # signal that doesn't need resolver state.
        if self._templated_text(item.get("claim")):
            return {"state": "no-path-definite", "reason": "templated-claim", "resolver_version": "n/a", "predicate_called": False}
        if self._templated_text(item.get("falsifier")):
            return {"state": "no-path-definite", "reason": "templated-falsifier", "resolver_version": "n/a", "predicate_called": False}

        item_id = str(item.get("id") or "")
        input_hash = self._predicate_input_hash(item)
        # First-pass cache lookup: any resolver_version (the cache key
        # third element is the value the subprocess returned previously).
        for (cached_item_id, cached_hash, _ver), cached in self._path_to_commons_cache.items():
            if cached_item_id == item_id and cached_hash == input_hash:
                return cached

        source = item.get("source") if isinstance(item.get("source"), dict) else {}
        claim_text = str(item.get("claim") or "")
        file_line = f"{source.get('file') or ''}:{source.get('line_range') or ''}"
        resolved = self._run_find_correction_targets(claim_text, file_line)
        if resolved is None:
            # Resolver failure — treat as unknown so the row passes through.
            result = {"state": "unknown", "reason": "concordance-stale", "resolver_version": "v1", "predicate_called": True}
            self._path_to_commons_cache[(item_id, input_hash, result["resolver_version"])] = result
            return result

        targets = resolved.get("targets") if isinstance(resolved.get("targets"), list) else []
        index_state = resolved.get("index_state") or "missing"
        resolver_version = str(resolved.get("resolver_version") or "v1")

        if index_state == "missing":
            result = {"state": "unknown", "reason": "concordance-stale", "resolver_version": resolver_version, "predicate_called": True}
        elif index_state == "stale" and not targets:
            result = {"state": "unknown", "reason": "concordance-stale", "resolver_version": resolver_version, "predicate_called": True}
        elif targets:
            result = {"state": "has-path", "reason": None, "resolver_version": resolver_version, "predicate_called": True}
        else:
            # index_state == "ready" with zero targets — heuristic no-path.
            result = {"state": "no-path-heuristic", "reason": "no-discoverable-target", "resolver_version": resolver_version, "predicate_called": True}
        self._path_to_commons_cache[(item_id, input_hash, resolver_version)] = result
        return result

    def _emit_filtered_claim(self, item: dict[str, Any], state: dict[str, Any], stage: str, mode: str, enqueued_anyway: bool) -> None:
        """Shell out to filtered-claim-append.sh (sole-writer). Failures are
        logged to stderr and swallowed — sidecar emission is best-effort and
        must never poison the recompute path."""
        work_item = str(item.get("work_item") or "")
        claim_id = str(item.get("claim_id") or "")
        source = item.get("source") if isinstance(item.get("source"), dict) else {}
        file_path = str(source.get("file") or "")
        line_range = str(source.get("line_range") or "")
        reason = state.get("reason") or ""
        resolver_version = str(state.get("resolver_version") or "v1")
        change_context = item.get("change_context")
        if not isinstance(change_context, dict):
            change_context = {"diff_ref": None, "changed_files": [file_path] if file_path else [], "summary": "synthesized for filtered-claim emission"}
        if not work_item or not claim_id or not file_path or not line_range or not reason:
            sys.stderr.write(f"[settlement] filtered-claim emission skipped: missing required field (work_item/claim_id/file/line_range/reason)\n")
            return
        script = Path(__file__).resolve().with_name("filtered-claim-append.sh")
        cmd = [
            "bash", str(script),
            "--work-item", work_item,
            "--claim-id", claim_id,
            "--reason", reason,
            "--mode", mode,
            "--stage", stage,
            "--file", file_path,
            "--line-range", line_range,
            "--change-context", json.dumps(change_context, separators=(",", ":")),
            "--enqueued-anyway", "true" if enqueued_anyway else "false",
            "--resolver-version", resolver_version,
            "--kdir", str(self.kdir),
        ]
        try:
            proc = subprocess.run(cmd, text=True, capture_output=True, timeout=10, check=False)
            if proc.returncode != 0:
                sys.stderr.write(f"[settlement] filtered-claim-append.sh exit {proc.returncode}: {proc.stderr[-500:]}\n")
        except Exception as exc:
            sys.stderr.write(f"[settlement] filtered-claim-append.sh failed: {exc}\n")

    def apply_path_to_commons_filter(
        self,
        backlog: list[dict[str, Any]],
        preserved_ids: set[str],
        terminal_ids: set[str],
        settings: dict[str, Any],
    ) -> tuple[set[str], dict[str, dict[str, Any]]]:
        """Lazy backlog scan per D3. Returns (no_path_ids, evaluations) where
        no_path_ids is the third parallel exclusion set, and evaluations maps
        item_id → state dict for every row we materialized a decision for.
        """
        ptcf = settings.get("path_to_commons_filter") or {}
        if not ptcf.get("enabled", True):
            return set(), {}
        exclude_reasons = set(ptcf.get("exclude_reasons") or [])
        batch_size = int(settings.get("batch_size", DEFAULT_BATCH_SIZE))
        budget_multiplier = int(ptcf.get("predicate_budget_multiplier", 3) or 3)
        budget = max(1, batch_size * budget_multiplier)

        no_path_ids: set[str] = set()
        evaluations: dict[str, dict[str, Any]] = {}
        has_path_count = 0
        calls = 0
        for item in backlog:
            item_id = str(item.get("id") or "")
            if not item_id:
                continue
            if item_id in preserved_ids or item_id in terminal_ids:
                continue
            if has_path_count >= batch_size and calls >= budget:
                break
            state = self.has_commons_path(item)
            if state.get("predicate_called"):
                calls += 1
            evaluations[item_id] = state
            predicate_reason = state.get("reason") or ""
            kind = state.get("state")
            if kind == "has-path":
                has_path_count += 1
                continue
            # Map the predicate state → sidecar emission (single emission
            # per row). Exclude vs report-only is settings-driven via
            # exclude_reasons (D5: only listed reasons promote to exclude).
            if predicate_reason and predicate_reason in exclude_reasons:
                no_path_ids.add(item_id)
                self._emit_filtered_claim(item, state, stage="pre-enqueue", mode="exclude", enqueued_anyway=False)
            else:
                # Report-only — row remains in the candidate set.
                if calls <= budget:
                    self._emit_filtered_claim(item, state, stage="pre-enqueue", mode="report-only", enqueued_anyway=True)
        return no_path_ids, evaluations

    def apply_recomputed_batch(self, queue: dict[str, Any], settings: dict[str, Any], reason: str) -> dict[str, Any]:
        active_leased = [item for item in queue.get("items", []) if item.get("status") == "leased"]
        legacy_pending = [item for item in queue.get("items", []) if item.get("status") == "pending"]
        preserved_ids = {item.get("id") for item in active_leased}
        terminal_ids = self.terminal_run_item_ids()
        backlog, errors = self.iter_backlog_items()
        backlog_ids = {item.get("id") for item in backlog}
        for item in legacy_pending:
            if item.get("id") in backlog_ids:
                continue
            clone = dict(item)
            clone["_backlog_order"] = len(backlog)
            clone.pop("selection_score", None)
            clone.pop("selection_reason", None)
            clone.pop("batch_id", None)
            clone.pop("selected_at", None)
            backlog.append(clone)
        # D3: path-to-commons filter — third parallel exclusion set
        # alongside preserved_ids and terminal_ids. Lazy evaluation bounded
        # by batch_size + predicate_budget_multiplier; emits filtered-claims
        # sidecar rows via sole-writer for every non-has-path decision.
        no_path_ids, _ptcf_evaluations = self.apply_path_to_commons_filter(backlog, preserved_ids, terminal_ids, settings)
        candidates = [item for item in backlog if item.get("id") not in preserved_ids and item.get("id") not in terminal_ids and item.get("id") not in no_path_ids]
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
        queue["items"] = active_leased + pending
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
        backlog_waiting = self.active_batch_drained_with_backlog(queue)
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
        return {
            "ok": True,
            "enabled": bool(settings["enabled"]),
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

    def process_once(self, settings: dict[str, Any]) -> dict[str, Any]:
        self.ensure()
        if not settings["enabled"]:
            return {"ok": True, "dispatched": False, "reason": "disabled"}
        active_hours = self.active_hours_status(settings)
        if not active_hours["allowed"]:
            return {"ok": True, "dispatched": False, "reason": active_hours["reason"], "active_hours": active_hours}
        eligible, rejected = self.eligible_frameworks(settings)
        if not eligible:
            return {"ok": True, "dispatched": False, "reason": "no_eligible_harnesses", "rejected_harnesses": rejected}
        executor = executor_command(settings)

        with repo_lock(self.state):
            queue = self.load_queue()
            leases = self.load_leases()
            healed = self.heal_queue(queue, leases)
            expired = self.expire_stale_leases(queue, leases)
            active = [l for l in leases.get("leases", {}).values() if l.get("state") == "active"]
            if len(active) >= int(settings["max_concurrency"]):
                self.save_queue(queue)
                self.save_leases(leases)
                return {"ok": True, "dispatched": False, "reason": "max_concurrency_reached", "active_leases": len(active), "expired_leases_reclaimed": expired}
            legacy_pending = any(it.get("status") == "pending" and not it.get("selection_reason") for it in queue.get("items", []))
            if legacy_pending:
                self.apply_recomputed_batch(queue, settings, "legacy_pending_normalization")
            item = next((it for it in queue.get("items", []) if it.get("status") == "pending"), None)
            if item is None:
                if self.active_batch_drained_with_backlog(queue) or self.should_recompute(queue, settings):
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

    def execute_item(self, item: dict[str, Any], run_id: str, chosen: dict[str, Any], settings: dict[str, Any], executor: list[str]) -> dict[str, Any]:
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
        run = {
            "version": VERSION,
            "run_id": run_id,
            "item_id": item["id"],
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
        self._invoke_post_verdict_hook(written, item)
        self._apply_correction_from_verdict(written, item)
        return written

    def _apply_correction_from_verdict(self, run: dict[str, Any], item: dict[str, Any]) -> None:
        """Autonomous correction terminus. On contradicted verdicts, attempt to
        mutate the commons entry directly via apply-correction.sh with
        --allow-settlement-verdict. This replaces the previous post-verdict hook
        indirection (correction-candidates.jsonl sidecar + deferred calibration
        consumer) with a single-shot mutation gated on exact superseded_text match.

        Failure modes are all silent terminal skips (logged to stderr only):
          - find-correction-targets returns no targets   → no commons home
          - find-correction-targets index_state==missing → concordance unavailable
          - apply-correction exit 2 (text not in entry)  → not_mechanically_applicable
          - apply-correction exit 4 (auth check failed)  → run record drift; shouldn't happen
          - apply-correction other non-zero              → logged; continue

        The audit trail lives in: (a) the settlement run record, (b) git commits
        on the entry, (c) the entry's corrections[] META block. No supersedes
        archive is created (--check-escalation is NOT passed): git history is
        the authoritative version trail.
        """
        verdict = run.get("verdict") if isinstance(run.get("verdict"), dict) else {}
        if verdict.get("verdict") != "contradicted":
            return
        if os.environ.get("LORE_SETTLEMENT_DISABLE_AUTO_CORRECTION", "").strip():
            return
        run_id = str(run.get("run_id") or "")
        if not run_id:
            return
        correction_text = verdict.get("correction")
        if not (isinstance(correction_text, str) and correction_text.strip()):
            sys.stderr.write(f"[settlement] auto-correction skipped run_id={run_id}: empty correction text\n")
            return
        evidence_text = verdict.get("evidence") or ""
        claim_text = item.get("claim") or ""
        if not claim_text.strip():
            sys.stderr.write(f"[settlement] auto-correction skipped run_id={run_id}: empty claim text\n")
            return
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
                find_cmd, text=True, capture_output=True, timeout=30, check=False,
            )
        except (subprocess.TimeoutExpired, OSError) as exc:
            sys.stderr.write(f"[settlement] auto-correction skipped run_id={run_id}: find-correction-targets failed: {exc}\n")
            return
        if find_proc.returncode != 0 or not find_proc.stdout.strip():
            sys.stderr.write(f"[settlement] auto-correction skipped run_id={run_id}: find-correction-targets exit {find_proc.returncode}\n")
            return
        try:
            find_result = json.loads(find_proc.stdout)
        except json.JSONDecodeError as exc:
            sys.stderr.write(f"[settlement] auto-correction skipped run_id={run_id}: find-correction-targets JSON parse: {exc}\n")
            return
        index_state = find_result.get("index_state")
        targets = find_result.get("targets") or []
        if index_state == "missing":
            sys.stderr.write(f"[settlement] auto-correction skipped run_id={run_id}: concordance index missing\n")
            return
        if not targets:
            sys.stderr.write(f"[settlement] auto-correction skipped run_id={run_id}: no commons target for claim\n")
            return
        target = targets[0]
        target_path = str(target.get("path") or "")
        if not target_path:
            sys.stderr.write(f"[settlement] auto-correction skipped run_id={run_id}: target row missing path\n")
            return
        # find-correction-targets returns paths relative to KDIR; resolve absolute.
        kdir = str(getattr(self, "kdir", "") or os.environ.get("LORE_KNOWLEDGE_DIR", ""))
        if kdir and not os.path.isabs(target_path):
            target_path = os.path.join(kdir, target_path)
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
                apply_cmd, text=True, capture_output=True, timeout=30, check=False,
            )
        except (subprocess.TimeoutExpired, OSError) as exc:
            sys.stderr.write(f"[settlement] auto-correction failed run_id={run_id}: apply-correction subprocess: {exc}\n")
            return
        if apply_proc.returncode == 0:
            sys.stderr.write(f"[settlement] auto-correction APPLIED run_id={run_id} entry={target_path}\n")
            return
        if apply_proc.returncode == 2:
            sys.stderr.write(f"[settlement] auto-correction skipped run_id={run_id}: superseded_text not present in {target_path} (not_mechanically_applicable)\n")
            return
        sys.stderr.write(f"[settlement] auto-correction failed run_id={run_id}: apply-correction exit {apply_proc.returncode}: {apply_proc.stderr[-500:]}\n")

    def _invoke_post_verdict_hook(self, run: dict[str, Any], item: dict[str, Any]) -> None:
        """Post-verdict propagation hook (D2). Fires after write_run_record_once
        ONLY when verdict.verdict == "contradicted". For verified/unverified/
        skipped/error verdicts the hook is bypassed (only contradicted verdicts
        produce candidates per plan Goal).

        Payload on stdin: a single JSON object {run, item, task_claim} where
        task_claim is the rehydrated Tier-2 row keyed by claim_id. The run
        record alone is never the payload — Tier-2 fields like change_context
        and scale are not represented in the run.

        Fail-open: any hook failure logs a warning to stderr and is swallowed.
        The reconciliation backstop discovers gaps on the next run."""
        verdict = run.get("verdict") if isinstance(run.get("verdict"), dict) else {}
        if verdict.get("verdict") != "contradicted":
            return
        hook = os.environ.get("LORE_SETTLEMENT_POST_HOOK", "").strip()
        if not hook:
            return
        work_item = str(run.get("work_item") or item.get("work_item") or "")
        claim_id = str(run.get("claim_id") or item.get("claim_id") or "")
        if not work_item or not claim_id:
            sys.stderr.write(f"[settlement] post-hook: missing work_item/claim_id for run_id={run.get('run_id')}\n")
            return
        task_claim = self.find_task_claim_row(work_item, claim_id)
        if task_claim is None:
            sys.stderr.write(f"[settlement] post-hook: rehydration_failed for run_id={run.get('run_id')}\n")
            return
        # Normalize the rehydrated row: settlement.find_task_claim_row returns
        # the original Tier-2 row; we project the fields the hook payload
        # expects. Fall through to keys present on the row for forward-compat.
        source = task_claim.get("source") if isinstance(task_claim.get("source"), dict) else {}
        normalized = dict(task_claim)
        normalized.setdefault("file", task_claim.get("file") or source.get("file"))
        normalized.setdefault("line_range", task_claim.get("line_range") or source.get("line_range"))
        normalized.setdefault("work_item", work_item)
        payload = {"run": run, "item": item, "task_claim": normalized}
        try:
            proc = subprocess.run(
                shlex.split(hook),
                input=compact(payload),
                text=True,
                capture_output=True,
                timeout=30,
                check=False,
            )
            if proc.returncode != 0:
                sys.stderr.write(f"[settlement] post-hook: exit {proc.returncode} for run_id={run.get('run_id')}: {proc.stderr[-500:]}\n")
        except Exception as exc:
            sys.stderr.write(f"[settlement] post-hook: subprocess failed for run_id={run.get('run_id')}: {exc}\n")

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
    ranges = []
    if isinstance(active_hours.get("ranges"), list):
        ranges = [r for r in (parse_active_hours_range(x) for x in active_hours.get("ranges", [])) if r is not None]
    ptcf_raw = raw.get("path_to_commons_filter") if isinstance(raw.get("path_to_commons_filter"), dict) else {}
    ptcf_exclude_default = ["templated-claim", "templated-falsifier"]
    ptcf_exclude = ptcf_raw.get("exclude_reasons")
    if isinstance(ptcf_exclude, list):
        ptcf_exclude = [r for r in ptcf_exclude if isinstance(r, str) and r in {
            "templated-claim", "templated-falsifier", "no-discoverable-target", "concordance-stale",
        }]
    else:
        ptcf_exclude = list(ptcf_exclude_default)
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
        "path_to_commons_filter": {
            "enabled": bool(ptcf_raw.get("enabled", True)),
            "exclude_reasons": ptcf_exclude,
            "predicate_budget_multiplier": parse_int(ptcf_raw.get("predicate_budget_multiplier"), 3, 1),
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
    ap.add_argument("command", choices=["enqueue", "scan", "status", "process", "enable", "disable", "queue", "retry-errors"])
    ap.add_argument("subcommand", nargs="?")
    ap.add_argument("--kdir")
    ap.add_argument("--work-item")
    ap.add_argument("--claim-id", action="append", default=[])
    ap.add_argument("--row-file")
    ap.add_argument("--once", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    settlement = Settlement(resolve_kdir(args.kdir))
    settings = settlement_settings()

    if args.command == "enqueue":
        if not args.work_item:
            raise SystemExit("[settlement] Error: enqueue requires --work-item")
        row_text = Path(args.row_file).read_text(encoding="utf-8") if args.row_file else sys.stdin.read()
        out = settlement.enqueue_row(args.work_item, json.loads(row_text))
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
    else:
        raise AssertionError(args.command)

    if args.json:
        print(json.dumps(out, sort_keys=True))
    else:
        print(compact(out))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
