#!/usr/bin/env bash
# coordinate-status.sh — Read-only cross-substrate coordination projection.
#
# This composer owns no state and invokes only the published pure readers for
# session and retro data. Work, scorecard, and evolve inputs are already-
# published artifacts without narrower read folds, so they are opened directly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# Read-only vocabulary mirrors. Tests compare the session and retro tokens to
# their sole appenders so producer drift fails loudly at review time.
SESSION_EVENT_VOCAB="requested claimed spawned needs_input quiescent resumed recovered closed orphaned step_completed terminus_reached harness_turn_ended spawn_failed request_reclaimed request_abandoned request_cancelled close_requested close_failed restore_refused worktree_quarantined send_requested sent send_refused answer_requested answered answer_refused modal_blocked review_flagged review_held review_notified review_released"
RETRO_ACTION_VOCAB="dispatched deferred skipped"
CEREMONY_OUTCOME_VOCAB="needs-decision"
CEREMONY_DISPOSITION_VOCAB="unhandled"

usage() {
  cat >&2 <<'EOF'
Usage: coordinate-status.sh [--kdir <path>] [--json]

Render a read-only, five-source coordination projection. The JSON envelope is
schema version 1; human output renders the same source manifest and bucket rows.
EOF
}

KDIR_OVERRIDE=""
JSON_MODE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kdir) KDIR_OVERRIDE="${2:-}"; shift 2 ;;
    --json) JSON_MODE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Error: unknown argument '$1'" >&2; usage; exit 1 ;;
  esac
done

command -v python3 >/dev/null 2>&1 || die "python3 is required but not found on PATH"

if [[ -n "$KDIR_OVERRIDE" ]]; then
  KNOWLEDGE_DIR="$KDIR_OVERRIDE"
else
  KNOWLEDGE_DIR="$(resolve_knowledge_dir)"
fi
[[ -d "$KNOWLEDGE_DIR" ]] || die "knowledge store not found at: $KNOWLEDGE_DIR"

export SESSION_EVENT_VOCAB RETRO_ACTION_VOCAB CEREMONY_OUTCOME_VOCAB \
  CEREMONY_DISPOSITION_VOCAB

exec python3 - "$KNOWLEDGE_DIR" "$SCRIPT_DIR" "$JSON_MODE" <<'PYEOF'
import datetime as dt
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path


kdir = Path(sys.argv[1])
scripts = Path(sys.argv[2])
json_mode = sys.argv[3] == "1"
observed_at = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")

SESSION_EVENTS = set(os.environ["SESSION_EVENT_VOCAB"].split())
RETRO_ACTIONS = set(os.environ["RETRO_ACTION_VOCAB"].split())
CEREMONY_OUTCOMES = set(os.environ["CEREMONY_OUTCOME_VOCAB"].split())
CEREMONY_DISPOSITIONS = set(os.environ["CEREMONY_DISPOSITION_VOCAB"].split())

EXPECTED_VERSION = "1"
SOURCE_ORDER = [
    "work-index",
    "session-journal",
    "scorecard-rows",
    "retro-queue",
    "evolve-staging",
]

RULES = {
    "act.work.pending-unblocked": "An unchecked task whose explicit DAG has no pending blockers is actionable.",
    "act.evolve.unconsumed": "A versioned accepted cluster with consumed_at_run_id=null is staged and unconsumed.",
    "needs.ceremony.unhandled": "A ceremony-resolution row explicitly says outcome=needs-decision and disposition=unhandled.",
    "needs.retro.unhandled-due": "The retro native fold reports a DUE outcome without a handling disposition.",
    "needs.session.unmatched-close-failed": "A close_failed event has no later closed event whose links.close_requests explicitly includes the failed request.",
    "waiting.session.live": "A session appears in the native live-instance fold.",
    "waiting.work.blocked-by": "A work item or pending task carries a non-empty blocked_by fact.",
    "waiting.work.not-before": "A work item declares a future not_before timestamp.",
    "waiting.scorecard.window": "A registered scorecard window has an explicit future window_end.",
    "reconcile.source.gap": "A required source is missing, malformed, unreadable, or declares an unsupported contract version/vocabulary.",
    "reconcile.work.index-meta-conflict": "The published work index and an explicit metadata field disagree.",
    "reconcile.work.notes-status-conflict": "The latest explicit **Status:** note disagrees with the published work status.",
    "reconcile.work.merged-active": "An item still in the active index explicitly reports merged state or a merge commit.",
    "reconcile.work.action-evidence-gap": "An active planned item lacks versioned task/DAG evidence; absence is not treated as unblocked.",
    "reconcile.work.action-wait-conflict": "A pending task is locally unblocked while its work item carries explicit waiting evidence.",
}


