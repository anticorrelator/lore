#!/usr/bin/env python3
"""Sole writer of the coordinated stream attempt record."""

from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import re
import sys
import tempfile


SCHEMA_VERSION = 3
# A record written before the lifecycle phases existed is still valid and is
# read unchanged; it is rewritten at version 3 by the first operation that
# actually changes it.
SUPPORTED_SCHEMA_VERSIONS = (2, 3)
WORKTREE_SCHEMA_VERSION = 1
TREES = {"writer", "read-only"}
TOKEN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")

# This module is the only place the `coord_` vocabulary is defined. The
# worktree manager and the board readers quote these strings; they do not
# maintain their own copies. The prefix is load-bearing rather than
# decorative: `reserved` is already a manager lifecycle state, `quarantine` is
# already a guard identity state, `disposition` already names three unrelated
# axes (branch_disposition, guard_refs_disposition, and the knowledge ledger's
# held/contradicted), and `stream` is this record's own key — so an unprefixed
# token would read as one of those.
COORD_ALLOCATED = "coord_allocated"
COORD_DISPATCHED = "coord_dispatched"
COORD_REPORT_ACCEPTED = "coord_report_accepted"
# Forward edges the advance verb may take. Everything else, including a skip
# and a walk backward, is refused. `coord_report_accepted` is terminal: the
# attempt's evidence is the landed report, the integration commit, and the
# suite counts the seat records in the arc ledger — none of which this record
# holds, and none of which it should restate.
COORD_TRANSITIONS = {
    COORD_ALLOCATED: {COORD_DISPATCHED},
    COORD_DISPATCHED: {COORD_REPORT_ACCEPTED},
}
# Whether a swept tree's temporary branch ever moved off its allocation base.
BRANCH_RELEVANCE = {
    "coord_branch_unchanged", "coord_branch_advanced", "coord_branch_unavailable",
}
# Where a quarantined result went, as judged by a caller who looked. Absence of
# the field is the distinct state meaning nobody looked; "coord_delivery_unknown"
# is a recorded judgment that the evidence was inconclusive. None of the three
# ever means publication succeeded.
DELIVERY_CLASSIFICATIONS = {
    "coord_quarantine_routine_residue", "coord_quarantine_unintegrated",
    "coord_delivery_unknown",
}
# Lookup answers. Each names a different situation, so a caller never has to
# read an empty result to guess which one it got.
LOOKUP_RECORD_ABSENT = "coord_lookup_record_absent"
LOOKUP_STREAM_ABSENT = "coord_lookup_stream_absent"
LOOKUP_ATTEMPT_ABSENT = "coord_lookup_attempt_absent"
LOOKUP_TREE_ABSENT = "coord_lookup_tree_absent"
LOOKUP_RESOLVED = "coord_lookup_resolved"
LOOKUP_STALE_POINTER = "coord_lookup_stale_pointer"


def fail(message: str) -> None:
    raise SystemExit(f"[coordinate-reconcile] Error: {message}")


def now() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def require_token(name: str, value: str) -> str:
    if not TOKEN.fullmatch(value or ""):
        fail(f"invalid {name}: {value!r}")
    return value


def load_json(path: Path, label: str) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        fail(f"{label} is missing: {path}")
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"{label} is unreadable: {exc}")
    if not isinstance(value, dict):
        fail(f"{label} must be a JSON object")
    return value


def find_worktree_record(kdir: Path, worktree_id: str) -> tuple[dict | None, str | None]:
    """Resolve a worktree pointer, returning (None, None) when it names nothing.

    An unreadable or wrong-version record still fails: only absence is a
    reportable outcome.
    """
    roots = (
        (kdir / "_coordination" / "worktrees" / "archive", "archive"),
        (kdir / "_coordination" / "worktrees" / "registry", "registry"),
    )
    for root, source in roots:
        path = root / f"{worktree_id}.json"
        if path.is_file():
            row = load_json(path, f"worktree {source} record")
            if row.get("schema_version") != WORKTREE_SCHEMA_VERSION:
                fail(f"worktree {source} record declares unsupported schema_version={row.get('schema_version')!r}")
            return row, source
    return None, None


def worktree_record(kdir: Path, worktree_id: str) -> tuple[dict, str]:
    row, source = find_worktree_record(kdir, worktree_id)
    if row is None:
        fail(f"worktree identity is absent from registry and archive: {worktree_id}")
    return row, source


