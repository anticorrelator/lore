#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# Read-only vocabulary mirrors. Tests compare the session and retro tokens to
# their sole appenders so producer drift fails loudly at review time.
SESSION_EVENT_VOCAB="requested claimed spawned needs_input resumed recovered closed orphaned step_completed terminus_reached spawn_failed request_reclaimed request_abandoned request_cancelled request_expired close_requested close_failed restore_refused worktree_quarantined worktree_no_changes worktree_published worktree_write_refused interrupt_requested interrupt_sent interrupt_refused send_requested sent send_refused answer_requested answered answer_refused modal_blocked"
RETRO_ACTION_VOCAB="dispatched deferred skipped"
CEREMONY_OUTCOME_VOCAB="needs-decision"
CEREMONY_DISPOSITION_VOCAB="unhandled handled"

usage() {
  cat >&2 <<'EOF'
Usage: coordinate-status.sh [--kdir <path>] [--json] [--wake-id <id>] [--full-evidence] [--receipt-only]

Render a five-source coordination projection. Without --wake-id this is read-only.
--wake-id includes that owner-bound delivery receipt and explicitly acknowledges
it after output succeeds. A receipt does not report that follow-up work completed.
The receipt is compact by default. --full-evidence includes its complete retained
historical evidence and current presentation; it requires --wake-id.
--receipt-only omits the board and returns only the requested receipt; it also
requires --wake-id. The JSON envelope is schema version 1.
EOF
}

KDIR_OVERRIDE=""
JSON_MODE=0
WAKE_ID=""
FULL_EVIDENCE=0
RECEIPT_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kdir) KDIR_OVERRIDE="${2:-}"; shift 2 ;;
    --json) JSON_MODE=1; shift ;;
    --full-evidence) FULL_EVIDENCE=1; shift ;;
    --receipt-only) RECEIPT_ONLY=1; shift ;;
    --wake-id) WAKE_ID="${2:-}"; [[ -n "$WAKE_ID" ]] || { echo "--wake-id requires an exact wake identity" >&2; exit 1; }; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Error: unknown argument '$1'" >&2; usage; exit 1 ;;
  esac
done

[[ $FULL_EVIDENCE -eq 0 || -n "$WAKE_ID" ]] || die "--full-evidence requires --wake-id"
[[ $RECEIPT_ONLY -eq 0 || -n "$WAKE_ID" ]] || die "--receipt-only requires --wake-id"

command -v python3 >/dev/null 2>&1 || die "python3 is required but not found on PATH"

if [[ -n "$KDIR_OVERRIDE" ]]; then
  KNOWLEDGE_DIR="$KDIR_OVERRIDE"
else
  KNOWLEDGE_DIR="$(resolve_knowledge_dir)"
fi
[[ -d "$KNOWLEDGE_DIR" ]] || die "knowledge store not found at: $KNOWLEDGE_DIR"

export WAKE_ID FULL_EVIDENCE RECEIPT_ONLY
export SESSION_EVENT_VOCAB RETRO_ACTION_VOCAB CEREMONY_OUTCOME_VOCAB \
  CEREMONY_DISPOSITION_VOCAB

# The board's own seat ceiling. Missing or malformed settings fail closed to
# one seat.
COORDINATION_MAX_CONCURRENCY=$(bash "$SCRIPT_DIR/settings.sh" get coordination.max_concurrency 2>/dev/null || true)
if [[ ! "$COORDINATION_MAX_CONCURRENCY" =~ ^[1-9][0-9]*$ ]]; then
  COORDINATION_MAX_CONCURRENCY=1
fi
export COORDINATION_MAX_CONCURRENCY

exec python3 - "$KNOWLEDGE_DIR" "$SCRIPT_DIR" "$JSON_MODE" <<'PYEOF'
import datetime as dt
import hashlib
import json
import os
import re
import runpy
import subprocess
import sys
from pathlib import Path
from pathlib import PurePosixPath
from urllib.parse import unquote, urlsplit


kdir = Path(sys.argv[1])
scripts = Path(sys.argv[2])
json_mode = sys.argv[3] == "1"
observed_at = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")

SESSION_EVENTS = set(os.environ["SESSION_EVENT_VOCAB"].split())
RETRO_ACTIONS = set(os.environ["RETRO_ACTION_VOCAB"].split())
CEREMONY_OUTCOMES = set(os.environ["CEREMONY_OUTCOME_VOCAB"].split())
CEREMONY_DISPOSITIONS = set(os.environ["CEREMONY_DISPOSITION_VOCAB"].split())

EXPECTED_VERSION = "1"

# Coordination ledgers live in the arc record, not in the work item — arc-open.sh
# writes _work/_arcs/<slug>/coordination.md and arc-migrate.sh moved the older
# item-local ledgers there.
ARC_ROOT = "_work/_arcs"

