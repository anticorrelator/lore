"""Canonical arc/stream reduction shared by audit and operational readers."""
import hashlib
import json
import re
from pathlib import PurePosixPath
from urllib.parse import unquote, urlsplit

ARC_ROOT = "_work/_arcs"
RELEASING_ATTEMPT_STATUS = "coord_report_accepted"

RULES = {
    "act.work.pending-unblocked": "An unchecked task whose explicit DAG has no pending blockers is actionable.",
    "act.evolve.unconsumed": "A versioned accepted cluster with consumed_at_run_id=null is staged and unconsumed.",
    "needs.ceremony.unhandled": "A ceremony-resolution outcome row explicitly says outcome=needs-decision and disposition=unhandled, and no later correlated transition row records its outcome_id as handled.",
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
    "act.coordinate.ready": "A pending stream has no active attempt, every explicit predecessor is done/full/cleaned, and a settings-derived seat is available.",
    "waiting.coordinate.dependency": "A stream remains waiting until every explicit predecessor is recorded done/full in the ledger.",
    "waiting.coordinate.capacity": "A ready stream waits because the settings-derived concurrency ceiling has no remaining seat.",
    "waiting.coordinate.active": "An active attempt is suppressed from the actionable projection.",
    "needs.coordinate.predecessor": "A terminal predecessor without a full verdict requires coordinator judgment.",
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


def parse_ledger(path):
    """Parse the first markdown table carrying the coordination edge columns."""
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return [], "coordination ledger is unreadable"
    for index, line in enumerate(lines[:-1]):
        if not line.lstrip().startswith("|"):
            continue
        headers = [cell.strip().lower() for cell in line.strip().strip("|").split("|")]
        required = {"depends on", "tree", "status", "verdict"}
        if not required.issubset(headers):
            continue
        separator = lines[index + 1]
        if not separator.lstrip().startswith("|") or "---" not in separator:
            continue
        rows = []
        seen_streams = set()
        for lineno, raw in enumerate(lines[index + 2:], index + 3):
            if not raw.lstrip().startswith("|"):
                break
            cells = [cell.strip() for cell in raw.strip().strip("|").split("|")]
            if len(cells) != len(headers):
                return [], f"coordination ledger row {lineno} has {len(cells)} cells; expected {len(headers)}"
            row = dict(zip(headers, cells))
            stream_id = row.get("stream") or row.get("#") or row.get("step")
            if not stream_id or stream_id in {"—", "-"}:
                return [], f"coordination ledger row {lineno} has no stream identity"
            stream_id = stream_id.strip("`")
            if stream_id in seen_streams:
                return [], f"coordination ledger repeats stream identity {stream_id!r}"
            seen_streams.add(stream_id)
            depends = [] if row["depends on"] in {"", "—", "-"} else [
                token.strip().strip("`") for token in row["depends on"].split(",") if token.strip()
            ]
            rows.append({**row, "stream_id": stream_id, "depends_on": depends,
                         "line": lineno})
        return rows, None
    return [], None


WORK_BACKLINK = re.compile(r"\[\[work:([A-Za-z0-9][A-Za-z0-9._-]*)(?:#[^\]|]+)?(?:\|[^\]]+)?\]\]")
MARKDOWN_LINK = re.compile(r"\[[^\]]*\]\((?:<([^>]+)>|([^\s)]+))(?:\s+[^)]*)?\)")


def declared_work_item(step, rationale=""):
    """Return one unique backlink across the display and rationale cells."""
    matches = list(dict.fromkeys(
        WORK_BACKLINK.findall((step or "") + "\n" + (rationale or ""))))
    return matches[0] if len(matches) == 1 else None


def declared_review_packet(evidence):
    """Return one safe arc-relative Markdown document reference."""
    matches = []
    for linked, plain in MARKDOWN_LINK.findall(evidence or ""):
        target = linked or plain
        try:
            parsed = urlsplit(target)
        except ValueError:
            continue
        path = unquote(parsed.path)
        if parsed.scheme or parsed.netloc or parsed.query or not path or path.startswith("/"):
            continue
        relative = PurePosixPath(path)
        if relative.suffix.lower() != ".md" or any(part == ".." for part in relative.parts):
            continue
        normalized = str(relative)
        if normalized not in matches:
            matches.append(normalized)
    return matches[0] if len(matches) == 1 else None


def reconciliation_projection(kdir, slug):
    """Project the attempt record as the reconciler wrote it.

    Read directly rather than through the writer: this is a plain projection of
    one JSON document, and shelling out to its author to be handed the same
    rows back put the writer's failures in the board's call path.
    """
    state_path = kdir / "_coordination" / "reconciliation" / slug / "streams.json"
    if not state_path.is_file():
        return {}, None
    try:
        payload = json.loads(state_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return {}, f"attempt record is unreadable: {exc}"
    streams = payload.get("streams")
    if not isinstance(streams, list):
        return {}, "attempt record carries no streams list"
    return {row.get("stream_id"): row for row in streams if isinstance(row, dict)}, None


def latest_attempt(stream):
    attempts = stream.get("attempts") if isinstance(stream, dict) else None
    return attempts[-1] if isinstance(attempts, list) and attempts else None


def attempt_liveness(attempt, tree):
    """Whether the latest attempt still holds its stream against redispatch.

    An attempt written before the lifecycle statuses existed carries no status
    at all; that reads as holding, because starting a second session over a live
    one is the direction that cannot be undone.
    """
    if attempt is None:
        return {"attempt_present": False, "attempt_status": None,
                "attempt_status_recorded": False, "holds_stream": False}
    status = attempt.get("status")
    if not isinstance(status, str) or not status:
        return {"attempt_present": True, "attempt_status": None,
                "attempt_status_recorded": False, "holds_stream": True}
    released = status == RELEASING_ATTEMPT_STATUS
    return {"attempt_present": True, "attempt_status": status,
            "attempt_status_recorded": True, "holds_stream": not released}


# --- The ledger's hand-authored vocabulary ---------------------------------
# The coordination ledger is written by hand, and this reader branches on three
# of its columns: Tree decides whether a stream needs a worktree, Status decides
# whether a row is dispatchable, Verdict decides whether a predecessor clears its
# dependents. A value outside the vocabulary therefore does not degrade the row —
# it removes the row from the board, silently, which the seat reads as a stream
# nobody is dispatching. Each column is checked against its declared set and a
# stray value becomes a Reconcile row naming the value, the set, and what the
# board is not doing with it. Canonical sets: the ledger vocabulary block in
# skills/coordinate/SKILL.md; amend both together.
LEDGER_TREES = {"writer", "read-only"}
LEDGER_STATUSES = {"pending", "in-flight", "blocked-on-input", "done", "dropped"}
LEDGER_VERDICTS = {"full", "partial", "none"}
# A verdict is judged at terminus, so an unjudged row leaves the cell empty or
# em-dashed. Status has no such blank form: every row has one from the moment it
# is written.
LEDGER_VERDICT_UNJUDGED = {"", "—", "-"}


def ledger_status_valid(status):
    """`blocked-on:<ref>` carries a free-text ref; the rest are fixed tokens."""
    if status in LEDGER_STATUSES:
        return True
    prefix = "blocked-on:"
    return status.startswith(prefix) and len(status) > len(prefix)


def dependency_cycles(rows):
    graph = {row["stream_id"]: [dep for dep in row["depends_on"]
                                if dep in {item["stream_id"] for item in rows}]
             for row in rows}
    visiting, visited, cyclic = set(), set(), set()

    def walk(node, stack):
        if node in visiting:
            cyclic.update(stack[stack.index(node):])
            return
        if node in visited:
            return
        visiting.add(node)
        stack.append(node)
        for dependency in graph[node]:
            walk(dependency, stack)
        stack.pop()
        visiting.remove(node)
        visited.add(node)

    for node in graph:
        walk(node, [])
    return cyclic


def scan_arcs(kdir, buckets):
    """Every arc record under _work/_arcs/, plus what the scan actually saw.

    The counters exist so an absent directory, an arc set with no ledger, and a
    ledger with no dispatchable stream stay three different answers instead of
    one empty projection.
    """
    root = kdir / "_work" / "_arcs"
    scan = {"locator": ARC_ROOT, "read_status": "absent", "error": None,
            "arcs_scanned": 0, "arcs_active": 0, "ledgers_read": 0, "streams_read": 0}
    records = []
    if not root.is_dir():
        return records, scan
    scan["read_status"] = "ok"
    try:
        names = sorted(entry.name for entry in root.iterdir() if entry.is_dir())
    except OSError as exc:
        scan["read_status"] = "error"
        scan["error"] = f"arc directory is unreadable: {exc}"
        return records, scan
    for name in names:
        if name.startswith((".", "_")):
            continue
        scan["arcs_scanned"] += 1
        meta_locator = f"{ARC_ROOT}/{name}/_meta.json"
        meta = None
        if (root / name / "_meta.json").is_file():
            try:
                loaded = json.loads((root / name / "_meta.json").read_text(encoding="utf-8"))
                if isinstance(loaded, dict):
                    meta = loaded
            except (OSError, json.JSONDecodeError):
                meta = None
        if meta is None:
            buckets["reconcile"].append(make_row(
                "reconcile", "work-index", "coordination-arc-record-invalid",
                f"{name}: arc record lacks readable metadata",
                {"arc": name, "metadata": None}, meta_locator, name,
                "reconcile.work.action-evidence-gap",
            ))
            continue
        ledger_path = root / name / "coordination.md"
        record = {
            "arc": name,
            "status": meta.get("status"),
            "members": [member for member in (meta.get("members") or []) if isinstance(member, str)],
            "ledger_path": ledger_path,
            "has_ledger": ledger_path.is_file(),
        }
        records.append(record)
        if record["status"] == "active":
            scan["arcs_active"] += 1
    return records, scan




def dispatch_reason(scan, ready_total):
    """Name why nothing is ready, so no-read never reads as read-and-empty."""
    if ready_total:
        return None
    if scan["read_status"] == "error":
        return scan["error"]
    if scan["read_status"] == "absent":
        return f"no arc directory at {ARC_ROOT}; no coordination ledger was read"
    if not scan["arcs_scanned"]:
        return f"{ARC_ROOT} holds no arc record"
    if not scan["arcs_active"]:
        return "no arc record is active; only an active arc dispatches"
    if not scan["ledgers_read"]:
        return "no active arc carries a readable coordination.md ledger"
    if not scan["streams_read"]:
        return "the arc ledgers that were read carry no stream rows"
    return "every stream read is active, waiting on a predecessor, or not pending"


class ArcReduction:
    def __init__(self, kdir, scan=None):
        self.kdir = kdir
        self.scan = scan or {"ledgers_read": 0, "streams_read": 0}
        self.buckets = {key: [] for key in ("act_now", "needs_judgment", "waiting", "reconcile")}
        self.streams, self.active, self.candidates = [], [], []

    def project(self, record, dispatch):
        """Project one arc's ledger, with dispatch joins reserved for active arcs."""
        arc = record["arc"]
        ledger_locator = f"{ARC_ROOT}/{arc}/coordination.md"
        ledger_rows, ledger_error = parse_ledger(record["ledger_path"])
        if ledger_error:
            if dispatch:
                self.buckets["reconcile"].append(make_row(
                    "reconcile", "work-index", "coordination-ledger-invalid",
                    f"{arc}: coordination ledger is malformed",
                    {"arc": arc, "error": ledger_error}, ledger_locator,
                    [arc, ledger_error], "reconcile.work.action-evidence-gap",
                ))
            return
        if dispatch:
            self.scan["ledgers_read"] += 1
            self.scan["streams_read"] += len(ledger_rows)
        if not ledger_rows:
            return

        for row in ledger_rows:
            self.streams.append({
                "arc": arc, "arc_status": record["status"],
                "stream_id": row["stream_id"], "step": row.get("step", ""),
                "depends_on": row["depends_on"], "tree": row["tree"],
                "gate": row.get("gate", ""), "status": row["status"],
                "verdict": row["verdict"],
                "work_item": declared_work_item(
                    row.get("step", ""), row.get("call + one-line rationale", "")),
                "review_packet": declared_review_packet(row.get("evidence / sha", "")),
            })

        if not dispatch:
            return

        # The lifecycle record is keyed by the same identity as the ledger it
        # reconciles. An arc without one yields an empty projection, which the
        # per-attempt absent branches below carry as facts rather than as an error.
        reconciled, reconciliation_error = reconciliation_projection(self.kdir, arc)
        if reconciliation_error:
            self.buckets["reconcile"].append(make_row(
                "reconcile", "work-index", "coordination-reconciliation-invalid",
                f"{arc}: reconciliation evidence failed validation",
                {"arc": arc, "error": reconciliation_error},
                f"_coordination/reconciliation/{arc}/streams.json",
                [arc, reconciliation_error], "reconcile.source.gap",
            ))
        ledger_by_id = {row["stream_id"]: row for row in ledger_rows}
        cyclic_streams = dependency_cycles(ledger_rows)
        for row in ledger_rows:
            stream_id = row["stream_id"]
            locator = f"{ledger_locator}#L{row['line']}"
            tree = row["tree"]
            status = row["status"]
            verdict = row["verdict"]
            work_item = declared_work_item(
                row.get("step", ""), row.get("call + one-line rationale", ""))
            review_packet = declared_review_packet(row.get("evidence / sha", ""))
            stream_state = reconciled.get(stream_id, {})
            attempt = latest_attempt(stream_state)
            liveness = attempt_liveness(attempt, tree)
            facts = {
                "arc": arc, "stream_id": stream_id, "depends_on": row["depends_on"],
                "step": row.get("step", ""), "tree": tree,
                "gate": row.get("gate", ""), "status": status, "verdict": verdict,
                "work_item": work_item, "review_packet": review_packet,
                "attempt": attempt, **liveness,
            }
            if stream_id in cyclic_streams:
                self.buckets["reconcile"].append(make_row(
                    "reconcile", "work-index", "coordination-dependency-cycle",
                    f"{arc}/{stream_id}: dependency edge participates in a cycle",
                    facts, locator, [arc, stream_id, sorted(cyclic_streams)],
                    "reconcile.work.action-evidence-gap",
                ))
                continue
            if tree not in LEDGER_TREES:
                self.buckets["reconcile"].append(make_row(
                    "reconcile", "work-index", "coordination-tree-invalid",
                    f"{arc}/{stream_id}: unknown Tree value {tree!r} "
                    f"(expected writer or read-only) — this row is not being joined "
                    f"into the board", facts, locator,
                    [arc, stream_id, tree], "reconcile.work.action-evidence-gap",
                ))
                continue
            if not ledger_status_valid(status):
                self.buckets["reconcile"].append(make_row(
                    "reconcile", "work-index", "coordination-status-invalid",
                    f"{arc}/{stream_id}: unknown Status value {status!r} "
                    f"(expected pending, in-flight, blocked-on:<ref>, "
                    f"blocked-on-input, done, or dropped) — this row is not being "
                    f"joined into the board", facts, locator,
                    [arc, stream_id, status], "reconcile.work.action-evidence-gap",
                ))
                continue
            if verdict not in LEDGER_VERDICTS and verdict not in LEDGER_VERDICT_UNJUDGED:
                self.buckets["reconcile"].append(make_row(
                    "reconcile", "work-index", "coordination-verdict-invalid",
                    f"{arc}/{stream_id}: unknown Verdict value {verdict!r} "
                    f"(expected full, partial, none, or — while unjudged) — this row "
                    f"is not being joined into the board, and no stream depending on "
                    f"it can be cleared by it", facts, locator,
                    [arc, stream_id, verdict], "reconcile.work.action-evidence-gap",
                ))
                continue
            if status == "in-flight" or liveness["holds_stream"]:
                self.active.append((arc, stream_id, tree))
                self.buckets["waiting"].append(make_row(
                    "waiting", "work-index", "active-stream-attempt",
                    f"{arc}/{stream_id}: active attempt is not redispatched", facts,
                    locator, [arc, stream_id], "waiting.coordinate.active",
                ))
                continue
            if status != "pending":
                continue
            unresolved = []
            judgment = []
            for dependency in row["depends_on"]:
                predecessor = ledger_by_id.get(dependency)
                if predecessor is None:
                    judgment.append({"stream_id": dependency, "reason": "missing ledger row"})
                    continue
                # The ledger row is the account of a predecessor's outcome: the seat
                # writes done/full there once it has merged the stream and run the
                # suites. Nothing else is consulted, so nothing else can disagree.
                if predecessor.get("status") == "done" and predecessor.get("verdict") == "full":
                    continue
                detail = {
                    "stream_id": dependency,
                    "status": predecessor.get("status"),
                    "verdict": predecessor.get("verdict"),
                }
                if predecessor.get("status") == "done" or predecessor.get("verdict") in {"partial", "none"}:
                    judgment.append(detail)
                else:
                    unresolved.append(detail)
            facts["unresolved_predecessors"] = unresolved
            facts["judgment_predecessors"] = judgment
            if judgment:
                self.buckets["needs_judgment"].append(make_row(
                    "needs_judgment", "work-index", "predecessor-not-full",
                    f"{arc}/{stream_id}: terminal predecessor is not recorded full",
                    facts, locator, [arc, stream_id, judgment],
                    "needs.coordinate.predecessor",
                ))
            elif unresolved:
                self.buckets["waiting"].append(make_row(
                    "waiting", "work-index", "stream-dependency-wait",
                    f"{arc}/{stream_id}: waiting on explicit predecessors", facts,
                    locator, [arc, stream_id, unresolved],
                    "waiting.coordinate.dependency",
                ))
            else:
                self.candidates.append((arc, stream_id, tree, facts, locator))

    def dispatch(self, ceiling):
        self.candidates.sort(key=lambda row: (row[0], row[1]))
        capacity = max(0, ceiling - len(self.active))
        for index, (arc, stream_id, tree, facts, locator) in enumerate(self.candidates):
            facts = {**facts, "concurrency_ceiling": ceiling,
                     "active_attempts": len(self.active),
                     "dispatch_slot": index + 1 if index < capacity else None}
            if index < capacity:
                self.buckets["act_now"].append(make_row(
                    "act_now", "work-index", "ready-stream",
                    f"{arc}/{stream_id}: ready for eager dispatch", facts, locator,
                    [arc, stream_id], "act.coordinate.ready",
                ))
            else:
                self.buckets["waiting"].append(make_row(
                    "waiting", "work-index", "ready-stream-at-capacity",
                    f"{arc}/{stream_id}: ready, waiting for a coordination seat", facts,
                    locator, [arc, stream_id], "waiting.coordinate.capacity",
                ))
        return capacity