def validate_identity(row: dict, slug: str, stream: str, attempt: str, worktree_id: str) -> None:
    expected = {
        "worktree_id": worktree_id,
        "owner_item": slug,
        "stream_id": stream,
        "attempt_id": attempt,
    }
    mismatches = {key: {"expected": value, "observed": row.get(key)}
                  for key, value in expected.items() if row.get(key) != value}
    if mismatches:
        fail(f"worktree identity mismatch: {json.dumps(mismatches, sort_keys=True)}")


class Store:
    def __init__(self, kdir: Path, slug: str):
        self.kdir = kdir
        self.slug = slug
        self.root = kdir / "_coordination" / "reconciliation" / slug
        self.state_path = self.root / "streams.json"
        self.lock_path = self.root / ".writer.lock"

    def load(self, allow_missing: bool = False) -> dict:
        if not self.state_path.exists():
            if allow_missing:
                return {"schema_version": SCHEMA_VERSION, "work_item": self.slug, "streams": []}
            fail(f"reconciliation state is missing: {self.state_path}")
        state = load_json(self.state_path, "reconciliation state")
        if state.get("schema_version") not in SUPPORTED_SCHEMA_VERSIONS:
            fail(f"unsupported reconciliation schema_version={state.get('schema_version')!r}")
        if state.get("work_item") != self.slug or not isinstance(state.get("streams"), list):
            fail("reconciliation state identity or streams shape is invalid")
        return state

    def locked(self):
        self.root.mkdir(parents=True, exist_ok=True)
        handle = self.lock_path.open("a+")
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        return handle

    @staticmethod
    def snapshot(state: dict) -> str:
        """Serialize everything an operation could change, so replays are detectable.

        `updated_at` and `schema_version` are excluded: both move as a
        consequence of writing rather than as content, and including either
        would make every replay look like a change.
        """
        body = {key: value for key, value in state.items()
                if key not in ("updated_at", "schema_version")}
        body["streams"] = sorted(state["streams"], key=lambda row: row["stream_id"])
        return json.dumps(body, ensure_ascii=False, sort_keys=True)

    def write(self, state: dict) -> None:
        state["schema_version"] = SCHEMA_VERSION
        state["updated_at"] = now()
        state["streams"] = sorted(state["streams"], key=lambda row: row["stream_id"])
        atomic_write(self.state_path, json.dumps(state, ensure_ascii=False, indent=2, sort_keys=True).encode() + b"\n")

    def commit(self, state: dict, before: str) -> bool:
        """Write only when the operation actually changed the record."""
        if self.snapshot(state) == before:
            return False
        self.write(state)
        return True

    def stream(self, state: dict, stream_id: str, tree: str, depends_on: list[str]) -> dict:
        for row in state["streams"]:
            if row.get("stream_id") == stream_id:
                if row.get("tree") != tree or row.get("depends_on") != depends_on:
                    fail(f"stream {stream_id} was already frozen with different tree/dependency identity")
                return row
        row = {"stream_id": stream_id, "tree": tree, "depends_on": depends_on, "attempts": []}
        state["streams"].append(row)
        return row


def parse_depends(raw: str) -> list[str]:
    values = []
    for value in raw.split(",") if raw else []:
        token = require_token("dependency", value.strip())
        if token not in values:
            values.append(token)
    return values


def declared_edges() -> str:
    return ", ".join(f"{source} -> {target}"
                     for source, targets in COORD_TRANSITIONS.items()
                     for target in sorted(targets))


def find_stream(state: dict, stream_id: str) -> dict | None:
    return next((row for row in state["streams"] if row.get("stream_id") == stream_id), None)


def find_attempt(stream: dict, attempt_id: str) -> dict | None:
    return next((row for row in stream.get("attempts", []) if row.get("attempt_id") == attempt_id), None)


def sweep_recovery_fact(args) -> dict | None:
    """Build the recorded sweep fact, or None when the caller supplied none."""
    if not args.branch_relevance:
        return None
    if args.branch_relevance not in BRANCH_RELEVANCE:
        fail(f"invalid --branch-relevance: {args.branch_relevance!r}; "
             f"choose one of {', '.join(sorted(BRANCH_RELEVANCE))}")
    fact = {"relevance": args.branch_relevance}
    for key, value in (("allocation_base_sha", args.branch_base_sha),
                       ("branch_tip_sha", args.branch_tip_sha),
                       ("recovery_bundle_path", args.recovery_bundle),
                       ("quarantine_patch_path", args.quarantine_patch)):
        if value:
            fact[key] = value
    return fact