# The attempt status that releases a stream for dispatch. Everything before it —
# allocated, dispatched — still holds the stream. The token is declared by
# scripts/coordinate-reconcile.py and quoted here rather than imported: this
# board stays readable when that reader is broken, and imports would put its
# failures in the projection's own call path.
RELEASING_ATTEMPT_STATUS = "coord_report_accepted"

SOURCE_ORDER = [
    "work-index",
    "session-journal",
    "scorecard-rows",
    "retro-queue",
    "evolve-staging",
]

sys.path.insert(0, str(scripts))
from coordinate_reducer import RULES, compact, stable_id, make_row, parse_ledger, ArcReduction, scan_arcs, dispatch_reason


buckets = {"act_now": [], "needs_judgment": [], "waiting": [], "reconcile": []}
manifest = {}
coordination_candidates = []
coordination_active = []
coordination_ceiling = int(os.environ.get("COORDINATION_MAX_CONCURRENCY", "1"))


def source_row(source_id, status, schema_version, vocabulary_version, locator, error=None):
    manifest[source_id] = {
        "source_id": source_id,
        "read_status": status,
        "observed_at": observed_at,
        "schema_version": schema_version,
        "vocabulary_version": vocabulary_version,
        "locator": locator,
        "error": error,
    }


def add_gap(source_id, locator, error, status="gap", schema_version=None, vocabulary_version=None):
    source_row(source_id, status, schema_version, vocabulary_version, locator, error)
    buckets["reconcile"].append(make_row(
        "reconcile", source_id, "source-gap", f"{source_id} coverage gap",
        {"read_status": status, "error": error}, locator, source_id,
        "reconcile.source.gap",
    ))


def parse_time(value):
    if not isinstance(value, str) or not value:
        return None
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def run_reader(name, *args):
    proc = subprocess.run(
        ["bash", str(scripts / name), *args, "--kdir", str(kdir), "--json"],
        text=True, capture_output=True, check=False,
    )
    if proc.returncode != 0:
        detail = proc.stderr.strip() or proc.stdout.strip() or f"exit {proc.returncode}"
        return None, detail, None
    try:
        return json.loads(proc.stdout), None, proc.stderr.strip() or None
    except json.JSONDecodeError as exc:
        return None, f"invalid JSON from published reader: {exc}", None


def version_errors(envelope, label, vocabulary_versions=(EXPECTED_VERSION,), fold_versions=(EXPECTED_VERSION,)):
    errors = []
    fold = envelope.get("fold_version")
    vocab = envelope.get("vocabulary_version")
    if fold is None:
        errors.append(f"{label} missing fold_version declaration")
    elif str(fold) not in fold_versions:
        errors.append(f"{label} unknown fold_version={fold}")
    if vocab is None:
        errors.append(f"{label} missing vocabulary_version declaration")
    elif str(vocab) not in vocabulary_versions:
        errors.append(f"{label} unknown vocabulary_version={vocab}")
    return errors, None if fold is None else str(fold), None if vocab is None else str(vocab)


def line_error_summary(errors):
    if not errors:
        return None
    if len(errors) <= 4:
        return "; ".join(errors)
    return "; ".join(errors[:4]) + f"; and {len(errors) - 4} more"


# --- arc coordination ledgers ---------------------------------------------
arc_records, arc_scan = scan_arcs(kdir, buckets)
reduction = ArcReduction(kdir, arc_scan)
coordination_arcs = [{"arc": record["arc"], "status": record["status"]} for record in arc_records]
arc_coordinated_items = {
    member for record in arc_records
    if record["status"] == "active" and record["has_ledger"]
    for member in record["members"]
}
for record in arc_records:
    if record["status"] in {"active", "closed"} and record["has_ledger"]:
        reduction.project(record, dispatch=record["status"] == "active")
coordination_streams = reduction.streams
coordination_active = reduction.active
coordination_candidates = reduction.candidates


# Evidence uses the same projection as work show, independently of metadata health.
work_evidence = []
try:
    evidence_reader = runpy.run_path(str(scripts / "work-evidence.py"))
    evidence_project = evidence_reader["project"]
    # A command-local snapshot avoids parsing the shared history once per item.
    packet_ledger = evidence_reader["LedgerSnapshot"](
        kdir / "_packets" / "packets.jsonl", kdir, {"1", "2"})
    evidence_error = None
except Exception as exc:
    evidence_project = None
    evidence_error = str(exc)


def summarize_work_evidence(slug, item_dir):
    summary = {"slug": slug, "reader_contract_version": "2",
               "locator": str(item_dir.relative_to(kdir)),
               "inspection_argv": ["lore", "work", "show", slug, "--json"]}
    try:
        if evidence_project is None:
            raise RuntimeError(evidence_error)
        evidence = evidence_project(item_dir, kdir, packet_ledger=packet_ledger)
        summary.update({"state": "read", "schema_version": evidence["schema_version"],
                        "reader_contract_version": evidence["reader_contract_version"],
                        "revision": evidence["revision"],
                        "result_summary": evidence["result_summary"],
                        "packet_summary": evidence["packet_summary"],
                        "review_summary": evidence["review_summary"],
                        "sources": {name: {key: value for key, value in source.items()
                                             if key in ("state", "reason", "path", "sha256")}
                                    for name, source in evidence["sources"].items()}})
    except Exception as exc:
        summary.update({"state": "unreadable", "reason": str(exc)})
    return summary