def compact(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def stable_id(source_id, kind, locator, identity):
    payload = compact([source_id, kind, locator, identity])
    return f"{source_id}:{kind}:{hashlib.sha256(payload.encode()).hexdigest()[:16]}"


def make_row(bucket, source_id, kind, title, facts, locator, identity, rule_id):
    return {
        "id": stable_id(source_id, kind, locator, identity),
        "source_id": source_id,
        "kind": kind,
        "title": title,
        "observed_facts": facts,
        "evidence": {"locator": locator},
        "classification": {"rule_id": rule_id, "rule_text": RULES[rule_id]},
    }


buckets = {"act_now": [], "needs_judgment": [], "waiting": [], "reconcile": []}
manifest = {}


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


def version_errors(envelope, label):
    errors = []
    fold = envelope.get("fold_version")
    vocab = envelope.get("vocabulary_version")
    if fold is None:
        errors.append(f"{label} missing fold_version declaration")
    elif str(fold) != EXPECTED_VERSION:
        errors.append(f"{label} unknown fold_version={fold}")
    if vocab is None:
        errors.append(f"{label} missing vocabulary_version declaration")
    elif str(vocab) != EXPECTED_VERSION:
        errors.append(f"{label} unknown vocabulary_version={vocab}")
    return errors, None if fold is None else str(fold), None if vocab is None else str(vocab)


def line_error_summary(errors):
    if not errors:
        return None
    if len(errors) <= 4:
        return "; ".join(errors)
    return "; ".join(errors[:4]) + f"; and {len(errors) - 4} more"


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

                plan_path = item_dir / "plan.md"
                tasks_path = item_dir / "tasks.json"
                if index_row.get("has_plan_doc") is True:
                    task_rows = None
                    plan_text = ""
                    try:
                        tasks_doc = json.loads(tasks_path.read_text(encoding="utf-8"))
                        plan_text = plan_path.read_text(encoding="utf-8")
                        task_rows = [task for phase in tasks_doc.get("phases", []) if isinstance(phase, dict)
                                     for task in phase.get("tasks", []) if isinstance(task, dict)]
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
    errs, fold, vocab = version_errors(session_events, "session events")
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
    source_row("session-journal", "ok", "1", "1", session_locator)

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

        for lineno, row in score_rows:
            locator = f"{score_locator}#L{lineno}"
            if row.get("event_type") == "ceremony-resolution":
                if row.get("outcome") not in CEREMONY_OUTCOMES or row.get("disposition") not in CEREMONY_DISPOSITIONS:
                    score_errors.append(
                        f"line {lineno} unknown ceremony vocabulary outcome={row.get('outcome')!r} disposition={row.get('disposition')!r}"
                    )
                elif row.get("outcome") == "needs-decision" and row.get("disposition") == "unhandled":
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
    errs, retro_fold, retro_vocab = version_errors(retro, "retro queue")
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
    source_row("retro-queue", "ok", "1", "1", retro_locator)


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
    "buckets": buckets,
}

if json_mode:
    print(json.dumps(projection, ensure_ascii=False, indent=2, sort_keys=False))
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
PYEOF