def delivery_fact(args) -> dict | None:
    """Build the recorded delivery judgment, or None when the caller supplied none."""
    if not args.delivery_classification:
        return None
    if args.delivery_classification not in DELIVERY_CLASSIFICATIONS:
        fail(f"invalid --delivery-classification: {args.delivery_classification!r}; "
             f"choose one of {', '.join(sorted(DELIVERY_CLASSIFICATIONS))}")
    # A classification is a judgment somebody made, so it has to arrive with
    # what it was made from. Nothing here reads the session journal: journal
    # silence is not evidence and never produces a classification.
    if not args.delivery_evidence:
        fail("--delivery-classification requires at least one --delivery-evidence "
             "naming what the judgment rests on (a quarantine ref, patch path, "
             "commit sha, or report id)")
    return {"classification": args.delivery_classification,
            "evidence": sorted(set(args.delivery_evidence))}


def command_register_attempt(args, store: Store) -> dict:
    """Bring an attempt into the record at its first lifecycle phase."""
    stream_id = require_token("stream", args.stream)
    attempt_id = require_token("attempt", args.attempt)
    depends_on = parse_depends(args.depends_on)
    if args.tree not in TREES:
        fail(f"invalid tree: {args.tree!r}")
    worktree_id = args.worktree_id or None
    if args.tree == "read-only":
        if worktree_id:
            fail("a read-only stream owns no worktree; drop --worktree-id")
        initial = COORD_DISPATCHED
    else:
        if not worktree_id:
            fail("register-attempt on a writer stream requires --worktree-id "
                 "(pass --tree read-only for a stream that owns no checkout)")
        require_token("worktree id", worktree_id)
        identity, _ = worktree_record(store.kdir, worktree_id)
        validate_identity(identity, store.slug, stream_id, attempt_id, worktree_id)
        initial = COORD_ALLOCATED

    with store.locked():
        state = store.load(allow_missing=True)
        before = store.snapshot(state)
        stream = store.stream(state, stream_id, args.tree, depends_on)
        attempt = find_attempt(stream, attempt_id)
        if attempt is None:
            attempt = {"attempt_id": attempt_id, "status": initial, "updated_at": now()}
            if worktree_id:
                attempt["worktree_id"] = worktree_id
            stream["attempts"].append(attempt)
        elif attempt.get("worktree_id") != worktree_id:
            fail(f"attempt {stream_id}/{attempt_id} is already registered against "
                 f"worktree {attempt.get('worktree_id')!r}, not {worktree_id!r}; "
                 "use a new attempt id")
        wrote = store.commit(state, before)
        status = attempt.get("status")
    return {"outcome": "coord_registered" if wrote else "coord_register_replayed",
            "work_item": store.slug, "stream_id": stream_id, "attempt_id": attempt_id,
            "tree": args.tree, "worktree_id": worktree_id, "status": status}


def command_advance_attempt(args, store: Store) -> dict:
    """Take one declared lifecycle edge, or attach recorded facts in place."""
    stream_id = require_token("stream", args.stream)
    attempt_id = require_token("attempt", args.attempt)
    if not args.expected_status:
        fail("advance-attempt requires --expected-status naming the status you "
             "believe the attempt is at, so a stale caller conflicts instead of "
             "overwriting a newer one")
    target = args.to or None
    recovery = sweep_recovery_fact(args)
    delivery = delivery_fact(args)
    if target is None and recovery is None and delivery is None:
        fail("advance-attempt needs --to, or at least one recorded fact "
             "(--branch-relevance / --delivery-classification)")
    if target is not None and target not in COORD_TRANSITIONS.get(args.expected_status, set()):
        fail(f"undeclared coordination transition {args.expected_status!r} -> {target!r}; "
             f"the declared edges are {declared_edges()}, and "
             f"{COORD_REPORT_ACCEPTED} is where an attempt rests.")

    with store.locked():
        state = store.load()
        before = store.snapshot(state)
        stream = find_stream(state, stream_id)
        if stream is None:
            fail(f"unknown stream {stream_id}")
        attempt = find_attempt(stream, attempt_id)
        if attempt is None:
            fail(f"unknown attempt {stream_id}/{attempt_id}")
        current = attempt.get("status")
        # An advance that already landed leaves the attempt sitting on its
        # target, so replaying the same call is a success, not a conflict.
        replayed_edge = target is not None and current == target
        if not replayed_edge and current != args.expected_status:
            fail(f"advance-attempt conflict: {stream_id}/{attempt_id} is at "
                 f"{current!r}, caller expected {args.expected_status!r}")
        if target is not None and not replayed_edge:
            attempt["status"] = target
        if recovery is not None:
            attempt["coord_sweep_recovery"] = recovery
        if delivery is not None:
            attempt["coord_delivery"] = delivery
        if store.snapshot(state) != before:
            attempt["updated_at"] = now()
        wrote = store.commit(state, before)
        status = attempt.get("status")
    return {"outcome": "coord_advanced" if wrote else "coord_advance_replayed",
            "work_item": store.slug, "stream_id": stream_id, "attempt_id": attempt_id,
            "status": status, "coord_sweep_recovery": recovery, "coord_delivery": delivery}