# --- work-index -----------------------------------------------------------
work_locator = "_work/_index.json"
work_path = kdir / work_locator
if not work_path.is_file():
    add_gap("work-index", work_locator, "required work index is missing")
else:
    try:
        work_index = json.loads(work_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        add_gap("work-index", work_locator, f"work index unreadable: {exc}", status="error")
    else:
        declared = work_index.get("version")
        if declared is None:
            add_gap("work-index", work_locator, "work index missing version declaration")
        elif str(declared) != EXPECTED_VERSION:
            add_gap("work-index", work_locator, f"work index unknown version={declared}", schema_version=str(declared), vocabulary_version=str(declared))
        elif not isinstance(work_index.get("plans"), list):
            add_gap("work-index", work_locator, "work index plans is not an array", status="error", schema_version="1", vocabulary_version="1")
        else:
            source_row("work-index", "ok", "1", "1", work_locator)
            for index_row in work_index["plans"]:
                if not isinstance(index_row, dict) or not isinstance(index_row.get("slug"), str) or not index_row.get("slug"):
                    continue
                slug = index_row["slug"]
                item_dir = kdir / "_work" / slug
                if not item_dir.is_dir() and (kdir / "_work" / "_archive" / slug).is_dir():
                    item_dir = kdir / "_work" / "_archive" / slug
                work_evidence.append(summarize_work_evidence(slug, item_dir))
                meta_path = item_dir / "_meta.json"
                meta_locator = f"_work/{slug}/_meta.json"
                meta = None
                if meta_path.is_file():
                    try:
                        loaded = json.loads(meta_path.read_text(encoding="utf-8"))
                        if isinstance(loaded, dict):
                            meta = loaded
                    except (OSError, json.JSONDecodeError):
                        meta = None

                if meta is None:
                    buckets["reconcile"].append(make_row(
                        "reconcile", "work-index", "work-index-meta-conflict",
                        f"{slug}: indexed item lacks readable metadata",
                        {"index": index_row, "metadata": None}, meta_locator, slug,
                        "reconcile.work.index-meta-conflict",
                    ))
                    continue

                conflicts = {}
                for field in ("slug", "title", "status", "blocked_by"):
                    if field in meta and index_row.get(field) != meta.get(field):
                        conflicts[field] = {"index": index_row.get(field), "metadata": meta.get(field)}
                if conflicts:
                    buckets["reconcile"].append(make_row(
                        "reconcile", "work-index", "work-index-meta-conflict",
                        f"{slug}: work index and metadata disagree",
                        {"slug": slug, "conflicts": conflicts}, meta_locator, [slug, conflicts],
                        "reconcile.work.index-meta-conflict",
                    ))

                explicit_status = meta.get("status") if "status" in meta else index_row.get("status")
                merge_commit = meta.get("merged_commit") or meta.get("merge_commit")
                if explicit_status == "merged" or merge_commit:
                    buckets["reconcile"].append(make_row(
                        "reconcile", "work-index", "merged-but-active",
                        f"{slug}: merged evidence remains in the active index",
                        {"slug": slug, "status": explicit_status, "merge_commit": merge_commit},
                        meta_locator, [slug, explicit_status, merge_commit],
                        "reconcile.work.merged-active",
                    ))

                notes_path = item_dir / "notes.md"
                if notes_path.is_file():
                    try:
                        statuses = re.findall(r"^\*\*Status:\*\*\s*(.+?)\s*$", notes_path.read_text(encoding="utf-8"), re.M)
                    except OSError:
                        statuses = []
                    if statuses and explicit_status and statuses[-1] != explicit_status:
                        buckets["reconcile"].append(make_row(
                            "reconcile", "work-index", "notes-status-conflict",
                            f"{slug}: latest notes status disagrees with work status",
                            {"slug": slug, "work_status": explicit_status, "notes_status": statuses[-1]},
                            f"_work/{slug}/notes.md", [slug, explicit_status, statuses[-1]],
                            "reconcile.work.notes-status-conflict",
                        ))

                item_blockers = index_row.get("blocked_by") if isinstance(index_row.get("blocked_by"), list) else []
                if item_blockers:
                    buckets["waiting"].append(make_row(
                        "waiting", "work-index", "work-blocked",
                        f"{slug}: blocked by {', '.join(map(str, item_blockers))}",
                        {"slug": slug, "blocked_by": item_blockers}, work_locator,
                        [slug, item_blockers], "waiting.work.blocked-by",
                    ))

                not_before = meta.get("not_before")
                if not_before is not None:
                    parsed = parse_time(not_before)
                    now = parse_time(observed_at)
                    if parsed is None:
                        buckets["reconcile"].append(make_row(
                            "reconcile", "work-index", "invalid-not-before",
                            f"{slug}: not_before is not a valid timestamp",
                            {"slug": slug, "not_before": not_before}, meta_locator,
                            [slug, not_before], "reconcile.work.index-meta-conflict",
                        ))
                    elif parsed > now:
                        buckets["waiting"].append(make_row(
                            "waiting", "work-index", "work-not-before",
                            f"{slug}: waiting until {not_before}",
                            {"slug": slug, "not_before": not_before}, meta_locator,
                            [slug, not_before], "waiting.work.not-before",
                        ))

                is_coordinated = slug in arc_coordinated_items or (item_dir / "coordination.md").is_file()

                plan_path = item_dir / "plan.md"
                tasks_path = item_dir / "tasks.json"
                if index_row.get("has_plan_doc") is True and not is_coordinated:
                    task_rows = None
                    plan_text = ""
                    try:
                        tasks_doc = json.loads(tasks_path.read_text(encoding="utf-8"))
                        plan_text = plan_path.read_text(encoding="utf-8")
                        # tasks[] is authoritative; otherwise phases[] is
                        # flattened. Neither shape leaves task_rows None, which
                        # routes to the evidence-gap row below rather than
                        # reporting a plan with nothing left to do.
                        flat = tasks_doc.get("tasks")
                        nested = tasks_doc.get("phases")
                        if isinstance(flat, list):
                            task_rows = [task for task in flat if isinstance(task, dict)]
                        elif isinstance(nested, list):
                            task_rows = [task for phase in nested if isinstance(phase, dict)
                                         for task in phase.get("tasks", []) if isinstance(task, dict)]
                        else:
                            task_rows = None
                    except (OSError, json.JSONDecodeError, AttributeError):
                        task_rows = None
                    if task_rows is None:
                        buckets["reconcile"].append(make_row(
                            "reconcile", "work-index", "work-action-evidence-gap",
                            f"{slug}: planned item lacks readable task/DAG evidence",
                            {"slug": slug, "tasks_locator": f"_work/{slug}/tasks.json"},
                            f"_work/{slug}/tasks.json", slug,
                            "reconcile.work.action-evidence-gap",
                        ))
                    else:
                        saw_explicit_dag = False
                        tasks_by_id = {
                            str(task.get("id")): task for task in task_rows
                            if task.get("id") is not None
                        }
                        pending_ids = {
                            str(task.get("id")) for task in task_rows
                            if task.get("id") is not None
                            and isinstance(task.get("subject"), str)
                            and f"- [ ] {task['subject']}" in plan_text
                        }
                        for task in task_rows:
                            subject = task.get("subject")
                            if not isinstance(subject, str) or f"- [ ] {subject}" not in plan_text:
                                continue
                            if "blockedBy" not in task or not isinstance(task.get("blockedBy"), list):
                                continue
                            saw_explicit_dag = True
                            task_id = str(task.get("id") or subject)
                            blocked_by = task["blockedBy"]
                            pending_blockers = [
                                str(blocker) for blocker in blocked_by
                                if str(blocker) in pending_ids or str(blocker) not in tasks_by_id
                            ]
                            task_locator = f"_work/{slug}/tasks.json#{task_id}"
                            if pending_blockers:
                                buckets["waiting"].append(make_row(
                                    "waiting", "work-index", "task-blocked",
                                    f"{slug}/{task_id}: pending task is blocked",
                                    {"slug": slug, "task_id": task_id, "subject": subject,
                                     "blockedBy": blocked_by, "blocked_by_pending": pending_blockers},
                                    task_locator, [slug, task_id], "waiting.work.blocked-by",
                                ))
                            elif item_blockers:
                                buckets["reconcile"].append(make_row(
                                    "reconcile", "work-index", "work-action-wait-conflict",
                                    f"{slug}/{task_id}: task DAG is unblocked but the item is explicitly waiting",
                                    {"slug": slug, "task_id": task_id, "task_blockedBy": blocked_by,
                                     "task_blocked_by_pending": [], "item_blocked_by": item_blockers},
                                    task_locator, [slug, task_id, item_blockers],
                                    "reconcile.work.action-wait-conflict",
                                ))
                            else:
                                buckets["act_now"].append(make_row(
                                    "act_now", "work-index", "pending-unblocked-task",
                                    f"{slug}/{task_id}: {subject}",
                                    {"slug": slug, "task_id": task_id, "subject": subject, "checked": False,
                                     "blockedBy": blocked_by, "blocked_by_pending": []},
                                    task_locator, [slug, task_id], "act.work.pending-unblocked",
                                ))
                        if not saw_explicit_dag and "- [ ]" in plan_text:
                            buckets["reconcile"].append(make_row(
                                "reconcile", "work-index", "work-action-evidence-gap",
                                f"{slug}: unchecked work exists without explicit task/DAG evidence",
                                {"slug": slug, "tasks_locator": f"_work/{slug}/tasks.json"},
                                f"_work/{slug}/tasks.json", slug,
                                "reconcile.work.action-evidence-gap",
                            ))


# Eager dispatch is a derived join, never persisted ledger state. Recompute the
# capacity after every projection; lexical ordering is deterministic and carries
# no priority claim.
coordination_capacity = reduction.dispatch(coordination_ceiling)
for bucket, rows in reduction.buckets.items():
    buckets[bucket].extend(rows)


# --- session-journal (published readers only) -----------------------------
session_locator = "_sessions/events.jsonl"
session_list, list_error, list_warning = run_reader("session-list.sh")
session_events, events_error, events_warning = run_reader("session-events.sh")
session_errors = []
session_fold_versions = set()
session_vocab_versions = set()
if list_error:
    session_errors.append(f"session list reader failed: {list_error}")
if events_error:
    session_errors.append(f"session events reader failed: {events_error}")
if list_warning:
    session_errors.append(f"session list reader warning: {list_warning}")
if events_warning:
    session_errors.append(f"session events reader warning: {events_warning}")
if session_list is not None:
    errs, fold, vocab = version_errors(session_list, "session list")
    session_errors.extend(errs)
    if fold is not None: session_fold_versions.add(fold)
    if vocab is not None: session_vocab_versions.add(vocab)
if session_events is not None:
    errs, fold, vocab = version_errors(session_events, "session events", ("1", "2"))
    session_errors.extend(errs)
    if fold is not None: session_fold_versions.add(fold)
    if vocab is not None: session_vocab_versions.add(vocab)
if not (kdir / session_locator).is_file():
    session_errors.append("required session journal is missing")
elif session_events is not None and isinstance(session_events.get("next_cursor"), int):
    journal_size = (kdir / session_locator).stat().st_size
    if session_events["next_cursor"] < journal_size:
        session_errors.append(
            f"session journal has unread trailing bytes at cursor {session_events['next_cursor']} of {journal_size}"
        )

known_events = []
closed_recovery_requests = {}
if session_events is not None and isinstance(session_events.get("events"), list):
    for pos, event in enumerate(session_events["events"], 1):
        if not isinstance(event, dict):
            session_errors.append(f"session event {pos} is not an object")
            continue
        token = event.get("event")
        if token not in SESSION_EVENTS:
            session_errors.append(f"session event {pos} unknown event={token!r}")
            continue
        known_events.append((pos, event))
        if token != "closed":
            continue
        links = event.get("links")
        if not isinstance(links, dict) or "close_requests" not in links:
            continue
        raw_close_requests = links.get("close_requests")
        try:
            close_requests = json.loads(raw_close_requests) if isinstance(raw_close_requests, str) else None
        except json.JSONDecodeError:
            close_requests = None
        if (
            not isinstance(close_requests, list)
            or not close_requests
            or any(not isinstance(request_id, str) or not request_id for request_id in close_requests)
            or len(set(close_requests)) != len(close_requests)
            or json.dumps(close_requests, separators=(",", ":"), ensure_ascii=False) != raw_close_requests
        ):
            session_errors.append(
                f"session event {pos} malformed closed.links.close_requests declaration"
            )
            continue
        closed_recovery_requests[pos] = close_requests

if session_errors:
    add_gap(
        "session-journal", session_locator, line_error_summary(session_errors),
        status="error" if (list_error or events_error) else "gap",
        schema_version="|".join(sorted(session_fold_versions)) or None,
        vocabulary_version="|".join(sorted(session_vocab_versions)) or None,
    )
else:
    source_row("session-journal", "ok", "1", "|".join(sorted(session_vocab_versions)), session_locator)

if session_list is not None and isinstance(session_list.get("instances"), list):
    for instance in session_list["instances"]:
        if not isinstance(instance, dict):
            continue
        instance_name = str(instance.get("name") or "unknown")
        for session in instance.get("sessions", []) if isinstance(instance.get("sessions"), list) else []:
            if not isinstance(session, dict):
                continue
            slug = session.get("slug") or session.get("session_id") or "unknown"
            locator = f"_sessions/instances/{instance_name}.json"
            buckets["waiting"].append(make_row(
                "waiting", "session-journal", "live-session",
                f"live session {slug} on {instance_name}",
                {"instance": instance_name, "session": session}, locator,
                [instance_name, slug], "waiting.session.live",
            ))

# Recovery is forward-only and declaration-only. In particular, the known
# pre-extension row behind
# [session-journal:unmatched-close-failed:1d77a8b177268b18] remains visible: a
# matching slug, ordering, or top-level closed.request_id is never inferred into
# a recovery fact that the historical row did not declare.
closed_after = {}
for pos, request_ids in closed_recovery_requests.items():
    for request_id in request_ids:
        closed_after.setdefault(request_id, []).append(pos)
for pos, event in known_events:
    if event.get("event") != "close_failed":
        continue
    if event.get("reason") == "target-instance-dead":
        continue
    request_id = event.get("request_id")
    if request_id and any(later > pos for later in closed_after.get(request_id, [])):
        continue
    identity = event.get("event_id") or request_id or [pos, event.get("slug")]
    locator = f"_sessions/events.jsonl#event={event.get('event_id') or pos}"
    buckets["needs_judgment"].append(make_row(
        "needs_judgment", "session-journal", "unmatched-close-failed",
        f"close failed for {event.get('slug') or request_id or 'unknown session'}",
        event, locator, identity, "needs.session.unmatched-close-failed",
    ))


# --- scorecard-rows -------------------------------------------------------
score_locator = "_scorecards/rows.jsonl"
score_path = kdir / score_locator
if not score_path.is_file():
    add_gap("scorecard-rows", score_locator, "required scorecard rows source is missing")
else:
    score_errors = []
    score_rows = []
    declared_versions = set()
    try:
        score_lines = score_path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        add_gap("scorecard-rows", score_locator, f"scorecard rows unreadable: {exc}", status="error")
        score_lines = None
    if score_lines is not None:
        if not score_lines:
            score_errors.append("scorecard rows source has no version declaration")
        for lineno, line in enumerate(score_lines, 1):
            if not line.strip():
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError as exc:
                score_errors.append(f"line {lineno} malformed: {exc.msg}")
                continue
            if not isinstance(row, dict):
                score_errors.append(f"line {lineno} is not an object")
                continue
            declared = row.get("schema_version")
            if declared is None:
                score_errors.append(f"line {lineno} missing schema_version declaration")
                continue
            declared_versions.add(str(declared))
            if str(declared) != EXPECTED_VERSION:
                score_errors.append(f"line {lineno} unknown schema_version={declared}")
                continue
            score_rows.append((lineno, row))

        # A ceremony outcome is handled by a later correlated transition row,
        # never by rewriting the outcome. Fold the transitions first so the
        # latest disposition per outcome_id decides; an outcome row that
        # predates the transition shape has no outcome_id to correlate on and
        # stays unhandled, which is the same answer as no transition at all.
        ceremony_latest_disposition = {}
        for _, row in score_rows:
            if row.get("event_type") != "ceremony-resolution":
                continue
            if row.get("record_type") != "disposition":
                continue
            outcome_id = row.get("outcome_id")
            if outcome_id:
                ceremony_latest_disposition[outcome_id] = row.get("disposition")

        for lineno, row in score_rows:
            locator = f"{score_locator}#L{lineno}"
            if row.get("event_type") == "ceremony-resolution":
                if row.get("outcome") not in CEREMONY_OUTCOMES or row.get("disposition") not in CEREMONY_DISPOSITIONS:
                    score_errors.append(
                        f"line {lineno} unknown ceremony vocabulary outcome={row.get('outcome')!r} disposition={row.get('disposition')!r}"
                    )
                elif (
                    row.get("record_type") != "disposition"
                    and row.get("outcome") == "needs-decision"
                    and row.get("disposition") == "unhandled"
                    and ceremony_latest_disposition.get(row.get("outcome_id")) != "handled"
                ):
                    identity = row.get("event_id") or [row.get("ceremony"), row.get("advisor"), row.get("timestamp")]
                    buckets["needs_judgment"].append(make_row(
                        "needs_judgment", "scorecard-rows", "unhandled-ceremony",
                        f"{row.get('ceremony')}: advisor {row.get('advisor')} needs a decision",
                        row, locator, identity, "needs.ceremony.unhandled",
                    ))

            window_end = row.get("window_end")
            parsed_end = parse_time(window_end)
            now = parse_time(observed_at)
            if window_end is not None and parsed_end is None:
                score_errors.append(f"line {lineno} invalid window_end={window_end!r}")
            elif parsed_end is not None and parsed_end > now:
                identity = row.get("window_id") or [row.get("template_id"), row.get("metric"), row.get("window_start"), window_end]
                buckets["waiting"].append(make_row(
                    "waiting", "scorecard-rows", "registered-window",
                    f"registered window remains open until {window_end}",
                    {key: row.get(key) for key in ("window_id", "window_start", "window_end", "template_id", "metric") if key in row},
                    locator, identity, "waiting.scorecard.window",
                ))

        if score_errors:
            add_gap(
                "scorecard-rows", score_locator, line_error_summary(score_errors),
                schema_version="|".join(sorted(declared_versions)) or None,
                vocabulary_version="|".join(sorted(declared_versions)) or None,
            )
        else:
            source_row("scorecard-rows", "ok", "1", "1", score_locator)


# --- retro-queue (published native fold only) -----------------------------
retro_locator = "_scorecards/retro-deferred-queue.jsonl"
retro, retro_error, retro_warning = run_reader("retro-queue.sh", "queue")
retro_errors = []
retro_fold = retro_vocab = None
if retro_error:
    retro_errors.append(f"retro queue reader failed: {retro_error}")
elif retro is not None:
    errs, retro_fold, retro_vocab = version_errors(retro, "retro queue", fold_versions=("2",))
    retro_errors.extend(errs)
if retro_warning:
    retro_errors.append(f"retro queue reader warning: {retro_warning}")
if retro is not None and isinstance(retro.get("counts"), dict):
    malformed = retro["counts"].get("malformed_ignored")
    if isinstance(malformed, int) and malformed > 0:
        retro_errors.append(f"retro queue excluded {malformed} malformed row(s)")
if not (kdir / retro_locator).is_file():
    retro_errors.append("required retro queue source is missing")

if retro is not None and isinstance(retro.get("unhandled_due"), list):
    for pos, row in enumerate(retro["unhandled_due"], 1):
        if not isinstance(row, dict):
            retro_errors.append(f"unhandled_due row {pos} is not an object")
            continue
        if row.get("outcome") != "due" or row.get("disposition") != "unhandled":
            retro_errors.append(
                f"unhandled_due row {pos} unknown vocabulary outcome={row.get('outcome')!r} disposition={row.get('disposition')!r}"
            )
            continue
        identity = row.get("outcome_id") or [row.get("cycle_id"), row.get("ts"), row.get("reason")]
        locator = f"{retro_locator}#outcome_id={row.get('outcome_id') or pos}"
        buckets["needs_judgment"].append(make_row(
            "needs_judgment", "retro-queue", "unhandled-due",
            f"retro DUE outcome {row.get('outcome_id') or pos} is unhandled",
            row, locator, identity, "needs.retro.unhandled-due",
        ))

if retro is not None and isinstance(retro.get("handled_due"), list):
    for pos, row in enumerate(retro["handled_due"], 1):
        action = (row.get("handling") or {}).get("action") if isinstance(row, dict) else None
        if action not in RETRO_ACTIONS:
            retro_errors.append(f"handled_due row {pos} unknown action={action!r}")

if retro_errors:
    add_gap(
        "retro-queue", retro_locator, line_error_summary(retro_errors),
        status="error" if retro_error else "gap",
        schema_version=retro_fold, vocabulary_version=retro_vocab,
    )
else:
    source_row("retro-queue", "ok", retro_fold, retro_vocab, retro_locator)


# --- evolve-staging -------------------------------------------------------
evolve_locator = "_evolve/accepted-clusters.jsonl"
evolve_path = kdir / evolve_locator
if not evolve_path.is_file():
    add_gap("evolve-staging", evolve_locator, "required evolve staging source is missing")
else:
    evolve_errors = []
    evolve_versions = set()
    evolve_vocab_versions = set()
    valid_evolve = []
    try:
        evolve_lines = evolve_path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        add_gap("evolve-staging", evolve_locator, f"evolve staging unreadable: {exc}", status="error")
        evolve_lines = None
    if evolve_lines is not None:
        if not evolve_lines:
            evolve_errors.append("evolve staging has no version declaration")
        for lineno, line in enumerate(evolve_lines, 1):
            if not line.strip():
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError as exc:
                evolve_errors.append(f"line {lineno} malformed: {exc.msg}")
                continue
            if not isinstance(row, dict):
                evolve_errors.append(f"line {lineno} is not an object")
                continue
            schema = row.get("schema_version")
            vocab = row.get("vocabulary_version")
            if schema is None:
                evolve_errors.append(f"line {lineno} missing schema_version declaration")
            else:
                evolve_versions.add(str(schema))
                if str(schema) != EXPECTED_VERSION:
                    evolve_errors.append(f"line {lineno} unknown schema_version={schema}")
            if vocab is None:
                evolve_errors.append(f"line {lineno} missing vocabulary_version declaration")
            else:
                evolve_vocab_versions.add(str(vocab))
                if str(vocab) != EXPECTED_VERSION:
                    evolve_errors.append(f"line {lineno} unknown vocabulary_version={vocab}")
            if str(schema) == EXPECTED_VERSION and str(vocab) == EXPECTED_VERSION:
                valid_evolve.append((lineno, row))

        for lineno, row in valid_evolve:
            if not isinstance(row.get("cluster_id"), str) or "consumed_at_run_id" not in row:
                evolve_errors.append(f"line {lineno} missing cluster_id or consumed_at_run_id")
                continue
            if row.get("consumed_at_run_id") is None:
                locator = f"{evolve_locator}#cluster_id={row['cluster_id']}"
                buckets["act_now"].append(make_row(
                    "act_now", "evolve-staging", "unconsumed-cluster",
                    f"accepted evolve cluster {row['cluster_id']} is ready to consume",
                    row, locator, row["cluster_id"], "act.evolve.unconsumed",
                ))

        if evolve_errors:
            add_gap(
                "evolve-staging", evolve_locator, line_error_summary(evolve_errors),
                schema_version="|".join(sorted(evolve_versions)) or None,
                vocabulary_version="|".join(sorted(evolve_vocab_versions)) or None,
            )
        else:
            source_row("evolve-staging", "ok", "1", "1", evolve_locator)


for rows in buckets.values():
    rows.sort(key=lambda row: (row["source_id"], row["id"]))

projection = {
    "schema_version": "1",
    "observed_at": observed_at,
    "ordering": "neutral lexical source/identity order; not priority",
    "source_manifest": [manifest[source_id] for source_id in SOURCE_ORDER],
    "bucket_counts": {name: len(rows) for name, rows in buckets.items()},
    "coordination_dispatch": {
        "concurrency_ceiling": coordination_ceiling,
        "active_attempts": len(coordination_active),
        "capacity": coordination_capacity,
        "ready_total": len(coordination_candidates),
        "eager_dispatch_count": min(coordination_capacity, len(coordination_candidates)),
        "ledger_scan": {**arc_scan,
                        "reason": dispatch_reason(arc_scan, len(coordination_candidates))},
    },
    # Every readable arc record, including records whose ledger has zero rows.
    # This keeps an empty declared plan distinct from an absent arc identity.
    "coordination_arcs": coordination_arcs,
    "work_evidence": work_evidence,
    # Complete active and closed ledger rows in declaration order. Buckets intentionally contain
    # only actionable/reconcilable rows and sort those rows by identity, so they
    # cannot serve consumers that need the whole DAG and its authored order.
    "coordination_streams": coordination_streams,
    "buckets": buckets,
}

wake_id = os.environ.get("WAKE_ID")
if wake_id:
    sys.path.insert(0, str(scripts))
    from coordinate_watch_state import wake_receipt, compact_receipt
    receipt = wake_receipt(kdir, wake_id)
    projection["wake_receipt"] = receipt if os.environ.get("FULL_EVIDENCE") == "1" else compact_receipt(receipt)
    if os.environ.get("RECEIPT_ONLY") == "1":
        rendered = json.dumps({"schema_version": 1, "wake_receipt": projection["wake_receipt"]}, ensure_ascii=False, indent=2)
        print(rendered, flush=True)
        wake_receipt(kdir, wake_id, acknowledge=True)
        raise SystemExit(0)

if json_mode:
    rendered = json.dumps(projection, ensure_ascii=False, indent=2, sort_keys=False)
    print(rendered, flush=True)
    if wake_id:
        wake_receipt(kdir, wake_id, acknowledge=True)
    raise SystemExit(0)

print(f"Lore coordinate status (observed {observed_at})")
print("Ordering: neutral lexical source/identity order; not priority")
print("\nCoverage manifest (5 required sources)")
for source in projection["source_manifest"]:
    error = f" error={source['error']}" if source["error"] else ""
    print(
        f"  {source['source_id']}: {source['read_status']} "
        f"schema={source['schema_version'] or 'missing'} "
        f"vocabulary={source['vocabulary_version'] or 'missing'} "
        f"locator={source['locator']}{error}"
    )

dispatch = projection["coordination_dispatch"]
scan = dispatch["ledger_scan"]
print("\nCoordination dispatch")
print(
    f"  ready={dispatch['ready_total']} active={dispatch['active_attempts']} "
    f"capacity={dispatch['capacity']} ceiling={dispatch['concurrency_ceiling']}"
)
print(
    f"  ledgers: {scan['read_status']} locator={scan['locator']} "
    f"arcs={scan['arcs_scanned']} active={scan['arcs_active']} "
    f"read={scan['ledgers_read']} streams={scan['streams_read']}"
)
if scan["reason"]:
    print(f"  reason: {scan['reason']}")

print("\nWork evidence (reader contract 2)")
for item in work_evidence:
    print(f"  {item['slug']}: {item['state']} locator={item['locator']}")
    if item.get("reason"):
        print(f"    reason: {item['reason']}")
    else:
        print(f"    revision={compact(item['revision'])}")
        for packet in item["packet_summary"]:
            print(f"    packet={compact(packet)}")
        for result in item["result_summary"]:
            print(f"    criterion={compact(result)}")
        for name, source in item["sources"].items():
            if source["state"] != "read":
                print(f"    {name}: {source['state']} reason={source.get('reason', '')}")
    print(f"    inspect: {compact(item['inspection_argv'])}")

labels = [
    ("act_now", "Act now"),
    ("needs_judgment", "Needs judgment"),
    ("waiting", "Waiting"),
    ("reconcile", "Reconcile"),
]
for key, label in labels:
    rows = buckets[key]
    print(f"\n{label} ({len(rows)})")
    if not rows:
        print("  none")
        continue
    for row in rows:
        print(f"  [{row['id']}] {row['title']}")
        print(f"    source={row['source_id']} rule={row['classification']['rule_id']}: {row['classification']['rule_text']}")
        print(f"    locator={row['evidence']['locator']}")
        print(f"    facts={compact(row['observed_facts'])}")
if wake_id:
    print("\nWake receipt: " + json.dumps(projection["wake_receipt"]), flush=True)
    wake_receipt(kdir, wake_id, acknowledge=True)
PYEOF