def command_lookup_attempt(args, store: Store) -> dict:
    """Answer (work item, stream, attempt) -> tree identity without a caller-held id.

    Every outcome is a successful read: the caller branches on `outcome` rather
    than on an empty payload, so "no record yet" and "the pointer went stale"
    never render alike.
    """
    stream_id = require_token("stream", args.stream)
    attempt_id = require_token("attempt", args.attempt)
    result = {"work_item": store.slug, "stream_id": stream_id, "attempt_id": attempt_id,
              "schema_version": None, "tree": None, "status": None, "worktree_id": None,
              "coord_sweep_recovery": None, "coord_delivery": None, "worktree": None}
    if not store.state_path.exists():
        return {**result, "outcome": LOOKUP_RECORD_ABSENT}
    state = store.load()
    result["schema_version"] = state.get("schema_version")
    stream = find_stream(state, stream_id)
    if stream is None:
        return {**result, "outcome": LOOKUP_STREAM_ABSENT}
    result["tree"] = stream.get("tree")
    attempt = find_attempt(stream, attempt_id)
    if attempt is None:
        return {**result, "outcome": LOOKUP_ATTEMPT_ABSENT}
    result.update({
        "status": attempt.get("status"),
        "worktree_id": attempt.get("worktree_id"),
        "coord_sweep_recovery": attempt.get("coord_sweep_recovery"),
        "coord_delivery": attempt.get("coord_delivery"),
    })
    worktree_id = attempt.get("worktree_id")
    if not worktree_id:
        return {**result, "outcome": LOOKUP_TREE_ABSENT}
    identity, source = find_worktree_record(store.kdir, worktree_id)
    if identity is None:
        return {**result, "outcome": LOOKUP_STALE_POINTER}
    validate_identity(identity, store.slug, stream_id, attempt_id, worktree_id)
    # Manager-owned fields are projected, never copied into the record: the
    # registry stays their only writer. `cleanup_proof` is passed through as the
    # manager wrote it at removal time rather than recomputed from its parts —
    # the proof is a record, and a reader that rebuilds it can disagree with it.
    result["worktree"] = {
        "record_source": source,
        "state": identity.get("state"),
        "execution_dir": identity.get("execution_dir"),
        "temporary_branch": identity.get("temporary_branch"),
        "git_common_dir": identity.get("git_common_dir"),
        "allocation_base_sha": identity.get("allocation_base_sha"),
        "owner": identity.get("owner"),
        "lease": identity.get("lease"),
        "cleanup_proof": identity.get("cleanup_proof"),
    }
    return {**result, "outcome": LOOKUP_RESOLVED}


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser()
    p.add_argument("operation", choices=("register-attempt", "advance-attempt", "lookup-attempt"))
    p.add_argument("--kdir", required=True)
    p.add_argument("--slug", required=True)
    p.add_argument("--stream")
    p.add_argument("--attempt")
    p.add_argument("--worktree-id")
    p.add_argument("--tree", default="writer")
    p.add_argument("--depends-on", default="")
    p.add_argument("--expected-status", help="status advance-attempt believes the attempt is at")
    p.add_argument("--to", help="lifecycle status to advance to; omit to record facts in place")
    p.add_argument("--branch-relevance", choices=sorted(BRANCH_RELEVANCE))
    p.add_argument("--branch-base-sha")
    p.add_argument("--branch-tip-sha")
    p.add_argument("--recovery-bundle")
    p.add_argument("--quarantine-patch")
    p.add_argument("--delivery-classification", choices=sorted(DELIVERY_CLASSIFICATIONS))
    p.add_argument("--delivery-evidence", action="append", default=[],
                   help="identifier the delivery judgment rests on; repeatable")
    p.add_argument("--json", action="store_true")
    return p


def main() -> int:
    args = parser().parse_args()
    store = Store(Path(args.kdir).resolve(), require_token("work item", args.slug))
    if not args.stream or not args.attempt:
        fail(f"{args.operation} requires --stream and --attempt")
    functions = {
        "register-attempt": command_register_attempt,
        "advance-attempt": command_advance_attempt,
        "lookup-attempt": command_lookup_attempt,
    }
    result = functions[args.operation](args, store)
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        print(f"[coordinate-reconcile] {result.get('outcome') or result.get('status') or 'valid'} {store.slug}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
